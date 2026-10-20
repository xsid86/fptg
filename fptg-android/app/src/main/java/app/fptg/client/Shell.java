package app.fptg.client;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Handler;
import android.os.Looper;
import android.os.Message;
import android.util.Log;
import android.content.MutableContextWrapper;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.MimeTypeMap;
import android.webkit.PermissionRequest;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * The page and everything around it — what webui.pas is for the Windows
 * window, with the same protocol to the same page (ui/shell.js, connect.js).
 *
 * One per process, NOT per screen: the WebView is created on a
 * MutableContextWrapper and the activity only borrows it. Swiping the app
 * away from Recents destroys the activity, not the page — the connection
 * stays, and with it the notifications (the KeepAlive service keeps the
 * process). If the system kills the process, the service brings the page
 * back by itself when it is restarted.
 */
final class Shell {
    private static final String TAG = "fptg";
    private static Shell instance;

    /** Defines window.chrome.webview for the page, as WebView2 has it: the
     *  page code is the Windows window's and talks to the shell through it.
     *  Put at the top of every page the app serves. */
    private static final String HOST_SHIM = "<script>(function(){"
        + "if(window.chrome&&window.chrome.webview)return;var L=[];window.chrome=window.chrome||{};"
        + "window.chrome.webview={"
        + "postMessage:function(s){" + Consts.BRIDGE_NAME + ".post(typeof s==='string'?s:JSON.stringify(s));},"
        + "addEventListener:function(t,f){if(t==='message')L.push(f);},"
        + "removeEventListener:function(t,f){var i=L.indexOf(f);if(i>=0)L.splice(i,1);}};"
        + "window.__fptgHost=function(m){L.slice().forEach(function(f){try{f({data:m});}catch(e){}});};"
        + "})();</script>";

    /** The Back key: close what is open over the app, or leave the chat for
     *  the list; 'exit' — nothing to close, the app goes to the background. */
    private static final String BACK_SCRIPT = "(function(){"
        + "var d=[].slice.call(document.querySelectorAll('dialog[open]')).pop();"
        + "if(d){d.close();return 'done';}"
        + "var p=document.querySelector('.pswp--open');"
        + "if(p){document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return 'done';}"
        + "var i=document.querySelector('.info-panel.is-open .info-panel__close');if(i){i.click();return 'done';}"
        + "var a=document.querySelector('.app');"
        + "if(a&&a.dataset.view==='chat'){var b=document.querySelector('.chat-header__back');"
        + "if(b){b.click();}else{a.dataset.view='list';}return 'done';}"
        + "return 'exit';})()";

    private static final Map<String, String> MIME = new HashMap<>();
    static {
        MIME.put("html", "text/html");
        MIME.put("js", "text/javascript");
        MIME.put("mjs", "text/javascript");
        MIME.put("css", "text/css");
        MIME.put("json", "application/json");
        MIME.put("svg", "image/svg+xml");
        MIME.put("png", "image/png");
        MIME.put("jpg", "image/jpeg");
        MIME.put("jpeg", "image/jpeg");
        MIME.put("webp", "image/webp");
        MIME.put("gif", "image/gif");
        MIME.put("woff", "font/woff");
        MIME.put("woff2", "font/woff2");
        MIME.put("ttf", "font/ttf");
        MIME.put("wasm", "application/wasm");
        MIME.put("map", "application/json");
        MIME.put("tgs", "application/octet-stream");
        MIME.put("mp3", "audio/mpeg");
        MIME.put("ogg", "audio/ogg");
        MIME.put("wav", "audio/wav");
    }

    final Context app;
    final Store store;
    final WebView web;
    private final MutableContextWrapper context;
    private final AssetManager assets;
    private final Handler main = new Handler(Looper.getMainLooper());

    /** The activity showing the page; null while it is in the background only. */
    private Activity activity;
    /** The status bar colour the page asked for (frame), and its icons. */
    int frameColor = 0xFF0B1630;
    boolean frameDark = true;

    // The certificate question, as in webui.pas: what the page was asked
    // about, and what the person trusted on the sign-in page.
    private String askedOrigin = "", askedPrint = "";
    private String trustOrigin = "", trustPrint = "";

    private ValueCallback<Uri[]> pendingFiles;
    private PermissionRequest pendingPermission;

    static Shell get(Context context) {
        if (instance == null) {
            instance = new Shell(context.getApplicationContext());
        }
        return instance;
    }

    private Shell(Context app) {
        this.app = app;
        store = new Store(app);
        assets = app.getAssets();
        context = new MutableContextWrapper(app);
        web = new WebView(context);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setSupportMultipleWindows(true);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setUserAgentString(s.getUserAgentString() + " fptg-android/" + BuildConfig.VERSION_NAME);
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG);
        web.setBackgroundColor(frameColor);
        web.addJavascriptInterface(new Bridge(), Consts.BRIDGE_NAME);
        web.setWebViewClient(new Client());
        web.setWebChromeClient(new Chrome());
        web.setDownloadListener((url, agent, disposition, mime, length) ->
            Downloads.start(this, url, disposition, mime));
        Notices.channels(app);
        connectSaved();
    }

    // ------------------------------------------------------------ activity

    /** The activity takes the page (dialogs, the file picker and <select>
     *  need an activity context). */
    void attach(Activity a) {
        activity = a;
        context.setBaseContext(a);
    }

    void detach(Activity a) {
        if (activity != a) return;
        activity = null;
        context.setBaseContext(app);
    }

    Activity activity() {
        return activity;
    }

    void back(Activity a) {
        web.evaluateJavascript(BACK_SCRIPT, (result) -> {
            if ("\"exit\"".equals(result)) a.moveTaskToBack(true);
        });
    }

    /** A tap on a message notification: the page opens the chat. */
    void openChat(long chatId) {
        if (chatId == 0) return;
        JSONObject o = new JSONObject();
        try {
            o.put("t", "openChat");
            o.put("chatId", chatId);
        } catch (Exception ignored) {
            return;
        }
        toPage(o);
    }

    // ------------------------------------------------------------ navigation

    private void connectSaved() {
        if (store.hasSession()) showApp();
        else showConnect("");
    }

    /** The app: the server as a parameter, the refresh token in the fragment
     *  (it goes into no request; the page erases it at once). */
    private void showApp() {
        web.loadUrl(Consts.WEB_ORIGIN + "/" + Consts.APP_PAGE + "?server=" + enc(store.serverOrigin())
            + "#r=" + enc(store.refresh));
        KeepAlive.sync(app, store);
    }

    private void showConnect(String error) {
        int port = store.port > 0 ? store.port : Consts.DEFAULT_PORT;
        web.loadUrl(Consts.WEB_ORIGIN + "/" + Consts.CONNECT_PAGE + "?host=" + enc(store.host)
            + "&user=" + enc(store.user) + "&port=" + port + "&error=" + enc(error));
        KeepAlive.sync(app, store);
    }

    private static String enc(String s) {
        try {
            return URLEncoder.encode(s == null ? "" : s, "UTF-8").replace("+", "%20");
        } catch (Exception e) {
            return "";
        }
    }

    void toPage(JSONObject o) {
        main.post(() -> web.evaluateJavascript(
            "window.__fptgHost&&window.__fptgHost(" + o + ")", null));
    }

    // ------------------------------------------------------------ page messages

    private final class Bridge {
        @JavascriptInterface
        public void post(String json) {
            main.post(() -> {
                // Only our own page speaks to the app (external pages are
                // never loaded in this view, but the check costs nothing).
                String url = web.getUrl();
                if (url == null || !Consts.WEB_HOST.equals(Uri.parse(url).getHost())) return;
                try {
                    onPageMessage(new JSONObject(json));
                } catch (Exception e) {
                    Log.w(TAG, "page message: " + e);
                }
            });
        }
    }

    private void onPageMessage(JSONObject o) {
        switch (o.optString("t")) {
            case "session": {
                // Sign-in succeeded (connect.js): remember it and open the app.
                String before = store.serverOrigin();
                store.host = o.optString("host");
                store.port = o.optInt("port");
                store.user = o.optString("user");
                store.refresh = o.optString("refresh");
                String now = store.serverOrigin();
                // The fingerprint: the one trusted just now; the same server — the
                // previous one; another one without a question (a CA-signed
                // certificate) — none.
                if (now.equals(trustOrigin)) store.fingerprint = trustPrint;
                else if (!now.equals(before)) store.fingerprint = "";
                store.save();
                showApp();
                if (activity instanceof MainActivity) ((MainActivity) activity).afterSignIn();
                break;
            }
            case "signedOut":
                // The session ended: forget the token, keep address and fingerprint.
                store.refresh = "";
                store.save();
                Notices.clearAll(app);
                showConnect(o.optString("error"));
                break;
            case "trustCert":
                // Only the certificate the app itself asked about.
                if (!askedPrint.isEmpty() && askedOrigin.equals(o.optString("origin"))
                        && askedPrint.equals(o.optString("fingerprint"))) {
                    trustOrigin = askedOrigin;
                    trustPrint = askedPrint;
                }
                break;
            case "config": {
                JSONObject n = o.optJSONObject("notify");
                boolean on = n != null && n.optBoolean("enabled");
                if (on != store.notify) {
                    store.notify = on;
                    store.save();
                }
                KeepAlive.sync(app, store);
                if (on && activity instanceof MainActivity) ((MainActivity) activity).askBattery();
                break;
            }
            case "frame":
                frameColor = parseColor(o.optString("caption"), frameColor);
                frameDark = o.optBoolean("dark", true);
                web.setBackgroundColor(frameColor);
                if (activity instanceof MainActivity) ((MainActivity) activity).applyFrame();
                break;
            case "notify":
                Notices.message(app, o.optLong("chatId"), o.optString("title"), o.optString("text"),
                    o.optString("photo"));
                break;
            case "notifySample":
                Notices.message(app, 0, "fptg", "A sample notification.", "");
                break;
            case "callpopup":
                if (o.optBoolean("show")) Notices.call(app);
                else Notices.cancelCall(app);
                break;
            case "miniapp":
                // No mini app window on Android yet: the browser opens it.
                openExternal(o.optString("url"));
                break;
            default:
                break;
        }
    }

    private static int parseColor(String s, int fallback) {
        if (s == null || !s.matches("#[0-9a-fA-F]{6}")) return fallback;
        return 0xFF000000 | Integer.parseInt(s.substring(1), 16);
    }

    void openExternal(String url) {
        if (url == null || url.isEmpty()) return;
        Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        Context c = activity != null ? activity : app;
        if (activity == null) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            c.startActivity(i);
        } catch (ActivityNotFoundException e) {
            Log.w(TAG, "no app for " + url);
        }
    }

    // ------------------------------------------------------------ certificates

    /** https://host:port of a request address, the port always written. */
    static String originOf(String url) {
        try {
            URI u = new URI(url);
            int port = u.getPort() > 0 ? u.getPort() : 443;
            return Store.origin(u.getHost(), port);
        } catch (Exception e) {
            return "";
        }
    }

    static String fingerprintOf(X509Certificate cert) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(cert.getEncoded());
        StringBuilder b = new StringBuilder();
        for (byte x : d) {
            if (b.length() > 0) b.append(':');
            b.append(String.format(Locale.ROOT, "%02X", x));
        }
        return b.toString();
    }

    /** The fingerprint the app trusts for this origin; '' — none pinned. */
    String pinnedFor(String origin) {
        if (origin.equals(store.serverOrigin()) && !store.fingerprint.isEmpty()) return store.fingerprint;
        if (origin.equals(trustOrigin)) return trustPrint;
        return "";
    }

    private final class Client extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
            Uri u = req.getUrl();
            if (!Consts.WEB_HOST.equals(u.getHost())) return null;
            return pageFile(u.getPath());
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
            Uri u = req.getUrl();
            if (Consts.WEB_HOST.equals(u.getHost())) return false;
            // Anything else (t.me, a link in a message) — out to the browser
            // or the app that handles it, never inside the app's view.
            openExternal(u.toString());
            return true;
        }

        @Override
        public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
            // The server's own certificate: a known one goes through; an unknown
            // (or a CHANGED) one is refused and the page asks the person, who
            // compares the fingerprint with the one the server printed.
            String origin = originOf(error.getUrl());
            String print;
            try {
                print = fingerprintOf(error.getCertificate().getX509Certificate());
            } catch (Exception e) {
                handler.cancel();
                return;
            }
            String pinned = pinnedFor(origin);
            if (!pinned.isEmpty() && pinned.equals(print)) {
                handler.proceed();
                return;
            }
            handler.cancel();
            askedOrigin = origin;
            askedPrint = print;
            JSONObject o = new JSONObject();
            try {
                o.put("t", "certificate");
                o.put("origin", origin);
                o.put("fingerprint", print);
                o.put("changed", origin.equals(store.serverOrigin()) && !store.fingerprint.isEmpty());
            } catch (Exception ignored) {
                return;
            }
            toPage(o);
        }
    }

    /** A page file from the APK; HTML gets the host shim at the top. */
    private WebResourceResponse pageFile(String path) {
        if (path == null || path.isEmpty() || path.equals("/")) path = "/" + Consts.APP_PAGE;
        if (path.contains("..")) return notFound();
        String file = Consts.WEB_ASSETS + path;
        String ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        String mime = MIME.get(ext);
        if (mime == null) {
            String guess = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
            mime = guess != null ? guess : "application/octet-stream";
        }
        try {
            InputStream in = assets.open(file);
            if (ext.equals("html")) {
                String html = new String(readAll(in), StandardCharsets.UTF_8);
                int head = html.indexOf("<head>");
                html = head >= 0
                    ? html.substring(0, head + 6) + HOST_SHIM + html.substring(head + 6)
                    : HOST_SHIM + html;
                in = new ByteArrayInputStream(html.getBytes(StandardCharsets.UTF_8));
            }
            WebResourceResponse r = new WebResourceResponse(mime,
                mime.startsWith("text/") || mime.endsWith("json") ? "utf-8" : null, in);
            Map<String, String> h = new HashMap<>();
            h.put("Cache-Control", "no-cache");
            r.setResponseHeaders(h);
            return r;
        } catch (IOException e) {
            return notFound();
        }
    }

    private static WebResourceResponse notFound() {
        WebResourceResponse r = new WebResourceResponse("text/plain", "utf-8",
            new ByteArrayInputStream(new byte[0]));
        r.setStatusCodeAndReasonPhrase(404, "Not Found");
        return r;
    }

    static byte[] readAll(InputStream in) throws IOException {
        try (InputStream s = in) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = s.read(buf)) > 0) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }

    // ------------------------------------------------------------ chrome

    private final class Chrome extends WebChromeClient {
        @Override
        public boolean onCreateWindow(WebView view, boolean dialog, boolean gesture, Message result) {
            // window.open / target=_blank: catch the address in a throw-away
            // view and hand it to the system.
            WebView probe = new WebView(context);
            probe.setWebViewClient(new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                    openExternal(req.getUrl().toString());
                    v.destroy();
                    return true;
                }
            });
            WebView.WebViewTransport transport = (WebView.WebViewTransport) result.obj;
            transport.setWebView(probe);
            result.sendToTarget();
            return true;
        }

        @Override
        public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
            if (activity == null) return false;
            if (pendingFiles != null) pendingFiles.onReceiveValue(null);
            pendingFiles = callback;
            Intent i = params.createIntent();
            i.addCategory(Intent.CATEGORY_OPENABLE);
            if (params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE) {
                i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
            }
            try {
                activity.startActivityForResult(i, Consts.REQ_FILES);
            } catch (ActivityNotFoundException e) {
                pendingFiles = null;
                return false;
            }
            return true;
        }

        @Override
        public void onPermissionRequest(PermissionRequest request) {
            // Microphone and camera for calls and recordings: the page may
            // have them once the app has the system permission.
            main.post(() -> askPermissions(request));
        }

        @Override
        public boolean onConsoleMessage(ConsoleMessage m) {
            if (BuildConfig.DEBUG) Log.d(TAG, "console: " + m.message());
            return true;
        }
    }

    // ------------------------------------------------------------ results from the activity

    void onFiles(int resultCode, Intent data) {
        if (pendingFiles == null) return;
        Uri[] uris = null;
        if (resultCode == Activity.RESULT_OK && data != null) {
            if (data.getClipData() != null) {
                int n = data.getClipData().getItemCount();
                uris = new Uri[n];
                for (int k = 0; k < n; k++) uris[k] = data.getClipData().getItemAt(k).getUri();
            } else if (data.getData() != null) {
                uris = new Uri[] {data.getData()};
            }
        }
        pendingFiles.onReceiveValue(uris);
        pendingFiles = null;
    }

    private static String[] systemPermissions(String[] resources) {
        List<String> out = new ArrayList<>();
        for (String r : resources) {
            if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r)) out.add(Manifest.permission.RECORD_AUDIO);
            else if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r)) out.add(Manifest.permission.CAMERA);
        }
        return out.toArray(new String[0]);
    }

    private void askPermissions(PermissionRequest request) {
        String[] need = systemPermissions(request.getResources());
        if (activity == null) {
            request.deny();
            return;
        }
        List<String> missing = new ArrayList<>();
        for (String p : need) {
            if (activity.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) missing.add(p);
        }
        if (missing.isEmpty()) {
            request.grant(request.getResources());
            return;
        }
        if (pendingPermission != null) pendingPermission.deny();
        pendingPermission = request;
        activity.requestPermissions(missing.toArray(new String[0]), Consts.REQ_PERMISSIONS);
    }

    void onPermissions() {
        PermissionRequest request = pendingPermission;
        pendingPermission = null;
        if (request == null) return;
        List<String> granted = new ArrayList<>();
        for (String r : request.getResources()) {
            String[] p = systemPermissions(new String[] {r});
            if (p.length == 0 || (activity != null
                    && activity.checkSelfPermission(p[0]) == PackageManager.PERMISSION_GRANTED)) {
                granted.add(r);
            }
        }
        if (granted.isEmpty()) request.deny();
        else request.grant(granted.toArray(new String[0]));
    }

    /** A file that did not download: the page says so. */
    void downloadFailed() {
        JSONObject o = new JSONObject();
        try {
            o.put("t", "downloadFailed");
        } catch (Exception ignored) {
            return;
        }
        toPage(o);
    }

    Handler main() {
        return main;
    }
}
