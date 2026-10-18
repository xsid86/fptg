unit appdirs;

{$mode objfpc}{$H+}

{ The programs' data folders — in the user profile, not next to the exe
  (2026-10-16): the program can be installed into Program Files, which is
  not writable, and the data of each Windows user — their Telegram
  sessions — must be closed to other users of the same machine. The
  profile is closed by the OS's own permissions; a shared folder
  (ProgramData) is not: its subfolders are readable by everyone by default.

  Windows: %LOCALAPPDATA%\fptg\<program>\ — Local, not Roaming: Roaming
  holds what synchronises with roaming profiles, and tdlib\ is gigabytes.
  Unix: $XDG_DATA_HOME/fptg/<program>/ or ~/.local/share/fptg/<program>/.

  No profile found (no environment variables — a service without a
  profile) — the program folder, as before. }

interface

{ Server: tdlib/, conf.dat, uploads/, tdlib_raw.log, the lock and the
  control channel (instance.pas). With a trailing separator, created. }
function ServerDataDir: string;

{ The client window: conf.dat, the lock and the control channel. }
function ClientDataDir: string;

implementation

uses
  SysUtils, constants;

function ProfileRoot: string;
begin
  {$IFDEF WINDOWS}
  Result := GetEnvironmentVariable('LOCALAPPDATA');
  {$ELSE}
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if (Result = '') and (GetEnvironmentVariable('HOME') <> '') then begin
    Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.local'
      + PathDelim + 'share';
  end;
  {$ENDIF}
end;

function DataDirFor(const AProgram: string): string;
var
  Root: string;
begin
  Root := ProfileRoot;
  if Root = '' then begin
    Exit(ExtractFilePath(ParamStr(0)));
  end;
  Result := IncludeTrailingPathDelimiter(Root) + APP_DATA_ROOT + PathDelim
    + AProgram + PathDelim;
  if not ForceDirectories(Result) then begin
    Result := ExtractFilePath(ParamStr(0));
  end;
end;

function ServerDataDir: string;
begin
  Result := DataDirFor(APP_DATA_SERVER);
end;

function ClientDataDir: string;
begin
  Result := DataDirFor(APP_DATA_CLIENT);
end;

end.
