unit tdclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, tdjson;

type
  TTdUpdateEvent = procedure(Sender: TObject; const AJson: utf8string) of object;

  TTdClient = class;

  { Единственный поток-приёмник на весь процесс. }
  TTdReceiveThread = class(TThread)
  private
    FOwner: TTdClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTdClient);
  end;

  TTdClient = class
  private
    FClientId:   integer;
    FThread:     TTdReceiveThread;
    FLock:       TCriticalSection;
    FQueue:      array of utf8string;
    FQueueCount: integer;
    FOnUpdate:   TTdUpdateEvent;
    FActive:     boolean;
    procedure PushUpdate(const AJson: utf8string);
    procedure DrainQueue;   // выполняется в главном потоке
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;
    procedure Send(const ARequest: utf8string);
    function Execute(const ARequest: utf8string): utf8string;

    property ClientId: integer read FClientId;
    property Active: boolean read FActive;
    property OnUpdate: TTdUpdateEvent read FOnUpdate write FOnUpdate;
  end;

implementation

const
  RECEIVE_TIMEOUT = 1.0;

  { ---------------- TTdReceiveThread ---------------- }

constructor TTdReceiveThread.Create(AOwner: TTdClient);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(True);   { создаём приостановленным }
end;

procedure TTdReceiveThread.Execute;
var
  S: utf8string;
begin
  while not Terminated do begin
    S := TdReceive(RECEIVE_TIMEOUT);
    if Terminated then begin
      Break;
    end;
    if S <> '' then begin
      FOwner.PushUpdate(S);
    end;
  end;
end;

{ ---------------- TTdClient ---------------- }

constructor TTdClient.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FClientId := 0;
  FQueueCount := 0;
  SetLength(FQueue, 32);
  FActive := False;
end;

destructor TTdClient.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

procedure TTdClient.Start;
begin
  if FActive then begin
    Exit;
  end;

  FClientId := td_create_client_id;
  { Клиент не создаётся физически, пока не отправлен первый запрос.
    getOption — самый безобидный способ его «разбудить». }
  Send('{"@type":"getOption","name":"version"}');

  FThread := TTdReceiveThread.Create(Self);
  FActive := True;
  FThread.Start;            { запускаем только после присваивания FThread }
end;

procedure TTdClient.Stop;
begin
  if FThread <> nil then begin
    FThread.Terminate;
    FThread.WaitFor;          { до RECEIVE_TIMEOUT секунд }
    TThread.RemoveQueuedEvents(FThread);
    FreeAndNil(FThread);
  end;
  FLock.Enter;
  try
    FQueueCount := 0;
  finally
    FLock.Leave;
  end;
  FActive := False;
end;

procedure TTdClient.Send(const ARequest: utf8string);
begin
  TdSend(FClientId, ARequest);
end;

function TTdClient.Execute(const ARequest: utf8string): utf8string;
begin
  Result := TdExecute(ARequest);
end;

procedure TTdClient.PushUpdate(const AJson: utf8string);
begin
  if (FThread = nil) or FThread.Terminated then begin
    Exit;
  end;

  FLock.Enter;
  try
    if FQueueCount >= Length(FQueue) then begin
      SetLength(FQueue, Length(FQueue) * 2);
    end;
    FQueue[FQueueCount] := AJson;
    Inc(FQueueCount);
  finally
    FLock.Leave;
  end;
  TThread.Queue(FThread, @DrainQueue);
end;

procedure TTdClient.DrainQueue;
var
  Batch: array of utf8string;
  I, N:  integer;
begin
  FLock.Enter;
  try
    N := FQueueCount;
    if N = 0 then begin
      Exit;
    end;
    SetLength(Batch, N);
    for I := 0 to N - 1 do begin
      Batch[I]  := FQueue[I];
      FQueue[I] := '';
    end;
    FQueueCount := 0;
  finally
    FLock.Leave;
  end;

  if Assigned(FOnUpdate) then begin
    for I := 0 to N - 1 do begin
      FOnUpdate(Self, Batch[I]);
    end;
  end;
end;

end.
