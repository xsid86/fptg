unit tdcore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, ExtCtrls,
  tdauth, tdrecv, tdsession, tdreq, tdchats, tdmessages, tdusers, tdaccount;

type
  { Псевдонимы, чтобы формам не пришлось добавлять tdsession в uses.
    Указывают на те же типы — GUID и совместимость сохраняются. }
  ITdUpdateListener = tdsession.ITdUpdateListener;
  ITdStateListener  = tdsession.ITdStateListener;
  ITdAuthListener   = tdsession.ITdAuthListener;
  ITdSession        = tdsession.ITdSession;
  TTdAccount        = tdaccount.TTdAccount;

  TTdCoreEvent = procedure(Sender: TObject) of object;

  { Смена активного аккаунта и изменение состава/имён.
    Многоадресный: слушателей будет несколько — главная форма,
    фрейм списка чатов, дальше фрейм чата. }
  ITdActiveListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1301}']
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

  { TTdCore

    Реестр аккаунтов. Сам ничего про TDLib не знает — вся работа
    в TTdAccount. Здесь: список, активный аккаунт, его сохранение
    между запусками и групповое закрытие. }

  TTdCore = class
  private
    FAccounts: TFPList;         { of TTdAccount }
    FActive: integer;
    FBaseDir: string;
    FApiId: integer;
    FApiHash: utf8string;
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

    { config.ini — api_id/api_hash, общие для всех аккаунтов:
      они принадлежат приложению, а не пользователю. }
    function LoadConfig: boolean;

    { accounts.ini — список аккаунтов и какой был активен. }
    procedure LoadAccounts;
    procedure SaveAccounts;

    function AddAccount(const ATitle: string): TTdAccount;
    { Убрать аккаунт из реестра НЕМЕДЛЕННО. Клиент при этом должен
      быть уже закрыт — иначе используй DiscardAccount. }
    procedure RemoveAccount(AAccount: TTdAccount);

    { Отменить аккаунт: закрыть клиента TDLib и убрать его, когда
      закрытие подтвердится. Без close клиент остаётся жив внутри
      TDLib и держит каталог базы заблокированным. }
    procedure DiscardAccount(AAccount: TTdAccount);
    procedure Start;

    procedure SubscribeActive(const AListener: ITdActiveListener);
    procedure UnsubscribeActive(const AListener: ITdActiveListener);

    { --- совместимость: всё это адресует АКТИВНЫЙ аккаунт --- }
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);
    procedure Send(const ARequest: utf8string);
    procedure LogOut;
    function GetState: TTdAuthState;
    function GetAuth: TTdAuth;

    { Закрывает ВСЕ клиенты: документация TDLib требует этого перед
      завершением приложения. True — можно выходить прямо сейчас. }
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

    property OnActiveChanged: TTdCoreEvent read FOnActiveChanged write FOnActiveChanged;
  end;

{ Синглтон реестра. }
function TdApp: TTdCore;

{ --- совместимость: модели АКТИВНОГО аккаунта --- }
function TdChatList: TTdChats;
{ Имя не TdMessages: так называется юнит tdmessages, и обращение
  совпало бы с ним по идентификатору (Паскаль нечувствителен к
  регистру) — та же ловушка, что у TdApp/tdcore, см. ARCHITECTURE.md. }
function TdMsgList: TTdMessages;
{ Та же ловушка с именем юнита (tdusers), что у TdMsgList/tdmessages
  выше — TdUsers обращался бы к юниту, не к функции. }
function TdUserList: TTdUsers;
function TdRequests: TTdRequests;

{ Отписка от всех аккаунтов сразу. Форма могла подписаться на один,
  а к моменту уничтожения активным быть другой. }
procedure TdUnsubscribe(const AListener: IUnknown);

function TdIsPromptState(AState: TTdAuthState): boolean;
function TdIsShuttingState(AState: TTdAuthState): boolean;

{ Обёртка, чтобы формам хватало одного tdcore в uses. }
procedure TdSessionUnsubscribe(const ASession: ITdSession; const AListener: IUnknown);

implementation

const
  SHUTDOWN_TIMEOUT = 5000;
  MANIFEST = 'accounts.ini';

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
  { Приёмник гасим последним: он общий для всех клиентов. }
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
      A := TTdAccount.Create(nil, Slot, FBaseDir, Title, FApiId, FApiHash);
      A.OnInfoChanged := @AccountInfoChanged;
      A.OnStateNotify := @AccountStateNotify;
      FAccounts.Add(A);
    end;
  finally
    Ini.Free;
  end;

  { Первый запуск — заводим один аккаунт. }
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

    { Подчищаем секции от удалённых аккаунтов: без этого в файле
      копится мусор от прежних записей. }
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
  { Номер слота — имя каталога. Ищем первый свободный, чтобы после
    удаления аккаунта его каталог мог переиспользоваться. }
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

  Result := TTdAccount.Create(nil, Slot, FBaseDir, ATitle, FApiId, FApiHash);
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
  { Удаление произойдёт по AccountStateNotify, когда придёт Closed. }
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
  { Имя пришло из getMe — сохраняем и обновляем меню. }
  SaveAccounts;
  NotifyAccountsChanged;
end;

procedure TTdCore.AccountStateNotify(Sender: TObject);
var
  A: TTdAccount;
begin
  A := TTdAccount(Sender);

  { Аккаунт вышел и подлежит удалению. Удаляем отложенно: сюда мы
    попали из его собственного обработчика, освобождать объект
    прямо отсюда нельзя. }
  if A.Forget and (A.State = tasNone) then begin
    if FPendingRemove.IndexOf(A) < 0 then begin
      FPendingRemove.Add(A);
      FRemoveTimer.Enabled := True;
    end;
    Exit;
  end;

  { Смена состояния влияет на пометку «нужен вход» в меню. }
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

  { Запускаем все: неактивные аккаунты тоже должны получать
    сообщения, иначе переключение будет каждый раз с нуля. }
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
  { Сохраняем сразу: при следующем запуске откроется тот же аккаунт. }
  SaveAccounts;
  NotifyActiveChanged;
end;

{ ---------------- проброс на активный аккаунт ---------------- }

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
  { Как в Telegram: выход убирает аккаунт из списка. Но если он
    последний — убирать некуда, просто возвращаемся к экрану входа. }
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

{ ---------------- завершение ---------------- }

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
    { Таймер и опрашивает готовность, и служит страховкой:
      если TDLib не ответит, выйдем по истечении срока. }
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
