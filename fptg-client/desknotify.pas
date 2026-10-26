unit desknotify;

{$mode objfpc}{$H+}{$codepage utf8}

{ Desktop notifications — as in Telegram Desktop: our own cards in the
  bottom right corner of the work area, stacked above the taskbar, rather
  than a Windows toast or a card inside the window.

  Each card is a separate WS_EX_LAYERED window, drawn entirely in
  BGRABitmap and put out with UpdateLayeredWindow: no frame, no flicker on
  redraw, and transparency (fading in, fading out) and shifting the stack
  change without redrawing the content. The windows are our own, plain
  Win32, not LCL forms: LCL shows a form through ShowWindow(SW_SHOWNORMAL)
  (win32wsforms.pp, ShowHide), and that activates the window and takes
  focus from whoever is typing. Here — SW_SHOWNOACTIVATE when showing and
  MA_NOACTIVATE on a click.

  Everything on the main thread: the windows are created on it, and the
  ordinary Application loop handles their messages. }

interface

type
  TDeskNotifyClick = procedure(AChatId: Int64) of object;

{ Shows a card. If the chat already has a card, it is updated, moves to
  the bottom of the stack as the freshest and lives anew — no second one
  appears. APhoto and AThumb — the picture's bytes (the chat photo and the
  blurred thumbnail); empty — initials on a coloured circle. }
procedure ShowDeskNotify(AChatId: Int64; const ATitle, AText: utf8string;
  const APhoto, AThumb: RawByteString);

{ The screen corner — an index in DESKNOTIFY_CORNERS. Cards already shown
  move there at once, without animation. }
procedure SetDeskNotifyCorner(AIndex: integer);
{ The current corner — the call pop-up goes there too (callpopup.pas). }
function DeskNotifyCorner: integer;
{ How many cards at once. The extra oldest ones start fading right away. }
procedure SetDeskNotifyLimit(ACount: integer);
{ Font size of the title and the text (at 96 dpi). Cards on screen are
  redrawn at once. }
procedure SetDeskNotifyFonts(ATitle, AText: integer);
{ The colours of the app's theme ('#rrggbb' each, the page's frame
  message): the card, its edging, the title and the text. Cards on screen
  are redrawn at once. Until the first call (or with a colour that is not
  '#rrggbb') the cards follow the Windows light or dark theme. }
procedure SetDeskNotifyColors(const ABg, ABorder, ATitle, AText: string);
{ The chat is read: its card fades out (the page's notifyClear). }
procedure CloseDeskNotify(AChatId: Int64);
{ A sample for the settings: as many cards as fit at once — both the
  corner and the stack height are visible right away. The previous sample
  goes at once, without fading. A click on a sample comes to
  DeskNotifyOnClick with AChatId = 0. }
procedure ShowDeskNotifySamples(const ATitle, AText: utf8string);

var
  { A click on a card outside the cross. The card itself closes after it. }
  DeskNotifyOnClick: TDeskNotifyClick = nil;

implementation

uses
  Windows, Classes, SysUtils, Math, Graphics, Forms, ExtCtrls, Registry,
  LazUTF8, BGRABitmap, BGRABitmapTypes, constants, guiconst, avatarcache;

{ The Windows unit of FPC 3.2.2 lacks this function (it is only in
  jwawinuser). Pointer parameters — as in WinUser.h. }
function UpdateLayeredWindow(hWnd: HWND; hdcDst: HDC; pptDst: PPoint;
  psize: PSize; hdcSrc: HDC; pptSrc: PPoint; crKey: COLORREF;
  pblend: PBlendFunction; dwFlags: DWORD): BOOL; stdcall;
  external 'user32' name 'UpdateLayeredWindow';

type
  TCard = class
  public
    Wnd: HWND;
    ChatId: Int64;
    Title: utf8string;
    Text: utf8string;
    Avatar: TBGRABitmap;
    Dark: boolean;
    X: integer;
    Width: integer;
    Height: integer;
    Y: double;
    TargetY: double;
    Alpha: double;          { 0..255 }
    LifeLeft: integer;      { ms until fading starts }
    { The mouse moved during the current display cycle. If it did not, the
      person is most likely away from the screen: at the end of the cycle
      the card does not fade but waits (Waiting) for the first movement and
      starts the cycle anew. }
    Moved: boolean;
    Waiting: boolean;
    Closing: boolean;
    { A sample from the settings: its ChatId is 0, and it is not merged by
      chat — there are several samples in the stack. }
    Sample: boolean;
    Hover: boolean;
    HoverClose: boolean;
    Tracking: boolean;      { TrackMouseEvent is armed already }
    { What last went into the window: Place does not touch it needlessly. }
    ShownX, ShownY, ShownAlpha: integer;
    destructor Destroy; override;
    function CloseRect: TRect;
    procedure Paint;
    procedure Place;
  end;

  { TTimer asks for a method, not a procedure. }
  TTicker = class
    procedure Tick(Sender: TObject);
  end;

var
  GCards: TFPList = nil;
  GTimer: TTimer = nil;
  GTicker: TTicker = nil;
  GLastTick: QWord = 0;
  GClassDone: boolean = False;
  GCorner: integer = DESKNOTIFY_CORNER_DEFAULT;
  GLimit: integer = DESKNOTIFY_LIMIT_DEFAULT;
  GTitleFont: integer = DESKNOTIFY_TITLE_FONT_DEFAULT;
  GTextFont: integer = DESKNOTIFY_TEXT_FONT_DEFAULT;
  { The app's theme (SetDeskNotifyColors); GThemed false — the system's. }
  GThemed: boolean = False;
  GThemeBg, GThemeBorder, GThemeTitle, GThemeText: TColor;
  GCursor: TPoint;
  GCursorKnown: boolean = False;

function Sc(AValue: integer): integer;
begin
  Result := MulDiv(AValue, Screen.PixelsPerInch, 96);
end;

function Card(AIndex: integer): TCard;
begin
  Result := TCard(GCards[AIndex]);
end;

{ The Windows theme for apps — the one in "Settings → Personalization →
  Colors". No key (an old system) — light. }
function SystemIsDark: boolean;
var
  R: TRegistry;
begin
  Result := False;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(DESKNOTIFY_THEME_KEY)
      and R.ValueExists(DESKNOTIFY_THEME_VALUE) then begin
      Result := R.ReadInteger(DESKNOTIFY_THEME_VALUE) = 0;
    end;
  except
    Result := False;
  end;
  R.Free;
end;

{ One line: line feeds into spaces and cut with a margin — Fit then makes
  it fit the width, and it has no reason to measure a megabyte. }
function OneLine(const AText: utf8string): utf8string;
begin
  Result := StringReplace(AText, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  if UTF8Length(Result) > DESKNOTIFY_TEXT_MAX then begin
    Result := UTF8Copy(Result, 1, DESKNOTIFY_TEXT_MAX);
  end;
end;

{ Text into the width AWidth, with an ellipsis if it does not fit. By UTF-8
  characters, not bytes: otherwise it would cut in the middle of a
  non-Latin character. }
function Fit(ABmp: TBGRABitmap; const AText: utf8string; AWidth: integer): utf8string;
var
  N: PtrInt;
begin
  Result := AText;
  if ABmp.TextSize(Result).cx <= AWidth then begin
    Exit;
  end;
  N := UTF8Length(AText);
  while N > 0 do begin
    Dec(N);
    Result := UTF8Copy(AText, 1, N);
    while (Result <> '') and (Result[Length(Result)] = ' ') do begin
      SetLength(Result, Length(Result) - 1);
    end;
    Result := Result + DESKNOTIFY_ELLIPSIS;
    if ABmp.TextSize(Result).cx <= AWidth then begin
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------- }

destructor TCard.Destroy;
begin
  if Wnd <> 0 then begin
    SetWindowLongPtrW(Wnd, GWLP_USERDATA, 0);
    DestroyWindow(Wnd);
  end;
  Avatar.Free;
  inherited Destroy;
end;

{ The click zone of the cross is bigger than the drawn cross: a ten-pixel
  target is hard to hit with a mouse. }
function TCard.CloseRect: TRect;
var
  Z: integer;
begin
  Z := Sc(DESKNOTIFY_CLOSE_ZONE);
  Result := Rect(Width - Z, 0, Width, Z);
end;

{ The whole content: background, border, avatar, title, text, cross. Only
  when the content or the hover changes — movement and transparency go
  through Place. }
procedure TCard.Paint;
var
  B: TBGRABitmap;
  Bg, Border, Fg, Sub, Cross: TBGRAPixel;
  Pad, Av, Tx, TextW, Half, Cx, Cy, Row, TitleH, TextH, Top: integer;
  Src, Dst: PBGRAPixel;
  Info: TBitmapInfo;
  Bits: Pointer;
  Dib, Old: HBITMAP;
  Mem: HDC;
  Pt, SrcPt: TPoint;
  Sz: TSize;
  Blend: TBlendFunction;
  I: integer;
  A: byte;
begin
  if GThemed then begin
    Bg := ColorToBGRA(GThemeBg);
    Border := ColorToBGRA(GThemeBorder);
    Fg := ColorToBGRA(GThemeTitle);
    Sub := ColorToBGRA(GThemeText);
  end else if Dark then begin
    Bg := ColorToBGRA(DESKNOTIFY_DARK_BG);
    Border := ColorToBGRA(DESKNOTIFY_DARK_BORDER);
    Fg := ColorToBGRA(DESKNOTIFY_DARK_TITLE);
    Sub := ColorToBGRA(DESKNOTIFY_DARK_TEXT);
  end else begin
    Bg := ColorToBGRA(DESKNOTIFY_LIGHT_BG);
    Border := ColorToBGRA(DESKNOTIFY_LIGHT_BORDER);
    Fg := ColorToBGRA(DESKNOTIFY_LIGHT_TITLE);
    Sub := ColorToBGRA(DESKNOTIFY_LIGHT_TEXT);
  end;
  if HoverClose then begin
    Cross := Fg;
  end else begin
    Cross := Sub;
    Cross.alpha := DESKNOTIFY_CLOSE_ALPHA;
  end;

  B := TBGRABitmap.Create(Width, Height, Bg);
  try
    B.Rectangle(0, 0, Width, Height, Border, dmSet);

    Pad := Sc(DESKNOTIFY_PAD);
    Av := Sc(DESKNOTIFY_AVATAR);
    if Avatar <> nil then begin
      B.PutImage(Pad, (Height - Av) div 2, Avatar, dmDrawWithTransparency);
    end;

    Tx := Pad + Av + Sc(DESKNOTIFY_TEXT_GAP);
    TextW := Width - Tx - Sc(DESKNOTIFY_CLOSE_ZONE);
    B.FontName := DESKNOTIFY_FONT;
    B.FontQuality := fqFineAntialiasing;
    { The two lines together — centred on the height; the line height is
      measured by the font itself, not from the size in the settings: for
      Segoe UI they differ. }
    B.FontStyle := [fsBold];
    B.FontHeight := Sc(GTitleFont);
    TitleH := B.TextSize('Ag').cy;
    B.FontStyle := [];
    B.FontHeight := Sc(GTextFont);
    TextH := B.TextSize('Ag').cy;
    Top := (Height - TitleH - Sc(DESKNOTIFY_LINE_GAP) - TextH) div 2;

    B.FontStyle := [fsBold];
    B.FontHeight := Sc(GTitleFont);
    B.TextOut(Tx, Top, Fit(B, Title, TextW), Fg);
    B.FontStyle := [];
    B.FontHeight := Sc(GTextFont);
    B.TextOut(Tx, Top + TitleH + Sc(DESKNOTIFY_LINE_GAP), Fit(B, Text, TextW), Sub);

    { The cross — in the centre of the click zone. }
    Half := Sc(DESKNOTIFY_CLOSE_SIZE) div 2;
    Cx := Width - Sc(DESKNOTIFY_CLOSE_ZONE) div 2;
    Cy := Sc(DESKNOTIFY_CLOSE_ZONE) div 2;
    B.DrawLineAntialias(Cx - Half, Cy - Half, Cx + Half, Cy + Half, Cross,
      Max(1, Sc(1)));
    B.DrawLineAntialias(Cx + Half, Cy - Half, Cx - Half, Cy + Half, Cross,
      Max(1, Sc(1)));

    { Into a top-down DIB, with premultiplied alpha — that is how
      UpdateLayeredWindow with AC_SRC_ALPHA expects it. Line by line
      through ScanLine: TBGRABitmap's own line order depends on the
      platform. }
    FillChar(Info, SizeOf(Info), 0);
    Info.bmiHeader.biSize := SizeOf(Info.bmiHeader);
    Info.bmiHeader.biWidth := Width;
    Info.bmiHeader.biHeight := -Height;
    Info.bmiHeader.biPlanes := 1;
    Info.bmiHeader.biBitCount := 32;
    Info.bmiHeader.biCompression := BI_RGB;
    Bits := nil;
    Dib := CreateDIBSection(0, Info, DIB_RGB_COLORS, Bits, 0, 0);
    if (Dib = 0) or (Bits = nil) then begin
      Exit;
    end;
    for Row := 0 to Height - 1 do begin
      Src := B.ScanLine[Row];
      Dst := PBGRAPixel(Bits) + Row * Width;
      for I := 0 to Width - 1 do begin
        A := Src^.alpha;
        Dst^.blue := Src^.blue * A div 255;
        Dst^.green := Src^.green * A div 255;
        Dst^.red := Src^.red * A div 255;
        Dst^.alpha := A;
        Inc(Src);
        Inc(Dst);
      end;
    end;

    Mem := CreateCompatibleDC(0);
    Old := SelectObject(Mem, Dib);
    Pt := Point(X, Round(Y));
    SrcPt := Point(0, 0);
    Sz.cx := Width;
    Sz.cy := Height;
    Blend.BlendOp := AC_SRC_OVER;
    Blend.BlendFlags := 0;
    Blend.SourceConstantAlpha := EnsureRange(Round(Alpha), 0, 255);
    Blend.AlphaFormat := AC_SRC_ALPHA;
    UpdateLayeredWindow(Wnd, 0, @Pt, @Sz, Mem, @SrcPt, 0, @Blend, ULW_ALPHA);
    SelectObject(Mem, Old);
    DeleteDC(Mem);
    DeleteObject(Dib);
    ShownX := Pt.X;
    ShownY := Pt.Y;
    ShownAlpha := Blend.SourceConstantAlpha;
  finally
    B.Free;
  end;
end;

{ Only the position and transparency: the window remembers its content
  itself (UpdateLayeredWindow can be called without hdcSrc if the look has
  not changed). }
procedure TCard.Place;
var
  Pt: TPoint;
  Blend: TBlendFunction;
begin
  Pt := Point(X, Round(Y));
  Blend.BlendOp := AC_SRC_OVER;
  Blend.BlendFlags := 0;
  Blend.SourceConstantAlpha := EnsureRange(Round(Alpha), 0, 255);
  Blend.AlphaFormat := AC_SRC_ALPHA;
  if (Pt.X = ShownX) and (Pt.Y = ShownY)
    and (Blend.SourceConstantAlpha = ShownAlpha) then begin
    Exit;
  end;
  UpdateLayeredWindow(Wnd, 0, @Pt, nil, 0, nil, 0, @Blend, ULW_ALPHA);
  ShownX := Pt.X;
  ShownY := Pt.Y;
  ShownAlpha := Blend.SourceConstantAlpha;
end;

{ ---------------------------------------------------------------- }

procedure StartTimer;
begin
  if GTimer = nil then begin
    GTicker := TTicker.Create;
    GTimer := TTimer.Create(nil);
    GTimer.Interval := DESKNOTIFY_TICK_MS;
    GTimer.OnTimer := @GTicker.Tick;
  end;
  if not GTimer.Enabled then begin
    GLastTick := GetTickCount64;
    GTimer.Enabled := True;
  end;
end;

{ Vertical targets: the freshest (the last in the list) is closest to the
  corner, older ones further from it. Closing ones keep their place until
  they fade: otherwise the stack would jump under a still visible card. }
procedure Relayout;
var
  WA: TRect;
  I, Y: integer;
  C: TCard;
  Code: string;
begin
  WA := Screen.WorkAreaRect;
  Code := DESKNOTIFY_CORNERS[GCorner];
  if Code[1] = 't' then begin
    Y := WA.Top + Sc(DESKNOTIFY_MARGIN);
  end else begin
    Y := WA.Bottom - Sc(DESKNOTIFY_MARGIN);
  end;
  for I := GCards.Count - 1 downto 0 do begin
    C := Card(I);
    if Code[1] = 't' then begin
      C.TargetY := Y;
      Y := Y + C.Height + Sc(DESKNOTIFY_GAP);
    end else begin
      Y := Y - C.Height;
      C.TargetY := Y;
      Y := Y - Sc(DESKNOTIFY_GAP);
    end;
    if Code[2] = 'l' then begin
      C.X := WA.Left + Sc(DESKNOTIFY_MARGIN);
    end else begin
      C.X := WA.Right - Sc(DESKNOTIFY_MARGIN) - C.Width;
    end;
  end;
end;

function DeskNotifyCorner: integer;
begin
  Result := GCorner;
end;

procedure SetDeskNotifyCorner(AIndex: integer);
var
  I: integer;
begin
  if (AIndex < Low(DESKNOTIFY_CORNERS)) or (AIndex > High(DESKNOTIFY_CORNERS)) then begin
    AIndex := DESKNOTIFY_CORNER_DEFAULT;
  end;
  GCorner := AIndex;
  if GCards = nil then begin
    Exit;
  end;
  Relayout;
  for I := 0 to GCards.Count - 1 do begin
    Card(I).Y := Card(I).TargetY;
    Card(I).Place;
  end;
end;

{ Whether the mouse moved since the last tick. The mouse specifically, at
  the user's request, not GetLastInputInfo (that one counts the keyboard
  too). GetCursorPos does not answer on the secure desktop (the lock
  screen) — that counts as "did not move", and the cards wait. }
function CursorMoved: boolean;
var
  P: TPoint;
begin
  Result := False;
  if not GetCursorPos(P) then begin
    Exit;
  end;
  Result := GCursorKnown and ((P.X <> GCursor.X) or (P.Y <> GCursor.Y));
  GCursor := P;
  GCursorKnown := True;
end;

procedure TTicker.Tick(Sender: TObject);
var
  Now64: QWord;
  Dt, I: integer;
  C: TCard;
  Paused, Moved: boolean;
  Fade, Slide, Gap: double;
begin
  Now64 := GetTickCount64;
  Dt := Min(Now64 - GLastTick, DESKNOTIFY_TICK_MAX_MS);
  GLastTick := Now64;
  Moved := CursorMoved;

  { The cursor over any card holds the whole stack: the reader does not
    want the neighbour to slide away from under their eyes. }
  Paused := False;
  for I := 0 to GCards.Count - 1 do begin
    if Card(I).Hover then begin
      Paused := True;
    end;
  end;

  Fade := 255 * Dt / DESKNOTIFY_FADE_MS;
  Slide := Sc(DESKNOTIFY_SLIDE_PX_PER_S) * Dt / 1000;
  I := GCards.Count - 1;
  while I >= 0 do begin
    C := Card(I);
    if C.Closing then begin
      C.Alpha := C.Alpha - Fade;
      if C.Alpha <= 0 then begin
        GCards.Delete(I);
        C.Free;
        Relayout;
        Dec(I);
        Continue;
      end;
    end else begin
      C.Alpha := Min(255, C.Alpha + Fade);
      if C.Waiting then begin
        { The cycle ended without mouse movement. The first movement starts
          it FROM THE BEGINNING and itself counts as movement of this
          cycle: the person is back, and a full showing is enough for them. }
        if Moved then begin
          C.Waiting := False;
          C.LifeLeft := DESKNOTIFY_LIFE_MS;
          C.Moved := True;
        end;
      end else if not Paused then begin
        if Moved then begin
          C.Moved := True;
        end;
        Dec(C.LifeLeft, Dt);
        if C.LifeLeft <= 0 then begin
          if C.Moved then begin
            C.Closing := True;
          end else begin
            C.Waiting := True;
          end;
        end;
      end;
    end;
    Gap := C.TargetY - C.Y;
    if Abs(Gap) <= Slide then begin
      C.Y := C.TargetY;
    end else begin
      C.Y := C.Y + Sign(Gap) * Slide;
    end;
    C.Place;
    Dec(I);
  end;

  if GCards.Count = 0 then begin
    GTimer.Enabled := False;
  end;
end;

{ ---------------------------------------------------------------- }

function FindCard(AWnd: HWND): TCard;
begin
  Result := TCard(GetWindowLongPtrW(AWnd, GWLP_USERDATA));
end;

function CardProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
var
  C: TCard;
  P: TPoint;
  T: TTrackMouseEvent;
  InClose: boolean;
begin
  C := FindCard(AWnd);
  if C <> nil then begin
    case AMsg of
      WM_MOUSEACTIVATE:
        Exit(MA_NOACTIVATE);
      WM_MOUSEMOVE:
        begin
          if not C.Tracking then begin
            T.cbSize := SizeOf(T);
            T.dwFlags := TME_LEAVE;
            T.hwndTrack := AWnd;
            T.dwHoverTime := 0;
            TrackMouseEvent(T);
            C.Tracking := True;
          end;
          P := Point(SmallInt(ALParam and $FFFF), SmallInt((ALParam shr 16) and $FFFF));
          InClose := PtInRect(C.CloseRect, P);
          if (not C.Hover) or (InClose <> C.HoverClose) then begin
            C.Hover := True;
            C.HoverClose := InClose;
            C.Paint;
          end;
          Exit(0);
        end;
      WM_MOUSELEAVE:
        begin
          C.Tracking := False;
          C.Hover := False;
          C.HoverClose := False;
          C.Paint;
          Exit(0);
        end;
      WM_LBUTTONUP:
        begin
          if not C.Closing then begin
            P := Point(SmallInt(ALParam and $FFFF), SmallInt((ALParam shr 16) and $FFFF));
            { Closing BEFORE the call: the handler raises the window, and by
              the time it returns the card must already be fading. }
            C.Closing := True;
            StartTimer;
            if (not PtInRect(C.CloseRect, P)) and Assigned(DeskNotifyOnClick) then begin
              DeskNotifyOnClick(C.ChatId);
            end;
          end;
          Exit(0);
        end;
    end;
  end;
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

procedure EnsureClass;
var
  WC: TWndClassW;
begin
  if GClassDone then begin
    Exit;
  end;
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @CardProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_HAND);
  WC.lpszClassName := DESKNOTIFY_CLASS;
  RegisterClassW(WC);
  GClassDone := True;
end;

{ Beyond the limit it is a wall, not a notification: the oldest go. }
procedure TrimToLimit;
var
  I, Alive: integer;
begin
  Alive := 0;
  for I := GCards.Count - 1 downto 0 do begin
    if not Card(I).Closing then begin
      Inc(Alive);
      if Alive > GLimit then begin
        Card(I).Closing := True;
      end;
    end;
  end;
end;

procedure PutCard(AChatId: Int64; ASample: boolean;
  const ATitle, AText: utf8string; const APhoto, AThumb: RawByteString);
var
  C: TCard;
  I: integer;
  Fresh: boolean;
begin
  if GCards = nil then begin
    GCards := TFPList.Create;
  end;

  C := nil;
  if not ASample then begin
    for I := 0 to GCards.Count - 1 do begin
      if (Card(I).ChatId = AChatId) and not Card(I).Closing
        and not Card(I).Sample then begin
        C := Card(I);
      end;
    end;
  end;
  Fresh := C = nil;
  if Fresh then begin
    EnsureClass;
    C := TCard.Create;
    C.ChatId := AChatId;
    C.Sample := ASample;
    C.Width := Sc(DESKNOTIFY_WIDTH);
    C.Height := Sc(DESKNOTIFY_HEIGHT);
    C.Alpha := 0;
    C.ShownX := MaxInt;
    C.Wnd := CreateWindowExW(
      WS_EX_LAYERED or WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE,
      DESKNOTIFY_CLASS, nil, WS_POPUP, 0, 0, C.Width, C.Height,
      0, 0, HInstance, nil);
    if C.Wnd = 0 then begin
      C.Free;
      Exit;
    end;
    SetWindowLongPtrW(C.Wnd, GWLP_USERDATA, LONG_PTR(C));
    GCards.Add(C);
  end else begin
    GCards.Remove(C);
    GCards.Add(C);
  end;

  C.Title := OneLine(ATitle);
  if C.Title = '' then begin
    C.Title := '(no title)';
  end;
  C.Text := OneLine(AText);
  C.Dark := SystemIsDark;
  FreeAndNil(C.Avatar);
  C.Avatar := RenderAvatarBmp(APhoto, AThumb, ATitle, AChatId,
    Sc(DESKNOTIFY_AVATAR), True);
  C.LifeLeft := DESKNOTIFY_LIFE_MS;
  C.Moved := False;
  C.Waiting := False;

  TrimToLimit;
  Relayout;
  if Fresh then begin
    { A new one stands in its place at once and fades in, the old ones move. }
    C.Y := C.TargetY;
  end;
  C.Paint;
  if Fresh then begin
    ShowWindow(C.Wnd, SW_SHOWNOACTIVATE);
  end;
  StartTimer;
end;

procedure ShowDeskNotify(AChatId: Int64; const ATitle, AText: utf8string;
  const APhoto, AThumb: RawByteString);
begin
  PutCard(AChatId, False, ATitle, AText, APhoto, AThumb);
end;

procedure SetDeskNotifyLimit(ACount: integer);
begin
  GLimit := EnsureRange(ACount, DESKNOTIFY_LIMIT_MIN, DESKNOTIFY_LIMIT_MAX);
  if GCards = nil then begin
    Exit;
  end;
  TrimToLimit;
  StartTimer;
end;

{ '#rrggbb' -> TColor ($00BBGGRR). }
function CssColor(const S: string; out AColor: TColor): boolean;
var
  V: integer;
begin
  Result := (Length(S) = 7) and (S[1] = '#') and TryStrToInt('$' + Copy(S, 2, 6), V);
  if Result then begin
    AColor := TColor(((V shr 16) and $FF) or (V and $FF00) or ((V and $FF) shl 16));
  end;
end;

procedure CloseDeskNotify(AChatId: Int64);
var
  I: integer;
begin
  if (GCards = nil) or (AChatId = 0) then begin
    Exit;
  end;
  for I := 0 to GCards.Count - 1 do begin
    if (Card(I).ChatId = AChatId) and not Card(I).Sample then begin
      Card(I).Closing := True;
    end;
  end;
  StartTimer;
end;

procedure SetDeskNotifyColors(const ABg, ABorder, ATitle, AText: string);
var
  Bg, Border, Title, Text: TColor;
  I: integer;
begin
  GThemed := CssColor(ABg, Bg) and CssColor(ABorder, Border)
    and CssColor(ATitle, Title) and CssColor(AText, Text);
  if GThemed then begin
    GThemeBg := Bg;
    GThemeBorder := Border;
    GThemeTitle := Title;
    GThemeText := Text;
  end;
  if GCards = nil then begin
    Exit;
  end;
  for I := 0 to GCards.Count - 1 do begin
    Card(I).Paint;
  end;
end;

procedure SetDeskNotifyFonts(ATitle, AText: integer);
var
  I: integer;
begin
  GTitleFont := EnsureRange(ATitle, DESKNOTIFY_FONT_MIN, DESKNOTIFY_FONT_MAX);
  GTextFont := EnsureRange(AText, DESKNOTIFY_FONT_MIN, DESKNOTIFY_FONT_MAX);
  if GCards = nil then begin
    Exit;
  end;
  for I := 0 to GCards.Count - 1 do begin
    Card(I).Paint;
  end;
end;

procedure ShowDeskNotifySamples(const ATitle, AText: utf8string);
var
  I: integer;
begin
  if GCards <> nil then begin
    for I := GCards.Count - 1 downto 0 do begin
      if Card(I).Sample then begin
        Card(I).Free;
        GCards.Delete(I);
      end;
    end;
  end;
  for I := 1 to GLimit do begin
    PutCard(0, True, ATitle, AText, '', '');
  end;
end;

finalization
  if GTimer <> nil then begin
    GTimer.Enabled := False;
    FreeAndNil(GTimer);
  end;
  FreeAndNil(GTicker);
  if GCards <> nil then begin
    while GCards.Count > 0 do begin
      Card(GCards.Count - 1).Free;
      GCards.Delete(GCards.Count - 1);
    end;
    FreeAndNil(GCards);
  end;
end.
