unit avatarcache;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Types, Graphics, fgl,
  BGRABitmap, BGRABitmapTypes,
  constants, tdchats;

type
  TAvatarKind = (akNone, akThumb, akReal);

  TAvatarEntry = class
  public
    ChatId:   Int64;
    Bmp:      TBGRABitmap;
    Kind:     TAvatarKind;
    LastUse:  QWord;
    destructor Destroy; override;
  end;

  TEntryMap = specialize TFPGMap<Int64, TAvatarEntry>;

  { TAvatarCache

    Отдаёт готовый к отрисовке битмап для строки списка. Порядок
    предпочтения: скачанный файл -> мини-превью из апдейта -> инициалы.
    Пока настоящая аватарка качается, показывается размытое превью —
    пустых кружков не будет. }

  TAvatarCache = class
  private
    FMap: TEntryMap;
    FTick: QWord;
    FCapacity: integer;
    FRound: boolean;
    function Render(ARow: TChatRow; out AKind: TAvatarKind): TBGRABitmap;
    procedure Evict;
  public
    constructor Create;
    destructor Destroy; override;

    { Битмап для строки. Владелец — кэш, освобождать не нужно.
      Может вернуть nil, если отрисовать не удалось.
      Рисовать через Bmp.Draw(Canvas, X, Y, False) — False включает
      смешивание по альфе, ради которого всё и затевалось. }
    function Get(ARow: TChatRow): TBGRABitmap;
    { Выбросить запись — зовётся, когда докачалась настоящая аватарка. }
    procedure Drop(AChatId: Int64);
    procedure Clear;

    property Capacity: integer read FCapacity write FCapacity;
    { Круглые аватарки. Форма задаётся сглаженной альфа-маской,
      поэтому края мягкие на любом фоне. }
    property RoundAvatars: boolean read FRound write FRound;
  end;

{ Устойчивый цвет по id чата — как в Telegram, чтобы у собеседника
  без фото кружок всегда был одного цвета. }
function AvatarColor(AId: Int64): TColor;
{ До двух заглавных букв из заголовка, с учётом UTF-8. }
function AvatarInitials(const ATitle: utf8string): utf8string;

{ Отрисовка аватарки без всякого кэша — нужна и списку чатов,
  и меню аккаунтов. Порядок предпочтения: скачанный файл,
  мини-превью из апдейта, инициалы на цветном круге.
  Результат принадлежит вызывающему. }
function RenderAvatarBmp(const APath: utf8string; const AThumb: RawByteString;
  const ATitle: utf8string; AId: Int64; ASize: integer; ARound: boolean): TBGRABitmap;

{ Круглая альфа-маска указанного размера. }
procedure ApplyRoundMaskTo(ABmp: TBGRABitmap; ASize: integer);

implementation

destructor TAvatarEntry.Destroy;
begin
  Bmp.Free;
  inherited Destroy;
end;

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

{ Длина UTF-8 символа по ведущему байту. }
function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;   { байт-продолжение в начале — строка битая, берём один }
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
  { Работаем строго в utf8string и по байтам. Заход в string и обратно
    зависел бы от DefaultSystemCodePage и резал многобайтные символы. }
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
      { Заглавную делаем только для ASCII: правила для кириллицы
        и прочего потребовали бы таблиц, а первая буква имени
        и так почти всегда заглавная. }
      if (N = 1) and (Ch[1] >= 'a') and (Ch[1] <= 'z') then begin
        Ch[1] := UpCase(Ch[1]);
      end;
      Result := Result + Ch;
      Inc(Words);
    end;

    Inc(I, N);
  end;
end;


{ ---------------- отрисовка без кэша ---------------- }

procedure ApplyRoundMaskTo(ABmp: TBGRABitmap; ASize: integer);
var
  Mask: TBGRABitmap;
  C, R: single;
begin
  if ABmp = nil then begin
    Exit;
  end;
  { Координаты центрированы по пикселю: центр — (N-1)/2, радиус — N/2.
    Иначе круг вылезает за правый и нижний край и срезается. }
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

function RenderAvatarBmp(const APath: utf8string; const AThumb: RawByteString;
  const ATitle: utf8string; AId: Int64; ASize: integer; ARound: boolean): TBGRABitmap;
var
  Src: TBGRABitmap;
  Ms: TMemoryStream;
begin
  Result := nil;

  { 1. Настоящая аватарка, если уже скачана. }
  if (APath <> '') and FileExists(string(APath)) then begin
    Src := nil;
    try
      try
        Src := TBGRABitmap.Create(string(APath));
        Result := ScaleSquare(Src, ASize);
      except
        FreeAndNil(Result);
      end;
    finally
      Src.Free;
    end;
    if Result <> nil then begin
      if ARound then begin
        ApplyRoundMaskTo(Result, ASize);
      end;
      Exit;
    end;
  end;

  { 2. Мини-превью — приходит прямо в апдейте, качать нечего. }
  if AThumb <> '' then begin
    Ms := TMemoryStream.Create;
    Src := nil;
    try
      try
        Ms.WriteBuffer(AThumb[1], Length(AThumb));
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
    if Result <> nil then begin
      if ARound then begin
        ApplyRoundMaskTo(Result, ASize);
      end;
      Exit;
    end;
  end;

  { 3. Инициалы на цветном круге. }
  Result := RenderInitialsBmp(ATitle, AId, ASize, ARound);
end;

{ ---------------- TAvatarCache ---------------- }

constructor TAvatarCache.Create;
begin
  inherited Create;
  FMap := TEntryMap.Create;
  FMap.Sorted := True;
  FCapacity := DEFAULT_CAPACITY;
  FRound := True;
  FTick := 0;
end;

destructor TAvatarCache.Destroy;
begin
  Clear;
  FMap.Free;
  inherited Destroy;
end;

procedure TAvatarCache.Clear;
var
  I: integer;
begin
  for I := 0 to FMap.Count - 1 do begin
    FMap.Data[I].Free;
  end;
  FMap.Clear;
end;

procedure TAvatarCache.Drop(AChatId: Int64);
var
  Idx: integer;
begin
  Idx := FMap.IndexOf(AChatId);
  if Idx >= 0 then begin
    FMap.Data[Idx].Free;
    FMap.Delete(Idx);
  end;
end;

procedure TAvatarCache.Evict;
var
  I, Victim: integer;
  Oldest: QWord;
begin
  while FMap.Count > FCapacity do begin
    Victim := 0;
    Oldest := High(QWord);
    for I := 0 to FMap.Count - 1 do begin
      if FMap.Data[I].LastUse < Oldest then begin
        Oldest := FMap.Data[I].LastUse;
        Victim := I;
      end;
    end;
    FMap.Data[Victim].Free;
    FMap.Delete(Victim);
  end;
end;

function TAvatarCache.Render(ARow: TChatRow; out AKind: TAvatarKind): TBGRABitmap;
begin
  { Вся отрисовка вынесена в RenderAvatarBmp — её же использует
    меню аккаунтов для своих глифов. }
  Result := RenderAvatarBmp(ARow.PhotoPath, ARow.Minithumb, ARow.Title,
    ARow.Id, AVATAR_SIZE, FRound);

  if (ARow.PhotoPath <> '') and FileExists(string(ARow.PhotoPath)) then begin
    AKind := akReal;
  end else if ARow.Minithumb <> '' then begin
    AKind := akThumb;
  end else begin
    AKind := akNone;
  end;
end;

function TAvatarCache.Get(ARow: TChatRow): TBGRABitmap;
var
  Idx: integer;
  E: TAvatarEntry;
  K: TAvatarKind;
  B: TBGRABitmap;
begin
  Result := nil;
  if ARow = nil then begin
    Exit;
  end;

  Inc(FTick);
  Idx := FMap.IndexOf(ARow.Id);
  if Idx >= 0 then begin
    E := FMap.Data[Idx];
    { Если в кэше лежит превью, а настоящая уже скачалась —
      перерисовываем. }
    if (E.Kind <> akReal) and (ARow.PhotoPath <> '') then begin
      FMap.Data[Idx].Free;
      FMap.Delete(Idx);
    end else begin
      E.LastUse := FTick;
      Result := E.Bmp;
      Exit;
    end;
  end;

  B := Render(ARow, K);
  if B = nil then begin
    Exit;
  end;

  E := TAvatarEntry.Create;
  E.ChatId := ARow.Id;
  E.Bmp := B;
  E.Kind := K;
  E.LastUse := FTick;
  FMap.Add(ARow.Id, E);
  Evict;

  Result := B;
end;

end.
