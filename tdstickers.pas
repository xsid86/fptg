unit tdstickers;

{$mode objfpc}{$H+}

{ What the emoji/sticker/GIF panel in the web UI draws from: the
  account's recently used stickers, its installed sticker sets, and its
  saved animations.

  A model of its own rather than more fields on TTdMessages, for the
  reason that model is already the biggest unit here: none of this
  belongs to a chat. It survives switching chats, it is fetched once
  per account, and its only consumer is a panel that may never be
  opened at all — which is also why nothing here runs until somebody
  asks (EnsureLoaded).

  TWO LEVELS OF LAZINESS, both deliberate:
    - the set LIST arrives up front (titles only, one request),
    - a set's STICKERS, and their files, only when the panel actually
      shows that set (EnsureSet).
  An account with forty installed sets is ordinary, and forty sets of
  a hundred stickers each is several hundred megabytes. The official
  clients page it the same way.

  GIFs show their THUMBNAIL, not the animation: a saved-animation list
  is routinely a couple of hundred entries and the animation itself is
  the whole file. The thumbnail is either an mpeg4 (which the page
  plays, so the preview moves like the original client's) or a still
  jpeg/webp. The animation itself is only ever fetched by Telegram —
  sending one needs no local copy at all, just the file id.

  Everything here was checked against td_api.tl AT THE VERSION IN USE
  (1.8.67, from the log's own updateOption), not against master: the
  shape of inputMessageSticker in particular has changed more than
  once, and master's is not this one. }

interface

uses
  Classes, SysUtils, fgl, fpjson,
  tdauth, tdsession, tdreq, tdmessages;

const
  { getStickers/getInlineQueryResults both cap what they will return;
    a panel shows far less than this at once anyway. }
  STICKER_SEARCH_LIMIT = 100;

type
  { One sticker, the panel's unit of display. Format is tdmessages'
    own enum — a sticker in a set and a sticker in a message are the
    same thing, and a second enum for it would be one more place to
    keep in step. }
  TStickerItem = class
  public
    FileId: integer;
    Format: TStickerFormat;
    Emoji: utf8string;
    Width, Height: integer;
    LocalPath: utf8string;
    Requested: boolean;
    { Non-zero only for a CUSTOM emoji: the id a reaction or a text
      entity names it by. A full Int64, so it travels to the page as
      text like every other id here. }
    CustomEmojiId: Int64;
  end;

  TStickerItemList = specialize TFPGObjectList<TStickerItem>;

  TStickerSetRow = class
  public
    Id: Int64;
    Title: utf8string;
    Items: TStickerItemList;
    { One sticker out of stickerSetInfo.covers, kept so a set can be
      drawn as itself before anything inside it has been asked for.
      Without it a set's button in the panel has only its title to show
      and ends up wearing a letter. Owned here. }
    Cover: TStickerItem;
    { Requested = a getStickerSet is in flight, Loaded = its answer
      came back. Both false is the ordinary state of a set nobody has
      scrolled to yet. }
    Requested, Loaded: boolean;
    { Every sticker's FILE has been asked for, not just the first.
      Kept apart from Loaded because for custom emoji the two happen
      at very different times: the list of stickers arrives for every
      set at once (there is no other way to know what a set looks
      like), while the files only arrive for the set actually being
      looked at. }
    FilesWanted: boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TStickerSetList = specialize TFPGObjectList<TStickerSetRow>;

  TGifItem = class
  public
    FileId: integer;
    ThumbFileId: integer;
    { thumbnailFormat*, lowercased: 'mpeg4' plays, anything else is a
      still. Empty when the animation came without a thumbnail. }
    ThumbFormat: utf8string;
    Width, Height, Duration: integer;
    ThumbPath: utf8string;
    ThumbRequested: boolean;
    { The animation itself, fetched only for the entries whose
      thumbnail does not move - see EnsureGif. }
    Path: utf8string;
    Requested: boolean;
    { Non-empty only for a GIF found through the inline bot: such a
      result is sent by naming it back to Telegram
      (sendInlineQueryResultMessage), not by its file id - the file is
      not the account's own saved animation. }
    ResultId: utf8string;
  end;

  TGifList = specialize TFPGObjectList<TGifItem>;

  TTdStickersEvent = procedure(Sender: TObject) of object;

  { TTdStickers

    Owned by TTdAccount like every other model, and reachable through
    tdcore's TdStickerList for whoever has no account in hand. }
  TTdStickers = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq: TTdRequests;
    FRecent: TStickerItemList;
    FSets: TStickerSetList;
    { The account's installed CUSTOM emoji sets - the same shape as
      sticker sets, because that is exactly what they are: sets whose
      stickers carry a custom_emoji_id. Kept apart because they answer
      a different question (which emoji may I react with) and are
      fetched only when something asks. }
    FEmojiSets: TStickerSetList;
    FEmojiAsked: boolean;
    FEmojiReady: boolean;
    FGifs: TGifList;
    FAsked: boolean;

    { --- sticker search (getStickers over the installed sets) --- }
    FFoundStickers: TStickerItemList;
    FStickerQuery: utf8string;
    { Tagged on the request and checked on the way back: a slow answer
      for a query the user has already typed past must not land. }
    FStickerSeq: integer;
    FStickerReady: boolean;

    { --- GIF search (the inline bot Telegram names for it) --- }
    FFoundGifs: TGifList;
    FGifQuery: utf8string;
    FGifSeq: integer;
    FGifReady: boolean;
    { Both needed to send a found GIF back. }
    FGifQueryId: Int64;
    FGifBotName: utf8string;
    FGifBotId: Int64;
    { A query typed before the bot had been resolved, run as soon as
      it has been. Only the last one is worth keeping. }
    FGifPending: utf8string;
    { Whether the first answer for each list has come back. An empty
      list means two very different things before and after that, and
      the panel has to be able to say "loading" rather than "you have
      no stickers" to somebody who has plenty. }
    FSetsReady, FGifsReady: boolean;
    FOnChanged: TTdStickersEvent;

    procedure Touch;
    function ReadSticker(AObj: TJSONObject; ACustom: boolean = False): TStickerItem;
    function EmojiSetById(AId: Int64): TStickerSetRow;
    procedure RequestEmojiSet(ARow: TStickerSetRow);
    procedure EmojiSetsDone(Sender: TObject; const AResp: TTdResponse);
    procedure EmojiSetDone(Sender: TObject; const AResp: TTdResponse);
    procedure WantFile(AFileId: integer; var ARequested: boolean);
    procedure ApplyFile(AFile: TJSONObject);
    function SetById(AId: Int64): TStickerSetRow;

    function ReadAnimation(AObj: TJSONObject): TGifItem;
    procedure RunGifQuery;
    procedure FillFoundStickers(AArr: TJSONArray);
    procedure StickersFoundDone(Sender: TObject; const AResp: TTdResponse);
    procedure EmojisFoundDone(Sender: TObject; const AResp: TTdResponse);
    procedure PublicStickersDone(Sender: TObject; const AResp: TTdResponse);
    procedure GifOptionDone(Sender: TObject; const AResp: TTdResponse);
    procedure GifBotDone(Sender: TObject; const AResp: TTdResponse);
    procedure GifsFoundDone(Sender: TObject; const AResp: TTdResponse);
    procedure SetsDone(Sender: TObject; const AResp: TTdResponse);
    procedure SetDone(Sender: TObject; const AResp: TTdResponse);
    procedure RecentDone(Sender: TObject; const AResp: TTdResponse);
    procedure GifsDone(Sender: TObject; const AResp: TTdResponse);
    procedure DownloadDone(Sender: TObject; const AResp: TTdResponse);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;

    { First call fetches the recent stickers, the list of installed
      sets and the saved animations; later calls do nothing. The
      answers arrive asynchronously and announce themselves through
      OnChanged, the same contract every other model here has. }
    procedure EnsureLoaded;

    { Fetches one set's stickers and starts downloading their files.
      Called when the panel shows that set, not before. }
    procedure EnsureSet(AId: Int64);

    { The same two steps for the account's installed CUSTOM emoji: the
      list of sets up front, one set's emoji when the panel scrolls to
      it. Separate from EnsureLoaded because the emoji panel and the
      sticker panel are different panels and either may never open. }
    procedure EnsureEmojiSets;
    procedure EnsureEmojiSet(AId: Int64);

    { Fetches the animation ITSELF for one saved GIF.

      Needed because only about half of them have a thumbnail that
      moves: measured on a real account, 134 saved animations came back
      with 68 mpeg4 thumbnails, 60 still jpegs and 6 with no thumbnail
      at all. A still frame is what the panel can show for free; for
      the rest the file is the only way to get a moving preview, which
      is what the official clients fetch too.

      Called per tile, as it scrolls into view - the same laziness
      EnsureSet has, and for the same reason: these are whole video
      files, and there can be hundreds of them. }
    procedure EnsureGif(AFileId: integer);

    { Searching.

      Stickers go through getStickers, which answers from the
      account's OWN installed sets (plus favourites, recents and
      trending) and takes either emoji or a keyword prefix - which is
      what a sticker panel's search means everywhere.

      GIFs have no such call: Telegram searches them with an inline
      BOT, whose username it names in the option
      animation_search_bot_username ("gif" on this account, read out
      of the option rather than written in here). So the first search
      of a session costs two extra round trips - the option, then
      searchPublicChat to turn the name into a user id - and every one
      after that is a single getInlineQueryResults.

      Both are no-ops when the query has not changed. An empty query
      means "no search", and the panel goes back to the ordinary
      lists. Results arrive asynchronously, through OnChanged. }
    procedure SearchStickers(const AQuery: utf8string);
    procedure SearchGifs(const AQuery: utf8string);

    { Finds a sticker by file id across the recent list and every
      loaded set — what the send path needs, since the page names a
      sticker by its file id and nothing else. Nil when unknown. }
    function FindSticker(AFileId: integer): TStickerItem;
    function FindGif(AFileId: integer): TGifItem;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property EmojiSets: TStickerSetList read FEmojiSets;
    property EmojiSetsReady: boolean read FEmojiReady;
    property SetsReady: boolean read FSetsReady;
    property GifsReady: boolean read FGifsReady;
    { What the last search asked for, what it found, and whether its
      answer has arrived. An empty query means the panel is showing
      the ordinary lists and these say nothing. }
    property StickerQuery: utf8string read FStickerQuery;
    property GifQuery: utf8string read FGifQuery;
    property StickerSearchReady: boolean read FStickerReady;
    property GifSearchReady: boolean read FGifReady;
    property FoundStickers: TStickerItemList read FFoundStickers;
    property FoundGifs: TGifList read FFoundGifs;
    { The inline query the found GIFs belong to - half of what naming
      one back to Telegram takes. }
    property GifQueryId: Int64 read FGifQueryId;
    property Recent: TStickerItemList read FRecent;
    property Sets: TStickerSetList read FSets;
    property Gifs: TGifList read FGifs;
    property OnChanged: TTdStickersEvent read FOnChanged write FOnChanged;
  end;

implementation

{ ---------------- TStickerSetRow ---------------- }

constructor TStickerSetRow.Create;
begin
  inherited Create;
  Items := TStickerItemList.Create(True);
end;

destructor TStickerSetRow.Destroy;
begin
  Items.Free;
  Cover.Free;
  inherited Destroy;
end;

{ ---------------- TTdStickers ---------------- }

constructor TTdStickers.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FRecent := TStickerItemList.Create(True);
  FSets := TStickerSetList.Create(True);
  FEmojiSets := TStickerSetList.Create(True);
  FGifs := TGifList.Create(True);
  FFoundStickers := TStickerItemList.Create(True);
  FFoundGifs := TGifList.Create(True);

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdStickers.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  FRecent.Free;
  FSets.Free;
  FEmojiSets.Free;
  FGifs.Free;
  FFoundStickers.Free;
  FFoundGifs.Free;
  inherited Destroy;
end;

procedure TTdStickers.Clear;
begin
  FRecent.Clear;
  FSets.Clear;
  FEmojiSets.Clear;
  FEmojiAsked := False;
  FEmojiReady := False;
  FGifs.Clear;
  FFoundStickers.Clear;
  FFoundGifs.Clear;
  FAsked := False;
  FSetsReady := False;
  FGifsReady := False;
  FStickerQuery := '';
  FGifQuery := '';
  FStickerReady := False;
  FGifReady := False;
  FGifQueryId := 0;
  FGifPending := '';
  { The bot id is NOT cleared: it belongs to the account, not to a
    search, and resolving it again costs two round trips. }
end;

procedure TTdStickers.Touch;
begin
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

{ ---------------- reading ---------------- }

{ One td_api sticker. The file may already be on disk — TDLib's cache
  survives restarts, and a set looked at yesterday comes back with
  every path filled in, so this is the common case rather than the
  exception.

  is_downloading_completed is the ONLY field that says the bytes are
  there: a path is present even for a file TDLib has merely reserved a
  name for, and for one whose bytes have since been evicted. The same
  trap TMsgRow's Apply*File handlers document at length. }
{ ACustom says WHICH kind of sticker is wanted, and the two are
  mutually exclusive: a custom emoji is not something to send as a
  message, and an ordinary sticker has no id to react with. Asking for
  the wrong kind answers nil rather than half an item. }
function TTdStickers.ReadSticker(AObj: TJSONObject; ACustom: boolean): TStickerItem;
var
  FileObj, LocalObj, FullType: TJSONObject;
  FormatStr: utf8string;
  IsCustom: boolean;
begin
  Result := nil;
  if AObj = nil then begin
    Exit;
  end;

  FullType := JGetObj(AObj, 'full_type');
  IsCustom := JGetStr(FullType, '@type') = 'stickerFullTypeCustomEmoji';
  if IsCustom <> ACustom then begin
    Exit;
  end;

  FileObj := JGetObj(AObj, 'sticker');
  if FileObj = nil then begin
    Exit;
  end;

  Result := TStickerItem.Create;
  Result.FileId := JGetInt(FileObj, 'id');
  Result.Emoji := JGetStr(AObj, 'emoji');
  if IsCustom then begin
    { As text in the JSON TDLib sends, because it is an int64. }
    Result.CustomEmojiId := StrToInt64Def(JGetStr(FullType, 'custom_emoji_id'), 0);
  end;
  Result.Width := JGetInt(AObj, 'width');
  Result.Height := JGetInt(AObj, 'height');

  FormatStr := JGetStr(JGetObj(AObj, 'format'), '@type');
  if FormatStr = 'stickerFormatTgs' then begin
    Result.Format := sfTgs;
  end else if FormatStr = 'stickerFormatWebm' then begin
    Result.Format := sfWebm;
  end else begin
    Result.Format := sfWebp;
  end;

  LocalObj := JGetObj(FileObj, 'local');
  if JGetBool(LocalObj, 'is_downloading_completed') then begin
    Result.LocalPath := JGetStr(LocalObj, 'path');
  end;
end;

{ Starts a download unless the file is already on its way. Open-ended
  (limit 0): a sticker is tens of kilobytes, and the byte-window pacing
  TTdMessages does for photos and video would only add latency here. }
procedure TTdStickers.WantFile(AFileId: integer; var ARequested: boolean);
begin
  if (FReq = nil) or (AFileId = 0) or ARequested then begin
    Exit;
  end;
  ARequested := True;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(AFileId)) +
    ',"priority":16,"offset":0,"limit":0,"synchronous":false',
    @DownloadDone, PtrInt(AFileId));
end;

function TTdStickers.SetById(AId: Int64): TStickerSetRow;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to FSets.Count - 1 do begin
    if FSets[I].Id = AId then begin
      Result := FSets[I];
      Exit;
    end;
  end;
end;

function TTdStickers.FindSticker(AFileId: integer): TStickerItem;
var
  I, J: integer;
begin
  Result := nil;
  for I := 0 to FFoundStickers.Count - 1 do begin
    if FFoundStickers[I].FileId = AFileId then begin
      Result := FFoundStickers[I];
      Exit;
    end;
  end;
  for I := 0 to FRecent.Count - 1 do begin
    if FRecent[I].FileId = AFileId then begin
      Result := FRecent[I];
      Exit;
    end;
  end;
  for I := 0 to FSets.Count - 1 do begin
    for J := 0 to FSets[I].Items.Count - 1 do begin
      if FSets[I].Items[J].FileId = AFileId then begin
        Result := FSets[I].Items[J];
        Exit;
      end;
    end;
  end;
end;

function TTdStickers.FindGif(AFileId: integer): TGifItem;
var
  I: integer;
begin
  Result := nil;
  { Search results first: a GIF can be in both lists, and the found
    copy is the one that carries the result id needed to send it. }
  for I := 0 to FFoundGifs.Count - 1 do begin
    if FFoundGifs[I].FileId = AFileId then begin
      Result := FFoundGifs[I];
      Exit;
    end;
  end;
  for I := 0 to FGifs.Count - 1 do begin
    if FGifs[I].FileId = AFileId then begin
      Result := FGifs[I];
      Exit;
    end;
  end;
end;

{ ---------------- fetching ---------------- }

procedure TTdStickers.EnsureLoaded;
begin
  if FAsked or (FReq = nil) then begin
    Exit;
  end;
  FAsked := True;
  FReq.SendRequest('getRecentStickers', '"is_attached":false', @RecentDone);
  FReq.SendRequest('getInstalledStickerSets',
    '"sticker_type":{"@type":"stickerTypeRegular"}', @SetsDone);
  FReq.SendRequest('getSavedAnimations', '', @GifsDone);
end;

function TTdStickers.EmojiSetById(AId: Int64): TStickerSetRow;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to FEmojiSets.Count - 1 do begin
    if FEmojiSets[I].Id = AId then begin
      Result := FEmojiSets[I];
      Exit;
    end;
  end;
end;

procedure TTdStickers.EnsureEmojiSets;
begin
  if FEmojiAsked or (FReq = nil) then begin
    Exit;
  end;
  FEmojiAsked := True;
  FReq.SendRequest('getInstalledStickerSets',
    '"sticker_type":{"@type":"stickerTypeCustomEmoji"}', @EmojiSetsDone);
end;

{ The set is being looked at, so now its files are worth having.

  Separate from RequestEmojiSet, which only asks what is IN a set:
  that happens for every set as soon as the list is known, because a
  set cannot be drawn without it. This is the expensive half, and it
  happens for one set at a time. }
procedure TTdStickers.EnsureEmojiSet(AId: Int64);
var
  Row: TStickerSetRow;
  I: integer;
begin
  Row := EmojiSetById(AId);
  if (Row = nil) or Row.FilesWanted then begin
    Exit;
  end;
  Row.FilesWanted := True;
  { Not loaded yet means the list is still on its way; EmojiSetDone
    sees FilesWanted and fetches the files as it fills the set. }
  if not Row.Loaded then begin
    RequestEmojiSet(Row);
    Exit;
  end;
  for I := 0 to Row.Items.Count - 1 do begin
    if Row.Items[I].LocalPath = '' then begin
      WantFile(Row.Items[I].FileId, Row.Items[I].Requested);
    end;
  end;
end;

procedure TTdStickers.EmojiSetsDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr, Covers: TJSONArray;
  I: integer;
  Info: TJSONObject;
  Row: TStickerSetRow;
begin
  if not AResp.Success then begin
    FEmojiReady := True;
    Touch;
    Exit;
  end;
  FEmojiReady := True;
  FEmojiSets.Clear;
  Arr := JGetArr(AResp.Obj, 'sets');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Info := TJSONObject(Arr.Items[I]);
      Row := TStickerSetRow.Create;
      Row.Id := JGetInt64(Info, 'id');
      Row.Title := JGetStr(Info, 'title');
      { stickerSetInfo has a `covers` field meant for exactly this, and
        for custom emoji sets it is EMPTY - measured on a live account:
        all 28 installed sets came back with "covers":[] and no
        thumbnail either. So a set cannot be drawn from its own
        listing, and the only way to know what one looks like is to
        fetch it. }
      Covers := JGetArr(Info, 'covers');
      if (Covers <> nil) and (Covers.Count > 0)
         and (Covers.Items[0] is TJSONObject) then begin
        Row.Cover := ReadSticker(TJSONObject(Covers.Items[0]), True);
        if (Row.Cover <> nil) and (Row.Cover.LocalPath = '') then begin
          WantFile(Row.Cover.FileId, Row.Cover.Requested);
        end;
      end;
      FEmojiSets.Add(Row);
    end;
  end;
  Touch;

  { So every set is fetched, right away - but only its LIST of
    stickers. The files behind them stay untouched except for the
    first of each, which is what the panel's strip draws the set with.
    Metadata for a couple of dozen sets is a few hundred kilobytes of
    JSON out of TDLib's own database; the files would be thousands of
    downloads. }
  for I := 0 to FEmojiSets.Count - 1 do begin
    RequestEmojiSet(FEmojiSets[I]);
  end;
end;

procedure TTdStickers.RequestEmojiSet(ARow: TStickerSetRow);
begin
  if (ARow = nil) or ARow.Requested or (FReq = nil) then begin
    Exit;
  end;
  ARow.Requested := True;
  FReq.SendRequest('getStickerSet',
    '"set_id":' + utf8string(IntToStr(ARow.Id)), @EmojiSetDone);
end;

procedure TTdStickers.EmojiSetDone(Sender: TObject; const AResp: TTdResponse);
var
  Row: TStickerSetRow;
  Arr: TJSONArray;
  I: integer;
  Item: TStickerItem;
begin
  if not AResp.Success then begin
    Exit;
  end;
  Row := EmojiSetById(JGetInt64(AResp.Obj, 'id'));
  if Row = nil then begin
    Exit;
  end;
  Row.Loaded := True;
  Row.Items.Clear;
  Arr := JGetArr(AResp.Obj, 'stickers');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Item := ReadSticker(TJSONObject(Arr.Items[I]), True);
      if Item = nil then begin
        Continue;
      end;
      Row.Items.Add(Item);
      { The first one's file, always: it is the set's own picture in
        the panel's strip, and without it the button has nothing to
        wear but a letter. The rest wait for the set to be opened. }
      if (Row.Items.Count = 1) or Row.FilesWanted then begin
        if Item.LocalPath = '' then begin
          WantFile(Item.FileId, Item.Requested);
        end;
      end;
    end;
  end;
  Touch;
end;

procedure TTdStickers.EnsureSet(AId: Int64);
var
  Row: TStickerSetRow;
begin
  Row := SetById(AId);
  if (Row = nil) or Row.Requested or (FReq = nil) then begin
    Exit;
  end;
  Row.Requested := True;
  FReq.SendRequest('getStickerSet', '"set_id":' + utf8string(IntToStr(AId)),
    @SetDone);
end;

procedure TTdStickers.EnsureGif(AFileId: integer);
var
  G: TGifItem;
begin
  G := FindGif(AFileId);
  if (G = nil) or (G.Path <> '') then begin
    Exit;
  end;
  WantFile(G.FileId, G.Requested);
end;

procedure TTdStickers.SetsDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  Info: TJSONObject;
  Row: TStickerSetRow;
begin
  if not AResp.Success then begin
    Exit;
  end;
  FSetsReady := True;
  FSets.Clear;
  Arr := JGetArr(AResp.Obj, 'sets');
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if not (Arr.Items[I] is TJSONObject) then begin
      Continue;
    end;
    Info := TJSONObject(Arr.Items[I]);
    Row := TStickerSetRow.Create;
    Row.Id := JGetInt64(Info, 'id');
    Row.Title := JGetStr(Info, 'title');
    FSets.Add(Row);
  end;
  Touch;
end;

procedure TTdStickers.SetDone(Sender: TObject; const AResp: TTdResponse);
var
  Row: TStickerSetRow;
  Arr: TJSONArray;
  I: integer;
  Item: TStickerItem;
begin
  if not AResp.Success then begin
    Exit;
  end;
  { Found by the id in the ANSWER rather than by a tag: getStickerSet
    echoes the set back in full, and a set that has since been
    uninstalled simply does not match anything here. }
  Row := SetById(JGetInt64(AResp.Obj, 'id'));
  if Row = nil then begin
    Exit;
  end;
  Row.Loaded := True;
  Row.Items.Clear;
  Arr := JGetArr(AResp.Obj, 'stickers');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Item := ReadSticker(TJSONObject(Arr.Items[I]));
      if Item = nil then begin
        Continue;
      end;
      Row.Items.Add(Item);
      if Item.LocalPath = '' then begin
        WantFile(Item.FileId, Item.Requested);
      end;
    end;
  end;
  Touch;
end;

procedure TTdStickers.RecentDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  Item: TStickerItem;
begin
  if not AResp.Success then begin
    Exit;
  end;
  FRecent.Clear;
  Arr := JGetArr(AResp.Obj, 'stickers');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Item := ReadSticker(TJSONObject(Arr.Items[I]));
      if Item = nil then begin
        Continue;
      end;
      FRecent.Add(Item);
      if Item.LocalPath = '' then begin
        WantFile(Item.FileId, Item.Requested);
      end;
    end;
  end;
  Touch;
end;

{ One td_api animation - from getSavedAnimations or from an inline
  query, which carry the very same object. Nil when it has no file. }
function TTdStickers.ReadAnimation(AObj: TJSONObject): TGifItem;
var
  ThumbObj, FileObj, LocalObj: TJSONObject;
  Fmt: utf8string;
begin
  Result := nil;
  if AObj = nil then begin
    Exit;
  end;
  FileObj := JGetObj(AObj, 'animation');
  if FileObj = nil then begin
    Exit;
  end;

  Result := TGifItem.Create;
  Result.FileId := JGetInt(FileObj, 'id');
  Result.Width := JGetInt(AObj, 'width');
  Result.Height := JGetInt(AObj, 'height');
  Result.Duration := JGetInt(AObj, 'duration');
  { A GIF just sent, or one opened before, is already on disk - then
    the panel gets a moving preview without asking for anything. }
  LocalObj := JGetObj(FileObj, 'local');
  if JGetBool(LocalObj, 'is_downloading_completed') then begin
    Result.Path := JGetStr(LocalObj, 'path');
  end;

  ThumbObj := JGetObj(AObj, 'thumbnail');
  if ThumbObj <> nil then begin
    Fmt := JGetStr(JGetObj(ThumbObj, 'format'), '@type');
    { thumbnailFormatMpeg4 -> 'mpeg4'. Taken off the constructor name
      rather than mapped by hand: the only thing the page has to
      decide is whether the preview moves. }
    if Length(Fmt) > Length('thumbnailFormat') then begin
      Result.ThumbFormat := LowerCase(Copy(Fmt, Length('thumbnailFormat') + 1,
        Length(Fmt)));
    end;
    FileObj := JGetObj(ThumbObj, 'file');
    Result.ThumbFileId := JGetInt(FileObj, 'id');
    LocalObj := JGetObj(FileObj, 'local');
    if JGetBool(LocalObj, 'is_downloading_completed') then begin
      Result.ThumbPath := JGetStr(LocalObj, 'path');
    end;
  end;
end;

procedure TTdStickers.GifsDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  Item: TGifItem;
begin
  if not AResp.Success then begin
    Exit;
  end;
  FGifsReady := True;
  FGifs.Clear;
  Arr := JGetArr(AResp.Obj, 'animations');
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if not (Arr.Items[I] is TJSONObject) then begin
      Continue;
    end;
    Item := ReadAnimation(TJSONObject(Arr.Items[I]));
    if Item = nil then begin
      Continue;
    end;
    FGifs.Add(Item);
    if (Item.ThumbFileId <> 0) and (Item.ThumbPath = '') then begin
      WantFile(Item.ThumbFileId, Item.ThumbRequested);
    end;
  end;
  Touch;
end;

{ ---------------- searching ---------------- }

procedure TTdStickers.SearchStickers(const AQuery: utf8string);
var
  Q: TJSONString;
begin
  if AQuery = FStickerQuery then begin
    Exit;
  end;
  FStickerQuery := AQuery;
  FFoundStickers.Clear;
  FStickerReady := False;
  Inc(FStickerSeq);
  if (AQuery = '') or (FReq = nil) then begin
    Touch;
    Exit;
  end;

  { getStickers, not searchStickers: this is the account's OWN
    installed sets (plus favourites, recents and trending), which is
    what a panel's search box means. searchStickers looks through
    PUBLIC sets and only by emoji - a different feature, not this one. }
  Q := TJSONString.Create(string(AQuery));
  try
    FReq.SendRequest('getStickers',
      '"sticker_type":{"@type":"stickerTypeRegular"}' +
      ',"query":' + utf8string(Q.AsJSON) +
      ',"limit":' + utf8string(IntToStr(STICKER_SEARCH_LIMIT)) +
      ',"chat_id":0',
      @StickersFoundDone, PtrInt(FStickerSeq));
  finally
    Q.Free;
  end;
end;

procedure TTdStickers.FillFoundStickers(AArr: TJSONArray);
var
  I: integer;
  Item: TStickerItem;
begin
  FFoundStickers.Clear;
  if AArr = nil then begin
    Exit;
  end;
  for I := 0 to AArr.Count - 1 do begin
    if not (AArr.Items[I] is TJSONObject) then begin
      Continue;
    end;
    Item := ReadSticker(TJSONObject(AArr.Items[I]));
    if Item = nil then begin
      Continue;
    end;
    FFoundStickers.Add(Item);
    if Item.LocalPath = '' then begin
      WantFile(Item.FileId, Item.Requested);
    end;
  end;
end;

{ The answer from the account's OWN sets. When it is empty the search
  is not over: the official clients then look through PUBLIC sets, and
  that takes a detour, because searchStickers is keyed on EMOJI rather
  than on words. So a typed word is first turned into emoji
  (searchEmojis, Telegram's own keyword table - "mask" -> the mask
  emoji), and those are what the public sets are searched by.

  FStickerReady stays false across the whole chain: it is what tells
  the panel to say "loading" rather than "nothing found", and saying
  "nothing found" between two legs of one search would be a lie. }
procedure TTdStickers.StickersFoundDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  Q: TJSONString;
begin
  { A slow answer for a query the user has already typed past must not
    land on the query they are looking at now. }
  if integer(AResp.Tag) <> FStickerSeq then begin
    Exit;
  end;
  if not AResp.Success then begin
    FStickerReady := True;
    Touch;
    Exit;
  end;

  Arr := JGetArr(AResp.Obj, 'stickers');
  if (Arr <> nil) and (Arr.Count > 0) then begin
    FStickerReady := True;
    FillFoundStickers(Arr);
    Touch;
    Exit;
  end;

  if (FStickerQuery = '') or (FReq = nil) then begin
    FStickerReady := True;
    Touch;
    Exit;
  end;
  Q := TJSONString.Create(string(FStickerQuery));
  try
    FReq.SendRequest('searchEmojis',
      '"text":' + utf8string(Q.AsJSON) + ',"input_language_codes":[]',
      @EmojisFoundDone, PtrInt(FStickerSeq));
  finally
    Q.Free;
  end;
end;

procedure TTdStickers.EmojisFoundDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  Emojis, One: utf8string;
  Q: TJSONString;
begin
  if integer(AResp.Tag) <> FStickerSeq then begin
    Exit;
  end;
  Emojis := '';
  if AResp.Success then begin
    Arr := JGetArr(AResp.Obj, 'emoji_keywords');
    if Arr <> nil then begin
      for I := 0 to Arr.Count - 1 do begin
        if not (Arr.Items[I] is TJSONObject) then begin
          Continue;
        end;
        One := JGetStr(TJSONObject(Arr.Items[I]), 'emoji');
        { Space-separated, and only the ones not already in the list -
          the keyword table repeats an emoji once per matching word. }
        if (One = '') or (Pos(One, Emojis) > 0) then begin
          Continue;
        end;
        if Emojis <> '' then begin
          Emojis := Emojis + ' ';
        end;
        Emojis := Emojis + One;
      end;
    end;
  end;

  if (Emojis = '') or (FReq = nil) then begin
    { Nothing to search public sets BY. That is a real "nothing
      found", not a failure. }
    FStickerReady := True;
    Touch;
    Exit;
  end;

  Q := TJSONString.Create(string(Emojis));
  try
    FReq.SendRequest('searchStickers',
      '"sticker_type":{"@type":"stickerTypeRegular"}' +
      ',"emojis":' + utf8string(Q.AsJSON) +
      ',"query":""' +
      ',"input_language_codes":[],"offset":0' +
      ',"limit":' + utf8string(IntToStr(STICKER_SEARCH_LIMIT)),
      @PublicStickersDone, PtrInt(FStickerSeq));
  finally
    Q.Free;
  end;
end;

procedure TTdStickers.PublicStickersDone(Sender: TObject; const AResp: TTdResponse);
begin
  if integer(AResp.Tag) <> FStickerSeq then begin
    Exit;
  end;
  FStickerReady := True;
  if AResp.Success then begin
    FillFoundStickers(JGetArr(AResp.Obj, 'stickers'));
  end;
  Touch;
end;

procedure TTdStickers.SearchGifs(const AQuery: utf8string);
begin
  if AQuery = FGifQuery then begin
    Exit;
  end;
  FGifQuery := AQuery;
  FFoundGifs.Clear;
  FGifReady := False;
  FGifQueryId := 0;
  Inc(FGifSeq);
  if (AQuery = '') or (FReq = nil) then begin
    Touch;
    Exit;
  end;

  if FGifBotId <> 0 then begin
    RunGifQuery;
    Exit;
  end;

  { The bot has to be resolved first, and that is two round trips. The
    query waits; only the last one typed is worth keeping. }
  if FGifPending <> '' then begin
    FGifPending := AQuery;
    Exit;
  end;
  FGifPending := AQuery;
  if FGifBotName = '' then begin
    FReq.SendRequest('getOption', '"name":"animation_search_bot_username"',
      @GifOptionDone);
  end else begin
    FReq.SendRequest('searchPublicChat',
      '"username":"' + FGifBotName + '"', @GifBotDone);
  end;
end;

procedure TTdStickers.GifOptionDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    FGifBotName := JGetStr(AResp.Obj, 'value');
  end;
  if (FGifBotName = '') or (FReq = nil) then begin
    { No bot, no GIF search. Saying so beats leaving the panel on
      "Loading" for ever. }
    FGifPending := '';
    FGifReady := True;
    Touch;
    Exit;
  end;
  FReq.SendRequest('searchPublicChat', '"username":"' + FGifBotName + '"',
    @GifBotDone);
end;

procedure TTdStickers.GifBotDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    { searchPublicChat answers with a CHAT. For a private chat the
      chat id and the user id are the same number, but the user id is
      what getInlineQueryResults wants, so it is read from the type
      rather than assumed from the chat. }
    FGifBotId := JGetInt64(JGetObj(AResp.Obj, 'type'), 'user_id');
  end;
  if FGifBotId = 0 then begin
    FGifPending := '';
    FGifReady := True;
    Touch;
    Exit;
  end;
  RunGifQuery;
end;

procedure TTdStickers.RunGifQuery;
var
  Q: TJSONString;
  Query: utf8string;
begin
  Query := FGifQuery;
  FGifPending := '';
  if (Query = '') or (FGifBotId = 0) or (FReq = nil) then begin
    Exit;
  end;
  Q := TJSONString.Create(string(Query));
  try
    FReq.SendRequest('getInlineQueryResults',
      '"bot_user_id":' + utf8string(IntToStr(FGifBotId)) +
      ',"chat_id":0' +
      ',"query":' + utf8string(Q.AsJSON) +
      ',"offset":""',
      @GifsFoundDone, PtrInt(FGifSeq));
  finally
    Q.Free;
  end;
end;

procedure TTdStickers.GifsFoundDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  Obj: TJSONObject;
  Item: TGifItem;
begin
  if integer(AResp.Tag) <> FGifSeq then begin
    Exit;
  end;
  if not AResp.Success then begin
    { An inline bot can refuse, and a refusal is an answer: the panel
      says "nothing found" rather than waiting. }
    FGifReady := True;
    Touch;
    Exit;
  end;
  FGifReady := True;
  FFoundGifs.Clear;
  { int64 travels as TEXT in td_api's JSON - the same rule album ids
    and custom emoji ids already taught this project. }
  FGifQueryId := StrToInt64Def(JGetStr(AResp.Obj, 'inline_query_id'), 0);

  Arr := JGetArr(AResp.Obj, 'results');
  if Arr <> nil then begin
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      Obj := TJSONObject(Arr.Items[I]);
      { The bot answers with whatever kinds it likes; only animations
        belong in this tab. }
      if JGetStr(Obj, '@type') <> 'inlineQueryResultAnimation' then begin
        Continue;
      end;
      Item := ReadAnimation(JGetObj(Obj, 'animation'));
      if Item = nil then begin
        Continue;
      end;
      Item.ResultId := JGetStr(Obj, 'id');
      FFoundGifs.Add(Item);
      if (Item.ThumbFileId <> 0) and (Item.ThumbPath = '') then begin
        WantFile(Item.ThumbFileId, Item.ThumbRequested);
      end;
    end;
  end;
  Touch;
end;

procedure TTdStickers.DownloadDone(Sender: TObject; const AResp: TTdResponse);
begin
  { The answer to downloadFile is a file object in whatever state it
    is in at that instant — usually not finished yet. The real arrival
    is updateFile, so both go through the same place. }
  if AResp.Success then begin
    ApplyFile(AResp.Obj);
  end;
end;

{ ---------------- updates ---------------- }

{ One file object, from updateFile or from a downloadFile answer,
  matched against everything this model is waiting for.

  A file whose download is NOT completed clears the path rather than
  leaving the old one: TDLib reports exactly this when a cached file
  has been evicted, and a page still holding a URL for it would draw a
  gap. Same rule, and the same reason, as TTdMessages.ForgetFile. }
procedure TTdStickers.ApplyFile(AFile: TJSONObject);
var
  Id, I, J: integer;
  Path: utf8string;
  Done, Hit: boolean;
  LocalObj: TJSONObject;

  { Nested so the three lists can be walked without repeating the same
    six lines three times over. Reads Id/Done/Path and sets Hit from
    the enclosing scope. }
  procedure Take(AItemId: integer; var APath: utf8string; var ARequested: boolean);
  begin
    if AItemId <> Id then begin
      Exit;
    end;
    if Done then begin
      APath := Path;
    end else begin
      APath := '';
      ARequested := False;
    end;
    Hit := True;
  end;

begin
  if AFile = nil then begin
    Exit;
  end;
  Id := JGetInt(AFile, 'id');
  if Id = 0 then begin
    Exit;
  end;
  LocalObj := JGetObj(AFile, 'local');
  Done := JGetBool(LocalObj, 'is_downloading_completed');
  Path := '';
  if Done then begin
    Path := JGetStr(LocalObj, 'path');
  end;

  Hit := False;
  for I := 0 to FRecent.Count - 1 do begin
    Take(FRecent[I].FileId, FRecent[I].LocalPath, FRecent[I].Requested);
  end;
  for I := 0 to FSets.Count - 1 do begin
    for J := 0 to FSets[I].Items.Count - 1 do begin
      Take(FSets[I].Items[J].FileId, FSets[I].Items[J].LocalPath,
        FSets[I].Items[J].Requested);
    end;
  end;
  for I := 0 to FEmojiSets.Count - 1 do begin
    if FEmojiSets[I].Cover <> nil then begin
      Take(FEmojiSets[I].Cover.FileId, FEmojiSets[I].Cover.LocalPath,
        FEmojiSets[I].Cover.Requested);
    end;
    for J := 0 to FEmojiSets[I].Items.Count - 1 do begin
      Take(FEmojiSets[I].Items[J].FileId, FEmojiSets[I].Items[J].LocalPath,
        FEmojiSets[I].Items[J].Requested);
    end;
  end;
  for I := 0 to FFoundStickers.Count - 1 do begin
    Take(FFoundStickers[I].FileId, FFoundStickers[I].LocalPath,
      FFoundStickers[I].Requested);
  end;
  for I := 0 to FGifs.Count - 1 do begin
    Take(FGifs[I].ThumbFileId, FGifs[I].ThumbPath, FGifs[I].ThumbRequested);
    Take(FGifs[I].FileId, FGifs[I].Path, FGifs[I].Requested);
  end;
  for I := 0 to FFoundGifs.Count - 1 do begin
    Take(FFoundGifs[I].ThumbFileId, FFoundGifs[I].ThumbPath,
      FFoundGifs[I].ThumbRequested);
    Take(FFoundGifs[I].FileId, FFoundGifs[I].Path, FFoundGifs[I].Requested);
  end;

  if Hit then begin
    Touch;
  end;
end;

procedure TTdStickers.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  T: utf8string;
begin
  if AData = nil then begin
    Exit;
  end;
  T := JGetStr(AData, '@type');
  if T = 'updateOption' then begin
    { Telegram sends its options at start-up, so the name of the GIF
      search bot is usually known long before anybody searches - and
      that saves a round trip off the first search. getOption stays as
      the fallback for the case where it is not. }
    if JGetStr(AData, 'name') = 'animation_search_bot_username' then begin
      FGifBotName := JGetStr(JGetObj(AData, 'value'), 'value');
    end;
  end else if T = 'updateFile' then begin
    ApplyFile(JGetObj(AData, 'file'));
  end else if (T = 'updateInstalledStickerSets')
           or (T = 'updateRecentStickers')
           or (T = 'updateSavedAnimations') then begin
    { The account's own lists changed — from this window or another
      one. Re-ask, but only if somebody had asked in the first place:
      until then there is no panel to keep up to date. }
    if FAsked then begin
      FAsked := False;
      EnsureLoaded;
    end;
  end;
end;

procedure TTdStickers.TdStateChanged(AState: TTdAuthState);
begin
  if TdIsShuttingState(AState) then begin
    Clear;
  end;
end;

procedure TTdStickers.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors do not concern this model. }
end;

end.
