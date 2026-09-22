unit webview2;

{ Minimal binding to Microsoft Edge WebView2, written from scratch
  against the real WebView2.h (SDK 1.0.4191.47) rather than adapted
  from a large third-party wrapper - the same choice, and for the same
  reason, as ffdecode.pas: only what this project actually calls, so
  there is far less surface that can be silently wrong.

  THE ONE THING THAT MATTERS HERE: a COM interface is called BY VTABLE
  SLOT, not by name. The order the methods are declared in below IS the
  binary contract. It was taken from the header, because the online
  reference lists members ALPHABETICALLY - building from that would
  call the wrong function pointer, which is not a compile error but
  memory corruption at run time.

  Where only a prefix of an interface is needed, only that prefix is
  declared: slots after the last one used can be left out safely, but
  not one of the ones before it. Methods that are only here to hold a
  slot are marked so and take generic pointers - they are never called,
  so their real parameters do not matter.

  Requires WebView2Loader.dll (x64) beside the exe and the WebView2
  Runtime installed - Windows 11 has it, as does any Windows 10 with
  Edge. Missing runtime is reported, not crashed on: see TWebView2's
  OnUnavailable.

  WebView2Loader.dll is redistributable under the SDK licence (a
  BSD-3-clause style permission); its notice travels with it in
  WebView2Loader.LICENSE.txt beside the exe. }

{$mode objfpc}{$H+}
{$interfaces com}

interface

uses
  Windows, ActiveX, SysUtils, Classes;

type
  { The header's EventRegistrationToken is a struct wrapping one int64;
    the value is only ever handed back to remove_*, which this binding
    does not call, so it is kept as the plain integer it is. }
  TEventToken = Int64;

  ICoreWebView2 = interface;
  ICoreWebView2Settings = interface;
  ICoreWebView2Controller = interface;
  ICoreWebView2Environment = interface;

  { --- ICoreWebView2Settings: slots 0..11, need 9 and 11 --- }
  ICoreWebView2Settings = interface(IUnknown)
    ['{E562E4F0-D7FA-43AC-8D71-C05150499F00}']
    function get_IsScriptEnabled(v: Pointer): HRESULT; stdcall;               { 0  slot only }
    function put_IsScriptEnabled(v: BOOL): HRESULT; stdcall;                  { 1  slot only }
    function get_IsWebMessageEnabled(v: Pointer): HRESULT; stdcall;           { 2  slot only }
    function put_IsWebMessageEnabled(v: BOOL): HRESULT; stdcall;              { 3  slot only }
    function get_AreDefaultScriptDialogsEnabled(v: Pointer): HRESULT; stdcall;{ 4  slot only }
    function put_AreDefaultScriptDialogsEnabled(v: BOOL): HRESULT; stdcall;   { 5  slot only }
    function get_IsStatusBarEnabled(v: Pointer): HRESULT; stdcall;            { 6  slot only }
    function put_IsStatusBarEnabled(v: BOOL): HRESULT; stdcall;               { 7 }
    function get_AreDevToolsEnabled(v: Pointer): HRESULT; stdcall;            { 8  slot only }
    function put_AreDevToolsEnabled(v: BOOL): HRESULT; stdcall;               { 9 }
    function get_AreDefaultContextMenusEnabled(v: Pointer): HRESULT; stdcall; { 10 slot only }
    function put_AreDefaultContextMenusEnabled(v: BOOL): HRESULT; stdcall;    { 11 }
  end;

  { --- ICoreWebView2NewWindowRequestedEventArgs: slots 0..3 --- }
  ICoreWebView2NewWindowRequestedEventArgs = interface(IUnknown)
    ['{34ACB11C-FC37-4418-9132-F9C21D1EAFB9}']
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;                   { 0 }
    function put_NewWindow(w: Pointer): HRESULT; stdcall;                     { 1 slot only }
    function get_NewWindow(w: Pointer): HRESULT; stdcall;                     { 2 slot only }
    function put_Handled(handled: BOOL): HRESULT; stdcall;                    { 3 }
  end;

  ICoreWebView2NewWindowRequestedEventHandler = interface(IUnknown)
    ['{D4C185FE-C81C-4989-97AF-2D3FA7AB5651}']
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
  end;

  { --- ICoreWebView2: slots 0..41, need 0, 2 and 41 --- }
  ICoreWebView2 = interface(IUnknown)
    ['{76ECEACB-0462-4D94-AC83-423A6793775E}']
    function get_Settings(out settings: ICoreWebView2Settings): HRESULT; stdcall; { 0 }
    function get_Source(v: Pointer): HRESULT; stdcall;                        { 1  slot only }
    function Navigate(uri: PWideChar): HRESULT; stdcall;                      { 2 }
    function NavigateToString(p: Pointer): HRESULT; stdcall;                  { 3  slot only }
    function add_NavigationStarting(a, b: Pointer): HRESULT; stdcall;         { 4  slot only }
    function remove_NavigationStarting(a: Pointer): HRESULT; stdcall;         { 5  slot only }
    function add_ContentLoading(a, b: Pointer): HRESULT; stdcall;             { 6  slot only }
    function remove_ContentLoading(a: Pointer): HRESULT; stdcall;             { 7  slot only }
    function add_SourceChanged(a, b: Pointer): HRESULT; stdcall;              { 8  slot only }
    function remove_SourceChanged(a: Pointer): HRESULT; stdcall;              { 9  slot only }
    function add_HistoryChanged(a, b: Pointer): HRESULT; stdcall;             { 10 slot only }
    function remove_HistoryChanged(a: Pointer): HRESULT; stdcall;             { 11 slot only }
    function add_NavigationCompleted(a, b: Pointer): HRESULT; stdcall;        { 12 slot only }
    function remove_NavigationCompleted(a: Pointer): HRESULT; stdcall;        { 13 slot only }
    function add_FrameNavigationStarting(a, b: Pointer): HRESULT; stdcall;    { 14 slot only }
    function remove_FrameNavigationStarting(a: Pointer): HRESULT; stdcall;    { 15 slot only }
    function add_FrameNavigationCompleted(a, b: Pointer): HRESULT; stdcall;   { 16 slot only }
    function remove_FrameNavigationCompleted(a: Pointer): HRESULT; stdcall;   { 17 slot only }
    function add_ScriptDialogOpening(a, b: Pointer): HRESULT; stdcall;        { 18 slot only }
    function remove_ScriptDialogOpening(a: Pointer): HRESULT; stdcall;        { 19 slot only }
    function add_PermissionRequested(a, b: Pointer): HRESULT; stdcall;        { 20 slot only }
    function remove_PermissionRequested(a: Pointer): HRESULT; stdcall;        { 21 slot only }
    function add_ProcessFailed(a, b: Pointer): HRESULT; stdcall;              { 22 slot only }
    function remove_ProcessFailed(a: Pointer): HRESULT; stdcall;              { 23 slot only }
    function AddScriptToExecuteOnDocumentCreated(a, b: Pointer): HRESULT; stdcall;    { 24 }
    function RemoveScriptToExecuteOnDocumentCreated(a: Pointer): HRESULT; stdcall;    { 25 }
    function ExecuteScript(a, b: Pointer): HRESULT; stdcall;                  { 26 slot only }
    function CapturePreview(a, b, c: Pointer): HRESULT; stdcall;              { 27 slot only }
    function Reload: HRESULT; stdcall;                                        { 28 }
    function PostWebMessageAsJson(a: Pointer): HRESULT; stdcall;              { 29 slot only }
    function PostWebMessageAsString(a: Pointer): HRESULT; stdcall;            { 30 slot only }
    function add_WebMessageReceived(a, b: Pointer): HRESULT; stdcall;         { 31 slot only }
    function remove_WebMessageReceived(a: Pointer): HRESULT; stdcall;         { 32 slot only }
    function CallDevToolsProtocolMethod(a, b, c: Pointer): HRESULT; stdcall;  { 33 slot only }
    function get_BrowserProcessId(a: Pointer): HRESULT; stdcall;              { 34 slot only }
    function get_CanGoBack(a: Pointer): HRESULT; stdcall;                     { 35 slot only }
    function get_CanGoForward(a: Pointer): HRESULT; stdcall;                  { 36 slot only }
    function GoBack: HRESULT; stdcall;                                        { 37 slot only }
    function GoForward: HRESULT; stdcall;                                     { 38 slot only }
    function GetDevToolsProtocolEventReceiver(a, b: Pointer): HRESULT; stdcall; { 39 slot only }
    function Stop: HRESULT; stdcall;                                          { 40 slot only }
    function add_NewWindowRequested(
      handler: ICoreWebView2NewWindowRequestedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                              { 41 }
  end;

  { --- ICoreWebView2Controller: slots 0..22, need 1, 3, 21 and 22 --- }
  ICoreWebView2Controller = interface(IUnknown)
    ['{4D00C0D1-9434-4EB6-8078-8697A560334F}']
    function get_IsVisible(v: Pointer): HRESULT; stdcall;                     { 0  slot only }
    function put_IsVisible(v: BOOL): HRESULT; stdcall;                        { 1 }
    function get_Bounds(v: Pointer): HRESULT; stdcall;                        { 2  slot only }
    { RECT goes by value in the header. On the Windows x64 ABI a 16-byte
      record is passed by hidden reference, which FPC does for us - the
      declaration just has to say "by value", as it does. }
    function put_Bounds(bounds: TRect): HRESULT; stdcall;                     { 3 }
    function get_ZoomFactor(v: Pointer): HRESULT; stdcall;                    { 4  slot only }
    function put_ZoomFactor(v: Double): HRESULT; stdcall;                     { 5  slot only }
    function add_ZoomFactorChanged(a, b: Pointer): HRESULT; stdcall;          { 6  slot only }
    function remove_ZoomFactorChanged(a: Pointer): HRESULT; stdcall;          { 7  slot only }
    function SetBoundsAndZoomFactor(a: TRect; b: Double): HRESULT; stdcall;   { 8  slot only }
    function MoveFocus(a: Integer): HRESULT; stdcall;                         { 9  slot only }
    function add_MoveFocusRequested(a, b: Pointer): HRESULT; stdcall;         { 10 slot only }
    function remove_MoveFocusRequested(a: Pointer): HRESULT; stdcall;         { 11 slot only }
    function add_GotFocus(a, b: Pointer): HRESULT; stdcall;                   { 12 slot only }
    function remove_GotFocus(a: Pointer): HRESULT; stdcall;                   { 13 slot only }
    function add_LostFocus(a, b: Pointer): HRESULT; stdcall;                  { 14 slot only }
    function remove_LostFocus(a: Pointer): HRESULT; stdcall;                  { 15 slot only }
    function add_AcceleratorKeyPressed(a, b: Pointer): HRESULT; stdcall;      { 16 slot only }
    function remove_AcceleratorKeyPressed(a: Pointer): HRESULT; stdcall;      { 17 slot only }
    function get_ParentWindow(a: Pointer): HRESULT; stdcall;                  { 18 slot only }
    function put_ParentWindow(a: HWND): HRESULT; stdcall;                     { 19 slot only }
    function NotifyParentWindowPositionChanged: HRESULT; stdcall;             { 20 }
    function Close: HRESULT; stdcall;                                         { 21 }
    function get_CoreWebView2(out wv: ICoreWebView2): HRESULT; stdcall;       { 22 }
  end;

  { --- ICoreWebView2Environment: only slot 0 is used --- }
  ICoreWebView2ControllerCompletedHandler = interface;

  ICoreWebView2Environment = interface(IUnknown)
    ['{B96D755E-0319-4E92-A296-23436F46A1FC}']
    function CreateCoreWebView2Controller(parentWindow: HWND;
      handler: ICoreWebView2ControllerCompletedHandler): HRESULT; stdcall;    { 0 }
  end;

  { The two completion callbacks. Named short here; the header calls
    them ICoreWebView2CreateCoreWebView2Environment- and
    ControllerCompletedHandler. One method each. }
  ICoreWebView2EnvironmentCompletedHandler = interface(IUnknown)
    ['{4E8A3389-C9D8-4BD2-B6B5-124FEE6CC14D}']
    function Invoke(errorCode: HRESULT;
      createdEnvironment: ICoreWebView2Environment): HRESULT; stdcall;
  end;

  ICoreWebView2ControllerCompletedHandler = interface(IUnknown)
    ['{6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}']
    function Invoke(errorCode: HRESULT;
      createdController: ICoreWebView2Controller): HRESULT; stdcall;
  end;

type
  TWebView2NavigateEvent = procedure(Sender: TObject; const AUri: utf8string) of object;
  TWebView2ErrorEvent = procedure(Sender: TObject; const AMessage: string) of object;

  { Hosts one WebView2 inside an existing window handle.

    Creation is ASYNCHRONOUS in two steps (environment, then
    controller), which is why nothing can be navigated straight after
    Create: the URL is remembered and applied when the controller
    arrives. Both callbacks land on the thread that pumps messages,
    i.e. the main thread, so no marshalling is needed. }
  TWebView2 = class
  private
    FHost: HWND;
    FController: ICoreWebView2Controller;
    FWebView: ICoreWebView2;
    FPendingUrl: UnicodeString;
    FReady: boolean;
    FOnExternalUri: TWebView2NavigateEvent;
    FOnUnavailable: TWebView2ErrorEvent;
    procedure EnvironmentReady(AResult: HRESULT; AEnv: ICoreWebView2Environment);
    procedure ControllerReady(AResult: HRESULT; ACtrl: ICoreWebView2Controller);
    function ExternalUriRequested(const AUri: UnicodeString): boolean;
    procedure ReportUnavailable(const AMessage: string);
  public
    constructor Create(AHost: HWND);
    destructor Destroy; override;
    { Available only after the runtime has been found and the control
      built; before that Navigate just remembers where to go. }
    property Ready: boolean read FReady;
    procedure Navigate(const AUrl: utf8string);
    procedure SetBounds(const ARect: TRect);
    { A link the page asked to open in a new window. Not handled here:
      the host decides, and in this app it hands it to the system
      browser - a stranger's link must never open inside a shell with
      no address bar. }
    property OnExternalUri: TWebView2NavigateEvent read FOnExternalUri write FOnExternalUri;
    { The runtime is missing or refused to start. Reported rather than
      left as an empty window. }
    property OnUnavailable: TWebView2ErrorEvent read FOnUnavailable write FOnUnavailable;
  end;

{ True when a WebView2 runtime is installed. Checked before building a
  window around something that cannot exist. }
function WebView2Available: boolean;

implementation

const
  WEBVIEW2_LOADER = 'WebView2Loader.dll';

function CreateCoreWebView2EnvironmentWithOptions(
  browserExecutableFolder, userDataFolder: PWideChar;
  environmentOptions: Pointer;
  environmentCreatedHandler: ICoreWebView2EnvironmentCompletedHandler): HRESULT;
  stdcall; external WEBVIEW2_LOADER;

{ The loader also exports a version probe, which is how availability is
  answered without starting anything. }
function GetAvailableCoreWebView2BrowserVersionString(
  browserExecutableFolder: PWideChar; out versionInfo: PWideChar): HRESULT;
  stdcall; external WEBVIEW2_LOADER;

function WebView2Available: boolean;
var
  Ver: PWideChar;
begin
  Ver := nil;
  Result := False;
  try
    if Succeeded(GetAvailableCoreWebView2BrowserVersionString(nil, Ver))
       and (Ver <> nil) then begin
      Result := True;
      CoTaskMemFree(Ver);
    end;
  except
    { The loader DLL itself is missing - the exception is the answer. }
    Result := False;
  end;
end;

type
  { Thin adapters: COM hands the callback back through an interface, and
    these turn that into a method call on the owning TWebView2. }
  TEnvHandler = class(TInterfacedObject, ICoreWebView2EnvironmentCompletedHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(errorCode: HRESULT;
      createdEnvironment: ICoreWebView2Environment): HRESULT; stdcall;
  end;

  TCtrlHandler = class(TInterfacedObject, ICoreWebView2ControllerCompletedHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(errorCode: HRESULT;
      createdController: ICoreWebView2Controller): HRESULT; stdcall;
  end;

  TNewWindowHandler = class(TInterfacedObject,
    ICoreWebView2NewWindowRequestedEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
  end;

constructor TEnvHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TEnvHandler.Invoke(errorCode: HRESULT;
  createdEnvironment: ICoreWebView2Environment): HRESULT; stdcall;
begin
  if FOwner <> nil then begin
    FOwner.EnvironmentReady(errorCode, createdEnvironment);
  end;
  Result := S_OK;
end;

constructor TCtrlHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TCtrlHandler.Invoke(errorCode: HRESULT;
  createdController: ICoreWebView2Controller): HRESULT; stdcall;
begin
  if FOwner <> nil then begin
    FOwner.ControllerReady(errorCode, createdController);
  end;
  Result := S_OK;
end;

constructor TNewWindowHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TNewWindowHandler.Invoke(sender: ICoreWebView2;
  args: ICoreWebView2NewWindowRequestedEventArgs): HRESULT; stdcall;
var
  Uri: PWideChar;
  S: UnicodeString;
begin
  Result := S_OK;
  if (FOwner = nil) or (args = nil) then begin
    Exit;
  end;
  Uri := nil;
  S := '';
  if Succeeded(args.get_Uri(Uri)) and (Uri <> nil) then begin
    S := UnicodeString(Uri);
    { get_Uri hands over a string allocated by the runtime; freeing it
      is the caller's job. }
    CoTaskMemFree(Uri);
  end;
  { Told the runtime we dealt with it, so it does not open a window of
    its own on top of ours. }
  if FOwner.ExternalUriRequested(S) then begin
    args.put_Handled(True);
  end;
end;

{ ------------------------------------------------------------------ }

constructor TWebView2.Create(AHost: HWND);
var
  Handler: ICoreWebView2EnvironmentCompletedHandler;
  DataDir: UnicodeString;
  Hr: HRESULT;
begin
  inherited Create;
  FHost := AHost;
  FReady := False;

  { WebView2 needs COM initialised on the calling thread. The LCL does
    not promise to have done it, and the standalone test only worked
    because it did so itself. The result is deliberately ignored:
    S_FALSE means it was already initialised here, RPC_E_CHANGED_MODE
    means the thread is already MTA - both are fine to build on, and
    neither is ours to undo, so there is no matching CoUninitialize. }
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);

  { Its own profile folder beside the app's other data rather than
    somewhere under the user's Edge profile: this is a separate browser
    instance and should not inherit or disturb anything. }
  DataDir := UnicodeString(GetEnvironmentVariable('LOCALAPPDATA'))
    + '\tgorchestrator\webview2';

  Handler := TEnvHandler.Create(Self);
  try
    Hr := CreateCoreWebView2EnvironmentWithOptions(nil, PWideChar(DataDir),
      nil, Handler);
  except
    on E: Exception do begin
      ReportUnavailable('WebView2Loader.dll could not be loaded: ' + E.Message);
      Exit;
    end;
  end;
  if Failed(Hr) then begin
    ReportUnavailable(Format('WebView2 environment could not be created (0x%.8x)', [Hr]));
  end;
end;

destructor TWebView2.Destroy;
begin
  if FController <> nil then begin
    FController.Close;
    FController := nil;
  end;
  FWebView := nil;
  inherited Destroy;
end;

procedure TWebView2.ReportUnavailable(const AMessage: string);
begin
  if Assigned(FOnUnavailable) then begin
    FOnUnavailable(Self, AMessage);
  end;
end;

procedure TWebView2.EnvironmentReady(AResult: HRESULT;
  AEnv: ICoreWebView2Environment);
var
  Hr: HRESULT;
begin
  if Failed(AResult) or (AEnv = nil) then begin
    ReportUnavailable(Format('WebView2 runtime is not available (0x%.8x)', [AResult]));
    Exit;
  end;
  Hr := AEnv.CreateCoreWebView2Controller(FHost, TCtrlHandler.Create(Self));
  if Failed(Hr) then begin
    ReportUnavailable(Format('WebView2 controller could not be created (0x%.8x)', [Hr]));
  end;
end;

procedure TWebView2.ControllerReady(AResult: HRESULT;
  ACtrl: ICoreWebView2Controller);
var
  Settings: ICoreWebView2Settings;
  Token: TEventToken;
  R: TRect;
begin
  if Failed(AResult) or (ACtrl = nil) then begin
    ReportUnavailable(Format('WebView2 controller could not be created (0x%.8x)', [AResult]));
    Exit;
  end;

  FController := ACtrl;
  if Failed(FController.get_CoreWebView2(FWebView)) or (FWebView = nil) then begin
    ReportUnavailable('WebView2 was created but could not be obtained');
    Exit;
  end;

  if Succeeded(FWebView.get_Settings(Settings)) and (Settings <> nil) then begin
    { Kept ON deliberately while the native window is still the
      reference implementation: verifying the web UI depends on them. }
    Settings.put_AreDevToolsEnabled(True);
    Settings.put_AreDefaultContextMenusEnabled(True);
  end;

  FWebView.add_NewWindowRequested(TNewWindowHandler.Create(Self), Token);

  Windows.GetClientRect(FHost, @R);
  FController.put_Bounds(R);
  FController.put_IsVisible(True);

  FReady := True;
  if FPendingUrl <> '' then begin
    FWebView.Navigate(PWideChar(FPendingUrl));
    FPendingUrl := '';
  end;
end;

function TWebView2.ExternalUriRequested(const AUri: UnicodeString): boolean;
begin
  Result := False;
  if (AUri <> '') and Assigned(FOnExternalUri) then begin
    FOnExternalUri(Self, utf8string(AUri));
    Result := True;
  end;
end;

procedure TWebView2.Navigate(const AUrl: utf8string);
begin
  if FReady and (FWebView <> nil) then begin
    FWebView.Navigate(PWideChar(UnicodeString(AUrl)));
  end else begin
    { Creation is asynchronous, so this is the normal path on startup,
      not an error. }
    FPendingUrl := UnicodeString(AUrl);
  end;
end;

procedure TWebView2.SetBounds(const ARect: TRect);
begin
  if FController <> nil then begin
    FController.put_Bounds(ARect);
  end;
end;

end.
