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
    procedure ViewExternalUri(Sender: TObject; const AUri: utf8string);
    procedure ViewUnavailable(Sender: TObject; const AMessage: string);
  protected
    procedure DoClose(var CloseAction: TCloseAction); override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure Resize; override;
    procedure Open(const AUrl: utf8string);
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
