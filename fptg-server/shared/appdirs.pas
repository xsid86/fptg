unit appdirs;

{$mode objfpc}{$H+}

{ Папки данных программ — в профиле пользователя, не рядом с exe
  (2026-10-16): программа ставится и в Program Files, куда не пишут, а
  данные каждого пользователя Windows — его сеансы Telegram — должны
  быть закрыты от других пользователей той же машины. Профиль закрыт
  правами самой ОС; общая папка (ProgramData) — нет: её подпапки по
  умолчанию читают все.

  Windows: %LOCALAPPDATA%\fptg\<программа>\ — Local, а не Roaming: в
  Roaming лежит то, что синхронизируется при перемещаемых профилях, а
  tdlib\ — это гигабайты. Unix: $XDG_DATA_HOME/fptg/<программа>/ или
  ~/.local/share/fptg/<программа>/.

  Не нашлось профиля (нет переменных окружения — служба без профиля) —
  папка программы, как было раньше. }

interface

{ Сервер: tdlib/, conf.dat, uploads/, tdlib_raw.log, блокировка и канал
  управления (instance.pas). С разделителем на конце, создана. }
function ServerDataDir: string;

{ Окно клиента: conf.dat, блокировка и канал управления. }
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
