package app.fptg.client;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Locale;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Where the app keeps the server: address, port, user, the trusted
 * certificate fingerprint and the session's refresh token — what conf.dat
 * holds for the Windows window (guiconn.pas). The refresh token opens the
 * account, so it is stored encrypted with a key from the Android Keystore
 * (never leaves the device), as conf.dat is with DPAPI.
 */
final class Store {
    private static final String FILE = "fptg";
    private static final String TRANSFORM = "AES/GCM/NoPadding";
    private static final int GCM_TAG_BITS = 128;

    private final SharedPreferences prefs;

    String host;
    int port;
    String user;
    /** SHA-256 of the server certificate, "AB:CD:…" — '' when none is pinned. */
    String fingerprint;
    String refresh;
    /** The page's desktop-notification setting (Settings → Notifications). */
    boolean notify;
    /** The battery-optimization question was asked once already. */
    boolean batteryAsked;

    Store(Context context) {
        prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
        host = prefs.getString("host", "");
        port = prefs.getInt("port", 0);
        user = prefs.getString("user", "");
        fingerprint = prefs.getString("fingerprint", "");
        refresh = decrypt(prefs.getString("refresh", ""));
        notify = prefs.getBoolean("notify", false);
        batteryAsked = prefs.getBoolean("batteryAsked", false);
    }

    void save() {
        prefs.edit()
            .putString("host", host)
            .putInt("port", port)
            .putString("user", user)
            .putString("fingerprint", fingerprint)
            .putString("refresh", encrypt(refresh))
            .putBoolean("notify", notify)
            .putBoolean("batteryAsked", batteryAsked)
            .apply();
    }

    boolean hasSession() {
        return !refresh.isEmpty() && !host.isEmpty() && port > 0;
    }

    /** https://host:port, lower case, an IPv6 host in brackets — as ServerOrigin. */
    String serverOrigin() {
        return origin(host, port);
    }

    static String origin(String host, int port) {
        String h = host.trim();
        if (h.indexOf(':') >= 0 && !h.startsWith("[")) {
            h = "[" + h + "]";
        }
        return ("https://" + h + ":" + port).toLowerCase(Locale.ROOT);
    }

    // ------------------------------------------------------------ crypto

    private static SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (ks.containsAlias(Consts.KEY_ALIAS)) {
            return (SecretKey) ks.getKey(Consts.KEY_ALIAS, null);
        }
        KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(Consts.KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build());
        return gen.generateKey();
    }

    /** "iv.ciphertext" in base64; '' for ''. A failure stores nothing: signing
     *  in again is better than a token lying in the clear. */
    private static String encrypt(String plain) {
        if (plain == null || plain.isEmpty()) return "";
        try {
            Cipher c = Cipher.getInstance(TRANSFORM);
            c.init(Cipher.ENCRYPT_MODE, key());
            byte[] data = c.doFinal(plain.getBytes(StandardCharsets.UTF_8));
            return Base64.encodeToString(c.getIV(), Base64.NO_WRAP) + "."
                + Base64.encodeToString(data, Base64.NO_WRAP);
        } catch (Exception e) {
            return "";
        }
    }

    private static String decrypt(String stored) {
        if (stored == null || stored.isEmpty()) return "";
        try {
            int dot = stored.indexOf('.');
            byte[] iv = Base64.decode(stored.substring(0, dot), Base64.NO_WRAP);
            byte[] data = Base64.decode(stored.substring(dot + 1), Base64.NO_WRAP);
            Cipher c = Cipher.getInstance(TRANSFORM);
            c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(GCM_TAG_BITS, iv));
            return new String(c.doFinal(data), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }
}
