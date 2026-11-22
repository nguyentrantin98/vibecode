//! The Windows host: Win32 windows, one shared WebView2 environment, the app's pages served from
//! memory at http://tauri.localhost (the origin the Tauri build used, so the pages' localStorage
//! and the WebView2 profile carry over), page → native calls and native → page messages.
//!
//! Everything here runs on the UI thread unless it says otherwise; other threads get there with
//! `onUi` / `onUiSync`.

const std = @import("std");
const core = @import("../../core.zig");
const ipc = @import("../../ipc.zig");
const shared = @import("../../host.zig");
const assets = @import("assets");
pub const com = @import("com.zig");
pub const c = com.c;

const Allocator = std.mem.Allocator;
const gpa = &core.gpa;

pub const Rect = shared.Rect;
pub const origin = "http://tauri.localhost";
pub const identifier = "vn.tinjs.vibecode";

const WM_RUN = c.WM_APP + 1;
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("VibeCodeWindow");
const msg_class_name = std.unicode.utf8ToUtf16LeStringLiteral("VibeCodeMessages");

// resource ids (MAKEINTRESOURCE) are odd "pointers": declared here taking an integer
extern "user32" fn LoadIconW(c.HINSTANCE, usize) callconv(.winapi) c.HICON;
extern "user32" fn LoadCursorW(c.HINSTANCE, usize) callconv(.winapi) c.HCURSOR;
// so are the special window handles (HWND_TOPMOST, HWND_BROADCAST…)
extern "user32" fn SetWindowPos(c.HWND, isize, c_int, c_int, c_int, c_int, c.UINT) callconv(.winapi) c.BOOL;
pub extern "user32" fn PostMessageW(usize, c.UINT, c.WPARAM, c.LPARAM) callconv(.winapi) c.BOOL;

var ui_thread: u32 = 0;
var msg_hwnd: c.HWND = null;
var hinstance: c.HINSTANCE = null;

// ---------------- start-up / run loop ----------------

pub fn init() !void {
    ui_thread = c.GetCurrentThreadId();
    _ = c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // OLE (not just COM): drag & drop needs it
    _ = c.OleInitialize(null);
    hinstance = c.GetModuleHandleW(null);

    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.lpszClassName = class_name;
    wc.hCursor = LoadCursorW(null, 32512); // IDC_ARROW
    wc.hIcon = LoadIconW(hinstance, 1); // app.rc
    wc.hIconSm = wc.hIcon;
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClass;

    var mc = std.mem.zeroes(c.WNDCLASSEXW);
    mc.cbSize = @sizeOf(c.WNDCLASSEXW);
    mc.lpfnWndProc = msgProc;
    mc.hInstance = hinstance;
    mc.lpszClassName = msg_class_name;
    if (c.RegisterClassExW(&mc) == 0) return error.RegisterClass;
    // a top-level (not message-only) hidden window, so it also gets broadcasts like
    // WM_SETTINGCHANGE / TaskbarCreated that hooks may want
    msg_hwnd = c.CreateWindowExW(0, msg_class_name, msg_class_name, 0, 0, 0, 0, 0, null, null, hinstance, null);
    if (msg_hwnd == null) return error.CreateWindow;

    try startEnvironment();
}

/// The hidden window that receives `onUi` work, hotkeys (`RegisterHotKey(messageWindow(), …)`)
/// and anything a hook wants to catch.
pub fn messageWindow() c.HWND {
    return msg_hwnd;
}

pub fn run() void {
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

/// Ends the run loop (from any thread).
pub fn quit() void {
    onUi(struct {
        fn f() void {
            c.PostQuitMessage(0);
        }
    }.f, .{});
}

pub fn isUiThread() bool {
    return c.GetCurrentThreadId() == ui_thread;
}

// ---------------- running on the UI thread ----------------

const Task = struct {
    run: *const fn (*Task) void,
};

/// Runs `f(args…)` on the UI thread, later (from any thread; returns at once).
pub fn onUi(comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) void {
    const Args = @TypeOf(args);
    const C = struct {
        task: Task,
        a: Args,
        fn run(t: *Task) void {
            const self: *@This() = @fieldParentPtr("task", t);
            const a = self.a;
            core.gpa.destroy(self);
            _ = @call(.auto, f, a);
        }
    };
    const cl = core.gpa.create(C) catch return;
    cl.* = .{ .task = .{ .run = C.run }, .a = args };
    if (c.PostMessageW(msg_hwnd, WM_RUN, 0, @bitCast(@intFromPtr(&cl.task))) == 0) core.gpa.destroy(cl);
}

/// Runs `f(args…)` on the UI thread and waits for its result (from any thread).
pub fn onUiSync(comptime f: anytype, args: std.meta.ArgsTuple(@TypeOf(f))) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    if (isUiThread()) return @call(.auto, f, args);
    const Args = @TypeOf(args);
    const C = struct {
        task: Task,
        a: Args,
        r: R = undefined,
        done: std.Io.Event = .unset,
        fn run(t: *Task) void {
            const self: *@This() = @fieldParentPtr("task", t);
            self.r = @call(.auto, f, self.a);
            self.done.set(core.io);
        }
    };
    var cl: C = .{ .task = .{ .run = C.run }, .a = args };
    _ = c.SendNotifyMessageW(msg_hwnd, WM_RUN, 0, @bitCast(@intFromPtr(&cl.task)));
    cl.done.waitUncancelable(core.io);
    return cl.r;
}

/// Called for every message of the app's windows (and the hidden message window) before the
/// host looks at it; return a value to answer the message yourself.
pub const Hook = *const fn (hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) ?c.LRESULT;
var hooks: [16]Hook = undefined;
var hook_count: usize = 0;

pub fn addHook(h: Hook) void {
    hooks[hook_count] = h;
    hook_count += 1;
}

fn runHooks(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) ?c.LRESULT {
    for (hooks[0..hook_count]) |h| if (h(hwnd, msg, wp, lp)) |r| return r;
    return null;
}

fn msgProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.c) c.LRESULT {
    if (msg == WM_RUN) {
        const t: *Task = @ptrFromInt(@as(usize, @bitCast(lp)));
        t.run(t);
        return 0;
    }
    if (runHooks(hwnd, msg, wp, lp)) |r| return r;
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------------- windows ----------------

pub const WindowEvent = enum {
    /// return true from the listener to keep the window open
    close_requested,
    resized,
    moved,
    focused,
    blurred,
    destroyed,
};

pub const Window = struct {
    label: []const u8,
    hwnd: c.HWND,
    /// the page that fills the window, if any
    webview: ?*Webview = null,
    decorations: bool,
    shadow: bool,
    min_w: i32,
    min_h: i32,
    listener: ?*const fn (*Window, WindowEvent) bool = null,

    pub fn dpi(w: *const Window) f64 {
        return @as(f64, @floatFromInt(c.GetDpiForWindow(w.hwnd))) / 96.0;
    }
    pub fn show(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_SHOW);
    }
    pub fn showInactive(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_SHOWNOACTIVATE);
    }
    pub fn hide(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_HIDE);
    }
    pub fn focus(w: *Window) void {
        // Windows only lets the foreground app steal focus; the Alt tap is the usual unlock
        if (c.GetForegroundWindow() != w.hwnd) {
            c.keybd_event(c.VK_MENU, 0, 0, 0);
            c.keybd_event(c.VK_MENU, 0, c.KEYEVENTF_KEYUP, 0);
        }
        _ = c.SetForegroundWindow(w.hwnd);
        _ = c.SetFocus(w.hwnd);
    }
    pub fn minimize(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_MINIMIZE);
    }
    pub fn maximize(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_MAXIMIZE);
    }
    pub fn restore(w: *Window) void {
        _ = c.ShowWindow(w.hwnd, c.SW_RESTORE);
    }
    pub fn isVisible(w: *const Window) bool {
        return c.IsWindowVisible(w.hwnd) != 0;
    }
    pub fn isMinimized(w: *const Window) bool {
        return c.IsIconic(w.hwnd) != 0;
    }
    pub fn isMaximized(w: *const Window) bool {
        return c.IsZoomed(w.hwnd) != 0;
    }
    pub fn isFocused(w: *const Window) bool {
        return c.GetForegroundWindow() == w.hwnd;
    }
    /// outer bounds, physical pixels
    pub fn bounds(w: *const Window) Rect {
        var r: c.RECT = undefined;
        _ = c.GetWindowRect(w.hwnd, &r);
        return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
    }
    pub fn setBounds(w: *Window, r: Rect) void {
        _ = c.SetWindowPos(w.hwnd, null, r.x, r.y, r.w, r.h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    pub fn setPosition(w: *Window, x: i32, y: i32) void {
        _ = c.SetWindowPos(w.hwnd, null, x, y, 0, 0, c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOSIZE);
    }
    /// client area size, physical pixels
    pub fn clientSize(w: *const Window) struct { w: i32, h: i32 } {
        var r: c.RECT = undefined;
        _ = c.GetClientRect(w.hwnd, &r);
        return .{ .w = r.right - r.left, .h = r.bottom - r.top };
    }
    pub fn setAlwaysOnTop(w: *Window, on: bool) void {
        // HWND_TOPMOST (-1) / HWND_NOTOPMOST (-2)
        _ = SetWindowPos(w.hwnd, if (on) -1 else -2, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
    pub fn setSkipTaskbar(w: *Window, on: bool) void {
        setTaskbarVisible(w.hwnd, !on);
    }
    /// minimize / maximize boxes (and so Win+arrow snapping)
    pub fn setMinMaxBoxes(w: *Window, minimizable: bool, maximizable: bool) void {
        var style = c.GetWindowLongPtrW(w.hwnd, c.GWL_STYLE);
        style = if (minimizable) style | c.WS_MINIMIZEBOX else style & ~@as(isize, c.WS_MINIMIZEBOX);
        style = if (maximizable) style | c.WS_MAXIMIZEBOX else style & ~@as(isize, c.WS_MAXIMIZEBOX);
        _ = c.SetWindowLongPtrW(w.hwnd, c.GWL_STYLE, style);
    }
    pub fn setTitle(w: *Window, title: []const u8) void {
        const t = core.wide(core.gpa, title) catch return;
        defer core.gpa.free(t);
        _ = c.SetWindowTextW(w.hwnd, t);
    }
    /// asks to close: the listener may keep it open
    pub fn close(w: *Window) void {
        _ = c.PostMessageW(w.hwnd, c.WM_CLOSE, 0, 0);
    }
    /// closes for good, without asking the listener
    pub fn destroy(w: *Window) void {
        _ = c.DestroyWindow(w.hwnd);
    }
    /// starts moving the window with the mouse (call while the button is down)
    pub fn startDrag(w: *Window) void {
        _ = c.ReleaseCapture();
        _ = c.SendMessageW(w.hwnd, c.WM_NCLBUTTONDOWN, c.HTCAPTION, 0);
    }
    /// starts resizing from an edge: "n" "s" "e" "w" "ne" "nw" "se" "sw"
    pub fn startResize(w: *Window, dir: []const u8) void {
        const ht: c.WPARAM = if (std.mem.eql(u8, dir, "n")) c.HTTOP else if (std.mem.eql(u8, dir, "s")) c.HTBOTTOM else if (std.mem.eql(u8, dir, "e")) c.HTRIGHT else if (std.mem.eql(u8, dir, "w")) c.HTLEFT else if (std.mem.eql(u8, dir, "ne")) c.HTTOPRIGHT else if (std.mem.eql(u8, dir, "nw")) c.HTTOPLEFT else if (std.mem.eql(u8, dir, "se")) c.HTBOTTOMRIGHT else if (std.mem.eql(u8, dir, "sw")) c.HTBOTTOMLEFT else return;
        _ = c.ReleaseCapture();
        _ = c.SendMessageW(w.hwnd, c.WM_NCLBUTTONDOWN, ht, 0);
    }
};

var windows: std.ArrayList(*Window) = .empty;

pub fn findWindow(label: []const u8) ?*Window {
    for (windows.items) |w| if (std.mem.eql(u8, w.label, label)) return w;
    return null;
}

pub fn windowFromHwnd(hwnd: c.HWND) ?*Window {
    for (windows.items) |w| if (w.hwnd == hwnd) return w;
    return null;
}

pub const WindowOptions = struct {
    label: []const u8,
    title: []const u8 = "VIBE CODE",
    /// logical pixels (scaled by the DPI of the screen it opens on)
    width: f64 = 800,
    height: f64 = 600,
    min_width: f64 = 0,
    min_height: f64 = 0,
    /// physical position; null = centred on the primary screen's work area
    x: ?i32 = null,
    y: ?i32 = null,
    visible: bool = true,
    decorations: bool = true,
    /// drop shadow (and rounded corners on Windows 11) for an undecorated window
    shadow: bool = true,
    resizable: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
    skip_taskbar: bool = false,
    /// a tool window: no taskbar button, no Alt+Tab, never takes focus when shown
    popup: bool = false,
    /// window colour before the page paints, 0xRRGGBBAA
    background: u32 = 0x000000ff,
};

pub fn createWindow(o: WindowOptions) !*Window {
    const w = try core.gpa.create(Window);
    errdefer core.gpa.destroy(w);
    w.* = .{
        .label = try core.gpa.dupe(u8, o.label),
        .hwnd = null,
        .decorations = o.decorations,
        .shadow = o.shadow,
        .min_w = 0,
        .min_h = 0,
    };
    var style: u32 = if (o.popup)
        c.WS_POPUP
    else if (o.decorations)
        c.WS_OVERLAPPEDWINDOW
    else
        // a caption-less window that still has a frame: snapping, Aero shake, animations and
        // the system shadow all keep working; WM_NCCALCSIZE hides the frame
        c.WS_POPUP | c.WS_THICKFRAME | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX | c.WS_MAXIMIZEBOX;
    if (!o.resizable) style &= ~@as(u32, c.WS_THICKFRAME | c.WS_MAXIMIZEBOX);
    var ex: u32 = 0;
    if (o.popup) ex |= c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE;
    if (o.always_on_top) ex |= c.WS_EX_TOPMOST;
    if (o.skip_taskbar and !o.popup) ex |= c.WS_EX_TOOLWINDOW;

    // size for the DPI of the primary screen; WM_DPICHANGED fixes it up on another screen
    var pt: c.POINT = .{ .x = o.x orelse 0, .y = o.y orelse 0 };
    const mon = c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTOPRIMARY);
    var mdpi_x: c.UINT = 96;
    var mdpi_y: c.UINT = 96;
    _ = c.GetDpiForMonitor(mon, c.MDT_EFFECTIVE_DPI, &mdpi_x, &mdpi_y);
    const scale = @as(f64, @floatFromInt(mdpi_x)) / 96.0;
    const pw: i32 = @intFromFloat(@round(o.width * scale));
    const ph: i32 = @intFromFloat(@round(o.height * scale));
    w.min_w = @intFromFloat(@round(o.min_width * scale));
    w.min_h = @intFromFloat(@round(o.min_height * scale));
    if (o.x == null or o.y == null) {
        var mi = std.mem.zeroes(c.MONITORINFO);
        mi.cbSize = @sizeOf(c.MONITORINFO);
        _ = c.GetMonitorInfoW(mon, &mi);
        const wa = mi.rcWork;
        pt.x = wa.left + @divTrunc((wa.right - wa.left) - pw, 2);
        pt.y = wa.top + @divTrunc((wa.bottom - wa.top) - ph, 2);
    }

    const title = try core.wide(core.gpa, o.title);
    defer core.gpa.free(title);
    const hwnd = c.CreateWindowExW(ex, class_name, title, style, pt.x, pt.y, pw, ph, null, null, hinstance, null);
    if (hwnd == null) return error.CreateWindow;
    w.hwnd = hwnd;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(w)));
    try windows.append(core.gpa, w);

    if (!o.decorations and !o.popup) {
        // recompute the frame now that WM_NCCALCSIZE answers for this window
        _ = c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        if (o.shadow) {
            const m: c.MARGINS = .{ .cxLeftWidth = 1, .cxRightWidth = 1, .cyTopHeight = 1, .cyBottomHeight = 1 };
            _ = c.DwmExtendFrameIntoClientArea(hwnd, &m);
        }
    }
    if (o.transparent) {
        // let the compositor show what is behind the window where the page is transparent
        const rgn = c.CreateRectRgn(0, 0, -1, -1);
        const bb: c.DWM_BLURBEHIND = .{ .dwFlags = c.DWM_BB_ENABLE | c.DWM_BB_BLURREGION, .fEnable = 1, .hRgnBlur = rgn, .fTransitionOnMaximized = 0 };
        _ = c.DwmEnableBlurBehindWindow(hwnd, &bb);
        _ = c.DeleteObject(rgn);
    }
    // dark title bar / frame colours follow the page
    const dark: c.BOOL = 1;
    _ = c.DwmSetWindowAttribute(hwnd, 20, &dark, @sizeOf(c.BOOL)); // DWMWA_USE_IMMERSIVE_DARK_MODE
    if (o.visible) _ = c.ShowWindow(hwnd, if (o.popup) c.SW_SHOWNOACTIVATE else c.SW_SHOW);
    return w;
}

fn setTaskbarVisible(hwnd: c.HWND, visible: bool) void {
    var ex = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    const was_visible = c.IsWindowVisible(hwnd) != 0;
    if (was_visible) _ = c.ShowWindow(hwnd, c.SW_HIDE);
    ex = if (visible) ex & ~@as(isize, c.WS_EX_TOOLWINDOW) else ex | c.WS_EX_TOOLWINDOW;
    _ = c.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, ex);
    if (was_visible) _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.c) c.LRESULT {
    if (runHooks(hwnd, msg, wp, lp)) |r| return r;
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wp, lp);
    const w: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        c.WM_NCCALCSIZE => if (!w.decorations and wp != 0) {
            // the whole window is client area; when maximized Windows hangs the frame off
            // screen, so keep the page inside the monitor's work area
            if (c.IsZoomed(hwnd) != 0) {
                const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lp)));
                const mon = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
                var mi = std.mem.zeroes(c.MONITORINFO);
                mi.cbSize = @sizeOf(c.MONITORINFO);
                if (c.GetMonitorInfoW(mon, &mi) != 0) params.rgrc[0] = mi.rcWork;
            }
            return 0;
        },
        c.WM_NCACTIVATE => if (!w.decorations) {
            // keeps Windows from painting a caption over the page on focus changes
            return c.DefWindowProcW(hwnd, msg, wp, -1);
        },
        c.WM_GETMINMAXINFO => {
            const mmi: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (w.min_w > 0) mmi.ptMinTrackSize.x = w.min_w;
            if (w.min_h > 0) mmi.ptMinTrackSize.y = w.min_h;
            return 0;
        },
        c.WM_SIZE => {
            if (w.webview) |v| v.fit();
            if (w.listener) |l| _ = l(w, .resized);
            return 0;
        },
        c.WM_MOVE => {
            for (webviews.items) |v| if (v.window == w) if (v.controller) |ctl| {
                _ = com.call(ctl, "NotifyParentWindowPositionChanged", .{});
            };
            if (w.listener) |l| _ = l(w, .moved);
            return 0;
        },
        c.WM_ACTIVATE => {
            const active = (wp & 0xffff) != c.WA_INACTIVE;
            if (active) if (w.webview) |v| if (v.controller) |ctl| {
                _ = com.call(ctl, "MoveFocus", .{c.COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC});
            };
            if (w.listener) |l| _ = l(w, if (active) .focused else .blurred);
        },
        c.WM_DPICHANGED => {
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            return 0;
        },
        c.WM_CLOSE => {
            if (w.listener) |l| if (l(w, .close_requested)) return 0;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (w.listener) |l| _ = l(w, .destroyed);
            var i: usize = webviews.items.len;
            while (i > 0) {
                i -= 1;
                if (webviews.items[i].window == w) webviews.items[i].close();
            }
            for (windows.items, 0..) |x, j| if (x == w) {
                _ = windows.swapRemove(j);
                break;
            };
            core.gpa.free(w.label);
            core.gpa.destroy(w);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------------- the WebView2 environment ----------------

var env: ?*c.ICoreWebView2Environment = null;
var env_failed: ?[]const u8 = null;
/// webviews asked for before the environment was ready
var waiting: std.ArrayList(*Webview) = .empty;

const CreateEnvFn = *const fn (c.PCWSTR, c.PCWSTR, ?*c.ICoreWebView2EnvironmentOptions, ?*c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(.c) c.HRESULT;

pub fn environment() ?*c.ICoreWebView2Environment {
    return env;
}

/// Where WebView2 keeps the profile: the same folder the Tauri build used. A dev copy with its
/// own data folder (`STUDIO_USER_DATA`) keeps its browser profile there too, so it never joins
/// the installed app's browser process.
pub fn webviewDataDir(a: Allocator) ![]u8 {
    if (core.getenv("STUDIO_USER_DATA") != null) return std.fs.path.join(a, &.{ core.userData(), "EBWebView" });
    return std.fs.path.join(a, &.{ core.localDataDir(), identifier, "EBWebView" });
}

fn startEnvironment() !void {
    // WebView2Loader.dll ships next to the exe
    const dir = try core.exeDir(core.gpa);
    defer core.gpa.free(dir);
    const dll = try std.fs.path.join(core.gpa, &.{ dir, "WebView2Loader.dll" });
    defer core.gpa.free(dll);
    const wdll = try core.wide(core.gpa, dll);
    defer core.gpa.free(wdll);
    const lib = c.LoadLibraryW(wdll) orelse c.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll")) orelse {
        env_failed = "WebView2Loader.dll is missing";
        return error.WebView2Loader;
    };
    const proc = c.GetProcAddress(lib, "CreateCoreWebView2EnvironmentWithOptions") orelse return error.WebView2Loader;
    const create: CreateEnvFn = @ptrCast(proc);

    const data = try webviewDataDir(core.gpa);
    defer core.gpa.free(data);
    const wdata = try com.wstr(core.gpa, data);
    defer core.gpa.free(wdata);
    const opts = EnvOptions.create();
    defer _ = opts.v1.lpVtbl.*.Release.?(&opts.v1);
    const h = com.handler(c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, &c.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, @as(?*anyopaque, null), onEnvironment);
    defer com.release(@as(?*c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, h));
    try com.check(create(null, wdata, &opts.v1, h));
}

fn onEnvironment(_: ?*anyopaque, hr: c.HRESULT, e: [*c]c.ICoreWebView2Environment) c.HRESULT {
    if (hr < 0 or e == null) {
        env_failed = "WebView2 could not start (is the WebView2 Runtime installed?)";
        std.log.err("WebView2 environment failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        _ = c.MessageBoxW(null, std.unicode.utf8ToUtf16LeStringLiteral("VIBE CODE needs the Microsoft Edge WebView2 Runtime. Install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703 and start the app again."), std.unicode.utf8ToUtf16LeStringLiteral("VIBE CODE"), c.MB_ICONERROR);
        c.PostQuitMessage(1);
        return com.S_OK;
    }
    com.addRef(e);
    env = e;
    for (waiting.items) |v| v.build();
    waiting.clearAndFree(core.gpa);
    return com.S_OK;
}

/// ICoreWebView2EnvironmentOptions (+2…6): extensions on, wry's default browser flags.
const EnvOptions = struct {
    v1: c.ICoreWebView2EnvironmentOptions,
    v2: c.ICoreWebView2EnvironmentOptions2,
    v3: c.ICoreWebView2EnvironmentOptions3,
    v4: c.ICoreWebView2EnvironmentOptions4,
    v5: c.ICoreWebView2EnvironmentOptions5,
    v6: c.ICoreWebView2EnvironmentOptions6,
    refs: std.atomic.Value(u32) = .init(1),

    const args = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection";
    const version = "158.0.4370.26";

    fn create() *EnvOptions {
        const o = std.heap.c_allocator.create(EnvOptions) catch @panic("oom");
        o.* = .{
            .v1 = .{ .lpVtbl = @constCast(&vt1) },
            .v2 = .{ .lpVtbl = @constCast(&vt2) },
            .v3 = .{ .lpVtbl = @constCast(&vt3) },
            .v4 = .{ .lpVtbl = @constCast(&vt4) },
            .v5 = .{ .lpVtbl = @constCast(&vt5) },
            .v6 = .{ .lpVtbl = @constCast(&vt6) },
        };
        return o;
    }

    fn from(comptime field: []const u8, this: anytype) *EnvOptions {
        return @fieldParentPtr(field, @as(*@FieldType(EnvOptions, field), @ptrCast(this)));
    }

    fn qiImpl(o: *EnvOptions, riid: [*c]const c.IID, out: [*c]?*anyopaque) c.HRESULT {
        const IID_IUnknown: c.IID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
        out.* = if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions) or com.eqlGuid(riid, &IID_IUnknown))
            @ptrCast(&o.v1)
        else if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions2))
            @ptrCast(&o.v2)
        else if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions3))
            @ptrCast(&o.v3)
        else if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions4))
            @ptrCast(&o.v4)
        else if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions5))
            @ptrCast(&o.v5)
        else if (com.eqlGuid(riid, &c.IID_ICoreWebView2EnvironmentOptions6))
            @ptrCast(&o.v6)
        else
            null;
        if (out.* == null) return com.E_NOINTERFACE;
        _ = o.refs.fetchAdd(1, .monotonic);
        return com.S_OK;
    }
    fn releaseImpl(o: *EnvOptions) c.ULONG {
        const n = o.refs.fetchSub(1, .acq_rel) - 1;
        if (n == 0) std.heap.c_allocator.destroy(o);
        return n;
    }

    fn Common(comptime field: []const u8, comptime I: type) type {
        return struct {
            fn qi(this: [*c]I, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
                return qiImpl(from(field, this), riid, out);
            }
            fn addRef(this: [*c]I) callconv(.c) c.ULONG {
                return from(field, this).refs.fetchAdd(1, .monotonic) + 1;
            }
            fn release(this: [*c]I) callconv(.c) c.ULONG {
                return releaseImpl(from(field, this));
            }
            fn getStr(comptime value: []const u8) fn ([*c]I, [*c]c.LPWSTR) callconv(.c) c.HRESULT {
                return struct {
                    fn f(_: [*c]I, v: [*c]c.LPWSTR) callconv(.c) c.HRESULT {
                        v.* = com.taskString(value);
                        return com.S_OK;
                    }
                }.f;
            }
            fn getBool(comptime value: bool) fn ([*c]I, [*c]c.BOOL) callconv(.c) c.HRESULT {
                return struct {
                    fn f(_: [*c]I, v: [*c]c.BOOL) callconv(.c) c.HRESULT {
                        v.* = @intFromBool(value);
                        return com.S_OK;
                    }
                }.f;
            }
            fn putStr(_: [*c]I, _: c.LPCWSTR) callconv(.c) c.HRESULT {
                return com.S_OK;
            }
            fn putBool(_: [*c]I, _: c.BOOL) callconv(.c) c.HRESULT {
                return com.S_OK;
            }
        };
    }

    const C1 = Common("v1", c.ICoreWebView2EnvironmentOptions);
    const vt1: c.ICoreWebView2EnvironmentOptionsVtbl = .{
        .QueryInterface = C1.qi,
        .AddRef = C1.addRef,
        .Release = C1.release,
        .get_AdditionalBrowserArguments = C1.getStr(args),
        .put_AdditionalBrowserArguments = C1.putStr,
        .get_Language = C1.getStr(""),
        .put_Language = C1.putStr,
        .get_TargetCompatibleBrowserVersion = C1.getStr(version),
        .put_TargetCompatibleBrowserVersion = C1.putStr,
        .get_AllowSingleSignOnUsingOSPrimaryAccount = C1.getBool(false),
        .put_AllowSingleSignOnUsingOSPrimaryAccount = C1.putBool,
    };
    const C2 = Common("v2", c.ICoreWebView2EnvironmentOptions2);
    const vt2: c.ICoreWebView2EnvironmentOptions2Vtbl = .{
        .QueryInterface = C2.qi,
        .AddRef = C2.addRef,
        .Release = C2.release,
        .get_ExclusiveUserDataFolderAccess = C2.getBool(false),
        .put_ExclusiveUserDataFolderAccess = C2.putBool,
    };
    const C3 = Common("v3", c.ICoreWebView2EnvironmentOptions3);
    const vt3: c.ICoreWebView2EnvironmentOptions3Vtbl = .{
        .QueryInterface = C3.qi,
        .AddRef = C3.addRef,
        .Release = C3.release,
        .get_IsCustomCrashReportingEnabled = C3.getBool(false),
        .put_IsCustomCrashReportingEnabled = C3.putBool,
    };
    const C4 = Common("v4", c.ICoreWebView2EnvironmentOptions4);
    const vt4: c.ICoreWebView2EnvironmentOptions4Vtbl = .{
        .QueryInterface = C4.qi,
        .AddRef = C4.addRef,
        .Release = C4.release,
        .GetCustomSchemeRegistrations = struct {
            fn f(_: [*c]c.ICoreWebView2EnvironmentOptions4, count: [*c]c.UINT32, list: [*c][*c][*c]c.ICoreWebView2CustomSchemeRegistration) callconv(.c) c.HRESULT {
                count.* = 0;
                list.* = null;
                return com.S_OK;
            }
        }.f,
        .SetCustomSchemeRegistrations = struct {
            fn f(_: [*c]c.ICoreWebView2EnvironmentOptions4, _: c.UINT32, _: [*c][*c]c.ICoreWebView2CustomSchemeRegistration) callconv(.c) c.HRESULT {
                return com.S_OK;
            }
        }.f,
    };
    const C5 = Common("v5", c.ICoreWebView2EnvironmentOptions5);
    const vt5: c.ICoreWebView2EnvironmentOptions5Vtbl = .{
        .QueryInterface = C5.qi,
        .AddRef = C5.addRef,
        .Release = C5.release,
        .get_EnableTrackingPrevention = C5.getBool(true),
        .put_EnableTrackingPrevention = C5.putBool,
    };
    const C6 = Common("v6", c.ICoreWebView2EnvironmentOptions6);
    const vt6: c.ICoreWebView2EnvironmentOptions6Vtbl = .{
        .QueryInterface = C6.qi,
        .AddRef = C6.addRef,
        .Release = C6.release,
        .get_AreBrowserExtensionsEnabled = C6.getBool(true),
        .put_AreBrowserExtensionsEnabled = C6.putBool,
    };
};

// ---------------- webviews ----------------

pub const WebviewOptions = struct {
    label: []const u8,
    /// absolute URL; app pages use `appUrl("/path")`
    url: []const u8,
    /// one of the app's own pages: gets `window.__VIBE__`, the IPC endpoint and the bundled files
    app: bool = true,
    /// physical pixels inside the window; null = fill the window and follow its size
    bounds: ?Rect = null,
    visible: bool = true,
    /// 0xRRGGBBAA painted before the page; alpha 0 = transparent
    background: u32 = 0xffffffff,
    user_agent: ?[]const u8 = null,
    devtools: bool = core.debug,
    /// Ctrl+wheel / Ctrl +/- zoom
    zoom_control: bool = false,
    /// files dragged in from Explorer arrive as `__drop` events (WebView2 alone never says
    /// where a dropped file lives)
    file_drop: bool = false,
    /// undecorated window: the edges of the page resize it
    resize_edges: bool = false,
    /// extra script run before each page's own scripts
    init_script: ?[]const u8 = null,
    /// once the page exists (controller + core webview); the place to add more event handlers
    on_ready: ?*const fn (*Webview, ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const Webview = struct {
    label: []const u8,
    window: *Window,
    controller: ?*c.ICoreWebView2Controller = null,
    view: ?*c.ICoreWebView2 = null,
    opts: WebviewOptions,
    bounds: ?Rect,
    visible: bool,
    closed: bool = false,
    drop: ?*DropTarget = null,
    /// what the owner keeps with it
    user: ?*anyopaque = null,

    fn build(v: *Webview) void {
        const h = com.handler(c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, &c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, v, onController);
        defer com.release(@as(?*c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, h));
        _ = com.call(env.?, "CreateCoreWebView2Controller", .{ v.window.hwnd, h });
    }

    /// physical bounds (null = fill) and visibility
    pub fn place(v: *Webview, r: ?Rect, visible: bool) void {
        v.bounds = r;
        v.visible = visible;
        if (v.controller) |ctl| {
            v.fit();
            _ = com.call(ctl, "put_IsVisible", .{@as(c.BOOL, @intFromBool(visible))});
        }
    }

    fn fit(v: *Webview) void {
        const ctl = v.controller orelse return;
        const rc: c.RECT = if (v.bounds) |b|
            .{ .left = b.x, .top = b.y, .right = b.x + b.w, .bottom = b.y + b.h }
        else blk: {
            var r: c.RECT = undefined;
            _ = c.GetClientRect(v.window.hwnd, &r);
            break :blk r;
        };
        _ = com.call(ctl, "put_Bounds", .{rc});
    }

    pub fn navigate(v: *Webview, url: []const u8) void {
        const view = v.view orelse return;
        const w = com.wstr(core.gpa, url) catch return;
        defer core.gpa.free(w);
        _ = com.call(view, "Navigate", .{w.ptr});
    }

    /// runs a script in the page (result ignored)
    pub fn eval(v: *Webview, js: []const u8) void {
        const view = v.view orelse return;
        const w = com.wstr(core.gpa, js) catch return;
        defer core.gpa.free(w);
        _ = com.call(view, "ExecuteScript", .{ w.ptr, null });
    }

    /// `window.chrome.webview` message (JSON text)
    pub fn postJson(v: *Webview, json: []const u8) void {
        const view = v.view orelse return;
        const w = com.wstr(core.gpa, json) catch return;
        defer core.gpa.free(w);
        _ = com.call(view, "PostWebMessageAsJson", .{w.ptr});
    }

    pub fn setZoom(v: *Webview, zoom: f64) void {
        if (v.controller) |ctl| _ = com.call(ctl, "put_ZoomFactor", .{zoom});
    }

    pub fn focus(v: *Webview) void {
        if (v.controller) |ctl| _ = com.call(ctl, "MoveFocus", .{c.COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC});
    }

    pub fn close(v: *Webview) void {
        if (v.closed) return;
        v.closed = true;
        if (v.window.webview == v) v.window.webview = null;
        if (v.drop) |d| d.revoke();
        if (v.controller) |ctl| {
            _ = com.call(ctl, "Close", .{});
            com.release(@as(?*c.ICoreWebView2Controller, ctl));
        }
        com.release(v.view);
        v.controller = null;
        v.view = null;
        for (webviews.items, 0..) |x, i| if (x == v) {
            _ = webviews.swapRemove(i);
            break;
        };
        for (waiting.items, 0..) |x, i| if (x == v) {
            _ = waiting.swapRemove(i);
            break;
        };
        // freed later: callbacks still in flight may hold it
        core.gpa.free(v.label);
        v.label = "";
    }
};

var webviews: std.ArrayList(*Webview) = .empty;

pub fn findWebview(label: []const u8) ?*Webview {
    for (webviews.items) |v| if (std.mem.eql(u8, v.label, label)) return v;
    return null;
}

/// URL of one of the app's own pages.
pub fn appUrl(a: Allocator, path: []const u8) ![]u8 {
    if (core.debug) if (core.getenv("VIBE_DEV_URL")) |dev| if (std.mem.eql(u8, path, "/"))
        return a.dupe(u8, dev);
    return std.mem.concat(a, u8, &.{ origin, path });
}

/// Creates a page in `win` (asynchronously: `on_ready` says when it exists).
pub fn createWebview(win: *Window, o: WebviewOptions) !*Webview {
    const v = try core.gpa.create(Webview);
    var opts = o;
    opts.label = try core.gpa.dupe(u8, o.label);
    opts.url = try core.gpa.dupe(u8, o.url);
    if (o.user_agent) |ua| opts.user_agent = try core.gpa.dupe(u8, ua);
    if (o.init_script) |s| opts.init_script = try core.gpa.dupe(u8, s);
    v.* = .{ .label = opts.label, .window = win, .opts = opts, .bounds = o.bounds, .visible = o.visible };
    if (o.bounds == null) win.webview = v;
    try webviews.append(core.gpa, v);
    if (env != null) v.build() else try waiting.append(core.gpa, v);
    return v;
}

fn onController(v: *Webview, hr: c.HRESULT, ctl: [*c]c.ICoreWebView2Controller) c.HRESULT {
    if (v.closed) return com.S_OK;
    if (hr < 0 or ctl == null) {
        std.log.err("webview {s}: controller failed 0x{x}", .{ v.label, @as(u32, @bitCast(hr)) });
        return com.S_OK;
    }
    com.addRef(ctl);
    v.controller = ctl;
    var view: ?*c.ICoreWebView2 = null;
    _ = com.call(ctl, "get_CoreWebView2", .{&view});
    v.view = view;
    const o = &v.opts;

    // background before the first paint
    if (com.query(c.ICoreWebView2Controller2, ctl, &c.IID_ICoreWebView2Controller2)) |c2| {
        defer com.release(@as(?*c.ICoreWebView2Controller2, c2));
        const bg = o.background;
        const col: c.COREWEBVIEW2_COLOR = .{ .R = @truncate(bg >> 24), .G = @truncate(bg >> 16), .B = @truncate(bg >> 8), .A = @truncate(bg) };
        _ = com.call(c2, "put_DefaultBackgroundColor", .{col});
    }

    var settings: ?*c.ICoreWebView2Settings = null;
    _ = com.call(view.?, "get_Settings", .{&settings});
    if (settings) |s| {
        defer com.release(@as(?*c.ICoreWebView2Settings, s));
        _ = com.call(s, "put_AreDevToolsEnabled", .{@as(c.BOOL, @intFromBool(o.devtools))});
        _ = com.call(s, "put_IsZoomControlEnabled", .{@as(c.BOOL, @intFromBool(o.zoom_control))});
        _ = com.call(s, "put_IsStatusBarEnabled", .{@as(c.BOOL, @intFromBool(!o.app))});
        if (o.app) _ = com.call(s, "put_AreDefaultContextMenusEnabled", .{@as(c.BOOL, @intFromBool(core.debug))});
        if (o.user_agent) |ua| if (com.query(c.ICoreWebView2Settings2, s, &c.IID_ICoreWebView2Settings2)) |s2| {
            defer com.release(@as(?*c.ICoreWebView2Settings2, s2));
            const w = com.wstr(core.gpa, ua) catch null;
            if (w) |ws| {
                defer core.gpa.free(ws);
                _ = com.call(s2, "put_UserAgent", .{ws.ptr});
            }
        };
        if (com.query(c.ICoreWebView2Settings3, s, &c.IID_ICoreWebView2Settings3)) |s3| {
            defer com.release(@as(?*c.ICoreWebView2Settings3, s3));
            // the app's own keys (F5, Ctrl+P, Ctrl+F…) are not the browser's
            if (o.app) _ = com.call(s3, "put_AreBrowserAcceleratorKeysEnabled", .{@as(c.BOOL, @intFromBool(core.debug))});
        }
    }

    if (o.app) {
        const filter = com.wstr(core.gpa, origin ++ "/*") catch unreachable;
        defer core.gpa.free(filter);
        _ = com.call(view.?, "AddWebResourceRequestedFilter", .{ filter.ptr, c.COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL });
        com.on(view.?, "WebResourceRequested", c.ICoreWebView2WebResourceRequestedEventHandler, &c.IID_ICoreWebView2WebResourceRequestedEventHandler, v, onRequest);
        addScript(view.?, shared.bridgeScript());
        if (o.resize_edges) addScript(view.?, resize_script);
    }
    if (o.init_script) |s| addScript(view.?, s);
    if (o.file_drop) {
        if (com.query(c.ICoreWebView2Controller4, ctl, &c.IID_ICoreWebView2Controller4)) |c4| {
            defer com.release(@as(?*c.ICoreWebView2Controller4, c4));
            _ = com.call(c4, "put_AllowExternalDrop", .{@as(c.BOOL, 0)});
        }
        v.drop = DropTarget.register(v);
    }

    v.fit();
    _ = com.call(ctl, "put_IsVisible", .{@as(c.BOOL, @intFromBool(v.visible))});
    if (o.on_ready) |f| f(v, o.ctx);
    if (!v.closed) v.navigate(o.url);
    return com.S_OK;
}

fn addScript(view: *c.ICoreWebView2, js: []const u8) void {
    const w = com.wstr(core.gpa, js) catch return;
    defer core.gpa.free(w);
    _ = com.call(view, "AddScriptToExecuteOnDocumentCreated", .{ w.ptr, null });
}

/// Undecorated windows have no frame to grab: the page's outer 5 px resize it, like Tauri's.
const resize_script =
    \\(() => {
    \\  const B = 5; let set = false
    \\  const dir = (e) => {
    \\    if (window.outerWidth >= screen.availWidth && window.outerHeight >= screen.availHeight) return ''
    \\    const w = window.innerWidth, h = window.innerHeight, x = e.clientX, y = e.clientY
    \\    return (y < B ? 'n' : y >= h - B ? 's' : '') + (x < B ? 'w' : x >= w - B ? 'e' : '')
    \\  }
    \\  const cur = { n: 'ns-resize', s: 'ns-resize', e: 'ew-resize', w: 'ew-resize', ne: 'nesw-resize', sw: 'nesw-resize', nw: 'nwse-resize', se: 'nwse-resize' }
    \\  document.addEventListener('mousemove', (e) => {
    \\    const d = dir(e)
    \\    if (d) { document.documentElement.style.cursor = cur[d]; set = true }
    \\    else if (set) { document.documentElement.style.cursor = ''; set = false }
    \\  }, true)
    \\  document.addEventListener('mousedown', (e) => {
    \\    if (e.button !== 0) return
    \\    const d = dir(e)
    \\    if (!d) return
    \\    e.preventDefault(); e.stopPropagation()
    \\    window.__VIBE__.invoke('__win_resize', { dir: d })
    \\  }, true)
    \\})()
;

// ---------------- serving the app's pages ----------------

const csp = "default-src 'self'; connect-src 'self' http://tauri.localhost ws://localhost:* http://localhost:*; script-src 'self'; style-src 'self' 'unsafe-inline'; " ++
    "img-src 'self' data: blob: https:; media-src 'self' blob: https:; font-src 'self' data:; worker-src 'self' blob:; frame-src http://127.0.0.1:*";

const Pending = struct {
    args: *c.ICoreWebView2WebResourceRequestedEventArgs,
    deferral: *c.ICoreWebView2Deferral,
};

fn onRequest(v: *Webview, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2WebResourceRequestedEventArgs) c.HRESULT {
    var arena_state: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var req: ?*c.ICoreWebView2WebResourceRequest = null;
    _ = com.call(args, "get_Request", .{&req});
    const r = req orelse return com.S_OK;
    defer com.release(@as(?*c.ICoreWebView2WebResourceRequest, r));
    var uri_w: c.LPWSTR = null;
    _ = com.call(r, "get_Uri", .{&uri_w});
    const uri = com.takeString(a, uri_w) catch return com.S_OK;
    var method_w: c.LPWSTR = null;
    _ = com.call(r, "get_Method", .{&method_w});
    const method = com.takeString(a, method_w) catch return com.S_OK;

    // path without origin, query and fragment
    var path: []const u8 = uri[@min(uri.len, origin.len)..];
    if (std.mem.indexOfAny(u8, path, "?#")) |i| path = path[0..i];
    if (path.len == 0) path = "/";

    if (std.mem.startsWith(u8, path, "/__ipc/")) {
        if (std.mem.eql(u8, method, "OPTIONS")) {
            respond(args, 204, "No Content", "", "text/plain", true);
            return com.S_OK;
        }
        const cmd = path["/__ipc/".len..];
        const headers = readHeaders(a, r) catch &.{};
        const body = readBody(a, r) catch "";
        var deferral: ?*c.ICoreWebView2Deferral = null;
        _ = com.call(args, "GetDeferral", .{&deferral});
        const p = core.gpa.create(Pending) catch return com.S_OK;
        com.addRef(args);
        p.* = .{ .args = args, .deferral = deferral.? };
        ipc.dispatch(.{ .cmd = cmd, .body = body, .headers = headers, .webview = v.label, .done = ipcDone, .ctx = p });
        return com.S_OK;
    }

    // routes other modules registered (toast page, capture page…)
    if (shared.findRoute(path)) |route| {
        if (route(a, path, uri)) |res| {
            respond(args, res.status, "OK", res.body, res.mime, false);
            return com.S_OK;
        }
    }

    // the bundled renderer; paths without an extension are the single-page app
    const file = assets.get(path) orelse if (std.fs.path.extension(path).len == 0) assets.get("/index.html") else null;
    if (file) |f| {
        respondFile(args, f.body, f.mime, std.mem.endsWith(u8, f.mime, "html") or std.mem.startsWith(u8, f.mime, "text/html"));
    } else {
        respond(args, 404, "Not Found", "not found", "text/plain", false);
    }
    return com.S_OK;
}

fn ipcDone(ctx: *anyopaque, reply: ipc.Reply) void {
    const p: *Pending = @ptrCast(@alignCast(ctx));
    // the reply is freed when this returns: copy it for the UI thread
    const body: []u8 = core.gpa.dupe(u8, reply.body) catch &.{};
    onUi(finishIpc, .{ p, body, reply.ok, reply.binary });
}

fn finishIpc(p: *Pending, body: []u8, ok: bool, binary: bool) void {
    defer {
        core.gpa.free(body);
        _ = com.call(p.deferral, "Complete", .{});
        com.release(@as(?*c.ICoreWebView2Deferral, p.deferral));
        com.release(@as(?*c.ICoreWebView2WebResourceRequestedEventArgs, p.args));
        core.gpa.destroy(p);
    }
    if (!ok) return respond(p.args, 400, "Bad Request", body, "text/plain; charset=utf-8", true);
    respond(p.args, 200, "OK", body, if (binary) "application/octet-stream" else "application/json", true);
}

fn respondFile(args: *c.ICoreWebView2WebResourceRequestedEventArgs, body: []const u8, mime: []const u8, html: bool) void {
    var buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(&buf, "Content-Type: {s}\r\nCache-Control: no-cache{s}{s}", .{ mime, if (html) "\r\nContent-Security-Policy: " else "", if (html) csp else "" }) catch return;
    respondRaw(args, 200, "OK", body, headers);
}

fn respond(args: *c.ICoreWebView2WebResourceRequestedEventArgs, status: c_int, reason: []const u8, body: []const u8, mime: []const u8, cors: bool) void {
    var buf: [512]u8 = undefined;
    const headers = std.fmt.bufPrint(&buf, "Content-Type: {s}{s}", .{ mime, if (cors) "\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS" else "" }) catch return;
    respondRaw(args, status, reason, body, headers);
}

fn respondRaw(args: *c.ICoreWebView2WebResourceRequestedEventArgs, status: c_int, reason: []const u8, body: []const u8, headers: []const u8) void {
    const e = env orelse return;
    const stream = c.SHCreateMemStream(body.ptr, @intCast(body.len));
    defer com.release(@as(?*c.IStream, stream));
    const wr = com.wstr(core.gpa, reason) catch return;
    defer core.gpa.free(wr);
    const wh = com.wstr(core.gpa, headers) catch return;
    defer core.gpa.free(wh);
    var res: ?*c.ICoreWebView2WebResourceResponse = null;
    _ = com.call(e, "CreateWebResourceResponse", .{ stream, status, wr.ptr, wh.ptr, &res });
    if (res) |rp| {
        defer com.release(@as(?*c.ICoreWebView2WebResourceResponse, rp));
        _ = com.call(args, "put_Response", .{rp});
    }
}

fn readHeaders(a: Allocator, r: *c.ICoreWebView2WebResourceRequest) ![]const ipc.Header {
    var list: std.ArrayList(ipc.Header) = .empty;
    var hs: ?*c.ICoreWebView2HttpRequestHeaders = null;
    _ = com.call(r, "get_Headers", .{&hs});
    const h = hs orelse return list.items;
    defer com.release(@as(?*c.ICoreWebView2HttpRequestHeaders, h));
    var iter: ?*c.ICoreWebView2HttpHeadersCollectionIterator = null;
    _ = com.call(h, "GetIterator", .{&iter});
    const it = iter orelse return list.items;
    defer com.release(@as(?*c.ICoreWebView2HttpHeadersCollectionIterator, it));
    var has: c.BOOL = 0;
    _ = com.call(it, "get_HasCurrentHeader", .{&has});
    while (has != 0) {
        var n: c.LPWSTR = null;
        var val: c.LPWSTR = null;
        if (com.call(it, "GetCurrentHeader", .{ &n, &val }) >= 0)
            try list.append(a, .{ .name = try com.takeString(a, n), .value = try com.takeString(a, val) });
        var more: c.BOOL = 0;
        if (com.call(it, "MoveNext", .{&more}) < 0) break;
        has = more;
    }
    return list.items;
}

fn readBody(a: Allocator, r: *c.ICoreWebView2WebResourceRequest) ![]const u8 {
    var s: ?*c.IStream = null;
    _ = com.call(r, "get_Content", .{&s});
    const stream = s orelse return "";
    defer com.release(@as(?*c.IStream, stream));
    var out: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var n: c.ULONG = 0;
        const hr = com.call(stream, "Read", .{ &buf, @as(c.ULONG, buf.len), &n });
        if (n > 0) try out.appendSlice(a, buf[0..n]);
        if (hr != com.S_OK or n == 0) break;
    }
    return out.items;
}

// ---------------- native → page ----------------

/// Sends a message (JSON text) to a webview by label (from any thread).
pub fn post(label: []const u8, json: []const u8) void {
    if (isUiThread()) return postNow(label, json);
    const l = core.gpa.dupe(u8, label) catch return;
    const j = core.gpa.dupe(u8, json) catch {
        core.gpa.free(l);
        return;
    };
    onUi(postOwned, .{ l, j });
}

fn postOwned(label: []u8, json: []u8) void {
    defer core.gpa.free(label);
    defer core.gpa.free(json);
    postNow(label, json);
}

fn postNow(label: []const u8, json: []const u8) void {
    const v = findWebview(label) orelse return;
    v.postJson(json);
}

// ---------------- files dropped from Explorer ----------------

const DropTarget = struct {
    iface: c.IDropTarget,
    refs: std.atomic.Value(u32) = .init(1),
    view: *Webview,
    hwnds: [8]c.HWND = undefined,
    count: usize = 0,

    const vtbl: c.IDropTargetVtbl = .{
        .QueryInterface = qi,
        .AddRef = addRefImpl,
        .Release = releaseImpl,
        .DragEnter = dragEnter,
        .DragOver = dragOver,
        .DragLeave = dragLeave,
        .Drop = drop,
    };

    fn register(v: *Webview) ?*DropTarget {
        const d = core.gpa.create(DropTarget) catch return null;
        d.* = .{ .iface = .{ .lpVtbl = @constCast(&vtbl) }, .view = v };
        // WebView2 makes its own child windows: the drop lands on those, not on ours
        _ = c.EnumChildWindows(v.window.hwnd, enumChild, @bitCast(@intFromPtr(d)));
        if (d.count == 0) d.add(v.window.hwnd);
        return d;
    }

    fn enumChild(hwnd: c.HWND, lp: c.LPARAM) callconv(.c) c.BOOL {
        const d: *DropTarget = @ptrFromInt(@as(usize, @bitCast(lp)));
        d.add(hwnd);
        return 1;
    }

    fn add(d: *DropTarget, hwnd: c.HWND) void {
        if (d.count == d.hwnds.len) return;
        _ = c.RevokeDragDrop(hwnd);
        if (c.RegisterDragDrop(hwnd, &d.iface) >= 0) {
            d.hwnds[d.count] = hwnd;
            d.count += 1;
        }
    }

    fn revoke(d: *DropTarget) void {
        for (d.hwnds[0..d.count]) |h| _ = c.RevokeDragDrop(h);
        d.count = 0;
        _ = releaseImpl(&d.iface);
    }

    fn self(this: [*c]c.IDropTarget) *DropTarget {
        return @fieldParentPtr("iface", @as(*c.IDropTarget, @ptrCast(this)));
    }
    fn qi(this: [*c]c.IDropTarget, _: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
        _ = self(this).refs.fetchAdd(1, .monotonic);
        out.* = @ptrCast(this);
        return com.S_OK;
    }
    fn addRefImpl(this: [*c]c.IDropTarget) callconv(.c) c.ULONG {
        return self(this).refs.fetchAdd(1, .monotonic) + 1;
    }
    fn releaseImpl(this: [*c]c.IDropTarget) callconv(.c) c.ULONG {
        const d = self(this);
        const n = d.refs.fetchSub(1, .acq_rel) - 1;
        if (n == 0) core.gpa.destroy(d);
        return n;
    }

    fn send(d: *DropTarget, kind: []const u8, paths: ?[]const []const u8, pt: c.POINTL) void {
        var p: c.POINT = .{ .x = pt.x, .y = pt.y };
        _ = c.ScreenToClient(d.view.window.hwnd, &p);
        const Payload = struct { type: []const u8, paths: []const []const u8, position: struct { x: i32, y: i32 } };
        core.emitTo(d.view.label, "__drop", Payload{ .type = kind, .paths = paths orelse &.{}, .position = .{ .x = p.x, .y = p.y } });
    }

    fn dragEnter(this: [*c]c.IDropTarget, data: [*c]c.IDataObject, _: c.DWORD, pt: c.POINTL, effect: [*c]c.DWORD) callconv(.c) c.HRESULT {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const paths = filePaths(arena.allocator(), data);
        effect.* = if (paths.len > 0) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
        self(this).send("enter", paths, pt);
        return com.S_OK;
    }
    fn dragOver(this: [*c]c.IDropTarget, _: c.DWORD, pt: c.POINTL, effect: [*c]c.DWORD) callconv(.c) c.HRESULT {
        effect.* = c.DROPEFFECT_COPY;
        self(this).send("over", null, pt);
        return com.S_OK;
    }
    fn dragLeave(this: [*c]c.IDropTarget) callconv(.c) c.HRESULT {
        const Payload = struct { type: []const u8 };
        core.emitTo(self(this).view.label, "__drop", Payload{ .type = "leave" });
        return com.S_OK;
    }
    fn drop(this: [*c]c.IDropTarget, data: [*c]c.IDataObject, _: c.DWORD, pt: c.POINTL, effect: [*c]c.DWORD) callconv(.c) c.HRESULT {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const paths = filePaths(arena.allocator(), data);
        effect.* = if (paths.len > 0) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
        self(this).send("drop", paths, pt);
        return com.S_OK;
    }

    fn filePaths(a: Allocator, data: [*c]c.IDataObject) []const []const u8 {
        var fmt: c.FORMATETC = .{ .cfFormat = c.CF_HDROP, .ptd = null, .dwAspect = c.DVASPECT_CONTENT, .lindex = -1, .tymed = c.TYMED_HGLOBAL };
        var medium: c.STGMEDIUM = undefined;
        if (com.call(data, "GetData", .{ &fmt, &medium }) < 0) return &.{};
        defer c.ReleaseStgMedium(&medium);
        const hdrop: c.HDROP = @ptrCast(@alignCast(medium.unnamed_0.hGlobal));
        const n = c.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
        var out: std.ArrayList([]const u8) = .empty;
        var i: c.UINT = 0;
        while (i < n) : (i += 1) {
            var buf: [32768]u16 = undefined;
            const len = c.DragQueryFileW(hdrop, i, &buf, buf.len);
            const s = std.unicode.wtf16LeToWtf8Alloc(a, buf[0..len]) catch continue;
            out.append(a, s) catch {};
        }
        return out.items;
    }
};

// ---------------- message boxes ----------------

/// OK / Cancel box over the main window; true = OK (from any thread).
pub fn askOkCancel(title: []const u8, message: []const u8) bool {
    const t = core.wide(core.gpa, title) catch return false;
    defer core.gpa.free(t);
    const m = core.wide(core.gpa, message) catch return false;
    defer core.gpa.free(m);
    const owner = if (findWindowAny(shared.main_label)) |w| w.hwnd else null;
    return c.MessageBoxW(owner, m, t, c.MB_OKCANCEL | c.MB_ICONQUESTION | c.MB_SETFOREGROUND) == c.IDOK;
}

/// `findWindow` that may be called off the UI thread (reads the list without changing it).
fn findWindowAny(label: []const u8) ?*Window {
    return onUiSync(findWindow, .{label});
}
