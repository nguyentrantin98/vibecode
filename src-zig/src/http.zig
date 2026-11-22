//! HTTP(S) requests for every module: one shared `std.http.Client` (thread-safe connection pool,
//! the system's root certificates).
//!
//!     const r = try http.get(a, "https://api.github.com/…", &.{.{ .name = "Accept", .value = "…" }});
//!     if (!r.ok()) return error.Http;
//!     const j = try core.fromJson(T, a, r.body);

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const Header = std.http.Header;

var client_state: std.http.Client = undefined;
var client_ready = false;
var client_mutex: core.Mutex = .{};

/// The shared client, for requests the helpers below do not cover (streaming uploads, WebSocket
/// upgrades…). A `Request` is not thread-safe; the client is.
pub fn client() *std.http.Client {
    client_mutex.lock();
    defer client_mutex.unlock();
    if (!client_ready) {
        client_state = .{ .allocator = core.gpa, .io = core.io };
        client_ready = true;
    }
    return &client_state;
}

pub const Options = struct {
    /// GET, or POST when there is a body
    method: ?std.http.Method = null,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    user_agent: []const u8 = "vibe-code",
    /// redirects followed (requests without a body); 0 hands 3xx back to the caller
    redirects: u16 = 5,
    /// the response may not be larger than this
    max: usize = 256 << 20,
};

pub const Response = struct {
    status: u16,
    /// decompressed body, allocated in the caller's allocator
    body: []u8,
    /// response headers (after redirects), in order; several `Set-Cookie` stay separate
    headers: []const Header,

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
    }

    /// First header with this name (case-insensitive).
    pub fn header(r: Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// One request, the whole response in memory (allocated in `a`; use an arena).
pub fn request(a: Allocator, url: []const u8, o: Options) !Response {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    const head = try stream(a, url, o, &aw.writer, null, null);
    if (aw.written().len > o.max) return error.StreamTooLong;
    return .{ .status = head.status, .body = try aw.toOwnedSlice(), .headers = head.headers };
}

pub fn get(a: Allocator, url: []const u8, headers: []const Header) !Response {
    return request(a, url, .{ .headers = headers });
}

/// POST with a JSON body.
pub fn postJson(a: Allocator, url: []const u8, headers: []const Header, json: []const u8) !Response {
    return request(a, url, .{ .headers = headers, .body = json, .content_type = "application/json" });
}

pub const Head = struct {
    status: u16,
    headers: []const Header,
    /// Content-Length, when the server sent one
    length: ?u64,
};

/// `done` bytes so far of `total` (null when the server did not say).
pub const Progress = *const fn (ctx: ?*anyopaque, done: u64, total: ?u64) void;

/// One request with the body streamed into `out` (a file writer, a hasher…): for downloads too
/// large to hold in memory. The body is asked for uncompressed when `progress` is given, so the
/// byte counts match Content-Length. Headers are allocated in `a`.
pub fn stream(a: Allocator, url: []const u8, o: Options, out: *std.Io.Writer, progress: ?Progress, ctx: ?*anyopaque) !Head {
    const uri = try std.Uri.parse(url);
    const method: std.http.Method = o.method orelse if (o.body != null) .POST else .GET;
    var req = try client().request(method, uri, .{
        .redirect_behavior = if (o.body != null or o.redirects == 0) .unhandled else .init(o.redirects),
        .headers = .{
            .user_agent = .{ .override = o.user_agent },
            .content_type = if (o.content_type) |t| .{ .override = t } else .default,
            .accept_encoding = if (progress != null) .{ .override = "identity" } else .default,
        },
        .extra_headers = o.headers,
    });
    defer req.deinit();

    if (o.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    // the head's strings die when the body reader starts: copy them first
    var headers: std.ArrayList(Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| try headers.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    const head: Head = .{ .status = @intFromEnum(response.head.status), .headers = headers.items, .length = response.head.content_length };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try core.gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try core.gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer core.gpa.free(decompress_buffer);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var done: u64 = 0;
    while (true) {
        const n = reader.stream(out, .limited(64 * 1024)) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |x| return x,
        };
        done += n;
        if (progress) |p| p(ctx, done, head.length);
    }
    try out.flush();
    return head;
}

/// Downloads `url` to `path` (through `path.part`, renamed when complete).
pub fn download(a: Allocator, url: []const u8, o: Options, path: []const u8, progress: ?Progress, ctx: ?*anyopaque) !Head {
    const Dir = std.Io.Dir;
    if (std.fs.path.dirname(path)) |d| try core.makePath(d);
    const part = try std.mem.concat(a, u8, &.{ path, ".part" });
    var file = try Dir.cwd().createFile(core.io, part, .{});
    var keep = false;
    defer if (!keep) Dir.cwd().deleteFile(core.io, part) catch {};
    const head = blk: {
        defer file.close(core.io);
        var buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(core.io, &buf);
        break :blk try stream(a, url, o, &fw.interface, progress, ctx);
    };
    if (head.status < 200 or head.status >= 300) return head;
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), path, core.io);
    keep = true;
    return head;
}

/// `s` percent-encoded for a query string value.
pub fn encodeQuery(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(a, ch);
        } else {
            try out.print(a, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(a);
}

test "encodeQuery" {
    const a = std.testing.allocator;
    const s = try encodeQuery(a, "a b&c=đ");
    defer a.free(s);
    try std.testing.expectEqualStrings("a%20b%26c%3D%C4%91", s);
}

test {
    _ = &request;
    _ = &get;
    _ = &postJson;
    _ = &download;
}
