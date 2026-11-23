//! Machine temperature and cooling, for the status bar's temperature meter:
//! - temperature: the ACPI thermal zones through PDH (`\Thermal Zone Information(*)`), no admin;
//! - Windows cooling: the active power plan's "System cooling policy" (fans before slowing the
//!   CPU) and "Processor performance boost mode" (turbo boost off runs far cooler), written to the
//!   user's own plan with powrprof, no admin;
//! - on ASUS laptops the firmware fan profile (Whisper / Standard / Performance) through ASUS WMI,
//!   which needs admin: asus_fan.ps1 runs elevated, one UAC prompt per change.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const tr = @import("settings.zig").tr;
const Allocator = std.mem.Allocator;

pub const commands = .{
    .{ "sys_thermal", sys_thermal },
    .{ "sys_set_cooling", sys_set_cooling },
    .{ "sys_set_fan_profile", sys_set_fan_profile },
};

const ASUS_FAN_PS1 = @embedFile("asus_fan.ps1");

const Zone = struct { name: []const u8, celsius: f64 };

const Thermal = struct {
    /// hottest zone, °C; null when the machine reports none
    celsius: ?f64,
    zones: []const Zone,
    /// the power plan's cooling policy is Active (fans first); null: no readable plan
    activeCooling: ?bool,
    /// CPU turbo boost is off in the power plan
    turboOff: ?bool,
    /// the firmware fan profile can be set (an ASUS laptop)
    asus: bool,
    /// the profile this app last set, and the fan speeds read then
    fanProfile: ?[]const u8,
    /// the CPU fan was last set to full speed by this app
    fanFull: bool,
    cpuFanRpm: ?u32,
    gpuFanRpm: ?u32,
};

fn sys_thermal(c: *ipc.Call) !?Thermal {
    if (!core.is_windows) return null;
    const a = c.arena;
    const zones = readZones(a) catch &.{};
    var hottest: ?f64 = null;
    for (zones) |z| hottest = if (hottest) |h| @max(h, z.celsius) else z.celsius;
    const st = loadState(a);
    return .{
        .celsius = hottest,
        .zones = zones,
        .activeCooling = if (readPlan(SYSCOOLPOL)) |v| v == 1 else null,
        .turboOff = if (readPlan(PERFBOOSTMODE)) |v| v == 0 else null,
        .asus = isAsus(),
        .fanProfile = st.fanProfile,
        .fanFull = st.fanFull,
        .cpuFanRpm = st.cpuFanRpm,
        .gpuFanRpm = st.gpuFanRpm,
    };
}

// ---------------- temperature (PDH) ----------------

const w = if (core.is_windows) host.win.c else struct {};

var pdh_mutex: core.Mutex = .{};
var pdh_query: ?*anyopaque = null;
var pdh_counter: ?*anyopaque = null;
/// the counter reads tenths of a kelvin ("High Precision Temperature") rather than kelvins
var pdh_tenths = true;
var pdh_failed = false;

fn openCounter() bool {
    if (pdh_counter != null) return true;
    if (pdh_failed) return false;
    var q: w.PDH_HQUERY = null;
    if (w.PdhOpenQueryW(null, 0, &q) != 0) {
        pdh_failed = true;
        return false;
    }
    var ctr: w.PDH_HCOUNTER = null;
    const precise = std.unicode.utf8ToUtf16LeStringLiteral("\\Thermal Zone Information(*)\\High Precision Temperature");
    const plain = std.unicode.utf8ToUtf16LeStringLiteral("\\Thermal Zone Information(*)\\Temperature");
    if (w.PdhAddEnglishCounterW(q, precise, 0, &ctr) != 0) {
        pdh_tenths = false;
        if (w.PdhAddEnglishCounterW(q, plain, 0, &ctr) != 0) {
            _ = w.PdhCloseQuery(q);
            pdh_failed = true;
            return false;
        }
    }
    pdh_query = q;
    pdh_counter = ctr;
    return true;
}

fn readZones(a: Allocator) ![]const Zone {
    pdh_mutex.lock();
    defer pdh_mutex.unlock();
    if (!openCounter()) return &.{};
    if (w.PdhCollectQueryData(pdh_query) != 0) return &.{};
    const Item = w.PDH_FMT_COUNTERVALUE_ITEM_W;
    var size: w.DWORD = 0;
    var count: w.DWORD = 0;
    const more: u32 = 0x800007D2; // PDH_MORE_DATA
    const first: u32 = @bitCast(w.PdhGetFormattedCounterArrayW(pdh_counter, w.PDH_FMT_DOUBLE, &size, &count, null));
    if (first != more or size == 0) return &.{};
    const buf = try a.alignedAlloc(u8, .of(Item), size);
    const items: [*]Item = @ptrCast(buf.ptr);
    if (w.PdhGetFormattedCounterArrayW(pdh_counter, w.PDH_FMT_DOUBLE, &size, &count, items) != 0) return &.{};
    var out: std.ArrayList(Zone) = .empty;
    for (items[0..count]) |it| {
        if (it.FmtValue.CStatus != 0) continue;
        const raw = it.FmtValue.unnamed_0.doubleValue;
        const kelvin = if (pdh_tenths) raw / 10 else raw;
        const celsius = kelvin - 273.15;
        // a zone that is not wired up reads 0 K or nonsense
        if (celsius < 1 or celsius > 125) continue;
        const name = core.fromWide(a, it.szName) catch "";
        try out.append(a, .{ .name = name, .celsius = @round(celsius * 10) / 10 });
    }
    return out.items;
}

// ---------------- power plan (powrprof) ----------------

const Guid = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };

const SUB_PROCESSOR: Guid = .{ .d1 = 0x54533251, .d2 = 0x82be, .d3 = 0x4824, .d4 = .{ 0x96, 0xc1, 0x47, 0xb6, 0x0b, 0x74, 0x0d, 0x00 } };
/// 1 Active (raise the fans before slowing the CPU), 0 Passive
const SYSCOOLPOL: Guid = .{ .d1 = 0x94d3a615, .d2 = 0xa899, .d3 = 0x4ac5, .d4 = .{ 0xae, 0x2b, 0xe4, 0xd8, 0xf6, 0x34, 0x36, 0x7f } };
/// 0 Disabled (no turbo), 2 Aggressive (Windows' default)
const PERFBOOSTMODE: Guid = .{ .d1 = 0xbe337238, .d2 = 0x0d82, .d3 = 0x4146, .d4 = .{ 0xa9, 0x60, 0x4f, 0x37, 0x49, 0xd4, 0x70, 0xc7 } };

extern "powrprof" fn PowerGetActiveScheme(root: ?*anyopaque, scheme: *?*Guid) callconv(.winapi) u32;
extern "powrprof" fn PowerSetActiveScheme(root: ?*anyopaque, scheme: *const Guid) callconv(.winapi) u32;
extern "powrprof" fn PowerReadACValueIndex(root: ?*anyopaque, scheme: *const Guid, sub: *const Guid, setting: *const Guid, value: *u32) callconv(.winapi) u32;
extern "powrprof" fn PowerReadDCValueIndex(root: ?*anyopaque, scheme: *const Guid, sub: *const Guid, setting: *const Guid, value: *u32) callconv(.winapi) u32;
extern "powrprof" fn PowerWriteACValueIndex(root: ?*anyopaque, scheme: *const Guid, sub: *const Guid, setting: *const Guid, value: u32) callconv(.winapi) u32;
extern "powrprof" fn PowerWriteDCValueIndex(root: ?*anyopaque, scheme: *const Guid, sub: *const Guid, setting: *const Guid, value: u32) callconv(.winapi) u32;
extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

fn activeScheme() ?*Guid {
    var g: ?*Guid = null;
    if (PowerGetActiveScheme(null, &g) != 0) return null;
    return g;
}

/// The active plan's value for this setting, on the power source in use.
fn readPlan(setting: Guid) ?u32 {
    const scheme = activeScheme() orelse return null;
    defer _ = LocalFree(scheme);
    var v: u32 = 0;
    const err = if (onBattery())
        PowerReadDCValueIndex(null, scheme, &SUB_PROCESSOR, &setting, &v)
    else
        PowerReadACValueIndex(null, scheme, &SUB_PROCESSOR, &setting, &v);
    if (err != 0) return null;
    return v;
}

/// Writes it for both plugged in and on battery, then re-applies the plan so it takes effect.
fn writePlan(setting: Guid, value: u32) u32 {
    const scheme = activeScheme() orelse return 1;
    defer _ = LocalFree(scheme);
    var err = PowerWriteACValueIndex(null, scheme, &SUB_PROCESSOR, &setting, value);
    if (err == 0) err = PowerWriteDCValueIndex(null, scheme, &SUB_PROCESSOR, &setting, value);
    if (err == 0) err = PowerSetActiveScheme(null, scheme);
    return err;
}

fn onBattery() bool {
    var s = std.mem.zeroes(w.SYSTEM_POWER_STATUS);
    if (w.GetSystemPowerStatus(&s) == 0) return false;
    return s.ACLineStatus == 0;
}

fn sys_set_cooling(c: *ipc.Call, a: struct { activeCooling: ?bool = null, turboOff: ?bool = null }) !?Thermal {
    if (!core.is_windows) return error.Unsupported;
    if (a.activeCooling) |on| {
        const err = writePlan(SYSCOOLPOL, if (on) 1 else 0);
        if (err != 0) return c.fail("{s} (error {d})", .{ tr("Could not change the power plan", "Không đổi được chế độ nguồn"), err });
    }
    if (a.turboOff) |off| {
        const err = writePlan(PERFBOOSTMODE, if (off) 0 else 2);
        if (err != 0) return c.fail("{s} (error {d})", .{ tr("Could not change the power plan", "Không đổi được chế độ nguồn"), err });
    }
    return sys_thermal(c);
}

// ---------------- ASUS fan profile ----------------

extern "advapi32" fn RegGetValueW(key: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
const HKEY_LOCAL_MACHINE: usize = 0x80000002;
const RRF_RT_REG_SZ: u32 = 0x2;

fn isAsus() bool {
    var buf: [128]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(buf));
    const key = std.unicode.utf8ToUtf16LeStringLiteral("HARDWARE\\DESCRIPTION\\System\\BIOS");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("SystemManufacturer");
    if (RegGetValueW(HKEY_LOCAL_MACHINE, key, name, RRF_RT_REG_SZ, null, &buf, &size) != 0) return false;
    const len = @min(buf.len, size / 2);
    var ascii: [128]u8 = undefined;
    for (buf[0..len], 0..) |ch, i| ascii[i] = if (ch < 128) std.ascii.toLower(@intCast(ch)) else '?';
    return std.mem.indexOf(u8, ascii[0..len], "asus") != null;
}

const FanState = struct {
    fanProfile: ?[]const u8 = null,
    fanFull: bool = false,
    cpuFanRpm: ?u32 = null,
    gpuFanRpm: ?u32 = null,
};

fn statePath(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"cooling.json"});
}

fn loadState(a: Allocator) FanState {
    const path = statePath(a) catch return .{};
    const raw = core.readFileAlloc(a, path, 1 << 16) catch return .{};
    return core.fromJson(FanState, a, raw) catch .{};
}

const ScriptResult = struct {
    ok: bool = false,
    profile: ?[]const u8 = null,
    cpuFanRpm: ?u32 = null,
    gpuFanRpm: ?u32 = null,
    @"error": ?[]const u8 = null,
};

var fan_counter: std.atomic.Value(u32) = .init(0);

fn sys_set_fan_profile(c: *ipc.Call, a: struct { profile: []const u8 }) !?Thermal {
    if (!core.is_windows) return error.Unsupported;
    const ar = c.arena;
    const valid = [_][]const u8{ "silent", "standard", "performance", "full", "auto" };
    for (valid) |v| {
        if (std.mem.eql(u8, v, a.profile)) break;
    } else return c.fail("unknown fan profile {s}", .{a.profile});

    const script = try core.resourceFile(ar, "asus_fan.ps1", ASUS_FAN_PS1);
    const out = try std.fmt.allocPrint(ar, "{s}\\vibe-fan-{d}-{d}.json", .{ core.tempDir(), w.GetCurrentProcessId(), fan_counter.fetchAdd(1, .monotonic) });
    const params = try std.fmt.allocPrint(ar, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{s}\" -Profile {s} -Out \"{s}\"", .{ script, a.profile, out });

    var info = std.mem.zeroes(w.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(w.SHELLEXECUTEINFOW);
    info.fMask = w.SEE_MASK_NOCLOSEPROCESS | w.SEE_MASK_NOASYNC;
    info.lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    info.lpFile = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
    info.lpParameters = (try core.wide(ar, params)).ptr;
    info.nShow = w.SW_HIDE;
    if (w.ShellExecuteExW(&info) == 0) {
        const err = w.GetLastError();
        if (err == 1223) return c.failMsg(tr("Admin permission was declined", "Đã từ chối quyền quản trị"));
        return c.fail("{s} (error {d})", .{ tr("Could not start PowerShell", "Không chạy được PowerShell"), err });
    }
    if (info.hProcess) |p| {
        defer _ = w.CloseHandle(p);
        if (w.WaitForSingleObject(p, 60_000) != 0) return c.failMsg(tr("The fan change took too long", "Đổi chế độ quạt quá lâu"));
    }
    defer std.Io.Dir.cwd().deleteFile(core.io, out) catch {};
    const raw = core.readFileAlloc(ar, out, 1 << 16) catch return c.failMsg(tr("The fan change gave no answer", "Không nhận được kết quả đổi quạt"));
    const body = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
    const r = core.fromJson(ScriptResult, ar, body) catch return c.failMsg(tr("The fan change gave no answer", "Không nhận được kết quả đổi quạt"));
    if (!r.ok) return c.failMsg(r.@"error" orelse tr("Could not change the fan profile", "Không đổi được chế độ quạt"));

    const prev = loadState(ar);
    const speed = std.mem.eql(u8, a.profile, "full") or std.mem.eql(u8, a.profile, "auto");
    const st: FanState = .{
        .fanProfile = r.profile orelse if (speed) prev.fanProfile else a.profile,
        .fanFull = if (speed) std.mem.eql(u8, a.profile, "full") else prev.fanFull,
        .cpuFanRpm = r.cpuFanRpm,
        .gpuFanRpm = r.gpuFanRpm,
    };
    core.writeAtomic(try statePath(ar), try core.toJson(ar, st)) catch {};
    return sys_thermal(c);
}

test "reads this machine's temperature and power plan" {
    if (!core.is_windows) return;
    core.io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const zones = try readZones(arena.allocator());
    for (zones) |z| try std.testing.expect(z.celsius > 0 and z.celsius < 125);
    if (readPlan(SYSCOOLPOL)) |v| try std.testing.expect(v <= 1);
    _ = readPlan(PERFBOOSTMODE);
    _ = isAsus();
}
