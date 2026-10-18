unit appid;

{$mode objfpc}{$H+}

{ Who Windows thinks is notifying.

  The tray balloon (LCL's TTrayIcon.ShowBalloonHint) is a plain
  Shell_NotifyIcon with NIF_INFO — checked in the widgetset source,
  lcl/interfaces/win32/win32trayicon.inc. On Windows 10 and 11 the
  shell turns that into a toast, and a toast is filed under the
  sending process's AppUserModelID: that ID is what the notification's
  header shows and what Action Center keeps the entry under.

  With no explicit ID Windows makes one up from the executable, which
  is why the header read "tg.exe" and why the notifications went
  nowhere after their few seconds on screen: an application the shell
  cannot name is not one it will keep a history for.

  Two halves, and BOTH are required — one without the other changes
  nothing:

    * the process declares its ID (SetCurrentProcessExplicitAppUserModelID);
    * a Start-menu shortcut carries the same ID, which is where the
      shell reads the display name and the icon from.

  The shortcut is written once, into the user's own Start menu, and
  the application becomes launchable from Start as a side effect. }

interface

{ Called once, as early as possible: the ID has to be set before
  anything creates a window or a tray icon. Never raises — an
  application that cannot name itself is still an application. }
procedure EnsureAppId;

implementation

uses
  Windows, SysUtils, ActiveX, ShlObj, ComObj, constants, guiconst;

const
  { Any unique string; the convention is Company.Product. It never
    reaches the user's eyes - the shortcut's NAME is what is shown. }
  APP_USER_MODEL_ID = 'Avenix.fptg';
  { And the shortcut, whose file name IS the name in the notification's
    header. }
  SHORTCUT_NAME = APP_TITLE + '.lnk';

  { PKEY_AppUserModel_ID, from propkey.h. }
  PKEY_APPUSERMODEL_ID: PROPERTYKEY = (
    fmtid: (D1: $9F4C2855; D2: $9F79; D3: $4B39;
            D4: ($A8, $D0, $E1, $D4, $2D, $E1, $D5, $F3));
    pid: 5);

type
  TSetAppId = function(AppID: PWideChar): HRESULT; stdcall;

{ Dynamically, not by import: the application must still start on a
  Windows without it rather than fail to load. }
procedure DeclareId;
var
  Lib: THandle;
  Proc: TSetAppId;
begin
  Lib := LoadLibrary('shell32.dll');
  if Lib = 0 then begin
    Exit;
  end;
  try
    Proc := TSetAppId(GetProcAddress(Lib, 'SetCurrentProcessExplicitAppUserModelID'));
    if Assigned(Proc) then begin
      Proc(PWideChar(WideString(APP_USER_MODEL_ID)));
    end;
  finally
    { Not freed: the process keeps shell32 loaded anyway, and
      unloading it under the shell's feet is a worse idea than the
      handle. }
  end;
end;

function StartMenuPath(const AName: WideString): WideString;
var
  Buf: array[0..MAX_PATH] of WideChar;
begin
  Result := '';
  if SHGetSpecialFolderPathW(0, @Buf[0], CSIDL_PROGRAMS, False) then begin
    Result := WideString(Buf) + '\' + AName;
  end;
end;

{ A shortcut of the former name (APP_TITLE_LEGACY) points to tg.exe, which
  is gone, and holds the old AppUserModelID — remove it. }
procedure DropLegacyShortcut;
var
  Path: WideString;
begin
  Path := StartMenuPath(WideString(APP_TITLE_LEGACY) + '.lnk');
  if (Path <> '') and FileExists(string(Path)) then begin
    DeleteFile(string(Path));
  end;
end;

{ The shortcut the shell reads our name and icon from. Written only
  when it is missing: this runs on every start. }
procedure EnsureShortcut(const APath: WideString);
var
  Link: IShellLinkW;
  Props: IPropertyStore;
  Store: IPersistFile;
  Value: TPropVariant;
  Exe: WideString;
begin
  if (APath = '') or FileExists(string(APath)) then begin
    Exit;
  end;
  Exe := WideString(ParamStr(0));

  Link := CreateComObject(CLSID_ShellLink) as IShellLinkW;
  OleCheck(Link.SetPath(PWideChar(Exe)));
  OleCheck(Link.SetWorkingDirectory(PWideChar(WideString(ExtractFilePath(ParamStr(0))))));
  OleCheck(Link.SetDescription(PWideChar(WideString(APP_TITLE))));

  { The whole point of the shortcut. Without this property it is an
    ordinary shortcut and the shell still cannot tie the toast to it. }
  Props := Link as IPropertyStore;
  FillChar(Value, SizeOf(Value), 0);
  Value.vt := VT_LPWSTR;
  Value.pwszVal := PWideChar(WideString(APP_USER_MODEL_ID));
  OleCheck(Props.SetValue(@PKEY_APPUSERMODEL_ID, @Value));
  OleCheck(Props.Commit);

  Store := Link as IPersistFile;
  OleCheck(Store.Save(PWideChar(APath), True));
end;

procedure EnsureAppId;
var
  Started: boolean;
  Hr: HRESULT;
begin
  DeclareId;

  { COM for the shortcut only. S_FALSE means someone got here first,
    which is fine and must NOT be answered with a CoUninitialize. }
  Hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  Started := Hr = S_OK;
  try
    try
      DropLegacyShortcut;
      EnsureShortcut(StartMenuPath(SHORTCUT_NAME));
    except
      { A missing shortcut costs a nicer notification header, nothing
        more. It is not worth refusing to start over. }
      on E: Exception do begin
      end;
    end;
  finally
    if Started then begin
      CoUninitialize;
    end;
  end;
end;

end.
