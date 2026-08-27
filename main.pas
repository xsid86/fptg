unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, StdCtrls, ExtCtrls, ComCtrls,
  Menus, tdauth, tdcore, tdreq, tdchats, uiframe, framelog, framewelcome,
  framechats;

type

  { TFormMain

    Application.MainForm: её закрытие завершает приложение, поэтому
    рукопожатие с TDLib живёт здесь. Форма намеренно тонкая —
    содержимое рабочей области целиком в фреймах. }

  TFormMain = class(TForm, ITdStateListener)
    ImageList1: TImageList;
    MainMenu1:  TMainMenu;
    MenuItem1:  TMenuItem;
    MenuItem2:  TMenuItem;
    MenuItem3:  TMenuItem;
    MenuItem4:  TMenuItem;
    MenuItem5:  TMenuItem;
    MenuItem6:  TMenuItem;
    MenuItem7:  TMenuItem;
    MenuItem8:  TMenuItem;
    MenuItem9:  TMenuItem;
    pnlTop:     TPanel;
    lblState:   TLabel;
    btnLogout:  TButton;
    pnlLeft:    TPanel;
    splLeft:    TSplitter;
    pnlWork:    TPanel;
    StatusBar1: TStatusBar;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure btnLogoutClick(Sender: TObject);
    procedure logScreen(Sender: TObject);
    procedure welcomeScreen(Sender: TObject);
    procedure menuQuitClick(Sender: TObject);
  private
    FTdClosed: boolean;
    FNav:      TFrameNavigator;
    FChats:    TFrameChats;
    procedure ShutdownDone(Sender: TObject);
    procedure ChatSelected(Sender: TObject; ARow: TChatRow);
  public
    procedure RequestAppClose;
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
    property Nav: TFrameNavigator read FNav;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FTdClosed := False;
  lblState.Caption := '';

  FNav := TFrameNavigator.Create(pnlWork);

  { Список чатов живёт в левой панели постоянно и навигатором
    не управляется — это не сменный экран. }
  FChats := TFrameChats.Create(pnlLeft);
  FChats.Parent := pnlLeft;
  FChats.Align := alClient;
  FChats.OnSelect := @ChatSelected;

  { Резолвер создаётся здесь, чтобы он успел подписаться на ядро
    до первых запросов. Обращение к синглтону его и конструирует. }
  TdRequests.DefaultTimeout := 30000;

  TdApp.Subscribe(Self);
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  TdUnsubscribe(Self);
  FreeAndNil(FNav);
end;

procedure TFormMain.RequestAppClose;
begin
  Close;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if FTdClosed then begin
    CanClose := True;
    Exit;
  end;

  CanClose  := TdApp.BeginShutdown(@ShutdownDone);
  FTdClosed := CanClose;

  if not CanClose then begin
    lblState.Caption := 'Закрываю TDLib, жду подтверждения...';
  end;
end;

procedure TFormMain.ChatSelected(Sender: TObject; ARow: TChatRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  { Экран чата появится следующим шагом. }
  Caption := 'Telegram — ' + string(ARow.Title);
end;

procedure TFormMain.ShutdownDone(Sender: TObject);
begin
  FTdClosed := True;
  Close;
end;

procedure TFormMain.btnLogoutClick(Sender: TObject);
begin
  if MessageDlg('Выход из аккаунта',
    'Завершить сеанс и вернуться к экрану входа?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then begin
    Exit;
  end;
  TdApp.LogOut;
end;

procedure TFormMain.logScreen(Sender: TObject);
begin
  FNav.ShowFrame(TFrameLog);
end;

procedure TFormMain.welcomeScreen(Sender: TObject);
begin
  FNav.ShowFrame(TFrameWelcome);
end;

procedure TFormMain.menuQuitClick(Sender: TObject);
begin
  FormCloseQuery(Self, FormMain.FTdClosed);
end;

{ ---------------- ITdStateListener ---------------- }

procedure TFormMain.TdStateChanged(AState: TTdAuthState);
begin
  lblState.Caption := 'Состояние: ' + AuthStateToStr(AState);

  if AState = tasReady then begin
    if not Visible then begin
      Show;
      { Первый экран показываем только когда форма реально появилась:
        фреймы создаются лениво, раньше это было бы впустую. }
      if FNav.Current = nil then begin
        FNav.ShowFrame(TFrameWelcome);
      end;
    end;
  end else begin
    if Visible and not TdApp.ShuttingDown then begin
      Hide;
    end;
  end;
end;

procedure TFormMain.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  lblState.Caption := Format('ОШИБКА %d [%s]: %s',
    [ACode, string(AContext), string(AMessage)]);
end;

end.
