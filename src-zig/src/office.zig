//! Office tab → GenOffice (github.com/genspark-ai/genoffice, Apache-2.0): Word, Excel, PowerPoint and
//! PDF files open in the GenOffice app, a separate program. This side:
//!   - finds GenOffice on the machine, and on Windows downloads and installs it (its own installer,
//!     silent, per-user) when the user asks;
//!   - opens files in it, with the file dialog, and keeps the "recent files" list;
//!   - tells Claude how to start GenOffice's own MCP server (`genoffice mcp`, see `mcpLaunch`), whose
//!     tools read and edit the .docx / .xlsx / .pptx / .pdf files themselves.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const http = @import("http.zig");
const settings = @import("settings.zig");
const dialog = @import("dialog.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const tr = settings.tr;

pub const commands = .{
    .{ "office_pick", office_pick },
    .{ "office_recent", office_recent },
    .{ "office_recent_add", office_recent_add },
    .{ "office_status", office_status },
    .{ "office_install", office_install },
    .{ "office_open", office_open },
};

/// The ONLYOFFICE editor the Office tab used to download (several hundred MB) is not used any more.
pub fn init() void {
    core.spawn(dropOnlyOffice, .{});
}

fn dropOnlyOffice() void {
    const dir = core.dataPath(core.gpa, &.{"onlyoffice"}) catch return;
    defer core.gpa.free(dir);
    Dir.cwd().deleteTree(core.io, dir) catch {};
}

// ---------------- GenOffice on this machine ----------------

pub const Install = struct {
    /// the program: GenOffice.exe, or GenOffice.app on macOS
    app: []const u8,
    /// its command line's folder (resources\cli): genoffice.cjs / genoffice
    cli: []const u8,
};

fn found(a: Allocator, app: []const u8, cli: []const u8) ?Install {
    const ok = if (core.is_windows)
        core.isFile(app) and core.isFile(std.fs.path.join(a, &.{ cli, "genoffice.cjs" }) catch return null)
    else
        core.isDir(app) and core.isFile(std.fs.path.join(a, &.{ cli, "genoffice" }) catch return null);
    return if (ok) .{ .app = app, .cli = cli } else null;
}

/// GenOffice where it is installed: the folder the app last wrote to ~/.genoffice/launcher, else
/// the installer's default places.
pub fn find(a: Allocator) ?Install {
    const launcher = std.fs.path.join(a, &.{ core.home(), ".genoffice", "launcher" }) catch return null;
    if (core.readFileAlloc(a, launcher, 64 << 10)) |text| {
        const p = std.mem.trim(u8, text, " \t\r\n\"");
        const cli = if (core.isDir(p)) p else std.fs.path.dirname(p) orelse p;
        // <app>\resources\cli (Windows), GenOffice.app/Contents/Resources/cli (macOS)
        const app = if (core.is_windows)
            std.fs.path.resolve(a, &.{ cli, "..", "..", "GenOffice.exe" }) catch return null
        else
            std.fs.path.resolve(a, &.{ cli, "..", "..", ".." }) catch return null;
        if (found(a, app, cli)) |i| return i;
    } else |_| {}
    if (core.is_windows) {
        const roots = [_]?[]const u8{
            if (core.getenv("LOCALAPPDATA")) |l| std.fs.path.join(a, &.{ l, "Programs" }) catch null else null,
            core.getenv("ProgramFiles"),
        };
        for (roots) |r| {
            const dir = std.fs.path.join(a, &.{ r orelse continue, "GenOffice" }) catch continue;
            const app = std.fs.path.join(a, &.{ dir, "GenOffice.exe" }) catch continue;
            const cli = std.fs.path.join(a, &.{ dir, "resources", "cli" }) catch continue;
            if (found(a, app, cli)) |i| return i;
        }
    } else if (core.is_mac) {
        const apps = [_][]const u8{ "/Applications/GenOffice.app", std.fs.path.join(a, &.{ core.home(), "Applications", "GenOffice.app" }) catch "" };
        for (apps) |app| {
            const cli = std.fs.path.join(a, &.{ app, "Contents", "Resources", "cli" }) catch continue;
            if (found(a, app, cli)) |i| return i;
        }
    }
    return null;
}

pub const Launch = struct {
    command: []const u8,
    args: []const []const u8,
    /// ELECTRON_RUN_AS_NODE on Windows; empty elsewhere
    env_name: []const u8 = "",
    env_value: []const u8 = "",
};

/// How Claude starts GenOffice's MCP server (stdio), as `genoffice mcp install` writes it: on
/// Windows GenOffice.exe runs the bundled CLI as Node (MCP clients spawn without a shell, so
/// genoffice.cmd is not an option). Null while GenOffice is not installed.
pub fn mcpLaunch(a: Allocator) ?Launch {
    const i = find(a) orelse return null;
    if (core.is_windows) return .{
        .command = i.app,
        .args = a.dupe([]const u8, &.{ std.fs.path.join(a, &.{ i.cli, "genoffice.cjs" }) catch return null, "mcp" }) catch return null,
        .env_name = "ELECTRON_RUN_AS_NODE",
        .env_value = "1",
    };
    return .{ .command = std.fs.path.join(a, &.{ i.cli, "genoffice" }) catch return null, .args = a.dupe([]const u8, &.{"mcp"}) catch return null };
}

pub const Status = struct {
    installed: bool,
    /// where it is (GenOffice.exe / GenOffice.app)
    app: ?[]const u8 = null,
    /// this platform gets it installed from here (else: the download page)
    can_install: bool,
    /// an install is running
    installing: bool,
};

var install_running: std.atomic.Value(bool) = .init(false);

fn status(a: Allocator) Status {
    const i = find(a);
    return .{ .installed = i != null, .app = if (i) |x| x.app else null, .can_install = core.is_windows, .installing = install_running.load(.acquire) };
}

fn office_status(c: *ipc.Call) !Status {
    return status(c.arena);
}

const Release = struct {
    tag_name: ?[]const u8 = null,
    assets: []const struct { name: []const u8 = "", browser_download_url: ?[]const u8 = null, size: u64 = 0 } = &.{},
};

const Progress = struct {
    total: u64,
    last: u64 = 0,
    fn tell(ctx: ?*anyopaque, done: u64, total: ?u64) void {
        const p: *Progress = @ptrCast(@alignCast(ctx.?));
        const all = total orelse p.total;
        // every half percent is plenty
        if (done != all and done - p.last < all / 200) return;
        p.last = done;
        core.emit("office:install", .{ .phase = "download", .done = done, .total = all });
    }
};

/// Downloads GenOffice's newest Windows installer from its GitHub releases and runs it silently
/// (a per-user install, no administrator rights); `office:install` events report the progress.
fn office_install(c: *ipc.Call) !Status {
    const a = c.arena;
    if (!core.is_windows) return c.failMsg(tr("Install GenOffice from github.com/genspark-ai/genoffice/releases.", "Cài GenOffice từ github.com/genspark-ai/genoffice/releases."));
    if (find(a) != null) return status(a);
    if (install_running.swap(true, .acq_rel)) return c.failMsg(tr("GenOffice is already being installed.", "GenOffice đang được cài."));
    defer install_running.store(false, .release);

    const res = http.get(a, "https://api.github.com/repos/genspark-ai/genoffice/releases/latest", &.{.{ .name = "Accept", .value = "application/vnd.github+json" }}) catch |e|
        return c.fail("github.com: {s}", .{@errorName(e)});
    if (!res.ok()) return c.fail("github.com: HTTP {d}", .{res.status});
    const rel = core.fromJson(Release, a, res.body) catch Release{};
    const suffix = if (builtin.cpu.arch == .aarch64) "-arm64.exe" else "-x64.exe";
    const asset = for (rel.assets) |x| {
        if (std.mem.startsWith(u8, x.name, "GenOfficeSetup") and std.mem.endsWith(u8, x.name, suffix) and x.browser_download_url != null) break x;
    } else return c.fail("{s} {s}", .{ tr("No Windows installer in GenOffice's latest release", "Bản phát hành mới nhất của GenOffice không có bộ cài Windows"), rel.tag_name orelse "" });

    const file = try std.fs.path.join(a, &.{ core.tempDir(), asset.name });
    defer Dir.cwd().deleteFile(core.io, file) catch {};
    var progress: Progress = .{ .total = asset.size };
    const head = http.download(a, asset.browser_download_url.?, .{}, file, Progress.tell, &progress) catch |e|
        return c.fail("{s} {s}", .{ tr("Download failed:", "Tải về thất bại:"), @errorName(e) });
    if (head.status < 200 or head.status >= 300) return c.fail("{s} HTTP {d}", .{ tr("Download failed:", "Tải về thất bại:"), head.status });

    core.emit("office:install", .{ .phase = "install", .done = asset.size, .total = asset.size });
    // NSIS: /S = silent
    var child = std.process.spawn(core.io, .{ .argv = &.{ file, "/S" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |e|
        return c.fail("{s} {s}", .{ tr("Could not start the installer:", "Không chạy được bộ cài:"), @errorName(e) });
    const term = child.wait(core.io) catch |e| return c.fail("{s} {s}", .{ tr("The installer failed:", "Bộ cài bị lỗi:"), @errorName(e) });
    if (term != .exited or term.exited != 0) return c.failMsg(tr("The GenOffice installer did not finish.", "Bộ cài GenOffice chưa cài xong."));
    if (find(a) == null) return c.failMsg(tr("GenOffice was installed, but VIBE CODE cannot find it.", "Đã cài GenOffice nhưng VIBE CODE không tìm thấy nó."));
    core.emit("office:install", .{ .phase = "done", .done = asset.size, .total = asset.size });
    return status(a);
}

/// Opens `path` in GenOffice (and puts it on top of the recent list); no path: GenOffice's home.
fn office_open(c: *ipc.Call, args: struct { path: ?[]const u8 = null }) !void {
    const a = c.arena;
    const i = find(a) orelse return c.failMsg(tr("GenOffice is not installed.", "Chưa cài GenOffice."));
    const path = args.path;
    if (path) |p| if (!core.isFile(p)) return c.fail("{s} {s}", .{ tr("No file at", "Không có tệp ở"), p });
    const argv: []const []const u8 = if (core.is_windows)
        (if (path) |p| &.{ i.app, p } else &.{i.app})
    else
        (if (path) |p| &.{ "open", "-a", i.app, p } else &.{ "open", "-a", i.app });
    _ = std.process.spawn(core.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |e|
        return c.fail("{s} {s}", .{ tr("Could not start GenOffice:", "Không mở được GenOffice:"), @errorName(e) });
    if (path) |p| try addRecent(a, p, false);
}

// ---------------- files ----------------

/// What the Office tab opens.
const EXTS = [_][]const u8{ "docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "csv", "pptx", "ppt", "odp", "pdf", "md", "html" };

/// File dialog: pick a file to open in GenOffice.
fn office_pick(c: *ipc.Call) !?[]u8 {
    const filter: dialog.Filter = .{ .name = tr("Documents, spreadsheets, presentations, PDF", "Tài liệu, bảng tính, trình chiếu, PDF"), .extensions = &EXTS };
    return dialog.pickFile(c.arena, .{ .filters = &.{filter} });
}

// ---------------- recent files ----------------

const RECENT_MAX = 50;

pub const RecentFile = struct {
    path: []const u8,
    /// bytes; 0 when the file is gone
    size: u64,
    /// ms since epoch, 0 when unknown
    modified: u64,
    exists: bool,
};

fn recentFile(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"office-recent.json"});
}

fn recentPaths(a: Allocator) []const []const u8 {
    const file = recentFile(a) catch return &.{};
    const text = core.readFileAlloc(a, file, 16 << 20) catch return &.{};
    return core.fromJson([]const []const u8, a, text) catch &.{};
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const p: u8 = if (x == '/') '\\' else std.ascii.toLower(x);
        const q: u8 = if (y == '/') '\\' else std.ascii.toLower(y);
        if (p != q) return false;
    }
    return true;
}

/// `list` without `path`.
fn without(a: Allocator, list: []const []const u8, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |p| {
        if (!samePath(p, path)) try out.append(a, p);
    }
    return out.items;
}

/// Moves `path` to the top of `list` (adding it), keeping at most RECENT_MAX.
fn bump(a: Allocator, list: []const []const u8, path: []const u8) ![]const []const u8 {
    const rest = try without(a, list, path);
    const out = try a.alloc([]const u8, @min(rest.len + 1, RECENT_MAX));
    out[0] = path;
    @memcpy(out[1..], rest[0 .. out.len - 1]);
    return out;
}

fn info(path: []const u8) RecentFile {
    const st = Dir.cwd().statFile(core.io, path, .{}) catch return .{ .path = path, .size = 0, .modified = 0, .exists = false };
    return .{ .path = path, .size = st.size, .modified = @intCast(@max(0, st.mtime.toMilliseconds())), .exists = true };
}

/// Files opened from the Office tab, most recent first, with their size and last change on disk.
fn office_recent(c: *ipc.Call) ![]RecentFile {
    const paths = recentPaths(c.arena);
    const out = try c.arena.alloc(RecentFile, paths.len);
    for (paths, out) |p, *o| o.* = info(p);
    return out;
}

fn addRecent(a: Allocator, path: []const u8, remove: bool) !void {
    const cur = recentPaths(a);
    const list = if (remove) try without(a, cur, path) else try bump(a, cur, path);
    try core.writeFile(try recentFile(a), try core.toJson(a, list));
}

/// `remove`: take it off the list; otherwise put it on top.
fn office_recent_add(c: *ipc.Call, a: struct { path: []const u8, remove: ?bool = null }) !void {
    try addRecent(c.arena, a.path, a.remove orelse false);
}

// ---------------- tests ----------------

const testing = std.testing;

test "recent list moves a file to the top once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try bump(a, &.{ "C:\\a.xlsx", "C:\\b.docx" }, "c:/B.docx");
    try testing.expectEqual(2, l.len);
    try testing.expectEqualStrings("c:/B.docx", l[0]);
    try testing.expectEqualStrings("C:\\a.xlsx", l[1]);
    var many: []const []const u8 = &.{};
    for (0..60) |i| many = try bump(a, many, try std.fmt.allocPrint(a, "C:\\f{d}.pdf", .{i}));
    try testing.expectEqual(RECENT_MAX, many.len);
    try testing.expectEqualStrings("C:\\f59.pdf", many[0]);
    try testing.expectEqual(1, (try without(a, l, "C:/A.XLSX")).len);
}

test "an install is found from its folders" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const app = try std.fs.path.join(a, &.{ dir, "GenOffice.exe" });
    const cli = try std.fs.path.join(a, &.{ dir, "resources", "cli" });
    try testing.expect(found(a, app, cli) == null);
    try core.makePath(cli);
    try core.writeFile(app, "");
    try core.writeFile(try std.fs.path.join(a, &.{ cli, if (core.is_windows) "genoffice.cjs" else "genoffice" }), "");
    if (core.is_windows) try testing.expectEqualStrings(app, found(a, app, cli).?.app);
}

test "GenOffice installed on this machine (GENOFFICE_TEST=1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = testing.environ.getAlloc(a, "GENOFFICE_TEST") catch return error.SkipZigTest;
    core.gpa = std.heap.smp_allocator;
    core.io = testing.io;
    var env = try testing.environ.createMap(a);
    const saved = core.env;
    core.env = &env;
    defer core.env = saved;
    const i = find(a) orelse return error.TestUnexpectedResult;
    std.debug.print("GenOffice: {s} | cli {s}\n", .{ i.app, i.cli });
    const l = mcpLaunch(a).?;
    std.debug.print("mcp: {s} {s} {s} ({s}={s})\n", .{ l.command, l.args[0], l.args[1], l.env_name, l.env_value });
    try testing.expect(std.mem.endsWith(u8, l.args[0], "genoffice.cjs"));
}
