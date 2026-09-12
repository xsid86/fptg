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
    step. edtDeviceModel — the app name shown in Telegram's own Active
    Sessions list — saves the same way, just on OnExit rather than on
    every keystroke (a text field, unlike a checkbox/list click, has no
    single "the user just chose this" moment other than leaving it). }

  TFrameSettingsGeneral = class(TFrameBase)
    chkCloseToTray: TCheckBox;
    edtDeviceModel: TEdit;
    lblDeviceModel: TLabel;
    procedure chkCloseToTrayChange(Sender: TObject);
    procedure edtDeviceModelExit(Sender: TObject);
  protected
    procedure DoActivate; override;
  private
    { Suppresses writing to config.ini while Checked/Text are being set
      from FormMain.CloseToTray/TdApp.DeviceModel in DoActivate — same
      guard as TFrameSettingsAudio.FLoading. }
    FLoading: boolean;
  end;

implementation

{$R *.lfm}

{ main/tdcore are used only in the implementation section, not the
  interface, to avoid a circular unit dependency — same pattern as
  framesettingsaudio.pas. }
uses
  main, tdcore;

{ TFrameSettingsGeneral }

procedure TFrameSettingsGeneral.DoActivate;
begin
  FLoading := True;
  try
    chkCloseToTray.Checked := FormMain.CloseToTray;
    edtDeviceModel.Text := string(TdApp.DeviceModel);
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

procedure TFrameSettingsGeneral.edtDeviceModelExit(Sender: TObject);
var
  Trimmed: string;
begin
  if FLoading then begin
    Exit;
  end;
  { An empty field isn't a valid device name to send TDLib — left as
    whatever was last saved rather than persisting blank, but the box
    itself is not forced back to the old text: the user can still see
    and fix what they typed. }
  Trimmed := Trim(edtDeviceModel.Text);
  if Trimmed = '' then begin
    Exit;
  end;
  TdApp.SetDeviceModel(utf8string(Trimmed));
end;

end.
