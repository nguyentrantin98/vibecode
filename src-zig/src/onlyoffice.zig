//! Office tab → ONLYOFFICE: the full ONLYOFFICE editors (Word, Excel, PowerPoint — docx, xlsx, pptx,
//! the old doc/xls/ppt and OpenDocument), running inside the app with nothing installed on the machine.
//!
//! The editor is the open-source build of github.com/ranuts/document (AGPL-3.0): ONLYOFFICE's web
//! editors with its x2t file converter compiled to WebAssembly, so files are opened and saved in the
//! page, without a document server. It is downloaded once, on first use, from the project's published
//! container image (the one layer holding the built site), pinned by digest, and checked against it.
//!
//! The files are served from 127.0.0.1 to an iframe of the Office tab, which drives the editor with
//! the project's embed API (postMessage) and reads / writes the files through `office_*` commands.
//! Every response forbids the page any connection off this machine: no analytics, no AI services,
//! no downloads, no update checks — documents never leave the computer.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const net = std.Io.net;
const flate = std.compress.flate;
const Sha256 = std.crypto.hash.sha2.Sha256;
const tr = settings.tr;

pub const commands = .{
    .{ "onlyoffice_origin", onlyoffice_origin },
    .{ "onlyoffice_install", onlyoffice_install },
    .{ "onlyoffice_download_size", onlyoffice_download_size },
};

/// ghcr.io/ranuts/document:0.0.9 (linux/amd64): its third layer is the site, under `public/`.
const IMAGE = "ranuts/document";
const VERSION = "0.0.9";
const LAYER = "sha256:0962b06bf39191ddc50a09e40cff78573befe6e6b0ec5d6f797df0bfdf824958";
const LAYER_SIZE: u64 = 217_175_624;
/// Fixed so the editor's own settings (language, zoom, theme) stay with its origin between launches.
const PORT: u16 = 47391;
/// Sent with every file: the page may connect to this server and nothing else.
const CSP = "connect-src 'self' blob: data:";

fn root(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"onlyoffice"});
}

fn site(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{ "onlyoffice", VERSION });
}

fn installed(a: Allocator) bool {
    return core.isFile(core.dataPath(a, &.{ "onlyoffice", VERSION, "editor.html" }) catch return false);
}

// ---------------- commands ----------------

/// Where the editor is served (`http://127.0.0.1:<port>`), or null while it is not downloaded yet.
fn onlyoffice_origin(c: *ipc.Call) !?[]u8 {
    if (!installed(c.arena)) return null;
    return try origin(c.arena);
}

var one_at_a_time: core.Mutex = .{};

/// Downloads and unpacks the editor (once; `onlyoffice:progress` (bytes done, total) meanwhile)
/// and returns where it is served.
fn onlyoffice_install(c: *ipc.Call) ![]u8 {
    one_at_a_time.lock();
    defer one_at_a_time.unlock();
    if (!installed(c.arena)) {
        var fail: core.Fail = .{};
        install(c.arena, &fail) catch |e|
            return c.fail("{s}: {s}", .{ tr("could not download ONLYOFFICE", "không tải được ONLYOFFICE"), fail.text(e) });
    }
    return origin(c.arena);
}

/// Size of the one-time download, for the page to say before it starts.
fn onlyoffice_download_size(_: *ipc.Call) !u64 {
    return LAYER_SIZE;
}

// ---------------- download ----------------

fn emitProgress(done: u64) void {
    core.emit("onlyoffice:progress", .{ done, LAYER_SIZE });
}

fn install(a: Allocator, fail: *core.Fail) !void {
    const cwd = Dir.cwd();
    const root_dir = try root(a);
    try core.makePath(root_dir);
    const tgz = try std.fs.path.join(a, &.{ root_dir, VERSION ++ ".tgz.part" });
    try download(a, tgz, emitProgress, fail);

    const staging = try std.fs.path.join(a, &.{ root_dir, VERSION ++ ".part" });
    cwd.deleteTree(core.io, staging) catch {};
    const unpacked = if (unpack(a, tgz, staging, fail)) prepare(a, staging, fail) else |e| e;
    cwd.deleteFile(core.io, tgz) catch {};
    unpacked catch |e| {
        cwd.deleteTree(core.io, staging) catch {};
        return e;
    };
    try Dir.rename(cwd, staging, cwd, try site(a), core.io);
    // other versions, and leftovers of an interrupted download
    var d = try cwd.openDir(core.io, root_dir, .{ .iterate = true });
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        if (!std.mem.eql(u8, e.name, VERSION)) d.deleteTree(core.io, e.name) catch {};
    }
}

/// Bytes of the layer received so far, and at which count `progress` was last told.
const Download = struct {
    done: u64 = 0,
    shown: u64 = 0,
    progress: *const fn (u64) void,

    fn onBytes(ctx: ?*anyopaque, done: u64, _: ?u64) void {
        const d: *Download = @ptrCast(@alignCast(ctx.?));
        d.done = done;
        if (done - d.shown >= LAYER_SIZE / 200 or done == LAYER_SIZE) {
            d.shown = done;
            d.progress(done);
        }
    }
};

/// The image layer into `to`, checked against its digest; `progress` gets the bytes done so far.
fn download(a: Allocator, to: []const u8, progress: *const fn (u64) void, fail: *core.Fail) !void {
    // anonymous pull token of a public package
    const auth = try http.get(a, "https://ghcr.io/token?scope=repository:" ++ IMAGE ++ ":pull", &.{});
    if (!auth.ok()) return fail.set(a, "ghcr.io: HTTP {d}", .{auth.status});
    const token = (core.fromJson(struct { token: ?[]const u8 = null }, a, auth.body) catch return fail.set(a, "ghcr.io gave no token", .{})).token orelse
        return fail.set(a, "ghcr.io gave no token", .{});
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    var d: Download = .{ .progress = progress };
    const got = try fetch(a, "https://ghcr.io/v2/" ++ IMAGE ++ "/blobs/" ++ LAYER, &.{.{ .name = "Authorization", .value = bearer }}, to, &d);
    if (got.status < 200 or got.status >= 300) {
        Dir.cwd().deleteFile(core.io, to) catch {};
        return fail.set(a, "ghcr.io: HTTP {d}", .{got.status});
    }
    if (d.done != LAYER_SIZE or !std.mem.eql(u8, &std.fmt.bytesToHex(got.sha256, .lower), LAYER["sha256:".len..])) {
        Dir.cwd().deleteFile(core.io, to) catch {};
        if (settings.vi()) return fail.set(a, "bản tải về bị hỏng ({d} / {d} byte), hãy thử lại", .{ d.done, LAYER_SIZE });
        return fail.set(a, "the download is damaged ({d} / {d} bytes), try again", .{ d.done, LAYER_SIZE });
    }
}

const Fetched = struct { status: u16, sha256: [Sha256.digest_length]u8 };

/// The body of `url` into the file `to`, hashed on its way there.
fn fetch(a: Allocator, url: []const u8, headers: []const http.Header, to: []const u8, d: *Download) !Fetched {
    var part = try Dir.cwd().createFile(core.io, to, .{});
    defer part.close(core.io);
    var file_buf: [64 * 1024]u8 = undefined;
    var fw = part.writer(core.io, &file_buf);
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = fw.interface.hashed(Sha256.init(.{}), &hash_buf);
    const head = try http.stream(a, url, .{ .headers = headers }, &hashed.writer, Download.onBytes, d);
    try fw.interface.flush();
    try part.sync(core.io);
    return .{ .status = head.status, .sha256 = hashed.hasher.finalResult() };
}

/// `path` (of an archive entry, of a URL) as a relative file path, when it is made of plain
/// names only; null with anything that could lead elsewhere: "..", a leading ".", a drive, a
/// backslash.
fn plainPath(buf: []u8, path: []const u8) ?[]const u8 {
    var n: usize = 0;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| : (first = false) {
        if (std.mem.eql(u8, part, ".")) {
            if (first) return null;
            continue;
        }
        if (std.mem.eql(u8, part, "..")) return null;
        if (core.is_windows and std.mem.findAny(u8, part, "\\:") != null) return null;
        if (n + 1 + part.len > buf.len) return null;
        if (n > 0) {
            buf[n] = std.fs.path.sep;
            n += 1;
        }
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    return buf[0..n];
}

/// The layer's `public/` folder into `to` (regular files and folders only, nothing outside `to`).
fn unpack(a: Allocator, tgz: []const u8, to: []const u8, fail: *core.Fail) !void {
    const cwd = Dir.cwd();
    var layer = try cwd.openFile(core.io, tgz, .{});
    defer layer.close(core.io);
    var file_buf: [64 * 1024]u8 = undefined;
    var fr = layer.reader(core.io, &file_buf);
    var gz: flate.Decompress = .init(&fr.interface, .gzip, try a.alloc(u8, flate.max_window_len));
    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    // without this, an entry that is not a file, folder or symlink (a hard link, a device) is an error
    var skipped: std.tar.Diagnostics = .{ .allocator = a };
    var archive: std.tar.Iterator = .init(&gz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf, .diagnostics = &skipped });
    try core.makePath(to);
    var rel_buf: [Dir.max_path_bytes]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    while (try archive.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "public/")) continue;
        const rel = plainPath(&rel_buf, entry.name["public/".len..]) orelse continue;
        if (rel.len == 0) continue;
        const dest = try std.fs.path.join(a, &.{ to, rel });
        defer a.free(dest);
        switch (entry.kind) {
            .directory => try core.makePath(dest),
            .file => {
                if (std.fs.path.dirname(dest)) |parent| try core.makePath(parent);
                var f = try cwd.createFile(core.io, dest, .{});
                defer f.close(core.io);
                var fw = f.writer(core.io, &out_buf);
                try archive.streamRemaining(entry, &fw.interface);
                try fw.interface.flush();
            },
            .sym_link => {},
        }
    }
    if (!core.isFile(try std.fs.path.join(a, &.{ to, "editor.html" })))
        return fail.set(a, "{s}", .{tr("the download has no editor.html", "bản tải về không có editor.html")});
}

/// What the build needs to run here, done once after unpacking:
/// - x2t (the file converter) is gzip in this image, meant to be sent with `Content-Encoding: gzip`;
///   it is stored as the plain module instead, so the server sends files as they are;
/// - the Vietnamese editor texts lack keys English has, and some of those are read without a
///   fallback (a new slide's "Click to add title" crashes the presentation editor): they get the
///   English text, as the project does for the languages its site offers.
fn prepare(a: Allocator, dir: []const u8, fail: *core.Fail) !void {
    const cwd = Dir.cwd();
    const x2t = try std.fs.path.join(a, &.{ dir, "sdkjs", "common", "wasm", "x2t", "x2t.wasm.br" });
    const bytes = cwd.readFileAlloc(core.io, x2t, a, .unlimited) catch |e|
        return fail.set(a, "{s}: {s}", .{ tr("the x2t converter is missing", "thiếu bộ chuyển đổi x2t"), @errorName(e) });
    if (std.mem.startsWith(u8, bytes, &.{ 0x1f, 0x8b })) {
        var in: std.Io.Reader = .fixed(bytes);
        var gz: flate.Decompress = .init(&in, .gzip, try a.alloc(u8, flate.max_window_len));
        try core.writeFile(x2t, try gz.reader.allocRemaining(a, .unlimited));
    } else if (!std.mem.startsWith(u8, bytes, "\x00asm")) {
        return fail.set(a, "{s}", .{tr("the x2t converter has the wrong format", "bộ chuyển đổi x2t không đúng định dạng")});
    }
    const apps = try std.fs.path.join(a, &.{ dir, "web-apps", "apps" });
    var d = try cwd.openDir(core.io, apps, .{ .iterate = true });
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |app| {
        const en = try std.fs.path.join(a, &.{ apps, app.name, "main", "locale", "en.json" });
        const vi = try std.fs.path.join(a, &.{ apps, app.name, "main", "locale", "vi.json" });
        if (core.isFile(vi) and core.isFile(en)) try fillLocale(a, en, vi);
    }
}

fn fillLocale(a: Allocator, en_file: []const u8, target: []const u8) !void {
    const en = try std.json.parseFromSliceLeaky(std.json.Value, a, try core.readFileAlloc(a, en_file, 256 << 20), .{});
    var t = try std.json.parseFromSliceLeaky(std.json.Value, a, try core.readFileAlloc(a, target, 256 << 20), .{});
    if (en != .object or t != .object) return error.UnexpectedToken;
    const before = t.object.count();
    var it = en.object.iterator();
    while (it.next()) |e| {
        const slot = try t.object.getOrPut(a, e.key_ptr.*);
        if (!slot.found_existing) slot.value_ptr.* = e.value_ptr.*;
    }
    if (t.object.count() != before) try core.writeFile(target, try core.toJson(a, t));
}

// ---------------- server ----------------

var server_mutex: core.Mutex = .{};
var server_port: ?u16 = null;

fn origin(a: Allocator) ![]u8 {
    server_mutex.lock();
    defer server_mutex.unlock();
    if (server_port == null) server_port = try serve(try site(core.gpa));
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server_port.?});
}

fn listen() !net.Server {
    var address: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    if (!(core.is_windows and portTaken(PORT))) {
        if (address.listen(core.io, .{})) |listener| return listener else |_| {}
    }
    address.setPort(0);
    return address.listen(core.io, .{});
}

extern "iphlpapi" fn GetExtendedTcpTable(table: ?*anyopaque, size: *u32, order: c_int, af: u32, class: c_int, reserved: u32) callconv(.winapi) u32;

/// Some program already listens on this TCP port. std binds a listening socket as shared on
/// Windows (as with SO_REUSEADDR), so binding a taken port succeeds and the two programs then
/// answer each other's connections: it has to be looked up instead.
pub fn portTaken(port: u16) bool {
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

/// Serves `dir` (which must stay allocated) for as long as the app runs; returns the port.
fn serve(dir: []const u8) !u16 {
    const listener = try listen();
    const port = listener.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, acceptLoop, .{ listener, dir, port });
    thread.detach();
    return port;
}

fn acceptLoop(listener: net.Server, dir: []const u8, port: u16) void {
    var l = listener;
    while (true) {
        const stream = l.accept(core.io) catch {
            core.sleepMs(1000);
            continue;
        };
        core.spawn(connection, .{ stream, dir, port });
    }
}

/// One browser connection: requests are answered in turn until it closes.
fn connection(stream: net.Stream, dir: []const u8, port: u16) void {
    defer stream.close(core.io);
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var in = stream.reader(core.io, &in_buf);
    var out = stream.writer(core.io, &out_buf);
    var server: std.http.Server = .init(&in.interface, &out.interface);
    var host_buf: [32]u8 = undefined;
    const host = std.fmt.bufPrint(&host_buf, "127.0.0.1:{d}", .{port}) catch unreachable;
    while (server.reader.state == .ready) {
        var req = server.receiveHead() catch return;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        respond(arena.allocator(), &req, dir, host) catch return;
    }
}

fn respond(a: Allocator, req: *std.http.Server.Request, dir: []const u8, host: []const u8) !void {
    const url = try urlPath(a, req.head.target);
    if (url.len == 0) return req.respond("", .{ .status = .not_found });
    if (req.head.method != .GET and req.head.method != .HEAD) return req.respond("", .{ .status = .method_not_allowed });
    var req_host: ?[]const u8 = null;
    var if_none_match: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (req_host == null and std.ascii.eqlIgnoreCase(h.name, "host")) req_host = h.value;
        if (if_none_match == null and std.ascii.eqlIgnoreCase(h.name, "if-none-match")) if_none_match = h.value;
    }
    // another name for this address (DNS rebinding) is not this server
    if (req_host == null or !std.mem.eql(u8, req_host.?, host)) return req.respond("", .{ .status = .forbidden });
    const r = try file(a, dir, url, if_none_match);
    try req.respond(r.body, .{ .status = r.status, .extra_headers = r.headers });
}

/// The path of a request target, decoded, without its first '/' and without the query.
fn urlPath(a: Allocator, target: []const u8) ![]u8 {
    const end = std.mem.findAny(u8, target, "?#") orelse target.len;
    const path = if (std.mem.startsWith(u8, target, "/")) target[1..end] else target[0..end];
    return std.Uri.percentDecodeInPlace(try a.dupe(u8, path));
}

/// Stands in for the project's service worker, which would copy the editor into the browser's cache
/// and later serve it from there instead of this folder. The editor waits (up to 15 s) for a worker
/// to control the page before it loads, so this one takes control at once and does nothing else.
const SERVICE_WORKER =
    \\self.addEventListener('install', () => self.skipWaiting())
    \\self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))
    \\
;

/// The file a URL path names inside `dir`: `a/` → `a/index.html`, `/editor` → `editor.html`;
/// null for anything outside it.
fn resolve(a: Allocator, dir: []const u8, url: []const u8) !?[]u8 {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const rel = plainPath(&buf, std.mem.trimStart(u8, url, "/")) orelse return null;
    const p = try std.fs.path.join(a, &.{ dir, rel });
    if (core.isDir(p)) {
        const index = try std.fs.path.join(a, &.{ p, "index.html" });
        return if (core.isFile(index)) index else null;
    }
    if (core.isFile(p)) return p;
    if (std.fs.path.extension(rel).len > 0) return null;
    const html = try std.mem.concat(a, u8, &.{ p, ".html" });
    return if (core.isFile(html)) html else null;
}

fn mime(path: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".map", "application/json" },
        .{ ".webmanifest", "application/manifest+json" },
        .{ ".wasm", "application/wasm" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml" },
    };
    const ext = std.fs.path.extension(path);
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    }
    return "application/octet-stream";
}

const Reply = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
};

fn file(a: Allocator, dir: []const u8, url: []const u8, if_none_match: ?[]const u8) !Reply {
    const Header = std.http.Header;
    const cache: Header = .{ .name = "cache-control", .value = "no-cache" };
    const csp: Header = .{ .name = "content-security-policy", .value = CSP };
    if (std.mem.eql(u8, url, "sw.js"))
        return .{ .headers = &.{ cache, csp, .{ .name = "content-type", .value = "text/javascript; charset=utf-8" } }, .body = SERVICE_WORKER };
    const path = try resolve(a, dir, url) orelse return .{ .status = .not_found };
    const st = Dir.cwd().statFile(core.io, path, .{}) catch return .{ .status = .not_found };
    const etag: Header = .{ .name = "etag", .value = try std.fmt.allocPrint(a, "\"{s}-{d}-{d}\"", .{ VERSION, st.size, @max(0, st.mtime.toSeconds()) }) };
    if (if_none_match) |v| {
        if (std.mem.eql(u8, v, etag.value)) return .{ .status = .not_modified, .headers = try a.dupe(Header, &.{ cache, csp, etag }) };
    }
    const bytes = Dir.cwd().readFileAlloc(core.io, path, a, .unlimited) catch return .{ .status = .not_found };
    return .{ .headers = try a.dupe(Header, &.{ cache, csp, etag, .{ .name = "content-type", .value = mime(path) } }), .body = bytes };
}

// ---------------- tests ----------------

const testing = std.testing;

/// A temp folder and an arena for one test.
const Temp = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init(t: *Temp) !void {
        core.gpa = testing.allocator;
        core.io = testing.io;
        t.tmp = testing.tmpDir(.{});
        t.arena = .init(testing.allocator);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        t.dir = try t.arena.allocator().dupe(u8, buf[0..try t.tmp.dir.realPath(testing.io, &buf)]);
    }

    fn deinit(t: *Temp) void {
        t.arena.deinit();
        t.tmp.cleanup();
    }

    fn path(t: *Temp, parts: []const []const u8) ![]u8 {
        const a = t.arena.allocator();
        return std.fs.path.join(a, &.{ t.dir, try std.fs.path.join(a, parts) });
    }
};

fn gzip(a: Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.ensureTotalCapacity(64);
    var gz: flate.Compress = try .init(&out.writer, try a.alloc(u8, flate.max_window_len), .gzip, .fastest);
    try gz.writer.writeAll(data);
    try gz.finish();
    return out.written();
}

test "unpacks only the site folder" {
    var t: Temp = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();

    var tar_bytes: std.Io.Writer.Allocating = .init(a);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    try tar.writeFileBytes("public/editor.html", "<html>", .{});
    try tar.writeDir("public/empty", .{});
    try tar.writeFileBytes("public/sdkjs/a b.js", "x", .{});
    try tar.writeLink("public/link.js", "/etc/passwd", .{});
    try tar.writeFileBytes("public/../escaped.js", "no", .{});
    try tar.writeFileBytes("public/sdkjs/../../escaped2.js", "no", .{});
    try tar.writeFileBytes("etc/passwd", "no", .{});
    try tar.writeFileBytes("publicity/editor.html", "no", .{});
    try tar.finishPedantically();
    const tgz = try t.path(&.{"layer.tgz"});
    try core.writeFile(tgz, try gzip(a, tar_bytes.written()));

    const out = try t.path(&.{"site"});
    var fail: core.Fail = .{};
    try unpack(a, tgz, out, &fail);
    try testing.expectEqualStrings("<html>", try core.readFileAlloc(a, try t.path(&.{ "site", "editor.html" }), 100));
    try testing.expectEqualStrings("x", try core.readFileAlloc(a, try t.path(&.{ "site", "sdkjs", "a b.js" }), 100));
    try testing.expect(core.isDir(try t.path(&.{ "site", "empty" })));
    for ([_][]const u8{ "etc", "escaped.js", "escaped2.js", "site/etc", "site/escaped.js", "site/escaped2.js", "site/link.js", "site/publicity", "publicity" }) |gone|
        try testing.expect(!core.exists(try t.path(&.{gone})));
}

test "prepare unzips x2t and fills Vietnamese" {
    var t: Temp = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const wasm = "\x00asm\x01\x00\x00\x00rest";
    const x2t = try t.path(&.{ "sdkjs", "common", "wasm", "x2t", "x2t.wasm.br" });
    try core.writeFile(x2t, try gzip(a, wasm));
    const en = try t.path(&.{ "web-apps", "apps", "presentationeditor", "main", "locale", "en.json" });
    const vi = try t.path(&.{ "web-apps", "apps", "presentationeditor", "main", "locale", "vi.json" });
    try core.writeFile(en, "{\"a\":\"Title\",\"b\":\"Body\"}");
    try core.writeFile(vi, "{\"a\":\"Tiêu đề\"}");

    var fail: core.Fail = .{};
    try prepare(a, t.dir, &fail);
    try testing.expectEqualStrings(wasm, try core.readFileAlloc(a, x2t, 100));
    try testing.expectEqualStrings("{\"a\":\"Tiêu đề\",\"b\":\"Body\"}", try core.readFileAlloc(a, vi, 100));
    // a second run leaves the plain module alone
    try prepare(a, t.dir, &fail);
    try testing.expectEqualStrings(wasm, try core.readFileAlloc(a, x2t, 100));
}

test "urls stay inside the site" {
    var t: Temp = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    for ([_][]const u8{ "editor.html", "help/index.html", "fonts" }) |f| try core.writeFile(try t.path(&.{f}), "");
    try testing.expectEqualStrings(try t.path(&.{"editor.html"}), (try resolve(a, t.dir, "editor.html")).?);
    try testing.expectEqualStrings(try t.path(&.{"editor.html"}), (try resolve(a, t.dir, "editor")).?);
    try testing.expectEqualStrings(try t.path(&.{ "help", "index.html" }), (try resolve(a, t.dir, "help/")).?);
    try testing.expectEqualStrings(try t.path(&.{"fonts"}), (try resolve(a, t.dir, "fonts")).?);
    try testing.expectEqual(null, try resolve(a, t.dir, "../editor.html"));
    try testing.expectEqual(null, try resolve(a, t.dir, "help/../../editor.html"));
    try testing.expectEqual(null, try resolve(a, t.dir, "./editor.html"));
    try testing.expectEqual(null, try resolve(a, t.dir, "missing.js"));
    if (core.is_windows) {
        try testing.expectEqual(null, try resolve(a, t.dir, "C:/Windows/win.ini"));
        try testing.expectEqual(null, try resolve(a, t.dir, "..\\editor.html"));
        try testing.expectEqual(null, try resolve(a, t.dir, "help\\index.html"));
    }
}

test "content types and request paths" {
    try testing.expectEqualStrings("text/html; charset=utf-8", mime("C:\\site\\editor.HTML"));
    try testing.expectEqualStrings("application/wasm", mime("x2t.wasm"));
    try testing.expectEqualStrings("application/octet-stream", mime("x2t.wasm.br"));
    try testing.expectEqualStrings("application/octet-stream", mime("fonts"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("sdkjs/a b.js", try urlPath(a, "/sdkjs/a%20b.js?v=1#top"));
    try testing.expectEqualStrings("../x", try urlPath(a, "/%2e%2e%2Fx"));
    try testing.expectEqualStrings("", try urlPath(a, "/"));
}

test "a port that is taken is left alone" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var first = try listen();
    defer first.deinit(core.io);
    var second = try listen();
    defer second.deinit(core.io);
    const port = first.socket.address.getPort();
    try testing.expect(port != 0 and second.socket.address.getPort() != 0);
    try testing.expect(port != second.socket.address.getPort());
    if (core.is_windows) {
        try testing.expect(portTaken(port) and portTaken(second.socket.address.getPort()));
        // where nothing listens: the port of a listener that is gone
        var third = try listen();
        const free = third.socket.address.getPort();
        third.deinit(core.io);
        try testing.expect(!portTaken(free));
    }
}

test "the server answers on 127.0.0.1 only" {
    var t: Temp = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try core.writeFile(try t.path(&.{"editor.html"}), "<html>editor");
    try core.writeFile(try t.path(&.{ "sdkjs", "a b.js" }), "let x");

    var listener = try listen();
    defer listener.deinit(core.io);
    const port = listener.socket.address.getPort();
    // what `acceptLoop` does, for the connections of this test, one after the other
    const requests = 8;
    const Loop = struct {
        fn run(l: *net.Server, dir: []const u8, p: u16) void {
            for (0..requests) |_| connection(l.accept(core.io) catch return, dir, p);
        }
    };
    const thread = try std.Thread.spawn(.{}, Loop.run, .{ &listener, t.dir, port });
    defer thread.join();

    const host = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{port});
    const Ask = struct {
        /// One request on a connection of its own; the whole answer, head included.
        fn ask(al: Allocator, p: u16, method: []const u8, path: []const u8, headers: []const u8) ![]u8 {
            const address: net.IpAddress = .{ .ip4 = .loopback(p) };
            const stream = try address.connect(core.io, .{ .mode = .stream });
            defer stream.close(core.io);
            var out_buf: [1024]u8 = undefined;
            var out = stream.writer(core.io, &out_buf);
            try out.interface.print("{s} {s} HTTP/1.1\r\n{s}Connection: close\r\n\r\n", .{ method, path, headers });
            try out.interface.flush();
            var in_buf: [1024]u8 = undefined;
            var in = stream.reader(core.io, &in_buf);
            return in.interface.allocRemaining(al, .unlimited);
        }
    };
    const host_line = try std.fmt.allocPrint(a, "Host: {s}\r\n", .{host});

    // 1: a file, with the headers every answer carries
    const page = try Ask.ask(a, port, "GET", "/editor.html", host_line);
    try testing.expect(std.mem.startsWith(u8, page, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, page, "\r\n\r\n<html>editor"));
    try testing.expect(std.mem.find(u8, page, "\r\ncontent-type: text/html; charset=utf-8\r\n") != null);
    try testing.expect(std.mem.find(u8, page, "\r\ncache-control: no-cache\r\n") != null);
    try testing.expect(std.mem.find(u8, page, "\r\ncontent-security-policy: " ++ CSP ++ "\r\n") != null);
    const etag_at = std.mem.find(u8, page, "\r\netag: ").? + "\r\netag: ".len;
    const etag = page[etag_at..][0..std.mem.find(u8, page[etag_at..], "\r\n").?];
    try testing.expect(std.mem.startsWith(u8, etag, "\"" ++ VERSION ++ "-12-"));

    // 2: the same file again, unchanged
    const again = try Ask.ask(a, port, "GET", "/editor.html", try std.fmt.allocPrint(a, "{s}If-None-Match: {s}\r\n", .{ host_line, etag }));
    try testing.expect(std.mem.startsWith(u8, again, "HTTP/1.1 304 "));
    try testing.expect(std.mem.find(u8, again, etag) != null);
    try testing.expect(std.mem.endsWith(u8, again, "\r\n\r\n"));

    // 3: another name for this address is refused
    const rebound = try Ask.ask(a, port, "GET", "/editor.html", "Host: evil.example\r\n");
    try testing.expect(std.mem.startsWith(u8, rebound, "HTTP/1.1 403 "));
    try testing.expect(std.mem.find(u8, rebound, "editor") == null);

    // 4, 5: the stand-in service worker; an encoded path, without its extension
    const sw = try Ask.ask(a, port, "GET", "/sw.js", host_line);
    try testing.expect(std.mem.endsWith(u8, sw, "\r\n\r\n" ++ SERVICE_WORKER));
    try testing.expect(std.mem.find(u8, sw, "\r\ncontent-type: text/javascript; charset=utf-8\r\n") != null);
    const script = try Ask.ask(a, port, "HEAD", "/sdkjs/a%20b.js?x=1", host_line);
    try testing.expect(std.mem.startsWith(u8, script, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.find(u8, script, "\r\ncontent-length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, script, "\r\n\r\n"));

    // 6, 7, 8: nothing outside the site, nothing at "/", no other methods
    try testing.expect(std.mem.startsWith(u8, try Ask.ask(a, port, "GET", "/%2e%2e/layer.tgz", host_line), "HTTP/1.1 404 "));
    try testing.expect(std.mem.startsWith(u8, try Ask.ask(a, port, "GET", "/", host_line), "HTTP/1.1 404 "));
    try testing.expect(std.mem.startsWith(u8, try Ask.ask(a, port, "POST", "/editor.html", host_line), "HTTP/1.1 405 "));
}

test "the server answers a request made with http.zig" {
    var t: Temp = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try core.writeFile(try t.path(&.{"editor.html"}), "<html>editor");

    var listener = try listen();
    defer listener.deinit(core.io);
    const port = listener.socket.address.getPort();
    const Loop = struct {
        fn run(l: *net.Server, dir: []const u8, p: u16) void {
            for (0..2) |_| connection(l.accept(core.io) catch return, dir, p);
        }
    };
    const thread = try std.Thread.spawn(.{}, Loop.run, .{ &listener, t.dir, port });
    defer thread.join();

    // "connection: close", so nothing of this test stays in the shared client
    const close: []const http.Header = &.{.{ .name = "connection", .value = "close" }};
    const r = try http.get(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/editor", .{port}), close);
    try testing.expectEqual(200, r.status);
    try testing.expectEqualStrings("<html>editor", r.body);
    try testing.expectEqualStrings("text/html; charset=utf-8", r.header("content-type").?);
    try testing.expectEqualStrings(CSP, r.header("content-security-policy").?);

    // the way the layer is downloaded: into a file, hashed and counted on its way
    const layer = try a.alloc(u8, 300_000);
    for (layer, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 7);
    try core.writeFile(try t.path(&.{"layer.bin"}), layer);
    const Noop = struct {
        fn f(_: u64) void {}
    };
    var d: Download = .{ .progress = Noop.f };
    const to = try t.path(&.{"layer.part"});
    const got = try fetch(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/layer.bin", .{port}), close, to, &d);
    try testing.expectEqual(200, got.status);
    try testing.expectEqual(layer.len, d.done);
    var sha: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(layer, &sha, .{});
    try testing.expectEqualSlices(u8, &sha, &got.sha256);
    try testing.expectEqualSlices(u8, layer, try core.readFileAlloc(a, to, 1 << 20));
}

test "progress is told every half percent" {
    const Seen = struct {
        var calls: u32 = 0;
        var last: u64 = 0;
        fn f(done: u64) void {
            calls += 1;
            last = done;
        }
    };
    var d: Download = .{ .progress = Seen.f };
    var done: u64 = 0;
    while (done < LAYER_SIZE) {
        done = @min(done + 64 * 1024, LAYER_SIZE);
        Download.onBytes(&d, done, LAYER_SIZE);
    }
    try testing.expectEqual(LAYER_SIZE, Seen.last);
    try testing.expectEqual(LAYER_SIZE, d.done);
    try testing.expect(Seen.calls >= 190 and Seen.calls <= 201);
}
