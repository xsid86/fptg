program tg;

{$mode objfpc}{$H+}

uses
  { ПОСТОЯННЫЙ фикс, не временная диагностика — устраняет реальный,
    подтверждённый краш при закрытии приложения (EAccessViolation,
    героя-Pascal-кадра в стеке часто не было вовсе — крэш глубоко в
    служебном коде менеджера памяти, симптом менялся от запуска к
    запуску: то $FFFFFFFFFFFFFFFF, то $B8, то разные файлы/буферы).
    Диагностика заняла несколько заходов (heaptrc — ни разу не поймал
    ничего, потому что сам FPC-шный менеджер памяти, не тонкая
    обёртка над Windows HeapAlloc, webview2, webui; Page Heap через Image File
    Execution Options/GlobalFlag в реестре — ТОЖЕ ничего не поймал,
    по той же причине: он инструментирует только HeapAlloc, а
    встроенный менеджер FPC берёт у Windows несколько больших кусков
    и сам режет их на мелкие блоки внутри процесса, минуя HeapAlloc
    на каждый GetMem — Page Heap физически не мог их увидеть).

    cmem подменяет менеджер памяти FPC на тонкую обёртку над
    msvcrt.dll malloc/free/realloc — многократно обкатанный,
    потокобезопасный аллокатор. После этой замены — несколько чистых
    прогонов того же сценария подряд (стикеры/кастомные эмодзи,
    закрытие приложения) без единого краша, на фоне того, что БЕЗ
    cmem этот краш воспроизводился почти при каждой такой попытке.
    Вывод (не доказан построчно в исходниках FPC RTL, но согласуется
    со всеми наблюдениями разом): встроенный менеджер памяти FPC не
    выдерживает сильную конкурентную нагрузку — десятки
    декодер-потоков (TLottiePlayer/TAnimationPlayer), одновременно
    зовущих GetMem/FreeMem, особенно кучно при закрытии — где-то в
    его собственной блокировке/учёте свободных блоков гонка, портящая
    служебные структуры, а не границы какого-то конкретного буфера
    (это и объясняет, почему крэш каждый раз всплывал в другом файле).
    ПЕРВЫМ юнитом — перехватить менеджер памяти раньше, чем что-либо
    успеет выделить память в обход него. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Controls, Dialogs, SysUtils,
  constants,
  tdjson, tdrecv, tdclient, tdauth, tdsession, tdreq, tdchats, tdmessages,
  tdstorage,
  tdusers, tdaccentcolors, tdaccount, tdcore,
  wsframe, webfiles, localserver, webapi, webauth, webui, autodownload,
  appid
  { Нативных форм больше нет (2026-10-05): интерфейс — только веб-страница
    в окне WebView2 (webui) и в браузере. Юниты форм в uses не
    возвращать — собранный без них проект и есть доказательство, что
    веб от них не зависит. }
  { you can add units after this };

{$R *.res}
{ The application's icon.

  tg.ico is the tray icon of the former native main window, lifted
  out of its .lfm when the web window became the application and
  needed a tray icon of its own. Rebuild the resource after changing
  the file with:

    fpcres -of res -o tg_icon.res tg_icon.rc }
{$R tg_icon.res}

var
  ServerPort: word;

begin
  { Defensive, app-wide belt-and-suspenders fix alongside tdrecv's own
    PreDecodeUnicodeEscapes (see its comment for the full story): this
    machine's DefaultSystemCodePage defaults to 1251 (Windows-1251),
    not UTF-8 -- any OTHER implicit UnicodeString/AnsiString conversion
    elsewhere in the app (not just fpjson's \uXXXX handling, already
    bypassed at the source in tdrecv) would otherwise silently lose
    non-Latin1 characters through the system ANSI codepage. Must run
    before anything does such a conversion, hence first line of the
    program. }
  DefaultSystemCodePage := CP_UTF8;

  { Before any window or tray icon exists: this is what Windows files
    our notifications under, and it has to be declared while there is
    still nothing to file. See appid.pas. }
  EnsureAppId;

  RequireDerivedFormResource := True;
  Application.Title:='TG Orchestrator';
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;

  { Ни одна форма не должна появиться сама: кто и когда показывается,
    решают сами формы по состоянию авторизации. }
  Application.ShowMainForm := False;

  { The web UI's transport, and it goes up FIRST - before the config
    is even read: the very first thing a fresh install needs is a way
    to be told an api_id, and the page is where that is asked. Nothing
    here depends on the config - the port comes from the command line
    or a constant, and the command bridge reports "no account yet"
    perfectly well, that being one of the states the page knows how to
    draw. }
  ServerPort := ConfiguredServerPort;
  if not StartLocalServer(ServerPort) then begin
    { Нативного окна, на которое раньше откатывались, больше нет. Почти
      всегда порт занят второй копией программы. }
    MessageDlg(APP_TITLE,
      'Could not start the local server on port ' + IntToStr(ServerPort) + '.'
      + LineEnding + LineEnding
      + 'Another copy of the program is probably running already. '
      + 'Close it, or start this one with --server-port=N.',
      mtError, [mbOK], 0);
    Exit;
  end;
  WebApiStart;

  { THE WEB INTERFACE IS THE APPLICATION'S FACE - and now the only one.
    Its own window comes up immediately: no splash, no login form, no
    main window. Signing in - including the api_id/api_hash a fresh
    install has to be told - happens in the page. }
  if not ShowWebUi(utf8string(LocalServerUrl)) then begin
    MessageDlg(APP_TITLE,
      'The Microsoft Edge WebView2 Runtime is needed to show the interface.'
      + LineEnding + LineEnding
      + 'Install it from https://developer.microsoft.com/microsoft-edge/webview2/ '
      + 'and start the program again.',
      mtError, [mbOK], 0);
    StopLocalServer;
    WebApiStop;
    Exit;
  end;
  SetWebUiPrimary(True);
  { The account layer comes up as soon as there is a pair to bring it
    up with: now, if config.ini already has one, or later from the
    page's api.save. The settings the native window used to read on
    its way up apply here too; the cache ceiling needs a live client,
    so it goes off the transition to Ready (TWebApi.AuthChanged). }
  TdLoadPresence;
  TdLoadDownloadLimits;
  TdApp.EnsureStarted;

  Application.Run;

  { The server goes first and the bridge second, so that by the time
    the command queue is freed there are no socket threads left that
    could still be filling it. }
  StopLocalServer;
  WebApiStop;
end.
