unit framesettingsaudio;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uiframe, audiodevices;

type

  { TFrameSettingsAudio

    Раздел "Audio" окна настроек — выбор устройства вывода звука.
    Перенесено из главного меню (было: TFormMain.RebuildAudioDeviceMenu/
    AudioDeviceItemClick, пункты прямо в пустом MenuItem5 "Settings") —
    то же самое поведение (клик по устройству сразу его выбирает и
    персистит в config.ini/[audio] через FormMain.SetAudioDeviceName),
    просто TListBox вместо подменю с TRadioItem/GroupIndex. }

  TFrameSettingsAudio = class(TFrameBase)
    lbDevices: TListBox;
    procedure lbDevicesSelectionChange(Sender: TObject; User: boolean);
  protected
    procedure DoActivate; override;
  private
    { Подавляет запись в config.ini, пока список переcтраивается
      программно (RefreshDevices сама выставляет ItemIndex) — писать
      нужно только на настоящий выбор пользователя. }
    FLoading: boolean;
    procedure RefreshDevices;
  end;

implementation

{$R *.lfm}

{ main — только в реализации, не в интерфейсе: тот же приём, что и у
  framehistory.pas (FormMain.Chats/FormMain.Nav) — FormMain уже хранит
  единственный источник правды для выбранного устройства
  (AudioDeviceName/SetAudioDeviceName), второй не заводим. }
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
      { Ничего не сохранено (первый запуск) — по умолчанию первое
        устройство в системном списке, как обычно и есть устройство
        "по умолчанию" в Windows. Та же логика, что была в
        AudioDeviceItemClick/RebuildAudioDeviceMenu. }
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
