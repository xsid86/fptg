unit tdsession;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, tdauth;

type

  { Интерфейсы подписчиков.

    Живут здесь, а не в tdcore, потому что после разделения на аккаунты
    tdcore оказывается НАД моделями: tdreq и tdchats должны знать про
    подписку, но не про реестр аккаунтов. Иначе получается цикл. }

  { Сырой поток JSON. AData — уже разобранный объект (парсинг теперь
    выполняется один раз в приёмном потоке, tdrecv.pas), а не заново
    каждым подписчиком на главном потоке. AData = nil, если строка не
    распарсилась или оказалась не объектом — подписчик обязан это
    проверять. Объект живёт только до конца вызова TdUpdate: подписчик
    не должен сохранять указатель, освобождает его tdrecv. }
  ITdUpdateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1101}']
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
  end;

  { Состояние авторизации и ошибки. Реализуют все формы. }
  ITdStateListener = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1102}']
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
  end;

  { Полный флоу авторизации. Реализует только форма входа. }
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

    Один аккаунт с точки зрения моделей. Ровно тот минимум, который
    нужен tdreq и tdchats: отправить, подписаться, узнать состояние.
    Про существование других аккаунтов модели не знают вообще. }

  ITdSession = interface
    ['{6F2A1C40-1E1B-4C2E-9A3D-2B7C5E0A1201}']
    function GetClientId: integer;
    function GetState: TTdAuthState;
    function GetDataDir: string;
    function GetTitle: string;
    function GetAuth: TTdAuth;

    procedure Send(const ARequest: utf8string);
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);

    property ClientId: integer read GetClientId;
    property State: TTdAuthState read GetState;
    { Каталог базы этого аккаунта. У каждого свой, иначе клиенты
      затрут данные друг друга. }
    property DataDir: string read GetDataDir;
    { Человекочитаемое имя для переключателя аккаунтов. }
    property Title: string read GetTitle;
    property Auth: TTdAuth read GetAuth;
  end;

{ Состояние требует ввода от пользователя. }
function TdIsPromptState(AState: TTdAuthState): boolean;

{ Состояние — процесс выхода или закрытия. }
function TdIsShuttingState(AState: TTdAuthState): boolean;

{ Безопасная отписка: молча пропускает nil-сессию, чтобы деструкторы
  форм не падали, если аккаунт уже уничтожен. }
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
