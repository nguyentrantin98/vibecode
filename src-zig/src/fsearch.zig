//! File Explorer search: one parallel walk of the folder (or every drive, from This PC) into an in-memory index,
//! then every keystroke ranks names against that index — instant after the first pass, and results show while
//! the walk is still going. Matching ignores case and Vietnamese accents ("tai lieu" finds "Tài liệu").

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const winfs = @import("winfs.zig");
const unicase = @import("unicase.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;

pub const commands = .{
    .{ "fs_search", fs_search },
    .{ "fs_search_forget", fs_search_forget },
};

/// folders listed but not walked into: huge and never what you're looking for
const NO_DESCEND = [_][]const u8{ ".git", "node_modules", "$Recycle.Bin", "System Volume Information", "$WinREAgent", "WinSxS" };
const TOP = 1000;
/// a search started on an index older than this walks the folder again
const STALE_MS = 30_000;
/// an index nobody searched for this long is dropped (one of all drives holds a few hundred MB)
const IDLE_SECS = 300;

/// a folder that was read: its path, and the names of what's in it, each followed by its key when that differs
const Folder = struct {
    path: []const u8,
    text: []const u8,
};

const DIR: u8 = 1;
/// hidden itself or inside a hidden folder
const HIDDEN: u8 = 2;
/// inside a dot-folder or AppData: caches and tools, ranked below your own files
const NOISE: u8 = 4;

/// 32 bytes: the names live in their folder's `text`
const Item = struct {
    folder: u32,
    /// the name is text[at..at + name_len]; the key (the name folded: lowercase, no accents) right after it,
    /// or key_len 0 when the name is its own key
    at: u32,
    name_len: u16,
    key_len: u16,
    depth: u16,
    flags: u8,
    size: u64,
    /// ms since 1970
    modified: u64,
};

comptime {
    std.debug.assert(@sizeOf(Item) == 32);
}

const Store = struct {
    folders: std.ArrayList(Folder) = .empty,
    items: std.ArrayList(Item) = .empty,

    fn name(st: *const Store, it: *const Item) []const u8 {
        return st.folders.items[it.folder].text[it.at..][0..it.name_len];
    }
    fn key(st: *const Store, it: *const Item) []const u8 {
        if (it.key_len == 0) return st.name(it);
        return st.folders.items[it.folder].text[it.at + it.name_len ..][0..it.key_len];
    }
    /// the folder it's in
    fn dir(st: *const Store, it: *const Item) []const u8 {
        return st.folders.items[it.folder].path;
    }
};

/// Shared by the list of indexes, its walk and the searches running on it (`retain` / `release`).
const Index = struct {
    id: u64,
    root: []const u8,
    store: Store = .{},
    lock: std.Io.RwLock = .init,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    /// `core.monoMs()` when the walk started
    built: u64,
    last_emit: std.atomic.Value(u64) = .init(0),
    /// `nowSecs()` of the last search
    used: std.atomic.Value(u64),
    refs: std.atomic.Value(u32) = .init(1),

    fn create(root: []const u8) !*Index {
        const ix = try core.gpa.create(Index);
        errdefer core.gpa.destroy(ix);
        ix.* = .{ .id = next_id.fetchAdd(1, .monotonic), .root = try core.gpa.dupe(u8, root), .built = core.monoMs(), .used = .init(nowSecs()) };
        return ix;
    }

    fn retain(ix: *Index) *Index {
        _ = ix.refs.fetchAdd(1, .monotonic);
        return ix;
    }

    fn release(ix: *Index) void {
        if (ix.refs.fetchSub(1, .acq_rel) != 1) return;
        for (ix.store.folders.items) |f| {
            core.gpa.free(f.path);
            core.gpa.free(f.text);
        }
        ix.store.folders.deinit(core.gpa);
        ix.store.items.deinit(core.gpa);
        core.gpa.free(ix.root);
        core.gpa.destroy(ix);
    }
};

var next_id: std.atomic.Value(u64) = .init(1);
var indexes_mutex: core.Mutex = .{};
var indexes: std.ArrayList(*Index) = .empty;
var reaper_started = false;

fn nowSecs() u64 {
    return core.monoMs() / 1000;
}

const Progress = struct {
    root: []const u8,
    indexed: usize,
    done: bool,
};

pub const Hit = struct {
    name: []const u8,
    path: []const u8,
    isDir: bool,
    size: u64,
    modified: u64,
    hidden: bool,
    /// the folder it's in, relative to where the search started
    at: []const u8,
    /// matched characters of the name: [start, end) pairs, in chars
    marks: []const u32,
};

pub const Found = struct {
    hits: []const Hit,
    /// matches in all (only the best TOP are sent)
    total: usize,
    indexed: usize,
    done: bool,
};

/// `root` "" is This PC: every local drive. `fresh`: a new search, so an old index is walked again.
fn fs_search(call: *ipc.Call, args: struct { root: []const u8, query: []const u8, hidden: bool, fresh: bool }) !Found {
    const ix = try indexFor(args.root, args.fresh);
    defer ix.release();
    ix.used.store(nowSecs(), .monotonic);
    const my_ticket = ticket.fetchAdd(1, .monotonic) + 1;
    return try search(call.arena, ix, args.query, args.hidden, my_ticket) orelse call.fail("superseded", .{});
}

/// the newest search: older ones still running stop, so typing never waits behind a stale query
var ticket: std.atomic.Value(u64) = .init(0);

/// the last search's matches: typing one more letter only looks at those (and at what the walk added since)
const Last = struct {
    ix: u64,
    query: []const u8,
    hidden: bool,
    indexed: usize,
    matched: []const usize,

    fn free(l: Last) void {
        core.gpa.free(l.query);
        core.gpa.free(l.matched);
    }
};
var last_mutex: core.Mutex = .{};
var last: ?Last = null;

/// F5 and file changes made here: the next search walks again
fn fs_search_forget(_: *ipc.Call) !void {
    indexes_mutex.lock();
    defer indexes_mutex.unlock();
    for (indexes.items) |ix| {
        ix.cancel.store(true, .monotonic);
        ix.release();
    }
    indexes.clearRetainingCapacity();
}

fn reaper() void {
    while (true) {
        core.sleepMs(60_000);
        const now = nowSecs();
        indexes_mutex.lock();
        defer indexes_mutex.unlock();
        var i: usize = 0;
        while (i < indexes.items.len) {
            const ix = indexes.items[i];
            if (ix.done.load(.monotonic) and now >= ix.used.load(.monotonic) + IDLE_SECS) {
                _ = indexes.orderedRemove(i);
                ix.release();
            } else i += 1;
        }
        last_mutex.lock();
        defer last_mutex.unlock();
        if (last) |l| {
            const alive = for (indexes.items) |ix| {
                if (ix.id == l.ix) break true;
            } else false;
            if (!alive) {
                l.free();
                last = null;
            }
        }
    }
}

/// The index of `root` (walking it now when there is none yet), retained for the caller.
fn indexFor(root: []const u8, fresh: bool) !*Index {
    indexes_mutex.lock();
    defer indexes_mutex.unlock();
    if (!reaper_started) {
        reaper_started = true;
        if (std.Thread.spawn(.{}, reaper, .{})) |th| th.detach() else |_| {}
    }
    for (indexes.items, 0..) |ix, i| {
        if (!std.ascii.eqlIgnoreCase(ix.root, root)) continue;
        if (!(fresh and ix.done.load(.monotonic) and core.monoMs() - ix.built > STALE_MS)) return ix.retain();
        _ = indexes.orderedRemove(i);
        ix.release();
        break;
    }
    const ix = try Index.create(root);
    errdefer ix.release();
    try indexes.ensureUnusedCapacity(core.gpa, 1);
    // two indexes at most: the folder you're in and the one you came from
    while (indexes.items.len >= 2) {
        const old = indexes.orderedRemove(0);
        old.cancel.store(true, .monotonic);
        old.release();
    }
    indexes.appendAssumeCapacity(ix);
    const walker = ix.retain();
    if (std.Thread.spawn(.{}, walkOwned, .{walker})) |th| th.detach() else |_| walkOwned(walker);
    return ix.retain();
}

fn walkOwned(ix: *Index) void {
    walk(ix);
    ix.release();
}

// ================================ the walk ================================

const Dir = struct {
    path: []const u8,
    depth: u16,
    hidden: bool,
    noise: bool,
};

const Queue = struct {
    mutex: core.Mutex = .{},
    wake: std.Io.Condition = .init,
    dirs: std.ArrayList(Dir) = .empty,
    /// folders being read right now
    active: usize = 0,
};

/// every folder below the root(s), read by a few threads sharing one queue of folders
fn walk(ix: *Index) void {
    const gpa = core.gpa;
    var q: Queue = .{};
    defer q.dirs.deinit(gpa);
    if (ix.root.len == 0) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const drives: []const []const u8 = if (@hasDecl(m.fsx, "localDrives")) m.fsx.localDrives(arena.allocator()) catch &.{} else &.{};
        for (drives) |d| q.dirs.append(gpa, .{ .path = gpa.dupe(u8, d) catch continue, .depth = 0, .hidden = false, .noise = false }) catch {};
    } else if (gpa.dupe(u8, ix.root)) |p| {
        q.dirs.append(gpa, .{ .path = p, .depth = 0, .hidden = false, .noise = false }) catch gpa.free(p);
    } else |_| {}

    var threads: [8]?std.Thread = @splat(null);
    const n = std.math.clamp(std.Thread.getCpuCount() catch 4, 2, 8);
    for (threads[1..n]) |*th| th.* = std.Thread.spawn(.{}, walkWorker, .{ ix, &q }) catch null;
    walkWorker(ix, &q);
    for (threads) |th| if (th) |x| x.join();

    ix.done.store(true, .monotonic);
    progress(ix, true);
}

fn walkWorker(ix: *Index, q: *Queue) void {
    const gpa = core.gpa;
    var r: Read = .{};
    defer r.deinit();
    while (true) {
        q.mutex.lock();
        const dir = while (true) {
            if (ix.cancel.load(.monotonic)) {
                for (q.dirs.items) |d| gpa.free(d.path);
                q.dirs.clearRetainingCapacity();
            }
            if (q.dirs.pop()) |d| {
                q.active += 1;
                break d;
            }
            if (q.active == 0) {
                q.wake.broadcast(core.io);
                q.mutex.unlock();
                return;
            }
            q.wake.waitUncancelable(core.io, &q.mutex.m);
        };
        q.mutex.unlock();

        r.read(dir);
        var kept = false;
        if (r.items.items.len > 0) add: {
            const text = gpa.dupe(u8, r.text.items) catch break :add;
            ix.lock.lockUncancelable(core.io);
            defer ix.lock.unlock(core.io);
            const st = &ix.store;
            st.folders.ensureUnusedCapacity(gpa, 1) catch {};
            st.items.ensureUnusedCapacity(gpa, r.items.items.len) catch {};
            if (st.folders.unusedCapacitySlice().len == 0 or st.items.unusedCapacitySlice().len < r.items.items.len) {
                gpa.free(text);
                break :add;
            }
            const id: u32 = @intCast(st.folders.items.len);
            st.folders.appendAssumeCapacity(.{ .path = dir.path, .text = text });
            for (r.items.items) |*it| it.folder = id;
            st.items.appendSliceAssumeCapacity(r.items.items);
            kept = true;
        }
        if (kept) progress(ix, false) else gpa.free(dir.path);

        q.mutex.lock();
        q.dirs.appendSlice(gpa, r.subdirs.items) catch {
            for (r.subdirs.items) |d| gpa.free(d.path);
        };
        q.active -= 1;
        q.wake.broadcast(core.io);
        q.mutex.unlock();
    }
}

/// What one folder holds; the buffers are reused for the next one.
const Read = struct {
    text: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    subdirs: std.ArrayList(Dir) = .empty,

    fn deinit(r: *Read) void {
        r.text.deinit(core.gpa);
        r.items.deinit(core.gpa);
        r.subdirs.deinit(core.gpa);
    }

    fn read(r: *Read, dir: Dir) void {
        r.text.clearRetainingCapacity();
        r.items.clearRetainingCapacity();
        r.subdirs.clearRetainingCapacity();
        if (!core.is_windows) return;
        const gpa = core.gpa;
        const drive_root = dir.depth == 0 and std.fs.path.dirname(dir.path) == null;
        var list = winfs.List.open(dir.path) catch return;
        defer list.close();
        // the listing comes with size, time and attributes: no extra call per file
        while (list.next()) |e| {
            const wname = winfs.name(e);
            r.text.ensureUnusedCapacity(gpa, wname.len * 6) catch return;
            r.items.ensureUnusedCapacity(gpa, 1) catch return;
            const at = r.text.items.len;
            const lens = appendNameAndKey(&r.text, wname);
            const name = r.text.items[at..][0..lens.name];
            const is_dir = winfs.isDir(e);
            const hidden = winfs.hidden(e) or dir.hidden;
            // links and junctions are listed, not followed (they loop: "Application Data" → AppData\Roaming…)
            if (is_dir and !winfs.isLink(e) and !noDescend(name) and !(drive_root and std.ascii.eqlIgnoreCase(name, "Windows"))) sub: {
                const noise = dir.noise or name[0] == '.' or std.mem.eql(u8, name, "AppData");
                const sep: []const u8 = if (endsWithSep(dir.path)) "" else std.fs.path.sep_str;
                const path = std.mem.concat(gpa, u8, &.{ dir.path, sep, name }) catch break :sub;
                r.subdirs.append(gpa, .{ .path = path, .depth = dir.depth + 1, .hidden = hidden, .noise = noise }) catch gpa.free(path);
            }
            r.items.appendAssumeCapacity(.{
                .folder = 0,
                .at = @intCast(at),
                .name_len = @intCast(lens.name),
                .key_len = @intCast(lens.key),
                .depth = dir.depth,
                .flags = (if (is_dir) DIR else 0) | (if (hidden) HIDDEN else 0) | (if (dir.noise) NOISE else 0),
                .size = if (is_dir) 0 else winfs.size(e),
                .modified = winfs.modifiedMs(e),
            });
        }
    }
};

fn noDescend(name: []const u8) bool {
    for (NO_DESCEND) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn endsWithSep(p: []const u8) bool {
    return p.len > 0 and (p[p.len - 1] == '\\' or p[p.len - 1] == '/');
}

/// Appends a file name (UTF-16 as Windows gave it; a broken surrogate becomes U+FFFD) as UTF-8,
/// then its key when that differs. `text` has room for both. Returns the byte lengths; key 0
/// when the name is its own key.
fn appendNameAndKey(text: *std.ArrayList(u8), wname: []const u16) struct { name: usize, key: usize } {
    var folded: [260]u21 = undefined;
    var count: usize = 0;
    var differs = false;
    const start = text.items.len;
    var i: usize = 0;
    while (i < wname.len and count < folded.len) : (count += 1) {
        var cp: u21 = wname[i];
        i += 1;
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            if (cp < 0xDC00 and i < wname.len and wname[i] >= 0xDC00 and wname[i] <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (wname[i] - 0xDC00);
                i += 1;
            } else cp = 0xFFFD;
        }
        appendCodepoint(text, cp);
        const f = fold(cp);
        differs = differs or f != cp;
        folded[count] = f;
    }
    const name_len = text.items.len - start;
    if (!differs) return .{ .name = name_len, .key = 0 };
    for (folded[0..count]) |f| appendCodepoint(text, f);
    return .{ .name = name_len, .key = text.items.len - start - name_len };
}

fn appendCodepoint(text: *std.ArrayList(u8), cp: u21) void {
    if (cp < 0x80) return text.appendAssumeCapacity(@intCast(cp));
    const n = std.unicode.utf8Encode(cp, text.unusedCapacitySlice()) catch unreachable;
    text.items.len += n;
}

/// at most five times a second while walking, then once at the end
fn progress(ix: *Index, done: bool) void {
    const now = core.monoMs() - ix.built;
    const prev = ix.last_emit.load(.monotonic);
    if (!done and now < prev + 200) return;
    if (!done and ix.last_emit.cmpxchgStrong(prev, now, .monotonic, .monotonic) != null) return;
    if (ix.cancel.load(.monotonic)) return;
    if (builtin.is_test) return; // no window to tell
    ix.lock.lockSharedUncancelable(core.io);
    const indexed = ix.store.items.items.len;
    ix.lock.unlockShared(core.io);
    core.emit("fs:search-progress", .{Progress{ .root = ix.root, .indexed = indexed, .done = done }});
}

// ================================ matching ================================

/// lowercase, without accents: the same number of chars as the name, so match positions are name positions
fn fold(c: u21) u21 {
    if (c < 0x80) return if (c >= 'A' and c <= 'Z') c + 32 else c;
    const l = unicase.lower(c);
    return switch (l) {
        'à', 'á', 'ả', 'ã', 'ạ', 'ă', 'ằ', 'ắ', 'ẳ', 'ẵ', 'ặ', 'â', 'ầ', 'ấ', 'ẩ', 'ẫ', 'ậ', 'ä', 'å' => 'a',
        'è', 'é', 'ẻ', 'ẽ', 'ẹ', 'ê', 'ề', 'ế', 'ể', 'ễ', 'ệ', 'ë' => 'e',
        'ì', 'í', 'ỉ', 'ĩ', 'ị', 'î', 'ï' => 'i',
        'ò', 'ó', 'ỏ', 'õ', 'ọ', 'ô', 'ồ', 'ố', 'ổ', 'ỗ', 'ộ', 'ơ', 'ờ', 'ớ', 'ở', 'ỡ', 'ợ', 'ö' => 'o',
        'ù', 'ú', 'ủ', 'ũ', 'ụ', 'ư', 'ừ', 'ứ', 'ử', 'ữ', 'ự', 'û', 'ü' => 'u',
        'ỳ', 'ý', 'ỷ', 'ỹ', 'ỵ' => 'y',
        'đ' => 'd',
        'ç' => 'c',
        'ñ' => 'n',
        else => l,
    };
}

/// `s` (UTF-8) folded, appended to `out` as chars
fn foldChars(a: Allocator, out: *std.ArrayList(u21), s: []const u8, comptime folded: bool) !void {
    try out.ensureUnusedCapacity(a, s.len);
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |c| out.appendAssumeCapacity(if (folded) fold(c) else c);
}

/// `s` (UTF-8) folded, as UTF-8
fn foldStr(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.ensureUnusedCapacity(a, s.len + 4);
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |c| appendCodepoint(out, fold(c));
}

fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

/// where a word starts: the beginning, after a separator, or a capital after a small letter (FileExplorer)
fn wordStart(name: []const u21, i: usize) bool {
    return i == 0 or !unicase.isAlphanumeric(name[i - 1]) or (unicase.isUpper(name[i]) and unicase.isLower(name[i - 1])) or
        (isDigit(name[i]) and !isDigit(name[i - 1]));
}

/// how well one term matches a name, and which chars it matched (`marks` has room for 2 per char of the term)
fn scoreTerm(term: []const u21, key: []const u21, name: []const u21, marks: *std.ArrayList(u32)) ?i32 {
    const n = term.len;
    if (n == 0 or n > key.len) return null;
    // "*.pdf": ends with
    if (term[0] == '*') {
        const rest = term[1..];
        if (!std.mem.endsWith(u21, key, rest)) return null;
        marks.appendSliceAssumeCapacity(&.{ @intCast(key.len - rest.len), @intCast(key.len) });
        return 300;
    }
    if (std.mem.eql(u21, key, term)) {
        marks.appendSliceAssumeCapacity(&.{ 0, @intCast(n) });
        return 1000;
    }
    // a substring: the best of its places (a word start beats the middle of a word)
    var best: ?struct { s: i32, i: usize } = null;
    var i: usize = 0;
    while (i + n <= key.len) : (i += 1) {
        if (!std.mem.eql(u21, key[i..][0..n], term)) continue;
        const s: i32 = if (i == 0)
            // the whole name but the extension: "readme" → README.md
            (if (key[n] == '.' and std.mem.indexOfScalar(u21, key[n + 1 ..], '.') == null) 900 else 800)
        else if (wordStart(name, i))
            600
        else
            400;
        if (best == null or s > best.?.s) best = .{ .s = s, .i = i };
        if (s >= 800) break;
    }
    if (best) |b| {
        marks.appendSliceAssumeCapacity(&.{ @intCast(b.i), @intCast(b.i + n) });
        return b.s;
    }
    // initials and word pieces: "fe" → FileExplorer, "bkinv" → bkav_invoice
    if (n < 2) return null;
    const start = marks.items.len;
    var ti: usize = 0;
    var k: usize = 0;
    var runs: usize = 0;
    while (ti < n and k < key.len) : (k += 1) {
        const joined = marks.items.len > start and marks.items[marks.items.len - 1] == k;
        if (key[k] == term[ti] and (joined or wordStart(name, k))) {
            if (joined) {
                marks.items[marks.items.len - 1] += 1;
            } else {
                marks.appendSliceAssumeCapacity(&.{ @intCast(k), @intCast(k + 1) });
                runs += 1;
            }
            ti += 1;
        }
    }
    // scattered single letters in a long term are noise: "lieu" → "-l-i-b-r-a-r-y_-e-l-e-m-e-n-t-s"
    if (ti < n or (n > 3 and n < runs * 2)) {
        marks.shrinkRetainingCapacity(start);
        return null;
    }
    return 250 - 10 * @as(i32, @intCast(runs));
}

const Term = struct {
    chars: []const u21,
    text: []const u8,
    /// what must appear in the name, in order, for any kind of match (the part after a leading "*")
    must: []const u8,
};

/// all of `needle`'s bytes in `hay`, in order: the cheap test that throws out almost every name
fn inOrder(hay: []const u8, needle: []const u8) bool {
    var h: usize = 0;
    for (needle) |b| {
        while (h < hay.len and hay[h] != b) h += 1;
        if (h == hay.len) return false;
        h += 1;
    }
    return true;
}

/// reused for every item a thread looks at
const Scratch = struct {
    a: Allocator,
    key: std.ArrayList(u21) = .empty,
    name: std.ArrayList(u21) = .empty,
    marks: std.ArrayList(u32) = .empty,
    missed: std.ArrayList(usize) = .empty,
    at: std.ArrayList(u8) = .empty,

    fn init(a: Allocator, terms: []const Term) !Scratch {
        var w: Scratch = .{ .a = a };
        errdefer w.deinit();
        var chars: usize = 0;
        for (terms) |term| chars += term.chars.len;
        try w.marks.ensureTotalCapacity(a, chars * 2 + 2);
        try w.missed.ensureTotalCapacity(a, terms.len);
        return w;
    }

    fn deinit(w: *Scratch) void {
        w.key.deinit(w.a);
        w.name.deinit(w.a);
        w.marks.deinit(w.a);
        w.missed.deinit(w.a);
        w.at.deinit(w.a);
    }
};

fn rank(terms: []const Term, st: *const Store, it: *const Item, hidden: bool, w: *Scratch) ?i32 {
    if (it.flags & HIDDEN != 0 and !hidden) return null;
    const key = st.key(it);
    for (terms) |term| {
        if (inOrder(key, term.must)) break;
    } else return null;
    w.key.clearRetainingCapacity();
    foldChars(w.a, &w.key, key, false) catch return null;
    w.name.clearRetainingCapacity();
    foldChars(w.a, &w.name, st.name(it), false) catch return null;
    w.marks.clearRetainingCapacity();
    w.missed.clearRetainingCapacity();
    var score: i32 = 0;
    for (terms, 0..) |term, i| {
        if (scoreTerm(term.chars, w.key.items, w.name.items, &w.marks)) |s| score += s else w.missed.appendAssumeCapacity(i);
    }
    if (w.missed.items.len == terms.len) return null;
    // a term that isn't in the name can be in the folders above it: "invoice 2024"
    if (w.missed.items.len > 0) {
        w.at.clearRetainingCapacity();
        foldStr(w.a, &w.at, st.dir(it)) catch return null;
        for (w.missed.items) |i| {
            if (std.mem.indexOf(u8, w.at.items, terms[i].text) == null) return null;
            score += 100;
        }
    }
    // the same match: your own files before caches, nearer the top and shorter names first
    const noise: i32 = if (it.flags & NOISE != 0) 4000 else 0;
    return score * 16 - noise - @as(i32, it.depth) * 8 - @as(i32, @intCast(w.name.items.len));
}

const Scored = struct { score: i32, i: usize };

/// best first: the higher score, then the key
fn order(st: *const Store, x: Scored, y: Scored) std.math.Order {
    if (x.score != y.score) return if (x.score > y.score) .lt else .gt;
    return std.mem.order(u8, st.key(&st.items.items[x.i]), st.key(&st.items.items[y.i]));
}

fn better(st: *const Store, x: Scored, y: Scored) bool {
    return order(st, x, y) == .lt;
}

/// Moves the `k` best of `found` to its front, in no particular order (`k` < found.len).
fn selectTop(st: *const Store, found: []Scored, k: usize) void {
    var lo: usize = 0;
    var hi: usize = found.len;
    while (hi - lo > 1) {
        // the middle one of three as the pivot; then [lo, lt) is better, [lt, gt) the same, [gt, hi) worse
        var p = found[lo + (hi - lo) / 2];
        const x = found[lo];
        const y = found[hi - 1];
        if (better(st, p, x) != better(st, p, y)) {} else if (better(st, x, p) != better(st, x, y)) {
            p = x;
        } else p = y;
        var lt = lo;
        var i = lo;
        var gt = hi;
        while (i < gt) switch (order(st, found[i], p)) {
            .lt => {
                std.mem.swap(Scored, &found[lt], &found[i]);
                lt += 1;
                i += 1;
            },
            .gt => {
                gt -= 1;
                std.mem.swap(Scored, &found[i], &found[gt]);
            },
            .eq => i += 1,
        };
        if (k < lt) hi = lt else if (k >= gt) lo = gt else return;
    }
}

const Job = struct {
    terms: []const Term,
    st: *const Store,
    /// the items to look at: `picks[from..to]`, or the items `from..to` themselves
    picks: ?[]const usize,
    from: usize,
    to: usize,
    hidden: bool,
    ticket: u64,
    out: std.ArrayList(Scored) = .empty,
    /// a newer search started, or out of memory
    failed: bool = false,
    thread: ?std.Thread = null,

    fn run(j: *Job) void {
        var w = Scratch.init(core.gpa, j.terms) catch {
            j.failed = true;
            return;
        };
        defer w.deinit();
        for (j.from..j.to) |n| {
            if (n % 4096 == 0 and ticket.load(.monotonic) != j.ticket) {
                j.failed = true;
                return;
            }
            const i = if (j.picks) |p| p[n] else n;
            if (rank(j.terms, j.st, &j.st.items.items[i], j.hidden, &w)) |s| {
                j.out.append(core.gpa, .{ .score = s, .i = i }) catch {
                    j.failed = true;
                    return;
                };
            }
        }
    }
};

/// null: a newer search took over. Everything returned is allocated in `a`.
fn search(a: Allocator, ix: *Index, raw_query: []const u8, hidden: bool, my_ticket: u64) !?Found {
    const query = try unicase.plainSpaces(a, raw_query);
    var terms: std.ArrayList(Term) = .empty;
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        var text: std.ArrayList(u8) = .empty;
        try foldStr(a, &text, word);
        var chars: std.ArrayList(u21) = .empty;
        try foldChars(a, &chars, text.items, false);
        try terms.append(a, .{ .chars = chars.items, .text = text.items, .must = std.mem.trimStart(u8, text.items, "*") });
    }
    ix.lock.lockSharedUncancelable(core.io);
    defer ix.lock.unlockShared(core.io);
    const st = &ix.store;
    const items = st.items.items;
    const done = ix.done.load(.monotonic);
    if (terms.items.len == 0) return .{ .hits = &.{}, .total = 0, .indexed = items.len, .done = done };

    // one more letter on the last word: only the last matches can still match (not after "*": "*.pd" ⊅ "*.pdf")
    const narrowed: ?[]const usize = blk: {
        last_mutex.lock();
        defer last_mutex.unlock();
        const l = last orelse break :blk null;
        const same = l.ix == ix.id and l.hidden == hidden;
        const longer = query.len > l.query.len and std.mem.startsWith(u8, query, l.query) and std.mem.indexOfScalar(u8, query[l.query.len..], ' ') == null;
        const star = std.mem.startsWith(u8, terms.items[terms.items.len - 1].text, "*");
        // the same query again (the walk found more): the old matches plus the new items
        const narrower = std.mem.eql(u8, query, l.query) or (longer and !star and !std.mem.endsWith(u8, l.query, " "));
        if (!(same and narrower)) break :blk null;
        const more = items.len - @min(l.indexed, items.len);
        const picks = try a.alloc(usize, l.matched.len + more);
        @memcpy(picks[0..l.matched.len], l.matched);
        for (picks[l.matched.len..], l.indexed..) |*p, i| p.* = i;
        break :blk picks;
    };
    const count = if (narrowed) |v| v.len else items.len;

    // every core takes a slice
    const parts = @min(std.Thread.getCpuCount() catch 4, 16);
    const chunk = @max(try std.math.divCeil(usize, count, parts), 4096);
    const jobs = try a.alloc(Job, try std.math.divCeil(usize, count, chunk));
    for (jobs, 0..) |*j, n| j.* = .{ .terms = terms.items, .st = st, .picks = narrowed, .from = n * chunk, .to = @min((n + 1) * chunk, count), .hidden = hidden, .ticket = my_ticket };
    defer for (jobs) |*j| j.out.deinit(core.gpa);
    if (jobs.len > 1) {
        for (jobs[1..]) |*j| j.thread = std.Thread.spawn(.{}, Job.run, .{j}) catch null;
    }
    for (jobs) |*j| {
        if (j.thread == null) j.run();
    }
    for (jobs) |*j| {
        if (j.thread) |th| th.join();
    }
    var total: usize = 0;
    for (jobs) |*j| {
        if (j.failed) return null;
        total += j.out.items.len;
    }
    var found = try a.alloc(Scored, total);
    var n: usize = 0;
    for (jobs) |*j| {
        @memcpy(found[n..][0..j.out.items.len], j.out.items);
        n += j.out.items.len;
    }

    remember: {
        const matched = core.gpa.alloc(usize, total) catch break :remember;
        for (found, matched) |f, *x| x.* = f.i;
        const q = core.gpa.dupe(u8, query) catch {
            core.gpa.free(matched);
            break :remember;
        };
        last_mutex.lock();
        defer last_mutex.unlock();
        if (last) |l| l.free();
        last = .{ .ix = ix.id, .query = q, .hidden = hidden, .indexed = items.len, .matched = matched };
    }

    if (found.len > TOP) {
        selectTop(st, found, TOP);
        found = found[0..TOP];
    }
    std.mem.sortUnstable(Scored, found, st, better);

    const root_len = if (ix.root.len == 0) 0 else std.mem.trimEnd(u8, ix.root, "\\/").len + 1;
    var w = try Scratch.init(a, terms.items);
    const hits = try a.alloc(Hit, found.len);
    for (found, hits) |f, *hit| {
        const it = &items[f.i];
        _ = rank(terms.items, st, it, hidden, &w);
        const dir = st.dir(it);
        const name = st.name(it);
        const at = std.mem.trimEnd(u8, dir, "\\/");
        const below = root_len < at.len and at[root_len] & 0xC0 != 0x80;
        hit.* = .{
            .name = try a.dupe(u8, name),
            .path = try std.mem.concat(a, u8, &.{ dir, if (endsWithSep(dir)) "" else std.fs.path.sep_str, name }),
            .isDir = it.flags & DIR != 0,
            .size = it.size,
            .modified = it.modified,
            .hidden = it.flags & HIDDEN != 0,
            .at = if (below) try a.dupe(u8, at[root_len..]) else "",
            .marks = try a.dupe(u32, w.marks.items),
        };
    }
    return .{ .hits = hits, .total = total, .indexed = items.len, .done = done };
}

// ================================ tests ================================

const t = std.testing;

const Score = struct { s: i32, marks: []const u32 };

fn scoreOf(a: Allocator, term: []const u8, name: []const u8) !?Score {
    var tc: std.ArrayList(u21) = .empty;
    try foldChars(a, &tc, term, true);
    var nc: std.ArrayList(u21) = .empty;
    try foldChars(a, &nc, name, false);
    var kc: std.ArrayList(u21) = .empty;
    try foldChars(a, &kc, name, true);
    var marks: std.ArrayList(u32) = .empty;
    try marks.ensureTotalCapacity(a, tc.items.len * 2 + 2);
    const s = scoreTerm(tc.items, kc.items, nc.items, &marks) orelse return null;
    return .{ .s = s, .marks = marks.items };
}

fn expectScore(a: Allocator, term: []const u8, name: []const u8, s: i32, marks: []const u32) !void {
    const got = try scoreOf(a, term, name) orelse return error.TestExpectedEqual;
    try t.expectEqual(s, got.s);
    try t.expectEqualSlices(u32, marks, got.marks);
}

test "ranks and marks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectScore(a, "readme", "README.md", 900, &.{ 0, 6 });
    try t.expectEqual(800, (try scoreOf(a, "tai", "Tài liệu.docx")).?.s);
    try expectScore(a, "lieu", "Tài liệu.docx", 600, &.{ 4, 8 });
    try expectScore(a, "fe", "FileExplorer.tsx", 230, &.{ 0, 1, 4, 5 });
    try expectScore(a, "fiex", "FileExplorer.tsx", 230, &.{ 0, 2, 4, 6 });
    try expectScore(a, "plor", "FileExplorer.tsx", 400, &.{ 6, 10 });
    try expectScore(a, "*.pdf", "a.PDF", 300, &.{ 1, 5 });
    try t.expect(try scoreOf(a, "xyz", "FileExplorer.tsx") == null);
    try t.expect(try scoreOf(a, "fl", "FileExplorer.tsx") == null);
    try t.expect(try scoreOf(a, "lieu", "-l-i-b-r-a-r-y_-e-l-e-m-e-n-t-s.html") == null);
    // more of the same kind
    try expectScore(a, "main.zig", "main.zig", 1000, &.{ 0, 8 });
    try expectScore(a, "main", "main.test.zig", 800, &.{ 0, 4 });
    try expectScore(a, "bkinv", "bkav_invoice.cs", 230, &.{ 0, 2, 5, 8 });
    try expectScore(a, "2024", "report2024.xlsx", 600, &.{ 6, 10 });
    try expectScore(a, "đặc", "Dac biet.txt", 800, &.{ 0, 3 });
}

test "fold" {
    const from = "ÀẮ ĐƯỜNG Ỹ ñÇ aZ9 中";
    const want = "aa duong y nc az9 中";
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try foldStr(arena.allocator(), &out, from);
    try t.expectEqualStrings(want, out.items);
}

test "appendNameAndKey" {
    const a = t.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.ensureTotalCapacity(a, 4096);
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    // already its own key
    var r = appendNameAndKey(&text, L("main.zig"));
    try t.expectEqual(8, r.name);
    try t.expectEqual(0, r.key);
    // the key follows the name
    r = appendNameAndKey(&text, L("Tài Liệu.DOCX"));
    try t.expectEqualStrings("main.zigTài Liệu.DOCXtai lieu.docx", text.items);
    try t.expectEqual("Tài Liệu.DOCX".len, r.name);
    try t.expectEqual("tai lieu.docx".len, r.key);
    // outside the BMP, and half a pair
    text.clearRetainingCapacity();
    r = appendNameAndKey(&text, &.{ 0xD83D, 0xDE00, 'a', 0xD83D, 'b' });
    try t.expectEqualStrings("😀a\u{FFFD}b", text.items);
    try t.expectEqual(0, r.key);
}

test "inOrder" {
    try t.expect(inOrder("fileexplorer.tsx", "fe"));
    try t.expect(inOrder("fileexplorer.tsx", ""));
    try t.expect(!inOrder("fileexplorer.tsx", "xf"));
    try t.expect(!inOrder("ab", "abb"));
}

test "selectTop" {
    const a = t.allocator;
    var st: Store = .{};
    defer st.folders.deinit(a);
    defer st.items.deinit(a);
    // 26 names "a".."z", each its own key
    try st.folders.append(a, .{ .path = "", .text = "abcdefghijklmnopqrstuvwxyz" });
    var found: std.ArrayList(Scored) = .empty;
    defer found.deinit(a);
    var seed: u32 = 12345;
    for (0..5000) |i| {
        seed = seed *% 1103515245 +% 12345;
        try st.items.append(a, .{ .folder = 0, .at = (seed >> 16) % 26, .name_len = 1, .key_len = 0, .depth = 0, .flags = 0, .size = 0, .modified = 0 });
        try found.append(a, .{ .score = @intCast((seed >> 8) % 7), .i = i }); // many ties
    }
    const sorted = try a.dupe(Scored, found.items);
    defer a.free(sorted);
    std.mem.sort(Scored, sorted, &st, better);
    for ([_]usize{ 1, 10, 1000, 4999 }) |k| {
        selectTop(&st, found.items, k);
        // the front holds the k best: none of them is worse than the k-th of the sorted list
        for (found.items[0..k]) |f| try t.expect(order(&st, f, sorted[k - 1]) != .gt);
        for (found.items[k..]) |f| try t.expect(order(&st, f, sorted[k - 1]) != .lt);
    }
}

test "walk a tree and search it" {
    if (!core.is_windows) return error.SkipZigTest;
    core.gpa = t.allocator;
    core.io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][]const u8{
        "README.md",
        "Tài liệu/Hoá đơn 2024.pdf",
        "Tài liệu/ghi chú.txt",
        "src/FileExplorer.tsx",
        "src/components/file_list.tsx",
        "src/readme-notes.txt",
        ".cache/readme.md",
        "node_modules/pkg/readme.md",
        "invoice/2024/march.xlsx",
    };
    for (files) |f| {
        try tmp.dir.createDirPath(t.io, std.fs.path.dirname(f) orelse ".");
        try tmp.dir.writeFile(t.io, .{ .sub_path = f, .data = "12345" });
    }
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const root = pb[0..try tmp.dir.realPath(t.io, &pb)];
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ix = try Index.create(root);
    defer ix.release();
    defer {
        if (last) |l| l.free();
        last = null;
    }
    walk(ix);
    try t.expect(ix.done.load(.monotonic));
    // 8 files + 7 folders: what is inside node_modules is not walked
    try t.expectEqual(15, ix.store.items.items.len);

    ticket.store(7, .monotonic);
    // nothing typed
    var f = (try search(a, ix, "  ", false, 7)).?;
    try t.expectEqual(0, f.hits.len);
    try t.expectEqual(15, f.indexed);
    try t.expect(f.done);

    // the name without its extension first, the one in a dot-folder last
    f = (try search(a, ix, "readme", false, 7)).?;
    try t.expectEqual(3, f.total);
    try t.expectEqualStrings("README.md", f.hits[0].name);
    try t.expectEqualStrings("", f.hits[0].at);
    try t.expectEqualSlices(u32, &.{ 0, 6 }, f.hits[0].marks);
    try t.expectEqual(5, f.hits[0].size);
    try t.expect(!f.hits[0].isDir and !f.hits[0].hidden and f.hits[0].modified > 1_600_000_000_000);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ root, "README.md" }), f.hits[0].path);
    try t.expectEqualStrings("readme-notes.txt", f.hits[1].name);
    try t.expectEqualStrings("src", f.hits[1].at);
    try t.expectEqualStrings(".cache", f.hits[2].at);

    // one more letter: looked up among the last matches only
    f = (try search(a, ix, "readme-", false, 7)).?;
    try t.expectEqual(1, f.total);
    try t.expectEqualStrings("readme-notes.txt", f.hits[0].name);
    try t.expectEqual(1, last.?.matched.len);

    // no accents needed; a folder is a hit too
    f = (try search(a, ix, "tai lieu", false, 7)).?;
    try t.expectEqualStrings("Tài liệu", f.hits[0].name);
    try t.expect(f.hits[0].isDir);
    try t.expectEqualSlices(u32, &.{ 0, 3, 4, 8 }, f.hits[0].marks);
    f = (try search(a, ix, "hoa don", false, 7)).?;
    try t.expectEqual(1, f.total);
    try t.expectEqualStrings("Hoá đơn 2024.pdf", f.hits[0].name);
    try t.expectEqualStrings("Tài liệu", f.hits[0].at);

    // a word of the folders above
    f = (try search(a, ix, "march invoice", false, 7)).?;
    try t.expectEqual(1, f.total);
    try t.expectEqualStrings("march.xlsx", f.hits[0].name);
    try t.expectEqualStrings("invoice\\2024", f.hits[0].at);

    // ends with; initials
    f = (try search(a, ix, "*.tsx", false, 7)).?;
    try t.expectEqual(2, f.total);
    f = (try search(a, ix, "fe", false, 7)).?;
    try t.expectEqualStrings("FileExplorer.tsx", f.hits[0].name);

    // a newer search took the ticket
    try t.expect(try search(a, ix, "readme", false, 6) == null);
}
