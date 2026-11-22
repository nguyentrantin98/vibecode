//! The conversation of a chat, for the Chat view (see `sessions.zig`).

const std = @import("std");
const core = @import("core.zig");
const u = @import("sessions_util.zig");
const Allocator = std.mem.Allocator;
const Value = u.Value;

/// One thing in the conversation as the Chat view draws it. On the wire: `{"kind":"user",…}`,
/// with `mid`, `output`, `diff` and `images` left out when false / unset / empty.
pub const ChatItem = union(enum) {
    /// a prompt you sent (mid: sent while Claude was working, it took it in during that turn)
    user: struct { text: []const u8, mid: bool, at: i64 },
    /// what Claude wrote (markdown)
    text: struct { text: []const u8, at: i64 },
    /// a tool call, and its result once it is back
    tool: Tool,
    /// a turn ended ("Worked for 33s"), or was interrupted (ms = 0)
    done: struct { ms: u64, at: i64 },

    pub const Tool = struct {
        id: []const u8,
        name: []const u8,
        /// one line: the command's description, the file, the pattern…
        label: []const u8,
        /// the full command / prompt / input, when the label doesn't already say it all
        detail: []const u8,
        output: ?[]const u8 = null,
        @"error": bool = false,
        /// lines a Write / Edit added and removed
        added: u32 = 0,
        removed: u32 = 0,
        /// a Write / Edit's change as unified-diff lines ("@@ -a,b +c,d @@" hunk heads, then " ", "+", "-" lines)
        diff: []const []const u8 = &.{},
        /// pictures the tool returned (screenshots…), saved as files: their paths
        images: []const []const u8 = &.{},
        at: i64,
    };

    pub fn jsonStringify(item: ChatItem, w: anytype) !void {
        try w.beginObject();
        try field(w, "kind", @tagName(item));
        switch (item) {
            .user => |x| {
                try field(w, "text", x.text);
                if (x.mid) try field(w, "mid", true);
                try field(w, "at", x.at);
            },
            .text => |x| {
                try field(w, "text", x.text);
                try field(w, "at", x.at);
            },
            .tool => |x| {
                try field(w, "id", x.id);
                try field(w, "name", x.name);
                try field(w, "label", x.label);
                try field(w, "detail", x.detail);
                if (x.output) |o| try field(w, "output", o);
                try field(w, "error", x.@"error");
                try field(w, "added", x.added);
                try field(w, "removed", x.removed);
                if (x.diff.len > 0) try field(w, "diff", x.diff);
                if (x.images.len > 0) try field(w, "images", x.images);
                try field(w, "at", x.at);
            },
            .done => |x| {
                try field(w, "ms", x.ms);
                try field(w, "at", x.at);
            },
        }
        try w.endObject();
    }
};

fn field(w: anytype, name: []const u8, v: anytype) !void {
    try w.objectField(name);
    try w.write(v);
}

pub const ChatTodo = struct {
    id: []const u8,
    text: []const u8,
    /// pending, in_progress, completed
    status: []const u8,
};

pub const ChatLog = struct {
    items: []const ChatItem,
    /// Claude's to-do list (TodoWrite / TaskCreate + TaskUpdate) as it stands now
    todos: []const ChatTodo,
    /// drawn before `items[todosAt]` (or at the end): where the list last changed
    todosAt: usize,
    /// items before the first one sent (only the last `LOG_KEEP` are)
    skipped: usize,
    /// tokens Claude wrote in the whole chat, and in its last turn
    outTokens: u64,
    turnOutTokens: u64,
};

/// the Chat view gets the last this many items, and this much of each tool's output
const LOG_KEEP = 400;
const OUTPUT_KEEP = 2000;
/// lines of a Write / Edit's diff kept for the Chat view
const DIFF_KEEP = 400;

/// A tool_result's content as text (images as a placeholder).
fn resultText(a: Allocator, v: ?Value) Allocator.Error![]const u8 {
    switch (v orelse return "") {
        .string => |s| return s,
        .array => |items| {
            var out: std.ArrayList(u8) = .empty;
            var first = true;
            for (items.items) |b| {
                const ty = u.strOf(b, "type") orelse continue;
                const t = if (std.mem.eql(u8, ty, "text"))
                    u.strOf(b, "text") orelse continue
                else if (std.mem.eql(u8, ty, "image"))
                    "[image]"
                else
                    continue;
                if (!first) try out.append(a, '\n');
                first = false;
                try out.appendSlice(a, t);
            }
            return out.items;
        },
        else => return "",
    }
}

/// The pictures in a tool_result (screenshots…), written once to temp files the Chat tab can show.
/// The paths are allocated in `a`.
fn resultImages(a: Allocator, tool_id: []const u8, v: ?Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var n: usize = 0;
    for (u.arr(v)) |b| {
        if (!u.isType(b, "image")) continue;
        defer n += 1;
        const src = u.get(b, "source") orelse continue;
        const data = u.strOf(src, "data") orelse continue;
        const mime = u.strOf(src, "media_type") orelse "image/png";
        const ext = if (std.mem.eql(u8, mime, "image/jpeg")) "jpg" else if (std.mem.eql(u8, mime, "image/gif")) "gif" else if (std.mem.eql(u8, mime, "image/webp")) "webp" else "png";
        const dir = try std.fs.path.join(a, &.{ core.tempDir(), "vibe-tool-images" });
        var name: std.ArrayList(u8) = .empty;
        for (tool_id) |c| if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') try name.append(a, c);
        try name.print(a, "-{d}.{s}", .{ n, ext });
        const file = try std.fs.path.join(a, &.{ dir, name.items });
        if (!core.exists(file)) {
            const dec = std.base64.standard.Decoder;
            const bytes = try core.gpa.alloc(u8, dec.calcSizeForSlice(data) catch continue);
            defer core.gpa.free(bytes);
            dec.decode(bytes, data) catch continue;
            core.makePath(dir) catch continue;
            std.Io.Dir.cwd().writeFile(core.io, .{ .sub_path = file, .data = bytes }) catch continue;
        }
        try out.append(a, file);
    }
    return out.items;
}

const Brief = struct { label: []const u8, detail: []const u8 = "" };

/// (label, detail) of a tool call.
fn toolBrief(a: Allocator, name: []const u8, input: ?Value) Allocator.Error!Brief {
    const eq = struct {
        fn any(s: []const u8, names: []const []const u8) bool {
            for (names) |n| if (std.mem.eql(u8, s, n)) return true;
            return false;
        }
    }.any;
    const In = struct {
        input: ?Value,
        fn s(in: @This(), k: []const u8) []const u8 {
            return u.strOf(in.input, k) orelse "";
        }
    };
    const in: In = .{ .input = input };
    if (eq(name, &.{ "Bash", "PowerShell" })) {
        const cmd = in.s("command");
        const desc = in.s("description");
        return .{ .label = if (desc.len == 0) u.firstLine(cmd) else desc, .detail = cmd };
    }
    if (eq(name, &.{ "Read", "Write", "Edit", "MultiEdit" })) return .{ .label = in.s("file_path") };
    if (eq(name, &.{"NotebookEdit"})) return .{ .label = in.s("notebook_path") };
    if (eq(name, &.{ "Grep", "Glob" })) {
        const path = in.s("path");
        return .{ .label = if (path.len == 0) in.s("pattern") else try std.fmt.allocPrint(a, "{s} in {s}", .{ in.s("pattern"), path }) };
    }
    if (eq(name, &.{"WebFetch"})) return .{ .label = in.s("url"), .detail = in.s("prompt") };
    if (eq(name, &.{"WebSearch"})) return .{ .label = in.s("query") };
    if (eq(name, &.{ "Agent", "Task" })) return .{ .label = in.s("description"), .detail = in.s("prompt") };
    if (eq(name, &.{"Skill"})) return .{ .label = in.s("skill") };
    if (eq(name, &.{"ToolSearch"})) return .{ .label = in.s("query") };
    const i = input orelse return .{ .label = "" };
    // keys in byte order, as serde_json's map keeps them
    const json = try u.jsonText(a, i, a);
    var label: []const u8 = "";
    for (try u.sortedKeys(a, i)) |k| {
        if (u.str(i.object.get(k))) |t| {
            label = u.firstLine(t);
            break;
        }
    }
    return .{ .label = label, .detail = if (std.mem.eql(u8, json, "{}")) "" else json };
}

/// Lines a Write / Edit added and removed, from its toolUseResult.
fn diffSize(r: ?Value) struct { u32, u32 } {
    if (r == null) return .{ 0, 0 };
    if (u.isType(r, "create")) return .{ if (u.strOf(r, "content")) |c| @intCast(u.countLines(c)) else 0, 0 };
    var add: u32 = 0;
    var del: u32 = 0;
    for (u.arr(u.get(r, "structuredPatch"))) |hunk| {
        for (u.arr(u.get(hunk, "lines"))) |x| {
            const l = u.str(x) orelse continue;
            if (std.mem.startsWith(u8, l, "+")) {
                add += 1;
            } else if (std.mem.startsWith(u8, l, "-")) {
                del += 1;
            }
        }
    }
    return .{ add, del };
}

/// A Write / Edit's change as unified-diff lines, from its toolUseResult (a new file: all "+").
fn diffLines(a: Allocator, r: ?Value) Allocator.Error![]const []const u8 {
    if (r == null) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    if (u.isType(r, "create")) {
        const content = u.strOf(r, "content") orelse "";
        try out.append(a, try std.fmt.allocPrint(a, "@@ -0,0 +1,{d} @@", .{u.countLines(content)}));
        var it = u.lines(content);
        while (it.next()) |l| {
            if (out.items.len >= DIFF_KEEP) break;
            try out.append(a, try std.mem.concat(a, u8, &.{ "+", l }));
        }
    } else {
        for (u.arr(u.get(r, "structuredPatch"))) |hunk| {
            if (out.items.len >= DIFF_KEEP) break;
            try out.append(a, try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{
                u.asU64(u.get(hunk, "oldStart")) orelse 0, u.asU64(u.get(hunk, "oldLines")) orelse 0,
                u.asU64(u.get(hunk, "newStart")) orelse 0, u.asU64(u.get(hunk, "newLines")) orelse 0,
            }));
            for (u.arr(u.get(hunk, "lines"))) |x| {
                if (out.items.len >= DIFF_KEEP) break;
                try out.append(a, try a.dupe(u8, u.str(x) orelse continue));
            }
        }
    }
    return out.items;
}

/// A prompt you typed, as written (null for injected rows: reminders, command output, notifications…).
fn promptText(a: Allocator, content: Value) Allocator.Error!?[]const u8 {
    const text: []const u8 = switch (content) {
        .string => |s| u.trim(s),
        .array => |items| blk: {
            for (items.items) |c| if (u.isType(c, "tool_result")) return null;
            var out: std.ArrayList(u8) = .empty;
            var first = true;
            for (items.items) |c| {
                if (!u.isType(c, "text")) continue;
                const t = u.trim(u.strOf(c, "text") orelse continue);
                if (std.mem.startsWith(u8, t, "<")) continue;
                if (!first) try out.append(a, '\n');
                first = false;
                try out.appendSlice(a, t);
            }
            break :blk out.items;
        },
        else => return null,
    };
    // a slash command: "/name args"
    if (try u.slashCommand(a, text)) |cmd| return cmd;
    if (text.len == 0 or text[0] == '<' or std.mem.startsWith(u8, text, "Caveat:")) return null;
    return text;
}

pub const LogScan = struct {
    items: std.ArrayList(ChatItem) = .empty,
    /// tool_use id → its item, to fill in the result
    tools: std.StringHashMapUnmanaged(usize) = .empty,
    /// TaskCreate calls waiting for the id their result gives the task
    creating: std.StringHashMapUnmanaged([]const u8) = .empty,
    todos: std.ArrayList(ChatTodo) = .empty,
    todos_at: usize = 0,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// output tokens per API message (its rows repeat the usage, growing): the chat's and the turn's sums
    msg_out: std.StringHashMapUnmanaged(u64) = .empty,
    out_tokens: u64 = 0,
    turn_out_tokens: u64 = 0,

    /// `a` owns what the scan keeps.
    pub fn feed(s: *LogScan, a: Allocator, text: []const u8) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "\"type\":\"user\"") == null and std.mem.find(u8, line, "\"type\":\"assistant\"") == null and
                std.mem.find(u8, line, "turn_duration") == null and std.mem.find(u8, line, "queued_command") == null) continue;
            _ = scratch.reset(.{ .retain_with_limit = 1 << 20 });
            const row = u.parseObj(sa, line) orelse continue;
            const assistant = u.isType(row, "assistant");
            const user = u.isType(row, "user");
            if (u.truthy(u.get(row, "isSidechain")) or u.truthy(u.get(row, "isMeta")) or u.truthy(u.get(row, "isCompactSummary"))) continue;
            // a resumed / replayed conversation can write the same row again
            if (u.strOf(row, "uuid")) |uuid| {
                const slot = try s.seen.getOrPut(a, uuid);
                if (slot.found_existing) continue;
                slot.key_ptr.* = try a.dupe(u8, uuid);
            }
            const at = u.rowTime(sa, row);

            if (u.isType(row, "system") and std.mem.eql(u8, u.strOf(row, "subtype") orelse "", "turn_duration")) {
                const ms = u.asU64(u.get(row, "durationMs")) orelse 0;
                try s.items.append(a, .{ .done = .{ .ms = @max(ms, 1), .at = at } });
                continue;
            }
            // a message sent while Claude worked ("Send now"): it took it in mid-turn
            if (u.isType(row, "attachment")) {
                const att = u.obj(u.get(row, "attachment")) orelse continue;
                if (!u.isType(att, "queued_command")) continue;
                if (u.strOf(att, "commandMode")) |mode| if (!std.mem.eql(u8, mode, "prompt")) continue;
                const t = try promptText(sa, u.get(att, "prompt") orelse continue) orelse continue;
                try s.items.append(a, .{ .user = .{ .text = try a.dupe(u8, t), .mid = true, .at = at } });
                continue;
            }
            if (!assistant and !user) continue;
            if (assistant) tokens: {
                const m = u.get(row, "message");
                const id = u.strOf(m, "id") orelse break :tokens;
                const out = u.asU64(u.get(u.get(m, "usage"), "output_tokens")) orelse break :tokens;
                const slot = try s.msg_out.getOrPut(a, id);
                if (!slot.found_existing) {
                    slot.key_ptr.* = try a.dupe(u8, id);
                    slot.value_ptr.* = 0;
                }
                if (out > slot.value_ptr.*) {
                    s.out_tokens += out - slot.value_ptr.*;
                    s.turn_out_tokens += out - slot.value_ptr.*;
                    slot.value_ptr.* = out;
                }
            }
            const content = u.get(u.get(row, "message"), "content") orelse continue;

            if (user) {
                if (try promptText(sa, content)) |t| {
                    if (std.mem.startsWith(u8, t, "[Request interrupted by user")) {
                        try s.items.append(a, .{ .done = .{ .ms = 0, .at = at } });
                    } else {
                        s.turn_out_tokens = 0;
                        try s.items.append(a, .{ .user = .{ .text = try a.dupe(u8, t), .mid = false, .at = at } });
                    }
                    continue;
                }
                const result = u.get(row, "toolUseResult");
                for (u.arr(content)) |b| {
                    if (b != .object or !u.isType(b, "tool_result")) continue;
                    const id = u.strOf(b, "tool_use_id") orelse "";
                    // a TaskCreate's result names the task it made
                    if (s.creating.fetchRemove(id)) |made| {
                        const task_id = if (u.get(u.get(result, "task"), "id")) |v| try u.jsString(sa, v) else "";
                        try s.todos.append(a, .{ .id = try a.dupe(u8, task_id), .text = made.value, .status = "pending" });
                        s.todos_at = s.items.items.len;
                        continue;
                    }
                    const tool = &s.items.items[s.tools.get(id) orelse continue].tool;
                    const out = try resultText(sa, u.get(b, "content"));
                    tool.images = try resultImages(a, id, u.get(b, "content"));
                    tool.output = try u.clip(a, try u.stripAnsi(sa, out, true), OUTPUT_KEEP);
                    tool.@"error" = u.truthy(u.get(b, "is_error"));
                    tool.added, tool.removed = diffSize(result);
                    tool.diff = try diffLines(a, result);
                }
                continue;
            }

            for (u.arr(content)) |b| {
                if (b != .object) continue;
                if (u.isType(b, "text")) {
                    const t = u.trim(u.strOf(b, "text") orelse "");
                    if (t.len > 0) try s.items.append(a, .{ .text = .{ .text = try a.dupe(u8, t), .at = at } });
                    continue;
                }
                if (!u.isType(b, "tool_use")) continue;
                const id = u.strOf(b, "id") orelse "";
                const name = u.strOf(b, "name") orelse "";
                const input = u.obj(u.get(b, "input"));
                // the to-do list is drawn as a checklist, not as tool calls
                if (std.mem.eql(u8, name, "TodoWrite")) {
                    s.todos.clearRetainingCapacity();
                    for (u.arr(u.get(input, "todos"))) |t| {
                        if (t != .object) continue;
                        try s.todos.append(a, .{
                            .id = try std.fmt.allocPrint(a, "{d}", .{s.todos.items.len}),
                            .text = try a.dupe(u8, try u.jsStringCoalesce(sa, t, &.{ "content", "subject" })),
                            .status = try a.dupe(u8, try u.jsStringCoalesce(sa, t, &.{"status"})),
                        });
                    }
                    s.todos_at = s.items.items.len;
                    continue;
                }
                if (std.mem.eql(u8, name, "TaskCreate")) {
                    const slot = try s.creating.getOrPut(a, id);
                    if (!slot.found_existing) slot.key_ptr.* = try a.dupe(u8, id);
                    slot.value_ptr.* = try a.dupe(u8, try u.jsStringCoalesce(sa, input, &.{"subject"}));
                    continue;
                }
                if (std.mem.eql(u8, name, "TaskUpdate")) {
                    const task_id = if (u.get(input, "taskId")) |v| try u.jsString(sa, v) else "";
                    const status = try u.jsStringCoalesce(sa, input, &.{"status"});
                    if (std.mem.eql(u8, status, "deleted")) {
                        var n: usize = 0;
                        for (s.todos.items) |t| {
                            if (std.mem.eql(u8, t.id, task_id)) continue;
                            s.todos.items[n] = t;
                            n += 1;
                        }
                        s.todos.items.len = n;
                    } else for (s.todos.items) |*t| {
                        if (!std.mem.eql(u8, t.id, task_id)) continue;
                        if (status.len > 0) t.status = try a.dupe(u8, status);
                        const subject = u.strOf(input, "subject") orelse "";
                        if (subject.len > 0) t.text = try a.dupe(u8, subject);
                        break;
                    }
                    s.todos_at = s.items.items.len;
                    continue;
                }
                if (s.tools.contains(id)) continue;
                const brief = try toolBrief(sa, name, input);
                const own_id = try a.dupe(u8, id);
                try s.tools.put(a, own_id, s.items.items.len);
                try s.items.append(a, .{ .tool = .{
                    .id = own_id,
                    .name = try a.dupe(u8, name),
                    .label = try u.clip(a, brief.label, 200),
                    .detail = try u.clip(a, brief.detail, OUTPUT_KEEP),
                    .at = at,
                } });
            }
        }
    }

    /// The conversation (its last `LOG_KEEP` items), pointing into the scan.
    pub fn log(s: *const LogScan) ChatLog {
        const skipped = s.items.items.len -| LOG_KEEP;
        return .{
            .items = s.items.items[skipped..],
            .todos = s.todos.items,
            .todosAt = s.todos_at -| skipped,
            .skipped = skipped,
            .outTokens = s.out_tokens,
            .turnOutTokens = s.turn_out_tokens,
        };
    }
};

// ---------------- tests ----------------

const testing = std.testing;

test "diffs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edit = u.parseLine(a,
        \\{"structuredPatch": [{"oldStart": 3, "oldLines": 2, "newStart": 3, "newLines": 2, "lines": [" a", "-b", "+c"]}]}
    );
    const lines = try diffLines(a, edit);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("@@ -3,2 +3,2 @@", lines[0]);
    try testing.expectEqualStrings(" a", lines[1]);
    try testing.expectEqualStrings("-b", lines[2]);
    try testing.expectEqualStrings("+c", lines[3]);
    try testing.expectEqual(@as(struct { u32, u32 }, .{ 1, 1 }), diffSize(edit));

    const create = u.parseLine(a, "{\"type\": \"create\", \"content\": \"x\\ny\"}");
    const made = try diffLines(a, create);
    try testing.expectEqual(@as(usize, 3), made.len);
    try testing.expectEqualStrings("@@ -0,0 +1,2 @@", made[0]);
    try testing.expectEqualStrings("+x", made[1]);
    try testing.expectEqualStrings("+y", made[2]);
    try testing.expectEqual(@as(struct { u32, u32 }, .{ 2, 0 }), diffSize(create));

    try testing.expectEqual(@as(usize, 0), (try diffLines(a, null)).len);
    try testing.expectEqual(@as(struct { u32, u32 }, .{ 0, 0 }), diffSize(null));
}

test "log: mid-turn messages and tokens" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: LogScan = .{};
    try s.feed(a,
        \\{"type":"user","uuid":"1","message":{"role":"user","content":"first"}}
        \\{"type":"assistant","uuid":"2","message":{"id":"m1","content":[{"type":"text","text":"a"}],"usage":{"output_tokens":5}}}
        \\{"type":"assistant","uuid":"3","message":{"id":"m1","content":[{"type":"text","text":"b"}],"usage":{"output_tokens":40}}}
        \\{"type":"attachment","uuid":"4","attachment":{"type":"queued_command","prompt":"also this","commandMode":"prompt"}}
        \\{"type":"attachment","uuid":"5","attachment":{"type":"queued_command","prompt":"<task-notification>x</task-notification>","commandMode":"task-notification"}}
        \\{"type":"user","uuid":"6","message":{"role":"user","content":"second"}}
        \\{"type":"assistant","uuid":"7","message":{"id":"m2","content":[{"type":"text","text":"c"}],"usage":{"output_tokens":7}}}
    );
    var users: std.ArrayList(u8) = .empty;
    for (s.items.items) |i| if (i == .user) try users.print(a, "{s}:{}|", .{ i.user.text, i.user.mid });
    try testing.expectEqualStrings("first:false|also this:true|second:false|", users.items);
    try testing.expectEqual(@as(u64, 47), s.out_tokens);
    try testing.expectEqual(@as(u64, 7), s.turn_out_tokens);
}

test "log: prompts, tools, results and the wire format" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: LogScan = .{};
    try s.feed(a,
        \\{"type":"user","uuid":"1","timestamp":"2025-01-02T03:04:05.678Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"},{"type":"text","text":"  fix the bug \n"}]}}
        \\{"type":"user","uuid":"1","timestamp":"2025-01-02T03:04:05.678Z","message":{"role":"user","content":"the same row again"}}
        \\{"type":"user","uuid":"1b","isMeta":true,"message":{"role":"user","content":"injected"}}
        \\{"type":"user","uuid":"1c","isSidechain":true,"message":{"role":"user","content":"a subagent's prompt"}}
        \\{"type":"user","uuid":"1d","message":{"role":"user","content":"Caveat: the messages below were generated by the user"}}
        \\{"type":"user","uuid":"1e","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-args>opus</command-args>"}}
        \\{"type":"assistant","uuid":"2","timestamp":"2025-01-02T03:04:06Z","message":{"id":"m1","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":" On it. "},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la\nwc","description":"List files"}},{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"C:\\a.txt"}},{"type":"tool_use","id":"toolu_3","name":"mcp__db__query","input":{"sql":"select 1\nfrom t","limit":5,"db":"main"}},{"type":"tool_use","id":"toolu_4","name":"Grep","input":{"pattern":"foo","path":"src"}}]}}
        \\{"type":"assistant","uuid":"2b","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"again"}}]}}
        \\{"type":"user","uuid":"3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\u001b[32mok\u001b[0m\u001b[2K"}]},"toolUseResult":{"stdout":"ok"}}
        \\{"type":"user","uuid":"4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"line 1"},{"type":"image","source":{}},{"type":"other"},{"type":"text","text":"line 2"}]}]},"toolUseResult":{"structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":2,"lines":["-a","+b","+c"]}]}}
        \\{"type":"system","subtype":"turn_duration","uuid":"5","durationMs":33000}
        \\{"type":"user","uuid":"6","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
    );
    const items = s.items.items;
    try testing.expectEqual(@as(usize, 9), items.len);
    try testing.expectEqualStrings("fix the bug", items[0].user.text);
    try testing.expectEqual(@as(i64, 1_735_787_045_678), items[0].user.at);
    try testing.expectEqualStrings("/model opus", items[1].user.text);
    try testing.expectEqualStrings("On it.", items[2].text.text);
    try testing.expectEqualStrings("List files", items[3].tool.label);
    try testing.expectEqualStrings("ls -la\nwc", items[3].tool.detail);
    try testing.expectEqualStrings("ok", items[3].tool.output.?);
    try testing.expect(!items[3].tool.@"error");
    try testing.expectEqualStrings("C:\\a.txt", items[4].tool.label);
    try testing.expectEqualStrings("line 1\n[image]\nline 2", items[4].tool.output.?);
    try testing.expect(items[4].tool.@"error");
    try testing.expectEqual(@as(u32, 2), items[4].tool.added);
    try testing.expectEqual(@as(u32, 1), items[4].tool.removed);
    try testing.expectEqual(@as(usize, 4), items[4].tool.diff.len);
    // any other tool: its first text input (keys in byte order) and the whole input
    try testing.expectEqualStrings("main", items[5].tool.label);
    try testing.expectEqualStrings("{\"db\":\"main\",\"limit\":5,\"sql\":\"select 1\\nfrom t\"}", items[5].tool.detail);
    try testing.expect(items[5].tool.output == null);
    try testing.expectEqualStrings("foo in src", items[6].tool.label);
    try testing.expectEqual(@as(u64, 33000), items[7].done.ms);
    try testing.expectEqual(@as(u64, 0), items[8].done.ms);

    const log = s.log();
    try testing.expectEqual(@as(usize, 0), log.skipped);
    const json = try core.toJson(a, log);
    try testing.expect(std.mem.startsWith(u8, json, "{\"items\":[{\"kind\":\"user\",\"text\":\"fix the bug\",\"at\":1735787045678},{\"kind\":\"user\",\"text\":\"/model opus\",\"at\":0},{\"kind\":\"text\",\"text\":\"On it.\",\"at\":1735787046000},"));
    try testing.expect(std.mem.find(u8, json, "{\"kind\":\"tool\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"label\":\"List files\",\"detail\":\"ls -la\\nwc\",\"output\":\"ok\",\"error\":false,\"added\":0,\"removed\":0,\"at\":1735787046000}") != null);
    try testing.expect(std.mem.find(u8, json, "\"output\":\"line 1\\n[image]\\nline 2\",\"error\":true,\"added\":2,\"removed\":1,\"diff\":[\"@@ -1,1 +1,2 @@\",\"-a\",\"+b\",\"+c\"],\"at\":") != null);
    try testing.expect(std.mem.find(u8, json, "{\"kind\":\"tool\",\"id\":\"toolu_4\",\"name\":\"Grep\",\"label\":\"foo in src\",\"detail\":\"\",\"error\":false,\"added\":0,\"removed\":0,\"at\":1735787046000}") != null);
    try testing.expect(std.mem.endsWith(u8, json, "{\"kind\":\"done\",\"ms\":33000,\"at\":0},{\"kind\":\"done\",\"ms\":0,\"at\":0}],\"todos\":[],\"todosAt\":0,\"skipped\":0,\"outTokens\":0,\"turnOutTokens\":0}"));

    var mid: ChatItem = .{ .user = .{ .text = "x", .mid = true, .at = 1 } };
    try testing.expectEqualStrings("{\"kind\":\"user\",\"text\":\"x\",\"mid\":true,\"at\":1}", try core.toJson(a, mid));
    mid = .{ .tool = .{ .id = "t", .name = "n", .label = "l", .detail = "d", .images = &.{"C:\\t\\a.png"}, .at = 2 } };
    try testing.expectEqualStrings("{\"kind\":\"tool\",\"id\":\"t\",\"name\":\"n\",\"label\":\"l\",\"detail\":\"d\",\"error\":false,\"added\":0,\"removed\":0,\"images\":[\"C:\\\\t\\\\a.png\"],\"at\":2}", try core.toJson(a, mid));
}

test "log: the to-do list" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: LogScan = .{};
    try s.feed(a,
        \\{"type":"assistant","uuid":"1","message":{"content":[{"type":"text","text":"plan"},{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"one","status":"completed"},{"subject":"two","status":"pending"}]}}]}}
    );
    try testing.expectEqual(@as(usize, 2), s.todos.items.len);
    try testing.expectEqualStrings("1", s.todos.items[1].id);
    try testing.expectEqualStrings("two", s.todos.items[1].text);
    try testing.expectEqual(@as(usize, 1), s.todos_at);
    try s.feed(a,
        \\{"type":"assistant","uuid":"2","message":{"content":[{"type":"tool_use","id":"t2","name":"TodoWrite","input":{"todos":[]}},{"type":"tool_use","id":"c1","name":"TaskCreate","input":{"subject":"build"}},{"type":"tool_use","id":"c2","name":"TaskCreate","input":{"subject":"test"}}]}}
        \\{"type":"user","uuid":"3","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"Task #1 created"}]},"toolUseResult":{"task":{"id":"1","subject":"build"}}}
        \\{"type":"user","uuid":"4","message":{"content":[{"type":"tool_result","tool_use_id":"c2","content":"Task #2 created"}]},"toolUseResult":{"task":{"id":2,"subject":"test"}}}
        \\{"type":"assistant","uuid":"5","message":{"content":[{"type":"tool_use","id":"u1","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress","subject":"build it"}},{"type":"tool_use","id":"u2","name":"TaskUpdate","input":{"taskId":"2","status":"deleted"}},{"type":"tool_use","id":"u3","name":"TaskUpdate","input":{"taskId":"9","status":"completed"}}]}}
    );
    try testing.expectEqual(@as(usize, 1), s.todos.items.len);
    try testing.expectEqualStrings("1", s.todos.items[0].id);
    try testing.expectEqualStrings("build it", s.todos.items[0].text);
    try testing.expectEqualStrings("in_progress", s.todos.items[0].status);
    // none of these are drawn as tool calls
    try testing.expectEqual(@as(usize, 1), s.items.items.len);
    try testing.expectEqualStrings("{\"items\":[{\"kind\":\"text\",\"text\":\"plan\",\"at\":0}],\"todos\":[{\"id\":\"1\",\"text\":\"build it\",\"status\":\"in_progress\"}],\"todosAt\":1,\"skipped\":0,\"outTokens\":0,\"turnOutTokens\":0}", try core.toJson(a, s.log()));
}

test "log: only the last items are sent" {
    core.gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: LogScan = .{};
    var text: std.ArrayList(u8) = .empty;
    for (0..LOG_KEEP + 5) |i| try text.print(a, "{{\"type\":\"user\",\"message\":{{\"content\":\"prompt {d}\"}}}}\n", .{i});
    try s.feed(a, text.items);
    s.todos_at = 3;
    const log = s.log();
    try testing.expectEqual(@as(usize, LOG_KEEP), log.items.len);
    try testing.expectEqual(@as(usize, 5), log.skipped);
    try testing.expectEqual(@as(usize, 0), log.todosAt);
    try testing.expectEqualStrings("prompt 5", log.items[0].user.text);
}

test "log: prompt text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a\nb", (try promptText(a, u.parseLine(a, "[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"<ide_opened_file>x</ide_opened_file>\"},{\"type\":\"text\",\"text\":\" b \"}]").?)).?);
    try testing.expect(try promptText(a, u.parseLine(a, "[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"tool_result\"}]").?) == null);
    try testing.expect(try promptText(a, u.parseLine(a, "\"  \"").?) == null);
    try testing.expect(try promptText(a, u.parseLine(a, "\"<task-notification>x</task-notification>\"").?) == null);
    try testing.expect(try promptText(a, u.parseLine(a, "{}").?) == null);
}

test "log: tool briefs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b = try toolBrief(a, "PowerShell", u.parseLine(a, "{\"command\":\"dir\\r\\ncd x\"}"));
    try testing.expectEqualStrings("dir", b.label);
    try testing.expectEqualStrings("dir\r\ncd x", b.detail);
    b = try toolBrief(a, "Glob", u.parseLine(a, "{\"pattern\":\"**/*.zig\"}"));
    try testing.expectEqualStrings("**/*.zig", b.label);
    b = try toolBrief(a, "WebFetch", u.parseLine(a, "{\"url\":\"https://x\",\"prompt\":\"read\"}"));
    try testing.expectEqualStrings("https://x", b.label);
    try testing.expectEqualStrings("read", b.detail);
    b = try toolBrief(a, "Whatever", u.parseLine(a, "{}"));
    try testing.expectEqualStrings("", b.label);
    try testing.expectEqualStrings("", b.detail);
    b = try toolBrief(a, "Whatever", null);
    try testing.expectEqualStrings("", b.detail);
    b = try toolBrief(a, "Whatever", u.parseLine(a, "{\"n\":1}"));
    try testing.expectEqualStrings("", b.label);
    try testing.expectEqualStrings("{\"n\":1}", b.detail);
}
