unit audioplayer;

{$mode objfpc}{$H+}

{ Plays a single audio file: decoding (ffdecode.pas, FFmpeg) in a
  background thread, output through winmm (waveOut*). One instance
  equals one playback; the next Play is a new instance
  (FreeOnTerminate is not used on this class — the caller frees the
  old object after seeing apsStopped/apsError via OnStateChanged). }

interface

uses
  Classes, SysUtils, Windows, MMSystem, ctypes, ffdecode, audiodevices;

const
  { ~0.2s per buffer at 44100Hz; 4 buffers means decoding stays about
    0.8s ahead of playback, a comfortable margin. }
  PLAYER_BUF_SAMPLES = 8820;
  PLAYER_BUF_COUNT = 4;
  PLAYER_OUT_RATE = 44100;
  PLAYER_OUT_CHANNELS = 2;
  PLAYER_BUF_BYTES = PLAYER_BUF_SAMPLES * PLAYER_OUT_CHANNELS * 2;   { S16 }

type
  TAudioPlayerState = (apsPlaying, apsPaused, apsStopped, apsError);

  TAudioPlayer = class(TThread)
  private
    FFilePath: utf8string;
    FDeviceName: utf8string;
    FStartPositionSec: double;
    FWaveOut: HWAVEOUT;
    FHeaders: array[0..PLAYER_BUF_COUNT - 1] of TWAVEHDR;
    FBufMem: array[0..PLAYER_BUF_COUNT - 1] of PByte;
    FState: TAudioPlayerState;
    FDurationSec: double;
    FPositionSamples: Int64;   { samples (per channel) already handed to waveOut }
    FPauseRequested: boolean;
    FStopRequested: boolean;
    FOnStateChanged: TNotifyEvent;
    FLastError: utf8string;
    FFifo: array of Byte;
    FFifoLen: cardinal;
    procedure DoStateChanged;
    procedure FifoAppend(AData: PByte; ALen: cardinal);
    function FifoTakeInto(ADst: PByte; AMax: cardinal): cardinal;
    function OpenDevice: boolean;
    procedure CloseDevice(AGraceful: boolean);
    function WaitBufferFree(AIndex: integer): boolean;
    function WriteBuffer(AIndex: integer; ALen: cardinal): boolean;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath, ADeviceName: utf8string; AStartPositionSec: double = 0);
    procedure Pause;
    procedure Resume;
    procedure StopPlayback;
    function PositionSec: double;
    property DurationSec: double read FDurationSec;
    property State: TAudioPlayerState read FState;
    property LastError: utf8string read FLastError;
    property OnStateChanged: TNotifyEvent read FOnStateChanged write FOnStateChanged;
  end;

implementation

constructor TAudioPlayer.Create(const AFilePath, ADeviceName: utf8string; AStartPositionSec: double = 0);
begin
  inherited Create(True);
  FFilePath := AFilePath;
  FDeviceName := ADeviceName;
  FStartPositionSec := AStartPositionSec;
  { The position is set here, on the caller's (main) thread, not only
    inside ExecuteInner (on the background thread, after the file is
    opened) — otherwise there is a window of a few milliseconds where
    PositionSec is already being read while FPositionSamples is still
    0, making the progress bar jump to the start of the track for one
    frame before settling on the seek position. }
  FPositionSamples := Round(AStartPositionSec * PLAYER_OUT_RATE);
  FreeOnTerminate := False;
  FState := apsPlaying;
  Start;
end;

procedure TAudioPlayer.DoStateChanged;
begin
  if Assigned(FOnStateChanged) then begin
    FOnStateChanged(Self);
  end;
end;

procedure TAudioPlayer.FifoAppend(AData: PByte; ALen: cardinal);
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

function TAudioPlayer.FifoTakeInto(ADst: PByte; AMax: cardinal): cardinal;
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

function TAudioPlayer.OpenDevice: boolean;
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
  Fmt.nChannels := PLAYER_OUT_CHANNELS;
  Fmt.nSamplesPerSec := PLAYER_OUT_RATE;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := (Fmt.nChannels * Fmt.wBitsPerSample) div 8;
  Fmt.nAvgBytesPerSec := Fmt.nSamplesPerSec * Fmt.nBlockAlign;

  Result := waveOutOpen(@FWaveOut, DevId, @Fmt, 0, 0, CALLBACK_NULL) = 0;
end;

procedure TAudioPlayer.CloseDevice(AGraceful: boolean);
var
  I: integer;
  WaitMs: integer;
  AllDone: boolean;
begin
  if FWaveOut = 0 then begin
    Exit;
  end;
  AllDone := True;
  if AGraceful then begin
    { Reaching the end of the file is not a user Stop: buffers already
      handed to winmm must finish playing, or the end of the track
      gets cut off (waveOutReset stops playback immediately, dropping
      whatever has not played yet). Waits for WHDR_DONE on every used
      buffer, with a safety timeout in case the driver is stuck. }
    for I := 0 to PLAYER_BUF_COUNT - 1 do begin
      WaitMs := 0;
      while ((FHeaders[I].dwFlags and WHDR_PREPARED) <> 0) and
            ((FHeaders[I].dwFlags and WHDR_DONE) = 0) and (WaitMs < 5000) do begin
        Sleep(10);
        Inc(WaitMs, 10);
      end;
      if ((FHeaders[I].dwFlags and WHDR_PREPARED) <> 0) and
        ((FHeaders[I].dwFlags and WHDR_DONE) = 0) then begin
        AllDone := False;   { a stuck buffer — the safety timeout fired }
      end;
    end;
  end;
  { Per waveOutUnprepareHeader's documented contract (MSDN: "called
    after ... the buffer has finished playing, OR waveOutReset has
    been called"), Reset is required ONLY if a buffer has not finished
    on its own. Calling waveOutReset on a device that has already
    fully finished playing is not free: WHDR_DONE only guarantees the
    driver has taken the buffer's data, not that the physical output
    (the sound card's DMA/hardware FIFO) has actually finished — an
    abrupt Reset at that point can cut off or click on the remaining
    hardware tail, even though playback looks complete from this
    code's point of view. If ALL buffers reached WHDR_DONE without
    timing out (AllDone), Reset is skipped entirely, using Unprepare+
    Close instead. Reset is kept for an explicit user Stop
    (AGraceful=False) and for a stuck driver (the safety timeout
    fired) — those cases genuinely need to drop playback rather than
    wait indefinitely. }
  if (not AGraceful) or (not AllDone) then begin
    waveOutReset(FWaveOut);
  end;
  for I := 0 to PLAYER_BUF_COUNT - 1 do begin
    if (FHeaders[I].dwFlags and WHDR_PREPARED) <> 0 then begin
      waveOutUnprepareHeader(FWaveOut, @FHeaders[I], SizeOf(TWAVEHDR));
    end;
  end;
  waveOutClose(FWaveOut);
  FWaveOut := 0;
end;

function TAudioPlayer.WaitBufferFree(AIndex: integer): boolean;
begin
  { Waits until the driver marks the buffer as played (WHDR_DONE) — no
    CALLBACK_EVENT/window callback, just short polling: with
    PLAYER_BUF_COUNT=4 buffers and ~0.2s per buffer, a 5ms poll
    interval is negligible relative to the buffer itself. IMPORTANT:
    this must complete BEFORE new data is written into
    FBufMem[AIndex], otherwise a buffer winmm is still physically
    playing could be overwritten (see PumpFifoToDevice, which waits
    for this before taking data from the FIFO). }
  while (not FStopRequested) and ((FHeaders[AIndex].dwFlags and WHDR_PREPARED) <> 0) and
        ((FHeaders[AIndex].dwFlags and WHDR_DONE) = 0) do begin
    Sleep(5);
  end;
  Result := not FStopRequested;
end;

function TAudioPlayer.WriteBuffer(AIndex: integer; ALen: cardinal): boolean;
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
  Inc(FPositionSamples, ALen div (PLAYER_OUT_CHANNELS * 2));
  Result := True;
end;

procedure TAudioPlayer.Execute;
begin
  try
    ExecuteInner;
  except
    on E: Exception do begin
      FLastError := utf8string(E.ClassName) + ': ' + utf8string(E.Message);
      FState := apsError;
      Synchronize(@DoStateChanged);
    end;
  end;
end;

procedure TAudioPlayer.ExecuteInner;
var
  FmtCtx: PAVFormatContext;
  Stream: PAVStream;
  CodecCtx, Codec, Swr: pointer;
  Pkt: PAVPacket;
  Frame: PAVFrame;
  AudioStreamIdx, Ret: cint;
  I: integer;
  OutChLayout, InChLayout: TAVChannelLayout;
  OutTmp: PByte;
  OutTmpCap: cint;
  OutSamples: cint;
  WriteIdx: integer;
  SwrReady: boolean;
  EofReached: boolean;

  procedure PumpFifoToDevice(AFlush: boolean);
  var
    N: cardinal;
  begin
    { As long as the FIFO has enough for a full buffer — or this is
      the final flush (AFlush) and anything is left — send it to
      winmm. Order matters: wait for the buffer slot to actually be
      free (WaitBufferFree) BEFORE writing new bytes into it
      (FifoTakeInto), otherwise a buffer the device is still
      physically playing could be overwritten. }
    while (not FStopRequested) and
          ((FFifoLen >= PLAYER_BUF_BYTES) or (AFlush and (FFifoLen > 0))) do begin
      if not WaitBufferFree(WriteIdx) then begin
        Break;
      end;
      N := FifoTakeInto(FBufMem[WriteIdx], PLAYER_BUF_BYTES);
      if N = 0 then begin
        Break;
      end;
      if not WriteBuffer(WriteIdx, N) then begin
        Break;
      end;
      WriteIdx := (WriteIdx + 1) mod PLAYER_BUF_COUNT;
    end;
  end;

begin
  FmtCtx := nil;
  Codec := nil;
  CodecCtx := nil;
  Swr := nil;
  Pkt := nil;
  Frame := nil;
  WriteIdx := 0;
  SwrReady := False;

  if not OpenDevice then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    Exit;
  end;
  for I := 0 to PLAYER_BUF_COUNT - 1 do begin
    GetMem(FBufMem[I], PLAYER_BUF_BYTES);
  end;

  if avformat_open_input(FmtCtx, PAnsiChar(FFilePath), nil, nil) < 0 then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    CloseDevice(False);
    Exit;
  end;
  if avformat_find_stream_info(FmtCtx, nil) < 0 then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    avformat_close_input(FmtCtx);
    CloseDevice(False);
    Exit;
  end;
  FDurationSec := FmtCtx^.duration / 1000000.0;

  if FStartPositionSec > 0 then begin
    { stream_index=-1 means the timestamp is in AV_TIME_BASE
      (microseconds), no need to know the stream's own timebase (see
      ffdecode.pas). FPositionSamples is set immediately, otherwise the
      progress bar would jump to 0 and back to the seek position on the
      first decoded frame. }
    av_seek_frame(FmtCtx, -1, Round(FStartPositionSec * 1000000), AVSEEK_FLAG_BACKWARD);
    FPositionSamples := Round(FStartPositionSec * PLAYER_OUT_RATE);
  end;

  AudioStreamIdx := -1;
  for I := 0 to FmtCtx^.nb_streams - 1 do begin
    Stream := PPAVStream(FmtCtx^.streams)[I];
    if Stream^.codecpar^.codec_type = AVMEDIA_TYPE_AUDIO then begin
      AudioStreamIdx := I;
      Break;
    end;
  end;
  if AudioStreamIdx < 0 then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    avformat_close_input(FmtCtx);
    CloseDevice(False);
    Exit;
  end;

  Stream := PPAVStream(FmtCtx^.streams)[AudioStreamIdx];
  Codec := avcodec_find_decoder(Stream^.codecpar^.codec_id);
  if Codec = nil then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    avformat_close_input(FmtCtx);
    CloseDevice(False);
    Exit;
  end;
  CodecCtx := avcodec_alloc_context3(Codec);
  if (CodecCtx = nil) or (avcodec_parameters_to_context(CodecCtx, Stream^.codecpar) < 0) or
     (avcodec_open2(CodecCtx, Codec, nil) < 0) then begin
    FState := apsError;
    Synchronize(@DoStateChanged);
    if CodecCtx <> nil then avcodec_free_context(CodecCtx);
    avformat_close_input(FmtCtx);
    CloseDevice(False);
    Exit;
  end;

  Pkt := av_packet_alloc;
  Frame := av_frame_alloc;
  OutTmpCap := PLAYER_BUF_SAMPLES * 2;   { 2x headroom, in samples per channel }
  GetMem(OutTmp, cardinal(OutTmpCap) * PLAYER_OUT_CHANNELS * 2);

  FillChar(OutChLayout, SizeOf(OutChLayout), 0);
  OutChLayout.order := AV_CHANNEL_ORDER_NATIVE;
  OutChLayout.nb_channels := PLAYER_OUT_CHANNELS;
  OutChLayout.u := AV_CH_LAYOUT_STEREO_MASK;

  EofReached := False;
  while (not FStopRequested) and (not EofReached) and (av_read_frame(FmtCtx, Pkt) >= 0) do begin
    if Pkt^.stream_index = AudioStreamIdx then begin
      if avcodec_send_packet(CodecCtx, Pkt) >= 0 then begin
        while True do begin
          Ret := avcodec_receive_frame(CodecCtx, Frame);
          if Ret < 0 then begin
            Break;
          end;

          if not SwrReady then begin
            InChLayout := Frame^.ch_layout;
            Ret := swr_alloc_set_opts2(Swr, @OutChLayout, AV_SAMPLE_FMT_S16, PLAYER_OUT_RATE,
              @InChLayout, Frame^.format, Frame^.sample_rate, 0, nil);
            if (Ret < 0) or (swr_init(Swr) < 0) then begin
              av_frame_unref(Frame);
              EofReached := True;
              Break;
            end;
            SwrReady := True;
          end;

          OutSamples := swr_convert(Swr, @OutTmp, OutTmpCap, @Frame^.data[0], Frame^.nb_samples);
          if OutSamples > 0 then begin
            FifoAppend(OutTmp, cardinal(OutSamples) * PLAYER_OUT_CHANNELS * 2);
          end;
          av_frame_unref(Frame);

          { Pausing simply stops handing winmm new data and stops
            decoding further until resumed (Resume itself calls
            waveOutRestart — this only withholds new buffers). }
          while FPauseRequested and (not FStopRequested) do begin
            Sleep(20);
          end;

          PumpFifoToDevice(False);
        end;
      end;
    end;
    av_packet_unref(Pkt);
  end;

  { Explicitly flushes the DECODER — reaching container EOF
    (av_read_frame < 0) does not mean the decoder has emitted ALL
    frames yet. Per the documented avcodec_send_packet/
    avcodec_receive_frame contract, many codecs (AAC, Opus, and others
    with internal lookahead/reordering) hold back several trailing
    frames in an internal buffer and only release them after an
    explicit flush packet (send_packet with pkt=NULL), followed by
    receive_frame in a loop until it returns < 0. Without this step,
    the last decoded frames would be cut off at the decoder's internal
    state boundary before ever reaching the resampler/FIFO. }
  if (not FStopRequested) and (avcodec_send_packet(CodecCtx, nil) >= 0) then begin
    while True do begin
      Ret := avcodec_receive_frame(CodecCtx, Frame);
      if Ret < 0 then begin
        Break;
      end;
      if not SwrReady then begin
        InChLayout := Frame^.ch_layout;
        Ret := swr_alloc_set_opts2(Swr, @OutChLayout, AV_SAMPLE_FMT_S16, PLAYER_OUT_RATE,
          @InChLayout, Frame^.format, Frame^.sample_rate, 0, nil);
        if (Ret >= 0) and (swr_init(Swr) >= 0) then begin
          SwrReady := True;
        end;
      end;
      if SwrReady then begin
        OutSamples := swr_convert(Swr, @OutTmp, OutTmpCap, @Frame^.data[0], Frame^.nb_samples);
        if OutSamples > 0 then begin
          FifoAppend(OutTmp, cardinal(OutSamples) * PLAYER_OUT_CHANNELS * 2);
        end;
      end;
      av_frame_unref(Frame);
    end;
  end;

  { Flushes the resampler (it may hold a few samples in reserve) and
    the remaining FIFO contents. }
  if SwrReady and (not FStopRequested) then begin
    repeat
      OutSamples := swr_convert(Swr, @OutTmp, OutTmpCap, nil, 0);
      if OutSamples > 0 then begin
        FifoAppend(OutTmp, cardinal(OutSamples) * PLAYER_OUT_CHANNELS * 2);
      end;
    until OutSamples <= 0;
  end;
  PumpFifoToDevice(True);

  if SwrReady then swr_free(Swr);
  av_frame_free(Frame);
  av_packet_free(Pkt);
  avcodec_free_context(CodecCtx);
  avformat_close_input(FmtCtx);
  FreeMem(OutTmp);

  for I := 0 to PLAYER_BUF_COUNT - 1 do begin
    FreeMem(FBufMem[I]);
  end;
  CloseDevice(not FStopRequested);

  if FState <> apsError then begin
    FState := apsStopped;
  end;
  Synchronize(@DoStateChanged);
end;

procedure TAudioPlayer.Pause;
begin
  FPauseRequested := True;
  if FWaveOut <> 0 then begin
    waveOutPause(FWaveOut);
  end;
  FState := apsPaused;
end;

procedure TAudioPlayer.Resume;
begin
  FPauseRequested := False;
  if FWaveOut <> 0 then begin
    waveOutRestart(FWaveOut);
  end;
  FState := apsPlaying;
end;

procedure TAudioPlayer.StopPlayback;
begin
  FStopRequested := True;
  FPauseRequested := False;   { clear pause so the thread doesn't wait forever for Resume }
end;

function TAudioPlayer.PositionSec: double;
begin
  Result := FPositionSamples / PLAYER_OUT_RATE;
end;

end.
