//! Secrets at rest (saved SQL passwords, the Zalo session).
//!
//! Same format Electron's `safeStorage` wrote, so everything the old builds saved still opens:
//! `"v10" + 12-byte nonce + AES-256-GCM(ciphertext + tag)`, with the AES key kept in
//! `<userData>/Local State` → `os_crypt.encrypted_key` = base64("DPAPI" + DPAPI-protected key).
//! On Windows only the signed-in user can unwrap that key.

const std = @import("std");
const core = @import("core.zig");
const settings = @import("settings.zig");
const Allocator = std.mem.Allocator;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const base64 = std.base64.standard;
const c = if (core.is_windows) core.host.win.c else struct {};

const prefix = "v10";
const key_tag = "DPAPI";
const Key = [Aes.key_length]u8;

var key_mutex: core.Mutex = .{};
var key_cache: ?Key = null;

fn key() !Key {
    key_mutex.lock();
    defer key_mutex.unlock();
    if (key_cache) |k| return k;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const k = try loadOrCreateKey(a, try core.dataPath(a, &.{"Local State"}));
    key_cache = k;
    return k;
}

/// `a` is for scratch memory (an arena).
fn loadOrCreateKey(a: Allocator, file: []const u8) !Key {
    var state: std.json.Value = blk: {
        const text = core.readFileAlloc(a, file, 64 << 20) catch break :blk .null;
        break :blk std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch .null;
    };
    if (encryptedKey(state)) |enc| {
        const raw = decode(a, enc) catch return error.OsCryptKeyNotBase64;
        if (!std.mem.startsWith(u8, raw, key_tag)) return error.UnknownOsCryptKeyFormat;
        const k = try unwrapKey(a, raw[key_tag.len..]);
        if (k.len != @sizeOf(Key)) return error.OsCryptKeyWrongLength;
        return k[0..@sizeOf(Key)].*;
    }
    // first run on this machine: make a key and keep it the way Chromium does
    var k: Key = undefined;
    try core.io.randomSecure(&k);
    const wrapped = try std.mem.concat(a, u8, &.{ key_tag, try wrapKey(a, &k) });
    if (state != .object) state = .{ .object = .empty };
    var os_crypt: std.json.ObjectMap = .empty;
    try os_crypt.put(a, "encrypted_key", .{ .string = try encode(a, wrapped) });
    try state.object.put(a, "os_crypt", .{ .object = os_crypt });
    try core.writeAtomic(file, try core.toJson(a, state));
    return k;
}

/// `state.os_crypt.encrypted_key`, when it is there.
fn encryptedKey(state: std.json.Value) ?[]const u8 {
    if (state != .object) return null;
    const os_crypt = state.object.get("os_crypt") orelse return null;
    if (os_crypt != .object) return null;
    const enc = os_crypt.object.get("encrypted_key") orelse return null;
    return if (enc == .string) enc.string else null;
}

/// Encrypts `plain` (the old `safeStorage.encryptString`).
pub fn seal(a: Allocator, plain: []const u8) ![]u8 {
    return sealWith(a, try key(), plain);
}

fn sealWith(a: Allocator, k: Key, plain: []const u8) ![]u8 {
    const out = try a.alloc(u8, prefix.len + Aes.nonce_length + plain.len + Aes.tag_length);
    @memcpy(out[0..prefix.len], prefix);
    const nonce = out[prefix.len..][0..Aes.nonce_length];
    core.io.random(nonce);
    const body = out[prefix.len + Aes.nonce_length ..];
    Aes.encrypt(body[0..plain.len], body[plain.len..][0..Aes.tag_length], plain, "", nonce.*, k);
    return out;
}

/// Decrypts what `seal` (or the Electron / Tauri build) wrote.
pub fn open(a: Allocator, sealed: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, sealed, prefix)) {
        // very old Chromium wrote bare DPAPI blobs
        return unwrapKey(a, sealed);
    }
    if (sealed.len < prefix.len + Aes.nonce_length + Aes.tag_length) return error.SealedDataTooShort;
    return openWith(a, try key(), sealed);
}

fn openWith(a: Allocator, k: Key, sealed: []const u8) ![]u8 {
    const nonce = sealed[prefix.len..][0..Aes.nonce_length];
    const body = sealed[prefix.len + Aes.nonce_length ..];
    const text = body[0 .. body.len - Aes.tag_length];
    const out = try a.alloc(u8, text.len);
    errdefer a.free(out);
    Aes.decrypt(out, text, body[text.len..][0..Aes.tag_length].*, "", nonce.*, k) catch return error.CouldNotDecrypt;
    return out;
}

/// What to show for an error of `open` / `openStr` (the functions themselves only return its name).
pub fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.CouldNotDecrypt => settings.tr(
            "could not decrypt (was it saved by another Windows user?)",
            "không giải mã được (có phải nó được lưu bởi một người dùng Windows khác?)",
        ),
        error.SealedDataTooShort => "sealed data is too short",
        else => @errorName(e),
    };
}

/// base64 text
pub fn sealStr(a: Allocator, s: []const u8) ![]u8 {
    const sealed = try seal(a, s);
    defer a.free(sealed);
    return encode(a, sealed);
}

pub fn openStr(a: Allocator, b64: []const u8) ![]u8 {
    const sealed = try decode(a, b64);
    defer a.free(sealed);
    const plain = try open(a, sealed);
    if (!std.unicode.utf8ValidateSlice(plain)) {
        a.free(plain);
        return error.InvalidUtf8;
    }
    return plain;
}

fn encode(a: Allocator, bytes: []const u8) ![]u8 {
    const out = try a.alloc(u8, base64.Encoder.calcSize(bytes.len));
    _ = base64.Encoder.encode(out, bytes);
    return out;
}

fn decode(a: Allocator, text: []const u8) ![]u8 {
    const out = try a.alloc(u8, try base64.Decoder.calcSizeForSlice(text));
    errdefer a.free(out);
    try base64.Decoder.decode(out, text);
    return out;
}

// ---------------- key wrapping: DPAPI on Windows ----------------
// (macOS / Linux, in the Rust build: the key as-is in `<userData>/Local State.key`, mode 0600, and
// "file" in its place in `Local State`. Not ported with the rest of the macOS side.)

fn wrapKey(a: Allocator, data: []const u8) ![]u8 {
    return dpapi(a, data, true);
}

fn unwrapKey(a: Allocator, data: []const u8) ![]u8 {
    return dpapi(a, data, false);
}

fn dpapi(a: Allocator, data: []const u8, protect: bool) ![]u8 {
    if (!core.is_windows) return error.Unsupported;
    var input: c.DATA_BLOB = .{ .cbData = @intCast(data.len), .pbData = @constCast(data.ptr) };
    var output = std.mem.zeroes(c.DATA_BLOB);
    const ok = if (protect)
        c.CryptProtectData(&input, null, null, null, null, c.CRYPTPROTECT_UI_FORBIDDEN, &output)
    else
        c.CryptUnprotectData(&input, null, null, null, null, c.CRYPTPROTECT_UI_FORBIDDEN, &output);
    if (ok == 0) return error.DpapiFailed;
    defer _ = c.LocalFree(output.pbData);
    return a.dupe(u8, output.pbData[0..output.cbData]);
}

// ---------------- tests ----------------

const testing = std.testing;

fn testInit() void {
    core.gpa = testing.allocator;
    core.io = testing.io;
}

const test_key: Key = blk: {
    var k: Key = undefined;
    for (&k, 0..) |*b, i| b.* = i;
    break :blk k;
};

test "opens what AES-256-GCM in the v10 format looks like (vector made with Node's crypto)" {
    testInit();
    // key 00..1f, nonce a0..ab, no associated data
    var sealed: [58]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sealed, "763130a0a1a2a3a4a5a6a7a8a9aaabb57d0e5b20b93f915935e6a0740dafac14913bd33f972f8d26a352a9977942f7dc61759aef82b48b601c52");
    const plain = try openWith(testing.allocator, test_key, &sealed);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("Server=.;Password=bí mật", plain);

    // one flipped bit anywhere: refused
    sealed[20] ^= 1;
    try testing.expectError(error.CouldNotDecrypt, openWith(testing.allocator, test_key, &sealed));
}

test "seal / open round trip, as bytes and as base64 text" {
    testInit();
    key_cache = test_key;
    defer key_cache = null;
    const a = testing.allocator;

    const secret = "s3cret \x00\xff bytes";
    const sealed = try seal(a, secret);
    defer a.free(sealed);
    try testing.expectEqualStrings("v10", sealed[0..3]);
    try testing.expectEqual(3 + 12 + secret.len + 16, sealed.len);
    const plain = try open(a, sealed);
    defer a.free(plain);
    try testing.expectEqualStrings(secret, plain);

    // a fresh nonce every time
    const again = try seal(a, secret);
    defer a.free(again);
    try testing.expect(!std.mem.eql(u8, sealed, again));

    const empty = try seal(a, "");
    defer a.free(empty);
    const none = try open(a, empty);
    defer a.free(none);
    try testing.expectEqual(0, none.len);

    const text = try sealStr(a, "mật khẩu");
    defer a.free(text);
    const back = try openStr(a, text);
    defer a.free(back);
    try testing.expectEqualStrings("mật khẩu", back);
    // the vector of the test above, as the text `sealStr` would have written
    const node = try openStr(a, "djEwoKGio6SlpqeoqaqrtX0OWyC5P5FZNeagdA2vrBSRO9M/ly+NJqNSqZd5QvfcYXWa74K0i2AcUg==");
    defer a.free(node);
    try testing.expectEqualStrings("Server=.;Password=bí mật", node);

    try testing.expectError(error.SealedDataTooShort, open(a, "v10 too short"));
    try testing.expectError(error.InvalidCharacter, openStr(a, "not base64!!"));
    const binary = try sealStr(a, "\xff\xfe");
    defer a.free(binary);
    try testing.expectError(error.InvalidUtf8, openStr(a, binary));
    try testing.expectEqualStrings("sealed data is too short", errorText(error.SealedDataTooShort));
}

test "DPAPI wraps and unwraps; a bare DPAPI blob opens" {
    if (!core.is_windows) return error.SkipZigTest;
    testInit();
    const a = testing.allocator;
    const wrapped = try wrapKey(a, &test_key);
    defer a.free(wrapped);
    try testing.expect(!std.mem.eql(u8, wrapped, &test_key));
    const back = try open(a, wrapped);
    defer a.free(back);
    try testing.expectEqualSlices(u8, &test_key, back);
    try testing.expectError(error.DpapiFailed, unwrapKey(a, "not a DPAPI blob"));
}

test "the key is made once, kept in Local State next to what is already there" {
    if (!core.is_windows) return error.SkipZigTest;
    testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const file = try std.fs.path.join(a, &.{ dir, "Local State" });

    try core.writeFile(file, "{\"browser\":{\"enabled\":true}}");
    const first = try loadOrCreateKey(a, file);
    const second = try loadOrCreateKey(a, file);
    try testing.expectEqualSlices(u8, &first, &second);

    const state = try std.json.parseFromSliceLeaky(std.json.Value, a, try core.readFileAlloc(a, file, 1 << 20), .{});
    try testing.expect(state.object.get("browser").?.object.get("enabled").?.bool);
    const raw = try decode(a, encryptedKey(state).?);
    try testing.expectEqualStrings("DPAPI", raw[0..5]);
    try testing.expectEqualSlices(u8, &first, try unwrapKey(a, raw[5..]));

    // a file that is not JSON is replaced; one whose key is damaged is an error, never a new key
    const other = try std.fs.path.join(a, &.{ dir, "Other State" });
    try core.writeFile(other, "garbage");
    _ = try loadOrCreateKey(a, other);
    try testing.expect(encryptedKey(try std.json.parseFromSliceLeaky(std.json.Value, a, try core.readFileAlloc(a, other, 1 << 20), .{})) != null);
    try core.writeFile(other, "{\"os_crypt\":{\"encrypted_key\":\"RFBBUEl4eHg=\"}}");
    try testing.expectError(error.DpapiFailed, loadOrCreateKey(a, other));
    try core.writeFile(other, "{\"os_crypt\":{\"encrypted_key\":\"eHh4eHh4\"}}");
    try testing.expectError(error.UnknownOsCryptKeyFormat, loadOrCreateKey(a, other));
}
