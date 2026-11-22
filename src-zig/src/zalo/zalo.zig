//! Personal Zalo account (the protocol is a port of zca-js).
//!
//! Login is a QR scan; the session (imei + cookies + user agent) is kept encrypted so the next
//! launch logs in by itself. Zalo has no "list my conversations with history" call for 1-to-1
//! chats, so we keep our own cache: everything the listener receives (live messages and the recent
//! history Zalo replays on connect) is stored here and read by Claude's `zalo_*` tools and by the
//! task list (`zalo_tasks`).
//!
//! On disk: `zalo/cache.json` holds the conversations, names and avatars; each conversation's
//! messages live in their own `zalo/msgs/<id>.json`, written only when that conversation changed.
//!
//! Memory: the store owns what it holds (`Store.a`, `core.gpa` in the app); what a function
//! returns is a copy in the allocator the caller passes (an arena).

const std = @import("std");
const core = @import("../core.zig");
const ipc = @import("../ipc.zig");
const settings = @import("../settings.zig");
const m = @import("../modules.zig");
const unicase = @import("../unicase.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const api = @import("api.zig");
pub const listen = @import("listen.zig");
pub const proto = @import("proto.zig");
pub const types = @import("types.zig");
const dates = @import("dates.zig");
const tools_mod = @import("tools.zig");

pub const INSTRUCTIONS = tools_mod.INSTRUCTIONS;
pub const tools = tools_mod.tools;
pub const callTool = tools_mod.callTool;

pub const ZaloState = types.ZaloState;
pub const ZaloSelf = types.ZaloSelf;
pub const ZaloThread = types.ZaloThread;
pub const ZaloAttachment = types.ZaloAttachment;
pub const Reply = types.Reply;
pub const MentionRef = types.MentionRef;
pub const ZaloMessage = types.ZaloMessage;
pub const WorkMsg = types.WorkMsg;
pub const WorkThread = types.WorkThread;

const Api = api.Api;
const Credentials = api.Credentials;
const QrEvent = api.QrEvent;
const ThreadType = api.ThreadType;
const Action = listen.Action;
const Event = listen.Event;
const Listener = listen.Listener;
const Msg = listen.Msg;
const field = proto.field;
const jnum = proto.jnum;
const jstr = proto.jstr;
const nowMs = proto.nowMs;
const truthy = proto.truthy;

pub const commands = .{
    .{ "zalo_state", zalo_state },
    .{ "zalo_login", zalo_login },
    .{ "zalo_cancel", zalo_cancel },
    .{ "zalo_reconnect", zalo_reconnect },
    .{ "zalo_logout", zalo_logout },
    .{ "zalo_sync_all", zalo_sync_all },
};

/// messages kept per conversation (the tools read ≤ 500, the task list ≤ 400)
pub const MAX_PER_THREAD: usize = 1000;
/// pages of history asked from the socket after connecting, per kind (people / groups)
const OLD_PAGES: u32 = 15;
pub const CACHE_VERSION: u32 = 2;

fn dir(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"zalo"});
}
fn credFile(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{ "zalo", "session.bin" });
}

// ---------------- state ----------------

const StrMap = std.StringArrayHashMapUnmanaged([]const u8);
const StrSet = std.StringArrayHashMapUnmanaged(void);

/// `map[key] = value`, both copied.
fn mapPut(a: Allocator, map: *StrMap, key: []const u8, value: []const u8) !void {
    const v = try a.dupe(u8, value);
    errdefer a.free(v);
    if (map.getPtr(key)) |slot| {
        a.free(slot.*);
        slot.* = v;
        return;
    }
    const k = try a.dupe(u8, key);
    errdefer a.free(k);
    try map.put(a, k, v);
}

/// Adds a copy of `key`; false when it was there.
fn setAdd(a: Allocator, set: *StrSet, key: []const u8) !bool {
    if (set.contains(key)) return false;
    const k = try a.dupe(u8, key);
    errdefer a.free(k);
    try set.put(a, k, {});
    return true;
}

fn mapClear(a: Allocator, map: *StrMap) void {
    for (map.keys(), map.values()) |k, v| {
        a.free(k);
        a.free(v);
    }
    map.clearAndFree(a);
}

fn setClear(a: Allocator, set: *StrSet) void {
    for (set.keys()) |k| a.free(k);
    set.clearAndFree(a);
}

pub const Store = struct {
    a: Allocator,
    loaded: bool = false,
    /// by id (the key is the conversation's own `id`)
    threads: std.StringArrayHashMapUnmanaged(ZaloThread) = .empty,
    /// each conversation's messages, oldest first
    messages: std.StringArrayHashMapUnmanaged(std.ArrayList(ZaloMessage)) = .empty,
    /// userId / groupId → display name (friends, groups, senders seen)
    names: StrMap = .empty,
    /// userId / groupId → avatar url
    avatars: StrMap = .empty,
    state: ZaloState = .{},
    retries: u32 = 0,
    replay_pages: [2]u32 = .{ 0, 0 },
    /// profiles asked for (never asked twice)
    profile_queue: StrSet = .empty,
    profile_timer: bool = false,
    /// conversations whose messages must be written; `meta_dirty`: cache.json must be
    dirty: StrSet = .empty,
    meta_dirty: bool = false,

    pub fn init(a: Allocator) Store {
        return .{ .a = a };
    }

    /// Forgets the conversations and everything about them (not the sign-in state).
    pub fn clear(s: *Store) void {
        const a = s.a;
        for (s.threads.values()) |t| types.free(a, t);
        s.threads.clearAndFree(a);
        for (s.messages.keys(), s.messages.values()) |k, *list| {
            for (list.items) |msg| types.free(a, msg);
            list.deinit(a);
            a.free(k);
        }
        s.messages.clearAndFree(a);
        mapClear(a, &s.names);
        mapClear(a, &s.avatars);
        setClear(a, &s.profile_queue);
        setClear(a, &s.dirty);
        s.meta_dirty = false;
    }

    pub fn deinit(s: *Store) void {
        s.clear();
        s.state.deinit(s.a);
        s.state = .{};
    }

    /// The messages of a conversation (none: an empty list).
    pub fn messagesOf(s: *const Store, thread_id: []const u8) []ZaloMessage {
        return if (s.messages.getPtr(thread_id)) |list| list.items else &.{};
    }
};

var store_mutex: core.Mutex = .{};
var store_data: Store = .{ .a = undefined };

/// The store, locked, with the cache loaded on first use. `unlock()` when done.
pub fn store() *Store {
    store_mutex.lock();
    const s = &store_data;
    if (!s.loaded) {
        s.a = core.gpa;
        s.loaded = true;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        if (dir(arena.allocator())) |d| loadCache(arena.allocator(), d, s) catch {} else |_| {}
    }
    return s;
}

pub fn unlock() void {
    store_mutex.unlock();
}

const Session = struct {
    id: u64,
    api: *Api,
    listener: *Listener,
};

var session_mutex: core.Mutex = .{};
var session: ?Session = null;
var next_session: std.atomic.Value(u64) = .init(1);
/// bumped by every login attempt / logout: a login that finishes after a newer one started is dropped
var gen: std.atomic.Value(u64) = .init(0);
/// a reconnect that waits for its turn runs only while this is still its number
var retry_gen: std.atomic.Value(u64) = .init(0);
var qr_mutex: core.Mutex = .{};
var qr_login: ?*api.QrLogin = null;

/// The logged-in API, online or not (`release()` it).
fn apiAny() ?*Api {
    session_mutex.lock();
    defer session_mutex.unlock();
    return if (session) |s| s.api.retain() else null;
}

fn sessionListener() ?*Listener {
    session_mutex.lock();
    defer session_mutex.unlock();
    return if (session) |s| s.listener.retain() else null;
}

/// The API when signed in and online (`release()` it).
pub fn need(a: Allocator, fail: *core.Fail) !*Api {
    if (apiAny()) |x| {
        const s = store();
        const online = std.mem.eql(u8, s.state.status, "online");
        unlock();
        if (online) return x;
        x.release();
    }
    return fail.set(a, "{s}", .{settings.tr(
        "Not signed in to Zalo. Open the Zalo tab in VIBE CODE and scan the QR code (or click Reconnect).",
        "Zalo chưa đăng nhập. Mở tab Zalo trong VIBE CODE và quét QR (hoặc bấm Kết nối lại).",
    )});
}

/// The sign-in state (a copy in `a`).
pub fn state(a: Allocator) !ZaloState {
    const s = store();
    defer unlock();
    return s.state.clone(a);
}

const Change = union(enum) { keep, clear, set: []const u8 };

const Patch = struct {
    status: ?[]const u8 = null,
    qr: Change = .keep,
    scanned: Change = .keep,
    err: Change = .keep,
};

fn change(a: Allocator, slot: *?[]const u8, c: Change) void {
    switch (c) {
        .keep => {},
        .clear => types.setOpt(a, slot, null) catch {},
        .set => |v| types.setOpt(a, slot, v) catch {},
    }
}

fn patchState(s: *Store, p: Patch) void {
    if (p.status) |x| s.state.status = x;
    change(s.a, &s.state.qr, p.qr);
    change(s.a, &s.state.scanned, p.scanned);
    change(s.a, &s.state.err, p.err);
}

/// Changes the state and tells the window.
fn setState(p: Patch) void {
    patchState(store(), p);
    unlock();
    emitState();
}

fn emitState() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const st = state(arena.allocator()) catch return;
    core.emit("zalo:state", .{st});
}

fn setMe(s: *Store, me: ?ZaloSelf) !void {
    const copy = try types.clone(s.a, me);
    types.free(s.a, s.state.me);
    s.state.me = copy;
}

// ---------------- cache on disk ----------------

/// cache.json: everything but the messages.
const Meta = struct {
    version: u32 = 0,
    threads: []const ZaloThread = &.{},
    names: std.json.ArrayHashMap([]const u8) = .{},
    avatars: std.json.ArrayHashMap([]const u8) = .{},
    /// version 1 kept every conversation's messages in here too
    messages: ?std.json.ArrayHashMap([]ZaloMessage) = null,

    pub const jsonStringify = types.Json(@This()).jsonStringify;
    pub const jsonParseFromValue = types.Json(@This()).jsonParseFromValue;
    pub const jsonParse = types.Json(@This()).jsonParse;
};

/// A conversation's file name: Zalo ids are digits (groups may carry a letter); anything else is
/// hex-encoded so it can never leave the folder.
pub fn threadFile(a: Allocator, folder: []const u8, id: []const u8) ![]u8 {
    var safe = id.len > 0 and id.len <= 64;
    for (id) |b| {
        if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-')) safe = false;
    }
    // "~" never occurs in a kept-as-is id, so an encoded name can't collide with one
    const name = if (safe)
        try std.fmt.allocPrint(a, "{s}.json", .{id})
    else
        try std.fmt.allocPrint(a, "~{s}.json", .{try proto.hex(a, id)});
    return std.fs.path.join(a, &.{ folder, "msgs", name });
}

/// The newest `MAX_PER_THREAD`, oldest first.
pub fn keepNewest(a: Allocator, list: *std.ArrayList(ZaloMessage)) void {
    if (list.items.len <= MAX_PER_THREAD) return;
    const drop = list.items.len - MAX_PER_THREAD;
    for (list.items[0..drop]) |msg| types.free(a, msg);
    std.mem.copyForwards(ZaloMessage, list.items[0..MAX_PER_THREAD], list.items[drop..]);
    list.shrinkRetainingCapacity(MAX_PER_THREAD);
}

fn tsLess(_: void, x: ZaloMessage, y: ZaloMessage) bool {
    return x.ts < y.ts;
}

/// The messages of a conversation as read from a file, into the store (which copies them).
fn adopt(s: *Store, id: []const u8, list: []const ZaloMessage) !void {
    const from = list.len -| MAX_PER_THREAD;
    var owned: std.ArrayList(ZaloMessage) = .empty;
    errdefer {
        for (owned.items) |msg| types.free(s.a, msg);
        owned.deinit(s.a);
    }
    try owned.ensureTotalCapacity(s.a, list.len - from);
    for (list[from..]) |msg| owned.appendAssumeCapacity(try types.clone(s.a, msg));
    if (s.messages.getPtr(id)) |old| {
        for (old.items) |msg| types.free(s.a, msg);
        old.deinit(s.a);
        old.* = owned;
        return;
    }
    const k = try s.a.dupe(u8, id);
    errdefer s.a.free(k);
    try s.messages.put(s.a, k, owned);
}

/// Reads the cache in `folder` into `s`. `a`: an arena for what is read on the way.
pub fn loadCache(a: Allocator, folder: []const u8, s: *Store) !void {
    const bytes = core.readFileAlloc(a, try std.fs.path.join(a, &.{ folder, "cache.json" }), 1 << 30) catch return;
    const meta = core.fromJson(Meta, a, bytes) catch return;
    for (meta.threads) |t| {
        const copy = try types.clone(s.a, t);
        if (s.threads.getPtr(copy.id)) |old| {
            // (the key is the old value's id)
            const key = s.threads.getKeyPtr(copy.id).?;
            types.free(s.a, old.*);
            old.* = copy;
            key.* = copy.id;
        } else {
            s.threads.put(s.a, copy.id, copy) catch |e| {
                types.free(s.a, copy);
                return e;
            };
        }
    }
    mapClear(s.a, &s.names);
    mapClear(s.a, &s.avatars);
    for (meta.names.map.keys(), meta.names.map.values()) |k, v| try mapPut(s.a, &s.names, k, v);
    for (meta.avatars.map.keys(), meta.avatars.map.values()) |k, v| try mapPut(s.a, &s.avatars, k, v);
    if (meta.messages) |all| {
        // the old single-file cache: split it up on the next save
        for (all.map.keys(), all.map.values()) |id, list| {
            std.mem.sort(ZaloMessage, list, {}, tsLess);
            _ = try setAdd(s.a, &s.dirty, id);
            try adopt(s, id, list);
        }
        s.meta_dirty = true;
    } else {
        for (s.threads.keys()) |id| {
            const b = core.readFileAlloc(a, try threadFile(a, folder, id), 1 << 30) catch continue;
            const list = core.fromJson([]ZaloMessage, a, b) catch continue;
            try adopt(s, id, list);
        }
    }
}

pub const Write = struct { path: []const u8, data: []const u8 };

/// What the next save writes: (file, bytes) pairs, encoded under the lock (only what changed).
pub fn takeWrites(a: Allocator, folder: []const u8, s: *Store) ![]Write {
    var out: std.ArrayList(Write) = .empty;
    for (s.dirty.keys()) |id| {
        const data = core.toJson(a, @as([]const ZaloMessage, s.messagesOf(id))) catch continue;
        try out.append(a, .{ .path = try threadFile(a, folder, id), .data = data });
    }
    setClear(s.a, &s.dirty);
    if (s.meta_dirty) {
        s.meta_dirty = false;
        const meta: Meta = .{
            .version = CACHE_VERSION,
            .threads = s.threads.values(),
            .names = .{ .map = s.names },
            .avatars = .{ .map = s.avatars },
        };
        if (core.toJson(a, meta)) |data| {
            try out.append(a, .{ .path = try std.fs.path.join(a, &.{ folder, "cache.json" }), .data = data });
        } else |_| {}
    }
    return out.items;
}

var timers_mutex: core.Mutex = .{};
var save_pending = false;
var ui_pending = false;

/// Write what changed a little later (many messages arriving together make one save).
fn scheduleSave() void {
    timers_mutex.lock();
    defer timers_mutex.unlock();
    if (save_pending) return;
    save_pending = true;
    core.spawn(saveLater, .{});
}

fn saveLater() void {
    core.sleepMs(3000);
    timers_mutex.lock();
    save_pending = false;
    timers_mutex.unlock();
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = dir(a) catch return;
    const writes = blk: {
        const s = store();
        defer unlock();
        break :blk takeWrites(a, folder, s) catch return;
    };
    for (writes) |w| core.writeAtomic(w.path, w.data) catch {};
}

/// Names / avatars changed: the task list re-reads them (once for a burst).
fn notifyUi() void {
    timers_mutex.lock();
    defer timers_mutex.unlock();
    if (ui_pending) return;
    ui_pending = true;
    core.spawn(notifyLater, .{});
}

fn notifyLater() void {
    core.sleepMs(300);
    timers_mutex.lock();
    ui_pending = false;
    timers_mutex.unlock();
    core.emit("zalo:changed", .{@as([]const []const u8, &.{})});
}

// ---------------- parsing Zalo messages ----------------

pub fn attachLabel(kind: []const u8) []const u8 {
    const labels = [_]struct { []const u8, []const u8 }{
        .{ "photo", "Ảnh" },      .{ "video", "Video" }, .{ "voice", "Tin nhắn thoại" },
        .{ "sticker", "Sticker" }, .{ "gif", "GIF" },     .{ "file", "File" },
        .{ "link", "Link" },       .{ "location", "Vị trí" }, .{ "card", "Danh thiếp" },
    };
    for (labels) |l| if (std.mem.eql(u8, kind, l[0])) return l[1];
    return "Tin nhắn";
}

const blank = " \t\r\n\x0b\x0c";

fn parseJsonObj(a: Allocator, v: ?Value) Value {
    const x = v orelse return .null;
    if (x == .object) return x;
    if (x == .string and std.mem.startsWith(u8, std.mem.trim(u8, x.string, blank), "{")) {
        const parsed = proto.parseJson(a, x.string) catch return .null;
        if (parsed == .object) return parsed;
    }
    return .null;
}

/// A string that is not blank, trimmed.
fn vstr(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    if (x != .string) return null;
    const t = std.mem.trim(u8, x.string, blank);
    return if (t.len > 0) t else null;
}

/// A number above zero.
fn vnum(v: ?Value) ?f64 {
    const n = jnum(v);
    return if (std.math.isFinite(n) and n > 0) n else null;
}

/// A number as Rust's `as i64` gives it (NaN is 0, the ends are clamped).
fn toInt(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 9.2233720368547758e18) return std.math.maxInt(i64);
    if (f <= -9.2233720368547758e18) return std.math.minInt(i64);
    return @intFromFloat(f);
}

/// What an attachment message carries, in one shape (allocated in `a`).
pub fn parseAttachment(a: Allocator, msg_type: []const u8, content: Value) !?ZaloAttachment {
    if (content != .object) return null;
    const c = content;
    const p = parseJsonObj(a, field(c, "params"));
    var att: ZaloAttachment = .{ .url = vstr(field(c, "href")), .thumb = vstr(field(c, "thumb")), .title = vstr(field(c, "title")), .desc = vstr(field(c, "description")) };
    const t = if (std.mem.startsWith(u8, msg_type, "chat.")) msg_type[5..] else if (std.mem.startsWith(u8, msg_type, "share.")) msg_type[6..] else msg_type;
    const duration: ?f64 = if (vnum(field(p, "duration"))) |d| d / 1000.0 else null;
    if (std.mem.eql(u8, t, "photo") or std.mem.eql(u8, t, "doodle")) {
        att.kind = "photo";
        att.url = vstr(field(p, "hd")) orelse vstr(field(p, "rawUrl")) orelse att.url;
        att.width = vnum(field(p, "width"));
        att.height = vnum(field(p, "height"));
    } else if (std.mem.startsWith(u8, t, "video")) {
        att.kind = "video";
        att.width = vnum(field(p, "video_width"));
        att.height = vnum(field(p, "video_height"));
        att.duration = duration;
    } else if (std.mem.eql(u8, t, "voice")) {
        att.kind = "voice";
        att.duration = duration;
    } else if (std.mem.eql(u8, t, "gif")) {
        att.kind = "gif";
        att.width = vnum(field(p, "width"));
        att.height = vnum(field(p, "height"));
    } else if (std.mem.eql(u8, t, "sticker")) {
        return if (vnum(field(c, "id")) != null) ZaloAttachment{ .kind = "sticker" } else null;
    } else if (std.mem.eql(u8, t, "file")) {
        att.kind = "file";
        att.size = vnum(field(p, "fileSize"));
        att.ext = if (vstr(field(p, "fileExt"))) |e| try unicase.lowerStr(a, e) else null;
    } else if (std.mem.startsWith(u8, t, "location")) {
        att.kind = "location";
    } else if (std.mem.eql(u8, t, "recommended") or std.mem.eql(u8, t, "link")) {
        const act = vstr(field(c, "action")) orelse "";
        if (std.mem.indexOf(u8, act, "user") != null) {
            att.kind = "card";
            att.desc = vstr(field(p, "phone")) orelse att.desc;
        } else att.kind = "link";
    } else att.kind = "other";
    return att;
}

/// Readable text for any Zalo message: plain text as is, attachments as "[kind] title url".
pub fn contentText(a: Allocator, att: ?ZaloAttachment, content: Value) ![]const u8 {
    if (content == .string) return content.string;
    const x = att orelse return "[tin nhắn]";
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "[{s}]", .{try unicase.lowerStr(a, attachLabel(x.kind))});
    var seen: [3][]const u8 = undefined;
    var n: usize = 0;
    for ([_]?[]const u8{ x.title, x.desc, x.url }) |part| {
        const v = part orelse continue;
        const dup = for (seen[0..n]) |s| {
            if (std.mem.eql(u8, s, v)) break true;
        } else false;
        if (dup) continue;
        seen[n] = v;
        n += 1;
        try out.print(a, " {s}", .{v});
    }
    return out.items;
}

/// One line for the conversation list (allocated in `a`).
pub fn previewOf(a: Allocator, msg: ZaloMessage) ![]const u8 {
    if (msg.recalled == true) return "Tin nhắn đã thu hồi";
    const x = msg.att orelse return msg.text;
    const k = x.kind;
    if (std.mem.eql(u8, k, "file")) return std.fmt.allocPrint(a, "📎 {s}", .{x.title orelse "File"});
    if (std.mem.eql(u8, k, "photo")) return std.fmt.allocPrint(a, "🖼 {s}", .{x.title orelse "Ảnh"});
    if (std.mem.eql(u8, k, "video")) return std.fmt.allocPrint(a, "🎬 {s}", .{x.title orelse "Video"});
    if (std.mem.eql(u8, k, "voice")) return "🎤 Tin nhắn thoại";
    if (std.mem.eql(u8, k, "sticker")) return "Sticker";
    if (std.mem.eql(u8, k, "gif")) return "GIF";
    if (std.mem.eql(u8, k, "link")) return std.fmt.allocPrint(a, "🔗 {s}", .{x.title orelse x.url orelse "Link"});
    if (std.mem.eql(u8, k, "location")) return std.fmt.allocPrint(a, "📍 {s}", .{x.title orelse "Vị trí"});
    if (std.mem.eql(u8, k, "card")) return std.fmt.allocPrint(a, "👤 {s}", .{x.title orelse "Danh thiếp"});
    return x.title orelse msg.text;
}

/// The first `n` characters of `s`.
pub fn firstChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len and count < n) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
    }
    return s[0..i];
}

fn refreshThreadLast(s: *Store, thread_id: []const u8) !void {
    const list = s.messagesOf(thread_id);
    if (list.len == 0) return;
    const last = list[list.len - 1];
    const t = s.threads.getPtr(thread_id) orelse return;
    var arena: std.heap.ArenaAllocator = .init(s.a);
    defer arena.deinit();
    const preview = firstChars(try previewOf(arena.allocator(), last), 200);
    const line = if (last.group and !last.mine) try std.fmt.allocPrint(s.a, "{s}: {s}", .{ last.from_name, preview }) else try s.a.dupe(u8, preview);
    s.a.free(t.last);
    t.last = line;
    t.last_ts = last.ts;
}

/// A message of the socket in our shape (allocated in `a`, pointing into `msg.data`).
pub fn toMessage(a: Allocator, s: *const Store, msg: Msg) !ZaloMessage {
    const d = msg.data;
    const content = field(d, "content") orelse Value{ .null = {} };
    const msg_type = try jstr(a, field(d, "msgType"));
    const att = try parseAttachment(a, msg_type, content);
    const uid_from = try jstr(a, field(d, "uidFrom"));
    const from_id = if (msg.is_self) (if (s.state.me) |me| me.id else uid_from) else uid_from;
    const q: ?Value = if (truthy(field(d, "quote"))) field(d, "quote") else null;
    var mentions: ?[]const types.MentionRef = null;
    if (field(d, "mentions")) |list| if (list == .array and list.array.items.len > 0) {
        const out = try a.alloc(types.MentionRef, list.array.items.len);
        for (out, list.array.items) |*o, x| o.* = .{ .uid = try jstr(a, field(x, "uid")), .pos = toInt(jnum(field(x, "pos"))), .len = toInt(jnum(field(x, "len"))) };
        mentions = out;
    };
    const d_name = dName(d);
    const ts = jnum(field(d, "ts"));
    const qmsg: ?[]const u8 = if (truthy(field(q, "msg"))) try jstr(a, field(q, "msg")) else null;
    const id_value = field(d, "msgId");
    return .{
        // no id at all: "" (jstr would give "undefined", and every such message would share it)
        .id = if (id_value != null and id_value.? != .null) try jstr(a, id_value) else "",
        .thread_id = msg.thread_id,
        .group = msg.kind == .group,
        .from_id = from_id,
        .from_name = if (msg.is_self) "Tôi" else d_name orelse blk: {
            const known = s.names.get(uid_from);
            break :blk if (known != null and known.?.len > 0) known.? else uid_from;
        },
        .mine = msg.is_self,
        .ts = if (std.math.isFinite(ts) and ts != 0) toInt(ts) else nowMs(),
        .kind = msg_type,
        .text = try contentText(a, att, content),
        .att = att,
        .mentions = mentions,
        .quote = if (q != null and (qmsg != null or truthy(field(q, "attach"))))
            try std.fmt.allocPrint(a, "{s}: {s}", .{ try jstr(a, field(q, "fromD")), qmsg orelse "[tệp đính kèm]" })
        else
            null,
        .reply = if (q != null) Reply{
            .id = try jstr(a, field(q, "globalMsgId")),
            .from = if (field(q, "fromD")) |f| try jstr(a, f) else "",
            .text = qmsg orelse if (truthy(field(q, "attach"))) "[tệp đính kèm]" else "",
        } else null,
    };
}

/// The sender's display name a message carries, when it has one.
fn dName(d: Value) ?[]const u8 {
    const n = proto.fieldStr(d, "dName") orelse return null;
    return if (n.len > 0) n else null;
}

/// Put a copy of `msg` in its place (the list stays sorted by time). Null: already there.
///
/// Messages arrive almost always newest-last, so this is a binary search plus a look at the few
/// messages with the same timestamp — not a scan of the whole conversation per message.
pub fn insertSorted(a: Allocator, list: *std.ArrayList(ZaloMessage), msg: ZaloMessage) !?usize {
    const from = std.sort.partitionPoint(ZaloMessage, list.items, msg.ts, struct {
        fn before(ts: i64, x: ZaloMessage) bool {
            return x.ts < ts;
        }
    }.before);
    var to = from;
    while (to < list.items.len and list.items[to].ts == msg.ts) : (to += 1) {
        if (std.mem.eql(u8, list.items[to].id, msg.id)) return null;
    }
    const copy = try types.clone(a, msg);
    list.insert(a, to, copy) catch |e| {
        types.free(a, copy);
        return e;
    };
    return to;
}

/// What `ingestInto` leaves for afterwards (outside the lock); the ids live in the caller's arena.
pub const Ingested = struct {
    /// conversations that got new messages
    touched: StrSet = .empty,
    /// group members whose avatar we don't have yet
    profiles: StrSet = .empty,
};

/// Store messages in `s`: sorted, without duplicates, capped per conversation; conversations
/// are created as they first show up and named from what the messages tell. `a`: the caller's
/// arena, for the work on the way and the result.
pub fn ingestInto(s: *Store, a: Allocator, list: []const Msg) !Ingested {
    var out: Ingested = .{};
    for (list) |item| {
        const msg = try toMessage(a, s, item);
        if (msg.id.len == 0) continue;
        const d_name = dName(item.data);
        if (!item.is_self) if (d_name) |n| {
            const old = s.names.get(msg.from_id);
            if (old == null or !std.mem.eql(u8, old.?, n)) {
                try mapPut(s.a, &s.names, msg.from_id, n);
                s.meta_dirty = true;
            }
        };
        if (!s.messages.contains(item.thread_id)) {
            const k = try s.a.dupe(u8, item.thread_id);
            errdefer s.a.free(k);
            try s.messages.put(s.a, k, .empty);
        }
        const arr = s.messages.getPtr(item.thread_id).?;
        const pos = try insertSorted(s.a, arr, msg) orelse continue;
        const newest = pos + 1 == arr.items.len;
        keepNewest(s.a, arr);
        if (!s.threads.contains(item.thread_id)) {
            const t = try types.clone(s.a, ZaloThread{
                .id = item.thread_id,
                .group = msg.group,
                .name = s.names.get(item.thread_id) orelse "",
                .avatar = s.avatars.get(item.thread_id),
            });
            s.threads.put(s.a, t.id, t) catch |e| {
                types.free(s.a, t);
                return e;
            };
        }
        if (s.threads.getPtr(item.thread_id)) |t| {
            if (t.name.len == 0 and !msg.group and !msg.mine) if (d_name) |n| try types.setStr(s.a, &t.name, n);
        }
        if (newest) try refreshThreadLast(s, item.thread_id);
        if (msg.group and !msg.mine and !s.avatars.contains(msg.from_id)) try out.profiles.put(a, try a.dupe(u8, msg.from_id), {});
        _ = try setAdd(s.a, &s.dirty, item.thread_id);
        s.meta_dirty = true;
        try out.touched.put(a, try a.dupe(u8, item.thread_id), {});
    }
    return out;
}

/// Store messages. `live`: just arrived (the task list looks at them right away).
fn ingest(list: []const Msg, live: bool) void {
    if (list.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const got = blk: {
        const s = store();
        defer unlock();
        break :blk ingestInto(s, a, list) catch return;
    };
    for (got.profiles.keys()) |uid| wantProfile(uid);
    if (got.touched.count() == 0) return;
    scheduleSave();
    if (live and @hasDecl(m.zalo_tasks, "onIngest")) m.zalo_tasks.onIngest(got.touched.keys());
}

/// Conversations with something addressed to me since `since`: every personal chat with an
/// incoming message, and groups where someone @mentioned me or replied to me — with my own later
/// messages, so it's clear what I answered. `only`: just these conversations.
pub fn workFeed(a: Allocator, since: i64, max_threads: usize, max_msgs: usize, only: ?[]const []const u8) ![]WorkThread {
    const s = store();
    defer unlock();
    return workFeedIn(a, s, since, max_threads, max_msgs, only);
}

fn toMe(t: ZaloThread, me: ?[]const u8, mine: *const std.StringHashMapUnmanaged(void), msg: ZaloMessage) bool {
    if (msg.mine) return false;
    if (!t.group) return true;
    if (msg.mentions) |list| if (me) |id| {
        for (list) |x| if (std.mem.eql(u8, x.uid, id)) return true;
    };
    if (msg.reply) |r| return mine.contains(r.id);
    return false;
}

pub fn workFeedIn(a: Allocator, s: *const Store, since: i64, max_threads: usize, max_msgs: usize, only: ?[]const []const u8) ![]WorkThread {
    const me: ?[]const u8 = if (s.state.me) |x| x.id else null;
    var out: std.ArrayList(WorkThread) = .empty;
    var threads: std.ArrayList(ZaloThread) = .empty;
    if (only) |ids| {
        for (ids) |id| if (s.threads.get(id)) |t| try threads.append(a, t);
    } else try threads.appendSlice(a, s.threads.values());
    for (threads.items) |t| {
        const arr = s.messagesOf(t.id);
        if (arr.len == 0 or arr[arr.len - 1].ts < since) continue;
        // only the recent part is looked at (the list is sorted by time)
        const recent_from = std.sort.partitionPoint(ZaloMessage, arr, since, struct {
            fn before(ts: i64, x: ZaloMessage) bool {
                return x.ts < ts;
            }
        }.before);
        var mine: std.StringHashMapUnmanaged(void) = .empty;
        for (arr) |x| if (x.mine) try mine.put(a, x.id, {});
        var recent: std.ArrayList(ZaloMessage) = .empty;
        for (arr[recent_from..]) |x| if (x.recalled != true) try recent.append(a, x);
        const first = for (recent.items, 0..) |x, i| {
            if (toMe(t, me, &mine, x)) break i;
        } else continue;
        var pick: std.ArrayList(ZaloMessage) = .empty;
        for (recent.items[first..]) |x| if (!t.group or x.mine or toMe(t, me, &mine, x)) try pick.append(a, x);
        const chosen = pick.items[pick.items.len -| max_msgs..];
        const msgs = try a.alloc(WorkMsg, chosen.len);
        for (msgs, chosen) |*o, x| {
            const body = if (x.text.len == 0) try previewOf(a, x) else x.text;
            const text = if (x.reply) |r| try std.fmt.allocPrint(a, "[trả lời {s}: \"{s}\"] {s}", .{ r.from, firstChars(r.text, 80), body }) else body;
            o.* = .{
                .id = try a.dupe(u8, x.id),
                .ts = x.ts,
                .from = if (x.mine) "Tôi" else try a.dupe(u8, x.from_name),
                .from_id = try a.dupe(u8, x.from_id),
                .mine = x.mine,
                .to_me = toMe(t, me, &mine, x),
                .text = try a.dupe(u8, firstChars(text, 600)),
            };
        }
        try out.append(a, .{ .thread_id = try a.dupe(u8, t.id), .name = try a.dupe(u8, if (t.name.len == 0) t.id else t.name), .group = t.group, .msgs = msgs });
    }
    std.mem.sort(WorkThread, out.items, {}, struct {
        fn newer(_: void, x: WorkThread, y: WorkThread) bool {
            const xt = if (x.msgs.len > 0) x.msgs[x.msgs.len - 1].ts else 0;
            const yt = if (y.msgs.len > 0) y.msgs[y.msgs.len - 1].ts else 0;
            return xt > yt;
        }
    }.newer);
    return out.items[0..@min(out.items.len, max_threads)];
}

/// My own user id, once signed in (a copy in `a`).
pub fn selfId(a: Allocator) ?[]u8 {
    const s = store();
    defer unlock();
    return if (s.state.me) |me| a.dupe(u8, me.id) catch null else null;
}

/// A user's avatar url, if known (queues a profile fetch otherwise). A copy in `a`.
pub fn avatarOf(a: Allocator, user_id: []const u8) ?[]u8 {
    const found = blk: {
        const s = store();
        defer unlock();
        break :blk if (s.avatars.get(user_id)) |url| a.dupe(u8, url) catch null else null;
    };
    if (found == null) wantProfile(user_id);
    return found;
}

// ---------------- profiles, fetched lazily ----------------

fn wantProfile(uid: []const u8) void {
    if (uid.len == 0) return;
    const signed_in = apiAny() orelse return;
    signed_in.release();
    const s = store();
    defer unlock();
    const added = setAdd(s.a, &s.profile_queue, uid) catch return;
    if (!added or s.profile_timer) return;
    s.profile_timer = true;
    core.spawn(flushProfilesLater, .{});
}

fn flushProfilesLater() void {
    core.sleepMs(800);
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    {
        const s = store();
        defer unlock();
        s.profile_timer = false;
        for (s.profile_queue.keys()) |id| {
            if (ids.items.len == 100) break;
            if (!s.avatars.contains(id)) ids.append(a, a.dupe(u8, id) catch return) catch return;
        }
    }
    const x = apiAny() orelse return;
    defer x.release();
    if (ids.items.len == 0) return;
    var fail: core.Fail = .{};
    const r = x.getUserInfo(a, ids.items, &fail) catch return;
    const changed = blk: {
        const s = store();
        defer unlock();
        break :blk applyProfiles(s, r) catch false;
    };
    if (changed) {
        scheduleSave();
        notifyUi();
    }
}

/// `getUserInfo`'s answer into names / avatars. Whether anything changed.
pub fn applyProfiles(s: *Store, r: Value) !bool {
    var any = false;
    const profiles = field(r, "changed_profiles") orelse return false;
    if (profiles != .object) return false;
    var it = profiles.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const p = e.value_ptr.*;
        const id = if (std.mem.endsWith(u8, k, "_0")) k[0 .. k.len - 2] else k;
        const avatar = vstr(field(p, "avatar"));
        const name = vstr(field(p, "displayName")) orelse vstr(field(p, "zaloName"));
        if (avatar) |av| {
            try mapPut(s.a, &s.avatars, id, av);
            any = true;
        }
        if (name) |n| {
            try mapPut(s.a, &s.names, id, n);
            any = true;
        }
        if (s.threads.getPtr(id)) |t| {
            if (avatar) |av| try types.setOpt(s.a, &t.avatar, av);
            if (t.name.len == 0) try types.setStr(s.a, &t.name, name orelse "");
        }
    }
    if (any) s.meta_dirty = true;
    return any;
}

// ---------------- recalls ----------------

fn recallLocally(a: Allocator, msg: *ZaloMessage) !void {
    try types.setStr(a, &msg.text, "Tin nhắn đã được thu hồi");
    msg.recalled = true;
    types.free(a, msg.att);
    msg.att = null;
    types.free(a, msg.reply);
    msg.reply = null;
}

/// A message was recalled. Whether it was one we have. `a`: an arena for the work on the way.
pub fn applyUndoIn(s: *Store, a: Allocator, u: Action) !bool {
    const id = try jstr(a, field(field(u.data, "content"), "globalMsgId"));
    const list = s.messagesOf(u.thread_id);
    var i = list.len;
    const found = while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, list[i].id, id)) break &list[i];
    } else return false;
    try recallLocally(s.a, found);
    try refreshThreadLast(s, u.thread_id);
    _ = try setAdd(s.a, &s.dirty, u.thread_id);
    s.meta_dirty = true;
    return true;
}

// ---------------- session ----------------

/// Keeps the session for the next launch, sealed. Without the `secure` module nothing is
/// written (there is no saved login then).
fn saveCreds(a: Allocator, c: Credentials) void {
    if (!@hasDecl(m.secure, "seal")) return;
    const raw = core.toJson(a, c) catch return;
    const body = if (m.secure.seal(a, raw)) |sealed|
        std.mem.concat(a, u8, &.{ "E1", sealed }) catch return
    else |_|
        std.mem.concat(a, u8, &.{ "P1", raw }) catch return;
    core.writeAtomic(credFile(a) catch return, body) catch {};
}

fn readCreds(a: Allocator) ?Credentials {
    const b = core.readFileAlloc(a, credFile(a) catch return null, 64 << 20) catch return null;
    if (b.len < 2) return null;
    const raw = if (std.mem.eql(u8, b[0..2], "E1")) blk: {
        if (!@hasDecl(m.secure, "open")) return null;
        break :blk m.secure.open(a, b[2..]) catch return null;
    } else b[2..];
    return core.fromJson(Credentials, a, raw) catch null;
}

/// Takes over the caller's reference to `x`.
fn afterLogin(a: Allocator, x: *Api) void {
    var fail: core.Fail = .{};
    const listener = Listener.create(a, x, &fail) catch |e| {
        x.release();
        return setState(.{ .status = "error", .err = .{ .set = fail.text(e) } });
    };
    const id = next_session.fetchAdd(1, .seq_cst);
    session_mutex.lock();
    const old = session;
    session = .{ .id = id, .api = x, .listener = listener };
    session_mutex.unlock();
    if (old) |o| {
        o.listener.stop();
        o.listener.release();
        o.api.release();
    }
    {
        const s = store();
        defer unlock();
        s.retries = 0;
        patchState(s, .{ .status = "online", .qr = .clear, .err = .clear });
        // who it is: the name and avatar we had until the profile is back
        const prev: ZaloSelf = s.state.me orelse .{};
        setMe(s, .{ .id = x.uid, .name = prev.name, .avatar = prev.avatar }) catch {};
    }
    emitState();
    core.spawn(loadAccount, .{x.retain()});
    core.spawn(loadNamesJob, .{x.retain()});
    if (std.Thread.spawn(.{}, runEvents, .{ id, listener.retain() })) |t| t.detach() else |_| listener.release();
    listener.start(a, true, &fail) catch |e| {
        // nothing will ever close the socket: let the event loop go
        listener.events.close();
        setState(.{ .status = "error", .err = .{ .set = fail.text(e) } });
    };
}

fn loadAccount(x: *Api) void {
    defer x.release();
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    const r = x.fetchAccountInfo(a, &fail) catch return;
    const p = field(r, "profile");
    {
        const s = store();
        defer unlock();
        setMe(s, .{
            .id = x.uid,
            .name = vstr(field(p, "displayName")) orelse vstr(field(p, "zaloName")) orelse "",
            .avatar = proto.fieldStr(p, "avatar") orelse "",
        }) catch {};
    }
    emitState();
}

fn loadNamesJob(x: *Api) void {
    defer x.release();
    loadNames(x);
}

fn isCurrent(id: u64) bool {
    session_mutex.lock();
    defer session_mutex.unlock();
    return if (session) |s| s.id == id else false;
}

/// Live messages that arrive together, as one batch (in `batch`): one lock, one save, one
/// task-list look. Returns the event that ended the batch, if one did.
pub fn nextBatch(first: Event, queue: *listen.Queue(Event), batch: *std.ArrayList(Event)) ?Event {
    batch.clearRetainingCapacity();
    if (first.what != .message) return first;
    batch.append(core.gpa, first) catch {
        first.deinit();
        return null;
    };
    while (batch.items.len < 500) {
        const e = queue.tryPop() orelse break;
        if (e.what != .message) return e;
        batch.append(core.gpa, e) catch e.deinit();
    }
    return null;
}

fn runEvents(id: u64, l: *Listener) void {
    defer l.release();
    var batch: std.ArrayList(Event) = .empty;
    defer batch.deinit(core.gpa);
    var live: std.ArrayList(Msg) = .empty;
    defer live.deinit(core.gpa);
    while (l.events.pop()) |first| {
        const rest = nextBatch(first, &l.events, &batch);
        live.clearRetainingCapacity();
        for (batch.items) |e| live.append(core.gpa, e.what.message) catch {};
        ingest(live.items, true);
        for (batch.items) |e| e.deinit();
        const ev = rest orelse continue;
        defer ev.deinit();
        switch (ev.what) {
            .cipher_key => if (isCurrent(id)) requestReplay(l),
            .message => |msg| ingest(&.{msg}, true),
            .old_messages => |old| {
                // the oldest of the page is where the next one starts
                var oldest: ?Msg = null;
                var oldest_ts = std.math.inf(f64);
                for (old.list) |x| {
                    const ts = jnum(field(x.data, "ts"));
                    if (oldest == null or ts < oldest_ts) {
                        oldest = x;
                        if (!std.math.isNan(ts)) oldest_ts = ts;
                    }
                }
                ingest(old.list, false);
                if (old.list.len > 0) {
                    const i: usize = if (old.kind == .user) 0 else 1;
                    const more = blk: {
                        const s = store();
                        defer unlock();
                        s.replay_pages[i] += 1;
                        break :blk s.replay_pages[i] < OLD_PAGES;
                    };
                    if (more) {
                        var buf: [64]u8 = undefined;
                        var fba: std.heap.FixedBufferAllocator = .init(&buf);
                        l.requestOldMessages(old.kind, jstr(fba.allocator(), field(oldest.?.data, "msgId")) catch null);
                    }
                }
            },
            .undo => |u| {
                var arena: std.heap.ArenaAllocator = .init(core.gpa);
                defer arena.deinit();
                const changed = blk: {
                    const s = store();
                    defer unlock();
                    break :blk applyUndoIn(s, arena.allocator(), u) catch false;
                };
                if (changed) scheduleSave();
            },
            .closed => |code| {
                onClosed(id, code);
                break;
            },
            .err => |text| if (core.debug) std.log.debug("zalo listener: {s}", .{text}),
        }
    }
}

fn onClosed(id: u64, code: u16) void {
    if (!isCurrent(id)) return;
    // 3000: the account opened Zalo Web somewhere else — only one web session may listen
    if (code == 3000) {
        return setState(.{ .status = "error", .err = .{ .set = settings.tr(
            "Zalo Web was opened somewhere else, so this session was cut off. Click Reconnect.",
            "Zalo Web đang mở ở nơi khác nên phiên này bị ngắt. Bấm Kết nối lại.",
        ) } });
    }
    const retries: ?u32 = blk: {
        const s = store();
        defer unlock();
        if (s.retries >= 5) break :blk null;
        s.retries += 1;
        break :blk s.retries;
    };
    const n = retries orelse {
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} ({d}).", .{ settings.tr("Lost the connection to Zalo", "Mất kết nối Zalo"), code }) catch "";
        return setState(.{ .status = "error", .err = .{ .set = text } });
    };
    setState(.{ .status = "connecting", .err = .clear });
    // (a newer wait, or any reconnect, takes this one's turn away)
    const token = retry_gen.fetchAdd(1, .seq_cst) + 1;
    core.spawn(reconnectLater, .{ token, @as(u64, 2000) * n });
}

fn reconnectLater(token: u64, delay_ms: u64) void {
    core.sleepMs(delay_ms);
    if (retry_gen.load(.seq_cst) != token) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    _ = reconnect(arena.allocator(), true) catch {};
}

fn requestReplay(l: *Listener) void {
    {
        const s = store();
        defer unlock();
        s.replay_pages = .{ 0, 0 };
    }
    l.requestOldMessages(.user, null);
    l.requestOldMessages(.group, null);
}

fn messageCount() i64 {
    const s = store();
    defer unlock();
    var n: usize = 0;
    for (s.messages.values()) |list| n += list.items.len;
    return @intCast(n);
}

const PageJob = struct {
    x: *Api,
    id: []const u8,

    /// One group's latest page, stored.
    fn run(job: PageJob) void {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        var fail: core.Fail = .{};
        const page = job.x.getCloudMessage(arena.allocator(), job.id, null, false, &fail) catch return;
        ingest(page.msgs, false);
    }
};

/// "Đồng bộ tất cả": names, the socket replay again, and the latest page of every group.
/// Returns how many new messages came in.
pub fn syncAll(a: Allocator, fail: *core.Fail) !i64 {
    const x = try need(a, fail);
    defer x.release();
    const before = messageCount();
    loadNames(x);
    if (sessionListener()) |l| {
        defer l.release();
        requestReplay(l);
    }
    var groups: std.ArrayList([]const u8) = .empty;
    {
        const s = store();
        defer unlock();
        for (s.threads.values()) |t| if (t.group) try groups.append(a, try a.dupe(u8, t.id));
    }
    // four at a time
    var i: usize = 0;
    while (i < groups.items.len) : (i += 4) {
        var threads: [4]?std.Thread = @splat(null);
        for (groups.items[i..@min(i + 4, groups.items.len)], 0..) |id, k| {
            const job: PageJob = .{ .x = x, .id = id };
            threads[k] = std.Thread.spawn(.{}, PageJob.run, .{job}) catch null;
            if (threads[k] == null) job.run();
        }
        for (threads) |t| if (t) |th| th.join();
    }
    return messageCount() - before;
}

/// Friend and group names / avatars, so conversations show who they are.
fn loadNames(x: *Api) void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    if (x.getAllFriends(a, &fail)) |list| {
        {
            const s = store();
            defer unlock();
            applyFriends(s, a, list) catch {};
        }
        scheduleSave();
        notifyUi();
    } else |_| {}
    const groups = x.getAllGroups(a, &fail) catch return;
    const map = field(groups, "gridVerMap") orelse Value{ .null = {} };
    const ids: []const []const u8 = if (map == .object) map.object.keys() else &.{};
    var i: usize = 0;
    while (i < ids.len) : (i += 50) {
        const info = x.getGroupInfo(a, ids[i..@min(i + 50, ids.len)], &fail) catch break;
        const s = store();
        defer unlock();
        applyGroups(s, a, info) catch {};
    }
    scheduleSave();
    notifyUi();
}

/// `a`: an arena for the work on the way.
pub fn applyFriends(s: *Store, a: Allocator, list: []const Value) !void {
    for (list) |f| {
        const id = try jstr(a, field(f, "userId"));
        if (id.len == 0) continue;
        try mapPut(s.a, &s.names, id, vstr(field(f, "displayName")) orelse vstr(field(f, "zaloName")) orelse "");
        if (vstr(field(f, "avatar"))) |av| try mapPut(s.a, &s.avatars, id, av);
    }
    for (s.threads.values()) |*t| {
        if (t.group) continue;
        if (s.names.get(t.id)) |n| if (n.len > 0) try types.setStr(s.a, &t.name, n);
        if (s.avatars.get(t.id)) |av| try types.setOpt(s.a, &t.avatar, av);
    }
    s.meta_dirty = true;
}

/// Group names / avatars. Groups we have no messages of aren't added as conversations (an
/// account can be in hundreds); their names are still known for when a message comes.
pub fn applyGroups(s: *Store, a: Allocator, info: Value) !void {
    const map = field(info, "gridInfoMap") orelse Value{ .null = {} };
    if (map == .object) {
        var it = map.object.iterator();
        while (it.next()) |e| {
            const gid = e.key_ptr.*;
            const g = e.value_ptr.*;
            const name = try jstr(a, field(g, "name"));
            const avt = vstr(field(g, "avt"));
            try mapPut(s.a, &s.names, gid, name);
            if (avt) |av| try mapPut(s.a, &s.avatars, gid, av);
            if (s.threads.getPtr(gid)) |t| {
                t.group = true;
                try types.setStr(s.a, &t.name, name);
                try types.setOpt(s.a, &t.avatar, avt);
            }
        }
    }
    s.meta_dirty = true;
}

/// Start: log in with the saved session, if any.
pub fn init() void {
    _ = store();
    unlock();
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    if (readCreds(arena.allocator()) != null) core.spawn(reconnectJob, .{});
}

fn reconnectJob() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    _ = reconnect(arena.allocator(), false) catch {};
}

/// Logs in with the saved session. The state afterwards (a copy in `a`).
pub fn reconnect(a: Allocator, auto: bool) !ZaloState {
    _ = retry_gen.fetchAdd(1, .seq_cst);
    if (!auto) {
        store().retries = 0;
        unlock();
    }
    const creds = readCreds(a) orelse {
        setState(.{ .status = "off" });
        return state(a);
    };
    const generation = gen.fetchAdd(1, .seq_cst) + 1;
    stopListener();
    setState(.{ .status = "connecting", .err = .clear });
    var fail: core.Fail = .{};
    const r = api.login(a, creds, &fail);
    if (gen.load(.seq_cst) != generation) {
        if (r) |x| x.release() else |_| {}
    } else if (r) |x| {
        afterLogin(a, x);
    } else |e| {
        const text = if (settings.vi())
            try std.fmt.allocPrint(a, "Không đăng nhập lại được: {s}. Hãy đăng nhập lại bằng QR.", .{fail.text(e)})
        else
            try std.fmt.allocPrint(a, "Could not sign in again: {s}. Sign in again with the QR code.", .{fail.text(e)});
        setState(.{ .status = "error", .err = .{ .set = text } });
    }
    return state(a);
}

fn onQrEvent(generation: u64, ev: QrEvent) void {
    if (gen.load(.seq_cst) != generation) return;
    switch (ev) {
        .generated => |image| {
            const url = std.fmt.allocPrint(core.gpa, "data:image/png;base64,{s}", .{image}) catch return;
            defer core.gpa.free(url);
            setState(.{ .status = "qr", .qr = .{ .set = url }, .scanned = .clear });
        },
        .expired => setState(.{ .status = "qr", .qr = .clear, .err = .{ .set = settings.tr("The QR code has expired.", "Mã QR đã hết hạn.") } }),
        .scanned => |display_name| setState(.{ .scanned = .{ .set = display_name } }),
        .declined => setState(.{ .status = "off", .qr = .clear, .err = .{ .set = settings.tr("The sign-in was declined on the phone.", "Đã từ chối đăng nhập trên điện thoại.") } }),
        .got_login_info => |c| {
            var arena: std.heap.ArenaAllocator = .init(core.gpa);
            defer arena.deinit();
            saveCreds(arena.allocator(), c);
        },
    }
}

/// A QR login, from the code on screen to signed in (or to the reason it ended).
pub fn loginQr(a: Allocator) void {
    const generation = gen.fetchAdd(1, .seq_cst) + 1;
    stopListener();
    setState(.{ .status = "qr", .qr = .clear, .err = .clear });
    const q = api.QrLogin.create() catch return;
    defer q.release();
    {
        // a login still on its way ends here
        qr_mutex.lock();
        const old = qr_login;
        qr_login = q.retain();
        qr_mutex.unlock();
        if (old) |o| {
            o.abort();
            o.release();
        }
    }
    var fail: core.Fail = .{};
    const r = api.loginQr(a, q, generation, onQrEvent, &fail);
    if (gen.load(.seq_cst) != generation) {
        if (r) |x| x.release() else |_| {}
        return;
    }
    {
        qr_mutex.lock();
        const mine = qr_login == q;
        if (mine) qr_login = null;
        qr_mutex.unlock();
        if (mine) q.release();
    }
    const x = r catch |e| {
        const s = store();
        const showing = std.mem.eql(u8, s.state.status, "qr");
        if (showing) {
            // an event already said why (expired, declined): keep its text
            if (s.state.err == null) patchState(s, .{ .status = "off", .qr = .clear, .err = .{ .set = fail.text(e) } }) else patchState(s, .{ .status = "qr", .qr = .clear });
        }
        unlock();
        if (showing) emitState();
        return;
    };
    afterLogin(a, x);
}

pub fn cancelLogin() void {
    qr_mutex.lock();
    const q = qr_login;
    qr_login = null;
    qr_mutex.unlock();
    if (q) |x| {
        x.abort();
        x.release();
        _ = gen.fetchAdd(1, .seq_cst);
    }
    setState(.{ .status = "off", .qr = .clear, .scanned = .clear, .err = .clear });
}

fn stopListener() void {
    session_mutex.lock();
    const old = session;
    session = null;
    session_mutex.unlock();
    if (old) |o| {
        o.listener.stop();
        o.listener.release();
        o.api.release();
    }
}

/// Forget the session and everything cached.
pub fn logout() void {
    _ = retry_gen.fetchAdd(1, .seq_cst);
    _ = gen.fetchAdd(1, .seq_cst);
    stopListener();
    {
        const s = store();
        defer unlock();
        s.clear();
    }
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    if (dir(arena.allocator())) |d| std.Io.Dir.cwd().deleteTree(core.io, d) catch {} else |_| {}
    {
        const s = store();
        defer unlock();
        patchState(s, .{ .status = "off", .qr = .clear, .err = .clear });
        setMe(s, null) catch {};
    }
    emitState();
    core.emit("zalo:changed", .{@as([]const []const u8, &.{})});
}

// ---------------- reading (Claude's tools, the task list) ----------------

fn typeOf(thread_id: []const u8, group: ?bool) ThreadType {
    const g = group orelse blk: {
        const s = store();
        defer unlock();
        break :blk if (s.threads.get(thread_id)) |t| t.group else false;
    };
    return if (g) .group else .user;
}

/// The conversations, newest first; `query` filters by name or id (copies in `a`).
pub fn listThreads(a: Allocator, query: []const u8, limit: usize) ![]ZaloThread {
    const s = store();
    defer unlock();
    return listThreadsIn(a, s, query, limit);
}

pub fn listThreadsIn(a: Allocator, s: *const Store, query: []const u8, limit: usize) ![]ZaloThread {
    const q = try unicase.lowerStr(a, std.mem.trim(u8, query, blank));
    var list: std.ArrayList(ZaloThread) = .empty;
    for (s.threads.values()) |t| {
        if (q.len == 0 or std.mem.indexOf(u8, try unicase.lowerStr(a, t.name), q) != null or std.mem.indexOf(u8, t.id, q) != null) try list.append(a, t);
    }
    std.mem.sort(ZaloThread, list.items, {}, struct {
        fn newer(_: void, x: ZaloThread, y: ZaloThread) bool {
            return x.last_ts > y.last_ts;
        }
    }.newer);
    const out = list.items[0..@min(list.items.len, limit)];
    for (out) |*t| t.* = try types.clone(a, t.*);
    return out;
}

/// The last `limit` messages of a conversation before `before` (null or 0: the newest), oldest
/// first (copies in `a`).
pub fn getMessages(a: Allocator, thread_id: []const u8, limit: usize, before: ?i64) ![]ZaloMessage {
    const s = store();
    defer unlock();
    return getMessagesIn(a, s, thread_id, limit, before);
}

pub fn getMessagesIn(a: Allocator, s: *const Store, thread_id: []const u8, limit: usize, before: ?i64) ![]ZaloMessage {
    const all = s.messagesOf(thread_id);
    // sorted by time: everything before `before` is a prefix
    const end = if (before != null and before.? != 0) std.sort.partitionPoint(ZaloMessage, all, before.?, struct {
        fn earlier(ts: i64, x: ZaloMessage) bool {
            return x.ts < ts;
        }
    }.earlier) else all.len;
    return types.clone(a, all[end -| limit .. end]);
}

/// Older messages of a group from Zalo's cloud (1-to-1 chats only have what the socket replayed).
/// How many came in.
pub fn loadOlder(a: Allocator, thread_id: []const u8, pages: usize, fail: *core.Fail) !i64 {
    const x = try need(a, fail);
    defer x.release();
    var cursor: ?[]const u8 = null;
    var before: i64 = 0;
    {
        const s = store();
        defer unlock();
        const t = s.threads.get(thread_id) orelse return 0;
        if (!t.group) return 0;
        const list = s.messagesOf(thread_id);
        before = @intCast(list.len);
        if (list.len > 0) cursor = try a.dupe(u8, list[0].id);
    }
    var is_old = false;
    for (0..pages) |_| {
        const page = try x.getCloudMessage(a, thread_id, cursor, is_old, fail);
        ingest(page.msgs, false);
        if (!truthy(field(page.data, "hasMore")) or (page.msgs.len == 0 and truthy(field(page.data, "isFiltered")))) break;
        cursor = if (field(page.data, "lastMsgId")) |v| try jstr(a, v) else null;
        is_old = truthy(field(page.data, "isOld"));
    }
    const s = store();
    defer unlock();
    return @as(i64, @intCast(s.messagesOf(thread_id).len)) - before;
}

/// Messages whose text or sender matches, newest first (copies in `a`).
pub fn searchMessages(a: Allocator, query: []const u8, thread_id: ?[]const u8, limit: usize) ![]ZaloMessage {
    const s = store();
    defer unlock();
    return searchMessagesIn(a, s, query, thread_id, limit);
}

pub fn searchMessagesIn(a: Allocator, s: *const Store, query: []const u8, thread_id: ?[]const u8, limit: usize) ![]ZaloMessage {
    const q = try unicase.lowerStr(a, std.mem.trim(u8, query, blank));
    if (q.len == 0) return &.{};
    var hits: std.ArrayList(ZaloMessage) = .empty;
    var low: std.ArrayList(u8) = .empty;
    const lists: []const std.ArrayList(ZaloMessage) = if (thread_id) |t| (if (s.messages.getPtr(t)) |one| one[0..1] else &.{}) else s.messages.values();
    for (lists) |list| for (list.items) |x| {
        low.clearRetainingCapacity();
        try unicase.lowerInto(a, &low, x.text);
        var hit = std.mem.indexOf(u8, low.items, q) != null;
        if (!hit) {
            low.clearRetainingCapacity();
            try unicase.lowerInto(a, &low, x.from_name);
            hit = std.mem.indexOf(u8, low.items, q) != null;
        }
        if (hit) try hits.append(a, x);
    };
    std.mem.sort(ZaloMessage, hits.items, {}, struct {
        fn newer(_: void, x: ZaloMessage, y: ZaloMessage) bool {
            return x.ts > y.ts;
        }
    }.newer);
    const out = hits.items[0..@min(hits.items.len, limit)];
    for (out) |*x| x.* = try types.clone(a, x.*);
    return out;
}

// ---------------- sending ----------------

/// A text to a person or group; the new message's id.
pub fn sendText(a: Allocator, thread_id: []const u8, text: []const u8, group: ?bool, fail: *core.Fail) ![]const u8 {
    const x = try need(a, fail);
    defer x.release();
    const r = try x.sendText(a, text, thread_id, typeOf(thread_id, group), fail);
    return if (field(r, "msgId")) |v| jstr(a, v) else "";
}

/// "HH:MM:SS dd/mm/yyyy" in local time (`toLocaleString('vi-VN', {hour12: false})`).
pub fn fmtTime(a: Allocator, ts: i64) ![]u8 {
    return dates.fmtLocal(a, ts);
}

// ---------------- commands (the Zalo tab) ----------------

fn zalo_state(c: *ipc.Call) !ZaloState {
    return state(c.arena);
}

fn zalo_login(c: *ipc.Call) !void {
    loginQr(c.arena);
}

fn zalo_cancel(_: *ipc.Call) !void {
    cancelLogin();
}

fn zalo_reconnect(c: *ipc.Call) !ZaloState {
    return reconnect(c.arena, false);
}

fn zalo_logout(_: *ipc.Call) !void {
    logout();
}

fn zalo_sync_all(c: *ipc.Call) !i64 {
    var fail: core.Fail = .{};
    return syncAll(c.arena, &fail) catch |e| c.failMsg(fail.text(e));
}

test {
    _ = @import("proto.zig");
    _ = @import("dates.zig");
    _ = @import("cookies.zig");
    _ = @import("types.zig");
    _ = @import("ws.zig");
    _ = @import("api.zig");
    _ = @import("listen.zig");
    _ = @import("tools.zig");
    _ = @import("tests.zig");
}
