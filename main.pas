unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Forms, Controls, Dialogs, StdCtrls, ExtCtrls,
  Graphics, Menus, ComCtrls, Math, BGRABitmap, BGRABitmapTypes, avatarcache,
  tdauth, tdcore, tdreq, tdchats, uiframe, framelog, framewelcome,
  framechats, framehistory, mediaviewer, msginput, constants;

type

  { TFormMain

    Application.MainForm: closing it ends the application, so the TDLib
    handshake lives here. The form itself stays thin — the work area's
    content lives entirely in frames. }

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
    MenuItem14: TMenuItem;
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
    procedure SettingsMenuClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FTdClosed:     boolean;
    FNav:          TFrameNavigator;
    FChats:        TFrameChats;
    { Full-screen photo/video viewer (mediaviewer.pas) — parented to the
      form itself (not pnlWork), covering the whole client rect, so it
      overlays the chat list on the left and the top panel too, not
      just the history area. Hidden (Visible=False) in normal mode is
      enough to stop it intercepting mouse/keyboard — no separate
      click-through handling is needed. }
    FMediaViewer:  TMediaViewerPanel;
    { pnlWork is split vertically: FNavHost is the upper part, the
      container for FNav (used to be pnlWork itself); FInputSplitter is
      the draggable divider; FMessageInput is the input box at the
      bottom. Creation order in FormCreate matters for Align, see its
      own comment. }
    FNavHost:       TPanel;
    FInputSplitter: TSplitter;
    FMessageInput:  TMessageInputPanel;
    FAccMenuCount: integer;   { number of dynamically created menu items }
    FGlyphs: TStringList;   { menu glyph cache: key -> TBitmap }
    FAudioDeviceName: string;   { selected audio output device, from config.ini [audio] }
    { FAutoDownload[media][chat] — a cache of the grid from
      config.ini/[autodownload] (see framesettingsautodownload.pas),
      same principle as FAudioDeviceName: the single in-memory source
      of truth for the session, config.ini is persistence only. Indices
      are positions in AUTODL_MEDIA_KINDS/AUTODL_CHAT_KINDS
      (constants.pas). }
    FAutoDownload: array[0..High(AUTODL_MEDIA_KINDS)] of array[0..High(AUTODL_CHAT_KINDS)] of boolean;
    function  AccountGlyph(AAcc: TTdAccount; AActive, ANeedLogin: boolean): TBitmap;
    procedure RebuildAccountsMenu;
    procedure AccountItemClick(Sender: TObject);
    procedure AddAccountClick(Sender: TObject);
    procedure ShutdownDone(Sender: TObject);
    procedure ChatSelected(Sender: TObject; ARow: TChatRow);
    procedure ListModeChanged(Sender: TObject; AMode: TChatListMode);
    procedure AvatarClicked(Sender: TObject; ARow: TChatRow);
    { Handles Send from the input panel (msginput.pas) — that panel has
      no knowledge of TTdMessages; sending is resolved here using the
      model of the CURRENTLY OPEN chat (FNav.Current, if it's a
      TFrameHistory), see the comment on TFrameHistory.Model. }
    procedure MessageInputSend(Sender: TObject);
  public
    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    procedure RequestAppClose;
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
    property Nav: TFrameNavigator read FNav;
    { The chat list is not a swappable navigator screen (see FormCreate)
      — it gets its own public accessor instead of going through
      Nav.Find. Needed by framehistory.pas to reach ImageList1's
      message-status icons without a second copy of the same icons. }
    property Chats: TFrameChats read FChats;
    { Photo/video viewer — needed by framehistory.pas (clicking a
      photo/video in a chat opens it), same global-FormMain access
      pattern already used for Chats/Nav. }
    property MediaViewer: TMediaViewerPanel read FMediaViewer;
    { Audio output device selected in Settings — needed by
      framehistory.pas (TAudioPlayer.Create) so it doesn't need a
      second source of truth on top of config.ini/[audio]. }
    property AudioDeviceName: string read FAudioDeviceName;
    { Changes the selected device and immediately persists it to
      config.ini/[audio] — called from TFrameSettingsAudio (the
      settings dialog), same global-FormMain access pattern already
      used by framehistory.pas for Chats/Nav. }
    procedure SetAudioDeviceName(const AName: string);
    { Reads config.ini/[autodownload] into FAutoDownload — called at
      startup (FormCreate) and again from
      TFrameSettingsAutoDownload.SaveSettings after saving (the same
      reuse pattern as SetAudioDeviceName: a single write refreshing
      the single source of truth). }
    procedure LoadAutoDownloadSettings;
    { Whether auto-download is enabled for a (media type, chat type)
      pair — keys are the same strings as AUTODL_MEDIA_KINDS/
      AUTODL_CHAT_KINDS (constants.pas), e.g. ('images','private'). An
      unknown key returns False rather than raising — the caller
      (framehistory.pas) has no way to tell an unrecognized chat type
      apart from a legitimate "off", and treating it as off is correct
      either way. }
    function AutoDownloadEnabled(const AMediaKind, AChatKind: string): boolean;
  end;

var
  FormMain: TFormMain;

implementation

{ login/settings are used in the implementation section, not the
  interface: both use main themselves (login for RequestAppClose,
  settings transitively via framesettingsaudio.pas and
  FormMain.AudioDeviceName/SetAudioDeviceName), which would create a
  cycle if used from the interface. }
uses
  login, settings;

{$R *.lfm}

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FTdClosed := False;
  lblState.Caption := '';

  { pnlWork is split vertically: the frame area on top, the message
    input at the bottom, see the comment on the FNavHost/
    FInputSplitter/FMessageInput fields. The Parent:= order below
    matters for Align — LCL hands out space in the order controls are
    added to Controls: bottom first (FMessageInput, alBottom), then the
    splitter directly above it (also alBottom), and only last whatever
    fills the remainder (FNavHost, alClient). }
  FMessageInput := TMessageInputPanel.Create(pnlWork);
  FMessageInput.Parent := pnlWork;
  FMessageInput.Align := alBottom;
  FMessageInput.Height := 150;
  FMessageInput.OnSend := @MessageInputSend;

  FInputSplitter := TSplitter.Create(pnlWork);
  FInputSplitter.Parent := pnlWork;
  FInputSplitter.Align := alBottom;

  FNavHost := TPanel.Create(pnlWork);
  FNavHost.Parent := pnlWork;
  FNavHost.Align := alClient;
  FNavHost.BevelOuter := bvNone;
  { Same minimum as FMessageInput (see TMessageInputPanel.Create) —
    otherwise the splitter could be dragged down to zero, hiding the
    history area entirely. }
  FNavHost.Constraints.MinHeight := 100;

  FNav := TFrameNavigator.Create(FNavHost);

  { The chat list lives permanently in the left panel and is not
    managed by the navigator — it's not a swappable screen. }
  FChats := TFrameChats.Create(pnlLeft);
  FChats.Parent := pnlLeft;
  FChats.Align := alClient;
  FChats.OnSelect := @ChatSelected;
  FChats.OnListMode := @ListModeChanged;
  FChats.OnAvatar := @AvatarClicked;

  { Created here so it subscribes to the core before the first
    requests. Touching the singleton is what constructs it. }
  TdRequests.DefaultTimeout := 30000;

  FGlyphs := TStringList.Create;
  FGlyphs.Sorted := True;
  FGlyphs.Duplicates := dupIgnore;
  FGlyphs.OwnsObjects := False;

  { Parented to the form itself (Self), not pnlWork — see the field
    comment. Align is not used (alClient would only fill the leftover
    space after pnlTop/pnlLeft/StatusBar1, but those need to be
    overlaid too) — explicit bounds are kept in sync in FormResize
    instead. }
  FMediaViewer := TMediaViewerPanel.Create(Self);
  FMediaViewer.Parent := Self;
  FMediaViewer.SetBounds(0, 0, ClientWidth, ClientHeight);
  FMediaViewer.Visible := False;
  OnResize := @FormResize;

  TdApp.Subscribe(Self);
  TdApp.SubscribeActive(Self);
  RebuildAccountsMenu;

  { The audio output device selection persists in the same config.ini
    that already holds api_id/api_hash, under [audio] — the picker
    itself now lives in the settings dialog (settings.pas, Audio
    section), not the main menu. }
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      FAudioDeviceName := ReadString('audio', 'device', '');
    finally
      Free;
    end;
  end;
  LoadAutoDownloadSettings;

  { "New" in the Account menu creates another account. }
  if MenuItem11 <> nil then begin
    MenuItem11.OnClick := @AddAccountClick;
  end;
  { "Logout" signs out of the active account; with multiple accounts
    it also removes it from the list, matching Telegram. }
  if MenuItem12 <> nil then begin
    MenuItem12.OnClick := @btnLogoutClick;
  end;
end;

procedure TFormMain.FormResize(Sender: TObject);
begin
  { FMediaViewer picks up the new size through its own Resize (the
    framehistory widget/photo inside recompute there) — this form only
    needs to keep its bounds in sync with the form's client area. }
  if FMediaViewer <> nil then begin
    FMediaViewer.SetBounds(0, 0, ClientWidth, ClientHeight);
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
var
  F: TFrameHistory;
begin
  if ARow = nil then begin
    Exit;
  end;
  Caption := 'Telegram - ' + string(ARow.Title);
  F := TFrameHistory(FNav.ShowFrame(TFrameHistory));
  F.OpenChat(ARow.Id);
end;

procedure TFormMain.AvatarClicked(Sender: TObject; ARow: TChatRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  { Placeholder: the contact-info panel will open here. }
  lblState.Caption := Format('Info: %s (id %d)', [string(ARow.Title), ARow.Id]);
end;

procedure TFormMain.MessageInputSend(Sender: TObject);
var
  MsgText: string;
  F: TFrameHistory;
begin
  MsgText := Trim(FMessageInput.Text);
  if MsgText = '' then begin
    Exit;
  end;
  if not (FNav.Current is TFrameHistory) then begin
    Exit;
  end;
  F := TFrameHistory(FNav.Current);
  if F.Model = nil then begin
    Exit;
  end;
  F.Model.SendText(utf8string(MsgText));
  FMessageInput.ClearText;
end;

procedure TFormMain.ListModeChanged(Sender: TObject; AMode: TChatListMode);
begin
  if AMode = clmArchive then begin
    Caption := 'Telegram - Archive';
  end else begin
    Caption := 'Telegram';
  end;
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
      { The first screen is shown only once the form has actually
        appeared: frames are created lazily, doing it earlier would be
        wasted work. }
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

{ ---------------- account menu ---------------- }

function TFormMain.AccountGlyph(AAcc: TTdAccount; AActive, ANeedLogin: boolean): TBitmap;
const
  SZ = 16;
var
  Key: string;
  Idx, I: integer;
  B, Av: TBGRABitmap;
  AX, AY, AR: single;
begin
  { The key includes the avatar path: once it finishes downloading, the
    glyph gets redrawn. }
  Key := IntToStr(AAcc.Slot) + '|' + BoolToStr(AActive, '1', '0') +
         BoolToStr(ANeedLogin, '1', '0') + '|' + string(AAcc.PhotoPath) +
         '|' + IntToStr(Length(AAcc.PhotoThumb)) + '|' + AAcc.Title;

  Idx := FGlyphs.IndexOf(Key);
  if Idx >= 0 then begin
    Result := TBitmap(FGlyphs.Objects[Idx]);
    Exit;
  end;

  { Account avatar: the downloaded photo, else the mini-thumbnail, else
    initials on a colored circle. The exact same rendering as the chat
    list. }
  Av := RenderAvatarBmp(AAcc.PhotoPath, AAcc.PhotoThumb,
    utf8string(AAcc.Title), AAcc.UserId, SZ, True);

  B := TBGRABitmap.Create(SZ, SZ, BGRAPixelTransparent);
  try
    if Av <> nil then begin
      B.PutImage(0, 0, Av, dmDrawWithTransparency);
    end;

    B.LineCap := pecRound;
    B.JoinStyle := pjsRound;

    { Sign-in required — a red asterisk in the bottom-right corner. }
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

    { clNone: MakeBitmapCopy produces a TBitmap with the alpha channel
      preserved. Baking a menu background color in here would be wrong
      — the item background changes on hover, and the baked-in corners
      would stay light squares. }
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

  { Drops the previous dynamic items. The static ones (New/Edit/Logout)
    sit below and are left untouched. }
  for I := FAccMenuCount - 1 downto 0 do begin
    MenuItem10.Delete(I);
  end;
  FAccMenuCount := 0;

  for I := 0 to TdApp.Count - 1 do begin
    A := TdApp.Accounts[I];
    IsActive := (I = TdApp.ActiveIndex);
    NeedLogin := A.State <> tasReady;

    MI := TMenuItem.Create(MenuItem10);
    { Different accounts can share a name and avatar, so the id is
      always in the label — otherwise they'd be indistinguishable. }
    if A.UserId <> 0 then begin
      MI.Caption := Format('%s  (%d)', [A.Title, A.UserId]);
    end else begin
      MI.Caption := A.Title;
    end;
    if NeedLogin then begin
      MI.Caption := MI.Caption + '  (sign-in required)';
    end;
    MI.Tag := I;
    { The active account is bolded — this doesn't touch the icon slot,
      which is occupied by the avatar. }
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

{ ---------------- settings dialog ---------------- }

procedure TFormMain.SettingsMenuClick(Sender: TObject);
var
  Dlg: TFormSettings;
begin
  Dlg := TFormSettings.Create(Self);
  try
    Dlg.ShowModal;
  finally
    Dlg.Free;
  end;
end;

procedure TFormMain.SetAudioDeviceName(const AName: string);
begin
  if AName = FAudioDeviceName then begin
    Exit;
  end;
  FAudioDeviceName := AName;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteString('audio', 'device', FAudioDeviceName);
    finally
      Free;
    end;
  end;
end;

{ ---------------- auto-download ---------------- }

function AutoDownloadMediaIndex(const AKind: string): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(AUTODL_MEDIA_KINDS) do begin
    if AUTODL_MEDIA_KINDS[I] = AKind then begin
      Result := I;
      Exit;
    end;
  end;
end;

function AutoDownloadChatIndex(const AKind: string): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(AUTODL_CHAT_KINDS) do begin
    if AUTODL_CHAT_KINDS[I] = AKind then begin
      Result := I;
      Exit;
    end;
  end;
end;

procedure TFormMain.LoadAutoDownloadSettings;
var
  M, C: integer;
begin
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
        for C := 0 to High(AUTODL_CHAT_KINDS) do begin
          FAutoDownload[M][C] := ReadBool('autodownload',
            AUTODL_MEDIA_KINDS[M] + '.' + AUTODL_CHAT_KINDS[C], False);
        end;
      end;
    finally
      Free;
    end;
  end;
end;

function TFormMain.AutoDownloadEnabled(const AMediaKind, AChatKind: string): boolean;
var
  M, C: integer;
begin
  Result := False;
  M := AutoDownloadMediaIndex(AMediaKind);
  C := AutoDownloadChatIndex(AChatKind);
  if (M < 0) or (C < 0) then begin
    Exit;
  end;
  Result := FAutoDownload[M][C];
end;

procedure TFormMain.AddAccountClick(Sender: TObject);
var
  Acc: TTdAccount;
  Dlg: TFormLogin;
begin
  Acc := TdApp.AddAccount('New account');
  Acc.Start;

  { A separate form instance, not the global FormLogin: that one is
    bound to the active account and serves the startup flow. }
  Dlg := TFormLogin.Create(nil);
  try
    Dlg.AttachTo(Acc, True);
    Dlg.ShowModal;
    if not Dlg.Succeeded then begin
      { Canceled: discard the unfinished account. The on-disk directory
        stays, the slot gets reused. }
      { Discard, not Remove: the TDLib client must be closed first,
        otherwise it keeps holding the database directory open, and the
        next attempt to reuse that slot would hit a locked database. }
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
