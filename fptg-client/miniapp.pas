unit miniapp;

{ The bot's mini app window (Telegram Mini App / Web App).

  A SEPARATE WebView2 WINDOW, NOT AN <iframe> IN THE PAGE — and this was
  checked rather than chosen: the most popular apps forbid being shown in
  a frame of a foreign site. walletbot.me sends frame-ancestors 'self'
  https://web.telegram.org, webappinternal.telegram.org (BotFather) —
  X-Frame-Options: ALLOW-FROM https://web.telegram.org. In a frame of a
  page from 127.0.0.1 they would be blank. In its own window the app opens
  as an ordinary page, without a frame — Telegram Desktop does the same.

  THE BRIDGE — window.TelegramWebviewProxy: telegram-web-app.js, finding
  this object, sends every event through it (postEvent(type, JSON string)),
  and receives events from the client through
  Telegram.WebView.receiveEvent. The object is put in place by a startup
  script (BRIDGE_JS) before the page's own scripts; it relays events into
  chrome.webview.postMessage, and this window's answers (PostJson) into
  receiveEvent.

  Requests to TDLib (the app's own methods — CloudStorage and the like,
  permission to write to the user, keyboard button data) go to the server
  through the main page: the window is in a different process from TDLib
  and maybe on another machine. The window sends the page (t: miniappReq,
  id, cmd, args), the page sends the server a command (webapp.custom and
  so on), the answer comes back (t: miniappResp) into MiniAppResponse. The
  id carries the window's serial number: an answer to an already closed
  window does not reach a new one.

  There is one window: a new app replaces the open one. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, StdCtrls, Graphics, Dialogs,
  LCLIntf, LCLType, fpjson, jsonparser, BCButton, BCTypes;

{ Opens an app (or replaces the open one). ALaunchId — from openWebApp, 0
  for an app from a keyboard button (getWebAppUrl); AButtonText — that
  button's text, sendWebAppData needs it. AThemeParams — theme_params for
  the theme_changed event; ownership passes to the window. }
procedure OpenMiniApp(const AUrl, ATitle: utf8string; ABotUserId, ALaunchId: Int64;
  const AButtonText: utf8string; AThemeParams: TJSONObject);

{ The server's answer to the window's request (the page passed on t:
  miniappResp). AResult — the command's answer object or nil; not taken over. }
procedure MiniAppResponse(AId: Int64; AOk: boolean; AResult: TJSONObject;
  const AError: string);

implementation

uses
  constants, guiconst, webview2, webui, winframe;

const
  { The kind of request in the id (see MiniAppResponse). }
  REQ_CUSTOM = 1;
  REQ_WRITE_ACCESS = 2;

  { Only in the main document: frames have no chrome.webview. }
  BRIDGE_JS =
    '(function () {' +
    '  if (window !== window.top || window.TelegramWebviewProxy) return;' +
    '  window.TelegramWebviewProxy = {' +
    '    postEvent: function (t, d) {' +
    '      window.chrome.webview.postMessage(JSON.stringify({ t: t, d: d || "" }));' +
    '    }' +
    '  };' +
    '  window.chrome.webview.addEventListener("message", function (e) {' +
    '    var m = e.data;' +
    '    if (m && m.t && window.Telegram && window.Telegram.WebView) {' +
    '      window.Telegram.WebView.receiveEvent(m.t, m.d);' +
    '    }' +
    '  });' +
    '})();';

type
  TFormMiniApp = class(TForm)
  private
    FSerial: integer;
    FBotUserId: Int64;
    FLaunchId: Int64;
    FButtonText: utf8string;
    FTheme: TJSONObject;
    FNeedConfirm: boolean;
    FView: TWebView2;
    FHost: TPanel;
    FBar: TPanel;
    { TBCButton (BGRAControls), not TButton: Windows draws the system button
      with its theme, and its colour cannot be set from LCL — while the
      header must be in the app's theme colours (light or dark), rounded. }
    FBack: TBCButton;
    FSettings: TBCButton;
    FReload: TBCButton;
    FBarColor: TColor;      { header background }
    FButtonColor: TColor;   { button background }
    FHoverColor: TColor;    { background of the button under the cursor }
    FPressColor: TColor;    { background of a pressed button }
    FTextColor: TColor;
    FMainBtn: TPanel;
    FSecondBtn: TPanel;
    FReqIds: TStringList;     { the app's req_id by the index of the request to the server }
    procedure HostResize(Sender: TObject);
    procedure ApplyTheme;
    function MakeBarButton(const ACaption: string; AAlign: TAlign;
      AClick: TNotifyEvent): TBCButton;
    procedure ViewMessage(Sender: TObject; const AText: UnicodeString);
    procedure ViewExternal(Sender: TObject; const AUri: utf8string);
    procedure BackClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure MainClick(Sender: TObject);
    procedure SecondClick(Sender: TObject);
    procedure Send(const AType: utf8string; AData: TJSONData);
    procedure SendViewport;
    procedure SetupButton(APanel: TPanel; AData: TJSONObject);
    procedure Popup(AData: TJSONObject);
    procedure CustomMethod(AData: TJSONObject);
    procedure WriteAccess;
    procedure HandleEvent(const AType: utf8string; AData: TJSONObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor CreateApp(const AUrl, ATitle: utf8string; ABotUserId, ALaunchId: Int64;
      const AButtonText: utf8string; AThemeParams: TJSONObject);
    destructor Destroy; override;
    function CloseQuery: boolean; override;
    procedure CustomDone(AIndex: integer; AOk: boolean; const AResult, AError: string);
    procedure WriteAccessDone(AOk: boolean);
  end;


var
  GForm: TFormMiniApp = nil;
  GSerial: integer = 0;

{ A command to the server through the main page. AArgs is taken over. AId =
  0 — no answer needed. }
procedure ServerCall(const ACmd: string; AArgs: TJSONObject; AId: Int64);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('t', 'miniappReq');
    O.Add('id', AId);
    O.Add('cmd', ACmd);
    O.Add('args', AArgs);
    WebUiPostJson(utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

{ Request id: (the window's serial number shl 20) or (kind shl 16) or index. }
function RequestId(AKind, AIndex: integer): Int64;
begin
  Result := (Int64(GForm.FSerial) shl 20) or (Int64(AKind) shl 16) or (AIndex and $FFFF);
end;

procedure MiniAppResponse(AId: Int64; AOk: boolean; AResult: TJSONObject;
  const AError: string);
var
  Res: string;
begin
  if (GForm = nil) or ((AId shr 20) <> GForm.FSerial) then begin
    Exit;
  end;
  case integer((AId shr 16) and $F) of
    REQ_CUSTOM: begin
      Res := '';
      if (AResult <> nil) and (AResult.Find('result') <> nil) then begin
        Res := AResult.Get('result', '');
      end;
      GForm.CustomDone(integer(AId and $FFFF), AOk, Res, AError);
    end;
    REQ_WRITE_ACCESS: begin
      GForm.WriteAccessDone(AOk);
    end;
  end;
end;

{ '#rrggbb' -> TColor (BGR); clNone for anything else. }
function HexColor(const AHex: string): TColor;
var
  V: integer;
begin
  Result := clNone;
  if (Length(AHex) = 7) and (AHex[1] = '#') and TryStrToInt('$' + Copy(AHex, 2, 6), V) then begin
    Result := TColor(((V and $FF) shl 16) or (V and $FF00) or ((V shr 16) and $FF));
  end;
end;

function JStr(AObj: TJSONObject; const AName: string): string;
begin
  Result := '';
  if (AObj <> nil) and (AObj.Find(AName) <> nil) and (AObj.Find(AName).JSONType = jtString) then begin
    Result := AObj.Strings[AName];
  end;
end;

function JBool(AObj: TJSONObject; const AName: string): boolean;
begin
  Result := (AObj <> nil) and (AObj.Find(AName) <> nil)
    and (AObj.Find(AName).JSONType = jtBoolean) and AObj.Booleans[AName];
end;

{ ------------------------------------------------------------------ }
{ TFormMiniApp                                                       }
{ ------------------------------------------------------------------ }

function MakeButton(AOwner: TComponent; AParent: TWinControl; const ACaption: string;
  AAlign: TAlign; AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(AOwner);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Align := AAlign;
  Result.AutoSize := True;
  Result.OnClick := AClick;
end;

function MakeAppButton(AOwner: TComponent; AParent: TWinControl; AClick: TNotifyEvent): TPanel;
begin
  Result := TPanel.Create(AOwner);
  Result.Parent := AParent;
  Result.Align := alBottom;
  Result.Height := MINIAPP_BUTTON_H;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Cursor := crHandPoint;
  Result.Font.Style := [fsBold];
  Result.Visible := False;
  Result.OnClick := AClick;
end;

constructor TFormMiniApp.CreateApp(const AUrl, ATitle: utf8string;
  ABotUserId, ALaunchId: Int64; const AButtonText: utf8string; AThemeParams: TJSONObject);
begin
  inherited CreateNew(nil);
  Inc(GSerial);
  FSerial := GSerial and $7FFF;
  FBotUserId := ABotUserId;
  FLaunchId := ALaunchId;
  FButtonText := AButtonText;
  FTheme := AThemeParams;
  FReqIds := TStringList.Create;
  OnClose := @FormClose;

  Caption := string(ATitle);
  Width := MINIAPP_WIDTH;
  Height := MINIAPP_HEIGHT;
  { Above the main window and without its own taskbar button: the owner is
    the main web window. BEFORE the first Handle — the owner goes into the
    window's creation parameters. }
  if WebUiForm <> nil then begin
    PopupMode := pmExplicit;
    PopupParent := WebUiForm;
    Position := poOwnerFormCenter;
  end else begin
    Position := poScreenCenter;
  end;

  FBar := TPanel.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alTop;
  FBar.Height := MINIAPP_BAR_H;
  FBar.BevelOuter := bvNone;
  FBar.ParentBackground := False;
  ApplyTheme;
  FBack := MakeBarButton('Back', alLeft, @BackClick);
  FBack.Visible := False;
  FReload := MakeBarButton('Reload', alRight, @ReloadClick);
  FSettings := MakeBarButton('Settings', alRight, @SettingsClick);
  FSettings.Visible := False;

  { Bottom up: the main button at the very edge, the secondary one above it. }
  FMainBtn := MakeAppButton(Self, Self, @MainClick);
  FSecondBtn := MakeAppButton(Self, Self, @SecondClick);

  FHost := TPanel.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  FHost.BevelOuter := bvNone;
  FHost.OnResize := @HostResize;

  FView := TWebView2.Create(FHost.Handle);
  { The frame in the app's theme colour (winframe), before the window shows. }
  FrameAttach(Handle);
  FView.StartupScript := UnicodeString(BRIDGE_JS);
  FView.OnWebMessage := @ViewMessage;
  FView.OnExternalUri := @ViewExternal;
  FView.Navigate(AUrl);
end;

destructor TFormMiniApp.Destroy;
var
  A: TJSONObject;
begin
  { Telegram must know the app is closed (td_api.tl: closeWebApp by the
    launch_id from openWebApp). }
  if FLaunchId <> 0 then begin
    A := TJSONObject.Create;
    A.Add('launch', IntToStr(FLaunchId));
    ServerCall('webapp.close', A, 0);
  end;
  if HandleAllocated then begin
    FrameDetach(Handle);
  end;
  FreeAndNil(FView);
  FreeAndNil(FTheme);
  FreeAndNil(FReqIds);
  if GForm = Self then begin
    GForm := nil;
  end;
  inherited Destroy;
end;

procedure TFormMiniApp.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
end;

function TFormMiniApp.CloseQuery: boolean;
begin
  Result := inherited CloseQuery;
  { web_app_setup_closing_behavior: the app asked for confirmation. }
  if Result and FNeedConfirm then begin
    Result := MessageDlg(Caption, 'Changes that you made may not be saved. Close anyway?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes;
  end;
end;

{ A mix of two RGB colours: APercent of the second one. System colours
  (clBtnFace and the like) do not mix — their values are not RGB. }
function MixColor(A, B: TColor; APercent: integer): TColor;
begin
  if (A and $FF000000 <> 0) or (B and $FF000000 <> 0) then begin
    Result := A;
    Exit;
  end;
  Result := RGBToColor(
    (Red(A) * (100 - APercent) + Red(B) * APercent) div 100,
    (Green(A) * (100 - APercent) + Green(B) * APercent) div 100,
    (Blue(A) * (100 - APercent) + Blue(B) * APercent) div 100);
end;

{ The header colours — from the theme the window gets anyway for
  theme_changed (the page's, light or dark): background — the app's
  background (secondary_bg_color), buttons — the surface (bg_color), text —
  text_color. Under the cursor a button mixes with the text at 12%, a
  pressed one at 20%. }
procedure TFormMiniApp.ApplyTheme;
var
  TextColor: TColor;
begin
  FBarColor := clBtnFace;
  FButtonColor := clWindow;
  TextColor := clWindowText;
  if FTheme <> nil then begin
    if HexColor(JStr(FTheme, 'secondary_bg_color')) <> clNone then begin
      FBarColor := HexColor(JStr(FTheme, 'secondary_bg_color'));
    end;
    if HexColor(JStr(FTheme, 'bg_color')) <> clNone then begin
      FButtonColor := HexColor(JStr(FTheme, 'bg_color'));
    end;
    if HexColor(JStr(FTheme, 'text_color')) <> clNone then begin
      TextColor := HexColor(JStr(FTheme, 'text_color'));
    end;
  end;
  FHoverColor := MixColor(FButtonColor, TextColor, 12);
  FPressColor := MixColor(FButtonColor, TextColor, 20);
  FTextColor := TextColor;
  FBar.Color := FBarColor;
  FBar.Font.Color := TextColor;
end;

{ One state of a button: a solid background, no border, text in the theme colour. }
procedure StyleState(AState: TBCButtonState; ABack, AText: TColor);
begin
  AState.Background.Style := bbsColor;
  AState.Background.Color := ABack;
  AState.Border.Style := bboNone;
  AState.FontEx.Color := AText;
  AState.FontEx.Shadow := False;
end;

function TFormMiniApp.MakeBarButton(const ACaption: string; AAlign: TAlign;
  AClick: TNotifyEvent): TBCButton;
var
  Bmp: TBitmap;
  W: integer;
begin
  Result := TBCButton.Create(Self);
  Result.Parent := FBar;
  Result.Align := AAlign;
  Result.Caption := ACaption;
  Result.Cursor := crHandPoint;
  Result.Rounding.RoundX := MINIAPP_BAR_BUTTON_RADIUS;
  Result.Rounding.RoundY := MINIAPP_BAR_BUTTON_RADIUS;
  StyleState(Result.StateNormal, FButtonColor, FTextColor);
  StyleState(Result.StateHover, FHoverColor, FTextColor);
  StyleState(Result.StateClicked, FPressColor, FTextColor);
  { 8px margins: top and bottom for all, on the left for the left button,
    on the right for the right ones (so it is exactly 8 both to the edge and
    between neighbours). }
  Result.BorderSpacing.Top := MINIAPP_BAR_PAD;
  Result.BorderSpacing.Bottom := MINIAPP_BAR_PAD;
  if AAlign = alLeft then begin
    Result.BorderSpacing.Left := MINIAPP_BAR_PAD;
  end else begin
    Result.BorderSpacing.Right := MINIAPP_BAR_PAD;
  end;
  { Width — by the text: the bitmap canvas measures without a window. }
  Bmp := TBitmap.Create;
  try
    Bmp.Canvas.Font.Assign(FBar.Font);
    W := Bmp.Canvas.TextWidth(ACaption);
  finally
    Bmp.Free;
  end;
  Result.Width := W + 2 * MINIAPP_BAR_BUTTON_PAD;
  Result.OnClick := AClick;
end;

procedure TFormMiniApp.HostResize(Sender: TObject);
begin
  if FView <> nil then begin
    FView.SetBounds(Rect(0, 0, FHost.ClientWidth, FHost.ClientHeight));
  end;
  SendViewport;
end;

procedure TFormMiniApp.Send(const AType: utf8string; AData: TJSONData);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('t', string(AType));
    if AData <> nil then begin
      O.Add('d', AData);
    end else begin
      O.Add('d', TJSONObject.Create);
    end;
    if FView <> nil then begin
      FView.PostJson(utf8string(O.AsJSON));
    end;
  finally
    O.Free;
  end;
end;

procedure TFormMiniApp.SendViewport;
var
  D: TJSONObject;
begin
  D := TJSONObject.Create;
  D.Add('height', FHost.ClientHeight);
  D.Add('width', FHost.ClientWidth);
  D.Add('is_expanded', True);
  D.Add('is_state_stable', True);
  Send('viewport_changed', D);
end;

procedure TFormMiniApp.ViewExternal(Sender: TObject; const AUri: utf8string);
begin
  { A new window the app asks for — into the browser, as from the main
    window. }
  OpenURL(string(AUri));
end;

procedure TFormMiniApp.BackClick(Sender: TObject);
begin
  Send('back_button_pressed', nil);
end;

procedure TFormMiniApp.SettingsClick(Sender: TObject);
begin
  Send('settings_button_pressed', nil);
end;

procedure TFormMiniApp.ReloadClick(Sender: TObject);
begin
  FView.Reload;
end;

procedure TFormMiniApp.MainClick(Sender: TObject);
begin
  if FMainBtn.Enabled then begin
    Send('main_button_pressed', nil);
  end;
end;

procedure TFormMiniApp.SecondClick(Sender: TObject);
begin
  if FSecondBtn.Enabled then begin
    Send('secondary_button_pressed', nil);
  end;
end;

{ web_app_setup_main_button / _secondary_button: is_visible, is_active,
  text, color, text_color, is_progress_visible. }
procedure TFormMiniApp.SetupButton(APanel: TPanel; AData: TJSONObject);
var
  C: TColor;
begin
  APanel.Visible := JBool(AData, 'is_visible') and (JStr(AData, 'text') <> '');
  APanel.Enabled := JBool(AData, 'is_active');
  if JBool(AData, 'is_progress_visible') then begin
    APanel.Caption := '…';
  end else begin
    APanel.Caption := JStr(AData, 'text');
  end;
  C := HexColor(JStr(AData, 'color'));
  if C <> clNone then begin
    APanel.Color := C;
  end;
  C := HexColor(JStr(AData, 'text_color'));
  if C <> clNone then begin
    APanel.Font.Color := C;
  end;
end;

{ web_app_open_popup: title, message, buttons (id, type, text). The answer —
  popup_closed with the button_id of the pressed one (empty — the window
  was closed). }
procedure TFormMiniApp.Popup(AData: TJSONObject);
var
  Dlg: TForm;
  Msg: TLabel;
  Row: TPanel;
  Btns: TJSONArray;
  B: TJSONObject;
  Btn: TButton;
  I, R: integer;
  T, BtnText: string;
  D: TJSONObject;
begin
  Dlg := TForm.CreateNew(nil);
  try
    Dlg.BorderStyle := bsDialog;
    Dlg.Position := poOwnerFormCenter;
    Dlg.Caption := JStr(AData, 'title');
    if Dlg.Caption = '' then begin
      Dlg.Caption := Caption;
    end;
    Dlg.Width := 340;
    Dlg.AutoSize := True;
    Msg := TLabel.Create(Dlg);
    Msg.Parent := Dlg;
    Msg.Align := alTop;
    Msg.WordWrap := True;
    Msg.BorderSpacing.Around := 12;
    Msg.Caption := JStr(AData, 'message');
    Row := TPanel.Create(Dlg);
    Row.Parent := Dlg;
    Row.Align := alTop;
    Row.BevelOuter := bvNone;
    Row.AutoSize := True;
    Row.BorderSpacing.Around := 8;
    Btns := nil;
    if (AData <> nil) and (AData.Find('buttons') is TJSONArray) then begin
      Btns := TJSONArray(AData.Find('buttons'));
    end;
    if (Btns = nil) or (Btns.Count = 0) then begin
      Btn := MakeButton(Dlg, Row, 'OK', alRight, nil);
      Btn.ModalResult := 1000;
    end else begin
      for I := Btns.Count - 1 downto 0 do begin
        if not (Btns.Items[I] is TJSONObject) then begin
          Continue;
        end;
        B := TJSONObject(Btns.Items[I]);
        T := JStr(B, 'type');
        if T = 'ok' then BtnText := 'OK'
        else if T = 'close' then BtnText := 'Close'
        else if T = 'cancel' then BtnText := 'Cancel'
        else BtnText := JStr(B, 'text');
        Btn := MakeButton(Dlg, Row, BtnText, alRight, nil);
        Btn.ModalResult := 1000 + I;
        Btn.BorderSpacing.Left := 6;
      end;
    end;
    { The frame in the theme colour, as the app itself (winframe). }
    FrameAttach(Dlg.Handle);
    try
      R := Dlg.ShowModal;
    finally
      FrameDetach(Dlg.Handle);
    end;
    D := TJSONObject.Create;
    if (Btns <> nil) and (R >= 1000) and (R - 1000 < Btns.Count)
       and (Btns.Items[R - 1000] is TJSONObject) then begin
      D.Add('button_id', JStr(TJSONObject(Btns.Items[R - 1000]), 'id'));
    end;
    Send('popup_closed', D);
  finally
    Dlg.Free;
  end;
end;

{ web_app_invoke_custom_method: req_id, method, params — the app's own
  methods at its bot (CloudStorage and the like): sendWebAppCustomRequest,
  the answer — custom_method_invoked with result (parsed JSON) or error. }
procedure TFormMiniApp.CustomMethod(AData: TJSONObject);
var
  A: TJSONObject;
  Params: string;
  Idx: integer;
begin
  Params := '{}';
  if (AData <> nil) and (AData.Find('params') <> nil) then begin
    Params := AData.Find('params').AsJSON;
  end;
  Idx := FReqIds.Add(JStr(AData, 'req_id'));
  A := TJSONObject.Create;
  A.Add('bot', IntToStr(FBotUserId));
  A.Add('method', JStr(AData, 'method'));
  A.Add('params', Params);
  ServerCall('webapp.custom', A, RequestId(REQ_CUSTOM, Idx));
end;

procedure TFormMiniApp.CustomDone(AIndex: integer; AOk: boolean; const AResult, AError: string);
var
  D: TJSONObject;
  Parsed: TJSONData;
begin
  if (AIndex < 0) or (AIndex >= FReqIds.Count) then begin
    Exit;
  end;
  D := TJSONObject.Create;
  D.Add('req_id', FReqIds[AIndex]);
  if AOk then begin
    Parsed := nil;
    try
      Parsed := GetJSON(AResult);
    except
      Parsed := nil;
    end;
    if Parsed <> nil then begin
      D.Add('result', Parsed);
    end else begin
      D.Add('result', TJSONNull.Create);
    end;
  end else begin
    D.Add('error', AError);
  end;
  Send('custom_method_invoked', D);
end;

{ web_app_request_write_access: ask the person; consent goes to Telegram
  (allowBotToSendMessages), the answer — write_access_requested. }
procedure TFormMiniApp.WriteAccess;
var
  A, D: TJSONObject;
begin
  if MessageDlg(Caption, 'Allow this bot to send you messages?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
    A := TJSONObject.Create;
    A.Add('bot', IntToStr(FBotUserId));
    ServerCall('webapp.allowWrite', A, RequestId(REQ_WRITE_ACCESS, 0));
    Exit;
  end;
  D := TJSONObject.Create;
  D.Add('status', 'cancelled');
  Send('write_access_requested', D);
end;

procedure TFormMiniApp.WriteAccessDone(AOk: boolean);
var
  D: TJSONObject;
begin
  D := TJSONObject.Create;
  if AOk then begin
    D.Add('status', 'allowed');
  end else begin
    D.Add('status', 'cancelled');
  end;
  Send('write_access_requested', D);
end;

{ The app's events — names per the telegram-web-app.js protocol.
  Everything not named is silently skipped: Telegram clients do the same
  with what they cannot do. }
procedure TFormMiniApp.HandleEvent(const AType: utf8string; AData: TJSONObject);
var
  D, A: TJSONObject;
  Url: string;
begin
  if AType = 'web_app_close' then begin
    FNeedConfirm := False;
    Close;
  end else if AType = 'web_app_request_theme' then begin
    D := TJSONObject.Create;
    if FTheme <> nil then begin
      D.Add('theme_params', FTheme.Clone);
    end;
    Send('theme_changed', D);
  end else if AType = 'web_app_request_viewport' then begin
    SendViewport;
  end else if (AType = 'web_app_request_safe_area') or (AType = 'web_app_request_content_safe_area') then begin
    D := TJSONObject.Create;
    D.Add('top', 0);
    D.Add('bottom', 0);
    D.Add('left', 0);
    D.Add('right', 0);
    if AType = 'web_app_request_safe_area' then begin
      Send('safe_area_changed', D);
    end else begin
      Send('content_safe_area_changed', D);
    end;
  end else if AType = 'web_app_setup_main_button' then begin
    SetupButton(FMainBtn, AData);
  end else if AType = 'web_app_setup_secondary_button' then begin
    SetupButton(FSecondBtn, AData);
  end else if AType = 'web_app_setup_back_button' then begin
    FBack.Visible := JBool(AData, 'is_visible');
  end else if AType = 'web_app_setup_settings_button' then begin
    FSettings.Visible := JBool(AData, 'is_visible');
  end else if AType = 'web_app_setup_closing_behavior' then begin
    FNeedConfirm := JBool(AData, 'need_confirmation');
  end else if AType = 'web_app_open_link' then begin
    Url := JStr(AData, 'url');
    if (Copy(LowerCase(Url), 1, 8) = 'https://') or (Copy(LowerCase(Url), 1, 7) = 'http://') then begin
      OpenURL(Url);
    end;
  end else if AType = 'web_app_open_tg_link' then begin
    { The page opens it — with the same parsing as a link in a message. }
    D := TJSONObject.Create;
    try
      D.Add('t', 'openLink');
      D.Add('url', 'https://t.me' + JStr(AData, 'path_full'));
      WebUiPostJson(utf8string(D.AsJSON));
    finally
      D.Free;
    end;
  end else if AType = 'web_app_open_popup' then begin
    Popup(AData);
  end else if AType = 'web_app_data_send' then begin
    { Only for an app from a keyboard button: the data goes to the bot, the
      window closes (td_api.tl: sendWebAppData). }
    if (FLaunchId = 0) and (FButtonText <> '') then begin
      A := TJSONObject.Create;
      A.Add('bot', IntToStr(FBotUserId));
      A.Add('buttonText', string(FButtonText));
      A.Add('data', JStr(AData, 'data'));
      ServerCall('webapp.sendData', A, 0);
      FNeedConfirm := False;
      Close;
    end;
  end else if AType = 'web_app_invoke_custom_method' then begin
    CustomMethod(AData);
  end else if AType = 'web_app_request_write_access' then begin
    WriteAccess;
  end else if AType = 'web_app_request_phone' then begin
    D := TJSONObject.Create;
    D.Add('status', 'cancelled');
    Send('phone_requested', D);
  end else if AType = 'web_app_read_text_from_clipboard' then begin
    { The clipboard is not given to the app. }
    D := TJSONObject.Create;
    D.Add('req_id', JStr(AData, 'req_id'));
    Send('clipboard_text_received', D);
  end else if AType = 'web_app_biometry_get_info' then begin
    D := TJSONObject.Create;
    D.Add('available', False);
    Send('biometry_info_received', D);
  end;
end;

procedure TFormMiniApp.ViewMessage(Sender: TObject; const AText: UnicodeString);
var
  Msg, Payload: TJSONData;
  T, DText: string;
begin
  Msg := nil;
  Payload := nil;
  try
    try
      Msg := GetJSON(string(AText));
    except
      Exit;
    end;
    if not (Msg is TJSONObject) then begin
      Exit;
    end;
    T := JStr(TJSONObject(Msg), 't');
    { d — a JSON string: that is how postEvent gives it (JSON.stringify). }
    DText := JStr(TJSONObject(Msg), 'd');
    if DText <> '' then begin
      try
        Payload := GetJSON(DText);
      except
        Payload := nil;
      end;
    end;
    if Payload is TJSONObject then begin
      HandleEvent(utf8string(T), TJSONObject(Payload));
    end else begin
      HandleEvent(utf8string(T), nil);
    end;
  finally
    Payload.Free;
    Msg.Free;
  end;
end;

{ ------------------------------------------------------------------ }

procedure CloseFormLater(AForm: TFormMiniApp);
begin
  AForm.FNeedConfirm := False;
  AForm.Release;
end;

procedure OpenMiniApp(const AUrl, ATitle: utf8string; ABotUserId, ALaunchId: Int64;
  const AButtonText: utf8string; AThemeParams: TJSONObject);
begin
  if GForm <> nil then begin
    CloseFormLater(GForm);
    GForm := nil;
  end;
  GForm := TFormMiniApp.CreateApp(AUrl, ATitle, ABotUserId, ALaunchId, AButtonText, AThemeParams);
  GForm.Show;
end;

end.
