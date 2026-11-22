//! The built-in browser: every Web tab is a native child WebView of the main window, laid over
//! the spot the page reserves for it.
//!
//! Why this is light: a tab that is not on screen is made invisible to the engine (so its timers,
//! animations and video throttle), asked to use little memory, and after a while frozen outright
//! (WebView2 `TrySuspend`) — the Electron build kept every page of every chat running at full
//! speed. A frozen page wakes up as soon as it is shown again, with its form input intact.
//!
//! Claude's browser tools drive a tab through the DevTools protocol (Runtime.evaluate,
//! Page.captureScreenshot, Input.dispatchKeyEvent).
//!
//! Threads: commands and Claude's tools run on worker threads; everything that touches WebView2
//! (`win`) runs on the UI thread, reached with `host.onUiSync` / `host.onUi`. A tab is named by
//! its label everywhere: the UI side looks its webview up again (`findWebview`), so a tab closed
//! meanwhile is simply not found. No lock is held across a hop to the UI thread or a COM call.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const settings = @import("settings.zig");
const adblock = @import("adblock.zig");
const ext_mod = @import("extensions.zig");
const J = @import("browser_json.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const commands = .{
    .{ "web_open", web_open },
    .{ "web_place", web_place },
    .{ "web_set_active", web_set_active },
    .{ "web_navigate", web_navigate },
    .{ "web_history", web_history },
    .{ "web_reload", web_reload },
    .{ "web_stop", web_stop },
    .{ "web_set_user_agent", web_set_user_agent },
    .{ "web_close", web_close },
    .{ "web_adblock_status", web_adblock_status },
};

/// Hidden this long → frozen.
const suspend_after_ms = 90_000;

const Tab = struct {
    chat: []const u8,
    visible: bool = false,
    /// `core.monoMs()` when it went off screen
    hidden_since: ?u64,
    suspended: bool = false,
    /// console / errors are being recorded (turned on the first time Claude's tools use the tab)
    logging: bool = false,
};

/// label → tab; keys and `chat` are owned by `core.gpa`
var tabs: std.StringHashMapUnmanaged(Tab) = .empty;
var tabs_mutex: core.Mutex = .{};

const LogLine = struct { at: u64, text: []u8 };
/// label → console errors / warnings, uncaught exceptions and failed requests of the page now loaded
var logs: std.StringHashMapUnmanaged(std.ArrayList(LogLine)) = .empty;
var logs_mutex: core.Mutex = .{};

/// chatId → label of the tab that chat's browser tools drive
var active: std.StringHashMapUnmanaged([]u8) = .empty;
/// tools waiting for a chat's tab to open (each on its own thread's stack)
var waiters: std.ArrayList(*Waiter) = .empty;
/// guards `active` and `waiters`
var active_mutex: core.Mutex = .{};

const Waiter = struct {
    chat: []const u8,
    /// set (owned by `core.gpa`) before `done`
    label: ?[]u8 = null,
    done: std.Io.Event = .unset,
};

fn hasTab(label: []const u8) bool {
    tabs_mutex.lock();
    defer tabs_mutex.unlock();
    return tabs.contains(label);
}

pub const WebNav = struct {
    url: []const u8,
    title: []const u8,
    back: bool,
    fwd: bool,
    loading: bool,
};

fn emitNav(label: []const u8, nav: WebNav) void {
    core.emit("web:nav", .{ label, nav });
}

fn seconds(n: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } };
}

// ---------------- commands ----------------

const Placement = struct { x: f64, y: f64, w: f64, h: f64, zoom: f64, visible: bool };

const Opening = struct {
    /// closed meanwhile
    closed: bool = false,
    /// where the page asked to put it meanwhile
    place: ?Placement = null,
};

/// Tabs whose page is still being created. One closed before `web_open` finished would otherwise
/// leave its page (a whole WebView2 renderer) alive for good. And the page places a tab right
/// after asking for it (and does not repeat itself): that placement is kept for when it exists —
/// commands run side by side here, where Tauri ran `web_place` behind the page's creation.
var opening: std.StringHashMapUnmanaged(Opening) = .empty;
/// placements that overtook their tab's `web_open` (label → where)
var early: std.StringHashMapUnmanaged(Placement) = .empty;
/// guards `opening` and `early`
var opening_mutex: core.Mutex = .{};

fn takeEarly(label: []const u8) ?Placement {
    const kv = early.fetchRemove(label) orelse return null;
    core.gpa.free(kv.key);
    return kv.value;
}

fn web_open(c: *ipc.Call, a: struct { label: []const u8, chatId: []const u8, url: []const u8, userAgent: ?[]const u8 = null }) !void {
    if (hasTab(a.label)) return;
    {
        opening_mutex.lock();
        defer opening_mutex.unlock();
        if (opening.contains(a.label)) return;
        const key = try core.gpa.dupe(u8, a.label);
        errdefer core.gpa.free(key);
        try opening.put(core.gpa, key, .{ .place = takeEarly(a.label) });
    }
    const res = openTab(c, a.label, a.chatId, a.url, a.userAgent);
    const state: Opening = blk: {
        opening_mutex.lock();
        defer opening_mutex.unlock();
        const kv = opening.fetchRemove(a.label) orelse break :blk .{};
        core.gpa.free(kv.key);
        break :blk kv.value;
    };
    if (state.closed) {
        closeTab(a.label);
    } else if (res) |_| {
        if (state.place) |p| if (core.is_windows) host.onUiSync(win.place, .{ a.label, p });
        announce(a.label);
    } else |_| {}
    return res;
}

fn openTab(c: *ipc.Call, label: []const u8, chat_id: []const u8, url: []const u8, user_agent: ?[]const u8) !void {
    if (!core.is_windows) return c.fail("The Web tabs need Windows (WebView2) for now.", .{});
    _ = std.Uri.parse(url) catch return c.fail("bad URL: {s}", .{url});
    const ua: ?[]const u8 = if (user_agent) |u| (if (u.len > 0) u else null) else null;
    // the page is made on the UI thread and exists a little later: `ready` lives on this stack,
    // so this function only returns once the page is ready or has been closed again
    var ready: std.Io.Event = .unset;
    if (!host.onUiSync(win.create, .{ label, url, ua, &ready })) return c.fail("no main window", .{});
    ready.waitTimeout(core.io, seconds(30)) catch {
        host.onUiSync(win.close, .{label});
        return c.fail("the Web tab could not start", .{});
    };
    insertTab(label, chat_id) catch |e| {
        host.onUiSync(win.close, .{label});
        return e;
    };
    startSweeper();
}

fn insertTab(label: []const u8, chat_id: []const u8) !void {
    const key = try core.gpa.dupe(u8, label);
    errdefer core.gpa.free(key);
    const chat = try core.gpa.dupe(u8, chat_id);
    errdefer core.gpa.free(chat);
    tabs_mutex.lock();
    defer tabs_mutex.unlock();
    try tabs.put(core.gpa, key, .{ .chat = chat, .hidden_since = core.monoMs() });
}

/// Where the page sits (CSS px of the main window) and its zoom; `visible` false parks it.
fn web_place(_: *ipc.Call, a: struct { label: []const u8, x: f64, y: f64, w: f64, h: f64, zoom: f64, visible: bool }) !void {
    const p: Placement = .{ .x = a.x, .y = a.y, .w = a.w, .h = a.h, .zoom = a.zoom, .visible = a.visible };
    {
        opening_mutex.lock();
        defer opening_mutex.unlock();
        if (opening.getPtr(a.label)) |o| {
            o.place = p;
            return;
        }
        if (!hasTab(a.label)) {
            // ahead of its `web_open`
            if (early.getPtr(a.label)) |e| {
                e.* = p;
            } else {
                const key = try core.gpa.dupe(u8, a.label);
                errdefer core.gpa.free(key);
                try early.put(core.gpa, key, p);
            }
            return;
        }
    }
    if (core.is_windows) host.onUiSync(win.place, .{ a.label, p });
}

fn web_set_active(_: *ipc.Call, a: struct { chatId: []const u8, label: []const u8 }) !void {
    try setActive(a.chatId, a.label);
}

fn setActive(chat: []const u8, label: []const u8) !void {
    active_mutex.lock();
    defer active_mutex.unlock();
    const value = try core.gpa.dupe(u8, label);
    errdefer core.gpa.free(value);
    if (active.getPtr(chat)) |old| {
        core.gpa.free(old.*);
        old.* = value;
    } else {
        const key = try core.gpa.dupe(u8, chat);
        errdefer core.gpa.free(key);
        try active.put(core.gpa, key, value);
    }
    // a tab whose page is still being created is told about by `announce`, once it exists
    if (hasTab(label)) wakeWaiters(chat, label);
}

/// A tab's page now exists: the tools of the chats it is the active tab of can go on.
fn announce(label: []const u8) void {
    active_mutex.lock();
    defer active_mutex.unlock();
    var it = active.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, label)) wakeWaiters(e.key_ptr.*, label);
}

/// Hands `label` to the tools waiting for `chat`'s tab (`active_mutex` held).
fn wakeWaiters(chat: []const u8, label: []const u8) void {
    var i: usize = 0;
    while (i < waiters.items.len) {
        const w = waiters.items[i];
        if (!std.mem.eql(u8, w.chat, chat)) {
            i += 1;
            continue;
        }
        _ = waiters.swapRemove(i);
        w.label = core.gpa.dupe(u8, label) catch null;
        // the waiter's stack may be gone right after this
        w.done.set(core.io);
    }
}

fn web_navigate(c: *ipc.Call, a: struct { label: []const u8, url: []const u8 }) !void {
    if (!hasTab(a.label)) return c.fail("tab is gone", .{});
    _ = std.Uri.parse(a.url) catch return c.fail("bad URL: {s}", .{a.url});
    navigate(a.label, a.url);
}

fn web_history(_: *ipc.Call, a: struct { label: []const u8, step: i32 }) !void {
    if (core.is_windows and hasTab(a.label)) host.onUiSync(win.history, .{ a.label, a.step });
}

fn web_reload(c: *ipc.Call, a: struct { label: []const u8, hard: bool }) !void {
    if (!hasTab(a.label)) return c.fail("tab is gone", .{});
    if (a.hard) {
        var fail: core.Fail = .{};
        _ = cdp(c.arena, a.label, "Page.reload", "{\"ignoreCache\":true}", &fail) catch |e| return c.failMsg(fail.text(e));
    } else if (core.is_windows) {
        host.onUiSync(win.reload, .{a.label});
    }
}

fn web_stop(_: *ipc.Call, a: struct { label: []const u8 }) !void {
    if (core.is_windows and hasTab(a.label)) host.onUiSync(win.stop, .{a.label});
}

/// Phone / tablet emulation: a different browser identity, then a reload so the site serves its
/// mobile layout. `null` → the engine's own.
fn web_set_user_agent(c: *ipc.Call, a: struct { label: []const u8, userAgent: ?[]const u8 = null }) !void {
    if (!hasTab(a.label)) return c.fail("tab is gone", .{});
    var fail: core.Fail = .{};
    const params = try core.toJson(c.arena, .{ .userAgent = a.userAgent orelse "" });
    _ = cdp(c.arena, a.label, "Emulation.setUserAgentOverride", params, &fail) catch |e| return c.failMsg(fail.text(e));
    if (core.is_windows) host.onUiSync(win.reload, .{a.label});
}

fn web_close(_: *ipc.Call, a: struct { label: []const u8 }) !void {
    closeTab(a.label);
}

fn closeTab(label: []const u8) void {
    const tab = blk: {
        tabs_mutex.lock();
        defer tabs_mutex.unlock();
        break :blk tabs.fetchRemove(label);
    };
    const kv = tab orelse {
        opening_mutex.lock();
        defer opening_mutex.unlock();
        if (opening.getPtr(label)) |o| o.closed = true;
        _ = takeEarly(label);
        return;
    };
    core.gpa.free(kv.key);
    core.gpa.free(kv.value.chat);
    forgetActive(label);
    clearLogs(label);
    if (core.is_windows) host.onUiSync(win.close, .{label});
}

/// No chat's tools drive `label` any more.
fn forgetActive(label: []const u8) void {
    active_mutex.lock();
    defer active_mutex.unlock();
    while (true) {
        var it = active.iterator();
        const key = while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.*, label)) break e.key_ptr.*;
        } else return;
        const kv = active.fetchRemove(key).?;
        core.gpa.free(kv.key);
        core.gpa.free(kv.value);
    }
}

// ---------------- sleeping tabs ----------------

var sweeper_started: std.atomic.Value(bool) = .init(false);

fn startSweeper() void {
    if (sweeper_started.swap(true, .acq_rel)) return;
    const t = std.Thread.spawn(.{}, sweep, .{}) catch {
        sweeper_started.store(false, .release);
        return;
    };
    t.detach();
}

fn sweep() void {
    while (true) {
        core.sleepMs(15_000);
        var due: std.ArrayList([]u8) = .empty;
        defer due.deinit(core.gpa);
        {
            tabs_mutex.lock();
            defer tabs_mutex.unlock();
            const now = core.monoMs();
            var it = tabs.iterator();
            while (it.next()) |e| {
                const t = e.value_ptr;
                const since = t.hidden_since orelse continue;
                if (t.visible or t.suspended or now -| since < suspend_after_ms) continue;
                const label = core.gpa.dupe(u8, e.key_ptr.*) catch continue;
                due.append(core.gpa, label) catch {
                    core.gpa.free(label);
                    continue;
                };
                t.suspended = true;
            }
        }
        for (due.items) |label| {
            if (core.is_windows) host.onUi(win.suspendTab, .{label}) else core.gpa.free(label);
        }
    }
}

/// Web tab: drop cached files (HTTP cache, Cache Storage, service workers) but keep cookies and
/// localStorage, so logins survive.
pub fn clearCache() !void {
    if (!core.is_windows) return;
    const ans = try Answer.create();
    if (!host.onUiSync(win.clearCacheStart, .{ans})) {
        ans.drop();
        return error.NoMainWindow;
    }
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    var fail: core.Fail = .{};
    // like the wait it replaces: after 30 s the cache is left to finish clearing on its own
    _ = ans.wait(arena.allocator(), 30, &fail, "") catch {};
}

// ---------------- ad blocking (uBlock Origin Lite) ----------------

/// What the shield button says: "uBlock Origin Lite 2026.1116.1650", "Downloading uBlock Origin Lite…", an error.
var adblock_status: ?[]u8 = null;
var adblock_status_mutex: core.Mutex = .{};
const adblock_status_start = "Downloading " ++ adblock.NAME ++ "…";

fn setAdblockStatus(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(core.gpa, fmt, args) catch return;
    // told before it is stored: once stored, another thread may replace (and free) it
    core.emit("web:adblock", .{s});
    adblock_status_mutex.lock();
    defer adblock_status_mutex.unlock();
    if (adblock_status) |old| core.gpa.free(old);
    adblock_status = s;
}

fn web_adblock_status(c: *ipc.Call) ![]const u8 {
    adblock_status_mutex.lock();
    defer adblock_status_mutex.unlock();
    return c.arena.dupe(u8, adblock_status orelse adblock_status_start);
}

/// Startup: fetch uBlock Origin Lite (first launch, or a newer release) and load it into the Web tabs.
pub fn startAdblock() void {
    if (!core.is_windows) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    _ = adblock.update(a, &fail) catch |e| if (adblock.installed(a) == null) {
        setAdblockStatus("Couldn't download {s}: {s}", .{ adblock.NAME, fail.text(e) });
        return;
    } else false;
    syncAdblock();
}

/// Puts the Web tabs' uBlock Origin Lite in line with the setting (and the release on disk). The tabs
/// share the main window's profile, so its webview is enough.
pub fn syncAdblock() void {
    if (!core.is_windows) return;
    waitMainView();
    host.onUi(win.syncUblock, .{});
}

/// At start-up the main window's page may not exist yet: gives it up to 30 s (not on the UI
/// thread, which is the one that makes it).
fn waitMainView() void {
    if (host.isUiThread()) return;
    const start = core.monoMs();
    while (!host.onUiSync(win.mainReady, .{}) and core.monoMs() -| start < 30_000) core.sleepMs(100);
}

// ---------------- other extensions (extensions.zig) ----------------

/// An extension in the Web tabs' profile.
pub const Ext = struct { id: []const u8, name: []const u8, enabled: bool };

const no_extensions = "Browser extensions need Windows (WebView2).";
const late = "WebView2 did not answer within 30s";

pub fn extensions(a: Allocator, fail: *core.Fail) ![]ext_mod.ExtInfo {
    if (!core.is_windows) return fail.set(a, no_extensions, .{});
    const ans = try Answer.create();
    host.onUiSync(win.extensionsStart, .{ans});
    const list = try core.fromJson([]const Ext, a, try ans.wait(a, 30, fail, late));
    const out = try a.alloc(ext_mod.ExtInfo, list.len);
    for (list, out) |e, *o| o.* = ext_mod.info(a, e.id, e.name, e.enabled);
    return out;
}

/// Loads an unpacked extension folder into the profile (on, until switched off).
pub fn addExtension(a: Allocator, dir: []const u8, fail: *core.Fail) !Ext {
    if (!core.is_windows) return fail.set(a, no_extensions, .{});
    waitMainView();
    const ans = try Answer.create();
    host.onUiSync(win.addExtensionStart, .{ dir, ans });
    return core.fromJson(Ext, a, try ans.wait(a, 30, fail, late));
}

pub fn extensionEnable(a: Allocator, id: []const u8, on: bool, fail: *core.Fail) !void {
    return extensionOp(a, id, on, fail);
}

pub fn extensionRemove(a: Allocator, id: []const u8, fail: *core.Fail) !void {
    return extensionOp(a, id, null, fail);
}

/// Switches an extension on / off, or removes it from the profile (`on` null).
fn extensionOp(a: Allocator, id: []const u8, on: ?bool, fail: *core.Fail) !void {
    if (!core.is_windows) return fail.set(a, no_extensions, .{});
    const ans = try Answer.create();
    host.onUiSync(win.extensionOpStart, .{ id, on, ans });
    _ = try ans.wait(a, 30, fail, late);
}

// ---------------- for Claude's tools (mcp.zig) ----------------

/// The tab a chat's tools drive (its label, allocated in `a`). Asks the page to open (and show)
/// the chat's Web tab, waiting up to 15 s for it.
pub fn viewFor(a: Allocator, chat: []const u8, fail: *core.Fail) ![]const u8 {
    core.emit("browser:open", .{chat});
    return activeTab(a, chat, 15_000, fail);
}

fn activeTab(a: Allocator, chat: []const u8, wait_ms: i64, fail: *core.Fail) ![]const u8 {
    var w: Waiter = .{ .chat = chat };
    {
        active_mutex.lock();
        defer active_mutex.unlock();
        if (active.get(chat)) |l| if (hasTab(l)) return a.dupe(u8, l);
        try waiters.append(core.gpa, &w);
    }
    w.done.waitTimeout(core.io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch {
        active_mutex.lock();
        defer active_mutex.unlock();
        for (waiters.items, 0..) |x, i| if (x == &w) {
            _ = waiters.swapRemove(i);
            return fail.set(a, "This chat's Web tab did not open within 15s. Ask the user to open this chat (or its Web tab) and try again.", .{});
        };
        // not in the list any more: `setActive` got to it first, `label` is set
    };
    const label = w.label orelse return error.OutOfMemory;
    defer core.gpa.free(label);
    if (!hasTab(label)) return fail.set(a, "the Web tab closed", .{});
    return a.dupe(u8, label);
}

/// Claude is about to drive the tab: unfreeze it if it was frozen, keep it from freezing again
/// for a while, and start recording its console errors (the first time).
pub fn wake(a: Allocator, label: []const u8) void {
    var thaw = false;
    var log = false;
    {
        tabs_mutex.lock();
        defer tabs_mutex.unlock();
        const t = tabs.getPtr(label) orelse return;
        if (!t.visible) t.hidden_since = core.monoMs();
        thaw = t.suspended;
        t.suspended = false;
        log = !t.logging;
        t.logging = true;
    }
    if (thaw and core.is_windows) host.onUiSync(win.resumeTab, .{label});
    // Only for tabs Claude drives: some sites treat a page with Runtime enabled as a bot.
    if (log) {
        var fail: core.Fail = .{};
        const on = if (cdp(a, label, "Runtime.enable", "{}", &fail)) |_| (if (cdp(a, label, "Log.enable", "{}", &fail)) |_| true else |_| false) else |_| false;
        if (!on) {
            tabs_mutex.lock();
            defer tabs_mutex.unlock();
            if (tabs.getPtr(label)) |t| t.logging = false;
        }
    }
}

/// Console errors / warnings, uncaught exceptions and failed requests of the page now loaded
/// (only those from `since` — a `core.monoMs()` — on, if given). Allocated in `a`.
pub fn errors(a: Allocator, label: []const u8, since: ?u64) []const []const u8 {
    logs_mutex.lock();
    defer logs_mutex.unlock();
    const list = logs.get(label) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (list.items) |l| {
        if (since != null and l.at < since.?) continue;
        out.append(a, a.dupe(u8, l.text) catch continue) catch {};
    }
    return out.items;
}

fn clearLogs(label: []const u8) void {
    logs_mutex.lock();
    defer logs_mutex.unlock();
    var kv = logs.fetchRemove(label) orelse return;
    for (kv.value.items) |l| core.gpa.free(l.text);
    kv.value.deinit(core.gpa);
    core.gpa.free(kv.key);
}

/// The first `n` characters of `s` (UTF-8 kept whole).
fn truncChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len and count < n) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
    }
    return s[0..i];
}

/// A DevTools event of a tab whose logging is on → its error list. `a` is scratch memory.
fn record(a: Allocator, label: []const u8, event: []const u8, params: []const u8) void {
    // a new document: the old page's errors no longer apply
    if (std.mem.eql(u8, event, "Runtime.executionContextsCleared")) return clearLogs(label);
    const line = logLine(a, event, J.parse(a, params)) catch return orelse return;
    const text = core.gpa.dupe(u8, truncChars(line, 600)) catch return;
    logs_mutex.lock();
    defer logs_mutex.unlock();
    const list = logs.getPtr(label) orelse blk: {
        const key = core.gpa.dupe(u8, label) catch return core.gpa.free(text);
        logs.put(core.gpa, key, .empty) catch {
            core.gpa.free(key);
            return core.gpa.free(text);
        };
        break :blk logs.getPtr(label).?;
    };
    list.append(core.gpa, .{ .at = core.monoMs(), .text = text }) catch return core.gpa.free(text);
    if (list.items.len > 50) core.gpa.free(list.orderedRemove(0).text);
}

/// What a DevTools event says, when it is worth telling Claude.
fn logLine(a: Allocator, event: []const u8, p: ?Value) !?[]const u8 {
    if (std.mem.eql(u8, event, "Runtime.consoleAPICalled")) {
        const kind = J.str(J.get(p, "type")) orelse "";
        if (!std.mem.eql(u8, kind, "error") and !std.mem.eql(u8, kind, "warning") and !std.mem.eql(u8, kind, "assert")) return null;
        var args: std.ArrayList(u8) = .empty;
        for (J.items(J.get(p, "args")), 0..) |x, i| {
            if (i > 0) try args.append(a, ' ');
            if (J.get(x, "value")) |v| {
                try args.appendSlice(a, try J.display(a, v));
            } else if (J.str(J.get(x, "description"))) |d| {
                try args.appendSlice(a, d);
            }
        }
        const f = J.at(J.path(p, &.{ "stackTrace", "callFrames" }), 0);
        const url = J.str(J.get(f, "url")) orelse "";
        const at = if (url.len > 0) try std.fmt.allocPrint(a, " ({s}:{d})", .{ url, (J.uint(J.get(f, "lineNumber")) orelse 0) + 1 }) else "";
        return try std.fmt.allocPrint(a, "console.{s}: {s}{s}", .{ kind, args.items, at });
    }
    if (std.mem.eql(u8, event, "Runtime.exceptionThrown")) {
        const d = J.get(p, "exceptionDetails");
        return try std.fmt.allocPrint(a, "uncaught: {s}", .{J.str(J.path(d, &.{ "exception", "description" })) orelse J.str(J.get(d, "text")) orelse "exception"});
    }
    if (std.mem.eql(u8, event, "Log.entryAdded")) {
        const e = J.get(p, "entry");
        if (!std.mem.eql(u8, J.str(J.get(e, "level")) orelse "", "error")) return null;
        const u = J.str(J.get(e, "url")) orelse "";
        const url = if (u.len > 0) try std.fmt.allocPrint(a, " ({s})", .{u}) else "";
        return try std.fmt.allocPrint(a, "{s}: {s}{s}", .{ J.str(J.get(e, "source")) orelse "log", J.str(J.get(e, "text")) orelse "", url });
    }
    return null;
}

/// Whether the tab is on screen (a hidden one cannot be captured).
pub fn isVisible(label: []const u8) bool {
    tabs_mutex.lock();
    defer tabs_mutex.unlock();
    return if (tabs.get(label)) |t| t.visible else false;
}

/// Sends the tab to another address.
pub fn navigate(label: []const u8, url: []const u8) void {
    if (core.is_windows) host.onUiSync(win.navigate, .{ label, url });
}

/// One DevTools protocol call (`params` is JSON text). Not for the UI thread: it waits for the
/// page's answer, which arrives there.
pub fn cdp(a: Allocator, label: []const u8, method: []const u8, params: []const u8, fail: *core.Fail) !Value {
    if (!core.is_windows) return fail.set(a, "The browser tools need Windows (WebView2) for now.", .{});
    const ans = try Answer.create();
    host.onUiSync(win.cdpStart, .{ label, method, params, ans });
    const json = try ans.wait(a, 60, fail, "the page did not answer within 60s");
    return J.parse(a, json) orelse .null;
}

/// Evaluates a JS expression in the page (promises awaited) and returns its JSON value.
pub fn eval(a: Allocator, label: []const u8, expression: []const u8, fail: *core.Fail) !Value {
    const params = try core.toJson(a, .{ .expression = expression, .awaitPromise = true, .returnByValue = true, .userGesture = true });
    const r = try cdp(a, label, "Runtime.evaluate", params, fail);
    if (J.get(r, "exceptionDetails")) |ex| {
        const msg = J.str(J.path(ex, &.{ "exception", "description" })) orelse J.str(J.get(ex, "text")) orelse "JavaScript error";
        return fail.set(a, "{s}", .{msg});
    }
    return J.path(r, &.{ "result", "value" }) orelse .null;
}

/// Presses a key the way a keyboard would (keyDown [+ char] + keyUp).
pub fn pressKey(a: Allocator, label: []const u8, key: []const u8, fail: *core.Fail) !void {
    const k = try keyInfo(a, key);
    const down = if (k.text) |t|
        try core.toJson(a, .{ .type = "keyDown", .key = k.key, .code = k.code, .windowsVirtualKeyCode = k.vk, .text = t })
    else
        try core.toJson(a, .{ .type = "rawKeyDown", .key = k.key, .code = k.code, .windowsVirtualKeyCode = k.vk });
    _ = try cdp(a, label, "Input.dispatchKeyEvent", down, fail);
    _ = try cdp(a, label, "Input.dispatchKeyEvent", try core.toJson(a, .{ .type = "keyUp", .key = k.key, .code = k.code, .windowsVirtualKeyCode = k.vk }), fail);
}

const Key = struct { key: []const u8, code: []const u8, vk: u32, text: ?[]const u8 = null };

const named_keys = std.StaticStringMap(Key).initComptime(.{
    .{ "enter", Key{ .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" } },
    .{ "return", Key{ .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" } },
    .{ "tab", Key{ .key = "Tab", .code = "Tab", .vk = 9 } },
    .{ "escape", Key{ .key = "Escape", .code = "Escape", .vk = 27 } },
    .{ "esc", Key{ .key = "Escape", .code = "Escape", .vk = 27 } },
    .{ "backspace", Key{ .key = "Backspace", .code = "Backspace", .vk = 8 } },
    .{ "delete", Key{ .key = "Delete", .code = "Delete", .vk = 46 } },
    .{ "del", Key{ .key = "Delete", .code = "Delete", .vk = 46 } },
    .{ "space", Key{ .key = " ", .code = "Space", .vk = 32, .text = " " } },
    .{ " ", Key{ .key = " ", .code = "Space", .vk = 32, .text = " " } },
    .{ "up", Key{ .key = "ArrowUp", .code = "ArrowUp", .vk = 38 } },
    .{ "arrowup", Key{ .key = "ArrowUp", .code = "ArrowUp", .vk = 38 } },
    .{ "down", Key{ .key = "ArrowDown", .code = "ArrowDown", .vk = 40 } },
    .{ "arrowdown", Key{ .key = "ArrowDown", .code = "ArrowDown", .vk = 40 } },
    .{ "left", Key{ .key = "ArrowLeft", .code = "ArrowLeft", .vk = 37 } },
    .{ "arrowleft", Key{ .key = "ArrowLeft", .code = "ArrowLeft", .vk = 37 } },
    .{ "right", Key{ .key = "ArrowRight", .code = "ArrowRight", .vk = 39 } },
    .{ "arrowright", Key{ .key = "ArrowRight", .code = "ArrowRight", .vk = 39 } },
    .{ "pageup", Key{ .key = "PageUp", .code = "PageUp", .vk = 33 } },
    .{ "pagedown", Key{ .key = "PageDown", .code = "PageDown", .vk = 34 } },
    .{ "home", Key{ .key = "Home", .code = "Home", .vk = 36 } },
    .{ "end", Key{ .key = "End", .code = "End", .vk = 35 } },
});

fn keyInfo(a: Allocator, key: []const u8) !Key {
    const k = try core.lower(a, key);
    if (named_keys.get(k)) |named| return named;
    // one character: typed as it is
    if ((std.unicode.utf8CountCodepoints(key) catch 0) == 1) {
        const ch = key[0];
        const up = std.ascii.toUpper(ch);
        if (key.len == 1 and std.ascii.isAlphabetic(up)) return .{ .key = key, .code = try std.fmt.allocPrint(a, "Key{c}", .{up}), .vk = up, .text = key };
        if (key.len == 1 and std.ascii.isDigit(ch)) return .{ .key = key, .code = try std.fmt.allocPrint(a, "Digit{c}", .{ch}), .vk = ch, .text = key };
        return .{ .key = key, .code = "", .vk = 0, .text = key };
    }
    if (k.len >= 2 and k.len <= 3 and k[0] == 'f' and std.ascii.isDigit(k[1]) and std.ascii.isDigit(k[k.len - 1])) {
        const n = std.fmt.parseInt(u32, k[1..], 10) catch 0;
        if (n >= 1 and n <= 12) {
            const name = try std.fmt.allocPrint(a, "F{d}", .{n});
            return .{ .key = name, .code = name, .vk = 111 + n };
        }
    }
    return .{ .key = key, .code = key, .vk = 0 };
}

// ---------------- answers of asynchronous WebView2 calls ----------------

/// The result of an asynchronous WebView2 call, handed from its completion handler (UI thread) to
/// the worker waiting for it. Two owners, the worker and the handler: a worker that gave up
/// waiting leaves the handler a live object to finish. A handler WebView2 never calls (it should
/// not happen) leaks its share, nothing worse.
const Answer = struct {
    done: std.Io.Event = .unset,
    refs: std.atomic.Value(u32) = .init(2),
    ok: bool = false,
    /// the result (JSON text), or what went wrong; owned by `core.gpa`
    text: []u8 = &.{},

    fn create() !*Answer {
        const self = try core.gpa.create(Answer);
        self.* = .{};
        return self;
    }

    /// UI thread, exactly once: stores the result, wakes the worker and lets go.
    fn finish(self: *Answer, ok: bool, text: []const u8) void {
        self.text = core.gpa.dupe(u8, text) catch &.{};
        self.ok = ok;
        self.done.set(core.io);
        self.drop();
    }

    fn drop(self: *Answer) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        core.gpa.free(self.text);
        core.gpa.destroy(self);
    }

    /// Worker thread, once: the result (allocated in `a`), or `fail` says what went wrong —
    /// `late` when there was no answer within `secs` seconds.
    fn wait(self: *Answer, a: Allocator, secs: i64, fail: *core.Fail, comptime late_msg: []const u8) ![]const u8 {
        defer self.drop();
        self.done.waitTimeout(core.io, seconds(secs)) catch return fail.set(a, late_msg, .{});
        const text = try a.dupe(u8, self.text);
        if (self.ok) return text;
        fail.msg = text;
        return error.Failed;
    }
};

// ---------------- WebView2 ----------------

/// Everything here runs on the UI thread.
const win = struct {
    const W = host.win;
    const com = W.com;
    const c = W.c;

    /// A new page for a tab, parked off-screen until the page tells us where it goes. False
    /// without a main window. `ready` is set once the page exists.
    fn create(label: []const u8, url: []const u8, user_agent: ?[]const u8, ready: *std.Io.Event) bool {
        const window = W.findWindow(host.main_label) orelse return false;
        _ = W.createWebview(window, .{
            .label = label,
            .url = url,
            .app = false,
            .bounds = .{ .x = -10_000, .y = -10_000, .w = 800, .h = 600 },
            .visible = false,
            .user_agent = user_agent,
            .devtools = true,
            .zoom_control = true,
            .on_ready = onReady,
            .ctx = ready,
        }) catch return false;
        return true;
    }

    fn onReady(v: *W.Webview, ctx: ?*anyopaque) void {
        hook(v);
        const ready: *std.Io.Event = @ptrCast(@alignCast(ctx.?));
        ready.set(core.io);
    }

    fn close(label: []const u8) void {
        if (W.findWebview(label)) |v| v.close();
    }

    const NavState = struct { url: c.LPWSTR = null, title: c.LPWSTR = null, back: c.BOOL = 0, fwd: c.BOOL = 0 };

    /// A navigation / title / history event of a tab → "web:nav" for its address bar.
    fn navEvent(v: *W.Webview, view: [*c]c.ICoreWebView2, loading: bool) void {
        if (v.closed or view == null) return;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var s: NavState = .{};
        _ = com.call(view, "get_Source", .{&s.url});
        _ = com.call(view, "get_DocumentTitle", .{&s.title});
        _ = com.call(view, "get_CanGoBack", .{&s.back});
        _ = com.call(view, "get_CanGoForward", .{&s.fwd});
        emitNav(v.label, .{
            .url = com.takeString(a, s.url) catch "",
            .title = com.takeString(a, s.title) catch "",
            .back = s.back != 0,
            .fwd = s.fwd != 0,
            .loading = loading,
        });
    }

    fn onNavStarting(v: *W.Webview, view: [*c]c.ICoreWebView2, _: [*c]c.ICoreWebView2NavigationStartingEventArgs) void {
        navEvent(v, view, true);
    }
    fn onNavCompleted(v: *W.Webview, view: [*c]c.ICoreWebView2, _: [*c]c.ICoreWebView2NavigationCompletedEventArgs) void {
        navEvent(v, view, false);
    }
    fn onChanged(v: *W.Webview, view: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) void {
        navEvent(v, view, false);
    }

    /// popups open in the same tab
    fn onNewWindow(v: *W.Webview, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2NewWindowRequestedEventArgs) void {
        if (args == null) return;
        _ = com.call(args, "put_Handled", .{@as(c.BOOL, 1)});
        var uri: c.LPWSTR = null;
        _ = com.call(args, "get_Uri", .{&uri});
        const url = com.takeString(core.gpa, uri) catch return;
        defer core.gpa.free(url);
        if (v.closed) return;
        if (std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://")) v.navigate(url);
    }

    const log_events = [_][]const u8{ "Runtime.consoleAPICalled", "Runtime.exceptionThrown", "Log.entryAdded", "Runtime.executionContextsCleared" };
    const LogCtx = struct { view: *W.Webview, event: []const u8 };

    fn onLogEvent(ctx: LogCtx, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2DevToolsProtocolEventReceivedEventArgs) void {
        if (ctx.view.closed or args == null) return;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var p: c.LPWSTR = null;
        _ = com.call(args, "get_ParameterObjectAsJson", .{&p});
        record(a, ctx.view.label, ctx.event, com.takeString(a, p) catch return);
    }

    /// The events of a new tab: navigation / title / history for its address bar, popups, and
    /// the console for Claude.
    fn hook(v: *W.Webview) void {
        const view = v.view orelse return;
        // Google refuses to sign in inside an "embedded" browser and tells it by `window.chrome.webview`.
        // Tabs show outside sites and talk to us only through the DevTools protocol, so they don't need it:
        // without it (from the next page on) Google sign-in works like in Chrome.
        var s: ?*c.ICoreWebView2Settings = null;
        _ = com.call(view, "get_Settings", .{&s});
        if (s) |st| {
            defer com.release(s);
            _ = com.call(st, "put_IsWebMessageEnabled", .{@as(c.BOOL, 0)});
            _ = com.call(st, "put_AreHostObjectsAllowed", .{@as(c.BOOL, 0)});
        }
        com.on(view, "NavigationStarting", c.ICoreWebView2NavigationStartingEventHandler, &c.IID_ICoreWebView2NavigationStartingEventHandler, v, onNavStarting);
        com.on(view, "NavigationCompleted", c.ICoreWebView2NavigationCompletedEventHandler, &c.IID_ICoreWebView2NavigationCompletedEventHandler, v, onNavCompleted);
        com.on(view, "HistoryChanged", c.ICoreWebView2HistoryChangedEventHandler, &c.IID_ICoreWebView2HistoryChangedEventHandler, v, onChanged);
        com.on(view, "DocumentTitleChanged", c.ICoreWebView2DocumentTitleChangedEventHandler, &c.IID_ICoreWebView2DocumentTitleChangedEventHandler, v, onChanged);
        com.on(view, "NewWindowRequested", c.ICoreWebView2NewWindowRequestedEventHandler, &c.IID_ICoreWebView2NewWindowRequestedEventHandler, v, onNewWindow);
        // console / errors for Claude: delivered once wake() turns the domains on
        inline for (log_events) |event| {
            var rx: ?*c.ICoreWebView2DevToolsProtocolEventReceiver = null;
            _ = com.call(view, "GetDevToolsProtocolEventReceiver", .{ std.unicode.utf8ToUtf16LeStringLiteral(event), &rx });
            if (rx) |r| {
                defer com.release(rx);
                com.on(r, "DevToolsProtocolEventReceived", c.ICoreWebView2DevToolsProtocolEventReceivedEventHandler, &c.IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler, LogCtx{ .view = v, .event = event }, onLogEvent);
            }
        }
    }

    fn px(v: f64) i32 {
        return std.math.lossyCast(i32, @round(v));
    }

    fn place(label: []const u8, p: Placement) void {
        const v = W.findWebview(label) orelse return;
        const visible = p.visible;
        var changed = false;
        {
            tabs_mutex.lock();
            defer tabs_mutex.unlock();
            const t = tabs.getPtr(label) orelse return;
            changed = visible != t.visible;
            t.visible = visible;
            if (changed and visible) {
                t.hidden_since = null;
                t.suspended = false;
            } else if (changed) {
                t.hidden_since = core.monoMs();
            }
        }
        if (visible) {
            // CSS px of the window → physical
            const s = v.window.dpi();
            v.place(.{ .x = px(p.x * s), .y = px(p.y * s), .w = px(@max(p.w, 1.0) * s), .h = px(@max(p.h, 1.0) * s) }, true);
            v.setZoom(p.zoom);
        }
        if (!changed) return;
        if (!visible) v.place(v.bounds, false);
        setAwake(v, visible);
    }

    /// Shown: full speed. Hidden: invisible to the engine (throttled) and asked to use little memory.
    fn setAwake(v: *W.Webview, awake: bool) void {
        const view = v.view orelse return;
        if (awake) resumeView(view);
        if (com.query(c.ICoreWebView2_19, view, &c.IID_ICoreWebView2_19)) |v19| {
            defer com.release(@as(?*c.ICoreWebView2_19, v19));
            const level: c.COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL = @intCast(if (awake) c.COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_NORMAL else c.COREWEBVIEW2_MEMORY_USAGE_TARGET_LEVEL_LOW);
            _ = com.call(v19, "put_MemoryUsageTargetLevel", .{level});
        }
    }

    fn resumeView(view: *c.ICoreWebView2) void {
        const v3 = com.query(c.ICoreWebView2_3, view, &c.IID_ICoreWebView2_3) orelse return;
        defer com.release(@as(?*c.ICoreWebView2_3, v3));
        _ = com.call(v3, "Resume", .{});
    }

    fn resumeTab(label: []const u8) void {
        const v = W.findWebview(label) orelse return;
        if (v.view) |view| resumeView(view);
    }

    /// Freezes a hidden tab: no script runs, its memory can be paged out. Showing it resumes it.
    /// Takes over `label` (allocated with `core.gpa`).
    fn suspendTab(label: []u8) void {
        defer core.gpa.free(label);
        const v = W.findWebview(label) orelse return;
        const view = v.view orelse return;
        const v3 = com.query(c.ICoreWebView2_3, view, &c.IID_ICoreWebView2_3) orelse return;
        defer com.release(@as(?*c.ICoreWebView2_3, v3));
        const h = com.handler(c.ICoreWebView2TrySuspendCompletedHandler, &c.IID_ICoreWebView2TrySuspendCompletedHandler, {}, onSuspended);
        defer com.release(@as(?*c.ICoreWebView2TrySuspendCompletedHandler, h));
        _ = com.call(v3, "TrySuspend", .{h});
    }

    fn onSuspended(_: void, _: c.HRESULT, _: c.BOOL) void {}

    fn viewOf(label: []const u8) ?*c.ICoreWebView2 {
        const v = W.findWebview(label) orelse return null;
        return v.view;
    }

    fn navigate(label: []const u8, url: []const u8) void {
        if (W.findWebview(label)) |v| v.navigate(url);
    }

    fn history(label: []const u8, step: i32) void {
        const view = viewOf(label) orelse return;
        _ = if (step < 0) com.call(view, "GoBack", .{}) else com.call(view, "GoForward", .{});
    }

    fn reload(label: []const u8) void {
        if (viewOf(label)) |view| _ = com.call(view, "Reload", .{});
    }

    fn stop(label: []const u8) void {
        if (viewOf(label)) |view| _ = com.call(view, "Stop", .{});
    }

    /// What Windows says an HRESULT means (allocated in `a`).
    fn hrText(a: Allocator, hr: c.HRESULT) []const u8 {
        var buf: [512]u16 = undefined;
        const n = c.FormatMessageW(c.FORMAT_MESSAGE_FROM_SYSTEM | c.FORMAT_MESSAGE_IGNORE_INSERTS, null, @bitCast(hr), 0, &buf, buf.len, null);
        if (n > 0) if (std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n])) |s| {
            const t = std.mem.trim(u8, s, " \r\n");
            if (t.len > 0) return t;
        } else |_| {};
        return std.fmt.allocPrint(a, "error 0x{x:0>8}", .{@as(u32, @bitCast(hr))}) catch "error";
    }

    fn cdpStart(label: []const u8, method: []const u8, params: []const u8, ans: *Answer) void {
        const view = viewOf(label) orelse return ans.finish(false, "the page is not ready");
        const wm = com.wstr(core.gpa, method) catch return ans.finish(false, "out of memory");
        defer core.gpa.free(wm);
        const wp = com.wstr(core.gpa, params) catch return ans.finish(false, "out of memory");
        defer core.gpa.free(wp);
        const h = com.handler(c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, &c.IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, ans, onCdp);
        defer com.release(@as(?*c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, h));
        // refused at once: the handler is never called
        if (com.call(view, "CallDevToolsProtocolMethod", .{ wm.ptr, wp.ptr, h }) < 0) ans.finish(false, "the page is not ready");
    }

    fn onCdp(ans: *Answer, hr: c.HRESULT, result: c.LPCWSTR) void {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (hr < 0) return ans.finish(false, hrText(a, hr));
        if (result == null) return ans.finish(true, "null");
        const json = std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(@as([*:0]const u16, @ptrCast(result)))) catch return ans.finish(false, "out of memory");
        ans.finish(true, json);
    }

    // ---- the profile: extensions, cache ----

    /// The tabs share the main window's profile, so its webview is enough.
    fn mainView() ?*c.ICoreWebView2 {
        return viewOf(host.main_label);
    }

    fn mainReady() bool {
        return mainView() != null;
    }

    /// The profile as interface `T` (to release), or null on a WebView2 runtime too old for it.
    fn profile(comptime T: type, iid: *const c.IID, view: *c.ICoreWebView2) ?*T {
        const v13 = com.query(c.ICoreWebView2_13, view, &c.IID_ICoreWebView2_13) orelse return null;
        defer com.release(@as(?*c.ICoreWebView2_13, v13));
        var p: ?*c.ICoreWebView2Profile = null;
        _ = com.call(v13, "get_Profile", .{&p});
        const prof = p orelse return null;
        defer com.release(p);
        return com.query(T, prof, iid);
    }

    fn profile7(view: *c.ICoreWebView2) ?*c.ICoreWebView2Profile7 {
        return profile(c.ICoreWebView2Profile7, &c.IID_ICoreWebView2Profile7, view);
    }

    const no_window = "the window is not ready";
    const no_profile = "Extensions need a newer WebView2 runtime.";
    const dropped = "WebView2 dropped the request";

    const ExtList = c.ICoreWebView2BrowserExtensionList;
    const ExtObj = c.ICoreWebView2BrowserExtension;
    const GetHandler = c.ICoreWebView2ProfileGetBrowserExtensionsCompletedHandler;
    const AddHandler = c.ICoreWebView2ProfileAddBrowserExtensionCompletedHandler;
    const EnableHandler = c.ICoreWebView2BrowserExtensionEnableCompletedHandler;
    const RemoveHandler = c.ICoreWebView2BrowserExtensionRemoveCompletedHandler;

    fn extCount(list: [*c]ExtList) u32 {
        if (list == null) return 0;
        var n: c.UINT = 0;
        _ = com.call(list, "get_Count", .{&n});
        return n;
    }

    /// The i-th extension (to release).
    fn extAt(list: [*c]ExtList, i: u32) ?*ExtObj {
        var ext: ?*ExtObj = null;
        _ = com.call(list, "GetValueAtIndex", .{ i, &ext });
        return ext;
    }

    fn extName(a: Allocator, ext: *ExtObj) []const u8 {
        var name: c.LPWSTR = null;
        _ = com.call(ext, "get_Name", .{&name});
        return com.takeString(a, name) catch "";
    }

    fn extInfo(a: Allocator, ext: *ExtObj) Ext {
        var id: c.LPWSTR = null;
        var on: c.BOOL = 0;
        _ = com.call(ext, "get_Id", .{&id});
        _ = com.call(ext, "get_IsEnabled", .{&on});
        return .{ .id = com.takeString(a, id) catch "", .name = extName(a, ext), .enabled = on != 0 };
    }

    /// Every extension in the Web tabs' profile → `ans` (a JSON list of `Ext`).
    fn extensionsStart(ans: *Answer) void {
        const view = mainView() orelse return ans.finish(false, no_window);
        const p = profile7(view) orelse return ans.finish(false, no_profile);
        defer com.release(@as(?*c.ICoreWebView2Profile7, p));
        const h = com.handler(GetHandler, &c.IID_ICoreWebView2ProfileGetBrowserExtensionsCompletedHandler, ans, onExtensions);
        defer com.release(@as(?*GetHandler, h));
        if (com.call(p, "GetBrowserExtensions", .{h}) < 0) ans.finish(false, dropped);
    }

    fn onExtensions(ans: *Answer, hr: c.HRESULT, list: [*c]ExtList) void {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (hr < 0) return ans.finish(false, hrText(a, hr));
        var out: std.ArrayList(Ext) = .empty;
        for (0..extCount(list)) |i| {
            const ext = extAt(list, @intCast(i)) orelse continue;
            defer com.release(@as(?*ExtObj, ext));
            out.append(a, extInfo(a, ext)) catch {};
        }
        ans.finish(true, core.toJson(a, out.items) catch "[]");
    }

    /// Loads an unpacked extension folder into the profile → `ans` (an `Ext` as JSON).
    fn addExtensionStart(dir: []const u8, ans: *Answer) void {
        const view = mainView() orelse return ans.finish(false, no_window);
        const p = profile7(view) orelse return ans.finish(false, no_profile);
        defer com.release(@as(?*c.ICoreWebView2Profile7, p));
        const wdir = com.wstr(core.gpa, dir) catch return ans.finish(false, "out of memory");
        defer core.gpa.free(wdir);
        const h = com.handler(AddHandler, &c.IID_ICoreWebView2ProfileAddBrowserExtensionCompletedHandler, ans, onExtensionAdded);
        defer com.release(@as(?*AddHandler, h));
        if (com.call(p, "AddBrowserExtension", .{ wdir.ptr, h }) < 0) ans.finish(false, "WebView2 refused the extension");
    }

    fn onExtensionAdded(ans: *Answer, hr: c.HRESULT, ext: [*c]ExtObj) void {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (hr < 0) return ans.finish(false, std.fmt.allocPrint(a, "WebView2 refused the extension: {s}", .{hrText(a, hr)}) catch "WebView2 refused the extension");
        if (ext == null) return ans.finish(false, "WebView2 refused the extension");
        ans.finish(true, core.toJson(a, extInfo(a, ext)) catch return ans.finish(false, "out of memory"));
    }

    const Op = struct {
        ans: *Answer,
        /// owned by `core.gpa`
        id: []u8,
        on: ?bool,
    };

    /// Switches an extension on / off, or removes it from the profile (`on` null) → `ans`.
    fn extensionOpStart(id: []const u8, on: ?bool, ans: *Answer) void {
        const view = mainView() orelse return ans.finish(false, no_window);
        const p = profile7(view) orelse return ans.finish(false, no_profile);
        defer com.release(@as(?*c.ICoreWebView2Profile7, p));
        const op: Op = .{ .ans = ans, .id = core.gpa.dupe(u8, id) catch return ans.finish(false, "out of memory"), .on = on };
        const h = com.handler(GetHandler, &c.IID_ICoreWebView2ProfileGetBrowserExtensionsCompletedHandler, op, onOpList);
        defer com.release(@as(?*GetHandler, h));
        if (com.call(p, "GetBrowserExtensions", .{h}) < 0) {
            core.gpa.free(op.id);
            ans.finish(false, dropped);
        }
    }

    fn onOpList(op: Op, _: c.HRESULT, list: [*c]ExtList) void {
        defer core.gpa.free(op.id);
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ext = for (0..extCount(list)) |i| {
            const e = extAt(list, @intCast(i)) orelse continue;
            if (std.mem.eql(u8, extInfo(a, e).id, op.id)) break e;
            com.release(@as(?*ExtObj, e));
        } else return op.ans.finish(false, "that extension is not installed any more");
        defer com.release(@as(?*ExtObj, ext));
        const hr = if (op.on) |on| blk: {
            const h = handler1(EnableHandler, &c.IID_ICoreWebView2BrowserExtensionEnableCompletedHandler, op.ans, onOpDone);
            defer com.release(@as(?*EnableHandler, h));
            break :blk com.call(ext, "Enable", .{ @as(c.BOOL, @intFromBool(on)), h });
        } else blk: {
            const h = handler1(RemoveHandler, &c.IID_ICoreWebView2BrowserExtensionRemoveCompletedHandler, op.ans, onOpDone);
            defer com.release(@as(?*RemoveHandler, h));
            break :blk com.call(ext, "Remove", .{h});
        };
        if (hr < 0) op.ans.finish(false, hrText(a, hr));
    }

    fn onOpDone(ans: *Answer, hr: c.HRESULT) void {
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        if (hr < 0) ans.finish(false, hrText(arena.allocator(), hr)) else ans.finish(true, "");
    }

    fn ignore(_: void, _: c.HRESULT) void {}

    /// Switches an extension on / off, not waiting for the outcome.
    fn enableExt(ext: *ExtObj, on: bool) void {
        const h = handler1(EnableHandler, &c.IID_ICoreWebView2BrowserExtensionEnableCompletedHandler, {}, ignore);
        defer com.release(@as(?*EnableHandler, h));
        _ = com.call(ext, "Enable", .{ @as(c.BOOL, @intFromBool(on)), h });
    }

    fn removeExt(ext: *ExtObj) void {
        const h = handler1(RemoveHandler, &c.IID_ICoreWebView2BrowserExtensionRemoveCompletedHandler, {}, ignore);
        defer com.release(@as(?*RemoveHandler, h));
        _ = com.call(ext, "Remove", .{h});
    }

    /// uBlock Origin Lite in the profile: added (or swapped for the release on disk when that is newer),
    /// then turned on or off as the setting says. The full uBlock Origin earlier versions added goes.
    fn syncUblock() void {
        const p = (if (mainView()) |view| profile7(view) else null) orelse
            return setAdblockStatus("Ad blocking needs a newer WebView2 runtime.", .{});
        // the handler keeps the profile (to add the extension) and releases it
        const h = com.handler(GetHandler, &c.IID_ICoreWebView2ProfileGetBrowserExtensionsCompletedHandler, p, onUblockList);
        defer com.release(@as(?*GetHandler, h));
        if (com.call(p, "GetBrowserExtensions", .{h}) < 0) com.release(@as(?*c.ICoreWebView2Profile7, p));
    }

    fn onUblockList(p: *c.ICoreWebView2Profile7, _: c.HRESULT, list: [*c]ExtList) void {
        defer com.release(@as(?*c.ICoreWebView2Profile7, p));
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const on = settings.adBlock();
        var ours: ?*ExtObj = null;
        defer com.release(ours);
        for (0..extCount(list)) |i| {
            const ext = extAt(list, @intCast(i)) orelse continue;
            const name = extName(a, ext);
            if (std.mem.startsWith(u8, name, adblock.NAME)) {
                com.release(ours);
                ours = ext;
                continue;
            }
            if (std.mem.startsWith(u8, name, adblock.OLD_NAME)) removeExt(ext);
            com.release(@as(?*ExtObj, ext));
        }
        const disk = adblock.installed(a) orelse {
            // nothing downloaded (yet): keep whatever the profile has
            if (ours) |ext| enableExt(ext, on);
            return;
        };
        if (ours) |ext| {
            if (adblock.loadedTag(a)) |loaded| if (std.mem.eql(u8, loaded, disk.tag)) {
                enableExt(ext, on);
                return setAdblockStatus("{s} {s}", .{ adblock.NAME, disk.tag });
            };
            removeExt(ext);
        }
        const wdir = com.wstr(a, disk.dir) catch return;
        const added: Added = .{ .tag = core.gpa.dupe(u8, disk.tag) catch return, .on = on };
        const h = com.handler(AddHandler, &c.IID_ICoreWebView2ProfileAddBrowserExtensionCompletedHandler, added, onUblockAdded);
        defer com.release(@as(?*AddHandler, h));
        if (com.call(p, "AddBrowserExtension", .{ wdir.ptr, h }) < 0) {
            setAdblockStatus("WebView2 refused {s} {s}", .{ adblock.NAME, added.tag });
            core.gpa.free(added.tag);
        }
    }

    const Added = struct {
        /// owned by `core.gpa`
        tag: []u8,
        on: bool,
    };

    fn onUblockAdded(added: Added, hr: c.HRESULT, ext: [*c]ExtObj) void {
        defer core.gpa.free(added.tag);
        if (hr < 0 or ext == null) {
            var arena: std.heap.ArenaAllocator = .init(core.gpa);
            defer arena.deinit();
            return setAdblockStatus("WebView2 refused {s} {s}: {s}", .{ adblock.NAME, added.tag, hrText(arena.allocator(), hr) });
        }
        adblock.setLoadedTag(added.tag);
        if (!added.on) enableExt(ext, false);
        setAdblockStatus("{s} {s}", .{ adblock.NAME, added.tag });
    }

    /// Starts clearing the cached files; `ans` is finished when that is done (or cannot be
    /// done). False — and `ans` let go — without a main window.
    fn clearCacheStart(ans: *Answer) bool {
        const view = mainView() orelse {
            ans.drop();
            return false;
        };
        const p = profile(c.ICoreWebView2Profile2, &c.IID_ICoreWebView2Profile2, view) orelse {
            ans.finish(true, "");
            return true;
        };
        defer com.release(@as(?*c.ICoreWebView2Profile2, p));
        const kinds: c.COREWEBVIEW2_BROWSING_DATA_KINDS = @intCast(c.COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE | c.COREWEBVIEW2_BROWSING_DATA_KINDS_CACHE_STORAGE | c.COREWEBVIEW2_BROWSING_DATA_KINDS_SERVICE_WORKERS);
        const h = handler1(c.ICoreWebView2ClearBrowsingDataCompletedHandler, &c.IID_ICoreWebView2ClearBrowsingDataCompletedHandler, ans, onCacheCleared);
        defer com.release(@as(?*c.ICoreWebView2ClearBrowsingDataCompletedHandler, h));
        if (com.call(p, "ClearBrowsingData", .{ kinds, h }) < 0) ans.finish(true, "");
        return true;
    }

    fn onCacheCleared(ans: *Answer, _: c.HRESULT) void {
        ans.finish(true, "");
    }

    const IID_IUnknown: c.IID = .{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
    const IID_IAgileObject: c.IID = .{ .Data1 = 0x94ea2b94, .Data2 = 0xe9cc, .Data3 = 0x49e0, .Data4 = .{ 0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90 } };

    /// `com.handler` for the completion handlers whose `Invoke(This, errorCode)` carries nothing
    /// but the HRESULT (`com.handler` expects two arguments). `f(ctx, hr)`.
    fn handler1(comptime Iface: type, iid: *const c.IID, ctx: anytype, comptime f: anytype) *Iface {
        const Ctx = @TypeOf(ctx);
        const Vtbl = @typeInfo(@FieldType(Iface, "lpVtbl")).pointer.child;
        const Obj = struct {
            iface: Iface,
            refs: std.atomic.Value(u32),
            ctx: Ctx,
            iid: *const c.IID,
            const vtbl: Vtbl = .{
                .QueryInterface = qi,
                .AddRef = addRefImpl,
                .Release = releaseImpl,
                .Invoke = invoke,
            };
            fn self(this: [*c]Iface) *@This() {
                return @fieldParentPtr("iface", @as(*Iface, @ptrCast(this)));
            }
            fn qi(this: [*c]Iface, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
                const s = self(this);
                if (com.eqlGuid(riid, &IID_IUnknown) or com.eqlGuid(riid, s.iid) or com.eqlGuid(riid, &IID_IAgileObject)) {
                    _ = s.refs.fetchAdd(1, .monotonic);
                    out.* = @ptrCast(this);
                    return com.S_OK;
                }
                out.* = null;
                return com.E_NOINTERFACE;
            }
            fn addRefImpl(this: [*c]Iface) callconv(.c) c.ULONG {
                return self(this).refs.fetchAdd(1, .monotonic) + 1;
            }
            fn releaseImpl(this: [*c]Iface) callconv(.c) c.ULONG {
                const s = self(this);
                const n = s.refs.fetchSub(1, .acq_rel) - 1;
                if (n == 0) std.heap.c_allocator.destroy(s);
                return n;
            }
            fn invoke(this: [*c]Iface, hr: c.HRESULT) callconv(.c) c.HRESULT {
                f(self(this).ctx, hr);
                return com.S_OK;
            }
        };
        const o = std.heap.c_allocator.create(Obj) catch @panic("oom");
        o.* = .{ .iface = .{ .lpVtbl = @constCast(&Obj.vtbl) }, .refs = .init(1), .ctx = ctx, .iid = iid };
        return &o.iface;
    }
};

// ---------------- tests ----------------

fn expectKey(key: []const u8, want: Key) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try keyInfo(arena.allocator(), key);
    try std.testing.expectEqualStrings(want.key, got.key);
    try std.testing.expectEqualStrings(want.code, got.code);
    try std.testing.expectEqual(want.vk, got.vk);
    if (want.text) |t| try std.testing.expectEqualStrings(t, got.text.?) else try std.testing.expect(got.text == null);
}

test "keys" {
    try expectKey("Enter", .{ .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" });
    try expectKey("RETURN", .{ .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" });
    try expectKey("Esc", .{ .key = "Escape", .code = "Escape", .vk = 27 });
    try expectKey("Down", .{ .key = "ArrowDown", .code = "ArrowDown", .vk = 40 });
    try expectKey("PageDown", .{ .key = "PageDown", .code = "PageDown", .vk = 34 });
    try expectKey(" ", .{ .key = " ", .code = "Space", .vk = 32, .text = " " });
    try expectKey("space", .{ .key = " ", .code = "Space", .vk = 32, .text = " " });
    try expectKey("a", .{ .key = "a", .code = "KeyA", .vk = 'A', .text = "a" });
    try expectKey("Z", .{ .key = "Z", .code = "KeyZ", .vk = 'Z', .text = "Z" });
    try expectKey("7", .{ .key = "7", .code = "Digit7", .vk = '7', .text = "7" });
    try expectKey("?", .{ .key = "?", .code = "", .vk = 0, .text = "?" });
    try expectKey("đ", .{ .key = "đ", .code = "", .vk = 0, .text = "đ" });
    // one letter is that letter, not a function key
    try expectKey("f", .{ .key = "f", .code = "KeyF", .vk = 'F', .text = "f" });
    try expectKey("F5", .{ .key = "F5", .code = "F5", .vk = 116 });
    try expectKey("f12", .{ .key = "F12", .code = "F12", .vk = 123 });
    try expectKey("F13", .{ .key = "F13", .code = "F13", .vk = 0 });
    try expectKey("f0", .{ .key = "f0", .code = "f0", .vk = 0 });
    try expectKey("Insert", .{ .key = "Insert", .code = "Insert", .vk = 0 });
    try expectKey("", .{ .key = "", .code = "", .vk = 0 });
}

test "truncChars" {
    try std.testing.expectEqualStrings("abc", truncChars("abcdef", 3));
    try std.testing.expectEqualStrings("abc", truncChars("abc", 600));
    try std.testing.expectEqualStrings("đư", truncChars("đường", 2));
    try std.testing.expectEqualStrings("", truncChars("abc", 0));
    // a cut-off sequence at the end is kept, not read past
    try std.testing.expectEqualStrings("a\xc4", truncChars("a\xc4", 5));
}

test "console events become error lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = struct {
        fn f(al: Allocator, event: []const u8, params: []const u8) !?[]const u8 {
            return logLine(al, event, J.parse(al, params));
        }
    }.f;

    try std.testing.expectEqualStrings(
        // an argument with neither a value nor a description is an empty word
        "console.error: boom {\"a\":1} 42 Error: x  (http://localhost/app.js:13)",
        (try line(a, "Runtime.consoleAPICalled",
            \\{"type":"error","args":[{"type":"string","value":"boom"},{"type":"object","value":{"a":1}},{"type":"number","value":42},{"type":"object","description":"Error: x"},{"type":"undefined"}],
            \\ "stackTrace":{"callFrames":[{"url":"http://localhost/app.js","lineNumber":12}]}}
        )).?,
    );
    try std.testing.expectEqualStrings("console.warning: careful", (try line(a, "Runtime.consoleAPICalled", "{\"type\":\"warning\",\"args\":[{\"value\":\"careful\"}],\"stackTrace\":{\"callFrames\":[{\"url\":\"\"}]}}")).?);
    try std.testing.expectEqualStrings("console.assert: ", (try line(a, "Runtime.consoleAPICalled", "{\"type\":\"assert\"}")).?);
    try std.testing.expect((try line(a, "Runtime.consoleAPICalled", "{\"type\":\"log\",\"args\":[{\"value\":\"hi\"}]}")) == null);
    try std.testing.expect((try line(a, "Runtime.consoleAPICalled", "not json")) == null);

    try std.testing.expectEqualStrings("uncaught: TypeError: x is not a function\n    at a.js:1", (try line(a, "Runtime.exceptionThrown", "{\"exceptionDetails\":{\"text\":\"Uncaught\",\"exception\":{\"description\":\"TypeError: x is not a function\\n    at a.js:1\"}}}")).?);
    try std.testing.expectEqualStrings("uncaught: Uncaught", (try line(a, "Runtime.exceptionThrown", "{\"exceptionDetails\":{\"text\":\"Uncaught\"}}")).?);
    try std.testing.expectEqualStrings("uncaught: exception", (try line(a, "Runtime.exceptionThrown", "{}")).?);

    try std.testing.expectEqualStrings(
        "network: Failed to load resource: 404 (http://localhost/x.png)",
        (try line(a, "Log.entryAdded", "{\"entry\":{\"source\":\"network\",\"level\":\"error\",\"text\":\"Failed to load resource: 404\",\"url\":\"http://localhost/x.png\"}}")).?,
    );
    try std.testing.expectEqualStrings("log: bad", (try line(a, "Log.entryAdded", "{\"entry\":{\"level\":\"error\",\"text\":\"bad\"}}")).?);
    try std.testing.expect((try line(a, "Log.entryAdded", "{\"entry\":{\"level\":\"warning\",\"text\":\"meh\"}}")) == null);
    try std.testing.expect((try line(a, "Page.loadEventFired", "{}")) == null);
}

test "a tab's error list" {
    core.gpa = std.testing.allocator;
    core.io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer logs.deinit(core.gpa);

    try std.testing.expectEqual(@as(usize, 0), errors(a, "t1", null).len);
    record(a, "t1", "Runtime.exceptionThrown", "{\"exceptionDetails\":{\"text\":\"first\"}}");
    record(a, "t1", "Runtime.consoleAPICalled", "{\"type\":\"log\"}");
    record(a, "t2", "Log.entryAdded", "{\"entry\":{\"level\":\"error\",\"text\":\"other tab\"}}");
    const all = errors(a, "t1", null);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    try std.testing.expectEqualStrings("uncaught: first", all[0]);
    try std.testing.expectEqual(@as(usize, 0), errors(a, "t1", core.monoMs() + 1000).len);
    try std.testing.expectEqual(@as(usize, 1), errors(a, "t1", 0).len);

    // long lines are cut, and only the last 50 are kept
    var many: std.ArrayList(u8) = .empty;
    for (0..700) |_| try many.appendSlice(a, "đ");
    const long = try std.fmt.allocPrint(a, "{{\"exceptionDetails\":{{\"text\":\"{s}\"}}}}", .{many.items});
    record(a, "t1", "Runtime.exceptionThrown", long);
    try std.testing.expectEqual(@as(usize, 600), try std.unicode.utf8CountCodepoints(errors(a, "t1", null)[1]));
    for (0..60) |i| record(a, "t1", "Runtime.exceptionThrown", try std.fmt.allocPrint(a, "{{\"exceptionDetails\":{{\"text\":\"e{d}\"}}}}", .{i}));
    const kept = errors(a, "t1", null);
    try std.testing.expectEqual(@as(usize, 50), kept.len);
    try std.testing.expectEqualStrings("uncaught: e10", kept[0]);
    try std.testing.expectEqualStrings("uncaught: e59", kept[49]);

    // a new document: the old page's errors no longer apply
    record(a, "t1", "Runtime.executionContextsCleared", "{}");
    try std.testing.expectEqual(@as(usize, 0), errors(a, "t1", null).len);
    try std.testing.expectEqual(@as(usize, 1), errors(a, "t2", null).len);
    clearLogs("t2");
}

test "a chat's tools find its tab, or wait for it" {
    core.gpa = std.testing.allocator;
    core.io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer {
        closeTabState("web-1");
        closeTabState("web-2");
        tabs.deinit(core.gpa);
        active.deinit(core.gpa);
        waiters.deinit(core.gpa);
    }
    var fail: core.Fail = .{};

    // no tab yet, and none comes
    try std.testing.expectError(error.Failed, activeTab(a, "chat-1", 30, &fail));
    try std.testing.expect(std.mem.startsWith(u8, fail.msg, "This chat's Web tab did not open"));
    try std.testing.expectEqual(@as(usize, 0), waiters.items.len);

    // the page opens the tab while the tool waits
    const Opener = struct {
        fn run() void {
            while (true) {
                active_mutex.lock();
                const waiting = waiters.items.len;
                active_mutex.unlock();
                if (waiting > 0) break;
                core.sleepMs(5);
            }
            insertTab("web-1", "chat-1") catch {};
            setActive("chat-1", "web-1") catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Opener.run, .{});
    const got = activeTab(a, "chat-1", 10_000, &fail);
    t.join();
    try std.testing.expectEqualStrings("web-1", try got);

    // already open: no waiting; the tab last made active wins
    try std.testing.expectEqualStrings("web-1", try activeTab(a, "chat-1", 0, &fail));
    try insertTab("web-2", "chat-1");
    try setActive("chat-1", "web-2");
    try std.testing.expectEqualStrings("web-2", try activeTab(a, "chat-1", 0, &fail));
    try std.testing.expect(!isVisible("web-2"));

    // a closed tab is no chat's active tab any more
    closeTabState("web-2");
    try std.testing.expectError(error.Failed, activeTab(a, "chat-1", 30, &fail));

    // the page names the active tab before its page exists: the tool goes on once it does
    const Late = struct {
        fn run() void {
            while (true) {
                active_mutex.lock();
                const waiting = waiters.items.len;
                active_mutex.unlock();
                if (waiting > 0) break;
                core.sleepMs(5);
            }
            setActive("chat-2", "web-3") catch {};
            core.sleepMs(30);
            insertTab("web-3", "chat-2") catch {};
            announce("web-3");
        }
    };
    const t2 = try std.Thread.spawn(.{}, Late.run, .{});
    const late_tab = activeTab(a, "chat-2", 10_000, &fail);
    t2.join();
    try std.testing.expectEqualStrings("web-3", try late_tab);
    closeTabState("web-3");
}

/// `closeTab` without the page (tests have no WebView2).
fn closeTabState(label: []const u8) void {
    tabs_mutex.lock();
    const tab = tabs.fetchRemove(label);
    tabs_mutex.unlock();
    const kv = tab orelse return;
    core.gpa.free(kv.key);
    core.gpa.free(kv.value.chat);
    forgetActive(label);
}

test {
    _ = @import("browser_json.zig");
}
