unit qrrender;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FPImage, FPWritePNG,
  constants, QlpQrCode, QlpIQrCode;

{ Renders a QR code for AText as a PNG into AStream.

  The output side is the largest that fits within ASizePx at an
  integer module scale. A fractional scale would give modules of
  uneven width and break scanning, so leftover space becomes margin
  instead of being stretched.

  Returns the actual side length in pixels, or 0 on failure.

  Without LCL: the picture is FPImage (fcl-image), the server must build
  as a console program and under Linux. }
function DrawQrToPng(const AText: utf8string; AStream: TStream; ASizePx: integer): integer;

implementation

function DrawQrToPng(const AText: utf8string; AStream: TStream; ASizePx: integer): integer;
var
  Qr: IQrCode;
  Img: TFPMemoryImage;
  Writer: TFPWriterPNG;
  Modules, Total, Scale, Side, X, Y: integer;
begin
  Result := 0;
  if (AStream = nil) or (AText = '') or (ASizePx <= 0) then begin
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

  Img := TFPMemoryImage.Create(Side, Side);
  Writer := TFPWriterPNG.Create;
  try
    { Colors are hardcoded black-on-white, not the theme's: in dark
      theme that would invert the code, which most phone cameras fail
      to scan. A module of the code is a Scale x Scale cell. }
    for Y := 0 to Side - 1 do begin
      for X := 0 to Side - 1 do begin
        if (X div Scale >= QR_QUIET_ZONE) and (Y div Scale >= QR_QUIET_ZONE)
          and (X div Scale < Modules + QR_QUIET_ZONE)
          and (Y div Scale < Modules + QR_QUIET_ZONE)
          and Qr.GetModule(X div Scale - QR_QUIET_ZONE, Y div Scale - QR_QUIET_ZONE) then begin
          Img.Colors[X, Y] := colBlack;
        end else begin
          Img.Colors[X, Y] := colWhite;
        end;
      end;
    end;
    Writer.GrayScale := True;
    Writer.WordSized := False;
    Writer.UseAlpha := False;
    Img.SaveToStream(AStream, Writer);
  finally
    Writer.Free;
    Img.Free;
  end;

  Result := Side;
end;

end.
