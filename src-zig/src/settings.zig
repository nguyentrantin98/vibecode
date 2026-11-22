//! App settings: `<userData>/settings.json`, same file and keys as the Electron and Tauri builds.

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const AppSettings = struct {
    recentFolders: []const []const u8 = &.{},
    lastFolder: ?[]const u8 = null,
    /// "window" | "dropdown"
    mode: []const u8 = "window",
    hotkey: []const u8 = "Alt+`",
    dropHeight: f64 = 0.6,
    dropOpacity: f64 = 0.97,
    hideOnBlur: bool = false,
    theme: []const u8 = "system",
    model: []const u8 = "",
    effort: []const u8 = "",
    permissionMode: []const u8 = "",
    seeThrough: bool = false,
    editorFont: []const u8 = "JetBrains Mono",
    editorFontSize: f64 = 12.0,
    editorLigatures: bool = true,
    openAtLogin: ?bool = null,
    /// Web tabs drop requests to known ad / tracking servers
    adBlock: bool = true,
    /// UI language: "en" | "vi" ("" until the app picks one from the system language)
    language: []const u8 = "",

    /// `openAtLogin` is left out while unset (like the Rust build's skip_serializing_if).
    pub fn jsonStringify(s: AppSettings, w: anytype) !void {
        try w.beginObject();
        inline for (@typeInfo(AppSettings).@"struct".field_names) |name| {
            const v = @field(s, name);
            if (comptime std.mem.eql(u8, name, "openAtLogin")) {
                if (v) |on| {
                    try w.objectField(name);
                    try w.write(on);
                }
            } else {
                try w.objectField(name);
                try w.write(v);
            }
        }
        try w.endObject();
    }
};

var mutex: core.Mutex = .{};
/// owns every string of `cache`
var cache_arena: ?std.heap.ArenaAllocator = null;
var cache: AppSettings = .{};
var loaded = false;

fn file(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"settings.json"});
}

fn load() void {
    if (loaded) return;
    loaded = true;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    const a = arena.allocator();
    const path = file(a) catch return;
    const bytes = core.readFileAlloc(a, path, 16 << 20) catch {
        cache_arena = arena;
        return;
    };
    cache = core.fromJson(AppSettings, a, bytes) catch .{};
    cache_arena = arena;
}

/// A copy of the settings, every string allocated in `a`.
pub fn get(a: Allocator) AppSettings {
    mutex.lock();
    defer mutex.unlock();
    load();
    return clone(a, cache) catch cache;
}

fn clone(a: Allocator, s: AppSettings) !AppSettings {
    const json = try core.toJson(a, s);
    return core.fromJson(AppSettings, a, json);
}

/// The UI is in Vietnamese (the tray menu, pop-ups and messages follow the app's language).
pub fn vi() bool {
    mutex.lock();
    defer mutex.unlock();
    load();
    return std.mem.eql(u8, cache.language, "vi");
}

/// The text for the UI language: `tr("Quit", "Thoát")`.
pub fn tr(en: []const u8, vi_text: []const u8) []const u8 {
    return if (vi()) vi_text else en;
}

/// The Web tabs run uBlock Origin Lite.
pub fn adBlock() bool {
    mutex.lock();
    defer mutex.unlock();
    load();
    return cache.adBlock;
}

/// Merges a partial patch (JSON object text with camelCase keys) and saves. Returns the new
/// settings, allocated in `a`.
pub fn update(a: Allocator, patch_json: []const u8) !AppSettings {
    mutex.lock();
    defer mutex.unlock();
    load();
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    errdefer arena.deinit();
    const ta = arena.allocator();
    const cur_json = try core.toJson(ta, cache);
    var cur = try std.json.parseFromSliceLeaky(std.json.Value, ta, cur_json, .{});
    const patch = std.json.parseFromSliceLeaky(std.json.Value, ta, patch_json, .{}) catch std.json.Value{ .null = {} };
    if (patch == .object) {
        var it = patch.object.iterator();
        while (it.next()) |e| try cur.object.put(ta, e.key_ptr.*, e.value_ptr.*);
    }
    const merged_json = try core.toJson(ta, cur);
    const next = core.fromJson(AppSettings, ta, merged_json) catch cache;
    if (cache_arena) |*old| old.deinit();
    cache_arena = arena;
    cache = next;
    save();
    return clone(a, cache);
}

fn save() void {
    var buf: std.Io.Writer.Allocating = .init(core.gpa);
    defer buf.deinit();
    std.json.Stringify.value(cache, .{ .whitespace = .indent_2 }, &buf.writer) catch return;
    const path = file(core.gpa) catch return;
    defer core.gpa.free(path);
    core.writeAtomic(path, buf.written()) catch |e| std.log.warn("settings not saved: {s}", .{@errorName(e)});
}

/// Typed update of a few fields: `set(a, .{ .mode = "dropdown" })`.
pub fn set(a: Allocator, fields: anytype) !AppSettings {
    const json = try core.toJson(a, fields);
    return update(a, json);
}

pub fn rememberFolder(a: Allocator, folder: []const u8) !AppSettings {
    const cur = get(a);
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(a, folder);
    const low = try core.lower(a, folder);
    for (cur.recentFolders) |f| {
        if (list.items.len >= 10) break;
        const fl = try core.lower(a, f);
        if (!std.mem.eql(u8, fl, low)) try list.append(a, f);
    }
    return set(a, .{ .recentFolders = list.items, .lastFolder = folder });
}
