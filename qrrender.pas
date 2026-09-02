unit qrrender;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics,
  constants, QlpQrCode, QlpIQrCode;

{ Рисует QR-код для AText в ABitmap.

  Сторона результата — наибольшая, что укладывается в ASizePx при
  ЦЕЛОЧИСЛЕННОМ масштабе модуля. Дробный масштаб даёт модули разной
  ширины и ломает распознавание, поэтому остаток уходит в поля, а не
  в растягивание.

  Возвращает фактическую сторону в пикселях, 0 при неудаче.
  Центрирование — забота вызывающего (TImage.Center := True). }
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

  { EncodeText сам выберет оптимальный режим сегмента.
    Кодировка задаётся явно — библиотека падает, если передать nil. }
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

  { Цвета жёстко чёрный на белом, а не clWindow/clWindowText:
    в тёмной теме получилась бы инверсия, которую большинство
    телефонов не читает. }
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
