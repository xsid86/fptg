unit framesettingsgeneral;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uiframe;

type

  { TFrameSettingsGeneral

    The "General" section of the settings window (TFormSettings).
    Checking/unchecking chkCloseToTray writes straight through to
    FormMain.SetCloseToTray, the same "select it, it's saved" pattern
    already used by the Audio section's device list — no separate Save
    step. }

  TFrameSettingsGeneral = class(TFrameBase)
    chkCloseToTray: TCheckBox;
    procedure chkCloseToTrayChange(Sender: TObject);
  protected
    procedure DoActivate; override;
  private
    { Suppresses writing to config.ini while Checked is being set from
      FormMain.CloseToTray in DoActivate — same guard as
      TFrameSettingsAudio.FLoading. }
    FLoading: boolean;
  end;

implementation

{$R *.lfm}

{ main is used only in the implementation section, not the interface,
  to avoid a circular unit dependency — same pattern as
  framesettingsaudio.pas. }
uses
  main;

{ TFrameSettingsGeneral }

procedure TFrameSettingsGeneral.DoActivate;
begin
  FLoading := True;
  try
    chkCloseToTray.Checked := FormMain.CloseToTray;
  finally
    FLoading := False;
  end;
end;

procedure TFrameSettingsGeneral.chkCloseToTrayChange(Sender: TObject);
begin
  if FLoading then begin
    Exit;
  end;
  FormMain.SetCloseToTray(chkCloseToTray.Checked);
end;

end.
