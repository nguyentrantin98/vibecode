//! VS Code extensions for the code editor (Monaco), added by the user from Open VSX (a .vsix link)
//! or from a .vsix file, unpacked into `editor-extensions/<publisher.name>`. There is no extension
//! host to run their code: the page only uses what package.json declares (color themes, syntax
//! grammars, language settings, snippets) and reads those files itself.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const adblock = @import("adblock.zig");
const J = @import("browser_json.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const tr = settings.tr;

pub const commands = .{
    .{ "editor_ext_list", editor_ext_list },
    .{ "editor_ext_install", editor_ext_install },
    .{ "editor_ext_remove", editor_ext_remove },
};

pub const EditorExt = struct {
    /// "publisher.name", lower-case: also its folder's name
    id: []const u8,
    /// the folder holding package.json; the paths in it are relative to this
    dir: []const u8,
    /// package.json as it is
    manifest: []const u8,
};

fn root(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"editor-extensions"});
}

/// The extension unpacked in `dir` (a .vsix keeps it under `extension/`).
fn load(a: Allocator, id: []const u8, dir: []const u8) ?EditorExt {
    const ext = std.fs.path.join(a, &.{ dir, "extension" }) catch return null;
    const pkg = std.fs.path.join(a, &.{ ext, "package.json" }) catch return null;
    const manifest = core.readFileAlloc(a, pkg, 4 << 20) catch return null;
    return .{ .id = id, .dir = ext, .manifest = manifest };
}

/// A folder name we made: letters, digits, '-', '_' and '.', and not "." or "..".
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 200 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    return true;
}

fn editor_ext_list(c: *ipc.Call) ![]EditorExt {
    const a = c.arena;
    const r = try root(a);
    var list: std.ArrayList(EditorExt) = .empty;
    var d = Dir.cwd().openDir(core.io, r, .{ .iterate = true }) catch return list.items;
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| {
        if (e.kind != .directory or !validId(e.name)) continue;
        const id = try a.dupe(u8, e.name);
        if (load(a, id, try std.fs.path.join(a, &.{ r, id }))) |x| try list.append(a, x);
    }
    return list.items;
}

/// Installs a .vsix from an https link (Open VSX's download link) or a file on this computer;
/// one already installed under the same id is replaced (an update).
fn editor_ext_install(c: *ipc.Call, args: struct { source: []const u8 }) !EditorExt {
    const a = c.arena;
    const source = std.mem.trim(u8, args.source, " \t\r\n\"");
    const r = try root(a);
    try core.makePath(r);
    const stamp = core.nowMs();
    const part = try std.fmt.allocPrint(a, "{s}{c}{d}.part", .{ r, std.fs.path.sep, stamp });
    defer Dir.cwd().deleteTree(core.io, part) catch {};

    if (std.mem.startsWith(u8, source, "https://")) {
        const file = try std.fmt.allocPrint(a, "{s}{c}{d}.vsix", .{ r, std.fs.path.sep, stamp });
        defer Dir.cwd().deleteFile(core.io, file) catch {};
        const head = http.download(a, source, .{}, file, null, null) catch |e|
            return c.fail("{s} {s}", .{ tr("Download failed:", "Tải về thất bại:"), @errorName(e) });
        if (head.status < 200 or head.status >= 300) return c.fail("{s} HTTP {d}", .{ tr("Download failed:", "Tải về thất bại:"), head.status });
        adblock.unzip(file, part) catch |e| return c.fail("{s} {s}", .{ tr("Not a .vsix file:", "Không phải tệp .vsix:"), @errorName(e) });
    } else if (std.ascii.endsWithIgnoreCase(source, ".vsix") and core.isFile(source)) {
        adblock.unzip(source, part) catch |e| return c.fail("{s} {s}", .{ tr("Not a .vsix file:", "Không phải tệp .vsix:"), @errorName(e) });
    } else {
        return c.failMsg(tr("Pick a .vsix file, or an extension from Open VSX.", "Chọn một tệp .vsix, hoặc một extension từ Open VSX."));
    }

    // its id is publisher.name from package.json
    const pkg_path = try std.fs.path.join(a, &.{ part, "extension", "package.json" });
    const pkg = J.parse(a, core.readFileAlloc(a, pkg_path, 4 << 20) catch "") orelse
        return c.failMsg(tr("This .vsix has no extension/package.json.", "Tệp .vsix này không có extension/package.json."));
    const publisher = J.str(J.get(pkg, "publisher")) orelse "unknown";
    const name = J.str(J.get(pkg, "name")) orelse return c.failMsg(tr("package.json has no name.", "package.json không có name."));
    const id = try std.ascii.allocLowerString(a, try std.fmt.allocPrint(a, "{s}.{s}", .{ publisher, name }));
    if (!validId(id)) return c.fail("{s} {s}", .{ tr("Unusual extension id:", "Id extension lạ:"), id });

    const done = try std.fs.path.join(a, &.{ r, id });
    Dir.cwd().deleteTree(core.io, done) catch {};
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), done, core.io);
    return load(a, id, done) orelse c.failMsg(tr("Could not read the installed extension.", "Không đọc được extension vừa cài."));
}

fn editor_ext_remove(c: *ipc.Call, args: struct { id: []const u8 }) !void {
    const a = c.arena;
    if (!validId(args.id)) return c.failMsg("bad id");
    Dir.cwd().deleteTree(core.io, try std.fs.path.join(a, &.{ try root(a), args.id })) catch |e|
        return c.fail("{s}", .{@errorName(e)});
}

test "ids" {
    try std.testing.expect(validId("dracula-theme.theme-dracula"));
    try std.testing.expect(!validId(".."));
    try std.testing.expect(!validId("a/b"));
    try std.testing.expect(!validId("a\\b"));
    try std.testing.expect(!validId(""));
}

var test_env: ?std.process.Environ.Map = null;

test "install from a .vsix file, list, remove" {
    // runs when EDEXT_TEST_VSIX names a .vsix of the Dracula theme (open-vsx.org/extension/dracula-theme/theme-dracula)
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const vsix = std.testing.environ.getAlloc(arena.allocator(), "EDEXT_TEST_VSIX") catch return error.SkipZigTest;
    // a data folder of the tests' own (or the one another module's test fixed first), never the real one
    core.gpa = std.heap.smp_allocator;
    core.io = std.testing.io;
    if (test_env == null) {
        const rel = ".zig-cache/tmp/editorext-test";
        try Dir.cwd().createDirPath(core.io, rel);
        var d = try Dir.cwd().openDir(core.io, rel, .{});
        defer d.close(core.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try d.realPath(core.io, &buf);
        var env: std.process.Environ.Map = .init(core.gpa);
        try env.put("STUDIO_USER_DATA", buf[0..n]);
        test_env = env;
    }
    core.env = &test_env.?;
    if (std.mem.indexOf(u8, core.userData(), ".zig-cache") == null) return error.SkipZigTest;
    var c: ipc.Call = .{ .arena = arena.allocator(), .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    const x = try editor_ext_install(&c, .{ .source = vsix });
    try std.testing.expectEqualStrings("dracula-theme.theme-dracula", x.id);
    try std.testing.expect(std.mem.indexOf(u8, x.manifest, "\"themes\"") != null);
    const list = try editor_ext_list(&c);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(core.isFile(try std.fs.path.join(arena.allocator(), &.{ x.dir, "theme", "dracula.json" })));
    try editor_ext_remove(&c, .{ .id = x.id });
    try std.testing.expectEqual(@as(usize, 0), (try editor_ext_list(&c)).len);
    try std.testing.expectError(error.Failed, editor_ext_remove(&c, .{ .id = ".." }));
}
