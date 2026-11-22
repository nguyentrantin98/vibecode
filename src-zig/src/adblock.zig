//! Ad blocking for the Web tabs: uBlock Origin Lite (github.com/uBlockOrigin/uBOL-home), loaded into WebView2 as a
//! browser extension. Its newest release is downloaded on first launch and again whenever a newer
//! one is out; browser.zig adds it to the Web tabs' profile and turns it on / off with the setting.

const std = @import("std");
const core = @import("core.zig");
const http = @import("http.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

const REPO = "uBlockOrigin/uBOL-home";
/// Extension name in its manifest: how it is found again among the profile's extensions.
pub const NAME = "uBlock Origin Lite";
/// What earlier versions loaded (the full uBlock Origin): taken out of the profile.
pub const OLD_NAME = "uBlock Origin";

fn root(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"ubol"});
}

pub const Installed = struct {
    tag: []const u8,
    /// the unpacked extension folder
    dir: []const u8,
};

/// The release now on disk (allocated in `a`).
pub fn installed(a: Allocator) ?Installed {
    return installedIn(a, root(a) catch return null);
}

fn installedIn(a: Allocator, root_dir: []const u8) ?Installed {
    var dir = Dir.cwd().openDir(core.io, root_dir, .{ .iterate = true }) catch return null;
    defer dir.close(core.io);
    var it = dir.iterate();
    while (it.next(core.io) catch null) |e| {
        if (e.kind != .directory or std.mem.endsWith(u8, e.name, ".part")) continue;
        const path = std.fs.path.join(a, &.{ root_dir, e.name }) catch return null;
        if (manifestDir(a, path)) |ext| return .{ .tag = a.dupe(u8, e.name) catch return null, .dir = ext };
    }
    return null;
}

fn hasManifest(a: Allocator, dir: []const u8) bool {
    const p = std.fs.path.join(a, &.{ dir, "manifest.json" }) catch return false;
    defer a.free(p);
    return core.isFile(p);
}

/// The folder holding manifest.json: the archive's root or its only subfolder.
pub fn manifestDir(a: Allocator, dir: []const u8) ?[]const u8 {
    if (hasManifest(a, dir)) return a.dupe(u8, dir) catch null;
    var d = Dir.cwd().openDir(core.io, dir, .{ .iterate = true }) catch return null;
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        const sub = std.fs.path.join(a, &.{ dir, e.name }) catch return null;
        if (hasManifest(a, sub)) return sub;
        a.free(sub);
    }
    return null;
}

/// Unpacks a zip file into the folder `dest` (made here; it must not hold these files yet).
pub fn unzip(zip_path: []const u8, dest: []const u8) !void {
    var file = try Dir.cwd().openFile(core.io, zip_path, .{});
    defer file.close(core.io);
    var out = try Dir.cwd().createDirPathOpen(core.io, dest, .{});
    defer out.close(core.io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(core.io, &buf);
    try std.zip.extract(out, &fr, .{ .allow_backslashes = true });
}

const Release = struct {
    tag_name: ?[]const u8 = null,
    assets: []const struct { name: []const u8 = "", browser_download_url: ?[]const u8 = null } = &.{},
};

/// Downloads the newest release unless it is already on disk; true when a new one was installed.
pub fn update(a: Allocator, fail: *core.Fail) !bool {
    const res = http.get(a, "https://api.github.com/repos/" ++ REPO ++ "/releases/latest", &.{}) catch |e|
        return fail.set(a, "github.com: {s}", .{@errorName(e)});
    if (!res.ok()) return fail.set(a, "github.com answered {d}", .{res.status});
    const rel = core.fromJson(Release, a, res.body) catch Release{};
    const tag = rel.tag_name orelse return fail.set(a, "release without a tag", .{});
    if (installed(a)) |cur| if (std.mem.eql(u8, cur.tag, tag)) return false;
    const asset_url: ?[]const u8 = for (rel.assets) |asset| {
        if (std.mem.endsWith(u8, asset.name, ".chromium.zip")) break asset.browser_download_url;
    } else null;
    const url = asset_url orelse return fail.set(a, "no Chromium build in the release", .{});

    const dir = try root(a);
    try core.makePath(dir);
    const file = try std.fmt.allocPrint(a, "{s}{c}{s}.zip", .{ dir, std.fs.path.sep, tag });
    const part = try std.fmt.allocPrint(a, "{s}{c}{s}.part", .{ dir, std.fs.path.sep, tag });
    const done = try std.fs.path.join(a, &.{ dir, tag });
    const head = http.download(a, url, .{}, file, null, null) catch |e|
        return fail.set(a, "download: {s}", .{@errorName(e)});
    if (head.status < 200 or head.status >= 300) return fail.set(a, "the download answered {d}", .{head.status});

    Dir.cwd().deleteTree(core.io, part) catch {};
    const unpacked = unzip(file, part);
    Dir.cwd().deleteFile(core.io, file) catch {};
    const why: ?[]const u8 = if (unpacked) |_| (if (manifestDir(a, part) == null) "no manifest.json in it" else null) else |e| @errorName(e);
    if (why) |w| {
        Dir.cwd().deleteTree(core.io, part) catch {};
        return fail.set(a, "could not unpack {s} {s}: {s}", .{ NAME, tag, w });
    }
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), done, core.io);
    // older releases: the profile may still have one loaded until the next launch, so a failed
    // delete is retried then
    removeOthers(a, dir, tag);
    // the full uBlock Origin earlier versions downloaded
    if (core.dataPath(a, &.{"ublock"})) |old| Dir.cwd().deleteTree(core.io, old) catch {} else |_| {}
    return true;
}

/// Deletes every folder of `root_dir` but `keep`.
fn removeOthers(a: Allocator, root_dir: []const u8, keep: []const u8) void {
    var d = Dir.cwd().openDir(core.io, root_dir, .{ .iterate = true }) catch return;
    defer d.close(core.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        if (e.kind == .directory and !std.mem.eql(u8, e.name, keep)) names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    for (names.items) |n| d.deleteTree(core.io, n) catch {};
}

/// Tag of the release last added to the Web tabs' profile (a newer one replaces it).
pub fn loadedTag(a: Allocator) ?[]const u8 {
    const path = core.dataPath(a, &.{ "ubol", "loaded.txt" }) catch return null;
    const s = core.readFileAlloc(a, path, 4096) catch return null;
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn setLoadedTag(tag: []const u8) void {
    const path = core.dataPath(core.gpa, &.{ "ubol", "loaded.txt" }) catch return;
    defer core.gpa.free(path);
    core.writeFile(path, tag) catch {};
}

// "uBOLite/manifest.json" (deflated) and "uBOLite/_metadata/x.txt" (stored)
pub const test_zip = "\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x00\x00\x21\x5c\xbb\x3c\xe1\xb8\x44\x00\x00\x00\x46\x00" ++
    "\x00\x00\x15\x00\x00\x00\x75\x42\x4f\x4c\x69\x74\x65\x2f\x6d\x61\x6e\x69\x66\x65\x73\x74\x2e\x6a" ++
    "\x73\x6f\x6e\xab\x56\xca\x4b\xcc\x4d\x55\xb2\x52\x2a\x75\xca\xc9\x4f\xce\x56\xf0\x2f\xca\x4c\xcf" ++
    "\xcc\x53\xf0\xc9\x2c\x49\x55\xd2\x51\x4a\x4c\x2e\xc9\xcc\xcf\x53\xb2\xaa\x56\x4a\x49\x4d\x4b\x2c" ++
    "\xcd\x29\x89\x2f\xc8\x2f\x28\x2d\x50\xb2\x52\xd2\x07\x33\xf4\x32\x4a\x72\x73\x94\x6a\x6b\x01\x50" ++
    "\x4b\x03\x04\x14\x00\x00\x00\x00\x00\x00\x00\x21\x5c\x0e\x2b\x1f\xce\x03\x00\x00\x00\x03\x00\x00" ++
    "\x00\x17\x00\x00\x00\x75\x42\x4f\x4c\x69\x74\x65\x2f\x5f\x6d\x65\x74\x61\x64\x61\x74\x61\x2f\x78" ++
    "\x2e\x74\x78\x74\x73\x69\x67\x50\x4b\x01\x02\x14\x00\x14\x00\x00\x00\x08\x00\x00\x00\x21\x5c\xbb" ++
    "\x3c\xe1\xb8\x44\x00\x00\x00\x46\x00\x00\x00\x15\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80" ++
    "\x01\x00\x00\x00\x00\x75\x42\x4f\x4c\x69\x74\x65\x2f\x6d\x61\x6e\x69\x66\x65\x73\x74\x2e\x6a\x73" ++
    "\x6f\x6e\x50\x4b\x01\x02\x14\x00\x14\x00\x00\x00\x00\x00\x00\x00\x21\x5c\x0e\x2b\x1f\xce\x03\x00" ++
    "\x00\x00\x03\x00\x00\x00\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x77\x00\x00\x00" ++
    "\x75\x42\x4f\x4c\x69\x74\x65\x2f\x5f\x6d\x65\x74\x61\x64\x61\x74\x61\x2f\x78\x2e\x74\x78\x74\x50" ++
    "\x4b\x05\x06\x00\x00\x00\x00\x02\x00\x02\x00\x88\x00\x00\x00\xaf\x00\x00\x00\x00\x00";

/// A scratch folder for a test: its absolute path, allocated in `a`.
pub fn testDir(a: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    core.gpa = std.testing.allocator;
    core.io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return a.dupe(u8, buf[0..n]);
}

test "a release is unpacked and found again" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testDir(a, &tmp);

    try std.testing.expect(installedIn(a, dir) == null);
    const zip = try std.fs.path.join(a, &.{ dir, "1.2.3.zip" });
    try core.writeFile(zip, test_zip);
    // a download that was cut short is not a release
    const part = try std.fs.path.join(a, &.{ dir, "1.2.3.part" });
    try unzip(zip, part);
    try std.testing.expect(installedIn(a, dir) == null);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ part, "uBOLite" }), manifestDir(a, part).?);

    const done = try std.fs.path.join(a, &.{ dir, "1.2.3" });
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), done, core.io);
    const got = installedIn(a, dir).?;
    try std.testing.expectEqualStrings("1.2.3", got.tag);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ done, "uBOLite" }), got.dir);
    const manifest = try core.readFileAlloc(a, try std.fs.path.join(a, &.{ got.dir, "manifest.json" }), 4096);
    try std.testing.expect(std.mem.startsWith(u8, manifest, "{\"name\":\"uBlock Origin Lite\""));
    // the manifest may also sit at the archive's root
    try std.testing.expectEqualStrings(got.dir, manifestDir(a, got.dir).?);

    try core.makePath(try std.fs.path.join(a, &.{ dir, "1.0.0", "old" }));
    removeOthers(a, dir, "1.2.3");
    try std.testing.expect(!core.exists(try std.fs.path.join(a, &.{ dir, "1.0.0" })));
    try std.testing.expect(core.isDir(done));
    try std.testing.expect(core.isFile(zip));
}

test "a file that is not a zip is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try testDir(a, &tmp);
    const zip = try std.fs.path.join(a, &.{ dir, "bad.zip" });
    try core.writeFile(zip, "<html>not a zip</html>");
    try std.testing.expect(std.meta.isError(unzip(zip, try std.fs.path.join(a, &.{ dir, "out" }))));
}
