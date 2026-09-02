unit audioplayer;

{$mode objfpc}{$H+}

{ Проигрывание одного аудиофайла: декодирование (ffdecode.pas, FFmpeg)
  в фоновом потоке, вывод через winmm (waveOut*, тот же принцип, что
  уже даёт audiodevices.pas — только вывод, не только перечисление).
  Один инстанс = одно проигрывание; следующий Play — новый инстанс
  (FreeOnTerminate у этого класса не используется, старый объект
  освобождает вызывающий, увидев apsStopped/apsError через
  OnStateChanged). }

interface

uses
  Classes, SysUtils, Windows, MMSystem, ctypes, ffdecode, audiodevices;

const
  { ~0.2с на буфер при 44100Гц; 4 буфера — decode бежит примерно на
    0.8с впереди воспроизведения, комфортный запас. }
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
    FPositionSamples: Int64;   { сэмплов (per channel) уже отдано в waveOut }
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
  { Позиция выставляется здесь же, на вызывающем (главном) потоке, а
    не только внутри ExecuteInner (там же, фоновым потоком, ПОСЛЕ
    открытия файла) — иначе есть окно в несколько миллисекунд, когда
    PositionSec уже читают (например, TMsgScroller.LayoutAudioWidgets
    сразу вслед за Create), а FPositionSamples ещё 0: прогресс-бар на
    один кадр "прыгает" к началу трека и только потом — на место
    перемотки. Для клика (без реального перетаскивания) это окно
    успевало попасть в перерисовку и было заметно; при обычном драге —
    нет, там события идут медленнее человеческого клика. }
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
begin
  if FWaveOut = 0 then begin
    Exit;
  end;
  if AGraceful then begin
    { Конец файла сам по себе — не Stop пользователя: буферы, уже
      отданные в winmm, должны доиграть, иначе конец трека обрежется
      (waveOutReset останавливает воспроизведение немедленно, отбрасывая
      всё, что ещё не отыграно). Ждём WHDR_DONE на каждом использованном
      буфере, с защитным таймаутом на случай залипшего драйвера. }
    for I := 0 to PLAYER_BUF_COUNT - 1 do begin
      WaitMs := 0;
      while ((FHeaders[I].dwFlags and WHDR_PREPARED) <> 0) and
            ((FHeaders[I].dwFlags and WHDR_DONE) = 0) and (WaitMs < 5000) do begin
        Sleep(10);
        Inc(WaitMs, 10);
      end;
    end;
  end;
  waveOutReset(FWaveOut);
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
  { Ждём, пока драйвер не пометит буфер как отыгранный (WHDR_DONE) —
    без CALLBACK_EVENT/оконного колбэка, просто короткий опрос: при
    PLAYER_BUF_COUNT=4 буферах и ~0.2с на буфер задержка опроса (5мс)
    пренебрежимо мала относительно самого буфера. ВАЖНО: это должно
    отработать ДО того, как в FBufMem[AIndex] запишут новые данные —
    иначе можно затереть буфер, который winmm ещё физически
    воспроизводит (см. правку в PumpFifoToDevice — раньше FIFO
    вычитывался в буфер раньше этого ожидания, отсюда и слышимые
    щелчки/повторы). }
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
    { Пока в FIFO хватает на полный буфер — или это финальный слив
      (AFlush) и там хоть что-то осталось — отправляем в winmm.
      Порядок важен: сначала дожидаемся, что этот слот буфера
      действительно свободен (WaitBufferFree), и только ПОТОМ пишем в
      его память новые байты (FifoTakeInto) — иначе можно затереть
      буфер, который устройство ещё физически проигрывает. }
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
    { stream_index=-1 — таймстамп в AV_TIME_BASE (микросекундах), не
      нужно знать timebase конкретного потока (см. ffdecode.pas).
      FPositionSamples выставляем сразу — иначе прогресс-бар прыгнул
      бы к 0 и только потом снова к месту перемотки, на первом же
      decoded-фрейме. }
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
  OutTmpCap := PLAYER_BUF_SAMPLES * 2;   { запас x2 в сэмплах на канал }
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

          { Пауза — просто не отдаём winmm новые данные и не декодируем
            дальше, пока не снимут (Resume зовёт waveOutRestart сама,
            здесь только не подкачиваем новые буферы). }
          while FPauseRequested and (not FStopRequested) do begin
            Sleep(20);
          end;

          PumpFifoToDevice(False);
        end;
      end;
    end;
    av_packet_unref(Pkt);
  end;

  { Слив ресемплера (может держать несколько сэмплов в запасе) и
    остатка FIFO. }
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
  FPauseRequested := False;   { снимаем паузу, чтобы поток не завис в ожидании Resume }
end;

function TAudioPlayer.PositionSec: double;
begin
  Result := FPositionSamples / PLAYER_OUT_RATE;
end;

end.
