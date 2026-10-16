program fptg_server_gui;

{$mode objfpc}{$H+}

{ Сервер fptg с окном: то же ядро, что у консольного
  fptg-server (TDLib, мост, HTTPS/WebSocket, вход), плюс небольшое
  окно управления (panel/srvpanel.pas + .lfm) и значок в трее. LCL —
  только в окне; ничего платформенного — собирается на Windows и Linux.

  Один экземпляр сервера на папку данных (instance.pas, общий с
  консольным): если уже запущено окно — второй запуск показывает его и
  выходит; если работает консольный сервер — окно становится пультом к
  нему.

  Параметры те же, что у консольного: --server-port, --bind, --web-dir,
  --cert/--key. Пользователи заводятся в окне. }

uses
  { Менеджер памяти — первым, раньше любого выделения (как у
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
  { Без этого неявные преобразования строк идут через системную кодовую
    страницу и теряют не-латиницу. }
  DefaultSystemCodePage := CP_UTF8;

  { Данные сервера — в профиле пользователя (appdirs.pas), не рядом с exe. }
  Dir := ServerDataDir;
  SecureConfigSetDir(Dir);
  Own := AcquireInstance(Dir, INSTANCE_SERVER);
  { Сервер уже работает из другой копии или у другого пользователя ОС —
    пульта к нему отсюда нет, а второй на машине не нужен. }
  if (not Own) and InstanceElsewhere then begin
    Application.Initialize;
    MessageDlg(APP_TITLE + ' server',
      'An fptg server is already running on this computer (another copy '
      + 'or another user). Only one can run per computer.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if (not Own) and (InstanceKind(Dir, INSTANCE_SERVER) = 'gui') then begin
    { Окно уже открыто — показать его, второго не нужно. }
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
  { Главная форма закрывается только в трей (FormCloseQuery); выход —
    трей → Quit (Application.Terminate). }
  Application.Run;
end.
