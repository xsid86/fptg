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
  autodownload, customemoji, tdstorage, tdsupergroups, tdattachbots, servicetext, tdaccount,
  appdirs, turnrelay;

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

  { The getChatSponsoredMessages answer for one chat, already with the
    paths of the downloaded files, and when it arrived (see "sponsored
    messages"). }
  TAdsEntry = class
  public
    Fetched: QWord;
    Raw: TJSONObject;
    destructor Destroy; override;
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

  { The bridge's listener on the account registry: the active account
    changing and the list changing (a name arrived, sign-in, sign-out).
    A separate object because the subscription goes through an interface
    with a GUID, while TWebApi is a plain class. }
  TWebActiveHook = class(TComponent, ITdActiveListener)
  public
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

  TWebApi = class
  private
    FTimer: TTdTimer;
    FActiveHook: TWebActiveHook;
    { Where to go back to when adding an account is cancelled
      (accounts.cancel); -1 — not remembered. }
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
    { The account's status in groups and channels — for the join button
      (messages.list -> join). One handler, as with stickers: nobody else
      listens to the supergroups' OnChanged. }
    FBoundGroups: TTdSupergroups;
    { The user model: a downloaded photo and a sender name that arrived
      reach the page by re-reading the messages (coalesced by the timer,
      like supergroups). Its only OnChanged used to be held by the native
      history window. }
    FBoundUsers: TTdUsers;
    { Calls of the active account: every change and every signalling
      packet becomes an event for the page (call, call.signal). }
    FBoundCalls: TTdCalls;
    FUsersDirty: boolean;
    { updateSupergroup arrives in a batch at start — coalesced into a page
      event by the timer, like stickers. }
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
    { Inline bot name (lower case) -> its id, see CmdInlineQuery. }
    FInlineBots: TStringList;
    { Sponsored messages per chat: chat id as text -> TAdsEntry (owned). }
    FAds: TStringList;
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
    function  CmdBotTmpPasswordState(AConnId: Int64; AReqId: integer): boolean;
    procedure TmpPasswordStateDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdMentionSearch(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure MentionMembersDone(Sender: TObject; const AResp: TTdResponse);
    procedure MentionContactsDone(Sender: TObject; const AResp: TTdResponse);
    procedure MentionReply(ASlot: PtrInt; const AIds: array of Int64);
    function  CmdSearchHome(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSearchQuery(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSearchRecent(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure SearchNext(ASlot: PtrInt);
    procedure SearchStepDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdAdmin(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdTdKept(AArgs: TJSONObject): TJSONData;
    procedure AdminNext(ASlot: PtrInt);
    procedure AdminStepDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdUsersCards(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure InfoSimilarDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdChatSimilar(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdChatSimilarOpened(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSearchMessages(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdSearchPostLimits(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure PostLimitsDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdSearchPosts(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure PostsDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdAccountsList: TJSONData;
    function  CmdAccountsSwitch(AArgs: TJSONObject): TJSONData;
    function  CmdAccountsAdd: TJSONData;
    function  CmdAccountsCancel: TJSONData;
    function  CmdAccountsLogout: TJSONData;
    procedure ChatsChanged(Sender: TObject);
    procedure ChatAction(Sender: TObject; AChatId, AThreadId: Int64;
      ASender: TJSONObject; const AAction: utf8string);
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
    function  CmdFileEnsure(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure FileEnsureDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdRichFull(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure RichFullDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdStoryList(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure StoryListDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdStoryOpen(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure StoryGetDone(Sender: TObject; const AResp: TTdResponse);
    procedure StoryFileDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdVchatStreams(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure VchatStreamsDone(Sender: TObject; const AResp: TTdResponse);
    function  CmdVchatSegment(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure VchatSegmentDone(Sender: TObject; const AResp: TTdResponse);
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
    function  DateJumpSlot(ASlot: PtrInt; out AChat, ADay: Int64): boolean;
    procedure DateJumpLastOfDay(ASlot: PtrInt);
    procedure DateJumpReply(ASlot: PtrInt; AMessageId: Int64);
    procedure DateJumpBeforeDone(Sender: TObject; const AResp: TTdResponse);
    procedure DateJumpAfterDone(Sender: TObject; const AResp: TTdResponse);
    procedure DateJumpLastDone(Sender: TObject; const AResp: TTdResponse);
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
    function  CmdChatsRows(AArgs: TJSONObject): TJSONData;
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
    function  CmdChatTyping(AArgs: TJSONObject): TJSONData;
    function  CmdSettingsGet: TJSONData;
    function  CmdSettingsSet(AArgs: TJSONObject): TJSONData;
    function  CmdStorageGet: TJSONData;
    function  CmdStorageCleanup: TJSONData;
    function  CmdMessageSend(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSendFiles(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSendRich(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSendNote(AArgs: TJSONObject): TJSONData;
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
    function  CmdChatDateJump(AConnId: Int64; AReqId: integer;
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
    function  CmdAdsGet(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure AdsListDone(Sender: TObject; const AResp: TTdResponse);
    procedure AdsFileDone(Sender: TObject; const AResp: TTdResponse);
    procedure AdsNext(ASlot: PtrInt);
    function  CmdAdsView(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdAdsClick(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    function  CmdAdsReport(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
    procedure AdsReportDone(Sender: TObject; const AResp: TTdResponse);
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
{ An id from command arguments — a number or a string. The page sends
  large ids as strings (JSON numbers lose precision past 2^53), and
  TJSONObject.Get with a numeric default does NOT take a string —
  Find(AName, jtNumber) in fpjson.pp — and silently returns the default:
  user_id 0 went out and "User not found" came back (the avatar gallery
  from the info panel). }
{ A command crash rather than its refusal (a refusal is an ordinary
  Exception with a text for a human): access violation, out of range and
  so on. Written to SERVER_ERROR_LOG — command, arguments, class, text and
  stack addresses (no names or lines in them: the build has no debug
  info, but the command and arguments let the crash be repeated). }
procedure LogCommandCrash(const ACmd: utf8string; AArgs: TJSONObject; E: Exception);
var
  Path, Line, ArgsText: string;
  F: TextFile;
  I: integer;
  Frames: PCodePointer;
  SR: TSearchRec;
begin
  try
    Path := IncludeTrailingPathDelimiter(ServerDataDir) + SERVER_ERROR_LOG;
    if FindFirst(Path, faAnyFile, SR) = 0 then begin
      try
        if SR.Size > SERVER_ERROR_LOG_MAX then begin
          DeleteFile(Path);
        end;
      finally
        FindClose(SR);
      end;
    end;
    ArgsText := '';
    if AArgs <> nil then begin
      ArgsText := Copy(AArgs.AsJSON, 1, SERVER_ERROR_LOG_ARGS);
    end;
    AssignFile(F, Path);
    if FileExists(Path) then begin
      Append(F);
    end else begin
      Rewrite(F);
    end;
    try
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + string(ACmd) + ' ' +
        E.ClassName + ': ' + E.Message;
      WriteLn(F, Line);
      WriteLn(F, '  args: ', ArgsText);
      WriteLn(F, '  at ', BackTraceStrFunc(ExceptAddr));
      Frames := ExceptFrames;
      for I := 0 to ExceptFrameCount - 1 do begin
        WriteLn(F, '     ', BackTraceStrFunc(Frames[I]));
      end;
    finally
      CloseFile(F);
    end;
  except
    { The log must not break the answer to the command. }
  end;
end;

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

{ true/false for the body of a TDLib request. }
function BoolJson(AValue: boolean): utf8string;
begin
  if AValue then begin
    Result := 'true';
  end else begin
    Result := 'false';
  end;
end;

{ The game short name of a message: messageGame.game.short_name
  (td_api.tl) — from the row's raw content; '' if it is not a game or
  there is no row. }
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

{ Ids of custom emoji on markup buttons (icon_custom_emoji_id of
  keyboardButton / inlineKeyboardButton; 0 — none). }
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

{ Emoji of markup buttons — into the answer's dictionary and, if not known
  yet, into a getCustomEmojiStickers request (like the emoji of text). }
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
    (fptg-client.lpr), so both types carry the same code page and no transcoding
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
  { Video chat or live stream: the call id (0 — none) and whether it has
    participants — the badge on the avatar and the bar above the history. }
  Result.Add('videoChat', ARow.VideoChatId);
  Result.Add('videoChatLive', ARow.VideoChatLive);
  { Stories: total and read — the segments of the ring around the avatar. }
  Result.Add('stories', ARow.StoryCount);
  Result.Add('storiesRead', ARow.StoryReadCount);
  Result.Add('premium',  AChats.IsPremiumUser(ARow));
  Result.Add('deleted',  AChats.IsDeletedUser(ARow));
  { Whether this account may write here at all — a channel it only
    reads says no, and the native window hides its composer for exactly
    this. }
  Result.Add('canSend',  ARow.CanSendBasicMessages);
  Result.Add('scheduled', ARow.HasScheduled);
  { The avatar, if it is already on disk. NOT requested here: chats.list
    serialises the WHOLE list, and asking for a hundred downloads
    because someone opened the app is precisely what the native window
    avoids by only calling EnsureAvatar for rows that are on screen.
    The page asks for the ones it can see, through chats.avatars.
    The minithumbnail rides along free — it arrives inside the chat
    object itself, with no download at all. }
  Result.Add('avatar',   string(FileUrl(ARow.PhotoFileId, ARow.PhotoPath)));
  Result.Add('avatarThumb', string(ThumbDataUri(ARow.Minithumb)));
  { Animated avatar (MPEG4), once downloaded; asked for together with the
    ordinary one — chats.avatars and the header of the open chat. }
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
    mekSpoiler:       Result := 'spoiler';
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

{ Avatar of a message's sender (the circle in its header): the photo
  address if it is on disk already, otherwise a blurred minithumbnail and
  a download — of a person through the user model (the bridge listens to
  its OnChanged and re-reads the messages), of a channel/group through
  the chat row. }
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
      { As a string, like album and emoji ids: the page passes it on as
        is (ui:open-contact). }
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
{ Transcription of a voice message — voice_note.speech_recognition_result
  (td_api.tl at commit d1085f9): speechRecognitionResultPending
  (partial_text), ...Text (text), ...Error (error). Started by
  recognizeSpeech (message.transcribe), the result arrives as an update of
  the message content. null — never transcribed. }
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
      { A round video (messageVideoNote) — ui/message.js. }
      Result.Add('round', ARow.VideoRound);
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
  { Progress of the main file's transfer — only while it runs: the page
    draws a ring around the icon from it and "how much of how much". up —
    an upload (outgoing), otherwise a download. }
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

{ Rows of keyboard buttons — both inline (under a message) and ordinary
  (above the input field), in one shape for the page: text, kind and what
  that kind needs. Kinds — per td_api.tl (TDLib 1.8.67):
    url / loginUrl -> url (open the link)
    webApp         -> webapp, url (Mini App — second stage)
    callback       -> callback, data (base64, as TDLib gives it)
    user           -> user, userId
    copyText       -> copy, copy
    keyboardButtonTypeText -> text (send the button's text)
  The rest (payment, games, phone requests and so on) — unsupported: the
  page draws the button but says this is not there yet. }
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

{ One button (inlineKeyboardButton, keyboardButton or a rich message's
  inlineButton) -> JSON for the page: text, style, emoji, kind and the
  fields of its kind. AText — the caption: for inlineButton it is
  RichText, and the caller collects its plain text. }
function ButtonToJson(Btn: TJSONObject; const AText: utf8string): TJSONObject;
var
  BType, O, Sub: TJSONObject;
  T: utf8string;
begin
  BType := JGetObj(Btn, 'type');
  T := JGetStr(BType, '@type');
  O := TJSONObject.Create;
  O.Add('text', string(AText));
  { Button colour: style — buttonStylePrimary/Danger/Success/Link
    (td_api.tl at commit d1085f9, on both keyboardButton and
    inlineKeyboardButton); live log: Default 89, Danger 1. To the page —
    the tail of the type name, '' for Default. }
  O.Add('style', string(ButtonStyleStr(JGetStr(JGetObj(Btn, 'style'), '@type'))));
  { A custom emoji before the text: id as a string, '' — none. }
  if JGetInt64(Btn, 'icon_custom_emoji_id') <> 0 then begin
    O.Add('emoji', string(IntToStr(JGetInt64(Btn, 'icon_custom_emoji_id'))));
  end else begin
    O.Add('emoji', '');
  end;
  if T = 'inlineKeyboardButtonTypeUrl' then begin
    O.Add('kind', 'url');
    O.Add('url', string(JGetStr(BType, 'url')));
  end else if T = 'inlineKeyboardButtonTypeLoginUrl' then begin
    { Signing in to a site through Telegram: getLoginUrlInfo by button id. }
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
    { "@bot query" — into this chat (targetChatCurrent) or a chosen one
      (targetChatChosen, with the allowed kinds of chats). A link
      (targetChatInternalLink) — not yet. }
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
    { Who can be chosen: max_quantity (0 — one), and the restriction on
      bots: restrict_user_is_bot + user_is_bot. The page cannot check the
      Premium restriction — Telegram checks it and refuses. }
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
  Result := O;
end;

{ ---------------- rich messages (messageRichMessage) ----------------

  The page draws the blocks itself (ui/richmessage.js) from TDLib's
  structure — pageBlock*, richText* (td_api.tl). The server hands it over
  almost as is, with two replacements in a copy:
  - a file (@type file) -> id, size, url: only the server can give an
    address (FileUrl); not downloaded yet — url '' and the page calls
    file.ensure by id;
  - a button (@type inlineButton) -> the same JSON as keyboard buttons
    (ButtonToJson) with @type inlineButton: a press goes through the same
    handler (callback, link, mini app). }

{ RichText -> plain text (a button caption). }
function RichPlainText(ANode: TJSONData): utf8string;
var
  O: TJSONObject;
  T: utf8string;
  Arr: TJSONArray;
  I: integer;
begin
  Result := '';
  if not (ANode is TJSONObject) then begin
    Exit;
  end;
  O := TJSONObject(ANode);
  T := JGetStr(O, '@type');
  if T = 'richTextPlain' then begin
    Result := JGetStr(O, 'text');
  end else if T = 'richTextCustomEmoji' then begin
    Result := JGetStr(O, 'alternative_text');
  end else if T = 'richTextMathematicalExpression' then begin
    Result := JGetStr(O, 'expression');
  end else if T = 'richTexts' then begin
    Arr := JGetArr(O, 'texts');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        Result := Result + RichPlainText(Arr.Items[I]);
      end;
    end;
  end else if O.Find('text') <> nil then begin
    Result := RichPlainText(O.Find('text'));
  end;
end;

{ A copy of the node with the replacements (see above). }
function RichFix(D: TJSONData): TJSONData;
var
  O, Src, Local: TJSONObject;
  Arr: TJSONArray;
  I: integer;
  T: utf8string;
begin
  if D is TJSONArray then begin
    Arr := TJSONArray.Create;
    for I := 0 to TJSONArray(D).Count - 1 do begin
      Arr.Add(RichFix(TJSONArray(D).Items[I]));
    end;
    Exit(Arr);
  end;
  if not (D is TJSONObject) then begin
    Exit(D.Clone);
  end;
  Src := TJSONObject(D);
  T := JGetStr(Src, '@type');
  if T = 'file' then begin
    O := TJSONObject.Create;
    O.Add('@type', 'file');
    O.Add('id', JGetInt(Src, 'id'));
    O.Add('size', JGetInt64(Src, 'size'));
    Local := JGetObj(Src, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      O.Add('url', string(FileUrl(JGetInt(Src, 'id'), JGetStr(Local, 'path'))));
    end else begin
      O.Add('url', '');
    end;
    Exit(O);
  end;
  if T = 'inlineButton' then begin
    O := ButtonToJson(Src, RichPlainText(Src.Find('text')));
    O.Add('@type', 'inlineButton');
    Exit(O);
  end;
  O := TJSONObject.Create;
  for I := 0 to Src.Count - 1 do begin
    O.Add(Src.Names[I], RichFix(Src.Items[I]));
  end;
  Result := O;
end;

{ Rich message blocks from the page -> a copy for TDLib: a file uploaded
  through POST /upload is marked by the page with an inputFileUpload
  object with an id field (it does not know the path on disk) — here it
  becomes inputFileLocal. An unknown id fails the whole send, as in
  message.sendFiles. The temporary copies are cleaned up by the server's
  start (uploads/). }
function RichInputFix(D: TJSONData): TJSONData;
var
  O, Src: TJSONObject;
  Arr: TJSONArray;
  I: integer;
  Path: string;
begin
  if D is TJSONArray then begin
    Arr := TJSONArray.Create;
    try
      for I := 0 to TJSONArray(D).Count - 1 do begin
        Arr.Add(RichInputFix(TJSONArray(D).Items[I]));
      end;
    except
      Arr.Free;
      raise;
    end;
    Exit(Arr);
  end;
  if not (D is TJSONObject) then begin
    Exit(D.Clone);
  end;
  Src := TJSONObject(D);
  if JGetStr(Src, '@type') = 'inputFileUpload' then begin
    Path := UploadFilePath(Src.Get('id', ''));
    if Path = '' then begin
      raise Exception.Create('uploaded file not found');
    end;
    O := TJSONObject.Create;
    O.Add('@type', 'inputFileLocal');
    O.Add('path', Path);
    Exit(O);
  end;
  O := TJSONObject.Create;
  try
    for I := 0 to Src.Count - 1 do begin
      O.Add(Src.Names[I], RichInputFix(Src.Items[I]));
    end;
  except
    O.Free;
    raise;
  end;
  Result := O;
end;

{ Raw content -> richMessage for the page, or nil — not a rich one. }
function RichMessageJson(const ARaw: utf8string): TJSONObject;
var
  Data: TJSONData;
  Msg: TJSONObject;
begin
  Result := nil;
  if (ARaw = '') or (Pos('"messageRichMessage"', string(ARaw)) = 0) then begin
    Exit;
  end;
  try
    Data := GetJSON(string(ARaw));
  except
    Exit;
  end;
  try
    if (Data is TJSONObject) and (JGetStr(TJSONObject(Data), '@type') = 'messageRichMessage') then begin
      Msg := JGetObj(TJSONObject(Data), 'message');
      if Msg <> nil then begin
        Result := TJSONObject(RichFix(Msg));
      end;
    end;
  finally
    Data.Free;
  end;
end;

function KeyboardRowsJson(ARows: TJSONArray): TJSONArray;
var
  I, J: integer;
  Row: TJSONArray;
  Btn, O: TJSONObject;
  OutRow: TJSONArray;
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
      O := ButtonToJson(Btn, JGetStr(Btn, 'text'));
      OutRow.Add(O);
    end;
    Result.Add(OutRow);
  end;
end;

{ The keyboard above the input field from the raw reply_markup, or nil if
  it is not replyMarkupShowKeyboard. }
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
    { replyMarkupForceReply: no buttons, but the input field must reply
      to this message, with its own placeholder (td_api.tl). }
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

{ A message's inline buttons from the raw reply_markup, or nil. }
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

{ User name for service lines ("X added Y"): the user model; '' — unknown. }
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

{ Text of the row's service message (servicetext) or ''. AActor — the
  sender's name; channel or not — by the kind of the open chat. }
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

{ Contact card — messageContact (td_api.tl at commit d1085f9: contact —
  phone_number, first_name, last_name, vcard, user_id). The model keeps it
  as mckOther; avatar and colour come from the user model if the person
  is on Telegram (user_id <> 0), the photo is downloaded there too. nil —
  not a contact. }
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

{ A call in the history — messageCall (is_video, discard_reason, duration)
  and messageGroupCall (is_active, was_missed, is_video, duration) per
  td_api.tl at commit d1085f9. The model keeps them as mckOther; without
  this the page drew an empty bubble. reason — the tail of the
  callDiscardReason* type in lower case (missed, declined,
  disconnected, hungup, empty...). nil — not a call. }
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

{ A message's location — from the raw content (td_api.tl at commit
  d1085f9): messageLocation (location), messageVenue (venue: location,
  title, address), messageLiveLocation (location: liveLocation — its
  location, live_period; expires_in). The model keeps such messages as
  mckOther; nil — not a location. }
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
    { horizontal_accuracy — the uncertainty radius in metres; 0 — unknown. }
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
  { Ephemeral content (visible to this user only) — for the page's
    "Only you can see this message" caption. }
  Result.Add('ephemeral', ARow.HasEphemeral);
  { A rich message (an article of blocks, with buttons) — ui/richmessage.js. }
  if ARow.Kind = mckOther then begin
    Loc := RichMessageJson(ARow.ContentRaw);
    if Loc <> nil then begin
      Result.Strings['kind'] := 'rich';
      Result.Add('rich', Loc);
    end;
  end;
  if (ARow.Kind = mckOther) and (Result.Get('kind', '') <> 'rich') then begin
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
  { A service message (group created, joined, pinned…): the page draws it
    as a line in the middle rather than a bubble, and its menu offers
    deletion only. Text — servicetext, with the sender's name. }
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
  { In a comment thread a reply to the post itself is not shown as a
    quote: the whole thread is under it anyway (the post is on top), and
    the quote came out as an empty "…". TDLib names the post in two ways —
    as the channel's message (ThreadChatId/ThreadPostId) or as the root
    copy in the discussion group, whose id equals message_thread_id.
    Replies to other commenters stay. }
  if (ARow.ReplyMessageId <> 0) and (AMsgs.ThreadId <> 0)
     and (((ARow.ReplyChatId = AMsgs.ThreadChatId)
           and (ARow.ReplyMessageId = AMsgs.ThreadPostId))
          or (ARow.ReplyMessageId = AMsgs.ThreadId)) then begin
    { no quote }
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
  { The bot's buttons under a message (replyMarkupInlineKeyboard). }
  Kb := InlineKeyboardJson(ARow.ReplyMarkupRaw);
  if Kb <> nil then begin
    Result.Add('keyboard', Kb);
    { For switchInline buttons: "@name query". }
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
  FAds := TStringList.Create;
  FAds.OwnsObjects := True;
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
  FAds.Free;
  inherited Destroy;
end;

destructor TAdsEntry.Destroy;
begin
  Raw.Free;
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
      Chats.OnChatAction := @ChatAction;
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

{ Whether the model belongs to any live account. Models of the account
  that was switched away from are alive and keep sending their changes;
  models of a removed one are already freed and must not be touched. }
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

{ Unsubscribing from the models of an account that stopped being active.
  Without it, its chat and message lists kept poking the bridge after the
  switch: EnsureBindings subscribes to the new ones but cannot let go of
  the old ones — it does not know whether they are alive. }
procedure TWebApi.UnbindStale;
begin
  { The previous account's open chat is closed: nobody sees it any more,
    and for TDLib the open chat is the one on screen. }
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

{ The active account changed. The models are different, the snapshots of
  what each page saw belong to another account: all of it is reset, and
  the pages reload on the account event (so their state can never mix two
  accounts). }
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
  { Sponsored messages — keyed by the previous account's chat ids. }
  FAds.Clear;
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

{ Account avatar as a data URI from the file (see ACCOUNT_AVATAR_MAX_BYTES);
  no file or too large — the minithumbnail; none either — ''. }
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

{ accounts.list — the account switcher in the status bar: every account in
  the registry (name from getMe, phone, username, avatar, signed in or
  not, unread chats of the main list) and the number of the active one. }
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
    { As a string: a user id can be beyond JS's exact integers. Before
      getMe — empty. }
    if A.UserId <> 0 then begin
      O.Add('userId', IntToStr(A.UserId));
    end else begin
      O.Add('userId', '');
    end;
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

{ A new account: into the registry, its TDLib client starts, the account
  becomes active — the page reloads and shows sign-in. The previously
  active one is remembered for accounts.cancel. }
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

{ Cancelling sign-in to an account not signed in yet, when there are
  others: back to the remembered one (or any other), and this one closes
  without logging out of the session and leaves the registry
  (DiscardAccount). }
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

{ Signing out of the active account. As in Telegram: with other accounts
  present it leaves the list, the last one stays and goes back to sign-in
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
{ calls (tdcalls.pas; page — ui/call.js, calls/*.js)                  }
{ ------------------------------------------------------------------ }

{ A call for the page. state — the tail of the callState* type with a
  lower-case first letter (pending, exchangingKeys, ready, hangingUp,
  discarded, error). For ready — everything WebRTC needs: the key
  (base64, 256 bytes), protocol version, servers, emoji to compare the
  key, allowP2p. The peer's name and avatar — so the call window does not
  have to ask for them separately. }
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
    { Servers: the WebRTC kind (STUN/TURN) suits the browser as is;
      Telegram's reflectors speak their own protocol, the page skips them,
      but they are passed on so it is visible what arrived. }
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

{ call.list: calls in progress — for a page opened or reloaded in the
  middle of a call (an incoming one still ringing). }
{ relay.get: credentials of the server's call relay (turnrelay.pas) —
  (enabled, username, credential, ttl). The page builds the TURN address
  from the server address it is connected to: the server cannot know
  which name or port forwarding the client reaches it by. }
function RelayJson: TJSONData;
var
  User, Pass: string;
  Ttl: integer;
  Res: TJSONObject;
begin
  Res := TJSONObject.Create;
  if RelayCredentials(User, Pass, Ttl) then begin
    Res.Add('enabled', True);
    Res.Add('username', User);
    Res.Add('credential', Pass);
    Res.Add('ttl', Ttl);
  end else begin
    Res.Add('enabled', False);
  end;
  Result := Res;
end;

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

{ call.start (userId, video): createCall -> (id). From then on the call
  lives in call events. }
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
  disconnected), call.signal (id, data in base64) — the answer is (ok). }
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
  Member: boolean;
begin
  if ARow = nil then begin
    Exit;
  end;
  { Only chats the person is a member of. TDLib sends new messages of
    channels they have not joined too — while such a chat is open (here,
    in search, or in another client of the same account) — and their
    notifications are "not muted" by default. Channel and supergroup —
    by one's own status (supergroup.status); until it is known — by the
    place in the chat lists: neither in the main list nor in the archive
    — not ours. }
  if ARow.SupergroupId <> 0 then begin
    if (TdSupergroupList <> nil)
       and TdSupergroupList.Membership(ARow.SupergroupId, Member) then begin
      if not Member then begin
        Exit;
      end;
    end else if not (ARow.InList or ARow.InArchive) then begin
      Exit;
    end;
  end;
  Data := TJSONObject.Create;
  { A number, the same shape chats.list sends an id in - the page
    compares it against the open chat. }
  Data.Add('chatId', ARow.Id);
  Data.Add('title', string(ARow.Title));
  Data.Add('text', string(APreview));
  Data.Add('color', string(AccentKey(ARow)));
  Data.Add('avatar', string(FileUrl(ARow.PhotoFileId, ARow.PhotoPath)));
  { Until the photo is downloaded — a blurred thumbnail, as on the call card. }
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
  { Somebody's status in a group changed — the page re-reads the message
    list, and join with it (joined — the button goes away). }
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

{ chats.rows (ids) — rows of chats already known, as in the list, without
  requests to TDLib: search (ui/search.js) picks up this way the avatars
  downloaded after it drew its rows. }
function TWebApi.CmdChatsRows(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  Arr, Out: TJSONArray;
  CRow: TChatRow;
  I: integer;
begin
  Chats := RequireChats;
  Out := TJSONArray.Create;
  Result := TJSONObject.Create;
  TJSONObject(Result).Add('items', Out);
  if AArgs = nil then begin
    Exit;
  end;
  Arr := TJSONArray(AArgs.Find('ids', jtArray));
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtNumber then begin
      Continue;
    end;
    CRow := Chats.Lookup(Arr.Items[I].AsInt64);
    if CRow <> nil then begin
      Out.Add(RowToJson(Chats, CRow));
    end;
  end;
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
  { Voice transcription — Premium only (recognizeSpeech answers with an
    error without it): without Premium the page does not show the button. }
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
      { The bot keyboard above the input field: the chat's own markup, and
        failing that — the one of the loaded message the chat points to. }
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
  { A channel or group the account is not a member of (reached through a
    forward or a link) — the page puts a join button in place of the input
    field. A comment thread has its own rule — thread.mustJoin. }
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
  Res.Add('savedTopic',   Msgs.SavedTopic);
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

{ thread.jump (messageId) — to a message inside the open thread (a quote
  in a comment). chat.open with jumpTo does not fit here: it would open the
  discussion group as an ordinary chat and leave the thread. }
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

{ chat.typing (action) — one's own action in the open chat
  (ui/sendaction.js): typing, cancel, photo, video, document. The model
  knows the chat and the thread — the message goes there too. Telegram API
  terms §1.3: a client must send the typing indicator, not suppress it. }
function TWebApi.CmdChatTyping(AArgs: TJSONObject): TJSONData;
var
  Action: utf8string;
begin
  Action := '';
  if AArgs <> nil then begin
    Action := utf8string(AArgs.Get('action', ''));
  end;
  if Action = 'typing' then begin
    RequireMsgs.SendChatAction('chatActionTyping', False);
  end else if Action = 'cancel' then begin
    RequireMsgs.SendChatAction('chatActionCancel', False);
  end else if Action = 'photo' then begin
    RequireMsgs.SendChatAction('chatActionUploadingPhoto', True);
  end else if Action = 'video' then begin
    RequireMsgs.SendChatAction('chatActionUploadingVideo', True);
  end else if Action = 'document' then begin
    RequireMsgs.SendChatAction('chatActionUploadingDocument', True);
  end else if Action = 'recordVoice' then begin
    RequireMsgs.SendChatAction('chatActionRecordingVoiceNote', False);
  end else if Action = 'recordVideo' then begin
    RequireMsgs.SendChatAction('chatActionRecordingVideoNote', False);
  end else begin
    raise Exception.Create('unknown chat.typing action: ' + Action);
  end;
  Result := nil;
end;

{ ------------------------------------------------------------------ }
{ settings                                                           }
{ ------------------------------------------------------------------ }

{ Everything the settings page shows, in one answer. The limits travel
  with the values: they live in constants.pas, and the page must not keep
  a second copy of them.

  The auto-download grid — as a list of enabled "media.chat" cells, and
  the kinds of media and chats — with labels from the same constants as
  the native dialog: a kind added there shows up on the page by itself. }
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
  { Where a location point opens; '' — ask every time. }
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

{ One setting per call: key and value, plus media and chat for
  auto-download. The answer is all the settings, already clamped, so a
  field where 500 was typed against a limit of 20 shows 20. The other
  open pages get the same as an event. }
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
    { An empty device name is of no use to TDLib — like the native field,
      it is not saved. Applies to the next session, see SetDeviceModel. }
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

{ State of the TDLib cache. The numbers are the last known answer; fresh
  ones are requested in CmdStorageGet and arrive as a 'storage' event when
  TDLib answers. }
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

{ The subscription to TdCache.OnChanged is set again on every question:
  the event has one listener, and the native Storage section, when opened,
  takes it over and clears it on close. The page asks on every visit to
  the section — enough for the subscription to be in place when needed. }
function TWebApi.CmdStorageGet: TJSONData;
begin
  TdCache.OnChanged := @StorageChanged;
  TdCache.RefreshStats;
  Result := StorageJson;
end;

{ The same limits as applied at start — from the file, not from the page's
  fields: every field has already saved itself on change. }
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

{ text + entities (TDLib textEntity, offsets in UTF-16 — as JS counts
  them) -> formattedText. The page builds the entities itself
  (ui/editor.js); here only the node type is set: TDLib rejects foreign
  fields anyway. }
function FormattedFromArgs(AArgs: TJSONObject): utf8string;
var
  F: TJSONObject;
  Src, Arr: TJSONArray;
  Item: TJSONData;
  I: integer;
begin
  Src := TJSONArray(AArgs.Find('entities', jtArray));
  F := TJSONObject.Create;
  try
    F.Add('@type', 'formattedText');
    F.Add('text', AArgs.Get('text', ''));
    Arr := TJSONArray.Create;
    F.Add('entities', Arr);
    for I := 0 to Src.Count - 1 do begin
      Item := Src.Items[I];
      if (Item is TJSONObject) and (JGetStr(TJSONObject(Item), '@type') = 'textEntity') then begin
        Arr.Add(Item.Clone);
      end;
    end;
    Result := utf8string(F.AsJSON);
  finally
    F.Free;
  end;
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
  { Entities from the input field (ui/editor.js) — nothing to parse. }
  if AArgs.Find('entities', jtArray) <> nil then begin
    Msgs.SendFormattedJson(FormattedFromArgs(AArgs), AArgs.Get('silent', False),
      StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
    Exit(nil);
  end;
  Msgs.SendFormattedText(Text, AArgs.Get('html', False),
    AArgs.Get('silent', False),
    { As TEXT: a message id is a full Int64 and JSON numbers stop being
      exact at 2^53 - the same rule ids follow everywhere else here. }
    StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
  Result := nil;
end;

{ message.sendNote (kind: voice | video, file, duration, waveform,
  length, thumb, tw, th, silent, replyTo) — a voice or video message
  recorded by the page (ui/recorder.js) and received by POST /upload: file
  and thumb are upload ids. Fields — td_api.tl at commit d1085f9:
  inputVoiceNote (OGG/Opus, waveform — 5 bits per sample, base64),
  inputVideoNote (MPEG4 H.264, square length <= 640, up to 60 s). }
function TWebApi.CmdMessageSendNote(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Content, Note, Local, Thumb: TJSONObject;
  Path, ThumbPath: string;
  Kind: string;
begin
  Msgs := RequireMsgs;
  if Msgs.ChatId = 0 then begin
    raise Exception.Create('no chat is open');
  end;
  Kind := AArgs.Get('kind', '');
  Path := UploadFilePath(AArgs.Get('file', ''));
  if Path = '' then begin
    raise Exception.Create('uploaded file not found');
  end;
  Local := TJSONObject.Create;
  Local.Add('@type', 'inputFileLocal');
  Local.Add('path', Path);
  Content := TJSONObject.Create;
  try
    Note := TJSONObject.Create;
    if Kind = 'voice' then begin
      Note.Add('@type', 'inputVoiceNote');
      Note.Add('voice_note', Local);
      Note.Add('duration', integer(AArgs.Get('duration', 0)));
      Note.Add('waveform', AArgs.Get('waveform', ''));
      Content.Add('@type', 'inputMessageVoiceNote');
      Content.Add('voice_note', Note);
      Content.Add('caption', TJSONNull.Create);
    end else if Kind = 'video' then begin
      Note.Add('@type', 'inputVideoNote');
      Note.Add('video_note', Local);
      ThumbPath := UploadFilePath(AArgs.Get('thumb', ''));
      if ThumbPath <> '' then begin
        Thumb := TJSONObject.Create;
        Thumb.Add('@type', 'inputThumbnail');
        Thumb.Add('thumbnail', TJSONObject.Create(['@type', 'inputFileLocal', 'path', ThumbPath]));
        Thumb.Add('width', integer(AArgs.Get('tw', 0)));
        Thumb.Add('height', integer(AArgs.Get('th', 0)));
        Note.Add('thumbnail', Thumb);
      end else begin
        Note.Add('thumbnail', TJSONNull.Create);
      end;
      Note.Add('duration', integer(AArgs.Get('duration', 0)));
      Note.Add('length', integer(AArgs.Get('length', 0)));
      Content.Add('@type', 'inputMessageVideoNote');
      Content.Add('video_note', Note);
    end else begin
      Note.Free;
      Local.Free;
      raise Exception.Create('message.sendNote needs kind voice or video');
    end;
    Content.Add('self_destruct_type', TJSONNull.Create);
    Msgs.SendInputContent(utf8string(Content.AsJSON), AArgs.Get('silent', False),
      StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
  finally
    Content.Free;
  end;
  Result := nil;
end;

{ message.sendRich (blocks, silent, replyTo): a rich message — the page
  builds the InputPageBlock blocks (util/richcompose.js). }
function TWebApi.CmdMessageSendRich(AArgs: TJSONObject): TJSONData;
var
  Msgs: TTdMessages;
  Arr: TJSONArray;
  Fixed: TJSONData;
begin
  Msgs := RequireMsgs;
  if Msgs.ChatId = 0 then begin
    raise Exception.Create('no chat is open');
  end;
  if AArgs = nil then begin
    raise Exception.Create('message.sendRich needs blocks');
  end;
  Arr := TJSONArray(AArgs.Find('blocks', jtArray));
  if (Arr = nil) or (Arr.Count = 0) then begin
    raise Exception.Create('empty message');
  end;
  Fixed := RichInputFix(Arr);
  try
    Msgs.SendRichMessage(utf8string(Fixed.AsJSON), AArgs.Get('silent', False),
      StrToInt64Def(utf8string(AArgs.Get('replyTo', '')), 0));
  finally
    Fixed.Free;
  end;
  Result := nil;
end;

{ Files already received through POST /upload: the page sends their ids
  (not paths — it cannot see the path on disk), the server finds the files
  and hands them to the model. asPhoto — as compressed photos, otherwise
  as documents; caption — markup in the same syntax as message text (html
  says which).

  An unknown id fails the whole command rather than being skipped
  quietly: otherwise part of the files would go and the person would
  think all of them did. }
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
  { mode: media | document | audio (the paperclip menu); the former
    asPhoto is the same as media. }
  Mode := utf8string(AArgs.Get('mode', ''));
  if Mode = '' then begin
    if AArgs.Get('asPhoto', False) then begin
      Mode := 'media';
    end else begin
      Mode := 'document';
    end;
  end;
  { meta — per file, video details from the page (duration, size, a
    thumbnail from a frame — uploaded as a separate file) or null. They
    become inputVideo / inputThumbnail fields (td_api.tl). }
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

{ A click on the progress ring: a download stops, an outgoing message whose
  upload has not finished is deleted (see TTdMessages.CancelTransfer). }
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
      utf8string(AArgs.Get('query', '')), AArgs.Get('savedTopic', Int64(0)));
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
  { Signing in to an account added to existing ones can be cancelled
    (accounts.cancel) — the sign-in screen shows a link for it. }
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

{ ------------------------------------------------------------------ }
{ to the first message of a day (the date chip in the history)         }
{ ------------------------------------------------------------------ }

{ chat.dateJump (id, date) -> messageId: the first message of the day;
  date — midnight of that day by the page's clock (unix). TDLib
  (td_api.tl) only has getChatMessageByDate — the last message NOT LATER
  than the date. So two steps: the last one BEFORE the day (date - 1),
  then getChatHistory from it with offset -2 — the ones after it, and of
  those the first with a date >= date. Nothing before the day (404: the
  chat began that day) or the next ones did not come — the last message
  of the day itself: not the first, but in the right day. }
function TWebApi.CmdChatDateJump(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  ChatId, Day: Int64;
  Slot: PtrInt;
begin
  Msgs := RequireMsgs;
  ChatId := AArgs.Get('id', Int64(0));
  Day := AArgs.Get('date', Int64(0));
  if (ChatId = 0) or (Day <= 0) then begin
    raise Exception.Create('chat.dateJump needs a chat id and a date');
  end;
  Slot := TakeDeferred(AConnId, AReqId, Day);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('chat', ChatId);
  Msgs.Request('getChatMessageByDate', '"chat_id":' + utf8string(IntToStr(ChatId))
    + ',"date":' + utf8string(IntToStr(Day - 1)), @DateJumpBeforeDone, Slot);
  Result := True;
end;

{ The slot is still waiting: the chat (Held) and the day's midnight (MessageId). }
function TWebApi.DateJumpSlot(ASlot: PtrInt; out AChat, ADay: Int64): boolean;
begin
  Result := (ASlot >= 0) and (ASlot <= High(FDeferred)) and FDeferred[ASlot].Busy
    and (FDeferred[ASlot].Held <> nil);
  if Result then begin
    AChat := FDeferred[ASlot].Held.Get('chat', Int64(0));
    ADay := FDeferred[ASlot].MessageId;
  end;
end;

procedure TWebApi.DateJumpReply(ASlot: PtrInt; AMessageId: Int64);
var
  Res: TJSONObject;
begin
  if AMessageId = 0 then begin
    Fail(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, 'No messages on this day');
  end else begin
    Res := TJSONObject.Create;
    Res.Add('messageId', AMessageId);
    Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  end;
  ReleaseDeferred(ASlot);
end;

{ The fallback step: the last message of the day. }
procedure TWebApi.DateJumpLastOfDay(ASlot: PtrInt);
var
  Msgs: TTdMessages;
  Chat, Day: Int64;
begin
  Msgs := TdMsgList;
  if (Msgs = nil) or not DateJumpSlot(ASlot, Chat, Day) then begin
    DateJumpReply(ASlot, 0);
    Exit;
  end;
  Msgs.Request('getChatMessageByDate', '"chat_id":' + utf8string(IntToStr(Chat))
    + ',"date":' + utf8string(IntToStr(Day + 86399)), @DateJumpLastDone, ASlot);
end;

procedure TWebApi.DateJumpBeforeDone(Sender: TObject; const AResp: TTdResponse);
var
  Msgs: TTdMessages;
  Chat, Day, Before: Int64;
begin
  if not DateJumpSlot(AResp.Tag, Chat, Day) then begin
    Exit;
  end;
  Before := 0;
  if AResp.Success then begin
    Before := JGetInt64(AResp.Obj, 'id');
  end;
  Msgs := TdMsgList;
  if (Before = 0) or (Msgs = nil) then begin
    DateJumpLastOfDay(AResp.Tag);
    Exit;
  end;
  Msgs.Request('getChatHistory', '"chat_id":' + utf8string(IntToStr(Chat))
    + ',"from_message_id":' + utf8string(IntToStr(Before))
    + ',"offset":-2,"limit":3,"only_local":false', @DateJumpAfterDone, AResp.Tag);
end;

procedure TWebApi.DateJumpAfterDone(Sender: TObject; const AResp: TTdResponse);
var
  Chat, Day, Best, Id: Int64;
  Arr: TJSONArray;
  I: integer;
  M: TJSONObject;
begin
  if not DateJumpSlot(AResp.Tag, Chat, Day) then begin
    Exit;
  end;
  Best := 0;
  if AResp.Success then begin
    Arr := JGetArr(AResp.Obj, 'messages');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if not (Arr.Items[I] is TJSONObject) then begin
          Continue;
        end;
        M := TJSONObject(Arr.Items[I]);
        Id := JGetInt64(M, 'id');
        if (JGetInt64(M, 'date') >= Day) and ((Best = 0) or (Id < Best)) then begin
          Best := Id;
        end;
      end;
    end;
  end;
  if Best = 0 then begin
    DateJumpLastOfDay(AResp.Tag);
  end else begin
    DateJumpReply(AResp.Tag, Best);
  end;
end;

procedure TWebApi.DateJumpLastDone(Sender: TObject; const AResp: TTdResponse);
var
  Chat, Day, Id: Int64;
begin
  if not DateJumpSlot(AResp.Tag, Chat, Day) then begin
    Exit;
  end;
  Id := 0;
  if AResp.Success and (JGetInt64(AResp.Obj, 'date') >= Day) then begin
    Id := JGetInt64(AResp.Obj, 'id');
  end;
  DateJumpReply(AResp.Tag, Id);
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

{ One person for a pop-up list: name, avatar (or the tiny preview from the
  object while it downloads — and the download starts right here), a
  colour in case of a letter, and the time (reactions, reads). }
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

{ A reaction can come from a chat too — a channel or an anonymous group admin. }
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

{ "Typing" and other actions in a chat — as a typing event (ui/typing.js).
  The name is resolved right here: the page does not know users, and a
  group member may appear nowhere else for it. senderId — user_id or
  chat_id; by it the page tells one sender from another. }
procedure TWebApi.ChatAction(Sender: TObject; AChatId, AThreadId: Int64;
  ASender: TJSONObject; const AAction: utf8string);
var
  Data, Person: TJSONObject;
  SenderId: Int64;
begin
  if (ASender = nil) or (AAction = '') then begin
    Exit;
  end;
  if JGetStr(ASender, '@type') = 'messageSenderChat' then begin
    SenderId := JGetInt64(ASender, 'chat_id');
  end else begin
    SenderId := JGetInt64(ASender, 'user_id');
  end;
  Data := TJSONObject.Create;
  Data.Add('chatId', AChatId);
  Data.Add('threadId', AThreadId);
  Data.Add('senderId', SenderId);
  Data.Add('action', string(AAction));
  Person := SenderPersonJson(ASender, 0);
  try
    Data.Add('name', Person.Get('name', ''));
  finally
    Person.Free;
  end;
  PushEvent('typing', Data);
end;

{ Who reacted (what = reactions; emoji or customEmojiId — which one) or who
  read it (what = viewers). In a private chat "who read it" is the peer and
  the time: getMessageReadDate, their id is kept in the slot until the
  answer. The answer is deferred: TDLib is asked anew on every hover —
  it is a question to Telegram's server and goes stale at once. }
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
    { First — whether it is possible at all (can_get_viewers /
      can_get_read_date in getMessageProperties). A page already told so
      sends checked and gets the list right away; one told "no" never asks
      again. }
    if AArgs.Get('checked', False) then begin
      PeopleQuery(Msgs, Id, Slot);
    end else begin
      Msgs.QueryProperties(Id, @PeoplePropsDone, Slot);
    end;
  end;
  Result := True;
end;

{ The "who read it" question itself: private chat — the peer's read time,
  group — the list of readers. }
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
    { messageReadDate* — a private chat. }
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

{ A t.me (telegram.me, tg:) link — open inside the app. TDLib parses it
  itself (getInternalLinkType), here is only the step by type:
    public chat    -> searchPublicChat           -> chatId
    invitation     -> checkChatInviteLink        -> chatId or invite
    message        -> getMessageLinkInfo         -> chatId, messageId
    anything else  -> external: true, the page hands the link to the browser.
  Fields and methods — per td_api.tl. }
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
    { An invoice link t.me/$name (buying Stars and the like): the page gets
      the invoice name, then the same path as the "Buy" button (bot.buy/bot.pay with
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

{ chat_id = 0 — no access before joining (td_api.tl): the page gets the
  chat's description for the "join?" question. }
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
    { As in the native client's window: avatar, description, the letter's
      colour for a chat without a photo. }
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

    { The photo of a chat there is no access to yet: the chat model has no
      row for it, so a photo downloaded later would have nowhere to show.
      So it is downloaded NOW and the answer waits: synchronous:true — the
      downloadFile answer comes when the file is on disk (td_api.tl). The
      file is small. }
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
  { The answer is taken out of the slot into ownership — Reply sends and
    frees it; otherwise ReleaseDeferred would free it a second time. }
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
  { Not downloaded — the window shows a blurred preview or a letter. }
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
    { The message is unavailable (a private chat without access and the
      like) — let the browser and the official client deal with it. }
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

{ Joining by invitation. The answer is chatJoinResult* in recent TDLib and
  a plain chat in older ones; both are understood. }
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

{ Pressing a callback button: getCallbackQueryAnswer, the bot's answer —
  text, alert (show_alert), url. The bot may not answer in time — then
  TDLib returns an error, and the page does not show it. }
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
  { Three kinds of callbackQueryPayload (td_api.tl): Data, DataWithPassword
    (the person types the 2FA password on the page), Game (game_short_name
    from the message's own messageGame). }
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

{ The bot's commands and its menu button — from userFullInfo.bot_info
  (td_api.tl): commands (command, description), menu_button (text, url).
  Only for a private chat with the bot: in groups every bot has its own,
  that comes later. }
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

{ Trim for utf8string without two conversion warnings. }
function TrimU(const AValue: utf8string): utf8string;
begin
  Result := utf8string(Trim(string(AValue)));
end;

{ ------------------------------------------------------------------ }
{ my account (Settings -> My account)                                 }
{ ------------------------------------------------------------------ }

{ account.get — as a chain: getMe -> getUserFullInfo -> getOption
  bio_length_max -> (downloadFile of the avatar if it is not on disk) ->
  answer. Fields — per td_api.tl at commit d1085f9: user (first_name,
  last_name, usernames.editable_username, phone_number, profile_photo,
  accent_color_id, is_premium), userFullInfo (bio, birthdate,
  personal_chat_id). The answer being built lives in Held['reply']. }
function TWebApi.CmdAccountGet(AConnId: Int64; AReqId: integer): boolean;
var
  Msgs: TTdMessages;
  Slot: PtrInt;
begin
  Msgs := RequireMsgs;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  { Which answer field the current download fills — see AccountFinish. }
  FDeferred[Slot].Held.Add('want', '');
  Msgs.Request('getMe', '', @AccountMeDone, Slot);
  Result := True;
end;

{ The slot is alive and the chain did not break; otherwise an error goes
  to the page and the slot is freed. }
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
  { For the colour picker: the colour ids of the name and the profile (-1 —
    profile without a colour) and their background emoji, which
    setAccentColor/setProfileAccentColor require to be passed again so as
    not to reset them. }
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
        { A broken preview — simply without it. }
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
  { The animated avatar is only in the full info: photo personal_photo /
    photo / public_photo (the same order as for chats in tdchats), the file
    — small_animation (160x160), otherwise animation. }
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
    { 0 — the year is not set (birthdate.year, td_api.tl). }
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
  { optionValueInteger.value — int64, a string in JSON (live log:
    "value":"140"). }
  BioMax := ACCOUNT_BIO_MAX_DEFAULT;
  V := AResp.Obj.Find('value');
  if V <> nil then begin
    BioMax := StrToIntDef(V.AsString, ACCOUNT_BIO_MAX_DEFAULT);
  end;
  Res.Add('bioMax', BioMax);

  AccountFinish(Slot);
end;

{ Downloading what is not on disk: first the avatar picture, then its
  animation — downloadFile synchronous, the answer arrives when the file is
  downloaded; the files are small. Everything in place — the answer goes
  to the page. }
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
  { Not downloaded — the page shows a preview, letters or a still picture
    instead of the animation. }
  if AResp.Success then begin
    Local := JGetObj(AResp.Obj, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      Res.Strings[FDeferred[Slot].Held.Strings['want']] :=
        string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
    end;
  end;
  AccountFinish(Slot);
end;

{ Changes — one field at a time, the answer is ok; the page takes the
  fresh values with a new account.get. Methods — td_api.tl: setName,
  setBio, setUsername, setBirthdate (null — remove), setPersonalChat (0 —
  remove), setProfilePhoto (inputChatPhotoStatic from an /upload file). }
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

{ The gallery of one's own avatars: getUserProfilePhotos (td_api.tl: up to
  100 at a time; personal and public photos are not in the answer) -> for
  each photo the largest photoSize is downloaded synchronously, one by one,
  -> answer. Previews right away — the minithumbnail, so the strip at the
  bottom is not empty. }
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
      { The largest size — by width: the types ('a', 'b', 'c') have no
        guaranteed order in the array. }
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
      { id — int64, as a string: in JS a number this long loses precision. }
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
          { A broken preview — without it. }
        end;
      end;
      { "Downloaded" — only if the file really is on disk. After
        optimizeStorage (tdstorage.pas: an empty file_types cleans photo
        files too, and full-size profile photos are those) TDLib still
        reports is_downloading_completed with a path that does not exist:
        checked live, 9 of 10 gallery files. Such a file is stale: first
        deleteFile so TDLib forgets the record, then the download. }
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
      { Animated avatar: chatPhoto.animation — animatedChatPhoto (length —
        the side of the square, file — MPEG4; td_api.tl). Downloaded right
        after the picture, the picture stays as the poster. }
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

{ What a photo still lacks: 'url' (the picture), 'animUrl' (the animation) or ''. }
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

{ The next file not downloaded — downloadFile synchronous; when everything
  is downloaded (or whatever could be), the answer goes to the page. Which
  field is being filled —
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
      { The record is stale (no file) — forget it first, the download is in
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

{ deleteFile of the stale record went through (or not — we try anyway):
  now the same download as for a file never downloaded. }
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
    { Not downloaded — '-': the field waits no more, and the page skips such
      an address (a picture — as a slide, an animation — keeping the picture). }
    if Item.Strings[Field] = '' then begin
      Item.Strings[Field] := '-';
    end;
  end;
  { The same index: the photo may still lack its animation. }
  AccountPhotosNext(Slot);
end;

{ Whether a username is free: checkChatUsername with the chat_id of the
  chat with oneself (= one's own user id; td_api.tl prescribes this for
  "private chat with self"). }
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
  { checkChatUsernameResult* — td_api.tl; the tail of the type name is the answer. }
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

{ Channels that qualify as the "personal channel": getSuitablePersonalChats
  -> chats (chat_ids). Titles — from the chat model: these are one's own
  channels, they are in the list. }
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
{ other kinds of bot buttons (td_api.tl at commit d1085f9)             }
{ ------------------------------------------------------------------ }

{ inlineKeyboardButtonTypeLoginUrl: getLoginUrlInfo -> loginUrlInfoOpen
  (url, skip_confirmation) — open right away; loginUrlInfoRequestConfirmation
  (url, domain, bot_user_id, request_write_access) — ask the person, then
  getLoginUrl (bot.loginUrlConfirm). }
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

{ The httpUrl answer -> url for the page. }
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

{ TDLib orderInfo -> for the page (name, phone, email, address(...)); nil -> null. }
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

{ Order data from the page -> orderInfo JSON for TDLib (through fpjson,
  with escaping); the address — only if the page sent one. }
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

{ Which invoice is being paid: by name from a t.me/$name link
  (inputInvoiceName, args.invoiceName) or an invoice message of the open
  chat (inputInvoiceMessage, args.msgId). Fields — td_api.tl at commit
  d1085f9. }
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
  paymentFormTypeStars (star_count) — the page gets the price and the form
  id, asks for confirmation and calls bot.pay; paymentFormTypeRegular with
  paymentProviderOther (url) — a link to pay at the provider; the rest
  (Stripe, Smart Glocal, subscriptions) — not supported. }
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
      { Card payment (td_api.tl at commit d1085f9): what to ask for (order
        data — invoice.need_*, shipping — is_flexible), what to pay with
        (saved_credentials, need_password), where to tokenize a new card
        (payment_provider). The card itself goes to the provider from the
        page (ui/payments.js) — only the token arrives here. }
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

{ bot.validateOrder — order data (validateOrderInfo, td_api.tl at commit
  d1085f9): order_info_id for sendPaymentForm and the shipping options of
  a flexible invoice (each one's sum — from price_parts). }
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

{ bot.tmpPassword — a temporary password for paying with a saved card
  (createTemporaryPassword; the password is the account's cloud password,
  typed by the person). }
function TWebApi.CmdBotTmpPassword(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
begin
  Result := True;
  RequireMsgs.Request('createTemporaryPassword',
    '"password":' + JsonStr(AArgs.Get('password', utf8string(''))) +
    ',"valid_for":' + utf8string(IntToStr(PAYMENT_TMP_PASSWORD_SEC)),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ bot.tmpPasswordState — whether there is a valid temporary password
  (getTemporaryPasswordState -> temporaryPasswordState: has_password,
  valid_for). Needed ALWAYS before paying with a saved card
  (inputCredentialsSaved, td_api.tl). Not to be confused with the form's
  need_password: that means "could save the card if a cloud password is
  set up" (live tdlib_raw.log: need_password false on every form, while
  the payment answered "Temporary password required to use saved
  credentials"). }
function TWebApi.CmdBotTmpPasswordState(AConnId: Int64; AReqId: integer): boolean;
begin
  Result := True;
  RequireMsgs.Request('getTemporaryPasswordState', '', @TmpPasswordStateDone,
    TakeDeferred(AConnId, AReqId, 0));
end;

procedure TWebApi.TmpPasswordStateDone(Sender: TObject; const AResp: TTdResponse);
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
  Res.Add('hasPassword', JGetBool(AResp.Obj, 'has_password'));
  Res.Add('validFor', JGetInt(AResp.Obj, 'valid_for'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Paying with Stars — only after explicit confirmation on the page:
  sendPaymentForm, credentials null (as td_api.tl prescribes for Stars). }
function TWebApi.CmdBotPay(AConnId: Int64; AReqId: integer;
  AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  Creds: utf8string;
begin
  Result := True;
  Msgs := RequireMsgs;
  { Stars — credentials null; a saved card — inputCredentialsSaved; a new
    one — inputCredentialsNew with the provider's JSON token (data). }
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
  { paymentResult: success, verification_url (3-D Secure and the like). }
  Res := TJSONObject.Create;
  Res.Add('success', JGetBool(AResp.Obj, 'success'));
  Res.Add('url', string(JGetStr(AResp.Obj, 'verification_url')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ keyboardButtonTypeRequestLocation: the browser gave the coordinates (the
  page asked for permission), what arrives here is the person's consent.
  inputMessageLocation in this schema is location only (latitude,
  longitude, horizontal_accuracy). }
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

{ keyboardButtonTypeRequestPoll: a poll put together on the page.
  inputMessagePoll (question, options of inputPollOption, is_anonymous,
  allows_multiple_answers, type: inputPollTypeRegular | inputPollTypeQuiz
  with correct_option_ids) — TDLib takes the other fields by default. }
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
  the bot of this private chat: the id of a private chat with a user
  equals their user id). }
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
{ the paperclip menu: checklist, article, attachment menu bots         }
{ ------------------------------------------------------------------ }

{ Checklist: inputMessageChecklist / inputChecklist (title, tasks of
  inputChecklistTask with ids from 1, others_can_add_tasks,
  others_can_mark_tasks_as_done) — td_api.tl at commit d1085f9. Premium
  only and not into channels — TDLib refuses by itself. }
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

{ Text as RichText: richTextPlain (td_api.tl). }
function RichPlain(const AText: utf8string): utf8string;
begin
  Result := '{"@type":"richTextPlain","text":' + JsonStr(AText) + '}';
end;

{ Article: inputMessageRichMessage -> inputRichMessage with
  richMessageSourceBlocks (Markdown and HTML in TDLib are for bots only).
  The page builds the blocks as simple descriptions, here they become
  InputPageBlock: heading (inputPageBlockSectionHeading, size 1..6),
  paragraph, list (inputPageBlockList of inputPageBlockListItem), quote
  (inputPageBlockBlockQuote with a paragraph inside), divider. }
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

{ Attachment menu bots suitable for the open chat (supports_*_chats). }
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

{ Map picture: getMapThumbnailFile (td_api.tl: PNG, zoom 13..20, width and
  height 16..1024 before scale, scale 1..3) -> file; not on disk —
  downloadFile synchronous. The page gets the file's address. }
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
  { The same handler for the downloadFile answer too: it is a File as well. }
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
{ mentions: suggestions while typing "@"                               }
{ ------------------------------------------------------------------ }

{ mention.search (query) — whom to suggest after "@" in the input field.
  The chat is the one the field writes to: the one open in the model (in a
  comment thread that is the discussion group, not the page's channel).
  Group — members via searchChatMembers with chatMembersFilterMention (in
  a thread — its topic_id: messageTopicThread); a private chat and the
  rest — contacts via searchContacts; a channel — nobody. Fields checked
  against td_api.tl at commit d1085f9. }
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

{ People by id — from the user model (TDLib sends updateUser before the
  search answer): name, username, colour, avatar (on disk — an address, not
  — a minithumbnail and a download). Oneself is not suggested. }
{ One user -> a card for the page (the "@" suggestion, search): userId,
  name, username, color, avatar / avatarThumb. nil — a deleted account or
  the user themself (AMe). }
function UserItemJson(AId, AMe: Int64): TJSONObject;
var
  Users: TTdUsers;
  U: TUserRow;
begin
  Result := nil;
  if (AId = 0) or (AId = AMe) then begin
    Exit;
  end;
  Result := TJSONObject.Create;
  Result.Add('userId', string(IntToStr(AId)));
  Result.Add('name', '');
  Result.Add('username', '');
  Result.Add('color', string(AccentKeyFor(-1, AId)));
  Result.Add('avatar', '');
  Result.Add('avatarThumb', '');
  Users := TdUserList;
  if Users = nil then begin
    Exit;
  end;
  U := Users.Find(AId);
  if U = nil then begin
    Result.Strings['name'] := string(Users.DisplayName(AId));
    Exit;
  end;
  if U.Deleted then begin
    FreeAndNil(Result);
    Exit;
  end;
  Result.Strings['name'] := string(U.DisplayName);
  Result.Strings['username'] := string(U.Username);
  Result.Strings['color'] := string(AccentKeyFor(U.AccentColorId, AId));
  if U.PhotoPath <> '' then begin
    Result.Strings['avatar'] := string(FileUrl(U.PhotoFileId, U.PhotoPath));
  end else begin
    Users.EnsurePhoto(U);
    Result.Strings['avatarThumb'] := string(ThumbDataUri(U.Minithumb));
  end;
end;

function MyUserId: Int64;
begin
  Result := 0;
  if TdApp.Active <> nil then begin
    Result := TdApp.Active.UserId;
  end;
end;

procedure TWebApi.MentionReply(ASlot: PtrInt; const AIds: array of Int64);
var
  Res, O: TJSONObject;
  Out: TJSONArray;
  I: integer;
  Me: Int64;
begin
  Out := TJSONArray.Create;
  Me := MyUserId;
  for I := 0 to High(AIds) do begin
    O := UserItemJson(AIds[I], Me);
    if O <> nil then begin
      Out.Add(O);
    end;
  end;
  Res := TJSONObject.Create;
  Res.Add('items', Out);
  Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
  ReleaseDeferred(ASlot);
end;

{ ------------------------------------------------------------------ }
{ global search (ui/search.js)                                         }
{ ------------------------------------------------------------------ }

{ Search as in Telegram Desktop: focusing the field above the list opens a
  panel with Chats / Channels / Apps tabs. An empty query — search.home
  (frequent and recent/recommended), a query — search.query (known chats,
  public ones, messages). Each is a short plan of TDLib requests run in
  turn on one deferred answer: Held keeps plan (steps: key, method,
  params, kind), i (the current step) and out (the answer). A step error
  is an empty list under its key, not an error of the whole answer
  (searchPublicChats, for instance, errors on a too short query). Fields
  checked against td_api.tl at commit d1085f9 (it has no
  getRecentlyFoundChats — recent ones come from searchRecentlyFoundChats
  with an empty query). }

procedure SearchStep(AHeld: TJSONObject; const AKey, AMethod, AParams, AKind: utf8string);
var
  Step: TJSONObject;
begin
  Step := TJSONObject.Create;
  Step.Add('key', string(AKey));
  Step.Add('method', string(AMethod));
  Step.Add('params', string(AParams));
  Step.Add('kind', string(AKind));
  TJSONArray(AHeld.Find('plan', jtArray)).Add(Step);
end;

function SearchHeld: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('plan', TJSONArray.Create);
  Result.Add('i', 0);
  Result.Add('out', TJSONObject.Create);
end;

{ The chat kind filter of searchMessages for a search tab ('' — a tab
  without messages). }
function SearchMessagesFilter(const ATab: utf8string): utf8string;
begin
  if ATab = 'channels' then begin
    Result := '{"@type":"searchMessagesChatTypeFilterChannel"}';
  end else if ATab = 'apps' then begin
    Result := '';
  end else begin
    Result := 'null';
  end;
end;

function JsonText(const AText: utf8string): utf8string;
var
  Q: TJSONString;
begin
  Q := TJSONString.Create(string(AText));
  try
    Result := utf8string(Q.AsJSON);
  finally
    Q.Free;
  end;
end;

function TopChats(const ACategory: utf8string): utf8string;
begin
  Result := '"category":{"@type":"' + ACategory + '"},"limit":' +
    utf8string(IntToStr(SEARCH_TOP_LIMIT));
end;

function TWebApi.CmdSearchHome(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Held: TJSONObject;
  Tab: utf8string;
begin
  Result := True;
  RequireMsgs;
  Tab := utf8string(AArgs.Get('tab', 'chats'));
  Held := SearchHeld;
  if Tab = 'channels' then begin
    SearchStep(Held, 'top', 'getTopChats', TopChats('topChatCategoryChannels'), 'chats');
    SearchStep(Held, 'recommended', 'getRecommendedChats', '', 'chats');
  end else if Tab = 'apps' then begin
    SearchStep(Held, 'top', 'getTopChats', TopChats('topChatCategoryWebAppBots'), 'chats');
    SearchStep(Held, 'popular', 'getGrossingWebAppBots',
      '"offset":"","limit":' + utf8string(IntToStr(SEARCH_LIST_LIMIT)), 'users');
  end else begin
    SearchStep(Held, 'top', 'getTopChats', TopChats('topChatCategoryUsers'), 'chats');
    SearchStep(Held, 'recent', 'searchRecentlyFoundChats',
      '"query":"","type_filter":null,"limit":' + utf8string(IntToStr(SEARCH_LIST_LIMIT)), 'chats');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  SearchNext(Slot);
end;

function TWebApi.CmdSearchQuery(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Held: TJSONObject;
  Tab, Query, Filter, MsgFilter: utf8string;
  Q: TJSONString;
begin
  Result := True;
  RequireMsgs;
  Tab := utf8string(AArgs.Get('tab', 'chats'));
  Q := TJSONString.Create(Trim(AArgs.Get('query', '')));
  try
    Query := utf8string(Q.AsJSON);
  finally
    Q.Free;
  end;
  if Tab = 'channels' then begin
    Filter := '{"@type":"searchChatTypeFilterChannel"}';
  end else if Tab = 'apps' then begin
    Filter := '{"@type":"searchChatTypeFilterBot"}';
  end else begin
    Filter := 'null';
  end;
  MsgFilter := SearchMessagesFilter(Tab);
  Held := SearchHeld;
  SearchStep(Held, 'chats', 'searchChats', '"query":' + Query + ',"type_filter":' + Filter +
    ',"limit":' + utf8string(IntToStr(SEARCH_LIST_LIMIT)), 'chats');
  SearchStep(Held, 'global', 'searchPublicChats', '"query":' + Query + ',"type_filter":' + Filter, 'chats');
  if MsgFilter <> '' then begin
    SearchStep(Held, 'messages', 'searchMessages',
      '"chat_list":{"@type":"chatListMain"},"query":' + Query + ',"offset":"","limit":' +
      utf8string(IntToStr(SEARCH_MESSAGES_LIMIT)) + ',"filter":null,"chat_type_filter":' + MsgFilter +
      ',"min_date":0,"max_date":0', 'messages');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  SearchNext(Slot);
end;

{ The next step of the plan, or the answer to the page when the steps are over. }
procedure TWebApi.SearchNext(ASlot: PtrInt);
var
  Held, Step, Res: TJSONObject;
  Plan: TJSONArray;
  I: integer;
begin
  Held := FDeferred[ASlot].Held;
  Plan := TJSONArray(Held.Find('plan', jtArray));
  I := Held.Get('i', 0);
  if I >= Plan.Count then begin
    Res := TJSONObject(Held.Find('out', jtObject).Clone);
    Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, Res);
    ReleaseDeferred(ASlot);
    Exit;
  end;
  Step := Plan.Objects[I];
  RequireMsgs.Request(utf8string(Step.Get('method', '')), utf8string(Step.Get('params', '')),
    @SearchStepDone, ASlot);
end;

{ TDLib's answer to a step -> a list for the page:
    chats — chat_ids -> rows as in the chat list (RowToJson);
    users — user_ids -> cards (UserItemJson);
    messages — messages -> chat (a row), id, date, text (a preview, as in
      the list — MessagePreview), sender, outgoing. }
function GiftSenderName(ASender: TJSONObject): utf8string; forward;

function SearchItems(const AKind: utf8string; AObj: TJSONObject): TJSONArray;
var
  Arr: TJSONArray;
  Chats: TTdChats;
  Row: TChatRow;
  M, Item, U: TJSONObject;
  I: integer;
  Me: Int64;
  Glyphs: TPreviewGlyphArray;
begin
  Result := TJSONArray.Create;
  Chats := TdChatList;
  Me := MyUserId;
  if AKind = 'users' then begin
    Arr := JGetArr(AObj, 'user_ids');
    if Arr = nil then begin
      Exit;
    end;
    for I := 0 to Arr.Count - 1 do begin
      U := UserItemJson(Arr.Items[I].AsInt64, Me);
      if U <> nil then begin
        Result.Add(U);
      end;
    end;
  end else if AKind = 'messages' then begin
    Arr := JGetArr(AObj, 'messages');
    if (Arr = nil) or (Chats = nil) then begin
      Exit;
    end;
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      M := TJSONObject(Arr.Items[I]);
      Row := Chats.Lookup(JGetInt64(M, 'chat_id'));
      if Row = nil then begin
        Continue;
      end;
      Item := TJSONObject.Create;
      Item.Add('chat', RowToJson(Chats, Row));
      Item.Add('id', JGetInt64(M, 'id'));
      Item.Add('date', JGetInt64(M, 'date'));
      Item.Add('text', string(MessagePreview(JGetObj(M, 'content'), Glyphs)));
      Item.Add('sender', string(GiftSenderName(JGetObj(M, 'sender_id'))));
      Item.Add('outgoing', JGetBool(M, 'is_outgoing'));
      Result.Add(Item);
    end;
  end else begin
    Arr := JGetArr(AObj, 'chat_ids');
    if (Arr = nil) or (Chats = nil) then begin
      Exit;
    end;
    for I := 0 to Arr.Count - 1 do begin
      Row := Chats.Lookup(Arr.Items[I].AsInt64);
      if Row <> nil then begin
        Result.Add(RowToJson(Chats, Row));
      end;
    end;
  end;
end;

procedure TWebApi.SearchStepDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Held, Step: TJSONObject;
  Items: TJSONArray;
  I: integer;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  Held := FDeferred[Slot].Held;
  I := Held.Get('i', 0);
  Step := TJSONArray(Held.Find('plan', jtArray)).Objects[I];
  if AResp.Success then begin
    Items := SearchItems(utf8string(Step.Get('kind', '')), AResp.Obj);
  end else begin
    Items := TJSONArray.Create;
  end;
  TJSONObject(Held.Find('out', jtObject)).Add(Step.Get('key', ''), Items);
  { Messages page further (search.messages): their next_offset. }
  if AResp.Success and (Step.Get('kind', '') = 'messages') then begin
    TJSONObject(Held.Find('out', jtObject)).Add(Step.Get('key', '') + 'Next',
      JGetStr(AResp.Obj, 'next_offset'));
  end;
  Held.Integers['i'] := I + 1;
  SearchNext(Slot);
end;

{ search.messages (tab, query, offset) — "Show more" under the messages
  found: the next page of searchMessages. }
function TWebApi.CmdSearchMessages(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Held: TJSONObject;
  Filter: utf8string;
begin
  Result := True;
  RequireMsgs;
  Filter := SearchMessagesFilter(utf8string(AArgs.Get('tab', 'chats')));
  if Filter = '' then begin
    raise Exception.Create('no messages in this tab');
  end;
  Held := SearchHeld;
  SearchStep(Held, 'messages', 'searchMessages',
    '"chat_list":{"@type":"chatListMain"},"query":' + JsonText(Trim(AArgs.Get('query', ''))) +
    ',"offset":' + JsonText(AArgs.Get('offset', '')) + ',"limit":' +
    utf8string(IntToStr(SEARCH_MESSAGES_LIMIT)) + ',"filter":null,"chat_type_filter":' + Filter +
    ',"min_date":0,"max_date":0', 'messages');
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  SearchNext(Slot);
end;

{ ---- public posts (the Posts tab) ----
  Search across all public channels: a few queries a day for free, then
  for Stars (td_api.tl: getPublicPostSearchLimits, searchPublicPosts,
  star_count — how much the person agreed to pay; 0 — free). The page
  first asks for the limits and shows them, and searches only on a press,
  a paid search — by a separate button with the price. }

function PostLimitsJson(L: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('dailyFree', JGetInt(L, 'daily_free_query_count'));
  Result.Add('remainingFree', JGetInt(L, 'remaining_free_query_count'));
  Result.Add('nextFreeIn', JGetInt(L, 'next_free_query_in'));
  Result.Add('stars', JGetInt64(L, 'star_count'));
  Result.Add('currentFree', JGetBool(L, 'is_current_query_free'));
end;

{ search.postLimits (query) -> the limits for this query. }
function TWebApi.CmdSearchPostLimits(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getPublicPostSearchLimits',
    '"query":' + JsonText(Trim(AArgs.Get('query', ''))), @PostLimitsDone, Slot);
end;

procedure TWebApi.PostLimitsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, PostLimitsJson(AResp.Obj));
  ReleaseDeferred(Slot);
end;

{ search.posts (query, offset, stars) -> messages, next, limits,
  exceeded. }
function TWebApi.CmdSearchPosts(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('searchPublicPosts',
    '"query":' + JsonText(Trim(AArgs.Get('query', ''))) +
    ',"offset":' + JsonText(AArgs.Get('offset', '')) +
    ',"limit":' + utf8string(IntToStr(SEARCH_MESSAGES_LIMIT)) +
    ',"star_count":' + utf8string(IntToStr(ArgId(AArgs, 'stars'))), @PostsDone, Slot);
end;

procedure TWebApi.PostsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('messages', SearchItems('messages', AResp.Obj));
  Res.Add('next', JGetStr(AResp.Obj, 'next_offset'));
  Res.Add('limits', PostLimitsJson(JGetObj(AResp.Obj, 'search_limits')));
  Res.Add('exceeded', JGetBool(AResp.Obj, 'are_limits_exceeded'));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ search.recent (op: add | remove | clear, id) — recently found: a chat
  opened from search joins them, the cross and Clear remove them. }
function TWebApi.CmdSearchRecent(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Op, Body: utf8string;
  Method: utf8string;
begin
  Result := True;
  Op := utf8string(AArgs.Get('op', ''));
  Body := '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'id')));
  if Op = 'add' then begin
    Method := 'addRecentlyFoundChat';
  end else if Op = 'remove' then begin
    Method := 'removeRecentlyFoundChat';
  end else if Op = 'clear' then begin
    Method := 'clearRecentlyFoundChats';
    Body := '';
  end else begin
    raise Exception.Create('search.recent needs op: add, remove or clear');
  end;
  RequireMsgs.Request(Method, Body, @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ ------------------------------------------------------------------ }
{ contacts (the Contacts button above the chat list)                   }
{ ------------------------------------------------------------------ }

{ contacts.list: getContacts (td_api.tl: users — user_ids) -> getUser for
  every id, all at once; the answers gather in Held['items'], the counter
  is Held['left']. At zero — the answer to the page; the page orders them. }
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

{ One contact: name, username, phone, avatar (on disk — an address, not —
  a minithumbnail and a download through the user model), colour, status
  (userStatus* — the tail of the type name and was_online for Offline). }
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
    { There is a photo, but it is still downloading — the page asks for the
      list again (the user model's OnChanged is taken by the native
      history window). }
    Item.Add('photoPending', False);
    Photo := JGetObj(AResp.Obj, 'profile_photo');
    if Photo <> nil then begin
      B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
      if B64 <> '' then begin
        try
          Thumb := DecodeStringBase64(string(B64));
          Item.Strings['avatarThumb'] := string(ThumbDataUri(Thumb));
        except
          { A broken preview — without it. }
        end;
      end;
      Small := JGetObj(Photo, 'small');
      Local := JGetObj(Small, 'local');
      if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
        Item.Strings['avatar'] := string(FileUrl(JGetInt(Small, 'id'), JGetStr(Local, 'path')));
      end else begin
        { The download goes through the user model (as for the people in
          the reactions window); the picture shows up with the next list
          request. }
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
    { The folder of the private chat with the person — the same chip as in
      the chat list. The private chat's id equals the user id; the chat may
      not exist yet (never written to) — then "no folder", and the menu
      creates the private chat first (main.js). }
    Chats := TdChatList;
    FolderId := 0;
    CRow := nil;
    if Chats <> nil then begin
      CRow := Chats.Lookup(Id);
      FolderId := Chats.RowFolderId(CRow);
    end;
    Item.Add('folderId', FolderId);
    { Only a chat with a place in a list (main or archive) gets into a
      folder. A private chat without messages is not there: addChatToList
      answers "Chat is not in a chat list" (live tdlib_raw.log), and
      editChatFolder accepts it, but TDLib then drops it from the folder by
      itself (DialogFilterManager: "Skip nonjoined"). For the page — so the
      menu does not promise the impossible. }
    Item.Add('inList', (CRow <> nil) and (CRow.InList or CRow.InArchive));
    if FolderId <> 0 then begin
      Item.Add('folder', string(Chats.FolderTitle(FolderId)));
    end else begin
      Item.Add('folder', '');
    end;
    Status := JGetObj(AResp.Obj, 'status');
    Item.Add('status', string(JGetStr(Status, '@type')));
    Item.Add('wasOnline', JGetInt64(Status, 'was_online'));
    { A bot: the line says "bot" instead of "online", as in Desktop. }
    Item.Add('bot', JGetStr(JGetObj(AResp.Obj, 'type'), '@type') = 'userTypeBot');
    { A group member (chat.members): the role from the member's status. }
    if FDeferred[Slot].Held.Find('roles') is TJSONObject then begin
      Item.Add('role', TJSONObject(FDeferred[Slot].Held.Objects['roles']).Get(
        string(IntToStr(Id)), ''));
    end;
    if FDeferred[Slot].Held.Find('tags') is TJSONObject then begin
      Item.Add('tag', TJSONObject(FDeferred[Slot].Held.Objects['tags']).Get(
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
{ creating groups and channels, managing them (ui/newchat.js, manage.js) }
{ ------------------------------------------------------------------ }

{ The management screens copy Telegram Desktop and read TDLib's fields
  themselves (td_api.tl at commit d1085f9), so the server is thin here:
  admin (steps: key, method, params) runs the steps in turn and returns
  TDLib's answers as is, under their keys. Only the methods listed below —
  reading and editing groups and channels; a file (the group photo) the
  page passes as inputFileUpload with an upload id (RichInputFix). A step
  error fails the whole command: these are edits, and a silently skipped
  one is worse than an explicit failure. }
const
  ADMIN_METHODS: array[0..38] of string = (
    'getChat', 'getSupergroup', 'getSupergroupFullInfo', 'getBasicGroup',
    'getBasicGroupFullInfo', 'getSupergroupMembers', 'searchChatMembers',
    'getChatMember', 'getChatAdministrators', 'getChatInviteLinks',
    'getChatInviteLinkCounts', 'getChatInviteLinkMembers', 'getChatEventLog',
    'checkChatUsername', 'getChatJoinRequests',
    'createNewBasicGroupChat', 'createNewSupergroupChat', 'setChatTitle',
    'setChatDescription', 'setChatPhoto', 'setChatPermissions',
    'setChatSlowModeDelay', 'setChatMemberStatus', 'banChatMember',
    'addChatMembers', 'setSupergroupUsername', 'toggleSupergroupIsAllHistoryAvailable',
    'toggleSupergroupSignMessages', 'toggleChatHasProtectedContent',
    'replacePrimaryChatInviteLink', 'createChatInviteLink', 'editChatInviteLink',
    'revokeChatInviteLink', 'deleteRevokedChatInviteLink', 'deleteChat',
    'upgradeBasicGroupChatToSupergroupChat', 'processChatJoinRequest',
    'toggleSupergroupJoinByRequest', 'setChatMemberTag');

  { Account settings (ui/settings.js — sections as in Telegram Desktop):
    privacy, sessions, notifications, folders, Premium, Stars, gifts,
    proxy, Telegram Business. The same admin, the same principle: the page
    reads TDLib's fields itself. }
  SETTINGS_METHODS: array[0..92] of string = (
    'getMe', 'getUser', 'getUserFullInfo', 'getContacts',
    'getUserPrivacySettingRules', 'setUserPrivacySettingRules',
    'getReadDatePrivacySettings', 'setReadDatePrivacySettings',
    'getNewChatPrivacySettings', 'setNewChatPrivacySettings',
    'getBlockedMessageSenders', 'setMessageSenderBlockList',
    'getActiveSessions', 'terminateSession', 'terminateAllOtherSessions',
    'toggleSessionCanAcceptCalls', 'toggleSessionCanAcceptSecretChats',
    'setInactiveSessionTtl', 'getAccountTtl', 'setAccountTtl',
    'getDefaultMessageAutoDeleteTime', 'setDefaultMessageAutoDeleteTime',
    'getPasswordState', 'setPassword', 'getConnectedWebsites',
    'disconnectWebsite', 'disconnectAllWebsites',
    'getArchiveChatListSettings', 'setArchiveChatListSettings',
    'getOption', 'setOption',
    'getScopeNotificationSettings', 'setScopeNotificationSettings',
    'resetAllNotificationSettings', 'getChatNotificationSettingsExceptions',
    'getChatFolder', 'createChatFolder', 'editChatFolder', 'deleteChatFolder',
    'reorderChatFolders', 'getRecommendedChatFolders', 'toggleChatFolderTags',
    'getChatFolderChatsToLeave', 'getChatFolderChatCount',
    'getPremiumFeatures', 'getPremiumState', 'getPremiumLimit',
    'getStarTransactions', 'getStarSubscriptions', 'getAvailableGifts', 'sendGift',
    'getLocalizationTargetInfo', 'setDefaultReactionType', 'getEmojiReaction',
    'getInstalledStickerSets', 'changeStickerSet', 'reorderInstalledStickerSets',
    'getProxies', 'addProxy', 'editProxy', 'enableProxy', 'disableProxy',
    'removeProxy', 'pingProxy',
    'setBusinessLocation', 'setBusinessOpeningHours', 'setBusinessStartPage',
    'setBusinessGreetingMessageSettings', 'setBusinessAwayMessageSettings',
    'getBusinessChatLinks', 'getChats', 'searchChatsOnServer', 'getTimeZones',
    'getChatScheduledMessages', 'editMessageSchedulingState', 'deleteMessages',
    'loadQuickReplyShortcuts', 'loadQuickReplyShortcutMessages', 'checkQuickReplyShortcutName',
    'setQuickReplyShortcutName', 'deleteQuickReplyShortcut', 'reorderQuickReplyShortcuts',
    'deleteQuickReplyShortcutMessages', 'addQuickReplyShortcutMessage', 'editQuickReplyMessage',
    'getBusinessConnectedBot', 'setBusinessConnectedBot', 'deleteBusinessConnectedBot',
    'createBusinessChatLink', 'editBusinessChatLink', 'deleteBusinessChatLink', 'searchPublicChat',
    'loadSavedMessagesTopics');

  { setOption — only these: the other TDLib options are the server's own
    setup (online, paths, network), not for the page to touch. }
  SETTINGS_OPTIONS: array[0..5] of string = (
    'disable_top_chats', 'disable_contact_registered_notifications',
    'ignore_sensitive_content_restrictions', 'disable_animated_emoji',
    'language_pack_id', 'localization_target');

function InList(const AName: string; const AList: array of string): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(AList) do begin
    if AList[I] = AName then begin
      Exit(True);
    end;
  end;
end;

function AdminAllowed(const AMethod: string; AParams: TJSONObject): boolean;
begin
  if AMethod = 'setOption' then begin
    Result := (AParams <> nil) and InList(AParams.Get('name', ''), SETTINGS_OPTIONS);
  end else begin
    Result := InList(AMethod, ADMIN_METHODS) or InList(AMethod, SETTINGS_METHODS);
  end;
end;

{ TDLib's answer without the request's service fields. }
function AdminClean(AObj: TJSONObject): TJSONObject;
var
  I: integer;
begin
  Result := TJSONObject(AObj.Clone);
  for I := Result.Count - 1 downto 0 do begin
    if (Result.Names[I] = '@extra') or (Result.Names[I] = '@client_id') then begin
      Result.Delete(I);
    end;
  end;
end;

function TWebApi.CmdAdmin(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Held, Step, Src: TJSONObject;
  Steps, Plan: TJSONArray;
  Fixed: TJSONData;
  Body: string;
  I: integer;
begin
  Result := True;
  RequireMsgs;
  Steps := TJSONArray(AArgs.Find('steps', jtArray));
  if (Steps = nil) or (Steps.Count = 0) then begin
    raise Exception.Create('admin needs steps');
  end;
  Held := TJSONObject.Create;
  try
    Plan := TJSONArray.Create;
    Held.Add('plan', Plan);
    Held.Add('i', 0);
    Held.Add('out', TJSONObject.Create);
    for I := 0 to Steps.Count - 1 do begin
      if not (Steps.Items[I] is TJSONObject) then begin
        raise Exception.Create('admin: bad step');
      end;
      Src := TJSONObject(Steps.Items[I]);
      if not AdminAllowed(Src.Get('method', ''), TJSONObject(Src.Find('params', jtObject))) then begin
        raise Exception.Create('admin: method not allowed: ' + Src.Get('method', ''));
      end;
      Body := '';
      if Src.Find('params', jtObject) <> nil then begin
        Fixed := RichInputFix(Src.Find('params', jtObject));
        try
          Body := Trim(Fixed.AsJSON);
        finally
          Fixed.Free;
        end;
        { An object without its outer braces — a request body (tdreq.SendRequest). }
        Body := Trim(Copy(Body, 2, Length(Body) - 2));
      end;
      Step := TJSONObject.Create;
      Step.Add('key', Src.Get('key', IntToStr(I)));
      Step.Add('method', Src.Get('method', ''));
      Step.Add('params', Body);
      { soft: an error of this step is not an error of the command; the
        answer has an error object with message under its key (reading: a
        method unavailable without Premium must not take down the whole
        section). }
      Step.Add('soft', Src.Get('soft', False));
      Plan.Add(Step);
    end;
  except
    Held.Free;
    raise;
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  AdminNext(Slot);
end;

procedure TWebApi.AdminNext(ASlot: PtrInt);
var
  Held, Step: TJSONObject;
  Plan: TJSONArray;
  I: integer;
begin
  Held := FDeferred[ASlot].Held;
  Plan := TJSONArray(Held.Find('plan', jtArray));
  I := Held.Get('i', 0);
  if I >= Plan.Count then begin
    Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId,
      TJSONObject(Held.Find('out', jtObject).Clone));
    ReleaseDeferred(ASlot);
    Exit;
  end;
  Step := Plan.Objects[I];
  RequireMsgs.Request(utf8string(Step.Get('method', '')), utf8string(Step.Get('params', '')),
    @AdminStepDone, ASlot);
end;

procedure TWebApi.AdminStepDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Held, Step, Err: TJSONObject;
  I: integer;
begin
  Slot := AResp.Tag;
  if (not AResp.Success) and (Slot >= 0) and (Slot <= High(FDeferred))
     and FDeferred[Slot].Busy and (FDeferred[Slot].Held <> nil) then begin
    Held := FDeferred[Slot].Held;
    I := Held.Get('i', 0);
    Step := TJSONArray(Held.Find('plan', jtArray)).Objects[I];
    if Step.Get('soft', False) then begin
      Err := TJSONObject.Create;
      Err.Add('@type', 'error');
      Err.Add('message', string(AResp.ErrorMessage));
      TJSONObject(Held.Find('out', jtObject)).Add(Step.Get('key', ''), Err);
      Held.Integers['i'] := I + 1;
      AdminNext(Slot);
      Exit;
    end;
  end;
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Held := FDeferred[Slot].Held;
  I := Held.Get('i', 0);
  Step := TJSONArray(Held.Find('plan', jtArray)).Objects[I];
  TJSONObject(Held.Find('out', jtObject)).Add(Step.Get('key', ''), AdminClean(AResp.Obj));
  Held.Integers['i'] := I + 1;
  AdminNext(Slot);
end;

{ td.kept (types) — the latest TDLib updates of these types
  (KEPT_UPDATE_TYPES): an object "type - the update's JSON as a string or empty". }
function TWebApi.CmdTdKept(AArgs: TJSONObject): TJSONData;
var
  Types: TJSONArray;
  Res: TJSONObject;
  I, J: integer;
  T: string;
  Raw: utf8string;
  Found: TStringList;
begin
  Res := TJSONObject.Create;
  Result := Res;
  Types := TJSONArray(AArgs.Find('types', jtArray));
  if (Types = nil) or (TdApp.Active = nil) then begin
    Exit;
  end;
  for I := 0 to Types.Count - 1 do begin
    T := Types.Items[I].AsString;
    { "type:" — everything kept of this type under "type:id" keys. }
    if (T <> '') and (T[Length(T)] = ':') then begin
      Found := TStringList.Create;
      try
        TdApp.Active.KeptMatching(T, Found);
        for J := 0 to Found.Count - 1 do begin
          Res.Add(Found.Names[J], Found.ValueFromIndex[J]);
        end;
      finally
        Found.Free;
      end;
      Continue;
    end;
    Raw := TdApp.Active.KeptUpdate(T);
    { As a string, as it came from TDLib — the page parses it itself. Not
      GetJSON: emoji there are surrogate pairs, and fpjson builds invalid
      UTF-8 from some of them — the browser drops the web socket on such a
      frame (live: updateActiveEmojiReactions). }
    Res.Add(T, string(Raw));
  end;
end;

{ users.cards (ids) — cards of people for the management lists: the same
  as for contacts (ContactUserDone: name, avatar, "online" status). }
function TWebApi.CmdUsersCards(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Arr: TJSONArray;
  Msgs: TTdMessages;
  I, N: integer;
  Id: Int64;
begin
  Result := True;
  Msgs := RequireMsgs;
  Arr := TJSONArray(AArgs.Find('ids', jtArray));
  N := 0;
  if Arr <> nil then begin
    N := Arr.Count;
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('items', TJSONArray.Create);
  FDeferred[Slot].Held.Add('replyKey', 'items');
  if N = 0 then begin
    Reply(AConnId, AReqId, TJSONObject(GetJSON('{"items":[]}')));
    ReleaseDeferred(Slot);
    Exit;
  end;
  FDeferred[Slot].Held.Add('left', N);
  for I := 0 to N - 1 do begin
    Id := 0;
    if Arr.Items[I].JSONType = jtNumber then begin
      Id := Arr.Items[I].AsInt64;
    end else if Arr.Items[I].JSONType = jtString then begin
      Id := StrToInt64Def(Arr.Items[I].AsString, 0);
    end;
    Msgs.Request('getUser', '"user_id":' + utf8string(IntToStr(Id)), @ContactUserDone, Slot);
  end;
end;

{ ------------------------------------------------------------------ }
{ greeting in an empty private chat                                    }
{ ------------------------------------------------------------------ }

{ chat.greeting — what to show in an empty private chat (td_api.tl at
  commit d1085f9): userFullInfo.bot_info (description, short_description)
  — a bot card with a Start button; business_info.start_page (title,
  message, sticker) — the start page of a business account; otherwise — a
  random sticker from getGreetingStickers, as in the native client. The
  sticker is downloaded before the answer (synchronous) so there is
  something to show. }
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

{ A sticker for the page: file id, size, emoji, format (the stickerFormat*
  tail) and the address if the file is on disk already; otherwise
  Held['fileId'] for the download. }
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

{ The answer — or after the sticker has downloaded. }
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

{ A click on the greeting sticker — it goes to the open chat. }
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
{ the chat info panel (the "i" button above the history)               }
{ ------------------------------------------------------------------ }

{ Media kinds for the panel's counters — searchMessagesFilter* (td_api.tl);
  the keys are the ones the page expects. }
const
  INFO_COUNT_FILTERS: array[0..7] of string = ('searchMessagesFilterPhoto',
    'searchMessagesFilterVideo', 'searchMessagesFilterDocument',
    'searchMessagesFilterAudio', 'searchMessagesFilterUrl',
    'searchMessagesFilterVoiceNote', 'searchMessagesFilterAnimation',
    'searchMessagesFilterPoll');
  INFO_COUNT_KEYS: array[0..7] of string = ('photo', 'video', 'document',
    'audio', 'url', 'voice', 'animation', 'poll');
  { The counter encodes both the slot and the kind in the tag: Slot * INFO_TAG_MUL + index. }
  INFO_TAG_MUL = 16;

{ chat.info: the chat row (title, avatar, colour, sound) + by the chat's
  kind getUser/getUserFullInfo, getSupergroup/getSupergroupFullInfo or
  getBasicGroup/getBasicGroupFullInfo + getChatMessageCount for seven media
  kinds — all in parallel; Held['left'] counts the answers, at zero — the
  answer. }
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
  { A channel — also the number of similar channels (getChatSimilarChatCount). }
  if Row.Kind = ckChannel then begin
    Inc(Left);
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
  if Row.Kind = ckChannel then begin
    Msgs.Request('getChatSimilarChatCount', '"chat_id":' + utf8string(IntToStr(ChatId)) +
      ',"return_local":false', @InfoSimilarDone, Slot);
  end;
  for I := 0 to High(INFO_COUNT_FILTERS) do begin
    Msgs.Request('getChatMessageCount',
      '"chat_id":' + utf8string(IntToStr(ChatId)) + ',"topic_id":null,"filter":{"@type":"' +
      utf8string(INFO_COUNT_FILTERS[I]) + '"},"return_local":false',
      @InfoCountDone, Slot * INFO_TAG_MUL + I);
  end;
end;

{ One more answer arrived: the counter goes down, at zero — the answer to the page. }
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

{ user: phone, username, status, whether a contact, whether a bot. }
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

{ userFullInfo: bio, birthday, blocking, gifts, the bot's description. }
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
    { block_list: null — not blocked (td_api.tl). }
    Res.Add('isBlocked', JGetObj(AResp.Obj, 'block_list') <> nil);
    Res.Add('giftCount', JGetInt(AResp.Obj, 'gift_count'));
    Bot := JGetObj(AResp.Obj, 'bot_info');
    if Bot <> nil then begin
      Res.Add('description', string(JGetStr(Bot, 'description')));
    end;
  end;
  InfoStep(AResp.Tag);
end;

{ supergroup / basicGroup: member count, public link. }
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
    { One's own status: whether the account is a member — for the panel to
      decide between "Join" and "Leave". Restricted — by is_member. }
    if JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusRestricted' then begin
      Res.Add('isMember', JGetBool(JGetObj(AResp.Obj, 'status'), 'is_member'));
    end else begin
      Res.Add('isMember', (JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusCreator')
        or (JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusAdministrator')
        or (JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusMember'));
    end;
    { Manage (ui/manage.js) — the owner or an administrator. }
    Res.Add('isCreator', JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusCreator');
    Res.Add('canManage', (JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusCreator')
      or (JGetStr(JGetObj(AResp.Obj, 'status'), '@type') = 'chatMemberStatusAdministrator'));
    User := JGetStr(JGetObj(AResp.Obj, 'usernames'), 'editable_username');
    if User <> '' then begin
      Res.Add('username', string(User));
      Res.Add('link', 'https://t.me/' + string(User));
    end;
  end;
  InfoStep(AResp.Tag);
end;

{ supergroupFullInfo / basicGroupFullInfo: description, members, the
  invite link (if there is no public one), whether members can be viewed. }
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
    { basicGroupFullInfo has no can_get_members field — the member list
      comes in it directly. }
    if JGetStr(AResp.Obj, '@type') = 'basicGroupFullInfo' then begin
      Res.Add('canGetMembers', True);
    end else begin
      Res.Add('canGetMembers', JGetBool(AResp.Obj, 'can_get_members'));
    end;
    Invite := JGetStr(JGetObj(AResp.Obj, 'invite_link'), 'invite_link');
    if Invite <> '' then begin
      Res.Add('inviteLink', string(Invite));
    end;
    { The channel's discussion group (for a group — its channel): the Chat
      button in the channel info leads there. 0 — none. }
    if JGetInt64(AResp.Obj, 'linked_chat_id') <> 0 then begin
      Res.Add('linkedChatId', JGetInt64(AResp.Obj, 'linked_chat_id'));
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

{ getChatSimilarChatCount -> similarCount (an approximate number of
  similar channels; an error — no number). }
procedure TWebApi.InfoSimilarDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  Slot := AResp.Tag;
  if not InfoSlot(Slot, Res) then begin
    Exit;
  end;
  if AResp.Success then begin
    Res.Add('similarCount', JGetInt(AResp.Obj, 'count'));
  end;
  InfoStep(Slot);
end;

{ chat.similar (chatId) — similar channels (getChatSimilarChats), as chat
  list rows, like search results. }
function TWebApi.CmdChatSimilar(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Held: TJSONObject;
begin
  Result := True;
  RequireMsgs;
  Held := SearchHeld;
  SearchStep(Held, 'items', 'getChatSimilarChats',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))), 'chats');
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := Held;
  SearchNext(Slot);
end;

{ chat.similarOpened (chatId, openedId) — openChatSimilarChat: Telegram
  counts which of the suggested channels get opened. }
function TWebApi.CmdChatSimilarOpened(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
begin
  Result := True;
  RequireMsgs.Request('openChatSimilarChat',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))) +
    ',"opened_chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'openedId'))),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ chat.members: group members — getSupergroupMembers (recent, up to
  INFO_MEMBERS_MAX) or members from basicGroupFullInfo; then getUser for
  each one the same way as contacts (ContactUserDone), with the role from
  the member's status. }
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

{ chatMembers.members or basicGroupFullInfo.members: chatMember
  (member_id, status). The role — by the status type: Creator / Administrator. }
procedure TWebApi.MembersListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Arr: TJSONArray;
  M, Sender2: TJSONObject;
  I, N: integer;
  Id: Int64;
  Role, St: utf8string;
  Roles, Tags, Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Roles := TJSONObject(FDeferred[Slot].Held.Objects['roles']);
  { The member's label (chatMember.tag, td_api.tl): an administrator's
    custom title or a member tag — the official client shows it instead of
    "owner"/"admin". Live tdlib_raw.log: the group creator had a tag
    ("Admin" in Russian), an ordinary member can have one too. }
  Tags := TJSONObject.Create;
  FDeferred[Slot].Held.Add('tags', Tags);
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
      Tags.Add(string(IntToStr(Id)), string(JGetStr(M, 'tag')));
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

{ Panel actions — one TDLib method each, the answer is ok (SimpleDone):
  contact.add — addContact (importedContact: first and last name; the
  phone is not shared), contact.remove — removeContacts, user.block —
  setMessageSenderBlockList (blockListMain / null), chat.leave — leaveChat,
  contact.share — a contact card (inputMessageContact) into a chosen chat. }
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
{ profile gifts                                                        }
{ ------------------------------------------------------------------ }

{ A gift sticker for the page: file id, format (stickerFormat*) and the
  address if it is on disk already. }
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

{ The gift sender's name: messageSenderUser — the user model,
  messageSenderChat — the chat title; no sender — ''. }
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

{ The gift sender's avatar — as in the native client, a circle in the
  tile's corner: a person — the user model (the photo is downloaded there
  too), a channel or group — the chat row. Writes avatar, avatarThumb,
  color into AItem; no sender — empty. }
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
  { Where a click on the sender's name leads: the private chat with the person or the chat itself. }
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

{ gifts.list: getReceivedGifts (td_api.tl at commit d1085f9) for the
  chat's owner — a person (messageSenderUser) or a channel
  (messageSenderChat). The kind — exclude_* flags: unlimited, limited
  (upgradable or not), unique (upgraded); sortByPrice — sort_by_price;
  offset — for "more". Gift stickers are downloaded before the answer —
  one per distinct file. }
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

{ The next sticker not downloaded (one file for all gifts that use it) —
  downloadFile synchronous; everything in place — the answer. }
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
  { The same file in other gifts — the same address; '-' — did not
    download, we wait no more. }
  for I := 0 to Arr.Count - 1 do begin
    S := TJSONObject(TJSONObject(Arr.Items[I]).Objects['sticker']);
    if S.Integers['fileId'] = FileId then begin
      S.Strings['url'] := Url;
    end;
  end;
  GiftsNext(Slot);
end;

{ ------------------------------------------------------------------ }
{ chat media in the info panel: photos, videos, GIFs, music, links      }
{ ------------------------------------------------------------------ }

{ The photoSize for a preview: the first one at least ASide on its longer
  side (the sizes in photo.sizes go in ascending order), no such one — the
  largest. The file of the chosen size (the photo field); no sizes — nil.
  Works for chatPhoto too — it has the same sizes. }
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

{ The picture of a link preview (linkPreviewType*, td_api.tl at commit
  d1085f9): photo for an article, photo, app, chat and others, thumbnail
  for embedded players, cover for a video. Nothing — nil. }
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

{ A thumbnail preview file (video, GIF, album cover): JPEG — as a picture,
  MPEG4 — as a clip (usually so for a GIF); other formats cannot be shown
  — nil. AKind receives 'img' or 'video'. }
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

{ Addresses from the text: textEntityTypeUrl entities (offset/length in
  UTF-16, the page cuts them: its strings use the same unit) and
  textEntityTypeTextUrl (the address in the entity itself). }
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

{ media.list: the chat's media for the info panel, as in the native
  client — searchChatMessages (td_api.tl at commit d1085f9) with a kind
  filter (filter: photo, video, gif, audio, link, voice, file, pinned),
  newest first; from —
  next_from_message_id of the previous page (0 — from the start). It does
  not touch the history: the model's filter (search.set) stays as it was. }
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
  end else if Kind = 'poll' then begin
    Filter := 'searchMessagesFilterPoll';
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

{ An entry per message: id, date, kind, minithumbnail (a blurred backdrop
  right away), preview (fileId, url if the file is on disk already;
  thumbKind — img or video) and the kind's fields:
    photo — preview: a photoSize from MEDIA_GRID_THUMB_SIDE;
    video, gif — thumbnail (JPEG or MPEG4), duration;
    audio — title, performer, fileName, duration, album cover;
    voice — duration, isListened, sender (sender and avatar, as for gifts:
      GiftSenderName / GiftSenderAvatar);
    file — fileName, size, mime, the document's preview (pictures only);
    pinned — any message: text (a preview, as in the chat list —
      MessagePreview), sender and a picture if there is one (photo — a
      photoSize from MEDIA_LINK_THUMB_SIDE, video, GIF, document — their
      JPEG preview);
    link — text and urls (address entities from the text or caption),
      preview (url, siteName, title, description) and its picture — a
      photoSize from MEDIA_LINK_THUMB_SIDE; no preview — the picture of the
      photo itself.
  Previews not downloaded are downloaded all at once (downloadFile
  synchronous); Held['left'] counts the answers, at zero — the answer to
  the page. }
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
      { A poll — as a line, like a pinned one: "Poll: question" and the author. }
      if (Want = 'pinned') or (Want = 'poll') then begin
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
        { Only a picture in a row. }
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
        { A cover clip in a list row is of no use. }
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
          { A broken backdrop — without it. }
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
  { '-' — did not download: the tile keeps its backdrop. An error answer
    does not name the file, so '-' goes to the first one still waiting. }
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

{ message.translate (id, lang) — translation of the text or caption of a
  message of the open chat on Telegram's side: translateMessageText
  (td_api.tl at commit d1085f9; tone "" — neutral). The answer is a
  formattedText; Telegram keeps formatting only for Premium. To the page —
  text and entities in the same shape as a message's. }
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

{ Without Premium Telegram returns a translation WITHOUT entities (checked
  with a live tdlib_raw.log: "entities":[] with a link in the text) —
  links, mentions and hashtags stopped being links. Then the text goes
  once more through getTextEntities (it finds URLs, e-mail, @mentions,
  #hashtags — td_api.tl at commit d1085f9), and what it finds is put in
  place. A translation with formatting (Premium) stays as is. }
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

{ message.forward (id, toChatId) — forwarding from the open chat:
  forwardMessages (td_api.tl at commit d1085f9) without topic_id and
  options, an ordinary forward (send_copy false), with the caption. }
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

{ The "user" button: the private chat with them (createPrivateChat), to open it. }
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


{ Launching a mini app. source: inline (a button under a message — the bot
  is the message's sender), menu (the bot's menu button in a private chat),
  keyboard (a keyboard button — getWebAppUrl, without launch_id; the app's
  data goes to the bot through sendWebAppData). theme — the page's colours
  under themeParameters names ('#rrggbb'): TDLib gets them as integer RGB,
  and the app itself — in theme_changed under its own names (bg_color and
  so on). Methods and fields — td_api.tl at commit d1085f9 (TDLib 1.8.67). }
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
    { An attachment menu bot (tdattachbots): openWebApp with an empty url. }
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

{ The answer — webAppInfo (launch_id, url: webAppUrl) for openWebApp or a
  bare webAppUrl for getWebAppUrl. The server does not open the window:
  the page gets everything the mini app window needs — in our window it
  hands it to the shell (miniapp.pas), in a browser it opens the address
  in a tab. }
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
  { As strings: int53/int64 without loss in JS. }
  Res.Add('bot', IntToStr(Held.Get('bot', Int64(0))));
  Res.Add('launch', IntToStr(Launch));
  Res.Add('buttonText', Held.Get('buttonText', ''));
  Res.Add('theme', Held.Find('theme').Clone);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ The mini app window's requests to TDLib (the page relays them: the window
  is in another process and perhaps on another machine). Only these four
  methods and only with these fields — not a general passage to TDLib. }
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

{ customRequestResult.result — JSON as a string; the window parses it. }
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

{ Request buttons of a bot keyboard: share users, a chat, one's own
  number. The button's source is the message with the keyboard
  (keyboardButtonSourceMessage, td_api.tl 1.8.67: in this version
  shareUsersWithBot/shareChatWithBot take a source, not
  chat_id/message_id). }
function KeyboardSource(AChatId, AMsgId: Int64): utf8string;
begin
  Result := '{"@type":"keyboardButtonSourceMessage","chat_id":' +
    utf8string(IntToStr(AChatId)) + ',"message_id":' + utf8string(IntToStr(AMsgId)) + '}';
end;

{ A common "done / error" answer for deferred commands without data. }
{ ------------------------------------------------------------------ }
{ video chats (group calls of chats): tdcalls.pas; page —              }
{ ui/videochat.js, calls/group.js                                    }
{ ------------------------------------------------------------------ }

{ groupCall for the page — what the video chat window needs. }
{ The latest speakers (groupCall.recent_speakers) — avatars on the live
  stream bar; no more than VCHAT_BAR_SPEAKERS. }
function SpeakersJson(AList: TJSONArray): TJSONArray;
var
  I: integer;
  Item: TJSONObject;
begin
  Result := TJSONArray.Create;
  if AList = nil then begin
    Exit;
  end;
  for I := 0 to AList.Count - 1 do begin
    if Result.Count >= VCHAT_BAR_SPEAKERS then begin
      Break;
    end;
    if not (AList.Items[I] is TJSONObject) then begin
      Continue;
    end;
    Item := TJSONObject(AList.Items[I]);
    Result.Add(SenderPersonJson(JGetObj(Item, 'participant_id'), 0));
  end;
end;

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
  Result.Add('speakers', SpeakersJson(JGetArr(AGroup, 'recent_speakers')));
end;

{ A participant's video channel: endpoint and SSRC groups (SIM/FID). nil — none. }
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
          { SSRC are unsigned 32 bits, TDLib gives int32: the page turns
            them unsigned (>>> 0). }
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

{ A video chat participant for the page. }
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

{ 'u123' / 'c-100...' -> MessageSender JSON for TDLib requests. }
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

{ vchat.info (chatId): getChat -> video_chat.group_call_id; if there is
  one — getGroupCall. The answer (groupCallId, call or null). }
function TWebApi.CmdVchatInfo(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  { Held marks the slot for AccountSlot. }
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
  Text with the SFU's answer (payload). Right after —
  loadGroupCallParticipants: participants arrive as updates (the
  vchat.participant event). }
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

{ file.ensure (fileId): a file by id — download it (downloadFile
  synchronous) and return the address. For files inside rich messages:
  there are many per message, while media.ensure downloads one — by the
  message's kind. }
function TWebApi.CmdFileEnsure(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Id: integer;
begin
  Result := True;
  Id := integer(AArgs.Get('fileId', 0));
  if Id <= 0 then begin
    raise Exception.Create('file.ensure needs a fileId');
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('downloadFile', '"file_id":' + utf8string(IntToStr(Id))
    + ',"priority":16,"offset":0,"limit":0,"synchronous":true', @FileEnsureDone, Slot);
end;

procedure TWebApi.FileEnsureDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Local: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('url', '');
  Local := JGetObj(AResp.Obj, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    Res.Strings['url'] := string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ rich.full (id): a rich message arrived incomplete (richMessage.is_full
  false) — getFullRichMessage in the open chat -> rich, as in a message. }
function TWebApi.CmdRichFull(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Msgs: TTdMessages;
begin
  Result := True;
  Msgs := RequireMsgs;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  Msgs.Request('getFullRichMessage', '"chat_id":' + utf8string(IntToStr(Msgs.ChatId))
    + ',"message_id":' + utf8string(IntToStr(ArgId(AArgs, 'id'))), @RichFullDone, Slot);
end;

procedure TWebApi.RichFullDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('rich', RichFix(AResp.Obj));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ Stories (ui/stories.js).

  story.list (chatId): getChatActiveStories -> stories: an array (id,
  date) in ascending id order, maxRead — max_read_story_id. }
function TWebApi.CmdStoryList(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getChatActiveStories', '"chat_id":'
    + utf8string(IntToStr(ArgId(AArgs, 'chatId'))), @StoryListDone, Slot);
end;

procedure TWebApi.StoryListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, O, S: TJSONObject;
  Src: TJSONArray;
  Arr: TJSONArray;
  I: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('maxRead', JGetInt(AResp.Obj, 'max_read_story_id'));
  Arr := TJSONArray.Create;
  Src := JGetArr(AResp.Obj, 'stories');
  if Src <> nil then begin
    for I := 0 to Src.Count - 1 do begin
      if not (Src.Items[I] is TJSONObject) then begin
        Continue;
      end;
      S := TJSONObject(Src.Items[I]);
      O := TJSONObject.Create;
      O.Add('id', JGetInt(S, 'story_id'));
      O.Add('date', JGetInt(S, 'date'));
      Arr.Add(O);
    end;
  end;
  Res.Add('stories', Arr);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ story.open (chatId, storyId): getStory -> what to show (photo — the
  largest size, video — the file itself) -> downloadFile synchronous ->
  id, date, kind (photo | video | unsupported), url, thumb (a blurred
  thumbnail), duration, caption. And openStory: that is how TDLib counts
  the story as viewed (max_read_story_id, the ring in the list). }
function TWebApi.CmdStoryOpen(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Ids: utf8string;
begin
  Result := True;
  Ids := '"story_poster_chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId')))
    + ',"story_id":' + utf8string(IntToStr(integer(AArgs.Get('storyId', 0))));
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getStory', Ids + ',"only_local":false', @StoryGetDone, Slot);
  RequireMsgs.Request('openStory', Ids, nil, 0);
end;

procedure TWebApi.StoryGetDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  H, Content, Media, F, Local, Mini, Best: TJSONObject;
  Sizes: TJSONArray;
  Kind: utf8string;
  I: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  H := FDeferred[Slot].Held;
  H.Add('id', JGetInt(AResp.Obj, 'id'));
  H.Add('date', JGetInt(AResp.Obj, 'date'));
  H.Add('caption', string(JGetStr(JGetObj(AResp.Obj, 'caption'), 'text')));
  Content := JGetObj(AResp.Obj, 'content');
  Kind := JGetStr(Content, '@type');
  F := nil;
  Mini := nil;
  if Kind = 'storyContentPhoto' then begin
    Media := JGetObj(Content, 'photo');
    Mini := JGetObj(Media, 'minithumbnail');
    Sizes := JGetArr(Media, 'sizes');
    Best := nil;
    if Sizes <> nil then begin
      for I := 0 to Sizes.Count - 1 do begin
        if (Sizes.Items[I] is TJSONObject) and ((Best = nil)
           or (JGetInt(TJSONObject(Sizes.Items[I]), 'width') > JGetInt(Best, 'width'))) then begin
          Best := TJSONObject(Sizes.Items[I]);
        end;
      end;
    end;
    F := JGetObj(Best, 'photo');
    H.Add('kind', 'photo');
    H.Add('duration', 0);
  end else if Kind = 'storyContentVideo' then begin
    Media := JGetObj(Content, 'video');
    Mini := JGetObj(Media, 'minithumbnail');
    F := JGetObj(Media, 'video');
    H.Add('kind', 'video');
    if Media <> nil then begin
      H.Add('duration', Media.Get('duration', 0.0));
    end else begin
      H.Add('duration', 0);
    end;
  end else begin
    H.Add('kind', 'unsupported');
    H.Add('duration', 0);
  end;
  if (Mini <> nil) and (JGetStr(Mini, 'data') <> '') then begin
    H.Add('thumb', 'data:image/jpeg;base64,' + string(JGetStr(Mini, 'data')));
  end else begin
    H.Add('thumb', '');
  end;
  H.Add('url', '');
  if F = nil then begin
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, H);
    FDeferred[Slot].Held := nil;
    ReleaseDeferred(Slot);
    Exit;
  end;
  Local := JGetObj(F, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    H.Strings['url'] := string(FileUrl(JGetInt(F, 'id'), JGetStr(Local, 'path')));
    Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, H);
    FDeferred[Slot].Held := nil;
    ReleaseDeferred(Slot);
    Exit;
  end;
  RequireMsgs.Request('downloadFile',
    '"file_id":' + utf8string(IntToStr(JGetInt(F, 'id'))) +
    ',"priority":24,"offset":0,"limit":0,"synchronous":true',
    @StoryFileDone, Slot);
end;

procedure TWebApi.StoryFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  H, Local: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  H := FDeferred[Slot].Held;
  Local := JGetObj(AResp.Obj, 'local');
  if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
    H.Strings['url'] := string(FileUrl(JGetInt(AResp.Obj, 'id'), JGetStr(Local, 'path')));
  end;
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, H);
  FDeferred[Slot].Held := nil;
  ReleaseDeferred(Slot);
end;

{ Live stream (a video chat in stream mode — the SFU answers with
  "stream":true — or RTMP): media not over WebRTC but in segments
  (ui/livestream.js).

  vchat.streams (groupCallId): getGroupCallStreams -> streams: an array
  (channelId, scale, timeOffset); timeOffset — where the stream currently
  ends, unix time in ms, as a string (int53). }
function TWebApi.CmdVchatStreams(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
begin
  Result := True;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getGroupCallStreams', '"group_call_id":'
    + utf8string(IntToStr(integer(ArgId(AArgs, 'groupCallId')))),
    @VchatStreamsDone, Slot);
end;

procedure TWebApi.VchatStreamsDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, S, O: TJSONObject;
  Arr: TJSONArray;
  Src: TJSONArray;
  I: integer;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Src := JGetArr(AResp.Obj, 'streams');
  if Src <> nil then begin
    for I := 0 to Src.Count - 1 do begin
      if not (Src.Items[I] is TJSONObject) then begin
        Continue;
      end;
      S := TJSONObject(Src.Items[I]);
      O := TJSONObject.Create;
      O.Add('channelId', JGetInt(S, 'channel_id'));
      O.Add('scale', JGetInt(S, 'scale'));
      O.Add('timeOffset', IntToStr(JGetInt64(S, 'time_offset')));
      Arr.Add(O);
    end;
  end;
  Res.Add('streams', Arr);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ vchat.segment (groupCallId, timeOffset, scale, channelId, quality):
  getGroupCallStreamSegment -> data (base64, as TDLib gives bytes).
  quality: thumbnail | medium | full | '' (the worst available).
  channelId 0 and quality '' — audio (OGG), otherwise video (MPEG-4); both
  have their own tgcalls header in front. }
function TWebApi.CmdVchatSegment(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Slot: PtrInt;
  Quality, Q: utf8string;
begin
  Result := True;
  Quality := utf8string(AArgs.Get('quality', ''));
  if Quality = 'thumbnail' then begin
    Q := '{"@type":"groupCallVideoQualityThumbnail"}';
  end else if Quality = 'medium' then begin
    Q := '{"@type":"groupCallVideoQualityMedium"}';
  end else if Quality = 'full' then begin
    Q := '{"@type":"groupCallVideoQualityFull"}';
  end else begin
    Q := 'null';
  end;
  Slot := TakeDeferred(AConnId, AReqId, 0);
  FDeferred[Slot].Held := TJSONObject.Create;
  RequireMsgs.Request('getGroupCallStreamSegment', '"group_call_id":'
    + utf8string(IntToStr(integer(ArgId(AArgs, 'groupCallId'))))
    + ',"time_offset":' + utf8string(IntToStr(StrToInt64Def(string(AArgs.Get('timeOffset', '0')), 0)))
    + ',"scale":' + utf8string(IntToStr(integer(AArgs.Get('scale', 0))))
    + ',"channel_id":' + utf8string(IntToStr(integer(AArgs.Get('channelId', 0))))
    + ',"video_quality":' + Q,
    @VchatSegmentDone, Slot);
end;

procedure TWebApi.VchatSegmentDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res: TJSONObject;
begin
  if not AccountSlot(AResp, Slot) then begin
    Exit;
  end;
  Res := TJSONObject.Create;
  Res.Add('data', string(JGetStr(AResp.Obj, 'data')));
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ vchat.participants (groupCallId): the participants the model knows — for
  a page opened in the middle of a video chat. }
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

{ Simple video chat commands — the answer is (ok), or (groupCallId) for create:
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

{ ------------------------------------------------------------------ }
{ sponsored messages (ads.*)                                            }
{ ------------------------------------------------------------------ }

{ Telegram's official ads in channels and chats with bots — a requirement
  of the Telegram API ToS 3.3 for any client that shows channels
  (core.telegram.org/api/sponsored-messages). Schema — td_api.tl of TDLib
  1.8.67:
    getChatSponsoredMessages chat_id = SponsoredMessages
      (messages:vector of sponsoredMessage, messages_between)
    sponsoredMessage message_id is_recommended can_be_reported content
      sponsor:advertisementSponsor (url photo info) title button_text
      accent_color_id background_custom_emoji_id additional_info
    viewMessages chat_id message_ids source force_read
    clickChatSponsoredMessage chat_id message_id is_media_click from_fullscreen
    reportChatSponsoredMessage chat_id message_id option_id:bytes
      = reportSponsoredResultOk / Failed / OptionRequired (title, options)
        / AdsHidden / PremiumRequired
  Content — messageText/Photo/Video/Animation, and it may only be shown
  fully downloaded: the files are downloaded here, before the answer to the
  page, one by one (downloadFile synchronous), like the greeting sticker.

  TDLib's answer is kept in FAds per chat for SPONSORED_CACHE_MS — already
  with the paths of the downloaded files (PatchFileLocal), so opening the
  channel again answers at once. The message row for the page is the same
  MsgToJson as the history's, over a row OUTSIDE the model
  (TTdMessages.DetachedRow). }

{ Replaces local in every file with this id inside the node (there may be
  several: one file can be both the preview and the original). }
procedure PatchFileLocal(ANode: TJSONData; AFileId: integer; ALocal: TJSONObject);
var
  I: integer;
  O: TJSONObject;
begin
  if (ANode = nil) or (ALocal = nil) then begin
    Exit;
  end;
  if ANode is TJSONObject then begin
    O := TJSONObject(ANode);
    if (JGetStr(O, '@type') = 'file') and (JGetInt(O, 'id') = AFileId) then begin
      O.Delete('local');
      O.Add('local', ALocal.Clone);
      Exit;
    end;
    for I := 0 to O.Count - 1 do begin
      PatchFileLocal(O.Items[I], AFileId, ALocal);
    end;
  end else if ANode is TJSONArray then begin
    for I := 0 to TJSONArray(ANode).Count - 1 do begin
      PatchFileLocal(TJSONArray(ANode).Items[I], AFileId, ALocal);
    end;
  end;
end;

{ A file on disk: "downloaded" and the path exists (the same rule as
  tdmessages.CompletedLocal — after a cache clean-up TDLib still calls the
  file downloaded). }
function AdLocalOk(ALocal: TJSONObject): boolean;
begin
  Result := (ALocal <> nil) and JGetBool(ALocal, 'is_downloading_completed')
    and (JGetStr(ALocal, 'path') <> '') and FileExists(string(JGetStr(ALocal, 'path')));
end;

{ A file the ad cannot be shown without and that is not on disk yet; 0 —
  everything in place. ATried — already requested (a failed download does
  not loop: such an ad is simply not shown). }
function AdTried(ATried: TJSONArray; AFileId: integer): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to ATried.Count - 1 do begin
    if ATried.Integers[I] = AFileId then begin
      Exit(True);
    end;
  end;
end;

function AdMissingFile(ARow: TMsgRow; ATried: TJSONArray): integer;

  function Need(AFileId: integer; const APath: utf8string): boolean;
  begin
    Result := (AFileId <> 0) and (APath = '') and not AdTried(ATried, AFileId);
  end;

begin
  Result := 0;
  case ARow.Kind of
    mckPhoto:
      if Need(ARow.PhotoFileId, ARow.PhotoLocalPath) then begin
        Result := ARow.PhotoFileId;
      end else if Need(ARow.PhotoBestFileId, ARow.PhotoBestLocalPath) then begin
        Result := ARow.PhotoBestFileId;
      end;
    mckAnimation:
      if Need(ARow.AnimFileId, ARow.AnimLocalPath) then begin
        Result := ARow.AnimFileId;
      end;
    mckVideo:
      if Need(ARow.VideoThumbFileId, ARow.VideoThumbLocalPath) then begin
        Result := ARow.VideoThumbFileId;
      end else if Need(ARow.VideoFileId, ARow.VideoLocalPath) then begin
        Result := ARow.VideoFileId;
      end;
  end;
end;

{ Whether everything of the ad is downloaded: without it the ad is not shown at all. }
function AdComplete(ARow: TMsgRow): boolean;
begin
  case ARow.Kind of
    mckText:
      Result := True;
    mckPhoto:
      Result := (ARow.PhotoLocalPath <> '')
        and ((ARow.PhotoBestFileId = 0) or (ARow.PhotoBestLocalPath <> ''));
    mckAnimation:
      Result := ARow.AnimLocalPath <> '';
    mckVideo:
      Result := ARow.VideoLocalPath <> '';
  else
    { The schema promises no other kinds — and there is nothing to draw them with here. }
    Result := False;
  end;
end;

{ The smallest copy of the sponsor's photo (sizes ascending) — its avatar.
  nil if there is no photo. }
function SponsorPhotoFile(AAd: TJSONObject): TJSONObject;
var
  Sizes: TJSONArray;
begin
  Result := nil;
  Sizes := JGetArr(JGetObj(JGetObj(AAd, 'sponsor'), 'photo'), 'sizes');
  if (Sizes <> nil) and (Sizes.Count > 0) and (Sizes.Items[0] is TJSONObject) then begin
    Result := JGetObj(TJSONObject(Sizes.Items[0]), 'photo');
  end;
end;

{ The chat kind for ads: channel and bot — where they occur; otherwise ''. }
function AdsChatKind(AChatId: Int64): utf8string;
var
  CRow: TChatRow;
begin
  Result := '';
  if TdChatList = nil then begin
    Exit;
  end;
  CRow := TdChatList.Lookup(AChatId);
  if CRow <> nil then begin
    Result := ChatKindStr(TdChatList, CRow);
  end;
  if (Result <> 'channel') and (Result <> 'bot') then begin
    Result := '';
  end;
end;

{ The answer to the page from the (already downloaded) sponsoredMessages.
  kind — where to show it: channel — after the posts, bot — as a strip
  above the input field. }
function AdsToJson(AMsgs: TTdMessages; AChatId: Int64; ARaw: TJSONObject): TJSONObject;
var
  Arr: TJSONArray;
  Items: TJSONArray;
  Emoji, Ad, Item, Sponsor, PhotoFile, Local: TJSONObject;
  Row: TMsgRow;
  I: integer;
begin
  Items := TJSONArray.Create;
  Emoji := TJSONObject.Create;
  Arr := JGetArr(ARaw, 'messages');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Ad := TJSONObject(Arr.Items[I]);
      Row := AMsgs.DetachedRow(AChatId, JGetInt64(Ad, 'message_id'), JGetObj(Ad, 'content'));
      try
        if not AdComplete(Row) then begin
          Continue;
        end;
        AMsgs.EnsureCustomEmojiForRow(Row);
        CollectMsgCustomEmoji(Emoji, Row);
        Sponsor := JGetObj(Ad, 'sponsor');
        Item := TJSONObject.Create;
        Item.Add('id', Row.Id);
        Item.Add('chatId', AChatId);
        Item.Add('recommended', JGetBool(Ad, 'is_recommended'));
        Item.Add('canReport', JGetBool(Ad, 'can_be_reported'));
        Item.Add('title', string(JGetStr(Ad, 'title')));
        Item.Add('buttonText', string(JGetStr(Ad, 'button_text')));
        Item.Add('color', string(AccentKeyFor(JGetInt(Ad, 'accent_color_id'), AChatId)));
        Item.Add('url', string(JGetStr(Sponsor, 'url')));
        Item.Add('sponsorInfo', string(JGetStr(Sponsor, 'info')));
        Item.Add('additionalInfo', string(JGetStr(Ad, 'additional_info')));
        Item.Add('avatar', '');
        PhotoFile := SponsorPhotoFile(Ad);
        Local := JGetObj(PhotoFile, 'local');
        if (Local <> nil) and AdLocalOk(Local) then begin
          Item.Strings['avatar'] := string(FileUrl(JGetInt(PhotoFile, 'id'), JGetStr(Local, 'path')));
        end;
        Item.Add('msg', MsgToJson(AMsgs, Row, 0));
        Items.Add(Item);
      finally
        Row.Free;
      end;
    end;
  end;
  Result := TJSONObject.Create;
  Result.Add('chatId', AChatId);
  Result.Add('kind', string(AdsChatKind(AChatId)));
  Result.Add('between', JGetInt(ARaw, 'messages_between'));
  Result.Add('items', Items);
  Result.Add('customEmoji', Emoji);
end;

function TWebApi.CmdAdsGet(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
var
  Msgs: TTdMessages;
  ChatId: Int64;
  Idx: integer;
  Entry: TAdsEntry;
  Slot: PtrInt;
  Empty: TJSONObject;
begin
  Result := True;
  Msgs := RequireMsgs;
  ChatId := ArgId(AArgs, 'chatId');
  { Only channels and chats with bots — TDLib gives no ads in the others. }
  if (ChatId = 0) or (AdsChatKind(ChatId) = '') then begin
    Empty := TJSONObject.Create;
    Empty.Add('chatId', ChatId);
    Empty.Add('kind', '');
    Empty.Add('between', 0);
    Empty.Add('items', TJSONArray.Create);
    Reply(AConnId, AReqId, Empty);
    Exit;
  end;
  Idx := FAds.IndexOf(IntToStr(ChatId));
  if Idx >= 0 then begin
    Entry := TAdsEntry(FAds.Objects[Idx]);
    if GetTickCount64 - Entry.Fetched < SPONSORED_CACHE_MS then begin
      Reply(AConnId, AReqId, AdsToJson(Msgs, ChatId, Entry.Raw));
      Exit;
    end;
    FAds.Delete(Idx);
  end;
  { The slot's MessageId is the chat id: it is needed at the end of the chain too. }
  Slot := TakeDeferred(AConnId, AReqId, ChatId);
  FDeferred[Slot].Held := TJSONObject.Create;
  FDeferred[Slot].Held.Add('tried', TJSONArray.Create);
  Msgs.Request('getChatSponsoredMessages', '"chat_id":' + utf8string(IntToStr(ChatId)),
    @AdsListDone, Slot);
end;

procedure TWebApi.AdsListDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Raw: TJSONObject;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  { A refusal (ads are not due in this chat, no network) is not an error
    for the page but an empty list; it is cached the same way, so every
    opening does not ask again. }
  if AResp.Success and (AResp.Obj <> nil) then begin
    Raw := TJSONObject(AResp.Obj.Clone);
  end else begin
    Raw := TJSONObject.Create;
    Raw.Add('messages', TJSONArray.Create);
    Raw.Add('messages_between', 0);
  end;
  FDeferred[Slot].Held.Add('raw', Raw);
  AdsNext(Slot);
end;

procedure TWebApi.AdsFileDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
begin
  Slot := AResp.Tag;
  if (Slot < 0) or (Slot > High(FDeferred)) or (not FDeferred[Slot].Busy)
     or (FDeferred[Slot].Held = nil) then begin
    Exit;
  end;
  if AResp.Success and (AResp.Obj <> nil)
     and AdLocalOk(JGetObj(AResp.Obj, 'local')) then begin
    PatchFileLocal(FDeferred[Slot].Held.Find('raw'), JGetInt(AResp.Obj, 'id'),
      JGetObj(AResp.Obj, 'local'));
  end;
  AdsNext(Slot);
end;

{ The next missing file — or, when there is nothing left to download, the
  answer and the cache entry. }
procedure TWebApi.AdsNext(ASlot: PtrInt);
var
  Msgs: TTdMessages;
  Raw, Ad, PhotoFile: TJSONObject;
  Tried, Arr: TJSONArray;
  ChatId: Int64;
  Row: TMsgRow;
  FileId, I: integer;
  Entry: TAdsEntry;
begin
  try
    Msgs := RequireMsgs;
    Raw := TJSONObject(FDeferred[ASlot].Held.Find('raw'));
    Tried := TJSONArray(FDeferred[ASlot].Held.Find('tried'));
    ChatId := FDeferred[ASlot].MessageId;
    Arr := JGetArr(Raw, 'messages');
    FileId := 0;
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if not (Arr.Items[I] is TJSONObject) then begin
          Continue;
        end;
        Ad := TJSONObject(Arr.Items[I]);
        Row := Msgs.DetachedRow(ChatId, JGetInt64(Ad, 'message_id'), JGetObj(Ad, 'content'));
        try
          FileId := AdMissingFile(Row, Tried);
        finally
          Row.Free;
        end;
        { The sponsor's avatar — not required, but since we are downloading anyway. }
        if FileId = 0 then begin
          PhotoFile := SponsorPhotoFile(Ad);
          if (PhotoFile <> nil) and not AdLocalOk(JGetObj(PhotoFile, 'local'))
             and not AdTried(Tried, JGetInt(PhotoFile, 'id')) then begin
            FileId := JGetInt(PhotoFile, 'id');
          end;
        end;
        if FileId <> 0 then begin
          Break;
        end;
      end;
    end;
    if FileId <> 0 then begin
      Tried.Add(FileId);
      Msgs.Request('downloadFile',
        '"file_id":' + utf8string(IntToStr(FileId)) +
        ',"priority":' + utf8string(IntToStr(SPONSORED_DOWNLOAD_PRIORITY)) +
        ',"offset":0,"limit":0,"synchronous":true',
        @AdsFileDone, ASlot);
      Exit;
    end;
    Entry := TAdsEntry.Create;
    Entry.Fetched := GetTickCount64;
    Entry.Raw := TJSONObject(FDeferred[ASlot].Held.Extract('raw'));
    FAds.AddObject(IntToStr(ChatId), Entry);
    Reply(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, AdsToJson(Msgs, ChatId, Entry.Raw));
    ReleaseDeferred(ASlot);
  except
    on E: Exception do begin
      Fail(FDeferred[ASlot].ConnId, FDeferred[ASlot].ReqId, utf8string(E.Message));
      ReleaseDeferred(ASlot);
    end;
  end;
end;

{ A view: the whole ad text is on screen (the page decides). viewMessages
  with the ad message's id — so in td_api.tl, there is no separate method. }
function TWebApi.CmdAdsView(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
begin
  Result := True;
  RequireMsgs.Request('viewMessages',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))) +
    ',"message_ids":[' + utf8string(IntToStr(ArgId(AArgs, 'id'))) + ']' +
    ',"force_read":false',
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ A click on an ad (button, title, media). The page opens the link. }
function TWebApi.CmdAdsClick(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
begin
  Result := True;
  if AArgs = nil then begin
    raise Exception.Create('ads.click needs a chat and a message');
  end;
  RequireMsgs.Request('clickChatSponsoredMessage',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))) +
    ',"message_id":' + utf8string(IntToStr(ArgId(AArgs, 'id'))) +
    ',"is_media_click":' + BoolJson(AArgs.Get('media', False)) +
    ',"from_fullscreen":' + BoolJson(AArgs.Get('fullscreen', False)),
    @SimpleDone, TakeDeferred(AConnId, AReqId, 0));
end;

{ A report: the first request — with an empty option_id; then the page
  sends the chosen option (id — base64, as TDLib gave it). }
function TWebApi.CmdAdsReport(AConnId: Int64; AReqId: integer; AArgs: TJSONObject): boolean;
begin
  Result := True;
  if AArgs = nil then begin
    raise Exception.Create('ads.report needs a chat and a message');
  end;
  RequireMsgs.Request('reportChatSponsoredMessage',
    '"chat_id":' + utf8string(IntToStr(ArgId(AArgs, 'chatId'))) +
    ',"message_id":' + utf8string(IntToStr(ArgId(AArgs, 'id'))) +
    ',"option_id":' + JsonStr(utf8string(AArgs.Get('option', ''))),
    @AdsReportDone, TakeDeferred(AConnId, AReqId, ArgId(AArgs, 'chatId')));
end;

procedure TWebApi.AdsReportDone(Sender: TObject; const AResp: TTdResponse);
var
  Slot: PtrInt;
  Res, Opt: TJSONObject;
  Opts, Arr: TJSONArray;
  T: utf8string;
  I, Idx: integer;
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
  if T = 'reportSponsoredResultOk' then begin
    Res.Add('result', 'ok');
  end else if T = 'reportSponsoredResultOptionRequired' then begin
    Res.Add('result', 'options');
    Res.Add('title', string(JGetStr(AResp.Obj, 'title')));
    Opts := TJSONArray.Create;
    Arr := JGetArr(AResp.Obj, 'options');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if Arr.Items[I] is TJSONObject then begin
          Opt := TJSONObject.Create;
          Opt.Add('id', string(JGetStr(TJSONObject(Arr.Items[I]), 'id')));
          Opt.Add('text', string(JGetStr(TJSONObject(Arr.Items[I]), 'text')));
          Opts.Add(Opt);
        end;
      end;
    end;
    Res.Add('options', Opts);
  end else if T = 'reportSponsoredResultAdsHidden' then begin
    Res.Add('result', 'hidden');
  end else if T = 'reportSponsoredResultPremiumRequired' then begin
    Res.Add('result', 'premium');
  end else begin
    Res.Add('result', 'failed');
  end;
  { Reported or hid the ads — the chat's cache is no longer valid. }
  if (T = 'reportSponsoredResultOk') or (T = 'reportSponsoredResultAdsHidden') then begin
    Idx := FAds.IndexOf(IntToStr(FDeferred[Slot].MessageId));
    if Idx >= 0 then begin
      FAds.Delete(Idx);
    end;
    if T = 'reportSponsoredResultAdsHidden' then begin
      FAds.Clear;
    end;
  end;
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

{ "Share my number": as in Telegram clients — one's own contact as a
  message in the chat with the bot. First getMe (number and name), then
  sendMessage with inputMessageContact. }
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

{ An inline query result for the page: id, kind, title, description.
  Fields — per td_api.tl (inlineQueryResult*). No pictures yet: a text
  list, as in the native client for articles. }
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
  { inlineQueryResultArticle -> article and so on. }
  Result.Add('kind', LowerCase(Copy(string(T), Length('inlineQueryResult') + 1, MaxInt)));
  Result.Add('title', string(Title));
  Result.Add('description', string(Desc));
end;

{ Bot name -> id: searchPublicChat, for a private chat the chat id = the
  user id. Cached — so it is not looked up again on every typed letter. }
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
  { inline_query_id — int64, a string in TDLib; a string for the page too. }
  Res.Add('queryId', string(JGetStr(AResp.Obj, 'inline_query_id')));
  if Res.Get('queryId', '') = '' then begin
    Res.Strings['queryId'] := IntToStr(JGetInt64(AResp.Obj, 'inline_query_id'));
  end;
  Res.Add('nextOffset', string(JGetStr(AResp.Obj, 'next_offset')));
  Res.Add('results', Items);
  Reply(FDeferred[Slot].ConnId, FDeferred[Slot].ReqId, Res);
  ReleaseDeferred(Slot);
end;

{ The chosen result — into the open chat (sendInlineQueryResultMessage,
  the ready TTdMessages.SendInlineResult). }
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
  if AArgs.Find('entities', jtArray) <> nil then begin
    RequireMsgs.SendFormattedJson(FormattedFromArgs(AArgs), False, 0, Id);
    Exit(nil);
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
  Sched: TTdMessages;
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

    { Scheduled sending (ui/schedule.js): schedule of message.send* — a
      unix date or -1 ("when they come online"). Set on the model for this
      one command: all its sendMessage requests are built synchronously
      inside it. }
    Sched := TdMsgList;
    if Sched <> nil then begin
      if (Copy(Cmd, 1, 12) = 'message.send') and (Args <> nil) then begin
        Sched.ScheduleAt := Args.Get('schedule', Int64(0));
      end else begin
        Sched.ScheduleAt := 0;
      end;
    end;

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
      { Accounts — before the models: cancelling an add and signing out
        work even when the active account has not signed in yet. }
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
      end else if Cmd = 'chats.rows' then begin
        Reply(AConnId, ReqId, CmdChatsRows(Args));
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
      end else if Cmd = 'chat.typing' then begin
        Reply(AConnId, ReqId, CmdChatTyping(Args));
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
      end else if Cmd = 'message.sendRich' then begin
        Reply(AConnId, ReqId, CmdMessageSendRich(Args));
      end else if Cmd = 'message.sendNote' then begin
        Reply(AConnId, ReqId, CmdMessageSendNote(Args));
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
      end else if Cmd = 'chat.dateJump' then begin
        CmdChatDateJump(AConnId, ReqId, Args);
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
      end else if Cmd = 'bot.tmpPasswordState' then begin
        CmdBotTmpPasswordState(AConnId, ReqId);
      end else if Cmd = 'bot.pay' then begin
        CmdBotPay(AConnId, ReqId, Args);
      end else if Cmd = 'bot.sendLocation' then begin
        CmdBotSendLocation(AConnId, ReqId, Args);
      end else if Cmd = 'bot.sendPoll' then begin
        CmdBotSendPoll(AConnId, ReqId, Args);
      end else if Cmd = 'bot.createBot' then begin
        CmdBotCreateBot(AConnId, ReqId, Args);
      { The paperclip menu: poll and location — the same commands as the
        bot buttons (into the open chat), plus checklist and article. }
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
      end else if Cmd = 'search.home' then begin
        CmdSearchHome(AConnId, ReqId, Args);
      end else if Cmd = 'search.query' then begin
        CmdSearchQuery(AConnId, ReqId, Args);
      end else if Cmd = 'admin' then begin
        CmdAdmin(AConnId, ReqId, Args);
      end else if Cmd = 'td.kept' then begin
        Reply(AConnId, ReqId, CmdTdKept(Args));
      end else if Cmd = 'users.cards' then begin
        CmdUsersCards(AConnId, ReqId, Args);
      end else if Cmd = 'chat.similar' then begin
        CmdChatSimilar(AConnId, ReqId, Args);
      end else if Cmd = 'chat.similarOpened' then begin
        CmdChatSimilarOpened(AConnId, ReqId, Args);
      end else if Cmd = 'search.recent' then begin
        CmdSearchRecent(AConnId, ReqId, Args);
      end else if Cmd = 'search.messages' then begin
        CmdSearchMessages(AConnId, ReqId, Args);
      end else if Cmd = 'search.postLimits' then begin
        CmdSearchPostLimits(AConnId, ReqId, Args);
      end else if Cmd = 'search.posts' then begin
        CmdSearchPosts(AConnId, ReqId, Args);
      end else if Cmd = 'mention.search' then begin
        CmdMentionSearch(AConnId, ReqId, Args);
      end else if Cmd = 'contacts.list' then begin
        CmdContactsList(AConnId, ReqId);
      end else if Cmd = 'message.transcribe' then begin
        { recognizeSpeech (chat_id, message_id) — of the open chat (in a
          thread it is the discussion group, as for the other message
          commands). The answer is (ok); the text arrives as a message
          update. }
        if TdMsgList = nil then begin
          raise Exception.Create('no chat open');
        end;
        TdMsgList.Request('recognizeSpeech', '"chat_id":'
          + utf8string(IntToStr(TdMsgList.ChatId)) + ',"message_id":'
          + utf8string(IntToStr(ArgId(Args, 'id'))),
          @SimpleDone, TakeDeferred(AConnId, ReqId, 0));
      end else if Cmd = 'call.list' then begin
        Reply(AConnId, ReqId, CmdCallList);
      end else if Cmd = 'relay.get' then begin
        Reply(AConnId, ReqId, RelayJson);
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
      end else if Cmd = 'file.ensure' then begin
        CmdFileEnsure(AConnId, ReqId, Args);
      end else if Cmd = 'rich.full' then begin
        CmdRichFull(AConnId, ReqId, Args);
      end else if Cmd = 'story.list' then begin
        CmdStoryList(AConnId, ReqId, Args);
      end else if Cmd = 'story.open' then begin
        CmdStoryOpen(AConnId, ReqId, Args);
      end else if Cmd = 'story.close' then begin
        { Viewing is over (td_api.tl: closeStory) — no answer from TDLib. }
        RequireMsgs.Request('closeStory', '"story_poster_chat_id":'
          + utf8string(IntToStr(ArgId(Args, 'chatId'))) + ',"story_id":'
          + utf8string(IntToStr(integer(Args.Get('storyId', 0)))), nil, 0);
        Reply(AConnId, ReqId, nil);
      end else if Cmd = 'vchat.streams' then begin
        CmdVchatStreams(AConnId, ReqId, Args);
      end else if Cmd = 'vchat.segment' then begin
        CmdVchatSegment(AConnId, ReqId, Args);
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
      { Ads in channels and chats with bots — see "sponsored messages". }
      end else if Cmd = 'ads.get' then begin
        CmdAdsGet(AConnId, ReqId, Args);
      end else if Cmd = 'ads.view' then begin
        CmdAdsView(AConnId, ReqId, Args);
      end else if Cmd = 'ads.click' then begin
        CmdAdsClick(AConnId, ReqId, Args);
      end else if Cmd = 'ads.report' then begin
        CmdAdsReport(AConnId, ReqId, Args);
      end else if Cmd = 'ads.enabled' then begin
        { Premium only: without it ads are always on. }
        FAds.Clear;
        RequireMsgs.Request('toggleHasSponsoredMessagesEnabled',
          '"has_sponsored_messages_enabled":' + BoolJson((Args <> nil) and Args.Get('enabled', False)),
          @SimpleDone, TakeDeferred(AConnId, ReqId, 0));
      end else begin
        Fail(AConnId, ReqId, 'unknown command: ' + Cmd);
      end;
    except
      on E: Exception do begin
        if E.ClassType = Exception then begin
          Fail(AConnId, ReqId, utf8string(E.Message));
        end else begin
          { A crash, not a refusal: into the log and with the command's
            name — a lone "Access violation" in a toast does not say what
            broke. }
          LogCommandCrash(Cmd, Args, E);
          Fail(AConnId, ReqId, Cmd + ': ' + utf8string(E.Message));
        end;
      end;
    end;
  finally
    if TdMsgList <> nil then begin
      TdMsgList.ScheduleAt := 0;
    end;
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
