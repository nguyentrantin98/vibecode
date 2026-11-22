//! The Zalo Web HTTP API, ported from the parts of zca-js 2.3.0 VIBE CODE uses: cookie login
//! (`zalo.js` + `apis/login.js`), QR login (`apis/loginQR.js`), `utils.request` (cookies,
//! redirects) and the endpoints in `apis/*.js` — each method names the file it comes from.
//!
//! Errors carry their text in the `fail: *core.Fail` every call takes (an error Zalo answered
//! with is its `error_message`). `a` is the caller's arena: what a call returns lives there.

const std = @import("std");
const core = @import("../core.zig");
const settings = @import("../settings.zig");
const http_client = @import("../http.zig");
const proto = @import("proto.zig");
const types = @import("types.zig");
const listen = @import("listen.zig");
const CookieJar = @import("cookies.zig").CookieJar;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Pair = proto.Pair;
const Header = std.http.Header;

pub const ThreadType = enum { user, group };

/// What zca-js keeps of a session (`Credentials`): enough to log in again without a QR scan.
pub const Credentials = struct {
    imei: []const u8 = "",
    /// tough-cookie JSON: an array of cookies, or `{cookies: [...]}`
    cookie: Value = .null,
    user_agent: []const u8 = "",
    language: ?[]const u8 = null,

    pub const jsonStringify = types.Json(@This()).jsonStringify;
    pub const jsonParseFromValue = types.Json(@This()).jsonParseFromValue;
    pub const jsonParse = types.Json(@This()).jsonParse;
};

// ---------------- HTTP: zca-js `request()` ----------------

pub const Resp = struct {
    status: u16,
    body: []const u8,

    pub fn ok(r: Resp) bool {
        return r.status >= 200 and r.status < 300;
    }

    pub fn json(r: Resp, a: Allocator) !Value {
        return proto.parseJson(a, r.body);
    }

    /// "Not Found" for 404.
    fn reason(r: Resp) []const u8 {
        return (@as(std.http.Status, @fromBackingInt(@as(u10, @intCast(@min(r.status, 1023)))))).phrase() orelse "";
    }
};

/// `base` followed to `location` (a redirect's `Location`, absolute or relative).
fn joinUrl(a: Allocator, base: []const u8, location: []const u8) ![]u8 {
    const base_uri = try std.Uri.parse(base);
    const buf = try a.alloc(u8, location.len + base.len + 16);
    @memcpy(buf[0..location.len], location);
    var aux: []u8 = buf;
    const uri = try base_uri.resolveInPlace(location.len, &aux);
    var out: std.Io.Writer.Allocating = .init(a);
    try uri.writeToStream(&out.writer, .{ .scheme = true, .authority = true, .path = true, .query = true });
    return out.toOwnedSlice();
}

/// "https://host" (with the port when it is not the scheme's own).
fn originOf(a: Allocator, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    var out: std.Io.Writer.Allocating = .init(a);
    try uri.writeToStream(&out.writer, .{ .scheme = true, .authority = true });
    return out.toOwnedSlice();
}

fn hostOf(a: Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const h = uri.host orelse return "";
    return std.ascii.allocLowerString(a, try h.toRawMaybeAlloc(a));
}

pub const Http = struct {
    jar: CookieJar,
    mutex: core.Mutex = .{},
    user_agent: []const u8,

    /// The cookies a request to `url` carries.
    pub fn cookieString(h: *Http, a: Allocator, url: []const u8) ![]u8 {
        h.mutex.lock();
        defer h.mutex.unlock();
        return h.jar.cookieString(a, url, proto.nowMs());
    }

    /// `getDefaultHeaders`. (No Accept-Encoding of our own: the client decompresses.)
    fn defaultHeaders(h: *Http, a: Allocator, url: []const u8) !std.ArrayList(Header) {
        var list: std.ArrayList(Header) = .empty;
        try list.appendSlice(a, &.{
            .{ .name = "Accept", .value = "application/json, text/plain, */*" },
            .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Origin", .value = "https://chat.zalo.me" },
            .{ .name = "Referer", .value = "https://chat.zalo.me/" },
            .{ .name = "User-Agent", .value = h.user_agent },
        });
        const cookie = try h.cookieString(a, try originOf(a, url));
        if (cookie.len > 0) try list.append(a, .{ .name = "Cookie", .value = cookie });
        return list;
    }

    /// One request with the session's headers + cookies, storing the cookies it gets back and
    /// following redirects (as GETs, with fresh default headers, as zca-js does). Redirects are
    /// followed by hand, so every hop's Set-Cookie lands in the jar.
    pub fn request(h: *Http, a: Allocator, first_url: []const u8, first_method: std.http.Method, extra: []const Header, form: ?[]const Pair, fail: *core.Fail) !Resp {
        var url = first_url;
        var method = first_method;
        var hop: usize = 0;
        while (hop < 10) : (hop += 1) {
            var headers = h.defaultHeaders(a, url) catch |e| return fail.set(a, "bad URL {s} ({s})", .{ url, @errorName(e) });
            if (hop == 0) for (extra) |x| {
                for (headers.items) |*slot| {
                    if (std.ascii.eqlIgnoreCase(slot.name, x.name)) {
                        slot.value = x.value;
                        break;
                    }
                } else try headers.append(a, x);
            };
            // these two are the client's own to send
            var content_type: ?[]const u8 = null;
            var user_agent = h.user_agent;
            var i: usize = 0;
            while (i < headers.items.len) {
                const x = headers.items[i];
                if (std.ascii.eqlIgnoreCase(x.name, "content-type")) {
                    content_type = x.value;
                } else if (std.ascii.eqlIgnoreCase(x.name, "user-agent")) {
                    user_agent = x.value;
                } else {
                    i += 1;
                    continue;
                }
                _ = headers.orderedRemove(i);
            }
            const body: ?[]const u8 = if (hop == 0 and form != null) try proto.formEncode(a, form.?) else null;
            const r = http_client.request(a, url, .{
                .method = method,
                .headers = headers.items,
                .body = body,
                .content_type = content_type,
                .user_agent = user_agent,
                .redirects = 0,
            }) catch |e| return fail.set(a, "{s}: {s}", .{ hostOf(a, url) catch url, @errorName(e) });
            {
                const host = try hostOf(a, url);
                h.mutex.lock();
                defer h.mutex.unlock();
                for (r.headers) |x| {
                    if (std.ascii.eqlIgnoreCase(x.name, "set-cookie")) h.jar.setFromHeader(x.value, host, proto.nowMs()) catch {};
                }
            }
            if (r.header("location")) |loc| {
                url = joinUrl(a, url, loc) catch |e| return fail.set(a, "bad redirect to {s} ({s})", .{ loc, @errorName(e) });
                method = .GET;
                continue;
            }
            return .{ .status = r.status, .body = r.body };
        }
        return fail.set(a, "too many redirects", .{});
    }
};

/// `error_code != 0`, loosely (JS `!=`).
fn codeOk(v: ?Value) bool {
    return switch (v orelse return false) {
        .integer => |n| n == 0,
        .float => |f| f == 0,
        .string, .number_string => proto.jnum(v) == 0,
        .bool => |b| !b,
        else => false,
    };
}

/// An error Zalo answered with (`ZaloApiError`): its message.
fn apiError(a: Allocator, j: Value, fail: *core.Fail) error{Failed} {
    return fail.set(a, "{s}", .{proto.fieldStr(j, "error_message") orelse ""});
}

// ---------------- login with saved cookies ----------------

/// A logged-in session: what zca-js keeps in its context + `API`. Shared between threads by
/// reference count (`retain` / `release`); everything it holds lives in its own arena.
pub const Api = struct {
    refs: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,
    http: Http,
    imei: []const u8 = "",
    language: []const u8 = "",
    uid: []const u8 = "",
    secret_key: []const u8 = "",
    settings: Value = .null,
    extra_ver: Value = .null,
    service_map: Value = .null,
    ws_urls: []const []const u8 = &.{},

    fn create() !*Api {
        const api = try core.gpa.create(Api);
        api.* = .{ .arena = .init(core.gpa), .http = .{ .jar = .init(core.gpa), .user_agent = "" } };
        return api;
    }

    pub fn retain(api: *Api) *Api {
        _ = api.refs.fetchAdd(1, .monotonic);
        return api;
    }

    pub fn release(api: *Api) void {
        if (api.refs.fetchSub(1, .acq_rel) != 1) return;
        api.http.jar.deinit();
        api.arena.deinit();
        core.gpa.destroy(api);
    }

    /// The first URL of a service in `zpw_service_map_v3`.
    fn svc(api: *const Api, a: Allocator, name: []const u8, fail: *core.Fail) ![]const u8 {
        const v = proto.field(api.service_map, name) orelse Value{ .null = {} };
        if (v == .array and v.array.items.len > 0 and v.array.items[0] == .string) return v.array.items[0].string;
        if (v == .string) return v.string;
        return fail.set(a, "Zalo did not give a `{s}` service", .{name});
    }

    /// `<service><path>` with the API version added.
    fn url(api: *const Api, a: Allocator, service: []const u8, path: []const u8, params: []const Pair, fail: *core.Fail) ![]u8 {
        const base = try std.mem.concat(a, u8, &.{ try api.svc(a, service, fail), path });
        return proto.makeUrl(a, base, params, true) catch fail.set(a, "bad URL {s}", .{base});
    }

    /// `params` (anything that serializes to JSON) encrypted for the session.
    fn enc(api: *const Api, a: Allocator, params: anytype, fail: *core.Fail) ![]u8 {
        return proto.encodeAes(a, api.secret_key, try core.toJson(a, params)) catch fail.set(a, "Failed to encrypt params", .{});
    }

    /// `resolveResponse` / `handleZaloResponse`: unwrap (and decrypt) `data`.
    pub fn resolve(api: *const Api, a: Allocator, r: Resp, encrypted: bool, fail: *core.Fail) !Value {
        if (!r.ok()) return fail.set(a, "Request failed with status code {d}", .{r.status});
        const j = r.json(a) catch return fail.set(a, "Failed to parse response data", .{});
        if (!codeOk(proto.field(j, "error_code"))) return apiError(a, j, fail);
        const decoded: Value = if (encrypted) blk: {
            const data = proto.fieldStr(j, "data") orelse return fail.set(a, "Failed to parse response data", .{});
            const text = proto.decodeAes(a, api.secret_key, data) catch return fail.set(a, "Failed to parse response data", .{});
            break :blk proto.parseJson(a, text) catch return fail.set(a, "Failed to parse response data", .{});
        } else j;
        if (!codeOk(proto.field(decoded, "error_code"))) return apiError(a, decoded, fail);
        return proto.field(decoded, "data") orelse .null;
    }

    fn get(api: *Api, a: Allocator, full_url: []const u8, fail: *core.Fail) !Value {
        const r = try api.http.request(a, full_url, .GET, &.{}, null, fail);
        return api.resolve(a, r, true, fail);
    }

    /// POST `params=<encrypted>` as a form.
    fn postWith(api: *Api, a: Allocator, full_url: []const u8, params: anytype, fail: *core.Fail) !Value {
        const r = try api.http.request(a, full_url, .POST, &.{}, &.{.{ "params", try api.enc(a, params, fail) }}, fail);
        return api.resolve(a, r, true, fail);
    }

    // ----- profile, friends, groups -----

    /// fetchAccountInfo.js
    pub fn fetchAccountInfo(api: *Api, a: Allocator, fail: *core.Fail) !Value {
        return api.get(a, try api.url(a, "profile", "/api/social/profile/me-v2", &.{}, fail), fail);
    }

    /// getAllFriends.js (GET with the encrypted params added to the URL)
    pub fn getAllFriends(api: *Api, a: Allocator, fail: *core.Fail) ![]const Value {
        const base = try api.url(a, "profile", "/api/social/friend/getfriends", &.{}, fail);
        const params = try api.enc(a, .{ .actiontime = 0, .avatar_size = 120, .count = 20000, .imei = api.imei, .incInvalid = 1, .page = 1 }, fail);
        const full = proto.makeUrl(a, base, &.{.{ "params", params }}, true) catch return fail.set(a, "bad URL {s}", .{base});
        const v = try api.get(a, full, fail);
        return if (v == .array) v.array.items else &.{};
    }

    /// getAllGroups.js
    pub fn getAllGroups(api: *Api, a: Allocator, fail: *core.Fail) !Value {
        return api.get(a, try api.url(a, "group_poll", "/api/group/getlg/v4", &.{}, fail), fail);
    }

    /// getGroupInfo.js
    pub fn getGroupInfo(api: *Api, a: Allocator, ids: []const []const u8, fail: *core.Fail) !Value {
        const full = try api.url(a, "group", "/api/group/getmg-v2", &.{}, fail);
        // {"<id>":0,…} as text
        var map: std.ArrayList(u8) = .empty;
        try map.append(a, '{');
        for (ids, 0..) |id, i| {
            if (i > 0) try map.append(a, ',');
            try map.print(a, "{s}:0", .{try core.toJson(a, id)});
        }
        try map.append(a, '}');
        return api.postWith(a, full, .{ .gridVerMap = map.items }, fail);
    }

    /// getUserInfo.js
    pub fn getUserInfo(api: *Api, a: Allocator, ids: []const []const u8, fail: *core.Fail) !Value {
        if (ids.len == 0) return fail.set(a, "Missing user id", .{});
        const full = try api.url(a, "profile", "/api/social/friend/getprofiles/v2", &.{}, fail);
        const list = try a.alloc([]const u8, ids.len);
        for (list, ids) |*out, id| out.* = if (std.mem.indexOfScalar(u8, id, '_') != null) id else try std.fmt.allocPrint(a, "{s}_0", .{id});
        return api.postWith(a, full, .{
            .avatar_size = 120,
            .friend_pversion_map = list,
            .imei = api.imei,
            .language = api.language,
            .phonebook_version = proto.field(api.extra_ver, "phonebook") orelse Value{ .null = {} },
            .show_online_status = 1,
        }, fail);
    }

    /// findUser.js (the phone goes international for Vietnamese accounts).
    pub fn findUser(api: *Api, a: Allocator, phone_in: []const u8, fail: *core.Fail) !Value {
        if (phone_in.len == 0) return fail.set(a, "Missing phoneNumber", .{});
        const phone = if (phone_in[0] == '0' and std.mem.eql(u8, api.language, "vi")) try std.fmt.allocPrint(a, "84{s}", .{phone_in[1..]}) else phone_in;
        const params = try api.enc(a, .{ .avatar_size = 240, .imei = api.imei, .language = api.language, .phone = phone, .reqSrc = 40 }, fail);
        const base = try api.url(a, "friend", "/api/friend/profile/get", &.{}, fail);
        // zca-js puts `params` on the URL twice
        const once = proto.makeUrl(a, base, &.{.{ "params", params }}, false) catch return fail.set(a, "bad URL {s}", .{base});
        const twice = proto.makeUrl(a, once, &.{.{ "params", params }}, true) catch return fail.set(a, "bad URL {s}", .{base});
        return api.get(a, twice, fail);
    }

    pub const CloudPage = struct { data: Value, msgs: []listen.Msg };

    /// getCloudMessage.js: one page (≤ 50) of a group's history. Returns the page and its messages.
    pub fn getCloudMessage(api: *Api, a: Allocator, group_id_in: []const u8, last_msg_id: ?[]const u8, is_old: bool, fail: *core.Fail) !CloudPage {
        if (group_id_in.len == 0) return fail.set(a, "Missing groupId", .{});
        const group_id = if (group_id_in[0] == 'g') group_id_in[1..] else group_id_in;
        const base = try api.url(a, "group_cloud_message", if (is_old) "/api/cm/getoldv2" else "/api/cm/getrecentv2", &.{}, fail);
        const last: ?[]const u8 = if (last_msg_id) |s| (if (s.len > 0) s else null) else null;
        const params = try api.enc(a, .{
            .count = 50,
            .globalMsgId = last orelse "0",
            .groupId = group_id,
            .imei = api.imei,
            .msgIds = @as([]const i32, &.{}),
            .src = @as(u8, if (last != null) 3 else 1),
        }, fail);
        const full = proto.makeUrl(a, base, &.{ .{ "params", params }, .{ "nretry", "0" } }, true) catch return fail.set(a, "bad URL {s}", .{base});
        var data = try api.get(a, full, fail);
        if (data == .string) data = proto.parseJson(a, data.string) catch return fail.set(a, "Failed to parse response data", .{});
        var msgs: std.ArrayList(listen.Msg) = .empty;
        if (proto.field(data, "groupMsgs")) |list| if (list == .array) {
            for (list.array.items) |m| try msgs.append(a, try listen.groupMessage(a, api.uid, m));
        };
        return .{ .data = data, .msgs = msgs.items };
    }

    // ----- sending: sendMessage.js, text only -----

    /// `sendMessage` for a plain text (`handleMessage` without quote or mentions): what the MCP
    /// tool `zalo_send_message` needs. Returns Zalo's `data` (it carries the new `msgId`).
    pub fn sendText(api: *Api, a: Allocator, msg: []const u8, thread_id: []const u8, kind: ThreadType, fail: *core.Fail) !Value {
        if (thread_id.len == 0) return fail.set(a, "Missing threadId", .{});
        if (msg.len == 0) return fail.set(a, "Missing message content", .{});
        const group = kind == .group;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (group) "/api/group" else "/api/message", textEndpoint(group) });
        const full = try api.url(a, if (group) "group" else "chat", path, &.{.{ "nretry", "0" }}, fail);
        return api.postWith(a, full, try textParams(a, msg, thread_id, group, api.imei, proto.nowMs()), fail);
    }
};

/// `Zalo.login(credentials)`.
pub fn login(a: Allocator, creds: Credentials, fail: *core.Fail) !*Api {
    if (creds.imei.len == 0 or !proto.truthy(creds.cookie) or creds.user_agent.len == 0) return fail.set(a, "Missing required params", .{});
    const api = try Api.create();
    errdefer api.release();
    const own = api.arena.allocator();
    api.http.jar = try CookieJar.fromCredentials(core.gpa, creds.cookie, proto.nowMs());
    api.http.user_agent = try own.dupe(u8, creds.user_agent);
    api.imei = try own.dupe(u8, creds.imei);
    api.language = try own.dupe(u8, if (creds.language != null and creds.language.?.len > 0) creds.language.? else "vi");

    const login_data = try getLoginInfo(a, &api.http, api.imei, api.language, fail);
    const server = try getServerInfo(a, &api.http, api.imei, fail);
    const info = proto.field(login_data, "data") orelse Value{ .null = {} };
    if (!proto.truthy(info)) return fail.set(a, "{s}", .{settings.tr("Sign-in failed", "Đăng nhập thất bại")});
    const secret_key = proto.fieldStr(info, "zpw_enk") orelse "";
    if (secret_key.len == 0) return fail.set(a, "{s}", .{settings.tr("Could not set up the session.", "Khởi tạo ngữ cảnh thất bại.")});
    // "setttings": Zalo's own spelling
    const server_settings = blk: {
        const s = proto.field(server, "setttings");
        break :blk if (proto.truthy(s)) s.? else proto.field(server, "settings") orelse Value{ .null = {} };
    };
    api.secret_key = try own.dupe(u8, secret_key);
    api.uid = try own.dupe(u8, try proto.jstr(a, proto.field(info, "uid")));
    api.settings = try proto.cloneValue(own, server_settings);
    api.extra_ver = try proto.cloneValue(own, proto.field(server, "extra_ver") orelse Value{ .null = {} });
    api.service_map = try proto.cloneValue(own, proto.field(info, "zpw_service_map_v3") orelse Value{ .null = {} });
    var urls: std.ArrayList([]const u8) = .empty;
    if (proto.field(info, "zpw_ws")) |ws| if (ws == .array) {
        for (ws.array.items) |u| if (u == .string) try urls.append(own, try own.dupe(u8, u.string));
    };
    api.ws_urls = urls.items;
    return api;
}

/// `login()` in apis/login.js: the encrypted `getLoginInfo` call. Null when it didn't decrypt to JSON.
fn getLoginInfo(a: Allocator, http: *Http, imei: []const u8, language: []const u8, fail: *core.Fail) !?Value {
    const now = proto.nowMs();
    const data = try core.toJson(a, .{ .computer_name = "Web", .imei = imei, .language = language, .ts = now });
    const enc = try proto.ParamsEncryptor.init(a, proto.API_TYPE, imei, @intCast(now));
    const encoded = try proto.encodeAesUtf8Key(a, enc.encrypt_key, data, false, false);
    var params: std.ArrayList(Pair) = .empty;
    try params.appendSlice(a, &.{
        .{ "zcid", enc.zcid },
        .{ "zcid_ext", enc.zcid_ext },
        .{ "enc_ver", proto.ParamsEncryptor.ENC_VER },
        .{ "params", encoded },
        .{ "type", try std.fmt.allocPrint(a, "{d}", .{proto.API_TYPE}) },
        .{ "client_version", try std.fmt.allocPrint(a, "{d}", .{proto.API_VERSION}) },
    });
    const signkey = try proto.signKey(a, "getlogininfo", params.items);
    try params.append(a, .{ "signkey", try a.dupe(u8, &signkey) });
    try params.append(a, .{ "nretry", "0" });
    const url = try proto.makeUrl(a, "https://wpa.chat.zalo.me/api/login/getLoginInfo", params.items, true);
    const r = try http.request(a, url, .GET, &.{}, null, fail);
    if (!r.ok()) return fail.set(a, "Failed to fetch login info: {s}", .{r.reason()});
    const j = r.json(a) catch return fail.set(a, "Failed to fetch login info: the answer is not JSON", .{});
    const text = proto.fieldStr(j, "data") orelse return null;
    const v = proto.decryptResp(a, enc.encrypt_key, text) catch return null;
    return if (v == .string or v == .null) null else v;
}

fn getServerInfo(a: Allocator, http: *Http, imei: []const u8, fail: *core.Fail) !Value {
    var params: std.ArrayList(Pair) = .empty;
    try params.appendSlice(a, &.{
        .{ "imei", imei },
        .{ "type", try std.fmt.allocPrint(a, "{d}", .{proto.API_TYPE}) },
        .{ "client_version", try std.fmt.allocPrint(a, "{d}", .{proto.API_VERSION}) },
        .{ "computer_name", "Web" },
    });
    const signkey = try proto.signKey(a, "getserverinfo", params.items);
    try params.append(a, .{ "signkey", try a.dupe(u8, &signkey) });
    const url = try proto.makeUrl(a, "https://wpa.chat.zalo.me/api/login/getServerInfo", params.items, false);
    const r = try http.request(a, url, .GET, &.{}, null, fail);
    if (!r.ok()) return fail.set(a, "Failed to fetch server info: {s}", .{r.reason()});
    const j = r.json(a) catch return fail.set(a, "Failed to fetch server info: the answer is not JSON", .{});
    const data = proto.field(j, "data") orelse Value{ .null = {} };
    if (data == .null) return fail.set(a, "Failed to fetch server info: {s}", .{try proto.jstr(a, proto.field(j, "error_message"))});
    return data;
}

// ---------------- QR login ----------------

/// The user agent zca-js logs in with when none is given.
pub const QR_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0";

pub const QrEvent = union(enum) {
    /// base64 PNG (no data: prefix)
    generated: []const u8,
    expired,
    /// the display name of who scanned
    scanned: []const u8,
    declined,
    /// the session to save, before the cookie login that follows
    got_login_info: Credentials,
};

/// The error a QR login ends with when it expired, was declined or cancelled.
pub const QR_ABORTED = "Operation aborted";

const SEC_CH_UA = "\"Chromium\";v=\"130\", \"Google Chrome\";v=\"130\", \"Not?A_Brand\";v=\"99\"";

fn idHeaders(a: Allocator, referer: []const u8, document: bool, more: []const Header) ![]const Header {
    var h: std.ArrayList(Header) = .empty;
    if (document) {
        try h.appendSlice(a, &.{
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" },
            .{ .name = "priority", .value = "u=0, i" },
            .{ .name = "sec-fetch-dest", .value = "document" },
            .{ .name = "sec-fetch-mode", .value = "navigate" },
            .{ .name = "upgrade-insecure-requests", .value = "1" },
        });
    } else {
        try h.appendSlice(a, &.{
            .{ .name = "accept", .value = "*/*" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "priority", .value = "u=1, i" },
            .{ .name = "sec-fetch-dest", .value = "empty" },
            .{ .name = "sec-fetch-mode", .value = "cors" },
        });
    }
    try h.appendSlice(a, &.{
        .{ .name = "accept-language", .value = "vi-VN,vi;q=0.9,fr-FR;q=0.8,fr;q=0.7,en-US;q=0.6,en;q=0.5" },
        .{ .name = "sec-ch-ua", .value = SEC_CH_UA },
        .{ .name = "sec-ch-ua-mobile", .value = "?0" },
        .{ .name = "sec-ch-ua-platform", .value = "\"Windows\"" },
        .{ .name = "Referer", .value = referer },
        .{ .name = "Referrer-Policy", .value = "strict-origin-when-cross-origin" },
    });
    try h.appendSlice(a, more);
    return h.items;
}

const REF_PC = "https://id.zalo.me/account?continue=https%3A%2F%2Fzalo.me%2Fpc";
const REF_CHAT = "https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F";

fn idPost(a: Allocator, http: *Http, url: []const u8, referer: []const u8, pairs: []const Pair, fail: *core.Fail) !Value {
    const h = try idHeaders(a, referer, false, &.{.{ .name = "sec-fetch-site", .value = "same-origin" }});
    const r = try http.request(a, url, .POST, h, pairs, fail);
    return r.json(a) catch fail.set(a, "{s}: the answer is not JSON", .{url});
}

/// The version of Zalo's login script, from the login page:
/// `https://stc-zlogin\.zdn\.vn/main-([\d.]+)\.js`.
fn loginVersion(html: []const u8) ?[]const u8 {
    const prefix = "https://stc-zlogin.zdn.vn/main-";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, html, from, prefix)) |at| {
        const start = at + prefix.len;
        var end = start;
        while (end < html.len and (std.ascii.isDigit(html[end]) or html[end] == '.')) end += 1;
        // the run took the dot of ".js" with it
        if (end > start + 1 and html[end - 1] == '.' and std.mem.startsWith(u8, html[end..], "js")) return html[start .. end - 1];
        from = start;
    }
    return null;
}

/// A QR login in progress, shared between the thread that runs it, the one that waits for the
/// phone and whoever may cancel it.
pub const QrLogin = struct {
    refs: std.atomic.Value(u32) = .init(1),
    mutex: core.Mutex = .{},
    cond: std.Io.Condition = .init,
    http: Http,
    /// what the waiting thread leaves
    arena: std.heap.ArenaAllocator,
    aborted: bool = false,
    /// nobody waits for the phone any more
    gone: bool = false,
    done: bool = false,
    confirm: ?Value = null,
    err: []const u8 = "",

    pub fn create() !*QrLogin {
        const q = try core.gpa.create(QrLogin);
        q.* = .{ .arena = .init(core.gpa), .http = .{ .jar = .init(core.gpa), .user_agent = QR_USER_AGENT } };
        return q;
    }

    pub fn retain(q: *QrLogin) *QrLogin {
        _ = q.refs.fetchAdd(1, .monotonic);
        return q;
    }

    pub fn release(q: *QrLogin) void {
        if (q.refs.fetchSub(1, .acq_rel) != 1) return;
        q.http.jar.deinit();
        q.arena.deinit();
        core.gpa.destroy(q);
    }

    /// Ends the login: `loginQr` returns at once (requests on their way are left to finish).
    pub fn abort(q: *QrLogin) void {
        q.mutex.lock();
        q.aborted = true;
        q.gone = true;
        q.cond.broadcast(core.io);
        q.mutex.unlock();
    }

    fn isGone(q: *QrLogin) bool {
        q.mutex.lock();
        defer q.mutex.unlock();
        return q.gone;
    }
};

pub const QrHandler = *const fn (generation: u64, ev: QrEvent) void;

const QrWait = struct {
    q: *QrLogin,
    generation: u64,
    on: QrHandler,
    code: []const u8,
    version: []const u8,
};

/// `waitingScan` then `waitingConfirm`, on a thread of its own so the login can expire or be
/// cancelled while Zalo holds the request open.
fn qrWaiting(w: *QrWait) void {
    const q = w.q;
    var scratch: std.heap.ArenaAllocator = .init(core.gpa);
    const a = scratch.allocator();
    var fail: core.Fail = .{};
    const result: ?Value = blk: {
        const scan = longPoll(a, q, "https://id.zalo.me/account/authen/qr/waiting-scan", &.{ .{ "code", w.code }, .{ "continue", "https://chat.zalo.me/" }, .{ "v", w.version } }, &fail) catch null;
        if (scan == null or !proto.truthy(proto.field(scan, "data"))) {
            fail.msg = "Cannot get scan result";
            break :blk null;
        }
        if (!q.isGone()) w.on(w.generation, .{ .scanned = proto.fieldStr(proto.field(scan, "data"), "display_name") orelse "" });
        break :blk longPoll(a, q, "https://id.zalo.me/account/authen/qr/waiting-confirm", &.{
            .{ "code", w.code },
            .{ "gToken", "" },
            .{ "gAction", "CONFIRM_QR" },
            .{ "continue", "https://chat.zalo.me/" },
            .{ "v", w.version },
        }, &fail) catch {
            fail.msg = "Cannot get confirm result";
            break :blk null;
        };
    };
    q.mutex.lock();
    const own = q.arena.allocator();
    if (result) |v| {
        q.confirm = proto.cloneValue(own, v) catch null;
    }
    if (q.confirm == null) q.err = own.dupe(u8, if (fail.msg.len > 0) fail.msg else "Cannot get confirm result") catch "Cannot get confirm result";
    q.done = true;
    q.cond.broadcast(core.io);
    q.mutex.unlock();
    scratch.deinit();
    q.release();
    core.gpa.free(w.code);
    core.gpa.free(w.version);
    core.gpa.destroy(w);
}

/// `waitingScan` / `waitingConfirm`: Zalo answers error 8 while nothing happened yet.
fn longPoll(a: Allocator, q: *QrLogin, url: []const u8, pairs: []const Pair, fail: *core.Fail) !Value {
    while (true) {
        if (q.isGone()) return fail.set(a, QR_ABORTED, .{});
        const r = try idPost(a, &q.http, url, REF_CHAT, pairs, fail);
        const code = proto.field(r, "error_code");
        if (code == null or code.? != .integer or code.?.integer != 8) return r;
    }
}

/// `apiloginQR` + the cookie login after it. `on` hears each step; expiry (100 s) and a decline
/// on the phone end the login with `QR_ABORTED` right after their event, `q.abort()` without one.
pub fn loginQr(a: Allocator, q: *QrLogin, generation: u64, on: QrHandler, fail: *core.Fail) !*Api {
    const http = &q.http;

    // loadLoginPage: the login script's version
    const page = try http.request(a, "https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F", .GET, try idHeaders(a, "https://chat.zalo.me/", true, &.{
        .{ .name = "cache-control", .value = "max-age=0" },
        .{ .name = "sec-fetch-site", .value = "same-site" },
        .{ .name = "sec-fetch-user", .value = "?1" },
    }), null, fail);
    const version = loginVersion(page.body) orelse return fail.set(a, "Cannot get API login version", .{});

    var ignored: core.Fail = .{};
    _ = idPost(a, http, "https://id.zalo.me/account/logininfo", REF_PC, &.{ .{ "continue", "https://zalo.me/pc" }, .{ "v", version } }, &ignored) catch {};
    _ = idPost(a, http, "https://id.zalo.me/account/verify-client", REF_PC, &.{ .{ "type", "device" }, .{ "continue", "https://zalo.me/pc" }, .{ "v", version } }, &ignored) catch {};
    const generated: ?Value = idPost(a, http, "https://id.zalo.me/account/authen/qr/generate", REF_PC, &.{ .{ "continue", "https://zalo.me/pc" }, .{ "v", version } }, &ignored) catch null;
    const data = proto.field(generated, "data");
    if (!proto.truthy(data)) return fail.set(a, "Unable to generate QRCode\nResponse: {s}", .{if (generated) |g| try core.toJson(a, g) else "undefined"});
    if (q.isGone()) return fail.set(a, QR_ABORTED, .{});
    const code = try proto.jstr(a, proto.field(data, "code"));
    const image = proto.fieldStr(data, "image") orelse "";
    const png_prefix = "data:image/png;base64,";
    on(generation, .{ .generated = if (std.mem.startsWith(u8, image, png_prefix)) image[png_prefix.len..] else image });

    // wait for the phone, 100 s at most
    {
        const w = try core.gpa.create(QrWait);
        w.* = .{ .q = q.retain(), .generation = generation, .on = on, .code = try core.gpa.dupe(u8, code), .version = try core.gpa.dupe(u8, version) };
        const t = std.Thread.spawn(.{}, qrWaiting, .{w}) catch |e| {
            q.release();
            core.gpa.free(w.code);
            core.gpa.free(w.version);
            core.gpa.destroy(w);
            return e;
        };
        t.detach();
    }
    const deadline = core.monoMs() + 100_000;
    q.mutex.lock();
    while (!q.done and !q.aborted) {
        const now = core.monoMs();
        if (now >= deadline) break;
        q.cond.waitTimeout(core.io, &q.mutex.m, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(deadline - now)), .clock = .awake } }) catch {};
    }
    const done = q.done;
    const aborted = q.aborted;
    if (!done) q.gone = true;
    const confirm = q.confirm;
    const wait_err = q.err;
    q.mutex.unlock();
    if (aborted) return fail.set(a, QR_ABORTED, .{});
    if (!done) {
        on(generation, .expired);
        return fail.set(a, QR_ABORTED, .{});
    }
    const answer = confirm orelse return fail.set(a, "{s}", .{wait_err});
    const error_code = proto.field(answer, "error_code");
    if (error_code != null and error_code.? == .integer and error_code.?.integer == -13) {
        on(generation, .declined);
        return fail.set(a, QR_ABORTED, .{});
    }
    if (!codeOk(error_code))
        return fail.set(a, "An error has occurred.\nResponse: {s}", .{try std.json.Stringify.valueAlloc(a, answer, .{ .whitespace = .indent_2 })});

    // checkSession: its redirects set the chat cookies
    var unused: core.Fail = .{};
    _ = http.request(a, "https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html", .GET, try idHeaders(a, REF_CHAT, true, &.{
        .{ .name = "sec-fetch-site", .value = "same-origin" },
    }), null, &unused) catch return fail.set(a, "Cannot get session, login failed", .{});
    // (the content-type id requests carry is the session's default anyway)
    const user: ?Value = blk: {
        const r = http.request(a, "https://jr.chat.zalo.me/jr/userinfo", .GET, try idHeaders(a, "https://chat.zalo.me/", false, &.{
            .{ .name = "sec-fetch-site", .value = "same-site" },
        }), null, &unused) catch break :blk null;
        break :blk r.json(a) catch null;
    };
    const user_data = proto.field(user, "data");
    if (!proto.truthy(user_data)) return fail.set(a, "Can't get account info", .{});
    if (!proto.truthy(proto.field(user_data, "logged"))) return fail.set(a, "Can't login", .{});
    if (q.isGone()) return fail.set(a, QR_ABORTED, .{});

    var creds: Credentials = .{ .imei = try proto.zaloUuid(a, QR_USER_AGENT), .cookie = blk: {
        http.mutex.lock();
        defer http.mutex.unlock();
        break :blk try http.jar.toJson(a);
    }, .user_agent = QR_USER_AGENT };
    on(generation, .{ .got_login_info = creds });
    creds.language = "vi";
    return login(a, creds, fail);
}

// ---------------- the API ----------------

/// An object of the pairs whose value is not null.
fn obj(a: Allocator, pairs: []const struct { []const u8, Value }) !Value {
    var m: std.json.ObjectMap = .empty;
    for (pairs) |p| if (p[1] != .null) try m.put(a, p[0], p[1]);
    return .{ .object = m };
}

/// `handleMessage`'s last path segment for a plain text.
fn textEndpoint(group: bool) []const u8 {
    return if (group) "sendmsg" else "sms";
}

/// `handleMessage`'s params for a plain text (no quote, no mentions).
fn textParams(a: Allocator, msg: []const u8, thread_id: []const u8, group: bool, imei: []const u8, client_id: i64) !Value {
    const none: Value = .null;
    return obj(a, &.{
        .{ "clientId", .{ .integer = client_id } },
        .{ "grid", if (group) Value{ .string = thread_id } else none },
        .{ "imei", if (!group) Value{ .string = imei } else none },
        .{ "message", .{ .string = msg } },
        .{ "toid", if (!group) Value{ .string = thread_id } else none },
        .{ "ttl", .{ .integer = 0 } },
        .{ "visibility", if (group) Value{ .integer = 0 } else none },
    });
}

// ---------------- tests ----------------

const testing = std.testing;

fn expectJson(a: Allocator, want: []const u8, got: Value) !void {
    try testing.expect(proto.jsonEql(try proto.parseJson(a, want), got));
}

test "loose error codes" {
    try testing.expect(codeOk(.{ .integer = 0 }) and codeOk(.{ .string = "0" }) and codeOk(.{ .string = "" }));
    try testing.expect(!codeOk(null) and !codeOk(.{ .integer = -1 }) and !codeOk(.null));
}

test "text to a person" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try textParams(a, "chào", "123", false, "imei-1", 42);
    try expectJson(a, "{\"message\":\"chào\",\"clientId\":42,\"imei\":\"imei-1\",\"ttl\":0,\"toid\":\"123\"}", p);
    // keys in the order the Rust build sent them (sorted)
    try testing.expectEqualStrings("{\"clientId\":42,\"imei\":\"imei-1\",\"message\":\"chào\",\"toid\":\"123\",\"ttl\":0}", try core.toJson(a, p));
    try testing.expectEqualStrings("sms", textEndpoint(false));
}

test "text to a group" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try textParams(a, "hi", "g9", true, "imei-1", 7);
    // groups: no imei, `grid` instead of `toid`, visibility 0
    try expectJson(a, "{\"message\":\"hi\",\"clientId\":7,\"ttl\":0,\"visibility\":0,\"grid\":\"g9\"}", p);
    try testing.expectEqualStrings("sendmsg", textEndpoint(true));
}

test "object drops nulls" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectJson(a, "{\"a\":1,\"c\":\"\"}", try obj(a, &.{ .{ "a", .{ .integer = 1 } }, .{ "b", .null }, .{ "c", .{ .string = "" } } }));
}

test "the login script's version" {
    try testing.expectEqualStrings("2.44.10", loginVersion("<script src=\"https://stc-zlogin.zdn.vn/main-2.44.10.js\"></script>").?);
    try testing.expectEqualStrings("7", loginVersion("x https://stc-zlogin.zdn.vn/main-7.js").?);
    // the first that matches, skipping what only looks like it
    try testing.expectEqualStrings("3.1", loginVersion("https://stc-zlogin.zdn.vn/main-abc.js https://stc-zlogin.zdn.vn/main-1.2.css https://stc-zlogin.zdn.vn/main-3.1.js").?);
    try testing.expect(loginVersion("https://stc-zlogin.zdn.vn/main-.js") == null);
    try testing.expect(loginVersion("https://stc-zlogin.zdn.vn/main-1.2js") == null);
    try testing.expect(loginVersion("https://stc-zlogin.zdn.vn/main-1.2") == null);
    try testing.expect(loginVersion("") == null);
}

test "redirects and origins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://id.zalo.me/account/checksession?continue=x";
    try testing.expectEqualStrings("https://chat.zalo.me/index.html?a=1", try joinUrl(a, base, "https://chat.zalo.me/index.html?a=1"));
    try testing.expectEqualStrings("https://id.zalo.me/login?next=%2F", try joinUrl(a, base, "/login?next=%2F"));
    try testing.expectEqualStrings("https://id.zalo.me/account/step2", try joinUrl(a, base, "step2"));
    try testing.expectEqualStrings("https://jr.chat.zalo.me/x", try joinUrl(a, base, "//jr.chat.zalo.me/x"));
    try testing.expectEqualStrings("https://id.zalo.me", try originOf(a, base));
    try testing.expectEqualStrings("http://localhost:8080", try originOf(a, "http://localhost:8080/a/b?c"));
    try testing.expectEqualStrings("id.zalo.me", try hostOf(a, "https://ID.zalo.me/x"));
}

test "credentials keep tough-cookie's JSON" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // what the Rust build saved
    const saved = "{\"imei\":\"i-1\",\"cookie\":[{\"key\":\"a\",\"value\":\"1\",\"domain\":\"zalo.me\"}],\"userAgent\":\"UA\"}";
    const c = try core.fromJson(Credentials, a, saved);
    try testing.expectEqualStrings("i-1", c.imei);
    try testing.expectEqualStrings("UA", c.user_agent);
    try testing.expect(c.language == null and c.cookie == .array);
    try testing.expectEqualStrings(saved, try core.toJson(a, c));
    const with_lang = try core.toJson(a, Credentials{ .imei = "x", .language = "vi" });
    try testing.expectEqualStrings("{\"imei\":\"x\",\"cookie\":null,\"userAgent\":\"\",\"language\":\"vi\"}", with_lang);
}

test "a missing piece of the session is said before any request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fail: core.Fail = .{};
    try testing.expectError(error.Failed, login(a, .{ .imei = "x", .user_agent = "UA" }, &fail));
    try testing.expectEqualStrings("Missing required params", fail.msg);
}
