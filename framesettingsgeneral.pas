unit framesettingsgeneral;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ColorBox, uiframe;

type

  { TFrameSettingsGeneral

    The "General" section of the settings window (TFormSettings).
    Checking/unchecking chkCloseToTray writes straight through to
    FormMain.SetCloseToTray, the same "select it, it's saved" pattern
    already used by the Audio section's device list — no separate Save
    step. edtDeviceModel — the app name shown in Telegram's own Active
    Sessions list — saves the same way, just on OnExit rather than on
    every keystroke (a text field, unlike a checkbox/list click, has no
    single "the user just chose this" moment other than leaving it).
    cbAccentColor — the app-wide accent color (currently: the photo/
    video download progress bar's fill, framehistory.pas) — the same
    "select it, it's saved" pattern as chkCloseToTray, via
    FormMain.SetAccentColor. TColorBox (ColorBox, standard LCL, no
    extra package) rather than a hand-rolled swatch+TColorDialog: its
    built-in cbCustomColor style already gives a "Custom..." entry that
    opens a color dialog on its own — no dialog-handling code needed
    here at all.
    cbSurfaceColor — the app's background surface, what the chat-list
    cards, the chat info bar and the input box float on (see
    FormMain.SurfaceColor). Same widget and the same immediate save,
    with one deliberate difference: its Style also includes
    cbSystemColors, so clBtnFace — the default, the one value that
    keeps following the Windows theme instead of freezing a grey — is
    actually selectable, not just the initial state. }

  TFrameSettingsGeneral = class(TFrameBase)
    chkCloseToTray: TCheckBox;
    edtDeviceModel: TEdit;
    lblDeviceModel: TLabel;
    lblAccentColor: TLabel;
    cbAccentColor: TColorBox;
    lblSurfaceColor: TLabel;
    cbSurfaceColor: TColorBox;
    procedure chkCloseToTrayChange(Sender: TObject);
    procedure edtDeviceModelExit(Sender: TObject);
    procedure cbAccentColorChange(Sender: TObject);
    procedure cbSurfaceColorChange(Sender: TObject);
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
    cbAccentColor.Selected := FormMain.AccentColor;
    cbSurfaceColor.Selected := FormMain.SurfaceColor;
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

procedure TFrameSettingsGeneral.cbAccentColorChange(Sender: TObject);
begin
  if FLoading then begin
    Exit;
  end;
  FormMain.SetAccentColor(cbAccentColor.Selected);
end;

procedure TFrameSettingsGeneral.cbSurfaceColorChange(Sender: TObject);
begin
  if FLoading then begin
    Exit;
  end;
  { Takes effect on the open window immediately (SetSurfaceColor
    repaints), so the choice can be judged against the real UI rather
    than a swatch. }
  FormMain.SetSurfaceColor(cbSurfaceColor.Selected);
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
