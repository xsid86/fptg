unit tdreq;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, ExtCtrls, fpjson, jsonparser,
  constants, tdauth, tdsession;

type
  TTdResponse = record
    Success: boolean;
    { ВАЖНО: объект живёт только внутри колбэка. Всё нужное копировать
      сразу, указатель наружу не сохранять. }
    Obj: TJSONObject;
    ErrorCode: integer;
    ErrorMessage: utf8string;
    { Произвольное значение, переданное при отправке. В FPC 3.2 нет
      анонимных функций, поэтому контекст запроса передаём так. }
    Tag: PtrInt;
  end;

  TTdResponseEvent = procedure(Sender: TObject; const AResp: TTdResponse) of object;

  { Одна запись об ожидающем ответа запросе. }
  TTdPending = class
  public
    Extra: string;
    Method: utf8string;
    Callback: TTdResponseEvent;
    Tag: PtrInt;
    Deadline: TDateTime;
  end;

  { TTdRequests

    Подписывается на ядро как ITdUpdateListener: ответы на запросы идут
    тем же потоком td_receive, что и апдейты. Наследник TComponent, а не
    TInterfacedObject, — чтобы интерфейс не был подсчётным и объект не
    самоуничтожился. }

  TTdRequests = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FSeq: integer;
    FPending: TStringList;
    FTimer: TTimer;
    FDefaultTimeout: integer;
    procedure CheckTimeouts(Sender: TObject);
    procedure Resolve(const AExtra: string; const AResp: TTdResponse);
    procedure FailAll(ACode: integer; const AMessage: utf8string);
    function TakePending(const AExtra: string): TTdPending;
  public
    { Резолвер принадлежит аккаунту: свой счётчик @extra, свои
      ожидающие запросы. Ответы чужих клиентов сюда не доходят —
      их отсекает приёмник по @client_id. }
    constructor Create(AOwner: TComponent; const ASession: ITdSession); reintroduce;
    destructor Destroy; override;

    { AMethod — имя метода TDLib, ABody — уже готовый кусок JSON без
      обрамляющих скобок, например '"chat_id":123,"limit":20'.
      ATimeoutMs = 0 берёт значение DefaultTimeout. }
    procedure SendRequest(const AMethod, ABody: utf8string;
      ACallback: TTdResponseEvent; ATag: PtrInt = 0; ATimeoutMs: integer = 0);

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property DefaultTimeout: integer read FDefaultTimeout write FDefaultTimeout;
    property PendingCount: integer read FSeq;
    property Session: ITdSession read FSession;
  end;

{ Хелперы чтения полей — те же, что в tdauth, но нужны и здесь. }
function JGetStr(AObj: TJSONObject; const AName: string): utf8string;
function JGetInt(AObj: TJSONObject; const AName: string): integer;
function JGetInt64(AObj: TJSONObject; const AName: string): Int64;
function JGetBool(AObj: TJSONObject; const AName: string): boolean;
function JGetObj(AObj: TJSONObject; const AName: string): TJSONObject;
function JGetArr(AObj: TJSONObject; const AName: string): TJSONArray;

implementation

{ ---------------- хелперы ---------------- }

function JGetStr(AObj: TJSONObject; const AName: string): utf8string;
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

function JGetInt(AObj: TJSONObject; const AName: string): integer;
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

function JGetInt64(AObj: TJSONObject; const AName: string): Int64;
var
  D: TJSONData;
begin
  { int64 в TDLib приходит СТРОКОЙ (order, file id большого размера
    и прочее), а int53 — числом. Поддерживаем оба варианта. }
  Result := 0;
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if D = nil then begin
    Exit;
  end;
  case D.JSONType of
    jtNumber: Result := D.AsInt64;
    jtString: if not TryStrToInt64(D.AsString, Result) then begin
                Result := 0;
              end;
  end;
end;

function JGetBool(AObj: TJSONObject; const AName: string): boolean;
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

function JGetObj(AObj: TJSONObject; const AName: string): TJSONObject;
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

function JGetArr(AObj: TJSONObject; const AName: string): TJSONArray;
var
  D: TJSONData;
begin
  Result := nil;
  if AObj = nil then begin
    Exit;
  end;
  D := AObj.Find(AName);
  if (D <> nil) and (D.JSONType = jtArray) then begin
    Result := TJSONArray(D);
  end;
end;

{ ---------------- TTdRequests ---------------- }

constructor TTdRequests.Create(AOwner: TComponent; const ASession: ITdSession);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FSeq := 0;
  FDefaultTimeout := 30000;

  FPending := TStringList.Create;
  FPending.Sorted := True;
  FPending.Duplicates := dupError;
  FPending.OwnsObjects := False;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := @CheckTimeouts;
  FTimer.Enabled := True;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdRequests.Destroy;
var
  I: integer;
begin
  FTimer.Enabled := False;
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  for I := 0 to FPending.Count - 1 do begin
    FPending.Objects[I].Free;
  end;
  FPending.Free;
  inherited Destroy;
end;

procedure TTdRequests.SendRequest(const AMethod, ABody: utf8string;
  ACallback: TTdResponseEvent; ATag: PtrInt; ATimeoutMs: integer);
var
  P: TTdPending;
  Req: utf8string;
  Ms: integer;
begin
  Inc(FSeq);

  Ms := ATimeoutMs;
  if Ms <= 0 then begin
    Ms := FDefaultTimeout;
  end;

  P := TTdPending.Create;
  P.Extra := REQ_PREFIX + IntToStr(FSeq);
  P.Method := AMethod;
  P.Callback := ACallback;
  P.Tag := ATag;
  P.Deadline := IncMilliSecond(Now, Ms);
  FPending.AddObject(P.Extra, P);

  Req := '{"@type":"' + AMethod + '"';
  if ABody <> '' then begin
    Req := Req + ',' + ABody;
  end;
  Req := Req + ',"@extra":"' + utf8string(P.Extra) + '"}';

  if FSession <> nil then begin
    FSession.Send(Req);
  end;
end;

function TTdRequests.TakePending(const AExtra: string): TTdPending;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FPending.IndexOf(AExtra);
  if Idx >= 0 then begin
    Result := TTdPending(FPending.Objects[Idx]);
    FPending.Delete(Idx);
  end;
end;

procedure TTdRequests.Resolve(const AExtra: string; const AResp: TTdResponse);
var
  P: TTdPending;
  R: TTdResponse;
begin
  P := TakePending(AExtra);
  if P = nil then begin
    Exit;
  end;
  try
    R := AResp;
    R.Tag := P.Tag;
    if Assigned(P.Callback) then begin
      P.Callback(Self, R);
    end;
  finally
    P.Free;
  end;
end;

procedure TTdRequests.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  Extra: string;
  Resp: TTdResponse;
begin
  { AData уже разобран приёмным потоком (tdrecv.pas) — раньше здесь
    был отдельный GetJSON именно этого ответа, и это была самая
    дорогая точка: getChatHistory возвращает пачки по полсотни
    сообщений с base64-превью, сотни КБ на ответ, а резолвер
    вызывался на главном потоке (см. HandleUpdate/DrainQueue). Теперь
    парсинг сделан один раз, до постановки в очередь на главный поток. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;

  Extra := string(JGetStr(Obj, '@extra'));
  if Pos(REQ_PREFIX, Extra) <> 1 then begin
    Exit;
  end;

  FillChar(Resp, SizeOf(Resp), 0);
  Resp.ErrorMessage := '';

  if JGetStr(Obj, '@type') = 'error' then begin
    Resp.Success := False;
    Resp.Obj := Obj;
    Resp.ErrorCode := JGetInt(Obj, 'code');
    Resp.ErrorMessage := JGetStr(Obj, 'message');
  end else begin
    Resp.Success := True;
    Resp.Obj := Obj;
  end;

  Resolve(Extra, Resp);
end;

procedure TTdRequests.TdStateChanged(AState: TTdAuthState);
begin
  { Клиент закрылся — все висящие запросы уже никогда не ответят. }
  if AState = tasClosed then begin
    FailAll(TD_ERR_CLOSED, 'client closed');
  end;
end;

procedure TTdRequests.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации нас не касаются: у них свой префикс @extra
    и свой владелец. }
end;

procedure TTdRequests.FailAll(ACode: integer; const AMessage: utf8string);
var
  Snap: array of TTdPending;
  I: integer;
  R: TTdResponse;
begin
  if FPending.Count = 0 then begin
    Exit;
  end;

  { Снимок и очистка ДО вызова колбэков: колбэк вправе отправить
    новый запрос, и он не должен попасть под эту же чистку. }
  SetLength(Snap, FPending.Count);
  for I := 0 to FPending.Count - 1 do begin
    Snap[I] := TTdPending(FPending.Objects[I]);
  end;
  FPending.Clear;

  for I := 0 to High(Snap) do begin
    FillChar(R, SizeOf(R), 0);
    R.Success := False;
    R.Obj := nil;
    R.ErrorCode := ACode;
    R.ErrorMessage := AMessage;
    R.Tag := Snap[I].Tag;
    if Assigned(Snap[I].Callback) then begin
      Snap[I].Callback(Self, R);
    end;
    Snap[I].Free;
  end;
end;

procedure TTdRequests.CheckTimeouts(Sender: TObject);
var
  Expired: array of TTdPending;
  I, N: integer;
  Nw: TDateTime;
  R: TTdResponse;
begin
  if FPending.Count = 0 then begin
    Exit;
  end;

  Nw := Now;
  SetLength(Expired, 0);
  N := 0;

  for I := FPending.Count - 1 downto 0 do begin
    if TTdPending(FPending.Objects[I]).Deadline < Nw then begin
      SetLength(Expired, N + 1);
      Expired[N] := TTdPending(FPending.Objects[I]);
      Inc(N);
      FPending.Delete(I);
    end;
  end;

  for I := 0 to High(Expired) do begin
    FillChar(R, SizeOf(R), 0);
    R.Success := False;
    R.Obj := nil;
    R.ErrorCode := TD_ERR_TIMEOUT;
    R.ErrorMessage := 'timeout: ' + Expired[I].Method;
    R.Tag := Expired[I].Tag;
    if Assigned(Expired[I].Callback) then begin
      Expired[I].Callback(Self, R);
    end;
    Expired[I].Free;
  end;
end;

end.
