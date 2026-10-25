unit constants;

{$mode objfpc}{$H+}

{ Named constants of the server (fptg-server), grouped by topic. The
  unit uses nothing — it sits at the bottom of the dependency graph, so
  "uses constants" never creates a cycle from any unit. No LCL here
  either: the server builds as a console program.

  Constants of the window (desktop cards, the mini app window,
  WebView2) live in fptg-client/guiconst.pas. Those shared with the
  window (APP_TITLE, the limits of the card settings) live here, from
  the time there was a single program (the "split into server and GUI"
  plan).

  A constant cannot refer to one declared further down in the same
  const block, so the groups others depend on come first. }

interface

type
  { A colour in the layout of the LCL TColor ($00BBGGRR), without Graphics. }
  TTdColor = type LongInt;

const

  { ================= the application itself ================= }

  { The name the user sees: the window caption, the tray tooltip, and -
    through the Start-menu shortcut appid.pas writes - the header of
    every Windows notification. One constant because those three must
    agree; the shortcut is matched BY NAME, so changing this leaves the
    old one behind in the Start menu. }
  APP_TITLE = 'fptg';

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
  { Settings — one encrypted file (secureconfig.pas), the same name for
    both programs: the server keeps its accounts, api_id and token in it,
    the window its connection to the server. config.ini and MANIFEST are
    the server's former plain files; their contents move inside on the
    first start. }
  SECURE_CONFIG_FILE = 'conf.dat';
  SECURE_CONFIG_MAGIC = 'FPTS';
  SECURE_CONFIG_VERSION = 1;
  { Extra DPAPI entropy — the program's string: the key blob opens only
    together with it (and only for the same Windows user). }
  SECURE_CONFIG_ENTROPY = 'fptg/settings/v1';
  { Section of the account list (the former [general] of accounts.ini). }
  SECURE_CONFIG_ACCOUNTS_SECTION = 'accounts';
  { A file that did not decrypt (another user, another machine,
    corruption) is set aside with this suffix rather than erased. }
  SECURE_CONFIG_BAD_SUFFIX = '.unreadable';
  LEGACY_CONFIG_FILE = 'config.ini';

  { ================= tdjson.pas ================= }

  TDJSON_LIB = 'tdjson.dll';
  { TDLib's own log (to stderr): errors only. By default it is verbose
    and writes message texts — the window's stderr goes nowhere, but the
    console server would print the correspondence there. What TDLib sent
    is visible in tdlib_raw.log anyway. }
  TDLIB_LOG_VERBOSITY = 1;
  { How many of the latest speakers the live stream bar shows
    (webapi.SpeakersJson). }
  VCHAT_BAR_SPEAKERS = 3;
  { Global search (webapi, ui/search.js): frequent chats as a strip, how
    many lists and messages to return at a time. }
  SEARCH_TOP_LIMIT = 30;
  SEARCH_LIST_LIMIT = 50;
  SEARCH_MESSAGES_LIMIT = 30;
  { How many characters of a rich message to collect for the preview in
    the chat list (tdchats.MessagePreview). }
  CHAT_PREVIEW_RICH_CHARS = 200;

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
  { Retries of a jump to a message when the target is not in the
    answer. The first getChatHistory for a chat missing from the local
    database returns what is stored locally — live log: 1 message
    (total_count 1), OLDER than the target; a repeat of the same request
    returned 34 including the target. }
  JUMP_RETRY_MAX = 3;
  { Map picture of a location in a message (getMapThumbnailFile): size
    before scale — the width of the media bubble, scale 2 — sharp on HiDPI. }
  { Map services a location point opens in (util/maps.js on the page
    knows their addresses and names). Empty in config.ini — ask every
    time. }
  MAPS_PROVIDERS: array[0..6] of string = ('google', 'yandex', 'osm', 'bing',
    'apple', '2gis', 'here');
  MAP_THUMB_WIDTH = 360;
  MAP_THUMB_HEIGHT = 200;
  MAP_THUMB_SCALE = 2;
  MAP_THUMB_ZOOM = 16;
  { Limit of the bio length when getOption("bio_length_max") gave no
    answer: 70 without Premium, 140 with it (live log: 140 for a Premium
    account). }
  ACCOUNT_BIO_MAX_DEFAULT = 70;
  { How many of one's own profile photos the gallery shows
    (getUserProfilePhotos returns up to 100 at a time; each one is
    downloaded synchronously before the answer). }
  ACCOUNT_PHOTOS_MAX = 30;
  { How many group members the info panel shows (getSupergroupMembers,
    recent). }
  INFO_MEMBERS_MAX = 200;
  { Gifts per getReceivedGifts request (no more than 100 per td_api.tl). }
  GIFTS_PAGE = 60;
  { The photo and video grid in the info panel (media.list): messages
    per searchChatMessages request (no more than 100 per td_api.tl) and
    the side from which a photo size is good enough for a tile preview —
    the first photoSize at least this long on its longer side (type "m"). }
  MEDIA_GRID_PAGE = 60;
  { How many ids of temporary (pending) messages already replaced through
    updateMessageSendSucceeded the history model remembers — so that a
    late sendMessage answer does not bring such a message back (TTdMessages.
    FReplaced). Plenty: these are the sends of one open chat. }
  REPLACED_IDS_MAX = 256;
  { Temporary password for paying with a saved card (createTemporaryPassword
    valid_for; td_api.tl: 60 to 86400 seconds). }
  PAYMENT_TMP_PASSWORD_SEC = 1800;
  { Mention suggestions in the input field (mention.search): how many
    people to ask searchChatMembers / searchContacts for. }
  MENTION_SUGGEST_LIMIT = 20;
  { The account avatar in the switcher (accounts.list) goes out as a
    data URI straight from the small photo file: file ids are per TDLib
    client, while /media/<id> is one table for all of them, and the avatar
    of an inactive account could take the id of somebody else's file.
    Larger than this — the minithumbnail only. }
  ACCOUNT_AVATAR_MAX_BYTES = 65536;
  MEDIA_GRID_THUMB_SIDE = 320;
  { The same for the picture of a link row — it is small (type "s"). }
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
  { Default bind address — this machine only (--bind changes it). }
  LOCAL_SERVER_BIND = '127.0.0.1';
  { ================= server window (panel/srvpanel.pas) ================= }

  { The window layout is in panel/srvpanel.lfm (Lazarus designer). Quit: how long to wait for TDLib to close its clients (TTdCore itself
    caps the wait at SHUTDOWN_TIMEOUT; this is the margin on top). }
  PANEL_QUIT_GIVEUP_MS = SHUTDOWN_TIMEOUT + 2000;
  { The port set in the window — in the server's conf.dat. }
  SERVER_CONFIG_SECTION = 'server';
  SERVER_CONFIG_PORT = 'port';
  { Who may connect (the first-run question, srvhost.pas): local — this
    computer, lan — the local network, internet — anyone; and the address
    it means (bind). --bind overrides it for one run. }
  SERVER_CONFIG_NETWORK = 'network';
  SERVER_CONFIG_BIND = 'bind';
  SERVER_NETWORK_LOCAL = 'local';
  SERVER_NETWORK_LAN = 'lan';
  SERVER_NETWORK_INTERNET = 'internet';
  { The archive row at the top of the chat list (webapi.ArchiveSummary):
    how many chat names its preview line carries. }
  ARCHIVE_SUMMARY_TITLES = 5;
  SERVER_BIND_ALL = '0.0.0.0';
  { This machine's address for other computers (localserver.MachineAddress):
    a UDP socket "connected" here picks the interface of the default route.
    UDP connect sends nothing — the address is never contacted. }
  ADDRESS_PROBE_IP = '8.8.8.8';
  ADDRESS_PROBE_PORT = '53';
  { Windows Firewall rules (fwrule.pas): the name, the port appended. }
  FIREWALL_RULE_NAME = 'fptg server, port ';

  { ================= single instance (instance.pas) ================= }

  { NAME.lock — the instance lock, NAME.instance — the port and key of
    the control channel. Both servers (console and windowed) are one
    instance: the data is shared. }
  INSTANCE_SERVER = 'server';
  INSTANCE_CLIENT = 'client';

  { ================= data folders (appdirs.pas) ================= }

  { %LOCALAPPDATA%\fptg\<program> (Unix: ~/.local/share/fptg/...). }
  APP_DATA_ROOT = 'fptg';
  { The server's data — data/ next to its exe (2026-10-19): every copy of
    the server folder is a separate server. }
  SERVER_DATA_DIR = 'data';
  APP_DATA_CLIENT = 'client';
  { Crash log of page commands (webapi.LogCommandCrash) — in the server's
    data folder; past SERVER_ERROR_LOG_MAX it starts over. }
  SERVER_ERROR_LOG = 'errors.log';
  SERVER_ERROR_LOG_MAX = 1024 * 1024;
  SERVER_ERROR_LOG_ARGS = 600;
  INSTANCE_LOCK_EXT = '.lock';
  INSTANCE_INFO_EXT = '.instance';
  INSTANCE_KEY_BYTES = 32;
  INSTANCE_IO_TIMEOUT_MS = 5000;
  INSTANCE_MAX_LINE = 65536;
  { A just started instance may not have written .instance yet. }
  INSTANCE_INFO_WAIT_TRIES = 30;
  INSTANCE_INFO_WAIT_MS = 100;
  { Remote control of another server: how often to ask for its state. }
  PANEL_REMOTE_POLL_MS = 2000;
  { Traffic statistics (srvhost): the server tick — traffic events to
    the pages and a getNetworkStatistics poll; the server window asks at
    the same step. }
  TRAFFIC_TICK_MS = 1000;

  { ================= TLS (tlscert.pas) ================= }

  { Our own self-signed certificate: RSA 2048, 10 years (the window
    remembers the fingerprint — the certificate must not change by
    itself), kept in conf.dat. }
  TLS_RSA_BITS = 2048;
  TLS_SELF_SIGNED_DAYS = 3650;
  TLS_SELF_SIGNED_NAME = 'fptg';
  TLS_CONFIG_SECTION = 'tls';
  { Raw TDLib log (tdjson.SetRawLog): the server window's checkbox, conf.dat. }
  LOG_CONFIG_SECTION = 'log';
  LOG_CONFIG_RAW = 'tdlib';
  TLS_CONFIG_CERT = 'cert';
  TLS_CONFIG_KEY = 'key';
  { A certificate of one's own from the server window — PATHS to PEM
    files, not their text: this way Synapse takes the whole chain
    (SslCtxUseCertificateChainFile), and a file renewed by certbot is
    picked up without changes. The --cert/--key command line keys win. }
  TLS_CONFIG_CERT_FILE = 'cert_file';
  TLS_CONFIG_KEY_FILE = 'key_file';

  { ================= sign-in (srvauth.pas) ================= }

  { Passwords — PBKDF2-HMAC-SHA256 (sha256u.pas): iterations, salt, hash. }
  AUTH_PBKDF2_ITERATIONS = 100000;
  AUTH_SALT_BYTES = 16;
  AUTH_HASH_BYTES = 32;
  { JWT signing secret (HS256) and refresh tokens — random bytes. }
  AUTH_JWT_KEY_BYTES = 32;
  AUTH_REFRESH_BYTES = 32;
  { A short JWT for requests (web socket, uploads) — an hour; the page
    renews it itself. The media JWT has no expiry and lives as long as
    the session: picture addresses stay in the page for hours. }
  AUTH_ACCESS_TTL_SEC = 3600;
  { A session (refresh token) unused for this many days expires. }
  AUTH_SESSION_IDLE_DAYS = 90;
  { Password guessing: this many failures from one address within the
    window — and the address waits. Plus PBKDF2 itself (~0.1 s a try). }
  AUTH_FAIL_LIMIT = 5;
  AUTH_FAIL_WINDOW_SEC = 600;
  AUTH_LOCK_SEC = 60;
  { Body of an /api/… request — a small JSON. }
  AUTH_MAX_BODY = 8192;
  AUTH_CONFIG_SECTION = 'auth';
  AUTH_CONFIG_JWT_KEY = 'jwtkey';
  AUTH_USERS_SECTION = 'users';
  AUTH_SESSIONS_SECTION = 'sessions';
  { Paths of the sign-in API (localserver.pas). }
  API_LOGIN_PATH = '/api/login';
  API_REFRESH_PATH = '/api/refresh';
  API_LOGOUT_PATH = '/api/logout';
  { Origin of the page in the fptg window: the window shows it from its
    own files under this name (WebView2, virtual host). The server lets
    its requests through (CORS, web socket) as its own. .example is a
    reserved domain (RFC 2606): no real site can have this name. }
  WEB_APP_HOST = 'fptg.example';
  WEB_APP_ORIGIN = 'https://' + WEB_APP_HOST;
  { Static files are served out of this directory next to the exe
    (never out of the project or the TDLib cache — see MapPath, which
    additionally refuses anything that escapes it). }
  { The page is part of the client (fptg-client/web); the server serves
    it from there (to the window and to an ordinary browser alike). On
    another machine — --web-dir. }
  LOCAL_SERVER_WEB_DIR = {$IFDEF WINDOWS}'..\fptg-client\web'{$ELSE}'../fptg-client/web'{$ENDIF};
  { The server's release archive: the page is the web folder next to the
    exe (tools/build_release.py); looked for when LOCAL_SERVER_WEB_DIR is
    not there. }
  LOCAL_SERVER_WEB_DIR_RELEASE = 'web';
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

  { Web socket close code "session revoked" (range 4000-4999 is for
    applications, RFC 6455): the page goes to sign-in instead of reconnecting. }
  LOCAL_SERVER_WS_CLOSE_SESSION_ENDED = 4001;
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

  { Files received from the page (POST /upload, localserver.pas) for
    sending to a chat. Each file goes into its own subfolder with a
    random id — under its OWN name, because TDLib takes a document's name
    from the inputFileLocal path. The folder is cleaned on every server
    start: sent files are removed by the model on
    updateMessageSendSucceeded, so only abandoned ones remain.
    The ceiling is 4 GB, Telegram's limit for Premium; without Premium
    TDLib refuses by itself and says why. }
  LOCAL_SERVER_UPLOAD_PATH = '/upload';
  LOCAL_SERVER_UPLOAD_DIR = 'uploads';
  LOCAL_SERVER_UPLOAD_MAX = Int64(4) * 1024 * 1024 * 1024;
  LOCAL_SERVER_UPLOAD_CHUNK = 65536;
  { A file name in a path — without what Windows does not allow in a
    name, and no longer than this (room for the folder path up to
    MAX_PATH). }
  LOCAL_SERVER_UPLOAD_NAME_MAX = 120;

  { ================= turnrelay.pas: the TURN relay for calls ================= }

  { The realm of the relay's credentials and the tail of its user names. }
  RELAY_REALM = 'fptg';
  { How long credentials given to the page stay valid. }
  RELAY_CREDENTIAL_SEC = 86400;
  { Allocation lifetime (RFC 8656: default 600 s, the client refreshes). }
  RELAY_DEFAULT_LIFETIME_SEC = 600;
  RELAY_MAX_LIFETIME_SEC = 3600;
  RELAY_PERMISSION_SEC = 300;
  RELAY_CHANNEL_SEC = 600;
  { A connection that has not allocated within this time is dropped. }
  RELAY_IDLE_MS = 30000;
  RELAY_POLL_MS = 200;
  RELAY_READ_TIMEOUT_MS = 15000;
  { The largest UDP datagram. }
  RELAY_MAX_DATAGRAM = 65536;
  { conf.dat: [relay] enabled=1, address=<public IPv4 or empty>,
    ports=<min>-<max> or empty for any. --relay-address, --relay-ports and
    --no-relay override them for one run. }
  RELAY_CONFIG_SECTION = 'relay';
  RELAY_CONFIG_ENABLED = 'enabled';
  RELAY_CONFIG_ADDRESS = 'address';
  RELAY_CONFIG_PORTS = 'ports';

  { sendMessageAlbum groups 2..10 messages (td_api.tl). More files go
    out as several albums in a row. }
  SEND_ALBUM_MAX = 10;
  { Font size (line height in pixels at 96 dpi) — a setting, separate
    for the title and the text. Both lines together are centred on the
    card's height; at 24+24 they still fit in DESKNOTIFY_HEIGHT. }
  DESKNOTIFY_FONT_MIN = 10;
  DESKNOTIFY_FONT_MAX = 24;
  DESKNOTIFY_TITLE_FONT_DEFAULT = 17;
  DESKNOTIFY_TEXT_FONT_DEFAULT = 17;
  { How many cards at once — a setting; beyond it the oldest go. }
  DESKNOTIFY_LIMIT_MIN = 1;
  DESKNOTIFY_LIMIT_MAX = 5;
  DESKNOTIFY_LIMIT_DEFAULT = 4;
  { Screen corners: codes for config.ini and the page. The first letter
    is top or bottom, the second left or right; desknotify.pas reads them
    the same way. }
  DESKNOTIFY_CORNERS: array[0..3] of string = ('tl', 'tr', 'bl', 'br');
  DESKNOTIFY_CORNER_DEFAULT = 3;   { bottom right, as in Telegram Desktop }
  MINIAPP_APP_NAME = 'fptg';

  { A SAFETY NET, not the delivery path (webapi.pas). A socket thread
    that queues a command also wakes the main thread immediately
    through TThread.Queue, so this interval only matters if something
    ever stops that wake-up from arriving — hence a lazy value
    rather than a frame-sized one. It began life AS the delivery path,
    at 15 ms, and measured a ~16 ms median round trip on every single
    command: exactly the kind of tax that is easy to add and hard to
    remove once things depend on it. }
  WEBAPI_FALLBACK_TICK_MS = 200;

  { Sponsored messages (webapi.pas, ads.*). The getChatSponsoredMessages
    answer lives this long per chat (core.telegram.org/api/sponsored-messages:
    "cache for 5 minutes"): every opening of a channel asks, but Telegram
    is asked no more often. Download priority of the ad's media — the same
    as the greeting sticker's: it may only be shown once downloaded. }
  SPONSORED_CACHE_MS = 5 * 60 * 1000;
  SPONSORED_DOWNLOAD_PRIORITY = 32;

  { Calls (tdcalls.pas). tgcalls protocol version — only 10.0.0
    (InstanceV2ReferenceImpl): its signalling is plain SDP offer/answer
    and ICE candidates in JSON, which the browser's RTCPeerConnection
    gives as is. 11.0.0 adds an SCTP signalling wrapper on top — the page
    has none, so it is not offered. The server picks the best common
    version from both sides' lists (core.telegram.org/api/calls).
    Layers — as in tgcalls: Meta::MaxLayer() = 92, minimum 65. }
  CALL_LIBRARY_VERSIONS: array[0..0] of utf8string = ('10.0.0');
  CALL_MIN_LAYER = 65;
  CALL_MAX_LAYER = 92;
  { How many video chat participants to ask for at once
    (loadGroupCallParticipants): the rest arrive as updates as they speak. }
  VCHAT_LOAD_PARTICIPANTS = 100;
  { A quote of a message that is gone (getMessage answered with an
    error) — as in the official clients. }
  REPLY_DELETED_TEXT = 'Deleted message';

  { TDLib updates that have no "getter" method, while the settings
    (ui/settings.js) need their latest value: quick reaction, folders
    (whether tags are on), Stars balance, the list of quick reactions.
    The account keeps the latest one of each type (tdaccount,
    KeptUpdate), the page reads it with the td.kept command. }
  KEPT_UPDATE_TYPES: array[0..5] of string = (
    'updateDefaultReactionType', 'updateChatFolders', 'updateOwnedStarCount',
    'updateActiveEmojiReactions', 'updateQuickReplyShortcuts', 'updateSavedMessagesTopicCount');

implementation

end.
