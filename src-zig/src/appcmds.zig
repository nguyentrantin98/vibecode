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
    .{ "claude_api_key", claude_api_key },
    .{ "claude_set_api_key", claude_set_api_key },
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

// ---------------- API key ----------------

/// An Anthropic API key Claude chats can run on instead of the plan's login (when its usage limit
/// is reached): `<userData>/claude-api-key.json`, the key sealed like the other secrets.
const ApiKeyFile = struct { key: []const u8 = "", on: bool = false };

const ApiKeyState = struct {
    /// "sk-ant-…abcd" (never the whole key); null = no key saved
    hint: ?[]const u8 = null,
    /// new Claude chats start with the key
    on: bool = false,
};

fn apiKeyPath(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"claude-api-key.json"});
}

fn readApiKeyFile(a: Allocator) ApiKeyFile {
    const raw = core.readFileAlloc(a, apiKeyPath(a) catch return .{}, 64 << 10) catch return .{};
    return core.fromJson(ApiKeyFile, a, raw) catch .{};
}

fn openApiKey(a: Allocator, f: ApiKeyFile) ?[]u8 {
    if (f.key.len == 0 or !@hasDecl(m.secure, "openStr")) return null;
    return m.secure.openStr(a, f.key) catch null;
}

fn apiKeyState(a: Allocator, f: ApiKeyFile) !ApiKeyState {
    // a key that can't be opened any more (another Windows user / machine) counts as none
    const key = openApiKey(a, f) orelse return .{};
    return .{ .hint = try std.fmt.allocPrint(a, "{s}…{s}", .{ key[0..@min(7, key.len)], key[key.len -| 4..] }), .on = f.on };
}

/// The key a Claude chat starts with (as ANTHROPIC_API_KEY), or null when it is off. Also makes
/// sure Claude Code takes it: an interactive `claude` ignores the variable until the key is
/// approved in its global config (it asks once, and remembers a "No" for good). `env`: the
/// chat's environment (it decides which config that is).
pub fn claudeApiKey(a: Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    const f = readApiKeyFile(a);
    if (!f.on) return null;
    const key = openApiKey(a, f) orelse return null;
    approveApiKey(a, env, key) catch |e| std.log.warn("approving the API key in .claude.json: {s}", .{@errorName(e)});
    return key;
}

/// Claude Code's global config: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
fn claudeGlobalConfig(a: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    return std.fs.path.join(a, &.{ env.get("CLAUDE_CONFIG_DIR") orelse core.home(), ".claude.json" });
}

/// Puts the key's last 20 characters (what Claude Code keeps of it) in
/// `customApiKeyResponses.approved` and out of `.rejected`. Writes only when that changes it.
fn approveApiKey(a: Allocator, env: *const std.process.Environ.Map, key: []const u8) !void {
    const path = try claudeGlobalConfig(a, env);
    const raw = try core.readFileAlloc(a, path, 64 << 20);
    const out = (try approvedConfig(a, raw, key)) orelse return;
    try core.writeAtomic(path, out);
}

/// `raw` with `key` approved, or null when it already is. Numbers stay as they were written.
fn approvedConfig(a: Allocator, raw: []const u8, key: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, key, " \t\r\n");
    const tail = trimmed[trimmed.len -| 20..];
    // never rewrite a file we can't parse: it holds the user's whole Claude Code state
    var cfg = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .parse_numbers = false });
    if (cfg != .object) return error.NotAnObject;
    var resp: Value = if (field(cfg, "customApiKeyResponses")) |r| (if (r == .object) r else .{ .object = .empty }) else .{ .object = .empty };
    var approved: Value = if (field(resp, "approved")) |v| (if (v == .array) v else .{ .array = .init(a) }) else .{ .array = .init(a) };
    var rejected: Value = if (field(resp, "rejected")) |v| (if (v == .array) v else .{ .array = .init(a) }) else .{ .array = .init(a) };

    var changed = for (approved.array.items) |v| {
        if (v == .string and std.mem.eql(u8, v.string, tail)) break false;
    } else true;
    if (changed) try approved.array.append(.{ .string = tail });
    var i: usize = 0;
    while (i < rejected.array.items.len) {
        const v = rejected.array.items[i];
        if (v == .string and std.mem.eql(u8, v.string, tail)) {
            _ = rejected.array.orderedRemove(i);
            changed = true;
        } else i += 1;
    }
    if (!changed) return null;

    try resp.object.put(a, "approved", approved);
    try resp.object.put(a, "rejected", rejected);
    try cfg.object.put(a, "customApiKeyResponses", resp);
    var aw: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2 }, &aw.writer);
    return aw.written();
}

fn claude_api_key(c: *ipc.Call) !ApiKeyState {
    return apiKeyState(c.arena, readApiKeyFile(c.arena));
}

/// `key`: a new key ("" removes it; null keeps the saved one). `on`: whether new Claude chats use it.
fn claude_set_api_key(c: *ipc.Call, a: struct { key: ?[]const u8 = null, on: ?bool = null }) !ApiKeyState {
    var f = readApiKeyFile(c.arena);
    if (a.key) |k| {
        const key = std.mem.trim(u8, k, " \t\r\n");
        if (key.len == 0) {
            f = .{};
        } else {
            if (!std.mem.startsWith(u8, key, "sk-ant-"))
                return c.failMsg(settings.tr("That is not an Anthropic API key (they start with sk-ant-).", "Đây không phải API key của Anthropic (key bắt đầu bằng sk-ant-)."));
            if (!@hasDecl(m.secure, "sealStr")) return c.fail("the secure module is not built in", .{});
            f = .{ .key = try m.secure.sealStr(c.arena, key), .on = true };
        }
    }
    if (a.on) |on| f.on = on and f.key.len > 0;
    try core.writeAtomic(try apiKeyPath(c.arena), try core.toJson(c.arena, f));
    return apiKeyState(c.arena, f);
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

test "approvedConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "sk-ant-api03-0123456789abcdefghijKLMNOPQRSTUVWXYZ";
    const tail = "ghijKLMNOPQRSTUVWXYZ";

    // added; the other keys and the way numbers were written stay
    const out = (try approvedConfig(a, "{\"n\": 0.10, \"big\": 12345678901234567890, \"customApiKeyResponses\": {\"approved\": [\"x\"], \"rejected\": [\"" ++ tail ++ "\"]}}", key)).?;
    try std.testing.expectEqualStrings(
        \\{
        \\  "n": 0.10,
        \\  "big": 12345678901234567890,
        \\  "customApiKeyResponses": {
        \\    "approved": [
        \\      "x",
        \\      "ghijKLMNOPQRSTUVWXYZ"
        \\    ],
        \\    "rejected": []
        \\  }
        \\}
    , out);
    // already approved: nothing to write
    try std.testing.expect(try approvedConfig(a, out, key) == null);
    // no responses yet
    try std.testing.expectEqualStrings(
        \\{
        \\  "customApiKeyResponses": {
        \\    "approved": [
        \\      "ghijKLMNOPQRSTUVWXYZ"
        \\    ],
        \\    "rejected": []
        \\  }
        \\}
    , (try approvedConfig(a, "{}", key)).?);
    try std.testing.expectError(error.NotAnObject, approvedConfig(a, "[]", key));
}
