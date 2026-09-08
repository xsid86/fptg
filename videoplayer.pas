unit videoplayer;

{$mode objfpc}{$H+}

{ Looped decoding of a single "GIF" (messageAnimation — actually a
  short MP4/H.264 video with no audio) in a background thread, the
  same decoder-thread approach as audioplayer.pas (TAudioPlayer), but
  with no audio output. Each decoded frame is converted to BGRA
  (libswscale, directly to the preview size — decode/scale once to
  the target size rather than to the native resolution, cheaper on
  memory/CPU) and written into a single buffer guarded by a critical
  section. The widget reads it on redraw (TryGetFrame), polled by a
  timer rather than via Synchronize per frame, since video frames
  arrive much more often than the audio timer's 250ms tick.

  There are no play/pause/stop controls: a GIF either does not play at
  all, or loops continuously for as long as the widget exists.
  StopPlayback is not a user control — it is the internal stop signal
  used when the widget is reused or hidden.

  FreeOnTerminate=True, unlike TAudioPlayer (FreeOnTerminate=False,
  where the caller does WaitFor+Free): any number of GIFs can be
  looping on screen at once, and StopPlayback fires every time a
  widget is reused or scrolled off screen — often, once per GIF. A
  synchronous WaitFor from the UI thread could stall the interface for
  up to a second (the maximum inter-frame delay inside the decode
  loop) when scrolling past several GIFs quickly. FreeOnTerminate
  removes the need for WaitFor — the thread frees itself once it
  notices FStopRequested and exits Execute; the caller (framehistory.
  pas) must forget its reference immediately after calling
  StopPlayback and never touch the object afterward, since it may be
  destroyed asynchronously, from its own thread, at any point after
  that. }

interface

uses
  Classes, SysUtils, SyncObjs, ffdecode, ctypes;

type
  TAnimationPlayer = class(TThread)
  private
    FFilePath: utf8string;
    FTargetW, FTargetH: integer;
    FLock: TCriticalSection;
    FFrameBuf: PByte;         { BGRA, FTargetW*FTargetH*4 bytes, guarded by FLock }
    FFrameVersion: cardinal;  { incremented on every completed frame }
    FStopRequested: boolean;
    FFailed: boolean;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
    destructor Destroy; override;
    procedure StopPlayback;
    { Copies the current frame into ADst (a TargetWidth*TargetHeight*4
      byte buffer already allocated by the caller, the same size as
      the internal FFrameBuf) if the available frame is NEWER than
      AKnownVersion — updates AKnownVersion and returns True (the
      widget should redraw). Returns False and leaves ADst untouched
      if there is no frame yet, or it is not newer than what was
      already seen. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    { True if the decoder failed to open/read the file at all (corrupt
      or unknown codec) — the widget then simply shows no animation
      (stays on the placeholder) instead of crashing. }
    property Failed: boolean read FFailed;
  end;

implementation

constructor TAnimationPlayer.Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
begin
  inherited Create(True);
  FFilePath := AFilePath;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FLock := TCriticalSection.Create;
  FreeOnTerminate := True;
  Start;
end;

destructor TAnimationPlayer.Destroy;
begin
  { FreeOnTerminate=True (see the unit header comment) — this
    destructor is called by the THREAD ITSELF, from inside TThread's
    termination machinery, after Execute has already returned; the
    caller (framehistory.pas) never reaches this code path, it only
    calls StopPlayback and immediately forgets the pointer. }
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TAnimationPlayer.StopPlayback;
begin
  FStopRequested := True;
end;

function TAnimationPlayer.TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if (FFrameBuf <> nil) and (FFrameVersion <> 0) and (FFrameVersion <> AKnownVersion) then begin
      Move(FFrameBuf^, ADst^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      AKnownVersion := FFrameVersion;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TAnimationPlayer.Execute;
begin
  try
    ExecuteInner;
  except
    on E: Exception do begin
      FFailed := True;
    end;
  end;
end;

procedure TAnimationPlayer.ExecuteInner;
var
  FmtCtx: PAVFormatContext;
  Stream: PAVStream;
  CodecCtx, Codec, Sws: pointer;
  Pkt: PAVPacket;
  Frame: PAVFrame;
  VideoStreamIdx, Ret: cint;
  I: integer;
  TmpBuf: PByte;
  DstData: array[0..0] of PByte;
  DstLinesize: array[0..0] of cint;
  LastPtsSec: double;
  HaveLastPts: boolean;
  TimeBase: TAVRational;
  { WebM alpha extension (BlockAdditions, BlockAddID=1) — see the
    AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL comment in ffdecode.pas for
    the confirmed (not assumed) container-level details. The alpha
    channel is a SECOND, fully independent VP8/VP9 bitstream riding as
    side data on the SAME packet as the color frame it belongs to — not
    a separate stream index, no separate demuxing/timing needed, just a
    second decoder CONTEXT fed in lockstep, one packet at a time.
    AlphaCodecCtx is opened lazily, the first time a packet is actually
    seen carrying this side data (most webm files — plain stickers,
    "GIF"s — never do, and should pay nothing extra for this). HaveAlpha
    is per-iteration, not carried over: if a given packet's alpha decode
    doesn't yield a frame this time (decoder buffering latency — rare
    for these short, simple clips), that one frame falls back to fully
    opaque rather than reusing a possibly stale alpha frame from a
    prior iteration — simpler and safer than trying to keep multi-frame
    state in sync across two independently-paced decoders. }
  AlphaCodecCtx: pointer;
  AlphaFrame: PAVFrame;
  AlphaPkt: PAVPacket;
  HaveAlpha: boolean;
  SwsHasAlpha: boolean;
  SideData: PByte;
  SideSize: SizeUInt;

  { One decoded frame -> BGRA -> shared buffer -> delay until the
    next frame, based on the source video's PTS difference (not a
    fixed interval — variable frame rate does occur in practice). }
  procedure HandleFrame;
  var
    NowPtsSec, DelaySec: double;
    DelayMs: integer;
    SrcData: array[0..3] of PByte;
    SrcLinesize: array[0..3] of cint;
    UseAlpha: boolean;
  begin
    { Alpha only actually usable if this frame's own alpha decode
      succeeded AND the two independently-encoded planes agree on
      dimensions — defensive, not just assumed from the container's
      AlphaMode flag (that only promises SOME alpha data exists
      somewhere in the file, not that every single frame's pairing is
      well-formed). Mismatched/missing alpha silently falls back to
      fully opaque for that one frame, not a hard failure. }
    { Nested ifs, not a single "and" chain — AlphaFrame is nil for the
      (overwhelmingly common) case of a webm file with no alpha at all,
      and this must never dereference it in that case regardless of
      whatever boolean-evaluation mode happens to be in effect. }
    UseAlpha := False;
    if HaveAlpha and (AlphaFrame <> nil) then begin
      if (AlphaFrame^.width = Frame^.width) and (AlphaFrame^.height = Frame^.height) then begin
        UseAlpha := True;
      end;
    end;

    if (Sws = nil) or (SwsHasAlpha <> UseAlpha) then begin
      if Sws <> nil then begin
        sws_freeContext(Sws);
      end;
      if UseAlpha then begin
        Sws := sws_getContext(Frame^.width, Frame^.height, AV_PIX_FMT_YUVA420P,
          FTargetW, FTargetH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil);
      end else begin
        Sws := sws_getContext(Frame^.width, Frame^.height, Frame^.format,
          FTargetW, FTargetH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil);
      end;
      SwsHasAlpha := UseAlpha;
      if Sws = nil then begin
        FFailed := True;
        FStopRequested := True;
        Exit;
      end;
    end;

    DstData[0] := TmpBuf;
    DstLinesize[0] := FTargetW * 4;
    if UseAlpha then begin
      { Manually assembled 4-plane "virtual" YUVA420P frame — Y/U/V
        from the color decode, unchanged; the 4th (alpha) plane is the
        alpha stream's own Y/luma output (a WebM alpha channel is
        itself encoded as an ordinary YUV420P clip whose luma directly
        IS the opacity value — its own U/V planes carry no meaning and
        are not read). swscale composites this into real per-pixel
        alpha in the BGRA output — no manual math needed on our side. }
      SrcData[0] := Frame^.data[0];
      SrcData[1] := Frame^.data[1];
      SrcData[2] := Frame^.data[2];
      SrcData[3] := AlphaFrame^.data[0];
      SrcLinesize[0] := Frame^.linesize[0];
      SrcLinesize[1] := Frame^.linesize[1];
      SrcLinesize[2] := Frame^.linesize[2];
      SrcLinesize[3] := AlphaFrame^.linesize[0];
      sws_scale(Sws, @SrcData[0], @SrcLinesize[0], 0, Frame^.height,
        @DstData[0], @DstLinesize[0]);
    end else begin
      sws_scale(Sws, @Frame^.data[0], @Frame^.linesize[0], 0, Frame^.height,
        @DstData[0], @DstLinesize[0]);
    end;

    FLock.Enter;
    try
      Move(TmpBuf^, FFrameBuf^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      Inc(FFrameVersion);
    finally
      FLock.Leave;
    end;

    { Frame.pts = Low(Int64) is the same bit pattern as AV_NOPTS_VALUE
      (libavutil/avutil.h) — no valid timestamp, so a default ~25fps
      delay is used. Otherwise (HaveLastPts), the delay comes from the
      PTS DIFFERENCE in real seconds, clamped to a sane range in case
      of a garbage PTS (negative or implausibly large), so a stuck
      decoder cannot turn into a hung widget. }
    if (Frame^.pts <> Low(Int64)) and (TimeBase.den <> 0) then begin
      NowPtsSec := Frame^.pts * (TimeBase.num / TimeBase.den);
      if HaveLastPts then begin
        DelaySec := NowPtsSec - LastPtsSec;
        if DelaySec < 0 then begin
          DelaySec := 0;
        end;
        if DelaySec > 1 then begin
          DelaySec := 1;
        end;
        DelayMs := Round(DelaySec * 1000);
      end else begin
        DelayMs := 40;
      end;
      LastPtsSec := NowPtsSec;
      HaveLastPts := True;
    end else begin
      DelayMs := 40;
    end;

    if DelayMs > 0 then begin
      Sleep(DelayMs);
    end;
  end;

begin
  FmtCtx := nil;
  Codec := nil;
  CodecCtx := nil;
  Sws := nil;
  Pkt := nil;
  Frame := nil;
  TmpBuf := nil;
  HaveLastPts := False;
  LastPtsSec := 0;
  AlphaCodecCtx := nil;
  AlphaFrame := nil;
  AlphaPkt := nil;
  SwsHasAlpha := False;

  if avformat_open_input(FmtCtx, PAnsiChar(FFilePath), nil, nil) < 0 then begin
    FFailed := True;
    Exit;
  end;
  if avformat_find_stream_info(FmtCtx, nil) < 0 then begin
    FFailed := True;
    avformat_close_input(FmtCtx);
    Exit;
  end;

  VideoStreamIdx := -1;
  for I := 0 to FmtCtx^.nb_streams - 1 do begin
    Stream := PPAVStream(FmtCtx^.streams)[I];
    if Stream^.codecpar^.codec_type = AVMEDIA_TYPE_VIDEO then begin
      VideoStreamIdx := I;
      Break;
    end;
  end;
  if VideoStreamIdx < 0 then begin
    FFailed := True;
    avformat_close_input(FmtCtx);
    Exit;
  end;

  Stream := PPAVStream(FmtCtx^.streams)[VideoStreamIdx];
  TimeBase := Stream^.time_base;

  Codec := avcodec_find_decoder(Stream^.codecpar^.codec_id);
  if Codec = nil then begin
    FFailed := True;
    avformat_close_input(FmtCtx);
    Exit;
  end;
  CodecCtx := avcodec_alloc_context3(Codec);
  if CodecCtx <> nil then begin
    { pkt_timebase is "decoding: set by user" (libavcodec/avcodec.h),
      same as in mediaplayer.pas — without it, Frame.pts can arrive in
      the decoder's own internal timebase rather than the stream's
      timebase, which HandleFrame below assumes (TimeBase :=
      Stream^.time_base); a mismatch inflates the computed inter-frame
      delay. }
    av_opt_set_q(CodecCtx, 'pkt_timebase', Stream^.time_base, 0);
  end;
  if (CodecCtx = nil) or (avcodec_parameters_to_context(CodecCtx, Stream^.codecpar) < 0) or
     (avcodec_open2(CodecCtx, Codec, nil) < 0) then begin
    FFailed := True;
    if CodecCtx <> nil then avcodec_free_context(CodecCtx);
    avformat_close_input(FmtCtx);
    Exit;
  end;

  Pkt := av_packet_alloc;
  Frame := av_frame_alloc;
  GetMem(TmpBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
  GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);

  { Main loop — on reaching the end of the container, seeks the stream
    back to the start and continues: a GIF loops for as long as the
    widget exists, it has no "finished playing" state. }
  while not FStopRequested do begin
    Ret := av_read_frame(FmtCtx, Pkt);
    if Ret < 0 then begin
      { End of container — seek back to the start. avcodec_flush_buffers
        is required here: without it the decoder keeps trying to
        reconstruct frames from data before the seek, which on
        MP4/H.264 reliably produces garbled/green frames on the first
        loop iteration. Same requirement applies to the alpha decoder,
        if one was ever opened — it's an independent decoder with its
        own internal reference-frame state. }
      av_seek_frame(FmtCtx, VideoStreamIdx, 0, AVSEEK_FLAG_BACKWARD);
      avcodec_flush_buffers(CodecCtx);
      if AlphaCodecCtx <> nil then begin
        avcodec_flush_buffers(AlphaCodecCtx);
      end;
      HaveLastPts := False;
      Continue;
    end;
    if Pkt^.stream_index = VideoStreamIdx then begin
      { WebM alpha extension — see this procedure's own var-block
        comment. Extracted BEFORE av_packet_unref(Pkt) below: the side
        data pointer is owned by Pkt and becomes invalid once that's
        unref'd. AlphaCodecCtx is opened lazily on first sight, same
        codec as the color stream (the alpha channel is encoded with
        the same codec, just as an independent bitstream) — most webm
        files (plain stickers, "GIF"s) never carry this at all and
        never pay for a second decoder. }
      HaveAlpha := False;
      SideData := av_packet_get_side_data(Pkt, AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL, @SideSize);
      if (SideData <> nil) and (SideSize > 8) then begin
        if AlphaCodecCtx = nil then begin
          AlphaCodecCtx := avcodec_alloc_context3(Codec);
          if (AlphaCodecCtx = nil) or
             (avcodec_parameters_to_context(AlphaCodecCtx, Stream^.codecpar) < 0) or
             (avcodec_open2(AlphaCodecCtx, Codec, nil) < 0) then begin
            { Alpha decoder failed to open — not fatal to the whole
              player, the color stream still plays fine, just opaque
              (same as a webm file with no alpha at all). }
            if AlphaCodecCtx <> nil then begin
              avcodec_free_context(AlphaCodecCtx);
            end;
            AlphaCodecCtx := nil;
          end else begin
            AlphaFrame := av_frame_alloc;
            AlphaPkt := av_packet_alloc;
          end;
        end;
        if AlphaCodecCtx <> nil then begin
          { The first 8 bytes are the BlockAddID prefix (confirmed via
            the real demuxer source, see ffdecode.pas) — the actual
            alpha bitstream for this frame starts right after it.
            AlphaPkt does not own this memory (it points directly into
            Pkt's own side-data buffer) — never av_packet_unref it. }
          AlphaPkt^.data := SideData + 8;
          AlphaPkt^.size := cint(SideSize - 8);
          if avcodec_send_packet(AlphaCodecCtx, AlphaPkt) >= 0 then begin
            HaveAlpha := avcodec_receive_frame(AlphaCodecCtx, AlphaFrame) >= 0;
          end;
        end;
      end;

      if avcodec_send_packet(CodecCtx, Pkt) >= 0 then begin
        while True do begin
          Ret := avcodec_receive_frame(CodecCtx, Frame);
          if Ret < 0 then begin
            Break;
          end;
          HandleFrame;
          av_frame_unref(Frame);
          if FStopRequested or FFailed then begin
            Break;
          end;
        end;
      end;
    end;
    av_packet_unref(Pkt);
  end;

  if Sws <> nil then sws_freeContext(Sws);
  av_frame_free(Frame);
  av_packet_free(Pkt);
  avcodec_free_context(CodecCtx);
  if AlphaFrame <> nil then begin
    av_frame_free(AlphaFrame);
  end;
  if AlphaPkt <> nil then begin
    av_packet_free(AlphaPkt);
  end;
  if AlphaCodecCtx <> nil then begin
    avcodec_free_context(AlphaCodecCtx);
  end;
  avformat_close_input(FmtCtx);
  FreeMem(TmpBuf);
end;

end.
