//! The Zalo store without a network: parsing, ingesting, the work feed, reading, recalls and the
//! cache on disk.
//!
//! Every store here lives in the testing allocator (leaks and double frees fail the test); what
//! the functions return on the way lives in each test's arena.

const std = @import("std");
const core = @import("../core.zig");
const zalo = @import("zalo.zig");
const proto = @import("proto.zig");
const listen = @import("listen.zig");
const types = @import("types.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Store = zalo.Store;
const Msg = listen.Msg;
const ZaloMessage = types.ZaloMessage;

const ME = "me";

fn storeAsMe() !Store {
    var s: Store = .init(testing.allocator);
    s.state.me = try types.clone(testing.allocator, @as(?types.ZaloSelf, .{ .id = ME, .name = "Tôi", .avatar = "" }));
    return s;
}

fn json(a: Allocator, text: []const u8) Value {
    return proto.parseJson(a, text) catch @panic("bad JSON in a test");
}

/// A message from `from` to me (or from me when `from` is ME) in a personal chat with `peer`.
fn dm(a: Allocator, peer: []const u8, from: []const u8, id: []const u8, ts: i64, text: []const u8) Msg {
    const mine = std.mem.eql(u8, from, ME);
    var o: std.json.ObjectMap = .empty;
    o.put(a, "msgId", .{ .string = id }) catch @panic("oom");
    o.put(a, "uidFrom", .{ .string = if (mine) "0" else from }) catch @panic("oom");
    o.put(a, "idTo", .{ .string = if (mine) peer else "0" }) catch @panic("oom");
    // the socket sends the time as a string
    o.put(a, "ts", .{ .string = std.fmt.allocPrint(a, "{d}", .{ts}) catch @panic("oom") }) catch @panic("oom");
    o.put(a, "msgType", .{ .string = "webchat" }) catch @panic("oom");
    o.put(a, "content", .{ .string = text }) catch @panic("oom");
    o.put(a, "dName", .{ .string = std.fmt.allocPrint(a, "Name {s}", .{from}) catch @panic("oom") }) catch @panic("oom");
    return listen.userMessage(a, ME, .{ .object = o }) catch @panic("oom");
}

/// A group message; `extra` (JSON) is merged into the socket data (mentions, quote…).
fn gm(a: Allocator, group: []const u8, from: []const u8, id: []const u8, ts: i64, text: []const u8, extra: []const u8) Msg {
    var o: std.json.ObjectMap = .empty;
    o.put(a, "msgId", .{ .string = id }) catch @panic("oom");
    o.put(a, "uidFrom", .{ .string = if (std.mem.eql(u8, from, ME)) "0" else from }) catch @panic("oom");
    o.put(a, "idTo", .{ .string = group }) catch @panic("oom");
    o.put(a, "ts", .{ .integer = ts }) catch @panic("oom");
    o.put(a, "msgType", .{ .string = "webchat" }) catch @panic("oom");
    o.put(a, "content", .{ .string = text }) catch @panic("oom");
    o.put(a, "dName", .{ .string = std.fmt.allocPrint(a, "Name {s}", .{from}) catch @panic("oom") }) catch @panic("oom");
    const e = json(a, extra);
    var it = e.object.iterator();
    while (it.next()) |kv| o.put(a, kv.key_ptr.*, kv.value_ptr.*) catch @panic("oom");
    return listen.groupMessage(a, ME, .{ .object = o }) catch @panic("oom");
}

fn expectIds(want: []const []const u8, list: []const ZaloMessage) !void {
    try testing.expectEqual(want.len, list.len);
    for (want, list) |w, got| try testing.expectEqualStrings(w, got.id);
}

fn expectJson(a: Allocator, want: []const u8, got: anytype) !void {
    const got_json = try core.toJson(a, got);
    if (!proto.jsonEql(json(a, want), json(a, got_json))) {
        std.debug.print("\nwant {s}\n got {s}\n", .{ want, got_json });
        return error.TestExpectedEqual;
    }
}

fn msg(id: []const u8, ts: i64) ZaloMessage {
    return .{ .id = id, .ts = ts };
}

fn freeList(list: *std.ArrayList(ZaloMessage)) void {
    for (list.items) |x| types.free(testing.allocator, x);
    list.deinit(testing.allocator);
}

/// A folder of its own for a test (the path, in `a`).
fn tempDir(a: Allocator, tmp: *testing.TmpDir) ![]u8 {
    core.gpa = testing.allocator;
    core.io = testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return a.dupe(u8, buf[0..n]);
}

/// What the save task would do, synchronously: the files written.
fn save(a: Allocator, folder: []const u8, s: *Store) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (try zalo.takeWrites(a, folder, s)) |w| {
        try core.writeFile(w.path, w.data);
        try paths.append(a, w.path);
    }
    return paths.items;
}

fn has(list: []const []const u8, x: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, x)) return true;
    return false;
}

const Arena = std.heap.ArenaAllocator;

// ---------------- parsing ----------------

test "attachments parse like zalo.ts" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const photo = (try zalo.parseAttachment(a, "chat.photo", json(a, "{\"href\":\"https://h\",\"thumb\":\"https://t\",\"params\":\"{\\\"hd\\\":\\\"https://hd\\\",\\\"width\\\":1920,\\\"height\\\":\\\"1080\\\"}\"}"))).?;
    try testing.expectEqualStrings("photo", photo.kind);
    try testing.expectEqualStrings("https://hd", photo.url.?);
    try testing.expectEqual(@as(?f64, 1920), photo.width);
    try testing.expectEqual(@as(?f64, 1080), photo.height);
    try expectJson(a, "{\"kind\":\"photo\",\"url\":\"https://hd\",\"thumb\":\"https://t\",\"width\":1920,\"height\":1080}", photo);
    try testing.expectEqualStrings("{\"kind\":\"photo\",\"url\":\"https://hd\",\"thumb\":\"https://t\",\"width\":1920,\"height\":1080}", try core.toJson(a, photo));
    const file = (try zalo.parseAttachment(a, "share.file", json(a, "{\"title\":\"a.PDF\",\"href\":\"https://f\",\"params\":{\"fileSize\":\"2048\",\"fileExt\":\"PDF\"}}"))).?;
    try testing.expectEqualStrings("file", file.kind);
    try testing.expectEqual(@as(?f64, 2048), file.size);
    try testing.expectEqualStrings("pdf", file.ext.?);
    const voice = (try zalo.parseAttachment(a, "chat.voice", json(a, "{\"href\":\"https://v\",\"params\":\"{\\\"duration\\\":2500}\"}"))).?;
    try testing.expectEqual(@as(?f64, 2.5), voice.duration);
    const card = (try zalo.parseAttachment(a, "chat.recommended", json(a, "{\"action\":\"recommened.user\",\"title\":\"Bob\",\"params\":\"{\\\"phone\\\":\\\"0909\\\"}\"}"))).?;
    try testing.expectEqualStrings("card", card.kind);
    try testing.expectEqualStrings("0909", card.desc.?);
    try testing.expect(try zalo.parseAttachment(a, "webchat", .{ .string = "hello" }) == null);
    try testing.expectEqualStrings("[file] a.PDF https://f", try zalo.contentText(a, file, json(a, "{}")));
    try testing.expectEqualStrings("[tin nhắn]", try zalo.contentText(a, null, json(a, "{}")));
    // the label in small letters, Vietnamese included
    try testing.expectEqualStrings("[ảnh] https://hd", try zalo.contentText(a, photo, json(a, "{}")));
}

test "more attachment kinds" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const video = (try zalo.parseAttachment(a, "chat.video.msg", json(a, "{\"href\":\"https://v\",\"params\":{\"video_width\":720,\"video_height\":1280,\"duration\":61000}}"))).?;
    try testing.expectEqualStrings("video", video.kind);
    try testing.expectEqual(@as(?f64, 720), video.width);
    try testing.expectEqual(@as(?f64, 1280), video.height);
    try testing.expectEqual(@as(?f64, 61), video.duration);
    try testing.expectEqualStrings("sticker", (try zalo.parseAttachment(a, "chat.sticker", json(a, "{\"id\":42,\"catId\":7}"))).?.kind);
    // a sticker without an id is nothing we can show
    try testing.expect(try zalo.parseAttachment(a, "chat.sticker", json(a, "{\"catId\":7}")) == null);
    try testing.expectEqualStrings("location", (try zalo.parseAttachment(a, "chat.location.new", json(a, "{\"title\":\"Nhà\"}"))).?.kind);
    try testing.expectEqualStrings("link", (try zalo.parseAttachment(a, "chat.link", json(a, "{\"href\":\"https://x\",\"action\":\"recommened.link\"}"))).?.kind);
    try testing.expectEqual(@as(?f64, 10), (try zalo.parseAttachment(a, "chat.gif", json(a, "{\"href\":\"https://g\",\"params\":{\"width\":10,\"height\":20}}"))).?.width);
    try testing.expectEqualStrings("photo", (try zalo.parseAttachment(a, "chat.doodle", json(a, "{\"href\":\"https://d\"}"))).?.kind);
    try testing.expectEqualStrings("other", (try zalo.parseAttachment(a, "chat.todo", json(a, "{\"title\":\"x\"}"))).?.kind);
    // bad params: ignored, not a failure
    const p = (try zalo.parseAttachment(a, "chat.photo", json(a, "{\"href\":\"https://h\",\"params\":\"{not json\"}"))).?;
    try testing.expectEqualStrings("https://h", p.url.?);
    try testing.expect(p.width == null);
}

test "previews" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x: ZaloMessage = .{ .text = "hi" };
    try testing.expectEqualStrings("hi", try zalo.previewOf(a, x));
    x.att = .{ .kind = "file", .title = "a.pdf" };
    try testing.expectEqualStrings("📎 a.pdf", try zalo.previewOf(a, x));
    x.att = .{ .kind = "photo" };
    try testing.expectEqualStrings("🖼 Ảnh", try zalo.previewOf(a, x));
    x.att = .{ .kind = "link", .url = "https://x" };
    try testing.expectEqualStrings("🔗 https://x", try zalo.previewOf(a, x));
    x.recalled = true;
    try testing.expectEqualStrings("Tin nhắn đã thu hồi", try zalo.previewOf(a, x));
    try testing.expectEqualStrings("Tin nhắn thoại", zalo.attachLabel("voice"));
    try testing.expectEqualStrings("Tin nhắn", zalo.attachLabel("???"));
    // characters, not bytes
    try testing.expectEqualStrings("chà", zalo.firstChars("chào bạn", 3));
    try testing.expectEqualStrings("👋x", zalo.firstChars("👋x", 9));
}

test "message from the socket" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = .init(testing.allocator);
    defer s.deinit();
    const m = try listen.groupMessage(a, ME, json(a,
        \\{"msgId":"7300000000000000001","cliMsgId":"1731","uidFrom":"55","idTo":"g1","dName":"Lan",
        \\ "ts":"1731999999999","msgType":"webchat","content":"chào","ttl":0,"st":3,"at":0,"cmd":521,
        \\ "quote":{"fromD":"Tôi","msg":"hỏi","globalMsgId":99,"ownerId":1},
        \\ "mentions":[{"uid":"me","pos":0,"len":3}]}
    ));
    const z = try zalo.toMessage(a, &s, m);
    const text = try core.toJson(a, z);
    const v = json(a, text);
    try testing.expectEqualStrings("7300000000000000001", proto.fieldStr(v, "id").?);
    try testing.expectEqualStrings("g1", proto.fieldStr(v, "threadId").?);
    try testing.expectEqualStrings("Lan", proto.fieldStr(v, "fromName").?);
    try testing.expectEqual(@as(i64, 1731999999999), proto.field(v, "ts").?.integer);
    try testing.expectEqualStrings("chào", proto.fieldStr(v, "text").?);
    try testing.expectEqualStrings("Tôi: hỏi", proto.fieldStr(v, "quote").?);
    try testing.expect(proto.jsonEql(json(a, "{\"id\":\"99\",\"from\":\"Tôi\",\"text\":\"hỏi\"}"), proto.field(v, "reply").?));
    try testing.expect(proto.jsonEql(json(a, "[{\"uid\":\"me\",\"pos\":0,\"len\":3}]"), proto.field(v, "mentions").?));
    try testing.expectEqual(true, proto.field(v, "group").?.bool);
    try testing.expectEqual(false, proto.field(v, "self").?.bool);
    try testing.expectEqualStrings("webchat", proto.fieldStr(v, "type").?);
    // nothing only the old chat tab needed
    for ([_][]const u8{ "raw", "status", "cliMsgId", "att", "recalled", "mine", "kind" }) |k| try testing.expect(proto.field(v, k) == null);
    const back = try core.fromJson(ZaloMessage, a, text);
    try testing.expectEqualStrings(text, try core.toJson(a, back));
}

test "my message and names" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    try s.names.put(testing.allocator, try testing.allocator.dupe(u8, "55"), try testing.allocator.dupe(u8, "Lan (saved)"));
    const mine = try zalo.toMessage(a, &s, dm(a, "55", ME, "1", 10, "ok"));
    try testing.expect(mine.mine);
    try testing.expectEqualStrings(ME, mine.from_id);
    try testing.expectEqualStrings("Tôi", mine.from_name);
    try testing.expectEqualStrings("55", mine.thread_id);
    try testing.expectEqual(@as(i64, 10), mine.ts);
    // no dName: the saved name, then the id
    var m = try listen.userMessage(a, ME, json(a, "{\"msgId\":\"2\",\"uidFrom\":\"55\",\"idTo\":\"0\",\"ts\":11,\"content\":\"x\"}"));
    try testing.expectEqualStrings("Lan (saved)", (try zalo.toMessage(a, &s, m)).from_name);
    m = try listen.userMessage(a, ME, json(a, "{\"msgId\":\"3\",\"uidFrom\":\"77\",\"idTo\":\"0\",\"ts\":11,\"content\":\"x\"}"));
    try testing.expectEqualStrings("77", (try zalo.toMessage(a, &s, m)).from_name);
    // a quote that is only an attachment
    m = try listen.userMessage(a, ME, json(a, "{\"msgId\":4,\"uidFrom\":\"77\",\"idTo\":\"0\",\"ts\":11,\"content\":\"x\",\"quote\":{\"attach\":\"{}\",\"globalMsgId\":\"8\"}}"));
    const z = try zalo.toMessage(a, &s, m);
    try testing.expectEqualStrings("4", z.id);
    try testing.expectEqualStrings("undefined: [tệp đính kèm]", z.quote.?);
    try testing.expectEqualStrings("[tệp đính kèm]", z.reply.?.text);
    try testing.expectEqualStrings("", z.reply.?.from);
}

test "a missing timestamp is now" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    core.io = testing.io;
    var s: Store = .init(testing.allocator);
    defer s.deinit();
    const m = try listen.userMessage(a, ME, json(a, "{\"msgId\":\"1\",\"uidFrom\":\"5\",\"idTo\":\"0\",\"content\":\"x\"}"));
    const before = proto.nowMs();
    try testing.expect((try zalo.toMessage(a, &s, m)).ts >= before);
}

// ---------------- ordering & ingest ----------------

test "insert keeps time order and skips duplicates" {
    const a = testing.allocator;
    var l: std.ArrayList(ZaloMessage) = .empty;
    defer freeList(&l);
    try testing.expectEqual(@as(?usize, 0), try zalo.insertSorted(a, &l, msg("a", 10)));
    try testing.expectEqual(@as(?usize, 1), try zalo.insertSorted(a, &l, msg("c", 30)));
    // late arrival goes in its place
    try testing.expectEqual(@as(?usize, 1), try zalo.insertSorted(a, &l, msg("b", 20)));
    // the same message again
    try testing.expectEqual(@as(?usize, null), try zalo.insertSorted(a, &l, msg("b", 20)));
    // same time, another message: kept, after the first
    try testing.expectEqual(@as(?usize, 2), try zalo.insertSorted(a, &l, msg("b2", 20)));
    // older than everything
    try testing.expectEqual(@as(?usize, 0), try zalo.insertSorted(a, &l, msg("z", 1)));
    try expectIds(&.{ "z", "a", "b", "b2", "c" }, l.items);
}

test "keepNewest caps from the front" {
    const a = testing.allocator;
    var l: std.ArrayList(ZaloMessage) = .empty;
    defer freeList(&l);
    var buf: [16]u8 = undefined;
    for (0..zalo.MAX_PER_THREAD + 5) |i| {
        const id = try std.fmt.bufPrint(&buf, "{d}", .{i});
        _ = try zalo.insertSorted(a, &l, msg(id, @intCast(i)));
    }
    zalo.keepNewest(a, &l);
    try testing.expectEqual(zalo.MAX_PER_THREAD, l.items.len);
    try testing.expectEqualStrings("5", l.items[0].id);
    var short: std.ArrayList(ZaloMessage) = .empty;
    defer freeList(&short);
    _ = try zalo.insertSorted(a, &short, msg("a", 1));
    zalo.keepNewest(a, &short);
    try testing.expectEqual(@as(usize, 1), short.items.len);
}

test "ingest creates a named conversation" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    const got = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "1", 100, "chào anh")});
    try testing.expectEqual(@as(usize, 1), got.touched.count());
    try testing.expectEqualStrings("55", got.touched.keys()[0]);
    const t = s.threads.get("55").?;
    try testing.expectEqualStrings("Name 55", t.name);
    try testing.expect(!t.group and t.last_ts == 100);
    try testing.expectEqualStrings("chào anh", t.last);
    try testing.expectEqualStrings("Name 55", s.names.get("55").?);
    try testing.expect(s.dirty.contains("55") and s.meta_dirty);
}

test "ingest twice changes nothing" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    const batch = [_]Msg{ dm(a, "55", "55", "1", 100, "a"), dm(a, "55", ME, "2", 200, "b") };
    _ = try zalo.ingestInto(&s, a, &batch);
    for (s.dirty.keys()) |k| testing.allocator.free(k);
    s.dirty.clearRetainingCapacity();
    const again = try zalo.ingestInto(&s, a, &batch);
    try testing.expect(again.touched.count() == 0 and again.profiles.count() == 0);
    try testing.expectEqual(@as(usize, 2), s.messagesOf("55").len);
    try testing.expectEqual(@as(usize, 0), s.dirty.count());
}

test "replayed history does not replace the last line" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "new", 500, "mới nhất")});
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "old", 100, "cũ")});
    try expectIds(&.{ "old", "new" }, s.messagesOf("55"));
    try testing.expectEqualStrings("mới nhất", s.threads.get("55").?.last);
    try testing.expectEqual(@as(i64, 500), s.threads.get("55").?.last_ts);
}

test "a group's last line names the sender, and avatars are wanted" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ta = testing.allocator;
    var s = try storeAsMe();
    defer s.deinit();
    try s.names.put(ta, try ta.dupe(u8, "g1"), try ta.dupe(u8, "Team"));
    try s.avatars.put(ta, try ta.dupe(u8, "77"), try ta.dupe(u8, "https://a77"));
    const got = try zalo.ingestInto(&s, a, &.{ gm(a, "g1", "55", "1", 10, "hello", "{}"), gm(a, "g1", "77", "2", 20, "yo", "{}"), gm(a, "g1", ME, "3", 30, "ok", "{}") });
    const t = s.threads.get("g1").?;
    try testing.expectEqualStrings("Team", t.name);
    try testing.expect(t.group);
    try testing.expectEqualStrings("ok", t.last);
    // 55 has no avatar yet; 77 has one; my own never asked
    try testing.expectEqual(@as(usize, 1), got.profiles.count());
    try testing.expectEqualStrings("55", got.profiles.keys()[0]);
    _ = try zalo.ingestInto(&s, a, &.{gm(a, "g1", "55", "4", 40, "bye", "{}")});
    try testing.expectEqualStrings("Name 55: bye", s.threads.get("g1").?.last);
}

test "ingest caps each conversation" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    var batch: std.ArrayList(Msg) = .empty;
    for (0..zalo.MAX_PER_THREAD + 20) |i| try batch.append(a, dm(a, "55", "55", try std.fmt.allocPrint(a, "m{d}", .{i}), @intCast(i + 1), "x"));
    _ = try zalo.ingestInto(&s, a, batch.items);
    const l = s.messagesOf("55");
    try testing.expectEqual(zalo.MAX_PER_THREAD, l.len);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "m{d}", .{zalo.MAX_PER_THREAD + 19}), l[l.len - 1].id);
    try testing.expectEqualStrings("m20", l[0].id);
}

test "ingest skips messages without an id and learns names" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ta = testing.allocator;
    var s = try storeAsMe();
    defer s.deinit();
    const no_id = try listen.userMessage(a, ME, json(a, "{\"uidFrom\":\"5\",\"idTo\":\"0\",\"ts\":1,\"content\":\"?\"}"));
    try testing.expectEqual(@as(usize, 0), (try zalo.ingestInto(&s, a, &.{no_id})).touched.count());
    try testing.expectEqual(@as(usize, 0), s.messagesOf("5").len);
    // a sender's new display name replaces the old one
    try s.names.put(ta, try ta.dupe(u8, "55"), try ta.dupe(u8, "Old"));
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "1", 1, "x")});
    try testing.expectEqualStrings("Name 55", s.names.get("55").?);
}

test "many conversations in one batch" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    var batch: std.ArrayList(Msg) = .empty;
    for (0..50) |i| {
        const u = try std.fmt.allocPrint(a, "u{d}", .{i});
        try batch.append(a, dm(a, u, u, try std.fmt.allocPrint(a, "id{d}", .{i}), @intCast(i), "x"));
    }
    const got = try zalo.ingestInto(&s, a, batch.items);
    try testing.expectEqual(@as(usize, 50), got.touched.count());
    try testing.expectEqual(@as(usize, 50), s.threads.count());
    try testing.expectEqual(@as(usize, 50), s.dirty.count());
}

// ---------------- the work feed ----------------

fn feedIds(a: Allocator, t: types.WorkThread) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.msgs, 0..) |x, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, x.id);
    }
    return out.items;
}

test "personal chats with incoming messages count" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "55", "55", "1", 100, "giúp mình"), dm(a, "55", ME, "2", 110, "ok") });
    const f = try zalo.workFeedIn(a, &s, 0, 10, 10, null);
    try testing.expectEqual(@as(usize, 1), f.len);
    try testing.expectEqualStrings("Name 55", f[0].name);
    try testing.expectEqualStrings("55", f[0].thread_id);
    const x = f[0].msgs;
    try testing.expectEqual(@as(usize, 2), x.len);
    try testing.expect(std.mem.eql(u8, x[0].id, "1") and x[0].to_me and !x[0].mine);
    try testing.expect(std.mem.eql(u8, x[1].id, "2") and !x[1].to_me and x[1].mine);
    try testing.expectEqualStrings("Tôi", x[1].from);
    try testing.expectEqualStrings("Name 55", x[0].from);
    try testing.expectEqualStrings("55", x[0].from_id);
    try testing.expectEqualStrings("giúp mình", x[0].text);
}

test "chats with only my messages do not" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", ME, "1", 100, "hi")});
    try testing.expectEqual(@as(usize, 0), (try zalo.workFeedIn(a, &s, 0, 10, 10, null)).len);
}

test "groups need a mention or a reply to me" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{gm(a, "g1", "55", "1", 10, "chuyện phiếm", "{}")});
    try testing.expectEqual(@as(usize, 0), (try zalo.workFeedIn(a, &s, 0, 10, 10, null)).len);

    _ = try zalo.ingestInto(&s, a, &.{gm(a, "g1", "55", "2", 20, "@me làm cái này", "{\"mentions\":[{\"uid\":\"me\",\"pos\":0,\"len\":3}]}")});
    const f = try zalo.workFeedIn(a, &s, 0, 10, 10, null);
    try testing.expectEqual(@as(usize, 1), f.len);
    // the small talk before it is left out
    try testing.expectEqualStrings("2", try feedIds(a, f[0]));

    // someone else mentioned: not for me
    var s2 = try storeAsMe();
    defer s2.deinit();
    _ = try zalo.ingestInto(&s2, a, &.{gm(a, "g2", "55", "1", 10, "@bob", "{\"mentions\":[{\"uid\":\"bob\",\"pos\":0,\"len\":4}]}")});
    try testing.expectEqual(@as(usize, 0), (try zalo.workFeedIn(a, &s2, 0, 10, 10, null)).len);
}

test "a reply to my group message counts" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{
        gm(a, "g1", ME, "100", 10, "ai làm giúp?", "{}"),
        gm(a, "g1", "55", "101", 20, "chuyện khác", "{}"),
        gm(a, "g1", "66", "102", 30, "để em", "{\"quote\":{\"fromD\":\"Tôi\",\"msg\":\"ai làm giúp?\",\"globalMsgId\":\"100\"}}"),
        gm(a, "g1", ME, "103", 40, "cảm ơn", "{}"),
    });
    const f = try zalo.workFeedIn(a, &s, 0, 10, 10, null);
    try testing.expectEqual(@as(usize, 1), f.len);
    // from the reply on: the reply and my answer, not the other member's chatter
    try testing.expectEqualStrings("102,103", try feedIds(a, f[0]));
    try testing.expectEqualStrings("[trả lời Tôi: \"ai làm giúp?\"] để em", f[0].msgs[0].text);
}

test "since, recalled and limits" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "55", "55", "old", 10, "cũ"), dm(a, "55", "55", "a", 100, "1"), dm(a, "55", "55", "b", 200, "2"), dm(a, "55", "55", "c", 300, "3") });
    // older than `since`: out
    var f = try zalo.workFeedIn(a, &s, 50, 10, 10, null);
    try testing.expectEqualStrings("a,b,c", try feedIds(a, f[0]));
    // max_msgs keeps the newest
    f = try zalo.workFeedIn(a, &s, 50, 10, 2, null);
    try testing.expectEqualStrings("b,c", try feedIds(a, f[0]));
    // recalled ones are gone
    try testing.expect(try zalo.applyUndoIn(&s, a, .{ .thread_id = "55", .data = json(a, "{\"content\":{\"globalMsgId\":\"b\"}}") }));
    f = try zalo.workFeedIn(a, &s, 50, 10, 10, null);
    try testing.expectEqualStrings("a,c", try feedIds(a, f[0]));
    // nothing new since: the conversation drops out
    try testing.expectEqual(@as(usize, 0), (try zalo.workFeedIn(a, &s, 1000, 10, 10, null)).len);
}

test "the feed is newest first, capped and filterable" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "a", "a", "1", 100, "x"), dm(a, "b", "b", "2", 300, "x"), dm(a, "c", "c", "3", 200, "x") });
    const names = struct {
        fn of(al: Allocator, f: []const types.WorkThread) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (f) |t| try out.appendSlice(al, t.thread_id);
            return out.items;
        }
    }.of;
    try testing.expectEqualStrings("bca", try names(a, try zalo.workFeedIn(a, &s, 0, 10, 10, null)));
    try testing.expectEqualStrings("bc", try names(a, try zalo.workFeedIn(a, &s, 0, 2, 10, null)));
    try testing.expectEqualStrings("a", try names(a, try zalo.workFeedIn(a, &s, 0, 10, 10, &.{ "a", "missing" })));
}

test "long texts are cut" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    // two bytes a character: cut by characters, never inside one
    const long = try a.alloc(u8, 4000);
    for (0..2000) |i| long[i * 2 ..][0..2].* = "à".*;
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "1", 1, long)});
    const text = (try zalo.workFeedIn(a, &s, 0, 1, 1, null))[0].msgs[0].text;
    try testing.expectEqual(@as(usize, 600), try std.unicode.utf8CountCodepoints(text));
    // the conversation list's line too
    try testing.expectEqual(@as(usize, 200), try std.unicode.utf8CountCodepoints(s.threads.get("55").?.last));
}

// ---------------- recalls ----------------

test "a recall clears the message and the last line" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    const photo = try listen.userMessage(a, ME, json(a, "{\"msgId\":\"9\",\"uidFrom\":\"55\",\"idTo\":\"0\",\"ts\":50,\"msgType\":\"chat.photo\",\"content\":{\"href\":\"https://p\"},\"quote\":{\"msg\":\"q\",\"globalMsgId\":1}}"));
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "55", "55", "1", 10, "a"), photo });
    try testing.expectEqualStrings("🖼 Ảnh", s.threads.get("55").?.last);
    for (s.dirty.keys()) |k| testing.allocator.free(k);
    s.dirty.clearRetainingCapacity();
    try testing.expect(try zalo.applyUndoIn(&s, a, .{ .thread_id = "55", .data = json(a, "{\"content\":{\"globalMsgId\":\"9\"}}") }));
    const list = s.messagesOf("55");
    const x = list[list.len - 1];
    try testing.expect(x.recalled == true and x.att == null and x.reply == null);
    try testing.expectEqualStrings("Tin nhắn đã được thu hồi", x.text);
    try testing.expectEqualStrings("Tin nhắn đã thu hồi", s.threads.get("55").?.last);
    try testing.expect(s.dirty.contains("55"));
    // unknown message / conversation: nothing happens
    try testing.expect(!try zalo.applyUndoIn(&s, a, .{ .thread_id = "55", .data = json(a, "{\"content\":{\"globalMsgId\":\"nope\"}}") }));
    try testing.expect(!try zalo.applyUndoIn(&s, a, .{ .thread_id = "zz", .data = json(a, "{\"content\":{\"globalMsgId\":\"9\"}}") }));
}

// ---------------- reading ----------------

test "reading pages back through history" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    var batch: std.ArrayList(Msg) = .empty;
    for (1..11) |i| try batch.append(a, dm(a, "55", "55", try std.fmt.allocPrint(a, "m{d}", .{i}), @intCast(i * 10), "x"));
    _ = try zalo.ingestInto(&s, a, batch.items);
    try expectIds(&.{ "m8", "m9", "m10" }, try zalo.getMessagesIn(a, &s, "55", 3, null));
    // before 50: the three before it
    try expectIds(&.{ "m2", "m3", "m4" }, try zalo.getMessagesIn(a, &s, "55", 3, 50));
    try expectIds(&.{ "m1", "m2" }, try zalo.getMessagesIn(a, &s, "55", 100, 25));
    // 0 means "no limit in time"
    try testing.expectEqual(@as(usize, 10), (try zalo.getMessagesIn(a, &s, "55", 100, 0)).len);
    try testing.expectEqual(@as(usize, 0), (try zalo.getMessagesIn(a, &s, "55", 5, 5)).len);
    try testing.expectEqual(@as(usize, 0), (try zalo.getMessagesIn(a, &s, "nobody", 5, null)).len);
    // what is returned is a copy
    const got = try zalo.getMessagesIn(a, &s, "55", 1, null);
    try testing.expect(got[0].id.ptr != s.messagesOf("55")[9].id.ptr);
}

test "search finds text and senders" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "55", "55", "1", 10, "Báo cáo tuần"), dm(a, "66", "66", "2", 20, "báo cáo tháng"), dm(a, "66", "66", "3", 30, "khác") });
    try expectIds(&.{ "2", "1" }, try zalo.searchMessagesIn(a, &s, "BÁO CÁO", null, 10));
    try expectIds(&.{"1"}, try zalo.searchMessagesIn(a, &s, "báo cáo", "55", 10));
    try expectIds(&.{"2"}, try zalo.searchMessagesIn(a, &s, "báo cáo", null, 1));
    try expectIds(&.{ "3", "2" }, try zalo.searchMessagesIn(a, &s, "name 66", null, 10));
    try testing.expectEqual(@as(usize, 0), (try zalo.searchMessagesIn(a, &s, "   ", null, 10)).len);
    try testing.expectEqual(@as(usize, 0), (try zalo.searchMessagesIn(a, &s, "báo", "missing", 10)).len);
}

test "the conversation list filters and sorts" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "11", "11", "1", 10, "x"), dm(a, "22", "22", "2", 30, "x"), dm(a, "33", "33", "3", 20, "x") });
    const ids = struct {
        fn of(al: Allocator, list: []const types.ZaloThread) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (list) |t| try out.print(al, "{s} ", .{t.id});
            return out.items;
        }
    }.of;
    try testing.expectEqualStrings("22 33 11 ", try ids(a, try zalo.listThreadsIn(a, &s, "", 10)));
    try testing.expectEqualStrings("22 ", try ids(a, try zalo.listThreadsIn(a, &s, "", 1)));
    try testing.expectEqualStrings("33 ", try ids(a, try zalo.listThreadsIn(a, &s, "NAME 33", 10)));
    try testing.expectEqualStrings("11 ", try ids(a, try zalo.listThreadsIn(a, &s, "1", 10)));
    try testing.expectEqual(@as(usize, 0), (try zalo.listThreadsIn(a, &s, "nobody", 10)).len);
}

// ---------------- names & avatars ----------------

test "profiles fill names and avatars" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "1", 1, "x")});
    try types.setStr(testing.allocator, &s.threads.getPtr("55").?.name, "");
    const r = json(a, "{\"changed_profiles\":{\"55_0\":{\"avatar\":\"https://a\",\"displayName\":\"\",\"zaloName\":\"Lan Z\"},\"66\":{\"avatar\":\"\"}}}");
    try testing.expect(try zalo.applyProfiles(&s, r));
    try testing.expectEqualStrings("https://a", s.avatars.get("55").?);
    try testing.expectEqualStrings("Lan Z", s.names.get("55").?);
    try testing.expectEqualStrings("https://a", s.threads.get("55").?.avatar.?);
    try testing.expectEqualStrings("Lan Z", s.threads.get("55").?.name);
    // empty values are not stored
    try testing.expect(!s.avatars.contains("66"));
    try testing.expect(!try zalo.applyProfiles(&s, json(a, "{}")));
}

test "friends name personal chats" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "1", 1, "x")});
    try zalo.applyFriends(&s, a, json(a, "[{\"userId\":\"55\",\"displayName\":\"Lan\",\"avatar\":\"https://l\"},{\"userId\":\"\",\"displayName\":\"nobody\"}]").array.items);
    try testing.expectEqualStrings("Lan", s.threads.get("55").?.name);
    try testing.expectEqualStrings("https://l", s.threads.get("55").?.avatar.?);
    try testing.expect(!s.names.contains(""));
}

test "groups are named but not all added" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{gm(a, "g1", "55", "1", 1, "x", "{}")});
    try zalo.applyGroups(&s, a, json(a, "{\"gridInfoMap\":{\"g1\":{\"name\":\"Team\",\"avt\":\"https://t\"},\"g2\":{\"name\":\"Silent group\"}}}"));
    try testing.expectEqualStrings("Team", s.threads.get("g1").?.name);
    try testing.expectEqualStrings("https://t", s.threads.get("g1").?.avatar.?);
    // a group with no messages: its name is known, it isn't a conversation (yet)
    try testing.expectEqualStrings("Silent group", s.names.get("g2").?);
    try testing.expect(!s.threads.contains("g2"));
    _ = try zalo.ingestInto(&s, a, &.{gm(a, "g2", "55", "2", 2, "x", "{}")});
    try testing.expectEqualStrings("Silent group", s.threads.get("g2").?.name);
}

// ---------------- the cache on disk ----------------

test "file names stay inside the folder" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const join = std.fs.path.join;
    try testing.expectEqualStrings(try join(a, &.{ "base", "msgs", "123456.json" }), try zalo.threadFile(a, "base", "123456"));
    try testing.expectEqualStrings(try join(a, &.{ "base", "msgs", "g-1_a.json" }), try zalo.threadFile(a, "base", "g-1_a"));
    const evil = try zalo.threadFile(a, "base", "../../x");
    try testing.expectEqualStrings(try join(a, &.{ "base", "msgs" }), std.fs.path.dirname(evil).?);
    try testing.expect(std.mem.indexOf(u8, evil, "..") == null);
    try testing.expectEqualStrings("~2e2e2f2e2e2f78.json", std.fs.path.basename(evil));
    try testing.expect(!std.mem.eql(u8, try zalo.threadFile(a, "base", ""), try zalo.threadFile(a, "base", "x")));
}

test "the cache round-trips and writes only what changed" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tempDir(a, &tmp);
    var s = try storeAsMe();
    defer s.deinit();
    _ = try zalo.ingestInto(&s, a, &.{ dm(a, "55", "55", "1", 10, "a"), gm(a, "g1", "66", "2", 20, "b", "{}") });
    try s.avatars.put(testing.allocator, try testing.allocator.dupe(u8, "55"), try testing.allocator.dupe(u8, "https://a"));
    var written = try save(a, folder, &s);
    try testing.expectEqual(@as(usize, 3), written.len); // two conversations + cache.json
    // nothing changed: nothing to write
    try testing.expectEqual(@as(usize, 0), (try zalo.takeWrites(a, folder, &s)).len);
    // one new message: only that conversation (and the list)
    _ = try zalo.ingestInto(&s, a, &.{dm(a, "55", "55", "3", 30, "c")});
    written = try save(a, folder, &s);
    try testing.expectEqual(@as(usize, 2), written.len);
    const cache_json = try std.fs.path.join(a, &.{ folder, "cache.json" });
    try testing.expect(has(written, try zalo.threadFile(a, folder, "55")) and has(written, cache_json));

    var back: Store = .init(testing.allocator);
    defer back.deinit();
    try zalo.loadCache(a, folder, &back);
    try expectIds(&.{ "1", "3" }, back.messagesOf("55"));
    try expectIds(&.{"2"}, back.messagesOf("g1"));
    try testing.expectEqualStrings("c", back.threads.get("55").?.last);
    try testing.expectEqualStrings("Name 55", back.threads.get("55").?.name);
    try testing.expect(back.threads.get("g1").?.group);
    try testing.expectEqualStrings("https://a", back.avatars.get("55").?);
    try testing.expect(back.dirty.count() == 0 and !back.meta_dirty);
    const meta = json(a, try core.readFileAlloc(a, cache_json, 1 << 20));
    try testing.expectEqual(@as(i64, zalo.CACHE_VERSION), proto.field(meta, "version").?.integer);
    try testing.expect(proto.field(meta, "messages") == null);
    // the files are what the Rust build wrote: camelCase keys, nulls left out
    try testing.expectEqualStrings(
        "[{\"id\":\"2\",\"threadId\":\"g1\",\"group\":true,\"fromId\":\"66\",\"fromName\":\"Name 66\",\"self\":false,\"ts\":20,\"type\":\"webchat\",\"text\":\"b\"}]",
        try core.readFileAlloc(a, try zalo.threadFile(a, folder, "g1"), 1 << 20),
    );
    try testing.expect(proto.jsonEql(json(a, "{\"id\":\"g1\",\"group\":true,\"name\":\"\",\"lastTs\":20,\"last\":\"Name 66: b\"}"), proto.field(meta, "threads").?.array.items[1]));
}

test "the old single-file cache is split" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tempDir(a, &tmp);
    // version 1: messages inside cache.json, with fields this version no longer keeps
    try core.writeFile(try std.fs.path.join(a, &.{ folder, "cache.json" }),
        \\{"threads":[{"id":"55","group":false,"name":"Lan","lastTs":20,"last":"b","unread":3,"pinned":true}],
        \\ "messages":{"55":[
        \\   {"id":"2","threadId":"55","ts":20,"text":"b","cliMsgId":"x","status":"seen","raw":{"content":"b"}},
        \\   {"id":"1","threadId":"55","ts":10,"text":"a","reactions":{"/-heart":["66"]}}]},
        \\ "names":{"55":"Lan"},"avatars":{},"friends":["55"],"stickers":{"1":"https://s"},"syncedAt":123}
    );
    var s: Store = .init(testing.allocator);
    defer s.deinit();
    try zalo.loadCache(a, folder, &s);
    // sorted on the way in
    try expectIds(&.{ "1", "2" }, s.messagesOf("55"));
    try testing.expectEqualStrings("Lan", s.threads.get("55").?.name);
    try testing.expect(s.dirty.contains("55") and s.meta_dirty);
    _ = try save(a, folder, &s);
    var back: Store = .init(testing.allocator);
    defer back.deinit();
    try zalo.loadCache(a, folder, &back);
    try expectIds(&.{ "1", "2" }, back.messagesOf("55"));
    try testing.expect(core.isFile(try zalo.threadFile(a, folder, "55")));
}

test "a broken or missing cache starts empty" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tempDir(a, &tmp);
    const cache_json = try std.fs.path.join(a, &.{ folder, "cache.json" });
    var s: Store = .init(testing.allocator);
    defer s.deinit();
    try zalo.loadCache(a, folder, &s);
    try testing.expectEqual(@as(usize, 0), s.threads.count());
    try core.writeFile(cache_json, "{ not json");
    try zalo.loadCache(a, folder, &s);
    try testing.expectEqual(@as(usize, 0), s.threads.count());
    // a conversation file that is damaged: that conversation has no messages, the rest loads
    try core.writeFile(cache_json, "{\"version\":2,\"threads\":[{\"id\":\"a\"},{\"id\":\"b\"}]}");
    try core.writeFile(try zalo.threadFile(a, folder, "a"), "[{");
    try core.writeFile(try zalo.threadFile(a, folder, "b"), "[{\"id\":\"1\",\"ts\":1}]");
    try zalo.loadCache(a, folder, &s);
    try testing.expectEqual(@as(usize, 2), s.threads.count());
    try testing.expect(!s.messages.contains("a"));
    try testing.expectEqual(@as(usize, 1), s.messagesOf("b").len);
    // reading the same cache again replaces, it does not double
    try zalo.loadCache(a, folder, &s);
    try testing.expectEqual(@as(usize, 2), s.threads.count());
    try testing.expectEqual(@as(usize, 1), s.messagesOf("b").len);
}

// ---------------- live events ----------------

test "live messages are batched" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    core.gpa = testing.allocator;
    core.io = testing.io;
    var q: listen.Queue(listen.Event) = .{};
    defer q.deinit();
    var batch: std.ArrayList(listen.Event) = .empty;
    defer batch.deinit(core.gpa);
    var buf: [8]u8 = undefined;
    for (0..3) |i| _ = q.push(.{ .what = .{ .message = dm(a, "55", "55", try std.fmt.bufPrint(&buf, "{d}", .{i}), @intCast(i), "x") } });
    _ = q.push(.{ .what = .cipher_key });
    _ = q.push(.{ .what = .{ .message = dm(a, "55", "55", "9", 9, "x") } });
    var rest = zalo.nextBatch(q.tryPop().?, &q, &batch);
    try testing.expectEqual(@as(usize, 3), batch.items.len);
    try testing.expect(rest != null and rest.?.what == .cipher_key);
    // the message after the other event starts the next batch
    rest = zalo.nextBatch(q.tryPop().?, &q, &batch);
    try testing.expect(batch.items.len == 1 and rest == null);
    // a non-message event alone
    rest = zalo.nextBatch(.{ .what = .{ .closed = 1000 } }, &q, &batch);
    try testing.expect(batch.items.len == 0 and rest.?.what.closed == 1000);
}
