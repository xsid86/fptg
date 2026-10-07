program FPTelegram;

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
  { Общие с сервером модули — по пути, а не через OtherUnitFiles: так
    окну видны ровно эти два, и случайная зависимость от ядра TDLib не
    соберётся. constants — общие значения (APP_TITLE, пределы настроек
    карточек), secureconfig — шифрование conf.dat, sha256u — отпечаток
    сертификата сервера. }
  constants in '..\fptelegram-server\constants.pas',
  secureconfig in '..\fptelegram-server\secureconfig.pas',
  sha256u in '..\fptelegram-server\sha256u.pas',
  guiconst, guiconn, webview2, webui, callpopup, desknotify, miniapp, appid
  { you can add units after this };

{$R *.res}
{ Иконка программы — иконка проекта Lazarus: FPTelegram.ico рядом с
  .lpi, сборка сама кладёт её в FPTelegram.res как MAINICON
  (ide/packages/ideproject/projecticon.pas, UpdateResources). }

begin
  { Defensive, app-wide: this machine's DefaultSystemCodePage defaults to
    1251 (Windows-1251), not UTF-8 - any implicit UnicodeString/AnsiString
    conversion would otherwise silently lose non-Latin1 characters through
    the system ANSI codepage. First line of the program. }
  DefaultSystemCodePage := CP_UTF8;

  { Before any window or tray icon exists: this is what Windows files
    our notifications under, and it has to be declared while there is
    still nothing to file. See appid.pas. }
  EnsureAppId;

  RequireDerivedFormResource := True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;

  { Ни одна форма не должна появиться сама: окно показывает себя само. }
  Application.ShowMainForm := False;

  { Окно — только окно: сервер (FPTelegramServer) — отдельная программа.
    Окно показывает страницу из своих файлов; она входит на сервер
    (webui.pas, guiconn.pas, connect.html). }
  if not StartWebUi then begin
    MessageDlg(APP_TITLE,
      'The Microsoft Edge WebView2 Runtime is needed to show the interface.'
      + LineEnding + LineEnding
      + 'Install it from https://developer.microsoft.com/microsoft-edge/webview2/ '
      + 'and start the program again.',
      mtError, [mbOK], 0);
    Exit;
  end;
  SetWebUiPrimary(True);

  Application.Run;
end.
