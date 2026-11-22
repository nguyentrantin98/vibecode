//! Reading a folder on Windows the way Rust's `read_dir` + `metadata()` did: FindFirstFileExW
//! hands back every entry with its attributes, size and time, so there is no call per file
//! (what keeps the explorer and the search fast on huge folders). Shared by fsx and fsearch.

const std = @import("std");
const core = @import("core.zig");
const win = if (core.is_windows) @import("win") else struct {};

pub const Entry = win.WIN32_FIND_DATAW;

const DIRECTORY: u32 = 0x10;
const REPARSE_POINT: u32 = 0x400;
/// set in the reparse tag of symlinks, junctions and mount points (not of OneDrive placeholders)
const NAME_SURROGATE: u32 = 0x2000_0000;

pub const List = struct {
    /// null: an empty drive (it has not even "." to list)
    handle: ?win.HANDLE,
    data: Entry,
    first: bool = true,

    pub fn open(dir: []const u8) !List {
        if (dir.len == 0) return error.FileNotFound;
        const pat = try pattern(core.gpa, dir);
        defer core.gpa.free(pat);
        var l: List = .{ .handle = null, .data = undefined };
        const h = win.FindFirstFileExW(pat.ptr, win.FindExInfoBasic, &l.data, win.FindExSearchNameMatch, null, win.FIND_FIRST_EX_LARGE_FETCH);
        if (h == win.INVALID_HANDLE_VALUE) return switch (win.GetLastError()) {
            // nothing matches "*": the folder is there, with nothing in it
            2 => l,
            3 => error.FileNotFound,
            5 => error.AccessDenied,
            267 => error.NotDir,
            else => error.Unexpected,
        };
        l.handle = h;
        return l;
    }

    /// The next entry ("." and ".." left out); valid until the next call.
    pub fn next(l: *List) ?*const Entry {
        const h = l.handle orelse return null;
        while (true) {
            if (l.first) {
                l.first = false;
            } else if (win.FindNextFileW(h, &l.data) == 0) {
                return null;
            }
            const n = &l.data.cFileName;
            if (n[0] == '.' and (n[1] == 0 or (n[1] == '.' and n[2] == 0))) continue;
            return &l.data;
        }
    }

    pub fn close(l: *List) void {
        if (l.handle) |h| _ = win.FindClose(h);
    }
};

/// `dir\*` as a wide string; paths too long for the plain API get the `\\?\` form.
fn pattern(a: std.mem.Allocator, dir: []const u8) ![:0]u16 {
    const room = 8; // "\\?\UNC\"
    const buf = try a.alloc(u16, room + dir.len + 3);
    errdefer a.free(buf);
    var n = try std.unicode.wtf8ToWtf16Le(buf[room..], dir);
    var start: usize = room;
    const p = buf[room..];
    const is_sep = struct {
        fn f(ch: u16) bool {
            return ch == '\\' or ch == '/';
        }
    }.f;
    if (!is_sep(p[n - 1])) {
        p[n] = '\\';
        n += 1;
    }
    p[n] = '*';
    n += 1;
    p[n] = 0;
    const verbatim = n >= 4 and is_sep(p[0]) and is_sep(p[1]) and p[2] == '?' and is_sep(p[3]);
    if (n >= 248 and !verbatim) {
        // the long form takes no forward slashes
        for (p[0..n]) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
        const L = std.unicode.utf8ToUtf16LeStringLiteral;
        if (n > 2 and p[1] == ':') {
            start = room - 4;
            @memcpy(buf[start..room], L("\\\\?\\"));
        } else if (p[0] == '\\' and p[1] == '\\') {
            // \\server\share\… → \\?\UNC\server\share\…
            start = room - 6;
            @memcpy(buf[start .. room + 2], L("\\\\?\\UNC\\"));
        }
    }
    const len = room + n - start;
    std.mem.copyForwards(u16, buf[0 .. len + 1], buf[start .. room + n + 1]);
    return (try a.realloc(buf, len + 1))[0..len :0];
}

pub fn name(e: *const Entry) []const u16 {
    return std.mem.sliceTo(&e.cFileName, 0);
}

/// A symlink or junction (to a file or a folder).
pub fn isLink(e: *const Entry) bool {
    return e.dwFileAttributes & REPARSE_POINT != 0 and e.dwReserved0 & NAME_SURROGATE != 0;
}

/// A folder, or a link to one.
pub fn isDir(e: *const Entry) bool {
    return e.dwFileAttributes & DIRECTORY != 0;
}

/// hidden or system
pub fn hidden(e: *const Entry) bool {
    return e.dwFileAttributes & 0x6 != 0;
}

pub fn size(e: *const Entry) u64 {
    return @as(u64, e.nFileSizeHigh) << 32 | e.nFileSizeLow;
}

/// Last write, ms since 1970 (0 when unknown or older).
pub fn modifiedMs(e: *const Entry) u64 {
    const t = @as(u64, e.ftLastWriteTime.dwHighDateTime) << 32 | e.ftLastWriteTime.dwLowDateTime;
    const epoch = 116_444_736_000_000_000; // 1601 → 1970, in 100 ns
    return if (t > epoch) (t - epoch) / 10_000 else 0;
}

pub const max_name_bytes = 260 * 3;

/// The name as UTF-8 (a broken surrogate becomes U+FFFD, like `to_string_lossy`).
pub fn nameUtf8(e: *const Entry, buf: *[max_name_bytes]u8) []const u8 {
    const n = std.unicode.wtf16LeToWtf8(buf, name(e));
    std.unicode.wtf8ToUtf8Lossy(buf[0..n], buf[0..n]) catch {};
    return buf[0..n];
}

test "List reads a folder" {
    if (!core.is_windows) return error.SkipZigTest;
    const t = std.testing;
    core.gpa = t.allocator;
    core.io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Tài liệu.txt", .data = "12345" });
    try tmp.dir.createDirPath(t.io, "sub");
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const root = pb[0..try tmp.dir.realPath(t.io, &pb)];

    var l = try List.open(root);
    defer l.close();
    var files: usize = 0;
    var dirs: usize = 0;
    while (l.next()) |e| {
        var nb: [max_name_bytes]u8 = undefined;
        const nm = nameUtf8(e, &nb);
        if (isDir(e)) {
            dirs += 1;
            try t.expectEqualStrings("sub", nm);
        } else {
            files += 1;
            try t.expectEqualStrings("Tài liệu.txt", nm);
            try t.expectEqual(5, size(e));
            try t.expect(modifiedMs(e) > 1_600_000_000_000);
            try t.expect(!hidden(e) and !isLink(e));
        }
    }
    try t.expectEqual(1, files);
    try t.expectEqual(1, dirs);
    var nb2: [std.fs.max_path_bytes]u8 = undefined;
    try t.expectError(error.FileNotFound, List.open(try std.fmt.bufPrint(&nb2, "{s}\\no\\such", .{root})));
}

test "pattern" {
    if (!core.is_windows) return error.SkipZigTest;
    const t = std.testing;
    const a = t.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const p1 = try pattern(a, "C:\\Users");
    defer a.free(p1);
    try t.expectEqualSlices(u16, L("C:\\Users\\*"), p1);
    const p2 = try pattern(a, "C:\\");
    defer a.free(p2);
    try t.expectEqualSlices(u16, L("C:\\*"), p2);
    // long paths: the \\?\ form, backslashes only
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(a);
    try long.appendSlice(a, "D:/");
    for (0..30) |_| try long.appendSlice(a, "abcdefghi\\");
    try long.append(a, 'x');
    const p3 = try pattern(a, long.items);
    defer a.free(p3);
    try t.expect(std.mem.startsWith(u16, p3, L("\\\\?\\D:\\abcdefghi\\")));
    try t.expect(std.mem.endsWith(u16, p3, L("\\x\\*")));
    long.clearRetainingCapacity();
    try long.appendSlice(a, "\\\\server\\share\\");
    for (0..30) |_| try long.appendSlice(a, "abcdefghi\\");
    const p4 = try pattern(a, long.items);
    defer a.free(p4);
    try t.expect(std.mem.startsWith(u16, p4, L("\\\\?\\UNC\\server\\share\\abcdefghi\\")));
    try t.expect(std.mem.endsWith(u16, p4, L("abcdefghi\\*")));
}
