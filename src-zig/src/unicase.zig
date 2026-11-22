//! Unicode case for file names, titles and URLs (std only knows ASCII): what Rust's
//! `char::to_lowercase`, `is_uppercase`, `is_lowercase` and `is_alphanumeric` gave the search and
//! the sorting. Written by hand, so it covers the scripts that have case and turn up in file
//! names — Latin (with Vietnamese), Greek, Cyrillic, Armenian, full-width letters — and leaves
//! every other character as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Latin Extended-B letters whose small form is not the next code point.
const odd_pairs = [_][2]u16{
    .{ 0x0181, 0x0253 }, .{ 0x0186, 0x0254 }, .{ 0x0189, 0x0256 }, .{ 0x018A, 0x0257 }, .{ 0x018E, 0x01DD },
    .{ 0x018F, 0x0259 }, .{ 0x0190, 0x025B }, .{ 0x0193, 0x0260 }, .{ 0x0194, 0x0263 }, .{ 0x0196, 0x0269 },
    .{ 0x0197, 0x0268 }, .{ 0x019C, 0x026F }, .{ 0x019D, 0x0272 }, .{ 0x019F, 0x0275 }, .{ 0x01A6, 0x0280 },
    .{ 0x01A9, 0x0283 }, .{ 0x01AE, 0x0288 }, .{ 0x01B1, 0x028A }, .{ 0x01B2, 0x028B }, .{ 0x01B7, 0x0292 },
    .{ 0x01C4, 0x01C6 }, .{ 0x01C5, 0x01C6 }, .{ 0x01C7, 0x01C9 }, .{ 0x01C8, 0x01C9 }, .{ 0x01CA, 0x01CC },
    .{ 0x01CB, 0x01CC }, .{ 0x01F1, 0x01F3 }, .{ 0x01F2, 0x01F3 }, .{ 0x01F6, 0x0195 }, .{ 0x01F7, 0x01BF },
    .{ 0x0220, 0x019E }, .{ 0x023A, 0x2C65 }, .{ 0x023D, 0x019A }, .{ 0x023E, 0x2C66 }, .{ 0x0243, 0x0180 },
    .{ 0x0244, 0x0289 }, .{ 0x0245, 0x028C },
};
/// Latin Extended-B capitals followed by their small letter.
const next_pairs = [_]u16{
    0x0182, 0x0184, 0x0187, 0x018B, 0x0191, 0x0198, 0x01A0, 0x01A2, 0x01A4, 0x01A7, 0x01AC, 0x01AF, 0x01B3,
    0x01B5, 0x01B8, 0x01BC, 0x01F4, 0x023B, 0x0241,
};

/// The small letter of `c` (`c` itself when it has none). One code point in, one out.
pub fn lower(c: u21) u21 {
    if (c < 0x80) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    if (c < 0x100) return if (c >= 0xC0 and c <= 0xDE and c != 0xD7) c + 32 else c;
    if (c < 0x180) {
        // Latin Extended-A: pairs, capital first
        if (c == 0x130) return 'i';
        if (c == 0x178) return 0xFF;
        const even_first = c < 0x138 or (c >= 0x14A and c < 0x178);
        if (c == 0x131 or c == 0x138 or c == 0x149 or c == 0x17F) return c;
        return if ((c & 1 == 0) == even_first) c + 1 else c;
    }
    if (c < 0x250) {
        if ((c >= 0x1CD and c <= 0x1DC)) return if (c & 1 == 1) c + 1 else c;
        if ((c >= 0x1DE and c <= 0x1EF) or (c >= 0x1F8 and c <= 0x21F) or (c >= 0x222 and c <= 0x233) or c >= 0x246)
            return if (c & 1 == 0) c + 1 else c;
        for (next_pairs) |p| if (p == c) return c + 1;
        for (odd_pairs) |p| if (p[0] == c) return p[1];
        return c;
    }
    if (c < 0x370) return c;
    if (c < 0x400) {
        // Greek
        if (c >= 0x391 and c <= 0x3AB) return if (c == 0x3A2) c else c + 32;
        return switch (c) {
            0x386 => 0x3AC,
            0x388...0x38A => c + 37,
            0x38C => 0x3CC,
            0x38E, 0x38F => c + 63,
            else => c,
        };
    }
    if (c < 0x530) {
        // Cyrillic
        if (c < 0x410) return c + 80;
        if (c < 0x430) return c + 32;
        if (c < 0x460) return c;
        if (c >= 0x482 and c <= 0x489) return c;
        if (c == 0x4C0) return 0x4CF;
        if (c > 0x4C0 and c < 0x4CF) return if (c & 1 == 1) c + 1 else c;
        if (c == 0x4CF) return c;
        return if (c & 1 == 0) c + 1 else c;
    }
    if (c < 0x560) return if (c >= 0x531 and c <= 0x556) c + 48 else c; // Armenian
    if (c < 0x1E00) return c;
    if (c < 0x1F00) {
        // Latin Extended Additional (Vietnamese is here)
        if (c == 0x1E9E) return 0xDF;
        if (c >= 0x1E96 and c < 0x1EA0) return c;
        return if (c & 1 == 0) c + 1 else c;
    }
    return switch (c) {
        0x2126 => 0x3C9, // ohm
        0x212A => 'k', // kelvin
        0x212B => 0xE5, // angstrom
        0x2160...0x216F => c + 16, // Roman numerals
        0x24B6...0x24CF => c + 26, // circled letters
        0xFF21...0xFF3A => c + 32, // full-width
        else => c,
    };
}

pub fn isUpper(c: u21) bool {
    return lower(c) != c;
}

pub fn isLower(c: u21) bool {
    if (c < 0x80) return c >= 'a' and c <= 'z';
    if (lower(c) != c) return false;
    // the blocks `lower` knows: a letter there that is not a capital is a small one
    return switch (c) {
        0xB5, 0xDF...0xF6, 0xF8...0xFF => true,
        0x100...0x1BA, 0x1BC...0x1BF, 0x1C4...0x2AF => true,
        0x3AC...0x3CE, 0x430...0x45F => true,
        0x460...0x481, 0x48A...0x52F => true,
        0x561...0x587 => true,
        0x1E00...0x1EFF => true,
        0xFF41...0xFF5A => true,
        else => false,
    };
}

/// A letter or a digit of any script. Outside ASCII this is "not punctuation, not a symbol, not
/// a combining mark" for the blocks where those live.
pub fn isAlphanumeric(c: u21) bool {
    if (c < 0x80) return std.ascii.isAlphanumeric(@intCast(c));
    return switch (c) {
        0x80...0xBF => c == 0xAA or c == 0xB2 or c == 0xB3 or c == 0xB5 or c == 0xB9 or c == 0xBA or (c >= 0xBC and c <= 0xBE),
        0xD7, 0xF7 => false,
        0x2C2...0x2C5, 0x2D2...0x2DF, 0x2E5...0x2EB, 0x2ED, 0x2EF...0x2FF => false, // modifier symbols
        0x300...0x36F => false, // combining marks (a name typed with separate accents)
        0x2000...0x206F, 0x207A...0x207E, 0x208A...0x208E, 0x20A0...0x20FF => false, // punctuation, signs, currency
        0x2190...0x245F, 0x2500...0x2775, 0x2794...0x2BFF, 0x2E00...0x2E7F => false, // arrows, maths, shapes
        0x3000...0x3004, 0x3008...0x3020, 0x3030, 0x303D...0x303F => false, // CJK punctuation
        0xD800...0xF8FF => false, // surrogates, private use
        0xFE10...0xFE6F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0xFFE0...0xFFFF => false,
        0x1F000...0x1FAFF => false, // emoji and pictographs
        else => true,
    };
}

/// `s` in small letters, allocated in `a`. Bytes that are not UTF-8 are copied as they are.
pub fn lowerStr(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try lowerInto(a, &out, s);
    return out.toOwnedSlice(a);
}

/// Appends `s` in small letters to `out`.
pub fn lowerInto(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.ensureUnusedCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            try out.append(a, std.ascii.toLower(b));
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
        const cp = if (n > 1 and i + n <= s.len) std.unicode.utf8Decode(s[i..][0..n]) catch null else null;
        if (cp) |ch| {
            var buf: [4]u8 = undefined;
            const m = std.unicode.utf8Encode(lower(ch), &buf) catch unreachable;
            try out.appendSlice(a, buf[0..m]);
            i += n;
        } else {
            try out.append(a, b);
            i += 1;
        }
    }
}

/// Rust's `char::is_whitespace`: the ASCII ones, and the no-break, typographic and ideographic spaces.
pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `s` with every kind of space as a plain one, so that splitting at ' ' gives the words Rust's
/// `split_whitespace` gave. Bytes that are not UTF-8 become spaces too.
pub fn plainSpaces(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            out.appendAssumeCapacity(if (isWhitespace(b)) ' ' else b);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
        const cp = if (n > 1 and i + n <= s.len) std.unicode.utf8Decode(s[i..][0..n]) catch null else null;
        if (cp == null or isWhitespace(cp.?)) {
            out.appendAssumeCapacity(' ');
            i += if (cp == null) 1 else n;
        } else {
            out.appendSliceAssumeCapacity(s[i..][0..n]);
            i += n;
        }
    }
    return out.toOwnedSlice(a);
}

test "lower" {
    const t = std.testing;
    const pairs = [_][2]u21{
        .{ 'A', 'a' }, .{ 'z', 'z' }, .{ '1', '1' },
        .{ 'À', 'à' },
        .{ 'Þ', 'þ' },
        .{ '×', '×' },
        .{ 'ß', 'ß' },
        .{ 'Ă', 'ă' },
        .{ 'Đ', 'đ' },
        .{ 'Ĩ', 'ĩ' },
        .{ 'İ', 'i' },
        .{ 'ı', 'ı' },
        .{ 'Ĺ', 'ĺ' },
        .{ 'ĸ', 'ĸ' },
        .{ 'Ň', 'ň' },
        .{ 'ŉ', 'ŉ' },
        .{ 'Ŋ', 'ŋ' },
        .{ 'Ũ', 'ũ' },
        .{ 'Ÿ', 'ÿ' },
        .{ 'Ź', 'ź' },
        .{ 'Ž', 'ž' },
        .{ 'ſ', 'ſ' },
        .{ 'Ơ', 'ơ' },
        .{ 'Ư', 'ư' },
        .{ 'Ǎ', 'ǎ' },
        .{ 'Ǆ', 'ǆ' },
        .{ 'Ș', 'ș' },
        .{ 'Ɛ', 'ɛ' },
        .{ 'Ạ', 'ạ' },
        .{ 'Ặ', 'ặ' },
        .{ 'Ệ', 'ệ' },
        .{ 'Ỹ', 'ỹ' },
        .{ 'ẞ', 'ß' },
        .{ 'ệ', 'ệ' },
        .{ 'Α', 'α' },
        .{ 'Ω', 'ω' },
        .{ 'Ά', 'ά' },
        .{ 'Ή', 'ή' },
        .{ 'Ό', 'ό' },
        .{ 'Ώ', 'ώ' },
        .{ 'ς', 'ς' },
        .{ 'Ё', 'ё' },
        .{ 'Я', 'я' },
        .{ 'я', 'я' },
        .{ 'Ґ', 'ґ' },
        .{ 'Ӏ', 'ӏ' },
        .{ 'Ӂ', 'ӂ' },
        .{ 'Ӑ', 'ӑ' },
        .{ 'Ա', 'ա' },
        .{ 'Ａ', 'ａ' },
        .{ 'K', 'k' },
        .{ '中', '中' },
        .{ 'Ⅳ', 'ⅳ' },
    };
    for (pairs) |p| try t.expectEqual(p[1], lower(p[0]));
}

test "classes" {
    const t = std.testing;
    try t.expect(isUpper('E') and !isUpper('e') and isUpper('Ệ') and !isUpper('ệ') and !isUpper('5') and !isUpper('中'));
    try t.expect(isLower('e') and !isLower('E') and isLower('ệ') and isLower('đ') and !isLower('Đ') and !isLower('_') and !isLower('中') and isLower('я'));
    try t.expect(isAlphanumeric('a') and isAlphanumeric('9') and isAlphanumeric('ệ') and isAlphanumeric('中') and isAlphanumeric('я'));
    try t.expect(!isAlphanumeric(' ') and !isAlphanumeric('_') and !isAlphanumeric('-') and !isAlphanumeric('.'));
    try t.expect(!isAlphanumeric('—') and !isAlphanumeric('·') and !isAlphanumeric('×') and !isAlphanumeric(0x301) and !isAlphanumeric('→') and !isAlphanumeric(0x1F600));
}

test "plainSpaces" {
    const a = std.testing.allocator;
    const s = try plainSpaces(a, "tài\u{A0}liệu\t\u{3000}x\ny \xff");
    defer a.free(s);
    try std.testing.expectEqualStrings("tài liệu  x y  ", s);
}

test "lowerStr" {
    const a = std.testing.allocator;
    const s = try lowerStr(a, "Tài LIỆU Đặc Biệt.DOCX \xff!");
    defer a.free(s);
    try std.testing.expectEqualStrings("tài liệu đặc biệt.docx \xff!", s);
}
