unit videoplayer;

{$mode objfpc}{$H+}

{ Зацикленное декодирование одной "гифки" (messageAnimation — физически
  короткое MP4/H.264-видео без звука) в фоновом потоке: тот же принцип
  потока-декодера, что и у audioplayer.pas (TAudioPlayer), но без
  звукового вывода. Каждый декодированный кадр конвертируется в BGRA
  (libswscale, сразу в размер превью — тот же приём, что и у
  TPhotoWidget: декодировать/масштабировать один раз в целевой размер,
  не в натуральном разрешении, дешевле по памяти/CPU) и складывается в
  единственный, под критической секцией перезаписываемый буфер —
  виджет читает его на перерисовке (TryGetFrame), опрос — тем же
  таймер-приёмом, что уже принят в проекте для позиции аудио
  (TMsgScroller.FPlaybackTimer), не через Synchronize на каждый кадр
  (кадры видео идут заметно чаще, чем 250мс-тик аудио-таймера).

  Списка плей/пауза/стоп контролов НЕТ — по прямому запросу
  пользователя: "гифка" либо не играет вовсе, либо крутится в цикле
  без остановки, пока виджет жив. StopPlayback — не пользовательский
  контрол, а внутренняя остановка потока при переиспользовании/скрытии
  виджета.

  FreeOnTerminate=True (в отличие от TAudioPlayer, у которого
  FreeOnTerminate=False и вызывающий сам делает WaitFor+Free) — по
  другой причине, не той же самой: у аудио одновременно играет НЕ
  БОЛЕЕ ОДНОГО трека (см. TMsgScroller.FActivePlayer), Stop — редкое,
  осознанное действие пользователя, WaitFor там не страшен. "Гифок" же
  одновременно на экране может крутиться сколько угодно (обычный
  Telegram-UX), и StopPlayback вызывается КАЖДЫЙ раз, когда виджет
  переиспользуется/уходит с экрана при скролле — то есть часто и на
  каждый гифок отдельно. Синхронный WaitFor из UI-потока (пусть даже
  не изнутри Paint, а из отложенной раскладки на таймере) мог бы
  подвесить интерфейс на время до секунды (максимальная пауза между
  кадрами внутри цикла декодера) при быстром скролле мимо нескольких
  "гифок" разом. FreeOnTerminate избавляет от WaitFor вовсе — поток
  освобождает сам себя, когда естественным образом заметит
  FStopRequested и выйдет из Execute; вызывающая сторона (framehistory.
  pas) обязана, вызвав StopPlayback, СРАЗУ ЖЕ забыть свою ссылку (nil),
  не обращаться к объекту после — тот может быть уже уничтожен в любой
  момент после этого, асинхронно, из своего же потока. }

interface

uses
  Classes, SysUtils, SyncObjs, ffdecode, ctypes;

type
  TAnimationPlayer = class(TThread)
  private
    FFilePath: utf8string;
    FTargetW, FTargetH: integer;
    FLock: TCriticalSection;
    FFrameBuf: PByte;         { BGRA, FTargetW*FTargetH*4 байт, под FLock }
    FFrameVersion: cardinal;  { растёт на каждый готовый кадр }
    FStopRequested: boolean;
    FFailed: boolean;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
    destructor Destroy; override;
    procedure StopPlayback;
    { Копирует текущий кадр в ADst (буфер TargetWidth*TargetHeight*4
      байт, уже выделенный вызывающим — тот же размер, что и у
      внутреннего FFrameBuf), если готовый кадр НОВЕЕ AKnownVersion —
      обновляет AKnownVersion и возвращает True (виджету нужно
      перерисоваться). Кадра ещё нет ИЛИ он не новее уже виденного —
      False, ADst не трогается. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    { Декодер не смог открыть/прочитать файл вовсе (битый/неизвестный
      кодек) — виджет в этом случае просто не покажет анимацию
      (остаётся на плейсхолдере), без падения. }
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
  { FreeOnTerminate=True (см. комментарий в шапке юнита) — этот
    деструктор вызывается САМИМ потоком, изнутри TThread-машинерии
    завершения, ПОСЛЕ того как Execute уже вернул управление; вызывающая
    сторона (framehistory.pas) сюда не заходит вовсе, только шлёт
    StopPlayback и сразу забывает указатель. }
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

  { Один декодированный кадр -> BGRA -> общий буфер -> пауза до
    следующего, по разнице PTS исходного видео (не фиксированный
    интервал — переменный fps на практике встречается). }
  procedure HandleFrame;
  var
    NowPtsSec, DelaySec: double;
    DelayMs: integer;
  begin
    if Sws = nil then begin
      Sws := sws_getContext(Frame^.width, Frame^.height, Frame^.format,
        FTargetW, FTargetH, AV_PIX_FMT_BGRA, SWS_BILINEAR, nil, nil, nil);
      if Sws = nil then begin
        FFailed := True;
        FStopRequested := True;
        Exit;
      end;
    end;

    DstData[0] := TmpBuf;
    DstLinesize[0] := FTargetW * 4;
    sws_scale(Sws, @Frame^.data[0], @Frame^.linesize[0], 0, Frame^.height,
      @DstData[0], @DstLinesize[0]);

    FLock.Enter;
    try
      Move(TmpBuf^, FFrameBuf^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      Inc(FFrameVersion);
    finally
      FLock.Leave;
    end;

    { Frame.pts = Low(Int64) — тот же битовый паттерн, что AV_NOPTS_VALUE
      (libavutil/avutil.h: ((int64_t)UINT64_C(0x8000000000000000)),
      сверено по заголовку, не угадано) — валидного таймштампа нет,
      выдерживаем дефолтную паузу ~25кадр/с. Не первый кадр витка
      (HaveLastPts) — пауза из РАЗНИЦЫ PTS в реальных секундах,
      ограниченная разумным диапазоном на случай мусорного PTS
      (отрицательного или неправдоподобно большого — залипший декодер
      в цикле не должен превратиться в подвисание виджета). }
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

  { Основной цикл — при достижении конца контейнера перематывает поток
    на начало и продолжает: "гифка" крутится, пока виджет жив, никакого
    "доиграл и остановился" состояния у неё нет (по требованию
    пользователя — без плей/пауза/стоп контролов, только луп). }
  while not FStopRequested do begin
    Ret := av_read_frame(FmtCtx, Pkt);
    if Ret < 0 then begin
      { Конец контейнера — перемотка на начало. avcodec_flush_buffers
        обязателен здесь: без него декодер продолжает попытки
        достроить кадры из данных ДО прыжка (см. её же комментарий в
        ffdecode.pas), что на MP4/H.264 стабильно даёт "кашу"/зелёные
        кадры на первом витке после первого зацикливания. }
      av_seek_frame(FmtCtx, VideoStreamIdx, 0, AVSEEK_FLAG_BACKWARD);
      avcodec_flush_buffers(CodecCtx);
      HaveLastPts := False;
      Continue;
    end;
    if Pkt^.stream_index = VideoStreamIdx then begin
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
  avformat_close_input(FmtCtx);
  FreeMem(TmpBuf);
end;

end.
