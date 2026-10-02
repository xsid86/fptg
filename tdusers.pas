unit tdusers;

{$mode objfpc}{$H+}

interface

uses
  Classes, constants, SysUtils, fgl, fpjson, base64,
  tdauth, tdsession, tdreq;

type
  { TUserRow

    The minimum needed for a display name in a message header. Has no
    reference to LCL, same as TChatRow/TMsgRow. }
  TUserRow = class
  public
    Id: Int64;
    FirstName, LastName: utf8string;
    { 0..6 are reserved built-in colors; 7+ are resolved through
      TTdAccentColors (tdaccentcolors.pas) from updateAccentColors. }
    AccentColorId: integer;
    { userTypeDeleted. TDLib sends such a user with both names blank,
      which is exactly the case DisplayName's "User <id>" fallback was
      written for — so without this the history would label every
      deleted account by its raw id. }
    Deleted: boolean;
    { Маленькое фото профиля (user.profile_photo.small) — для списков
      людей на странице: кто поставил реакцию, кто прочитал. Качается
      по требованию (TTdUsers.EnsurePhoto); пока его нет — Minithumb,
      крошечный jpeg прямо из объекта пользователя. }
    PhotoFileId: integer;
    PhotoPath: utf8string;
    Minithumb: RawByteString;
    PhotoRequested: boolean;
    function DisplayName: utf8string;
  end;

  TUserMap = specialize TFPGMap<Int64, TUserRow>;

  TTdUsersEvent = procedure(Sender: TObject) of object;

  { TTdUsers

    Cache of display names for arbitrary users — TTdChats.FBots
    (tdchats.pas) only stores whether a user is a bot, not its name.
    Populated passively from updateUser (the same update stream
    TTdChats already listens to for that type), and on a cache miss,
    actively backfilled via getUser — the same "fetch asynchronously,
    redraw once ready" pattern as avatars in avatarcache.pas/
    updateFile. }
  TTdUsers = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq: TTdRequests;
    FAll: TUserMap;
    { Ids of users for whom getUser has already been sent and a
      response is pending — avoids flooding TDLib with repeat requests
      on every redraw of the same still-unresolved name. }
    FPending: array of Int64;
    FOnChanged: TTdUsersEvent;
    function Lookup(AId: Int64): TUserRow;
    function IsPending(AId: Int64): boolean;
    procedure MarkPending(AId: Int64);
    procedure ClearPending(AId: Int64);
    procedure ApplyUser(AUser: TJSONObject);
    procedure RequestUser(AId: Int64);
    procedure GetUserDone(Sender: TObject; const AResp: TTdResponse);
    procedure PhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyFile(AFile: TJSONObject);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { Returns the cached name, or '' while asynchronously issuing
      getUser if the user is not yet known and no request for it is
      already in flight. The result arrives later via OnChanged. }
    function DisplayName(AUserId: Int64): utf8string;
    { Same, but for the user's accent_color_id; -1 if not yet known
      (also issues getUser on a miss, independently — it does not rely
      on DisplayName having already been called for the same id). }
    function AccentColorId(AUserId: Int64): integer;
    { Строка пользователя или nil; на промахе — getUser, ответ придёт
      через OnChanged. }
    function Find(AUserId: Int64): TUserRow;
    { Скачивает маленькое фото профиля, если его ещё нет. }
    procedure EnsurePhoto(ARow: TUserRow);

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property OnChanged: TTdUsersEvent read FOnChanged write FOnChanged;
  end;

implementation

{ ---------------- TUserRow ---------------- }

function TUserRow.DisplayName: utf8string;
begin
  { Checked before the names, not after: a deleted account has none,
    so this is what the id fallback below would otherwise catch. One
    place for it, and every caller in the history — the message
    header, a forward's source, a reply quote — follows. }
  if Deleted then begin
    Result := DELETED_ACCOUNT_TITLE;
    Exit;
  end;
  Result := utf8string(Trim(string(FirstName) + ' ' + string(LastName)));
  if Result = '' then begin
    Result := utf8string('User ' + IntToStr(Id));
  end;
end;

{ ---------------- TTdUsers ---------------- }

constructor TTdUsers.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TUserMap.Create;
  FAll.Sorted := True;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdUsers.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdUsers.Clear;
var
  I: integer;
begin
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  SetLength(FPending, 0);
end;

function TTdUsers.Lookup(AId: Int64): TUserRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdUsers.IsPending(AId: Int64): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(FPending) do begin
    if FPending[I] = AId then begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdUsers.MarkPending(AId: Int64);
begin
  SetLength(FPending, Length(FPending) + 1);
  FPending[High(FPending)] := AId;
end;

procedure TTdUsers.ClearPending(AId: Int64);
var
  I, J: integer;
begin
  for I := 0 to High(FPending) do begin
    if FPending[I] = AId then begin
      for J := I to High(FPending) - 1 do begin
        FPending[J] := FPending[J + 1];
      end;
      SetLength(FPending, Length(FPending) - 1);
      Exit;
    end;
  end;
end;

procedure TTdUsers.ApplyUser(AUser: TJSONObject);
var
  Id: Int64;
  R: TUserRow;
  Idx: integer;
  Photo, Small, Local: TJSONObject;
  B64: utf8string;
begin
  if AUser = nil then begin
    Exit;
  end;
  Id := JGetInt64(AUser, 'id');
  if Id = 0 then begin
    Exit;
  end;

  Idx := FAll.IndexOf(Id);
  if Idx >= 0 then begin
    R := FAll.Data[Idx];
  end else begin
    R := TUserRow.Create;
    R.Id := Id;
    FAll.Add(Id, R);
  end;
  R.FirstName := JGetStr(AUser, 'first_name');
  R.LastName := JGetStr(AUser, 'last_name');

  { profile_photo: small (file) и minithumbnail (base64 jpeg), поля по
    td_api.tl. Другое фото — прежний запрос уже не о нём. }
  Photo := JGetObj(AUser, 'profile_photo');
  if Photo = nil then begin
    R.PhotoFileId := 0;
    R.PhotoPath := '';
    R.Minithumb := '';
    R.PhotoRequested := False;
  end else begin
    Small := JGetObj(Photo, 'small');
    if R.PhotoFileId <> JGetInt(Small, 'id') then begin
      R.PhotoRequested := False;
      R.PhotoPath := '';
    end;
    R.PhotoFileId := JGetInt(Small, 'id');
    Local := JGetObj(Small, 'local');
    if (Local <> nil) and JGetBool(Local, 'is_downloading_completed') then begin
      R.PhotoPath := JGetStr(Local, 'path');
    end;
    B64 := JGetStr(JGetObj(Photo, 'minithumbnail'), 'data');
    R.Minithumb := '';
    if B64 <> '' then begin
      try
        R.Minithumb := DecodeStringBase64(string(B64));
      except
        R.Minithumb := '';
      end;
    end;
  end;
  R.AccentColorId := JGetInt(AUser, 'accent_color_id');
  R.Deleted := JGetStr(JGetObj(AUser, 'type'), '@type') = 'userTypeDeleted';

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

procedure TTdUsers.RequestUser(AId: Int64);
begin
  if (FReq = nil) or IsPending(AId) then begin
    Exit;
  end;
  MarkPending(AId);
  FReq.SendRequest('getUser', '"user_id":' + utf8string(IntToStr(AId)),
    @GetUserDone, PtrInt(AId));
end;

procedure TTdUsers.GetUserDone(Sender: TObject; const AResp: TTdResponse);
begin
  { Clears pending by Tag (the id actually requested), not by an id
    from the response body — on error the body may be absent
    entirely, and without this the name would stay marked "in flight"
    forever, blocking a retry on the next redraw. }
  ClearPending(Int64(AResp.Tag));
  if AResp.Success then begin
    ApplyUser(AResp.Obj);
  end;
end;

function TTdUsers.Find(AUserId: Int64): TUserRow;
begin
  Result := Lookup(AUserId);
  if (Result = nil) and (AUserId <> 0) then begin
    RequestUser(AUserId);
  end;
end;

procedure TTdUsers.EnsurePhoto(ARow: TUserRow);
begin
  if (ARow = nil) or (FReq = nil) or (ARow.PhotoFileId = 0)
     or (ARow.PhotoPath <> '') or ARow.PhotoRequested then begin
    Exit;
  end;
  ARow.PhotoRequested := True;
  { Приоритет 1, как у аватарок чатов: не мешать сообщениям. }
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.PhotoFileId)) +
    ',"priority":1,"offset":0,"limit":0,"synchronous":false',
    @PhotoDone, ARow.PhotoFileId);
end;

procedure TTdUsers.PhotoDone(Sender: TObject; const AResp: TTdResponse);
var
  I: integer;
begin
  { Уже скачанный файл приходит прямо в ответе. }
  if AResp.Success then begin
    ApplyFile(AResp.Obj);
    Exit;
  end;
  for I := 0 to FAll.Count - 1 do begin
    if FAll.Data[I].PhotoFileId = integer(AResp.Tag) then begin
      FAll.Data[I].PhotoRequested := False;
    end;
  end;
end;

{ Путь — всем пользователям с этим файлом (см. «Один файл TDLib бывает у
  нескольких чатов» в ARCHITECTURE.md — здесь то же правило). }
procedure TTdUsers.ApplyFile(AFile: TJSONObject);
var
  FileId, I: integer;
  Local: TJSONObject;
  Path: utf8string;
  Changed: boolean;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Local := JGetObj(AFile, 'local');
  if (FileId = 0) or (Local = nil) or not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;
  Changed := False;
  for I := 0 to FAll.Count - 1 do begin
    if (FAll.Data[I].PhotoFileId = FileId) and (FAll.Data[I].PhotoPath <> Path) then begin
      FAll.Data[I].PhotoPath := Path;
      Changed := True;
    end;
  end;
  if Changed and Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

function TTdUsers.DisplayName(AUserId: Int64): utf8string;
var
  R: TUserRow;
begin
  Result := '';
  if AUserId = 0 then begin
    Exit;
  end;
  R := Lookup(AUserId);
  if R <> nil then begin
    Result := R.DisplayName;
    Exit;
  end;
  RequestUser(AUserId);
end;

function TTdUsers.AccentColorId(AUserId: Int64): integer;
var
  R: TUserRow;
begin
  Result := -1;
  if AUserId = 0 then begin
    Exit;
  end;
  R := Lookup(AUserId);
  if R <> nil then begin
    Result := R.AccentColorId;
    Exit;
  end;
  RequestUser(AUserId);
end;

procedure TTdUsers.TdUpdate(const AJson: utf8string; AData: TJSONObject);
begin
  if AData = nil then begin
    Exit;
  end;
  if JGetStr(AData, '@type') = 'updateUser' then begin
    ApplyUser(JGetObj(AData, 'user'));
  end else if JGetStr(AData, '@type') = 'updateFile' then begin
    ApplyFile(JGetObj(AData, 'file'));
  end;
end;

procedure TTdUsers.TdStateChanged(AState: TTdAuthState);
begin
  { On logout/shutdown the name cache is no longer meaningful, same as
    for the other account models. }
  if TdIsShuttingState(AState) then begin
    Clear;
  end;
end;

procedure TTdUsers.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors don't concern this model. }
end;

end.
