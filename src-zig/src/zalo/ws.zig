//! A small WebSocket client (RFC 6455) for Zalo's socket: TCP, TLS for `wss://` (set up the way
//! `std.http.Client` sets up its connections, with the system's root certificates), the HTTP/1.1
//! upgrade, then frames — client frames masked, fragmented messages put together, pings answered,
//! the closing handshake. No extensions (no compression).
//!
//! One thread reads (`read`); any thread may send.

const std = @import("std");
const core = @import("../core.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Tls = std.crypto.tls.Client;

pub const Header = std.http.Header;

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    fn isControl(op: Opcode) bool {
        return @backingInt(op) >= 8;
    }
};

pub const Message = union(enum) {
    /// valid until the next `read`
    text: []const u8,
    binary: []const u8,
    /// the peer closed: its status code (1005 when it gave none)
    close: u16,
};

/// a message may not be larger than this
const max_message = 64 << 20;

// ---------------- frames ----------------

pub const FrameHead = struct {
    fin: bool,
    opcode: Opcode,
    mask: ?[4]u8,
    len: u64,
};

/// Writes one frame; `mask` is given by clients (and applied to the payload), never by servers.
pub fn writeFrame(w: *Io.Writer, opcode: Opcode, fin: bool, mask: ?[4]u8, payload: []const u8) Io.Writer.Error!void {
    try w.writeByte((if (fin) @as(u8, 0x80) else 0) | @backingInt(opcode));
    const m: u8 = if (mask != null) 0x80 else 0;
    if (payload.len < 126) {
        try w.writeByte(m | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(m | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else {
        try w.writeByte(m | 127);
        try w.writeInt(u64, payload.len, .big);
    }
    const key = mask orelse return w.writeAll(payload);
    try w.writeAll(&key);
    var buf: [1024]u8 = undefined;
    var done: usize = 0;
    while (done < payload.len) {
        const n = @min(buf.len, payload.len - done);
        for (buf[0..n], payload[done..][0..n], done..) |*o, b, i| o.* = b ^ key[i % 4];
        try w.writeAll(buf[0..n]);
        done += n;
    }
}

pub fn readFrameHead(r: *Io.Reader) !FrameHead {
    const b0 = try r.takeByte();
    const b1 = try r.takeByte();
    // RSV bits: only extensions use them, and none was negotiated
    if (b0 & 0x70 != 0) return error.WsProtocol;
    var h: FrameHead = .{ .fin = b0 & 0x80 != 0, .opcode = @fromBackingInt(@as(u4, @truncate(b0))), .mask = null, .len = b1 & 0x7f };
    if (h.len == 126) {
        h.len = try r.takeInt(u16, .big);
    } else if (h.len == 127) {
        h.len = try r.takeInt(u64, .big);
        if (h.len >> 63 != 0) return error.WsProtocol;
    }
    if (h.opcode.isControl() and (!h.fin or h.len > 125)) return error.WsProtocol;
    if (b1 & 0x80 != 0) h.mask = (try r.takeArray(4)).*;
    return h;
}

/// Reads a frame's payload (unmasked) to the end of `out`.
fn readPayload(r: *Io.Reader, a: Allocator, h: FrameHead, out: *std.ArrayList(u8)) !void {
    if (h.len > max_message or out.items.len + h.len > max_message) return error.WsMessageTooLarge;
    const n: usize = @intCast(h.len);
    try out.ensureUnusedCapacity(a, n);
    const dest = out.unusedCapacitySlice()[0..n];
    try r.readSliceAll(dest);
    if (h.mask) |key| for (dest, 0..) |*b, i| {
        b.* ^= key[i % 4];
    };
    out.items.len += n;
}

/// `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key`.
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

// ---------------- root certificates ----------------

var ca_mutex: core.Mutex = .{};
var ca_lock: Io.RwLock = .init;
var ca_bundle: std.crypto.Certificate.Bundle = .empty;
var ca_loaded = false;

/// The system's root certificates, read once.
fn loadCa(now: Io.Timestamp) !void {
    ca_mutex.lock();
    defer ca_mutex.unlock();
    if (ca_loaded) return;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(core.gpa);
    try bundle.rescan(core.gpa, core.io, now);
    ca_lock.lockUncancelable(core.io);
    defer ca_lock.unlock(core.io);
    std.mem.swap(std.crypto.Certificate.Bundle, &ca_bundle, &bundle);
    ca_loaded = true;
}

// ---------------- the client ----------------

pub const Client = struct {
    a: Allocator,
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls: ?Tls,
    buffers: []u8,
    write_mutex: core.Mutex = .{},
    sent_close: bool = false,
    /// the message being put together
    msg: std.ArrayList(u8) = .empty,

    /// Connects to a `ws://` or `wss://` URL and upgrades, sending `headers` with the request.
    pub fn connect(a: Allocator, url: []const u8, headers: []const Header) !*Client {
        const io = core.io;
        const uri = try std.Uri.parse(url);
        const secure = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss")) true else if (std.ascii.eqlIgnoreCase(uri.scheme, "ws")) false else return error.UnsupportedUriScheme;
        var host_buf: [net.HostName.max_len]u8 = undefined;
        const host = try net.HostName.fromUri(uri, &host_buf);
        const port: u16 = uri.port orelse if (secure) 443 else 80;

        const stream = try host.connect(io, port, .{ .mode = .stream });
        errdefer stream.close(io);

        const c = try a.create(Client);
        errdefer a.destroy(c);
        // the same buffers std.http.Client gives a connection
        const tls_len = Tls.min_buffer_len;
        const sizes: [4]usize = if (secure) .{ tls_len + 8192, tls_len, 4096, tls_len } else .{ 0, 4096, 0, 16 * 1024 };
        const buffers = try a.alloc(u8, sizes[0] + sizes[1] + sizes[2] + sizes[3]);
        errdefer a.free(buffers);
        const tls_read = buffers[0..sizes[0]];
        const socket_write = buffers[sizes[0]..][0..sizes[1]];
        const tls_write = buffers[sizes[0] + sizes[1] ..][0..sizes[2]];
        const socket_read = buffers[sizes[0] + sizes[1] + sizes[2] ..][0..sizes[3]];
        c.* = .{
            .a = a,
            .stream = stream,
            .stream_reader = stream.reader(io, socket_read),
            .stream_writer = stream.writer(io, socket_write),
            .tls = null,
            .buffers = buffers,
        };
        if (secure) {
            // certificates are checked against the time now, not the time the roots were read
            const now = Io.Clock.real.now(io);
            try loadCa(now);
            var entropy: [Tls.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            c.tls = Tls.init(&c.stream_reader.interface, &c.stream_writer.interface, .{
                .host = .{ .explicit = host.bytes },
                .ca = .{ .bundle = .{ .gpa = core.gpa, .io = io, .lock = &ca_lock, .bundle = &ca_bundle } },
                .read_buffer = tls_read,
                .write_buffer = tls_write,
                .entropy = &entropy,
                .realtime_now = now,
                // a close is a WebSocket close frame; a cut connection is an error either way
                .allow_truncation_attacks = true,
            }) catch |e| switch (e) {
                error.WriteFailed => return c.stream_writer.err orelse e,
                error.ReadFailed => return c.stream_reader.err orelse e,
                else => return e,
            };
        }
        try c.handshake(uri, host.bytes, if ((secure and port == 443) or (!secure and port == 80)) null else port, headers);
        return c;
    }

    fn reader(c: *Client) *Io.Reader {
        return if (c.tls) |*t| &t.reader else &c.stream_reader.interface;
    }

    fn writer(c: *Client) *Io.Writer {
        return if (c.tls) |*t| &t.writer else &c.stream_writer.interface;
    }

    fn flush(c: *Client) !void {
        if (c.tls) |*t| try t.writer.flush();
        try c.stream_writer.interface.flush();
    }

    fn handshake(c: *Client, uri: std.Uri, host: []const u8, port: ?u16, headers: []const Header) !void {
        var nonce: [16]u8 = undefined;
        core.io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);

        const w = c.writer();
        try w.writeAll("GET ");
        if (uri.path.isEmpty()) try w.writeByte('/');
        try uri.writeToStream(w, .{ .path = true, .query = true });
        try w.print(" HTTP/1.1\r\nHost: {s}", .{host});
        if (port) |p| try w.print(":{d}", .{p});
        try w.print("\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n", .{&key});
        for (headers) |h| {
            // a header may not carry a line break
            if (std.mem.indexOfAny(u8, h.name, "\r\n:") != null or std.mem.indexOfAny(u8, h.value, "\r\n") != null) continue;
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try w.writeAll("\r\n");
        try c.flush();

        const r = c.reader();
        const status = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        // "HTTP/1.1 101 Switching Protocols"
        var parts = std.mem.tokenizeScalar(u8, status, ' ');
        const version = parts.next() orelse return error.WsHandshakeFailed;
        const code = parts.next() orelse return error.WsHandshakeFailed;
        if (!std.mem.startsWith(u8, version, "HTTP/1.") or !std.mem.eql(u8, code, "101")) return error.WsHandshakeFailed;
        var accepted = false;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "sec-websocket-accept"))
                accepted = std.mem.eql(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"), &acceptKey(&key));
        }
        if (!accepted) return error.WsHandshakeFailed;
    }

    /// The next message (pings are answered and skipped). After `.close`, or an error, the
    /// connection is over.
    pub fn read(c: *Client) !Message {
        const r = c.reader();
        c.msg.clearRetainingCapacity();
        var kind: ?Opcode = null;
        while (true) {
            const h = try readFrameHead(r);
            if (h.opcode.isControl()) {
                var small: [125]u8 = undefined;
                const payload = small[0..@intCast(h.len)];
                try r.readSliceAll(payload);
                if (h.mask) |key| for (payload, 0..) |*b, i| {
                    b.* ^= key[i % 4];
                };
                switch (h.opcode) {
                    .ping => c.send(.pong, payload) catch {},
                    .pong => {},
                    .close => {
                        const code: u16 = if (payload.len >= 2) std.mem.readInt(u16, payload[0..2], .big) else 1005;
                        // answer the peer's close with ours, once
                        c.sendClose(if (payload.len >= 2) code else 1000) catch {};
                        return .{ .close = code };
                    },
                    else => return error.WsProtocol,
                }
                continue;
            }
            switch (h.opcode) {
                .continuation => if (kind == null) return error.WsProtocol,
                .text, .binary => {
                    if (kind != null) return error.WsProtocol;
                    kind = h.opcode;
                },
                else => return error.WsProtocol,
            }
            try readPayload(r, c.a, h, &c.msg);
            if (h.fin) return if (kind.? == .text) .{ .text = c.msg.items } else .{ .binary = c.msg.items };
        }
    }

    fn send(c: *Client, opcode: Opcode, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        core.io.random(&mask);
        c.write_mutex.lock();
        defer c.write_mutex.unlock();
        if (c.sent_close) return error.WsClosed;
        if (opcode == .close) c.sent_close = true;
        try writeFrame(c.writer(), opcode, true, mask, payload);
        try c.flush();
    }

    pub fn sendBinary(c: *Client, data: []const u8) !void {
        return c.send(.binary, data);
    }

    pub fn sendText(c: *Client, data: []const u8) !void {
        return c.send(.text, data);
    }

    /// Starts (or answers) the closing handshake; nothing can be sent after it.
    pub fn sendClose(c: *Client, code: u16) !void {
        var payload: [2]u8 = undefined;
        std.mem.writeInt(u16, &payload, code, .big);
        return c.send(.close, &payload);
    }

    /// Closes the connection and frees the client. No other thread may be using it.
    pub fn deinit(c: *Client) void {
        if (c.tls) |*t| {
            t.end() catch {};
            c.stream_writer.interface.flush() catch {};
        }
        c.stream.close(core.io);
        c.msg.deinit(c.a);
        c.a.free(c.buffers);
        c.a.destroy(c);
    }
};

// ---------------- tests ----------------

const testing = std.testing;

test "frames: lengths, masking, fragments" {
    const a = testing.allocator;
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;

    // RFC 6455 §5.7: a single-frame masked "Hello"
    try writeFrame(w, .text, true, .{ 0x37, 0xfa, 0x21, 0x3d }, "Hello");
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, aw.written());
    aw.clearRetainingCapacity();
    // unmasked (what a server sends)
    try writeFrame(w, .text, true, null, "Hello");
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f }, aw.written());
    aw.clearRetainingCapacity();

    // 16-bit and 64-bit lengths; a message in three frames with a ping in between
    const mid = try a.alloc(u8, 300);
    defer a.free(mid);
    for (mid, 0..) |*b, i| b.* = @truncate(i);
    const big = try a.alloc(u8, 70_000);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 7);
    try writeFrame(w, .binary, true, .{ 1, 2, 3, 4 }, mid);
    try writeFrame(w, .binary, false, .{ 9, 8, 7, 6 }, big[0..1000]);
    try writeFrame(w, .ping, true, null, "p");
    try writeFrame(w, .continuation, false, null, big[1000..66_000]);
    try writeFrame(w, .continuation, true, .{ 5, 5, 5, 5 }, big[66_000..]);
    try testing.expectEqual(@as(u8, 0x82), aw.written()[0]);
    try testing.expectEqual(@as(u8, 0x80 | 126), aw.written()[1]);

    var r: Io.Reader = .fixed(aw.written());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var h = try readFrameHead(&r);
    try testing.expect(h.fin and h.opcode == .binary and h.len == 300 and h.mask != null);
    try readPayload(&r, a, h, &out);
    try testing.expectEqualSlices(u8, mid, out.items);
    out.clearRetainingCapacity();
    h = try readFrameHead(&r);
    try testing.expect(!h.fin and h.opcode == .binary and h.len == 1000);
    try readPayload(&r, a, h, &out);
    h = try readFrameHead(&r);
    try testing.expect(h.fin and h.opcode == .ping and h.len == 1 and h.mask == null);
    try testing.expectEqual(@as(u8, 'p'), try r.takeByte());
    h = try readFrameHead(&r);
    try testing.expect(!h.fin and h.opcode == .continuation and h.len == 65_000);
    try readPayload(&r, a, h, &out);
    h = try readFrameHead(&r);
    try testing.expect(h.fin and h.opcode == .continuation and h.len == 4000);
    try readPayload(&r, a, h, &out);
    try testing.expectEqualSlices(u8, big, out.items);
    try testing.expectError(error.EndOfStream, readFrameHead(&r));
}

test "frames a peer may not send" {
    // a reserved bit, a fragmented control frame, a control frame that is too long
    for ([_][]const u8{ &.{ 0xc1, 0x00 }, &.{ 0x09, 0x00 }, &.{ 0x89, 126, 0, 126 }, &.{ 0x82, 127, 0xff, 0, 0, 0, 0, 0, 0, 0 } }) |bytes| {
        var r: Io.Reader = .fixed(bytes);
        try testing.expectError(error.WsProtocol, readFrameHead(&r));
    }
    // RFC 6455 §1.3
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

/// A WebSocket server for one connection: echoes binary messages (long ones in fragments with a
/// ping in between) until the client closes.
const TestServer = struct {
    server: net.Server,
    saw_headers: bool = false,
    masked: bool = true,
    pongs: u32 = 0,
    failed: ?anyerror = null,

    fn run(s: *TestServer) void {
        s.serve() catch |e| {
            s.failed = e;
        };
    }

    fn serve(s: *TestServer) !void {
        const io = core.io;
        const a = testing.allocator;
        const stream = try s.server.accept(io);
        defer stream.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        const r = &sr.interface;
        const w = &sw.interface;

        var key: [24]u8 = undefined;
        var have_key = false;
        var cookie = false;
        var target_ok = false;
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "GET ")) target_ok = std.mem.eql(u8, line, "GET /chat?t=1&x=a%20b HTTP/1.1");
            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-key: ")) {
                key = line[19..][0..24].*;
                have_key = true;
            }
            if (std.mem.eql(u8, line, "cookie: a=1; b=2")) cookie = true;
        }
        s.saw_headers = have_key and cookie and target_ok;
        try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&acceptKey(&key)});
        try w.flush();

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(a);
        while (true) {
            const h = try readFrameHead(r);
            if (h.mask == null) s.masked = false;
            msg.clearRetainingCapacity();
            try readPayload(r, a, h, &msg);
            switch (h.opcode) {
                .binary => {
                    const p = msg.items;
                    if (p.len > 1000) {
                        try writeFrame(w, .binary, false, null, p[0..10]);
                        try writeFrame(w, .ping, true, null, "are you there");
                        try writeFrame(w, .continuation, false, null, p[10..500]);
                        try writeFrame(w, .continuation, true, null, p[500..]);
                    } else {
                        try writeFrame(w, .binary, true, null, p);
                    }
                    try w.flush();
                },
                .pong => {
                    if (std.mem.eql(u8, msg.items, "are you there")) s.pongs += 1;
                },
                .close => {
                    try writeFrame(w, .close, true, null, msg.items);
                    try w.flush();
                    return;
                },
                else => return error.Unexpected,
            }
        }
    }
};

const TestReader = struct {
    client: *Client,
    got: std.ArrayList([]u8) = .empty,
    count: std.atomic.Value(u32) = .init(0),
    close: ?u16 = null,
    failed: ?anyerror = null,

    fn run(t: *TestReader) void {
        while (true) {
            const m = t.client.read() catch |e| {
                t.failed = e;
                return;
            };
            switch (m) {
                .binary, .text => |b| {
                    t.got.append(testing.allocator, testing.allocator.dupe(u8, b) catch return) catch return;
                    _ = t.count.fetchAdd(1, .seq_cst);
                },
                .close => |code| {
                    t.close = code;
                    return;
                },
            }
        }
    }
};

test "client against a local server: handshake, echo, fragments, ping, close" {
    const a = testing.allocator;
    core.gpa = a;
    core.io = testing.io;
    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server: TestServer = .{ .server = try addr.listen(core.io, .{}) };
    defer server.server.deinit(core.io);
    const port = server.server.socket.address.getPort();
    const st = try std.Thread.spawn(.{}, TestServer.run, .{&server});

    const url = try std.fmt.allocPrint(a, "ws://127.0.0.1:{d}/chat?t=1&x=a%20b", .{port});
    defer a.free(url);
    const client = try Client.connect(a, url, &.{ .{ .name = "cookie", .value = "a=1; b=2" }, .{ .name = "bad\r\nheader", .value = "x" } });
    defer client.deinit();

    // one thread reads while this one sends
    var rd: TestReader = .{ .client = client };
    defer {
        for (rd.got.items) |m| a.free(m);
        rd.got.deinit(a);
    }
    const rt = try std.Thread.spawn(.{}, TestReader.run, .{&rd});
    const big = try a.alloc(u8, 70_000);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i * 13);
    try client.sendBinary("hello");
    try client.sendBinary(big);
    try client.sendBinary("");
    // every echo is in (the ping inside the long one was answered) before the close
    var waited: u32 = 0;
    while (rd.count.load(.seq_cst) < 3 and waited < 2000) : (waited += 1) core.sleepMs(5);
    try client.sendClose(1000);
    try testing.expectError(error.WsClosed, client.sendBinary("late"));
    rt.join();
    st.join();

    try testing.expectEqual(@as(?anyerror, null), server.failed);
    try testing.expectEqual(@as(?anyerror, null), rd.failed);
    try testing.expect(server.saw_headers and server.masked);
    try testing.expectEqual(@as(u32, 1), server.pongs);
    try testing.expectEqual(@as(?u16, 1000), rd.close);
    try testing.expectEqual(@as(usize, 3), rd.got.items.len);
    try testing.expectEqualStrings("hello", rd.got.items[0]);
    try testing.expectEqualSlices(u8, big, rd.got.items[1]);
    try testing.expectEqual(@as(usize, 0), rd.got.items[2].len);
}

test "a server that is no WebSocket server is refused" {
    const a = testing.allocator;
    core.gpa = a;
    core.io = testing.io;
    var addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(core.io, .{});
    defer server.deinit(core.io);
    const port = server.socket.address.getPort();
    const st = try std.Thread.spawn(.{}, struct {
        fn run(s: *net.Server) void {
            const stream = s.accept(core.io) catch return;
            defer stream.close(core.io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [256]u8 = undefined;
            var sr = stream.reader(core.io, &rbuf);
            var sw = stream.writer(core.io, &wbuf);
            while (true) {
                const line = sr.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            sw.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") catch {};
            sw.interface.flush() catch {};
        }
    }.run, .{&server});
    const url = try std.fmt.allocPrint(a, "ws://127.0.0.1:{d}/", .{port});
    defer a.free(url);
    try testing.expectError(error.WsHandshakeFailed, Client.connect(a, url, &.{}));
    st.join();
    try testing.expectError(error.UnsupportedUriScheme, Client.connect(a, "https://127.0.0.1/", &.{}));
}

test "TLS and the upgrade against a public echo server" {
    const a = testing.allocator;
    // only when asked for: the unit tests do not depend on the network
    if (!(testing.environ.contains(a, "VIBE_NET_TESTS") catch false)) return error.SkipZigTest;
    core.gpa = a;
    core.io = testing.io;
    const client = Client.connect(a, "wss://ws.postman-echo.com/raw", &.{.{ .name = "origin", .value = "https://example.com" }}) catch |e| {
        std.debug.print("echo server not reached: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer {
        client.deinit();
        ca_bundle.deinit(core.gpa);
        ca_bundle = .empty;
        ca_loaded = false;
    }
    try client.sendText("xin chào");
    const m = try client.read();
    try testing.expectEqualStrings("xin chào", m.text);
    try client.sendClose(1000);
    while (true) {
        const next = client.read() catch break;
        if (next == .close) break;
    }
}
