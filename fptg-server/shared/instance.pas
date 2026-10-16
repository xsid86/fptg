unit instance;

{$mode objfpc}{$H+}

{ Единственный экземпляр программы и канал управления к нему.

  Экземпляр — эксклюзивная блокировка файла ИМЯ.lock в папке программы
  (FileOpen с fmShareExclusive: на Windows — запрет совместного доступа,
  на Unix — flock LOCK_EX|LOCK_NB внутри RTL). Упала программа — ОС
  снимает блокировку сама, «залипших» экземпляров не бывает. Оба сервера
  (консольный и с окном) берут одну и ту же — у них общие данные.

  Канал управления — TCP на 127.0.0.1, порт выбирает ОС. Порт, случайный
  ключ, вид программы и pid лежат в ИМЯ.instance рядом с блокировкой (на
  Unix — права 600; на Windows файл наследует права папки программы —
  папки пользователя). Запрос — одна строка JSON (key, cmd, args), ответ
  — одна строка (ok, result или error), соединение закрывается. Команду
  выполняет обработчик в ГЛАВНОМ потоке (Synchronize): в консольном
  сервере его крутит srvloop, в окне — цикл LCL.

  Модуль общий у всех трёх программ (окно клиента берёт его через
  uses … in); сокеты — модуль sockets из RTL, без пакетов. }

interface

uses
  Classes, SysUtils, fpjson;

type
  { Команда другого экземпляра. Возвращает результат (освобождает
    вызывающий) или бросает исключение — оно уйдёт как error. }
  TInstanceCommand = function(const ACmd: string; AArgs: TJSONObject): TJSONObject of object;

{ Захватить экземпляр ADir/AName.lock. False — уже запущен другой.
  Сервер (INSTANCE_SERVER) — ещё и машинную блокировку: один на всю
  машину. False с InstanceElsewhere = True — папка свободна, но сервер
  уже работает из другой копии или у другого пользователя ОС: канала
  управления к нему отсюда нет. }
function AcquireInstance(const ADir, AName: string): boolean;

{ Последний AcquireInstance не прошёл из-за машинной блокировки. }
function InstanceElsewhere: boolean;
{ Открыть канал управления и записать AName.instance. AKind — вид
  программы ('gui', 'console', 'client'): по нему второй запуск решает,
  что делать. }
procedure PublishInstance(const AKind: string; AHandler: TInstanceCommand);
{ Закрыть канал, отпустить блокировку (и при выходе — само). }
procedure ReleaseInstance;

{ Вид запущенного экземпляра ('' — не отвечает). }
function InstanceKind(const ADir, AName: string): string;
{ Команда запущенному экземпляру. AArgs не забирается. AResult —
  вызывающему. }
function CallInstance(const ADir, AName, ACmd: string; AArgs: TJSONObject;
  out AResult: TJSONObject; out AError: string): boolean;

implementation

uses
  {$IFDEF WINDOWS}
  Windows, WinSock2,
  {$ELSE}
  BaseUnix, Unix,
  {$ENDIF}
  sockets, jsonparser, constants, secureconfig, sha256u;

type
  TControlThread = class(TThread)
  private
    FListen: longint;
    FHandler: TInstanceCommand;
    FCmd: string;
    FArgs: TJSONObject;
    FResult: TJSONObject;
    FError: string;
    procedure RunOnMain;
    procedure Serve(AConn: longint);
  protected
    procedure Execute; override;
  end;

var
  GLock: THandle = THandle(-1);
  GDir: string = '';
  GName: string = '';
  GKey: string = '';
  GKind: string = '';
  GPort: word = 0;
  GThread: TControlThread = nil;
  { Машинная блокировка сервера: мьютекс (Windows) или дескриптор файла
    с flock (Unix); 0 / -1 — не взята. }
  {$IFDEF WINDOWS}
  GMachine: THandle = 0;
  {$ELSE}
  GMachine: longint = -1;
  {$ENDIF}
  GElsewhere: boolean = False;

function InfoPath(const ADir, AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ADir) + AName + INSTANCE_INFO_EXT;
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

{ ---------------- сокеты ---------------- }

procedure SetTimeouts(ASock: longint);
{$IFDEF WINDOWS}
var
  Ms: DWORD;
begin
  Ms := INSTANCE_IO_TIMEOUT_MS;
  fpsetsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, @Ms, SizeOf(Ms));
  fpsetsockopt(ASock, SOL_SOCKET, SO_SNDTIMEO, @Ms, SizeOf(Ms));
end;
{$ELSE}
var
  Tv: TTimeVal;
begin
  Tv.tv_sec := INSTANCE_IO_TIMEOUT_MS div 1000;
  Tv.tv_usec := (INSTANCE_IO_TIMEOUT_MS mod 1000) * 1000;
  fpsetsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, @Tv, SizeOf(Tv));
  fpsetsockopt(ASock, SOL_SOCKET, SO_SNDTIMEO, @Tv, SizeOf(Tv));
end;
{$ENDIF}

function LoopbackAddr(APort: word): TInetSockAddr;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.sin_family := AF_INET;
  Result.sin_port := htons(APort);
  Result.sin_addr := StrToNetAddr('127.0.0.1');
end;

{ Строка до перевода строки (без него), не длиннее INSTANCE_MAX_LINE. }
function RecvLine(ASock: longint; out ALine: string): boolean;
var
  Buf: array[0..4095] of char;
  N, I: integer;
begin
  ALine := '';
  Result := False;
  repeat
    N := fprecv(ASock, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then begin
      Exit;
    end;
    for I := 0 to N - 1 do begin
      if Buf[I] = #10 then begin
        Result := True;
        Exit;
      end;
      ALine := ALine + Buf[I];
    end;
  until Length(ALine) > INSTANCE_MAX_LINE;
end;

procedure SendAll(ASock: longint; const S: string);
var
  P, N: integer;
begin
  P := 1;
  while P <= Length(S) do begin
    N := fpsend(ASock, @S[P], Length(S) - P + 1, 0);
    if N <= 0 then begin
      Exit;
    end;
    Inc(P, N);
  end;
end;

{ ---------------- сервер канала ---------------- }

procedure TControlThread.Execute;
var
  Conn: longint;
begin
  while not Terminated do begin
    Conn := fpaccept(FListen, nil, nil);
    if Terminated then begin
      if Conn >= 0 then begin
        CloseSocket(Conn);
      end;
      Break;
    end;
    if Conn < 0 then begin
      Continue;
    end;
    try
      Serve(Conn);
    finally
      CloseSocket(Conn);
    end;
  end;
end;

procedure TControlThread.RunOnMain;
begin
  FResult := nil;
  FError := '';
  try
    FResult := FHandler(FCmd, FArgs);
  except
    on E: Exception do begin
      FError := E.Message;
    end;
  end;
end;

procedure TControlThread.Serve(AConn: longint);
var
  Line: string;
  D: TJSONData;
  Reply: TJSONObject;
begin
  SetTimeouts(AConn);
  if not RecvLine(AConn, Line) then begin
    Exit;
  end;
  D := nil;
  Reply := TJSONObject.Create;
  try
    try
      D := GetJSON(Line);
    except
      D := nil;
    end;
    if not (D is TJSONObject) then begin
      Reply.Add('ok', False);
      Reply.Add('error', 'bad request');
    end else if not SameBytes(TJSONObject(D).Get('key', ''), GKey) then begin
      { Тот же ответ на любой неверный ключ; и без подсказок. }
      Reply.Add('ok', False);
      Reply.Add('error', 'forbidden');
    end else begin
      FCmd := TJSONObject(D).Get('cmd', '');
      if FCmd = 'kind' then begin
        { Вид программы — без главного потока: им проверяют, жив ли
          экземпляр, и ответ не должен ждать его занятости. }
        Reply.Add('ok', True);
        FResult := TJSONObject.Create;
        FResult.Add('kind', GKind);
        Reply.Add('result', FResult);
        FResult := nil;
        SendAll(AConn, Reply.AsJSON + #10);
        Exit;
      end;
      if TJSONObject(D).Find('args') is TJSONObject then begin
        FArgs := TJSONObject(TJSONObject(D).Find('args'));
      end else begin
        FArgs := nil;
      end;
      Synchronize(@RunOnMain);
      if FError <> '' then begin
        Reply.Add('ok', False);
        Reply.Add('error', FError);
        FreeAndNil(FResult);
      end else begin
        Reply.Add('ok', True);
        if FResult <> nil then begin
          Reply.Add('result', FResult);
          FResult := nil;
        end;
      end;
    end;
    SendAll(AConn, Reply.AsJSON + #10);
  finally
    Reply.Free;
    D.Free;
  end;
end;

{ ---------------- экземпляр ---------------- }

{ Машинная блокировка. Windows: мьютекс уже есть — ERROR_ALREADY_EXISTS;
  создан процессом ДРУГОГО пользователя — его права не пускают даже
  открыть: ERROR_ACCESS_DENIED. Оба — «занято». Держится, пока жив
  дескриптор: упал процесс — ОС закрыла его, мьютекс исчез. }
function AcquireMachine: boolean;
{$IFDEF WINDOWS}
var
  H: THandle;
  Name: UnicodeString;
begin
  Name := UnicodeString(INSTANCE_MACHINE_MUTEX);
  H := CreateMutexW(nil, False, PWideChar(Name));
  if H = 0 then begin
    Exit(False);                        { ERROR_ACCESS_DENIED и прочее — занято }
  end;
  if GetLastError = ERROR_ALREADY_EXISTS then begin
    CloseHandle(H);
    Exit(False);
  end;
  GMachine := H;
  Result := True;
end;
{$ELSE}
var
  Fd: longint;
begin
  Fd := fpOpen(INSTANCE_MACHINE_LOCK_FILE, O_RDONLY or O_CREAT, &644);
  if Fd < 0 then begin
    { Файл создан другим пользователем и не открывается — занято им. }
    Exit(False);
  end;
  if fpFlock(Fd, LOCK_EX or LOCK_NB) <> 0 then begin
    fpClose(Fd);
    Exit(False);
  end;
  { Создал — открыть всем на чтение: flock другого пользователя берётся
    и на дескрипторе только для чтения. }
  fpChmod(INSTANCE_MACHINE_LOCK_FILE, &644);
  GMachine := Fd;
  Result := True;
end;
{$ENDIF}

procedure ReleaseMachine;
begin
  {$IFDEF WINDOWS}
  if GMachine <> 0 then begin
    CloseHandle(GMachine);
    GMachine := 0;
  end;
  {$ELSE}
  if GMachine >= 0 then begin
    fpClose(GMachine);
    GMachine := -1;
  end;
  {$ENDIF}
end;

function InstanceElsewhere: boolean;
begin
  Result := GElsewhere;
end;

function AcquireInstance(const ADir, AName: string): boolean;
var
  Path: string;
  H: THandle;
begin
  GElsewhere := False;
  Path := IncludeTrailingPathDelimiter(ADir) + AName + INSTANCE_LOCK_EXT;
  if not FileExists(Path) then begin
    H := FileCreate(Path);
    if H <> THandle(-1) then begin
      FileClose(H);
    end;
  end;
  GLock := FileOpen(Path, fmOpenReadWrite or fmShareExclusive);
  Result := GLock <> THandle(-1);
  { Папка свободна, но сервер на машине уже есть — из другой копии или у
    другого пользователя: отпустить папку, второй не нужен. }
  if Result and (AName = INSTANCE_SERVER) and not AcquireMachine then begin
    FileClose(GLock);
    GLock := THandle(-1);
    GElsewhere := True;
    Result := False;
  end;
  if Result then begin
    GDir := ADir;
    GName := AName;
  end;
end;

procedure WriteInfo(const AKind: string);
var
  O: TJSONObject;
  S: TStringStream;
  Path: string;
begin
  Path := InfoPath(GDir, GName);
  O := TJSONObject.Create;
  S := nil;
  try
    O.Add('kind', AKind);
    O.Add('pid', Int64(GetProcessID));
    O.Add('port', GPort);
    O.Add('key', GKey);
    S := TStringStream.Create(O.AsJSON);
    { Сначала пустой файл с правами только владельца, потом содержимое:
      ключ ни мгновения не лежит в файле, открытом для чтения другим. }
    SysUtils.DeleteFile(Path);
    FileClose(FileCreate(Path));
    {$IFNDEF WINDOWS}
    fpChmod(Path, &600);
    {$ENDIF}
    S.SaveToFile(Path);
  finally
    S.Free;
    O.Free;
  end;
end;

procedure PublishInstance(const AKind: string; AHandler: TInstanceCommand);
var
  Sock: longint;
  Addr: TInetSockAddr;
  Len: TSockLen;
begin
  if (GLock = THandle(-1)) or (GThread <> nil) then begin
    Exit;
  end;
  Sock := fpsocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then begin
    Exit;
  end;
  Addr := LoopbackAddr(0);
  if (fpbind(Sock, @Addr, SizeOf(Addr)) <> 0) or (fplisten(Sock, 4) <> 0) then begin
    CloseSocket(Sock);
    Exit;
  end;
  Len := SizeOf(Addr);
  fpgetsockname(Sock, @Addr, @Len);
  GPort := NToHs(Addr.sin_port);
  GKey := HexOf(SecureRandomBytes(INSTANCE_KEY_BYTES));
  GKind := AKind;
  GThread := TControlThread.Create(True);
  GThread.FListen := Sock;
  GThread.FHandler := AHandler;
  GThread.FreeOnTerminate := False;
  GThread.Start;
  WriteInfo(AKind);
end;

procedure ReleaseInstance;
var
  Sock: longint;
  Addr: TInetSockAddr;
begin
  if GThread <> nil then begin
    { accept не прерывается флагом: разбудить его своим же соединением. }
    GThread.Terminate;
    Sock := fpsocket(AF_INET, SOCK_STREAM, 0);
    if Sock >= 0 then begin
      Addr := LoopbackAddr(GPort);
      fpconnect(Sock, @Addr, SizeOf(Addr));
      CloseSocket(Sock);
    end;
    GThread.WaitFor;
    CloseSocket(GThread.FListen);
    FreeAndNil(GThread);
    SysUtils.DeleteFile(InfoPath(GDir, GName));
  end;
  if GLock <> THandle(-1) then begin
    FileClose(GLock);
    GLock := THandle(-1);
  end;
  ReleaseMachine;
end;

{ ---------------- клиент канала ---------------- }

function ReadInfo(const ADir, AName: string; out APort: word; out AKey, AKind: string): boolean;
var
  S: TStringStream;
  D: TJSONData;
  Tries: integer;
begin
  Result := False;
  APort := 0;
  AKey := '';
  AKind := '';
  { Только что запущенный экземпляр мог ещё не записать файл. }
  for Tries := 1 to INSTANCE_INFO_WAIT_TRIES do begin
    if FileExists(InfoPath(ADir, AName)) then begin
      D := nil;
      S := TStringStream.Create('');
      try
        try
          S.LoadFromFile(InfoPath(ADir, AName));
          D := GetJSON(S.DataString);
        except
          D := nil;
        end;
        if D is TJSONObject then begin
          APort := TJSONObject(D).Get('port', 0);
          AKey := TJSONObject(D).Get('key', '');
          AKind := TJSONObject(D).Get('kind', '');
          Result := (APort > 0) and (AKey <> '');
        end;
      finally
        D.Free;
        S.Free;
      end;
      if Result then begin
        Exit;
      end;
    end;
    Sleep(INSTANCE_INFO_WAIT_MS);
  end;
end;

function CallInstance(const ADir, AName, ACmd: string; AArgs: TJSONObject;
  out AResult: TJSONObject; out AError: string): boolean;
var
  Port: word;
  Key, Kind, Line: string;
  Sock: longint;
  Addr: TInetSockAddr;
  Req: TJSONObject;
  D: TJSONData;
begin
  Result := False;
  AResult := nil;
  AError := '';
  if not ReadInfo(ADir, AName, Port, Key, Kind) then begin
    AError := 'The running copy did not say how to reach it';
    Exit;
  end;
  Sock := fpsocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then begin
    AError := 'No socket';
    Exit;
  end;
  try
    SetTimeouts(Sock);
    Addr := LoopbackAddr(Port);
    if fpconnect(Sock, @Addr, SizeOf(Addr)) <> 0 then begin
      AError := 'The running copy does not answer';
      Exit;
    end;
    Req := TJSONObject.Create;
    try
      Req.Add('key', Key);
      Req.Add('cmd', ACmd);
      if AArgs <> nil then begin
        Req.Add('args', AArgs.Clone);
      end;
      SendAll(Sock, Req.AsJSON + #10);
    finally
      Req.Free;
    end;
    if not RecvLine(Sock, Line) then begin
      AError := 'The running copy did not answer';
      Exit;
    end;
    D := nil;
    try
      D := GetJSON(Line);
    except
      D := nil;
    end;
    try
      if not (D is TJSONObject) then begin
        AError := 'Bad answer';
        Exit;
      end;
      Result := TJSONObject(D).Get('ok', False);
      if Result then begin
        if TJSONObject(D).Find('result') is TJSONObject then begin
          AResult := TJSONObject(TJSONObject(D).Extract('result'));
        end;
      end else begin
        AError := TJSONObject(D).Get('error', 'failed');
      end;
    finally
      D.Free;
    end;
  finally
    CloseSocket(Sock);
  end;
end;

function InstanceKind(const ADir, AName: string): string;
var
  R: TJSONObject;
  Err: string;
begin
  Result := '';
  if CallInstance(ADir, AName, 'kind', nil, R, Err) then begin
    if R <> nil then begin
      Result := R.Get('kind', '');
    end;
    R.Free;
  end;
end;

finalization
  ReleaseInstance;
end.
