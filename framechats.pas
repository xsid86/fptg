unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, DateUtils, Controls, Forms, Dialogs, Graphics, Grids,
  Menus, StdCtrls, ExtCtrls, Clipbrd,
  BGRABitmap, BGRABitmapTypes,
  tdauth, tdcore, tdchats, uiframe, avatarcache;

type
  { Кликабельные области внутри строки. }
  TChatHitArea = (chaNone, chaBell, chaAvatar, chaHeader);

  { Какой список показан. }
  TChatListMode = (clmMain, clmArchive);

  TChatSelectEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TAvatarClickEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TListModeEvent = procedure(Sender: TObject; AMode: TChatListMode) of object;

  { TFrameChats

    Список чатов на TDrawGrid: у сетки нет собственной коллекции строк,
    поэтому модель остаётся единственным хранилищем данных, а
    перестановка чата — это просто Invalidate. }

  TFrameChats = class(TFrameBase, ITdActiveListener)
    Grid:      TDrawGrid;
    pnlBottom: TPanel;
    lblStatus: TLabel;
    mnuChat:   TPopupMenu;
    { Значки типов чата. Компонент положен на фрейм в дизайнере;
      имя должно совпадать с тем, что в .lfm. }
    ImageList1: TImageList;
    { Крупные картинки размером с аватарку (44x44).
      Индекс 0 — архив. }
    ImageListBig: TImageList;
    procedure GridDrawCell(Sender: TObject; ACol, ARow: integer; ARect: TRect; AState: TGridDrawState);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: integer; var CanSelect: boolean);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: boolean);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: integer);
    procedure GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
  protected
    { Resize — виртуальный метод TControl, доступен всегда и не зависит
      от того, опубликовано ли одноимённое событие у потомка.
      У TDrawGrid оно НЕ опубликовано. }
    procedure Resize; override;
  private
    FCache:    TAvatarCache;
    FReady:    boolean;
    FModel:    TTdChats;      { модель активного аккаунта }
    FBadges:   TStringList;   { кэш значков: ключ -> TBGRABitmap }
    FMeasure:  TBGRABitmap;   { 1x1 для замера текста тем же шрифтом }
    FReceipts: array[TChatReceipt, boolean] of TBGRABitmap;
    FMenuRow:  TChatRow;
    FOnSelect: TChatSelectEvent;
    FOnListMode: TListModeEvent;
    FMode: TChatListMode;
    FOnAvatar: TAvatarClickEvent;
    FSuppressSelect: boolean;
    procedure BindModel;
    procedure UnbindModel;
    { Архив — не чат: индекс 0 отдан ему, чаты сдвинуты на единицу.
      Фальшивый TChatRow завёл бы его в контекстное меню и в открытие
      чата, чего быть не должно. }
    function ChatAt(AGridRow: integer): TChatRow;
    function TypeIconIndex(ARow: TChatRow): integer;
    procedure DrawColIcon(ACX, ACY, AIndex: integer);
    { Одна проверка попадания на всех: и для нажатия, и для курсора.
      Дублировать геометрию в двух местах — верный способ развести
      их со временем. }
    function HitArea(X, Y: integer; out ARow: TChatRow): TChatHitArea;
    procedure SetMode(AMode: TChatListMode);
    function RowsCount: integer;
    procedure DrawHeaderRow(ARect: TRect; ASelected: boolean);
    function BadgeBitmap(const AText: string; ASelected: boolean): TBGRABitmap;
    function ReceiptBitmap(AKind: TChatReceipt; ASelected: boolean): TBGRABitmap;
    procedure ModelChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: integer;
      const AMessage, AAction: utf8string);
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

const
  ROW_HEIGHT = 56;
  PAD = 8;
  { Слева от аватарки — колонка под значки типа и уведомлений.
    Белой подложки нет, но значки центруются по тем же виртуальным
    кругам 24x24, что и раньше. }
  ICON_COL_L = 6;
  ICON_COL_W = 24;
  ICON_COL_R = ICON_COL_W div 2;
  AV_LEFT = ICON_COL_L + ICON_COL_W + 6;
  TEXT_LEFT = AV_LEFT + AVATAR_SIZE + 10;
  BADGE_H = 18;
  BADGE_PAD = 7;
  BADGE_FONT_H = 12;
  BADGE_CACHE_MAX = 64;
  { Вертикальная разметка правой колонки: время на уровне заголовка,
    значок — на уровне превью, как в Telegram. }
  { Отметка о прочтении. }
  TICK_W = 12;   { ширина одной галочки }
  TICK_H = 11;
  TICK_SHIFT = 5;    { сдвиг второй галочки у «прочитано» }
  TICK_PEN = 1.6;
  RECEIPT_TOP = 11;
  TITLE_TOP = 8;
  PREVIEW_TOP = 29;
  TIME_TOP = 10;
  GAP = 6;
  { За сколько строк до конца просить следующую порцию. }
  PREFETCH_ROWS = 6;
  { Архив всегда занимает нулевую строку, как в оригинальном клиенте. }
  ARCHIVE_ROWS = 1;

  { Индексы в ImageList на фрейме. Порядок задан самим списком:
    0 — рупор, 1 — двое, 2 — робот, 3 — человек. }
  ICON_CHANNEL  = 0;
  ICON_GROUP    = 1;
  ICON_BOT      = 2;
  ICON_PRIVATE  = 3;
  ICON_NOTIFY_ON  = 4;
  ICON_NOTIFY_OFF = 5;
  { Индекс в ImageListBig. }
  BIG_ARCHIVE  = 0;   { значок архива в основном списке }
  BIG_ALLCHATS = 1;   { значок возврата в архивном списке }



  { Коды пунктов контекстного меню. }
  MI_NONE       = 0;
  MI_READ       = 1;
  MI_UNREAD     = 2;
  MI_PIN        = 3;
  MI_UNPIN      = 4;
  MI_COPY_ID    = 5;
  MI_LEAVE      = 6;
  MI_ARCHIVE    = 7;
  MI_UNARCHIVE  = 8;

{ Отметка времени в стиле Telegram: сегодня — часы, вчера — словом,
  на этой неделе — день недели, дальше — дата. }
function ChatTimeStr(AUnix: int64): string;
const
  WD: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
var
  Dt, Today: TDateTime;
  Days: integer;
begin
  Result := '';
  if AUnix <= 0 then begin
    Exit;
  end;
  { TDLib отдаёт Unix-время в UTC — переводим в местное, иначе
    у пользователей вне UTC часы будут врать. }
  Dt := UniversalTimeToLocal(UnixToDateTime(AUnix));
  Today := Date;
  Days := Trunc(Today) - Trunc(Dt);

  if Days <= 0 then begin
    Result := FormatDateTime('hh:nn', Dt);   { 24 часа: hh, не ampm }
  end else
  if Days = 1 then begin
    Result := 'yesterday';
  end else
  if Days < 7 then begin
    Result := WD[DayOfWeek(Dt)];
  end else begin
    Result := FormatDateTime('dd.mm.yy', Dt);
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
  I: integer;
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

function TFrameChats.BadgeBitmap(const AText: string; ASelected: boolean): TBGRABitmap;
var
  Key: string;
  Idx, W: integer;
  Sz: TSize;
  BgCol, FgCol: TBGRAPixel;
  B: TBGRABitmap;
begin
  { Значки повторяются (1, 2, 3...), а отрисовка текста со сглаживанием
    недёшева — поэтому кэшируем. Ключ включает выделение: на выделенной
    строке цвета инвертированы. }
  if ASelected then begin
    Key := AText + #1;
  end else begin
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
  end else begin
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

function TFrameChats.ReceiptBitmap(AKind: TChatReceipt; ASelected: boolean): TBGRABitmap;
var
  B: TBGRABitmap;
  Col: TBGRAPixel;
  W: integer;

  { Одна галочка со сдвигом по X. Координаты подобраны так, чтобы
    линия целиком помещалась в битмап с учётом толщины пера. }
  procedure Tick(ADx: single);
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
  end else
  if AKind = crRead then begin
    Col := ColorToBGRA(clHighlight);
  end else
  if AKind = crFailed then begin
    Col := BGRA(200, 60, 60);
  end else begin
    Col := ColorToBGRA(clGrayText);
  end;

  if AKind = crRead then begin
    W := TICK_W + TICK_SHIFT;
  end else begin
    W := TICK_W;
  end;

  B := TBGRABitmap.Create(W, TICK_H, BGRAPixelTransparent);
  B.LineCap := pecRound;
  B.JoinStyle := pjsRound;

  case AKind of
    crSent:
    begin
      Tick(0);
    end;
    crRead:
    begin
      { Две галочки внахлёст, как в Telegram. }
      Tick(0);
      Tick(TICK_SHIFT);
    end;
    crPending:
    begin
      { Часики: окружность и две стрелки. }
      B.EllipseAntialias(5.5, 5.5, 4.5, 4.5, Col, 1.2);
      B.DrawPolyLineAntialias([PointF(5.5, 3), PointF(5.5, 5.5), PointF(7.5, 6.5)],
        Col, 1.2);
    end;
    crFailed:
    begin
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
  M := FModel;
  if M = nil then begin
    Exit;
  end;
  M.OnChanged := @ModelChanged;
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
  Grid.Row := 0;
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
  Busy, Done: boolean;
begin
  if (not FReady) or (lblStatus = nil) or (FModel = nil) then begin
    Exit;
  end;

  if FMode = clmArchive then begin
    Busy := FModel.ArchiveLoading;
    Done := FModel.ArchiveAllLoaded;
  end else begin
    Busy := FModel.Loading;
    Done := FModel.AllLoaded;
  end;

  if Busy then begin
    lblStatus.Caption := 'Loading...';
  end else if Done then begin
    lblStatus.Caption := Format('%d chats', [RowsCount]);
  end else begin
    lblStatus.Caption := Format('%d chats (more)', [RowsCount]);
  end;
end;

procedure TFrameChats.ActionError(Sender: TObject; ACode: integer;
  const AMessage, AAction: utf8string);
begin
  { Отказ TDLib на действие из меню не должен быть молчаливым:
    без этого «Pin» на переполненном списке просто ничего не делает. }
  if lblStatus <> nil then begin
    lblStatus.Caption := Format('Error %d: %s', [ACode, string(AMessage)]);
  end;
end;

procedure TFrameChats.MaybeLoadMore;
var
  LastVisible: integer;
  Busy, Done: boolean;
begin
  { Resize срабатывает ещё во время чтения .lfm, когда Grid — nil. }
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;

  if FMode = clmArchive then begin
    Busy := FModel.ArchiveLoading;
    Done := FModel.ArchiveAllLoaded;
  end else begin
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
    end else begin
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

function TFrameChats.RowsCount: integer;
begin
  if FModel = nil then begin
    Result := 0;
  end else if FMode = clmArchive then begin
    Result := FModel.ArchiveCount;
  end else begin
    Result := FModel.Count;
  end;
end;

function TFrameChats.ChatAt(AGridRow: integer): TChatRow;
begin
  { Нулевая строка — заголовок, чата за ней нет. }
  Result := nil;
  if (FModel = nil) or (AGridRow < ARCHIVE_ROWS) then begin
    Exit;
  end;
  if FMode = clmArchive then begin
    Result := FModel.ArchiveRows[AGridRow - ARCHIVE_ROWS];
  end else begin
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
    Grid.Row := 0;
  end;
  ModelChanged(nil);
  LoadingChanged(nil);
  if Assigned(FOnListMode) then begin
    FOnListMode(Self, FMode);
  end;
end;

function TFrameChats.TypeIconIndex(ARow: TChatRow): integer;
begin
  Result := -1;
  if (ARow = nil) or (FModel = nil) then begin
    Exit;
  end;

  case ARow.Kind of
    ckChannel:
      Result := ICON_CHANNEL;
    ckBasicGroup, ckSupergroup:
      Result := ICON_GROUP;
    ckPrivate, ckSecret:
      begin
        { Бот — это свойство собеседника, а не чата: тип чата у него
          такой же личный. Признак приходит отдельным updateUser. }
        if FModel.IsBotChat(ARow) then begin
          Result := ICON_BOT;
        end else begin
          Result := ICON_PRIVATE;
        end;
      end;
  end;
end;

procedure TFrameChats.DrawColIcon(ACX, ACY, AIndex: integer);
begin
  if (AIndex < 0) or (ImageList1 = nil) or (AIndex >= ImageList1.Count) then begin
    Exit;
  end;
  { Центрируем по заданной точке — центру виртуального круга,
    который сам не рисуется. }
  ImageList1.Draw(Grid.Canvas,
    ACX - ImageList1.Width div 2,
    ACY - ImageList1.Height div 2, AIndex, True);
end;


procedure TFrameChats.DrawHeaderRow(ARect: TRect; ASelected: boolean);
var
  Cv: TCanvas;
  Badge: TBGRABitmap;
  A: TArchiveInfo;
  TextRight, Y, Big: integer;
  S, Title: string;
begin
  Cv := Grid.Canvas;

  { В основном списке заголовок ведёт в архив, в архиве — обратно.
    Сводка берётся по тому списку, КУДА он ведёт. }
  if FMode = clmArchive then begin
    A := FModel.MainInfo;
    Big := BIG_ALLCHATS;
    Title := 'All chats';
  end else begin
    A := FModel.Archive;
    Big := BIG_ARCHIVE;
    Title := 'Archive';
  end;

  if (ImageListBig <> nil) and (Big < ImageListBig.Count) then begin
    ImageListBig.Draw(Cv, ARect.Left + AV_LEFT,
      ARect.Top + (ROW_HEIGHT - AVATAR_SIZE) div 2, Big, True);
  end;

  Cv.Brush.Style := bsClear;
  TextRight := ARect.Right - PAD;

  { Счётчик — число непрочитанных ЧАТОВ в архиве, как в Telegram. }
  if A.UnreadChats > 0 then begin
    Badge := BadgeBitmap(IntToStr(A.UnreadChats), ASelected);
    if Badge <> nil then begin
      Y := ARect.Top + PREVIEW_TOP;
      Badge.Draw(Cv, TextRight - Badge.Width, Y, False);
      Dec(TextRight, Badge.Width + GAP);
    end;
  end;

  Cv.Font.Style := [fsBold];
  Cv.Font.Height := -13;
  if ASelected then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clWindowText;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + TITLE_TOP,
                   ARect.Right - PAD, ARect.Top + TITLE_TOP + 18),
              ARect.Left + TEXT_LEFT, ARect.Top + TITLE_TOP, Title);

  Cv.Font.Style := [];
  Cv.Font.Height := -12;
  if ASelected then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clGrayText;
  end;
  S := string(A.Preview);
  if S = '' then begin
    if A.TotalChats > 0 then begin
      S := Format('%d chats', [A.TotalChats]);
    end else begin
      S := 'Empty';
    end;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP,
                   TextRight, ARect.Top + PREVIEW_TOP + 19),
              ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP, S);
end;

{ ---------------- отрисовка ---------------- }

procedure TFrameChats.GridDrawCell(Sender: TObject; ACol, ARow: integer; ARect: TRect; AState: TGridDrawState);
var
  R:  TChatRow;
  Cv: TCanvas;
  Bmp, Badge, Rec: TBGRABitmap;
  Y, W, TitleRight, PrevRight, AvTop, Ico, IcoX: integer;
  Sel: boolean;
  S:  string;
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
    Cv.Brush.Color := clHighlight;
  end else begin
    Cv.Brush.Color := clWindow;
  end;
  Cv.Brush.Style := bsSolid;
  Cv.FillRect(ARect);

  if ARow < ARCHIVE_ROWS then begin
    DrawHeaderRow(ARect, Sel);
    Exit;
  end;

  if R = nil then begin
    Exit;
  end;

  { Аватарку просим только для строк, которые реально рисуются, —
    это и есть ленивость: качается лишь видимое. }
  FModel.EnsureAvatar(R);
  AvTop := ARect.Top + (ROW_HEIGHT - AVATAR_SIZE) div 2;
  Bmp := FCache.Get(R);
  if Bmp <> nil then begin
    { Opaque=False — смешивание по альфе поверх уже залитого фона.
      Именно это даёт мягкий край на любом фоне, включая выделение. }
    Bmp.Draw(Cv, ARect.Left + AV_LEFT, AvTop, False);
  end;

  { Колонка значков слева: уведомления сверху, тип чата снизу.
    Центры — те же, что были у круглых подложек. }
  IcoX := ARect.Left + ICON_COL_L + ICON_COL_R;

  if R.IsMuted then begin
    Ico := ICON_NOTIFY_OFF;
  end else begin
    Ico := ICON_NOTIFY_ON;
  end;
  DrawColIcon(IcoX, AvTop + ICON_COL_R, Ico);

  DrawColIcon(IcoX, AvTop + AVATAR_SIZE - ICON_COL_R, TypeIconIndex(R));

  Cv.Brush.Style := bsClear;

  { --- верхний ярус справа: время --- }
  TitleRight := ARect.Right - PAD;
  S := ChatTimeStr(R.LastDate);
  if S <> '' then begin
    Cv.Font.Style  := [];
    Cv.Font.Height := -11;
    if Sel then begin
      Cv.Font.Color := clHighlightText;
    end else begin
      Cv.Font.Color := clGrayText;
    end;
    W := Cv.TextWidth(S);
    Cv.TextOut(TitleRight - W, ARect.Top + TIME_TOP, S);
    Dec(TitleRight, W + GAP);

    { Отметка о прочтении — слева от времени, только для исходящих. }
    Rec := ReceiptBitmap(ChatReceipt(R), Sel);
    if Rec <> nil then begin
      Rec.Draw(Cv, TitleRight - Rec.Width, ARect.Top + RECEIPT_TOP, False);
      Dec(TitleRight, Rec.Width + 3);
    end;
  end;

  { --- нижний ярус справа: счётчик непрочитанных --- }
  PrevRight := ARect.Right - PAD;
  if (R.UnreadCount > 0) or R.IsMarkedAsUnread then begin
    if R.UnreadCount > 0 then begin
      S := IntToStr(R.UnreadCount);
    end else begin
      S := '';
    end;
    Badge := BadgeBitmap(S, Sel);
    if Badge <> nil then begin
      Y := ARect.Top + PREVIEW_TOP;
      Badge.Draw(Cv, PrevRight - Badge.Width, Y, False);
      Dec(PrevRight, Badge.Width + GAP);
    end;
  end;

  { --- заголовок --- }
  Cv.Font.Style  := [fsBold];
  Cv.Font.Height := -13;
  if Sel then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clWindowText;
  end;
  S := string(R.Title);
  if R.IsPinned then begin
    S := '📌 ' + S;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + TITLE_TOP,
    TitleRight, ARect.Top + TITLE_TOP + 18),
    ARect.Left + TEXT_LEFT, ARect.Top + TITLE_TOP, S);

  { --- превью последнего сообщения --- }
  Cv.Font.Style  := [];
  Cv.Font.Height := -12;
  if Sel then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clGrayText;
  end;
  S := string(R.LastText);
  if R.LastIsOutgoing and (S <> '') then begin
    S := 'You: ' + S;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP,
    PrevRight, ARect.Top + PREVIEW_TOP + 19),
    ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP, S);
end;

{ ---------------- выбор и меню ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := ChatAt(Grid.Row);
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: integer; var CanSelect: boolean);
begin
  CanSelect := True;
  { Клик пришёлся по значку или аватарке — выделение не двигаем
    и чат не открываем. }
  if FSuppressSelect then begin
    FSuppressSelect := False;
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
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, ChatAt(ARow));
  end;
end;

function TFrameChats.HitArea(X, Y: integer; out ARow: TChatRow): TChatHitArea;
var
  C, Row: integer;
  Cell: TRect;
  AvTop, LocX, LocY, DX, DY, CX, CY: integer;
begin
  Result := chaNone;
  ARow := nil;
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

  { Координаты внутри строки. }
  Cell := Grid.CellRect(C, Row);
  LocX := X - Cell.Left;
  LocY := Y - Cell.Top;
  AvTop := (ROW_HEIGHT - AVATAR_SIZE) div 2;

  { Колокольчик ловим по кругу, а не по квадрату. }
  CX := ICON_COL_L + ICON_COL_R;
  CY := AvTop + ICON_COL_R;
  DX := LocX - CX;
  DY := LocY - CY;
  if (DX * DX + DY * DY) <= (ICON_COL_R * ICON_COL_R) then begin
    Result := chaBell;
    Exit;
  end;

  if (LocX >= AV_LEFT) and (LocX < AV_LEFT + AVATAR_SIZE) and
     (LocY >= AvTop) and (LocY < AvTop + AVATAR_SIZE) then begin
    Result := chaAvatar;
  end;
end;

procedure TFrameChats.GridMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: integer);
var
  R: TChatRow;
  Want: TCursor;
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if HitArea(X, Y, R) = chaNone then begin
    Want := crDefault;
  end else begin
    Want := crHandPoint;
  end;
  { Присваиваем только при смене: OnMouseMove срабатывает густо,
    а установка курсора дёргает виджетсет. }
  if Grid.Cursor <> Want then begin
    Grid.Cursor := Want;
  end;
end;

procedure TFrameChats.GridMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
var
  R: TChatRow;
begin
  FSuppressSelect := False;
  if Button <> mbLeft then begin
    Exit;
  end;

  { Важно, что LCL вызывает inherited MouseDown ПЕРВОЙ строкой:
    наш обработчик успевает отработать до смены выделения. }
  case HitArea(X, Y, R) of
    chaHeader:
      begin
        FSuppressSelect := True;
        if FMode = clmArchive then begin
          SetMode(clmMain);
        end else begin
          SetMode(clmArchive);
        end;
      end;
    chaBell:
      begin
        FSuppressSelect := True;
        FModel.SetMuted(R, not R.IsMuted);
      end;
    chaAvatar:
      begin
        FSuppressSelect := True;
        if Assigned(FOnAvatar) then begin
          FOnAvatar(Self, R);
        end;
      end;
  end;
end;

procedure TFrameChats.GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: boolean);
var
  C, R: integer;
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

  procedure Add(const ACaption: string; ATag: integer);
  var
    MI: TMenuItem;
  begin
    MI := TMenuItem.Create(mnuChat);
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

  Add(string(ARow.Title), MI_NONE);
  mnuChat.Items[0].Enabled := False;
  Add('-', MI_NONE);

  if (ARow.UnreadCount > 0) or ARow.IsMarkedAsUnread then begin
    Add('Mark as read', MI_READ);
  end else begin
    Add('Mark as unread', MI_UNREAD);
  end;

  if ARow.IsPinned then begin
    Add('Unpin', MI_UNPIN);
  end else begin
    Add('Pin', MI_PIN);
  end;

  if ARow.InArchive then begin
    Add('Move to main list', MI_UNARCHIVE);
  end else begin
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
    MI_LEAVE:
      begin
        if MessageDlg('Leave chat',
          Format('Leave "%s"?', [string(R.Title)]),
          mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
          FModel.LeaveChat(R);
        end;
      end;
  end;
end;

end.
