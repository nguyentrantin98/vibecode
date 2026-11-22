//! What the app adds to the user's Claude Code so chats start well equipped: the bundled
//! karpathy-guidelines skill and a few plugins from the official marketplace. Each is added once
//! and only when missing — a skill the user edited or a plugin they removed stays that way.

const std = @import("std");
const core = @import("core.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;

const marketplace = "claude-plugins-official";

/// Plugin, and the language server it needs on PATH (it is skipped until that is installed).
const Plugin = struct { name: []const u8, needs: ?[]const u8 = null };
const plugins = [_]Plugin{
    .{ .name = "context7" },
    .{ .name = "feature-dev" },
    .{ .name = "typescript-lsp", .needs = "typescript-language-server" },
    .{ .name = "csharp-lsp", .needs = "csharp-ls" },
    .{ .name = "php-lsp", .needs = "intelephense" },
};

pub fn init() void {
    installSkill(core.home());
    core.spawn(installPlugins, .{});
}

fn installSkill(home: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ home, skill_file }) catch return;
    if (core.exists(file)) return;
    core.writeFile(file, @embedFile("karpathy_guidelines.md")) catch {};
}

const skill_file = ".claude" ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "karpathy-guidelines" ++ std.fs.path.sep_str ++ "SKILL.md";

/// The plugins still to install: not in `done` (one name per line) and with what they need on PATH.
fn pending(a: Allocator, done: []const u8) ![]const []const u8 {
    var todo: std.ArrayList([]const u8) = .empty;
    for (plugins) |p| {
        var lines = std.mem.tokenizeAny(u8, done, "\r\n");
        const installed = while (lines.next()) |l| {
            if (std.mem.eql(u8, l, p.name)) break true;
        } else false;
        if (installed) continue;
        if (p.needs) |bin| if (core.which(a, bin) == null) continue;
        try todo.append(a, p.name);
    }
    return todo.items;
}

fn installPlugins() void {
    tryInstallPlugins() catch |e| std.log.warn("plugins not installed: {s}", .{@errorName(e)});
}

fn tryInstallPlugins() !void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // the plugins this app already installed, one per line: never installed a second time
    const done_file = try core.dataPath(a, &.{"plugins-installed.txt"});
    var done: std.ArrayList(u8) = .empty;
    if (core.readFileAlloc(a, done_file, 1 << 20)) |text| try done.appendSlice(a, text) else |_| {}
    const todo = try pending(a, done.items);
    if (todo.len == 0) return;
    if (!@hasDecl(m.pty, "claudePath")) return;
    var claude: []const u8 = m.pty.claudePath(a) orelse return;
    // npm's extensionless sh shim: Windows needs the .cmd next to it
    if (core.is_windows and std.fs.path.extension(claude).len == 0) {
        const cmd = try std.mem.concat(a, u8, &.{ claude, ".cmd" });
        if (core.exists(cmd)) claude = cmd;
    }
    for (todo) |name| {
        const plugin = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, marketplace });
        const out = core.run(a, &.{ claude, "plugin", "install", plugin }, .{}) catch continue;
        if (out.ok()) {
            try done.print(a, "{s}\n", .{name});
            core.writeFile(done_file, done.items) catch {};
        }
    }
}

// ---------------- tests ----------------

const testing = std.testing;

test "the skill is written once and an edited one is left alone" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    installSkill(home);
    const written = try tmp.dir.readFileAlloc(testing.io, skill_file, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(@embedFile("karpathy_guidelines.md"), written);
    try testing.expect(std.mem.startsWith(u8, written, "---\nname: karpathy-guidelines"));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = skill_file, .data = "mine" });
    installSkill(home);
    const kept = try tmp.dir.readFileAlloc(testing.io, skill_file, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("mine", kept);
}

test "plugins already installed are not installed again" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    core.env = &env;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // the two without a language server are always wanted; the others depend on this machine's PATH
    const all = try pending(a, "");
    try testing.expect(all.len >= 2);
    try testing.expectEqualStrings("context7", all[0]);
    try testing.expectEqualStrings("feature-dev", all[1]);

    const rest = try pending(a, "context7\r\nfeature-dev\n");
    try testing.expectEqual(all.len - 2, rest.len);
    for (rest) |name| try testing.expect(std.mem.endsWith(u8, name, "-lsp"));

    // a name inside another line does not count
    try testing.expectEqualStrings("context7", (try pending(a, "context7-old\nfeature-dev\n"))[0]);
    try testing.expectEqual(0, (try pending(a, "context7\nfeature-dev\ntypescript-lsp\ncsharp-lsp\nphp-lsp\n")).len);
}
