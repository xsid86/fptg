unit srvauth;

{$mode objfpc}{$H+}

{ Signing in to the server: users with passwords, sessions, JWT.

  The user signs in with a login and password (POST /api/login,
  localserver) and gets a refresh token — the session's long-lived secret:
  the window keeps it in its conf.dat, a browser — in localStorage. The
  password is kept nowhere except as a hash on the server
  (PBKDF2-HMAC-SHA256). By the refresh token (POST /api/refresh) JWTs are
  issued (HS256, signed with a secret from the server's conf.dat):
  - access (scp api) — for an hour: the web socket, uploads;
  - media (scp media) — no expiry while the session lives: picture
    addresses stay in the page for hours and must not go stale every hour.
  Any JWT works only while its session lives: sign-out (/api/logout) or
  --sign-out ends them at once, not when they expire.

  A session in conf.dat — sid = JSON (user, hash — the SHA-256 of the
  refresh token, the token itself is not on disk, created, used, device);
  a session unused for AUTH_SESSION_IDLE_DAYS expires.

  Threads: JWT checks and /api/… run on socket threads, user management —
  on the main one. All the state is in memory under a lock; conf.dat is
  written under the secureconfig lock. }

interface

uses
  Classes, SysUtils;

type
  TAuthScope = (ascApi, ascMedia);

{ Load the users, sessions and the signing key (creating the key on the
  first start). Called before the server starts. }
procedure AuthLoad;

{ The server has one user (the TDLib data belongs to one person). '' —
  not set up yet, nobody can sign in. }
function AuthUserName: string;
{ Login and password of the only user. The same login — only a new
  password, the sessions stay; another one — the previous user is
  replaced and their sessions end. }
procedure AuthSetUser(const AName, APassword: string);
{ Ends all sessions and changes the signing key: all issued JWTs too. }
procedure AuthLogoutAll;

{ Sign-in. True — ARefresh: a new refresh token; otherwise AError (for the
  page: the same for a wrong name and a wrong password). AIp — for
  brute-force protection. }
function AuthLogin(const AUser, APassword, ADevice, AIp: string;
  out ARefresh, AError: string): boolean;
{ Fresh JWTs by a refresh token. AExpires — the access token's expiry, unix time. }
function AuthRefresh(const ARefresh: string; out AAccess, AMedia, AUser: string;
  out AExpires: Int64; out AError: string): boolean;
procedure AuthLogout(const ARefresh: string);

{ Checking a request's JWT. A media address accepts an access token too. }
function AuthCheck(const AJwt: string; AScope: TAuthScope): boolean;
{ The session (sid) of a checked JWT — to close its connections when the
  session is ended. }
function AuthSessionId(const AJwt: string): string;

type
  { Sessions ended: ASids — their ids, nil — all. Called outside the
    srvauth lock, on the thread of whoever ended them. }
  TAuthSessionsEnded = procedure(ASids: TStrings);

var
  { Set by localserver: close the web sockets of these sessions. Without it
    an already open socket lives on — the token is checked only on
    connecting. }
  AuthSessionsEnded: TAuthSessionsEnded = nil;

implementation

uses
  base64, fpjson, jsonparser, DateUtils, SyncObjs,
  constants, secureconfig, sha256u;

type
  TSession = class
    Sid: string;
    User: string;
    Hash: RawByteString;      { SHA-256 of the refresh token }
    Created, Used: Int64;
    Device: string;
  end;

  TFails = record
    Ip: string;
    Count: integer;
    First, LockedUntil: Int64;
  end;

var
  GLock: TCriticalSection = nil;
  GUsers: TStringList = nil;      { name=salt:iterations:hash (base64) }
  GSessions: TFPList = nil;
  GKey: RawByteString = '';
  GFails: array of TFails;

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

{ ---------------- base64url ---------------- }

function B64Url(const S: RawByteString): string;
begin
  Result := EncodeStringBase64(S);
  Result := StringReplace(Result, '+', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  while (Result <> '') and (Result[Length(Result)] = '=') do begin
    SetLength(Result, Length(Result) - 1);
  end;
end;

function UnB64Url(const S: string): RawByteString;
var
  T: string;
begin
  T := StringReplace(StringReplace(S, '-', '+', [rfReplaceAll]), '_', '/', [rfReplaceAll]);
  while Length(T) mod 4 <> 0 do begin
    T := T + '=';
  end;
  Result := DecodeStringBase64(T);
end;

function HexOf(const S: RawByteString): string;
var
  I: integer;
begin
  Result := '';
  for I := 1 to Length(S) do begin
    Result := Result + LowerCase(IntToHex(byte(S[I]), 2));
  end;
end;

{ ---------------- storage ---------------- }

function SessionJson(S: TSession): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('user', S.User);
    O.Add('hash', EncodeStringBase64(S.Hash));
    O.Add('created', S.Created);
    O.Add('used', S.Used);
    O.Add('device', S.Device);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

{ Under GLock. Writes users, sessions and the key in full: there are few of them. }
procedure Persist;
var
  Ini: TSecureIni;
  I: integer;
begin
  Ini := OpenConfig;
  try
    Ini.WriteString(AUTH_CONFIG_SECTION, AUTH_CONFIG_JWT_KEY, EncodeStringBase64(GKey));
    Ini.EraseSection(AUTH_USERS_SECTION);
    for I := 0 to GUsers.Count - 1 do begin
      Ini.WriteString(AUTH_USERS_SECTION, GUsers.Names[I], GUsers.ValueFromIndex[I]);
    end;
    Ini.EraseSection(AUTH_SESSIONS_SECTION);
    for I := 0 to GSessions.Count - 1 do begin
      Ini.WriteString(AUTH_SESSIONS_SECTION, TSession(GSessions[I]).Sid,
        SessionJson(TSession(GSessions[I])));
    end;
  finally
    Ini.Free;
  end;
end;

procedure ClearSessions;
var
  I: integer;
begin
  for I := 0 to GSessions.Count - 1 do begin
    TSession(GSessions[I]).Free;
  end;
  GSessions.Clear;
end;

procedure AuthLoad;
var
  Ini: TSecureIni;
  Names: TStringList;
  I: integer;
  D: TJSONData;
  S: TSession;
  Changed: boolean;
begin
  GLock.Enter;
  try
    GUsers.Clear;
    ClearSessions;
    Changed := False;
    Names := TStringList.Create;
    Ini := OpenConfig;
    try
      GKey := DecodeStringBase64(Ini.ReadString(AUTH_CONFIG_SECTION, AUTH_CONFIG_JWT_KEY, ''));
      Ini.ReadSectionValues(AUTH_USERS_SECTION, GUsers);
      { From the times when there could be several users: the first one
        stays, the others' sessions end in the check below. }
      while GUsers.Count > 1 do begin
        GUsers.Delete(GUsers.Count - 1);
        Changed := True;
      end;
      Ini.ReadSection(AUTH_SESSIONS_SECTION, Names);
      for I := 0 to Names.Count - 1 do begin
        D := nil;
        try
          D := GetJSON(Ini.ReadString(AUTH_SESSIONS_SECTION, Names[I], ''));
        except
          D := nil;
        end;
        try
          if D is TJSONObject then begin
            S := TSession.Create;
            S.Sid := Names[I];
            S.User := TJSONObject(D).Get('user', '');
            S.Hash := DecodeStringBase64(TJSONObject(D).Get('hash', ''));
            S.Created := TJSONObject(D).Get('created', Int64(0));
            S.Used := TJSONObject(D).Get('used', Int64(0));
            S.Device := TJSONObject(D).Get('device', '');
            { The session has not been touched for long or its user is gone. }
            if (NowUnix - S.Used > Int64(AUTH_SESSION_IDLE_DAYS) * 86400)
               or (GUsers.IndexOfName(S.User) < 0) then begin
              S.Free;
              Changed := True;
            end else begin
              GSessions.Add(S);
            end;
          end;
        finally
          D.Free;
        end;
      end;
    finally
      Ini.Free;
      Names.Free;
    end;
    if Length(GKey) <> AUTH_JWT_KEY_BYTES then begin
      GKey := SecureRandomBytes(AUTH_JWT_KEY_BYTES);
      Changed := True;
    end;
    if Changed then begin
      Persist;
    end;
  finally
    GLock.Leave;
  end;
end;

function AuthUserName: string;
begin
  GLock.Enter;
  try
    if GUsers.Count > 0 then begin
      Result := GUsers.Names[0];
    end else begin
      Result := '';
    end;
  finally
    GLock.Leave;
  end;
end;

{ Report that sessions have ended (outside the lock). ASids = nil — all. }
procedure NotifyEnded(ASids: TStrings);
begin
  if Assigned(AuthSessionsEnded) then begin
    AuthSessionsEnded(ASids);
  end;
end;

procedure AuthSetUser(const AName, APassword: string);
var
  Salt: RawByteString;
  I: integer;
  Ended: TStringList;
begin
  if (AName = '') or (Pos('=', AName) > 0) or (Trim(AName) <> AName) then begin
    raise Exception.Create('A user name cannot be empty, contain "=" or spaces at the ends');
  end;
  if APassword = '' then begin
    raise Exception.Create('Empty password');
  end;
  Salt := SecureRandomBytes(AUTH_SALT_BYTES);
  Ended := TStringList.Create;
  try
    GLock.Enter;
    try
      for I := GSessions.Count - 1 downto 0 do begin
        if TSession(GSessions[I]).User <> AName then begin
          Ended.Add(TSession(GSessions[I]).Sid);
          TSession(GSessions[I]).Free;
          GSessions.Delete(I);
        end;
      end;
      GUsers.Clear;
      GUsers.Values[AName] := EncodeStringBase64(Salt) + ':' + IntToStr(AUTH_PBKDF2_ITERATIONS)
        + ':' + EncodeStringBase64(Pbkdf2Sha256(APassword, Salt, AUTH_PBKDF2_ITERATIONS,
          AUTH_HASH_BYTES));
      Persist;
    finally
      GLock.Leave;
    end;
    if Ended.Count > 0 then begin
      NotifyEnded(Ended);
    end;
  finally
    Ended.Free;
  end;
end;

procedure AuthLogoutAll;
begin
  GLock.Enter;
  try
    ClearSessions;
    GKey := SecureRandomBytes(AUTH_JWT_KEY_BYTES);
    Persist;
  finally
    GLock.Leave;
  end;
  NotifyEnded(nil);
end;

{ ---------------- brute force ---------------- }

{ Under GLock. The index of the address's record, created if needed. }
function FailSlot(const AIp: string): integer;
begin
  for Result := 0 to High(GFails) do begin
    if GFails[Result].Ip = AIp then begin
      Exit;
    end;
  end;
  Result := Length(GFails);
  SetLength(GFails, Result + 1);
  GFails[Result] := Default(TFails);
  GFails[Result].Ip := AIp;
end;

{ ---------------- sign-in ---------------- }

function CheckPassword(const AStored, APassword: string): boolean;
var
  P1, P2, Iter: integer;
  Salt, Hash: RawByteString;
begin
  Result := False;
  P1 := Pos(':', AStored);
  P2 := Pos(':', AStored, P1 + 1);
  if (P1 = 0) or (P2 = 0) then begin
    Exit;
  end;
  Salt := DecodeStringBase64(Copy(AStored, 1, P1 - 1));
  Iter := StrToIntDef(Copy(AStored, P1 + 1, P2 - P1 - 1), 0);
  Hash := DecodeStringBase64(Copy(AStored, P2 + 1, MaxInt));
  if (Iter <= 0) or (Hash = '') then begin
    Exit;
  end;
  Result := SameBytes(Pbkdf2Sha256(APassword, Salt, Iter, Length(Hash)), Hash);
end;

function AuthLogin(const AUser, APassword, ADevice, AIp: string;
  out ARefresh, AError: string): boolean;
var
  Stored: string;
  Slot: integer;
  NowT: Int64;
  Ok: boolean;
  S: TSession;
begin
  Result := False;
  ARefresh := '';
  AError := '';
  NowT := NowUnix;
  GLock.Enter;
  try
    Slot := FailSlot(AIp);
    if GFails[Slot].LockedUntil > NowT then begin
      AError := 'Too many attempts. Try again in a minute.';
      Exit;
    end;
    Stored := GUsers.Values[AUser];
  finally
    GLock.Leave;
  end;

  { PBKDF2 — without the lock: ~0.1 s, and other threads have no reason to
    wait. An unknown name is checked as long as a known one — names cannot
    be guessed from the answer time. }
  if Stored = '' then begin
    CheckPassword('AAAAAAAAAAAAAAAAAAAAAA==:' + IntToStr(AUTH_PBKDF2_ITERATIONS)
      + ':AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', APassword);
    Ok := False;
  end else begin
    Ok := CheckPassword(Stored, APassword);
  end;

  GLock.Enter;
  try
    Slot := FailSlot(AIp);
    if not Ok then begin
      if NowT - GFails[Slot].First > AUTH_FAIL_WINDOW_SEC then begin
        GFails[Slot].First := NowT;
        GFails[Slot].Count := 0;
      end;
      Inc(GFails[Slot].Count);
      if GFails[Slot].Count >= AUTH_FAIL_LIMIT then begin
        GFails[Slot].LockedUntil := NowT + AUTH_LOCK_SEC;
        GFails[Slot].Count := 0;
      end;
      AError := 'Wrong user name or password.';
      Exit;
    end;
    GFails[Slot].Count := 0;
    ARefresh := HexOf(SecureRandomBytes(AUTH_REFRESH_BYTES));
    S := TSession.Create;
    S.Sid := HexOf(SecureRandomBytes(8));
    S.User := AUser;
    S.Hash := DigestBytes(Sha256(ARefresh));
    S.Created := NowT;
    S.Used := NowT;
    S.Device := Copy(ADevice, 1, 100);
    GSessions.Add(S);
    Persist;
    Result := True;
  finally
    GLock.Leave;
  end;
end;

{ Under GLock. The session by refresh token. }
function FindByRefresh(const ARefresh: string): TSession;
var
  I: integer;
  H: RawByteString;
begin
  Result := nil;
  H := DigestBytes(Sha256(ARefresh));
  for I := 0 to GSessions.Count - 1 do begin
    if SameBytes(TSession(GSessions[I]).Hash, H) then begin
      Result := TSession(GSessions[I]);
      Exit;
    end;
  end;
end;

function FindBySid(const ASid: string): TSession;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to GSessions.Count - 1 do begin
    if TSession(GSessions[I]).Sid = ASid then begin
      Result := TSession(GSessions[I]);
      Exit;
    end;
  end;
end;

{ Under GLock. }
function MakeJwt(S: TSession; AScope: TAuthScope; AExpires: Int64): string;
var
  P: TJSONObject;
  Head, Body: string;
begin
  Head := B64Url('{"alg":"HS256","typ":"JWT"}');
  P := TJSONObject.Create;
  try
    P.Add('sub', S.User);
    P.Add('sid', S.Sid);
    if AScope = ascApi then begin
      P.Add('scp', 'api');
    end else begin
      P.Add('scp', 'media');
    end;
    P.Add('iat', NowUnix);
    if AExpires > 0 then begin
      P.Add('exp', AExpires);
    end;
    Body := B64Url(P.AsJSON);
  finally
    P.Free;
  end;
  Result := Head + '.' + Body + '.' + B64Url(DigestBytes(HmacSha256(GKey, Head + '.' + Body)));
end;

function AuthRefresh(const ARefresh: string; out AAccess, AMedia, AUser: string;
  out AExpires: Int64; out AError: string): boolean;
var
  S: TSession;
begin
  Result := False;
  AAccess := '';
  AMedia := '';
  AUser := '';
  AExpires := 0;
  AError := '';
  GLock.Enter;
  try
    S := FindByRefresh(ARefresh);
    if S = nil then begin
      AError := 'The session has ended. Sign in again.';
      Exit;
    end;
    AExpires := NowUnix + AUTH_ACCESS_TTL_SEC;
    AAccess := MakeJwt(S, ascApi, AExpires);
    AMedia := MakeJwt(S, ascMedia, 0);
    AUser := S.User;
    { "Used" — no more often than once an hour: no conf.dat write on every
      renewal. }
    if NowUnix - S.Used > 3600 then begin
      S.Used := NowUnix;
      Persist;
    end;
    Result := True;
  finally
    GLock.Leave;
  end;
end;

procedure AuthLogout(const ARefresh: string);
var
  S: TSession;
  Ended: TStringList;
begin
  Ended := TStringList.Create;
  try
    GLock.Enter;
    try
      S := FindByRefresh(ARefresh);
      if S <> nil then begin
        Ended.Add(S.Sid);
        GSessions.Remove(S);
        S.Free;
        Persist;
      end;
    finally
      GLock.Leave;
    end;
    if Ended.Count > 0 then begin
      NotifyEnded(Ended);
    end;
  finally
    Ended.Free;
  end;
end;

function AuthSessionId(const AJwt: string): string;
var
  P1, P2: integer;
  D: TJSONData;
begin
  Result := '';
  P1 := Pos('.', AJwt);
  P2 := Pos('.', AJwt, P1 + 1);
  if (P1 = 0) or (P2 = 0) then begin
    Exit;
  end;
  D := nil;
  try
    try
      D := GetJSON(UnB64Url(Copy(AJwt, P1 + 1, P2 - P1 - 1)));
    except
      D := nil;
    end;
    if D is TJSONObject then begin
      Result := TJSONObject(D).Get('sid', '');
    end;
  finally
    D.Free;
  end;
end;

function CheckJwt(const AJwt: string; AScope: TAuthScope): boolean; forward;

{ Any garbage instead of a token is simply "no": broken base64 or JSON
  raise exceptions, and this is a check on a socket thread. }
function AuthCheck(const AJwt: string; AScope: TAuthScope): boolean;
begin
  try
    Result := CheckJwt(AJwt, AScope);
  except
    Result := False;
  end;
end;

function CheckJwt(const AJwt: string; AScope: TAuthScope): boolean;
var
  P1, P2: integer;
  Signed, Scp: string;
  D: TJSONData;
  O: TJSONObject;
  Exp: Int64;
  S: TSession;
begin
  Result := False;
  P1 := Pos('.', AJwt);
  P2 := Pos('.', AJwt, P1 + 1);
  if (P1 = 0) or (P2 = 0) then begin
    Exit;
  end;
  Signed := Copy(AJwt, 1, P2 - 1);
  GLock.Enter;
  try
    if not SameBytes(UnB64Url(Copy(AJwt, P2 + 1, MaxInt)),
        DigestBytes(HmacSha256(GKey, Signed))) then begin
      Exit;
    end;
    D := nil;
    try
      D := GetJSON(UnB64Url(Copy(AJwt, P1 + 1, P2 - P1 - 1)));
    except
      D := nil;
    end;
    try
      if not (D is TJSONObject) then begin
        Exit;
      end;
      O := TJSONObject(D);
      Scp := O.Get('scp', '');
      { A media address accepts access too: the upload uses it. }
      if not ((Scp = 'api') or ((AScope = ascMedia) and (Scp = 'media'))) then begin
        Exit;
      end;
      Exp := O.Get('exp', Int64(0));
      if (Scp = 'api') and (Exp <= NowUnix) then begin
        Exit;
      end;
      S := FindBySid(O.Get('sid', ''));
      Result := (S <> nil) and (S.User = O.Get('sub', ''));
    finally
      D.Free;
    end;
  finally
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GUsers := TStringList.Create;
  GSessions := TFPList.Create;

finalization
  if GSessions <> nil then begin
    ClearSessions;
  end;
  FreeAndNil(GSessions);
  FreeAndNil(GUsers);
  FreeAndNil(GLock);
end.
