unit uiframe;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms;

type

  { TFrameBase

    Base class for all work-area screens. DoActivate/DoDeactivate are
    overridden by descendants; the public Activate/Deactivate ensure
    the hook is never called twice in a row. }

  TFrameBase = class(TFrame)
  private
    FActivated: boolean;
  protected
    { The frame became visible. A good place to lazily load data. }
    procedure DoActivate; virtual;
    { The frame was hidden. State is preserved — the frame is not
      destroyed. }
    procedure DoDeactivate; virtual;
  public
    procedure Activate;
    procedure Deactivate;
    property Activated: boolean read FActivated;
  end;

  TFrameBaseClass = class of TFrameBase;

  { TFrameNavigator

    Holds frames inside a container. Creates each frame lazily on
    first display and caches it: a repeat ShowFrame call only toggles
    Visible, so scroll position and other state survive leaving and
    returning to the screen.

    The container is the frames' owner — LCL frees them together with
    the form. The navigator only tracks them and never frees them
    itself, which would double-free. }

  TFrameNavigator = class
  private
    FContainer: TWinControl;
    FFrames:    TFPList;
    FCurrent:   TFrameBase;
  public
    constructor Create(AContainer: TWinControl);
    destructor Destroy; override;

    { Public — for callers that want an already-created (visited)
      frame directly, without going through ShowFrame (which also
      shows/hides). Example: TFormSettings.btnSaveClick — only a
      section the user actually opened needs saving; Find(AClass) =
      nil means "never opened, nothing to save". }
    function Find(AClass: TFrameBaseClass): TFrameBase;
    function ShowFrame(AClass: TFrameBaseClass): TFrameBase;
    procedure HideCurrent;

    property Current: TFrameBase read FCurrent;
    property Container: TWinControl read FContainer;
  end;

implementation

{ ---------------- TFrameBase ---------------- }

procedure TFrameBase.DoActivate;
begin
  { overridden by descendants }
end;

procedure TFrameBase.DoDeactivate;
begin
  { overridden by descendants }
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
  { Frames are not freed here: the container owns them. }
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
