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

{ Lists audio output devices via the Windows MME API (winmm.dll, no
  extra dependencies) — the same list shown by the Windows sound
  control panel. Id is the MME positional index, stable only within a
  single process run; device selection is persisted by name (see
  main.pas), not by Id. }
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
