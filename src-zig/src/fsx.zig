//! Files for the explorer, quick-open and editor, and the project watcher.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const watch = @import("watch.zig");
const winfs = @import("winfs.zig");
const unicase = @import("unicase.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const c = if (core.is_windows) core.host.win.c else struct {};
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const commands = .{
    .{ "fs_read_dir", fs_read_dir },
    .{ "fs_explore", fs_explore },
    .{ "fs_places", fs_places },
    .{ "fs_read_file", fs_read_file },
    .{ "fs_write_file", fs_write_file },
    .{ "fs_list_files", fs_list_files },
    .{ "fs_watch", fs_watch },
    .{ "fs_reveal", fs_reveal },
    .{ "fs_open_path", fs_open_path },
    .{ "fs_rename", fs_rename },
    .{ "fs_copy", fs_copy },
    .{ "fs_trash", fs_trash },
    .{ "fs_create", fs_create },
};

const HIDDEN = [_][]const u8{ ".git", "node_modules", ".DS_Store", "Thumbs.db" };
const SKIP_WALK = [_][]const u8{ ".git", "node_modules", "out", "dist", "build", ".next", ".venv", "venv", "__pycache__", "bin", "obj", ".vs" };

fn oneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    isDir: bool,
};

fn fs_read_dir(call: *ipc.Call, args: struct { dir: []const u8 }) ![]DirEntry {
    return readDir(call.arena, args.dir);
}

fn readDir(a: Allocator, dir: []const u8) ![]DirEntry {
    if (!core.is_windows) return error.Unsupported;
    var list = try winfs.List.open(dir);
    defer list.close();
    const Row = struct { e: DirEntry, key: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    while (list.next()) |e| {
        var nb: [winfs.max_name_bytes]u8 = undefined;
        const name = try a.dupe(u8, winfs.nameUtf8(e, &nb));
        if (oneOf(name, &HIDDEN)) continue;
        try rows.append(a, .{
            // a link to a folder is listed as a file, as it always was
            .e = .{ .name = name, .path = try std.fs.path.join(a, &.{ dir, name }), .isDir = winfs.isDir(e) and !winfs.isLink(e) },
            .key = try unicase.lowerStr(a, name),
        });
    }
    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            if (x.e.isDir != y.e.isDir) return x.e.isDir;
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
    const out = try a.alloc(DirEntry, rows.items.len);
    for (rows.items, out) |r, *o| o.* = r.e;
    return out;
}

/// A row of the File Explorer tab: everything in the folder (hidden / system items flagged, not dropped).
pub const ExEntry = struct {
    name: []const u8,
    path: []const u8,
    isDir: bool,
    size: u64,
    /// ms since 1970; 0 unknown
    modified: u64,
    hidden: bool,
};

fn fs_explore(call: *ipc.Call, args: struct { dir: []const u8 }) ![]ExEntry {
    return explore(call.arena, args.dir);
}

fn explore(a: Allocator, dir: []const u8) ![]ExEntry {
    if (!core.is_windows) return error.Unsupported;
    var list = try winfs.List.open(dir);
    defer list.close();
    var out: std.ArrayList(ExEntry) = .empty;
    while (list.next()) |e| {
        var nb: [winfs.max_name_bytes]u8 = undefined;
        const name = try a.dupe(u8, winfs.nameUtf8(e, &nb));
        const path = try std.fs.path.join(a, &.{ dir, name });
        // links and junctions: what they point at decides folder or file
        const is_dir = if (winfs.isLink(e)) core.isDir(path) else winfs.isDir(e);
        try out.append(a, .{
            .name = name,
            .path = path,
            .isDir = is_dir,
            .size = if (is_dir) 0 else winfs.size(e),
            .modified = winfs.modifiedMs(e),
            .hidden = winfs.hidden(e),
        });
    }
    return out.items;
}

/// The File Explorer's left column: the user's folders and the drives.
pub const Place = struct {
    /// home, desktop, documents, downloads, pictures, videos, music, drive
    kind: []const u8,
    name: []const u8,
    path: []const u8,
    /// drives: bytes, 0 unknown
    total: u64,
    free: u64,
};

fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) c.GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

fn fs_places(call: *ipc.Call) ![]Place {
    const a = call.arena;
    var out: std.ArrayList(Place) = .empty;
    if (core.is_windows) {
        // the FOLDERID_… of the user's folders
        const folders = [_]struct { []const u8, []const u8, c.GUID }{
            .{ "home", "Home", guid(0x5E6C858F, 0x0E22, 0x4760, .{ 0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73 }) },
            .{ "desktop", "Desktop", guid(0xB4BFCC3A, 0xDB2C, 0x424C, .{ 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 }) },
            .{ "documents", "Documents", guid(0xFDD39AD0, 0x238F, 0x46AF, .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 }) },
            .{ "downloads", "Downloads", guid(0x374DE290, 0x123F, 0x4565, .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B }) },
            .{ "pictures", "Pictures", guid(0x33E28130, 0x4E1E, 0x4676, .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB }) },
            .{ "videos", "Videos", guid(0x18989B1D, 0x99B5, 0x455B, .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC }) },
            .{ "music", "Music", guid(0x4BD8D571, 0x6D19, 0x48D3, .{ 0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43 }) },
        };
        for (&folders) |*f| {
            const path = knownFolder(a, &f[2]) orelse continue;
            if (core.isDir(path)) try out.append(a, .{ .kind = f[0], .name = f[1], .path = path, .total = 0, .free = 0 });
        }
    }
    try out.appendSlice(a, try drives(a));
    return out.items;
}

fn knownFolder(a: Allocator, id: *const c.GUID) ?[]u8 {
    var p: c.PWSTR = null;
    const hr = c.SHGetKnownFolderPath(id, 0, null, &p);
    defer c.CoTaskMemFree(p);
    if (hr < 0 or p == null) return null;
    return core.fromWide(a, @ptrCast(p)) catch null;
}

fn drives(a: Allocator) ![]Place {
    var out: std.ArrayList(Place) = .empty;
    if (!core.is_windows) {
        try out.append(a, .{ .kind = "drive", .name = "/", .path = "/", .total = 0, .free = 0 });
        return out.items;
    }
    const mask = c.GetLogicalDrives();
    for (0..26) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const letter: u8 = 'A' + @as(u8, @intCast(i));
        const root = [_:0]u16{ letter, ':', '\\' };
        const kind = c.GetDriveTypeW(&root);
        var label: [261]u16 = @splat(0);
        var total: c.ULARGE_INTEGER = std.mem.zeroes(c.ULARGE_INTEGER);
        var free: c.ULARGE_INTEGER = std.mem.zeroes(c.ULARGE_INTEGER);
        // network drives can hang when the server is gone: name only
        const mounted = kind != c.DRIVE_REMOTE and c.GetVolumeInformationW(&root, &label, label.len, null, null, null, null, 0) != 0;
        if (mounted) {
            _ = c.GetDiskFreeSpaceExW(&root, null, &total, &free);
        } else if (kind == c.DRIVE_CDROM or kind == c.DRIVE_REMOVABLE) {
            continue; // an empty card reader / disc drive
        }
        const label8 = try std.unicode.wtf16LeToWtf8Alloc(a, std.mem.sliceTo(&label, 0));
        std.unicode.wtf8ToUtf8Lossy(label8, label8) catch {};
        const shown: []const u8 = if (label8.len > 0) label8 else switch (kind) {
            c.DRIVE_REMOVABLE => "USB Drive",
            c.DRIVE_REMOTE => "Network Drive",
            c.DRIVE_CDROM => "CD Drive",
            else => "Local Disk",
        };
        try out.append(a, .{
            .kind = "drive",
            .name = try std.fmt.allocPrint(a, "{s} ({c}:)", .{ shown, letter }),
            .path = try std.fmt.allocPrint(a, "{c}:\\", .{letter}),
            .total = total.QuadPart,
            .free = free.QuadPart,
        });
    }
    return out.items;
}

/// the drives searched from This PC: mounted, not on the network
pub fn localDrives(a: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try drives(a)) |d| {
        if (d.total > 0) try out.append(a, d.path);
    }
    return out.items;
}

pub const FileContent = struct {
    content: []const u8,
    binary: bool,
    tooLarge: bool,
};

fn fs_read_file(call: *ipc.Call, args: struct { path: []const u8 }) !FileContent {
    return readFile(call.arena, args.path);
}

fn readFile(a: Allocator, path: []const u8) !FileContent {
    const max = 8 * 1024 * 1024;
    const st = try Dir.cwd().statFile(core.io, path, .{});
    if (st.size > max) return .{ .content = "", .binary = false, .tooLarge = true };
    // (a file that grew past the limit since the stat is too large as well)
    const buf = core.readFileAlloc(a, path, max + 1) catch |e| switch (e) {
        error.StreamTooLong => return .{ .content = "", .binary = false, .tooLarge = true },
        else => return e,
    };
    if (std.mem.indexOfScalar(u8, buf[0..@min(buf.len, 8000)], 0) != null) return .{ .content = "", .binary = true, .tooLarge = false };
    return .{ .content = try utf8Lossy(a, buf), .binary = false, .tooLarge = false };
}

/// `s` as UTF-8, every broken sequence replaced by U+FFFD (Rust's `String::from_utf8_lossy`).
fn utf8Lossy(a: Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len + 16);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            try out.append(a, b);
            i += 1;
            continue;
        }
        // the lead byte says how long the sequence is and what its second byte may be
        const len: usize = switch (b) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => 0,
        };
        const lo: u8 = if (b == 0xE0) 0xA0 else if (b == 0xF0) 0x90 else 0x80;
        const hi: u8 = if (b == 0xED) 0x9F else if (b == 0xF4) 0x8F else 0xBF;
        var j: usize = 1;
        while (j < len and i + j < s.len) : (j += 1) {
            const x = s[i + j];
            if (j == 1) {
                if (x < lo or x > hi) break;
            } else if (x & 0xC0 != 0x80) break;
        }
        if (len != 0 and j == len) {
            try out.appendSlice(a, s[i..][0..len]);
        } else {
            // one mark for the bytes that did start a character
            try out.appendSlice(a, "\u{FFFD}");
        }
        i += j;
    }
    return out.items;
}

fn fs_write_file(_: *ipc.Call, args: struct { path: []const u8, content: []const u8 }) !void {
    try Dir.cwd().writeFile(core.io, .{ .sub_path = args.path, .data = args.content });
}

/// Flat list of files (relative, forward slashes) for quick-open.
fn fs_list_files(call: *ipc.Call, args: struct { root: []const u8 }) ![]const []const u8 {
    return listFiles(call.arena, args.root, 20_000);
}

fn listFiles(a: Allocator, root: []const u8, limit: usize) ![]const []const u8 {
    if (!core.is_windows) return error.Unsupported;
    var out: std.ArrayList([]const u8) = .empty;
    // folders still to read, relative to the root ("" is the root itself)
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(a, "");
    while (stack.pop()) |rel| {
        const dir = if (rel.len == 0) root else try std.fs.path.join(a, &.{ root, rel });
        var list = winfs.List.open(dir) catch continue;
        defer list.close();
        const first_sub = stack.items.len;
        while (list.next()) |e| {
            if (out.items.len >= limit) return out.items;
            var nb: [winfs.max_name_bytes]u8 = undefined;
            const name = winfs.nameUtf8(e, &nb);
            const sub = if (rel.len == 0) try a.dupe(u8, name) else try std.mem.concat(a, u8, &.{ rel, "/", name });
            if (winfs.isDir(e) and !winfs.isLink(e)) {
                if (!oneOf(name, &SKIP_WALK)) try stack.append(a, sub);
            } else {
                try out.append(a, sub);
            }
        }
        // depth-first in directory order, like the old recursive walk
        std.mem.reverse([]const u8, stack.items[first_sub..]);
    }
    return out.items;
}

// ---------------- watcher ----------------

const WatchCtx = struct {
    base: []const u8,
    git_dir: ?[]const u8,

    fn destroy(x: *WatchCtx) void {
        core.gpa.free(x.base);
        if (x.git_dir) |g| core.gpa.free(g);
        core.gpa.destroy(x);
    }
};

var watch_mutex: core.Mutex = .{};
var watcher: ?*watch.Watcher = null;
var watch_ctx: ?*WatchCtx = null;

/// Folders whose churn (build output, caches) means nothing to the explorer or the Changes panel.
/// A `cargo build` / `dotnet build` / `next dev` writes thousands of files there; each batch used to
/// re-run `git status` and re-read the open explorer folders.
const SKIP_WATCH = [_][]const u8{
    "node_modules", "out",           "dist",    "build",       "target", "bin",  "obj", ".vs", ".next", ".nuxt", ".turbo", ".angular",
    ".svelte-kit",  ".parcel-cache", ".gradle", "__pycache__", ".venv",  "venv",
};

const separators = "\\/";

/// `p` below `base`, by whole path components (Rust's `Path::strip_prefix`): "" when they are the
/// same path, null when `p` is not inside `base`.
fn stripPrefix(p: []const u8, base: []const u8) ?[]const u8 {
    var pi = std.mem.tokenizeAny(u8, p, separators);
    var bi = std.mem.tokenizeAny(u8, base, separators);
    var first = true;
    while (bi.next()) |b| {
        const x = pi.next() orelse return null;
        // drive letters compare without case
        const same = if (first and b.len == 2 and b[1] == ':') std.ascii.eqlIgnoreCase(x, b) else std.mem.eql(u8, x, b);
        if (!same) return null;
        first = false;
    }
    return pi.rest();
}

/// Inside a git directory, only what changes the Changes panel or the history: the branch, refs,
/// the index (staging). `rest` is the path below the git directory.
fn gitRelevant(rest: []const u8, p: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rest, separators);
    const keep = if (it.next()) |first|
        if (oneOf(first, &.{ "HEAD", "index", "packed-refs", "MERGE_HEAD" })) it.next() == null else std.mem.eql(u8, first, "refs")
    else
        true;
    return keep and !std.mem.eql(u8, std.fs.path.extension(p), ".lock");
}

const Seen = enum { skip, file, git };

/// `p` relative to the watched root (a project that itself lives under e.g. `D:\build` still
/// counts). `git_dir`: the repository's git directory when it is outside the root (the folder
/// opened is inside a bigger repo, or is a worktree).
fn classify(root: []const u8, git_dir: ?[]const u8, p: []const u8) Seen {
    if (git_dir) |g| {
        if (stripPrefix(p, g)) |rest| return if (gitRelevant(rest, p)) .git else .skip;
    }
    const rel = stripPrefix(p, root) orelse p;
    var it = std.mem.tokenizeAny(u8, rel, separators);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git")) return if (gitRelevant(it.rest(), p)) .git else .skip;
    }
    it.reset();
    while (it.next()) |part| {
        if (oneOf(part, &SKIP_WATCH)) return .skip;
    }
    return .file;
}

/// The repository's git directory when it is not `<root>/.git` (opened a subfolder of a repo, or a
/// worktree): a commit only touches that directory, so it has to be watched as well.
fn outsideGitDir(a: Allocator, root: []const u8) ?[]u8 {
    const r = core.run(a, &.{ "git", "rev-parse", "--absolute-git-dir" }, .{ .cwd = root }) catch return null;
    if (!r.ok()) return null;
    const dir = a.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch return null;
    std.mem.replaceScalar(u8, dir, '/', std.fs.path.sep);
    const ld = unicase.lowerStr(a, dir) catch return null;
    const lr = unicase.lowerStr(a, root) catch return null;
    return if (std.mem.startsWith(u8, ld, lr)) null else dir;
}

fn stopWatcher() void {
    if (watcher) |w| w.stop(); // waits for the last batch
    watcher = null;
    if (watch_ctx) |x| x.destroy();
    watch_ctx = null;
}

fn fs_watch(call: *ipc.Call, args: struct { root: ?[]const u8 = null }) !void {
    const root = args.root orelse {
        watch_mutex.lock();
        defer watch_mutex.unlock();
        stopWatcher();
        return;
    };
    const git_dir = outsideGitDir(call.arena, root);
    watch_mutex.lock();
    defer watch_mutex.unlock();
    stopWatcher();
    if (!core.isDir(root)) return error.FileNotFound;
    const ctx = try core.gpa.create(WatchCtx);
    ctx.* = .{ .base = try core.gpa.dupe(u8, root), .git_dir = if (git_dir) |g| try core.gpa.dupe(u8, g) else null };
    errdefer ctx.destroy();
    // the git directory is best effort: the panel still refreshes on the project's own file
    // changes without it
    const roots: []const []const u8 = if (git_dir) |g| &.{ root, g } else &.{root};
    watcher = try watch.start(roots, .{ .debounce_ms = 200 }, onChanges, ctx);
    watch_ctx = ctx;
}

const Batch = struct {
    paths: []const []const u8,
    git: bool,
};

/// What one batch of changes means for the page: the files to re-read, and whether git moved.
fn sortBatch(a: Allocator, base: []const u8, git_dir: ?[]const u8, events: []const watch.Event) !Batch {
    // lost events (overflow while several chats write at once): report the root, so the Changes
    // panel and the history still refresh instead of waiting for the next change
    for (events) |e| {
        if (e.kind == .rescan) return .{ .paths = try a.dupe([]const u8, &.{base}), .git = true };
    }
    var git = false;
    var paths: std.ArrayList([]const u8) = .empty;
    for (events) |e| switch (classify(base, git_dir, e.path)) {
        .skip => {},
        .git => git = true,
        .file => try paths.append(a, e.path),
    };
    std.mem.sortUnstable([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var n: usize = 0;
    for (paths.items) |p| {
        if (n > 0 and std.mem.eql(u8, paths.items[n - 1], p)) continue;
        paths.items[n] = p;
        n += 1;
    }
    return .{ .paths = paths.items[0..n], .git = git };
}

fn onChanges(ctx_: ?*anyopaque, events: []const watch.Event) void {
    const ctx: *const WatchCtx = @ptrCast(@alignCast(ctx_.?));
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const b = sortBatch(arena.allocator(), ctx.base, ctx.git_dir, events) catch return;
    if (b.paths.len > 0) core.emit("fs:changed", .{b.paths});
    // a commit, checkout, pull or staging: only the git directory changes
    if (b.git) core.emit("git:changed", .{null}); // payload is the listener's argument list
}

// ---------------- the shell: reveal, open, trash ----------------

/// The absolute path with backslashes, as the shell wants it.
fn fullPath(a: Allocator, path: []const u8) ![:0]u16 {
    const w = try core.wide(a, path);
    const need = c.GetFullPathNameW(w.ptr, 0, null, null);
    if (need == 0) return error.BadPathName;
    const buf = try a.allocSentinel(u16, need, 0);
    const n = c.GetFullPathNameW(w.ptr, need + 1, buf.ptr, null);
    if (n == 0 or n > need) return error.BadPathName;
    return buf[0..n :0];
}

/// What Windows says about an error code, the way Rust's `io::Error` printed it.
fn osError(a: Allocator, code: u32) []const u8 {
    var buf: [1024]u16 = undefined;
    const n = c.FormatMessageW(c.FORMAT_MESSAGE_FROM_SYSTEM | c.FORMAT_MESSAGE_IGNORE_INSERTS, null, code, 0, &buf, buf.len, null);
    const text = std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]) catch "";
    return std.fmt.allocPrint(a, "{s} (os error {d})", .{ std.mem.trim(u8, text, " \r\n\t"), code }) catch "error";
}

/// COM for the shell calls of this thread (worker threads start without it).
const Com = struct {
    hr: c.HRESULT,
    fn init() Com {
        return .{ .hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED) };
    }
    fn deinit(x: Com) void {
        if (x.hr >= 0) c.CoUninitialize();
    }
};

fn shellExecute(file: [*:0]const u16, verb: ?[*:0]const u16, class: ?[*:0]const u16) bool {
    var info = std.mem.zeroes(c.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(c.SHELLEXECUTEINFOW);
    info.nShow = c.SW_SHOWNORMAL;
    info.lpFile = file;
    info.lpVerb = verb;
    info.lpClass = class;
    return c.ShellExecuteExW(&info) != 0;
}

/// Opens the folder an item is in, with the item selected.
fn fs_reveal(call: *ipc.Call, args: struct { path: []const u8 }) !void {
    if (!core.is_windows) return error.Unsupported;
    const a = call.arena;
    const full = try fullPath(a, args.path);
    if (c.GetFileAttributesW(full.ptr) == c.INVALID_FILE_ATTRIBUTES) return call.fail("path doesn't exist", .{});
    const full8 = try std.unicode.wtf16LeToWtf8Alloc(a, full);
    const parent = try core.wide(a, std.fs.path.dirname(full8) orelse return call.fail("{s} has no parent folder", .{full8}));

    const com = Com.init();
    defer com.deinit();
    const dir_id = c.ILCreateFromPathW(parent.ptr);
    defer c.ILFree(dir_id);
    const item_id = c.ILCreateFromPathW(full.ptr);
    defer c.ILFree(item_id);
    if (dir_id == null or item_id == null) return call.fail("can't show {s}", .{full8});
    var items = [_]c.LPCITEMIDLIST{item_id};
    const hr = c.SHOpenFolderAndSelectItems(dir_id, 1, &items, 0);
    // On some systems the call mysteriously fails with "file not found" even though the file is
    // there. ShellExecute works then (although it won't select the file).
    const not_found: c.HRESULT = @bitCast(@as(u32, 0x80070002));
    if (hr == not_found or hr == 2) {
        const is_dir = core.isDir(full8);
        if (!shellExecute(parent.ptr, if (is_dir) L("explore") else null, if (is_dir) L("folder") else null))
            return call.failMsg(osError(a, c.GetLastError()));
    }
}

/// Opens a file / folder with the OS default handler; '' on success, else the error (like Electron).
fn fs_open_path(call: *ipc.Call, args: struct { path: []const u8 }) ![]const u8 {
    if (!core.is_windows) return error.Unsupported;
    const a = call.arena;
    const w = try core.wide(a, args.path);
    const attrs = c.GetFileAttributesW(w.ptr);
    if (attrs == c.INVALID_FILE_ATTRIBUTES) return osError(a, c.GetLastError());
    const com = Com.init();
    defer com.deinit();
    const is_dir = attrs & c.FILE_ATTRIBUTE_DIRECTORY != 0;
    if (is_dir) {
        // a folder: its Explorer window (the one already showing it comes to the front)
        if (fullPath(a, args.path)) |full| {
            const folder = c.ILCreateFromPathW(full.ptr);
            defer c.ILFree(folder);
            if (folder != null) {
                var items = [_]c.LPCITEMIDLIST{folder};
                if (c.SHOpenFolderAndSelectItems(folder, 1, &items, 0) == 0) return "";
            }
        } else |_| {}
    }
    if (shellExecute(w.ptr, if (is_dir) L("explore") else null, if (is_dir) L("folder") else null)) return "";
    return osError(a, c.GetLastError());
}

fn alreadyExists(call: *ipc.Call, path: []const u8) error{Failed} {
    return if (settings.vi()) call.fail("{s} đã tồn tại", .{path}) else call.fail("{s} already exists", .{path});
}

/// Rename or move; refuses to overwrite.
fn fs_rename(call: *ipc.Call, args: struct { from: []const u8, to: []const u8 }) !void {
    if (core.exists(args.to)) return alreadyExists(call, args.to);
    try Dir.rename(Dir.cwd(), args.from, Dir.cwd(), args.to, core.io);
}

/// Copy a file or folder into `dir`, as "name copy.ext" (2, 3…) when the name is taken. Returns the new path.
fn fs_copy(call: *ipc.Call, args: struct { from: []const u8, dir: []const u8 }) ![]const u8 {
    const a = call.arena;
    const dst = try copyTarget(a, args.from, args.dir) orelse return call.fail("nothing to copy", .{});
    if (stripPrefix(dst, args.from) != null)
        return call.failMsg(settings.tr("can't copy a folder into itself", "không thể sao chép thư mục vào chính nó"));
    try copyTree(a, args.from, dst);
    return dst;
}

/// Where a copy of `from` goes in `dir`: its own name, else the first free "name copy[ n].ext".
/// null when `from` has no name (a drive, "..").
fn copyTarget(a: Allocator, from: []const u8, dir: []const u8) !?[]const u8 {
    const name = std.fs.path.basename(from);
    if (name.len == 0 or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".")) return null;
    var stem = name;
    var ext: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| {
        if (i > 0 and core.isFile(from)) {
            stem = name[0..i];
            ext = name[i..];
        }
    }
    var dst = try std.fs.path.join(a, &.{ dir, name });
    var n: usize = 1;
    while (core.exists(dst)) : (n += 1) {
        const file = if (n == 1) try std.mem.concat(a, u8, &.{ stem, " copy", ext }) else try std.fmt.allocPrint(a, "{s} copy {d}{s}", .{ stem, n, ext });
        dst = try std.fs.path.join(a, &.{ dir, file });
    }
    return dst;
}

fn copyTree(a: Allocator, src: []const u8, dst: []const u8) !void {
    if (!core.isDir(src)) return copyFile(a, src, dst);
    try Dir.cwd().createDir(core.io, dst, .default_dir);
    var dir = try Dir.cwd().openDir(core.io, src, .{ .iterate = true });
    defer dir.close(core.io);
    var it = dir.iterate();
    while (try it.next(core.io)) |e| {
        try copyTree(a, try std.fs.path.join(a, &.{ src, e.name }), try std.fs.path.join(a, &.{ dst, e.name }));
    }
}

/// One file, with its times and attributes (CopyFileW, what Rust's `fs::copy` calls).
fn copyFile(a: Allocator, src: []const u8, dst: []const u8) !void {
    if (!core.is_windows) return Dir.copyFile(Dir.cwd(), src, Dir.cwd(), dst, core.io, .{});
    if (c.CopyFileW((try core.wide(a, src)).ptr, (try core.wide(a, dst)).ptr, 0) == 0) return switch (c.GetLastError()) {
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        32 => error.SharingViolation,
        112 => error.NoSpaceLeft,
        else => error.CopyFailed,
    };
}

/// Send a file or folder to the Recycle Bin (it can be restored from there).
pub fn trash(path: []const u8) !void {
    if (!core.is_windows) return error.Unsupported;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // the shell wants the full path, and a list of paths: two NULs end it
    const full = try fullPath(a, path);
    if (c.GetFileAttributesW(full.ptr) == c.INVALID_FILE_ATTRIBUTES) return error.FileNotFound;
    const from = try a.alloc(u16, full.len + 2);
    @memcpy(from[0..full.len], full);
    from[full.len] = 0;
    from[full.len + 1] = 0;

    const com = Com.init();
    defer com.deinit();
    var op = std.mem.zeroes(c.SHFILEOPSTRUCTW);
    op.wFunc = c.FO_DELETE;
    op.pFrom = from.ptr;
    // no progress window, no "are you sure": the page already asked
    op.fFlags = c.FOF_ALLOWUNDO | c.FOF_NOCONFIRMATION | c.FOF_SILENT;
    const rc = c.SHFileOperationW(&op);
    if (rc != 0) {
        std.log.warn("recycle bin: error 0x{x} for {s}", .{ rc, path });
        return error.TrashFailed;
    }
    if (op.fAnyOperationsAborted != 0) return error.Canceled;
}

fn fs_trash(call: *ipc.Call, args: struct { path: []const u8 }) !void {
    trash(args.path) catch |e| return switch (e) {
        error.FileNotFound => call.fail("{s}: {s}", .{ args.path, settings.tr("not found", "không tìm thấy") }),
        error.TrashFailed => call.fail("{s}: {s}", .{ args.path, settings.tr("could not be moved to the Recycle Bin", "không chuyển được vào Thùng rác") }),
        else => e,
    };
}

/// New empty file (or folder); refuses to overwrite.
fn fs_create(call: *ipc.Call, args: struct { path: []const u8, dir: bool }) !void {
    if (core.exists(args.path)) return alreadyExists(call, args.path);
    try create(args.path, args.dir);
}

fn create(path: []const u8, dir: bool) !void {
    if (dir) {
        try Dir.cwd().createDir(core.io, path, .default_dir);
    } else {
        try Dir.cwd().writeFile(core.io, .{ .sub_path = path, .data = "" });
    }
}

// ---------------- tests ----------------

const t = std.testing;

/// A temp folder with its absolute path; `core.gpa` / `core.io` are the test's.
const Tmp = struct {
    tmp: t.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    arena: std.heap.ArenaAllocator,

    fn init(x: *Tmp) !void {
        core.gpa = t.allocator;
        core.io = t.io;
        x.* = .{ .tmp = t.tmpDir(.{}), .arena = .init(t.allocator) };
        x.root = x.buf[0..try x.tmp.dir.realPath(t.io, &x.buf)];
    }
    fn deinit(x: *Tmp) void {
        x.arena.deinit();
        x.tmp.cleanup();
    }
    fn path(x: *Tmp, rel: []const u8) []const u8 {
        return std.fs.path.join(x.arena.allocator(), &.{ x.root, rel }) catch @panic("oom");
    }
    fn write(x: *Tmp, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try x.tmp.dir.createDirPath(t.io, d);
        try x.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }
};

test "read_dir: folders first, then names without case; hidden names dropped" {
    if (!core.is_windows) return error.SkipZigTest;
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    try x.write("b.txt", "");
    try x.write("Ấm.txt", "");
    try x.write("A.txt", "");
    try x.write("zeta/in.txt", "");
    try x.write("Alpha/in.txt", "");
    try x.write("node_modules/x.js", "");
    try x.write("Thumbs.db", "");
    const rows = try readDir(x.arena.allocator(), x.root);
    const want = [_][]const u8{ "Alpha", "zeta", "A.txt", "b.txt", "Ấm.txt" };
    try t.expectEqual(want.len, rows.len);
    for (want, rows) |w, r| try t.expectEqualStrings(w, r.name);
    try t.expect(rows[0].isDir and rows[1].isDir and !rows[2].isDir);
    try t.expectEqualStrings(x.path("Alpha"), rows[0].path);
    try t.expectError(error.FileNotFound, readDir(x.arena.allocator(), x.path("nope")));
    // an empty folder is not an error
    try x.tmp.dir.createDirPath(t.io, "empty");
    try t.expectEqual(0, (try readDir(x.arena.allocator(), x.path("empty"))).len);
}

test "explore: sizes, times, everything listed" {
    if (!core.is_windows) return error.SkipZigTest;
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    try x.write("a.bin", "12345");
    try x.write("node_modules/x.js", "1");
    const rows = try explore(x.arena.allocator(), x.root);
    try t.expectEqual(2, rows.len);
    for (rows) |r| {
        if (r.isDir) {
            try t.expectEqualStrings("node_modules", r.name);
            try t.expectEqual(0, r.size);
        } else {
            try t.expectEqualStrings("a.bin", r.name);
            try t.expectEqual(5, r.size);
            try t.expectEqualStrings(x.path("a.bin"), r.path);
        }
        try t.expect(!r.hidden);
        try t.expect(r.modified > 1_600_000_000_000);
    }
}

test "places and drives" {
    if (!core.is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    core.gpa = t.allocator;
    core.io = t.io;
    var call: ipc.Call = .{ .arena = arena.allocator(), .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    const places = try fs_places(&call);
    // the user's folders exist on any Windows account, and so does one drive with a size
    try t.expectEqualStrings("home", places[0].kind);
    try t.expect(core.isDir(places[0].path));
    var kinds: usize = 0;
    for (places) |p| {
        if (!std.mem.eql(u8, p.kind, "drive")) kinds += 1;
    }
    try t.expect(kinds >= 4);
    const local = try localDrives(arena.allocator());
    try t.expect(local.len >= 1);
    try t.expect(local[0].len == 3 and local[0][1] == ':' and local[0][2] == '\\');
}

test "read_file: text, binary, lossy" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    try x.write("a.txt", "xin chào");
    try x.write("b.bin", "ab\x00cd");
    try x.write("c.txt", "a\xffb");
    const f = try readFile(a, x.path("a.txt"));
    try t.expectEqualStrings("xin chào", f.content);
    try t.expect(!f.binary and !f.tooLarge);
    const b = try readFile(a, x.path("b.bin"));
    try t.expect(b.binary and b.content.len == 0);
    try t.expectEqualStrings("a\u{FFFD}b", (try readFile(a, x.path("c.txt"))).content);
    try t.expectError(error.FileNotFound, readFile(a, x.path("nope.txt")));
}

test "utf8Lossy" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const R = "\u{FFFD}";
    try t.expectEqualStrings("Tài liệu", try utf8Lossy(a, "Tài liệu"));
    try t.expectEqualStrings("a" ++ R ++ "b", try utf8Lossy(a, "a\x80b"));
    // a character cut short is one mark, then the next byte is looked at again
    try t.expectEqualStrings(R ++ "x", try utf8Lossy(a, "\xe1\xbb" ++ "x"));
    try t.expectEqualStrings(R, try utf8Lossy(a, "\xe1\xbb"));
    try t.expectEqualStrings(R ++ R ++ "z", try utf8Lossy(a, "\xc0\xaf" ++ "z")); // overlong
    try t.expectEqualStrings(R ++ R ++ R, try utf8Lossy(a, "\xed\xa0\x80")); // a surrogate
    try t.expectEqualStrings(R ++ "é", try utf8Lossy(a, "\xf0\x9f\x98" ++ "é"));
    try t.expectEqualStrings("😀" ++ R, try utf8Lossy(a, "😀\xf5"));
}

test "list_files: relative, forward slashes, depth-first, build folders skipped" {
    if (!core.is_windows) return error.SkipZigTest;
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    try x.write("a.txt", "");
    try x.write("src/main.zig", "");
    try x.write("src/deep/x.zig", "");
    try x.write("zz/last.txt", "");
    try x.write("node_modules/pkg/index.js", "");
    try x.write("src/bin/tool.exe", "");
    try x.write(".git/HEAD", "");
    const files = try listFiles(a, x.root, 20_000);
    const want = [_][]const u8{ "a.txt", "src/main.zig", "src/deep/x.zig", "zz/last.txt" };
    try t.expectEqual(want.len, files.len);
    for (want, files) |w, f| try t.expectEqualStrings(w, f);
    try t.expectEqual(2, (try listFiles(a, x.root, 2)).len);
}

test "classify" {
    const root = "D:\\build\\app";
    try t.expectEqual(Seen.file, classify(root, null, "D:\\build\\app\\src\\main.rs"));
    try t.expectEqual(Seen.file, classify(root, null, "d:\\build\\app\\README.md"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\target\\debug\\x.exe"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\web\\node_modules\\a\\b.js"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\bin"));
    // inside .git: the branch, the refs and the index, not the objects or the locks
    try t.expectEqual(Seen.git, classify(root, null, "D:\\build\\app\\.git\\HEAD"));
    try t.expectEqual(Seen.git, classify(root, null, "D:\\build\\app\\.git\\index"));
    try t.expectEqual(Seen.git, classify(root, null, "D:\\build\\app\\.git\\refs\\heads\\main"));
    try t.expectEqual(Seen.git, classify(root, null, "D:\\build\\app\\.git"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\.git\\index.lock"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\.git\\refs\\heads\\main.lock"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\.git\\objects\\ab\\cdef"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\.git\\HEAD\\x"));
    try t.expectEqual(Seen.skip, classify(root, null, "D:\\build\\app\\.git\\logs\\HEAD"));
    try t.expectEqual(Seen.git, classify(root, null, "D:\\build\\app\\sub\\.git\\packed-refs"));
    // the git directory of a worktree, or of the repo the folder is part of
    const gd = "D:\\repo\\.git\\worktrees\\app";
    try t.expectEqual(Seen.git, classify(root, gd, "D:\\repo\\.git\\worktrees\\app\\HEAD"));
    try t.expectEqual(Seen.git, classify(root, gd, "D:\\repo\\.git\\worktrees\\app\\MERGE_HEAD"));
    try t.expectEqual(Seen.skip, classify(root, gd, "D:\\repo\\.git\\worktrees\\app\\logs\\HEAD"));
    try t.expectEqual(Seen.file, classify(root, gd, "D:\\build\\app\\a.txt"));
    try t.expectEqual(Seen.skip, classify(root, "D:\\repo\\.git", "D:\\repo\\.git\\ORIG_HEAD"));
}

test "stripPrefix" {
    try t.expectEqualStrings("b\\c", stripPrefix("C:\\a\\b\\c", "C:\\a").?);
    try t.expectEqualStrings("b/c", stripPrefix("c:/a/b/c", "C:\\a\\").?);
    try t.expectEqualStrings("", stripPrefix("C:\\a", "C:\\a").?);
    try t.expect(stripPrefix("C:\\ab\\c", "C:\\a") == null);
    try t.expect(stripPrefix("C:\\A\\c", "C:\\a") == null);
    try t.expect(stripPrefix("C:\\a", "C:\\a\\b") == null);
}

test "sortBatch" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = "D:\\p";
    const b = try sortBatch(a, root, null, &.{
        .{ .kind = .modify, .path = "D:\\p\\b.txt" },
        .{ .kind = .create, .path = "D:\\p\\a.txt" },
        .{ .kind = .modify, .path = "D:\\p\\b.txt" },
        .{ .kind = .modify, .path = "D:\\p\\dist\\x.js" },
        .{ .kind = .modify, .path = "D:\\p\\.git\\objects\\aa\\bb" },
    });
    try t.expect(!b.git);
    try t.expectEqual(2, b.paths.len);
    try t.expectEqualStrings("D:\\p\\a.txt", b.paths[0]);
    try t.expectEqualStrings("D:\\p\\b.txt", b.paths[1]);

    const g = try sortBatch(a, root, null, &.{.{ .kind = .modify, .path = "D:\\p\\.git\\index" }});
    try t.expect(g.git and g.paths.len == 0);

    // lost events: the root and git, whatever else came
    const l = try sortBatch(a, root, null, &.{ .{ .kind = .modify, .path = "D:\\p\\a.txt" }, .{ .kind = .rescan, .path = root } });
    try t.expect(l.git);
    try t.expectEqual(1, l.paths.len);
    try t.expectEqualStrings(root, l.paths[0]);
}

test "copy: a free name, folders and files" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    try x.write("a.tar.gz", "data");
    try x.write("dir.v2/in/x.txt", "x");
    try x.tmp.dir.createDirPath(t.io, "other");

    // into another folder: the same name
    try t.expectEqualStrings(x.path("other\\a.tar.gz"), (try copyTarget(a, x.path("a.tar.gz"), x.path("other"))).?);
    // next to itself: "copy", then "copy 2"
    const c1 = (try copyTarget(a, x.path("a.tar.gz"), x.root)).?;
    try t.expectEqualStrings(x.path("a.tar copy.gz"), c1);
    try copyTree(a, x.path("a.tar.gz"), c1);
    try t.expectEqualStrings("data", try core.readFileAlloc(a, c1, 100));
    try t.expectEqualStrings(x.path("a.tar copy 2.gz"), (try copyTarget(a, x.path("a.tar.gz"), x.root)).?);
    // a folder keeps its dots, and is copied with what is in it
    const d1 = (try copyTarget(a, x.path("dir.v2"), x.root)).?;
    try t.expectEqualStrings(x.path("dir.v2 copy"), d1);
    try copyTree(a, x.path("dir.v2"), d1);
    try t.expectEqualStrings("x", try core.readFileAlloc(a, x.path("dir.v2 copy\\in\\x.txt"), 100));
    // into itself
    const inside = (try copyTarget(a, x.path("dir.v2"), x.path("dir.v2"))).?;
    try t.expect(stripPrefix(inside, x.path("dir.v2")) != null);
    try t.expect(stripPrefix(c1, x.path("a.tar.gz")) == null);
    try t.expect(try copyTarget(a, "C:\\", x.root) == null);
}

test "create, write, rename" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    var call: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    try create(x.path("new.txt"), false);
    try create(x.path("folder"), true);
    try t.expect(core.isFile(x.path("new.txt")) and core.isDir(x.path("folder")));
    try t.expectError(error.FileNotFound, create(x.path("no\\such\\new.txt"), false));
    try fs_write_file(&call, .{ .path = x.path("new.txt"), .content = "hello" });
    try fs_rename(&call, .{ .from = x.path("new.txt"), .to = x.path("folder\\moved.txt") });
    try t.expectEqualStrings("hello", try core.readFileAlloc(a, x.path("folder\\moved.txt"), 100));
    try t.expect(!core.exists(x.path("new.txt")));
    try fs_rename(&call, .{ .from = x.path("folder"), .to = x.path("renamed") });
    try t.expect(core.isFile(x.path("renamed\\moved.txt")));
}

test "trash sends to the Recycle Bin" {
    if (!core.is_windows) return error.SkipZigTest;
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    try x.write("vibe-code-test-trash.txt", "from the unit tests");
    try x.write("vibe-code-test-trash-dir/in.txt", "from the unit tests");
    try trash(x.path("vibe-code-test-trash.txt"));
    try trash(x.path("vibe-code-test-trash-dir"));
    try t.expect(!core.exists(x.path("vibe-code-test-trash.txt")));
    try t.expect(!core.exists(x.path("vibe-code-test-trash-dir")));
    try t.expectError(error.FileNotFound, trash(x.path("gone.txt")));
}

test "osError and fullPath" {
    if (!core.is_windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(std.mem.endsWith(u8, osError(a, 2), " (os error 2)"));
    try t.expect(osError(a, 2).len > " (os error 2)".len);
    try t.expectEqualSlices(u16, L("C:\\a\\c"), try fullPath(a, "C:/a/b/../c"));
}
