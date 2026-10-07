unit webapi;

{$mode objfpc}{$H+}

{ The bridge between the loopback socket (localserver.pas) and the
  model. Commands arrive as JSON text frames, answers and events go
  back the same way.

  THE ONE RULE THIS UNIT EXISTS TO ENFORCE: the model is single
  threaded and lives on the main thread behind its own coalescing
  timers. A socket thread must never touch it. So SocketMessage (which
  runs on the socket thread) does nothing but copy the text into a
  queue, and the main thread drains that queue and does the actual
  work. TThread.Queue wakes it immediately; a 200 ms timer is kept
  only as a safety net.

  WHAT GOES OVER THE WIRE IS THIS PROJECT'S OWN VIEW MODEL, NOT TDLib.
  It would be less code today to forward TDLib's JSON straight to the
  page, and it would be a mistake: the paging anchor, the contiguity of
  FAll, the download queue and its rate limit, the dedup rules — all of
  that was expensive to get right and it lives in tdmessages/tdchats.
  Proxying TDLib would mean writing it a second time in JavaScript.

  THE WEB UI AND THE NATIVE WINDOW SHARE ONE MODEL. TdMsgList and
  TdChatList are the same instances the frames use, deliberately: that
  is the end state (the native UI is to be reduced to a tray icon), and
  in the meantime it is what makes side-by-side comparison meaningful —
  both windows show the same chat, from the same rows, and any
  difference is a difference in rendering rather than in data. The
  visible consequence while both exist: opening a chat in the browser
  switches the native window to it too.

  Protocol, all of it JSON objects (spelled out in words rather than
  in braces: a literal brace inside a brace comment opens a nested one
  and the compiler counts levels at you — see tdmessages.pas, which
  learned the same lesson):
    client -> server   id, cmd, and optional args
    server -> client   id, ok true, result        — an answer
    server -> client   id, ok false, error        — a refusal
    server -> client   event and data             — unsolicited

  Events are SIGNALS, not payloads: "the chat list changed", "the open
  chat's messages changed". The page then asks for what it wants, and
  throttles itself. That is on purpose — a model change fires for every
  download-progress tick, and pushing a full history on each of those
  would be pure waste when the page may not even be showing that part.

  On parsing: fpjson's \uXXXX handling is broken in two ways this
  project diagnosed the hard way (see tdrecv.PreDecodeUnicodeEscapes).
  In practice JSON.stringify emits non-ASCII as raw UTF-8 rather than
  as escapes, so it would not bite — but this unit now accepts message
  TEXT from the page, which is exactly the case the old comment here
  said would need the same hardening. It gets it: every incoming frame
  goes through the same decoder before GetJSON sees it. }

interface

procedure WebApiStart;
procedure WebApiStop;

implementation

uses
  Classes, SysUtils, SyncObjs, tdtimer, base64, fgl, fpjson, jsonparser,
  constants, tdreq, tdauth, tdchats, tdmessages,
  tdusers, tdstickers, tdcalls, tdcore, tdrecv, webauth, qrrender, localserver, webfiles,
  autodownload, customemoji, tdstorage, tdsupergroups, tdattachbots, servicetext, tdaccount;

type
  { A request whose answer is not here yet.

    Every command until now could be answered out of the model, which
    is on this thread and already holds everything. The context menu
    cannot: what may be done to a message (getMessageProperties) and
    which reactions the chat offers (getMessageAvailableReactions) are
    QUESTIONS FOR TELEGRAM, they go stale immediately, and caching them
    in the model would mean answering with yesterday's rights.

    So the id of the request is parked here and the answer is sent when
    TDLib replies. The slot index is what rides on the TDLib request's
    own Tag - the same trick, and the same reason (no closures in FPC
    3.2), as TTdMessages' send slots. }
  TDeferredReply = record
    Busy: boolean;
    ConnId: Int64;
    ReqId: integer;
    MessageId: Int64;
    { The first answer of a two-step query, held while the second is
      fetched. Owned here, freed when the slot is released. }
    Held: TJSONObject;
  end;

  TWebReq = class
  public
    ConnId:  Int64;
    Payload: utf8string;
  end;

  { What one connection was last told about each message: id -> hash
    of the JSON sent for it. }
  TIdHashMap = specialize TFPGMap<Int64, QWord>;
  { And one of those per connection, because two pages open at once are
    at two different places in the same history. }
  TConnSnapMap = specialize TFPGMap<Int64, TIdHashMap>;

  { Слушатель реестра аккаунтов для моста: смена активного и изменения
    списка (пришло имя, вход, выход). Отдельный объект, потому что
    подписка идёт по интерфейсу с GUID, а TWebApi — простой класс. }
  TWebActiveHook = class(TComponent, ITdActiveListener)
  public
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

  TWebApi = class
  private
    FTimer: TTdTimer;
    FActiveHook: TWebActiveHook;
    { Куда вернуться при отмене добавления аккаунта (accounts.cancel);
      -1 — не запоминали. }
    FAddReturn: integer;
    FLock:  SyncObjs.TCriticalSection;
    FQueue: TFPList;
    { The model objects this instance is currently subscribed to. They
      belong to the active account and are replaced when the account
      changes, so they are re-checked on every tick rather than bound
      once at start-up (at start-up there may be no account at all). }
    FBoundChats: TTdChats;
    FBoundMsgs:  TTdMessages;
    FBoundStickers: TTdStickers;
    { Статус аккаунта в группах и каналах — для кнопки вступления
      (messages.list -> join). Один обработчик, как у стикеров: больше
      OnChanged супергрупп никто не слушает. }
    FBoundGroups: TTdSupergroups;
    { Модель пользователей: докачанное фото и пришедшее имя отправителя
      доезжают до страницы перечитыванием сообщений (сводится таймером,
      как супергруппы). Раньше её единственный OnChanged держало нативное
      окно истории. }
    FBoundUsers: TTdUsers;
    { Звонки активного аккаунта: каждое изменение и каждый сигнальный
      пакет — событием странице (call, call.signal). }
    FBoundCalls: TTdCalls;
    FUsersDirty: boolean;
    { updateSupergroup на старте приходят пачкой — в событие страницы
      сводятся таймером, как стикеры. }
    FGroupsDirty: boolean;
    { Watches the sign-in flow. Owned here, alive for the life of the
      bridge: unlike the models it exists before any account does,
      because "there is no account yet" is one of the things the page
      has to be told. }
    FAuth: TWebAuth;
    FDeferred: array of TDeferredReply;
    { Set by the sticker model's own change event, drained on the next
      tick. Unlike chats and messages, this one fires per downloaded
      FILE - a set of a hundred stickers is a hundred notifications in
      a couple of seconds - and the page redraws a whole panel on each
      one. Coalescing to at most five a second is the difference
      between a panel that fills in and a panel that flickers. }
    FStickersDirty: boolean;
    { See TConnSnapMap. Entries are never explicitly removed - there is
      no "connection closed" signal to hang that on - so the map is
      capped instead; a page that loses its place is told the whole
      history again, which is the same thing that happens on its first
      request. }
    FSnaps: TConnSnapMap;
    { Имя инлайн-бота (в нижнем регистре) -> его id, см. CmdInlineQuery. }
    FInlineBots: TStringList;
    procedure Tick(Sender: TObject);
    procedure Drain;
    procedure EnsureBindings;
    procedure DropBindings;
    procedure UnbindStale;
    procedure ActiveSwitched;
    function  CmdMessageForward(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdMessageTranslate(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MessageTranslateDone(Sender: TObject; const AResp: TTdResponse);
    procedure TranslateEntitiesDone(Sender: TObject; const AResp: TTdResponse);
    procedure TranslateReply(ASlot: PtrInt; AFormatted: TJSONObject);
    function  CmdBotValidateOrder(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure BotValidateOrderDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotTmpPassword(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdMentionSearch(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MentionMembersDone(Sender: TObject; const AResp: TTdResponse);
    procedure MentionContactsDone(Sender: TObject; const AResp: TTdResponse);
    procedure MentionReply(ASlot: PtrInt; const AIds: array of Int64);
    function  CmdAccountsList: TJSONData;
    function  CmdAccountsSwitch(AArgs: TJSONObject): TJSONData;
    function  CmdAccountsAdd: TJSONData;
    function  CmdAccountsCancel: TJSONData;
    function  CmdAccountsLogout: TJSONData;
    procedure ChatsChanged(Sender: TObject);
    procedure ChatArrived(Sender: TObject; ARow: TChatRow;
      const APreview: utf8string);
    procedure MessagesChanged(Sender: TObject);
    procedure StickersChanged(Sender: TObject);
    procedure GroupsChanged(Sender: TObject);
    procedure UsersChanged(Sender: TObject);
    procedure CallChanged(Sender: TObject; ACallId: integer);
    procedure CallSignal(Sender: TObject; ACallId: integer; const AData: utf8string);
    procedure GroupCallChanged(Sender: TObject; AGroupCallId: integer);
    procedure GroupParticipantChanged(Sender: TObject; AGroupCallId: integer;
      AParticipant: TJSONObject);
    procedure ChatVideoChatChanged(Sender: TObject; AChatId: Int64;
      AGroupCallId: integer; AHasParticipants: boolean);
    function  CmdVchatInfo(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure VchatChatDone(Sender: TObject; const AResp: TTdResponse);
    procedure VchatGroupDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdVchatJoin(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure VchatJoinDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdVchatParticipants(AArgs: TJSONObject): TJSONData;
    function  CmdVchatSimple(const ACmd: utf8string; AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    procedure VchatCreateDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdCallStart(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure CallStartDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdCallSimple(const ACmd: utf8string; AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdCallList: TJSONData;
    procedure AuthChanged(Sender: TObject);
    procedure StorageChanged(Sender: TObject);
    function  TakeDeferred(AConnId: Int64; AReqId: integer;
      AMessageId: Int64): PtrInt;
    procedure ReleaseDeferred(ASlot: PtrInt);
    procedure MenuPropsDone(Sender: TObject; const AResp: TTdResponse);
    procedure MenuReactionsDone(Sender: TObject; const AResp: TTdResponse);
    procedure MessageLinkDone(Sender: TObject; const AResp: TTdResponse);
    procedure PeopleDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkExternal(ASlot: PtrInt);
    procedure LinkTypeDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkChatDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkInviteDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkInvitePhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkMessageDone(Sender: TObject; const AResp: TTdResponse);
    procedure LinkJoinDone(Sender: TObject; const AResp: TTdResponse);
    procedure BotCallbackDone(Sender: TObject; const AResp: TTdResponse);
    procedure BotInfoDone(Sender: TObject; const AResp: TTdResponse);
    procedure WebAppOpenDone(Sender: TObject; const AResp: TTdResponse);
    procedure SimpleDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdAccountGet(AConnId: Int64; AReqId: integer): boolean;
    function  CmdAccountSet(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdAccountCheckUsername(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdAccountPersonalChats(AConnId: Int64; AReqId: integer): boolean;
    function  AccountSlot(const AResp: TTdResponse; out ASlot: PtrInt): boolean;
    procedure AccountMeDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountFullDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountBioMaxDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountPhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountFinish(ASlot: PtrInt);
    procedure AccountUsernameDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountPersonalChatsDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdAccountPhotos(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure AccountPhotosDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountPhotosNext(ASlot: PtrInt);
    procedure AccountPhotoFileDone(Sender: TObject; const AResp: TTdResponse);
    procedure AccountPhotoStaleDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdMapThumb(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MapThumbDone(Sender: TObject; const AResp: TTdResponse);
    procedure MapThumbFileDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotLoginUrl(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure BotLoginInfoDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotLoginUrlConfirm(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure WebAppOpenUrlDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotBuy(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure BotBuyDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotPay(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure BotPayDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdBotSendLocation(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdBotSendPoll(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdBotCreateBot(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSendChecklist(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSendArticle(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdAttachBots: TJSONData;
    function  CmdContactsList(AConnId: Int64; AReqId: integer): boolean;
    procedure ContactsIdsDone(Sender: TObject; const AResp: TTdResponse);
    procedure ContactUserDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdChatGreeting(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure GreetingSticker(ASlot: PtrInt; ARes, ASticker: TJSONObject);
    procedure GreetingFinish(ASlot: PtrInt);
    procedure GreetingFullDone(Sender: TObject; const AResp: TTdResponse);
    procedure GreetingStickersDone(Sender: TObject; const AResp: TTdResponse);
    procedure GreetingFileDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdGreetingSend(AArgs: TJSONObject): TJSONData;
    function  CmdChatInfo(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure InfoStep(ASlot: PtrInt);
    function  InfoSlot(ASlot: PtrInt; out ARes: TJSONObject): boolean;
    procedure InfoUserDone(Sender: TObject; const AResp: TTdResponse);
    procedure InfoUserFullDone(Sender: TObject; const AResp: TTdResponse);
    procedure InfoGroupDone(Sender: TObject; const AResp: TTdResponse);
    procedure InfoGroupFullDone(Sender: TObject; const AResp: TTdResponse);
    procedure InfoCountDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdChatMembers(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MembersListDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdInfoAction(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdGiftsList(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure GiftsListDone(Sender: TObject; const AResp: TTdResponse);
    procedure GiftsNext(ASlot: PtrInt);
    procedure GiftFileDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdMediaList(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MediaListDone(Sender: TObject; const AResp: TTdResponse);
    procedure MediaFileDone(Sender: TObject; const AResp: TTdResponse);
    procedure MediaReplyIfDone(ASlot: PtrInt);
    procedure SharePhoneMeDone(Sender: TObject; const AResp: TTdResponse);
    procedure InlineBotDone(Sender: TObject; const AResp: TTdResponse);
    procedure InlineResultsDone(Sender: TObject; const AResp: TTdResponse);
    procedure InlineAsk(AMsgs: TTdMessages; ABot: Int64; ASlot: PtrInt);
    procedure PeoplePropsDone(Sender: TObject; const AResp: TTdResponse);
    procedure PushEvent(const AName: utf8string; AData: TJSONObject);
    procedure ReplyMessages(AConnId: Int64; AReqId: integer;
      AList: TJSONData; ADelta: boolean);
    function  SnapOf(AConnId: Int64): TIdHashMap;
    procedure NoteSent(AConnId: Int64; AList: TJSONData);
    function  ToDelta(AConnId: Int64; AFull: TJSONData): TJSONData;
    { NOT "Dispatch": TObject already has one (message dispatch), and
      a method of that name here hides it — the same family as
      TThread.Start, TControl.Text and TComponent.Name elsewhere in
      this project. }
    procedure RunCommand(AConnId: Int64; const AText: utf8string);
    procedure Reply(AConnId: Int64; AReqId: integer; AResult: TJSONData);
    procedure Fail(AConnId: Int64; AReqId: integer; const AError: utf8string);
    function  CmdChatsList(AArgs: TJSONObject): TJSONData;
    function  CmdChatsAvatars(AArgs: TJSONObject): TJSONData;
    function  CmdChatsMore(AArgs: TJSONObject): TJSONData;
    function  CmdChatOpen(AArgs: TJSONObject): TJSONData;
    function  CmdChatClose: TJSONData;
    function  CmdChatAction(AArgs: TJSONObject): TJSONData;
    function  CmdChatsFolders: TJSONData;
    function  CmdChatFolderSet(AArgs: TJSONObject): TJSONData;
    function  CmdChatFolderCreate(AArgs: TJSONObject): TJSONData;
    function  CmdMessagesList: TJSONData;
    function  CmdMessagesOlder: TJSONData;
    function  CmdMessagesTrim: TJSONData;
    function  CmdMessagesRead(AArgs: TJSONObject): TJSONData;
    function  CmdThreadOpen(AArgs: TJSONObject): TJSONData;
    function  CmdThreadJump(AArgs: TJSONObject): TJSONData;
    function  CmdThreadClose: TJSONData;
    function  CmdChatJoin(AArgs: TJSONObject): TJSONData;
    function  CmdPresenceGet: TJSONData;
    function  CmdPresenceSet(AArgs: TJSONObject): TJSONData;
    function  CmdSettingsGet: TJSONData;
    function  CmdSettingsSet(AArgs: TJSONObject): TJSONData;
    function  CmdStorageGet: TJSONData;
    function  CmdStorageCleanup: TJSONData;
    function  CmdMessageSend(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSendFiles(AArgs: TJSONObject): TJSONData;
    function  CmdCancelTransfer(AArgs: TJSONObject): TJSONData;
    function  CmdPollVote(AArgs: TJSONObject): TJSONData;
    function  CmdMediaEnsure(AArgs: TJSONObject): TJSONData;
    function  CmdSearchSet(AArgs: TJSONObject): TJSONData;
    function  CmdStickersList(AArgs: TJSONObject): TJSONData;
    function  CmdStickerSet(AArgs: TJSONObject): TJSONData;
    function  CmdGifsList(AArgs: TJSONObject): TJSONData;
    function  CmdGifEnsure(AArgs: TJSONObject): TJSONData;
    function  CmdAuthState: TJSONData;
    function  CmdAuthSubmit(const ACmd: utf8string; AArgs: TJSONObject): TJSONData;
    function  CmdApiConfig: TJSONData;
    function  CmdApiSave(AArgs: TJSONObject): TJSONData;
    function  CmdEmojiSets: TJSONData;
    function  CmdEmojiSet(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSendMedia(AArgs: TJSONObject): TJSONData;
    function  CmdMessageMenu(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdMessageLink(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdMessagePeople(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdLinkResolve(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdLinkJoin(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotCallback(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotInfo(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotUserChat(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdWebAppClose(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdWebAppCustom(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    procedure WebAppCustomDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdWebAppAllowWrite(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdWebAppSendData(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdWebAppOpen(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotShareUsers(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotShareChat(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdBotSharePhone(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdInlineQuery(AConnId: Int64; AReqId: integer;
      AArgs: TJSONObject): boolean;
    function  CmdInlineSend(AArgs: TJSONObject): TJSONData;
    procedure PeopleQuery(AMsgs: TTdMessages; AMessageId: Int64; ASlot: PtrInt);
    function  CmdMessageReact(AArgs: TJSONObject): TJSONData;
    function  CmdMessageDelete(AArgs: TJSONObject): TJSONData;
    function  CmdMessageEdit(AArgs: TJSONObject): TJSONData;
    function  CmdMessagePin(AArgs: TJSONObject): TJSONData;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(AConnId: Int64; const AText: utf8string);
  end;

var
  GApi: TWebApi = nil;

{ ------------------------------------------------------------------ }
{ view-model helpers                                                 }
{ ------------------------------------------------------------------ }

{ A key into the web UI's palette, NOT a colour.
    'a<id>' — Telegram's own accent id, 0..ACCENT_ID_MAX.
    'f<n>'  — the hashed fallback, for a subject with no accent id (or
              one past the range this build knows about), matching what
              framechats.ChatAccentColor falls back to.

  A key rather than '#rrggbb' because the page styles a chat by adding
  a class, never by writing an inline style: the set of accent colours
  is small and fixed, so it belongs in the stylesheet as a finite set
  of classes rather than being pushed into the DOM one element at a
  time. The stylesheet holds the matching hex values (and Telegram's
  separate dark-theme values, which a single colour sent from here
  could not express at all). }
function AccentKeyFor(AAccentColorId: integer; AHashId: Int64): utf8string;
begin
  if (AAccentColorId >= 0) and (AAccentColorId <= ACCENT_ID_MAX) then begin
    Result := 'a' + utf8string(IntToStr(AAccentColorId));
  end else begin
    Result := 'f' + utf8string(IntToStr(Abs(AHashId) mod Length(SENDER_PALETTE)));
  end;
end;

function AccentKey(ARow: TChatRow): utf8string;
begin
  Result := AccentKeyFor(ARow.AccentColorId, ARow.Id);
end;

{ The delivery state of the row's own last message, for the tick the
  card shows next to the time. '' for anything incoming or unsent -
  tdchats.ChatReceipt already answers crNone there, and the page skips
  the icon entirely rather than drawing a blank slot. }
function ReceiptStr(ARow: TChatRow): utf8string;
begin
  case ChatReceipt(ARow) of
    crPending: Result := 'pending';
    crFailed:  Result := 'failed';
    crSent:    Result := 'sent';
    crRead:    Result := 'read';
  else
    Result := '';
  end;
end;

function ChatKindStr(AChats: TTdChats; ARow: TChatRow): utf8string;
begin
  if AChats.IsSelfChat(ARow) then begin
    Exit('self');
  end;
  case ARow.Kind of
    ckPrivate:
      if AChats.IsBotChat(ARow) then begin
        Result := 'bot';
      end else begin
        Result := 'private';
      end;
    ckBasicGroup, ckSupergroup: Result := 'group';
    ckChannel:                  Result := 'channel';
    ckSecret:                   Result := 'secret';
  else
    Result := 'other';
  end;
end;

{ Registers a downloaded file and returns its URL, or '' when there is
  nothing on disk yet. Publishing happens here, while serialising, so
  the page can never be handed a URL for a file the HTTP side does not
  know how to resolve. }
{ id из аргументов команды — числом или строкой. Страница шлёт большие id
  строками (JSON-числа неточны после 2^53), а TJSONObject.Get с числовым
  умолчанием строку НЕ берёт — Find(AName, jtNumber) в fpjson.pp — и молча
  отдаёт умолчание: уходил user_id 0 и «User not found» (галерея аватарок
  из панели информации). }
function ArgId(AArgs: TJSONObject; const AName: string): Int64;
var
  D: TJSONData;
begin
  Result := 0;
  if AArgs = nil then begin
    Exit;
  end;
  D := AArgs.Find(AName);
  if D = nil then begin
    Exit;
  end;
  case D.JSONType of
    jtNumber: Result := D.AsInt64;
    jtString: Result := StrToInt64Def(Trim(D.AsString), 0);
  end;
end;

function FileUrl(AFileId: integer; const APath: utf8string): utf8string;
begin
  Result := WebFilePublish(AFileId, APath);
end;

function CustomEmojiFormatStr(AFormat: TCustomEmojiFormat): utf8string;
begin
  case AFormat of
    cmfTgs:  Result := 'tgs';
    cmfWebm: Result := 'webm';
  else
    Result := 'webp';
  end;
end;

{ Adds one custom emoji to the response's dictionary, unless it is
  already there.

  A dictionary per response rather than a URL on every occurrence: the
  same premium emoji turns up in half the previews of a list and in
  every second message of a chat, and the page only has to look an id
  up once. Keyed by the id AS TEXT, which is also how the entities
  carry it.

  An entry with an empty url is not a mistake and is still worth
  sending: it says "this id is a custom emoji whose file has not
  arrived yet", which is what lets the page keep showing the fallback
  character instead of a gap. }
procedure AddCustomEmoji(ADict: TJSONObject; AId: Int64);
var
  Key: string;
  O: TJSONObject;
begin
  if (ADict = nil) or (AId = 0) then begin
    Exit;
  end;
  Key := IntToStr(AId);
  if ADict.Find(Key) <> nil then begin
    Exit;
  end;
  O := TJSONObject.Create;
  O.Add('format', string(CustomEmojiFormatStr(CustomEmojiFormatFor(AId))));
  O.Add('url', string(FileUrl(CustomEmojiFileIdFor(AId),
    CustomEmojiLocalPathFor(AId))));
  ADict.Add(Key, O);
end;

{ Every custom emoji a message mentions - in its text and in its
  reactions. }
procedure CollectMsgCustomEmoji(ADict: TJSONObject; ARow: TMsgRow);
var
  I: integer;
begin
  for I := 0 to High(ARow.Entities) do begin
    AddCustomEmoji(ADict, ARow.Entities[I].CustomEmojiId);
  end;
  for I := 0 to High(ARow.Reactions) do begin
    AddCustomEmoji(ADict, ARow.Reactions[I].CustomEmojiId);
  end;
end;

{ ...and every one a chat row mentions - in its preview line and as the
  premium status beside its title. }
procedure CollectChatCustomEmoji(ADict: TJSONObject; ARow: TChatRow);
var
  I: integer;
begin
  for I := 0 to High(ARow.LastGlyphs) do begin
    AddCustomEmoji(ADict, ARow.LastGlyphs[I].CustomEmojiId);
  end;
  AddCustomEmoji(ADict, ARow.EmojiStatusCustomEmojiId);
end;

{ true/false для тела запроса TDLib. }
function BoolJson(AValue: boolean): utf8string;
begin
  if AValue then begin
    Result := 'true';
  end else begin
    Result := 'false';
  end;
end;

{ Короткое имя игры сообщения: messageGame.game.short_name (td_api.tl)
  — из сырого content строки; '' если это не игра или строки нет. }
function GameShortName(AMsgs: TTdMessages; AMsgId: Int64): utf8string;
var
  Idx: integer;
  Data: TJSONData;
begin
  Result := '';
  Idx := AMsgs.IndexOfId(AMsgId);
  if Idx < 0 then begin
    Exit;
  end;
  try
    Data := GetJSON(string(AMsgs.Rows[Idx].ContentRaw));
  except
    Exit;
  end;
  try
    if Data is TJSONObject then begin
      Result := JGetStr(JGetObj(TJSONObject(Data), 'game'), 'short_name');
    end;
  finally
    Data.Free;
  end;
end;

{ id кастомных эмодзи на кнопках разметки (icon_custom_emoji_id у
  keyboardButton / inlineKeyboardButton; 0 — нет). }
type
  TMarkupEmojiIds = array of Int64;

function MarkupEmojiIds(const ARaw: utf8string): TMarkupEmojiIds;
var
  Data: TJSONData;
  Rows, Row: TJSONArray;
  I, J, N: integer;
  Id: Int64;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    Rows := JGetArr(TJSONObject(Data), 'rows');
    if Rows = nil then begin
      Exit;
    end;
    N := 0;
    for I := 0 to Rows.Count - 1 do begin
      if not (Rows.Items[I] is TJSONArray) then begin
        Continue;
      end;
      Row := TJSONArray(Rows.Items[I]);
      for J := 0 to Row.Count - 1 do begin
        if not (Row.Items[J] is TJSONObject) then begin
          Continue;
        end;
        Id := JGetInt64(TJSONObject(Row.Items[J]), 'icon_custom_emoji_id');
        if Id <> 0 then begin
          SetLength(Result, N + 1);
          Result[N] := Id;
          Inc(N);
        end;
      end;
    end;
  finally
    Data.Free;
  end;
end;

{ Эмодзи кнопок разметки — в словарь ответа и, если ещё не знаем, в
  запрос getCustomEmojiStickers (как эмодзи текста). }
procedure CollectMarkupEmoji(AMsgs: TTdMessages; ADict: TJSONObject; const ARaw: utf8string);
var
  Ids: TMarkupEmojiIds;
  I: integer;
begin
  Ids := MarkupEmojiIds(ARaw);
  if Length(Ids) = 0 then begin
    Exit;
  end;
  AMsgs.EnsureCustomEmojiIds(Ids);
  for I := 0 to High(Ids) do begin
    AddCustomEmoji(ADict, Ids[I]);
  end;
end;

{ The custom-emoji spans of a chat's preview line, in the same shape as
  a message's entities: byte offsets into the string that was sent, so
  the page cuts both the same way. }
function GlyphsJson(const AGlyphs: TPreviewGlyphArray): TJSONArray;
var
  I: integer;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AGlyphs) do begin
    O := TJSONObject.Create;
    { -1 for the same reason EntitiesJson does it: ByteStart is a
      Pascal string index and counts from one. }
    O.Add('start', AGlyphs[I].ByteStart - 1);
    O.Add('len',   AGlyphs[I].ByteLen);
    O.Add('kind',  'customEmoji');
    O.Add('customEmojiId', string(IntToStr(AGlyphs[I].CustomEmojiId)));
    Result.Add(O);
  end;
end;

{ A tiny JPEG that arrives inside the message itself, with no download
  — the blurred placeholder. Sent inline as a data URI because that is
  what it is for: something to show in the same frame the message
  appears in, before any request could possibly come back. }
function ThumbDataUri(const ABytes: RawByteString): utf8string;
begin
  if ABytes = '' then begin
    Result := '';
  end else begin
    Result := 'data:image/jpeg;base64,' + utf8string(EncodeStringBase64(string(ABytes)));
  end;
end;

function RowToJson(AChats: TTdChats; ARow: TChatRow): TJSONObject;
var
  FolderId: integer;
  Folder: utf8string;
begin
  FolderId := AChats.RowFolderId(ARow);
  if FolderId = 0 then begin
    Folder := '';
  end else begin
    Folder := AChats.FolderTitle(FolderId);
  end;

  Result := TJSONObject.Create;
  { The utf8string -> string casts below are identity at run time: the
    program sets DefaultSystemCodePage to CP_UTF8 before anything else
    (FPTelegram.lpr), so both types carry the same code page and no transcoding
    happens. Worth knowing for any harness that links this unit without
    doing the same — it would quietly mangle every non-Latin title. }
  Result.Add('id',       ARow.Id);
  Result.Add('title',    string(ARow.Title));
  Result.Add('kind',     string(ChatKindStr(AChats, ARow)));
  Result.Add('color',    string(AccentKey(ARow)));
  Result.Add('preview',  string(ARow.LastText));
  { The custom-emoji spans inside that preview, and the premium status
    beside the title - ids only; what to draw for each one is in the
    response's customEmoji dictionary. }
  Result.Add('previewGlyphs', GlyphsJson(ARow.LastGlyphs));
  if ARow.EmojiStatusCustomEmojiId <> 0 then begin
    Result.Add('emojiStatus', string(IntToStr(ARow.EmojiStatusCustomEmojiId)));
  end else begin
    Result.Add('emojiStatus', '');
  end;
  Result.Add('date',     ARow.LastDate);
  Result.Add('unread',   ARow.UnreadCount);
  Result.Add('mentions', ARow.UnreadMentionCount);
  Result.Add('muted',    ARow.IsMuted);
  Result.Add('pinned',   ARow.IsPinned);
  Result.Add('archived', ARow.InArchive);
  Result.Add('outgoing', ARow.LastIsOutgoing);
  Result.Add('receipt',  string(ReceiptStr(ARow)));
  Result.Add('folder',   string(Folder));
  { The id alongside the title so the page's folder menu can mark
    the current entry without matching on a display string. 0 = the
    chat is in no folder, the same convention RowFolderId uses. }
  Result.Add('folderId', FolderId);
  Result.Add('premium',  AChats.IsPremiumUser(ARow));
  Result.Add('deleted',  AChats.IsDeletedUser(ARow));
  { Whether this account may write here at all — a channel it only
    reads says no, and the native window hides its composer for exactly
    this. }
  Result.Add('canSend',  ARow.CanSendBasicMessages);
  { The avatar, if it is already on disk. NOT requested here: chats.list
    serialises the WHOLE list, and asking for a hundred downloads
    because someone opened the app is precisely what the native window
    avoids by only calling EnsureAvatar for rows that are on screen.
    The page asks for the ones it can see, through chats.avatars.
    The minithumbnail rides along free — it arrives inside the chat
    object itself, with no download at all. }
  Result.Add('avatar',   string(FileUrl(ARow.PhotoFileId, ARow.PhotoPath)));
  Result.Add('avatarThumb', string(ThumbDataUri(ARow.Minithumb)));
  { Анимированная аватарка (MPEG4), когда она скачана; запрашивается
    вместе с обычной — chats.avatars и шапка открытого чата. }
  Result.Add('avatarAnim', string(FileUrl(ARow.AnimFileId, ARow.AnimPath)));
end;

{ ------------------------------------------------------------------ }
{ message view model                                                 }
{ ------------------------------------------------------------------ }

function ContentKindStr(AKind: TMsgContentKind): utf8string;
begin
  case AKind of
    mckText:      Result := 'text';
    mckAudio:     Result := 'audio';
    mckPhoto:     Result := 'photo';
    mckAnimation: Result := 'animation';
    mckSticker:   Result := 'sticker';
    mckVoiceNote: Result := 'voice';
    mckFile:      Result := 'file';
    mckVideo:     Result := 'video';
    mckPoll:      Result := 'poll';
  else
    Result := 'other';
  end;
end;

function EntityKindStr(AKind: TMsgEntityKind): utf8string;
begin
  case AKind of
    mekBold:          Result := 'bold';
    mekItalic:        Result := 'italic';
    mekUrl:           Result := 'url';
    mekTextUrl:       Result := 'textUrl';
    mekCode:          Result := 'code';
    mekPre:           Result := 'pre';
    mekStrikethrough: Result := 'strike';
    mekUnderline:     Result := 'underline';
    mekCustomEmoji:   Result := 'customEmoji';
    mekBlockQuote:    Result := 'quote';
    mekMention:       Result := 'mention';
    mekMentionName:   Result := 'mentionName';
  else
    Result := '';
  end;
end;

function ReceiptStr(AReceipt: TChatReceipt): utf8string;
begin
  case AReceipt of
    crPending: Result := 'pending';
    crFailed:  Result := 'failed';
    crSent:    Result := 'sent';
    crRead:    Result := 'read';
  else
    Result := 'none';
  end;
end;

function ForwardKindStr(AKind: TMsgForwardKind): utf8string;
begin
  case AKind of
    mfoUser:       Result := 'user';
    mfoChat:       Result := 'chat';
    mfoChannel:    Result := 'channel';
    mfoHiddenUser: Result := 'hidden';
  else
    Result := '';
  end;
end;

function StickerFormatStr(AFormat: TStickerFormat): utf8string;
begin
  case AFormat of
    sfTgs:  Result := 'tgs';
    sfWebm: Result := 'webm';
  else
    Result := 'webp';
  end;
end;

{ Name to show for a sender, given either a user id or a chat id — the
  same two sources framehistory.ResolveDisplayName consults, in the
  same order. A deliberate second implementation rather than a shared
  one: that method is private to a frame, and reaching into the LCL
  half of the program from here would undo the whole point of this
  unit being able to run without a window. }
procedure ResolveSubject(AUserId, AChatId: Int64;
  out AName: utf8string; out AColor: utf8string);
var
  Users: TTdUsers;
  Chats: TTdChats;
  CRow: TChatRow;
begin
  AName := '';
  AColor := AccentKeyFor(-1, AUserId + AChatId);
  if AUserId <> 0 then begin
    Users := TdUserList;
    if Users <> nil then begin
      AName := Users.DisplayName(AUserId);
      AColor := AccentKeyFor(Users.AccentColorId(AUserId), AUserId);
    end;
    Exit;
  end;
  if AChatId <> 0 then begin
    Chats := TdChatList;
    if Chats <> nil then begin
      CRow := Chats.Lookup(AChatId);
      if CRow <> nil then begin
        AName := CRow.Title;
        AColor := AccentKey(CRow);
      end;
    end;
  end;
end;

{ Аватарка отправителя сообщения (кружок в шапке): адрес фото, если оно
  уже на диске, иначе размытая minithumbnail и докачка — человека через
  модель пользователей (её OnChanged слушает мост и перечитывает
  сообщения), канала/группы через строку чата. }
procedure AddSenderAvatar(AObj: TJSONObject; AUserId, AChatId: Int64);
var
  Users: TTdUsers;
  U: TUserRow;
  Chats: TTdChats;
  Row: TChatRow;
  Url, Thumb: utf8string;
begin
  Url := '';
  Thumb := '';
  if AUserId <> 0 then begin
    Users := TdUserList;
    if Users <> nil then begin
      U := Users.Find(AUserId);
      if U <> nil then begin
        if U.PhotoPath <> '' then begin
          Url := FileUrl(U.PhotoFileId, U.PhotoPath);
        end else begin
          Users.EnsurePhoto(U);
          Thumb := ThumbDataUri(U.Minithumb);
        end;
      end;
    end;
  end else if AChatId <> 0 then begin
    Chats := TdChatList;
    if Chats <> nil then begin
      Row := Chats.Lookup(AChatId);
      if Row <> nil then begin
        if Row.PhotoPath <> '' then begin
          Url := FileUrl(Row.PhotoFileId, Row.PhotoPath);
        end else begin
          Chats.EnsureAvatar(Row);
          Thumb := ThumbDataUri(Row.Minithumb);
        end;
      end;
    end;
  end;
  AObj.Add('senderAvatar', string(Url));
  AObj.Add('senderThumb', string(Thumb));
end;

function EntitiesJson(const AEntities: TMsgEntityArray): TJSONArray;
var
  I: integer;
  O: TJSONObject;
  Kind: utf8string;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AEntities) do begin
    Kind := EntityKindStr(AEntities[I].Kind);
    if Kind = '' then begin
      Continue;
    end;
    O := TJSONObject.Create;
    { Byte offsets into the text. The page works on the same bytes: it
      decodes the text into a byte array once and slices it, rather
      than trusting JavaScript's UTF-16 string indexing, which would
      land every entity in the wrong place on any non-Latin text.

      The -1 is the whole point of this line, not a fudge: ByteStart is
      a Pascal string index, so it counts from ONE (see
      Utf16RangeToByteRange, which walks I := 1..N), and every native
      reader tests it that way. A JS typed array counts from zero.
      Without the shift every entity started one byte late and ran one
      byte past its end - the visible symptom being that the first
      character of a bold/underlined/quoted run stayed unformatted.
      Length needs no adjustment: it is a distance, not a position. }
    O.Add('start', AEntities[I].ByteStart - 1);
    O.Add('len',   AEntities[I].ByteLen);
    O.Add('kind',  string(Kind));
    if AEntities[I].URL <> '' then begin
      O.Add('url', string(AEntities[I].URL));
    end;
    if AEntities[I].Language <> '' then begin
      O.Add('language', string(AEntities[I].Language));
    end;
    if AEntities[I].UserId <> 0 then begin
      { Строкой, как id альбомов и эмодзи: страница передаёт его дальше
        как есть (ui:open-contact). }
      O.Add('userId', string(IntToStr(AEntities[I].UserId)));
    end;
    if AEntities[I].CustomEmojiId <> 0 then begin
      { A STRING, for the same reason album ids are one: a
        custom_emoji_id is a full 64-bit value (5127413407724601904 was
        in the log), and JSON numbers stop being exact at 2^53. The
        page only ever uses it as a key. }
      O.Add('customEmojiId', string(IntToStr(AEntities[I].CustomEmojiId)));
    end;
    Result.Add(O);
  end;
end;

function ReactionsJson(const AReactions: TMsgReactionArray): TJSONArray;
var
  I: integer;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AReactions) do begin
    O := TJSONObject.Create;
    case AReactions[I].Kind of
      rcEmoji: begin
        O.Add('kind', 'emoji');
        O.Add('emoji', string(AReactions[I].Emoji));
      end;
      rcCustomEmoji: begin
        O.Add('kind', 'custom');
        O.Add('customEmojiId', string(IntToStr(AReactions[I].CustomEmojiId)));
      end;
    else
      O.Add('kind', 'paid');
    end;
    O.Add('count',  AReactions[I].TotalCount);
    O.Add('chosen', AReactions[I].IsChosen);
    Result.Add(O);
  end;
end;

function PollJson(const APoll: TMsgPoll): TJSONObject;
var
  Arr: TJSONArray;
  O: TJSONObject;
  I: integer;
begin
  Arr := TJSONArray.Create;
  for I := 0 to High(APoll.Options) do begin
    O := TJSONObject.Create;
    O.Add('text',       string(APoll.Options[I].Text));
    O.Add('voters',     APoll.Options[I].VoterCount);
    O.Add('percentage', APoll.Options[I].VotePercentage);
    O.Add('chosen',     APoll.Options[I].IsChosen);
    O.Add('pending',    APoll.Options[I].IsBeingChosen);
    Arr.Add(O);
  end;

  Result := TJSONObject.Create;
  Result.Add('question',       string(APoll.Question));
  Result.Add('options',        Arr);
  Result.Add('totalVoters',    APoll.TotalVoters);
  Result.Add('closed',         APoll.IsClosed);
  Result.Add('anonymous',      APoll.IsAnonymous);
  Result.Add('multiple',       APoll.AllowsMultiple);
  Result.Add('revoting',       APoll.AllowsRevoting);
  Result.Add('quiz',           APoll.IsQuiz);
  Result.Add('correctOption',  APoll.CorrectOption);
end;

{ The kind-specific half of a message.

  Cheap, always-wanted files (a video's preview frame, a sticker, an
  album cover) are requested right here, unconditionally — exactly what
  the native window does in its layout pass, and for the same reason:
  they are tens of KB, and they are the placeholder the user is looking
  at while everything else loads. The expensive ones (the photo itself,
  the video, the track, a document) are NOT: the page asks for those
  with media.ensure when it decides to, which is the web equivalent of
  the native "first click downloads". }
{ Расшифровка голосового — voice_note.speech_recognition_result
  (td_api.tl коммита d1085f9): speechRecognitionResultPending
  (partial_text), ...Text (text), ...Error (error). Запускается
  recognizeSpeech (message.transcribe), результат приходит обновлением
  содержимого сообщения. null — не расшифровывали. }
function SpeechJson(const ARaw: utf8string): TJSONData;
var
  Data: TJSONData;
  R, Res: TJSONObject;
  T: utf8string;
begin
  Result := TJSONNull.Create;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    R := JGetObj(JGetObj(TJSONObject(Data), 'voice_note'), 'speech_recognition_result');
    if R = nil then begin
      Exit;
    end;
    T := JGetStr(R, '@type');
    Res := TJSONObject.Create;
    if T = 'speechRecognitionResultText' then begin
      Res.Add('state', 'text');
      Res.Add('text', string(JGetStr(R, 'text')));
    end else if T = 'speechRecognitionResultPending' then begin
      Res.Add('state', 'pending');
      Res.Add('text', string(JGetStr(R, 'partial_text')));
    end else begin
      Res.Add('state', 'error');
      Res.Add('text', string(JGetStr(JGetObj(R, 'error'), 'message')));
    end;
    Result.Free;
    Result := Res;
  finally
    Data.Free;
  end;
end;

function MediaJson(AMsgs: TTdMessages; ARow: TMsgRow): TJSONObject;
var
  Xfer: TJSONObject;
begin
  Result := nil;
  case ARow.Kind of
    mckPhoto: begin
      Result := TJSONObject.Create;
      Result.Add('w', ARow.PhotoWidth);
      Result.Add('h', ARow.PhotoHeight);
      Result.Add('thumb', string(ThumbDataUri(ARow.PhotoMinithumb)));
      Result.Add('url', string(FileUrl(ARow.PhotoFileId, ARow.PhotoLocalPath)));
      Result.Add('fullUrl', string(FileUrl(ARow.PhotoBestFileId, ARow.PhotoBestLocalPath)));
      Result.Add('fullW', ARow.PhotoBestWidth);
      Result.Add('fullH', ARow.PhotoBestHeight);
      Result.Add('got', ARow.PhotoDownloadedSize);
      Result.Add('total', ARow.PhotoTotalSize);
    end;
    mckVideo: begin
      AMsgs.EnsureVideoThumbFile(ARow);
      Result := TJSONObject.Create;
      Result.Add('w', ARow.VideoWidth);
      Result.Add('h', ARow.VideoHeight);
      { The preview box follows the THUMBNAIL's size, not the video's:
        the still shown in the list is only ever that big, and sizing
        the box to a 1080p source would just blur it on the way down.
        Same decision as framehistory.LayoutVideoWidgets. }
      Result.Add('thumbW', ARow.VideoThumbWidth);
      Result.Add('thumbH', ARow.VideoThumbHeight);
      Result.Add('duration', ARow.VideoDuration);
      Result.Add('thumbUrl',
        string(FileUrl(ARow.VideoThumbFileId, ARow.VideoThumbLocalPath)));
      Result.Add('url', string(FileUrl(ARow.VideoFileId, ARow.VideoLocalPath)));
      Result.Add('got', ARow.VideoDownloadedSize);
      Result.Add('total', ARow.VideoTotalSize);
    end;
    mckAnimation: begin
      Result := TJSONObject.Create;
      Result.Add('w', ARow.AnimWidth);
      Result.Add('h', ARow.AnimHeight);
      Result.Add('duration', ARow.AnimDuration);
      Result.Add('thumb', string(ThumbDataUri(ARow.AnimMinithumb)));
      Result.Add('url', string(FileUrl(ARow.AnimFileId, ARow.AnimLocalPath)));
      Result.Add('autoplay', ARow.AnimAutoPlay);
    end;
    mckAudio: begin
      AMsgs.EnsureAudioCoverFile(ARow);
      Result := TJSONObject.Create;
      Result.Add('title', string(ARow.AudioTitle));
      Result.Add('performer', string(ARow.AudioPerformer));
      Result.Add('fileName', string(ARow.AudioFileName));
      Result.Add('duration', ARow.AudioDuration);
      Result.Add('coverUrl',
        string(FileUrl(ARow.AudioCoverFileId, ARow.AudioCoverLocalPath)));
      Result.Add('url', string(FileUrl(ARow.AudioFileId, ARow.AudioLocalPath)));
    end;
    mckVoiceNote: begin
      Result := TJSONObject.Create;
      Result.Add('duration', ARow.VoiceDuration);
      Result.Add('url', string(FileUrl(ARow.VoiceFileId, ARow.VoiceLocalPath)));
      Result.Add('speech', SpeechJson(ARow.ContentRaw));
    end;
    mckFile: begin
      Result := TJSONObject.Create;
      Result.Add('fileName', string(ARow.DocFileName));
      Result.Add('size', ARow.DocFileSize);
      Result.Add('url', string(FileUrl(ARow.DocFileId, ARow.DocLocalPath)));
    end;
    mckSticker: begin
      AMsgs.EnsureStickerFile(ARow);
      Result := TJSONObject.Create;
      Result.Add('format', string(StickerFormatStr(ARow.StickerFormat)));
      Result.Add('w', ARow.StickerWidth);
      Result.Add('h', ARow.StickerHeight);
      Result.Add('url', string(FileUrl(ARow.StickerFileId, ARow.StickerLocalPath)));
    end;
  end;
  { Ход передачи основного файла — только пока она идёт: страница
    рисует по нему кольцо вокруг значка и «сколько из скольких». up —
    закачка (исходящее), иначе скачивание. }
  if (Result <> nil) and ARow.XferActive then begin
    Xfer := TJSONObject.Create;
    Xfer.Add('done', ARow.XferDone);
    Xfer.Add('total', ARow.XferTotal);
    Xfer.Add('up', ARow.XferUp);
    Result.Add('xfer', Xfer);
  end;
end;

{ The Auto download grid, applied to one row on its way to the page.

  The native window makes this decision in its layout pass
  (TMsgScroller.MaybeAutoDownload), once per row it draws. The page
  gets a whole screen of messages in a single response, so the same
  decision is made here, per row, as it is serialised: same grid, same
  media-to-setting mapping, same Ensure* calls. The two windows share
  one account and one model and must not disagree about what has been
  fetched — before this the page fetched NOTHING by itself, so every
  file needed a click even with auto-download on.

  Stickers are outside the gate entirely, exactly as they are there:
  the files are tiny and a sticker's whole point is an instant picture.
  That request already lives in MediaJson, unconditionally. }
procedure AutoFetch(AMsgs: TTdMessages; ARow: TMsgRow);
var
  MediaKind, ChatKind: string;
begin
  if (AMsgs = nil) or (ARow = nil) then begin
    Exit;
  end;

  case ARow.Kind of
    mckPhoto: MediaKind := 'images';
    { Voice notes share the Audio row of the grid with music: there is
      no separate category for them, and the native side reads it the
      same way. }
    mckAudio, mckVoiceNote: MediaKind := 'audio';
    mckFile: MediaKind := 'files';
    mckAnimation: MediaKind := 'gif';
    mckVideo: MediaKind := 'video';
  else
    Exit;
  end;

  ChatKind := AutoDownloadChatKind(AMsgs.ChatId);
  if (ChatKind = '') or not AutoDownloadEnabled(MediaKind, ChatKind) then begin
    Exit;
  end;

  case ARow.Kind of
    mckPhoto: begin
      { Both copies, as on the native side: the preview for the history
        and the original so the viewer opens sharp instead of blurred. }
      AMsgs.EnsurePhotoFile(ARow);
      AMsgs.EnsurePhotoBestFile(ARow);
    end;
    mckAudio, mckVoiceNote:
      AMsgs.EnsurePlayableFile(ARow);
    mckFile:
      AMsgs.EnsureDocFile(ARow);
    mckAnimation: begin
      { A downloaded "GIF" also starts looping by itself — the flag is
        a permanent mark on the row, and the page reads it the same way
        the native widget does. }
      AMsgs.EnsureAnimFile(ARow);
      ARow.AnimAutoPlay := True;
    end;
    mckVideo:
      { Download only, never auto-play: a video with sound starting on
        its own as it scrolls past is not what auto-download asked for.
        Same call the native side makes. }
      AMsgs.EnsureVideoFile(ARow);
  end;
end;

{ Ряды кнопок клавиатуры — и инлайн (под сообщением), и обычной (над
  полем ввода), в одном виде для страницы: text, kind и то, что нужно
  этому виду. Виды — по td_api.tl (TDLib 1.8.67):
    url / loginUrl -> url (открыть ссылку)
    webApp         -> webapp, url (Mini App — второй этап)
    callback       -> callback, data (base64, как его отдаёт TDLib)
    user           -> user, userId
    copyText       -> copy, copy
    keyboardButtonTypeText -> text (отправить текст кнопки)
  Прочее (оплата, игры, запросы телефона и т.п.) — unsupported: страница
  рисует кнопку, но говорит, что этого пока нет. }
function ButtonStyleStr(const AType: utf8string): utf8string;
begin
  if AType = 'buttonStylePrimary' then begin
    Result := 'primary';
  end else if AType = 'buttonStyleDanger' then begin
    Result := 'danger';
  end else if AType = 'buttonStyleSuccess' then begin
    Result := 'success';
  end else if AType = 'buttonStyleLink' then begin
    Result := 'link';
  end else begin
    Result := '';
  end;
end;

function KeyboardRowsJson(ARows: TJSONArray): TJSONArray;
var
  I, J: integer;
  Row: TJSONArray;
  Btn, BType, O, Sub: TJSONObject;
  OutRow: TJSONArray;
  T: utf8string;
begin
  Result := TJSONArray.Create;
  if ARows = nil then begin
    Exit;
  end;
  for I := 0 to ARows.Count - 1 do begin
    if not (ARows.Items[I] is TJSONArray) then begin
      Continue;
    end;
    Row := TJSONArray(ARows.Items[I]);
    OutRow := TJSONArray.Create;
    for J := 0 to Row.Count - 1 do begin
      if not (Row.Items[J] is TJSONObject) then begin
        Continue;
      end;
      Btn := TJSONObject(Row.Items[J]);
      BType := JGetObj(Btn, 'type');
      T := JGetStr(BType, '@type');
      O := TJSONObject.Create;
      O.Add('text', string(JGetStr(Btn, 'text')));
      { Цвет кнопки: style — buttonStylePrimary/Danger/Success/Link
        (td_api.tl коммита d1085f9, и у keyboardButton, и у
        inlineKeyboardButton); живой лог: Default 89, Danger 1. Странице —
        хвост имени типа, '' для Default. }
      O.Add('style', string(ButtonStyleStr(JGetStr(JGetObj(Btn, 'style'), '@type'))));
      { Кастомный эмодзи перед текстом: id строкой, '' — нет. }
      if JGetInt64(Btn, 'icon_custom_emoji_id') <> 0 then begin
        O.Add('emoji', string(IntToStr(JGetInt64(Btn, 'icon_custom_emoji_id'))));
      end else begin
        O.Add('emoji', '');
      end;
      if T = 'inlineKeyboardButtonTypeUrl' then begin
        O.Add('kind', 'url');
        O.Add('url', string(JGetStr(BType, 'url')));
      end else if T = 'inlineKeyboardButtonTypeLoginUrl' then begin
        { Вход на сайт через Telegram: getLoginUrlInfo по id кнопки. }
        O.Add('kind', 'login');
        O.Add('url', string(JGetStr(BType, 'url')));
        O.Add('buttonId', JGetInt64(BType, 'id'));
      end else if T = 'inlineKeyboardButtonTypeCallbackWithPassword' then begin
        O.Add('kind', 'callbackPassword');
        O.Add('data', string(JGetStr(BType, 'data')));
      end else if T = 'inlineKeyboardButtonTypeCallbackGame' then begin
        O.Add('kind', 'game');
      end else if T = 'inlineKeyboardButtonTypeBuy' then begin
        O.Add('kind', 'buy');
      end else if T = 'inlineKeyboardButtonTypeDisabled' then begin
        O.Add('kind', 'disabled');
      end else if T = 'keyboardButtonTypeRequestLocation' then begin
        O.Add('kind', 'requestLocation');
      end else if T = 'keyboardButtonTypeRequestPoll' then begin
        O.Add('kind', 'requestPoll');
        O.Add('forceRegular', JGetBool(BType, 'force_regular'));
        O.Add('forceQuiz', JGetBool(BType, 'force_quiz'));
      end else if T = 'keyboardButtonTypeRequestManagedBot' then begin
        O.Add('kind', 'requestManagedBot');
        O.Add('buttonId', JGetInt(BType, 'id'));
        O.Add('name', string(JGetStr(BType, 'suggested_name')));
        O.Add('username', string(JGetStr(BType, 'suggested_username')));
      end else if (T = 'inlineKeyboardButtonTypeWebApp') or (T = 'keyboardButtonTypeWebApp') then begin
        O.Add('kind', 'webapp');
        O.Add('url', string(JGetStr(BType, 'url')));
      end else if T = 'inlineKeyboardButtonTypeCallback' then begin
        O.Add('kind', 'callback');
        O.Add('data', string(JGetStr(BType, 'data')));
      end else if T = 'inlineKeyboardButtonTypeUser' then begin
        O.Add('kind', 'user');
        O.Add('userId', string(IntToStr(JGetInt64(BType, 'user_id'))));
      end else if T = 'inlineKeyboardButtonTypeSwitchInline' then begin
        { «@бот запрос» — в этот чат (targetChatCurrent) или в выбранный
          (targetChatChosen, с разрешёнными видами чатов). Ссылка
          (targetChatInternalLink) — пока нет. }
        O.Add('kind', 'switchInline');
        O.Add('query', string(JGetStr(BType, 'query')));
        Sub := JGetObj(BType, 'target_chat');
        if JGetStr(Sub, '@type') = 'targetChatCurrent' then begin
          O.Add('target', 'current');
        end else if JGetStr(Sub, '@type') = 'targetChatChosen' then begin
          O.Add('target', 'chosen');
          Sub := JGetObj(Sub, 'types');
          O.Add('users', JGetBool(Sub, 'allow_user_chats'));
          O.Add('bots', JGetBool(Sub, 'allow_bot_chats'));
          O.Add('groups', JGetBool(Sub, 'allow_group_chats'));
          O.Add('channels', JGetBool(Sub, 'allow_channel_chats'));
        end else begin
          O.Strings['kind'] := 'unsupported';
        end;
      end else if T = 'inlineKeyboardButtonTypeCopyText' then begin
        O.Add('kind', 'copy');
        O.Add('copy', string(JGetStr(BType, 'text')));
      end else if T = 'keyboardButtonTypeText' then begin
        O.Add('kind', 'text');
      end else if T = 'keyboardButtonTypeRequestUsers' then begin
        { Кого можно выбрать: max_quantity (0 — один), и ограничение на
          ботов: restrict_user_is_bot + user_is_bot. Премиум-ограничение
          страница не проверит — его проверит Telegram и откажет. }
        O.Add('kind', 'requestUsers');
        O.Add('buttonId', JGetInt(BType, 'id'));
        O.Add('max', JGetInt(BType, 'max_quantity'));
        if JGetBool(BType, 'restrict_user_is_bot') then begin
          O.Add('bots', JGetBool(BType, 'user_is_bot'));
        end;
      end else if T = 'keyboardButtonTypeRequestChat' then begin
        O.Add('kind', 'requestChat');
        O.Add('buttonId', JGetInt(BType, 'id'));
        O.Add('channel', JGetBool(BType, 'chat_is_channel'));
      end else if T = 'keyboardButtonTypeRequestPhoneNumber' then begin
        O.Add('kind', 'requestPhone');
      end else begin
        O.Add('kind', 'unsupported');
      end;
      OutRow.Add(O);
    end;
    Result.Add(OutRow);
  end;
end;

{ Клавиатура над полем ввода из сырого reply_markup, или nil, если это
  не replyMarkupShowKeyboard. }
function ReplyKeyboardJson(const ARaw: utf8string; AMsgId: Int64): TJSONObject;
var
  Data: TJSONData;
  M: TJSONObject;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    M := TJSONObject(Data);
    { replyMarkupForceReply: кнопок нет, но поле ввода должно отвечать на
      это сообщение, со своим плейсхолдером (td_api.tl). }
    if JGetStr(M, '@type') = 'replyMarkupForceReply' then begin
      Result := TJSONObject.Create;
      Result.Add('msgId', AMsgId);
      Result.Add('rows', TJSONArray.Create);
      Result.Add('oneTime', False);
      Result.Add('forceReply', True);
      Result.Add('placeholder', string(JGetStr(M, 'input_field_placeholder')));
      Exit;
    end;
    if JGetStr(M, '@type') <> 'replyMarkupShowKeyboard' then begin
      Exit;
    end;
    Result := TJSONObject.Create;
    Result.Add('msgId', AMsgId);
    Result.Add('forceReply', JGetBool(M, 'force_reply'));
    Result.Add('rows', KeyboardRowsJson(JGetArr(M, 'rows')));
    Result.Add('oneTime', JGetBool(M, 'one_time'));
    Result.Add('placeholder', string(JGetStr(M, 'input_field_placeholder')));
  finally
    Data.Free;
  end;
end;

{ Инлайн-кнопки сообщения из сырого reply_markup, или nil. }
function InlineKeyboardJson(const ARaw: utf8string): TJSONArray;
var
  Data: TJSONData;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if (Data is TJSONObject)
       and (JGetStr(TJSONObject(Data), '@type') = 'replyMarkupInlineKeyboard') then begin
      Result := KeyboardRowsJson(JGetArr(TJSONObject(Data), 'rows'));
    end;
  finally
    Data.Free;
  end;
end;

{ Имя пользователя для сервисных строк («X added Y»): модель
  пользователей; '' — не знаем. }
function ServiceUserName(AUserId: Int64): utf8string;
var
  Users: TTdUsers;
  U: TUserRow;
begin
  Result := '';
  Users := TdUserList;
  if Users = nil then begin
    Exit;
  end;
  U := Users.Find(AUserId);
  if U <> nil then begin
    Result := U.DisplayName;
  end;
end;

{ Текст сервисного сообщения строки (servicetext) или ''. AActor — имя
  отправителя; канал — по виду открытого чата. }
function RowServiceText(AMsgs: TTdMessages; ARow: TMsgRow; const AActor: utf8string): utf8string;
var
  Data: TJSONData;
  Chats: TTdChats;
  CRow: TChatRow;
  IsChannel: boolean;
begin
  Result := '';
  if (ARow.Kind <> mckOther) or (ARow.ContentRaw = '') then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARow.ContentRaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    IsChannel := False;
    Chats := TdChatList;
    if Chats <> nil then begin
      CRow := Chats.Lookup(AMsgs.ChatId);
      IsChannel := (CRow <> nil) and (CRow.Kind = ckChannel);
    end;
    Result := ServiceMessageText(TJSONObject(Data), AActor, IsChannel, @ServiceUserName);
  finally
    Data.Free;
  end;
end;

{ Карточка контакта — messageContact (td_api.tl коммита d1085f9:
  contact — phone_number, first_name, last_name, vcard, user_id). Модель
  держит её как mckOther; аватарка и цвет — из модели пользователей, если
  человек в Telegram (user_id <> 0), фото докачивается там же. nil — не
  контакт. }
function ContactJson(const ARaw: utf8string): TJSONObject;
var
  Data: TJSONData;
  C: TJSONObject;
  UserId: Int64;
  Users: TTdUsers;
  U: TUserRow;
  Name: utf8string;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) or (JGetStr(TJSONObject(Data), '@type') <> 'messageContact') then begin
      Exit;
    end;
    C := JGetObj(TJSONObject(Data), 'contact');
    UserId := JGetInt64(C, 'user_id');
    Name := utf8string(Trim(string(JGetStr(C, 'first_name') + ' ' + JGetStr(C, 'last_name'))));
    Result := TJSONObject.Create;
    Result.Add('name', string(Name));
    Result.Add('first', string(JGetStr(C, 'first_name')));
    Result.Add('last', string(JGetStr(C, 'last_name')));
    Result.Add('phone', string(JGetStr(C, 'phone_number')));
    Result.Add('userId', string(IntToStr(UserId)));
    Result.Add('avatar', '');
    Result.Add('avatarThumb', '');
    Result.Add('color', string(AccentKeyFor(-1, UserId)));
    if UserId = 0 then begin
      Exit;
    end;
    Users := TdUserList;
    if Users = nil then begin
      Exit;
    end;
    U := Users.Find(UserId);
    if U = nil then begin
      Exit;
    end;
    Result.Strings['color'] := string(AccentKeyFor(U.AccentColorId, UserId));
    Result.Strings['avatar'] := string(FileUrl(U.PhotoFileId, U.PhotoPath));
    Result.Strings['avatarThumb'] := string(ThumbDataUri(U.Minithumb));
    if U.PhotoPath = '' then begin
      Users.EnsurePhoto(U);
    end;
  finally
    Data.Free;
  end;
end;

{ Звонок в истории — messageCall (is_video, discard_reason, duration) и
  messageGroupCall (is_active, was_missed, is_video, duration) по
  td_api.tl коммита d1085f9. Модель держит их как mckOther; без этого
  страница рисовала пустой пузырь. reason — хвост типа
  callDiscardReason* маленькими буквами (missed, declined,
  disconnected, hungup, empty...). nil — не звонок. }
function CallMessageJson(const ARaw: utf8string): TJSONObject;
var
  Data: TJSONData;
  O: TJSONObject;
  T, Reason: utf8string;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    O := TJSONObject(Data);
    T := JGetStr(O, '@type');
    if (T <> 'messageCall') and (T <> 'messageGroupCall') then begin
      Exit;
    end;
    Result := TJSONObject.Create;
    Result.Add('group', T = 'messageGroupCall');
    Result.Add('video', JGetBool(O, 'is_video'));
    Result.Add('duration', JGetInt(O, 'duration'));
    Reason := JGetStr(JGetObj(O, 'discard_reason'), '@type');
    if Copy(Reason, 1, 17) = 'callDiscardReason' then begin
      Reason := LowerCase(Copy(Reason, 18, MaxInt));
    end;
    if T = 'messageGroupCall' then begin
      if JGetBool(O, 'is_active') then begin
        Reason := 'active';
      end else if JGetBool(O, 'was_missed') then begin
        Reason := 'missed';
      end else begin
        Reason := 'hungup';
      end;
    end;
    Result.Add('reason', string(Reason));
  finally
    Data.Free;
  end;
end;

{ Геопозиция сообщения — из сырого content (td_api.tl коммита d1085f9):
  messageLocation (location), messageVenue (venue: location, title,
  address), messageLiveLocation (location: liveLocation — его location,
  live_period; expires_in). Модель держит такие сообщения как mckOther;
  nil — не геопозиция. }
function LocationJson(const ARaw: utf8string): TJSONObject;
var
  Data: TJSONData;
  C, Loc, Venue: TJSONObject;
  T: utf8string;
begin
  Result := nil;
  if ARaw = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    C := TJSONObject(Data);
    T := JGetStr(C, '@type');
    Loc := nil;
    Venue := nil;
    if T = 'messageLocation' then begin
      Loc := JGetObj(C, 'location');
    end else if T = 'messageVenue' then begin
      Venue := JGetObj(C, 'venue');
      Loc := JGetObj(Venue, 'location');
    end else if T = 'messageLiveLocation' then begin
      Loc := JGetObj(JGetObj(C, 'location'), 'location');
    end;
    if Loc = nil then begin
      Exit;
    end;
    Result := TJSONObject.Create;
    Result.Add('lat', Loc.Get('latitude', 0.0));
    Result.Add('lon', Loc.Get('longitude', 0.0));
    { horizontal_accuracy — радиус неопределённости в метрах; 0 — неизвестен. }
    Result.Add('accuracy', Loc.Get('horizontal_accuracy', 0.0));
    Result.Add('title', string(JGetStr(Venue, 'title')));
    Result.Add('address', string(JGetStr(Venue, 'address')));
    Result.Add('live', T = 'messageLiveLocation');
    Result.Add('expiresIn', JGetInt(C, 'expires_in'));
  finally
    Data.Free;
  end;
end;

function MsgToJson(AMsgs: TTdMessages; ARow: TMsgRow; ALastReadOutbox: Int64): TJSONObject;
var
  BotUser: TUserRow;
  Kb: TJSONArray;
  Name, Color, PreviewText: utf8string;
  RUser, RChat: Int64;
  Sub: TJSONObject;
  Media: TJSONObject;
  Loc: TJSONObject;
  ServiceLine: utf8string;
begin
  Result := TJSONObject.Create;
  Result.Add('id',       ARow.Id);
  Result.Add('date',     ARow.Date);
  Result.Add('editDate', ARow.EditDate);
  Result.Add('outgoing', ARow.IsOutgoing);
  Result.Add('isPinned', ARow.IsPinned);
  { A STRING, not a number, and that is not cosmetic: album ids are full
    64-bit values (7822163933024890355 was in the log), well past the
    2^53 a JSON number survives in JavaScript. The page only ever
    compares them for equality, so text loses nothing. '' means "not
    part of an album" - cleaner on the page than the 0 TDLib sends. }
  if ARow.AlbumId <> 0 then begin
    Result.Add('albumId', string(IntToStr(ARow.AlbumId)));
  end else begin
    Result.Add('albumId', '');
  end;
  Result.Add('kind',     string(ContentKindStr(ARow.Kind)));
  if ARow.Kind = mckOther then begin
    Loc := LocationJson(ARow.ContentRaw);
    if Loc <> nil then begin
      Result.Strings['kind'] := 'location';
      Result.Add('location', Loc);
    end else begin
      Loc := ContactJson(ARow.ContentRaw);
      if Loc <> nil then begin
        Result.Strings['kind'] := 'contact';
        Result.Add('contact', Loc);
      end else begin
        Loc := CallMessageJson(ARow.ContentRaw);
        if Loc <> nil then begin
          Result.Strings['kind'] := 'call';
          Result.Add('call', Loc);
        end;
      end;
    end;
  end;
  Result.Add('text',     string(ARow.PlainText));
  Result.Add('entities', EntitiesJson(ARow.Entities));
  Result.Add('receipt',  string(ReceiptStr(MessageReceipt(ARow, ALastReadOutbox))));

  ResolveSubject(ARow.SenderUserId, ARow.SenderChatId, Name, Color);
  { Сервисное сообщение (создание группы, вход, закреп…): страница рисует
    его строкой посередине, а не пузырём, и в меню оставляет только
    удаление. Текст — servicetext, с именем отправителя. }
  if Result.Strings['kind'] = 'other' then begin
    ServiceLine := RowServiceText(AMsgs, ARow, Name);
    if ServiceLine <> '' then begin
      Result.Add('service', True);
      Result.Strings['text'] := string(ServiceLine);
      Result.Arrays['entities'] := TJSONArray.Create;
    end;
  end;
  Result.Add('senderId',    ARow.SenderUserId + ARow.SenderChatId);
  Result.Add('senderName',  string(Name));
  Result.Add('senderColor', string(Color));
  AddSenderAvatar(Result, ARow.SenderUserId, ARow.SenderChatId);

  { A reply quote. ReplyPreview answers False when the quoted message
    is not loaded yet — it starts a getRepliedMessage of its own and
    the answer arrives through the ordinary change signal, so sending
    the ids alone now and the text later is correct rather than lossy. }
  { В ветке комментариев ответ на сам пост цитатой не показывается: вся
    ветка и так под ним (пост стоит сверху), а цитата выходила пустой
    «…». TDLib называет пост двумя способами — сообщением канала
    (ThreadChatId/ThreadPostId) или корневой копией в группе обсуждения,
    чей id совпадает с message_thread_id. Ответы другим комментаторам
    остаются. }
  if (ARow.ReplyMessageId <> 0) and (AMsgs.ThreadId <> 0)
     and (((ARow.ReplyChatId = AMsgs.ThreadChatId)
           and (ARow.ReplyMessageId = AMsgs.ThreadPostId))
          or (ARow.ReplyMessageId = AMsgs.ThreadId)) then begin
    { без цитаты }
  end else if ARow.ReplyMessageId <> 0 then begin
    Sub := TJSONObject.Create;
    Sub.Add('id', ARow.ReplyMessageId);
    { Which chat the quoted message lives in. TDLib fills chat_id on
      every reply_to, usually with the chat the reply itself is in -
      but a comment under a channel post quotes the POST, which is in
      the channel. Without this the page could only look for it where
      it already was, and clicking the quote did nothing at all. }
    Sub.Add('chatId', ARow.ReplyChatId);
    if AMsgs.ReplyPreview(ARow.ReplyChatId, ARow.ReplyMessageId,
      RUser, RChat, PreviewText) then begin
      ResolveSubject(RUser, RChat, Name, Color);
      Sub.Add('name',  string(Name));
      Sub.Add('color', string(Color));
      Sub.Add('text',  string(PreviewText));
    end;
    Result.Add('reply', Sub);
  end;

  if ARow.ForwardKind <> mfoNone then begin
    Sub := TJSONObject.Create;
    Sub.Add('kind', string(ForwardKindStr(ARow.ForwardKind)));
    Sub.Add('date', ARow.ForwardDate);
    if ARow.ForwardKind = mfoHiddenUser then begin
      Sub.Add('name', string(ARow.ForwardSenderName));
      Sub.Add('color', string(AccentKeyFor(-1, 0)));
    end else begin
      ResolveSubject(ARow.ForwardUserId, ARow.ForwardChatId, Name, Color);
      if (Name = '') and (ARow.ForwardSenderName <> '') then begin
        Name := ARow.ForwardSenderName;
      end;
      Sub.Add('name',  string(Name));
      Sub.Add('color', string(Color));
    end;
    { Only a channel forward carries the source message's id, so only
      it can offer "go to the original" — the other origins withhold
      it by design (privacy), see TMsgForwardKind. }
    if ARow.ForwardKind = mfoChannel then begin
      Sub.Add('chatId',    ARow.ForwardChatId);
      Sub.Add('messageId', ARow.ForwardMessageId);
    end;
    Result.Add('forward', Sub);
  end;

  { The link preview, if Telegram built one for this message. The
    whole card comes from their servers; the only thing the client
    does is download the picture and lay it out. }
  if ARow.LinkUrl <> '' then begin
    Sub := TJSONObject.Create;
    Sub.Add('url',     string(ARow.LinkUrl));
    Sub.Add('display', string(ARow.LinkDisplay));
    Sub.Add('site',    string(ARow.LinkSite));
    Sub.Add('title',   string(ARow.LinkTitle));
    Sub.Add('text',    string(ARow.LinkDesc));
    Sub.Add('large',   ARow.LinkLarge);
    if ARow.LinkPhotoFileId <> 0 then begin
      Sub.Add('w', ARow.LinkPhotoW);
      Sub.Add('h', ARow.LinkPhotoH);
      Sub.Add('url_photo',
        string(FileUrl(ARow.LinkPhotoFileId, ARow.LinkPhotoPath)));
      if ARow.LinkMinithumb <> '' then begin
        Sub.Add('thumb', string(ThumbDataUri(ARow.LinkMinithumb)));
      end;
    end;
    Result.Add('link', Sub);
  end;

  { The comments pill. Sent whenever the post TAKES comments, count
    and all - including zero: without the button there is no way to
    leave the first one. }
  if ARow.HasComments then begin
    Result.Add('comments',  ARow.CommentCount);
    Result.Add('commentsNew', ARow.CommentUnread);
  end;

  if Length(ARow.Reactions) > 0 then begin
    Result.Add('reactions', ReactionsJson(ARow.Reactions));
    Result.Add('canSeeReactors', ARow.CanSeeReactors);
  end;
  if ARow.Kind = mckPoll then begin
    Result.Add('poll', PollJson(ARow.Poll));
  end;

  { Before the media is described, so that a download started on this
    pass is already reflected in the progress fields below. }
  AutoFetch(AMsgs, ARow);
  Media := MediaJson(AMsgs, ARow);
  if Media <> nil then begin
    Result.Add('media', Media);
  end;
  { Кнопки бота под сообщением (replyMarkupInlineKeyboard). }
  Kb := InlineKeyboardJson(ARow.ReplyMarkupRaw);
  if Kb <> nil then begin
    Result.Add('keyboard', Kb);
    { Для кнопок switchInline: «@имя запрос». }
    if (ARow.SenderUserId <> 0) and (TdUserList <> nil) then begin
      BotUser := TdUserList.Find(ARow.SenderUserId);
      if (BotUser <> nil) and (BotUser.Username <> '') then begin
        Result.Add('botUsername', string(BotUser.Username));
      end;
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{ TWebApi                                                            }
{ ------------------------------------------------------------------ }

constructor TWebApi.Create;
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FQueue := TFPList.Create;
  FTimer := TTdTimer.Create(nil);
  FTimer.Interval := WEBAPI_FALLBACK_TICK_MS;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := True;
  FAuth := TWebAuth.Create(nil);
  FAuth.OnChanged := @AuthChanged;
  FSnaps := TConnSnapMap.Create;
  FSnaps.Sorted := True;
  FInlineBots := TStringList.Create;
  FAddReturn := -1;
  FActiveHook := TWebActiveHook.Create(nil);
  TdApp.SubscribeActive(FActiveHook);
end;

destructor TWebApi.Destroy;
var
  I: integer;
begin
  TdApp.UnsubscribeActive(FActiveHook);
  FreeAndNil(FActiveHook);
  FTimer.Enabled := False;
  FTimer.Free;
  FreeAndNil(FAuth);
  DropBindings;
  { A queued Drain still pointing at this object would run against
    freed memory. }
  TThread.RemoveQueuedEvents(@Drain);
  FLock.Enter;
  try
    for I := 0 to FQueue.Count - 1 do begin
      TObject(FQueue[I]).Free;
    end;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
  FQueue.Free;
  FLock.Free;
  for I := 0 to FSnaps.Count - 1 do begin
    FSnaps.Data[I].Free;
  end;
  FSnaps.Free;
  FInlineBots.Free;
  inherited Destroy;
end;

{ Subscribes to whichever models the active account currently has.
  Re-checked on every tick rather than bound once: at start-up there is
  no account yet, and switching accounts replaces both objects. }
procedure TWebApi.EnsureBindings;
var
  Chats: TTdChats;
  Msgs: TTdMessages;
  Sticks: TTdStickers;
begin
  { The sign-in watcher follows the active account too, and does it
    first: until an account is signed in there is nothing else to
    bind, and the page is waiting to be told exactly that. }
  if FAuth <> nil then begin
    FAuth.Bind(TdApp.Active);
  end;

  Chats := TdChatList;
  if Chats <> FBoundChats then begin
    { The previous object is NOT unsubscribed from here. It belongs to
      an account that has just been switched away from or removed, and
      may already be gone; calling a method on it to tidy up would be
      the very use-after-free this is trying to avoid. Its listener
      list dies with it. }
    FBoundChats := Chats;
    if Chats <> nil then begin
      Chats.AddChangeListener(@ChatsChanged);
      Chats.OnArrival := @ChatArrived;
    end;
  end;

  Msgs := TdMsgList;
  if Msgs <> FBoundMsgs then begin
    FBoundMsgs := Msgs;
    if Msgs <> nil then begin
      Msgs.AddChangeListener(@MessagesChanged);
    end;
  end;

  { One handler, not a list: nothing else in the app looks at sticker
    sets, so TTdStickers has a plain OnChanged rather than the
    subscriber list TTdChats/TTdMessages need. }
  Sticks := TdStickerList;
  if Sticks <> FBoundStickers then begin
    FBoundStickers := Sticks;
    if Sticks <> nil then begin
      Sticks.OnChanged := @StickersChanged;
    end;
  end;

  if TdSupergroupList <> FBoundGroups then begin
    FBoundGroups := TdSupergroupList;
    if FBoundGroups <> nil then begin
      FBoundGroups.OnChanged := @GroupsChanged;
    end;
  end;

  if TdUserList <> FBoundUsers then begin
    FBoundUsers := TdUserList;
    if FBoundUsers <> nil then begin
      FBoundUsers.OnChanged := @UsersChanged;
    end;
  end;

  if TdCallList <> FBoundCalls then begin
    FBoundCalls := TdCallList;
    if FBoundCalls <> nil then begin
      FBoundCalls.OnChanged := @CallChanged;
      FBoundCalls.OnSignal := @CallSignal;
      FBoundCalls.OnGroup := @GroupCallChanged;
      FBoundCalls.OnParticipant := @GroupParticipantChanged;
      FBoundCalls.OnChatVideoChat := @ChatVideoChatChanged;
    end;
  end;
end;

{ Unsubscribes, but only from objects that are still the current ones.
  Anything else is either already freed or about to be, and reaching
  into it would be worse than leaving a listener on a dying object. }
procedure TWebApi.DropBindings;
begin
  if (FBoundChats <> nil) and (FBoundChats = TdChatList) then begin
    FBoundChats.RemoveChangeListener(@ChatsChanged);
    FBoundChats.OnArrival := nil;
  end;
  FBoundChats := nil;
  if (FBoundMsgs <> nil) and (FBoundMsgs = TdMsgList) then begin
    FBoundMsgs.RemoveChangeListener(@MessagesChanged);
  end;
  FBoundMsgs := nil;
  if (FBoundStickers <> nil) and (FBoundStickers = TdStickerList) then begin
    FBoundStickers.OnChanged := nil;
  end;
  FBoundStickers := nil;
  if (FBoundGroups <> nil) and (FBoundGroups = TdSupergroupList) then begin
    FBoundGroups.OnChanged := nil;
  end;
  FBoundGroups := nil;
  if (FBoundUsers <> nil) and (FBoundUsers = TdUserList) then begin
    FBoundUsers.OnChanged := nil;
  end;
  FBoundUsers := nil;
  if (FBoundCalls <> nil) and (FBoundCalls = TdCallList) then begin
    FBoundCalls.OnChanged := nil;
    FBoundCalls.OnSignal := nil;
    FBoundCalls.OnGroup := nil;
    FBoundCalls.OnParticipant := nil;
    FBoundCalls.OnChatVideoChat := nil;
  end;
  FBoundCalls := nil;
end;

{ Принадлежит ли модель какому-нибудь живому аккаунту. Модели
  аккаунта, с которого переключились, живы и шлют свои изменения дальше;
  модели удалённого — уже освобождены, трогать их нельзя. }
function ModelAlive(AObj: TObject): boolean;
var
  I: integer;
  A: TTdAccount;
begin
  Result := False;
  if AObj = nil then begin
    Exit;
  end;
  for I := 0 to TdApp.Count - 1 do begin
    A := TdApp.Accounts[I];
    if (TObject(A.Chats) = AObj) or (TObject(A.Messages) = AObj)
       or (TObject(A.Stickers) = AObj) or (TObject(A.Supergroups) = AObj)
       or (TObject(A.Users) = AObj) or (TObject(A.Calls) = AObj) then begin
      Result := True;
      Exit;
    end;
  end;
end;

{ Отписка от моделей аккаунта, который перестал быть активным. Без неё
  его списки чатов и сообщений продолжали дёргать мост и после
  переключения: EnsureBindings подписывается на новые, но старые
  отпустить не может — не знает, живы ли они. }
procedure TWebApi.UnbindStale;
begin
  { Открытый чат прежнего аккаунта закрывается: его больше никто не
    видит, а для TDLib открытый чат — тот, что на экране. }
  if ModelAlive(FBoundMsgs) and (FBoundMsgs.ChatId <> 0) then begin
    FBoundMsgs.CloseChat;
  end;
  if ModelAlive(FBoundChats) then begin
    FBoundChats.RemoveChangeListener(@ChatsChanged);
    FBoundChats.OnArrival := nil;
  end;
  FBoundChats := nil;
  if ModelAlive(FBoundMsgs) then begin
    FBoundMsgs.RemoveChangeListener(@MessagesChanged);
  end;
  FBoundMsgs := nil;
  if ModelAlive(FBoundStickers) then begin
    FBoundStickers.OnChanged := nil;
  end;
  FBoundStickers := nil;
  if ModelAlive(FBoundGroups) then begin
    FBoundGroups.OnChanged := nil;
  end;
  FBoundGroups := nil;
  if ModelAlive(FBoundUsers) then begin
    FBoundUsers.OnChanged := nil;
  end;
  FBoundUsers := nil;
  if ModelAlive(FBoundCalls) then begin
    FBoundCalls.OnChanged := nil;
    FBoundCalls.OnSignal := nil;
    FBoundCalls.OnGroup := nil;
    FBoundCalls.OnParticipant := nil;
    FBoundCalls.OnChatVideoChat := nil;
  end;
  FBoundCalls := nil;
end;

{ Сменился активный аккаунт. Модели — другие, снимки того, что видела
  каждая страница, — от другого аккаунта: всё это сбрасывается, а
  страницы перезагружаются по событию account (так их состояние
  гарантированно не смешает двух аккаунтов). }
procedure TWebApi.ActiveSwitched;
var
  I: integer;
begin
  UnbindStale;
  EnsureBindings;
  for I := 0 to FSnaps.Count - 1 do begin
    FSnaps.Data[I].Free;
  end;
  FSnaps.Clear;
  PushEvent('account', nil);
end;

procedure TWebActiveHook.TdActiveChanged(ANew: TTdAccount);
begin
  if GApi <> nil then begin
    GApi.ActiveSwitched;
  end;
end;

procedure TWebActiveHook.TdAccountsChanged;
begin
  if GApi <> nil then begin
    GApi.PushEvent('accounts', nil);
  end;
end;

{ Аватарка аккаунта data-URI из файла (см. ACCOUNT_AVATAR_MAX_BYTES);
  нет файла или он велик — minithumbnail; нет и её — ''. }
function AccountAvatarUri(A: TTdAccount): utf8string;
var
  F: TFileStream;
  S: RawByteString;
begin
  Result := ThumbDataUri(A.PhotoThumb);
  if (A.PhotoPath = '') or not FileExists(string(A.PhotoPath)) then begin
    Exit;
  end;
  S := '';
  try
    F := TFileStream.Create(string(A.PhotoPath), fmOpenRead or fmShareDenyNone);
    try
      if (F.Size > 0) and (F.Size <= ACCOUNT_AVATAR_MAX_BYTES) then begin
        SetLength(S, F.Size);
        F.ReadBuffer(S[1], F.Size);
      end;
    finally
      F.Free;
    end;
  except
    S := '';
  end;
  if S <> '' then begin
    Result := 'data:image/jpeg;base64,' + utf8string(EncodeStringBase64(string(S)));
  end;
end;

{ accounts.list — переключатель аккаунтов в статусной строке: все
  аккаунты реестра (имя из getMe, телефон, username, аватарка, вошёл ли,
  непрочитанные чаты основного списка) и номер активного. }
function TWebApi.CmdAccountsList: TJSONData;
var
  Res, O: TJSONObject;
  Arr: TJSONArray;
  I: integer;
  A: TTdAccount;
begin
  Res := TJSONObject.Create;
  Arr := TJSONArray.Create;
  for I := 0 to TdApp.Count - 1 do begin
    A := TdApp.Accounts[I];
    O := TJSONObject.Create;
    O.Add('index', I);
    O.Add('title', A.Title);
    O.Add('phone', string(A.Phone));
    O.Add('username', string(A.Username));
    O.Add('color', string(AccentKeyFor(-1, A.UserId)));
    O.Add('avatar', string(AccountAvatarUri(A)));
    O.Add('ready', A.State = tasReady);
    if A.Chats <> nil then begin
      O.Add('unread', A.Chats.MainInfo.UnreadChats);
    end else begin
      O.Add('unread', 0);
    end;
    Arr.Add(O);
  end;
  Res.Add('active', TdApp.ActiveIndex);
  Res.Add('accounts', Arr);
  Res.Add('canAdd', TdApp.Started);
  Result := Res;
end;

function TWebApi.CmdAccountsSwitch(AArgs: TJSONObject): TJSONData;
var
  I: integer;
begin
  I := AArgs.Get('index', -1);
  if (I < 0) or (I >= TdApp.Count) then begin
    raise Exception.Create('unknown account');
  end;
  FAddReturn := -1;
  TdApp.ActiveIndex := I;
  Result := TJSONObject.Create;
end;

{ Новый аккаунт: в реестр, клиент TDLib запускается, аккаунт становится
  активным — страница перезагрузится и покажет вход. Прежний активный
  запоминается для accounts.cancel. }
function TWebApi.CmdAccountsAdd: TJSONData;
var
  A: TTdAccount;
  Back: integer;
begin
  if not TdApp.Started then begin
    raise Exception.Create('Sign in to the first account before adding another');
  end;
  Back := TdApp.ActiveIndex;
  A := TdApp.AddAccount('Account ' + IntToStr(TdApp.Count + 1));
  TdApp.SaveAccounts;
  A.Start;
  FAddReturn := Back;
  TdApp.ActiveIndex := TdApp.Count - 1;
  Result := TJSONObject.Create;
end;

{ Отмена входа в аккаунт, который ещё не вошёл, когда есть другие:
  назад к запомненному (или любому другому), а этот закрывается без
  выхода из сессии и уходит из реестра (DiscardAccount). }
function TWebApi.CmdAccountsCancel: TJSONData;
var
  A: TTdAccount;
  Back, I: integer;
begin
  A := TdApp.Active;
  if (A = nil) or (A.State = tasReady) or (TdApp.Count < 2) then begin
    raise Exception.Create('Nothing to cancel');
  end;
  Back := FAddReturn;
  FAddReturn := -1;
  if (Back < 0) or (Back >= TdApp.Count) or (Back = TdApp.ActiveIndex) then begin
    Back := -1;
    for I := 0 to TdApp.Count - 1 do begin
      if I <> TdApp.ActiveIndex then begin
        Back := I;
        Break;
      end;
    end;
  end;
  TdApp.ActiveIndex := Back;
  TdApp.DiscardAccount(A);
  Result := TJSONObject.Create;
end;

{ Выход из активного аккаунта. Как у Telegram: при других аккаунтах он
  уходит из списка, последний остаётся и возвращается ко входу
  (TTdCore.LogOut). }
function TWebApi.CmdAccountsLogout: TJSONData;
begin
  FAddReturn := -1;
  TdApp.LogOut;
  Result := TJSONObject.Create;
end;

{ How many connections' views are remembered. Two is the normal case
  (the app's own window and a browser tab); the cap only exists so a
  long run of reconnects cannot grow the map without end. }
const
  MAX_SNAPS = 8;

{ FNV-1a, 64-bit. Any stable hash would do - this one is four lines and
  has no table. }
function JsonHash(const S: utf8string): QWord;
var
  I: integer;
begin
  Result := QWord(14695981039346656037);
  for I := 1 to Length(S) do begin
    Result := Result xor QWord(Ord(S[I]));
    Result := Result * QWord(1099511628211);
  end;
end;

{ Answers with a message list and remembers what went out.

  Every path that produces one comes through here, and that is the
  point: a full list sent without recording it would leave the next
  delta measured against something the page never received. }
procedure TWebApi.ReplyMessages(AConnId: Int64; AReqId: integer;
  AList: TJSONData; ADelta: boolean);
begin
  if ADelta then begin
    AList := ToDelta(AConnId, AList);
  end else begin
    NoteSent(AConnId, AList);
  end;
  Reply(AConnId, AReqId, AList);
end;

function TWebApi.SnapOf(AConnId: Int64): TIdHashMap;
var
  Idx: integer;
begin
  Idx := FSnaps.IndexOf(AConnId);
  if Idx >= 0 then begin
    Result := FSnaps.Data[Idx];
    Exit;
  end;
  { Oldest out. Whoever is dropped simply gets told everything on its
    next request, which is what a first request does anyway. }
  while FSnaps.Count >= MAX_SNAPS do begin
    FSnaps.Data[0].Free;
    FSnaps.Delete(0);
  end;
  Result := TIdHashMap.Create;
  Result.Sorted := True;
  FSnaps.Add(AConnId, Result);
end;

{ Records what this connection has just been told, so the next answer
  can be the difference. Called with the list that is actually going
  out, whatever produced it. }
procedure TWebApi.NoteSent(AConnId: Int64; AList: TJSONData);
var
  Snap: TIdHashMap;
  Arr: TJSONArray;
  I: integer;
  Item: TJSONObject;
begin
  if (AConnId = 0) or (AList = nil) or not (AList is TJSONObject) then begin
    Exit;
  end;
  Arr := JGetArr(TJSONObject(AList), 'items');
  Snap := SnapOf(AConnId);
  Snap.Clear;
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    Item := TJSONObject(Arr.Items[I]);
    Snap.Add(Item.Get('id', Int64(0)), JsonHash(utf8string(Item.AsJSON)));
  end;
end;

{ Turns a freshly built full list into what this connection has not
  seen: the messages whose JSON differs from last time, and the ids
  that have gone. Everything around the list - the unread marker, the
  thread, the chat's own row - is small and rides along whole.

  The list is still BUILT in full, because the only way to know that a
  message is unchanged is to serialise it and look. What this saves is
  the wire, the parse at the other end, and the page's reconcile - and
  that was the expensive part: 455 KB for 550 messages, on every
  change to the model. }
function TWebApi.ToDelta(AConnId: Int64; AFull: TJSONData): TJSONData;
var
  Snap, Fresh: TIdHashMap;
  Arr, Keep, Gone: TJSONArray;
  I, Idx: integer;
  Item: TJSONObject;
  Id: Int64;
  H: QWord;
begin
  Result := AFull;
  if (AConnId = 0) or (AFull = nil) or not (AFull is TJSONObject) then begin
    Exit;
  end;
  Arr := JGetArr(TJSONObject(AFull), 'items');
  if Arr = nil then begin
    Exit;
  end;
  Snap := SnapOf(AConnId);
  Fresh := TIdHashMap.Create;
  Fresh.Sorted := True;
  Keep := TJSONArray.Create;
  Gone := TJSONArray.Create;
  try
    I := 0;
    while I < Arr.Count do begin
      if Arr.Items[I].JSONType <> jtObject then begin
        Inc(I);
        Continue;
      end;
      Item := TJSONObject(Arr.Items[I]);
      Id := Item.Get('id', Int64(0));
      H := JsonHash(utf8string(Item.AsJSON));
      Fresh.Add(Id, H);
      Idx := Snap.IndexOf(Id);
      if (Idx >= 0) and (Snap.Data[Idx] = H) then begin
        { Unchanged - the page already has it. }
        Arr.Delete(I);
      end else begin
        Keep.Add(Arr.Extract(I));
      end;
    end;
    for I := 0 to Snap.Count - 1 do begin
      if Fresh.IndexOf(Snap.Keys[I]) < 0 then begin
        Gone.Add(Snap.Keys[I]);
      end;
    end;
    { The snapshot becomes what the page will have once this arrives. }
    Snap.Clear;
    for I := 0 to Fresh.Count - 1 do begin
      Snap.Add(Fresh.Keys[I], Fresh.Data[I]);
    end;
  finally
    Fresh.Free;
  end;
  { Replaced, not added: the builder already put both of these in, and
    fpjson is happy to carry two members of the same name while the
    parser at the other end is not. }
  TJSONObject(AFull).Delete(TJSONObject(AFull).IndexOfName('items'));
  TJSONObject(AFull).Delete(TJSONObject(AFull).IndexOfName('full'));
  TJSONObject(AFull).Add('items', Keep);
  TJSONObject(AFull).Add('removed', Gone);
  TJSONObject(AFull).Add('full', False);
end;

procedure TWebApi.PushEvent(const AName: utf8string; AData: TJSONObject);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('event', string(AName));
    if AData <> nil then begin
      O.Add('data', AData);
    end;
    WebBroadcast(utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

procedure TWebApi.ChatsChanged(Sender: TObject);
begin
  PushEvent('chats', nil);
end;

procedure TWebApi.MessagesChanged(Sender: TObject);
var
  D: TJSONObject;
  M: TTdMessages;
begin
  D := TJSONObject.Create;
  M := TdMsgList;
  if M <> nil then begin
    D.Add('chatId', M.ChatId);
  end else begin
    D.Add('chatId', 0);
  end;
  PushEvent('messages', D);
end;

procedure TWebApi.StickersChanged(Sender: TObject);
begin
  FStickersDirty := True;
end;

procedure TWebApi.GroupsChanged(Sender: TObject);
begin
  FGroupsDirty := True;
end;

procedure TWebApi.UsersChanged(Sender: TObject);
begin
  FUsersDirty := True;
end;

{ ------------------------------------------------------------------ }
{ звонки (tdcalls.pas; страница — ui/call.js, calls/*.js)            }
{ ------------------------------------------------------------------ }

{ Звонок для страницы. state — хвост типа callState* с маленькой буквы
  (pending, exchangingKeys, ready, hangingUp, discarded, error). Для
  ready — всё, что нужно WebRTC: ключ (base64, 256 байт), версия
  протокола, серверы, эмодзи для сверки ключа, allowP2p. Имя и
  аватарка собеседника — чтобы окно звонка не спрашивало их отдельно. }
function CallToJson(ACall: TJSONObject): TJSONObject;
var
  State, Proto, Srv, SrvType, Item: TJSONObject;
  Arr, Out, Emojis, Versions: TJSONArray;
  Kind: utf8string;
  I: integer;
  UserId: Int64;
  Users: TTdUsers;
  U: TUserRow;
begin
  Result := TJSONObject.Create;
  UserId := JGetInt64(ACall, 'user_id');
  Result.Add('id', JGetInt(ACall, 'id'));
  Result.Add('userId', UserId);
  Result.Add('outgoing', JGetBool(ACall, 'is_outgoing'));
  Result.Add('video', JGetBool(ACall, 'is_video'));
  Result.Add('name', '');
  Users := TdUserList;
  if Users <> nil then begin
    U := Users.Find(UserId);
    if U <> nil then begin
      Result.Strings['name'] := string(U.DisplayName);
    end;
  end;
  AddSenderAvatar(Result, UserId, 0);

  State := JGetObj(ACall, 'state');
  Kind := JGetStr(State, '@type');
  if Copy(Kind, 1, 9) = 'callState' then begin
    Kind := Copy(Kind, 10, MaxInt);
    if Kind <> '' then begin
      Kind[1] := LowerCase(Kind[1]);
    end;
  end;
  Result.Add('state', string(Kind));
  if Kind = 'pending' then begin
    Result.Add('created', JGetBool(State, 'is_created'));
    Result.Add('received', JGetBool(State, 'is_received'));
  end else if Kind = 'ready' then begin
    Result.Add('key', string(JGetStr(State, 'encryption_key')));
    Result.Add('allowP2p', JGetBool(State, 'allow_p2p'));
    Result.Add('config', string(JGetStr(State, 'config')));
    Result.Add('customParameters', string(JGetStr(State, 'custom_parameters')));
    Proto := JGetObj(State, 'protocol');
    Versions := JGetArr(Proto, 'library_versions');
    if (Versions <> nil) and (Versions.Count > 0) then begin
      Result.Add('version', Versions.Strings[0]);
    end else begin
      Result.Add('version', '');
    end;
    Emojis := TJSONArray.Create;
    Arr := JGetArr(State, 'emojis');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        Emojis.Add(Arr.Strings[I]);
      end;
    end;
    Result.Add('emojis', Emojis);
    { Серверы: WebRTC-тип (STUN/TURN) годится браузеру как есть;
      рефлекторы Telegram — свой протокол, страница их пропускает, но
      они отдаются, чтобы было видно, что пришло. }
    Out := TJSONArray.Create;
    Arr := JGetArr(State, 'servers');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if Arr.Items[I].JSONType <> jtObject then begin
          Continue;
        end;
        Srv := TJSONObject(Arr.Items[I]);
        SrvType := JGetObj(Srv, 'type');
        Item := TJSONObject.Create;
        Item.Add('id', string(IntToStr(JGetInt64(Srv, 'id'))));
        Item.Add('ip', string(JGetStr(Srv, 'ip_address')));
        Item.Add('ipv6', string(JGetStr(Srv, 'ipv6_address')));
        Item.Add('port', JGetInt(Srv, 'port'));
        if JGetStr(SrvType, '@type') = 'callServerTypeWebrtc' then begin
          Item.Add('type', 'webrtc');
          Item.Add('username', string(JGetStr(SrvType, 'username')));
          Item.Add('password', string(JGetStr(SrvType, 'password')));
          Item.Add('turn', JGetBool(SrvType, 'supports_turn'));
          Item.Add('stun', JGetBool(SrvType, 'supports_stun'));
        end else begin
          Item.Add('type', 'reflector');
          Item.Add('tcp', JGetBool(SrvType, 'is_tcp'));
        end;
        Out.Add(Item);
      end;
    end;
    Result.Add('servers', Out);
  end else if Kind = 'discarded' then begin
    Kind := JGetStr(JGetObj(State, 'reason'), '@type');
    if Copy(Kind, 1, 17) = 'callDiscardReason' then begin
      Kind := LowerCase(Copy(Kind, 18, MaxInt));
    end;
    Result.Add('reason', string(Kind));
    Result.Add('needRating', JGetBool(State, 'need_rating'));
  end else if Kind = 'error' then begin
    Result.Add('error', string(JGetStr(JGetObj(State, 'error'), 'message')));
  end;
end;

procedure TWebApi.CallChanged(Sender: TObject; ACallId: integer);
var
  C: TJSONObject;
begin
  if not (Sender is TTdCalls) then begin
    Exit;
  end;
  C := TTdCalls(Sender).Find(ACallId);
  if C <> nil then begin
    PushEvent('call', CallToJson(C));
  end;
end;

procedure TWebApi.CallSignal(Sender: TObject; ACallId: integer; const AData: utf8string);
var
  D: TJSONObject;
begin
  D := TJSONObject.Create;
  D.Add('id', ACallId);
  D.Add('data', string(AData));
  PushEvent('call.signal', D);
end;

{ call.list: звонки, которые идут сейчас, — для страницы, открытой или
  перезагруженной посреди звонка (входящий ещё звонит). }
function TWebApi.CmdCallList: TJSONData;
var
  Calls: TTdCalls;
  Arr: TJSONArray;
  I: integer;
  Res: TJSONObject;
begin
  Arr := TJSONArray.Create;
  Calls := TdCallList;
  if Calls <> nil then begin
    for I := 0 to Calls.Count - 1 do begin
      Arr.Add(CallToJson(Calls.CallAt(I)));
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('calls', Arr);
  Result := Res;
end;

{ call.start (userId, video): createCall -> (id). Дальше звонок живёт
  событиями call. }
function TWebApi.CmdCallStart(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Calls: TTdCalls;
  UserId: Int64;
begin
  Result := True;
  Calls := TdCallList;
  if Calls = nil then begin
    raise Exception.Create('not signed in');
  end;
  UserId := ArgId(AArgs, 'userId');
  if UserId <= 0 then begin
    raise Exception.Create('call.start needs a userId');
  end;
  Calls.StartCall(UserId, (AArgs <> nil) and AArgs.Get('video', False),
    @CallStartDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.CallStartDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('id', JGetInt(AResp.Obj, 'id'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ call.accept (id), call.discard (id, duration, video, connectionId,
  disconnected), call.signal (id, data в base64) — ответ (ok). }
function TWebApi.CmdCallSimple(const ACmd: utf8string; AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Calls: TTdCalls;
  Id: integer;
begin
  Result := True;
  Calls := TdCallList;
  if Calls = nil then begin
    raise Exception.Create('not signed in');
  end;
  if AArgs = nil then begin
    raise Exception.Create(string(ACmd) + ' needs an id');
  end;
  Id := integer(ArgId(AArgs, 'id'));
  if Id <= 0 then begin
    raise Exception.Create(string(ACmd) + ' needs an id');
  end;
  if ACmd = 'call.accept' then begin
    Calls.AcceptCall(Id, @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else if ACmd = 'call.discard' then begin
    Calls.DiscardCall(Id, AArgs.Get('disconnected', False),
      AArgs.Get('duration', 0), AArgs.Get('video', False),
      ArgId(AArgs, 'connectionId'),
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else begin
    Calls.SendSignal(Id, utf8string(AArgs.Get('data', '')),
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end;
end;

procedure TWebApi.AuthChanged(Sender: TObject);
begin
  { Every transition to Ready, not just the first: each TDLib client
    has its own "online" option, so a reconnect or a switch to another
    account has to be told again. Exactly what the native window does
    from its own TdStateChanged, and needed here because on the web
    path that window is never built. Resending the same value is
    harmless. }
  if (FAuth <> nil) and (FAuth.State = tasReady) then begin
    TdApplyPresence;
    { And the cache ceiling, for the same reason and with the same
      repetition: it belongs to whichever account just became ready. }
    TdApplyCacheLimit;
  end;
  { Not coalesced like the sticker one: the steps of a sign-in are
    rare, deliberate and each one is the whole screen. }
  PushEvent('auth', nil);
end;

{ A message arrived somewhere. The model has already ruled out our own
  messages and muted chats; what is left is WHERE to say so — and that
  is the page's call, not ours: the page knows whether it is in our
  window (then it asks the shell for a desktop card, ui/shell.js) or in
  a plain browser (its own card, ui/toasts.js), and whether the chat is
  on screen. }
procedure TWebApi.ChatArrived(Sender: TObject; ARow: TChatRow;
  const APreview: utf8string);
var
  Data: TJSONObject;
begin
  if ARow = nil then begin
    Exit;
  end;
  Data := TJSONObject.Create;
  { A number, the same shape chats.list sends an id in - the page
    compares it against the open chat. }
  Data.Add('chatId', ARow.Id);
  Data.Add('title', string(ARow.Title));
  Data.Add('text', string(APreview));
  Data.Add('color', string(AccentKey(ARow)));
  Data.Add('avatar', string(FileUrl(ARow.PhotoFileId, ARow.PhotoPath)));
  { Пока фото не скачано — размытая миниатюра, как у карточки звонка. }
  Data.Add('thumb', string(ThumbDataUri(ARow.Minithumb)));
  PushEvent('arrival', Data);
end;

procedure TWebApi.Enqueue(AConnId: Int64; const AText: utf8string);
var
  R: TWebReq;
begin
  R := TWebReq.Create;
  R.ConnId := AConnId;
  R.Payload := AText;
  FLock.Enter;
  try
    FQueue.Add(R);
  finally
    FLock.Leave;
  end;
  { Wake the main thread NOW rather than leaving the command to sit
    until the next timer tick. TThread.Queue is the right tool and not
    the one this project got burned by: unlike Synchronize it does not
    block the caller at all — it appends an entry that the main
    thread's CheckSynchronize runs later — so the "thread blocked
    inside Synchronize while the main thread waits on it" deadlock has
    no way to happen here. Measured: median command round trip drops
    from ~16 ms (half a tick, on average) to well under a millisecond.
    Extra entries are harmless: whichever Drain runs first empties the
    queue and the rest find it empty. }
  TThread.Queue(nil, @Drain);
end;

procedure TWebApi.Tick(Sender: TObject);
begin
  EnsureBindings;
  Drain;
  if FStickersDirty then begin
    FStickersDirty := False;
    PushEvent('stickers', nil);
  end;
  { Сменился чей-то статус в группе — страница перечитает список
    сообщений, а с ним и join (вступили — кнопка уходит). }
  if FGroupsDirty or FUsersDirty then begin
    FGroupsDirty := False;
    FUsersDirty := False;
    MessagesChanged(nil);
  end;
end;

procedure TWebApi.Drain;
var
  Batch: TFPList;
  I: integer;
  R: TWebReq;
begin
  { The queue is emptied into a local list under the lock and worked on
    outside it: dispatch runs model code of unbounded duration, and
    holding the lock across that would stall the socket threads. }
  Batch := TFPList.Create;
  try
    FLock.Enter;
    try
      if FQueue.Count = 0 then begin
        Exit;
      end;
      for I := 0 to FQueue.Count - 1 do begin
        Batch.Add(FQueue[I]);
      end;
      FQueue.Clear;
    finally
      FLock.Leave;
    end;

    for I := 0 to Batch.Count - 1 do begin
      R := TWebReq(Batch[I]);
      try
        RunCommand(R.ConnId, R.Payload);
      except
        { One bad command must not take the timer, and with it every
          later command, down with it. }
        on E: Exception do begin
          Fail(R.ConnId, 0, utf8string(E.Message));
        end;
      end;
    end;
  finally
    for I := 0 to Batch.Count - 1 do begin
      TObject(Batch[I]).Free;
    end;
    Batch.Free;
  end;
end;

procedure TWebApi.Reply(AConnId: Int64; AReqId: integer; AResult: TJSONData);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', AReqId);
    O.Add('ok', True);
    if AResult = nil then begin
      O.Add('result', TJSONNull.Create);
    end else begin
      { Add takes ownership, so AResult is freed along with O. }
      O.Add('result', AResult);
    end;
    WebSendTo(AConnId, utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

procedure TWebApi.Fail(AConnId: Int64; AReqId: integer; const AError: utf8string);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', AReqId);
    O.Add('ok', False);
    O.Add('error', string(AError));
    WebSendTo(AConnId, utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ commands                                                           }
{ ------------------------------------------------------------------ }

function RequireChats: TTdChats;
begin
  Result := TdChatList;
  if Result = nil then begin
    raise Exception.Create('no active account');
  end;
end;

function RequireMsgs: TTdMessages;
begin
  Result := TdMsgList;
  if Result = nil then begin
    raise Exception.Create('no active account');
  end;
end;

function TWebApi.CmdChatsList(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  Arr: TJSONArray;
  Res, Emoji: TJSONObject;
  CRow: TChatRow;
  I, N, Limit: integer;
  Archived: boolean;
begin
  Chats := RequireChats;

  Archived := False;
  Limit := 0;
  if AArgs <> nil then begin
    Archived := AArgs.Get('archived', False);
    Limit := AArgs.Get('limit', 0);
  end;

  if Archived then begin
    N := Chats.ArchiveCount;
  end else begin
    N := Chats.Count;
  end;

  Arr := TJSONArray.Create;
  Emoji := TJSONObject.Create;
  try
    for I := 0 to N - 1 do begin
      if (Limit > 0) and (Arr.Count >= Limit) then begin
        Break;
      end;
      if Archived then begin
        CRow := Chats.ArchiveRows[I];
      end else begin
        CRow := Chats.Rows[I];
      end;
      Arr.Add(RowToJson(Chats, CRow));
      CollectChatCustomEmoji(Emoji, CRow);
    end;
  except
    Arr.Free;
    Emoji.Free;
    raise;
  end;

  Res := TJSONObject.Create;
  Res.Add('total', N);
  Res.Add('loading', Chats.Loading);
  Res.Add('items', Arr);
  Res.Add('customEmoji', Emoji);
  Result := Res;
end;

{ Avatars for the rows the page currently shows. The web equivalent of
  framechats calling EnsureAvatar from its cell painter: bounded by
  what is on screen, rather than by how many chats exist. }
function TWebApi.CmdChatsAvatars(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  Arr: TJSONArray;
  CRow: TChatRow;
  I: integer;
begin
  Chats := RequireChats;
  if AArgs = nil then begin
    Exit(nil);
  end;
  Arr := TJSONArray(AArgs.Find('ids', jtArray));
  if Arr = nil then begin
    Exit(nil);
  end;
  for I := 0 to Arr.Count - 1 do begin
    CRow := Chats.Lookup(Arr.Int64s[I]);
    if CRow <> nil then begin
      Chats.EnsureAvatar(CRow);
      Chats.EnsureAvatarAnim(CRow);
      { The custom emoji of the rows on screen, fetched here for the
        same reason the avatars are: bounded by what is visible rather
        than by how many chats exist. The URLs themselves ride back in
        the next chats.list, as the avatars do. }
      Chats.EnsureCustomEmojiForRow(CRow);
    end;
  end;
  Result := nil;
end;

function TWebApi.CmdChatsMore(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  Archived: boolean;
begin
  Chats := RequireChats;
  Archived := (AArgs <> nil) and AArgs.Get('archived', False);
  if Archived then begin
    Chats.LoadMoreArchive;
  end else begin
    Chats.LoadMore;
  end;
  Result := nil;
end;

function TWebApi.CmdChatOpen(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  ChatId, JumpTo, UnreadFrom: Int64;
  CRow: TChatRow;
begin
  if AArgs = nil then begin
    raise Exception.Create('chat.open needs an id');
  end;
  Msgs := RequireMsgs;
  Chats := RequireChats;
  ChatId := AArgs.Get('id', Int64(0));
  JumpTo := AArgs.Get('jumpTo', Int64(0));

  { The unread marker comes from the chat row, not from the history
    model: TTdMessages has no chat list of its own to look it up in.
    Same split as TFrameHistory.OpenChat - and the same two conditions
    it applies. Only when something is actually unread: in a chat that
    is fully read last_read_inbox_message_id IS the newest message, and
    asking the model to reach back past it sends it hunting for a
    boundary it already stands on. And not at all when the caller named
    a message: following a quote is a deliberate destination, the
    marker is only a default one. }
  UnreadFrom := 0;
  if JumpTo = 0 then begin
    CRow := Chats.Lookup(ChatId);
    if (CRow <> nil) and (CRow.UnreadCount > 0) then begin
      UnreadFrom := CRow.LastReadInbox;
    end;
  end;

  { OPENING A CHAT THE MODEL ALREADY HAS OPEN IS A NO-OP INSIDE THE
    MODEL, and that is the case that left a long history standing:
    a page reloaded and picked the same chat, a second page catching up
    with the first, the native window having been there before either.
    Switching between two chats cleared everything and looked right;
    coming back to one that never left did not.

    Opening is the reader saying "show me this chat", and that starts
    at the first page. Not when a message was named, though - following
    a quote into the chat you are already in must not throw away the
    range that message sits in. }
  if (Msgs.ChatId = ChatId) and (JumpTo = 0) then begin
    Msgs.TrimOlder(TRIM_KEEP);
  end;
  Msgs.OpenChat(ChatId, JumpTo, UnreadFrom);
  Result := CmdMessagesList;
end;

function TWebApi.CmdChatClose: TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  Msgs.CloseChat;
  Result := nil;
end;

function TWebApi.CmdChatAction(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  CRow: TChatRow;
  Action: utf8string;
begin
  if AArgs = nil then begin
    raise Exception.Create('chat.action needs an id and an action');
  end;
  Chats := RequireChats;
  CRow := Chats.Lookup(AArgs.Get('id', Int64(0)));
  if CRow = nil then begin
    raise Exception.Create('no such chat');
  end;
  Action := utf8string(AArgs.Get('action', ''));

  if Action = 'mute' then begin
    Chats.SetMuted(CRow, True);
  end else if Action = 'unmute' then begin
    Chats.SetMuted(CRow, False);
  end else if Action = 'pin' then begin
    Chats.SetPinned(CRow, True);
  end else if Action = 'unpin' then begin
    Chats.SetPinned(CRow, False);
  end else if Action = 'archive' then begin
    Chats.SetArchived(CRow, True);
  end else if Action = 'unarchive' then begin
    Chats.SetArchived(CRow, False);
  end else if Action = 'read' then begin
    Chats.MarkAsRead(CRow);
  end else if Action = 'unread' then begin
    Chats.MarkAsUnread(CRow);
  end else begin
    raise Exception.Create('unknown chat action: ' + Action);
  end;
  Result := nil;
end;

{ The account's chat folders, in the order TDLib lists them - which is
  the order the user arranged their own folder tabs in.

  A command of its own rather than a field folded into chats.list: this
  is one short answer for the whole account, not a property of a row,
  and the page needs it only when a folder menu is actually opened.

  The folders carry no icon here, and cannot: TDLib describes a folder's
  icon by NAME only (chatFolderIcon is a string out of a fixed set -
  "Work", "Airplane", "Custom"...), never a picture, so showing them
  would mean shipping one icon per name. Same reason the native menu
  shows none. }
function TWebApi.CmdChatsFolders: TJSONData;
var
  Chats: TTdChats;
  Arr: TJSONArray;
  O: TJSONObject;
  I: integer;
  F: TChatFolder;
begin
  Chats := RequireChats;
  Arr := TJSONArray.Create;
  for I := 0 to Chats.FolderCount - 1 do begin
    F := Chats.Folders[I];
    O := TJSONObject.Create;
    { TDLib never assigns 0 as a folder id, which is what leaves 0 free
      to mean "no folder" in both directions of this protocol. }
    O.Add('id',    F.Id);
    O.Add('title', string(F.Title));
    Arr.Add(O);
  end;
  Result := Arr;
end;

{ Moves the chat into AFolderId, or - for 0 - takes it out of every
  folder it is in. One command for both because 0 is the same "no
  folder" the row already reports: the page can send back the id it was
  handed without a separate command for the empty case.

  Caveat inherited from the model, not introduced here: a chat a folder
  includes BY RULE (include_groups and the like) stays in it. TDLib has
  no removeChatFromList at all, and writing the chat into
  excluded_chat_ids to force it out would override the user's own filter
  far more durably than "it lives in another folder now" asks for. }
function TWebApi.CmdChatFolderSet(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  CRow: TChatRow;
  FolderId: integer;
begin
  if AArgs = nil then begin
    raise Exception.Create('chat.folder.set needs an id and a folderId');
  end;
  Chats := RequireChats;
  CRow := Chats.Lookup(AArgs.Get('id', Int64(0)));
  if CRow = nil then begin
    raise Exception.Create('no such chat');
  end;
  FolderId := AArgs.Get('folderId', 0);
  if FolderId = 0 then begin
    Chats.RemoveChatFromFolders(CRow);
  end else begin
    Chats.MoveChatToFolder(CRow, FolderId);
  end;
  { Nothing to return: the row updates itself when TDLib reports the new
    positions, and that arrives as the usual chats-changed event. }
  Result := nil;
end;

{ Creates a folder holding just this chat, taking it out of its current
  ones the way chat.folder.set would.

  The length limit is checked HERE rather than left to TDLib, and it is
  counted in CHARACTERS: chatFolderName allows 1..12 characters, while a
  Cyrillic name is two bytes per character - so Length() on the
  utf8string would reject valid names and let through invalid ones.
  Counting out continuation bytes (10xxxxxx) is all that takes, which is
  also what the native window does rather than pull in LazUTF8 for one
  call. }
function TWebApi.CmdChatFolderCreate(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  CRow: TChatRow;
  Title: utf8string;
  I, Chars: integer;
begin
  if AArgs = nil then begin
    raise Exception.Create('chat.folder.create needs an id and a title');
  end;
  Chats := RequireChats;
  CRow := Chats.Lookup(AArgs.Get('id', Int64(0)));
  if CRow = nil then begin
    raise Exception.Create('no such chat');
  end;

  Title := utf8string(Trim(string(AArgs.Get('title', ''))));
  if Title = '' then begin
    raise Exception.Create('a folder needs a name');
  end;
  Chars := 0;
  for I := 1 to Length(Title) do begin
    if (Ord(Title[I]) and $C0) <> $80 then begin
      Inc(Chars);
    end;
  end;
  if Chars > CHATROW_FOLDER_NAME_MAX then begin
    raise Exception.Create('a folder name is at most '
      + utf8string(IntToStr(CHATROW_FOLDER_NAME_MAX)) + ' characters');
  end;

  Chats.CreateFolderWithChat(Title, CRow);
  { Again nothing to return: TDLib answers with a fresh
    updateChatFolders, and the page picks the new folder up with the
    next chats.folders. }
  Result := nil;
end;

function TWebApi.CmdMessagesList: TJSONData;
var
  Msgs: TTdMessages;
  KbRaw: utf8string;
  ReplyKb: TJSONObject;
  Chats: TTdChats;
  CRow: TChatRow;
  Arr: TJSONArray;
  Res, Emoji, Sub: TJSONObject;
  I: integer;
  LastReadOutbox: Int64;
  MustJoin, ByRequest: boolean;
  Join: TJSONObject;
  JoinOk: boolean;
begin
  Msgs := RequireMsgs;

  LastReadOutbox := 0;
  Chats := TdChatList;
  if (Chats <> nil) and (Msgs.ChatId <> 0) then begin
    CRow := Chats.Lookup(Msgs.ChatId);
    if CRow <> nil then begin
      LastReadOutbox := CRow.LastReadOutbox;
    end;
  end;

  Arr := TJSONArray.Create;
  Emoji := TJSONObject.Create;
  try
    for I := 0 to Msgs.Count - 1 do begin
      { Custom emoji used in the text, fetched the same way the native
        window does it for visible rows: unconditionally, no
        auto-download gate. Idempotent, so calling it on every
        serialisation costs nothing after the first. }
      Msgs.EnsureCustomEmojiForRow(Msgs.Rows[I]);
      Arr.Add(MsgToJson(Msgs, Msgs.Rows[I], LastReadOutbox));
      CollectMsgCustomEmoji(Emoji, Msgs.Rows[I]);
      CollectMarkupEmoji(Msgs, Emoji, Msgs.Rows[I].ReplyMarkupRaw);
    end;
  except
    Arr.Free;
    Emoji.Free;
    raise;
  end;

  Res := TJSONObject.Create;
  { Turned to False by ToDelta on a refresh. The page replaces its
    list on a full answer and merges on a partial one. }
  Res.Add('full',         True);
  Res.Add('chatId',       Msgs.ChatId);
  { Расшифровка голосовых — только у Premium (recognizeSpeech без него
    отвечает ошибкой): без Premium страница кнопку не показывает. }
  Res.Add('canTranscribe', (TdApp.Active <> nil) and TdApp.Active.IsPremium);
  { The open chat's own row, for the bar above the history.

    The page looks the open chat up in the list it holds, and the chat
    reached by following a forward or a quote need not be in that list
    at all - a channel this account does not follow has a row here
    (updateNewChat makes one for any chat TDLib mentions) but no place
    in the list, so the list will never grow one. Without this the bar
    concluded there was no chat and hid itself, leaving a blank strip
    over real messages. Same reason the thread descriptor below
    exists. }
  if (Chats <> nil) and (Msgs.ChatId <> 0) then begin
    CRow := Chats.Lookup(Msgs.ChatId);
    if CRow <> nil then begin
      { Its picture has usually never been asked for, for the same
        reason: nothing has ever drawn this chat. }
      Chats.EnsureAvatar(CRow);
      Chats.EnsureAvatarAnim(CRow);
      Res.Add('chat', RowToJson(Chats, CRow));
      { Клавиатура бота над полем ввода: своя разметка чата, а нет её —
        у загруженного сообщения, на которое указывает чат. }
      KbRaw := CRow.ReplyMarkupRaw;
      if (KbRaw = '') and (CRow.ReplyMarkupMsgId <> 0)
         and (Msgs.IndexOfId(CRow.ReplyMarkupMsgId) >= 0) then begin
        KbRaw := Msgs.Rows[Msgs.IndexOfId(CRow.ReplyMarkupMsgId)].ReplyMarkupRaw;
      end;
      ReplyKb := ReplyKeyboardJson(KbRaw, CRow.ReplyMarkupMsgId);
      CollectMarkupEmoji(Msgs, Emoji, KbRaw);
      if ReplyKb <> nil then begin
        Res.Add('replyKeyboard', ReplyKb);
      end;
    end;
  end;
  { Comment thread, or nothing. The page cannot work this out for
    itself: the chat now open is the DISCUSSION group, which may not
    even be in the user's chat list - so the header and the composer
    would have no row to read and would show a dead bar. }
  if Msgs.ThreadPostId <> 0 then begin
    Sub := TJSONObject.Create;
    Sub.Add('postId',  Msgs.ThreadPostId);
    Sub.Add('postChatId', Msgs.ThreadChatId);
    CRow := Chats.Lookup(Msgs.ChatId);
    if CRow <> nil then begin
      Sub.Add('title',   string(CRow.Title));
      Sub.Add('canSend', CRow.CanSendBasicMessages);
      { The bar above the thread belongs to the DISCUSSION GROUP - that
        is whose messages these are. It used to wear the channel's
        name and picture, which said the wrong thing about where the
        reader was. }
      { The group is rarely in the visible part of the list, so its
        picture has usually never been asked for. Asked now: it rides
        back in the next messages.list, like every other avatar. }
      Chats.EnsureAvatar(CRow);
      Sub.Add('avatar',  string(FileUrl(CRow.PhotoFileId, CRow.PhotoPath)));
      Sub.Add('color',   string(AccentKey(CRow)));
      Sub.Add('chatId',  CRow.Id);
    end else begin
      { Not in the list - the ordinary case for a discussion group
        nobody has joined. }
      Sub.Add('title',   '');
      Sub.Add('canSend', True);
    end;
    { Some discussion groups want you in before you may write
      (supergroup.join_to_send_messages). That is NOT the same as "you
      may not write here", and the official clients say so with a join
      button instead of a dead input box - so the page is told which of
      the two it is, and whether joining needs approval. }
    MustJoin := False;
    ByRequest := False;
    if (CRow <> nil) and (CRow.SupergroupId <> 0)
       and (TdSupergroupList <> nil) then begin
      MustJoin := TdSupergroupList.MustJoinToSend(CRow.SupergroupId, ByRequest);
    end;
    Sub.Add('mustJoin',  MustJoin);
    Sub.Add('byRequest', ByRequest);
    CRow := Chats.Lookup(Msgs.ThreadChatId);
    if CRow <> nil then begin
      Sub.Add('postChatTitle', string(CRow.Title));
    end;
    Res.Add('thread', Sub);
  end;
  { Канал или группа, в которых аккаунт не состоит (до них дошли по
    пересылке или ссылке), — страница ставит на место поля ввода кнопку
    вступления. В ветке комментариев своё правило — thread.mustJoin. }
  Join := TJSONObject.Create;
  JoinOk := False;
  ByRequest := False;
  CRow := Chats.Lookup(Msgs.ChatId);
  if (Msgs.ThreadChatId = 0) and (CRow <> nil) and (CRow.SupergroupId <> 0)
     and (TdSupergroupList <> nil) then begin
    JoinOk := TdSupergroupList.CanJoin(CRow.SupergroupId, ByRequest);
  end;
  Join.Add('can', JoinOk);
  Join.Add('byRequest', ByRequest);
  Join.Add('channel', (CRow <> nil) and (CRow.Kind = ckChannel));
  Res.Add('join', Join);
  Res.Add('unreadFrom',   Msgs.UnreadFromId);
  Res.Add('unreadReady',  Msgs.UnreadReady);
  Res.Add('unreadCovered', Msgs.UnreadCovered);
  Res.Add('loadingOlder', Msgs.LoadingOlder);
  Res.Add('oldestLoaded', Msgs.OldestLoaded);
  Res.Add('searchActive', Msgs.SearchActive);
  Res.Add('searchFilter', string(Msgs.SearchFilter));
  Res.Add('searchQuery',  string(Msgs.SearchQuery));
  Res.Add('customEmoji', Emoji);
  Res.Add('searchTotal',  Msgs.SearchTotalCount);
  Res.Add('items',        Arr);
  Result := Res;
end;

function TWebApi.CmdMessagesOlder: TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  Msgs.LoadOlder;
  Result := nil;
end;

{ Open the comment thread of a post, and come back out of it.

  Both answer with the message list, exactly as chat.open does, so the
  page applies the result the same way and does not need a second code
  path for "the history changed". }
function TWebApi.CmdThreadOpen(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    raise Exception.Create('thread.open needs a message id');
  end;
  { The post is in the chat that is open right now - the button that
    sends this lives on one of its messages. }
  Msgs.OpenThread(Msgs.ChatId, AArgs.Get('id', Int64(0)));
  Result := CmdMessagesList;
end;

{ Join the group whose thread is open - the answer to "you must join
  before you can comment". Which of the two it turns out to be (joined
  outright, or a request sent for approval) is TDLib's to say, so the
  answer is passed straight back for the page to word. }
function TWebApi.CmdChatJoin(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Id: Int64;
begin
  Msgs := RequireMsgs;
  Id := 0;
  if AArgs <> nil then begin
    Id := AArgs.Get('id', Int64(0));
  end;
  if Id = 0 then begin
    Id := Msgs.ChatId;
  end;
  if Id = 0 then begin
    raise Exception.Create('no chat to join');
  end;
  Msgs.JoinChat(Id);
  Result := nil;
end;

{ thread.jump (messageId) — к сообщению внутри открытой ветки (цитата
  в комментарии). chat.open с jumpTo тут не годится: он открыл бы группу
  обсуждения обычным чатом и вывел из ветки. }
function TWebApi.CmdThreadJump(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  if Msgs.ThreadId = 0 then begin
    raise Exception.Create('no comment thread is open');
  end;
  Msgs.JumpTo(ArgId(AArgs, 'messageId'));
  Result := CmdMessagesList;
end;

function TWebApi.CmdThreadClose: TJSONData;
begin
  RequireMsgs.CloseThread;
  Result := CmdMessagesList;
end;

{ Online / Invisible. The setting lives in tdcore, which also
  remembers it and tells TDLib; what happens here is only the page's
  half of the conversation.

  The answer carries the value rather than just an ok, so a page that
  has just switched and a page that only asked get their state from
  the same place. }
function TWebApi.CmdPresenceGet: TJSONData;
var
  Res: TJSONObject;
begin
  Res := TJSONObject.Create;
  Res.Add('invisible', TdPresenceInvisible);
  Result := Res;
end;

function TWebApi.CmdPresenceSet(AArgs: TJSONObject): TJSONData;
var
  Data: TJSONObject;
begin
  if AArgs = nil then begin
    raise Exception.Create('presence.set needs a value');
  end;
  TdSetPresence(AArgs.Get('invisible', False));
  { Anyone else with the page open is looking at the same account, so
    they are told too - the same reasoning as every other push here. }
  Data := TJSONObject.Create;
  Data.Add('invisible', TdPresenceInvisible);
  PushEvent('presence', Data);
  Result := CmdPresenceGet;
end;

{ ------------------------------------------------------------------ }
{ settings                                                           }
{ ------------------------------------------------------------------ }

{ Всё, что показывает страница настроек, одним ответом. Пределы едут
  вместе со значениями: они в constants.pas, и страница не должна
  держать вторую их копию.

  Сетка автозагрузки — списком включённых клеток "media.chat", а виды
  медиа и чатов — с подписями из тех же констант, что у нативного
  диалога: добавленный вид появится на странице сам. }
function TWebApi.CmdSettingsGet: TJSONData;
var
  Res, Downloads, Cache, AutoDl, Item, Notify: TJSONObject;
  Media, Chats, OnList: TJSONArray;
  M, C: integer;
begin
  Res := TJSONObject.Create;
  Res.Add('closeToTray', TdCloseToTray);
  Res.Add('deviceModel', TdApp.DeviceModel);

  Notify := TJSONObject.Create;
  Notify.Add('enabled', TdDeskNotify);
  Notify.Add('corner', DESKNOTIFY_CORNERS[TdDeskNotifyCorner]);
  Notify.Add('limit', TdDeskNotifyLimit);
  Notify.Add('limitMin', DESKNOTIFY_LIMIT_MIN);
  Notify.Add('limitMax', DESKNOTIFY_LIMIT_MAX);
  Notify.Add('titleFont', TdDeskNotifyTitleFont);
  Notify.Add('textFont', TdDeskNotifyTextFont);
  Notify.Add('fontMin', DESKNOTIFY_FONT_MIN);
  Notify.Add('fontMax', DESKNOTIFY_FONT_MAX);
  Res.Add('notify', Notify);
  { Где открывать точку геопозиции; '' — спрашивать каждый раз. }
  Res.Add('mapsProvider', TdMapsProvider);

  Downloads := TJSONObject.Create;
  Downloads.Add('concurrency', tdmessages.DownloadConcurrency);
  Downloads.Add('concurrencyMin', DOWNLOAD_CONCURRENCY_MIN);
  Downloads.Add('concurrencyMax', DOWNLOAD_CONCURRENCY_MAX);
  Downloads.Add('speedKb', tdmessages.DownloadSpeedLimit);
  Downloads.Add('speedKbMin', DOWNLOAD_SPEED_MIN_KB);
  Downloads.Add('speedKbMax', DOWNLOAD_SPEED_MAX_KB);
  Res.Add('downloads', Downloads);

  Cache := TJSONObject.Create;
  Cache.Add('limitMb', TdCacheLimitMB);
  Cache.Add('limitMbMin', CACHE_LIMIT_MIN_MB);
  Cache.Add('limitMbMax', CACHE_LIMIT_MAX_MB);
  Cache.Add('ttlDays', TdCacheTtlDays);
  Cache.Add('ttlDaysMin', CACHE_TTL_MIN_DAYS);
  Cache.Add('ttlDaysMax', CACHE_TTL_MAX_DAYS);
  Res.Add('cache', Cache);

  AutoDl := TJSONObject.Create;
  Media := TJSONArray.Create;
  for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
    Item := TJSONObject.Create;
    Item.Add('kind', AUTODL_MEDIA_KINDS[M]);
    Item.Add('label', AUTODL_MEDIA_CAPTIONS[M]);
    Media.Add(Item);
  end;
  Chats := TJSONArray.Create;
  for C := 0 to High(AUTODL_CHAT_KINDS) do begin
    Item := TJSONObject.Create;
    Item.Add('kind', AUTODL_CHAT_KINDS[C]);
    Item.Add('label', AUTODL_CHAT_CAPTIONS[C]);
    Chats.Add(Item);
  end;
  OnList := TJSONArray.Create;
  for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
    for C := 0 to High(AUTODL_CHAT_KINDS) do begin
      if AutoDownloadEnabled(AUTODL_MEDIA_KINDS[M], AUTODL_CHAT_KINDS[C]) then begin
        OnList.Add(AUTODL_MEDIA_KINDS[M] + '.' + AUTODL_CHAT_KINDS[C]);
      end;
    end;
  end;
  AutoDl.Add('media', Media);
  AutoDl.Add('chats', Chats);
  AutoDl.Add('on', OnList);
  Res.Add('autodownload', AutoDl);

  Result := Res;
end;

{ Одна настройка за вызов: key и value, у автозагрузки ещё media и
  chat. Ответ — все настройки целиком, уже после зажима, так что поле,
  в которое ввели 500 при пределе 20, покажет 20. Остальным открытым
  страницам — то же самое событием. }
function TWebApi.CmdSettingsSet(AArgs: TJSONObject): TJSONData;
var
  Key, Model, Code: utf8string;
  I, Corner: integer;
begin
  if AArgs = nil then begin
    raise Exception.Create('settings.set needs a key');
  end;
  Key := AArgs.Get('key', utf8string(''));
  if Key = 'closeToTray' then begin
    TdSetCloseToTray(AArgs.Get('value', True));
  end else if Key = 'deviceModel' then begin
    { Пустое имя устройства TDLib не нужно — как и нативное поле, его
      не сохраняем. Применяется к следующей сессии, см. SetDeviceModel. }
    Model := utf8string(Trim(string(AArgs.Get('value', utf8string('')))));
    if Model = '' then begin
      raise Exception.Create('Device name cannot be empty');
    end;
    TdApp.SetDeviceModel(Model);
  end else if Key = 'notify.enabled' then begin
    TdSetDeskNotify(AArgs.Get('value', True));
  end else if Key = 'notify.corner' then begin
    Code := AArgs.Get('value', utf8string(''));
    Corner := -1;
    for I := Low(DESKNOTIFY_CORNERS) to High(DESKNOTIFY_CORNERS) do begin
      if DESKNOTIFY_CORNERS[I] = Code then begin
        Corner := I;
      end;
    end;
    if Corner < 0 then begin
      raise Exception.Create('unknown corner: ' + string(Code));
    end;
    TdSetDeskNotifyCorner(Corner);
  end else if Key = 'maps.provider' then begin
    Code := AArgs.Get('value', utf8string(''));
    Corner := -1;
    for I := Low(MAPS_PROVIDERS) to High(MAPS_PROVIDERS) do begin
      if MAPS_PROVIDERS[I] = Code then begin
        Corner := I;
      end;
    end;
    if (Code <> '') and (Corner < 0) then begin
      raise Exception.Create('unknown maps service: ' + string(Code));
    end;
    TdSetMapsProvider(string(Code));
  end else if Key = 'notify.titleFont' then begin
    TdSetDeskNotifyTitleFont(AArgs.Get('value', DESKNOTIFY_TITLE_FONT_DEFAULT));
  end else if Key = 'notify.textFont' then begin
    TdSetDeskNotifyTextFont(AArgs.Get('value', DESKNOTIFY_TEXT_FONT_DEFAULT));
  end else if Key = 'notify.limit' then begin
    TdSetDeskNotifyLimit(AArgs.Get('value', DESKNOTIFY_LIMIT_DEFAULT));
  end else if Key = 'downloads.concurrency' then begin
    TdSetDownloadConcurrency(AArgs.Get('value', DOWNLOAD_CONCURRENCY_DEFAULT));
  end else if Key = 'downloads.speedKb' then begin
    TdSetDownloadSpeedKB(AArgs.Get('value', DOWNLOAD_SPEED_DEFAULT_KB));
  end else if Key = 'cache.limitMb' then begin
    TdSetCacheLimitMB(AArgs.Get('value', CACHE_LIMIT_DEFAULT_MB));
  end else if Key = 'cache.ttlDays' then begin
    TdSetCacheTtlDays(AArgs.Get('value', CACHE_TTL_DEFAULT_DAYS));
  end else if Key = 'autodownload' then begin
    SetAutoDownloadEnabled(string(AArgs.Get('media', utf8string(''))),
      string(AArgs.Get('chat', utf8string(''))), AArgs.Get('value', False));
  end else begin
    raise Exception.Create('unknown setting: ' + string(Key));
  end;
  PushEvent('settings', TJSONObject(CmdSettingsGet));
  Result := CmdSettingsGet;
end;

{ Состояние кэша TDLib. Числа — последний известный ответ; свежие
  запрашиваются в CmdStorageGet и приезжают событием 'storage', когда
  TDLib ответит. }
function StorageJson: TJSONObject;
var
  St: TTdStorageStats;
begin
  St := TdCache.Stats;
  Result := TJSONObject.Create;
  Result.Add('known', St.Known);
  Result.Add('filesSize', St.FilesSize);
  Result.Add('fileCount', St.FileCount);
  Result.Add('databaseSize', St.DatabaseSize);
  Result.Add('logSize', St.LogSize);
  Result.Add('busy', TdCache.Busy);
  Result.Add('error', TdCache.LastError);
  Result.Add('freed', TdCache.LastFreed);
  Result.Add('freedCount', TdCache.LastFreedCount);
end;

{ Подписка на TdCache.OnChanged ставится заново при каждом вопросе:
  у события один слушатель, и нативная секция Storage, если её
  открыть, забирает его себе, а при закрытии обнуляет. Страница
  спрашивает при каждом заходе в раздел — этого хватает, чтобы
  подписка была на месте, когда она нужна. }
function TWebApi.CmdStorageGet: TJSONData;
begin
  TdCache.OnChanged := @StorageChanged;
  TdCache.RefreshStats;
  Result := StorageJson;
end;

{ Те же пределы, что применяются на старте, — из файла, а не из полей
  страницы: каждое поле уже сохранило себя при изменении. }
function TWebApi.CmdStorageCleanup: TJSONData;
begin
  TdCache.OnChanged := @StorageChanged;
  TdCache.Cleanup(TdCacheLimitMB, TdCacheTtlDays);
  Result := StorageJson;
end;

procedure TWebApi.StorageChanged(Sender: TObject);
begin
  PushEvent('storage', StorageJson);
end;

{ The reader is back at the newest end, and the pages they scrolled
  past on the way are of no use to anyone. Answers with the list, like
  chat.open does, so the page applies the shorter history the same way
  it applies any other change. }
function TWebApi.CmdMessagesTrim: TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  if Msgs.Count > TRIM_AT then begin
    Msgs.TrimOlder(TRIM_KEEP);
  end;
  Result := CmdMessagesList;
end;

function TWebApi.CmdMessagesRead(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Arr: TJSONArray;
  Ids: array of Int64;
  I: integer;
begin
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    Exit(nil);
  end;
  Arr := TJSONArray(AArgs.Find('ids', jtArray));
  if (Arr = nil) or (Arr.Count = 0) then begin
    Exit(nil);
  end;
  SetLength(Ids, Arr.Count);
  for I := 0 to Arr.Count - 1 do begin
    Ids[I] := Arr.Int64s[I];
  end;
  Msgs.MarkRead(Ids);
  Result := nil;
end;

function TWebApi.CmdMessageSend(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Text: utf8string;
begin
  Msgs := RequireMsgs;
  if Msgs.ChatId = 0 then begin
    raise Exception.Create('no chat is open');
  end;
  if AArgs = nil then begin
    raise Exception.Create('message.send needs text');
  end;
  Text := utf8string(AArgs.Get('text', ''));
  if Trim(Text) = '' then begin
    raise Exception.Create('empty message');
  end;
  Msgs.SendFormattedText(Text, AArgs.Get('html', False),
    AArgs.Get('silent', False),
    { As TEXT: a message id is a full Int64 and JSON numbers stop being
      exact at 2^53 - the same rule ids follow everywhere else here. }
    StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
  Result := nil;
end;

{ Файлы, уже принятые через POST /upload: страница присылает их id
  (не пути — путь на диске она не видит), сервер находит файлы и
  отдаёт модели. asPhoto — сжатыми фото, иначе документами; caption —
  разметка в том же синтаксисе, что текст сообщения (html — какой).

  Неизвестный id — ошибка всей команды, а не тихий пропуск: иначе
  ушла бы часть файлов, а человек думал бы, что все. }
function TWebApi.CmdMessageSendFiles(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Arr: TJSONArray;
  Paths: array of utf8string;
  Extras: array of utf8string;
  Meta: TJSONArray;
  M: TJSONObject;
  ThumbPath: string;
  ThumbJson: TJSONString;
  ThumbStr: utf8string;
  Mode: utf8string;
  I: integer;
  Path: string;
begin
  Msgs := RequireMsgs;
  if Msgs.ChatId = 0 then begin
    raise Exception.Create('no chat is open');
  end;
  if AArgs = nil then begin
    raise Exception.Create('message.sendFiles needs files');
  end;
  Arr := TJSONArray(AArgs.Find('files', jtArray));
  if (Arr = nil) or (Arr.Count = 0) then begin
    raise Exception.Create('no files to send');
  end;
  SetLength(Paths, Arr.Count);
  for I := 0 to Arr.Count - 1 do begin
    Path := UploadFilePath(Arr.Strings[I]);
    if Path = '' then begin
      raise Exception.Create('uploaded file not found');
    end;
    Paths[I] := utf8string(Path);
  end;
  { mode: media | document | audio (меню скрепки); прежнее asPhoto —
    то же, что media. }
  Mode := utf8string(AArgs.Get('mode', ''));
  if Mode = '' then begin
    if AArgs.Get('asPhoto', False) then begin
      Mode := 'media';
    end else begin
      Mode := 'document';
    end;
  end;
  { meta — на каждый файл сведения о видео от страницы (длительность,
    размеры, миниатюра из кадра — загружена как отдельный файл) или null.
    Превращаются в поля inputVideo / inputThumbnail (td_api.tl). }
  SetLength(Extras, Arr.Count);
  Meta := TJSONArray(AArgs.Find('meta', jtArray));
  for I := 0 to Arr.Count - 1 do begin
    Extras[I] := '';
    if (Meta = nil) or (I >= Meta.Count) or not (Meta.Items[I] is TJSONObject) then begin
      Continue;
    end;
    M := TJSONObject(Meta.Items[I]);
    if (M.Get('w', 0) > 0) and (M.Get('h', 0) > 0) then begin
      Extras[I] := ',"duration":' + utf8string(IntToStr(M.Get('duration', 0))) +
        ',"width":' + utf8string(IntToStr(M.Get('w', 0))) +
        ',"height":' + utf8string(IntToStr(M.Get('h', 0)));
    end;
    ThumbPath := UploadFilePath(M.Get('thumb', ''));
    if ThumbPath <> '' then begin
      ThumbJson := TJSONString.Create(ThumbPath);
      try
        ThumbStr := utf8string(ThumbJson.AsJSON);
      finally
        ThumbJson.Free;
      end;
      Extras[I] := Extras[I] + ',"thumbnail":{"@type":"inputThumbnail","thumbnail":' +
        '{"@type":"inputFileLocal","path":' + ThumbStr + '}' +
        ',"width":' + utf8string(IntToStr(M.Get('tw', 0))) +
        ',"height":' + utf8string(IntToStr(M.Get('th', 0))) + '}';
    end;
  end;
  Msgs.SendFiles(Paths, Extras, Mode,
    utf8string(AArgs.Get('caption', '')), AArgs.Get('html', False),
    AArgs.Get('silent', False),
    StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
  Result := nil;
end;

{ Клик по кольцу хода: скачивание останавливается, исходящее с
  незакончившейся закачкой удаляется (см. TTdMessages.CancelTransfer). }
function TWebApi.CmdCancelTransfer(AArgs: TJSONObject): TJSONData;
begin
  if AArgs = nil then begin
    raise Exception.Create('message.cancelTransfer needs a message id');
  end;
  RequireMsgs.CancelTransfer(AArgs.Get('id', Int64(0)));
  Result := nil;
end;

function TWebApi.CmdPollVote(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Idx, I: integer;
  Arr: TJSONArray;
  Options: array of integer;
  Row: TMsgRow;
begin
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    raise Exception.Create('poll.vote needs a message id');
  end;
  Idx := Msgs.IndexOfId(AArgs.Get('id', Int64(0)));
  if Idx < 0 then begin
    raise Exception.Create('message not loaded');
  end;
  Row := Msgs.Rows[Idx];

  Arr := TJSONArray(AArgs.Find('options', jtArray));
  if Arr = nil then begin
    { A single tapped option — let the model work out the resulting
      set, exactly as the native widget's click does. }
    Msgs.SetPollAnswer(Row, AArgs.Get('option', -1));
  end else begin
    SetLength(Options, Arr.Count);
    for I := 0 to Arr.Count - 1 do begin
      Options[I] := Arr.Integers[I];
    end;
    Msgs.SetPollAnswers(Row, Options);
  end;
  Result := nil;
end;

function TWebApi.CmdMediaEnsure(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Idx: integer;
  Row: TMsgRow;
  What: utf8string;
begin
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    raise Exception.Create('media.ensure needs a message id');
  end;
  Idx := Msgs.IndexOfId(AArgs.Get('id', Int64(0)));
  if Idx < 0 then begin
    raise Exception.Create('message not loaded');
  end;
  Row := Msgs.Rows[Idx];
  What := utf8string(AArgs.Get('what', ''));

  { 'preview' is what a row asks for when it scrolls into view;
    'full' is the deliberate one (open it, save it). Keeping them apart
    is the same split the native window makes between the medium photo
    layer it shows inline and the original it opens. }
  if What = 'full' then begin
    case Row.Kind of
      mckPhoto: Msgs.EnsurePhotoBestFile(Row);
      mckVideo: Msgs.EnsureVideoFile(Row);
      mckAudio, mckVoiceNote: Msgs.EnsurePlayableFile(Row);
      mckFile:  Msgs.EnsureDocFile(Row);
      mckAnimation: Msgs.EnsureAnimFile(Row);
    end;
  end else if What = 'link' then begin
    { A text message has no Kind to switch on - the preview's picture
      is asked for by name. }
    Msgs.EnsureLinkFile(Row);
  end else begin
    case Row.Kind of
      mckPhoto: Msgs.EnsurePhotoFile(Row);
      mckVideo: Msgs.EnsureVideoThumbFile(Row);
      mckAudio: Msgs.EnsureAudioCoverFile(Row);
      mckVoiceNote: Msgs.EnsureVoiceFile(Row);
      mckAnimation: Msgs.EnsureAnimFile(Row);
      mckSticker: Msgs.EnsureStickerFile(Row);
    end;
  end;
  Result := nil;
end;

function TWebApi.CmdSearchSet(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    Msgs.SetSearchFilter('', '');
  end else begin
    Msgs.SetSearchFilter(utf8string(AArgs.Get('filter', '')),
      utf8string(AArgs.Get('query', '')));
  end;
  Result := CmdMessagesList;
end;

{ ------------------------------------------------------------------ }
{ stickers, saved animations                                         }
{ ------------------------------------------------------------------ }

function RequireStickers: TTdStickers;
begin
  Result := TdStickerList;
  if Result = nil then begin
    raise Exception.Create('no active account');
  end;
end;

{ One sticker as the panel wants it. A sticker with no url yet is still
  worth sending, for the same reason a custom emoji with no url is (see
  AddCustomEmoji): it says "this one exists and is on its way", which
  lets the page hold its place instead of reflowing the grid as files
  land one by one. }
function StickerJson(AItem: TStickerItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('fileId', AItem.FileId);
  Result.Add('format', string(StickerFormatStr(AItem.Format)));
  Result.Add('emoji', string(AItem.Emoji));
  Result.Add('w', AItem.Width);
  Result.Add('h', AItem.Height);
  Result.Add('url', string(FileUrl(AItem.FileId, AItem.LocalPath)));
end;

function TWebApi.CmdStickersList(AArgs: TJSONObject): TJSONData;
var
  Sticks: TTdStickers;
  Sets, Arr: TJSONArray;
  SetObj: TJSONObject;
  I, J: integer;
  Query: utf8string;
begin
  Sticks := RequireStickers;
  Query := '';
  if AArgs <> nil then begin
    Query := utf8string(AArgs.Get('query', ''));
  end;

  { A search REPLACES the list rather than filtering it: the answer
    comes from Telegram (the installed sets, plus favourites, recents
    and trending), not from what happens to be loaded here. It is
    reported as a single set so the page has one shape to draw. }
  if Query <> '' then begin
    Sticks.SearchStickers(Query);
    Arr := TJSONArray.Create;
    for I := 0 to Sticks.FoundStickers.Count - 1 do begin
      Arr.Add(StickerJson(Sticks.FoundStickers[I]));
    end;
    Sets := TJSONArray.Create;
    { A heading over nothing says less than "Nothing found" does, so an
      empty result is reported as no sets at all rather than as one
      empty set. }
    if Arr.Count > 0 then begin
      SetObj := TJSONObject.Create;
      SetObj.Add('id', '0');
      SetObj.Add('title', 'Search results');
      SetObj.Add('loaded', True);
      SetObj.Add('stickers', Arr);
      Sets.Add(SetObj);
    end else begin
      Arr.Free;
    end;
    Result := TJSONObject.Create;
    TJSONObject(Result).Add('ready', Sticks.StickerSearchReady);
    TJSONObject(Result).Add('query', string(Query));
    TJSONObject(Result).Add('sets', Sets);
    Exit;
  end;

  { Leaving the search box puts the ordinary lists back, and drops the
    results so the next search of the same words really re-runs. }
  Sticks.SearchStickers('');
  Sticks.EnsureLoaded;

  Sets := TJSONArray.Create;

  { The recent stickers ride in as a set of their own, at the front.
    The panel then has one kind of thing to draw, and "Recently used"
    sits where every client puts it. Its id is 0, which no real set
    has, so asking to load it is a no-op rather than a special case. }
  if Sticks.Recent.Count > 0 then begin
    Arr := TJSONArray.Create;
    for I := 0 to Sticks.Recent.Count - 1 do begin
      Arr.Add(StickerJson(Sticks.Recent[I]));
    end;
    SetObj := TJSONObject.Create;
    SetObj.Add('id', '0');
    SetObj.Add('title', 'Recently used');
    SetObj.Add('loaded', True);
    SetObj.Add('stickers', Arr);
    Sets.Add(SetObj);
  end;

  for I := 0 to Sticks.Sets.Count - 1 do begin
    Arr := TJSONArray.Create;
    for J := 0 to Sticks.Sets[I].Items.Count - 1 do begin
      Arr.Add(StickerJson(Sticks.Sets[I].Items[J]));
    end;
    SetObj := TJSONObject.Create;
    { As TEXT: a set id is a full Int64 and JSON numbers stop being
      exact at 2^53 - the same trap album ids and custom emoji ids
      already taught this project. }
    SetObj.Add('id', string(IntToStr(Sticks.Sets[I].Id)));
    SetObj.Add('title', string(Sticks.Sets[I].Title));
    SetObj.Add('loaded', Sticks.Sets[I].Loaded);
    SetObj.Add('stickers', Arr);
    Sets.Add(SetObj);
  end;

  Result := TJSONObject.Create;
  TJSONObject(Result).Add('ready', Sticks.SetsReady);
  TJSONObject(Result).Add('query', '');
  TJSONObject(Result).Add('sets', Sets);
end;

{ Asks for one set's stickers. Answers immediately with nothing to say:
  the fetch is asynchronous, and its arrival is announced by the
  'stickers' event like every other change here. }
function TWebApi.CmdStickerSet(AArgs: TJSONObject): TJSONData;
var
  Id: Int64;
begin
  if AArgs = nil then begin
    raise Exception.Create('stickers.set needs a set id');
  end;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id <> 0 then begin
    RequireStickers.EnsureSet(Id);
  end;
  Result := nil;
end;

function GifJson(AItem: TGifItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('fileId', AItem.FileId);
  Result.Add('w', AItem.Width);
  Result.Add('h', AItem.Height);
  { 'mpeg4' means the THUMBNAIL already moves; anything else is a
    still, and the page asks for the animation itself instead. }
  Result.Add('thumbFormat', string(AItem.ThumbFormat));
  Result.Add('url', string(FileUrl(AItem.ThumbFileId, AItem.ThumbPath)));
  Result.Add('playUrl', string(FileUrl(AItem.FileId, AItem.Path)));
end;

function TWebApi.CmdGifsList(AArgs: TJSONObject): TJSONData;
var
  Sticks: TTdStickers;
  Arr: TJSONArray;
  I: integer;
  Query: utf8string;
begin
  Sticks := RequireStickers;
  Query := '';
  if AArgs <> nil then begin
    Query := utf8string(AArgs.Get('query', ''));
  end;

  Arr := TJSONArray.Create;
  if Query <> '' then begin
    { Telegram has no call that searches saved animations, and
      searching them locally would be meaningless - they carry no
      titles. Real GIF search goes through the inline bot Telegram
      names in an option, which is what the model does. }
    Sticks.SearchGifs(Query);
    for I := 0 to Sticks.FoundGifs.Count - 1 do begin
      Arr.Add(GifJson(Sticks.FoundGifs[I]));
    end;
    Result := TJSONObject.Create;
    TJSONObject(Result).Add('ready', Sticks.GifSearchReady);
    TJSONObject(Result).Add('query', string(Query));
    TJSONObject(Result).Add('items', Arr);
    Exit;
  end;

  Sticks.SearchGifs('');
  Sticks.EnsureLoaded;
  for I := 0 to Sticks.Gifs.Count - 1 do begin
    Arr.Add(GifJson(Sticks.Gifs[I]));
  end;

  Result := TJSONObject.Create;
  TJSONObject(Result).Add('ready', Sticks.GifsReady);
  TJSONObject(Result).Add('query', '');
  TJSONObject(Result).Add('items', Arr);
end;

{ The account's installed CUSTOM emoji sets - the Premium ones a
  reaction can be. Shaped like stickers.list, because they are the same
  thing underneath, but keyed by custom emoji id rather than file id:
  that is what a reaction names. }
function TWebApi.CmdEmojiSets: TJSONData;
var
  Sticks: TTdStickers;
  Sets, Arr: TJSONArray;
  SetObj, O: TJSONObject;
  Item, Cover: TStickerItem;
  I, J: integer;
begin
  Sticks := RequireStickers;
  Sticks.EnsureEmojiSets;

  Sets := TJSONArray.Create;
  for I := 0 to Sticks.EmojiSets.Count - 1 do begin
    { Only the set being LOOKED AT sends its emoji. The others send
      nothing but their icon below - a couple of dozen sets of sixty
      would otherwise put well over a thousand entries into every
      answer, on a command that is re-asked each time a file lands. }
    Arr := TJSONArray.Create;
    if Sticks.EmojiSets[I].FilesWanted then begin
      for J := 0 to Sticks.EmojiSets[I].Items.Count - 1 do begin
        Item := Sticks.EmojiSets[I].Items[J];
        O := TJSONObject.Create;
        O.Add('id', string(IntToStr(Item.CustomEmojiId)));
        O.Add('format', string(StickerFormatStr(Item.Format)));
        O.Add('emoji', string(Item.Emoji));
        O.Add('url', string(FileUrl(Item.FileId, Item.LocalPath)));
        Arr.Add(O);
      end;
    end;
    SetObj := TJSONObject.Create;
    SetObj.Add('id', string(IntToStr(Sticks.EmojiSets[I].Id)));
    SetObj.Add('title', string(Sticks.EmojiSets[I].Title));
    { "loaded" is what the page uses to decide whether it has the set
      to draw - which means the FILES, not merely the list of what is
      in it. }
    SetObj.Add('loaded', Sticks.EmojiSets[I].FilesWanted
      and Sticks.EmojiSets[I].Loaded);
    { What the set's button wears. stickerSetInfo's own `covers` is
      EMPTY for custom emoji sets - measured on a live account, all 28
      of them - so this is normally the set's first sticker, whose
      file is fetched for every set as soon as its contents are
      known. }
    Cover := Sticks.EmojiSets[I].Cover;
    if (Cover = nil) and (Sticks.EmojiSets[I].Items.Count > 0) then begin
      Cover := Sticks.EmojiSets[I].Items[0];
    end;
    if Cover <> nil then begin
      O := TJSONObject.Create;
      O.Add('format', string(StickerFormatStr(Cover.Format)));
      O.Add('emoji', string(Cover.Emoji));
      O.Add('url', string(FileUrl(Cover.FileId, Cover.LocalPath)));
      SetObj.Add('cover', O);
    end;
    SetObj.Add('emoji', Arr);
    Sets.Add(SetObj);
  end;

  Result := TJSONObject.Create;
  TJSONObject(Result).Add('ready', Sticks.EmojiSetsReady);
  TJSONObject(Result).Add('sets', Sets);
end;

function TWebApi.CmdEmojiSet(AArgs: TJSONObject): TJSONData;
var
  Id: Int64;
begin
  if AArgs = nil then begin
    raise Exception.Create('emoji.set needs a set id');
  end;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id <> 0 then begin
    RequireStickers.EnsureEmojiSet(Id);
  end;
  Result := nil;
end;

{ Asks for one saved GIF's own file, so its tile can move. Answers
  immediately and says nothing, like stickers.set: the fetch is
  asynchronous and announces itself with a 'stickers' event. }
function TWebApi.CmdGifEnsure(AArgs: TJSONObject): TJSONData;
begin
  if AArgs = nil then begin
    raise Exception.Create('gifs.ensure needs a file id');
  end;
  RequireStickers.EnsureGif(AArgs.Get('fileId', 0));
  Result := nil;
end;

{ Sends a sticker or a saved animation the account already has. The
  page names it by file id alone; the dimensions Telegram needs come
  from the model, which is where they arrived from Telegram in the
  first place. }
function TWebApi.CmdMessageSendMedia(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Sticks: TTdStickers;
  Kind: utf8string;
  FileId: integer;
  Silent: boolean;
  Item: TStickerItem;
  G: TGifItem;
begin
  Msgs := RequireMsgs;
  Sticks := RequireStickers;
  if AArgs = nil then begin
    raise Exception.Create('message.sendMedia needs a kind and a file id');
  end;
  Kind := utf8string(AArgs.Get('kind', ''));
  FileId := AArgs.Get('fileId', 0);
  Silent := AArgs.Get('silent', False);

  if Kind = 'sticker' then begin
    Item := Sticks.FindSticker(FileId);
    if Item = nil then begin
      raise Exception.Create('unknown sticker');
    end;
    Msgs.SendSticker(Item.FileId, Item.Width, Item.Height, Item.Emoji, Silent);
  end else if Kind = 'animation' then begin
    G := Sticks.FindGif(FileId);
    if G = nil then begin
      raise Exception.Create('unknown animation');
    end;
    { A GIF the search bot offered is not this account's file - it is
      sent by naming the query and the result back to Telegram. One
      the account has saved goes out by file id as before. }
    if G.ResultId <> '' then begin
      Msgs.SendInlineResult(Sticks.GifQueryId, G.ResultId, Silent);
    end else begin
      Msgs.SendAnimation(G.FileId, G.Width, G.Height, G.Duration, Silent);
    end;
  end else begin
    raise Exception.Create('unknown media kind: ' + Kind);
  end;
  Result := nil;
end;

{ ------------------------------------------------------------------ }
{ signing in                                                         }
{ ------------------------------------------------------------------ }

{ The step the page has to draw.

  Two states come from outside TTdAuth entirely and are reported here
  rather than in webauth.pas, because they are about the APPLICATION
  and not about an account:

    'apiConfig' - config.ini has no api_id/api_hash yet. Nothing can
                  be signed in to until it does, and the native
                  first-run dialog is asking for the same pair.
    'none'      - credentials are there but no account exists yet. }
{ The QR login code, drawn here rather than in the page.

  The renderer is qrrender.pas (QRCodeGenLib + FPImage, no LCL) - the
  alternative was a second QR implementation in JavaScript, vendored
  and maintained, to draw the same square from the same string. A
  data URI rather than a URL because it is tiny, it changes with
  every link, and there is nothing to cache. }
function QrDataUri(const ALink: utf8string): utf8string;
var
  Stream: TMemoryStream;
  Raw: RawByteString;
begin
  Result := '';
  if ALink = '' then begin
    Exit;
  end;
  Stream := TMemoryStream.Create;
  try
    if DrawQrToPng(ALink, Stream, 320) = 0 then begin
      Exit;
    end;
    SetLength(Raw, Stream.Size);
    Stream.Position := 0;
    if Stream.Size > 0 then begin
      Stream.ReadBuffer(Raw[1], Stream.Size);
    end;
    Result := 'data:image/png;base64,' +
      utf8string(EncodeStringBase64(string(Raw)));
  finally
    Stream.Free;
  end;
end;

function TWebApi.CmdAuthState: TJSONData;
var
  O: TJSONObject;
  Link: utf8string;
begin
  if (TdApp.ApiId = 0) or (TdApp.ApiHash = '') then begin
    O := TJSONObject.Create;
    O.Add('state', 'apiConfig');
    Result := O;
    Exit;
  end;
  if FAuth = nil then begin
    O := TJSONObject.Create;
    O.Add('state', 'none');
    Result := O;
    Exit;
  end;
  Result := FAuth.StateJson;
  { Drawn on the way out rather than kept: the link changes whenever
    TDLib renews it, and a stale square is worse than none. }
  O := TJSONObject(Result);
  { Вход в аккаунт, добавленный к уже имеющимся, можно отменить
    (accounts.cancel) — экран входа покажет для этого ссылку. }
  O.Add('canCancel', TdApp.Count > 1);
  Link := utf8string(O.Get('qrLink', ''));
  if Link <> '' then begin
    O.Add('qrImage', string(QrDataUri(Link)));
  end;
end;

{ Every answer the page can give, in one place.

  They all end up calling TTdAuth, which is the same object the native
  login form talks to - so a code typed in either window moves the one
  state machine, and the other window follows through its own
  listener. That is the whole reason this is a bridge rather than a
  second implementation. }
function TWebApi.CmdAuthSubmit(const ACmd: utf8string; AArgs: TJSONObject): TJSONData;
var
  Auth: TTdAuth;
begin
  Result := nil;
  if (FAuth = nil) or (FAuth.Session = nil) then begin
    raise Exception.Create('no account to sign in');
  end;
  Auth := FAuth.Session.Auth;
  if Auth = nil then begin
    raise Exception.Create('no account to sign in');
  end;
  if AArgs = nil then begin
    AArgs := TJSONObject.Create;   { leaks nothing: freed with the request }
  end;

  if ACmd = 'auth.phone' then begin
    Auth.SubmitPhone(utf8string(AArgs.Get('phone', '')));
  end else if ACmd = 'auth.qr' then begin
    Auth.RequestQr;
  end else if ACmd = 'auth.code' then begin
    Auth.SubmitCode(utf8string(AArgs.Get('code', '')));
  end else if ACmd = 'auth.resend' then begin
    Auth.ResendCode;
  end else if ACmd = 'auth.email' then begin
    Auth.SubmitEmailAddress(utf8string(AArgs.Get('email', '')));
  end else if ACmd = 'auth.emailCode' then begin
    Auth.SubmitEmailCode(utf8string(AArgs.Get('code', '')));
  end else if ACmd = 'auth.password' then begin
    Auth.SubmitPassword(utf8string(AArgs.Get('password', '')));
  end else if ACmd = 'auth.recover' then begin
    Auth.RequestPasswordRecovery;
  end else if ACmd = 'auth.recoverCode' then begin
    Auth.SubmitRecoveryCode(utf8string(AArgs.Get('code', '')),
      utf8string(AArgs.Get('password', '')), utf8string(AArgs.Get('hint', '')));
  end else if ACmd = 'auth.register' then begin
    Auth.SubmitRegistration(utf8string(AArgs.Get('first', '')),
      utf8string(AArgs.Get('last', '')));
  end else begin
    raise Exception.Create('unknown auth command: ' + ACmd);
  end;
end;

function TWebApi.CmdApiConfig: TJSONData;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  O.Add('apiId', TdApp.ApiId);
  { The hash is NOT sent back. It is a credential, the page never has
    to show it, and a form that arrives pre-filled with one is a form
    that leaks it to anything reading the page. }
  O.Add('hasHash', TdApp.ApiHash <> '');
  Result := O;
end;

{ Saves the pair and re-reads it.

  Re-reading is what makes the rest of the start-up notice: the native
  first-run dialog is sitting in ShowModal watching for exactly this
  (see apisetup.pas), and closes itself once the pair is valid. }
function TWebApi.CmdApiSave(AArgs: TJSONObject): TJSONData;
var
  Id: integer;
  Hash: utf8string;
begin
  if AArgs = nil then begin
    raise Exception.Create('api.save needs an api_id and an api_hash');
  end;
  Id := AArgs.Get('apiId', 0);
  Hash := Trim(utf8string(AArgs.Get('apiHash', '')));
  if (Id <= 0) or (Hash = '') then begin
    raise Exception.Create('an api_id and an api_hash are both needed');
  end;
  TdApp.SaveApiCredentials(Id, Hash);
  { And bring the account layer up, which on a fresh install has been
    waiting for exactly this pair. A no-op when it is already up. }
  TdApp.EnsureStarted;
  Result := nil;
end;

{ ------------------------------------------------------------------ }
{ the context menu, and what it can do                               }
{ ------------------------------------------------------------------ }

function TWebApi.TakeDeferred(AConnId: Int64; AReqId: integer;
  AMessageId: Int64): PtrInt;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(FDeferred) do begin
    if not FDeferred[I].Busy then begin
      Result := I;
      Break;
    end;
  end;
  if Result < 0 then begin
    SetLength(FDeferred, Length(FDeferred) + 1);
    Result := High(FDeferred);
  end;
  FDeferred[Result].Busy := True;
  FDeferred[Result].ConnId := AConnId;
  FDeferred[Result].ReqId := AReqId;
  FDeferred[Result].MessageId := AMessageId;
  FDeferred[Result].Held := nil;
end;

procedure TWebApi.ReleaseDeferred(ASlot: PtrInt);
begin
  if (ASlot < 0) or (ASlot > High(FDeferred)) then begin
    Exit;
  end;
  FreeAndNil(FDeferred[ASlot].Held);
  FDeferred[ASlot].Busy := False;
end;

{ Step one of the menu: what may be done to this message. The answer is
  KEPT rather than sent, because the strip of reactions above the menu
  is a second question and the page wants one answer. }
procedure TWebApi.MenuPropsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Msgs: TTdMessages;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;

  { Cloned: the response object is only valid inside this callback. }
  FDeferred[Slot].Held := AResp.Obj.Clone as TJSONObject;

  Msgs := TdMsgList;
  if Msgs = nil then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, 'no active account');
    ReleaseDeferred(Slot);
    Exit;
  end;
  Msgs.QueryAvailableReactions(FDeferred[Slot].MessageId,
    @MenuReactionsDone, Slot);
end;

{ Step two, and the reply. A chat that offers no reactions at all is
  not an error - the menu simply draws without the strip. }
procedure TWebApi.MenuReactionsDone(Sender: TObject; const AResp: TTdResponse);

  { Emoji out of one availableReaction vector, in order, skipping what
    is already there. Custom (Premium) reactions are left out: they are
    stickers, and the strip draws characters. }
  procedure Collect(AArr: TJSONArray; AOut: TJSONArray);
  var
    I, J: integer;
    TypeObj: TJSONObject;
    E: utf8string;
    Seen: boolean;
  begin
    if AArr = nil then begin
      Exit;
    end;
    for I := 0 to AArr.Count - 1 do begin
      if not (AArr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      TypeObj := JGetObj(TJSONObject(AArr.Items[I]), 'type');
      if JGetStr(TypeObj, '@type') <> 'reactionTypeEmoji' then begin
        Continue;
      end;
      E := JGetStr(TypeObj, 'emoji');
      if E = '' then begin
        Continue;
      end;
      Seen := False;
      for J := 0 to AOut.Count - 1 do begin
        if AOut.Items[J].AsString = string(E) then begin
          Seen := True;
          Break;
        end;
      end;
      if not Seen then begin
        AOut.Add(string(E));
      end;
    end;
  end;

var
  Slot: PtrInt;
  Res, Props: TJSONObject;
  Emojis: TJSONArray;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Props := FDeferred[Slot].Held;

  Emojis := TJSONArray.Create;
  if AResp.Success then begin
    { Top first, then popular, then recent: that is the order Telegram
      itself intends them to be shown in.

      ALL of them, not a row's worth. There used to be a cap of eight
      here, and eight is simply not how many a chat offers: measured on
      this account, a channel with a restricted set answered with 13
      distinct emoji and an ordinary chat with 73. The strip drew the
      first eight and there was no way to reach the rest - the "pick
      any emoji" chevron beside it only appears where custom emoji are
      allowed, and that channel did not allow them. The page scrolls
      the strip instead. }
    Collect(JGetArr(AResp.Obj, 'top_reactions'), Emojis);
    Collect(JGetArr(AResp.Obj, 'popular_reactions'), Emojis);
    Collect(JGetArr(AResp.Obj, 'recent_reactions'), Emojis);
  end;

  Res := TJSONObject.Create;
  Res.Add('id', string(IntToStr(FDeferred[Slot].MessageId)));
  Res.Add('canEdit',       JGetBool(Props, 'can_be_edited'));
  Res.Add('canDeleteSelf', JGetBool(Props, 'can_be_deleted_only_for_self'));
  Res.Add('canDeleteAll',  JGetBool(Props, 'can_be_deleted_for_all_users'));
  Res.Add('canReply',      JGetBool(Props, 'can_be_replied'));
  Res.Add('canPin',        JGetBool(Props, 'can_be_pinned'));
  Res.Add('canForward',    JGetBool(Props, 'can_be_forwarded'));
  Res.Add('canSave',       JGetBool(Props, 'can_be_saved'));
  Res.Add('canGetLink',    JGetBool(Props, 'can_get_link'));
  Res.Add('reactions', Emojis);
  Res.Add('allowCustom',
    AResp.Success and JGetBool(AResp.Obj, 'allow_custom_emoji'));

  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

procedure TWebApi.MessageLinkDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
  end else begin
    Res := TJSONObject.Create;
    Res.Add('url', string(JGetStr(AResp.Obj, 'link')));
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  end;
  ReleaseDeferred(Slot);
end;

{ True means "answered later" - RunCommand must not reply again. }
function TWebApi.CmdMessageMenu(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Id: Int64;
begin
  Msgs := RequireMsgs;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.menu needs a message id');
  end;
  Msgs.QueryProperties(Id, @MenuPropsDone, TakeDeferred(AConnId, AReqId, Id));
  Result := True;
end;

function TWebApi.CmdMessageLink(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Id: Int64;
begin
  Msgs := RequireMsgs;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.link needs a message id');
  end;
  Msgs.QueryLink(Id, @MessageLinkDone, TakeDeferred(AConnId, AReqId, Id));
  Result := True;
end;

{ ------------------------------------------------------------------ }
{ who reacted, who read                                              }
{ ------------------------------------------------------------------ }

{ Один человек для всплывающего списка: имя, аватарка (или крошечное
  превью из объекта, пока она качается — и качание начинается здесь
  же), цвет на случай буквы и время (реакции, прочтения). }
function UserPersonJson(AUserId, ADate: Int64): TJSONObject;
var
  Users: TTdUsers;
  U: TUserRow;
begin
  Result := TJSONObject.Create;
  Users := TdUserList;
  U := nil;
  if Users <> nil then begin
    U := Users.Find(AUserId);
  end;
  if U <> nil then begin
    Users.EnsurePhoto(U);
    Result.Add('name', string(U.DisplayName));
    Result.Add('avatar', string(FileUrl(U.PhotoFileId, U.PhotoPath)));
    Result.Add('avatarThumb', string(ThumbDataUri(U.Minithumb)));
    Result.Add('color', string(AccentKeyFor(U.AccentColorId, AUserId)));
  end else begin
    Result.Add('name', '');
    Result.Add('avatar', '');
    Result.Add('avatarThumb', '');
    Result.Add('color', string(AccentKeyFor(-1, AUserId)));
  end;
  Result.Add('date', ADate);
end;

{ Реакцию может поставить и чат — канал или анонимный админ группы. }
function ChatPersonJson(AChatId, ADate: Int64): TJSONObject;
var
  Chats: TTdChats;
  R: TChatRow;
begin
  Result := TJSONObject.Create;
  Chats := TdChatList;
  R := nil;
  if Chats <> nil then begin
    R := Chats.Lookup(AChatId);
  end;
  if R <> nil then begin
    Chats.EnsureAvatar(R);
    Result.Add('name', string(R.Title));
    Result.Add('avatar', string(FileUrl(R.PhotoFileId, R.PhotoPath)));
    Result.Add('avatarThumb', string(ThumbDataUri(R.Minithumb)));
    Result.Add('color', string(AccentKey(R)));
  end else begin
    Result.Add('name', '');
    Result.Add('avatar', '');
    Result.Add('avatarThumb', '');
    Result.Add('color', string(AccentKeyFor(-1, AChatId)));
  end;
  Result.Add('date', ADate);
end;

function SenderPersonJson(ASender: TJSONObject; ADate: Int64): TJSONObject;
begin
  if JGetStr(ASender, '@type') = 'messageSenderChat' then begin
    Result := ChatPersonJson(JGetInt64(ASender, 'chat_id'), ADate);
  end else begin
    Result := UserPersonJson(JGetInt64(ASender, 'user_id'), ADate);
  end;
end;

{ Кто поставил реакцию (what = reactions; emoji или customEmojiId — какую
  именно) или кто прочитал (what = viewers). В личке «кто прочитал» —
  это собеседник и время: getMessageReadDate, его id держится в слоте до
  ответа. Ответ отложенный: TDLib спрашивается заново на каждое
  наведение — это вопрос к серверу Telegram, и устаревает он сразу. }
function TWebApi.CmdMessagePeople(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  Row: TChatRow;
  Id, CustomId: Int64;
  Slot: PtrInt;
  What, ReactionJson: utf8string;
  Emoji: TJSONString;
begin
  Msgs := RequireMsgs;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.people needs a message id');
  end;
  What := utf8string(AArgs.Get('what', ''));
  Slot := TakeDeferred(AConnId, AReqId, Id);

  if What = 'reactions' then begin
    ReactionJson := '';
    CustomId := StrToInt64Def(utf8string(AArgs.Get('customEmojiId', '')), 0);
    if CustomId <> 0 then begin
      ReactionJson := '{"@type":"reactionTypeCustomEmoji","custom_emoji_id":"' +
        utf8string(IntToStr(CustomId)) + '"}';
    end else if AArgs.Get('emoji', '') <> '' then begin
      Emoji := TJSONString.Create(AArgs.Get('emoji', ''));
      try
        ReactionJson := '{"@type":"reactionTypeEmoji","emoji":' + utf8string(Emoji.AsJSON) + '}';
      finally
        Emoji.Free;
      end;
    end;
    Msgs.QueryAddedReactions(Id, ReactionJson, @PeopleDone, Slot);
  end else begin
    Chats := TdChatList;
    Row := nil;
    if Chats <> nil then begin
      Row := Chats.Lookup(Msgs.ChatId);
    end;
    FDeferred[Slot].Held := TJSONObject.Create;
    if (Row <> nil) and (Row.Kind = ckPrivate) and (Row.UserId <> 0) then begin
      FDeferred[Slot].Held.Add('peer', Row.UserId);
    end;
    { Сначала — можно ли (can_get_viewers / can_get_read_date в
      getMessageProperties). Страница, которой это уже сказали, шлёт
      checked и получает список сразу; та, которой сказали «нельзя»,
      больше не спрашивает вовсе. }
    if AArgs.Get('checked', False) then begin
      PeopleQuery(Msgs, Id, Slot);
    end else begin
      Msgs.QueryProperties(Id, @PeoplePropsDone, Slot);
    end;
  end;
  Result := True;
end;

{ Сам вопрос «кто прочитал»: личка — время прочтения собеседником,
  группа — список прочитавших. }
procedure TWebApi.PeopleQuery(AMsgs: TTdMessages; AMessageId: Int64; ASlot: PtrInt);
begin
  if (FDeferred[ASlot].Held <> nil) and (FDeferred[ASlot].Held.Get('peer', Int64(0)) <> 0) then begin
    AMsgs.QueryReadDate(AMessageId, @PeopleDone, ASlot);
  end else begin
    AMsgs.QueryViewers(AMessageId, @PeopleDone, ASlot);
  end;
end;

procedure TWebApi.PeoplePropsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Msgs: TTdMessages;
  Allowed: boolean;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Allowed := False;
  if AResp.Success then begin
    if (FDeferred[Slot].Held <> nil) and (FDeferred[Slot].Held.Get('peer', Int64(0)) <> 0) then begin
      Allowed := JGetBool(AResp.Obj, 'can_get_read_date');
    end else begin
      Allowed := JGetBool(AResp.Obj, 'can_get_viewers');
    end;
  end;
  Msgs := TdMsgList;
  if (not Allowed) or (Msgs = nil) then begin
    Res := TJSONObject.Create;
    Res.Add('allowed', False);
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
    Exit;
  end;
  PeopleQuery(Msgs, FDeferred[Slot].MessageId, Slot);
end;

procedure TWebApi.PeopleDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  T: utf8string;
  Res, Item: TJSONObject;
  Items, Arr: TJSONArray;
  I: integer;
  Peer: Int64;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;

  Res := TJSONObject.Create;
  Items := TJSONArray.Create;
  T := JGetStr(AResp.Obj, '@type');
  if T = 'addedReactions' then begin
    Arr := JGetArr(AResp.Obj, 'reactions');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if not (Arr.Items[I] is TJSONObject) then begin
          Continue;
        end;
        Item := TJSONObject(Arr.Items[I]);
        Items.Add(SenderPersonJson(JGetObj(Item, 'sender_id'), JGetInt64(Item, 'date')));
      end;
    end;
    Res.Add('total', JGetInt(AResp.Obj, 'total_count'));
  end else if T = 'messageViewers' then begin
    Arr := JGetArr(AResp.Obj, 'viewers');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if not (Arr.Items[I] is TJSONObject) then begin
          Continue;
        end;
        Item := TJSONObject(Arr.Items[I]);
        Items.Add(UserPersonJson(JGetInt64(Item, 'user_id'), JGetInt64(Item, 'view_date')));
      end;
    end;
    Res.Add('total', Items.Count);
  end else begin
    { messageReadDate* — личка. }
    Peer := 0;
    if FDeferred[Slot].Held <> nil then begin
      Peer := FDeferred[Slot].Held.Get('peer', Int64(0));
    end;
    if T = 'messageReadDateRead' then begin
      Items.Add(UserPersonJson(Peer, JGetInt64(AResp.Obj, 'read_date')));
    end else if T = 'messageReadDateUnread' then begin
      Res.Add('note', 'Not read yet');
    end else if T = 'messageReadDateTooOld' then begin
      Res.Add('note', 'Read, but too long ago to tell when');
    end else begin
      Res.Add('note', 'Hidden by privacy settings');
    end;
    Res.Add('total', Items.Count);
  end;
  Res.Add('items', Items);
  Res.Add('allowed', True);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ ------------------------------------------------------------------ }
{ t.me links                                                         }
{ ------------------------------------------------------------------ }

function JsonStr(const AValue: utf8string): utf8string;
var
  V: TJSONString;
begin
  V := TJSONString.Create(string(AValue));
  try
    Result := utf8string(V.AsJSON);
  finally
    V.Free;
  end;
end;

{ Ссылка t.me (telegram.me, tg:) — открыть внутри приложения. Разбирает
  её сам TDLib (getInternalLinkType), здесь только шаг по типу:
    публичный чат  -> searchPublicChat           -> chatId
    приглашение    -> checkChatInviteLink        -> chatId или invite
    сообщение      -> getMessageLinkInfo         -> chatId, messageId
    прочее         -> external: true, страница отдаёт ссылку браузеру.
  Поля и методы — по td_api.tl. }
function TWebApi.CmdLinkResolve(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Url: utf8string;
  Slot: PtrInt;
begin
  Url := utf8string(AArgs.Get('url', ''));
  if Url = '' then begin
    raise Exception.Create('link.resolve needs a url');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('url', string(Url));
  RequireMsgs.Request('getInternalLinkType', '"link":' + JsonStr(Url),
    @LinkTypeDone, Slot);
  Result := True;
end;

procedure TWebApi.LinkExternal(ASlot: PtrInt);
var
  Res: TJSONObject;
begin
  Res := TJSONObject.Create;
  Res.Add('external', True);
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

procedure TWebApi.LinkTypeDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  T: utf8string;
  Msgs: TTdMessages;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Msgs := TdMsgList;
  if (not AResp.Success) or (Msgs = nil) then begin
    LinkExternal(Slot);
    Exit;
  end;
  T := JGetStr(AResp.Obj, '@type');
  if T = 'internalLinkTypePublicChat' then begin
    Msgs.Request('searchPublicChat',
      '"username":' + JsonStr(JGetStr(AResp.Obj, 'chat_username')), @LinkChatDone, Slot);
  end else if T = 'internalLinkTypeChatInvite' then begin
    FDeferred[Slot].Held.Add('invite', string(JGetStr(AResp.Obj, 'invite_link')));
    Msgs.Request('checkChatInviteLink',
      '"invite_link":' + JsonStr(JGetStr(AResp.Obj, 'invite_link')), @LinkInviteDone, Slot);
  end else if T = 'internalLinkTypeMessage' then begin
    Msgs.Request('getMessageLinkInfo',
      '"url":' + JsonStr(JGetStr(AResp.Obj, 'url')), @LinkMessageDone, Slot);
  end else if T = 'internalLinkTypeInvoice' then begin
    { Ссылка-счёт t.me/$имя (покупка звёзд и т.п.): странице — имя счёта,
      дальше тот же путь, что у кнопки «Купить» (bot.buy/bot.pay с
      invoiceName -> inputInvoiceName). }
    Res := TJSONObject.Create;
    Res.Add('invoice', string(JGetStr(AResp.Obj, 'invoice_name')));
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
  end else begin
    LinkExternal(Slot);
  end;
end;

procedure TWebApi.LinkChatDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('chatId', JGetInt64(AResp.Obj, 'id'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ chat_id = 0 — до вступления доступа нет (td_api.tl): странице —
  описание чата для вопроса «вступить?». }
procedure TWebApi.LinkInviteDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Inv, Photo, Small, Local: TJSONObject;
  ChatId: Int64;
  Kind, B64: utf8string;
  Thumb: RawByteString;
  Msgs: TTdMessages;
  FileId: integer;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  ChatId := JGetInt64(AResp.Obj, 'chat_id');
  if ChatId <> 0 then begin
    Res.Add('chatId', ChatId);
  end else begin
    Kind := JGetStr(JGetObj(AResp.Obj, 'type'), '@type');
    Inv := TJSONObject.Create;
    Inv.Add('link', FDeferred[Slot].Held.Get('invite', ''));
    Inv.Add('title', string(JGetStr(AResp.Obj, 'title')));
    Inv.Add('members', JGetInt(AResp.Obj, 'member_count'));
    Inv.Add('channel', Kind = 'inviteLinkChatTypeChannel');
    Inv.Add('request', JGetBool(AResp.Obj, 'creates_join_request'));
    { Как окно нативного клиента: аватарка, описание, цвет буквы для
      чата без фото. }
    Inv.Add('description', string(JGetStr(AResp.Obj, 'description')));
    Inv.Add('color', string(AccentKeyFor(JGetInt(AResp.Obj, 'accent_color_id'), 0)));
    Photo := JGetObj(AResp.Obj, 'photo');
    Small := nil;
    if Photo <> nil then begin
      Small := JGetObj(Photo, 'small');
      Thumb := '';
      B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
      if B64 <> '' then begin
        try
          Thumb := DecodeStringBase64(string(B64));
        except
          Thumb := '';
        end;
      end;
      Inv.Add('avatarThumb', string(ThumbDataUri(Thumb)));
    end;
    Res.Add('invite', Inv);

    { Фото чата, куда доступа ещё нет: в модели чатов его строки нет, и
      докачанное потом показать было бы некуда. Поэтому оно качается
      СЕЙЧАС, а ответ ждёт: synchronous:true — ответ downloadFile
      приходит, когда файл уже на диске (td_api.tl). Файл маленький. }
    if Small <> nil then begin
      FileId := JGetInt(Small, 'id');
      Local := JGetObj(Small, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Inv.Add('avatar', string(FileUrl(FileId, JGetStr(Local, 'path'))));
      end else begin
        Msgs := TdMsgList;
        if (Msgs <> nil) and (FileId <> 0) then begin
          FDeferred[Slot].Held.Add('reply', Res);
          Msgs.Request('downloadFile',
            '"file_id":' + utf8string(IntToStr(FileId)) +
            ',"priority":32,"offset":0,"limit":0,"synchronous":true',
            @LinkInvitePhotoDone, Slot);
          Exit;
        end;
      end;
    end;
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

procedure TWebApi.LinkInvitePhotoDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  Local: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  { Ответ забирается из слота в собственность — Reply его отправит и
    освободит; иначе ReleaseDeferred освободил бы его второй раз. }
  Res := TJSONObject(FDeferred[Slot].Held.Extract('reply'));
  if Res = nil then begin
    ReleaseDeferred(Slot);
    Exit;
  end;
  if AResp.Success then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      TJSONObject(Res.Objects['invite']).Add('avatar',
        string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path'))));
    end;
  end;
  { Не скачалось — окно покажет размытое превью или букву. }
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

procedure TWebApi.LinkMessageDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Msg: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if (not AResp.Success) or (JGetInt64(AResp.Obj, 'chat_id') = 0) then begin
    { Сообщение недоступно (закрытый чат без доступа и т.п.) — пусть
      разбирается браузер и официальный клиент. }
    LinkExternal(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('chatId', JGetInt64(AResp.Obj, 'chat_id'));
  Msg := JGetObj(AResp.Obj, 'message');
  if Msg <> nil then begin
    Res.Add('messageId', JGetInt64(Msg, 'id'));
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Вступление по приглашению. Ответ — chatJoinResult* в свежем TDLib и
  просто chat в прежних; оба понимаются. }
function TWebApi.CmdLinkJoin(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Link: utf8string;
begin
  Link := utf8string(AArgs.Get('link', ''));
  if Link = '' then begin
    raise Exception.Create('link.join needs an invite link');
  end;
  RequireMsgs.Request('joinChatByInviteLink', '"invite_link":' + JsonStr(Link),
    @LinkJoinDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

procedure TWebApi.LinkJoinDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  T: utf8string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  T := JGetStr(AResp.Obj, '@type');
  if T = 'chat' then begin
    Res.Add('chatId', JGetInt64(AResp.Obj, 'id'));
  end else if T = 'chatJoinResultSuccess' then begin
    Res.Add('chatId', JGetInt64(AResp.Obj, 'chat_id'));
  end else if T = 'chatJoinResultRequestSent' then begin
    Res.Add('requested', True);
  end else begin
    Res.Add('declined', True);
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ ------------------------------------------------------------------ }
{ bots: keyboards, callbacks, commands                               }
{ ------------------------------------------------------------------ }

{ Нажатие callback-кнопки: getCallbackQueryAnswer, ответ бота — text,
  alert (show_alert), url. Бот может и не ответить вовремя — тогда
  TDLib вернёт ошибку, и страница её не показывает. }
function TWebApi.CmdBotCallback(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Id: Int64;
  Payload: utf8string;
begin
  Msgs := RequireMsgs;
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if (Id = 0) or (Msgs.ChatId = 0) then begin
    raise Exception.Create('bot.callback needs a message id');
  end;
  { Три вида callbackQueryPayload (td_api.tl): Data, DataWithPassword
    (пароль 2FA вводит человек на странице), Game (game_short_name из
    messageGame самого сообщения). }
  if AArgs.Get('game', False) then begin
    Payload := '{"@type":"callbackQueryPayloadGame","game_short_name":' +
      JsonStr(GameShortName(Msgs, Id)) + '}';
  end else if AArgs.Find('password') <> nil then begin
    Payload := '{"@type":"callbackQueryPayloadDataWithPassword","password":' +
      JsonStr(utf8string(AArgs.Get('password', ''))) + ',"data":' +
      JsonStr(utf8string(AArgs.Get('data', ''))) + '}';
  end else begin
    Payload := '{"@type":"callbackQueryPayloadData","data":' +
      JsonStr(utf8string(AArgs.Get('data', ''))) + '}';
  end;
  Msgs.Request('getCallbackQueryAnswer',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"message_id":' + utf8string(IntToStr(Id)) +
    ',"payload":' + Payload,
    @BotCallbackDone, TakeDeferred(AConnId, AReqId, Id));
  Result := True;
end;

procedure TWebApi.BotCallbackDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('text', string(JGetStr(AResp.Obj, 'text')));
  Res.Add('alert', JGetBool(AResp.Obj, 'show_alert'));
  Res.Add('url', string(JGetStr(AResp.Obj, 'url')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Команды бота и его кнопка меню — из userFullInfo.bot_info (td_api.tl):
  commands (command, description), menu_button (text, url). Только для
  лички с ботом: в группах у каждого бота свои, это позже. }
function TWebApi.CmdBotInfo(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Chats: TTdChats;
  Row: TChatRow;
  Slot: PtrInt;
begin
  Chats := RequireChats;
  Row := Chats.Lookup(AArgs.Get('chatId', Int64(0)));
  Slot := TakeDeferred(AConnId, AReqId, 0);
  if (Row = nil) or (Row.Kind <> ckPrivate) or (Row.UserId = 0) then begin
    Reply(AConnId, AReqId, TJSONObject.Create);
    ReleaseDeferred(Slot);
    Result := True;
    Exit;
  end;
  RequireMsgs.Request('getUserFullInfo',
    '"user_id":' + utf8string(IntToStr(Row.UserId)), @BotInfoDone, Slot);
  Result := True;
end;

procedure TWebApi.BotInfoDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Info, Menu, C: TJSONObject;
  Arr, Cmds: TJSONArray;
  I: integer;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  if AResp.Success then begin
    Info := JGetObj(AResp.Obj, 'bot_info');
    if Info <> nil then begin
      Cmds := TJSONArray.Create;
      Arr := JGetArr(Info, 'commands');
      if Arr <> nil then begin
        for I := 0 to Arr.Count - 1 do begin
          if not (Arr.Items[I] is TJSONObject) then begin
            Continue;
          end;
          C := TJSONObject.Create;
          C.Add('command', string(JGetStr(TJSONObject(Arr.Items[I]), 'command')));
          C.Add('description', string(JGetStr(TJSONObject(Arr.Items[I]), 'description')));
          Cmds.Add(C);
        end;
      end;
      Res.Add('commands', Cmds);
      Menu := JGetObj(Info, 'menu_button');
      if Menu <> nil then begin
        C := TJSONObject.Create;
        C.Add('text', string(JGetStr(Menu, 'text')));
        C.Add('url', string(JGetStr(Menu, 'url')));
        Res.Add('menuButton', C);
      end;
    end;
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Trim для utf8string без двух предупреждений о преобразовании. }
function TrimU(const AValue: utf8string): utf8string;
begin
  Result := utf8string(Trim(string(AValue)));
end;

{ ------------------------------------------------------------------ }
{ мой аккаунт (Settings -> My account)                               }
{ ------------------------------------------------------------------ }

{ account.get — цепочкой: getMe -> getUserFullInfo -> getOption
  bio_length_max -> (downloadFile аватарки, если её нет на диске) ->
  ответ. Поля — по td_api.tl коммита d1085f9: user (first_name,
  last_name, usernames.editable_username, phone_number, profile_photo,
  accent_color_id, is_premium), userFullInfo (bio, birthdate,
  personal_chat_id). Собираемый ответ живёт в Held['reply']. }
function TWebApi.CmdAccountGet(AConnId: Int64; AReqId: integer): boolean;
var
  Msgs: TTdMessages;
  Slot: PtrInt;
begin
  Msgs := RequireMsgs;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  { Какое поле ответа заполняет текущая докачка — см. AccountFinish. }
  FDeferred[Slot].Held.Add('want', '');
  Msgs.Request('getMe', '', @AccountMeDone, Slot);
  Result := True;
end;

{ Слот жив и цепочка не оборвалась; иначе — ошибка странице и слот
  освобождается. }
function TWebApi.AccountSlot(const AResp: TTdResponse; out ASlot: PtrInt): boolean;
begin
  Result := False;
  ASlot := AResp.Tag;
  if (ASlot < 0) or (ASlot > High(FDeferred)) or (not FDeferred[ASlot].Busy)
     or (FDeferred[ASlot].Held = nil) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(ASlot);
    Exit;
  end;
  Result := True;
end;

procedure TWebApi.AccountMeDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Photo, Small, Local: TJSONObject;
  Id: Int64;
  B64: utf8string;
  Thumb: RawByteString;
  Title: utf8string;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Id := JGetInt64(AResp.Obj, 'id');
  Res := TJSONObject.Create;
  Res.Add('id', Id);
  Res.Add('firstName', string(JGetStr(AResp.Obj, 'first_name')));
  Res.Add('lastName', string(JGetStr(AResp.Obj, 'last_name')));
  Res.Add('username', string(JGetStr(JGetObj(AResp.Obj, 'usernames'), 'editable_username')));
  Res.Add('phone', string(JGetStr(AResp.Obj, 'phone_number')));
  Res.Add('premium', JGetBool(AResp.Obj, 'is_premium'));
  Res.Add('color', string(AccentKeyFor(JGetInt(AResp.Obj, 'accent_color_id'), Id)));
  { Для выбора цвета: id цвета имени и профиля (-1 — профиль без цвета)
    и их фоновые эмодзи, которые setAccentColor/setProfileAccentColor
    требуют передать заново, чтобы не сбросить. }
  Res.Add('accentId', JGetInt(AResp.Obj, 'accent_color_id'));
  Res.Add('accentEmoji', string(IntToStr(JGetInt64(AResp.Obj, 'background_custom_emoji_id'))));
  Res.Add('profileAccentId', JGetInt(AResp.Obj, 'profile_accent_color_id'));
  Res.Add('profileEmoji', string(IntToStr(JGetInt64(AResp.Obj, 'profile_background_custom_emoji_id'))));
  Title := TrimU(JGetStr(AResp.Obj, 'first_name') + ' ' + JGetStr(AResp.Obj, 'last_name'));
  Res.Add('title', string(Title));
  Res.Add('avatar', '');
  Res.Add('avatarThumb', '');
  Res.Add('avatarAnim', '');
  Photo := JGetObj(AResp.Obj, 'profile_photo');
  if Photo <> nil then begin
    B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
    if B64 <> '' then begin
      try
        Thumb := DecodeStringBase64(string(B64));
        Res.Strings['avatarThumb'] := string(ThumbDataUri(Thumb));
      except
        { Битое превью — просто без него. }
      end;
    end;
    Small := JGetObj(Photo, 'small');
    if Small <> nil then begin
      Local := JGetObj(Small, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Res.Strings['avatar'] := string(FileUrl(JGetInt(Small, 'id'), JGetStr(Local, 'path')));
      end else begin
        FDeferred[Slot].Held.Add('photoFile', JGetInt(Small, 'id'));
      end;
    end;
  end;
  FDeferred[Slot].Held.Add('reply', Res);
  RequireMsgs.Request('getUserFullInfo', '"user_id":' + utf8string(IntToStr(Id)),
    @AccountFullDone, Slot);
end;

procedure TWebApi.AccountFullDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Birth, BirthOut, Personal, Photo, Anim, Local: TJSONObject;
  ChatId: Int64;
  Row: TChatRow;
  Chats: TTdChats;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Objects['reply']);
  Res.Add('bio', string(JGetStr(JGetObj(AResp.Obj, 'bio'), 'text')));
  { Анимированная аватарка — только в полной информации: фото
    personal_photo / photo / public_photo (тот же порядок, что у чатов в
    tdchats), файл — small_animation (160x160), иначе animation. }
  Photo := JGetObj(AResp.Obj, 'personal_photo');
  if Photo = nil then begin
    Photo := JGetObj(AResp.Obj, 'photo');
  end;
  if Photo = nil then begin
    Photo := JGetObj(AResp.Obj, 'public_photo');
  end;
  if Photo <> nil then begin
    Anim := JGetObj(Photo, 'small_animation');
    if Anim = nil then begin
      Anim := JGetObj(Photo, 'animation');
    end;
    if Anim <> nil then begin
      Local := JGetObj(JGetObj(Anim, 'file'), 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Res.Strings['avatarAnim'] := string(FileUrl(JGetInt(JGetObj(Anim, 'file'), 'id'),
          JGetStr(Local, 'path')));
      end else begin
        FDeferred[Slot].Held.Add('animFile', JGetInt(JGetObj(Anim, 'file'), 'id'));
      end;
    end;
  end;
  Birth := JGetObj(AResp.Obj, 'birthdate');
  if Birth <> nil then begin
    BirthOut := TJSONObject.Create;
    BirthOut.Add('day', JGetInt(Birth, 'day'));
    BirthOut.Add('month', JGetInt(Birth, 'month'));
    { 0 — год не указан (birthdate.year, td_api.tl). }
    BirthOut.Add('year', JGetInt(Birth, 'year'));
    Res.Add('birthdate', BirthOut);
  end else begin
    Res.Add('birthdate', TJSONNull.Create);
  end;
  ChatId := JGetInt64(AResp.Obj, 'personal_chat_id');
  if ChatId <> 0 then begin
    Personal := TJSONObject.Create;
    Personal.Add('id', ChatId);
    Chats := TdChatList;
    Row := nil;
    if Chats <> nil then begin
      Row := Chats.Lookup(ChatId);
    end;
    if Row <> nil then begin
      Personal.Add('title', string(Row.Title));
    end else begin
      Personal.Add('title', '');
    end;
    Res.Add('personalChat', Personal);
  end else begin
    Res.Add('personalChat', TJSONNull.Create);
  end;
  RequireMsgs.Request('getOption', '"name":"bio_length_max"', @AccountBioMaxDone, Slot);
end;

procedure TWebApi.AccountBioMaxDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  V: TJSONData;
  BioMax: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Objects['reply']);
  { optionValueInteger.value — int64, в JSON строкой (живой лог:
    "value":"140"). }
  BioMax := ACCOUNT_BIO_MAX_DEFAULT;
  V := AResp.Obj.Find('value');
  if V <> nil then begin
    BioMax := StrToIntDef(V.AsString, ACCOUNT_BIO_MAX_DEFAULT);
  end;
  Res.Add('bioMax', BioMax);

  AccountFinish(Slot);
end;

{ Докачка того, чего нет на диске: сначала картинка аватарки, потом её
  анимация — downloadFile synchronous, ответ приходит, когда файл уже
  скачан; файлы маленькие. Всё на месте — ответ странице. }
procedure TWebApi.AccountFinish(ASlot: PtrInt);
var
  Res: TJSONObject;
  FileId: integer;
begin
  FileId := FDeferred[ASlot].Held.Get('photoFile', 0);
  if FileId <> 0 then begin
    FDeferred[ASlot].Held.Delete('photoFile');
    FDeferred[ASlot].Held.Strings['want'] := 'avatar';
  end else begin
    FileId := FDeferred[ASlot].Held.Get('animFile', 0);
    if FileId <> 0 then begin
      FDeferred[ASlot].Held.Delete('animFile');
      FDeferred[ASlot].Held.Strings['want'] := 'avatarAnim';
    end;
  end;
  if FileId <> 0 then begin
    RequireMsgs.Request('downloadFile',
      '"file_id":' + utf8string(IntToStr(FileId)) +
      ',"priority":32,"offset":0,"limit":0,"synchronous":true',
      @AccountPhotoDone, ASlot);
    Exit;
  end;
  Res := TJSONObject(FDeferred[ASlot].Held.Extract('reply'));
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

procedure TWebApi.AccountPhotoDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Local: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Find('reply'));
  if Res = nil then begin
    ReleaseDeferred(Slot);
    Exit;
  end;
  { Не скачалось — страница покажет превью, буквы или неподвижную
    картинку вместо анимации. }
  if AResp.Success then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      Res.Strings[FDeferred[Slot].Held.Strings['want']] :=
        string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
    end;
  end;
  AccountFinish(Slot);
end;

{ Изменения — по одному полю, ответ ok; свежие значения страница
  берёт новым account.get. Методы — td_api.tl: setName, setBio,
  setUsername, setBirthdate (null — убрать), setPersonalChat (0 —
  убрать), setProfilePhoto (inputChatPhotoStatic из файла /upload). }
function TWebApi.CmdAccountSet(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Key, Method, Body, Path: utf8string;
  Day, Month, Year: integer;
begin
  Result := True;
  Msgs := RequireMsgs;
  if AArgs = nil then begin
    raise Exception.Create('account.set needs a key');
  end;
  Key := AArgs.Get('key', utf8string(''));
  if Key = 'name' then begin
    if TrimU(AArgs.Get('first', utf8string(''))) = '' then begin
      raise Exception.Create('First name cannot be empty');
    end;
    Method := 'setName';
    Body := '"first_name":' + JsonStr(TrimU(AArgs.Get('first', utf8string('')))) +
      ',"last_name":' + JsonStr(TrimU(AArgs.Get('last', utf8string(''))));
  end else if Key = 'bio' then begin
    Method := 'setBio';
    Body := '"bio":' + JsonStr(AArgs.Get('value', utf8string('')));
  end else if Key = 'username' then begin
    Method := 'setUsername';
    Body := '"username":' + JsonStr(TrimU(AArgs.Get('value', utf8string(''))));
  end else if Key = 'birthdate' then begin
    Method := 'setBirthdate';
    Day := AArgs.Get('day', 0);
    Month := AArgs.Get('month', 0);
    Year := AArgs.Get('year', 0);
    if (Day = 0) or (Month = 0) then begin
      Body := '"birthdate":null';
    end else begin
      Body := '"birthdate":{"@type":"birthdate","day":' + utf8string(IntToStr(Day)) +
        ',"month":' + utf8string(IntToStr(Month)) +
        ',"year":' + utf8string(IntToStr(Year)) + '}';
    end;
  end else if Key = 'accent' then begin
    Method := 'setAccentColor';
    Body := '"accent_color_id":' + utf8string(IntToStr(AArgs.Get('value', 0))) +
      ',"background_custom_emoji_id":' +
      utf8string(IntToStr(StrToInt64Def(AArgs.Get('emoji', '0'), 0)));
  end else if Key = 'profileAccent' then begin
    Method := 'setProfileAccentColor';
    Body := '"profile_accent_color_id":' + utf8string(IntToStr(AArgs.Get('value', -1))) +
      ',"profile_background_custom_emoji_id":' +
      utf8string(IntToStr(StrToInt64Def(AArgs.Get('emoji', '0'), 0)));
  end else if Key = 'photoMain' then begin
    Method := 'setProfilePhoto';
    Body := '"photo":{"@type":"inputChatPhotoPrevious","chat_photo_id":' +
      utf8string(IntToStr(StrToInt64Def(AArgs.Get('photoId', '0'), 0))) + '},"is_public":false';
  end else if Key = 'photoDelete' then begin
    Method := 'deleteProfilePhoto';
    Body := '"profile_photo_id":' +
      utf8string(IntToStr(StrToInt64Def(AArgs.Get('photoId', '0'), 0)));
  end else if Key = 'personalChat' then begin
    Method := 'setPersonalChat';
    Body := '"chat_id":' + utf8string(IntToStr(AArgs.Get('value', Int64(0))));
  end else if Key = 'photo' then begin
    Path := utf8string(UploadFilePath(AArgs.Get('upload', '')));
    if Path = '' then begin
      raise Exception.Create('uploaded file not found');
    end;
    Method := 'setProfilePhoto';
    Body := '"photo":{"@type":"inputChatPhotoStatic","photo":{"@type":"inputFileLocal","path":' +
      JsonStr(Path) + '}},"is_public":false';
  end else begin
    raise Exception.Create('unknown account setting: ' + string(Key));
  end;
  Msgs.Request(Method, Body, @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Галерея своих аватарок: getUserProfilePhotos (td_api.tl: до 100 за
  раз; personal и public фото в ответ не входят) -> по каждому фото
  самый крупный photoSize качается синхронно, по одному, -> ответ.
  Превью сразу — minithumbnail, чтобы полоса снизу не была пустой. }
function TWebApi.CmdAccountPhotos(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Slot: PtrInt;
begin
  Result := True;
  Msgs := RequireMsgs;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  Msgs.Request('getUserProfilePhotos',
    '"user_id":' + utf8string(IntToStr(ArgId(AArgs, 'userId'))) +
    ',"offset":0,"limit":' + utf8string(IntToStr(ACCOUNT_PHOTOS_MAX)),
    @AccountPhotosDone, Slot);
end;

procedure TWebApi.AccountPhotosDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr, Sizes, Out: TJSONArray;
  Photo, Size, Best, Item, Local, Anim: TJSONObject;
  I, J: integer;
  B64: utf8string;
  Thumb: RawByteString;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Out := TJSONArray.Create;
  Arr := JGetArr(AResp.Obj, 'photos');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Photo := TJSONObject(Arr.Items[I]);
      { Самый крупный размер — по ширине: у типов ('a', 'b', 'c') нет
        гарантированного порядка в массиве. }
      Best := nil;
      Sizes := JGetArr(Photo, 'sizes');
      if Sizes <> nil then begin
        for J := 0 to Sizes.Count - 1 do begin
          if not (Sizes.Items[J] is TJSONObject) then begin
            Continue;
          end;
          Size := TJSONObject(Sizes.Items[J]);
          if (Best = nil) or (JGetInt(Size, 'width') > JGetInt(Best, 'width')) then begin
            Best := Size;
          end;
        end;
      end;
      if Best = nil then begin
        Continue;
      end;
      Item := TJSONObject.Create;
      { id — int64, строкой: в JS число такой длины теряет точность. }
      Item.Add('id', string(IntToStr(JGetInt64(Photo, 'id'))));
      Item.Add('date', JGetInt64(Photo, 'added_date'));
      Item.Add('w', JGetInt(Best, 'width'));
      Item.Add('h', JGetInt(Best, 'height'));
      Item.Add('fileId', JGetInt(JGetObj(Best, 'photo'), 'id'));
      Item.Add('url', '');
      Item.Add('thumb', '');
      B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
      if B64 <> '' then begin
        try
          Thumb := DecodeStringBase64(string(B64));
          Item.Strings['thumb'] := string(ThumbDataUri(Thumb));
        except
          { Битое превью — без него. }
        end;
      end;
      { «Скачан» — только если файл и правда на диске. После
        optimizeStorage (tdstorage.pas: пустой file_types чистит и файлы
        типа photo, а полноразмерные фото профиля — они) TDLib ещё
        отдаёт is_downloading_completed с путём, которого нет:
        проверено живьём, 9 из 10 файлов галереи. Такой файл — stale:
        сначала deleteFile, чтобы TDLib забыл запись, потом докачка. }
      Item.Add('stale', False);
      Item.Add('animStale', False);
      Local := JGetObj(JGetObj(Best, 'photo'), 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        if FileExists(string(JGetStr(Local, 'path'))) then begin
          Item.Strings['url'] := string(FileUrl(Item.Integers['fileId'], JGetStr(Local, 'path')));
        end else begin
          Item.Booleans['stale'] := True;
        end;
      end;
      { Анимированная аватарка: chatPhoto.animation — animatedChatPhoto
        (length — сторона квадрата, file — MPEG4; td_api.tl). Качается
        следом за картинкой, картинка остаётся постером. }
      Item.Add('animFileId', 0);
      Item.Add('animUrl', '');
      Anim := JGetObj(Photo, 'animation');
      if Anim <> nil then begin
        Item.Integers['animFileId'] := JGetInt(JGetObj(Anim, 'file'), 'id');
        Item.Add('animSize', JGetInt(Anim, 'length'));
        Local := JGetObj(JGetObj(Anim, 'file'), 'local');
        if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
          if FileExists(string(JGetStr(Local, 'path'))) then begin
            Item.Strings['animUrl'] := string(FileUrl(Item.Integers['animFileId'],
              JGetStr(Local, 'path')));
          end else begin
            Item.Booleans['animStale'] := True;
          end;
        end;
      end;
      Out.Add(Item);
    end;
  end;
  FDeferred[Slot].Held.Add('photos', Out);
  FDeferred[Slot].Held.Add('next', 0);
  FDeferred[Slot].Held.Add('field', '');
  AccountPhotosNext(Slot);
end;

{ Чего у фото ещё нет: 'url' (картинка), 'animUrl' (анимация) или ''. }
function PhotoMissing(AItem: TJSONObject): string;
begin
  if AItem.Strings['url'] = '' then begin
    Result := 'url';
  end else if (AItem.Integers['animFileId'] <> 0) and (AItem.Strings['animUrl'] = '') then begin
    Result := 'animUrl';
  end else begin
    Result := '';
  end;
end;

{ Следующий нескачанный файл — downloadFile synchronous; когда скачано
  всё (или что смогло), ответ странице. Какое поле заполняется —
  Held['field']. }
procedure TWebApi.AccountPhotosNext(ASlot: PtrInt);
var
  Arr: TJSONArray;
  I: integer;
  Res, Item: TJSONObject;
  Field: string;
  FileId: integer;
begin
  Arr := TJSONArray(FDeferred[ASlot].Held.Arrays['photos']);
  I := FDeferred[ASlot].Held.Integers['next'];
  Field := '';
  while I < Arr.Count do begin
    Field := PhotoMissing(TJSONObject(Arr.Items[I]));
    if Field <> '' then begin
      Break;
    end;
    Inc(I);
  end;
  FDeferred[ASlot].Held.Integers['next'] := I;
  if I < Arr.Count then begin
    Item := TJSONObject(Arr.Items[I]);
    if Field = 'url' then begin
      FileId := Item.Integers['fileId'];
    end else begin
      FileId := Item.Integers['animFileId'];
    end;
    FDeferred[ASlot].Held.Strings['field'] := Field;
    if ((Field = 'url') and Item.Booleans['stale'])
       or ((Field = 'animUrl') and Item.Booleans['animStale']) then begin
      { Запись устарела (файла нет) — сначала забыть её, докачка — в
        AccountPhotoStaleDone. }
      if Field = 'url' then begin
        Item.Booleans['stale'] := False;
      end else begin
        Item.Booleans['animStale'] := False;
      end;
      RequireMsgs.Request('deleteFile', '"file_id":' + utf8string(IntToStr(FileId)),
        @AccountPhotoStaleDone, ASlot);
      Exit;
    end;
    RequireMsgs.Request('downloadFile',
      '"file_id":' + utf8string(IntToStr(FileId)) +
      ',"priority":16,"offset":0,"limit":0,"synchronous":true',
      @AccountPhotoFileDone, ASlot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('photos', FDeferred[ASlot].Held.Extract('photos'));
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

{ deleteFile устаревшей записи прошёл (или нет — всё равно пробуем):
  теперь та же докачка, что для нескачанного файла. }
procedure TWebApi.AccountPhotoStaleDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  AccountPhotosNext(Slot);
end;

procedure TWebApi.AccountPhotoFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  Item, Local: TJSONObject;
  I: integer;
  Field: string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  Arr := TJSONArray(FDeferred[Slot].Held.Arrays['photos']);
  I := FDeferred[Slot].Held.Integers['next'];
  Field := FDeferred[Slot].Held.Strings['field'];
  if (I < Arr.Count) and (Field <> '') then begin
    Item := TJSONObject(Arr.Items[I]);
    if AResp.Success then begin
      Local := JGetObj(AResp.Obj, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed')
         and FileExists(string(JGetStr(Local, 'path'))) then begin
        Item.Strings[Field] := string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
      end;
    end;
    { Не скачалось — '-': поле больше не ждёт, а страница такой адрес
      пропускает (картинку — слайдом, анимацию — оставляя картинку). }
    if Item.Strings[Field] = '' then begin
      Item.Strings[Field] := '-';
    end;
  end;
  { Тот же индекс: у фото может не хватать ещё анимации. }
  AccountPhotosNext(Slot);
end;

{ Свободно ли имя пользователя: checkChatUsername с chat_id своей лички
  (= свой user id; так велит td_api.tl для «private chat with self»). }
function TWebApi.CmdAccountCheckUsername(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('checkChatUsername',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'userId'))) +
    ',"username":' + JsonStr(TrimU(AArgs.Get('username', utf8string('')))),
    @AccountUsernameDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.AccountUsernameDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  T: utf8string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  { checkChatUsernameResult* — td_api.tl; хвост имени типа и есть ответ. }
  T := JGetStr(AResp.Obj, '@type');
  if T = 'checkChatUsernameResultOk' then begin
    T := 'ok';
  end else if T = 'checkChatUsernameResultUsernameInvalid' then begin
    T := 'invalid';
  end else if T = 'checkChatUsernameResultUsernameOccupied' then begin
    T := 'occupied';
  end else if T = 'checkChatUsernameResultUsernamePurchasable' then begin
    T := 'purchasable';
  end else if T = 'checkChatUsernameResultPublicChatsTooMany' then begin
    T := 'tooMany';
  end else begin
    T := 'unavailable';
  end;
  Res := TJSONObject.Create;
  Res.Add('result', string(T));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Каналы, годные в «личный канал»: getSuitablePersonalChats -> chats
  (chat_ids). Названия — из модели чатов: это свои каналы, они в списке. }
function TWebApi.CmdAccountPersonalChats(AConnId: Int64; AReqId: integer): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('getSuitablePersonalChats', '', @AccountPersonalChatsDone,
    TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.AccountPersonalChatsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Item: TJSONObject;
  Arr: TJSONArray;
  Ids: TJSONArray;
  Chats: TTdChats;
  Row: TChatRow;
  I: integer;
  Id: Int64;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Arr := TJSONArray.Create;
  Chats := TdChatList;
  Ids := JGetArr(AResp.Obj, 'chat_ids');
  if Ids <> nil then begin
    for I := 0 to Ids.Count - 1 do begin
      Id := Ids.Items[I].AsInt64;
      Item := TJSONObject.Create;
      Item.Add('id', Id);
      Row := nil;
      if Chats <> nil then begin
        Row := Chats.Lookup(Id);
      end;
      if Row <> nil then begin
        Item.Add('title', string(Row.Title));
      end else begin
        Item.Add('title', string(IntToStr(Id)));
      end;
      Arr.Add(Item);
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('chats', Arr);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ ------------------------------------------------------------------ }
{ остальные виды кнопок ботов (td_api.tl коммита d1085f9)             }
{ ------------------------------------------------------------------ }

{ inlineKeyboardButtonTypeLoginUrl: getLoginUrlInfo -> loginUrlInfoOpen
  (url, skip_confirmation) — открыть сразу; loginUrlInfoRequestConfirmation
  (url, domain, bot_user_id, request_write_access) — спросить человека,
  затем getLoginUrl (bot.loginUrlConfirm). }
function TWebApi.CmdBotLoginUrl(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('getLoginUrlInfo',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"message_id":' + utf8string(AArgs.Get('msgId', '0')) +
    ',"button_id":' + utf8string(IntToStr(AArgs.Get('buttonId', Int64(0)))),
    @BotLoginInfoDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.BotLoginInfoDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('url', string(JGetStr(AResp.Obj, 'url')));
  if JGetStr(AResp.Obj, '@type') = 'loginUrlInfoRequestConfirmation' then begin
    Res.Add('confirm', True);
    Res.Add('domain', string(JGetStr(AResp.Obj, 'domain')));
    Res.Add('writeAccess', JGetBool(AResp.Obj, 'request_write_access'));
  end else begin
    Res.Add('confirm', False);
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

function TWebApi.CmdBotLoginUrlConfirm(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('getLoginUrl',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"message_id":' + utf8string(AArgs.Get('msgId', '0')) +
    ',"button_id":' + utf8string(IntToStr(AArgs.Get('buttonId', Int64(0)))) +
    ',"allow_write_access":' + BoolJson(AArgs.Get('allowWrite', False)),
    @WebAppOpenUrlDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Ответ httpUrl -> url странице. }
procedure TWebApi.WebAppOpenUrlDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('url', string(JGetStr(AResp.Obj, 'url')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ orderInfo TDLib -> странице (name, phone, email, address(...)); nil -> null. }
function OrderInfoToPage(AInfo: TJSONObject): TJSONData;
var
  O, A, Addr: TJSONObject;
begin
  if AInfo = nil then begin
    Result := TJSONNull.Create;
    Exit;
  end;
  O := TJSONObject.Create;
  O.Add('name', string(JGetStr(AInfo, 'name')));
  O.Add('phone', string(JGetStr(AInfo, 'phone_number')));
  O.Add('email', string(JGetStr(AInfo, 'email_address')));
  Addr := JGetObj(AInfo, 'shipping_address');
  if Addr <> nil then begin
    A := TJSONObject.Create;
    A.Add('countryCode', string(JGetStr(Addr, 'country_code')));
    A.Add('state', string(JGetStr(Addr, 'state')));
    A.Add('city', string(JGetStr(Addr, 'city')));
    A.Add('street1', string(JGetStr(Addr, 'street_line1')));
    A.Add('street2', string(JGetStr(Addr, 'street_line2')));
    A.Add('postalCode', string(JGetStr(Addr, 'postal_code')));
    O.Add('address', A);
  end;
  Result := O;
end;

{ Данные заказа со страницы -> JSON orderInfo для TDLib (через fpjson, с
  экранированием); адрес — только если страница его прислала. }
function OrderInfoFromPage(AOrder: TJSONObject): utf8string;
var
  O, A, Src: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('@type', 'orderInfo');
    O.Add('name', AOrder.Get('name', ''));
    O.Add('phone_number', AOrder.Get('phone', ''));
    O.Add('email_address', AOrder.Get('email', ''));
    if AOrder.Find('address') is TJSONObject then begin
      Src := TJSONObject(AOrder.Find('address'));
      A := TJSONObject.Create;
      A.Add('@type', 'address');
      A.Add('country_code', Src.Get('countryCode', ''));
      A.Add('state', Src.Get('state', ''));
      A.Add('city', Src.Get('city', ''));
      A.Add('street_line1', Src.Get('street1', ''));
      A.Add('street_line2', Src.Get('street2', ''));
      A.Add('postal_code', Src.Get('postalCode', ''));
      O.Add('shipping_address', A);
    end;
    Result := utf8string(O.AsJSON);
  finally
    O.Free;
  end;
end;

{ Какой счёт оплачивается: по имени из ссылки t.me/$имя
  (inputInvoiceName, args.invoiceName) или счёт-сообщение открытого чата
  (inputInvoiceMessage, args.msgId). Поля — td_api.tl коммита d1085f9. }
function InvoiceJson(AMsgs: TTdMessages; AArgs: TJSONObject): utf8string;
var
  Name: utf8string;
begin
  Name := AArgs.Get('invoiceName', utf8string(''));
  if Name <> '' then begin
    Result := '{"@type":"inputInvoiceName","name":' + JsonStr(Name) + '}';
  end else begin
    Result := '{"@type":"inputInvoiceMessage","chat_id":' +
      utf8string(IntToStr(AMsgs.ChatId)) + ',"message_id":' +
      utf8string(AArgs.Get('msgId', '0')) + '}';
  end;
end;

{ inlineKeyboardButtonTypeBuy: getPaymentForm(inputInvoiceMessage).
  paymentFormTypeStars (star_count) — странице цена и id формы, она
  спрашивает подтверждение и зовёт bot.pay; paymentFormTypeRegular с
  paymentProviderOther (url) — ссылка на оплату у провайдера; прочее
  (Stripe, Smart Glocal, подписки) — не поддержано. }
function TWebApi.CmdBotBuy(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('getPaymentForm',
    '"input_invoice":' + InvoiceJson(Msgs, AArgs) + ',"theme":null',
    @BotBuyDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.BotBuyDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, FormType, Provider, Inv, Saved, Part, Need, Prov: TJSONObject;
  Parts, SavedArr, PartsOut, SavedOut: TJSONArray;
  T: utf8string;
  I: integer;
  Total: Int64;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('formId', string(IntToStr(JGetInt64(AResp.Obj, 'id'))));
  Res.Add('title', string(JGetStr(JGetObj(AResp.Obj, 'product_info'), 'title')));
  FormType := JGetObj(AResp.Obj, 'type');
  T := JGetStr(FormType, '@type');
  if T = 'paymentFormTypeStars' then begin
    Res.Add('kind', 'stars');
    Res.Add('stars', JGetInt64(FormType, 'star_count'));
  end else if T = 'paymentFormTypeRegular' then begin
    Provider := JGetObj(FormType, 'payment_provider');
    Inv := JGetObj(FormType, 'invoice');
    if JGetStr(Provider, '@type') = 'paymentProviderOther' then begin
      Res.Add('kind', 'url');
      Res.Add('url', string(JGetStr(Provider, 'url')));
    end else begin
      { Оплата картой (td_api.tl коммита d1085f9): что нужно спросить
        (данные заказа — invoice.need_*, доставка — is_flexible), чем
        платить (saved_credentials, need_password), куда токенизировать
        новую карту (payment_provider). Сама карта уходит провайдеру со
        страницы (ui/payments.js) — сюда приходит только токен. }
      Res.Add('kind', 'card');
      Res.Add('currency', string(JGetStr(Inv, 'currency')));
      PartsOut := TJSONArray.Create;
      Total := 0;
      Parts := JGetArr(Inv, 'price_parts');
      if Parts <> nil then begin
        for I := 0 to Parts.Count - 1 do begin
          if not (Parts.Items[I] is TJSONObject) then begin
            Continue;
          end;
          Part := TJSONObject.Create;
          Part.Add('label', string(JGetStr(TJSONObject(Parts.Items[I]), 'label')));
          Part.Add('amount', JGetInt64(TJSONObject(Parts.Items[I]), 'amount'));
          PartsOut.Add(Part);
          Inc(Total, JGetInt64(TJSONObject(Parts.Items[I]), 'amount'));
        end;
      end;
      Res.Add('amount', Total);
      Res.Add('priceParts', PartsOut);
      Res.Add('terms', string(JGetStr(Inv, 'terms_of_service_url')));
      Res.Add('isTest', JGetBool(Inv, 'is_test'));
      Need := TJSONObject.Create;
      Need.Add('name', JGetBool(Inv, 'need_name'));
      Need.Add('phone', JGetBool(Inv, 'need_phone_number'));
      Need.Add('email', JGetBool(Inv, 'need_email_address'));
      Need.Add('shipping', JGetBool(Inv, 'need_shipping_address'));
      Need.Add('flexible', JGetBool(Inv, 'is_flexible'));
      Res.Add('need', Need);
      Res.Add('savedOrder', OrderInfoToPage(JGetObj(FormType, 'saved_order_info')));
      SavedOut := TJSONArray.Create;
      SavedArr := JGetArr(FormType, 'saved_credentials');
      if SavedArr <> nil then begin
        for I := 0 to SavedArr.Count - 1 do begin
          if not (SavedArr.Items[I] is TJSONObject) then begin
            Continue;
          end;
          Saved := TJSONObject.Create;
          Saved.Add('id', string(JGetStr(TJSONObject(SavedArr.Items[I]), 'id')));
          Saved.Add('title', string(JGetStr(TJSONObject(SavedArr.Items[I]), 'title')));
          SavedOut.Add(Saved);
        end;
      end;
      Res.Add('saved', SavedOut);
      Res.Add('needPassword', JGetBool(FormType, 'need_password'));
      Res.Add('canSave', JGetBool(FormType, 'can_save_credentials'));
      Prov := TJSONObject.Create;
      if JGetStr(Provider, '@type') = 'paymentProviderSmartGlocal' then begin
        Prov.Add('type', 'smartglocal');
        Prov.Add('publicToken', string(JGetStr(Provider, 'public_token')));
        Prov.Add('tokenizeUrl', string(JGetStr(Provider, 'tokenize_url')));
      end else if JGetStr(Provider, '@type') = 'paymentProviderStripe' then begin
        Prov.Add('type', 'stripe');
        Prov.Add('publishableKey', string(JGetStr(Provider, 'publishable_key')));
        Prov.Add('needCountry', JGetBool(Provider, 'need_country'));
        Prov.Add('needPostalCode', JGetBool(Provider, 'need_postal_code'));
        Prov.Add('needCardholderName', JGetBool(Provider, 'need_cardholder_name'));
      end else begin
        Prov.Add('type', 'unsupported');
      end;
      Res.Add('provider', Prov);
    end;
  end else begin
    Res.Add('kind', 'unsupported');
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ bot.validateOrder — данные заказа (validateOrderInfo, td_api.tl коммита
  d1085f9): order_info_id для sendPaymentForm и варианты доставки
  гибкого счёта (сумма каждого — по price_parts). }
function TWebApi.CmdBotValidateOrder(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Order: TJSONObject;
begin
  Result := True;
  Msgs := RequireMsgs;
  if not (AArgs.Find('order') is TJSONObject) then begin
    raise Exception.Create('bot.validateOrder needs order');
  end;
  Order := TJSONObject(AArgs.Find('order'));
  Msgs.Request('validateOrderInfo',
    '"input_invoice":' + InvoiceJson(Msgs, AArgs) +
    ',"order_info":' + OrderInfoFromPage(Order) +
    ',"allow_save":' + BoolJson(AArgs.Get('save', False)),
    @BotValidateOrderDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.BotValidateOrderDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Opt, O: TJSONObject;
  Arr, Out, Parts: TJSONArray;
  I, J: integer;
  Sum: Int64;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('orderInfoId', string(JGetStr(AResp.Obj, 'order_info_id')));
  Out := TJSONArray.Create;
  Arr := JGetArr(AResp.Obj, 'shipping_options');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Opt := TJSONObject(Arr.Items[I]);
      Sum := 0;
      Parts := JGetArr(Opt, 'price_parts');
      if Parts <> nil then begin
        for J := 0 to Parts.Count - 1 do begin
          if Parts.Items[J] is TJSONObject then begin
            Inc(Sum, JGetInt64(TJSONObject(Parts.Items[J]), 'amount'));
          end;
        end;
      end;
      O := TJSONObject.Create;
      O.Add('id', string(JGetStr(Opt, 'id')));
      O.Add('title', string(JGetStr(Opt, 'title')));
      O.Add('amount', Sum);
      Out.Add(O);
    end;
  end;
  Res.Add('shipping', Out);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ bot.tmpPassword — временный пароль для оплаты сохранённой картой
  (createTemporaryPassword; пароль — облачный пароль аккаунта, его
  вводит человек). }
function TWebApi.CmdBotTmpPassword(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  Result := True;
  RequireMsgs.Request('createTemporaryPassword',
    '"password":' + JsonStr(AArgs.Get('password', utf8string(''))) +
    ',"valid_for":' + utf8string(IntToStr(PAYMENT_TMP_PASSWORD_SEC)),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Оплата звёздами — только после явного подтверждения на странице:
  sendPaymentForm, credentials null (так велит td_api.tl для Stars). }
function TWebApi.CmdBotPay(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Creds: utf8string;
begin
  Result := True;
  Msgs := RequireMsgs;
  { Звёзды — credentials null; сохранённая карта — inputCredentialsSaved;
    новая — inputCredentialsNew с JSON-токеном провайдера (data). }
  Creds := 'null';
  if AArgs.Get('savedId', utf8string('')) <> '' then begin
    Creds := '{"@type":"inputCredentialsSaved","saved_credentials_id":' +
      JsonStr(AArgs.Get('savedId', utf8string(''))) + '}';
  end else if AArgs.Get('newData', utf8string('')) <> '' then begin
    Creds := '{"@type":"inputCredentialsNew","data":' +
      JsonStr(AArgs.Get('newData', utf8string(''))) + ',"allow_save":' +
      BoolJson(AArgs.Get('allowSave', False)) + '}';
  end;
  Msgs.Request('sendPaymentForm',
    '"input_invoice":' + InvoiceJson(Msgs, AArgs) + ',"payment_form_id":' +
    utf8string(IntToStr(StrToInt64Def(AArgs.Get('formId', '0'), 0))) +
    ',"order_info_id":' + JsonStr(AArgs.Get('orderInfoId', utf8string(''))) +
    ',"shipping_option_id":' + JsonStr(AArgs.Get('shippingOptionId', utf8string(''))) +
    ',"credentials":' + Creds + ',"tip_amount":0',
    @BotPayDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.BotPayDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  { paymentResult: success, verification_url (3-D Secure и т.п.). }
  Res := TJSONObject.Create;
  Res.Add('success', JGetBool(AResp.Obj, 'success'));
  Res.Add('url', string(JGetStr(AResp.Obj, 'verification_url')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ keyboardButtonTypeRequestLocation: координаты дал браузер (страница
  спросила разрешение), сюда — уже согласие человека. inputMessageLocation
  в этой схеме — только location (latitude, longitude, horizontal_accuracy). }
function TWebApi.CmdBotSendLocation(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Fmt: TFormatSettings;
begin
  Result := True;
  Msgs := RequireMsgs;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Msgs.Request('sendMessage',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"input_message_content":{"@type":"inputMessageLocation","location":{"@type":"location"' +
    ',"latitude":' + utf8string(FloatToStr(AArgs.Get('lat', 0.0), Fmt)) +
    ',"longitude":' + utf8string(FloatToStr(AArgs.Get('lon', 0.0), Fmt)) +
    ',"horizontal_accuracy":' + utf8string(FloatToStr(AArgs.Get('accuracy', 0.0), Fmt)) + '}}',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ keyboardButtonTypeRequestPoll: опрос, собранный на странице.
  inputMessagePoll (question, options из inputPollOption, is_anonymous,
  allows_multiple_answers, type: inputPollTypeRegular | inputPollTypeQuiz
  с correct_option_ids) — прочие поля TDLib берёт по умолчанию. }
function TWebApi.CmdBotSendPoll(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Opts: TJSONArray;
  Body, OptJson, PollType: utf8string;
  I: integer;
begin
  Result := True;
  Msgs := RequireMsgs;
  Opts := TJSONArray(AArgs.Find('options', jtArray));
  if (Opts = nil) or (Opts.Count < 2) then begin
    raise Exception.Create('A poll needs at least two options');
  end;
  OptJson := '';
  for I := 0 to Opts.Count - 1 do begin
    if I > 0 then begin
      OptJson := OptJson + ',';
    end;
    OptJson := OptJson + '{"@type":"inputPollOption","text":{"@type":"formattedText","text":' +
      JsonStr(utf8string(Opts.Strings[I])) + '}}';
  end;
  if AArgs.Get('quiz', False) then begin
    PollType := '{"@type":"inputPollTypeQuiz","correct_option_ids":[' +
      utf8string(IntToStr(AArgs.Get('correct', 0))) +
      '],"explanation":{"@type":"formattedText","text":""}}';
  end else begin
    PollType := '{"@type":"inputPollTypeRegular","allow_adding_options":false}';
  end;
  Body := '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"input_message_content":{"@type":"inputMessagePoll","question":{"@type":"formattedText","text":' +
    JsonStr(utf8string(AArgs.Get('question', ''))) + '},"options":[' + OptJson + ']' +
    ',"is_anonymous":' + BoolJson(AArgs.Get('anonymous', True)) +
    ',"allows_multiple_answers":' + BoolJson(AArgs.Get('multiple', False)) +
    ',"type":' + PollType + '}';
  Msgs.Request('sendMessage', Body, @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ keyboardButtonTypeRequestManagedBot: createBot (manager_bot_user_id —
  бот этой лички: id лички с пользователем равен его user id). }
function TWebApi.CmdBotCreateBot(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Msgs.Request('createBot',
    '"manager_bot_user_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"name":' + JsonStr(TrimU(AArgs.Get('name', utf8string('')))) +
    ',"username":' + JsonStr(TrimU(AArgs.Get('username', utf8string('')))) +
    ',"via_link":false',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ ------------------------------------------------------------------ }
{ меню скрепки: список задач, статья, боты меню вложений             }
{ ------------------------------------------------------------------ }

{ Список задач: inputMessageChecklist / inputChecklist (title, tasks из
  inputChecklistTask с id от 1, others_can_add_tasks,
  others_can_mark_tasks_as_done) — td_api.tl коммита d1085f9. Только для
  Premium и не в каналы — откажет сам TDLib. }
function TWebApi.CmdSendChecklist(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Tasks: TJSONArray;
  TaskJson: utf8string;
  I: integer;
begin
  Result := True;
  Msgs := RequireMsgs;
  Tasks := TJSONArray(AArgs.Find('tasks', jtArray));
  if (Tasks = nil) or (Tasks.Count = 0) then begin
    raise Exception.Create('A checklist needs at least one task');
  end;
  TaskJson := '';
  for I := 0 to Tasks.Count - 1 do begin
    if I > 0 then begin
      TaskJson := TaskJson + ',';
    end;
    TaskJson := TaskJson + '{"@type":"inputChecklistTask","id":' + utf8string(IntToStr(I + 1)) +
      ',"text":{"@type":"formattedText","text":' + JsonStr(utf8string(Tasks.Strings[I])) + '}}';
  end;
  Msgs.Request('sendMessage',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"input_message_content":{"@type":"inputMessageChecklist","checklist":{"@type":"inputChecklist"' +
    ',"title":{"@type":"formattedText","text":' + JsonStr(utf8string(AArgs.Get('title', ''))) + '}' +
    ',"tasks":[' + TaskJson + ']' +
    ',"others_can_add_tasks":' + BoolJson(AArgs.Get('othersAdd', False)) +
    ',"others_can_mark_tasks_as_done":' + BoolJson(AArgs.Get('othersMark', False)) + '}}',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Текст как RichText: richTextPlain (td_api.tl). }
function RichPlain(const AText: utf8string): utf8string;
begin
  Result := '{"@type":"richTextPlain","text":' + JsonStr(AText) + '}';
end;

{ Статья: inputMessageRichMessage -> inputRichMessage с
  richMessageSourceBlocks (Markdown и HTML у TDLib — только для ботов).
  Блоки собирает страница простыми описаниями, здесь — их перевод в
  InputPageBlock: heading (inputPageBlockSectionHeading, size 1..6),
  paragraph, list (inputPageBlockList из inputPageBlockListItem), quote
  (inputPageBlockBlockQuote с абзацем внутри), divider. }
function TWebApi.CmdSendArticle(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Blocks, Items: TJSONArray;
  B: TJSONObject;
  Out, ItemJson, Kind: utf8string;
  I, J: integer;
begin
  Result := True;
  Msgs := RequireMsgs;
  Blocks := TJSONArray(AArgs.Find('blocks', jtArray));
  if (Blocks = nil) or (Blocks.Count = 0) then begin
    raise Exception.Create('The article is empty');
  end;
  Out := '';
  for I := 0 to Blocks.Count - 1 do begin
    if not (Blocks.Items[I] is TJSONObject) then begin
      Continue;
    end;
    B := TJSONObject(Blocks.Items[I]);
    Kind := B.Get('type', utf8string(''));
    if Out <> '' then begin
      Out := Out + ',';
    end;
    if Kind = 'heading' then begin
      Out := Out + '{"@type":"inputPageBlockSectionHeading","text":' +
        RichPlain(B.Get('text', utf8string(''))) + ',"size":' +
        utf8string(IntToStr(B.Get('size', 1))) + '}';
    end else if Kind = 'list' then begin
      ItemJson := '';
      Items := TJSONArray(B.Find('items', jtArray));
      if Items <> nil then begin
        for J := 0 to Items.Count - 1 do begin
          if J > 0 then begin
            ItemJson := ItemJson + ',';
          end;
          ItemJson := ItemJson + '{"@type":"inputPageBlockListItem","blocks":[' +
            '{"@type":"inputPageBlockParagraph","text":' + RichPlain(utf8string(Items.Strings[J])) +
            '}],"has_checkbox":false,"is_checked":false,"value":0,"type":""}';
        end;
      end;
      Out := Out + '{"@type":"inputPageBlockList","items":[' + ItemJson + ']}';
    end else if Kind = 'quote' then begin
      Out := Out + '{"@type":"inputPageBlockBlockQuote","blocks":[' +
        '{"@type":"inputPageBlockParagraph","text":' + RichPlain(B.Get('text', utf8string(''))) +
        '}],"credit":' + RichPlain('') + '}';
    end else if Kind = 'divider' then begin
      Out := Out + '{"@type":"inputPageBlockDivider"}';
    end else begin
      Out := Out + '{"@type":"inputPageBlockParagraph","text":' +
        RichPlain(B.Get('text', utf8string(''))) + '}';
    end;
  end;
  Msgs.Request('sendMessage',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"input_message_content":{"@type":"inputMessageRichMessage","message":{"@type":"inputRichMessage"' +
    ',"source":{"@type":"richMessageSourceBlocks","blocks":[' + Out + ']}' +
    ',"is_rtl":false,"detect_automatic_blocks":true},"clear_draft":false}',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Боты меню вложений, годные для открытого чата (supports_*_chats). }
function TWebApi.CmdAttachBots: TJSONData;
var
  Bots: TTdAttachBots;
  Chats: TTdChats;
  Row: TChatRow;
  Arr: TJSONArray;
  Item: TJSONObject;
  I: integer;
  Fits: boolean;
  B: TAttachBot;
begin
  Arr := TJSONArray.Create;
  Result := Arr;
  Bots := TdAttachBotList;
  Chats := TdChatList;
  if (Bots = nil) or (Chats = nil) or (TdMsgList = nil) then begin
    Exit;
  end;
  Row := Chats.Lookup(TdMsgList.ChatId);
  if Row = nil then begin
    Exit;
  end;
  for I := 0 to Bots.Count - 1 do begin
    B := Bots[I];
    if Chats.IsSelfChat(Row) then begin
      Fits := B.SelfChat;
    end else begin
      case Row.Kind of
        ckPrivate, ckSecret: Fits := B.UserChats or B.BotChats;
        ckBasicGroup, ckSupergroup: Fits := B.GroupChats;
        ckChannel: Fits := B.ChannelChats;
      else
        Fits := False;
      end;
    end;
    if not Fits then begin
      Continue;
    end;
    Item := TJSONObject.Create;
    Item.Add('id', string(IntToStr(B.UserId)));
    Item.Add('name', string(B.Name));
    Arr.Add(Item);
  end;
end;

{ Картинка карты: getMapThumbnailFile (td_api.tl: PNG, zoom 13..20,
  ширина и высота 16..1024 до scale, scale 1..3) -> файл; нет на диске —
  downloadFile synchronous. Странице — адрес файла. }
function TWebApi.CmdMapThumb(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Fmt: TFormatSettings;
begin
  Result := True;
  Msgs := RequireMsgs;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Msgs.Request('getMapThumbnailFile',
    '"location":{"@type":"location","latitude":' +
    utf8string(FloatToStr(AArgs.Get('lat', 0.0), Fmt)) +
    ',"longitude":' + utf8string(FloatToStr(AArgs.Get('lon', 0.0), Fmt)) +
    ',"horizontal_accuracy":0},"zoom":' + utf8string(IntToStr(MAP_THUMB_ZOOM)) +
    ',"width":' + utf8string(IntToStr(MAP_THUMB_WIDTH)) +
    ',"height":' + utf8string(IntToStr(MAP_THUMB_HEIGHT)) +
    ',"scale":' + utf8string(IntToStr(MAP_THUMB_SCALE)) +
    ',"chat_id":' + utf8string(IntToStr(Msgs.ChatId)),
    @MapThumbDone, TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.MapThumbDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Local: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Local := JGetObj(AResp.Obj, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    Res := TJSONObject.Create;
    Res.Add('url', string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path'))));
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
    Exit;
  end;
  { Тот же обработчик и для ответа downloadFile: он тоже File. }
  RequireMsgs.Request('downloadFile',
    '"file_id":' + utf8string(IntToStr(JGetInt(AResp.Obj, 'id'))) +
    ',"priority":16,"offset":0,"limit":0,"synchronous":true',
    @MapThumbFileDone, Slot);
end;

procedure TWebApi.MapThumbFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Local: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('url', '');
  if AResp.Success then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      Res.Strings['url'] := string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
    end;
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ ------------------------------------------------------------------ }
{ упоминания: подсказка при наборе «@»                               }
{ ------------------------------------------------------------------ }

{ mention.search (query) — кого предложить после «@» в поле ввода.
  Чат — тот, куда пишет поле: открытый в модели (в ветке комментариев
  это группа обсуждения, не канал со страницы). Группа — участники
  searchChatMembers с chatMembersFilterMention (в ветке — её topic_id:
  messageTopicThread); личка и прочее — контакты searchContacts; канал —
  никого. Поля сверены с td_api.tl коммита d1085f9. }
function TWebApi.CmdMentionSearch(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  Row: TChatRow;
  Slot: PtrInt;
  Query, Topic: utf8string;
  Q: TJSONString;
begin
  Result := True;
  Msgs := RequireMsgs;
  Chats := RequireChats;
  Q := TJSONString.Create(AArgs.Get('query', ''));
  try
    Query := utf8string(Q.AsJSON);
  finally
    Q.Free;
  end;
  Row := Chats.Lookup(Msgs.ChatId);
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  if (Row <> nil) and (Row.Kind = ckChannel) then begin
    MentionReply(Slot, []);
    Exit;
  end;
  if (Row <> nil) and (Row.Kind in [ckBasicGroup, ckSupergroup]) then begin
    Topic := '';
    if Msgs.ThreadId <> 0 then begin
      Topic := '"topic_id":{"@type":"messageTopicThread","message_thread_id":'
        + utf8string(IntToStr(Msgs.ThreadId)) + '}';
    end;
    Msgs.Request('searchChatMembers',
      '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) + ',"query":' + Query +
      ',"limit":' + utf8string(IntToStr(MENTION_SUGGEST_LIMIT)) +
      ',"filter":{"@type":"chatMembersFilterMention"' +
      BoolToStr(Topic <> '', ',' + string(Topic), '') + '}',
      @MentionMembersDone, Slot);
  end else begin
    Msgs.Request('searchContacts',
      '"query":' + Query + ',"limit":' + utf8string(IntToStr(MENTION_SUGGEST_LIMIT)),
      @MentionContactsDone, Slot);
  end;
end;

procedure TWebApi.MentionMembersDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  M, Who: TJSONObject;
  Ids: array of Int64;
  I, N: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Ids := nil;
  Arr := JGetArr(AResp.Obj, 'members');
  if Arr <> nil then begin
    SetLength(Ids, Arr.Count);
    N := 0;
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      M := TJSONObject(Arr.Items[I]);
      Who := JGetObj(M, 'member_id');
      if JGetStr(Who, '@type') <> 'messageSenderUser' then begin
        Continue;
      end;
      Ids[N] := JGetInt64(Who, 'user_id');
      Inc(N);
    end;
    SetLength(Ids, N);
  end;
  MentionReply(Slot, Ids);
end;

procedure TWebApi.MentionContactsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  Ids: array of Int64;
  I: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Ids := nil;
  Arr := JGetArr(AResp.Obj, 'user_ids');
  if Arr <> nil then begin
    SetLength(Ids, Arr.Count);
    for I := 0 to Arr.Count - 1 do begin
      Ids[I] := Arr.Items[I].AsInt64;
    end;
  end;
  MentionReply(Slot, Ids);
end;

{ Люди по id — из модели пользователей (TDLib присылает updateUser до
  ответа поиска): имя, username, цвет, аватарка (на диске — адрес, нет —
  minithumbnail и докачка). Себя не предлагаем. }
procedure TWebApi.MentionReply(ASlot: PtrInt; const AIds: array of Int64);
var
  Res, O: TJSONObject;
  Out: TJSONArray;
  Users: TTdUsers;
  U: TUserRow;
  I: integer;
  Me: Int64;
begin
  Out := TJSONArray.Create;
  Users := TdUserList;
  Me := 0;
  if TdApp.Active <> nil then begin
    Me := TdApp.Active.UserId;
  end;
  for I := 0 to High(AIds) do begin
    if (AIds[I] = 0) or (AIds[I] = Me) then begin
      Continue;
    end;
    O := TJSONObject.Create;
    O.Add('userId', string(IntToStr(AIds[I])));
    O.Add('name', '');
    O.Add('username', '');
    O.Add('color', string(AccentKeyFor(-1, AIds[I])));
    O.Add('avatar', '');
    O.Add('avatarThumb', '');
    if Users <> nil then begin
      U := Users.Find(AIds[I]);
      if U <> nil then begin
        if U.Deleted then begin
          O.Free;
          Continue;
        end;
        O.Strings['name'] := string(U.DisplayName);
        O.Strings['username'] := string(U.Username);
        O.Strings['color'] := string(AccentKeyFor(U.AccentColorId, AIds[I]));
        if U.PhotoPath <> '' then begin
          O.Strings['avatar'] := string(FileUrl(U.PhotoFileId, U.PhotoPath));
        end else begin
          Users.EnsurePhoto(U);
          O.Strings['avatarThumb'] := string(ThumbDataUri(U.Minithumb));
        end;
      end else begin
        O.Strings['name'] := string(Users.DisplayName(AIds[I]));
      end;
    end;
    Out.Add(O);
  end;
  Res := TJSONObject.Create;
  Res.Add('items', Out);
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

{ ------------------------------------------------------------------ }
{ контакты (кнопка Contacts над списком чатов)                       }
{ ------------------------------------------------------------------ }

{ contacts.list: getContacts (td_api.tl: users — user_ids) -> getUser по
  каждому id, все сразу; ответы собираются в Held['items'], счётчик —
  Held['left']. Дошёл до нуля — ответ странице; порядок наводит она. }
function TWebApi.CmdContactsList(AConnId: Int64; AReqId: integer): boolean;
var
  Msgs: TTdMessages;
  Slot: PtrInt;
begin
  Result := True;
  Msgs := RequireMsgs;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('items', TJSONArray.Create);
  FDeferred[Slot].Held.Add('left', 0);
  Msgs.Request('getContacts', '', @ContactsIdsDone, Slot);
end;

procedure TWebApi.ContactsIdsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Ids: TJSONArray;
  I: integer;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Ids := JGetArr(AResp.Obj, 'user_ids');
  if (Ids = nil) or (Ids.Count = 0) then begin
    Res := TJSONObject.Create;
    Res.Add('contacts', TJSONArray.Create);
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
    Exit;
  end;
  FDeferred[Slot].Held.Integers['left'] := Ids.Count;
  for I := 0 to Ids.Count - 1 do begin
    RequireMsgs.Request('getUser', '"user_id":' + utf8string(IntToStr(Ids.Items[I].AsInt64)),
      @ContactUserDone, Slot);
  end;
end;

{ Один контакт: имя, имя пользователя, телефон, аватарка (на диске — адрес,
  нет — minithumbnail и докачка через модель пользователей), цвет, статус
  (userStatus* — хвост имени типа и was_online для Offline). }
procedure TWebApi.ContactUserDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Item, Photo, Small, Local, Status: TJSONObject;
  Id: Int64;
  B64: utf8string;
  Thumb: RawByteString;
  Left: integer;
  Res: TJSONObject;
  Users: TTdUsers;
  URow: TUserRow;
  Chats: TTdChats;
  CRow: TChatRow;
  FolderId: integer;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  if AResp.Success then begin
    Id := JGetInt64(AResp.Obj, 'id');
    Item := TJSONObject.Create;
    Item.Add('userId', string(IntToStr(Id)));
    Item.Add('title', string(TrimU(JGetStr(AResp.Obj, 'first_name') + ' ' +
      JGetStr(AResp.Obj, 'last_name'))));
    Item.Add('username', string(JGetStr(JGetObj(AResp.Obj, 'usernames'), 'editable_username')));
    Item.Add('phone', string(JGetStr(AResp.Obj, 'phone_number')));
    Item.Add('color', string(AccentKeyFor(JGetInt(AResp.Obj, 'accent_color_id'), Id)));
    Item.Add('avatar', '');
    Item.Add('avatarThumb', '');
    { Фото есть, но ещё качается — страница перезапросит список
      (OnChanged модели пользователей занят нативным окном истории). }
    Item.Add('photoPending', False);
    Photo := JGetObj(AResp.Obj, 'profile_photo');
    if Photo <> nil then begin
      B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
      if B64 <> '' then begin
        try
          Thumb := DecodeStringBase64(string(B64));
          Item.Strings['avatarThumb'] := string(ThumbDataUri(Thumb));
        except
          { Битое превью — без него. }
        end;
      end;
      Small := JGetObj(Photo, 'small');
      Local := JGetObj(Small, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Item.Strings['avatar'] := string(FileUrl(JGetInt(Small, 'id'), JGetStr(Local, 'path')));
      end else begin
        { Докачка — модель пользователей (как для людей в окне реакций);
          картинка появится при следующем запросе списка. }
        Item.Booleans['photoPending'] := True;
        Users := TdUserList;
        if Users <> nil then begin
          URow := Users.Find(Id);
          if URow <> nil then begin
            Users.EnsurePhoto(URow);
          end;
        end;
      end;
    end;
    { Папка лички с человеком — тот же чип, что в списке чатов. Id лички
      равен id пользователя; чата может ещё не быть (никогда не писали) —
      тогда «без папки», а меню сперва создаст личку (main.js). }
    Chats := TdChatList;
    FolderId := 0;
    CRow := nil;
    if Chats <> nil then begin
      CRow := Chats.Lookup(Id);
      FolderId := Chats.RowFolderId(CRow);
    end;
    Item.Add('folderId', FolderId);
    { В папку попадает только чат, у которого есть место в списке (main
      или archive). Личка без переписки там не стоит: addChatToList
      отвечает "Chat is not in a chat list" (живой tdlib_raw.log), а
      editChatFolder такую принимает, но TDLib потом сам выкидывает её
      из папки (DialogFilterManager: "Skip nonjoined"). Странице — чтобы
      меню не обещало невозможного. }
    Item.Add('inList', (CRow <> nil) and (CRow.InList or CRow.InArchive));
    if FolderId <> 0 then begin
      Item.Add('folder', string(Chats.FolderTitle(FolderId)));
    end else begin
      Item.Add('folder', '');
    end;
    Status := JGetObj(AResp.Obj, 'status');
    Item.Add('status', string(JGetStr(Status, '@type')));
    Item.Add('wasOnline', JGetInt64(Status, 'was_online'));
    { Участник группы (chat.members): роль из статуса участника. }
    if FDeferred[Slot].Held.Find('roles') is TJSONObject then begin
      Item.Add('role', TJSONObject(FDeferred[Slot].Held.Objects['roles']).Get(
        string(IntToStr(Id)), ''));
    end;
    TJSONArray(FDeferred[Slot].Held.Arrays['items']).Add(Item);
  end;
  Left := FDeferred[Slot].Held.Integers['left'] - 1;
  FDeferred[Slot].Held.Integers['left'] := Left;
  if Left > 0 then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add(FDeferred[Slot].Held.Get('replyKey', 'contacts'), FDeferred[Slot].Held.Extract('items'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ ------------------------------------------------------------------ }
{ приветствие в пустом личном чате                                   }
{ ------------------------------------------------------------------ }

{ chat.greeting — что показать в пустой личке (td_api.tl коммита
  d1085f9): userFullInfo.bot_info (description, short_description) —
  карточка бота с кнопкой Start; business_info.start_page (title,
  message, sticker) — стартовая страница бизнес-аккаунта; иначе —
  случайный стикер из getGreetingStickers, как у нативного клиента.
  Стикер качается до ответа (synchronous), чтобы его было чем показать. }
function TWebApi.CmdChatGreeting(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Chats: TTdChats;
  Row: TChatRow;
  Slot: PtrInt;
begin
  Result := True;
  Chats := RequireChats;
  Row := Chats.Lookup(AArgs.Get('chatId', Int64(0)));
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  if (Row = nil) or (Row.Kind <> ckPrivate) or (Row.UserId = 0) or Chats.IsSelfChat(Row) then begin
    Reply(AConnId, AReqId, TJSONObject.Create);
    ReleaseDeferred(Slot);
    Exit;
  end;
  RequireMsgs.Request('getUserFullInfo', '"user_id":' + utf8string(IntToStr(Row.UserId)),
    @GreetingFullDone, Slot);
end;

{ Стикер для страницы: id файла, размеры, эмодзи, формат (stickerFormat*
  хвостом) и адрес, если файл уже на диске; иначе — Held['fileId'] для
  докачки. }
procedure TWebApi.GreetingSticker(ASlot: PtrInt; ARes, ASticker: TJSONObject);
var
  S, FileObj, Local: TJSONObject;
  Fmt: utf8string;
begin
  FileObj := JGetObj(ASticker, 'sticker');
  S := TJSONObject.Create;
  S.Add('fileId', JGetInt(FileObj, 'id'));
  S.Add('w', JGetInt(ASticker, 'width'));
  S.Add('h', JGetInt(ASticker, 'height'));
  S.Add('emoji', string(JGetStr(ASticker, 'emoji')));
  Fmt := JGetStr(JGetObj(ASticker, 'format'), '@type');
  if Fmt = 'stickerFormatTgs' then begin
    S.Add('format', 'tgs');
  end else if Fmt = 'stickerFormatWebm' then begin
    S.Add('format', 'webm');
  end else begin
    S.Add('format', 'webp');
  end;
  S.Add('url', '');
  Local := JGetObj(FileObj, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    S.Strings['url'] := string(FileUrl(JGetInt(FileObj, 'id'), JGetStr(Local, 'path')));
  end else begin
    FDeferred[ASlot].Held.Add('fileId', JGetInt(FileObj, 'id'));
  end;
  ARes.Add('sticker', S);
end;

{ Ответ — или после докачки стикера. }
procedure TWebApi.GreetingFinish(ASlot: PtrInt);
var
  Res: TJSONObject;
  FileId: integer;
begin
  FileId := FDeferred[ASlot].Held.Get('fileId', 0);
  if FileId <> 0 then begin
    FDeferred[ASlot].Held.Delete('fileId');
    RequireMsgs.Request('downloadFile',
      '"file_id":' + utf8string(IntToStr(FileId)) +
      ',"priority":32,"offset":0,"limit":0,"synchronous":true',
      @GreetingFileDone, ASlot);
    Exit;
  end;
  Res := TJSONObject(FDeferred[ASlot].Held.Extract('reply'));
  if Res = nil then begin
    Res := TJSONObject.Create;
  end;
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

procedure TWebApi.GreetingFullDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Bot, Start: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  FDeferred[Slot].Held.Add('reply', Res);
  Bot := JGetObj(AResp.Obj, 'bot_info');
  if Bot <> nil then begin
    Res.Add('kind', 'bot');
    Res.Add('description', string(JGetStr(Bot, 'description')));
    Res.Add('shortDescription', string(JGetStr(Bot, 'short_description')));
    GreetingFinish(Slot);
    Exit;
  end;
  Start := JGetObj(JGetObj(AResp.Obj, 'business_info'), 'start_page');
  if (Start <> nil) and ((JGetStr(Start, 'title') <> '') or (JGetStr(Start, 'message') <> '')) then begin
    Res.Add('kind', 'intro');
    Res.Add('title', string(JGetStr(Start, 'title')));
    Res.Add('message', string(JGetStr(Start, 'message')));
    if JGetObj(Start, 'sticker') <> nil then begin
      GreetingSticker(Slot, Res, JGetObj(Start, 'sticker'));
    end;
    GreetingFinish(Slot);
    Exit;
  end;
  Res.Add('kind', 'greeting');
  RequireMsgs.Request('getGreetingStickers', '', @GreetingStickersDone, Slot);
end;

procedure TWebApi.GreetingStickersDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Objects['reply']);
  Arr := JGetArr(AResp.Obj, 'stickers');
  if (Arr <> nil) and (Arr.Count > 0) then begin
    GreetingSticker(Slot, Res, TJSONObject(Arr.Items[Random(Arr.Count)]));
  end;
  GreetingFinish(Slot);
end;

procedure TWebApi.GreetingFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Local: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Find('reply'));
  if AResp.Success and (Res <> nil) and (Res.Find('sticker') is TJSONObject) then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      TJSONObject(Res.Objects['sticker']).Strings['url'] :=
        string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
    end;
  end;
  GreetingFinish(Slot);
end;

{ Клик по приветственному стикеру — он уходит в открытый чат. }
function TWebApi.CmdGreetingSend(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  Msgs.SendSticker(AArgs.Get('fileId', 0), AArgs.Get('w', 0), AArgs.Get('h', 0),
    utf8string(AArgs.Get('emoji', '')), False);
  Result := nil;
end;

{ ------------------------------------------------------------------ }
{ панель информации о чате (кнопка «i» над историей)                 }
{ ------------------------------------------------------------------ }

{ Виды медиа для счётчиков панели — searchMessagesFilter* (td_api.tl);
  ключи — те, что ждёт страница. }
const
  INFO_COUNT_FILTERS: array[0..6] of string = ('searchMessagesFilterPhoto',
    'searchMessagesFilterVideo', 'searchMessagesFilterDocument',
    'searchMessagesFilterAudio', 'searchMessagesFilterUrl',
    'searchMessagesFilterVoiceNote', 'searchMessagesFilterAnimation');
  INFO_COUNT_KEYS: array[0..6] of string = ('photo', 'video', 'document',
    'audio', 'url', 'voice', 'animation');
  { Счётчик кодирует в теге и слот, и вид: Slot * INFO_TAG_MUL + индекс. }
  INFO_TAG_MUL = 16;

{ chat.info: строка чата (название, аватарка, цвет, звук) + по виду чата
  getUser/getUserFullInfo, getSupergroup/getSupergroupFullInfo или
  getBasicGroup/getBasicGroupFullInfo + getChatMessageCount по семи видам
  медиа — всё параллельно; Held['left'] считает ответы, на нуле — ответ. }
function TWebApi.CmdChatInfo(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  Row: TChatRow;
  Slot: PtrInt;
  Res, Counts: TJSONObject;
  I, Left: integer;
  ChatId: Int64;
begin
  Result := True;
  Msgs := RequireMsgs;
  Chats := RequireChats;
  ChatId := AArgs.Get('chatId', Int64(0));
  Row := Chats.Lookup(ChatId);
  if Row = nil then begin
    raise Exception.Create('unknown chat');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  Res := RowToJson(Chats, Row);
  Res.Add('chatId', ChatId);
  Counts := TJSONObject.Create;
  Res.Add('counts', Counts);
  FDeferred[Slot].Held.Add('reply', Res);

  Left := Length(INFO_COUNT_FILTERS);
  if Chats.IsSelfChat(Row) then begin
    Res.Strings['kind'] := 'self';
  end else if (Row.Kind = ckPrivate) and (Row.UserId <> 0) then begin
    Inc(Left, 2);
  end else if Row.SupergroupId <> 0 then begin
    Inc(Left, 2);
  end else if Row.BasicGroupId <> 0 then begin
    Inc(Left, 2);
  end;
  FDeferred[Slot].Held.Add('left', Left);

  if (not Chats.IsSelfChat(Row)) and (Row.Kind = ckPrivate) and (Row.UserId <> 0) then begin
    Res.Add('userId', string(IntToStr(Row.UserId)));
    Msgs.Request('getUser', '"user_id":' + utf8string(IntToStr(Row.UserId)), @InfoUserDone, Slot);
    Msgs.Request('getUserFullInfo', '"user_id":' + utf8string(IntToStr(Row.UserId)),
      @InfoUserFullDone, Slot);
  end else if Row.SupergroupId <> 0 then begin
    Msgs.Request('getSupergroup', '"supergroup_id":' + utf8string(IntToStr(Row.SupergroupId)),
      @InfoGroupDone, Slot);
    Msgs.Request('getSupergroupFullInfo', '"supergroup_id":' + utf8string(IntToStr(Row.SupergroupId)),
      @InfoGroupFullDone, Slot);
  end else if Row.BasicGroupId <> 0 then begin
    Msgs.Request('getBasicGroup', '"basic_group_id":' + utf8string(IntToStr(Row.BasicGroupId)),
      @InfoGroupDone, Slot);
    Msgs.Request('getBasicGroupFullInfo', '"basic_group_id":' + utf8string(IntToStr(Row.BasicGroupId)),
      @InfoGroupFullDone, Slot);
  end;
  for I := 0 to High(INFO_COUNT_FILTERS) do begin
    Msgs.Request('getChatMessageCount',
      '"chat_id":' + utf8string(IntToStr(ChatId)) + ',"topic_id":null,"filter":{"@type":"' +
      utf8string(INFO_COUNT_FILTERS[I]) + '"},"return_local":false',
      @InfoCountDone, Slot * INFO_TAG_MUL + I);
  end;
end;

{ Ещё один ответ пришёл: счётчик вниз, на нуле — ответ странице. }
procedure TWebApi.InfoStep(ASlot: PtrInt);
var
  Left: integer;
  Res: TJSONObject;
begin
  Left := FDeferred[ASlot].Held.Integers['left'] - 1;
  FDeferred[ASlot].Held.Integers['left'] := Left;
  if Left > 0 then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[ASlot].Held.Extract('reply'));
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

function TWebApi.InfoSlot(ASlot: PtrInt; out ARes: TJSONObject): boolean;
begin
  Result := (ASlot >= 0) and (ASlot <= High(FDeferred)) and FDeferred[ASlot].Busy
    and (FDeferred[ASlot].Held <> nil);
  ARes := nil;
  if Result then begin
    ARes := TJSONObject(FDeferred[ASlot].Held.Find('reply'));
    Result := ARes <> nil;
  end;
end;

{ user: телефон, имя пользователя, статус, контакт ли, бот ли. }
procedure TWebApi.InfoUserDone(Sender: TObject; const AResp: TTdResponse);
var
  Res, Status: TJSONObject;
begin
  if not InfoSlot(AResp.Tag, Res) then begin
    Exit;
  end;
  if AResp.Success then begin
    Res.Add('phone', string(JGetStr(AResp.Obj, 'phone_number')));
    Res.Add('username', string(JGetStr(JGetObj(AResp.Obj, 'usernames'), 'editable_username')));
    Res.Add('firstName', string(JGetStr(AResp.Obj, 'first_name')));
    Res.Add('lastName', string(JGetStr(AResp.Obj, 'last_name')));
    Res.Add('isContact', JGetBool(AResp.Obj, 'is_contact'));
    Status := JGetObj(AResp.Obj, 'status');
    Res.Add('status', string(JGetStr(Status, '@type')));
    Res.Add('wasOnline', JGetInt64(Status, 'was_online'));
    if JGetStr(JGetObj(AResp.Obj, 'type'), '@type') = 'userTypeBot' then begin
      Res.Strings['kind'] := 'bot';
    end;
  end;
  InfoStep(AResp.Tag);
end;

{ userFullInfo: «о себе», день рождения, блокировка, подарки, описание
  бота. }
procedure TWebApi.InfoUserFullDone(Sender: TObject; const AResp: TTdResponse);
var
  Res, Birth, B, Bot: TJSONObject;
begin
  if not InfoSlot(AResp.Tag, Res) then begin
    Exit;
  end;
  if AResp.Success then begin
    Res.Add('bio', string(JGetStr(JGetObj(AResp.Obj, 'bio'), 'text')));
    Birth := JGetObj(AResp.Obj, 'birthdate');
    if Birth <> nil then begin
      B := TJSONObject.Create;
      B.Add('day', JGetInt(Birth, 'day'));
      B.Add('month', JGetInt(Birth, 'month'));
      B.Add('year', JGetInt(Birth, 'year'));
      Res.Add('birthdate', B);
    end;
    { block_list: null — не заблокирован (td_api.tl). }
    Res.Add('isBlocked', JGetObj(AResp.Obj, 'block_list') <> nil);
    Res.Add('giftCount', JGetInt(AResp.Obj, 'gift_count'));
    Bot := JGetObj(AResp.Obj, 'bot_info');
    if Bot <> nil then begin
      Res.Add('description', string(JGetStr(Bot, 'description')));
    end;
  end;
  InfoStep(AResp.Tag);
end;

{ supergroup / basicGroup: число участников, публичная ссылка. }
procedure TWebApi.InfoGroupDone(Sender: TObject; const AResp: TTdResponse);
var
  Res: TJSONObject;
  User: utf8string;
begin
  if not InfoSlot(AResp.Tag, Res) then begin
    Exit;
  end;
  if AResp.Success then begin
    if Res.Find('memberCount') = nil then begin
      Res.Add('memberCount', JGetInt(AResp.Obj, 'member_count'));
    end;
    User := JGetStr(JGetObj(AResp.Obj, 'usernames'), 'editable_username');
    if User <> '' then begin
      Res.Add('username', string(User));
      Res.Add('link', 'https://t.me/' + string(User));
    end;
  end;
  InfoStep(AResp.Tag);
end;

{ supergroupFullInfo / basicGroupFullInfo: описание, участники, ссылка-
  приглашение (если публичной нет), можно ли смотреть участников. }
procedure TWebApi.InfoGroupFullDone(Sender: TObject; const AResp: TTdResponse);
var
  Res: TJSONObject;
  Invite: utf8string;
begin
  if not InfoSlot(AResp.Tag, Res) then begin
    Exit;
  end;
  if AResp.Success then begin
    Res.Add('description', string(JGetStr(AResp.Obj, 'description')));
    if JGetInt(AResp.Obj, 'member_count') > 0 then begin
      if Res.Find('memberCount') <> nil then begin
        Res.Integers['memberCount'] := JGetInt(AResp.Obj, 'member_count');
      end else begin
        Res.Add('memberCount', JGetInt(AResp.Obj, 'member_count'));
      end;
    end;
    { У basicGroupFullInfo поля can_get_members нет — список участников
      приходит в нём же. }
    if JGetStr(AResp.Obj, '@type') = 'basicGroupFullInfo' then begin
      Res.Add('canGetMembers', True);
    end else begin
      Res.Add('canGetMembers', JGetBool(AResp.Obj, 'can_get_members'));
    end;
    Invite := JGetStr(JGetObj(AResp.Obj, 'invite_link'), 'invite_link');
    if Invite <> '' then begin
      Res.Add('inviteLink', string(Invite));
    end;
  end;
  InfoStep(AResp.Tag);
end;

procedure TWebApi.InfoCountDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Idx: integer;
  Res: TJSONObject;
begin
  Slot := AResp.Tag div INFO_TAG_MUL;
  Idx := AResp.Tag mod INFO_TAG_MUL;
  if not InfoSlot(Slot, Res) then begin
    Exit;
  end;
  if AResp.Success and (Idx >= 0) and (Idx <= High(INFO_COUNT_KEYS)) then begin
    TJSONObject(Res.Objects['counts']).Add(INFO_COUNT_KEYS[Idx], JGetInt(AResp.Obj, 'count'));
  end;
  InfoStep(Slot);
end;

{ chat.members: участники группы — getSupergroupMembers (последние,
  до INFO_MEMBERS_MAX) или members из basicGroupFullInfo; затем getUser
  по каждому тем же путём, что контакты (ContactUserDone), с ролью из
  статуса участника. }
function TWebApi.CmdChatMembers(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Row: TChatRow;
  Slot: PtrInt;
begin
  Result := True;
  Msgs := RequireMsgs;
  Row := RequireChats.Lookup(AArgs.Get('chatId', Int64(0)));
  if Row = nil then begin
    raise Exception.Create('unknown chat');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('items', TJSONArray.Create);
  FDeferred[Slot].Held.Add('left', 0);
  FDeferred[Slot].Held.Add('replyKey', 'members');
  FDeferred[Slot].Held.Add('roles', TJSONObject.Create);
  if Row.SupergroupId <> 0 then begin
    Msgs.Request('getSupergroupMembers',
      '"supergroup_id":' + utf8string(IntToStr(Row.SupergroupId)) +
      ',"filter":{"@type":"supergroupMembersFilterRecent"},"offset":0,"limit":' +
      utf8string(IntToStr(INFO_MEMBERS_MAX)), @MembersListDone, Slot);
  end else if Row.BasicGroupId <> 0 then begin
    Msgs.Request('getBasicGroupFullInfo',
      '"basic_group_id":' + utf8string(IntToStr(Row.BasicGroupId)), @MembersListDone, Slot);
  end else begin
    Reply(AConnId, AReqId, TJSONObject.Create);
    ReleaseDeferred(Slot);
  end;
end;

{ chatMembers.members или basicGroupFullInfo.members: chatMember
  (member_id, status). Роль — по типу статуса: Creator / Administrator. }
procedure TWebApi.MembersListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  M, Sender2: TJSONObject;
  I, N: integer;
  Id: Int64;
  Role, St: utf8string;
  Roles, Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Roles := TJSONObject(FDeferred[Slot].Held.Objects['roles']);
  Arr := JGetArr(AResp.Obj, 'members');
  N := 0;
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      M := TJSONObject(Arr.Items[I]);
      Sender2 := JGetObj(M, 'member_id');
      if JGetStr(Sender2, '@type') <> 'messageSenderUser' then begin
        Continue;
      end;
      Id := JGetInt64(Sender2, 'user_id');
      St := JGetStr(JGetObj(M, 'status'), '@type');
      if St = 'chatMemberStatusCreator' then begin
        Role := 'owner';
      end else if St = 'chatMemberStatusAdministrator' then begin
        Role := 'admin';
      end else begin
        Role := '';
      end;
      Roles.Add(string(IntToStr(Id)), string(Role));
      Inc(N);
    end;
  end;
  if N = 0 then begin
    Res := TJSONObject.Create;
    Res.Add('members', TJSONArray.Create);
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
    Exit;
  end;
  FDeferred[Slot].Held.Integers['left'] := N;
  for I := 0 to Roles.Count - 1 do begin
    RequireMsgs.Request('getUser', '"user_id":' + utf8string(Roles.Names[I]), @ContactUserDone, Slot);
  end;
end;

{ Действия панели — по одному методу TDLib, ответ ok (SimpleDone):
  contact.add — addContact (importedContact: имя и фамилия; телефон не
  делим), contact.remove — removeContacts, user.block — setMessageSender-
  BlockList (blockListMain / null), chat.leave — leaveChat, contact.share
  — карточка контакта (inputMessageContact) в выбранный чат. }
function TWebApi.CmdInfoAction(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Act, Method, Body, UserId: utf8string;
begin
  Result := True;
  Msgs := RequireMsgs;
  Act := AArgs.Get('action', utf8string(''));
  UserId := utf8string(IntToStr(StrToInt64Def(AArgs.Get('userId', '0'), 0)));
  if Act = 'contact.add' then begin
    if TrimU(AArgs.Get('first', utf8string(''))) = '' then begin
      raise Exception.Create('First name cannot be empty');
    end;
    Method := 'addContact';
    Body := '"user_id":' + UserId + ',"contact":{"@type":"importedContact","phone_number":""' +
      ',"first_name":' + JsonStr(TrimU(AArgs.Get('first', utf8string('')))) +
      ',"last_name":' + JsonStr(TrimU(AArgs.Get('last', utf8string('')))) +
      ',"note":{"@type":"formattedText","text":""}},"share_phone_number":false';
  end else if Act = 'contact.remove' then begin
    Method := 'removeContacts';
    Body := '"user_ids":[' + UserId + ']';
  end else if Act = 'user.block' then begin
    Method := 'setMessageSenderBlockList';
    if AArgs.Get('block', False) then begin
      Body := '"sender_id":{"@type":"messageSenderUser","user_id":' + UserId +
        '},"block_list":{"@type":"blockListMain"}';
    end else begin
      Body := '"sender_id":{"@type":"messageSenderUser","user_id":' + UserId +
        '},"block_list":null';
    end;
  end else if Act = 'chat.leave' then begin
    Method := 'leaveChat';
    Body := '"chat_id":' + utf8string(IntToStr(StrToInt64Def(AArgs.Get('chatId', '0'), 0)));
  end else if Act = 'contact.share' then begin
    Method := 'sendMessage';
    Body := '"chat_id":' + utf8string(IntToStr(StrToInt64Def(AArgs.Get('toChatId', '0'), 0))) +
      ',"input_message_content":{"@type":"inputMessageContact","contact":{"@type":"contact"' +
      ',"phone_number":' + JsonStr(utf8string(AArgs.Get('phone', ''))) +
      ',"first_name":' + JsonStr(utf8string(AArgs.Get('first', ''))) +
      ',"last_name":' + JsonStr(utf8string(AArgs.Get('last', ''))) +
      ',"vcard":"","user_id":' + UserId + '}}';
  end else begin
    raise Exception.Create('unknown action: ' + string(Act));
  end;
  Msgs.Request(Method, Body, @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ ------------------------------------------------------------------ }
{ подарки профиля                                                    }
{ ------------------------------------------------------------------ }

{ Стикер подарка для страницы: id файла, формат (stickerFormat*) и адрес,
  если уже на диске. }
function GiftStickerJson(ASticker: TJSONObject): TJSONObject;
var
  FileObj, Local: TJSONObject;
  Fmt: utf8string;
begin
  Result := TJSONObject.Create;
  FileObj := JGetObj(ASticker, 'sticker');
  Result.Add('fileId', JGetInt(FileObj, 'id'));
  Fmt := JGetStr(JGetObj(ASticker, 'format'), '@type');
  if Fmt = 'stickerFormatTgs' then begin
    Result.Add('format', 'tgs');
  end else if Fmt = 'stickerFormatWebm' then begin
    Result.Add('format', 'webm');
  end else begin
    Result.Add('format', 'webp');
  end;
  Result.Add('url', '');
  Local := JGetObj(FileObj, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    Result.Strings['url'] := string(FileUrl(JGetInt(FileObj, 'id'), JGetStr(Local, 'path')));
  end;
end;

{ Имя отправителя подарка: messageSenderUser — модель пользователей,
  messageSenderChat — название чата; нет отправителя — ''. }
function GiftSenderName(ASender: TJSONObject): utf8string;
var
  Users: TTdUsers;
  U: TUserRow;
  Chats: TTdChats;
  Row: TChatRow;
begin
  Result := '';
  if ASender = nil then begin
    Exit;
  end;
  if JGetStr(ASender, '@type') = 'messageSenderUser' then begin
    Users := TdUserList;
    if Users <> nil then begin
      U := Users.Find(JGetInt64(ASender, 'user_id'));
      if U <> nil then begin
        Result := U.DisplayName;
      end;
    end;
  end else begin
    Chats := TdChatList;
    if Chats <> nil then begin
      Row := Chats.Lookup(JGetInt64(ASender, 'chat_id'));
      if Row <> nil then begin
        Result := Row.Title;
      end;
    end;
  end;
end;

{ Аватарка отправителя подарка — как в нативном клиенте, кружок в углу
  плитки: человек — модель пользователей (фото докачивается там же),
  канал или группа — строка чата. Пишет avatar, avatarThumb, color в
  AItem; без отправителя — пусто. }
procedure GiftSenderAvatar(AItem, ASender: TJSONObject);
var
  Users: TTdUsers;
  U: TUserRow;
  Chats: TTdChats;
  Row: TChatRow;
  Id: Int64;
begin
  AItem.Add('senderAvatar', '');
  AItem.Add('senderThumb', '');
  AItem.Add('senderColor', 'a5');
  { Куда вести клик по имени отправителя: личка с человеком или сам чат. }
  AItem.Add('senderUserId', '');
  AItem.Add('senderChatId', '');
  if ASender = nil then begin
    Exit;
  end;
  if JGetStr(ASender, '@type') = 'messageSenderUser' then begin
    AItem.Strings['senderUserId'] := string(IntToStr(JGetInt64(ASender, 'user_id')));
  end else begin
    AItem.Strings['senderChatId'] := string(IntToStr(JGetInt64(ASender, 'chat_id')));
  end;
  if JGetStr(ASender, '@type') = 'messageSenderUser' then begin
    Id := JGetInt64(ASender, 'user_id');
    AItem.Strings['senderColor'] := string(AccentKeyFor(-1, Id));
    Users := TdUserList;
    if Users = nil then begin
      Exit;
    end;
    U := Users.Find(Id);
    if U = nil then begin
      Exit;
    end;
    AItem.Strings['senderColor'] := string(AccentKeyFor(U.AccentColorId, Id));
    AItem.Strings['senderAvatar'] := string(FileUrl(U.PhotoFileId, U.PhotoPath));
    AItem.Strings['senderThumb'] := string(ThumbDataUri(U.Minithumb));
    if U.PhotoPath = '' then begin
      Users.EnsurePhoto(U);
    end;
  end else begin
    Chats := TdChatList;
    if Chats = nil then begin
      Exit;
    end;
    Row := Chats.Lookup(JGetInt64(ASender, 'chat_id'));
    if Row = nil then begin
      Exit;
    end;
    AItem.Strings['senderColor'] := string(AccentKey(Row));
    AItem.Strings['senderAvatar'] := string(FileUrl(Row.PhotoFileId, Row.PhotoPath));
    AItem.Strings['senderThumb'] := string(ThumbDataUri(Row.Minithumb));
  end;
end;

{ gifts.list: getReceivedGifts (td_api.tl коммита d1085f9) для владельца
  чата — человек (messageSenderUser) или канал (messageSenderChat). Вид
  (kind) — флаги exclude_*: unlimited, limited (с улучшением и без),
  unique (улучшенные); sortByPrice — sort_by_price; offset — для «ещё».
  Стикеры подарков докачиваются до ответа — по одному на разный файл. }
function TWebApi.CmdGiftsList(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  Row: TChatRow;
  Owner, Kind, Flags: utf8string;
  Slot: PtrInt;
begin
  Result := True;
  Msgs := RequireMsgs;
  Chats := RequireChats;
  Row := Chats.Lookup(AArgs.Get('chatId', Int64(0)));
  if Row = nil then begin
    raise Exception.Create('unknown chat');
  end;
  if (Row.Kind = ckPrivate) and (Row.UserId <> 0) then begin
    Owner := '{"@type":"messageSenderUser","user_id":' + utf8string(IntToStr(Row.UserId)) + '}';
  end else begin
    Owner := '{"@type":"messageSenderChat","chat_id":' + utf8string(IntToStr(Row.Id)) + '}';
  end;
  Kind := AArgs.Get('kind', utf8string('all'));
  Flags := '"exclude_unsaved":false,"exclude_saved":false';
  if Kind = 'unlimited' then begin
    Flags := Flags + ',"exclude_unlimited":false,"exclude_upgradable":true,' +
      '"exclude_non_upgradable":true,"exclude_upgraded":true';
  end else if Kind = 'limited' then begin
    Flags := Flags + ',"exclude_unlimited":true,"exclude_upgradable":false,' +
      '"exclude_non_upgradable":false,"exclude_upgraded":true';
  end else if Kind = 'unique' then begin
    Flags := Flags + ',"exclude_unlimited":true,"exclude_upgradable":true,' +
      '"exclude_non_upgradable":true,"exclude_upgraded":false';
  end else begin
    Flags := Flags + ',"exclude_unlimited":false,"exclude_upgradable":false,' +
      '"exclude_non_upgradable":false,"exclude_upgraded":false';
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  Msgs.Request('getReceivedGifts',
    '"business_connection_id":"","owner_id":' + Owner + ',"collection_id":0,' + Flags +
    ',"exclude_without_colors":false,"exclude_hosted":false,"sort_by_price":' +
    BoolJson(AArgs.Get('sortByPrice', False)) +
    ',"offset":' + JsonStr(utf8string(AArgs.Get('offset', ''))) +
    ',"limit":' + utf8string(IntToStr(GIFTS_PAGE)),
    @GiftsListDone, Slot);
end;

procedure TWebApi.GiftsListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr, Out: TJSONArray;
  G, Gift, Inner, Item, Model, Res: TJSONObject;
  I: integer;
  IsUnique: boolean;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Out := TJSONArray.Create;
  Arr := JGetArr(AResp.Obj, 'gifts');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      G := TJSONObject(Arr.Items[I]);
      Gift := JGetObj(G, 'gift');
      Inner := JGetObj(Gift, 'gift');
      if Inner = nil then begin
        Continue;
      end;
      IsUnique := JGetStr(Gift, '@type') = 'sentGiftUpgraded';
      Item := TJSONObject.Create;
      Item.Add('id', string(JGetStr(G, 'received_gift_id')));
      Item.Add('date', JGetInt64(G, 'date'));
      Item.Add('text', string(JGetStr(JGetObj(G, 'text'), 'text')));
      Item.Add('sender', string(GiftSenderName(JGetObj(G, 'sender_id'))));
      GiftSenderAvatar(Item, JGetObj(G, 'sender_id'));
      Item.Add('isPrivate', JGetBool(G, 'is_private'));
      Item.Add('isSaved', JGetBool(G, 'is_saved'));
      Item.Add('sellStars', JGetInt64(G, 'sell_star_count'));
      Item.Add('unique', IsUnique);
      if IsUnique then begin
        Model := JGetObj(Inner, 'model');
        Item.Add('title', string(JGetStr(Inner, 'title')));
        Item.Add('number', JGetInt(Inner, 'number'));
        Item.Add('model', string(JGetStr(Model, 'name')));
        Item.Add('symbol', string(JGetStr(JGetObj(Inner, 'symbol'), 'name')));
        Item.Add('backdrop', string(JGetStr(JGetObj(Inner, 'backdrop'), 'name')));
        Item.Add('stars', 0);
        Item.Add('sticker', GiftStickerJson(JGetObj(Model, 'sticker')));
      end else begin
        Item.Add('title', '');
        Item.Add('stars', JGetInt64(Inner, 'star_count'));
        Item.Add('limited', JGetObj(Inner, 'overall_limits') <> nil);
        Item.Add('sticker', GiftStickerJson(JGetObj(Inner, 'sticker')));
      end;
      Out.Add(Item);
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('gifts', Out);
  Res.Add('total', JGetInt(AResp.Obj, 'total_count'));
  Res.Add('nextOffset', string(JGetStr(AResp.Obj, 'next_offset')));
  FDeferred[Slot].Held.Add('reply', Res);
  FDeferred[Slot].Held.Add('next', 0);
  GiftsNext(Slot);
end;

{ Следующий нескачанный стикер (один файл на все подарки с ним) —
  downloadFile synchronous; всё на месте — ответ. }
procedure TWebApi.GiftsNext(ASlot: PtrInt);
var
  Res, S: TJSONObject;
  Arr: TJSONArray;
  I: integer;
begin
  Res := TJSONObject(FDeferred[ASlot].Held.Objects['reply']);
  Arr := TJSONArray(Res.Arrays['gifts']);
  I := FDeferred[ASlot].Held.Integers['next'];
  while I < Arr.Count do begin
    S := TJSONObject(TJSONObject(Arr.Items[I]).Objects['sticker']);
    if (S.Strings['url'] = '') and (S.Integers['fileId'] <> 0) then begin
      Break;
    end;
    Inc(I);
  end;
  FDeferred[ASlot].Held.Integers['next'] := I;
  if I < Arr.Count then begin
    S := TJSONObject(TJSONObject(Arr.Items[I]).Objects['sticker']);
    RequireMsgs.Request('downloadFile',
      '"file_id":' + utf8string(IntToStr(S.Integers['fileId'])) +
      ',"priority":16,"offset":0,"limit":0,"synchronous":true', @GiftFileDone, ASlot);
    Exit;
  end;
  Res := TJSONObject(FDeferred[ASlot].Held.Extract('reply'));
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

procedure TWebApi.GiftFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, S, Local: TJSONObject;
  Arr: TJSONArray;
  I, FileId: integer;
  Url: string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  Res := TJSONObject(FDeferred[Slot].Held.Objects['reply']);
  Arr := TJSONArray(Res.Arrays['gifts']);
  I := FDeferred[Slot].Held.Integers['next'];
  if I >= Arr.Count then begin
    GiftsNext(Slot);
    Exit;
  end;
  FileId := TJSONObject(TJSONObject(Arr.Items[I]).Objects['sticker']).Integers['fileId'];
  Url := '-';
  if AResp.Success then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      Url := string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
    end;
  end;
  { Тот же файл у других подарков — тем же адресом; '-' — не скачалось,
    дальше не ждём. }
  for I := 0 to Arr.Count - 1 do begin
    S := TJSONObject(TJSONObject(Arr.Items[I]).Objects['sticker']);
    if S.Integers['fileId'] = FileId then begin
      S.Strings['url'] := Url;
    end;
  end;
  GiftsNext(Slot);
end;

{ ------------------------------------------------------------------ }
{ медиа чата в панели информации: фото, видео, GIF, музыка, ссылки   }
{ ------------------------------------------------------------------ }

{ photoSize для превью: первый не меньше ASide по длинной стороне (размеры
  в photo.sizes идут по возрастанию), нет такого — самый большой. Файл
  выбранного размера (поле photo); нет размеров — nil. Годится и для
  chatPhoto — у него тот же sizes. }
function PickPhotoFile(APhoto: TJSONObject; ASide: integer): TJSONObject;
var
  Sizes: TJSONArray;
  Size: TJSONObject;
  J, Side: integer;
begin
  Result := nil;
  Sizes := JGetArr(APhoto, 'sizes');
  if (Sizes = nil) or (Sizes.Count = 0) then begin
    Exit;
  end;
  Size := nil;
  for J := 0 to Sizes.Count - 1 do begin
    if not (Sizes.Items[J] is TJSONObject) then begin
      Continue;
    end;
    Size := TJSONObject(Sizes.Items[J]);
    Side := JGetInt(Size, 'width');
    if JGetInt(Size, 'height') > Side then begin
      Side := JGetInt(Size, 'height');
    end;
    if Side >= ASide then begin
      Break;
    end;
  end;
  Result := JGetObj(Size, 'photo');
end;

{ Картинка предпросмотра ссылки (linkPreviewType*, td_api.tl коммита
  d1085f9): photo у статьи, фото, приложения, чата и прочих, thumbnail у
  встроенных плееров, cover у видео. Нет ничего — nil. }
function LinkPreviewPhoto(APreview: TJSONObject): TJSONObject;
var
  T: TJSONObject;
begin
  T := JGetObj(APreview, 'type');
  Result := JGetObj(T, 'photo');
  if Result = nil then begin
    Result := JGetObj(T, 'thumbnail');
  end;
  if Result = nil then begin
    Result := JGetObj(T, 'cover');
  end;
end;

{ Превью-файл thumbnail (видео, GIF, обложка альбома): JPEG — картинкой,
  MPEG4 — роликом (у GIF обычно так); прочие форматы не показать — nil.
  AKind получает 'img' или 'video'. }
function ThumbFile(AThumb: TJSONObject; out AKind: utf8string): TJSONObject;
var
  Fmt: utf8string;
begin
  Result := nil;
  AKind := 'img';
  Fmt := JGetStr(JGetObj(AThumb, 'format'), '@type');
  if (Fmt = 'thumbnailFormatJpeg') or (Fmt = 'thumbnailFormatPng') or
     (Fmt = 'thumbnailFormatWebp') or (Fmt = 'thumbnailFormatGif') then begin
    Result := JGetObj(AThumb, 'file');
  end else if Fmt = 'thumbnailFormatMpeg4' then begin
    AKind := 'video';
    Result := JGetObj(AThumb, 'file');
  end;
end;

{ Адреса из текста: сущности textEntityTypeUrl (offset/length — в UTF-16,
  режет страница: у неё строки в той же единице) и textEntityTypeTextUrl
  (адрес в самой сущности). }
function UrlEntitiesJson(AText: TJSONObject): TJSONArray;
var
  Ents: TJSONArray;
  E, T, Item: TJSONObject;
  I: integer;
  ET: utf8string;
begin
  Result := TJSONArray.Create;
  Ents := JGetArr(AText, 'entities');
  if Ents = nil then begin
    Exit;
  end;
  for I := 0 to Ents.Count - 1 do begin
    if not (Ents.Items[I] is TJSONObject) then begin
      Continue;
    end;
    E := TJSONObject(Ents.Items[I]);
    T := JGetObj(E, 'type');
    ET := JGetStr(T, '@type');
    if (ET <> 'textEntityTypeUrl') and (ET <> 'textEntityTypeTextUrl') then begin
      Continue;
    end;
    Item := TJSONObject.Create;
    Item.Add('offset', JGetInt(E, 'offset'));
    Item.Add('length', JGetInt(E, 'length'));
    Item.Add('url', string(JGetStr(T, 'url')));
    Result.Add(Item);
  end;
end;

{ media.list: медиа чата для панели информации, как у нативного клиента —
  searchChatMessages (td_api.tl коммита d1085f9) с фильтром по виду
  (filter: photo, video, gif, audio, link, voice, file, pinned), от
  новых к старым; from —
  next_from_message_id прошлой страницы (0 — с начала). Историю это не
  трогает: фильтр модели (search.set) остаётся каким был. }
function TWebApi.CmdMediaList(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Kind, Filter: utf8string;
  Slot: PtrInt;
begin
  Result := True;
  Msgs := RequireMsgs;
  Kind := AArgs.Get('filter', utf8string(''));
  if Kind = 'video' then begin
    Filter := 'searchMessagesFilterVideo';
  end else if Kind = 'gif' then begin
    Filter := 'searchMessagesFilterAnimation';
  end else if Kind = 'audio' then begin
    Filter := 'searchMessagesFilterAudio';
  end else if Kind = 'link' then begin
    Filter := 'searchMessagesFilterUrl';
  end else if Kind = 'voice' then begin
    Filter := 'searchMessagesFilterVoiceNote';
  end else if Kind = 'file' then begin
    Filter := 'searchMessagesFilterDocument';
  end else if Kind = 'pinned' then begin
    Filter := 'searchMessagesFilterPinned';
  end else begin
    Kind := 'photo';
    Filter := 'searchMessagesFilterPhoto';
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('kind', string(Kind));
  Msgs.Request('searchChatMessages',
    '"chat_id":' + utf8string(IntToStr(AArgs.Get('chatId', Int64(0)))) +
    ',"query":"","from_message_id":' + utf8string(IntToStr(AArgs.Get('from', Int64(0)))) +
    ',"offset":0,"limit":' + utf8string(IntToStr(MEDIA_GRID_PAGE)) +
    ',"filter":{"@type":"' + Filter + '"}',
    @MediaListDone, Slot);
end;

{ Запись на сообщение: id, date, вид, minithumbnail (размытая подложка
  сразу), превью (fileId, url, если файл уже на диске; thumbKind — img
  или video) и поля вида:
    photo — превью: photoSize от MEDIA_GRID_THUMB_SIDE;
    video, gif — thumbnail (JPEG или MPEG4), duration;
    audio — title, performer, fileName, duration, обложка альбома;
    voice — duration, isListened, отправитель (sender и аватарка, как у
      подарков: GiftSenderName / GiftSenderAvatar);
    file — fileName, size, mime, превью документа (только картинкой);
    pinned — любое сообщение: text (превью, как в списке чатов —
      MessagePreview), отправитель и картинка, если она есть (фото —
      photoSize от MEDIA_LINK_THUMB_SIDE, видео, GIF, документ — их
      JPEG-превью);
    link — text и urls (сущности-адреса из текста или подписи), preview
      (url, siteName, title, description) и его картинка — photoSize от
      MEDIA_LINK_THUMB_SIDE; нет предпросмотра — картинка самого фото.
  Нескачанные превью качаются все разом (downloadFile synchronous);
  Held['left'] считает ответы, на нуле — ответ странице. }
procedure TWebApi.MediaListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr, Out: TJSONArray;
  M, Content, Media, Mini, FileObj, Local, Item, Res, Text, Preview, PJ: TJSONObject;
  I, Left: integer;
  Want, CType, B64, TKind: utf8string;
  Thumb: RawByteString;
  Glyphs: TPreviewGlyphArray;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Want := FDeferred[Slot].Held.Get('kind', 'photo');
  Out := TJSONArray.Create;
  Arr := JGetArr(AResp.Obj, 'messages');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      M := TJSONObject(Arr.Items[I]);
      Content := JGetObj(M, 'content');
      CType := JGetStr(Content, '@type');
      Item := TJSONObject.Create;
      Item.Add('id', JGetInt64(M, 'id'));
      Item.Add('date', JGetInt64(M, 'date'));
      Item.Add('kind', string(Want));
      FileObj := nil;
      Mini := nil;
      TKind := 'img';
      if Want = 'pinned' then begin
        Item.Add('text', string(MessagePreview(Content, Glyphs)));
        Item.Add('sender', string(GiftSenderName(JGetObj(M, 'sender_id'))));
        GiftSenderAvatar(Item, JGetObj(M, 'sender_id'));
        if CType = 'messagePhoto' then begin
          Media := JGetObj(Content, 'photo');
          FileObj := PickPhotoFile(Media, MEDIA_LINK_THUMB_SIDE);
        end else if CType = 'messageVideo' then begin
          Media := JGetObj(Content, 'video');
          FileObj := ThumbFile(JGetObj(Media, 'thumbnail'), TKind);
        end else if CType = 'messageAnimation' then begin
          Media := JGetObj(Content, 'animation');
          FileObj := ThumbFile(JGetObj(Media, 'thumbnail'), TKind);
        end else if CType = 'messageDocument' then begin
          Media := JGetObj(Content, 'document');
          FileObj := ThumbFile(JGetObj(Media, 'thumbnail'), TKind);
        end else begin
          Media := nil;
        end;
        Mini := JGetObj(Media, 'minithumbnail');
        { В строке — только картинка. }
        if TKind <> 'img' then begin
          FileObj := nil;
          TKind := 'img';
        end;
      end else if Want = 'link' then begin
        Text := JGetObj(Content, 'text');
        if Text = nil then begin
          Text := JGetObj(Content, 'caption');
        end;
        Item.Add('text', string(JGetStr(Text, 'text')));
        Item.Add('urls', UrlEntitiesJson(Text));
        Preview := JGetObj(Content, 'link_preview');
        if Preview <> nil then begin
          PJ := TJSONObject.Create;
          PJ.Add('url', string(JGetStr(Preview, 'url')));
          PJ.Add('siteName', string(JGetStr(Preview, 'site_name')));
          PJ.Add('title', string(JGetStr(Preview, 'title')));
          PJ.Add('description', string(JGetStr(JGetObj(Preview, 'description'), 'text')));
          Item.Add('preview', PJ);
          Media := LinkPreviewPhoto(Preview);
        end else if CType = 'messagePhoto' then begin
          Media := JGetObj(Content, 'photo');
        end else begin
          Media := nil;
        end;
        Mini := JGetObj(Media, 'minithumbnail');
        FileObj := PickPhotoFile(Media, MEDIA_LINK_THUMB_SIDE);
      end else if CType = 'messagePhoto' then begin
        Media := JGetObj(Content, 'photo');
        Mini := JGetObj(Media, 'minithumbnail');
        FileObj := PickPhotoFile(Media, MEDIA_GRID_THUMB_SIDE);
      end else if (CType = 'messageVideo') or (CType = 'messageAnimation') then begin
        if CType = 'messageVideo' then begin
          Media := JGetObj(Content, 'video');
        end else begin
          Media := JGetObj(Content, 'animation');
        end;
        Mini := JGetObj(Media, 'minithumbnail');
        FileObj := ThumbFile(JGetObj(Media, 'thumbnail'), TKind);
        Item.Add('duration', JGetInt(Media, 'duration'));
      end else if CType = 'messageAudio' then begin
        Media := JGetObj(Content, 'audio');
        Mini := JGetObj(Media, 'album_cover_minithumbnail');
        FileObj := ThumbFile(JGetObj(Media, 'album_cover_thumbnail'), TKind);
        { Обложка-ролик в строке списка ни к чему. }
        if TKind <> 'img' then begin
          FileObj := nil;
          TKind := 'img';
        end;
        Item.Add('duration', JGetInt(Media, 'duration'));
        Item.Add('title', string(JGetStr(Media, 'title')));
        Item.Add('performer', string(JGetStr(Media, 'performer')));
        Item.Add('fileName', string(JGetStr(Media, 'file_name')));
      end else if CType = 'messageVoiceNote' then begin
        Media := JGetObj(Content, 'voice_note');
        Item.Add('duration', JGetInt(Media, 'duration'));
        Item.Add('isListened', JGetBool(Content, 'is_listened'));
        Item.Add('sender', string(GiftSenderName(JGetObj(M, 'sender_id'))));
        GiftSenderAvatar(Item, JGetObj(M, 'sender_id'));
      end else if CType = 'messageDocument' then begin
        Media := JGetObj(Content, 'document');
        Mini := JGetObj(Media, 'minithumbnail');
        FileObj := ThumbFile(JGetObj(Media, 'thumbnail'), TKind);
        if TKind <> 'img' then begin
          FileObj := nil;
          TKind := 'img';
        end;
        Item.Add('fileName', string(JGetStr(Media, 'file_name')));
        Item.Add('mime', string(JGetStr(Media, 'mime_type')));
        Local := JGetObj(Media, 'document');
        if JGetInt64(Local, 'size') > 0 then begin
          Item.Add('size', JGetInt64(Local, 'size'));
        end else begin
          Item.Add('size', JGetInt64(Local, 'expected_size'));
        end;
      end else begin
        Item.Free;
        Continue;
      end;
      Item.Add('thumb', '');
      B64 := JGetStr(Mini, 'data');
      if B64 <> '' then begin
        try
          Thumb := DecodeStringBase64(string(B64));
          Item.Strings['thumb'] := string(ThumbDataUri(Thumb));
        except
          { Битая подложка — без неё. }
        end;
      end;
      Item.Add('thumbKind', string(TKind));
      Item.Add('fileId', JGetInt(FileObj, 'id'));
      Item.Add('url', '');
      Local := JGetObj(FileObj, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Item.Strings['url'] := string(FileUrl(JGetInt(FileObj, 'id'), JGetStr(Local, 'path')));
      end;
      Out.Add(Item);
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('items', Out);
  Res.Add('total', JGetInt(AResp.Obj, 'total_count'));
  Res.Add('nextFrom', JGetInt64(AResp.Obj, 'next_from_message_id'));
  FDeferred[Slot].Held.Add('reply', Res);
  Left := 0;
  for I := 0 to Out.Count - 1 do begin
    Item := TJSONObject(Out.Items[I]);
    if (Item.Strings['url'] = '') and (Item.Integers['fileId'] <> 0) then begin
      Inc(Left);
    end;
  end;
  FDeferred[Slot].Held.Add('left', Left);
  for I := 0 to Out.Count - 1 do begin
    Item := TJSONObject(Out.Items[I]);
    if (Item.Strings['url'] = '') and (Item.Integers['fileId'] <> 0) then begin
      RequireMsgs.Request('downloadFile',
        '"file_id":' + utf8string(IntToStr(Item.Integers['fileId'])) +
        ',"priority":16,"offset":0,"limit":0,"synchronous":true', @MediaFileDone, Slot);
    end;
  end;
  MediaReplyIfDone(Slot);
end;

procedure TWebApi.MediaFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  Item, Local: TJSONObject;
  I, FileId: integer;
  Url: string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  { '-' — не скачалось: плитка остаётся с подложкой. Ответ ошибкой не
    называет файл, поэтому '-' получает первый ещё ждущий. }
  Url := '-';
  FileId := 0;
  if AResp.Success then begin
    FileId := JGetInt(AResp.Obj, 'id');
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      Url := string(FileUrl(FileId, JGetStr(Local, 'path')));
    end;
  end;
  Arr := TJSONArray(TJSONObject(FDeferred[Slot].Held.Objects['reply']).Arrays['items']);
  for I := 0 to Arr.Count - 1 do begin
    Item := TJSONObject(Arr.Items[I]);
    if Item.Strings['url'] <> '' then begin
      Continue;
    end;
    if (FileId = 0) and (Item.Integers['fileId'] <> 0) then begin
      Item.Strings['url'] := Url;
      Break;
    end;
    if (FileId <> 0) and (Item.Integers['fileId'] = FileId) then begin
      Item.Strings['url'] := Url;
    end;
  end;
  FDeferred[Slot].Held.Integers['left'] := FDeferred[Slot].Held.Integers['left'] - 1;
  MediaReplyIfDone(Slot);
end;

procedure TWebApi.MediaReplyIfDone(ASlot: PtrInt);
begin
  if FDeferred[ASlot].Held.Integers['left'] > 0 then begin
    Exit;
  end;
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId,
    TJSONObject(FDeferred[ASlot].Held.Extract('reply')));
  ReleaseDeferred(ASlot);
end;

{ message.translate (id, lang) — перевод текста или подписи сообщения
  открытого чата на стороне Telegram: translateMessageText (td_api.tl
  коммита d1085f9; tone "" — нейтральный). Ответ — formattedText;
  форматирование Telegram сохраняет только у Premium. Странице — text и
  entities в том же виде, что у сообщения. }
function TWebApi.CmdMessageTranslate(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Id: Int64;
  Lang: utf8string;
begin
  Result := True;
  Msgs := RequireMsgs;
  Id := ArgId(AArgs, 'id');
  Lang := AArgs.Get('lang', utf8string(''));
  if (Id = 0) or (Lang = '') or (Msgs.ChatId = 0) then begin
    raise Exception.Create('message.translate needs a message and a language');
  end;
  Msgs.Request('translateMessageText',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"message_id":' + utf8string(IntToStr(Id)) +
    ',"to_language_code":' + JsonStr(Lang) + ',"tone":""',
    @MessageTranslateDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Без Premium Telegram отдаёт перевод БЕЗ сущностей (проверено живым
  tdlib_raw.log: "entities":[] при ссылке в тексте) — ссылки, упоминания
  и хэштеги переставали быть ссылками. Тогда текст ещё раз проходит
  getTextEntities (находит URL, почту, @упоминания, #хэштеги — td_api.tl
  коммита d1085f9), и найденное ставится на свои места. Перевод с
  форматированием (Premium) остаётся как есть. }
procedure TWebApi.MessageTranslateDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Ents: TJSONArray;
  Text: utf8string;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Ents := JGetArr(AResp.Obj, 'entities');
  Text := JGetStr(AResp.Obj, 'text');
  if ((Ents = nil) or (Ents.Count = 0)) and (Text <> '') then begin
    FDeferred[Slot].Held := TJSONObject.Create;
    FDeferred[Slot].Held.Add('text', string(Text));
    RequireMsgs.Request('getTextEntities', '"text":' + JsonStr(Text),
      @TranslateEntitiesDone, Slot);
    Exit;
  end;
  TranslateReply(Slot, AResp.Obj);
end;

procedure TWebApi.TranslateEntitiesDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  FT: TJSONObject;
  Arr: TJSONArray;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  FT := TJSONObject.Create;
  try
    FT.Add('@type', 'formattedText');
    FT.Add('text', FDeferred[Slot].Held.Get('text', ''));
    Arr := nil;
    if AResp.Success then begin
      Arr := JGetArr(AResp.Obj, 'entities');
    end;
    if Arr <> nil then begin
      FT.Add('entities', Arr.Clone);
    end else begin
      FT.Add('entities', TJSONArray.Create);
    end;
    TranslateReply(Slot, FT);
  finally
    FT.Free;
  end;
end;

procedure TWebApi.TranslateReply(ASlot: PtrInt; AFormatted: TJSONObject);
var
  Res: TJSONObject;
  Text: utf8string;
  Ents: TMsgEntityArray;
begin
  RequireMsgs.ParseFormattedText(AFormatted, Text, Ents);
  Res := TJSONObject.Create;
  Res.Add('text', string(Text));
  Res.Add('entities', EntitiesJson(Ents));
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

{ message.forward (id, toChatId) — пересылка из открытого чата:
  forwardMessages (td_api.tl коммита d1085f9) без topic_id и options,
  обычной пересылкой (send_copy false), с подписью. }
function TWebApi.CmdMessageForward(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Id, ToChat: Int64;
begin
  Result := True;
  Msgs := RequireMsgs;
  Id := ArgId(AArgs, 'id');
  ToChat := ArgId(AArgs, 'toChatId');
  if (Id = 0) or (ToChat = 0) or (Msgs.ChatId = 0) then begin
    raise Exception.Create('message.forward needs a message and a chat');
  end;
  Msgs.Request('forwardMessages',
    '"chat_id":' + utf8string(IntToStr(ToChat)) +
    ',"from_chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"message_ids":[' + utf8string(IntToStr(Id)) + ']' +
    ',"send_copy":false,"remove_caption":false',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ Кнопка «пользователь»: личка с ним (createPrivateChat), чтобы её открыть. }
function TWebApi.CmdBotUserChat(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('createPrivateChat',
    '"user_id":' + utf8string(AArgs.Get('userId', '0')) + ',"force":false',
    @LinkChatDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

{ ------------------------------------------------------------------ }
{ mini apps                                                          }
{ ------------------------------------------------------------------ }


{ Запуск мини-приложения. source: inline (кнопка под сообщением — бот
  это отправитель сообщения), menu (кнопка меню бота в личке), keyboard
  (кнопка клавиатуры — getWebAppUrl, без launch_id; данные приложения
  уходят боту через sendWebAppData). theme — цвета страницы под именами
  themeParameters ('#rrggbb'): TDLib получает их целыми RGB, а само
  приложение — в theme_changed под своими именами (bg_color и т.д.).
  Методы и поля — td_api.tl коммита d1085f9 (TDLib 1.8.67). }
function TWebApi.CmdWebAppOpen(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Chats: TTdChats;
  Row: TChatRow;
  Source, Url, Params, Key, Hex: utf8string;
  Bot: Int64;
  Idx, I, V: integer;
  Slot: PtrInt;
  Theme, Ints, Held: TJSONObject;
begin
  Msgs := RequireMsgs;
  Source := utf8string(AArgs.Get('source', ''));
  Url := utf8string(AArgs.Get('url', ''));
  Bot := 0;
  if Source = 'inline' then begin
    Idx := Msgs.IndexOfId(StrToInt64Def(utf8string(AArgs.Get('msgId', '')), 0));
    if Idx >= 0 then begin
      Bot := Msgs.Rows[Idx].SenderUserId;
    end;
  end else if Source = 'attach' then begin
    { Бот меню вложений (tdattachbots): openWebApp с пустым url. }
    Bot := StrToInt64Def(utf8string(AArgs.Get('botId', '')), 0);
  end else begin
    Chats := RequireChats;
    Row := Chats.Lookup(Msgs.ChatId);
    if (Row <> nil) and (Row.Kind = ckPrivate) then begin
      Bot := Row.UserId;
    end;
  end;
  if Bot = 0 then begin
    raise Exception.Create('No bot to open this app for');
  end;

  Ints := TJSONObject.Create;
  Held := TJSONObject.Create;
  try
    Ints.Add('@type', 'themeParameters');
    Theme := TJSONObject.Create;
    if AArgs.Find('theme') is TJSONObject then begin
      for I := 0 to TJSONObject(AArgs.Find('theme')).Count - 1 do begin
        Key := utf8string(TJSONObject(AArgs.Find('theme')).Names[I]);
        Hex := utf8string(TJSONObject(AArgs.Find('theme')).Items[I].AsString);
        if (Length(Hex) = 7) and (Hex[1] = '#')
           and TryStrToInt('$' + string(Copy(Hex, 2, 6)), V) then begin
          Ints.Add(string(Key), V);
          Theme.Add(StringReplace(string(Key), 'background', 'bg', []), string(Hex));
        end;
      end;
    end;
    Params := '{"@type":"webAppOpenParameters","theme":' + utf8string(Ints.AsJSON) +
      ',"application_name":' + JsonStr(MINIAPP_APP_NAME) +
      ',"mode":{"@type":"webAppOpenModeFullSize"}}';
    Held.Add('theme', Theme);
    Held.Add('bot', Bot);
    Held.Add('title', AArgs.Get('title', ''));
    Held.Add('buttonText', AArgs.Get('buttonText', ''));
  finally
    Ints.Free;
  end;

  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  if Source = 'keyboard' then begin
    Msgs.Request('getWebAppUrl',
      '"bot_user_id":' + utf8string(IntToStr(Bot)) + ',"url":' + JsonStr(Url) +
      ',"parameters":' + Params, @WebAppOpenDone, Slot);
  end else begin
    Msgs.Request('openWebApp',
      '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
      ',"bot_user_id":' + utf8string(IntToStr(Bot)) + ',"url":' + JsonStr(Url) +
      ',"parameters":' + Params, @WebAppOpenDone, Slot);
  end;
  Result := True;
end;

{ Ответ — webAppInfo (launch_id, url: webAppUrl) у openWebApp или сам
  webAppUrl у getWebAppUrl. Окно открывает не сервер: странице уходит
  всё, что нужно окну мини-приложения, — в нашем окне она отдаёт это
  оболочке (miniapp.pas), в браузере открывает адрес вкладкой. }
procedure TWebApi.WebAppOpenDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Held, UrlObj, Res: TJSONObject;
  Url: utf8string;
  Launch: Int64;
  Theme: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Held := FDeferred[Slot].Held;
  if JGetStr(AResp.Obj, '@type') = 'webAppInfo' then begin
    Launch := JGetInt64(AResp.Obj, 'launch_id');
    UrlObj := JGetObj(AResp.Obj, 'url');
  end else begin
    Launch := 0;
    UrlObj := AResp.Obj;
  end;
  Url := JGetStr(UrlObj, 'url');
  if Url = '' then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, 'The bot sent no app address');
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('url', string(Url));
  Res.Add('title', Held.Get('title', ''));
  { Строками: int53/int64 в JS без потерь. }
  Res.Add('bot', IntToStr(Held.Get('bot', Int64(0))));
  Res.Add('launch', IntToStr(Launch));
  Res.Add('buttonText', Held.Get('buttonText', ''));
  Res.Add('theme', Held.Find('theme').Clone);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Запросы окна мини-приложения к TDLib (их передаёт страница: окно —
  в другом процессе и, может быть, на другой машине). Только эти четыре
  метода и только с этими полями — не общий проход к TDLib. }
function TWebApi.CmdWebAppClose(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('closeWebApp',
    '"web_app_launch_id":' + utf8string(IntToStr(StrToInt64Def(string(AArgs.Get('launch', '')), 0))),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

function TWebApi.CmdWebAppCustom(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('sendWebAppCustomRequest',
    '"bot_user_id":' + utf8string(IntToStr(StrToInt64Def(string(AArgs.Get('bot', '')), 0))) +
    ',"method":' + JsonStr(utf8string(AArgs.Get('method', ''))) +
    ',"parameters":' + JsonStr(utf8string(AArgs.Get('params', '{}'))),
    @WebAppCustomDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

{ customRequestResult.result — JSON строкой; разбирает её окно. }
procedure TWebApi.WebAppCustomDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('result', string(JGetStr(AResp.Obj, 'result')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

function TWebApi.CmdWebAppAllowWrite(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('allowBotToSendMessages',
    '"bot_user_id":' + utf8string(IntToStr(StrToInt64Def(string(AArgs.Get('bot', '')), 0))),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

function TWebApi.CmdWebAppSendData(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('sendWebAppData',
    '"bot_user_id":' + utf8string(IntToStr(StrToInt64Def(string(AArgs.Get('bot', '')), 0))) +
    ',"button_text":' + JsonStr(utf8string(AArgs.Get('buttonText', ''))) +
    ',"data":' + JsonStr(utf8string(AArgs.Get('data', ''))),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

{ Кнопки-запросы клавиатуры бота: поделиться пользователями, чатом,
  своим номером. Источник кнопки — сообщение с клавиатурой
  (keyboardButtonSourceMessage, td_api.tl 1.8.67: в этой версии
  shareUsersWithBot/shareChatWithBot принимают source, а не
  chat_id/message_id). }
function KeyboardSource(AChatId, AMsgId: Int64): utf8string;
begin
  Result := '{"@type":"keyboardButtonSourceMessage","chat_id":' +
    utf8string(IntToStr(AChatId)) + ',"message_id":' + utf8string(IntToStr(AMsgId)) + '}';
end;

{ Общий ответ «сделано / ошибка» для отложенных команд без данных. }
{ ------------------------------------------------------------------ }
{ видеочаты (групповые звонки чатов): tdcalls.pas; страница —         }
{ ui/videochat.js, calls/group.js                                    }
{ ------------------------------------------------------------------ }

{ groupCall для страницы — то, что нужно окну видеочата. }
function GroupCallToJson(AGroup: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('id', JGetInt(AGroup, 'id'));
  Result.Add('title', string(JGetStr(AGroup, 'title')));
  Result.Add('active', JGetBool(AGroup, 'is_active'));
  Result.Add('joined', JGetBool(AGroup, 'is_joined'));
  Result.Add('needRejoin', JGetBool(AGroup, 'need_rejoin'));
  Result.Add('canManage', JGetBool(AGroup, 'can_be_managed'));
  Result.Add('count', JGetInt(AGroup, 'participant_count'));
  Result.Add('scheduled', JGetInt(AGroup, 'scheduled_start_date'));
  Result.Add('rtmp', JGetBool(AGroup, 'is_rtmp_stream'));
  Result.Add('myVideo', JGetBool(AGroup, 'is_my_video_enabled'));
  Result.Add('canEnableVideo', JGetBool(AGroup, 'can_enable_video'));
  Result.Add('muteNew', JGetBool(AGroup, 'mute_new_participants'));
end;

{ Видеоканал участника: endpoint и группы SSRC (SIM/FID). nil — нет. }
function PartVideoJson(AInfo: TJSONObject): TJSONData;
var
  Res, G, Src: TJSONObject;
  Groups, Ids, Out: TJSONArray;
  I, J: integer;
begin
  if AInfo = nil then begin
    Result := TJSONNull.Create;
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('endpoint', string(JGetStr(AInfo, 'endpoint_id')));
  Res.Add('paused', JGetBool(AInfo, 'is_paused'));
  Out := TJSONArray.Create;
  Groups := JGetArr(AInfo, 'source_groups');
  if Groups <> nil then begin
    for I := 0 to Groups.Count - 1 do begin
      if Groups.Items[I].JSONType <> jtObject then begin
        Continue;
      end;
      Src := TJSONObject(Groups.Items[I]);
      G := TJSONObject.Create;
      G.Add('semantics', string(JGetStr(Src, 'semantics')));
      Ids := TJSONArray.Create;
      if JGetArr(Src, 'source_ids') <> nil then begin
        for J := 0 to JGetArr(Src, 'source_ids').Count - 1 do begin
          { SSRC — беззнаковые 32 бита, TDLib отдаёт int32: на странице
            приводятся к беззнаковым (>>> 0). }
          Ids.Add(JGetArr(Src, 'source_ids').Integers[J]);
        end;
      end;
      G.Add('sources', Ids);
      Out.Add(G);
    end;
  end;
  Res.Add('groups', Out);
  Result := Res;
end;

{ Участник видеочата для страницы. }
function PartToJson(APart: TJSONObject): TJSONObject;
var
  Sender: TJSONObject;
  Key: utf8string;
  Id: Int64;
  Users: TTdUsers;
  U: TUserRow;
  Chats: TTdChats;
  Row: TChatRow;
  Name: utf8string;
begin
  Result := TJSONObject.Create;
  Sender := JGetObj(APart, 'participant_id');
  Key := ParticipantKey(Sender);
  Result.Add('key', string(Key));
  Name := '';
  if JGetStr(Sender, '@type') = 'messageSenderUser' then begin
    Id := JGetInt64(Sender, 'user_id');
    Result.Add('kind', 'user');
    Users := TdUserList;
    if Users <> nil then begin
      U := Users.Find(Id);
      if U <> nil then begin
        Name := U.DisplayName;
      end;
    end;
    AddSenderAvatar(Result, Id, 0);
  end else begin
    Id := JGetInt64(Sender, 'chat_id');
    Result.Add('kind', 'chat');
    Chats := TdChatList;
    if Chats <> nil then begin
      Row := Chats.Lookup(Id);
      if Row <> nil then begin
        Name := Row.Title;
      end;
    end;
    AddSenderAvatar(Result, 0, Id);
  end;
  Result.Add('id', Id);
  Result.Add('name', string(Name));
  Result.Add('self', JGetBool(APart, 'is_current_user'));
  Result.Add('audioSource', JGetInt(APart, 'audio_source_id'));
  Result.Add('screenAudioSource', JGetInt(APart, 'screen_sharing_audio_source_id'));
  Result.Add('video', PartVideoJson(JGetObj(APart, 'video_info')));
  Result.Add('screen', PartVideoJson(JGetObj(APart, 'screen_sharing_video_info')));
  Result.Add('speaking', JGetBool(APart, 'is_speaking'));
  Result.Add('handRaised', JGetBool(APart, 'is_hand_raised'));
  Result.Add('mutedAll', JGetBool(APart, 'is_muted_for_all_users'));
  Result.Add('mutedMe', JGetBool(APart, 'is_muted_for_current_user'));
  Result.Add('canUnmuteSelf', JGetBool(APart, 'can_unmute_self'));
  Result.Add('canMuteAll', JGetBool(APart, 'can_be_muted_for_all_users'));
  Result.Add('canUnmuteAll', JGetBool(APart, 'can_be_unmuted_for_all_users'));
  Result.Add('volume', JGetInt(APart, 'volume_level'));
  Result.Add('order', string(JGetStr(APart, 'order')));
end;

{ 'u123' / 'c-100...' -> MessageSender JSON для запросов TDLib. }
function SenderFromKey(const AKey: utf8string): utf8string;
begin
  Result := '';
  if Length(AKey) < 2 then begin
    Exit;
  end;
  if AKey[1] = 'u' then begin
    Result := '{"@type":"messageSenderUser","user_id":'
      + utf8string(IntToStr(StrToInt64Def(string(Copy(AKey, 2, MaxInt)), 0))) + '}';
  end else if AKey[1] = 'c' then begin
    Result := '{"@type":"messageSenderChat","chat_id":'
      + utf8string(IntToStr(StrToInt64Def(string(Copy(AKey, 2, MaxInt)), 0))) + '}';
  end;
end;

procedure TWebApi.GroupCallChanged(Sender: TObject; AGroupCallId: integer);
var
  G: TJSONObject;
begin
  if not (Sender is TTdCalls) then begin
    Exit;
  end;
  G := TTdCalls(Sender).FindGroup(AGroupCallId);
  if G <> nil then begin
    PushEvent('vchat', GroupCallToJson(G));
  end;
end;

procedure TWebApi.GroupParticipantChanged(Sender: TObject; AGroupCallId: integer;
  AParticipant: TJSONObject);
var
  D: TJSONObject;
begin
  D := TJSONObject.Create;
  D.Add('callId', AGroupCallId);
  D.Add('participant', PartToJson(AParticipant));
  PushEvent('vchat.participant', D);
end;

procedure TWebApi.ChatVideoChatChanged(Sender: TObject; AChatId: Int64;
  AGroupCallId: integer; AHasParticipants: boolean);
var
  D: TJSONObject;
begin
  D := TJSONObject.Create;
  D.Add('chatId', AChatId);
  D.Add('groupCallId', AGroupCallId);
  D.Add('hasParticipants', AHasParticipants);
  PushEvent('chat.videochat', D);
end;

{ vchat.info (chatId): getChat -> video_chat.group_call_id; есть —
  getGroupCall. Ответ (groupCallId, call или null). }
function TWebApi.CmdVchatInfo(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  { Held — признак слота для AccountSlot. }
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getChat', '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))),
    @VchatChatDone, Slot);
end;

procedure TWebApi.VchatChatDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Id: integer;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Id := JGetInt(JGetObj(AResp.Obj, 'video_chat'), 'group_call_id');
  if Id = 0 then begin
    Res := TJSONObject.Create;
    Res.Add('groupCallId', 0);
    Res.Add('call', TJSONNull.Create);
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
    ReleaseDeferred(Slot);
    Exit;
  end;
  RequireMsgs.Request('getGroupCall', '"group_call_id":' + utf8string(IntToStr(Id)),
    @VchatGroupDone, Slot);
end;

procedure TWebApi.VchatGroupDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('groupCallId', JGetInt(AResp.Obj, 'id'));
  Res.Add('call', GroupCallToJson(AResp.Obj));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ vchat.join (groupCallId, ssrc, payload, muted, video): joinVideoChat ->
  Text с ответом SFU (payload). Сразу после — loadGroupCallParticipants:
  участники приходят обновлениями (событие vchat.participant). }
function TWebApi.CmdVchatJoin(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
const
  B: array[boolean] of utf8string = ('false', 'true');
var
  Id: integer;
  Slot: PtrInt;
begin
  Result := True;
  Id := integer(ArgId(AArgs, 'groupCallId'));
  if Id <= 0 then begin
    raise Exception.Create('vchat.join needs a groupCallId');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('groupCallId', Id);
  RequireMsgs.Request('joinVideoChat', '"group_call_id":' + utf8string(IntToStr(Id))
    + ',"join_parameters":{"@type":"groupCallJoinParameters","audio_source_id":'
    + utf8string(IntToStr(integer(AArgs.Get('ssrc', Int64(0)))))
    + ',"payload":' + JsonStr(utf8string(AArgs.Get('payload', '')))
    + ',"is_muted":' + B[AArgs.Get('muted', True)]
    + ',"is_my_video_enabled":' + B[AArgs.Get('video', False)]
    + '},"invite_hash":""',
    @VchatJoinDone, Slot);
end;

procedure TWebApi.VchatJoinDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  Id: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Id := FDeferred[Slot].Held.Get('groupCallId', 0);
  Res := TJSONObject.Create;
  Res.Add('payload', string(JGetStr(AResp.Obj, 'text')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
  RequireMsgs.Request('loadGroupCallParticipants', '"group_call_id":'
    + utf8string(IntToStr(Id)) + ',"limit":' + utf8string(IntToStr(VCHAT_LOAD_PARTICIPANTS)),
    nil, 0);
end;

{ vchat.participants (groupCallId): известные модели участники — для
  страницы, открытой посреди видеочата. }
function TWebApi.CmdVchatParticipants(AArgs: TJSONObject): TJSONData;
var
  Calls: TTdCalls;
  Map: TJSONObject;
  Arr: TJSONArray;
  I: integer;
  Res: TJSONObject;
begin
  Arr := TJSONArray.Create;
  Calls := TdCallList;
  if Calls <> nil then begin
    Map := Calls.GroupParticipants(integer(ArgId(AArgs, 'groupCallId')));
    if Map <> nil then begin
      for I := 0 to Map.Count - 1 do begin
        if Map.Items[I].JSONType = jtObject then begin
          Arr.Add(PartToJson(TJSONObject(Map.Items[I])));
        end;
      end;
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('participants', Arr);
  Result := Res;
end;

{ Простые команды видеочата — ответ (ok) или (groupCallId) у create:
    vchat.create (chatId)              createVideoChat
    vchat.leave (groupCallId)          leaveGroupCall
    vchat.end (groupCallId)            endGroupCall
    vchat.mute (groupCallId, key, muted)  toggleGroupCallParticipantIsMuted
    vchat.video (groupCallId, enabled)    toggleGroupCallIsMyVideoEnabled
    vchat.load (groupCallId)           loadGroupCallParticipants }
function TWebApi.CmdVchatSimple(const ACmd: utf8string; AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
const
  B: array[boolean] of utf8string = ('false', 'true');
var
  Id: utf8string;
  Who: utf8string;
  Calls: TTdCalls;
  Slot: PtrInt;
begin
  Result := True;
  if AArgs = nil then begin
    raise Exception.Create(string(ACmd) + ' needs arguments');
  end;
  Id := utf8string(IntToStr(ArgId(AArgs, 'groupCallId')));
  if ACmd = 'vchat.create' then begin
    Slot := TakeDeferred(AConnId, AReqId, 0);
    FDeferred[Slot].Held := TJSONObject.Create;
    RequireMsgs.Request('createVideoChat', '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId')))
      + ',"title":"","start_date":0,"is_rtmp_stream":false',
      @VchatCreateDone, Slot);
  end else if ACmd = 'vchat.leave' then begin
    Calls := TdCallList;
    if Calls <> nil then begin
      Calls.DropParticipants(integer(ArgId(AArgs, 'groupCallId')));
    end;
    RequireMsgs.Request('leaveGroupCall', '"group_call_id":' + Id,
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else if ACmd = 'vchat.end' then begin
    RequireMsgs.Request('endGroupCall', '"group_call_id":' + Id,
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else if ACmd = 'vchat.mute' then begin
    Who := SenderFromKey(utf8string(AArgs.Get('key', '')));
    if Who = '' then begin
      raise Exception.Create('vchat.mute needs a participant key');
    end;
    RequireMsgs.Request('toggleGroupCallParticipantIsMuted', '"group_call_id":' + Id
      + ',"participant_id":' + Who + ',"is_muted":' + B[AArgs.Get('muted', True)],
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else if ACmd = 'vchat.video' then begin
    RequireMsgs.Request('toggleGroupCallIsMyVideoEnabled', '"group_call_id":' + Id
      + ',"is_my_video_enabled":' + B[AArgs.Get('enabled', False)],
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end else begin
    RequireMsgs.Request('loadGroupCallParticipants', '"group_call_id":' + Id
      + ',"limit":' + utf8string(IntToStr(VCHAT_LOAD_PARTICIPANTS)),
      @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  end;
end;

procedure TWebApi.VchatCreateDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('groupCallId', JGetInt(AResp.Obj, 'id'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

procedure TWebApi.SimpleDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('ok', True);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

function TWebApi.CmdBotShareUsers(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Arr: TJSONArray;
  Ids: utf8string;
  I: integer;
begin
  Msgs := RequireMsgs;
  Ids := '';
  Arr := TJSONArray(AArgs.Find('userIds', jtArray));
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if Ids <> '' then begin
        Ids := Ids + ',';
      end;
      Ids := Ids + utf8string(IntToStr(StrToInt64Def(Arr.Strings[I], 0)));
    end;
  end;
  Msgs.Request('shareUsersWithBot',
    '"source":' + KeyboardSource(Msgs.ChatId, StrToInt64Def(utf8string(AArgs.Get('msgId', '')), 0)) +
    ',"button_id":' + utf8string(IntToStr(AArgs.Get('buttonId', 0))) +
    ',"shared_user_ids":[' + Ids + '],"only_check":false',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

function TWebApi.CmdBotShareChat(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
begin
  Msgs := RequireMsgs;
  Msgs.Request('shareChatWithBot',
    '"source":' + KeyboardSource(Msgs.ChatId, StrToInt64Def(utf8string(AArgs.Get('msgId', '')), 0)) +
    ',"button_id":' + utf8string(IntToStr(AArgs.Get('buttonId', 0))) +
    ',"shared_chat_id":' + utf8string(IntToStr(StrToInt64Def(utf8string(AArgs.Get('chatId', '')), 0))) +
    ',"only_check":false',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

{ «Поделиться номером»: как у клиентов Telegram — свой контакт
  сообщением в чат с ботом. Сначала getMe (номер и имя), потом
  sendMessage с inputMessageContact. }
function TWebApi.CmdBotSharePhone(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  RequireMsgs.Request('getMe', '', @SharePhoneMeDone, TakeDeferred(AConnId, AReqId, 0));
  Result := True;
end;

procedure TWebApi.SharePhoneMeDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Msgs: TTdMessages;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Msgs := TdMsgList;
  if (not AResp.Success) or (Msgs = nil) or (Msgs.ChatId = 0) then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, 'Could not read your phone number');
    ReleaseDeferred(Slot);
    Exit;
  end;
  Msgs.Request('sendMessage',
    '"chat_id":' + utf8string(IntToStr(Msgs.ChatId)) +
    ',"input_message_content":{"@type":"inputMessageContact","contact":{"@type":"contact"' +
    ',"phone_number":' + JsonStr(JGetStr(AResp.Obj, 'phone_number')) +
    ',"first_name":' + JsonStr(JGetStr(AResp.Obj, 'first_name')) +
    ',"last_name":' + JsonStr(JGetStr(AResp.Obj, 'last_name')) +
    ',"vcard":"","user_id":' + utf8string(IntToStr(JGetInt64(AResp.Obj, 'id'))) + '}}',
    @SimpleDone, Slot);
end;

{ ------------------------------------------------------------------ }
{ inline mode: "@bot query" in the composer                          }
{ ------------------------------------------------------------------ }

{ Результат инлайн-запроса для страницы: id, вид, заголовок, описание.
  Поля — по td_api.tl (inlineQueryResult*). Картинок пока нет: список
  текстом, как у нативного клиента для статей. }
function InlineResultJson(AItem: TJSONObject): TJSONObject;
var
  T, Title, Desc: utf8string;
  Sub: TJSONObject;
begin
  T := JGetStr(AItem, '@type');
  Title := JGetStr(AItem, 'title');
  Desc := JGetStr(AItem, 'description');
  if T = 'inlineQueryResultGame' then begin
    Sub := JGetObj(AItem, 'game');
    Title := JGetStr(Sub, 'title');
    Desc := JGetStr(Sub, 'description');
  end else if T = 'inlineQueryResultContact' then begin
    Sub := JGetObj(AItem, 'contact');
    Title := utf8string(Trim(string(JGetStr(Sub, 'first_name') + ' ' + JGetStr(Sub, 'last_name'))));
    Desc := JGetStr(Sub, 'phone_number');
  end else if T = 'inlineQueryResultVenue' then begin
    Sub := JGetObj(AItem, 'venue');
    Title := JGetStr(Sub, 'title');
    Desc := JGetStr(Sub, 'address');
  end else if T = 'inlineQueryResultAudio' then begin
    Sub := JGetObj(AItem, 'audio');
    Title := JGetStr(Sub, 'title');
    Desc := JGetStr(Sub, 'performer');
  end else if T = 'inlineQueryResultSticker' then begin
    Title := JGetStr(JGetObj(AItem, 'sticker'), 'emoji');
  end;
  Result := TJSONObject.Create;
  Result.Add('id', string(JGetStr(AItem, 'id')));
  { inlineQueryResultArticle -> article и т.д. }
  Result.Add('kind', LowerCase(Copy(string(T), Length('inlineQueryResult') + 1, MaxInt)));
  Result.Add('title', string(Title));
  Result.Add('description', string(Desc));
end;

{ Имя бота -> id: searchPublicChat, у лички id чата = id пользователя.
  Кэш — чтобы не искать заново на каждую набранную букву. }
function TWebApi.CmdInlineQuery(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Name: utf8string;
  Slot: PtrInt;
  I: integer;
begin
  Msgs := RequireMsgs;
  Name := utf8string(LowerCase(AArgs.Get('username', '')));
  if Name = '' then begin
    raise Exception.Create('inline.query needs a bot username');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('name', string(Name));
  FDeferred[Slot].Held.Add('query', AArgs.Get('query', ''));
  FDeferred[Slot].Held.Add('offset', AArgs.Get('offset', ''));
  I := FInlineBots.IndexOfName(string(Name));
  if I >= 0 then begin
    InlineAsk(Msgs, StrToInt64Def(FInlineBots.ValueFromIndex[I], 0), Slot);
  end else begin
    Msgs.Request('searchPublicChat', '"username":' + JsonStr(Name), @InlineBotDone, Slot);
  end;
  Result := True;
end;

procedure TWebApi.InlineAsk(AMsgs: TTdMessages; ABot: Int64; ASlot: PtrInt);
begin
  AMsgs.Request('getInlineQueryResults',
    '"bot_user_id":' + utf8string(IntToStr(ABot)) +
    ',"chat_id":' + utf8string(IntToStr(AMsgs.ChatId)) +
    ',"query":' + JsonStr(utf8string(FDeferred[ASlot].Held.Get('query', ''))) +
    ',"offset":' + JsonStr(utf8string(FDeferred[ASlot].Held.Get('offset', ''))),
    @InlineResultsDone, ASlot);
end;

procedure TWebApi.InlineBotDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Bot: Int64;
  Msgs: TTdMessages;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  Bot := 0;
  if AResp.Success and (JGetStr(JGetObj(AResp.Obj, 'type'), '@type') = 'chatTypePrivate') then begin
    Bot := JGetInt64(JGetObj(AResp.Obj, 'type'), 'user_id');
  end;
  Msgs := TdMsgList;
  if (Bot = 0) or (Msgs = nil) then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, 'No such bot');
    ReleaseDeferred(Slot);
    Exit;
  end;
  FInlineBots.Values[FDeferred[Slot].Held.Get('name', '')] := IntToStr(Bot);
  InlineAsk(Msgs, Bot, Slot);
end;

procedure TWebApi.InlineResultsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
  Items, Arr: TJSONArray;
  I: integer;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy) then begin
    Exit;
  end;
  if not AResp.Success then begin
    Fail(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, AResp.ErrorMessage);
    ReleaseDeferred(Slot);
    Exit;
  end;
  Items := TJSONArray.Create;
  Arr := JGetArr(AResp.Obj, 'results');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if Arr.Items[I] is TJSONObject then begin
        Items.Add(InlineResultJson(TJSONObject(Arr.Items[I])));
      end;
    end;
  end;
  Res := TJSONObject.Create;
  { inline_query_id — int64, у TDLib строкой; странице — тоже строкой. }
  Res.Add('queryId', string(JGetStr(AResp.Obj, 'inline_query_id')));
  if Res.Get('queryId', '') = '' then begin
    Res.Strings['queryId'] := IntToStr(JGetInt64(AResp.Obj, 'inline_query_id'));
  end;
  Res.Add('nextOffset', string(JGetStr(AResp.Obj, 'next_offset')));
  Res.Add('results', Items);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Выбранный результат — в открытый чат (sendInlineQueryResultMessage,
  уже готовый TTdMessages.SendInlineResult). }
function TWebApi.CmdInlineSend(AArgs: TJSONObject): TJSONData;
begin
  RequireMsgs.SendInlineResult(StrToInt64Def(utf8string(AArgs.Get('queryId', '')), 0),
    utf8string(AArgs.Get('resultId', '')), AArgs.Get('silent', False));
  Result := nil;
end;

function TWebApi.CmdMessageReact(AArgs: TJSONObject): TJSONData;
var
  Id, CustomId: Int64;
begin
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.react needs a message id');
  end;
  { One of the two kinds: a character, or the id of a custom emoji. }
  CustomId := StrToInt64Def(utf8string(AArgs.Get('customEmojiId', '')), 0);
  if CustomId <> 0 then begin
    RequireMsgs.ToggleCustomReaction(Id, CustomId, AArgs.Get('add', True));
  end else begin
    RequireMsgs.ToggleReaction(Id, utf8string(AArgs.Get('emoji', '')),
      AArgs.Get('add', True));
  end;
  Result := nil;
end;

function TWebApi.CmdMessageDelete(AArgs: TJSONObject): TJSONData;
var
  Id: Int64;
begin
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.delete needs a message id');
  end;
  RequireMsgs.DeleteMessage(Id, AArgs.Get('revoke', False));
  Result := nil;
end;

function TWebApi.CmdMessageEdit(AArgs: TJSONObject): TJSONData;
var
  Id: Int64;
  Text: utf8string;
begin
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  Text := utf8string(AArgs.Get('text', ''));
  if (Id = 0) or (Trim(Text) = '') then begin
    raise Exception.Create('message.edit needs a message id and text');
  end;
  RequireMsgs.EditFormattedText(Id, Text, AArgs.Get('html', False));
  Result := nil;
end;

function TWebApi.CmdMessagePin(AArgs: TJSONObject): TJSONData;
var
  Id: Int64;
begin
  Id := StrToInt64Def(utf8string(AArgs.Get('id', '')), 0);
  if Id = 0 then begin
    raise Exception.Create('message.pin needs a message id');
  end;
  RequireMsgs.PinMessage(Id, AArgs.Get('unpin', False));
  Result := nil;
end;

procedure TWebApi.RunCommand(AConnId: Int64; const AText: utf8string);
var
  D: TJSONData;
  Obj, Args: TJSONObject;
  Cmd: utf8string;
  ReqId: integer;
begin
  D := nil;
  try
    try
      { Through the same decoder the receive thread uses. The page's
        JSON.stringify emits raw UTF-8 rather than \uXXXX escapes, so
        this is belt-and-braces today — but message text now travels
        this way, and a single mangled surrogate pair here would land
        entities on the wrong letters exactly as it did on the way in
        (see tdrecv.PreDecodeUnicodeEscapes). }
      D := GetJSON(string(PreDecodeUnicodeEscapes(AText)));
    except
      on E: Exception do begin
        Fail(AConnId, 0, 'malformed json');
        Exit;
      end;
    end;
    if not (D is TJSONObject) then begin
      Fail(AConnId, 0, 'expected a json object');
      Exit;
    end;

    Obj := TJSONObject(D);
    ReqId := Obj.Get('id', 0);
    Cmd := utf8string(Obj.Get('cmd', ''));
    Args := TJSONObject(Obj.Find('args', jtObject));

    { Bound to whatever the active account has before anything runs:
      the first command can easily arrive before the fallback tick
      that would otherwise do it. }
    EnsureBindings;

    { The handlers are wrapped HERE, where the request id is known.
      Letting an exception travel up to the drain loop instead loses
      it, and the answer comes back tagged id 0 — which the page
      cannot match to anything, so its pending request never settles
      and simply hangs. Caught by the harness: chats.list without a
      TDLib client answered id 0 instead of id 2. }
    try
      { Signing in comes before everything else, and deliberately
        before EnsureBindings' models: these are the commands that
        work when there is no account at all. }
      if Copy(Cmd, 1, 5) = 'auth.' then begin
        if Cmd = 'auth.state' then begin
          Reply(AConnId, ReqId, CmdAuthState);
        end else begin
          Reply(AConnId, ReqId, CmdAuthSubmit(Cmd, Args));
        end;
      end else if Cmd = 'api.config' then begin
        Reply(AConnId, ReqId, CmdApiConfig);
      end else if Cmd = 'api.save' then begin
        Reply(AConnId, ReqId, CmdApiSave(Args));
      { Аккаунты — до моделей: отмена добавления и выход работают и
        тогда, когда активный аккаунт ещё не вошёл. }
      end else if Cmd = 'accounts.list' then begin
        Reply(AConnId, ReqId, CmdAccountsList);
      end else if Cmd = 'accounts.switch' then begin
        Reply(AConnId, ReqId, CmdAccountsSwitch(Args));
      end else if Cmd = 'accounts.add' then begin
        Reply(AConnId, ReqId, CmdAccountsAdd);
      end else if Cmd = 'accounts.cancel' then begin
        Reply(AConnId, ReqId, CmdAccountsCancel);
      end else if Cmd = 'accounts.logout' then begin
        Reply(AConnId, ReqId, CmdAccountsLogout);
      end else if Cmd = 'ping' then begin
        { Deliberately trivial, and deliberately kept: it is the one
          command that proves the whole path — socket thread, queue,
          main thread, back out — without involving the model. }
        Reply(AConnId, ReqId, TJSONString.Create('pong'));
      end else if Cmd = 'chats.list' then begin
        Reply(AConnId, ReqId, CmdChatsList(Args));
      end else if Cmd = 'chats.avatars' then begin
        Reply(AConnId, ReqId, CmdChatsAvatars(Args));
      end else if Cmd = 'chats.more' then begin
        Reply(AConnId, ReqId, CmdChatsMore(Args));
      end else if Cmd = 'chat.open' then begin
        ReplyMessages(AConnId, ReqId, CmdChatOpen(Args), False);
      end else if Cmd = 'chat.close' then begin
        Reply(AConnId, ReqId, CmdChatClose);
      end else if Cmd = 'chat.action' then begin
        Reply(AConnId, ReqId, CmdChatAction(Args));
      end else if Cmd = 'chats.folders' then begin
        Reply(AConnId, ReqId, CmdChatsFolders);
      end else if Cmd = 'chat.folder.set' then begin
        Reply(AConnId, ReqId, CmdChatFolderSet(Args));
      end else if Cmd = 'chat.folder.create' then begin
        Reply(AConnId, ReqId, CmdChatFolderCreate(Args));
      end else if Cmd = 'messages.list' then begin
        { The page asks for the difference on a refresh and for the
          whole thing when it has nothing to compare against. }
        ReplyMessages(AConnId, ReqId, CmdMessagesList,
          (Args <> nil) and Args.Get('delta', False));
      end else if Cmd = 'messages.older' then begin
        Reply(AConnId, ReqId, CmdMessagesOlder);
      end else if Cmd = 'thread.open' then begin
        ReplyMessages(AConnId, ReqId, CmdThreadOpen(Args), False);
      end else if Cmd = 'thread.jump' then begin
        ReplyMessages(AConnId, ReqId, CmdThreadJump(Args), False);
      end else if Cmd = 'thread.close' then begin
        ReplyMessages(AConnId, ReqId, CmdThreadClose, False);
      end else if Cmd = 'messages.trim' then begin
        ReplyMessages(AConnId, ReqId, CmdMessagesTrim, False);
      end else if Cmd = 'chat.join' then begin
        Reply(AConnId, ReqId, CmdChatJoin(Args));
      end else if Cmd = 'presence.get' then begin
        Reply(AConnId, ReqId, CmdPresenceGet);
      end else if Cmd = 'presence.set' then begin
        Reply(AConnId, ReqId, CmdPresenceSet(Args));
      end else if Cmd = 'settings.get' then begin
        Reply(AConnId, ReqId, CmdSettingsGet);
      end else if Cmd = 'settings.set' then begin
        Reply(AConnId, ReqId, CmdSettingsSet(Args));
      end else if Cmd = 'storage.get' then begin
        Reply(AConnId, ReqId, CmdStorageGet);
      end else if Cmd = 'storage.cleanup' then begin
        Reply(AConnId, ReqId, CmdStorageCleanup);
      end else if Cmd = 'messages.read' then begin
        Reply(AConnId, ReqId, CmdMessagesRead(Args));
      end else if Cmd = 'message.send' then begin
        Reply(AConnId, ReqId, CmdMessageSend(Args));
      end else if Cmd = 'message.sendFiles' then begin
        Reply(AConnId, ReqId, CmdMessageSendFiles(Args));
      end else if Cmd = 'message.cancelTransfer' then begin
        Reply(AConnId, ReqId, CmdCancelTransfer(Args));
      end else if Cmd = 'poll.vote' then begin
        Reply(AConnId, ReqId, CmdPollVote(Args));
      end else if Cmd = 'media.ensure' then begin
        Reply(AConnId, ReqId, CmdMediaEnsure(Args));
      end else if Cmd = 'search.set' then begin
        ReplyMessages(AConnId, ReqId, CmdSearchSet(Args), False);
      end else if Cmd = 'stickers.list' then begin
        Reply(AConnId, ReqId, CmdStickersList(Args));
      end else if Cmd = 'stickers.set' then begin
        Reply(AConnId, ReqId, CmdStickerSet(Args));
      end else if Cmd = 'gifs.list' then begin
        Reply(AConnId, ReqId, CmdGifsList(Args));
      end else if Cmd = 'gifs.ensure' then begin
        Reply(AConnId, ReqId, CmdGifEnsure(Args));
      end else if Cmd = 'emoji.sets' then begin
        Reply(AConnId, ReqId, CmdEmojiSets);
      end else if Cmd = 'emoji.set' then begin
        Reply(AConnId, ReqId, CmdEmojiSet(Args));
      end else if Cmd = 'message.sendMedia' then begin
        Reply(AConnId, ReqId, CmdMessageSendMedia(Args));
      end else if Cmd = 'message.menu' then begin
        { Answers later, from the TDLib callback - see TDeferredReply. }
        CmdMessageMenu(AConnId, ReqId, Args);
      end else if Cmd = 'message.translate' then begin
        CmdMessageTranslate(AConnId, ReqId, Args);
      end else if Cmd = 'message.forward' then begin
        CmdMessageForward(AConnId, ReqId, Args);
      end else if Cmd = 'message.link' then begin
        CmdMessageLink(AConnId, ReqId, Args);
      end else if Cmd = 'message.people' then begin
        { Answers later, from the TDLib callback - see TDeferredReply. }
        CmdMessagePeople(AConnId, ReqId, Args);
      end else if Cmd = 'link.resolve' then begin
        CmdLinkResolve(AConnId, ReqId, Args);
      end else if Cmd = 'link.join' then begin
        CmdLinkJoin(AConnId, ReqId, Args);
      end else if Cmd = 'bot.callback' then begin
        CmdBotCallback(AConnId, ReqId, Args);
      end else if Cmd = 'bot.info' then begin
        CmdBotInfo(AConnId, ReqId, Args);
      end else if Cmd = 'bot.loginUrl' then begin
        CmdBotLoginUrl(AConnId, ReqId, Args);
      end else if Cmd = 'bot.loginUrlConfirm' then begin
        CmdBotLoginUrlConfirm(AConnId, ReqId, Args);
      end else if Cmd = 'bot.buy' then begin
        CmdBotBuy(AConnId, ReqId, Args);
      end else if Cmd = 'bot.validateOrder' then begin
        CmdBotValidateOrder(AConnId, ReqId, Args);
      end else if Cmd = 'bot.tmpPassword' then begin
        CmdBotTmpPassword(AConnId, ReqId, Args);
      end else if Cmd = 'bot.pay' then begin
        CmdBotPay(AConnId, ReqId, Args);
      end else if Cmd = 'bot.sendLocation' then begin
        CmdBotSendLocation(AConnId, ReqId, Args);
      end else if Cmd = 'bot.sendPoll' then begin
        CmdBotSendPoll(AConnId, ReqId, Args);
      end else if Cmd = 'bot.createBot' then begin
        CmdBotCreateBot(AConnId, ReqId, Args);
      { Меню скрепки: опрос и геопозиция — те же команды, что у кнопок
        бота (в открытый чат), плюс список задач и статья. }
      end else if Cmd = 'message.sendPoll' then begin
        CmdBotSendPoll(AConnId, ReqId, Args);
      end else if Cmd = 'message.sendLocation' then begin
        CmdBotSendLocation(AConnId, ReqId, Args);
      end else if Cmd = 'message.sendChecklist' then begin
        CmdSendChecklist(AConnId, ReqId, Args);
      end else if Cmd = 'message.sendArticle' then begin
        CmdSendArticle(AConnId, ReqId, Args);
      end else if Cmd = 'map.thumb' then begin
        CmdMapThumb(AConnId, ReqId, Args);
      end else if Cmd = 'chat.info' then begin
        CmdChatInfo(AConnId, ReqId, Args);
      end else if Cmd = 'chat.members' then begin
        CmdChatMembers(AConnId, ReqId, Args);
      end else if Cmd = 'gifts.list' then begin
        CmdGiftsList(AConnId, ReqId, Args);
      end else if Cmd = 'media.list' then begin
        CmdMediaList(AConnId, ReqId, Args);
      end else if Cmd = 'info.action' then begin
        CmdInfoAction(AConnId, ReqId, Args);
      end else if Cmd = 'chat.greeting' then begin
        CmdChatGreeting(AConnId, ReqId, Args);
      end else if Cmd = 'greeting.send' then begin
        Reply(AConnId, ReqId, CmdGreetingSend(Args));
      end else if Cmd = 'mention.search' then begin
        CmdMentionSearch(AConnId, ReqId, Args);
      end else if Cmd = 'contacts.list' then begin
        CmdContactsList(AConnId, ReqId);
      end else if Cmd = 'message.transcribe' then begin
        { recognizeSpeech (chat_id, message_id) — открытого чата (в ветке
          это группа обсуждения, как у остальных команд сообщения).
          Ответ (ok); текст приходит обновлением сообщения. }
        if TdMsgList = nil then begin
          raise Exception.Create('no chat open');
        end;
        TdMsgList.Request('recognizeSpeech', '"chat_id":'
          + utf8string(IntToStr(TdMsgList.ChatId)) + ',"message_id":'
          + utf8string(IntToStr(ArgId(Args, 'id'))),
          @SimpleDone, TakeDeferred(AConnId, ReqId, 0));
      end else if Cmd = 'call.list' then begin
        Reply(AConnId, ReqId, CmdCallList);
      end else if Cmd = 'call.start' then begin
        CmdCallStart(AConnId, ReqId, Args);
      end else if (Cmd = 'call.accept') or (Cmd = 'call.discard')
                  or (Cmd = 'call.signal') then begin
        CmdCallSimple(Cmd, AConnId, ReqId, Args);
      end else if Cmd = 'vchat.info' then begin
        CmdVchatInfo(AConnId, ReqId, Args);
      end else if Cmd = 'vchat.join' then begin
        CmdVchatJoin(AConnId, ReqId, Args);
      end else if Cmd = 'vchat.participants' then begin
        Reply(AConnId, ReqId, CmdVchatParticipants(Args));
      end else if (Cmd = 'vchat.create') or (Cmd = 'vchat.leave') or (Cmd = 'vchat.end')
                  or (Cmd = 'vchat.mute') or (Cmd = 'vchat.video')
                  or (Cmd = 'vchat.load') then begin
        CmdVchatSimple(Cmd, AConnId, ReqId, Args);
      end else if Cmd = 'attach.bots' then begin
        Reply(AConnId, ReqId, CmdAttachBots);
      end else if Cmd = 'account.get' then begin
        CmdAccountGet(AConnId, ReqId);
      end else if Cmd = 'account.set' then begin
        CmdAccountSet(AConnId, ReqId, Args);
      end else if Cmd = 'account.checkUsername' then begin
        CmdAccountCheckUsername(AConnId, ReqId, Args);
      end else if Cmd = 'account.personalChats' then begin
        CmdAccountPersonalChats(AConnId, ReqId);
      end else if Cmd = 'account.photos' then begin
        CmdAccountPhotos(AConnId, ReqId, Args);
      end else if Cmd = 'bot.userChat' then begin
        CmdBotUserChat(AConnId, ReqId, Args);
      end else if Cmd = 'webapp.open' then begin
        CmdWebAppOpen(AConnId, ReqId, Args);
      end else if Cmd = 'webapp.close' then begin
        CmdWebAppClose(AConnId, ReqId, Args);
      end else if Cmd = 'webapp.custom' then begin
        CmdWebAppCustom(AConnId, ReqId, Args);
      end else if Cmd = 'webapp.allowWrite' then begin
        CmdWebAppAllowWrite(AConnId, ReqId, Args);
      end else if Cmd = 'webapp.sendData' then begin
        CmdWebAppSendData(AConnId, ReqId, Args);
      end else if Cmd = 'bot.shareUsers' then begin
        CmdBotShareUsers(AConnId, ReqId, Args);
      end else if Cmd = 'bot.shareChat' then begin
        CmdBotShareChat(AConnId, ReqId, Args);
      end else if Cmd = 'bot.sharePhone' then begin
        CmdBotSharePhone(AConnId, ReqId, Args);
      end else if Cmd = 'inline.query' then begin
        CmdInlineQuery(AConnId, ReqId, Args);
      end else if Cmd = 'inline.send' then begin
        Reply(AConnId, ReqId, CmdInlineSend(Args));
      end else if Cmd = 'message.react' then begin
        Reply(AConnId, ReqId, CmdMessageReact(Args));
      end else if Cmd = 'message.delete' then begin
        Reply(AConnId, ReqId, CmdMessageDelete(Args));
      end else if Cmd = 'message.edit' then begin
        Reply(AConnId, ReqId, CmdMessageEdit(Args));
      end else if Cmd = 'message.pin' then begin
        Reply(AConnId, ReqId, CmdMessagePin(Args));
      end else begin
        Fail(AConnId, ReqId, 'unknown command: ' + Cmd);
      end;
    except
      on E: Exception do begin
        Fail(AConnId, ReqId, utf8string(E.Message));
      end;
    end;
  finally
    D.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ module entry points                                                }
{ ------------------------------------------------------------------ }

{ Runs on a SOCKET thread. Queue and return, nothing else. }
procedure SocketMessage(AConnId: Int64; const AText: utf8string);
begin
  if GApi <> nil then begin
    GApi.Enqueue(AConnId, AText);
  end;
end;

procedure WebApiStart;
begin
  if GApi <> nil then begin
    Exit;
  end;
  GApi := TWebApi.Create;
  SetWebMessageHandler(@SocketMessage);
end;

procedure WebApiStop;
begin
  if GApi = nil then begin
    Exit;
  end;
  { Unhook FIRST: after this no socket thread can reach the queue, so
    the object is free to go. }
  SetWebMessageHandler(nil);
  FreeAndNil(GApi);
  WebFilesClear;
end;

end.
