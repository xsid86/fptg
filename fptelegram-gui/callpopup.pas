unit callpopup;

{ Окошко входящего звонка поверх всех окон — оболочка, не логика.

  Решает всё страница: главная (ui/call.js) видит входящий звонок при
  окне не на виду и просит хост показать карточку (сообщение
  callpopup с адресом страницы карточки); карточка (callcard.html) сама
  рисует кнопки и о нажатии сообщает хосту, а хост передаёт это главной
  странице, которая и принимает или отклоняет звонок — медиа живёт там.

  Отсюда платформенное только одно: маленькое окно без рамки, поверх
  всех, без кнопки на панели задач и без отбора фокуса, со своим
  WebView2. На другой оболочке (Linux, Android) это её окно с её
  веб-движком, а страницы те же.

  LCL — только как хозяин окна WebView2, как webui и miniapp. Показ —
  ShowWindow(SW_SHOWNOACTIVATE) и WS_EX_NOACTIVATE: обычный Show у LCL
  активирует окно и отнимает фокус у того, кто сейчас печатает
  (desknotify.pas, тот же вывод). }

{$mode objfpc}{$H+}

interface

{ Показать карточку с адресом AUrl (страница того же сервера, что и
  главная). Уже показана — сменить адрес, если другой. }
procedure CallPopupShow(const AUrl: utf8string);
procedure CallPopupHide;

implementation

uses
  Windows, Classes, SysUtils, Forms, Controls, LCLType, fpjson, jsonparser,
  constants, guiconst, desknotify, webview2, webui, winframe;

type
  TFormCallPopup = class(TForm)
  private
    FView: TWebView2;
    FUrl: utf8string;
    procedure ViewMessage(Sender: TObject; const AText: UnicodeString);
    procedure ViewCertificateError(Sender: TObject; const AUri, APem: utf8string;
      var AAllow: boolean);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Resize; override;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;
    procedure Present(const AUrl: utf8string);
    procedure Conceal;
  end;

var
  GPopup: TFormCallPopup = nil;

function Sc(AValue: integer): integer;
begin
  Result := MulDiv(AValue, Screen.PixelsPerInch, 96);
end;

constructor TFormCallPopup.CreateNew(AOwner: TComponent; Dummy: Integer);
begin
  inherited CreateNew(AOwner, Dummy);
  BorderStyle := bsNone;
  FormStyle := fsSystemStayOnTop;
  ShowInTaskBar := stNever;
  Caption := APP_TITLE;
  { Ширина — как у обычных уведомлений (desknotify): одна колонка. }
  Width := Sc(DESKNOTIFY_WIDTH);
  Height := Sc(CALLPOPUP_HEIGHT);
  FView := TWebView2.Create(Handle);
  { Заголовка нет (bsNone) — от темы ей достаются тёмный режим и кайма
    Windows 11 (winframe). }
  FrameAttach(Handle);
  { Карточка — тоже из файлов окна, аватарка — с сервера: тот же сайт и
    то же решение о сертификате, что у главного окна. }
  FView.MapVirtualHost(WEB_APP_HOST, utf8string(WebUiFolder));
  FView.OnCertificateError := @ViewCertificateError;
  FView.OnWebMessage := @ViewMessage;
end;

destructor TFormCallPopup.Destroy;
begin
  if HandleAllocated then begin
    FrameDetach(Handle);
  end;
  FreeAndNil(FView);
  if GPopup = Self then begin
    GPopup := nil;
  end;
  inherited Destroy;
end;

procedure TFormCallPopup.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  { Клик по карточке не активирует окно и не отбирает фокус; без
    кнопки на панели задач и в Alt+Tab. }
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW
    or WS_EX_TOPMOST;
end;

procedure TFormCallPopup.Resize;
begin
  inherited Resize;
  if FView <> nil then begin
    FView.SetBounds(Rect(0, 0, ClientWidth, ClientHeight));
  end;
end;

{ Место — угол уведомлений из настроек (DeskNotifyCorner, тот же,
  что у desknotify) с тем же отступом от края рабочей области.

  Позиция — SetWindowPos напрямую, не SetBounds: окно показано мимо LCL
  (ShowWindow), LCL считает его скрытым и свои координаты к нему не
  применяет — живой случай 2026-10-07: окошко вставало в левый верхний
  угол экрана. По той же причине WebView2 растягивается здесь же —
  Resize не придёт. }
procedure TFormCallPopup.Present(const AUrl: utf8string);
var
  Work: TRect;
  Code: string;
  X, Y, W, H: integer;
begin
  if AUrl <> FUrl then begin
    FUrl := AUrl;
    FView.Navigate(AUrl);
  end;
  W := Sc(DESKNOTIFY_WIDTH);
  H := Sc(CALLPOPUP_HEIGHT);
  Work := Screen.WorkAreaRect;
  Code := DESKNOTIFY_CORNERS[DeskNotifyCorner];
  if Code[1] = 't' then begin
    Y := Work.Top + Sc(DESKNOTIFY_MARGIN);
  end else begin
    Y := Work.Bottom - Sc(DESKNOTIFY_MARGIN) - H;
  end;
  if Code[2] = 'l' then begin
    X := Work.Left + Sc(DESKNOTIFY_MARGIN);
  end else begin
    X := Work.Right - Sc(DESKNOTIFY_MARGIN) - W;
  end;
  Windows.SetWindowPos(Handle, HWND_TOPMOST, X, Y, W, H,
    SWP_NOACTIVATE or SWP_SHOWWINDOW);
  FView.SetBounds(Rect(0, 0, W, H));
end;

procedure TFormCallPopup.Conceal;
begin
  Windows.ShowWindow(Handle, SW_HIDE);
  { Следующий звонок — заново: страница карточки держит id звонка. }
  FUrl := '';
  FView.Navigate('about:blank');
end;

{ От карточки: (t: 'call', action: accept | decline | open, id).
  accept и open поднимают главное окно; любое действие уходит главной
  странице как есть и прячет карточку. close — звонок перестал звонить. }
procedure TFormCallPopup.ViewCertificateError(Sender: TObject; const AUri, APem: utf8string;
  var AAllow: boolean);
begin
  AAllow := WebUiCertificateTrusted(AUri, APem);
end;

procedure TFormCallPopup.ViewMessage(Sender: TObject; const AText: UnicodeString);
var
  Data: TJSONData;
  O: TJSONObject;
  Act: string;
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
    if O.Get('t', '') <> 'call' then begin
      Exit;
    end;
    Act := O.Get('action', '');
    if (Act = 'accept') or (Act = 'open') then begin
      WebUiReveal;
    end;
    if Act <> 'close' then begin
      WebUiPostJson(utf8string(O.AsJSON));
    end;
    Conceal;
  finally
    Data.Free;
  end;
end;

procedure CallPopupShow(const AUrl: utf8string);
begin
  if GPopup = nil then begin
    GPopup := TFormCallPopup.CreateNew(nil);
  end;
  GPopup.Present(AUrl);
end;

procedure CallPopupHide;
begin
  if GPopup <> nil then begin
    GPopup.Conceal;
  end;
end;

finalization
  FreeAndNil(GPopup);
end.
