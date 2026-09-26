unit tdsupergroups;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, fpjson,
  tdauth, tdsession, tdreq;

type
  { TSupergroupRow

    Whether the CURRENT ACCOUNT can post here, derived from
    supergroup.status (the viewer's OWN membership status — NOT
    anything about other members). Has no reference to LCL, same as
    TChatRow/TMsgRow/TUserRow. }
  TSupergroupRow = class
  public
    Id: Int64;
    { Only meaningful when Definite is True — see its own comment. }
    CanSend: boolean;
    { supergroup.join_to_send_messages: "users need to join the
      supergroup before they can send messages". Together with IsMember
      this is the difference between "you may not write here" and "you
      may, once you join" - which is what a discussion group under a
      channel usually asks for, and what the official clients answer
      with a join button rather than a dead input box. }
    JoinToSend:  boolean;
    { join_by_request: joining needs an administrator's approval, so
      the wording is "apply" rather than "join". }
    JoinByRequest: boolean;
    { Derived from the same status this row already reads. }
    IsMember:    boolean;
    { True when CanSend was derived from an EXPLICIT personal signal
      (being the creator, an administrator's own posting rights, a
      Restricted member's own permissions override, or not being a
      member at all) that should WIN over chat.permissions.
      can_send_basic_messages (TChatRow, tdchats.pas) — that field
      describes what an ORDINARY member may do, and says nothing about
      the viewer's own admin/creator status, which TDLib doesn't fold
      into the chat object at all (the only place it appears is this
      per-supergroup status). False means no personal override is
      known (a plain Member, or the status hasn't loaded yet) — the
      caller should fall back to chat.permissions in that case, not
      treat CanSend as a real answer. }
    Definite: boolean;
  end;

  TSupergroupMap = specialize TFPGMap<Int64, TSupergroupRow>;

  TTdSupergroupsEvent = procedure(Sender: TObject) of object;

  { TTdSupergroups

    Cache of "does the viewer's own status override chat.permissions"
    for supergroups/channels, keyed by supergroup_id (NOT chat_id —
    chatTypeSupergroup.supergroup_id is what this whole model, and
    TDLib's own updateSupergroup, use). Populated passively from
    updateSupergroup (the update stream already carries this — same
    idea as TTdUsers/tdusers.pas listening to updateUser), and on a
    cache miss, actively backfilled via getSupergroup, same "fetch
    asynchronously, redraw once ready" pattern as TTdUsers/
    avatarcache.pas. }
  TTdSupergroups = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq: TTdRequests;
    FAll: TSupergroupMap;
    { Ids of supergroups for which getSupergroup has already been sent
      and a response is pending — avoids flooding TDLib with repeat
      requests on every redraw of the same still-unresolved row. }
    FPending: array of Int64;
    FOnChanged: TTdSupergroupsEvent;
    function Lookup(AId: Int64): TSupergroupRow;
    function IsPending(AId: Int64): boolean;
    procedure MarkPending(AId: Int64);
    procedure ClearPending(AId: Int64);
    procedure ApplyGroup(AGroup: TJSONObject);
    procedure RequestGroup(AId: Int64);
    procedure GetSupergroupDone(Sender: TObject; const AResp: TTdResponse);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { True and ACanSend meaningful only when the viewer's own status
      gives a DEFINITE answer that should override chat.permissions —
      see TSupergroupRow.Definite's own comment. False (ACanSend
      undefined) means "no override, use chat.permissions" — this
      also covers AId=0 and a not-yet-cached id, which additionally
      issues getSupergroup asynchronously (the real answer, once
      known, arrives later via OnChanged). }
    function OverridesPermissions(AId: Int64; out ACanSend: boolean): boolean;
    { "You cannot write here YET": the group asks people to join first
      and this account has not. AByRequest says whether joining needs
      approval, which is the difference between "Join" and "Apply to
      join" in the wording. False when the group is unknown - saying
      "you must join" about a group whose status has not loaded would
      be a guess. }
    function MustJoinToSend(AId: Int64; out AByRequest: boolean): boolean;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property OnChanged: TTdSupergroupsEvent read FOnChanged write FOnChanged;
  end;

implementation

{ ---------------- TTdSupergroups ---------------- }

constructor TTdSupergroups.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TSupergroupMap.Create;
  FAll.Sorted := True;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdSupergroups.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdSupergroups.Clear;
var
  I: integer;
begin
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  SetLength(FPending, 0);
end;

function TTdSupergroups.Lookup(AId: Int64): TSupergroupRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdSupergroups.IsPending(AId: Int64): boolean;
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

procedure TTdSupergroups.MarkPending(AId: Int64);
begin
  SetLength(FPending, Length(FPending) + 1);
  FPending[High(FPending)] := AId;
end;

procedure TTdSupergroups.ClearPending(AId: Int64);
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

{ Derives CanSend/Definite from supergroup.status + is_channel —
  verified against real payloads in tdlib_raw.log (chatMemberStatus
  Creator/Administrator/Member/Restricted/Left, all seen live for real
  accounts/channels), not guessed:
    - Creator: always a definite True.
    - Administrator: for a channel, definite, following rights.
      can_post_messages (an admin without post rights genuinely can't
      post to a channel either); for an ordinary (non-channel)
      supergroup, definite True unconditionally — admins aren't
      subject to the chat-wide member permissions there either.
    - Restricted: carries its OWN per-member permissions override,
      more specific than the chat-wide default — definite, using it
      directly if is_member, else definite False (not actually in the
      chat despite the status existing).
    - Left/Banned: definite False outright, regardless of anything
      else.
    - Member, or any other/unrecognized status: NOT definite — a plain
      member has no override, chat.permissions is what actually
      decides for them. }
procedure TTdSupergroups.ApplyGroup(AGroup: TJSONObject);
var
  Id: Int64;
  IsChannel: boolean;
  StatusObj, RightsObj, PermObj: TJSONObject;
  StatusType: utf8string;
  Row: TSupergroupRow;
  Idx: integer;
  NewCanSend, NewDefinite: boolean;
  NewJoinToSend, NewJoinByRequest, NewIsMember: boolean;
begin
  if AGroup = nil then begin
    Exit;
  end;
  Id := JGetInt64(AGroup, 'id');
  if Id = 0 then begin
    Exit;
  end;
  IsChannel := JGetBool(AGroup, 'is_channel');
  StatusObj := JGetObj(AGroup, 'status');
  StatusType := JGetStr(StatusObj, '@type');
  NewJoinToSend := JGetBool(AGroup, 'join_to_send_messages');
  NewJoinByRequest := JGetBool(AGroup, 'join_by_request');
  { Restricted carries its own is_member; the rest say membership by
    their very name. }
  if StatusType = 'chatMemberStatusRestricted' then begin
    NewIsMember := JGetBool(StatusObj, 'is_member')
  end else begin
    NewIsMember := (StatusType = 'chatMemberStatusCreator')
      or (StatusType = 'chatMemberStatusAdministrator')
      or (StatusType = 'chatMemberStatusMember');
  end;

  NewDefinite := True;
  if StatusType = 'chatMemberStatusCreator' then begin
    NewCanSend := True;
  end else if StatusType = 'chatMemberStatusAdministrator' then begin
    if IsChannel then begin
      RightsObj := JGetObj(StatusObj, 'rights');
      NewCanSend := JGetBool(RightsObj, 'can_post_messages');
    end else begin
      NewCanSend := True;
    end;
  end else if StatusType = 'chatMemberStatusRestricted' then begin
    if JGetBool(StatusObj, 'is_member') then begin
      PermObj := JGetObj(StatusObj, 'permissions');
      NewCanSend := JGetBool(PermObj, 'can_send_basic_messages');
    end else begin
      NewCanSend := False;
    end;
  end else if (StatusType = 'chatMemberStatusLeft') or (StatusType = 'chatMemberStatusBanned') then begin
    NewCanSend := False;
  end else begin
    { chatMemberStatusMember, or anything unrecognized. }
    NewCanSend := False;
    NewDefinite := False;
  end;

  Idx := FAll.IndexOf(Id);
  if Idx >= 0 then begin
    Row := FAll.Data[Idx];
  end else begin
    Row := TSupergroupRow.Create;
    Row.Id := Id;
    FAll.Add(Id, Row);
  end;
  Row.CanSend := NewCanSend;
  Row.Definite := NewDefinite;
  Row.JoinToSend := NewJoinToSend;
  Row.JoinByRequest := NewJoinByRequest;
  Row.IsMember := NewIsMember;

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

function TTdSupergroups.MustJoinToSend(AId: Int64; out AByRequest: boolean): boolean;
var
  Row: TSupergroupRow;
begin
  AByRequest := False;
  Row := Lookup(AId);
  if Row = nil then begin
    Exit(False);
  end;
  AByRequest := Row.JoinByRequest;
  Result := Row.JoinToSend and (not Row.IsMember);
end;

procedure TTdSupergroups.RequestGroup(AId: Int64);
begin
  if (FReq = nil) or IsPending(AId) then begin
    Exit;
  end;
  MarkPending(AId);
  FReq.SendRequest('getSupergroup', '"supergroup_id":' + utf8string(IntToStr(AId)),
    @GetSupergroupDone, PtrInt(AId));
end;

procedure TTdSupergroups.GetSupergroupDone(Sender: TObject; const AResp: TTdResponse);
begin
  { Clears pending by Tag (the id actually requested), not by an id
    from the response body — on error the body may be absent
    entirely, and without this the row would stay marked "in flight"
    forever, blocking a retry on the next redraw — same reasoning as
    TTdUsers.GetUserDone (tdusers.pas). }
  ClearPending(Int64(AResp.Tag));
  if AResp.Success then begin
    ApplyGroup(AResp.Obj);
  end;
end;

function TTdSupergroups.OverridesPermissions(AId: Int64; out ACanSend: boolean): boolean;
var
  Row: TSupergroupRow;
begin
  Result := False;
  ACanSend := False;
  if AId = 0 then begin
    Exit;
  end;
  Row := Lookup(AId);
  if Row <> nil then begin
    Result := Row.Definite;
    ACanSend := Row.CanSend;
    Exit;
  end;
  RequestGroup(AId);
end;

procedure TTdSupergroups.TdUpdate(const AJson: utf8string; AData: TJSONObject);
begin
  if AData = nil then begin
    Exit;
  end;
  if JGetStr(AData, '@type') = 'updateSupergroup' then begin
    ApplyGroup(JGetObj(AData, 'supergroup'));
  end;
end;

procedure TTdSupergroups.TdStateChanged(AState: TTdAuthState);
begin
  { On logout/shutdown the cache is no longer meaningful, same as the
    other per-account models. }
  if TdIsShuttingState(AState) then begin
    Clear;
  end;
end;

procedure TTdSupergroups.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors don't concern this model. }
end;

end.
