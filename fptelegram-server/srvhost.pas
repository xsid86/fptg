unit srvhost;

{$mode objfpc}{$H+}

{ Сервер как целое — то, чем управляют: TLS, порт, приём подключений
  (старт/стоп), клиенты TDLib, пользователи. Общий у консольного сервера и
  у окна, без LCL.

  Control — команды управления; их же получает канал экземпляра
  (instance.pas) от второго запуска или от окна-пульта, и их же окно
  вызывает напрямую, когда сервер — оно само. Одна реализация:
    status            -> состояние (StatusJson)
    start (port)      -> начать приём подключений
    stop              -> перестать принимать
    users.add (user, password) / users.password (user, password)
    users.remove (user) / users.logoutAll
    show              -> показать окно (OnShow; у консольного — ничего)
  Ответ на каждую — состояние после неё.

  «Стоп» гасит только приём подключений: клиенты TDLib поднимаются с
  первым стартом и живут до выхода (TTdCore после закрытия заново не
  поднимается). }

interface

uses
  Classes, SysUtils, fpjson, tlscert;

type
  TServerHost = class
  private
    FKind: string;
    FTls: TServerTls;
    FTlsOk: boolean;
    FTlsError: string;
    FTdStarted: boolean;
    FOnShow: TNotifyEvent;
    FOnChanged: TNotifyEvent;
    procedure Changed;
  public
    { AKind — 'console' или 'gui'. Готовит TLS (свой сертификат или
      --cert/--key). }
    constructor Create(const AKind: string);
    function Running: boolean;
    { Начать приём на APort (и, в первый раз, поднять TDLib). }
    function Start(APort: word; out AError: string): boolean;
    procedure Stop;
    { Закрыть клиентов TDLib; True — уже закрыты (или не поднимались). }
    function BeginShutdown(ADone: TNotifyEvent): boolean;
    function StatusJson: TJSONObject;
    function Control(const ACmd: string; AArgs: TJSONObject): TJSONObject;
    property TlsOk: boolean read FTlsOk;
    property TlsError: string read FTlsError;
    property Fingerprint: string read FTls.Fingerprint;
    property CertFile: string read FTls.CertFile;
    property Kind: string read FKind;
    property OnShow: TNotifyEvent read FOnShow write FOnShow;
    { Состояние поменялось (в том числе командой по каналу). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ Порт: --server-port=N, иначе выбранный в окне (conf.dat), иначе
  LOCAL_SERVER_PORT. }
function SavedPort: word;
procedure SavePort(APort: word);
function ParamValue(const APrefix: string): string;

implementation

uses
  constants, tdcore, localserver, webapi, srvauth, secureconfig;

function ParamValue(const APrefix: string): string;
var
  I: integer;
begin
  Result := '';
  for I := 1 to ParamCount do begin
    if Copy(ParamStr(I), 1, Length(APrefix)) = APrefix then begin
      Result := Copy(ParamStr(I), Length(APrefix) + 1, MaxInt);
    end;
  end;
end;

function SavedPort: word;
var
  V: integer;
  Ini: TSecureIni;
begin
  if ParamValue('--server-port=') <> '' then begin
    Result := ConfiguredServerPort;
    Exit;
  end;
  Ini := OpenConfig;
  try
    V := Ini.ReadInteger(SERVER_CONFIG_SECTION, SERVER_CONFIG_PORT, LOCAL_SERVER_PORT);
  finally
    Ini.Free;
  end;
  if (V <= 0) or (V > 65535) then begin
    V := LOCAL_SERVER_PORT;
  end;
  Result := word(V);
end;

procedure SavePort(APort: word);
var
  Ini: TSecureIni;
begin
  Ini := OpenConfig;
  try
    Ini.WriteInteger(SERVER_CONFIG_SECTION, SERVER_CONFIG_PORT, APort);
  finally
    Ini.Free;
  end;
end;

constructor TServerHost.Create(const AKind: string);
begin
  inherited Create;
  FKind := AKind;
  FTlsOk := PrepareServerTls(ParamValue('--cert='), ParamValue('--key='), FTls, FTlsError);
end;

procedure TServerHost.Changed;
begin
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

function TServerHost.Running: boolean;
begin
  Result := LocalServerUrl <> '';
end;

function TServerHost.Start(APort: word; out AError: string): boolean;
begin
  AError := '';
  Result := Running;
  if Result then begin
    Exit;
  end;
  if not FTlsOk then begin
    AError := 'TLS: ' + FTlsError;
    Exit;
  end;
  if APort = 0 then begin
    AError := 'The port is a number from 1 to 65535.';
    Exit;
  end;
  if not StartLocalServer(APort, ConfiguredBindAddress, FTls, ConfiguredWebDir) then begin
    AError := 'Could not start on port ' + IntToStr(APort)
      + ': another program is probably using it.';
    Changed;
    Exit;
  end;
  SavePort(APort);
  WebApiStart;
  if not FTdStarted then begin
    FTdStarted := True;
    TdLoadPresence;
    TdLoadDownloadLimits;
    TdApp.EnsureStarted;
  end;
  Result := True;
  Changed;
end;

procedure TServerHost.Stop;
begin
  { Сначала сервер, потом мост — чтобы к освобождению очереди команд не
    осталось потоков сокетов. }
  StopLocalServer;
  WebApiStop;
  Changed;
end;

function TServerHost.BeginShutdown(ADone: TNotifyEvent): boolean;
begin
  Result := (not FTdStarted) or TdApp.BeginShutdown(ADone);
end;

function TServerHost.StatusJson: TJSONObject;
var
  Users: TStringList;
  A: TJSONArray;
  I: integer;
begin
  Result := TJSONObject.Create;
  Result.Add('kind', FKind);
  Result.Add('running', Running);
  Result.Add('url', LocalServerUrl);
  Result.Add('address', ConfiguredBindAddress);
  Result.Add('port', SavedPort);
  if FTlsOk then begin
    Result.Add('fingerprint', FTls.Fingerprint);
  end else begin
    Result.Add('fingerprint', 'TLS: ' + FTlsError);
  end;
  Result.Add('tlsOk', FTlsOk);
  Users := TStringList.Create;
  try
    AuthUserNames(Users);
    A := TJSONArray.Create;
    for I := 0 to Users.Count - 1 do begin
      A.Add(Users[I]);
    end;
    Result.Add('users', A);
  finally
    Users.Free;
  end;
end;

function TServerHost.Control(const ACmd: string; AArgs: TJSONObject): TJSONObject;
var
  Err, UserName: string;
  Port: integer;
begin
  if AArgs <> nil then begin
    UserName := Trim(AArgs.Get('user', ''));
  end else begin
    UserName := '';
  end;
  if ACmd = 'status' then begin
    { только состояние }
  end else if ACmd = 'start' then begin
    Port := 0;
    if AArgs <> nil then begin
      Port := AArgs.Get('port', 0);
    end;
    if Port = 0 then begin
      Port := SavedPort;
    end;
    if (Port <= 0) or (Port > 65535) then begin
      raise Exception.Create('The port is a number from 1 to 65535.');
    end;
    if not Start(word(Port), Err) then begin
      raise Exception.Create(Err);
    end;
  end else if ACmd = 'stop' then begin
    Stop;
  end else if (ACmd = 'users.add') or (ACmd = 'users.password') then begin
    if UserName = '' then begin
      raise Exception.Create('No user name');
    end;
    if (ACmd = 'users.add') and AuthHasUser(UserName) then begin
      raise Exception.Create('User ' + UserName + ' already exists.');
    end;
    if (ACmd = 'users.password') and not AuthHasUser(UserName) then begin
      raise Exception.Create('No user ' + UserName + '.');
    end;
    if AArgs.Get('password', '') = '' then begin
      raise Exception.Create('Empty password');
    end;
    AuthSetPassword(UserName, AArgs.Get('password', ''));
    Changed;
  end else if ACmd = 'users.remove' then begin
    if not AuthRemoveUser(UserName) then begin
      raise Exception.Create('No user ' + UserName + '.');
    end;
    Changed;
  end else if ACmd = 'users.logoutAll' then begin
    AuthLogoutAll;
  end else if ACmd = 'show' then begin
    if Assigned(FOnShow) then begin
      FOnShow(Self);
    end;
  end else begin
    raise Exception.Create('Unknown command: ' + ACmd);
  end;
  Result := StatusJson;
end;

end.
