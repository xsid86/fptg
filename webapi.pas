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
  Classes, SysUtils, SyncObjs, ExtCtrls, base64, fpjson, jsonparser,
  constants, tdchats, tdmessages, tdusers, tdcore, tdrecv, localserver,
  webfiles, autodownload, customemoji;

type
  TWebReq = class
  public
    ConnId:  Int64;
    Payload: utf8string;
  end;

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
    procedure Tick(Sender: TObject);
    procedure Drain;
    procedure EnsureBindings;
    procedure DropBindings;
    procedure ChatsChanged(Sender: TObject);
    procedure MessagesChanged(Sender: TObject);
    procedure PushEvent(const AName: utf8string; AData: TJSONObject);
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
    function  CmdMessagesRead(AArgs: TJSONObject): TJSONData;
    function  CmdMessageSend(AArgs: TJSONObject): TJSONData;
    function  CmdPollVote(AArgs: TJSONObject): TJSONData;
    function  CmdMediaEnsure(AArgs: TJSONObject): TJSONData;
    function  CmdSearchSet(AArgs: TJSONObject): TJSONData;
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

  if Length(ARow.Reactions) > 0 then begin
    Result.Add('reactions', ReactionsJson(ARow.Reactions));
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
end;

destructor TWebApi.Destroy;
var
  I: integer;
begin
  FTimer.Enabled := False;
  FTimer.Free;
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
  inherited Destroy;
end;

{ Subscribes to whichever models the active account currently has.
  Re-checked on every tick rather than bound once: at start-up there is
  no account yet, and switching accounts replaces both objects. }
procedure TWebApi.EnsureBindings;
var
  Chats: TTdChats;
  Msgs: TTdMessages;
begin
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
    end;
  end;

  Msgs := TdMsgList;
  if Msgs <> FBoundMsgs then begin
    FBoundMsgs := Msgs;
    if Msgs <> nil then begin
      Msgs.AddChangeListener(@MessagesChanged);
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
  end;
  FBoundChats := nil;
  if (FBoundMsgs <> nil) and (FBoundMsgs = TdMsgList) then begin
    FBoundMsgs.RemoveChangeListener(@MessagesChanged);
  end;
  FBoundMsgs := nil;
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
    Same split as TFrameHistory.OpenChat. }
  UnreadFrom := 0;
  CRow := Chats.Lookup(ChatId);
  if CRow <> nil then begin
    UnreadFrom := CRow.LastReadInbox;
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
  Res, Emoji: TJSONObject;
  I: integer;
  LastReadOutbox: Int64;
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
  Res.Add('chatId',       Msgs.ChatId);
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
    AArgs.Get('silent', False));
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
      if Cmd = 'ping' then begin
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
        Reply(AConnId, ReqId, CmdChatOpen(Args));
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
        Reply(AConnId, ReqId, CmdMessagesList);
      end else if Cmd = 'messages.older' then begin
        Reply(AConnId, ReqId, CmdMessagesOlder);
      end else if Cmd = 'messages.read' then begin
        Reply(AConnId, ReqId, CmdMessagesRead(Args));
      end else if Cmd = 'message.send' then begin
        Reply(AConnId, ReqId, CmdMessageSend(Args));
      end else if Cmd = 'poll.vote' then begin
        Reply(AConnId, ReqId, CmdPollVote(Args));
      end else if Cmd = 'media.ensure' then begin
        Reply(AConnId, ReqId, CmdMediaEnsure(Args));
      end else if Cmd = 'search.set' then begin
        Reply(AConnId, ReqId, CmdSearchSet(Args));
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
