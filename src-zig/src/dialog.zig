//! Native file dialogs over the main window. Call from a command (worker thread): each one
//! blocks until the user answers. Paths are allocated in `a`.

const std = @import("std");
const core = @import("core.zig");
const host = @import("host.zig");
const Allocator = std.mem.Allocator;

pub const Filter = struct {
    /// "Images"
    name: []const u8,
    /// without the dot: "png", "jpg"
    extensions: []const []const u8,
};

pub const Options = struct {
    title: ?[]const u8 = null,
    /// folder the dialog opens in
    default_path: ?[]const u8 = null,
    /// file name proposed by a save dialog
    default_name: ?[]const u8 = null,
    filters: []const Filter = &.{},
};

/// null = cancelled
pub fn pickFolder(a: Allocator, o: Options) !?[]u8 {
    const r = try run(a, o, .folder);
    return if (r.len > 0) r[0] else null;
}

pub fn pickFile(a: Allocator, o: Options) !?[]u8 {
    const r = try run(a, o, .file);
    return if (r.len > 0) r[0] else null;
}

/// empty = cancelled
pub fn pickFiles(a: Allocator, o: Options) ![]const []u8 {
    return run(a, o, .files);
}

pub fn saveFile(a: Allocator, o: Options) !?[]u8 {
    const r = try run(a, o, .save);
    return if (r.len > 0) r[0] else null;
}

const Kind = enum { folder, file, files, save };

const run = if (core.is_windows) runWindows else runUnsupported;

fn runUnsupported(a: Allocator, o: Options, kind: Kind) ![]const []u8 {
    _ = .{ a, o, kind };
    return error.Unsupported;
}

const guid = struct {
    const c = host.win.c;
    const CLSID_FileOpenDialog: c.GUID = .{ .Data1 = 0xDC1C5A9C, .Data2 = 0xE88A, .Data3 = 0x4DDE, .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
    const CLSID_FileSaveDialog: c.GUID = .{ .Data1 = 0xC0B4E2F3, .Data2 = 0xBA21, .Data3 = 0x4773, .Data4 = .{ 0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B } };
    const IID_IFileOpenDialog: c.GUID = .{ .Data1 = 0xD57C7288, .Data2 = 0xD4AD, .Data3 = 0x4768, .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
    const IID_IFileSaveDialog: c.GUID = .{ .Data1 = 0x84BCCD23, .Data2 = 0x5FDE, .Data3 = 0x4CDB, .Data4 = .{ 0xAE, 0xA4, 0xAF, 0x64, 0xB8, 0x3D, 0x78, 0xAB } };
    const IID_IShellItem: c.GUID = .{ .Data1 = 0x43826D1E, .Data2 = 0xE718, .Data3 = 0x42EE, .Data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };
};

fn runWindows(a: Allocator, o: Options, kind: Kind) ![]const []u8 {
    const c = host.win.c;
    const com = host.win.com;

    // the dialog lives on this (worker) thread, in its own apartment
    const inited = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE) >= 0;
    defer if (inited) c.CoUninitialize();

    // IFileOpenDialog and IFileSaveDialog both start with IFileDialog's methods
    var raw: ?*anyopaque = null;
    if (kind == .save) {
        try com.check(c.CoCreateInstance(&guid.CLSID_FileSaveDialog, null, c.CLSCTX_INPROC_SERVER, &guid.IID_IFileSaveDialog, &raw));
    } else {
        try com.check(c.CoCreateInstance(&guid.CLSID_FileOpenDialog, null, c.CLSCTX_INPROC_SERVER, &guid.IID_IFileOpenDialog, &raw));
    }
    const d: *c.IFileOpenDialog = @ptrCast(@alignCast(raw.?));
    defer com.release(@as(?*c.IFileOpenDialog, d));

    var flags: c.DWORD = 0;
    _ = com.call(d, "GetOptions", .{&flags});
    flags |= c.FOS_FORCEFILESYSTEM;
    if (kind == .folder) flags |= c.FOS_PICKFOLDERS;
    if (kind == .files) flags |= c.FOS_ALLOWMULTISELECT;
    _ = com.call(d, "SetOptions", .{flags});

    if (o.title) |t| _ = com.call(d, "SetTitle", .{(try core.wide(a, t)).ptr});
    if (o.default_name) |n| _ = com.call(d, "SetFileName", .{(try core.wide(a, n)).ptr});
    if (o.default_path) |p| if (p.len > 0) {
        var item: ?*anyopaque = null;
        if (c.SHCreateItemFromParsingName((try core.wide(a, p)).ptr, null, &guid.IID_IShellItem, &item) >= 0) {
            const si: *c.IShellItem = @ptrCast(@alignCast(item.?));
            _ = com.call(d, "SetFolder", .{si});
            com.release(@as(?*c.IShellItem, si));
        }
    };
    if (o.filters.len > 0) {
        const specs = try a.alloc(c.COMDLG_FILTERSPEC, o.filters.len);
        for (o.filters, specs) |f, *s| {
            var pattern: std.ArrayList(u8) = .empty;
            for (f.extensions, 0..) |e, i| {
                if (i > 0) try pattern.append(a, ';');
                try pattern.print(a, "*.{s}", .{e});
            }
            s.* = .{ .pszName = (try core.wide(a, f.name)).ptr, .pszSpec = (try core.wide(a, pattern.items)).ptr };
        }
        _ = com.call(d, "SetFileTypes", .{ @as(c.UINT, @intCast(specs.len)), specs.ptr });
        // a save dialog adds the first filter's extension when the name has none
        if (o.filters[0].extensions.len > 0) _ = com.call(d, "SetDefaultExtension", .{(try core.wide(a, o.filters[0].extensions[0])).ptr});
    }

    const owner: c.HWND = host.onUiSync(mainHwnd, .{});
    if (com.call(d, "Show", .{owner}) < 0) return &.{}; // cancelled

    var out: std.ArrayList([]u8) = .empty;
    if (kind == .files) {
        var items: ?*c.IShellItemArray = null;
        try com.check(com.call(d, "GetResults", .{&items}));
        const arr = items orelse return &.{};
        defer com.release(@as(?*c.IShellItemArray, arr));
        var n: c.DWORD = 0;
        _ = com.call(arr, "GetCount", .{&n});
        var i: c.DWORD = 0;
        while (i < n) : (i += 1) {
            var si: ?*c.IShellItem = null;
            if (com.call(arr, "GetItemAt", .{ i, &si }) < 0) continue;
            defer com.release(si);
            if (try itemPath(a, si.?)) |p| try out.append(a, p);
        }
    } else {
        var si: ?*c.IShellItem = null;
        try com.check(com.call(d, "GetResult", .{&si}));
        defer com.release(si);
        if (si) |s| if (try itemPath(a, s)) |p| try out.append(a, p);
    }
    return out.items;
}

fn mainHwnd() host.win.c.HWND {
    return if (host.win.findWindow(host.main_label)) |w| w.hwnd else null;
}

fn itemPath(a: Allocator, si: *host.win.c.IShellItem) !?[]u8 {
    const c = host.win.c;
    var name: c.LPWSTR = null;
    if (host.win.com.call(si, "GetDisplayName", .{ c.SIGDN_FILESYSPATH, &name }) < 0 or name == null) return null;
    return try host.win.com.takeString(a, name);
}

test {
    _ = &pickFolder;
    _ = &pickFile;
    _ = &pickFiles;
    _ = &saveFile;
}
