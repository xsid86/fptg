unit webauth;

{$mode objfpc}{$H+}

{ What the web UI needs to draw the sign-in flow.

  The flow itself is not here and never will be: TTdAuth (tdauth.pas)
  is the state machine, it is UI-free already, and both windows drive
  the SAME one. This unit only watches - every step of the flow
  announces itself through ITdAuthListener, and each announcement
  carries information that exists nowhere else afterwards (which
  number the code went to, what the password hint is, the QR link).
  TTdAuth fires those once and keeps none of them, because the native
  form drew them the moment they arrived.

  A page cannot work that way: it reloads, it connects late, it asks
  again. So the last announcement for each state is kept here, and
  StateJson hands the page whatever the CURRENT state needs. That is
  the whole job.

  Commands go the other way without passing through here at all: the
  page's answers reach TTdAuth directly (webapi.pas), because they are
  answers to a question this unit only reported. }

interface

uses
  Classes, SysUtils, fpjson,
  tdauth, tdsession;

type
  TWebAuthEvent = procedure(Sender: TObject) of object;

  TWebAuth = class(TComponent, ITdAuthListener, ITdStateListener)
  private
    FSession: ITdSession;
    FState: TTdAuthState;

    { The last announcement for each step. Each is only meaningful in
      its own state; StateJson is what decides which to send. }
    FQrLink: utf8string;
    FCode: TTdCodeInfo;
    FPassHint, FPassRecovery: utf8string;
    FPassHasRecovery: boolean;
    FEmailPattern: utf8string;
    FEmailLength: integer;
    FAllowApple, FAllowGoogle: boolean;
    FTosText: utf8string;
    FMinAge: integer;
    FShowTosPopup: boolean;
    FRecoveryEmail: utf8string;
    { The last refusal - a wrong code, a wrong password. Cleared the
      moment the state moves on, so a stale complaint cannot outlive
      the step it belonged to. }
    FError: utf8string;

    FOnChanged: TWebAuthEvent;
    procedure Touch;
  public
    constructor Create(AOwner: TComponent); reintroduce;
    destructor Destroy; override;

    { Follows whichever account is active. Binding to the one already
      bound does nothing; binding to another drops the old
      subscription first. }
    procedure Bind(const ASession: ITdSession);

    { Everything the page needs to draw the step it is on. Always
      carries the state; the rest depends on which state that is. }
    function StateJson: TJSONObject;

    { The account being watched, so the caller can reach its TTdAuth to
      send an answer back. Nil when there is no account yet. }
    property Session: ITdSession read FSession;
    property State: TTdAuthState read FState;
    property OnChanged: TWebAuthEvent read FOnChanged write FOnChanged;

    { ITdAuthListener }
    procedure TdNeedPhoneOrQr;
    procedure TdQrLink(const ALink: utf8string);
    procedure TdNeedCode(const AInfo: TTdCodeInfo);
    procedure TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
    procedure TdNeedEmailCode(const APattern: utf8string; ALength: integer);
    procedure TdNeedPassword(const AHint, ARecoveryPattern: utf8string;
      AHasRecovery: boolean);
    procedure TdPasswordRecovery(const AEmailPattern: utf8string);
    procedure TdNeedRegistration(const ATosText: utf8string;
      AShowPopup: boolean; AMinAge: integer);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
  end;

{ The state as the page names it. Deliberately not the Pascal
  identifier: the page switches on these, and renaming an enum member
  here should not silently blank a screen there. }
function AuthStateStr(AState: TTdAuthState): utf8string;

implementation

function AuthStateStr(AState: TTdAuthState): utf8string;
begin
  case AState of
    tasWaitTdlibParameters:        Result := 'parameters';
    tasWaitPhoneNumber:            Result := 'phone';
    tasWaitOtherDeviceConfirmation: Result := 'qr';
    tasWaitEmailAddress:           Result := 'emailAddress';
    tasWaitEmailCode:              Result := 'emailCode';
    tasWaitCode:                   Result := 'code';
    tasWaitRegistration:           Result := 'registration';
    tasWaitPassword:               Result := 'password';
    tasReady:                      Result := 'ready';
    tasLoggingOut:                 Result := 'loggingOut';
    tasClosing:                    Result := 'closing';
    tasClosed:                     Result := 'closed';
  else
    Result := 'none';
  end;
end;

{ Where the code was sent, in the page's words. The native form says
  the same things in its own labels; both read this enum rather than
  guessing from the phone pattern. }
function DeliveryStr(ADelivery: TTdCodeDelivery): utf8string;
begin
  case ADelivery of
    tcdTelegramMessage:  Result := 'app';
    tcdSms:              Result := 'sms';
    tcdSmsWord:          Result := 'smsWord';
    tcdSmsPhrase:        Result := 'smsPhrase';
    tcdCall:             Result := 'call';
    tcdFlashCall:        Result := 'flashCall';
    tcdMissedCall:       Result := 'missedCall';
    tcdFragment:         Result := 'fragment';
    tcdFirebaseAndroid,
    tcdFirebaseIos:      Result := 'firebase';
  else
    Result := '';
  end;
end;

constructor TWebAuth.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FState := tasNone;
end;

destructor TWebAuth.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  inherited Destroy;
end;

procedure TWebAuth.Bind(const ASession: ITdSession);
begin
  if FSession = ASession then begin
    Exit;
  end;
  TdSessionUnsubscribe(FSession, Self);
  FSession := ASession;
  if FSession = nil then begin
    FState := tasNone;
    Touch;
    Exit;
  end;
  FSession.Subscribe(Self);
  { The state may have moved before this bound - pull the current one
    rather than wait for a change that has already happened. Same
    reason TFormLogin.AttachTo does it. }
  TdStateChanged(FSession.State);
end;

procedure TWebAuth.Touch;
begin
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

function TWebAuth.StateJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('state', string(AuthStateStr(FState)));
  if FError <> '' then begin
    Result.Add('error', string(FError));
  end;

  case FState of
    tasWaitPhoneNumber: begin
      { The QR link is offered alongside the phone box rather than as
        a state of its own: TDLib only moves to
        tasWaitOtherDeviceConfirmation once the link exists, and until
        then the page still has a number to ask for. }
      Result.Add('qrLink', string(FQrLink));
    end;
    tasWaitOtherDeviceConfirmation: begin
      Result.Add('qrLink', string(FQrLink));
    end;
    tasWaitCode: begin
      Result.Add('phone', string(FCode.PhonePattern));
      Result.Add('delivery', string(DeliveryStr(FCode.Delivery)));
      Result.Add('length', FCode.CodeLength);
      Result.Add('hint', string(FCode.Hint));
      Result.Add('nextDelivery', string(DeliveryStr(FCode.NextDelivery)));
      Result.Add('timeout', FCode.Timeout);
    end;
    tasWaitEmailAddress: begin
      Result.Add('allowApple', FAllowApple);
      Result.Add('allowGoogle', FAllowGoogle);
    end;
    tasWaitEmailCode: begin
      Result.Add('email', string(FEmailPattern));
      Result.Add('length', FEmailLength);
    end;
    tasWaitPassword: begin
      Result.Add('hint', string(FPassHint));
      Result.Add('hasRecovery', FPassHasRecovery);
      Result.Add('recoveryPattern', string(FPassRecovery));
      { Non-empty only once a recovery code has actually been sent. }
      Result.Add('recoverySent', string(FRecoveryEmail));
    end;
    tasWaitRegistration: begin
      Result.Add('tos', string(FTosText));
      Result.Add('tosPopup', FShowTosPopup);
      Result.Add('minAge', FMinAge);
    end;
  end;
end;

{ ---------------- ITdAuthListener ---------------- }

procedure TWebAuth.TdNeedPhoneOrQr;
begin
  FQrLink := '';
  Touch;
end;

procedure TWebAuth.TdQrLink(const ALink: utf8string);
begin
  FQrLink := ALink;
  Touch;
end;

procedure TWebAuth.TdNeedCode(const AInfo: TTdCodeInfo);
begin
  FCode := AInfo;
  Touch;
end;

procedure TWebAuth.TdNeedEmailAddress(AAllowApple, AAllowGoogle: boolean);
begin
  FAllowApple := AAllowApple;
  FAllowGoogle := AAllowGoogle;
  Touch;
end;

procedure TWebAuth.TdNeedEmailCode(const APattern: utf8string; ALength: integer);
begin
  FEmailPattern := APattern;
  FEmailLength := ALength;
  Touch;
end;

procedure TWebAuth.TdNeedPassword(const AHint, ARecoveryPattern: utf8string;
  AHasRecovery: boolean);
begin
  FPassHint := AHint;
  FPassRecovery := ARecoveryPattern;
  FPassHasRecovery := AHasRecovery;
  FRecoveryEmail := '';
  Touch;
end;

procedure TWebAuth.TdPasswordRecovery(const AEmailPattern: utf8string);
begin
  FRecoveryEmail := AEmailPattern;
  Touch;
end;

procedure TWebAuth.TdNeedRegistration(const ATosText: utf8string;
  AShowPopup: boolean; AMinAge: integer);
begin
  FTosText := ATosText;
  FShowTosPopup := AShowPopup;
  FMinAge := AMinAge;
  Touch;
end;

{ ---------------- ITdStateListener ---------------- }

procedure TWebAuth.TdStateChanged(AState: TTdAuthState);
begin
  if FState = AState then begin
    Exit;
  end;
  FState := AState;
  { A refusal belongs to the step it was refused on. Moving on clears
    it, or the next screen would open already complaining about the
    previous one. }
  FError := '';
  Touch;
end;

procedure TWebAuth.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Kept as text rather than as a code: the page shows it, and TDLib's
    messages ("PHONE_CODE_INVALID") are the same ones every other
    client shows. }
  FError := AMessage;
  Touch;
end;

end.
