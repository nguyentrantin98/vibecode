//! What every module shares: the allocator and Io, events to the window, the data folder, a
//! worker pool for commands and background jobs, and child processes that never flash a console.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const is_windows = builtin.os.tag == .windows;
pub const is_mac = builtin.os.tag == .macos;
/// a dev build (`zig build`), not the installed app (`zig build -Doptimize=ReleaseFast`)
pub const debug = builtin.mode == .debug;

/// Thread-safe general purpose allocator for everything that outlives one command.
pub var gpa: Allocator = undefined;
pub var io: Io = undefined;
/// Process environment at start-up (owned by `gpa`). Read-only after `init`, except `fix_mac_path`.
pub var env: *std.process.Environ.Map = undefined;
/// Command line, without argv[0].
pub var args: []const []const u8 = &.{};

pub fn init(i: std.process.Init) !void {
    gpa = if (debug) i.gpa else std.heap.smp_allocator;
    io = i.io;
    env = i.environ_map;
    const all = try i.minimal.args.toSlice(i.arena.allocator());
    args = if (all.len > 0) all[1..] else all;
    if (is_mac) fixMacPath();
}

pub fn getenv(name: []const u8) ?[]const u8 {
    return env.get(name);
}

pub fn hasArg(a: []const u8) bool {
    for (args) |x| if (std.mem.eql(u8, x, a)) return true;
    return false;
}

// ---------------- locks ----------------

/// `Io.Mutex` without the `io` argument (every lock in the app is taken uncancelably).
pub const Mutex = struct {
    m: Io.Mutex = .init,
    pub fn lock(self: *Mutex) void {
        self.m.lockUncancelable(io);
    }
    pub fn unlock(self: *Mutex) void {
        self.m.unlock(io);
    }
};

// ---------------- worker pool ----------------

/// Runs `func(args...)` on a pooled worker thread and returns at once. Commands and every
/// background job go through here: the pool grows while every worker is busy (jobs may block on
/// the network or a child process for minutes) and idle workers retire after a while.
pub fn spawn(comptime func: anytype, fargs: std.meta.ArgsTuple(@TypeOf(func))) void {
    const Args = @TypeOf(fargs);
    const Closure = struct {
        job: Job,
        a: Args,
        fn run(job: *Job) void {
            const self: *@This() = @fieldParentPtr("job", job);
            const a = self.a;
            gpa.destroy(self);
            const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
            if (@typeInfo(R) == .error_union) {
                _ = @call(.auto, func, a) catch |e| {
                    std.log.warn("background job failed: {s}", .{@errorName(e)});
                };
            } else {
                _ = @call(.auto, func, a);
            }
        }
    };
    const c = gpa.create(Closure) catch {
        // out of memory: run inline rather than drop the job
        const r = @call(.auto, func, fargs);
        if (@typeInfo(@TypeOf(r)) == .error_union) _ = r catch {};
        return;
    };
    c.* = .{ .job = .{ .run = Closure.run }, .a = fargs };
    pool.push(&c.job);
}

const Job = struct {
    run: *const fn (*Job) void,
    next: ?*Job = null,
};

const Pool = struct {
    mutex: Mutex = .{},
    cond: Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    idle: u32 = 0,
    /// signals sent to idle workers that have not woken yet
    wakes: u32 = 0,
    threads: u32 = 0,
    const max_threads = 256;

    fn push(p: *Pool, job: *Job) void {
        p.mutex.lock();
        if (p.tail) |t| t.next = job else p.head = job;
        p.tail = job;
        // every job gets a worker of its own: wake an idle one, else start one
        var grow = false;
        if (p.idle > p.wakes) {
            p.wakes += 1;
            p.cond.signal(io);
        } else if (p.threads < max_threads) {
            grow = true;
            p.threads += 1;
        }
        p.mutex.unlock();
        if (grow) {
            if (std.Thread.spawn(.{ .stack_size = 8 << 20 }, worker, .{p})) |t| t.detach() else |_| {
                p.mutex.lock();
                p.threads -= 1;
                p.mutex.unlock();
            }
        }
    }

    fn worker(p: *Pool) void {
        p.mutex.lock();
        while (true) {
            if (p.head) |job| {
                p.head = job.next;
                if (p.head == null) p.tail = null;
                p.mutex.unlock();
                job.run(job);
                p.mutex.lock();
                continue;
            }
            p.idle += 1;
            // a few workers stay warm; the rest leave after 30 s without work
            const r = p.cond.waitTimeout(io, &p.mutex.m, .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } });
            p.idle -= 1;
            if (p.wakes > 0) p.wakes -= 1;
            if (r) |_| {} else |_| if (p.head == null and p.threads > 4) {
                p.threads -= 1;
                p.mutex.unlock();
                return;
            }
        }
    }
};
var pool: Pool = .{};

/// Sleep on the current thread.
pub fn sleepMs(ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Milliseconds since the Unix epoch.
pub fn nowMs() u64 {
    const t = Io.Clock.real.now(io);
    return @intCast(@max(0, t.toMilliseconds()));
}

/// Monotonic milliseconds (for timeouts and debouncing).
pub fn monoMs() u64 {
    const t = Io.Clock.awake.now(io);
    return @intCast(@max(0, t.toMilliseconds()));
}

// ---------------- events to the window ----------------

/// Event to the main window. `payload` is the listener's argument list: pass a tuple, e.g.
/// `emit("fs:changed", .{paths})` — tuples are written as JSON arrays.
pub fn emit(event: []const u8, payload: anytype) void {
    emitTo(host.main_label, event, payload);
}

/// Same, to one webview (by label).
pub fn emitTo(label: []const u8, event: []const u8, payload: anytype) void {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"e\":") catch return;
    std.json.Stringify.encodeJsonString(event, .{}, w) catch return;
    w.writeAll(",\"p\":") catch return;
    std.json.Stringify.value(payload, .{}, w) catch return;
    w.writeByte('}') catch return;
    host.post(label, aw.written());
}

// ---------------- errors with a message ----------------

/// Where a function that is not a command leaves the text of its error (Claude's tools, helpers
/// shared between modules): it returns `fail.set(a, "…{s}", .{x})`, the caller shows `fail.msg`
/// when the error is `error.Failed` and the error's name otherwise (see `text`).
pub const Fail = struct {
    msg: []const u8 = "",

    pub fn set(f: *Fail, a: Allocator, comptime fmt: []const u8, fargs: anytype) error{Failed} {
        f.msg = std.fmt.allocPrint(a, fmt, fargs) catch "out of memory";
        return error.Failed;
    }

    /// What to show for `e`.
    pub fn text(f: *const Fail, e: anyerror) []const u8 {
        return if (e == error.Failed and f.msg.len > 0) f.msg else @errorName(e);
    }
};

// ---------------- JSON ----------------

pub fn toJson(a: Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

/// Parses into `T`, ignoring unknown keys, every slice allocated in `a` (use an arena).
pub fn fromJson(comptime T: type, a: Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

// ---------------- folders ----------------

var user_data_buf: ?[]const u8 = null;
var home_buf: ?[]const u8 = null;
var once_mutex: Mutex = .{};

/// The app's data folder. Kept at "%APPDATA%/TINJS Studio" (the Electron build's folder) so
/// settings, recent folders, saved connections and the Zalo session carry over.
/// `STUDIO_USER_DATA` gives a dev copy its own profile.
pub fn userData() []const u8 {
    once_mutex.lock();
    defer once_mutex.unlock();
    if (user_data_buf) |d| return d;
    const dir = if (getenv("STUDIO_USER_DATA")) |d|
        gpa.dupe(u8, d) catch @panic("oom")
    else
        std.fs.path.join(gpa, &.{ configDir(), "TINJS Studio" }) catch @panic("oom");
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    user_data_buf = dir;
    return dir;
}

/// `%APPDATA%` (Roaming) on Windows, `~/Library/Application Support` on macOS.
pub fn configDir() []const u8 {
    if (is_windows) return getenv("APPDATA") orelse home();
    if (is_mac) return std.fs.path.join(gpa, &.{ home(), "Library", "Application Support" }) catch @panic("oom");
    return getenv("XDG_CONFIG_HOME") orelse std.fs.path.join(gpa, &.{ home(), ".config" }) catch @panic("oom");
}

/// `%LOCALAPPDATA%` on Windows, `~/Library/Caches` on macOS.
pub fn localDataDir() []const u8 {
    if (is_windows) return getenv("LOCALAPPDATA") orelse configDir();
    if (is_mac) return std.fs.path.join(gpa, &.{ home(), "Library", "Caches" }) catch @panic("oom");
    return getenv("XDG_DATA_HOME") orelse std.fs.path.join(gpa, &.{ home(), ".local", "share" }) catch @panic("oom");
}

pub fn home() []const u8 {
    if (home_buf) |h| return h;
    const h = (if (is_windows) getenv("USERPROFILE") else getenv("HOME")) orelse "";
    home_buf = h;
    return h;
}

/// The user's temp folder.
pub fn tempDir() []const u8 {
    return getenv("TEMP") orelse getenv("TMP") orelse getenv("TMPDIR") orelse if (is_windows) "C:\\Windows\\Temp" else "/tmp";
}

/// `<userData>/<parts…>` allocated in `a`.
pub fn dataPath(a: Allocator, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(a);
    try all.append(a, userData());
    try all.appendSlice(a, parts);
    return std.fs.path.join(a, all.items);
}

/// The folder the executable is in.
pub fn exeDir(a: Allocator) ![]u8 {
    const exe = try std.process.executablePathAlloc(io, a);
    return a.dupe(u8, std.fs.path.dirname(exe) orelse ".");
}

/// A bundled file the app ships inside its executable (icons, the PowerShell bridge…), written
/// once to `<userData>/res/<name>` so other programs can open it by path. Returns the path.
pub fn resourceFile(a: Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    const path = try dataPath(a, &.{ "res", name });
    const same = blk: {
        const cur = readFileAlloc(a, path, bytes.len + 1) catch break :blk false;
        defer a.free(cur);
        break :blk std.mem.eql(u8, cur, bytes);
    };
    if (!same) try writeAtomic(path, bytes);
    return path;
}

// ---------------- files ----------------

pub fn readFileAlloc(a: Allocator, path: []const u8, max: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max));
}

pub fn exists(path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn isFile(path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind != .directory;
}

pub fn isDir(path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn makePath(path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Writes through a temp file + rename, so a crash never leaves half a JSON file behind.
pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| Io.Dir.cwd().createDirPath(io, d) catch {};
    var buf: [64]u8 = undefined;
    const pid: u64 = if (is_windows) std.os.windows.GetCurrentProcessId() else @intCast(std.c.getpid());
    const suffix = std.fmt.bufPrint(&buf, ".tmp{d}-{d}", .{ pid, tmp_counter.fetchAdd(1, .monotonic) }) catch unreachable;
    const tmp = try std.mem.concat(gpa, u8, &.{ path, suffix });
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), path, io) catch |e| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return e;
    };
}
var tmp_counter: std.atomic.Value(u64) = .init(0);

// ---------------- child processes ----------------

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    /// exit code; null when killed by a signal
    code: ?u32,
    pub fn ok(r: RunResult) bool {
        return r.code != null and r.code.? == 0;
    }
};

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    /// null: the app's own environment (see `cleanEnv`)
    env_map: ?*const std.process.Environ.Map = null,
    stdin: ?[]const u8 = null,
    max_output: usize = 64 << 20,
};

/// Runs a program to completion (no console window on Windows) and collects its output.
pub fn run(a: Allocator, argv: []const []const u8, o: RunOptions) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (o.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = o.env_map orelse cleanEnvShared(),
        .stdin = if (o.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);
    if (o.stdin) |data| {
        if (child.stdin) |f| {
            var wbuf: [4096]u8 = undefined;
            var fw = f.writer(io, &wbuf);
            fw.interface.writeAll(data) catch {};
            fw.interface.flush() catch {};
            f.close(io);
            child.stdin = null;
        }
    }
    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, .none)) |_| {
        if (mr.reader(0).buffered().len > o.max_output or mr.reader(1).buffered().len > o.max_output)
            return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    const stdout = try mr.toOwnedSlice(0);
    const stderr = try mr.toOwnedSlice(1);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .code = switch (term) {
            .exited => |c| c,
            else => null,
        },
    };
}

var clean_env_map: ?std.process.Environ.Map = null;

/// The environment chats start with. When the app itself was launched from inside a Claude Code
/// session, that session's variables (CLAUDECODE, CLAUDE_CODE_*, MCP_*, the host's API URL) would
/// make every chat a child session that stops saving transcripts, so they are dropped.
pub fn cleanEnv(a: Allocator) !std.process.Environ.Map {
    var m = try env.clone(a);
    if (m.get("CLAUDECODE") != null or m.get("CLAUDE_CODE_SESSION_ID") != null) {
        var drop: std.ArrayList([]const u8) = .empty;
        defer drop.deinit(a);
        var it = m.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, "CLAUDECODE") or std.mem.startsWith(u8, k, "CLAUDE_") or
                std.mem.startsWith(u8, k, "MCP_") or std.mem.eql(u8, k, "ANTHROPIC_BASE_URL"))
                try drop.append(a, k);
        }
        for (drop.items) |k| _ = m.swapRemove(k);
    }
    return m;
}

/// `cleanEnv`, built once and shared (read-only).
pub fn cleanEnvShared() *const std.process.Environ.Map {
    once_mutex.lock();
    defer once_mutex.unlock();
    if (clean_env_map == null) clean_env_map = cleanEnv(gpa) catch @panic("oom");
    return &clean_env_map.?;
}

/// First match of `cmd` on PATH (PATHEXT aware on Windows), allocated in `a`.
pub fn which(a: Allocator, cmd: []const u8) ?[]u8 {
    if (std.fs.path.isAbsolute(cmd)) return if (isFile(cmd)) a.dupe(u8, cmd) catch null else null;
    const path = getenv(if (is_windows) "Path" else "PATH") orelse getenv("PATH") orelse return null;
    const sep: u8 = if (is_windows) ';' else ':';
    const has_ext = std.fs.path.extension(cmd).len > 0;
    const exts_env = if (is_windows) (getenv("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD") else "";
    var it = std.mem.tokenizeScalar(u8, path, sep);
    while (it.next()) |dir| {
        if (is_windows) {
            if (has_ext) {
                const p = std.fs.path.join(a, &.{ dir, cmd }) catch return null;
                if (isFile(p)) return p;
                a.free(p);
            }
            var ei = std.mem.tokenizeScalar(u8, exts_env, ';');
            while (ei.next()) |ext| {
                const p = std.mem.concat(a, u8, &.{ dir, "\\", cmd, ext }) catch return null;
                if (isFile(p)) return p;
                a.free(p);
            }
        } else {
            const p = std.fs.path.join(a, &.{ dir, cmd }) catch return null;
            if (isFile(p)) return p;
            a.free(p);
        }
    }
    return null;
}

/// macOS apps opened from Finder get launchd's bare PATH: take the login shell's PATH, plus the
/// usual install folders, so `claude`, `git`, `node`… are found.
fn fixMacPath() void {
    const a = gpa;
    var parts: std.ArrayList([]const u8) = .empty;
    const shell = getenv("SHELL") orelse "/bin/zsh";
    if (run(a, &.{ shell, "-ilc", "printf \"__PATH__%s__PATH__\" \"$PATH\"" }, .{ .env_map = env })) |r| {
        var sp = std.mem.splitSequence(u8, r.stdout, "__PATH__");
        _ = sp.next();
        if (sp.next()) |m| {
            var pi = std.mem.splitScalar(u8, m, ':');
            while (pi.next()) |p| parts.append(a, p) catch {};
        }
    } else |_| {}
    var pi = std.mem.splitScalar(u8, getenv("PATH") orelse "", ':');
    while (pi.next()) |p| parts.append(a, p) catch {};
    parts.append(a, "/opt/homebrew/bin") catch {};
    parts.append(a, "/usr/local/bin") catch {};
    for ([_][]const u8{ ".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin" }) |p|
        parts.append(a, std.fs.path.join(a, &.{ home(), p }) catch continue) catch {};
    var out: std.ArrayList(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (parts.items) |p| {
        if (p.len == 0) continue;
        const g = seen.getOrPut(a, p) catch continue;
        if (g.found_existing) continue;
        if (out.items.len > 0) out.append(a, ':') catch {};
        out.appendSlice(a, p) catch {};
    }
    env.put("PATH", out.items) catch {};
}

// ---------------- strings ----------------

/// ASCII lower-case copy.
pub fn lower(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    return std.ascii.lowerString(out, s);
}

/// Windows wide string (UTF-16, NUL-terminated) from UTF-8/WTF-8.
pub fn wide(a: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s);
}

/// UTF-8 from a NUL-terminated Windows wide string.
pub fn fromWide(a: Allocator, s: [*:0]const u16) ![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(s));
}

pub const host = @import("host.zig");
