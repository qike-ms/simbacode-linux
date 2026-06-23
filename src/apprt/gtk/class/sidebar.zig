//! Supacode worktree sidebar.
//!
//! Scans a root directory (the configured projects root, default `~/git`) for
//! git repositories, lists each repo's worktrees, and reports per-worktree
//! status (branch, dirty, ahead/behind, no-upstream). The result populates the
//! navigation ListBox in the window. Activating a row opens that worktree's
//! path in a new terminal tab.
//!
//! This is a straight port of the original Supacode (macOS) sidebar's
//! git-scan logic, which on Linux we drive with `std.process.Child` instead of
//! the Swift GitClient.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.supacode_sidebar);

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

    pub fn deinit(self: *const WorktreeStatus, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
        alloc.free(self.branch);
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

    return .{
        .name = name,
        .path = path,
        .branch = branch,
        .dirty = dirty,
        .ahead = ahead,
        .behind = behind,
        .no_upstream = no_upstream,
        .is_worktree = is_worktree,
    };
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

        // Is this a git work tree?
        const inside = git(alloc, sub, &.{ "git", "rev-parse", "--is-inside-work-tree" }) orelse continue;
        const is_repo = std.mem.eql(u8, std.mem.trim(u8, inside, " \t\r\n"), "true");
        alloc.free(inside);
        if (!is_repo) continue;

        // Resolve the main checkout top-level.
        const top = git(alloc, sub, &.{ "git", "rev-parse", "--show-toplevel" }) orelse continue;
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
            if (statusFor(alloc, top, false)) |s| try results.append(alloc, s);
            continue;
        }

        for (wt_paths.items) |wp| {
            const is_linked = !std.mem.eql(u8, wp, top);
            if (statusFor(alloc, wp, is_linked)) |s| try results.append(alloc, s);
        }
    }

    // Sort by name for stable display.
    std.mem.sort(WorktreeStatus, results.items, {}, struct {
        fn lessThan(_: void, a: WorktreeStatus, b: WorktreeStatus) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    return results.toOwnedSlice(alloc);
}

pub fn freeStatuses(alloc: Allocator, statuses: []WorktreeStatus) void {
    for (statuses) |*s| s.deinit(alloc);
    alloc.free(statuses);
}
