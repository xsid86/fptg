unit tdauth;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, tdclient;

type
  TTdAuthState = (
    tasNone,
    tasWaitTdlibParameters,
    tasWaitPhoneNumber,
    tasWaitOtherDeviceConfirmation,
    tasWaitEmailAddress,
    tasWaitEmailCode,
    tasWaitCode,
    tasWaitRegistration,
    tasWaitPassword,
    tasReady,
    tasLoggingOut,
    tasClosing,
    tasClosed
    );

  { Куда именно Telegram отправил код подтверждения. }
  TTdCodeDelivery = (
    tcdUnknown,
    tcdTelegramMessage,   // в другой активный клиент
    tcdSms,
    tcdSmsWord,           // код = первое слово SMS
    tcdSmsPhrase,         // код = первая фраза SMS
    tcdCall,              // голосовой звонок, код продиктуют
    tcdFlashCall,         // код в номере звонящего
    tcdMissedCall,        // код в последних цифрах номера
    tcdFragment,
    tcdFirebaseAndroid,
    tcdFirebaseIos
    );

  TTdCodeInfo = record
    PhonePattern: utf8string;      // маска номера, например +7 *** *** 12 34
    Delivery: TTdCodeDelivery;
    CodeLength: integer;
    Hint:    utf8string;           // first_word / first_phrase / префикс номера
    NextDelivery: TTdCodeDelivery; // чем повторить, tcdUnknown = повтор недоступен
    Timeout: integer;              // секунд до разрешённого resend
  end;

  TTdAuthStateEvent = procedure(Sender: TObject; AState: TTdAuthState) of object;
  TTdQrLinkEvent = procedure(Sender: TObject; const ALink: utf8string) of object;
  TTdCodeEvent = procedure(Sender: TObject; const AInfo: TTdCodeInfo) of object;
  TTdEmailCodeEvent = procedure(Sender: TObject; const APattern: utf8string; ALength: integer) of object;
  TTdEmailAddrEvent = procedure(Sender: TObject; AAllowApple, AAllowGoogle: boolean) of object;
  TTdPasswordEvent = procedure(Sender: TObject; const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean) of object;
  TTdRecoveryEvent = procedure(Sender: TObject; const AEmailPattern: utf8string) of object;
  TTdRegistrationEvent = procedure(Sender: TObject; const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer) of object;
  TTdAuthErrorEvent = procedure(Sender: TObject; ACode: integer; const AMessage, AContext: utf8string) of object;

  TTdAuth = class
  private
    FClient:   TTdClient;
    FState:    TTdAuthState;
    FExtraSeq: integer;
    FPending:  TStringList;          // '<extra>' = '<method>'
    FSavedUpdate: TTdUpdateEvent;

    FApiId:     integer;
    FApiHash:   utf8string;
    FDatabaseDir: utf8string;
    FFilesDir:  utf8string;
    FSystemLanguageCode: utf8string;
    FDeviceModel: utf8string;
    FSystemVersion: utf8string;
    FApplicationVersion: utf8string;
    FUseTestDc: boolean;
    FUseMessageDatabase: boolean;
    FUseChatInfoDatabase: boolean;
    FUseFileDatabase: boolean;
    FUseSecretChats: boolean;

    FOnStateChanged: TTdAuthStateEvent;
    FOnNeedPhoneOrQr: TNotifyEvent;
    FOnQrLink:   TTdQrLinkEvent;
    FOnNeedCode: TTdCodeEvent;
    FOnNeedEmailAddress: TTdEmailAddrEvent;
    FOnNeedEmailCode: TTdEmailCodeEvent;
    FOnNeedPassword: TTdPasswordEvent;
    FOnPasswordRecovery: TTdRecoveryEvent;
    FOnNeedRegistration: TTdRegistrationEvent;
    FOnReady:    TNotifyEvent;
    FOnClosed:   TNotifyEvent;
    FOnError:    TTdAuthErrorEvent;

    procedure ClientUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
    procedure ProcessAuthState(AObj: TJSONObject);
    procedure ProcessError(AObj: TJSONObject);
    procedure SetState(AState: TTdAuthState);
    procedure SendAuth(const AMethod, ABody: utf8string);
    procedure SendTdlibParameters;
    function TakePending(const AExtra: utf8string): utf8string;
  public
    constructor Create(AClient: TTdClient);
    destructor Destroy; override;

    { Ответы автомату }
    procedure SubmitPhone(const APhone: utf8string);
    procedure RequestQr;
    procedure SubmitCode(const ACode: utf8string);
    procedure ResendCode;
    procedure SubmitEmailAddress(const AEmail: utf8string);
    procedure SubmitEmailCode(const ACode: utf8string);
    procedure SubmitPassword(const APassword: utf8string);
    procedure RequestPasswordRecovery;
    procedure SubmitRecoveryCode(const ACode, ANewPassword, ANewHint: utf8string);
    procedure SubmitRegistration(const AFirstName, ALastName: utf8string);

    procedure LogOut;
    procedure Close;

    property State: TTdAuthState read FState;

    property ApiId: integer read FApiId write FApiId;
    property ApiHash: utf8string read FApiHash write FApiHash;
    property DatabaseDir: utf8string read FDatabaseDir write FDatabaseDir;
    property FilesDir: utf8string read FFilesDir write FFilesDir;
    property SystemLanguageCode: utf8string read FSystemLanguageCode write FSystemLanguageCode;
    property DeviceModel: utf8string read FDeviceModel write FDeviceModel;
    property SystemVersion: utf8string read FSystemVersion write FSystemVersion;
    property ApplicationVersion: utf8string read FApplicationVersion write FApplicationVersion;
    property UseTestDc: boolean read FUseTestDc write FUseTestDc;
    property UseMessageDatabase: boolean read FUseMessageDatabase write FUseMessageDatabase;
    property UseChatInfoDatabase: boolean read FUseChatInfoDatabase write FUseChatInfoDatabase;
    property UseFileDatabase: boolean read FUseFileDatabase write FUseFileDatabase;
    property UseSecretChats: boolean read FUseSecretChats write FUseSecretChats;

    property OnStateChanged: TTdAuthStateEvent read FOnStateChanged write FOnStateChanged;
    property OnNeedPhoneOrQr: TNotifyEvent read FOnNeedPhoneOrQr write FOnNeedPhoneOrQr;
    property OnQrLink: TTdQrLinkEvent read FOnQrLink write FOnQrLink;
    property OnNeedCode: TTdCodeEvent read FOnNeedCode write FOnNeedCode;
    property OnNeedEmailAddress: TTdEmailAddrEvent read FOnNeedEmailAddress write FOnNeedEmailAddress;
    property OnNeedEmailCode: TTdEmailCodeEvent read FOnNeedEmailCode write FOnNeedEmailCode;
    property OnNeedPassword: TTdPasswordEvent read FOnNeedPassword write FOnNeedPassword;
    property OnPasswordRecovery: TTdRecoveryEvent read FOnPasswordRecovery write FOnPasswordRecovery;
    property OnNeedRegistration: TTdRegistrationEvent read FOnNeedRegistration write FOnNeedRegistration;
    property OnReady: TNotifyEvent read FOnReady write FOnReady;
    property OnClosed: TNotifyEvent read FOnClosed write FOnClosed;
    property OnError: TTdAuthErrorEvent read FOnError write FOnError;
  end;

function JsonEsc(const S: utf8string): utf8string;
function AuthStateToStr(AState: TTdAuthState): string;
function CodeDeliveryToStr(ADelivery: TTdCodeDelivery): string;

implementation

const
  MAX_PENDING = 32;

  { ---------------- утилиты ---------------- }

function JsonEsc(const S: utf8string): utf8string;
var
  I: integer;
  C: ansichar;
begin
  Result := '';
  for I := 1 to System.Length(S) do begin
    C := S[I];
    case C of
      '"': begin
        Result := Result + '\"';
      end;
      '\': begin
        Result := Result + '\\';
      end;
      #8: begin
        Result := Result + '\b';
      end;
      #9: begin
        Result := Result + '\t';
      end;
      #10: begin
        Result := Result + '\n';
      end;
      #12: begin
        Result := Result + '\f';
      end;
      #13: begin
        Result := Result + '\r';
      end;
      else
      begin
        if C < #32 then begin
          Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4));
        end else begin
          Result := Result + C;
        end;
      end;   { байты UTF-8 >= #128 проходят как есть }
    end;
  end;
end;

function JBool(AValue: boolean): utf8string;
begin
  if AValue then begin
    Result := 'true';
  end else begin
    Result := 'false';
  end;
end;

function ObjStr(AObj: TJSONObject; const AName: string): utf8string;
var
  D: TJSONData;
begin
  Result := '';
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtString) then begin
    Result := utf8string(D.AsString);
  end;
end;

function ObjInt(AObj: TJSONObject; const AName: string): integer;
var
  D: TJSONData;
begin
  Result := 0;
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtNumber) then begin
    Result := D.AsInteger;
  end;
end;

function ObjBool(AObj: TJSONObject; const AName: string): boolean;
var
  D: TJSONData;
begin
  Result := False;
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtBoolean) then begin
    Result := D.AsBoolean;
  end;
end;

function ObjObj(AObj: TJSONObject; const AName: string): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtObject) then begin
    Result := TJSONObject(D);
  end;
end;

function AuthStateFromString(const S: utf8string): TTdAuthState;
begin
  if S = 'authorizationStateWaitTdlibParameters' then begin
    Result := tasWaitTdlibParameters;
  end else
  if S = 'authorizationStateWaitPhoneNumber' then begin
    Result := tasWaitPhoneNumber;
  end else
  if S = 'authorizationStateWaitOtherDeviceConfirmation' then begin
    Result := tasWaitOtherDeviceConfirmation;
  end else
  if S = 'authorizationStateWaitEmailAddress' then begin
    Result := tasWaitEmailAddress;
  end else
  if S = 'authorizationStateWaitEmailCode' then begin
    Result := tasWaitEmailCode;
  end else
  if S = 'authorizationStateWaitCode' then begin
    Result := tasWaitCode;
  end else
  if S = 'authorizationStateWaitRegistration' then begin
    Result := tasWaitRegistration;
  end else
  if S = 'authorizationStateWaitPassword' then begin
    Result := tasWaitPassword;
  end else
  if S = 'authorizationStateReady' then begin
    Result := tasReady;
  end else
  if S = 'authorizationStateLoggingOut' then begin
    Result := tasLoggingOut;
  end else
  if S = 'authorizationStateClosing' then begin
    Result := tasClosing;
  end else
  if S = 'authorizationStateClosed' then begin
    Result := tasClosed;
  end else begin
    Result := tasNone;
  end;
end;

function DeliveryFromString(const S: utf8string): TTdCodeDelivery;
begin
  if S = 'authenticationCodeTypeTelegramMessage' then begin
    Result := tcdTelegramMessage;
  end else
  if S = 'authenticationCodeTypeSms' then begin
    Result := tcdSms;
  end else
  if S = 'authenticationCodeTypeSmsWord' then begin
    Result := tcdSmsWord;
  end else
  if S = 'authenticationCodeTypeSmsPhrase' then begin
    Result := tcdSmsPhrase;
  end else
  if S = 'authenticationCodeTypeCall' then begin
    Result := tcdCall;
  end else
  if S = 'authenticationCodeTypeFlashCall' then begin
    Result := tcdFlashCall;
  end else
  if S = 'authenticationCodeTypeMissedCall' then begin
    Result := tcdMissedCall;
  end else
  if S = 'authenticationCodeTypeFragment' then begin
    Result := tcdFragment;
  end else
  if S = 'authenticationCodeTypeFirebaseAndroid' then begin
    Result := tcdFirebaseAndroid;
  end else
  if S = 'authenticationCodeTypeFirebaseIos' then begin
    Result := tcdFirebaseIos;
  end else begin
    Result := tcdUnknown;
  end;
end;

function AuthStateToStr(AState: TTdAuthState): string;
begin
  case AState of
    tasWaitTdlibParameters: begin
      Result := 'waiting for parameters';
    end;
    tasWaitPhoneNumber: begin
      Result := 'phone number or QR required';
    end;
    tasWaitOtherDeviceConfirmation: begin
      Result := 'confirm login on another device';
    end;
    tasWaitEmailAddress: begin
      Result := 'e-mail address required';
    end;
    tasWaitEmailCode: begin
      Result := 'e-mail code required';
    end;
    tasWaitCode: begin
      Result := 'confirmation code required';
    end;
    tasWaitRegistration: begin
      Result := 'registration required';
    end;
    tasWaitPassword: begin
      Result := 'password required (2FA)';
    end;
    tasReady: begin
      Result := 'authorized';
    end;
    tasLoggingOut: begin
      Result := 'logging out';
    end;
    tasClosing: begin
      Result := 'closing';
    end;
    tasClosed: begin
      Result := 'closed';
    end;
    else
    begin
      Result := 'undefined';
    end;
  end;
end;

function CodeDeliveryToStr(ADelivery: TTdCodeDelivery): string;
begin
  case ADelivery of
    tcdTelegramMessage: begin
      Result := 'Telegram message on another device';
    end;
    tcdSms: begin
      Result := 'SMS';
    end;
    tcdSmsWord: begin
      Result := 'SMS, code is the first word';
    end;
    tcdSmsPhrase: begin
      Result := 'SMS, code is the first phrase';
    end;
    tcdCall: begin
      Result := 'incoming call dictating the code';
    end;
    tcdFlashCall: begin
      Result := 'flash call, code in the number';
    end;
    tcdMissedCall: begin
      Result := 'missed call, code in last digits';
    end;
    tcdFragment: begin
      Result := 'Fragment';
    end;
    tcdFirebaseAndroid: begin
      Result := 'Firebase (Android)';
    end;
    tcdFirebaseIos: begin
      Result := 'Firebase (iOS)';
    end;
    else
    begin
      Result := 'unknown';
    end;
  end;
end;

{ ---------------- TTdAuth ---------------- }

constructor TTdAuth.Create(AClient: TTdClient);
begin
  inherited Create;
  FClient   := AClient;
  FPending  := TStringList.Create;
  FState    := tasNone;
  FExtraSeq := 0;

  FDatabaseDir         := 'tdlib';
  FFilesDir            := 'tdlib/files';
  FSystemLanguageCode  := 'ru';
  FDeviceModel         := 'Desktop';
  FSystemVersion       := '';
  FApplicationVersion  := '1.0';
  FUseTestDc           := False;
  FUseMessageDatabase  := True;
  FUseChatInfoDatabase := True;
  FUseFileDatabase     := True;
  FUseSecretChats      := False;

  FSavedUpdate     := FClient.OnUpdate;
  FClient.OnUpdate := @ClientUpdate;
end;

destructor TTdAuth.Destroy;
begin
  if (FClient <> nil) and (FClient.OnUpdate = @ClientUpdate) then begin
    FClient.OnUpdate := FSavedUpdate;
  end;
  FPending.Free;
  inherited Destroy;
end;

procedure TTdAuth.SetState(AState: TTdAuthState);
begin
  if FState = AState then begin
    Exit;
  end;
  FState := AState;
  if Assigned(FOnStateChanged) then begin
    FOnStateChanged(Self, FState);
  end;
end;

procedure TTdAuth.SendAuth(const AMethod, ABody: utf8string);
var
  Extra, Req: utf8string;
begin
  Inc(FExtraSeq);
  Extra := 'auth:' + utf8string(IntToStr(FExtraSeq));

  while FPending.Count >= MAX_PENDING do begin
    FPending.Delete(0);
  end;
  FPending.Values[string(Extra)] := string(AMethod);

  Req := '{"@type":"' + AMethod + '"';
  if ABody <> '' then begin
    Req := Req + ',' + ABody;
  end;
  Req := Req + ',"@extra":"' + Extra + '"}';

  FClient.Send(Req);
end;

function TTdAuth.TakePending(const AExtra: utf8string): utf8string;
var
  Idx: integer;
begin
  Result := '';
  if AExtra = '' then begin
    Exit;
  end;
  Idx := FPending.IndexOfName(string(AExtra));
  if Idx >= 0 then begin
    Result := utf8string(FPending.ValueFromIndex[Idx]);
    FPending.Delete(Idx);
  end;
end;

procedure TTdAuth.SendTdlibParameters;
var
  Body: utf8string;
begin
  Body :=
    '"use_test_dc":' + JBool(FUseTestDc) +
    ',"database_directory":"' + JsonEsc(FDatabaseDir) + '"' +
    ',"files_directory":"' + JsonEsc(FFilesDir) + '"' +
    ',"use_file_database":' + JBool(FUseFileDatabase) +
    ',"use_chat_info_database":' + JBool(FUseChatInfoDatabase) +
    ',"use_message_database":' + JBool(FUseMessageDatabase) +
    ',"use_secret_chats":' + JBool(FUseSecretChats) +
    ',"api_id":' + utf8string(IntToStr(FApiId)) +
    ',"api_hash":"' + JsonEsc(FApiHash) + '"' +
    ',"system_language_code":"' + JsonEsc(FSystemLanguageCode) + '"' +
    ',"device_model":"' + JsonEsc(FDeviceModel) + '"' +
    ',"system_version":"' + JsonEsc(FSystemVersion) + '"' +
    ',"application_version":"' + JsonEsc(FApplicationVersion) + '"';

  SendAuth('setTdlibParameters', Body);
end;

procedure TTdAuth.ClientUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  T:   utf8string;
begin
  if Assigned(FSavedUpdate) then begin
    FSavedUpdate(Sender, AJson, AData);
  end;

  { AData уже разобран приёмным потоком (tdrecv.pas) — раньше здесь
    был свой отдельный GetJSON той же строки. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;
  T   := ObjStr(Obj, '@type');

  if T = 'updateAuthorizationState' then begin
    ProcessAuthState(ObjObj(Obj, 'authorization_state'));
  end else
  if T = 'authorizationState' then begin
    ProcessAuthState(Obj);
  end else
  if T = 'error' then begin
    ProcessError(Obj);
  end else
  if T = 'passwordRecoveryEmailAddressInfo' then begin
    if Assigned(FOnPasswordRecovery) then begin
      FOnPasswordRecovery(Self, ObjStr(Obj, 'email_address_pattern'));
    end;
  end;
end;

procedure TTdAuth.ProcessAuthState(AObj: TJSONObject);
var
  StateType:                                utf8string;
  NewState:                                 TTdAuthState;
  CodeInfo, TypeObj, NextObj, Tos, TosText: TJSONObject;
  Info:                                     TTdCodeInfo;
begin
  if AObj = nil then begin
    Exit;
  end;
  StateType := ObjStr(AObj, '@type');
  NewState  := AuthStateFromString(StateType);
  SetState(NewState);

  case NewState of

    tasWaitTdlibParameters:
    begin
      SendTdlibParameters;
    end;

    tasWaitPhoneNumber:
    begin
      if Assigned(FOnNeedPhoneOrQr) then begin
        FOnNeedPhoneOrQr(Self);
      end;
    end;

    tasWaitOtherDeviceConfirmation:
    begin
      if Assigned(FOnQrLink) then begin
        FOnQrLink(Self, ObjStr(AObj, 'link'));
      end;
    end;

    tasWaitEmailAddress:
    begin
      if Assigned(FOnNeedEmailAddress) then begin
        FOnNeedEmailAddress(Self,
          ObjBool(AObj, 'allow_apple_id'),
          ObjBool(AObj, 'allow_google_id'));
      end;
    end;

    tasWaitEmailCode:
    begin
      CodeInfo := ObjObj(AObj, 'code_info');
      if Assigned(FOnNeedEmailCode) then begin
        FOnNeedEmailCode(Self,
          ObjStr(CodeInfo, 'email_address_pattern'),
          ObjInt(CodeInfo, 'length'));
      end;
    end;

    tasWaitCode:
    begin
      FillChar(Info, SizeOf(Info), 0);
      Info.PhonePattern := '';
      Info.Hint         := '';
      CodeInfo          := ObjObj(AObj, 'code_info');
      if CodeInfo <> nil then begin
        Info.PhonePattern := ObjStr(CodeInfo, 'phone_number');
        Info.Timeout      := ObjInt(CodeInfo, 'timeout');

        TypeObj := ObjObj(CodeInfo, 'type');
        if TypeObj <> nil then begin
          Info.Delivery   := DeliveryFromString(ObjStr(TypeObj, '@type'));
          Info.CodeLength := ObjInt(TypeObj, 'length');
          case Info.Delivery of
            tcdSmsWord: begin
              Info.Hint := ObjStr(TypeObj, 'first_word');
            end;
            tcdSmsPhrase: begin
              Info.Hint := ObjStr(TypeObj, 'first_phrase');
            end;
            tcdFlashCall: begin
              Info.Hint := ObjStr(TypeObj, 'pattern');
            end;
            tcdMissedCall: begin
              Info.Hint := ObjStr(TypeObj, 'phone_number_prefix');
            end;
          end;
        end;

        NextObj := ObjObj(CodeInfo, 'next_type');
        if NextObj <> nil then begin
          Info.NextDelivery := DeliveryFromString(ObjStr(NextObj, '@type'));
        end else begin
          Info.NextDelivery := tcdUnknown;
        end;
      end;
      if Assigned(FOnNeedCode) then begin
        FOnNeedCode(Self, Info);
      end;
    end;

    tasWaitRegistration:
    begin
      Tos     := ObjObj(AObj, 'terms_of_service');
      TosText := ObjObj(Tos, 'text');
      if Assigned(FOnNeedRegistration) then begin
        FOnNeedRegistration(Self,
          ObjStr(TosText, 'text'),
          ObjBool(Tos, 'show_popup'),
          ObjInt(Tos, 'min_user_age'));
      end;
    end;

    tasWaitPassword:
    begin
      if Assigned(FOnNeedPassword) then begin
        FOnNeedPassword(Self,
          ObjStr(AObj, 'password_hint'),
          ObjStr(AObj, 'recovery_email_address_pattern'),
          ObjBool(AObj, 'has_recovery_email_address'));
      end;
    end;

    tasReady:
    begin
      if Assigned(FOnReady) then begin
        FOnReady(Self);
      end;
    end;

    tasClosed:
    begin
      if Assigned(FOnClosed) then begin
        FOnClosed(Self);
      end;
    end;
  end;
end;

procedure TTdAuth.ProcessError(AObj: TJSONObject);
var
  Ctx: utf8string;
begin
  Ctx := TakePending(ObjStr(AObj, '@extra'));
  if Assigned(FOnError) then begin
    FOnError(Self, ObjInt(AObj, 'code'), ObjStr(AObj, 'message'), Ctx);
  end;
end;

{ ---------------- ответы автомату ---------------- }

procedure TTdAuth.SubmitPhone(const APhone: utf8string);
begin
  SendAuth('setAuthenticationPhoneNumber',
    '"phone_number":"' + JsonEsc(APhone) + '"');
end;

procedure TTdAuth.RequestQr;
begin
  SendAuth('requestQrCodeAuthentication', '"other_user_ids":[]');
end;

procedure TTdAuth.SubmitCode(const ACode: utf8string);
begin
  SendAuth('checkAuthenticationCode', '"code":"' + JsonEsc(ACode) + '"');
end;

procedure TTdAuth.ResendCode;
begin
  SendAuth('resendAuthenticationCode', '');
end;

procedure TTdAuth.SubmitEmailAddress(const AEmail: utf8string);
begin
  SendAuth('setAuthenticationEmailAddress',
    '"email_address":"' + JsonEsc(AEmail) + '"');
end;

procedure TTdAuth.SubmitEmailCode(const ACode: utf8string);
begin
  SendAuth('checkAuthenticationEmailCode',
    '"code":{"@type":"emailAddressAuthenticationCode","code":"' +
    JsonEsc(ACode) + '"}');
end;

procedure TTdAuth.SubmitPassword(const APassword: utf8string);
begin
  SendAuth('checkAuthenticationPassword',
    '"password":"' + JsonEsc(APassword) + '"');
end;

procedure TTdAuth.RequestPasswordRecovery;
begin
  SendAuth('requestAuthenticationPasswordRecovery', '');
end;

procedure TTdAuth.SubmitRecoveryCode(const ACode, ANewPassword, ANewHint: utf8string);
begin
  SendAuth('recoverAuthenticationPassword',
    '"recovery_code":"' + JsonEsc(ACode) + '"' +
    ',"new_password":"' + JsonEsc(ANewPassword) + '"' +
    ',"new_hint":"' + JsonEsc(ANewHint) + '"');
end;

procedure TTdAuth.SubmitRegistration(const AFirstName, ALastName: utf8string);
begin
  SendAuth('registerUser',
    '"first_name":"' + JsonEsc(AFirstName) + '"' +
    ',"last_name":"' + JsonEsc(ALastName) + '"' +
    ',"disable_notification":false');
end;

procedure TTdAuth.LogOut;
begin
  SendAuth('logOut', '');
end;

procedure TTdAuth.Close;
begin
  SendAuth('close', '');
end;

end.
