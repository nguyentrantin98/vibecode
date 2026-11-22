//! Recursive folder watching (ReadDirectoryChangesW on Windows), with the changes delivered in
//! debounced batches on a thread of the watcher's own.
//!
//!     const w = try watch.start(&.{root}, .{ .debounce_ms = 200 }, onChanges, null);
//!     …
//!     w.stop();

const std = @import("std");
const core = @import("core.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    create,
    remove,
    modify,
    /// renamed: one event for the old path, one for the new
    rename,
    /// changes were lost (too many at once): `path` is the watched root, re-read everything
    rescan,
};

pub const Event = struct {
    kind: Kind,
    /// absolute path
    path: []const u8,
};

pub const Options = struct {
    /// a batch is delivered this long after its first change
    debounce_ms: u32 = 200,
};

/// Called on the watcher's thread; `events` are only valid during the call.
pub const Callback = *const fn (ctx: ?*anyopaque, events: []const Event) void;

pub const Watcher = struct {
    arena: std.heap.ArenaAllocator,
    roots: []Root,
    opts: Options,
    cb: Callback,
    ctx: ?*anyopaque,
    mutex: core.Mutex = .{},
    cond: std.Io.Condition = .init,
    /// changes waiting for the next batch (paths owned by `pending_arena`)
    pending: std.ArrayList(Event) = .empty,
    pending_arena: std.heap.ArenaAllocator,
    stopping: bool = false,
    flusher: ?std.Thread = null,

    const Root = struct {
        path: []const u8,
        handle: if (core.is_windows) win.HANDLE else void,
        thread: ?std.Thread = null,
    };

    /// Stops watching and waits for the last callback to return. Do not call from the callback.
    pub fn stop(w: *Watcher) void {
        w.mutex.lock();
        w.stopping = true;
        w.cond.broadcast(core.io);
        w.mutex.unlock();
        if (core.is_windows) {
            for (w.roots) |*r| _ = win.CancelIoEx(r.handle, null);
        }
        for (w.roots) |*r| if (r.thread) |t| t.join();
        if (w.flusher) |t| t.join();
        if (core.is_windows) {
            for (w.roots) |*r| _ = win.CloseHandle(r.handle);
        }
        w.pending.deinit(core.gpa);
        w.pending_arena.deinit();
        var arena = w.arena;
        arena.deinit();
    }

    fn push(w: *Watcher, kind: Kind, path: []const u8) void {
        w.mutex.lock();
        defer w.mutex.unlock();
        if (w.stopping) return;
        const p = w.pending_arena.allocator().dupe(u8, path) catch return;
        w.pending.append(core.gpa, .{ .kind = kind, .path = p }) catch return;
        w.cond.signal(core.io);
    }

    fn flushLoop(w: *Watcher) void {
        while (true) {
            w.mutex.lock();
            while (w.pending.items.len == 0 and !w.stopping) w.cond.waitUncancelable(core.io, &w.mutex.m);
            if (w.stopping) {
                w.mutex.unlock();
                return;
            }
            w.mutex.unlock();
            core.sleepMs(w.opts.debounce_ms);
            w.mutex.lock();
            var batch = w.pending;
            var batch_arena = w.pending_arena;
            w.pending = .empty;
            w.pending_arena = .init(core.gpa);
            const stopping = w.stopping;
            w.mutex.unlock();
            if (!stopping) w.cb(w.ctx, batch.items);
            batch.deinit(core.gpa);
            batch_arena.deinit();
            if (stopping) return;
        }
    }
};

/// Watches every folder of `roots` and everything below. A root that cannot be opened is an
/// error unless another one opened (then it is skipped).
pub fn start(roots: []const []const u8, opts: Options, cb: Callback, ctx: ?*anyopaque) !*Watcher {
    if (!core.is_windows) return error.Unsupported;
    var arena: std.heap.ArenaAllocator = .init(core.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const w = try a.create(Watcher);
    var list: std.ArrayList(Watcher.Root) = .empty;
    for (roots) |root| {
        const wpath = try core.wide(a, root);
        const h = win.CreateFileW(wpath, win.FILE_LIST_DIRECTORY, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, null);
        if (h == win.INVALID_HANDLE_VALUE) continue;
        try list.append(a, .{ .path = try a.dupe(u8, root), .handle = h });
    }
    if (list.items.len == 0) return error.FileNotFound;
    w.* = .{ .arena = arena, .roots = list.items, .opts = opts, .cb = cb, .ctx = ctx, .pending_arena = .init(core.gpa) };
    w.flusher = try std.Thread.spawn(.{}, Watcher.flushLoop, .{w});
    for (w.roots) |*r| r.thread = std.Thread.spawn(.{}, readLoop, .{ w, r }) catch null;
    return w;
}

const win = if (core.is_windows) @import("win") else struct {};

fn readLoop(w: *Watcher, r: *Watcher.Root) void {
    const buf = core.gpa.alignedAlloc(u8, .of(win.FILE_NOTIFY_INFORMATION), 256 * 1024) catch return;
    defer core.gpa.free(buf);
    const filter: win.DWORD = win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE | win.FILE_NOTIFY_CHANGE_CREATION;
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(core.gpa);
    while (true) {
        var got: win.DWORD = 0;
        const ok = win.ReadDirectoryChangesW(r.handle, buf.ptr, @intCast(buf.len), 1, filter, &got, null, null);
        if (w.stopping) return;
        if (ok == 0) {
            // the folder went away, or the watch was cancelled
            if (win.GetLastError() == win.ERROR_NOTIFY_ENUM_DIR) {
                w.push(.rescan, r.path);
                continue;
            }
            return;
        }
        if (got == 0) {
            // more changes than the buffer holds
            w.push(.rescan, r.path);
            continue;
        }
        var off: usize = 0;
        while (true) {
            const info: *const win.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(buf.ptr + off));
            const name_ptr: [*]const u16 = @ptrCast(@alignCast(buf.ptr + off + @offsetOf(win.FILE_NOTIFY_INFORMATION, "FileName")));
            const name = name_ptr[0 .. info.FileNameLength / 2];
            path_buf.clearRetainingCapacity();
            path_buf.appendSlice(core.gpa, r.path) catch return;
            if (r.path.len > 0 and r.path[r.path.len - 1] != '\\' and r.path[r.path.len - 1] != '/') path_buf.append(core.gpa, '\\') catch return;
            path_buf.ensureUnusedCapacity(core.gpa, name.len * 3) catch return;
            path_buf.items.len += std.unicode.wtf16LeToWtf8(path_buf.unusedCapacitySlice(), name);
            const kind: Kind = switch (info.Action) {
                win.FILE_ACTION_ADDED => .create,
                win.FILE_ACTION_REMOVED => .remove,
                win.FILE_ACTION_RENAMED_OLD_NAME, win.FILE_ACTION_RENAMED_NEW_NAME => .rename,
                else => .modify,
            };
            w.push(kind, path_buf.items);
            if (info.NextEntryOffset == 0) break;
            off += info.NextEntryOffset;
        }
    }
}

test "watch sees a new file" {
    if (!core.is_windows) return error.SkipZigTest;
    const T = struct {
        var seen: std.atomic.Value(bool) = .init(false);
        fn cb(_: ?*anyopaque, events: []const Event) void {
            for (events) |e| if (std.mem.endsWith(u8, e.path, "hello.txt")) seen.store(true, .release);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    core.gpa = std.testing.allocator;
    core.io = std.testing.io;
    const w = try start(&.{buf[0..n]}, .{ .debounce_ms = 20 }, T.cb, null);
    core.sleepMs(150); // changes are recorded from the first read on
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hi" });
    var i: usize = 0;
    while (i < 100 and !T.seen.load(.acquire)) : (i += 1) core.sleepMs(20);
    w.stop();
    try std.testing.expect(T.seen.load(.acquire));
}
