unit audiodevices;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, MMSystem;

type
  TAudioDeviceInfo = record
    Id:   integer;
    Name: string;
  end;
  TAudioDeviceArray = array of TAudioDeviceInfo;

{ Список устройств вывода звука через системный MME API (winmm.dll,
  часть Windows, без доп. зависимостей). Тот же список, что видит
  панель управления звуком Windows. Id — позиционный индекс MME,
  устойчив только в рамках одного запуска (не хранится сам по себе,
  выбор персистится по имени, см. main.pas). }
function EnumAudioOutputDevices: TAudioDeviceArray;

implementation

function EnumAudioOutputDevices: TAudioDeviceArray;
var
  N, I: integer;
  Caps: TWaveOutCapsW;
begin
  SetLength(Result, 0);
  N := waveOutGetNumDevs;
  if N <= 0 then begin
    Exit;
  end;
  SetLength(Result, N);
  for I := 0 to N - 1 do begin
    Result[I].Id := I;
    if waveOutGetDevCapsW(I, @Caps, SizeOf(Caps)) = MMSYSERR_NOERROR then begin
      Result[I].Name := UTF8Encode(UnicodeString(PWideChar(@Caps.szPname[0])));
    end else begin
      Result[I].Name := Format('Device %d', [I]);
    end;
  end;
end;

end.
