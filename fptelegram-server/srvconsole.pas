unit srvconsole;

{$mode objfpc}{$H+}

{ Ввод в консоли сервера: имя пользователя и пароль (без эха) — для
  --add-user и для первого пользователя при первом запуске. }

interface

{ Сидит ли за программой человек: стандартный ввод — консоль, а не
  файл, канал или служба. }
function ConsoleInteractive: boolean;
function ReadLineVisible(const APrompt: string): string;
{ Пароль: набираемое не показывается. }
function ReadLineSecret(const APrompt: string): string;

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ELSE}
  BaseUnix, TermIO,
  {$ENDIF}
  SysUtils;

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
