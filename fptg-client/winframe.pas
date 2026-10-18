unit winframe;

{$mode objfpc}{$H+}

{ Window frames in the page's theme colour — the native Windows frame,
  recoloured through DWM (DwmSetWindowAttribute), not our own: shadow,
  rounding, Snap, the system menu and buttons stay native.

  The page decides the colours (ui/theme.js -> shell, a frame message:
  caption, text, border — '#rrggbb', dark); the window only carries them
  out and remembers the last ones in conf.dat (guiconn), so the frame is
  painted before the page loads.

  The application's windows — the main one, mini apps, their dialogs, the
  call pop-up — are attached with FrameAttach and painted all at once: new
  colours from the page reach the windows already open too. FrameDetach —
  before the window is destroyed.

  Windows 11 (22000+): the caption, text and border — in colour. Windows
  10 20H1+: only a dark/light caption. Earlier — nothing, the call simply
  refuses. On another platform — its own shell. }

interface

uses
  Windows, SysUtils, fpjson;

{ An application window: paint it with the current colours and on every change. }
procedure FrameAttach(AWnd: HWND);
procedure FrameDetach(AWnd: HWND);
{ A message from the page: repaint all windows and remember the colours if
  they are new. }
procedure FrameFromPage(AMsg: TJSONObject);

implementation

uses
  jsonparser, dwmapi, guiconst, guiconn;

var
  { The current colours — JSON (FrameKey), '' — none yet. }
  GCurrent: string = '';
  GCurrentRead: boolean = False;
  GWindows: array of HWND;

{ '#rrggbb' -> COLORREF ($00BBGGRR). Anything else — the system colour. }
function CssColor(const S: string): DWORD;
var
  V: integer;
begin
  Result := FRAME_COLOR_DEFAULT;
  if (Length(S) <> 7) or (S[1] <> '#') or not TryStrToInt('$' + Copy(S, 2, 6), V) then begin
    Exit;
  end;
  Result := DWORD(((V shr 16) and $FF) or (V and $FF00) or ((V and $FF) shl 16));
end;

procedure SetAttr(AWnd: HWND; AAttr, AValue: DWORD);
begin
  DwmSetWindowAttribute(AWnd, AAttr, @AValue, SizeOf(AValue));
end;

procedure ApplyTo(AWnd: HWND; AMsg: TJSONObject);
begin
  if (AWnd = 0) or (AMsg = nil) or not InitDwmLibrary
     or not Assigned(DwmSetWindowAttribute) then begin
    Exit;
  end;
  { BOOL — 4 bytes: 1 / 0. }
  SetAttr(AWnd, FRAME_ATTR_DARK_MODE, DWORD(Ord(AMsg.Get('dark', False))));
  SetAttr(AWnd, FRAME_ATTR_CAPTION, CssColor(AMsg.Get('caption', '')));
  SetAttr(AWnd, FRAME_ATTR_TEXT, CssColor(AMsg.Get('text', '')));
  SetAttr(AWnd, FRAME_ATTR_BORDER, CssColor(AMsg.Get('border', '')));
end;

{ Only the colours — without the t field and in one order: this string
  decides whether to write conf.dat. }
function FrameKey(AMsg: TJSONObject): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('caption', AMsg.Get('caption', ''));
    O.Add('text', AMsg.Get('text', ''));
    O.Add('border', AMsg.Get('border', ''));
    O.Add('dark', AMsg.Get('dark', False));
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

procedure EnsureCurrent;
begin
  if not GCurrentRead then begin
    GCurrent := LoadWindowFrame;
    GCurrentRead := True;
  end;
end;

{ The current colours -> the window. }
procedure ApplyCurrent(AWnd: HWND);
var
  Data: TJSONData;
begin
  EnsureCurrent;
  if GCurrent = '' then begin
    Exit;
  end;
  try
    Data := GetJSON(GCurrent);
  except
    Exit;
  end;
  try
    if Data is TJSONObject then begin
      ApplyTo(AWnd, TJSONObject(Data));
    end;
  finally
    Data.Free;
  end;
end;

procedure FrameAttach(AWnd: HWND);
var
  I: integer;
begin
  if AWnd = 0 then begin
    Exit;
  end;
  for I := 0 to High(GWindows) do begin
    if GWindows[I] = AWnd then begin
      ApplyCurrent(AWnd);
      Exit;
    end;
  end;
  SetLength(GWindows, Length(GWindows) + 1);
  GWindows[High(GWindows)] := AWnd;
  ApplyCurrent(AWnd);
end;

procedure FrameDetach(AWnd: HWND);
var
  I, J: integer;
begin
  for I := 0 to High(GWindows) do begin
    if GWindows[I] = AWnd then begin
      for J := I to High(GWindows) - 1 do begin
        GWindows[J] := GWindows[J + 1];
      end;
      SetLength(GWindows, Length(GWindows) - 1);
      Exit;
    end;
  end;
end;

procedure FrameFromPage(AMsg: TJSONObject);
var
  Key: string;
  I: integer;
begin
  for I := 0 to High(GWindows) do begin
    { The window may have been destroyed without being unregistered (LCL changing Handle). }
    if IsWindow(GWindows[I]) then begin
      ApplyTo(GWindows[I], AMsg);
    end;
  end;
  EnsureCurrent;
  { The page sends colours on every load — touch conf.dat only when they
    changed. }
  Key := FrameKey(AMsg);
  if Key <> GCurrent then begin
    GCurrent := Key;
    SaveWindowFrame(Key);
  end;
end;

end.
