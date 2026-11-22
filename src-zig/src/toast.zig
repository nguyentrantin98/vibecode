//! Pop-up cards at the bottom-right of the screen (new Zalo tasks): a small transparent window
//! that never takes focus, made on demand and gone with its last card.
//!
//! The page is a single HTML file served at `<origin>/__toast`.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const settings = @import("settings.zig");
const m = @import("modules.zig");

const W = host.win;
const c = W.c;

const label = "toast";
const width: f64 = 300.0;
const margin: f64 = 8.0;
const page = @embedFile("toast.html");

pub const ToastTag = struct {
    text: []const u8,
    color: []const u8,
};

pub const ToastCard = struct {
    id: []const u8,
    avatar: ?[]const u8 = null,
    /// initials fallback
    name: []const u8,
    title: []const u8,
    body: []const u8,
    /// small line under the body, e.g. group name
    meta: ?[]const u8 = null,
    /// chip before the body: "Việc mới", "Đang xử lý", "Hoàn thành"
    tag: ?ToastTag = null,
};

var mutex: core.Mutex = .{};
/// cards (as JSON) waiting for the page to load; owned by `core.gpa`
var pending: std.ArrayList([]u8) = .empty;
/// UI thread only
var ready = false;

pub fn init() void {
    host.addRoute("/__toast", route);
}

fn route(a: std.mem.Allocator, _: []const u8, _: []const u8) ?host.Response {
    const body = std.mem.replaceOwned(u8, a, page, "__CLOSE__", settings.tr("Close", "Đóng")) catch return null;
    return .{ .body = body };
}

/// Show these cards (the window is made on demand). From any thread; the cards are copied.
pub fn show(cards: []const ToastCard) void {
    if (cards.len == 0) return;
    mutex.lock();
    for (cards) |card| {
        const json = core.toJson(core.gpa, card) catch continue;
        pending.append(core.gpa, json) catch core.gpa.free(json);
    }
    mutex.unlock();
    host.onUi(pump, .{});
}

fn pump() void {
    if (W.findWebview(label)) |v| {
        if (ready) flush(v);
        return;
    }
    create() catch {
        mutex.lock();
        defer mutex.unlock();
        for (pending.items) |j| core.gpa.free(j);
        pending.clearRetainingCapacity();
    };
}

fn create() !void {
    const w = try W.createWindow(.{
        .label = label,
        .title = "VIBE CODE",
        .width = width,
        .height = 10,
        .visible = false,
        .decorations = false,
        .transparent = true,
        .resizable = false,
        .skip_taskbar = true,
        .always_on_top = true,
        .shadow = false,
        // never takes focus from what the user is doing
        .popup = true,
        .background = 0x00000000,
    });
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const url = try W.appUrl(fba.allocator(), "/__toast");
    _ = try W.createWebview(w, .{ .label = label, .url = url, .background = 0x00000000, .on_ready = onReady });
}

fn onReady(v: *W.Webview, _: ?*anyopaque) void {
    const view = v.view orelse return;
    W.com.on(view, "NavigationCompleted", c.ICoreWebView2NavigationCompletedEventHandler, &c.IID_ICoreWebView2NavigationCompletedEventHandler, v, onLoaded);
}

fn onLoaded(v: *W.Webview, _: [*c]c.ICoreWebView2, _: [*c]c.ICoreWebView2NavigationCompletedEventArgs) c.HRESULT {
    if (v.closed) return W.com.S_OK;
    ready = true;
    flush(v);
    return W.com.S_OK;
}

fn flush(v: *W.Webview) void {
    mutex.lock();
    var list = pending;
    pending = .empty;
    mutex.unlock();
    defer list.deinit(core.gpa);
    for (list.items) |json| {
        defer core.gpa.free(json);
        const js = std.mem.concat(core.gpa, u8, &.{ "push(", json, ")" }) catch continue;
        defer core.gpa.free(js);
        v.eval(js);
    }
}

/// Bottom-right of the primary screen's work area, `h` CSS pixels tall.
fn place(w: *W.Window, h: f64) void {
    const mon = c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY);
    var mi = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(mon, &mi) == 0) return;
    var dx: c.UINT = 96;
    var dy: c.UINT = 96;
    _ = c.GetDpiForMonitor(mon, c.MDT_EFFECTIVE_DPI, &dx, &dy);
    const scale = @as(f64, @floatFromInt(dx)) / 96.0;
    const area = mi.rcWork;
    const pw: i32 = @intFromFloat(@round(width * scale));
    const pm: i32 = @intFromFloat(@round(margin * scale));
    const max_h = (area.bottom - area.top) - @as(i32, @intFromFloat(margin * 2.0 * scale));
    const ph = @max(1, @min(@as(i32, @intFromFloat(@round(h * scale))), max_h));
    w.setBounds(.{ .x = area.right - pw - pm, .y = area.bottom - ph - pm, .w = pw, .h = ph });
}

pub const commands = .{
    .{ "toast_click", toast_click },
    .{ "toast_close", toast_close },
};

/// A card was clicked: bring the app up on the task list.
fn toast_click(_: *ipc.Call, _: struct { id: ?[]const u8 = null }) !void {
    if (@hasDecl(m.windowing, "show")) m.windowing.show();
    core.emit("zalo:showTasks", .{});
}

/// The page's stack changed to `height` CSS px; 0 = the last card is gone, so the window goes.
fn toast_close(_: *ipc.Call, a: struct { height: ?f64 = null }) !void {
    host.onUi(resize, .{a.height orelse 0});
}

fn resize(height: f64) void {
    const w = W.findWindow(label) orelse return;
    if (height > 0) {
        place(w, height);
        if (!w.isVisible()) w.showInactive();
        return;
    }
    mutex.lock();
    const none_waiting = pending.items.len == 0;
    mutex.unlock();
    if (none_waiting) {
        ready = false;
        w.destroy();
    }
}
