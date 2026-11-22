//! The session's cookies, kept the way zca-js keeps them in a tough-cookie `CookieJar`: the saved
//! session (`Credentials.cookie`) is tough-cookie's JSON (`jar.toJSON().cookies`), so sessions saved
//! by the Electron build load here and sessions saved here load there.

const std = @import("std");
const dates = @import("dates.zig");
const proto = @import("proto.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Every string is owned by the jar's allocator; dates are Unix milliseconds (UTC).
pub const Cookie = struct {
    key: []const u8,
    value: []const u8,
    /// lower-case, no leading dot
    domain: []const u8,
    path: []const u8,
    /// null: a session cookie (tough-cookie's "Infinity")
    expires: ?i64 = null,
    /// seconds; wins over `expires` (relative to `creation`)
    max_age: ?f64 = null,
    secure: bool = false,
    http_only: bool = false,
    host_only: bool = false,
    path_is_default: bool = false,
    creation: i64,
    last_accessed: ?i64 = null,
    same_site: ?[]const u8 = null,

    fn deinit(c: Cookie, a: Allocator) void {
        a.free(c.key);
        a.free(c.value);
        a.free(c.domain);
        a.free(c.path);
        if (c.same_site) |s| a.free(s);
    }

    fn expired(c: Cookie, now: i64) bool {
        if (c.max_age) |m| {
            if (m <= 0) return true;
            if (std.math.isFinite(m)) return c.creation +| @as(i64, @intFromFloat(@min(m * 1000, 9.0e18))) <= now;
            return false;
        }
        return if (c.expires) |e| e <= now else false;
    }

    fn domainMatches(c: Cookie, host: []const u8) bool {
        if (std.mem.eql(u8, host, c.domain)) return true;
        if (c.host_only) return false;
        return std.mem.endsWith(u8, host, c.domain) and host.len > c.domain.len and host[host.len - c.domain.len - 1] == '.';
    }

    fn pathMatches(c: Cookie, request_path: []const u8) bool {
        const path = if (request_path.len == 0) "/" else request_path;
        if (std.mem.eql(u8, path, c.path)) return true;
        return std.mem.startsWith(u8, path, c.path) and (std.mem.endsWith(u8, c.path, "/") or path[c.path.len] == '/');
    }

    fn sameSlot(c: Cookie, o: Cookie) bool {
        return std.mem.eql(u8, o.domain, c.domain) and std.mem.eql(u8, o.path, c.path) and std.mem.eql(u8, o.key, c.key);
    }

    /// tough-cookie's `Cookie.fromJSON` (also takes `name` for `key`, as zca-js does). The
    /// strings are copied into `a`.
    fn fromJson(a: Allocator, v: Value, now: i64) !?Cookie {
        if (v != .object) return null;
        var buf: [5][32]u8 = undefined;
        const key = blk: {
            const k = strOf(v, "key", &buf[0]);
            break :blk if (k != null and k.?.len > 0) k.? else strOf(v, "name", &buf[0]) orelse return null;
        };
        const max_age: ?f64 = if (proto.field(v, "maxAge")) |m| switch (m) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            .string => |s| if (std.mem.eql(u8, s, "Infinity")) std.math.inf(f64) else if (std.mem.eql(u8, s, "-Infinity")) -std.math.inf(f64) else null,
            else => null,
        } else null;
        const domain_raw = std.mem.trimStart(u8, strOf(v, "domain", &buf[1]) orelse "", ".");
        const path = blk: {
            const p = strOf(v, "path", &buf[2]) orelse break :blk "/";
            break :blk if (std.mem.startsWith(u8, p, "/")) p else "/";
        };
        const domain = try std.ascii.allocLowerString(a, domain_raw);
        errdefer a.free(domain);
        var c: Cookie = .{
            .key = "",
            .value = "",
            .domain = domain,
            .path = "",
            .host_only = boolOf(v, "hostOnly") orelse (domain.len == 0),
            .expires = if (proto.field(v, "expires")) |e| parseJsonDate(e) else null,
            .max_age = max_age,
            .secure = boolOf(v, "secure") orelse false,
            .http_only = boolOf(v, "httpOnly") orelse false,
            .path_is_default = boolOf(v, "pathIsDefault") orelse false,
            .creation = (if (proto.field(v, "creation")) |d| parseJsonDate(d) else null) orelse now,
            .last_accessed = if (proto.field(v, "lastAccessed")) |d| parseJsonDate(d) else null,
        };
        c.key = try a.dupe(u8, key);
        errdefer a.free(c.key);
        c.value = try a.dupe(u8, strOf(v, "value", &buf[3]) orelse "");
        errdefer a.free(c.value);
        c.path = try a.dupe(u8, path);
        errdefer a.free(c.path);
        if (strOf(v, "sameSite", &buf[4])) |s| c.same_site = try a.dupe(u8, s);
        return c;
    }

    /// tough-cookie's `Cookie.toJSON` (defaults left out), allocated in `a` (an arena).
    fn toJson(c: Cookie, a: Allocator) !Value {
        var m: std.json.ObjectMap = .empty;
        try m.put(a, "key", .{ .string = try a.dupe(u8, c.key) });
        try m.put(a, "value", .{ .string = try a.dupe(u8, c.value) });
        if (c.expires) |e| try m.put(a, "expires", .{ .string = try dates.formatIso(a, e) });
        if (c.max_age) |age| {
            try m.put(a, "maxAge", if (std.math.isInf(age))
                Value{ .string = if (age > 0) "Infinity" else "-Infinity" }
            else if (@trunc(age) == age and @abs(age) < 9.0e15)
                Value{ .integer = @intFromFloat(age) }
            else
                Value{ .float = age });
        }
        try m.put(a, "domain", .{ .string = try a.dupe(u8, c.domain) });
        try m.put(a, "path", .{ .string = try a.dupe(u8, c.path) });
        if (c.secure) try m.put(a, "secure", .{ .bool = true });
        if (c.http_only) try m.put(a, "httpOnly", .{ .bool = true });
        try m.put(a, "hostOnly", .{ .bool = c.host_only });
        if (c.path_is_default) try m.put(a, "pathIsDefault", .{ .bool = true });
        try m.put(a, "creation", .{ .string = try dates.formatIso(a, c.creation) });
        if (c.last_accessed) |l| try m.put(a, "lastAccessed", .{ .string = try dates.formatIso(a, l) });
        if (c.same_site) |s| try m.put(a, "sameSite", .{ .string = try a.dupe(u8, s) });
        return .{ .object = m };
    }
};

/// A string field, or a number as its digits (in `buf`).
fn strOf(v: Value, key: []const u8, buf: *[32]u8) ?[]const u8 {
    return switch (proto.field(v, key) orelse return null) {
        .string, .number_string => |s| s,
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch null,
        else => null,
    };
}

fn boolOf(v: Value, key: []const u8) ?bool {
    const f = proto.field(v, key) orelse return null;
    return if (f == .bool) f.bool else null;
}

fn parseJsonDate(v: Value) ?i64 {
    return switch (v) {
        .string => |s| if (std.mem.eql(u8, s, "Infinity")) null else dates.parseRfc3339(s) orelse dates.parseHttpDate(s),
        .integer => |ms| ms,
        else => null,
    };
}

/// One `Set-Cookie` header, before it is placed in the jar (slices of the header).
pub const SetCookie = struct {
    key: []const u8,
    value: []const u8,
    /// as written, without leading dots
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?i64 = null,
    max_age: ?f64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?[]const u8 = null,
};

const blank = " \t\r\n\x0b\x0c";

/// tough-cookie's `Cookie.parse` (strict: a cookie needs `name=value`).
pub fn parseSetCookie(header: []const u8) ?SetCookie {
    var parts = std.mem.splitScalar(u8, header, ';');
    const first = parts.next().?;
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
    var c: SetCookie = .{
        .key = std.mem.trim(u8, first[0..eq], blank),
        .value = std.mem.trim(u8, std.mem.trim(u8, first[eq + 1 ..], blank), "\""),
    };
    if (c.key.len == 0) return null;
    while (parts.next()) |attr| {
        const i = std.mem.indexOfScalar(u8, attr, '=');
        const name = std.mem.trim(u8, attr[0 .. i orelse attr.len], blank);
        const val = if (i) |x| std.mem.trim(u8, attr[x + 1 ..], blank) else "";
        if (std.ascii.eqlIgnoreCase(name, "expires")) {
            c.expires = dates.parseHttpDate(val) orelse c.expires;
        } else if (std.ascii.eqlIgnoreCase(name, "max-age")) {
            if (std.fmt.parseInt(i64, val, 10)) |n| c.max_age = @floatFromInt(n) else |_| {}
        } else if (std.ascii.eqlIgnoreCase(name, "domain")) {
            const d = std.mem.trimStart(u8, val, ".");
            c.domain = if (d.len > 0) d else null;
        } else if (std.ascii.eqlIgnoreCase(name, "path")) {
            c.path = if (std.mem.startsWith(u8, val, "/")) val else null;
        } else if (std.ascii.eqlIgnoreCase(name, "secure")) {
            c.secure = true;
        } else if (std.ascii.eqlIgnoreCase(name, "httponly")) {
            c.http_only = true;
        } else if (std.ascii.eqlIgnoreCase(name, "samesite")) {
            c.same_site = val;
        }
    }
    return c;
}

pub const CookieJar = struct {
    a: Allocator,
    cookies: std.ArrayList(Cookie) = .empty,

    pub fn init(a: Allocator) CookieJar {
        return .{ .a = a };
    }

    pub fn deinit(jar: *CookieJar) void {
        for (jar.cookies.items) |c| c.deinit(jar.a);
        jar.cookies.deinit(jar.a);
    }

    /// zca-js `parseCookies`: an array of tough-cookie JSON cookies, or `{cookies: [...]}`.
    pub fn fromCredentials(a: Allocator, v: Value, now: i64) !CookieJar {
        var jar: CookieJar = .init(a);
        errdefer jar.deinit();
        const list: []const Value = if (v == .array) v.array.items else if (proto.field(v, "cookies")) |c| (if (c == .array) c.array.items else &.{}) else &.{};
        for (list) |item| {
            var c = try Cookie.fromJson(a, item, now) orelse continue;
            if (c.domain.len == 0) {
                // tough-cookie: set against https://chat.zalo.me, so host-only there
                a.free(c.domain);
                c.domain = a.dupe(u8, "chat.zalo.me") catch |e| {
                    c.domain = "";
                    c.deinit(a);
                    return e;
                };
                c.host_only = true;
            }
            try jar.put(c);
        }
        return jar;
    }

    /// The cookies as tough-cookie JSON, allocated in `a` (an arena).
    pub fn toJson(jar: *const CookieJar, a: Allocator) !Value {
        var out = std.json.Array.init(a);
        for (jar.cookies.items) |c| try out.append(try c.toJson(a));
        return .{ .array = out };
    }

    pub fn len(jar: *const CookieJar) usize {
        return jar.cookies.items.len;
    }

    /// Takes ownership of `c`.
    fn put(jar: *CookieJar, c: Cookie) !void {
        for (jar.cookies.items) |*old| {
            if (!old.sameSlot(c)) continue;
            var new = c;
            new.creation = old.creation;
            old.deinit(jar.a);
            old.* = new;
            return;
        }
        jar.cookies.append(jar.a, c) catch |e| {
            c.deinit(jar.a);
            return e;
        };
    }

    /// A `Set-Cookie` from a response of `request_host`. Like zca-js `request()`, a cookie naming
    /// any domain is stored for that domain; one naming none is host-only for the responding host.
    pub fn setFromHeader(jar: *CookieJar, header: []const u8, request_host: []const u8, now: i64) !void {
        const sc = parseSetCookie(header) orelse return;
        const a = jar.a;
        const domain = try std.ascii.allocLowerString(a, sc.domain orelse request_host);
        var c: Cookie = .{
            .key = "",
            .value = "",
            .domain = domain,
            .path = "",
            .path_is_default = sc.path == null,
            .expires = sc.expires,
            .max_age = sc.max_age,
            .secure = sc.secure,
            .http_only = sc.http_only,
            .host_only = sc.domain == null,
            .creation = now,
            .last_accessed = now,
        };
        errdefer c.deinit(a);
        c.key = try a.dupe(u8, sc.key);
        c.value = try a.dupe(u8, sc.value);
        c.path = try a.dupe(u8, sc.path orelse "/");
        if (sc.same_site) |s| c.same_site = try std.ascii.allocLowerString(a, s);
        if (c.expired(now)) {
            var i: usize = 0;
            while (i < jar.cookies.items.len) {
                if (jar.cookies.items[i].sameSlot(c)) jar.cookies.orderedRemove(i).deinit(a) else i += 1;
            }
            c.deinit(a);
        } else {
            try jar.put(c);
        }
    }

    /// tough-cookie's `getCookieString(url)`: matching, unexpired cookies, longest path first.
    /// "" for a URL that does not parse.
    pub fn cookieString(jar: *const CookieJar, a: Allocator, url: []const u8, now: i64) ![]u8 {
        const uri = std.Uri.parse(url) catch return a.dupe(u8, "");
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_raw = if (uri.host) |h| h.toRaw(&host_buf) catch return a.dupe(u8, "") else "";
        const host = std.ascii.lowerString(&host_buf, host_raw);
        const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "wss");
        var path_buf: [2048]u8 = undefined;
        const path = uri.path.toRaw(&path_buf) catch "/";

        var list: std.ArrayList(*const Cookie) = .empty;
        defer list.deinit(a);
        for (jar.cookies.items) |*c| {
            if (!c.expired(now) and c.domainMatches(host) and c.pathMatches(path) and (secure or !c.secure)) try list.append(a, c);
        }
        std.mem.sort(*const Cookie, list.items, {}, struct {
            fn lt(_: void, x: *const Cookie, y: *const Cookie) bool {
                if (x.path.len != y.path.len) return x.path.len > y.path.len;
                return x.creation < y.creation;
            }
        }.lt);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        for (list.items, 0..) |c, i| {
            if (i > 0) try out.appendSlice(a, "; ");
            try out.print(a, "{s}={s}", .{ c.key, c.value });
        }
        return out.toOwnedSlice(a);
    }
};

const testing = std.testing;

fn expectCookies(jar: *const CookieJar, url: []const u8, now: i64, want: []const u8) !void {
    const got = try jar.cookieString(testing.allocator, url, now);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "set and send like tough-cookie" {
    const now: i64 = 1_794_988_365_650; // 2026-11-18
    var jar: CookieJar = .init(testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("a=1; Domain=.zalo.me; Path=/; Expires=Wed, 18 Mar 2099 10:00:00 GMT; Secure; HttpOnly; SameSite=None", "id.zalo.me", now);
    try jar.setFromHeader("c=3; Domain=chat.zalo.me; Max-Age=3600", "id.zalo.me", now + 1);
    try jar.setFromHeader("h=4; Path=/", "ID.zalo.me", now + 2);
    try jar.setFromHeader("old=5; Domain=zalo.me; Expires=Wed, 18-Mar-2001 10:00:00 GMT", "id.zalo.me", now + 3);
    try expectCookies(&jar, "https://chat.zalo.me", now + 4, "a=1; c=3");
    try expectCookies(&jar, "https://wpa.chat.zalo.me/api", now + 4, "a=1; c=3");
    try expectCookies(&jar, "wss://ws2-msg.chat.zalo.me/?zpw_ver=685", now + 4, "a=1; c=3");
    try expectCookies(&jar, "https://id.zalo.me/", now + 4, "a=1; h=4");
    try expectCookies(&jar, "http://chat.zalo.me", now + 4, "c=3");
    try expectCookies(&jar, "https://notzalo.me", now + 4, "");
    try expectCookies(&jar, "not a url", now + 4, "");
    // Max-Age runs out
    try expectCookies(&jar, "https://chat.zalo.me", now + 3_600_001, "a=1");
    // replacing keeps one copy
    try jar.setFromHeader("a=2; Domain=zalo.me; Path=/", "chat.zalo.me", now + 5);
    try expectCookies(&jar, "https://zalo.me/", now + 6, "a=2");
    // an expired Set-Cookie deletes
    try jar.setFromHeader("c=; Domain=chat.zalo.me; Max-Age=0", "chat.zalo.me", now + 7);
    try expectCookies(&jar, "https://chat.zalo.me", now + 8, "a=2");
    try testing.expectEqual(@as(usize, 2), jar.len());
}

test "paths and quoted values" {
    const now: i64 = 1_794_988_365_650;
    var jar: CookieJar = .init(testing.allocator);
    defer jar.deinit();
    try jar.setFromHeader("deep=1; Path=/api/v2", "zalo.me", now);
    try jar.setFromHeader("root=\"q\"; Path=/", "zalo.me", now + 1);
    try jar.setFromHeader("nopath=3; Path=relative", "zalo.me", now + 2);
    try jar.setFromHeader("novalue", "zalo.me", now + 3);
    try jar.setFromHeader("=x", "zalo.me", now + 3);
    // the longest path first; "/api/v2" is no prefix of "/api/v20"
    try expectCookies(&jar, "https://zalo.me/api/v2/x", now + 4, "deep=1; root=q; nopath=3");
    try expectCookies(&jar, "https://zalo.me/api/v20", now + 4, "root=q; nopath=3");
    // host-only: not for sub-domains
    try expectCookies(&jar, "https://chat.zalo.me/", now + 4, "");
    const sc = parseSetCookie("k = v ; MAX-AGE=abc; Domain=.Zalo.ME; sameSite=Lax").?;
    try testing.expectEqualStrings("k", sc.key);
    try testing.expectEqualStrings("v", sc.value);
    try testing.expect(sc.max_age == null);
    try testing.expectEqualStrings("Zalo.ME", sc.domain.?);
    try testing.expectEqualStrings("Lax", sc.same_site.?);
}

test "round-trips tough-cookie JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // what zca-js saved (tough-cookie 5 `toJSON().cookies`), including its "null" host cookies
    const saved = try proto.parseJson(a,
        \\[
        \\ {"key":"a","value":"1","expires":"2099-03-18T10:00:00.000Z","domain":"zalo.me","path":"/","secure":true,"httpOnly":true,"hostOnly":false,"creation":"2026-11-19T07:52:45.650Z","lastAccessed":"2026-11-19T07:52:45.650Z","sameSite":"none"},
        \\ {"key":"b","value":"2","domain":"null","path":"/","hostOnly":true,"creation":"2026-11-19T07:52:45.657Z","lastAccessed":"2026-11-19T07:52:45.657Z"},
        \\ {"key":"c","value":"3","maxAge":3600,"domain":"chat.zalo.me","path":"/","hostOnly":false,"pathIsDefault":true,"creation":"2099-01-01T00:00:00.000Z","lastAccessed":"2026-11-19T07:52:45.657Z"},
        \\ {"name":"zpw_sek","value":"s e k","domain":".chat.zalo.me","path":"/"}
        \\]
    );
    const now: i64 = 1_795_074_765_700; // 2026-11-19T07:52:45.700Z
    var jar = try CookieJar.fromCredentials(testing.allocator, saved, now);
    defer jar.deinit();
    try testing.expectEqual(@as(usize, 4), jar.len());
    // tough-cookie order: longer path first, then older creation first (c was "created" in 2099)
    try expectCookies(&jar, "https://chat.zalo.me", now, "a=1; zpw_sek=s e k; c=3");
    const back = (try jar.toJson(a)).array.items;
    const items = saved.array.items;
    try testing.expect(proto.jsonEql(back[0], items[0]));
    try testing.expect(proto.jsonEql(back[1], items[1]));
    try testing.expect(proto.jsonEql(back[2], items[2]));
    try testing.expectEqualStrings("zpw_sek", proto.fieldStr(back[3], "key").?);
    try testing.expectEqualStrings("chat.zalo.me", proto.fieldStr(back[3], "domain").?);
    // the {cookies: [...]} form too
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "cookies", saved);
    var jar2 = try CookieJar.fromCredentials(testing.allocator, .{ .object = o }, now);
    defer jar2.deinit();
    try testing.expectEqual(@as(usize, 4), jar2.len());
    // nothing to read: an empty jar
    var jar3 = try CookieJar.fromCredentials(testing.allocator, .{ .string = "x" }, now);
    defer jar3.deinit();
    try testing.expectEqual(@as(usize, 0), jar3.len());
}
