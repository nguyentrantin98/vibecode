//! VIBE CODE — the native side: terminals, files, git, Claude's session store, SQL Server, Zalo,
//! the built-in browser and the MCP server that lets each chat's Claude drive them.

const std = @import("std");
const core = @import("core.zig");
const host = @import("host.zig");
const m = @import("modules.zig");

pub const std_options: std.Options = .{
    .log_level = if (core.debug) .debug else .warn,
};

pub fn main(init: std.process.Init) !void {
    try core.init(init);

    // one instance: launching it again toggles the running window (Guake-style)
    if (@hasDecl(m.windowing, "singleInstance") and !m.windowing.singleInstance()) return;

    try host.init();

    if (@hasDecl(m.plugins, "init")) m.plugins.init();
    // before any chat starts: chats get the MCP server's address at launch
    if (@hasDecl(m.mcp, "start")) m.mcp.start() catch |e| std.log.err("MCP server: {s}", .{@errorName(e)});

    if (@hasDecl(m.windowing, "init")) {
        try m.windowing.init();
    } else {
        try fallbackWindow();
    }

    core.spawn(webStart, .{});
    if (@hasDecl(m.zalo, "init")) m.zalo.init();
    if (@hasDecl(m.zalo_tasks, "init")) m.zalo_tasks.init();
    // every other module (the ones above have their place in the order)
    inline for (m.all) |mod| {
        const started = comptime (mod == m.windowing or mod == m.plugins or mod == m.zalo or mod == m.zalo_tasks);
        if (!started and @hasDecl(mod, "init")) mod.init();
    }

    host.run();

    // the app is quitting: no terminal or query outlives it
    if (@hasDecl(m.pty, "killAll")) m.pty.killAll();
    inline for (m.all) |mod| {
        if (@hasDecl(mod, "deinit")) mod.deinit();
    }
}

/// uBlock Origin Lite, then the other default extensions, in the Web tabs.
fn webStart() void {
    if (@hasDecl(m.browser, "startAdblock")) m.browser.startAdblock();
    if (@hasDecl(m.extensions, "installDefaults")) m.extensions.installDefaults();
}

/// A plain main window, for builds without the windowing module (`-Donly=…`).
fn fallbackWindow() !void {
    if (core.is_windows) {
        const W = host.win;
        const w = try W.createWindow(.{ .label = host.main_label, .width = 1480, .height = 920, .min_width = 760, .min_height = 280, .decorations = false, .background = 0x2a2a2cff });
        const url = try W.appUrl(core.gpa, "/");
        _ = try W.createWebview(w, .{ .label = host.main_label, .url = url, .background = 0x2a2a2cff, .file_drop = true, .resize_edges = true });
        w.listener = struct {
            fn f(_: *W.Window, e: W.WindowEvent) bool {
                if (e == .destroyed) host.quit();
                return false;
            }
        }.f;
    } else {
        try host.mac.fallbackWindow();
    }
}

test {
    _ = @import("http.zig");
    _ = @import("watch.zig");
    _ = @import("png.zig");
    _ = @import("dialog.zig");
    // every command, with its argument parsing and reply encoding
    _ = &@import("ipc.zig").dispatch;
    inline for (m.all) |mod| std.testing.refAllDecls(mod);
}

test "sqlite is linked" {
    const sq = @import("sqlite");
    try std.testing.expect(sq.sqlite3_libversion_number() > 3000000);
}
