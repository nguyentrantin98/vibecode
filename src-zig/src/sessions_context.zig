//! How full a chat's context window is, and roughly what it is made of (see `sessions.zig`).

const std = @import("std");
const core = @import("core.zig");
const u = @import("sessions_util.zig");
const Allocator = std.mem.Allocator;
const Value = u.Value;

pub const Context = struct {
    used: u64,
    model: []const u8,
    /// `used` split by where it comes from (an estimate)
    parts: []const ContextPart,
    /// tools sent with full definitions, by estimated size (biggest first)
    tools: []const ContextTool,
};

pub const ContextTool = struct {
    name: []const u8,
    tokens: u64,
};

pub const ContextPart = struct {
    key: []const u8,
    tokens: u64,
};

/// Where the context goes, in the order the bar draws it (mirrors CTX_PARTS in Claude.tsx).
const CTX_KEYS = [_][]const u8{ "system", "tools", "mcp", "plugins", "skills", "agents", "memory", "messages" };
const SYSTEM = 0;
const TOOLS = 1;
const MCP = 2;
const PLUGINS = 3;
const SKILLS = 4;
const AGENTS = 5;
const MEMORY = 6;
const MESSAGES = 7;

const Parts = [CTX_KEYS.len]u64;

/// Rough size of what the model reads, in bytes of text (≈ 4 per token): pictures count as the
/// ~1.5k tokens they cost, not their base64.
fn ctxSize(v: ?Value) u64 {
    const x = v orelse return 0;
    switch (x) {
        .string => |s| return s.len,
        .array => |items| {
            var sum: u64 = 0;
            for (items.items) |i| sum += ctxSize(i);
            return sum;
        },
        .object => {
            const ty = u.strOf(x, "type") orelse "";
            if (std.mem.eql(u8, ty, "image")) return 6000;
            if (std.mem.eql(u8, ty, "document")) return if (u.strOf(u.get(x, "source"), "data")) |d| d.len / 8 else 6000;
            if (std.mem.eql(u8, ty, "text")) return ctxSize(u.get(x, "text"));
            if (std.mem.eql(u8, ty, "thinking")) return ctxSize(u.get(x, "thinking"));
            if (std.mem.eql(u8, ty, "tool_result")) return 20 + ctxSize(u.get(x, "content"));
            if (std.mem.eql(u8, ty, "tool_use"))
                return 20 + (if (u.strOf(x, "name")) |n| n.len else 0) + (if (u.get(x, "input")) |i| u.jsonLen(i) else 0);
            return u.jsonLen(x);
        },
        else => return 0,
    }
}

/// Tools of plugins come as `mcp__plugin_<plugin>_<server>__<tool>`, other servers' as `mcp__<server>__<tool>`.
fn toolPart(name: []const u8) usize {
    if (std.mem.startsWith(u8, name, "mcp__plugin_")) return PLUGINS;
    if (std.mem.startsWith(u8, name, "mcp__")) return MCP;
    return TOOLS;
}

/// A listing line `- name: description`: plugins' skills and agents are named `plugin:name`.
fn pluginLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "- ")) return false;
    const rest = line[2..];
    const end = std.mem.find(u8, rest, ": ") orelse return false;
    return std.mem.findScalar(u8, rest[0..end], ':') != null;
}

/// Bytes of the plugin lines of a listing (a text, or a list of lines).
fn pluginLines(v: ?Value) u64 {
    var sum: u64 = 0;
    switch (v orelse return 0) {
        .string => |s| {
            var it = u.lines(s);
            while (it.next()) |l| if (pluginLine(l)) {
                sum += l.len + 1;
            };
        },
        .array => |items| for (items.items) |x| {
            const l = u.str(x) orelse continue;
            if (pluginLine(l)) sum += l.len + 1;
        },
        else => {},
    }
    return sum;
}

fn oneOf(s: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, s, n)) return true;
    return false;
}

const Row = struct { uuid: []const u8, part: u8, size: u64 };

pub const ContextWalk = struct {
    /// the conversation since the last compaction: (row uuid, part, size); a compaction keeps
    /// the rows it preserved
    rows: std.ArrayList(Row) = .empty,
    conv: Parts = @splat(0),
    /// system prompt and tool definitions of each request shape, by hash
    shapes: std.StringHashMapUnmanaged(Parts) = .empty,
    /// size of each tool definition of each request shape, by hash
    shape_tools: std.StringHashMapUnmanaged([]const ContextTool) = .empty,
    /// shape of the last main-thread request (else of any request)
    shape: ?[]const u8 = null,
    any_shape: ?[]const u8 = null,
    used: u64 = 0,
    model: []const u8 = "",
    /// tokens per byte of the first reply's request, which is nearly all fixed parts
    calib: ?f64 = null,

    fn baseHash(w: *const ContextWalk) ?[]const u8 {
        return w.shape orelse w.any_shape;
    }

    fn base(w: *const ContextWalk) ?Parts {
        return w.shapes.get(w.baseHash() orelse return null);
    }

    fn add(w: *ContextWalk, a: Allocator, uuid: []const u8, part: usize, size: u64) !void {
        if (size == 0) return;
        w.conv[part] += size;
        try w.rows.append(a, .{ .uuid = try a.dupe(u8, uuid), .part = @intCast(part), .size = size });
    }

    /// `a` owns what the walk keeps.
    pub fn feed(w: *ContextWalk, a: Allocator, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            // the same messages again, by hash (the transcript has them already)
            if (std.mem.startsWith(u8, line, "{\"type\":\"api-request-blob\"")) continue;
            _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
            const r = u.parseObj(sa, line) orelse continue;
            const ty = u.strOf(r, "type") orelse continue;
            if (std.mem.eql(u8, ty, "api-request-shape")) {
                try w.shapeRow(a, r);
            } else if (std.mem.eql(u8, ty, "api-request")) {
                if (u.strOf(r, "shapeHash")) |h| {
                    const hash = try a.dupe(u8, h);
                    if (std.mem.find(u8, u.strOf(r, "querySource") orelse "", "main_thread") != null) w.shape = hash;
                    w.any_shape = hash;
                }
            } else if (std.mem.eql(u8, ty, "system")) {
                if (std.mem.eql(u8, u.strOf(r, "subtype") orelse "", "compact_boundary")) w.compacted(r);
            } else if (std.mem.eql(u8, ty, "user") or std.mem.eql(u8, ty, "assistant") or std.mem.eql(u8, ty, "attachment")) {
                if (u.truthy(u.get(r, "isSidechain")) or u.truthy(u.get(r, "isVisibleInTranscriptOnly"))) continue;
                const uuid = u.strOf(r, "uuid") orelse "";
                const content = u.get(u.get(r, "message"), "content");
                if (std.mem.eql(u8, ty, "attachment")) {
                    try w.attachment(a, uuid, r);
                } else if (std.mem.eql(u8, ty, "assistant")) {
                    w.usage(a, r);
                    if (content) |c| try w.add(a, uuid, MESSAGES, ctxSize(c));
                } else {
                    const c = content orelse continue;
                    // a skill's instructions, loaded when Claude invokes it
                    const skill = u.truthy(u.get(r, "isMeta")) and u.get(r, "sourceToolUseID") != null and
                        std.mem.find(u8, try u.jsonText(sa, c, null), "Base directory for this skill") != null;
                    try w.add(a, uuid, if (skill) SKILLS else MESSAGES, ctxSize(c));
                }
            }
        }
    }

    fn usage(w: *ContextWalk, a: Allocator, r: Value) void {
        if (u.truthy(u.get(r, "isApiErrorMessage"))) return;
        const msg = u.get(r, "message") orelse return;
        if (msg != .object) return;
        const model = u.strOf(msg, "model") orelse "";
        if (std.mem.eql(u8, model, "<synthetic>")) return;
        const usg = u.get(msg, "usage") orelse return;
        if (usg != .object) return;
        const out = u.asF64(u.get(usg, "output_tokens")) orelse 0;
        const used = (u.asF64(u.get(usg, "input_tokens")) orelse 0) + (u.asF64(u.get(usg, "cache_read_input_tokens")) orelse 0) +
            (u.asF64(u.get(usg, "cache_creation_input_tokens")) orelse 0) + out;
        if (!(used > 0)) return;
        w.used = u.toU64(used);
        if (!std.mem.eql(u8, w.model, model)) w.model = a.dupe(u8, model) catch return;
        if (w.calib == null) if (w.base()) |b| {
            var bytes: u64 = 0;
            for (b, w.conv) |x, y| bytes += x + y;
            if (bytes > 0) w.calib = std.math.clamp((used - out) / @as(f64, @floatFromInt(bytes)), 0.2, 0.75);
        };
    }

    fn shapeRow(w: *ContextWalk, a: Allocator, r: Value) !void {
        const hash = u.strOf(r, "shapeHash") orelse return;
        const shape = u.get(r, "shape") orelse return;
        var p: Parts = @splat(0);
        var tools: std.ArrayList(ContextTool) = .empty;
        p[SYSTEM] = ctxSize(u.get(shape, "system"));
        for (u.arr(u.get(shape, "tools"))) |t| {
            // deferred tools are only a name until ToolSearch loads them
            if (u.truthy(u.get(t, "defer_loading"))) continue;
            const name = u.strOf(t, "name") orelse "";
            const size = u.jsonLen(t);
            p[toolPart(name)] += size;
            try tools.append(a, .{ .name = try a.dupe(u8, name), .tokens = size });
        }
        const slot = try w.shapes.getOrPut(a, hash);
        if (!slot.found_existing) slot.key_ptr.* = try a.dupe(u8, hash);
        slot.value_ptr.* = p;
        try w.shape_tools.put(a, slot.key_ptr.*, tools.items);
    }

    fn attachment(w: *ContextWalk, a: Allocator, uuid: []const u8, r: Value) !void {
        // only rendered attachments reach the model
        const rendered = u.get(r, "rendered") orelse return;
        var size: u64 = 0;
        for (u.arr(rendered)) |b| size += ctxSize(u.get(b, "content"));
        const att: ?Value = if (u.get(r, "attachment")) |x| (if (x == .object) x else null) else null;
        const ty = u.strOf(att, "type") orelse "";
        if (oneOf(ty, &.{"skill_listing"})) {
            const plug = @min(pluginLines(u.get(att, "content")), size);
            try w.add(a, uuid, PLUGINS, plug);
            try w.add(a, uuid, SKILLS, size - plug);
        } else if (oneOf(ty, &.{"agent_listing_delta"})) {
            const plug = @min(pluginLines(u.get(att, "addedLines")), size);
            try w.add(a, uuid, PLUGINS, plug);
            try w.add(a, uuid, AGENTS, size - plug);
        } else if (oneOf(ty, &.{"mcp_instructions_delta"})) {
            try w.add(a, uuid, MCP, size);
        } else if (oneOf(ty, &.{ "instructions", "nested_memory" })) {
            try w.add(a, uuid, MEMORY, size);
        } else if (oneOf(ty, &.{"deferred_tools_delta"})) {
            try w.add(a, uuid, TOOLS, size);
            // MCP tools surfaced with their full definition
            for (u.arr(u.get(att, "surfacedDefinitions"))) |d| {
                const def = u.get(d, "definition");
                try w.add(a, uuid, toolPart(u.strOf(d, "name") orelse ""), if (def) |x| u.jsonLen(x) else 0);
            }
        } else if (oneOf(ty, &.{ "environment", "model", "date", "auto_mode", "session_context", "remote_session_change", "output_style" })) {
            try w.add(a, uuid, SYSTEM, size);
        } else {
            try w.add(a, uuid, MESSAGES, size);
        }
    }

    /// Everything before a compaction is gone but the summary and the messages it preserved.
    fn compacted(w: *ContextWalk, r: Value) void {
        const keep = u.arr(u.get(u.get(u.get(r, "compactMetadata"), "preservedMessages"), "uuids"));
        var n: usize = 0;
        w.conv = @splat(0);
        for (w.rows.items) |row| {
            const kept = for (keep) |k| {
                if (std.mem.eql(u8, u.str(k) orelse continue, row.uuid)) break true;
            } else false;
            if (!kept) continue;
            w.rows.items[n] = row;
            n += 1;
            w.conv[row.part] += row.size;
        }
        w.rows.items.len = n;
    }

    /// The last reply's token count, split by part: each fixed part from its size at the rate the
    /// first request measured, and the conversation is the rest (it also holds what the transcript
    /// doesn't keep, like thinking). Without a recorded request shape (older Claude Code) the
    /// system prompt and tools are the rest instead.
    pub fn result(w: *const ContextWalk, a: Allocator) Allocator.Error!?Context {
        if (w.used == 0) return null;
        var est = w.conv;
        const b = w.base();
        if (b) |fixed| for (&est, fixed) |*e, f| {
            e.* += f;
        };
        const rate = w.calib orelse 0.25;
        var tok: [CTX_KEYS.len]f64 = undefined;
        for (&tok, est) |*t, e| t.* = @as(f64, @floatFromInt(e)) * rate;
        const used: f64 = @floatFromInt(w.used);
        const rest: usize = if (b != null) MESSAGES else SYSTEM;
        var fixed: f64 = 0;
        for (tok, 0..) |t, i| {
            if (i != rest) fixed += t;
        }
        if (fixed <= used) {
            tok[rest] = used - fixed;
        } else {
            const sum = fixed + tok[rest];
            for (&tok) |*t| t.* *= used / sum;
        }
        const parts = try a.alloc(ContextPart, CTX_KEYS.len);
        var total: i64 = 0;
        // the last of the biggest, like `max_by_key`
        var big: usize = 0;
        for (parts, CTX_KEYS, tok, 0..) |*p, k, t, i| {
            p.* = .{ .key = k, .tokens = u.toU64(@round(t)) };
            total += @intCast(p.tokens);
            if (p.tokens >= parts[big].tokens) big = i;
        }
        // rounding: the parts add up to the total
        const off = @as(i64, @intCast(w.used)) - total;
        parts[big].tokens = @intCast(@max(@as(i64, @intCast(parts[big].tokens)) + off, 0));
        const defs: []const ContextTool = if (w.baseHash()) |h| w.shape_tools.get(h) orelse &.{} else &.{};
        const tools = try a.alloc(ContextTool, defs.len);
        for (tools, defs) |*t, d| t.* = .{ .name = d.name, .tokens = u.toU64(@round(@as(f64, @floatFromInt(d.tokens)) * rate)) };
        std.mem.sort(ContextTool, tools, {}, struct {
            fn lt(_: void, x: ContextTool, y: ContextTool) bool {
                return x.tokens > y.tokens;
            }
        }.lt);
        return .{ .used = w.used, .model = w.model, .parts = parts, .tools = tools };
    }
};

const testing = std.testing;

fn partOf(c: Context, key: []const u8) u64 {
    for (c.parts) |p| if (std.mem.eql(u8, p.key, key)) return p.tokens;
    unreachable;
}

test "context: sizes of what the model reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(u64, 5), ctxSize(u.parseLine(a, "\"hello\"")));
    try testing.expectEqual(@as(u64, 6000), ctxSize(u.parseLine(a, "{\"type\":\"image\",\"source\":{\"data\":\"AAAA\"}}")));
    try testing.expectEqual(@as(u64, 2), ctxSize(u.parseLine(a, "{\"type\":\"document\",\"source\":{\"data\":\"0123456789abcdef\"}}")));
    try testing.expectEqual(@as(u64, 6000), ctxSize(u.parseLine(a, "{\"type\":\"document\"}")));
    try testing.expectEqual(@as(u64, 2 + 3 + 22 + 31), ctxSize(u.parseLine(a,
        \\[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm"},{"type":"tool_result","content":"ok"},{"type":"tool_use","name":"Bash","input":{"a":1}}]
    )));
    try testing.expectEqual(@as(u64, 7), ctxSize(u.parseLine(a, "{\"a\":1}")));
    try testing.expectEqual(@as(u64, 0), ctxSize(u.parseLine(a, "12")));
    try testing.expect(pluginLine("- plug:skill: does things"));
    try testing.expect(!pluginLine("- skill: does things: more"));
    try testing.expect(!pluginLine("plug:skill: x"));
    try testing.expectEqual(@as(usize, PLUGINS), toolPart("mcp__plugin_a_b__c"));
    try testing.expectEqual(@as(usize, MCP), toolPart("mcp__a__c"));
    try testing.expectEqual(@as(usize, TOOLS), toolPart("Bash"));
}

test "context: parts add up to the last reply's tokens" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: ContextWalk = .{};
    try testing.expect(try w.result(a) == null);
    try w.feed(a,
        \\{"type":"api-request-shape","shapeHash":"h1","shape":{"system":[{"type":"text","text":"0123456789012345678901234567890123456789"}],"tools":[{"name":"Bash","description":"run"},{"name":"mcp__db__query","description":"sql"},{"name":"Later","defer_loading":true}]}}
        \\{"type":"api-request","shapeHash":"h1","querySource":"repl_main_thread"}
        \\{"type":"api-request-blob","shapeHash":"h1","messages":"not read"}
        \\{"type":"user","uuid":"u1","message":{"role":"user","content":"hello there"}}
        \\{"type":"attachment","uuid":"a1","attachment":{"type":"skill_listing","content":"- plug:one: x\n- two: y"},"rendered":[{"content":"- plug:one: x\n- two: y"}]}
        \\{"type":"attachment","uuid":"a2","attachment":{"type":"nested_memory"}}
        \\{"type":"user","uuid":"u2","isSidechain":true,"message":{"role":"user","content":"a subagent's prompt, not counted"}}
        \\{"type":"assistant","uuid":"m1","message":{"model":"claude-x","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"cache_read_input_tokens":60,"cache_creation_input_tokens":20,"output_tokens":10}}}
        \\{"type":"assistant","uuid":"m2","message":{"model":"<synthetic>","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"output_tokens":1}}}
    );
    const bash = u.jsonLen(u.parseLine(a, "{\"name\":\"Bash\",\"description\":\"run\"}").?);
    const mcp = u.jsonLen(u.parseLine(a, "{\"name\":\"mcp__db__query\",\"description\":\"sql\"}").?);
    try testing.expectEqualSlices(u64, &.{ 0, 0, 0, 14, 8, 0, 0, 11 + 2 + 1 }, &w.conv);
    try testing.expectEqualSlices(u64, &.{ 40, bash, mcp, 0, 0, 0, 0, 0 }, &w.shapes.get("h1").?);
    try testing.expectEqualStrings("h1", w.shape.?);
    const c = (try w.result(a)).?;
    try testing.expectEqual(@as(u64, 100), c.used);
    try testing.expectEqualStrings("claude-x", c.model);
    try testing.expectEqual(@as(usize, 8), c.parts.len);
    var sum: u64 = 0;
    for (c.parts) |p| sum += p.tokens;
    try testing.expectEqual(@as(u64, 100), sum);
    // the first request was 90 tokens for 40 + 35 + 45 (fixed) + 14 + 8 + 11 (conversation) bytes
    try testing.expectEqual(@as(u64, 35), bash);
    try testing.expectEqual(@as(u64, 45), mcp);
    try testing.expectApproxEqAbs(@as(f64, 90.0 / 153.0), w.calib.?, 1e-12);
    try testing.expectEqual(@as(u64, 24), partOf(c, "system"));
    try testing.expectEqual(@as(u64, 21), partOf(c, "tools"));
    try testing.expectEqual(@as(u64, 26), partOf(c, "mcp"));
    try testing.expectEqual(@as(u64, 8), partOf(c, "plugins"));
    try testing.expectEqual(@as(u64, 5), partOf(c, "skills"));
    try testing.expectEqual(@as(u64, 16), partOf(c, "messages"));
    try testing.expectEqual(@as(usize, 2), c.tools.len);
    try testing.expectEqualStrings("mcp__db__query", c.tools[0].name);
    try testing.expectEqual(@as(u64, 26), c.tools[0].tokens);
    try testing.expect(std.mem.startsWith(u8, try core.toJson(a, c), "{\"used\":100,\"model\":\"claude-x\",\"parts\":[{\"key\":\"system\",\"tokens\":24},{\"key\":\"tools\","));
    try testing.expect(std.mem.endsWith(u8, try core.toJson(a, c), "\"tools\":[{\"name\":\"mcp__db__query\",\"tokens\":26},{\"name\":\"Bash\",\"tokens\":21}]}"));

    // a compaction keeps only the rows it names
    try w.feed(a,
        \\{"type":"system","subtype":"compact_boundary","compactMetadata":{"preservedMessages":{"uuids":["u1"]}}}
    );
    try testing.expectEqualSlices(u64, &.{ 0, 0, 0, 0, 0, 0, 0, 11 }, &w.conv);
    try testing.expectEqual(@as(usize, 1), w.rows.items.len);
}

test "context: without a request shape the system prompt is the rest" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: ContextWalk = .{};
    try w.feed(a,
        \\{"type":"user","uuid":"u1","message":{"content":"0123456789012345678901234567890123456789"}}
        \\{"type":"assistant","uuid":"m1","message":{"model":"m","content":[],"usage":{"input_tokens":1000,"output_tokens":0}}}
    );
    const c = (try w.result(a)).?;
    try testing.expectEqual(@as(u64, 10), partOf(c, "messages"));
    try testing.expectEqual(@as(u64, 990), partOf(c, "system"));
    try testing.expectEqual(@as(usize, 0), c.tools.len);
}
