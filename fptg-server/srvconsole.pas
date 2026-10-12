unit srvconsole;

{$mode objfpc}{$H+}

{ Консоль сервера: имя пользователя и пароль (без эха) — для
  --set-user и для пользователя при первом запуске; очистка
  экрана, чтобы данные подключения не оставались на виду. }

interface

{ Сидит ли за программой человек: стандартный ввод — консоль, а не
  файл, канал или служба. }
function ConsoleInteractive: boolean;
function ReadLineVisible(const APrompt: string): string;
{ Пароль: набираемое не показывается. }
function ReadLineSecret(const APrompt: string): string;
{ Стереть экран вместе с прокруткой назад. }
procedure ClearConsole;
{ По Enter стереть экран и оставить ALine. Ждёт в своём потоке —
  главный поток крутит цикл событий сервера и вставать не должен. }
procedure ClearConsoleOnEnter(const ALine: string);

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ELSE}
  BaseUnix, TermIO,
  {$ENDIF}
  Classes, SysUtils, srvloop;

const
  { ESC[2J — экран, ESC[3J — прокрутка назад, ESC[H — курсор в угол.
    Понимают терминалы Unix и Windows Terminal; старая консоль Windows —
    после ENABLE_VIRTUAL_TERMINAL_PROCESSING, а на случай отказа ниже ещё
    и чистка буфера через API консоли. }
  CLEAR_SEQUENCE = #27'[2J'#27'[3J'#27'[H';

type
  TEnterWaiter = class(TThread)
  private
    FLine: string;
  protected
    procedure Execute; override;
  end;

function ConsoleInteractive: boolean;
{$IFDEF WINDOWS}
var
  Mode: DWORD;
begin
  Result := GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), @Mode);
end;
{$ELSE}
begin
  Result := IsATTY(0) = 1;
end;
{$ENDIF}

procedure ClearConsole;
{$IFDEF WINDOWS}
const
  ENABLE_VIRTUAL_TERMINAL_PROCESSING_ = $0004;
var
  H: THandle;
  Mode: DWORD;
  Info: TConsoleScreenBufferInfo;
  Origin: TCoord;
  Cells, Written: DWORD;
begin
  H := GetStdHandle(STD_OUTPUT_HANDLE);
  if GetConsoleMode(H, Mode) then begin
    SetConsoleMode(H, Mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING_);
  end;
  Write(CLEAR_SEQUENCE);
  Flush(Output);
  if GetConsoleScreenBufferInfo(H, Info) then begin
    Origin.X := 0;
    Origin.Y := 0;
    Cells := DWORD(Info.dwSize.X) * DWORD(Info.dwSize.Y);
    FillConsoleOutputCharacter(H, ' ', Cells, Origin, Written);
    FillConsoleOutputAttribute(H, Info.wAttributes, Cells, Origin, Written);
    SetConsoleCursorPosition(H, Origin);
  end;
end;
{$ELSE}
begin
  Write(CLEAR_SEQUENCE);
  Flush(Output);
end;
{$ENDIF}

procedure TEnterWaiter.Execute;
var
  S: string;
begin
  ReadLn(S);
  { Ctrl+C тоже прерывает ReadLn: тогда идёт остановка, и стирать её
    сообщения незачем. Обработчик Ctrl+C ставит флаг в своём потоке —
    дать ему мгновение. }
  Sleep(200);
  if StopRequested then begin
    Exit;
  end;
  ClearConsole;
  WriteLn(FLine);
end;

procedure ClearConsoleOnEnter(const ALine: string);
var
  T: TEnterWaiter;
begin
  T := TEnterWaiter.Create(True);
  T.FLine := ALine;
  { Не ждём его при выходе: по Ctrl+C он так и висит в ReadLn, процесс
    закрывается и без него. }
  T.FreeOnTerminate := True;
  T.Start;
end;

function ReadLineVisible(const APrompt: string): string;
begin
  Write(APrompt);
  ReadLn(Result);
  Result := Trim(Result);
end;

function ReadLineSecret(const APrompt: string): string;
{$IFDEF WINDOWS}
var
  H: THandle;
  Mode: DWORD;
begin
  Write(APrompt);
  H := GetStdHandle(STD_INPUT_HANDLE);
  if GetConsoleMode(H, @Mode) then begin
    SetConsoleMode(H, Mode and not ENABLE_ECHO_INPUT);
    try
      ReadLn(Result);
    finally
      SetConsoleMode(H, Mode);
    end;
  end else begin
    ReadLn(Result);
  end;
  WriteLn;
end;
{$ELSE}
var
  Old, T: Termios;
  Ok: boolean;
begin
  Write(APrompt);
  Ok := TCGetAttr(0, Old) = 0;
  if Ok then begin
    T := Old;
    T.c_lflag := T.c_lflag and not ECHO;
    TCSetAttr(0, TCSANOW, T);
  end;
  try
    ReadLn(Result);
  finally
    if Ok then begin
      TCSetAttr(0, TCSANOW, Old);
    end;
  end;
  WriteLn;
end;
{$ENDIF}

end.
