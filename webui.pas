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
  Windows, SysUtils, Classes, Forms, Controls, Dialogs, LCLIntf,
  webview2;

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
    procedure ViewExternalUri(Sender: TObject; const AUri: utf8string);
    procedure ViewUnavailable(Sender: TObject; const AMessage: string);
    procedure ViewAcceleratorKey(Sender: TObject; AVirtualKey: word;
      var AHandled: boolean);
    procedure ViewFullScreenElement(Sender: TObject; AActive: boolean);
  protected
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure Resize; override;
    procedure Open(const AUrl: utf8string);
    { F11, and the page's own fullscreen, both end up here. }
    procedure SetFullScreen(AOn: boolean);
    property FullScreen: boolean read FFullScreen;
  end;

{ Shows the web UI in its own window, creating it on first use. Returns
  False when there is no WebView2 runtime to host it - the caller then
  decides what to tell the user. }
function ShowWebUi(const AUrl: utf8string): boolean;

implementation

var
  GForm: TFormWebUi = nil;

constructor TFormWebUi.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  Caption := 'TG Orchestrator';
  Width := 1200;
  Height := 800;
  Position := poScreenCenter;
  { The runtime needs a window to attach to, and Handle is what creates
    one - reading it here rather than letting it happen later keeps the
    order explicit. }
  FView := TWebView2.Create(Handle);
  FView.OnExternalUri := @ViewExternalUri;
  FView.OnUnavailable := @ViewUnavailable;
  FView.OnAcceleratorKey := @ViewAcceleratorKey;
  FView.OnFullScreenElement := @ViewFullScreenElement;
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
  MessageDlg('Web interface',
    AMessage + LineEnding + LineEnding
    + 'The Microsoft Edge WebView2 Runtime is needed to show the web '
    + 'interface in its own window. Without it, Tools - Open web '
    + 'interface in a browser still works.',
    mtError, [mbOK], 0);
  Close;
end;

procedure TFormWebUi.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  { Kept alive and hidden: rebuilding the runtime for every open would
    throw away the page state and cost a visible pause. }
  CloseAction := caHide;
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
