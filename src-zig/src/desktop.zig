//! Claude's tools for the other apps on the user's Windows desktop (MCP server "vibe-desktop").
//!
//! Off by default: a chat only gets this server once the user turns "Desktop control" on for it
//! (the renderer remembers the choice for new chats). Windows are read through UI Automation (numbered controls,
//! like browser_snapshot) and driven with the real mouse and keyboard (SendInput).

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const png = @import("png.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const commands = .{
    .{ "desktop_set", desktop_set },
};

var enabled_mutex: core.Mutex = .{};
/// the chats it is on for (keys owned by `core.gpa`)
var enabled_chats: std.StringHashMapUnmanaged(void) = .empty;

pub fn enabled(chat: []const u8) bool {
    enabled_mutex.lock();
    defer enabled_mutex.unlock();
    return enabled_chats.contains(chat);
}

fn desktop_set(_: *ipc.Call, a: struct { chat: []const u8, on: bool }) !void {
    enabled_mutex.lock();
    defer enabled_mutex.unlock();
    if (!a.on) {
        if (enabled_chats.fetchRemove(a.chat)) |kv| core.gpa.free(kv.key);
    } else if (!enabled_chats.contains(a.chat)) {
        const chat = try core.gpa.dupe(u8, a.chat);
        errdefer core.gpa.free(chat);
        try enabled_chats.put(core.gpa, chat, {});
    }
}

pub const INSTRUCTIONS: []const u8 = "These tools see and operate the other apps open on the user's Windows desktop (the user turned them on for this chat). " ++
    "Start with desktop_list_windows, then desktop_snapshot of one window to get its numbered controls, then desktop_click / desktop_type / desktop_press_key with those numbers as `ref`. " ++
    "Take a new snapshot after the window changes. For apps whose controls don't show up in a snapshot (games, canvas or some Electron apps), use desktop_screenshot and click by x/y on it. " ++
    "To open an app, start it from the shell (e.g. `start notepad`), then list the windows. " ++
    "These use the user's real mouse and keyboard and bring the window to the front: ask the user before anything that sends, deletes, buys, pays, submits or changes settings, and never type passwords.";

const window_arg =
    \\{ "type": "string", "description": "Window id from desktop_list_windows, or part of its title / program name" }
;

const tools_json =
    \\[
    \\  {
    \\    "name": "desktop_list_windows",
    \\    "description": "The app windows open on the desktop, front to back: id, title, program, size. VIBE CODE's own windows are left out.",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  },
    \\  {
    \\    "name": "desktop_snapshot",
    \\    "description": "Reads one window's controls (UI Automation) as an indented tree: a numbered line per button, field, menu item, list item, text… with its name and current value. Use the numbers as `ref` for desktop_click / desktop_type. Does not move the window or the mouse.",
    \\    "inputSchema": { "type": "object", "properties": { "window":
++ window_arg ++
    \\ }, "required": ["window"] }
    \\  },
    \\  {
    \\    "name": "desktop_click",
    \\    "description": "Click a control (`ref` from the last desktop_snapshot), or a point (`x`, `y` in pixels of the last desktop_screenshot). Brings its window to the front first.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "ref": { "type": "string" },
    \\        "x": { "type": "number" },
    \\        "y": { "type": "number" },
    \\        "button": { "type": "string", "enum": ["left", "right"] },
    \\        "double": { "type": "boolean" }
    \\      }
    \\    }
    \\  },
    \\  {
    \\    "name": "desktop_type",
    \\    "description": "Type text with the keyboard: into a control (`ref`, clicked first), into a `window` (brought to the front), or else into the window in front. `clear` selects all and deletes first; `submit` presses Enter after.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": { "text": { "type": "string" }, "ref": { "type": "string" }, "window":
++ window_arg ++
    \\, "clear": { "type": "boolean" }, "submit": { "type": "boolean" } },
    \\      "required": ["text"]
    \\    }
    \\  },
    \\  {
    \\    "name": "desktop_press_key",
    \\    "description": "Press a key or shortcut in the window in front (or in `window`, brought to the front first), e.g. \"Enter\", \"Escape\", \"Tab\", \"Down\", \"Ctrl+S\", \"Alt+F4\", \"Ctrl+Shift+N\".",
    \\    "inputSchema": { "type": "object", "properties": { "key": { "type": "string" }, "window":
++ window_arg ++
    \\ }, "required": ["key"] }
    \\  },
    \\  {
    \\    "name": "desktop_focus",
    \\    "description": "Bring a window to the front (restoring it if minimized).",
    \\    "inputSchema": { "type": "object", "properties": { "window":
++ window_arg ++
    \\ }, "required": ["window"] }
    \\  },
    \\  {
    \\    "name": "desktop_screenshot",
    \\    "description": "Screenshot of one window (brought to the front first) or, without `window`, of the whole screen. desktop_click x/y are pixels of this image.",
    \\    "inputSchema": { "type": "object", "properties": { "window":
++ window_arg ++
    \\ } }
    \\  }
    \\]
;

/// The JSON text of the tools array.
pub fn tools(a: Allocator) ![]const u8 {
    _ = a;
    return tools_json;
}

/// MCP content (the JSON text of the array) for one tool call.
pub fn callTool(a: Allocator, chat: []const u8, name: []const u8, args: Value, fail: *core.Fail) anyerror![]const u8 {
    if (!enabled(chat))
        return fail.set(a, "Desktop control is off for this chat. The user can turn it on with the \"Desktop control\" button under the chat.", .{});
    if (!core.is_windows) return fail.set(a, "Desktop control only works on Windows.", .{});
    return call(a, chat, name, args, fail);
}

// ---------------- Windows ----------------

const com = core.host.win.com;
const c = core.host.win.c;

/// Lines in one snapshot (big apps have thousands of controls).
const MAX_REFS = 500;
/// Longest side of a screenshot (what Claude reads without shrinking it again).
const MAX_SHOT = 1568;

// uiautomation.h only declares these: the values are from uiautomationclient.h
const CLSID_CUIAutomation: c.GUID = .{ .Data1 = 0xff48dba4, .Data2 = 0x60ef, .Data3 = 0x4201, .Data4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e } };
const IID_IUIAutomation: c.GUID = .{ .Data1 = 0x30cbe57d, .Data2 = 0xd9d0, .Data3 = 0x452a, .Data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };
const IID_IUIAutomationValuePattern: c.GUID = .{ .Data1 = 0xa94cd8b1, .Data2 = 0x0844, .Data3 = 0x4cd6, .Data4 = .{ 0x9d, 0x2d, 0x64, 0x05, 0x37, 0xab, 0x39, 0xe9 } };
const IID_IUIAutomationTogglePattern: c.GUID = .{ .Data1 = 0x94cf8058, .Data2 = 0x9b8d, .Data3 = 0x4ab9, .Data4 = .{ 0x8b, 0xfd, 0x4c, 0xd0, 0xa3, 0x3c, 0x8c, 0x70 } };

const Element = c.IUIAutomationElement;

fn release(el: *Element) void {
    _ = el.lpVtbl.*.Release.?(el);
}

const Snap = struct { hwnd: c.HWND, refs: []const *Element };
/// `win` is null for the whole screen
const Shot = struct { win: c.HWND, left: i32, top: i32, scale: f64 };

/// UI Automation is COM: one thread owns it and every element handed out.
const Worker = struct {
    uia: *c.IUIAutomation,
    walker: *c.IUIAutomationTreeWalker,
    /// per chat: the window of the last snapshot and its numbered controls (owned by `core.gpa`)
    snaps: std.StringHashMapUnmanaged(Snap) = .empty,
    /// per chat: where the last screenshot was taken
    shots: std.StringHashMapUnmanaged(Shot) = .empty,

    fn init() ?Worker {
        var uia: ?*c.IUIAutomation = null;
        if (c.CoCreateInstance(&CLSID_CUIAutomation, null, c.CLSCTX_INPROC_SERVER, &IID_IUIAutomation, @ptrCast(&uia)) < 0) return null;
        const u = uia orelse return null;
        var walker: [*c]c.IUIAutomationTreeWalker = null;
        if (com.call(u, "get_ControlViewWalker", .{&walker}) < 0 or walker == null) {
            _ = u.lpVtbl.*.Release.?(u);
            return null;
        }
        return .{ .uia = u, .walker = walker };
    }

    fn deinit(w: *Worker) void {
        var it = w.snaps.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.refs) |el| release(el);
            core.gpa.free(e.value_ptr.refs);
            core.gpa.free(e.key_ptr.*);
        }
        w.snaps.deinit(core.gpa);
        var keys = w.shots.keyIterator();
        while (keys.next()) |k| core.gpa.free(k.*);
        w.shots.deinit(core.gpa);
        _ = w.walker.lpVtbl.*.Release.?(w.walker);
        _ = w.uia.lpVtbl.*.Release.?(w.uia);
    }

    /// Takes over `refs` (allocated in `core.gpa`).
    fn setSnap(w: *Worker, chat: []const u8, hwnd: c.HWND, refs: []const *Element) !void {
        errdefer {
            for (refs) |el| release(el);
            core.gpa.free(refs);
        }
        const slot = try w.snaps.getOrPut(core.gpa, chat);
        if (slot.found_existing) {
            for (slot.value_ptr.refs) |el| release(el);
            core.gpa.free(slot.value_ptr.refs);
        } else {
            errdefer w.snaps.removeByPtr(slot.key_ptr);
            slot.key_ptr.* = try core.gpa.dupe(u8, chat);
        }
        slot.value_ptr.* = .{ .hwnd = hwnd, .refs = refs };
    }

    fn setShot(w: *Worker, chat: []const u8, shot: Shot) !void {
        const slot = try w.shots.getOrPut(core.gpa, chat);
        if (!slot.found_existing) {
            errdefer w.shots.removeByPtr(slot.key_ptr);
            slot.key_ptr.* = try core.gpa.dupe(u8, chat);
        }
        slot.value_ptr.* = shot;
    }
};

/// One tool call on its way to the worker thread and back.
const Job = struct {
    /// owns everything below
    arena: std.heap.ArenaAllocator,
    chat: []const u8,
    name: []const u8,
    args: Value,
    result: union(enum) { none, ok: []const u8, err: []const u8 } = .none,
    done: std.Io.Event = .unset,
    /// the caller and the worker each hold it: a caller that gave up waiting leaves first
    refs: std.atomic.Value(u8) = .init(2),
    next: ?*Job = null,

    fn release(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        var arena = j.arena;
        arena.deinit();
        core.gpa.destroy(j);
    }
};

var queue_mutex: core.Mutex = .{};
var queue_cond: std.Io.Condition = .init;
var queue_head: ?*Job = null;
var queue_tail: ?*Job = null;
var worker_started = false;

const NO_UIA = "Windows UI Automation is not available.";

fn workerMain() void {
    // COM initialised on this thread, which owns every UIA object below.
    _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    // without UI Automation every call reports it
    var worker = Worker.init();
    while (true) {
        queue_mutex.lock();
        while (queue_head == null) queue_cond.waitUncancelable(core.io, &queue_mutex.m);
        const job = queue_head.?;
        queue_head = job.next;
        if (queue_head == null) queue_tail = null;
        queue_mutex.unlock();

        var fail: core.Fail = .{};
        job.result = if (worker) |*w|
            if (dispatch(w, job.arena.allocator(), job.chat, job.name, job.args, &fail)) |content| .{ .ok = content } else |e| .{ .err = fail.text(e) }
        else
            .{ .err = NO_UIA };
        job.done.set(core.io);
        job.release();
    }
}

/// Runs one call on the worker thread and waits for it.
fn call(a: Allocator, chat: []const u8, name: []const u8, args: Value, fail: *core.Fail) ![]const u8 {
    const job = try core.gpa.create(Job);
    job.* = .{ .arena = .init(core.gpa), .chat = "", .name = "", .args = .null };
    {
        errdefer {
            job.arena.deinit();
            core.gpa.destroy(job);
        }
        const ja = job.arena.allocator();
        job.chat = try ja.dupe(u8, chat);
        job.name = try ja.dupe(u8, name);
        job.args = try std.json.parseFromSliceLeaky(Value, ja, try core.toJson(ja, args), .{});

        queue_mutex.lock();
        defer queue_mutex.unlock();
        if (!worker_started) {
            const thread = std.Thread.spawn(.{}, workerMain, .{}) catch return fail.set(a, NO_UIA, .{});
            thread.detach();
            worker_started = true;
        }
        if (queue_tail) |t| t.next = job else queue_head = job;
        queue_tail = job;
        queue_cond.signal(core.io);
    }
    defer job.release();
    job.done.waitTimeout(core.io, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } }) catch
        return fail.set(a, "The window did not respond within 60 s.", .{});
    return switch (job.result) {
        .ok => |content| a.dupe(u8, content),
        .err => |msg| fail.set(a, "{s}", .{msg}),
        .none => unreachable,
    };
}

fn text(a: Allocator, t: []const u8) ![]const u8 {
    return core.toJson(a, .{.{ .type = "text", .text = t }});
}

fn get(args: Value, name: []const u8) ?Value {
    const v = if (args == .object) args.object.get(name) orelse return null else return null;
    return if (v == .null) null else v;
}

fn str(args: Value, name: []const u8) ?[]const u8 {
    const v = get(args, name) orelse return null;
    return if (v == .string) v.string else null;
}

fn flag(args: Value, name: []const u8) bool {
    const v = get(args, name) orelse return false;
    return v == .bool and v.bool;
}

fn number(args: Value, name: []const u8) ?f64 {
    return switch (get(args, name) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn dispatch(w: *Worker, a: Allocator, chat: []const u8, name: []const u8, args: Value, fail: *core.Fail) ![]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "desktop_list_windows")) return text(a, try listWindows(a));
    if (eql(u8, name, "desktop_snapshot")) return text(a, try snapshot(w, a, chat, args, fail));
    if (eql(u8, name, "desktop_click")) return text(a, try click(w, a, chat, args, fail));
    if (eql(u8, name, "desktop_type")) return text(a, try typeText(w, a, chat, args, fail));
    if (eql(u8, name, "desktop_press_key")) {
        if (str(args, "window")) |spec| try focus(a, try findWindow(a, spec, fail), fail);
        try press(a, str(args, "key") orelse "", fail);
        return text(a, try after(a));
    }
    if (eql(u8, name, "desktop_focus")) {
        const hwnd = try findWindow(a, str(args, "window") orelse "", fail);
        try focus(a, hwnd, fail);
        return text(a, try std.fmt.allocPrint(a, "\"{s}\" is in front.", .{try title(a, hwnd)}));
    }
    if (eql(u8, name, "desktop_screenshot")) return screenshot(w, a, chat, args, fail);
    return fail.set(a, "Unknown tool {s}", .{name});
}

// ---------------- windows ----------------

/// UTF-8 from UTF-16; an unpaired surrogate becomes U+FFFD.
fn utf8Lossy(a: Allocator, units: []const u16) ![]u8 {
    const s = try std.unicode.wtf16LeToWtf8Alloc(a, units);
    // WTF-8 writes a lone surrogate as ED A0..BF xx, which UTF-8 never has
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xED and s[i + 1] >= 0xA0) {
            s[i..][0..3].* = "\u{FFFD}".*;
            i += 2;
        }
    }
    return s;
}

/// What Rust's `char::is_whitespace` takes for a space.
fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn windowId(hwnd: c.HWND) isize {
    return @bitCast(@intFromPtr(hwnd));
}

fn title(a: Allocator, hwnd: c.HWND) ![]u8 {
    var buf: [512]u16 = undefined;
    const n = c.GetWindowTextW(hwnd, &buf, buf.len);
    return utf8Lossy(a, buf[0..@intCast(@max(n, 0))]);
}

fn pid(hwnd: c.HWND) u32 {
    var id: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &id);
    return id;
}

/// The file name of a process's program.
fn program(a: Allocator, pid_: u32) ![]u8 {
    const h = c.OpenProcess(c.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid_) orelse return a.dupe(u8, "");
    defer _ = c.CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var len: c.DWORD = buf.len;
    if (c.QueryFullProcessImageNameW(h, 0, &buf, &len) == 0) return a.dupe(u8, "");
    const path = try utf8Lossy(a, buf[0..len]);
    return path[if (std.mem.findScalarLast(u8, path, '\\')) |i| i + 1 else 0..];
}

/// Visible bounds of a window (without the invisible resize border Windows adds).
fn rect(hwnd: c.HWND) c.RECT {
    var r: c.RECT = .{};
    if (c.DwmGetWindowAttribute(hwnd, c.DWMWA_EXTENDED_FRAME_BOUNDS, &r, @sizeOf(c.RECT)) < 0) _ = c.GetWindowRect(hwnd, &r);
    return r;
}

/// Top-level app windows a person would see in the taskbar / Alt+Tab, front to back.
fn appWindows(a: Allocator) ![]c.HWND {
    const All = struct {
        a: Allocator,
        list: std.ArrayList(c.HWND) = .empty,
        fn each(hwnd: c.HWND, lp: c.LPARAM) callconv(.c) c.WINBOOL {
            const all: *@This() = @ptrFromInt(@as(usize, @bitCast(lp)));
            all.list.append(all.a, hwnd) catch return 0;
            return 1;
        }
    };
    var all: All = .{ .a = a };
    _ = c.EnumWindows(All.each, @bitCast(@intFromPtr(&all)));
    const me = c.GetCurrentProcessId();
    var n: usize = 0;
    for (all.list.items) |h| {
        var cloaked: u32 = 0;
        _ = c.DwmGetWindowAttribute(h, c.DWMWA_CLOAKED, &cloaked, 4);
        const ws_ex_toolwindow = 0x80;
        if (c.IsWindowVisible(h) == 0 or cloaked != 0 or c.GetWindowLongPtrW(h, c.GWL_EXSTYLE) & ws_ex_toolwindow != 0 or pid(h) == me) continue;
        if (blank(try title(a, h))) continue;
        all.list.items[n] = h;
        n += 1;
    }
    return all.list.items[0..n];
}

fn blank(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isSpace(cp)) return false;
    }
    return true;
}

fn listWindows(a: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try appWindows(a)) |h| {
        const r = rect(h);
        if (out.items.len > 0) try out.append(a, '\n');
        try out.print(a, "id {d} — \"{s}\" [{s}]", .{ windowId(h), try title(a, h), try program(a, pid(h)) });
        if (c.IsIconic(h) != 0) try out.appendSlice(a, " (minimized)") else try out.print(a, " {d}x{d}", .{ r.right - r.left, r.bottom - r.top });
    }
    if (out.items.len == 0) try out.appendSlice(a, "No app windows are open.");
    return out.items;
}

/// `needle` (UTF-16) is somewhere in `hay`, whatever the case of the letters.
fn contains(a: Allocator, hay: []const u8, needle: []const u16) !bool {
    const h = try core.wide(a, hay);
    return c.FindStringOrdinal(c.FIND_FROMSTART, h.ptr, @intCast(h.len), needle.ptr, @intCast(needle.len), 1) >= 0;
}

/// `spec`: a window id from desktop_list_windows, or part of a title / program name.
fn findWindow(a: Allocator, spec_: []const u8, fail: *core.Fail) !c.HWND {
    const spec = std.mem.trim(u8, spec_, " \t\r\n");
    if (spec.len == 0) return fail.set(a, "Pass `window`: an id from desktop_list_windows, or part of its title.", .{});
    const wins = try appWindows(a);
    if (std.fmt.parseInt(isize, spec, 10)) |id| {
        for (wins) |h| {
            if (windowId(h) == id) return h;
        }
    } else |_| {}
    const low = try core.wide(a, spec);
    for (wins) |h| {
        if (try contains(a, try title(a, h), low)) return h;
    }
    for (wins) |h| {
        if (try contains(a, try program(a, pid(h)), low)) return h;
    }
    return fail.set(a, "No window matches \"{s}\". Call desktop_list_windows.", .{spec});
}

/// Brings `hwnd` to the front; fails unless that app really is in front afterwards.
fn focus(a: Allocator, hwnd: c.HWND, fail: *core.Fail) !void {
    if (c.IsIconic(hwnd) != 0) _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    if (c.GetForegroundWindow() != hwnd and c.SetForegroundWindow(hwnd) == 0) {
        // Windows only lets the app that got the last input take the foreground: tap Alt
        var alt = [_]c.INPUT{ key(0x12, 0, 0), key(0x12, 0, c.KEYEVENTF_KEYUP) };
        send(&alt);
        _ = c.SetForegroundWindow(hwnd);
    }
    core.sleepMs(150);
    // a dialog of the same app may be the one in front: that is where input should go
    if (!frontIs(pid(hwnd)))
        return fail.set(a, "Windows would not bring \"{s}\" to the front. Ask the user to click on it once.", .{try title(a, hwnd)});
}

fn frontIs(pid_: u32) bool {
    return pid(c.GetForegroundWindow()) == pid_;
}

/// Input goes to the window in front: never let it land in VIBE CODE itself (this chat's terminal).
fn guardFront(a: Allocator, fail: *core.Fail) !void {
    if (frontIs(c.GetCurrentProcessId()))
        return fail.set(a, "VIBE CODE is in front, so keys would go into this chat. Pass `window` (or `ref`) so the target app is brought to the front first.", .{});
}

/// What is in front once an action had a moment to take effect.
fn after(a: Allocator) ![]u8 {
    core.sleepMs(400);
    const h = c.GetForegroundWindow();
    return std.fmt.allocPrint(a, "ok — in front: \"{s}\" [{s}]", .{ try title(a, h), try program(a, pid(h)) });
}

// ---------------- snapshot ----------------

const TYPES = [_][]const u8{
    "button",   "calendar",    "checkbox",   "combobox",  "edit",     "link",      "image",        "listitem", "list",     "menu",        "menubar",
    "menuitem", "progressbar", "radio",      "scrollbar", "slider",   "spinner",   "statusbar",    "tab",      "tabitem",  "text",        "toolbar",
    "tooltip",  "tree",        "treeitem",   "custom",    "group",    "thumb",     "datagrid",     "dataitem", "document", "splitbutton", "window",
    "pane",     "header",      "headeritem", "table",     "titlebar", "separator", "semanticzoom", "appbar",
};

const Node = union(enum) {
    /// leave it and everything inside out
    skip,
    /// not worth a line, but look inside
    through,
    show: []const u8,
};

fn oneOf(kind: []const u8, comptime kinds: []const []const u8) bool {
    inline for (kinds) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// `s` with every run of spaces as one space, cut after `max` characters.
fn short(a: Allocator, s: []const u8, max: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |ch| {
        if (isSpace(std.unicode.utf8Decode(ch) catch 0xFFFD)) {
            gap = out.items.len > 0;
            continue;
        }
        if (gap) try out.append(a, ' ');
        gap = false;
        try out.appendSlice(a, ch);
    }
    var chars: usize = 0;
    var i: usize = 0;
    while (i < out.items.len) : (chars += 1) {
        if (chars == max) {
            out.shrinkRetainingCapacity(i);
            try out.appendSlice(a, "…");
            break;
        }
        i += std.unicode.utf8ByteSequenceLength(out.items[i]) catch 1;
    }
    return out.items;
}

/// Takes the string (and frees it).
fn bstrText(a: Allocator, s: c.BSTR) ![]u8 {
    if (s == null) return a.dupe(u8, "");
    defer c.SysFreeString(s);
    return utf8Lossy(a, s[0..c.SysStringLen(s)]);
}

/// A control pattern of `el`, or null when it has none of that kind.
fn pattern(comptime T: type, el: *Element, id: c_int, iid: *const c.GUID) ?*T {
    var out: ?*anyopaque = null;
    if (com.call(el, "GetCurrentPatternAs", .{ id, iid, &out }) < 0) return null;
    return @ptrCast(@alignCast(out));
}

fn describe(a: Allocator, el: *Element) !Node {
    var yes: c.WINBOOL = 0;
    if (com.call(el, "get_CurrentIsOffscreen", .{&yes}) >= 0 and yes != 0) return .skip;
    var ty: c.CONTROLTYPEID = 0;
    const kind = if (com.call(el, "get_CurrentControlType", .{&ty}) >= 0 and ty >= 50000 and ty - 50000 < TYPES.len) TYPES[@intCast(ty - 50000)] else "element";
    if (oneOf(kind, &.{ "scrollbar", "thumb", "separator" })) return .skip;
    var bstr: c.BSTR = null;
    const name = try short(a, if (com.call(el, "get_CurrentName", .{&bstr}) >= 0) try bstrText(a, bstr) else "", 100);
    if (name.len == 0 and oneOf(kind, &.{ "pane", "group", "custom", "text", "element", "window", "image" })) return .through;
    var line: std.ArrayList(u8) = .empty;
    try line.print(a, "{s} \"{s}\"", .{ kind, name });
    if (oneOf(kind, &.{ "edit", "combobox", "document", "spinner", "slider" }) and !(com.call(el, "get_CurrentIsPassword", .{&yes}) >= 0 and yes != 0)) {
        if (pattern(c.IUIAutomationValuePattern, el, c.UIA_ValuePatternId, &IID_IUIAutomationValuePattern)) |v| {
            defer _ = v.lpVtbl.*.Release.?(v);
            bstr = null;
            if (com.call(v, "get_CurrentValue", .{&bstr}) >= 0) {
                const value = try bstrText(a, bstr);
                if (value.len > 0 and !std.mem.eql(u8, value, name))
                    try line.print(a, " value=\"{s}\"", .{try short(a, value, if (std.mem.eql(u8, kind, "document")) 2000 else 200)});
            }
        }
    }
    if (std.mem.eql(u8, kind, "checkbox")) {
        if (pattern(c.IUIAutomationTogglePattern, el, c.UIA_TogglePatternId, &IID_IUIAutomationTogglePattern)) |t| {
            defer _ = t.lpVtbl.*.Release.?(t);
            var state: c.enum_ToggleState = 0;
            if (com.call(t, "get_CurrentToggleState", .{&state}) >= 0 and state == c.ToggleState_On) try line.appendSlice(a, " (checked)");
        }
    }
    if (com.call(el, "get_CurrentIsEnabled", .{&yes}) >= 0 and yes == 0) try line.appendSlice(a, " (disabled)");
    return .{ .show = line.items };
}

/// `refs` (in `core.gpa`) keeps every control that got a line; the others are let go.
fn walk(w: *Worker, a: Allocator, el: *Element, depth: usize, refs: *std.ArrayList(*Element), lines: *std.ArrayList([]const u8)) !void {
    var child: [*c]Element = null;
    if (com.call(w.walker, "GetFirstChildElement", .{ el, &child }) < 0) return;
    while (child != null) {
        const cur: *Element = child;
        var kept = false;
        defer if (!kept) release(cur);
        if (refs.items.len >= MAX_REFS or depth > 40) return;
        switch (try describe(a, cur)) {
            .skip => {},
            .through => try walk(w, a, cur, depth, refs, lines),
            .show => |line| {
                try refs.append(core.gpa, cur);
                kept = true;
                const indent = try a.alloc(u8, depth * 2);
                @memset(indent, ' ');
                try lines.append(a, try std.fmt.allocPrint(a, "{s}[{d}] {s}", .{ indent, refs.items.len, line }));
                try walk(w, a, cur, depth + 1, refs, lines);
            },
        }
        child = null;
        if (com.call(w.walker, "GetNextSiblingElement", .{ cur, &child }) < 0) child = null;
    }
}

fn snapshot(w: *Worker, a: Allocator, chat: []const u8, args: Value, fail: *core.Fail) ![]u8 {
    const hwnd = try findWindow(a, str(args, "window") orelse "", fail);
    const head = try std.fmt.allocPrint(a, "Window id {d} — \"{s}\" [{s}]", .{ windowId(hwnd), try title(a, hwnd), try program(a, pid(hwnd)) });
    if (c.IsIconic(hwnd) != 0) return std.fmt.allocPrint(a, "{s} is minimized: call desktop_focus first.", .{head});
    var root: [*c]Element = null;
    if (com.call(w.uia, "ElementFromHandle", .{ @as(c.UIA_HWND, @ptrCast(hwnd)), &root }) < 0 or root == null)
        return fail.set(a, "UI Automation cannot read this window", .{});
    defer release(root);
    var refs: std.ArrayList(*Element) = .empty;
    errdefer {
        for (refs.items) |el| release(el);
        refs.deinit(core.gpa);
    }
    var lines: std.ArrayList([]const u8) = .empty;
    try walk(w, a, root, 0, &refs, &lines);
    const more = if (refs.items.len >= MAX_REFS) std.fmt.comptimePrint("\n(stopped at {d} controls)", .{MAX_REFS}) else "";
    const body = if (lines.items.len == 0) "(no controls exposed — use desktop_screenshot and click by x/y)" else try std.mem.join(a, "\n", lines.items);
    const out = try std.fmt.allocPrint(a, "{s}\n\n{s}{s}", .{ head, body, more });
    try w.setSnap(chat, hwnd, try refs.toOwnedSlice(core.gpa));
    return out;
}

/// The control numbered `r` in this chat's last snapshot, and its window.
fn element(w: *Worker, a: Allocator, chat: []const u8, r: Value, fail: *core.Fail) !struct { c.HWND, *Element } {
    const n: ?usize = switch (r) {
        .string => |s| std.fmt.parseInt(usize, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        .integer => |i| std.math.cast(usize, i),
        else => null,
    };
    const i = n orelse return fail.set(a, "`ref` is a number from desktop_snapshot", .{});
    const snap = w.snaps.get(chat) orelse return fail.set(a, "Take a desktop_snapshot first.", .{});
    if (i == 0 or i > snap.refs.len) return fail.set(a, "No such ref: take a new desktop_snapshot.", .{});
    return .{ snap.hwnd, snap.refs[i - 1] };
}

// ---------------- input ----------------

fn key(vk_: u16, scan: u16, flags: u32) c.INPUT {
    return .{ .type = c.INPUT_KEYBOARD, .unnamed_0 = .{ .ki = .{ .wVk = vk_, .wScan = scan, .dwFlags = flags } } };
}

fn mouse(flags: u32) c.INPUT {
    return .{ .type = c.INPUT_MOUSE, .unnamed_0 = .{ .mi = .{ .dwFlags = flags } } };
}

fn send(inputs: []c.INPUT) void {
    _ = c.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(c.INPUT));
}

fn clickAt(a: Allocator, x: i32, y: i32, right: bool, double: bool, fail: *core.Fail) !void {
    try guardFront(a, fail);
    // moves the cursor (physical pixels: the app is per-monitor DPI aware)
    if (c.SetCursorPos(x, y) == 0) return fail.set(a, "Windows would not move the mouse to {d}, {d}.", .{ x, y });
    var press_release = if (right)
        [_]c.INPUT{ mouse(c.MOUSEEVENTF_RIGHTDOWN), mouse(c.MOUSEEVENTF_RIGHTUP) }
    else
        [_]c.INPUT{ mouse(c.MOUSEEVENTF_LEFTDOWN), mouse(c.MOUSEEVENTF_LEFTUP) };
    send(&press_release);
    if (double) send(&press_release);
}

/// Clicks the middle of a control from the last snapshot.
fn clickRef(w: *Worker, a: Allocator, chat: []const u8, r: Value, right: bool, double: bool, fail: *core.Fail) !void {
    const hwnd, const el = try element(w, a, chat, r, fail);
    try focus(a, hwnd, fail);
    var b: c.RECT = .{};
    const hr = com.call(el, "get_CurrentBoundingRectangle", .{&b});
    if (hr < 0) return fail.set(a, "UI Automation could not find that control (0x{x:0>8}): take a new desktop_snapshot.", .{@as(u32, @bitCast(hr))});
    if (b.right <= b.left or b.bottom <= b.top)
        return fail.set(a, "That control is not on screen (scrolled away or closed): take a new desktop_snapshot.", .{});
    try clickAt(a, @divTrunc(b.left + b.right, 2), @divTrunc(b.top + b.bottom, 2), right, double, fail);
}

fn click(w: *Worker, a: Allocator, chat: []const u8, args: Value, fail: *core.Fail) ![]u8 {
    const right = if (str(args, "button")) |b| std.mem.eql(u8, b, "right") else false;
    const double = flag(args, "double");
    if (get(args, "ref")) |r| {
        try clickRef(w, a, chat, r, right, double, fail);
    } else if (number(args, "x") != null and number(args, "y") != null) {
        const shot = w.shots.get(chat) orelse return fail.set(a, "x/y are pixels of a desktop_screenshot: take one first.", .{});
        if (shot.win != null) try focus(a, shot.win, fail);
        try clickAt(a, shot.left + toPixel(number(args, "x").? / shot.scale), shot.top + toPixel(number(args, "y").? / shot.scale), right, double, fail);
    } else {
        return fail.set(a, "Pass `ref` (from desktop_snapshot) or `x` and `y` (on the last desktop_screenshot).", .{});
    }
    return after(a);
}

/// Rounded, and kept inside what an i32 holds (as Rust's `as i32` does).
fn toPixel(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(@round(v), -2147483648.0, 2147483647.0));
}

fn typeText(w: *Worker, a: Allocator, chat: []const u8, args: Value, fail: *core.Fail) ![]u8 {
    var clear = flag(args, "clear");
    if (get(args, "ref")) |r| {
        try clickRef(w, a, chat, r, false, false, fail);
        // empty the field directly where it allows it: not every app selects all on Ctrl+A
        if (clear) {
            _, const el = try element(w, a, chat, r, fail);
            if (pattern(c.IUIAutomationValuePattern, el, c.UIA_ValuePatternId, &IID_IUIAutomationValuePattern)) |v| {
                defer _ = v.lpVtbl.*.Release.?(v);
                if (com.call(v, "SetValue", .{@as(c.BSTR, null)}) >= 0) clear = false;
            }
        }
    } else if (str(args, "window")) |spec| {
        try focus(a, try findWindow(a, spec, fail), fail);
    }
    try guardFront(a, fail);
    if (clear) {
        try press(a, "Ctrl+A", fail);
        try press(a, "Delete", fail);
    }
    var inputs: std.ArrayList(c.INPUT) = .empty;
    for (try core.wide(a, str(args, "text") orelse "")) |unit| {
        switch (unit) {
            0x0D => {},
            // as keys, so editors start a new line / move to the next field
            0x0A, 0x09 => {
                const k: u16 = if (unit == 0x0A) 0x0D else 0x09;
                try inputs.appendSlice(a, &.{ key(k, 0, 0), key(k, 0, c.KEYEVENTF_KEYUP) });
            },
            else => try inputs.appendSlice(a, &.{ key(0, unit, c.KEYEVENTF_UNICODE), key(0, unit, c.KEYEVENTF_UNICODE | c.KEYEVENTF_KEYUP) }),
        }
    }
    var rest = inputs.items;
    while (rest.len > 0) {
        const n = @min(rest.len, 200);
        send(rest[0..n]);
        rest = rest[n..];
        core.sleepMs(10);
    }
    if (flag(args, "submit")) try press(a, "Enter", fail);
    return after(a);
}

const Vk = struct {
    code: u16,
    /// the key needs the extended flag
    ext: bool = false,
};

/// Virtual-key code of one key name.
fn vk(name: []const u8) ?Vk {
    var buf: [16]u8 = undefined;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    const n = std.ascii.lowerString(&buf, trimmed);
    const named = [_]struct { []const u8, Vk }{
        .{ "enter", .{ .code = 0x0D } },                   .{ "return", .{ .code = 0x0D } },
        .{ "esc", .{ .code = 0x1B } },                     .{ "escape", .{ .code = 0x1B } },
        .{ "tab", .{ .code = 0x09 } },                     .{ "backspace", .{ .code = 0x08 } },
        .{ "space", .{ .code = 0x20 } },                   .{ "delete", .{ .code = 0x2E, .ext = true } },
        .{ "del", .{ .code = 0x2E, .ext = true } },        .{ "insert", .{ .code = 0x2D, .ext = true } },
        .{ "ins", .{ .code = 0x2D, .ext = true } },        .{ "home", .{ .code = 0x24, .ext = true } },
        .{ "end", .{ .code = 0x23, .ext = true } },        .{ "pageup", .{ .code = 0x21, .ext = true } },
        .{ "pgup", .{ .code = 0x21, .ext = true } },       .{ "pagedown", .{ .code = 0x22, .ext = true } },
        .{ "pgdn", .{ .code = 0x22, .ext = true } },       .{ "up", .{ .code = 0x26, .ext = true } },
        .{ "arrowup", .{ .code = 0x26, .ext = true } },    .{ "down", .{ .code = 0x28, .ext = true } },
        .{ "arrowdown", .{ .code = 0x28, .ext = true } },  .{ "left", .{ .code = 0x25, .ext = true } },
        .{ "arrowleft", .{ .code = 0x25, .ext = true } },  .{ "right", .{ .code = 0x27, .ext = true } },
        .{ "arrowright", .{ .code = 0x27, .ext = true } }, .{ "ctrl", .{ .code = 0x11 } },
        .{ "control", .{ .code = 0x11 } },                 .{ "shift", .{ .code = 0x10 } },
        .{ "alt", .{ .code = 0x12 } },                     .{ "win", .{ .code = 0x5B, .ext = true } },
        .{ "windows", .{ .code = 0x5B, .ext = true } },    .{ "meta", .{ .code = 0x5B, .ext = true } },
        .{ "cmd", .{ .code = 0x5B, .ext = true } },        .{ "apps", .{ .code = 0x5D, .ext = true } },
        .{ "menu", .{ .code = 0x5D, .ext = true } },       .{ "printscreen", .{ .code = 0x2C } },
    };
    for (named) |k| {
        if (std.mem.eql(u8, n, k[0])) return k[1];
    }
    if (n.len > 1 and n[0] == 'f') {
        for (n[1..]) |d| {
            if (!std.ascii.isDigit(d)) break;
        } else {
            const f = std.fmt.parseInt(u16, n[1..], 10) catch 0;
            if (f >= 1 and f <= 24) return .{ .code = 0x70 + f - 1 };
        }
    }
    // one character: the key that types it
    const len = std.unicode.utf8ByteSequenceLength(n[0]) catch return null;
    if (len != n.len) return null;
    const ch = std.unicode.utf8Decode(n) catch return null;
    if (ch < 0x80 and std.ascii.isAlphanumeric(@intCast(ch))) return .{ .code = std.ascii.toUpper(@intCast(ch)) };
    if (ch > 0xFFFF) return null;
    // keyboard-layout lookup
    const k = c.VkKeyScanW(@intCast(ch));
    return if (k == -1) null else .{ .code = @as(u16, @bitCast(k)) & 0xFF };
}

/// Presses a key or chord like "Ctrl+Shift+S" in the window in front.
fn press(a: Allocator, spec: []const u8, fail: *core.Fail) !void {
    try guardFront(a, fail);
    var inputs: std.ArrayList(c.INPUT) = .empty;
    var parts = std.mem.splitScalar(u8, spec, '+');
    while (parts.next()) |p| {
        const name = std.mem.trim(u8, p, " \t\r\n");
        if (name.len == 0) continue;
        const k = vk(name) orelse return fail.set(a, "Unknown key \"{s}\".", .{name});
        try inputs.append(a, key(k.code, 0, if (k.ext) c.KEYEVENTF_EXTENDEDKEY else 0));
    }
    const n = inputs.items.len;
    if (n == 0) return fail.set(a, "Pass `key`, e.g. \"Enter\" or \"Ctrl+S\".", .{});
    // released in the reverse order
    for (0..n) |i| {
        var up = inputs.items[n - 1 - i];
        up.unnamed_0.ki.dwFlags |= c.KEYEVENTF_KEYUP;
        try inputs.append(a, up);
    }
    send(inputs.items);
}

// ---------------- screenshot ----------------

fn screenshot(w: *Worker, a: Allocator, chat: []const u8, args: Value, fail: *core.Fail) ![]const u8 {
    var win: c.HWND = null;
    var x: i32 = undefined;
    var y: i32 = undefined;
    var width: u32 = undefined;
    var height: u32 = undefined;
    const spec = str(args, "window") orelse "";
    if (std.mem.trim(u8, spec, " \t\r\n").len > 0) {
        win = try findWindow(a, spec, fail);
        // only what is on screen gets captured
        try focus(a, win, fail);
        core.sleepMs(150);
        const r = rect(win);
        x = r.left;
        y = r.top;
        width = @intCast(@max(r.right - r.left, 1));
        height = @intCast(@max(r.bottom - r.top, 1));
    } else {
        x = c.GetSystemMetrics(c.SM_XVIRTUALSCREEN);
        y = c.GetSystemMetrics(c.SM_YVIRTUALSCREEN);
        width = @intCast(@max(c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN), 1));
        height = @intCast(@max(c.GetSystemMetrics(c.SM_CYVIRTUALSCREEN), 1));
    }
    const grabbed: ?[]u8 = if (@hasDecl(m.capture, "grab")) m.capture.grab(a, x, y, width, height) else null;
    var px = grabbed orelse return fail.set(a, "Could not capture the screen.", .{});
    const scale = @min(@as(f64, MAX_SHOT) / @as(f64, @floatFromInt(@max(width, height))), 1.0);
    const nw: u32 = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(width)) * scale))), 1);
    const nh: u32 = @max(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(height)) * scale))), 1);
    if (scale < 1.0) px = try shrink(a, px, width, height, nw, nh);
    // the screen comes as BGRA: PNG wants RGBA, with nothing see-through
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        std.mem.swap(u8, &px[i], &px[i + 2]);
        px[i + 3] = 255;
    }
    const png_bytes = try png.encode(a, px, nw, nh);
    try w.setShot(chat, .{ .win = win, .left = x, .top = y, .scale = @as(f64, @floatFromInt(nw)) / @as(f64, @floatFromInt(width)) });
    const what = if (win != null) try std.fmt.allocPrint(a, "\"{s}\"", .{try title(a, win)}) else "the whole screen";
    const enc = std.base64.standard.Encoder;
    const data = enc.encode(try a.alloc(u8, enc.calcSize(png_bytes.len)), png_bytes);
    return core.toJson(a, .{
        .{ .type = "image", .data = data, .mimeType = "image/png" },
        .{ .type = "text", .text = try std.fmt.allocPrint(a, "{s}, {d}x{d} px. desktop_click x/y are pixels of this image.", .{ what, nw, nh }) },
    });
}

/// Box-filter downscale of 4-byte pixels (keeps text readable, unlike skipping pixels).
fn shrink(a: Allocator, px: []const u8, w: usize, h: usize, nw: usize, nh: usize) ![]u8 {
    const out = try a.alloc(u8, nw * nh * 4);
    for (0..nh) |dy| {
        const y0 = dy * h / nh;
        const y1 = @max((dy + 1) * h / nh, y0 + 1);
        for (0..nw) |dx| {
            const x0 = dx * w / nw;
            const x1 = @max((dx + 1) * w / nw, x0 + 1);
            var sum: [4]u32 = @splat(0);
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const i = (y * w + x) * 4;
                    for (0..4) |ch| sum[ch] += px[i + ch];
                }
            }
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            for (0..4) |ch| out[(dy * nw + dx) * 4 + ch] = @intCast(sum[ch] / n);
        }
    }
    return out;
}

// ---------------- tests ----------------

const testing = std.testing;

test "desktop control is off until a chat turns it on" {
    core.gpa = testing.allocator;
    core.io = testing.io;
    defer enabled_chats.clearAndFree(core.gpa);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c_: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    var fail: core.Fail = .{};

    try testing.expect(!enabled("chat-1"));
    try testing.expectError(error.Failed, callTool(a, "chat-1", "desktop_list_windows", .null, &fail));
    try testing.expect(std.mem.startsWith(u8, fail.msg, "Desktop control is off for this chat."));
    try desktop_set(&c_, .{ .chat = "chat-1", .on = true });
    try desktop_set(&c_, .{ .chat = "chat-1", .on = true });
    try testing.expect(enabled("chat-1") and !enabled("chat-2"));
    try desktop_set(&c_, .{ .chat = "chat-1", .on = false });
    try desktop_set(&c_, .{ .chat = "chat-2", .on = false });
    try testing.expect(!enabled("chat-1"));
}

test "the tools are listed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try std.json.parseFromSliceLeaky(Value, a, try tools(a), .{});
    const names = [_][]const u8{ "desktop_list_windows", "desktop_snapshot", "desktop_click", "desktop_type", "desktop_press_key", "desktop_focus", "desktop_screenshot" };
    try testing.expectEqual(names.len, listed.array.items.len);
    for (listed.array.items, names) |t, name| {
        try testing.expectEqualStrings(name, t.object.get("name").?.string);
        try testing.expect(t.object.get("description").?.string.len > 0);
        try testing.expectEqualStrings("object", t.object.get("inputSchema").?.object.get("type").?.string);
    }
    const type_schema = listed.array.items[3].object.get("inputSchema").?.object;
    try testing.expectEqualStrings("text", type_schema.get("required").?.array.items[0].string);
    try testing.expectEqualStrings("string", type_schema.get("properties").?.object.get("window").?.object.get("type").?.string);
}

test "tool arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.json.parseFromSliceLeaky(Value, a, "{\"window\":\"Notepad\",\"ref\":null,\"x\":12,\"y\":3.5,\"double\":true,\"clear\":\"yes\"}", .{});
    try testing.expectEqualStrings("Notepad", str(args, "window").?);
    try testing.expectEqual(null, str(args, "x"));
    try testing.expectEqual(null, get(args, "ref"));
    try testing.expectEqual(null, get(.null, "ref"));
    try testing.expectEqual(12.0, number(args, "x").?);
    try testing.expectEqual(3.5, number(args, "y").?);
    try testing.expect(flag(args, "double") and !flag(args, "clear") and !flag(args, "submit"));
    try testing.expectEqual(8, toPixel(7.5));
    try testing.expectEqual(-8, toPixel(-7.5));
    try testing.expectEqual(2147483647, toPixel(1e300));
    try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"a \\\"b\\\"\"}]", try text(a, "a \"b\""));
}

test "names are shortened like one line of text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Lưu tệp ngay", try short(a, "  Lưu\r\n tệp\u{A0}\tngay ", 100));
    try testing.expectEqualStrings("Lưu t…", try short(a, "Lưu tệp", 5));
    try testing.expectEqualStrings("Lưu tệp", try short(a, "Lưu tệp", 7));
    try testing.expectEqualStrings("", try short(a, " \n ", 5));
    try testing.expect(blank(" \u{3000}\t") and !blank(" a "));
    // a title cut in the middle of a surrogate pair
    try testing.expectEqualStrings("ok \u{1F600}\u{FFFD}", try utf8Lossy(a, &.{ 'o', 'k', ' ', 0xD83D, 0xDE00, 0xD83D }));
    try testing.expectEqualStrings("\u{FFFD}đ", try utf8Lossy(a, &.{ 0xDC00, 0x111 }));
}

test "screenshots shrink by averaging" {
    const px = [_]u8{
        0, 10, 20, 255, 100, 30, 40, 255, 1, 1, 1, 0, 3, 3, 3, 0,
        0, 10, 20, 255, 100, 30, 40, 255, 5, 5, 5, 0, 7, 7, 8, 0,
    };
    const out = try shrink(testing.allocator, &px, 4, 2, 2, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 50, 20, 30, 255, 4, 4, 4, 0 }, out);
    // never an empty box, even when a side grows
    const same = try shrink(testing.allocator, px[0..8], 2, 1, 2, 1);
    defer testing.allocator.free(same);
    try testing.expectEqualSlices(u8, px[0..8], same);
}

test "key names" {
    if (!core.is_windows) return error.SkipZigTest;
    try testing.expectEqual(Vk{ .code = 0x0D }, vk("Enter").?);
    try testing.expectEqual(Vk{ .code = 0x1B }, vk(" Esc ").?);
    try testing.expectEqual(Vk{ .code = 0x2E, .ext = true }, vk("delete").?);
    try testing.expectEqual(Vk{ .code = 0x28, .ext = true }, vk("ArrowDown").?);
    try testing.expectEqual(Vk{ .code = 0x11 }, vk("Ctrl").?);
    try testing.expectEqual(Vk{ .code = 0x5B, .ext = true }, vk("Win").?);
    try testing.expectEqual(Vk{ .code = 0x70 }, vk("F1").?);
    try testing.expectEqual(Vk{ .code = 0x74 }, vk("f5").?);
    try testing.expectEqual(Vk{ .code = 0x87 }, vk("F24").?);
    try testing.expectEqual(null, vk("F25"));
    try testing.expectEqual(null, vk("F0"));
    try testing.expectEqual(Vk{ .code = 'F' }, vk("f").?);
    try testing.expectEqual(Vk{ .code = 'S' }, vk("s").?);
    try testing.expectEqual(Vk{ .code = '7' }, vk("7").?);
    try testing.expectEqual(null, vk("bogus"));
    try testing.expectEqual(null, vk(""));
    try testing.expectEqual(null, vk("a-very-long-name-for-a-key"));
    // looked up in the keyboard layout: whatever key types it, it is one key
    if (vk(",")) |k| try testing.expect(k.code > 0 and k.code < 0x100 and !k.ext);
}

test "the desktop's windows are listed" {
    if (!core.is_windows) return error.SkipZigTest;
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};

    const wins = try appWindows(a);
    const list = try listWindows(a);
    if (wins.len == 0) {
        try testing.expectEqualStrings("No app windows are open.", list);
    } else {
        var lines = std.mem.splitScalar(u8, list, '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            try testing.expect(std.mem.startsWith(u8, line, "id "));
            try testing.expect(std.mem.find(u8, line, " — \"") != null);
            try testing.expect(std.mem.endsWith(u8, line, " (minimized)") or std.mem.findScalarLast(u8, line, 'x') != null);
        }
        try testing.expectEqual(wins.len, n);
        // by id, and by a part of its title in another case
        const first = wins[0];
        try testing.expectEqual(first, try findWindow(a, try std.fmt.allocPrint(a, " {d} ", .{windowId(first)}), &fail));
        const name = try title(a, first);
        const upper = try std.ascii.allocUpperString(a, name);
        try testing.expect(try contains(a, name, try core.wide(a, upper)));
        try testing.expect(std.unicode.utf8ValidateSlice(list));
    }
    try testing.expectError(error.Failed, findWindow(a, "  ", &fail));
    try testing.expectError(error.Failed, findWindow(a, "no window is called \u{1F9EA} this", &fail));
    try testing.expectEqualStrings("No window matches \"no window is called \u{1F9EA} this\". Call desktop_list_windows.", fail.msg);
    try testing.expect(try contains(a, "Báo cáo ĐẶC BIỆT.docx - Word", try core.wide(a, "đặc biệt")));
    try testing.expect(!try contains(a, "Notepad", try core.wide(a, "notepads")));
    try testing.expectEqual(0, (try program(a, 0)).len);
    try testing.expect(std.mem.endsWith(u8, try program(a, c.GetCurrentProcessId()), ".exe"));
}

test "UI Automation reads the taskbar" {
    if (!core.is_windows) return error.SkipZigTest;
    core.gpa = testing.allocator;
    core.io = testing.io;
    // a session without a desktop (CI) has no taskbar to read
    const tray = c.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("Shell_TrayWnd"), null) orelse return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inited = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    defer if (inited >= 0) c.CoUninitialize();
    var w = Worker.init() orelse return error.NoUiAutomation;
    defer w.deinit();

    var root: [*c]Element = null;
    try testing.expect(com.call(w.uia, "ElementFromHandle", .{ @as(c.UIA_HWND, @ptrCast(tray)), &root }) >= 0 and root != null);
    defer release(root);
    var refs: std.ArrayList(*Element) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    try walk(&w, a, root, 0, &refs, &lines);
    try testing.expect(refs.items.len > 0 and refs.items.len <= MAX_REFS);
    try testing.expectEqual(refs.items.len, lines.items.len);
    try testing.expect(std.mem.startsWith(u8, lines.items[0], "[1] "));
    for (lines.items) |line| try testing.expect(std.unicode.utf8ValidateSlice(line));

    // numbered as the chat's last snapshot: `ref` finds the control and where it is on screen
    try w.setSnap("chat", tray, try refs.toOwnedSlice(core.gpa));
    var fail: core.Fail = .{};
    const hwnd, const el = try element(&w, a, "chat", .{ .string = " 1 " }, &fail);
    try testing.expectEqual(tray, hwnd);
    var b: c.RECT = .{};
    try testing.expect(com.call(el, "get_CurrentBoundingRectangle", .{&b}) >= 0);
    try testing.expect(b.right >= b.left and b.bottom >= b.top);
    try testing.expectEqual(el, (try element(&w, a, "chat", .{ .integer = 1 }, &fail))[1]);
    try testing.expectError(error.Failed, element(&w, a, "chat", .{ .integer = 0 }, &fail));
    try testing.expectError(error.Failed, element(&w, a, "chat", .{ .integer = 100000 }, &fail));
    try testing.expectEqualStrings("No such ref: take a new desktop_snapshot.", fail.msg);
    try testing.expectError(error.Failed, element(&w, a, "chat", .{ .float = 1.0 }, &fail));
    try testing.expectError(error.Failed, element(&w, a, "other chat", .{ .integer = 1 }, &fail));
    try testing.expectEqualStrings("Take a desktop_snapshot first.", fail.msg);
}

test "a screenshot of the whole screen" {
    // needs the capture module (`-Donly=desktop,capture`, or the whole app)
    if (!core.is_windows or !@hasDecl(m.capture, "grab")) return error.SkipZigTest;
    core.gpa = testing.allocator;
    core.io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inited = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    defer if (inited >= 0) c.CoUninitialize();
    var w = Worker.init() orelse return error.NoUiAutomation;
    defer w.deinit();

    var fail: core.Fail = .{};
    const content = screenshot(&w, a, "chat", .{ .object = .empty }, &fail) catch |e| {
        // a session without a desktop (CI) has nothing to capture
        if (e == error.Failed and std.mem.eql(u8, fail.msg, "Could not capture the screen.")) return error.SkipZigTest;
        return e;
    };
    const parts = (try std.json.parseFromSliceLeaky(Value, a, content, .{})).array.items;
    try testing.expectEqual(2, parts.len);
    try testing.expectEqualStrings("image", parts[0].object.get("type").?.string);
    try testing.expectEqualStrings("image/png", parts[0].object.get("mimeType").?.string);
    const dec = std.base64.standard.Decoder;
    const data = parts[0].object.get("data").?.string;
    const bytes = try a.alloc(u8, try dec.calcSizeForSlice(data));
    try dec.decode(bytes, data);
    const image = try png.decode(a, bytes);
    try testing.expect(@max(image.width, image.height) <= MAX_SHOT and image.width > 0 and image.height > 0);
    try testing.expectEqual(255, image.rgba[3]);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "the whole screen, {d}x{d} px. desktop_click x/y are pixels of this image.", .{ image.width, image.height }),
        parts[1].object.get("text").?.string,
    );
    // where desktop_click's x/y land: the image's corner is the screen's
    const shot = w.shots.get("chat").?;
    try testing.expect(shot.win == null and shot.scale > 0 and shot.scale <= 1);
    try testing.expectEqual(c.GetSystemMetrics(c.SM_XVIRTUALSCREEN), shot.left);
    try testing.expectEqual(c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN), toPixel(@as(f64, @floatFromInt(image.width)) / shot.scale));
}
