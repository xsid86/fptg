unit turnrelay;

{$mode objfpc}{$H+}

{ A TURN relay inside the fptg server (RFC 8656 over RFC 8489 STUN), for
  calls when the client cannot reach Telegram itself: the server is on a
  VPS, and the client's network blocks Telegram. The browser can send
  WebRTC media only directly or through TURN, so the server becomes the
  client's TURN server, and the media leaves from the server's address.

  The relay shares the HTTPS port: the connection thread peeks at the
  first byte (TServerConn.Execute): TLS starts with 0x16, a STUN message
  with 0x00..0x3F, ChannelData with 0x40..0x4F. TURN goes over plain TCP,
  not TLS: the browser checks a TURNS certificate, and the server's own
  self-signed one would not pass. The media itself stays end-to-end
  encrypted (DTLS-SRTP between the client and Telegram or the other side);
  the relay sees only packets.

  The subset: Allocate (UDP only, IPv4), Refresh, CreatePermission,
  ChannelBind, Send and Data indications, ChannelData, plus Binding.
  Authentication — long-term credentials (MESSAGE-INTEGRITY, HMAC-SHA1)
  with time-limited passwords in the "TURN REST API" style: the user name
  is "<expiry>:fptg", the password is base64(HMAC-SHA1(secret, user name)).
  The secret lives only in this process; the page gets credentials over
  its signed-in WebSocket (webapi relay.get).

  One allocation per TCP connection, as TURN over TCP intends: the
  connection thread reads the client, a reader thread per allocation
  reads the UDP socket. }

interface

uses
  Classes, SysUtils, blcksock;

type
  TRelayConfig = record
    Enabled: boolean;
    { The relayed address peers send to; '' — the address the client's
      TCP connection came in on (right on a VPS with a public interface). }
    Address: string;
    { UDP ports for allocations; 0..0 — any free one. }
    PortMin, PortMax: word;
  end;

procedure RelayConfigure(const AConfig: TRelayConfig);
function RelayEnabled: boolean;
{ Fresh credentials for the page; False — the relay is off. }
function RelayCredentials(out AUser, APass: string; out ATtl: integer): boolean;
{ Whether a connection that starts with this byte speaks TURN. }
function IsTurnFirstByte(AByte: byte): boolean;
{ Serves a TURN client on an accepted (not TLS) connection until it
  closes. Runs on the connection's own thread. }
procedure ServeTurn(ASock: TTCPBlockSocket);

implementation

uses
  SyncObjs, synsock, hmac, md5, crc, base64, DateUtils, constants, localserver;

const
  STUN_MAGIC = $2112A442;
  STUN_HEADER = 20;

  { methods }
  M_BINDING = $001;
  M_ALLOCATE = $003;
  M_REFRESH = $004;
  M_SEND = $006;
  M_DATA = $007;
  M_CREATE_PERMISSION = $008;
  M_CHANNEL_BIND = $009;

  { classes (bits C1 C0 of the message type) }
  C_REQUEST = $0000;
  C_INDICATION = $0010;
  C_SUCCESS = $0100;
  C_ERROR = $0110;

  { attributes }
  A_MAPPED_ADDRESS = $0001;
  A_USERNAME = $0006;
  A_MESSAGE_INTEGRITY = $0008;
  A_ERROR_CODE = $0009;
  A_UNKNOWN_ATTRIBUTES = $000A;
  A_CHANNEL_NUMBER = $000C;
  A_LIFETIME = $000D;
  A_XOR_PEER_ADDRESS = $0012;
  A_DATA = $0013;
  A_REALM = $0014;
  A_NONCE = $0015;
  A_XOR_RELAYED_ADDRESS = $0016;
  A_REQUESTED_ADDRESS_FAMILY = $0017;
  A_EVEN_PORT = $0018;
  A_REQUESTED_TRANSPORT = $0019;
  A_DONT_FRAGMENT = $001A;
  A_MESSAGE_INTEGRITY_SHA256 = $001C;
  A_PASSWORD_ALGORITHM = $001D;
  A_USERHASH = $001E;
  A_XOR_MAPPED_ADDRESS = $0020;
  A_RESERVATION_TOKEN = $0022;
  A_PRIORITY = $0024;
  A_USE_CANDIDATE = $0025;
  A_SOFTWARE = $8022;
  A_FINGERPRINT = $8028;

  FINGERPRINT_XOR = $5354554E;
  UDP_PROTOCOL = 17;
  FAMILY_IPV4 = 1;
  FAMILY_IPV6 = 2;
  CHANNEL_MIN = $4000;
  CHANNEL_MAX = $4FFF;

var
  GConfig: TRelayConfig;
  GSecret: string = '';
  GLock: TCriticalSection = nil;

{ ------------------------------------------------------------------ }
{ bytes                                                              }
{ ------------------------------------------------------------------ }

function U16(const S: RawByteString; APos: integer): word;
begin
  Result := (word(byte(S[APos])) shl 8) or byte(S[APos + 1]);
end;

function U32(const S: RawByteString; APos: integer): cardinal;
begin
  Result := (cardinal(byte(S[APos])) shl 24) or (cardinal(byte(S[APos + 1])) shl 16)
    or (cardinal(byte(S[APos + 2])) shl 8) or byte(S[APos + 3]);
end;

function B16(AValue: word): RawByteString;
begin
  SetLength(Result, 2);
  Result[1] := AnsiChar(AValue shr 8);
  Result[2] := AnsiChar(AValue and $FF);
end;

function B32(AValue: cardinal): RawByteString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar(AValue shr 24);
  Result[2] := AnsiChar((AValue shr 16) and $FF);
  Result[3] := AnsiChar((AValue shr 8) and $FF);
  Result[4] := AnsiChar(AValue and $FF);
end;

procedure PutU16(var S: RawByteString; APos: integer; AValue: word);
begin
  S[APos] := AnsiChar(AValue shr 8);
  S[APos + 1] := AnsiChar(AValue and $FF);
end;

function Pad4(ALen: integer): integer;
begin
  Result := (ALen + 3) and not 3;
end;

function IpToU32(const AIp: string; out AValue: cardinal): boolean;
var
  Parts: TStringArray;
  I, N: integer;
begin
  Result := False;
  AValue := 0;
  Parts := AIp.Split(['.']);
  if Length(Parts) <> 4 then begin
    Exit;
  end;
  for I := 0 to 3 do begin
    if (not TryStrToInt(Parts[I], N)) or (N < 0) or (N > 255) then begin
      Exit;
    end;
    AValue := (AValue shl 8) or cardinal(N);
  end;
  Result := True;
end;

function U32ToIp(AValue: cardinal): string;
begin
  Result := IntToStr(AValue shr 24) + '.' + IntToStr((AValue shr 16) and $FF) + '.'
    + IntToStr((AValue shr 8) and $FF) + '.' + IntToStr(AValue and $FF);
end;

{ The XOR-*-ADDRESS value for an IPv4 address. }
function XorAddress(const AIp: string; APort: word): RawByteString;
var
  V: cardinal;
begin
  if not IpToU32(AIp, V) then begin
    V := 0;
  end;
  Result := #0 + AnsiChar(FAMILY_IPV4) + B16(APort xor (STUN_MAGIC shr 16))
    + B32(V xor STUN_MAGIC);
end;

{ The XOR-*-ADDRESS value -> IPv4 address and port; False — not IPv4 or
  malformed. }
function ParseXorAddress(const AValue: RawByteString; out AIp: string;
  out APort: word): boolean;
begin
  Result := False;
  AIp := '';
  APort := 0;
  if (Length(AValue) < 8) or (byte(AValue[2]) <> FAMILY_IPV4) then begin
    Exit;
  end;
  APort := U16(AValue, 3) xor (STUN_MAGIC shr 16);
  AIp := U32ToIp(U32(AValue, 5) xor STUN_MAGIC);
  Result := True;
end;

function DigestToStr(const ADigest: array of byte): RawByteString;
var
  I: integer;
begin
  SetLength(Result, Length(ADigest));
  for I := 0 to High(ADigest) do begin
    Result[I + 1] := AnsiChar(ADigest[I]);
  end;
end;

function HmacSha1Raw(const AKey, AMessage: RawByteString): RawByteString;
begin
  Result := DigestToStr(HMACSHA1Digest(AKey, AMessage));
end;

{ ------------------------------------------------------------------ }
{ credentials                                                        }
{ ------------------------------------------------------------------ }

function PasswordFor(const AUser: string): string;
begin
  Result := EncodeStringBase64(HmacSha1Raw(GSecret, AUser));
end;

{ The user name is "<unix expiry>:fptg"; True — not expired. }
function UserValid(const AUser: string): boolean;
var
  P: integer;
  Expiry: Int64;
begin
  Result := False;
  P := Pos(':', AUser);
  if (P < 2) or (Copy(AUser, P + 1, MaxInt) <> RELAY_REALM) then begin
    Exit;
  end;
  if not TryStrToInt64(Copy(AUser, 1, P - 1), Expiry) then begin
    Exit;
  end;
  Result := Expiry > DateTimeToUnix(Now, False);
end;

{ The long-term key: MD5(user:realm:password). }
function LongTermKey(const AUser: string): RawByteString;
begin
  Result := DigestToStr(MD5String(AUser + ':' + RELAY_REALM + ':' + PasswordFor(AUser)));
end;

{ ------------------------------------------------------------------ }
{ messages                                                           }
{ ------------------------------------------------------------------ }

type
  TStunAttr = record
    AType: word;
    Value: RawByteString;
    Offset: integer;  { of the attribute header, from the message start (0-based) }
  end;

  TStunMsg = record
    Raw: RawByteString;
    MsgType: word;
    Tid: RawByteString;  { 12 bytes }
    Attrs: array of TStunAttr;
  end;

function ParseStun(const ARaw: RawByteString; out AMsg: TStunMsg): boolean;
var
  P, Len, ALen: integer;
  A: TStunAttr;
begin
  Result := False;
  AMsg.Raw := ARaw;
  AMsg.Attrs := nil;
  if (Length(ARaw) < STUN_HEADER) or (U32(ARaw, 5) <> STUN_MAGIC) then begin
    Exit;
  end;
  AMsg.MsgType := U16(ARaw, 1);
  Len := U16(ARaw, 3);
  if Len + STUN_HEADER <> Length(ARaw) then begin
    Exit;
  end;
  AMsg.Tid := Copy(ARaw, 9, 12);
  P := STUN_HEADER + 1;
  while P <= Length(ARaw) do begin
    if P + 3 > Length(ARaw) then begin
      Exit;
    end;
    A.AType := U16(ARaw, P);
    ALen := U16(ARaw, P + 2);
    if P + 3 + ALen > Length(ARaw) then begin
      Exit;
    end;
    A.Value := Copy(ARaw, P + 4, ALen);
    A.Offset := P - 1;
    SetLength(AMsg.Attrs, Length(AMsg.Attrs) + 1);
    AMsg.Attrs[High(AMsg.Attrs)] := A;
    P := P + 4 + Pad4(ALen);
  end;
  Result := True;
end;

function FindAttr(const AMsg: TStunMsg; AType: word; out AValue: RawByteString): boolean;
var
  I: integer;
begin
  for I := 0 to High(AMsg.Attrs) do begin
    if AMsg.Attrs[I].AType = AType then begin
      AValue := AMsg.Attrs[I].Value;
      Exit(True);
    end;
  end;
  AValue := '';
  Result := False;
end;

function AttrIndex(const AMsg: TStunMsg; AType: word): integer;
var
  I: integer;
begin
  for I := 0 to High(AMsg.Attrs) do begin
    if AMsg.Attrs[I].AType = AType then begin
      Exit(I);
    end;
  end;
  Result := -1;
end;

{ Comprehension-required attributes we do not know, for 420. }
function UnknownAttrs(const AMsg: TStunMsg): RawByteString;
var
  I: integer;
  T: word;
begin
  Result := '';
  for I := 0 to High(AMsg.Attrs) do begin
    T := AMsg.Attrs[I].AType;
    if T >= $8000 then begin
      Continue;
    end;
    case T of
      A_MAPPED_ADDRESS, A_USERNAME, A_MESSAGE_INTEGRITY, A_ERROR_CODE,
      A_UNKNOWN_ATTRIBUTES, A_CHANNEL_NUMBER, A_LIFETIME, A_XOR_PEER_ADDRESS,
      A_DATA, A_REALM, A_NONCE, A_XOR_RELAYED_ADDRESS, A_REQUESTED_ADDRESS_FAMILY,
      A_EVEN_PORT, A_REQUESTED_TRANSPORT, A_DONT_FRAGMENT,
      A_MESSAGE_INTEGRITY_SHA256, A_PASSWORD_ALGORITHM, A_USERHASH,
      A_XOR_MAPPED_ADDRESS, A_RESERVATION_TOKEN, A_PRIORITY, A_USE_CANDIDATE: ;
    else
      Result := Result + B16(T);
    end;
  end;
end;

type
  { A message under construction. }
  TStunWriter = record
    MsgType: word;
    Tid: RawByteString;
    Body: RawByteString;
  end;

procedure WInit(var W: TStunWriter; AType: word; const ATid: RawByteString);
begin
  W.MsgType := AType;
  W.Tid := ATid;
  W.Body := '';
end;

procedure WAdd(var W: TStunWriter; AType: word; const AValue: RawByteString);
begin
  W.Body := W.Body + B16(AType) + B16(Length(AValue)) + AValue
    + StringOfChar(#0, Pad4(Length(AValue)) - Length(AValue));
end;

function WHeader(const W: TStunWriter; ALen: integer): RawByteString;
begin
  Result := B16(W.MsgType) + B16(ALen) + B32(STUN_MAGIC) + W.Tid;
end;

{ The finished message: MESSAGE-INTEGRITY with AKey (when it is not ''),
  then FINGERPRINT. }
function WFinish(var W: TStunWriter; const AKey: RawByteString): RawByteString;
var
  Fp: cardinal;
begin
  if AKey <> '' then begin
    { The length in the header already counts MESSAGE-INTEGRITY (24). }
    WAdd(W, A_MESSAGE_INTEGRITY,
      HmacSha1Raw(AKey, WHeader(W, Length(W.Body) + 24) + W.Body));
  end;
  Result := WHeader(W, Length(W.Body) + 8) + W.Body;
  Fp := crc32(0, PByte(PAnsiChar(Result)), Length(Result)) xor FINGERPRINT_XOR;
  Result := Result + B16(A_FINGERPRINT) + B16(4) + B32(Fp);
end;

{ MESSAGE-INTEGRITY of a request checked with AKey. }
function IntegrityOk(const AMsg: TStunMsg; const AKey: RawByteString): boolean;
var
  I: integer;
  Part: RawByteString;
begin
  Result := False;
  I := AttrIndex(AMsg, A_MESSAGE_INTEGRITY);
  if (I < 0) or (Length(AMsg.Attrs[I].Value) <> 20) then begin
    Exit;
  end;
  Part := Copy(AMsg.Raw, 1, AMsg.Attrs[I].Offset);
  PutU16(Part, 3, AMsg.Attrs[I].Offset - STUN_HEADER + 24);
  Result := HmacSha1Raw(AKey, Part) = AMsg.Attrs[I].Value;
end;

function ErrorCodeValue(ACode: integer; const AReason: string): RawByteString;
begin
  Result := #0#0 + AnsiChar(ACode div 100) + AnsiChar(ACode mod 100) + AReason;
end;

{ ------------------------------------------------------------------ }
{ a session: one TCP connection, at most one allocation              }
{ ------------------------------------------------------------------ }

type
  TTurnSession = class;

  TUdpReader = class(TThread)
  private
    FSession: TTurnSession;
  protected
    procedure Execute; override;
  public
    constructor Create(ASession: TTurnSession);
  end;

  TTurnSession = class
  private
    FSock: TTCPBlockSocket;
    FSendLock: TCriticalSection;
    FStateLock: TCriticalSection;
    FUdp: TUDPBlockSocket;
    FReader: TUdpReader;
    FAllocated: boolean;
    FExpires: QWord;           { GetTickCount64 }
    FNonce: string;
    FKey: RawByteString;       { of the last authenticated request }
    FRelayIp: string;
    FRelayPort: word;
    FPerms: TStringList;       { ip=expiry tick }
    FChanPeer: array[CHANNEL_MIN..CHANNEL_MAX] of string;  { 'ip:port' }
    FChanExpires: array[CHANNEL_MIN..CHANNEL_MAX] of QWord;
    FDead: boolean;
    procedure SendRaw(const AData: RawByteString);
    procedure Reply(var W: TStunWriter; AWithKey: boolean);
    procedure ReplyError(const AMsg: TStunMsg; ACode: integer; const AReason: string;
      AWithRealm: boolean);
    function Authenticate(const AMsg: TStunMsg): boolean;
    function PermissionOk(const AIp: string): boolean;
    procedure AddPermission(const AIp: string);
    function ChannelOf(const APeer: string): integer;
    procedure SendToPeer(const AIp: string; APort: word; const AData: RawByteString);
    procedure HandleStun(const ARaw: RawByteString);
    procedure HandleChannelData(AChannel: word; const AData: RawByteString);
    procedure DoAllocate(const AMsg: TStunMsg);
    procedure DoRefresh(const AMsg: TStunMsg);
    procedure DoCreatePermission(const AMsg: TStunMsg);
    procedure DoChannelBind(const AMsg: TStunMsg);
    procedure DoSend(const AMsg: TStunMsg);
    procedure FreeAllocation;
  public
    constructor Create(ASock: TTCPBlockSocket);
    destructor Destroy; override;
    procedure Run;
    { From the reader thread: a datagram from a peer. }
    procedure FromPeer(const AIp: string; APort: word; const AData: RawByteString);
  end;

constructor TUdpReader.Create(ASession: TTurnSession);
begin
  FSession := ASession;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TUdpReader.Execute;
var
  Buf: array[0..RELAY_MAX_DATAGRAM - 1] of byte;
  N: integer;
  Data: RawByteString;
  Udp: TUDPBlockSocket;
begin
  Udp := FSession.FUdp;
  while not Terminated do begin
    try
      if not Udp.CanRead(RELAY_POLL_MS) then begin
        Continue;
      end;
      N := Udp.RecvBufferFrom(@Buf[0], SizeOf(Buf));
      if (N <= 0) or (Udp.LastError <> 0) then begin
        Continue;
      end;
      SetLength(Data, N);
      Move(Buf[0], Data[1], N);
      FSession.FromPeer(Udp.GetRemoteSinIP, Udp.GetRemoteSinPort, Data);
    except
      { a bad datagram is no reason to stop relaying }
    end;
  end;
end;

constructor TTurnSession.Create(ASock: TTCPBlockSocket);
begin
  inherited Create;
  FSock := ASock;
  FSendLock := TCriticalSection.Create;
  FStateLock := TCriticalSection.Create;
  FPerms := TStringList.Create;
  FNonce := NewToken;
end;

destructor TTurnSession.Destroy;
begin
  FreeAllocation;
  FPerms.Free;
  FStateLock.Free;
  FSendLock.Free;
  inherited Destroy;
end;

procedure TTurnSession.FreeAllocation;
begin
  if FReader <> nil then begin
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  if FUdp <> nil then begin
    FUdp.CloseSocket;
    FreeAndNil(FUdp);
  end;
  FStateLock.Enter;
  try
    FAllocated := False;
    FPerms.Clear;
    FillChar(FChanExpires, SizeOf(FChanExpires), 0);
  finally
    FStateLock.Leave;
  end;
end;

procedure TTurnSession.SendRaw(const AData: RawByteString);
begin
  FSendLock.Enter;
  try
    if FDead then begin
      Exit;
    end;
    FSock.SendString(AData);
    if FSock.LastError <> 0 then begin
      FDead := True;
    end;
  finally
    FSendLock.Leave;
  end;
end;

procedure TTurnSession.Reply(var W: TStunWriter; AWithKey: boolean);
begin
  if AWithKey then begin
    SendRaw(WFinish(W, FKey));
  end else begin
    SendRaw(WFinish(W, ''));
  end;
end;

procedure TTurnSession.ReplyError(const AMsg: TStunMsg; ACode: integer;
  const AReason: string; AWithRealm: boolean);
var
  W: TStunWriter;
  Unknown: RawByteString;
begin
  WInit(W, (AMsg.MsgType and not $0110) or C_ERROR, AMsg.Tid);
  WAdd(W, A_ERROR_CODE, ErrorCodeValue(ACode, AReason));
  if ACode = 420 then begin
    Unknown := UnknownAttrs(AMsg);
    WAdd(W, A_UNKNOWN_ATTRIBUTES, Unknown);
  end;
  if AWithRealm then begin
    WAdd(W, A_REALM, RELAY_REALM);
    WAdd(W, A_NONCE, FNonce);
  end;
  { 401 and 438 go without integrity: the client has no valid key yet. }
  Reply(W, (not AWithRealm) and (FKey <> ''));
end;

function TTurnSession.Authenticate(const AMsg: TStunMsg): boolean;
var
  User, Nonce: RawByteString;
  Key: RawByteString;
begin
  Result := False;
  if (AttrIndex(AMsg, A_MESSAGE_INTEGRITY) < 0)
     or (not FindAttr(AMsg, A_USERNAME, User)) then begin
    ReplyError(AMsg, 401, 'Unauthorized', True);
    Exit;
  end;
  if (not FindAttr(AMsg, A_NONCE, Nonce)) or (Nonce <> FNonce) then begin
    ReplyError(AMsg, 438, 'Stale Nonce', True);
    Exit;
  end;
  if not UserValid(User) then begin
    ReplyError(AMsg, 401, 'Unauthorized', True);
    Exit;
  end;
  Key := LongTermKey(User);
  if not IntegrityOk(AMsg, Key) then begin
    ReplyError(AMsg, 401, 'Unauthorized', True);
    Exit;
  end;
  FKey := Key;
  Result := True;
end;

function TTurnSession.PermissionOk(const AIp: string): boolean;
var
  I: integer;
begin
  I := FPerms.IndexOfName(AIp);
  Result := (I >= 0) and (StrToQWordDef(FPerms.ValueFromIndex[I], 0) > GetTickCount64);
end;

procedure TTurnSession.AddPermission(const AIp: string);
begin
  FPerms.Values[AIp] := IntToStr(GetTickCount64 + QWord(RELAY_PERMISSION_SEC) * 1000);
end;

function TTurnSession.ChannelOf(const APeer: string): integer;
var
  C: integer;
  T: QWord;
begin
  T := GetTickCount64;
  for C := CHANNEL_MIN to CHANNEL_MAX do begin
    if (FChanExpires[C] > T) and (FChanPeer[C] = APeer) then begin
      Exit(C);
    end;
  end;
  Result := -1;
end;

procedure TTurnSession.SendToPeer(const AIp: string; APort: word; const AData: RawByteString);
var
  Sin: TVarSin;
begin
  if (FUdp = nil) or (AData = '') then begin
    Exit;
  end;
  { Not FUdp.SendBufferTo: that goes through the object's remote address,
    which the reader thread rewrites on every receive. }
  if synsock.SetVarSin(Sin, AIp, IntToStr(APort), AF_INET, IPPROTO_UDP, SOCK_DGRAM, True) <> 0 then begin
    Exit;
  end;
  synsock.SendTo(FUdp.Socket, Pointer(AData), Length(AData), 0, Sin);
end;

procedure TTurnSession.FromPeer(const AIp: string; APort: word; const AData: RawByteString);
var
  C: integer;
  Frame: RawByteString;
  W: TStunWriter;
  Tid: RawByteString;
  I: integer;
begin
  FStateLock.Enter;
  try
    if (not FAllocated) or (not PermissionOk(AIp)) then begin
      Exit;
    end;
    C := ChannelOf(AIp + ':' + IntToStr(APort));
  finally
    FStateLock.Leave;
  end;
  if C >= 0 then begin
    { Over TCP ChannelData is padded to a multiple of four. }
    Frame := B16(C) + B16(Length(AData)) + AData
      + StringOfChar(#0, Pad4(Length(AData)) - Length(AData));
    SendRaw(Frame);
  end else begin
    SetLength(Tid, 12);
    for I := 1 to 12 do begin
      Tid[I] := AnsiChar(Random(256));
    end;
    WInit(W, M_DATA or C_INDICATION, Tid);
    WAdd(W, A_XOR_PEER_ADDRESS, XorAddress(AIp, APort));
    WAdd(W, A_DATA, AData);
    SendRaw(WFinish(W, ''));
  end;
end;

procedure TTurnSession.DoAllocate(const AMsg: TStunMsg);
var
  V: RawByteString;
  Lifetime: cardinal;
  Port, First, Span, K: integer;
  W: TStunWriter;
  Sin: TVarSin;
begin
  if FAllocated then begin
    ReplyError(AMsg, 437, 'Allocation Mismatch', False);
    Exit;
  end;
  if not FindAttr(AMsg, A_REQUESTED_TRANSPORT, V) or (Length(V) < 1) then begin
    ReplyError(AMsg, 400, 'Bad Request', False);
    Exit;
  end;
  if byte(V[1]) <> UDP_PROTOCOL then begin
    ReplyError(AMsg, 442, 'Unsupported Transport Protocol', False);
    Exit;
  end;
  if FindAttr(AMsg, A_REQUESTED_ADDRESS_FAMILY, V) and (Length(V) >= 1)
     and (byte(V[1]) <> FAMILY_IPV4) then begin
    ReplyError(AMsg, 440, 'Address Family not Supported', False);
    Exit;
  end;
  Lifetime := RELAY_DEFAULT_LIFETIME_SEC;
  if FindAttr(AMsg, A_LIFETIME, V) and (Length(V) = 4) then begin
    Lifetime := U32(V, 1);
  end;
  if Lifetime < RELAY_DEFAULT_LIFETIME_SEC then begin
    Lifetime := RELAY_DEFAULT_LIFETIME_SEC;
  end;
  if Lifetime > RELAY_MAX_LIFETIME_SEC then begin
    Lifetime := RELAY_MAX_LIFETIME_SEC;
  end;

  FUdp := TUDPBlockSocket.Create;
  { IPv4 explicitly: with the family left "any", Synapse's Bind to
    0.0.0.0:0 silently does nothing (blcksock, TBlockSocket.Bind), and the
    socket stays unbound until its first send. }
  FUdp.Family := SF_IP4;
  FUdp.CreateSocket;
  if GConfig.PortMin = 0 then begin
    FUdp.Bind('0.0.0.0', '0');
  end else begin
    { From a random place in the range, so concurrent allocations do not
      all fight over the first port. }
    Span := GConfig.PortMax - GConfig.PortMin + 1;
    First := Random(Span);
    for K := 0 to Span - 1 do begin
      Port := GConfig.PortMin + (First + K) mod Span;
      FUdp.Bind('0.0.0.0', IntToStr(Port));
      if FUdp.LastError = 0 then begin
        Break;
      end;
    end;
  end;
  if FUdp.LastError <> 0 then begin
    FreeAndNil(FUdp);
    ReplyError(AMsg, 508, 'Insufficient Capacity', False);
    Exit;
  end;
  { From the socket itself: after Bind(port 0) Synapse's own copy of the
    local address still says 0. }
  FillChar(Sin, SizeOf(Sin), 0);
  synsock.GetSockName(FUdp.Socket, Sin);
  FRelayPort := synsock.GetSinPort(Sin);
  FRelayIp := GConfig.Address;
  if FRelayIp = '' then begin
    FRelayIp := FSock.GetLocalSinIP;
  end;

  FStateLock.Enter;
  try
    FAllocated := True;
    FExpires := GetTickCount64 + QWord(Lifetime) * 1000;
  finally
    FStateLock.Leave;
  end;
  FReader := TUdpReader.Create(Self);

  WInit(W, M_ALLOCATE or C_SUCCESS, AMsg.Tid);
  WAdd(W, A_XOR_RELAYED_ADDRESS, XorAddress(FRelayIp, FRelayPort));
  WAdd(W, A_LIFETIME, B32(Lifetime));
  WAdd(W, A_XOR_MAPPED_ADDRESS, XorAddress(FSock.GetRemoteSinIP, FSock.GetRemoteSinPort));
  Reply(W, True);
end;

procedure TTurnSession.DoRefresh(const AMsg: TStunMsg);
var
  V: RawByteString;
  Lifetime: cardinal;
  W: TStunWriter;
begin
  if not FAllocated then begin
    ReplyError(AMsg, 437, 'Allocation Mismatch', False);
    Exit;
  end;
  Lifetime := RELAY_DEFAULT_LIFETIME_SEC;
  if FindAttr(AMsg, A_LIFETIME, V) and (Length(V) = 4) then begin
    Lifetime := U32(V, 1);
  end;
  if Lifetime > RELAY_MAX_LIFETIME_SEC then begin
    Lifetime := RELAY_MAX_LIFETIME_SEC;
  end;
  if Lifetime = 0 then begin
    FreeAllocation;
  end else begin
    FStateLock.Enter;
    try
      FExpires := GetTickCount64 + QWord(Lifetime) * 1000;
    finally
      FStateLock.Leave;
    end;
  end;
  WInit(W, M_REFRESH or C_SUCCESS, AMsg.Tid);
  WAdd(W, A_LIFETIME, B32(Lifetime));
  Reply(W, True);
end;

procedure TTurnSession.DoCreatePermission(const AMsg: TStunMsg);
var
  I: integer;
  Ip: string;
  Port: word;
  Peers: TStringList;
  W: TStunWriter;
begin
  if not FAllocated then begin
    ReplyError(AMsg, 437, 'Allocation Mismatch', False);
    Exit;
  end;
  Peers := TStringList.Create;
  try
    for I := 0 to High(AMsg.Attrs) do begin
      if AMsg.Attrs[I].AType = A_XOR_PEER_ADDRESS then begin
        if not ParseXorAddress(AMsg.Attrs[I].Value, Ip, Port) then begin
          ReplyError(AMsg, 443, 'Peer Address Family Mismatch', False);
          Exit;
        end;
        Peers.Add(Ip);
      end;
    end;
    if Peers.Count = 0 then begin
      ReplyError(AMsg, 400, 'Bad Request', False);
      Exit;
    end;
    FStateLock.Enter;
    try
      for I := 0 to Peers.Count - 1 do begin
        AddPermission(Peers[I]);
      end;
    finally
      FStateLock.Leave;
    end;
  finally
    Peers.Free;
  end;
  WInit(W, M_CREATE_PERMISSION or C_SUCCESS, AMsg.Tid);
  Reply(W, True);
end;

procedure TTurnSession.DoChannelBind(const AMsg: TStunMsg);
var
  V, PeerV: RawByteString;
  C: integer;
  Ip, Peer: string;
  Port: word;
  W: TStunWriter;
  Other: integer;
  Ok: boolean;
begin
  if not FAllocated then begin
    ReplyError(AMsg, 437, 'Allocation Mismatch', False);
    Exit;
  end;
  if (not FindAttr(AMsg, A_CHANNEL_NUMBER, V)) or (Length(V) < 2)
     or (not FindAttr(AMsg, A_XOR_PEER_ADDRESS, PeerV)) then begin
    ReplyError(AMsg, 400, 'Bad Request', False);
    Exit;
  end;
  C := U16(V, 1);
  if (C < CHANNEL_MIN) or (C > CHANNEL_MAX) then begin
    ReplyError(AMsg, 400, 'Bad Request', False);
    Exit;
  end;
  if not ParseXorAddress(PeerV, Ip, Port) then begin
    ReplyError(AMsg, 443, 'Peer Address Family Mismatch', False);
    Exit;
  end;
  Peer := Ip + ':' + IntToStr(Port);
  FStateLock.Enter;
  try
    { One channel — one peer, and one peer — one channel. }
    Other := ChannelOf(Peer);
    Ok := ((Other < 0) or (Other = C))
      and ((FChanExpires[C] <= GetTickCount64) or (FChanPeer[C] = Peer));
    if Ok then begin
      FChanPeer[C] := Peer;
      FChanExpires[C] := GetTickCount64 + QWord(RELAY_CHANNEL_SEC) * 1000;
      AddPermission(Ip);
    end;
  finally
    FStateLock.Leave;
  end;
  if not Ok then begin
    ReplyError(AMsg, 400, 'Bad Request', False);
    Exit;
  end;
  WInit(W, M_CHANNEL_BIND or C_SUCCESS, AMsg.Tid);
  Reply(W, True);
end;

procedure TTurnSession.DoSend(const AMsg: TStunMsg);
var
  PeerV, Data: RawByteString;
  Ip: string;
  Port: word;
  Allowed: boolean;
begin
  if (not FAllocated) or (not FindAttr(AMsg, A_XOR_PEER_ADDRESS, PeerV))
     or (not FindAttr(AMsg, A_DATA, Data)) or (not ParseXorAddress(PeerV, Ip, Port)) then begin
    Exit;
  end;
  FStateLock.Enter;
  try
    Allowed := PermissionOk(Ip);
  finally
    FStateLock.Leave;
  end;
  if Allowed then begin
    SendToPeer(Ip, Port, Data);
  end;
end;

procedure TTurnSession.HandleStun(const ARaw: RawByteString);
var
  Msg: TStunMsg;
  Method, Cls: word;
  W: TStunWriter;
begin
  if not ParseStun(ARaw, Msg) then begin
    Exit;
  end;
  Cls := Msg.MsgType and $0110;
  Method := (Msg.MsgType and $000F) or ((Msg.MsgType and $00E0) shr 1)
    or ((Msg.MsgType and $3E00) shr 2);
  if Cls = C_INDICATION then begin
    if Method = M_SEND then begin
      DoSend(Msg);
    end;
    Exit;
  end;
  if Cls <> C_REQUEST then begin
    Exit;
  end;
  if Method = M_BINDING then begin
    WInit(W, M_BINDING or C_SUCCESS, Msg.Tid);
    WAdd(W, A_XOR_MAPPED_ADDRESS, XorAddress(FSock.GetRemoteSinIP, FSock.GetRemoteSinPort));
    Reply(W, False);
    Exit;
  end;
  if (Method <> M_ALLOCATE) and (Method <> M_REFRESH)
     and (Method <> M_CREATE_PERMISSION) and (Method <> M_CHANNEL_BIND) then begin
    ReplyError(Msg, 400, 'Bad Request', False);
    Exit;
  end;
  if UnknownAttrs(Msg) <> '' then begin
    ReplyError(Msg, 420, 'Unknown Attribute', False);
    Exit;
  end;
  if not Authenticate(Msg) then begin
    Exit;
  end;
  case Method of
    M_ALLOCATE: DoAllocate(Msg);
    M_REFRESH: DoRefresh(Msg);
    M_CREATE_PERMISSION: DoCreatePermission(Msg);
    M_CHANNEL_BIND: DoChannelBind(Msg);
  end;
end;

procedure TTurnSession.HandleChannelData(AChannel: word; const AData: RawByteString);
var
  Peer: string;
  P: integer;
  Port: integer;
begin
  FStateLock.Enter;
  try
    if (not FAllocated) or (FChanExpires[AChannel] <= GetTickCount64) then begin
      Exit;
    end;
    Peer := FChanPeer[AChannel];
  finally
    FStateLock.Leave;
  end;
  P := Pos(':', Peer);
  if (P > 0) and TryStrToInt(Copy(Peer, P + 1, MaxInt), Port) then begin
    SendToPeer(Copy(Peer, 1, P - 1), Port, AData);
  end;
end;

procedure TTurnSession.Run;
var
  Head, Rest: RawByteString;
  Len, Want: integer;
  Started: QWord;
  Expired: boolean;

  function ReadExact(ACount: integer; out AData: RawByteString): boolean;
  begin
    AData := '';
    if ACount = 0 then begin
      Exit(True);
    end;
    AData := FSock.RecvBufferStr(ACount, RELAY_READ_TIMEOUT_MS);
    Result := (FSock.LastError = 0) and (Length(AData) = ACount);
  end;

begin
  Started := GetTickCount64;
  while not FDead do begin
    { CanReadEx: Synapse may already hold the bytes in its own buffer. }
    if not FSock.CanReadEx(RELAY_POLL_MS) then begin
      FStateLock.Enter;
      try
        Expired := (FAllocated and (FExpires <= GetTickCount64))
          or ((not FAllocated) and (GetTickCount64 - Started > RELAY_IDLE_MS));
      finally
        FStateLock.Leave;
      end;
      if Expired then begin
        Exit;
      end;
      Continue;
    end;
    if not ReadExact(4, Head) then begin
      Exit;
    end;
    Len := U16(Head, 3);
    if (byte(Head[1]) and $C0) = 0 then begin
      { STUN: a 20-byte header, the attributes are Len bytes. }
      if (Len and 3) <> 0 then begin
        Exit;
      end;
      if not ReadExact(STUN_HEADER - 4 + Len, Rest) then begin
        Exit;
      end;
      if U32(Head + Rest, 5) <> STUN_MAGIC then begin
        Exit;  { not STUN after all }
      end;
      HandleStun(Head + Rest);
    end else if (byte(Head[1]) >= $40) and (byte(Head[1]) <= $4F) then begin
      { ChannelData before an allocation is not a TURN client — plain
        http:// on this port starts with "G" (0x47), say. Close at once. }
      if not FAllocated then begin
        Exit;
      end;
      Want := Pad4(Len);
      if not ReadExact(Want, Rest) then begin
        Exit;
      end;
      HandleChannelData(U16(Head, 1), Copy(Rest, 1, Len));
    end else begin
      Exit;
    end;
    if not FAllocated then begin
      { A client that has not allocated yet keeps the idle limit. }
      Continue;
    end;
    Started := GetTickCount64;
  end;
end;

{ ------------------------------------------------------------------ }
{ entry points                                                       }
{ ------------------------------------------------------------------ }

procedure RelayConfigure(const AConfig: TRelayConfig);
begin
  GLock.Enter;
  try
    GConfig := AConfig;
    if (GConfig.PortMin = 0) or (GConfig.PortMax < GConfig.PortMin) then begin
      GConfig.PortMin := 0;
      GConfig.PortMax := 0;
    end;
    if GSecret = '' then begin
      GSecret := NewToken + NewToken;
    end;
  finally
    GLock.Leave;
  end;
end;

function RelayEnabled: boolean;
begin
  Result := GConfig.Enabled and (GSecret <> '');
end;

function RelayCredentials(out AUser, APass: string; out ATtl: integer): boolean;
begin
  Result := RelayEnabled;
  AUser := '';
  APass := '';
  ATtl := 0;
  if not Result then begin
    Exit;
  end;
  ATtl := RELAY_CREDENTIAL_SEC;
  AUser := IntToStr(DateTimeToUnix(Now, False) + ATtl) + ':' + RELAY_REALM;
  APass := PasswordFor(AUser);
end;

function IsTurnFirstByte(AByte: byte): boolean;
begin
  { STUN: the two top bits are zero; ChannelData: 0x40..0x4F. TLS starts
    with 0x16 — that is in the STUN range too, so TLS is ruled out by the
    caller first. }
  Result := (AByte <= $4F) and (AByte <> $16);
end;

procedure ServeTurn(ASock: TTCPBlockSocket);
var
  S: TTurnSession;
begin
  S := TTurnSession.Create(ASock);
  try
    S.Run;
  finally
    S.Free;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  Randomize;

finalization
  FreeAndNil(GLock);

end.
