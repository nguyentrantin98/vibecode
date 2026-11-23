package vn.tinjs.vibecode.remote;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
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
 */
public class Main extends Activity {
    /** src-zig/src/remote.zig: TCP for the page, UDP for "VIBECODE?" */
    static final int PORT = 47717;
    static final String START = "file:///android_asset/start.html";

    WebView web;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(0xff232325);
        getWindow().setNavigationBarColor(0xff1c1c1e);
        web = new WebView(this);
        web.setBackgroundColor(0xff1c1c1e);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.addJavascriptInterface(new Bridge(), "VibeAndroid");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if ("file".equals(u.getScheme()) || u.getPort() == PORT) return false;
                // links in Claude's answers open in the browser
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, u));
                } catch (Exception ignored) {
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                // the start screen is the bottom of the stack: Back there leaves the app
                if (url.startsWith(START)) v.clearHistory();
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame() && !"file".equals(r.getUrl().getScheme()))
                    v.loadUrl(START + "#error=" + Uri.encode(r.getUrl().getHost()));
            }
        });
        setContentView(web);
        if (state != null) web.restoreState(state);
        else web.loadUrl(START + "#auto");
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
