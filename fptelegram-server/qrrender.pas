unit qrrender;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics,
  constants, QlpQrCode, QlpIQrCode;

{ Renders a QR code for AText into ABitmap.

  The output side is the largest that fits within ASizePx at an
  integer module scale. A fractional scale would give modules of
  uneven width and break scanning, so leftover space becomes margin
  instead of being stretched.

  Returns the actual side length in pixels, or 0 on failure.
  Centering is the caller's responsibility (TImage.Center := True). }
function DrawQrToBitmap(const AText: utf8string; ABitmap: TBitmap; ASizePx: integer): integer;

implementation

function DrawQrToBitmap(const AText: utf8string; ABitmap: TBitmap; ASizePx: integer): integer;
var
  Qr: IQrCode;
  Modules, Total, Scale, Side, X, Y, Px, Py: integer;
begin
  Result := 0;
  if (ABitmap = nil) or (AText = '') or (ASizePx <= 0) then begin
    Exit;
  end;

  { EncodeText picks the optimal segment mode on its own. The encoding
    is passed explicitly — the library throws if nil is passed. }
  Qr := TQrCode.EncodeText(string(AText), TQrCode.TEcc.eccMedium, TEncoding.UTF8);
  if Qr = nil then begin
    Exit;
  end;

  Modules := Qr.Size;
  Total := Modules + QR_QUIET_ZONE * 2;

  Scale := ASizePx div Total;
  if Scale < 1 then begin
    Scale := 1;
  end;
  Side := Total * Scale;

  ABitmap.PixelFormat := pf24bit;
  ABitmap.SetSize(Side, Side);

  { Colors are hardcoded black-on-white, not clWindow/clWindowText:
    in dark theme that would invert the code, which most phone
    cameras fail to scan. }
  ABitmap.Canvas.Brush.Style := bsSolid;
  ABitmap.Canvas.Brush.Color := clWhite;
  ABitmap.Canvas.FillRect(0, 0, Side, Side);

  ABitmap.Canvas.Brush.Color := clBlack;
  for Y := 0 to Modules - 1 do begin
    for X := 0 to Modules - 1 do begin
      if Qr.GetModule(X, Y) then begin
        Px := (X + QR_QUIET_ZONE) * Scale;
        Py := (Y + QR_QUIET_ZONE) * Scale;
        ABitmap.Canvas.FillRect(Px, Py, Px + Scale, Py + Scale);
      end;
    end;
  end;

  Result := Side;
end;

end.
