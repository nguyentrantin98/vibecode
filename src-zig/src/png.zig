//! PNG encoding and decoding (screenshots, the capture editor's result).

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

const signature = "\x89PNG\r\n\x1a\n";

/// `rgba`: width*height*4 bytes, rows top to bottom. Returns the PNG file bytes.
pub fn encode(a: Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    if (rgba.len != @as(usize, width) * height * 4) return error.BadSize;
    const row = @as(usize, width) * 4;

    // the picture, zlib-compressed, each row behind its filter byte (0: none)
    var z: std.Io.Writer.Allocating = try .initCapacity(a, 64 + rgba.len / 4);
    defer z.deinit();
    {
        const window = try a.alloc(u8, flate.max_window_len);
        defer a.free(window);
        var comp = try flate.Compress.init(&z.writer, window, .zlib, .level_4);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            try comp.writer.writeByte(0);
            try comp.writer.writeAll(rgba[y * row ..][0..row]);
        }
        try comp.finish();
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(a, z.written().len + 128);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, adaptive filters, not interlaced
    try chunk(w, "IHDR", &ihdr);
    try chunk(w, "IDAT", z.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

pub const Image = struct {
    width: u32,
    height: u32,
    /// width*height*4, rows top to bottom
    rgba: []u8,
};

/// Decodes what browsers and screenshot tools write: 8-bit RGB or RGBA, not interlaced.
pub fn decode(a: Allocator, png: []const u8) !Image {
    if (png.len < 8 or !std.mem.eql(u8, png[0..8], signature)) return error.NotPng;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(a);
    var i: usize = 8;
    while (i + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        const kind = png[i + 4 ..][0..4];
        if (i + 12 + len > png.len) return error.Truncated;
        const data = png[i + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Truncated;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[12] != 0) return error.Unsupported;
            channels = switch (data[9]) {
                2 => 3,
                6 => 4,
                else => return error.Unsupported,
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
        i += 12 + len;
    }
    if (width == 0 or height == 0 or channels == 0) return error.NotPng;

    const stride = @as(usize, width) * channels;
    const raw = try a.alloc(u8, (stride + 1) * height);
    defer a.free(raw);
    {
        var in: std.Io.Reader = .fixed(idat.items);
        const window = try a.alloc(u8, flate.max_window_len);
        defer a.free(window);
        var dec = flate.Decompress.init(&in, .zlib, window);
        try dec.reader.readSliceAll(raw);
    }

    const rgba = try a.alloc(u8, @as(usize, width) * height * 4);
    errdefer a.free(rgba);
    var prev: ?[]u8 = null;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const cur = line[1..];
        try unfilter(line[0], cur, prev, channels);
        const dst = rgba[y * width * 4 ..][0 .. @as(usize, width) * 4];
        if (channels == 4) {
            @memcpy(dst, cur);
        } else {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                dst[x * 4 ..][0..3].* = cur[x * 3 ..][0..3].*;
                dst[x * 4 + 3] = 255;
            }
        }
        prev = cur;
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn unfilter(kind: u8, cur: []u8, prev: ?[]const u8, bpp: usize) !void {
    for (cur, 0..) |*b, x| {
        const left: u8 = if (x >= bpp) cur[x - bpp] else 0;
        const up: u8 = if (prev) |p| p[x] else 0;
        const up_left: u8 = if (prev != null and x >= bpp) prev.?[x - bpp] else 0;
        b.* +%= switch (kind) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, up_left),
            else => return error.BadFilter,
        };
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

test "encode then decode" {
    const a = std.testing.allocator;
    var px: [5 * 3 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    const file = try encode(a, &px, 5, 3);
    defer a.free(file);
    const img = try decode(a, file);
    defer a.free(img.rgba);
    try std.testing.expectEqual(@as(u32, 5), img.width);
    try std.testing.expectEqual(@as(u32, 3), img.height);
    try std.testing.expectEqualSlices(u8, &px, img.rgba);
}

test "decode filtered RGB" {
    // 2x2 RGB, rows filtered Sub (1) and Up (2)
    const a = std.testing.allocator;
    const rows = [_]u8{ 1, 10, 20, 30, 5, 5, 5 } ++ [_]u8{ 2, 1, 2, 3, 4, 5, 6 };
    var z: std.Io.Writer.Allocating = try .initCapacity(a, 64);
    defer z.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    var comp = try flate.Compress.init(&z.writer, window, .zlib, .level_4);
    try comp.writer.writeAll(&rows);
    try comp.finish();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll(signature);
    try chunk(&out.writer, "IHDR", &[_]u8{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 });
    try chunk(&out.writer, "IDAT", z.written());
    try chunk(&out.writer, "IEND", "");
    const img = try decode(a, out.written());
    defer a.free(img.rgba);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 255, 15, 25, 35, 255, 11, 22, 33, 255, 19, 30, 41, 255 }, img.rgba);
}
