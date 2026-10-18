unit tdcalls;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, fpjson,
  tdauth, tdsession, tdreq;

type
  { A call event: ACallId — which call changed (updateCall). }
  TTdCallEvent = procedure(Sender: TObject; ACallId: integer) of object;
  { Signalling data from the peer (updateNewCallSignalingData): AData —
    base64, as TDLib gives bytes in JSON. The page parses it — the
    encryption and the frames of the tgcalls protocol live there. }
  TTdCallSignalEvent = procedure(Sender: TObject; ACallId: integer;
    const AData: utf8string) of object;

  TCallMap = specialize TFPGMap<integer, TJSONObject>;

  { A group call (video chat) changed: updateGroupCall. }
  TTdGroupCallEvent = procedure(Sender: TObject; AGroupCallId: integer) of object;
  { A group call participant: AParticipant — a groupCallParticipant object
    (owned by the model; an empty order — the participant left, after the
    event they are forgotten). }
  TTdGroupParticipantEvent = procedure(Sender: TObject; AGroupCallId: integer;
    AParticipant: TJSONObject) of object;
  { A chat's video chat started/ended: updateChatVideoChat. AGroupCallId =
    0 — no video chat. }
  TTdChatVideoChatEvent = procedure(Sender: TObject; AChatId: Int64;
    AGroupCallId: integer; AHasParticipants: boolean) of object;

  { TTdCalls

    The account's private calls. TDLib does only the signalling part: the
    key exchange (DH), choosing the protocol version, the server list and
    relaying signalling data. Sound and video are not its business: the
    page runs them through WebRTC.

    The model keeps the latest call object (td_api.tl: call id user_id
    is_outgoing is_video state) for each call and reports changes. A
    discarded call (callStateDiscarded/Error) is reported and forgotten at
    once: there is nothing more to do with it. }
  TTdCalls = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq: TTdRequests;
    FAll: TCallMap;
    FOnChanged: TTdCallEvent;
    FOnSignal: TTdCallSignalEvent;
    { Group calls: id -> the latest groupCall; participants: call id ->
      an object "participant key -> groupCallParticipant" (the key —
      ParticipantKey). }
    FGroups: TCallMap;
    FParts: TCallMap;
    FOnGroup: TTdGroupCallEvent;
    FOnParticipant: TTdGroupParticipantEvent;
    FOnChatVideoChat: TTdChatVideoChatEvent;
    procedure ApplyCall(ACall: TJSONObject);
    procedure ApplyGroupCall(AGroup: TJSONObject);
    procedure ApplyParticipant(AGroupCallId: integer; APart: TJSONObject);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { The latest known call object; nil — no call (or discarded already).
      The object belongs to the model. }
    function Find(ACallId: integer): TJSONObject;
    function Count: integer;
    function CallAt(AIndex: integer): TJSONObject;

    { createCall — the answer is callId. }
    procedure StartCall(AUserId: Int64; AIsVideo: boolean;
      ACallback: TTdResponseEvent; ATag: PtrInt);
    procedure AcceptCall(ACallId: integer;
      ACallback: TTdResponseEvent; ATag: PtrInt);
    { ADuration — seconds of conversation (0 if they never connected);
      AConnectionId — the connection id from WebRTC, 0 — none. }
    procedure DiscardCall(ACallId: integer; ADisconnected: boolean;
      ADuration: integer; AIsVideo: boolean; AConnectionId: Int64;
      ACallback: TTdResponseEvent; ATag: PtrInt);
    { AData — base64 (as it comes from the page). }
    procedure SendSignal(ACallId: integer; const AData: utf8string;
      ACallback: TTdResponseEvent; ATag: PtrInt);

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    { A group call: the latest groupCall or nil. }
    function FindGroup(AGroupCallId: integer): TJSONObject;
    { The call's participants: an object "key -> groupCallParticipant" or nil. }
    function GroupParticipants(AGroupCallId: integer): TJSONObject;
    { Forget the call's participants (we left it — the list no longer
      updates, and on a new join it comes again). }
    procedure DropParticipants(AGroupCallId: integer);

    property OnChanged: TTdCallEvent read FOnChanged write FOnChanged;
    property OnSignal: TTdCallSignalEvent read FOnSignal write FOnSignal;
    property OnGroup: TTdGroupCallEvent read FOnGroup write FOnGroup;
    property OnParticipant: TTdGroupParticipantEvent read FOnParticipant write FOnParticipant;
    property OnChatVideoChat: TTdChatVideoChatEvent read FOnChatVideoChat write FOnChatVideoChat;
  end;

{ The key of a group call participant by participant_id (MessageSender):
  'u<id>' a person, 'c<id>' a chat; '' — cannot be parsed. }
function ParticipantKey(ASender: TJSONObject): utf8string;

{ callProtocol for createCall/acceptCall (CALL_* in constants.pas). }
function CallProtocolJson: utf8string;

implementation

uses
  constants;

function CallProtocolJson: utf8string;
var
  I: integer;
  Versions: utf8string;
begin
  Versions := '';
  for I := 0 to High(CALL_LIBRARY_VERSIONS) do begin
    if I > 0 then begin
      Versions := Versions + ',';
    end;
    Versions := Versions + '"' + CALL_LIBRARY_VERSIONS[I] + '"';
  end;
  Result := '{"@type":"callProtocol","udp_p2p":true,"udp_reflector":true,'
    + '"min_layer":' + utf8string(IntToStr(CALL_MIN_LAYER))
    + ',"max_layer":' + utf8string(IntToStr(CALL_MAX_LAYER))
    + ',"library_versions":[' + Versions + ']}';
end;

constructor TTdCalls.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TCallMap.Create;
  FAll.Sorted := True;
  FGroups := TCallMap.Create;
  FGroups.Sorted := True;
  FParts := TCallMap.Create;
  FParts.Sorted := True;
  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdCalls.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FAll.Free;
  FGroups.Free;
  FParts.Free;
  inherited Destroy;
end;

procedure TTdCalls.Clear;
var
  I: integer;
begin
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  for I := 0 to FGroups.Count - 1 do begin
    FGroups.Data[I].Free;
  end;
  FGroups.Clear;
  for I := 0 to FParts.Count - 1 do begin
    FParts.Data[I].Free;
  end;
  FParts.Clear;
end;

function ParticipantKey(ASender: TJSONObject): utf8string;
var
  Kind: utf8string;
begin
  Result := '';
  Kind := JGetStr(ASender, '@type');
  if Kind = 'messageSenderUser' then begin
    Result := 'u' + utf8string(IntToStr(JGetInt64(ASender, 'user_id')));
  end else if Kind = 'messageSenderChat' then begin
    Result := 'c' + utf8string(IntToStr(JGetInt64(ASender, 'chat_id')));
  end;
end;

function TTdCalls.FindGroup(AGroupCallId: integer): TJSONObject;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FGroups.IndexOf(AGroupCallId);
  if Idx >= 0 then begin
    Result := FGroups.Data[Idx];
  end;
end;

function TTdCalls.GroupParticipants(AGroupCallId: integer): TJSONObject;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FParts.IndexOf(AGroupCallId);
  if Idx >= 0 then begin
    Result := FParts.Data[Idx];
  end;
end;

procedure TTdCalls.DropParticipants(AGroupCallId: integer);
var
  Idx: integer;
begin
  Idx := FParts.IndexOf(AGroupCallId);
  if Idx >= 0 then begin
    FParts.Data[Idx].Free;
    FParts.Delete(Idx);
  end;
end;

procedure TTdCalls.ApplyGroupCall(AGroup: TJSONObject);
var
  Id, Idx: integer;
begin
  if AGroup = nil then begin
    Exit;
  end;
  Id := JGetInt(AGroup, 'id');
  Idx := FGroups.IndexOf(Id);
  if Idx >= 0 then begin
    FGroups.Data[Idx].Free;
    FGroups.Data[Idx] := TJSONObject(AGroup.Clone);
  end else begin
    FGroups.Add(Id, TJSONObject(AGroup.Clone));
  end;
  if Assigned(FOnGroup) then begin
    FOnGroup(Self, Id);
  end;
end;

procedure TTdCalls.ApplyParticipant(AGroupCallId: integer; APart: TJSONObject);
var
  Idx, K: integer;
  Key: utf8string;
  Map, Kept: TJSONObject;
begin
  if APart = nil then begin
    Exit;
  end;
  Key := ParticipantKey(JGetObj(APart, 'participant_id'));
  if Key = '' then begin
    Exit;
  end;
  Idx := FParts.IndexOf(AGroupCallId);
  if Idx >= 0 then begin
    Map := FParts.Data[Idx];
  end else begin
    Map := TJSONObject.Create;
    FParts.Add(AGroupCallId, Map);
  end;
  K := Map.IndexOfName(string(Key));
  if K >= 0 then begin
    Map.Delete(K);
  end;
  Kept := TJSONObject(APart.Clone);
  Map.Add(string(Key), Kept);
  if Assigned(FOnParticipant) then begin
    FOnParticipant(Self, AGroupCallId, Kept);
  end;
  { An empty order — the participant left: reported and forgotten. }
  if JGetStr(APart, 'order') = '' then begin
    K := Map.IndexOfName(string(Key));
    if K >= 0 then begin
      Map.Delete(K);
    end;
  end;
end;

function TTdCalls.Find(ACallId: integer): TJSONObject;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(ACallId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdCalls.Count: integer;
begin
  Result := FAll.Count;
end;

function TTdCalls.CallAt(AIndex: integer): TJSONObject;
begin
  Result := FAll.Data[AIndex];
end;

procedure TTdCalls.ApplyCall(ACall: TJSONObject);
var
  Id, Idx: integer;
  Kind: utf8string;
begin
  if ACall = nil then begin
    Exit;
  end;
  Id := JGetInt(ACall, 'id');
  Idx := FAll.IndexOf(Id);
  if Idx >= 0 then begin
    FAll.Data[Idx].Free;
    FAll.Data[Idx] := TJSONObject(ACall.Clone);
  end else begin
    FAll.Add(Id, TJSONObject(ACall.Clone));
  end;
  if Assigned(FOnChanged) then begin
    FOnChanged(Self, Id);
  end;
  { A discarded call is reported — and forgotten. Find after the event returns nil. }
  Kind := JGetStr(JGetObj(ACall, 'state'), '@type');
  if (Kind = 'callStateDiscarded') or (Kind = 'callStateError') then begin
    Idx := FAll.IndexOf(Id);
    if Idx >= 0 then begin
      FAll.Data[Idx].Free;
      FAll.Delete(Idx);
    end;
  end;
end;

procedure TTdCalls.StartCall(AUserId: Int64; AIsVideo: boolean;
  ACallback: TTdResponseEvent; ATag: PtrInt);
const
  B: array[boolean] of utf8string = ('false', 'true');
begin
  if FReq = nil then begin
    Exit;
  end;
  FReq.SendRequest('createCall', '"user_id":' + utf8string(IntToStr(AUserId))
    + ',"protocol":' + CallProtocolJson + ',"is_video":' + B[AIsVideo],
    ACallback, ATag);
end;

procedure TTdCalls.AcceptCall(ACallId: integer;
  ACallback: TTdResponseEvent; ATag: PtrInt);
begin
  if FReq = nil then begin
    Exit;
  end;
  FReq.SendRequest('acceptCall', '"call_id":' + utf8string(IntToStr(ACallId))
    + ',"protocol":' + CallProtocolJson, ACallback, ATag);
end;

procedure TTdCalls.DiscardCall(ACallId: integer; ADisconnected: boolean;
  ADuration: integer; AIsVideo: boolean; AConnectionId: Int64;
  ACallback: TTdResponseEvent; ATag: PtrInt);
const
  B: array[boolean] of utf8string = ('false', 'true');
begin
  if FReq = nil then begin
    Exit;
  end;
  FReq.SendRequest('discardCall', '"call_id":' + utf8string(IntToStr(ACallId))
    + ',"is_disconnected":' + B[ADisconnected]
    + ',"invite_link":""'
    + ',"duration":' + utf8string(IntToStr(ADuration))
    + ',"is_video":' + B[AIsVideo]
    + ',"connection_id":' + utf8string(IntToStr(AConnectionId)),
    ACallback, ATag);
end;

procedure TTdCalls.SendSignal(ACallId: integer; const AData: utf8string;
  ACallback: TTdResponseEvent; ATag: PtrInt);
var
  I: integer;
begin
  if FReq = nil then begin
    Exit;
  end;
  { base64 from the page goes into the JSON as is — a check that it holds
    only the base64 alphabet, instead of escaping. }
  for I := 1 to Length(AData) do begin
    if not (AData[I] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=']) then begin
      Exit;
    end;
  end;
  FReq.SendRequest('sendCallSignalingData', '"call_id":'
    + utf8string(IntToStr(ACallId)) + ',"data":"' + AData + '"',
    ACallback, ATag);
end;

procedure TTdCalls.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Kind: utf8string;
begin
  if AData = nil then begin
    Exit;
  end;
  Kind := JGetStr(AData, '@type');
  if Kind = 'updateCall' then begin
    ApplyCall(JGetObj(AData, 'call'));
  end else if Kind = 'updateGroupCall' then begin
    ApplyGroupCall(JGetObj(AData, 'group_call'));
  end else if Kind = 'updateGroupCallParticipant' then begin
    ApplyParticipant(JGetInt(AData, 'group_call_id'), JGetObj(AData, 'participant'));
  end else if Kind = 'updateChatVideoChat' then begin
    if Assigned(FOnChatVideoChat) then begin
      FOnChatVideoChat(Self, JGetInt64(AData, 'chat_id'),
        JGetInt(JGetObj(AData, 'video_chat'), 'group_call_id'),
        JGetBool(JGetObj(AData, 'video_chat'), 'has_participants'));
    end;
  end else if Kind = 'updateNewCallSignalingData' then begin
    if Assigned(FOnSignal) then begin
      FOnSignal(Self, JGetInt(AData, 'call_id'), JGetStr(AData, 'data'));
    end;
  end;
end;

procedure TTdCalls.TdStateChanged(AState: TTdAuthState);
begin
  if TdIsShuttingState(AState) then begin
    Clear;
  end;
end;

procedure TTdCalls.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors do not concern this model. }
end;

end.
