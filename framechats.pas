unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  avatarcache, BGRABitmap, BGRABitmapTypes,
  Classes, Clipbrd,
  Controls, constants, DateUtils, Dialogs, ExtCtrls, Forms, Graphics, Grids,
  Menus, StdCtrls, SysUtils, tdaccentcolors, tdauth, tdchats, tdcore, Types, uiframe;

type
  { Кликабельные области внутри строки. }
  TChatHitArea = (chaNone, chaBell, chaAvatar, chaHeader, chaPin);

  { Какой список показан. }
  TChatListMode = (clmMain, clmArchive);

  TChatSelectEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TAvatarClickEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TListModeEvent = procedure(Sender: TObject; AMode: TChatListMode) of object;

  { TFrameChats

    Список чатов на TDrawGrid: у сетки нет собственной коллекции строк,
    поэтому модель остаётся единственным хранилищем данных, а
    перестановка чата — это просто Invalidate.

    Строка чата (2026-09-08, редизайн по прямому запросу пользователя —
    "делаем элемент контакта таким же как и сообщения в истории")
    оформлена тем же визуальным языком, что и блок сообщения в
    framehistory.pas: скруглённая карточка, тонированная цветом чата
    (accent_color_id), заголовок (значок типа + аватар 24x24 + имя +
    время/галочка/пин/колокольчик) и область текста (превью + счётчик
    непрочитанных). framechats.pas НЕ может импортировать framehistory.pas
    (та сама уже импортирует framechats.pas — цикл), поэтому нужные
    отсюда мелкие функции (резолвер цвета, блендинг с фоном, скруглённая
    заливка/обводка) — свои копии той же логики, см. их комментарии
    ниже, не общий код. }

  TFrameChats = class(TFrameBase, ITdActiveListener)
    Grid:      TDrawGrid;
    icons12: TImageList;
    pnlBottom: TPanel;
    lblStatus: TLabel;
    mnuChat:   TPopupMenu;
    { Значки типов чата. Компонент положен на фрейм в дизайнере;
      имя должно совпадать с тем, что в .lfm. }
    ImageList1: TImageList;
    { Не используется кодом с редизайна псевдо-строк "Архив"/"Все чаты"
      под вид карточки (2026-09-08, четвёртый заход — те теперь берут
      значок из icons12, см. CHATROW_ICON_ARCHIVE/ALLCHATS) — поле
      оставлено НЕ убранным намеренно: компонент по-прежнему объявлен
      в .lfm, а убирать типизированное поле под уже существующий в
      дизайнере компонент рискованно без явной необходимости (не тот
      случай, где выигрыш стоит риска сломать стриминг). }
    ImageListBig: TImageList;
    procedure GridDrawCell(Sender: TObject; ACol, ARow: Integer; ARect: TRect; AState: TGridDrawState);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
  protected
    { Resize — виртуальный метод TControl, доступен всегда и не зависит
      от того, опубликовано ли одноимённое событие у потомка.
      У TDrawGrid оно НЕ опубликовано. }
    procedure Resize; override;
  private
    FCache:    TAvatarCache;
    FReady:    Boolean;
    FModel:    TTdChats;      { модель активного аккаунта }
    FBadges:   TStringList;   { кэш значков: ключ -> TBGRABitmap }
    FMeasure:  TBGRABitmap;   { 1x1 для замера текста тем же шрифтом }
    FReceipts: array[TChatReceipt, Boolean] of TBGRABitmap;
    FMenuRow:  TChatRow;
    FOnSelect: TChatSelectEvent;
    FOnListMode: TListModeEvent;
    FMode:     TChatListMode;
    FOnAvatar: TAvatarClickEvent;
    { Клик по значку/аватарке (chaBell/chaPin/chaAvatar) — CanSelect:=False,
      выделение вообще не двигаем, FOnSelect не зовём. }
    FSuppressSelect: Boolean;
    { Идёт переключение режима списка (chaHeader) — в отличие от
      FSuppressSelect, выделение ДВИГАТЬ нужно (CanSelect остаётся
      True — выделенным должен стать заголовок нового списка,
      "Архив"/"Все чаты", не прежняя строка из старого списка), но
      FOnSelect всё равно не зовём — переключение списка само по себе
      не должно открывать чат. Оба флага — "липкие": не сбрасывают
      себя изнутри GridSelectCell на первый же вызов, единственное
      место сброса — начало GridMouseDown, см. её же комментарий и
      CLAUDE.md за 2026-09-06 про то, почему одноразовый вариант не
      работал (Grid.RowCount:=... в ModelChanged может само по себе,
      независимо от Grid.Row:=0, синхронно перевызвать GridSelectCell
      ещё раз через CheckPosition в LCL). }
    FSwitchingMode: Boolean;
    procedure BindModel;
    procedure UnbindModel;
    { Архив — не чат: индекс 0 отдан ему, чаты сдвинуты на единицу.
      Фальшивый TChatRow завёл бы его в контекстное меню и в открытие
      чата, чего быть не должно. }
    function ChatAt(AGridRow: Integer): TChatRow;
    function TypeIconIndex(ARow: TChatRow): Integer;
    procedure DrawIcon12(const ARect: TRect; AIndex: Integer);
    { Единственный источник геометрии карточки строки — и отрисовка
      (GridDrawCell), и хит-тест (HitArea) считают одно и то же отсюда,
      не копируют формулы по отдельности (та самая, не раз документированная
      в этом проекте ловушка — см. CLAUDE.md про ContentPadV/ForwardCardRect
      в framehistory.pas). ARect — либо реальный прямоугольник ячейки
      (для отрисовки), либо (0,0,Width,Height) той же ячейки (для
      хит-теста, координаты клика уже локальные). Result — сама карточка
      (ARect за вычетом CHATROW_GAP снизу).
      AHasPin=False (архивный список — там пинить нельзя, по прямому
      запросу пользователя) — APinR схлопывается в нулевую ширину у
      левого края MuteR, а не просто перестаёт рисоваться: TitleRight
      (граница текста времени в GridDrawCell) считается от PinR.Left,
      и без реального сокращения этого прямоугольника время наехало бы
      на пустое место, где раньше был пин. }
    function ChatRowRects(const ARect: TRect; AHasPin: Boolean; out AHeader, AContent,
      AIconR, AAvatarR, AMuteR, APinR: TRect): TRect;
    { Одна проверка попадания на всех: и для нажатия, и для курсора.
      Дублировать геометрию в двух местах — верный способ развести
      их со временем. }
    function HitArea(X, Y: Integer; out ARow: TChatRow): TChatHitArea;
    procedure SetMode(AMode: TChatListMode);
    function RowsCount: Integer;
    procedure DrawHeaderRow(ARect: TRect; ASelected: Boolean);
    function BadgeBitmap(const AText: String; ASelected: Boolean): TBGRABitmap;
    function ReceiptBitmap(AKind: TChatReceipt; ASelected: Boolean): TBGRABitmap;
    procedure ModelChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: Integer; const AMessage, AAction: Utf8string);
    procedure LoadingChanged(Sender: TObject);
    procedure MaybeLoadMore;
    procedure BuildMenu(ARow: TChatRow);
    procedure MenuItemClick(Sender: TObject);
    function CurrentRow: TChatRow;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    property Selected: TChatRow read CurrentRow;
    property OnSelect: TChatSelectEvent read FOnSelect write FOnSelect;
    property Mode: TChatListMode read FMode write SetMode;
    property OnListMode: TListModeEvent read FOnListMode write FOnListMode;
    property OnAvatar: TAvatarClickEvent read FOnAvatar write FOnAvatar;
  end;

implementation

{$R *.lfm}

{ Отметка времени в стиле Telegram: сегодня — часы, вчера — словом,
  на этой неделе — день недели, дальше — дата. }
function ChatTimeStr(AUnix: Int64): String;
const
  WD: array[1..7] of String = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
var
  Dt, Today: TDateTime;
  Days:      Integer;
begin
  Result := '';
  if AUnix <= 0 then begin
    Exit;
  end;
  { TDLib отдаёт Unix-время в UTC — переводим в местное, иначе
    у пользователей вне UTC часы будут врать. }
  Dt    := UniversalTimeToLocal(UnixToDateTime(AUnix));
  Today := Date;
  Days  := Trunc(Today) - Trunc(Dt);

  if Days <= 0 then begin
    Result := FormatDateTime('hh:nn', Dt);   { 24 часа: hh, не ampm }
  end
  else if Days = 1 then begin
    Result := 'yesterday';
  end
  else if Days < 7 then begin
    Result := WD[DayOfWeek(Dt)];
  end
  else begin
    Result := FormatDateTime('dd.mm.yy', Dt);
  end;
end;

{ Цвет чата по кругу — своя копия ResolveAccentColor (framehistory.pas):
  та же идея (accent_color_id, из updateChatAccentColors — см.
  tdaccentcolors.pas — вместо хэша по id, когда он известен; хэш по
  SENDER_PALETTE запасным вариантом), но framechats.pas не может
  импортировать framehistory.pas (та сама уже импортирует framechats.pas
  — цикл), поэтому не общая функция, а независимая копия той же логики. }
function ChatAccentColor(ARow: TChatRow): TColor;
var
  AC: TTdAccentColors;
begin
  if ARow.AccentColorId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(ARow.AccentColorId, Result) then begin
      Exit;
    end;
  end;
  Result := SENDER_PALETTE[Abs(ARow.Id) mod Length(SENDER_PALETTE)];
end;

{ Смешивает AColor с ABackground в пропорции AOpacity (0..1) — своя
  копия BlendWithBackground (framehistory.pas), см. комментарий у
  ChatAccentColor про то, почему копия, а не общий код. }
function BlendWithBackground(AColor: TColor; AOpacity: double; ABackground: TColor): TColor;
var
  Fg, Bg: longint;
begin
  Fg := ColorToRGB(AColor);
  Bg := ColorToRGB(ABackground);
  Result := RGBToColor(
    Round((Bg and $FF) + AOpacity * ((Fg and $FF) - (Bg and $FF))),
    Round(((Bg shr 8) and $FF) + AOpacity * (((Fg shr 8) and $FF) - ((Bg shr 8) and $FF))),
    Round(((Bg shr 16) and $FF) + AOpacity * (((Fg shr 16) and $FF) - ((Bg shr 16) and $FF)))
  );
end;

{ Скруглённая заливка/обводка карточки строки — своя, урезанная копия
  PaintRoundRectAA (framehistory.pas, SMOOTH_CORNERS=False ветка): та
  же причина независимой копии, что и у ChatAccentColor выше, и тот же
  выбор способа рисовать — список чатов скроллится ровно так же часто,
  как история сообщений, и тот же урок про стоимость BGRA-антиалиасинга
  на каждый кадр (см. CLAUDE.md, 2026-09-04) применим здесь один в
  один — простой GDI Canvas.RoundRect, без единого TBGRABitmap.
  AOptions/[rrBottomLeftSquare, rrBottomRightSquare] — тот же трюк
  "спрямить низ" для заголовка карточки, что и у сообщений. }
procedure PaintCardRoundRect(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ABorderWidth: single = 1);
var
  IRadius: Integer;
begin
  if (ABox.Right - ABox.Left <= 0) or (ABox.Bottom - ABox.Top <= 0) then begin
    Exit;
  end;
  IRadius := Round(ARadius);
  ACanvas.Pen.Style := psClear;
  if ABorderColor <> clNone then begin
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := ABorderColor;
    ACanvas.Pen.Width := Round(ABorderWidth);
  end;
  if AFillColor <> clNone then begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFillColor;
  end else begin
    ACanvas.Brush.Style := bsClear;
  end;
  ACanvas.RoundRect(ABox.Left, ABox.Top, ABox.Right, ABox.Bottom, IRadius * 2, IRadius * 2);
  if (AFillColor <> clNone) and (rrBottomLeftSquare in AOptions) and
    (rrBottomRightSquare in AOptions) then begin
    ACanvas.Pen.Style := psClear;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFillColor;
    ACanvas.FillRect(Rect(ABox.Left, ABox.Bottom - IRadius, ABox.Right, ABox.Bottom));
  end;
end;

{ ---------------- жизненный цикл ---------------- }

constructor TFrameChats.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FCache := TAvatarCache.Create;

  FBadges := TStringList.Create;
  FBadges.Sorted := True;
  FBadges.Duplicates := dupIgnore;
  FBadges.OwnsObjects := False;

  FMeasure := TBGRABitmap.Create(1, 1);
  FMeasure.FontName := 'default';
  FMeasure.FontHeight := BADGE_FONT_H;
  FMeasure.FontStyle := [fsBold];
  FMeasure.FontQuality := fqFineAntialiasing;

  Grid.ColCount  := 1;
  Grid.FixedCols := 0;
  Grid.FixedRows := 0;
  Grid.RowCount  := 0;
  Grid.DefaultRowHeight := ROW_HEIGHT;
  Grid.MouseWheelOption := mwGrid;
  Grid.FocusRectVisible := False;

  { Флаг ставится последним: до него любой ранний вызов
    (Resize во время чтения .lfm) обязан ничего не делать. }
  FReady := True;
  BindModel;
  TdApp.SubscribeActive(Self);
end;

destructor TFrameChats.Destroy;
var
  I: Integer;
  K: TChatReceipt;
begin
  FReady := False;
  TdApp.UnsubscribeActive(Self);
  UnbindModel;
  FCache.Free;
  if FBadges <> nil then begin
    for I := 0 to FBadges.Count - 1 do begin
      FBadges.Objects[I].Free;
    end;
    FBadges.Free;
  end;
  FMeasure.Free;
  for K := Low(TChatReceipt) to High(TChatReceipt) do begin
    FReceipts[K, False].Free;
    FReceipts[K, True].Free;
  end;
  inherited Destroy;
end;

function TFrameChats.BadgeBitmap(const AText: String; ASelected: Boolean): TBGRABitmap;
var
  Key:    String;
  Idx, W: Integer;
  Sz:     TSize;
  BgCol, FgCol: TBGRAPixel;
  B:      TBGRABitmap;
begin
  { Значки повторяются (1, 2, 3...), а отрисовка текста со сглаживанием
    недёшева — поэтому кэшируем. Ключ включает выделение: на выделенной
    строке цвета инвертированы. }
  if ASelected then begin
    Key := AText + #1;
  end
  else begin
    Key := AText;
  end;

  Idx := FBadges.IndexOf(Key);
  if Idx >= 0 then begin
    Result := TBGRABitmap(FBadges.Objects[Idx]);
    Exit;
  end;

  Sz := FMeasure.TextSize(AText);
  W  := Sz.cx + BADGE_PAD * 2;
  if W < BADGE_H then begin
    W := BADGE_H;
  end;

  if ASelected then begin
    { На выделении фон строки уже clHighlight — значок пришлось бы
      искать глазами. Инвертируем, как в самом Telegram. }
    BgCol := ColorToBGRA(clWindow);
    FgCol := ColorToBGRA(clHighlight);
  end
  else begin
    BgCol := ColorToBGRA(clHighlight);
    FgCol := ColorToBGRA(clWindow);
  end;

  B := TBGRABitmap.Create(W, BADGE_H, BGRAPixelTransparent);
  B.FontName := 'default';
  B.FontHeight := BADGE_FONT_H;
  B.FontStyle := [fsBold];
  B.FontQuality := fqFineAntialiasing;

  { Последний параметр False переключает координаты на угловые —
    тогда (0,0,W,H) закрывает битмап целиком без поправок на 0.5. }
  B.FillRoundRectAntialias(0, 0, W, BADGE_H, BADGE_H / 2, BADGE_H / 2,
    BgCol, [], False);
  B.TextOut((W - Sz.cx) / 2, (BADGE_H - Sz.cy) / 2, AText, FgCol);

  while FBadges.Count >= BADGE_CACHE_MAX do begin
    FBadges.Objects[0].Free;
    FBadges.Delete(0);
  end;
  FBadges.AddObject(Key, B);
  Result := B;
end;

function TFrameChats.ReceiptBitmap(AKind: TChatReceipt; ASelected: Boolean): TBGRABitmap;
var
  B:   TBGRABitmap;
  Col: TBGRAPixel;
  W:   Integer;

  { Одна галочка со сдвигом по X. Координаты подобраны так, чтобы
    линия целиком помещалась в битмап с учётом толщины пера. }
  procedure Tick(ADx: Single);
  begin
    B.DrawPolyLineAntialias(
      [PointF(ADx + 1, 5.5), PointF(ADx + 3.5, 8.5), PointF(ADx + 9, 2)],
      Col, TICK_PEN);
  end;

begin
  Result := FReceipts[AKind, ASelected];
  if (Result <> nil) or (AKind = crNone) then begin
    Exit;
  end;

  { На выделенной строке фон — clHighlight, поэтому серый и акцентный
    цвета там неразличимы: рисуем белым, как и время. }
  if ASelected then begin
    Col := ColorToBGRA(clHighlightText);
  end
  else if AKind = crRead then begin
    Col := ColorToBGRA(clHighlight);
  end
  else if AKind = crFailed then begin
    Col := BGRA(200, 60, 60);
  end
  else begin
    Col := ColorToBGRA(clGrayText);
  end;

  if AKind = crRead then begin
    W := TICK_W + TICK_SHIFT;
  end
  else begin
    W := TICK_W;
  end;

  B := TBGRABitmap.Create(W, TICK_H, BGRAPixelTransparent);
  B.LineCap := pecRound;
  B.JoinStyle := pjsRound;

  case AKind of
    crSent: begin
      Tick(0);
    end;
    crRead: begin
      { Две галочки внахлёст, как в Telegram. }
      Tick(0);
      Tick(TICK_SHIFT);
    end;
    crPending: begin
      { Часики: окружность и две стрелки. }
      B.EllipseAntialias(5.5, 5.5, 4.5, 4.5, Col, 1.2);
      B.DrawPolyLineAntialias([PointF(5.5, 3), PointF(5.5, 5.5), PointF(7.5, 6.5)],
        Col, 1.2);
    end;
    crFailed: begin
      { Восклицательный знак. }
      B.DrawPolyLineAntialias([PointF(5.5, 1.5), PointF(5.5, 6.5)], Col, 1.8);
      B.DrawPolyLineAntialias([PointF(5.5, 9), PointF(5.5, 9.2)], Col, 1.8);
    end;
  end;

  FReceipts[AKind, ASelected] := B;
  Result := B;
end;

{ ---------------- привязка к модели активного аккаунта ---------------- }

procedure TFrameChats.BindModel;
var
  M: TTdChats;
begin
  FModel := TdChatList;
  M      := FModel;
  if M = nil then begin
    Exit;
  end;
  M.OnChanged     := @ModelChanged;
  M.OnLoadingChanged := @LoadingChanged;
  M.OnActionError := @ActionError;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

procedure TFrameChats.UnbindModel;
begin
  { Отцепляем только СВОИ обработчики: чужие затирать нельзя. }
  if FModel <> nil then begin
    if TMethod(FModel.OnChanged).Data = Pointer(Self) then begin
      FModel.OnChanged := nil;
    end;
    if TMethod(FModel.OnLoadingChanged).Data = Pointer(Self) then begin
      FModel.OnLoadingChanged := nil;
    end;
    if TMethod(FModel.OnActionError).Data = Pointer(Self) then begin
      FModel.OnActionError := nil;
    end;
    FModel := nil;
  end;
end;

procedure TFrameChats.TdActiveChanged(ANew: TTdAccount);
begin
  if not FReady then begin
    Exit;
  end;
  UnbindModel;
  { Аватарки и значки принадлежат прежнему аккаунту — сбрасываем,
    иначе в списке нового мелькнут чужие картинки. }
  FCache.Clear;
  Grid.Row    := 0;
  Grid.TopRow := 0;
  BindModel;
end;

procedure TFrameChats.TdAccountsChanged;
begin
  { состав аккаунтов фрейму списка не важен }
end;

{ ---------------- связь с моделью ---------------- }

procedure TFrameChats.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;
  Grid.RowCount := RowsCount + ARCHIVE_ROWS;
  Grid.Invalidate;
  { Если чатов меньше, чем помещается в окно, докачиваем сразу:
    прокрутки, которая обычно это запускает, не будет. }
  MaybeLoadMore;
end;

procedure TFrameChats.LoadingChanged(Sender: TObject);
var
  Busy, Done: Boolean;
begin
  if (not FReady) or (lblStatus = nil) or (FModel = nil) then begin
    Exit;
  end;

  if FMode = clmArchive then begin
    Busy := FModel.ArchiveLoading;
    Done := FModel.ArchiveAllLoaded;
  end
  else begin
    Busy := FModel.Loading;
    Done := FModel.AllLoaded;
  end;

  if Busy then begin
    lblStatus.Caption := 'Loading...';
  end
  else if Done then begin
    lblStatus.Caption := Format('%d chats', [RowsCount]);
  end
  else begin
    lblStatus.Caption := Format('%d chats (more)', [RowsCount]);
  end;
end;

procedure TFrameChats.ActionError(Sender: TObject; ACode: Integer; const AMessage, AAction: Utf8string);
begin
  { Отказ TDLib на действие из меню не должен быть молчаливым:
    без этого «Pin» на переполненном списке просто ничего не делает. }
  if lblStatus <> nil then begin
    lblStatus.Caption := Format('Error %d: %s', [ACode, String(AMessage)]);
  end;
end;

procedure TFrameChats.MaybeLoadMore;
var
  LastVisible: Integer;
  Busy, Done:  Boolean;
begin
  { Resize срабатывает ещё во время чтения .lfm, когда Grid — nil. }
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;

  if FMode = clmArchive then begin
    Busy := FModel.ArchiveLoading;
    Done := FModel.ArchiveAllLoaded;
  end
  else begin
    Busy := FModel.Loading;
    Done := FModel.AllLoaded;
  end;
  if Busy or Done then begin
    Exit;
  end;

  LastVisible := Grid.TopRow + (Grid.ClientHeight div ROW_HEIGHT) - ARCHIVE_ROWS;
  if LastVisible >= RowsCount - PREFETCH_ROWS then begin
    if FMode = clmArchive then begin
      FModel.LoadMoreArchive;
    end
    else begin
      FModel.LoadMore;
    end;
  end;
end;

procedure TFrameChats.GridTopLeftChanged(Sender: TObject);
begin
  MaybeLoadMore;
end;

procedure TFrameChats.Resize;
begin
  inherited Resize;
  { Ширину колонки держит AutoFillColumns у сетки. Здесь остаётся
    только догрузка: окно выросло — стало видно больше строк. }
  MaybeLoadMore;
end;

function TFrameChats.RowsCount: Integer;
begin
  if FModel = nil then begin
    Result := 0;
  end
  else if FMode = clmArchive then begin
    Result := FModel.ArchiveCount;
  end
  else begin
    Result := FModel.Count;
  end;
end;

function TFrameChats.ChatAt(AGridRow: Integer): TChatRow;
begin
  { Нулевая строка — заголовок, чата за ней нет. }
  Result := nil;
  if (FModel = nil) or (AGridRow < ARCHIVE_ROWS) then begin
    Exit;
  end;
  if FMode = clmArchive then begin
    Result := FModel.ArchiveRows[AGridRow - ARCHIVE_ROWS];
  end
  else begin
    Result := FModel[AGridRow - ARCHIVE_ROWS];
  end;
end;

procedure TFrameChats.SetMode(AMode: TChatListMode);
begin
  if FMode = AMode then begin
    Exit;
  end;
  FMode := AMode;
  if Grid <> nil then begin
    Grid.TopRow := 0;
    Grid.Row    := 0;
  end;
  ModelChanged(nil);
  LoadingChanged(nil);
  if Assigned(FOnListMode) then begin
    FOnListMode(Self, FMode);
  end;
end;

function TFrameChats.TypeIconIndex(ARow: TChatRow): Integer;
begin
  Result := -1;
  if (ARow = nil) or (FModel = nil) then begin
    Exit;
  end;

  case ARow.Kind of
    ckChannel:
      Result := CHATROW_ICON_CHANNEL;
    ckBasicGroup, ckSupergroup:
      Result := CHATROW_ICON_GROUP;
    ckPrivate, ckSecret: begin
        { Бот — это свойство собеседника, а не чата: тип чата у него
          такой же личный. Признак приходит отдельным updateUser. }
      if FModel.IsBotChat(ARow) then begin
        Result := CHATROW_ICON_BOT;
      end
      else begin
        Result := CHATROW_ICON_PRIVATE;
      end;
    end;
  end;
end;

procedure TFrameChats.DrawIcon12(const ARect: TRect; AIndex: Integer);
begin
  if (AIndex < 0) or (icons12 = nil) or (AIndex >= icons12.Count) then begin
    Exit;
  end;
  icons12.Draw(Grid.Canvas, ARect.Left, ARect.Top, AIndex, True);
end;

function TFrameChats.ChatRowRects(const ARect: TRect; AHasPin: Boolean; out AHeader, AContent,
  AIconR, AAvatarR, AMuteR, APinR: TRect): TRect;
var
  IconY: Integer;
begin
  { Карточка — ARect с отступом CHATROW_GAP слева/справа (от края
    списка, по прямому запросу пользователя) и, по вертикали, ПОЛОВИНОЙ
    CHATROW_GAP сверху И снизу (по прямому запросу пользователя,
    2026-09-08, третий заход: "отступ 2 пикселя сверху и 2 снизу, наши
    4 в сумме") — раньше весь зазор в 4px уходил только вниз (та же
    идея, что MSG_GAP у сообщений, "после блока"), из-за чего карточка
    визуально начиналась прямо с верхнего края строки списка; итоговая
    высота карточки не изменилась (4px по-прежнему уходят на зазор
    целиком, просто поровну на обе стороны, а не только вниз). }
  Result := Rect(ARect.Left + CHATROW_GAP, ARect.Top + CHATROW_GAP div 2,
    ARect.Right - CHATROW_GAP, ARect.Bottom - CHATROW_GAP div 2);

  AHeader := Rect(Result.Left, Result.Top, Result.Right, Result.Top + CHATROW_HEADER_BAR_H);
  AContent := Rect(Result.Left, AHeader.Bottom, Result.Right, Result.Bottom);

  { Заголовок теперь без аватара (тот переехал в область текста, см.
    ниже — по прямому запросу пользователя): слева направо — только
    значок типа чата, дальше имя (ширина которого зависит от текста
    времени/галочки — считается на месте отрисовки, не здесь). }
  IconY := AHeader.Top + (CHATROW_HEADER_BAR_H - CHATROW_ICON_SIZE) div 2;
  AIconR := Rect(AHeader.Left + MSG_PAD_H, IconY,
    AHeader.Left + MSG_PAD_H + CHATROW_ICON_SIZE, IconY + CHATROW_ICON_SIZE);

  { Аватар — в области текста, перед превью сообщения (по прямому
    запросу пользователя, 2026-09-08, второй заход), вертикально по
    центру той же высоты, что и сама область (CHATROW_CONTENT_H
    посчитана ИМЕННО под аватар, см. constants.pas). }
  AAvatarR := Rect(AContent.Left + MSG_PAD_H, AContent.Top + MSG_PAD_V,
    AContent.Left + MSG_PAD_H + AVATAR_SIZE, AContent.Top + MSG_PAD_V + AVATAR_SIZE);

  { Справа налево: колокольчик уведомлений (у самого края), левее —
    пин. Дальше левее (галочка/время) — переменной ширины, считается
    на месте отрисовки, в хит-тест не входит (не кликабельны). }
  AMuteR := Rect(AHeader.Right - MSG_PAD_H - CHATROW_ICON_SIZE, IconY,
    AHeader.Right - MSG_PAD_H, IconY + CHATROW_ICON_SIZE);
  if AHasPin then begin
    APinR := Rect(AMuteR.Left - GAP - CHATROW_ICON_SIZE, IconY,
      AMuteR.Left - GAP, IconY + CHATROW_ICON_SIZE);
  end
  else begin
    { В архиве пинить нельзя (по прямому запросу пользователя) — нулевая
      ширина у левого края MuteR, не просто "не рисовать": TitleRight
      в GridDrawCell считается от PinR.Left, и время должно упираться
      прямо в MuteR, как будто слота под пин никогда не было. }
    APinR := Rect(AMuteR.Left, IconY, AMuteR.Left, IconY + CHATROW_ICON_SIZE);
  end;
end;

procedure TFrameChats.DrawHeaderRow(ARect: TRect; ASelected: Boolean);
var
  Cv:    TCanvas;
  Badge: TBGRABitmap;
  A:     TArchiveInfo;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
  BodyFill, HeaderFill, BorderCol: TColor;
  PrevRight, Y, IconIdx: Integer;
  S, Title: String;
begin
  Cv := Grid.Canvas;

  { В основном списке заголовок ведёт в архив, в архиве — обратно.
    Сводка берётся по тому списку, КУДА он ведёт. Тот же вид карточки,
    что и у настоящего чата (по прямому запросу пользователя,
    2026-09-08, четвёртый заход) — только без времени/аватара/пина/
    уведомлений (тем и остаётся "псевдо-строкой", не настоящим чатом) и
    фиксированным цветом CHATROW_PSEUDO_COLOR вместо ChatAccentColor. }
  if FMode = clmArchive then begin
    A       := FModel.MainInfo;
    IconIdx := CHATROW_ICON_ALLCHATS;
    Title   := 'All chats';
  end
  else begin
    A       := FModel.Archive;
    IconIdx := CHATROW_ICON_ARCHIVE;
    Title   := 'Archive';
  end;

  { AvatarR/MuteR/PinR — та же геометрия, что и у настоящих чатов, но
    здесь просто не используются (для этой карточки их нет). AHasPin —
    неважно (False для единообразия, тут и без того нет ни одной иконки
    из этой пары). }
  Card := ChatRowRects(ARect, False, Header, Content, IconR, AvatarR, MuteR, PinR);

  if ASelected then begin
    Cv.Brush.Color := BlendWithBackground(CHATROW_PSEUDO_COLOR, CHATROW_SELECTED_OPACITY, clWindow);
    Cv.Brush.Style := bsSolid;
    Cv.FillRect(ARect);
  end;

  BodyFill   := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_BG_OPACITY, clWindow);
  HeaderFill := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_HEADER_OPACITY, clWindow);
  BorderCol  := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_BORDER_OPACITY, clWindow);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], BodyFill, clNone);
  PaintCardRoundRect(Cv, Header, CHATROW_CORNER_RADIUS,
    [rrBottomLeftSquare, rrBottomRightSquare], HeaderFill, clNone);

  DrawIcon12(IconR, IconIdx);

  Cv.Brush.Style := bsClear;
  Cv.Font.Style  := [fsBold];
  Cv.Font.Height := -13;
  Cv.Font.Color  := clWindowText;
  Cv.TextRect(Rect(IconR.Right + MSG_ICON_GAP, Header.Top, Header.Right - MSG_PAD_H, Header.Bottom),
    IconR.Right + MSG_ICON_GAP, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(Title)) div 2, Title);

  { Счётчик — число непрочитанных ЧАТОВ в архиве, как в Telegram —
    в области текста, тем же местом, что и счётчик непрочитанных
    сообщений у настоящего чата. }
  PrevRight := Content.Right - MSG_PAD_H;
  if A.UnreadChats > 0 then begin
    Badge := BadgeBitmap(IntToStr(A.UnreadChats), False);
    if Badge <> nil then begin
      Y := Content.Top + (CHATROW_CONTENT_H - Badge.Height) div 2;
      Badge.Draw(Cv, PrevRight - Badge.Width, Y, False);
      Dec(PrevRight, Badge.Width + GAP);
    end;
  end;

  Cv.Brush.Style := bsClear;
  Cv.Font.Style  := [];
  Cv.Font.Height := -12;
  Cv.Font.Color  := clGrayText;
  S := String(A.Preview);
  if S = '' then begin
    if A.TotalChats > 0 then begin
      S := Format('%d chats', [A.TotalChats]);
    end
    else begin
      S := 'Empty';
    end;
  end;
  { Без аватара — текст начинается сразу от левого края области текста
    (не после AvatarR, как у настоящего чата), по вертикали — по
    центру той же строки. }
  Cv.TextRect(Rect(Content.Left + MSG_PAD_H, Content.Top, PrevRight, Content.Bottom),
    Content.Left + MSG_PAD_H, Content.Top + (CHATROW_CONTENT_H - Cv.TextHeight(S)) div 2, S);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], clNone, BorderCol);
end;

{ ---------------- отрисовка ---------------- }

procedure TFrameChats.GridDrawCell(Sender: TObject; ACol, ARow: Integer; ARect: TRect; AState: TGridDrawState);
var
  R:   TChatRow;
  Cv:  TCanvas;
  Bmp, Badge, Rec: TBGRABitmap;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
  BaseBg, Accent, BodyFill, HeaderFill, BorderCol: TColor;
  TitleRight, PrevRight, Y, W, MuteIdx, PinIdx: Integer;
  Sel: Boolean;
  S:   String;
begin
  { FCache создаётся в теле конструктора, то есть уже после стриминга.
    Если сетка успеет запросить отрисовку раньше — здесь nil. }
  if (not FReady) or (FCache = nil) or (FModel = nil) then begin
    Exit;
  end;
  R  := ChatAt(ARow);
  Cv := Grid.Canvas;

  Sel := gdSelected in AState;
  if Sel then begin
    BaseBg := clHighlight;
  end
  else begin
    BaseBg := clWindow;
  end;
  Cv.Brush.Color := BaseBg;
  Cv.Brush.Style := bsSolid;
  Cv.FillRect(ARect);

  if ARow < ARCHIVE_ROWS then begin
    DrawHeaderRow(ARect, Sel);
    Exit;
  end;

  if R = nil then begin
    Exit;
  end;

  { Заливка "за карточкой" на выделении — цветом самого контакта, не
    системным clHighlight (по прямому запросу пользователя, 2026-09-08,
    третий заход) — перекрывает уже сделанную выше generic-заливку
    (BaseBg=clHighlight), общую с псевдо-строкой "Архив"/"Все чаты",
    которую эта правка не касается. Сама карточка (тело/заголовок/
    обводка ниже) больше НЕ реагирует на Sel вовсе — считается всегда
    относительно clWindow, видимый признак выделения — только эта
    заливка вокруг неё, в зазорах CHATROW_GAP. }
  Accent := ChatAccentColor(R);
  if Sel then begin
    Cv.Brush.Color := BlendWithBackground(Accent, CHATROW_SELECTED_OPACITY, clWindow);
    Cv.Brush.Style := bsSolid;
    Cv.FillRect(ARect);
  end;

  { В архиве пинить нельзя (по прямому запросу пользователя) — значок
    пина не рисуется вовсе, не просто "неактивен". }
  Card := ChatRowRects(ARect, FMode <> clmArchive, Header, Content, IconR, AvatarR, MuteR, PinR);

  { Карточка — тот же визуальный язык, что и блок сообщения: тело
    (SENDER_BG_OPACITY), заголовок поверх (SENDER_HEADER_OPACITY,
    заметнее — низ спрямлён, чтобы не торчал скруглённым углом внутрь
    тела), обводка — последней, поверх всего содержимого. }
  BodyFill   := BlendWithBackground(Accent, SENDER_BG_OPACITY, clWindow);
  HeaderFill := BlendWithBackground(Accent, SENDER_HEADER_OPACITY, clWindow);
  BorderCol  := BlendWithBackground(Accent, SENDER_BORDER_OPACITY, clWindow);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], BodyFill, clNone);
  PaintCardRoundRect(Cv, Header, CHATROW_CORNER_RADIUS,
    [rrBottomLeftSquare, rrBottomRightSquare], HeaderFill, clNone);

  { Аватарку просим только для строк, которые реально рисуются, —
    это и есть ленивость: качается лишь видимое. Рисуется в области
    текста, перед превью (по прямому запросу пользователя, 2026-09-08,
    второй заход) — сама позиция уже посчитана в AvatarR. }
  FModel.EnsureAvatar(R);
  Bmp := FCache.Get(R);
  if Bmp <> nil then begin
    { Opaque=False — смешивание по альфе поверх уже залитого фона.
      Именно это даёт мягкий край на любом фоне, включая выделение. }
    Bmp.Draw(Cv, AvatarR.Left, AvatarR.Top, False);
  end;

  DrawIcon12(IconR, TypeIconIndex(R));

  if R.IsMuted then begin
    MuteIdx := CHATROW_ICON_NOTIFY_OFF;
  end
  else begin
    MuteIdx := CHATROW_ICON_NOTIFY_ON;
  end;
  DrawIcon12(MuteR, MuteIdx);

  if FMode <> clmArchive then begin
    if R.IsPinned then begin
      PinIdx := CHATROW_ICON_PIN;
    end
    else begin
      PinIdx := CHATROW_ICON_UNPIN;
    end;
    DrawIcon12(PinR, PinIdx);
  end;

  Cv.Brush.Style := bsClear;

  { --- заголовок: время + отметка о прочтении, справа налево от пина ---
    Цвета текста внутри карточки больше НЕ зависят от Sel (см. комментарий
    выше про заливку "за карточкой") — карточка выглядит одинаково,
    выделена строка или нет, признак выделения — заливка вокруг неё. }
  TitleRight := PinR.Left - GAP;
  S := ChatTimeStr(R.LastDate);
  if S <> '' then begin
    Cv.Font.Style  := [];
    Cv.Font.Height := -11;
    Cv.Font.Color := clGrayText;
    W := Cv.TextWidth(S);
    Cv.TextOut(TitleRight - W, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(S)) div 2, S);
    Dec(TitleRight, W + GAP);

    { Отметка о прочтении — слева от времени, только для исходящих. }
    Rec := ReceiptBitmap(ChatReceipt(R), False);
    if Rec <> nil then begin
      Rec.Draw(Cv, TitleRight - Rec.Width, Header.Top + (CHATROW_HEADER_BAR_H - Rec.Height) div 2, False);
      Dec(TitleRight, Rec.Width + 3);
    end;
  end;

  { --- имя --- }
  Cv.Font.Style  := [fsBold];
  Cv.Font.Height := -13;
  Cv.Font.Color := clWindowText;
  S := String(R.Title);
  Cv.TextRect(Rect(IconR.Right + MSG_ICON_GAP, Header.Top, TitleRight, Header.Bottom),
    IconR.Right + MSG_ICON_GAP, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(S)) div 2, S);

  { --- превью последнего сообщения + счётчик непрочитанных --- }
  Cv.Brush.Style := bsClear;
  PrevRight := Content.Right - MSG_PAD_H;
  if (R.UnreadCount > 0) or R.IsMarkedAsUnread then begin
    if R.UnreadCount > 0 then begin
      S := IntToStr(R.UnreadCount);
    end
    else begin
      S := '';
    end;
    Badge := BadgeBitmap(S, False);
    if Badge <> nil then begin
      Y := Content.Top + (CHATROW_CONTENT_H - Badge.Height) div 2;
      Badge.Draw(Cv, PrevRight - Badge.Width, Y, False);
      Dec(PrevRight, Badge.Width + GAP);
    end;
  end;

  Cv.Font.Style  := [];
  Cv.Font.Height := -12;
  Cv.Font.Color := clGrayText;
  S := String(R.LastText);
  if R.LastIsOutgoing and (S <> '') then begin
    S := 'You: ' + S;
  end;
  { Начинается после аватара (та переехала сюда, см. AvatarR/
    ChatRowRects), по вертикали — по центру той же строки, что и
    аватар, не просто "сверху с отступом MSG_PAD_V", как было до
    переезда аватара. }
  Cv.TextRect(Rect(AvatarR.Right + MSG_ICON_GAP, Content.Top,
    PrevRight, Content.Bottom),
    AvatarR.Right + MSG_ICON_GAP, Content.Top + (CHATROW_CONTENT_H - Cv.TextHeight(S)) div 2, S);

  { --- контур карточки — последним, поверх содержимого --- }
  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], clNone, BorderCol);
end;

{ ---------------- выбор и меню ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := ChatAt(Grid.Row);
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
begin
  CanSelect := True;
  { Клик пришёлся по значку/аватарке — выделение вообще не двигаем,
    чат не открываем. НЕ сбрасываем флаг здесь — см. её же объявление
    и CLAUDE.md за 2026-09-06 про то, почему одноразовый, сбрасывающий
    себя вариант не работал (Grid.RowCount:=... в ModelChanged может,
    независимо от Grid.Row:=0, синхронно перевызвать это же событие
    ещё раз через CheckPosition в LCL — заранее неизвестно, сколько
    именно раз). }
  if FSuppressSelect then begin
    CanSelect := False;
    Exit;
  end;
  if (not FReady) or (FModel = nil) then begin
    Exit;
  end;
  if ARow < ARCHIVE_ROWS then begin
    { Заголовок обрабатывается в GridMouseDown — сюда попадаем
      только при выборе с клавиатуры. }
    Exit;
  end;
  if FSwitchingMode then begin
    { Идёт переключение режима списка (GridMouseDown/chaHeader) —
      CanSelect остаётся True (см. выше) — выделенным должен стать сам
      заголовок нового списка ("Архив"/"Все чаты"), а не прежняя
      строка из старого — но чат при этом не открываем. }
    Exit;
  end;
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, ChatAt(ARow));
  end;
end;

function TFrameChats.HitArea(X, Y: Integer; out ARow: TChatRow): TChatHitArea;
var
  C, Row: Integer;
  Cell:   TRect;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
  P: TPoint;
begin
  Result := chaNone;
  ARow   := nil;
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;

  Grid.MouseToCell(X, Y, C, Row);
  if (Row >= 0) and (Row < ARCHIVE_ROWS) then begin
    { Заголовок кликается целиком, а не отдельными зонами. }
    Result := chaHeader;
    Exit;
  end;
  ARow := ChatAt(Row);
  if ARow = nil then begin
    Exit;
  end;

  { Координаты внутри строки — локальные, поэтому геометрия карточки
    считается для (0,0,Width,Height) той же ячейки, тем же ChatRowRects,
    что и отрисовка (только там ARect — настоящий, абсолютный). }
  Cell := Grid.CellRect(C, Row);
  P    := Point(X - Cell.Left, Y - Cell.Top);
  Card := ChatRowRects(Rect(0, 0, Cell.Right - Cell.Left, Cell.Bottom - Cell.Top),
    FMode <> clmArchive, Header, Content, IconR, AvatarR, MuteR, PinR);

  if PtInRect(MuteR, P) then begin
    Result := chaBell;
    Exit;
  end;
  if PtInRect(PinR, P) then begin
    Result := chaPin;
    Exit;
  end;
  if PtInRect(AvatarR, P) then begin
    Result := chaAvatar;
    Exit;
  end;
end;

procedure TFrameChats.GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  R:    TChatRow;
  Want: TCursor;
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if HitArea(X, Y, R) = chaNone then begin
    Want := crDefault;
  end
  else begin
    Want := crHandPoint;
  end;
  { Присваиваем только при смене: OnMouseMove срабатывает густо,
    а установка курсора дёргает виджетсет. }
  if Grid.Cursor <> Want then begin
    Grid.Cursor := Want;
  end;
end;

procedure TFrameChats.GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: TChatRow;
begin
  FSuppressSelect := False;
  FSwitchingMode := False;
  if Button <> mbLeft then begin
    Exit;
  end;

  { Важно, что LCL вызывает inherited MouseDown ПЕРВОЙ строкой:
    наш обработчик успевает отработать до смены выделения. }
  case HitArea(X, Y, R) of
    chaHeader: begin
      { FSwitchingMode (в отличие от FSuppressSelect у chaBell/chaPin/
        chaAvatar ниже) НЕ мешает выделению двигаться — оно ДОЛЖНО
        переехать на заголовок нового списка, см. FSwitchingMode/
        GridSelectCell. Держится True вплоть до начала СЛЕДУЮЩЕГО
        реального MouseDown, не потребляется по одному разу за вызов —
        и Grid.Row:=0, и Grid.RowCount:=... внутри SetMode/ModelChanged
        МОГУТ, независимо друг от друга, синхронно перевызвать
        GridSelectCell ещё раз (CheckPosition в LCL перепроверяет
        текущую ячейку на каждое такое присваивание) — заранее
        неизвестно, сколько именно раз. }
      FSwitchingMode := True;
      if FMode = clmArchive then begin
        SetMode(clmMain);
      end
      else begin
        SetMode(clmArchive);
      end;
    end;
    chaBell: begin
      FSuppressSelect := True;
      FModel.SetMuted(R, not R.IsMuted);
    end;
    chaPin: begin
      FSuppressSelect := True;
      FModel.SetPinned(R, not R.IsPinned);
    end;
    chaAvatar: begin
      FSuppressSelect := True;
      if Assigned(FOnAvatar) then begin
        FOnAvatar(Self, R);
      end;
    end;
  end;
end;

procedure TFrameChats.GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  C, R: Integer;
begin
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Handled := True;
    Exit;
  end;
  Grid.MouseToCell(MousePos.X, MousePos.Y, C, R);
  { У архива своего меню пока нет. }
  if (R < ARCHIVE_ROWS) or (R >= RowsCount + ARCHIVE_ROWS) then begin
    Handled := True;
    Exit;
  end;
  Grid.Row := R;
  FMenuRow := ChatAt(R);
  BuildMenu(FMenuRow);
end;

procedure TFrameChats.BuildMenu(ARow: TChatRow);

  procedure Add(const ACaption: String; ATag: Integer);
  var
    MI: TMenuItem;
  begin
    MI     := TMenuItem.Create(mnuChat);
    MI.Caption := ACaption;
    MI.Tag := ATag;
    MI.OnClick := @MenuItemClick;
    mnuChat.Items.Add(MI);
  end;

begin
  { Меню строится заново под конкретный чат: набор пунктов зависит
    от его типа и состояния. }
  mnuChat.Items.Clear;
  if ARow = nil then begin
    Exit;
  end;

  Add(String(ARow.Title), MI_NONE);
  mnuChat.Items[0].Enabled := False;
  Add('-', MI_NONE);

  if (ARow.UnreadCount > 0) or ARow.IsMarkedAsUnread then begin
    Add('Mark as read', MI_READ);
  end
  else begin
    Add('Mark as unread', MI_UNREAD);
  end;

  { В архиве пинить нельзя (по прямому запросу пользователя) — тот же
    запрет, что и на значок пина в строке (GridDrawCell/ChatRowRects),
    просто со стороны контекстного меню: оставлять пункт меню было бы
    несогласованным с уже убранным значком. }
  if FMode <> clmArchive then begin
    if ARow.IsPinned then begin
      Add('Unpin', MI_UNPIN);
    end
    else begin
      Add('Pin', MI_PIN);
    end;
  end;

  if ARow.InArchive then begin
    Add('Move to main list', MI_UNARCHIVE);
  end
  else begin
    Add('Archive', MI_ARCHIVE);
  end;

  Add('-', MI_NONE);
  Add('Copy id (' + IntToStr(ARow.Id) + ')', MI_COPY_ID);

  if ARow.Kind in [ckSupergroup, ckChannel, ckBasicGroup] then begin
    Add('-', MI_NONE);
    Add('Leave', MI_LEAVE);
  end;
end;

procedure TFrameChats.MenuItemClick(Sender: TObject);
var
  R: TChatRow;
begin
  { Строку запоминаем локально: пока висит подтверждение, модель
    могла перестроиться и FMenuRow указывать уже не туда. }
  R := FMenuRow;
  if (R = nil) or (FModel = nil) then begin
    Exit;
  end;

  case TMenuItem(Sender).Tag of
    MI_READ:
      FModel.MarkAsRead(R);
    MI_UNREAD:
      FModel.MarkAsUnread(R);
    MI_PIN:
      FModel.SetPinned(R, True);
    MI_UNPIN:
      FModel.SetPinned(R, False);
    MI_ARCHIVE:
      FModel.SetArchived(R, True);
    MI_UNARCHIVE:
      FModel.SetArchived(R, False);
    MI_COPY_ID:
      Clipboard.AsText := IntToStr(R.Id);
    MI_LEAVE: begin
      if MessageDlg('Leave chat',
        Format('Leave "%s"?', [String(R.Title)]),
        mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
        FModel.LeaveChat(R);
      end;
    end;
  end;
end;

end.
