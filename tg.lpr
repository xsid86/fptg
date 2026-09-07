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
  constants,
  tdjson, tdrecv, tdclient, tdauth, tdsession, tdreq, tdchats, tdmessages,
  tdusers, tdaccentcolors, tdaccount, tdcore, audiodevices, ffdecode, audioplayer, videoplayer,
  photodecoder, mediaplayer, rlottie, lottieplayer,
  uiframe, avatarcache, qrrender, msglayout,
  main, splash, login, settings, framesettingsgeneral, framesettingsaudio,
  framesettingsautodownload, framelog, framewelcome, framechats, framehistory,
  mediaviewer, msginput
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

  { Конфиг и список аккаунтов читаются ДО создания форм: формы
    в FormCreate подписываются на активный аккаунт и обращаются
    к его модели чатов, значит аккаунт к тому моменту должен
    существовать. Клиенты TDLib при этом ещё не запущены. }
  if not TdApp.LoadConfig then begin
    MessageDlg('Ошибка конфигурации', TdApp.ConfigError, mtError, [mbOK], 0);
    Application.Terminate;
    Exit;
  end;

  TdApp.LoadAccounts;

  { Первой создаётся главная — она становится Application.MainForm,
    и её закрытие завершает приложение. }
  Application.CreateForm(TFormMain, FormMain);
  Application.CreateForm(TFormSplash, FormSplash);
  Application.CreateForm(TFormLogin, FormLogin);

  { Стартовая форма входа нацеливается на активный аккаунт.
    При переключении она перепривяжется сама (ITdActiveListener). }
  FormLogin.AttachTo(TdApp.Active, False);

  FormSplash.Show;
  TdApp.Start;

  Application.Run;
end.
