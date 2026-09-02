unit tdrecv;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, constants, tdjson;

type
  { AData — результат разбора AJson, сделанного ЗДЕСЬ, в приёмном
    потоке (см. TTdReceiveThread.Execute), а не на главном потоке
    каждым подписчиком по отдельности, как было раньше. Владеет
    объектом tdrecv: он освобождается в DrainQueue сразу после вызова
    обработчика, поэтому AData за пределами TTdRawEvent невалиден —
    сохранять указатель нельзя. AData = nil, если строка не
    распарсилась или разобралась не в объект. }
  TTdRawEvent = procedure(Sender: TObject; const AJson: utf8string; AData: TJSONObject) of object;

  TTdReceiver = class;

  TTdReceiveThread = class(TThread)
  private
    FOwner: TTdReceiver;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTdReceiver);
  end;

  { TTdReceiver

    Один на процесс. Документация TDLib прямо запрещает вызывать
    td_receive одновременно из двух потоков, а апдейты всех клиентов
    приходят единым потоком и различаются полем @client_id.
    Поэтому поток здесь ровно один, а раздачей занимается диспетчер.

    Полный разбор JSON (GetJSON) тоже выполняется в этом потоке — он
    простаивает почти всё время внутри td_receive с таймаутом, так что
    лишней нагрузки на отзывчивость UI это не создаёт. Раньше каждый
    подписчик (TTdChats/TTdMessages/TTdRequests/...) парсил сырую
    строку заново уже на главном потоке — для мелких апдейтов
    незаметно, но getChatHistory с полусотней сообщений и base64
    мини-превью в каждом — это сотни КБ JSON, и синхронный парс такого
    на главном потоке ощутимо подвешивал интерфейс. }

  TTdReceiver = class
  private
    FThread: TTdReceiveThread;
    FLock: TCriticalSection;
    FQueueJson: array of utf8string;
    FQueueData: array of TJSONObject;
    FQueueId: array of integer;
    FQueueCount: integer;
    FHandlerId: array of integer;
    FHandler: array of TTdRawEvent;
    FActive: boolean;
    procedure PushUpdate(AClientId: integer; const AJson: utf8string; AData: TJSONObject);
    procedure DrainQueue;              { выполняется в главном потоке }
    function FindHandler(AClientId: integer; out AEvent: TTdRawEvent): boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { Клиент заявляет о себе сразу после td_create_client_id. }
    procedure RegisterClient(AClientId: integer; AHandler: TTdRawEvent);
    procedure UnregisterClient(AClientId: integer);

    property Active: boolean read FActive;
  end;

{ Синглтон. Имя отличается от имени юнита сознательно. }
function TdReceiver: TTdReceiver;
function TdReceiverExists: boolean;

{ Выдирает @client_id из сырого JSON без полного разбора.
  Полный парсинг тут недопустим: апдейтов идут тысячи, а подписчики
  и так отсеивают ненужное дешёвыми проверками по строке. }
function ExtractClientId(const AJson: utf8string): integer;

implementation

var
  GRecv: TTdReceiver = nil;

function TdReceiver: TTdReceiver;
begin
  if GRecv = nil then begin
    GRecv := TTdReceiver.Create;
  end;
  Result := GRecv;
end;

function TdReceiverExists: boolean;
begin
  Result := GRecv <> nil;
end;

function ExtractClientId(const AJson: utf8string): integer;
var
  P, I, L: integer;
  V: integer;
  Neg: boolean;
begin
  Result := 0;
  P := Pos(CLIENT_ID_TAG, AJson);
  if P = 0 then begin
    Exit;
  end;

  I := P + Length(CLIENT_ID_TAG);
  L := Length(AJson);
  { пробелы после двоеточия допустимы по JSON }
  while (I <= L) and (AJson[I] = ' ') do begin
    Inc(I);
  end;

  Neg := False;
  if (I <= L) and (AJson[I] = '-') then begin
    Neg := True;
    Inc(I);
  end;

  V := 0;
  while (I <= L) and (AJson[I] >= '0') and (AJson[I] <= '9') do begin
    V := V * 10 + (Ord(AJson[I]) - Ord('0'));
    Inc(I);
  end;

  if Neg then begin
    Result := -V;
  end else begin
    Result := V;
  end;
end;

{ ---------------- TTdReceiveThread ---------------- }

constructor TTdReceiveThread.Create(AOwner: TTdReceiver);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TTdReceiveThread.Execute;
var
  S: utf8string;
  Data: TJSONData;
begin
  while not Terminated do begin
    S := TdReceive(RECEIVE_TIMEOUT);
    if Terminated then begin
      Break;
    end;
    if S <> '' then begin
      { Разбор — здесь, не на главном потоке. Ошибка парсинга или
        JSON не-объект — не наша забота, подписчики уже умеют
        обрабатывать AData = nil (см. комментарий у TTdRawEvent). }
      Data := nil;
      try
        Data := GetJSON(string(S));
      except
        Data := nil;
      end;
      if (Data <> nil) and (Data.JSONType <> jtObject) then begin
        Data.Free;
        Data := nil;
      end;
      FOwner.PushUpdate(ExtractClientId(S), S, TJSONObject(Data));
    end;
  end;
end;

{ ---------------- TTdReceiver ---------------- }

constructor TTdReceiver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FQueueCount := 0;
  SetLength(FQueueJson, 32);
  SetLength(FQueueData, 32);
  SetLength(FQueueId, 32);
  FActive := False;
end;

destructor TTdReceiver.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

procedure TTdReceiver.Start;
begin
  if FActive then begin
    Exit;
  end;
  FThread := TTdReceiveThread.Create(Self);
  FActive := True;
  { Поток запускается только после присваивания FThread: иначе он
    успеет позвать PushUpdate раньше и TThread.Queue получит nil. }
  FThread.Start;
end;

procedure TTdReceiver.Stop;
var
  I: integer;
begin
  if FThread <> nil then begin
    FThread.Terminate;
    FThread.WaitFor;              { до RECEIVE_TIMEOUT секунд }
    TThread.RemoveQueuedEvents(FThread);
    FreeAndNil(FThread);
  end;
  FLock.Enter;
  try
    { RemoveQueuedEvents отменил DrainQueue, если он ещё не выполнился
      — разобранные объекты в очереди остались бы без хозяина. }
    for I := 0 to FQueueCount - 1 do begin
      FQueueData[I].Free;
      FQueueData[I] := nil;
    end;
    FQueueCount := 0;
  finally
    FLock.Leave;
  end;
  FActive := False;
end;

procedure TTdReceiver.RegisterClient(AClientId: integer; AHandler: TTdRawEvent);
var
  I: integer;
begin
  FLock.Enter;
  try
    for I := 0 to High(FHandlerId) do begin
      if FHandlerId[I] = AClientId then begin
        FHandler[I] := AHandler;
        Exit;
      end;
    end;
    SetLength(FHandlerId, Length(FHandlerId) + 1);
    SetLength(FHandler, Length(FHandler) + 1);
    FHandlerId[High(FHandlerId)] := AClientId;
    FHandler[High(FHandler)] := AHandler;
  finally
    FLock.Leave;
  end;
end;

procedure TTdReceiver.UnregisterClient(AClientId: integer);
var
  I, J: integer;
begin
  FLock.Enter;
  try
    for I := High(FHandlerId) downto 0 do begin
      if FHandlerId[I] = AClientId then begin
        for J := I to High(FHandlerId) - 1 do begin
          FHandlerId[J] := FHandlerId[J + 1];
          FHandler[J] := FHandler[J + 1];
        end;
        SetLength(FHandlerId, Length(FHandlerId) - 1);
        SetLength(FHandler, Length(FHandler) - 1);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TTdReceiver.FindHandler(AClientId: integer; out AEvent: TTdRawEvent): boolean;
var
  I: integer;
begin
  Result := False;
  AEvent := nil;
  FLock.Enter;
  try
    for I := 0 to High(FHandlerId) do begin
      if FHandlerId[I] = AClientId then begin
        AEvent := FHandler[I];
        Result := Assigned(AEvent);
        Exit;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TTdReceiver.PushUpdate(AClientId: integer; const AJson: utf8string;
  AData: TJSONObject);
begin
  if (FThread = nil) or FThread.Terminated then begin
    { Обработчиков уже не будет — объект достался бы никому. }
    AData.Free;
    Exit;
  end;

  FLock.Enter;
  try
    if FQueueCount >= Length(FQueueJson) then begin
      SetLength(FQueueJson, Length(FQueueJson) * 2);
      SetLength(FQueueData, Length(FQueueData) * 2);
      SetLength(FQueueId, Length(FQueueId) * 2);
    end;
    FQueueJson[FQueueCount] := AJson;
    FQueueData[FQueueCount] := AData;
    FQueueId[FQueueCount] := AClientId;
    Inc(FQueueCount);
  finally
    FLock.Leave;
  end;

  TThread.Queue(FThread, @DrainQueue);
end;

procedure TTdReceiver.DrainQueue;
var
  BatchJson: array of utf8string;
  BatchData: array of TJSONObject;
  BatchId: array of integer;
  I, N: integer;
  H: TTdRawEvent;
begin
  FLock.Enter;
  try
    N := FQueueCount;
    if N = 0 then begin
      Exit;
    end;
    SetLength(BatchJson, N);
    SetLength(BatchData, N);
    SetLength(BatchId, N);
    for I := 0 to N - 1 do begin
      BatchJson[I] := FQueueJson[I];
      BatchData[I] := FQueueData[I];
      BatchId[I] := FQueueId[I];
      FQueueJson[I] := '';
      FQueueData[I] := nil;
    end;
    FQueueCount := 0;
  finally
    FLock.Leave;
  end;

  { Секция отпущена до вызова обработчиков: иначе приёмный поток
    вставал бы на ней всё время разбора апдейта. Разобранный объект —
    общий для всех подписчиков этого client_id (см. TTdAccount.
    HandleUpdate), владеет им tdrecv: освобождаем сразу после вызова
    обработчика, подписчикам сохранять указатель за пределы вызова
    нельзя (см. комментарий у TTdRawEvent). }
  for I := 0 to N - 1 do begin
    if FindHandler(BatchId[I], H) then begin
      H(Self, BatchJson[I], BatchData[I]);
    end;
    BatchData[I].Free;
  end;
end;

initialization

finalization
  FreeAndNil(GRecv);

end.
