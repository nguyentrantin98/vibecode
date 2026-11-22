//! Claude's tools for the user's Zalo account (MCP server "vibe-zalo").

const std = @import("std");
const core = @import("../core.zig");
const unicase = @import("../unicase.zig");
const zalo = @import("zalo.zig");
const proto = @import("proto.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const INSTRUCTIONS: []const u8 = "Read (and, only when the user asks, send) messages of the user's personal Zalo account connected in VIBE CODE's Zalo tab. Start with zalo_list_chats to find a thread id, then zalo_read_messages. Message history is what VIBE CODE has synced since login plus recent history Zalo replays; groups can load older messages with zalo_read_messages {older: true}.";

const TOOLS =
    \\[
    \\  {
    \\    "name": "zalo_status",
    \\    "description": "Whether Zalo is logged in, and as whom.",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  },
    \\  {
    \\    "name": "zalo_list_chats",
    \\    "description": "Recent Zalo conversations (people and groups), newest first: thread id, name, type, time and last message. `query` filters by name.",
    \\    "inputSchema": { "type": "object", "properties": { "query": { "type": "string" }, "limit": { "type": "number", "description": "default 30" } } }
    \\  },
    \\  {
    \\    "name": "zalo_read_messages",
    \\    "description": "Messages of one conversation, oldest first. `before` (ms timestamp) pages back through the synced history. For groups, `older: true` first fetches older messages from Zalo.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "threadId": { "type": "string" },
    \\        "limit": { "type": "number", "description": "default 50, max 500" },
    \\        "before": { "type": "number" },
    \\        "older": { "type": "boolean" }
    \\      },
    \\      "required": ["threadId"]
    \\    }
    \\  },
    \\  {
    \\    "name": "zalo_search_messages",
    \\    "description": "Search synced Zalo messages by text or sender name (all conversations, or one `threadId`). Newest first.",
    \\    "inputSchema": { "type": "object", "properties": { "query": { "type": "string" }, "threadId": { "type": "string" }, "limit": { "type": "number" } }, "required": ["query"] }
    \\  },
    \\  {
    \\    "name": "zalo_contacts",
    \\    "description": "Zalo friends and groups with their ids. `query` filters by name.",
    \\    "inputSchema": { "type": "object", "properties": { "query": { "type": "string" } } }
    \\  },
    \\  {
    \\    "name": "zalo_find_user",
    \\    "description": "Look up a Zalo user by phone number (returns their id and name).",
    \\    "inputSchema": { "type": "object", "properties": { "phone": { "type": "string" } }, "required": ["phone"] }
    \\  },
    \\  {
    \\    "name": "zalo_send_message",
    \\    "description": "Send a text message from the user's own Zalo account. Only when the user explicitly asked you to send this message to this person or group; show them the exact text and recipient first if there is any doubt.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": {
    \\        "threadId": { "type": "string" },
    \\        "text": { "type": "string" },
    \\        "group": { "type": "boolean", "description": "true for a group thread (auto-detected for known threads)" }
    \\      },
    \\      "required": ["threadId", "text"]
    \\    }
    \\  }
    \\]
;

/// The JSON text of the tools array.
pub fn tools(a: Allocator) ![]const u8 {
    return a.dupe(u8, TOOLS);
}

fn fmt(a: Allocator, ts: i64) ![]const u8 {
    return if (ts == 0) "-" else zalo.fmtTime(a, ts);
}

fn fmtMsg(a: Allocator, msg: types.ZaloMessage) ![]const u8 {
    const who = if (msg.mine) "Tôi" else msg.from_name;
    const from = if (msg.group) try std.fmt.allocPrint(a, " ({s})", .{msg.from_id}) else "";
    const quote = if (msg.quote) |q| try std.fmt.allocPrint(a, "↪ «{s}» ", .{zalo.firstChars(q, 80)}) else "";
    return std.fmt.allocPrint(a, "[{s}] {s}{s}: {s}{s}", .{ try fmt(a, msg.ts), who, from, quote, msg.text });
}

/// JS `String(v ?? '')`.
fn argStr(a: Allocator, args: Value, k: []const u8) ![]const u8 {
    const v = proto.field(args, k) orelse return "";
    return if (v == .null) "" else proto.jstr(a, v);
}

/// `Math.min(max, Math.max(1, Number(v) || d))`
fn num(v: ?Value, d: f64, max: f64) usize {
    var x = proto.jnum(v);
    if (std.math.isNan(x) or x == 0) x = d;
    return @intFromFloat(@min(@max(x, 1), max));
}

/// The name a conversation is shown by: its name, or its id.
fn threadName(a: Allocator, s: *const zalo.Store, id: []const u8) ![]const u8 {
    if (s.threads.get(id)) |t| if (t.name.len > 0) return a.dupe(u8, t.name);
    return id;
}

/// Runs one tool; the text result is allocated in `a`.
pub fn callTool(a: Allocator, name: []const u8, args: Value, fail: *core.Fail) anyerror![]const u8 {
    if (std.mem.eql(u8, name, "zalo_status")) {
        const st = try zalo.state(a);
        const s = zalo.store();
        const count = s.threads.count();
        zalo.unlock();
        if (std.mem.eql(u8, st.status, "online")) {
            const me: types.ZaloSelf = st.me orelse .{};
            return std.fmt.allocPrint(a, "Logged in as {s} (id {s}). {d} conversations cached.", .{ me.name, me.id, count });
        }
        const err = if (st.err) |e| try std.fmt.allocPrint(a, ": {s}", .{e}) else "";
        return std.fmt.allocPrint(a, "Not logged in ({s}{s}). Ask the user to open the Zalo tab in VIBE CODE and scan the QR code.", .{ st.status, err });
    }
    if (std.mem.eql(u8, name, "zalo_list_chats")) {
        const list = try zalo.listThreads(a, try argStr(a, args, "query"), num(proto.field(args, "limit"), 30, 500));
        if (list.len == 0) return "No conversations synced yet.";
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |t, i| {
            if (i > 0) try out.append(a, '\n');
            try out.print(a, "{s} {s}  {s}  · {s}  · {s}", .{ if (t.group) "group" else "user ", t.id, if (t.name.len == 0) "(no name)" else t.name, try fmt(a, t.last_ts), t.last });
        }
        return out.items;
    }
    if (std.mem.eql(u8, name, "zalo_read_messages")) {
        const id = try argStr(a, args, "threadId");
        var note: []const u8 = "";
        if (proto.truthy(proto.field(args, "older")))
            note = try std.fmt.allocPrint(a, "Fetched {d} older messages.\n", .{try zalo.loadOlder(a, id, 3, fail)});
        const before: ?i64 = if (proto.field(args, "before")) |b| switch (b) {
            .integer => |n| n,
            .float => |f| @intFromFloat(std.math.clamp(f, -9.0e18, 9.0e18)),
            else => null,
        } else null;
        const list = try zalo.getMessages(a, id, num(proto.field(args, "limit"), 50, 500), before);
        const head = blk: {
            const s = zalo.store();
            defer zalo.unlock();
            const group = if (s.threads.get(id)) |t| t.group else false;
            break :blk try std.fmt.allocPrint(a, "{s} {s}\n", .{ if (group) "Group" else "Chat with", try threadName(a, s, id) });
        };
        if (list.len == 0) return std.fmt.allocPrint(a, "{s}{s}No messages synced for this conversation.", .{ head, note });
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{s}{s}", .{ head, note });
        for (list) |msg| try out.print(a, "{s}\n", .{try fmtMsg(a, msg)});
        try out.print(a, "(oldest ts here: {d} — pass as `before` for earlier messages)", .{list[0].ts});
        return out.items;
    }
    if (std.mem.eql(u8, name, "zalo_search_messages")) {
        const thread = try argStr(a, args, "threadId");
        const list = try zalo.searchMessages(a, try argStr(a, args, "query"), if (thread.len > 0) thread else null, num(proto.field(args, "limit"), 50, 500));
        if (list.len == 0) return "No matches.";
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |msg, i| {
            const shown = blk: {
                const s = zalo.store();
                defer zalo.unlock();
                break :blk try threadName(a, s, msg.thread_id);
            };
            if (i > 0) try out.append(a, '\n');
            try out.print(a, "{s} ({s}) {s}", .{ shown, msg.thread_id, try fmtMsg(a, msg) });
        }
        return out.items;
    }
    if (std.mem.eql(u8, name, "zalo_contacts")) {
        const q = try unicase.lowerStr(a, try argStr(a, args, "query"));
        var out: std.ArrayList(u8) = .empty;
        var rows: usize = 0;
        const s = zalo.store();
        defer zalo.unlock();
        for (s.names.keys(), s.names.values()) |id, v| {
            if (rows == 500) break;
            if (q.len > 0 and std.mem.indexOf(u8, try unicase.lowerStr(a, v), q) == null) continue;
            if (rows > 0) try out.append(a, '\n');
            const group = if (s.threads.get(id)) |t| t.group else false;
            try out.print(a, "{s} {s}  {s}", .{ if (group) "group" else "user ", id, v });
            rows += 1;
        }
        return if (rows == 0) "No contacts match." else out.items;
    }
    if (std.mem.eql(u8, name, "zalo_find_user")) {
        const x = try zalo.need(a, fail);
        defer x.release();
        const u = try x.findUser(a, try argStr(a, args, "phone"), fail);
        const uid = proto.field(u, "uid");
        if (!proto.truthy(uid)) return "Not found.";
        const display = proto.fieldStr(u, "display_name");
        const shown = if (display != null and display.?.len > 0) display.? else proto.fieldStr(u, "zalo_name") orelse "";
        return std.fmt.allocPrint(a, "id {s}  {s}", .{ try proto.jstr(a, uid), shown });
    }
    if (std.mem.eql(u8, name, "zalo_send_message")) {
        const group: ?bool = if (proto.field(args, "group")) |g| (if (g == .bool) g.bool else null) else null;
        const id = try zalo.sendText(a, try argStr(a, args, "threadId"), try argStr(a, args, "text"), group, fail);
        return std.fmt.allocPrint(a, "Sent (msgId {s}).", .{id});
    }
    return fail.set(a, "Unknown tool {s}", .{name});
}

const testing = std.testing;

test "the tools array is JSON, with every tool" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = (try proto.parseJson(a, try tools(a))).array.items;
    const names = [_][]const u8{ "zalo_status", "zalo_list_chats", "zalo_read_messages", "zalo_search_messages", "zalo_contacts", "zalo_find_user", "zalo_send_message" };
    try testing.expectEqual(names.len, list.len);
    for (names, list) |want, tool| {
        try testing.expectEqualStrings(want, proto.fieldStr(tool, "name").?);
        try testing.expect(proto.fieldStr(tool, "description").?.len > 0);
        try testing.expectEqualStrings("object", proto.fieldStr(proto.field(tool, "inputSchema"), "type").?);
    }
    try testing.expectEqualStrings("threadId", proto.field(proto.field(list[6], "inputSchema"), "required").?.array.items[0].string);
}

test "arguments the way JS reads them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try proto.parseJson(a, "{\"threadId\":123,\"query\":null,\"limit\":\"20\",\"zero\":0,\"big\":9999,\"neg\":-5}");
    try testing.expectEqualStrings("123", try argStr(a, args, "threadId"));
    try testing.expectEqualStrings("", try argStr(a, args, "query"));
    try testing.expectEqualStrings("", try argStr(a, args, "missing"));
    try testing.expectEqual(@as(usize, 20), num(proto.field(args, "limit"), 50, 500));
    try testing.expectEqual(@as(usize, 50), num(proto.field(args, "missing"), 50, 500));
    try testing.expectEqual(@as(usize, 50), num(proto.field(args, "zero"), 50, 500));
    try testing.expectEqual(@as(usize, 500), num(proto.field(args, "big"), 50, 500));
    try testing.expectEqual(@as(usize, 1), num(proto.field(args, "neg"), 50, 500));

    // a message as Claude reads it
    const line = try fmtMsg(a, .{ .from_name = "Lan", .from_id = "55", .group = true, .text = "ok", .quote = "Tôi: hỏi" });
    try testing.expectEqualStrings("[-] Lan (55): ↪ «Tôi: hỏi» ok", line);
    try testing.expectEqualStrings("[-] Tôi: ok", try fmtMsg(a, .{ .mine = true, .from_name = "x", .text = "ok" }));
}
