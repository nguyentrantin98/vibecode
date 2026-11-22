//! Reading a raw e-mail (RFC 5322 + MIME) for gmail.zig: headers with folding and RFC 2047
//! encoded-words, multipart bodies, base64 / quoted-printable and charsets. It does what the
//! `mailparse` crate did for the Rust build, with the same leniency towards broken mail.
//!
//! Everything returned is allocated in the `a` passed in and never freed piece by piece: use an
//! arena. Slices of a parsed message point into the raw bytes it was parsed from.

const std = @import("std");
const core = @import("core.zig");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;
const isWhitespace = text.isWhitespace;
const trimStart = text.trimStart;
const trimEnd = text.trimEnd;
const trim = text.trim;

pub const Error = error{ OutOfMemory, InvalidMail };

pub const Params = std.StringArrayHashMapUnmanaged([]const u8);

pub const Header = struct {
    key: []const u8,
    /// as in the message: still folded, encoded-words not decoded
    raw: []const u8,

    /// The value on one line, encoded-words decoded, as UTF-8.
    pub fn value(h: Header, a: Allocator) Allocator.Error![]u8 {
        return decodeHeaderValue(a, h.raw);
    }
};

pub const ContentType = struct {
    /// lower-case: "text/plain", "multipart/mixed", …
    mimetype: []const u8 = "text/plain",
    charset: []const u8 = "us-ascii",
    /// keys lower-case, values without their quotes ("boundary", "name", "charset", …)
    params: Params = .empty,
};

pub const Disposition = struct {
    /// `Content-Disposition: attachment` (anything else is shown inline)
    attachment: bool = false,
    params: Params = .empty,
};

/// A message, or one part of a multipart message.
pub const Part = struct {
    headers: []const Header,
    ctype: ContentType,
    /// the body as it is in the message (transfer encoding not undone)
    body_bytes: []const u8,
    /// only multipart/* has any
    subparts: []const Part,

    /// The decoded value of the first header with this name (case-insensitive).
    pub fn header(p: *const Part, a: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return firstValue(a, p.headers, name);
    }

    pub fn disposition(p: *const Part, a: Allocator) Allocator.Error!Disposition {
        const v = try p.header(a, "Content-Disposition") orelse return .{};
        const pc = try parseParamContent(a, v);
        return .{ .attachment = std.ascii.eqlIgnoreCase(pc.value, "attachment"), .params = pc.params };
    }

    /// The body's bytes with the Content-Transfer-Encoding undone (no charset conversion).
    pub fn bodyRaw(p: *const Part, a: Allocator) error{ OutOfMemory, InvalidBase64 }![]u8 {
        if (try p.header(a, "Content-Transfer-Encoding")) |enc| {
            if (std.ascii.eqlIgnoreCase(enc, "base64")) return decodeBase64(a, p.body_bytes, true);
            if (std.ascii.eqlIgnoreCase(enc, "quoted-printable")) return decodeQuotedPrintable(a, p.body_bytes);
        }
        return a.dupe(u8, p.body_bytes);
    }

    /// The body as text: transfer encoding undone, then converted to UTF-8 from the part's
    /// charset (an unknown charset keeps the ASCII and replaces the rest).
    pub fn body(p: *const Part, a: Allocator) error{ OutOfMemory, InvalidBase64 }![]u8 {
        const bytes = try p.bodyRaw(a);
        const cs = charsetForLabel(p.ctype.charset) orelse return decodeAscii(a, bytes);
        // a byte order mark wins over the declared charset
        if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return decodeCharset(a, .utf8, bytes[3..]);
        if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return decodeCharset(a, .utf16le, bytes[2..]);
        if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return decodeCharset(a, .utf16be, bytes[2..]);
        return decodeCharset(a, cs, bytes);
    }
};

/// Parses a whole message (what IMAP returns for RFC822).
pub fn parse(a: Allocator, raw: []const u8) Error!Part {
    return parseRecursive(a, raw, false);
}

fn parseRecursive(a: Allocator, raw: []const u8, in_multipart_digest: bool) Error!Part {
    const hs = try parseHeaders(a, raw);
    const ix_body = hs.end;
    var ctype: ContentType = .{};
    if (try firstValue(a, hs.headers, "Content-Type")) |v| {
        ctype = try parseContentType(a, v);
    } else if (in_multipart_digest) {
        ctype.mimetype = "message/rfc822";
    }
    var result: Part = .{ .headers = hs.headers, .ctype = ctype, .body_bytes = raw[ix_body..], .subparts = &.{} };

    const boundary_param = ctype.params.get("boundary") orelse return result;
    if (!std.mem.startsWith(u8, ctype.mimetype, "multipart/") or raw.len <= ix_body) return result;
    const digest = std.mem.eql(u8, ctype.mimetype, "multipart/digest");
    const boundary = try std.mem.concat(a, u8, &.{ "--", boundary_param });
    const ix_boundary_start = findLinePrefix(raw, ix_body, boundary) orelse return result;
    result.body_bytes = raw[ix_body..stripTrailingCrlf(raw, ix_body, ix_boundary_start)];

    var subparts: std.ArrayList(Part) = .empty;
    var ix_boundary_end = ix_boundary_start + boundary.len;
    while (std.mem.indexOfScalarPos(u8, raw, ix_boundary_end, '\n')) |nl| {
        const ix_part_start = nl + 1;
        const ix_part_boundary_start = findLinePrefix(raw, ix_part_start, boundary);
        // without a closing boundary the part runs to the end of the mail
        const ix_part_end = if (ix_part_boundary_start) |x| stripTrailingCrlf(raw, ix_part_start, x) else raw.len;
        try subparts.append(a, try parseRecursive(a, raw[ix_part_start..ix_part_end], digest));
        ix_boundary_end = if (ix_part_boundary_start) |x| x + boundary.len else raw.len;
        if (ix_boundary_end + 2 > raw.len or (raw[ix_boundary_end] == '-' and raw[ix_boundary_end + 1] == '-')) break;
    }
    result.subparts = subparts.items;
    return result;
}

/// `key` at `start` or at the start of a later line.
fn findLinePrefix(raw: []const u8, start: usize, key: []const u8) ?usize {
    var from = start;
    while (std.mem.indexOfPos(u8, raw, from, key)) |ix| {
        if (ix == start or raw[ix - 1] == '\n') return ix;
        from = ix + 1;
    }
    return null;
}

/// The line break just before a boundary belongs to the boundary, not to the part before it.
fn stripTrailingCrlf(raw: []const u8, start: usize, end: usize) usize {
    var ix = end;
    if (ix > start and raw[ix - 1] == '\n') {
        ix -= 1;
        if (ix > start and raw[ix - 1] == '\r') ix -= 1;
    }
    return ix;
}

// ---------------- headers ----------------

const ParsedHeader = struct { header: Header, next: usize };

/// One header at the start of `raw` (with its folded continuation lines) and where the next one
/// starts.
pub fn parseHeader(raw: []const u8) error{InvalidMail}!ParsedHeader {
    if (raw.len == 0) return error.InvalidMail;
    // an overhanging line from the header before
    if (raw[0] == ' ') return error.InvalidMail;
    var ix: usize = 0;
    var key_end: ?usize = null;
    var value_start: usize = 0;
    var value_end: usize = 0;
    var state: enum { key, pre_value, value, value_newline } = .key;
    while (ix < raw.len) {
        const ch = raw[ix];
        switch (state) {
            .key => if (ch == ':') {
                key_end = ix;
                state = .pre_value;
            } else if (ch == '\n') {
                // no colon on the line: seen in the wild, the line is a key without a value
                key_end = ix;
                value_start = ix;
                value_end = ix;
                ix += 1;
                break;
            },
            .pre_value => if (ch != ' ') {
                value_start = ix;
                value_end = ix;
                state = .value;
                continue;
            },
            .value => if (ch == '\n') {
                state = .value_newline;
            } else if (ch != '\r') {
                value_end = ix + 1;
            },
            .value_newline => if (ch == ' ' or ch == '\t') {
                state = .value;
                continue;
            } else break,
        }
        ix += 1;
    }
    if (key_end) |k| return .{ .header = .{ .key = raw[0..k], .raw = raw[value_start..value_end] }, .next = ix };
    return .{ .header = .{ .key = raw[0..ix], .raw = raw[ix..ix] }, .next = ix };
}

const ParsedHeaders = struct { headers: []const Header, end: usize };

/// The headers at the start of `raw`, up to the empty line; `end` is where the body starts.
pub fn parseHeaders(a: Allocator, raw: []const u8) Error!ParsedHeaders {
    var headers: std.ArrayList(Header) = .empty;
    var ix: usize = 0;
    while (ix < raw.len) {
        if (raw[ix] == '\n') {
            ix += 1;
            break;
        }
        if (raw[ix] == '\r') {
            if (ix + 1 < raw.len and raw[ix + 1] == '\n') {
                ix += 2;
                break;
            }
            return error.InvalidMail;
        }
        const h = try parseHeader(raw[ix..]);
        try headers.append(a, h.header);
        ix += h.next;
    }
    return .{ .headers = headers.items, .end = ix };
}

fn firstValue(a: Allocator, headers: []const Header, name: []const u8) Allocator.Error!?[]u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.key, name)) return try h.value(a);
    return null;
}

const Token = union(enum) {
    text: []const u8,
    whitespace: []const u8,
    newline,
    decoded: []const u8,
};

/// Joins the tokens of a header value: folded lines become one line, and whitespace between two
/// adjacent encoded-words is dropped (RFC 2047 section 6.2).
const Normalizer = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    saved: union(enum) { none, whitespace: []const u8, newline: []const u8, decoded } = .none,

    fn feed(n: *Normalizer, tok: Token) Allocator.Error!void {
        switch (tok) {
            .text => |t| {
                // whitespace held back after an encoded-word: it was not between two of them
                switch (n.saved) {
                    .whitespace, .newline => |ws| try n.out.appendSlice(n.a, ws),
                    else => {},
                }
                try n.out.appendSlice(n.a, t);
                n.saved = .none;
            },
            .whitespace => |ws| if (n.saved == .decoded) {
                n.saved = .{ .whitespace = ws };
            } else {
                try n.out.appendSlice(n.a, ws);
                n.saved = .none;
            },
            .newline => switch (n.saved) {
                .whitespace => |ws| n.saved = .{ .newline = try std.mem.concat(n.a, u8, &.{ ws, " " }) },
                .decoded => n.saved = .{ .newline = " " },
                else => {
                    try n.out.append(n.a, ' ');
                    n.saved = .none;
                },
            },
            .decoded => |d| {
                n.saved = .decoded;
                try n.out.appendSlice(n.a, d);
            },
        }
    }

    fn maybeWhitespace(n: *Normalizer, s: []const u8) Allocator.Error!void {
        try n.feed(if (trimEnd(s).len == 0) .{ .whitespace = s } else .{ .text = s });
    }

    fn line(n: *Normalizer, l: []const u8) Allocator.Error!void {
        var ix_search: usize = 0;
        while (std.mem.indexOfPos(u8, l, ix_search, "=?")) |v| {
            const ix_begin = v + 2;
            if (!boundaryBefore(l, v)) {
                try n.feed(.{ .text = l[ix_search..ix_begin] });
                ix_search = ix_begin;
                continue;
            }
            try n.maybeWhitespace(l[ix_search..v]);
            var ix_end_search = ix_begin;
            // the "?=" that closes the word is followed by a separator ("?=" can also be data: "?Q?=41")
            const end = while (std.mem.indexOfPos(u8, l, ix_end_search, "?=")) |ix_end| {
                if (boundaryAt(l, ix_end + 2)) break ix_end;
                ix_end_search = ix_end + 2;
            } else null;
            if (end) |ix_end| {
                if (try decodeWord(n.a, l[ix_begin..ix_end])) |word| {
                    try n.feed(.{ .decoded = word });
                } else {
                    try n.feed(.{ .text = l[v .. ix_end + 2] });
                }
                ix_search = ix_end + 2;
            } else {
                try n.feed(.{ .text = "=?" });
                ix_search = ix_begin;
            }
        }
        try n.maybeWhitespace(l[ix_search..]);
    }
};

/// A raw header value (possibly folded over several lines, possibly with RFC 2047 encoded-words
/// like "=?UTF-8?B?…?=") as one line of UTF-8. Bytes that are not UTF-8 are read as Latin-1.
pub fn decodeHeaderValue(a: Allocator, raw: []const u8) Allocator.Error![]u8 {
    const chars = if (std.unicode.utf8ValidateSlice(raw)) raw else try decodeLatin1(a, raw);
    var n: Normalizer = .{ .a = a };
    var lines: Lines = .{ .rest = chars };
    var first = true;
    while (lines.next()) |l| {
        if (first) first = false else try n.feed(.newline);
        try n.line(trimStart(l));
    }
    return n.out.items;
}

fn isBoundaryChar(cp: u21) bool {
    return isWhitespace(cp) or cp == '"' or cp == '(' or cp == ')' or cp == '<' or cp == '>' or cp == ',';
}

/// Is the character that ends at `at` one that may come before an encoded-word (or is `at` the start)?
fn boundaryBefore(line: []const u8, at: usize) bool {
    if (at == 0) return true;
    var s = at - 1;
    while (s > 0 and line[s] & 0xC0 == 0x80) s -= 1;
    return isBoundaryChar(std.unicode.utf8Decode(line[s..at]) catch return false);
}

/// Is the character at `at` one that may follow an encoded-word (or is `at` the end)?
fn boundaryAt(line: []const u8, at: usize) bool {
    if (at >= line.len) return true;
    const n = std.unicode.utf8ByteSequenceLength(line[at]) catch return false;
    if (at + n > line.len) return false;
    return isBoundaryChar(std.unicode.utf8Decode(line[at .. at + n]) catch return false);
}

/// The inside of "=?charset?B|Q?data?=" decoded to UTF-8; null when it is not a word this can
/// read (it then stays in the header as written).
fn decodeWord(a: Allocator, encoded: []const u8) Allocator.Error!?[]u8 {
    const d1 = std.mem.indexOfScalar(u8, encoded, '?') orelse return null;
    const d2 = std.mem.indexOfScalarPos(u8, encoded, d1 + 1, '?') orelse return null;
    const coding = encoded[d1 + 1 .. d2];
    const input = encoded[d2 + 1 ..];
    if (coding.len != 1) return null;
    const bytes = switch (coding[0]) {
        'B', 'b' => decodeBase64(a, input, false) catch |e| switch (e) {
            error.InvalidBase64 => return null,
            error.OutOfMemory => |x| return x,
        },
        'Q', 'q' => blk: {
            const spaced = try a.dupe(u8, input);
            std.mem.replaceScalar(u8, spaced, '_', ' ');
            // the quoted-printable decoder drops trailing whitespace: put it back
            const trimmed = trimEnd(spaced);
            const d = try decodeQuotedPrintable(a, trimmed);
            break :blk try std.mem.concat(a, u8, &.{ d, spaced[trimmed.len..] });
        },
        else => return null,
    };
    const cs = charsetForLabel(encoded[0..d1]) orelse return null;
    return try decodeCharset(a, cs, bytes);
}

// ---------------- Content-Type, Content-Disposition ----------------

pub fn parseContentType(a: Allocator, header: []const u8) Allocator.Error!ContentType {
    const pc = try parseParamContent(a, header);
    return .{
        .mimetype = try std.ascii.allocLowerString(a, pc.value),
        .charset = pc.params.get("charset") orelse "us-ascii",
        .params = pc.params,
    };
}

const ParamContent = struct { value: []const u8, params: Params };

/// "value; key=val; key2=\"val 2\"" as used by Content-Type and Content-Disposition, with the
/// charset-encoded and continued parameters of RFC 2231 ("filename*=UTF-8''a%20b",
/// "filename*0=…; filename*1=…") put back together. Like mailparse, a ';' inside a quoted value
/// is not understood.
fn parseParamContent(a: Allocator, content: []const u8) Allocator.Error!ParamContent {
    var tokens = std.mem.splitScalar(u8, content, ';');
    const value = trim(tokens.first());
    var map: Params = .empty;
    while (tokens.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = try std.ascii.allocLowerString(a, trim(kv[0..eq]));
        var v = trim(kv[eq + 1 ..]);
        if (v.len > 1 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        try map.put(a, key, v);
    }

    // RFC 2231 section 4: "key*" holds charset'language'percent-encoded text. Keys that already
    // have a plain twin are left alone.
    var decode_keys: std.ArrayList([]const u8) = .empty;
    for (map.keys()) |k| {
        if (k.len > 0 and k[k.len - 1] == '*' and !map.contains(k[0 .. k.len - 1])) try decode_keys.append(a, k[0 .. k.len - 1]);
    }
    // the "*0" segment comes before its continuations
    std.mem.sort([]const u8, decode_keys.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    // per key: its charset, and whether the value starts with charset'language' to strip (only
    // the first segment of a continued value does)
    const Encoding = struct { charset: []const u8, strip: bool };
    var encodings: std.StringArrayHashMapUnmanaged(Encoding) = .empty;
    for (decode_keys.items) |dk| {
        const full = map.get(try std.mem.concat(a, u8, &.{ dk, "*" })).?;
        const charset = full[0 .. std.mem.indexOfScalar(u8, full, '\'') orelse full.len];
        if (std.mem.endsWith(u8, dk, "*0")) {
            const prefix = dk[0 .. dk.len - 1];
            for (decode_keys.items) |ck| {
                if (std.mem.startsWith(u8, ck, prefix)) try encodings.put(a, ck, .{ .charset = charset, .strip = std.mem.eql(u8, ck, dk) });
            }
        } else if (!encodings.contains(dk)) {
            try encodings.put(a, dk, .{ .charset = charset, .strip = true });
        }
    }
    for (encodings.keys(), encodings.values()) |k, e| {
        const cs = charsetForLabel(e.charset) orelse continue;
        const key = try std.mem.concat(a, u8, &.{ k, "*" });
        var encoded = map.get(key).?;
        _ = map.orderedRemove(key);
        if (e.strip) {
            // charset'language'text
            const q1 = std.mem.indexOfScalar(u8, encoded, '\'');
            const q2 = if (q1) |q| std.mem.indexOfScalarPos(u8, encoded, q + 1, '\'') else null;
            encoded = if (q2) |q| encoded[q + 1 ..] else "";
        }
        try map.put(a, k, try decodeCharset(a, cs, try percentDecode(a, encoded)));
    }

    // RFC 2231 section 3: "key*0", "key*1", … are pieces of one value
    var unwrap_keys: std.ArrayList([]const u8) = .empty;
    for (map.keys()) |k| {
        if (std.mem.endsWith(u8, k, "*0") and !map.contains(k[0 .. k.len - 2])) try unwrap_keys.append(a, k[0 .. k.len - 2]);
    }
    for (unwrap_keys.items) |uk| {
        var whole: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (true) : (index += 1) {
            const key = try std.fmt.allocPrint(a, "{s}*{d}", .{ uk, index });
            const piece = map.get(key) orelse break;
            _ = map.orderedRemove(key);
            try whole.appendSlice(a, piece);
        }
        try map.put(a, uk, whole.items);
    }
    return .{ .value = value, .params = map };
}

fn percentDecode(a: Allocator, encoded: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%' and i + 2 < encoded.len and std.ascii.isHex(encoded[i + 1]) and std.ascii.isHex(encoded[i + 2])) {
            try out.append(a, hexPair(encoded[i + 1], encoded[i + 2]));
            i += 2;
        } else {
            try out.append(a, encoded[i]);
        }
    }
    return out.items;
}

fn hexPair(hi: u8, lo: u8) u8 {
    return (std.fmt.charToDigit(hi, 16) catch unreachable) << 4 | (std.fmt.charToDigit(lo, 16) catch unreachable);
}

// ---------------- transfer encodings ----------------

/// Lenient base64: line breaks (and with `skip_whitespace` any ASCII whitespace) are skipped,
/// padding is optional. Anything else outside the alphabet is an error.
pub fn decodeBase64(a: Allocator, input: []const u8, skip_whitespace: bool) error{ OutOfMemory, InvalidBase64 }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, input.len / 4 * 3 + 3);
    var acc: u32 = 0;
    var bits: u32 = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const ch = input[i];
        if (skippedInBase64(ch, skip_whitespace)) continue;
        if (ch == '=') break;
        const v: u32 = switch (ch) {
            'A'...'Z' => ch - 'A',
            'a'...'z' => ch - 'a' + 26,
            '0'...'9' => ch - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => return error.InvalidBase64,
        };
        acc = (acc << 6 | v) & 0xFFFF;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.appendAssumeCapacity(@truncate(acc >> @intCast(bits)));
        }
    }
    // after the first '=' only padding may follow
    while (i < input.len) : (i += 1) {
        if (input[i] != '=' and !skippedInBase64(input[i], skip_whitespace)) return error.InvalidBase64;
    }
    // one character alone carries no whole byte
    if (bits == 6) return error.InvalidBase64;
    return out.items;
}

fn skippedInBase64(ch: u8, skip_whitespace: bool) bool {
    return ch == '\r' or ch == '\n' or (skip_whitespace and (ch == ' ' or ch == '\t' or ch == 0x0C));
}

/// Quoted-printable, never failing: a broken "=XY" is kept as written. Bytes that cannot be in
/// quoted-printable text are dropped, trailing whitespace of a line is dropped, hard line breaks
/// come out as CRLF.
pub fn decodeQuotedPrintable(a: Allocator, input: []const u8) Allocator.Error![]u8 {
    var filtered: std.ArrayList(u8) = .empty;
    try filtered.ensureTotalCapacity(a, input.len);
    for (input) |ch| switch (ch) {
        '\t', '\r', '\n', ' '...'~' => filtered.appendAssumeCapacity(ch),
        else => {},
    };
    var out: std.ArrayList(u8) = .empty;
    // a "\n" can come out as "\r\n"
    try out.ensureTotalCapacity(a, filtered.items.len * 2 + 2);
    var lines: Lines = .{ .rest = filtered.items };
    // true: the line before ended without "=" (a real line break follows if more text comes)
    var add_line_break: ?bool = null;
    while (lines.next()) |l| {
        const line = std.mem.trimEnd(u8, l, " \t\r");
        if (add_line_break == true) {
            out.appendSliceAssumeCapacity("\r\n");
            add_line_break = false;
        }
        var i: usize = 0;
        while (true) {
            if (i >= line.len) {
                add_line_break = true;
                break;
            }
            const byte = line[i];
            i += 1;
            if (byte != '=') {
                out.appendAssumeCapacity(byte);
                continue;
            }
            // "=" at the end of the line: a soft break, the next line continues this one
            if (i >= line.len) break;
            const upper = line[i];
            i += 1;
            if (i >= line.len) {
                out.appendSliceAssumeCapacity(&.{ byte, upper });
                add_line_break = true;
                break;
            }
            const lower = line[i];
            i += 1;
            if (std.ascii.isHex(upper) and std.ascii.isHex(lower)) {
                out.appendAssumeCapacity(hexPair(upper, lower));
            } else {
                out.appendSliceAssumeCapacity(&.{ byte, upper, lower });
            }
        }
    }
    if (std.mem.endsWith(u8, filtered.items, "\n") and add_line_break == true) out.appendSliceAssumeCapacity("\r\n");
    return out.items;
}

// ---------------- charsets ----------------

const Charset = union(enum) {
    utf8,
    /// also what "iso-8859-1" and "us-ascii" mean on the web and in mail
    windows1252,
    utf16le,
    utf16be,
    iso2022jp,
    /// converted by Windows. Only code pages Windows reads from its tables: the ones it loads
    /// a converter DLL for (ISO-2022-*, GB18030 54936) can block for good.
    code_page: u32,
};

/// labels (lower-case, space separated) → charset. The usual names of the WHATWG encoding
/// standard, which is what mailparse knew; rarer aliases are missing.
const charset_labels = [_]struct { Charset, []const u8 }{
    .{ .utf8, "utf-8 utf8 unicode-1-1-utf-8 unicode11utf8 unicode20utf8 x-unicode20utf8" },
    .{ .windows1252, "windows-1252 cp1252 x-cp1252 iso-8859-1 iso8859-1 iso88591 iso_8859-1 iso_8859-1:1987 iso8859_1 iso-ir-100 latin1 l1 csisolatin1 ibm819 cp819 us-ascii ascii ansi_x3.4-1968" },
    .{ .utf16le, "utf-16 utf-16le ucs-2 unicode csunicode iso-10646-ucs-2 unicodefeff" },
    .{ .utf16be, "utf-16be unicodefffe" },
    .{ .{ .code_page = 28592 }, "iso-8859-2 iso8859-2 iso88592 iso_8859-2 iso8859_2 latin2 l2 csisolatin2" },
    .{ .{ .code_page = 28593 }, "iso-8859-3 iso8859-3 iso88593 iso_8859-3 iso8859_3 latin3 l3" },
    .{ .{ .code_page = 28594 }, "iso-8859-4 iso8859-4 iso88594 iso_8859-4 iso8859_4 latin4 l4" },
    .{ .{ .code_page = 28595 }, "iso-8859-5 iso8859-5 iso88595 iso_8859-5 iso8859_5 cyrillic" },
    .{ .{ .code_page = 28596 }, "iso-8859-6 iso8859-6 iso88596 iso_8859-6 iso8859_6 arabic" },
    .{ .{ .code_page = 28597 }, "iso-8859-7 iso8859-7 iso88597 iso_8859-7 iso8859_7 greek greek8" },
    .{ .{ .code_page = 28598 }, "iso-8859-8 iso8859-8 iso88598 iso_8859-8 hebrew visual" },
    .{ .{ .code_page = 38598 }, "iso-8859-8-i logical" },
    .{ .{ .code_page = 28603 }, "iso-8859-13 iso8859-13 iso885913 iso8859_13" },
    .{ .{ .code_page = 28605 }, "iso-8859-15 iso8859-15 iso885915 iso_8859-15 iso8859_15 l9 csisolatin9" },
    .{ .{ .code_page = 874 }, "windows-874 dos-874 tis-620 tis620 iso-8859-11 iso8859-11 ms874 x-windows-874" },
    .{ .{ .code_page = 1250 }, "windows-1250 cp1250 x-cp1250" },
    .{ .{ .code_page = 1251 }, "windows-1251 cp1251 x-cp1251" },
    .{ .{ .code_page = 1253 }, "windows-1253 cp1253 x-cp1253" },
    .{ .{ .code_page = 1254 }, "windows-1254 cp1254 x-cp1254 iso-8859-9 iso8859-9 iso88599 iso_8859-9 iso8859_9 latin5 l5" },
    .{ .{ .code_page = 1255 }, "windows-1255 cp1255 x-cp1255" },
    .{ .{ .code_page = 1256 }, "windows-1256 cp1256 x-cp1256" },
    .{ .{ .code_page = 1257 }, "windows-1257 cp1257 x-cp1257" },
    .{ .{ .code_page = 1258 }, "windows-1258 cp1258 x-cp1258" },
    .{ .{ .code_page = 20866 }, "koi8-r koi8_r koi8 koi cskoi8r" },
    .{ .{ .code_page = 21866 }, "koi8-u koi8_u koi8-ru" },
    .{ .{ .code_page = 866 }, "ibm866 cp866 866 csibm866" },
    .{ .{ .code_page = 10000 }, "macintosh mac x-mac-roman csmacintosh" },
    .{ .{ .code_page = 936 }, "gbk gb2312 gb_2312 gb_2312-80 csgb2312 chinese x-gbk iso-ir-58 gb18030 euc_cn ms936" },
    .{ .{ .code_page = 950 }, "big5 big5-hkscs cn-big5 csbig5 x-x-big5 ms950 ms950_hkscs x-windows-950" },
    .{ .{ .code_page = 932 }, "shift_jis shift-jis sjis ms_kanji csshiftjis windows-31j x-sjis ms932" },
    .{ .{ .code_page = 20932 }, "euc-jp euc_jp x-euc-jp cseucpkdfmtjapanese" },
    .{ .iso2022jp, "iso-2022-jp iso2022jp csiso2022jp" },
    .{ .{ .code_page = 949 }, "euc-kr euc_kr korean ks_c_5601-1987 ks_c_5601-1989 ksc5601 ksc_5601 cseuckr windows-949 iso-ir-149 ms949 x-windows-949" },
};

fn charsetForLabel(label: []const u8) ?Charset {
    const l = std.mem.trim(u8, label, " \t\r\n\x0C");
    if (l.len == 0) return null;
    for (charset_labels) |entry| {
        var names = std.mem.tokenizeScalar(u8, entry[1], ' ');
        while (names.next()) |name| if (std.ascii.eqlIgnoreCase(name, l)) return entry[0];
    }
    return null;
}

/// `bytes` in charset `cs` as UTF-8; what cannot be converted becomes U+FFFD.
fn decodeCharset(a: Allocator, cs: Charset, bytes: []const u8) Allocator.Error![]u8 {
    switch (cs) {
        .utf8 => return std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(bytes)}),
        .windows1252 => return decodeWindows1252(a, bytes),
        .utf16le, .utf16be => {
            const units = try a.alloc(u16, (bytes.len + 1) / 2);
            for (units, 0..) |*u, i| {
                // half a unit at the end
                u.* = if (2 * i + 1 >= bytes.len) 0xFFFD else std.mem.readInt(u16, bytes[2 * i ..][0..2], if (cs == .utf16le) .little else .big);
            }
            return utf16ToUtf8(a, units);
        },
        .iso2022jp => return decodeCharset(a, .{ .code_page = 20932 }, try iso2022jpToEuc(a, bytes)),
        .code_page => |cp| {
            if (core.is_windows) {
                if (try decodeCodePage(a, cp, bytes)) |s| return s;
            }
            return decodeAscii(a, bytes);
        },
    }
}

/// ISO-2022-JP as EUC-JP: the same JIS X 0208 codes with the high bits set, instead of escape
/// sequences that switch between ASCII and kanji.
fn iso2022jpToEuc(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len);
    var kanji = false;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1B and i + 2 < bytes.len) {
            const seq = bytes[i + 1 ..][0..2];
            const to_kanji = std.mem.eql(u8, seq, "$@") or std.mem.eql(u8, seq, "$B");
            if (to_kanji or std.mem.eql(u8, seq, "(B") or std.mem.eql(u8, seq, "(J")) {
                kanji = to_kanji;
                i += 3;
                continue;
            }
        }
        if (kanji and i + 1 < bytes.len and bytes[i] > 0x20 and bytes[i] < 0x7F and bytes[i + 1] > 0x20 and bytes[i + 1] < 0x7F) {
            out.appendSliceAssumeCapacity(&.{ bytes[i] | 0x80, bytes[i + 1] | 0x80 });
            i += 2;
        } else {
            out.appendAssumeCapacity(bytes[i]);
            i += 1;
        }
    }
    return out.items;
}

fn decodeCodePage(a: Allocator, cp: u32, bytes: []const u8) Allocator.Error!?[]u8 {
    if (bytes.len == 0) return try a.alloc(u8, 0);
    const c = core.host.win.c;
    const len = std.math.cast(c_int, bytes.len) orelse return null;
    const n = c.MultiByteToWideChar(cp, 0, bytes.ptr, len, null, 0);
    if (n <= 0) return null;
    const wide = try a.alloc(u16, @intCast(n));
    const got = c.MultiByteToWideChar(cp, 0, bytes.ptr, len, wide.ptr, n);
    if (got <= 0) return null;
    return try utf16ToUtf8(a, wide[0..@intCast(got)]);
}

fn utf16ToUtf8(a: Allocator, units: []const u16) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, units.len * 3);
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        var cp: u21 = units[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) {
            cp = std.unicode.replacement_character;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

/// 0x80–0x9F of windows-1252 (the rest is Latin-1); the five holes map to the C1 controls.
const windows1252_high = [32]u16{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
};

fn decodeWindows1252(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len * 3);
    for (bytes) |b| {
        const cp: u21 = if (b >= 0x80 and b <= 0x9F) windows1252_high[b - 0x80] else b;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.items;
}

fn decodeLatin1(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len * 2);
    for (bytes) |b| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(b, &buf) catch unreachable;
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.items;
}

/// ASCII kept, every other byte replaced by U+FFFD.
fn decodeAscii(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, bytes.len);
    for (bytes) |b| {
        if (b < 0x80) try out.append(a, b) else try out.appendSlice(a, &std.unicode.replacement_character_utf8);
    }
    return out.items;
}

// ---------------- dates ----------------

/// Seconds since the Unix epoch for a `Date:` header ("Sun, 02 Oct 2016 07:06:22 -0700 (PDT)"),
/// null when it cannot be read. Same rules as mailparse's `dateparse`: day, month name, year,
/// h:m:s, then a numeric or RFC 822 zone; what is missing at the end counts as zero / UTC.
pub fn dateparse(date: []const u8) ?i64 {
    var result: i64 = 0;
    var month: i64 = 0;
    var day: i64 = 0;
    var state: enum { date, month, year, hour, minute, second, timezone } = .date;
    var toks = std.mem.tokenizeAny(u8, date, " :");
    while (toks.next()) |tok| switch (state) {
        // anything that is not a small number ("Sun,") is skipped
        .date => if (parseNum(tok, false)) |v| {
            if (v > 255) continue;
            if (v < 1 or v > 31) return null;
            day = v;
            state = .month;
        },
        .month => {
            const names = [_][]const u8{ "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" };
            month = for (names, 0..) |name, i| {
                if (std.ascii.eqlIgnoreCase(tok, name) or std.ascii.eqlIgnoreCase(tok, name[0..3])) break @intCast(i);
            } else return null;
            state = .year;
        },
        .year => {
            var year = parseNum(tok, false) orelse return null;
            if (year < 70) year += 2000 else if (year < 100) year += 1900 else if (year < 1970 or year > std.math.maxInt(u32)) return null;
            result = secondsToDate(year, month, day);
            state = .hour;
        },
        .hour, .minute, .second => {
            const v = parseNum(tok, false) orelse return null;
            if (v > 255) return null;
            result += v * @as(i64, switch (state) {
                .hour => 3600,
                .minute => 60,
                else => 1,
            });
            state = switch (state) {
                .hour => .minute,
                .minute => .second,
                else => .timezone,
            };
        },
        .timezone => {
            // the offset from UTC as ±hhmm
            const tz: i64 = parseNum(tok, true) orelse blk: {
                const zones = [_]struct { []const u8, i64 }{
                    .{ "UTC", 0 },    .{ "UT", 0 },     .{ "GMT", 0 },    .{ "Z", 0 },
                    .{ "EDT", -400 }, .{ "EST", -500 }, .{ "CDT", -500 }, .{ "CST", -600 },
                    .{ "MDT", -600 }, .{ "MST", -700 }, .{ "PDT", -700 }, .{ "PST", -800 },
                    .{ "A", -100 },   .{ "M", -1200 },  .{ "N", 100 },    .{ "Y", 1200 },
                };
                for (zones) |z| if (std.ascii.eqlIgnoreCase(tok, z[0])) break :blk z[1];
                return null;
            };
            if (tz < -2400 or tz > 2400) return null;
            const abs = @abs(tz);
            const delta: i64 = @intCast((abs / 100) * 3600 + (abs % 100) * 60);
            result -= if (tz < 0) -delta else delta;
            break;
        },
    };
    return result;
}

/// Decimal digits with an optional '+' (and '-' when `signed`); null for anything else.
fn parseNum(tok: []const u8, signed: bool) ?i64 {
    var s = tok;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or (signed and s[0] == '-'))) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0 or s.len > 10) return null;
    var v: i64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    return if (neg) -v else v;
}

fn daysInMonth(month: i64, year: i64) i64 {
    return switch (month) {
        0, 2, 4, 6, 7, 9, 11 => 31,
        3, 5, 8, 10 => 30,
        else => if (@mod(year, 400) == 0 or (@mod(year, 4) == 0 and @mod(year, 100) != 0)) 29 else 28,
    };
}

/// 29ths of February in the years 1..=year.
fn leapDaysThrough(year: i64) i64 {
    return @divFloor(year, 4) - @divFloor(year, 100) + @divFloor(year, 400);
}

/// Seconds from 1970 to the start of that day (`month` from 0).
fn secondsToDate(year: i64, month: i64, day: i64) i64 {
    var days: i64 = 365 * (year - 1970) + leapDaysThrough(year - 1) - leapDaysThrough(1969);
    var m: i64 = 0;
    while (m < month) : (m += 1) days += daysInMonth(m, year);
    return 86400 * (days + day - 1);
}

// ---------------- text helpers ----------------

/// Lines as Rust's `str::lines`: split at "\n", a "\r" before it dropped, no empty last line.
const Lines = struct {
    rest: []const u8,

    fn next(l: *Lines) ?[]const u8 {
        if (l.rest.len == 0) return null;
        const nl = std.mem.indexOfScalar(u8, l.rest, '\n') orelse {
            const last = l.rest;
            l.rest = "";
            return last;
        };
        var line = l.rest[0..nl];
        l.rest = l.rest[nl + 1 ..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

// ---------------- tests ----------------

const testing = std.testing;

fn expectValue(expected: []const u8, raw: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try decodeHeaderValue(arena.allocator(), raw));
}

test "parseHeader: key, value, folding, where the next one starts" {
    var h = try parseHeader("Key: Value");
    try testing.expectEqualStrings("Key", h.header.key);
    try testing.expectEqualStrings("Value", h.header.raw);
    try testing.expectEqual(@as(usize, 10), h.next);

    h = try parseHeader("Key :  Value ");
    try testing.expectEqualStrings("Key ", h.header.key);
    try testing.expectEqualStrings("Value ", h.header.raw);

    h = try parseHeader("Key:");
    try testing.expectEqualStrings("Key", h.header.key);
    try testing.expectEqualStrings("", h.header.raw);

    h = try parseHeader(":\n");
    try testing.expectEqualStrings("", h.header.key);
    try testing.expectEqualStrings("", h.header.raw);

    h = try parseHeader("Key:Multi-line\n value");
    try testing.expectEqualStrings("Multi-line\n value", h.header.raw);

    h = try parseHeader("Key:  Multi\n  line\n value\nNext: x");
    try testing.expectEqualStrings("Key", h.header.key);
    try testing.expectEqualStrings("Multi\n  line\n value", h.header.raw);
    try testing.expectEqualStrings("Next: x", "Key:  Multi\n  line\n value\nNext: x"[h.next..]);

    h = try parseHeader("Subject: a\r\n\tb\r\nNext: x");
    try testing.expectEqualStrings("a\r\n\tb", h.header.raw);
    try testing.expectEqualStrings("Next: x", "Subject: a\r\n\tb\r\nNext: x"[h.next..]);

    // a line without a colon is a key without a value
    h = try parseHeader("Bad Key\nNext: x");
    try testing.expectEqualStrings("Bad Key", h.header.key);
    try testing.expectEqualStrings("", h.header.raw);
    try testing.expectEqual(@as(usize, 8), h.next);

    try testing.expectError(error.InvalidMail, parseHeader(" Leading: space"));
    try testing.expectError(error.InvalidMail, parseHeader(""));
}

test "header values: folding" {
    try expectValue("Value", "Value");
    try expectValue("Multi-line value", "Multi-line\n value");
    try expectValue("Multi line value", "Multi\n  line\n value");
    try expectValue("Hello, sir, I am multiline", "Hello, sir,\n   I am multiline");
    try expectValue("a b", "a\r\n\tb");
    try expectValue("", "");
}

test "header values: RFC 2047 encoded-words" {
    try expectValue("\u{a1}Hola, se\u{f1}or!", "=?iso-8859-1?Q?=A1Hola,_se=F1or!?=");
    try expectValue("\u{a1}Hola, se\u{f1}or!", "=?ISO-8859-1?q?=a1Hola,_se=f1or!?=");
    try expectValue("Euro: \u{20ac}", "Euro: =?utf-8?Q?=E2=82=AC?=");
    try expectValue("Hello World", "=?utf-8?B?SGVsbG8gV29ybGQ=?=");
    try expectValue("Hello World", "=?UTF-8?b?SGVsbG8gV29ybGQ?=");
    try expectValue("Xin chào Việt Nam", "=?UTF-8?B?WGluIGNow6BvIFZp4buHdCBOYW0=?=");
    // windows-1252, not Latin-1: 0x80 is the euro sign
    try expectValue("\u{20ac}uro", "=?windows-1252?Q?=80uro?=");
    try expectValue("\u{20ac}", "=?iso-8859-1?B?gA==?=");
    // the text of a Q word may start with "=" and hold "?"
    try expectValue("A=B?", "=?us-ascii?Q?=41=3DB=3F?=");
    try expectValue("a b ", "=?utf-8?Q?a_b_?=");
}

test "header values: whitespace around encoded-words" {
    // between two encoded-words it is dropped, also across a folded line
    try expectValue("ab", "=?utf-8?Q?a?= =?utf-8?Q?b?=");
    try expectValue("ab", "=?utf-8?Q?a?=\r\n =?utf-8?Q?b?=");
    try expectValue("ab", "=?utf-8?Q?a?=  \r\n   =?utf-8?Q?b?=");
    // next to plain text it stays
    try expectValue("a b", "=?utf-8?Q?a?= b");
    try expectValue("a  b", "=?utf-8?Q?a?=  b");
    try expectValue("a b", "=?utf-8?Q?a?=\r\n b");
    try expectValue("x a", "x =?utf-8?Q?a?=");
    try expectValue("x a y b", "x =?utf-8?Q?a?= y =?utf-8?Q?b?=");
    try expectValue("\"Tên\" <a@b.c>", "\"=?UTF-8?Q?T=C3=AAn?=\" <a@b.c>");
    try expectValue("Tên (ghi chú)", "=?UTF-8?Q?T=C3=AAn?= (=?UTF-8?Q?ghi_ch=C3=BA?=)");
}

test "header values: what is not an encoded-word stays as written" {
    // glued to the text before it
    try expectValue("foo=?utf-8?Q?a?=", "foo=?utf-8?Q?a?=");
    // no end
    try expectValue("=?utf-8?Q?a", "=?utf-8?Q?a");
    try expectValue("a =? b", "a =? b");
    // unknown charset, unknown coding, broken base64
    try expectValue("=?x-nope?Q?a?=", "=?x-nope?Q?a?=");
    try expectValue("=?utf-8?X?a?=", "=?utf-8?X?a?=");
    try expectValue("=?utf-8?B?@@@?=", "=?utf-8?B?@@@?=");
    try expectValue("=?utf-8?=", "=?utf-8?=");
}

test "header values: raw bytes are UTF-8, else Latin-1" {
    try expectValue("\u{a1}Hola, se\u{f1}or!", "\xC2\xA1Hola, se\xC3\xB1or!");
    try expectValue("\u{a1}Hola, se\u{f1}or!", "\xA1Hola, se\xF1or!");
    // bad UTF-8 inside an encoded-word is replaced
    try expectValue("a\u{fffd}b", "=?utf-8?Q?a=FFb?=");
}

test "header values: other charsets through Windows code pages" {
    if (!core.is_windows) return error.SkipZigTest;
    try expectValue("Привет", "=?koi8-r?B?8NLJ18XU?=");
    try expectValue("日本語", "=?shift_jis?B?k/qWe4zq?=");
    try expectValue("日本語", "=?ISO-2022-JP?B?GyRCRnxLXDhsGyhC?=");
    try expectValue("中文", "=?gb2312?B?1tDOxA==?=");
    try expectValue("Łódź", "=?iso-8859-2?Q?=A3=F3d=BC?=");
    try expectValue("日本語 ok", "=?euc-jp?B?xvzL3LjsIG9r?=");
    try expectValue("한국어", "=?euc-kr?B?x9Gxub7u?=");
    try expectValue("ไทย", "=?tis-620?B?5LfC?=");
}

test "charsets: UTF-16" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hé😀", try decodeCharset(a, .utf16le, "h\x00\xe9\x00\x3d\xd8\x00\xde"));
    try testing.expectEqualStrings("hé😀", try decodeCharset(a, .utf16be, "\x00h\x00\xe9\xd8\x3d\xde\x00"));
    // a lone surrogate, half a unit
    try testing.expectEqualStrings("\u{fffd}a\u{fffd}", try decodeCharset(a, .utf16le, "\x3d\xd8a\x00b"));
    try testing.expect(charsetForLabel(" UTF-8 ") != null);
    try testing.expect(charsetForLabel("ISO-8859-1").? == .windows1252);
    try testing.expect(charsetForLabel("") == null);
    try testing.expect(charsetForLabel("utf") == null);
}

test "base64" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("hello world", try decodeBase64(a, "aGVsbG 8gd\r\n29ybGQ=", true));
    try testing.expectEqualStrings("hello world", try decodeBase64(a, "aGVsbG8gd29ybGQ", false));
    try testing.expectEqualStrings("hello world", try decodeBase64(a, "aGVsbG8g\r\nd29ybGQ=\r\n", false));
    try testing.expectEqualStrings("a", try decodeBase64(a, "YQ==", false));
    try testing.expectEqualStrings("ab", try decodeBase64(a, "YWI=", false));
    try testing.expectEqualStrings("abc", try decodeBase64(a, "YWJj", false));
    try testing.expectEqualStrings("\xff\xfe\xfd", try decodeBase64(a, "//79", false));
    try testing.expectEqualStrings("", try decodeBase64(a, "", false));
    try testing.expectError(error.InvalidBase64, decodeBase64(a, "aGVsbG 8=", false));
    try testing.expectError(error.InvalidBase64, decodeBase64(a, "YQ==YQ", false));
    try testing.expectError(error.InvalidBase64, decodeBase64(a, "Y", false));
    try testing.expectError(error.InvalidBase64, decodeBase64(a, "YW*j", true));
}

test "quoted-printable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const qp = decodeQuotedPrintable;
    try testing.expectEqualStrings("hello world", try qp(a, "hello world"));
    try testing.expectEqualStrings("Proof by Euro: \xE2\x82\xAC", try qp(a, "Proof by Euro: =E2=82=AC"));
    try testing.expectEqualStrings("lower \xe2\x82\xac", try qp(a, "lower =e2=82=ac"));
    // soft line breaks join, hard ones become CRLF, trailing whitespace goes
    try testing.expectEqualStrings("one line", try qp(a, "one =\r\nline"));
    try testing.expectEqualStrings("one line", try qp(a, "one =   \nline"));
    try testing.expectEqualStrings("a\r\nb", try qp(a, "a  \nb"));
    try testing.expectEqualStrings("a\r\nb\r\n", try qp(a, "a\r\nb\r\n"));
    try testing.expectEqualStrings("a\r\n\r\nb", try qp(a, "a\n\nb"));
    try testing.expectEqualStrings("a b", try qp(a, "a =\r\nb=\r\n"));
    // broken escapes stay as written
    try testing.expectEqualStrings("=ZZ=4", try qp(a, "=ZZ=4"));
    try testing.expectEqualStrings("a=", try qp(a, "a=3D"));
    // bytes that cannot be in quoted-printable are dropped
    try testing.expectEqualStrings("ab", try qp(a, "a\xff\x00b"));
    try testing.expectEqualStrings("", try qp(a, ""));
}

test "Content-Type and its parameters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ct = try parseContentType(a, "text/html; charset=foo; boundary=\"quotes_are_removed\"");
    try testing.expectEqualStrings("text/html", ct.mimetype);
    try testing.expectEqualStrings("foo", ct.charset);
    try testing.expectEqualStrings("quotes_are_removed", ct.params.get("boundary").?);
    try testing.expectEqualStrings("foo", ct.params.get("charset").?);

    ct = try parseContentType(a, "bogus");
    try testing.expectEqualStrings("bogus", ct.mimetype);
    try testing.expectEqualStrings("us-ascii", ct.charset);
    try testing.expect(ct.params.get("boundary") == null);

    ct = try parseContentType(a, " Multipart/Mixed ;\tBoundary = abc ; x");
    try testing.expectEqualStrings("multipart/mixed", ct.mimetype);
    try testing.expectEqualStrings("abc", ct.params.get("boundary").?);

    // RFC 2231: charset + percent-encoding, continuations, both
    var pc = try parseParamContent(a, "attachment; filename*=UTF-8''%E1%BA%A3nh%20ch%E1%BB%A5p.png");
    try testing.expectEqualStrings("attachment", pc.value);
    try testing.expectEqualStrings("ảnh chụp.png", pc.params.get("filename").?);
    try testing.expect(pc.params.get("filename*") == null);

    pc = try parseParamContent(a, "attachment; filename*0=\"long \"; filename*1=\"file name\"; filename*2=.txt");
    try testing.expectEqualStrings("long file name.txt", pc.params.get("filename").?);
    try testing.expectEqual(@as(usize, 1), pc.params.count());

    pc = try parseParamContent(a, "attachment; filename*1*=%E1%BB%A5p; filename*0*=utf-8'vi'%E1%BA%A3nh%20ch; filename*2=\".png\"");
    try testing.expectEqualStrings("ảnh chụp.png", pc.params.get("filename").?);

    pc = try parseParamContent(a, "attachment; filename*=iso-8859-1'en'%A3%20rates");
    try testing.expectEqualStrings("£ rates", pc.params.get("filename").?);

    // a plain twin wins; an unknown charset is left alone; a stray '%' stays
    pc = try parseParamContent(a, "inline; filename=plain.txt; filename*=UTF-8''fancy.txt; name*=x-nope''a%20b; title*=utf-8''100%25%zz%");
    try testing.expectEqualStrings("inline", pc.value);
    try testing.expectEqualStrings("plain.txt", pc.params.get("filename").?);
    try testing.expectEqualStrings("x-nope''a%20b", pc.params.get("name*").?);
    try testing.expectEqualStrings("100%%zz%", pc.params.get("title").?);
}

test "dateparse" {
    try testing.expectEqual(@as(?i64, 1475417182), dateparse("Sun, 02 Oct 2016 07:06:22 -0700 (PDT)"));
    try testing.expectEqual(@as(?i64, 1474842993), dateparse("Sun, 25 Sep 2016 18:36:33 -0400"));
    try testing.expectEqual(@as(?i64, 4102485133), dateparse("Fri, 01 Jan 2100 11:12:13 +0000"));
    try testing.expectEqual(@as(?i64, 4133894400), dateparse("Fri, 31 Dec 2100 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, 13569379200), dateparse("Fri, 31 Dec 2399 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, 13601001600), dateparse("Fri, 31 Dec 2400 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, 1474164338), dateparse("17 Sep 2016 16:05:38 -1000"));
    try testing.expectEqual(@as(?i64, 1354309043), dateparse("Fri, 30 Nov 2012 20:57:23 GMT"));
    try testing.expectEqual(@as(?i64, 1354309043 + 5 * 3600), dateparse("Fri, 30 November 2012 20:57:23 est"));
    try testing.expectEqual(@as(?i64, 1354309043 - 7 * 3600), dateparse("30 Nov 12 20:57:23 +0700"));
    try testing.expectEqual(@as(?i64, 1354309043), dateparse("Fri, 30 Nov 2012 20:57:23"));
    try testing.expectEqual(@as(?i64, 951782400), dateparse("29 Feb 2000 00:00:00 Z"));
    // day cannot be zero; the zone is checked
    try testing.expectEqual(@as(?i64, null), dateparse("Wed, 0 Jan 1970 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, null), dateparse("Thu, 1 Jan 1970 00:00:00 +2147483647"));
    // without seconds the zone is taken for them (as mailparse does)
    try testing.expectEqual(@as(?i64, 3600), dateparse("Thu, 1 Jan 1970 01:00 +0000"));
    try testing.expectEqual(@as(?i64, null), dateparse("Thu, 1 Jan 1970 01:00 GMT"));
    try testing.expectEqual(@as(?i64, 86400), dateparse("Fri, 2 Jan 1970"));
    try testing.expectEqual(@as(?i64, null), dateparse("Thu, 1 Foo 1970 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, null), dateparse("Thu, 1 Jan 1969 00:00:00 +0000"));
    try testing.expectEqual(@as(?i64, null), dateparse("Thu, 1 Jan 1970 00:00:00 XYZ"));
    try testing.expectEqual(@as(?i64, 0), dateparse(""));
}

test "a plain message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mail = try parse(a, "Key: value\r\n\r\nSome body stuffs");
    try testing.expectEqual(@as(usize, 1), mail.headers.len);
    try testing.expectEqualStrings("Key", mail.headers[0].key);
    try testing.expectEqualStrings("value", (try mail.header(a, "KEY")).?);
    try testing.expect(try mail.header(a, "Other") == null);
    try testing.expectEqualStrings("text/plain", mail.ctype.mimetype);
    try testing.expectEqualStrings("us-ascii", mail.ctype.charset);
    try testing.expectEqualStrings("Some body stuffs", try mail.body(a));
    try testing.expectEqual(@as(usize, 0), mail.subparts.len);
    try testing.expect(!(try mail.disposition(a)).attachment);

    // "\n" line ends, no body, no headers
    mail = try parse(a, "Subject: test\n\nThis is the body");
    try testing.expectEqualStrings("This is the body", try mail.body(a));
    mail = try parse(a, "Subject: test\n");
    try testing.expectEqualStrings("", try mail.body(a));
    mail = try parse(a, "");
    try testing.expectEqual(@as(usize, 0), mail.headers.len);
    mail = try parse(a, "\r\nonly a body");
    try testing.expectEqualStrings("only a body", try mail.body(a));

    try testing.expectError(error.InvalidMail, parse(a, "Key: value\r\n\rbody"));
}

test "bodies: transfer encoding and charset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mail = try parse(a, "Content-Transfer-Encoding: base64\r\n\r\naGVsbG 8gd\r\n29ybGQ=");
    try testing.expectEqualStrings("aGVsbG 8gd\r\n29ybGQ=", mail.body_bytes);
    try testing.expectEqualStrings("hello world", try mail.bodyRaw(a));
    try testing.expectEqualStrings("hello world", try mail.body(a));

    mail = try parse(a, "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: Quoted-Printable\n\nXin ch=C3=A0o,=\n b=E1=BA=A1n\n");
    try testing.expectEqualStrings("Xin chào, bạn\r\n", try mail.body(a));

    mail = try parse(a, "Content-Type: text/plain; charset=ISO-8859-1\nContent-Transfer-Encoding: 8bit\n\ncaf\xe9 \x80");
    try testing.expectEqualStrings("café €", try mail.body(a));
    try testing.expectEqualStrings("caf\xe9 \x80", try mail.bodyRaw(a));

    // no charset: us-ascii is read as windows-1252; an unknown one keeps only the ASCII
    mail = try parse(a, "Subject: x\n\ncaf\xe9");
    try testing.expectEqualStrings("café", try mail.body(a));
    mail = try parse(a, "Content-Type: text/plain; charset=x-nope\n\ncaf\xe9");
    try testing.expectEqualStrings("caf\u{fffd}", try mail.body(a));

    // bad UTF-8 is replaced, a byte order mark is dropped and wins over the charset
    mail = try parse(a, "Content-Type: text/plain; charset=utf-8\n\nok \xff\xc3 end");
    try testing.expectEqualStrings("ok \u{fffd}\u{fffd} end", try mail.body(a));
    mail = try parse(a, "Content-Type: text/plain; charset=iso-8859-1\n\n\xef\xbb\xbfch\xc3\xa0o");
    try testing.expectEqualStrings("chào", try mail.body(a));

    mail = try parse(a, "Content-Transfer-Encoding: base64\n\n!!!");
    try testing.expectError(error.InvalidBase64, mail.body(a));
}

test "multipart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mail = try parse(a, "Subject: This is a test email\n" ++
        "Content-Type: multipart/alternative; boundary=foobar\n" ++
        "Date: Sun, 02 Oct 2016 07:06:22 -0700 (PDT)\n" ++
        "\n" ++
        "--foobar\n" ++
        "Content-Type: text/plain; charset=utf-8\n" ++
        "Content-Transfer-Encoding: quoted-printable\n" ++
        "\n" ++
        "This is the plaintext version, in utf-8. Proof by Euro: =E2=82=AC\n" ++
        "--foobar\n" ++
        "Content-Type: text/html\n" ++
        "Content-Transfer-Encoding: base64\n" ++
        "\n" ++
        "PGh0bWw+PGJvZHk+VGhpcyBpcyB0aGUgPGI+SFRNTDwvYj4gdmVyc2lvbiwgaW4g \n" ++
        "dXMtYXNjaWkuIFByb29mIGJ5IEV1cm86ICZldXJvOzwvYm9keT48L2h0bWw+Cg== \n" ++
        "--foobar--\n" ++
        "After the final boundary stuff gets ignored.\n");
    try testing.expectEqualStrings("This is a test email", (try mail.header(a, "Subject")).?);
    try testing.expectEqualStrings("multipart/alternative", mail.ctype.mimetype);
    try testing.expectEqual(@as(usize, 2), mail.subparts.len);
    try testing.expectEqualStrings("This is the plaintext version, in utf-8. Proof by Euro: \u{20AC}", try mail.subparts[0].body(a));
    try testing.expectEqualStrings("base64", (try mail.subparts[1].header(a, "content-transfer-encoding")).?);
    try testing.expectEqualStrings("text/html", mail.subparts[1].ctype.mimetype);
    try testing.expectEqualStrings("<html><body>This is the <b>HTML</b> version, in us-ascii. Proof by Euro: &euro;</body></html>\n", try mail.subparts[1].body(a));
    try testing.expectEqual(@as(?i64, 1475417182), dateparse((try mail.header(a, "Date")).?));
}

test "multipart: nested, CRLF, preamble, attachments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mail = try parse(a, "From: =?UTF-8?B?Tmd1eeG7hW4gVsSDbiBB?= <a@example.com>\r\n" ++
        "Content-Type: multipart/mixed;\r\n boundary=\"outer\"\r\n" ++
        "\r\n" ++
        "preamble --outer is not a boundary here\r\n" ++
        "--outer\r\n" ++
        "Content-Type: multipart/alternative; boundary=inner\r\n" ++
        "\r\n" ++
        "--inner\r\n" ++
        "Content-Type: text/plain; charset=\"UTF-8\"\r\n" ++
        "\r\n" ++
        "plain text\r\n" ++
        "second line\r\n" ++
        "--inner\r\n" ++
        "Content-Type: text/html; charset=UTF-8\r\n" ++
        "\r\n" ++
        "<p>html</p>\r\n" ++
        "--inner--\r\n" ++
        "--outer\r\n" ++
        "Content-Type: application/pdf; name=\"=?UTF-8?B?YsOhbyBjw6FvLnBkZg==?=\"\r\n" ++
        "Content-Disposition: attachment;\r\n filename*=UTF-8''b%C3%A1o%20c%C3%A1o.pdf\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "\r\n" ++
        "JVBERi0x\r\nLjQK\r\n" ++
        "--outer\r\n" ++
        "Content-Type: image/png; name=logo.png\r\n" ++
        "Content-Disposition: ATTACHMENT\r\n" ++
        "\r\n" ++
        "\x89PNG\r\n" ++
        "--outer--\r\n");
    try testing.expectEqualStrings("Nguyễn Văn A <a@example.com>", (try mail.header(a, "From")).?);
    try testing.expectEqualStrings("outer", mail.ctype.params.get("boundary").?);
    try testing.expectEqualStrings("preamble --outer is not a boundary here", mail.body_bytes);
    try testing.expectEqual(@as(usize, 3), mail.subparts.len);

    const alt = mail.subparts[0];
    try testing.expectEqual(@as(usize, 2), alt.subparts.len);
    // the line break before a boundary belongs to the boundary
    try testing.expectEqualStrings("plain text\r\nsecond line", try alt.subparts[0].body(a));
    try testing.expectEqualStrings("<p>html</p>", try alt.subparts[1].body(a));

    const pdf = mail.subparts[1];
    const d = try pdf.disposition(a);
    try testing.expect(d.attachment);
    try testing.expectEqualStrings("báo cáo.pdf", d.params.get("filename").?);
    try testing.expectEqualStrings("báo cáo.pdf", pdf.ctype.params.get("name").?);
    try testing.expectEqualStrings("%PDF-1.4\n", try pdf.bodyRaw(a));

    const png = mail.subparts[2];
    const d2 = try png.disposition(a);
    try testing.expect(d2.attachment);
    try testing.expect(d2.params.get("filename") == null);
    try testing.expectEqualStrings("logo.png", png.ctype.params.get("name").?);
    try testing.expectEqualStrings("\x89PNG", try png.bodyRaw(a));
}

test "multipart: missing pieces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // no closing boundary: the last part runs to the end
    var mail = try parse(a, "Content-Type: multipart/mixed; boundary=b\n\n--b\n\none\n--b\n\ntwo\n");
    try testing.expectEqual(@as(usize, 2), mail.subparts.len);
    try testing.expectEqualStrings("one", try mail.subparts[0].body(a));
    try testing.expectEqualStrings("two\n", try mail.subparts[1].body(a));

    // no boundary parameter, or the boundary never shows up: one plain body
    mail = try parse(a, "Content-Type: multipart/mixed\n\n--b\n\none\n--b--\n");
    try testing.expectEqual(@as(usize, 0), mail.subparts.len);
    mail = try parse(a, "Content-Type: multipart/mixed; boundary=zzz\n\n--b\n\none\n--b--\n");
    try testing.expectEqual(@as(usize, 0), mail.subparts.len);
    try testing.expectEqualStrings("--b\n\none\n--b--\n", mail.body_bytes);

    // parts of a digest are messages unless they say otherwise
    mail = try parse(a, "Content-Type: multipart/digest; boundary=b\n\n--b\n\nSubject: inner\n\nhi\n--b--\n");
    try testing.expectEqualStrings("message/rfc822", mail.subparts[0].ctype.mimetype);
}

test "lines" {
    var lines: Lines = .{ .rest = "a\r\nb\n\nc\r" };
    try testing.expectEqualStrings("a", lines.next().?);
    try testing.expectEqualStrings("b", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqualStrings("c\r", lines.next().?);
    try testing.expect(lines.next() == null);
    lines = .{ .rest = "a\n" };
    try testing.expectEqualStrings("a", lines.next().?);
    try testing.expect(lines.next() == null);
}
