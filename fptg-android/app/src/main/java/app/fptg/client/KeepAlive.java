package app.fptg.client;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

/**
 * Keeps the process — and with it the page and its WebSocket — alive in
 * the background, so new messages arrive as notifications. A self-hosted
 * server has no push service (FCM), so this is the only way, as in Signal
 * without Google services: a foreground service with a quiet notification.
 *
 * Runs while there is a session and the page's notifications are on
 * (Settings → Notifications). Restarted by the system after the process
 * was killed, it brings the page back (Shell.get loads it).
 */
public final class KeepAlive extends Service {

    /** Starts or stops the service to match the session and the setting. */
    static void sync(Context c, Store store) {
        Intent i = new Intent(c, KeepAlive.class);
        if (store.hasSession() && store.notify) {
            try {
                c.startForegroundService(i);
            } catch (IllegalStateException e) {
                // Not allowed from the background (Android 12+): it starts the
                // next time the app is in front.
            }
        } else {
            c.stopService(i);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Shell shell = Shell.get(this);
        if (!shell.store.hasSession() || !shell.store.notify) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(Consts.NOTE_SERVICE, Notices.service(this, shell.store.serverOrigin()),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(Consts.NOTE_SERVICE, Notices.service(this, shell.store.serverOrigin()));
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
