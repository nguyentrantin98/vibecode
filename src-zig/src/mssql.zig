//! SQL Server for the Database tab and Claude's `mssql_*` tools.
//!
//! Queries run in a long-lived PowerShell process (`mssql_bridge.ps1`): Windows ships SqlClient
//! with .NET Framework, so no driver is needed and SQL logins, Windows auth and LocalDB all work.
//! One JSON request per stdin line → one JSON reply per stdout line.
//! Saved connections live in `<userData>/db-connections.json`, connection strings sealed.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tr = settings.tr;

const BRIDGE_PS1 = @embedFile("mssql_bridge.ps1");

const ws = &std.ascii.whitespace;

/// Index of the first byte at or after `i` that is not white space.
fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
    return j;
}

/// A letter, digit or `_` (what a regex `\b` looks at).
fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

// ---------------- the bridge process (PowerShell + SqlClient) ----------------

/// One caller waiting for its reply.
const Waiter = struct {
    done: std.Io.Event = .unset,
    /// the reply line (owned by `core.gpa`)…
    reply: ?[]u8 = null,
    /// …or why there is none (owned by the bridge)
    err: []const u8 = "",
};

const Bridge = struct {
    /// held by CURRENT, the two reading threads and every caller between `start` and its reply
    refs: std.atomic.Value(u32) = .init(1),
    child_lock: core.Mutex = .{},
    /// its pipes are taken out: each one is closed by the thread that uses it
    child: std.process.Child,
    stdin_lock: core.Mutex = .{},
    stdin: std.Io.File,
    lock: core.Mutex = .{},
    /// set once the process is gone: why it stopped
    dead: ?[]const u8 = null,
    waiting: std.AutoHashMapUnmanaged(u64, *Waiter) = .empty,
    /// the process said it is ready, or is gone
    ready: std.Io.Event = .unset,
    err_lock: core.Mutex = .{},
    /// the end of what the process wrote to stderr
    err_buf: std.ArrayList(u8) = .empty,
    err_done: std.Io.Event = .unset,

    fn deadMsg(b: *Bridge) ?[]const u8 {
        b.lock.lock();
        defer b.lock.unlock();
        return b.dead;
    }

    fn alive(b: *Bridge) bool {
        return b.deadMsg() == null;
    }

    fn kill(b: *Bridge) void {
        b.child_lock.lock();
        defer b.child_lock.unlock();
        b.child.kill(core.io);
    }

    fn retain(b: *Bridge) *Bridge {
        _ = b.refs.fetchAdd(1, .monotonic);
        return b;
    }

    fn release(b: *Bridge) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        b.stdin.close(core.io);
        if (b.dead) |d| core.gpa.free(d);
        b.waiting.deinit(core.gpa);
        b.err_buf.deinit(core.gpa);
        core.gpa.destroy(b);
    }
};

/// The running bridge, if any.
var current: ?*Bridge = null;
var current_lock: core.Mutex = .{};
/// One start at a time (held until the new process says it is ready).
var starting: core.Mutex = .{};
var seq: std.atomic.Value(u64) = .init(0);

/// Keep stdin plain ASCII: the bridge reads it with the console code page.
fn ascii(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x7f) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        var cp: u21 = 0xfffd;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |n| {
            if (i + n <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + n])) |c| {
                    cp = c;
                    len = n;
                } else |_| {}
            }
        } else |_| {}
        i += len;
        if (cp < 0x10000) {
            try out.print(a, "\\u{x:0>4}", .{cp});
        } else {
            const c = cp - 0x10000;
            try out.print(a, "\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff) });
        }
    }
    return out.items;
}

/// The running bridge, or a new one once it is ready. The caller releases it.
fn start(a: Allocator, fail: *core.Fail) !*Bridge {
    starting.lock();
    defer starting.unlock();
    {
        current_lock.lock();
        defer current_lock.unlock();
        if (current) |b| if (b.alive()) return b.retain();
    }
    const script = core.resourceFile(a, "mssql_bridge.ps1", BRIDGE_PS1) catch |e| return fail.set(a, "{s}", .{@errorName(e)});
    const cannot_start = tr("could not start PowerShell", "không chạy được PowerShell");
    var child = std.process.spawn(core.io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |e| return fail.set(a, "{s}: {s}", .{ cannot_start, @errorName(e) });
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    const b = core.gpa.create(Bridge) catch {
        child.kill(core.io);
        return error.OutOfMemory;
    };
    b.* = .{ .child = child, .stdin = child.stdin.? };
    b.child.stdin = null;
    b.child.stdout = null;
    b.child.stderr = null;
    const t = std.Thread.spawn(.{}, readLoop, .{ b.retain(), stdout, stderr }) catch |e| {
        stdout.close(core.io);
        stderr.close(core.io);
        b.kill();
        b.release(); // the reader's
        b.release();
        return fail.set(a, "{s}: {s}", .{ cannot_start, @errorName(e) });
    };
    t.detach();
    {
        current_lock.lock();
        defer current_lock.unlock();
        if (current) |old| old.release();
        current = b.retain();
    }
    b.ready.waitUncancelable(core.io);
    if (b.deadMsg()) |e| {
        defer b.release();
        return fail.set(a, "{s}", .{e});
    }
    return b;
}

fn queryStopped() []const u8 {
    return tr("Query stopped.", "Truy vấn đã dừng.");
}

/// Collects what the process writes to stderr (it says there why it could not start).
fn errLoop(b: *Bridge, stderr: std.Io.File) void {
    defer b.release();
    var chunk: [4096]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    while (true) {
        const n = stderr.readStreaming(core.io, &bufs) catch break;
        b.err_lock.lock();
        defer b.err_lock.unlock();
        b.err_buf.appendSlice(core.gpa, chunk[0..n]) catch continue;
        const keep = 4000;
        const len = b.err_buf.items.len;
        if (len > keep) {
            std.mem.copyForwards(u8, b.err_buf.items[0..keep], b.err_buf.items[len - keep ..]);
            b.err_buf.shrinkRetainingCapacity(keep);
        }
    }
    stderr.close(core.io);
    b.err_done.set(core.io);
}

/// Routes replies to their callers; when the process ends, fails everything still waiting.
fn readLoop(b: *Bridge, stdout: std.Io.File, stderr: std.Io.File) void {
    defer b.release();
    if (std.Thread.spawn(.{}, errLoop, .{ b.retain(), stderr })) |t| t.detach() else |_| {
        b.release();
        stderr.close(core.io);
        b.err_done.set(core.io);
    }

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(core.gpa);
    var chunk: [64 << 10]u8 = undefined;
    var bufs = [_][]u8{&chunk};
    reading: while (true) {
        const n = stdout.readStreaming(core.io, &bufs) catch break;
        var rest: []const u8 = chunk[0..n];
        while (std.mem.findScalar(u8, rest, '\n')) |i| {
            line.appendSlice(core.gpa, rest[0..i]) catch break :reading;
            onLine(b, line.items);
            // a big result set is not worth keeping the memory for
            if (line.capacity > 1 << 20) line.clearAndFree(core.gpa) else line.clearRetainingCapacity();
            rest = rest[i + 1 ..];
        }
        line.appendSlice(core.gpa, rest) catch break;
    }
    onLine(b, line.items);
    stdout.close(core.io);

    // the process is gone (or going): give stderr a moment to arrive, then fail what waits
    b.err_done.waitTimeout(core.io, .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } }) catch {};
    const err: []const u8 = blk: {
        b.err_lock.lock();
        defer b.err_lock.unlock();
        const text = std.mem.trim(u8, b.err_buf.items, ws);
        if (text.len == 0) break :blk core.gpa.dupe(u8, queryStopped()) catch @panic("oom");
        const first = std.mem.trim(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], ws);
        break :blk std.fmt.allocPrint(core.gpa, "{s} {f}", .{ tr("SQL runner stopped:", "Trình chạy SQL đã dừng:"), std.unicode.fmtUtf8(first) }) catch @panic("oom");
    };
    {
        b.lock.lock();
        defer b.lock.unlock();
        b.dead = err;
        var it = b.waiting.valueIterator();
        while (it.next()) |w| {
            w.*.err = err;
            w.*.done.set(core.io);
        }
        b.waiting.clearRetainingCapacity();
    }
    b.ready.set(core.io);
    {
        current_lock.lock();
        defer current_lock.unlock();
        if (current == b) {
            current = null;
            b.release();
        }
    }
    b.kill();
}

/// One line from the process: `{"ready":true}` once, then a reply for each request (by id).
fn onLine(b: *Bridge, raw: []const u8) void {
    const line = std.mem.trim(u8, raw, ws);
    if (line.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    // (only these two keys are read here: the rows are parsed once, by the caller)
    const head = core.fromJson(struct { ready: Value = .null, id: Value = .null }, arena.allocator(), line) catch return;
    if (truthy(head.ready)) {
        b.ready.set(core.io);
        return;
    }
    if (head.id != .integer or head.id.integer < 0) return;
    b.lock.lock();
    defer b.lock.unlock();
    const kv = b.waiting.fetchRemove(@intCast(head.id.integer)) orelse return;
    kv.value.reply = core.gpa.dupe(u8, line) catch null;
    kv.value.done.set(core.io);
}

/// Sends one request (`req` without its id) and returns the reply line.
fn bridge(a: Allocator, req: anytype, fail: *core.Fail) ![]const u8 {
    const b = try start(a, fail);
    defer b.release();
    const id = seq.fetchAdd(1, .monotonic) + 1;
    const json = try core.toJson(a, req);
    const line = try std.fmt.allocPrint(a, "{{\"id\":{d},{s}\n", .{ id, try ascii(a, json[1..]) });
    var w: Waiter = .{};
    {
        b.lock.lock();
        defer b.lock.unlock();
        if (b.dead) |e| return fail.set(a, "{s}", .{e});
        try b.waiting.put(core.gpa, id, &w);
    }
    const wrote = blk: {
        b.stdin_lock.lock();
        defer b.stdin_lock.unlock();
        break :blk b.stdin.writeStreamingAll(core.io, line);
    };
    if (wrote) |_| {
        w.done.waitUncancelable(core.io);
    } else |e| {
        // the process is probably exiting: its own error says more, if it comes soon
        w.done.waitTimeout(core.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }) catch {
            b.lock.lock();
            const still_waiting = b.waiting.remove(id);
            b.lock.unlock();
            // (not waiting any more: the answer came in just now)
            if (still_waiting) return fail.set(a, "{s}: {s}", .{ tr("SQL runner is not responding", "Trình chạy SQL không phản hồi"), @errorName(e) });
        };
    }
    if (w.reply) |r| {
        defer core.gpa.free(r);
        return a.dupe(u8, r);
    }
    return fail.set(a, "{s}", .{if (w.err.len > 0) w.err else queryStopped()});
}

/// Stop whatever is running (the runner restarts on the next query). Also called on app exit.
pub fn cancelAll() void {
    current_lock.lock();
    const b = current;
    current = null;
    current_lock.unlock();
    if (b) |x| {
        x.kill();
        x.release();
    }
}

pub fn deinit() void {
    cancelAll();
}

// ---------------- shapes (src/shared/types.ts) ----------------

/// Writes a struct leaving out its null fields (serde's `skip_serializing_if = "Option::is_none"`).
fn writeWithoutNulls(v: anytype, w: anytype) !void {
    try w.beginObject();
    inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
        const f = @field(v, name);
        if (@typeInfo(@TypeOf(f)) == .optional) {
            if (f) |x| {
                try w.objectField(name);
                try w.write(x);
            }
        } else {
            try w.objectField(name);
            try w.write(f);
        }
    }
    try w.endObject();
}

/// A saved connection as the UI sees it — no password.
pub const DbConnection = struct {
    id: []const u8,
    name: []const u8,
    server: []const u8,
    database: []const u8,
    /// "sql" | "windows"
    auth: []const u8,
    user: []const u8,
    claudeReadOnly: bool,
    color: ?[]const u8 = null,

    pub fn jsonStringify(s: DbConnection, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

/// `DbConnection` and its connection string.
pub const DbConnectionWithConn = struct {
    id: []const u8,
    name: []const u8,
    server: []const u8,
    database: []const u8,
    auth: []const u8,
    user: []const u8,
    claudeReadOnly: bool,
    color: ?[]const u8 = null,
    conn: []const u8,

    pub fn jsonStringify(s: DbConnectionWithConn, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

pub const DbConnectionInput = struct {
    id: ?[]const u8 = null,
    name: []const u8,
    conn: []const u8,
    claudeReadOnly: bool = false,
    color: ?[]const u8 = null,
};

/// A connection string found in the project or in SSMS, ready to add.
pub const DbFound = struct {
    name: []const u8,
    conn: []const u8,
    file: []const u8,
    needsPassword: ?bool = null,

    pub fn jsonStringify(s: DbFound, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

pub const DbObject = struct {
    schema: []const u8,
    name: []const u8,
    /// U table, V view, P procedure, FN / IF / TF function
    type: []const u8,
};

pub const DbColumn = struct {
    name: []const u8,
    type: []const u8,
    nullable: bool,
    identity: bool,
    pk: bool,
    ref: ?[]const u8 = null,

    pub fn jsonStringify(s: DbColumn, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

pub const DbColumnHead = struct {
    name: []const u8 = "",
    type: []const u8 = "",
};

pub const DbResultSet = struct {
    columns: []const DbColumnHead = &.{},
    rows: []const []const Value = &.{},
    truncated: bool = false,
};

pub const DbQueryResult = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    results: []const DbResultSet = &.{},
    messages: []const []const u8 = &.{},
    /// rows inserted / updated / deleted; -1 for none
    affected: i64 = -1,
    ms: u64 = 0,

    pub fn jsonStringify(s: DbQueryResult, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

pub const TestResult = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
    version: ?[]const u8 = null,

    pub fn jsonStringify(s: TestResult, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

pub const BuildConnFields = struct {
    server: []const u8,
    database: ?[]const u8 = null,
    windowsAuth: bool = false,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    trustCert: ?bool = null,
    encrypt: ?bool = null,
};

// ---------------- saved connections ----------------

const Stored = struct {
    id: []const u8,
    name: []const u8,
    /// connection string, sealed (base64) when `enc`
    conn: []const u8,
    enc: bool = false,
    claudeReadOnly: bool = false,
    color: ?[]const u8 = null,

    pub fn jsonStringify(s: Stored, w: anytype) !void {
        return writeWithoutNulls(s, w);
    }
};

/// Held around every read-modify-write of the store file.
var store_lock: core.Mutex = .{};

fn storeFile(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"db-connections.json"});
}

fn load(a: Allocator) []const Stored {
    const path = storeFile(a) catch return &.{};
    const bytes = core.readFileAlloc(a, path, 64 << 20) catch return &.{};
    return core.fromJson([]const Stored, a, bytes) catch &.{};
}

fn persist(a: Allocator, list: []const Stored) !void {
    const json = try std.json.Stringify.valueAlloc(a, list, .{ .whitespace = .indent_2 });
    try core.writeAtomic(try storeFile(a), json);
}

const Sealed = struct { conn: []const u8, enc: bool };

fn seal(a: Allocator, conn: []const u8) Sealed {
    if (@hasDecl(m.secure, "sealStr")) {
        if (m.secure.sealStr(a, conn)) |s| return .{ .conn = s, .enc = true } else |_| {}
    }
    return .{ .conn = conn, .enc = false };
}

fn unseal(a: Allocator, s: Stored, fail: *core.Fail) ![]const u8 {
    if (!s.enc) return s.conn;
    const cannot = tr(
        "could not decrypt (was it saved by another Windows user?)",
        "không giải mã được (có phải nó được lưu bởi một người dùng Windows khác?)",
    );
    if (!@hasDecl(m.secure, "openStr")) return fail.set(a, "{s}", .{cannot});
    return m.secure.openStr(a, s.conn) catch fail.set(a, "{s}", .{cannot});
}

/// Key/value pairs of a connection string (a JSON object for the page).
pub const ConnMap = std.json.ArrayHashMap([]const u8);

/// Connection string → key/value pairs (keys lower-cased), honouring "quoted" and 'quoted' values.
pub fn parseConn(a: Allocator, conn: []const u8) !ConnMap {
    var out: ConnMap = .{};
    var i: usize = 0;
    while (i < conn.len) {
        const eq = std.mem.findScalarPos(u8, conn, i, '=') orelse break;
        const key = try core.lower(a, std.mem.trim(u8, conn[i..eq], ws));
        var j = eq + 1;
        while (j < conn.len and conn[j] == ' ') j += 1;
        var val: []const u8 = "";
        if (j < conn.len and (conn[j] == '"' or conn[j] == '\'')) {
            const q = conn[j];
            j += 1;
            var buf: std.ArrayList(u8) = .empty;
            while (j < conn.len) {
                if (conn[j] == q) {
                    if (j + 1 < conn.len and conn[j + 1] == q) {
                        try buf.append(a, q);
                        j += 2;
                        continue;
                    }
                    j += 1;
                    break;
                }
                try buf.append(a, conn[j]);
                j += 1;
            }
            val = buf.items;
            i = if (std.mem.findScalarPos(u8, conn, j, ';')) |s| s + 1 else conn.len;
        } else {
            const semi = std.mem.findScalarPos(u8, conn, j, ';');
            val = std.mem.trim(u8, conn[j .. semi orelse conn.len], ws);
            i = if (semi) |s| s + 1 else conn.len;
        }
        if (key.len > 0) try out.map.put(a, key, val);
    }
    return out;
}

fn pick(kv: ConnMap, keys: []const []const u8) []const u8 {
    for (keys) |k| if (kv.map.get(k)) |v| return v;
    return "";
}

/// A value safe inside a connection string.
fn quoteVal(a: Allocator, v: []const u8) ![]const u8 {
    const needs = std.mem.findAny(u8, v, ";'\"=") != null or
        (v.len > 0 and (std.ascii.isWhitespace(v[0]) or std.ascii.isWhitespace(v[v.len - 1])));
    if (!needs) return v;
    return std.fmt.allocPrint(a, "\"{s}\"", .{try std.mem.replaceOwned(u8, a, v, "\"", "\"\"")});
}

pub fn buildConn(a: Allocator, f: BuildConnFields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Server={s}", .{try quoteVal(a, f.server)});
    if (f.database) |db| if (db.len > 0) try out.print(a, ";Database={s}", .{try quoteVal(a, db)});
    if (f.windowsAuth) {
        try out.appendSlice(a, ";Integrated Security=True");
    } else {
        try out.print(a, ";User ID={s}", .{try quoteVal(a, f.user orelse "")});
        try out.print(a, ";Password={s}", .{try quoteVal(a, f.password orelse "")});
    }
    if (f.encrypt orelse false) try out.appendSlice(a, ";Encrypt=True");
    if (f.trustCert orelse true) try out.appendSlice(a, ";TrustServerCertificate=True");
    return out.items;
}

fn describe(a: Allocator, s: Stored) !DbConnection {
    // unreadable (sealed on another account) → just the name
    var fail: core.Fail = .{};
    const kv: ConnMap = if (unseal(a, s, &fail)) |c| try parseConn(a, c) else |_| .{};
    const how = pick(kv, &.{ "integrated security", "trusted_connection" });
    const integrated = for ([_][]const u8{ "true", "yes", "sspi" }) |x| {
        if (std.ascii.eqlIgnoreCase(how, x)) break true;
    } else false;
    return .{
        .id = s.id,
        .name = s.name,
        .server = pick(kv, &.{ "server", "data source", "address", "addr", "network address" }),
        .database = pick(kv, &.{ "database", "initial catalog" }),
        .auth = if (integrated) "windows" else "sql",
        .user = if (integrated) "" else pick(kv, &.{ "user id", "uid", "user" }),
        .claudeReadOnly = s.claudeReadOnly,
        .color = s.color,
    };
}

fn describeAll(a: Allocator, list: []const Stored) ![]DbConnection {
    const out = try a.alloc(DbConnection, list.len);
    for (list, out) |s, *d| d.* = try describe(a, s);
    return out;
}

pub fn listConnections(a: Allocator) ![]DbConnection {
    return describeAll(a, load(a));
}

fn getConnection(a: Allocator, id: []const u8, fail: *core.Fail) !?DbConnectionWithConn {
    for (load(a)) |s| {
        if (!std.mem.eql(u8, s.id, id)) continue;
        const d = try describe(a, s);
        return .{
            .id = d.id,
            .name = d.name,
            .server = d.server,
            .database = d.database,
            .auth = d.auth,
            .user = d.user,
            .claudeReadOnly = d.claudeReadOnly,
            .color = d.color,
            .conn = try unseal(a, s, fail),
        };
    }
    return null;
}

fn saveConnection(a: Allocator, input: DbConnectionInput) ![]DbConnection {
    store_lock.lock();
    defer store_lock.unlock();
    var list: std.ArrayList(Stored) = .empty;
    try list.appendSlice(a, load(a));
    const i: ?usize = if (input.id) |id| for (list.items, 0..) |c, n| {
        if (std.mem.eql(u8, c.id, id)) break n;
    } else null else null;
    const sealed = seal(a, input.conn);
    const name = std.mem.trim(u8, input.name, ws);
    const item: Stored = .{
        .id = if (i) |n| list.items[n].id else blk: {
            var rnd: [6]u8 = undefined;
            core.io.random(&rnd);
            break :blk try a.dupe(u8, &std.fmt.bytesToHex(rnd, .lower));
        },
        .name = if (name.len == 0) "SQL Server" else name,
        .conn = sealed.conn,
        .enc = sealed.enc,
        .claudeReadOnly = input.claudeReadOnly,
        .color = input.color,
    };
    if (i) |n| list.items[n] = item else try list.append(a, item);
    try persist(a, list.items);
    return describeAll(a, list.items);
}

fn saveConnections(a: Allocator, inputs: []const DbConnectionInput) ![]DbConnection {
    var out = try listConnections(a);
    for (inputs) |c| out = try saveConnection(a, c);
    return out;
}

fn removeConnection(a: Allocator, id: []const u8) ![]DbConnection {
    store_lock.lock();
    defer store_lock.unlock();
    var list: std.ArrayList(Stored) = .empty;
    for (load(a)) |c| {
        if (!std.mem.eql(u8, c.id, id)) try list.append(a, c);
    }
    try persist(a, list.items);
    return describeAll(a, list.items);
}

/// The same text whatever the letter case (names are often Vietnamese: ASCII folding is not enough).
fn sameName(a: Allocator, x: []const u8, y: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(x, y)) return true;
    if (core.is_windows) {
        const win = core.host.win.c;
        const wx = core.wide(a, x) catch return false;
        const wy = core.wide(a, y) catch return false;
        return win.CompareStringOrdinal(wx.ptr, @intCast(wx.len), wy.ptr, @intCast(wy.len), 1) == win.CSTR_EQUAL;
    }
    return false;
}

/// By id or by name (case-insensitive) — Claude refers to connections by name.
fn findStored(a: Allocator, reference: []const u8, fail: *core.Fail) !Stored {
    const list = load(a);
    for (list) |c| if (std.mem.eql(u8, c.id, reference)) return c;
    const wanted = std.mem.trim(u8, reference, ws);
    for (list) |c| if (sameName(a, c.name, wanted)) return c;
    var names: std.ArrayList(u8) = .empty;
    for (list, 0..) |c, i| {
        if (i > 0) try names.appendSlice(a, ", ");
        try names.appendSlice(a, c.name);
    }
    return fail.set(a, "No saved connection \"{s}\". Saved: {s}", .{ reference, if (names.items.len == 0) "(none)" else names.items });
}

// ---------------- queries ----------------

const Batch = struct {
    text: []const u8,
    /// editor line the batch starts on (1-based)
    line: usize,
};

/// A line that is just `GO` (any case), with an optional `-- comment` after it.
fn isGo(line: []const u8) bool {
    var i = skipWs(line, 0);
    if (!std.ascii.startsWithIgnoreCase(line[i..], "go")) return false;
    i = skipWs(line, i + 2);
    return i == line.len or std.mem.startsWith(u8, line[i..], "--");
}

/// T-SQL batches split on GO lines (GO isn't SQL — SSMS / sqlcmd split on it, so do we).
fn batches(a: Allocator, sql: []const u8) ![]Batch {
    var out: std.ArrayList(Batch) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var cur_lines: usize = 0;
    var start_line: usize = 1;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, sql, '\n');
    while (it.next()) |raw| : (i += 1) {
        const l = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (isGo(l)) {
            if (std.mem.trim(u8, cur.items, ws).len > 0) try out.append(a, .{ .text = cur.items, .line = start_line });
            cur = .empty;
            cur_lines = 0;
            start_line = i + 2;
        } else {
            if (cur_lines > 0) try cur.append(a, '\n');
            try cur.appendSlice(a, l);
            cur_lines += 1;
        }
    }
    if (std.mem.trim(u8, cur.items, ws).len > 0) try out.append(a, .{ .text = cur.items, .line = start_line });
    return out.items;
}

fn bracket(a: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[{s}]", .{try std.mem.replaceOwned(u8, a, name, "]", "]]")});
}

/// Adds `by` to the number of every `Line N:` that starts a line of a server error.
fn shiftLines(a: Allocator, err: []const u8, by: usize) ![]u8 {
    const prefix = "Line ";
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var it = std.mem.splitScalar(u8, err, '\n');
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        var e: usize = prefix.len;
        if (std.mem.startsWith(u8, line, prefix)) {
            while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
        }
        if (e > prefix.len and e < line.len and line[e] == ':') {
            const n = std.fmt.parseInt(usize, line[prefix.len..e], 10) catch 0;
            try out.print(a, "Line {d}{s}", .{ n +| by, line[e..] });
        } else {
            try out.appendSlice(a, line);
        }
    }
    return out.items;
}

const RunOpts = struct {
    database: ?[]const u8 = null,
    max_rows: ?u32 = null,
    timeout: ?u32 = null,
    read_only: bool = false,
};

fn queryFailed() []const u8 {
    return tr("Query failed", "Truy vấn thất bại");
}

fn runOn(a: Allocator, conn: []const u8, sql: []const u8, o: RunOpts, fail: *core.Fail) !DbQueryResult {
    const t0 = core.monoMs();
    const database: ?[]const u8 = if (o.database) |d| (if (d.len > 0) d else null) else null;
    var result: DbQueryResult = .{ .ok = true };
    var results: std.ArrayList(DbResultSet) = .empty;
    var messages: std.ArrayList([]const u8) = .empty;
    for (try batches(a, sql)) |b| {
        // USE on the same line, so the server's line numbers still match the editor's
        const text = if (database) |d| try std.fmt.allocPrint(a, "USE {s}; {s}", .{ try bracket(a, d), b.text }) else b.text;
        const reply = try bridge(a, .{
            .conn = conn,
            .sql = text,
            .maxRows = o.max_rows orelse 1000,
            .timeout = o.timeout orelse 120,
            .readOnly = o.read_only,
        }, fail);
        const r = core.fromJson(DbQueryResult, a, reply) catch |e|
            return fail.set(a, "unexpected reply from the SQL runner: {s}", .{@errorName(e)});
        try results.appendSlice(a, r.results);
        for (r.messages) |msg| {
            // (our own USE says "Changed database context to …" — not news to the user)
            if (database != null and std.mem.startsWith(u8, msg, "Changed database context to ")) continue;
            try messages.append(a, msg);
        }
        if (r.affected >= 0) result.affected = @max(result.affected, 0) + r.affected;
        if (!r.ok) {
            result.ok = false;
            // server line numbers are per batch: shift them to the editor's
            result.@"error" = try shiftLines(a, r.@"error" orelse queryFailed(), b.line - 1);
            break;
        }
    }
    result.results = results.items;
    result.messages = messages.items;
    result.ms = core.monoMs() - t0;
    return result;
}

fn query(a: Allocator, id: []const u8, sql: []const u8, database: ?[]const u8, max_rows: ?u32, fail: *core.Fail) !DbQueryResult {
    const conn = try unseal(a, try findStored(a, id, fail), fail);
    return runOn(a, conn, sql, .{ .database = database, .max_rows = max_rows }, fail);
}

/// `String(v)` as JavaScript would write a cell.
fn jsStr(a: Allocator, v: ?Value) ![]const u8 {
    const x = v orelse return "undefined";
    return switch (x) {
        .string, .number_string => |s| s,
        else => core.toJson(a, x),
    };
}

/// "" for a missing or null value, `jsStr` otherwise.
fn strOrEmpty(a: Allocator, v: ?Value) ![]const u8 {
    if (v == null or v.? == .null) return "";
    return jsStr(a, v);
}

/// JavaScript truthiness of a JSON value.
fn truthy(v: ?Value) bool {
    return switch (v orelse return false) {
        .null => false,
        .bool => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0.0 and !std.math.isNan(f),
        .number_string => |s| if (std.fmt.parseFloat(f64, s)) |f| f != 0.0 and !std.math.isNan(f) else |_| false,
        .string => |s| s.len > 0,
        .array, .object => true,
    };
}

/// `Number(v)` as JavaScript would convert it.
fn jsNumber(v: ?Value) f64 {
    const nan = std.math.nan(f64);
    return switch (v orelse return nan) {
        .null => 0.0,
        .bool => |b| @floatFromInt(@intFromBool(b)),
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch nan,
        .string => |s| blk: {
            const t = std.mem.trim(u8, s, ws);
            break :blk if (t.len == 0) 0.0 else std.fmt.parseFloat(f64, t) catch nan;
        },
        .array, .object => nan,
    };
}

/// A member of a JSON object (null for anything that is not an object).
fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn cell(row: []const Value, i: usize) ?Value {
    return if (i < row.len) row[i] else null;
}

fn firstRows(r: DbQueryResult) []const []const Value {
    return if (r.results.len > 0) r.results[0].rows else &.{};
}

fn okOrErr(a: Allocator, r: DbQueryResult, fail: *core.Fail) !DbQueryResult {
    return if (r.ok) r else fail.set(a, "{s}", .{r.@"error" orelse queryFailed()});
}

fn testConnection(a: Allocator, conn: []const u8, fail: *core.Fail) !TestResult {
    const r = try runOn(
        a,
        conn,
        "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) + ' ' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), DB_NAME()",
        .{ .timeout = 20 },
        fail,
    );
    if (!r.ok) return .{ .ok = false, .@"error" = r.@"error" };
    const rows = firstRows(r);
    const row: []const Value = if (rows.len > 0) rows[0] else &.{};
    return .{ .ok = true, .version = try std.fmt.allocPrint(a, "SQL Server {s} · {s} {s}", .{
        try jsStr(a, cell(row, 0)),
        tr("database", "cơ sở dữ liệu"),
        try jsStr(a, cell(row, 1)),
    }) };
}

fn listDatabases(a: Allocator, id: []const u8, fail: *core.Fail) ![]const []const u8 {
    const r = try okOrErr(a, try query(
        a,
        id,
        "SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY CASE WHEN database_id <= 4 THEN 1 ELSE 0 END, name",
        null,
        5000,
        fail,
    ), fail);
    const rows = firstRows(r);
    const out = try a.alloc([]const u8, rows.len);
    for (rows, out) |x, *o| o.* = try jsStr(a, cell(x, 0));
    return out;
}

fn listObjects(a: Allocator, id: []const u8, database: []const u8, fail: *core.Fail) ![]DbObject {
    const r = try okOrErr(a, try query(
        a,
        id,
        "SELECT s.name, o.name, o.type FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id\n" ++
            "     WHERE o.type IN ('U','V','P','FN','IF','TF') AND o.is_ms_shipped = 0 ORDER BY o.type, s.name, o.name",
        database,
        20000,
        fail,
    ), fail);
    const rows = firstRows(r);
    const out = try a.alloc(DbObject, rows.len);
    for (rows, out) |x, *o| o.* = .{
        .schema = try jsStr(a, cell(x, 0)),
        .name = try jsStr(a, cell(x, 1)),
        .type = std.mem.trim(u8, try jsStr(a, cell(x, 2)), ws),
    };
    return out;
}

fn columnsSql(a: Allocator, schema: []const u8, table: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\
        \\SELECT c.name, TYPE_NAME(c.user_type_id)
        \\  + CASE WHEN TYPE_NAME(c.user_type_id) IN ('varchar','char','varbinary','binary') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length AS varchar) END + ')'
        \\         WHEN TYPE_NAME(c.user_type_id) IN ('nvarchar','nchar') THEN '(' + CASE WHEN c.max_length = -1 THEN 'max' ELSE CAST(c.max_length / 2 AS varchar) END + ')'
        \\         WHEN TYPE_NAME(c.user_type_id) IN ('decimal','numeric') THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')'
        \\         ELSE '' END,
        \\  c.is_nullable, c.is_identity,
        \\  CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        \\                    WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
        \\  (SELECT OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) + '.' + COL_NAME(fk.referenced_object_id, fk.referenced_column_id)
        \\     FROM sys.foreign_key_columns fk WHERE fk.parent_object_id = c.object_id AND fk.parent_column_id = c.column_id)
        \\FROM sys.columns c WHERE c.object_id = OBJECT_ID(N'{s}.{s}')
        \\ORDER BY c.column_id
    , .{
        try std.mem.replaceOwned(u8, a, try bracket(a, schema), "'", "''"),
        try std.mem.replaceOwned(u8, a, try bracket(a, table), "'", "''"),
    });
}

fn listColumns(a: Allocator, id: []const u8, database: []const u8, schema: []const u8, table: []const u8, fail: *core.Fail) ![]DbColumn {
    const r = try okOrErr(a, try query(a, id, try columnsSql(a, schema, table), database, 5000, fail), fail);
    const rows = firstRows(r);
    const out = try a.alloc(DbColumn, rows.len);
    for (rows, out) |x, *o| o.* = .{
        .name = try jsStr(a, cell(x, 0)),
        .type = try jsStr(a, cell(x, 1)),
        .nullable = truthy(cell(x, 2)),
        .identity = truthy(cell(x, 3)),
        .pk = truthy(cell(x, 4)),
        .ref = if (truthy(cell(x, 5))) try jsStr(a, cell(x, 5)) else null,
    };
    return out;
}

// ---------------- finding existing connections ----------------

/// One of `keys` followed by `=` (any case, white space allowed before the `=`). `first`: only
/// where a `key=value` pair can start — at the beginning, or right after a `;`.
fn hasKey(s: []const u8, keys: []const []const u8, first: bool) bool {
    for (0..s.len) |i| {
        if (first and i > 0 and s[i - 1] != ';') continue;
        const j = if (first) skipWs(s, i) else i;
        for (keys) |k| {
            if (!std.ascii.startsWithIgnoreCase(s[j..], k)) continue;
            const e = skipWs(s, j + k.len);
            if (e < s.len and s[e] == '=') return true;
        }
    }
    return false;
}

fn looksSql(s: []const u8) bool {
    return hasKey(s, &.{ "server", "data source", "address", "addr" }, true) and
        hasKey(s, &.{ "initial catalog", "database", "integrated security", "trusted_connection", "user id", "uid" }, false) and
        !hasKey(s, &.{ "host", "port" }, true);
}

/// Drops `/* … */` and `// …` comments, except `//` right after `:`, `"` or a word character
/// (URLs and the like).
fn stripJsonComments(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    var i: usize = 0;
    while (i + 1 < text.len) {
        const end: ?usize = if (text[i] != '/')
            null
        else if (text[i + 1] == '*')
            (if (std.mem.findPos(u8, text, i + 2, "*/")) |e| e + 2 else null)
        else if (text[i + 1] == '/' and !(i > 0 and (text[i - 1] == ':' or text[i - 1] == '"' or isWord(text[i - 1]))))
            std.mem.findAnyPos(u8, text, i + 2, "\r\n") orelse text.len
        else
            null;
        if (end) |e| {
            try out.appendSlice(a, text[last..i]);
            last = e;
            i = e;
        } else {
            i += 1;
        }
    }
    try out.appendSlice(a, text[last..]);
    return out.items;
}

/// Drops the commas that JSON does not allow: the ones right before a `}` or `]`.
fn dropTrailingCommas(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len);
    for (text, 0..) |ch, i| {
        if (ch == ',') {
            const j = skipWs(text, i + 1);
            if (j < text.len and (text[j] == '}' or text[j] == ']')) continue;
        }
        out.appendAssumeCapacity(ch);
    }
    return out.items;
}

const Pair = struct { key: []const u8, value: []const u8 };

/// Every string in a JSON document with the key (or array index) it sits under, in document order.
fn jsonStrings(a: Allocator, text: []const u8) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    var sc: std.json.Scanner = .initCompleteInput(a, text);
    defer sc.deinit();
    // one entry per open container: the index of the next item of an array, null for an object
    var open: std.ArrayList(?usize) = .empty;
    var key: []const u8 = "connection";
    var want_key = false;
    while (true) {
        switch (try sc.nextAlloc(a, .alloc_always)) {
            .end_of_document => break,
            .object_begin => {
                try open.append(a, null);
                want_key = true;
                continue;
            },
            .array_begin => {
                try open.append(a, 0);
                key = "0";
                continue;
            },
            .object_end, .array_end => _ = open.pop(),
            .string, .allocated_string => |s| {
                if (want_key) {
                    key = s;
                    want_key = false;
                    continue;
                }
                try out.append(a, .{ .key = key, .value = s });
            },
            else => {},
        }
        // a value ended: what comes next in the container it sits in
        want_key = false;
        if (open.items.len == 0) continue;
        const top = &open.items[open.items.len - 1];
        if (top.*) |*n| {
            n.* += 1;
            key = try std.fmt.allocPrint(a, "{d}", .{n.*});
        } else {
            want_key = true;
        }
    }
    return out.items;
}

const PairMatch = struct { key: []const u8, value: []const u8, end: usize };

/// The next `"key": "value"` at or after `from`, as written (the value still has its escapes).
/// For files that are not JSON even with their comments removed.
fn jsonPair(text: []const u8, from: usize) ?PairMatch {
    var at = from;
    while (std.mem.findScalarPos(u8, text, at, '"')) |q| : (at = q + 1) {
        const key_end = std.mem.findScalarPos(u8, text, q + 1, '"') orelse return null;
        if (key_end == q + 1) continue;
        var i = skipWs(text, key_end + 1);
        if (i >= text.len or text[i] != ':') continue;
        i = skipWs(text, i + 1);
        if (i >= text.len or text[i] != '"') continue;
        const value_start = i + 1;
        i = value_start;
        const closed = while (i < text.len) {
            if (text[i] == '"') break true;
            if (text[i] != '\\') {
                i += 1;
            } else if (i + 1 < text.len and text[i + 1] != '\n') {
                i += 2;
            } else break false;
        } else false;
        if (!closed) continue;
        return .{ .key = text[q + 1 .. key_end], .value = text[value_start..i], .end = i + 1 };
    }
    return null;
}

/// `\x` → `x`.
fn unescape(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] != '\n') i += 1;
        try out.append(a, s[i]);
    }
    return out.items;
}

/// The next `<add …>` element at or after `from` (any case).
fn addTag(text: []const u8, from: usize) ?[]const u8 {
    var at = from;
    while (std.mem.findScalarPos(u8, text, at, '<')) |lt| : (at = lt + 1) {
        if (!std.ascii.startsWithIgnoreCase(text[lt..], "<add")) continue;
        if (lt + 4 < text.len and isWord(text[lt + 4])) continue;
        const gt = std.mem.findScalarPos(u8, text, lt + 4, '>') orelse return null;
        return text[lt .. gt + 1];
    }
    return null;
}

/// The value of `name="…"` in an XML tag (any case, white space allowed around the `=`).
fn xmlAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    for (0..tag.len) |i| {
        if (!std.ascii.startsWithIgnoreCase(tag[i..], name)) continue;
        var j = skipWs(tag, i + name.len);
        if (j >= tag.len or tag[j] != '=') continue;
        j = skipWs(tag, j + 1);
        if (j >= tag.len or tag[j] != '"') continue;
        const end = std.mem.findScalarPos(u8, tag, j + 1, '"') orelse continue;
        return tag[j + 1 .. end];
    }
    return null;
}

const EnvLine = struct { key: []const u8, value: []const u8, end: usize };

/// The next `KEY = value` of a .env file at or after `from`. As the regex this replaces did, white
/// space includes line ends: `KEY=` with nothing after it takes the next line as its value.
fn envLine(text: []const u8, from: usize) ?EnvLine {
    var p = from;
    while (p < text.len) : (p += 1) {
        // at the start of a line (CR LF counts as one line end)
        if (p > 0 and text[p - 1] != '\n' and !(text[p - 1] == '\r' and text[p] != '\n')) continue;
        const key_start = skipWs(text, p);
        var i = key_start;
        while (i < text.len and (isWord(text[i]) or text[i] == '.')) i += 1;
        if (i == key_start) continue;
        const key = text[key_start..i];
        i = skipWs(text, i);
        if (i >= text.len or text[i] != '=') continue;
        i = skipWs(text, i + 1);
        if (i >= text.len) continue;
        const end = std.mem.findAnyPos(u8, text, i, "\r\n") orelse text.len;
        return .{ .key = key, .value = text[i..end], .end = end };
    }
    return null;
}

/// Where the connection strings of one file go.
const Finder = struct {
    a: Allocator,
    out: *std.ArrayList(DbFound),
    proj: []const u8,
    file: []const u8,

    fn add(f: Finder, key: []const u8, conn: []const u8) !void {
        if (!looksSql(conn)) return;
        for (f.out.items) |x| if (std.mem.eql(u8, x.conn, conn)) return;
        try f.out.append(f.a, .{ .name = try std.fmt.allocPrint(f.a, "{s} · {s}", .{ f.proj, key }), .conn = conn, .file = f.file });
    }
};

/// SQL Server connection strings in a project: appsettings*.json, *.config, .env files.
fn scanProjectSync(a: Allocator, folder: []const u8) ![]DbFound {
    var out: std.ArrayList(DbFound) = .empty;
    if (folder.len > 0 and core.exists(folder)) try walk(a, folder, "", 0, &out);
    return out.items;
}

fn isJsonName(n: []const u8) bool {
    if (!std.mem.endsWith(u8, n, ".json")) return false;
    const stem = n[0 .. n.len - ".json".len];
    if (std.mem.startsWith(u8, stem, "appsettings")) return true;
    for ([_][]const u8{ "connectionstrings", "secrets", "launchsettings" }) |x| {
        if (std.mem.eql(u8, stem, x)) return true;
    }
    return false;
}

fn isEnvName(n: []const u8) bool {
    return std.mem.eql(u8, n, ".env") or std.mem.startsWith(u8, n, ".env.");
}

/// `rel_dir`: `dir` as seen from the folder that is scanned ("" for that folder itself).
fn walk(a: Allocator, dir: []const u8, rel_dir: []const u8, depth: usize, out: *std.ArrayList(DbFound)) !void {
    const skip = [_][]const u8{ "node_modules", ".git", "bin", "obj", "dist", "out", ".vs", ".idea", "packages", "wwwroot" };

    if (depth > 5 or out.items.len > 200) return;
    var d = std.Io.Dir.cwd().openDir(core.io, dir, .{ .iterate = true }) catch return;
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        const name = try a.dupe(u8, e.name);
        const p = try std.fs.path.join(a, &.{ dir, name });
        const rel = if (rel_dir.len == 0) name else try std.fs.path.join(a, &.{ rel_dir, name });
        const n = try core.lower(a, name);
        if (e.kind == .directory) {
            const skipped = name[0] == '.' or for (skip) |x| {
                if (std.mem.eql(u8, n, x)) break true;
            } else false;
            if (!skipped) try walk(a, p, rel, depth + 1, out);
            continue;
        }
        const json = isJsonName(n);
        const xml = std.mem.endsWith(u8, n, ".config") and !std.mem.endsWith(u8, n, "packages.config");
        const env = isEnvName(n);
        if (!json and !xml and !env) continue;
        const bytes = core.readFileAlloc(a, p, 64 << 20) catch continue;
        const text = if (std.unicode.utf8ValidateSlice(bytes)) bytes else try std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(bytes)});
        const f: Finder = .{ .a = a, .out = out, .proj = std.fs.path.basename(dir), .file = rel };
        if (json) {
            const body = if (std.mem.startsWith(u8, text, "\u{feff}")) text[3..] else text;
            const cleaned = try dropTrailingCommas(a, try stripJsonComments(a, body));
            if (jsonStrings(a, cleaned)) |pairs| {
                for (pairs) |kv| try f.add(kv.key, kv.value);
            } else |_| {
                var pos: usize = 0;
                while (jsonPair(text, pos)) |kv| : (pos = kv.end) try f.add(kv.key, try unescape(a, kv.value));
            }
        } else if (xml) {
            var pos: usize = 0;
            while (addTag(text, pos)) |tag| : (pos = @intFromPtr(tag.ptr) - @intFromPtr(text.ptr) + tag.len) {
                var cs: []const u8 = xmlAttr(tag, "connectionString") orelse continue;
                for ([_][2][]const u8{ .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&amp;", "&" } }) |r| {
                    cs = try std.mem.replaceOwned(u8, a, cs, r[0], r[1]);
                }
                try f.add(xmlAttr(tag, "name") orelse "connection", cs);
            }
        } else {
            var pos: usize = 0;
            while (envLine(text, pos)) |kv| : (pos = kv.end) {
                const v = std.mem.trim(u8, kv.value, ws);
                // drop one pair of matching quotes around the value
                const quoted = v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0];
                try f.add(kv.key, if (quoted) v[1 .. v.len - 1] else v);
            }
        }
    }
}

/// Connections saved in SQL Server Management Studio (passwords from Windows Credential Manager).
fn scanSsms(a: Allocator, fail: *core.Fail) ![]DbFound {
    const reply = try bridge(a, .{ .op = "ssms" }, fail);
    const r = std.json.parseFromSliceLeaky(Value, a, reply, .{}) catch |e|
        return fail.set(a, "unexpected reply from the SQL runner: {s}", .{@errorName(e)});
    var out: std.ArrayList(DbFound) = .empty;
    const list = field(r, "connections") orelse Value.null;
    for (if (list == .array) list.array.items else &.{}) |c| {
        const auth = try strOrEmpty(a, field(c, "auth"));
        // 0 = Windows, 1 = SQL login; Entra ID kinds need a newer driver than Windows ships
        const windows = std.mem.eql(u8, auth, "0");
        if (!windows and !std.mem.eql(u8, auth, "1")) continue;
        const server = try jsStr(a, field(c, "server"));
        const user = try strOrEmpty(a, field(c, "user"));
        const password: ?[]const u8 = if (field(c, "password")) |p| (if (p == .string and p.string.len > 0) p.string else null) else null;
        const trust = field(c, "trustCert") orelse Value.null;
        const encrypt = field(c, "encrypt") orelse Value.null;
        try out.append(a, .{
            .name = if (windows) server else try std.fmt.allocPrint(a, "{s} ({s})", .{ server, user }),
            .conn = try buildConn(a, .{
                .server = server,
                .database = try strOrEmpty(a, field(c, "database")),
                .windowsAuth = windows,
                .user = user,
                .password = password orelse "",
                .trustCert = !(trust == .bool and !trust.bool),
                .encrypt = encrypt == .bool and encrypt.bool,
            }),
            .file = if (present(field(c, "source"))) try jsStr(a, field(c, "source")) else "SSMS",
            .needsPassword = !windows and password == null,
        });
    }
    std.mem.sort(DbFound, out.items, {}, struct {
        fn before(_: void, x: DbFound, y: DbFound) bool {
            return switch (std.ascii.orderIgnoreCase(x.name, y.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, x.name, y.name) == .lt,
            };
        }
    }.before);
    return out.items;
}

/// Neither missing nor null.
fn present(v: ?Value) bool {
    return v != null and v.? != .null;
}

// ---------------- commands ----------------

pub const commands = .{
    .{ "db_list", db_list },
    .{ "db_get", db_get },
    .{ "db_save", db_save },
    .{ "db_save_many", db_save_many },
    .{ "db_remove", db_remove },
    .{ "db_test", db_test },
    .{ "db_build_conn", db_build_conn },
    .{ "db_parse_conn", db_parse_conn },
    .{ "db_query", db_query },
    .{ "db_cancel", db_cancel },
    .{ "db_databases", db_databases },
    .{ "db_objects", db_objects },
    .{ "db_columns", db_columns },
    .{ "db_scan_project", db_scan_project },
    .{ "db_scan_ssms", db_scan_ssms },
};

fn db_list(c: *ipc.Call) ![]DbConnection {
    return listConnections(c.arena);
}

fn db_get(c: *ipc.Call, args: struct { id: []const u8 }) !?DbConnectionWithConn {
    var fail: core.Fail = .{};
    return getConnection(c.arena, args.id, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_save(c: *ipc.Call, args: struct { c: DbConnectionInput }) ![]DbConnection {
    return saveConnection(c.arena, args.c);
}

fn db_save_many(c: *ipc.Call, args: struct { list: []const DbConnectionInput }) ![]DbConnection {
    return saveConnections(c.arena, args.list);
}

fn db_remove(c: *ipc.Call, args: struct { id: []const u8 }) ![]DbConnection {
    return removeConnection(c.arena, args.id);
}

fn db_test(c: *ipc.Call, args: struct { conn: []const u8 }) !TestResult {
    var fail: core.Fail = .{};
    return testConnection(c.arena, args.conn, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_build_conn(c: *ipc.Call, args: struct { f: BuildConnFields }) ![]u8 {
    return buildConn(c.arena, args.f);
}

fn db_parse_conn(c: *ipc.Call, args: struct { conn: []const u8 }) !ConnMap {
    return parseConn(c.arena, args.conn);
}

fn db_query(c: *ipc.Call, args: struct { id: []const u8, sql: []const u8, database: ?[]const u8 = null, maxRows: ?u32 = null }) !DbQueryResult {
    var fail: core.Fail = .{};
    return query(c.arena, args.id, args.sql, args.database, args.maxRows, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_cancel(_: *ipc.Call) !void {
    cancelAll();
}

fn db_databases(c: *ipc.Call, args: struct { id: []const u8 }) ![]const []const u8 {
    var fail: core.Fail = .{};
    return listDatabases(c.arena, args.id, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_objects(c: *ipc.Call, args: struct { id: []const u8, database: []const u8 }) ![]DbObject {
    var fail: core.Fail = .{};
    return listObjects(c.arena, args.id, args.database, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_columns(c: *ipc.Call, args: struct { id: []const u8, database: []const u8, schema: []const u8, table: []const u8 }) ![]DbColumn {
    var fail: core.Fail = .{};
    return listColumns(c.arena, args.id, args.database, args.schema, args.table, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn db_scan_project(c: *ipc.Call, args: struct { folder: []const u8 }) ![]DbFound {
    return scanProjectSync(c.arena, args.folder);
}

fn db_scan_ssms(c: *ipc.Call) ![]DbFound {
    var fail: core.Fail = .{};
    return scanSsms(c.arena, &fail) catch |e| return c.failMsg(fail.text(e));
}

// ---------------- for Claude (MCP tools) ----------------

const CELL_MAX = 300;

/// The first `n` characters of `s`, if it is longer than that.
fn cut(s: []const u8, n: usize) ?[]const u8 {
    var chars: usize = 0;
    for (s, 0..) |b, i| {
        if (b & 0xc0 == 0x80) continue; // inside a character
        if (chars == n) return s[0..i];
        chars += 1;
    }
    return null;
}

fn tableCell(a: Allocator, out: *std.ArrayList(u8), v: Value) !void {
    var s: []const u8 = switch (v) {
        .null => return out.appendSlice(a, "NULL"),
        else => try jsStr(a, v),
    };
    var more = false;
    if (cut(s, CELL_MAX)) |head| {
        s = head;
        more = true;
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '|' => try out.appendSlice(a, "\\|"),
            '\n' => try out.appendSlice(a, "⏎"),
            '\r' => if (i + 1 < s.len and s[i + 1] == '\n') {
                try out.appendSlice(a, "⏎");
                i += 1;
            } else try out.append(a, '\r'),
            else => |b| try out.append(a, b),
        }
    }
    // (cut first, then escaped: the mark goes after whatever the cut left)
    if (more) try out.appendSlice(a, "…");
}

fn asTable(a: Allocator, r: DbResultSet) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "| ");
    for (r.columns, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, " | ");
        try tableCell(a, &out, .{ .string = if (c.name.len == 0) "(no name)" else c.name });
    }
    try out.appendSlice(a, " |\n|");
    for (r.columns, 0..) |_, i| try out.appendSlice(a, if (i > 0) "|---" else "---");
    try out.append(a, '|');
    for (r.rows) |row| {
        try out.appendSlice(a, "\n| ");
        for (row, 0..) |v, i| {
            if (i > 0) try out.appendSlice(a, " | ");
            try tableCell(a, &out, v);
        }
        try out.appendSlice(a, " |");
    }
    const n = r.rows.len;
    try out.print(a, "\n({d} row{s}{s})", .{
        n,
        if (n == 1) "" else "s",
        if (r.truncated) ", more rows not shown — narrow the query or raise max_rows" else "",
    });
    return out.items;
}

pub const INSTRUCTIONS: []const u8 = "Query the SQL Server databases the user connected in VIBE CODE's Database tab. Start with mssql_connections, explore with mssql_schema, then mssql_query. Prefer small, targeted SELECTs (TOP n).";

const TOOLS =
    \\[
    \\  {
    \\    "name": "mssql_connections",
    \\    "description": "List the SQL Server connections the user saved in VIBE CODE (name, server, default database, auth, whether you may only read).",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  },
    \\  {
    \\    "name": "mssql_schema",
    \\    "description": "Explore a database. Without `table`: list databases (if no `database`), or tables/views/procedures in `database`. With `table` (\"schema.name\" or \"name\"): its columns with types, nullability, primary key and foreign keys.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "connection": { "type": "string", "description": "Connection name from mssql_connections" },
    \\        "database": { "type": "string" },
    \\        "table": { "type": "string" }
    \\      },
    \\      "required": ["connection"]
    \\    }
    \\  },
    \\  {
    \\    "name": "mssql_query",
    \\    "description": "Run T-SQL on a saved SQL Server connection and get the rows back as a table. Use T-SQL syntax (TOP, not LIMIT). GO separates batches. Connections marked read-only run inside a transaction that is always rolled back.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "connection": { "type": "string", "description": "Connection name from mssql_connections" },
    \\        "sql": { "type": "string" },
    \\        "database": { "type": "string", "description": "Database to run in (default: the connection's own)" },
    \\        "max_rows": { "type": "number", "description": "Rows to return per result set (default 100, max 2000)" }
    \\      },
    \\      "required": ["connection", "sql"]
    \\    }
    \\  }
    \\]
;

/// The `mssql_*` tools, as MCP `tools/list` entries.
pub fn tools(a: Allocator) ![]const u8 {
    return a.dupe(u8, TOOLS);
}

/// `COMMIT`, `SAVE TRAN` or `SAVE TRANSACTION` as whole words, in any case.
fn writesTx(sql: []const u8) bool {
    for (0..sql.len) |i| {
        if (i > 0 and isWord(sql[i - 1])) continue;
        const rest = sql[i..];
        if (std.ascii.startsWithIgnoreCase(rest, "commit") and wordEnds(rest, 6)) return true;
        if (!std.ascii.startsWithIgnoreCase(rest, "save")) continue;
        const j = skipWs(rest, 4);
        if (j == 4 or !std.ascii.startsWithIgnoreCase(rest[j..], "tran")) continue;
        if (wordEnds(rest, j + 4)) return true;
        if (std.ascii.startsWithIgnoreCase(rest[j + 4 ..], "saction") and wordEnds(rest, j + 11)) return true;
    }
    return false;
}

fn wordEnds(s: []const u8, i: usize) bool {
    return i >= s.len or !isWord(s[i]);
}

/// Runs one of the tools above; returns the text Claude sees.
pub fn callTool(a: Allocator, name: []const u8, args: Value, fail: *core.Fail) anyerror![]const u8 {
    if (std.mem.eql(u8, name, "mssql_connections")) {
        const list = try listConnections(a);
        if (list.len == 0) return "No connections saved yet. Ask the user to add one in the Database tab of VIBE CODE.";
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |c, i| {
            if (i > 0) try out.append(a, '\n');
            try out.print(a, "- {s}: {s}", .{ c.name, c.server });
            if (c.database.len > 0) try out.print(a, " / {s}", .{c.database});
            if (std.mem.eql(u8, c.auth, "windows")) try out.appendSlice(a, " (Windows auth)") else try out.print(a, " (login {s})", .{c.user});
            if (c.claudeReadOnly) try out.appendSlice(a, " [read-only]");
        }
        return out.items;
    }
    const s = try findStored(a, try strOrEmpty(a, field(args, "connection")), fail);
    const conn = try unseal(a, s, fail);
    const database: ?[]const u8 = if (truthy(field(args, "database"))) try jsStr(a, field(args, "database")) else null;
    if (std.mem.eql(u8, name, "mssql_schema")) {
        if (truthy(field(args, "table"))) {
            var raw: std.ArrayList(u8) = .empty;
            for (try jsStr(a, field(args, "table"))) |ch| {
                if (ch != '[' and ch != ']') try raw.append(a, ch);
            }
            var parts = std.mem.splitBackwardsScalar(u8, raw.items, '.');
            const table = parts.first();
            const before = parts.next() orelse "";
            const schema = if (before.len > 0) before else "dbo";
            const r = try okOrErr(a, try runOn(a, conn, try columnsSql(a, schema, table), .{ .database = database, .max_rows = 2000 }, fail), fail);
            const rows = firstRows(r);
            if (rows.len == 0) {
                return std.fmt.allocPrint(a, "No table or view {s}.{s}{s}{s}.", .{ schema, table, if (database != null) " in " else "", database orelse "" });
            }
            var out: std.ArrayList(u8) = .empty;
            try out.print(a, "{s}.{s}:", .{ schema, table });
            for (rows) |x| {
                try out.print(a, "\n- {s} {s}{s}{s}{s}", .{
                    try jsStr(a, cell(x, 0)),
                    try jsStr(a, cell(x, 1)),
                    if (truthy(cell(x, 2))) " NULL" else " NOT NULL",
                    if (truthy(cell(x, 4))) " PK" else "",
                    if (truthy(cell(x, 3))) " IDENTITY" else "",
                });
                if (truthy(cell(x, 5))) try out.print(a, " → {s}", .{try jsStr(a, cell(x, 5))});
            }
            return out.items;
        }
        const db = database orelse {
            const r = try okOrErr(a, try runOn(a, conn, "SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 ORDER BY name", .{ .max_rows = 5000 }, fail), fail);
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, "Databases:\n");
            for (firstRows(r), 0..) |x, i| {
                if (i > 0) try out.append(a, '\n');
                try out.print(a, "- {s}", .{try jsStr(a, cell(x, 0))});
            }
            return out.items;
        };
        const r = try okOrErr(a, try runOn(
            a,
            conn,
            "SELECT o.type_desc, s.name + '.' + o.name FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id\n" ++
                "       WHERE o.type IN ('U','V','P','FN','IF','TF') AND o.is_ms_shipped = 0 ORDER BY o.type, s.name, o.name",
            .{ .database = db, .max_rows = 20000 },
            fail,
        ), fail);
        const Group = struct { kind: []const u8, count: usize = 0, names: std.ArrayList(u8) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        for (firstRows(r)) |row| {
            const t = try jsStr(a, cell(row, 0));
            const g = for (groups.items) |*g| {
                if (std.mem.eql(u8, g.kind, t)) break g;
            } else blk: {
                try groups.append(a, .{ .kind = t });
                break :blk &groups.items[groups.items.len - 1];
            };
            if (g.count > 0) try g.names.appendSlice(a, ", ");
            try g.names.appendSlice(a, try jsStr(a, cell(row, 1)));
            g.count += 1;
        }
        if (groups.items.len == 0) return "No user objects.";
        var out: std.ArrayList(u8) = .empty;
        for (groups.items, 0..) |g, i| {
            if (i > 0) try out.appendSlice(a, "\n\n");
            try out.print(a, "{s} ({d}):\n{s}", .{ g.kind, g.count, g.names.items });
        }
        return out.items;
    }
    if (std.mem.eql(u8, name, "mssql_query")) {
        const sql = try strOrEmpty(a, field(args, "sql"));
        if (s.claudeReadOnly and writesTx(sql)) {
            return fail.set(a, "This connection is read-only for Claude: COMMIT / SAVE TRANSACTION are not allowed.", .{});
        }
        const n = jsNumber(field(args, "max_rows"));
        const max: u32 = @intFromFloat(std.math.clamp(if (std.math.isNan(n) or n == 0.0) 100.0 else n, 1.0, 2000.0));
        const r = try runOn(a, conn, sql, .{ .database = database, .max_rows = max, .read_only = s.claudeReadOnly }, fail);
        var parts: std.ArrayList([]const u8) = .empty;
        for (r.results) |set| try parts.append(a, try asTable(a, set));
        if (r.messages.len > 0) {
            try parts.append(a, try std.fmt.allocPrint(a, "Messages:\n{s}", .{try std.mem.join(a, "\n", r.messages)}));
        }
        if (r.affected >= 0) {
            try parts.append(a, try std.fmt.allocPrint(a, "{d} row(s) affected{s}.", .{
                r.affected,
                if (s.claudeReadOnly) " (rolled back: read-only connection)" else "",
            }));
        }
        if (!r.ok) try parts.append(a, try std.fmt.allocPrint(a, "Error: {s}", .{r.@"error" orelse "undefined"}));
        const text = try std.mem.join(a, "\n\n", parts.items);
        if (text.len == 0) return "Done (no results).";
        if (cut(text, 80000)) |head| return std.fmt.allocPrint(a, "{s}\n… (output cut — ask for fewer rows or columns)", .{head});
        return text;
    }
    return fail.set(a, "Unknown tool {s}", .{name});
}

// ---------------- tests ----------------

const testing = std.testing;

var test_env: std.process.Environ.Map = undefined;
var test_dir: ?[]const u8 = null;

/// For the tests that reach the data folder, `tr()` or the bridge: a profile of their own under
/// .zig-cache (never the user's), and an allocator that the settings cache, the data folder's
/// path and the bridge's threads can outlive one test with.
fn testProfile() !void {
    core.gpa = std.heap.smp_allocator;
    core.io = testing.io;
    if (test_dir == null) {
        const rel = ".zig-cache/tmp/mssql-test";
        std.Io.Dir.cwd().deleteTree(core.io, rel) catch {};
        try std.Io.Dir.cwd().createDirPath(core.io, rel);
        var d = try std.Io.Dir.cwd().openDir(core.io, rel, .{});
        defer d.close(core.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try d.realPath(core.io, &buf);
        test_dir = try core.gpa.dupe(u8, buf[0..n]);
        test_env = try testing.environ.createMap(core.gpa);
        try test_env.put("STUDIO_USER_DATA", test_dir.?);
        core.env = &test_env;
    }
    // (another test fixed the data folder first: stay out of it)
    if (!std.mem.eql(u8, core.userData(), test_dir.?)) return error.SkipZigTest;
}

test "parseConn: quotes, doubled quotes, keys in lower case" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kv = try parseConn(a, "Server=tcp:db.local,1433; Initial Catalog = Shop ;User ID=sa;Password=\"p;w\"\"d\" ;Note='it''s'; Trusted_Connection=yes");
    try testing.expectEqual(6, kv.map.count());
    try testing.expectEqualStrings("tcp:db.local,1433", kv.map.get("server").?);
    try testing.expectEqualStrings("Shop", kv.map.get("initial catalog").?);
    try testing.expectEqualStrings("sa", kv.map.get("user id").?);
    try testing.expectEqualStrings("p;w\"d", kv.map.get("password").?);
    try testing.expectEqualStrings("it's", kv.map.get("note").?);
    try testing.expectEqualStrings("yes", kv.map.get("trusted_connection").?);
    try testing.expectEqualStrings("Shop", pick(kv, &.{ "database", "initial catalog" }));
    try testing.expectEqualStrings("", pick(kv, &.{"uid"}));

    // the last one wins, a pair without a key is dropped, an unclosed quote runs to the end
    const odd = try parseConn(a, "a=1;A=2;=3;b=;c=\"x;y");
    try testing.expectEqual(3, odd.map.count());
    try testing.expectEqualStrings("2", odd.map.get("a").?);
    try testing.expectEqualStrings("", odd.map.get("b").?);
    try testing.expectEqualStrings("x;y", odd.map.get("c").?);
    try testing.expectEqual(0, (try parseConn(a, "no pairs here")).map.count());

    try testing.expectEqualStrings("{\"server\":\".\",\"uid\":\"u\"}", try core.toJson(a, try parseConn(a, "Server=.;UID=u")));
}

test "buildConn quotes what a connection string would misread" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "Server=\"a;b\";User ID=\" u\";Password=\"p\"\"w\";TrustServerCertificate=True",
        try buildConn(a, .{ .server = "a;b", .database = "", .user = " u", .password = "p\"w" }),
    );
    try testing.expectEqualStrings(
        "Server=.;Database=d;Integrated Security=True;Encrypt=True",
        try buildConn(a, .{ .server = ".", .database = "d", .windowsAuth = true, .user = "ignored", .encrypt = true, .trustCert = false }),
    );
    try testing.expectEqualStrings("Server=s;User ID=;Password=;TrustServerCertificate=True", try buildConn(a, .{ .server = "s" }));
    // and back
    const kv = try parseConn(a, try buildConn(a, .{ .server = "srv\\SQL", .database = "My=Db", .user = "it's", .password = " x;\"y\" " }));
    try testing.expectEqualStrings("srv\\SQL", kv.map.get("server").?);
    try testing.expectEqualStrings("My=Db", kv.map.get("database").?);
    try testing.expectEqualStrings("it's", kv.map.get("user id").?);
    try testing.expectEqualStrings(" x;\"y\" ", kv.map.get("password").?);
}

test "ascii escapes everything outside ASCII" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("{\"sql\":\"a\\u00e9\\u1ebf\\ud83d\\ude00\\u007f~\"}", try ascii(a, "{\"sql\":\"aéế😀\x7f~\"}"));
    try testing.expectEqualStrings("x\\ufffdy", try ascii(a, "x\xffy"));
}

test "batches split on GO lines and remember where they start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try batches(a, "select 1\r\nGO\r\n\r\nselect 2\n go -- done\nselect 3\nGOTO x\ngo");
    try testing.expectEqual(3, b.len);
    try testing.expectEqualStrings("select 1", b[0].text);
    try testing.expectEqual(1, b[0].line);
    try testing.expectEqualStrings("\nselect 2", b[1].text);
    try testing.expectEqual(3, b[1].line);
    try testing.expectEqualStrings("select 3\nGOTO x", b[2].text);
    try testing.expectEqual(6, b[2].line);
    try testing.expectEqual(0, (try batches(a, "  \nGO\n\n")).len);

    try testing.expect(isGo("go"));
    try testing.expect(isGo("\tGo  "));
    try testing.expect(isGo("GO--x"));
    try testing.expect(!isGo("GO 5"));
    try testing.expect(!isGo("gone"));
    try testing.expect(!isGo("-- go"));
    try testing.expect(!isGo(""));

    try testing.expectEqualStrings("[a]]b]", try bracket(a, "a]b"));
}

test "shiftLines moves the server's line numbers to the editor's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "Line 6: bad\nx Line 3: no\nLine 14: y\nLine : z\nLine 5 w",
        try shiftLines(a, "Line 2: bad\nx Line 3: no\nLine 10: y\nLine : z\nLine 5 w", 4),
    );
    try testing.expectEqualStrings("Invalid object name 'x'.", try shiftLines(a, "Invalid object name 'x'.", 9));
}

test "looksSql" {
    try testing.expect(looksSql("Server=.;Database=x"));
    try testing.expect(looksSql("Data Source = a ; Integrated Security=true"));
    try testing.expect(looksSql("x=1;  ADDR=1;UID =2"));
    try testing.expect(looksSql("Address=a;Trusted_Connection=yes"));
    try testing.expect(!looksSql("Host=h;Database=d"));
    try testing.expect(!looksSql("Server=a;Port=1;uid=x"));
    try testing.expect(!looksSql("Server=a"));
    try testing.expect(!looksSql("myserver=1;database=2"));
    try testing.expect(!looksSql("Database=x"));
    try testing.expect(!looksSql(""));
}

test "comments and trailing commas come out of a JSON file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"u\":\"http://x//y\", \r\n \"a\":1  ,\"b\":2}\n/* open",
        try stripJsonComments(a, "{\"u\":\"http://x//y\", // c /* d */\r\n \"a\":1 /* b\n */ ,\"b\":2}\n/* open"),
    );
    try testing.expectEqualStrings("x  y// kept /", try stripJsonComments(a, "x /**/ y// kept /"));
    try testing.expectEqualStrings("x ", try stripJsonComments(a, "x //"));
    try testing.expectEqualStrings("[1, 2 ] {\"a\":[] \n}", try dropTrailingCommas(a, "[1, 2, ] {\"a\":[], \n}"));
}

test "jsonStrings lists every string under its key or index" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try jsonStrings(a, "{\"a\":\"x\",\"b\":[\"y\",{\"c\":\"z\"},1,\"w\",[\"q\"]],\"d\":{\"e\":\"v\\n\"},\"f\":null}");
    const want = [_]Pair{
        .{ .key = "a", .value = "x" },
        .{ .key = "0", .value = "y" },
        .{ .key = "c", .value = "z" },
        .{ .key = "3", .value = "w" },
        .{ .key = "0", .value = "q" },
        .{ .key = "e", .value = "v\n" },
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.key, g.key);
        try testing.expectEqualStrings(w.value, g.value);
    }
    const top = try jsonStrings(a, " \"Server=.\" ");
    try testing.expectEqual(1, top.len);
    try testing.expectEqualStrings("connection", top[0].key);
    try testing.expect(std.meta.isError(jsonStrings(a, "{\"a\":\"x\" \"b\":1}")));
    try testing.expect(std.meta.isError(jsonStrings(a, "{\"a\":\"x\"} x")));
    try testing.expect(std.meta.isError(jsonStrings(a, "{\"a\":")));
}

test "jsonPair reads pairs out of a file that is not JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "{ \"a\" : \"x\\\"y\", \"\": \"no\", \"b\":\"C:\\\\dir\" oops \"c\": \"open";
    const first = jsonPair(text, 0).?;
    try testing.expectEqualStrings("a", first.key);
    try testing.expectEqualStrings("x\"y", try unescape(a, first.value));
    const second = jsonPair(text, first.end).?;
    try testing.expectEqualStrings("b", second.key);
    try testing.expectEqualStrings("C:\\dir", try unescape(a, second.value));
    try testing.expect(jsonPair(text, second.end) == null);
}

test "connection strings in a .config file" {
    const text = "<connectionStrings>\n<Add Name = \"N\"\n connectionString=\"cs\" providerName=\"p\"/> <address x=\"1\"> <add> <add name=\"open";
    const first = addTag(text, 0).?;
    try testing.expect(std.mem.startsWith(u8, first, "<Add Name"));
    try testing.expect(std.mem.endsWith(u8, first, "\"p\"/>"));
    try testing.expectEqualStrings("N", xmlAttr(first, "name").?);
    try testing.expectEqualStrings("cs", xmlAttr(first, "connectionString").?);
    const second = addTag(text, std.mem.find(u8, text, first).? + first.len).?;
    try testing.expectEqualStrings("<add>", second);
    try testing.expect(xmlAttr(second, "name") == null);
    try testing.expect(addTag(text, std.mem.find(u8, text, "<add>").? + 5) == null);
    // the first `name=` counts, whatever it is the end of
    try testing.expectEqualStrings("p", xmlAttr("<add providerName=\"p\" name=\"n\">", "name").?);
}

test "envLine" {
    const text = "# comment\nA=1\n\n B = \"x y\"\r\nEMPTY=\nNEXT=2\nnot a pair\n  C.D_1=last";
    const want = [_][2][]const u8{ .{ "A", "1" }, .{ "B", "\"x y\"" }, .{ "EMPTY", "NEXT=2" }, .{ "C.D_1", "last" } };
    var pos: usize = 0;
    for (want) |w| {
        const got = envLine(text, pos).?;
        try testing.expectEqualStrings(w[0], got.key);
        try testing.expectEqualStrings(w[1], got.value);
        pos = got.end;
    }
    try testing.expect(envLine(text, pos) == null);
    try testing.expect(envLine("A=  \n", 0) == null);
}

test "file names that are scanned" {
    try testing.expect(isJsonName("appsettings.json"));
    try testing.expect(isJsonName("appsettings.development.json"));
    try testing.expect(isJsonName("secrets.json"));
    try testing.expect(isJsonName("launchsettings.json"));
    try testing.expect(!isJsonName("mysecrets.json"));
    try testing.expect(!isJsonName("package.json"));
    try testing.expect(!isJsonName("appsettings.json.bak"));
    try testing.expect(isEnvName(".env"));
    try testing.expect(isEnvName(".env.local"));
    try testing.expect(!isEnvName(".envrc"));
    try testing.expect(!isEnvName("x.env"));
}

test "writesTx" {
    try testing.expect(writesTx("COMMIT"));
    try testing.expect(writesTx("select 1; Commit tran"));
    try testing.expect(writesTx("save \t transaction x"));
    try testing.expect(writesTx("x\nSAVE TRAN s1"));
    try testing.expect(writesTx("[commit]"));
    try testing.expect(!writesTx("select committed from t"));
    try testing.expect(!writesTx("select uncommit from t"));
    try testing.expect(!writesTx("commit_x"));
    try testing.expect(!writesTx("savetran"));
    try testing.expect(!writesTx("save transactions"));
    try testing.expect(!writesTx("save the tran"));
    try testing.expect(!writesTx("rollback"));
}

test "JavaScript's view of a JSON value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a, "{\"s\":\"x\",\"e\":\"\",\"n\":0,\"i\":12,\"f\":1.5,\"b\":true,\"z\":null,\"l\":[1,\"a\"],\"t\":\" 42 \"}", .{});
    try testing.expectEqualStrings("x", try jsStr(a, field(v, "s")));
    try testing.expectEqualStrings("12", try jsStr(a, field(v, "i")));
    try testing.expectEqualStrings("1.5", try jsStr(a, field(v, "f")));
    try testing.expectEqualStrings("true", try jsStr(a, field(v, "b")));
    try testing.expectEqualStrings("null", try jsStr(a, field(v, "z")));
    try testing.expectEqualStrings("[1,\"a\"]", try jsStr(a, field(v, "l")));
    try testing.expectEqualStrings("undefined", try jsStr(a, field(v, "missing")));
    try testing.expectEqualStrings("", try strOrEmpty(a, field(v, "z")));
    try testing.expectEqualStrings("", try strOrEmpty(a, field(v, "missing")));
    try testing.expectEqualStrings("", try strOrEmpty(a, field(.null, "s")));
    for ([_][]const u8{ "s", "i", "f", "b", "l", "t" }) |k| try testing.expect(truthy(field(v, k)));
    for ([_][]const u8{ "e", "n", "z", "missing" }) |k| try testing.expect(!truthy(field(v, k)));
    try testing.expectEqual(42.0, jsNumber(field(v, "t")));
    try testing.expectEqual(0.0, jsNumber(field(v, "e")));
    try testing.expectEqual(0.0, jsNumber(field(v, "z")));
    try testing.expectEqual(1.0, jsNumber(field(v, "b")));
    try testing.expectEqual(1.5, jsNumber(field(v, "f")));
    try testing.expect(std.math.isNan(jsNumber(field(v, "s"))));
    try testing.expect(std.math.isNan(jsNumber(field(v, "l"))));
    try testing.expect(std.math.isNan(jsNumber(field(v, "missing"))));
}

test "a reply of the bridge becomes the page's DbQueryResult" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try core.fromJson(DbQueryResult, a, "{\"results\":[{\"columns\":[{\"name\":\"a\",\"type\":\"int\"}],\"rows\":[[1,null,\"x\",1.5,true]],\"truncated\":false}],\"messages\":[\"hi\"],\"ok\":true,\"id\":7,\"affected\":2,\"ms\":3}");
    try testing.expectEqualStrings(
        "{\"ok\":true,\"results\":[{\"columns\":[{\"name\":\"a\",\"type\":\"int\"}],\"rows\":[[1,null,\"x\",1.5,true]],\"truncated\":false}],\"messages\":[\"hi\"],\"affected\":2,\"ms\":3}",
        try core.toJson(a, r),
    );
    const failed = try core.fromJson(DbQueryResult, a, "{\"id\":1,\"error\":\"Line 1: no\"}");
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"Line 1: no\",\"results\":[],\"messages\":[],\"affected\":-1,\"ms\":0}", try core.toJson(a, failed));
}

test "result shapes leave out what is not there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conn: DbConnection = .{ .id = "1", .name = "n", .server = "s", .database = "d", .auth = "sql", .user = "u", .claudeReadOnly = true };
    try testing.expectEqualStrings("{\"id\":\"1\",\"name\":\"n\",\"server\":\"s\",\"database\":\"d\",\"auth\":\"sql\",\"user\":\"u\",\"claudeReadOnly\":true}", try core.toJson(a, conn));
    const found = [_]DbFound{ .{ .name = "n", .conn = "c", .file = "f" }, .{ .name = "n", .conn = "c", .file = "SSMS", .needsPassword = false } };
    try testing.expectEqualStrings("[{\"name\":\"n\",\"conn\":\"c\",\"file\":\"f\"},{\"name\":\"n\",\"conn\":\"c\",\"file\":\"SSMS\",\"needsPassword\":false}]", try core.toJson(a, @as([]const DbFound, &found)));
    const col: DbColumn = .{ .name = "id", .type = "int", .nullable = false, .identity = true, .pk = true };
    try testing.expectEqualStrings("{\"name\":\"id\",\"type\":\"int\",\"nullable\":false,\"identity\":true,\"pk\":true}", try core.toJson(a, col));
    try testing.expectEqualStrings("{\"schema\":\"dbo\",\"name\":\"t\",\"type\":\"U\"}", try core.toJson(a, DbObject{ .schema = "dbo", .name = "t", .type = "U" }));
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"e\"}", try core.toJson(a, TestResult{ .ok = false, .@"error" = "e" }));
    try testing.expectEqualStrings("{\"ok\":true,\"version\":\"v\"}", try core.toJson(a, TestResult{ .ok = true, .version = "v" }));
    const none: ?DbConnectionWithConn = null;
    try testing.expectEqualStrings("null", try core.toJson(a, none));
}

test "asTable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hé", cut("héllo", 2).?);
    try testing.expect(cut("hé", 2) == null);
    var long: std.ArrayList(u8) = .empty;
    for (0..CELL_MAX + 1) |_| try long.appendSlice(a, "é");
    const set: DbResultSet = .{
        .columns = &.{ .{ .name = "a", .type = "int" }, .{ .name = "", .type = "nvarchar" } },
        .rows = &.{
            &.{ .{ .integer = 1 }, .null },
            &.{ .{ .string = "x|y\r\nz\nw" }, .{ .string = long.items } },
        },
        .truncated = true,
    };
    const want = try std.fmt.allocPrint(a, "| a | (no name) |\n|---|---|\n| 1 | NULL |\n| x\\|y⏎z⏎w | {s}… |\n(2 rows, more rows not shown — narrow the query or raise max_rows)", .{long.items[0 .. 2 * CELL_MAX]});
    try testing.expectEqualStrings(want, try asTable(a, set));
    try testing.expectEqualStrings("|  |\n||\n| 5 |\n(1 row)", try asTable(a, .{ .rows = &.{&.{.{ .integer = 5 }}} }));
}

test "tools is the JSON of three tools" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a, try tools(a), .{});
    try testing.expectEqual(3, v.array.items.len);
    for (v.array.items, [_][]const u8{ "mssql_connections", "mssql_schema", "mssql_query" }) |tool, name| {
        try testing.expectEqualStrings(name, field(tool, "name").?.string);
        try testing.expect(field(tool, "description").?.string.len > 0);
        try testing.expectEqualStrings("object", field(field(tool, "inputSchema").?, "type").?.string);
    }
    try testing.expectEqualStrings("sql", field(field(v.array.items[2], "inputSchema").?, "required").?.array.items[1].string);
    try testing.expect(INSTRUCTIONS.len > 0);
}

test "saved connections: the file, the lists the page gets, what Claude sees" {
    try testProfile();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    try testing.expectEqual(0, (try listConnections(a)).len);
    try testing.expectEqualStrings(
        "No connections saved yet. Ask the user to add one in the Database tab of VIBE CODE.",
        try callTool(a, "mssql_connections", .null, &fail),
    );

    var list = try saveConnection(a, .{ .name = "  Kế Toán ", .conn = "Server=.;Database=Shop;User ID=sa;Password=x", .claudeReadOnly = true });
    try testing.expectEqual(1, list.len);
    const id = list[0].id;
    try testing.expectEqual(12, id.len);
    for (id) |ch| try testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    try testing.expectEqualStrings("Kế Toán", list[0].name);
    try testing.expectEqualStrings(".", list[0].server);
    try testing.expectEqualStrings("Shop", list[0].database);
    try testing.expectEqualStrings("sql", list[0].auth);
    try testing.expectEqualStrings("sa", list[0].user);
    try testing.expect(list[0].claudeReadOnly);
    try testing.expect(list[0].color == null);

    // the file: the keys the Rust and Electron builds wrote, no "color" while there is none
    const file = try std.json.parseFromSliceLeaky(Value, a, try core.readFileAlloc(a, try storeFile(a), 1 << 20), .{});
    const item = file.array.items[0];
    try testing.expectEqual(5, item.object.count());
    try testing.expectEqualStrings(id, field(item, "id").?.string);
    try testing.expectEqualStrings("Kế Toán", field(item, "name").?.string);
    try testing.expect(field(item, "claudeReadOnly").?.bool);
    try testing.expectEqual(@hasDecl(m.secure, "sealStr"), field(item, "enc").?.bool);
    if (!field(item, "enc").?.bool) try testing.expectEqualStrings("Server=.;Database=Shop;User ID=sa;Password=x", field(item, "conn").?.string);

    try testing.expectEqualStrings("- Kế Toán: . / Shop (login sa) [read-only]", try callTool(a, "mssql_connections", .null, &fail));
    try testing.expectEqualStrings("Server=.;Database=Shop;User ID=sa;Password=x", (try getConnection(a, id, &fail)).?.conn);
    try testing.expect((try getConnection(a, "nope", &fail)) == null);

    // by id, or by name in any case
    try testing.expectEqualStrings(id, (try findStored(a, id, &fail)).id);
    try testing.expectEqualStrings(id, (try findStored(a, " kế toán ", &fail)).id);
    if (core.is_windows) try testing.expectEqualStrings(id, (try findStored(a, "KẾ TOÁN", &fail)).id);

    // saving with its id replaces it
    list = try saveConnections(a, &.{
        .{ .id = id, .name = " ", .conn = "Data Source=srv;Integrated Security=SSPI;User ID=x", .color = "#f00" },
        .{ .id = "unknown", .name = "Second", .conn = "Server=b" },
    });
    try testing.expectEqual(2, list.len);
    try testing.expectEqualStrings(id, list[0].id);
    try testing.expectEqualStrings("SQL Server", list[0].name);
    try testing.expectEqualStrings("srv", list[0].server);
    try testing.expectEqualStrings("windows", list[0].auth);
    try testing.expectEqualStrings("", list[0].user);
    try testing.expect(!list[0].claudeReadOnly);
    try testing.expectEqualStrings("#f00", list[0].color.?);
    try testing.expect(!std.mem.eql(u8, list[1].id, "unknown"));
    try testing.expectEqualStrings("- SQL Server: srv (Windows auth)\n- Second: b (login )", try callTool(a, "mssql_connections", .null, &fail));

    try testing.expectError(error.Failed, findStored(a, "missing", &fail));
    try testing.expectEqualStrings("No saved connection \"missing\". Saved: SQL Server, Second", fail.msg);
    const args = try std.json.parseFromSliceLeaky(Value, a, "{\"connection\":\"second\"}", .{});
    try testing.expectError(error.Failed, callTool(a, "mssql_nope", args, &fail));
    try testing.expectEqualStrings("Unknown tool mssql_nope", fail.msg);

    list = try removeConnection(a, id);
    try testing.expectEqual(1, list.len);
    try testing.expectEqualStrings("Second", list[0].name);
    try testing.expectEqual(0, (try removeConnection(a, list[0].id)).len);
    try testing.expectEqualStrings("[]", try core.readFileAlloc(a, try storeFile(a), 1 << 20));
    try testing.expectError(error.Failed, findStored(a, "x", &fail));
    try testing.expectEqualStrings("No saved connection \"x\". Saved: (none)", fail.msg);
}

test "scanProjectSync" {
    try testProfile();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try core.dataPath(a, &.{"proj"});
    const sep = std.fs.path.sep_str;
    try core.writeFile(try std.fs.path.join(a, &.{ root, "Api", "appsettings.Development.json" }),
        \\{
        \\  // the local database
        \\  "ConnectionStrings": {
        \\    "Default": "Server=.;Database=Shop;Trusted_Connection=True", /* main */
        \\    "Site": "http://example.com/a",
        \\  },
        \\  "List": [1, "Data Source=a;Initial Catalog=b"],
        \\}
    );
    try core.writeFile(try std.fs.path.join(a, &.{ root, "Api", "secrets.json" }), "{ \"Broken\": \"Server=q;Database=C:\\\\w\" \"x\": }");
    try core.writeFile(try std.fs.path.join(a, &.{ root, "Web.config" }),
        \\<configuration><connectionStrings>
        \\  <add name="Old" connectionString="Server=x;User ID=u;Password=&quot;a;b&quot;&amp;" providerName="System.Data.SqlClient" />
        \\  <add name="Same" connectionString="Server=.;Database=Shop;Trusted_Connection=True" />
        \\</connectionStrings></configuration>
    );
    try core.writeFile(try std.fs.path.join(a, &.{ root, ".env" }), "DB = \"Server=y;Database=z\"\nPG=Host=h;Database=d\n");
    try core.writeFile(try std.fs.path.join(a, &.{ root, "node_modules", "x", "appsettings.json" }), "{\"a\":\"Server=skipped;Database=1\"}");
    try core.writeFile(try std.fs.path.join(a, &.{ root, ".hidden", "appsettings.json" }), "{\"a\":\"Server=hidden;Database=1\"}");
    try core.writeFile(try std.fs.path.join(a, &.{ root, "packages.config" }), "<add name=\"p\" connectionString=\"Server=pk;Database=1\"/>");
    try core.writeFile(try std.fs.path.join(a, &.{ root, "notes.json" }), "{\"a\":\"Server=notes;Database=1\"}");

    const found = try scanProjectSync(a, root);
    const want = [_][3][]const u8{
        .{ "Api · Default", "Server=.;Database=Shop;Trusted_Connection=True", "Api" ++ sep ++ "appsettings.Development.json" },
        .{ "Api · 1", "Data Source=a;Initial Catalog=b", "Api" ++ sep ++ "appsettings.Development.json" },
        .{ "Api · Broken", "Server=q;Database=C:\\w", "Api" ++ sep ++ "secrets.json" },
        .{ "proj · Old", "Server=x;User ID=u;Password=\"a;b\"&", "Web.config" },
        .{ "proj · DB", "Server=y;Database=z", ".env" },
    };
    for (want) |w| {
        const hit = for (found) |f| {
            if (std.mem.eql(u8, f.conn, w[1])) break f;
        } else return error.TestExpectedEqual;
        // ("Default" and "Same" are one connection: whichever file came first names it)
        if (!std.mem.eql(u8, w[0], "Api · Default")) {
            try testing.expectEqualStrings(w[0], hit.name);
            try testing.expectEqualStrings(w[2], hit.file);
        }
        try testing.expect(hit.needsPassword == null);
    }
    try testing.expectEqual(want.len, found.len);
    try testing.expectEqual(0, (try scanProjectSync(a, "")).len);
    try testing.expectEqual(0, (try scanProjectSync(a, try std.fs.path.join(a, &.{ root, "nowhere" }))).len);
}

/// Stops the bridge and waits for its threads to leave (they use `core.gpa`, which the next test
/// may replace).
fn testStopBridge() !void {
    current_lock.lock();
    const b = if (current) |x| x.retain() else null;
    current_lock.unlock();
    cancelAll();
    const x = b orelse return;
    defer x.release();
    var waited: usize = 0;
    while (x.refs.load(.acquire) > 1) : (waited += 1) {
        if (waited > 1000) return error.BridgeThreadsStillRunning;
        core.sleepMs(10);
    }
    try testing.expect(!x.alive());
}

test "the bridge starts, answers, and starts again after a cancel" {
    if (!core.is_windows) return error.SkipZigTest;
    try testProfile();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    // SqlClient refuses this connection string before it opens anything: no server is contacted
    const conn = "Not A Keyword=1";
    const r = runOn(a, conn, "select 1\nGO\nselect 2", .{ .database = "x" }, &fail) catch |e| {
        if (std.mem.find(u8, fail.text(e), "PowerShell") != null) return error.SkipZigTest;
        std.debug.print("bridge: {s}\n", .{fail.text(e)});
        return e;
    };
    try testing.expect(!r.ok);
    try testing.expect(std.ascii.findIgnoreCase(r.@"error".?, "not a keyword") != null);
    try testing.expectEqual(0, r.results.len);
    try testing.expectEqual(-1, r.affected);

    // two callers at once each get their own reply
    const Other = struct {
        fn run(out: *bool) void {
            var arena2: std.heap.ArenaAllocator = .init(core.gpa);
            defer arena2.deinit();
            var fail2: core.Fail = .{};
            const r2 = runOn(arena2.allocator(), "Another Bad Keyword=1", "select 1", .{}, &fail2) catch return;
            out.* = !r2.ok and std.ascii.findIgnoreCase(r2.@"error" orelse "", "another bad keyword") != null;
        }
    };
    var other_ok = false;
    const th = try std.Thread.spawn(.{}, Other.run, .{&other_ok});
    const again = try runOn(a, conn, "select 1", .{}, &fail);
    th.join();
    try testing.expect(other_ok);
    try testing.expect(std.ascii.findIgnoreCase(again.@"error".?, "not a keyword") != null);

    try testStopBridge();
    try testing.expect(current == null);

    // the next query starts a new runner
    const test_result = try testConnection(a, conn, &fail);
    try testing.expect(!test_result.ok);
    try testing.expect(test_result.@"error" != null);
    try testing.expect(current != null);
    try testStopBridge();
}
