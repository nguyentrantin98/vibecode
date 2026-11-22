//! Git through the `git` CLI (the user's own config, credentials and hooks apply).

const std = @import("std");
const core = @import("core.zig");
const ipc = @import("ipc.zig");
const settings = @import("settings.zig");
const Allocator = std.mem.Allocator;

pub const commands = .{
    .{ "git_state", git_state },
    .{ "git_original", git_original },
    .{ "git_init", git_init },
    .{ "git_show", git_show },
    .{ "git_log", git_log },
    .{ "git_commit_files", git_commit_files },
    .{ "git_branches", git_branches },
    .{ "git_checkout", git_checkout },
    .{ "git_discard", git_discard },
    .{ "git_stage", git_stage },
    .{ "git_commit", git_commit },
    .{ "git_push", git_push },
    .{ "git_pull", git_pull },
};

const whitespace = " \t\r\n\x0b\x0c";

/// What `git <args>` printed, run in `cwd`; fails with git's own explanation.
fn git(c: *ipc.Call, cwd: []const u8, args: []const []const u8) ![]const u8 {
    return gitEnv(c, cwd, args, core.env);
}

fn gitEnv(c: *ipc.Call, cwd: []const u8, args: []const []const u8, env: *const std.process.Environ.Map) ![]const u8 {
    const argv = try std.mem.concat(c.arena, []const u8, &.{ &.{"git"}, args });
    const out = try core.run(c.arena, argv, .{ .cwd = cwd, .env_map = env });
    if (!out.ok()) return c.failMsg(try lossy(c.arena, failure(out)));
    return lossy(c.arena, out.stdout);
}

/// Git's explanation of a failed command (some, like "nothing to commit", go to stdout).
fn failure(out: core.RunResult) []const u8 {
    const stderr = std.mem.trim(u8, out.stderr, whitespace);
    return if (stderr.len == 0) std.mem.trim(u8, out.stdout, whitespace) else stderr;
}

/// `s` as UTF-8, invalid bytes replaced with U+FFFD (a file in another encoding, an odd path).
fn lossy(a: Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    return std.fmt.allocPrint(a, "{f}", .{std.unicode.fmtUtf8(s)});
}

/// One of several git commands that run side by side.
const Side = struct {
    cwd: []const u8,
    args: []const []const u8,
    /// what it printed, null when it failed; allocated with `core.gpa` (the call's arena is not
    /// for several threads)
    out: ?[]u8 = null,

    fn run(s: *Side) void {
        var argv: [12][]const u8 = undefined;
        argv[0] = "git";
        @memcpy(argv[1..][0..s.args.len], s.args);
        const r = core.run(core.gpa, argv[0 .. s.args.len + 1], .{ .cwd = s.cwd, .env_map = core.env }) catch return;
        core.gpa.free(r.stderr);
        if (r.ok()) s.out = r.stdout else core.gpa.free(r.stdout);
    }
};

/// Runs the commands at the same time; what each printed, "" for one that failed.
fn gitAll(c: *ipc.Call, cwd: []const u8, comptime n: usize, cmds: [n][]const []const u8) ![n][]const u8 {
    var sides: [n]Side = undefined;
    var threads: [n]?std.Thread = @splat(null);
    for (&sides, cmds) |*s, args| s.* = .{ .cwd = cwd, .args = args };
    // the last one on this thread (and any whose thread could not start)
    for (sides[0 .. n - 1], threads[0 .. n - 1]) |*s, *t| t.* = std.Thread.spawn(.{}, Side.run, .{s}) catch null;
    for (&sides, threads) |*s, t| if (t == null) s.run();
    for (threads) |t| if (t) |th| th.join();
    defer for (sides) |s| if (s.out) |o| core.gpa.free(o);
    var outs: [n][]const u8 = undefined;
    for (&outs, sides) |*o, s| o.* = if (s.out) |text| try c.arena.dupe(u8, try lossy(c.arena, text)) else "";
    return outs;
}

const GitFile = struct {
    rel: []const u8,
    abs: []const u8,
    status: []const u8,
    staged: bool,
    added: u32,
    deleted: u32,
};

const GitState = struct {
    isRepo: bool,
    root: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    files: []const GitFile = &.{},
    /// the branch it pushes to / pulls from (e.g. `origin/master`), and how far apart they are
    /// as of the last fetch
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// any remote at all (a branch without upstream can still be published)
    hasRemote: bool = false,
};

const Header = struct { upstream: ?[]const u8 = null, ahead: u32 = 0, behind: u32 = 0 };

/// `## master...origin/master [ahead 1, behind 2]` → (upstream, ahead, behind).
fn branchHeader(h: []const u8) Header {
    _, const rest = std.mem.cut(u8, h, "...") orelse return .{};
    const up, const counts = std.mem.cut(u8, rest, " [") orelse .{ rest, "" };
    return .{ .upstream = up, .ahead = headerCount(counts, "ahead"), .behind = headerCount(counts, "behind") };
}

fn headerCount(counts: []const u8, word: []const u8) u32 {
    var parts = std.mem.splitSequence(u8, counts, ", ");
    while (parts.next()) |p| {
        const n = std.mem.cutPrefix(u8, std.mem.trimEnd(u8, p, "]"), word) orelse continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, n, whitespace), 10) catch continue;
    }
    return 0;
}

const Stat = struct { added: u32 = 0, deleted: u32 = 0 };
const Stats = std.StringHashMapUnmanaged(Stat);

/// `added\tdeleted\tpath` records of `--numstat -z` → path → (added, deleted), summed.
fn numstats(a: Allocator, outs: []const []const u8) !Stats {
    var stats: Stats = .empty;
    for (outs) |out| {
        var recs = std.mem.splitScalar(u8, out, 0);
        while (recs.next()) |rec| {
            var it = std.mem.splitScalar(u8, rec, '\t');
            const added = it.next() orelse continue;
            const deleted = it.next() orelse continue;
            const path = it.rest();
            if (path.len == 0) continue;
            const e = try stats.getOrPutValue(a, path, .{});
            // "-" for a binary file
            e.value_ptr.added += std.fmt.parseInt(u32, added, 10) catch 0;
            e.value_ptr.deleted += std.fmt.parseInt(u32, deleted, 10) catch 0;
        }
    }
    return stats;
}

const Status = struct { header: Header, files: []GitFile };

/// The records of `status --porcelain=v1 --branch -z`.
fn parseStatus(a: Allocator, root: []const u8, status: []const u8, stats: Stats) !Status {
    var files: std.ArrayList(GitFile) = .empty;
    var recs = std.mem.splitScalar(u8, status, 0);
    var header: Header = .{};
    if (recs.peek()) |h| if (std.mem.startsWith(u8, h, "## ")) {
        header = branchHeader(h);
        _ = recs.next();
    };
    while (recs.next()) |rec| {
        if (rec.len < 4) continue;
        const x = rec[0];
        const y = rec[1];
        const rel = rec[3..];
        if (x == 'R' or x == 'C') _ = recs.next(); // the original path
        const st: []const u8 = if (x == '?' and y == '?')
            "?"
        else if (x == 'U' or y == 'U')
            "U"
        else if (x == 'D' or y == 'D')
            "D"
        else if (x == 'A')
            "A"
        else if (x == 'R')
            "R"
        else
            "M";
        const stat: Stat = stats.get(rel) orelse .{};
        try files.append(a, .{
            .abs = try std.fs.path.join(a, &.{ root, rel }),
            .rel = rel,
            .status = st,
            .staged = x != ' ' and x != '?',
            .added = stat.added,
            .deleted = stat.deleted,
        });
    }
    std.mem.sort(GitFile, files.items, {}, struct {
        fn lessThan(_: void, l: GitFile, r: GitFile) bool {
            return std.mem.lessThan(u8, l.rel, r.rel);
        }
    }.lessThan);
    return .{ .header = header, .files = files.items };
}

fn git_state(c: *ipc.Call, a: struct { folder: []const u8 }) !GitState {
    const top = git(c, a.folder, &.{ "rev-parse", "--show-toplevel" }) catch return .{ .isRepo = false };
    const root = std.mem.trim(u8, top, whitespace);
    const outs = try gitAll(c, root, 4, .{
        &.{ "branch", "--show-current" },
        // no index refresh: that write fires the watcher, which runs yet another status
        &.{ "--no-optional-locks", "status", "--porcelain=v1", "--branch", "-z", "-uall" },
        &.{ "diff", "--numstat", "-z" },
        &.{ "diff", "--numstat", "--cached", "-z" },
    });
    const stats = try numstats(c.arena, outs[2..4]);
    const status = try parseStatus(c.arena, root, outs[1], stats);
    const branch = std.mem.trim(u8, outs[0], whitespace);
    const has_remote = status.header.upstream != null or blk: {
        const remotes = git(c, root, &.{"remote"}) catch break :blk false;
        break :blk std.mem.trim(u8, remotes, whitespace).len > 0;
    };
    return .{
        .isRepo = true,
        .root = root,
        .branch = if (branch.len > 0) branch else "HEAD",
        .files = status.files,
        .upstream = status.header.upstream,
        .ahead = status.header.ahead,
        .behind = status.header.behind,
        .hasRemote = has_remote,
    };
}

/// Push / pull: never wait on a password prompt in a terminal nobody sees (the credential
/// manager's own window still works).
fn gitRemote(c: *ipc.Call, cwd: []const u8, args: []const []const u8) !void {
    var env = try core.env.clone(c.arena);
    try env.put("GIT_TERMINAL_PROMPT", "0");
    _ = try gitEnv(c, cwd, args, &env);
}

/// Stage (`git add`) or unstage files.
fn git_stage(c: *ipc.Call, a: struct { root: []const u8, rels: []const []const u8, stage: bool }) !void {
    const tail = try std.mem.concat(c.arena, []const u8, &.{ &.{"--"}, a.rels });
    if (a.stage) {
        _ = try git(c, a.root, try std.mem.concat(c.arena, []const u8, &.{ &.{ "add", "-A" }, tail }));
        return;
    }
    // before the first commit there is no HEAD to restore the index from
    if (git(c, a.root, try std.mem.concat(c.arena, []const u8, &.{ &.{ "restore", "--staged" }, tail }))) |_| {} else |_| {
        _ = try git(c, a.root, try std.mem.concat(c.arena, []const u8, &.{ &.{ "rm", "--cached", "-r", "-q" }, tail }));
    }
}

/// Commit what is staged; with nothing staged, every change (like `git commit -a`, new files too).
fn git_commit(c: *ipc.Call, a: struct { root: []const u8, message: []const u8 }) !void {
    // exits 1 when something is staged
    if (git(c, a.root, &.{ "diff", "--cached", "--quiet" })) |_| {
        _ = try git(c, a.root, &.{ "add", "-A" });
    } else |_| {}
    _ = try git(c, a.root, &.{ "commit", "-m", a.message });
}

/// Push; a branch without upstream is published to `origin` (or the only remote) and tracks it.
fn git_push(c: *ipc.Call, a: struct { root: []const u8 }) !void {
    if (git(c, a.root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })) |_| {
        return gitRemote(c, a.root, &.{"push"});
    } else |_| {}
    const remotes = try git(c, a.root, &.{"remote"});
    var first: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, remotes, "\r\n");
    const remote = while (lines.next()) |r| {
        if (std.mem.eql(u8, r, "origin")) break r;
        if (first == null) first = r;
    } else first orelse
        return c.failMsg(settings.tr("This repository has no remote to push to.", "Repository này không có remote để push lên."));
    return gitRemote(c, a.root, &.{ "push", "-u", remote, "HEAD" });
}

/// Pull, fast-forward only: never makes a merge commit or touches local work; git explains when
/// the branches have diverged.
fn git_pull(c: *ipc.Call, a: struct { root: []const u8 }) !void {
    return gitRemote(c, a.root, &.{ "pull", "--ff-only", "--no-rebase" });
}

/// File content at HEAD; '' when it does not exist there.
fn git_original(c: *ipc.Call, a: struct { root: []const u8, rel: []const u8 }) ![]const u8 {
    return git_show(c, .{ .root = a.root, .rev = "HEAD", .rel = a.rel });
}

fn git_init(c: *ipc.Call, a: struct { folder: []const u8 }) !void {
    _ = try git(c, a.folder, &.{"init"});
}

fn git_show(c: *ipc.Call, a: struct { root: []const u8, rev: []const u8, rel: []const u8 }) ![]const u8 {
    const spec = try std.fmt.allocPrint(c.arena, "{s}:{s}", .{ a.rev, a.rel });
    return git(c, a.root, &.{ "show", spec }) catch "";
}

const GitCommit = struct {
    hash: []const u8,
    short: []const u8,
    author: []const u8,
    date: u64,
    subject: []const u8,
};

fn git_log(c: *ipc.Call, a: struct { root: []const u8 }) ![]const GitCommit {
    const out = git(c, a.root, &.{ "log", "-n200", "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s%x1e" }) catch return &.{};
    return parseLog(c.arena, out);
}

/// Records end with 0x1e, fields are split by 0x1f: hash, short hash, author, Unix time, subject.
fn parseLog(a: Allocator, out: []const u8) ![]const GitCommit {
    var list: std.ArrayList(GitCommit) = .empty;
    var recs = std.mem.splitScalar(u8, out, 0x1e);
    while (recs.next()) |rec| {
        var f = std.mem.splitScalar(u8, std.mem.trimStart(u8, rec, whitespace), 0x1f);
        const hash = f.next() orelse continue;
        const short = f.next() orelse continue;
        if (hash.len == 0 or short.len == 0) continue;
        const author = f.next() orelse "";
        const date = if (f.next()) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        try list.append(a, .{ .hash = hash, .short = short, .author = author, .date = date * 1000, .subject = f.next() orelse "" });
    }
    return list.items;
}

const GitCommitFile = struct {
    rel: []const u8,
    status: []const u8,
    added: u32,
    deleted: u32,
};

fn git_commit_files(c: *ipc.Call, a: struct { root: []const u8, hash: []const u8 }) ![]const GitCommitFile {
    const outs = try gitAll(c, a.root, 2, .{
        &.{ "diff-tree", "--root", "--no-commit-id", "-r", "--no-renames", "-z", "--name-status", a.hash },
        &.{ "diff-tree", "--root", "--no-commit-id", "-r", "--no-renames", "-z", "--numstat", a.hash },
    });
    return parseCommitFiles(c.arena, outs[0], try numstats(c.arena, outs[1..2]));
}

/// `status\0path\0` pairs of `diff-tree --name-status -z`.
fn parseCommitFiles(a: Allocator, names: []const u8, stats: Stats) ![]const GitCommitFile {
    var list: std.ArrayList(GitCommitFile) = .empty;
    var parts = std.mem.splitScalar(u8, names, 0);
    while (parts.next()) |code| {
        const rel = parts.next() orelse break;
        if (code.len == 0 or rel.len == 0) continue;
        const st: []const u8 = switch (code[0]) {
            'A' => "A",
            'D' => "D",
            'U' => "U",
            else => "M",
        };
        const stat: Stat = stats.get(rel) orelse .{};
        try list.append(a, .{ .rel = rel, .status = st, .added = stat.added, .deleted = stat.deleted });
    }
    return list.items;
}

const GitBranch = struct {
    name: []const u8,
    current: bool,
    /// only on the remote (e.g. `origin/feature`): checking it out makes a local tracking branch
    remote: bool,
};

/// Local branches, then remote ones that have no local branch of the same name.
fn git_branches(c: *ipc.Call, a: struct { root: []const u8 }) ![]const GitBranch {
    const out = try git(c, a.root, &.{ "for-each-ref", "--sort=-committerdate", "--format=%(refname)%1f%(HEAD)", "refs/heads", "refs/remotes" });
    return parseBranches(c.arena, out);
}

fn parseBranches(a: Allocator, out: []const u8) ![]const GitBranch {
    var local: std.ArrayList(GitBranch) = .empty;
    var remote: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, out, "\r\n");
    while (lines.next()) |line| {
        const refname, const head = std.mem.cutScalar(u8, line, 0x1f) orelse continue;
        if (std.mem.cutPrefix(u8, refname, "refs/heads/")) |name| {
            try local.append(a, .{ .name = name, .current = std.mem.eql(u8, head, "*"), .remote = false });
        } else if (std.mem.cutPrefix(u8, refname, "refs/remotes/")) |name| {
            if (!std.mem.endsWith(u8, name, "/HEAD")) try remote.append(a, name);
        }
    }
    const locals = local.items.len;
    for (remote.items) |name| {
        const short = localName(name);
        const have = for (local.items[0..locals]) |b| {
            if (std.mem.eql(u8, b.name, short) or std.mem.eql(u8, b.name, name)) break true;
        } else false;
        if (!have) try local.append(a, .{ .name = name, .current = false, .remote = true });
    }
    return local.items;
}

/// `origin/x` → `x`.
fn localName(remote_branch: []const u8) []const u8 {
    _, const name = std.mem.cutScalar(u8, remote_branch, '/') orelse return remote_branch;
    return name;
}

/// Switch to a branch; a remote one (`origin/x`) becomes local `x` tracking it. Git refuses when
/// uncommitted changes would be overwritten: its message comes back as the error.
fn git_checkout(c: *ipc.Call, a: struct { root: []const u8, name: []const u8, remote: bool }) !void {
    if (a.remote) {
        _ = try git(c, a.root, &.{ "switch", "-c", localName(a.name), "--track", a.name });
    } else {
        _ = try git(c, a.root, &.{ "switch", a.name });
    }
}

/// Throw away a file's uncommitted changes (staged and not): back to HEAD, or gone when HEAD
/// doesn't have it (new / untracked files).
fn git_discard(c: *ipc.Call, a: struct { root: []const u8, rel: []const u8, status: []const u8 }) !void {
    if (std.mem.eql(u8, a.status, "?")) {
        try std.Io.Dir.cwd().deleteFile(core.io, try std.fs.path.join(c.arena, &.{ a.root, a.rel }));
    } else if (std.mem.eql(u8, a.status, "A")) {
        _ = try git(c, a.root, &.{ "rm", "-f", "--", a.rel });
    } else {
        _ = try git(c, a.root, &.{ "restore", "--source=HEAD", "--staged", "--worktree", "--", a.rel });
    }
}

// ---------------- tests ----------------

const testing = std.testing;

test "branch header" {
    const both = branchHeader("## master...origin/master [ahead 1, behind 2]");
    try testing.expectEqualStrings("origin/master", both.upstream.?);
    try testing.expectEqual(1, both.ahead);
    try testing.expectEqual(2, both.behind);

    const behind = branchHeader("## feature/x...origin/feature/x [behind 12]");
    try testing.expectEqualStrings("origin/feature/x", behind.upstream.?);
    try testing.expectEqual(0, behind.ahead);
    try testing.expectEqual(12, behind.behind);

    const even = branchHeader("## main...origin/main");
    try testing.expectEqualStrings("origin/main", even.upstream.?);
    try testing.expectEqual(0, even.ahead);

    try testing.expect(branchHeader("## main").upstream == null);
    try testing.expect(branchHeader("## No commits yet on main").upstream == null);
    // the upstream branch was deleted
    try testing.expectEqualStrings("origin/gone", branchHeader("## x...origin/gone [gone]").upstream.?);
}

test "numstat records are summed per path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stats = try numstats(arena.allocator(), &.{
        "3\t1\tsrc/a.zig\x00-\t-\timg.png\x000\t7\twith\ttab.txt\x00",
        "10\t0\tsrc/a.zig\x00\x00bad record\x00",
        "",
    });
    try testing.expectEqual(3, stats.count());
    try testing.expectEqual(Stat{ .added = 13, .deleted = 1 }, stats.get("src/a.zig").?);
    try testing.expectEqual(Stat{}, stats.get("img.png").?);
    try testing.expectEqual(Stat{ .added = 0, .deleted = 7 }, stats.get("with\ttab.txt").?);
}

test "status records" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stats = try numstats(a, &.{"2\t5\tz.txt\x00"});
    const st = try parseStatus(a, "D:/repo", "## main...origin/main [ahead 3]\x00 M z.txt\x00R  new name.txt\x00old name.txt\x00?? b/new.txt\x00A  added.txt\x00UU clash.txt\x00 D gone.txt\x00MM both.txt\x00", stats);
    try testing.expectEqualStrings("origin/main", st.header.upstream.?);
    try testing.expectEqual(3, st.header.ahead);
    const want = [_]struct { []const u8, []const u8, bool }{
        .{ "added.txt", "A", true },
        .{ "b/new.txt", "?", false },
        .{ "both.txt", "M", true },
        .{ "clash.txt", "U", true },
        .{ "gone.txt", "D", false },
        .{ "new name.txt", "R", true },
        .{ "z.txt", "M", false },
    };
    try testing.expectEqual(want.len, st.files.len);
    for (want, st.files) |w, f| {
        try testing.expectEqualStrings(w[0], f.rel);
        try testing.expectEqualStrings(w[1], f.status);
        try testing.expectEqual(w[2], f.staged);
    }
    try testing.expectEqual(2, st.files[6].added);
    try testing.expectEqual(5, st.files[6].deleted);
    try testing.expectEqualStrings("D:/repo" ++ std.fs.path.sep_str ++ "b/new.txt", st.files[1].abs);

    // no header (detached checkouts still have one, but be safe), nothing changed
    const none = try parseStatus(a, "D:/repo", "", stats);
    try testing.expectEqual(0, none.files.len);
    try testing.expect(none.header.upstream == null);
}

test "log, commit files and branches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const log = try parseLog(a, "aaaa\x1faa\x1fAn\x1f1700000000\x1fFix: it\x1e\nbbbb\x1fbb\x1f\x1f\x1f\x1e\n");
    try testing.expectEqual(2, log.len);
    try testing.expectEqualStrings("aaaa", log[0].hash);
    try testing.expectEqualStrings("aa", log[0].short);
    try testing.expectEqualStrings("An", log[0].author);
    try testing.expectEqual(1700000000000, log[0].date);
    try testing.expectEqualStrings("Fix: it", log[0].subject);
    try testing.expectEqualStrings("bbbb", log[1].hash);
    try testing.expectEqual(0, log[1].date);
    try testing.expectEqualStrings("", log[1].subject);

    const files = try parseCommitFiles(a, "M\x00a.txt\x00A\x00b c.txt\x00D\x00gone\x00T\x00link\x00", try numstats(a, &.{"1\t2\ta.txt\x004\t0\tb c.txt\x00"}));
    try testing.expectEqual(4, files.len);
    try testing.expectEqualStrings("a.txt", files[0].rel);
    try testing.expectEqualStrings("M", files[0].status);
    try testing.expectEqual(2, files[0].deleted);
    try testing.expectEqualStrings("A", files[1].status);
    try testing.expectEqual(4, files[1].added);
    try testing.expectEqualStrings("D", files[2].status);
    try testing.expectEqualStrings("M", files[3].status);

    const branches = try parseBranches(a, "refs/heads/main\x1f*\nrefs/heads/dev\x1f \nrefs/remotes/origin/HEAD\x1f \nrefs/remotes/origin/main\x1f \nrefs/remotes/origin/feature/x\x1f \nrefs/remotes/up/dev\x1f \n");
    try testing.expectEqual(3, branches.len);
    try testing.expectEqualStrings("main", branches[0].name);
    try testing.expect(branches[0].current and !branches[0].remote);
    try testing.expectEqualStrings("dev", branches[1].name);
    try testing.expect(!branches[1].current);
    try testing.expectEqualStrings("origin/feature/x", branches[2].name);
    try testing.expect(branches[2].remote);
    try testing.expectEqualStrings("feature/x", localName("origin/feature/x"));
    try testing.expectEqualStrings("plain", localName("plain"));
}

test "text that is not UTF-8 still reaches the page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("caf\u{FFFD} ok", try lossy(arena.allocator(), "caf\xe9 ok"));
    try testing.expectEqualStrings("cà phê", try lossy(arena.allocator(), "cà phê"));
}

/// The app's environment for a test: this process's own, plus an identity for commits.
var test_env: ?std.process.Environ.Map = null;

fn testInit() !void {
    core.gpa = testing.allocator;
    core.io = testing.io;
    if (test_env == null) {
        // kept for the whole run: not from the allocator that checks each test for leaks
        var env = try testing.environ.createMap(std.heap.page_allocator);
        for ([_][]const u8{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" }) |k| try env.put(k, "Test");
        for ([_][]const u8{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" }) |k| try env.put(k, "test@example.com");
        // whatever this machine's own git config says: files as written, unsigned commits
        try env.put("GIT_CONFIG_COUNT", "2");
        try env.put("GIT_CONFIG_KEY_0", "core.autocrlf");
        try env.put("GIT_CONFIG_VALUE_0", "false");
        try env.put("GIT_CONFIG_KEY_1", "commit.gpgsign");
        try env.put("GIT_CONFIG_VALUE_1", "false");
        test_env = env;
    }
    core.env = &test_env.?;
}

fn findFile(files: []const GitFile, rel: []const u8) ?GitFile {
    for (files) |f| if (std.mem.eql(u8, f.rel, rel)) return f;
    return null;
}

test "a real repository: init, stage, commit, log, branches, discard" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (core.which(a, "git") == null) return error.SkipZigTest;
    var call: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    const c = &call;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    // its own repository, though the temp folder is inside this checkout
    try git_init(c, .{ .folder = dir });

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b b.txt", .data = "b\n" });
    var st = try git_state(c, .{ .folder = dir });
    try testing.expect(st.isRepo);
    const root = st.root.?;
    try testing.expect(st.branch.?.len > 0);
    try testing.expect(st.upstream == null and !st.hasRemote);
    try testing.expectEqual(2, st.files.len);
    try testing.expectEqualStrings("?", findFile(st.files, "a.txt").?.status);
    try testing.expect(!findFile(st.files, "b b.txt").?.staged);
    try testing.expect(core.isFile(findFile(st.files, "b b.txt").?.abs));

    // stage one, unstage it again (no HEAD yet: the `rm --cached` way), stage it for good
    try git_stage(c, .{ .root = root, .rels = &.{"a.txt"}, .stage = true });
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqualStrings("A", findFile(st.files, "a.txt").?.status);
    try testing.expect(findFile(st.files, "a.txt").?.staged);
    try testing.expectEqual(2, findFile(st.files, "a.txt").?.added);
    try git_stage(c, .{ .root = root, .rels = &.{"a.txt"}, .stage = false });
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqualStrings("?", findFile(st.files, "a.txt").?.status);
    try git_stage(c, .{ .root = root, .rels = &.{"a.txt"}, .stage = true });

    // only what is staged is committed
    try git_commit(c, .{ .root = root, .message = "first: \"a\" & b" });
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqual(1, st.files.len);
    try testing.expectEqualStrings("b b.txt", st.files[0].rel);
    // nothing staged: everything goes in
    try git_commit(c, .{ .root = root, .message = "second" });
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqual(0, st.files.len);

    const log = try git_log(c, .{ .root = root });
    try testing.expectEqual(2, log.len);
    try testing.expectEqualStrings("second", log[0].subject);
    try testing.expectEqualStrings("first: \"a\" & b", log[1].subject);
    try testing.expectEqualStrings("Test", log[0].author);
    try testing.expectEqual(40, log[0].hash.len);
    try testing.expect(log[0].date > 1_600_000_000_000);
    const changed = try git_commit_files(c, .{ .root = root, .hash = log[1].hash });
    try testing.expectEqual(1, changed.len);
    try testing.expectEqualStrings("a.txt", changed[0].rel);
    try testing.expectEqualStrings("A", changed[0].status);
    try testing.expectEqual(2, changed[0].added);

    // a change: the numbers, the content at HEAD and at a commit, then thrown away
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n2\n3\n" });
    st = try git_state(c, .{ .folder = dir });
    const changed_file = findFile(st.files, "a.txt").?;
    try testing.expectEqualStrings("M", changed_file.status);
    try testing.expect(!changed_file.staged);
    try testing.expectEqual(2, changed_file.added);
    try testing.expectEqual(1, changed_file.deleted);
    try testing.expectEqualStrings("one\ntwo\n", try git_original(c, .{ .root = root, .rel = "a.txt" }));
    try testing.expectEqualStrings("b\n", try git_show(c, .{ .root = root, .rev = log[0].hash, .rel = "b b.txt" }));
    try testing.expectEqualStrings("", try git_original(c, .{ .root = root, .rel = "missing.txt" }));
    try git_discard(c, .{ .root = root, .rel = "a.txt", .status = "M" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.txt", .data = "x" });
    try git_discard(c, .{ .root = root, .rel = "new.txt", .status = "?" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "staged.txt", .data = "x" });
    try git_stage(c, .{ .root = root, .rels = &.{"staged.txt"}, .stage = true });
    try git_discard(c, .{ .root = root, .rel = "staged.txt", .status = "A" });
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqual(0, st.files.len);
    try testing.expect(!core.exists(try std.fs.path.join(a, &.{ dir, "new.txt" })));
    try testing.expect(!core.exists(try std.fs.path.join(a, &.{ dir, "staged.txt" })));

    // branches
    _ = try git(c, root, &.{ "branch", "other" });
    var branches = try git_branches(c, .{ .root = root });
    try testing.expectEqual(2, branches.len);
    try git_checkout(c, .{ .root = root, .name = "other", .remote = false });
    branches = try git_branches(c, .{ .root = root });
    for (branches) |b| try testing.expectEqual(std.mem.eql(u8, b.name, "other"), b.current);
    st = try git_state(c, .{ .folder = dir });
    try testing.expectEqualStrings("other", st.branch.?);

    // git's own words come back as the error; pushing with no remote has ours
    try testing.expectError(error.Failed, git_checkout(c, .{ .root = root, .name = "no-such-branch", .remote = false }));
    try testing.expect(std.mem.indexOf(u8, c.err_msg.?, "no-such-branch") != null);
    try testing.expectError(error.Failed, git_commit(c, .{ .root = root, .message = "nothing" }));
    try testing.expect(std.mem.indexOf(u8, c.err_msg.?, "nothing to commit") != null);
}

test "push and pull against a local remote" {
    try testInit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (core.which(a, "git") == null) return error.SkipZigTest;
    var call: ipc.Call = .{ .arena = a, .cmd = "", .body = "", .headers = &.{}, .webview = "main" };
    const c = &call;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const remote = try std.fs.path.join(a, &.{ dir, "remote.git" });
    const work = try std.fs.path.join(a, &.{ dir, "work" });
    const clone = try std.fs.path.join(a, &.{ dir, "clone" });
    _ = try git(c, dir, &.{ "init", "--bare", remote });
    try core.makePath(work);
    try git_init(c, .{ .folder = work });
    try core.writeFile(try std.fs.path.join(a, &.{ work, "a.txt" }), "one\n");
    try git_commit(c, .{ .root = work, .message = "first" });

    // no remote yet: nothing to publish to (the message itself needs the app's settings)
    var st = try git_state(c, .{ .folder = work });
    try testing.expect(!st.hasRemote);

    // a branch without upstream is published and tracks the remote
    _ = try git(c, work, &.{ "remote", "add", "origin", remote });
    st = try git_state(c, .{ .folder = work });
    try testing.expect(st.hasRemote and st.upstream == null);
    try git_push(c, .{ .root = work });
    st = try git_state(c, .{ .folder = work });
    try testing.expect(std.mem.startsWith(u8, st.upstream.?, "origin/"));
    try testing.expectEqual(0, st.ahead);

    _ = try git(c, dir, &.{ "clone", "-q", remote, clone });
    try core.writeFile(try std.fs.path.join(a, &.{ work, "a.txt" }), "one\ntwo\n");
    try git_commit(c, .{ .root = work, .message = "second" });
    st = try git_state(c, .{ .folder = work });
    try testing.expectEqual(1, st.ahead);
    try git_push(c, .{ .root = work });

    // the clone only hears about it at the next fetch; pull brings it in
    try git_pull(c, .{ .root = clone });
    try testing.expectEqualStrings("one\ntwo\n", try core.readFileAlloc(a, try std.fs.path.join(a, &.{ clone, "a.txt" }), 1 << 20));
    const branches = try git_branches(c, .{ .root = clone });
    try testing.expectEqual(1, branches.len);
    try testing.expect(branches[0].current);
}
