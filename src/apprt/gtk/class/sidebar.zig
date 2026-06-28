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

    pub fn deinit(self: *const WorktreeStatus, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.branch);
        alloc.free(self.repo_root);
        alloc.free(self.repo_name);
    }

    /// A worktree that has commits to push (ahead of upstream, has upstream).
    pub fn pushable(self: *const WorktreeStatus) bool {
        return self.ahead > 0 and !self.no_upstream;
    }
};

/// Run a git command in `cwd`, returning trimmed stdout. Caller owns result.
/// Returns null on non-zero exit or spawn failure.
fn git(
    alloc: Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) ?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        log.debug("git command failed cwd={s} err={}", .{ cwd, err });
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

/// Build the status for a single worktree directory.
fn statusFor(
    alloc: Allocator,
    dir: []const u8,
    is_worktree: bool,
    repo_root: []const u8,
) ?WorktreeStatus {
    // Branch (abbrev ref); fall back to "HEAD" when detached or on error.
    const branch = git(alloc, dir, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }) orelse
        (alloc.dupe(u8, "HEAD") catch return null);

    // Dirty: `git status --porcelain` produces any output.
    var dirty = false;
    if (git(alloc, dir, &.{ "git", "status", "--porcelain" })) |st| {
        dirty = st.len > 0;
        alloc.free(st);
    }

    // Diff line counts vs HEAD (working tree + staged). `git diff HEAD
    // --shortstat` prints e.g. " 3 files changed, 12 insertions(+), 4
    // deletions(-)". Parse insertions/deletions; absent on a clean tree.
    var added: u32 = 0;
    var removed: u32 = 0;
    if (dirty) {
        if (git(alloc, dir, &.{ "git", "diff", "HEAD", "--shortstat" })) |ss| {
            defer alloc.free(ss);
            parseShortstat(ss, &added, &removed);
        }
    }

    // Ahead/behind vs upstream. `--left-right --count @{u}...HEAD` prints
    // "<behind>\t<ahead>". Failure => no upstream.
    var ahead: u32 = 0;
    var behind: u32 = 0;
    var no_upstream = false;
    if (git(alloc, dir, &.{ "git", "rev-list", "--left-right", "--count", "@{u}...HEAD" })) |ab| {
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
/// git work tree. Used by both `scan` (per discovered subdir) and
/// `scanPaths` (per user-added root).
fn scanRepo(
    alloc: Allocator,
    dir: []const u8,
    results: *std.ArrayListUnmanaged(WorktreeStatus),
) !void {
    // Is this a git work tree?
    const inside = git(alloc, dir, &.{ "git", "rev-parse", "--is-inside-work-tree" }) orelse return;
    const is_repo = std.mem.eql(u8, std.mem.trim(u8, inside, " \t\r\n"), "true");
    alloc.free(inside);
    if (!is_repo) return;

    // Resolve the main checkout top-level.
    const top = git(alloc, dir, &.{ "git", "rev-parse", "--show-toplevel" }) orelse return;
    defer alloc.free(top);

    // List worktrees from the top-level.
    var wt_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (wt_paths.items) |p| alloc.free(p);
        wt_paths.deinit(alloc);
    }
    if (git(alloc, top, &.{ "git", "worktree", "list", "--porcelain" })) |porc| {
        defer alloc.free(porc);
        try appendWorktreePaths(alloc, porc, &wt_paths);
    }

    if (wt_paths.items.len == 0) {
        // No worktree info; treat top as the single (main) checkout.
        if (statusFor(alloc, top, false, top)) |s| try results.append(alloc, s);
        return;
    }

    for (wt_paths.items) |wp| {
        const is_linked = !std.mem.eql(u8, wp, top);
        if (statusFor(alloc, wp, is_linked, top)) |s| try results.append(alloc, s);
    }
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
pub fn scanPaths(alloc: Allocator, roots: []const [:0]const u8) ![]WorktreeStatus {
    var results: std.ArrayListUnmanaged(WorktreeStatus) = .empty;
    errdefer {
        for (results.items) |*s| s.deinit(alloc);
        results.deinit(alloc);
    }

    for (roots) |root| {
        // Defensive: `openDirAbsolute` below asserts (panics) on a relative
        // path. The store already filters these on load, but guard here too so
        // no caller can crash the scan with a relative root.
        if (!std.fs.path.isAbsolute(root)) {
            log.warn("sidebar: ignoring non-absolute root {s}", .{root});
            continue;
        }

        // First try the root itself as a repository.
        const before = results.items.len;
        try scanRepo(alloc, root, &results);
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
            try scanRepo(alloc, sub, &results);
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
        try scanRepo(alloc, sub, &results);
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
