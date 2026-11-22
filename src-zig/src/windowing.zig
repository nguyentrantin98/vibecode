//! The main window and how it lives on screen:
//!  - "window"   — an ordinary desktop window
//!  - "dropdown" — Guake-style: a global hotkey slides it down from the top edge of the
//!    screen under the mouse, above every other app, and back up again.
//!
//! Plus the tray icon, the taskbar badge, start-at-login and the single running instance.
//!
//! Windows belong to the UI thread: everything below that touches one runs there (the functions
//! other modules call hop over by themselves).

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const settings = @import("settings.zig");
const m = @import("modules.zig");

const W = host.win;
const c = W.c;
const Rect = host.Rect;

/// Launched by the OS at sign-in: start tucked away in the tray.
pub const hidden_arg = "--hidden";
/// F12 is reserved by Windows for the debugger, so fall back through a few Guake-ish keys.
const hotkey_fallbacks = [_][]const u8{ "Alt+`", "Ctrl+Alt+`", "Ctrl+Alt+Space" };

var main_win: ?*W.Window = null;
var dropdown_mode: std.atomic.Value(bool) = .init(false);
/// the window's bounds before it became a drop-down (UI thread)
var normal: ?Rect = null;
var animating: std.atomic.Value(bool) = .init(false);
var hotkey_ok: std.atomic.Value(bool) = .init(false);
var quitting: std.atomic.Value(bool) = .init(false);

fn dropdown() bool {
    return dropdown_mode.load(.acquire);
}

const Prefs = struct { drop_height: f64, drop_opacity: f64, see_through: bool, hide_on_blur: bool, open_at_login: bool };

fn prefs() Prefs {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const s = settings.get(arena.allocator());
    return .{ .drop_height = s.dropHeight, .drop_opacity = s.dropOpacity, .see_through = s.seeThrough, .hide_on_blur = s.hideOnBlur, .open_at_login = s.openAtLogin orelse true };
}

/// Whole-window opacity. In see-through mode the page fades its own backgrounds instead.
fn winOpacity() f64 {
    const p = prefs();
    return if (p.see_through) 1.0 else std.math.clamp(p.drop_opacity, 0.2, 1.0);
}

pub const WindowState = struct {
    mode: []const u8,
    maximized: bool,
    hotkey: []const u8,
    hotkeyOk: bool,
};

/// `hotkey` is allocated in `a`.
fn windowState(a: std.mem.Allocator) WindowState {
    return .{
        .mode = if (dropdown()) "dropdown" else "window",
        .maximized = host.onUiSync(isMaximized, .{}),
        .hotkey = settings.get(a).hotkey,
        .hotkeyOk = hotkey_ok.load(.acquire),
    };
}

fn isMaximized() bool {
    return if (main_win) |w| w.isMaximized() else false;
}

fn pushState() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    core.emit("win:state", .{windowState(arena.allocator())});
}

// ---------------- geometry ----------------

/// Work area of the screen under the mouse.
fn targetWorkArea() ?Rect {
    var pt: c.POINT = undefined;
    const mon = if (c.GetCursorPos(&pt) != 0)
        c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTONEAREST)
    else if (main_win) |w|
        c.MonitorFromWindow(w.hwnd, c.MONITOR_DEFAULTTOPRIMARY)
    else
        return null;
    var mi = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(mon, &mi) == 0) return null;
    const r = mi.rcWork;
    return .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
}

fn dropBounds() ?Rect {
    const wa = targetWorkArea() orelse return null;
    const h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(wa.h)) * std.math.clamp(prefs().drop_height, 0.25, 1.0)));
    return .{ .x = wa.x, .y = wa.y, .w = wa.w, .h = h };
}

// ---------------- opacity (Win32 layered window) ----------------

fn setOpacity(w: *W.Window, op: f64) void {
    const ex = c.GetWindowLongPtrW(w.hwnd, c.GWL_EXSTYLE);
    const layered: isize = c.WS_EX_LAYERED;
    if (op >= 0.999) {
        if (ex & layered != 0) _ = c.SetWindowLongPtrW(w.hwnd, c.GWL_EXSTYLE, ex & ~layered);
        return;
    }
    if (ex & layered == 0) _ = c.SetWindowLongPtrW(w.hwnd, c.GWL_EXSTYLE, ex | layered);
    const alpha: u8 = @intFromFloat(@round(std.math.clamp(op, 0.0, 1.0) * 255.0));
    _ = c.SetLayeredWindowAttributes(w.hwnd, 0, alpha, c.LWA_ALPHA);
}

// ---------------- slide animation ----------------

const Anim = struct {
    from_y: i32,
    to: Rect,
    from_op: f64,
    to_op: f64,
    ms: u64,
    /// slide down: focus the window; slide up: hide it and put it back at `restore`
    down: bool,
    restore: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

fn animate(an: Anim) void {
    animating.store(true, .release);
    core.spawn(animThread, .{an});
}

fn animThread(an: Anim) void {
    const start = core.monoMs();
    while (true) {
        const t = @min(1.0, @as(f64, @floatFromInt(core.monoMs() - start)) / @as(f64, @floatFromInt(an.ms)));
        host.onUiSync(animStep, .{ an, t });
        if (t >= 1.0) break;
        core.sleepMs(7);
    }
    animating.store(false, .release);
    host.onUiSync(animDone, .{an});
}

fn animStep(an: Anim, t: f64) void {
    const w = main_win orelse return;
    const e = 1.0 - std.math.pow(f64, 1.0 - t, 3); // ease-out cubic
    const y: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(an.from_y)) + @as(f64, @floatFromInt(an.to.y - an.from_y)) * e));
    w.setPosition(an.to.x, y);
    setOpacity(w, an.from_op + (an.to_op - an.from_op) * e);
}

fn animDone(an: Anim) void {
    const w = main_win orelse return;
    if (an.down) {
        w.focus();
        core.emit("win:shown", .{});
    } else {
        w.hide();
        w.setBounds(an.restore);
    }
}

fn slideDown(w: *W.Window) void {
    const b = dropBounds() orelse return;
    const from = b.y - b.h;
    setOpacity(w, 0.0);
    w.setBounds(.{ .x = b.x, .y = from, .w = b.w, .h = b.h });
    w.setAlwaysOnTop(true);
    w.showInactive();
    animate(.{ .from_y = from, .to = b, .from_op = 0.0, .to_op = winOpacity(), .ms = 170, .down = true });
}

fn slideUp(w: *W.Window) void {
    const b = w.bounds();
    animate(.{ .from_y = b.y, .to = .{ .x = b.x, .y = b.y - b.h, .w = b.w, .h = b.h }, .from_op = winOpacity(), .to_op = 0.0, .ms = 130, .down = false, .restore = b });
}

// ---------------- show / hide ----------------

/// The hotkey, the tray icon, a second launch: show the window, or put it away.
pub fn toggle() void {
    if (!host.isUiThread()) return host.onUi(toggle, .{});
    const w = main_win orelse return;
    if (animating.load(.acquire)) return;
    const visible = w.isVisible();
    const focused = w.isFocused();
    if (!dropdown()) {
        if (visible and focused and !w.isMinimized()) w.minimize() else show();
        return;
    }
    if (visible) {
        if (focused) slideUp(w) else w.focus();
    } else {
        slideDown(w);
    }
}

pub fn show() void {
    if (!host.isUiThread()) return host.onUi(show, .{});
    const w = main_win orelse return;
    if (dropdown()) {
        if (!w.isVisible() and !animating.load(.acquire)) slideDown(w) else w.focus();
        return;
    }
    if (w.isMinimized()) w.restore();
    w.show();
    w.focus();
}

fn hideDropdown() void {
    const w = main_win orelse return;
    if (dropdown() and w.isVisible() and !animating.load(.acquire)) slideUp(w);
}

fn applyDropdown(w: *W.Window, show_it: bool) void {
    w.setSkipTaskbar(true);
    w.setMinMaxBoxes(false, false);
    w.setAlwaysOnTop(true);
    if (show_it) {
        slideDown(w);
    } else {
        if (dropBounds()) |b| w.setBounds(b);
        w.hide();
    }
}

fn applyWindow(w: *W.Window) void {
    w.setAlwaysOnTop(false);
    w.setSkipTaskbar(false);
    w.setMinMaxBoxes(true, true);
    setOpacity(w, winOpacity());
    if (normal) |b| {
        w.setBounds(b);
    } else if (targetWorkArea()) |wa| {
        const sw = @min(1480, @max(0, wa.w - 80));
        const sh = @min(920, @max(0, wa.h - 60));
        w.setBounds(.{ .x = wa.x + @divTrunc(wa.w - sw, 2), .y = wa.y + @divTrunc(wa.h - sh, 2), .w = sw, .h = sh });
    }
    w.show();
    w.focus();
}

fn setMode(to_dropdown: bool) void {
    const w = main_win orelse return;
    if (to_dropdown == dropdown()) return;
    if (to_dropdown) {
        if (w.isMaximized()) w.restore();
        normal = w.bounds();
        dropdown_mode.store(true, .release);
        applyDropdown(w, true);
    } else {
        dropdown_mode.store(false, .release);
        applyWindow(w);
    }
    saveSetting(.{ .mode = if (to_dropdown) "dropdown" else "window" });
    pushState();
    buildTrayMenu();
}

fn saveSetting(fields: anytype) void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    _ = settings.set(arena.allocator(), fields) catch {};
}

/// Re-apply drop-down height / opacity after the settings changed (in-app panel or tray).
pub fn applyDropPrefs() void {
    if (!host.isUiThread()) return host.onUi(applyDropPrefs, .{});
    const w = main_win orelse return;
    if (dropdown() and w.isVisible() and !animating.load(.acquire)) {
        if (dropBounds()) |b| w.setBounds(b);
        setOpacity(w, winOpacity());
    }
    // the opacity setting applies to the normal window too
    if (!dropdown()) setOpacity(w, winOpacity());
    buildTrayMenu();
    pushState();
}

// ---------------- hotkeys ----------------

const hk_toggle = 1;
const hk_capture = 2;

const Hotkey = struct { mods: c.UINT, vk: c.UINT };

/// "Ctrl+Alt+Z", "Alt+`", "F12", "Ctrl+Shift+Space"… → RegisterHotKey's modifiers and key.
fn parseHotkey(text: []const u8) ?Hotkey {
    var mods: c.UINT = 0;
    var vk: ?c.UINT = null;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " ");
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(t, "ctrl") or eq(t, "control") or eq(t, "cmdorctrl") or eq(t, "commandorcontrol")) {
            mods |= 0x0002;
        } else if (eq(t, "alt") or eq(t, "option")) {
            mods |= 0x0001;
        } else if (eq(t, "shift")) {
            mods |= 0x0004;
        } else if (eq(t, "super") or eq(t, "win") or eq(t, "cmd") or eq(t, "command") or eq(t, "meta")) {
            mods |= 0x0008;
        } else if (vk != null) {
            return null; // two keys
        } else if (t.len == 1 and std.ascii.isAlphanumeric(t[0])) {
            vk = std.ascii.toUpper(t[0]);
        } else if (t.len >= 2 and (t[0] == 'F' or t[0] == 'f') and std.fmt.parseInt(u8, t[1..], 10) catch 0 >= 1 and std.fmt.parseInt(u8, t[1..], 10) catch 99 <= 24) {
            vk = 0x70 + @as(c.UINT, std.fmt.parseInt(u8, t[1..], 10) catch unreachable) - 1;
        } else {
            const named = .{
                .{ "`", 0xC0 },     .{ "Backquote", 0xC0 }, .{ "Space", 0x20 },    .{ "Tab", 0x09 },      .{ "Enter", 0x0D },
                .{ "Escape", 0x1B }, .{ "Esc", 0x1B },       .{ "Backspace", 0x08 }, .{ "Delete", 0x2E },   .{ "Insert", 0x2D },
                .{ "Home", 0x24 },   .{ "End", 0x23 },       .{ "PageUp", 0x21 },    .{ "PageDown", 0x22 }, .{ "Up", 0x26 },
                .{ "Down", 0x28 },   .{ "Left", 0x25 },      .{ "Right", 0x27 },     .{ "-", 0xBD },        .{ "=", 0xBB },
                .{ ",", 0xBC },      .{ ".", 0xBE },         .{ "/", 0xBF },         .{ ";", 0xBA },        .{ "'", 0xDE },
                .{ "[", 0xDB },      .{ "]", 0xDD },         .{ "\\", 0xDC },
            };
            inline for (named) |n| {
                if (vk == null and eq(t, n[0])) vk = n[1];
            }
            if (vk == null) return null;
        }
    }
    return .{ .mods = mods, .vk = vk orelse return null };
}

fn registerOne(id: c_int, text: []const u8) bool {
    const hk = parseHotkey(text) orelse return false;
    const no_repeat = 0x4000;
    return c.RegisterHotKey(W.messageWindow(), id, hk.mods | no_repeat, hk.vk) != 0;
}

fn registerHotkey() void {
    _ = c.UnregisterHotKey(W.messageWindow(), hk_toggle);
    _ = c.UnregisterHotKey(W.messageWindow(), hk_capture);
    // screen capture, from any app
    if (@hasDecl(m.capture, "hotkey")) _ = registerOne(hk_capture, m.capture.hotkey);
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const wanted = settings.get(arena.allocator()).hotkey;
    hotkey_ok.store(false, .release);
    if (registerOne(hk_toggle, wanted)) {
        hotkey_ok.store(true, .release);
        return;
    }
    for (hotkey_fallbacks) |key| {
        if (std.mem.eql(u8, key, wanted)) continue;
        if (registerOne(hk_toggle, key)) {
            hotkey_ok.store(true, .release);
            saveSetting(.{ .hotkey = key });
            return;
        }
    }
}

// ---------------- tray ----------------

const heights = [_]f64{ 0.4, 0.5, 0.6, 0.75, 0.9, 1.0 };
const opacities = [_]f64{ 1.0, 0.9, 0.8, 0.6, 0.4, 0.25 };

const wm_tray = c.WM_APP + 20;
var tray_icon: c.HICON = null;
var tray_added = false;
var wm_taskbar_created: c.UINT = 0;

const menu_toggle = 1;
const menu_dropdown = 2;
const menu_window = 3;
const menu_blur = 4;
const menu_login = 5;
const menu_quit = 6;
const menu_height = 100;
const menu_opacity = 200;

fn trayData() c.NOTIFYICONDATAW {
    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = W.messageWindow();
    nid.uID = 1;
    return nid;
}

fn addTray() void {
    if (tray_icon == null) {
        const png = @embedFile("tray.png");
        tray_icon = c.CreateIconFromResourceEx(@constCast(png.ptr), @intCast(png.len), 1, 0x00030000, 0, 0, c.LR_DEFAULTCOLOR);
    }
    var nid = trayData();
    nid.uFlags = c.NIF_ICON | c.NIF_MESSAGE;
    nid.uCallbackMessage = wm_tray;
    nid.hIcon = tray_icon;
    tray_added = c.Shell_NotifyIconW(c.NIM_ADD, &nid) != 0;
}

/// The tooltip follows the hotkey and the language; the menu itself is built when it opens.
fn buildTrayMenu() void {
    if (!tray_added) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const key = if (hotkey_ok.load(.acquire)) settings.get(a).hotkey else settings.tr("no hotkey", "không có phím tắt");
    const tip = std.fmt.allocPrint(a, "VIBE CODE — {s} {s}", .{ key, settings.tr("to show/hide", "để hiện/ẩn") }) catch return;
    const wtip = core.wide(a, tip) catch return;
    var nid = trayData();
    nid.uFlags = c.NIF_TIP | c.NIF_SHOWTIP;
    const n = @min(wtip.len, nid.szTip.len - 1);
    @memcpy(nid.szTip[0..n], wtip[0..n]);
    _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &nid);
}

fn appendItem(a: std.mem.Allocator, menu: c.HMENU, id: usize, text: []const u8, checked: bool, enabled: bool) void {
    const w = core.wide(a, text) catch return;
    var flags: c.UINT = c.MF_STRING;
    if (checked) flags |= c.MF_CHECKED;
    if (!enabled) flags |= c.MF_GRAYED;
    _ = c.AppendMenuW(menu, flags, id, w.ptr);
}

fn showTrayMenu() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = settings.tr;
    const s = settings.get(a);
    const drop = dropdown();
    const packaged = !core.debug;

    const menu = c.CreatePopupMenu();
    defer _ = c.DestroyMenu(menu);
    const toggle_text = if (hotkey_ok.load(.acquire))
        std.fmt.allocPrint(a, "{s}\t{s}", .{ tr("Show / Hide", "Hiện / Ẩn"), s.hotkey }) catch return
    else
        tr("Show / Hide", "Hiện / Ẩn");
    appendItem(a, menu, menu_toggle, toggle_text, false, true);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    appendItem(a, menu, menu_dropdown, tr("Drop-down (Guake)", "Thả xuống (Guake)"), drop, true);
    appendItem(a, menu, menu_window, tr("Normal window", "Cửa sổ thường"), !drop, true);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    const hm = c.CreatePopupMenu();
    for (heights, 0..) |h, i| {
        const label = std.fmt.allocPrint(a, "{d}%", .{@as(u32, @intFromFloat(@round(h * 100)))}) catch return;
        appendItem(a, hm, menu_height + i, label, @abs(s.dropHeight - h) < 0.01, true);
    }
    _ = c.AppendMenuW(menu, c.MF_POPUP, @intFromPtr(hm), (core.wide(a, tr("Drop-down height", "Chiều cao khi thả xuống")) catch return).ptr);
    const om = c.CreatePopupMenu();
    for (opacities, 0..) |o, i| {
        const label = std.fmt.allocPrint(a, "{d}%", .{@as(u32, @intFromFloat(@round(o * 100)))}) catch return;
        appendItem(a, om, menu_opacity + i, label, @abs(s.dropOpacity - o) < 0.005, true);
    }
    _ = c.AppendMenuW(menu, c.MF_POPUP, @intFromPtr(om), (core.wide(a, tr("Window opacity", "Độ mờ cửa sổ")) catch return).ptr);
    appendItem(a, menu, menu_blur, tr("Hide when focus is lost", "Ẩn khi mất focus"), s.hideOnBlur, true);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    appendItem(a, menu, menu_login, if (packaged)
        tr("Start with Windows", "Khởi động cùng Windows")
    else
        tr("Start with Windows (installed app only)", "Khởi động cùng Windows (chỉ bản cài đặt)"), packaged and (s.openAtLogin orelse true), packaged);
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    appendItem(a, menu, menu_quit, tr("Quit VIBE CODE", "Thoát VIBE CODE"), false, true);

    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    // without this the menu stays open when the user clicks elsewhere
    _ = c.SetForegroundWindow(W.messageWindow());
    const id = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY, pt.x, pt.y, 0, W.messageWindow(), null);
    _ = c.PostMessageW(W.messageWindow(), c.WM_NULL, 0, 0);
    if (id > 0) onMenu(@intCast(id), s.hideOnBlur, s.openAtLogin orelse true);
}

fn onMenu(id: usize, hide_on_blur: bool, open_at_login: bool) void {
    switch (id) {
        menu_toggle => toggle(),
        menu_dropdown => setMode(true),
        menu_window => setMode(false),
        menu_blur => saveSetting(.{ .hideOnBlur = !hide_on_blur }),
        menu_login => {
            saveSetting(.{ .openAtLogin = !open_at_login });
            applyLoginItem();
        },
        menu_quit => return quit(),
        else => if (id >= menu_opacity and id < menu_opacity + opacities.len) {
            saveSetting(.{ .dropOpacity = opacities[id - menu_opacity] });
            applyDropPrefs();
        } else if (id >= menu_height and id < menu_height + heights.len) {
            saveSetting(.{ .dropHeight = heights[id - menu_height] });
            applyDropPrefs();
        },
    }
    buildTrayMenu();
    pushState();
}

// ---------------- start at login ----------------

const run_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const run_name = std.unicode.utf8ToUtf16LeStringLiteral("VIBE CODE");

// `c.HKEY_CURRENT_USER` (0x80000001) is not an aligned pointer and fails to compile: the root
// key goes in as an integer
const HKEY_CURRENT_USER: usize = 0x80000001;
extern "advapi32" fn RegOpenKeyExW(key: usize, sub_key: [*:0]const u16, options: u32, sam: u32, result: *c.HKEY) callconv(.winapi) i32;

/// Register / unregister the sign-in entry. Installed app only: in dev it would point at a debug exe.
fn applyLoginItem() void {
    if (core.debug) return;
    var key: c.HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, run_key, 0, c.KEY_SET_VALUE, &key) != 0) return;
    defer _ = c.RegCloseKey(key);
    if (!prefs().open_at_login) {
        _ = c.RegDeleteValueW(key, run_name);
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const exe = std.process.executablePathAlloc(core.io, a) catch return;
    const cmd = std.fmt.allocPrint(a, "\"{s}\" {s}", .{ exe, hidden_arg }) catch return;
    const w = core.wide(a, cmd) catch return;
    _ = c.RegSetValueExW(key, run_name, 0, c.REG_SZ, @ptrCast(w.ptr), @intCast((w.len + 1) * 2));
}

// ---------------- one running instance ----------------

const instance_name = std.unicode.utf8ToUtf16LeStringLiteral(W.identifier ++ (if (core.debug) ".dev" else "") ++ ".instance");
var instance_mutex: c.HANDLE = null;
var wm_toggle: c.UINT = 0;

/// False when the app is already running: that instance is asked to show its window and this
/// one should leave. Call before anything else.
pub fn singleInstance() bool {
    wm_toggle = c.RegisterWindowMessageW(instance_name);
    instance_mutex = c.CreateMutexW(null, 0, instance_name);
    if (instance_mutex != null and c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        _ = c.AllowSetForegroundWindow(0xFFFFFFFF); // ASFW_ANY
        _ = W.PostMessageW(0xffff, wm_toggle, 0, 0); // HWND_BROADCAST
        return false;
    }
    return true;
}

/// Lets a new copy start while this one is still on its way out (relaunch).
pub fn releaseInstance() void {
    if (instance_mutex != null) _ = c.CloseHandle(instance_mutex);
    instance_mutex = null;
}

// ---------------- messages ----------------

fn hook(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) ?c.LRESULT {
    if (hwnd != W.messageWindow()) return null;
    if (msg == c.WM_HOTKEY) {
        if (wp == hk_toggle) toggle();
        if (wp == hk_capture and @hasDecl(m.capture, "captureStart")) core.spawn(startCapture, .{});
        return 0;
    }
    if (msg == wm_tray) {
        switch (lp & 0xffff) {
            c.WM_LBUTTONUP => toggle(),
            c.WM_LBUTTONDBLCLK => show(),
            c.WM_RBUTTONUP, c.WM_CONTEXTMENU => showTrayMenu(),
            else => {},
        }
        return 0;
    }
    if (msg == wm_toggle and wm_toggle != 0) {
        toggle();
        return 0;
    }
    if (msg == wm_taskbar_created and wm_taskbar_created != 0) {
        // Explorer restarted: the tray is empty again
        addTray();
        buildTrayMenu();
        return 0;
    }
    return null;
}

fn startCapture() void {
    m.capture.captureStart(false) catch {};
}

pub fn quit() void {
    quitting.store(true, .release);
    if (@hasDecl(m.pty, "killAll")) m.pty.killAll();
    host.quit();
}

// ---------------- setup ----------------

/// Creates the main window (UI thread, before the run loop).
pub fn init() !void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const s = settings.get(a);
    const start_hidden = core.hasArg(hidden_arg);
    dropdown_mode.store(std.mem.eql(u8, s.mode, "dropdown"), .release);

    const bg: u32 = if (s.seeThrough) 0x00000000 else if (std.mem.eql(u8, s.theme, "light")) 0xececeeff else 0x2a2a2cff;
    const w = try W.createWindow(.{
        .label = host.main_label,
        .title = "VIBE CODE",
        .width = 1480,
        .height = 920,
        .min_width = 760,
        .min_height = 280,
        .visible = false,
        .transparent = s.seeThrough,
        .background = bg,
        // the page draws its own title bar and window buttons (drop-down mode hides them)
        .decorations = false,
        .shadow = true,
    });
    _ = try W.createWebview(w, .{ .label = host.main_label, .url = try W.appUrl(a, "/"), .background = bg, .file_drop = true, .resize_edges = true });
    w.listener = onEvent;
    main_win = w;

    wm_taskbar_created = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
    W.addHook(hook);
    addTray();
    applyLoginItem();
    registerHotkey();
    buildTrayMenu();

    if (dropdown()) {
        applyDropdown(w, !start_hidden);
    } else {
        setOpacity(w, winOpacity());
        if (!start_hidden) w.show();
    }
}

pub fn deinit() void {
    if (tray_added) {
        var nid = trayData();
        _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
        tray_added = false;
    }
    _ = c.UnregisterHotKey(W.messageWindow(), hk_toggle);
    _ = c.UnregisterHotKey(W.messageWindow(), hk_capture);
}

/// Main window events.
fn onEvent(w: *W.Window, event: W.WindowEvent) bool {
    switch (event) {
        // The close button only tucks the window away: chats keep running and the tray icon
        // brings it back. Quitting for real is "Quit VIBE CODE" in the tray menu.
        .close_requested => {
            if (quitting.load(.acquire)) return false;
            if (dropdown()) hideDropdown() else w.hide();
            return true;
        },
        .resized => if (!animating.load(.acquire)) {
            if (dropdown()) {
                // dragging the bottom edge in drop-down mode changes the remembered height
                if (w.isVisible()) if (targetWorkArea()) |wa| {
                    const ratio = @round(std.math.clamp(@as(f64, @floatFromInt(w.bounds().h)) / @as(f64, @floatFromInt(wa.h)), 0.25, 1.0) * 100.0) / 100.0;
                    if (@abs(ratio - prefs().drop_height) >= 0.01) saveSetting(.{ .dropHeight = ratio });
                };
            } else {
                pushState();
            }
        },
        .blurred => if (dropdown() and prefs().hide_on_blur and !animating.load(.acquire)) {
            // let a click on the tray icon (which also blurs) toggle instead of double-hiding
            core.spawn(blurLater, .{});
        },
        .destroyed => {
            main_win = null;
            host.quit();
        },
        else => {},
    }
    return false;
}

fn blurLater() void {
    core.sleepMs(120);
    host.onUi(struct {
        fn f() void {
            const w = main_win orelse return;
            if (!w.isFocused() and w.isVisible() and !animating.load(.acquire)) slideUp(w);
        }
    }.f, .{});
}

// ---------------- commands ----------------

pub const commands = .{
    .{ "win_state", win_state },
    .{ "win_minimize", win_minimize },
    .{ "win_badge", win_badge },
    .{ "win_toggle_maximize", win_toggle_maximize },
    .{ "win_close", win_close },
    .{ "win_hide", win_hide },
    .{ "win_set_mode", win_set_mode },
};

fn win_state(call: *ipc.Call) !WindowState {
    return windowState(call.arena);
}

fn win_minimize(_: *ipc.Call) !void {
    host.onUi(struct {
        fn f() void {
            if (main_win) |w| w.minimize();
        }
    }.f, .{});
}

fn win_toggle_maximize(_: *ipc.Call) !void {
    host.onUiSync(struct {
        fn f() void {
            const w = main_win orelse return;
            if (w.isMaximized()) w.restore() else w.maximize();
        }
    }.f, .{});
    pushState();
}

fn win_close(_: *ipc.Call) !void {
    host.onUi(struct {
        fn f() void {
            if (main_win) |w| w.close();
        }
    }.f, .{});
}

fn win_hide(_: *ipc.Call) !void {
    host.onUi(hideDropdown, .{});
}

fn win_set_mode(_: *ipc.Call, a: struct { mode: []const u8 }) !void {
    host.onUiSync(setMode, .{std.mem.eql(u8, a.mode, "dropdown")});
}

/// Number on the taskbar icon: a PNG drawn by the page (data: URL), null clears it.
fn win_badge(call: *ipc.Call, a: struct { png: ?[]const u8 = null, label: []const u8 = "" }) !void {
    var bytes: ?[]u8 = null;
    if (a.png) |url| if (std.mem.indexOfScalar(u8, url, ',')) |i| {
        const b64 = url[i + 1 ..];
        const dec = std.base64.standard.Decoder;
        if (dec.calcSizeForSlice(b64)) |n| {
            const buf = try call.arena.alloc(u8, n);
            if (dec.decode(buf, b64)) |_| bytes = buf else |_| {}
        } else |_| {}
    };
    host.onUiSync(setBadge, .{ bytes, try core.wide(call.arena, a.label) });
}

const CLSID_TaskbarList: c.GUID = .{ .Data1 = 0x56FDF344, .Data2 = 0xFD6D, .Data3 = 0x11D0, .Data4 = .{ 0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90 } };
const IID_ITaskbarList3: c.GUID = .{ .Data1 = 0xEA1AFB91, .Data2 = 0x9E28, .Data3 = 0x4B86, .Data4 = .{ 0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF } };
var taskbar: ?*c.ITaskbarList3 = null;

fn setBadge(png: ?[]u8, label: [:0]const u16) void {
    const w = main_win orelse return;
    if (taskbar == null) {
        var raw: ?*anyopaque = null;
        if (c.CoCreateInstance(&CLSID_TaskbarList, null, c.CLSCTX_INPROC_SERVER, &IID_ITaskbarList3, &raw) < 0) return;
        taskbar = @ptrCast(@alignCast(raw));
        _ = W.com.call(taskbar.?, "HrInit", .{});
    }
    const icon: c.HICON = if (png) |b| c.CreateIconFromResourceEx(b.ptr, @intCast(b.len), 1, 0x00030000, 0, 0, c.LR_DEFAULTCOLOR) else null;
    defer if (icon != null) {
        _ = c.DestroyIcon(icon);
    };
    _ = W.com.call(taskbar.?, "SetOverlayIcon", .{ w.hwnd, icon, label.ptr });
}

test "parseHotkey" {
    const t = std.testing;
    try t.expectEqual(Hotkey{ .mods = 0x0001, .vk = 0xC0 }, parseHotkey("Alt+`").?);
    try t.expectEqual(Hotkey{ .mods = 0x0003, .vk = 'Z' }, parseHotkey("Ctrl+Alt+Z").?);
    try t.expectEqual(Hotkey{ .mods = 0x0003, .vk = 0x20 }, parseHotkey("Ctrl+Alt+Space").?);
    try t.expectEqual(Hotkey{ .mods = 0, .vk = 0x7B }, parseHotkey("F12").?);
    try t.expectEqual(Hotkey{ .mods = 0x0006, .vk = 'K' }, parseHotkey("Ctrl+Shift+k").?);
    try t.expect(parseHotkey("Ctrl+Alt") == null);
    try t.expect(parseHotkey("Ctrl+Nope") == null);
}
