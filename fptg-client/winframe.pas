unit winframe;

{$mode objfpc}{$H+}

{ Рамка окон в цвет темы страницы — родная рамка Windows, перекрашенная
  через DWM (DwmSetWindowAttribute), а не своя: тень, скругления, Snap,
  системное меню и кнопки остаются системными.

  Цвета решает страница (ui/theme.js -> shell, сообщение frame:
  caption, text, border — '#rrggbb', dark); окно только исполняет и
  помнит последние в conf.dat (guiconn), чтобы красить рамку ещё до
  загрузки страницы.

  Окна приложения — главное, мини-приложения, их диалоги, окошко звонка
  — подключаются FrameAttach и красятся все разом: новые цвета от
  страницы доходят и до уже открытых. FrameDetach — до уничтожения окна.

  Windows 11 (22000+): заголовок, текст и кайма — цветом. Windows 10
  20H1+: только тёмный/светлый заголовок. Раньше — ничего, вызов просто
  откажет. На другой платформе — своя оболочка. }

interface

uses
  Windows, SysUtils, fpjson;

{ Окно приложения: покрасить текущими цветами и красить при смене. }
procedure FrameAttach(AWnd: HWND);
procedure FrameDetach(AWnd: HWND);
{ Сообщение страницы: перекрасить все окна и запомнить, если цвета
  новые. }
procedure FrameFromPage(AMsg: TJSONObject);

implementation

uses
  jsonparser, dwmapi, guiconst, guiconn;

var
  { Текущие цвета — JSON (FrameKey), '' — ещё не было. }
  GCurrent: string = '';
  GCurrentRead: boolean = False;
  GWindows: array of HWND;

{ '#rrggbb' -> COLORREF ($00BBGGRR). Иное — системный цвет. }
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
  { BOOL — 4 байта: 1 / 0. }
  SetAttr(AWnd, FRAME_ATTR_DARK_MODE, DWORD(Ord(AMsg.Get('dark', False))));
  SetAttr(AWnd, FRAME_ATTR_CAPTION, CssColor(AMsg.Get('caption', '')));
  SetAttr(AWnd, FRAME_ATTR_TEXT, CssColor(AMsg.Get('text', '')));
  SetAttr(AWnd, FRAME_ATTR_BORDER, CssColor(AMsg.Get('border', '')));
end;

{ Только цвета — без поля t и в одном порядке: по этой строке решается,
  писать ли conf.dat. }
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

{ Текущие цвета -> окно. }
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
    { Окно могли уничтожить, не сняв с учёта (смена Handle у LCL). }
    if IsWindow(GWindows[I]) then begin
      ApplyTo(GWindows[I], AMsg);
    end;
  end;
  EnsureCurrent;
  { Страница шлёт цвета при каждой загрузке — conf.dat трогать, только
    когда они поменялись. }
  Key := FrameKey(AMsg);
  if Key <> GCurrent then begin
    GCurrent := Key;
    SaveWindowFrame(Key);
  end;
end;

end.
