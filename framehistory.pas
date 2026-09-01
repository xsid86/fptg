unit framehistory;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, Math, DateUtils, LCLType, LCLIntf,
  Controls, Forms, Graphics, Clipbrd, fgl, StdCtrls, ExtCtrls,
  tdauth, tdcore, tdchats, tdmessages, tdusers, msglayout, uiframe,
  framechats;

type
  { TAudioWidget

    UI-заглушка аудио-сообщения: кружок с play, подпись. Никакого
    декодирования — реальное воспроизведение (через ffmpeg) заедет
    отдельным заходом поверх этого же класса. Recycled-контрол: живёт
    в пуле TMsgScroller, Visible переключается, сам объект не
    пересоздаётся на каждый скролл. }
  TAudioWidget = class(TCustomControl)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TAudioMap = specialize TFPGMap<Int64, TAudioWidget>;

  { TMsgScroller

    Сердце фрейма переписки: сам виртуально скроллит (позиция —
    FScrollTop, диапазон синхронизируется с нативным TScrollBar в
    TFrameHistory через OnScrollRangeChanged/OnScroll — своей
    прорисовки скроллбара тут больше нет), сам раскладывает и красит
    видимые сообщения через msglayout.RendererFor, сам считает
    попадание мыши (ссылки, выделение текста), сам держит пул
    TAudioWidget. Высоты сообщений кэшируются на TMsgRow.LayoutCache —
    пересчитывается только то, что реально изменилось (см. RebuildOffsets). }
  TMsgScroller = class(TCustomControl)
  private
    FModel:   TTdMessages;
    FOffsets: array of integer;   { длина Count+1, накопленная высота }
    FTotalHeight: integer;
    FScrollTop:   integer;

    FSelAnchorMsg, FSelFocusMsg:   Int64;
    FSelAnchorChar, FSelFocusChar: integer;
    FSelecting: boolean;

    FAudioPool:   TFPList;   { of TAudioWidget, все когда-либо созданные }
    FAudioActive: TAudioMap; { сейчас позиционированные, по id сообщения }

    FOnScrollRangeChanged: TNotifyEvent;
    FOnNearTop: TNotifyEvent;

    procedure RebuildOffsets;
    function IndexAtY(AY: integer): integer;
    function FirstVisible: integer;
    function LastVisible: integer;
    function BlockRect(AIndex: integer): TRect;
    function ContentRect(AIndex: integer): TRect;
    procedure LayoutAudioWidgets(ALo, AHi: integer);
    function ObtainAudioWidget: TAudioWidget;
    function HitTestAt(X, Y: integer; out AIndex: integer): TMsgHit;
    function ResolveSelection(out ALowIdx, AHighIdx, ALowChar, AHighChar: integer): boolean;
    procedure RangeForRow(AIndex, ALowIdx, AHighIdx, ALowChar, AHighChar,
      ATextLen: integer; out ASelStart, ASelEnd: integer);
    procedure ClampScrollTop(AValue: integer);
    procedure SetScrollTop(AValue: integer);
    procedure DoLinkClick(const AUrl: utf8string);
    procedure CopySelection;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: integer;
      MousePos: TPoint): boolean; override;
    procedure KeyDown(var Key: word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { AModel = nil отвязывает (смена аккаунта на пустой список). }
    procedure BindModel(AModel: TTdMessages);
    { Модель прислала OnChanged: пересчитать оффсеты, удержать якорь
      прокрутки (см. реализацию — без прыжка при подгрузке вверх). }
    procedure ModelChanged;
    procedure ScrollToBottom;
    property ScrollTop: integer read FScrollTop write SetScrollTop;
    property TotalHeight: integer read FTotalHeight;
    property OnScrollRangeChanged: TNotifyEvent read FOnScrollRangeChanged write FOnScrollRangeChanged;
    property OnNearTop: TNotifyEvent read FOnNearTop write FOnNearTop;
  end;

  { TFrameHistory

    Экран переписки. Открывается через OpenChat(chatId) — вызывающая
    сторона (main.pas, клик по чату) сама решает, когда его показать
    через навигатор. }
  TFrameHistory = class(TFrameBase, ITdActiveListener)
  private
    FReady: boolean;
    FModel: TTdMessages;
    { Кэш имён — не "модель этого фрейма" в том же смысле, что FModel
      (история одного открытого чата): один на аккаунт, переживает
      смену чата, поэтому у него собственная лёгкая привязка внутри
      BindModel/UnbindModel, а не полноценный Bind/Unbind как у FModel. }
    FUsers: TTdUsers;
    FScroller:  TMsgScroller;
    FScrollbar: TScrollBar;
    pnlStatus:  TPanel;
    lblStatus:  TLabel;
    procedure BindModel;
    procedure UnbindModel;
    procedure ModelChanged(Sender: TObject);
    procedure LoadingChanged(Sender: TObject);
    { Кэшу имён/аватарке отправителя пришёл ответ на getUser — просто
      перерисовать: высота блока не меняется от того, что имя
      дорезолвилось, полная пересборка офсетов не нужна. }
    procedure UsersChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: integer;
      const AMessage, AAction: utf8string);
    procedure ScrollerRangeChanged(Sender: TObject);
    procedure ScrollerNearTop(Sender: TObject);
    procedure ScrollbarScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
    procedure MaybeLoadMore;
  protected
    procedure Resize; override;
    procedure DoActivate; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;

    procedure OpenChat(AChatId: Int64);

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

implementation

{ main в реализации, а не в интерфейсе: main сам использует
  framehistory (навигатор рабочей области), и в интерфейсе это дало бы
  цикл — тот же приём, что у main/login (см. main.pas). Нужен только
  ради FormMain.Chats.ImageList1 (значки статуса сообщения, §3 плана). }
uses
  main;

{$R *.lfm}

const
  MSG_PAD_H      = 12;
  MSG_PAD_V      = 6;
  MSG_GAP        = 4;
  { HEADER_H — высота самого значка/текста заголовка (для центрирования
    внутри неё). HEADER_BAR_H — сколько места заголовок реально
    занимает в блоке: та же высота плюс отступ MSG_GAP сверху и снизу
    внутри цветной подложки заголовка — тот же отступ, что между
    сообщениями (MSG_GAP), не отдельное магическое число. }
  HEADER_H       = 16;
  HEADER_BAR_H   = HEADER_H + 2 * MSG_GAP;
  NEAR_TOP_PX    = 400;
  WHEEL_LINE_PX  = 60;
  LINE_SCROLL_PX = 24;
  { Слот под значок статуса в заголовке блока — зарезервирован даже у
    входящих сообщений (там значка нет, crNone), чтобы имя отправителя
    не "прыгало" по горизонтали от строки к строке. }
  MSG_ICON_W     = 16;
  MSG_ICON_GAP   = 4;

  { Цвет отправителя по кругу — единственное место в файле, которое
    придётся тронуть под тёмную тему (см. план: полноценную
    инфраструктуру тем сейчас не строим, только не закапываем цвета
    россыпью литералов по коду отрисовки). TColor — $00BBGGRR, поэтому
    у каждого значения рядом RGB для читаемости при будущей правке. }
  SENDER_PALETTE: array[0..7] of TColor = (
    $2222B2,  { RGB(178, 34, 34)  firebrick }
    $228B22,  { RGB( 34,139, 34)  forest green }
    $A0501E,  { RGB( 30, 80,160)  steel blue }
    $800080,  { RGB(128,  0,128)  purple }
    $005AB4,  { RGB(180, 90,  0)  dark orange }
    $808000,  { RGB(  0,128,128)  teal }
    $8515C7,  { RGB(199, 21,133)  medium violet red }
    $008080   { RGB(128,128,  0)  olive }
  );
  { Насколько сильно цвет отправителя проступает в подложке блока —
    0.1 = 10% цвета поверх фона, остальное клBackground. Тоже
    вынесено, а не зашито внутрь BlendWithBackground, по той же причине,
    что и SENDER_PALETTE — легко подправить под тёмную тему/на вкус. }
  SENDER_BG_OPACITY = 0.1;
  { Подложка именно строки заголовка (значок+имя) — заметнее, чем фон
    всего блока: свой, более высокий уровень прозрачности. }
  SENDER_HEADER_OPACITY = 0.2;

{ Цвет по кругу, детерминированно по id отправителя — свой SenderUserId
  просто обычное значение в этом же хэше, поэтому исходящие сообщения
  получают стабильный цвет автоматически, без отдельной ветки на
  IsOutgoing. SenderChatId у каналов/супергрупп бывает отрицательным
  (см. tdlib_raw.log) — Abs, чтобы не уйти за границу массива. }
function SenderColor(ARow: TMsgRow): TColor;
var
  Id: Int64;
begin
  if ARow.SenderUserId <> 0 then begin
    Id := ARow.SenderUserId;
  end else begin
    Id := ARow.SenderChatId;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

{ Смешивает AColor с ABackground в пропорции AOpacity (0..1) —
  подложка блока сообщения, "цвет отправителя приглушённо поверх фона",
  без настоящей альфа-композиции (BGRABitmap) — она была бы избыточна
  для сплошной заливки прямоугольника, а Paint дёргается на каждый
  скролл. ColorToRGB разворачивает системные цвета (напр. clWindow)
  в реальные RGB — без этого блендинг псевдо-цвета дал бы мусор. }
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

{ Имя отправителя. SenderChatId (анонимный админ/пост от имени канала)
  резолвится через уже загруженный список чатов, не через TTdUsers —
  это не пользователь. }
function SenderDisplayName(ARow: TMsgRow): utf8string;
var
  C: TChatRow;
  U: TTdUsers;
  L: TTdChats;
begin
  Result := '';
  if ARow.SenderUserId <> 0 then begin
    U := TdUserList;
    if U <> nil then begin
      Result := U.DisplayName(ARow.SenderUserId);
    end;
  end else if ARow.SenderChatId <> 0 then begin
    L := TdChatList;
    C := nil;
    if L <> nil then begin
      C := L.Lookup(ARow.SenderChatId);
    end;
    if C <> nil then begin
      Result := C.Title;
    end else begin
      Result := 'Channel';
    end;
  end;
end;

{ Индекс кадра в ImageList1 (framechats.pas) под значок статуса
  исходящего сообщения; -1 — не рисовать (crNone, входящее). }
function ReceiptIconIndex(AKind: TChatReceipt): integer;
begin
  case AKind of
    crSent:    Result := ICON_MSG_SENT;
    crRead:    Result := ICON_MSG_READ;
    crPending: Result := ICON_MSG_PENDING;
    crFailed:  Result := ICON_MSG_FAILED;
  else
    Result := -1;
  end;
end;

{ ---------------- TAudioWidget ---------------- }

constructor TAudioWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  Color := clBtnFace;
end;

procedure TAudioWidget.Paint;
var
  R: TRect;
  CX, CY: integer;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(ClientRect);

  R := Rect(8, (ClientHeight - 32) div 2, 8 + 32, (ClientHeight - 32) div 2 + 32);
  Canvas.Pen.Color := clGrayText;
  Canvas.Brush.Color := clWindow;
  Canvas.Ellipse(R);

  CX := (R.Left + R.Right) div 2;
  CY := (R.Top + R.Bottom) div 2;
  Canvas.Brush.Color := clGrayText;
  Canvas.Pen.Color := clGrayText;
  Canvas.Polygon([Point(CX - 5, CY - 8), Point(CX - 5, CY + 8), Point(CX + 8, CY)]);

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clGrayText;
  Canvas.TextOut(R.Right + 12, (ClientHeight - Canvas.TextHeight('0')) div 2,
    'Audio (UI only)');
end;

{ ---------------- TMsgScroller ---------------- }

constructor TMsgScroller.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  TabStop := True;
  Color := clWindow;
  FAudioPool := TFPList.Create;
  FAudioActive := TAudioMap.Create;
  FAudioActive.Sorted := True;
  SetLength(FOffsets, 1);
  FOffsets[0] := 0;
end;

destructor TMsgScroller.Destroy;
begin
  FAudioActive.Free;
  { Сами виджеты не освобождаем: они дочерние control'ы Self,
    их уничтожит LCL вместе с родителем. }
  FAudioPool.Free;
  inherited Destroy;
end;

procedure TMsgScroller.BindModel(AModel: TTdMessages);
begin
  FModel := AModel;
  FSelAnchorMsg := 0;
  FSelFocusMsg := 0;
  FSelecting := False;
  FScrollTop := 0;
  RebuildOffsets;
  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

procedure TMsgScroller.RebuildOffsets;
var
  I, AvailW, H, Cnt: integer;
  Ctx: TMsgLayoutCtx;
begin
  { Align/Resize может дёрнуть это ещё в конструкторе TFrameHistory,
    когда у фрейма самого ещё нет Parent (навигатор выставляет его
    только ПОСЛЕ Create) — обращение к Canvas в этот момент кидает
    EInvalidOperation "Control has no parent window". Досчитаем,
    когда появится настоящий хэндл: BindModel и следующий Resize это
    гарантируют. }
  if not HandleAllocated then begin
    SetLength(FOffsets, 1);
    FOffsets[0] := 0;
    FTotalHeight := 0;
    Exit;
  end;

  Cnt := 0;
  if FModel <> nil then begin
    Cnt := FModel.Count;
  end;

  AvailW := ClientWidth - 2 * MSG_PAD_H;
  if AvailW < 20 then begin
    AvailW := 20;
  end;
  Ctx.Canvas := Canvas;
  Ctx.AvailWidth := AvailW;

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -13;
  Canvas.Font.Style := [];

  SetLength(FOffsets, Cnt + 1);
  FOffsets[0] := 0;
  for I := 0 to Cnt - 1 do begin
    H := HEADER_BAR_H + RendererFor(FModel[I].Kind).Measure(FModel[I], Ctx) + 2 * MSG_PAD_V;
    FOffsets[I + 1] := FOffsets[I] + H + MSG_GAP;
  end;

  if Cnt > 0 then begin
    FTotalHeight := FOffsets[Cnt] - MSG_GAP;
  end else begin
    FTotalHeight := 0;
  end;
end;

function TMsgScroller.IndexAtY(AY: integer): integer;
var
  Lo, Hi, Mid, Cnt: integer;
begin
  Cnt := Length(FOffsets) - 1;
  if Cnt <= 0 then begin
    Result := -1;
    Exit;
  end;
  if AY < 0 then begin
    Result := 0;
    Exit;
  end;
  if AY >= FOffsets[Cnt] then begin
    Result := Cnt - 1;
    Exit;
  end;
  Lo := 0;
  Hi := Cnt - 1;
  while Lo < Hi do begin
    Mid := (Lo + Hi + 1) div 2;
    if FOffsets[Mid] <= AY then begin
      Lo := Mid;
    end else begin
      Hi := Mid - 1;
    end;
  end;
  Result := Lo;
end;

function TMsgScroller.FirstVisible: integer;
begin
  Result := IndexAtY(FScrollTop);
end;

function TMsgScroller.LastVisible: integer;
begin
  Result := IndexAtY(FScrollTop + ClientHeight - 1);
end;

function TMsgScroller.BlockRect(AIndex: integer): TRect;
begin
  Result := Rect(0, FOffsets[AIndex] - FScrollTop, ClientWidth,
    FOffsets[AIndex] - FScrollTop + (FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP));
end;

function TMsgScroller.ContentRect(AIndex: integer): TRect;
var
  BlockH, ContentH, TopY: integer;
begin
  BlockH := FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP;
  ContentH := BlockH - HEADER_BAR_H - 2 * MSG_PAD_V;
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + MSG_PAD_V;
  Result := Rect(MSG_PAD_H, TopY, ClientWidth - MSG_PAD_H, TopY + ContentH);
end;

{ Зажимает и применяет позицию без уведомления "около верха — догрузи
  ещё". Внутренняя бухгалтерия (ModelChanged, Resize) правит
  FScrollTop программно и НЕ должна интерпретироваться как "юзер
  прокрутил и хочет больше" — за досыл короткой истории отвечает
  MaybeLoadMore в TFrameHistory.ModelChanged, вызываемый отдельно и
  ровно один раз. }
procedure TMsgScroller.ClampScrollTop(AValue: integer);
var
  MaxTop: integer;
begin
  MaxTop := FTotalHeight - ClientHeight;
  if MaxTop < 0 then begin
    MaxTop := 0;
  end;
  if AValue < 0 then begin
    AValue := 0;
  end;
  if AValue > MaxTop then begin
    AValue := MaxTop;
  end;
  if AValue = FScrollTop then begin
    Exit;
  end;
  FScrollTop := AValue;
  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

{ Публичный сеттер — только для настоящей прокрутки пользователем
  (колесо, клавиши, нативный скроллбар). Раньше OnNearTop дёргался
  отсюда же ИЗНУТРИ вложенной цепочки ModelChanged->ScrollToBottom
  ->SetScrollTop->OnNearTop->LoadOlder ещё до возврата в сам
  ModelChanged — рабочей эта цепочка была, но реентрантной и хрупкой.
  Теперь программные правки позиции идут через ClampScrollTop и в
  OnNearTop не заходят вовсе. }
procedure TMsgScroller.SetScrollTop(AValue: integer);
begin
  ClampScrollTop(AValue);
  { НЕ внутри проверки "значение изменилось" у ClampScrollTop: если
    пользователь уже упёрся в самый верх (FScrollTop=0=MaxTop) и
    продолжает крутить колесо вверх, зажатое AValue совпадёт с уже
    текущим FScrollTop — и если бы OnNearTop звался только при
    изменении, подгрузка старой истории переставала бы запускаться
    намертво ровно тогда, когда она нужнее всего.
    ScrollerNearTop idempotent (гвардится LoadingOlder/OldestLoaded),
    повторный вызов безопасен. }
  if (FScrollTop <= NEAR_TOP_PX) and Assigned(FOnNearTop) then begin
    FOnNearTop(Self);
  end;
end;

procedure TMsgScroller.ScrollToBottom;
begin
  ClampScrollTop(FTotalHeight - ClientHeight);
end;

procedure TMsgScroller.ModelChanged;
var
  WasAtBottom: boolean;
  OldMax: integer;
  AnchorId: Int64;
  AnchorIdx, AnchorOldOffset, AnchorNewOffset: integer;
begin
  OldMax := FTotalHeight - ClientHeight;
  WasAtBottom := (OldMax <= 0) or (FScrollTop >= OldMax - 4);

  { Запоминаем сообщение в верхней видимой строке — после подгрузки
    истории (LoadOlder добавляет контент ВЫШЕ) вернём его на то же
    место в окне, иначе список визуально прыгнет. }
  AnchorId := 0;
  AnchorOldOffset := 0;
  AnchorIdx := IndexAtY(FScrollTop);
  if (AnchorIdx >= 0) and (FModel <> nil) and (AnchorIdx < FModel.Count) then begin
    AnchorId := FModel[AnchorIdx].Id;
    AnchorOldOffset := FScrollTop - FOffsets[AnchorIdx];
  end;

  RebuildOffsets;

  if WasAtBottom then begin
    ScrollToBottom;
  end else if AnchorId <> 0 then begin
    AnchorIdx := FModel.IndexOfId(AnchorId);
    if AnchorIdx >= 0 then begin
      AnchorNewOffset := FOffsets[AnchorIdx];
      ClampScrollTop(AnchorNewOffset + AnchorOldOffset);
    end else begin
      ClampScrollTop(FScrollTop);
    end;
  end else begin
    ClampScrollTop(FScrollTop);
  end;

  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

procedure TMsgScroller.Resize;
begin
  inherited Resize;
  { Тоже вне try/except-обвязки TFrameHistory.ModelChanged: Resize
    зовёт LCL напрямую (изменение размера окна, сплиттер), а не
    ModelChanged. RebuildOffsets — то же измерение реальных
    сообщений, что и там, значит те же риски. }
  try
    RebuildOffsets;
    ClampScrollTop(FScrollTop);
  except
  end;
  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

function TMsgScroller.ResolveSelection(out ALowIdx, AHighIdx, ALowChar, AHighChar: integer): boolean;
var
  AnchorIdx, FocusIdx: integer;
begin
  Result := False;
  ALowIdx := -1;
  AHighIdx := -1;
  ALowChar := 0;
  AHighChar := 0;
  if (FModel = nil) or (FSelAnchorMsg = 0) or (FSelFocusMsg = 0) then begin
    Exit;
  end;
  AnchorIdx := FModel.IndexOfId(FSelAnchorMsg);
  FocusIdx := FModel.IndexOfId(FSelFocusMsg);
  if (AnchorIdx < 0) or (FocusIdx < 0) then begin
    Exit;
  end;
  if (AnchorIdx = FocusIdx) and (FSelAnchorChar = FSelFocusChar) then begin
    Exit;   { пустое выделение — обычный клик без drag }
  end;
  if AnchorIdx <= FocusIdx then begin
    ALowIdx := AnchorIdx;
    ALowChar := FSelAnchorChar;
    AHighIdx := FocusIdx;
    AHighChar := FSelFocusChar;
  end else begin
    ALowIdx := FocusIdx;
    ALowChar := FSelFocusChar;
    AHighIdx := AnchorIdx;
    AHighChar := FSelAnchorChar;
  end;
  Result := True;
end;

procedure TMsgScroller.RangeForRow(AIndex, ALowIdx, AHighIdx, ALowChar, AHighChar,
  ATextLen: integer; out ASelStart, ASelEnd: integer);
begin
  if ALowIdx = AHighIdx then begin
    ASelStart := Min(ALowChar, AHighChar);
    ASelEnd := Max(ALowChar, AHighChar);
  end else if AIndex = ALowIdx then begin
    ASelStart := ALowChar;
    ASelEnd := ATextLen;
  end else if AIndex = AHighIdx then begin
    ASelStart := 0;
    ASelEnd := AHighChar;
  end else begin
    ASelStart := 0;
    ASelEnd := ATextLen;
  end;
end;

procedure TMsgScroller.Paint;
var
  I, Lo, Hi: integer;
  R: TMsgRow;
  BR, CR: TRect;
  S: string;
  SelStart, SelEnd, LowIdx, HighIdx, LowChar, HighChar: integer;
  HasSel: boolean;
  ChatRow: TChatRow;
  LastReadOutbox: Int64;
  IconList: TImageList;
  HeaderX, HeaderY, IconIdx: integer;
  LocalDT: TDateTime;
  TimeStr, NameStr, SuffixStr: string;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(ClientRect);

  if (FModel = nil) or (FModel.Count = 0) then begin
    Exit;
  end;

  Lo := FirstVisible;
  Hi := LastVisible;
  if (Lo < 0) or (Hi < 0) then begin
    Exit;
  end;

  HasSel := ResolveSelection(LowIdx, HighIdx, LowChar, HighChar);

  { Значок статуса — по чату целиком, не по строке: LastReadOutbox
    одинаков для всех сообщений текущего чата, доставать его на
    каждую строку внутри цикла ниже незачем. }
  ChatRow := nil;
  if TdChatList <> nil then begin
    ChatRow := TdChatList.Lookup(FModel.ChatId);
  end;
  if ChatRow <> nil then begin
    LastReadOutbox := ChatRow.LastReadOutbox;
  end else begin
    LastReadOutbox := 0;
  end;
  IconList := nil;
  if (FormMain <> nil) and (FormMain.Chats <> nil) then begin
    IconList := FormMain.Chats.ImageList1;
  end;

  { Единственный путь исполнения из всей смены чата, где раньше не
    было try/except: Paint вызывается напрямую системой отрисовки
    (WM_PAINT), а не через ModelChanged, поэтому туда не долетала
    защита, добавленная в TFrameHistory.ModelChanged/OpenChat.
    Необработанное исключение внутри WM_PAINT — классический источник
    зависаний Win32-приложений (окно перестаёт отвечать на дальнейшую
    перерисовку/ввод); каждая строка — в своём try/except, чтобы одно
    проблемное сообщение не убивало всю перерисовку. }
  for I := Lo to Hi do begin
    try
      R := FModel[I];
      BR := BlockRect(I);
      CR := ContentRect(I);

      { Подложка блока — цвет отправителя приглушённо поверх фона,
        SENDER_BG_OPACITY. Заливаем ПЕРЕД заголовком/контентом, чтобы
        текст и разделительная линия легли поверх, не под. }
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY, clWindow);
      Canvas.FillRect(BR);

      { Подложка самой строки заголовка (значок+имя) — заметнее фона
        блока (SENDER_HEADER_OPACITY > SENDER_BG_OPACITY), поверх уже
        закрашенного фона блока. Отступ значка/текста от верхнего и
        нижнего края этой полосы — MSG_GAP, тот же, что между
        сообщениями (HeaderY, а не BR.Top напрямую). }
      Canvas.Brush.Color := BlendWithBackground(SenderColor(R), SENDER_HEADER_OPACITY, clWindow);
      Canvas.FillRect(Rect(BR.Left, BR.Top, BR.Right, BR.Top + HEADER_BAR_H));
      HeaderY := BR.Top + MSG_GAP;

      Canvas.Brush.Style := bsClear;
      Canvas.Font.Name := 'default';
      Canvas.Font.Height := -11;
      HeaderX := BR.Left + MSG_PAD_H;

      { У исходящих — статус доставки, у входящих — просто маркер
        направления (ICON_MSG_INCOMING, не статус: у чужого сообщения
        "доставлено/прочитано" с нашей стороны не бывает). Слот
        зарезервирован в любом случае, чтобы имя не "прыгало" по
        горизонтали от строки к строке. }
      if R.IsOutgoing then begin
        IconIdx := ReceiptIconIndex(MessageReceipt(R, LastReadOutbox));
      end else begin
        IconIdx := ICON_MSG_INCOMING;
      end;
      if IconList <> nil then begin
        if (IconIdx >= 0) and (IconIdx < IconList.Count) then begin
          IconList.Draw(Canvas, HeaderX, HeaderY + (HEADER_H - IconList.Height) div 2, IconIdx, True);
        end;
      end;
      Inc(HeaderX, MSG_ICON_W + MSG_ICON_GAP);

      LocalDT := UniversalTimeToLocal(UnixToDateTime(R.Date));
      if SameDate(LocalDT, Date) then begin
        TimeStr := FormatDateTime('hh:nn', LocalDT);
      end else begin
        TimeStr := FormatDateTime('hh:nn dd.mm.yy', LocalDT);
      end;
      NameStr := string(SenderDisplayName(R));
      if NameStr = '' then begin
        S := '(' + TimeStr + ')';
      end else begin
        S := NameStr + ' (' + TimeStr + ')';
      end;

      Canvas.Font.Style := [fsBold];
      Canvas.Font.Color := SenderColor(R);
      Canvas.TextOut(HeaderX, HeaderY, S);

      SuffixStr := '';
      if R.IsOutgoing then begin
        case R.Delivery of
          mdsPending: SuffixStr := '  sending...';
          mdsFailed:  SuffixStr := '  failed';
        end;
      end;
      if SuffixStr <> '' then begin
        Canvas.Font.Style := [];
        Canvas.Font.Color := clGrayText;
        Canvas.TextOut(HeaderX + Canvas.TextWidth(S), HeaderY, SuffixStr);
      end;

      Canvas.Font.Height := -13;
      if HasSel and (I >= LowIdx) and (I <= HighIdx) then begin
        RangeForRow(I, LowIdx, HighIdx, LowChar, HighChar, Length(R.PlainText), SelStart, SelEnd);
      end else begin
        SelStart := -1;
        SelEnd := -1;
      end;

      RendererFor(R.Kind).Paint(R, Canvas, CR, SelStart, SelEnd);

      { Тонкая разделительная линия под блоком — визуально ближе к
        плотной ленте QIP, чем голый MSG_GAP. }
      Canvas.Pen.Color := clBtnFace;
      Canvas.Pen.Style := psSolid;
      Canvas.MoveTo(0, BR.Bottom - 1);
      Canvas.LineTo(ClientWidth, BR.Bottom - 1);
    except
      { Молча пропускаем эту строку: статус-строка обновляется из
        ModelChanged, а не отсюда — Paint может вызываться десятками
        раз в секунду, спамить в неё было бы только хуже. }
    end;
  end;

  try
    LayoutAudioWidgets(Lo, Hi);
  except
  end;
end;

procedure TMsgScroller.LayoutAudioWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TAudioWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckAudio then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FAudioActive.Count - 1 downto 0 do begin
    if not IsWanted(FAudioActive.Keys[AIdx]) then begin
      FAudioActive.Data[AIdx].Visible := False;
      FAudioActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FAudioActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FAudioActive.Data[AIdx];
    end else begin
      W := ObtainAudioWidget;
      FAudioActive.Add(WantIds[I], W);
    end;
    W.SetBounds(CR.Left, CR.Top, CR.Right - CR.Left, CR.Bottom - CR.Top);
    W.Visible := True;
  end;
end;

function TMsgScroller.ObtainAudioWidget: TAudioWidget;
var
  I: integer;
begin
  for I := 0 to FAudioPool.Count - 1 do begin
    Result := TAudioWidget(FAudioPool[I]);
    if not Result.Visible then begin
      Exit;
    end;
  end;
  Result := TAudioWidget.Create(Self);
  Result.Parent := Self;
  FAudioPool.Add(Result);
end;

function TMsgScroller.HitTestAt(X, Y: integer; out AIndex: integer): TMsgHit;
var
  R: TMsgRow;
  CR: TRect;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
  AIndex := -1;
  if (FModel = nil) or (FModel.Count = 0) then begin
    Exit;
  end;
  AIndex := IndexAtY(FScrollTop + Y);
  if AIndex < 0 then begin
    Exit;
  end;
  R := FModel[AIndex];
  CR := ContentRect(AIndex);
  Result := RendererFor(R.Kind).HitTest(R, CR, X, Y);
end;

procedure TMsgScroller.DoLinkClick(const AUrl: utf8string);
var
  U: string;
begin
  if AUrl = '' then begin
    Exit;
  end;
  U := string(AUrl);
  if Pos('://', U) = 0 then begin
    U := 'https://' + U;
  end;
  OpenURL(U);
end;

procedure TMsgScroller.CopySelection;
var
  I, LowIdx, HighIdx, LowChar, HighChar, SelStart, SelEnd: integer;
  R: TMsgRow;
  Lines: TStringList;
begin
  if not ResolveSelection(LowIdx, HighIdx, LowChar, HighChar) then begin
    Exit;
  end;
  Lines := TStringList.Create;
  try
    for I := LowIdx to HighIdx do begin
      R := FModel[I];
      RangeForRow(I, LowIdx, HighIdx, LowChar, HighChar, Length(R.PlainText), SelStart, SelEnd);
      if SelEnd > SelStart then begin
        Lines.Add(string(Copy(R.PlainText, SelStart + 1, SelEnd - SelStart)));
      end;
    end;
    Clipboard.AsText := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TMsgScroller.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  Hit: TMsgHit;
  Idx: integer;
  R: TMsgRow;
begin
  inherited MouseDown(Button, Shift, X, Y);
  SetFocus;
  if Button <> mbLeft then begin
    Exit;
  end;

  Hit := HitTestAt(X, Y, Idx);
  if Idx < 0 then begin
    FSelAnchorMsg := 0;
    FSelFocusMsg := 0;
    Invalidate;
    Exit;
  end;

  if Hit.Kind = mhkLink then begin
    DoLinkClick(Hit.URL);
    Exit;
  end;

  R := FModel[Idx];
  FSelAnchorMsg := R.Id;
  FSelFocusMsg := R.Id;
  if Hit.CharOffset >= 0 then begin
    FSelAnchorChar := Hit.CharOffset;
  end else begin
    FSelAnchorChar := 0;
  end;
  FSelFocusChar := FSelAnchorChar;
  FSelecting := True;
  { Без захвата мыши: увели курсор за пределы control'а во время
    drag'а и отпустили кнопку там — MouseUp сюда не долетит (LCL не
    маршрутизирует его без MouseCapture), FSelecting зависает в True
    навсегда, и дальше обычное движение мыши БЕЗ зажатой кнопки
    начинает выглядеть как продолжающееся выделение. Это и есть
    "странное поведение выделения". }
  MouseCapture := True;
  Invalidate;
end;

procedure TMsgScroller.MouseMove(Shift: TShiftState; X, Y: integer);
var
  Hit: TMsgHit;
  Idx: integer;
  R: TMsgRow;
  Want: TCursor;
begin
  inherited MouseMove(Shift, X, Y);

  if FSelecting then begin
    Idx := IndexAtY(FScrollTop + Y);
    if Idx >= 0 then begin
      R := FModel[Idx];
      Hit := RendererFor(R.Kind).HitTest(R, ContentRect(Idx), X, Y);
      FSelFocusMsg := R.Id;
      if Hit.CharOffset >= 0 then begin
        FSelFocusChar := Hit.CharOffset;
      end else if Y < ContentRect(Idx).Top then begin
        FSelFocusChar := 0;
      end else begin
        FSelFocusChar := Length(R.PlainText);
      end;
      Invalidate;
    end;
    Exit;
  end;

  Hit := HitTestAt(X, Y, Idx);
  if Hit.Kind = mhkLink then begin
    Want := crHandPoint;
  end else if Hit.Kind = mhkText then begin
    Want := crIBeam;
  end else begin
    Want := crDefault;
  end;
  if Cursor <> Want then begin
    Cursor := Want;
  end;
end;

procedure TMsgScroller.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FSelecting := False;
  if MouseCapture then begin
    MouseCapture := False;
  end;
end;

function TMsgScroller.DoMouseWheel(Shift: TShiftState; WheelDelta: integer;
  MousePos: TPoint): boolean;
begin
  Result := True;
  SetScrollTop(FScrollTop - (WheelDelta div 120) * WHEEL_LINE_PX);
end;

procedure TMsgScroller.KeyDown(var Key: word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_C:
      if ssCtrl in Shift then begin
        CopySelection;
        Key := 0;
      end;
    VK_UP:    SetScrollTop(FScrollTop - LINE_SCROLL_PX);
    VK_DOWN:  SetScrollTop(FScrollTop + LINE_SCROLL_PX);
    VK_PRIOR: SetScrollTop(FScrollTop - ClientHeight);
    VK_NEXT:  SetScrollTop(FScrollTop + ClientHeight);
    VK_HOME:  SetScrollTop(0);
    VK_END:   SetScrollTop(FTotalHeight);
  end;
end;

{ ---------------- TFrameHistory ---------------- }

constructor TFrameHistory.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);

  pnlStatus := TPanel.Create(Self);
  pnlStatus.Parent := Self;
  pnlStatus.Align := alTop;
  pnlStatus.Height := 22;
  pnlStatus.BevelOuter := bvNone;
  lblStatus := TLabel.Create(Self);
  lblStatus.Parent := pnlStatus;
  lblStatus.Left := 8;
  lblStatus.Top := 4;
  lblStatus.AutoSize := False;
  lblStatus.Width := 600;
  lblStatus.Font.Color := clGrayText;
  lblStatus.Caption := '';

  FScrollbar := TScrollBar.Create(Self);
  FScrollbar.Parent := Self;
  FScrollbar.Kind := sbVertical;
  FScrollbar.Align := alRight;
  { Не константа: список чатов (framechats, TDrawGrid) рисует свой
    скроллбар нативно, шириной под системный метрик — тот же
    GetSystemMetrics(SM_CXVSCROLL), которым Windows и масштабирует
    его под DPI. Фиксированное число здесь просто разъезжалось бы с
    ним при любом отличном от 100% масштабе экрана. }
  FScrollbar.Width := GetSystemMetrics(SM_CXVSCROLL);
  FScrollbar.OnScroll := @ScrollbarScroll;

  FScroller := TMsgScroller.Create(Self);
  FScroller.Parent := Self;
  FScroller.Align := alClient;
  FScroller.OnScrollRangeChanged := @ScrollerRangeChanged;
  FScroller.OnNearTop := @ScrollerNearTop;

  { Флаг ставится последним по тому же правилу, что и во всех формах
    и фреймах проекта: LFM-стриминг (тут его формально нет, но
    Align-докинг может дёрнуть Resize раньше) не должен наткнуться на
    недособранные поля. }
  FReady := True;

  { BindModel сюда, в конструктор, НЕ зовём: у фрейма в этот момент
    ещё нет Parent (TFrameNavigator.ShowFrame выставляет его только
    ПОСЛЕ Create) — до тех пор у control'ов нет настоящего окна, и
    любое обращение к Canvas валит EInvalidOperation "has no parent
    window". Первое связывание — в DoActivate, куда навигатор
    попадает уже после Parent/Visible. }
  TdApp.SubscribeActive(Self);
end;

destructor TFrameHistory.Destroy;
begin
  FReady := False;
  TdApp.UnsubscribeActive(Self);
  UnbindModel;
  inherited Destroy;
end;

procedure TFrameHistory.BindModel;
begin
  FModel := TdMsgList;
  FScroller.BindModel(FModel);

  { Кэш имён — не смотрим на nil-раннюю Exit ниже: он привязывается
    независимо от того, есть ли уже открытый чат. }
  FUsers := TdUserList;
  if FUsers <> nil then begin
    FUsers.OnChanged := @UsersChanged;
  end;

  if FModel = nil then begin
    Exit;
  end;
  FModel.OnChanged := @ModelChanged;
  FModel.OnLoadingChanged := @LoadingChanged;
  FModel.OnActionError := @ActionError;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

procedure TFrameHistory.UnbindModel;
begin
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
  if FUsers <> nil then begin
    if TMethod(FUsers.OnChanged).Data = Pointer(Self) then begin
      FUsers.OnChanged := nil;
    end;
    FUsers := nil;
  end;
  FScroller.BindModel(nil);
end;

procedure TFrameHistory.OpenChat(AChatId: Int64);
begin
  if FModel = nil then begin
    Exit;
  end;
  { OpenChat синхронно дёргает FOnChanged (=ModelChanged) прямо
    отсюда — та цепочка сама уже обвязана try/except, но ловим и
    здесь: если исключение всё же прорвётся откуда-то ещё по пути
    (напр. из самой TTdMessages.OpenChat/Clear), пусть осядет в
    статус-строке, а не уйдёт необработанным в LCL — под отладчиком
    это выглядит как наглухо зависшее приложение, если диалог
    исключения всплывает не поверх активного окна. }
  try
    FModel.OpenChat(AChatId);
  except
    on E: Exception do begin
      if lblStatus <> nil then begin
        lblStatus.Caption := 'OpenChat error: ' + E.Message;
      end;
    end;
  end;
end;

procedure TFrameHistory.TdActiveChanged(ANew: TTdAccount);
begin
  if not FReady then begin
    Exit;
  end;
  UnbindModel;
  BindModel;
end;

procedure TFrameHistory.TdAccountsChanged;
begin
  { состав аккаунтов фрейму переписки не важен }
end;

procedure TFrameHistory.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (FModel = nil) then begin
    Exit;
  end;
  { Диагностическая обвязка: FScroller.ModelChanged — самый сложный
    кусок (пересчёт оффсетов, удержание якоря прокрутки, измерение
    реальных сообщений через msglayout) и единственное на весь чейн
    смены чата место без своего try/except. Если зависание при
    переключении чатов вызвано необработанным исключением где-то
    здесь (напр. неожиданная форма контента конкретного сообщения при
    первом реальном измерении) — оно осядет в статус-строке вместо
    того, чтобы просочиться в Application.HandleException. }
  try
    FScroller.ModelChanged;
    MaybeLoadMore;
    LoadingChanged(nil);
  except
    on E: Exception do begin
      if lblStatus <> nil then begin
        lblStatus.Caption := 'UI error: ' + E.Message;
      end;
    end;
  end;
end;

procedure TFrameHistory.LoadingChanged(Sender: TObject);
begin
  if (not FReady) or (lblStatus = nil) or (FModel = nil) then begin
    Exit;
  end;
  if FModel.LoadingOlder then begin
    lblStatus.Caption := 'Loading history...';
  end else if FModel.OldestLoaded then begin
    lblStatus.Caption := Format('%d messages (all loaded)', [FModel.Count]);
  end else begin
    lblStatus.Caption := Format('%d messages (more)', [FModel.Count]);
  end;
end;

procedure TFrameHistory.ActionError(Sender: TObject; ACode: integer;
  const AMessage, AAction: utf8string);
begin
  { Ошибка getChatHistory/sendMessage/viewMessages — без этого сбой
    RPC был бы совсем незаметен: пустой список и тишина. }
  if lblStatus <> nil then begin
    lblStatus.Caption := Format('Error %d: %s', [ACode, string(AMessage)]);
  end;
end;

procedure TFrameHistory.UsersChanged(Sender: TObject);
begin
  { Дорезолвилось (или обновилось) чьё-то имя — высота блоков от этого
    не меняется, полная FScroller.ModelChanged (пересчёт офсетов) не
    нужна, только перерисовать. }
  if FReady and (FScroller <> nil) then begin
    FScroller.Invalidate;
  end;
end;

procedure TFrameHistory.MaybeLoadMore;
begin
  if (FModel = nil) or FModel.LoadingOlder or FModel.OldestLoaded then begin
    Exit;
  end;
  { Загруженной истории не хватает даже на один экран — подгружаем
    ещё, иначе пользователь увидит короткий обрубок списка без
    возможности проскроллить и без triggerа "около верха". }
  if FScroller.TotalHeight < FScroller.ClientHeight then begin
    FModel.LoadOlder;
  end;
end;

procedure TFrameHistory.ScrollerNearTop(Sender: TObject);
begin
  if (FModel = nil) or FModel.LoadingOlder or FModel.OldestLoaded then begin
    Exit;
  end;
  FModel.LoadOlder;
end;

procedure TFrameHistory.ScrollerRangeChanged(Sender: TObject);
var
  Max: integer;
begin
  { Классическая Win32-семантика SCROLLINFO: Max — верх диапазона
    прокрутки целиком (как TotalHeight), PageSize вычитается из него
    самим контролом при вычислении крайней позиции ползунка — так же,
    как у нативного скролла в любом другом приложении. }
  Max := FScroller.TotalHeight;
  if Max < FScroller.ClientHeight then begin
    Max := FScroller.ClientHeight;
  end;
  FScrollbar.SetParams(FScroller.ScrollTop, 0, Max, FScroller.ClientHeight);
end;

procedure TFrameHistory.ScrollbarScroll(Sender: TObject; ScrollCode: TScrollCode;
  var ScrollPos: integer);
begin
  FScroller.ScrollTop := ScrollPos;
end;

procedure TFrameHistory.Resize;
begin
  inherited Resize;
  if not FReady then begin
    Exit;
  end;
  MaybeLoadMore;
end;

procedure TFrameHistory.DoActivate;
begin
  inherited DoActivate;
  { Первый настоящий показ — Parent и Visible навигатор уже
    выставил, здесь Canvas-операции внутри BindModel безопасны. }
  if FModel = nil then begin
    BindModel;
  end;
end;

end.
