unit login;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, StdCtrls, ExtCtrls, Graphics,
  Clipbrd, tdauth, tdcore, qrrender, main;

type
  TUiMode = (umNone, umPhone, umQr, umCode, umEmailAddr, umEmailCode,
    umPassword, umRecovery, umRegister);

  { TFormLogin

    ITdStateListener перечислен явно, хотя ITdAuthListener от него наследует:
    QueryInterface ищет GUID только среди интерфейсов, названных в объявлении
    класса, — интерфейсы-предки туда автоматически не попадают. }

  TFormLogin = class(TForm, ITdStateListener, ITdAuthListener)
    lblState:   TLabel;
    lblPrompt:  TLabel;
    lblPrompt2: TLabel;
    edtInput:   TEdit;
    edtInput2:  TEdit;
    btnOk:      TButton;
    btnAlt:     TButton;
    imgQr:      TImage;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure btnOkClick(Sender: TObject);
    procedure btnAltClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FMode:   TUiMode;
    FQrLink: utf8string;
    procedure SetMode(AMode: TUiMode; const APrompt: string; const APrompt2: string = ''; const AAlt: string = '');
    procedure RecenterOnScreen;
  public
    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string);
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
  TdApp.Subscribe(Self);
  Position := poScreenCenter;
end;

procedure TFormLogin.FormDestroy(Sender: TObject);
begin
  TdUnsubscribe(Self);
end;

procedure TFormLogin.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  CanClose := False;
  { Закрытие формы входа до авторизации = выход из приложения.
    Рукопожатие с TDLib целиком живёт в главной форме. }
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

  { QR показывается только в umQr — рисуется отдельно в TdQrLink }
  imgQr.Visible := False;

  if edtInput.Visible and edtInput.CanFocus then begin
    edtInput.SetFocus;
  end;
  FormResize(nil);
end;

procedure TFormLogin.RecenterOnScreen;
begin
  { poScreenCenter срабатывает однократно при первом показе.
    Форма меняет размер по ходу флоу, поэтому центрируем сами.
    WorkArea, а не Screen.Width/Height — чтобы учесть панель задач. }
  FormLogin.AutoSize := False;
  SetBounds(
    Screen.WorkAreaLeft + (Screen.WorkAreaWidth - Width) div 2,
    Screen.WorkAreaTop + (Screen.WorkAreaHeight - Height) div 2,
    Width, Height);
  FormLogin.AutoSize := True;
end;

{ ---------------- ITdUpdateListener ---------------- }

procedure TFormLogin.TdUpdate(const AJson: utf8string);
begin

end;

{ ---------------- ITdStateListener ---------------- }

procedure TFormLogin.TdStateChanged(AState: TTdAuthState);
begin
  lblState.Caption := 'Состояние: ' + AuthStateToStr(AState);

  if TdIsPromptState(AState) then begin
    if not Visible then begin
      Show;
    end;
  end else
  if AState = tasReady then begin
    if Visible then begin
      Hide;
    end;
  end else
  if TdIsShuttingState(AState) and not TdApp.ShuttingDown then begin
    { Выход из аккаунта: держим окно, иначе на пару секунд
      на экране не останется ни одной формы и это выглядит как вылет. }
    SetMode(umNone, '');
    lblState.Caption := 'Выход из аккаунта...';
    if not Visible then begin
      Show;
    end;
  end;
end;

procedure TFormLogin.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Состояние при ошибке ввода не меняется — TDLib просто ждёт
    корректное значение. Поле оставляем активным. }
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
  SetMode(umPhone, 'Номер телефона (в формате +71234567890):', '', 'Войти по QR');
end;

procedure TFormLogin.TdQrLink(const ALink: utf8string);
var
  Bmp: TBitmap;
begin
  FQrLink := ALink;
  SetMode(umQr, '', '', 'Скопировать ссылку');

  { TDLib перевыдаёт токен по таймеру и вызывает этот обработчик
    повторно — картинку надо перерисовывать каждый раз. }
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
  S := 'Код подтверждения';
  if AInfo.CodeLength > 0 then begin
    S := S + ' (' + IntToStr(AInfo.CodeLength) + ' знаков)';
  end;
  S := S + ':';

  if AInfo.NextDelivery <> tcdUnknown then begin
    Alt := 'Повторить (' + CodeDeliveryToStr(AInfo.NextDelivery) + ')';
  end else begin
    Alt := '';
  end;

  SetMode(umCode, S, '', Alt);
  FormResize(nil);
end;

procedure TFormLogin.TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
begin
  SetMode(umEmailAddr, 'Адрес e-mail:');
end;

procedure TFormLogin.TdNeedEmailCode(const APattern: utf8string; ALength: integer);
begin
  SetMode(umEmailCode, 'Код из письма (' + string(APattern) + '):');
end;

procedure TFormLogin.TdNeedPassword(const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
var
  S, Alt: string;
begin
  S := 'Пароль двухфакторной защиты';
  if AHint <> '' then begin
    S := S + ' (подсказка: ' + string(AHint) + ')';
  end;
  S := S + ':';

  if AHasRecovery then begin
    Alt := 'Забыли пароль?';
  end else begin
    Alt := '';
  end;

  SetMode(umPassword, S, '', Alt);
  edtInput.PasswordChar := '*';
end;

procedure TFormLogin.TdPasswordRecovery(const AEmailPattern: utf8string);
begin
  SetMode(umRecovery,
    'Код восстановления из письма (' + string(AEmailPattern) + '):',
    'Новый пароль:');
  edtInput2.PasswordChar := '*';
end;

procedure TFormLogin.TdNeedRegistration(const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
begin
  if ATosText <> '' then begin
    if AShowPopup then begin
      MessageDlg('Условия использования', string(ATosText), mtInformation, [mbOK], 0);
    end;
  end;
  SetMode(umRegister, 'Имя:', 'Фамилия:');
end;

{ ---------------- кнопки ---------------- }

procedure TFormLogin.btnOkClick(Sender: TObject);
var
  V1, V2: utf8string;
begin
  V1 := utf8string(edtInput.Text);
  V2 := utf8string(edtInput2.Text);

  case FMode of
    umPhone: begin
      TdApp.Auth.SubmitPhone(V1);
    end;
    umCode: begin
      TdApp.Auth.SubmitCode(V1);
    end;
    umEmailAddr: begin
      TdApp.Auth.SubmitEmailAddress(V1);
    end;
    umEmailCode: begin
      TdApp.Auth.SubmitEmailCode(V1);
    end;
    umPassword: begin
      TdApp.Auth.SubmitPassword(V1);
    end;
    umRecovery: begin
      TdApp.Auth.SubmitRecoveryCode(V1, V2, '');
    end;
    umRegister: begin
      TdApp.Auth.SubmitRegistration(V1, V2);
    end;
  end;
end;

procedure TFormLogin.btnAltClick(Sender: TObject);
begin
  case FMode of
    umPhone: begin
      TdApp.Auth.RequestQr;
    end;
    umQr: begin
      Clipboard.AsText := string(FQrLink);
    end;
    umCode: begin
      TdApp.Auth.ResendCode;
    end;
    umPassword: begin
      TdApp.Auth.RequestPasswordRecovery;
    end;
  end;
end;

procedure TFormLogin.FormResize(Sender: TObject);
begin
  RecenterOnScreen;
end;

end.
