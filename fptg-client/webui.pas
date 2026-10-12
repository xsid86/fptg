unit webui;

{ The window that hosts the web UI in an embedded Edge (WebView2)
  instead of handing the URL to whatever the default browser is.

  Built in code rather than from a .lfm because there is nothing to
  design: the whole client area belongs to a native child window owned
  by the WebView2 runtime, and no LCL control ever sits on it.

  Окно — отдельная программа от сервера (fptg-server) и о TDLib не
  знает ничего. Страница — из своих файлов окна (папка web как сайт
  https://WEB_APP_HOST/, WebView2 SetVirtualHostNameToFolderMapping), к
  серверу она ходит сама: вход логином и паролем (connect.html), дальше
  JWT (core/session.js). Окно хранит адрес, refresh-токен сеанса и
  отпечаток сертификата сервера (conf.dat, guiconn.pas) и решает о
  самоподписанном сертификате: пускает, только если отпечаток тот, которому
  человек доверился. Всё прочее, что окну нужно от сервера, — через
  страницу (ui/shell.js): настройки, карточки на рабочем столе,
  мини-приложения, окошко звонка. }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Classes, Forms, Controls, Dialogs, LCLIntf, ExtCtrls,
  Menus, fpjson,
  constants, guiconst, guiconn, webview2;

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
    { Настройка сервера (Settings → General), её присылает страница. }
    FCloseToTray: boolean;
    { Сохранённое подключение (conf.dat). }
    FAddr: TServerAddress;
    { Сертификат, о котором последний раз спросили человека, и тот, которому
      он доверился в окне ввода, — до входа он ещё не сохранён. }
    FAskedOrigin, FAskedPrint: string;
    FTrustOrigin, FTrustPrint: string;

    procedure TrayShowClick(Sender: TObject);
    procedure TrayQuitClick(Sender: TObject);
    procedure TrayDblClick(Sender: TObject);
    procedure TrayConnectionClick(Sender: TObject);
    procedure TraySignOutClick(Sender: TObject);
    procedure CardClick(AChatId: Int64);
    procedure ShowConnectPage(const AError: string);
    procedure ShowApp;
    procedure PostToPage(O: TJSONObject);
    procedure ViewCertificateError(Sender: TObject; const AUri, APem: utf8string;
      var AAllow: boolean);
    procedure HandlePageMessage(O: TJSONObject);
    procedure ViewExternalUri(Sender: TObject; const AUri: utf8string);
    procedure ViewDownloadStart(Sender: TObject; const AUri: utf8string; var AOpen: boolean);
    procedure ViewDownloadDone(Sender: TObject; const APath: utf8string; AOk: boolean);
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
    { По сохранённому сеансу — сразу приложение, без него — окно входа. }
    procedure ConnectSaved;
    { Пустить ли самоподписанный сертификат сервера (и в окошке звонка). }
    function CertificateTrusted(const AUri, APem: utf8string): boolean;
    { Builds the tray icon. Called once, by SetWebUiPrimary. }
    procedure SetupTray;
    { Показать окно и вывести вперёд — как двойной клик по трею. }
    procedure Reveal;
    { Команда второго запуска (instance.pas): show — показать окно. }
    function InstanceCommand(const ACmd: string; AArgs: TJSONObject): TJSONObject;
    { Is the user actually looking at this window? Visible is not
      enough - a window behind three others is as unseen as a hidden
      one, and that is exactly when a notification has to leave the
      page and become a system one. }
    function IsShowing: boolean;
    { F11, and the page's own fullscreen, both end up here. }
    procedure SetFullScreen(AOn: boolean);
    property FullScreen: boolean read FFullScreen;
  end;

{ Создаёт окно и подключается к серверу (сохранённое подключение или
  окно ввода). False — нет WebView2: что сказать, решает вызывающий. }
function StartWebUi: boolean;

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

{ Сообщение главной странице (chrome.webview, событие message): нажатие
  на окошке звонка, запрос мини-приложения, клик по карточке. }
procedure WebUiPostJson(const AJson: utf8string);
{ Решение о сертификате сервера — для других окон WebView2 (окошко
  звонка грузит аватарку с сервера). }
function WebUiCertificateTrusted(const AUri, APem: utf8string): boolean;
{ Папка страницы окна (web рядом с exe). }
function WebUiFolder: string;

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
  jsonparser, base64, sha256u, callpopup, desknotify, miniapp, winframe;

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

function WebUiCertificateTrusted(const AUri, APem: utf8string): boolean;
begin
  Result := (GForm <> nil) and GForm.CertificateTrusted(AUri, APem);
end;

function WebUiFolder: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + GUI_WEB_DIR;
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
  { Рамка в цвет темы — сразу, по запомненному: страница пришлёт свои
    цвета только после загрузки. }
  FrameAttach(Handle);
  { Страница — из своих файлов: https://WEB_APP_HOST/ (до первой
    навигации). }
  FView.MapVirtualHost(WEB_APP_HOST, utf8string(WebUiFolder));
  FView.OnCertificateError := @ViewCertificateError;
  FView.OnExternalUri := @ViewExternalUri;
  FView.OnDownloadStart := @ViewDownloadStart;
  FView.OnDownloadDone := @ViewDownloadDone;
  FView.OnUnavailable := @ViewUnavailable;
  FView.OnAcceleratorKey := @ViewAcceleratorKey;
  FView.OnFullScreenElement := @ViewFullScreenElement;
  FView.OnWebMessage := @ViewMessage;
  DeskNotifyOnClick := @CardClick;
end;

{ data:…;base64,XXXX -> байты; всё прочее — пусто. }
function DataUriBytes(const AUri: string): RawByteString;
var
  P: integer;
begin
  Result := '';
  P := Pos(',', AUri);
  if (Copy(AUri, 1, 5) = 'data:') and (P > 0) and (Pos(';base64', Copy(AUri, 1, P)) > 0) then begin
    Result := DecodeStringBase64(Copy(AUri, P + 1, MaxInt));
  end;
end;

function CornerIndex(const ACode: string): integer;
var
  I: integer;
begin
  Result := DESKNOTIFY_CORNER_DEFAULT;
  for I := Low(DESKNOTIFY_CORNERS) to High(DESKNOTIFY_CORNERS) do begin
    if DESKNOTIFY_CORNERS[I] = ACode then begin
      Result := I;
    end;
  end;
end;

{ Просьбы страницы к оболочке (chrome.webview.postMessage, JSON-строка).
  Протокол — ui/shell.js; окно входа — connect.js. Решает
  страница, оболочка только исполняет — на другой платформе это делает
  своя оболочка. }
procedure TFormWebUi.ViewMessage(Sender: TObject; const AText: UnicodeString);
var
  Data: TJSONData;
begin
  try
    Data := GetJSON(UTF8Encode(AText));
  except
    Exit;
  end;
  try
    if Data is TJSONObject then begin
      HandlePageMessage(TJSONObject(Data));
    end;
  finally
    Data.Free;
  end;
end;

procedure TFormWebUi.HandlePageMessage(O: TJSONObject);
var
  T, Origin: string;
  N, Res: TJSONObject;
begin
  T := O.Get('t', '');
  if T = 'callpopup' then begin
    if O.Get('show', False) then begin
      CallPopupShow(utf8string(O.Get('url', '')));
    end else begin
      CallPopupHide;
    end;
  end else if T = 'trustCert' then begin
    { Только тот сертификат, о котором окно само спросило. }
    if (O.Get('origin', '') = FAskedOrigin) and (O.Get('fingerprint', '') = FAskedPrint)
       and (FAskedPrint <> '') then begin
      FTrustOrigin := FAskedOrigin;
      FTrustPrint := FAskedPrint;
    end;
  end else if T = 'session' then begin
    { Вход удался (connect.js): запомнить и открыть приложение. }
    Origin := LowerCase(ServerOrigin(FAddr));
    FAddr.Host := O.Get('host', '');
    FAddr.Port := O.Get('port', 0);
    FAddr.User := O.Get('user', '');
    FAddr.Refresh := O.Get('refresh', '');
    { Отпечаток: которому доверились сейчас; сервер тот же — прежний;
      другой сервер без вопроса о сертификате (подписан центром) — нет. }
    if LowerCase(ServerOrigin(FAddr)) = FTrustOrigin then begin
      FAddr.Fingerprint := FTrustPrint;
    end else if LowerCase(ServerOrigin(FAddr)) <> Origin then begin
      FAddr.Fingerprint := '';
    end;
    SaveServerAddress(FAddr);
    ShowApp;
  end else if T = 'signedOut' then begin
    { Сеанс кончился (выход, или сервер его не знает): refresh забыть,
      адрес и отпечаток — оставить. }
    FAddr.Refresh := '';
    SaveServerAddress(FAddr);
    ShowConnectPage(O.Get('error', ''));
  end else if T = 'config' then begin
    FCloseToTray := O.Get('closeToTray', False);
    if O.Find('notify') is TJSONObject then begin
      N := TJSONObject(O.Find('notify'));
      SetDeskNotifyCorner(CornerIndex(N.Get('corner', '')));
      SetDeskNotifyLimit(N.Get('limit', DESKNOTIFY_LIMIT_DEFAULT));
      SetDeskNotifyFonts(N.Get('titleFont', DESKNOTIFY_TITLE_FONT_DEFAULT),
        N.Get('textFont', DESKNOTIFY_TEXT_FONT_DEFAULT));
    end;
  end else if T = 'frame' then begin
    FrameFromPage(O);
  end else if T = 'notify' then begin
    ShowDeskNotify(O.Get('chatId', Int64(0)), utf8string(O.Get('title', '')),
      utf8string(O.Get('text', '')), DataUriBytes(O.Get('photo', '')),
      DataUriBytes(O.Get('thumb', '')));
  end else if T = 'notifySample' then begin
    ShowDeskNotifySamples(APP_TITLE, DESKNOTIFY_SAMPLE_TEXT);
  end else if T = 'miniapp' then begin
    { theme переходит во владение окна мини-приложения. }
    if O.Find('theme') is TJSONObject then begin
      Res := TJSONObject(O.Find('theme').Clone);
    end else begin
      Res := TJSONObject.Create;
    end;
    OpenMiniApp(utf8string(O.Get('url', '')), utf8string(O.Get('title', '')),
      StrToInt64Def(O.Get('bot', ''), 0), StrToInt64Def(O.Get('launch', ''), 0),
      utf8string(O.Get('buttonText', '')), Res);
  end else if T = 'miniappResp' then begin
    Res := nil;
    if O.Find('result') is TJSONObject then begin
      Res := TJSONObject(O.Find('result'));
    end;
    MiniAppResponse(O.Get('id', Int64(0)), O.Get('ok', False), Res, O.Get('error', ''));
  end;
end;

{ Клик по карточке на рабочем столе: окно вперёд, чат открывает
  страница (выбор чата живёт в ней). 0 — образец из настроек. }
procedure TFormWebUi.CardClick(AChatId: Int64);
var
  O: TJSONObject;
begin
  Reveal;
  if AChatId = 0 then begin
    Exit;
  end;
  O := TJSONObject.Create;
  try
    O.Add('t', 'openChat');
    O.Add('chatId', AChatId);
    FView.PostJson(utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

procedure TFormWebUi.PostToPage(O: TJSONObject);
begin
  FView.PostJson(utf8string(O.AsJSON));
end;

{ Окно входа — с тем, куда входили, и с причиной, почему не вышло. }
procedure TFormWebUi.ShowConnectPage(const AError: string);
var
  Url: string;
begin
  Url := WEB_APP_ORIGIN + '/' + CONNECT_PAGE
    + '?host=' + UrlEncode(FAddr.Host)
    + '&user=' + UrlEncode(FAddr.User)
    + '&error=' + UrlEncode(AError);
  if FAddr.Port > 0 then begin
    Url := Url + '&port=' + IntToStr(FAddr.Port);
  end;
  FView.Navigate(utf8string(Url));
end;

{ Приложение: адрес сервера — параметром, refresh-токен — во фрагменте
  (#): фрагмент не уходит ни в один запрос, страница забирает его и
  стирает из адреса (core/session.js). }
procedure TFormWebUi.ShowApp;
begin
  FView.Navigate(utf8string(WEB_APP_ORIGIN + '/index.html?server='
    + UrlEncode(ServerOrigin(FAddr)) + '#r=' + UrlEncode(FAddr.Refresh)));
end;

procedure TFormWebUi.ConnectSaved;
begin
  if not LoadServerAddress(FAddr) then begin
    FAddr.Host := LOCAL_SERVER_BIND;
    FAddr.Port := LOCAL_SERVER_PORT;
  end;
  if FAddr.Refresh <> '' then begin
    ShowApp;
  end else begin
    ShowConnectPage('');
  end;
end;

{ PEM -> DER (первый блок). }
function PemDer(const APem: string): RawByteString;
var
  A, B: integer;
begin
  Result := '';
  A := Pos('-----BEGIN ', APem);
  if A = 0 then begin
    Exit;
  end;
  A := Pos(#10, APem, A);
  B := Pos('-----END ', APem, A);
  if (A = 0) or (B = 0) then begin
    Exit;
  end;
  Result := DecodeStringBase64(StringReplace(StringReplace(Copy(APem, A + 1, B - A - 1),
    #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]));
end;

{ https://адрес:порт из полного адреса запроса. }
function UriOrigin(const AUri: string): string;
var
  P, Q: integer;
begin
  Result := LowerCase(AUri);
  P := Pos('://', Result);
  if P = 0 then begin
    Exit;
  end;
  Q := Pos('/', Result, P + 3);
  if Q > 0 then begin
    Result := Copy(Result, 1, Q - 1);
  end;
end;

function TFormWebUi.CertificateTrusted(const AUri, APem: utf8string): boolean;
var
  Origin, Print: string;
begin
  Origin := UriOrigin(string(AUri));
  Print := DigestColonHex(Sha256(PemDer(string(APem))));
  Result := ((Origin = LowerCase(ServerOrigin(FAddr))) and (FAddr.Fingerprint <> '')
      and (Print = FAddr.Fingerprint))
    or ((Origin = FTrustOrigin) and (Print = FTrustPrint));
  if not Result then begin
    FAskedOrigin := Origin;
    FAskedPrint := Print;
  end;
end;

{ Самоподписанный сертификат сервера. Знакомый — пустить; незнакомый
  (или сменившийся!) — отказать и спросить человека в окне входа: он
  сверит отпечаток с тем, что напечатал сервер. }
procedure TFormWebUi.ViewCertificateError(Sender: TObject; const AUri, APem: utf8string;
  var AAllow: boolean);
var
  O: TJSONObject;
begin
  AAllow := CertificateTrusted(AUri, APem);
  if AAllow then begin
    Exit;
  end;
  O := TJSONObject.Create;
  try
    O.Add('t', 'certificate');
    O.Add('origin', FAskedOrigin);
    O.Add('fingerprint', FAskedPrint);
    { Этому серверу уже доверяли с другим отпечатком — сертификат
      сменился: страница предупредит громче. }
    O.Add('changed', (FAskedOrigin = LowerCase(ServerOrigin(FAddr)))
      and (FAddr.Fingerprint <> ''));
    PostToPage(O);
  finally
    O.Free;
  end;
end;

procedure TFormWebUi.TrayConnectionClick(Sender: TObject);
begin
  Reveal;
  ShowConnectPage('');
end;

{ Выход: страница сообщит серверу и вернёт signedOut. }
procedure TFormWebUi.TraySignOutClick(Sender: TObject);
var
  O: TJSONObject;
begin
  Reveal;
  O := TJSONObject.Create;
  try
    O.Add('t', 'signOut');
    PostToPage(O);
  finally
    O.Free;
  end;
end;

destructor TFormWebUi.Destroy;
begin
  DeskNotifyOnClick := nil;
  if HandleAllocated then begin
    FrameDetach(Handle);
  end;
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
  if AUrl <> '' then begin
    FView.Navigate(AUrl);
  end;
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

{ Файл из сообщения: страница ведёт на /media/…?save=имя&open=1 (ui/message.js),
  сервер отдаёт вложением, WebView2 начинает загрузку. Такую окно забирает
  себе — без своего окна загрузок — и готовый файл открывает системным
  приложением: иначе PDF и подобное открывались внутри окна, и из него
  не было пути назад. Прочие загрузки («Save as…») — как обычно. }
procedure TFormWebUi.ViewDownloadStart(Sender: TObject; const AUri: utf8string;
  var AOpen: boolean);
var
  Q: string;
begin
  Q := string(AUri);
  if Pos('?', Q) = 0 then begin
    Exit;
  end;
  Q := '&' + Copy(Q, Pos('?', Q) + 1, MaxInt) + '&';
  AOpen := Pos('&open=1&', Q) > 0;
end;

procedure TFormWebUi.ViewDownloadDone(Sender: TObject; const APath: utf8string; AOk: boolean);
var
  O: TJSONObject;
begin
  if AOk and (APath <> '') then begin
    OpenDocument(string(APath));
    Exit;
  end;
  O := TJSONObject.Create;
  try
    O.Add('t', 'downloadFailed');
    PostToPage(O);
  finally
    O.Free;
  end;
end;

procedure TFormWebUi.ViewUnavailable(Sender: TObject; const AMessage: string);
begin
  if FFailed then begin
    Exit;                  { one complaint per window, not one per retry }
  end;
  FFailed := True;
  MessageDlg(APP_TITLE,
    AMessage + LineEnding + LineEnding
    + 'The Microsoft Edge WebView2 Runtime is needed to show the '
    + 'interface in this window. Until it is installed, open the '
    + 'web interface link the server prints in any browser instead.',
    mtError, [mbOK], 0);
  Close;
end;


{ Может ли окно закрыться. TDLib — у сервера, закрывать тут нечего:
  сервер живёт своей жизнью и после окна. }
function TFormWebUi.CloseQuery: boolean;
begin
  Result := inherited CloseQuery;
  if (not Result) or (not GPrimary) then begin
    Exit;
  end;
  { The close button with close-to-tray on: out of sight, still
    running. Quit from the tray is what actually ends it. Значение —
    последнее, что прислала страница (настройки меняются на ходу). }
  if (not FQuitting) and (FTray <> nil) and FCloseToTray then begin
    Result := False;
    Hide;
  end;
end;

procedure TFormWebUi.DoClose(var CloseAction: TCloseAction);
begin
  inherited DoClose(CloseAction);
  { Kept alive and hidden: rebuilding the runtime for every open would
    throw away the page state and cost a visible pause. }
  CloseAction := caHide;
  { Unless this window is the application - see SetWebUiPrimary. There
    is no main form to close in that case, so nothing else would ever
    end the message loop. Only reached once CloseQuery has agreed. }
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
  Item.Caption := 'Connection...';
  Item.OnClick := @TrayConnectionClick;
  Pop.Items.Add(Item);

  Item := TMenuItem.Create(Pop);
  Item.Caption := 'Sign out';
  Item.OnClick := @TraySignOutClick;
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

function TFormWebUi.InstanceCommand(const ACmd: string; AArgs: TJSONObject): TJSONObject;
begin
  Result := nil;
  if ACmd = 'show' then begin
    Reveal;
  end else begin
    raise Exception.Create('Unknown command: ' + ACmd);
  end;
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

function StartWebUi: boolean;
begin
  Result := WebView2Available;
  if not Result then begin
    Exit;
  end;
  if GForm = nil then begin
    GForm := TFormWebUi.CreateNew(Application);
  end;
  GForm.Open('');
  GForm.ConnectSaved;
end;

end.
