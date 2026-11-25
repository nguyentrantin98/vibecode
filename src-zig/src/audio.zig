//! The status bar's Sound panel: a 10-band equalizer for the whole machine, through VIBE CODE's own
//! audio processing object (src-zig/apo, built into vibe-eq-apo.dll and embedded here).
//!
//! Installing it is the one admin step (eq_apo.ps1, one UAC prompt): it puts the dll in Windows'
//! audio chain of each speaker / headphones. After that the app only writes the gains to
//! %ProgramData%\VIBE CODE Audio\eq.txt, which the APO picks up within a quarter second.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const tr = @import("settings.zig").tr;
const elevated = @import("elevated.zig");
const Allocator = std.mem.Allocator;

pub const commands = .{
    .{ "sound_status", sound_status },
    .{ "sound_set", sound_set },
    .{ "sound_install", sound_install },
    .{ "sound_remove", sound_remove },
};

const APO_DLL = if (core.is_windows) @embedFile("vibe-eq-apo.dll") else "";
const INSTALL_PS1 = @embedFile("eq_apo.ps1");

/// band centres in Hz (the APO uses the same list, apo/dsp.zig)
const FREQS = [_]u32{ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

const State = struct {
    enabled: bool = false,
    preset: []const u8 = "flat",
    /// dB per band, FREQS order
    bands: []const f64 = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    /// the speakers / headphones the last install put the equalizer on
    devices: []const []const u8 = &.{},
    skipped: []const []const u8 = &.{},
};

const Status = struct {
    /// a connected speaker / headphones can take the equalizer (no effects of its own), or it is
    /// already installed: the status bar hides Sound otherwise
    supported: bool,
    /// the APO is registered with Windows
    installed: bool,
    /// it processed sound in the last few seconds (status.txt is fresh)
    running: bool,
    devices: []const []const u8,
    skipped: []const []const u8,
    enabled: bool,
    preset: []const u8,
    bands: []const f64,
    freqs: []const u32,
};

// ---------------- files ----------------

fn dataDir(a: Allocator) ![]u8 {
    return std.fs.path.join(a, &.{ core.getenv("ProgramData") orelse "C:\\ProgramData", "VIBE CODE Audio" });
}

fn statePath(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"sound.json"});
}

fn loadState(a: Allocator) State {
    const path = statePath(a) catch return .{};
    const raw = core.readFileAlloc(a, path, 1 << 16) catch return .{};
    var s = core.fromJson(State, a, raw) catch return .{};
    if (s.bands.len != FREQS.len) s.bands = (State{}).bands;
    return s;
}

fn saveState(a: Allocator, s: State) void {
    const path = statePath(a) catch return;
    const json = core.toJson(a, s) catch return;
    core.writeAtomic(path, json) catch {};
}

/// eq.txt: "1 -8 -6 …": on/off, then the gains (apo/dsp.zig Settings.parse)
pub fn eqText(a: Allocator, s: State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, if (s.enabled) "1" else "0");
    for (0..FREQS.len) |i| {
        const g = if (i < s.bands.len) std.math.clamp(s.bands[i], -15, 15) else 0;
        try out.print(a, " {d:.1}", .{g});
    }
    try out.appendSlice(a, "\r\n");
    return out.items;
}

fn writeEq(a: Allocator, s: State) !void {
    const path = try std.fs.path.join(a, &.{ try dataDir(a), "eq.txt" });
    try core.writeFile(path, try eqText(a, s));
}

// ---------------- registration ----------------

extern "advapi32" fn RegGetValueW(key: usize, sub_key: [*:0]const u16, value: ?[*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
const HKEY_LOCAL_MACHINE: usize = 0x80000002;
const RRF_RT_REG_SZ: u32 = 0x2;
const RRF_SUBKEY_WOW6464KEY: u32 = 0x00010000;

fn installed() bool {
    if (!core.is_windows) return false;
    var buf: [600]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(buf));
    const key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Classes\\CLSID\\{A1C947FD-C3DA-4823-B683-41C0BA386B75}\\InprocServer32");
    return RegGetValueW(HKEY_LOCAL_MACHINE, key, null, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, null, &buf, &size) == 0;
}

extern "advapi32" fn RegOpenKeyExW(key: usize, sub_key: [*:0]const u16, options: u32, sam: u32, result: *usize) callconv(.winapi) i32;
extern "advapi32" fn RegEnumKeyExW(key: usize, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, time: ?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn RegEnumValueW(key: usize, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, kind: ?*u32, data: ?*anyopaque, data_len: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: usize) callconv(.winapi) i32;
const KEY_READ: u32 = 0x20019;
const KEY_WOW64_64KEY: u32 = 0x0100;
const RRF_RT_REG_DWORD: u32 = 0x10;
const DEVICE_STATE_ACTIVE: u32 = 1;
/// the upper bits of DeviceState are flags of their own
const DEVICE_STATEMASK: u32 = 0xF;

/// True when a connected playback device is one eq_apo.ps1 would install on: it has an
/// FxProperties key without the driver's own effect chain (PKEY_FX_* ,1 ,7 ,13 ,14 ,15) or someone
/// else's post-mix effect (,2). Reading these keys needs no admin.
fn usableDevice() bool {
    if (!core.is_windows) return false;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var render: usize = 0;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Render"), 0, KEY_READ | KEY_WOW64_64KEY, &render) != 0) return false;
    defer _ = RegCloseKey(render);
    const sub = L("\\FxProperties");
    var i: u32 = 0;
    while (true) : (i += 1) {
        // room for "<endpoint guid>\FxProperties" and the terminating 0
        var path: [64 + sub.len + 1]u16 = undefined;
        var len: u32 = 64;
        if (RegEnumKeyExW(render, i, &path, &len, null, null, null, null) != 0) return false;
        path[len] = 0;
        var state: u32 = 0;
        var size: u32 = @sizeOf(u32);
        if (RegGetValueW(render, @ptrCast(&path), L("DeviceState"), RRF_RT_REG_DWORD, null, &state, &size) != 0 or state & DEVICE_STATEMASK != DEVICE_STATE_ACTIVE) continue;
        @memcpy(path[len..][0..sub.len], sub);
        path[len + sub.len] = 0;
        var fx: usize = 0;
        if (RegOpenKeyExW(render, @ptrCast(&path), 0, KEY_READ | KEY_WOW64_64KEY, &fx) != 0) continue;
        defer _ = RegCloseKey(fx);
        if (!hasDriverEffects(fx)) return true;
    }
}

fn hasDriverEffects(fx: usize) bool {
    const prefix = "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},";
    var j: u32 = 0;
    while (true) : (j += 1) {
        var vname: [128]u16 = undefined;
        var vlen: u32 = vname.len;
        var data: [128]u16 = undefined;
        var dlen: u32 = @sizeOf(@TypeOf(data));
        const r = RegEnumValueW(fx, j, &vname, &vlen, null, null, &data, &dlen);
        if (r == ERROR_MORE_DATA) {
            // a long value (not one of the CLSIDs looked at here): enumerate it again by name only
            vlen = vname.len;
            dlen = 0;
            if (RegEnumValueW(fx, j, &vname, &vlen, null, null, null, null) != 0) return false;
        } else if (r != 0) return false;
        const n = lowerAscii(vname[0..vlen]);
        if (!std.mem.startsWith(u8, n.slice(), prefix)) continue;
        const pid = n.slice()[prefix.len..];
        // the post-mix slot already holding this equalizer is fine
        if (std.mem.eql(u8, pid, "2")) {
            const v = lowerAscii(data[0..@min(data.len, dlen / 2)]);
            if (std.mem.eql(u8, std.mem.trimEnd(u8, v.slice(), &.{0}), "{a1c947fd-c3da-4823-b683-41c0ba386b75}")) continue;
        }
        for ([_][]const u8{ "1", "2", "7", "13", "14", "15" }) |id| if (std.mem.eql(u8, pid, id)) return true;
    }
}

const ERROR_MORE_DATA: i32 = 234;

const Ascii = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn slice(s: *const Ascii) []const u8 {
        return s.buf[0..s.len];
    }
};

fn lowerAscii(w: []const u16) Ascii {
    var out: Ascii = .{ .len = @min(w.len, 128) };
    for (w[0..out.len], 0..) |ch, k| out.buf[k] = if (ch < 128) std.ascii.toLower(@intCast(ch)) else '?';
    return out;
}

/// status.txt is rewritten every 2.5 s while the APO has a stream open
fn running(a: Allocator) bool {
    const dir = dataDir(a) catch return false;
    const path = std.fs.path.join(a, &.{ dir, "status.txt" }) catch return false;
    const st = std.Io.Dir.cwd().statFile(core.io, path, .{}) catch return false;
    const now = std.Io.Clock.real.now(core.io);
    const age_ns = now.nanoseconds - st.mtime.nanoseconds;
    return age_ns >= 0 and age_ns < 10 * std.time.ns_per_s;
}

fn status(a: Allocator) Status {
    const s = loadState(a);
    const on = installed();
    return .{
        .supported = on or usableDevice(),
        .installed = on,
        .running = on and running(a),
        .devices = s.devices,
        .skipped = s.skipped,
        .enabled = s.enabled,
        .preset = s.preset,
        .bands = s.bands,
        .freqs = &FREQS,
    };
}

// ---------------- commands ----------------

fn sound_status(c: *ipc.Call) !Status {
    return status(c.arena);
}

fn sound_set(c: *ipc.Call, a: struct { enabled: bool, preset: []const u8, bands: []const f64 }) !Status {
    const ar = c.arena;
    if (a.bands.len != FREQS.len) return c.fail("expected {d} bands", .{FREQS.len});
    var s = loadState(ar);
    s.enabled = a.enabled;
    s.preset = a.preset;
    s.bands = a.bands;
    saveState(ar, s);
    if (installed()) writeEq(ar, s) catch |e|
        return c.fail("{s}: {s}", .{ tr("Could not save the equalizer", "Không lưu được EQ"), @errorName(e) });
    return status(ar);
}

const ScriptResult = struct {
    ok: bool = false,
    devices: []const []const u8 = &.{},
    skipped: []const []const u8 = &.{},
    @"error": ?[]const u8 = null,
};

fn runScript(c: *ipc.Call, action: []const u8) !ScriptResult {
    const ar = c.arena;
    const script = try core.resourceFile(ar, "eq_apo.ps1", INSTALL_PS1);
    const dll = try core.resourceFile(ar, "vibe-eq-apo.dll", APO_DLL);
    const r = try elevated.run(c, ScriptResult, script, try std.fmt.allocPrint(ar, "-Action {s} -Dll \"{s}\"", .{ action, dll }), 120_000);
    if (!r.ok) return c.failMsg(r.@"error" orelse tr("The equalizer step failed", "Bước cài EQ bị lỗi"));
    return r;
}

/// Puts the equalizer in Windows' audio chain (admin), then hands it the saved gains.
fn sound_install(c: *ipc.Call) !Status {
    if (!core.is_windows) return error.Unsupported;
    const ar = c.arena;
    const r = try runScript(c, "install");
    var s = loadState(ar);
    s.devices = r.devices;
    s.skipped = r.skipped;
    saveState(ar, s);
    writeEq(ar, s) catch {};
    return status(ar);
}

/// Takes it out of every device's chain and unregisters it (admin).
fn sound_remove(c: *ipc.Call) !Status {
    if (!core.is_windows) return error.Unsupported;
    const ar = c.arena;
    _ = try runScript(c, "remove");
    var s = loadState(ar);
    s.devices = &.{};
    s.skipped = &.{};
    saveState(ar, s);
    return status(ar);
}

test "eqText" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "1 -8.0 -6.0 -4.0 -2.0 0.0 0.0 1.5 3.0 0.0 0.0\r\n",
        try eqText(a, .{ .enabled = true, .bands = &.{ -8, -6, -4, -2, 0, 0, 1.5, 3, 0, 0 } }),
    );
    try std.testing.expect(std.mem.startsWith(u8, try eqText(a, .{}), "0 0.0"));
}
