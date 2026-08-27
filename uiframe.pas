unit uiframe;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms;

type

  { TFrameBase

    Предок всех экранов рабочей области. DoActivate/DoDeactivate
    перекрываются потомками; публичные Activate/Deactivate следят,
    чтобы хук не вызвался дважды подряд. }

  TFrameBase = class(TFrame)
  private
    FActivated: boolean;
  protected
    { Фрейм стал видимым. Здесь уместно догрузить данные. }
    procedure DoActivate; virtual;
    { Фрейм скрыли. Состояние сохраняется — фрейм не уничтожается. }
    procedure DoDeactivate; virtual;
  public
    procedure Activate;
    procedure Deactivate;
    property Activated: boolean read FActivated;
  end;

  TFrameBaseClass = class of TFrameBase;

  { TFrameNavigator

    Держит фреймы внутри контейнера. Создаёт лениво при первом показе
    и кэширует: повторный вызов ShowFrame только переключает Visible,
    поэтому позиция прокрутки и прочее состояние переживают уход
    и возврат на экран.

    Владельцем фреймов назначается контейнер — их освободит LCL вместе
    с формой. Навигатор их только отслеживает и сам не освобождает,
    иначе получили бы двойное освобождение. }

  TFrameNavigator = class
  private
    FContainer: TWinControl;
    FFrames:    TFPList;
    FCurrent:   TFrameBase;
    function Find(AClass: TFrameBaseClass): TFrameBase;
  public
    constructor Create(AContainer: TWinControl);
    destructor Destroy; override;

    function ShowFrame(AClass: TFrameBaseClass): TFrameBase;
    procedure HideCurrent;

    property Current: TFrameBase read FCurrent;
    property Container: TWinControl read FContainer;
  end;

implementation

{ ---------------- TFrameBase ---------------- }

procedure TFrameBase.DoActivate;
begin
  { потомки перекрывают }
end;

procedure TFrameBase.DoDeactivate;
begin
  { потомки перекрывают }
end;

procedure TFrameBase.Activate;
begin
  if FActivated then begin
    Exit;
  end;
  FActivated := True;
  DoActivate;
end;

procedure TFrameBase.Deactivate;
begin
  if not FActivated then begin
    Exit;
  end;
  FActivated := False;
  DoDeactivate;
end;

{ ---------------- TFrameNavigator ---------------- }

constructor TFrameNavigator.Create(AContainer: TWinControl);
begin
  inherited Create;
  FContainer := AContainer;
  FFrames  := TFPList.Create;
  FCurrent := nil;
end;

destructor TFrameNavigator.Destroy;
begin
  { Фреймы не освобождаем: их владелец — контейнер. }
  FFrames.Free;
  inherited Destroy;
end;

function TFrameNavigator.Find(AClass: TFrameBaseClass): TFrameBase;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to FFrames.Count - 1 do begin
    if TObject(FFrames[I]).ClassType = AClass then begin
      Result := TFrameBase(FFrames[I]);
      Exit;
    end;
  end;
end;

function TFrameNavigator.ShowFrame(AClass: TFrameBaseClass): TFrameBase;
var
  F: TFrameBase;
begin
  Result := FCurrent;
  if (FContainer = nil) or (AClass = nil) then begin
    Exit;
  end;

  F := Find(AClass);
  if (F <> nil) and (F = FCurrent) then begin
    Exit;
  end;

  HideCurrent;

  if F = nil then begin
    F := AClass.Create(FContainer);
    F.Parent := FContainer;
    F.Align := alClient;
    FFrames.Add(F);
  end;

  F.Visible := True;
  F.BringToFront;
  FCurrent := F;
  F.Activate;

  Result := F;
end;

procedure TFrameNavigator.HideCurrent;
begin
  if FCurrent = nil then begin
    Exit;
  end;
  FCurrent.Deactivate;
  FCurrent.Visible := False;
  FCurrent := nil;
end;

end.
