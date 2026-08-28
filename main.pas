unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs, StdCtrls, ExtCtrls, Graphics,
  Menus, ComCtrls, Math, BGRABitmap, BGRABitmapTypes, avatarcache,
  tdauth, tdcore, tdreq, tdchats, uiframe, framelog, framewelcome,
  framechats;

type

  { TFormMain

    Application.MainForm: её закрытие завершает приложение, поэтому
    рукопожатие с TDLib живёт здесь. Форма намеренно тонкая —
    содержимое рабочей области целиком в фреймах. }

  TFormMain = class(TForm, ITdStateListener, ITdActiveListener)
    ImageList1: TImageList;
    MainMenu1:  TMainMenu;
    MenuItem1:  TMenuItem;
    MenuItem10: TMenuItem;
    MenuItem11: TMenuItem;
    MenuItem12: TMenuItem;
    MenuItem13: TMenuItem;
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
    TrayIcon1: TTrayIcon;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure btnLogoutClick(Sender: TObject);
    procedure logScreen(Sender: TObject);
    procedure welcomeScreen(Sender: TObject);
    procedure menuQuitClick(Sender: TObject);
  private
    FTdClosed:     boolean;
    FNav:          TFrameNavigator;
    FChats:        TFrameChats;
    FAccMenuCount: integer;   { сколько пунктов меню создано динамически }
    FGlyphs: TStringList;   { кэш глифов меню: ключ -> TBitmap }
    function  AccountGlyph(AAcc: TTdAccount; AActive, ANeedLogin: boolean): TBitmap;
    procedure RebuildAccountsMenu;
    procedure AccountItemClick(Sender: TObject);
    procedure AddAccountClick(Sender: TObject);
    procedure ShutdownDone(Sender: TObject);
    procedure ChatSelected(Sender: TObject; ARow: TChatRow);
    procedure ArchiveClicked(Sender: TObject);
  public
    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    procedure RequestAppClose;
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
    property Nav: TFrameNavigator read FNav;
  end;

var
  FormMain: TFormMain;

implementation

{ login в реализации, а не в интерфейсе: login сам использует main
  (для RequestAppClose), и в интерфейсе это дало бы цикл. }
uses
  login;

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
  FChats.OnArchive := @ArchiveClicked;

  { Резолвер создаётся здесь, чтобы он успел подписаться на ядро
    до первых запросов. Обращение к синглтону его и конструирует. }
  TdRequests.DefaultTimeout := 30000;

  FGlyphs := TStringList.Create;
  FGlyphs.Sorted := True;
  FGlyphs.Duplicates := dupIgnore;
  FGlyphs.OwnsObjects := False;

  TdApp.Subscribe(Self);
  TdApp.SubscribeActive(Self);
  RebuildAccountsMenu;

  { «New» из меню Account заводит ещё один аккаунт. }
  if MenuItem11 <> nil then begin
    MenuItem11.OnClick := @AddAccountClick;
  end;
  { «Logout» — выход из активного; при нескольких аккаунтах
    он заодно убирает его из списка, как в Telegram. }
  if MenuItem12 <> nil then begin
    MenuItem12.OnClick := @btnLogoutClick;
  end;
end;

procedure TFormMain.FormDestroy(Sender: TObject);
var
  I: integer;
begin
  TdApp.UnsubscribeActive(Self);
  TdUnsubscribe(Self);
  FreeAndNil(FNav);
  if FGlyphs <> nil then begin
    for I := 0 to FGlyphs.Count - 1 do begin
      FGlyphs.Objects[I].Free;
    end;
    FGlyphs.Free;
  end;
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
    lblState.Caption := 'Closing TDLib, waiting for confirmation...';
  end;
end;

procedure TFormMain.ChatSelected(Sender: TObject; ARow: TChatRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  { Экран чата появится следующим шагом. }
  Caption := 'Telegram - ' + string(ARow.Title);
end;

procedure TFormMain.ArchiveClicked(Sender: TObject);
begin
  { Экран архива появится позже: переключит список на chatListArchive. }
  Caption := 'Telegram - Archive';
end;

procedure TFormMain.ShutdownDone(Sender: TObject);
begin
  FTdClosed := True;
  Close;
end;

procedure TFormMain.btnLogoutClick(Sender: TObject);
begin
  if MessageDlg('Log out', 'End the session and return to the login screen?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then begin
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
  Close;
end;

{ ---------------- ITdStateListener ---------------- }

procedure TFormMain.TdStateChanged(AState: TTdAuthState);
begin
  lblState.Caption := 'State: ' + AuthStateToStr(AState);

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

{ ---------------- меню аккаунтов ---------------- }

function TFormMain.AccountGlyph(AAcc: TTdAccount; AActive, ANeedLogin: boolean): TBitmap;
const
  SZ = 16;
var
  Key: string;
  Idx, I: integer;
  B, Av: TBGRABitmap;
  AX, AY, AR: single;
begin
  { Ключ включает путь к аватарке: докачалась — глиф перерисуется. }
  Key := IntToStr(AAcc.Slot) + '|' + BoolToStr(AActive, '1', '0') +
         BoolToStr(ANeedLogin, '1', '0') + '|' + string(AAcc.PhotoPath) +
         '|' + IntToStr(Length(AAcc.PhotoThumb)) + '|' + AAcc.Title;

  Idx := FGlyphs.IndexOf(Key);
  if Idx >= 0 then begin
    Result := TBitmap(FGlyphs.Objects[Idx]);
    Exit;
  end;

  { Аватарка аккаунта: скачанная, иначе мини-превью, иначе инициалы
    на цветном круге. Ровно та же отрисовка, что в списке чатов. }
  Av := RenderAvatarBmp(AAcc.PhotoPath, AAcc.PhotoThumb,
    utf8string(AAcc.Title), AAcc.UserId, SZ, True);

  B := TBGRABitmap.Create(SZ, SZ, BGRAPixelTransparent);
  try
    if Av <> nil then begin
      B.PutImage(0, 0, Av, dmDrawWithTransparency);
    end;

    B.LineCap := pecRound;
    B.JoinStyle := pjsRound;

    { Нужен вход — красная звёздочка в правом нижнем углу. }
    if ANeedLogin then begin
      AX := SZ - 4.5;
      AY := SZ - 4.5;
      AR := 3.5;
      B.FillEllipseAntialias(AX, AY, AR + 1.2, AR + 1.2, ColorToBGRA(clWindow));
      for I := 0 to 2 do begin
        B.DrawPolyLineAntialias(
          [PointF(AX - AR * Cos(I * Pi / 3), AY - AR * Sin(I * Pi / 3)),
           PointF(AX + AR * Cos(I * Pi / 3), AY + AR * Sin(I * Pi / 3))],
          BGRA(220, 40, 40), 1.4);
      end;
    end;

    { clNone — MakeBitmapCopy отдаёт TBitmap с сохранённым альфа-каналом.
      Запекать сюда цвет меню нельзя: при наведении фон пункта меняется,
      и запечённые углы остаются светлыми квадратами. }
    Result := B.MakeBitmapCopy(clNone);
  finally
    B.Free;
    Av.Free;
  end;

  while FGlyphs.Count >= 32 do begin
    FGlyphs.Objects[0].Free;
    FGlyphs.Delete(0);
  end;
  FGlyphs.AddObject(Key, Result);
end;

procedure TFormMain.RebuildAccountsMenu;
var
  I: integer;
  MI: TMenuItem;
  A: TTdAccount;
  NeedLogin, IsActive: boolean;
begin
  if MenuItem10 = nil then begin
    Exit;
  end;

  { Сносим прежние динамические пункты. Статические (New/Edit/Logout)
    лежат ниже и не трогаются. }
  for I := FAccMenuCount - 1 downto 0 do begin
    MenuItem10.Delete(I);
  end;
  FAccMenuCount := 0;

  for I := 0 to TdApp.Count - 1 do begin
    A := TdApp.Accounts[I];
    IsActive := (I = TdApp.ActiveIndex);
    NeedLogin := A.State <> tasReady;

    MI := TMenuItem.Create(MenuItem10);
    MI.Caption := A.Title;
    if NeedLogin then begin
      MI.Caption := MI.Caption + '  (sign-in required)';
    end;
    MI.Tag := I;
    { Активный выделяем жирным: это не трогает слот значка,
      который занят аватаркой. }
    MI.Default := IsActive;
    MI.OnClick := @AccountItemClick;
    MI.Bitmap.Assign(AccountGlyph(A, IsActive, NeedLogin));
    MenuItem10.Insert(FAccMenuCount, MI);
    Inc(FAccMenuCount);
  end;

  if FAccMenuCount > 0 then begin
    MI := TMenuItem.Create(MenuItem10);
    MI.Caption := '-';
    MenuItem10.Insert(FAccMenuCount, MI);
    Inc(FAccMenuCount);
  end;
end;

procedure TFormMain.AccountItemClick(Sender: TObject);
begin
  TdApp.ActiveIndex := TMenuItem(Sender).Tag;
end;

procedure TFormMain.AddAccountClick(Sender: TObject);
var
  Acc: TTdAccount;
  Dlg: TFormLogin;
begin
  Acc := TdApp.AddAccount('New account');
  Acc.Start;

  { Отдельный экземпляр формы, а не глобальный FormLogin: тот привязан
    к активному аккаунту и обслуживает стартовый сценарий. }
  Dlg := TFormLogin.Create(nil);
  try
    Dlg.AttachTo(Acc, True);
    Dlg.ShowModal;
    if not Dlg.Succeeded then begin
      { Отмена: убираем недоделанный аккаунт. Каталог на диске
        остаётся, слот переиспользуется. }
      { Именно Discard, а не Remove: клиента TDLib надо сначала
        закрыть, иначе он продолжит держать каталог базы, и
        следующая попытка занять тот же слот упрётся
        в заблокированную базу. }
      TdApp.DiscardAccount(Acc);
      Exit;
    end;
  finally
    Dlg.Free;
  end;

  TdApp.SaveAccounts;
  TdApp.ActiveIndex := TdApp.Count - 1;
end;

procedure TFormMain.TdActiveChanged(ANew: TTdAccount);
begin
  RebuildAccountsMenu;
  if ANew <> nil then begin
    TdStateChanged(ANew.State);
  end;
end;

procedure TFormMain.TdAccountsChanged;
begin
  RebuildAccountsMenu;
end;

procedure TFormMain.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  lblState.Caption := Format('ERROR %d [%s]: %s',
    [ACode, string(AContext), string(AMessage)]);
end;

end.
