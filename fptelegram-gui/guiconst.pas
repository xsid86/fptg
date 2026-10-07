unit guiconst;

{$mode objfpc}{$H+}

{ Именованные константы окна (fptelegram-gui): карточки на рабочем
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
  { Папки данных в %LOCALAPPDATA%: нынешняя и прежняя. }
  APP_DATA_DIR = 'FPTelegram';
  APP_DATA_DIR_LEGACY = 'tgorchestrator';

  { ================= avatarcache.pas ================= }

  PALETTE: array[0..6] of TColor = (
    TColor($5B8BE3), TColor($5FBF6B), TColor($4B5FE8),
    TColor($C77BD8), TColor($D8B24B), TColor($5BC2D8), TColor($6B6BE8));

  { ================= подключение к серверу ================= }

  { Секция подключения в conf.dat окна (SECURE_CONFIG_FILE рядом с
    FPTelegram.exe — тот же файл и формат, что у сервера). }
  GUI_CONFIG_SECTION = 'connection';
  { Папка страницы рядом с FPTelegram.exe — сайт https://WEB_APP_HOST/
    (WebView2, виртуальный хост). }
  GUI_WEB_DIR = 'web';
  { Окно входа — страница из файлов окна (до входа сервер ничего не
    отдаёт). }
  CONNECT_PAGE = 'connect.html';

  { ================= WebView2 ================= }

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
