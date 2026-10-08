program FPTelegramServer;

{$mode objfpc}{$H+}

{ Сервер FPTelegram: ядро TDLib, мост для страницы и HTTPS/WebSocket-
  сервер. Консольная программа без LCL — собирается и под Linux (для VPS
  и службы); то же с окном — FPTelegramServerGui. Окно клиента
  (FPTelegram.exe, fptelegram-gui) подключается к серверу по адресу и
  порту и входит логином и паролем.

  Один экземпляр на папку данных (instance.pas, общий с
  FPTelegramServerGui): второй запуск не стартует, а команды
  пользователей передаёт работающему серверу.

  Параметры:
    --server-port=N     порт (по умолчанию — выбранный в окне сервера
                        или LOCAL_SERVER_PORT);
    --bind=АДРЕС        где слушать (по умолчанию 127.0.0.1 — только эта
                        машина; 0.0.0.0 — все сети);
    --web-dir=ПУТЬ      папка страницы (по умолчанию ../fptelegram-gui/web);
    --cert=ФАЙЛ --key=ФАЙЛ  свой сертификат TLS (PEM), иначе свой
                        самоподписанный;
    --add-user=ИМЯ      добавить пользователя или сменить ему пароль
                        (спросит пароль) и выйти;
    --remove-user=ИМЯ   удалить пользователя и его сеансы и выйти;
    --logout-all        завершить все сеансы (все окна и браузеры
                        войдут заново) и выйти. }

uses
  { Менеджер памяти — первым, раньше любого выделения. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, fpjson,
  constants, tdtimer, localserver, srvloop, srvauth, srvconsole, srvhost, instance;

{ Ресурсы проекта (FPTelegramServer.res, его пишет сборка): в них
  VERSIONINFO, которую tdaccount.AppVersionString отдаёт TDLib. }
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

function DataDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

{ Пароль дважды, с подтверждением. '' — человек передумал или не совпало.
  Без консоли (скрипт развёртывания) — первая строка стандартного ввода;
  конвейер PowerShell 5.1 приписывает BOM UTF-8 и может оставить #13. }
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

{ Команда пользователей из параметров, как команда управления (srvhost):
  ACmd и аргументы. False — команды нет. }
function UserCommand(out ACmd: string; out AArgs: TJSONObject): boolean;
var
  UserName, Pwd: string;
begin
  Result := True;
  AArgs := TJSONObject.Create;
  UserName := Trim(ParamValue('--add-user='));
  if UserName <> '' then begin
    Pwd := AskNewPassword(UserName);
    if Pwd = '' then begin
      ACmd := '';
      Exit;
    end;
    AArgs.Add('user', UserName);
    AArgs.Add('password', Pwd);
    { Есть такой — сменить пароль. }
    if AuthHasUser(UserName) then begin
      ACmd := 'users.password';
    end else begin
      ACmd := 'users.add';
    end;
    Exit;
  end;
  UserName := Trim(ParamValue('--remove-user='));
  if UserName <> '' then begin
    AArgs.Add('user', UserName);
    ACmd := 'users.remove';
    Exit;
  end;
  if HasParam('--logout-all') then begin
    ACmd := 'users.logoutAll';
    Exit;
  end;
  FreeAndNil(AArgs);
  ACmd := '';
  Result := False;
end;

function IsUserCommand: boolean;
begin
  Result := (ParamValue('--add-user=') <> '') or (ParamValue('--remove-user=') <> '')
    or HasParam('--logout-all');
end;

procedure ReportDone(const ACmd: string);
begin
  if ACmd = 'users.logoutAll' then begin
    WriteLn('All sessions ended: every window and browser has to sign in again.');
  end else if ACmd = 'users.remove' then begin
    WriteLn('User ', ParamValue('--remove-user='), ' removed, their sessions ended.');
  end else begin
    WriteLn('User ', ParamValue('--add-user='), ' saved.');
  end;
end;

{ Сервер уже запущен (здесь или с окном): команду пользователей — ему,
  иначе — сказать и выйти. }
procedure ServeSecondCopy;
var
  Cmd, Err: string;
  Args, Res: TJSONObject;
begin
  if not IsUserCommand then begin
    WriteLn(ErrOutput, 'The server is already running (', InstanceKind(DataDir, INSTANCE_SERVER),
      '). Only one copy can run with this data.');
    ExitCode := 1;
    Exit;
  end;
  { Имя для users.add/users.password решает работающий сервер — здесь
    пользователей не загрузить (conf.dat держит он). }
  if not UserCommand(Cmd, Args) then begin
    Exit;
  end;
  try
    if Cmd = '' then begin
      Exit;
    end;
    if Cmd = 'users.password' then begin
      Cmd := 'users.add';
    end;
    if not CallInstance(DataDir, INSTANCE_SERVER, Cmd, Args, Res, Err) then begin
      { Пользователь уже есть — это смена пароля. }
      if (Cmd = 'users.add') and (Pos('already exists', Err) > 0) then begin
        Cmd := 'users.password';
        if not CallInstance(DataDir, INSTANCE_SERVER, Cmd, Args, Res, Err) then begin
          WriteLn(ErrOutput, Err);
          ExitCode := 1;
          Exit;
        end;
      end else begin
        WriteLn(ErrOutput, Err);
        ExitCode := 1;
        Exit;
      end;
    end;
    Res.Free;
    ReportDone(Cmd);
  finally
    Args.Free;
  end;
end;

type
  { Состояние, поменявшееся командой из окна-пульта или второго запуска,
    — строкой в консоли: иначе на экране так и висит «running», хотя
    подключения уже не принимаются. }
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

{ Без пользователей войти некому. За консолью — завести первого сразу. }
procedure EnsureFirstUser;
var
  UserName, Pwd: string;
begin
  if AuthUserCount > 0 then begin
    Exit;
  end;
  if not ConsoleInteractive then begin
    WriteLn('No users yet: nobody can sign in. Run FPTelegramServer --add-user=NAME.');
    Exit;
  end;
  WriteLn('No users yet. Create the one you will sign in with.');
  UserName := ReadLineVisible('User name: ');
  if UserName = '' then begin
    WriteLn('No user created: nobody can sign in. Run FPTelegramServer --add-user=NAME.');
    Exit;
  end;
  Pwd := AskNewPassword(UserName);
  if Pwd <> '' then begin
    AuthSetPassword(UserName, Pwd);
    WriteLn('User ', UserName, ' created.');
  end;
end;

var
  Host: TServerHost;
  Notes: TConsoleNotes;
  Err, Cmd: string;
  Args: TJSONObject;

begin
  { Без этого неявные преобразования строк идут через системную кодовую
    страницу и теряют не-латиницу. }
  DefaultSystemCodePage := CP_UTF8;

  if not AcquireInstance(DataDir, INSTANCE_SERVER) then begin
    ServeSecondCopy;
    Exit;
  end;

  AuthLoad;
  if UserCommand(Cmd, Args) then begin
    try
      if Cmd <> '' then begin
        if Cmd = 'users.add' then begin
          AuthSetPassword(Args.Get('user', ''), Args.Get('password', ''));
        end else if Cmd = 'users.password' then begin
          AuthSetPassword(Args.Get('user', ''), Args.Get('password', ''));
        end else if Cmd = 'users.remove' then begin
          if not AuthRemoveUser(Args.Get('user', '')) then begin
            WriteLn(ErrOutput, 'No user ', Args.Get('user', ''), '.');
            ExitCode := 1;
            Exit;
          end;
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
  { Канал управления: окно сервера при запуске станет пультом к этому
    серверу, второй запуск передаст сюда команды пользователей. }
  Notes := TConsoleNotes.Create;
  Notes.Host := Host;
  Notes.WasRunning := True;
  Host.OnChanged := @Notes.Changed;
  PublishInstance('console', @Host.Control);

  WriteLn(APP_TITLE, ' server');
  WriteLn;
  EnsureFirstUser;
  { Адрес и порт сюда не выводятся: их видно и копируют в окне сервера
    (FPTelegramServerGui), а консоль бывает на виду у кого угодно. Отпечаток
    — не секрет: им сверяют сертификат при первом входе окна клиента. }
  if Host.CertFile = '' then begin
    WriteLn('Certificate (self-signed), SHA-256 fingerprint:');
  end else begin
    WriteLn('Certificate ', Host.CertFile, ', SHA-256 fingerprint:');
  end;
  WriteLn('  ', Host.Fingerprint);
  WriteLn('Users: ', AuthUserCount);
  if ConfiguredBindAddress <> LOCAL_SERVER_BIND then begin
    WriteLn;
    WriteLn('Reachable from the network (--bind).');
  end;
  WriteLn;
  if ConsoleInteractive then begin
    { Данные подключения не должны оставаться на экране. }
    WriteLn('Press Enter to hide these details. Press Ctrl+C to stop.');
    ClearConsoleOnEnter(APP_TITLE + ' server is running. Press Ctrl+C to stop.');
  end else begin
    WriteLn('Press Ctrl+C to stop.');
  end;

  RunUntilStopped;

  WriteLn('Stopping...');
  ReleaseInstance;
  { Это выход, а не «стоп из окна» — без строки о нём. }
  Host.OnChanged := nil;
  Host.Stop;
  ShutdownCore;
  ShutdownFinished;
end.
