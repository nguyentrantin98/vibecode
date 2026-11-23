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
