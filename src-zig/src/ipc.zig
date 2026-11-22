//! Page → native calls. A webview `invoke(cmd, args)`s; the host hands the request here, the
//! command runs on a worker thread and its reply goes back to the same webview.
//!
//! A command is a plain function:
//!
//!     pub fn fs_read_dir(c: *ipc.Call, a: struct { dir: []const u8 }) ![]DirEntry { ... }
//!
//! - `a` is parsed from the JSON body (keys as the page sends them, camelCase; unknown keys are
//!   ignored; `?T` fields may be missing). Use `void` / no second parameter when it takes none,
//!   or `ipc.Raw` to receive the body bytes as they came (binary uploads).
//! - The result is written as JSON (`void` → null); return `ipc.Bytes` for an ArrayBuffer.
//! - Fail with `return c.fail("message {s}", .{x})`; any other error reaches the page as its name.
//! - Everything allocated with `c.arena` is freed after the reply is sent.

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Call = struct {
    arena: Allocator,
    cmd: []const u8,
    body: []const u8,
    headers: []const Header,
    /// label of the webview that called ("main", "toast", …)
    webview: []const u8,
    err_msg: ?[]const u8 = null,

    /// A request header (case-insensitive), e.g. `x-ext`.
    pub fn header(c: *const Call, name: []const u8) ?[]const u8 {
        for (c.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// Rejects the page's promise with this message.
    pub fn fail(c: *Call, comptime fmt: []const u8, fargs: anytype) error{Failed} {
        c.err_msg = std.fmt.allocPrint(c.arena, fmt, fargs) catch "out of memory";
        return error.Failed;
    }

    /// Same, with a message already built.
    pub fn failMsg(c: *Call, msg: []const u8) error{Failed} {
        c.err_msg = c.arena.dupe(u8, msg) catch "out of memory";
        return error.Failed;
    }
};

/// Body bytes as they came (the page passed a Uint8Array / ArrayBuffer).
pub const Raw = struct { bytes: []const u8 };

/// Reply that reaches the page as an ArrayBuffer.
pub const Bytes = struct { bytes: []const u8 };

pub const Reply = struct {
    ok: bool,
    /// JSON text when `binary` is false
    body: []const u8,
    binary: bool = false,
};

/// Native → page stream (`new Channel()` passed as an argument). The page sends it as
/// "__CHANNEL__:<id>"; `send` delivers one message to its `onmessage`, in order.
pub const Channel = struct {
    id: u64,
    webview: []const u8 = core.host.main_label,

    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !Channel {
        _ = options;
        const tok = try source.nextAlloc(a, .alloc_always);
        const s = switch (tok) {
            .allocated_string, .string => |s| s,
            else => return error.UnexpectedToken,
        };
        const prefix = "__CHANNEL__:";
        if (!std.mem.startsWith(u8, s, prefix)) return error.UnexpectedToken;
        return .{ .id = std.fmt.parseInt(u64, s[prefix.len..], 10) catch return error.InvalidNumber };
    }

    pub fn send(ch: Channel, msg: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(core.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("{{\"c\":{d},\"m\":", .{ch.id}) catch return;
        std.json.Stringify.value(msg, .{}, w) catch return;
        w.writeByte('}') catch return;
        core.host.post(ch.webview, aw.written());
    }

    /// Same, with `msg` already JSON.
    pub fn sendRaw(ch: Channel, json: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(core.gpa);
        defer aw.deinit();
        aw.writer.print("{{\"c\":{d},\"m\":{s}}}", .{ ch.id, json }) catch return;
        core.host.post(ch.webview, aw.written());
    }
};

// ---------------- dispatch ----------------

const Handler = *const fn (*Call) anyerror!Reply;

/// Turns a command function (see the top of the file) into a `Handler`.
fn wrap(comptime func: anytype) Handler {
    const F = @typeInfo(@TypeOf(func)).@"fn";
    return struct {
        fn h(c: *Call) anyerror!Reply {
            const result = switch (F.param_types.len) {
                1 => try func(c),
                2 => blk: {
                    const A = F.param_types[1].?;
                    const a: A = if (A == Raw)
                        .{ .bytes = c.body }
                    else if (A == void)
                        {}
                    else
                        core.fromJson(A, c.arena, if (c.body.len == 0) "{}" else c.body) catch |e|
                            return c.fail("{s}: bad arguments ({s})", .{ c.cmd, @errorName(e) });
                    break :blk try func(c, a);
                },
                else => @compileError("a command takes (c: *ipc.Call) or (c: *ipc.Call, args)"),
            };
            const R = @TypeOf(result);
            if (R == Bytes) return .{ .ok = true, .body = result.bytes, .binary = true };
            if (R == void) return .{ .ok = true, .body = "null" };
            return .{ .ok = true, .body = try core.toJson(c.arena, result) };
        }
    }.h;
}

/// Every command the pages can call, by name (see commands.zig).
const table = blk: {
    const modules = @import("modules.zig");
    var n: usize = 0;
    for (modules.all) |m| {
        if (@hasDecl(m, "commands")) n += m.commands.len;
    }
    var kvs: [n]struct { []const u8, Handler } = undefined;
    var i: usize = 0;
    for (modules.all) |m| {
        if (@hasDecl(m, "commands")) for (m.commands) |entry| {
            kvs[i] = .{ entry[0], wrap(entry[1]) };
            i += 1;
        };
    }
    break :blk std.StaticStringMap(Handler).initComptime(kvs);
};

pub const Request = struct {
    cmd: []const u8,
    body: []const u8,
    headers: []const Header,
    webview: []const u8,
    /// called once, on any thread, with the reply; `ctx` is the host's
    done: *const fn (ctx: *anyopaque, reply: Reply) void,
    ctx: *anyopaque,
};

/// Called by the host (on its UI thread): copies the request and runs it on a worker.
pub fn dispatch(req: Request) void {
    const arena_state = core.gpa.create(std.heap.ArenaAllocator) catch return req.done(req.ctx, .{ .ok = false, .body = "out of memory" });
    arena_state.* = .init(core.gpa);
    const a = arena_state.allocator();
    const copy = a.create(Call) catch return finishOom(arena_state, req);
    var headers = a.alloc(Header, req.headers.len) catch return finishOom(arena_state, req);
    for (req.headers, 0..) |h, i| headers[i] = .{ .name = a.dupe(u8, h.name) catch "", .value = a.dupe(u8, h.value) catch "" };
    copy.* = .{
        .arena = a,
        .cmd = a.dupe(u8, req.cmd) catch return finishOom(arena_state, req),
        .body = a.dupe(u8, req.body) catch return finishOom(arena_state, req),
        .headers = headers,
        .webview = a.dupe(u8, req.webview) catch return finishOom(arena_state, req),
    };
    core.spawn(runCall, .{ arena_state, copy, req.done, req.ctx });
}

fn finishOom(arena_state: *std.heap.ArenaAllocator, req: Request) void {
    arena_state.deinit();
    core.gpa.destroy(arena_state);
    req.done(req.ctx, .{ .ok = false, .body = "out of memory" });
}

fn runCall(arena_state: *std.heap.ArenaAllocator, c: *Call, done: *const fn (*anyopaque, Reply) void, ctx: *anyopaque) void {
    defer {
        arena_state.deinit();
        core.gpa.destroy(arena_state);
    }
    const reply: Reply = if (table.get(c.cmd)) |h|
        h(c) catch |e| .{ .ok = false, .body = c.err_msg orelse @errorName(e) }
    else
        .{ .ok = false, .body = std.fmt.allocPrint(c.arena, "unknown command: {s}", .{c.cmd}) catch "unknown command" };
    if (!reply.ok) std.log.debug("{s} failed: {s}", .{ c.cmd, reply.body });
    // the host copies what it needs before returning
    done(ctx, reply);
}
