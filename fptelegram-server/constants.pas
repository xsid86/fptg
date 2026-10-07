unit constants;

{$mode objfpc}{$H+}

{ Именованные константы сервера (fptelegram-server) по темам. Модуль
  ничего не подключает — он на дне графа зависимостей, и "uses
  constants" не даёт цикла ни из какого модуля. LCL тут тоже нет:
  сервер собирается консольной программой.

  Константы окна (карточки на рабочем столе, окно мини-приложения,
  WebView2) — в fptelegram-gui/guiconst.pas. Общие с окном (APP_TITLE,
  пределы настроек карточек) лежат здесь, пока программа одна
  (TODO.md, «Разделение на сервер и GUI»).

  Константа не может ссылаться на объявленную ниже в том же блоке
  const, поэтому группы, от которых зависят другие, — выше. }

interface

type
  { Цвет в раскладке LCL-ного TColor ($00BBGGRR), но без Graphics. }
  TTdColor = type LongInt;

const

  { ================= the application itself ================= }

  { The name the user sees: the window caption, the tray tooltip, and -
    through the Start-menu shortcut appid.pas writes - the header of
    every Windows notification. One constant because those three must
    agree; the shortcut is matched BY NAME, so changing this leaves the
    old one behind in the Start menu. }
  APP_TITLE = 'FPTelegram';

  { ================= history and media ================= }

  { Sender color wheel. The page gets only the index into it (webapi,
    'f<index>'), the colors themselves are in its CSS; the values here
    are the originals. TTdColor is $00BBGGRR, so each entry carries its
    RGB name in a comment for readability. }
  SENDER_PALETTE: array[0..7] of TTdColor = (
    $2222B2,  { RGB(178, 34, 34)  firebrick }
    $228B22,  { RGB( 34,139, 34)  forest green }
    $A0501E,  { RGB( 30, 80,160)  steel blue }
    $800080,  { RGB(128,  0,128)  purple }
    $005AB4,  { RGB(180, 90,  0)  dark orange }
    $808000,  { RGB(  0,128,128)  teal }
    $8515C7,  { RGB(199, 21,133)  medium violet red }
    $008080   { RGB(128,128,  0)  olive }
  );

  { How many media files (photo/video/GIF/document/audio) may be
    downloading from TDLib at once — see tdmessages.pas,
    RequestFileDownload. Without a cap, one scroll through a media-rich
    chat with auto-download on fires AUTODL_PREFETCH_MESSAGES requests
    at TDLib in one go and they all compete for the same connection.
    User-configurable (Settings > General), these are just the default
    and the range the spin box allows. }
  DOWNLOAD_CONCURRENCY_DEFAULT = 3;
  DOWNLOAD_CONCURRENCY_MIN     = 1;
  DOWNLOAD_CONCURRENCY_MAX     = 20;

  { Download speed cap in KB/s, 0 = unlimited (the default — this is
    off unless the user turns it on). TDLib has no bandwidth setting of
    any kind (checked against the real td_api.tl, not assumed), so this
    is implemented on top of downloadFile's offset/limit window — see
    tdmessages.pas, the media download queue.

    The cap is enforced by how OFTEN a byte window is granted, not by
    how big it is. TDLib fetches in parts of its own and rounds a
    smaller window up to one: confirmed from tdlib_raw.log, where a
    paced download asked for 128000-byte windows and its prefix
    advanced in exact 524288-byte steps regardless. So the size of the
    window is not a throttle at all, and an earlier attempt to use it
    as one made the setting change nothing. The pacer instead keeps a
    byte budget that refills at the configured rate and spends what the
    download actually fetched — see tdmessages.pas.

    TD_DOWNLOAD_PART_BYTES is that observed part size. It is NOT a
    documented API value, so nothing depends on it being exact: it is
    only the smallest window worth asking for. If the real part is
    bigger, the budget still charges whatever was really fetched and
    the average rate stays correct. }
  DOWNLOAD_SPEED_DEFAULT_KB = 0;
  DOWNLOAD_SPEED_MIN_KB     = 0;
  DOWNLOAD_SPEED_MAX_KB     = 102400;
  DOWNLOAD_CHUNK_INTERVAL_MS = 250;
  TD_DOWNLOAD_PART_BYTES     = 512 * 1024;

  { Cache cleanup (tdstorage.pas, the settings window's Storage
    section). Nothing ever removed what the downloads above put in
    tdlib/accN/files, so the folder only grew — gigabytes of video for
    messages scrolled past once.

    The size cap is on by default, and deliberately so: a cache is by
    definition re-downloadable, and leaving the default at "unlimited"
    would mean the mechanism only works for whoever goes looking for
    it. CACHE_LIMIT_MB = 0 turns it off, and is what the age limit
    starts at — pruning by age is a second, independent rule most
    people don't need on top of a size cap.

    STORAGE_OPTIMIZE_TIMEOUT_MS is far above the 30s default of
    tdreq.pas: optimizeStorage walks the whole file database, and a
    timed-out request would report a failure for a cleanup that in
    fact completed. }
  CACHE_LIMIT_DEFAULT_MB = 2048;
  CACHE_LIMIT_MIN_MB     = 0;
  CACHE_LIMIT_MAX_MB     = 1024 * 1024;
  CACHE_TTL_DEFAULT_DAYS = 0;
  CACHE_TTL_MIN_DAYS     = 0;
  CACHE_TTL_MAX_DAYS     = 3650;
  STORAGE_OPTIMIZE_TIMEOUT_MS = 300000;

  { TDLib SearchMessagesFilter constructor names, passed straight into
    searchChatMessages' filter parameter (TTdMessages.SetSearchFilter).
    Spellings taken from the real td_api.tl (github.com/tdlib/td), not
    from memory — a wrong one is not a compile error, it is a runtime
    code-400 with an empty list and no other clue.

    "Empty" is a real filter, not the absence of one: it is what a
    plain text query with no type restriction uses. There is no "gifts"
    or "similar channels" member of this family at all — those are
    different requests entirely, which is why those buttons are still
    stubs. }
  TD_MSG_FILTER_EMPTY     = 'searchMessagesFilterEmpty';

  { ================= chat list ================= }

  { A deleted account: TDLib leaves its name empty, so it would show up
    nameless (in the chat list and the chat header) or as a bare
    "User <id>" (in the history, where TUserRow.DisplayName falls back
    to that). The name is substituted and a skull is stamped over the
    avatar — the ONLY frame in framechats' ImageListBig (32x32), which
    had been sitting in the .lfm unused since the pseudo-rows were
    redesigned and is back at work for this.
    No CHATROW_ prefix on purpose: all three surfaces use them. }
  DELETED_ACCOUNT_TITLE = 'Deleted account';
  { chatFolderName, per the TDLib schema: "1-12 characters without line
    feeds". Checked before sending rather than letting the server
    refuse the whole createChatFolder. }
  CHATROW_FOLDER_NAME_MAX = 12;

  { ================= auto-download settings ================= }

  { Five media types x five chat types — the checkbox grid in the
    "Auto download" settings section. AUTODL_*_KINDS are persistence
    keys in config.ini/[autodownload] (key "<media>.<chat>", e.g.
    "images.private"), AUTODL_*_CAPTIONS are the UI labels; both array
    pairs share the same order (media = sections/columns, chat = rows
    within a section). }
  AUTODL_MEDIA_KINDS: array[0..4] of string = ('images', 'video', 'audio', 'gif', 'files');
  AUTODL_MEDIA_CAPTIONS: array[0..4] of string = ('Images', 'Video', 'Audio', 'GIF', 'Files');
  AUTODL_CHAT_KINDS: array[0..4] of string = ('private', 'secret', 'groups', 'channels', 'bots');
  AUTODL_CHAT_CAPTIONS: array[0..4] of string = ('Private chats', 'Secret chats', 'Groups', 'Channels', 'Bots');

  { ================= message layout ================= }

  { The album cover shown at the left edge of TAudioWidget
    (framehistory.pas): content.audio.album_cover_thumbnail, or the
    smallest of content.audio.external_album_covers that still covers
    this size, or the headphones placeholder (TFrameHistory.Img48)
    when the track has neither. The placeholder frame already carries
    this rounding baked into its alpha, so AUDIO_COVER_RADIUS is what
    a real cover has to be masked with to match it. }
  AUDIO_COVER_SIZE   = 48;
  { How many EXTRA history pages may be fetched while looking for the
    unread boundary when a chat is opened (see
    TTdMessages.CheckUnreadBackfill). A cap is needed because a channel
    can have thousands of unread messages and walking all the way back
    to the boundary would be a request storm for a marker nobody would
    scroll to anyway. When it runs out the chat simply opens at the
    bottom with no divider, which is exactly what it did before. }
  UNREAD_BACKFILL_PAGES  = 4;

  { Photo preview (TPhotoWidget, framehistory.pas). Portrait
    (height>width): width capped at PHOTO_MAX_WIDTH, height scaled
    proportionally; landscape: height capped at PHOTO_MAX_HEIGHT
    instead. Small images are not upscaled — if the natural size is
    already below the cap, the preview stays natural size. This is only
    the upper cap — the actual column width at this point may be
    narrower (a non-wide window), in which case that wins, see AMaxW in
    ComputePhotoPreviewSize (msglayout.pas). Video previews
    (TVideoWidget also calls ComputePhotoPreviewSize) share the same
    cap rather than having their own — both message types should take
    up equally modest space in the chat. The full-size viewer
    (mediaviewer.pas) is NOT bound by this cap at all — it fits to the
    viewer window instead, see its own comment. }
  PHOTO_MAX_WIDTH     = 220;
  PHOTO_MAX_HEIGHT    = 220;

  { Download progress bar (TPhotoWidget/TVideoWidget, framehistory.pas)
    — drawn under the "download" icon while EnsurePhotoFile/
    EnsureVideoFile's downloadFile request is in flight (see
    ApplyPhotoFile/ApplyVideoFile, tdmessages.pas, which now track
    PhotoDownloadedSize/PhotoTotalSize and VideoDownloadedSize/
    VideoTotalSize instead of discarding every updateFile before
    completion). Width/height/track-background by direct request — the
    fill color is APP_ACCENT_COLOR (or its live override) above, not a
    constant here, since it's meant to change without touching this
    geometry. DOWNLOAD_PROGRESS_GAP is the vertical gap from the
    download icon's own bottom edge to the bar — not reusing MSG_PAD_V
    (that one means "distance from the block's edge", a different
    relationship). }
  DOWNLOAD_PROGRESS_W = 100;

  { ================= qrrender.pas ================= }

  { Standard quiet zone — 4 modules on each side. Without it a
    significant fraction of scanners fail to read the code. }
  QR_QUIET_ZONE = 4;

  { ================= tdaccentcolors.pas ================= }

  { Highest accent id Telegram actually hands out. 0..6 are the built-in
    ones below; 7..20 arrive in updateAccentColors. Counted from this
    account's own tdlib_raw.log (updateAccentColors defines exactly
    7..20, and no chat in the log carries anything outside 0..20), not
    assumed — the web UI turns this range into a fixed set of CSS
    classes, so an id past the end has to fall back rather than go
    unstyled. }
  ACCENT_ID_MAX = 20;

  { TTdColor is $00BBGGRR. The comment on each value gives its RGB and
    name per core.telegram.org/api/colors — not an official hex value
    (none is published). }
  BUILT_IN_COLORS: array[0..6] of TTdColor = (
    $3C3CE6,  { RGB(230, 60, 60)   red }
    $1E8CE6,  { RGB(230,140, 30)   orange }
    $D25096,  { RGB(150, 80,210)   violet }
    $5AAA3C,  { RGB( 60,170, 90)   green }
    $AFA028,  { RGB( 40,160,175)   cyan }
    $DC7832,  { RGB( 50,120,220)   blue }
    $9650DC   { RGB(220, 80,150)   pink }
  );

  { ================= tdauth.pas ================= }

  MAX_PENDING = 32;

  { ================= tdchats.pas ================= }

  { Was COALESCE_MS — renamed on consolidation: the same name and value
    (50) was independently declared in tdmessages.pas
    (MESSAGES_COALESCE_MS below) — the only real name collision when
    merging every project constant into one unit, see file header. }
  CHATS_COALESCE_MS = 50;

  { ================= tdcore.pas ================= }

  SHUTDOWN_TIMEOUT = 5000;
  MANIFEST = 'accounts.ini';
  { Настройки — один зашифрованный файл рядом с exe (secureconfig.pas),
    одно имя у обеих программ: у сервера в нём аккаунты, api_id и
    токен, у окна — подключение к серверу. config.ini и MANIFEST —
    прежние открытые файлы сервера, их содержимое переезжает внутрь
    при первом запуске; SECURE_CONFIG_FILE_OLD — прежнее имя самого
    файла (до 2026-10-07), он просто переименовывается. }
  SECURE_CONFIG_FILE = 'conf.dat';
  SECURE_CONFIG_FILE_OLD = 'fptelegram.dat';
  SECURE_CONFIG_MAGIC = 'FPTS';
  SECURE_CONFIG_VERSION = 1;
  { Дополнительная энтропия DPAPI — строка программы: блоб ключа
    раскрывается только вместе с ней (и только у того же пользователя
    Windows). }
  SECURE_CONFIG_ENTROPY = 'FPTelegram/settings/v1';
  { Секция списка аккаунтов (бывшая [general] из accounts.ini). }
  SECURE_CONFIG_ACCOUNTS_SECTION = 'accounts';
  { Файл, который не расшифровался (чужой пользователь, другая машина,
    повреждение), откладывается с этим суффиксом, а не стирается. }
  SECURE_CONFIG_BAD_SUFFIX = '.unreadable';
  LEGACY_CONFIG_FILE = 'config.ini';

  { ================= tdjson.pas ================= }

  TDJSON_LIB = 'tdjson.dll';
  { Собственный лог TDLib (в stderr): только ошибки. По умолчанию он
    подробный и пишет тексты сообщений — у окна stderr никуда не ведёт,
    а консольный сервер выводил бы туда переписку. Что TDLib прислала,
    и так видно в tdlib_raw.log. }
  TDLIB_LOG_VERBOSITY = 1;

  { ================= tdmessages.pas ================= }

  { Was COALESCE_MS — renamed on consolidation, see the comment on
    CHATS_COALESCE_MS above: the same collision, same meaning (debounce
    interval for a deferred rebuild), different source unit. }
  MESSAGES_COALESCE_MS = 50;
  { getChatHistory can legitimately return fewer messages than limit
    (or even a single duplicate of the anchor) even when history isn't
    exhausted — see HistoryDone in tdmessages.pas. Retries the same
    anchor a few times with a real delay between attempts (not
    synchronously — a synchronous retry inside the same callback once
    hung the app in a tight request/response loop). }
  MAX_NO_PROGRESS_RETRIES = 5;
  RETRY_DELAY_MS = 400;
  { A first page is routinely ONE message - measured, not feared: in a
    sweep of eight chats every single getChatHistory answered the
    opening request with got=1. So the model keeps pulling until it
    holds a screenful, instead of handing the view one message and
    waiting to be asked again. Short, because this delay is felt on
    every chat opening; it exists only to leave the callback before
    asking again (a synchronous retry there once hung the app). }
  FILL_TARGET = 50;
  FILL_DELAY_MS = 30;
  { Paging back through a chat grows the loaded history without limit,
    and the whole of it is serialised to the page on every change -
    measured at 455 KB for 550 messages, against 50 KB for a freshly
    opened chat. Once the reader is back at the newest end, everything
    they paged past is of no use to anyone: it is dropped back to the
    FIRST PAGE, which is what a chat is opened with in the first
    place.

    Kept deliberately small rather than "a few pages, so a nudge of
    the wheel costs nothing": a nudge costs one getChatHistory against
    TDLib's local database, measured at about 5ms, while the pages
    behind it cost their weight on every single change to the model.
    And the scrollbar is the reader's map of the chat - leaving three
    pages in it says the history is longer than it is. }
  TRIM_AT = FILL_TARGET * 2;
  TRIM_KEEP = FILL_TARGET;
  { Повторы прыжка к сообщению, если цели в ответе не оказалось. Первый
    getChatHistory по чату, которого нет в локальной базе, отдаёт то,
    что лежит локально, — живой лог: 1 сообщение (total_count 1),
    СТАРШЕ цели; повтор того же запроса уже вернул 34 с целью. }
  JUMP_RETRY_MAX = 3;
  { Картинка карты геопозиции в сообщении (getMapThumbnailFile): размер
    до scale — по ширине пузыря медиа, scale 2 — для чёткости на HiDPI. }
  { Сервисы карт, где открывается точка геопозиции (util/maps.js на
    странице знает их адреса и названия). Пусто в config.ini —
    спрашивать каждый раз. }
  MAPS_PROVIDERS: array[0..6] of string = ('google', 'yandex', 'osm', 'bing',
    'apple', '2gis', 'here');
  MAP_THUMB_WIDTH = 360;
  MAP_THUMB_HEIGHT = 200;
  MAP_THUMB_SCALE = 2;
  MAP_THUMB_ZOOM = 16;
  { Предел длины «о себе», если getOption("bio_length_max") не ответил:
    70 без Premium, 140 с ним (живой лог: 140 у Premium-аккаунта). }
  ACCOUNT_BIO_MAX_DEFAULT = 70;
  { Сколько своих аватарок показывает галерея (getUserProfilePhotos
    отдаёт до 100 за раз; каждое качается синхронно перед ответом). }
  ACCOUNT_PHOTOS_MAX = 30;
  { Сколько участников группы показывает панель информации
    (getSupergroupMembers, последние). }
  INFO_MEMBERS_MAX = 200;
  { Подарков за один запрос getReceivedGifts (не больше 100 по td_api.tl). }
  GIFTS_PAGE = 60;
  { Сетка фото и видео в панели информации (media.list): сообщений за
    один запрос searchChatMessages (не больше 100 по td_api.tl) и
    сторона, с которой размер фото уже годится в превью плитки —
    первый photoSize не меньше этого по длинной стороне (тип «m»). }
  MEDIA_GRID_PAGE = 60;
  { Сколько id временных (pending) сообщений, уже заменённых через
    updateMessageSendSucceeded, помнит модель истории — чтобы опоздавший
    ответ sendMessage не вернул такое сообщение обратно (TTdMessages.
    FReplaced). Хватает с запасом: это отправки одного открытого чата. }
  REPLACED_IDS_MAX = 256;
  { Временный пароль для оплаты сохранённой картой (createTemporaryPassword
    valid_for; td_api.tl: от 60 до 86400 секунд). }
  PAYMENT_TMP_PASSWORD_SEC = 1800;
  { Подсказка упоминаний в поле ввода (mention.search): сколько людей
    просить у searchChatMembers / searchContacts. }
  MENTION_SUGGEST_LIMIT = 20;
  { Аватарка аккаунта в переключателе (accounts.list) уходит data-URI
    прямо из файла small-фото: id файлов у каждого клиента TDLib свои, а
    /media/<id> — одна таблица на всех, и аватарка неактивного аккаунта
    могла бы занять id чужого файла. Больше этого — только minithumbnail. }
  ACCOUNT_AVATAR_MAX_BYTES = 65536;
  MEDIA_GRID_THUMB_SIDE = 320;
  { То же для картинки строки ссылки — она мелкая (тип «s»). }
  MEDIA_LINK_THUMB_SIDE = 100;

  { ================= tdrecv.pas ================= }

  RECEIVE_TIMEOUT = 1.0;
  CLIENT_ID_TAG = '"@client_id":';

  { ================= tdreq.pas ================= }

  { Own @extra prefix. TTdAuth has its own ('auth:'), and they must not
    collide — otherwise two owners would compete for the same responses. }
  REQ_PREFIX = 'req:';

  { Synthetic error code for requests left unanswered. }
  TD_ERR_TIMEOUT = -1;
  { Synthetic code for requests canceled by client shutdown. }
  TD_ERR_CLOSED  = -2;

  { ================= localserver.pas / wsframe.pas ================= }

  { The HTTP+WebSocket server that serves the web UI; --server-port=N
    on the command line overrides this default. }
  LOCAL_SERVER_PORT = 7654;
  { Адрес привязки по умолчанию — только эта машина (--bind меняет). }
  LOCAL_SERVER_BIND = '127.0.0.1';
  { Где в настройках сервера (conf.dat) лежит его постоянный
    токен подключения. }
  SERVER_CONFIG_SECTION = 'server';
  SERVER_CONFIG_TOKEN = 'token';
  { Static files are served out of this directory next to the exe
    (never out of the project or the TDLib cache — see MapPath, which
    additionally refuses anything that escapes it). }
  { Страница — часть морды (fptelegram-gui/web); сервер раздаёт её
    оттуда (и окну, и обычному браузеру). На другой машине — --web-dir.
    Показ страницы окном из своих файлов — TODO, шаг 3б. }
  LOCAL_SERVER_WEB_DIR = {$IFDEF WINDOWS}'..\fptelegram-gui\web'{$ELSE}'../fptelegram-gui/web'{$ENDIF};
  { Ссылка с токеном — ещё и в файл рядом с exe: для службы, у которой
    консоли нет. Удаляется при остановке. }
  LOCAL_SERVER_URL_FILE = 'server_url.txt';
  { The cookie the root page is given, so that <img>/<video> URLs the
    page builds afterwards carry the token without having to append it
    to every one of them. }
  LOCAL_SERVER_COOKIE = 'tgsid';
  { 128 bits, from the OS CSPRNG. This is effectively a session key:
    anything on this machine that can reach the port can drive the
    account once it has the token. }
  LOCAL_SERVER_TOKEN_BYTES = 16;

  { Accept is polled rather than blocked on, so Terminate is noticed
    within one of these instead of needing the socket pulled out from
    under a blocked call. }
  LOCAL_SERVER_ACCEPT_POLL_MS = 200;
  LOCAL_SERVER_HTTP_TIMEOUT_MS = 15000;
  { A cap on the request head, because without one a peer can make a
    connection thread grow a list until the process dies. }
  LOCAL_SERVER_MAX_HEADER_BYTES = 16384;
  LOCAL_SERVER_SEND_CHUNK = 65536;
  { How long shutdown waits for live connections to unwind before
    giving up on them. Bounded: a stuck connection must not hold
    application exit. }
  LOCAL_SERVER_STOP_WAIT_MS = 2000;

  { Same idea as the accept poll, for the WebSocket read loop. }
  LOCAL_SERVER_WS_POLL_MS = 200;
  LOCAL_SERVER_WS_READ_TIMEOUT_MS = 15000;
  { The point past which a peer is told it has gone too far instead of
    being allowed to make this process allocate whatever it claimed.
    Generous on purpose: a history page of fifty parsed messages is a
    genuinely large JSON. }
  LOCAL_SERVER_WS_MAX_PAYLOAD = 16 * 1024 * 1024;
  { Server-side keepalive. This is what detects a peer that vanished
    without a FIN (a sleeping laptop, a killed browser); without it
    such a connection sits in the read loop forever holding a thread. }
  LOCAL_SERVER_WS_PING_MS = 20000;

  { Приём файлов со страницы (POST /upload, localserver.pas) для
    отправки в чат. Каждый файл ложится в свой подкаталог со случайным
    id — под СВОИМ именем, потому что TDLib берёт имя документа из
    пути inputFileLocal. Каталог рядом с exe и чистится при каждом
    старте сервера: отправленные файлы удаляет модель по
    updateMessageSendSucceeded, а остаются только брошенные.
    Потолок — 4 ГБ, предел Telegram для Premium; без Premium TDLib
    откажет сам и скажет почему. }
  LOCAL_SERVER_UPLOAD_PATH = '/upload';
  LOCAL_SERVER_UPLOAD_DIR = 'uploads';
  LOCAL_SERVER_UPLOAD_MAX = Int64(4) * 1024 * 1024 * 1024;
  LOCAL_SERVER_UPLOAD_CHUNK = 65536;
  { Имя файла в пути — без того, что Windows в имени не допускает, и
    не длиннее этого (запас под путь к каталогу до MAX_PATH). }
  LOCAL_SERVER_UPLOAD_NAME_MAX = 120;

  { sendMessageAlbum группирует 2..10 сообщений (td_api.tl). Больше
    файлов уходит несколькими альбомами подряд. }
  SEND_ALBUM_MAX = 10;
  { Размер шрифта (высота строки в пикселях при 96 dpi) — настройка,
    отдельно у заголовка и у текста. Обе строки вместе центрируются по
    высоте карточки; при 24+24 они ещё помещаются в DESKNOTIFY_HEIGHT. }
  DESKNOTIFY_FONT_MIN = 10;
  DESKNOTIFY_FONT_MAX = 24;
  DESKNOTIFY_TITLE_FONT_DEFAULT = 17;
  DESKNOTIFY_TEXT_FONT_DEFAULT = 17;
  { Сколько карточек одновременно — настройка; больше — старшие уходят. }
  DESKNOTIFY_LIMIT_MIN = 1;
  DESKNOTIFY_LIMIT_MAX = 5;
  DESKNOTIFY_LIMIT_DEFAULT = 4;
  { Углы экрана: коды для config.ini и страницы. Первая буква — верх или
    низ, вторая — лево или право; desknotify.pas разбирает их так же. }
  DESKNOTIFY_CORNERS: array[0..3] of string = ('tl', 'tr', 'bl', 'br');
  DESKNOTIFY_CORNER_DEFAULT = 3;   { правый нижний, как у Telegram Desktop }
  MINIAPP_APP_NAME = 'FPTelegram';

  { A SAFETY NET, not the delivery path (webapi.pas). A socket thread
    that queues a command also wakes the main thread immediately
    through TThread.Queue, so this interval only matters if something
    ever stops that wake-up from arriving — hence a lazy value
    rather than a frame-sized one. It began life AS the delivery path,
    at 15 ms, and measured a ~16 ms median round trip on every single
    command: exactly the kind of tax that is easy to add and hard to
    remove once things depend on it. }
  WEBAPI_FALLBACK_TICK_MS = 200;

  { Звонки (tdcalls.pas). Версия протокола tgcalls — только 10.0.0
    (InstanceV2ReferenceImpl): сигналинг там — обычные SDP offer/answer
    и ICE-кандидаты в JSON, которые браузерный RTCPeerConnection даёт
    как есть. 11.0.0 добавляет поверх SCTP-обёртку сигналинга — её у
    страницы нет, поэтому не предлагается. Сервер выбирает лучшую общую
    версию из списков обеих сторон (core.telegram.org/api/calls).
    Слои — как у tgcalls: Meta::MaxLayer() = 92, минимальный 65. }
  CALL_LIBRARY_VERSIONS: array[0..0] of utf8string = ('10.0.0');
  CALL_MIN_LAYER = 65;
  CALL_MAX_LAYER = 92;
  { Сколько участников видеочата просить за раз (loadGroupCallParticipants):
    остальные приходят обновлениями по мере того, как говорят. }
  VCHAT_LOAD_PARTICIPANTS = 100;
  { Цитата на сообщение, которого больше нет (getMessage ответил
    ошибкой) — как у официальных клиентов. }
  REPLY_DELETED_TEXT = 'Deleted message';

implementation

end.
