unit srvpanel;

{$mode objfpc}{$H+}

{ The server window (fptg-server-gui): start/stop, address (read-only; the
  running server's address — as a link to the browser), port, certificate
  fingerprint, user (the server has one); at the bottom — traffic
  (Telegram and clients: total and speed, once a second). A tray icon; the
  cross hides the window to the tray, quitting — only from the tray menu.

  Two modes — depending on who holds the server instance (instance.pas):
  - the server is the window itself: TServerHost (srvhost.pas) right here;
  - a console server is already running (a service, for instance): the
    window is a remote control for it, the same commands over the control
    channel; quitting the window does not stop the server. When the server
    ends — the window takes over the instance and starts the server itself.
  In both the commands are the same (TServerHost.Control), only the
  delivery differs (Exec).

  The layout is in srvpanel.lfm (Lazarus designer). LCL — only here;
  nothing platform-specific: the window builds under Linux too. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, Menus, Dialogs, Clipbrd, LCLIntf,
  fpjson, constants, localserver, srvhost, srvauth, instance, appdirs;

type

  { TFormServerPanel }

  TFormServerPanel = class(TForm)
    btnCopyAddress: TButton;
    btnCopyPort: TButton;
    btnSignOut: TButton;
    btnStartStop: TButton;
    btnUser: TButton;
    btnCert: TButton;
    btnKey: TButton;
    btnTlsApply: TButton;
    chkRawLog: TCheckBox;
    dlgPem: TOpenDialog;
    edtCert: TEdit;
    edtKey: TEdit;
    lblCert: TLabel;
    lblKey: TLabel;
    edtAddress: TEdit;
    edtPort: TEdit;
    edtPrint: TEdit;
    edtUser: TEdit;
    lblAddress: TLabel;
    lblPort: TLabel;
    lblPrint: TLabel;
    lblStatus: TLabel;
    lblUrl: TLabel;
    lblUser: TLabel;
    lblTgTraffic: TLabel;
    lblClTraffic: TLabel;
    pnlTraffic: TPanel;
    bvlTraffic: TBevel;
    miQuit: TMenuItem;
    miSeparator: TMenuItem;
    miShow: TMenuItem;
    miStartStop: TMenuItem;
    popTray: TPopupMenu;
    tmrGiveUp: TTimer;
    tmrPoll: TTimer;
    tmrTraffic: TTimer;
    trayIcon: TTrayIcon;
    procedure btnCopyAddressClick(Sender: TObject);
    procedure btnCopyPortClick(Sender: TObject);
    procedure btnSignOutClick(Sender: TObject);
    procedure btnStartStopClick(Sender: TObject);
    procedure btnUserClick(Sender: TObject);
    procedure btnCertClick(Sender: TObject);
    procedure btnKeyClick(Sender: TObject);
    procedure btnTlsApplyClick(Sender: TObject);
    procedure chkRawLogChange(Sender: TObject);
    procedure edtTlsChange(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lblUrlClick(Sender: TObject);
    procedure miQuitClick(Sender: TObject);
    procedure miShowClick(Sender: TObject);
    procedure tmrGiveUpTimer(Sender: TObject);
    procedure tmrPollTimer(Sender: TObject);
    procedure tmrTrafficTimer(Sender: TObject);
  private
    { nil — a remote control window for another server. }
    FHost: TServerHost;
    FRunning: boolean;
    FConnected: boolean;
    FQuitting: boolean;
    FClosed: boolean;
    { The previous traffic answer — the speed from the difference. }
    FPrevTraffic: array[0..3] of Int64;
    FPrevTick: QWord;
    { The certificate fields are being edited — the server state does not
      overwrite them until Apply is pressed. FTlsFilling — ApplyStatus
      itself is filling the fields. }
    FTlsDirty: boolean;
    FTlsFilling: boolean;
    { ApplyStatus sets the log checkbox — do not send that back. }
    FLogFilling: boolean;
    procedure PickPem(AEdit: TEdit; const ATitle: string);
    function Exec(const ACmd: string; AArgs: TJSONObject; out AError: string): boolean;
    procedure Command(const ACmd: string; AArgs: TJSONObject);
    procedure ApplyStatus(S: TJSONObject);
    procedure ShowDisconnected;
    procedure HostChanged(Sender: TObject);
    procedure HostShow(Sender: TObject);
    function PortValue(out APort: integer): boolean;
    procedure ShutdownDone(Sender: TObject);
    procedure FinishQuit;
  public
    { The server instance is ours: bring the server up here. }
    procedure InitLocal;
    { The console server holds the instance: be a remote control for it. }
    procedure InitRemote;
    procedure Reveal;
  end;

var
  FormServerPanel: TFormServerPanel;

implementation

{$R *.lfm}

function DataDir: string;
begin
  Result := ServerDataDir;
end;

{ ---------------- modes ---------------- }

procedure TFormServerPanel.FormCreate(Sender: TObject);
begin
  Caption := APP_TITLE + ' server';
  tmrGiveUp.Interval := PANEL_QUIT_GIVEUP_MS;
  tmrPoll.Interval := PANEL_REMOTE_POLL_MS;
  tmrTraffic.Interval := TRAFFIC_TICK_MS;
  tmrTraffic.Enabled := True;
  if not Application.Icon.Empty then begin
    trayIcon.Icon.Assign(Application.Icon);
  end;
  trayIcon.Visible := True;
  edtAddress.Text := ConfiguredBindAddress;
end;

procedure TFormServerPanel.FormDestroy(Sender: TObject);
begin
  FClosed := True;
  if FHost <> nil then begin
    FHost.Stop;
    FreeAndNil(FHost);
  end;
end;

procedure TFormServerPanel.InitLocal;
var
  Err: string;
begin
  tmrPoll.Enabled := False;
  AuthLoad;
  FHost := TServerHost.Create('gui');
  FHost.OnChanged := @HostChanged;
  FHost.OnShow := @HostShow;
  edtPort.Text := IntToStr(SavedPort);
  Err := '';
  if FHost.TlsOk then begin
    FHost.Start(SavedPort, Err);
  end else begin
    Err := 'TLS: ' + FHost.TlsError;
  end;
  { A second start of the window shows this window, a console one passes commands. }
  PublishInstance('gui', @FHost.Control);
  ApplyStatus(nil);
  if Err <> '' then begin
    MessageDlg(Caption, Err, mtError, [mbOK], 0);
  end;
  { Without a user nobody can sign in — ask for a login and password right away. }
  if AuthUserName = '' then begin
    btnUserClick(nil);
  end;
end;

procedure TFormServerPanel.InitRemote;
begin
  FHost := nil;
  tmrPoll.Enabled := True;
  tmrPollTimer(nil);
end;

{ A command to the server: here or over the channel. The answer is the state after it. }
function TFormServerPanel.Exec(const ACmd: string; AArgs: TJSONObject;
  out AError: string): boolean;
var
  S: TJSONObject;
begin
  AError := '';
  S := nil;
  if FHost <> nil then begin
    try
      S := FHost.Control(ACmd, AArgs);
      Result := True;
    except
      on E: Exception do begin
        AError := E.Message;
        Result := False;
      end;
    end;
    if Result then begin
      ApplyStatus(S);
    end else begin
      ApplyStatus(nil);
    end;
  end else begin
    Result := CallInstance(DataDir, INSTANCE_SERVER, ACmd, AArgs, S, AError);
    if Result then begin
      FConnected := True;
      ApplyStatus(S);
    end;
  end;
  S.Free;
end;

{ A command from a button: an error — as a message. }
procedure TFormServerPanel.Command(const ACmd: string; AArgs: TJSONObject);
var
  Err: string;
begin
  if not Exec(ACmd, AArgs, Err) then begin
    MessageDlg(Caption, Err, mtError, [mbOK], 0);
    if (FHost = nil) and not FConnected then begin
      tmrPollTimer(nil);
    end;
  end;
end;

{ The server state onto the screen. S = nil — ask our own server. }
procedure TFormServerPanel.ApplyStatus(S: TJSONObject);
var
  Own: boolean;
begin
  Own := S = nil;
  if Own then begin
    S := FHost.StatusJson;
  end;
  try
    FRunning := S.Get('running', False);
    if FRunning then begin
      lblStatus.Caption := 'Running:';
      lblUrl.Caption := S.Get('url', '');
      btnStartStop.Caption := 'Stop';
      miStartStop.Caption := 'Stop server';
    end else begin
      lblStatus.Caption := 'Stopped';
      lblUrl.Caption := '';
      btnStartStop.Caption := 'Start';
      miStartStop.Caption := 'Start server';
    end;
    if FHost = nil then begin
      lblStatus.Caption := 'Console server: ' + lblStatus.Caption;
    end;
    edtAddress.Text := S.Get('address', '');
    { The port in the field — while the server runs (a stopped one's is edited). }
    if FRunning or (edtPort.Text = '') then begin
      edtPort.Text := IntToStr(S.Get('port', 0));
    end;
    edtPort.ReadOnly := FRunning;
    edtPrint.Text := S.Get('fingerprint', '');
    btnStartStop.Enabled := S.Get('tlsOk', False);
    miStartStop.Enabled := btnStartStop.Enabled;

    lblUrl.Visible := lblUrl.Caption <> '';
    edtUser.Text := S.Get('user', '');
    { One's own certificate: paths from conf.dat; one set by the --cert/--key
      keys does not change from the window. }
    if not FTlsDirty then begin
      FTlsFilling := True;
      try
        edtCert.Text := S.Get('certFile', '');
        edtKey.Text := S.Get('keyFile', '');
      finally
        FTlsFilling := False;
      end;
    end;
    edtCert.Enabled := not S.Get('certFromCli', False);
    edtKey.Enabled := edtCert.Enabled;
    btnCert.Enabled := edtCert.Enabled;
    btnKey.Enabled := edtCert.Enabled;
    btnTlsApply.Enabled := edtCert.Enabled and FTlsDirty;
    if not edtCert.Enabled then begin
      edtCert.Hint := 'Set by --cert/--key on the command line';
      edtCert.ShowHint := True;
    end;
    btnUser.Enabled := True;
    btnSignOut.Enabled := True;
    FLogFilling := True;
    try
      chkRawLog.Checked := S.Get('rawLog', False);
    finally
      FLogFilling := False;
    end;
    trayIcon.Hint := Caption + ' - ' + lblStatus.Caption + ' ' + lblUrl.Caption;
  finally
    if Own then begin
      S.Free;
    end;
  end;
end;

procedure TFormServerPanel.ShowDisconnected;
begin
  FConnected := False;
  lblStatus.Caption := 'Console server: not answering';
  lblUrl.Caption := '';
  lblUrl.Visible := False;
  btnStartStop.Enabled := False;
  miStartStop.Enabled := False;
  btnUser.Enabled := False;
  btnSignOut.Enabled := False;
  trayIcon.Hint := Caption + ' - ' + lblStatus.Caption;
end;

{ Remote control: ask for the state. No answer — maybe it is gone: then the
  instance is free and the server becomes ours (it starts if the other one
  was running). }
procedure TFormServerPanel.tmrPollTimer(Sender: TObject);
var
  Err: string;
  WasRunning: boolean;
begin
  if FHost <> nil then begin
    tmrPoll.Enabled := False;
    Exit;
  end;
  WasRunning := FRunning;
  if Exec('status', nil, Err) then begin
    Exit;
  end;
  if AcquireInstance(DataDir, INSTANCE_SERVER) then begin
    InitLocal;
    if (not WasRunning) and (FHost <> nil) and FHost.Running then begin
      FHost.Stop;
    end;
    Exit;
  end;
  ShowDisconnected;
end;

procedure TFormServerPanel.HostChanged(Sender: TObject);
begin
  if not FClosed then begin
    ApplyStatus(nil);
  end;
end;

procedure TFormServerPanel.HostShow(Sender: TObject);
begin
  Reveal;
end;

function TFormServerPanel.PortValue(out APort: integer): boolean;
begin
  Result := TryStrToInt(Trim(edtPort.Text), APort) and (APort > 0) and (APort <= 65535);
end;

procedure TFormServerPanel.btnStartStopClick(Sender: TObject);
var
  A: TJSONObject;
  P: integer;
begin
  if FRunning then begin
    Command('stop', nil);
    Exit;
  end;
  if not PortValue(P) then begin
    MessageDlg(Caption, 'The port is a number from 1 to 65535.', mtError, [mbOK], 0);
    Exit;
  end;
  A := TJSONObject.Create;
  try
    A.Add('port', P);
    Command('start', A);
  finally
    A.Free;
  end;
end;

{ Address and port — to the clipboard: they are typed into the client's sign-in window. }
procedure TFormServerPanel.btnCopyAddressClick(Sender: TObject);
begin
  Clipboard.AsText := Trim(edtAddress.Text);
end;

procedure TFormServerPanel.btnCopyPortClick(Sender: TObject);
begin
  Clipboard.AsText := Trim(edtPort.Text);
end;

{ ---------------- traffic ---------------- }

function FormatBytes(N: Int64): string;
begin
  if N < 1024 then begin
    Result := IntToStr(N) + ' B';
  end else if N < 1024 * 1024 then begin
    Result := FormatFloat('0.0', N / 1024) + ' KB';
  end else if N < Int64(1024) * 1024 * 1024 then begin
    Result := FormatFloat('0.0', N / (1024 * 1024)) + ' MB';
  end else begin
    Result := FormatFloat('0.00', N / (Int64(1024) * 1024 * 1024)) + ' GB';
  end;
end;

{ ↓ received by the program, ↑ sent — total and speed. }
function TrafficLine(const AName: string; ARecv, ASent, ARecvSpeed, ASentSpeed: Int64): string;
begin
  { The arrows and the dot — as UTF-8 bytes: a non-ASCII literal without
    $codepage would depend on the source's encoding. }
  Result := AName + '  ' + #$E2#$86#$93 + ' ' + FormatBytes(ARecv) + ' ' + #$C2#$B7 + ' '
    + FormatBytes(ARecvSpeed) + '/s   ' + #$E2#$86#$91 + ' ' + FormatBytes(ASent)
    + ' ' + #$C2#$B7 + ' ' + FormatBytes(ASentSpeed) + '/s';
end;

{ Once a second: traffic from our own server or over the channel from the
  console one. Errors are silent — this is not a person's action (an older
  console server does not know the command). }
procedure TFormServerPanel.tmrTrafficTimer(Sender: TObject);
var
  S: TJSONObject;
  Err: string;
  Cur: array[0..3] of Int64;
  Speed: array[0..3] of Int64;
  Now64, Dt: QWord;
  I: integer;
begin
  S := nil;
  if FHost <> nil then begin
    try
      S := FHost.Control('traffic', nil);
    except
      S := nil;
    end;
  end else if FConnected then begin
    if not CallInstance(DataDir, INSTANCE_SERVER, 'traffic', nil, S, Err) then begin
      S := nil;
    end;
  end;
  if S = nil then begin
    lblTgTraffic.Caption := 'Telegram  -';
    lblClTraffic.Caption := 'Clients  -';
    FPrevTick := 0;
    Exit;
  end;
  try
    Cur[0] := S.Get('tgRecv', Int64(0));
    Cur[1] := S.Get('tgSent', Int64(0));
    Cur[2] := S.Get('clRecv', Int64(0));
    Cur[3] := S.Get('clSent', Int64(0));
  finally
    S.Free;
  end;
  Now64 := GetTickCount64;
  Dt := Now64 - FPrevTick;
  for I := 0 to 3 do begin
    { The first measurement and a counter reset (a new TDLib client) — no speed. }
    if (FPrevTick = 0) or (Dt = 0) or (Cur[I] < FPrevTraffic[I]) then begin
      Speed[I] := 0;
    end else begin
      Speed[I] := (Cur[I] - FPrevTraffic[I]) * 1000 div Int64(Dt);
    end;
    FPrevTraffic[I] := Cur[I];
  end;
  FPrevTick := Now64;
  lblTgTraffic.Caption := TrafficLine('Telegram', Cur[0], Cur[1], Speed[0], Speed[1]);
  lblClTraffic.Caption := TrafficLine('Clients', Cur[2], Cur[3], Speed[2], Speed[3]);
end;

{ The running server's address — in the default browser. }
procedure TFormServerPanel.lblUrlClick(Sender: TObject);
begin
  if lblUrl.Caption <> '' then begin
    OpenURL(lblUrl.Caption);
  end;
end;

{ ---------------- user ---------------- }

function AskPassword(const ACaption, AUser: string; out APassword: string): boolean;
var
  A, B: string;
begin
  Result := False;
  APassword := '';
  A := '';
  if not InputQuery(ACaption, 'Password for ' + AUser + ':', True, A) or (A = '') then begin
    Exit;
  end;
  B := '';
  if not InputQuery(ACaption, 'Repeat the password:', True, B) then begin
    Exit;
  end;
  if A <> B then begin
    MessageDlg(ACaption, 'The passwords do not match.', mtError, [mbOK], 0);
    Exit;
  end;
  APassword := A;
  Result := True;
end;

procedure UserCommand(AForm: TFormServerPanel; const ACmd, AUser, APassword: string);
var
  A: TJSONObject;
begin
  A := TJSONObject.Create;
  try
    A.Add('user', AUser);
    if APassword <> '' then begin
      A.Add('password', APassword);
    end;
    AForm.Command(ACmd, A);
  finally
    A.Free;
  end;
end;

{ Login and password of the only user. The same login — a password change;
  another — replacing the user (their sessions end). The locals are not
  called Name: on a form (TComponent) that is a property, and a variable
  of the same name is a Duplicate identifier. }
procedure TFormServerPanel.btnUserClick(Sender: TObject);
var
  Current, UserName, Pwd: string;
begin
  Current := Trim(edtUser.Text);
  UserName := Current;
  if not InputQuery('User', 'Login:', UserName) then begin
    Exit;
  end;
  UserName := Trim(UserName);
  if UserName = '' then begin
    Exit;
  end;
  if (Current <> '') and (UserName <> Current) and (MessageDlg('User', 'Replace ' + Current
      + ' with ' + UserName + '? Windows and browsers signed in as ' + Current
      + ' are signed out.', mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then begin
    Exit;
  end;
  if AskPassword('User', UserName, Pwd) then begin
    UserCommand(Self, 'user.set', UserName, Pwd);
  end;
end;

{ ---------------- certificate ---------------- }

procedure TFormServerPanel.PickPem(AEdit: TEdit; const ATitle: string);
begin
  dlgPem.Title := ATitle;
  if AEdit.Text <> '' then begin
    dlgPem.InitialDir := ExtractFileDir(AEdit.Text);
    dlgPem.FileName := ExtractFileName(AEdit.Text);
  end else begin
    dlgPem.FileName := '';
  end;
  if dlgPem.Execute then begin
    AEdit.Text := dlgPem.FileName;
  end;
end;

procedure TFormServerPanel.btnCertClick(Sender: TObject);
begin
  PickPem(edtCert, 'Certificate (PEM)');
end;

procedure TFormServerPanel.btnKeyClick(Sender: TObject);
begin
  PickPem(edtKey, 'Private key (PEM)');
end;

procedure TFormServerPanel.edtTlsChange(Sender: TObject);
begin
  if FTlsFilling then begin
    Exit;
  end;
  FTlsDirty := True;
  btnTlsApply.Enabled := edtCert.Enabled;
end;

{ Both paths — or neither (then the built-in self-signed one). The server
  checks the files itself and, if running, restarts accepting; a new
  certificate means a new fingerprint: the client windows will ask whether
  to trust it. }
procedure TFormServerPanel.btnTlsApplyClick(Sender: TObject);
var
  A: TJSONObject;
  Cert, Key, Err, Restart: string;
begin
  Restart := '';
  if FRunning then begin
    Restart := ' The server restarts.';
  end;
  Cert := Trim(edtCert.Text);
  Key := Trim(edtKey.Text);
  if (Cert = '') <> (Key = '') then begin
    MessageDlg('Certificate', 'Choose both the certificate and its private key, '
      + 'or clear both to use the built-in self-signed certificate.', mtWarning, [mbOK], 0);
    Exit;
  end;
  if MessageDlg('Certificate', 'Apply this certificate? The fingerprint changes, and '
      + 'client windows will ask to trust the server again.' + Restart,
      mtConfirmation, [mbYes, mbNo], 0) <> mrYes then begin
    Exit;
  end;
  A := TJSONObject.Create;
  try
    A.Add('certFile', Cert);
    A.Add('keyFile', Key);
    if Exec('tls.set', A, Err) then begin
      FTlsDirty := False;
      btnTlsApply.Enabled := False;
      Exec('status', nil, Err);
    end else begin
      MessageDlg('Certificate', Err, mtError, [mbOK], 0);
    end;
  finally
    A.Free;
  end;
end;

{ "Keep TDLib log": the raw log of the exchange with TDLib — for troubleshooting. }
procedure TFormServerPanel.chkRawLogChange(Sender: TObject);
var
  Args: TJSONObject;
begin
  if FLogFilling then begin
    Exit;
  end;
  Args := TJSONObject.Create;
  try
    Args.Add('on', chkRawLog.Checked);
    Command('log.set', Args);
  finally
    Args.Free;
  end;
end;

procedure TFormServerPanel.btnSignOutClick(Sender: TObject);
begin
  if MessageDlg('Sign out', 'End every session? All windows and browsers will have '
      + 'to sign in again.', mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
    Command('signOut', nil);
  end;
end;

{ ---------------- tray and quitting ---------------- }

procedure TFormServerPanel.Reveal;
begin
  if not Visible then begin
    Show;
  end;
  if WindowState = wsMinimized then begin
    WindowState := wsNormal;
  end;
  BringToFront;
end;

procedure TFormServerPanel.miShowClick(Sender: TObject);
begin
  Reveal;
end;

{ The cross — to the tray; quitting is only possible from the tray menu. }
procedure TFormServerPanel.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if not FClosed then begin
    CanClose := False;
    Hide;
  end;
end;

{ Quitting. The server is us: stop accepting connections, close the TDLib
  clients (otherwise the TDLib database closes dirty) and finish; the wait
  is limited. A remote control for another server: simply leave — the
  server keeps running. }
procedure TFormServerPanel.miQuitClick(Sender: TObject);
begin
  if FQuitting then begin
    Exit;
  end;
  FQuitting := True;
  tmrPoll.Enabled := False;
  Hide;
  trayIcon.Visible := False;
  if FHost = nil then begin
    FinishQuit;
    Exit;
  end;
  ReleaseInstance;
  FHost.Stop;
  if FHost.BeginShutdown(@ShutdownDone) then begin
    FinishQuit;
    Exit;
  end;
  tmrGiveUp.Enabled := True;
end;

procedure TFormServerPanel.ShutdownDone(Sender: TObject);
begin
  FinishQuit;
end;

procedure TFormServerPanel.tmrGiveUpTimer(Sender: TObject);
begin
  FinishQuit;
end;

procedure TFormServerPanel.FinishQuit;
begin
  if FClosed then begin
    Exit;
  end;
  FClosed := True;
  tmrGiveUp.Enabled := False;
  Application.Terminate;
end;

end.
