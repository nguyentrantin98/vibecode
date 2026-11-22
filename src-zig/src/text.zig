//! Small text helpers for mail.zig, gmail.zig and zalo_tasks.zig that see whitespace and characters
//! the way the Rust build did (`char::is_whitespace`, `str::trim`, `chars().take(n)`, the regex
//! `\s+`): by Unicode code point, not by byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unicode White_Space.
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// How many bytes the character at `s[i]` takes; a byte that is not UTF-8 counts as one.
fn charLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len) return 1;
    _ = std.unicode.utf8Decode(s[i .. i + n]) catch return 1;
    return n;
}

fn whitespaceAt(s: []const u8, i: usize) bool {
    const n = charLen(s, i);
    // a lone byte above ASCII is not a character
    if (n == 1 and s[i] >= 0x80) return false;
    return isWhitespace(std.unicode.utf8Decode(s[i .. i + n]) catch return false);
}

/// `s` without leading whitespace.
pub fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and whitespaceAt(s, i)) i += charLen(s, i);
    return s[i..];
}

/// `s` without trailing whitespace.
pub fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and s[start] & 0xC0 == 0x80) start -= 1;
        if (start + charLen(s, start) != end or !whitespaceAt(s, start)) break;
        end = start;
    }
    return s[0..end];
}

pub fn trim(s: []const u8) []const u8 {
    return trimEnd(trimStart(s));
}

/// The first `n` characters of `s`.
pub fn takeChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len and count < n) : (count += 1) i += charLen(s, i);
    return s[0..i];
}

/// Every run of whitespace as one space.
pub fn collapseWhitespace(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    var in_run = false;
    while (i < s.len) {
        const n = charLen(s, i);
        if (whitespaceAt(s, i)) {
            if (!in_run) out.appendAssumeCapacity(' ');
            in_run = true;
        } else {
            out.appendSliceAssumeCapacity(s[i .. i + n]);
            in_run = false;
        }
        i += n;
    }
    return out.items;
}

const testing = std.testing;

test "trim" {
    try testing.expectEqualStrings("a b", trim(" \t\u{a0}a b\u{3000}\r\n"));
    try testing.expectEqualStrings("", trim(" \u{2003} "));
    try testing.expectEqualStrings("", trim(""));
    try testing.expectEqualStrings("é", trim("é"));
    try testing.expectEqualStrings("a ", trimStart("  a "));
    try testing.expectEqualStrings("  a", trimEnd("  a "));
    // bytes that are not UTF-8 are not whitespace
    try testing.expectEqualStrings("\xa0", trim(" \xa0 "));
    try testing.expectEqualStrings("a\xc2", trim("a\xc2 "));
}

test "takeChars" {
    try testing.expectEqualStrings("Việ", takeChars("Việt Nam", 3));
    try testing.expectEqualStrings("Việt Nam", takeChars("Việt Nam", 80));
    try testing.expectEqualStrings("", takeChars("abc", 0));
    try testing.expectEqualStrings("😀é", takeChars("😀éx", 2));
    try testing.expectEqualStrings("\xff\xfe", takeChars("\xff\xfe\xfd", 2));
}

test "collapseWhitespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b c", try collapseWhitespace(a, "a  b\r\n\tc"));
    try testing.expectEqualStrings(" a b ", try collapseWhitespace(a, "\u{a0} a\u{2003}\u{3000}b\n"));
    try testing.expectEqualStrings("việc cần làm", try collapseWhitespace(a, "việc   cần\nlàm"));
    try testing.expectEqualStrings("", try collapseWhitespace(a, ""));
}
