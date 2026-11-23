//! The status bar's Sound panel: a 10-band equalizer for the whole machine through Equalizer APO
//! (a system-wide audio filter, installed separately). Equalizer APO reads its config.txt and
//! re-applies it as soon as the file changes, so a change here is heard at once.
//!
//! config.txt is written whole; whatever was there before VIBE CODE first wrote it is kept as
//! config-before-vibecode.txt next to it.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const tr = @import("settings.zig").tr;
const Allocator = std.mem.Allocator;

pub const commands = .{
    .{ "sound_status", sound_status },
    .{ "sound_set", sound_set },
    .{ "sound_open_configurator", sound_open_configurator },
};

/// band centres in Hz, the classic 10-band graphic EQ
const FREQS = [_]u32{ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
const HEADER = "# Written by VIBE CODE (status bar > Sound). Your earlier config: config-before-vibecode.txt";

const State = struct {
    enabled: bool = false,
    preset: []const u8 = "flat",
    /// dB per band, FREQS order
    bands: []const f64 = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

const Status = struct {
    /// Equalizer APO is installed
    installed: bool,
    configDir: ?[]const u8,
    enabled: bool,
    preset: []const u8,
    bands: []const f64,
    freqs: []const u32,
};

// ---------------- Equalizer APO ----------------

extern "advapi32" fn RegGetValueW(key: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
const HKEY_LOCAL_MACHINE: usize = 0x80000002;
const RRF_RT_REG_SZ: u32 = 0x2;
/// read the 64-bit registry view even from a 32-bit build
const RRF_SUBKEY_WOW6464KEY: u32 = 0x00010000;

fn regString(a: Allocator, comptime sub: []const u8, comptime name: []const u8) ?[]u8 {
    var buf: [1024]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(buf));
    const k = std.unicode.utf8ToUtf16LeStringLiteral(sub);
    const n = std.unicode.utf8ToUtf16LeStringLiteral(name);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, k, n, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, null, &buf, &size) != 0) return null;
    const len = std.mem.indexOfScalar(u16, buf[0..@min(buf.len, size / 2)], 0) orelse size / 2;
    if (len == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(a, buf[0..len]) catch null;
}

fn installDir(a: Allocator) ?[]const u8 {
    if (regString(a, "SOFTWARE\\EqualizerAPO", "InstallPath")) |p| if (core.exists(p)) return p;
    const def = "C:\\Program Files\\EqualizerAPO";
    return if (core.exists(def)) def else null;
}

fn configDir(a: Allocator) ?[]const u8 {
    if (regString(a, "SOFTWARE\\EqualizerAPO", "ConfigPath")) |p| if (core.exists(p)) return p;
    const dir = installDir(a) orelse return null;
    const p = std.fs.path.join(a, &.{ dir, "config" }) catch return null;
    return if (core.exists(p)) p else null;
}

/// config.txt for these settings: off is an empty (pass-through) config.
pub fn configText(a: Allocator, s: State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, HEADER ++ "\r\n");
    if (!s.enabled) {
        try out.appendSlice(a, "# equalizer off\r\n");
        return out.items;
    }
    // lower the volume by the biggest boost so boosted bands cannot clip
    var peak: f64 = 0;
    for (s.bands) |g| peak = @max(peak, g);
    try out.print(a, "Preamp: {d:.1} dB\r\nGraphicEQ: ", .{if (peak > 0) -peak else 0});
    for (FREQS, 0..) |f, i| {
        const g = if (i < s.bands.len) std.math.clamp(s.bands[i], -15, 15) else 0;
        try out.print(a, "{s}{d} {d:.1}", .{ if (i == 0) "" else "; ", f, g });
    }
    try out.appendSlice(a, "\r\n");
    return out.items;
}

// ---------------- commands ----------------

fn statePath(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"sound.json"});
}

fn loadState(a: Allocator) State {
    const path = statePath(a) catch return .{};
    const raw = core.readFileAlloc(a, path, 1 << 16) catch return .{};
    const s = core.fromJson(State, a, raw) catch return .{};
    return if (s.bands.len == FREQS.len) s else .{ .enabled = s.enabled, .preset = s.preset };
}

fn status(a: Allocator) Status {
    const s = loadState(a);
    return .{
        .installed = installDir(a) != null,
        .configDir = configDir(a),
        .enabled = s.enabled,
        .preset = s.preset,
        .bands = s.bands,
        .freqs = &FREQS,
    };
}

fn sound_status(c: *ipc.Call) !Status {
    return status(c.arena);
}

fn sound_set(c: *ipc.Call, a: struct { enabled: bool, preset: []const u8, bands: []const f64 }) !Status {
    const ar = c.arena;
    if (a.bands.len != FREQS.len) return c.fail("expected {d} bands", .{FREQS.len});
    const dir = configDir(ar) orelse return c.failMsg(tr("Equalizer APO is not installed", "Chưa cài Equalizer APO"));
    const s: State = .{ .enabled = a.enabled, .preset = a.preset, .bands = a.bands };
    const cfg = try std.fs.path.join(ar, &.{ dir, "config.txt" });

    // keep the user's own config the first time
    const backup = try std.fs.path.join(ar, &.{ dir, "config-before-vibecode.txt" });
    if (core.readFileAlloc(ar, cfg, 4 << 20)) |old| {
        if (!std.mem.startsWith(u8, old, HEADER) and !core.exists(backup))
            core.writeFile(backup, old) catch {};
    } else |_| {}

    core.writeFile(cfg, try configText(ar, s)) catch |e|
        return c.fail("{s} {s}: {s}", .{ tr("Could not write", "Không ghi được"), cfg, @errorName(e) });
    core.writeAtomic(try statePath(ar), try core.toJson(ar, s)) catch {};
    return status(ar);
}

/// Equalizer APO's Configurator, where the speakers / headphones it filters are picked (admin).
fn sound_open_configurator(c: *ipc.Call) !void {
    if (!core.is_windows) return error.Unsupported;
    const w = host.win.c;
    const dir = installDir(c.arena) orelse return c.failMsg(tr("Equalizer APO is not installed", "Chưa cài Equalizer APO"));
    const exe = try std.fs.path.join(c.arena, &.{ dir, "Configurator.exe" });
    var info = std.mem.zeroes(w.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(w.SHELLEXECUTEINFOW);
    info.lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    info.lpFile = (try core.wide(c.arena, exe)).ptr;
    info.nShow = w.SW_SHOWNORMAL;
    if (w.ShellExecuteExW(&info) == 0) {
        const err = w.GetLastError();
        if (err == 1223) return c.failMsg(tr("Admin permission was declined", "Đã từ chối quyền quản trị"));
        return c.fail("{s} (error {d})", .{ tr("Could not open the Configurator", "Không mở được Configurator"), err });
    }
}

test "configText" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on = try configText(a, .{ .enabled = true, .bands = &.{ -8, -6, -4, -2, 0, 0, 1.5, 3, 0, 0 } });
    try std.testing.expect(std.mem.indexOf(u8, on, "Preamp: -3.0 dB\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "GraphicEQ: 31 -8.0; 62 -6.0; 125 -4.0; 250 -2.0; 500 0.0; 1000 0.0; 2000 1.5; 4000 3.0; 8000 0.0; 16000 0.0\r\n") != null);
    const off = try configText(a, .{ .enabled = false });
    try std.testing.expect(std.mem.indexOf(u8, off, "GraphicEQ") == null);
    try std.testing.expect(std.mem.startsWith(u8, off, HEADER));
}
