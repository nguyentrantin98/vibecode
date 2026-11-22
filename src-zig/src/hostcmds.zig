//! Commands the pages need from the window itself (Tauri's built-ins in the old build).

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const settings = @import("settings.zig");

pub const commands = .{
    .{ "win_start_drag", win_start_drag },
    .{ "__win_resize", win_resize },
    .{ "dialog_ask", dialog_ask },
};

fn mainWindowDo(comptime f: anytype, args: anytype) void {
    if (core.is_windows) {
        const W = host.win;
        host.onUiSync(struct {
            fn run(a: @TypeOf(args)) void {
                const w = W.findWindow(host.main_label) orelse return;
                @call(.auto, f, .{w} ++ a);
            }
        }.run, .{args});
    } else {
        host.mac.mainWindowDo(f, args);
    }
}

/// The title bar was pressed: move the window with the mouse.
fn win_start_drag(_: *ipc.Call) !void {
    mainWindowDo(host.platform.Window.startDrag, .{});
}

/// An edge of an undecorated window was pressed.
fn win_resize(c: *ipc.Call, a: struct { dir: []const u8 }) !void {
    const dir = try core.gpa.dupe(u8, a.dir);
    defer core.gpa.free(dir);
    _ = c;
    mainWindowDo(host.platform.Window.startResize, .{dir});
}

/// OK / Cancel question in a native box; true = OK.
fn dialog_ask(_: *ipc.Call, a: struct { message: []const u8, title: ?[]const u8 = null }) !bool {
    return host.platform.askOkCancel(a.title orelse "VIBE CODE", a.message);
}
