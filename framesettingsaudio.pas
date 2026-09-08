unit framesettingsaudio;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uiframe, audiodevices;

type

  { TFrameSettingsAudio

    The "Audio" section of the settings window — selects the audio
    output device. Clicking a device selects it immediately and
    persists the choice to config.ini/[audio] via
    FormMain.SetAudioDeviceName. }

  TFrameSettingsAudio = class(TFrameBase)
    lbDevices: TListBox;
    procedure lbDevicesSelectionChange(Sender: TObject; User: boolean);
  protected
    procedure DoActivate; override;
  private
    { Suppresses writing to config.ini while the list is being rebuilt
      programmatically (RefreshDevices sets ItemIndex itself) — only a
      real user selection should be written. }
    FLoading: boolean;
    procedure RefreshDevices;
  end;

implementation

{$R *.lfm}

{ main is used only in the implementation section, not the interface,
  to avoid a circular unit dependency — FormMain is the single source
  of truth for the selected device (AudioDeviceName/SetAudioDeviceName). }
uses
  main;

{ TFrameSettingsAudio }

procedure TFrameSettingsAudio.DoActivate;
begin
  RefreshDevices;
end;

procedure TFrameSettingsAudio.RefreshDevices;
var
  Devs: TAudioDeviceArray;
  I, Sel: integer;
  CurName: string;
begin
  Devs := EnumAudioOutputDevices;
  CurName := FormMain.AudioDeviceName;

  FLoading := True;
  try
    lbDevices.Items.BeginUpdate;
    try
      lbDevices.Items.Clear;
      if Length(Devs) = 0 then begin
        lbDevices.Items.Add('No audio output devices found');
        lbDevices.Enabled := False;
        Exit;
      end;
      lbDevices.Enabled := True;
      { Nothing saved yet (first run) — default to the first device in
        the system list, which is usually Windows' own default device. }
      Sel := 0;
      for I := 0 to High(Devs) do begin
        lbDevices.Items.Add(Devs[I].Name);
        if (Devs[I].Name = CurName) or ((CurName = '') and (I = 0)) then begin
          Sel := I;
        end;
      end;
      lbDevices.ItemIndex := Sel;
    finally
      lbDevices.Items.EndUpdate;
    end;
  finally
    FLoading := False;
  end;
end;

procedure TFrameSettingsAudio.lbDevicesSelectionChange(Sender: TObject; User: boolean);
begin
  if FLoading or (not User) or (lbDevices.ItemIndex < 0) then begin
    Exit;
  end;
  FormMain.SetAudioDeviceName(lbDevices.Items[lbDevices.ItemIndex]);
end;

end.
