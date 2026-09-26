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
  constants, cardpaint,
  tdjson, tdrecv, tdclient, tdauth, tdsession, tdreq, tdchats, tdmessages,
  tdstorage,
  tdusers, tdaccentcolors, tdaccount, tdcore, audiodevices, ffdecode, audioplayer, videoplayer,
  photodecoder, mediaplayer, rlottie, lottieplayer,
  uiframe, avatarcache, qrrender, msglayout, emojiassets, customemoji,
  main, splash, login, settings, framesettingsgeneral, framesettingsaudio,
  framesettingsautodownload, framesettingsstorage,
  framelog, framewelcome, framechats, framehistory,
  mediaviewer, msginput, apisetup, chatheader,
  wsframe, webfiles, localserver, webapi, webauth, webui, autodownload,
  appid
  { you can add units after this };

{$R *.res}
{ The application's icon.

  The project never had one: the exe showed the generic Windows icon,
  and Application.Icon was empty. That did not matter while the only
  tray icon lived on TFormMain and carried its own image in main.lfm -
  and it started mattering the moment the web window became the
  application and needed a tray icon of its own.

  tg.ico is that same image, lifted out of main.lfm's TrayIcon1.Icon
  .Data, so both windows show the one icon. Rebuild the resource after
  changing the file with:

    fpcres -of res -o tg_icon.res tg_icon.rc }
{$R tg_icon.res}

var
  WaitIter: integer;
  ServerPort: word;
  ServerUp: boolean;
  UseWeb: boolean;

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
  Application.Title := APP_TITLE;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;

  { Ни одна форма не должна появиться сама: кто и когда показывается,
    решают сами формы по состоянию авторизации. }
  Application.ShowMainForm := False;

  { The web UI's transport, and it goes up FIRST - before the config
    is even read.

    It used to start last, after the first-run dialog had already been
    through and the accounts were loaded. That was fine while the web
    was a second view of a running application; it is not fine now
    that signing in is being moved there, because the very first thing
    a fresh install needs is a way to be told an api_id - and a server
    that starts after that question has been asked cannot be the one
    asking it.

    Nothing here depends on the config: the port comes from the
    command line or a constant, and the command bridge reports "no
    account yet" perfectly well, that being one of the states the page
    knows how to draw.

    A refused start (port already taken) is still not fatal - the
    native window is a complete application on its own, and it is what
    the program falls back to just below. }
  ServerPort := ConfiguredServerPort;
  ServerUp := StartLocalServer(ServerPort);
  if ServerUp then begin
    WebApiStart;
  end;

  { THE WEB INTERFACE IS THE APPLICATION'S FACE.

    Its own window comes up immediately and is the only one there is:
    no splash, no login form, no main window. Signing in - including
    the api_id/api_hash a fresh install has to be told - happens in the
    page, against the same TTdAuth the native forms used to drive.

    The native forms are NOT gone. They are still built into this
    binary, still work, and are the fallback for the two ways this can
    fail: no local server (the port was taken) and no WebView2 runtime
    (nothing to host the page in). Neither is hypothetical, and in
    either case a complete native application is a far better answer
    than a program with no window at all. }
  UseWeb := ServerUp and ShowWebUi(utf8string(LocalServerUrl));

  if UseWeb then begin
    SetWebUiPrimary(True);
    { The account layer comes up as soon as there is a pair to bring it
      up with: now, if config.ini already has one, or later from the
      page's api.save. Nothing is shown or waited for here - the page
      is already on screen asking the question. }
    { The settings the native window used to read on its way up. The
      page has no screen to EDIT most of them yet - that is still the
      desktop Settings dialog - but what stands in the file has to
      apply either way. The cache ceiling is not here: pruning needs a
      live client, so it goes off the transition to Ready, see
      TWebApi.AuthChanged. }
    TdLoadPresence;
    TdLoadDownloadLimits;
    TdApp.EnsureStarted;
  end else begin

  { ---------------- the native path, to the end of this block ------ }

  { Конфиг и список аккаунтов читаются ДО создания форм: формы
    в FormCreate подписываются на активный аккаунт и обращаются
    к его модели чатов, значит аккаунт к тому моменту должен
    существовать. Клиенты TDLib при этом ещё не запущены. }
  if not TdApp.LoadConfig then begin
    { First run, or a config.ini missing/without api_id/api_hash yet —
      offer the first-run dialog instead of just failing. Application.
      CreateForm is safe to call here even though ShowMainForm=False
      further down hasn't run yet: this form is Free'd explicitly
      right after and never becomes Application.MainForm. }
    Application.CreateForm(TFormApiConfig, FormApiConfig);
    try
      if FormApiConfig.ShowModal <> mrOk then begin
        { Cancelled, or closed via the title bar/Esc without ever
          saving a valid pair — TFormApiConfig only returns mrOk once
          TdApp.LoadConfig has actually succeeded (see its
          btnOkClick), so there's nothing left to load here. }
        Application.Terminate;
        Exit;
      end;
    finally
      FormApiConfig.Free;
    end;
  end;

  TdApp.LoadAccounts;

  { Первой создаётся главная — она становится Application.MainForm,
    и её закрытие завершает приложение. }
  Application.CreateForm(TFormMain, FormMain);
  Application.CreateForm(TFormSplash, FormSplash);
  Application.CreateForm(TFormLogin, FormLogin);

  { Стартовая форма входа нацеливается на активный аккаунт.
    При переключении она перепривяжется сама (ITdActiveListener). }
  FormLogin.AttachTo(TdApp.Active, False);

  FormSplash.Show;
  TdApp.Start;

  end;   { not UseWeb }

  { Both paths end here, and end the same way: one message loop, and
    one shutdown. The decoder-thread wait below is the reason that
    matters - see its own comment. }

  { The web UI's transport, on for every launch. It used to need
    --server, which meant remembering a flag to get at the interface
    the app is being moved to — the wrong default once the web UI is
    the point rather than an experiment. --server-port=N still
    overrides the port.

    Started HERE rather than from a form because it shares nothing
    with the LCL side; it stands alongside the native UI, not inside
    it. A refused start (port already taken) is still not fatal for
    the same reason: the native window is a complete application on
    its own, and Tools -> Open web interface is where the user is
    told about it — that menu item is the only place this failure
    would otherwise surface, a GUI process having no console to
    complain to. }
  Application.Run;

  { Before the decoder-thread wait below, because this one is quick
    and its connection threads are holding an object owned by this
    unit. The server goes first and the bridge second, so that by the
    time the command queue is freed there are no socket threads left
    that could still be filling it. }
  StopLocalServer;
  WebApiStop;

  { The main form has closed and the message loop just returned —
    normal shutdown (the implicit Halt at the end of this block) is
    about to run every unit's finalization section and then call
    ExitProcess, which terminates every OTHER thread abruptly and
    starts unloading DLLs. TLottiePlayer (lottieplayer.pas) and
    TAnimationPlayer (videoplayer.pas) are both FreeOnTerminate=True,
    fire-and-forget background decoder threads — StopPlayback (called
    from widget/model destructors as the app tears down, and from
    customemoji.pas's own finalization for whatever custom emoji
    decoders are still alive purely from earlier scrolling — that unit
    never evicts them) only sets a flag; nothing waits for the thread
    to actually notice it and finish. If ExitProcess fires while one of
    them is still mid-FreeMem or mid-call into librlottie.dll/the
    ffmpeg DLLs, the thread is killed abruptly while that DLL's own
    state may already be getting torn down on this thread — a
    documented class of Windows process-teardown race, and a close
    match for a crash that only ever happens on close, inside one of
    these threads' own FreeMem calls, with nothing in heaptrc's log to
    show for it (by the time this happens, heaptrc's own bookkeeping is
    no longer trustworthy either). Give every such thread a bounded
    chance to actually finish first. Bounded, not indefinite: a
    genuinely stuck decoder (should never happen, the per-frame delay
    inside each of them is always small) must not hang application
    exit forever. }
  WaitIter := 0;
  while ((lottieplayer.LottiePlayerActiveCount > 0) or (videoplayer.AnimationPlayerActiveCount > 0))
        and (WaitIter < 300) do begin
    Sleep(10);
    Inc(WaitIter);
  end;
end.
