program fptg_client;

{$mode objfpc}{$H+}

uses
  { A PERMANENT fix, not temporary diagnostics — it removes a real,
    confirmed crash on closing the application (EAccessViolation; often no
    Pascal frame of interest in the stack at all — the crash was deep in
    the memory manager's internals, and the symptom changed from run to
    run: $FFFFFFFFFFFFFFFF one time, $B8 another, different files/buffers).
    The diagnosis took several rounds (heaptrc never caught anything,
    because it is FPC's own memory manager, not a thin wrapper over
    Windows HeapAlloc, webview2, webui; Page Heap through Image File
    Execution Options/GlobalFlag in the registry did not catch anything
    EITHER, for the same reason: it instruments only HeapAlloc, while
    FPC's built-in manager takes a few large chunks from Windows and cuts
    them into small blocks inside the process itself, bypassing HeapAlloc
    on every GetMem — Page Heap physically could not see them).

    cmem replaces FPC's memory manager with a thin wrapper over msvcrt.dll
    malloc/free/realloc — a thoroughly tested, thread-safe allocator.
    After the replacement — several clean runs of the same scenario in a
    row (stickers/custom emoji, closing the application) without a single
    crash, while WITHOUT cmem the crash reproduced on almost every such
    attempt. The conclusion (not proven line by line in the FPC RTL
    sources, but consistent with all the observations at once): FPC's
    built-in memory manager does not withstand heavy concurrent load —
    dozens of decoder threads (TLottiePlayer/TAnimationPlayer) calling
    GetMem/FreeMem at once, especially in a burst on closing — somewhere in
    its own locking/free block bookkeeping there is a race that corrupts
    its internal structures rather than the bounds of some particular
    buffer (which explains why the crash surfaced in a different file each
    time). The FIRST unit — to take over the memory manager before anything
    manages to allocate memory past it. }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Controls, Dialogs, SysUtils, fpjson, LCLIntf,
  { Units shared with the server — from fptg-server/shared (the project's
    OtherUnitFiles): only this folder is visible to the window, and an
    accidental dependency on the TDLib core will not build. Not through
    uses … in: then, when compiling a unit using them, the compiler found
    only a stale .ppu and silently took it. constants — shared values
    (APP_TITLE, the limits of the card settings), secureconfig — conf.dat
    encryption, sha256u — the server certificate's fingerprint, instance —
    the single instance. }
  constants, secureconfig, sha256u, instance, appdirs,
  guiconst, guiconn, webview2, webui, callpopup, desknotify, miniapp, appid, winframe, lsrepair
  { you can add units after this };

{$R *.res}
{ The program's icon is the Lazarus project icon: fptg-client.ico next to
  the .lpi, the build itself puts it into fptg-client.res as MAINICON
  (ide/packages/ideproject/projecticon.pas, UpdateResources). }

var
  InstanceReply: TJSONObject;
  InstanceError: string;

begin
  { Defensive, app-wide: this machine's DefaultSystemCodePage defaults to
    1251 (Windows-1251), not UTF-8 - any implicit UnicodeString/AnsiString
    conversion would otherwise silently lose non-Latin1 characters through
    the system ANSI codepage. First line of the program. }
  DefaultSystemCodePage := CP_UTF8;

  { One window per OS user: a second start shows the first one and exits
    (instance.pas). The lock is in the window's data folder (appdirs). }
  if not AcquireInstance(ClientDataDir, INSTANCE_CLIENT) then begin
    if CallInstance(ClientDataDir, INSTANCE_CLIENT, 'show', nil,
        InstanceReply, InstanceError) then begin
      InstanceReply.Free;
    end;
    Exit;
  end;

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

  { No form must appear by itself: the window shows itself. }
  Application.ShowMainForm := False;

  { The window is only a window: the server (fptg-server) is a separate
    program. The window shows the page from its own files; the page signs
    in to the server (webui.pas, guiconn.pas, connect.html). }
  if not StartWebUi then begin
    { No WebView2 Runtime — offer its installer (Microsoft). }
    if MessageDlg(APP_TITLE,
      WEBVIEW2_NEEDED_TEXT + LineEnding + LineEnding
      + 'Download the installer now? Start the program again once it is installed.',
      mtError, [mbYes, mbNo], 0) = mrYes then begin
      OpenURL(WEBVIEW2_DOWNLOAD_URL);
    end;
    Exit;
  end;
  SetWebUiPrimary(True);
  PublishInstance('client', @TFormWebUi(WebUiForm).InstanceCommand);

  Application.Run;
end.
