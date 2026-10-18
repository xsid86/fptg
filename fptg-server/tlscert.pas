unit tlscert;

{$mode objfpc}{$H+}

{ The server's TLS certificate. The server always uses TLS (on 127.0.0.1
  too): one path for one's own machine and for a VPS, checked on every
  start.

  Two sources:
  - one's own file (--cert=FILE --key=FILE, PEM; Let's Encrypt for a
    server with a domain, for instance) — the browser and the window
    accept it without questions;
  - otherwise a self-signed one, made by the server on the first start and
    kept in conf.dat (encrypted, like everything there; the private key
    does not lie on disk as a plain file). Its term is 10 years: the window
    remembers the fingerprint (pinning), and a certificate change is a
    reason for it not to trust, so it must not change by itself. Synapse's
    stock CreateSelfSignedCert does not fit: it gives 60 days.

  The fingerprint is the SHA-256 of the certificate (DER), as browsers show
  it: the server prints it at start, the window checks against it. }

interface

uses
  Classes, SysUtils;

type
  TServerTls = record
    { From files (--cert/--key) — paths; otherwise DER in memory. }
    CertFile, KeyFile: string;
    CertDer, KeyDer: RawByteString;
    Fingerprint: string;
  end;

{ Prepares the certificate: from files if set, otherwise our own (created
  on the first start). False — with AError saying why. }
function PrepareServerTls(const ACertFile, AKeyFile: string; out ATls: TServerTls;
  out AError: string): boolean;

{ PEM -> DER of the first block ('' — not PEM). }
function PemToDer(const APem: string): RawByteString;

implementation

uses
  base64, ssl_openssl3_lib, constants, secureconfig, sha256u;

function PemToDer(const APem: string): RawByteString;
var
  A, B: integer;
  Body: string;
begin
  Result := '';
  A := Pos('-----BEGIN ', APem);
  if A = 0 then begin
    Exit;
  end;
  A := Pos(#10, APem, A);
  B := Pos('-----END ', APem, A);
  if (A = 0) or (B = 0) then begin
    Exit;
  end;
  Body := StringReplace(StringReplace(Copy(APem, A + 1, B - A - 1), #13, '', [rfReplaceAll]),
    #10, '', [rfReplaceAll]);
  Result := DecodeStringBase64(Body);
end;

function ReadFileText(const AFile: string): string;
var
  S: TStringStream;
begin
  S := TStringStream.Create('');
  try
    S.LoadFromFile(AFile);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

function BioBytes(B: PBIO): RawByteString;
var
  N, Got: integer;
  S: AnsiString;
begin
  N := BioCtrlPending(B);
  SetLength(S, N);
  Got := BioRead(B, S, N);
  if Got > 0 then begin
    SetLength(S, Got);
  end else begin
    S := '';
  end;
  Result := S;
end;

{ The same as TSSLOpenSSL3.CreateSelfSignedCert (ssl_openssl3.pas), but
  for TLS_SELF_SIGNED_DAYS and with our own name. }
function MakeSelfSigned(out ACert, AKey: RawByteString): boolean;
var
  Pk: EVP_PKEY;
  X: PX509;
  Rsa: PRSA;
  T: PASN1_UTCTIME;
  Name: PX509_NAME;
  B: PBIO;
begin
  Result := False;
  ACert := '';
  AKey := '';
  if not InitSSLInterface then begin
    Exit;
  end;
  Pk := EvpPkeyNew;
  X := X509New;
  try
    Rsa := RsaGenerateKey(TLS_RSA_BITS, $10001, nil, nil);
    EvpPkeyAssign(Pk, EVP_PKEY_RSA, Rsa);
    X509SetVersion(X, 2);
    Asn1IntegerSet(X509GetSerialNumber(X), integer(GetTickCount64 and $7FFFFFFF));
    T := Asn1UtctimeNew;
    try
      X509GmtimeAdj(T, -60 * 60 * 24);
      X509SetNotBefore(X, T);
      X509GmtimeAdj(T, TLS_SELF_SIGNED_DAYS * 60 * 60 * 24);
      X509SetNotAfter(X, T);
    finally
      Asn1UtctimeFree(T);
    end;
    X509SetPubkey(X, Pk);
    Name := X509GetSubjectName(X);
    X509NameAddEntryByTxt(Name, 'CN', $1001, TLS_SELF_SIGNED_NAME, -1, -1, 0);
    X509SetIssuerName(X, Name);
    X509Sign(X, Pk, EvpGetDigestByName('SHA256'));
    B := BioNew(BioSMem);
    try
      I2dX509Bio(B, X);
      ACert := BioBytes(B);
    finally
      BioFreeAll(B);
    end;
    B := BioNew(BioSMem);
    try
      I2dPrivateKeyBio(B, Pk);
      AKey := BioBytes(B);
    finally
      BioFreeAll(B);
    end;
  finally
    X509Free(X);
    EvpPkeyFree(Pk);
  end;
  Result := (ACert <> '') and (AKey <> '');
end;

function PrepareServerTls(const ACertFile, AKeyFile: string; out ATls: TServerTls;
  out AError: string): boolean;
var
  Ini: TSecureIni;
begin
  Result := False;
  AError := '';
  ATls := Default(TServerTls);
  if not InitSSLInterface then begin
    AError := 'OpenSSL (libssl-3, libcrypto-3) could not be loaded';
    Exit;
  end;

  if (ACertFile <> '') or (AKeyFile <> '') then begin
    if (ACertFile = '') or (AKeyFile = '') then begin
      AError := '--cert and --key go together';
      Exit;
    end;
    if not FileExists(ACertFile) then begin
      AError := 'No certificate file ' + ACertFile;
      Exit;
    end;
    if not FileExists(AKeyFile) then begin
      AError := 'No key file ' + AKeyFile;
      Exit;
    end;
    ATls.CertFile := ExpandFileName(ACertFile);
    ATls.KeyFile := ExpandFileName(AKeyFile);
    ATls.CertDer := PemToDer(ReadFileText(ATls.CertFile));
    if ATls.CertDer = '' then begin
      AError := 'The certificate file is not PEM';
      Exit;
    end;
    ATls.Fingerprint := DigestColonHex(Sha256(ATls.CertDer));
    Result := True;
    Exit;
  end;

  Ini := OpenConfig;
  try
    ATls.CertDer := DecodeStringBase64(Ini.ReadString(TLS_CONFIG_SECTION, TLS_CONFIG_CERT, ''));
    ATls.KeyDer := DecodeStringBase64(Ini.ReadString(TLS_CONFIG_SECTION, TLS_CONFIG_KEY, ''));
    if (ATls.CertDer = '') or (ATls.KeyDer = '') then begin
      if not MakeSelfSigned(ATls.CertDer, ATls.KeyDer) then begin
        AError := 'Could not create a self-signed certificate';
        Exit;
      end;
      Ini.WriteString(TLS_CONFIG_SECTION, TLS_CONFIG_CERT, EncodeStringBase64(ATls.CertDer));
      Ini.WriteString(TLS_CONFIG_SECTION, TLS_CONFIG_KEY, EncodeStringBase64(ATls.KeyDer));
    end;
  finally
    Ini.Free;
  end;
  ATls.Fingerprint := DigestColonHex(Sha256(ATls.CertDer));
  Result := True;
end;

end.
