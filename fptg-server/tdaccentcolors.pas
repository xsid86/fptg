unit tdaccentcolors;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson,
  constants, tdauth, tdsession, tdreq;

type
  TAccentColorEntry = record
    Id: integer;
    Color: TTdColor;
  end;

  TTdAccentColorsEvent = procedure(Sender: TObject) of object;

  { TTdAccentColors

    Passive cache of "accent color id -> RGB" from updateAccentColors —
    TDLib pushes it on its own, with no dedicated RPC call.

    Ids 0..6 are the reserved "built-in" colors: red/orange/violet/
    green/cyan/blue/pink, in this order (core.telegram.org/api/colors).
    TDLib never sends explicit RGB entries for these — only id 7 and
    above arrive in updateAccentColors.colors with real
    light_theme_colors/dark_theme_colors. No official hex values for
    0..6 are published anywhere; BUILT_IN_COLORS below is a reasonable
    approximation by color name, not an official value. }
  TTdAccentColors = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FEntries: array of TAccentColorEntry;
    FOnChanged: TTdAccentColorsEvent;
    procedure ApplyColors(AArr: TJSONArray);
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession); reintroduce;
    destructor Destroy; override;

    { Returns False if the id is not known yet (no updateAccentColors
      for it has arrived, and it's not 0..6) — the caller decides what
      fallback color to use (see framehistory.pas: falls back to
      SENDER_PALETTE). }
    function TryGetColor(AId: integer; out AColor: TTdColor): boolean;

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

function TTdAccentColors.TryGetColor(AId: integer; out AColor: TTdColor): boolean;
var
  I: integer;
begin
  Result := False;
  AColor := 0;
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
    { The first color is the main one; the rest (2-3 in some entries)
      form a gradient, not needed for a solid fill. }
    PackedRGB := Colors.Items[0].AsInteger;
    FEntries[N].Id := Id;
    { $RRGGBB -> $00BBGGRR }
    FEntries[N].Color := TTdColor(((PackedRGB shr 16) and $FF)
      or (PackedRGB and $FF00) or ((PackedRGB and $FF) shl 16));
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
  { Authorization errors don't concern this model. }
end;

end.
