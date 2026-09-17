unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, Forms, Controls, Dialogs, StdCtrls, ExtCtrls,
  Graphics, Menus, ComCtrls, Math, BGRABitmap, BGRABitmapTypes, avatarcache,
  tdauth, tdcore, tdreq, tdchats, tdsupergroups, uiframe, framelog, framewelcome,
  framechats, framehistory, mediaviewer, msginput, tdmessages, tdstorage,
  constants;

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
    pnlLeft:    TPanel;
    splLeft:    TSplitter;
    pnlWork:    TPanel;
    StatusBar1: TStatusBar;
    TrayIcon1: TTrayIcon;
    { Status-bar presence menu (Panels[0], see StatusBar1DrawPanel) —
      a real TPopupMenu component, dropped on the form so the user can
      edit its items/icons in the Designer, not built in code. }
    PresenceMenu: TPopupMenu;
    MenuItemPresenceOnline: TMenuItem;
    MenuItemPresenceInvisible: TMenuItem;
    { Tray icon's own popup menu (right-click) — separate component from
      MainMenu1/PresenceMenu so it can be edited in the Designer too.
      Its "Exit" item reuses menuQuitClick directly (same method, two
      menu owners — LCL doesn't care which menu a TMenuItem's OnClick
      came from). }
    TrayPopupMenu: TPopupMenu;
    MenuItemTrayShow: TMenuItem;
    MenuItemTrayExit: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure TrayIconDblClick(Sender: TObject);
    procedure MenuItemTrayShowClick(Sender: TObject);
    procedure btnLogoutClick(Sender: TObject);
    procedure logScreen(Sender: TObject);
    procedure welcomeScreen(Sender: TObject);
    procedure menuQuitClick(Sender: TObject);
    procedure SettingsMenuClick(Sender: TObject);
    procedure FormResize(Sender: TObject);
    { Click on the presence panel (Panels[0], now first — see main.lfm)
      pops up PresenceMenu at
      the cursor — GetPanelIndexAt is LCL's own hit-test helper
      (comctrls.pp), no manual width-summing needed. }
    procedure StatusBar1MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: integer);
    { Owner-drawn: TStatusPanel has no icon property, only Text — a
      small filled/hollow circle plus the panel's own Text is painted
      by hand here, the same "quick, code-drawn glyph" approach already
      used by AccountGlyph's sign-in-required marker above. }
    procedure StatusBar1DrawPanel(AStatusBar: TStatusBar; APanel: TStatusPanel;
      const ARect: TRect);
    procedure PresenceOnlineClick(Sender: TObject);
    procedure PresenceInvisibleClick(Sender: TObject);
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
    { True = "Invisible": never marks messages as read (already the
      case — the app never calls viewMessages as a side effect of
      reading, only from the explicit "Mark as read" chat-list menu
      item, see tdchats.pas/TTdChats.MarkAsRead) AND suppresses the
      "online" presence TDLib would otherwise show to contacts
      automatically whenever the client has an authorized connection —
      via setOption("online", false), see ApplyPresence. Persisted to
      config.ini/[ui], same pattern as FAudioDeviceName. }
    FInvisible: boolean;
    { True = pressing the window's close button hides it to the tray
      instead of quitting — the tray icon (always visible, see main.lfm)
      stays behind, a double-click or its own "Show" menu item restores
      the window. Does NOT affect an explicit quit (File > Quit, the
      tray icon's own "Exit", or closing the pre-login window) — those
      always go through the real shutdown, see FQuitRequested.
      Persisted to config.ini/[ui], same pattern as FInvisible. Defaults
      to True: this is the newly-requested behavior, not a preserved
      old default. }
    FCloseToTray: boolean;
    { The app's brand accent color (see APP_ACCENT_COLOR, constants.pas,
      for the default and why it's a SEPARATE constant from
      CHATROW_PSEUDO_COLOR) — currently used only for the fill of the
      photo/video download progress bar (framehistory.pas), but kept
      general (a plain color, not e.g. "download bar color" specifically)
      since Settings > General presents it as one app-wide choice, not a
      per-feature one. Persisted to config.ini/[ui], same pattern as
      FInvisible/FCloseToTray above. }
    FAccentColor: TColor;
    { The app's background surface — the field the chat-list cards, the
      chat info bar's card and the message input box all float on (the
      window grey in the default theme). NOT the message history's own
      background, which stays clWindow: that one is a sheet of paper
      with text on it, this is the desk under it.

      Applied by setting it on the few real containers (pnlLeft/
      pnlWork/FNavHost/FMessageInput — see ApplySurfaceColor); every
      frame and control inside them has ParentColor on and follows
      along by itself, which is why there is no list of consumers to
      keep in step here. Persisted to config.ini/[ui], same pattern as
      FAccentColor above. }
    FSurfaceColor: TColor;
    { How many media files may download at once — the value itself
      lives in tdmessages.pas (SetDownloadConcurrency), which is where
      the queueing happens; this form only persists it and pushes it
      back on startup. }
    FDownloadConcurrency: integer;
    { Download speed cap in KB/s, 0 = unlimited. Same arrangement as
      the concurrency cap: the live value lives in tdmessages.pas, this
      form only persists it. }
    FDownloadSpeedKB: integer;
    { Cache cleanup limits, config.ini/[storage]. Unlike the two above
      the live value IS here — tdstorage.pas holds no settings of its
      own, it is handed the numbers on each call. 0 = that particular
      limit is off. }
    FCacheLimitMB: integer;
    FCacheTtlDays: integer;
    { Set by the few paths that mean an actual quit, not just closing
      the window: File > Quit (menuQuitClick), the tray icon's own
      "Exit" (same handler), and RequestAppClose (closing the pre-login
      window, where there's nothing useful to keep alive in the tray
      for). FormCloseQuery checks this before honoring FCloseToTray. }
    FQuitRequested: boolean;
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
    procedure ApplyPresence;
    { Prunes TDLib's media cache to the configured limits. No-op when
      both are 0 — the whole point of 0 is "keep everything". }
    procedure ApplyCacheLimit;
    procedure PresenceSetDone(Sender: TObject; const AResp: TTdResponse);
    procedure UpdatePresencePanel;
    procedure SetPresence(AInvisible: boolean);
    { Pushes FSurfaceColor onto the handful of containers that actually
      own a background — everything inside them has ParentColor on and
      follows. Called from FormCreate (after the value is read) and
      from SetSurfaceColor. }
    procedure ApplySurfaceColor;
    { Shared OnPaint for both splitters — see its own comment. }
    procedure SplitterPaint(Sender: TObject);
  public
    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    procedure RequestAppClose;
    { Shows/hides the message input panel (and its splitter) based on
      whether a chat is actually open right now — FNav.Current is
      TFrameHistory AND that frame's Model has a nonzero ChatId. Model
      alone isn't enough: it's a per-ACCOUNT singleton (TTdMessages),
      already non-nil as soon as the account is ready, regardless of
      whether any chat has ever been opened in it — so on the Welcome/
      Log/Settings screens, or on a freshly-created TFrameHistory
      before its first OpenChat, Model.ChatId is still 0. Called from
      here (logScreen/welcomeScreen/TdStateChanged) whenever the shown
      screen changes to something other than a chat, and from
      framehistory.pas's own OpenChat/TdActiveChanged whenever a chat
      is opened or the active account switches — the two ends of the
      transition, not a generic navigator-wide event, since those are
      the only places either side of it actually happens. }
    procedure UpdateMessageInputVisibility;
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
    property Nav: TFrameNavigator read FNav;
    { The chat list is not a swappable navigator screen (see FormCreate)
      — it gets its own public accessor instead of going through
      Nav.Find. Needed by framehistory.pas to reach ImageList1's
      message-status icons without a second copy of the same icons. }
    property Chats: TFrameChats read FChats;
    { Replaces the old pnlTop label — auth state, shutdown/error
      messages, the contact-info placeholder. StatusBar1's rightmost
      panel (index 2, the wide one that absorbs whatever width is
      left — index 0 is the clickable presence indicator (see
      PresenceMenu), index 1 is the chat-list status). }
    procedure SetStatusText(const AText: string);
    { Replaces the old pnlBottom label under the chat list — the
      "N chats (more)" line. StatusBar1's middle panel (index 1, fixed
      width) — called from framechats.pas via the same global-FormMain
      access pattern already used for Chats/Nav/MediaViewer. }
    procedure SetChatListStatus(const AText: string);
    { True = Invisible: TTdMessages.SendFormattedText and friends don't
      change behavior on this, but reading it never marks messages as
      read (see framehistory.pas/TMsgScroller.MarkVisibleAsRead) and
      the "online" presence is suppressed (see ApplyPresence) — needed
      by framehistory.pas, same global-FormMain access pattern already
      used for AutoDownloadEnabled/AudioDeviceName. }
    property Invisible: boolean read FInvisible;
    { Whether closing the window hides it to the tray instead of
      quitting — needed by framesettingsgeneral.pas (the General
      section's checkbox), same global-FormMain access pattern already
      used for AudioDeviceName/Invisible. }
    property CloseToTray: boolean read FCloseToTray;
    { Changes the setting and immediately persists it to
      config.ini/[ui] — called from TFrameSettingsGeneral, same
      pattern as SetAudioDeviceName. }
    procedure SetCloseToTray(AValue: boolean);
    { The live, user-configurable value of the accent color — needed by
      framehistory.pas (the download progress bar), same global-FormMain
      access pattern already used for AudioDeviceName/CloseToTray.
      APP_ACCENT_COLOR (constants.pas) is only the fallback used when
      nothing has been saved to config.ini yet, see FormCreate. }
    property AccentColor: TColor read FAccentColor;
    { Changes the setting and immediately persists it to
      config.ini/[ui] — called from TFrameSettingsGeneral, same pattern
      as SetCloseToTray. }
    procedure SetAccentColor(AValue: TColor);
    { The live, user-configurable background surface — see FSurfaceColor.
      APP_SURFACE_COLOR (constants.pas) is only the fallback used when
      nothing has been saved to config.ini yet, see FormCreate. }
    property SurfaceColor: TColor read FSurfaceColor;
    property DownloadConcurrency: integer read FDownloadConcurrency;
    property DownloadSpeedKB: integer read FDownloadSpeedKB;
    { Changes the setting, applies it to the open window right away and
      persists it — same pattern as SetAccentColor, plus the immediate
      repaint (an accent color only shows up on the next paint of a
      progress bar; a background is on screen the whole time). }
    procedure SetSurfaceColor(AValue: TColor);
    procedure SetDownloadConcurrency(AValue: integer);
    procedure SetDownloadSpeedKB(AValue: integer);
    { How big TDLib's media cache may get and how old a file may be
      before the next cleanup drops it; 0 disables that limit. Read by
      the settings window's Storage section, applied by ApplyCacheLimit
      on every transition to Ready. }
    property CacheLimitMB: integer read FCacheLimitMB;
    property CacheTtlDays: integer read FCacheTtlDays;
    procedure SetCacheLimitMB(AValue: integer);
    procedure SetCacheTtlDays(AValue: integer);
    { Photo/video viewer — needed by framehistory.pas (clicking a
      photo/video in a chat opens it), same global-FormMain access
      pattern already used for Chats/Nav. }
    property MediaViewer: TMediaViewerPanel read FMediaViewer;
    { "Quote selected" in the message history's right-click menu. The
      input panel is a private field and the history has no reference
      to it — it comes through this form, the same access pattern as
      Chats/Nav/MediaViewer. No-op while the panel is hidden (no chat
      open, or a channel this account can't post to). }
    procedure QuoteToInput(const AText: string);
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
  SetStatusText('');

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
  { Height comes from msginput.lfm now (set in the Designer) — do not
    override it here. }
  FMessageInput.OnSend := @MessageInputSend;

  FInputSplitter := TSplitter.Create(pnlWork);
  FInputSplitter.Parent := pnlWork;
  FInputSplitter.Align := alBottom;
  { rsUpdate (the default) relayouts and repaints everything anchored
    to this splitter on every single mouse-move during a drag — with
    the chat list (a TDrawGrid painting each row through BGRABitmap)
    and the message history (TMsgScroller, same kind of per-row BGRA
    painting) both anchored above it, repaint can't keep up with a fast
    drag, and the intermediate, partially-repainted frames are what
    showed up as streaking/ghosting. rsLine defers the actual
    resize+repaint to mouse-up, drawing just a plain line while
    dragging — the same fix applied to splLeft (main.lfm). }
  FInputSplitter.ResizeStyle := rsLine;

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
    space after pnlLeft/StatusBar1, but those need to be overlaid too)
    — explicit bounds are kept in sync in FormResize instead. }
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
      FInvisible := ReadBool('ui', 'invisible', False);
      FCloseToTray := ReadBool('ui', 'closetotray', True);
      FAccentColor := TColor(ReadInteger('ui', 'accentcolor', Integer(APP_ACCENT_COLOR)));
      FSurfaceColor := TColor(ReadInteger('ui', 'surfacecolor', Integer(APP_SURFACE_COLOR)));
      FDownloadConcurrency := ReadInteger('downloads', 'concurrency',
        DOWNLOAD_CONCURRENCY_DEFAULT);
      FDownloadSpeedKB := ReadInteger('downloads', 'speedkb',
        DOWNLOAD_SPEED_DEFAULT_KB);
      FCacheLimitMB := ReadInteger('storage', 'maxcachemb',
        CACHE_LIMIT_DEFAULT_MB);
      FCacheTtlDays := ReadInteger('storage', 'ttldays',
        CACHE_TTL_DEFAULT_DAYS);
    finally
      Free;
    end;
  end;
  LoadAutoDownloadSettings;
  { tdmessages.pas keeps the live value — it is read by every
    TTdMessages instance, including ones created later for other
    accounts, so it has to be pushed once at startup rather than
    handed to a particular model. }
  tdmessages.SetDownloadConcurrency(FDownloadConcurrency);
  FDownloadConcurrency := tdmessages.DownloadConcurrency;   { clamped }
  tdmessages.SetDownloadSpeedLimit(FDownloadSpeedKB);
  FDownloadSpeedKB := tdmessages.DownloadSpeedLimit;
  ApplySurfaceColor;
  UpdatePresencePanel;
  { No chat is open yet — hidden until the Welcome screen (or a real
    chat selection) says otherwise, see the property's own comment.
    Not strictly needed before the window is even shown, but keeps
    FMessageInput/FInputSplitter's actual Visible state honest from
    the start rather than whatever msginput.lfm's default happens to
    be. }
  UpdateMessageInputVisibility;

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
  { Closing the pre-login window: nothing useful to keep alive in the
    tray for, always a real quit. }
  FQuitRequested := True;
  Close;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  { The window's own close button, with "close to tray" on: hide
    instead of quitting. An explicit quit (File > Quit, the tray
    icon's "Exit", RequestAppClose) always sets FQuitRequested first
    and skips this branch. }
  if FCloseToTray and not FQuitRequested then begin
    CanClose := False;
    Hide;
    Exit;
  end;

  if FTdClosed then begin
    CanClose := True;
    Exit;
  end;
  { Hidden right away, before TDLib has even confirmed the close:
    RequestClose on every account fires a burst of updates as chats
    and messages get torn down on the way out, and with the window
    still visible and repainting that showed up as a visible "freeze"
    — the chat list emptying out, a stray message left behind in the
    history frame from whatever chat was open. None of that is
    anything the user needs to see; hiding first means the whole
    teardown happens off-screen, same as an ordinary tray-hide. }
  Hide;
  CanClose  := TdApp.BeginShutdown(@ShutdownDone);
  FTdClosed := CanClose;
  if not CanClose then begin
    SetStatusText('Closing TDLib, waiting for confirmation...');
  end;
end;

procedure TFormMain.TrayIconDblClick(Sender: TObject);
begin
  if not Visible then begin
    Show;
  end;
  if WindowState = wsMinimized then begin
    WindowState := wsNormal;
  end;
  Application.BringToFront;
end;

procedure TFormMain.MenuItemTrayShowClick(Sender: TObject);
begin
  TrayIconDblClick(Sender);
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
  SetStatusText(Format('Info: %s (id %d)', [string(ARow.Title), ARow.Id]));
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
  { Always through the formatting/parse path now, not the old plain
    SendText — a message with none of the toolbar's markup in it is
    just formattedText with an empty entities array, parseTextEntities
    handles that the same as any other, no separate "was anything
    actually formatted" branch needed. }
  F.Model.SendFormattedText(utf8string(MsgText), FMessageInput.IsHtmlMode);
  FMessageInput.ClearText;
end;

procedure TFormMain.QuoteToInput(const AText: string);
begin
  if (FMessageInput = nil) or (not FMessageInput.Visible) then begin
    Exit;
  end;
  FMessageInput.InsertQuote(AText);
end;

procedure TFormMain.UpdateMessageInputVisibility;
var
  ShowInput, HasOverride, OverrideCanSend: boolean;
  F: TFrameHistory;
  ChatsModel: TTdChats;
  Groups: TTdSupergroups;
  Row: TChatRow;
begin
  if (FMessageInput = nil) or (FInputSplitter = nil) or (FNav = nil) then begin
    Exit;
  end;
  ShowInput := False;
  if FNav.Current is TFrameHistory then begin
    F := TFrameHistory(FNav.Current);
    if (F.Model <> nil) and (F.Model.ChatId <> 0) then begin
      ShowInput := True;
      { A chat being open only means somewhere to type INTO — not that
        sending is actually possible there. Two independent signals,
        checked in priority order:
          1) The viewer's OWN status in the chat's supergroup/channel
             (TTdSupergroups.OverridesPermissions) — a channel admin
             with posting rights, or the creator, CAN post there even
             though chat.permissions (below) says ordinary members
             can't; conversely a Restricted/Left/Banned status means
             they definitely CAN'T, whatever chat.permissions says.
             Wins outright when it gives a definite answer.
          2) chat.permissions.can_send_basic_messages (TChatRow.
             CanSendBasicMessages) — what an ORDINARY member may do,
             used only when (1) had no personal override to report
             (a plain Member, or the status hasn't loaded yet).
        Both looked up by chat id/supergroup id from the chat-list
        model, not anything TFrameHistory tracks itself — that frame
        has no per-chat permission state of its own. }
      ChatsModel := TdChatList;
      if ChatsModel <> nil then begin
        Row := ChatsModel.Lookup(F.Model.ChatId);
        if Row <> nil then begin
          HasOverride := False;
          if Row.SupergroupId <> 0 then begin
            Groups := TdSupergroupList;
            if Groups <> nil then begin
              HasOverride := Groups.OverridesPermissions(Row.SupergroupId, OverrideCanSend);
            end;
          end;
          if HasOverride then begin
            ShowInput := OverrideCanSend;
          end else if not Row.CanSendBasicMessages then begin
            ShowInput := False;
          end;
        end;
      end;
    end;
  end;
  FMessageInput.Visible := ShowInput;
  FInputSplitter.Visible := ShowInput;
  { With the input box showing, the splitter and the box's own 5px
    ChildSizing margin already separate the message area from the
    window's bottom edge. With it hidden (a channel one can't post in,
    or no chat open at all) the frame ran flush into the status bar
    instead — so the margin is put back here, by direct request, on the
    only side that loses it. Set on the host rather than inside
    TFrameHistory: it is a property of the work area's layout, decided
    here, and it applies to whatever frame the navigator has up. }
  if ShowInput then begin
    FNavHost.BorderSpacing.Bottom := 0;
  end else begin
    FNavHost.BorderSpacing.Bottom := WORKAREA_EDGE_MARGIN;
  end;
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

procedure TFormMain.SetStatusText(const AText: string);
begin
  StatusBar1.Panels[2].Text := AText;
end;

{ ---------------- presence (online/invisible) ---------------- }

procedure TFormMain.UpdatePresencePanel;
begin
  if FInvisible then begin
    StatusBar1.Panels[0].Text := 'Invisible';
  end else begin
    StatusBar1.Panels[0].Text := 'Online';
  end;
  StatusBar1.Invalidate;
end;

procedure TFormMain.SetPresence(AInvisible: boolean);
begin
  if AInvisible = FInvisible then begin
    Exit;
  end;
  FInvisible := AInvisible;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteBool('ui', 'invisible', FInvisible);
    finally
      Free;
    end;
  end;
  UpdatePresencePanel;
  ApplyPresence;
end;

procedure TFormMain.ApplyPresence;
var
  ValStr: utf8string;
begin
  if TdRequests = nil then begin
    Exit;
  end;
  if FInvisible then begin
    ValStr := 'false';
  end else begin
    ValStr := 'true';
  end;
  { TDLib has no bare-bool shortcut for setOption — the value must be
    wrapped in an optionValueBoolean object. }
  TdRequests.SendRequest('setOption',
    '"name":"online","value":{"@type":"optionValueBoolean","value":' +
    ValStr + '}', @PresenceSetDone);
end;

procedure TFormMain.PresenceSetDone(Sender: TObject; const AResp: TTdResponse);
begin
  if not AResp.Success then begin
    SetStatusText(Format('ERROR %d: %s',
      [AResp.ErrorCode, string(AResp.ErrorMessage)]));
  end;
end;

procedure TFormMain.StatusBar1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: integer);
var
  Pt: TPoint;
begin
  if Button <> mbLeft then begin
    Exit;
  end;
  if StatusBar1.GetPanelIndexAt(X, Y) <> 0 then begin
    Exit;
  end;
  Pt.X := X;
  Pt.Y := Y;
  Pt := StatusBar1.ClientToScreen(Pt);
  PresenceMenu.Popup(Pt.X, Pt.Y);
end;

procedure TFormMain.StatusBar1DrawPanel(AStatusBar: TStatusBar; APanel: TStatusPanel;
  const ARect: TRect);
const
  { Same ImageList1/ImageIndex the user assigned to MenuItemPresence
    Online/Invisible in the Designer (main.lfm) — kept in sync by hand,
    not read back from the menu items, so the panel shows the exact
    same icon as the popup it opens. }
  PRESENCE_ICON_ONLINE = 8;
  PRESENCE_ICON_INVISIBLE = 9;
var
  IconIdx, IconY, TextX, TextY: integer;
begin
  if APanel.Index <> 0 then begin
    Exit;
  end;

  if FInvisible then begin
    IconIdx := PRESENCE_ICON_INVISIBLE;
  end else begin
    IconIdx := PRESENCE_ICON_ONLINE;
  end;

  TextX := ARect.Left + 4;
  if (ImageList1 <> nil) and (IconIdx < ImageList1.Count) then begin
    IconY := ARect.Top + (ARect.Bottom - ARect.Top - ImageList1.Height) div 2;
    ImageList1.Draw(AStatusBar.Canvas, TextX, IconY, IconIdx, True);
    TextX := TextX + ImageList1.Width + 4;
  end;

  AStatusBar.Canvas.Brush.Style := bsClear;
  AStatusBar.Canvas.Font.Color := clWindowText;
  TextY := ARect.Top + (ARect.Bottom - ARect.Top - AStatusBar.Canvas.TextHeight(APanel.Text)) div 2;
  AStatusBar.Canvas.TextOut(TextX, TextY, APanel.Text);
end;

procedure TFormMain.PresenceOnlineClick(Sender: TObject);
begin
  SetPresence(False);
end;

procedure TFormMain.PresenceInvisibleClick(Sender: TObject);
begin
  SetPresence(True);
end;

procedure TFormMain.SetChatListStatus(const AText: string);
begin
  StatusBar1.Panels[1].Text := AText;
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
  UpdateMessageInputVisibility;
end;

procedure TFormMain.welcomeScreen(Sender: TObject);
begin
  FNav.ShowFrame(TFrameWelcome);
  UpdateMessageInputVisibility;
end;

procedure TFormMain.menuQuitClick(Sender: TObject);
begin
  { File > Quit and the tray icon's own "Exit" item (same handler) —
    both are one deliberate click away from actually closing TDLib and
    ending the process (unlike the window's own close button, which
    just hides to the tray by default), so confirm first, same pattern
    as btnLogoutClick. }
  if MessageDlg('Quit', 'Quit Telegram?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then begin
    Exit;
  end;
  { An explicit quit always goes through the real shutdown, regardless
    of FCloseToTray (see FormCloseQuery). }
  FQuitRequested := True;
  Close;
end;

{ ---------------- ITdStateListener ---------------- }

procedure TFormMain.TdStateChanged(AState: TTdAuthState);
begin
  { No longer displayed anywhere — the auth state is not useful
    information for the end user, only the Show/Hide decision below
    that's actually driven by it. }

  if AState = tasReady then begin
    { Re-applied on every transition to Ready, not just the first —
      this also covers switching the active account (TdActiveChanged
      re-calls TdStateChanged(ANew.State) below) and reconnects: each
      TDLib client has its own "online" option, so whichever account
      just became ready needs to be told again. Idempotent — resending
      the same value is harmless. }
    ApplyPresence;
    { Same "on every transition to Ready" reasoning as ApplyPresence,
      and for the same underlying reason: TdRequests talks to whichever
      account is active, so an account switch has to prune ITS cache,
      not re-prune the previous one. Repeats are harmless — tdstorage
      ignores a call while one is still running, and a cache already
      inside the limit loses nothing. }
    ApplyCacheLimit;
    if not Visible then begin
      Show;
      { The first screen is shown only once the form has actually
        appeared: frames are created lazily, doing it earlier would be
        wasted work. }
      if FNav.Current = nil then begin
        FNav.ShowFrame(TFrameWelcome);
        UpdateMessageInputVisibility;
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

procedure TFormMain.SetCloseToTray(AValue: boolean);
begin
  if AValue = FCloseToTray then begin
    Exit;
  end;
  FCloseToTray := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteBool('ui', 'closetotray', FCloseToTray);
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.SetAccentColor(AValue: TColor);
begin
  if AValue = FAccentColor then begin
    Exit;
  end;
  FAccentColor := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('ui', 'accentcolor', Integer(FAccentColor));
    finally
      Free;
    end;
  end;
end;

{ Both splitters, in place of the themed pattern TCustomSplitter would
  otherwise draw (see ApplySurfaceColor). Flat background plus a
  discreet three-dot grip, so the divider still reads as something
  draggable rather than becoming an invisible seam.

  The grip's color is derived from the background rather than named:
  the background is a user setting now and can be anything, so a fixed
  grey would disappear on some choices. Perceived brightness decides
  the direction (the usual 299/587/114 weighting — the eye is far more
  sensitive to green than to blue), and the dots go a quarter of the
  way toward black on a light background, toward white on a dark one. }
procedure TFormMain.SplitterPaint(Sender: TObject);
const
  DotSize = 2;
  DotGap  = 3;
  DotCount = 3;
var
  Spl: TSplitter;
  Cv: TCanvas;
  Bg: TColor;
  R, G, B, Lum, I, X, Y, Span: integer;
begin
  if not (Sender is TSplitter) then begin
    Exit;
  end;
  Spl := TSplitter(Sender);
  Cv := Spl.Canvas;

  Bg := ColorToRGB(Spl.Color);
  Cv.Brush.Style := bsSolid;
  Cv.Brush.Color := Bg;
  Cv.Pen.Style := psClear;
  Cv.FillRect(Spl.ClientRect);

  R := Bg and $FF;
  G := (Bg shr 8) and $FF;
  B := (Bg shr 16) and $FF;
  Lum := (R * 299 + G * 587 + B * 114) div 1000;
  if Lum > 128 then begin
    R := R - R div 4;
    G := G - G div 4;
    B := B - B div 4;
  end else begin
    R := R + (255 - R) div 4;
    G := G + (255 - G) div 4;
    B := B + (255 - B) div 4;
  end;
  Cv.Brush.Color := RGBToColor(R, G, B);

  { The dots run ALONG the divider — vertically for the left/right
    splitter (a vertical bar), horizontally for the top/bottom one —
    so the run is laid out on whichever axis is the long one. }
  Span := DotCount * DotSize + (DotCount - 1) * DotGap;
  if Spl.Align in [alLeft, alRight] then begin
    X := (Spl.Width - DotSize) div 2;
    Y := (Spl.Height - Span) div 2;
    for I := 0 to DotCount - 1 do begin
      Cv.FillRect(X, Y, X + DotSize, Y + DotSize);
      Inc(Y, DotSize + DotGap);
    end;
  end else begin
    X := (Spl.Width - Span) div 2;
    Y := (Spl.Height - DotSize) div 2;
    for I := 0 to DotCount - 1 do begin
      Cv.FillRect(X, Y, X + DotSize, Y + DotSize);
      Inc(X, DotSize + DotGap);
    end;
  end;
end;

procedure TFormMain.ApplySurfaceColor;
begin
  { Only the containers that genuinely own a background are named here.
    Everything inside them — the chat list frame and its grid, the chat
    info bar, the history frame, the input box's own panels — has
    ParentColor on and inherits this, so adding a new frame to the work
    area needs no change here.

    ParentBackground must be off wherever Color is expected to show at
    all: with it on, Windows themes the panel's background and ignores
    Color entirely. pnlLeft/pnlWork already have it off from main.lfm;
    FNavHost is created in code, where TPanel's default is ON. }
  pnlLeft.Color := FSurfaceColor;
  pnlWork.Color := FSurfaceColor;
  { Both splitters are their own painted controls, not children of the
    panels they sit between, so nothing propagates a parent color to
    them — and setting Color alone would not have been enough either:
    TCustomSplitter.Paint draws a THEMED pattern over the whole
    ClientRect and never looks at Color at all (read in
    customsplitter.inc, not guessed), which is why the divider stayed a
    bright strip through the middle of the window. That same routine
    offers the way out — it only draws the pattern "if not
    Assigned(OnPaint)" — so SplitterPaint below takes over, and Color
    is what it paints with. }
  splLeft.Color := FSurfaceColor;
  splLeft.OnPaint := @SplitterPaint;
  if FInputSplitter <> nil then begin
    FInputSplitter.Color := FSurfaceColor;
    FInputSplitter.OnPaint := @SplitterPaint;
  end;
  if FNavHost <> nil then begin
    FNavHost.ParentBackground := False;
    FNavHost.Color := FSurfaceColor;
  end;
  if FMessageInput <> nil then begin
    { The input panel keeps ParentColor off (msginput.lfm) so the
      Designer can show it on its own — set directly rather than
      inherited. }
    FMessageInput.Color := FSurfaceColor;
  end;
end;

procedure TFormMain.SetSurfaceColor(AValue: TColor);
begin
  if AValue = FSurfaceColor then begin
    Exit;
  end;
  FSurfaceColor := AValue;
  ApplySurfaceColor;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('ui', 'surfacecolor', Integer(FSurfaceColor));
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.SetDownloadConcurrency(AValue: integer);
begin
  tdmessages.SetDownloadConcurrency(AValue);
  { Read back rather than stored as given — tdmessages clamps to
    DOWNLOAD_CONCURRENCY_MIN/MAX, and config.ini should hold what is
    actually in effect. }
  AValue := tdmessages.DownloadConcurrency;
  if AValue = FDownloadConcurrency then begin
    Exit;
  end;
  FDownloadConcurrency := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('downloads', 'concurrency', FDownloadConcurrency);
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.SetDownloadSpeedKB(AValue: integer);
begin
  tdmessages.SetDownloadSpeedLimit(AValue);
  AValue := tdmessages.DownloadSpeedLimit;   { clamped, see the other setter }
  if AValue = FDownloadSpeedKB then begin
    Exit;
  end;
  FDownloadSpeedKB := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('downloads', 'speedkb', FDownloadSpeedKB);
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.SetCacheLimitMB(AValue: integer);
begin
  if AValue < CACHE_LIMIT_MIN_MB then begin
    AValue := CACHE_LIMIT_MIN_MB;
  end;
  if AValue > CACHE_LIMIT_MAX_MB then begin
    AValue := CACHE_LIMIT_MAX_MB;
  end;
  if AValue = FCacheLimitMB then begin
    Exit;
  end;
  FCacheLimitMB := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('storage', 'maxcachemb', FCacheLimitMB);
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.SetCacheTtlDays(AValue: integer);
begin
  if AValue < CACHE_TTL_MIN_DAYS then begin
    AValue := CACHE_TTL_MIN_DAYS;
  end;
  if AValue > CACHE_TTL_MAX_DAYS then begin
    AValue := CACHE_TTL_MAX_DAYS;
  end;
  if AValue = FCacheTtlDays then begin
    Exit;
  end;
  FCacheTtlDays := AValue;
  with TIniFile.Create(TdApp.BaseDir + 'config.ini') do begin
    try
      WriteInteger('storage', 'ttldays', FCacheTtlDays);
    finally
      Free;
    end;
  end;
end;

procedure TFormMain.ApplyCacheLimit;
begin
  if (FCacheLimitMB <= 0) and (FCacheTtlDays <= 0) then begin
    Exit;
  end;
  { Deliberately not subscribed to TdCache.OnChanged: that is a
    single-listener event and it belongs to the Storage settings
    section, which is the only place the numbers are shown. A silent
    prune at startup is the intended behavior. }
  TdCache.Cleanup(FCacheLimitMB, FCacheTtlDays);
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
  SetStatusText(Format('ERROR %d [%s]: %s',
    [ACode, string(AContext), string(AMessage)]));
end;

end.
