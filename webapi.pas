unit webapi;

{$mode objfpc}{$H+}

{ The bridge between the loopback socket (localserver.pas) and the
  model. Commands arrive as JSON text frames, answers and events go
  back the same way.

  THE ONE RULE THIS UNIT EXISTS TO ENFORCE: the model is single
  threaded and lives on the main thread behind its own coalescing
  timers. A socket thread must never touch it. So SocketMessage (which
  runs on the socket thread) does nothing but copy the text into a
  queue, and a timer on the main thread drains that queue and does the
  actual work. A TTimer rather than TThread.Synchronize/Queue on
  purpose: this project has already been bitten by a decoder thread
  blocked inside its own Synchronize while the main thread waited on
  it, and a plain queue has no such failure mode. The cost is up to one
  tick of added latency, which against a transport measured at 0.024 ms
  is invisible.

  WHAT GOES OVER THE WIRE IS THIS PROJECT'S OWN VIEW MODEL, NOT TDLib.
  It would be less code today to forward TDLib's JSON straight to the
  page, and it would be a mistake: the paging anchor, the contiguity of
  FAll, the download queue and its rate limit, the dedup rules — all of
  that was expensive to get right and it lives in tdmessages/tdchats.
  Proxying TDLib would mean writing it a second time in JavaScript.

  Protocol, all of it JSON objects (spelled out in words rather than
  in braces: a literal brace inside a brace comment opens a nested one
  and the compiler counts levels at you — see tdmessages.pas, which
  learned the same lesson):
    client -> server   id, cmd, and optional args
    server -> client   id, ok true, result        — an answer
    server -> client   id, ok false, error        — a refusal
    server -> client   event and data             — unsolicited

  A note on parsing, for when this grows: fpjson's \uXXXX handling is
  broken in two ways this project has already diagnosed the hard way
  (see tdrecv.pas's PreDecodeUnicodeEscapes). It does not bite here
  because JSON.stringify emits non-ASCII as raw UTF-8 rather than as
  escapes, and because the commands this unit accepts are ASCII names
  and numbers. The moment the page starts sending message TEXT, that
  input needs the same hardening tdrecv already applies. }

interface

procedure WebApiStart;
procedure WebApiStop;

implementation

uses
  Classes, SysUtils, SyncObjs, ExtCtrls, fpjson, jsonparser,
  constants, tdchats, tdcore, localserver;

type
  TWebReq = class
  public
    ConnId:  Int64;
    Payload: utf8string;
  end;

  TWebApi = class
  private
    FTimer: TTimer;
    FLock:  SyncObjs.TCriticalSection;
    FQueue: TFPList;
    procedure Tick(Sender: TObject);
    { The same work, callable as a TThreadMethod — that is what
      TThread.Queue needs, and it takes no parameters. }
    procedure Drain;
    { NOT "Dispatch": TObject already has one (message dispatch), and
      a method of that name here hides it — the same family as
      TThread.Start, TControl.Text and TComponent.Name elsewhere in
      this project. }
    procedure RunCommand(AConnId: Int64; const AText: utf8string);
    procedure Reply(AConnId: Int64; AReqId: integer; AResult: TJSONData);
    procedure Fail(AConnId: Int64; AReqId: integer; const AError: utf8string);
    function  CmdChatsList(AArgs: TJSONObject): TJSONData;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(AConnId: Int64; const AText: utf8string);
  end;

var
  GApi: TWebApi = nil;

{ ------------------------------------------------------------------ }
{ view-model helpers                                                 }
{ ------------------------------------------------------------------ }

{ A key into the web UI's palette, NOT a colour.
    'a<id>' — Telegram's own accent id, 0..ACCENT_ID_MAX.
    'f<n>'  — the hashed fallback, for a chat with no accent id (or one
              past the range this build knows about), matching what
              framechats.ChatAccentColor falls back to.

  A key rather than '#rrggbb' because the page styles a chat by adding
  a class, never by writing an inline style: the set of accent colours
  is small and fixed, so it belongs in the stylesheet as a finite set
  of classes rather than being pushed into the DOM one element at a
  time. The stylesheet holds the matching hex values (and Telegram's
  separate dark-theme values, which a single colour sent from here
  could not express at all). }
function AccentKey(ARow: TChatRow): utf8string;
begin
  if (ARow.AccentColorId >= 0) and (ARow.AccentColorId <= ACCENT_ID_MAX) then begin
    Result := 'a' + utf8string(IntToStr(ARow.AccentColorId));
  end else begin
    Result := 'f' + utf8string(IntToStr(Abs(ARow.Id) mod Length(SENDER_PALETTE)));
  end;
end;

function ChatKindStr(AChats: TTdChats; ARow: TChatRow): utf8string;
begin
  if AChats.IsSelfChat(ARow) then begin
    Exit('self');
  end;
  case ARow.Kind of
    ckPrivate:
      if AChats.IsBotChat(ARow) then begin
        Result := 'bot';
      end else begin
        Result := 'private';
      end;
    ckBasicGroup, ckSupergroup: Result := 'group';
    ckChannel:                  Result := 'channel';
    ckSecret:                   Result := 'secret';
  else
    Result := 'other';
  end;
end;

function RowToJson(AChats: TTdChats; ARow: TChatRow): TJSONObject;
var
  FolderId: integer;
  Folder: utf8string;
begin
  FolderId := AChats.RowFolderId(ARow);
  if FolderId = 0 then begin
    Folder := '';
  end else begin
    Folder := AChats.FolderTitle(FolderId);
  end;

  Result := TJSONObject.Create;
  { The utf8string -> string casts below are identity at run time: the
    program sets DefaultSystemCodePage to CP_UTF8 before anything else
    (tg.lpr), so both types carry the same code page and no transcoding
    happens. Worth knowing for any harness that links this unit without
    doing the same — it would quietly mangle every non-Latin title. }
  Result.Add('id',       ARow.Id);
  Result.Add('title',    string(ARow.Title));
  Result.Add('kind',     string(ChatKindStr(AChats, ARow)));
  Result.Add('color',    string(AccentKey(ARow)));
  Result.Add('preview',  string(ARow.LastText));
  Result.Add('date',     ARow.LastDate);
  Result.Add('unread',   ARow.UnreadCount);
  Result.Add('mentions', ARow.UnreadMentionCount);
  Result.Add('muted',    ARow.IsMuted);
  Result.Add('pinned',   ARow.IsPinned);
  Result.Add('archived', ARow.InArchive);
  Result.Add('outgoing', ARow.LastIsOutgoing);
  Result.Add('folder',   string(Folder));
end;

{ ------------------------------------------------------------------ }
{ TWebApi                                                            }
{ ------------------------------------------------------------------ }

constructor TWebApi.Create;
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FQueue := TFPList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := WEBAPI_FALLBACK_TICK_MS;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := True;
end;

destructor TWebApi.Destroy;
var
  I: integer;
begin
  FTimer.Enabled := False;
  FTimer.Free;
  { A queued Drain still pointing at this object would run against
    freed memory. }
  TThread.RemoveQueuedEvents(@Drain);
  FLock.Enter;
  try
    for I := 0 to FQueue.Count - 1 do begin
      TObject(FQueue[I]).Free;
    end;
    FQueue.Clear;
  finally
    FLock.Leave;
  end;
  FQueue.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWebApi.Enqueue(AConnId: Int64; const AText: utf8string);
var
  R: TWebReq;
begin
  R := TWebReq.Create;
  R.ConnId := AConnId;
  R.Payload := AText;
  FLock.Enter;
  try
    FQueue.Add(R);
  finally
    FLock.Leave;
  end;
  { Wake the main thread NOW rather than leaving the command to sit
    until the next timer tick. TThread.Queue is the right tool and not
    the one this project got burned by: unlike Synchronize it does not
    block the caller at all — it appends an entry that the main
    thread's CheckSynchronize runs later — so the "thread blocked
    inside Synchronize while the main thread waits on it" deadlock has
    no way to happen here. Measured: median command round trip drops
    from ~16 ms (half a tick, on average) to well under a millisecond.
    Extra entries are harmless: whichever Drain runs first empties the
    queue and the rest find it empty. }
  TThread.Queue(nil, @Drain);
end;

procedure TWebApi.Tick(Sender: TObject);
begin
  Drain;
end;

procedure TWebApi.Drain;
var
  Batch: TFPList;
  I: integer;
  R: TWebReq;
begin
  { The queue is emptied into a local list under the lock and worked on
    outside it: dispatch runs model code of unbounded duration, and
    holding the lock across that would stall the socket threads. }
  Batch := TFPList.Create;
  try
    FLock.Enter;
    try
      if FQueue.Count = 0 then begin
        Exit;
      end;
      for I := 0 to FQueue.Count - 1 do begin
        Batch.Add(FQueue[I]);
      end;
      FQueue.Clear;
    finally
      FLock.Leave;
    end;

    for I := 0 to Batch.Count - 1 do begin
      R := TWebReq(Batch[I]);
      try
        RunCommand(R.ConnId, R.Payload);
      except
        { One bad command must not take the timer, and with it every
          later command, down with it. }
        on E: Exception do begin
          Fail(R.ConnId, 0, utf8string(E.Message));
        end;
      end;
    end;
  finally
    for I := 0 to Batch.Count - 1 do begin
      TObject(Batch[I]).Free;
    end;
    Batch.Free;
  end;
end;

procedure TWebApi.Reply(AConnId: Int64; AReqId: integer; AResult: TJSONData);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', AReqId);
    O.Add('ok', True);
    if AResult = nil then begin
      O.Add('result', TJSONNull.Create);
    end else begin
      { Add takes ownership, so AResult is freed along with O. }
      O.Add('result', AResult);
    end;
    WebSendTo(AConnId, utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

procedure TWebApi.Fail(AConnId: Int64; AReqId: integer; const AError: utf8string);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', AReqId);
    O.Add('ok', False);
    O.Add('error', string(AError));
    WebSendTo(AConnId, utf8string(O.AsJSON));
  finally
    O.Free;
  end;
end;

function TWebApi.CmdChatsList(AArgs: TJSONObject): TJSONData;
var
  Chats: TTdChats;
  Arr: TJSONArray;
  Res: TJSONObject;
  I, N, Limit: integer;
  Archived: boolean;
begin
  Chats := TdChatList;
  if Chats = nil then begin
    raise Exception.Create('no active account');
  end;

  Archived := False;
  Limit := 0;
  if AArgs <> nil then begin
    Archived := AArgs.Get('archived', False);
    Limit := AArgs.Get('limit', 0);
  end;

  if Archived then begin
    N := Chats.ArchiveCount;
  end else begin
    N := Chats.Count;
  end;

  Arr := TJSONArray.Create;
  try
    for I := 0 to N - 1 do begin
      if (Limit > 0) and (Arr.Count >= Limit) then begin
        Break;
      end;
      if Archived then begin
        Arr.Add(RowToJson(Chats, Chats.ArchiveRows[I]));
      end else begin
        Arr.Add(RowToJson(Chats, Chats.Rows[I]));
      end;
    end;
  except
    Arr.Free;
    raise;
  end;

  Res := TJSONObject.Create;
  Res.Add('total', N);
  Res.Add('loading', Chats.Loading);
  Res.Add('items', Arr);
  Result := Res;
end;

procedure TWebApi.RunCommand(AConnId: Int64; const AText: utf8string);
var
  D: TJSONData;
  Obj, Args: TJSONObject;
  Cmd: utf8string;
  ReqId: integer;
begin
  D := nil;
  try
    try
      D := GetJSON(string(AText));
    except
      on E: Exception do begin
        Fail(AConnId, 0, 'malformed json');
        Exit;
      end;
    end;
    if not (D is TJSONObject) then begin
      Fail(AConnId, 0, 'expected a json object');
      Exit;
    end;

    Obj := TJSONObject(D);
    ReqId := Obj.Get('id', 0);
    Cmd := utf8string(Obj.Get('cmd', ''));
    Args := TJSONObject(Obj.Find('args', jtObject));

    { The handlers are wrapped HERE, where the request id is known.
      Letting an exception travel up to the drain loop instead loses
      it, and the answer comes back tagged id 0 — which the page
      cannot match to anything, so its pending request never settles
      and simply hangs. Caught by the harness: chats.list without a
      TDLib client answered id 0 instead of id 2. }
    try
      if Cmd = 'ping' then begin
        { Deliberately trivial, and deliberately kept: it is the one
          command that proves the whole path — socket thread, queue,
          main thread, back out — without involving the model. }
        Reply(AConnId, ReqId, TJSONString.Create('pong'));
      end else if Cmd = 'chats.list' then begin
        Reply(AConnId, ReqId, CmdChatsList(Args));
      end else begin
        Fail(AConnId, ReqId, 'unknown command: ' + Cmd);
      end;
    except
      on E: Exception do begin
        Fail(AConnId, ReqId, utf8string(E.Message));
      end;
    end;
  finally
    D.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ module entry points                                                }
{ ------------------------------------------------------------------ }

{ Runs on a SOCKET thread. Queue and return, nothing else. }
procedure SocketMessage(AConnId: Int64; const AText: utf8string);
begin
  if GApi <> nil then begin
    GApi.Enqueue(AConnId, AText);
  end;
end;

procedure WebApiStart;
begin
  if GApi <> nil then begin
    Exit;
  end;
  GApi := TWebApi.Create;
  SetWebMessageHandler(@SocketMessage);
end;

procedure WebApiStop;
begin
  if GApi = nil then begin
    Exit;
  end;
  { Unhook FIRST: after this no socket thread can reach the queue, so
    the object is free to go. }
  SetWebMessageHandler(nil);
  FreeAndNil(GApi);
end;

end.
