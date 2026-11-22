//! What the session readers share: JSON values read the way serde_json / JavaScript read them,
//! Rust's string helpers (Unicode trim, `lines`, clips counted in characters), the hand-written
//! matchers that stand in for the Rust build's regexes, and ISO dates.

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;

// ---------------- JSON values ----------------

/// One transcript line as JSON (null when it is not: partial lines fail and are skipped).
/// Strings may point into `line`. Bytes that are not UTF-8 become U+FFFD, as with
/// `String::from_utf8_lossy`.
pub fn parseLine(a: Allocator, line: []const u8) ?Value {
    const opts: std.json.ParseOptions = .{ .duplicate_field_behavior = .use_last };
    return std.json.parseFromSliceLeaky(Value, a, line, opts) catch {
        if (std.unicode.utf8ValidateSlice(line)) return null;
        const fixed = lossy(a, line) catch return null;
        return std.json.parseFromSliceLeaky(Value, a, fixed, opts) catch null;
    };
}

/// A line that is a JSON object.
pub fn parseObj(a: Allocator, line: []const u8) ?Value {
    const v = parseLine(a, line) orelse return null;
    return if (v == .object) v else null;
}

/// `String::from_utf8_lossy`
pub fn lossy(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

/// A member of an object (null for anything that is not one).
pub fn get(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    return if (o == .object) o.object.get(key) else null;
}

pub fn str(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

pub fn strOf(v: ?Value, key: []const u8) ?[]const u8 {
    return str(get(v, key));
}

/// `v` when it is an object.
pub fn obj(v: ?Value) ?Value {
    const o = v orelse return null;
    return if (o == .object) o else null;
}

/// The items of an array (none for anything else).
pub fn arr(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

pub fn isType(v: ?Value, ty: []const u8) bool {
    const t = strOf(v, "type") orelse return false;
    return std.mem.eql(u8, t, ty);
}

pub fn asF64(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// A non-negative whole number (serde's `as_u64`).
pub fn asU64(v: ?Value) ?u64 {
    return switch (v orelse return null) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// `f as u64` in Rust: saturating, NaN is 0.
pub fn toU64(f: f64) u64 {
    if (!(f > 0)) return 0;
    if (f >= 18446744073709551615.0) return std.math.maxInt(u64);
    return @intFromFloat(f);
}

/// JS truthiness of an optional JSON value.
pub fn truthy(v: ?Value) bool {
    return switch (v orelse return false) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0 and !std.math.isNan(f),
        .number_string => |s| if (std.fmt.parseFloat(f64, s)) |f| f != 0 else |_| true,
        .string => |s| s.len > 0,
        else => true,
    };
}

/// JS `String(v)`, near enough.
pub fn jsString(a: Allocator, v: Value) Allocator.Error![]const u8 {
    switch (v) {
        .string => |s| return s,
        .null => return "null",
        .object => return "[object Object]",
        .array => |items| {
            var out: std.ArrayList(u8) = .empty;
            for (items.items, 0..) |x, i| {
                if (i > 0) try out.append(a, ',');
                if (x != .null) try out.appendSlice(a, try jsString(a, x));
            }
            return out.items;
        },
        else => return jsonText(a, v, null),
    }
}

/// `a ?? b ?? ''` over object keys, then `String()`.
pub fn jsStringCoalesce(a: Allocator, o: ?Value, keys: []const []const u8) Allocator.Error![]const u8 {
    for (keys) |k| {
        const v = get(o, k) orelse continue;
        if (v != .null) return jsString(a, v);
    }
    return "";
}

/// Compact JSON as serde_json writes it. `sort`: object keys in byte order (serde_json's map is a
/// BTreeMap), which needs an allocator; null keeps them as they came.
/// Numbers with a fraction or an exponent are written in plain decimal ("1.0", "0.000001").
pub fn writeJson(w: *std.Io.Writer, v: Value, sort: ?Allocator) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            var buf: [400]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return w.print("{e}", .{f});
            try w.writeAll(s);
            if (std.mem.findScalar(u8, s, '.') == null) try w.writeAll(".0");
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .array => |items| {
            try w.writeByte('[');
            for (items.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeJson(w, x, sort);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            if (sort) |a| {
                const keys = sortedKeys(a, v) catch return error.WriteFailed;
                for (keys, 0..) |k, i| {
                    if (i > 0) try w.writeByte(',');
                    try std.json.Stringify.encodeJsonString(k, .{}, w);
                    try w.writeByte(':');
                    try writeJson(w, o.get(k).?, sort);
                }
            } else for (o.keys(), o.values(), 0..) |k, x, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try writeJson(w, x, null);
            }
            try w.writeByte('}');
        },
    }
}

/// An object's keys in byte order.
pub fn sortedKeys(a: Allocator, o: Value) Allocator.Error![]const []const u8 {
    const keys = try a.dupe([]const u8, o.object.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return keys;
}

/// `v.to_string()`; `sort` as in `writeJson`.
pub fn jsonText(a: Allocator, v: Value, sort: ?Allocator) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    writeJson(&aw.writer, v, sort) catch return error.OutOfMemory;
    return aw.written();
}

/// Length of `v` as compact JSON.
pub fn jsonLen(v: Value) u64 {
    var buf: [256]u8 = undefined;
    var d: std.Io.Writer.Discarding = .init(&buf);
    writeJson(&d.writer, v, null) catch return 0;
    return d.fullCount();
}

/// When a row was written (0 without a readable timestamp).
pub fn rowTime(a: Allocator, row: Value) i64 {
    const v = get(row, "timestamp") orelse return 0;
    return parseDate(jsString(a, v) catch return 0) orelse 0;
}

// ---------------- text ----------------

fn isWs3(b: []const u8) bool {
    return switch (b[0]) {
        0xe1 => b[1] == 0x9a and b[2] == 0x80, // U+1680
        0xe2 => (b[1] == 0x80 and (b[2] <= 0x8a or b[2] == 0xa8 or b[2] == 0xa9 or b[2] == 0xaf)) or // U+2000-200A, 2028, 2029, 202F
            (b[1] == 0x81 and b[2] == 0x9f), // U+205F
        0xe3 => b[1] == 0x80 and b[2] == 0x80, // U+3000
        else => false,
    };
}

/// Bytes of the white space character `s` starts with (0: none). Unicode's White_Space, which
/// is what Rust's `trim` and `split_whitespace` go by.
fn wsStart(s: []const u8) usize {
    if (s.len == 0) return 0;
    return switch (s[0]) {
        0x09...0x0d, ' ' => 1,
        0xc2 => if (s.len >= 2 and (s[1] == 0x85 or s[1] == 0xa0)) 2 else 0,
        0xe1...0xe3 => if (s.len >= 3 and isWs3(s[0..3])) 3 else 0,
        else => 0,
    };
}

fn wsEnd(s: []const u8) usize {
    if (s.len == 0) return 0;
    const last = s[s.len - 1];
    if ((last >= 0x09 and last <= 0x0d) or last == ' ') return 1;
    if (s.len >= 2 and s[s.len - 2] == 0xc2 and (last == 0x85 or last == 0xa0)) return 2;
    if (s.len >= 3 and isWs3(s[s.len - 3 ..])) return 3;
    return 0;
}

/// `str::trim`
pub fn trim(s: []const u8) []const u8 {
    var t = s;
    while (wsStart(t) > 0) t = t[wsStart(t)..];
    while (wsEnd(t) > 0) t = t[0 .. t.len - wsEnd(t)];
    return t;
}

/// `s.split_whitespace().collect::<Vec<_>>().join(" ")`
pub fn collapseWs(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    var gap = false;
    while (i < s.len) {
        const n = wsStart(s[i..]);
        if (n > 0) {
            gap = out.items.len > 0;
            i += n;
            continue;
        }
        if (gap) out.appendAssumeCapacity(' ');
        gap = false;
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.items;
}

/// `str::lines`: split at "\n" (a "\r" before it goes too), with no empty line after a final "\n".
pub const Lines = struct {
    rest: []const u8,

    pub fn next(it: *Lines) ?[]const u8 {
        if (it.rest.len == 0) return null;
        const nl = std.mem.findScalar(u8, it.rest, '\n') orelse {
            defer it.rest = "";
            return it.rest;
        };
        var line = it.rest[0..nl];
        it.rest = it.rest[nl + 1 ..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

pub fn lines(s: []const u8) Lines {
    return .{ .rest = s };
}

pub fn firstLine(s: []const u8) []const u8 {
    var it = lines(s);
    return it.next() orelse "";
}

pub fn countLines(s: []const u8) usize {
    var it = lines(s);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Where the character after the first `n` starts (null when `s` has no more than `n`).
fn charEnd(s: []const u8, n: usize) ?usize {
    var chars: usize = 0;
    for (s, 0..) |b, i| {
        if (b & 0xc0 == 0x80) continue;
        if (chars == n) return i;
        chars += 1;
    }
    return null;
}

/// `s.chars().take(n)`
pub fn takeChars(s: []const u8, n: usize) []const u8 {
    return s[0 .. charEnd(s, n) orelse s.len];
}

/// A copy of `s`, cut to `n` characters with an ellipsis when it is longer.
pub fn clip(a: Allocator, s: []const u8, n: usize) Allocator.Error![]const u8 {
    const end = charEnd(s, n) orelse return a.dupe(u8, s);
    return std.mem.concat(a, u8, &.{ s[0..end], "…" });
}

const win = if (core.is_windows) @import("win") else struct {};

/// `str::to_lowercase`. Anything beyond ASCII goes through Windows (the page lowercases the same
/// folder names with JavaScript, and the two must agree on "D:\Dự Án").
pub fn lower(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try a.alloc(u8, s.len);
    _ = std.ascii.lowerString(out, s);
    const ascii = for (s) |c| {
        if (c >= 0x80) break false;
    } else true;
    if (ascii or !core.is_windows) return out;
    const src = std.unicode.utf8ToUtf16LeAlloc(a, s) catch return out;
    if (src.len > std.math.maxInt(c_int)) return out;
    const n: c_int = @intCast(src.len);
    const dst = try a.alloc(u16, src.len);
    if (win.LCMapStringEx(&[_:0]u16{}, win.LCMAP_LOWERCASE, src.ptr, n, dst.ptr, n, null, null, 0) != n) return out;
    return std.unicode.utf16LeToUtf8Alloc(a, dst) catch out;
}

pub fn isSlash(c: u8) bool {
    return c == '/' or c == '\\';
}

// ---------------- the Rust build's regexes, by hand ----------------

/// `(?i)^(.*?)[\\/]\.claude[\\/]worktrees[\\/]`: the repo a worktree folder was cut from.
pub fn worktreeRepo(cwd: []const u8) ?[]const u8 {
    for (cwd, 0..) |c, i| {
        if (c == '\n') return null; // `.` does not cross a line break
        if (!isSlash(c)) continue;
        var rest = cwd[i + 1 ..];
        if (!std.ascii.startsWithIgnoreCase(rest, ".claude")) continue;
        rest = rest[".claude".len..];
        if (rest.len == 0 or !isSlash(rest[0])) continue;
        rest = rest[1..];
        if (!std.ascii.startsWithIgnoreCase(rest, "worktrees")) continue;
        rest = rest["worktrees".len..];
        if (rest.len > 0 and isSlash(rest[0])) return cwd[0..i];
    }
    return null;
}

const image_exts = [_][]const u8{ "png", "jpeg", "jpg", "gif", "webp" };

/// `(?i)\.(png|jpe?g|gif|webp)` somewhere in `s`.
pub fn hasImageExt(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, s, from, '.')) |dot| : (from = dot + 1) {
        for (image_exts) |ext| if (std.ascii.startsWithIgnoreCase(s[dot + 1 ..], ext)) return true;
    }
    return false;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `(?:png|jpe?g|gif|webp)\b` (any case) at the start of `s`: its length.
fn imageExtEnd(s: []const u8) ?usize {
    for (image_exts) |ext| {
        if (std.ascii.startsWithIgnoreCase(s, ext) and (s.len == ext.len or !isWord(s[ext.len]))) return ext.len;
    }
    return null;
}

/// `(?i)[A-Za-z]:[\\/][^"'\n\r<>|*?]+?\.(?:png|jpe?g|gif|webp)\b`, one match after another:
/// the Windows paths of image files named in a text.
pub const ImagePaths = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *ImagePaths) ?[]const u8 {
        const t = it.text;
        while (it.pos + 3 < t.len) : (it.pos += 1) {
            const s = it.pos;
            if (!std.ascii.isAlphabetic(t[s]) or t[s + 1] != ':' or !isSlash(t[s + 2])) continue;
            // lazy: the first extension after at least one character of the path
            var k = s + 3;
            while (k < t.len and std.mem.findScalar(u8, "\"'\n\r<>|*?", t[k]) == null) : (k += 1) {
                if (k == s + 3 or t[k] != '.') continue;
                if (imageExtEnd(t[k + 1 ..])) |n| {
                    it.pos = k + 1 + n;
                    return t[s..it.pos];
                }
            }
        }
        return null;
    }
};

/// `Output is being written to: ([^\n\r\u{2028}\u{2029}]+?\.output)`: the file a background
/// task's result names.
pub fn outputFile(s: []const u8) ?[]const u8 {
    const head = "Output is being written to: ";
    var from: usize = 0;
    while (std.mem.findPos(u8, s, from, head)) |p| : (from = p + 1) {
        const start = p + head.len;
        var k = start;
        while (k < s.len) : (k += 1) {
            if (s[k] == '\n' or s[k] == '\r') break;
            // U+2028, U+2029
            if (s[k] == 0xe2 and k + 2 < s.len and s[k + 1] == 0x80 and (s[k + 2] == 0xa8 or s[k + 2] == 0xa9)) break;
            if (k > start and std.mem.startsWith(u8, s[k..], ".output")) return s[start .. k + ".output".len];
        }
    }
    return null;
}

pub const TaskNote = struct { id: []const u8, status: []const u8 };

/// `(?s)<task-id>([^<]+)</task-id>.*?<status>([^<]+)</status>`, one match after another.
pub const TaskNotes = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *TaskNotes) ?TaskNote {
        const t = it.text;
        while (std.mem.findPos(u8, t, it.pos, "<task-id>")) |p| {
            it.pos = p + 1;
            const id_start = p + "<task-id>".len;
            const id_end = std.mem.findScalarPos(u8, t, id_start, '<') orelse return null;
            if (id_end == id_start or !std.mem.startsWith(u8, t[id_end..], "</task-id>")) continue;
            var from = id_end + "</task-id>".len;
            while (std.mem.findPos(u8, t, from, "<status>")) |sp| : (from = sp + 1) {
                const st_start = sp + "<status>".len;
                const st_end = std.mem.findScalarPos(u8, t, st_start, '<') orelse break;
                if (st_end == st_start or !std.mem.startsWith(u8, t[st_end..], "</status>")) continue;
                it.pos = st_end + "</status>".len;
                return .{ .id = t[id_start..id_end], .status = t[st_start..st_end] };
            }
        }
        return null;
    }
};

/// `s` without its terminal colour codes: `\x1b\[[0-9;]*m`, or with `any` every CSI sequence
/// that ends in a letter (`\x1b\[[0-9;]*[A-Za-z]`).
pub fn stripAnsi(a: Allocator, s: []const u8, any: bool) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, s, 0x1b) == null) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var k = i + 2;
            while (k < s.len and (std.ascii.isDigit(s[k]) or s[k] == ';')) k += 1;
            if (k < s.len and (if (any) std.ascii.isAlphabetic(s[k]) else s[k] == 'm')) {
                i = k + 1;
                continue;
            }
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.items;
}

/// `(?s)<command-name>(.*?)</command-name>(?:.*?<command-args>(.*?)</command-args>)?`:
/// a slash command as typed, "/name args".
pub fn slashCommand(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    const open = "<command-name>";
    const close = "</command-name>";
    const p = std.mem.find(u8, text, open) orelse return null;
    const name_end = std.mem.findPos(u8, text, p + open.len, close) orelse return null;
    var args: []const u8 = "";
    if (std.mem.findPos(u8, text, name_end + close.len, "<command-args>")) |ap| {
        const args_start = ap + "<command-args>".len;
        if (std.mem.findPos(u8, text, args_start, "</command-args>")) |ae| args = text[args_start..ae];
    }
    return trim(try std.fmt.allocPrint(a, "{s} {s}", .{ trim(text[p + open.len .. name_end]), trim(args) }));
}

// ---------------- dates ----------------

fn num(b: []const u8, from: usize, len: usize) ?i64 {
    if (from + len > b.len) return null;
    var n: i64 = 0;
    for (b[from .. from + len]) |d| {
        if (!std.ascii.isDigit(d)) return null;
        n = n * 10 + (d - '0');
    }
    return n;
}

fn at(b: []const u8, i: usize) ?u8 {
    return if (i < b.len) b[i] else null;
}

/// `Date.parse` for the ISO 8601 timestamps Claude Code writes ("2025-01-02T03:04:05.678Z").
/// Times without an offset are read as UTC. Null where JS would give NaN.
pub fn parseDate(s: []const u8) ?i64 {
    const b = trim(s);
    const y = num(b, 0, 4) orelse return null;
    const mo = num(b, 5, 2) orelse return null;
    const d = num(b, 8, 2) orelse return null;
    if (b[4] != '-' or b[7] != '-' or mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    const days = daysFromCivil(y, mo, d);
    if (b.len == 10) return days * 86_400_000;
    if ((b[10] != 'T' and b[10] != 't' and b[10] != ' ') or at(b, 13) != ':') return null;
    const h = num(b, 11, 2) orelse return null;
    const mi = num(b, 14, 2) orelse return null;
    var i: usize = 16;
    var sec: i64 = 0;
    var millis: i64 = 0;
    if (at(b, i) == ':') {
        sec = num(b, i + 1, 2) orelse return null;
        i += 3;
        if (at(b, i) == '.') {
            i += 1;
            const start = i;
            while (i < b.len and std.ascii.isDigit(b[i])) i += 1;
            if (i == start) return null;
            const frac = b[start..@min(i, start + 3)];
            for (frac) |c| millis = millis * 10 + (c - '0');
            millis *= std.math.pow(i64, 10, @intCast(3 - frac.len));
        }
    }
    if (h > 24 or mi > 59 or sec > 59) return null;
    var offset_min: i64 = 0;
    if (at(b, i)) |c| switch (c) {
        'Z', 'z' => if (i + 1 != b.len) return null,
        '+', '-' => {
            const oh = num(b, i + 1, 2) orelse return null;
            var om: i64 = 0;
            if (at(b, i + 3)) |sep| {
                if (sep == ':') {
                    om = num(b, i + 4, 2) orelse return null;
                    if (i + 6 != b.len) return null;
                } else {
                    om = num(b, i + 3, 2) orelse return null;
                    if (i + 5 != b.len) return null;
                }
            }
            offset_min = oh * 60 + om;
            if (c == '-') offset_min = -offset_min;
        },
        else => return null,
    };
    return (days * 86_400 + h * 3600 + mi * 60 + sec - offset_min * 60) * 1000 + millis;
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn daysFromCivil(year: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divTrunc(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// ---------------- tests ----------------

const testing = std.testing;

fn testValue(a: Allocator, json: []const u8) Value {
    return parseLine(a, json).?;
}

test "dates" {
    try testing.expectEqual(@as(?i64, 0), parseDate("1970-01-01T00:00:00.000Z"));
    try testing.expectEqual(@as(?i64, 1_735_787_045_678), parseDate("2025-01-02T03:04:05.678Z"));
    try testing.expectEqual(@as(?i64, 1_735_787_045_678), parseDate("2025-01-02T05:04:05.678+02:00"));
    try testing.expectEqual(@as(?i64, 1_735_787_045_678), parseDate(" 2025-01-02T01:04:05.678123-0200 "));
    try testing.expectEqual(@as(?i64, 1_735_787_040_000), parseDate("2025-01-02T03:04"));
    try testing.expectEqual(@as(?i64, 1_735_776_000_000), parseDate("2025-01-02"));
    try testing.expectEqual(@as(?i64, -86_400_000), parseDate("1969-12-31"));
    try testing.expectEqual(@as(?i64, null), parseDate("nope"));
    try testing.expectEqual(@as(?i64, null), parseDate("null"));
    try testing.expectEqual(@as(?i64, null), parseDate(""));
    try testing.expectEqual(@as(?i64, null), parseDate("2025-13-02"));
    try testing.expectEqual(@as(?i64, null), parseDate("2025-01-02T03:04:05.Z"));
    try testing.expectEqual(@as(?i64, null), parseDate("2025-01-02T03:04:05Zx"));
    try testing.expectEqual(@as(?i64, null), parseDate("2025-01-02X03:04:05Z"));
}

test "lines that are not JSON are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parseLine(a, "") == null);
    try testing.expect(parseLine(a, "{\"a\":") == null);
    try testing.expect(parseLine(a, "{} {}") == null);
    try testing.expect(parseLine(a, "{}x") == null);
    try testing.expect(parseObj(a, "[1]") == null);
    try testing.expect(parseObj(a, "{\"a\":1}\r") != null);
    // the last of a repeated key wins, as in serde_json
    try testing.expectEqual(@as(i64, 2), get(parseObj(a, "{\"a\":1,\"a\":2}"), "a").?.integer);
    // bytes that are not UTF-8 are replaced, not fatal
    try testing.expectEqualStrings("a\u{fffd}b", strOf(parseObj(a, "{\"t\":\"a\xffb\"}"), "t").?);
}

test "JSON values the JavaScript way" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = testValue(a,
        \\{"s":"x","e":"","n":null,"t":true,"f":false,"i":5,"z":0,"neg":-3,"fl":1.5,"one":1.0,"a":[1,null,"b",[2,3]],"o":{"b":1,"a":"q\n"},"big":18446744073709551615}
    );
    try testing.expect(truthy(get(v, "s")) and truthy(get(v, "t")) and truthy(get(v, "i")) and truthy(get(v, "a")) and truthy(get(v, "o")));
    try testing.expect(!truthy(get(v, "e")) and !truthy(get(v, "n")) and !truthy(get(v, "f")) and !truthy(get(v, "z")) and !truthy(get(v, "missing")));
    try testing.expectEqualStrings("x", try jsString(a, get(v, "s").?));
    try testing.expectEqualStrings("null", try jsString(a, get(v, "n").?));
    try testing.expectEqualStrings("true", try jsString(a, get(v, "t").?));
    try testing.expectEqualStrings("5", try jsString(a, get(v, "i").?));
    try testing.expectEqualStrings("1.5", try jsString(a, get(v, "fl").?));
    try testing.expectEqualStrings("1,,b,2,3", try jsString(a, get(v, "a").?));
    try testing.expectEqualStrings("[object Object]", try jsString(a, get(v, "o").?));
    try testing.expectEqualStrings("5", try jsStringCoalesce(a, v, &.{ "missing", "n", "i", "s" }));
    try testing.expectEqualStrings("", try jsStringCoalesce(a, v, &.{"n"}));
    try testing.expectEqualStrings("", try jsStringCoalesce(a, null, &.{"s"}));
    try testing.expectEqual(@as(?u64, 5), asU64(get(v, "i")));
    try testing.expectEqual(@as(?u64, null), asU64(get(v, "neg")));
    try testing.expectEqual(@as(?u64, null), asU64(get(v, "fl")));
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), asU64(get(v, "big")));
    try testing.expectEqual(@as(?f64, -3), asF64(get(v, "neg")));
    try testing.expectEqual(@as(?f64, null), asF64(get(v, "s")));
    try testing.expectEqualStrings("{\"b\":1,\"a\":\"q\\n\"}", try jsonText(a, get(v, "o").?, null));
    try testing.expectEqualStrings("{\"a\":\"q\\n\",\"b\":1}", try jsonText(a, get(v, "o").?, a));
    try testing.expectEqualStrings("[1,null,\"b\",[2,3]]", try jsonText(a, get(v, "a").?, null));
    try testing.expectEqualStrings("1.0", try jsonText(a, get(v, "one").?, null));
    try testing.expectEqual(@as(u64, 17), jsonLen(get(v, "o").?));
    try testing.expectEqual(@as(u64, 0), toU64(-1));
    try testing.expectEqual(@as(u64, 0), toU64(std.math.nan(f64)));
    try testing.expectEqual(@as(u64, 7), toU64(7.9));
}

test "text helpers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b", trim(" \t\r\n\u{a0}\u{3000}a b\u{2028}\u{85} "));
    try testing.expectEqualStrings("", trim(" \n"));
    try testing.expectEqualStrings("é", trim("é"));
    try testing.expectEqualStrings("a b c", try collapseWs(a, "  a \n\t b\u{a0}c "));
    try testing.expectEqualStrings("héllo…", try clip(a, "héllo wörld", 5));
    try testing.expectEqualStrings("héllo", try clip(a, "héllo", 5));
    try testing.expectEqualStrings("hé", takeChars("héllo", 2));
    try testing.expectEqualStrings("", firstLine(""));
    try testing.expectEqualStrings("a", firstLine("a\r\nb"));
    try testing.expectEqual(@as(usize, 0), countLines(""));
    try testing.expectEqual(@as(usize, 1), countLines("\n"));
    try testing.expectEqual(@as(usize, 2), countLines("x\ny"));
    try testing.expectEqual(@as(usize, 2), countLines("x\ny\n"));
    try testing.expectEqual(@as(usize, 3), countLines("x\n\ny"));
    var it = lines("a\r\nb\r");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b\r", it.next().?); // a "\r" that no "\n" follows stays
    try testing.expect(it.next() == null);
    try testing.expectEqualStrings("d:\\code\\x", try lower(a, "D:\\Code\\X"));
    if (core.is_windows) try testing.expectEqualStrings("d:\\dự án\\đồ", try lower(a, "D:\\Dự Án\\ĐỒ"));
}

test "worktree folders" {
    try testing.expectEqualStrings("E:\\x\\repo", worktreeRepo("E:\\x\\repo\\.claude\\worktrees\\a").?);
    try testing.expectEqualStrings("/home/me/repo", worktreeRepo("/home/me/repo/.Claude/WORKTREES/a/b").?);
    try testing.expectEqualStrings("", worktreeRepo("/.claude/worktrees/").?);
    try testing.expect(worktreeRepo("E:\\x\\repo\\.claude\\worktrees") == null);
    try testing.expect(worktreeRepo("E:\\x\\repo\\.claude\\other\\a") == null);
    try testing.expect(worktreeRepo("E:\\x\\repo") == null);
}

test "image files named in a text" {
    try testing.expect(hasImageExt("see shot.PNG here"));
    try testing.expect(hasImageExt("a.b.jpeg"));
    try testing.expect(!hasImageExt("a.txt, b.pn g"));

    var it: ImagePaths = .{ .text = "look at C:\\Users\\me\\a b.png and d:/x/y.JPEG, not C:\\notes.txt or \"E:\\q\".gif E:\\p.jpgx E:\\w.webp." };
    try testing.expectEqualStrings("C:\\Users\\me\\a b.png", it.next().?);
    try testing.expectEqualStrings("d:/x/y.JPEG", it.next().?);
    // the extension must end at a word boundary: this one runs on to the next that does
    try testing.expectEqualStrings("E:\\p.jpgx E:\\w.webp", it.next().?);
    try testing.expect(it.next() == null);

    // lazy, from the leftmost drive letter
    var lazy: ImagePaths = .{ .text = "C:\\notes.txt or E:\\q.gif.png" };
    try testing.expectEqualStrings("C:\\notes.txt or E:\\q.gif", lazy.next().?);
    try testing.expect(lazy.next() == null);

    var none: ImagePaths = .{ .text = "C:\\.png c:\\a.png_ x:\\<a.png" };
    try testing.expect(none.next() == null);
}

test "background task notes" {
    try testing.expectEqualStrings("C:\\t\\b1.output", outputFile("Command running in background with ID: b1. Output is being written to: C:\\t\\b1.output\nmore").?);
    try testing.expectEqualStrings("/t/a.output", outputFile("Output is being written to: \nOutput is being written to: /t/a.output.output").?);
    try testing.expect(outputFile("Output is being written to: .output") == null);
    try testing.expect(outputFile("Output is being written to: /t/a\n.output") == null);
    try testing.expect(outputFile("Output is being written to: /t/a\u{2028}.output") == null);

    var it: TaskNotes = .{ .text = "<task-notification>\n<task-id>b1</task-id>\n<output-file>x</output-file>\n<status>completed</status>\n</task-notification><task-id></task-id><task-id>b2</task-id><status></status><status>failed</status>" };
    const one = it.next().?;
    try testing.expectEqualStrings("b1", one.id);
    try testing.expectEqualStrings("completed", one.status);
    const two = it.next().?;
    try testing.expectEqualStrings("b2", two.id);
    try testing.expectEqualStrings("failed", two.status);
    try testing.expect(it.next() == null);
    var open: TaskNotes = .{ .text = "<task-id>b3</task-id> still running" };
    try testing.expect(open.next() == null);
}

test "terminal colours" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("red plain\x1b[2K", try stripAnsi(a, "\x1b[1;31mred\x1b[0m plain\x1b[2K", false));
    try testing.expectEqualStrings("red plain", try stripAnsi(a, "\x1b[1;31mred\x1b[m plain\x1b[2K", true));
    try testing.expectEqualStrings("\x1b[12", try stripAnsi(a, "\x1b[12", true));
    try testing.expectEqualStrings("\x1b]0;t", try stripAnsi(a, "\x1b]0;t", true));
}

test "slash commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/review 123", (try slashCommand(a, "<command-message>review</command-message>\n<command-name> /review </command-name>\n<command-args> 123 </command-args>")).?);
    try testing.expectEqualStrings("/clear", (try slashCommand(a, "<command-name>/clear</command-name>\n<command-args></command-args>")).?);
    try testing.expectEqualStrings("/init", (try slashCommand(a, "<command-name>/init</command-name>")).?);
    try testing.expect((try slashCommand(a, "<command-name>/init")) == null);
    try testing.expect((try slashCommand(a, "hello")) == null);
}
