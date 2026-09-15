unit cardpaint;

{$mode objfpc}{$H+}

{ One rounded fill/outline routine for the whole application.

  Until this unit existed there were THREE near-identical copies of it
  — framehistory.PaintRoundRectAA (message blocks, forward cards, reply
  quotes, audio/file widgets, reaction pills), framechats.
  PaintCardRoundRect (chat list row cards) and chatheader.PaintCard
  (the chat info bar's card). They were independent copies for a real
  reason (framechats/chatheader cannot import framehistory — that one
  imports both of them, a unit cycle), not by oversight, and while they
  all drew with plain GDI the duplication was harmless.

  It stopped being harmless the moment the two "chrome" copies needed
  the antialiased path as well: that path carries a correction that
  took three rounds of fixes to get right (see PaintRounded below), and
  having it written out in three places is exactly how one of them ends
  up quietly diverging. This unit sits at the bottom of the dependency
  graph — it imports only Graphics/Types and BGRABitmap, nothing
  project-specific except constants — so all three can share it.

  Deliberately NOT a decision-maker: whether to antialias is passed in
  as ASmooth rather than read from a constant here. The application has
  two independent answers to that question (SMOOTH_CORNERS for the
  message history, SMOOTH_CHROME_CORNERS for everything around it — see
  constants.pas for why they differ), and baking either one in would
  have forced them back together. }

interface

uses
  Graphics, Types, BGRABitmap, BGRABitmapTypes;

{ Fill and/or outline a rounded rectangle on ACanvas.

  AFillColor/ABorderColor = clNone skips the corresponding pass (fill
  only, outline only, or both). ARadius is used AS GIVEN — callers
  moving between the two drawing methods change no numbers.

  ASmooth=False is plain GDI Canvas.RoundRect: cheap, no temporary
  bitmap, visibly jagged at small radii. ASmooth=True draws into a
  temporary transparent BGRA bitmap sized exactly to ABox and
  composites it with alpha blending, so whatever lies outside the
  rounded shape is left exactly as it was on the canvas.

  The two -0.5 corrections in the antialiased path are not cosmetic
  tweaking. FillRoundRectAntialias/RoundRectAntialias, by default
  (APixelCenteredCoordinates=True, confirmed by reading the BGRABitmap
  source, not guessed), treat an integer coordinate N as the CENTER of
  pixel N, not the boundary between pixels N-1 and N the way GDI does.
  Three separate bug reports on one photo widget — a white gap in the
  corner, then a clipped outline, then a blurry outline — were all this
  one fact. Hence: -0.5 on the fill (its edge must fall exactly between
  "pixel still exists" and "pixel no longer exists") and an additional
  half border width on the outline (the line is centered on its path
  and ABorderWidth thick, so its whole extent has to stay inside the
  bitmap).

  Per-corner squaring (AOptions) is native to the BGRA path. GDI cannot
  do it at all, so the ASmooth=False branch falls back to the older
  trick this project used before BGRA: draw all four corners rounded,
  then square off one side with a plain FillRect. Only the two
  combinations that actually occur are handled — squaring off the
  bottom (a header strip sitting on top of a card) and squaring off the
  top (the reaction strip flush against a block's rounded bottom) — and
  both are only ever asked for without an outline. This is not
  generalized past what is really used. }
procedure PaintRounded(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ASmooth: boolean; ABorderWidth: single = 1);

implementation

procedure PaintRounded(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ASmooth: boolean; ABorderWidth: single = 1);
var
  W, H, IRadius: integer;
  Bmp: TBGRABitmap;
  Half: single;
begin
  W := ABox.Right - ABox.Left;
  H := ABox.Bottom - ABox.Top;
  if (W <= 0) or (H <= 0) then begin
    Exit;
  end;

  if not ASmooth then begin
    IRadius := Round(ARadius);
    ACanvas.Pen.Style := psClear;
    if ABorderColor <> clNone then begin
      ACanvas.Pen.Style := psSolid;
      ACanvas.Pen.Color := ABorderColor;
      ACanvas.Pen.Width := Round(ABorderWidth);
    end;
    if AFillColor <> clNone then begin
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := AFillColor;
    end else begin
      ACanvas.Brush.Style := bsClear;
    end;
    ACanvas.RoundRect(ABox.Left, ABox.Top, ABox.Right, ABox.Bottom, IRadius * 2, IRadius * 2);
    if AFillColor <> clNone then begin
      ACanvas.Pen.Style := psClear;
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := AFillColor;
      if (rrBottomLeftSquare in AOptions) and (rrBottomRightSquare in AOptions) then begin
        ACanvas.FillRect(Rect(ABox.Left, ABox.Bottom - IRadius, ABox.Right, ABox.Bottom));
      end;
      if (rrTopLeftSquare in AOptions) and (rrTopRightSquare in AOptions) then begin
        ACanvas.FillRect(Rect(ABox.Left, ABox.Top, ABox.Right, ABox.Top + IRadius));
      end;
    end;
    Exit;
  end;

  Bmp := TBGRABitmap.Create(W, H, BGRAPixelTransparent);
  try
    if AFillColor <> clNone then begin
      Bmp.FillRoundRectAntialias(-0.5, -0.5, W - 0.5, H - 0.5, ARadius, ARadius,
        ColorToBGRA(AFillColor), AOptions);
    end;
    if ABorderColor <> clNone then begin
      Half := ABorderWidth / 2;
      Bmp.RoundRectAntialias(Half - 0.5, Half - 0.5, W - Half - 0.5, H - Half - 0.5,
        ARadius, ARadius, ColorToBGRA(ABorderColor), ABorderWidth, AOptions);
    end;
    Bmp.Draw(ACanvas, ABox.Left, ABox.Top, False);
  finally
    Bmp.Free;
  end;
end;

end.
