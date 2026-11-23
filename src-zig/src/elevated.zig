//! Runs one of the app's PowerShell scripts as administrator (one UAC prompt) and reads back the
//! JSON it writes to the `-Out` file it is given. For the few things that need admin: the ASUS fan
//! (thermal.zig) and installing the equalizer APO (audio.zig).

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const host = @import("host.zig");
const tr = @import("settings.zig").tr;

var counter: std.atomic.Value(u32) = .init(0);

/// `script` is a path; `args` are appended to the PowerShell command line as they are (quote
/// paths). Returns the parsed `-Out` JSON, or fails the call with a readable message.
pub fn run(c: *ipc.Call, comptime T: type, script: []const u8, args: []const u8, timeout_ms: u32) !T {
    if (!core.is_windows) return error.Unsupported;
    const w = host.win.c;
    const ar = c.arena;
    const out = try std.fmt.allocPrint(ar, "{s}\\vibe-elevated-{d}-{d}.json", .{ core.tempDir(), w.GetCurrentProcessId(), counter.fetchAdd(1, .monotonic) });
    const params = try std.fmt.allocPrint(ar, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{s}\" {s} -Out \"{s}\"", .{ script, args, out });

    var info = std.mem.zeroes(w.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(w.SHELLEXECUTEINFOW);
    info.fMask = w.SEE_MASK_NOCLOSEPROCESS | w.SEE_MASK_NOASYNC;
    info.lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    info.lpFile = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
    info.lpParameters = (try core.wide(ar, params)).ptr;
    info.nShow = w.SW_HIDE;
    if (w.ShellExecuteExW(&info) == 0) {
        const err = w.GetLastError();
        if (err == 1223) return c.failMsg(tr("Admin permission was declined", "Đã từ chối quyền quản trị"));
        return c.fail("{s} (error {d})", .{ tr("Could not start PowerShell", "Không chạy được PowerShell"), err });
    }
    if (info.hProcess) |p| {
        defer _ = w.CloseHandle(p);
        if (w.WaitForSingleObject(p, timeout_ms) != 0) return c.failMsg(tr("It took too long", "Chạy quá lâu"));
    }
    defer std.Io.Dir.cwd().deleteFile(core.io, out) catch {};
    const no_answer = tr("The admin step gave no answer", "Bước quản trị không trả kết quả");
    const raw = core.readFileAlloc(ar, out, 1 << 20) catch return c.failMsg(no_answer);
    const body = if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
    return core.fromJson(T, ar, body) catch c.failMsg(no_answer);
}
