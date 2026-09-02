unit tdaccentcolors;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, fpjson,
  constants, tdauth, tdsession, tdreq;

type
  TAccentColorEntry = record
    Id: integer;
    Color: TColor;
  end;

  TTdAccentColorsEvent = procedure(Sender: TObject) of object;

  { TTdAccentColors

    Пассивный кэш «id акцентного цвета -> RGB» из updateAccentColors —
    TDLib присылает его сам, без отдельного RPC-запроса (в схеме
    td_api.tl нет функции getAccentColors, только апдейт). Проверено
    напрямую по схеме (github.com/tdlib/td, td_api.tl) и по
    tdlib_raw.log этого проекта — не предположение.

    id 0..6 — зарезервированные "базовые" цвета: red/orange/violet/
    green/cyan/blue/pink, в этом порядке (core.telegram.org/api/colors).
    Для них TDLib НЕ шлёт отдельных записей с RGB вообще — только id 7
    и выше приходят в updateAccentColors.colors с реальными
    light_theme_colors/dark_theme_colors. Точных официальных hex для
    0..6 нигде в схеме/документации нет — ниже разумное приближение по
    названию цвета, не официальное значение. }
  TTdAccentColors = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FEntries: array of TAccentColorEntry;
    FOnChanged: TTdAccentColorsEvent;
    procedure ApplyColors(AArr: TJSONArray);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession); reintroduce;
    destructor Destroy; override;

    { False, если id ещё не известен вовсе (апдейт updateAccentColors
      ещё не приходил и это не 0..6) — вызывающий сам решает, чем
      закрашивать взамен (см. framehistory.pas: падает на
      SENDER_PALETTE). }
    function TryGetColor(AId: integer; out AColor: TColor): boolean;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property OnChanged: TTdAccentColorsEvent read FOnChanged write FOnChanged;
  end;

implementation

constructor TTdAccentColors.Create(AOwner: TComponent; const ASession: ITdSession);
begin
  inherited Create(AOwner);
  FSession := ASession;
  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdAccentColors.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  inherited Destroy;
end;

function TTdAccentColors.TryGetColor(AId: integer; out AColor: TColor): boolean;
var
  I: integer;
begin
  Result := False;
  AColor := clNone;
  if (AId >= Low(BUILT_IN_COLORS)) and (AId <= High(BUILT_IN_COLORS)) then begin
    AColor := BUILT_IN_COLORS[AId];
    Result := True;
    Exit;
  end;
  for I := 0 to High(FEntries) do begin
    if FEntries[I].Id = AId then begin
      AColor := FEntries[I].Color;
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdAccentColors.ApplyColors(AArr: TJSONArray);
var
  I, N, Id, PackedRGB: integer;
  Item: TJSONObject;
  Colors: TJSONArray;
begin
  if AArr = nil then begin
    Exit;
  end;
  SetLength(FEntries, AArr.Count);
  N := 0;
  for I := 0 to AArr.Count - 1 do begin
    if AArr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    Item := TJSONObject(AArr.Items[I]);
    Id := JGetInt(Item, 'id');
    Colors := JGetArr(Item, 'light_theme_colors');
    if (Colors = nil) or (Colors.Count = 0) then begin
      Continue;
    end;
    { Первый цвет — основной; остальные (у некоторых записей 2-3) —
      градиент, не нужен для сплошной заливки. }
    PackedRGB := Colors.Items[0].AsInteger;
    FEntries[N].Id := Id;
    FEntries[N].Color := RGBToColor((PackedRGB shr 16) and $FF, (PackedRGB shr 8) and $FF, PackedRGB and $FF);
    Inc(N);
  end;
  SetLength(FEntries, N);
end;

procedure TTdAccentColors.TdUpdate(const AJson: utf8string; AData: TJSONObject);
begin
  if AData = nil then begin
    Exit;
  end;
  if JGetStr(AData, '@type') = 'updateAccentColors' then begin
    ApplyColors(JGetArr(AData, 'colors'));
    if Assigned(FOnChanged) then begin
      FOnChanged(Self);
    end;
  end;
end;

procedure TTdAccentColors.TdStateChanged(AState: TTdAuthState);
begin
  if TdIsShuttingState(AState) then begin
    SetLength(FEntries, 0);
  end;
end;

procedure TTdAccentColors.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации модели не касаются. }
end;

end.
