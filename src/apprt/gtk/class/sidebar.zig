//! simbacode worktree sidebar.
//!
//! Scans a root directory (the configured projects root, default `~/git`) for
//! git repositories, lists each repo's worktrees, and reports per-worktree
//! status (branch, dirty, ahead/behind, no-upstream). The result populates the
//! navigation ListBox in the window. Activating a row opens that worktree's
//! path in a new terminal tab.
//!
//! This is a straight port of the original supacode (macOS) sidebar's
//! git-scan logic, which on Linux we drive with `std.process.Child` instead of
//! the Swift GitClient.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sidebar_store = @import("sidebar_store.zig");
const ssh_command = @import("ssh_command.zig");

const log = std.log.scoped(.simbacode_sidebar);

/// Status of a single worktree (or a repo's main checkout).
pub const WorktreeStatus = struct {
    /// Display name (basename of the worktree path).
    name: []const u8,
    /// Absolute path to the worktree, NUL-terminated for GTK/working-directory.
    path: [:0]const u8,
    /// Current branch (abbrev ref), or "HEAD" when detached.
    branch: []const u8,
    /// Working tree has uncommitted changes.
    dirty: bool,
    /// Commits ahead of upstream.
    ahead: u32,
    /// Commits behind upstream.
    behind: u32,
    /// No upstream tracking branch configured.
    no_upstream: bool,
    /// True if this is a linked worktree (not the main checkout).
    is_worktree: bool,
    /// Lines added in the working tree (uncommitted, vs HEAD).
    added: u32,
    /// Lines removed in the working tree (uncommitted, vs HEAD).
    removed: u32,
    /// Absolute path to the owning repository's main checkout top-level,
    /// NUL-terminated. Used to group worktrees under their repo in the sidebar.
    repo_root: [:0]const u8,
    /// Display name of the owning repository (basename of repo_root).
    repo_name: []const u8,
    /// Remote SSH host this worktree lives on (#32), or null for a local
    /// worktree. Owned. When set, the worktree's terminal is opened over ssh
    /// and its git status was gathered over ssh.
    host: ?RemoteHost = null,

    pub fn deinit(self: *const WorktreeStatus, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.branch);
        alloc.free(self.repo_root);
        alloc.free(self.repo_name);
        if (self.host) |*h| h.deinit(alloc);
    }

    /// A worktree that has commits to push (ahead of upstream, has upstream).
    pub fn pushable(self: *const WorktreeStatus) bool {
        return self.ahead > 0 and !self.no_upstream;
    }

    /// True if this worktree lives on a remote SSH host.
    pub fn isRemote(self: *const WorktreeStatus) bool {
        return self.host != null;
    }
};

/// An owned remote-host spec attached to a WorktreeStatus (#32). Mirrors
/// sidebar_store.RemoteSpec but lives here so sidebar consumers don't need the
/// store type. Owns its strings.
pub const RemoteHost = struct {
    alias: [:0]u8,
    username: ?[:0]u8 = null,
    port: ?u16 = null,

    pub fn deinit(self: *const RemoteHost, alloc: Allocator) void {
        alloc.free(self.alias);
        if (self.username) |u| alloc.free(u);
    }

    /// Borrow as an ssh_command.RemoteHost for command construction.
    pub fn asSshHost(self: *const RemoteHost) ssh_command.RemoteHost {
        return .{ .alias = self.alias, .username = self.username, .port = self.port };
    }
};

/// Run a git command in `cwd`, returning trimmed stdout. Caller owns result.
/// Returns null on non-zero exit or spawn failure.
/// A git execution context: local (run in `cwd`) or remote (run over ssh on
/// `host`). Threaded through the scan so the same status logic serves both.
const GitRunner = struct {
    host: ?sidebar_store.RemoteSpec = null,

    /// Run a git command (argv[0] == "git") for directory `dir`, returning
    /// trimmed stdout or null on failure. Local runs use `cwd = dir`; remote
    /// runs build an ssh invocation with `dir` as the remote working dir.
    fn run(self: GitRunner, alloc: Allocator, dir: []const u8, git_argv: []const []const u8) ?[]u8 {
        if (self.host) |h| {
            const ssh_host: ssh_command.RemoteHost = .{
                .alias = h.alias,
                .username = h.username,
                .port = h.port,
            };
            const argv = ssh_command.invocation(
                alloc,
                ssh_host,
                git_argv[0],
                git_argv[1..],
                dir,
                .{ .batch = true, .allocate_tty = false },
            ) catch |err| {
                log.debug("ssh git build failed dir={s} err={}", .{ dir, err });
                return null;
            };
            defer ssh_command.freeArgv(alloc, argv);
            // Remote command runs the whole cwd change itself; no local cwd.
            return runChild(alloc, null, argv);
        }
        return runChild(alloc, dir, git_argv);
    }
};

/// Run a child process, returning trimmed stdout (caller owns) or null on any
/// nonzero exit / spawn error. `cwd` is the local working directory (null to
/// inherit — used for ssh invocations that cd remotely).
fn runChild(
    alloc: Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        log.debug("command failed cwd={?s} err={}", .{ cwd, err });
        return null;
    };
    defer alloc.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            alloc.free(result.stdout);
            return null;
        },
        else => {
            alloc.free(result.stdout);
            return null;
        },
    }
    // Trim trailing whitespace/newline in place.
    const trimmed = std.mem.trimRight(u8, result.stdout, " \t\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;
    const out = alloc.dupe(u8, trimmed) catch {
        alloc.free(result.stdout);
        return null;
    };
    alloc.free(result.stdout);
    return out;
}

/// Run a local git command in `cwd`, returning trimmed stdout. Caller owns
/// result. Thin wrapper over `runChild` for the many local call sites.
fn git(
    alloc: Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) ?[]u8 {
    return runChild(alloc, cwd, argv);
}

/// Build the status for a single worktree directory. `runner` selects local
/// vs remote (ssh) git execution; when remote, the result is tagged with an
/// owned copy of the host.
fn statusFor(
    alloc: Allocator,
    runner: GitRunner,
    dir: []const u8,
    is_worktree: bool,
    repo_root: []const u8,
) ?WorktreeStatus {
    // Branch (abbrev ref); fall back to "HEAD" when detached or on error.
    const branch = runner.run(alloc, dir, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse
        (alloc.dupe(u8, "HEAD") catch return null);

    // Dirty: `git status --porcelain` produces any output.
    var dirty = false;
    if (runner.run(alloc, dir, &.{ "git", "status", "--porcelain" })) |st| {
        dirty = st.len > 0;
        alloc.free(st);
    }

    // Diff line counts vs HEAD (working tree + staged). `git diff HEAD
    // --shortstat` prints e.g. " 3 files changed, 12 insertions(+), 4
    // deletions(-)". Parse insertions/deletions; absent on a clean tree.
    var added: u32 = 0;
    var removed: u32 = 0;
    if (dirty) {
        if (runner.run(alloc, dir, &.{ "git", "diff", "HEAD", "--shortstat" })) |ss| {
            defer alloc.free(ss);
            parseShortstat(ss, &added, &removed);
        }
    }

    // Ahead/behind vs upstream. `--left-right --count @{u}...HEAD` prints
    // "<behind>\t<ahead>". Failure => no upstream.
    var ahead: u32 = 0;
    var behind: u32 = 0;
    var no_upstream = false;
    if (runner.run(alloc, dir, &.{ "git", "rev-list", "--left-right", "--count", "@{u}...HEAD" })) |ab| {
        defer alloc.free(ab);
        var it = std.mem.tokenizeAny(u8, ab, " \t");
        if (it.next()) |b| behind = std.fmt.parseInt(u32, b, 10) catch 0;
        if (it.next()) |a| ahead = std.fmt.parseInt(u32, a, 10) catch 0;
    } else {
        no_upstream = true;
    }

    const name = alloc.dupe(u8, std.fs.path.basename(dir)) catch {
        alloc.free(branch);
        return null;
    };
    const path = alloc.dupeZ(u8, dir) catch {
        alloc.free(branch);
        alloc.free(name);
        return null;
    };
    const rroot = alloc.dupeZ(u8, repo_root) catch {
        alloc.free(branch);
        alloc.free(name);
        alloc.free(path);
        return null;
    };
    const rname = alloc.dupe(u8, std.fs.path.basename(repo_root)) catch {
        alloc.free(branch);
        alloc.free(name);
        alloc.free(path);
        alloc.free(rroot);
        return null;
    };

    // Tag with an owned copy of the host when this is a remote scan, so the
    // worktree's terminal + status can be driven over ssh downstream (#32).
    var host_copy: ?RemoteHost = null;
    if (runner.host) |h| {
        const alias_z = alloc.dupeZ(u8, h.alias) catch {
            alloc.free(branch);
            alloc.free(name);
            alloc.free(path);
            alloc.free(rroot);
            alloc.free(rname);
            return null;
        };
        const user_z: ?[:0]u8 = if (h.username) |u| (alloc.dupeZ(u8, u) catch null) else null;
        host_copy = .{ .alias = alias_z, .username = user_z, .port = h.port };
    }

    return .{
        .name = name,
        .path = path,
        .branch = branch,
        .dirty = dirty,
        .ahead = ahead,
        .behind = behind,
        .no_upstream = no_upstream,
        .is_worktree = is_worktree,
        .added = added,
        .removed = removed,
        .repo_root = rroot,
        .repo_name = rname,
        .host = host_copy,
    };
}

/// Parse a `git diff --shortstat` line, extracting insertion/deletion counts.
/// Example input: " 3 files changed, 12 insertions(+), 4 deletions(-)".
fn parseShortstat(line: []const u8, added: *u32, removed: *u32) void {
    var it = std.mem.tokenizeAny(u8, line, " ,\n");
    var prev: ?u32 = null;
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "insertion")) {
            if (prev) |n| added.* = n;
        } else if (std.mem.startsWith(u8, tok, "deletion")) {
            if (prev) |n| removed.* = n;
        }
        prev = std.fmt.parseInt(u32, tok, 10) catch null;
    }
}

/// Parse `git worktree list --porcelain` output for worktree paths.
/// Lines of interest start with "worktree ".
fn appendWorktreePaths(
    alloc: Allocator,
    porcelain: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |line| {
        const prefix = "worktree ";
        if (std.mem.startsWith(u8, line, prefix)) {
            const p = std.mem.trimRight(u8, line[prefix.len..], " \t\r");
            if (p.len > 0) try out.append(alloc, try alloc.dupe(u8, p));
        }
    }
}

/// Scan a single directory `dir` as a git repository, appending its
/// worktrees (or the main checkout) to `results`. No-op when `dir` is not a
/// git work tree. `runner` selects local vs remote (ssh) execution. Used by
/// `scan` (per discovered subdir), `scanPaths` (per user-added local root),
/// and `scanRemoteRoot` (remote root).
fn scanRepo(
    alloc: Allocator,
    runner: GitRunner,
    dir: []const u8,
    results: *std.ArrayListUnmanaged(WorktreeStatus),
) !void {
    // Is this a git work tree?
    const inside = runner.run(alloc, dir, &.{ "git", "rev-parse", "--is-inside-work-tree" }) orelse return;
    const is_repo = std.mem.eql(u8, std.mem.trim(u8, inside, " \t\r\n"), "true");
    alloc.free(inside);
    if (!is_repo) return;

    // Resolve the main checkout top-level.
    const top = runner.run(alloc, dir, &.{ "git", "rev-parse", "--show-toplevel" }) orelse return;
    defer alloc.free(top);

    // List worktrees from the top-level.
    var wt_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (wt_paths.items) |p| alloc.free(p);
        wt_paths.deinit(alloc);
    }
    if (runner.run(alloc, top, &.{ "git", "worktree", "list", "--porcelain" })) |porc| {
        defer alloc.free(porc);
        try appendWorktreePaths(alloc, porc, &wt_paths);
    }

    if (wt_paths.items.len == 0) {
        // No worktree info; treat top as the single (main) checkout.
        if (statusFor(alloc, runner, top, false, top)) |s| try results.append(alloc, s);
        return;
    }

    for (wt_paths.items) |wp| {
        const is_linked = !std.mem.eql(u8, wp, top);
        if (statusFor(alloc, runner, wp, is_linked, top)) |s| try results.append(alloc, s);
    }
}

/// Scan a REMOTE (SSH) root over ssh (#32). Runs the same repo/worktree/status
/// logic as a local scan, but every git command is dispatched over ssh with
/// `path` as the remote working directory. Each resulting WorktreeStatus is
/// tagged with `host` so its terminal opens over ssh.
fn scanRemoteRoot(
    alloc: Allocator,
    path: []const u8,
    host: sidebar_store.RemoteSpec,
    results: *std.ArrayListUnmanaged(WorktreeStatus),
) !void {
    const runner: GitRunner = .{ .host = host };
    try scanRepo(alloc, runner, path, results);
}

/// Sort scan results by repo name, then main-checkout-first, then worktree
/// name, grouping worktrees under their owning repo for the grouped sidebar.
fn sortResults(results: []WorktreeStatus) void {
    std.mem.sort(WorktreeStatus, results, {}, struct {
        fn lessThan(_: void, a: WorktreeStatus, b: WorktreeStatus) bool {
            const repo_cmp = std.mem.order(u8, a.repo_name, b.repo_name);
            if (repo_cmp != .eq) return repo_cmp == .lt;
            // Within a repo: main checkout (not is_worktree) sorts first.
            if (a.is_worktree != b.is_worktree) return !a.is_worktree;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

/// Scan an explicit list of user-added project roots. Each root is treated as
/// a repository directly when it is a git work tree; otherwise its immediate
/// subdirectories are scanned (so adding a parent folder like `~/git` still
/// discovers the repos beneath it). Caller owns the returned slice and must
/// call `freeStatuses`.
pub fn scanPaths(alloc: Allocator, roots: []const sidebar_store.Root) ![]WorktreeStatus {
    var results: std.ArrayListUnmanaged(WorktreeStatus) = .empty;
    errdefer {
        for (results.items) |*s| s.deinit(alloc);
        results.deinit(alloc);
    }

    for (roots) |*root_entry| {
        // Remote (SSH) roots are scanned over ssh (#32, B3).
        if (root_entry.host) |host| {
            scanRemoteRoot(alloc, root_entry.path, host, &results) catch |err| {
                log.warn("sidebar: remote scan failed root={s} err={}", .{ root_entry.path, err });
            };
            continue;
        }

        const root = root_entry.path;
        // Defensive: `openDirAbsolute` below asserts (panics) on a relative
        // path. The store already filters these on load, but guard here too so
        // no caller can crash the scan with a relative root.
        if (!std.fs.path.isAbsolute(root)) {
            log.warn("sidebar: ignoring non-absolute root {s}", .{root});
            continue;
        }

        // First try the root itself as a repository.
        const before = results.items.len;
        try scanRepo(alloc, .{}, root, &results);
        if (results.items.len > before) continue;

        // Not a repo itself: fall back to scanning immediate subdirectories.
        var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| {
            log.warn("cannot open sidebar root {s}: {}", .{ root, err });
            continue;
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            const sub = try std.fs.path.join(alloc, &.{ root, entry.name });
            defer alloc.free(sub);
            try scanRepo(alloc, .{}, sub, &results);
        }
    }

    // Deduplicate by worktree path: overlapping roots (e.g. `~/git` added
    // alongside a child repo `~/git/foo`, or the same repo reached via two
    // roots) would otherwise list the same worktree twice. Keep first seen.
    // The map is pre-sized so getOrPut can't fail mid-loop — an OOM there would
    // leave the in-place compaction half-done and make the function-wide
    // errdefer double-free aliased survivor slots.
    {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(alloc);
        try seen.ensureTotalCapacity(alloc, @intCast(results.items.len));
        var w: usize = 0;
        for (results.items) |s| {
            const gop = seen.getOrPutAssumeCapacity(s.path);
            if (gop.found_existing) {
                // Drop this duplicate; free its owned strings.
                s.deinit(alloc);
                continue;
            }
            results.items[w] = s;
            w += 1;
        }
        results.shrinkRetainingCapacity(w);
    }

    sortResults(results.items);
    return results.toOwnedSlice(alloc);
}

/// Scan `root` for git repos and their worktrees. Caller owns the returned
/// slice and must call `freeStatuses`.
pub fn scan(alloc: Allocator, root: []const u8) ![]WorktreeStatus {
    var results: std.ArrayListUnmanaged(WorktreeStatus) = .empty;
    errdefer {
        for (results.items) |*s| s.deinit(alloc);
        results.deinit(alloc);
    }

    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| {
        log.warn("cannot open projects root {s}: {}", .{ root, err });
        return results.toOwnedSlice(alloc);
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const sub = try std.fs.path.join(alloc, &.{ root, entry.name });
        defer alloc.free(sub);
        try scanRepo(alloc, .{}, sub, &results);
    }

    // Sort by repo name, then main-checkout-first, then worktree name. This
    // groups worktrees under their owning repo for the grouped sidebar.
    sortResults(results.items);

    return results.toOwnedSlice(alloc);
}

pub fn freeStatuses(alloc: Allocator, statuses: []WorktreeStatus) void {
    for (statuses) |*s| s.deinit(alloc);
    alloc.free(statuses);
}

test "parseShortstat: insertions and deletions" {
    var added: u32 = 0;
    var removed: u32 = 0;
    parseShortstat(" 3 files changed, 12 insertions(+), 4 deletions(-)", &added, &removed);
    try std.testing.expectEqual(@as(u32, 12), added);
    try std.testing.expectEqual(@as(u32, 4), removed);
}

test "parseShortstat: insertions only" {
    var added: u32 = 0;
    var removed: u32 = 0;
    parseShortstat(" 1 file changed, 5 insertions(+)", &added, &removed);
    try std.testing.expectEqual(@as(u32, 5), added);
    try std.testing.expectEqual(@as(u32, 0), removed);
}

test "parseShortstat: deletions only" {
    var added: u32 = 0;
    var removed: u32 = 0;
    parseShortstat(" 2 files changed, 7 deletions(-)", &added, &removed);
    try std.testing.expectEqual(@as(u32, 0), added);
    try std.testing.expectEqual(@as(u32, 7), removed);
}

test "parseShortstat: empty" {
    var added: u32 = 0;
    var removed: u32 = 0;
    parseShortstat("", &added, &removed);
    try std.testing.expectEqual(@as(u32, 0), added);
    try std.testing.expectEqual(@as(u32, 0), removed);
}
