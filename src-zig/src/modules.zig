//! Every feature module, in start-up order. Each one may declare:
//!   pub const commands = .{ .{ "name", func }, … };   page-callable commands (see ipc.zig)
//!   pub fn init() void                                  start-up (after the main window exists
//!                                                       unless noted in main.zig)
//!   pub fn deinit() void                                the app is quitting
//!
//! `zig build -Donly=pty,fsx` compiles just those modules (plus hostcmds and settings), so one
//! module can be built and tested while others are half-written.

const std = @import("std");
const opts = @import("build_options");

fn enabled(comptime name: []const u8) bool {
    if (opts.only.len == 0) return true;
    var it = std.mem.tokenizeScalar(u8, opts.only, ',');
    while (it.next()) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}


pub const hostcmds = @import("hostcmds.zig");
pub const settings = @import("settings.zig");
pub const secure = if (enabled("secure")) @import("secure.zig") else struct {};
pub const appcmds = if (enabled("appcmds")) @import("appcmds.zig") else struct {};
pub const windowing = if (enabled("windowing")) @import("windowing.zig") else struct {};
pub const pty = if (enabled("pty")) @import("pty.zig") else struct {};
pub const plugins = if (enabled("plugins")) @import("plugins.zig") else struct {};
pub const mcp = if (enabled("mcp")) @import("mcp.zig") else struct {};
pub const browser = if (enabled("browser")) @import("browser.zig") else struct {};
pub const adblock = if (enabled("adblock")) @import("adblock.zig") else struct {};
pub const extensions = if (enabled("extensions")) @import("extensions.zig") else struct {};
pub const webdata = if (enabled("webdata")) @import("webdata.zig") else struct {};
pub const sessions = if (enabled("sessions")) @import("sessions.zig") else struct {};
pub const mssql = if (enabled("mssql")) @import("mssql.zig") else struct {};
pub const desktop = if (enabled("desktop")) @import("desktop.zig") else struct {};
pub const gmail = if (enabled("gmail")) @import("gmail.zig") else struct {};
pub const office = if (enabled("office")) @import("office.zig") else struct {};
pub const onlyoffice = if (enabled("onlyoffice")) @import("onlyoffice.zig") else struct {};
pub const zalo = if (enabled("zalo/zalo")) @import("zalo/zalo.zig") else struct {};
pub const zalo_tasks = if (enabled("zalo_tasks")) @import("zalo_tasks.zig") else struct {};
pub const toast = if (enabled("toast")) @import("toast.zig") else struct {};
pub const capture = if (enabled("capture")) @import("capture.zig") else struct {};
pub const fsx = if (enabled("fsx")) @import("fsx.zig") else struct {};
pub const fsearch = if (enabled("fsearch")) @import("fsearch.zig") else struct {};
pub const git = if (enabled("git")) @import("git.zig") else struct {};
pub const thermal = if (enabled("thermal")) @import("thermal.zig") else struct {};
pub const audio = if (enabled("audio")) @import("audio.zig") else struct {};

/// in start-up order
pub const all = .{
    hostcmds, settings, secure,     appcmds,    windowing,  pty,   plugins, mcp,
    browser,  adblock,  extensions, webdata,    sessions,   mssql, desktop, gmail,
    office,   onlyoffice, zalo,     zalo_tasks, toast,      capture, fsx,   fsearch,
    git,      thermal, audio,
};
