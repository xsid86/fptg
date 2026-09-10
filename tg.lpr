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
    обёртка над Windows HeapAlloc; Page Heap через Image File
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
  Forms, Dialogs, SysUtils,
  constants,
  tdjson, tdrecv, tdclient, tdauth, tdsession, tdreq, tdchats, tdmessages,
  tdusers, tdaccentcolors, tdaccount, tdcore, audiodevices, ffdecode, audioplayer, videoplayer,
  photodecoder, mediaplayer, rlottie, lottieplayer,
  uiframe, avatarcache, qrrender, msglayout,
  main, splash, login, settings, framesettingsgeneral, framesettingsaudio,
  framesettingsautodownload, framelog, framewelcome, framechats, framehistory,
  mediaviewer, msginput
  { you can add units after this };

{$R *.res}

var
  WaitIter: integer;

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

  { Конфиг и список аккаунтов читаются ДО создания форм: формы
    в FormCreate подписываются на активный аккаунт и обращаются
    к его модели чатов, значит аккаунт к тому моменту должен
    существовать. Клиенты TDLib при этом ещё не запущены. }
  if not TdApp.LoadConfig then begin
    MessageDlg('Configuration Error', TdApp.ConfigError, mtError, [mbOK], 0);
    Application.Terminate;
    Exit;
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

  Application.Run;

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
