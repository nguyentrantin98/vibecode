//! Terminals: one pseudo-console per chat / shell, streamed to the page through its own Channel.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const c = if (core.is_windows) core.host.win.c else struct {};

pub const commands = .{
    .{ "pty_spawn", pty_spawn },
    .{ "pty_write", pty_write },
    .{ "pty_resize", pty_resize },
    .{ "pty_kill", pty_kill },
    .{ "pty_visible", pty_visible },
    .{ "claude_detect", claude_detect },
    .{ "agents_detect", agents_detect },
};

/// The app is quitting.
pub fn deinit() void {
    killAll();
}

// ---------------- coding agents ----------------

/// (id, command on PATH) — src/shared/agents.ts
const agents = [_][2][]const u8{
    .{ "claude", "claude" },
    .{ "codex", "codex" },
    .{ "grok", "grok" },
    .{ "gemini", "gemini" },
    .{ "qwen", "qwen" },
    .{ "copilot", "copilot" },
    .{ "opencode", "opencode" },
};

fn agentCmd(id: ?[]const u8) []const u8 {
    const want = id orelse "claude";
    for (agents) |ag| if (std.mem.eql(u8, ag[0], want)) return ag[1];
    return "claude";
}

var shell_mutex: core.Mutex = .{};
var shell_cache: ?[]const u8 = null;

/// Found once, kept for the life of the app.
fn defaultShell() []const u8 {
    shell_mutex.lock();
    defer shell_mutex.unlock();
    if (shell_cache) |s| return s;
    const found: ?[]const u8 = if (core.is_windows) core.which(core.gpa, "pwsh.exe") else core.getenv("SHELL");
    shell_cache = found orelse if (core.is_windows) "powershell.exe" else "/bin/bash";
    return shell_cache.?;
}

/// The `claude` executable, also where npm / the native installer put it when PATH misses it.
pub fn claudePath(a: Allocator) ?[]u8 {
    if (core.which(a, "claude")) |p| return p;
    if (!core.is_windows) return null;
    const candidates = [_][]const []const u8{
        &.{ core.home(), ".local", "bin", "claude.exe" },
        &.{ core.getenv("APPDATA") orelse "", "npm", "claude.cmd" },
    };
    for (candidates) |parts| {
        const p = std.fs.path.join(a, parts) catch return null;
        if (core.exists(p)) return p;
        a.free(p);
    }
    return null;
}

const ClaudeInfo = struct {
    found: bool,
    path: ?[]const u8,
    shell: []const u8,
};

fn claude_detect(call: *ipc.Call) !ClaudeInfo {
    const path = claudePath(call.arena);
    return .{ .found = path != null, .path = path, .shell = defaultShell() };
}

const AgentInfo = struct {
    id: []const u8,
    found: bool,
};

fn agents_detect(call: *ipc.Call) ![agents.len]AgentInfo {
    var out: [agents.len]AgentInfo = undefined;
    for (&out, agents) |*o, ag| o.* = .{ .id = ag[0], .found = core.which(call.arena, ag[1]) != null };
    return out;
}

// ---------------- processes ----------------

const SpawnOptions = struct {
    id: []const u8,
    cwd: []const u8,
    /// "claude" | "shell"
    kind: []const u8,
    agent: ?[]const u8 = null,
    claudeArgs: ?[]const []const u8 = null,
    cols: u16,
    rows: u16,
};

/// What the page's channel receives: `{kind:"data",data}` / `{kind:"exit",code}`.
const PtyMsg = union(enum) {
    data: []const u8,
    exit: i32,

    pub fn jsonStringify(msg: PtyMsg, w: anytype) !void {
        switch (msg) {
            .data => |data| try w.write(.{ .kind = "data", .data = data }),
            .exit => |code| try w.write(.{ .kind = "exit", .code = code }),
        }
    }
};

fn deliver(out: ipc.Channel, msg: PtyMsg) void {
    // tests have no page: what it would have received is kept instead
    if (builtin.is_test) return Page.receive(out.id, msg);
    out.send(msg);
}

const Session = struct {
    id: []u8,
    out: ipc.Channel,
    pty: Pty,
    mutex: core.Mutex = .{},
    /// output and the exit code, on their way from the reader and wait threads to the forwarder
    pending: std.ArrayList(u8) = .empty,
    exit: ?i32 = null,
    cond: std.Io.Condition = .init,
    /// keystrokes go to a writer thread: a ConPTY input pipe whose process isn't reading blocks,
    /// and that must never stall the command
    keys: std.ArrayList(u8) = .empty,
    keys_cond: std.Io.Condition = .init,
    closing: bool = false,
    /// the writer thread ended on a failed write: the process is gone
    writer_dead: bool = false,
    threads: [loops.len]?std.Thread = @splat(null),

    const loops = .{ writeLoop, readLoop, waitLoop, forwardLoop };
    const forwarder = loops.len - 1;

    /// In order, off the caller's thread; ends when the session is closing or a write fails.
    fn writeLoop(s: *Session) void {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(core.gpa);
        while (true) {
            s.mutex.lock();
            while (s.keys.items.len == 0 and !s.closing) s.keys_cond.waitUncancelable(core.io, &s.mutex.m);
            if (s.closing) return s.mutex.unlock();
            // a paste arrives as many pieces: write what has queued up in one go
            std.mem.swap(std.ArrayList(u8), &data, &s.keys);
            s.mutex.unlock();
            const ok = s.pty.write(data.items);
            data.clearRetainingCapacity();
            if (!ok) {
                s.mutex.lock();
                s.writer_dead = true;
                s.mutex.unlock();
                return;
            }
        }
    }

    /// Blocking reads on their own thread, until the console is closed.
    fn readLoop(s: *Session) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = s.pty.read(&buf);
            if (n == 0) return;
            s.mutex.lock();
            s.pending.appendSlice(core.gpa, buf[0..n]) catch {};
            s.cond.signal(core.io);
            s.mutex.unlock();
        }
    }

    /// Exit: give the last output a moment to arrive (ConPTY keeps the pipe open until closed).
    fn waitLoop(s: *Session) void {
        const code = s.pty.wait();
        core.sleepMs(40);
        s.mutex.lock();
        s.exit = code;
        s.cond.signal(core.io);
        s.mutex.unlock();
    }

    /// Moves what has arrived into `carry`; the exit code when the process has ended. Holding `mutex`.
    fn drain(s: *Session, carry: *std.ArrayList(u8)) ?i32 {
        carry.appendSlice(core.gpa, s.pending.items) catch {};
        s.pending.clearRetainingCapacity();
        return s.exit;
    }

    /// Claude Code redraws in many tiny chunks; one message per chunk floods the page and makes the
    /// chat stutter. But a fixed gathering delay lands on every keystroke's echo (and a 5 ms sleep is
    /// really ~16 ms on Windows' default timer), which made typing lag. So: output after a quiet
    /// moment goes out at once; a running stream is sent at most once a frame (hidden: every 50 ms).
    fn forwardLoop(s: *Session) void {
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(core.gpa);
        var last_send: u64 = 0;
        while (true) {
            s.mutex.lock();
            while (s.pending.items.len == 0 and s.exit == null) s.cond.waitUncancelable(core.io, &s.mutex.m);
            // whatever is already queued goes in the same piece
            var exit = s.drain(&carry);
            s.mutex.unlock();
            if (exit == null) {
                const deadline = last_send + @as(u64, if (isVisible(s.id)) 16 else 50);
                s.mutex.lock();
                while (carry.items.len < 256 * 1024) {
                    const now = core.monoMs();
                    if (now >= deadline) break;
                    if (s.pending.items.len == 0 and s.exit == null)
                        s.cond.waitTimeout(core.io, &s.mutex.m, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(deadline - now)), .clock = .awake } }) catch {};
                    exit = s.drain(&carry);
                    if (exit != null) break;
                }
                s.mutex.unlock();
            }
            send(s.out, &carry);
            last_send = core.monoMs();
            if (exit) |code| {
                // a process we killed or replaced (restart) must not report "exited": the id
                // already belongs to a new, live process
                if (take(s.id, s) != null) {
                    deliver(s.out, .{ .exit = code });
                    // closing a ConPTY can stall, but this thread is the session's own
                    dispose(s, .exited);
                }
                return;
            }
        }
    }

    /// Sends what has gathered, except a UTF-8 sequence that was cut in half: kept for the next round.
    fn send(out: ipc.Channel, carry: *std.ArrayList(u8)) void {
        const cut = utf8Cut(carry.items);
        if (cut == 0) return;
        const piece = carry.items[0..cut];
        if (std.unicode.utf8ValidateSlice(piece)) {
            deliver(out, .{ .data = piece });
        } else if (std.fmt.allocPrint(core.gpa, "{f}", .{std.unicode.fmtUtf8(piece)})) |text| {
            defer core.gpa.free(text);
            deliver(out, .{ .data = text });
        } else |_| {}
        const rest = carry.items.len - cut;
        std.mem.copyForwards(u8, carry.items[0..rest], carry.items[cut..]);
        carry.shrinkRetainingCapacity(rest);
    }
};

/// How much of `s` can go out now: all of it, less a UTF-8 sequence still missing its last bytes.
fn utf8Cut(s: []const u8) usize {
    var i = s.len;
    // at most 3 bytes of a 4-byte sequence can be waiting
    while (i > 0 and s.len - i < 3) {
        i -= 1;
        if (s[i] < 0x80) break;
        if (s[i] >= 0xC0) {
            // a lead byte: does what it starts end inside `s`?
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
            return if (len > s.len - i) i else s.len;
        }
    }
    return s.len;
}

var mutex: core.Mutex = .{};
/// by id; a session in here is alive (its console is open). Under `mutex`.
var sessions: std.StringHashMapUnmanaged(*Session) = .empty;
/// Terminals on screen right now. Their output goes out every frame; the others' is gathered for
/// 50 ms — ten busy chats in the background then wake the page ~200×/s instead of ~2000×/s.
/// Under its own lock: a resize that holds `mutex` must not hold up every terminal's output.
var visible: std.StringHashMapUnmanaged(void) = .empty;
var visible_mutex: core.Mutex = .{};
/// sessions not freed yet (the ones in `sessions` and the ones being closed)
var live: std.atomic.Value(u32) = .init(0);

fn isVisible(id: []const u8) bool {
    visible_mutex.lock();
    defer visible_mutex.unlock();
    return visible.contains(id);
}

fn hide(id: []const u8) void {
    visible_mutex.lock();
    defer visible_mutex.unlock();
    if (visible.fetchRemove(id)) |kv| core.gpa.free(kv.key);
}

/// Takes the session out of the table: from then on it is the caller's to `dispose`. With `only`,
/// just when the id still belongs to that session.
fn take(id: []const u8, only: ?*Session) ?*Session {
    mutex.lock();
    defer mutex.unlock();
    const s = sessions.get(id);
    if (only != null and s != only) return null;
    hide(id);
    if (s != null) _ = sessions.remove(id);
    return s;
}

const End = enum {
    /// we end it: the process is terminated first
    killed,
    /// its input pipe broke
    dead,
    /// the process ended by itself; called by the session's forwarder
    exited,
};

/// Closes a session that `take` (or `killAll`) removed from the table, and frees it. Closing a
/// ConPTY can stall: never on a command's thread.
fn dispose(s: *Session, end: End) void {
    shutdown(s, end == .killed);
    reap(s, end == .exited);
}

/// Ends the process tree: the shell itself, then — by closing the console — everything attached
/// to it. The session's threads all come to an end after this.
fn shutdown(s: *Session, terminate: bool) void {
    if (terminate) s.pty.kill();
    s.pty.closeConsole();
    // (also waits for `start` to have finished with the session)
    s.mutex.lock();
    s.closing = true;
    s.keys_cond.signal(core.io);
    s.mutex.unlock();
}

fn reap(s: *Session, from_forwarder: bool) void {
    for (s.threads, 0..) |thread, i| {
        if (thread) |t| {
            if (from_forwarder and i == Session.forwarder) t.detach() else t.join();
        }
        // the writer (first) is done. A console that is still waiting for the terminal's answer
        // about the cursor does not close until its input does, and the reader waits on that.
        if (i == 0) s.pty.closeInput();
    }
    s.pty.close();
    s.pending.deinit(core.gpa);
    s.keys.deinit(core.gpa);
    core.gpa.free(s.id);
    core.gpa.destroy(s);
    _ = live.fetchSub(1, .release);
}

/// PowerShell-safe argument.
fn quoteArg(a: Allocator, arg: []const u8) ![]const u8 {
    const plain = arg.len > 0 and for (arg) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_-./:=", ch) == null) break false;
    } else true;
    if (plain) return arg;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (arg) |ch| {
        if (ch == '\'') try out.append(a, '\'');
        try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.items;
}

/// The shell's command line for a terminal. `mcp_config`: the chat's `--mcp-config` file.
fn shellArgs(a: Allocator, shell: []const u8, o: SpawnOptions, mcp_config: ?[]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, shell);
    if (std.mem.eql(u8, o.kind, "claude")) {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(a, try quoteArg(a, agentCmd(o.agent)));
        for (o.claudeArgs orelse &.{}) |arg| try line.print(a, " {s}", .{try quoteArg(a, arg)});
        // the chat's own Web tab, database and Zalo as MCP tools (Claude only); last, because
        // --mcp-config takes several values
        if (mcp_config) |cfg| try line.print(a, " --mcp-config {s}", .{try quoteArg(a, cfg)});
        // inside an interactive shell: when the agent exits the user lands in a shell in the
        // same folder instead of a dead pane
        if (core.is_windows) {
            try argv.appendSlice(a, &.{ "-NoLogo", "-NoExit", "-Command", line.items });
        } else {
            try argv.appendSlice(a, &.{ "-lc", try std.fmt.allocPrint(a, "{s}; exec {s}", .{ line.items, shell }) });
        }
    } else {
        try argv.append(a, if (core.is_windows) "-NoLogo" else "-l");
    }
    return argv.items;
}

fn pty_spawn(call: *ipc.Call, args: struct { opts: SpawnOptions, out: ipc.Channel }) !void {
    const a = call.arena;
    const o = args.opts;
    kill(o.id);

    const claude = std.mem.eql(u8, o.kind, "claude") and std.mem.eql(u8, agentCmd(o.agent), "claude");
    const mcp_config: ?[]const u8 = if (claude and @hasDecl(m.mcp, "configFor")) m.mcp.configFor(a, o.id) else null;
    const argv = try shellArgs(a, defaultShell(), o, mcp_config);
    // Claude Code keys folder trust by the exact path (`E:/x` ≠ `E:\x`): hand it the native form
    const cwd = if (core.is_windows) try std.mem.replaceOwned(u8, a, o.cwd, "/", "\\") else o.cwd;
    var env = try core.cleanEnv(a);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("FORCE_COLOR", "1");
    // the API key the user turned on for when the plan's limit is reached
    if (claude and @hasDecl(m.appcmds, "claudeApiKey")) if (m.appcmds.claudeApiKey(a, &env)) |key| try env.put("ANTHROPIC_API_KEY", key);

    var fail: core.Fail = .{};
    start(a, o.id, argv, cwd, &env, o.cols, o.rows, args.out, &fail) catch |e| return call.failMsg(fail.text(e));
}

/// Starts `argv` in a pseudo-console of its own and streams it to `out` until it exits or is killed.
fn start(a: Allocator, id: []const u8, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map, cols: u16, rows: u16, out: ipc.Channel, fail: *core.Fail) !void {
    const s = try core.gpa.create(Session);
    errdefer core.gpa.destroy(s);
    const own_id = try core.gpa.dupe(u8, id);
    errdefer core.gpa.free(own_id);
    s.* = .{ .id = own_id, .out = out, .pty = try Pty.spawn(a, argv, cwd, env, cols, rows, fail) };
    // from here on the session is closed with `dispose`
    _ = live.fetchAdd(1, .monotonic);

    mutex.lock();
    const old = if (sessions.fetchRemove(id)) |kv| kv.value else null;
    const added = sessions.put(core.gpa, s.id, s);
    // its threads are stored before any of them, or anyone who finds it in the table, ends it
    s.mutex.lock();
    mutex.unlock();
    if (old) |other| core.spawn(dispose, .{ other, .killed });
    var ok = if (added) |_| true else |_| false;
    inline for (Session.loops, 0..) |loop, i| {
        if (ok) {
            // (std's default is 16 MB of stack per thread, committed up front on Windows)
            if (std.Thread.spawn(.{ .stack_size = 1 << 20 }, loop, .{s})) |t| s.threads[i] = t else |_| ok = false;
        }
    }
    s.mutex.unlock();
    if (ok) return;
    if (added) |_| {
        if (take(id, s) != null) dispose(s, .killed);
    } else |_| dispose(s, .killed);
    return fail.set(a, "could not start the terminal (out of memory or threads)", .{});
}

/// false when there is no live process for this id (it died without us hearing about it).
fn pty_write(_: *ipc.Call, a: struct { id: []const u8, data: []const u8 }) !bool {
    return write(a.id, a.data);
}

fn write(id: []const u8, data: []const u8) bool {
    mutex.lock();
    const s = sessions.get(id) orelse {
        mutex.unlock();
        return false;
    };
    s.mutex.lock();
    const alive = !s.writer_dead;
    if (alive) {
        s.keys.appendSlice(core.gpa, data) catch {};
        s.keys_cond.signal(core.io);
    }
    s.mutex.unlock();
    if (alive) {
        mutex.unlock();
        return true;
    }
    // the writer thread ended: the process is gone
    _ = sessions.remove(id);
    hide(id);
    mutex.unlock();
    core.spawn(dispose, .{ s, .dead });
    return false;
}

fn pty_resize(_: *ipc.Call, a: struct { id: []const u8, cols: u16, rows: u16 }) !void {
    // (in the table = its console is open; ResizePseudoConsole waits on conhost, commands run on
    // worker threads)
    mutex.lock();
    defer mutex.unlock();
    if (sessions.get(a.id)) |s| s.pty.resize(a.cols, a.rows);
}

fn pty_visible(_: *ipc.Call, a: struct { id: []const u8, visible: bool }) !void {
    if (!a.visible) return hide(a.id);
    visible_mutex.lock();
    defer visible_mutex.unlock();
    if (visible.contains(a.id)) return;
    const id = try core.gpa.dupe(u8, a.id);
    errdefer core.gpa.free(id);
    try visible.put(core.gpa, id, {});
}

fn pty_kill(_: *ipc.Call, a: struct { id: []const u8 }) !void {
    kill(a.id);
}

fn kill(id: []const u8) void {
    // closing a ConPTY can stall: never on the caller's thread
    if (take(id, null)) |s| core.spawn(dispose, .{ s, .killed });
}

/// The app is quitting: every terminal's processes end with it.
pub fn killAll() void {
    while (true) {
        mutex.lock();
        var it = sessions.iterator();
        const s = if (it.next()) |e| e.value_ptr.* else null;
        if (s) |x| _ = sessions.remove(x.id);
        mutex.unlock();
        shutdown(s orelse return, true);
        core.spawn(reap, .{ s.?, false });
    }
}

// ---------------- the pseudo-console (ConPTY) ----------------

const PSEUDOCONSOLE_INHERIT_CURSOR = 0x1;
const PSEUDOCONSOLE_RESIZE_QUIRK = 0x2;
const PSEUDOCONSOLE_WIN32_INPUT_MODE = 0x4;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;

/// A pseudo-console with one process started in it, and our ends of its pipes (what the
/// `portable-pty` crate did in the Rust build; same console flags, so the page sees the same
/// stream).
const Pty = struct {
    console: Handle,
    /// keystrokes
    input: Handle,
    /// what the console draws, as a VT stream
    output: Handle,
    process: Handle,

    const Handle = if (core.is_windows) c.HANDLE else void;

    fn size(cols: u16, rows: u16) c.COORD {
        return .{ .X = @intCast(std.math.clamp(cols, 2, 32767)), .Y = @intCast(std.math.clamp(rows, 2, 32767)) };
    }

    fn spawn(a: Allocator, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map, cols: u16, rows: u16, fail: *core.Fail) !Pty {
        if (!core.is_windows) return fail.set(a, "terminals are not available on this system yet", .{});
        var in_read: c.HANDLE = null;
        var in_write: c.HANDLE = null;
        if (c.CreatePipe(&in_read, &in_write, null, 0) == 0) return fail.set(a, "CreatePipe failed: error {d}", .{c.GetLastError()});
        errdefer _ = c.CloseHandle(in_write);
        var out_read: c.HANDLE = null;
        var out_write: c.HANDLE = null;
        if (c.CreatePipe(&out_read, &out_write, null, 0) == 0) {
            _ = c.CloseHandle(in_read);
            return fail.set(a, "CreatePipe failed: error {d}", .{c.GetLastError()});
        }
        errdefer _ = c.CloseHandle(out_read);

        var console: c.HPCON = null;
        const hr = c.CreatePseudoConsole(size(cols, rows), in_read, out_write, PSEUDOCONSOLE_INHERIT_CURSOR | PSEUDOCONSOLE_RESIZE_QUIRK | PSEUDOCONSOLE_WIN32_INPUT_MODE, &console);
        // the console has its own copies of these ends
        _ = c.CloseHandle(in_read);
        _ = c.CloseHandle(out_write);
        if (hr != 0) return fail.set(a, "failed to create pseudo console: HRESULT 0x{x}", .{@as(u32, @bitCast(hr))});
        errdefer c.ClosePseudoConsole(console);

        var attrs_size: usize = 0;
        _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attrs_size);
        const attrs: c.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast((try a.alignedAlloc(u8, .of(usize), attrs_size)).ptr);
        if (c.InitializeProcThreadAttributeList(attrs, 1, 0, &attrs_size) == 0)
            return fail.set(a, "InitializeProcThreadAttributeList failed: error {d}", .{c.GetLastError()});
        defer c.DeleteProcThreadAttributeList(attrs);
        if (c.UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, @sizeOf(c.HPCON), null, null) == 0)
            return fail.set(a, "UpdateProcThreadAttribute failed: error {d}", .{c.GetLastError()});

        var si = std.mem.zeroes(c.STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
        // explicitly none: otherwise the process can inherit the handles this app was started
        // with (output redirected to a file or a pipe) and write there instead of to its console
        si.StartupInfo.dwFlags = c.STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = c.INVALID_HANDLE_VALUE;
        si.StartupInfo.hStdOutput = c.INVALID_HANDLE_VALUE;
        si.StartupInfo.hStdError = c.INVALID_HANDLE_VALUE;
        si.lpAttributeList = attrs;

        const cmd = try commandLine(a, argv);
        const app: ?[*:0]const u16 = if (cmd.app) |p| (try core.wide(a, p)).ptr else null;
        const line = try core.wide(a, cmd.line);
        // a folder that is gone: the user's home rather than no terminal
        const dir: ?[]const u8 = if (core.isDir(cwd)) cwd else if (env.get("USERPROFILE")) |h| (if (core.isDir(h)) h else null) else null;
        const dir_w: ?[*:0]const u16 = if (dir) |d| (try core.wide(a, d)).ptr else null;
        const block = try env.createWindowsBlock(a, .{});
        var pi = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(app, line.ptr, null, null, 0, c.EXTENDED_STARTUPINFO_PRESENT | c.CREATE_UNICODE_ENVIRONMENT, @ptrCast(@constCast(block.slice.ptr)), dir_w, &si.StartupInfo, &pi) == 0)
            return fail.set(a, "CreateProcessW `{s}` in `{s}` failed: error {d}", .{ cmd.line, dir orelse "", c.GetLastError() });
        _ = c.CloseHandle(pi.hThread);
        return .{ .console = console, .input = in_write, .output = out_read, .process = pi.hProcess };
    }

    /// 0 when the console was closed.
    fn read(p: *const Pty, buf: []u8) usize {
        if (!core.is_windows) return 0;
        var n: c.DWORD = 0;
        if (c.ReadFile(p.output, buf.ptr, @intCast(buf.len), &n, null) == 0) return 0;
        return n;
    }

    fn write(p: *const Pty, data: []const u8) bool {
        if (!core.is_windows) return false;
        var rest = data;
        while (rest.len > 0) {
            var n: c.DWORD = 0;
            if (c.WriteFile(p.input, rest.ptr, @intCast(@min(rest.len, 1 << 20)), &n, null) == 0 or n == 0) return false;
            rest = rest[n..];
        }
        return true;
    }

    fn resize(p: *const Pty, cols: u16, rows: u16) void {
        if (!core.is_windows) return;
        _ = c.ResizePseudoConsole(p.console, size(cols, rows));
    }

    /// Waits for the process to end; its exit code.
    fn wait(p: *const Pty) i32 {
        if (!core.is_windows) return -1;
        _ = c.WaitForSingleObject(p.process, 0xFFFFFFFF);
        var code: c.DWORD = 0;
        return if (c.GetExitCodeProcess(p.process, &code) != 0) @bitCast(code) else -1;
    }

    fn kill(p: *const Pty) void {
        if (!core.is_windows) return;
        _ = c.TerminateProcess(p.process, 1);
    }

    /// Ends every process still attached to the console, and `read`.
    fn closeConsole(p: *const Pty) void {
        if (!core.is_windows) return;
        c.ClosePseudoConsole(p.console);
    }

    fn closeInput(p: *const Pty) void {
        if (!core.is_windows) return;
        _ = c.CloseHandle(p.input);
    }

    fn close(p: *const Pty) void {
        if (!core.is_windows) return;
        _ = c.CloseHandle(p.output);
        _ = c.CloseHandle(p.process);
    }
};

const CommandLine = struct {
    /// the program CreateProcessW starts; null: Windows finds it from the first word of `line`
    app: ?[]const u8,
    line: []const u8,
};

fn commandLine(a: Allocator, argv: []const []const u8) !CommandLine {
    const found = core.which(a, argv[0]);
    const program = found orelse argv[0];
    var line: std.ArrayList(u8) = .empty;
    if (isBatchFile(program)) {
        // CreateProcessW does not run a .cmd / .bat (npm's `claude.cmd` shim…) by itself, and
        // cmd.exe reads its line by rules of its own
        try batchLine(&line, a, program, argv[1..]);
        var dir: [c.MAX_PATH]u16 = undefined;
        const n = c.GetSystemDirectoryW(&dir, dir.len);
        if (n == 0 or n >= dir.len) return error.NoSystemDirectory;
        const system = try std.unicode.wtf16LeToWtf8Alloc(a, dir[0..n]);
        return .{ .app = try std.fs.path.join(a, &.{ system, "cmd.exe" }), .line = line.items };
    }
    try appendArg(&line, a, program);
    for (argv[1..]) |arg| {
        try line.append(a, ' ');
        try appendArg(&line, a, arg);
    }
    return .{ .app = found, .line = line.items };
}

fn isBatchFile(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".cmd") or std.ascii.endsWithIgnoreCase(path, ".bat");
}

/// One argument the way the program's `CommandLineToArgvW` (and the C runtime) reads it back.
fn appendArg(line: *std.ArrayList(u8), a: Allocator, arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) return line.appendSlice(a, arg);
    try line.append(a, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        // backslashes stand for themselves, except in front of a quote: there each one is
        // doubled, and the quote gets one of its own
        try line.appendNTimes(a, '\\', if (ch == '"') backslashes * 2 + 1 else backslashes);
        try line.append(a, ch);
        backslashes = 0;
    }
    // … and in front of the closing quote
    try line.appendNTimes(a, '\\', backslashes * 2);
    try line.append(a, '"');
}

/// The line for `cmd.exe` that runs a batch file, written the way Rust's std does: cmd expands
/// `%VAR%` and splits on `&`, `|`, `^`… wherever it finds them outside quotes, so an argument
/// could otherwise run commands of its own.
fn batchLine(line: *std.ArrayList(u8), a: Allocator, script: []const u8, args: []const []const u8) !void {
    // file names have no `"` and do not end with `\`: one that does would break out of its quotes
    if (std.mem.indexOfScalar(u8, script, '"') != null or std.mem.endsWith(u8, script, "\\")) return error.InvalidBatchFile;
    // /e:ON and /v:OFF: the `%` escape below works whatever the registry says. The whole command
    // sits in one more pair of quotes, closed at the end.
    try line.print(a, "cmd.exe /e:ON /v:OFF /d /c \"\"{s}\"", .{script});
    for (args) |arg| {
        // a line break would end the command there
        if (std.mem.indexOfAny(u8, arg, "\r\n\x00") != null) return error.InvalidBatchArgument;
        try line.append(a, ' ');
        // quoted unless every character is known to be harmless; also when it ends with `\`,
        // which would escape the quote a script adds around `%~1`
        const quote = arg.len == 0 or arg[arg.len - 1] == '\\' or for (arg) |ch| {
            if (ch < 0x80 and !std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "#$*+-./:?@\\_", ch) == null) break true;
        } else false;
        if (quote) try line.append(a, '"');
        var backslashes: usize = 0;
        for (arg) |ch| {
            if (ch == '\\') {
                backslashes += 1;
            } else {
                if (ch == '"') {
                    // n backslashes in front of a quote become 2n, and the quote is doubled
                    try line.appendNTimes(a, '\\', backslashes);
                    try line.append(a, '"');
                } else if (ch == '%') {
                    // `%cd:~,%` expands to nothing, and keeps cmd from reading `%NAME%` as a variable
                    try line.appendSlice(a, "%%cd:~,");
                }
                backslashes = 0;
            }
            try line.append(a, ch);
        }
        if (quote) {
            try line.appendNTimes(a, '\\', backslashes);
            try line.append(a, '"');
        }
    }
    try line.append(a, '"');
}

// ---------------- tests ----------------

const testing = std.testing;

/// What stands in for the page in tests: keeps what each channel received and, like the terminal
/// on the page, answers the console's question about the cursor position.
const Page = struct {
    var lock: core.Mutex = .{};
    var text: std.ArrayList(u8) = .empty;
    var exit: ?i32 = null;
    /// the terminal on each channel; the one on channel 0 gets no answers (a page that is gone)
    const terminals = [_][]const u8{ "t0", "t1", "t2" };

    fn receive(channel: u64, msg: PtyMsg) void {
        lock.lock();
        defer lock.unlock();
        switch (msg) {
            .data => |d| {
                text.appendSlice(testing.allocator, d) catch {};
                if (channel != 0 and std.mem.indexOf(u8, d, "\x1b[6n") != null) _ = write(terminals[channel], "\x1b[1;1R");
            },
            .exit => |code| exit = code,
        }
    }

    fn reset() void {
        lock.lock();
        defer lock.unlock();
        text.clearAndFree(testing.allocator);
        exit = null;
    }

    fn contains(needle: []const u8) bool {
        lock.lock();
        defer lock.unlock();
        return std.mem.indexOf(u8, text.items, needle) != null;
    }

    fn exitCode() ?i32 {
        lock.lock();
        defer lock.unlock();
        return exit;
    }

    /// Waits (up to 20 s) for `needle` to show up in the output.
    fn expectText(needle: []const u8) !void {
        var i: usize = 0;
        while (i < 2000 and !contains(needle)) : (i += 1) core.sleepMs(10);
        if (contains(needle)) return;
        lock.lock();
        defer lock.unlock();
        std.debug.print("\nexpected {s} in the terminal's output:\n{f}\n", .{ needle, std.zig.fmtString(text.items) });
        return error.TestExpectedOutput;
    }

    fn expectExit(code: i32) !void {
        var i: usize = 0;
        while (i < 2000 and exitCode() == null) : (i += 1) core.sleepMs(10);
        try testing.expectEqual(code, exitCode());
    }

    /// Waits for every session to be closed and freed, then drops the text that was received.
    fn finish() !void {
        var i: usize = 0;
        while (i < 2000 and live.load(.acquire) != 0) : (i += 1) core.sleepMs(10);
        // and for the pool's thread that freed the last one to be done with its job
        core.sleepMs(50);
        lock.lock();
        text.clearAndFree(testing.allocator);
        lock.unlock();
        mutex.lock();
        defer mutex.unlock();
        const left = sessions.count();
        sessions.clearAndFree(core.gpa);
        var it = visible.keyIterator();
        while (it.next()) |k| core.gpa.free(k.*);
        visible.clearAndFree(core.gpa);
        try testing.expectEqual(0, live.load(.acquire));
        try testing.expectEqual(0, left);
    }

    /// A test failed half-way: nothing of it is left for the next one.
    fn abandon() void {
        killAll();
        finish() catch {};
    }
};

var test_env: ?std.process.Environ.Map = null;

fn testInit() !void {
    core.gpa = testing.allocator;
    core.io = testing.io;
    // kept for the whole run: not from the allocator that checks each test for leaks
    if (test_env == null) test_env = try testing.environ.createMap(std.heap.page_allocator);
    core.env = &test_env.?;
}

fn testStart(a: Allocator, channel: u64, argv: []const []const u8) !void {
    Page.reset();
    var fail: core.Fail = .{};
    start(a, Page.terminals[channel], argv, ".", core.env, 120, 30, .{ .id = channel }, &fail) catch |e| {
        std.debug.print("{s}\n", .{fail.text(e)});
        return e;
    };
}

test "agents and their commands" {
    try testing.expectEqualStrings("claude", agentCmd(null));
    try testing.expectEqualStrings("codex", agentCmd("codex"));
    try testing.expectEqualStrings("opencode", agentCmd("opencode"));
    try testing.expectEqualStrings("claude", agentCmd("no such agent"));
}

test "messages to the page" {
    const a = testing.allocator;
    const data = try core.toJson(a, PtyMsg{ .data = "hi \"there\"\r\n\x1b[0m" });
    defer a.free(data);
    try testing.expectEqualStrings("{\"kind\":\"data\",\"data\":\"hi \\\"there\\\"\\r\\n\\u001b[0m\"}", data);
    const exit = try core.toJson(a, PtyMsg{ .exit = -1 });
    defer a.free(exit);
    try testing.expectEqualStrings("{\"kind\":\"exit\",\"code\":-1}", exit);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const args = try core.fromJson(struct { opts: SpawnOptions, out: ipc.Channel }, arena.allocator(),
        \\{"opts":{"id":"t1","cwd":"D:/x","kind":"shell","cols":80,"rows":24},"out":"__CHANNEL__:7"}
    );
    try testing.expectEqual(7, args.out.id);
    try testing.expectEqual(80, args.opts.cols);
    try testing.expect(args.opts.agent == null and args.opts.claudeArgs == null);
}

test "PowerShell arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("--resume", try quoteArg(a, "--resume"));
    try testing.expectEqualStrings("C:/Users/a_b/x.json", try quoteArg(a, "C:/Users/a_b/x.json"));
    try testing.expectEqualStrings("--model=opus", try quoteArg(a, "--model=opus"));
    try testing.expectEqualStrings("''", try quoteArg(a, ""));
    try testing.expectEqualStrings("'a b'", try quoteArg(a, "a b"));
    try testing.expectEqualStrings("'it''s'", try quoteArg(a, "it's"));
    try testing.expectEqualStrings("'C:\\Users\\x'", try quoteArg(a, "C:\\Users\\x"));
    try testing.expectEqualStrings("'$(calc)'", try quoteArg(a, "$(calc)"));
    try testing.expectEqualStrings("'tiếng'", try quoteArg(a, "tiếng"));
}

test "the shell's command line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: SpawnOptions = .{ .id = "c1", .cwd = "D:/x", .kind = "claude", .cols = 80, .rows = 24 };
    const win = core.is_windows;

    var argv = try shellArgs(a, "pwsh.exe", base, null);
    try testing.expectEqualStrings("pwsh.exe", argv[0]);
    try testing.expectEqualStrings(if (win) "claude" else "claude; exec pwsh.exe", argv[argv.len - 1]);
    if (win) {
        try testing.expectEqual(5, argv.len);
        try testing.expectEqualStrings("-NoLogo", argv[1]);
        try testing.expectEqualStrings("-NoExit", argv[2]);
        try testing.expectEqualStrings("-Command", argv[3]);
    }

    var o = base;
    o.claudeArgs = &.{ "--resume", "abc-123", "--append-system-prompt", "be brief, it's late" };
    argv = try shellArgs(a, "pwsh.exe", o, "C:\\Users\\A B\\mcp.json");
    const line = "claude --resume abc-123 --append-system-prompt 'be brief, it''s late' --mcp-config 'C:\\Users\\A B\\mcp.json'";
    try testing.expectEqualStrings(if (win) line else line ++ "; exec pwsh.exe", argv[argv.len - 1]);

    o.agent = "codex";
    o.claudeArgs = &.{"resume"};
    argv = try shellArgs(a, "pwsh.exe", o, null);
    try testing.expectEqualStrings(if (win) "codex resume" else "codex resume; exec pwsh.exe", argv[argv.len - 1]);

    o.kind = "shell";
    argv = try shellArgs(a, "pwsh.exe", o, null);
    try testing.expectEqual(2, argv.len);
    try testing.expectEqualStrings(if (win) "-NoLogo" else "-l", argv[1]);
}

test "a UTF-8 sequence cut in half waits for its other half" {
    try testing.expectEqual(0, utf8Cut(""));
    try testing.expectEqual(5, utf8Cut("hello"));
    try testing.expectEqual(6, utf8Cut("việt")); // complete
    try testing.expectEqual(1, utf8Cut("v\xe1")); // ệ = e1 bb 87
    try testing.expectEqual(1, utf8Cut("v\xe1\xbb"));
    try testing.expectEqual(4, utf8Cut("v\xe1\xbb\x87"));
    try testing.expectEqual(2, utf8Cut("ok\xf0\x9f\x98")); // 😀 = f0 9f 98 80
    try testing.expectEqual(6, utf8Cut("ok\xf0\x9f\x98\x80"));
    try testing.expectEqual(0, utf8Cut("\xc3"));
    // not UTF-8 at all: nothing to wait for
    try testing.expectEqual(3, utf8Cut("a\x80\x80"));
    try testing.expectEqual(4, utf8Cut("\x80\x80\x80\x80"));
    try testing.expectEqual(2, utf8Cut("a\xff"));

    // across two rounds: the page gets whole characters only, and bad bytes as U+FFFD
    try testInit();
    Page.reset();
    defer Page.reset();
    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(testing.allocator);
    try carry.appendSlice(testing.allocator, "vi\xe1\xbb");
    Session.send(.{ .id = 1 }, &carry);
    try testing.expectEqualStrings("\xe1\xbb", carry.items);
    try carry.appendSlice(testing.allocator, "\x87t \xff!");
    Session.send(.{ .id = 1 }, &carry);
    try testing.expectEqual(0, carry.items.len);
    try testing.expectEqualStrings("việt \u{FFFD}!", Page.text.items);
}

fn expectArgvRoundTrip(argv: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try line.append(a, ' ');
        try appendArg(&line, a, arg);
    }
    var n: c_int = 0;
    const parsed = c.CommandLineToArgvW(try core.wide(a, line.items), &n) orelse return error.TestUnexpectedResult;
    defer _ = c.LocalFree(@ptrCast(parsed));
    try testing.expectEqual(argv.len, @as(usize, @intCast(n)));
    for (argv, 0..) |arg, i| try testing.expectEqualStrings(arg, try core.fromWide(a, parsed[i]));
}

test "arguments survive the command line (read back by Windows itself)" {
    if (!core.is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    try appendArg(&line, a, "plain");
    try testing.expectEqualStrings("plain", line.items);
    line.clearRetainingCapacity();
    try appendArg(&line, a, "a \"b\" c\\");
    try testing.expectEqualStrings("\"a \\\"b\\\" c\\\\\"", line.items);

    try expectArgvRoundTrip(&.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo", "-NoExit", "-Command", "claude --resume 'a b' --mcp-config 'C:\\Users\\A B\\mcp.json'" });
    try expectArgvRoundTrip(&.{ "prog.exe", "", "a b", "say \"hi\"", "back\\slash", "ends with\\", "C:\\dir with space\\", "\\\"", "a\\\\\"b c", "tab\there", "tiếng Việt", "'single'", "%PATH%", "a&b|c^d" });
    try expectArgvRoundTrip(&.{ "prog.exe", "\\\\server\\share\\", "\"", "\"\"", "\\", "x\\\\", " " });
}

test "the line for a batch file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var line: std.ArrayList(u8) = .empty;
    try batchLine(&line, a, "C:\\Users\\A B\\npm\\claude.cmd", &.{ "plugin", "install", "context7@claude-plugins-official" });
    try testing.expectEqualStrings("cmd.exe /e:ON /v:OFF /d /c \"\"C:\\Users\\A B\\npm\\claude.cmd\" plugin install context7@claude-plugins-official\"", line.items);

    line.clearRetainingCapacity();
    try batchLine(&line, a, "x.bat", &.{ "a b", "", "100%", "%PATH%", "say \"hi\"", "dir\\", "a&calc", "back\\slash", "q\\\"" });
    try testing.expectEqualStrings("cmd.exe /e:ON /v:OFF /d /c \"\"x.bat\" \"a b\" \"\" \"100%%cd:~,%\" \"%%cd:~,%PATH%%cd:~,%\" \"say \"\"hi\"\"\" \"dir\\\\\" \"a&calc\" back\\slash \"q\\\\\"\"\"\"", line.items);

    try testing.expectError(error.InvalidBatchArgument, batchLine(&line, a, "x.bat", &.{"two\nlines"}));
    try testing.expectError(error.InvalidBatchFile, batchLine(&line, a, "x\".bat", &.{}));
    try testing.expect(isBatchFile("C:\\npm\\claude.CMD") and isBatchFile("x.bat") and !isBatchFile("claude.exe") and !isBatchFile("cmd"));
}

test "a process in a pseudo-console: its output, then its exit code" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testStart(a, 1, &.{ "cmd.exe", "/c", "echo hello from conpty& exit 7" });
    try Page.expectText("hello from conpty");
    try Page.expectExit(7);
    // it left the table by itself, and tells the page so only once
    try testing.expect(!write("t1", "x"));
    try Page.finish();

    // a program that is not there: an error with the command in it, nothing left behind
    Page.reset();
    var fail: core.Fail = .{};
    try testing.expectError(error.Failed, start(a, "t2", &.{ "no-such-program-here.exe", "x y" }, ".", core.env, 80, 24, .{ .id = 1 }, &fail));
    try testing.expect(std.mem.indexOf(u8, fail.msg, "no-such-program-here.exe \"x y\"") != null);
    try Page.finish();
}

test "typing, resizing, visibility and killing a terminal" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var call: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };

    try testStart(a, 1, &.{ "cmd.exe", "/q", "/k", "prompt $G" });
    try pty_visible(&call, .{ .id = "t1", .visible = true });
    try testing.expect(isVisible("t1"));
    // `^` is dropped by cmd: the text only appears joined once the command has run
    try testing.expect(try pty_write(&call, .{ .id = "t1", .data = "echo ty^ped tiếng Vi" }));
    try testing.expect(try pty_write(&call, .{ .id = "t1", .data = "ệt\r" }));
    try Page.expectText("typed tiếng Việt");
    try pty_resize(&call, .{ .id = "t1", .cols = 100, .rows = 40 });
    try pty_resize(&call, .{ .id = "no such", .cols = 100, .rows = 40 });
    try testing.expect(try pty_write(&call, .{ .id = "t1", .data = "mode con\r" }));
    try Page.expectText("100");
    try testing.expect(!try pty_write(&call, .{ .id = "no such", .data = "x" }));

    // a restart under the same id: the first process is killed without an "exit" for the page
    try testStart(a, 1, &.{ "cmd.exe", "/q", "/k", "prompt $G" });
    try testing.expect(try pty_write(&call, .{ .id = "t1", .data = "echo sec^ond\r" }));
    try Page.expectText("second");
    try pty_kill(&call, .{ .id = "t1" });
    try testing.expect(!isVisible("t1"));
    try testing.expect(!try pty_write(&call, .{ .id = "t1", .data = "x" }));
    try Page.finish();
    try testing.expectEqual(null, Page.exitCode());
}

test "quitting ends every terminal" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testStart(a, 1, &.{ "cmd.exe", "/q", "/k", "prompt $G" });
    try testStart(a, 2, &.{ "cmd.exe", "/q", "/k", "prompt $G" });
    try testing.expectEqual(2, live.load(.acquire));
    killAll();
    try testing.expect(!write("t1", "x") and !write("t2", "x"));
    try Page.finish();
    try testing.expectEqual(null, Page.exitCode());
}

test "a terminal whose page never answers the console is still closed" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testStart(arena.allocator(), 0, &.{ "cmd.exe", "/q", "/k", "prompt $G" });
    try Page.expectText("\x1b[6n");
    kill("t0");
    try Page.finish();
}

test "a .cmd shim gets its arguments whole" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try core.makePath(try std.fs.path.join(a, &.{ dir, "a b" }));
    const script = try std.fs.path.join(a, &.{ dir, "a b", "shim.cmd" });
    try core.writeFile(script, "@echo off\r\necho [%1] [%2] [%3] [%4]\r\nexit /b 3\r\n");

    try testStart(a, 1, &.{ script, "one two", "100%", "%USERPROFILE%", "a&echo owned" });
    // (as cmd hands them to the script: still in their quotes)
    try Page.expectText("[\"one two\"] [\"100%\"] [\"%USERPROFILE%\"] [\"a&echo owned\"]");
    try Page.expectExit(3);
    try Page.finish();
}

test "what PowerShell makes of a quoted agent line" {
    if (!core.is_windows) return error.SkipZigTest;
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the way a chat is started, with Write-Output in the agent's place (and no profile, no -NoExit)
    var line: std.ArrayList(u8) = .empty;
    try line.appendSlice(a, "Write-Output");
    for ([_][]const u8{ "--resume", "it's a \"b\" $HOME `x", "C:\\Users\\A B\\mcp.json" }) |arg| try line.print(a, " {s}", .{try quoteArg(a, arg)});
    try testStart(a, 1, &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", line.items });
    try Page.expectText("--resume");
    try Page.expectText("it's a \"b\" $HOME `x");
    try Page.expectText("C:\\Users\\A B\\mcp.json");
    try Page.expectExit(0);
    try Page.finish();
}

test "finding claude" {
    try testInit();
    errdefer Page.abandon();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var call: ipc.Call = .{ .arena = arena.allocator(), .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    const found = try agents_detect(&call);
    try testing.expectEqual(7, found.len);
    try testing.expectEqualStrings("claude", found[0].id);
    // on PATH, or where the installers put it; whichever, the file is there
    if (claudePath(call.arena)) |p| try testing.expect(core.isFile(p)) else try testing.expect(!found[0].found);
}
