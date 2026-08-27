program tg;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Dialogs,
  tdjson, tdclient, tdauth, tdcore,
  main, splash, login, qrrender
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title:='TG Orchestrator';
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  {$POP}
  Application.Initialize;

  { Ни одна форма не должна появиться сама: кто и когда показывается,
    решают сами формы по состоянию авторизации. }
  Application.ShowMainForm := False;

  { Первой создаётся главная — она становится Application.MainForm,
    и её закрытие завершает приложение. }
  Application.CreateForm(TFormMain, FormMain);
  Application.CreateForm(TFormSplash, FormSplash);
  Application.CreateForm(TFormLogin, FormLogin);

  if TdApp.LoadConfig then begin
    FormSplash.Show;
    TdApp.Start;
  end else begin
    MessageDlg('Ошибка конфигурации', TdApp.ConfigError, mtError, [mbOK], 0);
    Application.Terminate;
  end;

  Application.Run;
end.
