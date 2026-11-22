//! Small app-level commands: settings, pickers, attachments, Claude's usage and per-project bypass.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const http = @import("http.zig");
const dialog = @import("dialog.zig");
const settings = @import("settings.zig");
const m = @import("modules.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const commands = .{
    .{ "claude_usage", claude_usage },
    .{ "sys_memory", sys_memory },
    .{ "claude_get_project_bypass", claude_get_project_bypass },
    .{ "claude_set_project_bypass", claude_set_project_bypass },
    .{ "app_settings", app_settings },
    .{ "app_remember_folder", app_remember_folder },
    .{ "app_set_settings", app_set_settings },
    .{ "app_pick_folder", app_pick_folder },
    .{ "app_pick_files", app_pick_files },
    .{ "app_file_info", app_file_info },
    .{ "app_open_external", app_open_external },
    .{ "app_clear_browser_cache", app_clear_browser_cache },
    .{ "app_relaunch", app_relaunch },
    .{ "app_check_update", app_check_update },
    .{ "app_install_update", app_install_update },
    .{ "app_save_image", app_save_image },
    .{ "app_clipboard_files", app_clipboard_files },
    .{ "app_voice_typing", app_voice_typing },
};

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn field(v: ?Value, key: []const u8) ?Value {
    const x = v orelse return null;
    return if (x == .object) x.object.get(key) else null;
}

// ---------------- Claude ----------------

const UsageLimit = struct {
    kind: []const u8,
    label: []const u8,
    percent: i64,
    severity: []const u8,
    resetsAt: ?[]const u8,
};

/// Same numbers as Claude Code's /usage, read with the OAuth login `claude` keeps in
/// ~/.claude/.credentials.json. Read-only: we never refresh the token (Claude Code does).
fn claude_usage(c: *ipc.Call) !?[]UsageLimit {
    return fetchUsage(c.arena) catch null;
}

fn fetchUsage(a: Allocator) ![]UsageLimit {
    const raw = try core.readFileAlloc(a, try std.fs.path.join(a, &.{ core.home(), ".claude", ".credentials.json" }), 4 << 20);
    const creds = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    const token = str(field(field(creds, "claudeAiOauth"), "accessToken")) orelse return error.NoToken;
    const r = try http.get(a, "https://api.anthropic.com/api/oauth/usage", &.{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) },
        .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
    });
    if (!r.ok()) return error.Http;
    const j = try std.json.parseFromSliceLeaky(Value, a, r.body, .{});
    var out: std.ArrayList(UsageLimit) = .empty;
    const limits = field(j, "limits") orelse return out.items;
    if (limits != .array) return out.items;
    for (limits.array.items) |l| {
        const kind = str(field(l, "kind")) orelse "";
        const label = if (std.mem.eql(u8, kind, "session"))
            "5-hour"
        else if (std.mem.eql(u8, kind, "weekly_all"))
            "Weekly"
        else
            try std.fmt.allocPrint(a, "Weekly · {s}", .{str(field(field(field(l, "scope"), "model"), "display_name")) orelse "model"});
        const percent: f64 = if (field(l, "percent")) |p| switch (p) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 0,
        } else 0;
        try out.append(a, .{
            .kind = kind,
            .label = label,
            .percent = @intFromFloat(@round(percent)),
            .severity = str(field(l, "severity")) orelse "",
            .resetsAt = str(field(l, "resets_at")),
        });
    }
    return out.items;
}

/// <project>/.claude/settings.local.json — {} when missing; an error when present but not JSON.
fn readProjectLocal(a: Allocator, folder: []const u8) !Value {
    const empty: Value = .{ .object = .empty };
    const path = try std.fs.path.join(a, &.{ folder, ".claude", "settings.local.json" });
    const raw = core.readFileAlloc(a, path, 16 << 20) catch return empty;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return empty;
    const v = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
    return if (v == .object) v else error.NotAnObject;
}

fn isBypass(s: Value) bool {
    const mode = str(field(field(s, "permissions"), "defaultMode")) orelse return false;
    return std.mem.eql(u8, mode, "bypassPermissions");
}

fn claude_get_project_bypass(c: *ipc.Call, a: struct { folder: []const u8 }) !bool {
    const s = readProjectLocal(c.arena, a.folder) catch return false;
    return isBypass(s);
}

/// Claude Code's own per-project setting `permissions.defaultMode`.
fn claude_set_project_bypass(c: *ipc.Call, a: struct { folder: []const u8, on: bool }) !bool {
    // never overwrite a file we can't parse — that would wipe the user's settings
    var s = readProjectLocal(c.arena, a.folder) catch |e| return c.fail("{s}", .{@errorName(e)});
    var perms: Value = if (field(s, "permissions")) |p| (if (p == .object) p else Value{ .object = .empty }) else .{ .object = .empty };
    if (a.on) {
        try perms.object.put(c.arena, "defaultMode", .{ .string = "bypassPermissions" });
    } else if (isBypass(s)) {
        _ = perms.object.orderedRemove("defaultMode");
    }
    if (perms.object.count() == 0) {
        _ = s.object.orderedRemove("permissions");
    } else {
        try s.object.put(c.arena, "permissions", perms);
    }
    var aw: std.Io.Writer.Allocating = .init(c.arena);
    try std.json.Stringify.value(s, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try core.writeFile(try std.fs.path.join(c.arena, &.{ a.folder, ".claude", "settings.local.json" }), aw.written());
    return a.on;
}

// ---------------- system memory ----------------

const MemInfo = struct { usedBytes: u64, totalBytes: u64 };

/// Physical RAM in use across the whole machine (what Task Manager's Memory shows).
fn sys_memory(_: *ipc.Call) !?MemInfo {
    if (!core.is_windows) return null;
    const w = host.win.c;
    var ms = std.mem.zeroes(w.MEMORYSTATUSEX);
    ms.dwLength = @sizeOf(w.MEMORYSTATUSEX);
    if (w.GlobalMemoryStatusEx(&ms) == 0) return null;
    return .{ .usedBytes = ms.ullTotalPhys - ms.ullAvailPhys, .totalBytes = ms.ullTotalPhys };
}

// ---------------- settings ----------------

fn app_settings(c: *ipc.Call) !settings.AppSettings {
    return settings.get(c.arena);
}

fn app_remember_folder(c: *ipc.Call, a: struct { folder: []const u8 }) !settings.AppSettings {
    return settings.rememberFolder(c.arena, a.folder);
}

fn app_set_settings(c: *ipc.Call, a: struct { patch: Value }) !settings.AppSettings {
    const allowed = [_][]const u8{ "theme", "dropOpacity", "dropHeight", "hideOnBlur", "model", "effort", "permissionMode", "seeThrough", "adBlock", "language" };
    var clean: Value = .{ .object = .empty };
    if (a.patch == .object) for (allowed) |k| {
        if (a.patch.object.get(k)) |v| try clean.object.put(c.arena, k, v);
    };
    var drop_prefs = false;
    for ([_][]const u8{ "dropOpacity", "dropHeight", "hideOnBlur", "language" }) |k| {
        if (clean.object.contains(k)) drop_prefs = true;
    }
    const ad_block = clean.object.contains("adBlock");
    const s = try settings.update(c.arena, try core.toJson(c.arena, clean));
    // the tray menu is rebuilt there too, so a new language shows up in it
    if (drop_prefs and @hasDecl(m.windowing, "applyDropPrefs")) m.windowing.applyDropPrefs();
    if (ad_block and @hasDecl(m.browser, "syncAdblock")) m.browser.syncAdblock();
    return s;
}

// ---------------- pickers + attachments ----------------

fn app_pick_folder(c: *ipc.Call) !?[]u8 {
    return dialog.pickFolder(c.arena, .{});
}

/// Chat "Attach files": Claude Code reads files by path, so only the chosen paths come back.
fn app_pick_files(c: *ipc.Call, a: struct { defaultPath: ?[]const u8 = null }) ![]const []u8 {
    return dialog.pickFiles(c.arena, .{
        .title = settings.tr("Attach files to the chat", "Đính kèm tệp vào chat"),
        .default_path = a.defaultPath,
    });
}

const FileInfo = struct {
    path: []const u8,
    size: i64,
    dir: bool,
    preview: ?[]const u8 = null,

    pub fn jsonStringify(f: FileInfo, w: anytype) !void {
        try w.beginObject();
        try w.objectField("path");
        try w.write(f.path);
        try w.objectField("size");
        try w.write(f.size);
        try w.objectField("dir");
        try w.write(f.dir);
        if (f.preview) |p| {
            try w.objectField("preview");
            try w.write(p);
        }
        try w.endObject();
    }
};

fn imageMime(p: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '.') orelse return null;
    var buf: [8]u8 = undefined;
    if (p.len - i - 1 > buf.len) return null;
    const ext = std.ascii.lowerString(&buf, p[i + 1 ..]);
    const table = .{
        .{ "png", "image/png" },   .{ "jpg", "image/jpeg" }, .{ "jpeg", "image/jpeg" },   .{ "gif", "image/gif" },    .{ "webp", "image/webp" },
        .{ "bmp", "image/bmp" },   .{ "svg", "image/svg+xml" }, .{ "ico", "image/x-icon" }, .{ "avif", "image/avif" },
    };
    inline for (table) |t| if (std.mem.eql(u8, ext, t[0])) return t[1];
    return null;
}

/// Attachment tray: size, folder?, and an image's picture (≤ 15 MB) as a data: URL.
fn app_file_info(c: *ipc.Call, a: struct { paths: []const []const u8 }) ![]FileInfo {
    const out = try c.arena.alloc(FileInfo, a.paths.len);
    for (a.paths, out) |path, *o| {
        const st = std.Io.Dir.cwd().statFile(core.io, path, .{}) catch {
            o.* = .{ .path = path, .size = -1, .dir = false };
            continue;
        };
        const is_file = st.kind == .file;
        var preview: ?[]const u8 = null;
        if (is_file and st.size <= 15 * 1024 * 1024) if (imageMime(path)) |mime| {
            if (core.readFileAlloc(c.arena, path, 16 << 20)) |bytes| {
                const enc = std.base64.standard.Encoder;
                const head = try std.fmt.allocPrint(c.arena, "data:{s};base64,", .{mime});
                const buf = try c.arena.alloc(u8, head.len + enc.calcSize(bytes.len));
                @memcpy(buf[0..head.len], head);
                _ = enc.encode(buf[head.len..], bytes);
                preview = buf;
            } else |_| {}
        };
        o.* = .{ .path = path, .size = if (is_file) @intCast(st.size) else -1, .dir = st.kind == .directory, .preview = preview };
    }
    return out;
}

fn app_open_external(c: *ipc.Call, a: struct { url: []const u8 }) !void {
    if (!std.mem.startsWith(u8, a.url, "http://") and !std.mem.startsWith(u8, a.url, "https://")) return;
    if (core.is_windows) {
        const w = host.win.c;
        _ = w.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), (try core.wide(c.arena, a.url)).ptr, null, null, w.SW_SHOWNORMAL);
    }
}

fn app_clear_browser_cache(c: *ipc.Call) !void {
    if (@hasDecl(m.browser, "clearCache")) m.browser.clearCache() catch |e| return c.fail("{s}", .{@errorName(e)});
}

fn app_relaunch(c: *ipc.Call) !bool {
    // a dev build is restarted by hand
    if (core.debug) return false;
    const exe = try std.process.executablePathAlloc(core.io, c.arena);
    if (@hasDecl(m.pty, "killAll")) m.pty.killAll();
    if (@hasDecl(m.windowing, "releaseInstance")) m.windowing.releaseInstance();
    _ = try std.process.spawn(core.io, .{ .argv = &.{exe}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    quitApp();
    return true;
}

fn quitApp() void {
    if (@hasDecl(m.windowing, "quit")) m.windowing.quit() else host.quit();
}

// ---------------- updates (GitHub releases) ----------------

const releases_url = "https://api.github.com/repos/nguyentrantin98/vibecode/releases/latest";

const Release = struct { version: []const u8, url: []const u8, notes: []const u8 };

/// `a` > `b`, comparing the dot-separated numbers ("0.2.10" > "0.2.9").
fn newerVersion(a: []const u8, b: []const u8) bool {
    var ai = std.mem.splitScalar(u8, a, '.');
    var bi = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x == null and y == null) return false;
        // a shorter list is the smaller one when it is a prefix of the other
        if (x == null) return false;
        if (y == null) return true;
        const xn = std.fmt.parseInt(u64, x.?, 10) catch 0;
        const yn = std.fmt.parseInt(u64, y.?, 10) catch 0;
        if (xn != yn) return xn > yn;
    }
}

/// The newest release's version, installer url and notes, when it is newer than this build.
fn newerRelease(a: Allocator) !?Release {
    const r = try http.get(a, releases_url, &.{.{ .name = "Accept", .value = "application/vnd.github+json" }});
    if (r.status == 404) return null; // no release yet
    if (!r.ok()) return error.Http;
    const j = try std.json.parseFromSliceLeaky(Value, a, r.body, .{});
    const latest = std.mem.trimStart(u8, str(field(j, "tag_name")) orelse "", "v");
    if (!newerVersion(latest, @import("build_options").version)) return null;
    const assets = field(j, "assets") orelse return null;
    if (assets != .array) return null;
    for (assets.array.items) |asset| {
        const name = str(field(asset, "name")) orelse continue;
        if (!std.mem.endsWith(u8, name, "-setup.exe")) continue;
        const url = str(field(asset, "browser_download_url")) orelse continue;
        return .{ .version = latest, .url = url, .notes = std.mem.trim(u8, str(field(j, "body")) orelse "", " \t\r\n") };
    }
    return null;
}

/// The newer version on GitHub and its release notes, or null when this build is the latest.
fn app_check_update(c: *ipc.Call) !?struct { version: []const u8, notes: []const u8 } {
    const r = (newerRelease(c.arena) catch |e| return c.fail("{s}", .{@errorName(e)})) orelse return null;
    return .{ .version = r.version, .notes = r.notes };
}

/// Downloads the newest installer, runs it in passive update mode (it restarts the app) and quits.
fn app_install_update(c: *ipc.Call) !void {
    const r = (newerRelease(c.arena) catch |e| return c.fail("{s}", .{@errorName(e)})) orelse
        return c.failMsg(settings.tr("already up to date", "đã là bản mới nhất"));
    const path = try std.fs.path.join(c.arena, &.{ core.tempDir(), try std.fmt.allocPrint(c.arena, "vibe-code_{s}_setup.exe", .{r.version}) });
    const head = try http.download(c.arena, r.url, .{}, path, null, null);
    if (head.status < 200 or head.status >= 300) return c.fail("HTTP {d}", .{head.status});
    _ = try std.process.spawn(core.io, .{ .argv = &.{ path, "/P", "/R", "/UPDATE" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    if (@hasDecl(m.pty, "killAll")) m.pty.killAll();
    quitApp();
}

/// Pasted / dropped image bytes (raw request body, extension in `x-ext`) → a temp file path.
fn app_save_image(c: *ipc.Call, body: ipc.Raw) ![]const u8 {
    var ext = c.header("x-ext") orelse "png";
    if (ext.len == 0 or ext.len > 5) ext = "png";
    for (ext) |ch| if (!std.ascii.isAlphanumeric(ch)) {
        ext = "png";
        break;
    };
    const file = try std.fs.path.join(c.arena, &.{ core.tempDir(), "tinjs-paste", try std.fmt.allocPrint(c.arena, "image-{d}.{s}", .{ core.nowMs(), ext }) });
    try core.writeFile(file, body.bytes);
    return file;
}

/// Files copied in Explorer (CF_HDROP): a WebView only sees their bytes, never their paths.
fn app_clipboard_files(c: *ipc.Call) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (!core.is_windows) return out.items;
    const w = host.win.c;
    if (w.IsClipboardFormatAvailable(w.CF_HDROP) == 0 or w.OpenClipboard(null) == 0) return out.items;
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_HDROP) orelse return out.items;
    const drop: w.HDROP = @ptrCast(@alignCast(h));
    const n = w.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    var i: w.UINT = 0;
    while (i < n) : (i += 1) {
        var buf: [32768]u16 = undefined;
        const len = w.DragQueryFileW(drop, i, &buf, buf.len);
        try out.append(c.arena, try std.unicode.wtf16LeToWtf8Alloc(c.arena, buf[0..len]));
    }
    return out.items;
}

/// Windows voice typing (Win+H): it types what you say into the focused field.
fn app_voice_typing(_: *ipc.Call) !void {
    if (!core.is_windows) return;
    const w = host.win.c;
    var inputs: [4]w.INPUT = undefined;
    const keys = [_]struct { vk: u16, up: bool }{ .{ .vk = 0x5B, .up = false }, .{ .vk = 0x48, .up = false }, .{ .vk = 0x48, .up = true }, .{ .vk = 0x5B, .up = true } };
    for (keys, &inputs) |k, *in| {
        in.* = std.mem.zeroes(w.INPUT);
        in.type = w.INPUT_KEYBOARD;
        in.unnamed_0.ki = .{ .wVk = k.vk, .wScan = 0, .dwFlags = if (k.up) w.KEYEVENTF_KEYUP else 0, .time = 0, .dwExtraInfo = 0 };
    }
    _ = w.SendInput(inputs.len, &inputs, @sizeOf(w.INPUT));
}

test "newerVersion" {
    const t = std.testing;
    try t.expect(newerVersion("0.2.29", "0.2.28"));
    try t.expect(newerVersion("0.2.10", "0.2.9"));
    try t.expect(newerVersion("1.0", "0.9.9"));
    try t.expect(!newerVersion("0.2.28", "0.2.28"));
    try t.expect(!newerVersion("0.2.27", "0.2.28"));
    try t.expect(!newerVersion("", "0.2.28"));
}

test "imageMime" {
    try std.testing.expectEqualStrings("image/jpeg", imageMime("C:\\x\\Photo.JPG").?);
    try std.testing.expect(imageMime("notes.txt") == null);
    try std.testing.expect(imageMime("noext") == null);
}
