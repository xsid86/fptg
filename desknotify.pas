unit desknotify;

{$mode objfpc}{$H+}{$codepage utf8}

{ Уведомления на рабочем столе — как у Telegram Desktop: свои карточки
  в правом нижнем углу рабочей области, стопкой над панелью задач, а не
  тост Windows и не карточка внутри окна.

  Каждая карточка — отдельное окно WS_EX_LAYERED, нарисованное целиком
  в BGRABitmap и выведенное UpdateLayeredWindow: ни рамки, ни мигания
  при перерисовке, а прозрачность (появление, исчезновение) и сдвиг
  стопки меняются без перерисовки содержимого. Окна свои, на чистом
  Win32, а не LCL-формы: LCL показывает форму через
  ShowWindow(SW_SHOWNORMAL) (win32wsforms.pp, ShowHide), а это
  активирует окно и отбирает фокус у того, кто сейчас печатает. Здесь —
  SW_SHOWNOACTIVATE при показе и MA_NOACTIVATE при клике.

  Всё в главном потоке: окна создаются в нём, и их сообщения разбирает
  обычный цикл Application. }

interface

type
  TDeskNotifyClick = procedure(AChatId: Int64) of object;

{ Показывает карточку. Если у чата карточка уже есть, она обновляется,
  уходит вниз стопки как самая свежая и живёт заново — второй не
  появляется. }
procedure ShowDeskNotify(AChatId: Int64; const ATitle, AText, APhotoPath: utf8string;
  const AMinithumb: RawByteString);

{ Угол экрана — индекс в DESKNOTIFY_CORNERS. Уже показанные карточки
  переезжают туда сразу, без анимации. }
procedure SetDeskNotifyCorner(AIndex: integer);
{ Сколько карточек одновременно. Лишние старшие тут же начинают таять. }
procedure SetDeskNotifyLimit(ACount: integer);
{ Размер шрифта заголовка и текста (при 96 dpi). Показанные карточки
  перерисовываются сразу. }
procedure SetDeskNotifyFonts(ATitle, AText: integer);
{ Образец для настроек: столько карточек, сколько их помещается
  одновременно, — сразу видно и угол, и высоту стопки. Прежний образец
  убирается сразу, без исчезновения. Клик по образцу приходит в
  DeskNotifyOnClick с AChatId = 0. }
procedure ShowDeskNotifySamples(const ATitle, AText: utf8string);

var
  { Клик по карточке мимо крестика. Сама карточка после него закрывается. }
  DeskNotifyOnClick: TDeskNotifyClick = nil;

implementation

uses
  Windows, Classes, SysUtils, Math, Graphics, Forms, ExtCtrls, Registry,
  LazUTF8, BGRABitmap, BGRABitmapTypes, constants, avatarcache;

{ В модуле Windows у FPC 3.2.2 этой функции нет (есть только в
  jwawinuser). Параметры-указатели — как в WinUser.h. }
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
    LifeLeft: integer;      { мс до начала исчезновения }
    Closing: boolean;
    { Образец из настроек: ChatId у него 0, и слиянию по чату он не
      подлежит — образцов в стопке несколько. }
    Sample: boolean;
    Hover: boolean;
    HoverClose: boolean;
    Tracking: boolean;      { TrackMouseEvent уже взведён }
    { Что последним ушло в окно: Place не трогает его без нужды. }
    ShownX, ShownY, ShownAlpha: integer;
    destructor Destroy; override;
    function CloseRect: TRect;
    procedure Paint;
    procedure Place;
  end;

  { TTimer просит метод, а не процедуру. }
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

function Sc(AValue: integer): integer;
begin
  Result := MulDiv(AValue, Screen.PixelsPerInch, 96);
end;

function Card(AIndex: integer): TCard;
begin
  Result := TCard(GCards[AIndex]);
end;

{ Тема Windows для приложений — та, что в «Параметры → Персонализация →
  Цвета». Нет ключа (старая система) — светлая. }
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

{ Одна строка: переводы строк в пробелы и с запасом обрезано — дальше
  ширину добирает Fit, а ему незачем мерить мегабайт. }
function OneLine(const AText: utf8string): utf8string;
begin
  Result := StringReplace(AText, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  if UTF8Length(Result) > DESKNOTIFY_TEXT_MAX then begin
    Result := UTF8Copy(Result, 1, DESKNOTIFY_TEXT_MAX);
  end;
end;

{ Текст в ширину AWidth, с многоточием, если не влез. По символам UTF-8,
  а не по байтам: иначе резало бы посреди кириллицы. }
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

{ Зона клика по крестику — больше нарисованного крестика: в десять
  пикселей мышью не попасть. }
function TCard.CloseRect: TRect;
var
  Z: integer;
begin
  Z := Sc(DESKNOTIFY_CLOSE_ZONE);
  Result := Rect(Width - Z, 0, Width, Z);
end;

{ Содержимое целиком: фон, рамка, аватарка, заголовок, текст, крестик.
  Только при смене содержимого или наведения — движение и прозрачность
  идут через Place. }
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
  if Dark then begin
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
    { Две строки вместе — по центру высоты; высоту строки меряет сам
      шрифт, а не размер из настроек: у Segoe UI они не совпадают. }
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

    { Крестик — по центру зоны клика. }
    Half := Sc(DESKNOTIFY_CLOSE_SIZE) div 2;
    Cx := Width - Sc(DESKNOTIFY_CLOSE_ZONE) div 2;
    Cy := Sc(DESKNOTIFY_CLOSE_ZONE) div 2;
    B.DrawLineAntialias(Cx - Half, Cy - Half, Cx + Half, Cy + Half, Cross,
      Max(1, Sc(1)));
    B.DrawLineAntialias(Cx + Half, Cy - Half, Cx - Half, Cy + Half, Cross,
      Max(1, Sc(1)));

    { В DIB сверху вниз, с умноженной альфой — так UpdateLayeredWindow
      с AC_SRC_ALPHA её и ждёт. Построчно через ScanLine: порядок строк
      у самого TBGRABitmap от платформы зависит. }
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

{ Только место и прозрачность: содержимое окно помнит само (у
  UpdateLayeredWindow можно не передавать hdcSrc, если вид не менялся). }
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

{ Цели по вертикали: самая свежая (последняя в списке) — ближе всех к
  углу, старшие — дальше от него. Закрывающиеся место держат, пока не
  растают: иначе стопка прыгала бы под ещё видимой карточкой. }
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

procedure TTicker.Tick(Sender: TObject);
var
  Now64: QWord;
  Dt, I: integer;
  C: TCard;
  Paused: boolean;
  Fade, Slide, Gap: double;
begin
  Now64 := GetTickCount64;
  Dt := Min(Now64 - GLastTick, DESKNOTIFY_TICK_MAX_MS);
  GLastTick := Now64;

  { Курсор над любой карточкой держит всю стопку: читающему не нужно,
    чтобы соседняя уехала из-под глаз. }
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
      if not Paused then begin
        Dec(C.LifeLeft, Dt);
        if C.LifeLeft <= 0 then begin
          C.Closing := True;
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
            { Закрываем ДО вызова: обработчик поднимает окно, и к его
              возврату карточка уже должна таять. }
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

{ Больше предела — стена, а не уведомление: старшие уходят. }
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
  const ATitle, AText, APhotoPath: utf8string; const AMinithumb: RawByteString);
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
  C.Avatar := RenderAvatarBmp(APhotoPath, AMinithumb, ATitle, AChatId,
    Sc(DESKNOTIFY_AVATAR), True);
  C.LifeLeft := DESKNOTIFY_LIFE_MS;

  TrimToLimit;
  Relayout;
  if Fresh then begin
    { Новая встаёт сразу на своё место и проявляется, сдвигаются старые. }
    C.Y := C.TargetY;
  end;
  C.Paint;
  if Fresh then begin
    ShowWindow(C.Wnd, SW_SHOWNOACTIVATE);
  end;
  StartTimer;
end;

procedure ShowDeskNotify(AChatId: Int64; const ATitle, AText, APhotoPath: utf8string;
  const AMinithumb: RawByteString);
begin
  PutCard(AChatId, False, ATitle, AText, APhotoPath, AMinithumb);
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
