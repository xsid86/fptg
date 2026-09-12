unit thinscrollbar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, StdCtrls,
  BGRABitmap, BGRABitmapTypes, constants;

type

  { TThinScrollBar

    A vertical-only, custom-painted stand-in for the native TScrollBar
    — NOT a TScrollBar subclass, deliberately: Windows' own scrollbar
    is a real native child window (window class "SCROLLBAR", see
    win32wsstdctrls.pp's TWin32WSScrollBar.CreateHandle), themed and
    painted entirely by the OS itself. There is no Paint/Canvas hook
    for it at all — WM_PAINT for that window never reaches an LCL
    Canvas-based Paint method, so inheriting from TScrollBar and
    overriding Paint would compile cleanly but draw nothing different;
    the OS still owns every pixel. The only way to get a custom look
    is a plain windowless-drawing control reimplementing scrollbar
    behavior from scratch, which is what this is.

    Deliberately mirrors TScrollBar's shape closely enough — the same
    TScrollEvent/TScrollCode types (from StdCtrls, not redeclared) and
    the same SetParams(APosition, AMin, AMax, APage) signature — to be
    a drop-in replacement at its one call site (framehistory.pas):
    only FScrollbar's declared type changes there, the surrounding
    OnScroll handler and SetParams call are untouched. }

  TThinScrollBar = class(TCustomControl)
  private
    FMin, FMax, FPage, FPosition: integer;
    FDragging: boolean;
    FHovering: boolean;
    FDragStartY, FDragStartPos: integer;
    FOnScroll: TScrollEvent;
    { Pixel height of the thumb — proportional to the visible page
      versus the whole range, floored at THIN_SCROLLBAR_MIN_THUMB_H so
      it never shrinks into an unclickable sliver on a long history. }
    function ThumbHeight: integer;
    { How many pixels the thumb's TOP can travel across, from the very
      top of the track to the very bottom. }
    function TrackRange: integer;
    { Thumb's current rectangle in client coordinates — horizontally
      centered (THIN_SCROLLBAR_THUMB_W is narrower than the control's
      own THIN_SCROLLBAR_WIDTH), vertically placed from FPosition. }
    function ThumbRect: TRect;
    { Clamps APos to [FMin, FMin+range-FPage], fires OnScroll with it,
      and lets the caller's handler drive the actual scroll — same
      round-trip contract as the native TScrollBar: this control does
      NOT update FPosition itself here. The caller's OnScroll handler
      (framehistory.pas's ScrollbarScroll) applies the position to the
      real content and that, in turn, synchronously calls back into
      SetParams below with the authoritative clamped value — which is
      what actually moves the thumb and repaints. }
    procedure DoScroll(ACode: TScrollCode; APos: integer);
  protected
    procedure Paint; override;
    { The track's rounded shape depends on the control's current
      Width/Height (THIN_SCROLLBAR_TRACK_RADIUS, Paint below) — forces
      a full repaint whenever either changes, rather than relying on
      the OS's own default partial-invalidate-on-resize behavior to
      happen to cover the corner pixels that moved. }
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
  public
    constructor Create(TheOwner: TComponent); override;
    { Same signature as TCustomScrollBar.SetParams — classic Win32
      SCROLLINFO semantics: AMax is the top of the whole scroll range
      (like TotalHeight), APage is subtracted from it by the control
      itself when computing the thumb's extreme position. }
    procedure SetParams(APosition, AMin, AMax, APage: integer);
    property Position: integer read FPosition;
    property OnScroll: TScrollEvent read FOnScroll write FOnScroll;
  end;

implementation

{ TThinScrollBar }

constructor TThinScrollBar.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  Width := THIN_SCROLLBAR_WIDTH;
  Color := clWindow;
  ParentColor := False;
end;

function TThinScrollBar.ThumbHeight: integer;
var
  Range, MaxH: integer;
begin
  { Never allowed to reach all the way to the track's own top/bottom
    edge — see THIN_SCROLLBAR_THUMB_INSET's own comment. }
  MaxH := Height - 2 * THIN_SCROLLBAR_THUMB_INSET;
  if MaxH < 0 then begin
    MaxH := 0;
  end;
  Range := FMax - FMin;
  if Range <= FPage then begin
    { Nothing to scroll — the thumb would fill the whole track; Paint
      skips drawing it at all in this case (see its own comment), this
      value is only used defensively elsewhere. }
    Result := MaxH;
    Exit;
  end;
  Result := Round(Height * (FPage / Range));
  if Result < THIN_SCROLLBAR_MIN_THUMB_H then begin
    Result := THIN_SCROLLBAR_MIN_THUMB_H;
  end;
  if Result > MaxH then begin
    Result := MaxH;
  end;
end;

function TThinScrollBar.TrackRange: integer;
begin
  Result := Height - ThumbHeight - 2 * THIN_SCROLLBAR_THUMB_INSET;
  if Result < 0 then begin
    Result := 0;
  end;
end;

function TThinScrollBar.ThumbRect: TRect;
var
  TH, Y, Denom, TR: integer;
  X0: integer;
begin
  TH := ThumbHeight;
  TR := TrackRange;
  Denom := (FMax - FMin) - FPage;
  if (Denom <= 0) or (TR <= 0) then begin
    Y := 0;
  end else begin
    Y := Round((FPosition - FMin) / Denom * TR);
    if Y < 0 then begin
      Y := 0;
    end;
    if Y > TR then begin
      Y := TR;
    end;
  end;
  { The top inset, on top of whatever position within the track range
    was just computed above — this is what actually keeps the thumb
    off the track's top/bottom edges (TrackRange/ThumbHeight above
    already shrank the range it travels across by the same 2 insets,
    this places its origin past the first one). }
  Y := Y + THIN_SCROLLBAR_THUMB_INSET;
  X0 := (Width - THIN_SCROLLBAR_THUMB_W) div 2;
  Result := Rect(X0, Y, X0 + THIN_SCROLLBAR_THUMB_W, Y + TH);
end;

procedure TThinScrollBar.DoScroll(ACode: TScrollCode; APos: integer);
var
  Denom, ClampedPos: integer;
begin
  Denom := (FMax - FMin) - FPage;
  if Denom < 0 then begin
    Denom := 0;
  end;
  ClampedPos := APos;
  if ClampedPos < FMin then begin
    ClampedPos := FMin;
  end;
  if ClampedPos > FMin + Denom then begin
    ClampedPos := FMin + Denom;
  end;
  if Assigned(FOnScroll) then begin
    FOnScroll(Self, ACode, ClampedPos);
  end;
end;

procedure TThinScrollBar.SetParams(APosition, AMin, AMax, APage: integer);
var
  ParamsChanged: boolean;
begin
  ParamsChanged := (FPosition <> APosition) or (FMin <> AMin) or (FMax <> AMax) or (FPage <> APage);
  FPosition := APosition;
  FMin := AMin;
  FMax := AMax;
  FPage := APage;
  if ParamsChanged then begin
    Invalidate;
  end;
end;

procedure TThinScrollBar.Resize;
begin
  inherited Resize;
  Invalidate;
end;

procedure TThinScrollBar.Paint;
var
  Bmp: TBGRABitmap;
  TR: TRect;
  ThumbColor, BgColor: TColor;
begin
  { Whatever the real parent's own background actually is — read live,
    not plumbed in as a separate property from each of this control's
    three call sites, unlike the message-block widgets elsewhere in
    this project (TPhotoWidget etc.) that need one: those sit on a
    computed, per-message TINTED background with no single color to
    just ask for, but this control's parent (a plain frame/panel in
    all three cases) genuinely IS just its own flat Color.

    GetRGBColorResolvingParent, not the raw Color property — reported
    live: a parent left at its DESIGN-TIME default (Color = clDefault,
    the actual value before anyone explicitly sets one — not a real
    color at all, just a sentinel meaning "whatever this control class
    would normally use") produced solid black corners once fed
    straight into ColorToBGRA below. Confirmed by reading the real LCL
    source (control.inc): TControl.GetColorResolvingParent already
    exists to handle exactly this — clDefault resolves through
    GetDefaultColor (per-widgetset/control-class, or up the ParentColor
    chain if that's set instead), and GetRGBColorResolvingParent
    additionally runs the result through ColorToRGB so any remaining
    symbolic system color (clBtnFace, clWindow, ...) also comes back as
    a real, usable RGB value — this is the sanctioned way to ask "what
    does this control actually look like right now," not a home-grown
    guess at clDefault's fallback. Falls back to this control's own
    Color if unparented (shouldn't happen in practice — always created
    with a Parent right away — but Parent can genuinely be nil before
    that assignment runs). }
  if Parent <> nil then begin
    BgColor := Parent.GetRGBColorResolvingParent;
  end else begin
    BgColor := Color;
  end;

  { One antialiased composite for the WHOLE control — the track's own
    rounded background AND the thumb on top of it, not two separate
    drawing paths. Previously the track was clipped to a rounded shape
    via SetWindowRgn (a native window region — inherently a hard,
    all-or-nothing per-pixel mask, so its rounded corners came out
    visibly stair-stepped, by direct report) while only the thumb got
    antialiased; both now go through the same FillRoundRectAntialias
    path the thumb always used, so both are equally smooth. Sized to
    the FULL control (Width, Height), not just the thumb's own bounds
    as before — the thumb's rect is simply drawn at its own offset
    within this same bitmap rather than composited as a second,
    separately-sized one. -0.5 on every edge: BGRABitmap's coordinates
    are pixel-CENTERED by default (see PaintRoundRectAA's own comment
    in framehistory.pas for the same correction, already worked out
    there), so a rect literally (0,0,W,H) would sit half a pixel
    outside the bitmap on two sides. }
  Bmp := TBGRABitmap.Create(Width, Height, ColorToBGRA(BgColor));
  try
    Bmp.FillRoundRectAntialias(-0.5, -0.5, Width - 0.5, Height - 0.5,
      THIN_SCROLLBAR_TRACK_RADIUS, THIN_SCROLLBAR_TRACK_RADIUS, ColorToBGRA(Color));

    if (FMax - FMin) > FPage then begin
      { Native scrollbar equivalent: nothing to scroll (the whole
        content already fits) means no thumb at all, not just an
        oversized one filling the track. }
      TR := ThumbRect;
      if (TR.Right > TR.Left) and (TR.Bottom > TR.Top) then begin
        if FDragging or FHovering then begin
          ThumbColor := THIN_SCROLLBAR_THUMB_ACTIVE_COLOR;
        end else begin
          ThumbColor := THIN_SCROLLBAR_THUMB_COLOR;
        end;
        Bmp.FillRoundRectAntialias(TR.Left - 0.5, TR.Top - 0.5, TR.Right - 0.5, TR.Bottom - 0.5,
          THIN_SCROLLBAR_RADIUS, THIN_SCROLLBAR_RADIUS, ColorToBGRA(ThumbColor));
      end;
    end;

    Bmp.Draw(Canvas, 0, 0, False);
  finally
    Bmp.Free;
  end;
end;

procedure TThinScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  TR: TRect;
  NewPos: integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then begin
    Exit;
  end;
  TR := ThumbRect;
  if PtInRect(Point(X, Y), TR) then begin
    FDragging := True;
    FDragStartY := Y;
    FDragStartPos := FPosition;
  end else begin
    { Clicked the track above/below the thumb — page up/down, same as
      a native scrollbar's track click (no click-and-hold repeat here,
      not asked for and adds a timer for a rarely-used path). }
    if Y < TR.Top then begin
      NewPos := FPosition - FPage;
    end else begin
      NewPos := FPosition + FPage;
    end;
    DoScroll(scPosition, NewPos);
    DoScroll(scEndScroll, NewPos);
  end;
end;

procedure TThinScrollBar.MouseMove(Shift: TShiftState; X, Y: integer);
var
  Denom, TR, DY, NewPos: integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging then begin
    Exit;
  end;
  TR := TrackRange;
  Denom := (FMax - FMin) - FPage;
  if (TR <= 0) or (Denom <= 0) then begin
    Exit;
  end;
  { Delta-based, not absolute-from-click-point: starting the drag
    anywhere on the thumb (not necessarily its center) must not make
    it jump to align with the cursor. }
  DY := Y - FDragStartY;
  NewPos := FDragStartPos + Round(DY * Denom / TR);
  DoScroll(scTrack, NewPos);
end;

procedure TThinScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging and (Button = mbLeft) then begin
    FDragging := False;
    DoScroll(scEndScroll, FPosition);
  end;
end;

procedure TThinScrollBar.MouseEnter;
begin
  inherited MouseEnter;
  FHovering := True;
  Invalidate;
end;

procedure TThinScrollBar.MouseLeave;
begin
  inherited MouseLeave;
  FHovering := False;
  Invalidate;
end;

end.
