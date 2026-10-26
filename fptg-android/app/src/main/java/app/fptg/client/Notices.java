package app.fptg.client;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.util.Base64;

/**
 * Notifications: new messages (the page's "notify", what desknotify.pas
 * shows as cards on Windows), an incoming call, and the quiet one the
 * background service must show.
 */
final class Notices {
    private Notices() {}

    static void channels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        NotificationChannel messages = new NotificationChannel(Consts.CHANNEL_MESSAGES, "Messages",
            NotificationManager.IMPORTANCE_HIGH);
        messages.setDescription("New messages in chats that are not muted.");
        messages.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
            new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build());
        messages.enableVibration(true);
        // Calls ring with the phone's ringtone, as a call should.
        NotificationChannel calls = new NotificationChannel(Consts.CHANNEL_CALLS, "Calls",
            NotificationManager.IMPORTANCE_HIGH);
        calls.setDescription("Incoming calls, with the phone's ringtone.");
        calls.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
            new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build());
        calls.enableVibration(true);
        calls.setVibrationPattern(new long[] {0, 1000, 1000});
        nm.deleteNotificationChannel(Consts.CHANNEL_CALLS_OLD);
        NotificationChannel service = new NotificationChannel(Consts.CHANNEL_SERVICE, "Connection",
            NotificationManager.IMPORTANCE_MIN);
        service.setDescription("Shown while fptg stays connected to the server in the background.");
        service.setShowBadge(false);
        nm.createNotificationChannel(messages);
        nm.createNotificationChannel(calls);
        nm.createNotificationChannel(service);
    }

    /** Opens the app, and with a chat — that chat. */
    static PendingIntent open(Context c, long chatId) {
        Intent i = new Intent(c, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (chatId != 0) i.putExtra(Consts.EXTRA_CHAT, chatId);
        return PendingIntent.getActivity(c, Long.hashCode(chatId), i,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** One notification per chat: a newer message replaces the older one. */
    static void message(Context c, long chatId, String title, String text, String photo) {
        Notification.Builder b = new Notification.Builder(c, Consts.CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(new Notification.BigTextStyle().bigText(text))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(open(c, chatId));
        Bitmap face = round(decodeDataUrl(photo));
        if (face != null) b.setLargeIcon(Icon.createWithBitmap(face));
        c.getSystemService(NotificationManager.class).notify(noteId(chatId), b.build());
    }

    /** The chat is read: its notification goes (the page's notifyClear). */
    static void cancel(Context c, long chatId) {
        if (chatId != 0) c.getSystemService(NotificationManager.class).cancel(noteId(chatId));
    }

    /** The page asks for it while a call rings and the app is out of sight
     *  (ui/call.js, callpopup); it rings until the call is answered, declined
     *  or the app comes to the front (insistent: the sound repeats). */
    static void call(Context c) {
        Notification n = new Notification.Builder(c, Consts.CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Incoming call")
            .setContentText("Tap to answer in fptg.")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open(c, 0))
            .build();
        n.flags |= Notification.FLAG_INSISTENT;
        c.getSystemService(NotificationManager.class).notify(Consts.NOTE_CALL, n);
    }

    static void cancelCall(Context c) {
        c.getSystemService(NotificationManager.class).cancel(Consts.NOTE_CALL);
    }

    /** Signed out: what was shown belongs to the old session. */
    static void clearAll(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        for (android.service.notification.StatusBarNotification s : nm.getActiveNotifications()) {
            if (s.getId() != Consts.NOTE_SERVICE) nm.cancel(s.getId());
        }
    }

    static Notification service(Context c, String server) {
        return new Notification.Builder(c, Consts.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("fptg is connected")
            .setContentText(server)
            .setOngoing(true)
            .setContentIntent(open(c, 0))
            .build();
    }

    private static int noteId(long chatId) {
        // Clear of the fixed ids (service, call).
        int id = Long.hashCode(chatId);
        return (id == Consts.NOTE_SERVICE || id == Consts.NOTE_CALL) ? id + 1000 : id;
    }

    static Bitmap decodeDataUrl(String url) {
        if (url == null || !url.startsWith("data:")) return null;
        int comma = url.indexOf(',');
        if (comma < 0 || !url.substring(0, comma).endsWith(";base64")) return null;
        try {
            byte[] bytes = Base64.decode(url.substring(comma + 1), Base64.DEFAULT);
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /** The avatar as a circle, as everywhere else in the app. */
    private static Bitmap round(Bitmap src) {
        if (src == null) return null;
        int size = Math.min(src.getWidth(), src.getHeight());
        Bitmap out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(out);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, p);
        p.setXfermode(new android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN));
        canvas.drawBitmap(src, (size - src.getWidth()) / 2f, (size - src.getHeight()) / 2f, p);
        return out;
    }
}
