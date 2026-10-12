unit tdrecv;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, fpjson, jsonparser, constants, tdjson;

type
  { AData is the result of parsing AJson, done HERE, in the receive
    thread (see TTdReceiveThread.Execute), not separately by each
    subscriber on the main thread. tdrecv owns the object: it is freed
    in DrainQueue right after the handler call, so AData is invalid
    outside TTdRawEvent — the pointer must not be kept. AData is nil
    if the string failed to parse or did not parse to an object. }
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

    One instance per process. TDLib's documentation forbids calling
    td_receive from two threads at once, and updates for all clients
    arrive on a single stream, distinguished by the @client_id field.
    So there is exactly one thread here, and a dispatcher fans updates
    out to subscribers.

    Full JSON parsing (GetJSON) also happens on this thread — it is
    idle almost all the time inside td_receive's timeout, so this adds
    no load to UI responsiveness. Parsing on the main thread instead,
    once per subscriber, would be a measurable stall for something
    like getChatHistory with dozens of messages and a base64
    mini-thumbnail in each — hundreds of KB of JSON. }

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
    procedure DrainQueue;              { runs on the main thread }
    function FindHandler(AClientId: integer; out AEvent: TTdRawEvent): boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { A client registers itself right after td_create_client_id. }
    procedure RegisterClient(AClientId: integer; AHandler: TTdRawEvent);
    procedure UnregisterClient(AClientId: integer);

    property Active: boolean read FActive;
  end;

{ Singleton accessor. }
function TdReceiver: TTdReceiver;
function TdReceiverExists: boolean;

{ Extracts @client_id from raw JSON without a full parse — updates
  arrive by the thousands, and subscribers already filter out
  irrelevant ones with cheap string checks. }
function ExtractClientId(const AJson: utf8string): integer;

{ Exported for webapi.pas, which faces the same hazard from the other
  direction: anything arriving as JSON from outside has to be put
  through this before GetJSON sees it. See the long comment at the
  implementation. }
function PreDecodeUnicodeEscapes(const AJson: utf8string): utf8string;

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

{ fpjson's \uXXXX decoding (jsonscanner.pp) has two confirmed bugs on
  this build, found by reading FPC 3.2.2's actual source after a real,
  reproducible corruption in the app (custom-emoji entity landing on
  the wrong letters -- see docs/journal/ for the full trail):

  1) A single \uXXXX escape is only UTF-8-encoded correctly when
     (joUTF8 in Options) or (DefaultSystemCodePage = CP_UTF8) --
     GetJSON's default parser passes neither, and this machine's
     DefaultSystemCodePage is 1251 (Windows-1251), so every isolated
     BMP escape decoded to a lossy literal '?' via the ANSI codepage.
  2) Even with DefaultSystemCodePage forced to CP_UTF8, TWO \uXXXX
     escapes back to back where the FIRST is not a valid high
     surrogate (D800-DBFF) still get silently truncated by the
     scanner's surrogate-pair-combine path (confirmed: ➡️,
     arrow+VS16 -- exactly what a custom/variant emoji looks like in
     TDLib's JSON -- decoded to only 4 of the correct 6 UTF-8 bytes,
     losing VS16's last two bytes). Because every later entity byte
     offset in the same message is computed from Utf16RangeToByteRange
     against this now-too-short string, the loss shifts every
     subsequent offset, landing custom-emoji entities on the wrong
     letters -- exactly the "eaten text / wrong icon" bug reported.

  Rather than patch FPC's own scanner, \uXXXX (including correct
  surrogate-pair combination) is decoded to raw UTF-8 bytes HERE,
  on the raw string, before it ever reaches GetJSON -- fpjson's
  scanner then only ever sees ordinary bytes (which it already moves
  through untouched, byte-for-byte, on the non-escape path) plus the
  other escapes (\\, \", \n, ...) it already handles correctly. }
function PreDecodeUnicodeEscapes(const AJson: utf8string): utf8string;
var
  I, Len: integer;
  U1, U2: cardinal;

  function HexAt(APos: integer): cardinal;
  var
    J: integer;
    C: char;
  begin
    Result := 0;
    for J := 0 to 3 do begin
      C := AJson[APos + J];
      case C of
        '0'..'9': Result := Result * 16 + (Ord(C) - Ord('0'));
        'A'..'F': Result := Result * 16 + (Ord(C) - Ord('A') + 10);
        'a'..'f': Result := Result * 16 + (Ord(C) - Ord('a') + 10);
      else
        Result := $FFFFFFFF; { not 4 hex digits -- not a real escape }
        Exit;
      end;
    end;
  end;

  procedure AppendUtf8(ACp: cardinal);
  begin
    if ACp <= $7F then begin
      Result := Result + Chr(ACp);
    end else if ACp <= $7FF then begin
      Result := Result + Chr($C0 or (ACp shr 6)) + Chr($80 or (ACp and $3F));
    end else if ACp <= $FFFF then begin
      Result := Result + Chr($E0 or (ACp shr 12)) +
        Chr($80 or ((ACp shr 6) and $3F)) + Chr($80 or (ACp and $3F));
    end else begin
      Result := Result + Chr($F0 or (ACp shr 18)) +
        Chr($80 or ((ACp shr 12) and $3F)) +
        Chr($80 or ((ACp shr 6) and $3F)) + Chr($80 or (ACp and $3F));
    end;
  end;

begin
  { Cheap bailout: the overwhelming majority of updates (typing
    notifications, file-progress pings, ...) carry no \u at all. }
  if Pos('\u', AJson) = 0 then begin
    Result := AJson;
    Exit;
  end;

  Result := '';
  Len := Length(AJson);
  I := 1;
  while I <= Len do begin
    if (AJson[I] = '\') and (I + 1 <= Len) then begin
      if (AJson[I + 1] = 'u') and (I + 5 <= Len) then begin
        U1 := HexAt(I + 2);
        if U1 <> $FFFFFFFF then begin
          Inc(I, 6); { consumed \uXXXX }
          if (U1 >= $D800) and (U1 <= $DBFF) and (I + 5 <= Len) and
             (AJson[I] = '\') and (AJson[I + 1] = 'u') then begin
            U2 := HexAt(I + 2);
            if (U2 <> $FFFFFFFF) and (U2 >= $DC00) and (U2 <= $DFFF) then begin
              Inc(I, 6); { consumed the low surrogate too }
              AppendUtf8($10000 + ((U1 - $D800) shl 10) + (U2 - $DC00));
              Continue;
            end;
          end;
          AppendUtf8(U1);
          Continue;
        end;
      end;
      { Any other escape (\\, \", \n, ...), or a lone/malformed \u --
        copy the backslash and its next char verbatim, unexamined, so
        an escaped backslash is never re-entered as a new escape start
        (this is what correctly leaves a literal "\\u1234" as-is,
        rather than misreading its second backslash as \u). }
      Result := Result + AJson[I] + AJson[I + 1];
      Inc(I, 2);
    end else begin
      Result := Result + AJson[I];
      Inc(I);
    end;
  end;
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
  { JSON allows whitespace after the colon }
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
      { Parsing happens here, not on the main thread. A parse error or
        non-object JSON is left to the subscribers, which already
        handle AData = nil (see the TTdRawEvent comment). }
      Data := nil;
      try
        Data := GetJSON(string(PreDecodeUnicodeEscapes(S)));
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
  { The thread is started only after FThread is assigned: otherwise it
    could call PushUpdate before that, and TThread.Queue would get nil. }
  FThread.Start;
end;

procedure TTdReceiver.Stop;
var
  I: integer;
begin
  if FThread <> nil then begin
    FThread.Terminate;
    FThread.WaitFor;              { up to RECEIVE_TIMEOUT seconds }
    TThread.RemoveQueuedEvents(FThread);
    FreeAndNil(FThread);
  end;
  FLock.Enter;
  try
    { RemoveQueuedEvents canceled DrainQueue if it had not run yet —
      the parsed objects still queued would otherwise be orphaned. }
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
    { No handler will ever run for this — free it here instead. }
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

  { The critical section is released before calling the handlers:
    otherwise the receive thread would block on it for the whole
    duration of update processing. The parsed object is shared by all
    subscribers of this client_id (see TTdAccount.HandleUpdate) and
    owned by tdrecv: it is freed right after the handler call —
    subscribers must not keep the pointer beyond that call (see the
    TTdRawEvent comment). }
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
