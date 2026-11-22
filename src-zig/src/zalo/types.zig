//! What the Zalo cache holds (cache.json, msgs/*.json) and what Claude's tools and the task list read.
//! Fields older versions wrote and no longer kept are ignored when a cache is read.
//!
//! Fields keep their Rust names; on the wire they are camelCase (`thread_id` ↔ "threadId") unless
//! the type lists another name in `json_names`, and optional fields that are null are left out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

// ---------------- JSON ----------------

fn camel(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var up = false;
        for (name) |ch| {
            if (ch == '_') {
                up = true;
            } else {
                out = out ++ [_]u8{if (up) std.ascii.toUpper(ch) else ch};
                up = false;
            }
        }
        return out;
    }
}

fn wireName(comptime T: type, comptime field: []const u8) []const u8 {
    if (@hasDecl(T, "json_names") and @hasField(@TypeOf(T.json_names), field)) return @field(T.json_names, field);
    return camel(field);
}

/// Writes a struct as a JSON object (see the top of the file). A number that is whole is written
/// without ".0", as JS would.
pub fn writeObject(v: anytype, w: anytype) !void {
    const T = @TypeOf(v);
    try w.beginObject();
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FT| {
        const x = @field(v, name);
        if (@typeInfo(FT) == .optional) {
            if (x) |inner| {
                try w.objectField(comptime wireName(T, name));
                try writeValue(inner, w);
            }
        } else {
            try w.objectField(comptime wireName(T, name));
            try writeValue(x, w);
        }
    }
    try w.endObject();
}

fn writeValue(x: anytype, w: anytype) !void {
    if (@TypeOf(x) == f64) {
        if (@trunc(x) == x and @abs(x) < 9.0e15) return w.write(@as(i64, @intFromFloat(x)));
    }
    return w.write(x);
}

/// Reads a struct from a JSON object: missing keys keep the field's default, unknown ones are ignored.
pub fn readObject(comptime T: type, a: Allocator, source: Value, options: std.json.ParseOptions) !T {
    if (source != .object) return error.UnexpectedToken;
    var r: T = .{};
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FT| {
        if (source.object.get(comptime wireName(T, name))) |fv|
            @field(r, name) = try std.json.innerParseFromValue(FT, a, fv, options);
    }
    return r;
}

/// The three functions std.json looks for, for a struct that goes through `writeObject` / `readObject`.
pub fn Json(comptime T: type) type {
    return struct {
        pub fn jsonStringify(v: T, w: anytype) !void {
            return writeObject(v, w);
        }
        pub fn jsonParseFromValue(a: Allocator, source: Value, options: std.json.ParseOptions) !T {
            return readObject(T, a, source, options);
        }
        pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !T {
            const v = try std.json.innerParse(Value, a, source, options);
            return readObject(T, a, v, options);
        }
    };
}

// ---------------- copies ----------------

/// A deep copy of plain data (strings, slices, optionals, structs of those) in `a`.
pub fn clone(a: Allocator, v: anytype) Allocator.Error!@TypeOf(v) {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.child == u8) return a.dupe(u8, v);
            const out = try a.alloc(p.child, v.len);
            for (out, v) |*o, x| o.* = try clone(a, x);
            return out;
        },
        .optional => return if (v) |x| try clone(a, x) else null,
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names) |name| @field(out, name) = try clone(a, @field(v, name));
            return out;
        },
        else => return v,
    }
}

/// Frees what `clone` allocated.
pub fn free(a: Allocator, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.child != u8) for (v) |x| free(a, x);
            a.free(v);
        },
        .optional => if (v) |x| free(a, x),
        .@"struct" => |s| inline for (s.field_names) |name| free(a, @field(v, name)),
        else => {},
    }
}

/// Replaces an owned string.
pub fn setStr(a: Allocator, slot: *[]const u8, v: []const u8) !void {
    const copy = try a.dupe(u8, v);
    a.free(slot.*);
    slot.* = copy;
}

/// Replaces an owned optional string.
pub fn setOpt(a: Allocator, slot: *?[]const u8, v: ?[]const u8) !void {
    const copy: ?[]const u8 = if (v) |x| try a.dupe(u8, x) else null;
    if (slot.*) |old| a.free(old);
    slot.* = copy;
}

// ---------------- the types ----------------

pub const ZaloState = struct {
    /// off | qr | connecting | online | error (never allocated)
    status: []const u8 = "off",
    qr: ?[]const u8 = null,
    scanned: ?[]const u8 = null,
    err: ?[]const u8 = null,
    me: ?ZaloSelf = null,

    pub const json_names = .{ .err = "error", .me = "self" };
    pub const jsonStringify = Json(@This()).jsonStringify;

    pub fn clone(s: ZaloState, a: Allocator) !ZaloState {
        return .{
            .status = s.status,
            .qr = try types.clone(a, s.qr),
            .scanned = try types.clone(a, s.scanned),
            .err = try types.clone(a, s.err),
            .me = try types.clone(a, s.me),
        };
    }

    pub fn deinit(s: ZaloState, a: Allocator) void {
        types.free(a, s.qr);
        types.free(a, s.scanned);
        types.free(a, s.err);
        types.free(a, s.me);
    }
};

pub const ZaloSelf = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    avatar: []const u8 = "",
};

pub const ZaloThread = struct {
    id: []const u8 = "",
    group: bool = false,
    name: []const u8 = "",
    last_ts: i64 = 0,
    last: []const u8 = "",
    avatar: ?[]const u8 = null,

    pub const jsonStringify = Json(@This()).jsonStringify;
    pub const jsonParseFromValue = Json(@This()).jsonParseFromValue;
    pub const jsonParse = Json(@This()).jsonParse;
};

pub const ZaloAttachment = struct {
    /// photo | video | voice | file | sticker | gif | link | location | card | other
    kind: []const u8 = "",
    url: ?[]const u8 = null,
    thumb: ?[]const u8 = null,
    title: ?[]const u8 = null,
    desc: ?[]const u8 = null,
    width: ?f64 = null,
    height: ?f64 = null,
    /// bytes
    size: ?f64 = null,
    /// seconds
    duration: ?f64 = null,
    ext: ?[]const u8 = null,

    pub const jsonStringify = Json(@This()).jsonStringify;
    pub const jsonParseFromValue = Json(@This()).jsonParseFromValue;
    pub const jsonParse = Json(@This()).jsonParse;
};

pub const Reply = struct {
    id: []const u8 = "",
    from: []const u8 = "",
    text: []const u8 = "",

    pub const jsonParseFromValue = Json(@This()).jsonParseFromValue;
    pub const jsonParse = Json(@This()).jsonParse;
};

pub const MentionRef = struct {
    uid: []const u8 = "",
    pos: i64 = 0,
    len: i64 = 0,

    pub const jsonParseFromValue = Json(@This()).jsonParseFromValue;
    pub const jsonParse = Json(@This()).jsonParse;
};

pub const ZaloMessage = struct {
    id: []const u8 = "",
    thread_id: []const u8 = "",
    group: bool = false,
    from_id: []const u8 = "",
    from_name: []const u8 = "",
    /// "self" on the wire
    mine: bool = false,
    ts: i64 = 0,
    /// "type" on the wire
    kind: []const u8 = "",
    text: []const u8 = "",
    quote: ?[]const u8 = null,
    reply: ?Reply = null,
    att: ?ZaloAttachment = null,
    mentions: ?[]const MentionRef = null,
    recalled: ?bool = null,

    pub const json_names = .{ .mine = "self", .kind = "type" };
    pub const jsonStringify = Json(@This()).jsonStringify;
    pub const jsonParseFromValue = Json(@This()).jsonParseFromValue;
    pub const jsonParse = Json(@This()).jsonParse;
};

/// A message in `zalo.workFeed`.
pub const WorkMsg = struct {
    id: []const u8,
    ts: i64,
    from: []const u8,
    from_id: []const u8,
    mine: bool,
    /// sent to me: a personal chat, an @mention of me, or a reply to my message
    to_me: bool,
    text: []const u8,
};

pub const WorkThread = struct {
    thread_id: []const u8,
    name: []const u8,
    group: bool,
    msgs: []const WorkMsg,
};

const types = @This();
const testing = std.testing;

test "wire names and nulls" {
    const a = testing.allocator;
    const att: ZaloAttachment = .{ .kind = "photo", .url = "https://hd", .width = 1920, .duration = 2.5 };
    const json = try std.json.Stringify.valueAlloc(a, att, .{});
    defer a.free(json);
    try testing.expectEqualStrings("{\"kind\":\"photo\",\"url\":\"https://hd\",\"width\":1920,\"duration\":2.5}", json);

    const st: ZaloState = .{ .status = "online", .err = "x", .me = .{ .id = "1", .name = "n" } };
    const sj = try std.json.Stringify.valueAlloc(a, st, .{});
    defer a.free(sj);
    try testing.expectEqualStrings("{\"status\":\"online\",\"error\":\"x\",\"self\":{\"id\":\"1\",\"name\":\"n\",\"avatar\":\"\"}}", sj);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const text = "{\"id\":\"1\",\"threadId\":\"g1\",\"self\":true,\"type\":\"webchat\",\"ts\":5,\"unknown\":[1],\"att\":{\"kind\":\"file\",\"size\":2048},\"mentions\":[{\"uid\":\"me\",\"pos\":0,\"len\":3}],\"reply\":{\"id\":\"9\"}}";
    const m = try std.json.parseFromSliceLeaky(ZaloMessage, arena.allocator(), text, .{ .ignore_unknown_fields = true });
    try testing.expect(m.mine and m.ts == 5 and m.recalled == null and m.quote == null);
    try testing.expectEqualStrings("g1", m.thread_id);
    try testing.expectEqualStrings("webchat", m.kind);
    try testing.expectEqual(@as(?f64, 2048), m.att.?.size);
    try testing.expectEqualStrings("me", m.mentions.?[0].uid);
    try testing.expectEqualStrings("", m.reply.?.from);
    const back = try std.json.Stringify.valueAlloc(a, m, .{});
    defer a.free(back);
    try testing.expectEqualStrings(
        "{\"id\":\"1\",\"threadId\":\"g1\",\"group\":false,\"fromId\":\"\",\"fromName\":\"\",\"self\":true,\"ts\":5,\"type\":\"webchat\",\"text\":\"\",\"reply\":{\"id\":\"9\",\"from\":\"\",\"text\":\"\"},\"att\":{\"kind\":\"file\",\"size\":2048},\"mentions\":[{\"uid\":\"me\",\"pos\":0,\"len\":3}]}",
        back,
    );

    // a copy owns its memory
    const copy = try clone(a, m);
    defer free(a, copy);
    try testing.expectEqualStrings("me", copy.mentions.?[0].uid);
    try testing.expect(copy.thread_id.ptr != m.thread_id.ptr);
}
