unit avatarcache;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, Graphics,
  BGRABitmap, BGRABitmapTypes,
  guiconst;

{ A color derived deterministically from the chat id, so a contact
  without a photo always gets the same colored circle, as in Telegram. }
function AvatarColor(AId: Int64): TColor;
{ Up to two capital letters from the title, UTF-8 aware. }
function AvatarInitials(const ATitle: utf8string): utf8string;

{ Аватарка для карточки на рабочем столе. Порядок: настоящее фото,
  миниатюра, инициалы на цветном круге. Фото и миниатюра — байты
  картинки (их присылает страница: файлы — на сервере, который может
  быть и на другой машине). Результат — вызывающему. }
function RenderAvatarBmp(const APhoto: RawByteString; const AThumb: RawByteString;
  const ATitle: utf8string; AId: Int64; ASize: integer; ARound: boolean): TBGRABitmap;

{ A round alpha mask of the given size. }
procedure ApplyRoundMaskTo(ABmp: TBGRABitmap; ASize: integer);

implementation

function AvatarColor(AId: Int64): TColor;
var
  K: Int64;
begin
  K := AId;
  if K < 0 then begin
    K := -K;
  end;
  Result := PALETTE[K mod Length(PALETTE)];
end;

{ UTF-8 character length from its leading byte. }
function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;   { a continuation byte at the start — malformed string, take one }
  end else if AByte < $E0 then begin
    Result := 2;
  end else if AByte < $F0 then begin
    Result := 3;
  end else begin
    Result := 4;
  end;
end;

function AvatarInitials(const ATitle: utf8string): utf8string;
var
  I, L, N, Words: integer;
  Ch: utf8string;
  InWord: boolean;
begin
  { Operates strictly on utf8string, byte by byte. Converting to
    string and back would depend on DefaultSystemCodePage and could
    cut multi-byte characters. }
  Result := '';
  Words := 0;
  I := 1;
  L := Length(ATitle);
  InWord := False;

  while (I <= L) and (Words < 2) do begin
    if ATitle[I] in [' ', #9, #10, #13] then begin
      InWord := False;
      Inc(I);
      Continue;
    end;

    N := Utf8CharLen(byte(ATitle[I]));
    if I + N - 1 > L then begin
      N := L - I + 1;
    end;

    if not InWord then begin
      InWord := True;
      Ch := Copy(ATitle, I, N);
      { Uppercased only for ASCII: rules for Cyrillic and other
        scripts would require lookup tables, and a name's first letter
        is already capitalized in most cases. }
      if (N = 1) and (Ch[1] >= 'a') and (Ch[1] <= 'z') then begin
        Ch[1] := UpCase(Ch[1]);
      end;
      Result := Result + Ch;
      Inc(Words);
    end;

    Inc(I, N);
  end;
end;


{ ---------------- rendering without a cache ---------------- }

procedure ApplyRoundMaskTo(ABmp: TBGRABitmap; ASize: integer);
var
  Mask: TBGRABitmap;
  C, R: single;
begin
  if ABmp = nil then begin
    Exit;
  end;
  { Coordinates are pixel-centered: center is (N-1)/2, radius is N/2.
    Otherwise the circle would extend past the right/bottom edge and
    get clipped. }
  C := (ASize - 1) / 2;
  R := ASize / 2;
  Mask := TBGRABitmap.Create(ASize, ASize, BGRABlack);
  try
    Mask.FillEllipseAntialias(C, C, R, R, BGRAWhite);
    ABmp.ApplyMask(Mask);
  finally
    Mask.Free;
  end;
end;

function ScaleSquare(ASrc: TBGRABitmap; ASize: integer): TBGRABitmap;
var
  Side, X, Y: integer;
  Sq: TBGRABitmap;
begin
  Result := nil;
  if (ASrc = nil) or (ASrc.Width = 0) or (ASrc.Height = 0) then begin
    Exit;
  end;

  if ASrc.Width <> ASrc.Height then begin
    Side := ASrc.Width;
    if ASrc.Height < Side then begin
      Side := ASrc.Height;
    end;
    X := (ASrc.Width - Side) div 2;
    Y := (ASrc.Height - Side) div 2;
    Sq := ASrc.GetPart(Rect(X, Y, X + Side, Y + Side));
  end else begin
    Sq := nil;
  end;

  try
    if Sq <> nil then begin
      Sq.ResampleFilter := rfBestQuality;
      Result := Sq.Resample(ASize, ASize, rmFineResample);
    end else begin
      ASrc.ResampleFilter := rfBestQuality;
      Result := ASrc.Resample(ASize, ASize, rmFineResample);
    end;
  finally
    Sq.Free;
  end;
end;

function RenderInitialsBmp(const ATitle: utf8string; AId: Int64;
  ASize: integer; ARound: boolean): TBGRABitmap;
var
  Ini: string;
  Sz: TSize;
  C, R: single;
begin
  Result := TBGRABitmap.Create(ASize, ASize, BGRAPixelTransparent);
  C := (ASize - 1) / 2;
  R := ASize / 2;

  if ARound then begin
    Result.FillEllipseAntialias(C, C, R, R, ColorToBGRA(AvatarColor(AId)));
  end else begin
    Result.Fill(ColorToBGRA(AvatarColor(AId)));
  end;

  Ini := string(AvatarInitials(ATitle));
  if Ini = '' then begin
    Exit;
  end;

  Result.FontName := 'default';
  Result.FontHeight := Round(ASize * 0.45);
  Result.FontStyle := [fsBold];
  Result.FontQuality := fqFineAntialiasing;
  Sz := Result.TextSize(Ini);
  Result.TextOut((ASize - Sz.cx) / 2, (ASize - Sz.cy) / 2, Ini, BGRAWhite);
end;

{ Картинка из байтов, сразу в квадрат ASize; nil — не разобралась. }
function BytesToSquare(const ABytes: RawByteString; ASize: integer;
  ARound: boolean): TBGRABitmap;
var
  Src: TBGRABitmap;
  Ms: TMemoryStream;
begin
  Result := nil;
  if ABytes = '' then begin
    Exit;
  end;
  Ms := TMemoryStream.Create;
  Src := nil;
  try
    try
      Ms.WriteBuffer(ABytes[1], Length(ABytes));
      Ms.Position := 0;
      Src := TBGRABitmap.Create(Ms);
      Result := ScaleSquare(Src, ASize);
    except
      FreeAndNil(Result);
    end;
  finally
    Src.Free;
    Ms.Free;
  end;
  if (Result <> nil) and ARound then begin
    ApplyRoundMaskTo(Result, ASize);
  end;
end;

function RenderAvatarBmp(const APhoto: RawByteString; const AThumb: RawByteString;
  const ATitle: utf8string; AId: Int64; ASize: integer; ARound: boolean): TBGRABitmap;
begin
  Result := BytesToSquare(APhoto, ASize, ARound);
  if Result = nil then begin
    Result := BytesToSquare(AThumb, ASize, ARound);
  end;
  if Result <> nil then begin
    Exit;
  end;

  { 3. Initials on a colored circle. }
  Result := RenderInitialsBmp(ATitle, AId, ASize, ARound);
end;

end.
