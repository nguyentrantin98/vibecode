//! `zig build apo-check`: loads vibe-eq-apo.dll the way the audio engine does (DllGetClassObject →
//! IClassFactory → IAudioProcessingObject…), feeds it sine waves and checks what comes out.
//! Uses a scratch eq.txt in %ProgramData%\VIBE CODE Audio and restores the old one after.

const std = @import("std");
const WINAPI = std.builtin.CallingConvention.winapi;
const HRESULT = i32;

const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
fn g(d1: u32, d2: u16, d3: u16, d4: [8]u8) GUID {
    return .{ .d1 = d1, .d2 = d2, .d3 = d3, .d4 = d4 };
}
const CLSID = g(0xa1c947fd, 0xc3da, 0x4823, .{ 0xb6, 0x83, 0x41, 0xc0, 0xba, 0x38, 0x6b, 0x75 });
const IID_IClassFactory = g(1, 0, 0, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });
const IID_APO = g(0xfd7f2b29, 0x24d0, 0x4b5c, .{ 0xb1, 0x77, 0x59, 0x2c, 0x39, 0xf9, 0xca, 0x10 });
const IID_RT = g(0x9e1d6a6d, 0xddbc, 0x4e95, .{ 0xa4, 0xc7, 0xad, 0x64, 0xba, 0x37, 0x84, 0x6c });
const IID_CFG = g(0x0e5ed805, 0xaba6, 0x49c3, .{ 0x8f, 0x9a, 0x2b, 0x8c, 0x88, 0x9c, 0x4f, 0xa8 });
const IID_SFX = g(0x5fa00f27, 0xadd6, 0x499a, .{ 0x8a, 0x9d, 0x6b, 0x98, 0x52, 0x1f, 0xa7, 0x5b });
const FLOAT = g(3, 0, 0x10, .{ 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 });

const Unk = struct {
    const Vt = extern struct {
        QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
        Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    };
};
fn vtbl(comptime T: type, p: *anyopaque) *const T {
    const pp: *const *const T = @ptrCast(@alignCast(p));
    return pp.*;
}
const QI = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT;
const UL = *const fn (*anyopaque) callconv(WINAPI) u32;
const CfVt = extern struct { qi: QI, ar: UL, rl: UL, CreateInstance: *const fn (*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT, Lock: *const anyopaque };
const ApoVt = extern struct { qi: QI, ar: UL, rl: UL, Reset: *const anyopaque, GetLatency: *const anyopaque, GetReg: *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT, Initialize: *const fn (*anyopaque, u32, ?[*]const u8) callconv(WINAPI) HRESULT, IsIn: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT };
const Prop = extern struct { pBuffer: usize, frames: u32, flags: u32, sig: u32 };
const Desc = extern struct { Type: u32, pBuffer: usize, max: u32, fmt: ?*anyopaque, sig: u32 };
const RtVt = extern struct { qi: QI, ar: UL, rl: UL, Process: *const fn (*anyopaque, u32, [*]const *Prop, u32, [*]const *Prop) callconv(WINAPI) void };
const CfgVt = extern struct { qi: QI, ar: UL, rl: UL, Lock: *const fn (*anyopaque, u32, [*]const *Desc, u32, [*]const *Desc) callconv(WINAPI) HRESULT, Unlock: *const fn (*anyopaque) callconv(WINAPI) HRESULT };

// a minimal IAudioMediaType: float32 stereo 48 kHz
const Fmt = extern struct { guid: GUID, spf: u32, bpc: u32, vbps: u32, fps: f32, mask: u32 };
const MediaType = extern struct {
    vt: *const MtVt,
    const MtVt = extern struct { qi: QI, ar: UL, rl: UL, IsCompressed: *const fn (*anyopaque, *i32) callconv(WINAPI) HRESULT, IsEqual: *const fn (*anyopaque, *anyopaque, *u32) callconv(WINAPI) HRESULT, GetAudioFormat: *const fn (*anyopaque) callconv(WINAPI) ?*anyopaque, GetUncompressed: *const fn (*anyopaque, *Fmt) callconv(WINAPI) HRESULT };
    fn qi(_: *anyopaque, _: *const GUID, o: *?*anyopaque) callconv(WINAPI) HRESULT {
        o.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn one(_: *anyopaque) callconv(WINAPI) u32 {
        return 1;
    }
    fn comp(_: *anyopaque, c: *i32) callconv(WINAPI) HRESULT {
        c.* = 0;
        return 0;
    }
    fn eq(_: *anyopaque, _: *anyopaque, f: *u32) callconv(WINAPI) HRESULT {
        f.* = 0xF;
        return 0;
    }
    fn wf(_: *anyopaque) callconv(WINAPI) ?*anyopaque {
        return null;
    }
    fn unc(_: *anyopaque, f: *Fmt) callconv(WINAPI) HRESULT {
        f.* = .{ .guid = FLOAT, .spf = 2, .bpc = 4, .vbps = 32, .fps = 48000, .mask = 3 };
        return 0;
    }
    const vt_ = MtVt{ .qi = qi, .ar = one, .rl = one, .IsCompressed = comp, .IsEqual = eq, .GetAudioFormat = wf, .GetUncompressed = unc };
};

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(m: ?*anyopaque, name: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn Sleep(ms: u32) callconv(WINAPI) void;

fn check(ok: bool, what: []const u8) !void {
    std.debug.print("{s} {s}\n", .{ if (ok) "ok  " else "FAIL", what });
    if (!ok) return error.CheckFailed;
}

fn levelDb(buf: []const f32, ch: usize) f64 {
    var peak: f64 = 0;
    var i: usize = buf.len / 2 + ch;
    while (i < buf.len) : (i += 2) peak = @max(peak, @abs(@as(f64, buf[i])));
    return 20 * std.math.log10(peak);
}

/// Runs a 1-second stereo sine of `freq` Hz through the APO in 480-frame buffers.
fn run(rt: *anyopaque, freq: f64) !f64 {
    const frames = 480;
    var all: [48000 * 2]f32 = undefined;
    var t: usize = 0;
    while (t < 48000) : (t += frames) {
        var buf: [frames * 2]f32 align(16) = undefined;
        for (0..frames) |i| {
            const s: f32 = @floatCast(0.5 * @sin(2 * std.math.pi * freq * @as(f64, @floatFromInt(t + i)) / 48000));
            buf[2 * i] = s;
            buf[2 * i + 1] = s;
        }
        var p: Prop = .{ .pBuffer = @intFromPtr(&buf), .frames = frames, .flags = 1, .sig = 0 };
        const pp = [_]*Prop{&p};
        vtbl(RtVt, rt).Process(rt, 1, &pp, 1, &pp);
        @memcpy(all[t * 2 .. (t + frames) * 2], &buf);
    }
    return levelDb(&all, 0) - 20 * std.math.log10(0.5);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next();
    const dll = args.next() orelse return error.Usage;

    const pd = init.environ_map.get("ProgramData") orelse "C:\\ProgramData";
    const dir = try std.fs.path.join(a, &.{ pd, "VIBE CODE Audio" });
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const eq = try std.fs.path.join(a, &.{ dir, "eq.txt" });
    const saved: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, eq, a, .limited(4096)) catch null;
    defer if (saved) |s| (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = eq, .data = s }) catch {}) else (std.Io.Dir.cwd().deleteFile(io, eq) catch {});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = eq, .data = "1 -9 -7 -5 -3 -1 0 0 0 0 0\r\n" });

    const m = LoadLibraryW(try std.unicode.wtf8ToWtf16LeAllocZ(a, dll));
    try check(m != null, "LoadLibrary");
    const gco: *const fn (*const GUID, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT = @ptrCast(GetProcAddress(m, "DllGetClassObject") orelse return error.NoExport);
    try check(GetProcAddress(m, "DllCanUnloadNow") != null, "exports DllGetClassObject, DllCanUnloadNow");

    var cf: ?*anyopaque = null;
    try check(gco(&CLSID, &IID_IClassFactory, &cf) == 0 and cf != null, "class factory");
    var apo: ?*anyopaque = null;
    try check(vtbl(CfVt, cf.?).CreateInstance(cf.?, null, &IID_APO, &apo) == 0, "CreateInstance(IAudioProcessingObject)");
    const ap = apo.?;

    var reg: ?*anyopaque = null;
    try check(vtbl(ApoVt, ap).GetReg(ap, &reg) == 0 and reg != null, "GetRegistrationProperties");
    const init_data = [_]u8{ 20, 0, 0, 0 } ++ @as([16]u8, @splat(0));
    try check(vtbl(ApoVt, ap).Initialize(ap, init_data.len, &init_data) == 0, "Initialize");

    var mt: MediaType = .{ .vt = &MediaType.vt_ };
    var sup: ?*anyopaque = null;
    try check(vtbl(ApoVt, ap).IsIn(ap, null, &mt, &sup) == 0 and sup == @as(?*anyopaque, &mt), "accepts float32 stereo 48 kHz");

    var rt: ?*anyopaque = null;
    var cfg: ?*anyopaque = null;
    var sfx: ?*anyopaque = null;
    try check(vtbl(ApoVt, ap).qi(ap, &IID_RT, &rt) == 0, "QueryInterface RT");
    try check(vtbl(ApoVt, ap).qi(ap, &IID_CFG, &cfg) == 0, "QueryInterface Configuration");
    try check(vtbl(ApoVt, ap).qi(ap, &IID_SFX, &sfx) == 0, "QueryInterface IAudioSystemEffects");

    var desc: Desc = .{ .Type = 0, .pBuffer = 0, .max = 480, .fmt = &mt, .sig = 0 };
    const dd = [_]*Desc{&desc};
    try check(vtbl(CfgVt, cfg.?).Lock(cfg.?, 1, &dd, 1, &dd) == 0, "LockForProcess");

    const bass = try run(rt.?, 40);
    const mid = try run(rt.?, 3000);
    std.debug.print("     less bass: 40 Hz {d:.1} dB, 3 kHz {d:.1} dB\n", .{ bass, mid });
    try check(bass < -6 and @abs(mid) < 0.6, "bass cut, mids untouched");

    // the watcher thread picks up a new eq.txt within a second
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = eq, .data = "0 -9 -7 -5 -3 -1 0 0 0 0 0\r\n" });
    Sleep(1200);
    const off = try run(rt.?, 40);
    std.debug.print("     off: 40 Hz {d:.1} dB\n", .{off});
    try check(@abs(off) < 0.1, "turning it off in eq.txt passes audio through");

    _ = vtbl(CfgVt, cfg.?).Unlock(cfg.?);
    for ([_]?*anyopaque{ rt, cfg, sfx }) |p| _ = vtbl(CfgVt, p.?).rl(p.?);
    try check(vtbl(ApoVt, ap).rl(ap) == 0, "last Release frees it (watcher thread stopped)");

    try aggregated(cf.?);
}

/// The audio engine aggregates APOs: an outer object owns the APO's non-delegating IUnknown and
/// hands out its interfaces. Every AddRef / Release on them must land on the outer object.
const Outer = struct {
    vt: *const Unk.Vt = &vt_,
    refs: i32 = 1,
    inner: ?*anyopaque = null,
    const vt_: Unk.Vt = .{ .QueryInterface = qi, .AddRef = ar, .Release = rl };
    fn self(p: *anyopaque) *Outer {
        return @ptrCast(@alignCast(p));
    }
    fn qi(p: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
        const o = self(p);
        if (std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&IID_Unknown))) {
            out.* = p;
            o.refs += 1;
            return 0;
        }
        return vtbl(Unk.Vt, o.inner.?).QueryInterface(o.inner.?, iid, out);
    }
    fn ar(p: *anyopaque) callconv(WINAPI) u32 {
        self(p).refs += 1;
        return @intCast(self(p).refs);
    }
    fn rl(p: *anyopaque) callconv(WINAPI) u32 {
        self(p).refs -= 1;
        return @intCast(@max(0, self(p).refs));
    }
};
const IID_Unknown = g(0, 0, 0, .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 });

fn aggregated(cf: *anyopaque) !void {
    var outer: Outer = .{};
    var inner: ?*anyopaque = null;
    try check(vtbl(CfVt, cf).CreateInstance(cf, &outer, &IID_Unknown, &inner) == 0 and inner != null, "aggregated CreateInstance");
    outer.inner = inner;
    try check(vtbl(CfVt, cf).CreateInstance(cf, &outer, &IID_APO, &inner) != 0, "aggregation asks for IUnknown only");
    // the usual pattern: get an interface from the inner object, then drop the reference that
    // put on the outer one
    var apo: ?*anyopaque = null;
    try check(vtbl(Unk.Vt, outer.inner.?).QueryInterface(outer.inner.?, &IID_APO, &apo) == 0, "inner QueryInterface(IAudioProcessingObject)");
    try check(outer.refs == 2, "that AddRef went to the outer object");
    _ = Outer.rl(&outer);
    var rt: ?*anyopaque = null;
    try check(vtbl(ApoVt, apo.?).qi(apo.?, &IID_RT, &rt) == 0, "QueryInterface through an interface goes via the outer object");
    try check(outer.refs == 2, "and counts on it");
    _ = vtbl(ApoVt, rt.?).rl(rt.?);
    try check(outer.refs == 1, "Release through an interface goes to the outer object");
    try check(vtbl(Unk.Vt, outer.inner.?).Release(outer.inner.?) == 0, "releasing the inner IUnknown frees it");
}
