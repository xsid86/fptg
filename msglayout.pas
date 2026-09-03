unit msglayout;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, Graphics,
  constants, tdmessages;

type
  TRunKind = (rkText, rkLink);

  { Один "прогон" текста — слово или его кусок после жёсткого переноса,
    уже измеренный и позиционированный внутри локальных координат
    контента сообщения (0,0 — левый верхний угол области под текст,
    БЕЗ отступов бабла — их накладывает framehistory). }
  TTextRun = record
    Kind:               TRunKind;
    Rect:               TRect;
    Text:               utf8string;
    URL:                utf8string;   { только rkLink }
    Bold, Italic:       boolean;
    { Байтовые смещения в TMsgRow.PlainText, CharEnd не включая —
      как у TMsgEntity. Нужны выделению текста и copy. }
    CharStart, CharEnd: integer;
  end;
  TTextRunArray = array of TTextRun;

  { Кэш разметки одного сообщения. Хранится в TMsgRow.LayoutCache как
    непрозрачный TObject — tdmessages о TMsgLayout не знает. }
  TMsgLayout = class
  public
    CachedWidth: integer;
    Height:      integer;
    Runs:        TTextRunArray;
  end;

  TMsgLayoutCtx = record
    Canvas:     TCanvas;
    AvailWidth: integer;
  end;

  TMsgHitKind = (mhkNone, mhkText, mhkLink, mhkAudioWidget);
  TMsgHit = record
    Kind:       TMsgHitKind;
    URL:        utf8string;
    CharOffset: integer;   { байтовое смещение в PlainText; -1, если неприменимо }
  end;

  { TMsgContentRenderer

    Точка расширения по типу контента сообщения: один класс на вид
    (текст, аудио, будущие фото/видео/стикеры), реестр — RendererFor
    ниже. Framehistory всегда работает через эту абстракцию и не знает
    про конкретные классы-наследники. }
  TMsgContentRenderer = class
  public
    { Возвращает высоту при данной доступной ширине; попутно
      (пере)строит и кладёт разметку в ARow.LayoutCache. }
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; virtual; abstract;
    { ASelStart/ASelEnd — байтовый диапазон выделения в PlainText ЭТОГО
      сообщения (уже посчитанный вызывающим на границах многосообщенного
      выделения); ASelStart < 0 означает «выделения нет». }
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); virtual; abstract;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; virtual;
    { True только у аудио: framehistory заводит для таких строк
      настоящий дочерний control из пула, а не рисует их сама. }
    function WantsWidget: boolean; virtual;
  end;

{ Реестр — простой lookup по виду контента. Сюда позже подключатся
  TAnimationContentRenderer/TStickerContentRenderer без изменений в
  framehistory. }
function RendererFor(AKind: TMsgContentKind): TMsgContentRenderer;

{ Целевой размер превью фото по натуральным ANaturalW/ANaturalH —
  общая формула для TPhotoContentRenderer.Measure/Paint (высота строки)
  И TFileWidget-аналога в framehistory.pas (сам рендер) — один источник
  правды, а не две копии одной арифметики. Вертикальное изображение
  (height>width) — ограничена ширина (PHOTO_MAX_WIDTH), горизонтальное
  — высота (PHOTO_MAX_HEIGHT); маленькие изображения не увеличиваем. }
procedure ComputePhotoPreviewSize(ANaturalW, ANaturalH: integer; out AOutW, AOutH: integer);

implementation

{ ---------------- разбор текста в runs ---------------- }

{ Длина UTF-8 символа по ведущему байту — та же логика, что в
  avatarcache/tdmessages. msglayout не тянет ни один из этих юнитов
  (avatarcache — LCL/BGRABitmap, tdmessages было бы обратной
  зависимостью), поэтому копия локальная. }
function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;
  end else if AByte < $E0 then begin
    Result := 2;
  end else if AByte < $F0 then begin
    Result := 3;
  end else begin
    Result := 4;
  end;
end;

{ Жадный перенос по словам с ручной раскладкой стилей по entity-спанам.
  Гранулярность — слово: если слово целиком попадает в спан ссылки —
  вся ссылка кликабельна целиком, если частично — граница округляется
  до начала слова. Для реальных сообщений (ссылка — токен без пробелов,
  либо именованная ссылка на несколько слов) это не приближение, а
  точный случай; для экзотики (спан обрывается на середине слова) —
  упрощение, приемлемое для v1. }
function WrapText(const AText: utf8string; const AEntities: TMsgEntityArray;
  ACanvas: TCanvas; AAvailWidth: integer; out AHeight: integer): TTextRunArray;
var
  N, I, WordStart, WordLen, LineTop, CurX, LineH, Cap, Cnt: integer;
  SpaceW: integer;
  AtLineStart: boolean;

  function StyleAt(APos: integer; out ABold, AItalic: boolean;
    out ALinkKind: TMsgEntityKind; out ALinkUrl: utf8string): boolean;
  var
    J: integer;
    E: TMsgEntity;
  begin
    ABold := False;
    AItalic := False;
    ALinkKind := mekNone;
    ALinkUrl := '';
    Result := False;
    for J := 0 to High(AEntities) do begin
      E := AEntities[J];
      if (APos >= E.ByteStart) and (APos < E.ByteStart + E.ByteLen) then begin
        case E.Kind of
          mekBold:   ABold := True;
          mekItalic: AItalic := True;
          mekUrl, mekTextUrl:
            begin
              ALinkKind := E.Kind;
              ALinkUrl := E.URL;
              Result := True;
            end;
        end;
      end;
    end;
  end;

  procedure EnsureCap(ANeed: integer);
  begin
    if ANeed > Cap then begin
      Cap := ANeed + 16;
      SetLength(Result, Cap);
    end;
  end;

  procedure EmitChunk(AStart, ALen, AW: integer; ABold, AItalic, AIsLink: boolean;
    const AUrl: utf8string);
  begin
    EnsureCap(Cnt + 1);
    if AIsLink then begin
      Result[Cnt].Kind := rkLink;
    end else begin
      Result[Cnt].Kind := rkText;
    end;
    Result[Cnt].Rect := Rect(CurX, LineTop, CurX + AW, LineTop + LineH);
    Result[Cnt].Text := Copy(AText, AStart, ALen);
    Result[Cnt].Bold := ABold;
    Result[Cnt].Italic := AItalic;
    Result[Cnt].CharStart := AStart;
    Result[Cnt].CharEnd := AStart + ALen;
    Result[Cnt].URL := AUrl;
    Inc(Cnt);
    CurX := CurX + AW;
    AtLineStart := False;
  end;

  { Слово не влезает в строку целиком ни при каких обстоятельствах —
    режем по символам, иначе вылезли бы за правый край или зациклились
    на пустой строке. }
  procedure HardBreakChars(AStart, ALen: integer; ABold, AItalic, AIsLink: boolean;
    const AUrl: utf8string);
  var
    P, CLen, ChunkStart, ChunkLen, ChW, AccW: integer;
    Ch: utf8string;
  begin
    P := AStart;
    ChunkStart := AStart;
    ChunkLen := 0;
    AccW := 0;
    while P < AStart + ALen do begin
      CLen := Utf8CharLen(byte(AText[P]));
      if P + CLen - 1 > AStart + ALen - 1 then begin
        CLen := AStart + ALen - P;
      end;
      Ch := Copy(AText, P, CLen);
      ChW := ACanvas.TextWidth(string(Ch));

      if (ChunkLen > 0) and (CurX + AccW + ChW > AAvailWidth) then begin
        EmitChunk(ChunkStart, ChunkLen, AccW, ABold, AItalic, AIsLink, AUrl);
        CurX := 0;
        Inc(LineTop, LineH);
        AtLineStart := True;
        ChunkStart := P;
        ChunkLen := 0;
        AccW := 0;
      end;

      Inc(ChunkLen, CLen);
      Inc(AccW, ChW);
      Inc(P, CLen);
    end;
    if ChunkLen > 0 then begin
      EmitChunk(ChunkStart, ChunkLen, AccW, ABold, AItalic, AIsLink, AUrl);
    end;
  end;

  procedure EmitWord(AStart, ALen: integer);
  var
    W: integer;
    Txt: utf8string;
    Bold, Italic, IsLink: boolean;
    LKind: TMsgEntityKind;
    LUrl: utf8string;
  begin
    IsLink := StyleAt(AStart, Bold, Italic, LKind, LUrl);
    if LKind = mekUrl then begin
      LUrl := Copy(AText, AStart, ALen);   { авто-ссылка — URL это сам текст }
    end;

    ACanvas.Font.Style := [];
    if Bold then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsBold];
    end;
    if Italic then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsItalic];
    end;
    Txt := Copy(AText, AStart, ALen);
    W := ACanvas.TextWidth(string(Txt));

    if W > AAvailWidth then begin
      HardBreakChars(AStart, ALen, Bold, Italic, IsLink, LUrl);
      Exit;
    end;

    if (not AtLineStart) and (CurX + W > AAvailWidth) then begin
      CurX := 0;
      Inc(LineTop, LineH);
      AtLineStart := True;
    end;

    EmitChunk(AStart, ALen, W, Bold, Italic, IsLink, LUrl);
  end;

begin
  Cnt := 0;
  Cap := 0;
  SetLength(Result, 0);
  CurX := 0;
  LineTop := 0;
  AtLineStart := True;

  ACanvas.Font.Style := [];
  LineH := ACanvas.TextHeight('Щ') + LINE_LEADING;
  SpaceW := ACanvas.TextWidth(' ');

  N := Length(AText);
  I := 1;
  while I <= N do begin
    if AText[I] = #10 then begin
      CurX := 0;
      Inc(LineTop, LineH);
      AtLineStart := True;
      Inc(I);
      Continue;
    end;
    if AText[I] in [' ', #9, #13] then begin
      if not AtLineStart then begin
        CurX := CurX + SpaceW;
      end;
      Inc(I);
      Continue;
    end;

    WordStart := I;
    while (I <= N) and not (AText[I] in [' ', #9, #10, #13]) do begin
      Inc(I);
    end;
    WordLen := I - WordStart;
    EmitWord(WordStart, WordLen);
  end;

  if Cnt = 0 then begin
    AHeight := 0;
  end else begin
    AHeight := LineTop + LineH;
  end;
  SetLength(Result, Cnt);
end;

procedure OffsetRuns(var ARuns: TTextRunArray; ADy: integer);
var
  I: integer;
begin
  if ADy = 0 then begin
    Exit;
  end;
  for I := 0 to High(ARuns) do begin
    ARuns[I].Rect.Top := ARuns[I].Rect.Top + ADy;
    ARuns[I].Rect.Bottom := ARuns[I].Rect.Bottom + ADy;
  end;
end;

{ Общий кэш-строитель для рендереров, у которых есть текстовый блок
  (сам текст либо подпись под плейсхолдером). ATopOffset — с какой
  Y-координаты начинается текст: 0 для обычного текста, высота блока
  превью + отступ для подписи. }
function EnsureTextLayout(ARow: TMsgRow; const ACtx: TMsgLayoutCtx;
  ATopOffset: integer): TMsgLayout;
var
  L: TMsgLayout;
  H: integer;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if (L = nil) or (L.CachedWidth <> ACtx.AvailWidth) then begin
    if L = nil then begin
      L := TMsgLayout.Create;
      ARow.LayoutCache := L;
    end;
    L.CachedWidth := ACtx.AvailWidth;
    L.Runs := WrapText(ARow.PlainText, ARow.Entities, ACtx.Canvas, ACtx.AvailWidth, H);
    OffsetRuns(L.Runs, ATopOffset);
    L.Height := ATopOffset + H;
  end;
  Result := L;
end;

procedure PaintRuns(ACanvas: TCanvas; const AOrigin: TPoint; const ARuns: TTextRunArray;
  ASelStart, ASelEnd: integer);
var
  I: integer;
  R: TTextRun;
  HasSel: boolean;
begin
  HasSel := (ASelStart >= 0) and (ASelEnd > ASelStart);
  for I := 0 to High(ARuns) do begin
    R := ARuns[I];
    { Подсветка — целым run'ом (словом), если он хотя бы частично попал
      в диапазон выделения. Точная подсветка внутри слова — не в этом
      заходе: гранулярность выделения и так словная (см. framehistory). }
    if HasSel and (R.CharEnd > ASelStart) and (R.CharStart < ASelEnd) then begin
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := clHighlight;
      ACanvas.FillRect(Rect(AOrigin.X + R.Rect.Left, AOrigin.Y + R.Rect.Top,
        AOrigin.X + R.Rect.Right, AOrigin.Y + R.Rect.Bottom));
    end;
    ACanvas.Brush.Style := bsClear;

    ACanvas.Font.Style := [];
    if R.Bold then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsBold];
    end;
    if R.Italic then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsItalic];
    end;
    if R.Kind = rkLink then begin
      ACanvas.Font.Color := clHighlight;
      ACanvas.Font.Style := ACanvas.Font.Style + [fsUnderline];
    end else begin
      ACanvas.Font.Color := clWindowText;
    end;
    ACanvas.TextOut(AOrigin.X + R.Rect.Left, AOrigin.Y + R.Rect.Top, string(R.Text));
  end;
end;

function HitTestRuns(const ARuns: TTextRunArray; LocalX, LocalY: integer): TMsgHit;
var
  I: integer;
  R: TTextRun;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
  for I := 0 to High(ARuns) do begin
    R := ARuns[I];
    if (LocalY >= R.Rect.Top) and (LocalY < R.Rect.Bottom) and
       (LocalX >= R.Rect.Left) and (LocalX < R.Rect.Right) then begin
      if R.Kind = rkLink then begin
        Result.Kind := mhkLink;
        Result.URL := R.URL;
      end else begin
        Result.Kind := mhkText;
      end;
      Result.CharOffset := R.CharStart;
      Exit;
    end;
  end;
end;

{ ---------------- TMsgContentRenderer (база) ---------------- }

function TMsgContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
end;

function TMsgContentRenderer.WantsWidget: boolean;
begin
  Result := False;
end;

{ ---------------- текст ---------------- }

type
  TTextContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
  end;

function TTextContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := EnsureTextLayout(ARow, ACtx, 0).Height;
end;

procedure TTextContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer);
var
  Ctx: TMsgLayoutCtx;
  L: TMsgLayout;
begin
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, 0);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TTextContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

{ ---------------- аудио: реальный виджет (framehistory.TAudioWidget) ---------------- }

type
  TAudioContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); override;
    function WantsWidget: boolean; override;
  end;

function TAudioContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := AUDIO_WIDGET_H;
end;

procedure TAudioContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer);
begin
  { Подложка на случай кадра до того, как framehistory успеет
    позиционировать поверх настоящий TAudioWidget из пула — сам
    виджет рисует себя сам поверх этого прямоугольника. }
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(ARect);
end;

function TAudioContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- файл-документ: реальный виджет (framehistory.TFileWidget) ----------------
  Та же схема, что и у аудио — этот renderer только резервирует высоту
  и рисует подложку-заглушку на кадр до того, как TFrameHistory
  позиционирует поверх настоящий TFileWidget из своего пула. }

type
  TDocContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); override;
    function WantsWidget: boolean; override;
  end;

function TDocContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := FILE_WIDGET_H;
end;

procedure TDocContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer);
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(ARect);
end;

function TDocContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- фото: реальный виджет (framehistory.TPhotoWidget) ---------------- }

procedure ComputePhotoPreviewSize(ANaturalW, ANaturalH: integer; out AOutW, AOutH: integer);
begin
  if (ANaturalW <= 0) or (ANaturalH <= 0) then begin
    AOutW := PHOTO_MAX_WIDTH;
    AOutH := PHOTO_MAX_HEIGHT;
    Exit;
  end;
  if ANaturalH > ANaturalW then begin
    { Вертикальное — ограничена ширина, высота пропорционально. }
    AOutW := Min(ANaturalW, PHOTO_MAX_WIDTH);
    AOutH := Round(ANaturalH * (AOutW / ANaturalW));
  end else begin
    { Горизонтальное (или квадратное) — ограничена высота. }
    AOutH := Min(ANaturalH, PHOTO_MAX_HEIGHT);
    AOutW := Round(ANaturalW * (AOutH / ANaturalH));
  end;
end;

type
  TPhotoContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
    function WantsWidget: boolean; override;
  end;

function TPhotoContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
var
  ImgW, ImgH: integer;
begin
  ComputePhotoPreviewSize(ARow.PhotoWidth, ARow.PhotoHeight, ImgW, ImgH);
  if ARow.PlainText = '' then begin
    Result := ImgH;
  end else begin
    { Подпись — во всю доступную ширину колонки, не ограничена шириной
      самого превью (та часто уже него). }
    Result := EnsureTextLayout(ARow, ACtx, ImgH + CAPTION_GAP).Height;
  end;
end;

procedure TPhotoContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer);
var
  ImgW, ImgH: integer;
  L: TMsgLayout;
  Ctx: TMsgLayoutCtx;
begin
  { Подложка на случай кадра до того, как framehistory успеет
    позиционировать поверх настоящий TPhotoWidget из пула — тот же
    приём, что и у аудио/файла. Только под превью, не во всю ширину:
    у фото свой натуральный размер, не "во всю колонку". }
  ComputePhotoPreviewSize(ARow.PhotoWidth, ARow.PhotoHeight, ImgW, ImgH);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(Rect(ARect.Left, ARect.Top, ARect.Left + ImgW, ARect.Top + ImgH));

  if ARow.PlainText = '' then begin
    Exit;
  end;
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, ImgH + CAPTION_GAP);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TPhotoContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

function TPhotoContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- видео/анимации/стикеры: плейсхолдер ---------------- }

type
  TPlaceholderContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
  end;

function PlaceholderLabel(AKind: TMsgContentKind): string;
begin
  case AKind of
    mckPhoto:     Result := 'Photo';
    mckAnimation: Result := 'GIF / video';
    mckSticker:   Result := 'Sticker';
    mckVoiceNote: Result := 'Voice message';
  else
    Result := 'Unsupported';
  end;
end;

function TPlaceholderContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
var
  TopOff: integer;
begin
  if ARow.PlainText = '' then begin
    TopOff := 0;
  end else begin
    TopOff := PLACEHOLDER_BOX_H + CAPTION_GAP;
  end;
  Result := EnsureTextLayout(ARow, ACtx, TopOff).Height;
  if ARow.PlainText = '' then begin
    Result := PLACEHOLDER_BOX_H;
  end;
end;

procedure TPlaceholderContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer);
var
  BoxRect: TRect;
  S: string;
  Sz: TSize;
  L: TMsgLayout;
  Ctx: TMsgLayoutCtx;
begin
  BoxRect := Rect(ARect.Left, ARect.Top, ARect.Left + PLACEHOLDER_BOX,
    ARect.Top + PLACEHOLDER_BOX_H);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(BoxRect);

  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Style := [];
  ACanvas.Font.Color := clGrayText;
  S := PlaceholderLabel(ARow.Kind);
  Sz := ACanvas.TextExtent(S);
  ACanvas.TextOut(BoxRect.Left + (PLACEHOLDER_BOX - Sz.cx) div 2,
    BoxRect.Top + (PLACEHOLDER_BOX_H - Sz.cy) div 2, S);

  if ARow.PlainText = '' then begin
    Exit;
  end;
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, PLACEHOLDER_BOX_H + CAPTION_GAP);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TPlaceholderContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

{ ---------------- реестр ---------------- }

var
  GTextRenderer:        TTextContentRenderer;
  GAudioRenderer:        TAudioContentRenderer;
  GDocRenderer:         TDocContentRenderer;
  GPhotoRenderer:       TPhotoContentRenderer;
  GPlaceholderRenderer: TPlaceholderContentRenderer;

function RendererFor(AKind: TMsgContentKind): TMsgContentRenderer;
begin
  case AKind of
    mckText:  Result := GTextRenderer;
    mckAudio: Result := GAudioRenderer;
    mckFile:  Result := GDocRenderer;
    mckPhoto: Result := GPhotoRenderer;
  else
    Result := GPlaceholderRenderer;
  end;
end;

initialization
  GTextRenderer := TTextContentRenderer.Create;
  GAudioRenderer := TAudioContentRenderer.Create;
  GDocRenderer := TDocContentRenderer.Create;
  GPhotoRenderer := TPhotoContentRenderer.Create;
  GPlaceholderRenderer := TPlaceholderContentRenderer.Create;

finalization
  GTextRenderer.Free;
  GAudioRenderer.Free;
  GDocRenderer.Free;
  GPhotoRenderer.Free;
  GPlaceholderRenderer.Free;

end.
