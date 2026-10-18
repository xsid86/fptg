unit callpopup;

{ The incoming call pop-up above all windows — a shell, not logic.

  The page decides everything: the main one (ui/call.js) sees an incoming
  call while the window is not in view and asks the host to show the card
  (a callpopup message with the card page's address); the card
  (callcard.html) draws its buttons itself and tells the host about a
  press, and the host passes it on to the main page, which accepts or
  declines the call — the media live there.

  Only one thing here is platform-specific: a small borderless window
  above all others, without a taskbar button and without stealing focus,
  with its own WebView2. On another shell (Linux, Android) it is that
  shell's window with its web engine, and the pages are the same.

  LCL — only as the host of the WebView2 window, like webui and miniapp.
  Showing — ShowWindow(SW_SHOWNOACTIVATE) and WS_EX_NOACTIVATE: LCL's
  ordinary Show activates the window and takes focus from whoever is
  typing (desknotify.pas, the same conclusion). }

{$mode objfpc}{$H+}

interface

{ Show the card with the address AUrl (a page of the same server as the
  main one). Shown already — change the address if it differs. }
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
  { Width — as ordinary notifications (desknotify): one column. }
  Width := Sc(DESKNOTIFY_WIDTH);
  Height := Sc(CALLPOPUP_HEIGHT);
  FView := TWebView2.Create(Handle);
  { There is no title bar (bsNone) — from the theme it gets the dark mode
    and the Windows 11 border (winframe). }
  FrameAttach(Handle);
  { The card is from the window's files too, the avatar from the server:
    the same site and the same certificate decision as the main window. }
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
  { A click on the card does not activate the window or take focus; no
    button on the taskbar or in Alt+Tab. }
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

{ The place — the notification corner from the settings (DeskNotifyCorner,
  the same as desknotify's) with the same margin from the edge of the work
  area.

  The position — SetWindowPos directly, not SetBounds: the window is shown
  past LCL (ShowWindow), LCL considers it hidden and does not apply its
  coordinates — a live case on 2026-10-07: the pop-up went to the top
  left corner of the screen. For the same reason WebView2 is stretched
  right here — Resize will not come. }
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
  { The next call — from scratch: the card page keeps the call id. }
  FUrl := '';
  FView.Navigate('about:blank');
end;

{ From the card: (t: 'call', action: accept | decline | open, id). accept
  and open bring up the main window; any action goes to the main page as
  is and hides the card. close — the call stopped ringing. }
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
