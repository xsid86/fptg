package app.fptg.client;

import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.MediaStore;
import android.webkit.MimeTypeMap;
import android.webkit.URLUtil;
import android.widget.Toast;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.SecureRandom;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.Locale;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Files from messages: /media/…?save=name[&open=1] (util/download.js).
 *
 * The system download manager cannot be used: it would refuse the server's
 * own certificate. The app downloads itself, trusting exactly the
 * fingerprint the person trusted (Shell.pinnedFor), saves into Downloads and,
 * with open=1, opens the file with an app that can show it — as the
 * Windows window does (webui.ViewDownloadDone).
 */
final class Downloads {
    private Downloads() {}

    static void start(Shell shell, String url, String disposition, String mime) {
        Uri u = Uri.parse(url);
        String name = u.getQueryParameter("save");
        if (name == null || name.isEmpty() || name.equals("*")) {
            name = URLUtil.guessFileName(url, disposition, mime);
        }
        final String fileName = name.replaceAll("[\\\\/:*?\"<>|]", "_");
        final boolean open = "1".equals(u.getQueryParameter("open"));
        final String type = typeOf(fileName, mime);
        final String pinned = shell.pinnedFor(Shell.originOf(url));
        Context app = shell.app;
        Toast.makeText(app, "Downloading " + fileName, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            Uri saved = null;
            try {
                saved = fetch(app, url, pinned, fileName, type);
            } catch (Exception e) {
                saved = null;
            }
            final Uri result = saved;
            shell.main().post(() -> done(shell, result, fileName, type, open));
        }, "fptg-download").start();
    }

    private static String typeOf(String name, String mime) {
        if (mime != null && !mime.isEmpty() && !mime.equals("application/octet-stream")) return mime;
        String ext = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        String guess = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
        return guess != null ? guess : "application/octet-stream";
    }

    private static Uri fetch(Context app, String url, String pinned, String name, String type) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        conn.setConnectTimeout(Consts.DOWNLOAD_TIMEOUT_MS);
        conn.setReadTimeout(Consts.DOWNLOAD_TIMEOUT_MS);
        if (conn instanceof HttpsURLConnection && !pinned.isEmpty()) {
            HttpsURLConnection https = (HttpsURLConnection) conn;
            SSLContext ssl = SSLContext.getInstance("TLS");
            ssl.init(null, new TrustManager[] {new Pinned(pinned)}, new SecureRandom());
            https.setSSLSocketFactory(ssl.getSocketFactory());
            // The name in a self-signed certificate means nothing; the
            // fingerprint above is what identifies the server.
            https.setHostnameVerifier((host, session) -> true);
        }
        if (conn.getResponseCode() != HttpURLConnection.HTTP_OK) {
            conn.disconnect();
            return null;
        }
        ContentResolver cr = app.getContentResolver();
        ContentValues v = new ContentValues();
        v.put(MediaStore.Downloads.DISPLAY_NAME, name);
        v.put(MediaStore.Downloads.MIME_TYPE, type);
        v.put(MediaStore.Downloads.IS_PENDING, 1);
        Uri item = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
        if (item == null) {
            conn.disconnect();
            return null;
        }
        try (InputStream in = conn.getInputStream(); OutputStream out = cr.openOutputStream(item)) {
            byte[] buf = new byte[Consts.DOWNLOAD_BUFFER];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } catch (Exception e) {
            cr.delete(item, null, null);
            throw e;
        } finally {
            conn.disconnect();
        }
        v.clear();
        v.put(MediaStore.Downloads.IS_PENDING, 0);
        cr.update(item, v, null, null);
        return item;
    }

    private static void done(Shell shell, Uri file, String name, String type, boolean open) {
        Context app = shell.app;
        if (file == null) {
            shell.downloadFailed();
            return;
        }
        if (!open) {
            Toast.makeText(app, "Saved to Downloads: " + name, Toast.LENGTH_SHORT).show();
            return;
        }
        Intent i = new Intent(Intent.ACTION_VIEW).setDataAndType(file, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Context c = shell.activity() != null ? shell.activity() : app;
        if (shell.activity() == null) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            c.startActivity(Intent.createChooser(i, name)
                .addFlags(shell.activity() == null ? Intent.FLAG_ACTIVITY_NEW_TASK : 0));
        } catch (ActivityNotFoundException e) {
            Toast.makeText(app, "Saved to Downloads: " + name, Toast.LENGTH_SHORT).show();
        }
    }

    /** Trusts one certificate: the one with the pinned SHA-256 fingerprint. */
    private static final class Pinned implements X509TrustManager {
        private final String print;

        Pinned(String print) {
            this.print = print;
        }

        @Override
        public void checkServerTrusted(X509Certificate[] chain, String authType) throws CertificateException {
            try {
                if (chain.length > 0 && print.equals(Shell.fingerprintOf(chain[0]))) return;
            } catch (Exception e) {
                throw new CertificateException(e);
            }
            throw new CertificateException("not the trusted certificate");
        }

        @Override
        public void checkClientTrusted(X509Certificate[] chain, String authType) throws CertificateException {
            throw new CertificateException("no client certificates");
        }

        @Override
        public X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
        }
    }
}
