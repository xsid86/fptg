unit tdchats;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, base64, customemoji, fgl, ExtCtrls, fpjson, jsonparser,
  constants, tdauth, tdsession, tdreq;

type
  TChatKind = (ckUnknown, ckPrivate, ckBasicGroup, ckSupergroup, ckChannel, ckSecret);

  { Sending state of the last message. }
  TMsgSendState = (mssDelivered, mssPending, mssFailed);

  { What to show to the right of the time. Outgoing messages only. }
  TChatReceipt = (crNone, crPending, crFailed, crSent, crRead);

  { A custom (Premium) emoji entity's span within LastText — deliberately
    NOT tdmessages.TMsgEntity/emojiassets.TCustomGlyphSpan (same 3
    fields, different unit): TChatRow is plain data with no reference to
    LCL at all (see its own comment below), and emojiassets.pas pulls in
    Graphics/BGRABitmap; tdmessages.pas can't be used here either (it
    already uses tdchats — a reverse dependency would cycle). framechats.pas
    (which needs both this and emojiassets.TCustomGlyphSpanArray) does
    the trivial element-by-element conversion right before calling
    DrawEmojiLine. }
  TPreviewGlyph = record
    ByteStart, ByteLen: integer;
    CustomEmojiId: Int64;
  end;
  TPreviewGlyphArray = array of TPreviewGlyph;

  { A chat folder (chatListFolder), as announced by updateChatFolders.

    Only the two fields the chat list actually shows: TDLib's
    chatFolderInfo also carries an icon name, a color id and sharing
    flags, none of which the folder button on a row uses. Title comes
    from name.text.text — chatFolderName is a formattedText whose
    entities may only be custom emoji (per the schema), and those are
    not rendered on the button either. }
  TChatFolder = record
    Id:    integer;
    Title: utf8string;
  end;
  TChatFolderArray = array of TChatFolder;

  { Context for one in-flight getChatFolder -> editChatFolder pair, see
    RemoveChatFromFolder. TTdRequests carries exactly one PtrInt Tag
    through a request (tdreq.pas, no anonymous functions in FPC 3.2),
    so the TWO values that pair needs live in a slot here and the slot
    INDEX is what rides along as the tag. Slots are reused rather than
    appended forever: ChatId = 0 means free. }
  TFolderOp = record
    FolderId: integer;
    ChatId:   Int64;
  end;

  { TChatRow

    Plain data, with no reference to LCL at all. The mini-thumbnail is
    stored as raw JPEG bytes, not a TBitmap: decoding and image caching
    is the chat-list frame's job. This lets the model be tested without
    a widget set and keeps graphics out of a unit that has no business
    with them. }

  TChatRow = class
  public
    Id:                 Int64;
    Order:              Int64;
    IsPinned:           boolean;
    InList:             boolean;   { has a position in chatListMain }
    InArchive:          boolean;   { has a position in chatListArchive }
    ArchiveOrder:       Int64;
    { Ids of the chat folders (chatListFolder) this chat currently
      appears in — empty for a chat in no folder, and also for one
      whose folder positions TDLib simply hasn't sent yet.

      Maintained ADDITIVELY: one id added or removed per explicit
      signal (updateChatPosition with a folder list, or
      updateChatAddedToList/updateChatRemovedFromList), never rebuilt
      wholesale from a positions array the way InList/InArchive are.
      That difference is deliberate, not an oversight —
      updateChatLastMessage routinely arrives with "positions":[] for a
      chat that IS in the main list and in several folders (confirmed
      in this project's own tdlib_raw.log, not assumed), so treating
      that array as exhaustive for folders would clear every folder
      again on the next incoming message. }
    FolderIds:          array of integer;
    Kind:               TChatKind;
    Title:              utf8string;
    LastText:           utf8string;
    LastGlyphs:         TPreviewGlyphArray;   { custom-emoji spans in LastText, see MessagePreview }
    LastDate:           Int64;
    LastIsOutgoing:     boolean;
    LastMessageId:      Int64;
    LastSending:        TMsgSendState;
    LastReadOutbox:     Int64;   { id of the last message the peer has read }
    { id of the last INCOMING message this account has read. What the
      "Unread messages" divider is placed after — the first message
      newer than this one is the first unread one. Arrives both in the
      chat object and in updateChatReadInbox (confirmed in
      tdlib_raw.log, not assumed). }
    LastReadInbox:      Int64;
    UnreadCount:        integer;
    UnreadMentionCount: integer;
    IsMarkedAsUnread:   boolean;
    IsMuted:            boolean;   { mute_for > 0 }
    { Raw notification settings. Kept whole because
      setChatNotificationSettings takes the object AS A WHOLE: building
      it from just two fields would wipe out sound, preview, and
      everything else. }
    NotifyRaw:          utf8string;
    UserId:             Int64;        { the peer, private chats only }
    { chatTypeSupergroup.supergroup_id — set for BOTH ordinary
      supergroups and broadcast channels (Kind=ckSupergroup/ckChannel;
      TDLib backs both by the same supergroup entity, is_channel is
      what tells them apart). 0 for anything else. Needed to look up
      the viewer's own admin/creator override
      (TTdSupergroups.OverridesPermissions, tdsupergroups.pas) — see
      CanSendBasicMessages below for why chat.permissions alone isn't
      enough. }
    SupergroupId:       Int64;
    PhotoFileId:        integer;      { small.id, 0 = no photo }
    PhotoPath:          utf8string;   { local path, if already downloaded }
    Minithumb:          RawByteString;{ raw JPEG from minithumbnail }
    AvatarRequested:    boolean;      { downloadFile already sent }
    { -1 if not received yet. 0..6 are the reserved "base" colors
      (red/orange/violet/green/cyan/blue/pink), 7+ are resolved via
      TTdAccentColors (tdaccentcolors.pas) from updateAccentColors.
      Needed by framehistory.pas for anonymous posts made on behalf of
      a chat/channel. }
    AccentColorId:      integer;
    { The Premium "emoji status" shown after a user's name (a custom
      emoji id, same id-space as LastGlyphs/text custom emoji), 0 if
      none. Read straight off chat.emoji_status — TDLib mirrors the
      peer's own user.emoji_status onto the chat object itself for
      private chats, so no separate user lookup is needed here (unlike
      is_premium below, which genuinely only exists on the user).
      emojiStatusTypeUpgradedGift (collectible statuses, no emoji id)
      is left at 0, same as "no status" — see ApplyEmojiStatus. }
    EmojiStatusCustomEmojiId: Int64;
    { chat.permissions.can_send_basic_messages — what it actually
      describes, per TDLib's own doc on chatPermissions, is what a
      NON-ADMINISTRATOR member of the chat may do; it's what makes a
      broadcast channel come back False for everyone but its posting
      admins/creator (ordinary members/viewers can never send there at
      all), while an ordinary group or a private chat comes back True.
      Says NOTHING about the viewer's OWN admin/creator status in a
      channel they'd otherwise be refused in — that lives in a
      separate per-member status TDLib doesn't attach to the chat
      object at all (supergroup.status, tracked by TTdSupergroups,
      tdsupergroups.pas, keyed by SupergroupId below — the caller
      checks TTdSupergroups.OverridesPermissions FIRST and only falls
      back to this field when that returns no personal override).
      Kept live via updateChatPermissions, in addition to the initial
      value from ApplyChat. Defaults True (a freshly Obtain'd row,
      before its first ApplyChat) so nothing hides on a not-yet-
      populated row. }
    CanSendBasicMessages: boolean;
  end;

  { Archive summary for the pseudo-row at the top of the list. }
  TArchiveInfo = record
    KnownChats:  integer;    { how many archived chats have loaded }
    TotalChats:  integer;    { how many there are in total, per TDLib }
    UnreadChats: integer;    { chats with unread messages }
    Preview:     utf8string; { comma-separated titles }
  end;

  TChatMap = specialize TFPGMap<Int64, TChatRow>;
  TFileMap = specialize TFPGMap<integer, TChatRow>;
  TBotMap = specialize TFPGMap<Int64, boolean>;

  TTdChatsEvent = procedure(Sender: TObject) of object;
  TTdChatsErrorEvent = procedure(Sender: TObject; ACode: integer;
    const AMessage, AAction: utf8string) of object;

  { TTdChats

    The list is not paginated: TDLib delivers chats via updates, and
    loadChats only asks it to load more, replying 404 once everything
    is loaded. The model is therefore an observer, not the source of
    data requests. }

  TTdChats = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq:     TTdRequests;
    FAll:   TChatMap;     { every known chat, by id }
    FByFile: TFileMap;    { avatar file_id -> chat }
    { Bots are identified by user, not chat: a chat's type is always
      chatTypePrivate. updateUser updates arrive on their own. }
    FBots:   TBotMap;
    { Same idea as FBots again: user ids whose account is gone
      (userTypeDeleted). TDLib leaves first_name/last_name empty for
      those, so the chat title comes through blank — confirmed in this
      project's own tdlib_raw.log, which is also where the type name
      itself was read rather than recalled. }
    FDeletedUsers: TBotMap;
    { Same idea as FBots, one boolean per user id, but for
      user.is_premium — a separate map, not a second field alongside
      IsBot on some shared record: the two flags are independent and
      updateUser can change either one on its own (see ApplyUser). }
    FPremiumUsers: TBotMap;
    FRows:  TFPList;      { displayed, sorted }
    FTimer: TTimer;
    FDirty: boolean;
    FLoading: boolean;
    FAllLoaded: boolean;
    FLoadLimit: integer;
    FArchive: TArchiveInfo;     { archive summary }
    FMainInfo: TArchiveInfo;    { main-list summary }
    FArchiveRows: TFPList;      { archived chats, sorted }
    FArchiveLoading: boolean;
    FArchiveAllLoaded: boolean;
    FOnChanged: TTdChatsEvent;
    FOnLoadingChanged: TTdChatsEvent;
    FOnActionError: TTdChatsErrorEvent;
    { custom_emoji_ids with a getCustomEmojiStickers request in flight —
      see EnsureCustomEmojiForRow. Mirrors TTdMessages.FCustomEmojiPending
      (tdmessages.pas) — a genuine duplicate, not shared: TTdChats and
      TTdMessages are unrelated model classes with no common base to
      hang this on, and the two are independent GLOBAL dedupe lists
      anyway (the underlying cache in customemoji.pas is the one thing
      actually shared between them). }
    FCustomEmojiPending: array of Int64;
    { Chat folders, in the order TDLib lists them (which is the order
      the user arranged their folder tabs in — reorderChatFolders).
      Replaced wholesale on every updateChatFolders: that update is a
      complete list, not a delta. }
    FFolders: TChatFolderArray;
    { Slots for in-flight getChatFolder -> editChatFolder pairs, see
      TFolderOp. }
    FFolderOps: array of TFolderOp;

    function GetCount: integer;
    function GetRow(AIndex: integer): TChatRow;
    function Obtain(AId: Int64): TChatRow;

    procedure ApplyChat(AChat: TJSONObject);
    procedure ApplyPositions(ARow: TChatRow; APositions: TJSONArray);
    procedure ApplyPosition(ARow: TChatRow; APos: TJSONObject);
    procedure ApplyPhoto(ARow: TChatRow; APhoto: TJSONObject);
    procedure ApplyLastMessage(ARow: TChatRow; AMsg: TJSONObject);
    procedure ApplyEmojiStatus(ARow: TChatRow; AStatus: TJSONObject);
    procedure ApplyPermissions(ARow: TChatRow; APermissions: TJSONObject);

    procedure Touch;
    procedure Rebuild(Sender: TObject);
    procedure SetLoading(AValue: boolean);
    procedure LoadChatsDone(Sender: TObject; const AResp: TTdResponse);
    procedure ArchiveDone(Sender: TObject; const AResp: TTdResponse);
    function GetArchiveCount: integer;
    function GetArchiveRow(AIndex: integer): TChatRow;
    procedure RebuildArchive;
    procedure ApplyUnreadCount(AObj: TJSONObject);
    procedure ActionDone(Sender: TObject; const AResp: TTdResponse);
    procedure DownloadDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyFile(AFile: TJSONObject);
    function IsCustomEmojiPending(AId: Int64): boolean;
    procedure MarkCustomEmojiPending(AId: Int64);
    procedure ClearCustomEmojiPending(AId: Int64);
    procedure GetCustomEmojiStickersDone(Sender: TObject; const AResp: TTdResponse);
    procedure DownloadCustomEmojiDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyCustomEmojiFile(AFile: TJSONObject);
    procedure ApplyUser(AUser: TJSONObject);
    procedure ApplyNotifySettings(ARow: TChatRow; ASettings: TJSONObject);
    procedure ApplyChatFolders(AFolders: TJSONArray);
    procedure SetRowFolder(ARow: TChatRow; AFolderId: integer; AIn: boolean);
    procedure ApplyListMembership(AObj: TJSONObject; AIn: boolean);
    function GetFolderCount: integer;
    function GetFolder(AIndex: integer): TChatFolder;
    function AllocFolderOp(AFolderId: integer; AChatId: Int64): PtrInt;
    procedure DetachChatFromFolders(ARow: TChatRow; AExceptId: integer);
    procedure RemoveChatFromFolder(AChatId: Int64; AFolderId: integer);
    procedure GetChatFolderDone(Sender: TObject; const AResp: TTdResponse);
  public
    { The model belongs to an account. The resolver is passed in from
      outside rather than fetched as a singleton: each account has its
      own. }
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { A chat by id, nil if unknown. Public: framehistory.pas uses it to
      fetch the current chat's LastReadOutbox (message status icon) and
      the sender chat's Title (anonymous posts on behalf of a
      channel/group). }
    function Lookup(AId: Int64): TChatRow;
    { --- chat actions ---
      The result arrives via updates (updateChatReadInbox,
      updateChatPosition, and others) that the model already parses, so
      the list updates itself. These methods only send the request. }
    { Turns notifications on or off. Mute-for-a-period is not supported
      yet: turning it off is permanent. }
    procedure SetMuted(ARow: TChatRow; AMuted: boolean);
    procedure MarkAsRead(ARow: TChatRow);
    procedure MarkAsUnread(ARow: TChatRow);
    procedure SetPinned(ARow: TChatRow; APinned: boolean);
    procedure SetArchived(ARow: TChatRow; AArchived: boolean);
    procedure LeaveChat(ARow: TChatRow);

    { --- chat folders ---
      Membership is read straight off TChatRow.FolderIds (kept current
      by updates); the two actions below only send requests, and the
      row updates itself when TDLib reports the new positions. }
    { A folder's display title by id, '' if that id is unknown. }
    function FolderTitle(AFolderId: integer): utf8string;
    { The folder to SHOW for a chat that may be in several at once: the
      first one in FFolders order, i.e. the leftmost of the user's own
      folder tabs. 0 = none. }
    function RowFolderId(ARow: TChatRow): integer;
    { Moves a chat into AFolderId, leaving every other folder it is
      currently in. Not "add to folder": one button showing one folder
      is the whole point of the row's folder chip. }
    procedure MoveChatToFolder(ARow: TChatRow; AFolderId: integer);
    { Creates a new folder holding just this chat (and removes the chat
      from its current folders, as MoveChatToFolder would). The folder
      list refreshes itself: TDLib answers with a new updateChatFolders. }
    procedure CreateFolderWithChat(const ATitle: utf8string; ARow: TChatRow);
    { Takes the chat out of every folder it is in, without putting it
      anywhere else. Same caveat as the removal half of
      MoveChatToFolder: a chat a folder includes BY RULE stays in it —
      see GetChatFolderDone. }
    procedure RemoveChatFromFolders(ARow: TChatRow);

    { Whether the peer is a bot. Always False for non-private chats. }
    function IsBotChat(ARow: TChatRow): boolean;
    { Whether the peer is a Telegram Premium user (user.is_premium).
      Always False for non-private chats, same restriction as
      IsBotChat — group/channel/secret chats have no single peer to
      ask (secret chats never get UserId populated either, see
      ChatUserId). }
    function IsPremiumUser(ARow: TChatRow): boolean;
    { True when the peer's account has been deleted. Same shape as the
      two above: a private chat with a known peer, nothing else. }
    function IsDeletedUser(ARow: TChatRow): boolean;
    { Whether ARow IS this account's own Saved Messages chat (a
      ckPrivate row whose peer is this account's own user id — the
      standard TDLib representation, no dedicated chat type of its
      own). Used to hide the notification-mute toggle for that row: it
      has no effect there (you can't mute notifications from yourself),
      unlike pinning, which still works normally. False while FSession
      hasn't resolved its own UserId yet (getMe still in flight, or no
      session at all) — never a false positive, at worst a brief window
      where the row looks like any other private chat. }
    function IsSelfChat(ARow: TChatRow): boolean;

    { Requests the real avatar. Called by the frame only for visible
      rows — downloading everything at once would be pointless. Repeat
      calls are harmless. }
    procedure EnsureAvatar(ARow: TChatRow);
    { Custom (Premium) emoji in ARow.LastGlyphs, plus the peer's own
      Premium "emoji status" (ARow.EmojiStatusCustomEmojiId) if it has
      one — same idea as TTdMessages.EnsureCustomEmojiForRow
      (tdmessages.pas), which likewise batches a message's text
      entities together with its reactions in one request rather than
      firing a separate one per source: a message's history being open
      is what fetches these for the message view, but the chat LIST
      shows a preview of chats that may never have been opened this
      session at all, so it needs its own fetch path, not just its own
      render path (already wired, framechats.pas). Called by the frame
      only for visible rows, same as EnsureAvatar above — repeat calls
      are harmless. }
    procedure EnsureCustomEmojiForRow(ARow: TChatRow);

    { Asks TDLib to load the next batch. The chats themselves arrive via
      updates, not in the response to this request. }
    procedure LoadMore;
    { Same for the archive list: it has its own cursor and its own
      "everything loaded" flag. }
    procedure LoadMoreArchive;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property Count: integer read GetCount;
    property Rows[AIndex: integer]: TChatRow read GetRow; default;
    { List summaries. Refreshed together with each rebuild. }
    property Archive: TArchiveInfo read FArchive;
    property MainInfo: TArchiveInfo read FMainInfo;

    { Archived chats — a second list, living alongside the main one. }
    property ArchiveCount: integer read GetArchiveCount;
    property ArchiveRows[AIndex: integer]: TChatRow read GetArchiveRow;
    property ArchiveLoading: boolean read FArchiveLoading;
    property ArchiveAllLoaded: boolean read FArchiveAllLoaded;
    property Loading: boolean read FLoading;
    property AllLoaded: boolean read FAllLoaded;
    property LoadLimit: integer read FLoadLimit write FLoadLimit;

    { The user's chat folders, in their own tab order. }
    property FolderCount: integer read GetFolderCount;
    property Folders[AIndex: integer]: TChatFolder read GetFolder;

    property Session: ITdSession read FSession;
    property OnChanged: TTdChatsEvent read FOnChanged write FOnChanged;
    property OnActionError: TTdChatsErrorEvent read FOnActionError write FOnActionError;
    property OnLoadingChanged: TTdChatsEvent read FOnLoadingChanged write FOnLoadingChanged;
  end;

function ChatKindToStr(AKind: TChatKind): string;
{ Read receipt. "Read" means the last message's id is no greater than
  last_read_outbox_message_id. }
function ChatReceipt(ARow: TChatRow): TChatReceipt;
{ A short preview of the message content for the row's second line.
  AGlyphs collects any textEntityTypeCustomEmoji spans found in whatever
  formattedText (text or caption) the preview was built from, with byte
  offsets already relative to the RETURNED string — including the
  "Photo: ", "Video: " etc. prefix CaptionOr adds internally, not to the
  original caption alone. }
function MessagePreview(AContent: TJSONObject; out AGlyphs: TPreviewGlyphArray): utf8string;

implementation

function ChatKindToStr(AKind: TChatKind): string;
begin
  case AKind of
    ckPrivate:    Result := 'private';
    ckBasicGroup: Result := 'group';
    ckSupergroup: Result := 'supergroup';
    ckChannel:    Result := 'channel';
    ckSecret:     Result := 'secret';
  else
    Result := 'unknown';
  end;
end;

{ chat_folder_id of a ChatList object, or -1 when it isn't a folder at
  all (chatListMain/chatListArchive, which the model tracks through
  their own dedicated fields). Folder ids are assigned by the server
  and are positive, so -1 can never collide with a real one. }
function ChatListFolderId(AList: TJSONObject): integer;
begin
  Result := -1;
  if AList = nil then begin
    Exit;
  end;
  if JGetStr(AList, '@type') = 'chatListFolder' then begin
    Result := JGetInt(AList, 'chat_folder_id');
  end;
end;

{ Strips TDLib's envelope keys off a cloned RESPONSE object so it can
  be handed straight back as a REQUEST parameter, and forces its
  '@type'. A response carries '@extra' (this project's own request tag,
  tdreq.pas) and '@client_id'; neither belongs inside a chatFolder
  being sent to editChatFolder. Everything else is preserved untouched,
  including fields this code knows nothing about — that is the entire
  point of a get/modify/put cycle: a folder's icon, color and filter
  flags have to survive an edit that only means to change which chats
  are in it. }
procedure StripEnvelope(AObj: TJSONObject; const AType: utf8string);
var
  I: integer;
  N: string;
begin
  if AObj = nil then begin
    Exit;
  end;
  I := 0;
  while I < AObj.Count do begin
    N := AObj.Names[I];
    if (N <> '') and (N[1] = '@') then begin
      AObj.Delete(I);
    end else begin
      Inc(I);
    end;
  end;
  AObj.Strings['@type'] := string(AType);
end;

{ Drops every occurrence of AId from the named int53 array, if the
  array is there at all. }
procedure RemoveIdFromArray(AObj: TJSONObject; const AName: string; AId: Int64);
var
  Arr: TJSONArray;
  I: integer;
begin
  Arr := JGetArr(AObj, AName);
  if Arr = nil then begin
    Exit;
  end;
  I := 0;
  while I < Arr.Count do begin
    if (Arr.Items[I].JSONType = jtNumber) and (Arr.Items[I].AsInt64 = AId) then begin
      Arr.Delete(I);
    end else begin
      Inc(I);
    end;
  end;
end;

{ A complete chatFolder object for createChatFolder, holding exactly
  one chat and no automatic filters — the minimum that describes "a
  folder called X with this chat in it". Built with TJSONObject rather
  than by string concatenation for one reason that matters: the title
  is arbitrary user input and has to be escaped properly. }
function NewFolderJson(const ATitle: utf8string; AChatId: Int64): utf8string;
var
  Obj, NameObj, TextObj, IconObj: TJSONObject;
  Included: TJSONArray;
begin
  Obj := TJSONObject.Create;
  try
    TextObj := TJSONObject.Create;
    TextObj.Strings['@type'] := 'formattedText';
    TextObj.Strings['text'] := string(ATitle);
    TextObj.Add('entities', TJSONArray.Create);

    NameObj := TJSONObject.Create;
    NameObj.Strings['@type'] := 'chatFolderName';
    NameObj.Add('text', TextObj);
    NameObj.Booleans['animate_custom_emoji'] := False;

    { "Custom" is a real icon name from the schema's own list, and the
      one TDLib itself hands back for a folder with no theme of its
      own. color_id -1 means "no color", the only value guaranteed to
      be accepted: per the schema a real color can't be set at all
      without Premium or with folder tags disabled. }
    IconObj := TJSONObject.Create;
    IconObj.Strings['@type'] := 'chatFolderIcon';
    IconObj.Strings['name'] := 'Custom';

    Included := TJSONArray.Create;
    if AChatId <> 0 then begin
      Included.Add(AChatId);
    end;

    Obj.Strings['@type'] := 'chatFolder';
    Obj.Add('name', NameObj);
    Obj.Add('icon', IconObj);
    Obj.Add('color_id', -1);
    Obj.Booleans['is_shareable'] := False;
    Obj.Add('pinned_chat_ids', TJSONArray.Create);
    Obj.Add('included_chat_ids', Included);
    Obj.Add('excluded_chat_ids', TJSONArray.Create);
    Obj.Booleans['exclude_muted'] := False;
    Obj.Booleans['exclude_read'] := False;
    Obj.Booleans['exclude_archived'] := False;
    Obj.Booleans['include_contacts'] := False;
    Obj.Booleans['include_non_contacts'] := False;
    Obj.Booleans['include_bots'] := False;
    Obj.Booleans['include_groups'] := False;
    Obj.Booleans['include_channels'] := False;
    Result := utf8string(Obj.AsJSON);
  finally
    Obj.Free;
  end;
end;

function ChatReceipt(ARow: TChatRow): TChatReceipt;
begin
  Result := crNone;
  if (ARow = nil) or (not ARow.LastIsOutgoing) or (ARow.LastMessageId = 0) then begin
    Exit;
  end;
  case ARow.LastSending of
    mssPending: Result := crPending;
    mssFailed:  Result := crFailed;
  else
    if ARow.LastMessageId <= ARow.LastReadOutbox then begin
      Result := crRead;
    end else begin
      Result := crSent;
    end;
  end;
end;

function ChatUserId(AType: TJSONObject): Int64;
begin
  Result := 0;
  if (AType <> nil) and (JGetStr(AType, '@type') = 'chatTypePrivate') then begin
    Result := JGetInt64(AType, 'user_id');
  end;
end;

{ chatTypeSupergroup.supergroup_id — present for both ordinary
  supergroups and channels (see SupergroupId's own comment). }
function ChatSupergroupId(AType: TJSONObject): Int64;
begin
  Result := 0;
  if (AType <> nil) and (JGetStr(AType, '@type') = 'chatTypeSupergroup') then begin
    Result := JGetInt64(AType, 'supergroup_id');
  end;
end;

function KindFromType(AType: TJSONObject): TChatKind;
var
  T: utf8string;
begin
  Result := ckUnknown;
  if AType = nil then begin
    Exit;
  end;
  T := JGetStr(AType, '@type');
  if T = 'chatTypePrivate' then begin
    Result := ckPrivate;
  end else if T = 'chatTypeBasicGroup' then begin
    Result := ckBasicGroup;
  end else if T = 'chatTypeSupergroup' then begin
    if JGetBool(AType, 'is_channel') then begin
      Result := ckChannel;
    end else begin
      Result := ckSupergroup;
    end;
  end else if T = 'chatTypeSecret' then begin
    Result := ckSecret;
  end;
end;

{ Local duplicate of tdmessages.Utf16RangeToByteRange (tdmessages.pas
  can't be used here — it already uses tdchats, and this file is
  plain data with no business depending on the message layout model
  either way). Small, low-risk logic (a UTF-16-code-unit-count to
  UTF-8-byte-offset conversion) — worth a second copy rather than a new
  cross-unit dependency for it, unlike something genuinely fragile (see
  the R/B channel swap comment in customemoji.pas for the other end of
  that tradeoff). }
procedure Utf16RangeToByteRangeLocal(const AText: utf8string;
  AUtf16Offset, AUtf16Length: integer; out AByteStart, AByteLen: integer);
var
  I, N, Units, TargetStart, TargetEnd, CodeLen: integer;
  Cp: cardinal;

  function DecodeCp(APos: integer; out ALen: integer): cardinal;
  var
    B0: byte;
  begin
    B0 := byte(AText[APos]);
    if B0 < $80 then ALen := 1
    else if B0 < $C0 then ALen := 1
    else if B0 < $E0 then ALen := 2
    else if B0 < $F0 then ALen := 3
    else ALen := 4;
    if APos + ALen - 1 > Length(AText) then begin
      ALen := Length(AText) - APos + 1;
    end;
    case ALen of
      1: Result := B0;
      2: Result := ((B0 and $1F) shl 6) or (byte(AText[APos + 1]) and $3F);
      3: Result := ((B0 and $0F) shl 12) or ((byte(AText[APos + 1]) and $3F) shl 6)
                   or (byte(AText[APos + 2]) and $3F);
    else
      Result := ((B0 and $07) shl 18) or ((byte(AText[APos + 1]) and $3F) shl 12)
                or ((byte(AText[APos + 2]) and $3F) shl 6) or (byte(AText[APos + 3]) and $3F);
    end;
  end;

begin
  TargetStart := AUtf16Offset;
  TargetEnd := AUtf16Offset + AUtf16Length;
  N := Length(AText);
  AByteStart := N + 1;
  AByteLen := 0;

  I := 1;
  Units := 0;
  while I <= N do begin
    if Units = TargetStart then begin
      AByteStart := I;
    end;
    Cp := DecodeCp(I, CodeLen);
    if Cp > $FFFF then begin
      Inc(Units, 2);
    end else begin
      Inc(Units, 1);
    end;
    Inc(I, CodeLen);
    if Units >= TargetEnd then begin
      if AByteStart > N then begin
        AByteStart := I;
      end;
      AByteLen := I - AByteStart;
      Exit;
    end;
  end;
  if AByteStart > N then begin
    AByteStart := N + 1;
  end;
  AByteLen := (N + 1) - AByteStart;
end;

{ Appends every textEntityTypeCustomEmoji span found in AEntities (the
  'entities' array alongside the formattedText ASubText was read from)
  to AGlyphs, with byte offsets shifted by ABaseOffset — the length of
  whatever prefix ("Photo: " etc.) MessagePreview put in front of
  ASubText in the final, returned string. }
procedure AppendCustomEmojiGlyphs(const ASubText: utf8string; AEntities: TJSONArray;
  ABaseOffset: integer; var AGlyphs: TPreviewGlyphArray);
var
  I, ByteStart, ByteLen: integer;
  EObj, TypeObj: TJSONObject;
begin
  if AEntities = nil then begin
    Exit;
  end;
  for I := 0 to AEntities.Count - 1 do begin
    if AEntities.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    EObj := TJSONObject(AEntities.Items[I]);
    TypeObj := JGetObj(EObj, 'type');
    if JGetStr(TypeObj, '@type') <> 'textEntityTypeCustomEmoji' then begin
      Continue;
    end;
    Utf16RangeToByteRangeLocal(ASubText, JGetInt(EObj, 'offset'), JGetInt(EObj, 'length'),
      ByteStart, ByteLen);
    if ByteLen <= 0 then begin
      Continue;
    end;
    SetLength(AGlyphs, Length(AGlyphs) + 1);
    AGlyphs[High(AGlyphs)].ByteStart := ABaseOffset + ByteStart;
    AGlyphs[High(AGlyphs)].ByteLen := ByteLen;
    AGlyphs[High(AGlyphs)].CustomEmojiId := JGetInt64(TypeObj, 'custom_emoji_id');
  end;
end;

function MessagePreview(AContent: TJSONObject; out AGlyphs: TPreviewGlyphArray): utf8string;
var
  T, Cap: utf8string;
  FT: TJSONObject;

  function CaptionOr(const ADefault: utf8string): utf8string;
  begin
    FT := JGetObj(AContent, 'caption');
    Cap := JGetStr(FT, 'text');
    if Cap <> '' then begin
      Result := ADefault + ': ' + Cap;
      AppendCustomEmojiGlyphs(Cap, JGetArr(FT, 'entities'), Length(ADefault) + 2, AGlyphs);
    end else begin
      Result := ADefault;
    end;
  end;

begin
  Result := '';
  SetLength(AGlyphs, 0);
  if AContent = nil then begin
    Exit;
  end;
  T := JGetStr(AContent, '@type');

  if T = 'messageText' then begin
    FT := JGetObj(AContent, 'text');
    Result := JGetStr(FT, 'text');
    AppendCustomEmojiGlyphs(Result, JGetArr(FT, 'entities'), 0, AGlyphs);
  end else if T = 'messagePhoto' then begin
    Result := CaptionOr('Photo');
  end else if T = 'messageVideo' then begin
    Result := CaptionOr('Video');
  end else if T = 'messageAnimation' then begin
    Result := CaptionOr('GIF');
  end else if T = 'messageDocument' then begin
    Result := CaptionOr('File');
  end else if T = 'messageAudio' then begin
    Result := CaptionOr('Audio');
  end else if T = 'messageVoiceNote' then begin
    Result := CaptionOr('Voice message');
  end else if T = 'messageVideoNote' then begin
    Result := 'Video message';
  end else if T = 'messageSticker' then begin
    Result := 'Sticker';
  end else if T = 'messageAnimatedEmoji' then begin
    Result := JGetStr(AContent, 'emoji');
  end else if T = 'messageLocation' then begin
    Result := 'Location';
  end else if T = 'messageContact' then begin
    Result := 'Contact';
  end else if T = 'messagePoll' then begin
    Result := 'Poll';
  end else if T = 'messageCall' then begin
    Result := 'Call';
  end else begin
    { Unknown kind — show the raw type, more useful than a blank. }
    Result := T;
  end;

  { A line break has no place in a one-line preview. }
  Result := utf8string(StringReplace(StringReplace(string(Result),
    #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
end;

{ ---------------- sorting ---------------- }

function CompareRows(P1, P2: Pointer): integer;
var
  A, B: TChatRow;
begin
  A := TChatRow(P1);
  B := TChatRow(P2);
  { The schema calls for descending order by the pair (order, chat.id). }
  if A.Order > B.Order then begin
    Result := -1;
  end else if A.Order < B.Order then begin
    Result := 1;
  end else if A.Id > B.Id then begin
    Result := -1;
  end else if A.Id < B.Id then begin
    Result := 1;
  end else begin
    Result := 0;
  end;
end;

function CompareArchive(P1, P2: Pointer): integer;
var
  A, B: TChatRow;
begin
  A := TChatRow(P1);
  B := TChatRow(P2);
  if A.ArchiveOrder > B.ArchiveOrder then begin
    Result := -1;
  end else if A.ArchiveOrder < B.ArchiveOrder then begin
    Result := 1;
  end else if A.Id > B.Id then begin
    Result := -1;
  end else if A.Id < B.Id then begin
    Result := 1;
  end else begin
    Result := 0;
  end;
end;

{ ---------------- TTdChats ---------------- }

constructor TTdChats.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TChatMap.Create;
  FAll.Sorted := True;
  FByFile := TFileMap.Create;
  FByFile.Sorted := True;
  FBots := TBotMap.Create;
  FBots.Sorted := True;
  FPremiumUsers := TBotMap.Create;
  FPremiumUsers.Sorted := True;
  FDeletedUsers := TBotMap.Create;
  FDeletedUsers.Sorted := True;
  FRows := TFPList.Create;
  FArchiveRows := TFPList.Create;
  FLoadLimit := 30;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := CHATS_COALESCE_MS;
  FTimer.OnTimer := @Rebuild;
  FTimer.Enabled := False;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdChats.Destroy;
begin
  FTimer.Enabled := False;
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FRows.Free;
  FArchiveRows.Free;
  FBots.Free;
  FPremiumUsers.Free;
  FDeletedUsers.Free;
  FByFile.Free;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdChats.Clear;
var
  I: integer;
begin
  FRows.Clear;
  FArchiveRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  FByFile.Clear;
  FBots.Clear;
  FPremiumUsers.Clear;
  FDeletedUsers.Clear;
  { Folders belong to the account, so they go out with the chats. TDLib
    re-announces them with a fresh updateChatFolders AFTER
    authorizationStateReady (which is what triggers this Clear — that
    order verified in tdlib_raw.log, not assumed), so nothing is lost.
    In-flight folder edits are abandoned with them: their slots name
    chats that no longer exist. }
  SetLength(FFolders, 0);
  SetLength(FFolderOps, 0);
  FAllLoaded := False;
  FArchiveLoading := False;
  FArchiveAllLoaded := False;
  FillChar(FArchive, SizeOf(FArchive), 0);
  FArchive.Preview := '';
  FillChar(FMainInfo, SizeOf(FMainInfo), 0);
  FMainInfo.Preview := '';
  FDirty := False;
  FTimer.Enabled := False;
end;

function TTdChats.GetArchiveCount: integer;
begin
  Result := FArchiveRows.Count;
end;

function TTdChats.GetArchiveRow(AIndex: integer): TChatRow;
begin
  if (AIndex < 0) or (AIndex >= FArchiveRows.Count) then begin
    Result := nil;
  end else begin
    Result := TChatRow(FArchiveRows[AIndex]);
  end;
end;

function TTdChats.GetCount: integer;
begin
  Result := FRows.Count;
end;

function TTdChats.GetRow(AIndex: integer): TChatRow;
begin
  if (AIndex < 0) or (AIndex >= FRows.Count) then begin
    Result := nil;
  end else begin
    Result := TChatRow(FRows[AIndex]);
  end;
end;

function TTdChats.Lookup(AId: Int64): TChatRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdChats.Obtain(AId: Int64): TChatRow;
begin
  Result := Lookup(AId);
  if Result = nil then begin
    Result := TChatRow.Create;
    Result.Id := AId;
    { A boolean field defaults to False on a fresh object — explicit
      here so a row is never mistaken for "can't send" before its
      first ApplyChat has actually said so, see the field's own
      comment. }
    Result.CanSendBasicMessages := True;
    FAll.Add(AId, Result);
  end;
end;

procedure TTdChats.Touch;
begin
  FDirty := True;
  FTimer.Enabled := True;
end;

procedure TTdChats.Rebuild(Sender: TObject);
var
  I: integer;
  R: TChatRow;
begin
  FTimer.Enabled := False;
  if not FDirty then begin
    Exit;
  end;
  FDirty := False;

  { A full rebuild instead of incremental inserts: sorting a few
    thousand pointers takes a fraction of a millisecond, and there's an
    order of magnitude less code and fewer chances for bugs. }
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    R := FAll.Data[I];
    if R.InList and (R.Order <> 0) then begin
      FRows.Add(R);
    end;
  end;
  FRows.Sort(@CompareRows);
  RebuildArchive;

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

procedure TTdChats.SetLoading(AValue: boolean);
begin
  if FLoading = AValue then begin
    Exit;
  end;
  FLoading := AValue;
  if Assigned(FOnLoadingChanged) then begin
    FOnLoadingChanged(Self);
  end;
end;

procedure TTdChats.LoadMore;
begin
  if FLoading or FAllLoaded then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  SetLoading(True);
  if FReq = nil then begin
    SetLoading(False);
    Exit;
  end;
  FReq.SendRequest('loadChats',
    '"chat_list":{"@type":"chatListMain"},"limit":' + utf8string(IntToStr(FLoadLimit)),
    @LoadChatsDone);
end;

procedure TTdChats.EnsureAvatar(ARow: TChatRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  { Nothing to download, already downloaded, or already requested. }
  if (ARow.PhotoFileId = 0) or (ARow.PhotoPath <> '') or ARow.AvatarRequested then begin
    Exit;
  end;
  ARow.AvatarRequested := True;
  if FByFile.IndexOf(ARow.PhotoFileId) < 0 then begin
    FByFile.Add(ARow.PhotoFileId, ARow);
  end;
  { priority 1 — the lowest: avatars must not compete with message
    loading. synchronous=false, the result arrives via an updateFile. }
  if FReq = nil then begin
    ARow.AvatarRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.PhotoFileId)) +
    ',"priority":1,"offset":0,"limit":0,"synchronous":false',
    @DownloadDone, ARow.PhotoFileId);
end;

procedure TTdChats.DownloadDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  { The downloadFile response is a file object. If the file was already
    on disk, it arrives right here, and updateFile may never come at
    all. }
  if AResp.Success then begin
    ApplyFile(AResp.Obj);
    Exit;
  end;
  { Failure — clear the flag so another attempt can be made. }
  Idx := FByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FByFile.Data[Idx].AvatarRequested := False;
  end;
end;

procedure TTdChats.ApplyFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TChatRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FByFile.Data[Idx];
  if R.PhotoPath = Path then begin
    Exit;
  end;
  R.PhotoPath := Path;
  Touch;
end;

function TTdChats.IsCustomEmojiPending(AId: Int64): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(FCustomEmojiPending) do begin
    if FCustomEmojiPending[I] = AId then begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdChats.MarkCustomEmojiPending(AId: Int64);
begin
  SetLength(FCustomEmojiPending, Length(FCustomEmojiPending) + 1);
  FCustomEmojiPending[High(FCustomEmojiPending)] := AId;
end;

procedure TTdChats.ClearCustomEmojiPending(AId: Int64);
var
  I, J: integer;
begin
  for I := 0 to High(FCustomEmojiPending) do begin
    if FCustomEmojiPending[I] = AId then begin
      for J := I to High(FCustomEmojiPending) - 1 do begin
        FCustomEmojiPending[J] := FCustomEmojiPending[J + 1];
      end;
      SetLength(FCustomEmojiPending, Length(FCustomEmojiPending) - 1);
      Exit;
    end;
  end;
end;

{ Same batching approach as TTdMessages.EnsureCustomEmojiForRow
  (tdmessages.pas) — one getCustomEmojiStickers call per row for
  whatever ids in ARow.LastGlyphs aren't already known/pending. }
procedure TTdChats.EnsureCustomEmojiForRow(ARow: TChatRow);
var
  I, N: integer;
  Ids: array of Int64;
  Id: Int64;
  Body: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  SetLength(Ids, Length(ARow.LastGlyphs) + 1);
  N := 0;
  for I := 0 to High(ARow.LastGlyphs) do begin
    Id := ARow.LastGlyphs[I].CustomEmojiId;
    if (Id = 0) or CustomEmojiKnown(Id) or IsCustomEmojiPending(Id) then begin
      Continue;
    end;
    Ids[N] := Id;
    Inc(N);
    MarkCustomEmojiPending(Id);
  end;
  { The peer's Premium "emoji status" rides in the same batch — same
    dedup rules as the preview glyphs above, just one extra candidate
    id, not its own array/request (the same approach
    TTdMessages.EnsureCustomEmojiForRow, tdmessages.pas, already takes
    to combine text entities with reactions). }
  Id := ARow.EmojiStatusCustomEmojiId;
  if (Id <> 0) and not CustomEmojiKnown(Id) and not IsCustomEmojiPending(Id) then begin
    Ids[N] := Id;
    Inc(N);
    MarkCustomEmojiPending(Id);
  end;
  if N = 0 then begin
    Exit;
  end;

  Body := '"custom_emoji_ids":[';
  for I := 0 to N - 1 do begin
    if I > 0 then begin
      Body := Body + ',';
    end;
    Body := Body + '"' + utf8string(IntToStr(Ids[I])) + '"';
  end;
  Body := Body + ']';
  FReq.SendRequest('getCustomEmojiStickers', Body, @GetCustomEmojiStickersDone);
end;

{ Same shape as TTdMessages.GetCustomEmojiStickersDone (tdmessages.pas)
  — see its comment for the accepted "not found = not retried this
  session" tradeoff, unchanged here. }
procedure TTdChats.GetCustomEmojiStickersDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  StObj, FormatObj, FullTypeObj, FileObj, LocalObj: TJSONObject;
  Id: Int64;
  Format: TCustomEmojiFormat;
  FmtType: utf8string;
  FileId: integer;
  LocalPath: utf8string;
begin
  if not AResp.Success then begin
    Exit;
  end;
  Arr := JGetArr(AResp.Obj, 'stickers');
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    StObj := TJSONObject(Arr.Items[I]);
    FullTypeObj := JGetObj(StObj, 'full_type');
    if JGetStr(FullTypeObj, '@type') <> 'stickerFullTypeCustomEmoji' then begin
      Continue;
    end;
    Id := JGetInt64(FullTypeObj, 'custom_emoji_id');
    if Id = 0 then begin
      Continue;
    end;
    ClearCustomEmojiPending(Id);

    FormatObj := JGetObj(StObj, 'format');
    FmtType := JGetStr(FormatObj, '@type');
    if FmtType = 'stickerFormatTgs' then begin
      Format := cmfTgs;
    end else if FmtType = 'stickerFormatWebm' then begin
      Format := cmfWebm;
    end else begin
      Format := cmfWebp;
    end;

    FileObj := JGetObj(StObj, 'sticker');
    FileId := JGetInt(FileObj, 'id');
    LocalPath := '';
    LocalObj := JGetObj(FileObj, 'local');
    if JGetBool(LocalObj, 'is_downloading_completed') then begin
      LocalPath := JGetStr(LocalObj, 'path');
    end;
    CustomEmojiSetSticker(Id, FileId, Format, LocalPath);

    if LocalPath = '' then begin
      if CustomEmojiNeedsDownload(Id) then begin
        CustomEmojiMarkDownloadRequested(Id);
        FReq.SendRequest('downloadFile',
          '"file_id":' + utf8string(IntToStr(FileId)) +
          ',"priority":32,"offset":0,"limit":0,"synchronous":false',
          @DownloadCustomEmojiDone, PtrInt(FileId));
      end;
    end else begin
      Touch;
    end;
  end;
end;

procedure TTdChats.DownloadCustomEmojiDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyCustomEmojiFile(AResp.Obj);
  end;
end;

procedure TTdChats.ApplyCustomEmojiFile(AFile: TJSONObject);
var
  FileId: integer;
  Id: Int64;
  Local: TJSONObject;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Id := CustomEmojiIdForFile(FileId);
  if Id = 0 then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;
  CustomEmojiSetLocalPath(Id, Path);
  Touch;
end;

procedure TTdChats.LoadMoreArchive;
begin
  if FArchiveLoading or FArchiveAllLoaded or (FReq = nil) then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  FArchiveLoading := True;
  FReq.SendRequest('loadChats',
    '"chat_list":{"@type":"chatListArchive"},"limit":' +
    utf8string(IntToStr(FLoadLimit)), @ArchiveDone);
end;

procedure TTdChats.ArchiveDone(Sender: TObject; const AResp: TTdResponse);
begin
  FArchiveLoading := False;
  { 404 is the only signal that the archive has been exhausted. }
  if (not AResp.Success) and (AResp.ErrorCode = 404) then begin
    FArchiveAllLoaded := True;
    Touch;
  end;
end;

procedure TTdChats.ApplyUnreadCount(AObj: TJSONObject);
var
  Kind: utf8string;
begin
  if AObj = nil then begin
    Exit;
  end;
  Kind := JGetStr(JGetObj(AObj, 'chat_list'), '@type');
  if Kind = 'chatListArchive' then begin
    FArchive.TotalChats := JGetInt(AObj, 'total_count');
    FArchive.UnreadChats := JGetInt(AObj, 'unread_count');
  end else if Kind = 'chatListMain' then begin
    FMainInfo.TotalChats := JGetInt(AObj, 'total_count');
    FMainInfo.UnreadChats := JGetInt(AObj, 'unread_count');
  end else begin
    Exit;
  end;
  Touch;
end;

function PreviewOf(AList: TFPList): utf8string;
var
  I: integer;
begin
  { Comma-separated titles of the top chats, matching Telegram. Cut off
    by length, not count: titles vary widely in length. }
  Result := '';
  for I := 0 to AList.Count - 1 do begin
    if Length(Result) > 60 then begin
      Break;
    end;
    if Result <> '' then begin
      Result := Result + ', ';
    end;
    Result := Result + TChatRow(AList[I]).Title;
  end;
end;

procedure TTdChats.RebuildArchive;
var
  I: integer;
  R: TChatRow;
begin
  FArchiveRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    R := FAll.Data[I];
    if R.InArchive and (R.ArchiveOrder <> 0) then begin
      FArchiveRows.Add(R);
    end;
  end;
  FArchiveRows.Sort(@CompareArchive);

  FArchive.KnownChats := FArchiveRows.Count;
  FArchive.Preview := PreviewOf(FArchiveRows);

  FMainInfo.KnownChats := FRows.Count;
  FMainInfo.Preview := PreviewOf(FRows);
end;

procedure TTdChats.LoadChatsDone(Sender: TObject; const AResp: TTdResponse);
begin
  SetLoading(False);
  { 404 is the only signal that the list has been exhausted. Other
    errors are transient and retrying is fine. }
  if (not AResp.Success) and (AResp.ErrorCode = 404) then begin
    FAllLoaded := True;
  end;
end;

procedure TTdChats.ApplyNotifySettings(ARow: TChatRow; ASettings: TJSONObject);
begin
  if (ARow = nil) or (ASettings = nil) then begin
    Exit;
  end;
  { use_default_mute_for means "follow the category's setting". The
    category's own value arrives via a separate
    updateScopeNotificationSettings; until then, such chats are treated
    as unmuted, which matches the default anyway. }
  if JGetBool(ASettings, 'use_default_mute_for') then begin
    ARow.IsMuted := False;
  end else begin
    ARow.IsMuted := JGetInt(ASettings, 'mute_for') > 0;
  end;
  ARow.NotifyRaw := utf8string(ASettings.AsJSON);
end;

procedure TTdChats.ApplyUser(AUser: TJSONObject);
var
  Id: Int64;
  IsBot, IsPrem, IsDel: boolean;
  Idx: integer;
  Changed: boolean;
begin
  if AUser = nil then begin
    Exit;
  end;
  Id := JGetInt64(AUser, 'id');
  if Id = 0 then begin
    Exit;
  end;
  IsBot := JGetStr(JGetObj(AUser, 'type'), '@type') = 'userTypeBot';
  IsDel := JGetStr(JGetObj(AUser, 'type'), '@type') = 'userTypeDeleted';
  IsPrem := JGetBool(AUser, 'is_premium');
  { updateUser arrives for EVERY known user, and there are thousands of
    them. A repaint is only requested when one of the flags this model
    tracks actually changed — checking bot status alone (the original
    shape of this method) and bailing out early on "unchanged" would
    silently skip a genuine is_premium change riding along on the same
    update, so all of them are checked before deciding whether to
    Touch. }
  Changed := False;

  Idx := FBots.IndexOf(Id);
  if Idx >= 0 then begin
    if FBots.Data[Idx] <> IsBot then begin
      FBots.Data[Idx] := IsBot;
      Changed := True;
    end;
  end else begin
    FBots.Add(Id, IsBot);
    Changed := Changed or IsBot;
  end;

  Idx := FPremiumUsers.IndexOf(Id);
  if Idx >= 0 then begin
    if FPremiumUsers.Data[Idx] <> IsPrem then begin
      FPremiumUsers.Data[Idx] := IsPrem;
      Changed := True;
    end;
  end else begin
    FPremiumUsers.Add(Id, IsPrem);
    Changed := Changed or IsPrem;
  end;

  Idx := FDeletedUsers.IndexOf(Id);
  if Idx >= 0 then begin
    if FDeletedUsers.Data[Idx] <> IsDel then begin
      FDeletedUsers.Data[Idx] := IsDel;
      Changed := True;
    end;
  end else begin
    FDeletedUsers.Add(Id, IsDel);
    Changed := Changed or IsDel;
  end;

  if Changed then begin
    Touch;
  end;
end;

function TTdChats.IsBotChat(ARow: TChatRow): boolean;
var
  Idx: integer;
begin
  Result := False;
  if (ARow = nil) or (ARow.Kind <> ckPrivate) or (ARow.UserId = 0) then begin
    Exit;
  end;
  Idx := FBots.IndexOf(ARow.UserId);
  if Idx >= 0 then begin
    Result := FBots.Data[Idx];
  end;
end;

function TTdChats.IsPremiumUser(ARow: TChatRow): boolean;
var
  Idx: integer;
begin
  Result := False;
  if (ARow = nil) or (ARow.Kind <> ckPrivate) or (ARow.UserId = 0) then begin
    Exit;
  end;
  Idx := FPremiumUsers.IndexOf(ARow.UserId);
  if Idx >= 0 then begin
    Result := FPremiumUsers.Data[Idx];
  end;
end;

function TTdChats.IsDeletedUser(ARow: TChatRow): boolean;
var
  Idx: integer;
begin
  Result := False;
  if (ARow = nil) or (ARow.Kind <> ckPrivate) or (ARow.UserId = 0) then begin
    Exit;
  end;
  Idx := FDeletedUsers.IndexOf(ARow.UserId);
  if Idx >= 0 then begin
    Result := FDeletedUsers.Data[Idx];
  end;
end;

function TTdChats.IsSelfChat(ARow: TChatRow): boolean;
begin
  Result := (ARow <> nil) and (ARow.Kind = ckPrivate) and (ARow.UserId <> 0)
    and (FSession <> nil) and (ARow.UserId = FSession.UserId);
end;

{ ---------------- chat actions ---------------- }

procedure TTdChats.ActionDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    Exit;
  end;
  if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, '');
  end;
end;

procedure TTdChats.SetMuted(ARow: TChatRow; AMuted: boolean);
const
  { Per the schema: a chat muted for more than 366 days counts as muted
    forever. There's no dedicated constant for it in the API. }
  MUTE_FOREVER = 367 * 24 * 60 * 60;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Body: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;

  Obj := nil;
  Data := nil;
  try
    { Take the existing settings and change only the mute flag — every
      other field must survive intact. }
    if ARow.NotifyRaw <> '' then begin
      try
        Data := GetJSON(string(ARow.NotifyRaw));
        if (Data <> nil) and (Data.JSONType = jtObject) then begin
          Obj := TJSONObject(Data);
        end;
      except
        FreeAndNil(Data);
      end;
    end;

    if Obj = nil then begin
      Data := TJSONObject.Create;
      Obj := TJSONObject(Data);
    end;

    Obj.Strings['@type'] := 'chatNotificationSettings';
    Obj.Booleans['use_default_mute_for'] := False;
    if AMuted then begin
      Obj.Integers['mute_for'] := MUTE_FOREVER;
    end else begin
      Obj.Integers['mute_for'] := 0;
    end;

    Body := '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
            ',"notification_settings":' + utf8string(Obj.AsJSON);
  finally
    Data.Free;
  end;

  FReq.SendRequest('setChatNotificationSettings', Body, @ActionDone);
end;

procedure TTdChats.MarkAsRead(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;

  if ARow.LastMessageId <> 0 then begin
    { force_read = true: the chat is closed, but it still needs to be
      marked as read. source is given explicitly — from the chat list. }
    FReq.SendRequest('viewMessages',
      '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
      ',"message_ids":[' + utf8string(IntToStr(ARow.LastMessageId)) + ']' +
      ',"source":{"@type":"messageSourceChatList"},"force_read":true',
      @ActionDone);
  end;

  { The chat may have been manually marked unread too — clear that as
    well, otherwise the dot would remain stuck. }
  if ARow.IsMarkedAsUnread then begin
    FReq.SendRequest('toggleChatIsMarkedAsUnread',
      '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
      ',"is_marked_as_unread":false', @ActionDone);
  end;
end;

procedure TTdChats.MarkAsUnread(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  FReq.SendRequest('toggleChatIsMarkedAsUnread',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"is_marked_as_unread":true', @ActionDone);
end;

procedure TTdChats.SetPinned(ARow: TChatRow; APinned: boolean);
var
  Flag: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  if APinned then begin
    Flag := 'true';
  end else begin
    Flag := 'false';
  end;
  { Note: for toggleChatIsPinned, chat_list comes FIRST — pinning
    applies to a specific list. }
  FReq.SendRequest('toggleChatIsPinned',
    '"chat_list":{"@type":"chatListMain"},"chat_id":' +
    utf8string(IntToStr(ARow.Id)) + ',"is_pinned":' + Flag, @ActionDone);
end;

procedure TTdChats.SetArchived(ARow: TChatRow; AArchived: boolean);
var
  List: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  if AArchived then begin
    List := 'chatListArchive';
  end else begin
    List := 'chatListMain';
  end;
  FReq.SendRequest('addChatToList',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"chat_list":{"@type":"' + List + '"}', @ActionDone);
end;

procedure TTdChats.LeaveChat(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  FReq.SendRequest('leaveChat',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)), @ActionDone);
end;

{ ---------------- chat folders ---------------- }

function TTdChats.GetFolderCount: integer;
begin
  Result := Length(FFolders);
end;

function TTdChats.GetFolder(AIndex: integer): TChatFolder;
begin
  if (AIndex < 0) or (AIndex > High(FFolders)) then begin
    Result.Id := 0;
    Result.Title := '';
  end else begin
    Result := FFolders[AIndex];
  end;
end;

function TTdChats.FolderTitle(AFolderId: integer): utf8string;
var
  I: integer;
begin
  Result := '';
  for I := 0 to High(FFolders) do begin
    if FFolders[I].Id = AFolderId then begin
      Result := FFolders[I].Title;
      Exit;
    end;
  end;
end;

function TTdChats.RowFolderId(ARow: TChatRow): integer;
var
  I, J: integer;
begin
  Result := 0;
  if ARow = nil then begin
    Exit;
  end;
  { Walked in FFolders order, not in the row's own: a chat can sit in
    several folders at once and the row shows ONE chip, so which one it
    shows has to be stable and meaningful rather than "whichever
    position update happened to arrive first". FFolders order is the
    user's own tab order, so the chip names the leftmost tab the chat
    appears under. }
  for I := 0 to High(FFolders) do begin
    for J := 0 to High(ARow.FolderIds) do begin
      if ARow.FolderIds[J] = FFolders[I].Id then begin
        Result := FFolders[I].Id;
        Exit;
      end;
    end;
  end;
end;

procedure TTdChats.ApplyChatFolders(AFolders: TJSONArray);
var
  I, N: integer;
  Info: TJSONObject;
begin
  SetLength(FFolders, 0);
  if AFolders <> nil then begin
    N := 0;
    SetLength(FFolders, AFolders.Count);
    for I := 0 to AFolders.Count - 1 do begin
      if AFolders.Items[I].JSONType <> jtObject then begin
        Continue;
      end;
      Info := TJSONObject(AFolders.Items[I]);
      FFolders[N].Id := JGetInt(Info, 'id');
      { name.text.text — chatFolderName wraps a formattedText, it is
        not a plain string (schema-confirmed, and confirmed again
        against this project's own tdlib_raw.log). }
      FFolders[N].Title := JGetStr(JGetObj(JGetObj(Info, 'name'), 'text'), 'text');
      Inc(N);
    end;
    SetLength(FFolders, N);
  end;
  Touch;
end;

procedure TTdChats.SetRowFolder(ARow: TChatRow; AFolderId: integer; AIn: boolean);
var
  I, N: integer;
begin
  if (ARow = nil) or (AFolderId <= 0) then begin
    Exit;
  end;
  for I := 0 to High(ARow.FolderIds) do begin
    if ARow.FolderIds[I] = AFolderId then begin
      if AIn then begin
        Exit;   { already there }
      end;
      for N := I to High(ARow.FolderIds) - 1 do begin
        ARow.FolderIds[N] := ARow.FolderIds[N + 1];
      end;
      SetLength(ARow.FolderIds, Length(ARow.FolderIds) - 1);
      Touch;
      Exit;
    end;
  end;
  if AIn then begin
    SetLength(ARow.FolderIds, Length(ARow.FolderIds) + 1);
    ARow.FolderIds[High(ARow.FolderIds)] := AFolderId;
    Touch;
  end;
end;

{ updateChatAddedToList / updateChatRemovedFromList. Both also fire for
  chatListMain/chatListArchive, which are tracked through positions
  instead (order carries information these two updates don't) — only
  the folder case is acted on here. }
procedure TTdChats.ApplyListMembership(AObj: TJSONObject; AIn: boolean);
var
  FolderId: integer;
  R: TChatRow;
begin
  FolderId := ChatListFolderId(JGetObj(AObj, 'chat_list'));
  if FolderId <= 0 then begin
    Exit;
  end;
  R := Lookup(JGetInt64(AObj, 'chat_id'));
  if R <> nil then begin
    SetRowFolder(R, FolderId, AIn);
  end;
end;

function TTdChats.AllocFolderOp(AFolderId: integer; AChatId: Int64): PtrInt;
var
  I: integer;
begin
  for I := 0 to High(FFolderOps) do begin
    if FFolderOps[I].ChatId = 0 then begin
      FFolderOps[I].FolderId := AFolderId;
      FFolderOps[I].ChatId := AChatId;
      Result := I;
      Exit;
    end;
  end;
  SetLength(FFolderOps, Length(FFolderOps) + 1);
  FFolderOps[High(FFolderOps)].FolderId := AFolderId;
  FFolderOps[High(FFolderOps)].ChatId := AChatId;
  Result := High(FFolderOps);
end;

{ TDLib has no removeChatFromList: dropping a chat out of a folder
  means editing the FOLDER, and editChatFolder replaces it whole, so
  the current one has to be fetched first. }
procedure TTdChats.RemoveChatFromFolder(AChatId: Int64; AFolderId: integer);
begin
  if (FReq = nil) or (AChatId = 0) or (AFolderId <= 0) then begin
    Exit;
  end;
  FReq.SendRequest('getChatFolder',
    '"chat_folder_id":' + utf8string(IntToStr(AFolderId)),
    @GetChatFolderDone, AllocFolderOp(AFolderId, AChatId));
end;

procedure TTdChats.GetChatFolderDone(Sender: TObject; const AResp: TTdResponse);
var
  Op: TFolderOp;
  Folder: TJSONObject;
  Body: utf8string;
begin
  if (AResp.Tag < 0) or (AResp.Tag > High(FFolderOps)) then begin
    Exit;
  end;
  Op := FFolderOps[AResp.Tag];
  FFolderOps[AResp.Tag].ChatId := 0;   { slot free again, whatever follows }
  if not AResp.Success then begin
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'folder');
    end;
    Exit;
  end;
  if (FReq = nil) or (Op.ChatId = 0) or (AResp.Obj = nil) then begin
    Exit;
  end;

  { Cloned, not referenced: AResp.Obj is only valid inside this
    callback (see TTdResponse) and SendRequest below is asynchronous.

    Only the two lists that hold a chat in a folder BY NAME are
    touched. The chat is deliberately NOT added to excluded_chat_ids:
    that would make the removal stick even against the folder's own
    filter rules, a bigger and longer-lived change to the user's folder
    than "this chat lives somewhere else now" asked for. A chat the
    folder includes by rule (include_groups and friends) therefore
    stays visible in it — the same thing the official clients do. }
  Folder := AResp.Obj.Clone as TJSONObject;
  try
    StripEnvelope(Folder, 'chatFolder');
    RemoveIdFromArray(Folder, 'pinned_chat_ids', Op.ChatId);
    RemoveIdFromArray(Folder, 'included_chat_ids', Op.ChatId);
    Body := '"chat_folder_id":' + utf8string(IntToStr(Op.FolderId)) +
            ',"folder":' + utf8string(Folder.AsJSON);
  finally
    Folder.Free;
  end;
  FReq.SendRequest('editChatFolder', Body, @ActionDone);
end;

procedure TTdChats.DetachChatFromFolders(ARow: TChatRow; AExceptId: integer);
var
  I: integer;
  Ids: array of integer;
begin
  { The ids are copied out first: each RemoveChatFromFolder is only a
    request, but the reply that eventually shrinks ARow.FolderIds
    arrives through the same update stream this loop is not holding
    still — walking the live array while something else may rewrite it
    is not a risk worth taking to save three lines. }
  SetLength(Ids, Length(ARow.FolderIds));
  for I := 0 to High(ARow.FolderIds) do begin
    Ids[I] := ARow.FolderIds[I];
  end;
  for I := 0 to High(Ids) do begin
    if Ids[I] <> AExceptId then begin
      RemoveChatFromFolder(ARow.Id, Ids[I]);
    end;
  end;
end;

procedure TTdChats.MoveChatToFolder(ARow: TChatRow; AFolderId: integer);
begin
  if (ARow = nil) or (FReq = nil) or (AFolderId <= 0) then begin
    Exit;
  end;
  DetachChatFromFolders(ARow, AFolderId);
  { addChatToList is the cheap half: for a folder list it appends the
    chat to included_chat_ids with no round trip of our own. }
  FReq.SendRequest('addChatToList',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"chat_list":{"@type":"chatListFolder","chat_folder_id":' +
    utf8string(IntToStr(AFolderId)) + '}', @ActionDone);
end;

procedure TTdChats.RemoveChatFromFolders(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  { AExceptId = 0 spares nothing: TDLib assigns no folder that id. }
  DetachChatFromFolders(ARow, 0);
end;

procedure TTdChats.CreateFolderWithChat(const ATitle: utf8string; ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) or (ATitle = '') then begin
    Exit;
  end;
  DetachChatFromFolders(ARow, 0);
  { The reply (a chatFolderInfo) is not parsed: TDLib follows it with a
    fresh updateChatFolders and with the chat's new position, which is
    what actually refreshes the list. ActionDone is still the callback
    so a refusal — a name over 12 characters, or the folder limit —
    gets reported rather than swallowed. }
  FReq.SendRequest('createChatFolder',
    '"folder":' + NewFolderJson(ATitle, ARow.Id), @ActionDone);
end;

{ ---------------- update parsing ---------------- }

procedure TTdChats.ApplyPosition(ARow: TChatRow; APos: TJSONObject);
var
  Ord: Int64;
  Kind: utf8string;
begin
  if (ARow = nil) or (APos = nil) then begin
    Exit;
  end;

  Kind := JGetStr(JGetObj(APos, 'list'), '@type');
  Ord := JGetInt64(APos, 'order');

  { Per the schema: order = 0 means remove from the list. }
  if Kind = 'chatListMain' then begin
    if Ord = 0 then begin
      ARow.InList := False;
      ARow.Order := 0;
      ARow.IsPinned := False;
    end else begin
      ARow.InList := True;
      ARow.Order := Ord;
      ARow.IsPinned := JGetBool(APos, 'is_pinned');
    end;
  end else if Kind = 'chatListArchive' then begin
    if Ord = 0 then begin
      ARow.InArchive := False;
      ARow.ArchiveOrder := 0;
    end else begin
      ARow.InArchive := True;
      ARow.ArchiveOrder := Ord;
    end;
  end else begin
    { A folder position. Order 0 means the same thing here as in the
      two lists above — gone from that folder. ChatListFolderId returns
      -1 for anything that isn't a folder at all, and SetRowFolder
      ignores that. }
    SetRowFolder(ARow, ChatListFolderId(JGetObj(APos, 'list')), Ord <> 0);
  end;
end;

procedure TTdChats.ApplyPositions(ARow: TChatRow; APositions: TJSONArray);
var
  I: integer;
  P: TJSONObject;
  SawMain, SawArchive: boolean;
  Kind: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if APositions = nil then begin
    Exit;
  end;

  SawMain := False;
  SawArchive := False;
  for I := 0 to APositions.Count - 1 do begin
    if APositions.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    P := TJSONObject(APositions.Items[I]);
    Kind := JGetStr(JGetObj(P, 'list'), '@type');
    if Kind = 'chatListMain' then begin
      SawMain := True;
      ApplyPosition(ARow, P);
    end else if Kind = 'chatListArchive' then begin
      SawArchive := True;
      ApplyPosition(ARow, P);
    end else if Kind = 'chatListFolder' then begin
      { Folder entries are applied one at a time and never cleared from
        an ABSENT entry — see TChatRow.FolderIds for why this array
        can't be treated as exhaustive where folders are concerned. }
      ApplyPosition(ARow, P);
    end;
  end;

  { The positions array is exhaustive: a missing list means the chat
    isn't in it at all. }
  if not SawMain then begin
    ARow.InList := False;
    ARow.Order := 0;
    ARow.IsPinned := False;
  end;
  if not SawArchive then begin
    ARow.InArchive := False;
    ARow.ArchiveOrder := 0;
  end;
end;

procedure TTdChats.ApplyPhoto(ARow: TChatRow; APhoto: TJSONObject);
var
  Small: TJSONObject;
  B64: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if APhoto = nil then begin
    ARow.PhotoFileId := 0;
    ARow.PhotoPath := '';
    ARow.Minithumb := '';
    ARow.AvatarRequested := False;
    Exit;
  end;

  Small := JGetObj(APhoto, 'small');
  if ARow.PhotoFileId <> JGetInt(Small, 'id') then begin
    { The photo changed — any earlier request is no longer about this
      file. }
    ARow.AvatarRequested := False;
  end;
  ARow.PhotoFileId := JGetInt(Small, 'id');
  ARow.PhotoPath := JGetStr(JGetObj(Small, 'local'), 'path');

  { minithumbnail arrives right in the update: base64 of a tiny JPEG.
    Nothing to download — the image can be shown immediately. }
  B64 := JGetStr(JGetObj(APhoto, 'minithumbnail'), 'data');
  if B64 <> '' then begin
    try
      ARow.Minithumb := DecodeStringBase64(string(B64));
    except
      ARow.Minithumb := '';
    end;
  end;
end;

procedure TTdChats.ApplyLastMessage(ARow: TChatRow; AMsg: TJSONObject);
var
  St: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if AMsg = nil then begin
    ARow.LastText := '';
    SetLength(ARow.LastGlyphs, 0);
    ARow.LastDate := 0;
    ARow.LastIsOutgoing := False;
    ARow.LastMessageId := 0;
    ARow.LastSending := mssDelivered;
    Exit;
  end;
  ARow.LastText := MessagePreview(JGetObj(AMsg, 'content'), ARow.LastGlyphs);
  ARow.LastDate := JGetInt64(AMsg, 'date');
  ARow.LastIsOutgoing := JGetBool(AMsg, 'is_outgoing');
  ARow.LastMessageId := JGetInt64(AMsg, 'id');

  { sending_state is absent for already-sent messages. }
  St := JGetStr(JGetObj(AMsg, 'sending_state'), '@type');
  if St = 'messageSendingStatePending' then begin
    ARow.LastSending := mssPending;
  end else if St = 'messageSendingStateFailed' then begin
    ARow.LastSending := mssFailed;
  end else begin
    ARow.LastSending := mssDelivered;
  end;
end;

{ chat.emoji_status: an emojiStatus object (type + expiration_date) or
  null. Only emojiStatusTypeCustomEmoji carries an id to render — the
  newer emojiStatusTypeUpgradedGift (a collectible status, no custom
  emoji underneath) is left as "no status" (0), same as null, rather
  than guessing at some other rendering for it. }
procedure TTdChats.ApplyEmojiStatus(ARow: TChatRow; AStatus: TJSONObject);
var
  TypeObj: TJSONObject;
begin
  if ARow = nil then begin
    Exit;
  end;
  ARow.EmojiStatusCustomEmojiId := 0;
  if AStatus = nil then begin
    Exit;
  end;
  TypeObj := JGetObj(AStatus, 'type');
  if JGetStr(TypeObj, '@type') = 'emojiStatusTypeCustomEmoji' then begin
    ARow.EmojiStatusCustomEmojiId := JGetInt64(TypeObj, 'custom_emoji_id');
  end;
end;

{ chat.permissions: a chatPermissions object, always present (never
  null) per the schema — no "missing" case to fall back on, unlike
  ApplyEmojiStatus above. See CanSendBasicMessages' own comment
  (its field declaration) for what this flag does and doesn't cover. }
procedure TTdChats.ApplyPermissions(ARow: TChatRow; APermissions: TJSONObject);
begin
  if (ARow = nil) or (APermissions = nil) then begin
    Exit;
  end;
  ARow.CanSendBasicMessages := JGetBool(APermissions, 'can_send_basic_messages');
end;

procedure TTdChats.ApplyChat(AChat: TJSONObject);
var
  R: TChatRow;
begin
  if AChat = nil then begin
    Exit;
  end;
  R := Obtain(JGetInt64(AChat, 'id'));
  R.Title := JGetStr(AChat, 'title');
  R.Kind := KindFromType(JGetObj(AChat, 'type'));
  R.UserId := ChatUserId(JGetObj(AChat, 'type'));
  R.SupergroupId := ChatSupergroupId(JGetObj(AChat, 'type'));
  R.UnreadCount := JGetInt(AChat, 'unread_count');
  R.UnreadMentionCount := JGetInt(AChat, 'unread_mention_count');
  R.IsMarkedAsUnread := JGetBool(AChat, 'is_marked_as_unread');
  R.LastReadOutbox := JGetInt64(AChat, 'last_read_outbox_message_id');
  R.LastReadInbox := JGetInt64(AChat, 'last_read_inbox_message_id');
  R.AccentColorId := JGetInt(AChat, 'accent_color_id');
  ApplyPermissions(R, JGetObj(AChat, 'permissions'));
  ApplyNotifySettings(R, JGetObj(AChat, 'notification_settings'));
  ApplyPhoto(R, JGetObj(AChat, 'photo'));
  ApplyLastMessage(R, JGetObj(AChat, 'last_message'));
  ApplyEmojiStatus(R, JGetObj(AChat, 'emoji_status'));
  ApplyPositions(R, JGetArr(AChat, 'positions'));
end;

procedure TTdChats.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  T: utf8string;
  R: TChatRow;
begin
  { AData is already parsed by the receive thread (tdrecv.pas) — this
    used to have its own GetJSON, gated behind a cheap Pos-based check
    on the raw string; now parsing happens once for all subscribers, so
    that check is no longer needed. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;
  T := JGetStr(Obj, '@type');

  if T = 'updateNewChat' then begin
      ApplyChat(JGetObj(Obj, 'chat'));
      Touch;
    end else if T = 'updateChatPosition' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPosition(R, JGetObj(Obj, 'position'));
        Touch;
      end;
    end else if T = 'updateChatLastMessage' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyLastMessage(R, JGetObj(Obj, 'last_message'));
        ApplyPositions(R, JGetArr(Obj, 'positions'));
        Touch;
      end;
    end else if T = 'updateChatDraftMessage' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPositions(R, JGetArr(Obj, 'positions'));
        Touch;
      end;
    end else if T = 'updateChatTitle' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.Title := JGetStr(Obj, 'title');
        Touch;
      end;
    end else if T = 'updateChatPhoto' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPhoto(R, JGetObj(Obj, 'photo'));
        Touch;
      end;
    end else if T = 'updateChatNotificationSettings' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyNotifySettings(R, JGetObj(Obj, 'notification_settings'));
        Touch;
      end;
    end else if T = 'updateUser' then begin
      ApplyUser(JGetObj(Obj, 'user'));
    end else if T = 'updateUnreadChatCount' then begin
      ApplyUnreadCount(Obj);
    end else if T = 'updateFile' then begin
      ApplyFile(JGetObj(Obj, 'file'));
      ApplyCustomEmojiFile(JGetObj(Obj, 'file'));
    end else if T = 'updateChatReadOutbox' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.LastReadOutbox := JGetInt64(Obj, 'last_read_outbox_message_id');
        Touch;
      end;
    end else if T = 'updateChatReadInbox' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.UnreadCount := JGetInt(Obj, 'unread_count');
        R.LastReadInbox := JGetInt64(Obj, 'last_read_inbox_message_id');
        Touch;
      end;
    end else if T = 'updateChatAccentColors' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.AccentColorId := JGetInt(Obj, 'accent_color_id');
        Touch;
      end;
    end else if T = 'updateChatEmojiStatus' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyEmojiStatus(R, JGetObj(Obj, 'emoji_status'));
        Touch;
      end;
    end else if T = 'updateChatFolders' then begin
      ApplyChatFolders(JGetArr(Obj, 'chat_folders'));
    end else if T = 'updateChatAddedToList' then begin
      ApplyListMembership(Obj, True);
    end else if T = 'updateChatRemovedFromList' then begin
      ApplyListMembership(Obj, False);
    end else if T = 'updateChatPermissions' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPermissions(R, JGetObj(Obj, 'permissions'));
        Touch;
      end;
    end;
end;

procedure TTdChats.TdStateChanged(AState: TTdAuthState);
begin
  if AState = tasReady then begin
    Clear;
    LoadMore;
    LoadMoreArchive;
  end else if TdIsShuttingState(AState) then begin
    Clear;
    SetLoading(False);
  end;
end;

procedure TTdChats.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors don't concern this model. }
end;

end.
