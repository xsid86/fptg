program FPTelegramServer;

{$mode objfpc}{$H+}

{ Сервер FPTelegram: ядро TDLib, мост для страницы и HTTPS/WebSocket-
  сервер. Консольная программа без LCL — собирается и под Linux.
  Окно (FPTelegram.exe, fptelegram-gui) — отдельная программа: оно
  подключается к серверу по адресу и порту и входит логином и паролем
  (TODO.md, «Разделение на сервер и GUI»).

  Параметры:
    --server-port=N     порт (по умолчанию LOCAL_SERVER_PORT);
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
  { Менеджер памяти — как у прежнего общего exe: первым, раньше любого
    выделения. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  blcksock,
  constants, tdtimer, tdcore, localserver, webapi, srvloop, srvauth, srvconsole, tlscert;

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

{ Пароль дважды, с подтверждением. '' — человек передумал или не совпало. }
function AskNewPassword(const AUser: string): string;
var
  A, B: string;
begin
  Result := '';
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

{ Слушает ли кто-то порт сервера на этой машине — запущен ли сервер. }
function ServerRunning: boolean;
var
  S: TTCPBlockSocket;
begin
  S := TTCPBlockSocket.Create;
  try
    S.ConnectionTimeout := 1000;
    S.Connect(LOCAL_SERVER_BIND, IntToStr(ConfiguredServerPort));
    Result := S.LastError = 0;
  finally
    S.Free;
  end;
end;

{ Команды пользователей: True — выполнена, программе выходить. }
function UserCommands: boolean;
var
  Name, Pwd: string;
begin
  Result := True;
  if ((ParamValue('--add-user=') <> '') or (ParamValue('--remove-user=') <> '')
      or HasParam('--logout-all')) and ServerRunning then begin
    { Запущенный сервер держит conf.dat в памяти и при первой же своей
      записи затёр бы изменение. }
    WriteLn(ErrOutput, 'The server is running. Stop it first, then change users.');
    ExitCode := 1;
    Exit;
  end;
  Name := Trim(ParamValue('--add-user='));
  if Name <> '' then begin
    if ConsoleInteractive then begin
      Pwd := AskNewPassword(Name);
    end else begin
      { Без консоли (скрипт развёртывания): пароль — первая строка
        стандартного ввода. Конвейер PowerShell 5.1 приписывает BOM
        UTF-8 в начало и может оставить #13 в конце — не часть пароля. }
      ReadLn(Pwd);
      if Copy(Pwd, 1, 3) = #$EF#$BB#$BF then begin
        Delete(Pwd, 1, 3);
      end;
      while (Pwd <> '') and (Pwd[Length(Pwd)] in [#13, #10]) do begin
        SetLength(Pwd, Length(Pwd) - 1);
      end;
    end;
    if Pwd <> '' then begin
      AuthSetPassword(Name, Pwd);
      WriteLn('User ', Name, ' saved.');
    end;
    Exit;
  end;
  Name := Trim(ParamValue('--remove-user='));
  if Name <> '' then begin
    if AuthRemoveUser(Name) then begin
      WriteLn('User ', Name, ' removed, their sessions ended.');
    end else begin
      WriteLn(ErrOutput, 'No user ', Name, '.');
      ExitCode := 1;
    end;
    Exit;
  end;
  if HasParam('--logout-all') then begin
    AuthLogoutAll;
    WriteLn('All sessions ended: every window and browser has to sign in again.');
    Exit;
  end;
  Result := False;
end;

{ Без пользователей войти некому. За консолью — завести первого сразу. }
procedure EnsureFirstUser;
var
  Name, Pwd: string;
begin
  if AuthUserCount > 0 then begin
    Exit;
  end;
  if not ConsoleInteractive then begin
    WriteLn('No users yet: nobody can sign in. Run FPTelegramServer --add-user=NAME.');
    Exit;
  end;
  WriteLn('No users yet. Create the one you will sign in with.');
  Name := ReadLineVisible('User name: ');
  if Name = '' then begin
    WriteLn('No user created: nobody can sign in. Run FPTelegramServer --add-user=NAME.');
    Exit;
  end;
  Pwd := AskNewPassword(Name);
  if Pwd <> '' then begin
    AuthSetPassword(Name, Pwd);
    WriteLn('User ', Name, ' created.');
  end;
end;

var
  ServerPort: word;
  BindAddr, TlsError: string;
  Tls: TServerTls;

begin
  { Без этого неявные преобразования строк идут через системную кодовую
    страницу и теряют не-латиницу. }
  DefaultSystemCodePage := CP_UTF8;

  AuthLoad;
  if UserCommands then begin
    Exit;
  end;

  if not PrepareServerTls(ParamValue('--cert='), ParamValue('--key='), Tls, TlsError) then begin
    WriteLn(ErrOutput, 'TLS: ', TlsError);
    ExitCode := 1;
    Exit;
  end;

  ServerPort := ConfiguredServerPort;
  BindAddr := ConfiguredBindAddress;
  if not StartLocalServer(ServerPort, BindAddr, Tls, ConfiguredWebDir) then begin
    WriteLn(ErrOutput, 'Could not start the server on ', BindAddr, ':', ServerPort, '.');
    WriteLn(ErrOutput, 'Another copy is probably running already. '
      + 'Close it, or start this one with --server-port=N.');
    ExitCode := 1;
    Exit;
  end;
  WebApiStart;

  TdLoadPresence;
  TdLoadDownloadLimits;
  TdApp.EnsureStarted;

  WriteLn(APP_TITLE, ' server');
  WriteLn;
  EnsureFirstUser;
  WriteLn('Connection for ', APP_TITLE, ':');
  WriteLn('  Address: ', LocalServerHost);
  WriteLn('  Port:    ', ServerPort);
  if Tls.CertFile = '' then begin
    WriteLn('  Certificate (self-signed), SHA-256 fingerprint:');
  end else begin
    WriteLn('  Certificate ', Tls.CertFile, ', SHA-256 fingerprint:');
  end;
  WriteLn('    ', Tls.Fingerprint);
  WriteLn('  Users:   ', AuthUserCount);
  WriteLn;
  WriteLn('Web interface: ', LocalServerUrl);
  if BindAddr <> LOCAL_SERVER_BIND then begin
    WriteLn;
    WriteLn('Listening on ', BindAddr, ': reachable from the network.');
  end;
  WriteLn;
  WriteLn('Press Ctrl+C to stop.');

  RunUntilStopped;

  WriteLn('Stopping...');
  ShutdownCore;
  { Сначала сервер, потом мост — чтобы к освобождению очереди команд не
    осталось потоков сокетов. }
  StopLocalServer;
  WebApiStop;
  ShutdownFinished;
end.
