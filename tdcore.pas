unit tdcore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, ExtCtrls,
  constants, tdauth, tdrecv, tdsession, tdreq, tdchats, tdmessages, tdusers,
  tdaccentcolors, tdaccount, tdsupergroups;

type
  { Aliases so forms don't need to add tdsession to their uses clause.
    Point at the same types — GUIDs and compatibility are preserved. }
  ITdUpdateListener = tdsession.ITdUpdateListener;
  ITdStateListener  = tdsession.ITdStateListener;
  ITdAuthListener   = tdsession.ITdAuthListener;
  ITdSession        = tdsession.ITdSession;
  TTdAccount        = tdaccount.TTdAccount;

  TTdCoreEvent = procedure(Sender: TObject) of object;

  { Active-account switches and roster/name changes. Multicast: there
    will be several listeners — the main form, the chat-list frame, and
    later the chat frame. }
  ITdActiveListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1301}']
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

  { TTdCore

    The account registry. Knows nothing about TDLib itself — all of
    that lives in TTdAccount. This class owns the list, the active
    account, persisting it across restarts, and closing all accounts
    together. }

  TTdCore = class
  private
    FAccounts: TFPList;         { of TTdAccount }
    FActive: integer;
    FBaseDir: string;
    FApiId: integer;
    FApiHash: utf8string;
    { device_model sent to setTdlibParameters — the name Telegram shows
      for this app in Active Sessions on other devices (see
      TTdAccount.CreateEngine, tdaccount.pas). Config-persisted like
      FApiId/FApiHash above, but user-editable at any time (Settings >
      General, framesettingsgeneral.pas) rather than fixed at first
      run — SetDeviceModel below writes it straight through, the same
      "select it, it's saved" pattern already used elsewhere in
      Settings. Only affects accounts authenticated AFTER the change:
      Telegram fixes a session's device name at login time, TDLib has
      no way to rename an already-established one. }
    FDeviceModel: utf8string;
    FConfigError: string;
    FStarted: boolean;

    FShuttingDown: boolean;
    FClosed: boolean;
    FCloseTimer: TTimer;
    FOnShutdownComplete: TNotifyEvent;
    FOnActiveChanged: TTdCoreEvent;
    FActiveL: array of ITdActiveListener;

    FPendingRemove: TFPList;
    FRemoveTimer: TTimer;

    procedure AccountInfoChanged(Sender: TObject);
    procedure AccountStateNotify(Sender: TObject);
    procedure RemoveTick(Sender: TObject);
    procedure NotifyActiveChanged;
    procedure NotifyAccountsChanged;

    function GetCount: integer;
    function GetAccount(AIndex: integer): TTdAccount;
    function GetActive: TTdAccount;
    procedure SetActiveIndex(AValue: integer);
    procedure CloseTimeout(Sender: TObject);
    procedure FinishShutdown;
    function AllClosed: boolean;
    function ManifestPath: string;
  public
    constructor Create;
    destructor Destroy; override;

    { config.ini — api_id/api_hash, shared by all accounts: they belong
      to the application, not the user. }
    function LoadConfig: boolean;

    { accounts.ini — the account list and which one was active. }
    procedure LoadAccounts;
    procedure SaveAccounts;

    function AddAccount(const ATitle: string): TTdAccount;
    { Removes an account from the registry IMMEDIATELY. Its client must
      already be closed — otherwise use DiscardAccount. }
    procedure RemoveAccount(AAccount: TTdAccount);

    { Discards an account: closes its TDLib client and removes it once
      the close is confirmed. Without closing first, the client stays
      alive inside TDLib and keeps its database directory locked. }
    procedure DiscardAccount(AAccount: TTdAccount);
    procedure Start;

    procedure SubscribeActive(const AListener: ITdActiveListener);
    procedure UnsubscribeActive(const AListener: ITdActiveListener);

    { --- compatibility: all of this addresses the ACTIVE account --- }
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);
    procedure Send(const ARequest: utf8string);
    procedure LogOut;
    function GetState: TTdAuthState;
    function GetAuth: TTdAuth;

    { Closes ALL clients — TDLib's documentation requires this before
      the application exits. Returns True if it's safe to exit right
      now. }
    function BeginShutdown(AOnComplete: TNotifyEvent): boolean;

    property Count: integer read GetCount;
    property Accounts[AIndex: integer]: TTdAccount read GetAccount;
    property Active: TTdAccount read GetActive;
    property ActiveIndex: integer read FActive write SetActiveIndex;

    property State: TTdAuthState read GetState;
    property Auth: TTdAuth read GetAuth;
    property Started: boolean read FStarted;
    property Closed: boolean read FClosed;
    property ShuttingDown: boolean read FShuttingDown;
    property ConfigError: string read FConfigError;
    property BaseDir: string read FBaseDir;
    { The name Telegram shows for this app in Active Sessions — needed
      by framesettingsgeneral.pas (the General section's text field),
      same global-TdApp access pattern as FormMain.CloseToTray/
      SetCloseToTray. }
    property DeviceModel: utf8string read FDeviceModel;
    { Changes the setting and immediately persists it to
      config.ini/[telegram] — called from TFrameSettingsGeneral, same
      pattern as TFormMain.SetCloseToTray. Only reaches TDLib the next
      time an account authenticates (TTdAccount.CreateEngine reads
      this at account-creation time) — see FDeviceModel's own comment
      for why an already-logged-in session can't be renamed. }
    procedure SetDeviceModel(const AValue: utf8string);

    property OnActiveChanged: TTdCoreEvent read FOnActiveChanged write FOnActiveChanged;
  end;

{ The registry singleton. }
function TdApp: TTdCore;

{ --- compatibility: models of the ACTIVE account --- }
function TdChatList: TTdChats;
{ Not named TdMessages: that's the name of the tdmessages unit, and the
  reference would collide with it by identifier (Pascal is case-
  insensitive) — the same pitfall as TdApp/tdcore, see ARCHITECTURE.md. }
function TdMsgList: TTdMessages;
{ Same unit-name pitfall (tdusers) as TdMsgList/tdmessages above —
  TdUsers would resolve to the unit, not the function. }
function TdUserList: TTdUsers;
function TdAccentColorList: TTdAccentColors;
{ Same unit-name pitfall (tdsupergroups) as TdMsgList/TdUserList above. }
function TdSupergroupList: TTdSupergroups;
function TdRequests: TTdRequests;

{ Unsubscribes from all accounts at once. A form may have subscribed to
  one account while a different one is active by the time it's
  destroyed. }
procedure TdUnsubscribe(const AListener: IUnknown);

function TdIsPromptState(AState: TTdAuthState): boolean;
function TdIsShuttingState(AState: TTdAuthState): boolean;

{ Wrapper so forms only need tdcore in their uses clause. }
procedure TdSessionUnsubscribe(const ASession: ITdSession; const AListener: IUnknown);

implementation

var
  GCore: TTdCore = nil;

function TdApp: TTdCore;
begin
  if GCore = nil then begin
    GCore := TTdCore.Create;
  end;
  Result := GCore;
end;

function TdChatList: TTdChats;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.Chats;
  end else begin
    Result := nil;
  end;
end;

function TdMsgList: TTdMessages;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.Messages;
  end else begin
    Result := nil;
  end;
end;

function TdUserList: TTdUsers;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.Users;
  end else begin
    Result := nil;
  end;
end;

function TdAccentColorList: TTdAccentColors;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.AccentColors;
  end else begin
    Result := nil;
  end;
end;

function TdSupergroupList: TTdSupergroups;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.Supergroups;
  end else begin
    Result := nil;
  end;
end;

function TdRequests: TTdRequests;
var
  A: TTdAccount;
begin
  A := TdApp.Active;
  if A <> nil then begin
    Result := A.Requests;
  end else begin
    Result := nil;
  end;
end;

procedure TdUnsubscribe(const AListener: IUnknown);
var
  I: integer;
begin
  if GCore = nil then begin
    Exit;
  end;
  for I := 0 to GCore.Count - 1 do begin
    GCore.Accounts[I].Unsubscribe(AListener);
  end;
end;

function TdIsPromptState(AState: TTdAuthState): boolean;
begin
  Result := tdsession.TdIsPromptState(AState);
end;

function TdIsShuttingState(AState: TTdAuthState): boolean;
begin
  Result := tdsession.TdIsShuttingState(AState);
end;

procedure TdSessionUnsubscribe(const ASession: ITdSession; const AListener: IUnknown);
begin
  tdsession.TdSessionUnsubscribe(ASession, AListener);
end;

{ ---------------- TTdCore ---------------- }

constructor TTdCore.Create;
begin
  inherited Create;
  FAccounts := TFPList.Create;
  FActive := -1;
  FBaseDir := ExtractFilePath(ParamStr(0));

  FPendingRemove := TFPList.Create;
  FRemoveTimer := TTimer.Create(nil);
  FRemoveTimer.Interval := 1;
  FRemoveTimer.OnTimer := @RemoveTick;
  FRemoveTimer.Enabled := False;

  FCloseTimer := TTimer.Create(nil);
  FCloseTimer.Enabled := False;
  FCloseTimer.Interval := SHUTDOWN_TIMEOUT;
  FCloseTimer.OnTimer := @CloseTimeout;
end;

destructor TTdCore.Destroy;
var
  I: integer;
begin
  FCloseTimer.Enabled := False;
  FRemoveTimer.Enabled := False;
  FPendingRemove.Free;
  FRemoveTimer.Free;
  for I := FAccounts.Count - 1 downto 0 do begin
    TTdAccount(FAccounts[I]).Free;
  end;
  FAccounts.Free;
  SetLength(FActiveL, 0);
  FCloseTimer.Free;
  { The receiver is stopped last: it's shared by all clients. }
  if TdReceiverExists then begin
    TdReceiver.Stop;
  end;
  inherited Destroy;
end;

function TTdCore.ManifestPath: string;
begin
  Result := FBaseDir + MANIFEST;
end;

function TTdCore.LoadConfig: boolean;
var
  Ini: TIniFile;
begin
  FConfigError := '';
  Ini := TIniFile.Create(FBaseDir + 'config.ini');
  try
    FApiId   := Ini.ReadInteger('telegram', 'api_id', 0);
    FApiHash := utf8string(Ini.ReadString('telegram', 'api_hash', ''));
    { 'FPC Desktop' default — what this always hardcoded to before it
      became a Settings > General field, so an existing config.ini
      with no [telegram]/device_model key yet sees no change. }
    FDeviceModel := utf8string(Ini.ReadString('telegram', 'device_model', 'FPC Desktop'));
  finally
    Ini.Free;
  end;

  if FApiId = 0 then begin
    FConfigError := 'api_id is not set in config.ini (section [telegram]).';
  end else if FApiHash = '' then begin
    FConfigError := 'api_hash is not set in config.ini (section [telegram]).';
  end;

  Result := FConfigError = '';
end;

procedure TTdCore.SetDeviceModel(const AValue: utf8string);
begin
  if AValue = FDeviceModel then begin
    Exit;
  end;
  FDeviceModel := AValue;
  with TIniFile.Create(FBaseDir + 'config.ini') do begin
    try
      WriteString('telegram', 'device_model', string(FDeviceModel));
    finally
      Free;
    end;
  end;
end;

procedure TTdCore.LoadAccounts;
var
  Ini: TIniFile;
  N, I, Act: integer;
  Sect, Title: string;
  Slot: integer;
  A: TTdAccount;
begin
  Ini := TIniFile.Create(ManifestPath);
  try
    N := Ini.ReadInteger('general', 'count', 0);
    Act := Ini.ReadInteger('general', 'active', 0);
    for I := 0 to N - 1 do begin
      Sect := 'acc' + IntToStr(I);
      Slot := Ini.ReadInteger(Sect, 'slot', I);
      Title := Ini.ReadString(Sect, 'title', 'Account ' + IntToStr(I + 1));
      A := TTdAccount.Create(nil, Slot, FBaseDir, Title, FApiId, FApiHash, FDeviceModel);
      A.OnInfoChanged := @AccountInfoChanged;
      A.OnStateNotify := @AccountStateNotify;
      FAccounts.Add(A);
    end;
  finally
    Ini.Free;
  end;

  { First run — create a single account. }
  if FAccounts.Count = 0 then begin
    AddAccount('Account 1');
    Act := 0;
  end;

  if (Act < 0) or (Act >= FAccounts.Count) then begin
    Act := 0;
  end;
  FActive := Act;
end;

procedure TTdCore.SaveAccounts;
var
  Ini: TIniFile;
  I: integer;
  A: TTdAccount;
begin
  Ini := TIniFile.Create(ManifestPath);
  try
    Ini.WriteInteger('general', 'count', FAccounts.Count);
    Ini.WriteInteger('general', 'active', FActive);
    for I := 0 to FAccounts.Count - 1 do begin
      A := TTdAccount(FAccounts[I]);
      Ini.WriteInteger('acc' + IntToStr(I), 'slot', A.Slot);
      Ini.WriteString('acc' + IntToStr(I), 'title', A.Title);
    end;

    { Cleans up sections for removed accounts: without this, stale
      entries would keep accumulating in the file. }
    I := FAccounts.Count;
    while Ini.SectionExists('acc' + IntToStr(I)) do begin
      Ini.EraseSection('acc' + IntToStr(I));
      Inc(I);
    end;

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function TTdCore.AddAccount(const ATitle: string): TTdAccount;
var
  I, Slot: integer;
  Used: boolean;
begin
  { The slot number is the directory name. Finds the first free one so
    a removed account's directory can be reused. }
  Slot := 0;
  repeat
    Used := False;
    for I := 0 to FAccounts.Count - 1 do begin
      if TTdAccount(FAccounts[I]).Slot = Slot then begin
        Used := True;
        Break;
      end;
    end;
    if Used then begin
      Inc(Slot);
    end;
  until not Used;

  Result := TTdAccount.Create(nil, Slot, FBaseDir, ATitle, FApiId, FApiHash, FDeviceModel);
  Result.OnInfoChanged := @AccountInfoChanged;
  Result.OnStateNotify := @AccountStateNotify;
  FAccounts.Add(Result);
  if FActive < 0 then begin
    FActive := 0;
  end;
  NotifyAccountsChanged;
end;

procedure TTdCore.RemoveAccount(AAccount: TTdAccount);
var
  Idx: integer;
begin
  if AAccount = nil then begin
    Exit;
  end;
  Idx := FAccounts.IndexOf(AAccount);
  if Idx < 0 then begin
    Exit;
  end;

  FAccounts.Delete(Idx);
  AAccount.Free;

  if FActive >= FAccounts.Count then begin
    FActive := FAccounts.Count - 1;
  end;
  SaveAccounts;
  NotifyAccountsChanged;
  NotifyActiveChanged;
end;

procedure TTdCore.DiscardAccount(AAccount: TTdAccount);
begin
  if AAccount = nil then begin
    Exit;
  end;
  { The actual removal happens via AccountStateNotify once Closed
    arrives. }
  AAccount.CloseAndForget;
end;

procedure TTdCore.SubscribeActive(const AListener: ITdActiveListener);
var
  I: integer;
begin
  if AListener = nil then begin
    Exit;
  end;
  for I := 0 to High(FActiveL) do begin
    if FActiveL[I] = AListener then begin
      Exit;
    end;
  end;
  SetLength(FActiveL, Length(FActiveL) + 1);
  FActiveL[High(FActiveL)] := AListener;
end;

procedure TTdCore.UnsubscribeActive(const AListener: ITdActiveListener);
var
  I, J: integer;
begin
  for I := High(FActiveL) downto 0 do begin
    if FActiveL[I] = AListener then begin
      for J := I to High(FActiveL) - 1 do begin
        FActiveL[J] := FActiveL[J + 1];
      end;
      SetLength(FActiveL, Length(FActiveL) - 1);
    end;
  end;
end;

procedure TTdCore.NotifyActiveChanged;
var
  Snap: array of ITdActiveListener;
  I: integer;
  A: TTdAccount;
begin
  A := GetActive;
  Snap := Copy(FActiveL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdActiveChanged(A);
  end;
  if Assigned(FOnActiveChanged) then begin
    FOnActiveChanged(Self);
  end;
end;

procedure TTdCore.NotifyAccountsChanged;
var
  Snap: array of ITdActiveListener;
  I: integer;
begin
  Snap := Copy(FActiveL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdAccountsChanged;
  end;
end;

procedure TTdCore.AccountInfoChanged(Sender: TObject);
begin
  { The name arrived via getMe — save and refresh the menu. }
  SaveAccounts;
  NotifyAccountsChanged;
end;

procedure TTdCore.AccountStateNotify(Sender: TObject);
var
  A: TTdAccount;
begin
  A := TTdAccount(Sender);

  { The account has logged out and is due for removal. Removal is
    deferred: we got here from the account's own event handler, so the
    object cannot be freed directly at this point. }
  if A.Forget and (A.State = tasNone) then begin
    if FPendingRemove.IndexOf(A) < 0 then begin
      FPendingRemove.Add(A);
      FRemoveTimer.Enabled := True;
    end;
    Exit;
  end;

  { A state change affects the "sign-in required" mark in the menu. }
  NotifyAccountsChanged;
end;

procedure TTdCore.RemoveTick(Sender: TObject);
var
  I: integer;
  A: TTdAccount;
begin
  FRemoveTimer.Enabled := False;
  for I := FPendingRemove.Count - 1 downto 0 do begin
    A := TTdAccount(FPendingRemove[I]);
    FPendingRemove.Delete(I);
    RemoveAccount(A);
  end;
end;

procedure TTdCore.Start;
var
  I: integer;
begin
  if FStarted then begin
    Exit;
  end;
  FStarted := True;

  if FAccounts.Count = 0 then begin
    LoadAccounts;
  end;

  { Starts every account: inactive ones must also receive updates,
    otherwise switching to one would start from scratch each time. }
  for I := 0 to FAccounts.Count - 1 do begin
    TTdAccount(FAccounts[I]).Start;
  end;
end;

function TTdCore.GetCount: integer;
begin
  Result := FAccounts.Count;
end;

function TTdCore.GetAccount(AIndex: integer): TTdAccount;
begin
  if (AIndex < 0) or (AIndex >= FAccounts.Count) then begin
    Result := nil;
  end else begin
    Result := TTdAccount(FAccounts[AIndex]);
  end;
end;

function TTdCore.GetActive: TTdAccount;
begin
  Result := GetAccount(FActive);
end;

procedure TTdCore.SetActiveIndex(AValue: integer);
begin
  if (AValue = FActive) or (AValue < 0) or (AValue >= FAccounts.Count) then begin
    Exit;
  end;
  FActive := AValue;
  { Saved immediately: the same account opens on next launch. }
  SaveAccounts;
  NotifyActiveChanged;
end;

{ ---------------- forwarded to the active account ---------------- }

procedure TTdCore.Subscribe(const AListener: IUnknown);
var
  A: TTdAccount;
begin
  A := GetActive;
  if A <> nil then begin
    A.Subscribe(AListener);
  end;
end;

procedure TTdCore.Unsubscribe(const AListener: IUnknown);
begin
  TdUnsubscribe(AListener);
end;

procedure TTdCore.Send(const ARequest: utf8string);
var
  A: TTdAccount;
begin
  A := GetActive;
  if A <> nil then begin
    A.Send(ARequest);
  end;
end;

procedure TTdCore.LogOut;
var
  A: TTdAccount;
begin
  A := GetActive;
  if A = nil then begin
    Exit;
  end;
  { Same as Telegram: logging out removes the account from the list.
    But if it's the last one, there's nothing to remove it to — just
    fall back to the login screen. }
  if FAccounts.Count > 1 then begin
    A.LogOutAndForget;
  end else begin
    A.LogOut;
  end;
end;

function TTdCore.GetState: TTdAuthState;
var
  A: TTdAccount;
begin
  A := GetActive;
  if A <> nil then begin
    Result := A.State;
  end else begin
    Result := tasNone;
  end;
end;

function TTdCore.GetAuth: TTdAuth;
var
  A: TTdAccount;
begin
  A := GetActive;
  if A <> nil then begin
    Result := A.Auth;
  end else begin
    Result := nil;
  end;
end;

{ ---------------- shutdown ---------------- }

function TTdCore.AllClosed: boolean;
var
  I: integer;
begin
  Result := True;
  for I := 0 to FAccounts.Count - 1 do begin
    if not TTdAccount(FAccounts[I]).Closed then begin
      Result := False;
      Exit;
    end;
  end;
end;

function TTdCore.BeginShutdown(AOnComplete: TNotifyEvent): boolean;
var
  I: integer;
begin
  if FClosed or (FAccounts.Count = 0) then begin
    Result := True;
    Exit;
  end;

  FOnShutdownComplete := AOnComplete;

  if not FShuttingDown then begin
    FShuttingDown := True;
    for I := 0 to FAccounts.Count - 1 do begin
      TTdAccount(FAccounts[I]).RequestClose;
    end;
    { The timer both polls for completion and acts as a safety net: if
      TDLib never responds, exit once the timeout elapses. }
    FCloseTimer.Interval := 200;
    FCloseTimer.Enabled := True;
  end;

  if AllClosed then begin
    FinishShutdown;
    Result := True;
    Exit;
  end;

  Result := False;
end;

procedure TTdCore.CloseTimeout(Sender: TObject);
begin
  if not FShuttingDown then begin
    FCloseTimer.Enabled := False;
    Exit;
  end;

  FCloseTimer.Tag := FCloseTimer.Tag + FCloseTimer.Interval;
  if AllClosed or (FCloseTimer.Tag >= SHUTDOWN_TIMEOUT) then begin
    FinishShutdown;
  end;
end;

procedure TTdCore.FinishShutdown;
var
  Cb: TNotifyEvent;
begin
  FCloseTimer.Enabled := False;
  if FClosed then begin
    Exit;
  end;
  FClosed := True;

  Cb := FOnShutdownComplete;
  FOnShutdownComplete := nil;
  if Assigned(Cb) then begin
    Cb(Self);
  end;
end;

initialization

finalization
  FreeAndNil(GCore);

end.
