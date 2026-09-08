unit login;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, StdCtrls, ExtCtrls, Graphics,
  Clipbrd, Buttons, tdauth, tdcore, qrrender, main;

type
  TUiMode = (umNone, umPhone, umQr, umCode, umEmailAddr, umEmailCode,
    umPassword, umRecovery, umRegister);

  { TFormLogin

    ITdStateListener is listed explicitly even though ITdAuthListener
    inherits from it: QueryInterface only looks for a GUID among the
    interfaces named in the class declaration — ancestor interfaces
    are not included automatically. }

  TFormLogin = class(TForm, ITdStateListener, ITdAuthListener)
    btnAlt:     TBitBtn;
    lblState:   TLabel;
    lblPrompt:  TLabel;
    lblPrompt2: TLabel;
    edtInput:   TEdit;
    edtInput2:  TEdit;
    btnOk:      TButton;
    imgQr:      TImage;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure btnOkClick(Sender: TObject);
    procedure btnAltClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    { The form targets a SPECIFIC account, not the "active" one.
      While adding a second account, the first stays active, so
      tracking the active account would be wrong here. }
    FSession: ITdSession;
    FAddMode: boolean;   { add-account mode: modal dialog }
    FSucceeded: boolean; { sign-in completed successfully }
    FMode:   TUiMode;
    FQrLink: utf8string;
    procedure SetMode(AMode: TUiMode; const APrompt: string; const APrompt2: string = ''; const AAlt: string = '');
    function  Auth: TTdAuth;
    procedure RecenterOnScreen;
  public
    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;

    { Attaches to an account. AAddMode = True is the add-account
      dialog: closing it cancels the addition rather than quitting
      the app. }
    procedure AttachTo(const ASession: ITdSession; AAddMode: boolean);
    procedure Detach;

    property Session: ITdSession read FSession;
    property AddMode: boolean read FAddMode;
    property Succeeded: boolean read FSucceeded;

    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
    { ITdAuthListener }
    procedure TdNeedPhoneOrQr;
    procedure TdQrLink(const ALink: utf8string);
    procedure TdNeedCode(const AInfo: TTdCodeInfo);
    procedure TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
    procedure TdNeedEmailCode(const APattern: utf8string; ALength: integer);
    procedure TdNeedPassword(const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
    procedure TdPasswordRecovery(const AEmailPattern: utf8string);
    procedure TdNeedRegistration(const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
  end;

var
  FormLogin: TFormLogin;

implementation

{$R *.lfm}

{ TFormLogin }

procedure TFormLogin.FormCreate(Sender: TObject);
begin
  SetMode(umNone, '');
  { No subscription here: the target is assigned externally via
    AttachTo. }
  Position := poScreenCenter;
end;

procedure TFormLogin.FormDestroy(Sender: TObject);
begin
  Detach;
end;

procedure TFormLogin.TdActiveChanged(ANew: TTdAccount);
begin
  { The startup form follows the active account. The add-account
    dialog is pinned to its target and ignores this switch. }
  if not FAddMode then begin
    AttachTo(ANew, False);
  end;
end;

procedure TFormLogin.TdAccountsChanged;
begin
  { The set of accounts doesn't matter to the login form. }
end;

procedure TFormLogin.AttachTo(const ASession: ITdSession; AAddMode: boolean);
begin
  if FSession = ASession then begin
    FAddMode := AAddMode;
    Exit;
  end;
  Detach;
  FSession := ASession;
  FAddMode := AAddMode;
  FSucceeded := False;
  if FSession <> nil then begin
    FSession.Subscribe(Self);
    { The state may have already changed before attaching — pull the
      current one. }
    TdStateChanged(FSession.State);
  end;
end;

procedure TFormLogin.Detach;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
end;

function TFormLogin.Auth: TTdAuth;
begin
  if FSession <> nil then begin
    Result := FSession.Auth;
  end else begin
    Result := nil;
  end;
end;

procedure TFormLogin.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if FAddMode then begin
    { Add-account dialog: closing cancels the addition, not the app.
      A successful sign-in closes the window itself by setting
      FSucceeded. }
    CanClose := True;
    Exit;
  end;

  CanClose := False;
  { Closing the startup login form before authorization means quitting
    the app. The TDLib handshake lives entirely in the main form. }
  FormMain.RequestAppClose;
end;

procedure TFormLogin.SetMode(AMode: TUiMode; const APrompt: string; const APrompt2: string; const AAlt: string);
begin
  FMode := AMode;

  lblPrompt.Caption := APrompt;
  lblPrompt.Visible := APrompt <> '';
  edtInput.Visible := APrompt <> '';
  edtInput.Text := '';
  edtInput.PasswordChar := #0;

  lblPrompt2.Caption := APrompt2;
  lblPrompt2.Visible := APrompt2 <> '';
  edtInput2.Visible := APrompt2 <> '';
  edtInput2.Text := '';
  edtInput2.PasswordChar := #0;

  btnOk.Visible  := APrompt <> '';
  btnAlt.Caption := AAlt;
  btnAlt.Visible := AAlt <> '';

  { The QR code shows only in umQr — drawn separately in TdQrLink }
  imgQr.Visible := False;
  if (FMode = umQr) or (FMode = umPhone) then begin
    btnAlt.ImageIndex := 6;
  end else begin
    btnAlt.ImageIndex := -1;
  end;

  if edtInput.Visible and edtInput.CanFocus then begin
    edtInput.SetFocus;
  end;
  FormResize(nil);
end;

procedure TFormLogin.RecenterOnScreen;
begin
  { poScreenCenter only applies once, on first show. The form resizes
    as the flow progresses, so it is recentered here manually.
    WorkArea, not Screen.Width/Height, accounts for the taskbar. }
  FormLogin.AutoSize := False;
  SetBounds(
    Screen.WorkAreaLeft + (Screen.WorkAreaWidth - Width) div 2,
    Screen.WorkAreaTop + (Screen.WorkAreaHeight - Height) div 2,
    Width, Height);
  FormLogin.AutoSize := True;
end;

{ ---------------- ITdStateListener ---------------- }

procedure TFormLogin.TdStateChanged(AState: TTdAuthState);
begin
  lblState.Caption := 'State: ' + AuthStateToStr(AState);

  if AState = tasReady then begin
    FSucceeded := True;
    if FAddMode then begin
      { The added account's sign-in is complete — close the modal
        dialog. }
      ModalResult := mrOk;
    end else if Visible then begin
      Hide;
    end;
    Exit;
  end;

  if TdIsPromptState(AState) then begin
    if not Visible then begin
      Show;
    end;
  end else
  if FAddMode then begin
    { In the add-account dialog, intermediate states are just shown. }
  end else
  if TdIsShuttingState(AState) and not TdApp.ShuttingDown then begin
    { Logging out: keep the window up, otherwise no form is on screen
      for a couple of seconds and it looks like a crash. }
    SetMode(umNone, '');
    lblState.Caption := 'Logging out...';
    if not Visible then begin
      Show;
    end;
  end;
end;

procedure TFormLogin.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Errors are shown in the status line, otherwise a stuck state
    (e.g. a locked database during setTdlibParameters) looks like a
    silent hang. }
  lblState.Caption := Format('Error %d: %s', [ACode, string(AMessage)]);

  { The state does not change on an input error — TDLib is just
    waiting for a valid value. Keep the field active. }
  if edtInput.Visible then begin
    edtInput.SelectAll;
    if edtInput.CanFocus then begin
      edtInput.SetFocus;
    end;
  end;
end;

{ ---------------- ITdAuthListener ---------------- }

procedure TFormLogin.TdNeedPhoneOrQr;
begin
  SetMode(umPhone, 'Phone number (e.g. +71234567890):', '', 'Sign in with QR');
end;

procedure TFormLogin.TdQrLink(const ALink: utf8string);
var
  Bmp: TBitmap;
begin
  FQrLink := ALink;
  SetMode(umQr, '', '', 'Copy link');

  { TDLib reissues the token on a timer and calls this handler again
    — the image must be redrawn every time. }
  Bmp := TBitmap.Create;
  try
    if DrawQrToBitmap(ALink, Bmp, imgQr.Width) > 0 then begin
      imgQr.Picture.Assign(Bmp);
      imgQr.Visible := True;
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TFormLogin.TdNeedCode(const AInfo: TTdCodeInfo);
var
  S, Alt: string;
begin
  S := 'Confirmation code';
  if AInfo.CodeLength > 0 then begin
    S := S + ' (' + IntToStr(AInfo.CodeLength) + ' digits)';
  end;
  S := S + ':';

  if AInfo.NextDelivery <> tcdUnknown then begin
    Alt := 'Resend (' + CodeDeliveryToStr(AInfo.NextDelivery) + ')';
  end else begin
    Alt := '';
  end;

  SetMode(umCode, S, '', Alt);
  FormResize(nil);
end;

procedure TFormLogin.TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
begin
  SetMode(umEmailAddr, 'E-mail address:');
end;

procedure TFormLogin.TdNeedEmailCode(const APattern: utf8string; ALength: integer);
begin
  SetMode(umEmailCode, 'Code from e-mail (' + string(APattern) + '):');
end;

procedure TFormLogin.TdNeedPassword(const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
var
  S, Alt: string;
begin
  S := 'Two-factor password';
  if AHint <> '' then begin
    S := S + ' (hint: ' + string(AHint) + ')';
  end;
  S := S + ':';

  if AHasRecovery then begin
    Alt := 'Forgot password?';
  end else begin
    Alt := '';
  end;

  SetMode(umPassword, S, '', Alt);
  edtInput.PasswordChar := '*';
end;

procedure TFormLogin.TdPasswordRecovery(const AEmailPattern: utf8string);
begin
  SetMode(umRecovery,
    'Recovery code from e-mail (' + string(AEmailPattern) + '):',
    'New password:');
  edtInput2.PasswordChar := '*';
end;

procedure TFormLogin.TdNeedRegistration(const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
begin
  if ATosText <> '' then begin
    if AShowPopup then begin
      MessageDlg('Terms of Service', string(ATosText), mtInformation, [mbOK], 0);
    end;
  end;
  SetMode(umRegister, 'First name:', 'Last name:');
end;

{ ---------------- buttons ---------------- }

procedure TFormLogin.btnOkClick(Sender: TObject);
var
  V1, V2: utf8string;
begin
  V1 := utf8string(edtInput.Text);
  V2 := utf8string(edtInput2.Text);

  if Auth = nil then begin
    Exit;
  end;

  case FMode of
    umPhone: begin
      Auth.SubmitPhone(V1);
    end;
    umCode: begin
      Auth.SubmitCode(V1);
    end;
    umEmailAddr: begin
      Auth.SubmitEmailAddress(V1);
    end;
    umEmailCode: begin
      Auth.SubmitEmailCode(V1);
    end;
    umPassword: begin
      Auth.SubmitPassword(V1);
    end;
    umRecovery: begin
      Auth.SubmitRecoveryCode(V1, V2, '');
    end;
    umRegister: begin
      Auth.SubmitRegistration(V1, V2);
    end;
  end;
end;

procedure TFormLogin.btnAltClick(Sender: TObject);
begin
  if Auth = nil then begin
    Exit;
  end;

  case FMode of
    umPhone: begin
      Auth.RequestQr;
    end;
    umQr: begin
      Clipboard.AsText := string(FQrLink);
    end;
    umCode: begin
      Auth.ResendCode;
    end;
    umPassword: begin
      Auth.RequestPasswordRecovery;
    end;
  end;
end;

procedure TFormLogin.FormResize(Sender: TObject);
begin
  RecenterOnScreen;
end;

end.
