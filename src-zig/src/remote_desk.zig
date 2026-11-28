//! The phone remote's screen view: a paired phone sees this computer's screen and drives its
//! mouse and keyboard (remote.zig carries the messages; the phone page is src/renderer/src/phone).
//!
//! Each phone asks for the part of the screen it shows (`view`, desktop pixels) at the size it
//! shows it (`pw`×`ph`), so a zoomed-in phone gets sharp text and a zoomed-out one a small picture.
//! Frames carry only what changed since the last one: the picture is cut into 32×32 tiles, and
//! each run of changed rows goes out as one JPEG. A phone acknowledges every frame and at most two
//! are on their way, so a slow network gets fewer frames instead of a backlog.
//!
//! Frame (binary, little endian): u8 1, u8 flags (1: whole picture), u16 0, u32 seq,
//! i32 x, y, u32 w, h (the view), u16 pw, ph, i32 cursor x, y, u16 n, then n × (u16 x, y, w, h,
//! u32 len, JPEG bytes).
//!
//! What it cannot do (Windows keeps them from a normal program): the lock screen, UAC prompts,
//! and input into windows of programs running as administrator.

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;
const c = core.host.win.c;
const com = core.host.win.com;

pub const Opcode = std.http.Server.WebSocket.Opcode;
/// Where a phone's messages go (remote.zig's client queue).
pub const Sink = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, op: Opcode, data: []const u8) void,
};

const Rect = struct { x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 };

const tile = 32;
/// the largest picture a phone gets (pixels on its longer side)
const max_side = 2560;
const min_frame_ms = 66;
const in_flight = 2;

pub const Desk = struct {
    sink: Sink,
    mutex: core.Mutex = .{},
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    view: Rect = .{},
    pw: u32 = 0,
    ph: u32 = 0,
    /// a new view: the next frame is a whole picture
    view_gen: u32 = 0,
    quality: f32 = 0.6,
    sent: u32 = 0,
    acked: u32 = 0,

    /// A `desk.*` message from the phone.
    pub fn handle(d: *Desk, a: Allocator, t: []const u8, msg: std.json.ObjectMap) void {
        if (!core.is_windows) return;
        if (eql(t, "desk.start")) return d.start(a);
        if (eql(t, "desk.stop")) return d.stop();
        if (eql(t, "desk.ack")) {
            d.mutex.lock();
            const seq: u32 = @truncate(@as(u64, @bitCast(int(msg, "seq") orelse return d.mutex.unlock())));
            // only a frame that is on its way (not one of an earlier stream)
            if (seq -% d.acked <= d.sent -% d.acked) d.acked = seq;
            d.cond.signal(core.io);
            d.mutex.unlock();
            return;
        }
        if (eql(t, "desk.view")) {
            const v = Rect{
                .x = @intCast(int(msg, "x") orelse 0),
                .y = @intCast(int(msg, "y") orelse 0),
                .w = @intCast(@max(1, int(msg, "w") orelse 1)),
                .h = @intCast(@max(1, int(msg, "h") orelse 1)),
            };
            const q = num(msg, "q");
            d.setView(clampToScreen(v), @intCast(@max(1, int(msg, "pw") orelse 1)), @intCast(@max(1, int(msg, "ph") orelse 1)), q);
            return;
        }
        const mods = modsOf(msg);
        if (eql(t, "desk.mouse")) {
            const x = num(msg, "x") orelse return;
            const y = num(msg, "y") orelse return;
            const act = str(msg, "a") orelse "click";
            withMods(mods, true);
            mouse(x, y, act);
            withMods(mods, false);
        } else if (eql(t, "desk.wheel")) {
            const x = num(msg, "x") orelse return;
            const y = num(msg, "y") orelse return;
            mouse(x, y, "move");
            wheel(@intFromFloat(num(msg, "dy") orelse 0), @intFromFloat(num(msg, "dx") orelse 0));
        } else if (eql(t, "desk.text")) {
            typeText(a, str(msg, "s") orelse return);
        } else if (eql(t, "desk.key")) {
            const vk = vkOf(str(msg, "k") orelse return) orelse return;
            withMods(mods, true);
            key(vk, true);
            key(vk, false);
            withMods(mods, false);
        }
    }

    fn start(d: *Desk, a: Allocator) void {
        d.sink.send(d.sink.ctx, .text, infoMsg(a) catch return);
        d.mutex.lock();
        defer d.mutex.unlock();
        if (d.running) return;
        d.running = true;
        // frame numbers go on from an earlier stream: its late acknowledgements are ignored
        d.acked = d.sent;
        d.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, loop, .{d}) catch {
            d.running = false;
            return;
        };
    }

    /// Ends the stream (and waits for it): before the client goes away.
    pub fn stop(d: *Desk) void {
        d.mutex.lock();
        d.running = false;
        d.cond.signal(core.io);
        const th = d.thread;
        d.thread = null;
        d.mutex.unlock();
        if (th) |t| t.join();
    }

    fn setView(d: *Desk, v: Rect, pw: u32, ph: u32, q: ?f64) void {
        // never more pixels than the screen has there, nor a huge picture
        var w = @min(pw, v.w);
        var h = @min(ph, v.h);
        const side = @max(w, h);
        if (side > max_side) {
            w = @max(1, w * max_side / side);
            h = @max(1, h * max_side / side);
        }
        d.mutex.lock();
        defer d.mutex.unlock();
        d.view = v;
        d.pw = w;
        d.ph = h;
        if (q) |x| d.quality = @floatCast(std.math.clamp(x, 0.2, 0.95));
        d.view_gen +%= 1;
        d.cond.signal(core.io);
    }

    fn loop(d: *Desk) void {
        _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        defer c.CoUninitialize();
        var enc = Jpeg.init() catch |e| {
            std.log.warn("remote desk: no JPEG encoder: {s}", .{@errorName(e)});
            return;
        };
        defer enc.deinit();
        var prev: ?[]u8 = null;
        defer if (prev) |p| core.gpa.free(p);
        var prev_gen: u32 = 0;
        var prev_cursor: [2]i32 = .{ 0, 0 };
        var last_ms: u64 = 0;
        while (true) {
            d.mutex.lock();
            while (d.running and (d.pw == 0 or d.sent -% d.acked >= in_flight))
                d.cond.waitUncancelable(core.io, &d.mutex.m);
            if (!d.running) return d.mutex.unlock();
            const view = d.view;
            const pw = d.pw;
            const ph = d.ph;
            const gen = d.view_gen;
            const q = d.quality;
            d.mutex.unlock();

            const since = core.monoMs() - last_ms;
            if (since < min_frame_ms) core.sleepMs(min_frame_ms - since);
            last_ms = core.monoMs();

            var arena: std.heap.ArenaAllocator = .init(core.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const px = grabScaled(view, pw, ph) orelse {
                core.sleepMs(500);
                continue;
            };
            var pt: c.POINT = .{};
            _ = c.GetCursorPos(&pt);
            const cursor = [2]i32{ pt.x, pt.y };
            const whole = prev == null or gen != prev_gen or prev.?.len != px.len;
            const bands = changedBands(a, if (whole) null else prev.?, px, pw, ph) catch {
                core.gpa.free(px);
                continue;
            };
            if (bands.len == 0 and std.mem.eql(i32, &cursor, &prev_cursor)) {
                core.gpa.free(px);
                core.sleepMs(80);
                continue;
            }
            const msg = frameMsg(a, &enc, q, d.sent +% 1, whole, view, pw, ph, cursor, px, bands) catch |e| {
                std.log.warn("remote desk: frame: {s}", .{@errorName(e)});
                core.gpa.free(px);
                core.sleepMs(500);
                continue;
            };
            if (prev) |p| core.gpa.free(p);
            prev = px;
            prev_gen = gen;
            prev_cursor = cursor;
            d.mutex.lock();
            d.sent +%= 1;
            d.mutex.unlock();
            d.sink.send(d.sink.ctx, .binary, msg);
        }
    }
};

// ---------------- the screen ----------------

/// The virtual screen (every monitor) and each monitor, for the phone.
fn infoMsg(a: Allocator) ![]const u8 {
    const Mon = struct { x: i32, y: i32, w: u32, h: u32, primary: bool };
    var list: std.ArrayList(Mon) = .empty;
    const Ctx = struct {
        fn each(mon: c.HMONITOR, _: c.HDC, _: [*c]c.RECT, data: c.LPARAM) callconv(.c) c.WINBOOL {
            const l: *std.ArrayList(Mon) = @ptrFromInt(@as(usize, @bitCast(data)));
            var mi: c.MONITORINFO = .{ .cbSize = @sizeOf(c.MONITORINFO) };
            if (c.GetMonitorInfoW(mon, &mi) != 0) l.append(core.gpa, .{
                .x = mi.rcMonitor.left,
                .y = mi.rcMonitor.top,
                .w = @intCast(mi.rcMonitor.right - mi.rcMonitor.left),
                .h = @intCast(mi.rcMonitor.bottom - mi.rcMonitor.top),
                .primary = mi.dwFlags & c.MONITORINFOF_PRIMARY != 0,
            }) catch {};
            return 1;
        }
    };
    defer list.deinit(core.gpa);
    _ = c.EnumDisplayMonitors(null, null, Ctx.each, @bitCast(@intFromPtr(&list)));
    // the primary one first
    std.mem.sort(Mon, list.items, {}, struct {
        fn lt(_: void, l: Mon, r: Mon) bool {
            return l.primary and !r.primary or (l.primary == r.primary and (l.x < r.x or (l.x == r.x and l.y < r.y)));
        }
    }.lt);
    return core.toJson(a, .{ .t = "desk.info", .screens = list.items });
}

fn virtualScreen() Rect {
    return .{
        .x = c.GetSystemMetrics(c.SM_XVIRTUALSCREEN),
        .y = c.GetSystemMetrics(c.SM_YVIRTUALSCREEN),
        .w = @intCast(@max(1, c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN))),
        .h = @intCast(@max(1, c.GetSystemMetrics(c.SM_CYVIRTUALSCREEN))),
    };
}

fn clampToScreen(v: Rect) Rect {
    const s = virtualScreen();
    const x0 = std.math.clamp(v.x, s.x, s.x + @as(i32, @intCast(s.w)) - 1);
    const y0 = std.math.clamp(v.y, s.y, s.y + @as(i32, @intCast(s.h)) - 1);
    const x1 = std.math.clamp(v.x + @as(i32, @intCast(v.w)), x0 + 1, s.x + @as(i32, @intCast(s.w)));
    const y1 = std.math.clamp(v.y + @as(i32, @intCast(v.h)), y0 + 1, s.y + @as(i32, @intCast(s.h)));
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// `view` of the screen scaled to `w`×`h`, as BGRA rows top to bottom (core.gpa), or null.
fn grabScaled(view: Rect, w: u32, h: u32) ?[]u8 {
    const screen = c.GetDC(null) orelse return null;
    defer _ = c.ReleaseDC(null, screen);
    const mem = c.CreateCompatibleDC(screen) orelse return null;
    defer _ = c.DeleteDC(mem);
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader = .{
        .biSize = @sizeOf(c.BITMAPINFOHEADER),
        .biWidth = @intCast(w),
        .biHeight = -@as(i32, @intCast(h)), // top-down
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = c.BI_RGB,
    };
    var bits: ?*anyopaque = null;
    const bmp = c.CreateDIBSection(mem, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    defer _ = c.DeleteObject(bmp);
    const old = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old);
    const ok = if (w == view.w and h == view.h)
        c.BitBlt(mem, 0, 0, @intCast(w), @intCast(h), screen, view.x, view.y, c.SRCCOPY)
    else blk: {
        _ = c.SetStretchBltMode(mem, c.HALFTONE);
        _ = c.SetBrushOrgEx(mem, 0, 0, null);
        break :blk c.StretchBlt(mem, 0, 0, @intCast(w), @intCast(h), screen, view.x, view.y, @intCast(view.w), @intCast(view.h), c.SRCCOPY);
    };
    if (ok == 0) return null;
    _ = c.GdiFlush();
    const len = @as(usize, w) * h * 4;
    const src: [*]const u8 = @ptrCast(bits orelse return null);
    return core.gpa.dupe(u8, src[0..len]) catch null;
}

/// Rows of tiles that changed, each as the rectangle spanning its changed tiles (consecutive rows
/// with overlapping spans merged). Everything when there is no previous picture.
fn changedBands(a: Allocator, prev: ?[]const u8, px: []const u8, w: u32, h: u32) ![]Rect {
    var out: std.ArrayList(Rect) = .empty;
    if (prev == null) {
        try out.append(a, .{ .x = 0, .y = 0, .w = w, .h = h });
        return out.items;
    }
    const cols = (w + tile - 1) / tile;
    const dirty = try a.alloc(bool, cols);
    var ty: u32 = 0;
    while (ty < h) : (ty += tile) {
        const th = @min(tile, h - ty);
        @memset(dirty, false);
        var y = ty;
        while (y < ty + th) : (y += 1) {
            const row = @as(usize, y) * w * 4;
            for (0..cols) |col| {
                if (dirty[col]) continue;
                const x0 = col * tile;
                const x1 = @min(x0 + tile, w);
                if (!std.mem.eql(u8, prev.?[row + x0 * 4 .. row + x1 * 4], px[row + x0 * 4 .. row + x1 * 4])) dirty[col] = true;
            }
        }
        const first = std.mem.indexOfScalar(bool, dirty, true) orelse continue;
        const last = std.mem.lastIndexOfScalar(bool, dirty, true).?;
        const r = Rect{ .x = @intCast(first * tile), .y = @intCast(ty), .w = @intCast(@min((last + 1) * tile, w) - first * tile), .h = th };
        if (out.items.len > 0) {
            const p = &out.items[out.items.len - 1];
            const px1 = p.x + @as(i32, @intCast(p.w));
            const rx1 = r.x + @as(i32, @intCast(r.w));
            if (p.y + @as(i32, @intCast(p.h)) == r.y and r.x < px1 and p.x < rx1) {
                const x0 = @min(p.x, r.x);
                p.* = .{ .x = x0, .y = p.y, .w = @intCast(@max(px1, rx1) - x0), .h = p.h + r.h };
                continue;
            }
        }
        try out.append(a, r);
    }
    return out.items;
}

fn frameMsg(a: Allocator, enc: *Jpeg, q: f32, seq: u32, whole: bool, view: Rect, pw: u32, ph: u32, cursor: [2]i32, px: []const u8, bands: []const Rect) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(&.{ 1, @intFromBool(whole), 0, 0 });
    try w.writeInt(u32, seq, .little);
    try w.writeInt(i32, view.x, .little);
    try w.writeInt(i32, view.y, .little);
    try w.writeInt(u32, view.w, .little);
    try w.writeInt(u32, view.h, .little);
    try w.writeInt(u16, @intCast(pw), .little);
    try w.writeInt(u16, @intCast(ph), .little);
    try w.writeInt(i32, cursor[0], .little);
    try w.writeInt(i32, cursor[1], .little);
    try w.writeInt(u16, @intCast(bands.len), .little);
    for (bands) |b| {
        const jpg = try enc.encode(a, px, pw, b, q);
        try w.writeInt(u16, @intCast(b.x), .little);
        try w.writeInt(u16, @intCast(b.y), .little);
        try w.writeInt(u16, @intCast(b.w), .little);
        try w.writeInt(u16, @intCast(b.h), .little);
        try w.writeInt(u32, @intCast(jpg.len), .little);
        try w.writeAll(jpg);
    }
    return out.written();
}

// ---------------- JPEG (Windows Imaging Component) ----------------

const Jpeg = struct {
    factory: *c.IWICImagingFactory,

    const CLSID_WICImagingFactory: c.GUID = .{ .Data1 = 0xcacaf262, .Data2 = 0x9370, .Data3 = 0x4615, .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
    const IID_IWICImagingFactory: c.GUID = .{ .Data1 = 0xec5ec8a9, .Data2 = 0xc395, .Data3 = 0x4314, .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
    const GUID_ContainerFormatJpeg: c.GUID = .{ .Data1 = 0x19e4a5aa, .Data2 = 0x5662, .Data3 = 0x4fc5, .Data4 = .{ 0xa0, 0xc0, 0x17, 0x58, 0x02, 0x8e, 0x10, 0x57 } };
    const GUID_WICPixelFormat24bppBGR: c.GUID = .{ .Data1 = 0x6fddc324, .Data2 = 0x4e03, .Data3 = 0x4bfe, .Data4 = .{ 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0c } };

    fn init() !Jpeg {
        var f: ?*anyopaque = null;
        try com.check(c.CoCreateInstance(&CLSID_WICImagingFactory, null, c.CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, &f));
        return .{ .factory = @ptrCast(@alignCast(f.?)) };
    }

    fn deinit(j: *Jpeg) void {
        com.release(@as(?*c.IWICImagingFactory, j.factory));
    }

    /// The rectangle `r` of a BGRA picture `stride_px` wide, as a JPEG (in `a`).
    fn encode(j: *Jpeg, a: Allocator, px: []const u8, stride_px: u32, r: Rect, q: f32) ![]u8 {
        const rw: usize = r.w;
        const rh: usize = r.h;
        // BGRA → BGR, the encoder's own format
        const bgr = try a.alloc(u8, rw * rh * 3);
        for (0..rh) |y| {
            const src = px[((@as(usize, @intCast(r.y)) + y) * stride_px + @as(usize, @intCast(r.x))) * 4 ..][0 .. rw * 4];
            const dst = bgr[y * rw * 3 ..][0 .. rw * 3];
            for (0..rw) |x| @memcpy(dst[x * 3 ..][0..3], src[x * 4 ..][0..3]);
        }
        const buf = try a.alloc(u8, rw * rh * 3 + 64 * 1024);

        var stream: [*c]c.IWICStream = null;
        try com.check(com.call(j.factory, "CreateStream", .{&stream}));
        defer com.release(@as(?*c.IWICStream, stream));
        try com.check(com.call(stream, "InitializeFromMemory", .{ buf.ptr, @as(c.DWORD, @intCast(buf.len)) }));
        var encoder: [*c]c.IWICBitmapEncoder = null;
        try com.check(com.call(j.factory, "CreateEncoder", .{ &GUID_ContainerFormatJpeg, null, &encoder }));
        defer com.release(@as(?*c.IWICBitmapEncoder, encoder));
        try com.check(com.call(encoder, "Initialize", .{ @as([*c]c.IStream, @ptrCast(stream)), c.WICBitmapEncoderNoCache }));
        var frame: [*c]c.IWICBitmapFrameEncode = null;
        var props: [*c]c.IPropertyBag2 = null;
        try com.check(com.call(encoder, "CreateNewFrame", .{ &frame, &props }));
        defer com.release(@as(?*c.IWICBitmapFrameEncode, frame));
        defer com.release(@as(?*c.IPropertyBag2, props));
        var name = std.unicode.utf8ToUtf16LeStringLiteral("ImageQuality").*;
        var bag: c.PROPBAG2 = .{ .dwType = c.PROPBAG2_TYPE_DATA, .vt = c.VT_R4, .pstrName = &name };
        var v = std.mem.zeroes(c.VARIANT);
        v.unnamed_0.unnamed_0.vt = c.VT_R4;
        v.unnamed_0.unnamed_0.unnamed_0.fltVal = q;
        _ = com.call(props, "Write", .{ 1, &bag, &v });
        try com.check(com.call(frame, "Initialize", .{props}));
        try com.check(com.call(frame, "SetSize", .{ r.w, r.h }));
        var fmt = GUID_WICPixelFormat24bppBGR;
        try com.check(com.call(frame, "SetPixelFormat", .{&fmt}));
        if (!com.eqlGuid(&fmt, &GUID_WICPixelFormat24bppBGR)) return error.PixelFormat;
        try com.check(com.call(frame, "WritePixels", .{ r.h, @as(c.UINT, @intCast(rw * 3)), @as(c.UINT, @intCast(bgr.len)), bgr.ptr }));
        try com.check(com.call(frame, "Commit", .{}));
        try com.check(com.call(encoder, "Commit", .{}));
        var pos = std.mem.zeroes(c.ULARGE_INTEGER);
        try com.check(com.call(stream, "Seek", .{ std.mem.zeroes(c.LARGE_INTEGER), c.STREAM_SEEK_CUR, &pos }));
        return buf[0..@intCast(pos.QuadPart)];
    }
};

// ---------------- mouse and keyboard ----------------

fn send(inputs: []c.INPUT) void {
    _ = c.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(c.INPUT));
}

fn mouseInput(flags: c.DWORD, data: i32) c.INPUT {
    var in: c.INPUT = .{ .type = c.INPUT_MOUSE };
    in.unnamed_0.mi = .{ .dwFlags = flags, .mouseData = @bitCast(data) };
    return in;
}

/// x, y: desktop pixels. `act`: move, down, up, click, rdown, rup, rclick, mclick.
fn mouse(x: f64, y: f64, act: []const u8) void {
    const s = virtualScreen();
    var move = mouseInput(c.MOUSEEVENTF_MOVE | c.MOUSEEVENTF_ABSOLUTE | c.MOUSEEVENTF_VIRTUALDESK, 0);
    const fx = std.math.clamp((x - @as(f64, @floatFromInt(s.x))) * 65535.0 / @as(f64, @floatFromInt(@max(1, s.w - 1))), 0, 65535);
    const fy = std.math.clamp((y - @as(f64, @floatFromInt(s.y))) * 65535.0 / @as(f64, @floatFromInt(@max(1, s.h - 1))), 0, 65535);
    move.unnamed_0.mi.dx = @intFromFloat(@round(fx));
    move.unnamed_0.mi.dy = @intFromFloat(@round(fy));
    var list: [3]c.INPUT = undefined;
    list[0] = move;
    var n: usize = 1;
    const add = struct {
        fn f(l: *[3]c.INPUT, k: *usize, flags: c.DWORD) void {
            l[k.*] = mouseInput(flags, 0);
            k.* += 1;
        }
    }.f;
    if (eql(act, "down")) add(&list, &n, c.MOUSEEVENTF_LEFTDOWN) //
    else if (eql(act, "up")) add(&list, &n, c.MOUSEEVENTF_LEFTUP) //
    else if (eql(act, "click")) {
        add(&list, &n, c.MOUSEEVENTF_LEFTDOWN);
        add(&list, &n, c.MOUSEEVENTF_LEFTUP);
    } else if (eql(act, "rdown")) add(&list, &n, c.MOUSEEVENTF_RIGHTDOWN) //
    else if (eql(act, "rup")) add(&list, &n, c.MOUSEEVENTF_RIGHTUP) //
    else if (eql(act, "rclick")) {
        add(&list, &n, c.MOUSEEVENTF_RIGHTDOWN);
        add(&list, &n, c.MOUSEEVENTF_RIGHTUP);
    } else if (eql(act, "mclick")) {
        add(&list, &n, c.MOUSEEVENTF_MIDDLEDOWN);
        add(&list, &n, c.MOUSEEVENTF_MIDDLEUP);
    }
    send(list[0..n]);
}

/// Wheel notches ×120 (up / right positive).
fn wheel(dy: i32, dx: i32) void {
    var list: [2]c.INPUT = undefined;
    var n: usize = 0;
    if (dy != 0) {
        list[n] = mouseInput(c.MOUSEEVENTF_WHEEL, dy);
        n += 1;
    }
    if (dx != 0) {
        list[n] = mouseInput(c.MOUSEEVENTF_HWHEEL, dx);
        n += 1;
    }
    send(list[0..n]);
}

fn key(vk: u16, down: bool) void {
    var in: c.INPUT = .{ .type = c.INPUT_KEYBOARD };
    const extended = switch (vk) {
        0x21...0x28, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D => true, // PgUp…Down, Ins, Del, Win, Menu
        else => false,
    };
    in.unnamed_0.ki = .{
        .wVk = vk,
        .wScan = @intCast(c.MapVirtualKeyW(vk, 0)),
        .dwFlags = (if (down) @as(c.DWORD, 0) else @as(c.DWORD, c.KEYEVENTF_KEYUP)) | (if (extended) @as(c.DWORD, c.KEYEVENTF_EXTENDEDKEY) else 0),
    };
    send((&in)[0..1]);
}

/// Text as typed characters (any language: Unicode key events), line breaks as Enter.
fn typeText(a: Allocator, s: []const u8) void {
    const units = std.unicode.utf8ToUtf16LeAlloc(a, s) catch return;
    const list = a.alloc(c.INPUT, units.len * 2) catch return;
    var n: usize = 0;
    for (units) |u| {
        if (u == '\r') continue;
        if (u == '\n') {
            send(list[0..n]);
            n = 0;
            key(0x0D, true);
            key(0x0D, false);
            continue;
        }
        for ([_]bool{ true, false }) |down| {
            list[n] = .{ .type = c.INPUT_KEYBOARD };
            list[n].unnamed_0.ki = .{ .wScan = u, .dwFlags = @as(c.DWORD, c.KEYEVENTF_UNICODE) | (if (down) @as(c.DWORD, 0) else @as(c.DWORD, c.KEYEVENTF_KEYUP)) };
            n += 1;
        }
    }
    send(list[0..n]);
}

const Mods = struct { ctrl: bool = false, alt: bool = false, shift: bool = false, win: bool = false };

fn modsOf(msg: std.json.ObjectMap) Mods {
    var m: Mods = .{};
    const list = msg.get("mods") orelse return m;
    if (list != .array) return m;
    for (list.array.items) |v| if (v == .string) {
        if (eql(v.string, "ctrl")) m.ctrl = true;
        if (eql(v.string, "alt")) m.alt = true;
        if (eql(v.string, "shift")) m.shift = true;
        if (eql(v.string, "win")) m.win = true;
    };
    return m;
}

/// Presses (or releases, in the opposite order) the modifier keys.
fn withMods(m: Mods, down: bool) void {
    const order = [_]struct { on: bool, vk: u16 }{ .{ .on = m.ctrl, .vk = 0x11 }, .{ .on = m.alt, .vk = 0x12 }, .{ .on = m.shift, .vk = 0x10 }, .{ .on = m.win, .vk = 0x5B } };
    if (down) {
        for (order) |o| if (o.on) key(o.vk, true);
    } else {
        var i = order.len;
        while (i > 0) {
            i -= 1;
            if (order[i].on) key(order[i].vk, false);
        }
    }
}

fn vkOf(name: []const u8) ?u16 {
    const named = [_]struct { []const u8, u16 }{
        .{ "Enter", 0x0D },  .{ "Esc", 0x1B },    .{ "Tab", 0x09 },     .{ "Backspace", 0x08 }, .{ "Delete", 0x2E },
        .{ "Left", 0x25 },   .{ "Up", 0x26 },     .{ "Right", 0x27 },   .{ "Down", 0x28 },      .{ "Home", 0x24 },
        .{ "End", 0x23 },    .{ "PageUp", 0x21 }, .{ "PageDown", 0x22 }, .{ "Space", 0x20 },    .{ "Win", 0x5B },
        .{ "Insert", 0x2D }, .{ "Menu", 0x5D },   .{ "PrintScreen", 0x2C },
    };
    for (named) |n| if (eql(n[0], name)) return n[1];
    if (name.len == 1 and std.ascii.isAlphanumeric(name[0])) return std.ascii.toUpper(name[0]);
    if (name.len >= 2 and name.len <= 3 and name[0] == 'F') {
        const f = std.fmt.parseInt(u16, name[1..], 10) catch return null;
        if (f >= 1 and f <= 12) return 0x70 + f - 1;
    }
    return null;
}

// ---------------- JSON helpers ----------------

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn num(o: std.json.ObjectMap, k: []const u8) ?f64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn int(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const f = num(o, k) orelse return null;
    if (!std.math.isFinite(f) or @abs(f) > 1e9) return null;
    return @intFromFloat(@round(f));
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

test "keys" {
    try std.testing.expectEqual(@as(?u16, 0x43), vkOf("c"));
    try std.testing.expectEqual(@as(?u16, 0x7B), vkOf("F12"));
    try std.testing.expectEqual(@as(?u16, 0x0D), vkOf("Enter"));
    try std.testing.expectEqual(@as(?u16, null), vkOf("F13"));
}

test "changed bands" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const w = 100;
    const h = 70;
    const prev = try arena.allocator().alloc(u8, w * h * 4);
    @memset(prev, 0);
    const cur = try arena.allocator().dupe(u8, prev);
    try std.testing.expectEqual(@as(usize, 0), (try changedBands(arena.allocator(), prev, cur, w, h)).len);
    cur[(40 * w + 70) * 4] = 1; // tile row 1, column 2
    cur[(65 * w + 99) * 4] = 1; // tile row 2, column 3 (the narrow last one)
    const b = try changedBands(arena.allocator(), prev, cur, w, h);
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqual(Rect{ .x = 64, .y = 32, .w = 32, .h = 32 }, b[0]);
    try std.testing.expectEqual(Rect{ .x = 96, .y = 64, .w = 4, .h = 6 }, b[1]);
}
