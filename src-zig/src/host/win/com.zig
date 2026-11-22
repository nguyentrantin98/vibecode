//! COM plumbing for WebView2: handler objects built from a Zig function, and small helpers.

const std = @import("std");
pub const c = @import("win");

pub const HRESULT = c.HRESULT;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

pub fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn check(hr: HRESULT) !void {
    if (hr < 0) {
        std.log.warn("COM call failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.ComFailed;
    }
}

pub fn eqlGuid(a: *const c.IID, b: *const c.IID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

const IID_IUnknown: c.IID = .{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IAgileObject: c.IID = .{ .Data1 = 0x94ea2b94, .Data2 = 0xe9cc, .Data3 = 0x49e0, .Data4 = .{ 0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90 } };

/// Calls a COM method: `call(obj, "get_Settings", .{&settings})`.
pub inline fn call(obj: anytype, comptime method: []const u8, args: anytype) HRESULT {
    const f = @field(obj.*.lpVtbl.*, method).?;
    return @call(.auto, f, .{obj} ++ args);
}

pub fn release(obj: anytype) void {
    if (obj) |o| _ = o.*.lpVtbl.*.Release.?(o);
}

pub fn addRef(obj: anytype) void {
    _ = obj.*.lpVtbl.*.AddRef.?(obj);
}

/// `obj` as another interface it implements, or null (`QueryInterface`).
pub fn query(comptime T: type, obj: anytype, iid: *const c.IID) ?*T {
    var out: ?*anyopaque = null;
    const hr = obj.*.lpVtbl.*.QueryInterface.?(obj, iid, &out);
    if (hr < 0 or out == null) return null;
    return @ptrCast(@alignCast(out));
}

/// A WebView2 handler object (`ICoreWebView2…Handler`): every such interface has a single
/// `Invoke(This, a, b)`. `f(ctx, a, b)` is called with the same `a`, `b`.
///
///     const h = com.handler(c.ICoreWebView2WebMessageReceivedEventHandler,
///         &c.IID_ICoreWebView2WebMessageReceivedEventHandler, self, onMessage);
pub fn handler(comptime Iface: type, iid: *const c.IID, ctx: anytype, comptime f: anytype) *Iface {
    const Ctx = @TypeOf(ctx);
    const VtblPtr = @FieldType(Iface, "lpVtbl");
    const Vtbl = @typeInfo(VtblPtr).pointer.child;
    const InvokeFnPtr = @typeInfo(@FieldType(Vtbl, "Invoke")).optional.child;
    const InvokeFn = @typeInfo(InvokeFnPtr).pointer.child;
    const params = @typeInfo(InvokeFn).@"fn".param_types;
    const A = params[1].?;
    const B = params[2].?;
    const Obj = struct {
        iface: Iface,
        refs: std.atomic.Value(u32),
        ctx: Ctx,
        iid: *const c.IID,
        const vtbl: Vtbl = .{
            .QueryInterface = qi,
            .AddRef = addRefImpl,
            .Release = releaseImpl,
            .Invoke = invoke,
        };
        fn self(this: [*c]Iface) *@This() {
            return @fieldParentPtr("iface", @as(*Iface, @ptrCast(this)));
        }
        fn qi(this: [*c]Iface, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) HRESULT {
            const s = self(this);
            if (eqlGuid(riid, &IID_IUnknown) or eqlGuid(riid, s.iid) or eqlGuid(riid, &IID_IAgileObject)) {
                _ = s.refs.fetchAdd(1, .monotonic);
                out.* = @ptrCast(this);
                return S_OK;
            }
            out.* = null;
            return E_NOINTERFACE;
        }
        fn addRefImpl(this: [*c]Iface) callconv(.c) c.ULONG {
            return self(this).refs.fetchAdd(1, .monotonic) + 1;
        }
        fn releaseImpl(this: [*c]Iface) callconv(.c) c.ULONG {
            const s = self(this);
            const n = s.refs.fetchSub(1, .acq_rel) - 1;
            if (n == 0) std.heap.c_allocator.destroy(s);
            return n;
        }
        fn invoke(this: [*c]Iface, a: A, b: B) callconv(.c) HRESULT {
            const r = f(self(this).ctx, a, b);
            return if (@TypeOf(r) == void) S_OK else r;
        }
    };
    const o = std.heap.c_allocator.create(Obj) catch @panic("oom");
    o.* = .{ .iface = .{ .lpVtbl = @constCast(&Obj.vtbl) }, .refs = .init(1), .ctx = ctx, .iid = iid };
    return &o.iface;
}

/// Adds an event handler (`add_<Event>`) and drops our reference (the webview holds it).
pub fn on(obj: anytype, comptime event: []const u8, comptime Iface: type, iid: *const c.IID, ctx: anytype, comptime f: anytype) void {
    const h = handler(Iface, iid, ctx, f);
    var token: c.EventRegistrationToken = undefined;
    _ = call(obj, "add_" ++ event, .{ h, &token });
    release(@as(?*Iface, h));
}

/// A UTF-16 string the callee owns (`CoTaskMemAlloc`), e.g. for `get_` methods we implement.
pub fn taskString(s: []const u8) c.LPWSTR {
    const w = std.unicode.wtf8ToWtf16LeAllocZ(std.heap.c_allocator, s) catch return null;
    defer std.heap.c_allocator.free(w);
    const bytes = (w.len + 1) * 2;
    const p: [*]u16 = @ptrCast(@alignCast(c.CoTaskMemAlloc(bytes) orelse return null));
    @memcpy(p[0 .. w.len + 1], w[0 .. w.len + 1]);
    return p;
}

/// UTF-8 copy of a string WebView2 handed us (and frees it with `CoTaskMemFree`).
pub fn takeString(a: std.mem.Allocator, s: c.LPWSTR) ![]u8 {
    if (s == null) return a.dupe(u8, "");
    defer c.CoTaskMemFree(s);
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(@as([*:0]const u16, @ptrCast(s))));
}

/// UTF-16 for a call (allocated with `a`).
pub fn wstr(a: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s);
}
