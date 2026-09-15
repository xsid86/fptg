unit tdsession;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, tdauth;

type

  { Subscriber interfaces.

    Declared here rather than in tdcore, because after the split into
    per-account clients, tdcore sits ABOVE the models: tdreq and
    tdchats need to know about subscriptions but not about the account
    registry. Declaring these in tdcore would create a circular
    dependency. }

  { Raw JSON update stream. AData is an already-parsed object (parsing
    now happens once, in the receive thread, tdrecv.pas — not again by
    each subscriber on the main thread). AData is nil if the string
    failed to parse or was not an object; subscribers must check for
    that. The object is valid only for the duration of the TdUpdate
    call — subscribers must not keep the pointer, tdrecv frees it. }
  ITdUpdateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1101}']
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
  end;

  { Authorization state and errors. Implemented by all forms. }
  ITdStateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1102}']
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
  end;

  { The full authorization flow. Implemented only by the login form. }
  ITdAuthListener = interface(ITdStateListener)
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1103}']
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
  end;

  { ITdSession

    A single account, as seen by the models. Exposes exactly the
    minimum tdreq and tdchats need: send a request, subscribe, read
    the state. Models have no knowledge of other accounts. }

  ITdSession = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1201}']
    function GetClientId: integer;
    function GetState: TTdAuthState;
    function GetDataDir: string;
    function GetTitle: string;
    function GetAuth: TTdAuth;
    function GetUserId: Int64;

    procedure Send(const ARequest: utf8string);
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);

    property ClientId: integer read GetClientId;
    property State: TTdAuthState read GetState;
    { This account's database directory. Each account has its own, or
      clients would overwrite each other's data. }
    property DataDir: string read GetDataDir;
    { Human-readable name for the account switcher. }
    property Title: string read GetTitle;
    property Auth: TTdAuth read GetAuth;
    { This account's own user id (arrives via getMe) — 0 until that
      response comes back. Needed by tdchats.IsSelfChat, to tell the
      Saved Messages chat (a ckPrivate row whose peer IS this id) apart
      from an ordinary private chat. }
    property UserId: Int64 read GetUserId;
  end;

{ True if the state requires input from the user. }
function TdIsPromptState(AState: TTdAuthState): boolean;

{ True if the state is a logout/shutdown state. }
function TdIsShuttingState(AState: TTdAuthState): boolean;

{ Safe unsubscribe: silently skips a nil session, so form destructors
  don't fail if the account has already been destroyed. }
procedure TdSessionUnsubscribe(const ASession: ITdSession; const AListener: IUnknown);

implementation

function TdIsPromptState(AState: TTdAuthState): boolean;
begin
  Result := AState in [tasWaitPhoneNumber, tasWaitOtherDeviceConfirmation,
    tasWaitEmailAddress, tasWaitEmailCode, tasWaitCode,
    tasWaitRegistration, tasWaitPassword];
end;

function TdIsShuttingState(AState: TTdAuthState): boolean;
begin
  Result := AState in [tasLoggingOut, tasClosing, tasClosed];
end;

procedure TdSessionUnsubscribe(const ASession: ITdSession; const AListener: IUnknown);
begin
  if (ASession <> nil) and (AListener <> nil) then begin
    ASession.Unsubscribe(AListener);
  end;
end;

end.
