unit wsframe;

{$mode objfpc}{$H+}

{ RFC 6455 — the handshake reply and the frame format, and nothing
  else. No sockets, no threads, no project types: this unit is a pure
  byte-level codec, so it can be exercised on its own (feed it a
  captured frame, compare bytes) without a server or a browser in the
  picture. The socket side lives in localserver.pas.

  Everything here is RawByteString rather than utf8string ON PURPOSE.
  Frame headers contain arbitrary bytes >= $80 (the length and mask
  fields), and a string type with a declared code page invites FPC to
  "helpfully" transcode on assignment/concatenation, which would
  corrupt the wire format in a way that only shows up on payloads over
  125 bytes. RawByteString is the one AnsiString flavour that is
  defined to carry bytes through untouched. The caller converts the
  payload of a TEXT frame to utf8string at its own boundary, where the
  bytes really are UTF-8 by protocol.

  The four things this project has to get exactly right, because the
  browser's client is strict and fails silently-ish when it doesn't:

  1. Payload length in three encodings (7 bit / 7+16 / 7+64). Skipping
     the 64-bit form works fine until a message crosses 64 KB and then
     breaks — exactly the size a history page of fifty parsed messages
     is going to land on.
  2. Client -> server frames are ALWAYS masked and the browser gives
     no way to turn that off; server -> client frames must NOT be
     masked. Both directions are enforced here.
  3. Fragmentation: opcode 0 (continuation). The browser will use it
     whenever it feels like it, so it cannot be treated as exotic.
     This unit reports frames; assembling a message out of them is the
     caller's job (it has to stay able to answer a ping that arrives
     INTERLEAVED inside a fragmented message, which is legal).
  4. Ping/pong/close. Ignore them and the connection dies at some
     unpredictable later moment, which is miserable to debug. }

interface

uses
  Classes, SysUtils;

type
  { Only the opcodes RFC 6455 actually defines. The gap between $2 and
    $8 is the reserved range; values in it are a protocol error, which
    is why decoding goes through an explicit case rather than casting
    the nibble straight to this type. }
  TWsOpcode = (
    wsoContinuation = $0,
    wsoText         = $1,
    wsoBinary       = $2,
    wsoClose        = $8,
    wsoPing         = $9,
    wsoPong         = $A
  );

  { "Read exactly ALen bytes, or fail." Blocking-socket shaped on
    purpose — a frame arrives in however many TCP segments it likes,
    and every field below has a known length before it is read, so the
    codec never needs to buffer or look ahead. }
  TWsReadExact = function(ABuf: PByte; ALen: integer): boolean of object;

  TWsResult = (
    wsrOk,            { a whole frame was read }
    wsrEof,           { the peer went away mid-frame, or timed out }
    wsrProtocol,      { the peer broke the framing rules }
    wsrTooLarge       { the peer announced more than we agreed to hold }
  );

{ The value for the Sec-WebSocket-Accept reply header: SHA-1 of the
  client's key concatenated with the protocol's fixed GUID, base64'd.
  Pure ASCII in and out. }
function WsAcceptKey(const AClientKey: string): string;

{ A complete, unmasked, unfragmented server -> client frame. }
function WsEncodeFrame(AOpcode: TWsOpcode; const APayload: RawByteString): RawByteString;

{ One frame, unmasked in place. AMaxPayload is the point at which a
  peer is told it has gone too far instead of being allowed to make
  this process allocate whatever it asked for. }
function WsReadFrame(AReader: TWsReadExact; AMaxPayload: Int64;
  out AOpcode: TWsOpcode; out AFin: boolean;
  out APayload: RawByteString): TWsResult;

{ The two-byte big-endian status code a close frame carries (1000 =
  normal). Its payload is optional, so this builds the minimal one. }
function WsCloseCode(ACode: word): RawByteString;

implementation

uses
  sha1, base64;

const
  { RFC 6455, section 1.3 — a fixed string, not a secret and not a
    parameter. }
  WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function WsAcceptKey(const AClientKey: string): string;
var
  D: TSHA1Digest;
  Raw: string;
  I: integer;
begin
  D := SHA1String(AClientKey + WS_MAGIC_GUID);
  { The digest goes into base64 as RAW BYTES, not as the hex string
    SHA1Print would give — a hex digest here produces a handshake the
    browser rejects with a bland "connection failed", one of the
    easier ways to lose an afternoon. }
  SetLength(Raw, Length(D));
  for I := 0 to High(D) do begin
    Raw[I + 1] := Chr(D[I]);
  end;
  Result := EncodeStringBase64(Raw);
end;

function WsEncodeFrame(AOpcode: TWsOpcode; const APayload: RawByteString): RawByteString;
var
  L: Int64;
  HdrLen, I: integer;
begin
  L := Length(APayload);
  if L < 126 then begin
    HdrLen := 2;
  end else if L <= $FFFF then begin
    HdrLen := 4;
  end else begin
    HdrLen := 10;
  end;
  SetLength(Result, HdrLen + L);

  { FIN set, RSV1..3 clear (no extensions are negotiated in the
    handshake, so setting one would be a protocol error). }
  Result[1] := Chr($80 or Ord(AOpcode));

  if L < 126 then begin
    Result[2] := Chr(Byte(L));
  end else if L <= $FFFF then begin
    Result[2] := Chr(126);
    Result[3] := Chr(Byte((L shr 8) and $FF));
    Result[4] := Chr(Byte(L and $FF));
  end else begin
    Result[2] := Chr(127);
    for I := 0 to 7 do begin
      Result[3 + I] := Chr(Byte((L shr (56 - 8 * I)) and $FF));
    end;
  end;

  if L > 0 then begin
    Move(APayload[1], Result[HdrLen + 1], L);
  end;
end;

function WsReadFrame(AReader: TWsReadExact; AMaxPayload: Int64;
  out AOpcode: TWsOpcode; out AFin: boolean;
  out APayload: RawByteString): TWsResult;
var
  H: array[0..7] of byte;
  Mask: array[0..3] of byte;
  Len: Int64;
  I: Int64;
  B0, B1: byte;
begin
  AOpcode := wsoClose;
  AFin := True;
  APayload := '';

  if not AReader(@H[0], 2) then begin
    Exit(wsrEof);
  end;
  B0 := H[0];
  B1 := H[1];

  AFin := (B0 and $80) <> 0;
  if (B0 and $70) <> 0 then begin
    { RSV bits set without a negotiated extension. }
    Exit(wsrProtocol);
  end;

  case B0 and $0F of
    $0: AOpcode := wsoContinuation;
    $1: AOpcode := wsoText;
    $2: AOpcode := wsoBinary;
    $8: AOpcode := wsoClose;
    $9: AOpcode := wsoPing;
    $A: AOpcode := wsoPong;
  else
    Exit(wsrProtocol);
  end;

  Len := B1 and $7F;
  if Len = 126 then begin
    if not AReader(@H[0], 2) then begin
      Exit(wsrEof);
    end;
    Len := (Int64(H[0]) shl 8) or H[1];
  end else if Len = 127 then begin
    if not AReader(@H[0], 8) then begin
      Exit(wsrEof);
    end;
    { The most significant bit of a 64-bit length must be 0. }
    if (H[0] and $80) <> 0 then begin
      Exit(wsrProtocol);
    end;
    Len := 0;
    for I := 0 to 7 do begin
      Len := (Len shl 8) or H[I];
    end;
  end;

  { A control frame may not be fragmented and may not exceed 125
    bytes — both are flat rules, not conventions. }
  if (Ord(AOpcode) >= $8) and ((not AFin) or (Len > 125)) then begin
    Exit(wsrProtocol);
  end;

  { Unmasked client frames are a protocol error, and letting one
    through would silently produce garbage payloads. }
  if (B1 and $80) = 0 then begin
    Exit(wsrProtocol);
  end;

  if Len > AMaxPayload then begin
    Exit(wsrTooLarge);
  end;

  if not AReader(@Mask[0], 4) then begin
    Exit(wsrEof);
  end;

  SetLength(APayload, Len);
  if Len > 0 then begin
    if not AReader(PByte(@APayload[1]), integer(Len)) then begin
      Exit(wsrEof);
    end;
    { Unmask in place. The key repeats every four bytes and the index
      is the offset within THIS frame's payload, which is why
      fragmented messages must be unmasked frame by frame rather than
      after being reassembled. }
    for I := 0 to Len - 1 do begin
      APayload[I + 1] := Chr(Byte(Ord(APayload[I + 1]) xor Mask[I and 3]));
    end;
  end;

  Result := wsrOk;
end;

function WsCloseCode(ACode: word): RawByteString;
begin
  SetLength(Result, 2);
  Result[1] := Chr(Byte((ACode shr 8) and $FF));
  Result[2] := Chr(Byte(ACode and $FF));
end;

end.
