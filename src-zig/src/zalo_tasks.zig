//! "Việc của tôi": Claude reads what was sent to me on Zalo (personal chats, @mentions, replies to
//! me) and keeps a checklist — not answered = todo, answered but not finished = doing, reported
//! done = done. Port of src/main/zaloTasks.ts.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const text = @import("text.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const tr = settings.tr;

const WINDOW_DAYS: i64 = 7;
const KEEP_DONE_DAYS: i64 = 14;
const DAY: i64 = 86_400_000;
/// after a message to me: if nothing more arrives for this long, send the batch to Claude
const REALTIME_DELAY_MS: i64 = 30_000;
const MODEL = "haiku";

// ---------------- what this needs from the Zalo module ----------------
// Every call into zalo/zalo.zig is here. In a build without it (`-Donly=zalo_tasks`) there are no
// messages and nobody is signed in. Results are allocated in `a`.

const zalo_types = @import("zalo/types.zig");
const WorkThread = zalo_types.WorkThread;
const WorkMsg = zalo_types.WorkMsg;
const ZaloMessage = zalo_types.ZaloMessage;

const zalo = struct {
    /// Conversations with messages to me since `since` (the ones in `only`, or all).
    fn workFeed(a: Allocator, since: i64, max_threads: usize, max_msgs: usize, only: ?[]const []const u8) []const WorkThread {
        return if (@hasDecl(m.zalo, "workFeed")) m.zalo.workFeed(a, since, max_threads, max_msgs, only) catch &.{} else &.{};
    }

    /// A user's avatar url, if known.
    fn avatarOf(a: Allocator, user_id: []const u8) ?[]const u8 {
        return if (@hasDecl(m.zalo, "avatarOf")) m.zalo.avatarOf(a, user_id) else null;
    }

    /// The last `limit` messages of a conversation, oldest first.
    fn getMessages(a: Allocator, thread_id: []const u8, limit: usize) []const ZaloMessage {
        return if (@hasDecl(m.zalo, "getMessages")) m.zalo.getMessages(a, thread_id, limit, null) catch &.{} else &.{};
    }

    /// Online, or at least an account whose cached messages can be read.
    fn signedIn(a: Allocator) bool {
        if (@hasDecl(m.zalo, "state")) {
            const st = m.zalo.state(a) catch return false;
            return std.mem.eql(u8, st.status, "online") or st.me != null;
        } else return false;
    }

    /// "HH:MM:SS dd/mm/yyyy" in local time.
    fn fmtTime(a: Allocator, ts: i64) []const u8 {
        return if (@hasDecl(m.zalo, "fmtTime")) m.zalo.fmtTime(a, ts) catch "" else @import("zalo/dates.zig").fmtLocal(a, ts) catch "";
    }
};

// ---------------- state ----------------

pub const ZaloTask = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    detail: ?[]const u8 = null,
    threadId: []const u8 = "",
    threadName: []const u8 = "",
    group: bool = false,
    msgId: ?[]const u8 = null,
    from: []const u8 = "",
    fromId: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
    ts: i64 = 0,
    /// todo | doing | done
    status: []const u8 = "",
    manual: ?bool = null,
    updatedAt: i64 = 0,

    pub fn jsonStringify(t: ZaloTask, w: anytype) !void {
        return writeWithoutNulls(t, w);
    }
};

pub const ZaloIncoming = struct {
    threadId: []const u8,
    msgId: []const u8,
    threadName: []const u8,
    group: bool,
    from: []const u8,
    avatar: ?[]const u8 = null,
    text: []const u8,
    ts: i64,

    pub fn jsonStringify(i: ZaloIncoming, w: anytype) !void {
        return writeWithoutNulls(i, w);
    }
};

/// task id → "new" | "updated", in the order they were added
const Unseen = std.StringArrayHashMapUnmanaged([]const u8);

pub const ZaloTasksState = struct {
    tasks: []const ZaloTask,
    running: bool,
    analyzedAt: i64,
    @"error": ?[]const u8,
    incoming: []const ZaloIncoming,
    fresh: []const []const u8,
    changed: []const []const u8,
    unseen: std.json.ArrayHashMap([]const u8),
    dueAt: ?i64,

    pub fn jsonStringify(s: ZaloTasksState, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

/// A struct as a JSON object, its null fields left out (serde's `skip_serializing_if`).
fn writeWithoutNulls(v: anytype, w: anytype) !void {
    try w.beginObject();
    inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
        const x = @field(v, name);
        if (@typeInfo(@TypeOf(x)) == .optional) {
            if (x) |inner| {
                try w.objectField(name);
                try w.write(inner);
            }
        } else {
            try w.objectField(name);
            try w.write(x);
        }
    }
    try w.endObject();
}

/// Everything the lists hold is owned by `core.gpa`.
const Tasks = struct {
    loaded: bool = false,
    tasks: std.ArrayList(ZaloTask) = .empty,
    analyzed_at: i64 = 0,
    running: bool = false,
    err: ?[]const u8 = null,
    again: bool = false,
    /// a batch of messages is waiting (a job sleeps until `due_at`, then analyzes)
    auto: bool = false,
    /// when the waiting batch goes to Claude
    due_at: i64 = 0,
    /// messages to me waiting to become tasks (shown as progress)
    incoming: std.ArrayList(ZaloIncoming) = .empty,
    /// tasks created by the last analysis
    fresh: std.ArrayList([]const u8) = .empty,
    /// tasks whose status the last analysis changed
    changed: std.ArrayList([]const u8) = .empty,
    /// tasks created / changed by Claude that I haven't looked at yet: "new" | "updated"
    /// (the keys are owned, the values are the two literals)
    unseen: Unseen = .empty,
    /// the Zalo tab is on screen in a focused window: changes count as seen right away, no pop-up
    viewing: bool = false,
    /// source messages of tasks I deleted: the analysis never turns them into tasks again
    dismissed: std.ArrayList([]const u8) = .empty,

    fn find(t: *Tasks, id: []const u8) ?*ZaloTask {
        for (t.tasks.items) |*x| if (std.mem.eql(u8, x.id, id)) return x;
        return null;
    }

    fn setUnseen(t: *Tasks, id: []const u8, kind: []const u8) !void {
        const key = try core.gpa.dupe(u8, id);
        errdefer core.gpa.free(key);
        const g = try t.unseen.getOrPut(core.gpa, key);
        if (g.found_existing) core.gpa.free(key);
        g.value_ptr.* = if (std.mem.eql(u8, kind, "new")) "new" else "updated";
    }

    fn dropUnseen(t: *Tasks, id: []const u8) void {
        const i = t.unseen.getIndex(id) orelse return;
        const key = t.unseen.keys()[i];
        t.unseen.orderedRemoveAt(i);
        core.gpa.free(key);
    }

    fn setStrings(list: *std.ArrayList([]const u8), items: []const []const u8) !void {
        for (list.items) |s| core.gpa.free(s);
        list.clearRetainingCapacity();
        for (items) |s| try list.append(core.gpa, try core.gpa.dupe(u8, s));
    }

    fn deinit(t: *Tasks) void {
        for (t.tasks.items) |x| freeStrings(core.gpa, x);
        t.tasks.deinit(core.gpa);
        for (t.incoming.items) |x| freeStrings(core.gpa, x);
        t.incoming.deinit(core.gpa);
        for ([_]*std.ArrayList([]const u8){ &t.fresh, &t.changed, &t.dismissed }) |list| {
            for (list.items) |s| core.gpa.free(s);
            list.deinit(core.gpa);
        }
        for (t.unseen.keys()) |k| core.gpa.free(k);
        t.unseen.deinit(core.gpa);
        if (t.err) |e| core.gpa.free(e);
        t.* = .{};
    }
};

var mutex: core.Mutex = .{};
var state: Tasks = .{};

/// A copy of a struct whose strings (and optional strings) are copied into `a`.
fn cloneStrings(a: Allocator, v: anytype) Allocator.Error!@TypeOf(v) {
    var out = v;
    inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
        const f = &@field(out, name);
        switch (@TypeOf(f.*)) {
            []const u8 => f.* = try a.dupe(u8, f.*),
            ?[]const u8 => if (f.*) |s| {
                f.* = try a.dupe(u8, s);
            },
            else => {},
        }
    }
    return out;
}

fn freeStrings(a: Allocator, v: anytype) void {
    inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
        const f = @field(v, name);
        switch (@TypeOf(f)) {
            []const u8 => a.free(f),
            ?[]const u8 => if (f) |s| a.free(s),
            else => {},
        }
    }
}

/// Replaces a string owned by `core.gpa`.
fn setStr(slot: *[]const u8, v: []const u8) !void {
    const copy = try core.gpa.dupe(u8, v);
    core.gpa.free(slot.*);
    slot.* = copy;
}

fn setOpt(slot: *?[]const u8, v: ?[]const u8) !void {
    const copy: ?[]const u8 = if (v) |s| try core.gpa.dupe(u8, s) else null;
    if (slot.*) |old| core.gpa.free(old);
    slot.* = copy;
}

fn cloneList(a: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (out, items) |*dst, src| dst.* = try a.dupe(u8, src);
    return out;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn nowMs() i64 {
    return @intCast(core.nowMs());
}

fn dir(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"zalo"});
}

fn file(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{ "zalo", "tasks.json" });
}

/// The state, locked; read from disk the first time. Pair with `unlock()`.
fn tasks() *Tasks {
    mutex.lock();
    if (!state.loaded) {
        state.loaded = true;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (file(a)) |path| {
            if (core.readFileAlloc(a, path, 64 << 20)) |bytes| load(&state, a, bytes) catch {} else |_| {}
        } else |_| {}
    }
    return &state;
}

fn unlock() void {
    mutex.unlock();
}

/// Fills `t` from the text of tasks.json (`a` is scratch memory). Entries that do not have the
/// expected shape are skipped.
fn load(t: *Tasks, a: Allocator, bytes: []const u8) !void {
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (d != .object) return;
    if (d.object.get("tasks")) |v| if (v == .array) for (v.array.items) |x| {
        const task = std.json.parseFromValueLeaky(ZaloTask, a, x, .{ .ignore_unknown_fields = true }) catch continue;
        try t.tasks.append(core.gpa, try cloneStrings(core.gpa, task));
    };
    if (d.object.get("analyzedAt")) |v| if (v == .integer) {
        t.analyzed_at = v.integer;
    };
    if (d.object.get("unseen")) |v| if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try t.setUnseen(e.key_ptr.*, e.value_ptr.string);
    };
    if (d.object.get("dismissed")) |v| if (v == .array) for (v.array.items) |x| {
        if (x == .string) try t.dismissed.append(core.gpa, try core.gpa.dupe(u8, x.string));
    };
}

/// The text of tasks.json.
fn fileJson(a: Allocator, t: *const Tasks) ![]u8 {
    return core.toJson(a, .{
        .analyzedAt = t.analyzed_at,
        .dismissed = t.dismissed.items,
        .tasks = t.tasks.items,
        .unseen = std.json.ArrayHashMap([]const u8){ .map = t.unseen },
    });
}

fn save() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const data = blk: {
        const t = tasks();
        defer unlock();
        break :blk fileJson(a, t) catch return;
    };
    core.writeAtomic(file(a) catch return, data) catch {};
}

fn uidOf(t: ZaloTask) ?[]const u8 {
    return t.fromId orelse if (!t.group) t.threadId else null;
}

/// A snapshot for the page, allocated in `a`.
pub fn getTasks(a: Allocator) !ZaloTasksState {
    var list: []ZaloTask = &.{};
    const s: ZaloTasksState = blk: {
        const t = tasks();
        defer unlock();
        list = try a.alloc(ZaloTask, t.tasks.items.len);
        for (list, t.tasks.items) |*dst, x| dst.* = try cloneStrings(a, x);
        const incoming = try a.alloc(ZaloIncoming, t.incoming.items.len);
        for (incoming, t.incoming.items) |*dst, x| dst.* = try cloneStrings(a, x);
        var unseen: Unseen = .empty;
        for (t.unseen.keys(), t.unseen.values()) |k, v| try unseen.put(a, try a.dupe(u8, k), v);
        break :blk .{
            .tasks = list,
            .running = t.running,
            .analyzedAt = t.analyzed_at,
            .@"error" = if (t.err) |e| try a.dupe(u8, e) else null,
            .incoming = incoming,
            .fresh = try cloneList(a, t.fresh.items),
            .changed = try cloneList(a, t.changed.items),
            .unseen = .{ .map = unseen },
            .dueAt = if (t.auto) t.due_at else null,
        };
    };
    // avatars outside the lock (zalo has its own)
    for (list) |*x| x.avatar = if (uidOf(x.*)) |u| zalo.avatarOf(a, u) else null;
    return s;
}

fn broadcast() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const s = getTasks(arena.allocator()) catch return;
    core.emit("zalo:tasks", .{s});
}

pub fn init() void {
    _ = tasks();
    unlock();
}

/// The messages of `feed` that arrived since the last analysis (at most 10 minutes back): the
/// ones to me not yet waiting are added to `add` (with who sent each in `uids`, for the avatar).
/// Returns whether any of them calls for a new analysis.
fn collectIncoming(a: Allocator, t: *const Tasks, feed: []const WorkThread, now: i64, add: *std.ArrayList(ZaloIncoming), uids: *std.ArrayList([]const u8)) !bool {
    var relevant = false;
    const since = @max(t.analyzed_at, now - 10 * 60_000);
    for (feed) |th| for (th.msgs) |msg| {
        if (msg.ts <= since) continue;
        if (msg.to_me) {
            relevant = true;
            const waiting = for (t.incoming.items) |x| {
                if (std.mem.eql(u8, x.msgId, msg.id)) break true;
            } else for (add.items) |x| {
                if (std.mem.eql(u8, x.msgId, msg.id)) break true;
            } else false;
            if (waiting) continue;
            try add.append(a, .{
                .threadId = th.thread_id,
                .msgId = msg.id,
                .threadName = th.name,
                .group = th.group,
                .from = msg.from,
                .text = text.takeChars(msg.text, 160),
                .ts = msg.ts,
            });
            try uids.append(a, msg.from_id);
        } else if (msg.mine) {
            // my reply in a chat with open work
            for (t.tasks.items) |x| {
                if (std.mem.eql(u8, x.threadId, th.thread_id) and !std.mem.eql(u8, x.status, "done")) relevant = true;
            }
        }
    };
    return relevant;
}

/// Realtime: a new message to me (or my reply in a chat with open work) → analyze within seconds.
pub fn onIngest(ids: []const []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const now = nowMs();
    // only the conversations that just got messages (not a scan of every conversation per message)
    const feed = zalo.workFeed(a, now - WINDOW_DAYS * DAY, 40, 40, ids);
    var add: std.ArrayList(ZaloIncoming) = .empty;
    var uids: std.ArrayList([]const u8) = .empty;
    const relevant = blk: {
        const t = tasks();
        defer unlock();
        break :blk collectIncoming(a, t, feed, now, &add, &uids) catch return;
    };
    for (add.items, uids.items) |*i, uid| i.avatar = zalo.avatarOf(a, uid);
    if (!relevant) return;
    {
        const t = tasks();
        defer unlock();
        for (add.items) |i| {
            const copy = cloneStrings(core.gpa, i) catch continue;
            t.incoming.append(core.gpa, copy) catch freeStrings(core.gpa, copy);
        }
        // each new message restarts the wait: the batch goes once the chat is quiet for REALTIME_DELAY
        t.due_at = now + REALTIME_DELAY_MS;
        if (!t.auto) {
            t.auto = true;
            core.spawn(autoAnalyze, .{});
        }
    }
    broadcast();
}

/// Sleeps until the waiting batch is due (the time moves while messages keep coming), then analyzes.
fn autoAnalyze() void {
    while (true) {
        const t = tasks();
        const wait = t.due_at - nowMs();
        if (wait <= 0) t.auto = false;
        unlock();
        if (wait <= 0) break;
        core.sleepMs(@intCast(wait));
    }
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    _ = analyze(arena.allocator()) catch {};
}

const Tag = struct { text: []const u8, color: []const u8 };

fn statusTag(status: []const u8) Tag {
    if (std.mem.eql(u8, status, "doing")) return .{ .text = tr("In progress", "Đang xử lý"), .color = "#d9922e" };
    if (std.mem.eql(u8, status, "done")) return .{ .text = tr("Done", "Hoàn thành"), .color = "#2f9e63" };
    return .{ .text = tr("To do", "Cần làm"), .color = "#e5484d" };
}

const WindowState = struct { exists: bool = false, focused: bool = false, visible: bool = false };

/// UI thread.
fn mainWindowState() WindowState {
    if (!core.is_windows) return .{};
    const w = core.host.win.findWindow(core.host.main_label) orelse return .{};
    return .{ .exists = true, .focused = w.isFocused(), .visible = w.isVisible() };
}

/// UI thread. The taskbar button lights up until the window is brought to the front.
fn requestAttention() void {
    if (!core.is_windows) return;
    const c = core.host.win.c;
    const w = core.host.win.findWindow(core.host.main_label) orelse return;
    var info: c.FLASHWINFO = .{
        .cbSize = @sizeOf(c.FLASHWINFO),
        .hwnd = w.hwnd,
        .dwFlags = c.FLASHW_TRAY | c.FLASHW_TIMERNOFG,
        .uCount = 0,
        .dwTimeout = 0,
    };
    _ = c.FlashWindowEx(&info);
}

/// Badge + Zalo-style pop-ups for tasks Claude just created or changed.
fn announce(a: Allocator, created: []const ZaloTask, updated: []const ZaloTask) void {
    const w = core.host.onUiSync(mainWindowState, .{});
    {
        const t = tasks();
        defer unlock();
        if (t.viewing and w.visible and w.focused) return;
        markUnseen(t, created, updated) catch {};
    }
    if (created.len + updated.len == 0) return;
    if (@hasDecl(m.toast, "show")) {
        var cards: std.ArrayList(m.toast.ToastCard) = .empty;
        for (created) |x| cards.append(a, toastCard(a, x, true)) catch {};
        for (updated) |x| cards.append(a, toastCard(a, x, false)) catch {};
        m.toast.show(cards.items);
    }
    if (w.exists and !w.focused) core.host.onUi(requestAttention, .{});
}

fn markUnseen(t: *Tasks, created: []const ZaloTask, updated: []const ZaloTask) !void {
    for (created) |x| try t.setUnseen(x.id, "new");
    for (updated) |x| {
        if (!std.mem.eql(u8, t.unseen.get(x.id) orelse "", "new")) try t.setUnseen(x.id, "updated");
    }
}

fn toastCard(a: Allocator, x: ZaloTask, new: bool) m.toast.ToastCard {
    const tag: Tag = if (new) .{ .text = tr("New task", "Việc mới"), .color = "#3b82f6" } else statusTag(x.status);
    return .{
        .id = x.id,
        .name = x.from,
        .avatar = if (uidOf(x)) |u| zalo.avatarOf(a, u) else null,
        .title = x.from,
        .tag = .{ .text = tag.text, .color = tag.color },
        .body = x.title,
        .meta = if (x.group) x.threadName else null,
    };
}

/// The Zalo tab is (not) on screen; while it is, everything counts as seen.
pub fn setViewing(on: bool) void {
    tasks().viewing = on;
    unlock();
    if (on) markSeen();
}

pub fn markSeen() void {
    {
        const t = tasks();
        defer unlock();
        if (t.unseen.count() == 0) return;
        for (t.unseen.keys()) |k| core.gpa.free(k);
        t.unseen.clearRetainingCapacity();
    }
    save();
    broadcast();
}

pub fn setStatus(a: Allocator, id: []const u8, status: []const u8) !ZaloTasksState {
    {
        const t = tasks();
        defer unlock();
        if (t.find(id)) |x| {
            try setStr(&x.status, status);
            x.manual = true;
            x.updatedAt = nowMs();
        }
        t.dropUnseen(id);
    }
    save();
    broadcast();
    return getTasks(a);
}

pub fn removeTask(a: Allocator, id: []const u8) !ZaloTasksState {
    {
        const t = tasks();
        defer unlock();
        try removeFrom(t, id);
    }
    save();
    broadcast();
    return getTasks(a);
}

fn removeFrom(t: *Tasks, id: []const u8) !void {
    const index = for (t.tasks.items, 0..) |x, i| {
        if (std.mem.eql(u8, x.id, id)) break i;
    } else null;
    if (index) |at| {
        if (t.tasks.items[at].msgId) |mid| {
            try t.dismissed.append(core.gpa, try core.gpa.dupe(u8, mid));
            // bounded: message ids older than the analysis window can't come back anyway
            const n = t.dismissed.items.len;
            if (n > 500) {
                for (t.dismissed.items[0 .. n - 500]) |s| core.gpa.free(s);
                t.dismissed.replaceRangeAssumeCapacity(0, n - 500, &.{});
            }
        }
        freeStrings(core.gpa, t.tasks.orderedRemove(at));
    }
    t.dropUnseen(id);
}

// ---------------- context for a new chat ----------------

const MAX_DOWNLOAD = 25 * 1024 * 1024;

/// A file name made of `s`: the characters Windows does not allow become "_", whitespace is
/// tidied, at most 80 characters, never empty.
pub fn safeName(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_bad = false;
    for (s) |ch| {
        const bad = ch < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", ch) != null;
        if (!bad) try out.append(a, ch) else if (!in_bad) try out.append(a, '_');
        in_bad = bad;
    }
    const name = text.takeChars(text.trim(try text.collapseWhitespace(a, out.items)), 80);
    return a.dupe(u8, if (name.len == 0) "file" else name);
}

/// The image extension a url ends with (before any "?" or "#"), lower-case; else `fallback`.
fn extOf(url: []const u8, fallback: []const u8) []const u8 {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, url, from, '.')) |dot| : (from = dot + 1) {
        const rest = url[dot + 1 ..];
        for ([_][]const u8{ "png", "jpeg", "jpg", "gif", "webp", "bmp" }) |ext| {
            if (std.ascii.startsWithIgnoreCase(rest, ext) and (rest.len == ext.len or rest[ext.len] == '?' or rest[ext.len] == '#')) return ext;
        }
    }
    return fallback;
}

/// Downloads `url` to `path` through `buf` (MAX_DOWNLOAD bytes: a larger file does not fit and fails).
fn download(a: Allocator, buf: []u8, url: []const u8, path: []const u8) bool {
    var w: std.Io.Writer = .fixed(buf);
    const head = http.stream(a, url, .{}, &w, null, null) catch return false;
    if (head.status < 200 or head.status >= 300) return false;
    core.writeFile(path, w.buffered()) catch return false;
    return true;
}

pub const TaskContext = struct {
    file: []const u8,
    images: []const []const u8,
    files: []const []const u8,
};

/// The messages a task's context shows: a little of what came before the request (the question
/// often builds on it), then everything since, capped.
fn contextMessages(t: ZaloTask, all: []const ZaloMessage) []const ZaloMessage {
    var start: ?usize = null;
    if (t.msgId) |mid| for (all, 0..) |msg, i| {
        if (std.mem.eql(u8, msg.id, mid)) {
            start = i;
            break;
        }
    };
    if (start == null) for (all, 0..) |msg, i| {
        if (msg.ts >= t.ts) {
            start = i;
            break;
        }
    };
    const from = (start orelse all.len -| 30) -| 15;
    return all[from..@min(all.len, from + 120)];
}

/// Everything a coding chat needs about a task: the conversation around it written to a Markdown
/// file, with photos and files sent in that chat downloaded next to it.
pub fn taskContext(a: Allocator, fail: *core.Fail, id: []const u8) !TaskContext {
    const t = blk: {
        const s = tasks();
        defer unlock();
        const x = s.find(id) orelse return fail.set(a, "{s}", .{tr("Task not found", "Không tìm thấy việc này")});
        break :blk try cloneStrings(a, x.*);
    };
    var all: std.ArrayList(ZaloMessage) = .empty;
    for (zalo.getMessages(a, t.threadId, 400)) |msg| {
        if (msg.recalled != true) try all.append(a, msg);
    }
    const out = try core.dataPath(a, &.{ "zalo", "context", t.id });
    std.Io.Dir.cwd().deleteTree(core.io, out) catch {};
    try core.makePath(out);
    var images: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList(u8) = .empty;
    var buf: ?[]u8 = null;
    defer if (buf) |b| core.gpa.free(b);
    var n: usize = 0;
    for (contextMessages(t, all.items)) |msg| {
        var body: []const u8 = try indentBody(a, msg.text);
        if (msg.att) |att| {
            const photo = std.mem.eql(u8, att.kind, "photo") or std.mem.eql(u8, att.kind, "gif");
            if (photo and (att.url != null or att.thumb != null)) {
                const url = att.url orelse att.thumb.?;
                n += 1;
                const path = try std.fs.path.join(a, &.{ out, try std.fmt.allocPrint(a, "img-{d:0>2}.{s}", .{ n, extOf(url, "jpg") }) });
                if (buf == null) buf = try core.gpa.alloc(u8, MAX_DOWNLOAD);
                if (download(a, buf.?, url, path)) {
                    body = try std.fmt.allocPrint(a, "[ảnh] {s}{s}{s}", .{ path, if (att.desc != null) " — " else "", att.desc orelse "" });
                    try images.append(a, path);
                }
            } else if (std.mem.eql(u8, att.kind, "file") and att.url != null and (att.size orelse 0) <= MAX_DOWNLOAD) {
                const name = if (att.title) |title| try safeName(a, title) else blk: {
                    n += 1;
                    break :blk try safeName(a, try std.fmt.allocPrint(a, "file-{d}{s}{s}", .{ n, if (att.ext != null) "." else "", att.ext orelse "" }));
                };
                const path = try std.fs.path.join(a, &.{ out, name });
                if (buf == null) buf = try core.gpa.alloc(u8, MAX_DOWNLOAD);
                if (download(a, buf.?, att.url.?, path)) {
                    body = try std.fmt.allocPrint(a, "[tệp] {s}", .{path});
                    try files.append(a, path);
                }
            }
        }
        if (lines.items.len > 0) try lines.append(a, '\n');
        try lines.appendSlice(a, try contextLine(a, t, msg, zalo.fmtTime(a, msg.ts), body));
    }
    const md = try contextMarkdown(a, t, zalo.fmtTime(a, t.ts), images.items, files.items, lines.items);
    const path = try std.fs.path.join(a, &.{ out, "context.md" });
    try core.writeFile(path, md);
    return .{ .file = path, .images = images.items, .files = files.items };
}

/// A message's text as the body of a list item: its later lines indented under the first.
fn indentBody(a: Allocator, s: []const u8) ![]u8 {
    const unix = try std.mem.replaceOwned(u8, a, s, "\r\n", "\n");
    return std.mem.replaceOwned(u8, a, unix, "\n", "\n  ");
}

fn contextLine(a: Allocator, t: ZaloTask, msg: ZaloMessage, time: []const u8, body: []const u8) ![]u8 {
    const reply = if (msg.reply) |r|
        try std.fmt.allocPrint(a, " _(trả lời {s}: \"{s}\")_", .{ r.from, text.takeChars(try text.collapseWhitespace(a, r.text), 120) })
    else
        "";
    const is_request = if (t.msgId) |mid| std.mem.eql(u8, mid, msg.id) else false;
    return std.fmt.allocPrint(a, "- **{s}** ({s}){s}{s}: {s}", .{
        if (msg.mine) "Tôi" else msg.from_name, time, reply, if (is_request) " ⟵ **yêu cầu**" else "", body,
    });
}

fn contextMarkdown(a: Allocator, t: ZaloTask, time: []const u8, images: []const []const u8, files: []const []const u8, body: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const o = &w.writer;
    try o.print("# Việc từ Zalo: {s}\n\n**Hướng dẫn cho bạn (Claude):** Đây là một việc tôi nhận qua Zalo. Hãy đọc kỹ đoạn chat bên dưới{s}{s}, rồi tìm hiểu code trong project hiện tại liên quan tới yêu cầu. Sau đó tóm tắt lại yêu cầu bằng tiếng Việt, nêu nguyên nhân / vị trí code liên quan và đề xuất cách xử lý. CHƯA sửa code cho tới khi tôi xác nhận.\n\n", .{
        t.title,
        if (images.len == 0) "" else " và XEM TẤT CẢ ảnh đính kèm (dùng Read với đường dẫn ảnh)",
        if (files.len == 0) "" else ", mở các tệp đính kèm",
    });
    try o.print("- Người yêu cầu: {s}", .{t.from});
    if (t.group) try o.print(" (nhóm \"{s}\")", .{t.threadName});
    try o.print("\n- Thời gian: {s}\n- Tóm tắt: {s}\n", .{ time, t.title });
    if (t.detail) |d| try o.print("- Ngữ cảnh: {s}\n", .{d});
    for ([_][]const u8{ "Ảnh đính kèm", "Tệp đính kèm" }, [_][]const []const u8{ images, files }) |title, paths| {
        if (paths.len == 0) continue;
        try o.print("- {s}:", .{title});
        for (paths) |p| try o.print("\n  - {s}", .{p});
        try o.writeByte('\n');
    }
    try o.writeAll("\n## Đoạn chat ");
    if (t.group) try o.print("nhóm \"{s}\"", .{t.threadName}) else try o.print("với {s}", .{t.threadName});
    try o.print("\n\n{s}\n", .{body});
    return w.written();
}

// ---------------- Claude ----------------

fn runClaude(a: Allocator, fail: *core.Fail, prompt: []const u8) ![]const u8 {
    var path: []const u8 = (if (@hasDecl(m.pty, "claudePath")) m.pty.claudePath(a) else null) orelse
        return fail.set(a, "{s}", .{tr("Claude Code is not installed on this computer", "Không tìm thấy Claude Code trên máy")});
    // npm's extensionless sh shim: Windows needs the .cmd next to it
    if (core.is_windows and std.fs.path.extension(path).len == 0) {
        const cmd = try std.mem.concat(a, u8, &.{ path, ".cmd" });
        if (core.exists(cmd)) path = cmd;
    }
    const cwd = try dir(a);
    core.makePath(cwd) catch {};
    // no saved session (keeps the chat history clean), no MCP servers — it only needs to read the prompt
    var child = std.process.spawn(core.io, .{
        .argv = &.{ path, "-p", "--output-format", "json", "--model", MODEL, "--no-session-persistence", "--strict-mcp-config" },
        .cwd = .{ .path = cwd },
        .environ_map = core.cleanEnvShared(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| return fail.set(a, "{s}: {s}", .{ tr("could not run claude", "không chạy được claude"), @errorName(e) });
    defer child.kill(core.io);
    if (child.stdin) |f| {
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(core.io, &wbuf);
        fw.interface.writeAll(prompt) catch {};
        fw.interface.flush() catch {};
        f.close(core.io);
        child.stdin = null;
    }
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, core.io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(300), .clock = .awake } }).toDeadline(core.io);
    while (mr.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return fail.set(a, "{s}", .{tr("Claude took too long to answer", "Claude phản hồi quá lâu")}),
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(core.io);
    const code: ?u32 = switch (term) {
        .exited => |c| c,
        else => null,
    };
    return claudeResult(a, fail, try mr.toOwnedSlice(0), try mr.toOwnedSlice(1), code);
}

/// What `claude -p --output-format json` printed: the "result" of its JSON, or its error.
fn claudeResult(a: Allocator, fail: *core.Fail, stdout_bytes: []const u8, stderr_bytes: []const u8, code: ?u32) ![]const u8 {
    const stdout = try std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(stdout_bytes)});
    const stderr = try std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(stderr_bytes)});
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, stdout, .{}) catch {
        const out = if (stderr.len > 0) stderr else if (stdout.len > 0) stdout else if (code) |c|
            try std.fmt.allocPrint(a, "{s} {d}", .{ tr("claude exited with code", "claude thoát với mã"), c })
        else
            try std.fmt.allocPrint(a, "{s} null", .{tr("claude exited with code", "claude thoát với mã")});
        return fail.set(a, "{s}", .{text.takeChars(text.trim(out), 300)});
    };
    const result: ?std.json.Value = if (j == .object) j.object.get("result") else null;
    if (truthy(if (j == .object) j.object.get("is_error") else null)) {
        return fail.set(a, "{s}", .{if (truthy(result)) try valueText(a, result.?) else tr("Claude reported an error", "Claude báo lỗi")});
    }
    return if (result) |r| valueText(a, r) else "";
}

fn valueText(a: Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .null => "",
        else => core.toJson(a, v),
    };
}

/// As JavaScript sees it.
fn truthy(v: ?std.json.Value) bool {
    return switch (v orelse return false) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0.0,
        .number_string => |s| (std.fmt.parseFloat(f64, s) catch 1.0) != 0.0,
        .string => |s| s.len > 0,
        else => true,
    };
}

fn buildPrompt(a: Allocator, feed: []const WorkThread, open: []const ZaloTask) ![]u8 {
    var convo: std.ArrayList(u8) = .empty;
    for (feed, 0..) |t, i| {
        if (i > 0) try convo.appendSlice(a, "\n\n");
        try convo.print(a, "### threadId={s} · {s} \"{s}\"\n", .{ t.thread_id, if (t.group) "Nhóm" else "Cá nhân", t.name });
        for (t.msgs, 0..) |msg, k| {
            if (k > 0) try convo.append(a, '\n');
            try convo.print(a, "  [{s}] {s} {s}{s}: {s}", .{ msg.id, zalo.fmtTime(a, msg.ts), msg.from, if (msg.to_me) " →TÔI" else "", try text.collapseWhitespace(a, msg.text) });
        }
    }
    const Existing = struct { id: []const u8, threadId: []const u8, title: []const u8, status: []const u8 };
    const existing = try a.alloc(Existing, open.len);
    for (existing, open) |*e, t| e.* = .{ .id = t.id, .threadId = t.threadId, .title = t.title, .status = t.status };
    return std.fmt.allocPrint(a,
        \\Bạn là trợ lý quản lý công việc. Dưới đây là tin nhắn Zalo gửi tới TÔI (chat cá nhân, nhóm @nhắc tên tôi hoặc trả lời tin của tôi) trong {d} ngày qua, kèm các tin "Tôi" đã gửi sau đó. Dòng có "→TÔI" là tin gửi trực tiếp cho tôi.
        \\
        \\Nhiệm vụ: lập danh sách CÔNG VIỆC của tôi — những yêu cầu, câu hỏi cần tôi trả lời, việc được giao/nhờ tôi làm. Bỏ qua chào hỏi, tán gẫu, quảng cáo, tin thông báo tự động, tin không cần tôi làm gì.
        \\
        \\Trạng thái mỗi việc:
        \\- "todo": tôi chưa trả lời / chưa phản hồi gì.
        \\- "doing": tôi đã phản hồi nhưng chưa xong (vd "ok", "để em xem", "đang làm", hẹn sẽ gửi).
        \\- "done": tôi đã báo xong / đã gửi / đã trả lời đầy đủ câu hỏi, hoặc người yêu cầu nói đã ổn / huỷ.
        \\
        \\Việc đã có (giữ nguyên "id" nếu vẫn là việc đó, cập nhật status/title nếu cần; KHÔNG tạo trùng; việc "done" là đã xong hẳn — KHÔNG mở lại, KHÔNG tạo lại việc đó dưới id/tiêu đề khác):
        \\{s}
        \\
        \\Tin nhắn:
        \\{s}
        \\
        \\Chỉ trả về MỘT object JSON, không giải thích, dạng:
        \\{{"tasks":[{{"id":"<id việc đã có hoặc null>","threadId":"...","msgId":"<id tin yêu cầu>","from":"<người giao>","title":"<việc cần làm, ngắn gọn, tiếng Việt>","detail":"<1 câu tóm tắt ngữ cảnh / tôi đã trả lời gì>","status":"todo|doing|done"}}]}}
        \\Trả về đầy đủ mọi việc (cả việc đã có còn liên quan).
    , .{ WINDOW_DAYS, try core.toJson(a, existing), convo.items });
}

const RawTask = struct {
    id: ?[]const u8 = null,
    threadId: ?[]const u8 = null,
    msgId: ?[]const u8 = null,
    from: ?[]const u8 = null,
    title: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

/// The tasks in Claude's answer: the JSON object somewhere in `answer`.
fn parse(a: Allocator, fail: *core.Fail, answer: []const u8) ![]const RawTask {
    const no_json = tr("Claude did not return JSON", "Claude không trả về JSON");
    const start = std.mem.indexOfScalar(u8, answer, '{') orelse return fail.set(a, "{s}", .{no_json});
    const end = std.mem.lastIndexOfScalar(u8, answer, '}') orelse return fail.set(a, "{s}", .{no_json});
    if (end <= start) return fail.set(a, "{s}", .{no_json});
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, answer[start .. end + 1], .{}) catch |e| switch (e) {
        error.OutOfMemory => |x| return x,
        else => return fail.set(a, "{s}", .{no_json}),
    };
    var out: std.ArrayList(RawTask) = .empty;
    if (j == .object) if (j.object.get("tasks")) |v| if (v == .array) for (v.array.items) |x| {
        try out.append(a, std.json.parseFromValueLeaky(RawTask, a, x, .{ .ignore_unknown_fields = true }) catch continue);
    };
    return out.items;
}

fn trimmed(s: ?[]const u8) ?[]const u8 {
    const t = text.trim(s orelse return null);
    return if (t.len == 0) null else t;
}

/// Read the last few days of messages to me and update the checklist.
pub fn analyze(a: Allocator) !ZaloTasksState {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const tmp = arena.allocator();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const busy = blk: {
            const t = tasks();
            defer unlock();
            if (t.running) t.again = true;
            break :blk t.running;
        };
        if (busy) return getTasks(a);
        if (!zalo.signedIn(tmp)) {
            setErr(tasks(), tr("Not signed in to Zalo", "Zalo chưa đăng nhập"));
            unlock();
            broadcast();
            return getTasks(a);
        }
        // messages that arrive during this run stay "incoming" for the next one
        var handling: std.ArrayList([]const u8) = .empty;
        {
            const t = tasks();
            defer unlock();
            t.running = true;
            setErr(t, null);
            for (t.incoming.items) |i| try handling.append(tmp, try tmp.dupe(u8, i.msgId));
        }
        broadcast();
        var fail: core.Fail = .{};
        const r = runOnce(tmp, &fail);
        const again = blk: {
            const t = tasks();
            defer unlock();
            if (r) |_| {} else |e| setErr(t, fail.text(e));
            t.running = false;
            var kept: usize = 0;
            for (t.incoming.items) |i| {
                if (contains(handling.items, i.msgId)) {
                    freeStrings(core.gpa, i);
                } else {
                    t.incoming.items[kept] = i;
                    kept += 1;
                }
            }
            t.incoming.shrinkRetainingCapacity(kept);
            defer t.again = false;
            break :blk t.again;
        };
        broadcast();
        if (!again) return getTasks(a);
    }
}

fn setErr(t: *Tasks, msg: ?[]const u8) void {
    setOpt(&t.err, msg) catch {};
}

/// What Claude found (`raw`) merged into the list: known tasks updated, new ones added to the
/// list and to `created` (copies in `a`); `updated_ids` gets the tasks whose status changed.
fn applyRaw(
    a: Allocator,
    t: *Tasks,
    feed: []const WorkThread,
    raw: []const RawTask,
    now: i64,
    /// when the run before this one read the messages
    prev: i64,
    created: *std.ArrayList(ZaloTask),
    updated_ids: *std.ArrayList([]const u8),
) !void {
    for (raw) |r| {
        const th = for (feed) |*f| {
            if (r.threadId) |id| if (std.mem.eql(u8, f.thread_id, id)) break f;
        } else continue;
        const title = trimmed(r.title) orelse continue;
        const status: []const u8 = if (r.status) |s|
            (if (std.mem.eql(u8, s, "done")) "done" else if (std.mem.eql(u8, s, "doing")) "doing" else "todo")
        else
            "todo";
        const src: ?*const WorkMsg = for (th.msgs) |*msg| {
            if (r.msgId) |mid| if (std.mem.eql(u8, msg.id, mid)) break msg;
        } else null;
        const cur: ?*ZaloTask = (if (r.id) |id| t.find(id) else null) orelse for (t.tasks.items) |*x| {
            const mid = r.msgId orelse break null;
            if (std.mem.eql(u8, x.threadId, th.thread_id) and x.msgId != null and std.mem.eql(u8, x.msgId.?, mid)) break x;
        } else null;
        if (cur) |x| {
            try setStr(&x.title, title);
            if (trimmed(r.detail)) |d| try setOpt(&x.detail, d);
            try setStr(&x.threadName, th.name);
            if (x.fromId == null) if (src) |s| {
                if (!s.mine) try setOpt(&x.fromId, s.from_id);
            };
            // a status set by hand stays, unless Claude now sees it finished;
            // finished work (by hand or by Claude) is never reopened by the analysis
            const done = std.mem.eql(u8, status, "done");
            if (!std.mem.eql(u8, x.status, "done") and (x.manual != true or done)) {
                if (!std.mem.eql(u8, x.status, status)) {
                    x.updatedAt = now;
                    if (!contains(updated_ids.items, x.id)) try updated_ids.append(a, try a.dupe(u8, x.id));
                }
                if (done) x.manual = false;
                try setStr(&x.status, status);
            }
        } else {
            // nothing new to do, or a message whose task I deleted
            if (std.mem.eql(u8, status, "done")) continue;
            if (r.msgId) |mid| if (contains(t.dismissed.items, mid)) continue;
            // from a message an earlier run already read, in a chat that has tasks: a re-worded duplicate
            const old = if (src) |s| s.ts <= prev else true;
            if (old and prev > 0) {
                const has_tasks = for (t.tasks.items) |x| {
                    if (std.mem.eql(u8, x.threadId, th.thread_id)) break true;
                } else false;
                if (has_tasks) continue;
            }
            const id = newId();
            const task: ZaloTask = .{
                .id = &id,
                .title = title,
                .detail = trimmed(r.detail),
                .threadId = th.thread_id,
                .threadName = th.name,
                .group = th.group,
                .msgId = if (src) |s| s.id else null,
                .from = trimmed(r.from) orelse if (src) |s| s.from else th.name,
                .fromId = if (src != null and !src.?.mine) src.?.from_id else if (!th.group) th.thread_id else null,
                .ts = if (src) |s| s.ts else if (th.msgs.len > 0) th.msgs[th.msgs.len - 1].ts else now,
                .status = status,
                .updatedAt = now,
            };
            try t.tasks.append(core.gpa, try cloneStrings(core.gpa, task));
            try created.append(a, try cloneStrings(a, task));
        }
    }
}

/// The end of a run: old finished work is forgotten, the list sorted newest first, and what
/// the run created / changed recorded. Returns the changed tasks (copies in `a`).
fn finishRun(a: Allocator, t: *Tasks, now: i64, created: []const ZaloTask, updated_ids: []const []const u8) ![]const ZaloTask {
    // forget finished work after a while
    const keep = now - KEEP_DONE_DAYS * DAY;
    var kept: usize = 0;
    for (t.tasks.items) |x| {
        if (!std.mem.eql(u8, x.status, "done") or x.updatedAt > keep) {
            t.tasks.items[kept] = x;
            kept += 1;
        } else {
            freeStrings(core.gpa, x);
        }
    }
    t.tasks.shrinkRetainingCapacity(kept);
    var i: usize = t.unseen.count();
    while (i > 0) {
        i -= 1;
        const key = t.unseen.keys()[i];
        if (t.find(key) == null) {
            t.unseen.orderedRemoveAt(i);
            core.gpa.free(key);
        }
    }
    std.mem.sort(ZaloTask, t.tasks.items, {}, struct {
        fn newer(_: void, x: ZaloTask, y: ZaloTask) bool {
            return x.ts > y.ts;
        }
    }.newer);
    t.analyzed_at = now;
    const fresh = try a.alloc([]const u8, created.len);
    for (fresh, created) |*dst, x| dst.* = x.id;
    try Tasks.setStrings(&t.fresh, fresh);
    try Tasks.setStrings(&t.changed, updated_ids);
    var updated: std.ArrayList(ZaloTask) = .empty;
    for (updated_ids) |id| if (t.find(id)) |x| try updated.append(a, try cloneStrings(a, x.*));
    return updated.items;
}

fn runOnce(a: Allocator, fail: *core.Fail) !void {
    const now = nowMs();
    const feed = zalo.workFeed(a, now - WINDOW_DAYS * DAY, 40, 40, null);
    var created: std.ArrayList(ZaloTask) = .empty;
    var updated_ids: std.ArrayList([]const u8) = .empty;
    if (feed.len > 0) {
        var open: std.ArrayList(ZaloTask) = .empty;
        // what the previous run already read: tasks "found" in those messages now are almost always
        // duplicates of work that was done or deleted — never re-announce them
        const prev = blk: {
            const t = tasks();
            defer unlock();
            for (t.tasks.items) |x| for (feed) |f| {
                if (std.mem.eql(u8, f.thread_id, x.threadId)) {
                    try open.append(a, try cloneStrings(a, x));
                    break;
                }
            };
            break :blk t.analyzed_at;
        };
        const raw = try parse(a, fail, try runClaude(a, fail, try buildPrompt(a, feed, open.items)));
        const t = tasks();
        defer unlock();
        try applyRaw(a, t, feed, raw, now, prev, &created, &updated_ids);
    }
    const updated = blk: {
        const t = tasks();
        defer unlock();
        break :blk try finishRun(a, t, now, created.items, updated_ids.items);
    };
    var new_open: std.ArrayList(ZaloTask) = .empty;
    for (created.items) |x| if (!std.mem.eql(u8, x.status, "done")) try new_open.append(a, x);
    announce(a, new_open.items, updated);
    save();
}

/// A random (version 4) UUID.
fn newId() [36]u8 {
    var b: [16]u8 = undefined;
    core.io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .lower);
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return out;
}

// ---------------- commands ----------------

pub fn zalo_tasks(c: *ipc.Call) !ZaloTasksState {
    return getTasks(c.arena);
}

pub fn zalo_tasks_analyze(c: *ipc.Call) !ZaloTasksState {
    return analyze(c.arena);
}

pub fn zalo_task_status(c: *ipc.Call, args: struct { id: []const u8, status: []const u8 }) !ZaloTasksState {
    return setStatus(c.arena, args.id, args.status);
}

pub fn zalo_task_context(c: *ipc.Call, args: struct { id: []const u8 }) !TaskContext {
    var fail: core.Fail = .{};
    return taskContext(c.arena, &fail, args.id) catch |e| return c.failMsg(fail.text(e));
}

pub fn zalo_task_remove(c: *ipc.Call, args: struct { id: []const u8 }) !ZaloTasksState {
    return removeTask(c.arena, args.id);
}

pub fn zalo_tasks_viewing(_: *ipc.Call, args: struct { viewing: bool }) !void {
    setViewing(args.viewing);
}

pub const commands = .{
    .{ "zalo_tasks", zalo_tasks },
    .{ "zalo_tasks_analyze", zalo_tasks_analyze },
    .{ "zalo_task_status", zalo_task_status },
    .{ "zalo_task_context", zalo_task_context },
    .{ "zalo_task_remove", zalo_task_remove },
    .{ "zalo_tasks_viewing", zalo_tasks_viewing },
};

// ---------------- tests ----------------

const testing = std.testing;

test {
    _ = text;
}

/// `s` n times.
fn repeat(a: Allocator, s: []const u8, n: usize) ![]u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

var test_env: ?std.process.Environ.Map = null;

/// For tests that reach `tr` (the settings are read from the data folder): a data folder of
/// the tests' own, unless another module's test fixed it first (it is then only read).
fn testInit() !void {
    // the settings and the data folder's path stay allocated for the whole run
    core.gpa = std.heap.smp_allocator;
    core.io = testing.io;
    if (test_env == null) {
        const rel = ".zig-cache/tmp/zalo-tasks-test";
        try std.Io.Dir.cwd().createDirPath(core.io, rel);
        var d = try std.Io.Dir.cwd().openDir(core.io, rel, .{});
        defer d.close(core.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try d.realPath(core.io, &buf);
        var env: std.process.Environ.Map = .init(core.gpa);
        try env.put("STUDIO_USER_DATA", buf[0..n]);
        test_env = env;
    }
    core.env = &test_env.?;
}

fn addTask(t: *Tasks, task: ZaloTask) !void {
    try t.tasks.append(core.gpa, try cloneStrings(core.gpa, task));
}

test "helpers" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    try testing.expectEqualStrings("a_b_c_d_e_f_g_h_ x.pdf", try safeName(a, "a<b>:c\"d/e\\f|g?h*  x.pdf"));
    try testing.expectEqualStrings("file", try safeName(a, "   "));
    try testing.expectEqualStrings("jpeg", extOf("https://x/y.JPEG?a=1", "jpg"));
    try testing.expectEqualStrings("jpg", extOf("https://x/y", "jpg"));
    const r = try parse(a, &fail, "ok {\"tasks\":[{\"id\":null,\"threadId\":\"1\",\"title\":\" a \",\"status\":\"doing\"}]} done");
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("a", trimmed(r[0].title).?);
    try testing.expectError(error.Failed, parse(a, &fail, "no json"));
    try testing.expectEqualStrings(tr("Claude did not return JSON", "Claude không trả về JSON"), fail.msg);
}

test "safeName" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("báo cáo tháng 10.pdf", try safeName(a, "  báo  cáo\u{a0}tháng 10.pdf "));
    try testing.expectEqualStrings("a_b", try safeName(a, "a\r\n\tb"));
    try testing.expectEqualStrings("_", try safeName(a, "\\/:*?\"<>|"));
    try testing.expectEqualStrings(".._.._evil.exe", try safeName(a, "..\\..\\evil.exe"));
    try testing.expectEqualStrings("file", try safeName(a, ""));
    // 80 characters, not bytes, counted after trimming
    try testing.expectEqualStrings(try repeat(a, "ệ", 80), try safeName(a, try std.mem.concat(a, u8, &.{ " ", try repeat(a, "ệ", 100) })));
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ try repeat(a, "a", 79), " " }), try safeName(a, try std.mem.concat(a, u8, &.{ try repeat(a, "a", 79), "  b" })));
}

test "extOf" {
    try testing.expectEqualStrings("png", extOf("https://cdn/a.b/c.PNG", "jpg"));
    try testing.expectEqualStrings("jpg", extOf("https://cdn/c.jpg#frag", "x"));
    try testing.expectEqualStrings("jpeg", extOf("c.jpeg", "x"));
    try testing.expectEqualStrings("webp", extOf("https://cdn/c.webp?x=.png&y", "x"));
    try testing.expectEqualStrings("gif", extOf("a.pngx/b.gif", "x"));
    try testing.expectEqualStrings("bmp", extOf(".bmp", "x"));
    try testing.expectEqualStrings("x", extOf("https://cdn/c.jpgs", "x"));
    try testing.expectEqualStrings("x", extOf("https://cdn/c.png/more", "x"));
    try testing.expectEqualStrings("x", extOf("", "x"));
}

test "parse: Claude's answer" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    const r = try parse(a, &fail, "```json\n{\"tasks\":[" ++
        "{\"id\":\"t1\",\"threadId\":\"g\",\"msgId\":\"m\",\"from\":\"An\",\"title\":\"T\",\"detail\":\"D\",\"status\":\"done\",\"extra\":1}," ++
        "{\"title\":\"only a title\"}," ++
        "{\"id\":5,\"title\":\"an id that is not text\"}," ++
        "\"not an object\"" ++
        "]}\n```");
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("t1", r[0].id.?);
    try testing.expectEqualStrings("g", r[0].threadId.?);
    try testing.expectEqualStrings("m", r[0].msgId.?);
    try testing.expectEqualStrings("An", r[0].from.?);
    try testing.expectEqualStrings("D", r[0].detail.?);
    try testing.expectEqualStrings("done", r[0].status.?);
    try testing.expect(r[1].id == null and r[1].threadId == null and r[1].status == null);

    try testing.expectEqual(@as(usize, 0), (try parse(a, &fail, "{}")).len);
    try testing.expectEqual(@as(usize, 0), (try parse(a, &fail, "{\"tasks\":5}")).len);
    try testing.expectError(error.Failed, parse(a, &fail, "} {"));
    try testing.expectError(error.Failed, parse(a, &fail, "{ not json }"));

    try testing.expectEqualStrings("a", trimmed(" a\u{a0}\n").?);
    try testing.expect(trimmed("  ") == null);
    try testing.expect(trimmed(null) == null);
}

test "JSON for the page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const task: ZaloTask = .{ .id = "t1", .title = "T", .threadId = "g", .threadName = "G", .group = true, .from = "An", .ts = 5, .status = "todo", .updatedAt = 6 };
    try testing.expectEqualStrings(
        "{\"id\":\"t1\",\"title\":\"T\",\"threadId\":\"g\",\"threadName\":\"G\",\"group\":true,\"from\":\"An\",\"ts\":5,\"status\":\"todo\",\"updatedAt\":6}",
        try core.toJson(a, task),
    );
    var full = task;
    full.detail = "D";
    full.msgId = "m";
    full.fromId = "u";
    full.avatar = "https://a";
    full.manual = false;
    try testing.expectEqualStrings(
        "{\"id\":\"t1\",\"title\":\"T\",\"detail\":\"D\",\"threadId\":\"g\",\"threadName\":\"G\",\"group\":true,\"msgId\":\"m\",\"from\":\"An\",\"fromId\":\"u\",\"avatar\":\"https://a\",\"ts\":5,\"status\":\"todo\",\"manual\":false,\"updatedAt\":6}",
        try core.toJson(a, full),
    );

    var unseen: Unseen = .empty;
    try unseen.put(a, "b", "new");
    try unseen.put(a, "a", "updated");
    var s: ZaloTasksState = .{
        .tasks = &.{},
        .running = false,
        .analyzedAt = 0,
        .@"error" = null,
        .incoming = &.{.{ .threadId = "g", .msgId = "m", .threadName = "G", .group = true, .from = "An", .text = "hi", .ts = 1 }},
        .fresh = &.{"b"},
        .changed = &.{},
        .unseen = .{ .map = unseen },
        .dueAt = null,
    };
    try testing.expectEqualStrings(
        "{\"tasks\":[],\"running\":false,\"analyzedAt\":0,\"incoming\":[{\"threadId\":\"g\",\"msgId\":\"m\",\"threadName\":\"G\",\"group\":true,\"from\":\"An\",\"text\":\"hi\",\"ts\":1}],\"fresh\":[\"b\"],\"changed\":[],\"unseen\":{\"b\":\"new\",\"a\":\"updated\"}}",
        try core.toJson(a, s),
    );
    s.@"error" = "E";
    s.dueAt = 9;
    s.incoming = &.{};
    s.unseen = .{};
    try testing.expectEqualStrings(
        "{\"tasks\":[],\"running\":false,\"analyzedAt\":0,\"error\":\"E\",\"incoming\":[],\"fresh\":[\"b\"],\"changed\":[],\"unseen\":{},\"dueAt\":9}",
        try core.toJson(a, s),
    );
    try testing.expectEqualStrings("{\"file\":\"f\",\"images\":[\"i\"],\"files\":[]}", try core.toJson(a, TaskContext{ .file = "f", .images = &.{"i"}, .files = &.{} }));
}

test "tasks.json: read and written" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t: Tasks = .{};
    defer t.deinit();
    try load(&t, a, "{\"tasks\":[" ++
        "{\"id\":\"t1\",\"title\":\"T\",\"threadId\":\"g\",\"threadName\":\"G\",\"group\":true,\"msgId\":\"m1\",\"from\":\"An\",\"ts\":5,\"status\":\"todo\",\"manual\":true,\"updatedAt\":6,\"gone\":1}," ++
        "{\"id\":\"t2\"}," ++
        "{\"id\":7}," ++
        "\"x\"" ++
        "],\"analyzedAt\":123,\"unseen\":{\"t2\":\"new\",\"t1\":\"updated\",\"zz\":5},\"dismissed\":[\"m9\",2],\"other\":true}");
    try testing.expectEqual(@as(usize, 2), t.tasks.items.len);
    try testing.expectEqualStrings("m1", t.tasks.items[0].msgId.?);
    try testing.expect(t.tasks.items[0].manual == true and t.tasks.items[0].group);
    try testing.expect(t.tasks.items[0].detail == null and t.tasks.items[0].avatar == null);
    // what is missing has its default
    try testing.expectEqualStrings("", t.tasks.items[1].status);
    try testing.expectEqual(@as(i64, 123), t.analyzed_at);
    try testing.expectEqual(@as(usize, 2), t.unseen.count());
    try testing.expectEqualStrings("new", t.unseen.get("t2").?);
    try testing.expectEqual(@as(usize, 1), t.dismissed.items.len);

    try testing.expectEqualStrings("{\"analyzedAt\":123,\"dismissed\":[\"m9\"],\"tasks\":[" ++
        "{\"id\":\"t1\",\"title\":\"T\",\"threadId\":\"g\",\"threadName\":\"G\",\"group\":true,\"msgId\":\"m1\",\"from\":\"An\",\"ts\":5,\"status\":\"todo\",\"manual\":true,\"updatedAt\":6}," ++
        "{\"id\":\"t2\",\"title\":\"\",\"threadId\":\"\",\"threadName\":\"\",\"group\":false,\"from\":\"\",\"ts\":0,\"status\":\"\",\"updatedAt\":0}" ++
        "],\"unseen\":{\"t2\":\"new\",\"t1\":\"updated\"}}", try fileJson(a, &t));

    // a file that is not what it should be changes nothing
    var empty: Tasks = .{};
    defer empty.deinit();
    try load(&empty, a, "[1,2]");
    try load(&empty, a, "{\"tasks\":{},\"analyzedAt\":\"x\",\"unseen\":[],\"dismissed\":{}}");
    try testing.expect(std.meta.isError(load(&empty, a, "{")));
    try testing.expectEqual(@as(usize, 0), empty.tasks.items.len);
    try testing.expectEqualStrings("{\"analyzedAt\":0,\"dismissed\":[],\"tasks\":[],\"unseen\":{}}", try fileJson(a, &empty));
}

const test_now: i64 = 100 * DAY;

/// g1: a group where An asked me something and I answered; u2: Bình wrote to me; u3: Chi wrote
/// twice, once before the previous analysis (test_now - 1000) and once after.
const test_feed = [_]WorkThread{
    .{ .thread_id = "g1", .name = "Nhóm dự án", .group = true, .msgs = &.{
        .{ .id = "m1", .ts = test_now - 5000, .from = "An", .from_id = "u1", .mine = false, .to_me = true, .text = "@Tôi  gửi\nbáo cáo" },
        .{ .id = "m2", .ts = test_now - 4000, .from = "Tôi", .from_id = "me", .mine = true, .to_me = false, .text = "ok" },
    } },
    .{ .thread_id = "u2", .name = "Bình", .group = false, .msgs = &.{
        .{ .id = "m3", .ts = test_now - 3000, .from = "Bình", .from_id = "u2", .mine = false, .to_me = true, .text = "hi" },
    } },
    .{ .thread_id = "u3", .name = "Chi", .group = false, .msgs = &.{
        .{ .id = "m4", .ts = test_now - 2000, .from = "Chi", .from_id = "u3", .mine = false, .to_me = true, .text = "cũ" },
        .{ .id = "m5", .ts = test_now - 500, .from = "Chi", .from_id = "u3", .mine = false, .to_me = true, .text = "mới" },
    } },
};

test "analysis: the first run makes tasks" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t: Tasks = .{};
    defer t.deinit();
    var created: std.ArrayList(ZaloTask) = .empty;
    var updated_ids: std.ArrayList([]const u8) = .empty;
    try applyRaw(a, &t, &test_feed, &.{
        .{ .threadId = "g1", .msgId = "m1", .title = " Gửi báo cáo ", .detail = "  ", .status = "doing" },
        // the message is not in the feed: who and when come from the conversation
        .{ .threadId = "u2", .msgId = "nope", .title = "Trả lời Bình", .from = " Bình B " },
        .{ .threadId = "zzz", .title = "a conversation that is not in the feed" },
        .{ .threadId = "g1", .title = "   " },
        .{ .title = "no conversation" },
        // found already finished: nothing to do
        .{ .threadId = "u3", .msgId = "m5", .title = "đã xong", .status = "done" },
        .{ .threadId = "u3", .msgId = "m4", .title = "Xem lại", .status = "whatever" },
    }, test_now, 0, &created, &updated_ids);
    try testing.expectEqual(@as(usize, 3), t.tasks.items.len);
    try testing.expectEqual(@as(usize, 3), created.items.len);
    try testing.expectEqual(@as(usize, 0), updated_ids.items.len);

    const x = t.tasks.items[0];
    try testing.expectEqual(@as(usize, 36), x.id.len);
    try testing.expectEqualStrings("Gửi báo cáo", x.title);
    try testing.expect(x.detail == null and x.manual == null and x.avatar == null);
    try testing.expectEqualStrings("g1", x.threadId);
    try testing.expectEqualStrings("Nhóm dự án", x.threadName);
    try testing.expect(x.group);
    try testing.expectEqualStrings("m1", x.msgId.?);
    try testing.expectEqualStrings("An", x.from);
    try testing.expectEqualStrings("u1", x.fromId.?);
    try testing.expectEqual(test_now - 5000, x.ts);
    try testing.expectEqualStrings("doing", x.status);
    try testing.expectEqual(test_now, x.updatedAt);
    try testing.expectEqualStrings(x.id, created.items[0].id);

    const y = t.tasks.items[1];
    try testing.expect(y.msgId == null);
    try testing.expectEqualStrings("Bình B", y.from);
    try testing.expectEqualStrings("u2", y.fromId.?);
    try testing.expectEqual(test_now - 3000, y.ts);
    try testing.expectEqualStrings("todo", y.status);

    try testing.expectEqualStrings("m4", t.tasks.items[2].msgId.?);
    try testing.expectEqualStrings("todo", t.tasks.items[2].status);

    const first_id = try a.dupe(u8, x.id);
    const updated = try finishRun(a, &t, test_now, created.items, updated_ids.items);
    try testing.expectEqual(@as(usize, 0), updated.len);
    // newest first
    try testing.expectEqualStrings("m4", t.tasks.items[0].msgId.?);
    try testing.expectEqualStrings("u2", t.tasks.items[1].threadId);
    try testing.expectEqualStrings("g1", t.tasks.items[2].threadId);
    try testing.expectEqual(test_now, t.analyzed_at);
    try testing.expectEqual(@as(usize, 3), t.fresh.items.len);
    try testing.expectEqualStrings(first_id, t.fresh.items[0]);
    try testing.expectEqual(@as(usize, 0), t.changed.items.len);
}

test "analysis: later runs update, never duplicate or reopen" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t: Tasks = .{};
    defer t.deinit();
    try addTask(&t, .{ .id = "t1", .title = "old", .detail = "kept", .threadId = "g1", .threadName = "old name", .group = true, .msgId = "m1", .from = "An", .ts = test_now - 5000, .status = "todo", .updatedAt = 1 });
    try addTask(&t, .{ .id = "t2", .title = "mine", .threadId = "g1", .threadName = "G", .group = true, .msgId = "m9", .from = "An", .fromId = "keep", .ts = test_now - 9000, .status = "doing", .manual = true, .updatedAt = 2 });
    try addTask(&t, .{ .id = "t3", .title = "long done", .threadId = "u2", .from = "Bình", .ts = 3, .status = "done", .updatedAt = test_now - 15 * DAY });
    try addTask(&t, .{ .id = "t4", .title = "done", .threadId = "u2", .from = "Bình", .ts = 4, .status = "done", .manual = true, .updatedAt = test_now - DAY });
    try t.dismissed.append(core.gpa, try core.gpa.dupe(u8, "m3"));
    try t.setUnseen("t1", "new");
    try t.setUnseen("gone", "updated");

    var created: std.ArrayList(ZaloTask) = .empty;
    var updated_ids: std.ArrayList([]const u8) = .empty;
    try applyRaw(a, &t, &test_feed, &.{
        .{ .id = "t1", .threadId = "g1", .msgId = "m1", .title = "new title", .detail = " ", .status = "doing" },
        // no id: found by its message; a status set by hand stays
        .{ .threadId = "g1", .msgId = "m9", .title = "t2 title", .detail = "ctx", .status = "todo" },
        // … unless Claude now sees it finished
        .{ .id = "t2", .threadId = "g1", .title = "t2 done", .status = "done" },
        .{ .id = "t2", .threadId = "g1", .title = "t2 done", .status = "done" },
        // finished work is never reopened
        .{ .id = "t4", .threadId = "u2", .title = "again?", .status = "todo" },
        // the message of a task I deleted
        .{ .threadId = "u2", .msgId = "m3", .title = "deleted before", .status = "todo" },
        // nothing points at a new message, and the chat already has tasks: the same work re-worded
        .{ .threadId = "g1", .msgId = "m1x", .title = "re-worded" },
        .{ .id = "nope", .threadId = "g1", .msgId = "m2", .title = "from a message read before" },
        // a message that came after the previous run, then one from before it in the same chat
        .{ .threadId = "u3", .msgId = "m5", .title = "new chat" },
        .{ .threadId = "u3", .msgId = "m4", .title = "older message" },
    }, test_now, test_now - 1000, &created, &updated_ids);

    const t1 = t.find("t1").?;
    try testing.expectEqualStrings("new title", t1.title);
    try testing.expectEqualStrings("kept", t1.detail.?);
    try testing.expectEqualStrings("Nhóm dự án", t1.threadName);
    try testing.expectEqualStrings("u1", t1.fromId.?);
    try testing.expectEqualStrings("doing", t1.status);
    try testing.expectEqual(test_now, t1.updatedAt);
    try testing.expect(t1.manual == null);

    const t2 = t.find("t2").?;
    try testing.expectEqualStrings("t2 done", t2.title);
    try testing.expectEqualStrings("ctx", t2.detail.?);
    try testing.expectEqualStrings("keep", t2.fromId.?);
    try testing.expectEqualStrings("done", t2.status);
    try testing.expect(t2.manual == false);
    try testing.expectEqual(test_now, t2.updatedAt);

    const t4 = t.find("t4").?;
    try testing.expectEqualStrings("again?", t4.title);
    try testing.expectEqualStrings("done", t4.status);
    try testing.expect(t4.manual == true);
    try testing.expectEqual(test_now - DAY, t4.updatedAt);

    try testing.expectEqual(@as(usize, 5), t.tasks.items.len);
    try testing.expectEqual(@as(usize, 1), created.items.len);
    try testing.expectEqualStrings("new chat", created.items[0].title);
    try testing.expectEqualStrings("u3", created.items[0].fromId.?);
    try testing.expectEqual(@as(usize, 2), updated_ids.items.len);
    try testing.expectEqualStrings("t1", updated_ids.items[0]);
    try testing.expectEqualStrings("t2", updated_ids.items[1]);

    const updated = try finishRun(a, &t, test_now, created.items, updated_ids.items);
    try testing.expectEqual(@as(usize, 2), updated.len);
    try testing.expectEqualStrings("new title", updated[0].title);
    try testing.expectEqualStrings("done", updated[1].status);
    // work finished more than KEEP_DONE_DAYS ago is forgotten; newest first
    try testing.expect(t.find("t3") == null);
    try testing.expectEqual(@as(usize, 4), t.tasks.items.len);
    try testing.expectEqualStrings("new chat", t.tasks.items[0].title);
    try testing.expectEqualStrings("t1", t.tasks.items[1].id);
    try testing.expectEqualStrings("t2", t.tasks.items[2].id);
    try testing.expectEqualStrings("t4", t.tasks.items[3].id);
    try testing.expectEqualStrings(created.items[0].id, t.fresh.items[0]);
    try testing.expectEqual(@as(usize, 2), t.changed.items.len);
    // the badge only counts tasks that still exist
    try testing.expectEqual(@as(usize, 1), t.unseen.count());

    // a task that is new stays "new" when it is also updated
    try markUnseen(&t, created.items, updated);
    try testing.expectEqual(@as(usize, 3), t.unseen.count());
    try testing.expectEqualStrings("new", t.unseen.get("t1").?);
    try testing.expectEqualStrings("new", t.unseen.get(created.items[0].id).?);
    try testing.expectEqualStrings("updated", t.unseen.get("t2").?);
    t.dropUnseen("t1");
    t.dropUnseen("not there");
    try testing.expectEqual(@as(usize, 2), t.unseen.count());

    // deleting a task remembers its message
    try removeFrom(&t, "t1");
    try removeFrom(&t, "t4");
    try removeFrom(&t, "not there");
    try testing.expectEqual(@as(usize, 2), t.tasks.items.len);
    try testing.expectEqual(@as(usize, 2), t.dismissed.items.len);
    try testing.expectEqualStrings("m1", t.dismissed.items[1]);
}

test "deleted tasks: at most 500 messages remembered" {
    core.gpa = testing.allocator;
    var t: Tasks = .{};
    defer t.deinit();
    var buf: [16]u8 = undefined;
    for (0..502) |i| {
        const mid = try std.fmt.bufPrint(&buf, "m{d}", .{i});
        try addTask(&t, .{ .id = mid, .msgId = mid });
        try removeFrom(&t, mid);
    }
    try testing.expectEqual(@as(usize, 500), t.dismissed.items.len);
    try testing.expectEqualStrings("m2", t.dismissed.items[0]);
    try testing.expectEqualStrings("m501", t.dismissed.items[499]);
    try testing.expectEqual(@as(usize, 0), t.tasks.items.len);
}

test "incoming: what just arrived for me" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t: Tasks = .{};
    defer t.deinit();
    var add: std.ArrayList(ZaloIncoming) = .empty;
    var uids: std.ArrayList([]const u8) = .empty;

    // analyzed 2500 ms ago: m4 (2000 ms old) and m5 are new, the rest was read already
    t.analyzed_at = test_now - 2500;
    try testing.expect(try collectIncoming(a, &t, &test_feed, test_now, &add, &uids));
    try testing.expectEqual(@as(usize, 2), add.items.len);
    try testing.expectEqualStrings("m4", add.items[0].msgId);
    try testing.expectEqualStrings("u3", add.items[0].threadId);
    try testing.expectEqualStrings("Chi", add.items[0].threadName);
    try testing.expectEqualStrings("Chi", add.items[0].from);
    try testing.expectEqualStrings("cũ", add.items[0].text);
    try testing.expect(!add.items[0].group and add.items[0].avatar == null);
    try testing.expectEqualStrings("u3", uids.items[1]);

    // already waiting: not added twice
    for (add.items) |i| try t.incoming.append(core.gpa, try cloneStrings(core.gpa, i));
    add.clearRetainingCapacity();
    uids.clearRetainingCapacity();
    try testing.expect(try collectIncoming(a, &t, &test_feed, test_now, &add, &uids));
    try testing.expectEqual(@as(usize, 0), add.items.len);

    // nothing newer than the last analysis
    t.analyzed_at = test_now;
    try testing.expect(!try collectIncoming(a, &t, &test_feed, test_now, &add, &uids));

    // never analyzed: only the last ten minutes count
    t.analyzed_at = 0;
    try testing.expect(!try collectIncoming(a, &t, &test_feed, test_now + 10 * 60_000, &add, &uids));

    // my own reply matters only where work is open
    t.analyzed_at = test_now - 4500;
    const mine = [_]WorkThread{test_feed[0]};
    try testing.expect(!try collectIncoming(a, &t, &mine, test_now, &add, &uids));
    try addTask(&t, .{ .id = "t1", .threadId = "g1", .status = "done" });
    try testing.expect(!try collectIncoming(a, &t, &mine, test_now, &add, &uids));
    try addTask(&t, .{ .id = "t2", .threadId = "g1", .status = "doing" });
    try testing.expect(try collectIncoming(a, &t, &mine, test_now, &add, &uids));
    try testing.expectEqual(@as(usize, 0), add.items.len);

    // long messages are cut to 160 characters
    const long = [_]WorkThread{.{ .thread_id = "u9", .name = "N", .group = false, .msgs = &.{
        .{ .id = "x", .ts = test_now, .from = "N", .from_id = "u9", .mine = false, .to_me = true, .text = try repeat(a, "ờ", 200) },
    } }};
    try testing.expect(try collectIncoming(a, &t, &long, test_now, &add, &uids));
    try testing.expectEqualStrings(try repeat(a, "ờ", 160), add.items[0].text);
}

test "the prompt" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prompt = try buildPrompt(a, test_feed[0..2], &.{.{ .id = "1", .threadId = "2", .title = "t", .status = "todo", .detail = "not sent" }});
    try testing.expect(std.mem.startsWith(u8, prompt, "Bạn là trợ lý quản lý công việc. Dưới đây là tin nhắn Zalo gửi tới TÔI (chat cá nhân, nhóm @nhắc tên tôi hoặc trả lời tin của tôi) trong 7 ngày qua, kèm các tin \"Tôi\" đã gửi sau đó. Dòng có \"→TÔI\" là tin gửi trực tiếp cho tôi.\n\nNhiệm vụ: "));
    const tail = try std.fmt.allocPrint(a, "dưới id/tiêu đề khác):\n[{{\"id\":\"1\",\"threadId\":\"2\",\"title\":\"t\",\"status\":\"todo\"}}]\n\nTin nhắn:\n" ++
        "### threadId=g1 · Nhóm \"Nhóm dự án\"\n" ++
        "  [m1] {s} An →TÔI: @Tôi gửi báo cáo\n" ++
        "  [m2] {s} Tôi: ok\n\n" ++
        "### threadId=u2 · Cá nhân \"Bình\"\n" ++
        "  [m3] {s} Bình →TÔI: hi\n\n" ++
        "Chỉ trả về MỘT object JSON, không giải thích, dạng:\n" ++
        "{{\"tasks\":[{{\"id\":\"<id việc đã có hoặc null>\",\"threadId\":\"...\",\"msgId\":\"<id tin yêu cầu>\",\"from\":\"<người giao>\",\"title\":\"<việc cần làm, ngắn gọn, tiếng Việt>\",\"detail\":\"<1 câu tóm tắt ngữ cảnh / tôi đã trả lời gì>\",\"status\":\"todo|doing|done\"}}]}}\n" ++
        "Trả về đầy đủ mọi việc (cả việc đã có còn liên quan).", .{ zalo.fmtTime(a, test_now - 5000), zalo.fmtTime(a, test_now - 4000), zalo.fmtTime(a, test_now - 3000) });
    try testing.expect(std.mem.endsWith(u8, prompt, tail));
    try testing.expectEqual(@as(usize, 19), zalo.fmtTime(a, test_now).len);

    const none = try buildPrompt(a, &.{}, &.{});
    try testing.expect(std.mem.indexOf(u8, none, "khác):\n[]\n\nTin nhắn:\n\n\nChỉ trả về") != null);
}

test "what claude printed" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    try testing.expectEqualStrings("hello", try claudeResult(a, &fail, "{\"type\":\"result\",\"is_error\":false,\"result\":\"hello\"}\n", "warning", 0));
    try testing.expectEqualStrings("{\"a\":1}", try claudeResult(a, &fail, " {\"result\":{\"a\":1}} ", "", 0));
    try testing.expectEqualStrings("", try claudeResult(a, &fail, "{\"result\":null}", "", 0));
    try testing.expectEqualStrings("", try claudeResult(a, &fail, "{}", "", 0));
    try testing.expectEqualStrings("", try claudeResult(a, &fail, "null", "", 0));

    try testing.expectError(error.Failed, claudeResult(a, &fail, "{\"is_error\":true,\"result\":\"Rate limited\"}", "", 1));
    try testing.expectEqualStrings("Rate limited", fail.msg);
    try testing.expectError(error.Failed, claudeResult(a, &fail, "{\"is_error\":1,\"result\":\"\"}", "", 1));
    try testing.expectEqualStrings(tr("Claude reported an error", "Claude báo lỗi"), fail.msg);

    // not JSON: what it wrote to stderr, else stdout, else its exit code
    try testing.expectError(error.Failed, claudeResult(a, &fail, "not json", "  boom\n", 1));
    try testing.expectEqualStrings("boom", fail.msg);
    try testing.expectError(error.Failed, claudeResult(a, &fail, try repeat(a, "ờ", 400), "", 1));
    try testing.expectEqualStrings(try repeat(a, "ờ", 300), fail.msg);
    try testing.expectError(error.Failed, claudeResult(a, &fail, "", "", 3));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} 3", .{tr("claude exited with code", "claude thoát với mã")}), fail.msg);
    try testing.expectError(error.Failed, claudeResult(a, &fail, "", "", null));
    try testing.expect(std.mem.endsWith(u8, fail.msg, " null"));
    try testing.expectError(error.Failed, claudeResult(a, &fail, "bad \xff bytes", "", 1));
    try testing.expectEqualStrings("bad \u{fffd} bytes", fail.msg);

    try testing.expect(!truthy(null));
    try testing.expect(!truthy(.null));
    try testing.expect(!truthy(.{ .bool = false }));
    try testing.expect(!truthy(.{ .integer = 0 }));
    try testing.expect(!truthy(.{ .float = 0.0 }));
    try testing.expect(!truthy(.{ .string = "" }));
    try testing.expect(truthy(.{ .bool = true }));
    try testing.expect(truthy(.{ .integer = -1 }));
    try testing.expect(truthy(.{ .string = "false" }));
    try testing.expect(truthy(.{ .array = .init(a) }));
}

test "context: which messages, and how they read" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var all: [200]ZaloMessage = undefined;
    for (&all, 0..) |*msg, i| msg.* = .{ .id = try std.fmt.allocPrint(a, "{d}", .{i}), .ts = @intCast(i * 10) };
    // from the request's message, with 15 before it
    var picked = contextMessages(.{ .msgId = "20", .ts = 9999 }, all[0..50]);
    try testing.expectEqual(@as(usize, 45), picked.len);
    try testing.expectEqualStrings("5", picked[0].id);
    try testing.expectEqualStrings("49", picked[picked.len - 1].id);
    // the message is gone: from the task's time
    picked = contextMessages(.{ .msgId = "zz", .ts = 255 }, all[0..50]);
    try testing.expectEqualStrings("11", picked[0].id);
    picked = contextMessages(.{ .ts = 30 }, all[0..50]);
    try testing.expectEqualStrings("0", picked[0].id);
    try testing.expectEqual(@as(usize, 50), picked.len);
    // nothing to go by: the last 30 (and the 15 before)
    picked = contextMessages(.{ .ts = 99999 }, all[0..50]);
    try testing.expectEqualStrings("5", picked[0].id);
    picked = contextMessages(.{ .ts = 99999 }, all[0..10]);
    try testing.expectEqual(@as(usize, 10), picked.len);
    try testing.expectEqual(@as(usize, 0), contextMessages(.{}, &.{}).len);
    // at most 120
    picked = contextMessages(.{ .msgId = "20" }, &all);
    try testing.expectEqual(@as(usize, 120), picked.len);
    try testing.expectEqualStrings("124", picked[119].id);
    picked = contextMessages(.{ .msgId = "150" }, &all);
    try testing.expectEqual(@as(usize, 65), picked.len);

    const task: ZaloTask = .{ .id = "t1", .title = "Gửi báo cáo", .detail = "đã hẹn chiều nay", .threadId = "g1", .threadName = "Nhóm dự án", .group = true, .msgId = "m1", .from = "An", .ts = 5 };
    try testing.expectEqualStrings(
        "- **An** (T) _(trả lời Tôi: \"a b c\")_ ⟵ **yêu cầu**: dòng 1\n  dòng 2\n  dòng 3",
        try contextLine(a, task, .{ .id = "m1", .from_name = "An", .reply = .{ .from = "Tôi", .text = "a  b\nc" } }, "T", try indentBody(a, "dòng 1\r\ndòng 2\ndòng 3")),
    );
    try testing.expectEqualStrings("- **Tôi** (T): ok", try contextLine(a, task, .{ .id = "m2", .from_name = "Me", .mine = true }, "T", "ok"));
    const quoted = try contextLine(a, task, .{ .id = "m3", .from_name = "An", .reply = .{ .from = "B", .text = try repeat(a, "ờ", 200) } }, "T", "x");
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "- **An** (T) _(trả lời B: \"", try repeat(a, "ờ", 120), "\")_: x" }), quoted);

    try testing.expectEqualStrings("# Việc từ Zalo: Gửi báo cáo\n\n" ++
        "**Hướng dẫn cho bạn (Claude):** Đây là một việc tôi nhận qua Zalo. Hãy đọc kỹ đoạn chat bên dưới và XEM TẤT CẢ ảnh đính kèm (dùng Read với đường dẫn ảnh), mở các tệp đính kèm, rồi tìm hiểu code trong project hiện tại liên quan tới yêu cầu. Sau đó tóm tắt lại yêu cầu bằng tiếng Việt, nêu nguyên nhân / vị trí code liên quan và đề xuất cách xử lý. CHƯA sửa code cho tới khi tôi xác nhận.\n\n" ++
        "- Người yêu cầu: An (nhóm \"Nhóm dự án\")\n- Thời gian: T\n- Tóm tắt: Gửi báo cáo\n- Ngữ cảnh: đã hẹn chiều nay\n" ++
        "- Ảnh đính kèm:\n  - i1\n  - i2\n- Tệp đính kèm:\n  - f1\n" ++
        "\n## Đoạn chat nhóm \"Nhóm dự án\"\n\nLINES\n", try contextMarkdown(a, task, "T", &.{ "i1", "i2" }, &.{"f1"}, "LINES"));
    var personal = task;
    personal.group = false;
    personal.detail = null;
    personal.threadName = "An";
    try testing.expectEqualStrings("# Việc từ Zalo: Gửi báo cáo\n\n" ++
        "**Hướng dẫn cho bạn (Claude):** Đây là một việc tôi nhận qua Zalo. Hãy đọc kỹ đoạn chat bên dưới, rồi tìm hiểu code trong project hiện tại liên quan tới yêu cầu. Sau đó tóm tắt lại yêu cầu bằng tiếng Việt, nêu nguyên nhân / vị trí code liên quan và đề xuất cách xử lý. CHƯA sửa code cho tới khi tôi xác nhận.\n\n" ++
        "- Người yêu cầu: An\n- Thời gian: T\n- Tóm tắt: Gửi báo cáo\n" ++
        "\n## Đoạn chat với An\n\nLINES\n", try contextMarkdown(a, personal, "T", &.{}, &.{}, "LINES"));
}

test "newId, statusTag" {
    try testInit();
    const id = newId();
    for (id, 0..) |ch, i| switch (i) {
        8, 13, 18, 23 => try testing.expectEqual(@as(u8, '-'), ch),
        14 => try testing.expectEqual(@as(u8, '4'), ch),
        19 => try testing.expect(std.mem.indexOfScalar(u8, "89ab", ch) != null),
        else => try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f')),
    };
    try testing.expect(!std.mem.eql(u8, &id, &newId()));

    try testing.expectEqualStrings("#d9922e", statusTag("doing").color);
    try testing.expectEqualStrings("#2f9e63", statusTag("done").color);
    try testing.expectEqualStrings("#e5484d", statusTag("todo").color);
    try testing.expectEqualStrings(tr("To do", "Cần làm"), statusTag("anything").text);
}
