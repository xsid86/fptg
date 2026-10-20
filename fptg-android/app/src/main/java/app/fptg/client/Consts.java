package app.fptg.client;

/** The app's named constants, in one place (as constants.pas / guiconst.pas). */
final class Consts {
    private Consts() {}

    /** Where the page lives: served by the app itself from the APK (Shell),
     *  the same origin the Windows window uses — the server lets it in. */
    static final String WEB_ORIGIN = "https://fptg.example";
    static final String WEB_HOST = "fptg.example";
    /** The page files inside the APK assets (app/build.gradle, copyWeb). */
    static final String WEB_ASSETS = "web";
    static final String APP_PAGE = "index.html";
    static final String CONNECT_PAGE = "connect.html";
    /** The port offered on the sign-in page when none is remembered. */
    static final int DEFAULT_PORT = 7654;

    /** The page's way to the app (window.FptgAndroid) and back (window.__fptgHost). */
    static final String BRIDGE_NAME = "FptgAndroid";

    /** Notification channels. */
    static final String CHANNEL_MESSAGES = "messages";
    static final String CHANNEL_CALLS = "calls";
    static final String CHANNEL_SERVICE = "service";
    /** Fixed notification ids; messages use their chat's own. */
    static final int NOTE_SERVICE = 1;
    static final int NOTE_CALL = 2;

    /** Intent extra: the chat to open (a tap on a message notification). */
    static final String EXTRA_CHAT = "chatId";

    /** Activity request codes. */
    static final int REQ_FILES = 1;
    static final int REQ_PERMISSIONS = 2;
    static final int REQ_NOTIFICATIONS = 3;

    /** Downloads: the buffer and how long to wait for the server. */
    static final int DOWNLOAD_BUFFER = 64 * 1024;
    static final int DOWNLOAD_TIMEOUT_MS = 30000;

    /** The Android Keystore key that encrypts the refresh token at rest. */
    static final String KEY_ALIAS = "fptg.session";
}
