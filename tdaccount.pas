unit tdaccount;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ExtCtrls, fpjson, jsonparser, base64,
  tdauth, tdclient, tdsession, tdreq, tdchats, tdmessages, tdusers, tdaccentcolors;

type

  { TTdAccount

    Один аккаунт Telegram со всем своим хозяйством. Наследник
    TComponent, а не TInterfacedObject: интерфейс ITdSession не должен
    быть подсчётным, иначе объект самоуничтожится, когда модели
    отпустят ссылку.

    Списки подписчиков живут здесь, а не в реестре: форма подписывается
    на КОНКРЕТНЫЙ аккаунт, и при пересоздании клиента после logOut
    подписки не теряются. }

  TTdAccount = class(TComponent, ITdSession)
  private
    FSlot:     integer;      { порядковый номер, он же имя каталога }
    FDataDir:  string;
    FFilesDir: string;
    FTitle:    string;
    FApiId:    integer;
    FApiHash:  utf8string;
    FUserId:   Int64;
    FPhone:    utf8string;
    FUsername: utf8string;
    FPhotoFileId:  integer;
    FPhotoPath:    utf8string;
    FPhotoThumb:   RawByteString;
    FPhotoAsked:   boolean;
    FOnInfoChanged: TNotifyEvent;
    FOnStateNotify: TNotifyEvent;
    FForget: boolean;   { после logOut аккаунт не пересоздавать, а убрать }

    FClient:   TTdClient;
    FAuth:     TTdAuth;
    FReq:      TTdRequests;
    FChats:    TTdChats;
    FMessages: TTdMessages;
    FUsers:    TTdUsers;
    FAccentColors: TTdAccentColors;

    FUpdateL: array of ITdUpdateListener;
    FStateL:  array of ITdStateListener;
    FAuthL:   array of ITdAuthListener;

    FState:      TTdAuthState;
    FStarted:    boolean;
    FLoggingOut: boolean;
    FClosing:    boolean;
    FClosed:     boolean;
    FRestartTimer: TTimer;

    procedure CreateEngine;
    procedure DestroyEngine;
    procedure RestartTick(Sender: TObject);
    procedure RequestMe;
    procedure MeDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyMyPhoto(APhoto: TJSONObject);
    procedure PhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyPhotoFile(AFile: TJSONObject);

    { приёмники событий TTdAuth }
    procedure HandleUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
    procedure HandleStateChanged(Sender: TObject; AState: TTdAuthState);
    procedure HandleError(Sender: TObject; ACode: integer;
      const AMessage, AContext: utf8string);
    procedure HandleNeedPhoneOrQr(Sender: TObject);
    procedure HandleQrLink(Sender: TObject; const ALink: utf8string);
    procedure HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
    procedure HandleNeedEmailAddress(Sender: TObject; AAllowApple, AAllowGoogle: boolean);
    procedure HandleNeedEmailCode(Sender: TObject; const APattern: utf8string;
      ALength: integer);
    procedure HandleNeedPassword(Sender: TObject;
      const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
    procedure HandlePasswordRecovery(Sender: TObject; const AEmailPattern: utf8string);
    procedure HandleNeedRegistration(Sender: TObject; const ATosText: utf8string;
      AShowPopup: boolean; AMinAge: integer);
  public
    constructor Create(AOwner: TComponent; ASlot: integer;
      const ABaseDir, ATitle: string; AApiId: integer;
      const AApiHash: utf8string); reintroduce;
    destructor Destroy; override;

    procedure Start;

    { Выход из аккаунта. Клиент пересоздаётся, флоу вернётся
      к вводу номера. Другие аккаунты не затрагиваются. }
    procedure LogOut;

    { То же, но аккаунт после выхода подлежит удалению из реестра —
      как в Telegram. Пересоздания клиента не будет. }
    procedure LogOutAndForget;

    { Закрыть клиента и убрать аккаунт, НЕ выходя из сессии.
      Нужно при отмене добавления: без close клиент TDLib остаётся
      жив и держит каталог базы, и следующая попытка занять тот же
      слот упирается в заблокированную базу. }
    procedure CloseAndForget;

    { Просит TDLib закрыть клиента. Ждать окончания — забота реестра:
      закрывать надо все аккаунты, а таймаут разумно иметь общий. }
    procedure RequestClose;

    { ITdSession }
    function GetClientId: integer;
    function GetState: TTdAuthState;
    function GetDataDir: string;
    function GetTitle: string;
    function GetAuth: TTdAuth;
    procedure Send(const ARequest: utf8string);
    procedure Subscribe(const AListener: IUnknown);
    procedure Unsubscribe(const AListener: IUnknown);

    property Slot: integer read FSlot;
    property UserId: Int64 read FUserId;
    property Phone: utf8string read FPhone;
    property Username: utf8string read FUsername;
    { Своя аватарка — для меню аккаунтов. Мини-превью приходит
      вместе с getMe, полноразмерная докачивается. }
    property PhotoPath: utf8string read FPhotoPath;
    property PhotoThumb: RawByteString read FPhotoThumb;
    { Реестр подписывается, чтобы сохранить манифест и обновить меню. }
    property OnInfoChanged: TNotifyEvent read FOnInfoChanged write FOnInfoChanged;
    { Любая смена состояния — реестру, чтобы обновить меню:
      неактивный аккаунт мог разлогиниться, и это надо показать. }
    property OnStateNotify: TNotifyEvent read FOnStateNotify write FOnStateNotify;
    property Forget: boolean read FForget;
    property Title: string read FTitle write FTitle;
    property Chats: TTdChats read FChats;
    property Messages: TTdMessages read FMessages;
    property Users: TTdUsers read FUsers;
    property AccentColors: TTdAccentColors read FAccentColors;
    property Requests: TTdRequests read FReq;
    property Auth: TTdAuth read FAuth;
    property State: TTdAuthState read FState;
    property Started: boolean read FStarted;
    property Closing: boolean read FClosing;
    property Closed: boolean read FClosed;
  end;

implementation

{ ---------------- жизненный цикл ---------------- }

constructor TTdAccount.Create(AOwner: TComponent; ASlot: integer;
  const ABaseDir, ATitle: string; AApiId: integer; const AApiHash: utf8string);
begin
  inherited Create(AOwner);
  FSlot := ASlot;
  FTitle := ATitle;
  FApiId := AApiId;
  FApiHash := AApiHash;
  FState := tasNone;

  { У каждого аккаунта свой каталог. Общий привёл бы к тому, что
    клиенты затирают базы друг друга. }
  FDataDir := ABaseDir + 'tdlib' + PathDelim + 'acc' + IntToStr(ASlot);
  FFilesDir := FDataDir + PathDelim + 'files';

  FRestartTimer := TTimer.Create(Self);
  FRestartTimer.Interval := 1;
  FRestartTimer.OnTimer := @RestartTick;
  FRestartTimer.Enabled := False;

  { Объекты создаём сразу, а не в Start: формы обращаются к Chats
    и подписываются ещё в FormCreate, то есть до запуска клиента.
    Сам клиент TDLib при этом ещё спит — его будит Start. }
  CreateEngine;
end;

destructor TTdAccount.Destroy;
begin
  FRestartTimer.Enabled := False;
  DestroyEngine;
  SetLength(FUpdateL, 0);
  SetLength(FStateL, 0);
  SetLength(FAuthL, 0);
  inherited Destroy;
end;

procedure TTdAccount.CreateEngine;
begin
  FClient := TTdClient.Create;
  { Порядок важен: TTdAuth в конструкторе встраивается в цепочку OnUpdate. }
  FClient.OnUpdate := @HandleUpdate;

  FAuth := TTdAuth.Create(FClient);
  FAuth.ApiId              := FApiId;
  FAuth.ApiHash            := FApiHash;
  FAuth.DatabaseDir        := utf8string(FDataDir);
  FAuth.FilesDir           := utf8string(FFilesDir);
  FAuth.DeviceModel        := 'FPC Desktop';
  FAuth.ApplicationVersion := '1.0';
  FAuth.SystemLanguageCode := 'ru';

  FAuth.OnStateChanged     := @HandleStateChanged;
  FAuth.OnError            := @HandleError;
  FAuth.OnNeedPhoneOrQr    := @HandleNeedPhoneOrQr;
  FAuth.OnQrLink           := @HandleQrLink;
  FAuth.OnNeedCode         := @HandleNeedCode;
  FAuth.OnNeedEmailAddress := @HandleNeedEmailAddress;
  FAuth.OnNeedEmailCode    := @HandleNeedEmailCode;
  FAuth.OnNeedPassword     := @HandleNeedPassword;
  FAuth.OnPasswordRecovery := @HandlePasswordRecovery;
  FAuth.OnNeedRegistration := @HandleNeedRegistration;

  { Резолвер и модель подписываются на сам аккаунт, а не на клиента:
    при пересоздании клиента они переживают смену. }
  FReq := TTdRequests.Create(Self, Self);
  FChats := TTdChats.Create(Self, Self, FReq);
  FMessages := TTdMessages.Create(Self, Self, FReq);
  FUsers := TTdUsers.Create(Self, Self, FReq);
  FAccentColors := TTdAccentColors.Create(Self, Self);
end;

procedure TTdAccount.DestroyEngine;
begin
  FreeAndNil(FAccentColors);
  FreeAndNil(FUsers);
  FreeAndNil(FMessages);
  FreeAndNil(FChats);
  FreeAndNil(FReq);
  FreeAndNil(FAuth);
  if FClient <> nil then begin
    FClient.Stop;
    FreeAndNil(FClient);
  end;
end;

procedure TTdAccount.Start;
begin
  if FStarted then begin
    Exit;
  end;
  FStarted := True;
  if FClient <> nil then begin
    FClient.Start;
  end;
end;

{ ---------------- ITdSession ---------------- }

function TTdAccount.GetClientId: integer;
begin
  if FClient <> nil then begin
    Result := FClient.ClientId;
  end else begin
    Result := 0;
  end;
end;

function TTdAccount.GetState: TTdAuthState;
begin
  Result := FState;
end;

function TTdAccount.GetDataDir: string;
begin
  Result := FDataDir;
end;

function TTdAccount.GetTitle: string;
begin
  Result := FTitle;
end;

function TTdAccount.GetAuth: TTdAuth;
begin
  Result := FAuth;
end;

procedure TTdAccount.Send(const ARequest: utf8string);
begin
  if FClient <> nil then begin
    FClient.Send(ARequest);
  end;
end;

procedure TTdAccount.Subscribe(const AListener: IUnknown);
var
  U: ITdUpdateListener;
  S: ITdStateListener;
  A: ITdAuthListener;
  I: integer;
  Found: boolean;
begin
  if AListener = nil then begin
    Exit;
  end;

  if Supports(AListener, ITdUpdateListener, U) then begin
    Found := False;
    for I := 0 to High(FUpdateL) do begin
      if FUpdateL[I] = U then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FUpdateL, Length(FUpdateL) + 1);
      FUpdateL[High(FUpdateL)] := U;
    end;
  end;

  if Supports(AListener, ITdStateListener, S) then begin
    Found := False;
    for I := 0 to High(FStateL) do begin
      if FStateL[I] = S then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FStateL, Length(FStateL) + 1);
      FStateL[High(FStateL)] := S;
    end;
  end;

  if Supports(AListener, ITdAuthListener, A) then begin
    Found := False;
    for I := 0 to High(FAuthL) do begin
      if FAuthL[I] = A then begin
        Found := True;
        Break;
      end;
    end;
    if not Found then begin
      SetLength(FAuthL, Length(FAuthL) + 1);
      FAuthL[High(FAuthL)] := A;
    end;
  end;
end;

procedure TTdAccount.Unsubscribe(const AListener: IUnknown);
var
  U: ITdUpdateListener;
  S: ITdStateListener;
  A: ITdAuthListener;
  I, J: integer;
begin
  if AListener = nil then begin
    Exit;
  end;

  if Supports(AListener, ITdUpdateListener, U) then begin
    for I := High(FUpdateL) downto 0 do begin
      if FUpdateL[I] = U then begin
        for J := I to High(FUpdateL) - 1 do begin
          FUpdateL[J] := FUpdateL[J + 1];
        end;
        SetLength(FUpdateL, Length(FUpdateL) - 1);
      end;
    end;
  end;

  if Supports(AListener, ITdStateListener, S) then begin
    for I := High(FStateL) downto 0 do begin
      if FStateL[I] = S then begin
        for J := I to High(FStateL) - 1 do begin
          FStateL[J] := FStateL[J + 1];
        end;
        SetLength(FStateL, Length(FStateL) - 1);
      end;
    end;
  end;

  if Supports(AListener, ITdAuthListener, A) then begin
    for I := High(FAuthL) downto 0 do begin
      if FAuthL[I] = A then begin
        for J := I to High(FAuthL) - 1 do begin
          FAuthL[J] := FAuthL[J + 1];
        end;
        SetLength(FAuthL, Length(FAuthL) - 1);
      end;
    end;
  end;
end;

{ ---------------- раздача событий ----------------
  Списки копируются перед обходом: подписчик вправе отписаться
  прямо в обработчике. }

procedure TTdAccount.HandleUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
var
  Snap: array of ITdUpdateListener;
  I: integer;
begin
  { Своя аватарка докачалась. AData уже разобран приёмным потоком
    (tdrecv.pas) — раньше здесь был свой отдельный GetJSON. }
  if (FPhotoFileId <> 0) and (FPhotoPath = '') and (AData <> nil)
     and (JGetStr(AData, '@type') = 'updateFile') then begin
    ApplyPhotoFile(JGetObj(AData, 'file'));
  end;

  Snap := Copy(FUpdateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdUpdate(AJson, AData);
  end;
end;

procedure TTdAccount.HandleStateChanged(Sender: TObject; AState: TTdAuthState);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  FState := AState;

  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdStateChanged(AState);
  end;

  { Как только вошли — спрашиваем, кто мы. Заголовок нужен
    переключателю аккаунтов, а user_id пригодится дальше. }
  if AState = tasReady then begin
    RequestMe;
  end;

  if Assigned(FOnStateNotify) then begin
    FOnStateNotify(Self);
  end;

  if AState = tasClosed then begin
    if FLoggingOut or FForget then begin
      { Пересоздание отложено: мы внутри разбора пачки апдейтов,
        сносить клиента из-под себя нельзя. }
      FRestartTimer.Enabled := True;
    end else if FClosing then begin
      FClosed := True;
    end;
  end;
end;

procedure TTdAccount.HandleError(Sender: TObject; ACode: integer;
  const AMessage, AContext: utf8string);
var
  Snap: array of ITdStateListener;
  I: integer;
begin
  Snap := Copy(FStateL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdError(ACode, AMessage, AContext);
  end;
end;

procedure TTdAccount.HandleNeedPhoneOrQr(Sender: TObject);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPhoneOrQr;
  end;
end;

procedure TTdAccount.HandleQrLink(Sender: TObject; const ALink: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdQrLink(ALink);
  end;
end;

procedure TTdAccount.HandleNeedCode(Sender: TObject; const AInfo: TTdCodeInfo);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedCode(AInfo);
  end;
end;

procedure TTdAccount.HandleNeedEmailAddress(Sender: TObject;
  AAllowApple, AAllowGoogle: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailAddress(AAllowApple, AAllowGoogle);
  end;
end;

procedure TTdAccount.HandleNeedEmailCode(Sender: TObject;
  const APattern: utf8string; ALength: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedEmailCode(APattern, ALength);
  end;
end;

procedure TTdAccount.HandleNeedPassword(Sender: TObject;
  const AHint, ARecoveryPattern: utf8string; AHasRecovery: boolean);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedPassword(AHint, ARecoveryPattern, AHasRecovery);
  end;
end;

procedure TTdAccount.HandlePasswordRecovery(Sender: TObject;
  const AEmailPattern: utf8string);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdPasswordRecovery(AEmailPattern);
  end;
end;

procedure TTdAccount.HandleNeedRegistration(Sender: TObject;
  const ATosText: utf8string; AShowPopup: boolean; AMinAge: integer);
var
  Snap: array of ITdAuthListener;
  I: integer;
begin
  Snap := Copy(FAuthL);
  for I := 0 to High(Snap) do begin
    Snap[I].TdNeedRegistration(ATosText, AShowPopup, AMinAge);
  end;
end;

{ ---------------- сведения о себе ---------------- }

procedure TTdAccount.RequestMe;
begin
  if FReq <> nil then begin
    FReq.SendRequest('getMe', '', @MeDone);
  end;
end;

procedure TTdAccount.MeDone(Sender: TObject; const AResp: TTdResponse);
var
  First, Last, NewTitle: utf8string;
  U: TJSONObject;
  Arr: TJSONArray;
begin
  if not AResp.Success then begin
    Exit;
  end;

  FUserId := JGetInt64(AResp.Obj, 'id');
  FPhone := JGetStr(AResp.Obj, 'phone_number');

  ApplyMyPhoto(JGetObj(AResp.Obj, 'profile_photo'));

  U := JGetObj(AResp.Obj, 'usernames');
  FUsername := JGetStr(U, 'editable_username');
  if FUsername = '' then begin
    Arr := JGetArr(U, 'active_usernames');
    if (Arr <> nil) and (Arr.Count > 0) then begin
      FUsername := utf8string(Arr.Items[0].AsString);
    end;
  end;

  First := JGetStr(AResp.Obj, 'first_name');
  Last := JGetStr(AResp.Obj, 'last_name');

  { Порядок предпочтения тот же, что в клиентах Telegram:
    имя, потом @username, потом номер. }
  NewTitle := utf8string(Trim(string(First) + ' ' + string(Last)));
  if NewTitle = '' then begin
    if FUsername <> '' then begin
      NewTitle := '@' + FUsername;
    end else if FPhone <> '' then begin
      NewTitle := '+' + FPhone;
    end;
  end;

  if (NewTitle <> '') and (NewTitle <> utf8string(FTitle)) then begin
    FTitle := string(NewTitle);
    if Assigned(FOnInfoChanged) then begin
      FOnInfoChanged(Self);
    end;
  end;
end;

procedure TTdAccount.ApplyMyPhoto(APhoto: TJSONObject);
var
  Small: TJSONObject;
  B64: utf8string;
begin
  if APhoto = nil then begin
    FPhotoFileId := 0;
    FPhotoPath := '';
    FPhotoThumb := '';
    Exit;
  end;

  Small := JGetObj(APhoto, 'small');
  FPhotoFileId := JGetInt(Small, 'id');
  FPhotoPath := JGetStr(JGetObj(Small, 'local'), 'path');

  B64 := JGetStr(JGetObj(APhoto, 'minithumbnail'), 'data');
  if B64 <> '' then begin
    try
      FPhotoThumb := DecodeStringBase64(string(B64));
    except
      FPhotoThumb := '';
    end;
  end;

  if Assigned(FOnInfoChanged) then begin
    FOnInfoChanged(Self);
  end;

  { Мини-превью уже можно показывать, а настоящую докачиваем. }
  if (FPhotoFileId <> 0) and (FPhotoPath = '') and (not FPhotoAsked)
     and (FReq <> nil) then begin
    FPhotoAsked := True;
    FReq.SendRequest('downloadFile',
      '"file_id":' + utf8string(IntToStr(FPhotoFileId)) +
      ',"priority":1,"offset":0,"limit":0,"synchronous":false', @PhotoDone);
  end;
end;

procedure TTdAccount.PhotoDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyPhotoFile(AResp.Obj);
  end else begin
    FPhotoAsked := False;
  end;
end;

procedure TTdAccount.ApplyPhotoFile(AFile: TJSONObject);
var
  Local: TJSONObject;
  Path: utf8string;
begin
  if (AFile = nil) or (JGetInt(AFile, 'id') <> FPhotoFileId) then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if (Path = '') or (Path = FPhotoPath) then begin
    Exit;
  end;
  FPhotoPath := Path;
  if Assigned(FOnInfoChanged) then begin
    FOnInfoChanged(Self);
  end;
end;

{ ---------------- выход и закрытие ---------------- }

procedure TTdAccount.LogOut;
begin
  if (FAuth = nil) or FClosing then begin
    Exit;
  end;
  FLoggingOut := True;
  FAuth.LogOut;
end;

procedure TTdAccount.LogOutAndForget;
begin
  FForget := True;
  LogOut;
end;

procedure TTdAccount.CloseAndForget;
begin
  FForget := True;
  if (FAuth = nil) or (not FStarted) then begin
    { Клиента и не было — сразу сообщаем реестру. }
    DestroyEngine;
    FState := tasNone;
    if Assigned(FOnStateNotify) then begin
      FOnStateNotify(Self);
    end;
    Exit;
  end;
  FClosing := True;
  FLoggingOut := False;
  FRestartTimer.Enabled := False;
  FAuth.Close;
end;

procedure TTdAccount.RestartTick(Sender: TObject);
begin
  FRestartTimer.Enabled := False;
  if not (FLoggingOut or FForget) then begin
    Exit;
  end;
  FLoggingOut := False;

  if FForget then begin
    { Аккаунт уходит из реестра — пересоздавать клиента незачем.
      Само удаление делает реестр, и делает отложенно: освобождать
      объект изнутри его собственного обработчика нельзя. }
    DestroyEngine;
    FState := tasNone;
    if Assigned(FOnStateNotify) then begin
      FOnStateNotify(Self);
    end;
    Exit;
  end;

  DestroyEngine;
  FState := tasNone;
  CreateEngine;
  if FClient <> nil then begin
    FClient.Start;
  end;
end;

procedure TTdAccount.RequestClose;
begin
  if FClosed then begin
    Exit;
  end;
  if (FAuth = nil) or (not FStarted) then begin
    FClosed := True;
    Exit;
  end;
  if FClosing then begin
    Exit;
  end;
  FClosing := True;
  FLoggingOut := False;
  FRestartTimer.Enabled := False;
  FAuth.Close;
end;

end.
