unit miniapp;

{ Окно мини-приложения бота (Telegram Mini App / Web App).

  ОТДЕЛЬНОЕ ОКНО WebView2, А НЕ <iframe> В СТРАНИЦЕ — и это проверено,
  а не выбрано: самые ходовые приложения запрещают показ во фрейме
  чужого сайта. walletbot.me отдаёт frame-ancestors 'self'
  https://web.telegram.org, webappinternal.telegram.org (BotFather) —
  X-Frame-Options: ALLOW-FROM https://web.telegram.org. Во фрейме
  страницы с 127.0.0.1 они были бы пустыми. В своём окне приложение
  открывается обычной страницей, без фрейма — так же делает Telegram
  Desktop.

  МОСТ — window.TelegramWebviewProxy: telegram-web-app.js, найдя этот
  объект, шлёт через него каждое событие (postEvent(тип, JSON-строка)),
  а события от клиента принимает через Telegram.WebView.receiveEvent.
  Объект подкладывает стартовый скрипт (BRIDGE_JS) до скриптов самой
  страницы; он переправляет события в chrome.webview.postMessage, а
  ответы этого окна (PostJson) — в receiveEvent.

  Запросы к TDLib (свои методы приложения — CloudStorage и т.п., права
  писать пользователю, данные кнопки клавиатуры) идут на сервер через
  главную страницу: окно — в другом процессе, чем TDLib, и, может быть,
  на другой машине. Окно шлёт странице (t: miniappReq, id, cmd, args),
  она — команду серверу (webapp.custom и т.д.), ответ возвращается
  (t: miniappResp) в MiniAppResponse. В id — серийный номер окна:
  ответ уже закрытому окну не достаётся новому.

  Окно одно: новое приложение заменяет открытое. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, StdCtrls, Graphics, Dialogs,
  LCLIntf, LCLType, fpjson, jsonparser, BCButton, BCTypes;

{ Открывает приложение (или заменяет открытое). ALaunchId — из
  openWebApp, 0 для приложения с кнопки клавиатуры (getWebAppUrl);
  AButtonText — текст этой кнопки, нужен sendWebAppData. AThemeParams —
  theme_params для события theme_changed; переходит во владение окна. }
procedure OpenMiniApp(const AUrl, ATitle: utf8string; ABotUserId, ALaunchId: Int64;
  const AButtonText: utf8string; AThemeParams: TJSONObject);

{ Ответ сервера на запрос окна (страница передала t: miniappResp).
  AResult — объект ответа команды или nil; не забирается. }
procedure MiniAppResponse(AId: Int64; AOk: boolean; AResult: TJSONObject;
  const AError: string);

implementation

uses
  constants, guiconst, webview2, webui;

const
  { Вид запроса в id (см. MiniAppResponse). }
  REQ_CUSTOM = 1;
  REQ_WRITE_ACCESS = 2;

  { Только в главном документе: во фреймах chrome.webview нет. }
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
    { TBCButton (BGRAControls), а не TButton: системную кнопку Windows
      рисует темой, и её цвет из LCL не задать, — а шапка должна быть в
      цветах темы приложения (светлой или тёмной), со скруглением. }
    FBack: TBCButton;
    FSettings: TBCButton;
    FReload: TBCButton;
    FBarColor: TColor;      { фон шапки }
    FButtonColor: TColor;   { фон кнопок }
    FHoverColor: TColor;    { фон кнопки под курсором }
    FPressColor: TColor;    { фон нажатой кнопки }
    FTextColor: TColor;
    FMainBtn: TPanel;
    FSecondBtn: TPanel;
    FReqIds: TStringList;     { req_id приложения по индексу запроса к серверу }
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

{ Команда серверу через главную страницу. AArgs забирается. AId = 0 —
  ответ не нужен. }
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

{ id запроса: (серийный номер окна shl 20) or (вид shl 16) or индекс. }
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

{ '#rrggbb' -> TColor (BGR); clNone для всего остального. }
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
  { Над главным окном и без своей кнопки на панели задач: владелец —
    главное веб-окно. ДО первого Handle — владелец входит в параметры
    создания окна. }
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

  { Снизу вверх: главная кнопка у самого края, дополнительная над ней. }
  FMainBtn := MakeAppButton(Self, Self, @MainClick);
  FSecondBtn := MakeAppButton(Self, Self, @SecondClick);

  FHost := TPanel.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  FHost.BevelOuter := bvNone;
  FHost.OnResize := @HostResize;

  FView := TWebView2.Create(FHost.Handle);
  FView.StartupScript := UnicodeString(BRIDGE_JS);
  FView.OnWebMessage := @ViewMessage;
  FView.OnExternalUri := @ViewExternal;
  FView.Navigate(AUrl);
end;

destructor TFormMiniApp.Destroy;
var
  A: TJSONObject;
begin
  { Telegram должен знать, что приложение закрыто (td_api.tl:
    closeWebApp по launch_id из openWebApp). }
  if FLaunchId <> 0 then begin
    A := TJSONObject.Create;
    A.Add('launch', IntToStr(FLaunchId));
    ServerCall('webapp.close', A, 0);
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
  { web_app_setup_closing_behavior: приложение просило подтверждать. }
  if Result and FNeedConfirm then begin
    Result := MessageDlg(Caption, 'Changes that you made may not be saved. Close anyway?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes;
  end;
end;

{ Смесь двух цветов RGB: APercent второго. Системные (clBtnFace и т.п.)
  не смешиваются — их значения не RGB. }
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

{ Цвета шапки — из темы, которую окно и так получило для theme_changed
  (страница, светлая или тёмная): фон — фон приложения
  (secondary_bg_color), кнопки — поверхность (bg_color), текст —
  text_color. Под курсором кнопка смешивается с текстом на 12%, нажатая —
  на 20%. }
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

{ Одно состояние кнопки: сплошной фон, без рамки, текст цвета темы. }
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
  { Отступы 8px: сверху и снизу у всех, у левой кнопки — слева, у правых
    — справа (так и до края, и между соседями ровно 8). }
  Result.BorderSpacing.Top := MINIAPP_BAR_PAD;
  Result.BorderSpacing.Bottom := MINIAPP_BAR_PAD;
  if AAlign = alLeft then begin
    Result.BorderSpacing.Left := MINIAPP_BAR_PAD;
  end else begin
    Result.BorderSpacing.Right := MINIAPP_BAR_PAD;
  end;
  { Ширина — по тексту: холст битмапа меряет без окна. }
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
  { Новое окно, о котором просит приложение, — в браузер, как и из
    главного окна. }
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

{ web_app_open_popup: title, message, buttons (id, type, text). Ответ —
  popup_closed с button_id нажатой (пустой — окно закрыли). }
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
    R := Dlg.ShowModal;
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

{ web_app_invoke_custom_method: req_id, method, params — свои методы
  приложения у его бота (CloudStorage и т.п.): sendWebAppCustomRequest,
  ответ — custom_method_invoked с result (разобранный JSON) или error. }
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

{ web_app_request_write_access: спросить человека; согласие — Telegram
  (allowBotToSendMessages), ответ — write_access_requested. }
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

{ События приложения — имена по протоколу telegram-web-app.js. Всё, что
  не названо, молча пропускается: так поступают и клиенты Telegram с
  тем, чего не умеют. }
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
    { Открывает страница — тем же разбором, что ссылку в сообщении. }
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
    { Только у приложения с кнопки клавиатуры: данные уходят боту, окно
      закрывается (td_api.tl: sendWebAppData). }
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
    { Буфер обмена приложению не отдаётся. }
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
    { d — JSON-строка: так её отдаёт postEvent (JSON.stringify). }
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
