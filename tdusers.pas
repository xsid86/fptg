unit tdusers;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, fpjson,
  tdauth, tdsession, tdreq;

type
  { TUserRow

    Минимум, нужный для отображаемого имени в заголовке сообщения.
    Без единой ссылки на LCL — как TChatRow/TMsgRow. }
  TUserRow = class
  public
    Id: Int64;
    FirstName, LastName: utf8string;
    { 0..6 — зарезервированные "базовые" цвета, 7+ — резолвятся через
      TTdAccentColors (tdaccentcolors.pas) из updateAccentColors. }
    AccentColorId: integer;
    function DisplayName: utf8string;
  end;

  TUserMap = specialize TFPGMap<Int64, TUserRow>;

  TTdUsersEvent = procedure(Sender: TObject) of object;

  { TTdUsers

    Кэш отображаемых имён произвольных пользователей — то, чего не было
    в проекте: TTdChats.FBots хранит только флаг "бот ли это"
    (tdchats.pas), не имя. Пассивно пополняется из updateUser (тот же
    поток апдейтов, что уже слушает TTdChats на этот тип), а на промах
    кэша — активно доедаёт через getUser, по тому же принципу
    "асинхронно догрузить и перерисовать по готовности", что и аватарки
    в avatarcache.pas/updateFile. }
  TTdUsers = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq: TTdRequests;
    FAll: TUserMap;
    { id пользователей, на которых getUser уже отправлен и ждём ответа —
      чтобы не заваливать TDLib повторными запросами на каждую
      перерисовку одного и того же ещё не разрешённого имени. }
    FPending: array of Int64;
    FOnChanged: TTdUsersEvent;
    function Lookup(AId: Int64): TUserRow;
    function IsPending(AId: Int64): boolean;
    procedure MarkPending(AId: Int64);
    procedure ClearPending(AId: Int64);
    procedure ApplyUser(AUser: TJSONObject);
    procedure RequestUser(AId: Int64);
    procedure GetUserDone(Sender: TObject; const AResp: TTdResponse);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { Возвращает закэшированное имя, либо '' и асинхронно запускает
      getUser, если пользователь ещё не известен и запрос на него ещё
      не в полёте. Результат придёт позже через OnChanged. }
    function DisplayName(AUserId: Int64): utf8string;
    { То же самое, но accent_color_id пользователя; -1, если ещё не
      известен (в т.ч. запускает getUser на промах — независимо и
      достаточно само по себе, не полагается на то, что DisplayName
      для этого же id уже был вызван раньше). }
    function AccentColorId(AUserId: Int64): integer;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property OnChanged: TTdUsersEvent read FOnChanged write FOnChanged;
  end;

implementation

{ ---------------- TUserRow ---------------- }

function TUserRow.DisplayName: utf8string;
begin
  Result := utf8string(Trim(string(FirstName) + ' ' + string(LastName)));
  if Result = '' then begin
    Result := utf8string('User ' + IntToStr(Id));
  end;
end;

{ ---------------- TTdUsers ---------------- }

constructor TTdUsers.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TUserMap.Create;
  FAll.Sorted := True;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdUsers.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdUsers.Clear;
var
  I: integer;
begin
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  SetLength(FPending, 0);
end;

function TTdUsers.Lookup(AId: Int64): TUserRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdUsers.IsPending(AId: Int64): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(FPending) do begin
    if FPending[I] = AId then begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdUsers.MarkPending(AId: Int64);
begin
  SetLength(FPending, Length(FPending) + 1);
  FPending[High(FPending)] := AId;
end;

procedure TTdUsers.ClearPending(AId: Int64);
var
  I, J: integer;
begin
  for I := 0 to High(FPending) do begin
    if FPending[I] = AId then begin
      for J := I to High(FPending) - 1 do begin
        FPending[J] := FPending[J + 1];
      end;
      SetLength(FPending, Length(FPending) - 1);
      Exit;
    end;
  end;
end;

procedure TTdUsers.ApplyUser(AUser: TJSONObject);
var
  Id: Int64;
  R: TUserRow;
  Idx: integer;
begin
  if AUser = nil then begin
    Exit;
  end;
  Id := JGetInt64(AUser, 'id');
  if Id = 0 then begin
    Exit;
  end;

  Idx := FAll.IndexOf(Id);
  if Idx >= 0 then begin
    R := FAll.Data[Idx];
  end else begin
    R := TUserRow.Create;
    R.Id := Id;
    FAll.Add(Id, R);
  end;
  R.FirstName := JGetStr(AUser, 'first_name');
  R.LastName := JGetStr(AUser, 'last_name');
  R.AccentColorId := JGetInt(AUser, 'accent_color_id');

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

procedure TTdUsers.RequestUser(AId: Int64);
begin
  if (FReq = nil) or IsPending(AId) then begin
    Exit;
  end;
  MarkPending(AId);
  FReq.SendRequest('getUser', '"user_id":' + utf8string(IntToStr(AId)),
    @GetUserDone, PtrInt(AId));
end;

procedure TTdUsers.GetUserDone(Sender: TObject; const AResp: TTdResponse);
begin
  { Снимаем pending по Tag (тому, что реально запрашивали), а не по id
    из тела ответа — на ошибке тела может не быть вовсе, и без этого
    имя осталось бы навечно помеченным "уже в полёте", не давая
    повторить попытку при следующей прорисовке. }
  ClearPending(Int64(AResp.Tag));
  if AResp.Success then begin
    ApplyUser(AResp.Obj);
  end;
end;

function TTdUsers.DisplayName(AUserId: Int64): utf8string;
var
  R: TUserRow;
begin
  Result := '';
  if AUserId = 0 then begin
    Exit;
  end;
  R := Lookup(AUserId);
  if R <> nil then begin
    Result := R.DisplayName;
    Exit;
  end;
  RequestUser(AUserId);
end;

function TTdUsers.AccentColorId(AUserId: Int64): integer;
var
  R: TUserRow;
begin
  Result := -1;
  if AUserId = 0 then begin
    Exit;
  end;
  R := Lookup(AUserId);
  if R <> nil then begin
    Result := R.AccentColorId;
    Exit;
  end;
  RequestUser(AUserId);
end;

procedure TTdUsers.TdUpdate(const AJson: utf8string; AData: TJSONObject);
begin
  if AData = nil then begin
    Exit;
  end;
  if JGetStr(AData, '@type') = 'updateUser' then begin
    ApplyUser(JGetObj(AData, 'user'));
  end;
end;

procedure TTdUsers.TdStateChanged(AState: TTdAuthState);
begin
  { На выходе/закрытии клиента кэш имён теряет смысл — как и у прочих
    моделей аккаунта. }
  if TdIsShuttingState(AState) then begin
    Clear;
  end;
end;

procedure TTdUsers.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации модели не касаются. }
end;

end.
