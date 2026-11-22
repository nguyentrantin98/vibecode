//! Office tab: Word, Excel, PowerPoint and PDF, each open file in an ONLYOFFICE editor (onlyoffice.zig)
//! that the page drives and that turns the file into its bytes and back. This side only:
//!   - reads and writes the files, with the file dialog, and keeps the "recent files" list;
//!   - relays Claude's vibe-office tool calls to the page, which runs them on what the user sees:
//!     `office:request` goes out (also kept in a queue until the tab is mounted and picks it up),
//!     `office_reply` brings the answer back.

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const dialog = @import("dialog.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const commands = .{
    .{ "office_pick", office_pick },
    .{ "office_read_file", office_read_file },
    .{ "office_write_file", office_write_file },
    .{ "office_backup", office_backup },
    .{ "office_recent", office_recent },
    .{ "office_recent_add", office_recent_add },
    .{ "office_pending", office_pending },
    .{ "office_reply", office_reply },
};

// ---------------- files ----------------

/// What each workspace of the Office tab opens; the first one is what it creates.
const DOC_EXTS = [_][]const u8{ "docx", "doc", "odt", "rtf" };
const SHEET_EXTS = [_][]const u8{ "xlsx", "xls", "ods", "csv" };
const SLIDE_EXTS = [_][]const u8{ "pptx", "ppt", "odp" };

/// File dialog: pick a file to open, or (`save`) name a new one. `kind` narrows the file types:
/// "doc", "sheet", "slide" or "pdf" (anything else: every kind the Office tab opens).
fn office_pick(c: *ipc.Call, a: struct { save: bool, kind: ?[]const u8 = null }) !?[]u8 {
    const Kind = enum { doc, sheet, slide, pdf };
    const kind = std.meta.stringToEnum(Kind, a.kind orelse "");
    // a new file is made in its workspace's own format
    const doc: []const []const u8 = if (a.save) DOC_EXTS[0..1] else &DOC_EXTS;
    const sheet: []const []const u8 = if (a.save) SHEET_EXTS[0..1] else &SHEET_EXTS;
    const slide: []const []const u8 = if (a.save) SLIDE_EXTS[0..1] else &SLIDE_EXTS;
    const pdf: []const []const u8 = &.{"pdf"};
    const filter: dialog.Filter = if (kind) |k| switch (k) {
        .doc => .{ .name = settings.tr("Word document", "Tài liệu Word"), .extensions = doc },
        .sheet => .{ .name = settings.tr("Spreadsheet", "Bảng tính"), .extensions = sheet },
        .slide => .{ .name = settings.tr("Presentation", "Bản trình chiếu"), .extensions = slide },
        .pdf => .{ .name = "PDF", .extensions = pdf },
    } else .{
        .name = settings.tr("Documents, spreadsheets, presentations, PDF", "Tài liệu, bảng tính, trình chiếu, PDF"),
        .extensions = try std.mem.concat(c.arena, []const u8, &.{ doc, sheet, slide, pdf }),
    };
    if (!a.save) return dialog.pickFile(c.arena, .{ .filters = &.{filter} });
    const name = if (kind == .doc)
        settings.tr("Document.docx", "Tai lieu.docx")
    else if (kind == .slide)
        settings.tr("Presentation.pptx", "Trinh chieu.pptx")
    else
        settings.tr("Spreadsheet.xlsx", "Bang tinh.xlsx");
    return dialog.saveFile(c.arena, .{ .filters = &.{filter}, .default_name = name });
}

/// A file's bytes (an ArrayBuffer on the page).
fn office_read_file(c: *ipc.Call, a: struct { path: []const u8 }) !ipc.Bytes {
    const bytes = Dir.cwd().readFileAlloc(core.io, a.path, c.arena, .unlimited) catch |e|
        return c.fail("{s} {s}: {s}", .{ settings.tr("could not read", "không đọc được"), a.path, @errorName(e) });
    return .{ .bytes = bytes };
}

/// Writes a file the editor exported (base64).
fn office_write_file(c: *ipc.Call, a: struct { path: []const u8, data: []const u8 }) !void {
    const dec = std.base64.standard.Decoder;
    const bytes = try c.arena.alloc(u8, try dec.calcSizeForSlice(a.data));
    try dec.decode(bytes, a.data);
    Dir.cwd().writeFile(core.io, .{ .sub_path = a.path, .data = bytes }) catch |e| {
        if (settings.vi()) return c.fail("không lưu được {s} (file đang mở ở chương trình khác?): {s}", .{ a.path, @errorName(e) });
        return c.fail("could not save {s} (is it open in another program?): {s}", .{ a.path, @errorName(e) });
    };
}

/// Copies a file into `<userData>/office-backups` before the Office tab first overwrites it (the
/// editors don't keep everything a .docx/.xlsx can hold); returns the copy's path. Keeps the newest 200.
fn office_backup(c: *ipc.Call, a: struct { path: []const u8 }) ![]u8 {
    var fail: core.Fail = .{};
    const dir = try core.dataPath(c.arena, &.{"office-backups"});
    return backup(c.arena, a.path, dir, &fail) catch |e| return c.failMsg(fail.text(e));
}

fn backup(a: Allocator, path: []const u8, dir: []const u8, fail: *core.Fail) ![]u8 {
    try core.makePath(dir);
    const base = std.fs.path.basename(path);
    const name = try std.fmt.allocPrint(a, "{s} {s}", .{ try stamp(a), if (base.len > 0) base else "file" });
    const to = try std.fs.path.join(a, &.{ dir, name });
    Dir.copyFile(Dir.cwd(), path, Dir.cwd(), to, core.io, .{}) catch |e| {
        if (settings.vi()) return fail.set(a, "không sao lưu được {s}: {s}", .{ path, @errorName(e) });
        return fail.set(a, "could not back up {s}: {s}", .{ path, @errorName(e) });
    };
    var old: std.ArrayList([]const u8) = .empty;
    var d = try Dir.cwd().openDir(core.io, dir, .{ .iterate = true });
    defer d.close(core.io);
    var it = d.iterate();
    while (it.next(core.io) catch null) |e| try old.append(a, try a.dupe(u8, e.name));
    if (old.items.len > 200) {
        // the names start with the time of the copy: the oldest sort first
        std.mem.sort([]const u8, old.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        for (old.items[0 .. old.items.len - 200]) |n| d.deleteFile(core.io, n) catch {};
    }
    return to;
}

/// Local time as "20260131-235959".
fn stamp(a: Allocator) ![]u8 {
    if (core.is_windows) {
        const win = core.host.win.c;
        var t: win.SYSTEMTIME = undefined;
        win.GetLocalTime(&t);
        return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond });
    }
    // UTC elsewhere
    const secs: std.time.epoch.EpochSeconds = .{ .secs = core.nowMs() / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

// ---------------- recent files ----------------

const RECENT_MAX = 50;

pub const RecentFile = struct {
    path: []const u8,
    /// bytes; 0 when the file is gone
    size: u64,
    /// ms since epoch, 0 when unknown
    modified: u64,
    exists: bool,
};

fn recentFile(a: Allocator) ![]u8 {
    return core.dataPath(a, &.{"office-recent.json"});
}

fn recentPaths(a: Allocator) []const []const u8 {
    const file = recentFile(a) catch return &.{};
    const text = core.readFileAlloc(a, file, 16 << 20) catch return &.{};
    return core.fromJson([]const []const u8, a, text) catch &.{};
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const p: u8 = if (x == '/') '\\' else std.ascii.toLower(x);
        const q: u8 = if (y == '/') '\\' else std.ascii.toLower(y);
        if (p != q) return false;
    }
    return true;
}

/// `list` without `path`.
fn without(a: Allocator, list: []const []const u8, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |p| {
        if (!samePath(p, path)) try out.append(a, p);
    }
    return out.items;
}

/// Moves `path` to the top of `list` (adding it), keeping at most RECENT_MAX.
fn bump(a: Allocator, list: []const []const u8, path: []const u8) ![]const []const u8 {
    const rest = try without(a, list, path);
    const out = try a.alloc([]const u8, @min(rest.len + 1, RECENT_MAX));
    out[0] = path;
    @memcpy(out[1..], rest[0 .. out.len - 1]);
    return out;
}

fn info(path: []const u8) RecentFile {
    const st = Dir.cwd().statFile(core.io, path, .{}) catch return .{ .path = path, .size = 0, .modified = 0, .exists = false };
    return .{ .path = path, .size = st.size, .modified = @intCast(@max(0, st.mtime.toMilliseconds())), .exists = true };
}

/// Files opened in the Office tab, most recent first, with their size and last change on disk.
fn office_recent(c: *ipc.Call) ![]RecentFile {
    const paths = recentPaths(c.arena);
    const out = try c.arena.alloc(RecentFile, paths.len);
    for (paths, out) |p, *o| o.* = info(p);
    return out;
}

/// `remove`: take it off the list; otherwise put it on top.
fn office_recent_add(c: *ipc.Call, a: struct { path: []const u8, remove: ?bool = null }) !void {
    const cur = recentPaths(c.arena);
    const list = if (a.remove orelse false) try without(c.arena, cur, a.path) else try bump(c.arena, cur, a.path);
    try core.writeFile(try recentFile(c.arena), try core.toJson(c.arena, list));
}

// ---------------- Claude's tools, run by the page ----------------

pub const Request = struct {
    id: u64,
    tool: []const u8,
    /// JSON text
    args: []const u8,

    pub fn jsonStringify(r: Request, w: anytype) !void {
        try w.beginObject();
        try w.objectField("id");
        try w.write(r.id);
        try w.objectField("tool");
        try w.write(r.tool);
        try w.objectField("args");
        try w.beginWriteRaw();
        try w.writer.writeAll(r.args);
        w.endWriteRaw();
        try w.endObject();
    }
};

/// Where the page's answer to one call lands; `done` wakes the caller.
const Answer = struct {
    done: std.Io.Event = .unset,
    ok: bool = false,
    /// owned by `core.gpa`; null until the page answers
    text: ?[]u8 = null,
};

var next_id: std.atomic.Value(u64) = .init(1);
var mutex: core.Mutex = .{};
/// calls the page has not picked up yet (the Office tab mounts on first use); `args` owned by `core.gpa`
var pending: std.ArrayList(Request) = .empty;
var waiting: std.AutoHashMapUnmanaged(u64, *Answer) = .empty;

/// Takes `id` out of `pending` (with `mutex` held).
fn dropPending(id: u64) void {
    for (pending.items, 0..) |r, i| {
        if (r.id == id) {
            core.gpa.free(r.args);
            _ = pending.orderedRemove(i);
            return;
        }
    }
}

/// The calls waiting for the page; it runs each once and answers with `office_reply`.
fn office_pending(c: *ipc.Call) ![]Request {
    mutex.lock();
    defer mutex.unlock();
    const out = try c.arena.alloc(Request, pending.items.len);
    for (pending.items, out) |r, *o| o.* = .{ .id = r.id, .tool = r.tool, .args = try c.arena.dupe(u8, r.args) };
    for (pending.items) |r| core.gpa.free(r.args);
    pending.clearRetainingCapacity();
    return out;
}

fn office_reply(_: *ipc.Call, a: struct { id: u64, ok: bool, text: []const u8 }) !void {
    mutex.lock();
    defer mutex.unlock();
    dropPending(a.id);
    if (waiting.fetchRemove(a.id)) |kv| {
        const answer = kv.value;
        answer.text = try core.gpa.dupe(u8, a.text);
        answer.ok = a.ok;
        // the caller cannot leave before it takes `mutex`, which is still held here
        answer.done.set(core.io);
    }
}

pub const INSTRUCTIONS: []const u8 = "Read the files open in VIBE CODE's Office tab — the user sees them there, each in ONLYOFFICE: Word (.docx, .doc, .odt, .rtf), Excel (.xlsx, .xls, .ods, .csv), PowerPoint (.pptx, .ppt, .odp) and PDF. " ++
    "Several files can be open, one tab each; tools act on the one on screen of their kind unless `file` names another (its path or file name). " ++
    "Use these tools when the user mentions 'tab Office', 'the document/sheet/slides/PDF', 'tài liệu', 'bảng tính', 'trình chiếu', 'file Word/Excel/PowerPoint/PDF', or what is in them. Start with office_status. " ++
    "The tools only read: they see what the editor holds now, unsaved edits included. They cannot change a file; the user edits it in the editor, which saves it by itself.";

const file_arg =
    \\{ "type": "string", "description": "path or file name of an open file (default: the one on screen)" }
;

const tools_json =
    \\[
    \\  {
    \\    "name": "office_status",
    \\    "description": "The files open in the Office tab (by kind: Word, Excel, PowerPoint, PDF; the one on screen is marked): path, unsaved changes, read-only.",
    \\    "inputSchema": { "type": "object", "properties": {} }
    \\  },
    \\  {
    \\    "name": "office_open",
    \\    "description": "Open a Word, Excel, PowerPoint or PDF file in its own tab of the Office tab and show it (or just show it when it is open already). `create: true` makes a new empty .docx / .xlsx / .pptx at `path`.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": { "path": { "type": "string", "description": "absolute path" }, "create": { "type": "boolean" } },
    \\      "required": ["path"]
    \\    }
    \\  },
    \\  {
    \\    "name": "doc_read",
    \\    "description": "Text of an open Word document: one line per paragraph, table rows as cells joined by \" | \".",
    \\    "inputSchema": { "type": "object", "properties": { "file":
++ file_arg ++
    \\ } }
    \\  },
    \\  {
    \\    "name": "sheet_read",
    \\    "description": "Cells of one sheet as tab-separated rows, each starting with its row number; the first lines list the workbook's sheets and name the columns. Values are as stored (no number formats: dates are serial numbers); formula cells add ` [=FORMULA]`. Default: the first 200 rows of the sheet on screen. At most 1000 rows per call.",
    \\    "inputSchema": {
    \\      "type": "object",
    \\      "properties": { "file":
++ file_arg ++
    \\, "sheet": { "type": "string", "description": "sheet name (default: the one on screen)" }, "range": { "type": "string", "description": "e.g. \"A1:F100\" or \"A200:Z400\"" } }
    \\    }
    \\  },
    \\  {
    \\    "name": "slide_read",
    \\    "description": "Text of an open presentation, slide by slide. `slides`: e.g. \"1-5\" or \"3\" (default: the first 20 slides).",
    \\    "inputSchema": { "type": "object", "properties": { "file":
++ file_arg ++
    \\, "slides": { "type": "string" } } }
    \\  },
    \\  {
    \\    "name": "pdf_read",
    \\    "description": "Text of an open PDF, page by page. `pages`: e.g. \"1-5\" or \"3\" (default: the first 20 pages). Scanned PDFs (images only) have no text.",
    \\    "inputSchema": { "type": "object", "properties": { "file":
++ file_arg ++
    \\, "pages": { "type": "string" } } }
    \\  }
    \\]
;

/// The JSON text of the tools array.
pub fn tools(a: Allocator) ![]const u8 {
    _ = a;
    return tools_json;
}

const TOOLS = [_][]const u8{ "office_status", "office_open", "doc_read", "sheet_read", "slide_read", "pdf_read" };

/// Hands one call to the page (opening the Office tab if needed) and waits for its answer.
pub fn callTool(a: Allocator, name: []const u8, args: std.json.Value, fail: *core.Fail) anyerror![]const u8 {
    var answer: Answer = .{};
    const req = try enqueue(a, name, args, &answer, fail);
    core.emit("office:request", .{req});
    return wait(a, req, &answer, fail);
}

/// `answer` must stay where it is until `wait` returns.
fn enqueue(a: Allocator, name: []const u8, args: std.json.Value, answer: *Answer, fail: *core.Fail) !Request {
    const tool = for (TOOLS) |t| {
        if (std.mem.eql(u8, t, name)) break t;
    } else return fail.set(a, "unknown tool {s}", .{name});
    const req: Request = .{ .id = next_id.fetchAdd(1, .monotonic), .tool = tool, .args = try core.toJson(a, args) };
    mutex.lock();
    defer mutex.unlock();
    try waiting.put(core.gpa, req.id, answer);
    errdefer _ = waiting.remove(req.id);
    const kept = try core.gpa.dupe(u8, req.args);
    errdefer core.gpa.free(kept);
    try pending.append(core.gpa, .{ .id = req.id, .tool = tool, .args = kept });
    return req;
}

fn wait(a: Allocator, req: Request, answer: *Answer, fail: *core.Fail) ![]const u8 {
    answer.done.waitTimeout(core.io, .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } }) catch {};
    mutex.lock();
    _ = waiting.remove(req.id);
    dropPending(req.id);
    mutex.unlock();
    const text = answer.text orelse return fail.set(a, "The Office tab did not answer (is VIBE CODE's window open?)", .{});
    defer core.gpa.free(text);
    if (!answer.ok) return fail.set(a, "{s}", .{text});
    return a.dupe(u8, text);
}

// ---------------- tests ----------------

const testing = std.testing;

fn testInit() void {
    core.gpa = testing.allocator;
    core.io = testing.io;
}

test "recent list moves a file to the top once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try bump(a, &.{ "C:\\a.xlsx", "C:\\b.docx" }, "c:/B.docx");
    try testing.expectEqual(2, l.len);
    try testing.expectEqualStrings("c:/B.docx", l[0]);
    try testing.expectEqualStrings("C:\\a.xlsx", l[1]);
    var many: []const []const u8 = &.{};
    for (0..60) |i| many = try bump(a, many, try std.fmt.allocPrint(a, "C:\\f{d}.pdf", .{i}));
    try testing.expectEqual(RECENT_MAX, many.len);
    try testing.expectEqualStrings("C:\\f59.pdf", many[0]);
    try testing.expectEqual(1, (try without(a, l, "C:/A.XLSX")).len);
}

test "backup copies the file aside" {
    testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const src = try std.fs.path.join(a, &.{ dir, "Báo cáo.docx" });
    try core.writeFile(src, "original");
    var fail: core.Fail = .{};
    const to = try backup(a, src, try std.fs.path.join(a, &.{ dir, "bk" }), &fail);
    try testing.expect(std.mem.endsWith(u8, to, " Báo cáo.docx"));
    // "<dir>\bk\20260131-235959 Báo cáo.docx"
    const name = std.fs.path.basename(to);
    try testing.expectEqual(15 + " Báo cáo.docx".len, name.len);
    try testing.expectEqual('-', name[8]);
    try testing.expectEqualStrings("original", try core.readFileAlloc(a, to, 1 << 20));
    try testing.expect(info(to).exists and info(to).size == 8 and info(to).modified > 0);
    try testing.expect(!info(src[0 .. src.len - 1]).exists);
}

test "every listed tool is accepted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = try std.json.parseFromSliceLeaky(std.json.Value, a, try tools(a), .{});
    try testing.expectEqual(TOOLS.len, listed.array.items.len);
    for (listed.array.items, TOOLS) |t, name| {
        try testing.expectEqualStrings(name, t.object.get("name").?.string);
        try testing.expect(t.object.get("description").?.string.len > 0);
        try testing.expectEqualStrings("object", t.object.get("inputSchema").?.object.get("type").?.string);
    }
    const file = listed.array.items[3].object.get("inputSchema").?.object.get("properties").?.object.get("file").?;
    try testing.expectEqualStrings("string", file.object.get("type").?.string);
}

test "tool calls wait for the page" {
    testInit();
    defer {
        pending.clearAndFree(core.gpa);
        waiting.clearAndFree(core.gpa);
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var call: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    var fail: core.Fail = .{};

    const Caller = struct {
        req: Request,
        answer: Answer = .{},
        fail: core.Fail = .{},
        arena: std.heap.ArenaAllocator = .init(testing.allocator),
        result: anyerror![]const u8 = error.Unexpected,
        fn run(s: *@This()) void {
            s.result = wait(s.arena.allocator(), s.req, &s.answer, &s.fail);
        }
    };
    var caller: Caller = .{ .req = undefined };
    defer caller.arena.deinit();
    caller.req = try enqueue(a, "sheet_read", try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"range\":\"A1:B2\"}", .{}), &caller.answer, &fail);
    const id = caller.req.id;
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    // the page (mounted late) picks it up from the queue, then answers
    const picked = try office_pending(&call);
    try testing.expectEqual(1, picked.len);
    try testing.expectEqual(id, picked[0].id);
    try testing.expectEqualStrings("sheet_read", picked[0].tool);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "[{{\"id\":{d},\"tool\":\"sheet_read\",\"args\":{{\"range\":\"A1:B2\"}}}}]", .{id}),
        try core.toJson(a, picked),
    );
    try testing.expectEqual(0, (try office_pending(&call)).len);
    try office_reply(&call, .{ .id = id, .ok = true, .text = "ok from page" });
    thread.join();
    try testing.expectEqualStrings("ok from page", try caller.result);

    var answer: Answer = .{};
    const req = try enqueue(a, "pdf_read", .{ .object = .empty }, &answer, &fail);
    try office_reply(&call, .{ .id = req.id, .ok = false, .text = "still opening" });
    try testing.expectError(error.Failed, wait(a, req, &answer, &fail));
    try testing.expectEqualStrings("still opening", fail.msg);
    try testing.expectEqual(0, pending.items.len);
    try testing.expectError(error.Failed, enqueue(a, "sheet_write", .null, &answer, &fail));
    try testing.expectEqualStrings("unknown tool sheet_write", fail.msg);
    try testing.expectError(error.Failed, enqueue(a, "rm_rf", .null, &answer, &fail));
}
