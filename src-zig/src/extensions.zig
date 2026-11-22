//! Browser extensions in the Web tabs, beside the built-in ad blocker (adblock.zig): added from the
//! Chrome Web Store (a link or an id) or from an unpacked folder. WebView2 keeps them in the Web
//! tabs' profile; `extensions/index.json` remembers each one's folder, to find its options page.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const adblock = @import("adblock.zig");
const browser = @import("browser.zig");
const J = @import("browser_json.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const tr = settings.tr;

pub const commands = .{
    .{ "web_extensions", web_extensions },
    .{ "web_extension_add", web_extension_add },
    .{ "web_extension_enable", web_extension_enable },
    .{ "web_extension_remove", web_extension_remove },
};

pub const ExtInfo = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool,
    /// the ad blocker: switched with the shield setting, not removable
    builtin: bool,
    /// its settings page (chrome-extension://…), when it has one
    options: ?[]const u8 = null,

    /// `options` is left out when there is none.
    pub fn jsonStringify(e: ExtInfo, w: anytype) !void {
        try w.beginObject();
        try w.objectField("id");
        try w.write(e.id);
        try w.objectField("name");
        try w.write(e.name);
        try w.objectField("enabled");
        try w.write(e.enabled);
        try w.objectField("builtin");
        try w.write(e.builtin);
        if (e.options) |o| {
            try w.objectField("options");
            try w.write(o);
        }
        try w.endObject();
    }
};

fn root(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"extensions"});
}

/// id → the extension's folder.
fn index(a: Allocator) std.json.ObjectMap {
    const path = core.dataPath(a, &.{ "extensions", "index.json" }) catch return .empty;
    const bytes = core.readFileAlloc(a, path, 16 << 20) catch return .empty;
    const v = J.parse(a, bytes) orelse return .empty;
    return if (v == .object) v.object else .empty;
}

fn saveIndex(a: Allocator, map: std.json.ObjectMap) void {
    const path = core.dataPath(a, &.{ "extensions", "index.json" }) catch return;
    const json = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = map }, .{ .whitespace = .indent_2 }) catch return;
    core.writeFile(path, json) catch {};
}

/// The page to open as its settings: options page, else the toolbar popup (WebView2 has no toolbar).
fn optionsPage(a: Allocator, dir: []const u8) ?[]const u8 {
    const path = std.fs.path.join(a, &.{ dir, "manifest.json" }) catch return null;
    const m = J.parse(a, core.readFileAlloc(a, path, 16 << 20) catch return null) orelse return null;
    const candidates = [_]?J.Value{
        J.path(m, &.{ "options_ui", "page" }),
        J.get(m, "options_page"),
        J.path(m, &.{ "action", "default_popup" }),
        J.path(m, &.{ "browser_action", "default_popup" }),
    };
    for (candidates) |v| if (J.str(v)) |s| if (s.len > 0) return std.mem.trimStart(u8, s, "/");
    return null;
}

/// The extension's folder on disk: the ad blocker's, or one added here.
fn folderOf(a: Allocator, id: []const u8, builtin: bool) ?[]const u8 {
    if (builtin) return if (adblock.installed(a)) |i| i.dir else null;
    return J.str(index(a).get(id));
}

pub fn info(a: Allocator, id: []const u8, name: []const u8, enabled: bool) ExtInfo {
    const builtin = std.mem.startsWith(u8, name, adblock.NAME);
    var options: ?[]const u8 = null;
    if (folderOf(a, id, builtin)) |dir| if (optionsPage(a, dir)) |p| {
        options = std.fmt.allocPrint(a, "chrome-extension://{s}/{s}", .{ id, p }) catch null;
    };
    return .{ .id = id, .name = name, .enabled = enabled, .builtin = builtin, .options = options };
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// A Web Store link ("https://chromewebstore.google.com/detail/name/<id>") or a bare id → the id:
/// the first word that is exactly 32 letters a–p (the regex `\b[a-p]{32}\b`).
fn storeId(input: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < input.len) {
        if (!isWord(input[i])) {
            i += 1;
            continue;
        }
        const start = i;
        var all = true;
        while (i < input.len and isWord(input[i])) : (i += 1) {
            if (input[i] < 'a' or input[i] > 'p') all = false;
        }
        if (all and i - start == 32) return input[start..i];
    }
    return null;
}

const Crx = union(enum) {
    /// the zip inside the package
    zip: []const u8,
    not_crx,
    unknown_version: u32,
    cut_short,
};

/// CRX = "Cr24", version, then (v3) a header of `len` bytes or (v2) a key and a signature; the zip follows.
fn crxZip(crx: []const u8) Crx {
    if (crx.len < 16 or !std.mem.eql(u8, crx[0..4], "Cr24")) return .not_crx;
    const n = struct {
        fn n(b: []const u8, at_: usize) usize {
            return std.mem.readInt(u32, b[at_..][0..4], .little);
        }
    }.n;
    const start = switch (n(crx, 4)) {
        3 => 12 + n(crx, 8),
        2 => 16 + n(crx, 8) + n(crx, 12),
        else => |v| return .{ .unknown_version = @intCast(v) },
    };
    if (start > crx.len) return .cut_short;
    return .{ .zip = crx[start..] };
}

/// Downloads a Web Store extension and unpacks it into `extensions/<id>`.
fn download(a: Allocator, id: []const u8, fail: *core.Fail) ![]const u8 {
    const url = try std.fmt.allocPrint(
        a,
        "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx2,crx3&x=id%3D{s}%26installsource%3Dondemand%26uc",
        .{id},
    );
    const res = http.get(a, url, &.{}) catch |e| return fail.set(a, "Web Store: {s}", .{@errorName(e)});
    if (!res.ok()) return fail.set(a, "Web Store: HTTP {d}", .{res.status});
    const zip = switch (crxZip(res.body)) {
        .zip => |z| z,
        .not_crx => return fail.set(a, "{s}", .{tr(
            "the Web Store did not send an extension (is the id right, and is it a Chrome extension?)",
            "Web Store không gửi về tiện ích nào (id có đúng không, và đó có phải tiện ích Chrome không?)",
        )}),
        .unknown_version => |v| return fail.set(a, "unknown extension package version {d}", .{v}),
        .cut_short => return fail.set(a, "the extension package is cut short", .{}),
    };

    const dir = try root(a);
    try core.makePath(dir);
    const file = try std.fmt.allocPrint(a, "{s}{c}{s}.zip", .{ dir, std.fs.path.sep, id });
    const part = try std.fmt.allocPrint(a, "{s}{c}{s}.part", .{ dir, std.fs.path.sep, id });
    const done = try std.fs.path.join(a, &.{ dir, id });
    try core.writeFile(file, zip);
    if (try unpack(a, file, part)) |why|
        return fail.set(a, "{s} {s}", .{ tr("could not unpack the extension:", "không giải nén được tiện ích:"), why });
    Dir.cwd().deleteTree(core.io, done) catch {};
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), done, core.io);
    return done;
}

/// Unpacks the zip `file` (deleted afterwards) into the folder `part`, ready to be loaded
/// unpacked. Returns why it could not (nothing is left behind then), null when it worked.
fn unpack(a: Allocator, file: []const u8, part: []const u8) !?[]const u8 {
    Dir.cwd().deleteTree(core.io, part) catch {};
    const unpacked = adblock.unzip(file, part);
    Dir.cwd().deleteFile(core.io, file) catch {};
    const manifest = try std.fs.path.join(a, &.{ part, "manifest.json" });
    const why: ?[]const u8 = if (unpacked) |_| (if (core.isFile(manifest)) null else "no manifest.json") else |e| @errorName(e);
    if (why != null) {
        Dir.cwd().deleteTree(core.io, part) catch {};
        return why;
    }
    // the store's signature folder: names starting with "_" are refused when loading unpacked
    const metadata = try std.fs.path.join(a, &.{ part, "_metadata" });
    Dir.cwd().deleteTree(core.io, metadata) catch {};
    return null;
}

/// Extensions the Web tabs come with (beside the ad blocker): added once, so one you remove stays removed.
const DEFAULTS = [_][]const u8{
    // Claude in Chrome
    "fcoeoabgfenejglbffodgkkbkcdhcgfn",
};

/// Startup: adds the default extensions not added before.
pub fn installDefaults() void {
    if (!core.is_windows) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = core.dataPath(a, &.{ "extensions", "defaults.txt" }) catch return;
    var done: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, core.readFileAlloc(a, marker, 1 << 20) catch "", "\r\n");
    while (lines.next()) |l| done.append(a, l) catch return;
    for (DEFAULTS) |id| {
        const added = for (done.items) |d| {
            if (std.mem.eql(u8, d, id)) break true;
        } else false;
        if (added) continue;
        var fail: core.Fail = .{};
        if (add(a, id, null, &fail)) |_| {
            done.append(a, id) catch return;
        } else |e| {
            // offline, or WebView2 refused it: tried again next launch
            std.log.warn("default extension {s}: {s}", .{ id, fail.text(e) });
        }
    }
    core.writeFile(marker, std.mem.join(a, "\n", done.items) catch return) catch {};
}

/// Loads the Web Store extension `store` (or the unpacked folder `folder`) into the Web tabs and
/// remembers where it lives.
fn add(a: Allocator, store: []const u8, folder: ?[]const u8, fail: *core.Fail) !browser.Ext {
    const dir = folder orelse try download(a, store, fail);
    const ext = try browser.addExtension(a, dir, fail);
    var map = index(a);
    try map.put(a, ext.id, .{ .string = dir });
    saveIndex(a, map);
    return ext;
}

// ---------------- commands ----------------

fn web_extensions(c: *ipc.Call) ![]ExtInfo {
    var fail: core.Fail = .{};
    return browser.extensions(c.arena, &fail) catch |e| c.failMsg(fail.text(e));
}

/// Adds an extension from a Web Store link / id, or from an unpacked folder (one with manifest.json).
fn web_extension_add(c: *ipc.Call, args: struct { source: []const u8 }) !ExtInfo {
    const a = c.arena;
    const source = std.mem.trim(u8, args.source, " \t\r\n");
    const manifest = try std.fs.path.join(a, &.{ source, "manifest.json" });
    const folder: ?[]const u8 = if (source.len > 0 and core.isFile(manifest)) source else null;
    const id = if (folder == null) storeId(source) orelse return c.failMsg(tr(
        "Paste a Chrome Web Store link (or the extension's id), or pick a folder that has a manifest.json.",
        "Dán link Chrome Web Store (hoặc id của tiện ích), hoặc chọn một thư mục có manifest.json.",
    )) else "";
    var fail: core.Fail = .{};
    const ext = add(a, id, folder, &fail) catch |e| return c.failMsg(fail.text(e));
    return info(a, ext.id, ext.name, ext.enabled);
}

fn web_extension_enable(c: *ipc.Call, args: struct { id: []const u8, on: bool }) !void {
    var fail: core.Fail = .{};
    browser.extensionEnable(c.arena, args.id, args.on, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn web_extension_remove(c: *ipc.Call, args: struct { id: []const u8 }) !void {
    const a = c.arena;
    var fail: core.Fail = .{};
    browser.extensionRemove(a, args.id, &fail) catch |e| return c.failMsg(fail.text(e));
    var map = index(a);
    // a Web Store download is ours to delete; a folder you picked stays where it is
    if (map.fetchOrderedRemove(args.id)) |kv| if (J.str(kv.value)) |dir| {
        if (isInside(dir, try root(a))) Dir.cwd().deleteTree(core.io, dir) catch {};
    };
    saveIndex(a, map);
}

/// `path` is `dir` or something under it.
fn isInside(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or std.fs.path.isSep(path[dir.len]));
}

test "ids" {
    try std.testing.expectEqualStrings(
        "ddkjiahejlhfcafbddmgiahcphecmpfh",
        storeId("https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en").?,
    );
    try std.testing.expectEqualStrings("ddkjiahejlhfcafbddmgiahcphecmpfh", storeId("ddkjiahejlhfcafbddmgiahcphecmpfh").?);
    try std.testing.expect(storeId("not an id") == null);
    try std.testing.expect(storeId("") == null);
    // word boundaries: 33 letters, a letter outside a–p, or glued to other word characters
    try std.testing.expect(storeId("ddkjiahejlhfcafbddmgiahcphecmpfha") == null);
    try std.testing.expect(storeId("ddkjiahejlhfcafbddmgiahcphecmpfz") == null);
    try std.testing.expect(storeId("x_ddkjiahejlhfcafbddmgiahcphecmpfh") == null);
    try std.testing.expect(storeId("ddkjiahejlhfcafbddmgiahcphecmpfh9") == null);
    // the first one that fits wins
    try std.testing.expectEqualStrings("ddkjiahejlhfcafbddmgiahcphecmpfh", storeId("  id: abcdefghijklmnop / ddkjiahejlhfcafbddmgiahcphecmpfh, fcoeoabgfenejglbffodgkkbkcdhcgfn").?);
}

test "the zip inside a crx" {
    const v3 = "Cr24" ++ "\x03\x00\x00\x00" ++ "\x05\x00\x00\x00" ++ "HEADR" ++ "PK-zip";
    try std.testing.expectEqualStrings("PK-zip", crxZip(v3).zip);
    const v2 = "Cr24" ++ "\x02\x00\x00\x00" ++ "\x03\x00\x00\x00" ++ "\x02\x00\x00\x00" ++ "KEY" ++ "SG" ++ "PK-zip";
    try std.testing.expectEqualStrings("PK-zip", crxZip(v2).zip);
    try std.testing.expect(crxZip("<html>blocked</html>") == .not_crx);
    try std.testing.expect(crxZip("Cr24") == .not_crx);
    try std.testing.expectEqual(@as(u32, 9), crxZip("Cr24" ++ "\x09\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00").unknown_version);
    try std.testing.expect(crxZip("Cr24" ++ "\x03\x00\x00\x00" ++ "\xff\xff\x00\x00" ++ "abcd") == .cut_short);
    // nothing after the header is an empty zip, not an error here
    try std.testing.expectEqualStrings("", crxZip("Cr24" ++ "\x03\x00\x00\x00" ++ "\x04\x00\x00\x00" ++ "abcd").zip);
}

test "options page and unpacking" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try adblock.testDir(a, &tmp);

    const cases = [_]struct { manifest: []const u8, page: ?[]const u8 }{
        .{ .manifest = "{\"options_ui\":{\"page\":\"/options.html\"},\"options_page\":\"old.html\"}", .page = "options.html" },
        .{ .manifest = "{\"options_page\":\"dashboard.html#x\"}", .page = "dashboard.html#x" },
        .{ .manifest = "{\"options_page\":\"\",\"action\":{\"default_popup\":\"popup/index.html\"}}", .page = "popup/index.html" },
        .{ .manifest = "{\"browser_action\":{\"default_popup\":\"//p.html\"}}", .page = "p.html" },
        .{ .manifest = "{\"name\":\"no pages\",\"options_page\":7}", .page = null },
        .{ .manifest = "not json", .page = null },
    };
    for (cases) |case| {
        try core.writeFile(try std.fs.path.join(a, &.{ dir, "manifest.json" }), case.manifest);
        const got = optionsPage(a, dir);
        if (case.page) |want| try std.testing.expectEqualStrings(want, got.?) else try std.testing.expect(got == null);
    }
    try std.testing.expect(optionsPage(a, try std.fs.path.join(a, &.{ dir, "missing" })) == null);

    // a package whose manifest is not at the root is refused, and nothing is left behind
    const zip = try std.fs.path.join(a, &.{ dir, "x.zip" });
    const part = try std.fs.path.join(a, &.{ dir, "x.part" });
    try core.writeFile(zip, adblock.test_zip);
    try std.testing.expectEqualStrings("no manifest.json", (try unpack(a, zip, part)).?);
    try std.testing.expect(!core.exists(zip));
    try std.testing.expect(!core.exists(part));
    // so is something that is not a zip at all
    try core.writeFile(zip, "<html>");
    try std.testing.expect((try unpack(a, zip, part)) != null);
    try std.testing.expect(!core.exists(zip));
}

test "ExtInfo JSON" {
    const a = std.testing.allocator;
    const with = try core.toJson(a, ExtInfo{ .id = "abc", .name = "N", .enabled = true, .builtin = false, .options = "chrome-extension://abc/o.html" });
    defer a.free(with);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"name\":\"N\",\"enabled\":true,\"builtin\":false,\"options\":\"chrome-extension://abc/o.html\"}", with);
    const without = try core.toJson(a, ExtInfo{ .id = "abc", .name = "N", .enabled = false, .builtin = true });
    defer a.free(without);
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"name\":\"N\",\"enabled\":false,\"builtin\":true}", without);
}

test "isInside" {
    try std.testing.expect(isInside("C:\\data\\extensions\\abc", "C:\\data\\extensions"));
    try std.testing.expect(isInside("C:\\data\\extensions", "C:\\data\\extensions"));
    try std.testing.expect(!isInside("C:\\data\\extensions2\\abc", "C:\\data\\extensions"));
    try std.testing.expect(!isInside("D:\\my\\ext", "C:\\data\\extensions"));
}
