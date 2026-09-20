unit localserver;

{$mode objfpc}{$H+}

{ A loopback HTTP + WebSocket server living inside this very exe,
  started only when the process is launched with --server. Nothing in
  the existing UI knows it exists and it touches no model: this is the
  transport half of the "web UI alongside the native one" plan, stood
  up on its own so it can be proven in a browser before anything is
  ported onto it.

  WHY BOTH PROTOCOLS, and not just the WebSocket: media has to be
  ordinary HTTP with Range support, because <video>/<audio> seek by
  asking for byte ranges. Pushing media bytes down the socket into a
  blob instead throws away seeking and streaming and holds whole files
  in the page's memory. So: WebSocket for events and commands, plain
  GET for files. One listener, one port, two paths through it.

  Threading: Synapse is blocking sockets, so this is a listener thread
  plus a thread per connection (there will be one or two). NOTHING
  here may touch TTdMessages/TTdChats — that model is single-threaded
  and lives on the main thread behind its own timers. When the
  protocol layer arrives, socket threads will parse and hand work over
  with Application.QueueAsyncCall, the same way the decoder threads
  already marshal back.

  Security is not decoration here. A listening socket on 127.0.0.1 is
  reachable by every process on the machine AND by any web page the
  user happens to have open, because browsers allow cross-origin
  requests to localhost and WebSocket has no same-origin policy of its
  own. Without a check, any tab could drive the user's Telegram
  account. Hence: a random per-run token required on every request
  (query parameter, or the cookie the root page gets), plus an Origin
  check on the upgrade. Both, not either — the token stops non-browser
  callers, the Origin check stops a page that somehow learned the
  token from using it.

  The token is written to server_url.txt next to the exe: this is a
  GUI process with no console, and the URL has to reach the user
  somehow. That file is a local secret for the length of one run. }

interface

uses
  Classes, SysUtils, SyncObjs, blcksock, synsock, constants, wsframe;

type
  TLocalServer = class;

  { Raised on the SOCKET thread the moment a text message arrives. The
    handler must do nothing but queue it: everything this server can be
    asked about lives in a single-threaded model on the main thread.
    See webapi.pas, which installs the only implementation. }
  TWebMessageEvent = procedure(AConnId: Int64; const AText: utf8string);

  { One connection: reads a request, then either serves a file or
    turns into a WebSocket for the rest of its life. }
  TServerConn = class(TThread)
  private
    FOwner:    TLocalServer;
    FConnId:   Int64;
    { Sends come from TWO threads — this one (pong, keepalive ping)
      and the main thread answering a command — and a half-written
      frame interleaved with another is unrecoverable garbage on the
      wire, so every send goes through SendText. }
    FSendLock: SyncObjs.TCriticalSection;
    FSock:     TTCPBlockSocket;
    FMethod:   string;
    FPath:     string;
    FQuery:    string;
    FHeaders:  TStringList;
    function  ReadExact(ABuf: PByte; ALen: integer): boolean;
    function  ReadRequest: boolean;
    function  HeaderValue(const AName: string): string;
    function  QueryParam(const AName: string): string;
    function  CookieValue(const AName: string): string;
    function  Authorized: boolean;
    function  OriginAllowed: boolean;
    function  MapPath(out AFileName: string): boolean;
    procedure SendSimple(ACode: integer; const AReason, ABody: string;
      const AExtraHeaders: string = '');
    procedure ServeFile;
    procedure IsWebSocketRequest(out AIsWs: boolean);
    procedure ServeWebSocket;
    procedure DispatchOrEcho(AOpcode: TWsOpcode; const APayload: RawByteString);
    procedure WsSend(AOpcode: TWsOpcode; const APayload: RawByteString);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLocalServer; ASocket: TSocket);
    destructor Destroy; override;
    { Thread-safe. Callers on another thread must reach it through
      WebSendTo/WebBroadcast, which additionally hold the registry lock
      so this object cannot be freed mid-send. }
    procedure SendText(const AText: utf8string);
    property ConnId: Int64 read FConnId;
  end;

  { The listener. Binding happens in the constructor, synchronously, so
    the caller finds out immediately whether the port was free instead
    of discovering it later from a thread nobody is watching. }
  TLocalServer = class(TThread)
  private
    FPort:     word;
    FToken:    string;
    FWebRoot:  string;
    FBound:    boolean;
    FListener: TTCPBlockSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: word);
    destructor Destroy; override;
    property Port: word read FPort;
    property Token: string read FToken;
    property WebRoot: string read FWebRoot;
    property Bound: boolean read FBound;
  end;

{ True when the command line asked for the server; APort carries the
  port to use (LOCAL_SERVER_PORT unless --server-port=N overrode it). }
function ServerRequested(out APort: word): boolean;

{ Binds and starts. False means the port was taken or the socket could
  not be created — the caller decides whether that is fatal. }
function StartLocalServer(APort: word): boolean;
procedure StopLocalServer;

{ The full URL including the token, empty when not running. }
function LocalServerUrl: string;

{ Installed by webapi.pas. While nil, a text frame is simply echoed —
  which is what the transport-check page exercises. }
procedure SetWebMessageHandler(AHandler: TWebMessageEvent);

{ Both take the connection registry lock for the whole send, which is
  what makes it safe to call them from the main thread: a connection
  unregisters itself under the same lock before it can be freed. }
function WebSendTo(AConnId: Int64; const AText: utf8string): boolean;
procedure WebBroadcast(const AText: utf8string);

implementation

{$IFDEF WINDOWS}
{ RtlGenRandom, the small CSPRNG every Windows process already has.
  Exported by name only, hence the odd literal. Used instead of
  Randomize/Random because that pair is seeded from the clock and is
  reconstructable by anything that knows roughly when the process
  started — a poor basis for what is effectively a session key. }
function RtlGenRandom(ABuffer: Pointer; ALength: cardinal): ByteBool;
  stdcall; external 'advapi32.dll' name 'SystemFunction036';
{$ENDIF}

var
  GServer:      TLocalServer = nil;
  GStopping:    boolean = False;
  GActiveConns: longint = 0;
  { Only connections that made it as far as a live WebSocket appear
    here; a plain file request never registers. }
  GConns:       TFPList = nil;
  GConnsLock:   SyncObjs.TCriticalSection = nil;
  GNextConnId:  Int64 = 0;
  GOnMessage:   TWebMessageEvent = nil;

const
  CRLF = #13#10;

{ ------------------------------------------------------------------ }
{ helpers                                                            }
{ ------------------------------------------------------------------ }

function NewToken: string;
var
  Buf: array[0..LOCAL_SERVER_TOKEN_BYTES - 1] of byte;
  I: integer;
  Ok: boolean;
const
  HEX = '0123456789abcdef';
begin
  Ok := False;
  {$IFDEF WINDOWS}
  Ok := RtlGenRandom(@Buf[0], Length(Buf));
  {$ENDIF}
  if not Ok then begin
    { Only reachable on a platform without the call above, or if it
      failed outright. Weaker, and deliberately noted as such rather
      than quietly pretended to be equivalent. }
    Randomize;
    for I := 0 to High(Buf) do begin
      Buf[I] := byte(Random(256));
    end;
  end;
  Result := '';
  for I := 0 to High(Buf) do begin
    Result := Result + HEX[(Buf[I] shr 4) + 1] + HEX[(Buf[I] and $0F) + 1];
  end;
end;

function UrlDecode(const S: string): string;
var
  I, L: integer;
  H: string;
  V: integer;
begin
  Result := '';
  I := 1;
  L := Length(S);
  while I <= L do begin
    if (S[I] = '%') and (I + 2 <= L) then begin
      H := '$' + Copy(S, I + 1, 2);
      if TryStrToInt(H, V) then begin
        Result := Result + Chr(Byte(V));
        Inc(I, 3);
        Continue;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

function ContentTypeFor(const AFileName: string): string;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(AFileName));
  if E = '.html' then Result := 'text/html; charset=utf-8'
  else if E = '.js' then Result := 'text/javascript; charset=utf-8'
  else if E = '.css' then Result := 'text/css; charset=utf-8'
  else if E = '.json' then Result := 'application/json; charset=utf-8'
  { Source maps live beside the stylesheet they belong to. Only ever
    fetched with devtools open, but served as octet-stream they are
    refused there, which is a confusing way to lose them. }
  else if E = '.map' then Result := 'application/json; charset=utf-8'
  else if E = '.svg' then Result := 'image/svg+xml'
  else if E = '.png' then Result := 'image/png'
  else if (E = '.jpg') or (E = '.jpeg') then Result := 'image/jpeg'
  else if E = '.webp' then Result := 'image/webp'
  else if E = '.gif' then Result := 'image/gif'
  else if E = '.ico' then Result := 'image/x-icon'
  else if E = '.mp4' then Result := 'video/mp4'
  else if E = '.webm' then Result := 'video/webm'
  else if (E = '.ogg') or (E = '.oga') then Result := 'audio/ogg'
  else if E = '.mp3' then Result := 'audio/mpeg'
  else if E = '.wav' then Result := 'audio/wav'
  else if E = '.woff2' then Result := 'font/woff2'
  else if E = '.wasm' then Result := 'application/wasm'
  else if E = '.tgs' then Result := 'application/gzip'
  else Result := 'application/octet-stream';
end;

{ "bytes=a-b" / "bytes=a-" / "bytes=-n". Only a single range: a
  multi-range request may legally be answered with the whole file, and
  no browser media element needs more than one. }
function ParseRange(const AValue: string; ATotal: Int64;
  out AStart, AFinish: Int64): boolean;
var
  S, L, R: string;
  P: integer;
begin
  Result := False;
  AStart := 0;
  AFinish := ATotal - 1;
  S := Trim(AValue);
  if LowerCase(Copy(S, 1, 6)) <> 'bytes=' then begin
    Exit;
  end;
  S := Trim(Copy(S, 7, MaxInt));
  if Pos(',', S) > 0 then begin
    Exit;
  end;
  P := Pos('-', S);
  if P = 0 then begin
    Exit;
  end;
  L := Trim(Copy(S, 1, P - 1));
  R := Trim(Copy(S, P + 1, MaxInt));
  if L = '' then begin
    { suffix form: the LAST n bytes }
    if (R = '') or (not TryStrToInt64(R, AStart)) or (AStart <= 0) then begin
      Exit;
    end;
    if AStart > ATotal then begin
      AStart := ATotal;
    end;
    AFinish := ATotal - 1;
    AStart := ATotal - AStart;
  end else begin
    if not TryStrToInt64(L, AStart) then begin
      Exit;
    end;
    if R <> '' then begin
      if not TryStrToInt64(R, AFinish) then begin
        Exit;
      end;
    end;
    if AFinish > ATotal - 1 then begin
      AFinish := ATotal - 1;
    end;
  end;
  Result := (AStart >= 0) and (AStart <= AFinish) and (AFinish < ATotal);
end;

{ ------------------------------------------------------------------ }
{ TServerConn                                                        }
{ ------------------------------------------------------------------ }

constructor TServerConn.Create(AOwner: TLocalServer; ASocket: TSocket);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := AOwner;
  FHeaders := TStringList.Create;
  FSendLock := SyncObjs.TCriticalSection.Create;
  FSock := TTCPBlockSocket.Create;
  FSock.Socket := ASocket;
  FSock.SetTimeout(LOCAL_SERVER_HTTP_TIMEOUT_MS);
  GConnsLock.Enter;
  try
    Inc(GNextConnId);
    FConnId := GNextConnId;
  finally
    GConnsLock.Leave;
  end;
  InterLockedIncrement(GActiveConns);
  Start;
end;

destructor TServerConn.Destroy;
begin
  FSock.Free;
  FSendLock.Free;
  FHeaders.Free;
  InterLockedDecrement(GActiveConns);
  inherited Destroy;
end;

function TServerConn.ReadExact(ABuf: PByte; ALen: integer): boolean;
begin
  Result := (FSock.RecvBufferEx(ABuf, ALen, LOCAL_SERVER_WS_READ_TIMEOUT_MS) = ALen)
            and (FSock.LastError = 0);
end;

function TServerConn.HeaderValue(const AName: string): string;
begin
  Result := Trim(FHeaders.Values[LowerCase(AName)]);
end;

function TServerConn.ReadRequest: boolean;
var
  Line, Raw: string;
  P, Total: integer;
begin
  Result := False;
  FHeaders.Clear;

  Line := FSock.RecvTerminated(LOCAL_SERVER_HTTP_TIMEOUT_MS, CRLF);
  if (FSock.LastError <> 0) or (Line = '') then begin
    Exit;
  end;

  P := Pos(' ', Line);
  if P = 0 then begin
    Exit;
  end;
  FMethod := UpperCase(Copy(Line, 1, P - 1));
  Raw := Trim(Copy(Line, P + 1, MaxInt));
  P := Pos(' ', Raw);
  if P > 0 then begin
    Raw := Copy(Raw, 1, P - 1);
  end;

  P := Pos('?', Raw);
  if P > 0 then begin
    FQuery := Copy(Raw, P + 1, MaxInt);
    Raw := Copy(Raw, 1, P - 1);
  end else begin
    FQuery := '';
  end;
  FPath := UrlDecode(Raw);

  { Headers are lower-cased on the way in so lookups never have to
    guess at the peer's capitalisation. A cap on the total is not
    paranoia theatre: without it a peer can make this thread grow a
    list until the process dies. }
  Total := 0;
  repeat
    Line := FSock.RecvTerminated(LOCAL_SERVER_HTTP_TIMEOUT_MS, CRLF);
    if FSock.LastError <> 0 then begin
      Exit;
    end;
    if Line = '' then begin
      Break;
    end;
    Inc(Total, Length(Line));
    if Total > LOCAL_SERVER_MAX_HEADER_BYTES then begin
      Exit;
    end;
    P := Pos(':', Line);
    if P > 0 then begin
      FHeaders.Values[LowerCase(Trim(Copy(Line, 1, P - 1)))] :=
        Trim(Copy(Line, P + 1, MaxInt));
    end;
  until False;

  Result := True;
end;

function TServerConn.QueryParam(const AName: string): string;
var
  Parts: TStringList;
  I, P: integer;
  N: string;
begin
  Result := '';
  if FQuery = '' then begin
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '&';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := FQuery;
    for I := 0 to Parts.Count - 1 do begin
      P := Pos('=', Parts[I]);
      if P > 0 then begin
        N := Copy(Parts[I], 1, P - 1);
        if SameText(N, AName) then begin
          Result := UrlDecode(Copy(Parts[I], P + 1, MaxInt));
          Exit;
        end;
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function TServerConn.CookieValue(const AName: string): string;
var
  Raw, Item: string;
  Parts: TStringList;
  I, P: integer;
begin
  Result := '';
  Raw := HeaderValue('cookie');
  if Raw = '' then begin
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Raw;
    for I := 0 to Parts.Count - 1 do begin
      Item := Trim(Parts[I]);
      P := Pos('=', Item);
      if (P > 0) and SameText(Copy(Item, 1, P - 1), AName) then begin
        Result := Trim(Copy(Item, P + 1, MaxInt));
        Exit;
      end;
    end;
  finally
    Parts.Free;
  end;
end;

function TServerConn.Authorized: boolean;
var
  T: string;
begin
  T := QueryParam('t');
  if T = '' then begin
    T := CookieValue(LOCAL_SERVER_COOKIE);
  end;
  Result := (T <> '') and (T = FOwner.Token);
end;

function TServerConn.OriginAllowed: boolean;
var
  O: string;
begin
  O := LowerCase(HeaderValue('origin'));
  { No Origin at all means a non-browser client; the token alone
    governs those. A browser always sends one on an upgrade, so a
    WRONG one is a page trying its luck and gets refused. }
  if O = '' then begin
    Result := True;
    Exit;
  end;
  Result := (O = 'http://127.0.0.1:' + IntToStr(FOwner.Port))
         or (O = 'http://localhost:' + IntToStr(FOwner.Port));
end;

function TServerConn.MapPath(out AFileName: string): boolean;
var
  Rel, Root, Full: string;
begin
  Result := False;
  AFileName := '';
  Rel := FPath;
  if (Rel = '') or (Rel = '/') then begin
    Rel := '/index.html';
  end;
  { Anything that could climb out, before it ever becomes a real path.
    The ExpandFileName check below is the actual guarantee; this is the
    cheap first gate. }
  if (Pos('..', Rel) > 0) or (Pos(#0, Rel) > 0) or (Pos(':', Rel) > 0)
     or (Pos('\', Rel) > 0) then begin
    Exit;
  end;
  if Rel[1] <> '/' then begin
    Exit;
  end;
  Delete(Rel, 1, 1);
  Root := IncludeTrailingPathDelimiter(ExpandFileName(FOwner.WebRoot));
  Full := ExpandFileName(Root + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]));
  { The real containment test: whatever the path games, the result has
    to still be inside the web root. }
  if Copy(Full, 1, Length(Root)) <> Root then begin
    Exit;
  end;
  AFileName := Full;
  Result := True;
end;

procedure TServerConn.SendSimple(ACode: integer; const AReason, ABody: string;
  const AExtraHeaders: string);
var
  H: string;
begin
  H := 'HTTP/1.1 ' + IntToStr(ACode) + ' ' + AReason + CRLF
     + 'Content-Type: text/plain; charset=utf-8' + CRLF
     + 'Content-Length: ' + IntToStr(Length(ABody)) + CRLF
     + 'Connection: close' + CRLF;
  if AExtraHeaders <> '' then begin
    H := H + AExtraHeaders + CRLF;
  end;
  FSock.SendString(H + CRLF + ABody);
end;

procedure TServerConn.ServeFile;
var
  Fn, Hdr, Ct: string;
  FS: TFileStream;
  { NOT "Start"/"Finish": TThread already has a Start method, and a
    local of that name inside any method of this class is a duplicate
    identifier rather than a harmless shadow — the same trap as
    Text (TControl) and Name (TComponent) elsewhere in this project. }
  Total, RStart, RFinish, Left: Int64;
  Buf: array of byte;
  Want, Got: integer;
  Partial: boolean;
begin
  if not MapPath(Fn) then begin
    SendSimple(404, 'Not Found', 'not found');
    Exit;
  end;
  if not FileExists(Fn) then begin
    SendSimple(404, 'Not Found', 'not found');
    Exit;
  end;

  try
    FS := TFileStream.Create(Fn, fmOpenRead or fmShareDenyNone);
  except
    SendSimple(404, 'Not Found', 'not readable');
    Exit;
  end;
  try
    Total := FS.Size;
    RStart := 0;
    RFinish := Total - 1;
    Partial := False;

    Hdr := HeaderValue('range');
    if (Hdr <> '') and (Total > 0) then begin
      if ParseRange(Hdr, Total, RStart, RFinish) then begin
        Partial := True;
      end else begin
        SendSimple(416, 'Range Not Satisfiable', '',
          'Content-Range: bytes */' + IntToStr(Total));
        Exit;
      end;
    end;

    if Total = 0 then begin
      Left := 0;
    end else begin
      Left := RFinish - RStart + 1;
    end;
    Ct := ContentTypeFor(Fn);

    if Partial then begin
      Hdr := 'HTTP/1.1 206 Partial Content' + CRLF
           + 'Content-Range: bytes ' + IntToStr(RStart) + '-' + IntToStr(RFinish)
             + '/' + IntToStr(Total) + CRLF;
    end else begin
      Hdr := 'HTTP/1.1 200 OK' + CRLF;
    end;
    Hdr := Hdr
         + 'Content-Type: ' + Ct + CRLF
         + 'Content-Length: ' + IntToStr(Left) + CRLF
         + 'Accept-Ranges: bytes' + CRLF
         { Local files that change under the page (a download finishing
           and replacing a placeholder) must not be cached while this
           is being developed. }
         + 'Cache-Control: no-store' + CRLF
         + 'Connection: close' + CRLF;
    { The root page hands the browser the token as a cookie, so that
      <img>/<video> URLs the page builds later need no query string of
      their own. SameSite=Strict keeps other origins from riding it. }
    if (FPath = '/') or (FPath = '/index.html') then begin
      Hdr := Hdr + 'Set-Cookie: ' + LOCAL_SERVER_COOKIE + '=' + FOwner.Token
           + '; Path=/; SameSite=Strict' + CRLF;
    end;
    FSock.SendString(Hdr + CRLF);
    if (FSock.LastError <> 0) or (FMethod = 'HEAD') then begin
      Exit;
    end;

    FS.Position := RStart;
    SetLength(Buf, LOCAL_SERVER_SEND_CHUNK);
    while (Left > 0) and (not Terminated) and (not GStopping) do begin
      if Left > LOCAL_SERVER_SEND_CHUNK then begin
        Want := LOCAL_SERVER_SEND_CHUNK;
      end else begin
        Want := integer(Left);
      end;
      Got := FS.Read(Buf[0], Want);
      if Got <= 0 then begin
        Break;
      end;
      FSock.SendBuffer(@Buf[0], Got);
      if FSock.LastError <> 0 then begin
        Break;
      end;
      Dec(Left, Got);
    end;
  finally
    FS.Free;
  end;
end;

procedure TServerConn.IsWebSocketRequest(out AIsWs: boolean);
begin
  AIsWs := (Pos('websocket', LowerCase(HeaderValue('upgrade'))) > 0)
       and (Pos('upgrade', LowerCase(HeaderValue('connection'))) > 0);
end;

procedure TServerConn.WsSend(AOpcode: TWsOpcode; const APayload: RawByteString);
begin
  FSendLock.Enter;
  try
    FSock.SendString(WsEncodeFrame(AOpcode, APayload));
  finally
    FSendLock.Leave;
  end;
end;

procedure TServerConn.SendText(const AText: utf8string);
begin
  { utf8string -> RawByteString keeps the bytes as they are, which is
    exactly right: a text frame's payload is UTF-8 by protocol. }
  WsSend(wsoText, RawByteString(AText));
end;

procedure TServerConn.ServeWebSocket;
var
  Key: string;
  R: TWsResult;
  Op, FragOp: TWsOpcode;
  Fin, Fragging: boolean;
  Payload, Frag: RawByteString;
  LastPing: QWord;
begin
  Key := HeaderValue('sec-websocket-key');
  if (Key = '') or (HeaderValue('sec-websocket-version') <> '13') then begin
    SendSimple(400, 'Bad Request', 'bad websocket handshake');
    Exit;
  end;
  if not OriginAllowed then begin
    SendSimple(403, 'Forbidden', 'bad origin');
    Exit;
  end;

  FSock.SendString(
    'HTTP/1.1 101 Switching Protocols' + CRLF +
    'Upgrade: websocket' + CRLF +
    'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Accept: ' + WsAcceptKey(Key) + CRLF + CRLF);
  if FSock.LastError <> 0 then begin
    Exit;
  end;

  { Only now does this connection become addressable from the main
    thread: before the upgrade there is nothing to push to. }
  GConnsLock.Enter;
  try
    GConns.Add(Self);
  finally
    GConnsLock.Leave;
  end;
  try

  WsSend(wsoText, '{"type":"hello","proto":1}');

  Fragging := False;
  FragOp := wsoText;
  Frag := '';
  LastPing := GetTickCount64;

  while (not Terminated) and (not GStopping) do begin
    { CanReadEx, NOT CanRead — and this is not interchangeable.
      Synapse's RecvBufferEx pulls a whole TCP packet and keeps
      whatever the frame did not need in the socket object's own
      FBuffer; CanRead is a bare select() on the handle and cannot see
      that buffer, so every frame that arrived in the same segment as
      its predecessor became invisible and the loop sat here idling on
      data it already held. Symptom: the FIRST frame of a batch was
      answered and the rest were not, until some later segment
      happened to wake the select. Found by an independent client
      sending a deliberately fragmented message; a browser never
      fragments small messages, so it would have hidden this
      indefinitely while merely looking slow under bursts. }
    if not FSock.CanReadEx(LOCAL_SERVER_WS_POLL_MS) then begin
      { Idle. A server-side ping is what detects a peer that vanished
        without a FIN (a sleeping laptop, a killed browser) — without
        it such a connection sits here forever holding a thread. }
      if GetTickCount64 - LastPing >= LOCAL_SERVER_WS_PING_MS then begin
        WsSend(wsoPing, '');
        LastPing := GetTickCount64;
        if FSock.LastError <> 0 then begin
          Break;
        end;
      end;
      Continue;
    end;

    R := WsReadFrame(@ReadExact, LOCAL_SERVER_WS_MAX_PAYLOAD, Op, Fin, Payload);
    if R = wsrTooLarge then begin
      WsSend(wsoClose, WsCloseCode(1009));   { message too big }
      Break;
    end;
    if R = wsrProtocol then begin
      WsSend(wsoClose, WsCloseCode(1002));   { protocol error }
      Break;
    end;
    if R <> wsrOk then begin
      Break;
    end;

    case Op of
      wsoPing:
        begin
          { A pong must carry the ping's payload back unchanged. }
          WsSend(wsoPong, Payload);
        end;
      wsoPong:
        begin
          { Answer to our own keepalive; nothing to do. }
        end;
      wsoClose:
        begin
          WsSend(wsoClose, WsCloseCode(1000));
          Break;
        end;
      wsoText, wsoBinary:
        begin
          if Fin then begin
            DispatchOrEcho(Op, Payload);
          end else begin
            Fragging := True;
            FragOp := Op;
            Frag := Payload;
          end;
        end;
      wsoContinuation:
        begin
          if not Fragging then begin
            WsSend(wsoClose, WsCloseCode(1002));
            Break;
          end;
          if Length(Frag) + Length(Payload) > LOCAL_SERVER_WS_MAX_PAYLOAD then begin
            WsSend(wsoClose, WsCloseCode(1009));
            Break;
          end;
          Frag := Frag + Payload;
          if Fin then begin
            DispatchOrEcho(FragOp, Frag);
            Fragging := False;
            Frag := '';
          end;
        end;
    end;

    if FSock.LastError <> 0 then begin
      Break;
    end;
  end;

  finally
    { Unregister BEFORE this object can be freed, under the same lock
      WebSendTo holds while sending — that pairing is what stops the
      main thread from writing into a destroyed connection. }
    GConnsLock.Enter;
    try
      GConns.Remove(Self);
    finally
      GConnsLock.Leave;
    end;
  end;
end;

procedure TServerConn.DispatchOrEcho(AOpcode: TWsOpcode; const APayload: RawByteString);
var
  H: TWebMessageEvent;
begin
  { Read ONCE into a local. Testing the global and then calling it
    leaves a window in which shutdown can nil it in between, and the
    call then goes to nil. }
  H := GOnMessage;
  { No handler installed (the transport-check page, or the server
    running without webapi) — behave as a plain echo. }
  if (AOpcode <> wsoText) or (H = nil) then begin
    WsSend(AOpcode, APayload);
    Exit;
  end;
  { Runs on THIS thread. The handler only queues; the answer comes
    back later through WebSendTo, on the main thread. }
  H(FConnId, utf8string(APayload));
end;

procedure TServerConn.Execute;
var
  IsWs: boolean;
begin
  try
    try
      if not ReadRequest then begin
        Exit;
      end;
      if (FMethod <> 'GET') and (FMethod <> 'HEAD') then begin
        SendSimple(405, 'Method Not Allowed', 'only GET/HEAD');
        Exit;
      end;
      if not Authorized then begin
        { Deliberately bland and identical for "no token" and "wrong
          token" — there is nothing to be gained by telling a caller
          which. }
        SendSimple(403, 'Forbidden', 'forbidden');
        Exit;
      end;
      IsWebSocketRequest(IsWs);
      if IsWs then begin
        ServeWebSocket;
      end else begin
        ServeFile;
      end;
    except
      { A malformed request must never escape into the thread: an
        unhandled exception here would take the whole process with it,
        and the UI half of this exe is a real application. }
      on E: Exception do begin
        { swallowed on purpose }
      end;
    end;
  finally
    FSock.CloseSocket;
  end;
end;

{ ------------------------------------------------------------------ }
{ TLocalServer                                                       }
{ ------------------------------------------------------------------ }

constructor TLocalServer.Create(APort: word);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPort := APort;
  FToken := NewToken;
  FWebRoot := IncludeTrailingPathDelimiter(
    ExtractFilePath(ParamStr(0)) + LOCAL_SERVER_WEB_DIR);

  FListener := TTCPBlockSocket.Create;
  FListener.CreateSocket;
  { 127.0.0.1 and not 0.0.0.0: this must not be reachable from the
    network, whatever else is wrong with the token. }
  FListener.Bind('127.0.0.1', IntToStr(FPort));
  FBound := FListener.LastError = 0;
  if FBound then begin
    FListener.Listen;
    FBound := FListener.LastError = 0;
  end;
end;

destructor TLocalServer.Destroy;
begin
  if FListener <> nil then begin
    FListener.CloseSocket;
    FreeAndNil(FListener);
  end;
  inherited Destroy;
end;

procedure TLocalServer.Execute;
var
  S: TSocket;
begin
  while not Terminated do begin
    { Polled accept rather than a blocking one, so Terminate is
      noticed within one poll instead of needing the socket torn down
      underneath a blocked call. }
    if FListener.CanRead(LOCAL_SERVER_ACCEPT_POLL_MS) then begin
      S := FListener.Accept;
      if FListener.LastError = 0 then begin
        TServerConn.Create(Self, S);
      end;
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{ module entry points                                                }
{ ------------------------------------------------------------------ }

function ServerRequested(out APort: word): boolean;
var
  I, V: integer;
  S: string;
begin
  Result := False;
  APort := LOCAL_SERVER_PORT;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if S = '--server' then begin
      Result := True;
    end else if Copy(S, 1, 14) = '--server-port=' then begin
      if TryStrToInt(Copy(S, 15, MaxInt), V) and (V > 0) and (V <= 65535) then begin
        APort := word(V);
        { Naming a port implies wanting the server. }
        Result := True;
      end;
    end;
  end;
end;

procedure SetWebMessageHandler(AHandler: TWebMessageEvent);
begin
  GOnMessage := AHandler;
end;

function WebSendTo(AConnId: Int64; const AText: utf8string): boolean;
var
  I: integer;
  C: TServerConn;
begin
  Result := False;
  if GConnsLock = nil then begin
    Exit;
  end;
  GConnsLock.Enter;
  try
    for I := 0 to GConns.Count - 1 do begin
      C := TServerConn(GConns[I]);
      if C.ConnId = AConnId then begin
        C.SendText(AText);
        Result := True;
        Exit;
      end;
    end;
  finally
    GConnsLock.Leave;
  end;
end;

procedure WebBroadcast(const AText: utf8string);
var
  I: integer;
begin
  if GConnsLock = nil then begin
    Exit;
  end;
  GConnsLock.Enter;
  try
    for I := 0 to GConns.Count - 1 do begin
      TServerConn(GConns[I]).SendText(AText);
    end;
  finally
    GConnsLock.Leave;
  end;
end;

function LocalServerUrl: string;
begin
  if GServer = nil then begin
    Result := '';
  end else begin
    Result := 'http://127.0.0.1:' + IntToStr(GServer.Port) + '/?t=' + GServer.Token;
  end;
end;

procedure WriteUrlFile;
var
  F: TextFile;
begin
  try
    AssignFile(F, ExtractFilePath(ParamStr(0)) + LOCAL_SERVER_URL_FILE);
    Rewrite(F);
    try
      WriteLn(F, LocalServerUrl);
    finally
      CloseFile(F);
    end;
  except
    { Not being able to leave the URL on disk is not a reason to
      refuse to serve. }
    on E: Exception do begin
    end;
  end;
end;

function StartLocalServer(APort: word): boolean;
begin
  if GServer <> nil then begin
    Result := True;
    Exit;
  end;
  GStopping := False;
  GServer := TLocalServer.Create(APort);
  if not GServer.Bound then begin
    FreeAndNil(GServer);
    Result := False;
    Exit;
  end;
  GServer.Start;
  WriteUrlFile;
  Result := True;
end;

procedure StopLocalServer;
var
  Waited: integer;
begin
  if GServer = nil then begin
    Exit;
  end;
  { Two stages: stop accepting, then give the live connections a
    bounded chance to unwind. Bounded because a stuck connection must
    not hold application exit, and needed at all because these threads
    outlive the object they point at otherwise — the same
    "don't let ExitProcess catch a thread mid-work" discipline the
    decoder threads already get in tg.lpr. }
  GStopping := True;
  GServer.Terminate;
  GServer.WaitFor;

  Waited := 0;
  while (GActiveConns > 0) and (Waited < LOCAL_SERVER_STOP_WAIT_MS) do begin
    Sleep(10);
    Inc(Waited, 10);
  end;

  FreeAndNil(GServer);
  DeleteFile(ExtractFilePath(ParamStr(0)) + LOCAL_SERVER_URL_FILE);
end;

initialization
  GConns := TFPList.Create;
  GConnsLock := SyncObjs.TCriticalSection.Create;

finalization
  StopLocalServer;
  FreeAndNil(GConns);
  FreeAndNil(GConnsLock);

end.
