package vn.tinjs.vibecode.remote;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

import org.json.JSONObject;

/**
 * The whole app: one WebView. It starts on assets/start.html (find the computer), then shows the
 * page the computer serves at http://<ip>:47717/ — so the remote always matches the desktop
 * version and this APK never needs updating for UI changes.
 *
 * Away from the Wi-Fi: the computer's page tells the app its Internet address (a Cloudflare
 * tunnel, with this phone's token in the link); the app opens that from then on, and goes back to
 * finding the computer on the Wi-Fi when it stops working (the address changes when the PC restarts).
 * The start screen can also scan the QR code the computer shows (the camera, for that page only).
 */
public class Main extends Activity {
    /** src-zig/src/remote.zig: TCP for the page, UDP for "VIBECODE?" */
    static final int PORT = 47717;
    static final String START = "file:///android_asset/start.html";

    WebView web;
    SharedPreferences prefs;
    /** the page shown, for the bridge (which runs on another thread) */
    volatile String page = "";
    /** the start screen asked for the camera while Android asks the user */
    PermissionRequest pendingCamera;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("remote", MODE_PRIVATE);
        getWindow().setStatusBarColor(0xff232325);
        getWindow().setNavigationBarColor(0xff1c1c1e);
        web = new WebView(this);
        web.setBackgroundColor(0xff1c1c1e);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.addJavascriptInterface(new Bridge(), "VibeAndroid");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if ("file".equals(u.getScheme()) || u.getPort() == PORT || isTunnel(u)) return false;
                // links in Claude's answers open in the browser
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, u));
                } catch (Exception ignored) {
                }
                return true;
            }

            @Override
            public void onPageStarted(WebView v, String url, android.graphics.Bitmap icon) {
                page = url;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                // the start screen is the bottom of the stack: Back there leaves the app
                if (url.startsWith(START)) v.clearHistory();
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (!r.isForMainFrame() || "file".equals(r.getUrl().getScheme())) return;
                // the Internet address is gone (or out of reach): the computer on this Wi-Fi then
                if (isTunnel(r.getUrl())) v.loadUrl(START + "#auto");
                else v.loadUrl(START + "#error=" + Uri.encode(r.getUrl().getHost()));
            }

            @Override
            public void onReceivedHttpError(WebView v, WebResourceRequest r, WebResourceResponse res) {
                // Cloudflare's own error page: no tunnel at that address any more, or the app is closed
                if (r.isForMainFrame() && isTunnel(r.getUrl()) && res.getStatusCode() >= 500) v.loadUrl(START + "#auto");
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(PermissionRequest r) {
                // the camera, for the start screen's QR scanner: never for the pages computers serve
                boolean camera = false;
                for (String res : r.getResources()) if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res)) camera = true;
                if (!camera || !"file".equals(r.getOrigin().getScheme())) {
                    r.deny();
                    return;
                }
                String[] only = {PermissionRequest.RESOURCE_VIDEO_CAPTURE};
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) r.grant(only);
                else {
                    pendingCamera = r;
                    requestPermissions(new String[]{Manifest.permission.CAMERA}, 1);
                }
            }
        });
        setContentView(web);
        if (state != null) web.restoreState(state);
        else web.loadUrl(prefs.getString("tunnel", START + "#auto"));
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (pendingCamera == null) return;
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) pendingCamera.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
        else pendingCamera.deny();
        pendingCamera = null;
    }

    static boolean isTunnelLink(Uri u) {
        return "https".equals(u.getScheme()) && u.getHost() != null && u.getHost().endsWith(".trycloudflare.com");
    }

    /** the Internet address the computer gave */
    boolean isTunnel(Uri u) {
        String saved = prefs.getString("tunnel", null);
        return saved != null && "https".equals(u.getScheme()) && u.getHost() != null && u.getHost().equals(Uri.parse(saved).getHost());
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    /** window.VibeAndroid in the pages */
    class Bridge {
        @JavascriptInterface
        public String deviceName() {
            return Build.MANUFACTURER + " " + Build.MODEL;
        }

        /** The computer's page on the Wi-Fi gives its Internet address: https://….trycloudflare.com/#token=… */
        @JavascriptInterface
        public void saveTunnel(String link) {
            Uri u = Uri.parse(link);
            if (Uri.parse(page).getPort() != PORT || !isTunnelLink(u)) return;
            prefs.edit().putString("tunnel", link).apply();
        }

        /** The start screen: a link typed in or scanned (https://….trycloudflare.com/, maybe #pair=PIN). Kept and opened. */
        @JavascriptInterface
        public void openTunnel(String link) {
            Uri u = Uri.parse(link);
            if (!page.startsWith(START) || !isTunnelLink(u)) return;
            // the PIN is for once: the page keeps its token itself
            prefs.edit().putString("tunnel", "https://" + u.getHost() + "/").apply();
            web.post(() -> web.loadUrl(link));
        }

        /** Asks the network for VIBE CODE computers; each answer calls window.onFound({ip,name,port}), then onSearchDone(). */
        @JavascriptInterface
        public void discover() {
            new Thread(Main.this::search).start();
        }
    }

    void search() {
        Set<String> seen = new HashSet<>();
        try (DatagramSocket sock = new DatagramSocket()) {
            sock.setBroadcast(true);
            sock.setSoTimeout(400);
            byte[] ask = "VIBECODE?".getBytes(StandardCharsets.US_ASCII);
            Set<InetAddress> targets = new HashSet<>();
            targets.add(InetAddress.getByName("255.255.255.255"));
            // the subnet's own broadcast address too: some routers drop 255.255.255.255
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InterfaceAddress ia : ni.getInterfaceAddresses())
                    if (ia.getBroadcast() != null) targets.add(ia.getBroadcast());
            }
            byte[] buf = new byte[512];
            // a few rounds: a broadcast can get lost on Wi-Fi
            for (int round = 0; round < 4; round++) {
                for (InetAddress t : targets) {
                    try {
                        sock.send(new DatagramPacket(ask, ask.length, t, PORT));
                    } catch (Exception ignored) {
                    }
                }
                long until = System.currentTimeMillis() + 500;
                while (System.currentTimeMillis() < until) {
                    DatagramPacket p = new DatagramPacket(buf, buf.length);
                    try {
                        sock.receive(p);
                    } catch (SocketTimeoutException e) {
                        break;
                    }
                    String ip = p.getAddress().getHostAddress();
                    if (!seen.add(ip)) continue;
                    try {
                        JSONObject o = new JSONObject(new String(p.getData(), 0, p.getLength(), StandardCharsets.UTF_8));
                        if (!"vibecode".equals(o.optString("app"))) continue;
                        o.put("ip", ip);
                        js("window.onFound && window.onFound(" + o + ")");
                    } catch (Exception ignored) {
                    }
                }
            }
        } catch (Exception ignored) {
        }
        js("window.onSearchDone && window.onSearchDone()");
    }

    void js(String code) {
        web.post(() -> web.evaluateJavascript(code, null));
    }
}
