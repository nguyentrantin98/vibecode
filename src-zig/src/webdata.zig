//! Bookmarks and history for the Web tab, shared by every tab of every chat.
//! Imported once from all Chrome profiles; visits in the Web tab are added from then on.
//! Kept in `<userData>/web-data.json`.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const unicase = @import("unicase.zig");
const sq = @import("sqlite");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Order = std.math.Order;

pub const commands = .{
    .{ "web_data", web_data },
    .{ "web_import_chrome", web_import_chrome },
    .{ "web_suggest", web_suggest },
    .{ "web_visit", web_visit },
    .{ "web_title", web_title },
};

const MAX_HISTORY = 20000;

/// Web tab bookmark: a link, or a folder of them.
pub const WebBookmark = struct {
    title: []const u8 = "",
    url: ?[]const u8 = null,
    children: ?[]const WebBookmark = null,

    /// `url` / `children` are left out when there is none
    pub fn jsonStringify(b: WebBookmark, w: anytype) !void {
        try w.beginObject();
        try w.objectField("title");
        try w.write(b.title);
        if (b.url) |u| {
            try w.objectField("url");
            try w.write(u);
        }
        if (b.children) |ch| {
            try w.objectField("children");
            try w.write(ch);
        }
        try w.endObject();
    }
};

pub const WebData = struct {
    /// when bookmarks and history were imported from Chrome (0 = not yet)
    importedAt: u64,
    bookmarks: []const WebBookmark,
    /// Chrome is installed, so there is something to import
    chromeFound: bool,
};

pub const WebSuggestion = struct {
    url: []const u8,
    title: []const u8,
    bookmark: ?bool = null,

    pub fn jsonStringify(s: WebSuggestion, w: anytype) !void {
        try w.beginObject();
        try w.objectField("url");
        try w.write(s.url);
        try w.objectField("title");
        try w.write(s.title);
        if (s.bookmark) |b| {
            try w.objectField("bookmark");
            try w.write(b);
        }
        try w.endObject();
    }
};

const HistoryEntry = struct {
    url: []const u8,
    title: []const u8 = "",
    visits: i64 = 0,
    /// last visit, ms
    last: i64 = 0,
};

/// What `web-data.json` holds.
const Saved = struct {
    importedAt: u64 = 0,
    bookmarks: []const WebBookmark = &.{},
    history: []const HistoryEntry = &.{},
};

const State = struct {
    loaded: bool = false,
    imported_at: u64 = 0,
    /// everything in it lives in `bookmarks_arena`
    bookmarks: []const WebBookmark = &.{},
    bookmarks_arena: ?std.heap.ArenaAllocator = null,
    /// by URL; the key is the entry's own `url`, the strings belong to the allocator the
    /// methods are given (`core.gpa` for the app's state)
    history: std.StringHashMapUnmanaged(HistoryEntry) = .empty,

    fn setBookmarks(st: *State, gpa: Allocator, list: []const WebBookmark) !void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const copy = try cloneBookmarks(arena.allocator(), list);
        if (st.bookmarks_arena) |*old| old.deinit();
        st.bookmarks_arena = arena;
        st.bookmarks = copy;
    }

    fn insert(st: *State, gpa: Allocator, h: HistoryEntry) !void {
        const url = try gpa.dupe(u8, h.url);
        errdefer gpa.free(url);
        const title = try gpa.dupe(u8, h.title);
        errdefer gpa.free(title);
        try st.history.put(gpa, url, .{ .url = url, .title = title, .visits = h.visits, .last = h.last });
    }

    fn setTitle(gpa: Allocator, h: *HistoryEntry, title: []const u8) !void {
        const copy = try gpa.dupe(u8, title);
        gpa.free(h.title);
        h.title = copy;
    }

    /// The saved file (missing or unreadable: nothing).
    fn load(st: *State, gpa: Allocator, path: []const u8) void {
        if (st.loaded) return;
        st.loaded = true;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = core.readFileAlloc(a, path, 1 << 30) catch return;
        const d = core.fromJson(Saved, a, text) catch return;
        st.imported_at = d.importedAt;
        st.setBookmarks(gpa, d.bookmarks) catch {};
        for (d.history) |h| {
            if (st.history.getPtr(h.url)) |old| {
                // the same URL twice in the file: the later one counts
                setTitle(gpa, old, h.title) catch {};
                old.visits = h.visits;
                old.last = h.last;
            } else st.insert(gpa, h) catch {};
        }
    }

    /// The text of `web-data.json`: the newest MAX_HISTORY visits.
    fn toJson(st: *const State, a: Allocator) ![]u8 {
        var list: std.ArrayList(HistoryEntry) = .empty;
        defer list.deinit(a);
        try list.ensureTotalCapacity(a, st.history.count());
        var it = st.history.valueIterator();
        while (it.next()) |h| list.appendAssumeCapacity(h.*);
        std.mem.sort(HistoryEntry, list.items, {}, struct {
            fn newer(_: void, x: HistoryEntry, y: HistoryEntry) bool {
                return x.last > y.last;
            }
        }.newer);
        const n = @min(list.items.len, MAX_HISTORY);
        return core.toJson(a, Saved{ .importedAt = st.imported_at, .bookmarks = st.bookmarks, .history = list.items[0..n] });
    }

    /// Chrome's history on top of ours: visits add up, the newer title wins.
    fn mergeHistory(st: *State, gpa: Allocator, rows: []const HistoryEntry) !void {
        for (rows) |r| {
            if (!isHttp(r.url)) continue;
            if (st.history.getPtr(r.url)) |h| {
                h.visits += r.visits;
                if (r.last > h.last) {
                    h.last = r.last;
                    if (r.title.len > 0) try setTitle(gpa, h, r.title);
                }
            } else try st.insert(gpa, r);
        }
    }

    /// false: not a web page, nothing recorded.
    fn recordVisit(st: *State, gpa: Allocator, url: []const u8, title: []const u8, now: i64) !bool {
        if (!isHttp(url)) return false;
        if (st.history.getPtr(url)) |h| {
            h.visits += 1;
            h.last = now;
            if (title.len > 0) try setTitle(gpa, h, title);
        } else try st.insert(gpa, .{ .url = url, .title = title, .visits = 1, .last = now });
        return true;
    }

    /// true when the title changed.
    fn setVisitTitle(st: *State, gpa: Allocator, url: []const u8, title: []const u8) !bool {
        const h = st.history.getPtr(url) orelse return false;
        if (title.len == 0 or std.mem.eql(u8, h.title, title)) return false;
        try setTitle(gpa, h, title);
        return true;
    }
};

fn cloneBookmarks(a: Allocator, list: []const WebBookmark) Allocator.Error![]const WebBookmark {
    const out = try a.alloc(WebBookmark, list.len);
    for (list, out) |b, *o| o.* = .{
        .title = try a.dupe(u8, b.title),
        .url = if (b.url) |u| try a.dupe(u8, u) else null,
        .children = if (b.children) |ch| try cloneBookmarks(a, ch) else null,
    };
    return out;
}

var mutex: core.Mutex = .{};
var state: State = .{};
/// Bumped by every `save`; the pending write waits until a second passes without one.
var save_gen: std.atomic.Value(u64) = .init(0);
var saving: std.atomic.Value(bool) = .init(false);

fn file(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"web-data.json"});
}

fn chromeRoot(a: Allocator) ![]u8 {
    if (core.is_mac) return std.fs.path.join(a, &.{ core.home(), "Library", "Application Support", "Google", "Chrome" });
    if (core.is_windows) return std.fs.path.join(a, &.{ core.localDataDir(), "Google", "Chrome", "User Data" });
    return std.fs.path.join(a, &.{ core.home(), ".config", "google-chrome" });
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn isHttp(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http:") or startsWithIgnoreCase(url, "https:");
}

/// with `mutex` held
fn loadState() void {
    if (state.loaded) return;
    const path = file(core.gpa) catch return;
    defer core.gpa.free(path);
    state.load(core.gpa, path);
}

/// Writes a second after the last change (visits come in bursts).
fn save() void {
    _ = save_gen.fetchAdd(1, .monotonic);
    if (saving.swap(true, .acq_rel)) return; // a write is already waiting
    core.spawn(saveLater, .{});
}

fn saveLater() void {
    while (true) {
        const gen = save_gen.load(.monotonic);
        core.sleepMs(1000);
        if (save_gen.load(.monotonic) != gen) continue;
        writeNow() catch |e| std.log.warn("web-data.json not saved: {s}", .{@errorName(e)});
        saving.store(false, .release);
        // changed while it was being written: that change found `saving` set and left it to us
        if (save_gen.load(.monotonic) == gen or saving.swap(true, .acq_rel)) return;
    }
}

fn writeNow() !void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = blk: {
        mutex.lock();
        defer mutex.unlock();
        break :blk try state.toJson(a);
    };
    try core.writeAtomic(try file(a), json);
}

fn getWebData(a: Allocator) !WebData {
    const local_state = try std.fs.path.join(a, &.{ try chromeRoot(a), "Local State" });
    mutex.lock();
    defer mutex.unlock();
    loadState();
    return .{ .importedAt = state.imported_at, .bookmarks = try cloneBookmarks(a, state.bookmarks), .chromeFound = core.exists(local_state) };
}

// ---------------- Chrome import ----------------

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// `v.a.b.c` when every step is an object
fn at(v: Value, path: []const []const u8) ?Value {
    var cur = v;
    for (path) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn readJson(a: Allocator, path: []const u8) ?Value {
    const text = core.readFileAlloc(a, path, 1 << 30) catch return null;
    return std.json.parseFromSliceLeaky(Value, a, text, .{}) catch null;
}

fn toBookmark(a: Allocator, n: Value) Allocator.Error!?WebBookmark {
    if (n != .object) return null;
    const title = str(n.object.get("name")) orelse "";
    const kind = str(n.object.get("type")) orelse return null;
    if (std.mem.eql(u8, kind, "url")) {
        const url = str(n.object.get("url")) orelse return null;
        if (url.len == 0) return null;
        return .{ .title = title, .url = url };
    }
    if (std.mem.eql(u8, kind, "folder")) {
        var children: std.ArrayList(WebBookmark) = .empty;
        if (n.object.get("children")) |ch| {
            if (ch == .array) for (ch.array.items) |x| {
                if (try toBookmark(a, x)) |b| try children.append(a, b);
            };
        }
        return .{ .title = title, .children = children.items };
    }
    return null;
}

/// One run of digits, or one run of anything else.
fn nextChunk(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= s.len) return null;
    const start = i.*;
    const digit = std.ascii.isDigit(s[start]);
    while (i.* < s.len and std.ascii.isDigit(s[i.*]) == digit) i.* += 1;
    return s[start..i.*];
}

/// `x` against `y` in small letters, char by char.
fn orderLower(x: []const u8, y: []const u8) Order {
    var xi = std.unicode.Utf8View.initUnchecked(x).iterator();
    var yi = std.unicode.Utf8View.initUnchecked(y).iterator();
    while (true) {
        const cx = xi.nextCodepoint() orelse return if (yi.nextCodepoint() == null) .eq else .lt;
        const cy = yi.nextCodepoint() orelse return .gt;
        const o = std.math.order(unicase.lower(cx), unicase.lower(cy));
        if (o != .eq) return o;
    }
}

/// "Profile 2" before "Profile 10".
fn naturalCmp(x: []const u8, y: []const u8) Order {
    var xi: usize = 0;
    var yi: usize = 0;
    while (true) {
        const cx = nextChunk(x, &xi) orelse return if (nextChunk(y, &yi) == null) .eq else .lt;
        const cy = nextChunk(y, &yi) orelse return .gt;
        var o: Order = undefined;
        if (std.ascii.isDigit(cx[0]) and std.ascii.isDigit(cy[0])) {
            const nx = std.mem.trimStart(u8, cx, "0");
            const ny = std.mem.trimStart(u8, cy, "0");
            o = std.math.order(nx.len, ny.len);
            if (o == .eq) o = std.mem.order(u8, nx, ny);
        } else {
            o = orderLower(cx, cy);
            if (o == .eq) o = std.mem.order(u8, cx, cy);
        }
        if (o != .eq) return o;
    }
}

fn profileBefore(_: void, x: []const u8, y: []const u8) bool {
    const dx = std.mem.eql(u8, x, "Default");
    const dy = std.mem.eql(u8, y, "Default");
    if (dx or dy) return dx and !dy;
    return naturalCmp(x, y) == .lt;
}

/// Chrome profile folders, Default first.
fn profiles(a: Allocator, root: []const u8) ![]const []const u8 {
    const ls = readJson(a, try std.fs.path.join(a, &.{ root, "Local State" })) orelse return a.dupe([]const u8, &.{"Default"});
    const cache = at(ls, &.{ "profile", "info_cache" }) orelse return &.{};
    if (cache != .object) return &.{};
    const names = try a.dupe([]const u8, cache.object.keys());
    std.mem.sort([]const u8, names, {}, profileBefore);
    return names;
}

const Importer = struct {
    a: Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(im: *Importer, to: *std.ArrayList(WebBookmark), nodes: ?Value) !void {
        const list = nodes orelse return;
        if (list != .array) return;
        for (list.array.items) |n| {
            if (n != .object) continue;
            const url: ?[]const u8 = if (str(n.object.get("url"))) |u| (if (u.len > 0) u else null) else null;
            const is_url = if (str(n.object.get("type"))) |k| std.mem.eql(u8, k, "url") else false;
            if (is_url and (url == null or im.seen.contains(url.?))) continue;
            if (url) |u| try im.seen.put(im.a, u, {});
            if (try toBookmark(im.a, n)) |b| {
                if (b.url != null or (b.children != null and b.children.?.len > 0)) try to.append(im.a, b);
            }
        }
    }
};

/// Bar items of every profile (deduplicated by URL); "other" and "mobile" bookmarks go in one folder at the end.
fn importBookmarks(a: Allocator, root: []const u8, dirs: []const []const u8) ![]const WebBookmark {
    var bar: std.ArrayList(WebBookmark) = .empty;
    var other: std.ArrayList(WebBookmark) = .empty;
    var im: Importer = .{ .a = a };
    for (dirs) |d| {
        // signed-in profiles keep them in AccountBookmarks, local ones in Bookmarks
        for ([_][]const u8{ "AccountBookmarks", "Bookmarks" }) |name| {
            const doc = readJson(a, try std.fs.path.join(a, &.{ root, d, name })) orelse continue;
            const roots = at(doc, &.{"roots"}) orelse continue;
            try im.add(&bar, at(roots, &.{ "bookmark_bar", "children" }));
            try im.add(&other, at(roots, &.{ "other", "children" }));
            try im.add(&other, at(roots, &.{ "synced", "children" }));
        }
    }
    if (other.items.len > 0) try bar.append(a, .{ .title = "Other bookmarks", .children = other.items });
    return bar.items;
}

fn copyFile(a: Allocator, src: []const u8, dst: []const u8) !void {
    const Dir = std.Io.Dir;
    if (!core.is_windows) return Dir.copyFile(Dir.cwd(), src, Dir.cwd(), dst, core.io, .{});
    // (CopyFileW reads a file another program holds open, as long as that one shares reading)
    if (core.host.win.c.CopyFileW((try core.wide(a, src)).ptr, (try core.wide(a, dst)).ptr, 0) == 0) return error.CopyFailed;
}

fn columnText(a: Allocator, stmt: ?*sq.sqlite3_stmt, col: c_int) ![]const u8 {
    const p = sq.sqlite3_column_text(stmt, col);
    if (p == null) return "";
    const n: usize = @intCast(sq.sqlite3_column_bytes(stmt, col));
    const s = p[0..n];
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    return a.dupe(u8, s);
}

/// History of one profile, read from a copy (Chrome keeps the file open).
fn readHistory(a: Allocator, src: []const u8, tmp: []const u8) ![]const HistoryEntry {
    copyFile(a, src, tmp) catch return &.{};
    var db: ?*sq.sqlite3 = null;
    defer _ = sq.sqlite3_close(db);
    if (sq.sqlite3_open_v2((try a.dupeSentinel(u8, tmp, 0)).ptr, &db, sq.SQLITE_OPEN_READONLY | sq.SQLITE_OPEN_NOMUTEX, null) != sq.SQLITE_OK) return error.Sqlite;
    // Chrome time is microseconds since 1601: turned into ms since 1970 in SQL
    const sql = std.fmt.comptimePrint(
        "SELECT url, title, visit_count AS visits, last_visit_time / 1000 - 11644473600000 AS last FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT {d}",
        .{MAX_HISTORY},
    );
    var stmt: ?*sq.sqlite3_stmt = null;
    if (sq.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sq.SQLITE_OK) return error.Sqlite;
    defer _ = sq.sqlite3_finalize(stmt);
    var out: std.ArrayList(HistoryEntry) = .empty;
    while (true) {
        const rc = sq.sqlite3_step(stmt);
        if (rc == sq.SQLITE_DONE) break;
        if (rc != sq.SQLITE_ROW) return error.Sqlite;
        try out.append(a, .{
            .url = try columnText(a, stmt, 0),
            .title = try columnText(a, stmt, 1),
            .visits = sq.sqlite3_column_int64(stmt, 2),
            .last = sq.sqlite3_column_int64(stmt, 3),
        });
    }
    return out.items;
}

/// The history of every profile; `tmp_dir` is where the copies are made.
fn importHistory(a: Allocator, root: []const u8, dirs: []const []const u8, tmp_dir: []const u8) ![]const []const HistoryEntry {
    const tmp = try std.fmt.allocPrint(a, "{s}{c}vibe-chrome-history-{d}.db", .{ tmp_dir, std.fs.path.sep, core.nowMs() });
    var out: std.ArrayList([]const HistoryEntry) = .empty;
    for (dirs) |d| {
        // a profile without history, or a copy that failed, just adds nothing
        if (readHistory(a, try std.fs.path.join(a, &.{ root, d, "History" }), tmp)) |rows| try out.append(a, rows) else |_| {}
        std.Io.Dir.cwd().deleteFile(core.io, tmp) catch {};
    }
    return out.items;
}

fn importChrome(a: Allocator) !WebData {
    {
        mutex.lock();
        defer mutex.unlock();
        loadState();
    }
    const root = try chromeRoot(a);
    const dirs = try profiles(a, root);
    const bookmarks = try importBookmarks(a, root, dirs);
    const profiles_rows = try importHistory(a, root, dirs, core.tempDir());
    {
        mutex.lock();
        defer mutex.unlock();
        try state.setBookmarks(core.gpa, bookmarks);
        for (profiles_rows) |rows| try state.mergeHistory(core.gpa, rows);
        state.imported_at = core.nowMs();
    }
    save();
    return getWebData(a);
}

// ---------------- visits and suggestions ----------------

/// The URL without `http://` / `https://` and a leading `www.` (any case).
fn stripScheme(url: []const u8) []const u8 {
    if (!startsWithIgnoreCase(url, "http")) return url;
    var rest = url[4..];
    if (rest.len > 0 and (rest[0] == 's' or rest[0] == 'S')) rest = rest[1..];
    if (!std.mem.startsWith(u8, rest, "://")) return url;
    rest = rest[3..];
    return if (startsWithIgnoreCase(rest, "www.")) rest[4..] else rest;
}

const Hit = struct {
    url: []const u8,
    title: []const u8,
    bookmark: ?bool,
    visits: i64,
    last: i64,
    score: f64 = 0,
};

const Suggester = struct {
    a: Allocator,
    words: []const []const u8,
    found: std.ArrayList(Hit) = .empty,
    /// URL → its place in `found`
    index: std.StringHashMapUnmanaged(usize) = .empty,
    buf: std.ArrayList(u8) = .empty,

    /// URL or title contains every typed word
    fn matches(s: *Suggester, url: []const u8, title: []const u8) !bool {
        s.buf.clearRetainingCapacity();
        try unicase.lowerInto(s.a, &s.buf, url);
        try s.buf.append(s.a, ' ');
        try unicase.lowerInto(s.a, &s.buf, title);
        for (s.words) |w| {
            if (std.mem.indexOf(u8, s.buf.items, w) == null) return false;
        }
        return true;
    }

    fn walk(s: *Suggester, list: []const WebBookmark) !void {
        for (list) |b| {
            if (b.children) |children| {
                try s.walk(children);
                continue;
            }
            const url = b.url orelse continue;
            if (url.len == 0 or !try s.matches(url, b.title)) continue;
            const hit: Hit = .{ .url = try s.a.dupe(u8, url), .title = try s.a.dupe(u8, b.title), .bookmark = true, .visits = 0, .last = 0 };
            if (s.index.get(url)) |i| {
                s.found.items[i] = hit;
            } else {
                try s.index.put(s.a, hit.url, s.found.items.len);
                try s.found.append(s.a, hit);
            }
        }
    }
};

/// Address-bar suggestions: bookmarks and history whose URL or title contains every typed word.
fn suggest(a: Allocator, st: *const State, query: []const u8, limit: usize, now_ms: u64) ![]WebSuggestion {
    const q = try unicase.lowerStr(a, try unicase.plainSpaces(a, query));
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |w| try words.append(a, w);
    if (words.items.len == 0) return &.{};
    const first = words.items[0];
    // every match, bookmarked or visited, ranked together (first-seen order breaks ties)
    var s: Suggester = .{ .a = a, .words = words.items };
    try s.walk(st.bookmarks);
    var hi = st.history.valueIterator();
    while (hi.next()) |h| {
        if (!try s.matches(h.url, h.title)) continue;
        if (s.index.get(h.url)) |i| {
            s.found.items[i].visits = h.visits;
            s.found.items[i].last = h.last;
        } else {
            const url = try a.dupe(u8, h.url);
            try s.index.put(a, url, s.found.items.len);
            try s.found.append(a, .{ .url = url, .title = try a.dupe(u8, h.title), .bookmark = null, .visits = h.visits, .last = h.last });
        }
    }
    const now: f64 = @floatFromInt(now_ms);
    // frequent, recent, bookmarked and short (site roots) first; a host typed from its start ranks highest
    for (s.found.items) |*x| {
        const bare = try unicase.lowerStr(a, stripScheme(x.url));
        const age: f64 = if (x.last != 0) (now - @as(f64, @floatFromInt(x.last))) / (30.0 * 864e5) else 3.0;
        const visits: f64 = @floatFromInt(x.visits);
        const len: f64 = @floatFromInt(std.unicode.calcUtf16LeLen(bare) catch bare.len);
        x.score = @log(1.0 + visits) - @min(age, 6.0) + @as(f64, if (x.bookmark == true) 2.0 else 0.0) +
            @as(f64, if (std.mem.startsWith(u8, bare, first)) 5.0 else 0.0) - len / 60.0;
    }
    std.mem.sort(Hit, s.found.items, {}, struct {
        fn higher(_: void, x: Hit, y: Hit) bool {
            return x.score > y.score;
        }
    }.higher);
    const n = @min(limit, s.found.items.len);
    const out = try a.alloc(WebSuggestion, n);
    for (s.found.items[0..n], out) |f, *o| o.* = .{ .url = f.url, .title = f.title, .bookmark = f.bookmark };
    return out;
}

// ---------------- commands ----------------

fn web_data(call: *ipc.Call) !WebData {
    return getWebData(call.arena);
}

fn web_import_chrome(call: *ipc.Call) !WebData {
    return importChrome(call.arena);
}

fn web_suggest(call: *ipc.Call, args: struct { query: []const u8 }) ![]WebSuggestion {
    mutex.lock();
    defer mutex.unlock();
    loadState();
    return suggest(call.arena, &state, args.query, 8, core.nowMs());
}

fn web_visit(_: *ipc.Call, args: struct { url: []const u8, title: ?[]const u8 = null }) !void {
    const recorded = blk: {
        mutex.lock();
        defer mutex.unlock();
        loadState();
        break :blk try state.recordVisit(core.gpa, args.url, args.title orelse "", @intCast(core.nowMs()));
    };
    if (recorded) save();
}

fn web_title(_: *ipc.Call, args: struct { url: []const u8, title: []const u8 }) !void {
    const changed = blk: {
        mutex.lock();
        defer mutex.unlock();
        break :blk try state.setVisitTitle(core.gpa, args.url, args.title);
    };
    if (changed) save();
}

// ---------------- tests ----------------

const t = std.testing;

/// A temp folder with its absolute path, and an arena for everything a test makes.
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

test "stripScheme" {
    try t.expectEqualStrings("github.com/x", stripScheme("https://www.github.com/x"));
    try t.expectEqualStrings("github.com", stripScheme("HTTP://WWW.github.com"));
    try t.expectEqualStrings("example.org/www.", stripScheme("http://example.org/www."));
    try t.expectEqualStrings("wwwx.org", stripScheme("https://wwwx.org"));
    try t.expectEqualStrings("ftp://www.x.org", stripScheme("ftp://www.x.org"));
    try t.expectEqualStrings("httpx://a", stripScheme("httpx://a"));
    try t.expectEqualStrings("https:/a", stripScheme("https:/a"));
    try t.expectEqualStrings("www.x.org", stripScheme("www.x.org"));
    try t.expectEqualStrings("", stripScheme("https://"));
    try t.expectEqualStrings("http", stripScheme("http"));
}

test "isHttp" {
    try t.expect(isHttp("http://a") and isHttp("HTTPS://a") and isHttp("https:"));
    try t.expect(!isHttp("chrome://settings") and !isHttp("file:///x") and !isHttp("http") and !isHttp(""));
}

test "naturalCmp and the order of profiles" {
    try t.expectEqual(Order.lt, naturalCmp("Profile 2", "Profile 10"));
    try t.expectEqual(Order.gt, naturalCmp("Profile 10", "Profile 9"));
    try t.expectEqual(Order.eq, naturalCmp("Profile 3", "Profile 3"));
    try t.expectEqual(Order.lt, naturalCmp("Profile 3", "Profile 03x"));
    try t.expectEqual(Order.lt, naturalCmp("Profile", "Profile 1"));
    try t.expectEqual(Order.lt, naturalCmp("a2", "B1"));
    try t.expectEqual(Order.lt, naturalCmp("Guest", "guest"));
    try t.expectEqual(Order.lt, naturalCmp("7", "x"));
    var names = [_][]const u8{ "Profile 10", "Profile 2", "Default", "Guest Profile", "Profile 1" };
    std.mem.sort([]const u8, &names, {}, profileBefore);
    const want = [_][]const u8{ "Default", "Guest Profile", "Profile 1", "Profile 2", "Profile 10" };
    for (want, names) |w, n| try t.expectEqualStrings(w, n);
}

const bookmarks_default =
    \\{"roots":{
    \\ "bookmark_bar":{"children":[
    \\   {"type":"url","name":"GitHub","url":"https://github.com/"},
    \\   {"type":"folder","name":"Docs","children":[
    \\     {"type":"url","name":"Zig","url":"https://ziglang.org/documentation/"},
    \\     {"type":"url","name":"no url"},
    \\     {"type":"folder","name":"empty","children":[]}]},
    \\   {"type":"folder","name":"nothing in it","children":[]},
    \\   {"type":"separator","name":"?"}]},
    \\ "other":{"children":[{"type":"url","name":"News","url":"https://news.ycombinator.com/"}]},
    \\ "synced":{"children":[{"type":"url","name":"Phone","url":"https://m.example.com/"}]}}}
;
const bookmarks_profile2 =
    \\{"roots":{"bookmark_bar":{"children":[
    \\   {"type":"url","name":"GitHub again","url":"https://github.com/"},
    \\   {"type":"url","name":"Tin tức","url":"https://vnexpress.net/"}]},
    \\ "other":{"children":[]}}}
;

test "Chrome bookmarks of every profile" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    try x.write("Local State", "{\"profile\":{\"info_cache\":{\"Profile 2\":{},\"Default\":{},\"Profile 10\":{}}}}");
    try x.write("Default/Bookmarks", bookmarks_default);
    try x.write("Profile 2/AccountBookmarks", bookmarks_profile2);
    try x.write("Profile 10/Bookmarks", "not json");

    const dirs = try profiles(a, x.root);
    try t.expectEqual(3, dirs.len);
    try t.expectEqualStrings("Default", dirs[0]);
    try t.expectEqualStrings("Profile 2", dirs[1]);
    try t.expectEqualStrings("Profile 10", dirs[2]);
    // no Local State: the one profile every Chrome has
    const none = try profiles(a, x.path("nowhere"));
    try t.expectEqual(1, none.len);
    try t.expectEqualStrings("Default", none[0]);

    const bar = try importBookmarks(a, x.root, dirs);
    try t.expectEqualStrings(
        \\[{"title":"GitHub","url":"https://github.com/"},{"title":"Docs","children":[{"title":"Zig","url":"https://ziglang.org/documentation/"},{"title":"empty","children":[]}]},{"title":"Tin tức","url":"https://vnexpress.net/"},{"title":"Other bookmarks","children":[{"title":"News","url":"https://news.ycombinator.com/"},{"title":"Phone","url":"https://m.example.com/"}]}]
    , try core.toJson(a, bar));
}

fn exec(db: ?*sq.sqlite3, sql: [*:0]const u8) !void {
    if (sq.sqlite3_exec(db, sql, null, null, null) != sq.SQLITE_OK) return error.Sqlite;
}

/// A Chrome "History" database with a few visits; times are Chrome's (µs since 1601).
fn makeHistory(a: Allocator, path: []const u8) !void {
    var db: ?*sq.sqlite3 = null;
    defer _ = sq.sqlite3_close(db);
    if (sq.sqlite3_open_v2((try a.dupeSentinel(u8, path, 0)).ptr, &db, sq.SQLITE_OPEN_READWRITE | sq.SQLITE_OPEN_CREATE, null) != sq.SQLITE_OK) return error.Sqlite;
    try exec(db, "CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)");
    // 13350000000000000 µs since 1601 = 1705526400000 ms since 1970
    try exec(db, "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden) VALUES" ++
        " ('https://github.com/', 'GitHub', 40, 13350000000000000, 0)," ++
        " ('https://ziglang.org/', NULL, 3, 13350000001000000, 0)," ++
        " ('https://hidden.example/', 'Hidden', 9, 13350000002000000, 1)," ++
        " ('chrome://settings/', 'Settings', 5, 13350000003000000, 0)");
}

test "Chrome history: read from a copy, merged into ours" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    try x.tmp.dir.createDirPath(t.io, "Default");
    try x.tmp.dir.createDirPath(t.io, "Profile 1");
    try makeHistory(a, x.path("Default\\History"));
    try x.write("Profile 1/History", "this is not a database");

    const all = try importHistory(a, x.root, &.{ "Default", "Profile 1", "Profile 2" }, x.root);
    // the broken profile adds nothing; the one without a History file adds no rows
    try t.expectEqual(2, all.len);
    try t.expectEqual(0, all[1].len);
    const rows = all[0];
    try t.expectEqual(3, rows.len); // newest first, the hidden one left out
    try t.expectEqualStrings("chrome://settings/", rows[0].url);
    try t.expectEqualStrings("https://ziglang.org/", rows[1].url);
    try t.expectEqualStrings("", rows[1].title);
    try t.expectEqual(3, rows[1].visits);
    try t.expectEqual(1705526401000, rows[1].last);
    try t.expectEqualStrings("GitHub", rows[2].title);
    try t.expectEqual(1705526400000, rows[2].last);
    // the copies are gone
    var dir = try x.tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    while (try it.next(t.io)) |e| try t.expect(!std.mem.startsWith(u8, e.name, "vibe-chrome-history-"));

    var st: State = .{};
    try t.expect(try st.recordVisit(a, "https://github.com/", "GitHub · mine", 1705526400500));
    try st.mergeHistory(a, rows);
    try t.expectEqual(2, st.history.count()); // chrome:// is not a web page
    const gh = st.history.get("https://github.com/").?;
    try t.expectEqual(41, gh.visits);
    try t.expectEqual(1705526400500, gh.last);
    try t.expectEqualStrings("GitHub · mine", gh.title); // ours is newer
    // again, with a newer visit: the time and the title follow
    try st.mergeHistory(a, &.{.{ .url = "https://github.com/", .title = "GitHub!", .visits = 1, .last = 1705526409999 }});
    try t.expectEqualStrings("GitHub!", st.history.get("https://github.com/").?.title);
    try t.expectEqual(42, st.history.get("https://github.com/").?.visits);
}

test "visits, titles, and the saved file" {
    var x: Tmp = undefined;
    try x.init();
    defer x.deinit();
    const a = x.arena.allocator();
    var st: State = .{ .loaded = true };
    try t.expect(!try st.recordVisit(a, "about:blank", "", 5));
    try t.expect(try st.recordVisit(a, "https://a.example/", "A", 1000));
    try t.expect(try st.recordVisit(a, "https://b.example/", "", 3000));
    try t.expect(try st.recordVisit(a, "https://a.example/", "", 2000));
    try t.expectEqual(2, st.history.get("https://a.example/").?.visits);
    try t.expectEqualStrings("A", st.history.get("https://a.example/").?.title); // an empty title keeps the old one
    try t.expect(try st.setVisitTitle(a, "https://b.example/", "B"));
    try t.expect(!try st.setVisitTitle(a, "https://b.example/", "B"));
    try t.expect(!try st.setVisitTitle(a, "https://b.example/", ""));
    try t.expect(!try st.setVisitTitle(a, "https://never.example/", "x"));
    st.imported_at = 42;
    try st.setBookmarks(a, &.{.{ .title = "Folder", .children = &.{.{ .title = "A", .url = "https://a.example/" }} }});

    const json = try st.toJson(a);
    try t.expectEqualStrings(
        \\{"importedAt":42,"bookmarks":[{"title":"Folder","children":[{"title":"A","url":"https://a.example/"}]}],"history":[{"url":"https://b.example/","title":"B","visits":1,"last":3000},{"url":"https://a.example/","title":"A","visits":2,"last":2000}]}
    , json);

    // what the Rust build wrote reads back the same; unknown keys and missing ones are fine
    try x.write("web-data.json", json);
    var back: State = .{};
    back.load(a, x.path("web-data.json"));
    try t.expectEqualStrings(json, try back.toJson(a));
    try x.write("old.json", "{\"bookmarks\":[{\"title\":\"x\",\"url\":\"https://x/\",\"extra\":1}],\"history\":[{\"url\":\"https://x/\"}]}");
    var old: State = .{};
    old.load(a, x.path("old.json"));
    try t.expectEqual(0, old.imported_at);
    try t.expectEqualStrings("https://x/", old.bookmarks[0].url.?);
    try t.expectEqual(0, old.history.get("https://x/").?.visits);
    // no file, or a broken one: empty
    var none: State = .{};
    none.load(a, x.path("missing.json"));
    try t.expect(none.loaded and none.history.count() == 0);
    try x.write("bad.json", "{\"history\":[{\"title\":\"no url\"}]}");
    var bad: State = .{};
    bad.load(a, x.path("bad.json"));
    try t.expectEqual(0, bad.history.count());
}

test "suggest" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day = 864e5;
    const now: u64 = 1_700_000_000_000;
    var st: State = .{ .loaded = true };
    try st.setBookmarks(a, &.{
        .{ .title = "GitHub", .url = "https://github.com/" },
        .{ .title = "Dev", .children = &.{
            .{ .title = "Zig Documentation", .url = "https://ziglang.org/documentation/master/" },
            .{ .title = "Tài liệu Git", .url = "https://git-scm.com/doc" },
        } },
    });
    try st.insert(a, .{ .url = "https://github.com/", .title = "GitHub: Let's build", .visits = 50, .last = @intFromFloat(@as(f64, @floatFromInt(now)) - day) });
    try st.insert(a, .{ .url = "https://github.com/ziglang/zig/issues/1234", .title = "some issue", .visits = 2, .last = @intFromFloat(@as(f64, @floatFromInt(now)) - 2 * day) });
    try st.insert(a, .{ .url = "https://www.google.com/search?q=github", .title = "github - Google Search", .visits = 1, .last = @intFromFloat(@as(f64, @floatFromInt(now)) - 200 * day) });
    try st.insert(a, .{ .url = "https://example.org/", .title = "Example", .visits = 99, .last = @intCast(now) });

    // the bookmarked, visited site root first; its bookmark title is kept, the visits count
    var r = try suggest(a, &st, "git", 8, now);
    try t.expectEqual(4, r.len);
    try t.expectEqualStrings("https://github.com/", r[0].url);
    try t.expectEqualStrings("GitHub", r[0].title);
    try t.expectEqual(true, r[0].bookmark);
    try t.expectEqualStrings("https://github.com/ziglang/zig/issues/1234", r[1].url);
    try t.expectEqual(null, r[1].bookmark);
    try t.expectEqualStrings("https://git-scm.com/doc", r[2].url); // never visited, but bookmarked and typed from its start
    try t.expectEqualStrings("https://www.google.com/search?q=github", r[3].url);

    // every word, in the URL or the title, any case
    r = try suggest(a, &st, "ZIG  doc", 8, now);
    try t.expectEqual(1, r.len);
    try t.expectEqualStrings("Zig Documentation", r[0].title);
    r = try suggest(a, &st, "TÀI liệu", 8, now);
    try t.expectEqual(1, r.len);
    try t.expectEqualStrings("https://git-scm.com/doc", r[0].url);
    // "www." does not count for typing a host from its start
    r = try suggest(a, &st, "goo", 8, now);
    try t.expectEqualStrings("https://www.google.com/search?q=github", r[0].url);

    try t.expectEqual(2, (try suggest(a, &st, "git", 2, now)).len);
    try t.expectEqual(0, (try suggest(a, &st, "   ", 8, now)).len);
    try t.expectEqual(0, (try suggest(a, &st, "nothing-like-this", 8, now)).len);
    try t.expectEqualStrings(
        \\[{"url":"https://example.org/","title":"Example"}]
    , try core.toJson(a, try suggest(a, &st, "example", 8, now)));
}
