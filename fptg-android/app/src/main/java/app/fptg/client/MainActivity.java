package app.fptg.client;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.webkit.WebView;
import android.widget.FrameLayout;

/**
 * The screen: shows the page Shell keeps for the whole process. It only
 * borrows the WebView — closing the screen leaves the page and its
 * connection running (see Shell).
 */
public final class MainActivity extends Activity {
    private Shell shell;
    private FrameLayout root;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        shell = Shell.get(this);
        root = new FrameLayout(this);
        setContentView(root);
        Window w = getWindow();
        // Edge to edge (the rule on Android 15, the same on older ones): the
        // page gets the space between the system bars and above the keyboard,
        // the bars show the page's own colour (applyFrame).
        w.setDecorFitsSystemWindows(false);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            Insets i = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
            v.setPadding(i.left, i.top, i.right, i.bottom);
            return WindowInsets.CONSUMED;
        });
        shell.attach(this);
        WebView web = shell.web;
        if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
        root.addView(web, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        applyFrame();
        askNotifications();
        handle(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handle(intent);
    }

    private void handle(Intent intent) {
        if (intent == null) return;
        long chat = intent.getLongExtra(Consts.EXTRA_CHAT, 0);
        if (chat != 0) {
            intent.removeExtra(Consts.EXTRA_CHAT);
            shell.openChat(chat);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // A call notification is pointless once the app is in front.
        Notices.cancelCall(this);
    }

    @Override
    protected void onDestroy() {
        root.removeView(shell.web);
        shell.detach(this);
        super.onDestroy();
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        shell.back(this);
    }

    /** The status and navigation bars in the page's colour (its theme). */
    void applyFrame() {
        root.setBackgroundColor(shell.frameColor);
        WindowInsetsController c = getWindow().getInsetsController();
        if (c != null) {
            int light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            c.setSystemBarsAppearance(shell.frameDark ? 0 : light, light);
        }
    }

    // ------------------------------------------------------------ permissions

    private void askNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, Consts.REQ_NOTIFICATIONS);
        }
    }

    /** Right after signing in: the notifications question if not asked yet. */
    void afterSignIn() {
        askNotifications();
    }

    /**
     * Once: messages in the background need the app exempt from battery
     * optimization — otherwise the system cuts the connection while the
     * phone sleeps (Doze), and notifications come only when it wakes.
     */
    void askBattery() {
        Store store = shell.store;
        if (store.batteryAsked) return;
        PowerManager pm = getSystemService(PowerManager.class);
        if (pm.isIgnoringBatteryOptimizations(getPackageName())) return;
        store.batteryAsked = true;
        store.save();
        new AlertDialog.Builder(this)
            .setTitle("Messages in the background")
            .setMessage("fptg talks to your own server, without a push service. To get new messages "
                + "while the phone sleeps, let it run without battery optimization.")
            .setPositiveButton("Allow", (d, k) -> {
                Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + getPackageName()));
                try {
                    startActivity(i);
                } catch (Exception ignored) {
                    // Some systems have no such screen; nothing else to do.
                }
            })
            .setNegativeButton("Not now", null)
            .show();
    }

    @Override
    @SuppressWarnings("deprecation")
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == Consts.REQ_FILES) shell.onFiles(result, data);
    }

    @Override
    public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == Consts.REQ_PERMISSIONS) shell.onPermissions();
        else if (request == Consts.REQ_NOTIFICATIONS) KeepAlive.sync(this, shell.store);
    }
}
