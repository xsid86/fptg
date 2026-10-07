unit srvauth;

{$mode objfpc}{$H+}

{ Вход на сервер: пользователи с паролями, сеансы, JWT.

  Пользователь входит логином и паролем (POST /api/login, localserver)
  и получает refresh-токен — долгий секрет сеанса: окно хранит его в
  своём conf.dat, браузер — в localStorage. Пароль не хранится нигде,
  кроме хеша на сервере (PBKDF2-HMAC-SHA256). По refresh-токену
  (POST /api/refresh) выдаются JWT (HS256, подпись — секрет из conf.dat
  сервера):
  - access (scp api) — на час: веб-сокет, загрузки;
  - media (scp media) — без срока, пока жив сеанс: адреса картинок
    висят в странице часами, и протухать каждый час им нельзя.
  Любой JWT действует, только пока жив его сеанс: выход (/api/logout)
  или --logout-all гасят их сразу, а не по истечении срока.

  Сеанс в conf.dat — sid = JSON (user, hash — SHA-256 refresh-токена,
  самого токена на диске нет, created, used, device); сеанс, которым
  не пользовались AUTH_SESSION_IDLE_DAYS, гаснет.

  Потоки: проверка JWT и /api/… идут в потоках сокетов, управление
  пользователями — в главном. Всё состояние — в памяти под замком;
  conf.dat пишется под замком secureconfig. }

interface

uses
  Classes, SysUtils;

type
  TAuthScope = (ascApi, ascMedia);

{ Загрузить пользователей, сеансы и ключ подписи (создав ключ при
  первом запуске). Зовётся до старта сервера. }
procedure AuthLoad;

function AuthUserCount: integer;
function AuthHasUser(const AName: string): boolean;
{ Новый пользователь или новый пароль существующему. }
procedure AuthSetPassword(const AName, APassword: string);
{ Удаляет пользователя и все его сеансы. False — такого нет. }
function AuthRemoveUser(const AName: string): boolean;
{ Гасит все сеансы и меняет ключ подписи: все выданные JWT — тоже. }
procedure AuthLogoutAll;

{ Вход. True — ARefresh: новый refresh-токен; иначе AError (для
  страницы: одинаковый на неверное имя и неверный пароль). AIp — для
  защиты от перебора. }
function AuthLogin(const AUser, APassword, ADevice, AIp: string;
  out ARefresh, AError: string): boolean;
{ По refresh-токену — свежие JWT. AExpires — срок access, unix-время. }
function AuthRefresh(const ARefresh: string; out AAccess, AMedia, AUser: string;
  out AExpires: Int64; out AError: string): boolean;
procedure AuthLogout(const ARefresh: string);

{ Проверка JWT запроса. Media-адрес принимает и access-токен. }
function AuthCheck(const AJwt: string; AScope: TAuthScope): boolean;

implementation

uses
  base64, fpjson, jsonparser, DateUtils, SyncObjs,
  constants, secureconfig, sha256u;

type
  TSession = class
    Sid: string;
    User: string;
    Hash: RawByteString;      { SHA-256 refresh-токена }
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
  GUsers: TStringList = nil;      { имя=salt:iterations:hash (base64) }
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

{ ---------------- хранение ---------------- }

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

{ Под GLock. Пишет пользователей, сеансы и ключ целиком: их мало. }
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
            { Сеанс давно не трогали или его пользователя уже нет. }
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

function AuthUserCount: integer;
begin
  GLock.Enter;
  try
    Result := GUsers.Count;
  finally
    GLock.Leave;
  end;
end;

function AuthHasUser(const AName: string): boolean;
begin
  GLock.Enter;
  try
    Result := GUsers.IndexOfName(AName) >= 0;
  finally
    GLock.Leave;
  end;
end;

procedure AuthSetPassword(const AName, APassword: string);
var
  Salt: RawByteString;
begin
  if (AName = '') or (Pos('=', AName) > 0) or (Trim(AName) <> AName) then begin
    raise Exception.Create('A user name cannot be empty, contain "=" or spaces at the ends');
  end;
  Salt := SecureRandomBytes(AUTH_SALT_BYTES);
  GLock.Enter;
  try
    GUsers.Values[AName] := EncodeStringBase64(Salt) + ':' + IntToStr(AUTH_PBKDF2_ITERATIONS)
      + ':' + EncodeStringBase64(Pbkdf2Sha256(APassword, Salt, AUTH_PBKDF2_ITERATIONS,
        AUTH_HASH_BYTES));
    Persist;
  finally
    GLock.Leave;
  end;
end;

function AuthRemoveUser(const AName: string): boolean;
var
  I: integer;
begin
  GLock.Enter;
  try
    I := GUsers.IndexOfName(AName);
    Result := I >= 0;
    if not Result then begin
      Exit;
    end;
    GUsers.Delete(I);
    for I := GSessions.Count - 1 downto 0 do begin
      if TSession(GSessions[I]).User = AName then begin
        TSession(GSessions[I]).Free;
        GSessions.Delete(I);
      end;
    end;
    Persist;
  finally
    GLock.Leave;
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
end;

{ ---------------- перебор ---------------- }

{ Под GLock. Индекс записи адреса, создаёт при нужде. }
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

{ ---------------- вход ---------------- }

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

  { PBKDF2 — без замка: ~0.1 с, и другим потокам ждать незачем.
    Неизвестное имя проверяется так же долго, как известное, — по
    времени ответа имена не перебрать. }
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

{ Под GLock. Сеанс по refresh-токену. }
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

{ Под GLock. }
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
    { «Пользовались» — не чаще раза в час: запись conf.dat не на
      каждое продление. }
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
begin
  GLock.Enter;
  try
    S := FindByRefresh(ARefresh);
    if S <> nil then begin
      GSessions.Remove(S);
      S.Free;
      Persist;
    end;
  finally
    GLock.Leave;
  end;
end;

function CheckJwt(const AJwt: string; AScope: TAuthScope): boolean; forward;

{ Любой мусор вместо токена — просто «нет»: битый base64 или JSON
  бросают исключения, а это проверка в потоке сокета. }
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
      { Адрес медиа принимает и access: им же пользуется загрузка. }
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
