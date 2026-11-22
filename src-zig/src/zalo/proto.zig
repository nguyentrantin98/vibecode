//! Zalo Web's wire format, ported from zca-js 2.3.0 (`dist/utils.js`, `apis/login.js`,
//! `apis/listen.js`): the AES-CBC used for request params, the login-time param encryptor and
//! its signature, websocket frames and how their (encrypted, deflated) event data decodes.
//!
//! Everything here is pure: unit tests compare it with values produced by zca-js itself.

const std = @import("std");
const core = @import("../core.zig");
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

/// zca-js `createContext` defaults (`apiType`, `apiVersion`).
pub const API_TYPE: u32 = 30;
pub const API_VERSION: u32 = 685;

/// A query / form parameter.
pub const Pair = struct { []const u8, []const u8 };

// ---------------- base64 ----------------

const b64_chars = std.base64.standard_alphabet_chars;

/// Standard alphabet, padded.
pub fn b64Encode(a: Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// Standard alphabet, lenient on input (like crypto-js' Base64.parse): padding may be there or
/// not, and the bits left over in the last character are dropped.
pub fn b64Decode(a: Allocator, text: []const u8) ![]u8 {
    const s = std.mem.trimEnd(u8, text, "=");
    if (s.len % 4 == 1) return error.InvalidBase64;
    const out = try a.alloc(u8, s.len * 6 / 8);
    errdefer a.free(out);
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (s) |ch| {
        const v: u32 = switch (ch) {
            'A'...'Z' => ch - 'A',
            'a'...'z' => ch - 'a' + 26,
            '0'...'9' => ch - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => return error.InvalidBase64,
        };
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n] = @truncate(acc >> bits);
            n += 1;
        }
    }
    std.debug.assert(n == out.len);
    return out;
}

// ---------------- hashing ----------------

pub fn hex(a: Allocator, bytes: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const out = try a.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}

pub fn md5Hex(data: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// `getSignKey`: md5("zsecure" + type + the values of `params`, ordered by key).
pub fn signKey(a: Allocator, kind: []const u8, params: []const Pair) ![32]u8 {
    const sorted = try a.dupe(Pair, params);
    defer a.free(sorted);
    std.mem.sort(Pair, sorted, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return std.mem.order(u8, x[0], y[0]) == .lt;
        }
    }.lt);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(a);
    try s.appendSlice(a, "zsecure");
    try s.appendSlice(a, kind);
    for (sorted) |p| try s.appendSlice(a, p[1]);
    return md5Hex(s.items);
}

/// A random (version 4) uuid, "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".
pub fn uuidV4() [36]u8 {
    var b: [16]u8 = undefined;
    core.io.random(&b);
    return uuidFrom(b);
}

fn uuidFrom(bytes: [16]u8) [36]u8 {
    var b = bytes;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] }) catch unreachable;
    return out;
}

/// zca-js `generateZaloUUID`: a v4 uuid + "-" + md5(user agent).
pub fn zaloUuid(a: Allocator, user_agent: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}-{s}", .{ uuidV4(), md5Hex(user_agent) });
}

// ---------------- AES-CBC, zero IV, PKCS#7 (crypto-js) ----------------

const aes = std.crypto.core.aes;

/// AES-128 or AES-256 by the key's length. (crypto-js would also take a 24-byte key; Zalo's keys
/// are 16 or 32 bytes and Zig's std has no AES-192.)
const AesKey = union(enum) {
    a128: [16]u8,
    a256: [32]u8,

    fn init(key: []const u8) !AesKey {
        return switch (key.len) {
            16 => .{ .a128 = key[0..16].* },
            32 => .{ .a256 = key[0..32].* },
            else => error.BadAesKey,
        };
    }

    fn encrypter(k: AesKey) Enc {
        return switch (k) {
            .a128 => |key| .{ .a128 = aes.Aes128.initEnc(key) },
            .a256 => |key| .{ .a256 = aes.Aes256.initEnc(key) },
        };
    }

    const Enc = union(enum) {
        a128: aes.AesEncryptCtx(aes.Aes128),
        a256: aes.AesEncryptCtx(aes.Aes256),

        fn encrypt(e: Enc, dst: *[16]u8, src: *const [16]u8) void {
            switch (e) {
                inline else => |c| c.encrypt(dst, src),
            }
        }
    };
};

pub fn cbcEncrypt(a: Allocator, key: []const u8, data: []const u8) ![]u8 {
    const enc = (try AesKey.init(key)).encrypter();
    const pad = 16 - data.len % 16;
    const buf = try a.alloc(u8, data.len + pad);
    @memcpy(buf[0..data.len], data);
    @memset(buf[data.len..], @intCast(pad));
    var prev: [16]u8 = @splat(0);
    var i: usize = 0;
    while (i < buf.len) : (i += 16) {
        const chunk = buf[i..][0..16];
        var block: [16]u8 = undefined;
        for (&block, chunk, prev) |*b, c, p| b.* = c ^ p;
        enc.encrypt(chunk, &block);
        prev = chunk.*;
    }
    return buf;
}

pub fn cbcDecrypt(a: Allocator, key: []const u8, data: []const u8) ![]u8 {
    const k = try AesKey.init(key);
    // the ciphertext must be a whole number of blocks
    if (data.len == 0 or data.len % 16 != 0) return error.BadCiphertext;
    const out = try a.alloc(u8, data.len);
    errdefer a.free(out);
    var prev: [16]u8 = @splat(0);
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        const chunk = data[i..][0..16];
        var block: [16]u8 = undefined;
        switch (k) {
            .a128 => |key16| aes.Aes128.initDec(key16).decrypt(&block, chunk),
            .a256 => |key32| aes.Aes256.initDec(key32).decrypt(&block, chunk),
        }
        for (out[i..][0..16], block, prev) |*o, b, p| o.* = b ^ p;
        prev = chunk.*;
    }
    // crypto-js strips as many bytes as the last one says, without checking them
    const pad: usize = out[out.len - 1];
    if (pad == 0 or pad > 16) return error.BadPadding;
    const plain = try a.dupe(u8, out[0 .. out.len - pad]);
    a.free(out);
    return plain;
}

const ws_chars = " \t\r\n\x0b\x0c";

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, ws_chars);
}

/// `encodeAES(secretKey, data)`: the session's request params (key = base64 `zpw_enk`).
pub fn encodeAes(a: Allocator, secret_key: []const u8, data: []const u8) ![]u8 {
    const key = try b64Decode(a, trim(secret_key));
    defer a.free(key);
    const ct = try cbcEncrypt(a, key, data);
    defer a.free(ct);
    return b64Encode(a, ct);
}

/// `decodeAES(secretKey, data)`: an API response's `data`.
pub fn decodeAes(a: Allocator, secret_key: []const u8, data: []const u8) ![]u8 {
    const key = try b64Decode(a, trim(secret_key));
    defer a.free(key);
    const uri = try decodeUriComponent(a, data);
    defer a.free(uri);
    const raw = try b64Decode(a, trim(uri));
    defer a.free(raw);
    const plain = try cbcDecrypt(a, key, raw);
    errdefer a.free(plain);
    if (!std.unicode.utf8ValidateSlice(plain)) return error.InvalidUtf8;
    return plain;
}

/// `ParamsEncryptor.encodeAES`: key = the UTF-8 bytes of `key`, output hex or base64.
pub fn encodeAesUtf8Key(a: Allocator, key: []const u8, message: []const u8, as_hex: bool, uppercase: bool) ![]u8 {
    const ct = try cbcEncrypt(a, key, message);
    defer a.free(ct);
    const s = if (as_hex) try hex(a, ct) else try b64Encode(a, ct);
    if (uppercase) _ = std.ascii.upperString(s, s);
    return s;
}

/// `decryptResp(key, data)`: the login response, parsed when it is JSON (a string otherwise).
/// Allocate in an arena.
pub fn decryptResp(a: Allocator, key: []const u8, data: []const u8) !Value {
    const raw = try b64Decode(a, trim(try decodeUriComponent(a, data)));
    const text = try cbcDecrypt(a, key, raw);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    return parseJson(a, text) catch Value{ .string = text };
}

// ---------------- the login param encryptor ----------------

/// `ParamsEncryptor`: the per-login key Zalo derives from (type, imei, launch time) + a random salt.
pub const ParamsEncryptor = struct {
    zcid: []const u8,
    zcid_ext: []const u8,
    encrypt_key: []const u8,

    pub const ENC_VER = "v2";

    pub fn init(a: Allocator, kind: u32, imei: []const u8, first_launch_time: u64) !ParamsEncryptor {
        return withExt(a, kind, imei, first_launch_time, try randomHex(a));
    }

    pub fn withExt(a: Allocator, kind: u32, imei: []const u8, first_launch_time: u64, zcid_ext: []const u8) !ParamsEncryptor {
        const msg = try std.fmt.allocPrint(a, "{d},{s},{d}", .{ kind, imei, first_launch_time });
        defer a.free(msg);
        const zcid = try encodeAesUtf8Key(a, "3FC4F0D2AB50057BCE0D90D9187A22B1", msg, true, true);
        var n = md5Hex(zcid_ext);
        _ = std.ascii.upperString(&n, &n);
        // 8 even characters of the salt's md5, 12 even ones of zcid, 12 odd ones of zcid from the end
        var key: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < n.len and key.items.len < 8) : (i += 2) try key.append(a, n[i]);
        i = 0;
        var taken: usize = 0;
        while (i < zcid.len and taken < 12) : (i += 2) {
            try key.append(a, zcid[i]);
            taken += 1;
        }
        // the last odd index
        i = if (zcid.len % 2 == 0) zcid.len else zcid.len - 1;
        taken = 0;
        while (i >= 2 and taken < 12) : (i -= 2) {
            try key.append(a, zcid[i - 1]);
            taken += 1;
        }
        return .{ .zcid = zcid, .zcid_ext = zcid_ext, .encrypt_key = try key.toOwnedSlice(a) };
    }
};

/// `ParamsEncryptor.randomString()`: 6–12 hex digits.
fn randomHex(a: Allocator) ![]u8 {
    var b: [16]u8 = undefined;
    core.io.random(&b);
    const len = 6 + b[0] % 7;
    const h = std.fmt.bytesToHex(b, .lower);
    return a.dupe(u8, h[0..len]);
}

// ---------------- websocket ----------------

/// A frame Zalo's socket takes: version, cmd (u16 LE), sub-command, then the JSON body.
pub fn encodeFrame(a: Allocator, version: u8, cmd: u16, sub_cmd: u8, body: []const u8) ![]u8 {
    const out = try a.alloc(u8, 4 + body.len);
    out[0] = version;
    std.mem.writeInt(u16, out[1..3], cmd, .little);
    out[3] = sub_cmd;
    @memcpy(out[4..], body);
    return out;
}

pub const FrameHeader = struct { version: u8, cmd: u16, sub: u8 };

/// (version, cmd, sub-command) of a received frame.
pub fn frameHeader(frame: []const u8) ?FrameHeader {
    if (frame.len < 4) return null;
    return .{ .version = frame[0], .cmd = std.mem.readInt(u16, frame[1..3], .little), .sub = frame[3] };
}

/// `decodeEventData`: `{data, encrypt}` → the event JSON. encrypt 0: plain JSON; 1: base64 of
/// deflated JSON; 2: AES-GCM(cipher key) of deflated JSON; 3: AES-GCM of plain JSON.
/// Allocate in an arena.
pub fn decodeEventData(a: Allocator, parsed: Value, cipher_key: ?[]const u8) !Value {
    const raw = switch (field(parsed, "data") orelse Value{ .null = {} }) {
        .string => |s| s,
        else => return error.InvalidData, // expected string
    };
    const kind: i64 = switch (field(parsed, "encrypt") orelse Value{ .null = {} }) {
        .integer => |n| n,
        else => return error.InvalidEncryptType, // expected number
    };
    if (kind < 0 or kind > 3) return error.InvalidEncryptType;
    if (kind == 0) return parseJson(a, raw);
    const decoded = if (kind == 1) try b64Decode(a, trim(raw)) else try b64Decode(a, trim(try decodeUriComponent(a, raw)));
    const decrypted = if (kind == 1) decoded else blk: {
        const key = cipher_key orelse return error.MissingCipherKey;
        if (decoded.len < 48) return error.InvalidDataLength;
        break :blk try aesGcm16(a, try b64Decode(a, key), decoded[0..16], decoded[16..32], decoded[32..]);
    };
    const plain = if (kind == 3) decrypted else try inflate(a, decrypted);
    return parseJson(a, plain);
}

/// AES-GCM with the 16-byte IV Zalo uses (WebCrypto infers AES-128/256 from the key). `data` is
/// the ciphertext followed by the 16-byte tag. std's AES-GCM only takes 12-byte nonces, so the
/// counter block is derived here the way the standard says for any other length.
fn aesGcm16(a: Allocator, key: []const u8, iv: *const [16]u8, aad: []const u8, data: []const u8) ![]u8 {
    if (data.len < 16) return error.InvalidDataLength;
    return switch (key.len) {
        16 => gcmDecrypt(aes.Aes128, a, key[0..16].*, iv, aad, data),
        32 => gcmDecrypt(aes.Aes256, a, key[0..32].*, iv, aad, data),
        else => error.BadCipherKey,
    };
}

fn gcmDecrypt(comptime Aes: type, a: Allocator, key: [Aes.key_bits / 8]u8, iv: *const [16]u8, aad: []const u8, data: []const u8) ![]u8 {
    const Ghash = std.crypto.onetimeauth.Ghash;
    const ct = data[0 .. data.len - 16];
    const tag = data[data.len - 16 ..][0..16];
    const ctx = Aes.initEnc(key);
    var h: [16]u8 = undefined;
    ctx.encrypt(&h, &@as([16]u8, @splat(0)));

    // J0 = GHASH(IV ‖ padding ‖ [0]64 ‖ [len(IV) in bits]64)
    var j0: [16]u8 = undefined;
    {
        var g = Ghash.init(&h);
        g.update(iv);
        g.pad();
        var len_block: [16]u8 = @splat(0);
        std.mem.writeInt(u64, len_block[8..16], iv.len * 8, .big);
        g.update(&len_block);
        g.final(&j0);
    }
    var t: [16]u8 = undefined;
    ctx.encrypt(&t, &j0);

    var mac = Ghash.init(&h);
    mac.update(aad);
    mac.pad();
    mac.update(ct);
    mac.pad();
    var len_block: [16]u8 = undefined;
    std.mem.writeInt(u64, len_block[0..8], @as(u64, aad.len) * 8, .big);
    std.mem.writeInt(u64, len_block[8..16], @as(u64, ct.len) * 8, .big);
    mac.update(&len_block);
    var computed: [16]u8 = undefined;
    mac.final(&computed);
    for (&computed, t) |*x, y| x.* ^= y;
    if (!std.crypto.timing_safe.eql([16]u8, computed, tag.*)) return error.AuthenticationFailed;

    // the data is encrypted with the counter after J0 (its last 32 bits count, wrapping)
    var counter = j0;
    std.mem.writeInt(u32, counter[12..16], std.mem.readInt(u32, j0[12..16], .big) +% 1, .big);
    const out = try a.alloc(u8, ct.len);
    std.crypto.core.modes.ctrSlice(@TypeOf(ctx), ctx, out, ct, counter, .big, 12, 4);
    return out;
}

/// `pako.inflate`: zlib, or gzip when the header says so.
pub fn inflate(a: Allocator, data: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var d: std.compress.flate.Decompress = .init(&in, if (std.mem.startsWith(u8, data, &.{ 0x1f, 0x8b })) .gzip else .zlib, window);
    return d.reader.allocRemaining(a, .unlimited);
}

// ---------------- URLs ----------------

/// `URLSearchParams` serialization of one name or value (application/x-www-form-urlencoded).
fn formEncodeInto(out: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '*' or ch == '-' or ch == '.' or ch == '_') {
            try out.append(a, ch);
        } else if (ch == ' ') {
            try out.append(a, '+');
        } else {
            try out.print(a, "%{X:0>2}", .{ch});
        }
    }
}

/// `k=v&k2=v2`, form-urlencoded.
pub fn formEncode(a: Allocator, pairs: []const Pair) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(a, '&');
        try formEncodeInto(&out, a, p[0]);
        try out.append(a, '=');
        try formEncodeInto(&out, a, p[1]);
    }
    return out.toOwnedSlice(a);
}

/// Whether the query string has a parameter named `name`.
fn queryHas(a: Allocator, query: []const u8, name: []const u8) !bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        const raw = part[0 .. std.mem.indexOfScalar(u8, part, '=') orelse part.len];
        const key = try a.dupe(u8, raw);
        defer a.free(key);
        std.mem.replaceScalar(u8, key, '+', ' ');
        if (std.mem.eql(u8, std.Uri.percentDecodeInPlace(key), name)) return true;
    }
    return false;
}

/// `makeURL`: append `params`, then `zpw_ver` / `zpw_type` unless present.
pub fn makeUrl(a: Allocator, base: []const u8, params: []const Pair, api_version: bool) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return error.BadUrl;
    if (scheme_end == 0 or base.len == scheme_end + 3) return error.BadUrl;
    const q = std.mem.indexOfScalar(u8, base, '?');
    const head = base[0 .. q orelse base.len];
    const query = if (q) |i| base[i + 1 ..] else "";

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, head);
    // a URL always has a path
    if (std.mem.indexOfScalar(u8, head[scheme_end + 3 ..], '/') == null) try out.append(a, '/');

    var all: std.ArrayList(Pair) = .empty;
    defer all.deinit(a);
    try all.appendSlice(a, params);
    var ver_buf: [16]u8 = undefined;
    var type_buf: [16]u8 = undefined;
    if (api_version and !try queryHas(a, query, "zpw_ver"))
        try all.append(a, .{ "zpw_ver", std.fmt.bufPrint(&ver_buf, "{d}", .{API_VERSION}) catch unreachable });
    if (api_version and !try queryHas(a, query, "zpw_type"))
        try all.append(a, .{ "zpw_type", std.fmt.bufPrint(&type_buf, "{d}", .{API_TYPE}) catch unreachable });

    const added = try formEncode(a, all.items);
    defer a.free(added);
    if (q != null or added.len > 0) try out.append(a, '?');
    try out.appendSlice(a, query);
    if (query.len > 0 and added.len > 0) try out.append(a, '&');
    try out.appendSlice(a, added);
    return out.toOwnedSlice(a);
}

/// JS `decodeURIComponent` (throws on a malformed escape).
pub fn decodeUriComponent(a: Allocator, s: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return a.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 3 > s.len) return error.UriMalformed;
            // two hex digits, nothing else (parseInt would take a sign)
            if (!std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return error.UriMalformed;
            try out.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.UriMalformed);
            i += 3;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return error.UriMalformed;
    return out.toOwnedSlice(a);
}

// ---------------- JSON values, with JS semantics ----------------

/// Parses any JSON into a `Value` (allocate in an arena).
pub fn parseJson(a: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}

/// `v[key]` (null: `v` is no object or has no such key).
pub fn field(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    return if (o == .object) o.object.get(key) else null;
}

/// The string at `v[key]`, when it is one.
pub fn fieldStr(v: ?Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

/// A deep copy in `a`.
pub fn cloneValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

/// JS `String(v)` for a JSON value (null = undefined).
pub fn jstr(a: Allocator, v: ?Value) ![]const u8 {
    return switch (v orelse return "undefined") {
        .null => "null",
        .string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        .array, .object => core.toJson(a, v.?),
    };
}

/// JS truthiness.
pub fn truthy(v: ?Value) bool {
    return switch (v orelse return false) {
        .null => false,
        .bool => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0 and !std.math.isNan(f),
        .number_string => true,
        .string => |s| s.len > 0,
        .array, .object => true,
    };
}

/// JS `Number(v)` (NaN for what doesn't convert).
pub fn jnum(v: ?Value) f64 {
    const nan = std.math.nan(f64);
    return switch (v orelse return nan) {
        .null => 0,
        .bool => |b| @floatFromInt(@intFromBool(b)),
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch nan,
        .string => |s| blk: {
            const t = trim(s);
            if (t.len == 0) break :blk 0;
            if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) {
                for (t[2..]) |ch| if (!std.ascii.isHex(ch)) break :blk nan;
                break :blk if (std.fmt.parseInt(i64, t[2..], 16)) |n| @floatFromInt(n) else |_| nan;
            }
            if (std.mem.eql(u8, t, "Infinity") or std.mem.eql(u8, t, "+Infinity")) break :blk std.math.inf(f64);
            if (std.mem.eql(u8, t, "-Infinity")) break :blk -std.math.inf(f64);
            // parseFloat would take "inf" / "nan" / "1_000"; JS doesn't
            for (t) |ch| if ((std.ascii.isAlphabetic(ch) and ch != 'e' and ch != 'E') or ch == '_') break :blk nan;
            break :blk std.fmt.parseFloat(f64, t) catch nan;
        },
        .array, .object => nan,
    };
}

/// `v == "0"` (loose): the string "0" or the number 0.
pub fn isZeroId(v: ?Value) bool {
    return switch (v orelse return false) {
        .string => |s| std.mem.eql(u8, s, "0"),
        .integer => |n| n == 0,
        .float => |f| f == 0,
        else => false,
    };
}

/// Milliseconds since the epoch, as JS `Date.now()`.
pub fn nowMs() i64 {
    return @intCast(core.nowMs());
}

/// Structural equality (object keys in any order; 1 == 1.0), for tests.
pub fn jsonEql(x: Value, y: Value) bool {
    return switch (x) {
        .null => y == .null,
        .bool => |b| y == .bool and y.bool == b,
        .integer, .float => (y == .integer or y == .float) and jnum(x) == jnum(y),
        .number_string => |s| y == .number_string and std.mem.eql(u8, s, y.number_string),
        .string => |s| y == .string and std.mem.eql(u8, s, y.string),
        .array => |arr| blk: {
            if (y != .array or y.array.items.len != arr.items.len) break :blk false;
            for (arr.items, y.array.items) |p, q| if (!jsonEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |obj| blk: {
            if (y != .object or y.object.count() != obj.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |e| {
                const other = y.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEql(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ---------------- tests ----------------
// Expected values were produced by zca-js 2.3.0's own helpers under node (crypto-js, pako,
// WebCrypto).

const testing = std.testing;
const PLAIN = "{\"imei\":\"abc-123\",\"text\":\"Xin chào 👋 \\\"q\\\"\",\"n\":1}";

test "encodeAes matches zca" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "IEYbby6K8plUNeGKatxhpYgkaZ49oRlGVvR70j/TrLaaNYf/dwMjB5GIdJlxI2VRWAF8Yfh7+zx1y92KaHcmmw==",
        try encodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", PLAIN),
    );
    try testing.expectEqualStrings(
        "zJ97ujC7o++hZBZ+MTbuMWCTOxqZgx6vfkcKQ7s1jMfEEBfi5IxQLUinYneELg/0WCgIlJuf0oBEJqSrftmZpQ==",
        try encodeAes(a, "ABEiM0RVZneImaq7zN3u/wARIjNEVWZ3iJmqu8zd7v8=", PLAIN),
    );
}

test "decodeAes: roundtrip and URI-encoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = "IEYbby6K8plUNeGKatxhpYgkaZ49oRlGVvR70j/TrLaaNYf/dwMjB5GIdJlxI2VRWAF8Yfh7+zx1y92KaHcmmw==";
    try testing.expectEqualStrings(PLAIN, try decodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", enc));
    var uri = try std.mem.replaceOwned(u8, a, enc, "+", "%2B");
    uri = try std.mem.replaceOwned(u8, a, uri, "/", "%2F");
    uri = try std.mem.replaceOwned(u8, a, uri, "=", "%3D");
    try testing.expectEqualStrings(PLAIN, try decodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", uri));
    // a 24-byte key is not supported; a wrong one is an error, not garbage
    try testing.expectError(error.BadAesKey, encodeAes(a, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX", PLAIN));
}

test "the memory of the AES helpers is released" {
    const a = testing.allocator;
    const enc = try encodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", PLAIN);
    defer a.free(enc);
    const dec = try decodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", enc);
    defer a.free(dec);
    try testing.expectEqualStrings(PLAIN, dec);
    try testing.expectError(error.InvalidBase64, decodeAes(a, "AAECAwQFBgcICQoLDA0ODw==", "!!!!"));
}

test "sign keys match zca" {
    const a = testing.allocator;
    const p = [_]Pair{ .{ "zcid", "ABC" }, .{ "zcid_ext", "f00d" }, .{ "enc_ver", "v2" }, .{ "params", "xyz==" }, .{ "type", "30" }, .{ "client_version", "685" } };
    try testing.expectEqualStrings("311171f7166804f88e231dea50c65903", &try signKey(a, "getlogininfo", &p));
    const s = [_]Pair{ .{ "imei", "imei-1" }, .{ "type", "30" }, .{ "client_version", "685" }, .{ "computer_name", "Web" } };
    try testing.expectEqualStrings("e056a872bbfd6d4998380170e8df066b", &try signKey(a, "getserverinfo", &s));
}

test "params encryptor matches zca" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pe = try ParamsEncryptor.withExt(a, 30, "imei-1", 1700000000000, "a1b2c3d4e5");
    try testing.expectEqualStrings("0E1E394F287EC558340011224B0BAE698D6F8454F6A9D7AFA8C0F07059D228A5", pe.zcid);
    try testing.expectEqualStrings("C3A3B143013427C5301258290008F796", pe.encrypt_key);
    const enc = try encodeAesUtf8Key(a, pe.encrypt_key, PLAIN, false, false);
    try testing.expectEqualStrings("3BFow1GREB3yn8ZysM0p/wXOqx7QJIOOHSqrcWI8KzBTvhZdTEVfWHD2MaRyRbEzKlIGFK+sKuFrrAlx5NTffA==", enc);
    var uri = try std.mem.replaceOwned(u8, a, enc, "+", "%2B");
    uri = try std.mem.replaceOwned(u8, a, uri, "/", "%2F");
    const back = try decryptResp(a, pe.encrypt_key, uri);
    try testing.expectEqualStrings("Xin chào 👋 \"q\"", fieldStr(back, "text").?);
    try testing.expectEqual(@as(i64, 1), field(back, "n").?.integer);
    // a fresh encryptor makes a 6–12 digit salt and a 32-char key
    core.io = testing.io;
    const r = try ParamsEncryptor.init(a, 30, "imei-1", 1);
    try testing.expect(r.zcid_ext.len >= 6 and r.zcid_ext.len <= 12);
    for (r.zcid_ext) |ch| try testing.expect(std.ascii.isHex(ch));
    try testing.expectEqual(@as(usize, 32), r.encrypt_key.len);
}

test "md5 and uuid" {
    const a = testing.allocator;
    const ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0";
    try testing.expectEqualStrings("a69b52f9d7f760edf3fd052bcda2542f", &md5Hex(ua));
    const u = uuidFrom(@splat(0xff));
    try testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", &u);
    core.io = testing.io;
    const z = try zaloUuid(a, ua);
    defer a.free(z);
    try testing.expect(std.mem.endsWith(u8, z, "-a69b52f9d7f760edf3fd052bcda2542f"));
    try testing.expectEqual(@as(usize, 36 + 1 + 32), z.len);
    try testing.expectEqual(@as(u8, '4'), z[14]);
}

test "makeUrl matches zca" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "https://tt-chat-wpa.chat.zalo.me/api/message/sms?nretry=0&params=a%2Bb%2Fc%3D%3D&x=1&zpw_ver=685&zpw_type=30",
        try makeUrl(a, "https://tt-chat-wpa.chat.zalo.me/api/message/sms?nretry=0", &.{ .{ "params", "a+b/c==" }, .{ "x", "1" } }, true),
    );
    try testing.expectEqualStrings(
        "https://files.zalo.me/api/message/photo_original/send?nretry=0&zpw_ver=685&zpw_type=30",
        try makeUrl(a, "https://files.zalo.me/api/message/photo_original/send?", &.{.{ "nretry", "0" }}, true),
    );
    const once = try makeUrl(a, "https://a.zalo.me/x", &.{}, true);
    try testing.expectEqualStrings("https://a.zalo.me/x?zpw_ver=685&zpw_type=30&p=1", try makeUrl(a, once, &.{.{ "p", "1" }}, true));
    // a bare host gets its "/" (as a URL object would print it); nothing to add leaves it alone
    try testing.expectEqualStrings("wss://ws.chat.zalo.me/?t=5&zpw_ver=685&zpw_type=30", try makeUrl(a, "wss://ws.chat.zalo.me", &.{.{ "t", "5" }}, true));
    try testing.expectEqualStrings("https://a.zalo.me/x", try makeUrl(a, "https://a.zalo.me/x", &.{}, false));
    try testing.expectEqualStrings("a=1+2&b=%C3%A0%26", try formEncode(a, &.{ .{ "a", "1 2" }, .{ "b", "à&" } }));
    try testing.expectError(error.BadUrl, makeUrl(a, "not a url", &.{}, true));
}

test "frames match zca" {
    const a = testing.allocator;
    const body = "{\"first\":true,\"lastId\":null,\"preIds\":[],\"req_id\":\"req_0\"}";
    const f = try encodeFrame(a, 1, 510, 1, body);
    defer a.free(f);
    const h = try hex(a, f);
    defer a.free(h);
    try testing.expectEqualStrings(
        "01fe01017b226669727374223a747275652c226c6173744964223a6e756c6c2c22707265496473223a5b5d2c227265715f6964223a227265715f30227d",
        h,
    );
    try testing.expectEqual(FrameHeader{ .version = 1, .cmd = 510, .sub = 1 }, frameHeader(f).?);
    try testing.expect(frameHeader(&.{ 1, 2 }) == null);
}

test "event data, all encryptions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "eW3IKbdwwN1/3bOziTGtGg==";
    const ev = "{\"data\":{\"msgs\":[{\"msgId\":\"7300000000000000001\",\"uidFrom\":\"0\",\"idTo\":\"123\",\"content\":\"hi\"}]},\"error_code\":0}";
    const want = try parseJson(a, ev);
    const e1 = "eJyrVkpJLElUsqpWyi1OL1ayigYzPFOUrJTMjQ3QgKGSjlJpZopbUX4uUN4AyMtMCckHMg2NjIGc5Py8ktS8EiA/I1OpNrZWRym1qCi/KD45PyVVycqgFgBsuR8C";
    const e2 = "hX690Znr76w1qPB%2Fn4zpsOwrajmqSfrBxfjPNkupHINPn2EUOss89F2ev2idwy9ywtZIGMndRpW1nmybKFgy3tuxRsqtrDypleC7DKmfxIXGkU2teYqPjwswt9ryKun1HONA2ym7dp2AcH%2BQXT4dHViYqTaTmJPwfic%2BMOqoWDcf3EG1JsY71TFzZS%2BO";
    const e3 = "eLPOda5L18GDkb2oEfcAD/TUewpeHoHJYPJjEBQ8rtoPg7GOhXM9agmP3oVXMfsGJFMmRzDvVRqg7F/E+/2ui2NOm1QF0lt/9KZbZlpU3DLPymugZAG/LXrZoa6BWWN1PsK/SJELH1ZcIbqp7DxzoaKFjNkdVHsnYX9eK9TVohGHzbHpskURKcxZnCJOxd0mMoNodI5ts5XAwNQf";
    const cases = [_]struct { []const u8, i64 }{ .{ ev, 0 }, .{ e1, 1 }, .{ e2, 2 }, .{ e3, 3 } };
    for (cases) |c| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "data", .{ .string = c[0] });
        try o.put(a, "encrypt", .{ .integer = c[1] });
        const got = try decodeEventData(a, .{ .object = o }, key);
        try testing.expect(jsonEql(got, want));
    }
    // the 19-digit id survives exactly (zca-js uses json-bigint here)
    const first = field(field(want, "data"), "msgs").?.array.items[0];
    try testing.expectEqualStrings("7300000000000000001", fieldStr(first, "msgId").?);
    var o: std.json.ObjectMap = .empty;
    try o.put(a, "data", .{ .string = e2 });
    try o.put(a, "encrypt", .{ .integer = 2 });
    try testing.expectError(error.MissingCipherKey, decodeEventData(a, .{ .object = o }, null));
    // a wrong key does not decrypt
    try testing.expectError(error.AuthenticationFailed, decodeEventData(a, .{ .object = o }, "AAECAwQFBgcICQoLDA0ODw=="));
    try o.put(a, "encrypt", .{ .integer = 4 });
    try testing.expectError(error.InvalidEncryptType, decodeEventData(a, .{ .object = o }, key));
}

test "js values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("12", try jstr(a, .{ .integer = 12 }));
    try testing.expectEqualStrings("undefined", try jstr(a, null));
    try testing.expectEqualStrings("9223372036854775808", try jstr(a, try parseJson(a, "9223372036854775808")));
    try testing.expect(!truthy(.{ .string = "" }) and truthy(.{ .string = "x" }) and !truthy(.{ .integer = 0 }));
    try testing.expectEqual(@as(f64, 42), jnum(.{ .string = " 42 " }));
    try testing.expectEqual(@as(f64, 0), jnum(.{ .string = "" }));
    try testing.expectEqual(@as(f64, 255), jnum(.{ .string = "0xff" }));
    try testing.expect(std.math.isNan(jnum(.{ .string = "abc" })));
    try testing.expect(std.math.isNan(jnum(.{ .string = "inf" })));
    try testing.expect(std.math.isNan(jnum(.{ .string = "1_000" })));
    try testing.expect(std.math.isNan(jnum(null)));
    try testing.expect(isZeroId(.{ .string = "0" }) and isZeroId(.{ .integer = 0 }) and !isZeroId(.{ .string = "10" }));
    try testing.expectEqualStrings("a bà", try decodeUriComponent(a, "a%20b%C3%A0"));
    try testing.expectError(error.UriMalformed, decodeUriComponent(a, "%E0%A4%A"));
    try testing.expectError(error.UriMalformed, decodeUriComponent(a, "%+1"));
}

test "base64 is lenient on input" {
    const a = testing.allocator;
    for ([_][]const u8{ "aGk=", "aGk", "aGl=", "aGk==" }) |s| {
        const out = try b64Decode(a, s);
        defer a.free(out);
        try testing.expectEqualStrings("hi", out);
    }
    try testing.expectError(error.InvalidBase64, b64Decode(a, "a"));
    try testing.expectError(error.InvalidBase64, b64Decode(a, "a b="));
}

test "inflate takes zlib and gzip" {
    const a = testing.allocator;
    // "hello hello hello" through zlib and gzip
    const z = try b64Decode(a, "eJzLSM3JyVfIQJAAOi4GfQ==");
    defer a.free(z);
    const out = try inflate(a, z);
    defer a.free(out);
    try testing.expectEqualStrings("hello hello hello", out);
    const g = try b64Decode(a, "H4sIAAAAAAAACstIzcnJV8hAkACAiPnlEQAAAA==");
    defer a.free(g);
    const out2 = try inflate(a, g);
    defer a.free(out2);
    try testing.expectEqualStrings("hello hello hello", out2);
}
