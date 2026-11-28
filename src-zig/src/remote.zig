//! Phone remote: the VIBE CODE Android app (../android) drives this window over the local network.
//!
//! The phone app is a thin shell: it finds this computer with a UDP broadcast ("VIBECODE?" on
//! `port`, answered with the name and port), then shows `/remote.html` from here, so the remote
//! page always matches this version. Pairing: the user opens the phone panel in the status bar,
//! which shows a 6-digit PIN for a few minutes; the phone trades it (POST /pair) for a token of its
//! own, kept on the phone. Only a hash of the token is stored here.
//!
//! This side is a transport: every message a paired phone sends on `/ws` goes to the page as
//! `remote:cmd` (client id, message) and the page answers with `remote_push`. Chats, terminals
//! and transcripts are the page's (src/renderer/src/remote.ts).
//!
//! Off by default. Once turned on the listener stays until the app quits; turned off, it answers
//! nothing and every phone is dropped.
//!
//! From outside the local network: a Cloudflare quick tunnel (see "from the Internet" below).
//! The screen itself, with mouse and keyboard, when allowed: remote_desk.zig.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const http = @import("http.zig");
const desk = @import("remote_desk.zig");
const assets = @import("assets");
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const WebSocket = std.http.Server.WebSocket;

pub const commands = .{
    .{ "remote_state", remote_state },
    .{ "remote_enable", remote_enable },
    .{ "remote_pin", remote_pin },
    .{ "remote_revoke", remote_revoke },
    .{ "remote_push", remote_push },
    .{ "remote_tunnel", remote_tunnel },
    .{ "remote_desktop", remote_desktop },
};

/// TCP (HTTP + WebSocket) and UDP (discovery) — android/src/vibe/remote/Main.java has the same
pub const port: u16 = 47717;
const discover_ask = "VIBECODE?";
const pin_ms = 5 * 60 * 1000;
const pin_tries = 5;
/// a phone that stops reading is dropped rather than held in memory
const queue_max = 16 << 20;

pub fn init() void {
    mutex.lock();
    load();
    const on = enabled;
    mutex.unlock();
    if (on) startServer();
    mutex.lock();
    startTunnel();
    mutex.unlock();
    core.spawn(killLeftover, .{});
}

pub fn deinit() void {
    mutex.lock();
    enabled = false;
    mutex.unlock();
    dropClients(null);
}

// ---------------- paired phones (remote.json) ----------------

const Device = struct {
    id: []const u8,
    name: []const u8,
    /// sha256 of the phone's token, hex
    hash: []const u8,
    at: u64,
};

const Saved = struct {
    enabled: bool = false,
    /// reachable from the Internet too
    tunnel: bool = false,
    /// phones may see the screen and use the mouse and keyboard
    desktop: bool = false,
    devices: []const Device = &.{},
};

var mutex: core.Mutex = .{};
var loaded = false;
var enabled = false;
/// every string owned by `devices_arena`. Under `mutex`.
var devices: std.ArrayList(Device) = .empty;
var devices_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var pin: ?[6]u8 = null;
var pin_until: u64 = 0;
var pin_fails: u32 = 0;
var listening = false;
var desktop_on = false;
var problem: ?[]const u8 = null;

fn file(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"remote.json"});
}

/// Holding `mutex`.
fn load() void {
    if (loaded) return;
    loaded = true;
    const a = devices_arena.allocator();
    const path = file(a) catch return;
    const bytes = core.readFileAlloc(a, path, 1 << 20) catch return;
    const saved = core.fromJson(Saved, a, bytes) catch return;
    enabled = saved.enabled;
    tunnel_on = saved.tunnel;
    desktop_on = saved.desktop;
    devices.appendSlice(core.gpa, saved.devices) catch {};
}

/// Holding `mutex`.
fn save() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json = core.toJson(a, Saved{ .enabled = enabled, .tunnel = tunnel_on, .desktop = desktop_on, .devices = devices.items }) catch return;
    core.writeAtomic(file(a) catch return, json) catch |e| std.log.warn("remote.json: {s}", .{@errorName(e)});
}

fn hashHex(token: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// The device a token belongs to (its id, in `a`), or null.
fn deviceOf(a: Allocator, token: []const u8) ?[]const u8 {
    const h = hashHex(token);
    mutex.lock();
    defer mutex.unlock();
    if (!enabled) return null;
    for (devices.items) |d| if (d.hash.len == 64 and std.crypto.timing_safe.eql([64]u8, h, d.hash[0..64].*)) return a.dupe(u8, d.id) catch null;
    return null;
}

/// A new device for a correct PIN: its token (in `a`). Null for a wrong or expired PIN.
fn pair(a: Allocator, given: []const u8, name: []const u8) ?struct { token: []const u8, id: []const u8 } {
    mutex.lock();
    defer mutex.unlock();
    if (!enabled) return null;
    const want = pin orelse return null;
    if (core.nowMs() > pin_until) {
        pin = null;
        return null;
    }
    if (given.len != want.len or !std.crypto.timing_safe.eql([6]u8, want, given[0..6].*)) {
        pin_fails += 1;
        // guessing gets nowhere: a new PIN has to be shown again
        if (pin_fails >= pin_tries) pin = null;
        return null;
    }
    pin = null;
    var raw: [32]u8 = undefined;
    core.io.random(&raw);
    const token = std.fmt.bytesToHex(raw, .lower);
    var idb: [6]u8 = undefined;
    core.io.random(&idb);
    const da = devices_arena.allocator();
    const dev: Device = .{
        .id = da.dupe(u8, &std.fmt.bytesToHex(idb, .lower)) catch return null,
        .name = da.dupe(u8, if (name.len == 0) "Android" else name[0..@min(name.len, 60)]) catch return null,
        .hash = da.dupe(u8, &hashHex(&token)) catch return null,
        .at = core.nowMs(),
    };
    devices.append(core.gpa, dev) catch return null;
    save();
    core.emit("remote:changed", .{});
    return .{ .token = a.dupe(u8, &token) catch return null, .id = a.dupe(u8, dev.id) catch return null };
}

// ---------------- commands ----------------

const DeviceInfo = struct { id: []const u8, name: []const u8, at: u64, online: bool };

const State = struct {
    enabled: bool,
    listening: bool,
    /// why the server could not start
    problem: ?[]const u8,
    port: u16,
    host: []const u8,
    /// this computer's IPv4 addresses, for typing one in on the phone
    addresses: []const []const u8,
    pin: ?[]const u8,
    pinUntil: u64,
    devices: []const DeviceInfo,
    /// phones may see the screen and use the mouse and keyboard
    desktop: bool,
    /// reaching it from the Internet is turned on
    tunnel: bool,
    tunnelPhase: Phase,
    /// https://….trycloudflare.com, once Cloudflare gave one
    tunnelUrl: ?[]const u8,
    tunnelError: ?[]const u8,
    /// while cloudflared downloads
    tunnelDone: u64,
    tunnelTotal: u64,
};

fn state(a: Allocator) !State {
    const addrs = localAddresses(a);
    mutex.lock();
    defer mutex.unlock();
    load();
    const list = try a.alloc(DeviceInfo, devices.items.len);
    for (devices.items, list) |d, *o| o.* = .{ .id = try a.dupe(u8, d.id), .name = try a.dupe(u8, d.name), .at = d.at, .online = online(d.id) };
    const live_pin = if (pin != null and core.nowMs() <= pin_until) pin.? else null;
    return .{
        .enabled = enabled,
        .listening = listening,
        .problem = if (problem) |p| try a.dupe(u8, p) else null,
        .port = port,
        .host = core.getenv("COMPUTERNAME") orelse "PC",
        .addresses = addrs,
        .pin = if (live_pin) |p| try a.dupe(u8, &p) else null,
        .pinUntil = if (live_pin != null) pin_until else 0,
        .devices = list,
        .desktop = desktop_on,
        .tunnel = tunnel_on,
        .tunnelPhase = tunnel_phase,
        .tunnelUrl = if (tunnel_url) |u| try a.dupe(u8, u) else null,
        .tunnelError = if (tunnel_err) |e| try a.dupe(u8, e) else null,
        .tunnelDone = tunnel_done,
        .tunnelTotal = cf_size,
    };
}

fn remote_state(c: *ipc.Call) !State {
    return state(c.arena);
}

fn remote_enable(c: *ipc.Call, args: struct { on: bool }) !State {
    mutex.lock();
    load();
    enabled = args.on;
    if (!args.on) {
        pin = null;
        killTunnel();
    }
    save();
    mutex.unlock();
    if (args.on) {
        startServer();
        mutex.lock();
        startTunnel();
        mutex.unlock();
    } else dropClients(null);
    return state(c.arena);
}

fn remote_tunnel(c: *ipc.Call, args: struct { on: bool }) !State {
    mutex.lock();
    load();
    tunnel_on = args.on;
    save();
    if (args.on) startTunnel() else killTunnel();
    mutex.unlock();
    return state(c.arena);
}

fn remote_desktop(c: *ipc.Call, args: struct { on: bool }) !State {
    mutex.lock();
    load();
    desktop_on = args.on;
    save();
    mutex.unlock();
    if (!args.on) {
        clients_mutex.lock();
        defer clients_mutex.unlock();
        for (clients.items) |cl| {
            cl.desk.stop();
            cl.enqueue(.text, "{\"t\":\"desk.off\"}");
        }
    }
    return state(c.arena);
}

fn desktopAllowed() bool {
    mutex.lock();
    defer mutex.unlock();
    return enabled and desktop_on;
}

/// A fresh PIN for pairing a phone, shown for `pin_ms`.
fn remote_pin(c: *ipc.Call) !State {
    mutex.lock();
    var digits: [6]u8 = undefined;
    var rnd: [6]u8 = undefined;
    core.io.random(&rnd);
    for (&digits, rnd) |*d, r| d.* = '0' + r % 10;
    pin = digits;
    pin_until = core.nowMs() + pin_ms;
    pin_fails = 0;
    mutex.unlock();
    return state(c.arena);
}

fn remote_revoke(c: *ipc.Call, args: struct { id: []const u8 }) !State {
    mutex.lock();
    for (devices.items, 0..) |d, i| if (std.mem.eql(u8, d.id, args.id)) {
        _ = devices.orderedRemove(i);
        break;
    };
    save();
    mutex.unlock();
    dropClients(args.id);
    return state(c.arena);
}

/// The page's answer: `msg` (JSON text) to one phone, or to every phone when `to` is left out.
fn remote_push(_: *ipc.Call, args: struct { to: ?u64 = null, msg: []const u8 }) !void {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    for (clients.items) |cl| if (args.to == null or args.to.? == cl.id) cl.enqueue(.text, args.msg);
}

// ---------------- from the Internet: a Cloudflare quick tunnel ----------------
//
// `cloudflared tunnel --url http://127.0.0.1:<port>` (no Cloudflare account) gives this server a
// public https://<words>.trycloudflare.com address, a new one each time cloudflared starts. So it
// is left running when the app quits or updates: the next start finds it on its metrics port
// (`/quicktunnel` says its address) and the phones' link keeps working; only a reboot changes it.
// It ends when the remote or the tunnel is turned off. Phones still need a token: the address only
// replaces the Wi-Fi. Paired phones are told the address, so the app can switch to it by itself.
// cloudflared is downloaded once, pinned by version and SHA-256.

const cf_version = "2026.11.2";
const cf_url = "https://github.com/cloudflare/cloudflared/releases/download/" ++ cf_version ++ "/cloudflared-windows-amd64.exe";
const cf_size: u64 = 55_470_800;
const cf_sha256 = "555b46c85582461d189cac30d14ad05480d612613801be9f110b8ce08c5b2113";
/// cloudflared's metrics server: `/quicktunnel` (its address) and `/ready` (connected to Cloudflare)
const cf_metrics = "127.0.0.1:47718";

const Phase = enum { off, download, start, up, failed };

// all under `mutex`
var tunnel_on = false;
var tunnel_phase: Phase = .off;
/// its thread is running
var tunnel_running = false;
var tunnel_url: ?[]u8 = null;
var tunnel_err: ?[]u8 = null;
var tunnel_done: u64 = 0;
/// counts the times it was stopped on purpose
var tunnel_kills: u64 = 0;

/// Frees what `slot` held and keeps a copy of `v` (core.gpa). Holding `mutex`.
fn keep(slot: *?[]u8, v: ?[]const u8) void {
    const copy = if (v) |s| core.gpa.dupe(u8, s) catch null else null;
    if (slot.*) |old| core.gpa.free(old);
    slot.* = copy;
}

fn cfFile(a: Allocator, name: []const u8) ![]u8 {
    return core.dataPath(a, &.{ "cloudflared", name });
}

/// Holding `mutex`.
fn startTunnel() void {
    if (tunnel_running or !enabled or !tunnel_on) return;
    const t = std.Thread.spawn(.{ .stack_size = 512 << 10 }, tunnelLoop, .{}) catch return;
    t.detach();
    tunnel_running = true;
}

/// Ends cloudflared (the one in cloudflared.pid); its thread then stops, or starts it again when
/// it is still wanted. Holding `mutex`.
fn killTunnel() void {
    tunnel_kills += 1;
    killCloudflared();
}

/// The app was started with the tunnel off: one left running by an earlier run goes.
fn killLeftover() void {
    mutex.lock();
    defer mutex.unlock();
    if (!enabled or !tunnel_on) killCloudflared();
}

fn killCloudflared() void {
    if (!core.is_windows) return;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pid_file = cfFile(a, "cloudflared.pid") catch return;
    const text = core.readFileAlloc(a, pid_file, 64) catch return;
    std.Io.Dir.cwd().deleteFile(core.io, pid_file) catch {};
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \r\n"), 10) catch return;
    const c = core.host.win.c;
    const h = c.OpenProcess(c.PROCESS_TERMINATE | c.PROCESS_QUERY_LIMITED_INFORMATION | c.SYNCHRONIZE, 0, pid) orelse return;
    defer _ = c.CloseHandle(h);
    // the id may have gone to another program since
    var buf: [1024]u16 = undefined;
    var len: c.DWORD = buf.len;
    if (c.QueryFullProcessImageNameW(h, 0, &buf, &len) == 0) return;
    const name = std.unicode.wtf16LeToWtf8Alloc(a, buf[0..len]) catch return;
    if (!std.ascii.endsWithIgnoreCase(name, "\\cloudflared.exe")) return;
    _ = c.TerminateProcess(h, 1);
    _ = c.WaitForSingleObject(h, 3000);
}

fn tunnelLoop() void {
    while (true) {
        mutex.lock();
        if (!enabled or !tunnel_on) {
            tunnel_running = false;
            tunnel_phase = .off;
            keep(&tunnel_url, null);
            keep(&tunnel_err, null);
            mutex.unlock();
            core.emit("remote:changed", .{});
            return;
        }
        const kills = tunnel_kills;
        mutex.unlock();

        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        var fail: core.Fail = .{};
        runTunnel(arena.allocator(), kills, &fail) catch |e| {
            mutex.lock();
            if (tunnel_kills == kills) {
                tunnel_phase = .failed;
                keep(&tunnel_url, null);
                keep(&tunnel_err, fail.text(e));
                std.log.warn("remote: tunnel: {s}", .{fail.text(e)});
            }
            mutex.unlock();
            core.emit("remote:changed", .{});
            // no network, Cloudflare refused…: again in a while
            _ = pause(kills, 15_000);
        };
    }
}

/// Waits `ms`; false when the tunnel was stopped or turned off meanwhile.
fn pause(kills: u64, ms: u64) bool {
    var waited: u64 = 0;
    while (waited < ms) : (waited += 250) {
        mutex.lock();
        const go_on = tunnel_kills == kills and enabled and tunnel_on;
        mutex.unlock();
        if (!go_on) return false;
        core.sleepMs(250);
    }
    return true;
}

/// Finds the running cloudflared or starts one (downloading it first if need be), then watches
/// it while the tunnel stays on. An error when it went away.
fn runTunnel(a: Allocator, kills: u64, fail: *core.Fail) !void {
    if (!core.is_windows) return fail.set(a, "Windows only", .{});
    var host = askAddress(a);
    if (host == null) {
        const exe = try core.dataPath(a, &.{ "cloudflared", cf_version, "cloudflared.exe" });
        if (!core.isFile(exe)) try downloadCloudflared(a, exe, fail);
        mutex.lock();
        tunnel_phase = .start;
        keep(&tunnel_err, null);
        // one that no longer answers
        killCloudflared();
        mutex.unlock();
        core.emit("remote:changed", .{});
        const log_path = try cfFile(a, "cloudflared.log");
        try spawnCloudflared(a, exe, log_path, fail);
        // Cloudflare hands out the address within seconds
        const t0 = core.monoMs();
        while (host == null) {
            if (!pause(kills, 500)) return;
            host = askAddress(a);
            if (host == null and core.monoMs() - t0 > 60_000) {
                const log = core.readFileAlloc(a, log_path, 4 << 20) catch "";
                return fail.set(a, "{s}", .{lastError(log) orelse settings.tr("Cloudflare gave no address", "Cloudflare không cấp địa chỉ")});
            }
        }
    }
    const url = try std.fmt.allocPrint(a, "https://{s}", .{host.?});
    var misses: u32 = 0;
    var shown: ?Phase = null;
    while (true) {
        const ready = askReady(a);
        misses = if (ready != null) 0 else misses + 1;
        // gone: a new one (with a new address)
        if (misses >= 3) return fail.set(a, "{s}", .{settings.tr("cloudflared stopped", "cloudflared đã dừng")});
        // still running but cut off from Cloudflare (no network): it reconnects by itself
        const phase: Phase = if (ready orelse true) .up else .start;
        if (shown != phase) {
            shown = phase;
            mutex.lock();
            if (tunnel_kills != kills) return mutex.unlock();
            tunnel_phase = phase;
            keep(&tunnel_url, url);
            mutex.unlock();
            core.emit("remote:changed", .{});
            if (phase == .up) {
                std.log.info("remote: reachable at {s}", .{url});
                pushTunnel();
            }
        }
        if (!pause(kills, 3000)) return;
    }
}

fn spawnCloudflared(a: Allocator, exe: []const u8, log_path: []const u8, fail: *core.Fail) !void {
    const local = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    var log = try std.Io.Dir.cwd().createFile(core.io, log_path, .{});
    defer log.close(core.io);
    const child = std.process.spawn(core.io, .{
        .argv = &.{ exe, "tunnel", "--no-autoupdate", "--metrics", cf_metrics, "--url", local },
        .cwd = .{ .path = std.fs.path.dirname(exe).? },
        .environ_map = core.cleanEnvShared(),
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .create_no_window = true,
    }) catch |e| return fail.set(a, "{s}: {s}", .{ settings.tr("could not start cloudflared", "không chạy được cloudflared"), @errorName(e) });
    // not waited for: it outlives the app on purpose (see above)
    const handle = child.id.?;
    defer _ = core.host.win.c.CloseHandle(@ptrCast(handle));
    const pid = core.host.win.c.GetProcessId(@ptrCast(handle));
    try core.writeAtomic(try cfFile(a, "cloudflared.pid"), try std.fmt.allocPrint(a, "{d}", .{pid}));
}

const Probe = struct { status: u16, body: []u8 };

/// A GET to cloudflared's metrics server, on a connection of its own (see dbx.zig `local`).
fn probe(a: Allocator, path: []const u8) ?Probe {
    var client: std.http.Client = .{ .allocator = a, .io = core.io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    const url = std.fmt.allocPrint(a, "http://" ++ cf_metrics ++ "{s}", .{path}) catch return null;
    const r = client.fetch(.{ .location = .{ .url = url }, .keep_alive = false, .response_writer = &aw.writer }) catch return null;
    return .{ .status = @intFromEnum(r.status), .body = aw.written() };
}

/// The address of the cloudflared running on `cf_metrics` ("<words>.trycloudflare.com"), if any.
fn askAddress(a: Allocator) ?[]const u8 {
    const r = probe(a, "/quicktunnel") orelse return null;
    if (r.status != 200) return null;
    const j = core.fromJson(struct { hostname: []const u8 = "" }, a, r.body) catch return null;
    return if (validHost(j.hostname)) j.hostname else null;
}

/// null: cloudflared does not answer; false: it runs but has no connection to Cloudflare.
fn askReady(a: Allocator) ?bool {
    const r = probe(a, "/ready") orelse return null;
    const j = core.fromJson(struct { readyConnections: u32 = 0 }, a, r.body) catch return r.status == 200;
    return j.readyConnections > 0;
}

fn validHost(h: []const u8) bool {
    const suffix = ".trycloudflare.com";
    if (h.len <= suffix.len or !std.mem.endsWith(u8, h, suffix)) return false;
    for (h) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '.') return false;
    return true;
}

/// The last "ERR" line of cloudflared's log, without its time stamp.
fn lastError(log: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, log, '\n');
    while (it.next()) |line| if (std.mem.indexOf(u8, line, " ERR ")) |i| {
        const msg = std.mem.trim(u8, line[i + 5 ..], " \r");
        return msg[0..@min(msg.len, 200)];
    };
    return null;
}

/// Tells every phone the address (they keep it for when they are away from the Wi-Fi).
fn pushTunnel() void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const msg = tunnelMsg(arena.allocator()) orelse return;
    clients_mutex.lock();
    defer clients_mutex.unlock();
    for (clients.items) |cl| cl.enqueue(.text, msg);
}

/// `{"t":"tunnel","url":…}` while the tunnel is up.
fn tunnelMsg(a: Allocator) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();
    if (tunnel_phase != .up) return null;
    const url = tunnel_url orelse return null;
    return core.toJson(a, .{ .t = "tunnel", .url = url }) catch null;
}

fn downloadCloudflared(a: Allocator, exe: []const u8, fail: *core.Fail) !void {
    mutex.lock();
    tunnel_phase = .download;
    tunnel_done = 0;
    mutex.unlock();
    core.emit("remote:changed", .{});
    const Dir = std.Io.Dir;
    try core.makePath(std.fs.path.dirname(exe).?);
    const part = try std.mem.concat(a, u8, &.{ exe, ".part" });
    defer Dir.cwd().deleteFile(core.io, part) catch {};
    {
        var out = try Dir.cwd().createFile(core.io, part, .{});
        defer out.close(core.io);
        var file_buf: [64 * 1024]u8 = undefined;
        var fw = out.writer(core.io, &file_buf);
        var hash_buf: [64 * 1024]u8 = undefined;
        var hashed = fw.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);
        const Progress = struct {
            fn onBytes(_: ?*anyopaque, done: u64, _: ?u64) void {
                mutex.lock();
                const show = done >= tunnel_done + cf_size / 100 or done == cf_size;
                if (show) tunnel_done = done;
                mutex.unlock();
                if (show) core.emit("remote:changed", .{});
            }
        };
        const head = http.stream(a, cf_url, .{}, &hashed.writer, Progress.onBytes, null) catch |e|
            return fail.set(a, "github.com: {s}", .{@errorName(e)});
        try fw.interface.flush();
        if (head.status < 200 or head.status >= 300) return fail.set(a, "github.com: HTTP {d}", .{head.status});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower), cf_sha256))
            return fail.set(a, "{s}", .{settings.tr("the cloudflared download is damaged, try again", "bản tải cloudflared bị hỏng, hãy thử lại")});
    }
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), exe, core.io);
}

// ---------------- this computer's addresses ----------------

const AddrInfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: usize,
    canonname: ?[*:0]u8,
    addr: ?*const SockAddrIn,
    next: ?*AddrInfo,
};
const SockAddrIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
extern "ws2_32" fn gethostname(name: [*]u8, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfo, res: *?*AddrInfo) callconv(.winapi) c_int;
extern "ws2_32" fn freeaddrinfo(ai: ?*AddrInfo) callconv(.winapi) void;
extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;

fn localAddresses(a: Allocator) []const []const u8 {
    if (!core.is_windows) return &.{};
    // std.Io reaches the network without Winsock's start-up, which these calls need (a repeat only bumps its count)
    var wsa: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &wsa) != 0) return &.{};
    var name: [256:0]u8 = @splat(0);
    if (gethostname(&name, name.len) != 0) return &.{};
    const hints: AddrInfo = .{ .flags = 0, .family = 2, .socktype = 1, .protocol = 0, .addrlen = 0, .canonname = null, .addr = null, .next = null };
    var res: ?*AddrInfo = null;
    if (getaddrinfo(&name, null, &hints, &res) != 0) return &.{};
    defer freeaddrinfo(res);
    var out: std.ArrayList([]const u8) = .empty;
    var it = res;
    while (it) |ai| : (it = ai.next) {
        const sa = ai.addr orelse continue;
        const text = std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ sa.addr[0], sa.addr[1], sa.addr[2], sa.addr[3] }) catch continue;
        out.append(a, text) catch {};
    }
    return out.items;
}

// ---------------- the server ----------------

/// Starts the listener and the discovery answerer once; they live until the app quits.
fn startServer() void {
    mutex.lock();
    defer mutex.unlock();
    if (listening) return;
    const any = net.IpAddress.parse("0.0.0.0", port) catch unreachable;
    const server = any.listen(core.io, .{ .reuse_address = false }) catch |e| {
        problem = switch (e) {
            error.AddressInUse => settings.tr("Port 47717 is taken by another program", "Cổng 47717 đang bị chương trình khác dùng"),
            else => @errorName(e),
        };
        return;
    };
    const t = std.Thread.spawn(.{}, acceptLoop, .{server}) catch {
        var s = server;
        s.deinit(core.io);
        problem = "could not start a thread";
        return;
    };
    t.detach();
    listening = true;
    problem = null;
    if (std.Thread.spawn(.{ .stack_size = 256 << 10 }, discoverLoop, .{})) |d| d.detach() else |_| {}
}

fn isEnabled() bool {
    mutex.lock();
    defer mutex.unlock();
    return enabled;
}

/// Answers "VIBECODE?" broadcasts with `{"name":…,"port":…}` while the remote is on.
fn discoverLoop() void {
    const any = net.IpAddress.parse("0.0.0.0", port) catch unreachable;
    const sock = any.bind(core.io, .{ .mode = .dgram, .protocol = .udp, .allow_broadcast = true }) catch |e| {
        std.log.warn("remote discovery: {s}", .{@errorName(e)});
        return;
    };
    defer sock.close(core.io);
    var buf: [256]u8 = undefined;
    var reply_buf: [256]u8 = undefined;
    while (true) {
        const msg = sock.receive(core.io, &buf) catch {
            core.sleepMs(200);
            continue;
        };
        if (!std.mem.eql(u8, std.mem.trim(u8, msg.data, " \r\n"), discover_ask) or !isEnabled()) continue;
        var w: std.Io.Writer = .fixed(&reply_buf);
        w.writeAll("{\"app\":\"vibecode\",\"name\":") catch continue;
        std.json.Stringify.encodeJsonString(core.getenv("COMPUTERNAME") orelse "PC", .{}, &w) catch continue;
        w.print(",\"port\":{d}}}", .{port}) catch continue;
        sock.send(core.io, &msg.from, w.buffered()) catch {};
    }
}

fn acceptLoop(listener: net.Server) void {
    var server = listener;
    while (true) {
        const stream = server.accept(core.io) catch |e| {
            if (e == error.SocketNotListening) return;
            core.sleepMs(50);
            continue;
        };
        if (!isEnabled()) {
            stream.close(core.io);
            continue;
        }
        const t = std.Thread.spawn(.{ .stack_size = 1 << 20 }, serve, .{stream}) catch {
            stream.close(core.io);
            continue;
        };
        t.detach();
    }
}

fn serve(stream: net.Stream) void {
    defer stream.close(core.io);
    // a WebSocket message has to fit in the read buffer: a long prompt pasted on the phone
    const in_buf = core.gpa.alloc(u8, 1 << 20) catch return;
    defer core.gpa.free(in_buf);
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(core.io, in_buf);
    var writer = stream.writer(core.io, &out_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        var arena: std.heap.ArenaAllocator = .init(core.gpa);
        defer arena.deinit();
        const upgraded = onRequest(arena.allocator(), &request, stream) catch return;
        if (upgraded or !keep_alive) return;
    }
}

const json_type = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

/// true when the connection became a WebSocket (and has ended)
fn onRequest(a: Allocator, request: *std.http.Server.Request, stream: net.Stream) !bool {
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/ws")) {
        switch (request.upgradeRequested()) {
            .websocket => |key| {
                var ws = try request.respondWebSocket(.{ .key = key orelse return error.BadRequest });
                try ws.flush();
                wsLoop(&ws, stream);
                return true;
            },
            else => {
                try request.respond("", .{ .status = .bad_request });
                return false;
            },
        }
    }

    if (std.mem.eql(u8, path, "/pair")) {
        if (request.head.method != .POST) {
            try request.respond("", .{ .status = .method_not_allowed });
            return false;
        }
        var body_buf: [1024]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buf);
        const body = try body_reader.allocRemaining(a, .limited(4096));
        const req = core.fromJson(struct { pin: []const u8 = "", name: []const u8 = "" }, a, body) catch {
            try request.respond("", .{ .status = .bad_request });
            return false;
        };
        if (pair(a, req.pin, req.name)) |p| {
            try request.respond(try core.toJson(a, .{ .token = p.token, .id = p.id }), .{ .extra_headers = &json_type });
        } else {
            try request.respond(try core.toJson(a, .{ .@"error" = settings.tr("Wrong or expired PIN", "PIN sai hoặc đã hết hạn") }), .{ .status = .forbidden, .extra_headers = &json_type });
        }
        return false;
    }

    // the remote page and the files it loads (nothing else of the app's pages)
    const asset = if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/remote.html"))
        assets.get("/remote.html")
    else if (std.mem.startsWith(u8, path, "/assets/") and std.mem.indexOf(u8, path, "..") == null)
        assets.get(path)
    // what a home screen needs to add it like an app (src/renderer/public/remote-*)
    else if (std.mem.startsWith(u8, path, "/remote-") and std.mem.lastIndexOfScalar(u8, path, '/') == 0)
        assets.get(path)
    else
        null;
    if (asset) |f| {
        try request.respond(f.body, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = f.mime },
            // the hashed file names change with every build; the page itself must not be cached
            .{ .name = "cache-control", .value = if (std.mem.startsWith(u8, path, "/assets/")) "max-age=31536000, immutable" else "no-cache" },
        } });
    } else {
        try request.respond("not found", .{ .status = .not_found });
    }
    return false;
}

// ---------------- connected phones ----------------

const Out = struct { op: WebSocket.Opcode, data: []u8 };

const Client = struct {
    id: u64,
    device: []const u8,
    stream: net.Stream,
    mutex: core.Mutex = .{},
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(Out) = .empty,
    queued: usize = 0,
    closed: bool = false,
    /// its screen view (set up by wsLoop)
    desk: desk.Desk = undefined,

    fn sinkSend(ctx: *anyopaque, op: WebSocket.Opcode, data: []const u8) void {
        const cl: *Client = @ptrCast(@alignCast(ctx));
        cl.enqueue(op, data);
    }

    /// Never blocks: a phone on a slow network must not hold up the page or the other phones.
    fn enqueue(cl: *Client, op: WebSocket.Opcode, data: []const u8) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        if (cl.closed) return;
        if (cl.queued + data.len > queue_max) return cl.closeLocked();
        const copy = core.gpa.dupe(u8, data) catch return cl.closeLocked();
        cl.queue.append(core.gpa, .{ .op = op, .data = copy }) catch {
            core.gpa.free(copy);
            return cl.closeLocked();
        };
        cl.queued += data.len;
        cl.cond.signal(core.io);
    }

    /// Ends the connection: the reader's next read fails and it cleans up. Holding `cl.mutex`.
    fn closeLocked(cl: *Client) void {
        cl.closed = true;
        cl.cond.signal(core.io);
        cl.stream.shutdown(core.io, .both) catch {};
    }

    fn writeLoop(cl: *Client, ws: *WebSocket) void {
        var batch: std.ArrayList(Out) = .empty;
        defer batch.deinit(core.gpa);
        while (true) {
            cl.mutex.lock();
            while (cl.queue.items.len == 0 and !cl.closed) cl.cond.waitUncancelable(core.io, &cl.mutex.m);
            if (cl.closed) return cl.mutex.unlock();
            std.mem.swap(std.ArrayList(Out), &batch, &cl.queue);
            cl.queued = 0;
            cl.mutex.unlock();
            var ok = true;
            for (batch.items) |o| {
                if (ok) ws.writeMessageUnflushed(o.data, o.op) catch {
                    ok = false;
                };
                core.gpa.free(o.data);
            }
            batch.clearRetainingCapacity();
            if (ok) ws.flush() catch {
                ok = false;
            };
            if (!ok) {
                cl.mutex.lock();
                cl.closeLocked();
                cl.mutex.unlock();
                return;
            }
        }
    }
};

var clients_mutex: core.Mutex = .{};
/// authenticated phones. Under `clients_mutex`.
var clients: std.ArrayList(*Client) = .empty;
var next_id: std.atomic.Value(u64) = .init(1);

/// Holding `mutex` (and taking `clients_mutex`).
fn online(device: []const u8) bool {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    for (clients.items) |cl| if (std.mem.eql(u8, cl.device, device)) return true;
    return false;
}

/// Drops every phone (null), or the ones of one device.
fn dropClients(device: ?[]const u8) void {
    clients_mutex.lock();
    defer clients_mutex.unlock();
    for (clients.items) |cl| if (device == null or std.mem.eql(u8, cl.device, device.?)) {
        cl.mutex.lock();
        cl.closeLocked();
        cl.mutex.unlock();
    };
}

/// One phone: `{"t":"auth","token":…}` first, then every message goes to the page.
fn wsLoop(ws: *WebSocket, stream: net.Stream) void {
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = ws.readSmallMessage() catch return;
    const Auth = struct { t: []const u8 = "", token: []const u8 = "" };
    const auth = core.fromJson(Auth, a, first.data) catch return;
    const device = if (std.mem.eql(u8, auth.t, "auth")) deviceOf(a, auth.token) else null;
    if (device == null) {
        ws.writeMessage("{\"t\":\"auth\",\"ok\":false}", .text) catch {};
        return;
    }

    const cl = core.gpa.create(Client) catch return;
    cl.* = .{ .id = next_id.fetchAdd(1, .monotonic), .device = device.?, .stream = stream };
    cl.desk = .{ .sink = .{ .ctx = cl, .send = Client.sinkSend } };
    const writer = std.Thread.spawn(.{ .stack_size = 256 << 10 }, Client.writeLoop, .{ cl, ws }) catch {
        core.gpa.destroy(cl);
        return;
    };
    clients_mutex.lock();
    const added = if (clients.append(core.gpa, cl)) true else |_| false;
    clients_mutex.unlock();
    if (added) {
        cl.enqueue(.text, core.toJson(a, .{ .t = "auth", .ok = true, .client = cl.id }) catch "");
        if (tunnelMsg(a)) |msg| cl.enqueue(.text, msg);
        core.emit("remote:changed", .{});
        readLoop(cl, ws);
    }

    clients_mutex.lock();
    for (clients.items, 0..) |x, i| if (x == cl) {
        _ = clients.swapRemove(i);
        break;
    };
    clients_mutex.unlock();
    cl.desk.stop();
    cl.mutex.lock();
    cl.closeLocked();
    cl.mutex.unlock();
    writer.join();
    const id = cl.id;
    for (cl.queue.items) |o| core.gpa.free(o.data);
    cl.queue.deinit(core.gpa);
    core.gpa.destroy(cl);
    if (added) {
        core.emit("remote:cmd", .{ id, .{ .t = "bye" } });
        core.emit("remote:changed", .{});
    }
}

fn readLoop(cl: *Client, ws: *WebSocket) void {
    while (true) {
        const msg = ws.readSmallMessage() catch return;
        switch (msg.opcode) {
            .ping => cl.enqueue(.pong, msg.data),
            .text => {
                var arena: std.heap.ArenaAllocator = .init(core.gpa);
                defer arena.deinit();
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), msg.data, .{}) catch continue;
                if (v != .object) continue;
                // the screen view is handled here, not by the page
                const t = if (v.object.get("t")) |x| (if (x == .string) x.string else "") else "";
                if (std.mem.startsWith(u8, t, "desk.")) {
                    if (desktopAllowed()) cl.desk.handle(arena.allocator(), t, v.object) else cl.enqueue(.text, "{\"t\":\"desk.off\"}");
                    continue;
                }
                core.emit("remote:cmd", .{ cl.id, v });
            },
            else => {},
        }
    }
}

test "tunnel address and errors" {
    try std.testing.expect(validHost("before-committee-classifieds-hit.trycloudflare.com"));
    try std.testing.expect(!validHost(".trycloudflare.com"));
    try std.testing.expect(!validHost("x.trycloudflare.com/evil"));
    try std.testing.expect(!validHost("example.com"));
    try std.testing.expectEqualStrings("failed to request quick Tunnel: x", lastError("2026-11-28T04:18:05Z INF a\n2026-11-28T04:18:06Z ERR failed to request quick Tunnel: x\r\n2026-11-28T04:18:07Z INF b\n").?);
    try std.testing.expect(lastError("INF only\n") == null);
}

test {
    _ = desk;
}

test "hash is hex sha256" {
    const h = hashHex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}
