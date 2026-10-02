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
  Classes, SysUtils, SyncObjs, ExtCtrls, base64, fgl, fpjson, jsonparser,
  constants, Graphics, tdreq, tdauth, tdchats, tdmessages,
  tdusers, tdstickers, tdcore, tdrecv, webauth, qrrender, localserver, webfiles,
  autodownload, customemoji, webui, tdstorage;

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

  TWebApi = class
  private
    FTimer: TTimer;
    FLock:  SyncObjs.TCriticalSection;
    FQueue: TFPList;
    { The model objects this instance is currently subscribed to. They
      belong to the active account and are replaced when the account
      changes, so they are re-checked on every tick rather than bound
      once at start-up (at start-up there may be no account at all). }
    FBoundChats: TTdChats;
    FBoundMsgs:  TTdMessages;
    FBoundStickers: TTdStickers;
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
    procedure Tick(Sender: TObject);
    procedure Drain;
    procedure EnsureBindings;
    procedure DropBindings;
    procedure ChatsChanged(Sender: TObject);
    procedure ChatArrived(Sender: TObject; ARow: TChatRow;
      const APreview: utf8string);
    procedure MessagesChanged(Sender: TObject);
    procedure StickersChanged(Sender: TObject);
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
    (tg.lpr), so both types carry the same code page and no transcoding
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

function MsgToJson(AMsgs: TTdMessages; ARow: TMsgRow; ALastReadOutbox: Int64): TJSONObject;
var
  Name, Color, PreviewText: utf8string;
  RUser, RChat: Int64;
  Sub: TJSONObject;
  Media: TJSONObject;
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
  Result.Add('text',     string(ARow.PlainText));
  Result.Add('entities', EntitiesJson(ARow.Entities));
  Result.Add('receipt',  string(ReceiptStr(MessageReceipt(ARow, ALastReadOutbox))));

  ResolveSubject(ARow.SenderUserId, ARow.SenderChatId, Name, Color);
  Result.Add('senderId',    ARow.SenderUserId + ARow.SenderChatId);
  Result.Add('senderName',  string(Name));
  Result.Add('senderColor', string(Color));

  { A reply quote. ReplyPreview answers False when the quoted message
    is not loaded yet — it starts a getRepliedMessage of its own and
    the answer arrives through the ordinary change signal, so sending
    the ids alone now and the text later is correct rather than lossy. }
  if ARow.ReplyMessageId <> 0 then begin
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
end;

{ ------------------------------------------------------------------ }
{ TWebApi                                                            }
{ ------------------------------------------------------------------ }

constructor TWebApi.Create;
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FQueue := TFPList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := WEBAPI_FALLBACK_TICK_MS;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := True;
  FAuth := TWebAuth.Create(nil);
  FAuth.OnChanged := @AuthChanged;
  FSnaps := TConnSnapMap.Create;
  FSnaps.Sorted := True;
end;

destructor TWebApi.Destroy;
var
  I: integer;
begin
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
  messages and muted chats; what is left is WHERE to say so.

  Two places, and the window decides which. While the web window is the
  one on screen, the page draws its own card - that is the half that
  looks like a real client, with the chat's picture on it and a click
  that opens the chat. When the window is in the tray, minimised or
  simply behind something else, the page would be talking to nobody, so
  it goes to the tray icon and becomes a Windows notification instead.

  Both are sent for the SAME arrival, never neither: a page open in an
  ordinary browser is not this window, and it is told either way - it
  decides for itself whether it is visible (see ui/toasts.js). }
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
  PushEvent('arrival', Data);

  if not WebUiIsShowing then begin
    WebUiNotify(ARow.Title, APreview);
  end;
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
  Chats: TTdChats;
  CRow: TChatRow;
  Arr: TJSONArray;
  Res, Emoji, Sub: TJSONObject;
  I: integer;
  LastReadOutbox: Int64;
  MustJoin, ByRequest: boolean;
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
  Res, Downloads, Cache, AutoDl, Item: TJSONObject;
  Media, Chats, OnList: TJSONArray;
  M, C: integer;
begin
  Res := TJSONObject.Create;
  Res.Add('closeToTray', TdCloseToTray);
  Res.Add('deviceModel', TdApp.DeviceModel);

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
  Key, Model: utf8string;
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
  Msgs.SendFiles(Paths, AArgs.Get('asPhoto', False),
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

  The renderer is the one the native window uses (qrrender.pas, on
  QRCodeGenLib) - the alternative was a second QR implementation in
  JavaScript, vendored and maintained, to draw the same square from
  the same string. A data URI rather than a URL because it is tiny,
  it changes with every link, and there is nothing to cache. }
function QrDataUri(const ALink: utf8string): utf8string;
var
  Bmp: TBitmap;
  Png: TPortableNetworkGraphic;
  Stream: TMemoryStream;
  Raw: RawByteString;
begin
  Result := '';
  if ALink = '' then begin
    Exit;
  end;
  Bmp := TBitmap.Create;
  Stream := TMemoryStream.Create;
  { The LCL's own PNG graphic rather than a raw FPImage writer: it
    takes the bitmap by Assign and knows how to write itself, which is
    the whole conversion. }
  Png := TPortableNetworkGraphic.Create;
  try
    if DrawQrToBitmap(ALink, Bmp, 320) = 0 then begin
      Exit;
    end;
    Png.Assign(Bmp);
    Png.SaveToStream(Stream);
    SetLength(Raw, Stream.Size);
    Stream.Position := 0;
    if Stream.Size > 0 then begin
      Stream.ReadBuffer(Raw[1], Stream.Size);
    end;
    Result := 'data:image/png;base64,' +
      utf8string(EncodeStringBase64(string(Raw)));
  finally
    Png.Free;
    Stream.Free;
    Bmp.Free;
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
      end else if Cmd = 'message.link' then begin
        CmdMessageLink(AConnId, ReqId, Args);
      end else if Cmd = 'message.people' then begin
        { Answers later, from the TDLib callback - see TDeferredReply. }
        CmdMessagePeople(AConnId, ReqId, Args);
      end else if Cmd = 'link.resolve' then begin
        CmdLinkResolve(AConnId, ReqId, Args);
      end else if Cmd = 'link.join' then begin
        CmdLinkJoin(AConnId, ReqId, Args);
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
