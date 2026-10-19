unit srvhost;

{$mode objfpc}{$H+}

{ The server as a whole — what is controlled: TLS, the port, accepting
  connections (start/stop), the TDLib clients, the user. Shared by the
  console server and the window, without LCL.

  Control — the control commands; the instance channel (instance.pas)
  receives the same ones from a second start or from a remote window, and
  the window calls them directly when it is the server itself. One
  implementation:
    status            -> state (StatusJson)
    start (port)      -> start accepting connections
    stop              -> stop accepting
    user.set (user, password) -> login and password of the only user
    signOut           -> end all sessions
    log.set (on)      -> keep the raw TDLib log (tdlib_raw.log); in conf.dat
    traffic           -> traffic: telegram (TDLib <-> Telegram, all
                         accounts) and clients (server <-> windows and
                         browsers), bytes since start; the asker computes
                         the speed
    show              -> show the window (OnShow; nothing for the console one)
  The answer to each is the state after it.

  "Stop" only stops accepting connections: the TDLib clients come up with
  the first start and live until exit (TTdCore does not come up again
  after closing). }

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
    { The certificate was set by --cert/--key — the window does not change it. }
    FTlsFromCli: boolean;
    { One's own certificate from conf.dat (paths; '' — the built-in one). }
    FCertFile, FKeyFile: string;
    FTdStarted: boolean;
    FOnShow: TNotifyEvent;
    FOnChanged: TNotifyEvent;
    { Once a second: session traffic — to their pages, TDLib statistics —
      into FTg* (per account, the answers are asynchronous). }
    FTrafficTimer: TTdTimer;
    FTgSent, FTgRecv: array of Int64;
    procedure Changed;
    procedure PrepareTls;
    procedure SetTls(const ACertFile, AKeyFile: string);
    procedure TrafficTick(Sender: TObject);
    procedure NetStatsDone(Sender: TObject; const AResp: TTdResponse);
    function TrafficJson: TJSONObject;
  public
    { AKind — 'console' or 'gui'. Prepares TLS (our own certificate or
      --cert/--key). }
    constructor Create(const AKind: string);
    destructor Destroy; override;
    function Running: boolean;
    { Start accepting on APort (and, the first time, bring TDLib up). }
    function Start(APort: word; out AError: string): boolean;
    procedure Stop;
    { Close the TDLib clients; True — closed already (or never started). }
    function BeginShutdown(ADone: TNotifyEvent): boolean;
    function StatusJson: TJSONObject;
    function Control(const ACmd: string; AArgs: TJSONObject): TJSONObject;
    property TlsOk: boolean read FTlsOk;
    property TlsError: string read FTlsError;
    property Fingerprint: string read FTls.Fingerprint;
    property CertFile: string read FTls.CertFile;
    property Kind: string read FKind;
    property OnShow: TNotifyEvent read FOnShow write FOnShow;
    { The state changed (including by a command over the channel). }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ The port: --server-port=N, otherwise the one chosen in the window
  (conf.dat), otherwise
  LOCAL_SERVER_PORT. }
function SavedPort: word;
procedure SavePort(APort: word);
{ Who may connect — the first-run question (SERVER_NETWORK_*): '' — not
  asked yet. Saving also sets the address to listen on (from the next
  start; a running server restarts to take it). }
function NetworkChoice: string;
procedure SaveNetworkChoice(const AChoice: string);
function ParamValue(const APrefix: string): string;

implementation

uses
  constants, tdcore, tdaccount, tdauth, localserver, webapi, srvauth, secureconfig, tdjson,
  turnrelay;

{ --tdlib-log of the console one: the log for this run, not written to conf.dat. }
function RawLogFromCli: boolean;
var
  I: integer;
begin
  Result := False;
  for I := 1 to ParamCount do begin
    if ParamStr(I) = '--tdlib-log' then begin
      Result := True;
    end;
  end;
end;

{ The raw TDLib log at start: the checkbox from conf.dat or --tdlib-log. }
procedure PrepareRawLog;
var
  Ini: TSecureIni;
  LogOn: boolean;
begin
  Ini := OpenConfig;
  try
    LogOn := Ini.ReadBool(LOG_CONFIG_SECTION, LOG_CONFIG_RAW, False);
  finally
    Ini.Free;
  end;
  SetRawLog(LogOn or RawLogFromCli);
end;

procedure SaveRawLog(AOn: boolean);
var
  Ini: TSecureIni;
begin
  Ini := OpenConfig;
  try
    Ini.WriteBool(LOG_CONFIG_SECTION, LOG_CONFIG_RAW, AOn);
  finally
    Ini.Free;
  end;
  SetRawLog(AOn or RawLogFromCli);
end;

{ "min-max" -> the port range; False — not a range. }
function ParsePorts(const S: string; out AMin, AMax: word): boolean;
var
  P, A, B: integer;
begin
  AMin := 0;
  AMax := 0;
  P := Pos('-', S);
  Result := (P > 1) and TryStrToInt(Trim(Copy(S, 1, P - 1)), A)
    and TryStrToInt(Trim(Copy(S, P + 1, MaxInt)), B)
    and (A >= 1) and (B <= 65535) and (A <= B);
  if Result then begin
    AMin := A;
    AMax := B;
  end;
end;

{ The call relay (turnrelay.pas): conf.dat [relay], then --no-relay,
  --relay-address=IP, --relay-ports=MIN-MAX for this run. }
procedure PrepareRelay;
var
  Ini: TSecureIni;
  Cfg: TRelayConfig;
  Ports, V: string;
  I: integer;
begin
  Ini := OpenConfig;
  try
    { On by default: the page uses it only for a remote server, and in the
      Automatic mode only as one more path besides the direct ones
      (calls/relay.js) — a wrong relayed address behind a home router costs
      nothing then. }
    Cfg.Enabled := Ini.ReadBool(RELAY_CONFIG_SECTION, RELAY_CONFIG_ENABLED, True);
    Cfg.Address := Ini.ReadString(RELAY_CONFIG_SECTION, RELAY_CONFIG_ADDRESS, '');
    Ports := Ini.ReadString(RELAY_CONFIG_SECTION, RELAY_CONFIG_PORTS, '');
  finally
    Ini.Free;
  end;
  for I := 1 to ParamCount do begin
    if ParamStr(I) = '--no-relay' then begin
      Cfg.Enabled := False;
    end;
  end;
  V := ParamValue('--relay-address=');
  if V <> '' then begin
    Cfg.Address := V;
  end;
  V := ParamValue('--relay-ports=');
  if V <> '' then begin
    Ports := V;
  end;
  if not ParsePorts(Ports, Cfg.PortMin, Cfg.PortMax) then begin
    Cfg.PortMin := 0;
    Cfg.PortMax := 0;
  end;
  RelayConfigure(Cfg);
end;

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

function NetworkChoice: string;
var
  Ini: TSecureIni;
begin
  Ini := OpenConfig;
  try
    Result := Ini.ReadString(SERVER_CONFIG_SECTION, SERVER_CONFIG_NETWORK, '');
  finally
    Ini.Free;
  end;
end;

function BindFor(const AChoice: string): string;
begin
  if (AChoice = SERVER_NETWORK_LAN) or (AChoice = SERVER_NETWORK_INTERNET) then begin
    Result := SERVER_BIND_ALL;
  end else begin
    Result := LOCAL_SERVER_BIND;
  end;
end;

procedure SaveNetworkChoice(const AChoice: string);
var
  Ini: TSecureIni;
begin
  Ini := OpenConfig;
  try
    Ini.WriteString(SERVER_CONFIG_SECTION, SERVER_CONFIG_NETWORK, AChoice);
    Ini.WriteString(SERVER_CONFIG_SECTION, SERVER_CONFIG_BIND, BindFor(AChoice));
  finally
    Ini.Free;
  end;
  SetDefaultBindAddress(BindFor(AChoice));
end;

{ The address to listen on from conf.dat (the first-run question). }
procedure PrepareNetwork;
var
  Ini: TSecureIni;
begin
  Ini := OpenConfig;
  try
    SetDefaultBindAddress(Ini.ReadString(SERVER_CONFIG_SECTION, SERVER_CONFIG_BIND, ''));
  finally
    Ini.Free;
  end;
end;

constructor TServerHost.Create(const AKind: string);
begin
  inherited Create;
  FKind := AKind;
  PrepareTls;
  PrepareRawLog;
  PrepareNetwork;
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

{ networkStatistics (td_api.tl): entries — networkStatisticsEntryFile and
  networkStatisticsEntryCall, both with sent_bytes/received_bytes (int53).
  only_current — since the TDLib client started. }
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

{ Where the certificate comes from: --cert/--key, otherwise paths from
  conf.dat (the server window), otherwise the built-in self-signed one
  (tlscert). }
procedure TServerHost.PrepareTls;
var
  Ini: TSecureIni;
begin
  FTlsFromCli := (ParamValue('--cert=') <> '') or (ParamValue('--key=') <> '');
  Ini := OpenConfig;
  try
    FCertFile := Ini.ReadString(TLS_CONFIG_SECTION, TLS_CONFIG_CERT_FILE, '');
    FKeyFile := Ini.ReadString(TLS_CONFIG_SECTION, TLS_CONFIG_KEY_FILE, '');
  finally
    Ini.Free;
  end;
  if FTlsFromCli then begin
    FTlsOk := PrepareServerTls(ParamValue('--cert='), ParamValue('--key='), FTls, FTlsError);
  end else begin
    FTlsOk := PrepareServerTls(FCertFile, FKeyFile, FTls, FTlsError);
  end;
end;

{ tls.set from the window: first check the new files (an error — at once
  and with an explanation, the previous certificate stays), then save and,
  if the server is running, restart accepting — the certificate is taken
  at start. Both paths empty — the built-in self-signed one. }
procedure TServerHost.SetTls(const ACertFile, AKeyFile: string);
var
  Tls: TServerTls;
  Err: string;
  Ini: TSecureIni;
  WasRunning: boolean;
begin
  if FTlsFromCli then begin
    raise Exception.Create('The certificate is set by --cert/--key on the command line.');
  end;
  if not PrepareServerTls(ACertFile, AKeyFile, Tls, Err) then begin
    raise Exception.Create(Err);
  end;
  Ini := OpenConfig;
  try
    Ini.WriteString(TLS_CONFIG_SECTION, TLS_CONFIG_CERT_FILE, ACertFile);
    Ini.WriteString(TLS_CONFIG_SECTION, TLS_CONFIG_KEY_FILE, AKeyFile);
  finally
    Ini.Free;
  end;
  FCertFile := ACertFile;
  FKeyFile := AKeyFile;
  FTls := Tls;
  FTlsOk := True;
  FTlsError := '';
  WasRunning := Running;
  if WasRunning then begin
    Stop;
    if not Start(word(SavedPort), Err) then begin
      raise Exception.Create(Err);
    end;
  end;
  Changed;
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
  PrepareRelay;
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
  { The server first, then the bridge — so no socket threads are left by
    the time the command queue is freed. }
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
  Result.Add('certFile', FCertFile);
  Result.Add('keyFile', FKeyFile);
  Result.Add('certFromCli', FTlsFromCli);
  Result.Add('user', AuthUserName);
  Result.Add('rawLog', RawLogOn);
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
    { state only }
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
  end else if ACmd = 'tls.set' then begin
    if AArgs = nil then begin
      SetTls('', '');
    end else begin
      SetTls(Trim(AArgs.Get('certFile', '')), Trim(AArgs.Get('keyFile', '')));
    end;
  end else if ACmd = 'log.set' then begin
    SaveRawLog((AArgs <> nil) and AArgs.Get('on', False));
  end else if ACmd = 'traffic' then begin
    { Once a second from the window — without the whole state. }
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
