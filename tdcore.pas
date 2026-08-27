unit tdcore;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, ExtCtrls, tdclient, tdauth;

type
  { Сырой поток JSON. Для отладочного лога. }
  ITdUpdateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1101}']
    procedure TdUpdate(const AJson: utf8string);
  end;

  { Состояние авторизации и ошибки. Реализуют все формы. }
  ITdStateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1102}']
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
  end;

  { Полный флоу авторизации. Реализует только форма входа. }
  ITdAuthListener = interface(ITdStateListener)
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1103}']
    procedure TdNeedPhoneOrQr;
    procedure TdQrLink(const ALink: utf8string);
    procedure TdNeedCode(const AInfo: TTdCodeInfo);
    procedure TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
    procedure TdNeedEmailCode(const APattern: utf8string; ALength: integer);
    procedure TdNeedPassword(const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
    procedure TdPasswordRecovery(const AEmailPattern: utf8string);
    procedure TdNeedRegistration(const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
  end;

  { Ядро. Единственный владелец клиента и автомата авторизации. }
  TTdCore = class
  private
    FClient: TTdClient;
    FAuth:   TTdAuth;

    FUpdateL: array of ITdUpdateListener;
    FStateL:  array of ITdStateListener;
    FAuthL:   array of ITdAuthListener;

    FCloseTimer:   TTimer;
    FRestartTimer: TTimer;

    FApiId:       integer;
    FApiHash:     utf8string;
    FBaseDir:     string;
    FConfigError: string;
    FStarted:     boolean;

    FState:              TTdAuthState;
    FLoggingOut:         boolean;
    FShuttingDown:       boolean;
    FClosed:             boolean;
    FOnShutdownComplete: TNotifyEvent;

    procedure CreateEngine;
    procedure DestroyEngine;

    { приёмники событий TTdAuth }
    procedure HandleUpdate(Sender: TObject; const AJson: utf8string);
    procedure HandleStateChanged(Sender: TObject; AState: TTdAuthState);
    procedure HandleError(Sender: TObject; ACode: integer; const AMessage, AContext: utf8string);
    procedure HandleNeedPhoneOrQr(Sender: TObject);
    procedure HandleQrLink(Sender: TObject; const ALink: utf8string);
    procedure HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
    procedure HandleNeedEmailAddress(Sender: TObject; AAllowApple, AAllowGoogle: boolean);
    procedure HandleNeedEmailCode(Sender: TObject; const APattern: utf8string; ALength: integer);
    procedure HandleNeedPassword(Sender: TObject; const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
    procedure HandlePasswordRecovery(Sender: TObject; const AEmailPattern: utf8string);
    procedure HandleNeedRegistration(Sender: TObject; const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);

    procedure CloseTimeout(Sender: TObject);
    procedure RestartTick(Sender: TObject);

    procedure FinishShutdown;
  public
    constructor Create;
    destructor Destroy; override;

    { Читает config.ini рядом с exe. False — параметры не заданы,
      текст причины в ConfigError. }
    function LoadConfig: boolean;

    procedure Start;

    { Подписка. Ядро само определит, какие интерфейсы поддерживает объект.
      Отписка ОБЯЗАТЕЛЬНА в FormDestroy каждой формы. }
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);

    { Отправка произвольного запроса. Идёт через ядро, а не напрямую
      в TTdClient, потому что после logOut клиент пересоздаётся. }
    procedure Send(const ARequest: utf8string);

    { Выход из аккаунта. Клиент будет пересоздан автоматически,
      флоу вернётся к вводу номера. }
    procedure LogOut;

    { Корректное завершение. True — закрывать можно прямо сейчас.
      False — ждать вызова AOnComplete. }
    function BeginShutdown(AOnComplete: TNotifyEvent): boolean;

    property Auth: TTdAuth read FAuth;
    property State: TTdAuthState read FState;
    property Started: boolean read FStarted;
    property Closed: boolean read FClosed;
    property ShuttingDown: boolean read FShuttingDown;
    property ConfigError: string read FConfigError;
    property BaseDir: string read FBaseDir;
  end;

{ Отписка, безопасная даже если ядро уже уничтожено. }
procedure TdUnsubscribe(const AListener: IUnknown);

{ Синглтон. }
function TdApp: TTdCore;

{ Состояние требует ввода от пользователя. }
function TdIsPromptState(AState: TTdAuthState): boolean;

{ Состояние — процесс выхода/закрытия. }
function TdIsShuttingState(AState: TTdAuthState): boolean;

implementation

const
  SHUTDOWN_TIMEOUT = 5000;

var
  GCore: TTdCore = nil;

function TdApp: TTdCore;
begin
  if GCore = nil then begin
    GCore := TTdCore.Create;
  end;
  Result := GCore;
end;

procedure TdUnsubscribe(const AListener: IUnknown);
begin
  if GCore <> nil then begin
    GCore.Unsubscribe(AListener);
  end;
end;

function TdIsPromptState(AState: TTdAuthState): boolean;
begin
  Result := AState in [tasWaitPhoneNumber, tasWaitOtherDeviceConfirmation,
    tasWaitEmailAddress, tasWaitEmailCode, tasWaitCode,
    tasWaitRegistration, tasWaitPassword];
end;

function TdIsShuttingState(AState: TTdAuthState): boolean;
begin
  Result := AState in [tasLoggingOut, tasClosing, tasClosed];
end;

{ ---------------- жизненный цикл ---------------- }

constructor TTdCore.Create;
begin
  inherited Create;
  FBaseDir := ExtractFilePath(ParamStr(0));
  FState := tasNone;

  FCloseTimer := TTimer.Create(nil);
  FCloseTimer.Enabled := False;
  FCloseTimer.Interval := SHUTDOWN_TIMEOUT;
  FCloseTimer.OnTimer := @CloseTimeout;

  FRestartTimer := TTimer.Create(nil);
  FRestartTimer.Enabled := False;
  FRestartTimer.Interval := 1;
  FRestartTimer.OnTimer := @RestartTick;
end;

destructor TTdCore.Destroy;
begin
  FCloseTimer.Enabled := False;
  FRestartTimer.Enabled := False;
  DestroyEngine;
  FCloseTimer.Free;
  FRestartTimer.Free;
  SetLength(FUpdateL, 0);
  SetLength(FStateL, 0);
  SetLength(FAuthL, 0);
  inherited Destroy;
end;

function TTdCore.LoadConfig: boolean;
var
  Ini: TIniFile;
begin
  FConfigError := '';
  Ini := TIniFile.Create(FBaseDir + 'config.ini');
  try
    FApiId := Ini.ReadInteger('telegram', 'api_id', 0);
    FApiHash := utf8string(Ini.ReadString('telegram', 'api_hash', ''));
  finally
    Ini.Free;
  end;

  if FApiId = 0 then begin
    FConfigError := 'В config.ini не задан api_id (секция [telegram]).';
  end else
  if FApiHash = '' then begin
    FConfigError := 'В config.ini не задан api_hash (секция [telegram]).';
  end;

  Result := FConfigError = '';
end;

procedure TTdCore.CreateEngine;
begin
  FClient := TTdClient.Create;
  { Порядок важен: TTdAuth в конструкторе встраивается в цепочку OnUpdate. }
  FClient.OnUpdate := @HandleUpdate;

  FAuth := TTdAuth.Create(FClient);
  FAuth.ApiId := FApiId;
  FAuth.ApiHash := FApiHash;
  FAuth.DatabaseDir := utf8string(FBaseDir + 'tdlib');
  FAuth.FilesDir := utf8string(FBaseDir + 'tdlib' + PathDelim + 'files');
  FAuth.DeviceModel := 'FPC Desktop';
  FAuth.ApplicationVersion := '1.0';
  FAuth.SystemLanguageCode := 'ru';

  FAuth.OnStateChanged := @HandleStateChanged;
  FAuth.OnError  := @HandleError;
  FAuth.OnNeedPhoneOrQr := @HandleNeedPhoneOrQr;
  FAuth.OnQrLink := @HandleQrLink;
  FAuth.OnNeedCode := @HandleNeedCode;
  FAuth.OnNeedEmailAddress := @HandleNeedEmailAddress;
  FAuth.OnNeedEmailCode := @HandleNeedEmailCode;
  FAuth.OnNeedPassword := @HandleNeedPassword;
  FAuth.OnPasswordRecovery := @HandlePasswordRecovery;
  FAuth.OnNeedRegistration := @HandleNeedRegistration;

  FClient.Start;
end;

procedure TTdCore.DestroyEngine;
begin
  FreeAndNil(FAuth);
  if FClient <> nil then begin
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

procedure TTdCore.Start;
begin
  if FStarted then begin
    Exit;
  end;
  FStarted := True;
  CreateEngine;
end;

{ ---------------- подписка ---------------- }

procedure TTdCore.Subscribe(const AListener: IUnknown);
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

procedure TTdCore.Unsubscribe(const AListener: IUnknown);
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

{ ---------------- раздача событий ----------------
  Списки копируются перед обходом: подписчик вправе отписаться
  прямо в обработчике. }

procedure TTdCore.HandleUpdate(Sender: TObject; const AJson: utf8string);
var
  Snap: array of ITdUpdateListener;
  I: integer;
begin
  Snap := Copy(FUpdateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdUpdate(AJson);
  end;
end;

procedure TTdCore.HandleStateChanged(Sender: TObject; AState: TTdAuthState);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  FState := AState;

  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdStateChanged(AState);
  end;

  if AState = tasClosed then begin
    if FLoggingOut then begin
      { Пересоздание отложено: сейчас мы внутри разбора пачки апдейтов. }
      FRestartTimer.Enabled := True;
    end else
    if FShuttingDown then begin
      FinishShutdown;
    end;
  end;
end;

procedure TTdCore.HandleError(Sender: TObject; ACode: integer; const AMessage, AContext: utf8string);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdError(ACode, AMessage, AContext);
  end;
end;

procedure TTdCore.HandleNeedPhoneOrQr(Sender: TObject);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPhoneOrQr;
  end;
end;

procedure TTdCore.HandleQrLink(Sender: TObject; const ALink: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdQrLink(ALink);
  end;
end;

procedure TTdCore.HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedCode(AInfo);
  end;
end;

procedure TTdCore.HandleNeedEmailAddress(Sender: TObject; AAllowApple, AAllowGoogle: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailAddress(AAllowApple, AAllowGoogle);
  end;
end;

procedure TTdCore.HandleNeedEmailCode(Sender: TObject; const APattern: utf8string; ALength: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailCode(APattern, ALength);
  end;
end;

procedure TTdCore.HandleNeedPassword(Sender: TObject; const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPassword(AHint, ARecoveryPattern, AHasRecovery);
  end;
end;

procedure TTdCore.HandlePasswordRecovery(Sender: TObject; const AEmailPattern: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdPasswordRecovery(AEmailPattern);
  end;
end;

procedure TTdCore.HandleNeedRegistration(Sender: TObject; const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedRegistration(ATosText, AShowPopup, AMinAge);
  end;
end;

{ ---------------- выход из аккаунта ---------------- }

procedure TTdCore.Send(const ARequest: utf8string);
begin
  if FClient <> nil then begin
    FClient.Send(ARequest);
  end;
end;

procedure TTdCore.LogOut;
begin
  if (FAuth = nil) or FShuttingDown then begin
    Exit;
  end;
  FLoggingOut := True;
  FAuth.LogOut;
end;

procedure TTdCore.RestartTick(Sender: TObject);
begin
  FRestartTimer.Enabled := False;
  if not FLoggingOut then begin
    Exit;
  end;
  FLoggingOut := False;

  DestroyEngine;
  FState := tasNone;
  CreateEngine;
end;

{ ---------------- завершение ---------------- }

function TTdCore.BeginShutdown(AOnComplete: TNotifyEvent): boolean;
begin
  if FClosed or (FAuth = nil) then begin
    Result := True;
    Exit;
  end;

  FOnShutdownComplete := AOnComplete;

  if not FShuttingDown then begin
    FShuttingDown := True;
    FLoggingOut := False;
    FRestartTimer.Enabled := False;
    FAuth.Close;
    FCloseTimer.Interval := SHUTDOWN_TIMEOUT;
    FCloseTimer.Enabled  := True;
  end;

  Result := False;
end;

procedure TTdCore.CloseTimeout(Sender: TObject);
begin
  FCloseTimer.Enabled := False;
  if not FShuttingDown then begin
    Exit;
  end;
  FinishShutdown;
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
