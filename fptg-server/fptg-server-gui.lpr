program fptg_server_gui;

{$mode objfpc}{$H+}

{ The fptg server with a window: the same core as the console fptg-server
  (TDLib, the bridge, HTTPS/WebSocket, sign-in), plus a small control
  window (panel/srvpanel.pas + .lfm) and a tray icon. LCL — in the window
  only; nothing platform-specific — it builds on Windows and Linux.

  One server instance per data folder (instance.pas, shared with the
  console one): if the window is already running, a second start shows it
  and exits; if the console server is running, the window becomes a remote
  control for it.

  The parameters are the same as the console one's: --server-port, --bind,
  --web-dir, --cert/--key. Users are set up in the window. }

uses
  { The memory manager — first, before any allocation (as in
    fptg-server). }
  cmem,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Dialogs, SysUtils, fpjson,
  constants, instance, srvpanel, appdirs, secureconfig;

{$R *.res}

var
  Dir, Err: string;
  Own: boolean;
  Res: TJSONObject;

begin
  { Without this, implicit string conversions go through the system code
    page and lose non-Latin characters. }
  DefaultSystemCodePage := CP_UTF8;

  { The server's data lives in the user profile (appdirs.pas), not next to the exe. }
  Dir := ServerDataDir;
  SecureConfigSetDir(Dir);
  Own := AcquireInstance(Dir, INSTANCE_SERVER);
  { The server is already running from another copy or under another OS
    user — there is no remote control to it from here, and a second one on
    the machine is not needed. }
  if (not Own) and InstanceElsewhere then begin
    Application.Initialize;
    MessageDlg(APP_TITLE + ' server',
      'An fptg server is already running on this computer (another copy '
      + 'or another user). Only one can run per computer.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if (not Own) and (InstanceKind(Dir, INSTANCE_SERVER) = 'gui') then begin
    { The window is already open — show it, a second one is not needed. }
    if CallInstance(Dir, INSTANCE_SERVER, 'show', nil, Res, Err) then begin
      Res.Free;
    end;
    Exit;
  end;

  RequireDerivedFormResource := True;
  Application.Scaled:=True;
  Application.Initialize;
  Application.CreateForm(TFormServerPanel, FormServerPanel);
  if Own then begin
    FormServerPanel.InitLocal;
  end else begin
    FormServerPanel.InitRemote;
  end;
  { The main form closes only to the tray (FormCloseQuery); quitting is
    tray → Quit (Application.Terminate). }
  Application.Run;
end.
