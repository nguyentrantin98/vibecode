//! The native shell around the pages, per platform: windows, webviews, the run loop, and getting
//! onto the UI thread. `host.win` / `host.mac` are the platform modules themselves, for code that
//! needs more than the common part below.

const std = @import("std");
const builtin = @import("builtin");

pub const platform = switch (builtin.os.tag) {
    .windows => @import("host/win/host.zig"),
    .macos => @import("host/mac/host.zig"),
    else => @compileError("VIBE CODE runs on Windows and macOS"),
};
pub const win = if (builtin.os.tag == .windows) platform else struct {};
pub const mac = if (builtin.os.tag == .macos) platform else struct {};

/// The app window's label (its webview has the same one).
pub const main_label = "main";

/// Physical pixels.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const init = platform.init;
pub const run = platform.run;
pub const quit = platform.quit;
pub const isUiThread = platform.isUiThread;
pub const onUi = platform.onUi;
pub const onUiSync = platform.onUiSync;
/// JSON message to a webview by label, from any thread (see core.emit / ipc.Channel).
pub const post = platform.post;
pub const origin = platform.origin;

// ---------------- extra pages served at the app's origin ----------------

pub const Response = struct {
    status: c_int = 200,
    mime: []const u8 = "text/html; charset=utf-8",
    body: []const u8,
};

/// Serves `<origin><prefix>…`: return null to fall through to the bundled files. Runs on the UI
/// thread; allocate the body in `a` (freed after the response is copied).
pub const Route = *const fn (a: std.mem.Allocator, path: []const u8, url: []const u8) ?Response;

var routes: [16]struct { prefix: []const u8, f: Route } = undefined;
var route_count: usize = 0;

/// Call during start-up, before the run loop.
pub fn addRoute(prefix: []const u8, f: Route) void {
    routes[route_count] = .{ .prefix = prefix, .f = f };
    route_count += 1;
}

pub fn findRoute(path: []const u8) ?Route {
    for (routes[0..route_count]) |r| if (std.mem.startsWith(u8, path, r.prefix)) return r.f;
    return null;
}

/// The script every app page gets first (`window.__VIBE__`).
pub fn bridgeScript() []const u8 {
    return bridge;
}

const bridge = blk: {
    const src = @embedFile("host/bridge.js");
    const needle = "__IPC_ORIGIN__";
    const i = std.mem.indexOf(u8, src, needle).?;
    break :blk src[0..i] ++ "'" ++ platform.origin ++ "'" ++ src[i + needle.len ..];
};
