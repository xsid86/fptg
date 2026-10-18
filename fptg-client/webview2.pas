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
  Windows, ActiveX, SysUtils, Classes, CommDlg;

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

  { --- ICoreWebView2WebMessageReceivedEventArgs: slots 0..2 ---
    For mini apps (miniapp.pas): the page sends chrome.webview.postMessage,
    the host reads a string. Order and GUID — from
    WebView2.h SDK 1.0.4191.47 (0f99a40c-...). }
  ICoreWebView2WebMessageReceivedEventArgs = interface(IUnknown)
    ['{0F99A40C-E962-4207-9E92-E3D542EFF849}']
    function get_Source(out value: PWideChar): HRESULT; stdcall;               { 0 }
    function get_WebMessageAsJson(out value: PWideChar): HRESULT; stdcall;     { 1 }
    function TryGetWebMessageAsString(out value: PWideChar): HRESULT; stdcall; { 2 }
  end;

  { --- ICoreWebView2PermissionRequestedEventArgs: slots 0..5 ---
    Order and GUID — WebView2.h SDK 1.0.4191.47 (973ae2ef-...). Without a
    PermissionRequested handler the page's geolocation got a refusal. }
  ICoreWebView2PermissionRequestedEventArgs = interface(IUnknown)
    ['{973AE2EF-FF18-4894-8FB2-3C758F046810}']
    function get_Uri(out value: PWideChar): HRESULT; stdcall;                  { 0 }
    function get_PermissionKind(out value: integer): HRESULT; stdcall;        { 1 }
    function get_IsUserInitiated(out value: BOOL): HRESULT; stdcall;          { 2 }
    function get_State(out value: integer): HRESULT; stdcall;                 { 3 }
    function put_State(value: integer): HRESULT; stdcall;                     { 4 }
    function GetDeferral(out deferral: IUnknown): HRESULT; stdcall;           { 5 }
  end;

  ICoreWebView2PermissionRequestedEventHandler = interface(IUnknown)
    ['{15E1C6A3-C72A-4DF3-91D7-D097FBEC6BFD}']
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2PermissionRequestedEventArgs): HRESULT; stdcall;
  end;

  ICoreWebView2WebMessageReceivedEventHandler = interface(IUnknown)
    ['{57213F19-00E6-49FA-8E07-898EA01ECBD2}']
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2WebMessageReceivedEventArgs): HRESULT; stdcall;
  end;

  { AddScriptToExecuteOnDocumentCreated answers asynchronously; navigation
    waits for that answer, otherwise the first document could open without
    the script. GUID b99369f3-... from the same header. }
  ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = interface(IUnknown)
    ['{B99369F3-9B11-47B5-BC6F-8E7895FCEA17}']
    function Invoke(errorCode: HRESULT; AId: PWideChar): HRESULT; stdcall;
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

  { --- ICoreWebView2AcceleratorKeyPressedEventArgs: slots 0..5 --- }
  ICoreWebView2AcceleratorKeyPressedEventArgs = interface(IUnknown)
    ['{9F760F8A-FB79-42BE-9990-7B56900FA9C7}']
    function get_KeyEventKind(out kind: DWORD): HRESULT; stdcall;             { 0 }
    function get_VirtualKey(out key: DWORD): HRESULT; stdcall;                { 1 }
    function get_KeyEventLParam(a: Pointer): HRESULT; stdcall;                { 2  slot only }
    function get_PhysicalKeyStatus(a: Pointer): HRESULT; stdcall;             { 3  slot only }
    function get_Handled(a: Pointer): HRESULT; stdcall;                       { 4  slot only }
    function put_Handled(handled: BOOL): HRESULT; stdcall;                    { 5 }
  end;

  { Keys the page does not get to see first. The runtime calls this for
    anything it considers an accelerator - Ctrl or Alt held, or a key
    that maps to no character, which is what F11 is. Without it the key
    never reaches this side at all: the focus belongs to the runtime's
    own child window, so the LCL form's OnKeyDown never fires. }
  ICoreWebView2AcceleratorKeyPressedEventHandler = interface(IUnknown)
    ['{B29C7E28-FA79-41A8-8E44-65811C76DCB2}']
    function Invoke(sender: ICoreWebView2Controller;
      args: ICoreWebView2AcceleratorKeyPressedEventArgs): HRESULT; stdcall;
  end;

  { The page put an element into fullscreen (a video's own button, or
    requestFullscreen from script). The runtime grows that element to
    the WebView's bounds and no further - the window is the host's to
    deal with, which is the whole point of the event. It carries no
    arguments; the state is read back with
    get_ContainsFullScreenElement. }
  ICoreWebView2ContainsFullScreenElementChangedEventHandler = interface(IUnknown)
    ['{E45D98B1-AFEF-45BE-8BAF-6C7728867F73}']
    function Invoke(sender: ICoreWebView2; args: IUnknown): HRESULT; stdcall;
  end;

  { --- ICoreWebView2: slots 0..57, need 0, 2, 41, 49 and 51. All 58 are
    required: ICoreWebView2_3/_14 stand on this interface, and a missing
    tail shifted their methods (a live case on 2026-10-07:
    SetVirtualHostNameToFolderMapping landed in remove_DOMContentLoaded and
    honestly answered S_OK). --- }
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
    function add_PermissionRequested(
      handler: ICoreWebView2PermissionRequestedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                              { 20 }
    function remove_PermissionRequested(a: Pointer): HRESULT; stdcall;        { 21 slot only }
    function add_ProcessFailed(a, b: Pointer): HRESULT; stdcall;              { 22 slot only }
    function remove_ProcessFailed(a: Pointer): HRESULT; stdcall;              { 23 slot only }
    function AddScriptToExecuteOnDocumentCreated(javaScript: PWideChar;
      handler: ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler): HRESULT; stdcall; { 24 }
    function RemoveScriptToExecuteOnDocumentCreated(a: Pointer): HRESULT; stdcall;    { 25 }
    function ExecuteScript(a, b: Pointer): HRESULT; stdcall;                  { 26 slot only }
    function CapturePreview(a, b, c: Pointer): HRESULT; stdcall;              { 27 slot only }
    function Reload: HRESULT; stdcall;                                        { 28 }
    function PostWebMessageAsJson(webMessageAsJson: PWideChar): HRESULT; stdcall; { 29 }
    function PostWebMessageAsString(a: Pointer): HRESULT; stdcall;            { 30 slot only }
    function add_WebMessageReceived(
      handler: ICoreWebView2WebMessageReceivedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                              { 31 }
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
    function remove_NewWindowRequested(a: Pointer): HRESULT; stdcall;         { 42 slot only }
    function add_DocumentTitleChanged(a, b: Pointer): HRESULT; stdcall;       { 43 slot only }
    function remove_DocumentTitleChanged(a: Pointer): HRESULT; stdcall;       { 44 slot only }
    function get_DocumentTitle(a: Pointer): HRESULT; stdcall;                 { 45 slot only }
    function AddHostObjectToScript(a, b: Pointer): HRESULT; stdcall;          { 46 slot only }
    function RemoveHostObjectFromScript(a: Pointer): HRESULT; stdcall;        { 47 slot only }
    function OpenDevToolsWindow: HRESULT; stdcall;                            { 48 slot only }
    function add_ContainsFullScreenElementChanged(
      handler: ICoreWebView2ContainsFullScreenElementChangedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                              { 49 }
    function remove_ContainsFullScreenElementChanged(a: Pointer): HRESULT; stdcall; { 50 slot only }
    function get_ContainsFullScreenElement(out value: BOOL): HRESULT; stdcall;      { 51 }
    function add_WebResourceRequested(a, b: Pointer): HRESULT; stdcall;       { 52 slot only }
    function remove_WebResourceRequested(a: Pointer): HRESULT; stdcall;       { 53 slot only }
    function AddWebResourceRequestedFilter(a: Pointer; b: integer): HRESULT; stdcall; { 54 slot only }
    function RemoveWebResourceRequestedFilter(a: Pointer; b: integer): HRESULT; stdcall; { 55 slot only }
    function add_WindowCloseRequested(a, b: Pointer): HRESULT; stdcall;       { 56 slot only }
    function remove_WindowCloseRequested(a: Pointer): HRESULT; stdcall;       { 57 slot only }
  end;

  { --- ICoreWebView2Controller: slots 0..22, need 1, 3, 9, 16, 21 and 22 --- }
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
    function MoveFocus(reason: Integer): HRESULT; stdcall;                    { 9 }
    function add_MoveFocusRequested(a, b: Pointer): HRESULT; stdcall;         { 10 slot only }
    function remove_MoveFocusRequested(a: Pointer): HRESULT; stdcall;         { 11 slot only }
    function add_GotFocus(a, b: Pointer): HRESULT; stdcall;                   { 12 slot only }
    function remove_GotFocus(a: Pointer): HRESULT; stdcall;                   { 13 slot only }
    function add_LostFocus(a, b: Pointer): HRESULT; stdcall;                  { 14 slot only }
    function remove_LostFocus(a: Pointer): HRESULT; stdcall;                  { 15 slot only }
    function add_AcceleratorKeyPressed(
      handler: ICoreWebView2AcceleratorKeyPressedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                              { 16 }
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

  { --- ICoreWebView2_3: a folder as a virtual site. Slots 58..64 —
    ICoreWebView2_2 (7 methods), then _3. Order and GUID — WebView2.h
    SDK 1.0.4191.47. --- }
  ICoreWebView2_3 = interface(ICoreWebView2)
    ['{A0D6DF20-3B92-416D-AA0C-437A9C727857}']
    function add_WebResourceResponseReceived(a, b: Pointer): HRESULT; stdcall;  { 58 slot only }
    function remove_WebResourceResponseReceived(a: Pointer): HRESULT; stdcall;  { 59 slot only }
    function NavigateWithWebResourceRequest(a: Pointer): HRESULT; stdcall;      { 60 slot only }
    function add_DOMContentLoaded(a, b: Pointer): HRESULT; stdcall;             { 61 slot only }
    function remove_DOMContentLoaded(a: Pointer): HRESULT; stdcall;             { 62 slot only }
    function get_CookieManager(a: Pointer): HRESULT; stdcall;                   { 63 slot only }
    function get_Environment(a: Pointer): HRESULT; stdcall;                     { 64 slot only }
    function TrySuspend(a: Pointer): HRESULT; stdcall;                          { 65 slot only }
    function Resume: HRESULT; stdcall;                                          { 66 slot only }
    function get_IsSuspended(a: Pointer): HRESULT; stdcall;                     { 67 slot only }
    function SetVirtualHostNameToFolderMapping(hostName, folderPath: PWideChar;
      accessKind: integer): HRESULT; stdcall;                                   { 68 }
    function ClearVirtualHostNameToFolderMapping(hostName: PWideChar): HRESULT; stdcall; { 69 slot only }
  end;

  { --- The server certificate error (ICoreWebView2_14). --- }
  ICoreWebView2Certificate = interface(IUnknown)
    ['{C5FB2FCE-1CAC-4AEE-9C79-5ED0362EAAE0}']
    function get_Subject(a: Pointer): HRESULT; stdcall;                         { 0 slot only }
    function get_Issuer(a: Pointer): HRESULT; stdcall;                          { 1 slot only }
    function get_ValidFrom(a: Pointer): HRESULT; stdcall;                       { 2 slot only }
    function get_ValidTo(a: Pointer): HRESULT; stdcall;                         { 3 slot only }
    function get_DerEncodedSerialNumber(a: Pointer): HRESULT; stdcall;          { 4 slot only }
    function get_DisplayName(a: Pointer): HRESULT; stdcall;                     { 5 slot only }
    function ToPemEncoding(out pem: PWideChar): HRESULT; stdcall;               { 6 }
    function get_PemEncodedIssuerCertificateChain(a: Pointer): HRESULT; stdcall; { 7 slot only }
  end;

  ICoreWebView2ServerCertificateErrorDetectedEventArgs = interface(IUnknown)
    ['{012193ED-7C13-48FF-969D-A84C1F432A14}']
    function get_ErrorStatus(out value: integer): HRESULT; stdcall;            { 0 }
    function get_RequestUri(out value: PWideChar): HRESULT; stdcall;           { 1 }
    function get_ServerCertificate(out value: ICoreWebView2Certificate): HRESULT; stdcall; { 2 }
    function get_Action(out value: integer): HRESULT; stdcall;                 { 3 }
    function put_Action(value: integer): HRESULT; stdcall;                     { 4 }
    function GetDeferral(a: Pointer): HRESULT; stdcall;                        { 5 slot only }
  end;

  ICoreWebView2ServerCertificateErrorDetectedEventHandler = interface(IUnknown)
    ['{969B3A26-D85E-4795-8199-FEF57344DA22}']
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2ServerCertificateErrorDetectedEventArgs): HRESULT; stdcall;
  end;

  { Slots 58..102 — ICoreWebView2_2.._13 (per WebView2.h: 7, 5, 4, 2, 1, 1,
    7, 9, 2, 3, 3, 1 methods), then _14. Only 103 is needed. }
  ICoreWebView2_14 = interface(ICoreWebView2)
    ['{6DAA4F10-4A90-4753-8898-77C5DF534165}']
    function Slot58: HRESULT; stdcall;  { 58  _2, slot only }
    function Slot59: HRESULT; stdcall;  { 59  _2, slot only }
    function Slot60: HRESULT; stdcall;  { 60  _2, slot only }
    function Slot61: HRESULT; stdcall;  { 61  _2, slot only }
    function Slot62: HRESULT; stdcall;  { 62  _2, slot only }
    function Slot63: HRESULT; stdcall;  { 63  _2, slot only }
    function Slot64: HRESULT; stdcall;  { 64  _2, slot only }
    function Slot65: HRESULT; stdcall;  { 65  _3, slot only }
    function Slot66: HRESULT; stdcall;  { 66  _3, slot only }
    function Slot67: HRESULT; stdcall;  { 67  _3, slot only }
    function Slot68: HRESULT; stdcall;  { 68  _3, slot only }
    function Slot69: HRESULT; stdcall;  { 69  _3, slot only }
    function Slot70: HRESULT; stdcall;  { 70  _4, slot only }
    function Slot71: HRESULT; stdcall;  { 71  _4, slot only }
    function Slot72: HRESULT; stdcall;  { 72  _4, slot only }
    function Slot73: HRESULT; stdcall;  { 73  _4, slot only }
    function Slot74: HRESULT; stdcall;  { 74  _5, slot only }
    function Slot75: HRESULT; stdcall;  { 75  _5, slot only }
    function Slot76: HRESULT; stdcall;  { 76  _6, slot only }
    function Slot77: HRESULT; stdcall;  { 77  _7, slot only }
    function Slot78: HRESULT; stdcall;  { 78  _8, slot only }
    function Slot79: HRESULT; stdcall;  { 79  _8, slot only }
    function Slot80: HRESULT; stdcall;  { 80  _8, slot only }
    function Slot81: HRESULT; stdcall;  { 81  _8, slot only }
    function Slot82: HRESULT; stdcall;  { 82  _8, slot only }
    function Slot83: HRESULT; stdcall;  { 83  _8, slot only }
    function Slot84: HRESULT; stdcall;  { 84  _8, slot only }
    function Slot85: HRESULT; stdcall;  { 85  _9, slot only }
    function Slot86: HRESULT; stdcall;  { 86  _9, slot only }
    function Slot87: HRESULT; stdcall;  { 87  _9, slot only }
    function Slot88: HRESULT; stdcall;  { 88  _9, slot only }
    function Slot89: HRESULT; stdcall;  { 89  _9, slot only }
    function Slot90: HRESULT; stdcall;  { 90  _9, slot only }
    function Slot91: HRESULT; stdcall;  { 91  _9, slot only }
    function Slot92: HRESULT; stdcall;  { 92  _9, slot only }
    function Slot93: HRESULT; stdcall;  { 93  _9, slot only }
    function Slot94: HRESULT; stdcall;  { 94  _10, slot only }
    function Slot95: HRESULT; stdcall;  { 95  _10, slot only }
    function Slot96: HRESULT; stdcall;  { 96  _11, slot only }
    function Slot97: HRESULT; stdcall;  { 97  _11, slot only }
    function Slot98: HRESULT; stdcall;  { 98  _11, slot only }
    function Slot99: HRESULT; stdcall;  { 99  _12, slot only }
    function Slot100: HRESULT; stdcall;  { 100  _12, slot only }
    function Slot101: HRESULT; stdcall;  { 101  _12, slot only }
    function Slot102: HRESULT; stdcall;  { 102  _13, slot only }
    function add_ServerCertificateErrorDetected(
      handler: ICoreWebView2ServerCertificateErrorDetectedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                                { 103 }
    function remove_ServerCertificateErrorDetected(a: Pointer): HRESULT; stdcall; { 104 slot only }
    function ClearServerCertificateErrorActions(a: Pointer): HRESULT; stdcall;   { 105 slot only }
  end;

  { --- Downloads (ICoreWebView2_4.add_DownloadStarting). The method order
    and GUID — WebView2.h SDK 1.0.4191.47 (taken by a script, 2026-10-11).
    The vtable prefix is declared up to the last slot needed. --- }
  ICoreWebView2DownloadOperation = interface;

  ICoreWebView2StateChangedEventHandler = interface(IUnknown)
    ['{81336594-7EDE-4BA9-BF71-ACF0A95B58DD}']
    function Invoke(sender: ICoreWebView2DownloadOperation; args: IUnknown): HRESULT; stdcall;
  end;

  ICoreWebView2DownloadOperation = interface(IUnknown)
    ['{3D6B6CF2-AFE1-44C7-A995-C65117714336}']
    function add_BytesReceivedChanged(a, b: Pointer): HRESULT; stdcall;         { 0 slot only }
    function remove_BytesReceivedChanged(a: TEventToken): HRESULT; stdcall;     { 1 slot only }
    function add_EstimatedEndTimeChanged(a, b: Pointer): HRESULT; stdcall;      { 2 slot only }
    function remove_EstimatedEndTimeChanged(a: TEventToken): HRESULT; stdcall;  { 3 slot only }
    function add_StateChanged(handler: ICoreWebView2StateChangedEventHandler;
      out token: TEventToken): HRESULT; stdcall;                                { 4 }
    function remove_StateChanged(a: TEventToken): HRESULT; stdcall;             { 5 slot only }
    function get_Uri(out uri: PWideChar): HRESULT; stdcall;                     { 6 }
    function get_ContentDisposition(a: Pointer): HRESULT; stdcall;              { 7 slot only }
    function get_MimeType(a: Pointer): HRESULT; stdcall;                        { 8 slot only }
    function get_TotalBytesToReceive(a: Pointer): HRESULT; stdcall;             { 9 slot only }
    function get_BytesReceived(a: Pointer): HRESULT; stdcall;                   { 10 slot only }
    function get_EstimatedEndTime(a: Pointer): HRESULT; stdcall;                { 11 slot only }
    function get_ResultFilePath(out path: PWideChar): HRESULT; stdcall;         { 12 }
    function get_State(out state: integer): HRESULT; stdcall;                   { 13 }
  end;

  { An event deferral: the runtime waits for Complete before reading what
    was set in the arguments (WebView2.h, the same SDK). }
  ICoreWebView2Deferral = interface(IUnknown)
    ['{C10E7F7B-B585-46F0-A623-8BEFBF3E4EE0}']
    function Complete: HRESULT; stdcall;                                        { 0 }
  end;

  ICoreWebView2DownloadStartingEventArgs = interface(IUnknown)
    ['{E99BBE21-43E9-4544-A732-282764EAFA60}']
    function get_DownloadOperation(out op: ICoreWebView2DownloadOperation): HRESULT; stdcall; { 0 }
    function get_Cancel(a: Pointer): HRESULT; stdcall;                          { 1 slot only }
    function put_Cancel(cancel: BOOL): HRESULT; stdcall;                        { 2 }
    function get_ResultFilePath(out path: PWideChar): HRESULT; stdcall;         { 3 }
    function put_ResultFilePath(path: PWideChar): HRESULT; stdcall;             { 4 }
    function get_Handled(a: Pointer): HRESULT; stdcall;                         { 5 slot only }
    function put_Handled(handled: BOOL): HRESULT; stdcall;                      { 6 }
    function GetDeferral(out deferral: ICoreWebView2Deferral): HRESULT; stdcall; { 7 }
  end;

  ICoreWebView2DownloadStartingEventHandler = interface(IUnknown)
    ['{EFEDC989-C396-41CA-83F7-07F845A55724}']
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
  end;

  { Slots 58..69 — _2 and _3 (declared in ICoreWebView2_3), then _4. }
  ICoreWebView2_4 = interface(ICoreWebView2_3)
    ['{20D02D59-6DF2-42DC-BD06-F98A694B1302}']
    function add_FrameCreated(a, b: Pointer): HRESULT; stdcall;                 { 70 slot only }
    function remove_FrameCreated(a: TEventToken): HRESULT; stdcall;             { 71 slot only }
    function add_DownloadStarting(handler: ICoreWebView2DownloadStartingEventHandler;
      out token: TEventToken): HRESULT; stdcall;                                { 72 }
  end;

type
  TWebView2NavigateEvent = procedure(Sender: TObject; const AUri: utf8string) of object;
  TWebView2ErrorEvent = procedure(Sender: TObject; const AMessage: string) of object;
  TWebView2TextEvent = procedure(Sender: TObject; const AText: UnicodeString) of object;
  { AHandled left False lets the key through to the page as usual. }
  TWebView2KeyEvent = procedure(Sender: TObject; AVirtualKey: word;
    var AHandled: boolean) of object;
  TWebView2StateEvent = procedure(Sender: TObject; AActive: boolean) of object;
  { The server certificate failed the check: AAllow — let it through (and
    do not ask about this server again until the browser session ends). }
  TWebView2CertEvent = procedure(Sender: TObject; const AUri, APem: utf8string;
    var AAllow: boolean) of object;
  { What to do with a download. The WebView2 downloads window NEVER shows —
    every download is taken over (put_Handled):
      dmSave — the system "Save as" dialog; a refusal in it cancels the
               download, and OnDownloadDone does not come for it;
      dmOpen — silently into the default downloads folder, when done —
               OnDownloadDone (the host opens the file itself). }
  TWebView2DownloadMode = (dmSave, dmOpen);
  { A download started: AMode — what to do with it (dmSave by default).
    Without a handler — dmSave: so in the mini app and call windows too. }
  TWebView2DownloadStartEvent = procedure(Sender: TObject; const AUri: utf8string;
    var AMode: TWebView2DownloadMode) of object;
  { A download finished: APath — where it went; AOk — whole. }
  TWebView2DownloadDoneEvent = procedure(Sender: TObject; const APath: utf8string;
    AOk: boolean; AMode: TWebView2DownloadMode) of object;

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
    FOnAcceleratorKey: TWebView2KeyEvent;
    FOnFullScreenElement: TWebView2StateEvent;
    FStartupScript: UnicodeString;
    FOnWebMessage: TWebView2TextEvent;
    FVirtualHost: UnicodeString;
    FVirtualFolder: UnicodeString;
    FOnCertificateError: TWebView2CertEvent;
    FOnDownloadStart: TWebView2DownloadStartEvent;
    FOnDownloadDone: TWebView2DownloadDoneEvent;
    { Save dialogs still in the queue (TDownloadAsk): on destruction they
      are told there is no owner any more. }
    FAsks: TFPList;
    procedure EnvironmentReady(AResult: HRESULT; AEnv: ICoreWebView2Environment);
    procedure ControllerReady(AResult: HRESULT; ACtrl: ICoreWebView2Controller);
    function ExternalUriRequested(const AUri: UnicodeString): boolean;
    function AcceleratorKey(AVirtualKey: word): boolean;
    procedure FullScreenElementChanged;
    procedure ReportUnavailable(const AMessage: string);
    procedure StartupScriptAdded;
    procedure WebMessage(const AText: UnicodeString);
    function CertificateError(const AUri, APem: UnicodeString): boolean;
    function DownloadMode(const AUri: UnicodeString): TWebView2DownloadMode;
    procedure DownloadFinished(const APath: UnicodeString; AOk: boolean;
      AMode: TWebView2DownloadMode);
    function AskSavePath(const ASuggested: UnicodeString): UnicodeString;
  public
    constructor Create(AHost: HWND);
    destructor Destroy; override;
    { Available only after the runtime has been found and the control
      built; before that Navigate just remembers where to go. }
    property Ready: boolean read FReady;
    procedure Navigate(const AUrl: utf8string);
    procedure SetBounds(const ARect: TRect);
    { Keyboard focus to the page. Without it the runtime sees no keys at
      all, and AcceleratorKeyPressed never fires. }
    procedure Focus;
    { A link the page asked to open in a new window. Not handled here:
      the host decides, and in this app it hands it to the system
      browser - a stranger's link must never open inside a shell with
      no address bar. }
    property OnExternalUri: TWebView2NavigateEvent read FOnExternalUri write FOnExternalUri;
    { Downloads (see TWebView2DownloadMode). The subscription to them is
      always set, in ControllerReady. }
    property OnDownloadStart: TWebView2DownloadStartEvent read FOnDownloadStart write FOnDownloadStart;
    property OnDownloadDone: TWebView2DownloadDoneEvent read FOnDownloadDone write FOnDownloadDone;
    { The runtime is missing or refused to start. Reported rather than
      left as an empty window. }
    property OnUnavailable: TWebView2ErrorEvent read FOnUnavailable write FOnUnavailable;
    { A key the runtime treats as an accelerator. What any of them MEANS
      is the host's business - this only carries it across. }
    property OnAcceleratorKey: TWebView2KeyEvent read FOnAcceleratorKey write FOnAcceleratorKey;
    { The page entered or left element fullscreen. The runtime has
      already sized the element to the view; whether the WINDOW follows
      is the host's decision. }
    property OnFullScreenElement: TWebView2StateEvent read FOnFullScreenElement write FOnFullScreenElement;
    { A script put into every document BEFORE its own scripts
      (AddScriptToExecuteOnDocumentCreated). Set right after Create:
      navigation waits until it is in place. }
    property StartupScript: UnicodeString read FStartupScript write FStartupScript;
    { A string from the page's chrome.webview.postMessage. }
    property OnWebMessage: TWebView2TextEvent read FOnWebMessage write FOnWebMessage;
    { A folder as the site https://NAME/ (SetVirtualHostNameToFolderMapping):
      the window's page loads from its own files. Set right after Create,
      like StartupScript. }
    procedure MapVirtualHost(const AHost, AFolder: utf8string);
    { A server certificate error (self-signed): the host decides. Without a
      handler — as in a browser, the request is cancelled. }
    property OnCertificateError: TWebView2CertEvent read FOnCertificateError write FOnCertificateError;
    { A message to the page (chrome.webview, the message event, e.data is
      already parsed JSON). }
    procedure PostJson(const AJson: utf8string);
    procedure Reload;
  end;

{ True when a WebView2 runtime is installed. Checked before building a
  window around something that cannot exist. }
function WebView2Available: boolean;

implementation

uses
  constants, guiconst, lsrepair;

const
  WEBVIEW2_LOADER = 'WebView2Loader.dll';
  { The loader is loaded by hand (LoadLibrary, next to the exe), not
    statically (external): no DLL — the program still starts and says what
    is missing (WebView2Available), rather than failing before its first
    line with a system load error. }

  { COREWEBVIEW2_KEY_EVENT_KIND and COREWEBVIEW2_MOVE_FOCUS_REASON,
    only the members this unit reads. Values from the header. }
  KEY_EVENT_KIND_KEY_DOWN = 0;
  KEY_EVENT_KIND_SYSTEM_KEY_DOWN = 2;
  MOVE_FOCUS_REASON_PROGRAMMATIC = 0;

type
  TCreateEnvFn = function(browserExecutableFolder, userDataFolder: PWideChar;
    environmentOptions: Pointer;
    environmentCreatedHandler: ICoreWebView2EnvironmentCompletedHandler): HRESULT; stdcall;
  TVersionFn = function(browserExecutableFolder: PWideChar;
    out versionInfo: PWideChar): HRESULT; stdcall;

var
  GLoader: HMODULE = 0;
  GCreateEnv: TCreateEnvFn = nil;
  GVersion: TVersionFn = nil;
  { The localStorage journal check (lsrepair) — already done in this run. }
  GStorageChecked: boolean = False;

{ The loader once per process. Not found anywhere — an exception: that is
  how "WebView2 is unavailable" was answered before too
  (WebView2Available, Create). }
procedure EnsureLoader;
var
  Dir: string;
begin
  if GLoader <> 0 then begin
    Exit;
  end;
  Dir := ExtractFilePath(ParamStr(0));
  GLoader := LoadLibraryW(PWideChar(UnicodeString(Dir + WEBVIEW2_LOADER)));
  if GLoader = 0 then begin
    raise Exception.Create(WEBVIEW2_LOADER + ' not found');
  end;
  Pointer(GCreateEnv) := GetProcAddress(GLoader, 'CreateCoreWebView2EnvironmentWithOptions');
  Pointer(GVersion) := GetProcAddress(GLoader, 'GetAvailableCoreWebView2BrowserVersionString');
  if (not Assigned(GCreateEnv)) or (not Assigned(GVersion)) then begin
    raise Exception.Create(WEBVIEW2_LOADER + ' has no expected exports');
  end;
end;

function CreateCoreWebView2EnvironmentWithOptions(
  browserExecutableFolder, userDataFolder: PWideChar;
  environmentOptions: Pointer;
  environmentCreatedHandler: ICoreWebView2EnvironmentCompletedHandler): HRESULT;
begin
  EnsureLoader;
  Result := GCreateEnv(browserExecutableFolder, userDataFolder,
    environmentOptions, environmentCreatedHandler);
end;

{ The loader also exports a version probe, which is how availability is
  answered without starting anything. }
function GetAvailableCoreWebView2BrowserVersionString(
  browserExecutableFolder: PWideChar; out versionInfo: PWideChar): HRESULT;
begin
  EnsureLoader;
  Result := GVersion(browserExecutableFolder, versionInfo);
end;

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

  TCertErrorHandler = class(TInterfacedObject,
    ICoreWebView2ServerCertificateErrorDetectedEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2ServerCertificateErrorDetectedEventArgs): HRESULT; stdcall;
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

  TAccelHandler = class(TInterfacedObject,
    ICoreWebView2AcceleratorKeyPressedEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2Controller;
      args: ICoreWebView2AcceleratorKeyPressedEventArgs): HRESULT; stdcall;
  end;

  TWebMessageHandler = class(TInterfacedObject,
    ICoreWebView2WebMessageReceivedEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2WebMessageReceivedEventArgs): HRESULT; stdcall;
  end;

  { Geolocation — only for our own page from the local server (http on
    127.0.0.1 / localhost): mini apps (https) get whatever the runtime
    decides by default. Other permissions are left alone. }
  TPermissionHandler = class(TInterfacedObject,
    ICoreWebView2PermissionRequestedEventHandler)
  public
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2PermissionRequestedEventArgs): HRESULT; stdcall;
  end;

  TScriptAddedHandler = class(TInterfacedObject,
    ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(errorCode: HRESULT; AId: PWideChar): HRESULT; stdcall;
  end;

  TDownloadStartingHandler = class(TInterfacedObject,
    ICoreWebView2DownloadStartingEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2;
      args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
  end;

  TDownloadStateHandler = class(TInterfacedObject,
    ICoreWebView2StateChangedEventHandler)
  private
    FOwner: TWebView2;
    FMode: TWebView2DownloadMode;
  public
    constructor Create(AOwner: TWebView2; AMode: TWebView2DownloadMode);
    function Invoke(sender: ICoreWebView2DownloadOperation; args: IUnknown): HRESULT; stdcall;
  end;

  { The "where to save" question — OUTSIDE the event handler: a modal
    dialog inside a call from the runtime is a nested message loop in the
    middle of its code. The handler takes a deferral and queues this object
    on the main thread (TThread.ForceQueue); the answer goes into the
    arguments, then Complete. It keeps the arguments and the operation
    alive until the answer. }
  TDownloadAsk = class
  public
    Owner: TWebView2;
    Args: ICoreWebView2DownloadStartingEventArgs;
    Op: ICoreWebView2DownloadOperation;
    Deferral: ICoreWebView2Deferral;
    Suggested: UnicodeString;
    procedure Run;
  end;

  TFullScreenHandler = class(TInterfacedObject,
    ICoreWebView2ContainsFullScreenElementChangedEventHandler)
  private
    FOwner: TWebView2;
  public
    constructor Create(AOwner: TWebView2);
    function Invoke(sender: ICoreWebView2; args: IUnknown): HRESULT; stdcall;
  end;

{ COREWEBVIEW2_DOWNLOAD_STATE (WebView2.h): 0 in progress, 1 interrupted, 2 completed. }
const
  DOWNLOAD_STATE_IN_PROGRESS = 0;
  DOWNLOAD_STATE_COMPLETED = 2;

{ A string from the runtime — into a UnicodeString, freeing it (CoTaskMemFree). }
function TakeComString(P: PWideChar): UnicodeString;
begin
  Result := '';
  if P <> nil then begin
    Result := UnicodeString(P);
    CoTaskMemFree(P);
  end;
end;

constructor TDownloadStartingHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TDownloadStartingHandler.Invoke(sender: ICoreWebView2;
  args: ICoreWebView2DownloadStartingEventArgs): HRESULT; stdcall;
var
  Op: ICoreWebView2DownloadOperation;
  P: PWideChar;
  Token: TEventToken;
  Mode: TWebView2DownloadMode;
  Ask: TDownloadAsk;
begin
  Result := S_OK;
  if (FOwner = nil) or (args = nil) then begin
    Exit;
  end;
  Op := nil;
  if Failed(args.get_DownloadOperation(Op)) or (Op = nil) then begin
    Exit;
  end;
  P := nil;
  Op.get_Uri(P);
  Mode := FOwner.DownloadMode(TakeComString(P));
  { No download gets the WebView2 downloads window. }
  args.put_Handled(True);
  if Mode = dmOpen then begin
    { The path — the default one (the downloads folder, a name without overwriting). }
    Op.add_StateChanged(TDownloadStateHandler.Create(FOwner, dmOpen), Token);
    Exit;
  end;
  { Saving — first ask where. }
  Ask := TDownloadAsk.Create;
  Ask.Owner := FOwner;
  Ask.Args := args;
  Ask.Op := Op;
  P := nil;
  args.get_ResultFilePath(P);
  Ask.Suggested := TakeComString(P);
  Ask.Deferral := nil;
  args.GetDeferral(Ask.Deferral);
  FOwner.FAsks.Add(Ask);
  TThread.ForceQueue(nil, @Ask.Run);
end;

procedure TDownloadAsk.Run;
var
  Path: UnicodeString;
  Token: TEventToken;
begin
  try
    Path := '';
    if Owner <> nil then begin
      Owner.FAsks.Remove(Self);
      Path := Owner.AskSavePath(Suggested);
    end;
    if Path = '' then begin
      Args.put_Cancel(True);
    end else begin
      { The file exists already — the person agreed to replace it in the
        dialog; the runtime overwrites at such a path. }
      Args.put_ResultFilePath(PWideChar(Path));
      Op.add_StateChanged(TDownloadStateHandler.Create(Owner, dmSave), Token);
    end;
    if Deferral <> nil then begin
      Deferral.Complete;
    end;
  finally
    Free;
  end;
end;

constructor TDownloadStateHandler.Create(AOwner: TWebView2; AMode: TWebView2DownloadMode);
begin
  inherited Create;
  FOwner := AOwner;
  FMode := AMode;
end;

function TDownloadStateHandler.Invoke(sender: ICoreWebView2DownloadOperation;
  args: IUnknown): HRESULT; stdcall;
var
  State: integer;
  P: PWideChar;
begin
  Result := S_OK;
  if (FOwner = nil) or (sender = nil) then begin
    Exit;
  end;
  State := DOWNLOAD_STATE_IN_PROGRESS;
  if Failed(sender.get_State(State)) or (State = DOWNLOAD_STATE_IN_PROGRESS) then begin
    Exit;
  end;
  P := nil;
  sender.get_ResultFilePath(P);
  FOwner.DownloadFinished(TakeComString(P), State = DOWNLOAD_STATE_COMPLETED, FMode);
end;

constructor TWebMessageHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TWebMessageHandler.Invoke(sender: ICoreWebView2;
  args: ICoreWebView2WebMessageReceivedEventArgs): HRESULT; stdcall;
var
  P: PWideChar;
  S: UnicodeString;
begin
  Result := S_OK;
  if (FOwner = nil) or (args = nil) then begin
    Exit;
  end;
  P := nil;
  { Strings only: the bridge sends JSON as a string. A non-string is not ours. }
  if Succeeded(args.TryGetWebMessageAsString(P)) and (P <> nil) then begin
    S := UnicodeString(P);
    { The runtime allocated the string — the caller frees it. }
    CoTaskMemFree(P);
    FOwner.WebMessage(S);
  end;
end;

function TPermissionHandler.Invoke(sender: ICoreWebView2;
  args: ICoreWebView2PermissionRequestedEventArgs): HRESULT; stdcall;
var
  Kind: integer;
  P: PWideChar;
  Uri: UnicodeString;
begin
  Result := S_OK;
  { Geolocation — for "send location"; microphone and camera — for calls
    (WebRTC on the page) and voice messages. Only for our own page — from
    the window's files, WEB_APP_ORIGIN; foreign ones (mini apps) — the
    runtime's default decision. }
  if (args = nil) or Failed(args.get_PermissionKind(Kind))
     or ((Kind <> WEBVIEW2_PERMISSION_KIND_GEOLOCATION)
         and (Kind <> WEBVIEW2_PERMISSION_KIND_MICROPHONE)
         and (Kind <> WEBVIEW2_PERMISSION_KIND_CAMERA)) then begin
    Exit;
  end;
  P := nil;
  Uri := '';
  if Succeeded(args.get_Uri(P)) and (P <> nil) then begin
    Uri := UnicodeString(P);
    CoTaskMemFree(P);
  end;
  if Pos(UnicodeString(WEB_APP_ORIGIN + '/'), Uri) = 1 then begin
    args.put_State(WEBVIEW2_PERMISSION_STATE_ALLOW);
  end;
end;

constructor TScriptAddedHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TScriptAddedHandler.Invoke(errorCode: HRESULT; AId: PWideChar): HRESULT; stdcall;
begin
  if FOwner <> nil then begin
    FOwner.StartupScriptAdded;
  end;
  Result := S_OK;
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

const
  { COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION, COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND. }
  CERT_ACTION_ALWAYS_ALLOW = 0;
  CERT_ACTION_CANCEL = 1;
  HOST_RESOURCE_ACCESS_ALLOW = 1;

constructor TCertErrorHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TCertErrorHandler.Invoke(sender: ICoreWebView2;
  args: ICoreWebView2ServerCertificateErrorDetectedEventArgs): HRESULT; stdcall;
var
  P: PWideChar;
  Uri, Pem: UnicodeString;
  Cert: ICoreWebView2Certificate;
begin
  Result := S_OK;
  if (FOwner = nil) or (args = nil) then begin
    Exit;
  end;
  Uri := '';
  Pem := '';
  P := nil;
  if Succeeded(args.get_RequestUri(P)) and (P <> nil) then begin
    Uri := UnicodeString(P);
    CoTaskMemFree(P);
  end;
  Cert := nil;
  if Succeeded(args.get_ServerCertificate(Cert)) and (Cert <> nil) then begin
    P := nil;
    if Succeeded(Cert.ToPemEncoding(P)) and (P <> nil) then begin
      Pem := UnicodeString(P);
      CoTaskMemFree(P);
    end;
  end;
  if FOwner.CertificateError(Uri, Pem) then begin
    args.put_Action(CERT_ACTION_ALWAYS_ALLOW);
  end else begin
    args.put_Action(CERT_ACTION_CANCEL);
  end;
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

constructor TAccelHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TAccelHandler.Invoke(sender: ICoreWebView2Controller;
  args: ICoreWebView2AcceleratorKeyPressedEventArgs): HRESULT; stdcall;
var
  Kind, Key: DWORD;
begin
  Result := S_OK;
  if (FOwner = nil) or (args = nil) then begin
    Exit;
  end;
  Kind := 0;
  Key := 0;
  if Failed(args.get_KeyEventKind(Kind)) or Failed(args.get_VirtualKey(Key)) then begin
    Exit;
  end;
  { Down only. The runtime reports the release as well, and acting on
    both would toggle twice on one press. }
  if (Kind <> KEY_EVENT_KIND_KEY_DOWN)
     and (Kind <> KEY_EVENT_KIND_SYSTEM_KEY_DOWN) then begin
    Exit;
  end;
  if FOwner.AcceleratorKey(word(Key)) then begin
    { Handled means the page never sees it, which is what we want for a
      key the shell has just acted on. }
    args.put_Handled(True);
  end;
end;

constructor TFullScreenHandler.Create(AOwner: TWebView2);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TFullScreenHandler.Invoke(sender: ICoreWebView2;
  args: IUnknown): HRESULT; stdcall;
begin
  Result := S_OK;
  if FOwner <> nil then begin
    FOwner.FullScreenElementChanged;
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
  FAsks := TFPList.Create;

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
  { The project's former name — the former folder: it moves whole, so the
    page's localStorage (theme, remembered choices) is not lost. Only if
    the new one does not exist yet. }
  if (not DirectoryExists(GetEnvironmentVariable('LOCALAPPDATA') + '\' + APP_DATA_DIR))
     and DirectoryExists(GetEnvironmentVariable('LOCALAPPDATA') + '\' + APP_DATA_DIR_LEGACY) then begin
    RenameFile(GetEnvironmentVariable('LOCALAPPDATA') + '\' + APP_DATA_DIR_LEGACY,
      GetEnvironmentVariable('LOCALAPPDATA') + '\' + APP_DATA_DIR);
  end;
  DataDir := UnicodeString(GetEnvironmentVariable('LOCALAPPDATA'))
    + '\' + UnicodeString(APP_DATA_DIR) + '\webview2';

  { A localStorage journal with a hole after a broken-off session — before
    the environment takes the files (lsrepair.pas). Once per run: windows
    opened later share the same profile already running. }
  if not GStorageChecked then begin
    GStorageChecked := True;
    RepairLocalStorage(string(DataDir));
  end;

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
var
  I: integer;
begin
  { A dialog not shown yet — without an owner: the download is cancelled. }
  for I := 0 to FAsks.Count - 1 do begin
    TDownloadAsk(FAsks[I]).Owner := nil;
  end;
  FAsks.Free;
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
  V3: ICoreWebView2_3;
  V14: ICoreWebView2_14;
  V4: ICoreWebView2_4;
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

  if FVirtualHost <> '' then begin
    if Supports(FWebView, ICoreWebView2_3, V3) then begin
      V3.SetVirtualHostNameToFolderMapping(PWideChar(FVirtualHost),
        PWideChar(FVirtualFolder), HOST_RESOURCE_ACCESS_ALLOW);
    end;
  end;
  if Assigned(FOnCertificateError) and Supports(FWebView, ICoreWebView2_14, V14) then begin
    V14.add_ServerCertificateErrorDetected(TCertErrorHandler.Create(Self), Token);
  end;
  FWebView.add_NewWindowRequested(TNewWindowHandler.Create(Self), Token);
  if Supports(FWebView, ICoreWebView2_4, V4) then begin
    V4.add_DownloadStarting(TDownloadStartingHandler.Create(Self), Token);
  end;
  FWebView.add_ContainsFullScreenElementChanged(TFullScreenHandler.Create(Self), Token);
  FWebView.add_PermissionRequested(TPermissionHandler.Create, Token);
  FController.add_AcceleratorKeyPressed(TAccelHandler.Create(Self), Token);
  if Assigned(FOnWebMessage) then begin
    FWebView.add_WebMessageReceived(TWebMessageHandler.Create(Self), Token);
  end;

  Windows.GetClientRect(FHost, @R);
  FController.put_Bounds(R);
  FController.put_IsVisible(True);

  { The startup script — before navigation: wait for its answer, and only
    then go to the address (StartupScriptAdded). Without a script — as before. }
  if FStartupScript <> '' then begin
    FWebView.AddScriptToExecuteOnDocumentCreated(PWideChar(FStartupScript),
      TScriptAddedHandler.Create(Self));
  end else begin
    StartupScriptAdded;
  end;
  { The page takes the keyboard as soon as it exists. Nothing else in
    this window can want it - the whole client area is the runtime's
    child - and without focus the runtime reports no keys at all, so
    F11 would do nothing until the first click. MoveFocus stays inside
    this window, so it cannot steal focus from another one. }
  FController.MoveFocus(MOVE_FOCUS_REASON_PROGRAMMATIC);
end;

function TWebView2.ExternalUriRequested(const AUri: UnicodeString): boolean;
begin
  Result := False;
  if (AUri <> '') and Assigned(FOnExternalUri) then begin
    FOnExternalUri(Self, utf8string(AUri));
    Result := True;
  end;
end;

function TWebView2.AcceleratorKey(AVirtualKey: word): boolean;
begin
  Result := False;
  if Assigned(FOnAcceleratorKey) then begin
    FOnAcceleratorKey(Self, AVirtualKey, Result);
  end;
end;

procedure TWebView2.FullScreenElementChanged;
var
  Active: BOOL;
begin
  if (FWebView = nil) or not Assigned(FOnFullScreenElement) then begin
    Exit;
  end;
  Active := False;
  if Succeeded(FWebView.get_ContainsFullScreenElement(Active)) then begin
    FOnFullScreenElement(Self, Active);
  end;
end;

procedure TWebView2.MapVirtualHost(const AHost, AFolder: utf8string);
begin
  FVirtualHost := UnicodeString(AHost);
  FVirtualFolder := UnicodeString(AFolder);
end;

function TWebView2.CertificateError(const AUri, APem: UnicodeString): boolean;
begin
  Result := False;
  if Assigned(FOnCertificateError) then begin
    FOnCertificateError(Self, utf8string(AUri), utf8string(APem), Result);
  end;
end;

function TWebView2.DownloadMode(const AUri: UnicodeString): TWebView2DownloadMode;
begin
  Result := dmSave;
  if Assigned(FOnDownloadStart) then begin
    FOnDownloadStart(Self, utf8string(AUri), Result);
  end;
end;

procedure TWebView2.DownloadFinished(const APath: UnicodeString; AOk: boolean;
  AMode: TWebView2DownloadMode);
begin
  if Assigned(FOnDownloadDone) then begin
    FOnDownloadDone(Self, utf8string(APath), AOk, AMode);
  end;
end;

{ The folder saved to last time — until the program exits; the first time —
  the folder the runtime suggested (the person's downloads). }
var
  GLastSaveDir: UnicodeString = '';

{ The system "Save as" (comdlg32, the Explorer style). '' — refusal. The
  filter — by the suggested name's extension, plus "all files". }
function TWebView2.AskSavePath(const ASuggested: UnicodeString): UnicodeString;
var
  Ofn: TOpenFileNameW;
  Buf: array[0..SAVE_DIALOG_PATH_MAX] of WideChar;
  Name, Dir, Ext, Filter, DefExt: UnicodeString;
  Owner: HWND;
begin
  Result := '';
  Name := ExtractFileName(ASuggested);
  Dir := GLastSaveDir;
  if Dir = '' then begin
    Dir := ExtractFileDir(ASuggested);
  end;
  Ext := ExtractFileExt(Name);
  DefExt := Copy(Ext, 2, MaxInt);
  if DefExt <> '' then begin
    Filter := UpperCase(DefExt) + ' file (*' + Ext + ')' + #0 + '*' + Ext + #0
      + 'All files (*.*)' + #0 + '*.*' + #0#0;
  end else begin
    Filter := 'All files (*.*)' + #0 + '*.*' + #0#0;
  end;

  FillChar(Buf, SizeOf(Buf), 0);
  if Length(Name) > SAVE_DIALOG_PATH_MAX then begin
    SetLength(Name, SAVE_DIALOG_PATH_MAX);
  end;
  if Name <> '' then begin
    Move(PWideChar(Name)^, Buf[0], Length(Name) * SizeOf(WideChar));
  end;

  { The owner is the top-level window: while the dialog is open, it is
    unavailable, as with any modal window. }
  Owner := GetAncestor(FHost, GA_ROOT);
  if Owner = 0 then begin
    Owner := FHost;
  end;

  FillChar(Ofn, SizeOf(Ofn), 0);
  Ofn.lStructSize := SizeOf(Ofn);
  Ofn.hwndOwner := Owner;
  Ofn.lpstrFilter := PWideChar(Filter);
  Ofn.nFilterIndex := 1;
  Ofn.lpstrFile := @Buf[0];
  Ofn.nMaxFile := Length(Buf);
  if Dir <> '' then begin
    Ofn.lpstrInitialDir := PWideChar(Dir);
  end;
  if DefExt <> '' then begin
    Ofn.lpstrDefExt := PWideChar(DefExt);
  end;
  Ofn.Flags := OFN_EXPLORER or OFN_OVERWRITEPROMPT or OFN_PATHMUSTEXIST
    or OFN_NOCHANGEDIR;
  if not GetSaveFileNameW(LPOPENFILENAME(@Ofn)) then begin
    Exit;
  end;
  Result := UnicodeString(PWideChar(@Buf[0]));
  GLastSaveDir := ExtractFileDir(Result);
end;

procedure TWebView2.StartupScriptAdded;
begin
  FReady := True;
  if (FPendingUrl <> '') and (FWebView <> nil) then begin
    FWebView.Navigate(PWideChar(FPendingUrl));
    FPendingUrl := '';
  end;
end;

procedure TWebView2.WebMessage(const AText: UnicodeString);
begin
  if Assigned(FOnWebMessage) then begin
    FOnWebMessage(Self, AText);
  end;
end;

procedure TWebView2.PostJson(const AJson: utf8string);
begin
  if FReady and (FWebView <> nil) then begin
    FWebView.PostWebMessageAsJson(PWideChar(UnicodeString(AJson)));
  end;
end;

procedure TWebView2.Reload;
begin
  if FReady and (FWebView <> nil) then begin
    FWebView.Reload;
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

procedure TWebView2.Focus;
begin
  if FController <> nil then begin
    FController.MoveFocus(MOVE_FOCUS_REASON_PROGRAMMATIC);
  end;
end;

end.
