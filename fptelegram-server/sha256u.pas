unit sha256u;

{$mode objfpc}{$H+}
{$Q-}{$R-}

{ SHA-256, HMAC-SHA256 и PBKDF2-HMAC-SHA256 (FIPS 180-4, RFC 2104,
  RFC 8018) на чистом Pascal.

  Своё, а не из библиотек: в FPC 3.2.2 SHA-256 нет (hash/hmac.pp — только
  MD5 и SHA1), а OpenSSL есть только у сервера — окну (fptelegram-gui)
  этот модуль нужен для отпечатка сертификата сервера, без лишних DLL.
  Общий у двух программ, как constants и secureconfig.

  Проверено эталонными векторами FIPS 180-4, RFC 4231 и RFC 7914
  (PBKDF2-HMAC-SHA256) — см. журнал 2026-10-07. }

interface

uses
  SysUtils;

type
  TSha256Digest = array[0..31] of byte;

function Sha256(const AData: RawByteString): TSha256Digest;
function HmacSha256(const AKey, AData: RawByteString): TSha256Digest;
function Pbkdf2Sha256(const APassword, ASalt: RawByteString; AIterations: integer;
  ALength: integer): RawByteString;

{ Дайджест строкой байтов. }
function DigestBytes(const ADigest: TSha256Digest): RawByteString;
{ 'AB:CD:…' — как отпечатки сертификатов показывают браузеры. }
function DigestColonHex(const ADigest: TSha256Digest): string;
{ Сравнение за постоянное время (секреты, подписи). }
function SameBytes(const A, B: RawByteString): boolean;

implementation

const
  K: array[0..63] of longword = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

type
  TState = array[0..7] of longword;

function Ror(X: longword; N: integer): longword; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Compress(var H: TState; const ABlock: PByte);
var
  W: array[0..63] of longword;
  A, B, C, D, E, F, G, HH, T1, T2, S0, S1: longword;
  I: integer;
begin
  for I := 0 to 15 do begin
    W[I] := (longword(ABlock[I * 4]) shl 24) or (longword(ABlock[I * 4 + 1]) shl 16)
      or (longword(ABlock[I * 4 + 2]) shl 8) or longword(ABlock[I * 4 + 3]);
  end;
  for I := 16 to 63 do begin
    S0 := Ror(W[I - 15], 7) xor Ror(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Ror(W[I - 2], 17) xor Ror(W[I - 2], 19) xor (W[I - 2] shr 10);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;
  A := H[0]; B := H[1]; C := H[2]; D := H[3];
  E := H[4]; F := H[5]; G := H[6]; HH := H[7];
  for I := 0 to 63 do begin
    S1 := Ror(E, 6) xor Ror(E, 11) xor Ror(E, 25);
    T1 := HH + S1 + ((E and F) xor ((not E) and G)) + K[I] + W[I];
    S0 := Ror(A, 2) xor Ror(A, 13) xor Ror(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    HH := G; G := F; F := E; E := D + T1;
    D := C; C := B; B := A; A := T1 + T2;
  end;
  Inc(H[0], A); Inc(H[1], B); Inc(H[2], C); Inc(H[3], D);
  Inc(H[4], E); Inc(H[5], F); Inc(H[6], G); Inc(H[7], HH);
end;

function Sha256(const AData: RawByteString): TSha256Digest;
var
  H: TState;
  Buf: RawByteString;
  Len, BitLen: QWord;
  I, Pad: integer;
begin
  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372; H[3] := $a54ff53a;
  H[4] := $510e527f; H[5] := $9b05688c; H[6] := $1f83d9ab; H[7] := $5be0cd19;
  Len := Length(AData);
  BitLen := Len * 8;
  { Дополнение: 0x80, нули до 56 по модулю 64, длина в битах (big-endian). }
  Pad := 64 - integer((Len + 9) mod 64);
  if Pad = 64 then begin
    Pad := 0;
  end;
  SetLength(Buf, Len + 9 + Pad);
  if Len > 0 then begin
    Move(AData[1], Buf[1], Len);
  end;
  Buf[Len + 1] := #$80;
  for I := Len + 2 to Len + 1 + Pad do begin
    Buf[I] := #0;
  end;
  for I := 0 to 7 do begin
    Buf[Length(Buf) - I] := AnsiChar((BitLen shr (8 * I)) and $FF);
  end;
  I := 0;
  while I < Length(Buf) do begin
    Compress(H, @Buf[I + 1]);
    Inc(I, 64);
  end;
  for I := 0 to 7 do begin
    Result[I * 4] := (H[I] shr 24) and $FF;
    Result[I * 4 + 1] := (H[I] shr 16) and $FF;
    Result[I * 4 + 2] := (H[I] shr 8) and $FF;
    Result[I * 4 + 3] := H[I] and $FF;
  end;
end;

function DigestBytes(const ADigest: TSha256Digest): RawByteString;
begin
  SetLength(Result, 32);
  Move(ADigest[0], Result[1], 32);
end;

function HmacSha256(const AKey, AData: RawByteString): TSha256Digest;
var
  Key, IPad, OPad: RawByteString;
  I: integer;
begin
  Key := AKey;
  if Length(Key) > 64 then begin
    Key := DigestBytes(Sha256(Key));
  end;
  SetLength(IPad, 64);
  SetLength(OPad, 64);
  for I := 1 to 64 do begin
    if I <= Length(Key) then begin
      IPad[I] := AnsiChar(byte(Key[I]) xor $36);
      OPad[I] := AnsiChar(byte(Key[I]) xor $5C);
    end else begin
      IPad[I] := #$36;
      OPad[I] := #$5C;
    end;
  end;
  Result := Sha256(OPad + DigestBytes(Sha256(IPad + AData)));
end;

function Pbkdf2Sha256(const APassword, ASalt: RawByteString; AIterations: integer;
  ALength: integer): RawByteString;
var
  Block, I, J: integer;
  U, T: TSha256Digest;
  Idx: RawByteString;
begin
  Result := '';
  Block := 1;
  while Length(Result) < ALength do begin
    Idx := AnsiChar((Block shr 24) and $FF) + AnsiChar((Block shr 16) and $FF)
      + AnsiChar((Block shr 8) and $FF) + AnsiChar(Block and $FF);
    U := HmacSha256(APassword, ASalt + Idx);
    T := U;
    for I := 2 to AIterations do begin
      U := HmacSha256(APassword, DigestBytes(U));
      for J := 0 to 31 do begin
        T[J] := T[J] xor U[J];
      end;
    end;
    Result := Result + DigestBytes(T);
    Inc(Block);
  end;
  SetLength(Result, ALength);
end;

function DigestColonHex(const ADigest: TSha256Digest): string;
var
  I: integer;
begin
  Result := '';
  for I := 0 to 31 do begin
    if I > 0 then begin
      Result := Result + ':';
    end;
    Result := Result + IntToHex(ADigest[I], 2);
  end;
end;

function SameBytes(const A, B: RawByteString): boolean;
var
  I: integer;
  D: byte;
begin
  if Length(A) <> Length(B) then begin
    Result := False;
    Exit;
  end;
  D := 0;
  for I := 1 to Length(A) do begin
    D := D or (byte(A[I]) xor byte(B[I]));
  end;
  Result := D = 0;
end;

end.
