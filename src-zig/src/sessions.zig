//! Reads the Claude Code session store (`~/.claude/projects/<encoded-cwd>/<session>.jsonl`),
//! which the Claude desktop app, the CLI and the IDE extensions all share.
//! The JSONL format is internal to Claude Code, so everything here is best-effort:
//! we only pick out cwd, title and timestamps, and skip whatever we don't recognise.
//!
//! `sessions_context.zig` (context window), `sessions_log.zig` (the Chat view's conversation) and
//! `sessions_util.zig` (JSON / text helpers, the matchers that were regexes) belong to this module.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const watch = @import("watch.zig");
const m = @import("modules.zig");
const u = @import("sessions_util.zig");
const context = @import("sessions_context.zig");
const log = @import("sessions_log.zig");
const sq = @import("sqlite");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Value = u.Value;

pub const commands = .{
    .{ "sessions_list", sessions_list },
    .{ "sessions_images", sessions_images },
    .{ "sessions_context", sessions_context },
    .{ "sessions_tasks", sessions_tasks },
    .{ "sessions_files", sessions_files },
    .{ "sessions_log", sessions_log },
    .{ "sessions_delete", sessions_delete },
};

// ---------------- types (mirror src/shared/types.ts) ----------------

pub const SessionInfo = struct {
    id: []const u8,
    title: []const u8,
    /// folder the session ran in — `claude --resume` must run from here
    cwd: []const u8,
    /// repo the session belongs to (worktree sessions roll up to their repo)
    projectCwd: []const u8,
    created: i64,
    updated: i64,
    cwdExists: bool,
    /// the coding agent whose chat this is, when it is not Claude Code: "codex" (a literal, not owned)
    agent: ?[]const u8 = null,

    fn clone(s: SessionInfo, a: Allocator) !SessionInfo {
        var c = s;
        c.id = try a.dupe(u8, s.id);
        c.title = try a.dupe(u8, s.title);
        c.cwd = try a.dupe(u8, s.cwd);
        c.projectCwd = try a.dupe(u8, s.projectCwd);
        return c;
    }
};

pub const ProjectGroup = struct {
    key: []const u8,
    cwd: []const u8,
    name: []const u8,
    updated: i64,
    sessions: []const SessionInfo,
};

pub const ChatTask = struct {
    id: []const u8,
    command: []const u8,
    description: []const u8,
    /// running, completed, failed, killed… (as Claude Code reports it)
    status: []const u8,
    startedAt: i64,
    endedAt: ?i64 = null,
    outputFile: ?[]const u8 = null,
    /// the end of its output
    output: ?[]const u8 = null,

    /// unset fields are left out (the Rust build's skip_serializing_if)
    pub fn jsonStringify(t: ChatTask, w: anytype) !void {
        try w.beginObject();
        inline for (@typeInfo(ChatTask).@"struct".field_names) |name| {
            const v = @field(t, name);
            if (@typeInfo(@TypeOf(v)) == .optional) {
                if (v) |some| {
                    try w.objectField(name);
                    try w.write(some);
                }
            } else {
                try w.objectField(name);
                try w.write(v);
            }
        }
        try w.endObject();
    }
};

pub const ChatFile = struct {
    path: []const u8,
    /// created, edited or read (a file Claude read and then changed counts as changed)
    action: []const u8,
    /// successful Write / Edit calls on it
    edits: u32,
    /// the last time Claude touched it
    at: i64,
    exists: bool,
};

pub const SessionImages = struct {
    /// changes whenever a picture is added
    version: u64,
    /// null when the caller already has this version (nothing re-encoded or sent)
    images: ?[]const []const u8,
};

/// JSON written while a scan was locked, passed on as it is.
const Json = struct {
    text: []const u8,

    pub fn jsonStringify(j: Json, w: anytype) !void {
        try w.print("{s}", .{j.text});
    }
};

// ---------------- commands ----------------

pub fn sessions_list(c: *ipc.Call) ![]const ProjectGroup {
    watchSessions();
    return listSessions(c.arena);
}

pub fn sessions_images(c: *ipc.Call, args: struct { sessionId: []const u8, since: ?u64 = null }) !SessionImages {
    return sessionImages(c.arena, args.sessionId, args.since);
}

pub fn sessions_context(c: *ipc.Call, args: struct { sessionId: []const u8 }) !?context.Context {
    return sessionContext(c.arena, args.sessionId);
}

pub fn sessions_tasks(c: *ipc.Call, args: struct { sessionId: []const u8 }) ![]const ChatTask {
    return sessionTasks(c.arena, args.sessionId);
}

pub fn sessions_files(c: *ipc.Call, args: struct { sessionId: []const u8 }) ![]const ChatFile {
    return sessionFiles(c.arena, args.sessionId);
}

pub fn sessions_log(c: *ipc.Call, args: struct { sessionId: []const u8 }) !?Json {
    return sessionLog(c.arena, args.sessionId);
}

/// Delete a conversation from Claude Code's store: its transcript (and its subagent folder) go to the Recycle Bin.
pub fn sessions_delete(c: *ipc.Call, args: struct { sessionId: []const u8 }) !void {
    const id = args.sessionId;
    const ok = for (id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') break false;
    } else id.len > 0;
    if (!ok) return c.fail("bad session id", .{});
    if (!try deleteSession(c.arena, id))
        return c.failMsg(settings.tr("this chat has no saved history", "chat này không có lịch sử đã lưu"));
}

/// False when no project has a transcript of that session.
fn deleteSession(a: Allocator, id: []const u8) !bool {
    const root = try projectsDir(a);
    var dir = try Dir.cwd().openDir(core.io, root, .{ .iterate = true });
    defer dir.close(core.io);
    var found = false;
    const name = try std.mem.concat(a, u8, &.{ id, ".jsonl" });
    var it = dir.iterate();
    while (it.next(core.io) catch null) |e| {
        const file = try std.fs.path.join(a, &.{ root, e.name, name });
        if (core.isFile(file)) {
            try trash(file);
            found = true;
        }
        const sub = try std.fs.path.join(a, &.{ root, e.name, id });
        if (core.isDir(sub)) try trash(sub);
    }
    return found;
}

/// To the Recycle Bin (deleted outright in a build without the files module).
fn trash(path: []const u8) !void {
    if (@hasDecl(m.fsx, "trash")) return m.fsx.trash(path);
    if (core.isDir(path)) try Dir.cwd().deleteTree(core.io, path) else try Dir.cwd().deleteFile(core.io, path);
}

// ---------------- session list ----------------

/// tests read a folder of their own
var test_root: ?[]const u8 = null;

pub fn projectsDir(a: Allocator) ![]u8 {
    if (builtin.is_test) if (test_root) |r| return a.dupe(u8, r);
    return std.fs.path.join(a, &.{ core.home(), ".claude", "projects" });
}

const Cached = struct {
    mtime: i96,
    size: u64,
    info: ?SessionInfo,

    fn free(c: Cached) void {
        const i = c.info orelse return;
        for ([_][]const u8{ i.id, i.title, i.cwd, i.projectCwd }) |s| core.gpa.free(s);
    }
};

var cache_mutex: core.Mutex = .{};
/// by transcript path; keys and infos are owned by `core.gpa`
var cache: std.StringHashMapUnmanaged(Cached) = .empty;

const win = if (core.is_windows) @import("win") else struct {};

/// When a file was created (Unix ms), where the system keeps that.
fn createdMs(a: Allocator, file: []const u8) ?i64 {
    if (!core.is_windows) return null;
    const path = core.wide(a, file) catch return null;
    var data: win.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win.GetFileAttributesExW(path, win.GetFileExInfoStandard, &data) == 0) return null;
    // 100 ns ticks since 1601
    const ticks = (@as(u64, data.ftCreationTime.dwHighDateTime) << 32) | data.ftCreationTime.dwLowDateTime;
    return @as(i64, @intCast(ticks / 10_000)) - 11_644_473_600_000;
}

/// `length` bytes from `start` (fewer at the end of the file), as they are: callers that show
/// them make them UTF-8 (`u.lossy`), JSON lines are checked when they are parsed.
fn readSlice(a: Allocator, file: []const u8, start: u64, length: u64) ![]u8 {
    var f = try Dir.cwd().openFile(core.io, file, .{});
    defer f.close(core.io);
    const buf = try a.alloc(u8, @intCast(length));
    return buf[0..try f.readPositionalAll(core.io, buf, start)];
}

fn parseLines(a: Allocator, text: []const u8, drop_first: bool) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    if (drop_first) _ = it.next(); // probably cut mid-line
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, "{")) continue;
        try out.append(a, u.parseObj(a, l) orelse continue); // partial lines fail and are skipped
    }
    return out.items;
}

/// skip injected command / system wrappers
fn realPrompt(t: []const u8) bool {
    return t.len > 0 and t[0] != '<' and !std.mem.startsWith(u8, t, "Caveat:");
}

fn userText(a: Allocator, rec: Value) !?[]const u8 {
    if (!u.isType(rec, "user")) return null;
    const text: []const u8 = switch (u.get(u.get(rec, "message"), "content") orelse return null) {
        .string => |s| if (realPrompt(u.trim(s))) u.trim(s) else return null,
        // the prompt may follow injected blocks (<system-reminder>, IDE context…) in the same message
        .array => |items| for (items.items) |c| {
            if (!u.isType(c, "text")) continue;
            const t = u.trim(u.strOf(c, "text") orelse continue);
            if (realPrompt(t)) break t;
        } else return null,
        else => return null,
    };
    return try u.collapseWs(a, text);
}

fn findTitle(recs: []const Value) ?[]const u8 {
    var i = recs.len;
    while (i > 0) {
        i -= 1;
        if (!u.isType(recs[i], "custom-title")) continue;
        const t = u.trim(u.strOf(recs[i], "customTitle") orelse continue);
        if (t.len > 0) return t;
    }
    i = recs.len;
    while (i > 0) {
        i -= 1;
        if (u.isType(recs[i], "summary")) if (u.strOf(recs[i], "summary")) |s| return s;
    }
    return null;
}

/// The session a transcript holds (null: nothing to show, e.g. no prompt yet), allocated in `a`.
fn readSession(a: Allocator, file: []const u8, dir_name: []const u8) !?SessionInfo {
    const st = try Dir.cwd().statFile(core.io, file, .{});
    const mtime = st.mtime.nanoseconds;
    const size = st.size;
    {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        if (cache.get(file)) |hit| if (hit.mtime == mtime and hit.size == size)
            return if (hit.info) |i| try i.clone(a) else null;
    }

    const HEAD = 96 * 1024;
    const TAIL = 256 * 1024;
    const head = try parseLines(a, try readSlice(a, file, 0, @min(HEAD, size)), false);
    const tail: []const Value = if (size > HEAD) try parseLines(a, try readSlice(a, file, size -| TAIL, @min(TAIL, size)), true) else &.{};

    var cwd: ?[]const u8 = null;
    var first_prompt: ?[]const u8 = null;
    var created: ?i64 = null;
    for (head) |r| {
        if (cwd == null) if (u.strOf(r, "cwd")) |c| if (c.len > 0) {
            cwd = c;
        };
        if (created == null) if (u.strOf(r, "timestamp")) |ts| if (u.parseDate(ts)) |t| if (t != 0) {
            created = t;
        };
        if (first_prompt == null) first_prompt = try userText(a, r);
        if (cwd != null and first_prompt != null and created != null) break;
    }

    const head_title = findTitle(head);
    const mtime_ms = st.mtime.toMilliseconds();
    var info: ?SessionInfo = null;
    if (first_prompt != null or (head_title != null and head_title.?.len > 0)) {
        const title = findTitle(tail) orelse head_title orelse if (first_prompt) |p| u.takeChars(p, 90) else "";
        const dir = cwd orelse try decodeDirName(a, dir_name);
        // "updated" = the last real message, not the file's mtime: just opening/resuming a chat
        // appends bookkeeping records (titles, snapshots…) that would bump it to "now"
        const recs = if (tail.len == 0) head else tail;
        var last_msg: ?i64 = null;
        var i = recs.len;
        while (i > 0 and last_msg == null) {
            i -= 1;
            if (!u.isType(recs[i], "user") and !u.isType(recs[i], "assistant")) continue;
            const t = u.parseDate(u.strOf(recs[i], "timestamp") orelse continue) orelse continue;
            if (t != 0) last_msg = t;
        }
        info = .{
            .id = std.fs.path.stem(file),
            .title = title,
            .cwd = dir,
            .projectCwd = projectRoot(dir),
            .created = created orelse createdMs(a, file) orelse mtime_ms,
            .updated = last_msg orelse mtime_ms,
            .cwdExists = core.exists(dir),
        };
    }

    cache_mutex.lock();
    defer cache_mutex.unlock();
    const entry: Cached = .{ .mtime = mtime, .size = size, .info = if (info) |i| try i.clone(core.gpa) else null };
    errdefer entry.free();
    const slot = try cache.getOrPut(core.gpa, file);
    if (slot.found_existing) {
        slot.value_ptr.free();
    } else {
        slot.key_ptr.* = core.gpa.dupe(u8, file) catch |e| {
            cache.removeByPtr(slot.key_ptr);
            return e;
        };
    }
    slot.value_ptr.* = entry;
    return info;
}

/// Lossy fallback when no record carries a cwd: "E--softek-core2" → "E:\softek\core2".
fn decodeDirName(a: Allocator, d: []const u8) ![]const u8 {
    if (d.len < 3 or !std.ascii.isAlphabetic(d[0]) or d[1] != '-' or d[2] != '-') return a.dupe(u8, d);
    const out = try std.fmt.allocPrint(a, "{c}:\\{s}", .{ d[0], d[3..] });
    std.mem.replaceScalar(u8, out[3..], '-', '\\');
    return out;
}

/// Worktree sessions belong to the repo they were cut from.
fn projectRoot(cwd: []const u8) []const u8 {
    return u.worktreeRepo(cwd) orelse cwd;
}

/// `path.basename(p)` and `path.basename(path.dirname(p))` the way Node's `path` sees them
/// (drive prefix dropped on Windows): "" where there is none.
fn lastParts(path: []const u8) struct { name: []const u8, parent: []const u8 } {
    var p = path;
    if (core.is_windows and p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) p = p[2..];
    var name: []const u8 = "";
    var parent: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, p, if (core.is_windows) "/\\" else "/");
    while (it.next()) |part| {
        parent = name;
        name = part;
    }
    return .{ .name = name, .parent = parent };
}

/// `a.localeCompare(b, undefined, { sensitivity: 'base', numeric: true })`, approximately:
/// case-insensitive (the caller lowercases both), digit runs compared by value.
fn naturalCmp(x: []const u8, y: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        if (i == x.len and j == y.len) return .eq;
        if (i == x.len) return .lt;
        if (j == y.len) return .gt;
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[j])) {
            const n = std.mem.trimStart(u8, digitRun(x, &i), "0");
            const d = std.mem.trimStart(u8, digitRun(y, &j), "0");
            const o = if (n.len != d.len) std.math.order(n.len, d.len) else std.mem.order(u8, n, d);
            if (o != .eq) return o;
        } else {
            // bytes of UTF-8 order like the characters they spell
            if (x[i] != y[j]) return std.math.order(x[i], y[j]);
            i += 1;
            j += 1;
        }
    }
}

fn digitRun(s: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) i.* += 1;
    return s[start..i.*];
}

fn newerFirst(_: void, x: SessionInfo, y: SessionInfo) bool {
    return if (x.updated != y.updated) x.updated > y.updated else std.mem.lessThan(u8, x.id, y.id);
}

const Job = struct {
    file: []const u8,
    dir: []const u8,
    /// a Codex rollout, not a Claude transcript
    codex: bool = false,
};

/// Unchanged files are a cache hit (one stat); a cold start reads them on a few threads.
const Readers = struct {
    jobs: []const Job,
    next: std.atomic.Value(usize) = .init(0),
    mutex: core.Mutex = .{},
    /// owns `found`
    a: Allocator,
    found: std.ArrayList(SessionInfo) = .empty,

    fn run(r: *Readers) void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        while (true) {
            const i = r.next.fetchAdd(1, .monotonic);
            if (i >= r.jobs.len) return;
            _ = scratch.reset(.retain_capacity);
            const job = r.jobs[i];
            const read = if (job.codex) readRollout(scratch.allocator(), job.file) else readSession(scratch.allocator(), job.file, job.dir);
            const info = (read catch continue) orelse continue;
            r.mutex.lock();
            defer r.mutex.unlock();
            r.found.append(r.a, info.clone(r.a) catch continue) catch {};
        }
    }
};

fn listSessions(a: Allocator) ![]const ProjectGroup {
    const root = try projectsDir(a);
    var jobs: std.ArrayList(Job) = .empty;
    // (a PC with Codex alone has no such folder)
    if (Dir.cwd().openDir(core.io, root, .{ .iterate = true })) |opened| {
        var rd = opened;
        defer rd.close(core.io);
        var it = rd.iterate();
        while (it.next(core.io) catch null) |e| {
            if (e.kind != .directory) continue;
            const d = try a.dupe(u8, e.name);
            var sub = rd.openDir(core.io, d, .{ .iterate = true }) catch continue;
            defer sub.close(core.io);
            var files = sub.iterate();
            while (files.next(core.io) catch null) |f| {
                if (std.mem.endsWith(u8, f.name, ".jsonl"))
                    try jobs.append(a, .{ .file = try std.fs.path.join(a, &.{ root, d, f.name }), .dir = d });
            }
        }
    } else |_| {}
    // Codex's chats, one file each
    if (codexHome(a)) |home| try rolloutJobs(a, try std.fs.path.join(a, &.{ home, "sessions" }), 0, &jobs) else |_| {}

    // files that are gone drop out of the cache
    {
        var live: std.StringHashMapUnmanaged(void) = .empty;
        for (jobs.items) |j| try live.put(a, j.file, {});
        var gone: std.ArrayList([]const u8) = .empty;
        cache_mutex.lock();
        defer cache_mutex.unlock();
        var it = cache.iterator();
        while (it.next()) |e| if (!live.contains(e.key_ptr.*)) try gone.append(a, e.key_ptr.*);
        for (gone.items) |k| {
            const old = cache.fetchRemove(k).?;
            old.value.free();
            core.gpa.free(old.key);
        }
    }

    var readers: Readers = .{ .jobs = jobs.items, .a = a };
    {
        const cpus = std.Thread.getCpuCount() catch 4;
        const workers = @min(std.math.clamp(cpus, 1, 8), @max(jobs.items.len, 1));
        var threads: [8]?std.Thread = @splat(null);
        for (threads[0 .. workers - 1]) |*t| t.* = std.Thread.spawn(.{}, Readers.run, .{&readers}) catch null;
        readers.run();
        for (threads) |t| if (t) |th| th.join();
    }
    // Codex's chats go under the same projects. Its database knows them best (the name it gave
    // each, the archived ones); a rollout file only speaks for a chat the database does not have
    // (a Codex from before it kept one).
    if (codexDb(a)) |db| {
        var known: std.StringHashMapUnmanaged(void) = .empty;
        if (codexSessions(a, db, &known)) |list| {
            var n: usize = 0;
            for (readers.found.items) |x| {
                if (x.agent != null and known.contains(x.id)) continue;
                readers.found.items[n] = x;
                n += 1;
            }
            readers.found.shrinkRetainingCapacity(n);
            try readers.found.appendSlice(a, list);
        } else |_| {}
    }
    const all = readers.found.items;
    // newest first, so a group takes its folder spelling from its latest session
    std.mem.sort(SessionInfo, all, {}, newerFirst);

    // groups in the order their first (newest) session comes, each one's sessions newest first
    var groups: std.ArrayList(ProjectGroup) = .empty;
    var members: std.ArrayList(std.ArrayList(SessionInfo)) = .empty;
    var by_key: std.StringHashMapUnmanaged(usize) = .empty;
    for (all) |s| {
        const key = std.mem.trimEnd(u8, try u.lower(a, s.projectCwd), "\\/");
        const slot = try by_key.getOrPut(a, key);
        if (!slot.found_existing) {
            slot.value_ptr.* = groups.items.len;
            const base = lastParts(s.projectCwd).name;
            try groups.append(a, .{ .key = key, .cwd = s.projectCwd, .name = if (base.len == 0) s.projectCwd else base, .updated = 0, .sessions = &.{} });
            try members.append(a, .empty);
        }
        const g = &groups.items[slot.value_ptr.*];
        g.updated = @max(g.updated, s.updated);
        try members.items[slot.value_ptr.*].append(a, s);
    }
    const list = groups.items;
    for (list, members.items) |*g, sessions| g.sessions = sessions.items;

    // Two folders with the same name ("monk" in two places) → add the parent folder to tell them apart.
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    const low_names = try a.alloc([]const u8, list.len);
    for (list, low_names) |g, *low| {
        low.* = try u.lower(a, g.name);
        const slot = try by_name.getOrPut(a, low.*);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }
    for (list, low_names) |*g, low| {
        if (by_name.get(low).? < 2) continue;
        const parent = lastParts(g.cwd).parent;
        if (parent.len > 0) g.name = try std.fmt.allocPrint(a, "{s} · {s}", .{ g.name, parent });
    }
    std.mem.sort(ProjectGroup, list, a, struct {
        fn lt(arena: Allocator, x: ProjectGroup, y: ProjectGroup) bool {
            const lx = u.lower(arena, x.name) catch x.name;
            const ly = u.lower(arena, y.name) catch y.name;
            return naturalCmp(lx, ly) == .lt;
        }
    }.lt);
    return list;
}

// ---------------- Codex's chats ----------------

/// Codex's folder: `$CODEX_HOME`, else `~/.codex`.
fn codexHome(a: Allocator) ![]const u8 {
    // tests: next to their own store
    if (builtin.is_test) return std.fs.path.join(a, &.{ std.fs.path.dirname(test_root orelse return error.NoStore) orelse return error.NoStore, "codex" });
    if (core.getenv("CODEX_HOME")) |h| if (h.len > 0) return a.dupe(u8, h);
    return std.fs.path.join(a, &.{ core.home(), ".codex" });
}

/// `<n>` of "state_<n>.sqlite".
fn stateVersion(name: []const u8) ?u32 {
    const head = "state_";
    const tail = ".sqlite";
    if (!std.mem.startsWith(u8, name, head) or !std.mem.endsWith(u8, name, tail) or name.len <= head.len + tail.len) return null;
    return std.fmt.parseInt(u32, name[head.len .. name.len - tail.len], 10) catch null;
}

/// Codex (the CLI, its desktop app and its IDE extension share it) keeps its conversations in
/// `state_<n>.sqlite`, table `threads`; `<n>` grows with its schema. The newest one, or null
/// where Codex was never used.
fn codexDb(a: Allocator) ?[]const u8 {
    const home = codexHome(a) catch return null;
    var dir = Dir.cwd().openDir(core.io, home, .{ .iterate = true }) catch return null;
    defer dir.close(core.io);
    var best: ?u32 = null;
    var it = dir.iterate();
    while (it.next(core.io) catch null) |e| {
        const n = stateVersion(e.name) orelse continue;
        if (best == null or n > best.?) best = n;
    }
    const name = std.fmt.allocPrint(a, "state_{d}.sqlite", .{best orelse return null}) catch return null;
    return std.fs.path.join(a, &.{ home, name }) catch null;
}

fn columnText(a: Allocator, stmt: ?*sq.sqlite3_stmt, col: c_int) ![]const u8 {
    const p = sq.sqlite3_column_text(stmt, col);
    if (p == null) return "";
    const n: usize = @intCast(sq.sqlite3_column_bytes(stmt, col));
    const text = p[0..n];
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return a.dupe(u8, text);
}

/// Codex writes Windows folders as `\\?\E:\repo`.
fn plainPath(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "\\\\?\\") and !std.mem.startsWith(u8, p, "\\\\?\\UNC\\")) p[4..] else p;
}

/// Whether `p` can be a folder's path at all (one read out of a message may be anything).
fn pathLike(p: []const u8) bool {
    return p.len > 0 and p.len < 1024 and std.fs.path.isAbsolute(p) and std.mem.indexOfAny(u8, p[@min(p.len, 3)..], "<>|\"?*:\r\n\t") == null;
}

/// Codex's timestamps are seconds; newer columns are milliseconds.
fn toMs(t: i64) i64 {
    return if (t > 0 and t < 100_000_000_000) t * 1000 else t;
}

/// The conversations in Codex's database that are not archived, as sessions of the agent "codex"
/// (`codex resume <id>` picks one back up). Read-only: Codex may have the file open.
/// `known` gets the id of every one of them, archived or not.
fn codexSessions(a: Allocator, db_path: []const u8, known: *std.StringHashMapUnmanaged(void)) ![]const SessionInfo {
    var db: ?*sq.sqlite3 = null;
    defer _ = sq.sqlite3_close(db);
    if (sq.sqlite3_open_v2((try a.dupeSentinel(u8, db_path, 0)).ptr, &db, sq.SQLITE_OPEN_READONLY | sq.SQLITE_OPEN_NOMUTEX, null) != sq.SQLITE_OK) return error.Sqlite;
    _ = sq.sqlite3_busy_timeout(db, 500);
    // `name` (what Codex or the user called the chat) came with a later schema than `title`
    const queries = [_][*:0]const u8{
        "SELECT id, cwd, COALESCE(NULLIF(name, ''), title), created_at, updated_at, archived FROM threads",
        "SELECT id, cwd, title, created_at, updated_at, archived FROM threads",
    };
    var stmt: ?*sq.sqlite3_stmt = null;
    for (queries) |sql| {
        if (sq.sqlite3_prepare_v2(db, sql, -1, &stmt, null) == sq.SQLITE_OK) break;
        stmt = null;
    }
    if (stmt == null) return error.Sqlite;
    defer _ = sq.sqlite3_finalize(stmt);
    var out: std.ArrayList(SessionInfo) = .empty;
    while (true) {
        const rc = sq.sqlite3_step(stmt);
        if (rc == sq.SQLITE_DONE) break;
        if (rc != sq.SQLITE_ROW) return error.Sqlite;
        const id = columnText(a, stmt, 0) catch continue;
        if (id.len > 0) try known.put(a, id, {});
        const cwd = plainPath(columnText(a, stmt, 1) catch continue);
        if (id.len == 0 or !pathLike(cwd) or sq.sqlite3_column_int64(stmt, 5) != 0) continue;
        // one line, like the titles of Claude's chats
        var lines = std.mem.tokenizeAny(u8, columnText(a, stmt, 2) catch "", "\r\n");
        const first = std.mem.trim(u8, lines.next() orelse "", " \t");
        try out.append(a, .{
            .id = id,
            .title = if (first.len > 0) first else "Codex chat",
            .cwd = cwd,
            .projectCwd = projectRoot(cwd),
            .created = toMs(sq.sqlite3_column_int64(stmt, 3)),
            .updated = toMs(sq.sqlite3_column_int64(stmt, 4)),
            .cwdExists = core.exists(cwd),
            .agent = "codex",
        });
    }
    return out.items;
}

/// Every `rollout-*.jsonl` under Codex's `sessions/<year>/<month>/<day>/`. (Those a newer Codex
/// compressed, `.jsonl.zst`, are in its database.)
fn rolloutJobs(a: Allocator, dir_path: []const u8, depth: usize, jobs: *std.ArrayList(Job)) !void {
    var dir = Dir.cwd().openDir(core.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(core.io);
    var it = dir.iterate();
    while (it.next(core.io) catch null) |e| {
        if (e.kind == .directory) {
            if (depth < 3) try rolloutJobs(a, try std.fs.path.join(a, &.{ dir_path, e.name }), depth + 1, jobs);
        } else if (std.mem.startsWith(u8, e.name, "rollout-") and std.mem.endsWith(u8, e.name, ".jsonl")) {
            try jobs.append(a, .{ .file = try std.fs.path.join(a, &.{ dir_path, e.name }), .dir = "", .codex = true });
        }
    }
}

/// The id a rollout's name ends with: "rollout-2025-08-01T10-00-00-<uuid>.jsonl".
fn rolloutId(file: []const u8) ?[]const u8 {
    const stem = std.fs.path.stem(file);
    if (stem.len < 36) return null;
    const id = stem[stem.len - 36 ..];
    for (id, 0..) |ch, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (if (dash) ch != '-' else !std.ascii.isHex(ch)) return null;
    }
    return id;
}

/// The folder an `<environment_context>` block names: `<cwd>…</cwd>`, or before that
/// "Current working directory: …".
fn contextCwd(t: []const u8) ?[]const u8 {
    if (std.mem.find(u8, t, "<cwd>")) |i| {
        const rest = t[i + 5 ..];
        if (std.mem.find(u8, rest, "</cwd>")) |j| return u.trim(rest[0..j]);
    }
    const label = "Current working directory:";
    const i = std.mem.find(u8, t, label) orelse return null;
    const rest = t[i + label.len ..];
    return u.trim(rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len]);
}

/// What the user asked for in a message: the IDE extension puts its context before the request.
fn codexPrompt(t: []const u8) ?[]const u8 {
    const mark = "## My request for Codex:";
    const asked = u.trim(if (std.mem.find(u8, t, mark)) |i| t[i + mark.len ..] else t);
    return if (realPrompt(asked)) asked else null;
}

/// One Codex chat from its rollout file, or null for one nothing was asked in (or a sub-agent's).
/// Its records changed shape over time: first the bare items of the conversation after a line
/// `{ id, timestamp }`, then each wrapped as `{ timestamp, type, payload }` with a `session_meta`
/// first; the folder was at first only told to the model, in an `<environment_context>` message.
fn readRollout(a: Allocator, file: []const u8) !?SessionInfo {
    const st = try Dir.cwd().statFile(core.io, file, .{});
    const mtime = st.mtime.nanoseconds;
    const size = st.size;
    {
        cache_mutex.lock();
        defer cache_mutex.unlock();
        if (cache.get(file)) |hit| if (hit.mtime == mtime and hit.size == size)
            return if (hit.info) |i| try i.clone(a) else null;
    }

    // (the first line carries Codex's whole system prompt)
    const HEAD = 768 * 1024;
    const head = try parseLines(a, try readSlice(a, file, 0, @min(HEAD, size)), false);
    var id: ?[]const u8 = rolloutId(file);
    var cwd: ?[]const u8 = null;
    var created: ?i64 = null;
    var prompt: ?[]const u8 = null;
    var sub_agent = false;
    for (head, 0..) |rec, n| {
        const body = if (u.get(rec, "payload")) |p| (if (p == .object) p else rec) else rec;
        if (u.isType(rec, "session_meta") or (n == 0 and u.strOf(rec, "type") == null)) {
            if (u.strOf(body, "id")) |x| if (x.len > 0) {
                id = x;
            };
            if (created == null) if (u.strOf(body, "timestamp")) |ts| if (u.parseDate(ts)) |t| if (t != 0) {
                created = t;
            };
            // a chat an agent started for itself says who did, where the others say "cli", "vscode"…
            if (u.get(body, "source")) |src| sub_agent = src == .object;
        }
        if (cwd == null) if (u.strOf(body, "cwd")) |x| if (x.len > 0) {
            cwd = x;
        };
        if (prompt != null and cwd != null) break;
        if (u.isType(rec, "event_msg")) {
            if (prompt == null and u.isType(body, "user_message")) if (u.strOf(body, "message")) |t| {
                prompt = codexPrompt(t);
            };
            continue;
        }
        if (!u.isType(body, "message") or !std.mem.eql(u8, u.strOf(body, "role") orelse "", "user")) continue;
        const content = u.get(body, "content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |c| {
            const t = u.trim(u.strOf(c, "text") orelse continue);
            if (std.mem.startsWith(u8, t, "<environment_context>")) {
                if (cwd == null) cwd = contextCwd(t);
            } else if (prompt == null) prompt = codexPrompt(t);
        }
    }

    var info: ?SessionInfo = null;
    if (!sub_agent and id != null and cwd != null and pathLike(plainPath(cwd.?)) and prompt != null) {
        const dir = plainPath(cwd.?);
        const mtime_ms = st.mtime.toMilliseconds();
        info = .{
            .id = id.?,
            .title = u.takeChars(try u.collapseWs(a, prompt.?), 90),
            .cwd = dir,
            .projectCwd = projectRoot(dir),
            .created = created orelse createdMs(a, file) orelse mtime_ms,
            .updated = mtime_ms,
            .cwdExists = core.exists(dir),
            .agent = "codex",
        };
    }

    cache_mutex.lock();
    defer cache_mutex.unlock();
    const entry: Cached = .{ .mtime = mtime, .size = size, .info = if (info) |i| try i.clone(core.gpa) else null };
    errdefer entry.free();
    const slot = try cache.getOrPut(core.gpa, file);
    if (slot.found_existing) {
        slot.value_ptr.free();
    } else {
        slot.key_ptr.* = core.gpa.dupe(u8, file) catch |e| {
            cache.removeByPtr(slot.key_ptr);
            return e;
        };
    }
    slot.value_ptr.* = entry;
    return info;
}

// ---------------- watcher ----------------

var watch_mutex: core.Mutex = .{};
var watcher: ?*watch.Watcher = null;
/// the store's folder, as the watcher was given it
var watch_root: []const u8 = "";

/// The sessions whose transcript changed since the last ping, filled by the watcher's callback.
const Ping = struct {
    mutex: core.Mutex = .{},
    cond: std.Io.Condition = .init,
    /// owned by `core.gpa`; "*" when events were lost and any chat may have changed
    ids: std.StringHashMapUnmanaged(void) = .empty,
    /// something changed since the last ping (a project folder coming or going leaves `ids` empty)
    dirty: bool = false,
    /// changes in all: each one restarts the debounce
    count: u64 = 0,
};
var ping: Ping = .{};

fn isJsonl(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.extension(path), ".jsonl");
}

/// Whether a change under the store should refresh the list: project folders coming and going,
/// and `.jsonl` files directly inside them (chokidar `depth: 1` with non-jsonl files ignored).
fn relevant(root: []const u8, ev: watch.Event) bool {
    const structural = ev.kind == .create or ev.kind == .remove or ev.kind == .rename;
    const p = ev.path;
    if (!std.mem.startsWith(u8, p, root)) return false;
    var rel = p[root.len..];
    if (root.len > 0 and !u.isSlash(root[root.len - 1])) {
        if (rel.len == 0 or !u.isSlash(rel[0])) return false;
        rel = rel[1..];
    }
    var depth: usize = 0;
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |_| depth += 1;
    if (depth < 1 or depth > 2) return false;
    if (isJsonl(p)) return true;
    // folders: only adds / removes, not "something inside changed"
    return structural and (core.isDir(p) or !core.exists(p));
}

/// What to ping for a change: the session whose transcript it is, "" for a project folder coming
/// or going, "*" when events were lost; null when the change does not matter.
fn changedId(root: []const u8, ev: watch.Event) ?[]const u8 {
    // an overflow (many chats writing at once) loses events: every chat re-reads
    if (ev.kind == .rescan) return "*";
    if (!relevant(root, ev)) return null;
    return if (isJsonl(ev.path)) std.fs.path.stem(ev.path) else "";
}

fn onChanges(_: ?*anyopaque, events: []const watch.Event) void {
    for (events) |ev| {
        const id = changedId(watch_root, ev) orelse continue;
        ping.mutex.lock();
        defer ping.mutex.unlock();
        ping.dirty = true;
        ping.count += 1;
        if (id.len > 0 and !ping.ids.contains(id)) {
            const own = core.gpa.dupe(u8, id) catch continue;
            ping.ids.put(core.gpa, own, {}) catch core.gpa.free(own);
        }
        ping.cond.signal(core.io);
    }
}

/// Waits for a change, then for the changes to stop, and takes the ids they left (the caller
/// frees them: `freeIds`).
/// trailing debounce: one ping 600 ms after the last change, but at least every 1.5 s - several
/// chats streaming at once never go quiet for 600 ms, which held every ping back until all stopped
fn waitPing() std.StringHashMapUnmanaged(void) {
    ping.mutex.lock();
    defer ping.mutex.unlock();
    while (!ping.dirty) ping.cond.waitUncancelable(core.io, &ping.mutex.m);
    const deadline = core.monoMs() + 1500;
    var quiet = core.monoMs() + 600;
    var seen = ping.count;
    while (true) {
        const now = core.monoMs();
        const until = @min(deadline, quiet);
        if (now >= until) break;
        ping.cond.waitTimeout(core.io, &ping.mutex.m, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(until - now)), .clock = .awake } }) catch {};
        if (ping.count != seen) {
            seen = ping.count;
            quiet = core.monoMs() + 600;
        }
    }
    defer ping.ids = .empty;
    ping.dirty = false;
    return ping.ids;
}

fn freeIds(ids: *std.StringHashMapUnmanaged(void)) void {
    var it = ids.keyIterator();
    while (it.next()) |k| core.gpa.free(k.*);
    ids.deinit(core.gpa);
}

fn pingLoop() void {
    while (true) {
        var ids = waitPing();
        defer freeIds(&ids);
        // listeners for one chat (its images, tasks, context) skip pings for other chats ("*": none skip)
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(core.gpa);
        var it = ids.keyIterator();
        while (it.next()) |k| list.append(core.gpa, k.*) catch {};
        core.emit("sessions:changed", .{list.items});
    }
}

/// Push a "sessions changed" ping whenever Claude (any client) writes to the store.
fn watchSessions() void {
    watch_mutex.lock();
    defer watch_mutex.unlock();
    if (watcher != null) return;
    const root = projectsDir(core.gpa) catch return;
    watch_root = root;
    // the store may not exist yet: leave the slot empty so the next list call tries again
    // (the watcher only hands over what changed, a few ms later; the debounce is `pingLoop`'s)
    const w = watch.start(&.{root}, .{ .debounce_ms = 20 }, onChanges, null) catch {
        watch_root = "";
        core.gpa.free(root);
        return;
    };
    const t = std.Thread.spawn(.{}, pingLoop, .{}) catch {
        w.stop();
        watch_root = "";
        core.gpa.free(root);
        return;
    };
    t.detach();
    watcher = w;
}

// ---------------- one session's file ----------------

fn validId(id: []const u8) bool {
    for (id) |b| if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '-') return false;
    return id.len > 0;
}

/// The transcript of a session, in whichever project has it (owned by `core.gpa`).
fn findSessionFile(session_id: []const u8) ?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = projectsDir(a) catch return null;
    const name = std.mem.concat(a, u8, &.{ session_id, ".jsonl" }) catch return null;
    var dir = Dir.cwd().openDir(core.io, root, .{ .iterate = true }) catch return null;
    defer dir.close(core.io);
    var it = dir.iterate();
    while (it.next(core.io) catch null) |e| {
        const f = std.fs.path.join(a, &.{ root, e.name, name }) catch return null;
        if (core.exists(f)) return core.gpa.dupe(u8, f) catch null;
    }
    return null;
}

// ---------------- reading a transcript as it grows ----------------

/// open chats' scans kept; the least recently used goes first
const SCAN_KEEP = 8;
var scan_clock: std.atomic.Value(u64) = .init(0);

/// A transcript only ever grows. Images and background tasks used to re-read (and re-parse) the
/// whole file - often tens of MB - every time any chat wrote a line; now each remembers how far
/// it got and parses only the new lines.
///
/// `S` is what is kept of a session: `.{}` to start with, `feed(*S, a, text)` takes the new lines
/// (`a` lives as long as the scan), and `deinit(*S)` frees what it keeps outside `a`, if anything.
fn ScanCache(comptime S: type) type {
    return struct {
        mutex: core.Mutex = .{},
        /// by session id (the scan's own copy)
        map: std.StringHashMapUnmanaged(*Scan) = .empty,

        const Self = @This();

        const Scan = struct {
            id: []const u8,
            file: []const u8,
            offset: u64 = 0,
            last_use: u64 = 0,
            arena: std.heap.ArenaAllocator,
            state: S = .{},

            fn clear(sc: *Scan) void {
                if (@hasDecl(S, "deinit")) sc.state.deinit();
                sc.state = .{};
                _ = sc.arena.reset(.free_all);
                sc.offset = 0;
            }

            fn destroy(sc: *Scan) void {
                sc.clear();
                core.gpa.free(sc.id);
                core.gpa.free(sc.file);
                core.gpa.destroy(sc);
            }
        };

        /// Feeds the lines added since the last call (a rewritten / shorter file starts over) and
        /// returns the session's state with the cache locked: read it, then `release`.
        /// Null (and nothing locked) for a session that has no transcript.
        fn acquire(self: *Self, session_id: []const u8) ?*const S {
            if (!validId(session_id)) return null;
            self.mutex.lock();
            const sc = self.advance(session_id) orelse {
                self.mutex.unlock();
                return null;
            };
            return &sc.state;
        }

        fn release(self: *Self) void {
            if (self.map.count() > SCAN_KEEP) {
                var oldest: ?*Scan = null;
                var it = self.map.valueIterator();
                while (it.next()) |sc| if (oldest == null or sc.*.last_use < oldest.?.last_use) {
                    oldest = sc.*;
                };
                _ = self.map.remove(oldest.?.id);
                oldest.?.destroy();
            }
            self.mutex.unlock();
        }

        fn advance(self: *Self, session_id: []const u8) ?*Scan {
            const known = self.map.get(session_id);
            if (known == null or !core.exists(known.?.file)) {
                const file = findSessionFile(session_id) orelse return null;
                const sc = core.gpa.create(Scan) catch {
                    core.gpa.free(file);
                    return null;
                };
                sc.* = .{ .id = core.gpa.dupe(u8, session_id) catch "", .file = file, .arena = .init(core.gpa) };
                if (sc.id.len == 0) {
                    sc.destroy();
                    return null;
                }
                if (known) |old| {
                    _ = self.map.remove(old.id);
                    old.destroy();
                }
                self.map.put(core.gpa, sc.id, sc) catch {
                    sc.destroy();
                    return null;
                };
            }
            const sc = self.map.get(session_id).?;
            sc.last_use = scan_clock.fetchAdd(1, .monotonic);
            const len = (Dir.cwd().statFile(core.io, sc.file, .{}) catch return null).size;
            if (len < sc.offset) sc.clear();
            if (len > sc.offset) {
                var f = Dir.cwd().openFile(core.io, sc.file, .{}) catch return null;
                defer f.close(core.io);
                const buf = core.gpa.alloc(u8, @intCast(len - sc.offset)) catch return null;
                defer core.gpa.free(buf);
                const got = buf[0..(f.readPositionalAll(core.io, buf, sc.offset) catch return null)];
                // only whole lines: the one Claude is still writing waits for the next call
                if (std.mem.findScalarLast(u8, got, '\n')) |end| {
                    sc.offset += end + 1;
                    sc.state.feed(sc.arena.allocator(), got[0..end]) catch {};
                }
            }
            return sc;
        }

        /// Forgets every scan (tests).
        fn reset(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |sc| sc.*.destroy();
            self.map.deinit(core.gpa);
            self.map = .empty;
        }
    };
}

// ---------------- images in a session ----------------

const MAX_IMAGES = 40;
const MAX_FILE_BYTES = 8 * 1024 * 1024;

fn imageMime(ext: []const u8) ?[]const u8 {
    const names = [_][2][]const u8{ .{ "png", "image/png" }, .{ "jpg", "image/jpeg" }, .{ "jpeg", "image/jpeg" }, .{ "gif", "image/gif" }, .{ "webp", "image/webp" } };
    for (names) |n| if (std.ascii.eqlIgnoreCase(ext, n[0])) return n[1];
    return null;
}

/// A picture of the conversation: a data: URL, or the path of an image file.
const Found = struct {
    is_path: bool,
    /// owned by `core.gpa` (inline pictures are big: the old ones are freed as they drop out)
    text: []const u8,
};

const ImageWalk = struct {
    /// the newest pictures only (inline ones are big)
    found: std.ArrayList(Found) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// pictures found so far: the list's version
    total: u64 = 0,

    pub fn deinit(w: *ImageWalk) void {
        for (w.found.items) |f| core.gpa.free(f.text);
        w.found.deinit(core.gpa);
    }

    /// `parts` together are the picture (see `Found`); `key` tells whether it was seen before.
    fn add(w: *ImageWalk, a: Allocator, key: []const u8, is_path: bool, parts: []const []const u8) !void {
        const slot = try w.seen.getOrPut(a, key);
        if (slot.found_existing) return;
        slot.key_ptr.* = a.dupe(u8, key) catch |e| {
            w.seen.removeByPtr(slot.key_ptr);
            return e;
        };
        const text = try std.mem.concat(core.gpa, u8, parts);
        errdefer core.gpa.free(text);
        try w.found.append(core.gpa, .{ .is_path = is_path, .text = text });
        w.total += 1;
        if (w.found.items.len > MAX_IMAGES * 2) {
            const drop = w.found.items.len - MAX_IMAGES;
            for (w.found.items[0..drop]) |f| core.gpa.free(f.text);
            w.found.replaceRangeAssumeCapacity(0, drop, &.{});
        }
    }

    fn feed(w: *ImageWalk, a: Allocator, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "image") == null and !u.hasImageExt(line)) continue;
            _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
            // partial line while Claude is writing
            const row = u.parseLine(sa, line) orelse continue;
            const from_user = u.isType(row, "user");
            const content = u.get(u.get(row, "message"), "content") orelse continue;
            if (content == .string) {
                if (from_user) try w.paths(a, sa, content.string);
            } else try w.walk(a, sa, content, from_user);
        }
    }

    fn walk(w: *ImageWalk, a: Allocator, sa: Allocator, blocks: Value, from_user: bool) Allocator.Error!void {
        for (u.arr(blocks)) |b| {
            if (b != .object) continue;
            const ty = u.strOf(b, "type") orelse continue;
            if (std.mem.eql(u8, ty, "image")) {
                const src = u.obj(u.get(b, "source")) orelse continue;
                if (!u.isType(src, "base64")) continue;
                const data = u.strOf(src, "data") orelse continue;
                if (data.len == 0) continue;
                const key = try std.fmt.allocPrint(sa, "{s}{d}", .{ u.takeChars(data, 200), data.len });
                try w.add(a, key, false, &.{ "data:", u.strOf(src, "media_type") orelse "image/png", ";base64,", data });
            } else if (std.mem.eql(u8, ty, "tool_result")) {
                if (u.get(b, "content")) |c| try w.walk(a, sa, c, false);
            } else if (std.mem.eql(u8, ty, "text") and from_user) {
                if (u.strOf(b, "text")) |t| try w.paths(a, sa, t);
            }
        }
    }

    /// Image files named in something the user wrote.
    fn paths(w: *ImageWalk, a: Allocator, sa: Allocator, text: []const u8) Allocator.Error!void {
        var it: u.ImagePaths = .{ .text = text };
        while (it.next()) |p| try w.add(a, try u.lower(sa, p), true, &.{p});
    }
};

var image_scans: ScanCache(ImageWalk) = .{};

/// Every image in a chat, oldest first: pictures pasted into the conversation, screenshots tools
/// returned, and image files named in the user's messages. Returned as data: URLs.
fn sessionImages(a: Allocator, session_id: []const u8, since: ?u64) !SessionImages {
    var items: []Found = &.{};
    var version: u64 = 0;
    {
        const w = image_scans.acquire(session_id) orelse return .{ .version = 0, .images = &.{} };
        defer image_scans.release();
        version = w.total;
        if (since != null and since.? == w.total) return .{ .version = version, .images = null };
        const last = w.found.items[w.found.items.len -| MAX_IMAGES..];
        items = try a.alloc(Found, last.len);
        for (items, last) |*item, f| item.* = .{ .is_path = f.is_path, .text = try a.dupe(u8, f.text) };
    }
    // files are read and encoded outside the lock
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (!item.is_path) {
            try out.append(a, item.text);
            continue;
        }
        const p = item.text;
        const mime = imageMime(p[(std.mem.findScalarLast(u8, p, '.') orelse continue) + 1 ..]) orelse continue;
        // the file may be gone (e.g. temp paste cleaned up)
        const st = Dir.cwd().statFile(core.io, p, .{}) catch continue;
        if (st.kind != .file or st.size > MAX_FILE_BYTES) continue;
        const bytes = core.readFileAlloc(a, p, MAX_FILE_BYTES + 1) catch continue;
        const enc = std.base64.standard.Encoder;
        const head = try std.fmt.allocPrint(a, "data:{s};base64,", .{mime});
        const url = try a.alloc(u8, head.len + enc.calcSize(bytes.len));
        @memcpy(url[0..head.len], head);
        _ = enc.encode(url[head.len..], bytes);
        try out.append(a, url);
    }
    return .{ .version = version, .images = out.items };
}

// ---------------- context window ----------------

var context_scans: ScanCache(context.ContextWalk) = .{};

/// How full a chat's context window is: the token count of the last main-thread API call
/// (input + cache read + cache write + output), and roughly what it's made of.
fn sessionContext(a: Allocator, session_id: []const u8) !?context.Context {
    const w = context_scans.acquire(session_id) orelse return null;
    defer context_scans.release();
    var c = try w.result(a) orelse return null;
    // the names are the scan's: copies outlive the lock
    c.model = try a.dupe(u8, c.model);
    for (@constCast(c.tools)) |*t| t.name = try a.dupe(u8, t.name);
    return c;
}

// ---------------- background tasks ----------------

const TaskCall = struct { command: []const u8, description: []const u8 };
const TaskEnd = struct { status: []const u8, at: i64 };

const TaskScan = struct {
    calls: std.StringHashMapUnmanaged(TaskCall) = .empty,
    /// in the order the tasks started: a task set again keeps its first place, like a JS Map
    tasks: std.ArrayList(ChatTask) = .empty,
    task_index: std.StringHashMapUnmanaged(usize) = .empty,
    ended: std.StringHashMapUnmanaged(TaskEnd) = .empty,

    fn feed(s: *TaskScan, a: Allocator, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "run_in_background") == null and std.mem.find(u8, line, "backgroundTaskId") == null and
                std.mem.find(u8, line, "<task-notification>") == null) continue;
            _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
            const row = u.parseObj(sa, line) orelse continue;
            const at = u.rowTime(sa, row);
            const content: ?Value = if (u.get(u.get(row, "message"), "content")) |c| (if (c == .array) c else null) else null;

            if (u.isType(row, "assistant")) for (u.arr(content)) |b| {
                if (b != .object or !u.isType(b, "tool_use")) continue;
                const input = u.obj(u.get(b, "input"));
                const id = u.strOf(b, "id") orelse continue;
                if (id.len == 0 or !u.truthy(u.get(input, "run_in_background"))) continue;
                const slot = try s.calls.getOrPut(a, id);
                if (!slot.found_existing) slot.key_ptr.* = try a.dupe(u8, id);
                slot.value_ptr.* = .{
                    .command = try a.dupe(u8, try u.jsStringCoalesce(sa, input, &.{ "command", "prompt" })),
                    .description = try a.dupe(u8, try u.jsStringCoalesce(sa, input, &.{"description"})),
                };
            };

            const task_id = u.strOf(u.get(row, "toolUseResult"), "backgroundTaskId") orelse "";
            if (task_id.len > 0 and content != null) {
                const r: ?Value = for (u.arr(content)) |b| {
                    if (b == .object and u.isType(b, "tool_result")) break b;
                } else null;
                const msg: []const u8 = if (u.get(r, "content")) |c| switch (c) {
                    .string => |str| str,
                    .null => "\"\"",
                    else => try u.jsonText(sa, c, sa),
                } else "\"\"";
                const call = s.calls.get(u.strOf(r, "tool_use_id") orelse "");
                const task: ChatTask = .{
                    .id = try a.dupe(u8, task_id),
                    .command = if (call) |c| c.command else "",
                    .description = if (call) |c| c.description else "",
                    .status = "running",
                    .startedAt = at,
                    .outputFile = if (u.outputFile(msg)) |f| try a.dupe(u8, f) else null,
                };
                const slot = try s.task_index.getOrPut(a, task.id);
                if (slot.found_existing) {
                    s.tasks.items[slot.value_ptr.*] = task;
                } else {
                    slot.value_ptr.* = s.tasks.items.len;
                    try s.tasks.append(a, task);
                }
            }

            // the notification shows up several times (queued, delivered): the first one is when it ended
            var notes: u.TaskNotes = .{ .text = u.strOf(row, "content") orelse line };
            while (notes.next()) |n| {
                const slot = try s.ended.getOrPut(a, n.id);
                if (slot.found_existing) continue;
                slot.key_ptr.* = try a.dupe(u8, n.id);
                slot.value_ptr.* = .{ .status = try a.dupe(u8, n.status), .at = at };
            }
        }
    }
};

var task_scans: ScanCache(TaskScan) = .{};

/// Background tasks Claude started in a chat (Bash/PowerShell with run_in_background), with their
/// status from the task notifications and the last part of their output file.
fn sessionTasks(a: Allocator, session_id: []const u8) ![]const ChatTask {
    var tasks: []ChatTask = &.{};
    {
        const s = task_scans.acquire(session_id) orelse return &.{};
        defer task_scans.release();
        tasks = try a.alloc(ChatTask, s.tasks.items.len);
        // the newest first
        for (tasks, 0..) |*t, i| {
            const src = s.tasks.items[s.tasks.items.len - 1 - i];
            t.* = .{
                .id = try a.dupe(u8, src.id),
                .command = try a.dupe(u8, src.command),
                .description = try a.dupe(u8, src.description),
                .status = src.status,
                .startedAt = src.startedAt,
                .outputFile = if (src.outputFile) |f| try a.dupe(u8, f) else null,
            };
            if (s.ended.get(src.id)) |end| {
                t.status = try a.dupe(u8, end.status);
                t.endedAt = end.at;
            }
        }
    }
    for (tasks) |*t| {
        const out_file = t.outputFile orelse continue;
        // the output file may have been cleaned up
        const st = Dir.cwd().statFile(core.io, out_file, .{}) catch continue;
        const tail = readSlice(a, out_file, st.size -| 6000, 6000) catch continue;
        t.output = try u.stripAnsi(a, try u.lossy(a, tail), false);
    }
    return tasks;
}

// ---------------- files Claude touched ----------------

const Touch = enum { write, edit, read };
const PendingCall = struct { path: []const u8, touch: Touch };

const FileScan = struct {
    /// tool calls waiting for their result (a failed Edit changed nothing)
    pending: std.StringHashMapUnmanaged(PendingCall) = .empty,
    /// in order of first touch; `index` is keyed by the lowercased path
    files: std.ArrayList(ChatFile) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,

    fn awaited(s: *const FileScan, line: []const u8) bool {
        if (s.pending.count() == 0 or std.mem.find(u8, line, "tool_result") == null) return false;
        var it = s.pending.keyIterator();
        while (it.next()) |id| if (std.mem.find(u8, line, id.*) != null) return true;
        return false;
    }

    fn feed(s: *FileScan, a: Allocator, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const call = std.mem.find(u8, line, "\"file_path\"") != null or std.mem.find(u8, line, "\"notebook_path\"") != null;
            if (!call and !s.awaited(line)) continue;
            _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
            const row = u.parseObj(sa, line) orelse continue;
            // only the conversation's own rows: others (api-request-blob…) repeat its tool calls
            const assistant = u.isType(row, "assistant");
            const user = u.isType(row, "user");
            if (!assistant and !user) continue;
            const content = u.get(u.get(row, "message"), "content") orelse continue;
            if (content != .array) continue;
            const at = u.rowTime(sa, row);
            // a Write over an existing file is an edit; over nothing, a new file
            const created = u.isType(u.get(row, "toolUseResult"), "create");
            for (content.array.items) |b| {
                if (b != .object) continue;
                if (assistant and u.isType(b, "tool_use")) {
                    const name = u.strOf(b, "name") orelse continue;
                    const touch: Touch = if (std.mem.eql(u8, name, "Write"))
                        .write
                    else if (std.mem.eql(u8, name, "Edit") or std.mem.eql(u8, name, "MultiEdit") or std.mem.eql(u8, name, "NotebookEdit"))
                        .edit
                    else if (std.mem.eql(u8, name, "Read"))
                        .read
                    else
                        continue;
                    const input = u.obj(u.get(b, "input"));
                    const path = u.strOf(input, "file_path") orelse u.strOf(input, "notebook_path") orelse "";
                    const id = u.strOf(b, "id") orelse continue;
                    if (path.len == 0) continue;
                    const slot = try s.pending.getOrPut(a, id);
                    if (!slot.found_existing) slot.key_ptr.* = try a.dupe(u8, id);
                    slot.value_ptr.* = .{ .path = try a.dupe(u8, path), .touch = touch };
                } else if (user and u.isType(b, "tool_result")) {
                    const done = s.pending.fetchRemove(u.strOf(b, "tool_use_id") orelse continue) orelse continue;
                    if (!u.truthy(u.get(b, "is_error"))) try s.touched(a, sa, done.value.path, done.value.touch, created, at);
                }
            }
        }
    }

    fn touched(s: *FileScan, a: Allocator, sa: Allocator, path: []const u8, touch: Touch, created: bool, at: i64) !void {
        const slashed = try sa.dupe(u8, path);
        std.mem.replaceScalar(u8, slashed, '/', '\\');
        const key = try u.lower(sa, slashed);
        const slot = try s.index.getOrPut(a, key);
        if (!slot.found_existing) {
            slot.key_ptr.* = try a.dupe(u8, key);
            slot.value_ptr.* = s.files.items.len;
            try s.files.append(a, .{ .path = path, .action = "read", .edits = 0, .at = at, .exists = true });
        }
        const f = &s.files.items[slot.value_ptr.*];
        f.at = @max(f.at, at);
        if (touch == .read) return;
        f.edits += 1;
        if (touch == .write and created) {
            f.action = "created";
        } else if (std.mem.eql(u8, f.action, "read")) {
            f.action = "edited";
        }
    }
};

var file_scans: ScanCache(FileScan) = .{};

/// Files Claude created, edited or read in a chat (its Write / Edit / Read tools), most recent first.
fn sessionFiles(a: Allocator, session_id: []const u8) ![]const ChatFile {
    var files: []ChatFile = &.{};
    {
        const s = file_scans.acquire(session_id) orelse return &.{};
        defer file_scans.release();
        files = try a.dupe(ChatFile, s.files.items);
        for (files) |*f| f.path = try a.dupe(u8, f.path);
    }
    std.mem.sort(ChatFile, files, {}, struct {
        fn lt(_: void, x: ChatFile, y: ChatFile) bool {
            return x.at > y.at;
        }
    }.lt);
    for (files) |*f| f.exists = core.isFile(f.path);
    return files;
}

// ---------------- the conversation, for the Chat view ----------------

var log_scans: ScanCache(log.LogScan) = .{};

/// The conversation of a chat (its last items), for the Chat view.
fn sessionLog(a: Allocator, session_id: []const u8) !?Json {
    const s = log_scans.acquire(session_id) orelse return null;
    defer log_scans.release();
    return .{ .text = try core.toJson(a, s.log()) };
}

// ---------------- tests ----------------

const testing = std.testing;

test {
    _ = u;
    _ = context;
    _ = log;
}

fn times(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const done = comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &done;
}

/// A store of its own for a test: `tmp/projects`, with the caches empty.
const TestStore = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init() !TestStore {
        core.gpa = testing.allocator;
        core.io = testing.io;
        var t: TestStore = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .root = "" };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try t.tmp.dir.realPath(testing.io, &buf);
        t.root = try std.fs.path.join(t.arena.allocator(), &.{ buf[0..n], "projects" });
        try core.makePath(t.root);
        test_root = t.root;
        return t;
    }

    fn deinit(t: *TestStore) void {
        test_root = null;
        var it = cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.free();
            core.gpa.free(e.key_ptr.*);
        }
        cache.deinit(core.gpa);
        cache = .empty;
        image_scans.reset();
        context_scans.reset();
        task_scans.reset();
        file_scans.reset();
        log_scans.reset();
        t.arena.deinit();
        t.tmp.cleanup();
    }

    fn path(t: *TestStore, parts: []const []const u8) ![]const u8 {
        const a = t.arena.allocator();
        return std.fs.path.join(a, &.{ t.root, try std.fs.path.join(a, parts) });
    }

    fn write(t: *TestStore, parts: []const []const u8, data: []const u8) ![]const u8 {
        const p = try t.path(parts);
        try core.writeFile(p, data);
        return p;
    }
};

test "paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("E:\\softek\\core2", try decodeDirName(a, "E--softek-core2"));
    try testing.expectEqualStrings("-home-me", try decodeDirName(a, "-home-me"));
    try testing.expectEqualStrings("E:\\x\\repo", projectRoot("E:\\x\\repo\\.claude\\worktrees\\a"));
    try testing.expectEqualStrings("E:\\x\\repo", projectRoot("E:\\x\\repo"));
    try testing.expectEqual(std.math.Order.gt, naturalCmp("a10", "a9"));
    try testing.expectEqual(std.math.Order.eq, naturalCmp("a010", "a10"));
    try testing.expectEqual(std.math.Order.lt, naturalCmp("a2b", "a2c"));
    try testing.expectEqual(std.math.Order.lt, naturalCmp("a", "ab"));
    try testing.expectEqual(std.math.Order.gt, naturalCmp("b", "ab"));
    if (core.is_windows) {
        try testing.expectEqualStrings("core2", lastParts("E:\\softek\\core2\\").name);
        try testing.expectEqualStrings("softek", lastParts("E:\\softek/core2").parent);
        try testing.expectEqualStrings("", lastParts("E:\\").name);
        try testing.expectEqualStrings("", lastParts("E:\\x").parent);
    }
    try testing.expect(validId("0a1b-2c_3"));
    try testing.expect(!validId("") and !validId("../x") and !validId("a b"));
}

test "session list: titles, groups and the cache" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const repo = try std.fs.path.join(a, &.{ t.root, "repo" });
    const repo_json = try core.toJson(a, repo);
    const wt_json = try core.toJson(a, try std.fs.path.join(a, &.{ repo, ".claude", "worktrees", "fix" }));

    // a plain session: the title is its first real prompt
    _ = try t.write(&.{ "X--repo", "s1.jsonl" }, try std.fmt.allocPrint(a,
        \\{{"type":"file-history-snapshot"}}
        \\{{"type":"user","cwd":{s},"timestamp":"2025-01-02T03:04:05.000Z","message":{{"role":"user","content":[{{"type":"text","text":"<ide_opened_file>x</ide_opened_file>"}},{{"type":"text","text":"  fix   the\n bug "}}]}}}}
        \\{{"type":"assistant","cwd":{s},"timestamp":"2025-01-02T03:05:00.000Z","message":{{"role":"assistant","content":[]}}}}
        \\{{"type":"custom-title","customTitle":"   "}}
        \\not json
        \\
    , .{ repo_json, repo_json }));
    // in a worktree of the same repo, renamed by the user; then only bookkeeping rows
    _ = try t.write(&.{ "X--repo--claude-worktrees-fix", "s2.jsonl" }, try std.fmt.allocPrint(a,
        \\{{"type":"user","cwd":{s},"timestamp":"2025-02-02T00:00:00.000Z","message":{{"role":"user","content":"Caveat: injected"}}}}
        \\{{"type":"user","cwd":{s},"timestamp":"2025-02-02T00:00:01.000Z","message":{{"role":"user","content":"hello"}}}}
        \\{{"type":"summary","summary":"An older summary"}}
        \\{{"type":"custom-title","customTitle":" Renamed "}}
        \\{{"type":"system","timestamp":"2025-03-03T00:00:00.000Z"}}
        \\
    , .{ wt_json, wt_json }));
    // no prompt and no title: not listed
    _ = try t.write(&.{ "X--repo", "s3.jsonl" }, "{\"type\":\"file-history-snapshot\"}\n");
    // no cwd in any row: the folder's name stands in
    _ = try t.write(&.{ "Q--other-repo", "s4.jsonl" }, "{\"type\":\"user\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"content\":\"elsewhere\"}}\n");
    _ = try t.write(&.{ "Q--other-repo", "notes.txt" }, "x");
    _ = try t.write(&.{"stray.jsonl"}, "{}\n");

    const list = try listSessions(a);
    try testing.expectEqual(@as(usize, 2), list.len);
    // "repo" in two places: the parent folder tells them apart
    try testing.expectEqualStrings("repo · other", list[0].name);
    try testing.expectEqualStrings("Q:\\other\\repo", list[0].cwd);
    try testing.expectEqualStrings("q:\\other\\repo", list[0].key);
    try testing.expectEqual(@as(usize, 1), list[0].sessions.len);
    try testing.expectEqualStrings("elsewhere", list[0].sessions[0].title);
    try testing.expect(!list[0].sessions[0].cwdExists);
    try testing.expectEqual(@as(i64, 1_735_689_600_000), list[0].sessions[0].updated);

    try testing.expectEqualStrings("repo · projects", list[1].name);
    try testing.expectEqualStrings(repo, list[1].cwd);
    try testing.expectEqualStrings(try u.lower(a, repo), list[1].key);
    try testing.expectEqual(@as(i64, 1_738_454_401_000), list[1].updated);
    try testing.expectEqual(@as(usize, 2), list[1].sessions.len);
    const s2 = list[1].sessions[0];
    try testing.expectEqualStrings("s2", s2.id);
    try testing.expectEqualStrings("Renamed", s2.title);
    try testing.expectEqualStrings(repo, s2.projectCwd);
    try testing.expect(std.mem.endsWith(u8, s2.cwd, "fix"));
    try testing.expectEqual(@as(i64, 1_738_454_400_000), s2.created);
    try testing.expectEqual(@as(i64, 1_738_454_401_000), s2.updated);
    const s1 = list[1].sessions[1];
    try testing.expectEqualStrings("fix the bug", s1.title);
    try testing.expectEqual(@as(i64, 1_735_787_045_000), s1.created);
    try testing.expectEqual(@as(i64, 1_735_787_100_000), s1.updated);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"id\":\"s1\",\"title\":\"fix the bug\",\"cwd\":{s},\"projectCwd\":{s},\"created\":1735787045000,\"updated\":1735787100000,\"cwdExists\":false,\"agent\":null}}", .{ repo_json, repo_json }),
        try core.toJson(a, s1),
    );

    // every transcript is cached, the unlisted one too; a deleted one drops out
    try testing.expectEqual(@as(u32, 4), cache.count());
    try Dir.cwd().deleteFile(core.io, try t.path(&.{ "Q--other-repo", "s4.jsonl" }));
    try core.makePath(repo);
    const again = try listSessions(a);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqualStrings("repo", again[0].name);
    try testing.expectEqual(@as(u32, 3), cache.count());
    // unchanged files come from the cache as they were read
    try testing.expect(!again[0].sessions[1].cwdExists);
}

test "session list: long transcripts are read at both ends" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "{\"type\":\"user\",\"cwd\":\"/w/proj\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"content\":\"" ++ times("long prompt ", 10) ++ "\"}}\n");
    const filler = "{\"type\":\"assistant\",\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" ++ times("x", 1000) ++ "\"}]}}\n";
    for (0..400) |_| try text.appendSlice(a, filler);
    try text.appendSlice(a, "{\"type\":\"summary\",\"summary\":\"From the tail\"}\n{\"type\":\"user\",\"timestamp\":\"2025-06-01T00:00:00Z\",\"message\":{\"content\":\"last\"}}\n{\"type\":\"custom-title\",\"customTi");
    _ = try t.write(&.{ "p", "long.jsonl" }, text.items);
    const list = try listSessions(a);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("proj", list[0].name);
    const s = list[0].sessions[0];
    try testing.expectEqualStrings("From the tail", s.title);
    try testing.expectEqual(@as(i64, 1_735_689_600_000), s.created);
    try testing.expectEqual(@as(i64, 1_748_736_000_000), s.updated);

    // without a title, the first 90 characters of the prompt
    _ = try t.write(&.{ "p", "plain.jsonl" }, "{\"type\":\"user\",\"cwd\":\"/w/proj\",\"message\":{\"content\":\"" ++ times("long prompt ", 10) ++ "\"}}\n");
    const both = try listSessions(a);
    const plain = for (both[0].sessions) |x| {
        if (std.mem.eql(u8, x.id, "plain")) break x;
    } else unreachable;
    try testing.expectEqualStrings(times("long prompt ", 10)[0..90], plain.title);
    // no timestamp in the file: the file's own times
    try testing.expect(plain.created > 1_700_000_000_000 and plain.updated > 1_700_000_000_000);
}

test "scan: only the new whole lines are read" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try testing.expect(try sessionLog(a, "nope") == null);
    try testing.expect(try sessionLog(a, "../s") == null);
    try testing.expectEqual(@as(usize, 0), (try sessionTasks(a, "nope")).len);
    try testing.expectEqual(@as(usize, 0), (try sessionFiles(a, "nope")).len);
    try testing.expect(try sessionContext(a, "nope") == null);
    try testing.expectEqualStrings("{\"version\":0,\"images\":[]}", try core.toJson(a, try sessionImages(a, "nope", null)));

    const one = "{\"type\":\"user\",\"uuid\":\"1\",\"message\":{\"content\":\"one\"}}\n";
    const two = "{\"type\":\"user\",\"uuid\":\"2\",\"message\":{\"content\":\"two\"}}";
    const file = try t.write(&.{ "p", "s.jsonl" }, one ++ two);
    const empty = "\"todos\":[],\"todosAt\":0,\"skipped\":0,\"outTokens\":0,\"turnOutTokens\":0}";
    // the second line is still being written
    try testing.expectEqualStrings("{\"items\":[{\"kind\":\"user\",\"text\":\"one\",\"at\":0}]," ++ empty, (try sessionLog(a, "s")).?.text);
    try testing.expectEqual(@as(u64, one.len), log_scans.map.get("s").?.offset);
    try core.writeFile(file, one ++ two ++ "\n");
    try testing.expectEqualStrings("{\"items\":[{\"kind\":\"user\",\"text\":\"one\",\"at\":0},{\"kind\":\"user\",\"text\":\"two\",\"at\":0}]," ++ empty, (try sessionLog(a, "s")).?.text);
    // nothing new: nothing changes
    try testing.expectEqual(@as(usize, 2), log_scans.map.get("s").?.state.items.items.len);
    _ = try sessionLog(a, "s");
    try testing.expectEqual(@as(usize, 2), log_scans.map.get("s").?.state.items.items.len);
    // a rewritten, shorter file starts over
    try core.writeFile(file, "{\"type\":\"user\",\"uuid\":\"9\",\"message\":{\"content\":\"new\"}}\n");
    try testing.expectEqualStrings("{\"items\":[{\"kind\":\"user\",\"text\":\"new\",\"at\":0}]," ++ empty, (try sessionLog(a, "s")).?.text);

    // the least recently used scans go
    for (0..SCAN_KEEP + 2) |i| {
        const id = try std.fmt.allocPrint(a, "k{d}", .{i});
        _ = try t.write(&.{ "p", try std.mem.concat(a, u8, &.{ id, ".jsonl" }) }, one);
        try testing.expect(try sessionLog(a, id) != null);
    }
    try testing.expectEqual(@as(u32, SCAN_KEEP), log_scans.map.count());
    try testing.expect(!log_scans.map.contains("s") and !log_scans.map.contains("k1") and log_scans.map.contains("k2"));
}

test "images of a session" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const pic = try t.write(&.{"shot.PNG"}, "\x89PNG");
    const pic_json = try core.toJson(a, try std.mem.concat(a, u8, &.{ "look at ", pic, " and ", try u.lower(a, pic), " and C:\\gone\\x.jpg" }));
    _ = try t.write(&.{ "p", "s.jsonl" }, try std.fmt.allocPrint(a,
        \\{{"type":"user","message":{{"content":[{{"type":"image","source":{{"type":"base64","media_type":"image/jpeg","data":"QUJD"}}}},{{"type":"image","source":{{"type":"url","url":"https://x/y.png"}}}},{{"type":"image","source":{{"type":"base64","data":""}}}}]}}}}
        \\{{"type":"assistant","message":{{"content":[{{"type":"text","text":"I saved C:\\out\\made.png for you"}}]}}}}
        \\{{"type":"user","message":{{"content":[{{"type":"tool_result","content":[{{"type":"image","source":{{"type":"base64","data":"REVG"}}}},{{"type":"image","source":{{"type":"base64","media_type":"image/jpeg","data":"QUJD"}}}},{{"type":"text","text":"wrote C:\\out\\tool.png"}}]}}]}}}}
        \\{{"type":"user","message":{{"content":{s}}}}}
        \\{{"type":"user","message":{{"content":"no pictures here"}}}}
        \\
    , .{pic_json}));
    const got = try sessionImages(a, "s", null);
    try testing.expectEqual(@as(u64, 4), got.version);
    const images = got.images.?;
    // the file that is gone is left out
    try testing.expectEqual(@as(usize, 3), images.len);
    try testing.expectEqualStrings("data:image/jpeg;base64,QUJD", images[0]);
    try testing.expectEqualStrings("data:image/png;base64,REVG", images[1]);
    try testing.expectEqualStrings("data:image/png;base64,iVBORw==", images[2]);
    try testing.expectEqualStrings("{\"version\":4,\"images\":null}", try core.toJson(a, try sessionImages(a, "s", 4)));
    try testing.expect((try sessionImages(a, "s", 3)).images != null);

    // only the newest are kept
    var w: ImageWalk = .{};
    defer w.deinit();
    for (0..MAX_IMAGES * 2 + 1) |i| try w.add(a, try std.fmt.allocPrint(a, "k{d}", .{i}), false, &.{ "data:", try std.fmt.allocPrint(a, "{d}", .{i}) });
    try w.add(a, "k3", false, &.{"again"});
    try testing.expectEqual(@as(u64, MAX_IMAGES * 2 + 1), w.total);
    try testing.expectEqual(@as(usize, MAX_IMAGES), w.found.items.len);
    try testing.expectEqualStrings("data:41", w.found.items[0].text);
}

test "background tasks of a session" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const out = try t.write(&.{"b1.output"}, times("x", 7000) ++ "\x1b[32mdone\x1b[0m \xff\n");
    const note = try core.toJson(a, try std.mem.concat(a, u8, &.{ "Command running in background with ID: b1. Output is being written to: ", out }));
    _ = try t.write(&.{ "p", "s.jsonl" }, try std.fmt.allocPrint(a,
        \\{{"type":"assistant","timestamp":"2025-01-01T00:00:00Z","message":{{"content":[{{"type":"tool_use","id":"t1","name":"Bash","input":{{"command":"npm run dev","description":"Start the server","run_in_background":true}}}},{{"type":"tool_use","id":"t2","name":"Agent","input":{{"prompt":"look around","run_in_background":true}}}},{{"type":"tool_use","id":"t3","name":"Bash","input":{{"command":"ls","run_in_background":false}}}}]}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:01Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"t1","content":{s}}}]}},"toolUseResult":{{"backgroundTaskId":"b1"}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:02Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"t2","content":[{{"type":"text","text":"started"}}]}}]}},"toolUseResult":{{"backgroundTaskId":"b2"}}}}
        \\{{"type":"queue-operation","timestamp":"2025-01-01T00:01:00Z","content":"<task-notification>\n<task-id>b2</task-id>\n<status>completed</status>\n</task-notification>"}}
        \\{{"type":"user","timestamp":"2025-01-01T00:02:00Z","message":{{"content":"<task-notification>\n<task-id>b2</task-id>\n<status>completed</status>\n</task-notification>"}}}}
        \\
    , .{note}));
    const tasks = try sessionTasks(a, "s");
    try testing.expectEqual(@as(usize, 2), tasks.len);
    try testing.expectEqualStrings(
        "{\"id\":\"b2\",\"command\":\"look around\",\"description\":\"\",\"status\":\"completed\",\"startedAt\":1735689602000,\"endedAt\":1735689660000}",
        try core.toJson(a, tasks[0]),
    );
    try testing.expectEqualStrings("b1", tasks[1].id);
    try testing.expectEqualStrings("npm run dev", tasks[1].command);
    try testing.expectEqualStrings("Start the server", tasks[1].description);
    try testing.expectEqualStrings("running", tasks[1].status);
    try testing.expect(tasks[1].endedAt == null);
    try testing.expectEqualStrings(out, tasks[1].outputFile.?);
    // the last 6000 bytes, without colours, as UTF-8
    try testing.expectEqualStrings(times("x", 5984) ++ "done \u{fffd}\n", tasks[1].output.?);
    try testing.expect(std.mem.find(u8, try core.toJson(a, tasks[1]), "\"endedAt\"") == null);
}

test "files a session touched" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const made = try t.write(&.{"made.txt"}, "x");
    const made_json = try core.toJson(a, made);
    _ = try t.write(&.{ "p", "s.jsonl" }, try std.fmt.allocPrint(a,
        \\{{"type":"assistant","timestamp":"2025-01-01T00:00:00Z","message":{{"content":[{{"type":"tool_use","id":"r1","name":"Read","input":{{"file_path":"C:/w/a.txt"}}}},{{"type":"tool_use","id":"w1","name":"Write","input":{{"file_path":{s}}}}},{{"type":"tool_use","id":"g1","name":"Grep","input":{{"pattern":"x","path":"C:/w"}}}}]}}}}
        \\{{"type":"api-request-blob","message":{{"content":[{{"type":"tool_use","id":"zz","name":"Read","input":{{"file_path":"C:/w/blob.txt"}}}}]}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:01Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"r1","content":"..."}}]}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:02Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"w1","content":"ok"}}]}},"toolUseResult":{{"type":"create"}}}}
        \\{{"type":"assistant","timestamp":"2025-01-01T00:00:03Z","message":{{"content":[{{"type":"tool_use","id":"e1","name":"Edit","input":{{"file_path":"c:\\W\\A.txt"}}}},{{"type":"tool_use","id":"e2","name":"Edit","input":{{"file_path":"C:/w/b.txt"}}}},{{"type":"tool_use","id":"n1","name":"NotebookEdit","input":{{"notebook_path":"C:/w/n.ipynb"}}}}]}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:04Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"e1","content":"ok"}},{{"type":"tool_result","tool_use_id":"e2","is_error":true,"content":"no match"}}]}}}}
        \\{{"type":"user","timestamp":"2025-01-01T00:00:05Z","message":{{"content":[{{"type":"tool_result","tool_use_id":"n1","content":"ok"}}]}}}}
        \\
    , .{made_json}));
    const files = try sessionFiles(a, "s");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "[{{\"path\":\"C:/w/n.ipynb\",\"action\":\"edited\",\"edits\":1,\"at\":1735689605000,\"exists\":false}},{{\"path\":\"C:/w/a.txt\",\"action\":\"edited\",\"edits\":1,\"at\":1735689604000,\"exists\":false}},{{\"path\":{s},\"action\":\"created\",\"edits\":1,\"at\":1735689602000,\"exists\":true}}]", .{made_json}),
        try core.toJson(a, files),
    );
}

test "context of a session" {
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    _ = try t.write(&.{ "p", "s.jsonl" },
        \\{"type":"user","uuid":"u1","message":{"content":"0123456789012345678901234567890123456789"}}
        \\{"type":"assistant","uuid":"m1","message":{"model":"claude-x","content":[],"usage":{"input_tokens":1000,"output_tokens":0}}}
        \\
    );
    try testing.expectEqualStrings(
        "{\"used\":1000,\"model\":\"claude-x\",\"parts\":[{\"key\":\"system\",\"tokens\":990},{\"key\":\"tools\",\"tokens\":0},{\"key\":\"mcp\",\"tokens\":0},{\"key\":\"plugins\",\"tokens\":0},{\"key\":\"skills\",\"tokens\":0},{\"key\":\"agents\",\"tokens\":0},{\"key\":\"memory\",\"tokens\":0},{\"key\":\"messages\",\"tokens\":10}],\"tools\":[]}",
        try core.toJson(a, try sessionContext(a, "s")),
    );
    _ = try t.write(&.{ "p", "empty.jsonl" }, "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n");
    try testing.expectEqualStrings("null", try core.toJson(a, try sessionContext(a, "empty")));
}

test "watcher: which changes ping, and for whom" {
    var t = try TestStore.init();
    defer t.deinit();
    const root = t.root;
    const file = try t.write(&.{ "proj", "abc-1.jsonl" }, "{}\n");
    _ = try t.write(&.{ "proj", "notes.txt" }, "x");
    _ = try t.write(&.{ "proj", "abc-1", "subagents", "agent-1.jsonl" }, "{}\n");
    const proj = try t.path(&.{"proj"});

    try testing.expectEqualStrings("abc-1", changedId(root, .{ .kind = .modify, .path = file }).?);
    try testing.expectEqualStrings("abc-1", changedId(root, .{ .kind = .remove, .path = file }).?);
    try testing.expectEqualStrings("*", changedId(root, .{ .kind = .rescan, .path = root }).?);
    // project folders coming and going, not "something inside changed"
    try testing.expectEqualStrings("", changedId(root, .{ .kind = .create, .path = proj }).?);
    try testing.expectEqualStrings("", changedId(root, .{ .kind = .remove, .path = try t.path(&.{"gone"}) }).?);
    try testing.expectEqualStrings("", changedId(root, .{ .kind = .rename, .path = try t.path(&.{ "proj", "abc-1" }) }).?);
    try testing.expect(changedId(root, .{ .kind = .modify, .path = proj }) == null);
    // other files, anything deeper, anything outside
    try testing.expect(changedId(root, .{ .kind = .modify, .path = try t.path(&.{ "proj", "notes.txt" }) }) == null);
    try testing.expect(changedId(root, .{ .kind = .create, .path = try t.path(&.{ "proj", "notes.txt" }) }) == null);
    try testing.expect(changedId(root, .{ .kind = .modify, .path = try t.path(&.{ "proj", "abc-1", "subagents", "agent-1.jsonl" }) }) == null);
    try testing.expect(changedId(root, .{ .kind = .create, .path = root }) == null);
    try testing.expect(changedId(root, .{ .kind = .create, .path = try std.mem.concat(t.arena.allocator(), u8, &.{ root, "-other\\x.jsonl" }) }) == null);
}

test "watcher: one ping after the changes go quiet" {
    var t = try TestStore.init();
    defer t.deinit();
    watch_root = t.root;
    defer watch_root = "";
    const file = try t.path(&.{ "proj", "abc-1.jsonl" });
    onChanges(null, &.{ .{ .kind = .modify, .path = file }, .{ .kind = .modify, .path = file }, .{ .kind = .remove, .path = try t.path(&.{"gone"}) }, .{ .kind = .modify, .path = try t.path(&.{ "proj", "notes.txt" }) } });
    try testing.expect(ping.dirty);
    try testing.expectEqual(@as(u64, 3), ping.count);
    var started = core.monoMs();
    var ids = waitPing();
    var took = core.monoMs() - started;
    try testing.expect(took >= 550 and took < 1400);
    try testing.expectEqual(@as(u32, 1), ids.count());
    try testing.expect(ids.contains("abc-1"));
    try testing.expect(!ping.dirty and ping.ids.count() == 0);
    freeIds(&ids);

    // changes that never go quiet for 600 ms still ping every 1.5 s
    const Busy = struct {
        fn run(path: []const u8) void {
            for (0..12) |_| {
                onChanges(null, &.{.{ .kind = .modify, .path = path }});
                core.sleepMs(200);
            }
        }
    };
    const busy = try std.Thread.spawn(.{}, Busy.run, .{file});
    started = core.monoMs();
    ids = waitPing();
    took = core.monoMs() - started;
    freeIds(&ids);
    busy.join();
    try testing.expect(took >= 1300 and took < 2300);
    // what came after that ping waits for the next one
    try testing.expect(ping.dirty);
    ids = waitPing();
    try testing.expect(ids.contains("abc-1"));
    freeIds(&ids);
    ping = .{};
}

test "watcher: a transcript written under the store pings its session" {
    if (!core.is_windows) return error.SkipZigTest;
    var t = try TestStore.init();
    defer t.deinit();
    watch_root = t.root;
    defer watch_root = "";
    try core.makePath(try t.path(&.{"proj"}));
    const w = try watch.start(&.{t.root}, .{ .debounce_ms = 20 }, onChanges, null);
    core.sleepMs(150); // changes are recorded from the first read on
    _ = try t.write(&.{ "proj", "abc-2.jsonl" }, "{}\n");
    _ = try t.write(&.{ "proj", "notes.txt" }, "x");
    var ids = waitPing();
    w.stop();
    defer freeIds(&ids);
    defer ping = .{};
    try testing.expectEqual(@as(u32, 1), ids.count());
    try testing.expect(ids.contains("abc-2"));
}

test "delete a session" {
    // with the files module, deleting goes to the real Recycle Bin: not from a test
    if (@hasDecl(m.fsx, "trash")) return error.SkipZigTest;
    var t = try TestStore.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const file = try t.write(&.{ "p1", "abc-1.jsonl" }, "{}\n");
    const sub = try t.write(&.{ "p1", "abc-1", "subagents", "agent-1.jsonl" }, "{}\n");
    const copy = try t.write(&.{ "p2", "abc-1.jsonl" }, "{}\n");
    const other = try t.write(&.{ "p1", "abc-2.jsonl" }, "{}\n");
    try testing.expect(!try deleteSession(a, "missing"));
    try testing.expect(try deleteSession(a, "abc-1"));
    try testing.expect(!core.exists(file) and !core.exists(sub) and !core.exists(copy));
    try testing.expect(!core.exists(try t.path(&.{ "p1", "abc-1" })));
    try testing.expect(core.exists(other));
    try testing.expect(!try deleteSession(a, "abc-1"));
}

test "Codex's chats are listed with Claude's" {
    var store = try TestStore.init();
    defer store.deinit();
    const a = store.arena.allocator();

    try testing.expectEqual(@as(?u32, 5), stateVersion("state_5.sqlite"));
    try testing.expectEqual(@as(?u32, 12), stateVersion("state_12.sqlite"));
    for ([_][]const u8{ "state_5.sqlite-wal", "state_.sqlite", "state_x.sqlite", "logs_2.sqlite", "state_5" }) |name|
        try testing.expectEqual(@as(?u32, null), stateVersion(name));
    try testing.expectEqualStrings("E:\\repo", plainPath("\\\\?\\E:\\repo"));
    try testing.expectEqualStrings("\\\\?\\UNC\\pc\\share", plainPath("\\\\?\\UNC\\pc\\share"));
    try testing.expectEqualStrings("/home/me/repo", plainPath("/home/me/repo"));
    try testing.expectEqual(@as(i64, 1_790_741_406_000), toMs(1_790_741_406));
    try testing.expectEqual(@as(i64, 1_790_741_406_123), toMs(1_790_741_406_123));

    // no Codex here: only Claude's (none)
    try testing.expect(codexDb(a) == null);
    try testing.expectEqual(@as(usize, 0), (try listSessions(a)).len);

    const home = try codexHome(a);
    try core.makePath(home);
    const repo = try std.fs.path.join(a, &.{ std.fs.path.dirname(home).?, "repo" });
    try core.makePath(repo);
    // an older schema's file is left alone once a newer one is there
    try core.writeFile(try std.fs.path.join(a, &.{ home, "state_4.sqlite" }), "");
    const file = try std.fs.path.join(a, &.{ home, "state_5.sqlite" });
    {
        var db: ?*sq.sqlite3 = null;
        defer _ = sq.sqlite3_close(db);
        try testing.expectEqual(sq.SQLITE_OK, sq.sqlite3_open_v2((try a.dupeSentinel(u8, file, 0)).ptr, &db, sq.SQLITE_OPEN_READWRITE | sq.SQLITE_OPEN_CREATE, null));
        const sql = try std.fmt.allocPrintSentinel(a,
            \\CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, title TEXT, name TEXT, created_at INTEGER, updated_at INTEGER, archived INTEGER);
            \\INSERT INTO threads VALUES ('t-new', '{s}', 'sửa lỗi phân trang' || char(10) || 'dòng hai', 'Fix paging', 1790741406, 1790743003, 0);
            \\INSERT INTO threads VALUES ('t-old', '{s}', '  first words  ', NULL, 1776832286, 1776832300, 0);
            \\INSERT INTO threads VALUES ('t-gone', 'Q:\\no\\such\\folder', '', '', 1776832286, 1776832290, 0);
            \\INSERT INTO threads VALUES ('t-archived', '{s}', 'archived', NULL, 1, 2, 1);
        , .{ repo, repo, repo }, 0);
        try testing.expectEqual(sq.SQLITE_OK, sq.sqlite3_exec(db, sql.ptr, null, null, null));
    }
    try testing.expectEqualStrings(file, codexDb(a).?);

    const list = try listSessions(a);
    try testing.expectEqual(@as(usize, 2), list.len);
    const g = for (list) |x| {
        if (std.mem.eql(u8, x.cwd, repo)) break x;
    } else return error.NoRepoGroup;
    try testing.expectEqualStrings("repo", g.name);
    try testing.expectEqual(@as(usize, 2), g.sessions.len);
    try testing.expectEqualStrings("t-new", g.sessions[0].id);
    try testing.expectEqualStrings("Fix paging", g.sessions[0].title);
    try testing.expectEqualStrings("codex", g.sessions[0].agent.?);
    try testing.expectEqual(@as(i64, 1_790_743_003_000), g.sessions[0].updated);
    try testing.expect(g.sessions[0].cwdExists);
    try testing.expectEqualStrings("first words", g.sessions[1].title);
    const gone = for (list) |x| {
        if (!std.mem.eql(u8, x.cwd, repo)) break x;
    } else return error.NoOtherGroup;
    try testing.expectEqualStrings("Codex chat", gone.sessions[0].title);
    try testing.expect(!gone.sessions[0].cwdExists);
    try testing.expect(std.mem.find(u8, try core.toJson(a, g.sessions[0]), "\"agent\":\"codex\"") != null);

    // a database of another shape is skipped, not an error
    try core.writeFile(try std.fs.path.join(a, &.{ home, "state_6.sqlite" }), "not a database");
    try testing.expectEqual(@as(usize, 0), (try listSessions(a)).len);
}

test "Codex's chats from before it kept a database" {
    var store = try TestStore.init();
    defer store.deinit();
    const a = store.arena.allocator();

    try testing.expectEqualStrings("0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", rolloutId("C:\\x\\rollout-2025-08-01T10-00-00-0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl").?);
    try testing.expect(rolloutId("rollout-2025-08-01T10-00-00.jsonl") == null);
    try testing.expect(rolloutId("rollout-2025-08-01T10-00-00-0198a1b2+c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl") == null);
    try testing.expectEqualStrings("/home/me/app", contextCwd("<environment_context>\n  <cwd> /home/me/app </cwd>\n  <shell>bash</shell>\n</environment_context>").?);
    try testing.expectEqualStrings("E:\\repo", contextCwd("<environment_context>\nCurrent working directory: E:\\repo\nApproval policy: never\n</environment_context>").?);
    try testing.expect(contextCwd("<environment_context></environment_context>") == null);
    try testing.expect(pathLike(if (core.is_windows) "E:\\softek\\TMS" else "/home/me/app"));
    try testing.expect(!pathLike("repo") and !pathLike("") and !pathLike(if (core.is_windows) "E:\\a\nApproval policy: <never>" else "/a\nb"));
    try testing.expectEqualStrings("fix it", codexPrompt("# Context from my IDE setup:\n\n## Open tabs:\n- a.cs\n\n## My request for Codex:\nfix it\n").?);
    try testing.expectEqualStrings("fix it", codexPrompt("fix it").?);
    try testing.expect(codexPrompt("<user_instructions>be brief</user_instructions>") == null);

    const home = try codexHome(a);
    const repo = try std.fs.path.join(a, &.{ std.fs.path.dirname(home).?, "repo" });
    try core.makePath(repo);
    const repo_json = try core.toJson(a, repo);
    const day = try std.fs.path.join(a, &.{ home, "sessions", "2025", "08", "01" });
    try core.makePath(day);
    const put = struct {
        fn put(arena: Allocator, dir: []const u8, id: []const u8, text: []const u8) !void {
            const name = try std.fmt.allocPrint(arena, "rollout-2025-08-01T10-00-00-{s}.jsonl", .{id});
            try core.writeFile(try std.fs.path.join(arena, &.{ dir, name }), text);
        }
    }.put;
    // as it is written now: every record wrapped, the folder in the first one
    try put(a, day, "00000000-0000-7000-8000-000000000001", try std.fmt.allocPrint(a,
        \\{{"timestamp":"2025-10-02T03:04:05.000Z","type":"session_meta","payload":{{"id":"00000000-0000-7000-8000-000000000001","timestamp":"2025-10-02T03:04:05.000Z","cwd":{s},"originator":"codex_cli_rs","source":"cli"}}}}
        \\{{"timestamp":"2025-10-02T03:04:06.000Z","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"<environment_context>\n  <cwd>/elsewhere</cwd>\n</environment_context>"}}]}}}}
        \\{{"timestamp":"2025-10-02T03:04:07.000Z","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"# Context from my IDE setup:\n\n## My request for Codex:\nsửa   lỗi\nphân trang"}}]}}}}
        \\{{"timestamp":"2025-10-02T03:04:07.000Z","type":"event_msg","payload":{{"type":"user_message","message":"second question"}}}}
        \\
    , .{repo_json}));
    // as it was at first: bare items, the folder only told to the model
    try put(a, day, "00000000-0000-7000-8000-000000000002", try std.fmt.allocPrint(a,
        \\{{"id":"00000000-0000-7000-8000-000000000002","timestamp":"2025-08-01T10:00:00.000Z","instructions":null}}
        \\{{"record_type":"state"}}
        \\{{"type":"message","role":"user","content":[{{"type":"input_text","text":"<environment_context>\nCurrent working directory: {s}\nApproval policy: on-request\n</environment_context>"}}]}}
        \\{{"type":"message","role":"user","content":[{{"type":"input_text","text":"add a test"}}]}}
        \\{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"done"}}]}}
        \\
    , .{repo_json[1 .. repo_json.len - 1]}));
    // nothing asked, a sub-agent's, no folder: not chats to go back to
    try put(a, day, "00000000-0000-7000-8000-000000000003", try std.fmt.allocPrint(a,
        \\{{"timestamp":"2025-10-02T03:04:05.000Z","type":"session_meta","payload":{{"id":"00000000-0000-7000-8000-000000000003","cwd":{s},"source":"cli"}}}}
        \\
    , .{repo_json}));
    try put(a, day, "00000000-0000-7000-8000-000000000004", try std.fmt.allocPrint(a,
        \\{{"timestamp":"2025-10-02T03:04:05.000Z","type":"session_meta","payload":{{"id":"00000000-0000-7000-8000-000000000004","cwd":{s},"source":{{"subagent":"review"}}}}}}
        \\{{"timestamp":"2025-10-02T03:04:07.000Z","type":"event_msg","payload":{{"type":"user_message","message":"review this"}}}}
        \\
    , .{repo_json}));
    try put(a, day, "00000000-0000-7000-8000-000000000005",
        \\{"id":"00000000-0000-7000-8000-000000000005","timestamp":"2025-08-01T10:00:00.000Z"}
        \\{"type":"message","role":"user","content":[{"type":"input_text","text":"where am I"}]}
        \\
    );
    // other files there are not rollouts
    try core.writeFile(try std.fs.path.join(a, &.{ day, "rollout-2025-08-01T10-00-00-00000000-0000-7000-8000-000000000006.jsonl.zst" }), "x");
    try core.writeFile(try std.fs.path.join(a, &.{ day, "notes.jsonl" }), "{}");

    var list = try listSessions(a);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings(repo, list[0].cwd);
    try testing.expectEqual(@as(usize, 2), list[0].sessions.len);
    const by_id = struct {
        fn find(sessions: []const SessionInfo, id: []const u8) ?SessionInfo {
            for (sessions) |x| if (std.mem.eql(u8, x.id, id)) return x;
            return null;
        }
    }.find;
    const new = by_id(list[0].sessions, "00000000-0000-7000-8000-000000000001").?;
    try testing.expectEqualStrings("sửa lỗi phân trang", new.title);
    try testing.expectEqualStrings("codex", new.agent.?);
    try testing.expectEqual(@as(i64, 1_759_374_245_000), new.created);
    try testing.expect(new.cwdExists);
    const old = by_id(list[0].sessions, "00000000-0000-7000-8000-000000000002").?;
    try testing.expectEqualStrings("add a test", old.title);
    try testing.expectEqualStrings(repo, old.cwd);
    try testing.expectEqual(@as(i64, 1_754_042_400_000), old.created);
    // read once: the second listing comes from the cache
    try testing.expectEqual(@as(usize, 2), (try listSessions(a))[0].sessions.len);

    // once Codex keeps a database, it speaks for the chats it has: its name for one, another archived
    const file = try std.fs.path.join(a, &.{ home, "state_5.sqlite" });
    {
        var db: ?*sq.sqlite3 = null;
        defer _ = sq.sqlite3_close(db);
        try testing.expectEqual(sq.SQLITE_OK, sq.sqlite3_open_v2((try a.dupeSentinel(u8, file, 0)).ptr, &db, sq.SQLITE_OPEN_READWRITE | sq.SQLITE_OPEN_CREATE, null));
        const sql = try std.fmt.allocPrintSentinel(a,
            \\CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, title TEXT, name TEXT, created_at INTEGER, updated_at INTEGER, archived INTEGER);
            \\INSERT INTO threads VALUES ('00000000-0000-7000-8000-000000000001', '{s}', 't', 'Fix paging', 1790741406, 1790743003, 0);
            \\INSERT INTO threads VALUES ('00000000-0000-7000-8000-000000000002', '{s}', 'archived', NULL, 1, 2, 1);
        , .{ repo, repo }, 0);
        try testing.expectEqual(sq.SQLITE_OK, sq.sqlite3_exec(db, sql.ptr, null, null, null));
    }
    list = try listSessions(a);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqual(@as(usize, 1), list[0].sessions.len);
    try testing.expectEqualStrings("Fix paging", list[0].sessions[0].title);
}
