unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, DateUtils, Controls, Forms, Graphics, Grids, Menus, StdCtrls, ExtCtrls,
  BGRABitmap, BGRABitmapTypes,
  tdauth, tdcore, tdchats, uiframe, avatarcache;

type
  TChatSelectEvent = procedure(Sender: TObject; ARow: TChatRow) of object;

  { TFrameChats

    Список чатов на TDrawGrid: у сетки нет собственной коллекции строк,
    поэтому модель остаётся единственным хранилищем данных, а
    перестановка чата — это просто Invalidate. }

  TFrameChats = class(TFrameBase)
    Grid:      TDrawGrid;
    pnlBottom: TPanel;
    lblStatus: TLabel;
    mnuChat:   TPopupMenu;
    procedure GridDrawCell(Sender: TObject; ACol, ARow: integer; ARect: TRect; AState: TGridDrawState);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: integer; var CanSelect: boolean);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: boolean);
  protected
    { Resize — виртуальный метод TControl, доступен всегда и не зависит
      от того, опубликовано ли одноимённое событие у потомка.
      У TDrawGrid оно НЕ опубликовано. }
    procedure Resize; override;
  private
    FCache:    TAvatarCache;
    FReady:    boolean;
    FBadges:   TStringList;   { кэш значков: ключ -> TBGRABitmap }
    FMeasure:  TBGRABitmap;   { 1x1 для замера текста тем же шрифтом }
    FReceipts: array[TChatReceipt, boolean] of TBGRABitmap;
    FMenuRow:  TChatRow;
    FOnSelect: TChatSelectEvent;
    function BadgeBitmap(const AText: string; ASelected: boolean): TBGRABitmap;
    function ReceiptBitmap(AKind: TChatReceipt; ASelected: boolean): TBGRABitmap;
    procedure ModelChanged(Sender: TObject);
    procedure LoadingChanged(Sender: TObject);
    procedure MaybeLoadMore;
    procedure BuildMenu(ARow: TChatRow);
    procedure MenuItemClick(Sender: TObject);
    function CurrentRow: TChatRow;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    property Selected: TChatRow read CurrentRow;
    property OnSelect: TChatSelectEvent read FOnSelect write FOnSelect;
  end;

implementation

{$R *.lfm}

const
  ROW_HEIGHT = 56;
  PAD = 8;
  AV_LEFT = 8;
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
    Result := 'Yesterday';
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

  TdChatList.OnChanged := @ModelChanged;
  TdChatList.OnLoadingChanged := @LoadingChanged;

  { Флаг ставится последним: до него любой ранний вызов
    (Resize во время чтения .lfm) обязан ничего не делать. }
  FReady := True;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

destructor TFrameChats.Destroy;
var
  I: integer;
  K: TChatReceipt;
begin
  FReady := False;
  { Модель живёт дольше фрейма — обязательно отцепиться, но только
    от своих обработчиков: чужие затирать нельзя. }
  if TdChatList <> nil then begin
    if TMethod(TdChatList.OnChanged).Data = Pointer(Self) then begin
      TdChatList.OnChanged := nil;
    end;
    if TMethod(TdChatList.OnLoadingChanged).Data = Pointer(Self) then begin
      TdChatList.OnLoadingChanged := nil;
    end;
  end;
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

{ ---------------- связь с моделью ---------------- }

procedure TFrameChats.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  Grid.RowCount := TdChatList.Count;
  Grid.Invalidate;
  { Если чатов меньше, чем помещается в окно, докачиваем сразу:
    прокрутки, которая обычно это запускает, не будет. }
  MaybeLoadMore;
end;

procedure TFrameChats.LoadingChanged(Sender: TObject);
begin
  if (not FReady) or (lblStatus = nil) then begin
    Exit;
  end;
  if TdChatList.Loading then begin
    lblStatus.Caption := 'Loading...';
  end else
  if TdChatList.AllLoaded then begin
    lblStatus.Caption := Format('Chats: %d', [TdChatList.Count]);
  end else begin
    lblStatus.Caption := Format('Chats: %d (there are more)', [TdChatList.Count]);
  end;
end;

procedure TFrameChats.MaybeLoadMore;
var
  LastVisible: integer;
begin
  { Resize срабатывает ещё во время чтения .lfm, когда Grid — nil.
    Любой перекрытый виртуальный метод обязан это учитывать. }
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if TdChatList.AllLoaded or TdChatList.Loading then begin
    Exit;
  end;
  LastVisible := Grid.TopRow + (Grid.ClientHeight div ROW_HEIGHT);
  if LastVisible >= TdChatList.Count - PREFETCH_ROWS then begin
    TdChatList.LoadMore;
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

{ ---------------- отрисовка ---------------- }

procedure TFrameChats.GridDrawCell(Sender: TObject; ACol, ARow: integer; ARect: TRect; AState: TGridDrawState);
var
  R:  TChatRow;
  Cv: TCanvas;
  Bmp, Badge, Rec: TBGRABitmap;
  Y, W, TitleRight, PrevRight: integer;
  Sel: boolean;
  S:  string;
begin
  { FCache создаётся в теле конструктора, то есть уже после стриминга.
    Если сетка успеет запросить отрисовку раньше — здесь nil. }
  if (not FReady) or (FCache = nil) then begin
    Exit;
  end;
  R  := TdChatList[ARow];
  Cv := Grid.Canvas;

  Sel := gdSelected in AState;
  if Sel then begin
    Cv.Brush.Color := clHighlight;
  end else begin
    Cv.Brush.Color := clWindow;
  end;
  Cv.Brush.Style := bsSolid;
  Cv.FillRect(ARect);

  if R = nil then begin
    Exit;
  end;

  { Аватарку просим только для строк, которые реально рисуются, —
    это и есть ленивость: качается лишь видимое. }
  TdChatList.EnsureAvatar(R);
  Bmp := FCache.Get(R);
  if Bmp <> nil then begin
    { Opaque=False — смешивание по альфе поверх уже залитого фона.
      Именно это даёт мягкий край на любом фоне, включая выделение. }
    Bmp.Draw(Cv, ARect.Left + AV_LEFT,
      ARect.Top + (ROW_HEIGHT - AVATAR_SIZE) div 2, False);
  end;

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
    S := 'Вы: ' + S;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP,
    PrevRight, ARect.Top + PREVIEW_TOP + 19),
    ARect.Left + TEXT_LEFT, ARect.Top + PREVIEW_TOP, S);
end;

{ ---------------- выбор и меню ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := TdChatList[Grid.Row];
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: integer; var CanSelect: boolean);
begin
  CanSelect := True;
  if not FReady then begin
    Exit;
  end;
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, TdChatList[ARow]);
  end;
end;

procedure TFrameChats.GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: boolean);
var
  C, R: integer;
begin
  if (not FReady) or (Grid = nil) then begin
    Handled := True;
    Exit;
  end;
  Grid.MouseToCell(MousePos.X, MousePos.Y, C, R);
  if (R < 0) or (R >= TdChatList.Count) then begin
    Handled := True;
    Exit;
  end;
  Grid.Row := R;
  FMenuRow := TdChatList[R];
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

  Add(string(ARow.Title), 0);
  mnuChat.Items[0].Enabled := False;
  Add('-', 0);

  if ARow.UnreadCount > 0 then begin
    Add('Mark as read', 1);
  end else begin
    Add('Mark as unread', 2);
  end;

  if ARow.IsPinned then begin
    Add('Unpin', 4);
  end else begin
    Add('Pin', 3);
  end;

  Add('-', 0);
  Add('Copy id (' + IntToStr(ARow.Id) + ')', 5);

  if ARow.Kind in [ckSupergroup, ckChannel] then begin
    Add('-', 0);
    Add('Leave', 6);
  end;
end;

procedure TFrameChats.MenuItemClick(Sender: TObject);
begin
  if FMenuRow = nil then begin
    Exit;
  end;
  { Действия появятся следующим шагом — сейчас каркас меню. }
  case TMenuItem(Sender).Tag of
    1: begin
    end;
    2: begin
    end;
    3: begin
    end;
    4: begin
    end;
    5: begin
    end;
    6: begin
    end;
  end;
end;

end.
