program fptg_server;

{$mode objfpc}{$H+}

{ The fptg server: the TDLib core, the bridge for the page and the
  HTTPS/WebSocket server. A console program without LCL — it builds under
  Linux too (for a VPS and a service); the same with a window is
  fptg-server-gui. The client window (fptg-client.exe, fptg-client)
  connects to the server by address and port and signs in with a login
  and password.

  One instance per data folder (instance.pas, shared with
  fptg-server-gui): a second start does not start, but passes the user
  commands on to the running server.

  Parameters:
    --server-port=N     port (by default the one chosen in the server
                        window, or LOCAL_SERVER_PORT);
    --bind=ADDRESS      where to listen (by default 127.0.0.1 — this
                        machine only; 0.0.0.0 — all networks);
    --web-dir=PATH      the page folder (by default ../fptg-client/web);
    --cert=FILE --key=FILE  one's own TLS certificate (PEM), otherwise our
                        own self-signed one;
    --set-user=LOGIN    the user's login and password (asks for the
                        password) and exit. The server has one user: another
                        login replaces the previous one, and its sessions
                        end;
    --sign-out          end all sessions (all windows and browsers sign in
                        again) and exit;
    --tdlib-log         keep the raw TDLib log (tdlib_raw.log) for this
                        run. Off by default: it holds all the
                        correspondence in plain text;
    --no-relay          turn the call relay off (turnrelay.pas: calls go
                        through the server when the client cannot reach
                        Telegram itself);
    --relay-address=IP  the relay's public IPv4 address, when the server's
                        own interface has a private one (NAT);
    --relay-ports=A-B   UDP ports for relayed calls, to open in a firewall
                        (by default any free port). }

uses
  { The memory manager — first, before any allocation. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, fpjson,
  constants, tdtimer, localserver, srvloop, srvauth, srvconsole, srvhost, instance,
  appdirs, secureconfig, turnrelay;

{ The project's resources (fptg-server.res, written by the build): they hold
  the VERSIONINFO that tdaccount.AppVersionString gives TDLib. }
{$R *.res}

function HasParam(const AName: string): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 1 to ParamCount do begin
    if ParamStr(I) = AName then begin
      Result := True;
    end;
  end;
end;

{ The server's data lives in the user profile (appdirs.pas), not next to the exe. }
function DataDir: string;
begin
  Result := ServerDataDir;
end;

{ The password twice, with confirmation. '' — the person changed their
  mind or it did not match. Without a console (a deployment script) — the
  first line of standard input; a PowerShell 5.1 pipeline prepends a UTF-8
  BOM and may leave a #13. }
function AskNewPassword(const AUser: string): string;
var
  A, B: string;
begin
  Result := '';
  if not ConsoleInteractive then begin
    ReadLn(A);
    if Copy(A, 1, 3) = #$EF#$BB#$BF then begin
      Delete(A, 1, 3);
    end;
    while (A <> '') and (A[Length(A)] in [#13, #10]) do begin
      SetLength(A, Length(A) - 1);
    end;
    Result := A;
    Exit;
  end;
  A := ReadLineSecret('Password for ' + AUser + ': ');
  if A = '' then begin
    WriteLn('Empty password - nothing changed.');
    Exit;
  end;
  B := ReadLineSecret('Repeat the password: ');
  if A <> B then begin
    WriteLn('The passwords do not match - nothing changed.');
    Exit;
  end;
  Result := A;
end;

{ The user command from the parameters, as a control command (srvhost):
  ACmd and arguments. False — no command; ACmd = '' — the person changed
  their mind. }
function UserCommand(out ACmd: string; out AArgs: TJSONObject): boolean;
var
  UserName, Pwd: string;
begin
  Result := True;
  AArgs := TJSONObject.Create;
  UserName := Trim(ParamValue('--set-user='));
  if UserName <> '' then begin
    Pwd := AskNewPassword(UserName);
    if Pwd = '' then begin
      ACmd := '';
      Exit;
    end;
    AArgs.Add('user', UserName);
    AArgs.Add('password', Pwd);
    ACmd := 'user.set';
    Exit;
  end;
  if HasParam('--sign-out') then begin
    ACmd := 'signOut';
    Exit;
  end;
  FreeAndNil(AArgs);
  ACmd := '';
  Result := False;
end;

function IsUserCommand: boolean;
begin
  Result := (ParamValue('--set-user=') <> '') or HasParam('--sign-out');
end;

procedure ReportDone(const ACmd: string);
begin
  if ACmd = 'signOut' then begin
    WriteLn('All sessions ended: every window and browser has to sign in again.');
  end else begin
    WriteLn('User ', ParamValue('--set-user='), ' saved.');
  end;
end;

{ The server is already running (here or with a window): the user command
  goes to it, otherwise say so and exit. }
procedure ServeSecondCopy;
var
  Cmd, Err: string;
  Args, Res: TJSONObject;
begin
  if InstanceElsewhere then begin
    WriteLn(ErrOutput, 'An fptg server is already running on this computer ',
      '(another copy or another user). Only one can run per computer.');
    ExitCode := 1;
    Exit;
  end;
  if not IsUserCommand then begin
    WriteLn(ErrOutput, 'The server is already running (', InstanceKind(DataDir, INSTANCE_SERVER),
      '). Only one copy can run with this data.');
    ExitCode := 1;
    Exit;
  end;
  if not UserCommand(Cmd, Args) then begin
    Exit;
  end;
  try
    if Cmd = '' then begin
      Exit;
    end;
    if not CallInstance(DataDir, INSTANCE_SERVER, Cmd, Args, Res, Err) then begin
      WriteLn(ErrOutput, Err);
      ExitCode := 1;
      Exit;
    end;
    Res.Free;
    ReportDone(Cmd);
  finally
    Args.Free;
  end;
end;

type
  { A state changed by a command from the remote window or a second start
    — as a line in the console: otherwise "running" stays on screen even
    though connections are no longer accepted. }
  TConsoleNotes = class
    Host: TServerHost;
    WasRunning: boolean;
    procedure Changed(Sender: TObject);
  end;

procedure TConsoleNotes.Changed(Sender: TObject);
begin
  if Host.Running = WasRunning then begin
    Exit;
  end;
  WasRunning := Host.Running;
  if WasRunning then begin
    WriteLn(FormatDateTime('hh:nn:ss', Now), '  Accepting connections again.');
  end else begin
    WriteLn(FormatDateTime('hh:nn:ss', Now), '  Stopped accepting connections (from the server '
      + 'window). The process keeps running; Start in the window resumes, Ctrl+C quits.');
  end;
end;

{ Without a user nobody can sign in. At the console — set one up right away. }
procedure EnsureUser;
var
  UserName, Pwd: string;
begin
  if AuthUserName <> '' then begin
    Exit;
  end;
  if not ConsoleInteractive then begin
    WriteLn('No user yet: nobody can sign in. Run fptg-server --set-user=NAME.');
    Exit;
  end;
  WriteLn('No user yet. Choose the login and password you will sign in with.');
  UserName := ReadLineVisible('User name: ');
  if UserName = '' then begin
    WriteLn('No user created: nobody can sign in. Run fptg-server --set-user=NAME.');
    Exit;
  end;
  Pwd := AskNewPassword(UserName);
  if Pwd <> '' then begin
    AuthSetUser(UserName, Pwd);
    WriteLn('User ', UserName, ' created.');
  end;
end;

var
  Host: TServerHost;
  Notes: TConsoleNotes;
  Err, Cmd: string;
  Args: TJSONObject;

begin
  { Without this, implicit string conversions go through the system code
    page and lose non-Latin characters. }
  DefaultSystemCodePage := CP_UTF8;
  { conf.dat is in the data folder too; before the first read (AuthLoad). }
  SecureConfigSetDir(DataDir);

  if not AcquireInstance(DataDir, INSTANCE_SERVER) then begin
    ServeSecondCopy;
    Exit;
  end;

  AuthLoad;
  if UserCommand(Cmd, Args) then begin
    try
      if Cmd <> '' then begin
        if Cmd = 'user.set' then begin
          AuthSetUser(Args.Get('user', ''), Args.Get('password', ''));
        end else begin
          AuthLogoutAll;
        end;
        ReportDone(Cmd);
      end;
    finally
      Args.Free;
    end;
    Exit;
  end;

  Host := TServerHost.Create('console');
  if not Host.TlsOk then begin
    WriteLn(ErrOutput, 'TLS: ', Host.TlsError);
    ExitCode := 1;
    Exit;
  end;
  if not Host.Start(SavedPort, Err) then begin
    WriteLn(ErrOutput, Err);
    ExitCode := 1;
    Exit;
  end;
  { The control channel: the server window, when started, becomes a remote
    control for this server, a second start passes the user commands here. }
  Notes := TConsoleNotes.Create;
  Notes.Host := Host;
  Notes.WasRunning := True;
  Host.OnChanged := @Notes.Changed;
  PublishInstance('console', @Host.Control);

  WriteLn(APP_TITLE, ' server');
  WriteLn;
  EnsureUser;
  { The address and port are not printed here: they are visible and copied
    in the server window (fptg-server-gui), and a console can be in view of
    anyone. The fingerprint is no secret: the client window checks the
    certificate against it on its first sign-in. }
  if Host.CertFile = '' then begin
    WriteLn('Certificate (self-signed), SHA-256 fingerprint:');
  end else begin
    WriteLn('Certificate ', Host.CertFile, ', SHA-256 fingerprint:');
  end;
  WriteLn('  ', Host.Fingerprint);
  WriteLn('User: ', AuthUserName);
  if RelayEnabled then begin
    WriteLn('Call relay: on (TURN over TCP on the same port)');
  end else begin
    WriteLn('Call relay: off');
  end;
  if ConfiguredBindAddress <> LOCAL_SERVER_BIND then begin
    WriteLn;
    WriteLn('Reachable from the network (--bind).');
  end;
  WriteLn;
  if ConsoleInteractive then begin
    { Connection details must not stay on screen. }
    WriteLn('Press Enter to hide these details. Press Ctrl+C to stop.');
    ClearConsoleOnEnter(APP_TITLE + ' server is running. Press Ctrl+C to stop.');
  end else begin
    WriteLn('Press Ctrl+C to stop.');
  end;

  RunUntilStopped;

  WriteLn('Stopping...');
  ReleaseInstance;
  { This is quitting, not a "stop from the window" — no line about it. }
  Host.OnChanged := nil;
  Host.Stop;
  ShutdownCore;
  ShutdownFinished;
end.
