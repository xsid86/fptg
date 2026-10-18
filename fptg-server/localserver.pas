unit localserver;

{$mode objfpc}{$H+}

{ The HTTP + WebSocket server of fptg-server: it serves the page,
  carries commands and events over the socket, and media over plain
  HTTP. It touches no model itself. Its clients are the window
  (fptg, fptg-client) and any ordinary browser.

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
  account. Hence: a signed token (JWT, srvauth.pas) required on every
  request that reaches the account — the socket, uploads, media — plus
  an Origin check on the upgrade. Both, not either — the token stops
  non-browser callers, the Origin check stops a page that somehow
  learned the token from using it. The page itself (static files) is
  public: there is nothing secret in it.

  Always TLS (tlscert.pas): our own self-signed certificate or
  --cert/--key. Sign-in — login and password (POST /api/login), then JWT
  (srvauth.pas). The page in the fptg window comes from another address
  (WEB_APP_ORIGIN, the window's files), so the server answers it with CORS
  and lets its web socket in. By default it listens on 127.0.0.1 only;
  --bind opens the network. }

interface

uses
  Classes, SysUtils, SyncObjs, blcksock, synsock, constants, wsframe,
  webfiles, tlscert;

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
    { The session (JWT sid) that opened the web socket; FEnded — the
      session is revoked, the socket closes with
      LOCAL_SERVER_WS_CLOSE_SESSION_ENDED. Set by another thread, read by
      the socket loop. }
    FSid:      string;
    FEnded:    boolean;
    { How many bytes of the socket have been counted (HarvestTraffic). }
    FCountedSent, FCountedRecv: Int64;
    { The Content-Disposition header (with CRLF) for ServeFileFrom: /media/
      with ?save=name is served as an attachment — the browser and the
      window save it rather than show it themselves. '' — as usual. }
    FDisposition: string;
    procedure HarvestTraffic;
    function  ReadExact(ABuf: PByte; ALen: integer): boolean;
    function  ReadRequest: boolean;
    function  HeaderValue(const AName: string): string;
    function  QueryParam(const AName: string): string;
    function  TokenOk(AMedia: boolean): boolean;
    function  CorsHeaders: string;
    procedure ServeOptions;
    procedure ServeApi;
    procedure SendJson(ACode: integer; const AReason, AJson: string);
    function  OriginAllowed: boolean;
    function  MapPath(out AFileName: string): boolean;
    procedure SendSimple(ACode: integer; const AReason, ABody: string;
      const AExtraHeaders: string = '');
    procedure ServeFile;
    procedure ServeMedia;
    procedure ServeUpload;
    procedure ServeFileFrom(const AFileName, AContentType: string);
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
    FBindAddr: string;
    FTls:      TServerTls;
    FWebRoot:  string;
    FBound:    boolean;
    FListener: TTCPBlockSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: word; const ABindAddr: string; const ATls: TServerTls;
      const AWebRoot: string);
    destructor Destroy; override;
    property Port: word read FPort;
    property BindAddr: string read FBindAddr;
    property Tls: TServerTls read FTls;
    property WebRoot: string read FWebRoot;
    property Bound: boolean read FBound;
  end;

{ The port to serve on: LOCAL_SERVER_PORT unless --server-port=N
  overrode it on the command line. There is no flag for whether to
  serve at all any more — the server is part of every launch, see
  fptg-client.lpr. }
function ConfiguredServerPort: word;

{ The address to listen on: LOCAL_SERVER_BIND (this machine only) unless
  --bind=ADDRESS says otherwise. 0.0.0.0 — all of the machine's networks
  (a server on a VPS): then only the token protects it. }
function ConfiguredBindAddress: string;

{ The page folder: --web-dir=PATH or LOCAL_SERVER_WEB_DIR next to the exe. }
function ConfiguredWebDir: string;

{ Binds and starts. False means the port was taken or the socket could
  not be created — the caller decides whether that is fatal. }
function StartLocalServer(APort: word; const ABindAddr: string; const ATls: TServerTls;
  const AWebDir: string): boolean;
procedure StopLocalServer;

{ The server page's address (https), empty when it is not running. }
function LocalServerUrl: string;

{ The address to reach the server at from this machine: the bind address,
  and 127.0.0.1 for 0.0.0.0. }
function LocalServerHost: string;

{ The path of a file received through POST /upload by its id — or '' if
  the id is malformed or there is no such file. The page sends back only
  the id: it cannot see the path on disk and cannot slip in its own. }
function UploadFilePath(const AId: string): string;

{ The name a received file is stored on disk under. In the interface so a
  separate program can test it — like EscapeMarkdownV2 in tdmessages. }
function SafeUploadName(const AName: string): string;

{ A random hex token (CSPRNG on Windows): session ids, relay secrets. }
function NewToken: string;

{ Installed by webapi.pas. While nil, a text frame is simply echoed —
  which is what the transport-check page exercises. }
procedure SetWebMessageHandler(AHandler: TWebMessageEvent);

{ Both take the connection registry lock for the whole send, which is
  what makes it safe to call them from the main thread: a connection
  unregisters itself under the same lock before it can be freed. }
function WebSendTo(AConnId: Int64; const AText: utf8string): boolean;
procedure WebBroadcast(const AText: utf8string);

{ The server's traffic with clients (windows and browsers) since the
  process started: the TLS payload (Synapse counts decrypted bytes; the
  handshake is not counted). ASent — sent to clients, ARecv — received. }
procedure LocalTraffic(out ASent, ARecv: Int64);
{ To every web socket — the traffic of its sign-in session (the traffic
  event: sent, recv — from the server's side). Once a second, from the main
  thread
  (srvhost). }
procedure PushSessionTraffic;

implementation

uses
  { ssl_openssl3 plugs OpenSSL 3 into Synapse (SSLImplementation) when the
    unit loads. }
  ssl_openssl3, fpjson, jsonparser, srvauth, appdirs, turnrelay;

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
  { Traffic with clients: total and per sign-in session (sid -> TTrafficCell). }
  GTrafficLock: SyncObjs.TCriticalSection = nil;
  GTrafficSent: Int64 = 0;
  GTrafficRecv: Int64 = 0;
  GSidTraffic:  TStringList = nil;

type
  TTrafficCell = class
    Sent, Recv: Int64;
  end;

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

function UploadRoot: string;
begin
  Result := ServerDataDir + LOCAL_SERVER_UPLOAD_DIR + PathDelim;
end;

{ An upload id is exactly what NewToken produces: 32 lower-case hex digits.
  Anything else is rejected before it becomes part of a path. }
function IsUploadId(const AId: string): boolean;
var
  I: integer;
begin
  Result := Length(AId) = LOCAL_SERVER_TOKEN_BYTES * 2;
  if not Result then begin
    Exit;
  end;
  for I := 1 to Length(AId) do begin
    if not (AId[I] in ['0'..'9', 'a'..'f']) then begin
      Result := False;
      Exit;
    end;
  end;
end;

{ The name a file is stored on disk and sent to Telegram under. Only the
  last part of the path, without characters Windows forbids, without
  trailing dots and spaces, no longer than LOCAL_SERVER_UPLOAD_NAME_MAX
  bytes (cut at a UTF-8 character boundary, the extension kept), and not
  one of the reserved device names. }
function SafeUploadName(const AName: string): string;
const
  RESERVED: array[0..21] of string = ('CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');
var
  I, Cut: integer;
  S, Ext, Base: string;
begin
  S := StringReplace(AName, '/', '\', [rfReplaceAll]);
  I := LastDelimiter('\', S);
  if I > 0 then begin
    S := Copy(S, I + 1, MaxInt);
  end;
  Result := '';
  for I := 1 to Length(S) do begin
    if (S[I] < #32) or (S[I] in ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then begin
      Result := Result + '_';
    end else begin
      Result := Result + S[I];
    end;
  end;
  while (Result <> '') and (Result[Length(Result)] in ['.', ' ']) do begin
    SetLength(Result, Length(Result) - 1);
  end;
  Result := Trim(Result);
  if Result = '' then begin
    Result := 'file';
  end;

  if Length(Result) > LOCAL_SERVER_UPLOAD_NAME_MAX then begin
    Ext := ExtractFileExt(Result);
    if Length(Ext) > 16 then begin
      Ext := '';
    end;
    Base := Copy(Result, 1, Length(Result) - Length(Ext));
    Cut := LOCAL_SERVER_UPLOAD_NAME_MAX - Length(Ext);
    { Do not cut in the middle of a multi-byte character: UTF-8
      continuation bytes look like 10xxxxxx. }
    while (Cut > 0) and ((Ord(Base[Cut + 1]) and $C0) = $80) do begin
      Dec(Cut);
    end;
    Result := Copy(Base, 1, Cut) + Ext;
  end;

  Base := UpperCase(ChangeFileExt(Result, ''));
  for I := Low(RESERVED) to High(RESERVED) do begin
    if Base = RESERVED[I] then begin
      Result := '_' + Result;
      Break;
    end;
  end;
end;

{ Deletes an upload's folder entirely (it holds one file). }
procedure RemoveUploadDir(const ADir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then begin
          DeleteFile(IncludeTrailingPathDelimiter(ADir) + SR.Name);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(ADir);
end;

{ Abandoned uploads of previous runs. Only folders named with an id:
  anything else in this folder is left alone. }
procedure ClearUploads;
var
  SR: TSearchRec;
begin
  if FindFirst(UploadRoot + '*', faDirectory, SR) = 0 then begin
    try
      repeat
        if ((SR.Attr and faDirectory) <> 0) and IsUploadId(SR.Name) then begin
          RemoveUploadDir(UploadRoot + SR.Name);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

function UploadFilePath(const AId: string): string;
var
  SR: TSearchRec;
  Dir: string;
begin
  Result := '';
  if not IsUploadId(AId) then begin
    Exit;
  end;
  Dir := UploadRoot + AId + PathDelim;
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then begin
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then begin
          Result := Dir + SR.Name;
          Exit;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
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

{ Bytes of the socket not counted yet — into the total and into the
  session's count. Only from the connection thread: Synapse's counters grow
  from the main thread's sends too (SendText), but reading an Int64 on x64
  is safe, and what has been counted is kept right here. Bytes before the
  session is known (TLS, request headers) go to its count on the first
  harvest after. }
procedure TServerConn.HarvestTraffic;
var
  S, R: Int64;
  I: integer;
  Cell: TTrafficCell;
begin
  S := FSock.SendCounter - FCountedSent;
  R := FSock.RecvCounter - FCountedRecv;
  if (S <= 0) and (R <= 0) then begin
    Exit;
  end;
  Inc(FCountedSent, S);
  Inc(FCountedRecv, R);
  GTrafficLock.Enter;
  try
    Inc(GTrafficSent, S);
    Inc(GTrafficRecv, R);
    if FSid <> '' then begin
      I := GSidTraffic.IndexOf(FSid);
      if I < 0 then begin
        I := GSidTraffic.AddObject(FSid, TTrafficCell.Create);
      end;
      Cell := TTrafficCell(GSidTraffic.Objects[I]);
      Inc(Cell.Sent, S);
      Inc(Cell.Recv, R);
    end;
  finally
    GTrafficLock.Leave;
  end;
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


{ The request's JWT: ?t= (the web socket and <img> cannot send headers) or
  Authorization: Bearer. AMedia — a /media/ address (accepts the media
  token too, srvauth). }
function TServerConn.TokenOk(AMedia: boolean): boolean;
var
  T: string;
begin
  T := QueryParam('t');
  if (T = '') and SameText(Copy(HeaderValue('authorization'), 1, 7), 'Bearer ') then begin
    T := Trim(Copy(HeaderValue('authorization'), 8, MaxInt));
  end;
  if AMedia then begin
    Result := (T <> '') and AuthCheck(T, ascMedia);
  end else begin
    Result := (T <> '') and AuthCheck(T, ascApi);
  end;
  { Whose request this is — for counting traffic per session. }
  if Result and (FSid = '') then begin
    FSid := AuthSessionId(T);
  end;
end;

{ CORS — only for our own: the window's page (WEB_APP_ORIGIN) and the page
  from the server itself. A foreign page will not read the answer. }
function TServerConn.CorsHeaders: string;
var
  O: string;
begin
  Result := '';
  O := HeaderValue('origin');
  if (O <> '') and OriginAllowed then begin
    Result := 'Access-Control-Allow-Origin: ' + O + CRLF + 'Vary: Origin' + CRLF;
  end;
end;

{ The browser's preflight request (POST with JSON, an upload,
  Authorization). Private-Network — for Chromium: the window's page
  reaches "from outside" to
  127.0.0.1. }
procedure TServerConn.ServeOptions;
var
  H: string;
begin
  H := 'HTTP/1.1 204 No Content' + CRLF + CorsHeaders
     + 'Access-Control-Allow-Methods: GET, POST, OPTIONS' + CRLF
     + 'Access-Control-Allow-Headers: Content-Type, Authorization' + CRLF
     + 'Access-Control-Max-Age: 600' + CRLF;
  if HeaderValue('access-control-request-private-network') <> '' then begin
    H := H + 'Access-Control-Allow-Private-Network: true' + CRLF;
  end;
  FSock.SendString(H + 'Content-Length: 0' + CRLF + 'Connection: close' + CRLF + CRLF);
end;

procedure TServerConn.SendJson(ACode: integer; const AReason, AJson: string);
begin
  FSock.SendString('HTTP/1.1 ' + IntToStr(ACode) + ' ' + AReason + CRLF
    + 'Content-Type: application/json; charset=utf-8' + CRLF
    + 'Content-Length: ' + IntToStr(Length(AJson)) + CRLF
    + 'Cache-Control: no-store' + CRLF
    + CorsHeaders
    + 'Connection: close' + CRLF + CRLF + AJson);
end;

{ POST /api/login | /api/refresh | /api/logout — JSON both ways
  (srvauth.pas). Without a token: this is the way to get one. }
procedure TServerConn.ServeApi;
var
  Len: Int64;
  Body: RawByteString;
  D: TJSONData;
  O, R: TJSONObject;
  Refresh, Access, Media, User, Err: string;
  Expires: Int64;
begin
  Len := StrToInt64Def(HeaderValue('content-length'), -1);
  if (Len < 0) or (Len > AUTH_MAX_BODY) then begin
    SendSimple(413, 'Payload Too Large', 'bad request body');
    Exit;
  end;
  SetLength(Body, Len);
  if (Len > 0) and not ReadExact(@Body[1], Len) then begin
    Exit;
  end;
  D := nil;
  try
    D := GetJSON(Body);
  except
    D := nil;
  end;
  R := TJSONObject.Create;
  try
    if not (D is TJSONObject) then begin
      R.Add('error', 'Bad request');
      SendJson(400, 'Bad Request', R.AsJSON);
      Exit;
    end;
    O := TJSONObject(D);
    if FPath = API_LOGIN_PATH then begin
      if AuthLogin(O.Get('user', ''), O.Get('password', ''), O.Get('device', ''),
          FSock.GetRemoteSinIP, Refresh, Err) then begin
        R.Add('refresh', Refresh);
        SendJson(200, 'OK', R.AsJSON);
      end else begin
        R.Add('error', Err);
        SendJson(401, 'Unauthorized', R.AsJSON);
      end;
    end else if FPath = API_REFRESH_PATH then begin
      if AuthRefresh(O.Get('refresh', ''), Access, Media, User, Expires, Err) then begin
        R.Add('access', Access);
        R.Add('media', Media);
        R.Add('user', User);
        R.Add('expires', Expires);
        { The lifetime — as a duration too: the page's clock may run differently. }
        R.Add('ttl', AUTH_ACCESS_TTL_SEC);
        SendJson(200, 'OK', R.AsJSON);
      end else begin
        R.Add('error', Err);
        SendJson(401, 'Unauthorized', R.AsJSON);
      end;
    end else begin
      AuthLogout(O.Get('refresh', ''));
      R.Add('ok', True);
      SendJson(200, 'OK', R.AsJSON);
    end;
  finally
    R.Free;
    D.Free;
  end;
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
  Result := (O = WEB_APP_ORIGIN)
         or (O = 'https://127.0.0.1:' + IntToStr(FOwner.Port))
         or (O = 'https://localhost:' + IntToStr(FOwner.Port));
  { The server listens not only on loopback (--bind): the page was opened
    by the machine's address, and its Origin is that address, i.e. the
    request's Host. A foreign page that pointed its DNS at our address gets
    through this — the token stops it: it has no cookie and does not know
    the token itself. }
  if (not Result) and (FOwner.BindAddr <> LOCAL_SERVER_BIND) then begin
    Result := O = 'https://' + LowerCase(HeaderValue('host'));
  end;
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

{ POST /upload?name=<name>: the request body streamed into
  uploads/<id>/<name>, the id in reply (text/plain).

  The Origin is checked here too, not only on the WebSocket: a POST from a
  foreign browser tab would be sent with our cookie, and without this check
  any page could put files on disk. Content-Length is required — fetch and
  XMLHttpRequest with a file body always send it, and without a length one
  can neither refuse a too large one in advance nor tell that the body
  arrived whole. A broken-off body is erased together with its folder, and
  there is no answer to it: the connection is gone. }
procedure TServerConn.ServeUpload;
var
  Len, Left: Int64;
  Id, Dir, Full: string;
  Buf: array of byte;
  Want, Got: integer;
  F: TFileStream;
  Ok: boolean;
begin
  if not OriginAllowed then begin
    SendSimple(403, 'Forbidden', 'forbidden');
    Exit;
  end;
  Len := StrToInt64Def(HeaderValue('content-length'), -1);
  if Len < 0 then begin
    SendSimple(411, 'Length Required', 'length required');
    Exit;
  end;
  if Len > LOCAL_SERVER_UPLOAD_MAX then begin
    SendSimple(413, 'Payload Too Large', 'file too large');
    Exit;
  end;

  Id := NewToken;
  Dir := UploadRoot + Id;
  if not ForceDirectories(Dir) then begin
    SendSimple(500, 'Internal Server Error', 'cannot create upload directory');
    Exit;
  end;
  Full := Dir + PathDelim + SafeUploadName(QueryParam('name'));

  Ok := False;
  F := TFileStream.Create(Full, fmCreate);
  try
    SetLength(Buf, LOCAL_SERVER_UPLOAD_CHUNK);
    Left := Len;
    while (Left > 0) and (not GStopping) do begin
      if Left < LOCAL_SERVER_UPLOAD_CHUNK then begin
        Want := integer(Left);
      end else begin
        Want := LOCAL_SERVER_UPLOAD_CHUNK;
      end;
      Got := FSock.RecvBufferEx(@Buf[0], Want, LOCAL_SERVER_HTTP_TIMEOUT_MS);
      if Got > 0 then begin
        F.WriteBuffer(Buf[0], Got);
        Dec(Left, Got);
        HarvestTraffic;
      end;
      if (FSock.LastError <> 0) or (Got <= 0) then begin
        Break;
      end;
    end;
    Ok := Left = 0;
  finally
    F.Free;
  end;

  if not Ok then begin
    RemoveUploadDir(Dir);
    Exit;
  end;
  SendSimple(200, 'OK', Id);
end;

procedure TServerConn.SendSimple(ACode: integer; const AReason, ABody: string;
  const AExtraHeaders: string);
var
  H: string;
begin
  H := 'HTTP/1.1 ' + IntToStr(ACode) + ' ' + AReason + CRLF
     + 'Content-Type: text/plain; charset=utf-8' + CRLF
     + 'Content-Length: ' + IntToStr(Length(ABody)) + CRLF
     + CorsHeaders
     + 'Connection: close' + CRLF;
  if AExtraHeaders <> '' then begin
    H := H + AExtraHeaders + CRLF;
  end;
  FSock.SendString(H + CRLF + ABody);
end;

{ A file out of the web root — the pages, scripts and styles this
  project ships. }
procedure TServerConn.ServeFile;
var
  Fn: string;
begin
  if not MapPath(Fn) then begin
    SendSimple(404, 'Not Found', 'not found');
    Exit;
  end;
  ServeFileFrom(Fn, ContentTypeFor(Fn));
end;

{ /media/<file_id> — a file out of TDLib's cache: a photo, a video, a
  track, a sticker. The URL carries no path, only TDLib's own integer
  file id, and the only paths that can come back from webfiles are ones
  the model itself published — so there is nothing here for a
  traversal attempt to work with, and MapPath's containment check has
  no equivalent to do.

  Note what this does NOT do: ask the model anything. This runs on a
  socket thread, and the model is the main thread's. The lookup is a
  lock-protected integer-to-path map and nothing more. }
{ Content-Disposition: attachment with the file name: filename* — UTF-8 in
  percent encoding (RFC 6266/5987), filename — ASCII as a fallback. The
  name goes through SafeUploadName: no paths, no reserved Windows names. }
function AttachmentHeader(const AName: string): string;
const
  HEX = '0123456789ABCDEF';
var
  Safe, Ascii, Pct: string;
  I: integer;
  B: byte;
begin
  Safe := SafeUploadName(AName);
  Ascii := '';
  Pct := '';
  for I := 1 to Length(Safe) do begin
    B := Ord(Safe[I]);
    if (B >= 32) and (B < 127) and (Safe[I] <> '"') and (Safe[I] <> '\') then begin
      Ascii := Ascii + Safe[I];
    end else begin
      Ascii := Ascii + '_';
    end;
    if Safe[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then begin
      Pct := Pct + Safe[I];
    end else begin
      Pct := Pct + '%' + HEX[(B shr 4) + 1] + HEX[(B and $F) + 1];
    end;
  end;
  Result := 'Content-Disposition: attachment; filename="' + Ascii
    + '"; filename*=UTF-8''''' + Pct + CRLF;
end;

procedure TServerConn.ServeMedia;
var
  Ids, Fn: string;
  FileId, Err: integer;
begin
  Ids := Copy(FPath, Length('/media/') + 1, MaxInt);
  Val(Ids, FileId, Err);
  if (Err <> 0) or (FileId = 0) then begin
    SendSimple(404, 'Not Found', 'not found');
    Exit;
  end;
  if not WebFileResolve(FileId, Fn) then begin
    { Known id, nothing on disk yet: the download has not finished, or
      this build never saw the file. Either way there is nothing to
      send, and the page retries when the model says the file landed. }
    SendSimple(404, 'Not Found', 'not downloaded');
    Exit;
  end;
  { save=* — the file's name on disk (photos and videos have no name of their own). }
  if QueryParam('save') = '*' then begin
    FDisposition := AttachmentHeader(ExtractFileName(Fn));
  end else if QueryParam('save') <> '' then begin
    FDisposition := AttachmentHeader(QueryParam('save'));
  end;
  ServeFileFrom(Fn, MediaContentType(Fn));
end;

{ The shared body: range handling, headers, and the send loop. Both
  routes above resolve a path their own way and then end up here, so
  there is one implementation of Range rather than two that drift. }
procedure TServerConn.ServeFileFrom(const AFileName, AContentType: string);
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
  Fn := AFileName;
  Ct := AContentType;
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
         + FDisposition
         { Local files that change under the page (a download finishing
           and replacing a placeholder) must not be cached while this
           is being developed. }
         + 'Cache-Control: no-store' + CRLF
         + CorsHeaders
         + 'Connection: close' + CRLF;
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
      HarvestTraffic;
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

  while (not Terminated) and (not GStopping) and (not FEnded) do begin
    HarvestTraffic;
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
  if FEnded then begin
    { The session is revoked (sign-out, user removed, "sign out
      everywhere"): the page goes straight to sign-in rather than
      reconnecting. }
    WsSend(wsoClose, WsCloseCode(LOCAL_SERVER_WS_CLOSE_SESSION_ENDED));
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

{ The first byte of the connection, without taking it out of the socket;
  -1 — nothing came in time. }
function PeekFirstByte(ASock: TTCPBlockSocket): integer;
var
  B: byte;
begin
  Result := -1;
  if ASock.CanRead(LOCAL_SERVER_HTTP_TIMEOUT_MS)
     and (synsock.Recv(ASock.Socket, @B, 1, MSG_PEEK) = 1) then begin
    Result := B;
  end;
end;

procedure TServerConn.Execute;
var
  IsWs: boolean;
  First: integer;
begin
  try
    try
      { The call relay shares this port (turnrelay.pas): a TURN client
        starts with a STUN message, TLS with 0x16. }
      if RelayEnabled then begin
        First := PeekFirstByte(FSock);
        if First < 0 then begin
          Exit;
        end;
        if IsTurnFirstByte(byte(First)) then begin
          ServeTurn(FSock);
          Exit;
        end;
      end;
      { TLS — before the first byte of the request. A non-TLS client
        (http:// on this port) does not get past here. }
      if FOwner.Tls.CertFile <> '' then begin
        FSock.SSL.CertificateFile := FOwner.Tls.CertFile;
        FSock.SSL.PrivateKeyFile := FOwner.Tls.KeyFile;
      end else begin
        FSock.SSL.Certificate := FOwner.Tls.CertDer;
        FSock.SSL.PrivateKey := FOwner.Tls.KeyDer;
      end;
      if (not FSock.SSLAcceptConnection) or (FSock.LastError <> 0) then begin
        Exit;
      end;
      if not ReadRequest then begin
        Exit;
      end;
      if FMethod = 'OPTIONS' then begin
        ServeOptions;
        Exit;
      end;
      if FMethod = 'POST' then begin
        if (FPath = API_LOGIN_PATH) or (FPath = API_REFRESH_PATH)
           or (FPath = API_LOGOUT_PATH) then begin
          ServeApi;
        end else if FPath = LOCAL_SERVER_UPLOAD_PATH then begin
          if TokenOk(False) then begin
            ServeUpload;
          end else begin
            SendSimple(403, 'Forbidden', 'forbidden');
          end;
        end else begin
          SendSimple(405, 'Method Not Allowed', 'not here');
        end;
        Exit;
      end;
      if not ((FMethod = 'GET') or (FMethod = 'HEAD')) then begin
        SendSimple(405, 'Method Not Allowed', 'only GET/HEAD/POST/OPTIONS');
        Exit;
      end;
      { Deliberately bland and identical for "no token" and "wrong token"
        — there is nothing to be gained by telling a caller which. The
        page itself (static files) needs no token: there are no secrets in
        it, and without it one cannot sign in. }
      IsWebSocketRequest(IsWs);
      if IsWs then begin
        if TokenOk(False) then begin
          FSid := AuthSessionId(QueryParam('t'));
          ServeWebSocket;
        end else begin
          SendSimple(403, 'Forbidden', 'forbidden');
        end;
      end else if Copy(FPath, 1, Length('/media/')) = '/media/' then begin
        if TokenOk(True) then begin
          ServeMedia;
        end else begin
          SendSimple(403, 'Forbidden', 'forbidden');
        end;
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
    try
      HarvestTraffic;
    except
      { traffic counting is no reason to bring the thread down }
    end;
    FSock.CloseSocket;
  end;
end;

{ ------------------------------------------------------------------ }
{ TLocalServer                                                       }
{ ------------------------------------------------------------------ }

constructor TLocalServer.Create(APort: word; const ABindAddr: string; const ATls: TServerTls;
  const AWebRoot: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPort := APort;
  FBindAddr := ABindAddr;
  FTls := ATls;
  FWebRoot := IncludeTrailingPathDelimiter(AWebRoot);

  FListener := TTCPBlockSocket.Create;
  FListener.CreateSocket;
  { 127.0.0.1 by default, not 0.0.0.0: the server is not visible from the
    network whatever happens to the token. Anything else — only
    explicitly, --bind. }
  FListener.Bind(FBindAddr, IntToStr(FPort));
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

function ConfiguredServerPort: word;
var
  I, V: integer;
  S: string;
begin
  Result := LOCAL_SERVER_PORT;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if Copy(S, 1, 14) = '--server-port=' then begin
      if TryStrToInt(Copy(S, 15, MaxInt), V) and (V > 0) and (V <= 65535) then begin
        Result := word(V);
      end;
    end;
  end;
end;

function ParamValue(const APrefix: string): string;
var
  I: integer;
begin
  Result := '';
  for I := 1 to ParamCount do begin
    if Copy(ParamStr(I), 1, Length(APrefix)) = APrefix then begin
      Result := Copy(ParamStr(I), Length(APrefix) + 1, MaxInt);
    end;
  end;
end;

function ConfiguredBindAddress: string;
begin
  Result := Trim(ParamValue('--bind='));
  if Result = '' then begin
    Result := LOCAL_SERVER_BIND;
  end;
end;

function ConfiguredWebDir: string;
begin
  Result := Trim(ParamValue('--web-dir='));
  if Result = '' then begin
    Result := ExtractFilePath(ParamStr(0)) + LOCAL_SERVER_WEB_DIR;
    { Not the source tree but a release archive: web next to the exe. }
    if not DirectoryExists(Result) then begin
      Result := ExtractFilePath(ParamStr(0)) + LOCAL_SERVER_WEB_DIR_RELEASE;
    end;
  end;
  Result := ExpandFileName(Result);
end;

procedure SetWebMessageHandler(AHandler: TWebMessageEvent);
begin
  GOnMessage := AHandler;
end;

{ Sessions revoked (srvauth): close their web sockets. ASids = nil — all.
  The socket loop notices the flag within LOCAL_SERVER_WS_POLL_MS. }
procedure EndSessionSockets(ASids: TStrings);
var
  I: integer;
  C: TServerConn;
begin
  if GConnsLock = nil then begin
    Exit;
  end;
  GConnsLock.Enter;
  try
    for I := 0 to GConns.Count - 1 do begin
      C := TServerConn(GConns[I]);
      if (ASids = nil) or (ASids.IndexOf(C.FSid) >= 0) then begin
        C.FEnded := True;
      end;
    end;
  finally
    GConnsLock.Leave;
  end;
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

procedure LocalTraffic(out ASent, ARecv: Int64);
begin
  GTrafficLock.Enter;
  try
    ASent := GTrafficSent;
    ARecv := GTrafficRecv;
  finally
    GTrafficLock.Leave;
  end;
end;

procedure PushSessionTraffic;
var
  I, J: integer;
  C: TServerConn;
  S, R: Int64;
begin
  if GConnsLock = nil then begin
    Exit;
  end;
  { Lock order: the registry, then traffic — HarvestTraffic takes only the
    second. }
  GConnsLock.Enter;
  try
    for I := 0 to GConns.Count - 1 do begin
      C := TServerConn(GConns[I]);
      if C.FSid = '' then begin
        Continue;
      end;
      S := 0;
      R := 0;
      GTrafficLock.Enter;
      try
        J := GSidTraffic.IndexOf(C.FSid);
        if J >= 0 then begin
          S := TTrafficCell(GSidTraffic.Objects[J]).Sent;
          R := TTrafficCell(GSidTraffic.Objects[J]).Recv;
        end;
      finally
        GTrafficLock.Leave;
      end;
      C.SendText(utf8string('{"event":"traffic","data":{"sent":' + IntToStr(S)
        + ',"recv":' + IntToStr(R) + '}}'));
    end;
  finally
    GConnsLock.Leave;
  end;
end;

function LocalServerHost: string;
begin
  Result := '';
  if GServer <> nil then begin
    Result := GServer.BindAddr;
    if (Result = '0.0.0.0') or (Result = '::') or (Result = '') then begin
      Result := LOCAL_SERVER_BIND;
    end;
  end;
end;

function LocalServerUrl: string;
begin
  if GServer = nil then begin
    Result := '';
  end else begin
    Result := 'https://' + LocalServerHost + ':' + IntToStr(GServer.Port) + '/';
  end;
end;

function StartLocalServer(APort: word; const ABindAddr: string; const ATls: TServerTls;
  const AWebDir: string): boolean;
begin
  if GServer <> nil then begin
    Result := True;
    Exit;
  end;
  GStopping := False;
  GServer := TLocalServer.Create(APort, ABindAddr, ATls, AWebDir);
  if not GServer.Bound then begin
    FreeAndNil(GServer);
    Result := False;
    Exit;
  end;
  GServer.Start;
  { Before this run's first upload: whatever lies there is abandoned. }
  ClearUploads;
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
    decoder threads already get in fptg-client.lpr. }
  GStopping := True;
  GServer.Terminate;
  GServer.WaitFor;

  Waited := 0;
  while (GActiveConns > 0) and (Waited < LOCAL_SERVER_STOP_WAIT_MS) do begin
    Sleep(10);
    Inc(Waited, 10);
  end;

  FreeAndNil(GServer);
end;

initialization
  GConns := TFPList.Create;
  GConnsLock := SyncObjs.TCriticalSection.Create;
  GTrafficLock := SyncObjs.TCriticalSection.Create;
  GSidTraffic := TStringList.Create;
  GSidTraffic.OwnsObjects := True;
  GSidTraffic.Sorted := True;
  AuthSessionsEnded := @EndSessionSockets;

finalization
  StopLocalServer;
  FreeAndNil(GConns);
  FreeAndNil(GConnsLock);
  FreeAndNil(GSidTraffic);
  FreeAndNil(GTrafficLock);

end.
