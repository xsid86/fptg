unit tdaccount;

{$mode objfpc}{$H+}

interface

uses
  { Windows first — same reasoning as everywhere else in this project
    that touches raw Win32 API (framehistory.pas's own uses-clause
    comment covers it in full): GetFileVersionInfoSize/GetFileVersionInfo/
    VerQueryValue (AppVersionString, implementation section) are the
    real Win32 version API, and later units here don't redeclare any
    of those names, but keeping the convention avoids having to
    remember which units are safe to reorder later. }
  Windows,
  Classes, SysUtils, ExtCtrls, fpjson, jsonparser, base64,
  tdauth, tdclient, tdsession, tdreq, tdchats, tdmessages, tdusers, tdaccentcolors,
  tdsupergroups, tdstickers, tdattachbots, tdcalls;

type

  { TTdAccount

    One Telegram account with everything it owns. Descends from
    TComponent rather than TInterfacedObject: the ITdSession interface
    must not be reference-counted, or the object would self-destruct
    once the models release their reference.

    Subscriber lists live here rather than in the registry: a form
    subscribes to a SPECIFIC account, and subscriptions survive the
    client being recreated after logOut. }

  TTdAccount = class(TComponent, ITdSession)
  private
    FSlot:     integer;      { sequence number, also the directory name }
    FDataDir:  string;
    FFilesDir: string;
    FTitle:    string;
    FApiId:    integer;
    FApiHash:  utf8string;
    { The app name Telegram shows in Active Sessions — TdApp.
      DeviceModel (tdcore.pas), passed down at construction time the
      same way FApiId/FApiHash already are. }
    FDeviceModel: utf8string;
    FUserId:   Int64;
    { Telegram Premium у этого аккаунта: getMe.is_premium, дальше —
      updateOption is_premium. Нужен странице, чтобы прятать то, что
      без Premium недоступно (расшифровка голосовых). }
    FIsPremium: boolean;
    FPhone:    utf8string;
    FUsername: utf8string;
    FPhotoFileId:  integer;
    FPhotoPath:    utf8string;
    FPhotoThumb:   RawByteString;
    FPhotoAsked:   boolean;
    FOnInfoChanged: TNotifyEvent;
    FOnStateNotify: TNotifyEvent;
    FForget: boolean;   { after logOut, remove the account instead of recreating it }

    FClient:   TTdClient;
    FAuth:     TTdAuth;
    FReq:      TTdRequests;
    FChats:    TTdChats;
    FMessages: TTdMessages;
    FUsers:    TTdUsers;
    FAccentColors: TTdAccentColors;
    FSupergroups: TTdSupergroups;
    FAttachBots: TTdAttachBots;
    FStickers: TTdStickers;
    FCalls:    TTdCalls;

    FUpdateL: array of ITdUpdateListener;
    FStateL:  array of ITdStateListener;
    FAuthL:   array of ITdAuthListener;

    FState:      TTdAuthState;
    FStarted:    boolean;
    FLoggingOut: boolean;
    FClosing:    boolean;
    FClosed:     boolean;
    FRestartTimer: TTimer;

    procedure CreateEngine;
    procedure DestroyEngine;
    procedure RestartTick(Sender: TObject);
    procedure RequestMe;
    procedure MeDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyMyPhoto(APhoto: TJSONObject);
    procedure PhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyPhotoFile(AFile: TJSONObject);

    { TTdAuth event handlers }
    procedure HandleUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
    procedure HandleStateChanged(Sender: TObject; AState: TTdAuthState);
    procedure HandleError(Sender: TObject; ACode: integer;
      const AMessage, AContext: utf8string);
    procedure HandleNeedPhoneOrQr(Sender: TObject);
    procedure HandleQrLink(Sender: TObject; const ALink: utf8string);
    procedure HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
    procedure HandleNeedEmailAddress(Sender: TObject; AAllowApple, AAllowGoogle: boolean);
    procedure HandleNeedEmailCode(Sender: TObject; const APattern: utf8string;
      ALength: integer);
    procedure HandleNeedPassword(Sender: TObject;
      const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
    procedure HandlePasswordRecovery(Sender: TObject; const AEmailPattern: utf8string);
    procedure HandleNeedRegistration(Sender: TObject; const ATosText: utf8string;
      AShowPopup: boolean; AMinAge: integer);
  public
    constructor Create(AOwner: TComponent; ASlot: integer;
      const ABaseDir, ATitle: string; AApiId: integer;
      const AApiHash: utf8string; const ADeviceModel: utf8string); reintroduce;
    destructor Destroy; override;

    procedure Start;

    { Logs out of the account. The client is recreated, and the flow
      returns to phone entry. Other accounts are unaffected. }
    procedure LogOut;

    { Same, but the account is removed from the registry after logging
      out, matching Telegram. The client is not recreated. }
    procedure LogOutAndForget;

    { Closes the client and removes the account WITHOUT logging out of
      the session. Needed when canceling adding an account: without
      closing, the TDLib client stays alive and keeps the database
      directory locked, and the next attempt to reuse that slot hits a
      locked database. }
    procedure CloseAndForget;

    { Asks TDLib to close the client. Waiting for completion is the
      registry's job: every account has to be closed together, and a
      shared timeout makes sense. }
    procedure RequestClose;

    { ITdSession }
    function GetClientId: integer;
    function GetState: TTdAuthState;
    function GetDataDir: string;
    function GetTitle: string;
    function GetAuth: TTdAuth;
    function GetUserId: Int64;
    procedure Send(const ARequest: utf8string);
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);

    property Slot: integer read FSlot;
    property UserId: Int64 read FUserId;
    property IsPremium: boolean read FIsPremium;
    property Phone: utf8string read FPhone;
    property Username: utf8string read FUsername;
    { Own avatar — for the account menu. The mini-thumbnail arrives
      with getMe, the full-size image is downloaded afterward. }
    property PhotoPath: utf8string read FPhotoPath;
    property PhotoThumb: RawByteString read FPhotoThumb;
    { The registry subscribes to save the manifest and refresh the menu. }
    property OnInfoChanged: TNotifyEvent read FOnInfoChanged write FOnInfoChanged;
    { Any state change goes to the registry so it can refresh the menu
      — an inactive account may have logged out, and that needs to
      show. }
    property OnStateNotify: TNotifyEvent read FOnStateNotify write FOnStateNotify;
    property Forget: boolean read FForget;
    property Title: string read FTitle write FTitle;
    property Chats: TTdChats read FChats;
    property Messages: TTdMessages read FMessages;
    property Users: TTdUsers read FUsers;
    property AccentColors: TTdAccentColors read FAccentColors;
    property Supergroups: TTdSupergroups read FSupergroups;
    property AttachBots: TTdAttachBots read FAttachBots;
    { Sticker sets and saved animations. Fetches nothing until asked
      — see TTdStickers.EnsureLoaded. }
    property Stickers: TTdStickers read FStickers;
    { Личные звонки: сигнальная часть (tdcalls.pas). }
    property Calls: TTdCalls read FCalls;
    property Requests: TTdRequests read FReq;
    property Auth: TTdAuth read FAuth;
    property State: TTdAuthState read FState;
    property Started: boolean read FStarted;
    property Closing: boolean read FClosing;
    property Closed: boolean read FClosed;
  end;

implementation

{ The running exe's own embedded VERSIONINFO — the same numbers FPTelegram.lpi's
  UseVersionInfo/BuildNr produce and Explorer's file Properties > Details
  tab already shows, read directly via the real Win32 version API rather
  than hand-tracked separately in Pascal, so the string sent to
  setTdlibParameters (CreateEngine below) can never drift from what's
  actually compiled into THIS binary. Major/Minor/Release aren't set in
  FPTelegram.lpi (all 0 as of this writing, see the project's own VersionInfo),
  only BuildNr auto-increments — formatted as all four parts regardless,
  so a future version bump just starts showing up here automatically.
  Returns '0.0.0.0' if the query fails for any reason (should not happen
  for our own already-running exe, but this only ever reaches Telegram's
  servers, not shown to the user directly — not worth raising an error
  over). }
function AppVersionString: utf8string;
var
  Size, Handle: DWORD;
  Buf: array of byte;
  FixedInfo: PVSFixedFileInfo;
  Len: UINT;
  ExeName: string;
begin
  Result := '0.0.0.0';
  ExeName := ParamStr(0);
  Size := Windows.GetFileVersionInfoSize(PChar(ExeName), Handle);
  if Size = 0 then begin
    Exit;
  end;
  SetLength(Buf, Size);
  if not Windows.GetFileVersionInfo(PChar(ExeName), Handle, Size, @Buf[0]) then begin
    Exit;
  end;
  if not Windows.VerQueryValue(@Buf[0], '\', Pointer(FixedInfo), Len) then begin
    Exit;
  end;
  Result := utf8string(Format('%d.%d.%d.%d', [
    HiWord(FixedInfo^.dwFileVersionMS), LoWord(FixedInfo^.dwFileVersionMS),
    HiWord(FixedInfo^.dwFileVersionLS), LoWord(FixedInfo^.dwFileVersionLS)]));
end;

{ ---------------- lifecycle ---------------- }

constructor TTdAccount.Create(AOwner: TComponent; ASlot: integer;
  const ABaseDir, ATitle: string; AApiId: integer; const AApiHash: utf8string;
  const ADeviceModel: utf8string);
begin
  inherited Create(AOwner);
  FSlot := ASlot;
  FTitle := ATitle;
  FApiId := AApiId;
  FApiHash := AApiHash;
  FDeviceModel := ADeviceModel;
  FState := tasNone;

  { Each account has its own directory. Sharing one would make the
    clients overwrite each other's databases. }
  FDataDir := ABaseDir + 'tdlib' + PathDelim + 'acc' + IntToStr(ASlot);
  FFilesDir := FDataDir + PathDelim + 'files';

  FRestartTimer := TTimer.Create(Self);
  FRestartTimer.Interval := 1;
  FRestartTimer.OnTimer := @RestartTick;
  FRestartTimer.Enabled := False;

  { The objects are created immediately, not in Start: forms access
    Chats and subscribe already in FormCreate, before the client is
    started. The TDLib client itself stays dormant until Start wakes
    it. }
  CreateEngine;
end;

destructor TTdAccount.Destroy;
begin
  FRestartTimer.Enabled := False;
  DestroyEngine;
  SetLength(FUpdateL, 0);
  SetLength(FStateL, 0);
  SetLength(FAuthL, 0);
  inherited Destroy;
end;

procedure TTdAccount.CreateEngine;
begin
  FClient := TTdClient.Create;
  { Order matters: TTdAuth's constructor inserts itself into the
    OnUpdate chain. }
  FClient.OnUpdate := @HandleUpdate;

  FAuth := TTdAuth.Create(FClient);
  FAuth.ApiId              := FApiId;
  FAuth.ApiHash            := FApiHash;
  FAuth.DatabaseDir        := utf8string(FDataDir);
  FAuth.FilesDir           := utf8string(FFilesDir);
  FAuth.DeviceModel        := FDeviceModel;
  FAuth.ApplicationVersion := AppVersionString;
  FAuth.SystemLanguageCode := 'ru';

  FAuth.OnStateChanged     := @HandleStateChanged;
  FAuth.OnError            := @HandleError;
  FAuth.OnNeedPhoneOrQr    := @HandleNeedPhoneOrQr;
  FAuth.OnQrLink           := @HandleQrLink;
  FAuth.OnNeedCode         := @HandleNeedCode;
  FAuth.OnNeedEmailAddress := @HandleNeedEmailAddress;
  FAuth.OnNeedEmailCode    := @HandleNeedEmailCode;
  FAuth.OnNeedPassword     := @HandleNeedPassword;
  FAuth.OnPasswordRecovery := @HandlePasswordRecovery;
  FAuth.OnNeedRegistration := @HandleNeedRegistration;

  { The resolver and models subscribe to the account itself, not the
    client: they survive the client being recreated. }
  FReq := TTdRequests.Create(Self, Self);
  FChats := TTdChats.Create(Self, Self, FReq);
  FMessages := TTdMessages.Create(Self, Self, FReq);
  FUsers := TTdUsers.Create(Self, Self, FReq);
  FAccentColors := TTdAccentColors.Create(Self, Self);
  FSupergroups := TTdSupergroups.Create(Self, Self, FReq);
  FAttachBots := TTdAttachBots.Create(Self, Self);
  FStickers := TTdStickers.Create(Self, Self, FReq);
  FCalls := TTdCalls.Create(Self, Self, FReq);
end;

procedure TTdAccount.DestroyEngine;
begin
  FreeAndNil(FCalls);
  FreeAndNil(FStickers);
  FreeAndNil(FAttachBots);
  FreeAndNil(FSupergroups);
  FreeAndNil(FAccentColors);
  FreeAndNil(FUsers);
  FreeAndNil(FMessages);
  FreeAndNil(FChats);
  FreeAndNil(FReq);
  FreeAndNil(FAuth);
  if FClient <> nil then begin
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

procedure TTdAccount.Start;
begin
  if FStarted then begin
    Exit;
  end;
  FStarted := True;
  if FClient <> nil then begin
    FClient.Start;
  end;
end;

{ ---------------- ITdSession ---------------- }

function TTdAccount.GetClientId: integer;
begin
  if FClient <> nil then begin
    Result := FClient.ClientId;
  end else begin
    Result := 0;
  end;
end;

function TTdAccount.GetState: TTdAuthState;
begin
  Result := FState;
end;

function TTdAccount.GetDataDir: string;
begin
  Result := FDataDir;
end;

function TTdAccount.GetTitle: string;
begin
  Result := FTitle;
end;

function TTdAccount.GetAuth: TTdAuth;
begin
  Result := FAuth;
end;

function TTdAccount.GetUserId: Int64;
begin
  Result := FUserId;
end;

procedure TTdAccount.Send(const ARequest: utf8string);
begin
  if FClient <> nil then begin
    FClient.Send(ARequest);
  end;
end;

procedure TTdAccount.Subscribe(const AListener: IUnknown);
var
  U: ITdUpdateListener;
  S: ITdStateListener;
  A: ITdAuthListener;
  I: integer;
  Found: boolean;
begin
  if AListener = nil then begin
    Exit;
  end;

  if Supports(AListener, ITdUpdateListener, U) then begin
    Found := False;
    for I := 0 to High(FUpdateL) do begin
      if FUpdateL[I] = U then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FUpdateL, Length(FUpdateL) + 1);
      FUpdateL[High(FUpdateL)] := U;
    end;
  end;

  if Supports(AListener, ITdStateListener, S) then begin
    Found := False;
    for I := 0 to High(FStateL) do begin
      if FStateL[I] = S then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FStateL, Length(FStateL) + 1);
      FStateL[High(FStateL)] := S;
    end;
  end;

  if Supports(AListener, ITdAuthListener, A) then begin
    Found := False;
    for I := 0 to High(FAuthL) do begin
      if FAuthL[I] = A then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FAuthL, Length(FAuthL) + 1);
      FAuthL[High(FAuthL)] := A;
    end;
  end;
end;

procedure TTdAccount.Unsubscribe(const AListener: IUnknown);
var
  U: ITdUpdateListener;
  S: ITdStateListener;
  A: ITdAuthListener;
  I, J: integer;
begin
  if AListener = nil then begin
    Exit;
  end;

  if Supports(AListener, ITdUpdateListener, U) then begin
    for I := High(FUpdateL) downto 0 do begin
      if FUpdateL[I] = U then begin
        for J := I to High(FUpdateL) - 1 do begin
          FUpdateL[J] := FUpdateL[J + 1];
        end;
        SetLength(FUpdateL, Length(FUpdateL) - 1);
      end;
    end;
  end;

  if Supports(AListener, ITdStateListener, S) then begin
    for I := High(FStateL) downto 0 do begin
      if FStateL[I] = S then begin
        for J := I to High(FStateL) - 1 do begin
          FStateL[J] := FStateL[J + 1];
        end;
        SetLength(FStateL, Length(FStateL) - 1);
      end;
    end;
  end;

  if Supports(AListener, ITdAuthListener, A) then begin
    for I := High(FAuthL) downto 0 do begin
      if FAuthL[I] = A then begin
        for J := I to High(FAuthL) - 1 do begin
          FAuthL[J] := FAuthL[J + 1];
        end;
        SetLength(FAuthL, Length(FAuthL) - 1);
      end;
    end;
  end;
end;

{ ---------------- event dispatch ----------------
  Lists are copied before iterating: a subscriber is allowed to
  unsubscribe from within its own handler. }

procedure TTdAccount.HandleUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
var
  Snap: array of ITdUpdateListener;
  I: integer;
begin
  { Own avatar finished downloading. AData is already parsed by the
    receive thread (tdrecv.pas) — this used to have its own separate
    GetJSON call. }
  if (FPhotoFileId <> 0) and (FPhotoPath = '') and (AData <> nil)
     and (JGetStr(AData, '@type') = 'updateFile') then begin
    ApplyPhotoFile(JGetObj(AData, 'file'));
  end;
  { Premium купили или он кончился — TDLib сообщает опцией
    (td_api.tl: updateOption name value; value — optionValueBoolean). }
  if (AData <> nil) and (JGetStr(AData, '@type') = 'updateOption')
     and (JGetStr(AData, 'name') = 'is_premium') then begin
    FIsPremium := JGetBool(JGetObj(AData, 'value'), 'value');
  end;

  Snap := Copy(FUpdateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdUpdate(AJson, AData);
  end;
end;

procedure TTdAccount.HandleStateChanged(Sender: TObject; AState: TTdAuthState);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  FState := AState;

  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdStateChanged(AState);
  end;

  { As soon as we're signed in, ask who we are. The title is needed by
    the account switcher, and user_id is useful later on. }
  if AState = tasReady then begin
    RequestMe;
  end;

  if Assigned(FOnStateNotify) then begin
    FOnStateNotify(Self);
  end;

  if AState = tasClosed then begin
    if FLoggingOut or FForget then begin
      { Recreation is deferred: we're inside a batch of update
        dispatch, and the client cannot be torn down out from under
        itself. }
      FRestartTimer.Enabled := True;
    end else if FClosing then begin
      FClosed := True;
    end;
  end;
end;

procedure TTdAccount.HandleError(Sender: TObject; ACode: integer;
  const AMessage, AContext: utf8string);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdError(ACode, AMessage, AContext);
  end;
end;

procedure TTdAccount.HandleNeedPhoneOrQr(Sender: TObject);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPhoneOrQr;
  end;
end;

procedure TTdAccount.HandleQrLink(Sender: TObject; const ALink: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdQrLink(ALink);
  end;
end;

procedure TTdAccount.HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedCode(AInfo);
  end;
end;

procedure TTdAccount.HandleNeedEmailAddress(Sender: TObject;
  AAllowApple, AAllowGoogle: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailAddress(AAllowApple, AAllowGoogle);
  end;
end;

procedure TTdAccount.HandleNeedEmailCode(Sender: TObject;
  const APattern: utf8string; ALength: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailCode(APattern, ALength);
  end;
end;

procedure TTdAccount.HandleNeedPassword(Sender: TObject;
  const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPassword(AHint, ARecoveryPattern, AHasRecovery);
  end;
end;

procedure TTdAccount.HandlePasswordRecovery(Sender: TObject;
  const AEmailPattern: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdPasswordRecovery(AEmailPattern);
  end;
end;

procedure TTdAccount.HandleNeedRegistration(Sender: TObject;
  const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedRegistration(ATosText, AShowPopup, AMinAge);
  end;
end;

{ ---------------- self info ---------------- }

procedure TTdAccount.RequestMe;
begin
  if FReq <> nil then begin
    FReq.SendRequest('getMe', '', @MeDone);
  end;
end;

procedure TTdAccount.MeDone(Sender: TObject; const AResp: TTdResponse);
var
  First, Last, NewTitle: utf8string;
  U: TJSONObject;
  Arr: TJSONArray;
begin
  if not AResp.Success then begin
    Exit;
  end;

  FUserId := JGetInt64(AResp.Obj, 'id');
  FIsPremium := JGetBool(AResp.Obj, 'is_premium');
  FPhone := JGetStr(AResp.Obj, 'phone_number');

  ApplyMyPhoto(JGetObj(AResp.Obj, 'profile_photo'));

  U := JGetObj(AResp.Obj, 'usernames');
  FUsername := JGetStr(U, 'editable_username');
  if FUsername = '' then begin
    Arr := JGetArr(U, 'active_usernames');
    if (Arr <> nil) and (Arr.Count > 0) then begin
      FUsername := utf8string(Arr.Items[0].AsString);
    end;
  end;

  First := JGetStr(AResp.Obj, 'first_name');
  Last := JGetStr(AResp.Obj, 'last_name');

  { Same preference order as Telegram's own clients: name, then
    @username, then phone number. }
  NewTitle := utf8string(Trim(string(First) + ' ' + string(Last)));
  if NewTitle = '' then begin
    if FUsername <> '' then begin
      NewTitle := '@' + FUsername;
    end else if FPhone <> '' then begin
      NewTitle := '+' + FPhone;
    end;
  end;

  if (NewTitle <> '') and (NewTitle <> utf8string(FTitle)) then begin
    FTitle := string(NewTitle);
    if Assigned(FOnInfoChanged) then begin
      FOnInfoChanged(Self);
    end;
  end;
end;

procedure TTdAccount.ApplyMyPhoto(APhoto: TJSONObject);
var
  Small: TJSONObject;
  B64: utf8string;
begin
  if APhoto = nil then begin
    FPhotoFileId := 0;
    FPhotoPath := '';
    FPhotoThumb := '';
    Exit;
  end;

  Small := JGetObj(APhoto, 'small');
  FPhotoFileId := JGetInt(Small, 'id');
  FPhotoPath := JGetStr(JGetObj(Small, 'local'), 'path');

  B64 := JGetStr(JGetObj(APhoto, 'minithumbnail'), 'data');
  if B64 <> '' then begin
    try
      FPhotoThumb := DecodeStringBase64(string(B64));
    except
      FPhotoThumb := '';
    end;
  end;

  if Assigned(FOnInfoChanged) then begin
    FOnInfoChanged(Self);
  end;

  { The mini-thumbnail can already be shown; the real photo is
    downloaded next. }
  if (FPhotoFileId <> 0) and (FPhotoPath = '') and (not FPhotoAsked)
     and (FReq <> nil) then begin
    FPhotoAsked := True;
    FReq.SendRequest('downloadFile',
      '"file_id":' + utf8string(IntToStr(FPhotoFileId)) +
      ',"priority":1,"offset":0,"limit":0,"synchronous":false', @PhotoDone);
  end;
end;

procedure TTdAccount.PhotoDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyPhotoFile(AResp.Obj);
  end else begin
    FPhotoAsked := False;
  end;
end;

procedure TTdAccount.ApplyPhotoFile(AFile: TJSONObject);
var
  Local: TJSONObject;
  Path: utf8string;
begin
  if (AFile = nil) or (JGetInt(AFile, 'id') <> FPhotoFileId) then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if (Path = '') or (Path = FPhotoPath) then begin
    Exit;
  end;
  FPhotoPath := Path;
  if Assigned(FOnInfoChanged) then begin
    FOnInfoChanged(Self);
  end;
end;

{ ---------------- logout and shutdown ---------------- }

procedure TTdAccount.LogOut;
begin
  if (FAuth = nil) or FClosing then begin
    Exit;
  end;
  FLoggingOut := True;
  FAuth.LogOut;
end;

procedure TTdAccount.LogOutAndForget;
begin
  FForget := True;
  LogOut;
end;

procedure TTdAccount.CloseAndForget;
begin
  FForget := True;
  if (FAuth = nil) or (not FStarted) then begin
    { There was no client to begin with — notify the registry right
      away. }
    DestroyEngine;
    FState := tasNone;
    if Assigned(FOnStateNotify) then begin
      FOnStateNotify(Self);
    end;
    Exit;
  end;
  FClosing := True;
  FLoggingOut := False;
  FRestartTimer.Enabled := False;
  FAuth.Close;
end;

procedure TTdAccount.RestartTick(Sender: TObject);
begin
  FRestartTimer.Enabled := False;
  if not (FLoggingOut or FForget) then begin
    Exit;
  end;
  FLoggingOut := False;

  if FForget then begin
    { The account is leaving the registry — no point recreating the
      client. The registry performs the actual removal, deferred: the
      object cannot be freed from within its own event handler. }
    DestroyEngine;
    FState := tasNone;
    if Assigned(FOnStateNotify) then begin
      FOnStateNotify(Self);
    end;
    Exit;
  end;

  DestroyEngine;
  FState := tasNone;
  CreateEngine;
  if FClient <> nil then begin
    FClient.Start;
  end;
end;

procedure TTdAccount.RequestClose;
begin
  if FClosed then begin
    Exit;
  end;
  if (FAuth = nil) or (not FStarted) then begin
    FClosed := True;
    Exit;
  end;
  if FClosing then begin
    Exit;
  end;
  FClosing := True;
  FLoggingOut := False;
  FRestartTimer.Enabled := False;
  FAuth.Close;
end;

end.
