unit mediaplayer;

{$mode objfpc}{$H+}

{ Plays a single video message (messageVideo — real video with sound,
  as opposed to a "GIF"/messageAnimation in videoplayer.pas): TWO
  independent decoder threads per file, not one.

  An earlier version used a SINGLE thread combining audio output via
  winmm (the same WAVEHDR pipeline as TAudioPlayer, audioplayer.pas)
  and video-frame decoding to BGRA via libswscale (the same approach as
  TAnimationPlayer, videoplayer.pas), with frame display delayed by a
  blocking Sleep until audio "caught up" to it. In practice this
  periodically starved the audio buffer: while the thread slept for
  video, it wasn't reading new packets or feeding winmm — once the
  device exhausted its buffered supply (~0.8s across 4 buffers) and ran
  dry, its HARDWARE clock (waveOutGetPosition) stopped advancing in
  real time IRREVERSIBLY, and video, faithfully following it, fell
  behind along with it — the whole thing played noticeably slower than
  real time (~2x, see video_debug.log in the project history). A first
  fix attempt (video simply stopped waiting and displayed frames
  immediately) fixed the audio speed but made video jerky — it decoded
  in bursts between long pauses spent feeding audio, and the shared
  frame buffer updated very unevenly.

  The real fix is to physically SEPARATE the two threads: TMediaPlayer
  itself (class(TThread)) now handles ONLY audio — the same WAVEHDR
  pipeline as before, untouched by video. TVideoDecodeThread is a
  separate thread that opens the SAME file again, INDEPENDENTLY (its
  own AVFormatContext, the same approach TAnimationPlayer already
  uses in videoplayer.pas) — it decodes frames and waits (a blocking
  Sleep, the exact same Delay formula as before) for the display moment
  relative to the owner's audio clock (TMediaPlayer.AudioClockSec) —
  but this wait no longer blocks feeding audio at all, since they're on
  physically different threads. The only coordination between the two
  threads is a read of the audio clock plus a local TCriticalSection
  around the shared frame buffer (FFrameBuf/FFrameVersion), the same
  approach already used in the single-thread version.

  There's no looping (unlike a "GIF") and, unlike a "GIF" (which has
  none at all), the class DOES expose Pause/Resume/StopPlayback, same
  as TAudioPlayer: a video message is an ordinary player with pause and
  seeking, plays through once and stops (mpsStopped), waiting for BOTH
  threads to finish.

  FreeOnTerminate=False on TMediaPlayer, like TAudioPlayer (NOT like
  TAnimationPlayer) — for the same reason: at most ONE video with sound
  plays at a time (the sole owner is TMediaViewerPanel, mediaviewer.pas,
  a single slot for the whole app; inline video playback in the chat no
  longer exists at all, see framehistory.pas), Stop is a deliberate
  user action, and a synchronous WaitFor there is not a problem.
  TVideoDecodeThread is also FreeOnTerminate=False — its WaitFor/Free
  is called from TMediaPlayer's own ExecuteInner (not the UI thread,
  not someone else's Synchronize — safe). }

interface

uses
  Classes, SysUtils, SyncObjs, Windows, MMSystem, ffdecode, audiodevices, ctypes;

const
  { Same output format and buffering as TAudioPlayer (audioplayer.pas)
    — not two different numbers for the same meaning. }
  MEDIA_BUF_SAMPLES = 8820;
  MEDIA_BUF_COUNT = 4;
  MEDIA_OUT_RATE = 44100;
  MEDIA_OUT_CHANNELS = 2;
  MEDIA_BUF_BYTES = MEDIA_BUF_SAMPLES * MEDIA_OUT_CHANNELS * 2;   { S16 }

type
  TMediaPlayerState = (mpsPlaying, mpsPaused, mpsStopped, mpsError);

  TMediaPlayer = class;

  { The video half — a separate thread, independent from audio, see
    the unit header. Opens the file a SECOND TIME, on its own (its own
    AVFormatContext) — the same approach as TAnimationPlayer. }
  TVideoDecodeThread = class(TThread)
  private
    FOwner: TMediaPlayer;
    FStartPositionSec: double;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMediaPlayer; AStartPositionSec: double);
  end;

  TMediaPlayer = class(TThread)
  private
    FFilePath: utf8string;
    FDeviceName: utf8string;
    FStartPositionSec: double;
    FTargetW, FTargetH: integer;

    { Video: only ONE continuously overwritten frame lives under the
      critical section, written by TVideoDecodeThread, read by the UI
      thread through TryGetFrame. Explicitly qualified as
      SyncObjs.TCriticalSection — Windows (also in uses, needed for
      waveOut*/MMTIME) comes BEFORE SyncObjs in the uses list above and
      declares its OWN, different, incompatible TCriticalSection (an
      internal RTL type from sysosh.inc, not a class with
      Enter/Leave/Create) — the same uses-order pitfall documented in
      framehistory.pas, just in reverse order here (Windows not first),
      so the unqualified name resolves to the wrong type. }
    FFrameLock: SyncObjs.TCriticalSection;
    FFrameBuf: PByte;          { BGRA, FTargetW*FTargetH*4 bytes, allocated by TVideoDecodeThread }
    FFrameVersion: cardinal;
    FHasVideo: boolean;
    FVideoPositionSec: double; { written by TVideoDecodeThread; read by PositionSec when there's no audio }
    FVideoThread: TVideoDecodeThread;

    { Audio: the same WAVEHDR pipeline as TAudioPlayer, living entirely
      on THIS (TMediaPlayer's main) thread. }
    FWaveOut: HWAVEOUT;
    { FWaveOut is read/closed from TWO threads — this one (audio decode,
      closes it at end of file) and the UI thread
      (TMediaViewerPanel.VideoTick -> PositionSec -> AudioClockSec,
      every 33ms while video is active, plus Pause/Resume on click).
      Without locking, closing the device (waveOutClose) could race
      against reading the same handle in waveOutGetPosition on the
      other thread — a real crash caught in the field (Access
      Violation inside AudioClockSec, inside winmm, right after
      playback ended — exactly the moment this thread closes the
      device). FWaveLock guards every place where FWaveOut is read OR
      written from more than one thread. }
    FWaveLock: SyncObjs.TCriticalSection;
    FHeaders: array[0..MEDIA_BUF_COUNT - 1] of TWAVEHDR;
    FBufMem: array[0..MEDIA_BUF_COUNT - 1] of PByte;
    FHasAudio: boolean;
    FAudioPositionSamples: Int64;   { samples ALREADY HANDED to the winmm queue — fallback clock, see AudioClockSec }
    { Offset (in samples) of the seek point from the start of the file
      — set ONCE in the constructor, NEVER changed afterward (unlike
      FAudioPositionSamples, which grows as data is handed to winmm).
      Needed by AudioClockSec: waveOutGetPosition/TIME_SAMPLES counts
      samples RELATIVE TO THE MOMENT waveOutOpen was called — winmm has
      no idea we started not from the beginning of the file but from
      the 10th/20th second (a seek). Without adding this offset,
      AudioClockSec would restart counting from 0 after EVERY seek — a
      real, reproducible bug ("seeking 10 seconds doesn't work, video
      stalls and the slider snaps back to the start") — the clock
      "forgot" about the seek, and the video thread computed Delay
      against it (NowPtsSec from the seek point minus AClock counting
      from 0); the resulting ~10s gap hit the safety cap (1s per frame)
      and stayed there until AClock caught up to it on its own, one
      real second at a time — perceived as "stalling at the start" for
      exactly those 10 seconds. }
    FSeekBaseSamples: Int64;
    { The moment (GetTickCount64) FWaveOut closed for good (see
      CloseAudioDevice) — i.e. the audio track has fully played out.
      Needed by AudioClockSec: without it, the clock would stay FROZEN
      at FAudioPositionSamples forever once the device closes, see the
      comment on the "video hangs a second before the end" bug below. }
    FAudioEndTick: QWord;

    FState: TMediaPlayerState;
    FDurationSec: double;
    FPauseRequested: boolean;
    FStopRequested: boolean;
    FOnStateChanged: TNotifyEvent;
    FLastError: utf8string;
    FFifo: array of Byte;
    FFifoLen: cardinal;

    procedure DoStateChanged;
    procedure FifoAppend(AData: PByte; ALen: cardinal);
    function FifoTakeInto(ADst: PByte; AMax: cardinal): cardinal;
    function OpenAudioDevice: boolean;
    procedure CloseAudioDevice(AGraceful: boolean);
    function WaitBufferFree(AIndex: integer): boolean;
    function WriteBuffer(AIndex: integer; ALen: cardinal): boolean;
    { The real audio playback position — waveOutGetPosition (how many
      samples the device has ACTUALLY physically played), not
      FAudioPositionSamples (that's how much has been HANDED to the
      queue, which runs up to ~0.8s ahead, see MEDIA_BUF_COUNT). This is
      also the master clock video syncs to (read by TVideoDecodeThread,
      from a DIFFERENT thread — see FWaveLock). The fallback
      (FAudioPositionSamples), used if the driver doesn't support
      TIME_SAMPLES, is less accurate (ignores buffering) but never
      fails. }
    function AudioClockSec: double;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath, ADeviceName: utf8string;
      ATargetW, ATargetH: integer; AStartPositionSec: double = 0);
    destructor Destroy; override;
    procedure Pause;
    procedure Resume;
    procedure StopPlayback;
    { The clock: the real audio position (AudioClockSec) if there's
      audio, otherwise the position of the last displayed video frame. }
    function PositionSec: double;
    { Same role/contract as TAnimationPlayer.TryGetFrame (videoplayer.
      pas) — copies the frame into ADst if it's newer than
      AKnownVersion. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property DurationSec: double read FDurationSec;
    property State: TMediaPlayerState read FState;
    property HasVideo: boolean read FHasVideo;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property LastError: utf8string read FLastError;
    property OnStateChanged: TNotifyEvent read FOnStateChanged write FOnStateChanged;
  end;

{ The REAL pixel size of a video file's first frame.

  Needed because TDLib's content.video.width/height is not measured by
  TDLib at all — it is whatever the uploading client declared, and it
  can simply be wrong. Confirmed on this account's own history: every
  LostFilm release in it reports 715x330 while the actual stream is
  1280x720 (checked against the mp4 boxes of the cached files, not
  assumed), which showed the picture both squashed and far too small.

  Reads the size off a decoded frame rather than off AVCodecParameters:
  ffdecode.pas deliberately declares only the first three fields of
  that struct, and width/height sit well past them, behind fields that
  have been added between FFmpeg releases — a guessed offset there
  would be silent memory corruption, while AVFrame.width/height is
  already declared and already relied on elsewhere. The cost is opening
  the file and decoding a single frame, once per video opened. }
function ProbeVideoSize(const APath: utf8string; out AWidth, AHeight: integer): boolean;

implementation

const
  { See the GetMem(VTmpBuf, ...) comment further down (ExecuteInner) —
    a safety margin against libswscale's documented SIMD tail-write-
    past-bounds behavior (CVE-2017-7866, GHSA-3w97-3qww-vxj8), the same
    fix applied to the identical pattern in videoplayer.pas after a
    live heaptrc-caught heap corruption there. }
  SWS_SCALE_TAIL_PAD = 64;

function ProbeVideoSize(const APath: utf8string; out AWidth, AHeight: integer): boolean;
var
  FmtCtx: PAVFormatContext;
  VStream: PAVStream;
  VCodecCtx, VCodec: pointer;
  Pkt: PAVPacket;
  Frame: PAVFrame;
  VideoStreamIdx, I: integer;
  Guard: integer;
begin
  Result := False;
  AWidth := 0;
  AHeight := 0;
  FmtCtx := nil;
  VCodecCtx := nil;
  Pkt := nil;
  Frame := nil;
  VideoStreamIdx := -1;

  if APath = '' then begin
    Exit;
  end;
  if avformat_open_input(FmtCtx, PAnsiChar(APath), nil, nil) < 0 then begin
    Exit;
  end;
  try
    if avformat_find_stream_info(FmtCtx, nil) < 0 then begin
      Exit;
    end;
    for I := 0 to FmtCtx^.nb_streams - 1 do begin
      if (Pointer(PPAVStream(FmtCtx^.streams)[I]) <> nil) and
         (PPAVStream(FmtCtx^.streams)[I]^.codecpar^.codec_type = AVMEDIA_TYPE_VIDEO) then begin
        VideoStreamIdx := I;
        Break;
      end;
    end;
    if VideoStreamIdx < 0 then begin
      Exit;
    end;
    VStream := PPAVStream(FmtCtx^.streams)[VideoStreamIdx];
    VCodec := avcodec_find_decoder(VStream^.codecpar^.codec_id);
    if VCodec = nil then begin
      Exit;
    end;
    VCodecCtx := avcodec_alloc_context3(VCodec);
    if VCodecCtx = nil then begin
      Exit;
    end;
    if (avcodec_parameters_to_context(VCodecCtx, VStream^.codecpar) < 0) or
       (avcodec_open2(VCodecCtx, VCodec, nil) < 0) then begin
      Exit;
    end;
    Pkt := av_packet_alloc;
    Frame := av_frame_alloc;
    if (Pkt = nil) or (Frame = nil) then begin
      Exit;
    end;
    { Bounded: a file whose first video frame never decodes (truncated,
      broken) must not spin here — the caller falls back to TDLib's
      declared size in that case. }
    Guard := 0;
    while (not Result) and (Guard < 500) and (av_read_frame(FmtCtx, Pkt) >= 0) do begin
      Inc(Guard);
      if Pkt^.stream_index = VideoStreamIdx then begin
        if avcodec_send_packet(VCodecCtx, Pkt) >= 0 then begin
          while avcodec_receive_frame(VCodecCtx, Frame) >= 0 do begin
            if (Frame^.width > 0) and (Frame^.height > 0) then begin
              AWidth := Frame^.width;
              AHeight := Frame^.height;
              Result := True;
              Break;
            end;
          end;
        end;
      end;
      av_packet_unref(Pkt);
    end;
  finally
    if Frame <> nil then begin
      av_frame_free(Frame);
    end;
    if Pkt <> nil then begin
      av_packet_free(Pkt);
    end;
    if VCodecCtx <> nil then begin
      avcodec_free_context(VCodecCtx);
    end;
    avformat_close_input(FmtCtx);
  end;
end;

{ ---------------- TVideoDecodeThread ---------------- }

constructor TVideoDecodeThread.Create(AOwner: TMediaPlayer; AStartPositionSec: double);
begin
  inherited Create(True);
  FOwner := AOwner;
  FStartPositionSec := AStartPositionSec;
  FreeOnTerminate := False;
  Start;
end;

procedure TVideoDecodeThread.Execute;
begin
  try
    ExecuteInner;
  except
    { A video-decode error must not take audio down with it — the same
      principle as "Sws=nil -> skip the frame, not the whole video"
      below. }
  end;
end;

procedure TVideoDecodeThread.ExecuteInner;
var
  FmtCtx: PAVFormatContext;
  VStream: PAVStream;
  VCodecCtx, VCodec, Sws: pointer;
  Pkt: PAVPacket;
  Frame: PAVFrame;
  VideoStreamIdx, Ret: cint;
  I: integer;
  VTmpBuf: PByte;
  VDstData: array[0..0] of PByte;
  VDstLinesize: array[0..0] of cint;
  VTimeBase: TAVRational;
  NowPtsSec, Delay, AClock: double;
  HaveOwnPts: boolean;
  LastOwnPtsSec: double;
begin
  FmtCtx := nil;
  VCodecCtx := nil;
  Sws := nil;
  VTmpBuf := nil;
  VideoStreamIdx := -1;
  HaveOwnPts := False;
  LastOwnPtsSec := 0;

  if avformat_open_input(FmtCtx, PAnsiChar(FOwner.FFilePath), nil, nil) < 0 then begin
    Exit;
  end;
  if avformat_find_stream_info(FmtCtx, nil) < 0 then begin
    avformat_close_input(FmtCtx);
    Exit;
  end;

  for I := 0 to FmtCtx^.nb_streams - 1 do begin
    if (Pointer(PPAVStream(FmtCtx^.streams)[I]) <> nil) and
       (PPAVStream(FmtCtx^.streams)[I]^.codecpar^.codec_type = AVMEDIA_TYPE_VIDEO) then begin
      VideoStreamIdx := I;
      Break;
    end;
  end;
  if VideoStreamIdx < 0 then begin
    avformat_close_input(FmtCtx);
    Exit;
  end;

  VStream := PPAVStream(FmtCtx^.streams)[VideoStreamIdx];
  VTimeBase := VStream^.time_base;
  VCodec := avcodec_find_decoder(VStream^.codecpar^.codec_id);
  if VCodec = nil then begin
    avformat_close_input(FmtCtx);
    Exit;
  end;
  VCodecCtx := avcodec_alloc_context3(VCodec);
  if VCodecCtx = nil then begin
    avformat_close_input(FmtCtx);
    Exit;
  end;
  { pkt_timebase: without it, some codecs report Frame.pts in their own
    internal time base rather than the stream's time base. }
  av_opt_set_q(VCodecCtx, 'pkt_timebase', VStream^.time_base, 0);
  if (avcodec_parameters_to_context(VCodecCtx, VStream^.codecpar) < 0) or
     (avcodec_open2(VCodecCtx, VCodec, nil) < 0) then begin
    avcodec_free_context(VCodecCtx);
    avformat_close_input(FmtCtx);
    Exit;
  end;

  { VTmpBuf is sws_scale's OWN write target (below) — padded past its
    nominal W*H*4 size, unlike FOwner.FFrameBuf (only ever reached via
    an exact-length Move, never sws_scale) — see SWS_SCALE_TAIL_PAD's
    own comment for why. }
  GetMem(VTmpBuf, cardinal(FOwner.FTargetW) * cardinal(FOwner.FTargetH) * 4 + SWS_SCALE_TAIL_PAD);
  GetMem(FOwner.FFrameBuf, cardinal(FOwner.FTargetW) * cardinal(FOwner.FTargetH) * 4);

  if FStartPositionSec > 0 then begin
    av_seek_frame(FmtCtx, -1, Round(FStartPositionSec * 1000000), AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(VCodecCtx);
  end;

  Pkt := av_packet_alloc;
  Frame := av_frame_alloc;

  while (not Terminated) and (not FOwner.FStopRequested) and
        (av_read_frame(FmtCtx, Pkt) >= 0) do begin
    if Pkt^.stream_index = VideoStreamIdx then begin
      if avcodec_send_packet(VCodecCtx, Pkt) >= 0 then begin
        while True do begin
          Ret := avcodec_receive_frame(VCodecCtx, Frame);
          if Ret < 0 then begin
            Break;
          end;

          if Sws = nil then begin
            Sws := sws_getContext(Frame^.width, Frame^.height, Frame^.format,
              FOwner.FTargetW, FOwner.FTargetH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil);
          end;

          if Sws <> nil then begin
            VDstData[0] := VTmpBuf;
            VDstLinesize[0] := FOwner.FTargetW * 4;
            sws_scale(Sws, @Frame^.data[0], @Frame^.linesize[0], 0, Frame^.height,
              @VDstData[0], @VDstLinesize[0]);

            if (Frame^.pts <> Low(Int64)) and (VTimeBase.den <> 0) then begin
              NowPtsSec := Frame^.pts * (VTimeBase.num / VTimeBase.den);
              { With audio, wait on the owner's audio clock; this BLOCKS
                only THIS thread, not the one feeding audio — safe now
                that they're physically separate threads. Without
                audio, fall back to the same PTS delta between
                consecutive frames as before (TAnimationPlayer). }
              if FOwner.FHasAudio then begin
                AClock := FOwner.AudioClockSec;
                Delay := NowPtsSec - AClock;
              end else if HaveOwnPts then begin
                AClock := LastOwnPtsSec;
                Delay := NowPtsSec - LastOwnPtsSec;
              end else begin
                AClock := 0;
                Delay := 0;
              end;
              if Delay > 1 then begin
                Delay := 1;   { safety cap against an implausible PTS/desynced clock }
              end;
              if Delay > 0 then begin
                Sleep(Round(Delay * 1000));
              end;
              LastOwnPtsSec := NowPtsSec;
              HaveOwnPts := True;
              FOwner.FVideoPositionSec := NowPtsSec;
            end;

            FOwner.FFrameLock.Enter;
            try
              Move(VTmpBuf^, FOwner.FFrameBuf^, cardinal(FOwner.FTargetW) * cardinal(FOwner.FTargetH) * 4);
              Inc(FOwner.FFrameVersion);
            finally
              FOwner.FFrameLock.Leave;
            end;
          end;

          av_frame_unref(Frame);

          while FOwner.FPauseRequested and (not FOwner.FStopRequested) and (not Terminated) do begin
            Sleep(20);
          end;
        end;
      end;
    end;
    av_packet_unref(Pkt);
  end;

  av_frame_free(Frame);
  av_packet_free(Pkt);
  if Sws <> nil then begin
    sws_freeContext(Sws);
  end;
  avcodec_free_context(VCodecCtx);
  avformat_close_input(FmtCtx);
  FreeMem(VTmpBuf);
end;

{ ---------------- TMediaPlayer ---------------- }

constructor TMediaPlayer.Create(const AFilePath, ADeviceName: utf8string;
  ATargetW, ATargetH: integer; AStartPositionSec: double = 0);
begin
  inherited Create(True);
  FFilePath := AFilePath;
  FDeviceName := ADeviceName;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FStartPositionSec := AStartPositionSec;
  { Same approach as TAudioPlayer.Create — the position is set here,
    before Start, so a PositionSec read right after Create
    (TMediaViewerPanel.StartVideoPlayer/VideoTick) doesn't catch a
    several-millisecond window showing 0 instead of the seek position. }
  FAudioPositionSamples := Round(AStartPositionSec * MEDIA_OUT_RATE);
  FSeekBaseSamples := FAudioPositionSamples;
  FVideoPositionSec := AStartPositionSec;
  FFrameLock := SyncObjs.TCriticalSection.Create;
  FWaveLock := SyncObjs.TCriticalSection.Create;
  FreeOnTerminate := False;
  FState := mpsPlaying;
  Start;
end;

destructor TMediaPlayer.Destroy;
begin
  { By the time Destroy is called, Execute has already finished (per
    the FreeOnTerminate=False contract — the caller must WaitFor
    before Free, and TMediaViewerPanel.FlushDonePlayer does exactly
    that), so ExecuteInner has already waited for and freed
    FVideoThread on the normal path. This check is only a safety net
    for an early error Exit BEFORE the video thread was ever created
    (in which case FVideoThread=nil and there's nothing to do). }
  if FVideoThread <> nil then begin
    FVideoThread.WaitFor;
    FVideoThread.Free;
    FVideoThread := nil;
  end;
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  FFrameLock.Free;
  FWaveLock.Free;
  inherited Destroy;
end;

procedure TMediaPlayer.DoStateChanged;
begin
  if Assigned(FOnStateChanged) then begin
    FOnStateChanged(Self);
  end;
end;

procedure TMediaPlayer.FifoAppend(AData: PByte; ALen: cardinal);
begin
  if ALen = 0 then begin
    Exit;
  end;
  if cardinal(Length(FFifo)) < FFifoLen + ALen then begin
    SetLength(FFifo, FFifoLen + ALen);
  end;
  Move(AData^, FFifo[FFifoLen], ALen);
  Inc(FFifoLen, ALen);
end;

function TMediaPlayer.FifoTakeInto(ADst: PByte; AMax: cardinal): cardinal;
begin
  Result := FFifoLen;
  if Result > AMax then begin
    Result := AMax;
  end;
  if Result = 0 then begin
    Exit;
  end;
  Move(FFifo[0], ADst^, Result);
  Move(FFifo[Result], FFifo[0], FFifoLen - Result);
  Dec(FFifoLen, Result);
end;

function TMediaPlayer.OpenAudioDevice: boolean;
var
  Fmt: TWAVEFORMATEX;
  Devs: TAudioDeviceArray;
  DevId: UINT;
  I: integer;
begin
  DevId := WAVE_MAPPER;
  if FDeviceName <> '' then begin
    Devs := EnumAudioOutputDevices;
    for I := 0 to High(Devs) do begin
      if Devs[I].Name = FDeviceName then begin
        DevId := Devs[I].Id;
        Break;
      end;
    end;
  end;

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := 1;   { WAVE_FORMAT_PCM }
  Fmt.nChannels := MEDIA_OUT_CHANNELS;
  Fmt.nSamplesPerSec := MEDIA_OUT_RATE;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := (Fmt.nChannels * Fmt.wBitsPerSample) div 8;
  Fmt.nAvgBytesPerSec := Fmt.nSamplesPerSec * Fmt.nBlockAlign;

  Result := waveOutOpen(@FWaveOut, DevId, @Fmt, 0, 0, CALLBACK_NULL) = 0;
end;

procedure TMediaPlayer.CloseAudioDevice(AGraceful: boolean);
var
  I: integer;
  WaitMs: integer;
  AllDone: boolean;
begin
  if FWaveOut = 0 then begin
    Exit;
  end;
  { Same logic as TAudioPlayer.CloseDevice (audioplayer.pas) — see its
    detailed comment there about why Reset is not called unconditionally.
    Not duplicated here line for line — it's enough to know this is the
    same, already-verified code, not a new guess.

    The WAITING loop itself (WaitMs<5000) does NOT hold FWaveLock — it
    only touches FHeaders (buffer flags), not FWaveOut, and can take up
    to 5 seconds in the rare case of a stuck driver; holding the lock
    that whole time would stall AudioClockSec (and with it the UI
    thread polling it every 33ms while video is active) for the same
    5 seconds. The lock is held only for the actual close, which is
    short and doesn't block readers. }
  AllDone := True;
  if AGraceful then begin
    for I := 0 to MEDIA_BUF_COUNT - 1 do begin
      WaitMs := 0;
      while ((FHeaders[I].dwFlags and WHDR_PREPARED) <> 0) and
            ((FHeaders[I].dwFlags and WHDR_DONE) = 0) and (WaitMs < 5000) do begin
        Sleep(10);
        Inc(WaitMs, 10);
      end;
      if ((FHeaders[I].dwFlags and WHDR_PREPARED) <> 0) and
        ((FHeaders[I].dwFlags and WHDR_DONE) = 0) then begin
        AllDone := False;
      end;
    end;
  end;
  FWaveLock.Enter;
  try
    if FWaveOut = 0 then begin
      Exit;
    end;
    if (not AGraceful) or (not AllDone) then begin
      waveOutReset(FWaveOut);
    end;
    for I := 0 to MEDIA_BUF_COUNT - 1 do begin
      if (FHeaders[I].dwFlags and WHDR_PREPARED) <> 0 then begin
        waveOutUnprepareHeader(FWaveOut, @FHeaders[I], SizeOf(TWAVEHDR));
      end;
    end;
    waveOutClose(FWaveOut);
    FWaveOut := 0;
    FAudioEndTick := GetTickCount64;
  finally
    FWaveLock.Leave;
  end;
end;

function TMediaPlayer.WaitBufferFree(AIndex: integer): boolean;
begin
  while (not FStopRequested) and ((FHeaders[AIndex].dwFlags and WHDR_PREPARED) <> 0) and
        ((FHeaders[AIndex].dwFlags and WHDR_DONE) = 0) do begin
    Sleep(5);
  end;
  Result := not FStopRequested;
end;

function TMediaPlayer.WriteBuffer(AIndex: integer; ALen: cardinal): boolean;
begin
  if (FHeaders[AIndex].dwFlags and WHDR_PREPARED) <> 0 then begin
    waveOutUnprepareHeader(FWaveOut, @FHeaders[AIndex], SizeOf(TWAVEHDR));
  end;

  FillChar(FHeaders[AIndex], SizeOf(TWAVEHDR), 0);
  FHeaders[AIndex].lpData := PChar(FBufMem[AIndex]);
  FHeaders[AIndex].dwBufferLength := ALen;

  if waveOutPrepareHeader(FWaveOut, @FHeaders[AIndex], SizeOf(TWAVEHDR)) <> 0 then begin
    Result := False;
    Exit;
  end;
  if waveOutWrite(FWaveOut, @FHeaders[AIndex], SizeOf(TWAVEHDR)) <> 0 then begin
    Result := False;
    Exit;
  end;
  Inc(FAudioPositionSamples, ALen div (MEDIA_OUT_CHANNELS * 2));
  Result := True;
end;

function TMediaPlayer.AudioClockSec: double;
var
  Mmt: TMMTime;
begin
  Result := FAudioPositionSamples / MEDIA_OUT_RATE;
  { The lock is held for the whole read — not just the FWaveOut=0
    check but the waveOutGetPosition call itself — otherwise the window
    between "read the handle" and "passed it to the API" would reopen
    the same race against CloseAudioDevice as before (see its comment
    about the end-of-playback AV crash). }
  FWaveLock.Enter;
  try
    if FWaveOut = 0 then begin
      { The device is already closed — the audio track has fully
        played out (while FHasAudio; by the time TVideoDecodeThread
        starts calling this function at all, the device is guaranteed
        to have already been OPENED — see the order in ExecuteInner,
        OpenAudioDevice runs before FVideoThread.Create — so FWaveOut=0
        here means "already closed", not "not open yet"). This used to
        simply return the FROZEN FAudioPositionSamples — if the audio
        track is shorter than the video (common with muxed files, the
        gap can be ~1s or more), trailing video frames computed Delay
        against a clock that NEVER moved again: Delay grew with every
        frame, hit the cap (1s), and stayed there — EVERY trailing
        frame slept a full second instead of showing instantly, which
        looked like "video hangs a second before the end" (a real,
        reproducible bug). Fix: the clock keeps advancing by real wall
        time from the moment of closing (FAudioEndTick, set in
        CloseAudioDevice under the same lock) — a silent tail plays out
        in real time, Delay quickly drops to <=0, and frames after that
        show without waiting. }
      Result := FAudioPositionSamples / MEDIA_OUT_RATE +
        (GetTickCount64 - FAudioEndTick) / 1000.0;
      Exit;
    end;
    Mmt.wType := TIME_SAMPLES;
    if (waveOutGetPosition(FWaveOut, @Mmt, SizeOf(Mmt)) = 0) and (Mmt.wType = TIME_SAMPLES) then begin
      { Mmt.sample counts samples played SINCE waveOutOpen, NOT since
        the start of the file — adding FSeekBaseSamples is mandatory
        (see its comment); without it, this was the "seeking doesn't
        work" bug. }
      Result := (FSeekBaseSamples + Mmt.sample) / MEDIA_OUT_RATE;
    end;
  finally
    FWaveLock.Leave;
  end;
end;

function TMediaPlayer.TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
begin
  Result := False;
  FFrameLock.Enter;
  try
    if (FFrameBuf <> nil) and (FFrameVersion <> 0) and (FFrameVersion <> AKnownVersion) then begin
      Move(FFrameBuf^, ADst^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      AKnownVersion := FFrameVersion;
      Result := True;
    end;
  finally
    FFrameLock.Leave;
  end;
end;

procedure TMediaPlayer.Execute;
begin
  try
    ExecuteInner;
  except
    on E: Exception do begin
      FLastError := utf8string(E.ClassName) + ': ' + utf8string(E.Message);
      FState := mpsError;
      Synchronize(@DoStateChanged);
    end;
  end;
end;

procedure TMediaPlayer.ExecuteInner;
var
  FmtCtx: PAVFormatContext;
  AStream: PAVStream;
  ACodecCtx, ACodec, Swr: pointer;
  Pkt: PAVPacket;
  Frame: PAVFrame;
  AudioStreamIdx, VideoStreamIdx, Ret: cint;
  I: integer;
  OutChLayout, InChLayout: TAVChannelLayout;
  OutTmp: PByte;
  OutTmpCap: cint;
  OutSamples: cint;
  WriteIdx: integer;
  SwrReady: boolean;

  procedure PumpFifoToDevice(AFlush: boolean);
  var
    N: cardinal;
  begin
    while (not FStopRequested) and
          ((FFifoLen >= MEDIA_BUF_BYTES) or (AFlush and (FFifoLen > 0))) do begin
      if not WaitBufferFree(WriteIdx) then begin
        Break;
      end;
      N := FifoTakeInto(FBufMem[WriteIdx], MEDIA_BUF_BYTES);
      if N = 0 then begin
        Break;
      end;
      if not WriteBuffer(WriteIdx, N) then begin
        Break;
      end;
      WriteIdx := (WriteIdx + 1) mod MEDIA_BUF_COUNT;
    end;
  end;

  procedure HandleAudioFrame;
  begin
    if not SwrReady then begin
      InChLayout := Frame^.ch_layout;
      Ret := swr_alloc_set_opts2(Swr, @OutChLayout, AV_SAMPLE_FMT_S16, MEDIA_OUT_RATE,
        @InChLayout, Frame^.format, Frame^.sample_rate, 0, nil);
      if (Ret >= 0) and (swr_init(Swr) >= 0) then begin
        SwrReady := True;
      end;
    end;
    if SwrReady then begin
      OutSamples := swr_convert(Swr, @OutTmp, OutTmpCap, @Frame^.data[0], Frame^.nb_samples);
      if OutSamples > 0 then begin
        FifoAppend(OutTmp, cardinal(OutSamples) * MEDIA_OUT_CHANNELS * 2);
      end;
    end;
    while FPauseRequested and (not FStopRequested) do begin
      Sleep(20);
    end;
    PumpFifoToDevice(False);
  end;

begin
  FmtCtx := nil;
  ACodec := nil;
  ACodecCtx := nil;
  Swr := nil;
  Pkt := nil;
  Frame := nil;
  WriteIdx := 0;
  SwrReady := False;
  AudioStreamIdx := -1;
  VideoStreamIdx := -1;

  if avformat_open_input(FmtCtx, PAnsiChar(FFilePath), nil, nil) < 0 then begin
    FState := mpsError;
    Synchronize(@DoStateChanged);
    Exit;
  end;
  if avformat_find_stream_info(FmtCtx, nil) < 0 then begin
    FState := mpsError;
    Synchronize(@DoStateChanged);
    avformat_close_input(FmtCtx);
    Exit;
  end;
  FDurationSec := FmtCtx^.duration / 1000000.0;

  for I := 0 to FmtCtx^.nb_streams - 1 do begin
    if Pointer(PPAVStream(FmtCtx^.streams)[I]) = nil then begin
      Continue;
    end;
    if (AudioStreamIdx < 0) and
      (PPAVStream(FmtCtx^.streams)[I]^.codecpar^.codec_type = AVMEDIA_TYPE_AUDIO) then begin
      AudioStreamIdx := I;
    end else if (VideoStreamIdx < 0) and
      (PPAVStream(FmtCtx^.streams)[I]^.codecpar^.codec_type = AVMEDIA_TYPE_VIDEO) then begin
      VideoStreamIdx := I;
    end;
  end;
  FHasAudio := AudioStreamIdx >= 0;
  { Presence-based, not codec-verified — the video decoder itself is
    opened and checked INDEPENDENTLY, inside TVideoDecodeThread; if the
    codec fails to open there, the widget simply never gets a frame
    (TryGetFrame silently returns False forever) — the same level of
    fault tolerance already accepted elsewhere in the project
    (TAnimationPlayer.Failed is likewise never checked on the UI side). }
  FHasVideo := VideoStreamIdx >= 0;

  if FHasAudio then begin
    AStream := PPAVStream(FmtCtx^.streams)[AudioStreamIdx];
    ACodec := avcodec_find_decoder(AStream^.codecpar^.codec_id);
    if ACodec <> nil then begin
      ACodecCtx := avcodec_alloc_context3(ACodec);
      if (ACodecCtx = nil) or (avcodec_parameters_to_context(ACodecCtx, AStream^.codecpar) < 0) or
         (avcodec_open2(ACodecCtx, ACodec, nil) < 0) then begin
        if ACodecCtx <> nil then avcodec_free_context(ACodecCtx);
        ACodecCtx := nil;
      end;
    end;
    FHasAudio := (ACodecCtx <> nil) and OpenAudioDevice;
    if FHasAudio then begin
      for I := 0 to MEDIA_BUF_COUNT - 1 do begin
        GetMem(FBufMem[I], MEDIA_BUF_BYTES);
      end;
      FillChar(OutChLayout, SizeOf(OutChLayout), 0);
      OutChLayout.order := AV_CHANNEL_ORDER_NATIVE;
      OutChLayout.nb_channels := MEDIA_OUT_CHANNELS;
      OutChLayout.u := AV_CH_LAYOUT_STEREO_MASK;
      OutTmpCap := MEDIA_BUF_SAMPLES * 2;
      GetMem(OutTmp, cardinal(OutTmpCap) * MEDIA_OUT_CHANNELS * 2);
    end;
  end;

  if (not FHasAudio) and (not FHasVideo) then begin
    FState := mpsError;
    Synchronize(@DoStateChanged);
    if ACodecCtx <> nil then avcodec_free_context(ACodecCtx);
    avformat_close_input(FmtCtx);
    Exit;
  end;

  { Video now runs entirely in its own thread, with its OWN file
    context — this (audio) thread only needs to wait for it at the
    end, see below. }
  if FHasVideo then begin
    FVideoThread := TVideoDecodeThread.Create(Self, FStartPositionSec);
  end;

  if FHasAudio then begin
    if FStartPositionSec > 0 then begin
      av_seek_frame(FmtCtx, -1, Round(FStartPositionSec * 1000000), AVSEEK_FLAG_BACKWARD);
      avcodec_flush_buffers(ACodecCtx);
      FAudioPositionSamples := Round(FStartPositionSec * MEDIA_OUT_RATE);
    end;

    Pkt := av_packet_alloc;
    Frame := av_frame_alloc;

    while (not FStopRequested) and (av_read_frame(FmtCtx, Pkt) >= 0) do begin
      if Pkt^.stream_index = AudioStreamIdx then begin
        if avcodec_send_packet(ACodecCtx, Pkt) >= 0 then begin
          while True do begin
            Ret := avcodec_receive_frame(ACodecCtx, Frame);
            if Ret < 0 then begin
              Break;
            end;
            HandleAudioFrame;
            av_frame_unref(Frame);
          end;
        end;
      end;
      av_packet_unref(Pkt);
    end;

    { Decoder flush on EOF — same reasoning as TAudioPlayer (see its
      detailed comment, audioplayer.pas): container EOF doesn't mean
      the decoder has handed back every frame. }
    if (not FStopRequested) and (avcodec_send_packet(ACodecCtx, nil) >= 0) then begin
      while True do begin
        Ret := avcodec_receive_frame(ACodecCtx, Frame);
        if Ret < 0 then begin
          Break;
        end;
        HandleAudioFrame;
        av_frame_unref(Frame);
      end;
    end;

    if SwrReady and (not FStopRequested) then begin
      repeat
        OutSamples := swr_convert(Swr, @OutTmp, OutTmpCap, nil, 0);
        if OutSamples > 0 then begin
          FifoAppend(OutTmp, cardinal(OutSamples) * MEDIA_OUT_CHANNELS * 2);
        end;
      until OutSamples <= 0;
    end;
    PumpFifoToDevice(True);

    if SwrReady then swr_free(Swr);
    av_frame_free(Frame);
    av_packet_free(Pkt);
    if ACodecCtx <> nil then avcodec_free_context(ACodecCtx);
    FreeMem(OutTmp);
    for I := 0 to MEDIA_BUF_COUNT - 1 do begin
      FreeMem(FBufMem[I]);
    end;
  end;

  avformat_close_input(FmtCtx);
  CloseAudioDevice(not FStopRequested);

  { Wait for video — the overall "playback finished" state
    (mpsStopped/OnStateChanged) doesn't fire until both threads have
    actually finished. Called from THIS thread (not the UI thread, not
    inside someone else's Synchronize) — WaitFor/Free are safe here. }
  if FVideoThread <> nil then begin
    FVideoThread.WaitFor;
    FVideoThread.Free;
    FVideoThread := nil;
  end;

  if FState <> mpsError then begin
    FState := mpsStopped;
  end;
  Synchronize(@DoStateChanged);
end;

procedure TMediaPlayer.Pause;
begin
  FPauseRequested := True;
  FWaveLock.Enter;
  try
    if FWaveOut <> 0 then begin
      waveOutPause(FWaveOut);
    end;
  finally
    FWaveLock.Leave;
  end;
  FState := mpsPaused;
end;

procedure TMediaPlayer.Resume;
begin
  FPauseRequested := False;
  FWaveLock.Enter;
  try
    if FWaveOut <> 0 then begin
      waveOutRestart(FWaveOut);
    end;
  finally
    FWaveLock.Leave;
  end;
  FState := mpsPlaying;
end;

procedure TMediaPlayer.StopPlayback;
begin
  FStopRequested := True;
  FPauseRequested := False;
  if FVideoThread <> nil then begin
    FVideoThread.Terminate;
  end;
end;

function TMediaPlayer.PositionSec: double;
begin
  if FHasAudio then begin
    Result := AudioClockSec;
  end else begin
    Result := FVideoPositionSec;
  end;
end;

end.
