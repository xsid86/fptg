unit framehistory;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, Math, DateUtils, LCLType, LCLIntf,
  Controls, Forms, Graphics, Clipbrd, fgl, StdCtrls, ExtCtrls,
  BGRABitmap, BGRABitmapTypes, avatarcache,
  tdauth, tdcore, tdchats, tdmessages, tdusers, tdaccentcolors, msglayout,
  uiframe, framechats;

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
  { Ключ — id пользователя или чата-источника репоста (см. поле у
    TMsgScroller, где заведены два разных инстанса этого типа). }
  TForwardAvatarMap = specialize TFPGMap<Int64, TBGRABitmap>;

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
    { id сообщения на каждой позиции FOffsets — снимок ТОГО ЖЕ момента,
      что и сам FOffsets (заполняется в том же цикле RebuildOffsets).
      Нужен ModelChanged: к моменту его вызова FModel уже отражает
      НОВОЕ состояние (TTdMessages.Rebuild отработал до FOnChanged), а
      FOffsets — ещё СТАРОЕ. Если якорь верхней видимой строки читать
      через FModel[индекс из старых FOffsets], после LoadOlder (который
      добавляет сообщения В НАЧАЛО, сдвигая индексы всех остальных)
      получится id случайного другого сообщения — отсюда и "вставляются
      вразнобой". FRowIds всегда того же винтажа, что и FOffsets,
      поэтому такого смешения нет. }
    FRowIds:  array of Int64;
    FTotalHeight: integer;
    FScrollTop:   integer;

    FSelAnchorMsg, FSelFocusMsg:   Int64;
    FSelAnchorChar, FSelFocusChar: integer;
    FSelecting: boolean;

    FAudioPool:   TFPList;   { of TAudioWidget, все когда-либо созданные }
    FAudioActive: TAudioMap; { сейчас позиционированные, по id сообщения }

    { Аватарки источников репоста — маленькие (диаметр HEADER_H),
      свой кэш, а не avatarcache.TAvatarCache: тот заточен под
      AVATAR_SIZE=44 и TChatRow (список чатов), здесь же нужны и чаты
      (mfoChat/mfoChannel — по ForwardChatId), и пользователи (mfoUser —
      по ForwardUserId, для которых в проекте вообще нет скачанных фото,
      только TChatRow их имеет). Раздельные карты — id пользователя и
      id чата не одно и то же пространство, а совпадение по значению
      возможно. Ключ — Id источника; значение освобождается в Destroy. }
    FForwardChatAvatars: TForwardAvatarMap;
    FForwardUserAvatars: TForwardAvatarMap;

    FOnScrollRangeChanged: TNotifyEvent;
    FOnNearTop: TNotifyEvent;

    procedure RebuildOffsets;
    { Левая/правая граница центрированной колонки сообщений — не шире
      MAX_MSG_W. Один источник правды для RebuildOffsets (ширина
      переноса текста), BlockRect и ContentRect — иначе разъедутся при
      малейшей правке одного из них. }
    procedure ColumnBounds(out ALeft, ARight: integer);
    { Единый расчёт для строки с репостом — сколько места до и после
      контента занимает цитата (шапка+паддинги источника, БЕЗ высоты
      самого контента) и какая ширина остаётся контенту внутри неё.
      ARow=nil или не репост — APreH/APostH такие же, как и без цитаты
      (см. реализацию), AInnerW=AAvailW без изменений. Источник истины
      и для RebuildOffsets (высота строки), и для ContentRect/
      ForwardCardRect/ForwardHeaderRect (где рисовать) — как ColumnBounds. }
    procedure ForwardMetrics(ARow: TMsgRow; AColW: integer;
      out APreH, APostH, AInnerW: integer);
    { Рамка цитаты целиком (для заливки/обводки) и её собственная строка
      "аватар+имя+время" (для отрисовки и хит-теста клика по имени). }
    function ForwardCardRect(AIndex: integer): TRect;
    function ForwardHeaderRect(AIndex: integer): TRect;
    { Высота плашки цитаты ответа (reply_to) + отступ до того, что
      после неё — 0, если у сообщения нет reply_to. Складывается с
      PreH из ForwardMetrics (ортогональные свойства, см. реализацию). }
    function ReplyExtraH(ARow: TMsgRow): integer;
    function ReplyBoxRect(AIndex: integer): TRect;
    procedure PaintReplyBox(AIndex: integer; ARow: TMsgRow);
    { AOwned=True — вызывающий обязан сам освободить результат (снимок
      "пока не скачано", не кэшируется, см. реализацию); False —
      результат в кэше, освобождать нельзя. }
    function ForwardAvatarBmp(ARow: TMsgRow; out AOwned: boolean): TBGRABitmap;
    procedure ClearForwardAvatars;
    procedure PaintForwardCard(AIndex: integer; ARow: TMsgRow);
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
    { Клик по источнику цитаты репоста (только mfoChannel — см. вызов) —
      не строим шэрабельную ссылку (getMessageLink требует членства в
      чате, для чужого источника обычно не наш случай), а переходим,
      как в официальном клиенте: открываем чат-источник и
      прокручиваем к сообщению. }
    procedure OpenForwardSource(ARow: TMsgRow);
    { Прокрутить и показать конкретное сообщение — вызывается из
      TFrameHistory в ответ на TTdMessages.OnJumpReady, когда нужная
      пачка истории уже применена и FOffsets/FRowIds её видят. }
    procedure ScrollToMessage(AMessageId: Int64);
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
    { Тот же принцип, что у FUsers — один на аккаунт, лёгкая привязка,
      без офсетов. }
    FAccentColors: TTdAccentColors;
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
    { Нужная вокруг AMessageId пачка истории применена (TTdMessages.
      JumpTo/JumpDone) — переход по цитате репоста: прокрутить к ней. }
    procedure JumpReady(Sender: TObject; AMessageId: Int64);
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

    { AJumpToMessageId <> 0 — переход по цитате репоста, см.
      TTdMessages.OpenChat/JumpTo. }
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0);

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
  MSG_PAD_H      = 11;
  MSG_PAD_V      = 6;
  MSG_GAP        = 16;
  { Колонка сообщений не шире этого — при широком окне не растягиваем
    текст во всю ширину (нечитаемо), а центрируем узкую колонку.
    0 — без ограничения, во всю ширину фрейма (см. ColumnBounds). }
  MAX_MSG_W      = 600;
  { HEADER_H — высота самого значка/текста заголовка (для центрирования
    внутри неё). HEADER_PAD_V — свой отступ сверху/снизу внутри цветной
    подложки заголовка, НЕ завязан на MSG_GAP (расстояние между
    сообщениями) — это два разных с виду похожих отступа, которые
    раньше были одним числом по случайности, не по смыслу.
    HEADER_BAR_H — сколько места заголовок реально занимает в блоке. }
  HEADER_H       = 16;
  HEADER_PAD_V   = 6;
  HEADER_BAR_H   = HEADER_H + 2 * HEADER_PAD_V;
  NEAR_TOP_PX    = 400;
  WHEEL_LINE_PX  = 60;
  LINE_SCROLL_PX = 24;
  { Радиус скругления углов у подложки блока/заголовка сообщения. }
  MSG_CORNER_RADIUS = 16;
  { Слот под значок статуса в заголовке блока — зарезервирован даже у
    входящих сообщений (там значка нет, crNone), чтобы имя отправителя
    не "прыгало" по горизонтали от строки к строке. }
  MSG_ICON_W     = 16;
  MSG_ICON_GAP   = 4;

  { Цитата репоста (сообщение, пришедшее с forward_info) — своя рамка
    внутри блока: свой, меньший радиус и свой отступ от основного
    заголовка сообщения. Остальные отступы внутри цитаты переиспользуют
    MSG_PAD_H/MSG_PAD_V/HEADER_BAR_H — цитата структурно то же самое
    "заголовок+контент", что и весь блок, только вложенная и поменьше,
    заводить для неё второй набор паддингов не за чем.
    FORWARD_HEADER_GAP = MSG_PAD_H, не отдельное число — по месту
    пользователя: горизонтальный (MSG_PAD_H) и вертикальный (этот зазор)
    отступы цитаты должны визуально совпадать, и должны продолжать
    совпадать, если MSG_PAD_H ещё раз подправят на глаз. }
  FORWARD_CORNER_RADIUS = 8;
  FORWARD_HEADER_GAP    = MSG_PAD_H;

  { Цитата ответа (reply_to) — компактная плашка над содержимым
    сообщения: значок цитаты + имя цитируемого отправителя + первая
    строка его текста, подложка и контур тем же приёмом, что и у
    карточки репоста (не как у цитаты репоста, FORWARD_*, при этом —
    там TDLib сам присылает отдельный объект с контекстом источника,
    здесь же это просто ссылка на СВОЁ ЖЕ сообщение выше по переписке,
    ближе по духу к тому, как reply рисует оригинальный клиент
    Telegram). Отступ значка от левого края плашки и от значка до
    текста — MSG_PAD_H/MSG_ICON_GAP, отступ сверху — HEADER_PAD_V: те
    же константы и по тому же месту, что и у иконки в основном
    заголовке блока (HeaderX := BR.Left + MSG_PAD_H, HeaderY := BR.Top
    + HEADER_PAD_V, см. Paint) и у аватара в заголовке цитаты репоста
    (AvX/AvY в PaintForwardCard) — по месту пользователя: 4px "на
    глаз" смотрелись хуже, чем повтор уже устоявшегося отступа
    заголовков. Высота — фиксированные два текстовых ряда, без
    word-wrap: имя и текст обрезаются по ширине с "…", не переносятся. }
  REPLY_LINE_H  = 15;
  REPLY_BOX_H   = 2 * REPLY_LINE_H + 2 * HEADER_PAD_V;

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
  { Контур блока — цвет отправителя поверх фона, заметно сильнее заливок
    выше (0.5): не тонировка, а именно очерчивающая рамка блока. }
  SENDER_BORDER_OPACITY = 0.5;

{ Цвет по кругу, детерминированно по id — общий резолвер для отправителя
  сообщения (SenderColor), источника репоста (ForwardSourceColor) и
  цитируемого в reply_to (ReplySenderColor): три структурно одинаковых
  случая "раскрасить кого-то по id", вынесены в одно место. Ровно один
  из AUserId/AChatId должен быть ненулевым (как и везде в проекте —
  отправитель это либо пользователь, либо чат, не оба разом); оба
  нулевые (напр. mfoHiddenUser) — берём Id=1, лишь бы не всегда одна и
  та же ячейка палитры. AChatId у каналов/супергрупп бывает
  отрицательным (см. tdlib_raw.log) — Abs, чтобы не уйти за границу
  массива. }
function ResolveAccentColor(AUserId, AChatId: Int64): TColor;
var
  Id: Int64;
  AccId: integer;
  C: TChatRow;
  L: TTdChats;
  AC: TTdAccentColors;
begin
  { У Telegram уже есть свой закреплённый за контактом/чатом цвет
    (accent_color_id, из updateUser/updateChatAccentColors — см.
    tdaccentcolors.pas) — используем его вместо хэша по id, когда он
    известен. Хэш по SENDER_PALETTE остаётся запасным вариантом: пока
    accent_color_id ещё не резолвился (первая прорисовка нового
    отправителя) или для совсем неожиданного случая, когда ни один
    источник его не даёт. }
  AccId := -1;
  if AUserId <> 0 then begin
    if TdUserList <> nil then begin
      AccId := TdUserList.AccentColorId(AUserId);
    end;
  end else if AChatId <> 0 then begin
    L := TdChatList;
    if L <> nil then begin
      C := L.Lookup(AChatId);
      if C <> nil then begin
        AccId := C.AccentColorId;
      end;
    end;
  end;

  if AccId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(AccId, Result) then begin
      Exit;
    end;
  end;

  if AUserId <> 0 then begin
    Id := AUserId;
  end else begin
    Id := AChatId;
  end;
  if Id = 0 then begin
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

function SenderColor(ARow: TMsgRow): TColor;
begin
  Result := ResolveAccentColor(ARow.SenderUserId, ARow.SenderChatId);
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

{ Имя по id — общий резолвер, тем же приёмом, что и ResolveAccentColor
  (отправитель сообщения / источник репоста / цитируемый в reply_to).
  AChatId (анонимный админ/пост от имени канала) резолвится через уже
  загруженный список чатов, не через TTdUsers — это не пользователь. }
function ResolveDisplayName(AUserId, AChatId: Int64): utf8string;
var
  C: TChatRow;
  U: TTdUsers;
  L: TTdChats;
begin
  Result := '';
  if AUserId <> 0 then begin
    U := TdUserList;
    if U <> nil then begin
      Result := U.DisplayName(AUserId);
    end;
  end else if AChatId <> 0 then begin
    L := TdChatList;
    C := nil;
    if L <> nil then begin
      C := L.Lookup(AChatId);
    end;
    if C <> nil then begin
      Result := C.Title;
    end else begin
      Result := 'Channel';
    end;
  end;
end;

function SenderDisplayName(ARow: TMsgRow): utf8string;
begin
  Result := ResolveDisplayName(ARow.SenderUserId, ARow.SenderChatId);
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

{ Отображаемое имя источника репоста. mfoChannel/mfoChat резолвятся
  через уже загруженный список чатов (ForwardChatId) — тот же приём,
  что и SenderDisplayName для анонимных постов от чата. mfoUser — через
  кэш пользователей. mfoHiddenUser — TDLib присылает готовое имя и
  больше ничего (отправитель сам скрыл, откуда переслано). }
function ForwardSourceName(ARow: TMsgRow): utf8string;
var
  C: TChatRow;
  L: TTdChats;
  U: TTdUsers;
begin
  Result := '';
  case ARow.ForwardKind of
    mfoUser: begin
      U := TdUserList;
      if U <> nil then begin
        Result := U.DisplayName(ARow.ForwardUserId);
      end;
    end;
    mfoChat, mfoChannel: begin
      L := TdChatList;
      C := nil;
      if L <> nil then begin
        C := L.Lookup(ARow.ForwardChatId);
      end;
      if C <> nil then begin
        Result := C.Title;
      end else if ARow.ForwardSenderName <> '' then begin
        Result := ARow.ForwardSenderName;
      end else begin
        Result := 'Channel';
      end;
    end;
    mfoHiddenUser: begin
      Result := ARow.ForwardSenderName;
    end;
  end;
  if Result = '' then begin
    Result := 'Unknown';
  end;
end;

{ Цвет источника репоста — тот же приём, что и SenderColor (настоящий
  accent_color_id, хэш по SENDER_PALETTE запасным вариантом), но по
  ForwardUserId/ForwardChatId, а не по отправителю самого сообщения:
  это два разных, независимо раскрашенных участка одного блока — кто
  прислал репост (внешний заголовок) и откуда он изначально (цитата). }
function ForwardSourceColor(ARow: TMsgRow): TColor;
var
  Id: Int64;
  AccId: integer;
  C: TChatRow;
  L: TTdChats;
  AC: TTdAccentColors;
begin
  AccId := -1;
  Id := 0;
  case ARow.ForwardKind of
    mfoUser: begin
      Id := ARow.ForwardUserId;
      if TdUserList <> nil then begin
        AccId := TdUserList.AccentColorId(Id);
      end;
    end;
    mfoChat, mfoChannel: begin
      Id := ARow.ForwardChatId;
      L := TdChatList;
      if L <> nil then begin
        C := L.Lookup(Id);
        if C <> nil then begin
          AccId := C.AccentColorId;
        end;
      end;
    end;
  end;

  if AccId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(AccId, Result) then begin
      Exit;
    end;
  end;

  if Id = 0 then begin
    { mfoHiddenUser (и любой другой случай без числового id) — стабильный,
      но произвольный запасной цвет: важно не 0, иначе всегда одна и та
      же ячейка палитры для всех подряд. }
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
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
  FForwardChatAvatars := TForwardAvatarMap.Create;
  FForwardChatAvatars.Sorted := True;
  FForwardUserAvatars := TForwardAvatarMap.Create;
  FForwardUserAvatars.Sorted := True;
  SetLength(FOffsets, 1);
  FOffsets[0] := 0;
end;

destructor TMsgScroller.Destroy;
begin
  FAudioActive.Free;
  { Сами виджеты не освобождаем: они дочерние control'ы Self,
    их уничтожит LCL вместе с родителем. }
  FAudioPool.Free;
  ClearForwardAvatars;
  FForwardChatAvatars.Free;
  FForwardUserAvatars.Free;
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
  I, H, Cnt, ColL, ColR, PreH, PostH, InnerW: integer;
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
    SetLength(FRowIds, 0);
    FOffsets[0] := 0;
    FTotalHeight := 0;
    Exit;
  end;

  Cnt := 0;
  if FModel <> nil then begin
    Cnt := FModel.Count;
  end;

  ColumnBounds(ColL, ColR);
  Ctx.Canvas := Canvas;

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -13;
  Canvas.Font.Style := [];

  SetLength(FOffsets, Cnt + 1);
  SetLength(FRowIds, Cnt);
  FOffsets[0] := 0;
  for I := 0 to Cnt - 1 do begin
    FRowIds[I] := FModel[I].Id;
    ForwardMetrics(FModel[I], ColR - ColL, PreH, PostH, InnerW);
    { Цитата ответа (reply_to) рисуется ВЫШЕ цитаты репоста/контента —
      её высота добавляется к PreH отдельно, а не внутри ForwardMetrics
      (это два независимых, ортогональных свойства сообщения: реплай и
      репост технически могут встретиться на одном сообщении разом). }
    PreH := PreH + ReplyExtraH(FModel[I]);
    Ctx.AvailWidth := InnerW;
    H := HEADER_BAR_H + PreH + RendererFor(FModel[I].Kind).Measure(FModel[I], Ctx) + PostH;
    FOffsets[I + 1] := FOffsets[I] + H + MSG_GAP;
  end;

  FTotalHeight := FOffsets[Cnt];
end;

{ Метрики цитаты репоста — единый источник для RebuildOffsets (высота
  строки) и ContentRect/ForwardCardRect/ForwardHeaderRect (где рисовать),
  тем же приёмом, что ColumnBounds. AColW — ШИРИНА КОЛОНКИ целиком
  (ColR-ColL, ДО вычитания чьих-либо паддингов) — у цитаты свой,
  цитата структурно нарочно то же самое "заголовок+контент", что и весь
  блок, вложенное — переиспользует ровно те же MSG_PAD_H/MSG_PAD_V, что
  и обычный (не вложенный) блок, чтобы отступы контента от рамки цитаты
  визуально совпадали с отступами обычного сообщения от рамки блока.
  FORWARD_HEADER_GAP — единственное по-настоящему отдельное число,
  и только для одного места: зазор МЕЖДУ основным заголовком блока и
  рамкой цитаты (см. FORWARD_HEADER_GAP выше). Не репост — APreH/APostH/
  AInnerW как у обычного блока. }
procedure TMsgScroller.ForwardMetrics(ARow: TMsgRow; AColW: integer;
  out APreH, APostH, AInnerW: integer);
begin
  if (ARow = nil) or (ARow.ForwardKind = mfoNone) then begin
    APreH := MSG_PAD_V;
    APostH := MSG_PAD_V;
    AInnerW := AColW - 2 * MSG_PAD_H;
    if AInnerW < 20 then begin
      AInnerW := 20;
    end;
    Exit;
  end;
  { До контента: зазор от основного заголовка (FORWARD_HEADER_GAP) +
    мини-заголовок цитаты (HEADER_BAR_H) + её собственный отступ до
    контента — тот же MSG_PAD_V, что и у обычного блока. После контента
    — собственный нижний отступ цитаты (MSG_PAD_V, симметричен верхнему
    внутри самой цитаты) + отступ ОТ рамки цитаты до края основного
    блока — тот же FORWARD_HEADER_GAP, что и сверху (симметрия с
    зазором "заголовок блока → цитата", а не обычный MSG_PAD_V: цитата
    — не обычный контент, а вложенный элемент со своим отступом от
    родителя с обеих сторон). }
  APreH := FORWARD_HEADER_GAP + HEADER_BAR_H + MSG_PAD_V;
  APostH := MSG_PAD_V + FORWARD_HEADER_GAP;
  { Ширина контента: рамка цитаты отстоит от краёв блока на MSG_PAD_H
    (как обычный контент от блока), содержимое внутри рамки — ещё на
    такой же MSG_PAD_H от неё. }
  AInnerW := AColW - 4 * MSG_PAD_H;
  if AInnerW < 20 then begin
    AInnerW := 20;
  end;
end;

procedure TMsgScroller.ColumnBounds(out ALeft, ARight: integer);
var
  W: integer;
begin
  { MAX_MSG_W = 0 — колонка во всю ширину фрейма, без ограничения. }
  W := ClientWidth;
  if (MAX_MSG_W > 0) and (W > MAX_MSG_W) then begin
    W := MAX_MSG_W;
  end;
  ALeft := (ClientWidth - W) div 2;
  ARight := ALeft + W;
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
var
  ColL, ColR: integer;
begin
  ColumnBounds(ColL, ColR);
  Result := Rect(ColL, FOffsets[AIndex] - FScrollTop, ColR,
    FOffsets[AIndex] - FScrollTop + (FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP));
end;

function TMsgScroller.ContentRect(AIndex: integer): TRect;
var
  BlockH, ContentH, TopY, ColL, ColR, PreH, PostH, InnerW: integer;
  R: TMsgRow;
begin
  ColumnBounds(ColL, ColR);
  R := FModel[AIndex];
  ForwardMetrics(R, ColR - ColL, PreH, PostH, InnerW);
  PreH := PreH + ReplyExtraH(R);
  BlockH := FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP;
  ContentH := BlockH - HEADER_BAR_H - PreH - PostH;
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + PreH;
  if (R <> nil) and (R.ForwardKind <> mfoNone) then begin
    { Контент цитаты — внутри рамки ForwardCardRect, у которой уже свой
      MSG_PAD_H от краёв блока (как у обычного контента); ещё один такой
      же MSG_PAD_H — собственный отступ содержимого ОТ этой рамки (см.
      ForwardMetrics) — тот же по величине отступ, что у контента
      обычного сообщения от его блока, не отдельное число. }
    Result := Rect(ColL + 2 * MSG_PAD_H, TopY,
      ColR - 2 * MSG_PAD_H, TopY + ContentH);
    Exit;
  end;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + ContentH);
end;

{ Рамка цитаты целиком (заливка/обводка) — от конца основного заголовка
  плюс FORWARD_HEADER_GAP (единственный отступ, специфичный для цитаты),
  до нижнего внутреннего отступа цитаты после ContentRect (см.
  ForwardMetrics: APostH = 2*MSG_PAD_V, первый MSG_PAD_V — как раз этот
  нижний отступ). Горизонтально — тот же MSG_PAD_H, что и у обычного
  (не вложенного) контента от блока — см. комментарий у ForwardMetrics.
  Не репост — пустой Rect, вызывающий обязан сам проверить ForwardKind
  перед вызовом. }
function TMsgScroller.ForwardCardRect(AIndex: integer): TRect;
var
  ColL, ColR: integer;
  CR: TRect;
begin
  ColumnBounds(ColL, ColR);
  CR := ContentRect(AIndex);
  { ReplyExtraH — если у сообщения ЕЩЁ и есть цитата ответа (reply_to),
    она рисуется первой, а карточка репоста сдвигается ниже её. }
  Result := Rect(ColL + MSG_PAD_H,
    FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + ReplyExtraH(FModel[AIndex]) + FORWARD_HEADER_GAP,
    ColR - MSG_PAD_H, CR.Bottom + MSG_PAD_V);
end;

{ Строка "аватар+имя+время" внутри цитаты — верхняя полоса ForwardCardRect,
  высотой HEADER_BAR_H (та же величина, что и у основного заголовка блока —
  цитата структурно то же самое "заголовок+контент", см. ForwardMetrics). }
function TMsgScroller.ForwardHeaderRect(AIndex: integer): TRect;
var
  Card: TRect;
begin
  Card := ForwardCardRect(AIndex);
  Result := Rect(Card.Left, Card.Top, Card.Right, Card.Top + HEADER_BAR_H);
end;

{ FORWARD_HEADER_GAP — зазор ОТ ОСНОВНОГО ЗАГОЛОВКА до плашки цитаты
  ответа, тот же самый (не просто равный по значению), что и у карточки
  репоста, по месту пользователя: "цитата от верхнего края основного
  сообщения так же должна отстоять на 11 пикселей, как и пересланное
  сообщение" — переиспользуем именно эту константу, а не заводим
  REPLY_TOP_GAP с тем же числом, чтобы они не могли разъехаться при
  следующей правке. "REPLY_BOX_H" ниже — уже сама плашка; отступ ПОСЛЕ
  неё (до карточки репоста, если есть, либо до контента) — обычный
  MSG_PAD_V, как и у всего остального в ForwardMetrics, см. вызовы
  ReplyExtraH в RebuildOffsets/ContentRect/ForwardCardRect: везде это
  прибавляется К ГОЛОВЕ уже готового PreH из ForwardMetrics (который
  сам начинается с MSG_PAD_V для обычного контента или с
  FORWARD_HEADER_GAP для карточки репоста) — то есть "отступ после
  плашки" тут получается автоматически, из уже существующего PreH, а
  не отдельным слагаемым здесь. }
function TMsgScroller.ReplyExtraH(ARow: TMsgRow): integer;
begin
  if (ARow = nil) or (ARow.ReplyMessageId = 0) then begin
    Result := 0;
  end else begin
    Result := FORWARD_HEADER_GAP + REPLY_BOX_H;
  end;
end;

{ Плашка цитаты ответа — сразу под основным заголовком блока, на том же
  отступе (FORWARD_HEADER_GAP), что и карточка репоста от него. Если у
  сообщения ЕЩЁ и репост — карточка репоста и контент сдвинуты ниже
  неё, см. ReplyExtraH в ForwardCardRect/ContentRect/RebuildOffsets. }
function TMsgScroller.ReplyBoxRect(AIndex: integer): TRect;
var
  ColL, ColR, TopY: integer;
begin
  ColumnBounds(ColL, ColR);
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + FORWARD_HEADER_GAP;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + REPLY_BOX_H);
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
  OldMax, OldCount: integer;
  AnchorId: Int64;
  AnchorIdx, AnchorOldOffset, AnchorNewOffset: integer;
begin
  OldCount := Length(FRowIds);
  OldMax := FTotalHeight - ClientHeight;
  { "Была внизу" — только когда реально существовала прокручиваемая
    область и мы были у её конца. OldMax<=0 (весь список помещался на
    экране) раньше ЛЮБОЙ такой случай засчитывал как "внизу" — из-за
    этого короткий, ещё догружаемый чат (MaybeLoadMore подгружает
    историю сам, пока контента не хватает на экран) на каждую подгрузку
    прыгал к низу, забивая попытку пользователя проскроллить вверх ДО
    того, как список вырастет больше экрана. Для OldCount=0 (самое
    первое открытие чата) низ всё равно нужен явно — якорить не к чему. }
  WasAtBottom := (OldCount > 0) and (OldMax > 0) and (FScrollTop >= OldMax - 4);

  { Запоминаем сообщение в верхней видимой строке — после подгрузки
    истории (LoadOlder добавляет контент ВЫШЕ) вернём его на то же
    место в окне, иначе список визуально прыгнет.

    ВАЖНО: id берём из FRowIds, СВОЕГО снимка того же винтажа, что и
    FOffsets/AnchorIdx — НЕ из FModel[AnchorIdx]. К моменту вызова
    ModelChanged модель (TTdMessages) уже перестроена (Rebuild отработал
    до FOnChanged), а FOffsets/FRowIds — ещё старые. LoadOlder вставляет
    новые сообщения В НАЧАЛО списка, сдвигая индексы всех остальных;
    FModel[тот же индекс] после такой вставки — уже СОВСЕМ ДРУГОЕ
    сообщение. Отсюда и "вставляются вразнобой" при подгрузке во время
    скролла вверх — старый индекс молча читался из уже сдвинутых данных. }
  AnchorId := 0;
  AnchorOldOffset := 0;
  AnchorIdx := IndexAtY(FScrollTop);
  if (AnchorIdx >= 0) and (AnchorIdx < Length(FRowIds)) then begin
    AnchorId := FRowIds[AnchorIdx];
    AnchorOldOffset := FScrollTop - FOffsets[AnchorIdx];
  end;

  RebuildOffsets;

  if (OldCount = 0) or WasAtBottom then begin
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

procedure TMsgScroller.ClearForwardAvatars;
var
  I: integer;
begin
  for I := 0 to FForwardChatAvatars.Count - 1 do begin
    FForwardChatAvatars.Data[I].Free;
  end;
  FForwardChatAvatars.Clear;
  for I := 0 to FForwardUserAvatars.Count - 1 do begin
    FForwardUserAvatars.Data[I].Free;
  end;
  FForwardUserAvatars.Clear;
end;

{ Аватарка источника репоста. AOwned=False (обычный случай) — результат
  в FForwardChatAvatars/FForwardUserAvatars, вызывающий НЕ освобождает.
  AOwned=True — снимок "фото ещё не скачано" (см. ниже), вызывающий
  обязан освободить сам. nil — строить не из чего вовсе (mfoHiddenUser,
  нет числового id — см. вызов в PaintForwardCard, там свой запасной
  вариант без кэша). Источник данных — TChatRow (mfoChat/mfoChannel, по
  ForwardChatId через TdChatList) или ничего, кроме имени (mfoUser — в
  проекте пока нет скачанных фото произвольных пользователей,
  tdusers.pas хранит только имя/цвет, см. ARCHITECTURE.md). }
function TMsgScroller.ForwardAvatarBmp(ARow: TMsgRow; out AOwned: boolean): TBGRABitmap;
var
  Idx: integer;
  Id: Int64;
  Map: TForwardAvatarMap;
  C: TChatRow;
  L: TTdChats;
  SrcName: utf8string;
begin
  Result := nil;
  AOwned := False;
  if ARow = nil then begin
    Exit;
  end;

  case ARow.ForwardKind of
    mfoUser: begin
      Map := FForwardUserAvatars;
      Id := ARow.ForwardUserId;
    end;
    mfoChat, mfoChannel: begin
      Map := FForwardChatAvatars;
      Id := ARow.ForwardChatId;
    end;
  else
    Exit;   { mfoNone/mfoHiddenUser — нет стабильного id, см. комментарий выше }
  end;
  if Id = 0 then begin
    Exit;
  end;

  Idx := Map.IndexOf(Id);
  if Idx >= 0 then begin
    Result := Map.Data[Idx];
    Exit;
  end;

  SrcName := ForwardSourceName(ARow);
  if ARow.ForwardKind in [mfoChat, mfoChannel] then begin
    C := nil;
    L := TdChatList;
    if L <> nil then begin
      C := L.Lookup(Id);
    end;
    if C <> nil then begin
      { Список чатов сам скачивает настоящее фото только для строк,
        реально видимых в TDrawGrid (framechats.pas:757,
        TTdChats.EnsureAvatar) — источник репоста туда обычно не входит
        (это ЧУЖОЙ канал/группа, необязательно наш, в списке чатов).
        Без явного запроса здесь PhotoPath остался бы пустым навсегда, и
        рисовалось бы только Minithumb — заведомо мелкое, размытое
        превью (Telegram сам генерирует его таким, "заглушка на время
        загрузки", не полноценная миниатюра — вот и вся причина
        "размытости" из жалобы). }
      L.EnsureAvatar(C);
      Result := RenderAvatarBmp(C.PhotoPath, C.Minithumb, SrcName, Id, HEADER_H, True);
      if C.PhotoPath = '' then begin
        { Настоящее фото ещё не скачано — НЕ кэшируем: со следующей
          перерисовкой (скролл, новое сообщение, что угодно) попробуем
          снова, и как только EnsureAvatar докачает файл, подхватим уже
          настоящую картинку вместо Minithumb. Результат при этом уже
          не принадлежит кэшу — вызывающий обязан его освободить сам
          (иначе утечка: RenderAvatarBmp создаёт новый TBGRABitmap на
          каждый такой вызов). Не идеально (decode Minithumb на каждый
          Paint, пока файл не готов), но дёшево и временно — реальных
          цитат на экране одновременно немного. }
        AOwned := True;
        Exit;
      end;
    end else begin
      Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
    end;
  end else begin
    { mfoUser — для произвольных пользователей в проекте вообще нет
      механизма скачивания фото (см. TODO.md), апгрейда не будет —
      кэшировать инициалы насовсем можно спокойно. }
    Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
  end;
  if Result <> nil then begin
    Map.Add(Id, Result);
  end;
end;

{ Цитата репоста — рамка (заливка тем же приёмом, что и подложка
  внешнего блока, SENDER_BG_OPACITY) и внутри неё своя строка
  "аватар+имя+время" с СОБСТВЕННОЙ подложкой (SENDER_HEADER_OPACITY,
  скруглены только верхние углы — тот же приём "нарисовать всё
  скруглённым и спрямить низ FillRect'ом", что и у основного заголовка
  блока, см. Paint) — оба цвета источника, не отправителя. Обводка
  рамки рисуется отдельно, в Paint, ПОСЛЕ содержимого цитаты — тем же
  порядком, что и у внешнего блока (контур поверх всего). Имя — ссылка
  (курсор меняется на руку в MouseMove) только для mfoChannel: только
  там TDLib вообще даёт message_id исходного поста, без которого
  getMessageLink нечего резолвить (см. TMsgForwardKind в tdmessages.pas
  — приватность остальных случаев запрещает строить ссылку). }
procedure TMsgScroller.PaintForwardCard(AIndex: integer; ARow: TMsgRow);
var
  CardRect, HeaderRect: TRect;
  Clr: TColor;
  Radius, HeaderRadius, AvX, AvY, NameX: integer;
  AvBmp: TBGRABitmap;
  FreeAvBmp: boolean;
  TimeStr, S: string;
  LocalDT: TDateTime;
begin
  CardRect := ForwardCardRect(AIndex);
  HeaderRect := ForwardHeaderRect(AIndex);
  Clr := ForwardSourceColor(ARow);
  Radius := Min(FORWARD_CORNER_RADIUS, (CardRect.Bottom - CardRect.Top) div 2);

  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow);
  Canvas.RoundRect(CardRect, Radius, Radius);

  HeaderRadius := Min(FORWARD_CORNER_RADIUS, HEADER_BAR_H div 2);
  Canvas.Brush.Color := BlendWithBackground(Clr, SENDER_HEADER_OPACITY, clWindow);
  Canvas.RoundRect(HeaderRect, HeaderRadius, HeaderRadius);
  Canvas.FillRect(Rect(HeaderRect.Left, HeaderRect.Bottom - HeaderRadius,
    HeaderRect.Right, HeaderRect.Bottom));

  AvBmp := ForwardAvatarBmp(ARow, FreeAvBmp);
  if AvBmp = nil then begin
    { mfoHiddenUser (или ещё не резолвившийся id) — рендерим на месте,
      без кэша: это только инициалы, decode файла/превью тут не бывает
      (см. ForwardAvatarBmp), так что дёшево даже каждую перерисовку. }
    AvBmp := RenderAvatarBmp('', '', ForwardSourceName(ARow), 0, HEADER_H, True);
    FreeAvBmp := True;
  end;
  { Тот же горизонтальный отступ, что и у внешнего заголовка
    (HeaderX := BR.Left + MSG_PAD_H, см. Paint) — и та же вертикальная
    центровка (HEADER_PAD_V). }
  AvX := HeaderRect.Left + MSG_PAD_H;
  AvY := HeaderRect.Top + HEADER_PAD_V;
  if AvBmp <> nil then begin
    AvBmp.Draw(Canvas, AvX, AvY, False);
    if FreeAvBmp then begin
      AvBmp.Free;
    end;
  end;

  { Имя+время — ОДНОЙ строкой в цвете источника, тем же приёмом, что и
    у внешнего заголовка (там тоже единый TextOut на "Имя (HH:MM)",
    цветом отправителя целиком — время не отдельным серым суффиксом). }
  NameX := AvX + HEADER_H + MSG_ICON_GAP;
  LocalDT := UniversalTimeToLocal(UnixToDateTime(ARow.ForwardDate));
  if SameDate(LocalDT, Date) then begin
    TimeStr := FormatDateTime('hh:nn', LocalDT);
  end else begin
    TimeStr := FormatDateTime('hh:nn dd.mm.yy', LocalDT);
  end;
  S := string(ForwardSourceName(ARow)) + ' (' + TimeStr + ')';

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := Clr;
  Canvas.Brush.Style := bsClear;
  Canvas.TextOut(NameX, HeaderRect.Top + HEADER_PAD_V, S);
end;

{ Цитата ответа (reply_to) — компактная плашка: значок цитаты + имя
  цитируемого отправителя (жирным, цветом) + первая строка его текста
  (серым) — подложка/контур/скругление тем же приёмом, что и у карточки
  репоста (см. константы REPLY_*), но без аватара — источник тут не
  внешний объект, а просто своё же более раннее сообщение, значок
  вместо фото. Данные — FModel.ReplyPreview: если ещё не разрешены
  (сообщение ещё грузится через getRepliedMessage), рисуем временную
  серую заглушку — перерисуется сама, как только придут (см.
  TTdMessages.GetRepliedDone → Touch → полный ModelChanged, не просто
  Invalidate: высота плашки не меняется, но текст появляется). }
procedure TMsgScroller.PaintReplyBox(AIndex: integer; ARow: TMsgRow);
var
  Box: TRect;
  SenderUserId, SenderChatId: Int64;
  PreviewText: utf8string;
  Have: boolean;
  Clr: TColor;
  NameStr, SnippetStr: string;
  TextX, MaxW, NlPos, Radius, IconX, IconY: integer;
  IconList: TImageList;

  function Truncate(const S: string; AMaxW: integer): string;
  var
    Lo, Hi, Mid: integer;
  begin
    Result := S;
    if Canvas.TextWidth(Result) <= AMaxW then begin
      Exit;
    end;
    Lo := 0;
    Hi := Length(S);
    while Lo < Hi do begin
      Mid := (Lo + Hi + 1) div 2;
      if Canvas.TextWidth(Copy(S, 1, Mid) + '…') <= AMaxW then begin
        Lo := Mid;
      end else begin
        Hi := Mid - 1;
      end;
    end;
    if Lo <= 0 then begin
      Result := '…';
    end else begin
      Result := Copy(S, 1, Lo) + '…';
    end;
  end;

begin
  Box := ReplyBoxRect(AIndex);
  Have := (FModel <> nil) and FModel.ReplyPreview(ARow.ReplyChatId, ARow.ReplyMessageId,
    SenderUserId, SenderChatId, PreviewText);

  if Have then begin
    Clr := ResolveAccentColor(SenderUserId, SenderChatId);
    NameStr := string(ResolveDisplayName(SenderUserId, SenderChatId));
    SnippetStr := string(PreviewText);
    NlPos := Pos(#10, SnippetStr);
    if NlPos > 0 then begin
      { Только первая строка — многострочный текст сжимаем в одну,
        как и оригинальный клиент. }
      SnippetStr := Copy(SnippetStr, 1, NlPos - 1);
    end;
  end else begin
    Clr := clGrayText;
    NameStr := '';
    SnippetStr := 'Loading…';
  end;

  { Подложка — тем же приёмом, что и у карточки репоста (SENDER_BG_
    OPACITY, скруглённые углы с той же защитой от "капсулы", см.
    PaintForwardCard). }
  Radius := Min(FORWARD_CORNER_RADIUS, (Box.Bottom - Box.Top) div 2);
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow);
  Canvas.RoundRect(Box, Radius, Radius);

  { Значок цитаты — из того же ImageList1, что и значки статуса
    сообщения/аватар источника репоста (FormMain.Chats.ImageList1, см.
    комментарий в Paint про общий список с одной сквозной нумерацией). }
  IconX := Box.Left + MSG_PAD_H;
  IconY := Box.Top + HEADER_PAD_V;
  IconList := nil;
  if (FormMain <> nil) and (FormMain.Chats <> nil) then begin
    IconList := FormMain.Chats.ImageList1;
  end;
  if (IconList <> nil) and (ICON_QUOTE >= 0) and (ICON_QUOTE < IconList.Count) then begin
    IconList.Draw(Canvas, IconX, IconY, ICON_QUOTE, True);
  end;

  TextX := Box.Left + MSG_PAD_H + MSG_ICON_W + MSG_ICON_GAP;
  MaxW := Box.Right - MSG_ICON_GAP - TextX;
  if MaxW >= 10 then begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Name := 'default';
    Canvas.Font.Height := -11;

    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := Clr;
    Canvas.TextOut(TextX, Box.Top + HEADER_PAD_V, Truncate(NameStr, MaxW));

    Canvas.Font.Style := [];
    Canvas.Font.Color := clGrayText;
    Canvas.TextOut(TextX, Box.Top + HEADER_PAD_V + REPLY_LINE_H, Truncate(SnippetStr, MaxW));
  end;

  { Контур — последним, поверх содержимого, тем же приёмом, что и у
    карточки репоста (SENDER_BORDER_OPACITY, тот же Radius). }
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Width := 1;
  Canvas.Pen.Color := BlendWithBackground(Clr, SENDER_BORDER_OPACITY, clWindow);
  Canvas.RoundRect(Box, Radius, Radius);
end;

procedure TMsgScroller.Paint;
var
  I, Lo, Hi: integer;
  R: TMsgRow;
  BR, CR, HeaderRect, FwdBR: TRect;
  S: string;
  SelStart, SelEnd, LowIdx, HighIdx, LowChar, HighChar: integer;
  HasSel: boolean;
  ChatRow: TChatRow;
  LastReadOutbox: Int64;
  IconList: TImageList;
  HeaderX, HeaderY, IconIdx, HeaderRadius, FwdRadius: integer;
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
        текст и разделительная линия легли поверх, не под. Скруглённые
        углы — RoundRect рисует и заливкой (Brush), и обводкой (Pen);
        обводка не нужна вовсе, иначе кисть предыдущей строки
        (разделительная линия, ниже по циклу) проступила бы рамкой. }
      Canvas.Brush.Style := bsSolid;
      Canvas.Pen.Style := psClear;
      Canvas.Brush.Color := BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY, clWindow);
      Canvas.RoundRect(BR, MSG_CORNER_RADIUS, MSG_CORNER_RADIUS);

      { Подложка самой строки заголовка (значок+имя) — заметнее фона
        блока (SENDER_HEADER_OPACITY > SENDER_BG_OPACITY), поверх уже
        закрашенного фона блока. Отступ значка/текста от верхнего и
        нижнего края этой полосы — свой, HEADER_PAD_V, не MSG_GAP
        (HeaderY, а не BR.Top напрямую). Скруглены только ВЕРХНИЕ углы —
        те же, что у блока снаружи; нижние скруглённые превращали бы
        короткую полосу в подобие таблетки, отдельной от блока под ней.
        RoundRect умеет только все 4 угла разом, per-corner в чистом
        TCanvas нет — рисуем со всеми скруглёнными, затем перекрываем
        низ обычным прямоугольником того же цвета, "спрямляя" его.
        Радиус для этой полосы — свой, HeaderRadius, не MSG_CORNER_RADIUS
        напрямую: полоса всего HEADER_BAR_H пикселей высотой, и если
        радиус блока больше её половины, RoundRect вместо скруглённых
        углов рисует растянутую "таблетку" (оба конца — полукруги,
        сходящиеся у середины) — источник и "овального" вида, и
        артефактов на стыке с FillRect ниже (тот исходит из
        предположения, что дуга не выходит за свои MSG_CORNER_RADIUS
        нижних пикселей, что при слишком большом радиусе неверно). }
      HeaderRect := Rect(BR.Left, BR.Top, BR.Right, BR.Top + HEADER_BAR_H);
      HeaderRadius := Min(MSG_CORNER_RADIUS, HEADER_BAR_H div 2);
      Canvas.Brush.Color := BlendWithBackground(SenderColor(R), SENDER_HEADER_OPACITY, clWindow);
      Canvas.RoundRect(HeaderRect, HeaderRadius, HeaderRadius);
      Canvas.FillRect(Rect(HeaderRect.Left, HeaderRect.Bottom - HeaderRadius,
        HeaderRect.Right, HeaderRect.Bottom));
      HeaderY := BR.Top + HEADER_PAD_V;

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

      if R.ReplyMessageId <> 0 then begin
        PaintReplyBox(I, R);
      end;

      if R.ForwardKind <> mfoNone then begin
        PaintForwardCard(I, R);
      end;

      Canvas.Font.Height := -13;
      if HasSel and (I >= LowIdx) and (I <= HighIdx) then begin
        RangeForRow(I, LowIdx, HighIdx, LowChar, HighChar, Length(R.PlainText), SelStart, SelEnd);
      end else begin
        SelStart := -1;
        SelEnd := -1;
      end;

      RendererFor(R.Kind).Paint(R, Canvas, CR, SelStart, SelEnd);

      if R.ForwardKind <> mfoNone then begin
        { Контур цитаты — тем же порядком, что и у внешнего блока ниже:
          после содержимого, поверх него. }
        FwdBR := ForwardCardRect(I);
        FwdRadius := Min(FORWARD_CORNER_RADIUS, (FwdBR.Bottom - FwdBR.Top) div 2);
        Canvas.Brush.Style := bsClear;
        Canvas.Pen.Style := psSolid;
        Canvas.Pen.Width := 1;
        Canvas.Pen.Color := BlendWithBackground(ForwardSourceColor(R), SENDER_BORDER_OPACITY, clWindow);
        Canvas.RoundRect(FwdBR, FwdRadius, FwdRadius);
      end;

      { Контур блока — рисуется последним, поверх содержимого: только
        обводка (Brush.Style := bsClear), сам текст на MSG_PAD_H от края
        и краем не задевается. }
      Canvas.Brush.Style := bsClear;
      Canvas.Pen.Style := psSolid;
      Canvas.Pen.Width := 1;
      Canvas.Pen.Color := BlendWithBackground(SenderColor(R), SENDER_BORDER_OPACITY, clWindow);
      Canvas.RoundRect(BR, MSG_CORNER_RADIUS, MSG_CORNER_RADIUS);
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

procedure TMsgScroller.OpenForwardSource(ARow: TMsgRow);
var
  F: TFrameHistory;
begin
  if (ARow = nil) or (ARow.ForwardChatId = 0) or (ARow.ForwardMessageId = 0) then begin
    Exit;
  end;
  if (FormMain = nil) or (FormMain.Nav = nil) then begin
    Exit;
  end;
  { TFrameHistory — синглтон навигатора (TFrameNavigator.ShowFrame сам
    решает создавать или переиспользовать), так что если источник —
    ТЕКУЩИЙ открытый чат, это буквально вызов метода у самого Self же
    владельца, просто через новую точку входа TFrameHistory.OpenChat. }
  F := TFrameHistory(FormMain.Nav.ShowFrame(TFrameHistory));
  if F <> nil then begin
    F.OpenChat(ARow.ForwardChatId, ARow.ForwardMessageId);
  end;
end;

procedure TMsgScroller.ScrollToMessage(AMessageId: Int64);
var
  Idx, RowH: integer;
begin
  if (FModel = nil) or (Length(FOffsets) < 2) then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(AMessageId);
  if Idx < 0 then begin
    { Не должно случаться после синхронного Rebuild в TTdMessages.
      JumpDone, но на всякий случай — просто не скроллим, не падаем. }
    Exit;
  end;
  RowH := FOffsets[Idx + 1] - FOffsets[Idx];
  { Центрируем сообщение в видимой области, а не прижимаем к верху —
    так виднее и то, что было до, и то, что после. }
  ClampScrollTop(FOffsets[Idx] - (ClientHeight - RowH) div 2);
  Invalidate;
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

  R := FModel[Idx];
  { Клик по плашке цитаты ответа — прыжок к цитируемому сообщению В ТОМ
    ЖЕ чате (ReplyPreview/JumpTo поддерживают только этот случай, см.
    комментарий у TTdMessages.ReplyPreview) — тем же приёмом, что тап
    по цитате в оригинальном клиенте. }
  if (R.ReplyMessageId <> 0) and (FModel <> nil) and (R.ReplyChatId = FModel.ChatId)
    and PtInRect(ReplyBoxRect(Idx), Point(X, Y)) then begin
    FModel.JumpTo(R.ReplyMessageId);
    Exit;
  end;

  { Имя источника в цитате репоста — ссылка только у mfoChannel (только
    там TDLib знает message_id исходного поста, см. TMsgForwardKind).
    Кликабельна вся строка "аватар+имя+время", не только текст имени —
    для такой маленькой строки точный хит-тест по ширине текста не
    стоит лишнего кода. }
  if (R.ForwardKind = mfoChannel) and PtInRect(ForwardHeaderRect(Idx), Point(X, Y)) then begin
    OpenForwardSource(R);
    Exit;
  end;

  if Hit.Kind = mhkLink then begin
    DoLinkClick(Hit.URL);
    Exit;
  end;

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
  if (Idx >= 0) and (FModel[Idx].ForwardKind = mfoChannel)
    and PtInRect(ForwardHeaderRect(Idx), Point(X, Y)) then begin
    Want := crHandPoint;
  end else if (Idx >= 0) and (FModel[Idx].ReplyMessageId <> 0)
    and (FModel[Idx].ReplyChatId = FModel.ChatId)
    and PtInRect(ReplyBoxRect(Idx), Point(X, Y)) then begin
    Want := crHandPoint;
  end else if Hit.Kind = mhkLink then begin
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

  { Кэш имён и кэш акцентных цветов — не смотрим на nil-раннюю Exit
    ниже: привязываются независимо от того, есть ли уже открытый чат. }
  FUsers := TdUserList;
  if FUsers <> nil then begin
    FUsers.OnChanged := @UsersChanged;
  end;
  FAccentColors := TdAccentColorList;
  if FAccentColors <> nil then begin
    FAccentColors.OnChanged := @UsersChanged;
  end;

  if FModel = nil then begin
    Exit;
  end;
  FModel.OnChanged := @ModelChanged;
  FModel.OnLoadingChanged := @LoadingChanged;
  FModel.OnActionError := @ActionError;
  FModel.OnJumpReady := @JumpReady;
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
    if TMethod(FModel.OnJumpReady).Data = Pointer(Self) then begin
      FModel.OnJumpReady := nil;
    end;
    FModel := nil;
  end;
  if FUsers <> nil then begin
    if TMethod(FUsers.OnChanged).Data = Pointer(Self) then begin
      FUsers.OnChanged := nil;
    end;
    FUsers := nil;
  end;
  if FAccentColors <> nil then begin
    if TMethod(FAccentColors.OnChanged).Data = Pointer(Self) then begin
      FAccentColors.OnChanged := nil;
    end;
    FAccentColors := nil;
  end;
  FScroller.BindModel(nil);
end;

procedure TFrameHistory.OpenChat(AChatId: Int64; AJumpToMessageId: Int64);
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
    FModel.OpenChat(AChatId, AJumpToMessageId);
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
  if lblStatus = nil then begin
    Exit;
  end;
  if AAction = 'jump' then begin
    { getChatHistory вокруг сообщения (переход по цитате репоста) не
      удался — обычно потому, что само сообщение с тех пор удалено в
      чате-источнике, а не баг: chat_id/message_id идут как есть из
      forward_info.origin, без ручных преобразований (см.
      TMsgForwardKind в tdmessages.pas). }
    lblStatus.Caption := 'Не удалось перейти к сообщению — возможно, оно удалено';
    Exit;
  end;
  lblStatus.Caption := Format('Error %d: %s', [ACode, string(AMessage)]);
end;

procedure TFrameHistory.JumpReady(Sender: TObject; AMessageId: Int64);
begin
  if FReady and (FScroller <> nil) then begin
    FScroller.ScrollToMessage(AMessageId);
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
