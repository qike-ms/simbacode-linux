//! Persistence for running-agent sessions across a restart (issue #29).
//!
//! When agents are running in tabs and simbacode exits (crash, update, or an
//! intentional restart), we lose which agent was running where. This store
//! records, for each live agent surface, the agent identity plus the working
//! directory it was launched in, so the next launch can relaunch each agent
//! and resume its most recent session (`Agent.resumeCommand`).
//!
//! The file lives next to the sidebar store at `~/.simbacode/agent-sessions.json`
//! and follows the same conventions as `sidebar_store.zig`: a small, versioned,
//! forward-compatible JSON schema, atomic writes via temp file + rename, and
//! crash-tolerant loads (a corrupt/foreign file yields an empty set, never a
//! panic).
//!
//! Session identity: we persist only the info we can reliably recover on Linux
//! — the agent name and its cwd (worktree). The per-agent CLI is responsible
//! for actually resuming "the last conversation" for that cwd (e.g. `claude
//! --continue`, `codex resume --last`). We intentionally do NOT try to persist
//! an opaque agent-internal session id: those are agent-private and unstable,
//! and the cwd + "resume last" contract is what every agent already supports.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.simbacode_agent_session);

/// Current on-disk schema version for the agent-session store.
pub const schema_version: u32 = 1;

/// A single persisted agent session. Owns its strings.
pub const Session = struct {
    /// The agent's stable name (`Agent.name`, e.g. "claude", "codex").
    agent: [:0]u8,
    /// Absolute working directory the agent was running in (its worktree /
    /// cwd). Used both to relaunch the tab in the right place and, for agents
    /// keyed by cwd, to resume the correct conversation.
    cwd: [:0]u8,
    /// Optional worktree path the tab belonged to, used to restore the tab
    /// into the right per-worktree tab space. Falls back to `cwd` when empty.
    worktree: ?[:0]u8 = null,
    /// Optional agent session id (issue #29). When present the restore builds
    /// a session-SPECIFIC resume (e.g. `claude --resume <id>`) so the EXACT
    /// conversation reopens — essential when several tabs run the same agent.
    /// When absent we fall back to the agent's "continue last" form.
    session_id: ?[:0]u8 = null,

    pub fn deinit(self: *const Session, alloc: Allocator) void {
        alloc.free(self.agent);
        alloc.free(self.cwd);
        if (self.worktree) |w| alloc.free(w);
        if (self.session_id) |s| alloc.free(s);
    }
};

/// In-memory model of the persisted running-agent sessions. Owns its entries.
pub const Store = struct {
    sessions: std.ArrayListUnmanaged(Session) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.sessions.items) |*s| s.deinit(alloc);
        self.sessions.deinit(alloc);
    }

    /// Clear all sessions (freeing their strings) without freeing the backing
    /// list, so the store can be rebuilt in place before a save.
    pub fn clearSessions(self: *Store, alloc: Allocator) void {
        for (self.sessions.items) |*s| s.deinit(alloc);
        self.sessions.clearRetainingCapacity();
    }

    /// Append a session, taking ownership of fresh copies of the given strings.
    /// `agent` and `cwd` are required; `worktree` and `session_id` are
    /// optional. Absolute cwd is enforced by the caller/loader — an empty cwd
    /// is rejected here.
    pub fn add(
        self: *Store,
        alloc: Allocator,
        agent: []const u8,
        cwd: []const u8,
        worktree: ?[]const u8,
        session_id: ?[]const u8,
    ) !void {
        if (agent.len == 0 or cwd.len == 0) return;
        const agent_copy = try alloc.dupeZ(u8, agent);
        errdefer alloc.free(agent_copy);
        const cwd_copy = try alloc.dupeZ(u8, cwd);
        errdefer alloc.free(cwd_copy);
        const wt_copy: ?[:0]u8 = if (worktree) |w|
            (if (w.len > 0) try alloc.dupeZ(u8, w) else null)
        else
            null;
        errdefer if (wt_copy) |w| alloc.free(w);
        const sid_copy: ?[:0]u8 = if (session_id) |sid|
            (if (sid.len > 0) try alloc.dupeZ(u8, sid) else null)
        else
            null;
        errdefer if (sid_copy) |sid| alloc.free(sid);
        try self.sessions.append(alloc, .{
            .agent = agent_copy,
            .cwd = cwd_copy,
            .worktree = wt_copy,
            .session_id = sid_copy,
        });
    }

    /// Find the index of the entry with `session_id`, or null. Session id is
    /// the durable key (issue #29 design): globally unique per agent run.
    pub fn indexOfSessionId(self: *const Store, session_id: []const u8) ?usize {
        for (self.sessions.items, 0..) |*s, i| {
            if (s.session_id) |sid| {
                if (std.mem.eql(u8, sid, session_id)) return i;
            }
        }
        return null;
    }

    /// Insert-or-update the entry for `session_id` (the durable key). Requires a
    /// non-empty session id and cwd (principle: no id = nothing to resume).
    /// Returns true if the store changed (so the caller can persist). Idempotent
    /// when the same (agent, cwd, worktree, id) is upserted again.
    pub fn upsertBySessionId(
        self: *Store,
        alloc: Allocator,
        agent: []const u8,
        cwd: []const u8,
        worktree: ?[]const u8,
        session_id: []const u8,
    ) !bool {
        if (agent.len == 0 or cwd.len == 0 or session_id.len == 0) return false;
        if (self.indexOfSessionId(session_id)) |i| {
            // Update in place if any field differs (cwd/worktree can change).
            const s = &self.sessions.items[i];
            const wt_same = blk: {
                if (s.worktree) |w| {
                    break :blk if (worktree) |nw| std.mem.eql(u8, w, nw) else false;
                } else break :blk worktree == null;
            };
            if (std.mem.eql(u8, s.agent, agent) and
                std.mem.eql(u8, s.cwd, cwd) and wt_same) return false;
            // Replace the entry's mutable fields.
            const agent_copy = try alloc.dupeZ(u8, agent);
            errdefer alloc.free(agent_copy);
            const cwd_copy = try alloc.dupeZ(u8, cwd);
            errdefer alloc.free(cwd_copy);
            const wt_copy: ?[:0]u8 = if (worktree) |w|
                (if (w.len > 0) try alloc.dupeZ(u8, w) else null)
            else
                null;
            alloc.free(s.agent);
            alloc.free(s.cwd);
            if (s.worktree) |w| alloc.free(w);
            s.agent = agent_copy;
            s.cwd = cwd_copy;
            s.worktree = wt_copy;
            return true;
        }
        try self.add(alloc, agent, cwd, worktree, session_id);
        return true;
    }

    /// Remove the entry with `session_id`. Returns true if one was removed.
    pub fn removeBySessionId(self: *Store, alloc: Allocator, session_id: []const u8) bool {
        if (self.indexOfSessionId(session_id)) |i| {
            var removed = self.sessions.orderedRemove(i);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }
};

/// JSON wire shape. Forward-compatible: unknown fields are ignored on load,
/// and absence of the file means "no sessions to restore".
const WireSession = struct {
    agent: []const u8 = "",
    cwd: []const u8 = "",
    worktree: ?[]const u8 = null,
    sessionId: ?[]const u8 = null,
};

const Wire = struct {
    schemaVersion: u32 = schema_version,
    sessions: []const WireSession = &.{},
};

/// Resolve `~/.simbacode/agent-sessions.json`. Caller owns the result.
pub fn storePath(alloc: Allocator) ?[:0]u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fs.path.joinZ(alloc, &.{ home, ".simbacode", "agent-sessions.json" }) catch null;
}

/// Load the persisted sessions. Returns an empty store when the file is absent
/// (nothing to restore) or malformed (corrupt) — never panics.
pub fn load(alloc: Allocator) Store {
    const path = storePath(alloc) orelse return .{};
    defer alloc.free(path);
    return loadFrom(alloc, path);
}

/// Load from an explicit path. Exposed for hermetic tests.
pub fn loadFrom(alloc: Allocator, path: []const u8) Store {
    var store: Store = .{};

    const data = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) {
            log.warn("agent-session: cannot read {s}: {}", .{ path, err });
        }
        return store;
    };
    defer alloc.free(data);

    const parsed = std.json.parseFromSlice(
        Wire,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("agent-session: cannot parse {s}: {} (starting empty)", .{ path, err });
        return store;
    };
    defer parsed.deinit();

    for (parsed.value.sessions) |s| {
        // Require a non-empty agent name and an absolute cwd. A relative cwd
        // would be fed to tab creation / openDirAbsolute downstream and could
        // panic or open the wrong place, so skip it defensively (matching the
        // sidebar store's crash-tolerance contract).
        if (s.agent.len == 0) continue;
        if (s.cwd.len == 0 or !std.fs.path.isAbsolute(s.cwd)) {
            if (s.cwd.len > 0) log.warn("agent-session: skipping non-absolute cwd {s}", .{s.cwd});
            continue;
        }
        // Reject a non-absolute worktree rather than carrying it (fall back to
        // cwd on restore).
        const wt: ?[]const u8 = if (s.worktree) |w|
            (if (w.len > 0 and std.fs.path.isAbsolute(w)) w else null)
        else
            null;
        store.add(alloc, s.agent, s.cwd, wt, s.sessionId) catch |err| {
            log.debug("agent-session: skipping entry: {}", .{err});
            continue;
        };
    }
    return store;
}

/// Persist `store` to `~/.simbacode/agent-sessions.json`.
pub fn save(alloc: Allocator, store: *const Store) !void {
    const path = storePath(alloc) orelse return error.NoHome;
    defer alloc.free(path);
    return saveTo(alloc, path, store);
}

/// Persist to an explicit path (atomic temp + rename). Exposed for tests.
pub fn saveTo(alloc: Allocator, path: []const u8, store: *const Store) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("agent-session: cannot create dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    var wire_sessions = try alloc.alloc(WireSession, store.sessions.items.len);
    defer alloc.free(wire_sessions);
    for (store.sessions.items, 0..) |*s, i| {
        wire_sessions[i] = .{
            .agent = s.agent,
            .cwd = s.cwd,
            .worktree = if (s.worktree) |w| w else null,
            .sessionId = if (s.session_id) |sid| sid else null,
        };
    }
    const wire: Wire = .{
        .schemaVersion = schema_version,
        .sessions = wire_sessions,
    };

    const json = try std.json.Stringify.valueAlloc(alloc, wire, .{ .whitespace = .indent_2 });
    defer alloc.free(json);

    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    errdefer std.fs.cwd().deleteFile(tmp) catch {};
    {
        var file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Delete the persisted store (best-effort). Called once the restore has been
/// consumed so the sessions aren't replayed again on the next launch.
pub fn clear(alloc: Allocator) void {
    const path = storePath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch |err| {
        if (err != error.FileNotFound) {
            log.debug("agent-session: cannot delete {s}: {}", .{ path, err });
        }
    };
}

test "add rejects empty agent or cwd" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.add(alloc, "", "/tmp", null, null);
    try store.add(alloc, "claude", "", null, null);
    try std.testing.expectEqual(@as(usize, 0), store.sessions.items.len);
    try store.add(alloc, "claude", "/tmp/x", null, null);
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
}

test "saveTo then loadFrom round-trips sessions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, ".simbacode", "agent-sessions.json" });
    defer alloc.free(path);

    {
        var store: Store = .{};
        defer store.deinit(alloc);
        try store.add(alloc, "claude", "/home/u/proj-a", "/home/u/proj-a", "sess-a");
        try store.add(alloc, "codex", "/home/u/proj-b", null, null);
        try saveTo(alloc, path, &store);
    }

    var loaded = loadFrom(alloc, path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.sessions.items.len);
    try std.testing.expectEqualStrings("claude", loaded.sessions.items[0].agent);
    try std.testing.expectEqualStrings("/home/u/proj-a", loaded.sessions.items[0].cwd);
    try std.testing.expect(loaded.sessions.items[0].worktree != null);
    try std.testing.expectEqualStrings("/home/u/proj-a", loaded.sessions.items[0].worktree.?);
    try std.testing.expect(loaded.sessions.items[0].session_id != null);
    try std.testing.expectEqualStrings("sess-a", loaded.sessions.items[0].session_id.?);
    try std.testing.expectEqualStrings("codex", loaded.sessions.items[1].agent);
    try std.testing.expect(loaded.sessions.items[1].worktree == null);
    try std.testing.expect(loaded.sessions.items[1].session_id == null);
}

test "loadFrom missing file yields empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "agent-sessions.json" });
    defer alloc.free(path);

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.sessions.items.len);
}

test "loadFrom skips non-absolute cwd" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "agent-sessions.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{
        .sub_path = "agent-sessions.json",
        .data =
        \\{ "schemaVersion": 1, "sessions": [
        \\  { "agent": "claude", "cwd": "relative/dir" },
        \\  { "agent": "codex", "cwd": "/abs/keep" },
        \\  { "agent": "", "cwd": "/abs/noagent" }
        \\] }
        ,
    });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
    try std.testing.expectEqualStrings("codex", store.sessions.items[0].agent);
    try std.testing.expectEqualStrings("/abs/keep", store.sessions.items[0].cwd);
}

test "loadFrom corrupt file yields empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "agent-sessions.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{ .sub_path = "agent-sessions.json", .data = "{ not valid json " });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.sessions.items.len);
}

test "clearSessions frees entries and keeps capacity" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    try store.add(alloc, "claude", "/a", null, null);
    try store.add(alloc, "codex", "/b", null, null);
    store.clearSessions(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.sessions.items.len);
    // Reusable after clear.
    try store.add(alloc, "pi", "/c", null, null);
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
}

test "upsertBySessionId inserts, updates, and is idempotent" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    // Insert.
    try std.testing.expect(try store.upsertBySessionId(alloc, "claude", "/a", "/a", "sid-1"));
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
    // Idempotent: same fields -> no change, no duplicate.
    try std.testing.expect(!try store.upsertBySessionId(alloc, "claude", "/a", "/a", "sid-1"));
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
    // Update cwd for the same session id -> changed, still one entry.
    try std.testing.expect(try store.upsertBySessionId(alloc, "claude", "/b", "/b", "sid-1"));
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
    try std.testing.expectEqualStrings("/b", store.sessions.items[0].cwd);
    // A different session id -> a new entry.
    try std.testing.expect(try store.upsertBySessionId(alloc, "codex", "/c", null, "sid-2"));
    try std.testing.expectEqual(@as(usize, 2), store.sessions.items.len);
    // Empty id / cwd / agent are rejected (no id = nothing to resume).
    try std.testing.expect(!try store.upsertBySessionId(alloc, "pi", "/d", null, ""));
    try std.testing.expect(!try store.upsertBySessionId(alloc, "pi", "", null, "sid-3"));
    try std.testing.expectEqual(@as(usize, 2), store.sessions.items.len);
}

test "removeBySessionId + indexOfSessionId" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);
    try std.testing.expect(try store.upsertBySessionId(alloc, "claude", "/a", null, "sid-1"));
    try std.testing.expect(try store.upsertBySessionId(alloc, "codex", "/b", null, "sid-2"));
    try std.testing.expect(store.indexOfSessionId("sid-2") != null);
    try std.testing.expect(store.removeBySessionId(alloc, "sid-1"));
    try std.testing.expect(store.indexOfSessionId("sid-1") == null);
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
    // Removing a missing id is a no-op.
    try std.testing.expect(!store.removeBySessionId(alloc, "nope"));
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);
}
