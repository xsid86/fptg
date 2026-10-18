unit guiconst;

{$mode objfpc}{$H+}

{ Named constants of the window (fptg-client): desktop cards, the incoming
  call pop-up, the mini app window, WebView2. Separated from the server's
  constants.pas on 2026-10-07; values shared with the server the window
  still takes from there. }

interface

uses
  Graphics, constants;

const

  { ================= the application itself ================= }

  { The former name (before 2026-10-06): a Start menu shortcut with it is
    removed at start (appid.pas), the WebView2 profile folder with it moves
    to the new one (webview2.pas). }
  APP_TITLE_LEGACY = 'TG Orchestrator';
  { The WebView2 Runtime installer (Evergreen Bootstrapper, Microsoft):
    Windows 11 has it already, Windows 10 sometimes does not. }
  WEBVIEW2_DOWNLOAD_URL = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  WEBVIEW2_NEEDED_TEXT = 'The Microsoft Edge WebView2 Runtime is needed to show the interface. '
    + 'Windows 11 has it built in; on Windows 10 it may have to be installed.';
  { Data folders in %LOCALAPPDATA%: the current one and the former one. }
  APP_DATA_DIR = 'fptg';
  APP_DATA_DIR_LEGACY = 'tgorchestrator';

  { ================= avatarcache.pas ================= }

  PALETTE: array[0..6] of TColor = (
    TColor($5B8BE3), TColor($5FBF6B), TColor($4B5FE8),
    TColor($C77BD8), TColor($D8B24B), TColor($5BC2D8), TColor($6B6BE8));

  { ================= connection to the server ================= }

  { The connection section in the window's conf.dat (SECURE_CONFIG_FILE —
    the same file and format as the server's). }
  GUI_CONFIG_SECTION = 'connection';
  { The page folder next to fptg-client.exe — the site https://WEB_APP_HOST/
    (WebView2, virtual host). }
  GUI_WEB_DIR = 'web';
  { The sign-in window — a page from the window's files (before sign-in the
    server gives nothing). }
  CONNECT_PAGE = 'connect.html';

  { ================= window frame (DWM) ================= }

  { The latest frame colours from the page — in the window's conf.dat: the
    frame is painted before the page loads, otherwise the first frame has
    the wrong colour. }
  GUI_WINDOW_SECTION = 'window';
  GUI_FRAME_KEY = 'frame';
  { DWMWINDOWATTRIBUTE (dwmapi.h; FPC 3.2.2's dwmapi.pp lacks them yet).
    Checked against Microsoft's docs, 2026-10-11. Dark mode — Windows 11
    22000 and Windows 10 20H1+; colours — Windows 11 22000+ only, on older
    ones DwmSetWindowAttribute simply refuses. }
  FRAME_ATTR_DARK_MODE = 20;     { DWMWA_USE_IMMERSIVE_DARK_MODE, BOOL }
  FRAME_ATTR_BORDER = 34;        { DWMWA_BORDER_COLOR, COLORREF }
  FRAME_ATTR_CAPTION = 35;       { DWMWA_CAPTION_COLOR }
  FRAME_ATTR_TEXT = 36;          { DWMWA_TEXT_COLOR }
  { DWMWA_COLOR_DEFAULT: back to the system colour. }
  FRAME_COLOR_DEFAULT = $FFFFFFFF;

  { ================= WebView2 ================= }

  { The leveldb journal of the profile's localStorage (lsrepair.pas): the
    record's block and header — leveldb doc/log_format.md; the folder is
    inside the data folder. }
  { Path length in the system "Save as" dialog (webview2.AskSavePath), in
    characters: Windows long paths, not MAX_PATH. }
  SAVE_DIALOG_PATH_MAX = 32767;

  LS_LOG_BLOCK = 32768;
  LS_LOG_HEADER = 7;
  LS_LEVELDB_SUBDIR = 'EBWebView\Default\Local Storage\leveldb\';

  { WebView2.h: COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION (UNKNOWN 0,
    MICROPHONE 1, CAMERA 2, GEOLOCATION 3) and
    COREWEBVIEW2_PERMISSION_STATE_ALLOW (DEFAULT 0, ALLOW 1, DENY 2). }
  WEBVIEW2_PERMISSION_KIND_GEOLOCATION = 3;
  WEBVIEW2_PERMISSION_KIND_MICROPHONE = 1;
  WEBVIEW2_PERMISSION_KIND_CAMERA = 2;
  WEBVIEW2_PERMISSION_STATE_ALLOW = 1;

  { ================= mini-app window, desktop cards ================= }

  { The bot's mini app window (miniapp.pas): size — as Telegram Desktop's
    window, the heights of the strips — the header with Back/Settings/
    Reload and the app's buttons at the bottom. MINIAPP_APP_NAME —
    application_name in webAppOpenParameters (td_api.tl: 0-64 Latin
    letters, digits and _). }
  MINIAPP_WIDTH = 420;
  MINIAPP_HEIGHT = 720;
  { Header: MINIAPP_BAR_PAD margin at the edges and between buttons,
    buttons MINIAPP_BAR_BUTTON_H high, MINIAPP_BAR_BUTTON_PAD at the sides
    of the text. }
  MINIAPP_BAR_PAD = 8;
  MINIAPP_BAR_BUTTON_H = 28;
  MINIAPP_BAR_BUTTON_PAD = 12;
  MINIAPP_BAR_BUTTON_RADIUS = 4;   { rounding of the header buttons (TBCButton) }

  { desknotify.pas — desktop notification cards. Sizes — in pixels at
    96 dpi, the unit scales them itself. }
  DESKNOTIFY_CLASS: PWideChar = 'TGODeskNotifyCard';
  DESKNOTIFY_WIDTH = 320;
  DESKNOTIFY_HEIGHT = 80;
  DESKNOTIFY_PAD = 10;             { card edge -> avatar }
  DESKNOTIFY_AVATAR = 60;
  DESKNOTIFY_TEXT_GAP = 12;        { avatar -> text }
  DESKNOTIFY_FONT = 'Segoe UI';
  DESKNOTIFY_LINE_GAP = 6;         { title -> text }
  DESKNOTIFY_CLOSE_ZONE = 28;      { the click square of the cross in the corner }
  DESKNOTIFY_CLOSE_SIZE = 9;       { the drawn cross itself }
  DESKNOTIFY_CLOSE_ALPHA = 150;    { the cross without hover — dimmed }
  DESKNOTIFY_MARGIN = 8;           { from the edge of the work area }
  DESKNOTIFY_GAP = 8;              { between cards }
  DESKNOTIFY_LIFE_MS = 6000;
  DESKNOTIFY_FADE_MS = 150;
  DESKNOTIFY_SLIDE_PX_PER_S = 900;
  DESKNOTIFY_TICK_MS = 15;
  DESKNOTIFY_TICK_MAX_MS = 100;    { after a freeze — no jumping ahead }
  DESKNOTIFY_TEXT_MAX = 200;       { characters before fitting to the width }
  DESKNOTIFY_ELLIPSIS = #$E2#$80#$A6;   { "…" as UTF-8 bytes: a literal under codepage utf8 would become a WideString }
  { The incoming call pop-up (callpopup.pas): height at 96 dpi. Width,
    corner and margin from the edge — as ordinary notifications'
    (DESKNOTIFY_WIDTH, the corner setting, DESKNOTIFY_MARGIN). The layout of
    callcard.html is made for this size. }
  CALLPOPUP_HEIGHT = 164;
  { The text of the sample cards (notification settings). }
  DESKNOTIFY_SAMPLE_TEXT = 'This is how notifications will look';
  DESKNOTIFY_THEME_KEY = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
  DESKNOTIFY_THEME_VALUE = 'AppsUseLightTheme';
  { Colours — as in Telegram Desktop: the day and night (blue) themes. }
  DESKNOTIFY_LIGHT_BG = $FFFFFF;
  DESKNOTIFY_LIGHT_BORDER = $DEDEDE;
  DESKNOTIFY_LIGHT_TITLE = $222222;
  DESKNOTIFY_LIGHT_TEXT = $666666;
  DESKNOTIFY_DARK_BG = $2B2117;      { #17212B }
  DESKNOTIFY_DARK_BORDER = $21160E;  { #0E1621 }
  DESKNOTIFY_DARK_TITLE = $FFFFFF;
  DESKNOTIFY_DARK_TEXT = $BBB2AA;    { #AAB2BB }
  MINIAPP_BAR_H = MINIAPP_BAR_PAD + MINIAPP_BAR_BUTTON_H + MINIAPP_BAR_PAD;
  MINIAPP_BUTTON_H = 44;

implementation

end.
