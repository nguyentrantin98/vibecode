//! Screen capture: grabs the monitor under the mouse (the title-bar button hides the app first, the
//! hotkey grabs the screen as it is, app included), and shows it in a frameless
//! full-screen window where you pick a region and mark it up (boxes, arrows, pen, text, numbered
//! steps, mosaic…). The result goes to the clipboard and, by default, into the active chat.
//!
//! Like the Zalo toast, the editor page is a single HTML file, served at `<origin>/__capture`.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const dialog = @import("dialog.zig");
const png = @import("png.zig");
const settings = @import("settings.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;

const W = host.win;
const c = W.c;
const tr = settings.tr;

const label = "capture";
/// Global shortcut that starts a capture.
pub const hotkey = "Ctrl+Alt+Z";
const page = @embedFile("capture.html");

/// The grabbed screen as the page gets it: width and height (u32 LE), then RGBA pixels.
var frame: ?[]u8 = null;
var frame_mutex: core.Mutex = .{};
/// The app window was on screen before the capture, so it comes back after.
var was_visible: std.atomic.Value(bool) = .init(false);
/// one capture at a time, from the moment it is asked for
var busy: std.atomic.Value(bool) = .init(false);

pub fn init() void {
    host.addRoute("/__capture", route);
}

fn route(a: Allocator, _: []const u8, _: []const u8) ?host.Response {
    const body = std.mem.replaceOwned(u8, a, page, "__LANG__", tr("en", "vi")) catch return null;
    return .{ .body = body };
}

pub const commands = .{
    .{ "capture_start", capture_start },
    .{ "capture_frame", capture_frame },
    .{ "capture_ready", capture_ready },
    .{ "capture_cancel", capture_cancel },
    .{ "capture_done", capture_done },
};

fn capture_start(call: *ipc.Call, a: struct { hide: bool = false }) !void {
    captureStart(a.hide) catch |e| switch (e) {
        error.NoMonitor => return call.failMsg(tr("no monitor", "không tìm thấy màn hình")),
        error.GrabFailed => return call.failMsg(tr("could not capture the screen", "không chụp được màn hình")),
        else => return call.fail("{s}", .{@errorName(e)}),
    };
}

/// Grab the screen and open the editor over it. `hide`: take the app off the screen first (the
/// title-bar button); the hotkey keeps it, so what is on screen, VIBE CODE included, is grabbed.
/// Call from a worker thread.
pub fn captureStart(hide: bool) !void {
    if (busy.swap(true, .acq_rel)) return;
    errdefer busy.store(false, .release);

    const visible = host.onUiSync(mainVisible, .{});
    was_visible.store(visible, .release);
    if (visible and hide) {
        host.onUiSync(hideMain, .{});
        // let the window actually leave the screen before it is grabbed
        core.sleepMs(220);
    }
    errdefer restore(false);

    // the monitor under the mouse
    var pt: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.GetCursorPos(&pt);
    var mi = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTOPRIMARY), &mi) == 0) return error.NoMonitor;
    const r = mi.rcMonitor;
    const rect: host.Rect = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
    const w: u32 = @intCast(rect.w);
    const h: u32 = @intCast(rect.h);

    const bgra = grab(core.gpa, rect.x, rect.y, w, h) orelse return error.GrabFailed;
    defer core.gpa.free(bgra);
    const buf = try core.gpa.alloc(u8, 8 + bgra.len);
    std.mem.writeInt(u32, buf[0..4], w, .little);
    std.mem.writeInt(u32, buf[4..8], h, .little);
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) {
        buf[8 + i] = bgra[i + 2];
        buf[8 + i + 1] = bgra[i + 1];
        buf[8 + i + 2] = bgra[i];
        buf[8 + i + 3] = 255;
    }
    setFrame(buf);
    errdefer setFrame(null);

    try host.onUiSync(openEditor, .{rect});
}

fn setFrame(buf: ?[]u8) void {
    frame_mutex.lock();
    defer frame_mutex.unlock();
    if (frame) |old| core.gpa.free(old);
    frame = buf;
}

fn mainVisible() bool {
    const w = W.findWindow(host.main_label) orelse return false;
    return w.isVisible() and !w.isMinimized();
}

fn hideMain() void {
    if (W.findWindow(host.main_label)) |w| w.hide();
}

fn openEditor(rect: host.Rect) !void {
    const w = try W.createWindow(.{
        .label = label,
        .title = tr("VIBE CODE capture", "VIBE CODE chụp màn hình"),
        .visible = false,
        .decorations = false,
        .resizable = false,
        .skip_taskbar = true,
        .always_on_top = true,
        .shadow = false,
        .background = 0x000000ff,
    });
    w.setBounds(rect);
    var buf: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const url = try W.appUrl(fba.allocator(), "/__capture");
    _ = try W.createWebview(w, .{ .label = label, .url = url, .background = 0x000000ff });
}

/// The page asks for the grabbed screen: 8 bytes (width, height as u32 LE) then RGBA pixels.
fn capture_frame(call: *ipc.Call) !ipc.Bytes {
    frame_mutex.lock();
    defer frame_mutex.unlock();
    return .{ .bytes = if (frame) |f| try call.arena.dupe(u8, f) else "" };
}

/// The page has drawn the screen: show it (no flash of an empty window).
fn capture_ready(_: *ipc.Call) !void {
    host.onUi(struct {
        fn f() void {
            const w = W.findWindow(label) orelse return;
            w.show();
            w.focus();
        }
    }.f, .{});
}

/// Esc / ✕: close without keeping anything.
fn capture_cancel(_: *ipc.Call) !void {
    close();
    restore(false);
}

/// The finished picture (PNG body). `x-action`: "chat" (clipboard + active chat), "copy"
/// (clipboard only) or "save" (a file you pick).
fn capture_done(call: *ipc.Call, body: ipc.Raw) !void {
    const a = call.arena;
    const action = call.header("x-action") orelse "chat";
    close();
    if (std.mem.eql(u8, action, "save")) {
        defer restore(false);
        var st: c.SYSTEMTIME = undefined;
        c.GetLocalTime(&st);
        const name = try std.fmt.allocPrint(a, "{s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}{d:0>2}{d:0>2}.png", .{ tr("Screenshot", "Ảnh chụp màn hình"), st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond });
        const picked = dialog.saveFile(a, .{ .default_name = name, .filters = &.{.{ .name = tr("PNG image", "Ảnh PNG"), .extensions = &.{"png"} }} }) catch null;
        if (picked) |path| try core.writeFile(path, body.bytes);
        return;
    }
    copyPng(a, body.bytes) catch {};
    if (std.mem.eql(u8, action, "chat")) {
        const path = try std.fs.path.join(a, &.{ core.tempDir(), "tinjs-paste", try std.fmt.allocPrint(a, "capture-{d}.png", .{core.nowMs()}) });
        try core.writeFile(path, body.bytes);
        restore(true);
        core.emit("capture:done", .{path});
    } else {
        restore(false);
    }
}

fn close() void {
    setFrame(null);
    host.onUiSync(struct {
        fn f() void {
            if (W.findWindow(label)) |w| w.destroy();
        }
    }.f, .{});
    busy.store(false, .release);
}

/// Bring the app back if it was up before the capture (or `force` it up).
fn restore(force: bool) void {
    if ((force or was_visible.load(.acquire)) and @hasDecl(m.windowing, "show")) m.windowing.show();
}

/// PNG → CF_DIB on the clipboard, so it pastes into any app.
fn copyPng(a: Allocator, bytes: []const u8) !void {
    const img = try png.decode(a, bytes);
    // top-down BGRA
    var i: usize = 0;
    while (i < img.rgba.len) : (i += 4) {
        std.mem.swap(u8, &img.rgba[i], &img.rgba[i + 2]);
        img.rgba[i + 3] = 255;
    }
    try setClipboardDib(img.width, img.height, img.rgba);
}

/// The screen rectangle as BGRA pixels, rows top to bottom (allocated in `a`), or null.
pub fn grab(a: Allocator, x: i32, y: i32, w: u32, h: u32) ?[]u8 {
    if (!core.is_windows or w == 0 or h == 0) return null;
    const px = a.alloc(u8, @as(usize, w) * h * 4) catch return null;
    const screen = c.GetDC(null);
    const mem = c.CreateCompatibleDC(screen);
    const bmp = c.CreateCompatibleBitmap(screen, @intCast(w), @intCast(h));
    const old = c.SelectObject(mem, bmp);
    const ok = c.BitBlt(mem, 0, 0, @intCast(w), @intCast(h), screen, x, y, c.SRCCOPY | c.CAPTUREBLT) != 0;
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader = .{
        .biSize = @sizeOf(c.BITMAPINFOHEADER),
        .biWidth = @intCast(w),
        .biHeight = -@as(i32, @intCast(h)), // top-down
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = c.BI_RGB,
    };
    const lines = if (ok) c.GetDIBits(mem, bmp, 0, h, px.ptr, &info, c.DIB_RGB_COLORS) else 0;
    _ = c.SelectObject(mem, old);
    _ = c.DeleteObject(bmp);
    _ = c.DeleteDC(mem);
    _ = c.ReleaseDC(null, screen);
    if (lines == 0) {
        a.free(px);
        return null;
    }
    var i: usize = 3;
    while (i < px.len) : (i += 4) px[i] = 255;
    return px;
}

fn setClipboardDib(w: u32, h: u32, bgra: []const u8) !void {
    if (!core.is_windows) return error.Unsupported;
    var header = std.mem.zeroes(c.BITMAPINFOHEADER);
    header.biSize = @sizeOf(c.BITMAPINFOHEADER);
    header.biWidth = @intCast(w);
    header.biHeight = @intCast(h); // CF_DIB readers expect bottom-up
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = c.BI_RGB;
    header.biSizeImage = w * h * 4;
    const hsize = @sizeOf(c.BITMAPINFOHEADER);
    const row = @as(usize, w) * 4;

    // the clipboard owns the block once it is set
    const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, hsize + bgra.len) orelse return error.OutOfMemory;
    const dst: [*]u8 = @ptrCast(c.GlobalLock(mem) orelse {
        _ = c.GlobalFree(mem);
        return error.OutOfMemory;
    });
    @memcpy(dst[0..hsize], std.mem.asBytes(&header));
    var y: usize = 0;
    while (y < h) : (y += 1) @memcpy(dst[hsize + y * row ..][0..row], bgra[(h - 1 - y) * row ..][0..row]);
    _ = c.GlobalUnlock(mem);
    if (c.OpenClipboard(null) == 0) {
        _ = c.GlobalFree(mem);
        return error.ClipboardBusy;
    }
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    if (c.SetClipboardData(c.CF_DIB, mem) == null) {
        _ = c.GlobalFree(mem);
        return error.ClipboardBusy;
    }
}

test "grab the screen" {
    if (!core.is_windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // a session without a desktop (CI) has nothing to grab
    const px = grab(a, 0, 0, 16, 8) orelse return error.SkipZigTest;
    defer a.free(px);
    try std.testing.expectEqual(@as(usize, 16 * 8 * 4), px.len);
    try std.testing.expectEqual(@as(u8, 255), px[3]);
}
