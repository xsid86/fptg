unit mediaplayer;

{$mode objfpc}{$H+}

{ Проигрывание одного видео-сообщения (messageVideo — настоящее видео
  со звуком, в отличие от "гифки"/messageAnimation в videoplayer.pas):
  ДВА независимых потока-декодера на файл, не один.

  Раньше (первая версия) был ОДИН общий поток, объединявший вывод звука
  через winmm (тот же WAVEHDR-конвейер, что у TAudioPlayer,
  audioplayer.pas) и декод видео-кадров в BGRA через libswscale (тот же
  приём, что у TAnimationPlayer, videoplayer.pas), с показом кадра,
  отложенным блокирующим Sleep до момента, пока звук его "догонит".
  На практике это периодически морило голодом аудио-буфер: пока поток
  спал ради видео, он не читал новые пакеты и не кормил winmm — если
  устройство успевало доиграть весь свой запас (~0.8с, 4 буфера) и
  вставало без данных, его АППАРАТНЫЕ часы (waveOutGetPosition)
  переставали продвигаться в реальном темпе НЕОБРАТИМО, и видео,
  честно следуя за ними, отставало вместе — вся связка играла заметно
  медленнее реального времени (см. CLAUDE.md, video_debug.log: ~2x).
  Первая попытка фикса (video просто перестало ждать вообще, показывая
  кадры сразу) исправила скорость звука, но сделала видео дёрганым —
  видео декодировалось рывками между долгими паузами на кормление
  звука, и общий буфер кадра обновлялся крайне неравномерно.

  Правильное решение — РАЗДЕЛИТЬ два потока физически: `TMediaPlayer`
  (сам, `class(TThread)`) теперь занимается ТОЛЬКО звуком — тот же
  WAVEHDR-конвейер, что и раньше, ничем не потревоженный видео.
  `TVideoDecodeThread` — отдельный поток, открывающий ТОТ ЖЕ файл ещё
  раз, НЕЗАВИСИМО (свой AVFormatContext, тот же приём, что уже
  применяется у TAnimationPlayer в videoplayer.pas) — декодирует кадры
  и ждёт (блокирующим Sleep, ТОЧНО той же Delay-формулой, что и раньше)
  момента показа относительно аудио-часов владельца
  (`TMediaPlayer.AudioClockSec`) — но теперь это ожидание НЕ блокирует
  кормление звука вообще, они физически на разных потоках. Синхронизация
  между двумя потоками — только на чтение (аудио-часы) и через
  локальный TCriticalSection вокруг общего кадрового буфера
  (`FFrameBuf`/`FFrameVersion`), тот же приём, что уже применялся в
  однопоточной версии.

  Нет зацикливания (в отличие от "гифки") и нет плей/пауза/стоп
  контролов у самого класса на уровне UI (в отличие от "гифки", где их
  нет вовсе) — здесь ЕСТЬ Pause/Resume/StopPlayback, ровно как у
  TAudioPlayer: видео-сообщение — обычный проигрыватель с паузой и
  перемоткой, доигрывает один раз и останавливается (mpsStopped),
  дожидаясь завершения ОБОИХ потоков.

  FreeOnTerminate=False у TMediaPlayer, как у TAudioPlayer (НЕ как у
  TAnimationPlayer) — по той же причине: одновременно играет НЕ БОЛЕЕ
  ОДНОГО видео со звуком (единственный владелец — TMediaViewerPanel,
  mediaviewer.pas, один слот на всё приложение; инлайн-проигрывания
  видео в чате больше нет вовсе, см. framehistory.pas), Stop —
  осознанное действие пользователя, синхронный WaitFor там не проблема.
  TVideoDecodeThread тоже FreeOnTerminate=False — его WaitFor/Free
  вызывается из ExecuteInner самого TMediaPlayer (не из UI-потока, не
  из чужого Synchronize — безопасно). }

interface

uses
  Classes, SysUtils, SyncObjs, Windows, MMSystem, ffdecode, audiodevices, ctypes;

const
  { Тот же формат вывода и та же буферизация, что у TAudioPlayer
    (audioplayer.pas) — не два разных числа на один и тот же смысл. }
  MEDIA_BUF_SAMPLES = 8820;
  MEDIA_BUF_COUNT = 4;
  MEDIA_OUT_RATE = 44100;
  MEDIA_OUT_CHANNELS = 2;
  MEDIA_BUF_BYTES = MEDIA_BUF_SAMPLES * MEDIA_OUT_CHANNELS * 2;   { S16 }

type
  TMediaPlayerState = (mpsPlaying, mpsPaused, mpsStopped, mpsError);

  TMediaPlayer = class;

  { Видео-часть — отдельный поток, независимый от аудио, см. шапку
    юнита. Открывает файл ВТОРОЙ РАЗ, самостоятельно (свой
    AVFormatContext) — тот же приём, что TAnimationPlayer. }
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

    { видео — под критической секцией лежит только ОДИН, постоянно
      перезаписываемый кадр, пишет TVideoDecodeThread, читает UI-поток
      через TryGetFrame. Квалифицировано SyncObjs.TCriticalSection явно
      — Windows (тоже в uses, нужен под waveOut*/MMTIME) идёт РАНЬШЕ
      SyncObjs в списке выше и объявляет СВОЙ, другой, несовместимый
      TCriticalSection (внутренний RTL-тип из sysosh.inc, не класс с
      Enter/Leave/Create) — тот самый класс ловушки с порядком uses,
      что уже документирован в framehistory.pas, только здесь порядок
      обратный (Windows не первым), поэтому неквалифицированное имя
      резолвится не туда. }
    FFrameLock: SyncObjs.TCriticalSection;
    FFrameBuf: PByte;          { BGRA, FTargetW*FTargetH*4 байт, выделяется TVideoDecodeThread }
    FFrameVersion: cardinal;
    FHasVideo: boolean;
    FVideoPositionSec: double; { пишет TVideoDecodeThread; читает PositionSec, если звука нет }
    FVideoThread: TVideoDecodeThread;

    { аудио — тот же WAVEHDR-конвейер, что TAudioPlayer, живёт целиком
      на ЭТОМ (главном для TMediaPlayer) потоке. }
    FWaveOut: HWAVEOUT;
    { FWaveOut читается/закрывается с ДВУХ потоков — этот (аудио-декод,
      закрывает по концу файла) и UI-поток (TMediaViewerPanel.VideoTick →
      PositionSec → AudioClockSec, раз в 33мс, пока видео активно, плюс
      Pause/Resume по клику). Без блокировки закрытие устройства
      (waveOutClose) могло гонку с чтением его же хендла в
      waveOutGetPosition на другом потоке — реальный, пойманный
      пользователем крах (Access Violation в AudioClockSec, "по адресу"
      внутри winmm, сразу после конца проигрывания — ровно момент,
      когда этот поток закрывает устройство). FWaveLock — вокруг
      каждого места, где FWaveOut читается ИЛИ пишется с более чем
      одного потока. }
    FWaveLock: SyncObjs.TCriticalSection;
    FHeaders: array[0..MEDIA_BUF_COUNT - 1] of TWAVEHDR;
    FBufMem: array[0..MEDIA_BUF_COUNT - 1] of PByte;
    FHasAudio: boolean;
    FAudioPositionSamples: Int64;   { сэмплов, УЖЕ ОТДАННЫХ в очередь winmm — запасные часы, см. AudioClockSec }

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
    { Реальная позиция воспроизведения звука — waveOutGetPosition
      (сколько сэмплов устройство УЖЕ физически проиграло), не
      FAudioPositionSamples (то — сколько уже ОТДАНО в очередь, а там
      до ~0.8с буферизации вперёд, см. MEDIA_BUF_COUNT). Она же — master-
      часы синхронизации видео (читает TVideoDecodeThread, с ЧУЖОГО
      потока — см. FWaveLock). Резервный вариант (FAudioPositionSamples),
      если драйвер не поддержал TIME_SAMPLES — реже точный (не
      учитывает буферизацию), но не падает. }
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
    { Часы: реальная позиция звука (AudioClockSec), если звук есть;
      иначе позиция последнего показанного кадра видео. }
    function PositionSec: double;
    { Та же роль/контракт, что TAnimationPlayer.TryGetFrame (videoplayer.
      pas) — копирует кадр в ADst, если он новее AKnownVersion. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property DurationSec: double read FDurationSec;
    property State: TMediaPlayerState read FState;
    property HasVideo: boolean read FHasVideo;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property LastError: utf8string read FLastError;
    property OnStateChanged: TNotifyEvent read FOnStateChanged write FOnStateChanged;
  end;

implementation

{ ВРЕМЕННАЯ диагностика — та же, что уже была; оставлена ещё на один
  раунд проверки после структурной правки (раздельные потоки звука и
  видео) — убрать, когда пользователь подтвердит, что и скорость, и
  плавность, и крах на конце проигрывания исправлены по-настоящему. }
procedure LogVideoDebug(const ALine: utf8string);
var
  F: TextFile;
  Path: string;
begin
  try
    Path := ExtractFilePath(ParamStr(0)) + 'video_debug.log';
    AssignFile(F, Path);
    if FileExists(Path) then begin
      {$I-}
      Append(F);
      {$I+}
      if IOResult <> 0 then begin
        Rewrite(F);
      end;
    end else begin
      Rewrite(F);
    end;
    WriteLn(F, ALine);
    CloseFile(F);
  except
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
    { Ошибка видео-декода не должна ронять звук — тот же принцип, что и
      "Sws=nil -> пропустить кадр, не всё видео целиком", ниже. }
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
  FrameCounter: integer;    { ВРЕМЕННО, см. LogVideoDebug }
  StartTick: QWord;         { ВРЕМЕННО }
begin
  FmtCtx := nil;
  VCodecCtx := nil;
  Sws := nil;
  VTmpBuf := nil;
  VideoStreamIdx := -1;
  HaveOwnPts := False;
  LastOwnPtsSec := 0;
  FrameCounter := 0;

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
  { pkt_timebase — см. подробное объяснение в CLAUDE.md/старом варианте
    этого файла: без него некоторые кодеки отдают Frame.pts в СВОЕЙ
    внутренней временной базе, не в таймбейсе потока. }
  av_opt_set_q(VCodecCtx, 'pkt_timebase', VStream^.time_base, 0);
  if (avcodec_parameters_to_context(VCodecCtx, VStream^.codecpar) < 0) or
     (avcodec_open2(VCodecCtx, VCodec, nil) < 0) then begin
    avcodec_free_context(VCodecCtx);
    avformat_close_input(FmtCtx);
    Exit;
  end;

  GetMem(VTmpBuf, cardinal(FOwner.FTargetW) * cardinal(FOwner.FTargetH) * 4);
  GetMem(FOwner.FFrameBuf, cardinal(FOwner.FTargetW) * cardinal(FOwner.FTargetH) * 4);

  if FStartPositionSec > 0 then begin
    av_seek_frame(FmtCtx, -1, Round(FStartPositionSec * 1000000), AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(VCodecCtx);
  end;

  Pkt := av_packet_alloc;
  Frame := av_frame_alloc;
  StartTick := GetTickCount64;

  while (not Terminated) and (not FOwner.FStopRequested) and
        (av_read_frame(FmtCtx, Pkt) >= 0) do begin
    if Pkt^.stream_index = VideoStreamIdx then begin
      if avcodec_send_packet(VCodecCtx, Pkt) >= 0 then begin
        while True do begin
          Ret := avcodec_receive_frame(VCodecCtx, Frame);
          if Ret < 0 then begin
            Break;
          end;
          Inc(FrameCounter);

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
              { Со звуком — ждём аудио-часы владельца; это БЛОКИРУЕТ
                только ЭТОТ поток, не поток, кормящий звук — теперь
                это безопасно, они физически разные потоки. Без звука —
                та же PTS-дельта между соседними кадрами, что и раньше
                (TAnimationPlayer). }
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
                Delay := 1;   { защита от неправдоподобного PTS/сбитых часов }
              end;
              if (FrameCounter <= 5) or (FrameCounter mod 30 = 0) then begin
                LogVideoDebug(Format(
                  'frame=%d wall=%.3f nowpts=%.3f clock=%.3f delay=%.3f hasaudio=%d',
                  [FrameCounter, (GetTickCount64 - StartTick) / 1000.0,
                   NowPtsSec, AClock, Delay, Ord(FOwner.FHasAudio)]));
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
  { Тот же приём, что у TAudioPlayer.Create — позиция выставляется
    здесь же, до Start, чтобы PositionSec, прочитанный сразу вслед за
    Create (TMediaViewerPanel.StartVideoPlayer/VideoTick), не увидел
    окно в несколько миллисекунд с позицией 0 до места перемотки. }
  FAudioPositionSamples := Round(AStartPositionSec * MEDIA_OUT_RATE);
  FVideoPositionSec := AStartPositionSec;
  FFrameLock := SyncObjs.TCriticalSection.Create;
  FWaveLock := SyncObjs.TCriticalSection.Create;
  FreeOnTerminate := False;
  FState := mpsPlaying;
  Start;
end;

destructor TMediaPlayer.Destroy;
begin
  { К моменту вызова Destroy Execute уже гарантированно завершился (см.
    контракт FreeOnTerminate=False — вызывающая сторона обязана
    WaitFor перед Free, TMediaViewerPanel.FlushDonePlayer так и
    делает), а значит ExecuteInner уже сам дождался и освободил
    FVideoThread на обычном пути. Проверка здесь — только защитная
    сетка на случай раннего Exit по ошибке ДО того, как видео-поток
    вообще был создан (тогда FVideoThread=nil, ничего делать не надо). }
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
  { Та же логика, что у TAudioPlayer.CloseDevice (audioplayer.pas) —
    см. её же подробный комментарий там про то, почему Reset не
    вызывается безусловно. Не продублирован здесь построчно с той же
    длиной обоснования — достаточно знать, что это тот же, уже
    проверенный код, не новая догадка.

    Сам ЖДУЩИЙ цикл (WaitMs<5000) НЕ держит FWaveLock — он трогает
    только FHeaders (флаги буферов), не FWaveOut, и может занять до
    5 секунд в редком случае залипшего драйвера; держать лок всё это
    время означало бы подвесить AudioClockSec (а с ним и UI-поток,
    который её опрашивает раз в 33мс, пока видео активно) на те же
    5 секунд. Лок берётся только на сам момент закрытия — короткий,
    неблокирующий для читателей. }
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
  { Держим лок на всё чтение — не только на проверку FWaveOut=0, но и на
    сам вызов waveOutGetPosition — иначе окно между "прочитали хендл" и
    "передали его в API" оставляло бы ровно ту же гонку с CloseAudioDevice,
    что и раньше (см. её же комментарий про AV на конце проигрывания). }
  FWaveLock.Enter;
  try
    if FWaveOut = 0 then begin
      Exit;
    end;
    Mmt.wType := TIME_SAMPLES;
    if (waveOutGetPosition(FWaveOut, @Mmt, SizeOf(Mmt)) = 0) and (Mmt.wType = TIME_SAMPLES) then begin
      Result := Mmt.sample / MEDIA_OUT_RATE;
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
  { Presence-based, не codec-verified — сам видео-декодер открывается и
    проверяется НЕЗАВИСИМО, внутри TVideoDecodeThread; если там кодек
    не откроется, виджет просто никогда не получит кадр (TryGetFrame
    молча вернёт False навсегда) — тот же уровень отказоустойчивости,
    что уже принят в проекте для похожих случаев (TAnimationPlayer.Failed
    тоже нигде не проверяется на стороне UI). }
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

  LogVideoDebug(Format(
    '--- start file=%s duration=%.3f hasaudio=%d hasvideo=%d target=%dx%d rate=%d ---',
    [FFilePath, FDurationSec, Ord(FHasAudio), Ord(FHasVideo), FTargetW, FTargetH, MEDIA_OUT_RATE]));

  { Видео теперь целиком в отдельном потоке, с СОБСТВЕННЫМ файловым
    контекстом — этому (аудио-)потоку нужно только дождаться его в
    конце, см. ниже. }
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

    { Флаш декодера на EOF — та же причина, что у TAudioPlayer (см. её
      же подробный комментарий, audioplayer.pas): контейнерный EOF не
      значит, что декодер отдал все кадры. }
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

  { Дождаться видео — общий "конец проигрывания" (mpsStopped/OnStateChanged)
    не наступает раньше, чем оба потока реально закончили. Вызывается с
    ЭТОГО (не UI, не чужого Synchronize) потока — WaitFor/Free здесь
    безопасны. }
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
