//! Build-time: packs the built pages (a folder) into `<out>/assets.bin` + `<out>/assets.zig`,
//! which the app embeds: `assets.get("/index.html")`.
//!
//!     gen_assets <renderer folder> <out folder>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const src_path = args[1];
    const out_path = args[2];

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);

    var blob: std.ArrayList(u8) = .empty;
    var index: std.ArrayList(u8) = .empty;
    try index.appendSlice(a,
        \\const std = @import("std");
        \\pub const File = struct { body: []const u8, mime: []const u8 };
        \\const blob = @embedFile("assets.bin");
        \\pub fn get(path: []const u8) ?File {
        \\    const e = map.get(path) orelse return null;
        \\    return .{ .body = blob[e[0]..][0..e[1]], .mime = e[2] };
        \\}
        \\const map = std.StaticStringMap(struct { usize, usize, []const u8 }).initComptime(.{
        \\
    );

    if (std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        var files: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            try files.append(a, try std.mem.replaceOwned(u8, a, e.path, "\\", "/"));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (files.items) |rel| {
            const bytes = try dir.readFileAlloc(io, rel, a, .unlimited);
            const off = blob.items.len;
            try blob.appendSlice(a, bytes);
            try index.print(a, "    .{{ \"/{s}\", .{{ {d}, {d}, \"{s}\" }} }},\n", .{ rel, off, bytes.len, mime(rel) });
        }
    } else |_| {
        std.log.warn("{s} not found: run `npm run build:web` (the app will show no page)", .{src_path});
    }
    try index.appendSlice(a, "});\n");
    try out_dir.writeFile(io, .{ .sub_path = "assets.bin", .data = blob.items });
    try out_dir.writeFile(io, .{ .sub_path = "assets.zig", .data = index.items });
}

fn mime(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".wasm", "application/wasm" },
        .{ ".map", "application/json" },
        .{ ".txt", "text/plain; charset=utf-8" },
    };
    inline for (table) |t| if (std.mem.eql(u8, ext, t[0])) return t[1];
    return "application/octet-stream";
}
