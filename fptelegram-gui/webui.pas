unit webui;

{ The window that hosts the web UI in an embedded Edge (WebView2)
  instead of handing the URL to whatever the default browser is.

  Built in code rather than from a .lfm because there is nothing to
  design: the whole client area belongs to a native child window owned
  by the WebView2 runtime, and no LCL control ever sits on it. Same
  reasoning as TMediaViewerPanel.

  It talks to the same local server the browser did - one URL, one
  token, one implementation. Nothing here knows about TDLib. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Forms, Controls, Dialogs, LCLIntf, ExtCtrls,
  Menus,
  constants, webview2;

type
  TFormWebUi = class(TForm)
  private
    FView: TWebView2;
    FFailed: boolean;
    FFullScreen: boolean;
    { Set when it was the PAGE that asked for fullscreen (a video's own
      button), so that leaving element fullscreen only gives the window
      back if the window was not already fullscreen by F11. }
    FByElement: boolean;
    FSavedStyle: PtrInt;
    FSavedPlacement: TWindowPlacement;

    { Only built when this window is the application (SetWebUiPrimary).
      As a second view it has no business owning a tray icon - the
      native main window already has one. }
    FTray: TTrayIcon;
    { A real quit, as opposed to the close button with close-to-tray
      on. Set by the tray's Exit and nothing else. }
    FQuitting: boolean;
    { TDLib has confirmed every client is closed, so the window may
      actually go. }
    FTdClosed: boolean;
    FGiveUp: TTimer;

    procedure TrayShowClick(Sender: TObject);
    procedure TrayQuitClick(Sender: TObject);
    procedure TrayDblClick(Sender: TObject);
    procedure ShutdownDone(Sender: TObject);
    procedure GiveUpTick(Sender: TObject);
    procedure ViewExternalUri(Sender: TObject; const AUri: utf8string);
    procedure ViewUnavailable(Sender: TObject; const AMessage: string);
    procedure ViewAcceleratorKey(Sender: TObject; AVirtualKey: word;
      var AHandled: boolean);
    procedure ViewFullScreenElement(Sender: TObject; AActive: boolean);
    procedure ViewMessage(Sender: TObject; const AText: UnicodeString);
  protected
    procedure DoClose(var CloseAction: TCloseAction); override;
    function CloseQuery: boolean; override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure Resize; override;
    procedure Open(const AUrl: utf8string);
    { Builds the tray icon. Called once, by SetWebUiPrimary. }
    procedure SetupTray;
    { Показать окно и вывести вперёд — как двойной клик по трею. }
    procedure Reveal;
    { Is the user actually looking at this window? Visible is not
      enough - a window behind three others is as unseen as a hidden
      one, and that is exactly when a notification has to leave the
      page and become a system one. }
    function IsShowing: boolean;
    { F11, and the page's own fullscreen, both end up here. }
    procedure SetFullScreen(AOn: boolean);
    property FullScreen: boolean read FFullScreen;
  end;

{ Shows the web UI in its own window, creating it on first use. Returns
  False when there is no WebView2 runtime to host it - the caller then
  decides what to tell the user. }
function ShowWebUi(const AUrl: utf8string): boolean;

{ True while the web window is the one the user is looking at. False
  when it is hidden in the tray, minimised, or simply behind something
  else - the cases where a notification belongs to the system rather
  than to the page. }
function WebUiIsShowing: boolean;
{ Показывает веб-окно и выводит его вперёд (клик по уведомлению на
  рабочем столе, desknotify.pas). }
procedure WebUiReveal;

{ Главное веб-окно или nil — владелец окон поверх него (мини-приложения,
  miniapp.pas), чтобы те держались над ним и не выходили на панель задач. }
function WebUiForm: TForm;

{ Сообщение главной странице (chrome.webview, событие message). От
  окошка звонка (callpopup.pas): что нажали на карточке. }
procedure WebUiPostJson(const AJson: utf8string);

{ Says that this window IS the application rather than a second view
  of it.

  It changes one thing, and that thing matters: a secondary window
  hides when closed (rebuilding the runtime for every open would throw
  the page state away), but the application's own window closing has
  to end the application. With no LCL main form there is nothing else
  left to end it. }
procedure SetWebUiPrimary(AOn: boolean);

implementation

uses
  { Only for the shutdown and for the one setting the tray honours.
    In the implementation section so the interface stays free of the
    account layer - this unit is a window, not a model. }
  tdcore,
  fpjson, jsonparser, callpopup;

var
  GForm: TFormWebUi = nil;
  GPrimary: boolean = False;

function WebUiIsShowing: boolean;
begin
  Result := (GForm <> nil) and GForm.IsShowing;
end;

function WebUiForm: TForm;
begin
  Result := GForm;
end;

procedure WebUiReveal;
begin
  if GForm <> nil then begin
    GForm.Reveal;
  end;
end;

procedure WebUiPostJson(const AJson: utf8string);
begin
  if (GForm <> nil) and (GForm.FView <> nil) then begin
    GForm.FView.PostJson(AJson);
  end;
end;

procedure SetWebUiPrimary(AOn: boolean);
begin
  GPrimary := AOn;
  if AOn and (GForm <> nil) then begin
    GForm.SetupTray;
  end;
end;

constructor TFormWebUi.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Caption := APP_TITLE;
  Width := 1200;
  Height := 800;
  Position := poScreenCenter;
  { На панели задач — всегда. Окно создаётся через CreateNew, а не
    Application.CreateForm, и главной формой приложения не становится;
    при MainFormOnTaskbar = True и stDefault LCL делает такое окно
    подчинённым скрытому AppHandle (TWin32WSCustomForm.CreateHandle,
    win32wsforms.pp), а подчинённые окна Windows на панель задач не
    выводит. stAlways оставляет его самостоятельным.
    ДО первого обращения к Handle: здесь свойство только запоминается
    и попадает в параметры создания окна, а поменянное потом оно
    перепрятывает окно, к которому уже привязан WebView2. }
  ShowInTaskBar := stAlways;
  { The runtime needs a window to attach to, and Handle is what creates
    one - reading it here rather than letting it happen later keeps the
    order explicit. }
  FView := TWebView2.Create(Handle);
  FView.OnExternalUri := @ViewExternalUri;
  FView.OnUnavailable := @ViewUnavailable;
  FView.OnAcceleratorKey := @ViewAcceleratorKey;
  FView.OnFullScreenElement := @ViewFullScreenElement;
  FView.OnWebMessage := @ViewMessage;
end;

{ Просьбы страницы к оболочке (chrome.webview.postMessage, JSON-строка).
  Пока одна: callpopup (show, url) — показать или спрятать окошко
  входящего звонка (callpopup.pas). Решает страница; оболочка только
  исполняет — на другой платформе это делает своя оболочка. }
procedure TFormWebUi.ViewMessage(Sender: TObject; const AText: UnicodeString);
var
  Data: TJSONData;
  O: TJSONObject;
begin
  try
    Data := GetJSON(UTF8Encode(AText));
  except
    Exit;
  end;
  try
    if not (Data is TJSONObject) then begin
      Exit;
    end;
    O := TJSONObject(Data);
    if O.Get('t', '') = 'callpopup' then begin
      if O.Get('show', False) then begin
        CallPopupShow(utf8string(O.Get('url', '')));
      end else begin
        CallPopupHide;
      end;
    end;
  finally
    Data.Free;
  end;
end;

destructor TFormWebUi.Destroy;
begin
  FreeAndNil(FView);
  if GForm = Self then begin
    GForm := nil;
  end;
  inherited Destroy;
end;

procedure TFormWebUi.Resize;
var
  R: TRect;
begin
  inherited Resize;
  if FView <> nil then begin
    { Client coordinates: the runtime places its child window inside the
      host, so this is not screen space. }
    R := Rect(0, 0, ClientWidth, ClientHeight);
    FView.SetBounds(R);
  end;
end;

procedure TFormWebUi.Open(const AUrl: utf8string);
begin
  FView.Navigate(AUrl);
  Show;
  BringToFront;
  { Keys only reach the runtime when the page has the focus, and F11 is
    a key. Harmless before the view exists - it is given focus again as
    soon as it does. }
  FView.Focus;
end;

{ F11, the way a browser means it.

  The key cannot be caught as an LCL key event: the focus belongs to the
  runtime's own child window, so the form never sees a WM_KEYDOWN. It
  arrives through AcceleratorKeyPressed instead - the runtime hands over
  anything that maps to no character, which F11 does not.

  Escape is deliberately NOT taken. It belongs to the page: the picture
  viewer closes on it, and a shell that swallowed it would break that.
  Browsers behave the same way - Escape leaves element fullscreen, not
  F11 fullscreen. }
procedure TFormWebUi.ViewAcceleratorKey(Sender: TObject; AVirtualKey: word;
  var AHandled: boolean);
begin
  if AVirtualKey <> VK_F11 then begin
    Exit;
  end;
  SetFullScreen(not FFullScreen);
  FByElement := False;
  AHandled := True;
end;

{ A video went fullscreen inside the page. The runtime has already
  stretched it to the view's bounds and stops there - the window is
  ours. Without this the "fullscreen" video is as big as the window and
  no bigger, which is exactly how it looked before. }
procedure TFormWebUi.ViewFullScreenElement(Sender: TObject; AActive: boolean);
begin
  if AActive then begin
    if not FFullScreen then begin
      FByElement := True;
      SetFullScreen(True);
    end;
  end else if FByElement then begin
    FByElement := False;
    SetFullScreen(False);
  end;
end;

{ Done by hand, with the window's own style, because neither LCL way
  works here:

  * WindowState := wsFullScreen is mapped to SW_SHOWMAXIMIZED on win32
    ("win32 has no fullscreen window state", win32wsforms.pp) - the
    caption and the taskbar would stay;
  * BorderStyle := bsNone is RecreateWnd, i.e. a NEW window handle, and
    the WebView2 controller is bound to the old one. The view would be
    left behind.

  Changing the style in place keeps the handle, so the runtime notices
  nothing; Resize then moves the view for us. The monitor's BoundsRect
  rather than WorkareaRect - the second one stops at the taskbar. }
procedure TFormWebUi.SetFullScreen(AOn: boolean);
var
  R: TRect;
begin
  if (AOn = FFullScreen) or not HandleAllocated then begin
    Exit;
  end;

  if AOn then begin
    FSavedStyle := Windows.GetWindowLongPtr(Handle, GWL_STYLE);
    FillChar(FSavedPlacement, SizeOf(FSavedPlacement), 0);
    FSavedPlacement.length := SizeOf(FSavedPlacement);
    Windows.GetWindowPlacement(Handle, @FSavedPlacement);

    R := Monitor.BoundsRect;
    Windows.SetWindowLongPtr(Handle, GWL_STYLE,
      FSavedStyle and not (WS_CAPTION or WS_THICKFRAME));
    Windows.SetWindowPos(Handle, 0, R.Left, R.Top,
      R.Right - R.Left, R.Bottom - R.Top,
      SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  end else begin
    Windows.SetWindowLongPtr(Handle, GWL_STYLE, FSavedStyle);
    Windows.SetWindowPlacement(Handle, @FSavedPlacement);
    { The frame has to be recalculated even though nothing moved, or the
      caption comes back only on the next resize. }
    Windows.SetWindowPos(Handle, 0, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE
      or SWP_FRAMECHANGED);
  end;

  FFullScreen := AOn;
end;

procedure TFormWebUi.ViewExternalUri(Sender: TObject; const AUri: utf8string);
begin
  { A link out of a message goes to the real browser, never inside this
    shell. The shell has no address bar, so a stranger's link opening
    here would be both confusing and a decent phishing surface. }
  OpenURL(AUri);
end;

procedure TFormWebUi.ViewUnavailable(Sender: TObject; const AMessage: string);
begin
  if FFailed then begin
    Exit;                  { one complaint per window, not one per retry }
  end;
  FFailed := True;
  { Two different pieces of advice, because there are two different
    situations. As a second view of a running application, the native
    window is right there and has a menu item for the browser. As the
    application itself, there is no menu to point at - only the file
    the server writes its address into. }
  if GPrimary then begin
    MessageDlg('Web interface',
      AMessage + LineEnding + LineEnding
      + 'The Microsoft Edge WebView2 Runtime is needed to show the '
      + 'interface in this window. Until it is installed, open the '
      + 'address in server_url.txt (beside the program) in any '
      + 'browser instead.',
      mtError, [mbOK], 0);
  end else begin
    MessageDlg('Web interface',
      AMessage + LineEnding + LineEnding
      + 'The Microsoft Edge WebView2 Runtime is needed to show the web '
      + 'interface in its own window. Without it, Tools - Open web '
      + 'interface in a browser still works.',
      mtError, [mbOK], 0);
  end;
  Close;
end;

{ Whether the window may actually close, and the place where the
  application is shut down properly.

  TDLib REQUIRES every client to be closed before the process exits,
  and that is asynchronous: BeginShutdown answers False and calls back
  once the clients confirm. The native main window has always done
  this (TFormMain.FormCloseQuery); when this window became the
  application, the step was missed - and an application that never
  closes its clients is one that has to be killed from Task Manager,
  which is exactly how it was reported. }
function TFormWebUi.CloseQuery: boolean;
begin
  Result := inherited CloseQuery;
  if (not Result) or (not GPrimary) then begin
    Exit;
  end;

  { The close button with close-to-tray on: out of sight, still
    running. Quit from the tray is what actually ends it. }
  { Спрашивается в момент закрытия, а не запоминается при старте:
    страница настроек меняет это значение на ходу. }
  if (not FQuitting) and (FTray <> nil) and TdCloseToTray then begin
    Result := False;
    Hide;
    Exit;
  end;

  if FTdClosed then begin
    Exit;
  end;

  { Hidden before TDLib has confirmed anything: closing the clients
    fires a burst of updates, and there is no reason to watch them go
    by. Same reasoning as the native window's. }
  Hide;
  FTdClosed := TdApp.BeginShutdown(@ShutdownDone);
  Result := FTdClosed;
  if not Result then begin
    { And a bound on the wait. Without one, a client that never
      confirms leaves the application unclosable - the very thing this
      is here to prevent. }
    if FGiveUp = nil then begin
      FGiveUp := TTimer.Create(Self);
      FGiveUp.Interval := 5000;
      FGiveUp.OnTimer := @GiveUpTick;
    end;
    FGiveUp.Enabled := True;
  end;
end;

procedure TFormWebUi.ShutdownDone(Sender: TObject);
begin
  if FGiveUp <> nil then begin
    FGiveUp.Enabled := False;
  end;
  FTdClosed := True;
  Close;
end;

procedure TFormWebUi.GiveUpTick(Sender: TObject);
begin
  FGiveUp.Enabled := False;
  FTdClosed := True;
  Close;
end;

procedure TFormWebUi.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  { Kept alive and hidden: rebuilding the runtime for every open would
    throw away the page state and cost a visible pause. }
  CloseAction := caHide;
  { Unless this window is the application - see SetWebUiPrimary. There
    is no main form to close in that case, so nothing else would ever
    end the message loop. Only reached once CloseQuery has agreed,
    which means TDLib is already closed. }
  if GPrimary then begin
    Application.Terminate;
  end;
end;

{ The tray icon, and the only way to quit when close-to-tray is on.

  Built in code rather than dropped on a form: this window has no
  .lfm - it is a CreateNew form wrapped around the WebView2 control. }
procedure TFormWebUi.SetupTray;
var
  Pop: TPopupMenu;
  Item: TMenuItem;
begin
  if FTray <> nil then begin
    Exit;
  end;

  Pop := TPopupMenu.Create(Self);

  Item := TMenuItem.Create(Pop);
  Item.Caption := 'Show window';
  Item.OnClick := @TrayShowClick;
  Item.Default := True;
  Pop.Items.Add(Item);

  Item := TMenuItem.Create(Pop);
  Item.Caption := '-';
  Pop.Items.Add(Item);

  Item := TMenuItem.Create(Pop);
  Item.Caption := 'Quit';
  Item.OnClick := @TrayQuitClick;
  Pop.Items.Add(Item);

  FTray := TTrayIcon.Create(Self);
  FTray.Hint := APP_TITLE;
  FTray.PopUpMenu := Pop;
  FTray.OnDblClick := @TrayDblClick;
  { The application's own icon, which the resource already carries -
    an empty one would leave a blank gap in the tray. }
  if not Application.Icon.Empty then begin
    FTray.Icon.Assign(Application.Icon);
  end;
  FTray.Visible := True;
end;

function TFormWebUi.IsShowing: boolean;
begin
  Result := Visible and (WindowState <> wsMinimized)
    and (GetForegroundWindow = Handle);
end;

procedure TFormWebUi.TrayShowClick(Sender: TObject);
begin
  Reveal;
end;

procedure TFormWebUi.TrayDblClick(Sender: TObject);
begin
  Reveal;
end;

procedure TFormWebUi.Reveal;
begin
  if not Visible then begin
    Show;
  end;
  if WindowState = wsMinimized then begin
    WindowState := wsNormal;
  end;
  BringToFront;
  Application.BringToFront;
end;

procedure TFormWebUi.TrayQuitClick(Sender: TObject);
begin
  { The one path that skips close-to-tray. }
  FQuitting := True;
  Close;
end;

function ShowWebUi(const AUrl: utf8string): boolean;
begin
  Result := WebView2Available;
  if not Result then begin
    Exit;
  end;
  if GForm = nil then begin
    GForm := TFormWebUi.CreateNew(Application);
  end;
  GForm.Open(AUrl);
end;

end.
