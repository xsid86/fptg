unit srvpanel;

{$mode objfpc}{$H+}

{ Окно сервера (FPTelegramServerGui): старт/стоп, адрес (только чтение;
  адрес работающего сервера — ссылкой в браузер), порт, отпечаток
  сертификата, пользователь (он у сервера один). Значок в трее; крестик
  прячет окно в трей, выход — только из меню трея.

  Два режима — смотря, кто держит экземпляр сервера (instance.pas):
  - сервер — само окно: TServerHost (srvhost.pas) здесь же;
  - уже работает консольный сервер (например, служба): окно — пульт к
    нему, те же команды по каналу управления; выход из окна сервер не
    останавливает. Сервер завершился — окно забирает экземпляр и
    запускает сервер само.
  И там, и там команды одни (TServerHost.Control), отличается только
  доставка (Exec).

  Раскладка — в srvpanel.lfm (дизайнер Lazarus). LCL — только здесь;
  ничего платформенного: окно собирается и под Linux. }

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, Menus, Dialogs, Clipbrd, LCLIntf,
  fpjson, constants, localserver, srvhost, srvauth, instance;

type

  { TFormServerPanel }

  TFormServerPanel = class(TForm)
    btnCopyAddress: TButton;
    btnCopyPort: TButton;
    btnSignOut: TButton;
    btnStartStop: TButton;
    btnUser: TButton;
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
    miQuit: TMenuItem;
    miSeparator: TMenuItem;
    miShow: TMenuItem;
    miStartStop: TMenuItem;
    popTray: TPopupMenu;
    tmrGiveUp: TTimer;
    tmrPoll: TTimer;
    trayIcon: TTrayIcon;
    procedure btnCopyAddressClick(Sender: TObject);
    procedure btnCopyPortClick(Sender: TObject);
    procedure btnSignOutClick(Sender: TObject);
    procedure btnStartStopClick(Sender: TObject);
    procedure btnUserClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lblUrlClick(Sender: TObject);
    procedure miQuitClick(Sender: TObject);
    procedure miShowClick(Sender: TObject);
    procedure tmrGiveUpTimer(Sender: TObject);
    procedure tmrPollTimer(Sender: TObject);
  private
    { nil — окно-пульт к чужому серверу. }
    FHost: TServerHost;
    FRunning: boolean;
    FConnected: boolean;
    FQuitting: boolean;
    FClosed: boolean;
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
    { Экземпляр сервера — наш: поднять сервер здесь. }
    procedure InitLocal;
    { Экземпляр держит консольный сервер: быть пультом к нему. }
    procedure InitRemote;
    procedure Reveal;
  end;

var
  FormServerPanel: TFormServerPanel;

implementation

{$R *.lfm}

function DataDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

{ ---------------- режимы ---------------- }

procedure TFormServerPanel.FormCreate(Sender: TObject);
begin
  Caption := APP_TITLE + ' server';
  tmrGiveUp.Interval := PANEL_QUIT_GIVEUP_MS;
  tmrPoll.Interval := PANEL_REMOTE_POLL_MS;
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
  { Второй запуск окна покажет это окно, консольный — передаст команды. }
  PublishInstance('gui', @FHost.Control);
  ApplyStatus(nil);
  if Err <> '' then begin
    MessageDlg(Caption, Err, mtError, [mbOK], 0);
  end;
  { Без пользователя войти некому — сразу спросить логин и пароль. }
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

{ Команда серверу: здесь или по каналу. Ответ — состояние после неё. }
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

{ Команда от кнопки: ошибка — сообщением. }
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

{ Состояние сервера на экран. S = nil — спросить у своего сервера. }
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
    { Порт в поле — пока сервер работает (у остановленного его правят). }
    if FRunning or (edtPort.Text = '') then begin
      edtPort.Text := IntToStr(S.Get('port', 0));
    end;
    edtPort.ReadOnly := FRunning;
    edtPrint.Text := S.Get('fingerprint', '');
    btnStartStop.Enabled := S.Get('tlsOk', False);
    miStartStop.Enabled := btnStartStop.Enabled;

    lblUrl.Visible := lblUrl.Caption <> '';
    edtUser.Text := S.Get('user', '');
    btnUser.Enabled := True;
    btnSignOut.Enabled := True;
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

{ Пульт: спросить состояние. Не отвечает — может, его уже нет: тогда
  экземпляр свободен, и сервер становится нашим (запускается, если тот
  работал). }
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

{ Адрес и порт — в буфер обмена: их вводят в окне входа клиента. }
procedure TFormServerPanel.btnCopyAddressClick(Sender: TObject);
begin
  Clipboard.AsText := Trim(edtAddress.Text);
end;

procedure TFormServerPanel.btnCopyPortClick(Sender: TObject);
begin
  Clipboard.AsText := Trim(edtPort.Text);
end;

{ Адрес работающего сервера — в браузере по умолчанию. }
procedure TFormServerPanel.lblUrlClick(Sender: TObject);
begin
  if lblUrl.Caption <> '' then begin
    OpenURL(lblUrl.Caption);
  end;
end;

{ ---------------- пользователь ---------------- }

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

{ Логин и пароль единственного пользователя. Тот же логин — смена
  пароля; другой — замена пользователя (его сеансы гаснут).
  Локальные — не Name: у формы (TComponent) это свойство, и одноимённая
  переменная — Duplicate identifier. }
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

procedure TFormServerPanel.btnSignOutClick(Sender: TObject);
begin
  if MessageDlg('Sign out', 'End every session? All windows and browsers will have '
      + 'to sign in again.', mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
    Command('signOut', nil);
  end;
end;

{ ---------------- трей и выход ---------------- }

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

{ Крестик — в трей; выйти можно только из меню трея. }
procedure TFormServerPanel.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if not FClosed then begin
    CanClose := False;
    Hide;
  end;
end;

{ Выход. Сервер — мы: перестать принимать подключения, закрыть клиентов
  TDLib (иначе база TDLib закрывается грязно) и закончить; ожидание
  ограничено. Пульт к чужому серверу: просто уйти — сервер работает
  дальше. }
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
