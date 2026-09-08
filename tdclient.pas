unit tdclient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, tdjson, tdrecv;

type
  TTdUpdateEvent = procedure(Sender: TObject; const AJson: utf8string; AData: TJSONObject) of object;

  { TTdClient

    A thin wrapper around a single TDLib client_id. Does not own a
    thread: td_receive runs once per process, owned by TTdReceiver,
    which dispatches only the updates carrying this @client_id. This
    lets multiple clients coexist in one process without interfering
    with each other. }

  TTdClient = class
  private
    FClientId: integer;
    FActive: boolean;
    FOnUpdate: TTdUpdateEvent;
    procedure RawUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
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

constructor TTdClient.Create;
begin
  inherited Create;
  FClientId := 0;
  FActive := False;
end;

destructor TTdClient.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TTdClient.Start;
begin
  if FActive then begin
    Exit;
  end;

  FClientId := td_create_client_id;
  TdReceiver.RegisterClient(FClientId, @RawUpdate);
  TdReceiver.Start;

  { The client is not physically created until the first request is
    sent. getOption is the most harmless way to wake it up. }
  Send('{"@type":"getOption","name":"version"}');

  FActive := True;
end;

procedure TTdClient.Stop;
begin
  if FClientId <> 0 then begin
    if TdReceiverExists then begin
      TdReceiver.UnregisterClient(FClientId);
    end;
    FClientId := 0;
  end;
  FActive := False;
end;

procedure TTdClient.RawUpdate(Sender: TObject; const AJson: utf8string; AData: TJSONObject);
begin
  if Assigned(FOnUpdate) then begin
    FOnUpdate(Self, AJson, AData);
  end;
end;

procedure TTdClient.Send(const ARequest: utf8string);
begin
  if FClientId <> 0 then begin
    TdSend(FClientId, ARequest);
  end;
end;

function TTdClient.Execute(const ARequest: utf8string): utf8string;
begin
  Result := TdExecute(ARequest);
end;

end.
