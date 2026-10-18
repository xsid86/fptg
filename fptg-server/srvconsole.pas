unit srvconsole;

{$mode objfpc}{$H+}

{ The server console: user name and password (without echo) — for
  --set-user and for the user on the first start; clearing the screen so
  connection details do not stay in view. }

interface

{ Whether a person sits at the program: standard input is a console, not
  a file, a pipe or a service. }
function ConsoleInteractive: boolean;
function ReadLineVisible(const APrompt: string): string;
{ A password: what is typed is not shown. }
function ReadLineSecret(const APrompt: string): string;
{ Clear the screen together with the scrollback. }
procedure ClearConsole;
{ On Enter clear the screen and leave ALine. Waits on its own thread — the
  main thread runs the server's event loop and must not stop. }
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
  { ESC[2J — the screen, ESC[3J — the scrollback, ESC[H — the cursor to the
    corner. Unix terminals and Windows Terminal understand them; the old
    Windows console — after ENABLE_VIRTUAL_TERMINAL_PROCESSING, and in case
    that fails, the buffer is also cleared through the console API below. }
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
  { Ctrl+C interrupts ReadLn too: then a stop is under way, and there is
    no point erasing its messages. The Ctrl+C handler sets a flag on its
    own thread — give it a moment. }
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
  { Not waited for on exit: on Ctrl+C it hangs in ReadLn, and the process
    closes without it. }
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
