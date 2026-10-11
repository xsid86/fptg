unit srvhost;

{$mode objfpc}{$H+}

{ Сервер как целое — то, чем управляют: TLS, порт, приём подключений
  (старт/стоп), клиенты TDLib, пользователь. Общий у консольного сервера и
  у окна, без LCL.

  Control — команды управления; их же получает канал экземпляра
  (instance.pas) от второго запуска или от окна-пульта, и их же окно
  вызывает напрямую, когда сервер — оно само. Одна реализация:
    status            -> состояние (StatusJson)
    start (port)      -> начать приём подключений
    stop              -> перестать принимать
    user.set (user, password) -> логин и пароль единственного пользователя
    signOut           -> завершить все сеансы
    traffic           -> трафик: telegram (TDLib <-> Telegram, все
                         аккаунты) и clients (сервер <-> окна и браузеры),
                         байты с запуска; скорость считает спросивший
    show              -> показать окно (OnShow; у консольного — ничего)
  Ответ на каждую — состояние после неё.

  «Стоп» гасит только приём подключений: клиенты TDLib поднимаются с
  первым стартом и живут до выхода (TTdCore после закрытия заново не
  поднимается). }

interface

uses
  Classes, SysUtils, fpjson, tlscert, tdtimer, tdreq;

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
    { Раз в секунду: трафик сеансов — их страницам, статистика TDLib —
      в FTg* (по аккаунтам, ответы асинхронные). }
    FTrafficTimer: TTdTimer;
    FTgSent, FTgRecv: array of Int64;
    procedure Changed;
    procedure TrafficTick(Sender: TObject);
    procedure NetStatsDone(Sender: TObject; const AResp: TTdResponse);
    function TrafficJson: TJSONObject;
  public
    { AKind — 'console' или 'gui'. Готовит TLS (свой сертификат или
      --cert/--key). }
    constructor Create(const AKind: string);
    destructor Destroy; override;
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
  constants, tdcore, tdaccount, tdauth, localserver, webapi, srvauth, secureconfig;

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
  FTrafficTimer := TTdTimer.Create(nil);
  FTrafficTimer.Interval := TRAFFIC_TICK_MS;
  FTrafficTimer.OnTimer := @TrafficTick;
end;

destructor TServerHost.Destroy;
begin
  FreeAndNil(FTrafficTimer);
  inherited Destroy;
end;

procedure TServerHost.TrafficTick(Sender: TObject);
var
  I: integer;
  A: TTdAccount;
begin
  PushSessionTraffic;
  if not FTdStarted then begin
    Exit;
  end;
  if Length(FTgSent) <> TdApp.Count then begin
    SetLength(FTgSent, TdApp.Count);
    SetLength(FTgRecv, TdApp.Count);
  end;
  for I := 0 to TdApp.Count - 1 do begin
    A := TdApp.Accounts[I];
    if (A.Requests <> nil) and not (A.State in [tasClosing, tasClosed]) then begin
      A.Requests.SendRequest('getNetworkStatistics', '"only_current":true', @NetStatsDone, I);
    end;
  end;
end;

{ networkStatistics (td_api.tl): entries — networkStatisticsEntryFile и
  networkStatisticsEntryCall, у обоих sent_bytes/received_bytes (int53).
  only_current — с запуска клиента TDLib. }
procedure TServerHost.NetStatsDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  S, R: Int64;
begin
  if (not AResp.Success) or (AResp.Tag < 0) or (AResp.Tag > High(FTgSent)) then begin
    Exit;
  end;
  Arr := JGetArr(AResp.Obj, 'entries');
  if Arr = nil then begin
    Exit;
  end;
  S := 0;
  R := 0;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I] is TJSONObject then begin
      Inc(S, JGetInt64(TJSONObject(Arr.Items[I]), 'sent_bytes'));
      Inc(R, JGetInt64(TJSONObject(Arr.Items[I]), 'received_bytes'));
    end;
  end;
  FTgSent[AResp.Tag] := S;
  FTgRecv[AResp.Tag] := R;
end;

function TServerHost.TrafficJson: TJSONObject;
var
  I: integer;
  S, R: Int64;
begin
  Result := TJSONObject.Create;
  S := 0;
  R := 0;
  for I := 0 to High(FTgSent) do begin
    Inc(S, FTgSent[I]);
    Inc(R, FTgRecv[I]);
  end;
  Result.Add('tgSent', S);
  Result.Add('tgRecv', R);
  LocalTraffic(S, R);
  Result.Add('clSent', S);
  Result.Add('clRecv', R);
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
  Result.Add('user', AuthUserName);
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
  end else if ACmd = 'user.set' then begin
    if UserName = '' then begin
      raise Exception.Create('No user name');
    end;
    AuthSetUser(UserName, AArgs.Get('password', ''));
    Changed;
  end else if ACmd = 'signOut' then begin
    AuthLogoutAll;
  end else if ACmd = 'traffic' then begin
    { Раз в секунду от окна — без всего состояния. }
    Result := TrafficJson;
    Exit;
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
