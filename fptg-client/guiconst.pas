unit guiconst;

{$mode objfpc}{$H+}

{ Именованные константы окна (fptg-client): карточки на рабочем
  столе, окошко входящего звонка, окно мини-приложения, WebView2.
  Отделены от серверного constants.pas 2026-10-07; общие с сервером
  значения окно пока берёт оттуда. }

interface

uses
  Graphics, constants;

const

  { ================= the application itself ================= }

  { Прежнее название (до 2026-10-06): ярлык в «Пуске» с ним удаляется
    при старте (appid.pas), папка профиля WebView2 с ним переезжает в
    новую (webview2.pas). }
  APP_TITLE_LEGACY = 'TG Orchestrator';
  { Установщик WebView2 Runtime (Evergreen Bootstrapper, Microsoft): на
    Windows 11 он уже есть, на Windows 10 — бывает, что нет. }
  WEBVIEW2_DOWNLOAD_URL = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  WEBVIEW2_NEEDED_TEXT = 'The Microsoft Edge WebView2 Runtime is needed to show the interface. '
    + 'Windows 11 has it built in; on Windows 10 it may have to be installed.';
  { Папки данных в %LOCALAPPDATA%: нынешняя и прежняя. }
  APP_DATA_DIR = 'fptg';
  APP_DATA_DIR_LEGACY = 'tgorchestrator';

  { ================= avatarcache.pas ================= }

  PALETTE: array[0..6] of TColor = (
    TColor($5B8BE3), TColor($5FBF6B), TColor($4B5FE8),
    TColor($C77BD8), TColor($D8B24B), TColor($5BC2D8), TColor($6B6BE8));

  { ================= подключение к серверу ================= }

  { Секция подключения в conf.dat окна (SECURE_CONFIG_FILE рядом с
    fptg-client.exe — тот же файл и формат, что у сервера). }
  GUI_CONFIG_SECTION = 'connection';
  { Папка страницы рядом с fptg-client.exe — сайт https://WEB_APP_HOST/
    (WebView2, виртуальный хост). }
  GUI_WEB_DIR = 'web';
  { Окно входа — страница из файлов окна (до входа сервер ничего не
    отдаёт). }
  CONNECT_PAGE = 'connect.html';

  { ================= рамка окна (DWM) ================= }

  { Последние цвета рамки от страницы — в conf.dat окна: рамку красить
    ещё до загрузки страницы, иначе первый кадр не того цвета. }
  GUI_WINDOW_SECTION = 'window';
  GUI_FRAME_KEY = 'frame';
  { DWMWINDOWATTRIBUTE (dwmapi.h; в dwmapi.pp FPC 3.2.2 их ещё нет).
    Сверено по docs Microsoft, 2026-10-11. Тёмный режим — Windows 11
    22000 и Windows 10 20H1+; цвета — только Windows 11 22000+, на
    старых DwmSetWindowAttribute просто откажет. }
  FRAME_ATTR_DARK_MODE = 20;     { DWMWA_USE_IMMERSIVE_DARK_MODE, BOOL }
  FRAME_ATTR_BORDER = 34;        { DWMWA_BORDER_COLOR, COLORREF }
  FRAME_ATTR_CAPTION = 35;       { DWMWA_CAPTION_COLOR }
  FRAME_ATTR_TEXT = 36;          { DWMWA_TEXT_COLOR }
  { DWMWA_COLOR_DEFAULT: вернуть системный цвет. }
  FRAME_COLOR_DEFAULT = $FFFFFFFF;

  { ================= WebView2 ================= }

  { Журнал leveldb localStorage профиля (lsrepair.pas): блок и заголовок
    записи — leveldb doc/log_format.md; папка — внутри папки данных. }
  { Длина пути в системном диалоге «Сохранить как» (webview2.AskSavePath),
    в символах: длинные пути Windows, не MAX_PATH. }
  SAVE_DIALOG_PATH_MAX = 32767;

  LS_LOG_BLOCK = 32768;
  LS_LOG_HEADER = 7;
  LS_LEVELDB_SUBDIR = 'EBWebView\Default\Local Storage\leveldb\';

  { WebView2.h: COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION (UNKNOWN 0,
    MICROPHONE 1, CAMERA 2, GEOLOCATION 3) и
    COREWEBVIEW2_PERMISSION_STATE_ALLOW (DEFAULT 0, ALLOW 1, DENY 2). }
  WEBVIEW2_PERMISSION_KIND_GEOLOCATION = 3;
  WEBVIEW2_PERMISSION_KIND_MICROPHONE = 1;
  WEBVIEW2_PERMISSION_KIND_CAMERA = 2;
  WEBVIEW2_PERMISSION_STATE_ALLOW = 1;

  { ================= mini-app window, desktop cards ================= }

  { Окно мини-приложения бота (miniapp.pas): размер — как у окна
    Telegram Desktop, высоты полос — шапки с Back/Settings/Reload и
    кнопок приложения внизу. MINIAPP_APP_NAME — application_name в
    webAppOpenParameters (td_api.tl: 0-64 латинских букв, цифр и _). }
  MINIAPP_WIDTH = 420;
  MINIAPP_HEIGHT = 720;
  { Шапка: отступ MINIAPP_BAR_PAD по краям и между кнопками, кнопки
    высотой MINIAPP_BAR_BUTTON_H, по бокам текста — MINIAPP_BAR_BUTTON_PAD. }
  MINIAPP_BAR_PAD = 8;
  MINIAPP_BAR_BUTTON_H = 28;
  MINIAPP_BAR_BUTTON_PAD = 12;
  MINIAPP_BAR_BUTTON_RADIUS = 4;   { скругление кнопок шапки (TBCButton) }

  { desknotify.pas — карточки уведомлений на рабочем столе. Размеры —
    в пикселях при 96 dpi, модуль масштабирует их сам. }
  DESKNOTIFY_CLASS: PWideChar = 'TGODeskNotifyCard';
  DESKNOTIFY_WIDTH = 320;
  DESKNOTIFY_HEIGHT = 80;
  DESKNOTIFY_PAD = 10;             { край карточки -> аватарка }
  DESKNOTIFY_AVATAR = 60;
  DESKNOTIFY_TEXT_GAP = 12;        { аватарка -> текст }
  DESKNOTIFY_FONT = 'Segoe UI';
  DESKNOTIFY_LINE_GAP = 6;         { заголовок -> текст }
  DESKNOTIFY_CLOSE_ZONE = 28;      { квадрат клика по крестику в углу }
  DESKNOTIFY_CLOSE_SIZE = 9;       { сам нарисованный крестик }
  DESKNOTIFY_CLOSE_ALPHA = 150;    { крестик без наведения — приглушён }
  DESKNOTIFY_MARGIN = 8;           { от края рабочей области }
  DESKNOTIFY_GAP = 8;              { между карточками }
  DESKNOTIFY_LIFE_MS = 6000;
  DESKNOTIFY_FADE_MS = 150;
  DESKNOTIFY_SLIDE_PX_PER_S = 900;
  DESKNOTIFY_TICK_MS = 15;
  DESKNOTIFY_TICK_MAX_MS = 100;    { после зависания — не прыгать скачком }
  DESKNOTIFY_TEXT_MAX = 200;       { символов до подгонки по ширине }
  DESKNOTIFY_ELLIPSIS = #$E2#$80#$A6;   { «…» байтами UTF-8: литерал при codepage utf8 стал бы WideString }
  { Окошко входящего звонка (callpopup.pas): высота при 96 dpi. Ширина,
    угол и отступ от края — как у обычных уведомлений (DESKNOTIFY_WIDTH,
    настройка угла, DESKNOTIFY_MARGIN). Вёрстка callcard.html
    рассчитана на этот размер. }
  CALLPOPUP_HEIGHT = 164;
  { Текст образца карточек (настройки уведомлений). }
  DESKNOTIFY_SAMPLE_TEXT = 'This is how notifications will look';
  DESKNOTIFY_THEME_KEY = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
  DESKNOTIFY_THEME_VALUE = 'AppsUseLightTheme';
  { Цвета — как у Telegram Desktop: дневная и ночная (синяя) темы. }
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
