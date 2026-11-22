//! Reading dynamic JSON (`std.json.Value`) the way serde_json's `v["a"]["b"].as_str()` does: a
//! missing key or another type is null, never an error. Shared by browser.zig, extensions.zig and
//! mcp.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

/// The value of `bytes`, allocated in `a` (use an arena); null when it is not JSON.
pub fn parse(a: Allocator, bytes: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch null;
}

/// `v[key]` of an object.
pub fn get(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    return if (o == .object) o.object.get(key) else null;
}

/// `v[i]` of an array.
pub fn at(v: ?Value, i: usize) ?Value {
    const list = items(v);
    return if (i < list.len) list[i] else null;
}

/// `v[keys[0]][keys[1]]…`
pub fn path(v: ?Value, keys: []const []const u8) ?Value {
    var cur = v;
    for (keys) |k| cur = get(cur, k);
    return cur;
}

pub fn str(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

pub fn boolean(v: ?Value) ?bool {
    const b = v orelse return null;
    return if (b == .bool) b.bool else null;
}

/// A non-negative whole number.
pub fn uint(v: ?Value) ?u64 {
    const n = v orelse return null;
    return if (n == .integer and n.integer >= 0) @intCast(n.integer) else null;
}

/// The elements of an array (none for anything else).
pub fn items(v: ?Value) []const Value {
    const list = v orelse return &.{};
    return if (list == .array) list.array.items else &.{};
}

/// Compact JSON text of `v`.
pub fn text(a: Allocator, v: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

/// A string as it is, anything else as JSON text.
pub fn display(a: Allocator, v: Value) ![]const u8 {
    return if (v == .string) v.string else text(a, v);
}

test "reading values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = parse(a, "{\"a\":{\"b\":[1,\"two\",true,-3,null]},\"s\":\"x\"}").?;
    try std.testing.expectEqualStrings("x", str(get(v, "s")).?);
    try std.testing.expectEqual(@as(?u64, 1), uint(at(path(v, &.{ "a", "b" }), 0)));
    try std.testing.expectEqualStrings("two", str(at(path(v, &.{ "a", "b" }), 1)).?);
    try std.testing.expectEqual(@as(?bool, true), boolean(at(path(v, &.{ "a", "b" }), 2)));
    try std.testing.expectEqual(@as(?u64, null), uint(at(path(v, &.{ "a", "b" }), 3)));
    try std.testing.expect(at(path(v, &.{ "a", "b" }), 4).? == .null);
    try std.testing.expect(get(v, "missing") == null);
    try std.testing.expect(path(v, &.{ "s", "deeper" }) == null);
    try std.testing.expect(str(get(v, "a")) == null);
    try std.testing.expectEqual(@as(usize, 0), items(get(v, "s")).len);
    try std.testing.expectEqualStrings("{\"b\":[1,\"two\",true,-3,null]}", try display(a, get(v, "a").?));
    try std.testing.expectEqualStrings("x", try display(a, get(v, "s").?));
    try std.testing.expect(parse(a, "{not json") == null);
}
