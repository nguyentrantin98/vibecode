//! Zalo Web's websocket: live messages, the recent history Zalo replays on request and recalls.
//! Port of zca-js `apis/listen.js` (only the events VIBE CODE uses) plus the message models (`models/Message.js`, `Reaction.js`, …).
//!
//! Only one web session per account may listen: a listener that was stopped never reconnects.

const std = @import("std");
const core = @import("../core.zig");
const proto = @import("proto.zig");
const ws = @import("ws.zig");
const api_mod = @import("api.zig");
const Api = api_mod.Api;
const ThreadType = api_mod.ThreadType;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// A message, as zca-js `UserMessage` / `GroupMessage` leave it: "0" ids replaced by mine.
pub const Msg = struct {
    kind: ThreadType,
    thread_id: []const u8,
    is_self: bool,
    data: Value,
};

fn asObject(data: Value) Value {
    return if (data == .object) data else .{ .object = .empty };
}

fn fixQuoteOwner(a: Allocator, data: *Value) !void {
    const q = data.object.getPtr("quote") orelse return;
    if (q.* != .object) return;
    const owner = q.object.get("ownerId") orelse return;
    try q.object.put(a, "ownerId", .{ .string = try proto.jstr(a, owner) });
}

/// `data` is changed in place (give a copy that lives in `a`).
pub fn userMessage(a: Allocator, uid: []const u8, data_in: Value) !Msg {
    var data = asObject(data_in);
    const is_self = proto.isZeroId(proto.field(data, "uidFrom"));
    const thread_id = try proto.jstr(a, if (is_self) proto.field(data, "idTo") else proto.field(data, "uidFrom"));
    const me: Value = .{ .string = try a.dupe(u8, uid) };
    if (proto.isZeroId(proto.field(data, "idTo"))) try data.object.put(a, "idTo", me);
    if (is_self) try data.object.put(a, "uidFrom", me);
    try fixQuoteOwner(a, &data);
    return .{ .kind = .user, .thread_id = thread_id, .is_self = is_self, .data = data };
}

pub fn groupMessage(a: Allocator, uid: []const u8, data_in: Value) !Msg {
    var data = asObject(data_in);
    const is_self = proto.isZeroId(proto.field(data, "uidFrom"));
    const thread_id = try proto.jstr(a, proto.field(data, "idTo"));
    if (is_self) try data.object.put(a, "uidFrom", .{ .string = try a.dupe(u8, uid) });
    try fixQuoteOwner(a, &data);
    return .{ .kind = .group, .thread_id = thread_id, .is_self = is_self, .data = data };
}

/// `Undo`: same id rules as messages, the thread is the group or the other person.
pub const Action = struct {
    thread_id: []const u8,
    data: Value,
};

fn action(a: Allocator, uid: []const u8, data_in: Value, is_group: bool) !Action {
    var data = asObject(data_in);
    const is_self = proto.isZeroId(proto.field(data, "uidFrom"));
    const thread_id = try proto.jstr(a, if (is_group or is_self) proto.field(data, "idTo") else proto.field(data, "uidFrom"));
    const me: Value = .{ .string = try a.dupe(u8, uid) };
    if (proto.isZeroId(proto.field(data, "idTo"))) try data.object.put(a, "idTo", me);
    if (is_self) try data.object.put(a, "uidFrom", me);
    return .{ .thread_id = thread_id, .data = data };
}

/// What the listener tells its owner. An event owns what it points to (`deinit` when done).
pub const Event = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    what: What,

    pub const What = union(enum) {
        /// the socket has its key: history can be requested now
        cipher_key,
        message: Msg,
        old_messages: struct { list: []const Msg, kind: ThreadType },
        /// a message recalled ("thu hồi")
        undo: Action,
        /// the socket closed for good (no retry): its close code
        closed: u16,
        err: []const u8,
    };

    pub fn deinit(e: Event) void {
        const arena = e.arena orelse return;
        arena.deinit();
        core.gpa.destroy(arena);
    }
};

fn newArena() !*std.heap.ArenaAllocator {
    const arena = try core.gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(core.gpa);
    return arena;
}

/// An unbounded queue between threads (what the Rust build used tokio's channels for).
pub fn Queue(comptime T: type) type {
    return struct {
        mutex: core.Mutex = .{},
        cond: std.Io.Condition = .init,
        items: std.ArrayList(T) = .empty,
        head: usize = 0,
        closed: bool = false,

        const Self = @This();

        /// False when the queue is closed (the item is still the caller's).
        pub fn push(q: *Self, item: T) bool {
            q.mutex.lock();
            defer q.mutex.unlock();
            if (q.closed) return false;
            q.items.append(core.gpa, item) catch return false;
            q.cond.signal(core.io);
            return true;
        }

        fn take(q: *Self) ?T {
            if (q.head == q.items.items.len) return null;
            const item = q.items.items[q.head];
            q.head += 1;
            if (q.head == q.items.items.len) {
                q.head = 0;
                q.items.clearRetainingCapacity();
            }
            return item;
        }

        /// Waits for the next item; null once the queue is closed and empty.
        pub fn pop(q: *Self) ?T {
            q.mutex.lock();
            defer q.mutex.unlock();
            while (true) {
                if (q.take()) |item| return item;
                if (q.closed) return null;
                q.cond.waitUncancelable(core.io, &q.mutex.m);
            }
        }

        /// The next item if there is one.
        pub fn tryPop(q: *Self) ?T {
            q.mutex.lock();
            defer q.mutex.unlock();
            return q.take();
        }

        pub fn close(q: *Self) void {
            q.mutex.lock();
            q.closed = true;
            q.cond.broadcast(core.io);
            q.mutex.unlock();
        }

        /// Frees the queue's own memory (take what is left out first).
        pub fn deinit(q: *Self) void {
            q.items.deinit(core.gpa);
        }
    };
}

const Retry = struct {
    count: u32 = 0,
    max: u32,
    times: []const u64,
};

const OutMsg = union(enum) {
    /// owned by `core.gpa`
    frame: []u8,
    close: u16,
};
const Out = Queue(OutMsg);

const State = struct {
    ws_url: []u8 = &.{},
    rotate_count: usize = 0,
    retries: std.AutoArrayHashMapUnmanaged(u16, Retry) = .empty,
    out: ?*Out = null,
    req_id: u64 = 0,
    cipher_key: ?[]u8 = null,
    /// the ping thread of another number stops
    ping_gen: u64 = 0,
    /// set by `stop`: never reconnect after that
    stopped: bool = false,
    /// the code we closed with, when we closed
    closing: ?u16 = null,
};

/// Shared between threads by reference count (`retain` / `release`).
pub const Listener = struct {
    refs: std.atomic.Value(u32) = .init(1),
    api: *Api,
    events: Queue(Event) = .{},
    mutex: core.Mutex = .{},
    ping_cond: std.Io.Condition = .init,
    st: State = .{},

    pub fn create(a: Allocator, api: *Api, fail: *core.Fail) !*Listener {
        if (api.ws_urls.len == 0) return fail.set(a, "Zalo did not give a websocket address", .{});
        const l = try core.gpa.create(Listener);
        l.* = .{ .api = api.retain() };
        errdefer l.release();
        l.st.ws_url = makeWsUrl(api.ws_urls[0]) catch return fail.set(a, "bad URL {s}", .{api.ws_urls[0]});
        const retries = l.socketSetting("retries");
        if (retries == .object) {
            var it = retries.object.iterator();
            while (it.next()) |e| {
                const code = std.fmt.parseInt(u16, e.key_ptr.*, 10) catch continue;
                const r = e.value_ptr.*;
                var times: std.ArrayList(u64) = .empty;
                switch (proto.field(r, "times") orelse Value{ .null = {} }) {
                    .integer => |n| try times.append(core.gpa, @intCast(@max(0, n))),
                    .array => |arr| for (arr.items) |t| {
                        if (t == .integer and t.integer >= 0) try times.append(core.gpa, @intCast(t.integer));
                    },
                    else => {},
                }
                const max: u32 = switch (proto.field(r, "max") orelse Value{ .null = {} }) {
                    .integer => |n| @intCast(std.math.clamp(n, 0, std.math.maxInt(u32))),
                    else => 0,
                };
                const owned = try times.toOwnedSlice(core.gpa);
                l.st.retries.put(core.gpa, code, .{ .max = max, .times = owned }) catch |err| {
                    core.gpa.free(owned);
                    return err;
                };
            }
        }
        return l;
    }

    pub fn retain(l: *Listener) *Listener {
        _ = l.refs.fetchAdd(1, .monotonic);
        return l;
    }

    pub fn release(l: *Listener) void {
        if (l.refs.fetchSub(1, .acq_rel) != 1) return;
        while (l.events.tryPop()) |e| e.deinit();
        l.events.deinit();
        for (l.st.retries.values()) |r| core.gpa.free(r.times);
        l.st.retries.deinit(core.gpa);
        core.gpa.free(l.st.ws_url);
        if (l.st.cipher_key) |k| core.gpa.free(k);
        l.api.release();
        core.gpa.destroy(l);
    }

    fn makeWsUrl(base: []const u8) ![]u8 {
        var buf: [24]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{proto.nowMs()}) catch unreachable;
        return proto.makeUrl(core.gpa, base, &.{.{ "t", t }}, true);
    }

    /// `settings.features.socket[key]`
    fn socketSetting(l: *const Listener, key: []const u8) Value {
        return proto.field(proto.field(proto.field(l.api.settings, "features"), "socket"), key) orelse .null;
    }

    fn emit(l: *Listener, e: Event) void {
        if (!l.events.push(e)) e.deinit();
    }

    fn emitErr(l: *Listener, msg: []const u8) void {
        const arena = newArena() catch return;
        l.emit(.{ .arena = arena, .what = .{ .err = arena.allocator().dupe(u8, msg) catch "" } });
    }

    /// Connect (`retry_on_close`: reconnect the way Zalo's settings say on the codes they list).
    pub fn start(l: *Listener, a: Allocator, retry_on_close: bool, fail: *core.Fail) !void {
        l.mutex.lock();
        defer l.mutex.unlock();
        if (l.st.out != null) return fail.set(a, "Already started", .{});
        if (l.st.stopped) return fail.set(a, "Listener was stopped", .{});
        const out = try core.gpa.create(Out);
        errdefer core.gpa.destroy(out);
        out.* = .{};
        const url = try core.gpa.dupe(u8, l.st.ws_url);
        errdefer core.gpa.free(url);
        const t = try std.Thread.spawn(.{}, run, .{ l.retain(), url, out, retry_on_close });
        t.detach();
        l.st.out = out;
        l.st.closing = null;
    }

    /// Close for good.
    pub fn stop(l: *Listener) void {
        l.mutex.lock();
        defer l.mutex.unlock();
        l.st.stopped = true;
        if (l.st.out) |out| {
            l.st.closing = 1000;
            _ = out.push(.{ .close = 1000 });
        }
        l.reset();
    }

    /// With the lock held.
    fn reset(l: *Listener) void {
        l.st.out = null;
        if (l.st.cipher_key) |k| core.gpa.free(k);
        l.st.cipher_key = null;
        l.st.ping_gen += 1;
        l.ping_cond.broadcast(core.io);
    }

    fn run(l: *Listener, url: []u8, out: *Out, retry_on_close: bool) void {
        defer l.release();
        const code = l.pump(url, out);
        core.gpa.free(url);
        l.mutex.lock();
        l.reset();
        const stopped = l.st.stopped;
        l.mutex.unlock();
        // nothing can reach the queue any more (`st.out` is cleared under the lock)
        while (out.tryPop()) |o| if (o == .frame) core.gpa.free(o.frame);
        out.deinit();
        core.gpa.destroy(out);

        const retry: ?u64 = if (retry_on_close and !stopped) l.canRetry(code) else null;
        // zca-js treats a 0 ms retry time as "don't retry"
        if (retry != null and retry.? > 0) {
            if (l.shouldRotate(code)) l.rotate();
            core.sleepMs(retry.?);
            l.mutex.lock();
            const stopped_now = l.st.stopped;
            l.mutex.unlock();
            var fail: core.Fail = .{};
            var buf: [256]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            if (stopped_now) return l.emit(.{ .what = .{ .closed = code } });
            l.start(fba.allocator(), true, &fail) catch l.emit(.{ .what = .{ .closed = code } });
            return;
        }
        l.emit(.{ .what = .{ .closed = code } });
    }

    fn writeLoop(client: *ws.Client, out: *Out) void {
        while (out.pop()) |o| {
            switch (o) {
                .frame => |b| {
                    defer core.gpa.free(b);
                    client.sendBinary(b) catch return;
                },
                .close => |code| client.sendClose(code) catch return,
            }
        }
    }

    /// One connection, until it closes: its close code.
    fn pump(l: *Listener, url: []const u8, out: *Out) u16 {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const cookie = l.api.http.cookieString(a, "https://chat.zalo.me") catch "";
        const client = ws.Client.connect(core.gpa, url, &.{
            .{ .name = "accept-language", .value = "en-US,en;q=0.9" },
            .{ .name = "cache-control", .value = "no-cache" },
            .{ .name = "pragma", .value = "no-cache" },
            .{ .name = "origin", .value = "https://chat.zalo.me" },
            .{ .name = "user-agent", .value = l.api.http.user_agent },
            .{ .name = "cookie", .value = cookie },
        }) catch |e| {
            l.emitErr(@errorName(e));
            return 1006;
        };
        defer client.deinit();
        const writer = std.Thread.spawn(.{}, writeLoop, .{ client, out }) catch |e| {
            l.emitErr(@errorName(e));
            return 1006;
        };
        var code: ?u16 = null;
        while (true) {
            const m = client.read() catch |e| {
                if (e != error.EndOfStream) l.emitErr(@errorName(e));
                break;
            };
            switch (m) {
                .binary => |b| l.onFrame(b),
                .text => {},
                .close => |c| {
                    code = c;
                    break;
                },
            }
        }
        out.close();
        writer.join();
        l.mutex.lock();
        defer l.mutex.unlock();
        return code orelse l.st.closing orelse 1006;
    }

    fn listed(l: *const Listener, key: []const u8, code: u16) bool {
        const codes = l.socketSetting(key);
        if (codes != .array) return false;
        for (codes.array.items) |c| if (c == .integer and c.integer == code) return true;
        return false;
    }

    /// `canRetry`: the wait before reconnecting, if this code may retry.
    fn canRetry(l: *Listener, code: u16) ?u64 {
        if (!l.listed("close_and_retry_codes", code)) return null;
        l.mutex.lock();
        defer l.mutex.unlock();
        const r = l.st.retries.getPtr(code) orelse return null;
        if (r.count >= r.max) return null;
        r.count += 1;
        if (r.times.len == 0) return null;
        return r.times[@min(r.count - 1, r.times.len - 1)];
    }

    fn shouldRotate(l: *Listener, code: u16) bool {
        if (!l.listed("rotate_error_codes", code)) return false;
        l.mutex.lock();
        defer l.mutex.unlock();
        return l.st.rotate_count < l.api.ws_urls.len -| 1;
    }

    fn rotate(l: *Listener) void {
        l.mutex.lock();
        defer l.mutex.unlock();
        l.st.rotate_count += 1;
        if (l.st.rotate_count >= l.api.ws_urls.len) return;
        const url = makeWsUrl(l.api.ws_urls[l.st.rotate_count]) catch return;
        core.gpa.free(l.st.ws_url);
        l.st.ws_url = url;
    }

    /// `sendWs`: `fields` is the inside of the JSON object ("\"first\":true,…"); `req_id` goes
    /// last, as the Rust build's (sorted) JSON had it.
    fn sendWs(l: *Listener, version: u8, cmd: u16, sub_cmd: u8, fields: []const u8, require_id: bool) void {
        l.mutex.lock();
        defer l.mutex.unlock();
        const out = l.st.out orelse return;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(core.gpa);
        body.print(core.gpa, "{{{s}", .{fields}) catch return;
        if (require_id) {
            body.print(core.gpa, ",\"req_id\":\"req_{d}\"", .{l.st.req_id}) catch return;
            l.st.req_id += 1;
        }
        body.append(core.gpa, '}') catch return;
        const frame = proto.encodeFrame(core.gpa, version, cmd, sub_cmd, body.items) catch return;
        if (!out.push(.{ .frame = frame })) core.gpa.free(frame);
    }

    /// Ask Zalo to replay a page of recent messages (older than `last_id` when given).
    pub fn requestOldMessages(l: *Listener, kind: ThreadType, last_id: ?[]const u8) void {
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const last = if (last_id) |id| core.toJson(fba.allocator(), id) catch return else "null";
        var fields: [320]u8 = undefined;
        const text = std.fmt.bufPrint(&fields, "\"first\":true,\"lastId\":{s},\"preIds\":[]", .{last}) catch return;
        l.sendWs(1, if (kind == .user) 510 else 511, 1, text, true);
    }

    fn pingLoop(l: *Listener, gen: u64, interval: u64) void {
        defer l.release();
        while (true) {
            const deadline = core.monoMs() + interval;
            l.mutex.lock();
            while (l.st.ping_gen == gen) {
                const now = core.monoMs();
                if (now >= deadline) break;
                l.ping_cond.waitTimeout(core.io, &l.mutex.m, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(deadline - now)), .clock = .awake } }) catch {};
            }
            const alive = l.st.ping_gen == gen;
            l.mutex.unlock();
            if (!alive) return;
            var buf: [64]u8 = undefined;
            l.sendWs(1, 2, 1, std.fmt.bufPrint(&buf, "\"eventId\":{d}", .{proto.nowMs()}) catch return, false);
        }
    }

    /// The event's `data`, decoded with the socket's key (allocated in `a`).
    fn decode(l: *Listener, a: Allocator, parsed: Value) !Value {
        const key: ?[]const u8 = blk: {
            l.mutex.lock();
            defer l.mutex.unlock();
            break :blk if (l.st.cipher_key) |k| try a.dupe(u8, k) else null;
        };
        const v = try proto.decodeEventData(a, parsed, key);
        return proto.field(v, "data") orelse .null;
    }

    fn onFrame(l: *Listener, frame: []const u8) void {
        const h = proto.frameHeader(frame) orelse return l.emitErr("Invalid header");
        const text = frame[4..];
        if (text.len == 0) return;
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const parsed = proto.parseJson(a, text) catch |e| return l.emitErr(@errorName(e));
        l.dispatch(a, h.version, h.cmd, h.sub, parsed) catch |e| l.emitErr(@errorName(e));
    }

    fn listOf(v: Value, key: []const u8) []const Value {
        const x = proto.field(v, key) orelse return &.{};
        return if (x == .array) x.array.items else &.{};
    }

    fn isUndo(m: Value) bool {
        const c = proto.field(m, "content") orelse return false;
        return c == .object and c.object.contains("deleteMsg");
    }

    /// A live message (or recall) as an event that owns its copy of `m`.
    fn emitOne(l: *Listener, m: Value, group: bool) !void {
        const arena = try newArena();
        errdefer Event.deinit(.{ .arena = arena, .what = .cipher_key });
        const ea = arena.allocator();
        const copy = try proto.cloneValue(ea, m);
        const uid = l.api.uid;
        l.emit(.{ .arena = arena, .what = if (isUndo(m))
            .{ .undo = try action(ea, uid, copy, group) }
        else
            .{ .message = if (group) try groupMessage(ea, uid, copy) else try userMessage(ea, uid, copy) } });
    }

    fn emitOld(l: *Listener, msgs: []const Value, kind: ThreadType) !void {
        const arena = try newArena();
        errdefer Event.deinit(.{ .arena = arena, .what = .cipher_key });
        const ea = arena.allocator();
        const out = try ea.alloc(Msg, msgs.len);
        for (out, msgs) |*o, m| {
            const copy = try proto.cloneValue(ea, m);
            o.* = if (kind == .group) try groupMessage(ea, l.api.uid, copy) else try userMessage(ea, l.api.uid, copy);
        }
        l.emit(.{ .arena = arena, .what = .{ .old_messages = .{ .list = out, .kind = kind } } });
    }

    fn dispatch(l: *Listener, a: Allocator, version: u8, cmd: u16, sub: u8, parsed: Value) !void {
        if (version == 1 and cmd == 1 and sub == 1 and proto.field(parsed, "key") != null) {
            const key = try core.gpa.dupe(u8, try proto.jstr(a, proto.field(parsed, "key")));
            const setting = l.socketSetting("ping_interval");
            const interval: u64 = if (setting == .integer and setting.integer > 0) @intCast(setting.integer) else 60_000;
            l.mutex.lock();
            if (l.st.cipher_key) |old| core.gpa.free(old);
            l.st.cipher_key = key;
            // the ping of an earlier key stops
            l.st.ping_gen += 1;
            const gen = l.st.ping_gen;
            l.ping_cond.broadcast(core.io);
            l.mutex.unlock();
            if (std.Thread.spawn(.{}, pingLoop, .{ l.retain(), gen, interval })) |t| t.detach() else |_| l.release();
            l.emit(.{ .what = .cipher_key });
        }
        if (version == 1 and (cmd == 501 or cmd == 551) and sub == 0) {
            for (listOf(try l.decode(a, parsed), "msgs")) |m| try l.emitOne(m, false);
        }
        if (version == 1 and cmd == 521 and sub == 0) {
            for (listOf(try l.decode(a, parsed), "groupMsgs")) |m| try l.emitOne(m, true);
        }
        if (cmd == 510 and sub == 1) try l.emitOld(listOf(try l.decode(a, parsed), "msgs"), .user);
        if (cmd == 511 and sub == 1) try l.emitOld(listOf(try l.decode(a, parsed), "groupMsgs"), .group);
        if (version == 1 and cmd == 3000 and sub == 0) {
            // another Zalo Web session took over
            l.mutex.lock();
            defer l.mutex.unlock();
            l.st.closing = 3000;
            if (l.st.out) |out| _ = out.push(.{ .close = 3000 });
        }
    }
};

// ---------------- tests ----------------

const testing = std.testing;

test "message models like zca" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const me = "999";
    const mine = try userMessage(a, me, try proto.parseJson(a, "{\"msgId\":\"1\",\"uidFrom\":\"0\",\"idTo\":\"123\",\"quote\":{\"ownerId\":55}}"));
    try testing.expect(mine.is_self);
    try testing.expectEqualStrings("123", mine.thread_id);
    try testing.expectEqualStrings("999", proto.fieldStr(mine.data, "uidFrom").?);
    try testing.expectEqualStrings("55", proto.fieldStr(proto.field(mine.data, "quote"), "ownerId").?);
    const theirs = try userMessage(a, me, try proto.parseJson(a, "{\"msgId\":\"2\",\"uidFrom\":\"123\",\"idTo\":\"0\"}"));
    try testing.expect(!theirs.is_self);
    try testing.expectEqualStrings("123", theirs.thread_id);
    try testing.expectEqualStrings("999", proto.fieldStr(theirs.data, "idTo").?);
    const g = try groupMessage(a, me, try proto.parseJson(a, "{\"msgId\":\"3\",\"uidFrom\":\"0\",\"idTo\":\"g1\"}"));
    try testing.expect(g.is_self and g.kind == .group);
    try testing.expectEqualStrings("g1", g.thread_id);
    try testing.expectEqualStrings("999", proto.fieldStr(g.data, "uidFrom").?);
    var r = try action(a, me, try proto.parseJson(a, "{\"uidFrom\":\"123\",\"idTo\":\"0\"}"), false);
    try testing.expectEqualStrings("123", r.thread_id);
    r = try action(a, me, try proto.parseJson(a, "{\"uidFrom\":\"123\",\"idTo\":\"g7\"}"), true);
    try testing.expectEqualStrings("g7", r.thread_id);
    // not an object: nothing to read, no crash
    const odd = try userMessage(a, me, .{ .string = "?" });
    try testing.expectEqualStrings("undefined", odd.thread_id);
}

test "queue: order, close, waiting" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var q: Queue(u32) = .{};
    defer q.deinit();
    try testing.expect(q.tryPop() == null);
    for (0..5) |i| try testing.expect(q.push(@intCast(i)));
    for (0..5) |i| try testing.expectEqual(@as(?u32, @intCast(i)), q.pop());
    // a waiting reader gets what another thread pushes, then the end
    const t = try std.Thread.spawn(.{}, struct {
        fn run(queue: *Queue(u32)) void {
            core.sleepMs(20);
            _ = queue.push(7);
            queue.close();
        }
    }.run, .{&q});
    try testing.expectEqual(@as(?u32, 7), q.pop());
    try testing.expectEqual(@as(?u32, null), q.pop());
    t.join();
    try testing.expect(!q.push(8));
}

fn testApi(a: Allocator, settings_json: []const u8, urls: []const []const u8) !Api {
    return .{
        .arena = .init(a),
        .http = .{ .jar = .init(a), .user_agent = "UA" },
        .uid = "999",
        .settings = try proto.parseJson(a, settings_json),
        .ws_urls = urls,
    };
}

test "retries and rotation follow Zalo's settings" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    var api = try testApi(a,
        \\{"features":{"socket":{"ping_interval":1000,"close_and_retry_codes":[1006,1000,3003],"rotate_error_codes":[1006],
        \\ "retries":{"1006":{"max":3,"times":[100,200]},"1000":{"max":1,"times":5000},"bad":{"max":1},"3003":{"max":2,"times":[]}}}}}
    , &.{ "wss://ws1.chat.zalo.me/?a=1", "wss://ws2.chat.zalo.me" });
    const l = try Listener.create(a, &api, &fail);
    try testing.expect(std.mem.startsWith(u8, l.st.ws_url, "wss://ws1.chat.zalo.me/?a=1&t="));
    try testing.expect(std.mem.endsWith(u8, l.st.ws_url, "&zpw_ver=685&zpw_type=30"));
    // the times in order, the last one again, then no more
    try testing.expectEqual(@as(?u64, 100), l.canRetry(1006));
    try testing.expectEqual(@as(?u64, 200), l.canRetry(1006));
    try testing.expectEqual(@as(?u64, 200), l.canRetry(1006));
    try testing.expectEqual(@as(?u64, null), l.canRetry(1006));
    try testing.expectEqual(@as(?u64, 5000), l.canRetry(1000));
    try testing.expectEqual(@as(?u64, null), l.canRetry(1000));
    // not listed, or listed without times
    try testing.expectEqual(@as(?u64, null), l.canRetry(3000));
    try testing.expectEqual(@as(?u64, null), l.canRetry(3003));
    // one more address to rotate to, once
    try testing.expect(l.shouldRotate(1006) and !l.shouldRotate(1000));
    l.rotate();
    try testing.expect(std.mem.startsWith(u8, l.st.ws_url, "wss://ws2.chat.zalo.me/?t="));
    try testing.expect(!l.shouldRotate(1006));

    // nothing is sent while there is no connection; with one, frames carry a running request id
    l.requestOldMessages(.user, null);
    var out: Out = .{};
    defer out.deinit();
    l.st.out = &out;
    l.requestOldMessages(.user, null);
    l.requestOldMessages(.group, "73\"1");
    l.st.out = null;
    const f1 = out.tryPop().?.frame;
    defer core.gpa.free(f1);
    try testing.expectEqual(proto.FrameHeader{ .version = 1, .cmd = 510, .sub = 1 }, proto.frameHeader(f1).?);
    try testing.expectEqualStrings("{\"first\":true,\"lastId\":null,\"preIds\":[],\"req_id\":\"req_0\"}", f1[4..]);
    const f2 = out.tryPop().?.frame;
    defer core.gpa.free(f2);
    try testing.expectEqual(@as(u16, 511), proto.frameHeader(f2).?.cmd);
    try testing.expectEqualStrings("{\"first\":true,\"lastId\":\"73\\\"1\",\"preIds\":[],\"req_id\":\"req_1\"}", f2[4..]);

    // a stopped listener never starts again
    l.stop();
    try testing.expectError(error.Failed, l.start(a, true, &fail));
    try testing.expectEqualStrings("Listener was stopped", fail.msg);
    // (`api` is on the stack: its own reference is never given back)
    l.release();

    var none = try testApi(a, "{}", &.{});
    try testing.expectError(error.Failed, Listener.create(a, &none, &fail));
    try testing.expectEqualStrings("Zalo did not give a websocket address", fail.msg);
}

test "frames become events" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    var api = try testApi(a, "{}", &.{"wss://ws1.chat.zalo.me/"});
    const l = try Listener.create(a, &api, &fail);
    defer l.release();

    const frame = struct {
        fn make(al: Allocator, cmd: u16, sub: u8, comptime data: []const u8) ![]u8 {
            const body = try core.toJson(al, .{ .data = data, .encrypt = 0 });
            return proto.encodeFrame(al, 1, cmd, sub, body);
        }
    }.make;
    // live messages of a personal chat: one message, one recall, in order
    l.onFrame(try frame(a, 501, 0, "{\"data\":{\"msgs\":[{\"msgId\":\"1\",\"uidFrom\":\"5\",\"idTo\":\"0\",\"content\":\"hi\"},{\"uidFrom\":\"5\",\"idTo\":\"0\",\"content\":{\"deleteMsg\":1,\"globalMsgId\":\"1\"}}]}}"));
    // a group message, then a page of old ones
    l.onFrame(try frame(a, 521, 0, "{\"data\":{\"groupMsgs\":[{\"msgId\":\"2\",\"uidFrom\":\"0\",\"idTo\":\"g1\",\"content\":\"yo\"}]}}"));
    l.onFrame(try frame(a, 511, 1, "{\"data\":{\"groupMsgs\":[{\"msgId\":\"3\",\"uidFrom\":\"7\",\"idTo\":\"g1\"},{\"msgId\":\"4\",\"uidFrom\":\"7\",\"idTo\":\"g1\"}]}}"));
    l.onFrame(&.{ 1, 2 });
    l.onFrame(try proto.encodeFrame(a, 1, 501, 0, "{not json"));
    l.onFrame(try proto.encodeFrame(a, 1, 9999, 0, ""));

    var e = l.events.tryPop().?;
    try testing.expect(e.what == .message and e.what.message.kind == .user and !e.what.message.is_self);
    try testing.expectEqualStrings("5", e.what.message.thread_id);
    try testing.expectEqualStrings("999", proto.fieldStr(e.what.message.data, "idTo").?);
    e.deinit();
    e = l.events.tryPop().?;
    try testing.expect(e.what == .undo);
    try testing.expectEqualStrings("5", e.what.undo.thread_id);
    e.deinit();
    e = l.events.tryPop().?;
    try testing.expect(e.what == .message and e.what.message.kind == .group and e.what.message.is_self);
    try testing.expectEqualStrings("999", proto.fieldStr(e.what.message.data, "uidFrom").?);
    e.deinit();
    e = l.events.tryPop().?;
    try testing.expect(e.what == .old_messages and e.what.old_messages.kind == .group);
    try testing.expectEqual(@as(usize, 2), e.what.old_messages.list.len);
    try testing.expectEqualStrings("g1", e.what.old_messages.list[1].thread_id);
    e.deinit();
    e = l.events.tryPop().?;
    try testing.expectEqualStrings("Invalid header", e.what.err);
    e.deinit();
    e = l.events.tryPop().?;
    try testing.expect(e.what == .err);
    e.deinit();
    try testing.expect(l.events.tryPop() == null);

    // the key starts the pings and says history may be asked for; "another session" closes
    var out: Out = .{};
    defer out.deinit();
    l.st.out = &out;
    l.onFrame(try proto.encodeFrame(a, 1, 1, 1, "{\"key\":\"abc\"}"));
    e = l.events.tryPop().?;
    try testing.expect(e.what == .cipher_key);
    try testing.expectEqualStrings("abc", l.st.cipher_key.?);
    l.onFrame(try proto.encodeFrame(a, 1, 3000, 0, "{}"));
    try testing.expectEqual(@as(?u16, 3000), l.st.closing);
    try testing.expectEqual(@as(u16, 3000), out.tryPop().?.close);
    // stopping ends the ping thread (it holds a reference until it has seen it)
    l.stop();
    var waited: u32 = 0;
    while (l.refs.load(.seq_cst) > 1 and waited < 1000) : (waited += 1) core.sleepMs(2);
    try testing.expectEqual(@as(u32, 1), l.refs.load(.seq_cst));
}
