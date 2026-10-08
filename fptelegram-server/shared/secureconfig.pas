unit secureconfig;

{ Настройки программы — один зашифрованный файл вместо config.ini и
  accounts.ini (2026-10-06).

  Ключ — случайный, свой на каждой машине и у каждого пользователя
  Windows: создаётся при первом запуске и хранится в заголовке того же
  файла, защищённый DPAPI (CryptProtectData, текущий пользователь, плюс
  строка программы SECURE_CONFIG_ENTROPY). Файл, скопированный на другой
  компьютер или другому пользователю, не расшифровывается; секрета в
  самой программе нет.

  Формат (все целые — little-endian):
    'FPTS'                       магия
    версия                       1 байт (SECURE_CONFIG_VERSION)
    длина блоба DPAPI            4 байта
    блоб DPAPI                   защищённый мастер-ключ (88 байт:
                                 56 — Blowfish, 32 — HMAC)
    IV                           8 байт, новый при каждой записи
    длина шифротекста            4 байта
    шифротекст                   Blowfish-CBC, дополнение PKCS#7
    HMAC-SHA1                    20 байт по всему, что выше
  Внутри — текст ini (UTF-8): [telegram], [ui], [autodownload], ...,
  [accounts] (бывший [general] из accounts.ini) и [accN].

  Blowfish — блочный шифр из fcl-base (blowfish.pp, только блок 8 байт);
  CBC и HMAC собраны здесь, HMAC — на SHA1Init/Update/Final по сырым
  буферам (hmac.pp берёт string, и при DefaultSystemCodePage = UTF-8
  двоичные данные могли бы перекодироваться).

  Доступ — как раньше к TIniFile: OpenConfig отдаёт TMemIniFile с
  текущим содержимым; изменения сохраняются при UpdateFile и при Free. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles;

type
  { Окно в общие настройки на время одного блока: читает их при
    создании, пишет (шифруя) при UpdateFile и при уничтожении, если что-то
    изменилось. }
  TSecureIni = class(TMemIniFile)
  public
    constructor CreateFromStore;
    destructor Destroy; override;
    procedure UpdateFile; override;
  end;

{ Каталог файла настроек (папка программы). Зовёт TTdCore при создании. }
procedure SecureConfigSetDir(const ADir: string);
{ Настройки на время блока; вызывающий освобождает. }
function OpenConfig: TSecureIni;
{ Почему прежний файл не прочитался ('' — всё в порядке). }
function SecureConfigProblem: string;
{ Криптостойкие случайные байты (ключи, соли, токены). }
function SecureRandomBytes(ALen: integer): RawByteString;

implementation

uses
  Windows, SyncObjs, sha1, blowfish, constants;

var
  { Настройки читают и пишут и главный поток, и потоки сокетов (вход,
    srvauth). Замок держится всё время жизни TSecureIni — от чтения до
    записи, — чтобы два окна в настройки не затёрли друг друга.
    Повторный вход тем же потоком допустим (критическая секция FPC
    рекурсивна). }
  GLock: TCriticalSection = nil;

{ ------------------------------------------------------------------ }
{ Windows: случайные байты и DPAPI                                    }
{ ------------------------------------------------------------------ }

type
  TDataBlob = record
    cbData: DWORD;
    pbData: PByte;
  end;
  PDataBlob = ^TDataBlob;

const
  CRYPTPROTECT_UI_FORBIDDEN = $1;
  MOVEFILE_REPLACE_EXISTING_ = $1;
  MOVEFILE_WRITE_THROUGH_ = $8;

function RtlGenRandom(RandomBuffer: Pointer; RandomBufferLength: ULONG): BOOLEAN; stdcall;
  external 'advapi32.dll' name 'SystemFunction036';
function CryptProtectData(pDataIn: PDataBlob; szDataDescr: PWideChar;
  pOptionalEntropy: PDataBlob; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall; external 'crypt32.dll';
function CryptUnprotectData(pDataIn: PDataBlob; ppszDataDescr: Pointer;
  pOptionalEntropy: PDataBlob; pvReserved: Pointer; pPromptStruct: Pointer;
  dwFlags: DWORD; pDataOut: PDataBlob): BOOL; stdcall; external 'crypt32.dll';

procedure RandomFill(out ABuf; ALen: integer);
begin
  if not RtlGenRandom(@ABuf, ALen) then begin
    raise Exception.Create('No secure random source');
  end;
end;

function SecureRandomBytes(ALen: integer): RawByteString;
begin
  SetLength(Result, ALen);
  if ALen > 0 then begin
    RandomFill(Result[1], ALen);
  end;
end;

function DpapiCall(const AData: TBytes; AProtect: boolean): TBytes;
var
  InBlob, OutBlob, Entropy: TDataBlob;
  Ent: string;
  Ok: BOOL;
begin
  Result := nil;
  Ent := SECURE_CONFIG_ENTROPY;
  Entropy.cbData := Length(Ent);
  Entropy.pbData := PByte(PChar(Ent));
  InBlob.cbData := Length(AData);
  InBlob.pbData := PByte(AData);
  FillChar(OutBlob, SizeOf(OutBlob), 0);
  if AProtect then begin
    Ok := CryptProtectData(@InBlob, nil, @Entropy, nil, nil,
      CRYPTPROTECT_UI_FORBIDDEN, @OutBlob);
  end else begin
    Ok := CryptUnprotectData(@InBlob, nil, @Entropy, nil, nil,
      CRYPTPROTECT_UI_FORBIDDEN, @OutBlob);
  end;
  if not Ok then begin
    raise Exception.CreateFmt('DPAPI failed (%d)', [GetLastError]);
  end;
  try
    SetLength(Result, OutBlob.cbData);
    if OutBlob.cbData > 0 then begin
      Move(OutBlob.pbData^, Result[0], OutBlob.cbData);
    end;
  finally
    LocalFree(HLOCAL(OutBlob.pbData));
  end;
end;

{ ------------------------------------------------------------------ }
{ HMAC-SHA1 и Blowfish-CBC                                            }
{ ------------------------------------------------------------------ }

const
  KEY_ENC_LEN = 56;          { Blowfish: ключ до 448 бит }
  KEY_MAC_LEN = 32;
  KEY_LEN = KEY_ENC_LEN + KEY_MAC_LEN;
  BLOCK = 8;
  MAC_LEN = 20;
  SHA1_BLOCK = 64;

function HmacSha1(const AKey; AKeyLen: integer; const AData; ADataLen: integer): TSHA1Digest;
var
  K: array[0..SHA1_BLOCK - 1] of byte;
  Pad: array[0..SHA1_BLOCK - 1] of byte;
  Inner: TSHA1Digest;
  Ctx: TSHA1Context;
  I: integer;
begin
  FillChar(K, SizeOf(K), 0);
  if AKeyLen > SHA1_BLOCK then begin
    SHA1Init(Ctx);
    SHA1Update(Ctx, AKey, AKeyLen);
    SHA1Final(Ctx, Inner);
    Move(Inner, K, SizeOf(Inner));
  end else if AKeyLen > 0 then begin
    Move(AKey, K, AKeyLen);
  end;
  for I := 0 to SHA1_BLOCK - 1 do begin
    Pad[I] := K[I] xor $36;
  end;
  SHA1Init(Ctx);
  SHA1Update(Ctx, Pad, SHA1_BLOCK);
  if ADataLen > 0 then begin
    SHA1Update(Ctx, AData, ADataLen);
  end;
  SHA1Final(Ctx, Inner);
  for I := 0 to SHA1_BLOCK - 1 do begin
    Pad[I] := K[I] xor $5C;
  end;
  SHA1Init(Ctx);
  SHA1Update(Ctx, Pad, SHA1_BLOCK);
  SHA1Update(Ctx, Inner, SizeOf(Inner));
  SHA1Final(Ctx, Result);
end;

function NewCipher(const AMaster: TBytes): TBlowFish;
var
  Key: TBlowFishKey;
begin
  Move(AMaster[0], Key[0], KEY_ENC_LEN);
  Result := TBlowFish.Create(Key, KEY_ENC_LEN);
  FillChar(Key, SizeOf(Key), 0);
end;

function EncryptCbc(const AMaster: TBytes; const APlain: TBytes; const AIv: TBytes): TBytes;
var
  Bf: TBlowFish;
  Pad, N, I, J: integer;
  Prev, Blk: TBFBlock;
begin
  Result := nil;
  Pad := BLOCK - Length(APlain) mod BLOCK;
  N := Length(APlain) + Pad;
  SetLength(Result, N);
  if Length(APlain) > 0 then begin
    Move(APlain[0], Result[0], Length(APlain));
  end;
  for I := Length(APlain) to N - 1 do begin
    Result[I] := Pad;
  end;
  Bf := NewCipher(AMaster);
  try
    Move(AIv[0], Prev, BLOCK);
    I := 0;
    while I < N do begin
      Move(Result[I], Blk, BLOCK);
      for J := 0 to 1 do begin
        Blk[J] := Blk[J] xor Prev[J];
      end;
      Bf.Encrypt(Blk);
      Move(Blk, Result[I], BLOCK);
      Prev := Blk;
      Inc(I, BLOCK);
    end;
  finally
    Bf.Free;
  end;
end;

function DecryptCbc(const AMaster: TBytes; const ACipher: TBytes; const AIv: TBytes): TBytes;
var
  Bf: TBlowFish;
  N, I, J, Pad: integer;
  Prev, Blk, Saved: TBFBlock;
begin
  Result := nil;
  N := Length(ACipher);
  if (N = 0) or (N mod BLOCK <> 0) then begin
    raise Exception.Create('Damaged settings file');
  end;
  SetLength(Result, N);
  Bf := NewCipher(AMaster);
  try
    Move(AIv[0], Prev, BLOCK);
    I := 0;
    while I < N do begin
      Move(ACipher[I], Blk, BLOCK);
      Saved := Blk;
      Bf.Decrypt(Blk);
      for J := 0 to 1 do begin
        Blk[J] := Blk[J] xor Prev[J];
      end;
      Move(Blk, Result[I], BLOCK);
      Prev := Saved;
      Inc(I, BLOCK);
    end;
  finally
    Bf.Free;
  end;
  Pad := Result[N - 1];
  if (Pad < 1) or (Pad > BLOCK) then begin
    raise Exception.Create('Damaged settings file');
  end;
  SetLength(Result, N - Pad);
end;

{ ------------------------------------------------------------------ }
{ Файл                                                                }
{ ------------------------------------------------------------------ }

var
  GDir: string = '';
  GLoaded: boolean = False;
  GText: string = '';        { расшифрованный текст ini }
  GMaster: TBytes = nil;     { мастер-ключ (в памяти процесса) }
  GBlob: TBytes = nil;       { он же под DPAPI — пишется в заголовок }
  GProblem: string = '';

function StorePath: string;
begin
  Result := GDir + SECURE_CONFIG_FILE;
end;

procedure PutU32(var ABuf: TBytes; var APos: integer; AValue: DWORD);
begin
  Move(AValue, ABuf[APos], 4);
  Inc(APos, 4);
end;

function GetU32(const ABuf: TBytes; var APos: integer): DWORD;
begin
  if APos + 4 > Length(ABuf) then begin
    raise Exception.Create('Damaged settings file');
  end;
  Move(ABuf[APos], Result, 4);
  Inc(APos, 4);
end;

function TextBytes(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then begin
    Move(AText[1], Result[0], Length(AText));
  end;
end;

function BytesText(const ABytes: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then begin
    Move(ABytes[0], Result[1], Length(ABytes));
  end;
end;

function Pack(const AText: string): TBytes;
var
  Iv, Ct: TBytes;
  Pos: integer;
  Mac: TSHA1Digest;
  Magic: string;
begin
  Result := nil;
  Magic := SECURE_CONFIG_MAGIC;
  SetLength(Iv, BLOCK);
  RandomFill(Iv[0], BLOCK);
  Ct := EncryptCbc(GMaster, TextBytes(AText), Iv);
  SetLength(Result, 4 + 1 + 4 + Length(GBlob) + BLOCK + 4 + Length(Ct) + MAC_LEN);
  Pos := 0;
  Move(Magic[1], Result[Pos], 4);
  Inc(Pos, 4);
  Result[Pos] := SECURE_CONFIG_VERSION;
  Inc(Pos);
  PutU32(Result, Pos, Length(GBlob));
  Move(GBlob[0], Result[Pos], Length(GBlob));
  Inc(Pos, Length(GBlob));
  Move(Iv[0], Result[Pos], BLOCK);
  Inc(Pos, BLOCK);
  PutU32(Result, Pos, Length(Ct));
  Move(Ct[0], Result[Pos], Length(Ct));
  Inc(Pos, Length(Ct));
  Mac := HmacSha1(GMaster[KEY_ENC_LEN], KEY_MAC_LEN, Result[0], Pos);
  Move(Mac, Result[Pos], MAC_LEN);
end;

{ Разбор файла: ключ — из DPAPI-блоба, затем проверка HMAC, затем
  расшифровка. Заполняет GMaster/GBlob; результат — текст ini. }
function Unpack(const AData: TBytes): string;
var
  Pos, BlobLen, CtLen, MacAt: integer;
  Iv, Ct, Master: TBytes;
  Mac, Want: TSHA1Digest;
  Magic: string;
begin
  Magic := SECURE_CONFIG_MAGIC;
  if (Length(AData) < 4 + 1 + 4 + BLOCK + 4 + MAC_LEN)
     or not CompareMem(@AData[0], @Magic[1], 4) then begin
    raise Exception.Create('Not a settings file');
  end;
  if AData[4] <> SECURE_CONFIG_VERSION then begin
    raise Exception.CreateFmt('Unknown settings file version %d', [AData[4]]);
  end;
  Pos := 5;
  BlobLen := GetU32(AData, Pos);
  if Pos + BlobLen > Length(AData) then begin
    raise Exception.Create('Damaged settings file');
  end;
  GBlob := Copy(AData, Pos, BlobLen);
  Inc(Pos, BlobLen);
  Master := DpapiCall(GBlob, False);
  if Length(Master) <> KEY_LEN then begin
    raise Exception.Create('Damaged settings key');
  end;
  if Pos + BLOCK > Length(AData) then begin
    raise Exception.Create('Damaged settings file');
  end;
  Iv := Copy(AData, Pos, BLOCK);
  Inc(Pos, BLOCK);
  CtLen := GetU32(AData, Pos);
  MacAt := Pos + CtLen;
  if MacAt + MAC_LEN <> Length(AData) then begin
    raise Exception.Create('Damaged settings file');
  end;
  Ct := Copy(AData, Pos, CtLen);
  Mac := HmacSha1(Master[KEY_ENC_LEN], KEY_MAC_LEN, AData[0], MacAt);
  Move(AData[MacAt], Want, MAC_LEN);
  if not CompareMem(@Mac, @Want, MAC_LEN) then begin
    raise Exception.Create('Settings file was changed or damaged');
  end;
  GMaster := Master;
  Result := BytesText(DecryptCbc(GMaster, Ct, Iv));
end;

function ReadAll(const APath: string): TBytes;
var
  F: TFileStream;
begin
  Result := nil;
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then begin
      F.ReadBuffer(Result[0], F.Size);
    end;
  finally
    F.Free;
  end;
end;

{ Запись — во временный файл и подмена (MoveFileEx с заменой): оборванная
  запись не оставит полфайла вместо настроек. }
procedure WriteStore;
var
  Data: TBytes;
  Tmp: string;
  F: TFileStream;
begin
  Data := Pack(GText);
  Tmp := StorePath + '.tmp';
  F := TFileStream.Create(Tmp, fmCreate);
  try
    F.WriteBuffer(Data[0], Length(Data));
  finally
    F.Free;
  end;
  if not MoveFileExW(PWideChar(UnicodeString(Tmp)), PWideChar(UnicodeString(StorePath)),
     MOVEFILE_REPLACE_EXISTING_ or MOVEFILE_WRITE_THROUGH_) then begin
    raise Exception.CreateFmt('Could not save settings (%d)', [GetLastError]);
  end;
end;

{ Прежние config.ini и accounts.ini -> текст ini одного файла
  ([general] из accounts.ini становится [accounts]). }
function LegacyText: string;
var
  Merged, Src: TMemIniFile;
  Sections, Values: TStringList;

  procedure Take(const APath: string; ARenameGeneral: boolean);
  var
    I, J: integer;
    Target: string;
  begin
    if not FileExists(APath) then begin
      Exit;
    end;
    Src := TMemIniFile.Create(APath);
    try
      Sections.Clear;
      Src.ReadSections(Sections);
      for I := 0 to Sections.Count - 1 do begin
        Target := Sections[I];
        if ARenameGeneral and SameText(Target, 'general') then begin
          Target := SECURE_CONFIG_ACCOUNTS_SECTION;
        end;
        Values.Clear;
        Src.ReadSectionValues(Sections[I], Values);
        for J := 0 to Values.Count - 1 do begin
          Merged.WriteString(Target, Values.Names[J], Values.ValueFromIndex[J]);
        end;
      end;
    finally
      Src.Free;
    end;
  end;

begin
  Merged := TMemIniFile.Create('');
  Sections := TStringList.Create;
  Values := TStringList.Create;
  try
    Take(GDir + LEGACY_CONFIG_FILE, False);
    Take(GDir + MANIFEST, True);
    Values.Clear;
    Merged.GetStrings(Values);
    Result := Values.Text;
  finally
    Values.Free;
    Sections.Free;
    Merged.Free;
  end;
end;

procedure NewKey;
begin
  SetLength(GMaster, KEY_LEN);
  RandomFill(GMaster[0], KEY_LEN);
  GBlob := DpapiCall(GMaster, True);
end;

procedure EnsureLoaded;
var
  Bad: string;
begin
  if GLoaded then begin
    Exit;
  end;
  GLoaded := True;
  if GDir = '' then begin
    GDir := ExtractFilePath(ParamStr(0));
  end;

  { Файл под прежним именем — тот же формат, только переименовать. }
  if (not FileExists(StorePath)) and FileExists(GDir + SECURE_CONFIG_FILE_OLD) then begin
    SysUtils.RenameFile(GDir + SECURE_CONFIG_FILE_OLD, StorePath);
  end;

  if FileExists(StorePath) then begin
    try
      GText := Unpack(ReadAll(StorePath));
      Exit;
    except
      on E: Exception do begin
        { Не стираем: файл другого пользователя или машины, или битый. Он
          откладывается в сторону, настройки начинаются заново — api_id
          и api_hash спросит страница, сессии TDLib (tdlib/accN) целы. }
        GProblem := E.Message;
        Bad := StorePath + SECURE_CONFIG_BAD_SUFFIX;
        SysUtils.DeleteFile(Bad);
        SysUtils.RenameFile(StorePath, Bad);
        GMaster := nil;
        GBlob := nil;
      end;
    end;
  end;

  { Первый запуск на этой машине у этого пользователя: свой ключ. Если
    рядом прежние открытые файлы — их содержимое переезжает внутрь, а
    сами они удаляются, только когда записанное прочиталось обратно. }
  NewKey;
  GText := LegacyText;
  WriteStore;
  if (Unpack(ReadAll(StorePath)) = GText) then begin
    if FileExists(GDir + LEGACY_CONFIG_FILE) then begin
      SysUtils.DeleteFile(GDir + LEGACY_CONFIG_FILE);
    end;
    if FileExists(GDir + MANIFEST) then begin
      SysUtils.DeleteFile(GDir + MANIFEST);
    end;
  end;
end;

{ ------------------------------------------------------------------ }

procedure SecureConfigSetDir(const ADir: string);
begin
  GDir := IncludeTrailingPathDelimiter(ADir);
end;


function OpenConfig: TSecureIni;
begin
  GLock.Enter;
  try
    EnsureLoaded;
    Result := TSecureIni.CreateFromStore;
  except
    GLock.Leave;
    raise;
  end;
end;

function SecureConfigProblem: string;
begin
  Result := GProblem;
end;

constructor TSecureIni.CreateFromStore;
var
  L: TStringList;
begin
  inherited Create('');
  L := TStringList.Create;
  try
    L.Text := GText;
    SetStrings(L);
  finally
    L.Free;
  end;
end;

procedure TSecureIni.UpdateFile;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    GetStrings(L);
    GText := L.Text;
  finally
    L.Free;
  end;
  { Файлового имени нет — inherited ничего не пишет, только сбрасывает
    признак изменений. Пишем мы. }
  inherited UpdateFile;
  WriteStore;
end;

destructor TSecureIni.Destroy;
begin
  try
    if Dirty then begin
      try
        UpdateFile;
      except
        { Как у TIniFile: деструктор исключений не бросает. }
      end;
    end;
    inherited Destroy;
  finally
    { Взят в OpenConfig. }
    GLock.Leave;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GLock);

end.
