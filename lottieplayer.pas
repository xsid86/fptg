unit lottieplayer;

{$mode objfpc}{$H+}

{ Зацикленное воспроизведение одного TGS-стикера (Lottie/векторная
  анимация, gzip-сжатый JSON) — тот же принцип поток-декодер +
  разделяемый кадровый буфер, что и у TAnimationPlayer (videoplayer.pas,
  "гифки"), просто вместо FFmpeg — rlottie (см. её же комментарий в
  rlottie.pas). Разница по существу от видео-декода: у Lottie не нужен
  контейнер/пакеты — вся анимация уже целиком разобрана в памяти
  (lottie_animation_from_data), кадр НОМЕРОМ рендерится напрямую
  (lottie_animation_render), произвольный доступ, без последовательного
  чтения — цикл здесь просто "нарисовать кадр N, подождать 1/framerate,
  N:=(N+1) mod totalframes", без seek/flush-специфики видео-декодеров.

  Формат вывода — ARGB32_Premultiplied (см. rlottie.pas) — виджет
  (framehistory.pas, DrawPremultipliedArgbBuffer) знает про это и
  композитит через GDI AlphaBlend, не через SetDIBitsToDevice (тот, как
  и у "гифки", просто заменяет пиксели, без альфы — стикеры, в отличие
  от опрятного видео, почти всегда прозрачные).

  FreeOnTerminate=True, по ТОЙ ЖЕ причине, что и у TAnimationPlayer:
  стикеров на экране одновременно может быть сколько угодно, каждый со
  своим независимым виджетом/потоком, Stop — частый вызов при скролле,
  синхронный WaitFor из UI недопустим. }

interface

uses
  Classes, SysUtils, SyncObjs, Math, Windows, MMSystem, zstream, rlottie;

const
  { Рендерить напрямую в размер показа (обычно STICKER_MAX_SIZE=170) —
    заметно "паршиво" (прямой отчёт пользователя со скриншотом):
    растеризатор при таком мелком целевом размере теряет тонкие детали
    (мелкие пятна, обводки, границу белого живота у пушистых
    персонажей) — не баг компоновки/альфы на стороне Pascal (проверено
    отдельно, вне Pascal — см. её же запись в CLAUDE.md: та же самая
    DLL, тот же файл, официальный example/lottie2gif.exe при рендере
    ПРЯМО в 170×170 даёт визуально то же самое смазанное "паршивое"
    изображение, что и в приложении; тот же файл, отрендеренный в
    512×512 и уменьшенный до 170×170 фильтром — все детали на месте).
    Решение — тот же приём, что уже применяется для фото/аудио-обложек
    в проекте: рендерить в БОЛЬШЕМ внутреннем разрешении, потом
    уменьшать до размера показа усреднением блоков (BoxDownscaleArgb
    ниже) — не нагружать растеризатор мелкой целевой сеткой напрямую. }
  RENDER_SCALE = 3;
  RENDER_MAX_DIM = 512;

type
  TLottiePlayer = class(TThread)
  private
    FFilePath: utf8string;
    FTargetW, FTargetH: integer;
    { SyncObjs.TCriticalSection — квалифицировано явно: Windows (в uses
      ради GetTickCount64) объявляет СВОЙ, несовместимый TCriticalSection
      (внутренний RTL-тип, не класс с Enter/Leave/Create) — та же
      ловушка, что уже документирована в mediaplayer.pas/framehistory.pas. }
    FLock: SyncObjs.TCriticalSection;
    FFrameBuf: PByte;         { ARGB32_Premultiplied, FTargetW*FTargetH*4 байт, под FLock }
    FFrameVersion: cardinal;
    FStopRequested: boolean;
    FFailed: boolean;
    { Распаковывает .tgs (gzip) целиком в память — TGZFileStream (paszlib,
      уже в комплекте FPC, чистый Pascal, без внешней zlib.dll) читает
      сам файл по имени и сам разбирает gzip-заголовок. Небольшие файлы
      (типичный TGS — единицы-десятки КБ распакованного JSON) — читать
      блоками с ростом буфера, не пытаясь угадать итоговый размер
      заранее (сам gzip-заголовок не хранит точный размер полезной
      нагрузки, только оригинальный размер по модулю 2^32 в футере,
      которым TGZFileStream не пользуется). }
    function LoadJson: utf8string;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
    destructor Destroy; override;
    procedure StopPlayback;
    { Тот же контракт, что и TAnimationPlayer.TryGetFrame. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property Failed: boolean read FFailed;
  end;

implementation

constructor TLottiePlayer.Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
begin
  inherited Create(True);
  FFilePath := AFilePath;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FLock := SyncObjs.TCriticalSection.Create;
  FreeOnTerminate := True;
  Start;
end;

destructor TLottiePlayer.Destroy;
begin
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TLottiePlayer.StopPlayback;
begin
  FStopRequested := True;
end;

function TLottiePlayer.TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
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

function TLottiePlayer.LoadJson: utf8string;
var
  Gz: TGZFileStream;
  Chunk: array[0..65535] of byte;
  N: longint;
  Mem: TMemoryStream;
begin
  Result := '';
  Gz := nil;
  Mem := TMemoryStream.Create;
  try
    try
      Gz := TGZFileStream.Create(FFilePath, gzopenread);
    except
      { Создание не удалось (нет файла/битый gzip) — Gz так и остался
        nil, ниже до него дело не доходит вовсе; Exit здесь размотает
        стек ЧЕРЕЗ внешний try/finally (Mem.Free) — тот и только тот
        освобождает Mem, ровно один раз. }
      Exit;
    end;
    try
      repeat
        N := Gz.Read(Chunk, SizeOf(Chunk));
        if N > 0 then begin
          Mem.WriteBuffer(Chunk, N);
        end;
      until N < SizeOf(Chunk);
    finally
      Gz.Free;
    end;
    if Mem.Size > 0 then begin
      SetLength(Result, Mem.Size);
      Mem.Position := 0;
      Mem.ReadBuffer(Result[1], Mem.Size);
    end;
  finally
    Mem.Free;
  end;
end;

procedure TLottiePlayer.Execute;
begin
  try
    ExecuteInner;
  except
    on E: Exception do begin
      FFailed := True;
    end;
  end;
end;

{ Уменьшает ASrc (ARGB32_Premultiplied, ASrcW x ASrcH) до ADst (ADstW x
  ADstH) усреднением прямоугольного блока исходных пикселей на каждый
  пиксель результата — простой box-фильтр, не билинейный/Ланцош
  (та точность не нужна — цель ровно "не терять тонкие детали при
  прямом рендере в мелкий размер", не художественное качество
  ресемплинга). Усреднение — НАПРЯМУЮ по преумноженным ARGB-каналам,
  без де-преумножения туда-обратно: для преумноженной альфы это
  математически корректно (среднее преумноженных значений — то же
  самое, что взвешенное альфой смешение) и одновременно самый дешёвый
  вариант. Каждый исходный пиксель посещается РОВНО один раз суммарно
  по всем выходным — O(ASrcW*ASrcH), не дороже, чем sws_scale на
  сопоставимых размерах кадра видео в этом же проекте. }
procedure BoxDownscaleArgb(ASrc: PByte; ASrcW, ASrcH: integer; ADst: PByte; ADstW, ADstH: integer);
var
  X, Y, SX, SY, SX0, SX1, SY0, SY1: integer;
  SumB, SumG, SumR, SumA, Cnt: cardinal;
  SP, DP: PByte;
begin
  { Форк Telegram X (см. шапку юнита/CLAUDE.md) пишет пиксели в порядке
    R,G,B,A, а не B,G,R,A, как vanilla rlottie и как ожидает остальной
    пайплайн проекта (DrawPremultipliedArgbBuffer/GDI AlphaBlend,
    рассчитанные на обычный Windows DIB) — несмотря на ОДИНАКОВУЮ
    документацию "ARGB32_Premultiplied" в обоих rlottie.h. Проверено
    не по коду (там пришлось бы вычитывать весь vdrawhelper.cpp), а
    практически — один и тот же пиксель одного и того же кадра одного
    и того же файла: vanilla (94,191,246), этот форк (248,193,96) —
    R и B поменяны местами, G совпадает. Меняем местами здесь же, при
    чтении источника — Move ниже (в FFrameBuf/AlphaBlend) остаётся
    прежним. }

  for Y := 0 to ADstH - 1 do begin
    SY0 := (Y * ASrcH) div ADstH;
    SY1 := ((Y + 1) * ASrcH) div ADstH;
    if SY1 <= SY0 then begin
      SY1 := SY0 + 1;
    end;
    for X := 0 to ADstW - 1 do begin
      SX0 := (X * ASrcW) div ADstW;
      SX1 := ((X + 1) * ASrcW) div ADstW;
      if SX1 <= SX0 then begin
        SX1 := SX0 + 1;
      end;
      SumB := 0;
      SumG := 0;
      SumR := 0;
      SumA := 0;
      Cnt := 0;
      for SY := SY0 to SY1 - 1 do begin
        for SX := SX0 to SX1 - 1 do begin
          SP := ASrc + (cardinal(SY) * cardinal(ASrcW) + cardinal(SX)) * 4;
          Inc(SumB, SP[2]);   { источник хранит R здесь — см. комментарий выше }
          Inc(SumG, SP[1]);
          Inc(SumR, SP[0]);   { источник хранит B здесь }
          Inc(SumA, SP[3]);
          Inc(Cnt);
        end;
      end;
      DP := ADst + (cardinal(Y) * cardinal(ADstW) + cardinal(X)) * 4;
      DP[0] := SumB div Cnt;
      DP[1] := SumG div Cnt;
      DP[2] := SumR div Cnt;
      DP[3] := SumA div Cnt;
    end;
  end;
end;

procedure TLottiePlayer.ExecuteInner;
var
  Json: utf8string;
  Anim: PLottieAnimation;
  TotalFrames: SizeUInt;
  FrameRate: double;
  FrameNum: SizeUInt;
  TmpBuf: PByte;
  RenderBuf: PByte;
  RenderW, RenderH: integer;
  AnchorTick, TargetTick, NowTick: QWord;
  CycleMs: QWord;
  SleepMs: integer;
begin
  Json := LoadJson;
  if Json = '' then begin
    FFailed := True;
    Exit;
  end;

  Anim := lottie_animation_from_data(PAnsiChar(Json), PAnsiChar(FFilePath), '');
  if Anim = nil then begin
    FFailed := True;
    Exit;
  end;

  TotalFrames := lottie_animation_get_totalframe(Anim);
  FrameRate := lottie_animation_get_framerate(Anim);
  if (TotalFrames = 0) or (FrameRate <= 0) then begin
    FFailed := True;
    lottie_animation_destroy(Anim);
    Exit;
  end;

  RenderW := Min(FTargetW * RENDER_SCALE, RENDER_MAX_DIM);
  RenderH := Min(FTargetH * RENDER_SCALE, RENDER_MAX_DIM);
  if RenderW < FTargetW then begin
    RenderW := FTargetW;
  end;
  if RenderH < FTargetH then begin
    RenderH := FTargetH;
  end;

  GetMem(RenderBuf, cardinal(RenderW) * cardinal(RenderH) * 4);
  GetMem(TmpBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
  GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);

  { Рендер — в RenderBuf (внутреннее разрешение, ВЫШЕ размера показа,
    см. константы выше), уменьшение — в TmpBuf, оба ВНЕ лока (рендер
    сложной анимации плюс downscale могут занять заметное время,
    держать лок всё это время означало бы подвешивать TryGetFrame,
    дёргаемый с UI-потока таймером опроса); под лок — только быстрый
    Move готового TmpBuf в разделяемый FFrameBuf, тот же приём, что и
    HandleFrame в TAnimationPlayer (videoplayer.pas).

    Сам рендер+downscale измерены отдельно (вне Pascal, ctypes/консольный
    тест) — ~1мс на рендер и ~0.5мс на BoxDownscaleArgb даже при
    510×510→170×170, вместе ~1.5мс, на порядок меньше кадрового
    бюджета (17-33мс) — они НЕ являются причиной "проигрывается
    медленнее официального клиента", вопреки первому предположению.
    `Sleep(N)` в Windows по умолчанию округляет паузу вверх до
    системного тика (обычно ~15.6мс) — `timeBeginPeriod(1)` (winmm.dll,
    тот же юнит MMSystem, что уже используется в проекте для аудио)
    исправляет это (измерено отдельно: `Sleep(17)`×60 — 20.3мс в
    среднем без него, 17.18мс с ним) — но САМО ПО СЕБЕ тоже оказалось
    недостаточно: "СЧИТАТЬ ОСТАТОК ОТ НАЧАЛА ЭТОЙ ЖЕ ИТЕРАЦИИ"
    (`IterStart` на каждый заход цикла заново) не имеет ПАМЯТИ о
    предыдущих кадрах — если хоть один кадр опоздал (пусть даже на
    доли миллисекунды — планировщик ОС, конкуренция с другими потоками
    процесса, remaining Sleep-погрешность) это опоздание НИКОГДА не
    компенсируется, оно просто повторяется на КАЖДОМ следующем кадре
    ровно того же типа — за десятки/сотни кадров зацикленного показа
    складывается в заметный, растущий уход от реального времени, при
    том что каждый ОТДЕЛЬНЫЙ кадр в моменте выглядел "почти вовремя".

    Правка — интервалы отсчитываются от ОДНОЙ фиксированной точки
    начала цикла (`AnchorTick`), не от начала каждой итерации: целевое
    время показа кадра N — `AnchorTick + Round(N * (1000/FrameRate))`,
    спим до этого МОМЕНТА, а не отведённое количество миллисекунд
    "с нуля". Если какой-то кадр опоздал — следующий проснётся РАНЬШЕ
    (или вовсе не будет спать), забирая ровно то время, что было
    потеряно — самокорректирующаяся схема, ошибка НЕ накапливается.

    Правка №2 (по отчёту "проигрывается чуть-чуть быстрее оригинала",
    ~0.9% на типичных 116 кадрах/60к-с — ровно 1 кадр из 116, не
    догадка, а прямое следствие арифметики ниже). Первая версия на
    каждом витке зацикливания (FrameNum вновь 0) переставляла AnchorTick
    на `GetTickCount64` — то есть на ФАКТИЧЕСКОЕ "сейчас", ПОЧТИ СРАЗУ
    после того, как был показан последний кадр цикла (TotalFrames-1) —
    у этого последнего кадра из-за этого не оставалось СВОЕГО интервала
    показа вовсе (следующий, "нулевой" кадр нового цикла целился в то
    же самое "сейчас", без ожидания) — весь цикл длился
    `(TotalFrames-1)/FrameRate` вместо честных `TotalFrames/FrameRate`.
    Исправлено — на витке `AnchorTick` не пересэмплируется из
    `GetTickCount64`, а СДВИГАЕТСЯ на ТОЧНУЮ длину одного полного цикла
    (`CycleMs`), сохраняя показ последнего кадра на полный положенный
    интервал; самокоррекция (см. выше) при этом не теряется — если
    реальное время уже обогнало новый целевой момент (система была
    занята/зависла), `TargetTick > NowTick` просто окажется ложным, и
    кадр покажется без ожидания, тем же путём, что и раньше. }
  CycleMs := QWord(Round(TotalFrames * (1000.0 / FrameRate)));
  timeBeginPeriod(1);
  try
    FrameNum := 0;
    AnchorTick := GetTickCount64;
    while not FStopRequested do begin
      lottie_animation_render(Anim, FrameNum, PCardinal(RenderBuf), RenderW, RenderH, RenderW * 4);
      BoxDownscaleArgb(RenderBuf, RenderW, RenderH, TmpBuf, FTargetW, FTargetH);

      FLock.Enter;
      try
        Move(TmpBuf^, FFrameBuf^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
        Inc(FFrameVersion);
      finally
        FLock.Leave;
      end;

      Inc(FrameNum);
      if FrameNum >= TotalFrames then begin
        FrameNum := 0;
        Inc(AnchorTick, CycleMs);
      end;

      TargetTick := AnchorTick + QWord(Round(FrameNum * (1000.0 / FrameRate)));
      NowTick := GetTickCount64;
      if TargetTick > NowTick then begin
        SleepMs := integer(TargetTick - NowTick);
        Sleep(SleepMs);
      end;
    end;
  finally
    timeEndPeriod(1);
  end;

  lottie_animation_destroy(Anim);
  FreeMem(TmpBuf);
  FreeMem(RenderBuf);
end;

end.
