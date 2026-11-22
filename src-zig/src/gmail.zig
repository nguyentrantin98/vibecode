//! Gmail tab: a read-only view of the inbox over IMAP, signed in with a Google app password
//! (no Google Cloud project needed). The mailbox is opened with EXAMINE, so reading here never
//! marks mail as read. The password is kept in `<userData>/gmail.json`, sealed by `secure`.
//!
//! Speed: one IMAP connection is kept open and reused (a fresh one is made when Gmail has dropped
//! it), the list asks only for each message's ENVELOPE, and opened messages are cached in memory.
//!
//! The IMAP client is the small part of the protocol this needs (LOGIN, EXAMINE, FETCH, UID
//! SEARCH, UID FETCH, LOGOUT) over `std.crypto.tls`; messages are read by mail.zig.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const mail = @import("mail.zig");
const trim = @import("text.zig").trim;
const isWhitespace = @import("text.zig").isWhitespace;
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tr = settings.tr;

const HOST = "imap.gmail.com";
const PORT = 993;
/// how many messages one page of the list loads (scrolling to the bottom loads the next page)
const PAGE_SIZE: u32 = 30;

pub const MailSummary = struct {
    uid: u32,
    /// display name, or the address when there is none
    from: []const u8,
    fromAddr: []const u8,
    subject: []const u8,
    /// ms since epoch, 0 when the Date header is missing or unreadable
    date: i64,
    seen: bool,
};

pub const MailBody = struct {
    uid: u32,
    from: []const u8,
    to: []const u8,
    subject: []const u8,
    date: i64,
    html: ?[]const u8,
    text: ?[]const u8,
    attachments: []const []const u8,
};

// ---------------- saved account ----------------

const Account = struct { email: []const u8, password: []const u8 };

fn accountFile(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"gmail.json"});
}

fn savedAccount(a: Allocator) ?Account {
    const path = accountFile(a) catch return null;
    const bytes = core.readFileAlloc(a, path, 1 << 20) catch return null;
    const j = core.fromJson(Account, a, bytes) catch return null;
    const password = if (@hasDecl(m.secure, "openStr")) m.secure.openStr(a, j.password) catch return null else return null;
    return .{ .email = j.email, .password = password };
}

// ---------------- IMAP ----------------

/// A parsed piece of a response: `(UID 7 FLAGS (\Seen) ENVELOPE ("date" NIL …))`.
const Value = union(enum) {
    nil,
    /// an atom or a number, as written
    atom: []const u8,
    /// a quoted string (unescaped) or a literal
    string: []const u8,
    list: []const Value,

    fn text(v: Value) ?[]const u8 {
        return switch (v) {
            .atom, .string => |s| s,
            else => null,
        };
    }
};

const ValueParser = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpaces(p: *ValueParser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    /// The next value; null at the end of the input or of the list being read.
    fn next(p: *ValueParser, a: Allocator) error{ OutOfMemory, BadResponse }!?Value {
        p.skipSpaces();
        if (p.i >= p.s.len or p.s[p.i] == ')') return null;
        switch (p.s[p.i]) {
            '(' => {
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                while (try p.next(a)) |v| try items.append(a, v);
                if (p.i >= p.s.len) return error.BadResponse;
                p.i += 1;
                return .{ .list = items.items };
            },
            '"' => {
                p.i += 1;
                var out: std.ArrayList(u8) = .empty;
                while (p.i < p.s.len and p.s[p.i] != '"') : (p.i += 1) {
                    if (p.s[p.i] == '\\' and p.i + 1 < p.s.len) p.i += 1;
                    try out.append(a, p.s[p.i]);
                }
                if (p.i >= p.s.len) return error.BadResponse;
                p.i += 1;
                return .{ .string = out.items };
            },
            '{' => {
                // a literal: "{12}\r\n" and then exactly 12 bytes
                const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '}') orelse return error.BadResponse;
                const n = std.fmt.parseUnsigned(usize, p.s[p.i + 1 .. close], 10) catch return error.BadResponse;
                const start = close + 3;
                if (!std.mem.startsWith(u8, p.s[close + 1 ..], "\r\n") or start + n > p.s.len) return error.BadResponse;
                p.i = start + n;
                return .{ .string = p.s[start..p.i] };
            },
            else => {
                const start = p.i;
                while (p.i < p.s.len and p.s[p.i] != ' ' and p.s[p.i] != '(' and p.s[p.i] != ')') p.i += 1;
                const atom = p.s[start..p.i];
                return if (std.ascii.eqlIgnoreCase(atom, "NIL")) .nil else .{ .atom = atom };
            },
        }
    }
};

/// One message of a FETCH response.
const Fetch = struct {
    uid: ?u32 = null,
    seen: bool = false,
    /// (date subject from sender reply-to to cc bcc in-reply-to message-id)
    envelope: ?[]const Value = null,
    /// the whole message, when RFC822 was asked for
    body: ?[]const u8 = null,
};

/// `line` is an untagged response without its CRLF ("* 12 FETCH (…)"); null when it is not a FETCH.
fn parseFetch(a: Allocator, line: []const u8) error{ OutOfMemory, BadResponse }!?Fetch {
    var p: ValueParser = .{ .s = line };
    const star = try p.next(a) orelse return null;
    if (star != .atom or !std.mem.eql(u8, star.atom, "*")) return null;
    _ = try p.next(a) orelse return null;
    const kind = try p.next(a) orelse return null;
    if (kind != .atom or !std.ascii.eqlIgnoreCase(kind.atom, "FETCH")) return null;
    const data = try p.next(a) orelse return error.BadResponse;
    if (data != .list) return error.BadResponse;
    var f: Fetch = .{};
    var i: usize = 0;
    while (i + 1 < data.list.len) : (i += 2) {
        const key = data.list[i].text() orelse continue;
        const v = data.list[i + 1];
        if (std.ascii.eqlIgnoreCase(key, "UID")) {
            if (v.text()) |t| f.uid = std.fmt.parseUnsigned(u32, t, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(key, "FLAGS")) {
            if (v == .list) for (v.list) |flag| {
                if (flag.text()) |t| if (std.ascii.eqlIgnoreCase(t, "\\Seen")) {
                    f.seen = true;
                };
            };
        } else if (std.ascii.eqlIgnoreCase(key, "ENVELOPE")) {
            if (v == .list) f.envelope = v.list;
        } else if (std.ascii.eqlIgnoreCase(key, "RFC822") or std.ascii.eqlIgnoreCase(key, "BODY[]")) {
            if (v == .string) f.body = v.string;
        }
    }
    return f;
}

/// The size of the literal a response line announces at its end ("… {123}\r"), if it does.
fn literalSize(line: []const u8) ?usize {
    const l = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    if (l.len < 3 or l[l.len - 1] != '}') return null;
    const open = std.mem.lastIndexOfScalar(u8, l, '{') orelse return null;
    return std.fmt.parseUnsigned(usize, l[open + 1 .. l.len - 1], 10) catch null;
}

/// `s` as an IMAP quoted string.
fn quote(a: Allocator, s: []const u8) ![]u8 {
    // a line break would end the command
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return error.InvalidCharacter;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (s) |ch| {
        if (ch == '\\' or ch == '"') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '"');
    return out.items;
}

/// The IMAP conversation over a byte stream: the TLS connection, or a fixture in the tests.
const Imap = struct {
    r: *Io.Reader,
    w: *Io.Writer,
    /// what `w` writes into, when it has to be flushed too (the socket under TLS)
    under: ?*Io.Writer = null,
    tag: u32 = 0,

    /// One response as the server sent it, without the final CRLF. A response that carries
    /// literals spans several lines: "{n}\r\n", n raw bytes, then the rest.
    fn readResponse(self: *Imap, a: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(a);
        while (true) {
            _ = try self.r.streamDelimiter(&aw.writer, '\n');
            self.r.toss(1);
            const n = literalSize(aw.written()) orelse break;
            try aw.writer.writeByte('\n');
            try self.r.streamExact(&aw.writer, n);
        }
        const line = aw.written();
        return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    }

    /// Sends a command and reads up to its tagged reply. Returns the untagged responses that
    /// came before it; NO and BAD fail with the server's explanation in `fail`.
    fn command(self: *Imap, a: Allocator, fail: *core.Fail, comptime fmt: []const u8, args: anytype) ![]const []const u8 {
        self.tag += 1;
        try self.w.print("a{d} " ++ fmt ++ "\r\n", .{self.tag} ++ args);
        try self.w.flush();
        if (self.under) |u| try u.flush();
        var tag_buf: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "a{d} ", .{self.tag}) catch unreachable;
        var lines: std.ArrayList([]const u8) = .empty;
        while (true) {
            const line = try self.readResponse(a);
            if (!std.mem.startsWith(u8, line, tag)) {
                try lines.append(a, line);
                continue;
            }
            const status = line[tag.len..];
            if (std.ascii.startsWithIgnoreCase(status, "OK")) return lines.items;
            const no = std.ascii.startsWithIgnoreCase(status, "NO");
            if (!no and !std.ascii.startsWithIgnoreCase(status, "BAD")) return error.BadResponse;
            // "NO [CODE] explanation"
            var info = std.mem.trimStart(u8, status[if (no) 2 else 3..], " ");
            if (info.len > 0 and info[0] == '[') {
                if (std.mem.indexOfScalar(u8, info, ']')) |end| info = std.mem.trimStart(u8, info[end + 1 ..], " ");
            }
            if (info.len == 0) info = "no explanation given";
            return fail.set(a, "{s} Response: {s}", .{ if (no) "No" else "Bad", info });
        }
    }

    fn login(self: *Imap, a: Allocator, fail: *core.Fail, email: []const u8, password: []const u8) !void {
        _ = try self.command(a, fail, "LOGIN {s} {s}", .{ try quote(a, email), try quote(a, password) });
    }

    /// Opens the mailbox read-only; returns how many messages it holds.
    fn examine(self: *Imap, a: Allocator, fail: *core.Fail, mailbox: []const u8) !u32 {
        const lines = try self.command(a, fail, "EXAMINE {s}", .{try quote(a, mailbox)});
        var exists: u32 = 0;
        for (lines) |line| {
            // "* 23 EXISTS"
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            _ = it.next();
            const n = it.next() orelse continue;
            if (std.ascii.eqlIgnoreCase(it.next() orelse continue, "EXISTS")) exists = std.fmt.parseUnsigned(u32, n, 10) catch exists;
        }
        return exists;
    }

    /// `FETCH` (message numbers) or `UID FETCH` (UIDs) of `set`.
    fn fetch(self: *Imap, a: Allocator, fail: *core.Fail, by_uid: bool, set: []const u8, query: []const u8) ![]const Fetch {
        if (set.len == 0) return &.{};
        const lines = try self.command(a, fail, "{s}FETCH {s} {s}", .{ if (by_uid) "UID " else "", set, query });
        var out: std.ArrayList(Fetch) = .empty;
        for (lines) |line| if (try parseFetch(a, line)) |f| try out.append(a, f);
        return out.items;
    }

    /// The UIDs matching `query` ("UID 1:41"), in the server's order, each once.
    fn uidSearch(self: *Imap, a: Allocator, fail: *core.Fail, comptime query: []const u8, args: anytype) ![]u32 {
        const lines = try self.command(a, fail, "UID SEARCH " ++ query, args);
        var out: std.ArrayList(u32) = .empty;
        for (lines) |line| {
            // "* SEARCH 2 84 882"
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            _ = it.next();
            if (!std.ascii.eqlIgnoreCase(it.next() orelse continue, "SEARCH")) continue;
            while (it.next()) |t| {
                const uid = std.fmt.parseUnsigned(u32, t, 10) catch continue;
                if (std.mem.indexOfScalar(u32, out.items, uid) == null) try out.append(a, uid);
            }
        }
        return out.items;
    }
};

// ---------------- the connection ----------------

var ca_mutex: core.Mutex = .{};
var ca_lock: Io.RwLock = .init;
var ca_bundle: std.crypto.Certificate.Bundle = .empty;
var ca_loaded = false;

/// The system's root certificates, read once.
fn loadRoots() !void {
    ca_mutex.lock();
    defer ca_mutex.unlock();
    if (ca_loaded) return;
    try ca_bundle.rescan(core.gpa, core.io, Io.Clock.real.now(core.io));
    ca_loaded = true;
}

const Session = struct {
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    tls: std.crypto.tls.Client,
    imap: Imap,
    buffers: []u8,

    const tls_len = std.crypto.tls.Client.min_buffer_len;
    /// decrypted bytes waiting to be read / written
    const plain_read_len = tls_len + 16 * 1024;
    const plain_write_len = 4 * 1024;

    /// TCP + TLS to imap.gmail.com and the server's greeting.
    fn open() !*Session {
        try loadRoots();
        const host: Io.net.HostName = try .init(HOST);
        const stream = try host.connect(core.io, PORT, .{ .mode = .stream });
        errdefer stream.close(core.io);
        const s = try core.gpa.create(Session);
        errdefer core.gpa.destroy(s);
        const buffers = try core.gpa.alloc(u8, 2 * tls_len + plain_read_len + plain_write_len);
        errdefer core.gpa.free(buffers);
        s.stream = stream;
        s.buffers = buffers;
        s.reader = stream.reader(core.io, buffers[0..tls_len]);
        s.writer = stream.writer(core.io, buffers[tls_len..][0..tls_len]);
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        core.io.random(&entropy);
        s.tls = try std.crypto.tls.Client.init(&s.reader.interface, &s.writer.interface, .{
            .host = .{ .explicit = HOST },
            .ca = .{ .bundle = .{ .gpa = core.gpa, .io = core.io, .lock = &ca_lock, .bundle = &ca_bundle } },
            .read_buffer = buffers[2 * tls_len ..][0..plain_read_len],
            .write_buffer = buffers[2 * tls_len + plain_read_len ..],
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(core.io),
        });
        s.imap = .{ .r = &s.tls.reader, .w = &s.tls.writer, .under = &s.writer.interface };
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const greeting = try s.imap.readResponse(arena.allocator());
        if (!std.mem.startsWith(u8, greeting, "* ")) return error.BadResponse;
        return s;
    }

    fn close(s: *Session) void {
        s.stream.close(core.io);
        core.gpa.free(s.buffers);
        core.gpa.destroy(s);
    }
};

fn connect(a: Allocator, fail: *core.Fail, email: []const u8, password: []const u8) !*Session {
    const s = Session.open() catch |e|
        return fail.set(a, "{s}: {s}", .{ tr("could not connect to imap.gmail.com", "không kết nối được tới imap.gmail.com"), @errorName(e) });
    errdefer s.close();
    s.imap.login(a, fail, email, password) catch |e| {
        const detail = fail.text(e);
        if (std.mem.indexOf(u8, detail, "Application-specific password required") != null) {
            return fail.set(a, "{s}", .{tr(
                "This is your normal Google password. Gmail only accepts an app password: follow steps 1–2 below to create one, then paste the 16-character code into the password box.",
                "Đây là mật khẩu Google thường. Gmail chỉ nhận mật khẩu ứng dụng: làm theo bước 1–2 bên dưới để tạo, rồi dán mã 16 ký tự vào ô mật khẩu.",
            )});
        } else if (std.mem.indexOf(u8, detail, "Invalid credentials") != null) {
            return fail.set(a, "{s}", .{tr(
                "Wrong email or app password. Check them, or create a new app password.",
                "Sai email hoặc mật khẩu ứng dụng. Kiểm tra lại, hoặc tạo mật khẩu ứng dụng mới.",
            )});
        }
        return fail.set(a, "{s} {s}", .{ tr("Gmail refused the sign-in:", "Gmail từ chối đăng nhập:"), detail });
    };
    return s;
}

// ---------------- the shared connection ----------------

var session_mutex: core.Mutex = .{};
var session: ?*Session = null;

var bodies_mutex: core.Mutex = .{};
/// owns `bodies` and every string in it
var bodies_arena: ?std.heap.ArenaAllocator = null;
var bodies: std.AutoHashMapUnmanaged(u32, MailBody) = .empty;

fn clearBodies() void {
    bodies_mutex.lock();
    defer bodies_mutex.unlock();
    if (bodies_arena) |*arena| arena.deinit();
    bodies_arena = null;
    bodies = .empty;
}

fn cloneBody(a: Allocator, b: MailBody) !MailBody {
    const attachments = try a.alloc([]const u8, b.attachments.len);
    for (attachments, b.attachments) |*dst, src| dst.* = try a.dupe(u8, src);
    return .{
        .uid = b.uid,
        .from = try a.dupe(u8, b.from),
        .to = try a.dupe(u8, b.to),
        .subject = try a.dupe(u8, b.subject),
        .date = b.date,
        .html = if (b.html) |h| try a.dupe(u8, h) else null,
        .text = if (b.text) |t| try a.dupe(u8, t) else null,
        .attachments = attachments,
    };
}

fn Payload(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload;
}

/// Runs `f(imap, a, fail, args…)` on the open connection (INBOX examined). If the kept connection
/// fails (Gmail drops idle ones), it is replaced by a fresh one and `f` runs once more.
fn withInbox(a: Allocator, fail: *core.Fail, comptime f: anytype, args: anytype) !Payload(f) {
    session_mutex.lock();
    defer session_mutex.unlock();
    if (session) |s| {
        if (@call(.auto, f, .{ &s.imap, a, fail } ++ args)) |v| return v else |_| {}
        s.close();
        session = null;
    }
    const account = savedAccount(a) orelse return fail.set(a, "{s}", .{tr("not signed in to Gmail", "chưa đăng nhập Gmail")});
    const s = try connect(a, fail, account.email, account.password);
    errdefer s.close();
    _ = try s.imap.examine(a, fail, "INBOX");
    const v = try @call(.auto, f, .{ &s.imap, a, fail } ++ args);
    session = s;
    return v;
}

/// What the page is told when `e` came out of an IMAP call.
fn failed(c: *ipc.Call, fail: *const core.Fail, e: anyerror) error{Failed} {
    return c.failMsg(fail.text(e));
}

// ---------------- parsing ----------------

fn header(a: Allocator, part: *const mail.Part, name: []const u8) ![]const u8 {
    return try part.header(a, name) orelse "";
}

fn dateMs(a: Allocator, part: *const mail.Part) !i64 {
    const d = try part.header(a, "Date") orelse return 0;
    return (mail.dateparse(d) orelse return 0) * 1000;
}

/// Envelope fields come raw, possibly RFC 2047 encoded ("=?UTF-8?B?...?="): decode them as a header would be.
fn decode(a: Allocator, v: Value) ![]const u8 {
    const raw = v.text() orelse return "";
    const line = try std.mem.concat(a, u8, &.{ "X: ", raw });
    const h = mail.parseHeader(line) catch return std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(raw)});
    return h.header.value(a);
}

/// The file name an attachment part gives itself.
fn attachmentName(part: *const mail.Part, disposition: mail.Disposition) ?[]const u8 {
    return disposition.params.get("filename") orelse part.ctype.params.get("name");
}

const Content = struct {
    html: ?[]const u8 = null,
    text: ?[]const u8 = null,
    attachments: std.ArrayList([]const u8) = .empty,
};

/// First text/html and text/plain parts, plus attachment file names.
fn walk(a: Allocator, part: *const mail.Part, out: *Content) Allocator.Error!void {
    const disposition = try part.disposition(a);
    if (disposition.attachment) {
        try out.attachments.append(a, attachmentName(part, disposition) orelse tr("(no name)", "(không tên)"));
        return;
    }
    if (part.subparts.len == 0) {
        const slot = if (std.mem.eql(u8, part.ctype.mimetype, "text/html"))
            &out.html
        else if (std.mem.eql(u8, part.ctype.mimetype, "text/plain"))
            &out.text
        else
            return;
        if (slot.* == null) slot.* = part.body(a) catch |e| switch (e) {
            error.OutOfMemory => |x| return x,
            error.InvalidBase64 => null,
        };
        return;
    }
    for (part.subparts) |*p| try walk(a, p, out);
}

// ---------------- commands ----------------

/// The signed-in address, or null.
pub fn gmail_state(c: *ipc.Call) !?[]const u8 {
    return if (savedAccount(c.arena)) |account| account.email else null;
}

/// Checks the address + app password against Gmail, then saves them.
pub fn gmail_login(c: *ipc.Call, args: struct { email: []const u8, password: []const u8 }) ![]const u8 {
    const a = c.arena;
    const email = trim(args.email);
    // Google shows app passwords as "abcd efgh ijkl mnop"
    var password: std.ArrayList(u8) = .empty;
    var it: std.unicode.Utf8Iterator = .{ .bytes = args.password, .i = 0 };
    while (it.nextCodepointSlice()) |ch| {
        if (!isWhitespace(std.unicode.utf8Decode(ch) catch 0)) try password.appendSlice(a, ch);
    }
    if (email.len == 0 or password.items.len == 0)
        return c.failMsg(tr("Enter the email and app password", "Nhập email và mật khẩu ứng dụng"));

    var fail: core.Fail = .{};
    const s = connect(a, &fail, email, password.items) catch |e| return failed(c, &fail, e);
    _ = s.imap.examine(a, &fail, "INBOX") catch |e| {
        s.close();
        return failed(c, &fail, e);
    };
    session_mutex.lock();
    if (session) |old| old.close();
    session = s;
    session_mutex.unlock();
    clearBodies();

    const sealed = if (@hasDecl(m.secure, "sealStr")) try m.secure.sealStr(a, password.items) else return error.SecureModuleMissing;
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{ .email = email, .password = sealed }, .{ .whitespace = .indent_2 }, &aw.writer);
    try core.writeFile(try accountFile(a), aw.written());
    return email;
}

pub fn gmail_logout(c: *ipc.Call) !void {
    const a = c.arena;
    session_mutex.lock();
    if (session) |s| {
        var fail: core.Fail = .{};
        _ = s.imap.command(a, &fail, "LOGOUT", .{}) catch {};
        s.close();
        session = null;
    }
    session_mutex.unlock();
    clearBodies();
    Io.Dir.cwd().deleteFile(core.io, try accountFile(a)) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

fn summary(a: Allocator, f: Fetch) !?MailSummary {
    const env = f.envelope orelse return null;
    const uid = f.uid orelse return null;
    // the first address of From: (name route mailbox host)
    const sender: ?[]const Value = if (env.len > 2 and env[2] == .list and env[2].list.len > 0 and env[2].list[0] == .list and env[2].list[0].list.len >= 4)
        env[2].list[0].list
    else
        null;
    const addr: []const u8 = if (sender) |s| try std.fmt.allocPrint(a, "{s}@{s}", .{ try decode(a, s[2]), try decode(a, s[3]) }) else "";
    const name = if (sender) |s| try decode(a, s[0]) else "";
    const date: i64 = if (env.len > 0) blk: {
        const raw = env[0].text() orelse break :blk 0;
        const lossy = try std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(raw)});
        break :blk (mail.dateparse(lossy) orelse 0) * 1000;
    } else 0;
    return .{
        .uid = uid,
        .from = if (name.len > 0) name else addr,
        .fromAddr = addr,
        .subject = if (env.len > 1) try decode(a, env[1]) else "",
        .date = date,
        .seen = f.seen,
    };
}

fn listPage(imap: *Imap, a: Allocator, fail: *core.Fail, before: ?u32) ![]MailSummary {
    const fetched = if (before) |b| blk: {
        if (b <= 1) return &.{};
        const uids = try imap.uidSearch(a, fail, "UID 1:{d}", .{b - 1});
        if (uids.len == 0) return &.{};
        std.mem.sort(u32, uids, {}, std.sort.desc(u32));
        var set: std.ArrayList(u8) = .empty;
        for (uids[0..@min(uids.len, PAGE_SIZE)], 0..) |uid, i| {
            if (i > 0) try set.append(a, ',');
            try set.print(a, "{d}", .{uid});
        }
        break :blk try imap.fetch(a, fail, true, set.items, "(UID FLAGS ENVELOPE)");
    } else blk: {
        // re-EXAMINE: picks up mail that arrived since the last call
        const exists = try imap.examine(a, fail, "INBOX");
        if (exists == 0) return &.{};
        const first = @max(exists -| (PAGE_SIZE - 1), 1);
        break :blk try imap.fetch(a, fail, false, try std.fmt.allocPrint(a, "{d}:{d}", .{ first, exists }), "(UID FLAGS ENVELOPE)");
    };
    var list: std.ArrayList(MailSummary) = .empty;
    for (fetched) |f| if (try summary(a, f)) |s| try list.append(a, s);
    return list.items;
}

/// One page of the inbox, newest first: the newest `PAGE_SIZE` messages, or with `before` (a UID)
/// the `PAGE_SIZE` messages just older than it.
pub fn gmail_list(c: *ipc.Call, args: struct { before: ?u32 = null }) ![]MailSummary {
    var fail: core.Fail = .{};
    const list = withInbox(c.arena, &fail, listPage, .{args.before}) catch |e| return failed(c, &fail, e);
    std.mem.sort(MailSummary, list, {}, struct {
        fn newer(_: void, x: MailSummary, y: MailSummary) bool {
            return x.uid > y.uid;
        }
    }.newer);
    return list;
}

/// The whole message (RFC822). Read-only: EXAMINE keeps it unread in Gmail.
fn fetchRaw(imap: *Imap, a: Allocator, fail: *core.Fail, uid: u32) ![]const u8 {
    const fetched = try imap.fetch(a, fail, true, try std.fmt.allocPrint(a, "{d}", .{uid}), "RFC822");
    for (fetched) |f| if (f.body) |b| return b;
    return fail.set(a, "{s}", .{tr("message not found", "không tìm thấy thư")});
}

fn parseMail(c: *ipc.Call, raw: []const u8) !mail.Part {
    return mail.parse(c.arena, raw) catch |e| switch (e) {
        error.OutOfMemory => |x| return x,
        error.InvalidMail => return c.failMsg(tr("this message could not be read", "không đọc được thư này")),
    };
}

/// One message's content. Read-only: the inbox is opened with EXAMINE, so it stays unread in Gmail.
pub fn gmail_read(c: *ipc.Call, args: struct { uid: u32 }) !MailBody {
    const a = c.arena;
    {
        bodies_mutex.lock();
        defer bodies_mutex.unlock();
        if (bodies.get(args.uid)) |cached| return cloneBody(a, cached);
    }
    var fail: core.Fail = .{};
    const raw = withInbox(a, &fail, fetchRaw, .{args.uid}) catch |e| return failed(c, &fail, e);
    const msg = try parseMail(c, raw);
    var content: Content = .{};
    try walk(a, &msg, &content);
    const body: MailBody = .{
        .uid = args.uid,
        .from = try header(a, &msg, "From"),
        .to = try header(a, &msg, "To"),
        .subject = try header(a, &msg, "Subject"),
        .date = try dateMs(a, &msg),
        .html = content.html,
        .text = content.text,
        .attachments = content.attachments.items,
    };
    bodies_mutex.lock();
    defer bodies_mutex.unlock();
    if (bodies_arena == null) bodies_arena = .init(core.gpa);
    const keep = bodies_arena.?.allocator();
    try bodies.put(keep, args.uid, try cloneBody(keep, body));
    return body;
}

pub const MailContext = struct {
    file: []const u8,
    files: []const []const u8,
};

/// Writes each attachment of the message into `out`, collecting the saved paths.
fn saveAttachments(a: Allocator, part: *const mail.Part, out: []const u8, files: *std.ArrayList([]const u8)) !void {
    const disposition = try part.disposition(a);
    if (disposition.attachment) {
        const name = attachmentName(part, disposition) orelse try std.fmt.allocPrint(a, "file-{d}", .{files.items.len + 1});
        const safe: []const u8 = if (@hasDecl(m.zalo_tasks, "safeName")) try m.zalo_tasks.safeName(a, name) else std.fs.path.basename(name);
        const path = try std.fs.path.join(a, &.{ out, safe });
        const bytes = part.bodyRaw(a) catch |e| switch (e) {
            error.OutOfMemory => |x| return x,
            error.InvalidBase64 => return,
        };
        core.writeFile(path, bytes) catch return;
        try files.append(a, path);
        return;
    }
    for (part.subparts) |*p| try saveAttachments(a, p, out, files);
}

/// Everything a coding chat needs about one email (like a Zalo task's context): a Markdown file with
/// its headers and text, with its attachments (and its HTML when it has no plain text) saved next to it.
pub fn gmail_task_context(c: *ipc.Call, args: struct { uid: u32 }) !MailContext {
    const a = c.arena;
    var fail: core.Fail = .{};
    const raw = withInbox(a, &fail, fetchRaw, .{args.uid}) catch |e| return failed(c, &fail, e);
    const msg = try parseMail(c, raw);
    const out = try core.dataPath(a, &.{ "gmail", "context", try std.fmt.allocPrint(a, "{d}", .{args.uid}) });
    Io.Dir.cwd().deleteTree(core.io, out) catch {};
    try core.makePath(out);
    var content: Content = .{};
    try walk(a, &msg, &content);
    var files: std.ArrayList([]const u8) = .empty;
    try saveAttachments(a, &msg, out, &files);
    const body: []const u8 = if (content.text) |t| t else if (content.html) |h| blk: {
        const path = try std.fs.path.join(a, &.{ out, "mail.html" });
        try core.writeFile(path, h);
        break :blk try std.fmt.allocPrint(a, "(Thư chỉ có bản HTML, đọc file: {s})", .{path});
    } else "(thư không có nội dung)";
    const md = try contextMarkdown(a, .{
        .subject = try header(a, &msg, "Subject"),
        .from = try header(a, &msg, "From"),
        .to = try header(a, &msg, "To"),
        .date = try header(a, &msg, "Date"),
        .body = body,
        .files = files.items,
    });
    const file = try std.fs.path.join(a, &.{ out, "context.md" });
    try core.writeFile(file, md);
    return .{ .file = file, .files = files.items };
}

fn contextMarkdown(a: Allocator, x: struct {
    subject: []const u8,
    from: []const u8,
    to: []const u8,
    date: []const u8,
    body: []const u8,
    files: []const []const u8,
}) ![]u8 {
    var lf: std.ArrayList(u8) = .empty;
    if (x.files.len > 0) {
        try lf.appendSlice(a, "- Tệp đính kèm:");
        for (x.files) |p| try lf.print(a, "\n  - {s}", .{p});
        try lf.append(a, '\n');
    }
    return std.fmt.allocPrint(
        a,
        "# Việc từ Gmail: {s}\n\n**Hướng dẫn cho bạn (Claude):** Đây là một việc tôi nhận qua email. Hãy đọc kỹ thư bên dưới{s}, rồi tìm hiểu code trong project hiện tại liên quan tới yêu cầu. Sau đó tóm tắt lại yêu cầu bằng tiếng Việt, nêu nguyên nhân / vị trí code liên quan và đề xuất cách xử lý. CHƯA sửa code cho tới khi tôi xác nhận.\n\n- Người gửi: {s}\n- Gửi tới: {s}\n- Thời gian: {s}\n- Tiêu đề: {s}\n{s}\n## Nội dung thư\n\n{s}\n",
        .{ x.subject, if (x.files.len == 0) "" else " và mở các tệp đính kèm", x.from, x.to, x.date, x.subject, lf.items, x.body },
    );
}

pub const commands = .{
    .{ "gmail_state", gmail_state },
    .{ "gmail_login", gmail_login },
    .{ "gmail_logout", gmail_logout },
    .{ "gmail_list", gmail_list },
    .{ "gmail_read", gmail_read },
    .{ "gmail_task_context", gmail_task_context },
};

// ---------------- tests ----------------

const testing = std.testing;

test {
    _ = mail;
    _ = @import("text.zig");
}

/// An `Imap` that reads a canned server transcript and records what the client sent.
const Fixture = struct {
    reader: Io.Reader,
    sent: Io.Writer.Allocating,
    imap: Imap,

    fn init(f: *Fixture, a: Allocator, server: []const u8) void {
        f.reader = .fixed(server);
        f.sent = .init(a);
        f.imap = .{ .r = &f.reader, .w = &f.sent.writer };
    }
};

test "IMAP values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p: ValueParser = .{ .s = "12 (\\Seen $x) \"a \\\"b\\\" \\\\\" NIL nil {5}\r\nh(\"lo ((x) ()) tail" };
    try testing.expectEqualStrings("12", (try p.next(a)).?.atom);
    const flags = (try p.next(a)).?.list;
    try testing.expectEqual(@as(usize, 2), flags.len);
    try testing.expectEqualStrings("\\Seen", flags[0].atom);
    try testing.expectEqualStrings("a \"b\" \\", (try p.next(a)).?.string);
    try testing.expect((try p.next(a)).? == .nil);
    try testing.expect((try p.next(a)).? == .nil);
    try testing.expectEqualStrings("h(\"lo", (try p.next(a)).?.string);
    const nested = (try p.next(a)).?.list;
    try testing.expectEqual(@as(usize, 2), nested.len);
    try testing.expectEqualStrings("x", nested[0].list[0].atom);
    try testing.expectEqual(@as(usize, 0), nested[1].list.len);
    try testing.expectEqualStrings("tail", (try p.next(a)).?.atom);
    try testing.expect(try p.next(a) == null);

    for ([_][]const u8{ "(a b", "\"open", "{5}\r\nabc", "{x}\r\nabc", "{3}abc" }) |bad| {
        var bp: ValueParser = .{ .s = bad };
        try testing.expectError(error.BadResponse, bp.next(a));
    }

    try testing.expectEqual(@as(?usize, 123), literalSize("* 1 FETCH (RFC822 {123}\r"));
    try testing.expectEqual(@as(?usize, 0), literalSize("x {0}"));
    try testing.expectEqual(@as(?usize, null), literalSize("* 1 FETCH (UID 2)\r"));
    try testing.expectEqual(@as(?usize, null), literalSize("{12} more\r"));
    try testing.expectEqual(@as(?usize, null), literalSize("{}\r"));

    try testing.expectEqualStrings("\"a\\\\b\\\"c d\"", try quote(a, "a\\b\"c d"));
    try testing.expectError(error.InvalidCharacter, quote(a, "a\r\nb"));
}

test "IMAP: commands, tagged and untagged replies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    var f: Fixture = undefined;
    f.init(a, "* OK Gimap ready\r\n" ++
        "* CAPABILITY IMAP4rev1\r\n" ++
        "a1 OK user@example.com authenticated (Success)\r\n" ++
        "* FLAGS (\\Answered \\Seen)\r\n" ++
        "* 42 EXISTS\r\n" ++
        "* 0 RECENT\r\n" ++
        "* OK [UIDNEXT 99] Predicted next UID.\r\n" ++
        "a2 OK [READ-ONLY] INBOX selected. (Success)\r\n" ++
        "* SEARCH 5 9 7\r\n" ++
        "* SEARCH 9 12\r\n" ++
        "a3 OK SEARCH completed (Success)\r\n" ++
        "a4 OK nothing found\r\n" ++
        "* BYE LOGOUT Requested\r\n" ++
        "a5 OK 73 good day (Success)\r\n");
    try testing.expectEqualStrings("* OK Gimap ready", try f.imap.readResponse(a));
    try f.imap.login(a, &fail, "user@example.com", "ab\"cd");
    try testing.expectEqual(@as(u32, 42), try f.imap.examine(a, &fail, "INBOX"));
    try testing.expectEqualSlices(u32, &.{ 5, 9, 7, 12 }, try f.imap.uidSearch(a, &fail, "UID 1:{d}", .{40}));
    try testing.expectEqual(@as(usize, 0), (try f.imap.uidSearch(a, &fail, "UID 1:{d}", .{3})).len);
    _ = try f.imap.command(a, &fail, "LOGOUT", .{});
    try testing.expectEqualStrings("a1 LOGIN \"user@example.com\" \"ab\\\"cd\"\r\n" ++
        "a2 EXAMINE \"INBOX\"\r\n" ++
        "a3 UID SEARCH UID 1:40\r\n" ++
        "a4 UID SEARCH UID 1:3\r\n" ++
        "a5 LOGOUT\r\n", f.sent.written());
    // the server hung up
    try testing.expectError(error.EndOfStream, f.imap.command(a, &fail, "NOOP", .{}));
}

test "IMAP: NO, BAD and a dropped connection" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    var f: Fixture = undefined;
    f.init(a, "a1 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n" ++
        "a2 NO [ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)\r\n" ++
        "a3 BAD Could not parse command\r\n" ++
        "a4 NO\r\n" ++
        "* BYE going away\r\n" ++
        "a5 PREAUTH what\r\n" ++
        "* 3 EXISTS\r\nhalf a li");
    try testing.expectError(error.Failed, f.imap.login(a, &fail, "u", "p"));
    try testing.expectEqualStrings("No Response: Invalid credentials (Failure)", fail.msg);
    try testing.expectError(error.Failed, f.imap.login(a, &fail, "u", "p"));
    try testing.expectEqualStrings("No Response: Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)", fail.msg);
    try testing.expectError(error.Failed, f.imap.command(a, &fail, "WHAT", .{}));
    try testing.expectEqualStrings("Bad Response: Could not parse command", fail.msg);
    try testing.expectError(error.Failed, f.imap.command(a, &fail, "WHAT", .{}));
    try testing.expectEqualStrings("No Response: no explanation given", fail.msg);
    try testing.expectError(error.BadResponse, f.imap.command(a, &fail, "WHAT", .{}));
    try testing.expectError(error.EndOfStream, f.imap.command(a, &fail, "WHAT", .{}));
    try testing.expectError(error.InvalidCharacter, f.imap.login(a, &fail, "u\r\na9 DELETE x", "p"));
}

const envelope_fixture = "* 41 FETCH (UID 1001 FLAGS (\\Seen) ENVELOPE (\"Sun, 02 Oct 2016 07:06:22 -0700 (PDT)\" \"=?UTF-8?B?WGluIGNow6BvIFZp4buHdCBOYW0=?=\" " ++
    "((\"=?UTF-8?B?Tmd1eeG7hW4gVsSDbiBB?=\" NIL \"a\" \"example.com\")) ((\"x\" NIL \"a\" \"example.com\")) ((NIL NIL \"a\" \"example.com\")) " ++
    "((NIL NIL \"me\" \"gmail.com\")) NIL NIL NIL \"<id-1@example.com>\"))\r\n" ++
    // a subject sent as a literal, with quotes and a line break folded in; no display name; unread
    "* 42 FETCH (ENVELOPE (\"1 Jan 2024 00:00:00 +0000\" {20}\r\nHe said \"hi\"\r\n there((NIL NIL \"bob\" \"example.org\")) NIL NIL NIL NIL NIL NIL NIL) FLAGS () UID 1002)\r\n" ++
    // no From, no date
    "* 43 FETCH (UID 1003 FLAGS (\\Answered \\Seen) ENVELOPE (NIL \"escaped \\\"quotes\\\"\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n" ++
    // changes pushed by the server in between: no UID / no envelope, not a FETCH
    "* 40 FETCH (FLAGS (\\Seen))\r\n" ++
    "* 44 EXISTS\r\n";

test "list: the newest page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    var f: Fixture = undefined;
    f.init(a, "* 43 EXISTS\r\na1 OK [READ-ONLY] INBOX selected.\r\n" ++ envelope_fixture ++ "a2 OK Success\r\n");
    const list = try listPage(&f.imap, a, &fail, null);
    try testing.expectEqualStrings("a1 EXAMINE \"INBOX\"\r\na2 FETCH 14:43 (UID FLAGS ENVELOPE)\r\n", f.sent.written());
    try testing.expectEqual(@as(usize, 3), list.len);

    try testing.expectEqual(@as(u32, 1001), list[0].uid);
    try testing.expectEqualStrings("Nguyễn Văn A", list[0].from);
    try testing.expectEqualStrings("a@example.com", list[0].fromAddr);
    try testing.expectEqualStrings("Xin chào Việt Nam", list[0].subject);
    try testing.expectEqual(@as(i64, 1475417182000), list[0].date);
    try testing.expect(list[0].seen);

    try testing.expectEqual(@as(u32, 1002), list[1].uid);
    try testing.expectEqualStrings("bob@example.org", list[1].from);
    try testing.expectEqualStrings("bob@example.org", list[1].fromAddr);
    try testing.expectEqualStrings("He said \"hi\" there", list[1].subject);
    try testing.expectEqual(@as(i64, 1704067200000), list[1].date);
    try testing.expect(!list[1].seen);

    try testing.expectEqual(@as(u32, 1003), list[2].uid);
    try testing.expectEqualStrings("", list[2].from);
    try testing.expectEqualStrings("", list[2].fromAddr);
    try testing.expectEqualStrings("escaped \"quotes\"", list[2].subject);
    try testing.expectEqual(@as(i64, 0), list[2].date);
    try testing.expect(list[2].seen);

    const json = try core.toJson(a, list[1]);
    try testing.expectEqualStrings("{\"uid\":1002,\"from\":\"bob@example.org\",\"fromAddr\":\"bob@example.org\",\"subject\":\"He said \\\"hi\\\" there\",\"date\":1704067200000,\"seen\":false}", json);
}

test "list: an empty inbox, a small one, and older pages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    var f: Fixture = undefined;
    f.init(a, "* 0 EXISTS\r\na1 OK done\r\n" ++
        "* 3 EXISTS\r\na2 OK done\r\na3 OK done\r\n" ++
        "* SEARCH 7 3 50 21\r\na4 OK done\r\na5 OK done\r\n" ++
        "* SEARCH\r\na6 OK done\r\n");
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, null)).len);
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, null)).len);
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, 51)).len);
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, 3)).len);
    // nothing is older than the first UID: no command at all
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, 1)).len);
    try testing.expectEqual(@as(usize, 0), (try listPage(&f.imap, a, &fail, 0)).len);
    try testing.expectEqualStrings("a1 EXAMINE \"INBOX\"\r\n" ++
        "a2 EXAMINE \"INBOX\"\r\na3 FETCH 1:3 (UID FLAGS ENVELOPE)\r\n" ++
        "a4 UID SEARCH UID 1:50\r\na5 UID FETCH 50,21,7,3 (UID FLAGS ENVELOPE)\r\n" ++
        "a6 UID SEARCH UID 1:2\r\n", f.sent.written());

    // a page is the PAGE_SIZE newest of what the search found
    var server: std.ArrayList(u8) = .empty;
    try server.appendSlice(a, "* SEARCH");
    for (1..41) |uid| try server.print(a, " {d}", .{uid});
    try server.appendSlice(a, "\r\na1 OK done\r\na2 OK done\r\n");
    f.init(a, server.items);
    _ = try listPage(&f.imap, a, &fail, 41);
    try testing.expect(std.mem.endsWith(u8, f.sent.written(), "a2 UID FETCH 40,39,38,37,36,35,34,33,32,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11 (UID FLAGS ENVELOPE)\r\n"));
}

const message_fixture = "From: =?UTF-8?B?Tmd1eeG7hW4gVsSDbiBB?= <a@example.com>\r\n" ++
    "To: me@gmail.com\r\n" ++
    "Subject: =?UTF-8?Q?B=C3=A1o_c=C3=A1o?=\r\n =?UTF-8?Q?_th=C3=A1ng_10?=\r\n" ++
    "Date: Sun, 02 Oct 2016 07:06:22 -0700 (PDT)\r\n" ++
    "Content-Type: multipart/mixed; boundary=\"outer\"\r\n" ++
    "\r\n" ++
    "--outer\r\n" ++
    "Content-Type: multipart/alternative; boundary=inner\r\n" ++
    "\r\n" ++
    "--inner\r\n" ++
    "Content-Type: text/plain; charset=UTF-8\r\n" ++
    "Content-Transfer-Encoding: quoted-printable\r\n" ++
    "\r\n" ++
    "Ch=C3=A0o b=E1=BA=A1n,\r\nxem t=E1=BB=87p =C4=91=C3=ADnh k=C3=A8m.\r\n" ++
    "--inner\r\n" ++
    "Content-Type: text/html; charset=UTF-8\r\n" ++
    "Content-Transfer-Encoding: base64\r\n" ++
    "\r\n" ++
    "PHA+Q2jDoG8gYuG6oW48L3A+\r\n" ++
    "--inner--\r\n" ++
    "--outer\r\n" ++
    "Content-Type: text/plain; name=\"notes.txt\"\r\n" ++
    "Content-Disposition: attachment; filename*=UTF-8''ghi%20ch%C3%BA.txt\r\n" ++
    "\r\n" ++
    "an attached text file\r\n" ++
    "--outer\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Disposition: attachment\r\n" ++
    "Content-Transfer-Encoding: base64\r\n" ++
    "\r\n" ++
    "AAEC/w==\r\n" ++
    "--outer--\r\n";

var test_env: ?std.process.Environ.Map = null;

/// For tests that reach `tr` (the settings are read from the data folder): a data folder of
/// the tests' own, unless another module's test fixed it first (it is then only read).
fn testInit() !void {
    // the settings and the data folder's path stay allocated for the whole run
    core.gpa = std.heap.smp_allocator;
    core.io = testing.io;
    if (test_env == null) {
        const rel = ".zig-cache/tmp/gmail-test";
        try Io.Dir.cwd().createDirPath(core.io, rel);
        var d = try Io.Dir.cwd().openDir(core.io, rel, .{});
        defer d.close(core.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try d.realPath(core.io, &buf);
        var env: std.process.Environ.Map = .init(core.gpa);
        try env.put("STUDIO_USER_DATA", buf[0..n]);
        test_env = env;
    }
    core.env = &test_env.?;
}

test "read: a message fetched as a literal" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    const server = try std.fmt.allocPrint(a, "* 7 FETCH (UID 1001 RFC822 {{{d}}}\r\n{s} FLAGS (\\Seen))\r\na1 OK Success\r\n" ++
        "* 7 FETCH (UID 1002 FLAGS (\\Seen))\r\na2 OK Success\r\n", .{ message_fixture.len, message_fixture });
    var f: Fixture = undefined;
    f.init(a, server);
    const raw = try fetchRaw(&f.imap, a, &fail, 1001);
    try testing.expectEqualStrings(message_fixture, raw);
    // the server answered, but without the message
    try testing.expectError(error.Failed, fetchRaw(&f.imap, a, &fail, 1002));
    try testing.expectEqualStrings("a1 UID FETCH 1001 RFC822\r\na2 UID FETCH 1002 RFC822\r\n", f.sent.written());

    const msg = try mail.parse(a, raw);
    var content: Content = .{};
    try walk(a, &msg, &content);
    try testing.expectEqualStrings("Chào bạn,\r\nxem tệp đính kèm.", content.text.?);
    try testing.expectEqualStrings("<p>Chào bạn</p>", content.html.?);
    try testing.expectEqual(@as(usize, 2), content.attachments.items.len);
    try testing.expectEqualStrings("ghi chú.txt", content.attachments.items[0]);
    try testing.expectEqualStrings(tr("(no name)", "(không tên)"), content.attachments.items[1]);
    try testing.expectEqualStrings("Nguyễn Văn A <a@example.com>", try header(a, &msg, "From"));
    try testing.expectEqualStrings("Báo cáo tháng 10", try header(a, &msg, "Subject"));
    try testing.expectEqualStrings("", try header(a, &msg, "Cc"));
    try testing.expectEqual(@as(i64, 1475417182000), try dateMs(a, &msg));

    const body: MailBody = .{ .uid = 1, .from = "f", .to = "t", .subject = "s", .date = 2, .html = null, .text = content.text, .attachments = content.attachments.items };
    const copy = try cloneBody(a, body);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{{\"uid\":1,\"from\":\"f\",\"to\":\"t\",\"subject\":\"s\",\"date\":2,\"html\":null,\"text\":\"Chào bạn,\\r\\nxem tệp đính kèm.\",\"attachments\":[\"ghi chú.txt\",\"{s}\"]}}", .{tr("(no name)", "(không tên)")}),
        try core.toJson(a, copy),
    );
}

test "walk: the first text parts win, a broken part is skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const msg = try mail.parse(a, "Content-Type: multipart/mixed; boundary=b\n\n" ++
        "--b\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\n!!!\n" ++
        "--b\nContent-Type: text/plain\n\nsecond\n" ++
        "--b\nContent-Type: text/plain\n\nthird\n" ++
        "--b\nContent-Type: image/png\n\nxx\n" ++
        "--b\nContent-Type: TEXT/HTML\n\n<b>h</b>\n" ++
        "--b--\n");
    var content: Content = .{};
    try walk(a, &msg, &content);
    try testing.expectEqualStrings("second", content.text.?);
    try testing.expectEqualStrings("<b>h</b>", content.html.?);
    try testing.expectEqual(@as(usize, 0), content.attachments.items.len);

    // a message that is only an attachment
    const only = try mail.parse(a, "Content-Type: text/plain\nContent-Disposition: attachment; filename=a.txt\n\nhello");
    content = .{};
    try walk(a, &only, &content);
    try testing.expect(content.text == null and content.html == null);
    try testing.expectEqualStrings("a.txt", content.attachments.items[0]);
}

test "task context: attachments saved next to the Markdown" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const msg = try mail.parse(a, message_fixture);
    var files: std.ArrayList([]const u8) = .empty;
    try saveAttachments(a, &msg, out, &files);
    try testing.expectEqual(@as(usize, 2), files.items.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ out, "ghi chú.txt" }), files.items[0]);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ out, "file-2" }), files.items[1]);
    try testing.expectEqualStrings("an attached text file", try core.readFileAlloc(a, files.items[0], 1 << 20));
    try testing.expectEqualStrings("\x00\x01\x02\xff", try core.readFileAlloc(a, files.items[1], 1 << 20));

    const md = try contextMarkdown(a, .{ .subject = "S", .from = "F", .to = "T", .date = "D", .body = "B", .files = &.{ "p1", "p2" } });
    try testing.expectEqualStrings("# Việc từ Gmail: S\n\n**Hướng dẫn cho bạn (Claude):** Đây là một việc tôi nhận qua email. Hãy đọc kỹ thư bên dưới và mở các tệp đính kèm, rồi tìm hiểu code trong project hiện tại liên quan tới yêu cầu. Sau đó tóm tắt lại yêu cầu bằng tiếng Việt, nêu nguyên nhân / vị trí code liên quan và đề xuất cách xử lý. CHƯA sửa code cho tới khi tôi xác nhận.\n\n" ++
        "- Người gửi: F\n- Gửi tới: T\n- Thời gian: D\n- Tiêu đề: S\n- Tệp đính kèm:\n  - p1\n  - p2\n\n## Nội dung thư\n\nB\n", md);
    const bare = try contextMarkdown(a, .{ .subject = "S", .from = "F", .to = "T", .date = "D", .body = "B", .files = &.{} });
    try testing.expect(std.mem.indexOf(u8, bare, "thư bên dưới, rồi") != null);
    try testing.expect(std.mem.endsWith(u8, bare, "- Tiêu đề: S\n\n## Nội dung thư\n\nB\n"));
}
