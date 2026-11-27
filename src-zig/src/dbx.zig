//! dbX tab → DBX (github.com/t8y2/dbx, Apache-2.0): a database client for 100+ databases (SQL
//! Server, PostgreSQL, MySQL, SQLite, Oracle, MongoDB, Redis…), with schema browser, query editor,
//! data editing and ER diagrams. Its web build (`dbx-web.exe`, one file) is downloaded once, on
//! first use, pinned by version and SHA-256, and runs as a child process on 127.0.0.1. The tab
//! shows it in a native page (browser.zig), like a Web tab.
//!
//! Claude reaches the same connections through DBX's own MCP endpoint (`/mcp`): the app's
//! `vibe-dbx` server (mcp.zig) forwards to it, starting DBX first when it is not running.
//!
//! DBX is guarded by a login password and the MCP endpoint by a token, both random for each run
//! and known only to this process: other programs and web pages cannot use the connections.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const browser = @import("browser.zig");
const adblock = @import("adblock.zig");
const J = @import("browser_json.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;
const tr = settings.tr;

pub const commands = .{
    .{ "dbx_status", dbx_status },
    .{ "dbx_install", dbx_install },
    .{ "dbx_start", dbx_start },
    .{ "dbx_login", dbx_login },
};

const VERSION = "0.6.75";
const ZIP_URL = "https://github.com/t8y2/dbx/releases/download/v" ++ VERSION ++ "/dbx-web_" ++ VERSION ++ "_x86_64-browser-static.zip";
const ZIP_SIZE: u64 = 43_691_574;
const ZIP_SHA256 = "272020cf5bb32292e336fee0479b2f9dd1c566a5c6e0c476561f9f44866913fc";
const EXE = "dbx-web.exe";
/// Fixed, so DBX's own settings in the page (theme, layout, open tabs) stay with its origin.
const PORT: u16 = 47392;

fn exePath(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{ "dbx", VERSION, EXE });
}

fn installed(a: Allocator) bool {
    return core.isFile(exePath(a) catch return false);
}

// ---------------- commands ----------------

const Status = struct { installed: bool, version: []const u8, downloadSize: u64 };

fn dbx_status(c: *ipc.Call) !Status {
    return .{ .installed = installed(c.arena), .version = VERSION, .downloadSize = ZIP_SIZE };
}

var one_install: core.Mutex = .{};

/// Downloads and unpacks DBX (once; `dbx:progress` (bytes done, total) meanwhile).
fn dbx_install(c: *ipc.Call) !void {
    one_install.lock();
    defer one_install.unlock();
    if (installed(c.arena)) return;
    var fail: core.Fail = .{};
    install(c.arena, &fail) catch |e|
        return c.fail("{s}: {s}", .{ tr("could not download DBX", "không tải được DBX"), fail.text(e) });
}

const Started = struct {
    origin: []const u8,
    /// changes each time DBX (re)starts: the page has to log in again
    run: u64,
};

/// Starts DBX if it is not running; where it is served.
fn dbx_start(c: *ipc.Call) !Started {
    var fail: core.Fail = .{};
    const r = ensureRunning(c.arena, &fail) catch |e| return c.failMsg(fail.text(e));
    return .{ .origin = r.origin, .run = r.run };
}

/// Logs the native page `label` (already on DBX's origin) in, then sends it to DBX's start page.
/// The first time, DBX also takes the app's light or dark look (later it keeps its own setting).
fn dbx_login(c: *ipc.Call, args: struct { label: []const u8, dark: bool = true }) !void {
    const password = blk: {
        state_mutex.lock();
        defer state_mutex.unlock();
        if (state.child == null) return c.fail("DBX is not running", .{});
        break :blk try c.arena.dupe(u8, &state.password);
    };
    const js = try std.fmt.allocPrint(c.arena,
        \\(async () => {{
        \\  const s = await (await fetch('/api/auth/check', {{ cache: 'no-store' }})).json()
        \\  if (!s.authenticated) {{
        \\    const r = await fetch('/api/auth/login', {{ method: 'POST', headers: {{ 'Content-Type': 'application/json' }}, body: JSON.stringify({{ password: {s} }}) }})
        \\    if (!r.ok) return 'login failed: HTTP ' + r.status
        \\  }}
        \\  if (!localStorage.getItem('dbx-theme')) localStorage.setItem('dbx-theme', {s})
        \\  setTimeout(() => location.replace('/'), 0)
        \\  return 'ok'
        \\}})()
    , .{ try core.toJson(c.arena, password), if (args.dark) "'dark'" else "'light'" });
    var fail: core.Fail = .{};
    const v = browser.eval(c.arena, args.label, js, &fail) catch |e| return c.failMsg(fail.text(e));
    const said = J.str(v) orelse "ok";
    if (!std.mem.eql(u8, said, "ok")) return c.fail("{s}", .{said});
}

// ---------------- download ----------------

const Progress = struct {
    shown: u64 = 0,

    fn onBytes(ctx: ?*anyopaque, done: u64, _: ?u64) void {
        const p: *Progress = @ptrCast(@alignCast(ctx.?));
        if (done - p.shown >= ZIP_SIZE / 200 or done == ZIP_SIZE) {
            p.shown = done;
            core.emit("dbx:progress", .{ done, ZIP_SIZE });
        }
    }
};

fn install(a: Allocator, fail: *core.Fail) !void {
    const cwd = Dir.cwd();
    const root = try core.dataPath(a, &.{"dbx"});
    try core.makePath(root);
    const zip = try std.fs.path.join(a, &.{ root, VERSION ++ ".zip.part" });
    defer cwd.deleteFile(core.io, zip) catch {};
    {
        var file = try cwd.createFile(core.io, zip, .{});
        defer file.close(core.io);
        var file_buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(core.io, &file_buf);
        var hash_buf: [64 * 1024]u8 = undefined;
        var hashed = fw.interface.hashed(Sha256.init(.{}), &hash_buf);
        var p: Progress = .{};
        const head = http.stream(a, ZIP_URL, .{}, &hashed.writer, Progress.onBytes, &p) catch |e|
            return fail.set(a, "github.com: {s}", .{@errorName(e)});
        try fw.interface.flush();
        if (head.status < 200 or head.status >= 300) return fail.set(a, "github.com: HTTP {d}", .{head.status});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower), ZIP_SHA256))
            return fail.set(a, "{s}", .{tr("the download is damaged, try again", "bản tải về bị hỏng, hãy thử lại")});
    }
    const staging = try std.fs.path.join(a, &.{ root, VERSION ++ ".part" });
    cwd.deleteTree(core.io, staging) catch {};
    adblock.unzip(zip, staging) catch |e| {
        cwd.deleteTree(core.io, staging) catch {};
        return fail.set(a, "{s}: {s}", .{ tr("could not unpack DBX", "không giải nén được DBX"), @errorName(e) });
    };
    if (!core.isFile(try std.fs.path.join(a, &.{ staging, EXE }))) {
        cwd.deleteTree(core.io, staging) catch {};
        return fail.set(a, "{s}", .{tr("the download has no " ++ EXE, "bản tải về không có " ++ EXE)});
    }
    try Dir.rename(cwd, staging, cwd, try core.dataPath(a, &.{ "dbx", VERSION }), core.io);
    // older versions, and leftovers of an interrupted download (the data folder stays)
    var d = try cwd.openDir(core.io, root, .{ .iterate = true });
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, VERSION) or std.mem.eql(u8, e.name, "data")) continue;
        d.deleteTree(core.io, e.name) catch {};
    }
}

// ---------------- the DBX process ----------------

const State = struct {
    child: ?std.process.Child = null,
    port: u16 = 0,
    password: [32]u8 = undefined,
    token: [48]u8 = undefined,
    run: u64 = 0,
};

/// Held while DBX is checked or (re)started; `state_mutex` guards `state` itself.
var start_mutex: core.Mutex = .{};
var state_mutex: core.Mutex = .{};
var state: State = .{};

const Running = struct { origin: []const u8, run: u64 };

fn originOf(a: Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
}

/// DBX answers on its port (and is the one this process started).
fn answers(a: Allocator, port: u16) bool {
    const r = local(a, std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api/auth/check", .{port}) catch return false, null, &.{}) catch return false;
    return r.status == 200 and std.mem.indexOf(u8, r.body, "\"authenticated\"") != null;
}

const Reply = struct { status: u16, body: []u8 };

/// One request to DBX, on a connection of its own: through the shared client's pool, a connection
/// to a DBX that had since stopped kept every later request to the new one failing.
fn local(a: Allocator, url: []const u8, payload: ?[]const u8, headers: []const http.Header) !Reply {
    var client: std.http.Client = .{ .allocator = a, .io = core.io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    const r = try client.fetch(.{
        .location = .{ .url = url },
        .payload = payload,
        .keep_alive = false,
        .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        .extra_headers = headers,
        .response_writer = &aw.writer,
    });
    return .{ .status = @intFromEnum(r.status), .body = aw.written() };
}

/// The running DBX, started (and its old connections brought over, the first time) if need be.
fn ensureRunning(a: Allocator, fail: *core.Fail) !Running {
    start_mutex.lock();
    defer start_mutex.unlock();
    {
        state_mutex.lock();
        const port = state.port;
        const run = state.run;
        const alive = state.child != null;
        state_mutex.unlock();
        if (alive and answers(a, port)) return .{ .origin = try originOf(a, port), .run = run };
    }
    if (!core.is_windows) return fail.set(a, "DBX needs Windows for now.", .{});
    if (!installed(a)) return fail.set(a, "{s}", .{tr(
        "DBX is not set up yet: open the dbX tab in VIBE CODE (it downloads DBX once).",
        "DBX chưa được cài: mở tab dbX trong VIBE CODE (DBX được tải về một lần).",
    )});
    stop();
    try spawnDbx(a, fail);
    state_mutex.lock();
    const r: Running = .{ .origin = try originOf(a, state.port), .run = state.run };
    state_mutex.unlock();
    core.spawn(migrateOld, .{});
    return r;
}

extern "iphlpapi" fn GetExtendedTcpTable(table: ?*anyopaque, size: *u32, order: c_int, af: u32, class: c_int, reserved: u32) callconv(.winapi) u32;

/// Some program already listens on this TCP port. std binds a listening socket as shared on
/// Windows (as with SO_REUSEADDR), so binding a taken port succeeds and the two programs then
/// answer each other's connections: it has to be looked up instead.
fn portTaken(port: u16) bool {
    // MIB_TCPTABLE of the IPv4 listeners: a count, then rows of 5 DWORDs (state, local address,
    // local port in network byte order, remote address, remote port)
    var table: [64 * 1024]u8 align(4) = undefined;
    var size: u32 = table.len;
    const af_inet = 2;
    const tcp_table_basic_listener = 0;
    if (GetExtendedTcpTable(&table, &size, 0, af_inet, tcp_table_basic_listener, 0) != 0) return false;
    const rows = std.mem.readInt(u32, table[0..4], .little);
    for (0..rows) |i| {
        if (std.mem.readInt(u16, table[4 + i * 20 + 8 ..][0..2], .big) == port) return true;
    }
    return false;
}

/// A free port on 127.0.0.1 when `PORT` is taken.
fn pickPort() !u16 {
    if (!portTaken(PORT)) return PORT;
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var l = try address.listen(core.io, .{});
    defer l.deinit(core.io);
    return l.socket.address.getPort();
}

fn spawnDbx(a: Allocator, fail: *core.Fail) !void {
    var secret: [16]u8 = undefined;
    core.io.random(&secret);
    const password = std.fmt.bytesToHex(secret, .lower);
    var tok: [24]u8 = undefined;
    core.io.random(&tok);
    const token = std.fmt.bytesToHex(tok, .lower);
    const port = try pickPort();
    const host = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port});

    const data = try core.dataPath(a, &.{ "dbx", "data" });
    try core.makePath(data);
    var env = try core.cleanEnvShared().clone(a);
    try env.put("DBX_BIND_ADDR", "127.0.0.1");
    try env.put("DBX_PORT", try std.fmt.allocPrint(a, "{d}", .{port}));
    try env.put("DBX_DATA_DIR", data);
    try env.put("DBX_PASSWORD", &password);
    try env.put("DBX_WEB_MCP_TOKEN", &token);
    try env.put("DBX_WEB_MCP_ALLOWED_HOSTS", host);

    // its output, for when it will not start
    const log_path = try core.dataPath(a, &.{ "dbx", "dbx-web.log" });
    var log = try Dir.cwd().createFile(core.io, log_path, .{});
    defer log.close(core.io);
    const exe = try exePath(a);
    var child = std.process.spawn(core.io, .{
        .argv = &.{exe},
        .cwd = .{ .path = std.fs.path.dirname(exe).? },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .create_no_window = true,
    }) catch |e| return fail.set(a, "{s}: {s}", .{ tr("could not start DBX", "không chạy được DBX"), @errorName(e) });
    killWithApp(child.id.?);

    // up within a minute (the first start sets up its data folder)
    const t0 = core.monoMs();
    while (!answers(a, port)) {
        if (core.monoMs() - t0 > 60_000) {
            child.kill(core.io);
            const out = core.readFileAlloc(a, log_path, 1 << 20) catch "";
            const last = lastLine(out);
            return fail.set(a, "{s}{s}{s}", .{ tr("DBX did not start", "DBX không khởi động được"), if (last.len > 0) ": " else "", last });
        }
        core.sleepMs(200);
    }
    state_mutex.lock();
    defer state_mutex.unlock();
    state.child = child;
    state.port = port;
    state.password = password;
    state.token = token;
    state.run += 1;
}

fn lastLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, text, &std.ascii.whitespace), '\n');
    return std.mem.trim(u8, it.first(), &std.ascii.whitespace);
}

/// A job that ends with this process: DBX never outlives the app, even when the app crashes.
var job: ?*anyopaque = null;

fn killWithApp(process: std.process.Child.Id) void {
    if (!core.is_windows) return;
    const win = core.host.win.c;
    if (job == null) {
        const j = win.CreateJobObjectW(null, null) orelse return;
        var info = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (win.SetInformationJobObject(j, win.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info))) == 0) {
            _ = win.CloseHandle(j);
            return;
        }
        job = j;
    }
    _ = win.AssignProcessToJobObject(job, @ptrCast(process));
}

fn stop() void {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (state.child) |*c| c.kill(core.io);
    state.child = null;
}

pub fn deinit() void {
    stop();
}

// ---------------- connections saved by the old Database tab ----------------

/// The SQL Server connections of the Database tab this tab replaces (`db-connections.json`, their
/// connection strings sealed with DPAPI) are added to DBX once, through its MCP tools.
fn migrateOld() !void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = try core.dataPath(a, &.{ "dbx", "imported-db-connections" });
    if (core.exists(marker)) return;
    const file = try core.dataPath(a, &.{"db-connections.json"});
    const bytes = core.readFileAlloc(a, file, 64 << 20) catch return core.writeFile(marker, "");
    const Old = struct { name: []const u8 = "", conn: []const u8 = "", enc: bool = false };
    const list = core.fromJson([]const Old, a, bytes) catch return core.writeFile(marker, "");
    var done: usize = 0;
    for (list) |o| {
        const conn = if (!o.enc) o.conn else if (@hasDecl(m.secure, "openStr")) (m.secure.openStr(a, o.conn) catch |e| {
            std.log.warn("dbx: old connection \"{s}\": {s}", .{ o.name, m.secure.errorText(e) });
            continue;
        }) else continue;
        const args = connArgs(a, o.name, conn) catch continue;
        var fail: core.Fail = .{};
        const reply = mcpRequest(a, "tools/call", try core.toJson(a, .{ .name = "dbx_add_connection", .arguments = args }), &fail) catch |e| {
            std.log.warn("dbx: old connection \"{s}\": {s}", .{ o.name, fail.text(e) });
            continue;
        };
        if (J.get(J.parse(a, reply), "isError")) |e| if (e == .bool and e.bool) {
            std.log.warn("dbx: old connection \"{s}\": {s}", .{ o.name, reply });
            continue;
        };
        done += 1;
    }
    std.log.info("dbx: {d} of {d} old connections added", .{ done, list.len });
    // none could be added (DBX refused, the key to unseal them is missing…): tried again next start
    if (done == 0 and list.len > 0) return;
    try core.writeFile(marker, try std.fmt.allocPrint(a, "{d}/{d}\n", .{ done, list.len }));
    // the old tab's query runner, written out at its first use
    Dir.cwd().deleteTree(core.io, core.dataPath(a, &.{"mssql"}) catch return) catch {};
}

const AddArgs = struct {
    name: []const u8,
    db_type: []const u8 = "sqlserver",
    host: []const u8,
    port: u16 = 1433,
    username: []const u8,
    password: []const u8,
    database: ?[]const u8 = null,
    ssl: bool,
};

/// A SQL Server connection string → `dbx_add_connection` arguments.
fn connArgs(a: Allocator, name: []const u8, conn: []const u8) !AddArgs {
    const kv = try parseConn(a, conn);
    var server = pick(kv, &.{ "server", "data source", "address", "addr", "network address" });
    if (std.ascii.startsWithIgnoreCase(server, "tcp:")) server = server[4..];
    var port: u16 = 1433;
    if (std.mem.findScalar(u8, server, ',')) |i| {
        port = std.fmt.parseInt(u16, std.mem.trim(u8, server[i + 1 ..], " "), 10) catch 1433;
        server = server[0..i];
    }
    if (server.len == 0) return error.NoServer;
    const database = pick(kv, &.{ "database", "initial catalog" });
    const encrypt = pick(kv, &.{"encrypt"});
    return .{
        .name = if (name.len > 0) name else server,
        .host = server,
        .port = port,
        .username = pick(kv, &.{ "user id", "uid", "user" }),
        .password = pick(kv, &.{ "password", "pwd" }),
        .database = if (database.len > 0) database else null,
        .ssl = std.ascii.eqlIgnoreCase(encrypt, "true") or std.ascii.eqlIgnoreCase(encrypt, "yes") or std.ascii.eqlIgnoreCase(encrypt, "strict"),
    };
}

const ConnMap = std.StringArrayHashMapUnmanaged([]const u8);

/// Connection string → key/value pairs (keys lower-cased), honouring "quoted" and 'quoted' values.
fn parseConn(a: Allocator, conn: []const u8) !ConnMap {
    const ws = &std.ascii.whitespace;
    var out: ConnMap = .empty;
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
        if (key.len > 0) try out.put(a, key, val);
    }
    return out;
}

fn pick(kv: ConnMap, keys: []const []const u8) []const u8 {
    for (keys) |k| if (kv.get(k)) |v| return v;
    return "";
}

// ---------------- for Claude (mcp.zig) ----------------

pub const INSTRUCTIONS: []const u8 = "Query the databases the user connected in DBX (the dbX tab of VIBE CODE): SQL Server, PostgreSQL, MySQL, SQLite, Oracle, MongoDB, Redis and more. " ++
    "Start with dbx_list_connections, explore with dbx_list_databases / dbx_list_tables / dbx_describe_table (or dbx_get_schema_context), then dbx_execute_query. " ++
    "Use the SQL dialect of the connection's database type. Prefer small, targeted queries. What you may change is set by the user in DBX's Settings → MCP.";

/// One JSON-RPC call to DBX's MCP endpoint (DBX started if need be); the JSON text of its result.
fn mcpRequest(a: Allocator, method: []const u8, params: []const u8, fail: *core.Fail) ![]const u8 {
    const r = try ensureRunning(a, fail);
    const bearer = blk: {
        state_mutex.lock();
        defer state_mutex.unlock();
        break :blk try std.fmt.allocPrint(a, "Bearer {s}", .{&state.token});
    };
    const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":{s},\"params\":{s}}}", .{ try core.toJson(a, method), params });
    const res = local(a, try std.mem.concat(a, u8, &.{ r.origin, "/mcp" }), body, &.{
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "Accept", .value = "application/json, text/event-stream" },
    }) catch |e| return fail.set(a, "DBX: {s}", .{@errorName(e)});
    if (res.status != 200) return fail.set(a, "DBX: HTTP {d}", .{res.status});
    const msg = J.parse(a, sseData(res.body)) orelse return fail.set(a, "DBX gave an unreadable answer", .{});
    if (J.get(msg, "error")) |e| return fail.set(a, "DBX: {s}", .{J.str(J.get(e, "message")) orelse "error"});
    return core.toJson(a, J.get(msg, "result") orelse return fail.set(a, "DBX gave no result", .{}));
}

/// The JSON of a reply that may come as one Server-Sent Event (`data: {…}`) or as plain JSON.
fn sseData(body: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "data:")) return std.mem.trim(u8, line["data:".len..], " ");
    }
    return body;
}

/// DBX's tools, as the JSON text of an MCP `tools` array. Every chat asks for them as it starts:
/// while DBX is not running they come from the last list it gave, so it starts only when a tool
/// is actually used.
pub fn tools(a: Allocator, fail: *core.Fail) ![]const u8 {
    const cache = try core.dataPath(a, &.{ "dbx", "tools.json" });
    state_mutex.lock();
    const running = state.child != null;
    state_mutex.unlock();
    if (!running) if (core.readFileAlloc(a, cache, 4 << 20)) |saved| return saved else |_| {};
    const result = try mcpRequest(a, "tools/list", "{}", fail);
    const list = try core.toJson(a, J.get(J.parse(a, result), "tools") orelse return "[]");
    // (with no connection yet DBX lists only the tools that add one: not worth keeping)
    if (std.mem.indexOf(u8, list, "\"dbx_execute_query\"") != null) core.writeAtomic(cache, list) catch {};
    return list;
}

/// Runs one of DBX's tools; the JSON text of the MCP result (content, isError…).
pub fn callTool(a: Allocator, params: std.json.Value, fail: *core.Fail) ![]const u8 {
    return mcpRequest(a, "tools/call", try core.toJson(a, params), fail);
}

// ---------------- tests ----------------

const testing = std.testing;

test "connArgs reads the old SQL Server connection strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try connArgs(a, "TMS", "Server=tcp:db.local,1434;Initial Catalog=Shop;User ID=sa;Password=\"p;w\"\"d\";Encrypt=True;TrustServerCertificate=True");
    try testing.expectEqualStrings("TMS", x.name);
    try testing.expectEqualStrings("db.local", x.host);
    try testing.expectEqual(1434, x.port);
    try testing.expectEqualStrings("Shop", x.database.?);
    try testing.expectEqualStrings("sa", x.username);
    try testing.expectEqualStrings("p;w\"d", x.password);
    try testing.expect(x.ssl);

    const y = try connArgs(a, "", "Data Source=.\\SQLEXPRESS;Integrated Security=True");
    try testing.expectEqualStrings(".\\SQLEXPRESS", y.name);
    try testing.expectEqual(1433, y.port);
    try testing.expect(y.database == null);
    try testing.expectEqualStrings("", y.username);
    try testing.expect(!y.ssl);

    try testing.expectError(error.NoServer, connArgs(a, "x", "Database=d"));
}

test "sseData takes the event's JSON, or the body as it is" {
    try testing.expectEqualStrings("{\"a\":1}", sseData("data: {\"a\":1}\r\n\r\n"));
    try testing.expectEqualStrings("{\"a\":1}", sseData("event: message\ndata:{\"a\":1}\n\n"));
    try testing.expectEqualStrings("{\"b\":2}", sseData("{\"b\":2}"));
}

test "lastLine" {
    try testing.expectEqualStrings("Failed to start", lastLine("a\nb\r\nFailed to start\r\n\n"));
    try testing.expectEqualStrings("", lastLine(""));
}
