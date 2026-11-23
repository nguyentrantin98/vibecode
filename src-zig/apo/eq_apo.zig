//! vibe-eq-apo.dll: VIBE CODE's equalizer as a Windows audio processing object (APO). It is
//! appended to a speaker's endpoint-effect chain (the CompositeFX list in the endpoint's
//! FxProperties), so the audio engine runs it after the driver's own effects on everything the
//! device plays.
//!
//! audiodg.exe loads it. It reads the gains from %ProgramData%\VIBE CODE Audio\eq.txt (written by
//! the app, see src/audio.zig) on a watcher thread and swaps them into the real-time path without
//! locks, and writes status.txt there every few seconds so the app can tell it is running.
//! Built without safety checks: a panic would take the machine's sound down with it.

const std = @import("std");
const dsp = @import("dsp.zig");

const GUID = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
    fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

fn guid(comptime s: []const u8) GUID {
    @setEvalBranchQuota(10000);
    const hex = struct {
        fn n(comptime t: []const u8) comptime_int {
            return std.fmt.parseInt(u64, t, 16) catch unreachable;
        }
    }.n;
    var d4: [8]u8 = undefined;
    d4[0] = hex(s[19..21]);
    d4[1] = hex(s[21..23]);
    for (0..6) |i| d4[2 + i] = hex(s[24 + 2 * i .. 26 + 2 * i]);
    return .{ .d1 = hex(s[0..8]), .d2 = hex(s[9..13]), .d3 = hex(s[14..18]), .d4 = d4 };
}

pub const CLSID_VIBE_EQ = guid("a1c947fd-c3da-4823-b683-41c0ba386b75");
const IID_IUnknown = guid("00000000-0000-0000-c000-000000000046");
const IID_IClassFactory = guid("00000001-0000-0000-c000-000000000046");
const IID_IAudioProcessingObject = guid("fd7f2b29-24d0-4b5c-b177-592c39f9ca10");
const IID_IAudioProcessingObjectRT = guid("9e1d6a6d-ddbc-4e95-a4c7-ad64ba37846c");
const IID_IAudioProcessingObjectConfiguration = guid("0e5ed805-aba6-49c3-8f9a-2b8c889c4fa8");
const IID_IAudioSystemEffects = guid("5fa00f27-add6-499a-8a9d-6b98521fa75b");
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = guid("00000003-0000-0010-8000-00aa00389b71");

const HRESULT = i32;
const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
const CLASS_E_NOAGGREGATION: HRESULT = @bitCast(@as(u32, 0x80040110));
const CLASS_E_CLASSNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040111));
const APOERR_FORMAT_NOT_SUPPORTED: HRESULT = @bitCast(@as(u32, 0x887D0003));

const WINAPI = std.builtin.CallingConvention.winapi;

// ---------------- Win32 ----------------

extern "kernel32" fn GetProcessHeap() callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn HeapAlloc(heap: ?*anyopaque, flags: u32, size: usize) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn HeapFree(heap: ?*anyopaque, flags: u32, mem: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CreateThread(attrs: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(WINAPI) u32, param: ?*anyopaque, flags: u32, id: ?*u32) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(WINAPI) u32;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: i32, initial: i32, name: ?[*:0]const u16) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn SetEvent(h: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, template: ?*anyopaque) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn ReadFile(h: ?*anyopaque, buf: [*]u8, n: u32, read: ?*u32, ov: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: [*]const u8, n: u32, written: ?*u32, ov: ?*anyopaque) callconv(WINAPI) i32;
extern "kernel32" fn GetFileTime(h: ?*anyopaque, created: ?*u64, accessed: ?*u64, written: ?*u64) callconv(WINAPI) i32;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(WINAPI) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
extern "kernel32" fn GetTickCount64() callconv(WINAPI) u64;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *?*anyopaque) callconv(WINAPI) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *?*anyopaque) callconv(WINAPI) void;
extern "ole32" fn CoTaskMemAlloc(size: usize) callconv(WINAPI) ?*anyopaque;

const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

fn alloc(comptime T: type) ?*T {
    const p = HeapAlloc(GetProcessHeap(), 0x8, @sizeOf(T)) orelse return null; // HEAP_ZERO_MEMORY
    return @ptrCast(@alignCast(p));
}

// ---------------- COM layouts ----------------

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
};
const IUnknown = extern struct { vt: *const IUnknownVtbl };

const UNCOMPRESSEDAUDIOFORMAT = extern struct {
    guidFormatType: GUID,
    dwSamplesPerFrame: u32,
    dwBytesPerSampleContainer: u32,
    dwValidBitsPerSample: u32,
    fFramesPerSecond: f32,
    dwChannelMask: u32,
};

const IAudioMediaTypeVtbl = extern struct {
    base: IUnknownVtbl,
    IsCompressedFormat: *const fn (*IAudioMediaType, *i32) callconv(WINAPI) HRESULT,
    IsEqual: *const fn (*IAudioMediaType, *IAudioMediaType, *u32) callconv(WINAPI) HRESULT,
    GetAudioFormat: *const fn (*IAudioMediaType) callconv(WINAPI) ?*const anyopaque,
    GetUncompressedAudioFormat: *const fn (*IAudioMediaType, *UNCOMPRESSEDAUDIOFORMAT) callconv(WINAPI) HRESULT,
};
const IAudioMediaType = extern struct { vt: *const IAudioMediaTypeVtbl };

const APO_CONNECTION_PROPERTY = extern struct {
    pBuffer: usize,
    u32ValidFrameCount: u32,
    u32BufferFlags: u32,
    u32Signature: u32,
};
const BUFFER_VALID: u32 = 1;
const BUFFER_SILENT: u32 = 2;

const APO_CONNECTION_DESCRIPTOR = extern struct {
    Type: u32,
    pBuffer: usize,
    u32MaxFrameCount: u32,
    pFormat: ?*IAudioMediaType,
    u32Signature: u32,
};

const APO_REG_PROPERTIES = extern struct {
    clsid: GUID,
    Flags: u32,
    szFriendlyName: [256]u16,
    szCopyrightInfo: [256]u16,
    u32MajorVersion: u32,
    u32MinorVersion: u32,
    u32MinInputConnections: u32,
    u32MaxInputConnections: u32,
    u32MinOutputConnections: u32,
    u32MaxOutputConnections: u32,
    u32MaxInstances: u32,
    u32NumAPOInterfaces: u32,
    iidAPOInterfaceList: [1]GUID,
};
/// in place, and the engine keeps channels, rate and sample size the same on both sides
const APO_FLAGS: u32 = 0xF;

const ApoVtbl = extern struct {
    base: IUnknownVtbl,
    Reset: *const fn (*anyopaque) callconv(WINAPI) HRESULT,
    GetLatency: *const fn (*anyopaque, ?*i64) callconv(WINAPI) HRESULT,
    GetRegistrationProperties: *const fn (*anyopaque, ?*?*APO_REG_PROPERTIES) callconv(WINAPI) HRESULT,
    Initialize: *const fn (*anyopaque, u32, ?[*]const u8) callconv(WINAPI) HRESULT,
    IsInputFormatSupported: *const fn (*anyopaque, ?*IAudioMediaType, ?*IAudioMediaType, ?*?*IAudioMediaType) callconv(WINAPI) HRESULT,
    IsOutputFormatSupported: *const fn (*anyopaque, ?*IAudioMediaType, ?*IAudioMediaType, ?*?*IAudioMediaType) callconv(WINAPI) HRESULT,
    GetInputChannelCount: *const fn (*anyopaque, ?*u32) callconv(WINAPI) HRESULT,
};
const RtVtbl = extern struct {
    base: IUnknownVtbl,
    APOProcess: *const fn (*anyopaque, u32, ?[*]*APO_CONNECTION_PROPERTY, u32, ?[*]*APO_CONNECTION_PROPERTY) callconv(WINAPI) void,
    CalcInputFrames: *const fn (*anyopaque, u32) callconv(WINAPI) u32,
    CalcOutputFrames: *const fn (*anyopaque, u32) callconv(WINAPI) u32,
};
const CfgVtbl = extern struct {
    base: IUnknownVtbl,
    LockForProcess: *const fn (*anyopaque, u32, ?[*]*APO_CONNECTION_DESCRIPTOR, u32, ?[*]*APO_CONNECTION_DESCRIPTOR) callconv(WINAPI) HRESULT,
    UnlockForProcess: *const fn (*anyopaque) callconv(WINAPI) HRESULT,
};

// ---------------- the object ----------------

var live_objects: std.atomic.Value(u32) = .init(0);

/// One APO instance. Supports COM aggregation (the engine may aggregate it): `outer` gets every
/// IUnknown call of the interfaces; `nd` is the real (non-delegating) IUnknown.
const Apo = struct {
    nd: *const IUnknownVtbl = &nd_vtbl,
    apo: *const ApoVtbl = &apo_vtbl,
    rt: *const RtVtbl = &rt_vtbl,
    cfg: *const CfgVtbl = &cfg_vtbl,
    sfx: *const IUnknownVtbl = &sfx_vtbl,
    refs: std.atomic.Value(u32) = .init(1),
    outer: *IUnknown = undefined,

    channels: u32 = 0,
    rate: std.atomic.Value(u32) = .init(0),
    locked: bool = false,

    /// double buffer: the watcher fills the slot not in use, then flips `active`
    coefs: [2]dsp.Coefs = .{ .{}, .{} },
    active: std.atomic.Value(u32) = .init(0),
    write_lock: ?*anyopaque = null,
    settings: dsp.Settings = .{},
    state: dsp.State = .{},
    frames_done: std.atomic.Value(u64) = .init(0),

    thread: ?*anyopaque = null,
    stop: ?*anyopaque = null,

    fn fromField(comptime field: []const u8, p: *anyopaque) *Apo {
        const fp: *@FieldType(Apo, field) = @ptrCast(@alignCast(p));
        return @fieldParentPtr(field, fp);
    }

    /// Recomputes the coefficients (for new settings, or the current ones at a new rate) into the
    /// spare slot, then flips to it.
    fn publish(self: *Apo, settings: ?dsp.Settings) void {
        AcquireSRWLockExclusive(&self.write_lock);
        defer ReleaseSRWLockExclusive(&self.write_lock);
        if (settings) |s| self.settings = s;
        const next = 1 - self.active.load(.acquire);
        self.coefs[next] = dsp.Coefs.compute(self.settings, @floatFromInt(self.rate.load(.acquire)));
        self.active.store(next, .release);
    }
};

fn ndQueryInterface(p: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self = Apo.fromField("nd", p);
    out.* = if (iid.eql(&IID_IUnknown))
        @ptrCast(&self.nd)
    else if (iid.eql(&IID_IAudioProcessingObject))
        @ptrCast(&self.apo)
    else if (iid.eql(&IID_IAudioProcessingObjectRT))
        @ptrCast(&self.rt)
    else if (iid.eql(&IID_IAudioProcessingObjectConfiguration))
        @ptrCast(&self.cfg)
    else if (iid.eql(&IID_IAudioSystemEffects))
        @ptrCast(&self.sfx)
    else
        null;
    const got = out.* orelse return E_NOINTERFACE;
    // AddRef through the interface handed out: its IUnknown goes to the outer object when this one
    // is aggregated (the audio engine aggregates APOs). Counting it here instead would let the outer
    // object's own Release free it while the engine still uses it.
    const unk: *IUnknown = @ptrCast(@alignCast(got));
    _ = unk.vt.AddRef(unk);
    return S_OK;
}
fn ndAddRef(p: *anyopaque) callconv(WINAPI) u32 {
    return Apo.fromField("nd", p).refs.fetchAdd(1, .monotonic) + 1;
}
fn ndRelease(p: *anyopaque) callconv(WINAPI) u32 {
    const self = Apo.fromField("nd", p);
    const left = self.refs.fetchSub(1, .acq_rel) - 1;
    if (left == 0) destroy(self);
    return left;
}
const nd_vtbl: IUnknownVtbl = .{ .QueryInterface = ndQueryInterface, .AddRef = ndAddRef, .Release = ndRelease };

/// IUnknown of the interface in field `field`: passes everything to the outer object.
fn Delegating(comptime field: []const u8) IUnknownVtbl {
    return .{
        .QueryInterface = struct {
            fn f(p: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
                const o = Apo.fromField(field, p).outer;
                return o.vt.QueryInterface(o, iid, out);
            }
        }.f,
        .AddRef = struct {
            fn f(p: *anyopaque) callconv(WINAPI) u32 {
                const o = Apo.fromField(field, p).outer;
                return o.vt.AddRef(o);
            }
        }.f,
        .Release = struct {
            fn f(p: *anyopaque) callconv(WINAPI) u32 {
                const o = Apo.fromField(field, p).outer;
                return o.vt.Release(o);
            }
        }.f,
    };
}

const sfx_vtbl: IUnknownVtbl = Delegating("sfx");

// ---- IAudioProcessingObject ----

fn apoReset(_: *anyopaque) callconv(WINAPI) HRESULT {
    return S_OK;
}
fn apoGetLatency(_: *anyopaque, t: ?*i64) callconv(WINAPI) HRESULT {
    const out = t orelse return E_POINTER;
    out.* = 0;
    return S_OK;
}
fn apoGetRegistrationProperties(_: *anyopaque, out: ?*?*APO_REG_PROPERTIES) callconv(WINAPI) HRESULT {
    const pp = out orelse return E_POINTER;
    const raw = CoTaskMemAlloc(@sizeOf(APO_REG_PROPERTIES)) orelse return E_OUTOFMEMORY;
    const r: *APO_REG_PROPERTIES = @ptrCast(@alignCast(raw));
    r.* = std.mem.zeroes(APO_REG_PROPERTIES);
    r.clsid = CLSID_VIBE_EQ;
    r.Flags = APO_FLAGS;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("VIBE CODE EQ");
    const copy = std.unicode.utf8ToUtf16LeStringLiteral("VIBE CODE");
    @memcpy(r.szFriendlyName[0..name.len], name);
    @memcpy(r.szCopyrightInfo[0..copy.len], copy);
    r.u32MajorVersion = 1;
    r.u32MinorVersion = 0;
    r.u32MinInputConnections = 1;
    r.u32MaxInputConnections = 1;
    r.u32MinOutputConnections = 1;
    r.u32MaxOutputConnections = 1;
    r.u32MaxInstances = 0xFFFFFFFF;
    r.u32NumAPOInterfaces = 1;
    r.iidAPOInterfaceList[0] = IID_IAudioProcessingObject;
    pp.* = r;
    return S_OK;
}
fn apoInitialize(_: *anyopaque, size: u32, data: ?[*]const u8) callconv(WINAPI) HRESULT {
    if (size > 0 and data == null) return E_POINTER;
    return S_OK;
}

/// Float32 only: what the engine runs endpoint effects in.
fn formatOk(t: *IAudioMediaType) bool {
    var f: UNCOMPRESSEDAUDIOFORMAT = undefined;
    if (t.vt.GetUncompressedAudioFormat(t, &f) != S_OK) return false;
    return f.guidFormatType.eql(&KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) and f.dwBytesPerSampleContainer == 4 and
        f.dwSamplesPerFrame >= 1 and f.dwSamplesPerFrame <= dsp.MAX_CHANNELS;
}
fn apoFormatSupported(_: *anyopaque, opposite: ?*IAudioMediaType, requested: ?*IAudioMediaType, supported: ?*?*IAudioMediaType) callconv(WINAPI) HRESULT {
    const req = requested orelse return E_POINTER;
    const out = supported orelse return E_POINTER;
    out.* = null;
    if (!formatOk(req)) return APOERR_FORMAT_NOT_SUPPORTED;
    if (opposite) |o| {
        // in place: the other side must be the same format
        var flags: u32 = 0;
        if (o.vt.IsEqual(o, req, &flags) != S_OK) {
            _ = o.vt.base.AddRef(o);
            out.* = o;
            return S_FALSE;
        }
    }
    _ = req.vt.base.AddRef(req);
    out.* = req;
    return S_OK;
}
fn apoGetInputChannelCount(p: *anyopaque, out: ?*u32) callconv(WINAPI) HRESULT {
    const o = out orelse return E_POINTER;
    o.* = Apo.fromField("apo", p).channels;
    return S_OK;
}
const apo_vtbl: ApoVtbl = .{
    .base = Delegating("apo"),
    .Reset = apoReset,
    .GetLatency = apoGetLatency,
    .GetRegistrationProperties = apoGetRegistrationProperties,
    .Initialize = apoInitialize,
    .IsInputFormatSupported = apoFormatSupported,
    .IsOutputFormatSupported = apoFormatSupported,
    .GetInputChannelCount = apoGetInputChannelCount,
};

// ---- IAudioProcessingObjectRT ----

fn rtProcess(p: *anyopaque, n_in: u32, ins: ?[*]*APO_CONNECTION_PROPERTY, n_out: u32, outs: ?[*]*APO_CONNECTION_PROPERTY) callconv(WINAPI) void {
    const self = Apo.fromField("rt", p);
    if (n_in < 1 or n_out < 1) return;
    const in = (ins orelse return)[0];
    const out = (outs orelse return)[0];
    const frames = in.u32ValidFrameCount;
    out.u32ValidFrameCount = frames;
    if (in.u32BufferFlags != BUFFER_VALID or self.channels == 0) {
        out.u32BufferFlags = in.u32BufferFlags;
        return;
    }
    const src: [*]f32 = @ptrFromInt(in.pBuffer);
    const dst: [*]f32 = @ptrFromInt(out.pBuffer);
    const n = @as(usize, frames) * self.channels;
    if (src != dst) @memcpy(dst[0..n], src[0..n]);
    const c = &self.coefs[self.active.load(.acquire)];
    dsp.process(c, &self.state, dst, frames, self.channels);
    out.u32BufferFlags = BUFFER_VALID;
    _ = self.frames_done.fetchAdd(frames, .monotonic);
}
fn rtCalcFrames(_: *anyopaque, n: u32) callconv(WINAPI) u32 {
    return n;
}
const rt_vtbl: RtVtbl = .{ .base = Delegating("rt"), .APOProcess = rtProcess, .CalcInputFrames = rtCalcFrames, .CalcOutputFrames = rtCalcFrames };

// ---- IAudioProcessingObjectConfiguration ----

fn cfgLock(p: *anyopaque, n_in: u32, ins: ?[*]*APO_CONNECTION_DESCRIPTOR, n_out: u32, outs: ?[*]*APO_CONNECTION_DESCRIPTOR) callconv(WINAPI) HRESULT {
    const self = Apo.fromField("cfg", p);
    if (n_in < 1 or n_out < 1 or ins == null or outs == null) return E_INVALIDARG;
    const fmt_t = ins.?[0].pFormat orelse return E_POINTER;
    var f: UNCOMPRESSEDAUDIOFORMAT = undefined;
    if (fmt_t.vt.GetUncompressedAudioFormat(fmt_t, &f) != S_OK or !formatOk(fmt_t)) return APOERR_FORMAT_NOT_SUPPORTED;
    self.channels = f.dwSamplesPerFrame;
    self.rate.store(@intFromFloat(f.fFramesPerSecond), .release);
    self.state.reset();
    self.publish(null);
    self.locked = true;
    startWatcher(self);
    return S_OK;
}
fn cfgUnlock(p: *anyopaque) callconv(WINAPI) HRESULT {
    Apo.fromField("cfg", p).locked = false;
    return S_OK;
}
const cfg_vtbl: CfgVtbl = .{ .base = Delegating("cfg"), .LockForProcess = cfgLock, .UnlockForProcess = cfgUnlock };

// ---------------- settings file watcher ----------------

/// `%ProgramData%\VIBE CODE Audio\<name>`
fn dataFile(buf: *[512]u16, comptime name: []const u8) ?[*:0]const u16 {
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ProgramData"), buf, 400);
    var len: usize = n;
    if (n == 0 or n >= 400) {
        const def = std.unicode.utf8ToUtf16LeStringLiteral("C:\\ProgramData");
        @memcpy(buf[0..def.len], def);
        len = def.len;
    }
    const tail = std.unicode.utf8ToUtf16LeStringLiteral("\\VIBE CODE Audio\\" ++ name);
    @memcpy(buf[len .. len + tail.len], tail);
    buf[len + tail.len] = 0;
    return @ptrCast(buf);
}

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const SHARE_ALL: u32 = 7;
const OPEN_EXISTING: u32 = 3;
const CREATE_ALWAYS: u32 = 2;

fn readSettings(self: *Apo, last: *u64) void {
    var path: [512]u16 = undefined;
    const h = CreateFileW(dataFile(&path, "eq.txt") orelse return, GENERIC_READ, SHARE_ALL, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE or h == null) return;
    defer _ = CloseHandle(h);
    var t: u64 = 0;
    if (GetFileTime(h, null, null, &t) == 0 or t == last.*) return;
    var buf: [512]u8 = undefined;
    var n: u32 = 0;
    if (ReadFile(h, &buf, buf.len, &n, null) == 0) return;
    const s = dsp.Settings.parse(buf[0..n]) orelse return;
    last.* = t;
    self.publish(s);
}

fn writeStatus(self: *Apo) void {
    var path: [512]u16 = undefined;
    // one file per instance would pile up: the newest writer wins, which is enough to show "running"
    const h = CreateFileW(dataFile(&path, "status.txt") orelse return, GENERIC_WRITE, SHARE_ALL, null, CREATE_ALWAYS, 0, null);
    if (h == INVALID_HANDLE or h == null) return;
    defer _ = CloseHandle(h);
    var buf: [160]u8 = undefined;
    const c = &self.coefs[self.active.load(.acquire)];
    const line = std.fmt.bufPrint(&buf, "rate={d} channels={d} frames={d} filters={d} pid={d}\r\n", .{ self.rate.load(.acquire), self.channels, self.frames_done.load(.monotonic), c.count, GetCurrentProcessId() }) catch return;
    _ = WriteFile(h, line.ptr, @intCast(line.len), null, null);
}

fn watcher(param: ?*anyopaque) callconv(WINAPI) u32 {
    const self: *Apo = @ptrCast(@alignCast(param.?));
    var last: u64 = 0;
    var ticks: u32 = 0;
    while (true) {
        readSettings(self, &last);
        if (ticks % 10 == 0 and self.locked) writeStatus(self);
        ticks +%= 1;
        if (WaitForSingleObject(self.stop, 250) == 0) break; // stop was signalled
    }
    return 0;
}

fn startWatcher(self: *Apo) void {
    if (self.thread != null) return;
    // read once now so the first buffers already use the saved gains
    var last: u64 = 0;
    readSettings(self, &last);
    self.stop = CreateEventW(null, 1, 0, null) orelse return;
    self.thread = CreateThread(null, 64 * 1024, watcher, self, 0, null);
}

fn destroy(self: *Apo) void {
    if (self.thread) |t| {
        _ = SetEvent(self.stop);
        _ = WaitForSingleObject(t, 2000);
        _ = CloseHandle(t);
    }
    if (self.stop) |e| _ = CloseHandle(e);
    _ = HeapFree(GetProcessHeap(), 0, self);
    _ = live_objects.fetchSub(1, .monotonic);
}

// ---------------- class factory and exports ----------------

const IClassFactoryVtbl = extern struct {
    base: IUnknownVtbl,
    CreateInstance: *const fn (*anyopaque, ?*IUnknown, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    LockServer: *const fn (*anyopaque, i32) callconv(WINAPI) HRESULT,
};

fn cfQueryInterface(p: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    if (iid.eql(&IID_IUnknown) or iid.eql(&IID_IClassFactory)) {
        out.* = p;
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}
fn cfAddRef(_: *anyopaque) callconv(WINAPI) u32 {
    return 2;
}
fn cfRelease(_: *anyopaque) callconv(WINAPI) u32 {
    return 1;
}
fn cfCreateInstance(_: *anyopaque, outer: ?*IUnknown, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = null;
    if (outer != null and !iid.eql(&IID_IUnknown)) return CLASS_E_NOAGGREGATION;
    const self = alloc(Apo) orelse return E_OUTOFMEMORY;
    self.* = .{};
    self.outer = outer orelse @ptrCast(&self.nd);
    _ = live_objects.fetchAdd(1, .monotonic);
    // the reference `self.* = .{}` started with is handed over (aggregated) or traded for `iid`
    if (outer != null) {
        out.* = @ptrCast(&self.nd);
        return S_OK;
    }
    const hr = ndQueryInterface(@ptrCast(&self.nd), iid, out);
    _ = ndRelease(@ptrCast(&self.nd));
    return hr;
}
fn cfLockServer(_: *anyopaque, _: i32) callconv(WINAPI) HRESULT {
    return S_OK;
}
const cf_vtbl: IClassFactoryVtbl = .{
    .base = .{ .QueryInterface = cfQueryInterface, .AddRef = cfAddRef, .Release = cfRelease },
    .CreateInstance = cfCreateInstance,
    .LockServer = cfLockServer,
};
var factory: struct { vt: *const IClassFactoryVtbl } = .{ .vt = &cf_vtbl };

export fn DllGetClassObject(clsid: *const GUID, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = null;
    if (!clsid.eql(&CLSID_VIBE_EQ)) return CLASS_E_CLASSNOTAVAILABLE;
    return cfQueryInterface(@ptrCast(&factory), iid, out);
}

/// Kept loaded while audiodg runs: unloading under a live watcher thread would crash it.
export fn DllCanUnloadNow() callconv(WINAPI) HRESULT {
    return S_FALSE;
}
