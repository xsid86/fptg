program FPTelegramServer;

{$mode objfpc}{$H+}

{ Сервер FPTelegram: ядро TDLib, мост для страницы и HTTP/WebSocket-
  сервер. Консольная программа без LCL — собирается и под Linux.
  Окно (FPTelegram.exe, fptelegram-gui) — отдельная программа: она
  подключается к этому серверу по адресу, порту и токену, которые он
  печатает при запуске (TODO.md, «Разделение на сервер и GUI»).

  Параметры:
    --server-port=N  порт (по умолчанию LOCAL_SERVER_PORT);
    --bind=АДРЕС     где слушать (по умолчанию 127.0.0.1 — только эта
                     машина; 0.0.0.0 — все сети, тогда токен идёт
                     открытым HTTP);
    --web-dir=ПУТЬ   папка страницы (по умолчанию ../fptelegram-gui/web);
    --new-token      выдать новый токен: прежние подключения перестанут
                     работать. }

uses
  { Менеджер памяти — как у прежнего общего exe: первым, раньше любого
    выделения. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  constants, tdtimer, tdcore, localserver, webapi, srvloop;

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

var
  ServerPort: word;
  BindAddr, Token: string;

begin
  { Без этого неявные преобразования строк идут через системную кодовую
    страницу и теряют не-латиницу. }
  DefaultSystemCodePage := CP_UTF8;

  ServerPort := ConfiguredServerPort;
  BindAddr := ConfiguredBindAddress;
  Token := ServerToken(HasParam('--new-token'));
  if not StartLocalServer(ServerPort, BindAddr, Token, ConfiguredWebDir) then begin
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
  WriteLn('Connection for ', APP_TITLE, ':');
  WriteLn('  Address: ', LocalServerHost);
  WriteLn('  Port:    ', ServerPort);
  WriteLn('  Token:   ', Token);
  WriteLn;
  WriteLn('Web interface: ', LocalServerUrl);
  if BindAddr <> LOCAL_SERVER_BIND then begin
    WriteLn;
    WriteLn('Listening on ', BindAddr, ': reachable from the network over plain HTTP.');
    WriteLn('Only the token protects the account - keep it secret.');
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
