unit autodownload;

{ The "Auto download" settings grid, and nothing else.

  It used to live on TFormMain, which put it out of reach of the web
  server: webapi.pas sits below the UI and must not use main.pas. So
  the page ignored the settings altogether and made every file a click,
  while the native window downloaded whatever the grid allowed - the
  same account and the same messages, answered two different ways
  depending on which window you were looking at.

  Values come from config.ini/[autodownload], keys "media.chat" built
  out of AUTODL_MEDIA_KINDS/AUTODL_CHAT_KINDS. Cached rather than read
  per message: both sides ask this question once per row, which is
  several hundred times a scroll. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ True when this kind of media downloads by itself in this kind of
  chat. The kinds are the strings in AUTODL_MEDIA_KINDS and
  AUTODL_CHAT_KINDS (constants.pas); anything else answers False. }
function AutoDownloadEnabled(const AMediaKind, AChatKind: string): boolean;

{ Re-reads config.ini. Called after the settings window has written it;
  nothing needs to call it at startup, because the first query loads
  the grid itself. }
procedure ReloadAutoDownload;

{ Меняет одну клетку: пишет в config.ini и сразу в кэш, так что
  следующий же вопрос AutoDownloadEnabled получает новый ответ.
  Неизвестный вид медиа или чата — исключение: страница прислала
  то, чего этот билд не знает, и молча проглотить это нельзя. }
procedure SetAutoDownloadEnabled(const AMediaKind, AChatKind: string;
  AValue: boolean);

{ Which column of the grid a chat falls in - 'private', 'bots',
  'secret', 'groups' or 'channels' - or '' when the chat is not in the
  list yet. A caller with no kind downloads nothing, the same as the
  native side (TMsgScroller.CurrentChatKind). }
function AutoDownloadChatKind(AChatId: Int64): string;

implementation

uses
  IniFiles, constants, tdcore, tdchats, secureconfig;

var
  GGrid: array[0..High(AUTODL_MEDIA_KINDS)] of
         array[0..High(AUTODL_CHAT_KINDS)] of boolean;
  GLoaded: boolean = False;

function MediaIndex(const AKind: string): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(AUTODL_MEDIA_KINDS) do begin
    if AUTODL_MEDIA_KINDS[I] = AKind then begin
      Result := I;
      Exit;
    end;
  end;
end;

function ChatIndex(const AKind: string): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(AUTODL_CHAT_KINDS) do begin
    if AUTODL_CHAT_KINDS[I] = AKind then begin
      Result := I;
      Exit;
    end;
  end;
end;

procedure Load;
var
  Ini: TIniFile;
  M, C: integer;
begin
  { Before TdApp exists there is no base directory to read from. Left
    UNLOADED rather than loaded empty, so the next query tries again
    instead of caching "everything off" for the rest of the run. }
  if TdApp = nil then begin
    Exit;
  end;
  Ini := OpenConfig;
  try
    for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
      for C := 0 to High(AUTODL_CHAT_KINDS) do begin
        GGrid[M][C] := Ini.ReadBool('autodownload',
          AUTODL_MEDIA_KINDS[M] + '.' + AUTODL_CHAT_KINDS[C], False);
      end;
    end;
  finally
    Ini.Free;
  end;
  GLoaded := True;
end;

procedure ReloadAutoDownload;
begin
  Load;
end;

procedure SetAutoDownloadEnabled(const AMediaKind, AChatKind: string;
  AValue: boolean);
var
  M, C: integer;
  Ini: TIniFile;
begin
  M := MediaIndex(AMediaKind);
  C := ChatIndex(AChatKind);
  if (M < 0) or (C < 0) then begin
    raise Exception.CreateFmt('unknown auto-download cell: %s.%s',
      [AMediaKind, AChatKind]);
  end;
  Ini := OpenConfig;
  try
    Ini.WriteBool('autodownload', AUTODL_MEDIA_KINDS[M] + '.' +
      AUTODL_CHAT_KINDS[C], AValue);
  finally
    Ini.Free;
  end;
  { Остальные клетки — из файла: их мог поменять нативный диалог. }
  Load;
end;

function AutoDownloadEnabled(const AMediaKind, AChatKind: string): boolean;
var
  M, C: integer;
begin
  Result := False;
  if not GLoaded then begin
    Load;
  end;
  M := MediaIndex(AMediaKind);
  C := ChatIndex(AChatKind);
  if (M < 0) or (C < 0) then begin
    Exit;
  end;
  Result := GGrid[M][C];
end;

function AutoDownloadChatKind(AChatId: Int64): string;
var
  Row: TChatRow;
begin
  Result := '';
  if (TdChatList = nil) or (AChatId = 0) then begin
    Exit;
  end;
  Row := TdChatList.Lookup(AChatId);
  if Row = nil then begin
    Exit;
  end;
  case Row.Kind of
    ckPrivate:
      if TdChatList.IsBotChat(Row) then begin
        Result := 'bots';
      end else begin
        Result := 'private';
      end;
    ckSecret:
      Result := 'secret';
    ckBasicGroup, ckSupergroup:
      Result := 'groups';
    ckChannel:
      Result := 'channels';
  end;
end;

end.
