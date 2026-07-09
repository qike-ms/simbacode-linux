//! Persistence for the user-curated sidebar project roots.
//!
//! Issue #21: instead of auto-scanning every repo under `~/git`, the sidebar
//! lists only folders the user has explicitly added via the `+` button. The
//! chosen set is persisted to `~/.simbacode/sidebar.json` and read on startup.
//!
//! macOS source of truth: `~/.supacode/sidebar.json` (the macOS app) (a far richer nested
//! schema of sections/buckets/items; see supacode's `SidebarState.swift`). On
//! Linux we persist only the flat list of project roots we need — the file is
//! versioned so the schema can grow later without breaking older readers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.simbacode_sidebar);

/// Current on-disk schema version for the Linux sidebar store. v2 adds an
/// optional per-root `host` for remote (SSH) repositories (#32); v1 files
/// (flat string roots) still load — a v1 root becomes a local Root.
pub const schema_version: u32 = 2;

/// A remote SSH host a root can live on (#32). Mirrors ssh_command.RemoteHost
/// but owns its strings for persistence. `null` host on a Root means local.
pub const RemoteSpec = struct {
    alias: [:0]u8,
    username: ?[:0]u8 = null,
    port: ?u16 = null,

    pub fn deinit(self: *const RemoteSpec, alloc: Allocator) void {
        alloc.free(self.alias);
        if (self.username) |u| alloc.free(u);
    }

    fn dupe(self: *const RemoteSpec, alloc: Allocator) !RemoteSpec {
        const alias_copy = try alloc.dupeZ(u8, self.alias);
        errdefer alloc.free(alias_copy);
        const user_copy: ?[:0]u8 = if (self.username) |u| try alloc.dupeZ(u8, u) else null;
        return .{ .alias = alias_copy, .username = user_copy, .port = self.port };
    }
};

/// A user-added project root. `path` is absolute (local filesystem path, or
/// the remote absolute path when `host` is set). `host` null = local.
pub const Root = struct {
    path: [:0]u8,
    host: ?RemoteSpec = null,

    pub fn deinit(self: *const Root, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.host) |*h| h.deinit(alloc);
    }

    pub fn isRemote(self: *const Root) bool {
        return self.host != null;
    }
};

/// In-memory model of the persisted sidebar state. Owns its strings.
pub const Store = struct {
    /// User-added project roots. Order is preserved.
    roots: std.ArrayListUnmanaged(Root) = .empty,

    /// Last directory the user browsed from in the `+` Add Folder picker
    /// (absolute path). Used to reopen the picker where they left off so
    /// adding several folders from the same parent doesn't re-navigate from
    /// scratch. `null` until the first add.
    last_folder: ?[:0]u8 = null,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.roots.items) |*r| r.deinit(alloc);
        self.roots.deinit(alloc);
        if (self.last_folder) |lf| alloc.free(lf);
    }

    /// Record the directory the user just browsed from (typically the parent
    /// of an added folder) so the picker reopens there. Replaces any prior
    /// value. Takes ownership of a fresh copy of `path`.
    pub fn setLastFolder(self: *Store, alloc: Allocator, path: []const u8) !void {
        const copy = try alloc.dupeZ(u8, path);
        if (self.last_folder) |lf| alloc.free(lf);
        self.last_folder = copy;
    }

    /// Index of the root whose path matches (local roots only, since a remote
    /// path can collide with a local one). Returns null if absent.
    fn indexOfLocal(self: *const Store, path: []const u8) ?usize {
        for (self.roots.items, 0..) |*r, i| {
            if (r.host == null and std.mem.eql(u8, r.path, path)) return i;
        }
        return null;
    }

    /// True if a LOCAL root with `path` is already present.
    pub fn contains(self: *const Store, path: []const u8) bool {
        return self.indexOfLocal(path) != null;
    }

    /// Add a LOCAL `path` if not already present. Returns true if it was added.
    /// Takes ownership of a fresh copy of `path`.
    pub fn add(self: *Store, alloc: Allocator, path: []const u8) !bool {
        if (self.contains(path)) return false;
        const copy = try alloc.dupeZ(u8, path);
        errdefer alloc.free(copy);
        try self.roots.append(alloc, .{ .path = copy, .host = null });
        return true;
    }

    /// True if a REMOTE root with the same host authority + path is present.
    pub fn containsRemote(self: *const Store, host: RemoteSpec, path: []const u8) bool {
        return self.indexOfRemote(host, path) != null;
    }

    fn indexOfRemote(self: *const Store, host: RemoteSpec, path: []const u8) ?usize {
        for (self.roots.items, 0..) |*r, i| {
            const rh = r.host orelse continue;
            if (!std.mem.eql(u8, r.path, path)) continue;
            if (!std.mem.eql(u8, rh.alias, host.alias)) continue;
            const user_same = blk: {
                if (rh.username) |a| {
                    break :blk if (host.username) |b| std.mem.eql(u8, a, b) else false;
                } else break :blk host.username == null;
            };
            if (!user_same) continue;
            if (rh.port != host.port) continue;
            return i;
        }
        return null;
    }

    /// Add a REMOTE root (host + absolute remote path). Returns true if added.
    /// Takes ownership of fresh copies of all strings.
    pub fn addRemote(self: *Store, alloc: Allocator, host: RemoteSpec, path: []const u8) !bool {
        if (self.containsRemote(host, path)) return false;
        const host_copy = try host.dupe(alloc);
        errdefer host_copy.deinit(alloc);
        const path_copy = try alloc.dupeZ(u8, path);
        errdefer alloc.free(path_copy);
        try self.roots.append(alloc, .{ .path = path_copy, .host = host_copy });
        return true;
    }

    /// Remove a LOCAL root by `path` if present. Returns true if it was removed.
    pub fn remove(self: *Store, alloc: Allocator, path: []const u8) bool {
        if (self.indexOfLocal(path)) |i| {
            var removed = self.roots.orderedRemove(i);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }

    /// Remove a REMOTE root by host + path if present. Returns true if removed.
    pub fn removeRemote(self: *Store, alloc: Allocator, host: RemoteSpec, path: []const u8) bool {
        if (self.indexOfRemote(host, path)) |i| {
            var removed = self.roots.orderedRemove(i);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }
};

/// JSON wire shape. Forward-compatible: unknown fields are ignored on load.
/// v1 used `roots: []string`; v2 uses `roots: []WireRoot`. We accept BOTH on
/// load (see loadFrom) by trying the structured shape first, then the legacy
/// string shape, so old files upgrade transparently.
const WireRemote = struct {
    alias: []const u8 = "",
    username: ?[]const u8 = null,
    port: ?u16 = null,
};

const WireRoot = struct {
    path: []const u8 = "",
    host: ?WireRemote = null,
};

const Wire = struct {
    schemaVersion: u32 = schema_version,
    roots: []const WireRoot = &.{},
    lastFolder: ?[]const u8 = null,
};

/// Legacy v1 wire shape (flat string roots), accepted on load for migration.
const WireV1 = struct {
    schemaVersion: u32 = 1,
    roots: []const []const u8 = &.{},
    lastFolder: ?[]const u8 = null,
};

/// Resolve `~/.simbacode/sidebar.json`. Caller owns the result. If the new
/// location is absent but a legacy `~/.supacode/sidebar.json` exists, returns
/// the legacy path so existing config is read (one-time migration on next save
/// writes to the new location).
pub fn storePath(alloc: Allocator) ?[:0]u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const new_path = std.fs.path.joinZ(alloc, &.{ home, ".simbacode", "sidebar.json" }) catch return null;
    // If the new file is missing but a legacy one exists, hand back the legacy
    // path so we read it (load path). Saves always go through the new path via
    // saveStorePath below.
    std.fs.cwd().access(new_path, .{}) catch {
        const legacy = std.fs.path.joinZ(alloc, &.{ home, ".supacode", "sidebar.json" }) catch return new_path;
        if (std.fs.cwd().access(legacy, .{})) {
            alloc.free(new_path);
            return legacy;
        } else |_| {
            alloc.free(legacy);
        }
    };
    return new_path;
}

/// Resolve the canonical (new) `~/.simbacode/sidebar.json` for writing.
pub fn saveStorePath(alloc: Allocator) ?[:0]u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fs.path.joinZ(alloc, &.{ home, ".simbacode", "sidebar.json" }) catch null;
}

/// Load the persisted store. Returns an empty store when the file is absent
/// (first run) or malformed (corrupt) — never auto-imports `~/git`.
pub fn load(alloc: Allocator) Store {
    const path = storePath(alloc) orelse return .{};
    defer alloc.free(path);
    return loadFrom(alloc, path);
}

/// Load the store from an explicit file path. Exposed for hermetic tests so
/// they don't depend on `$HOME` / `setenv` interacting with the libc/no-libc
/// `std.posix.getenv` snapshot semantics.
pub fn loadFrom(alloc: Allocator, path: []const u8) Store {
    var store: Store = .{};

    const data = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| {
        // ENOENT on first run is expected and silent; anything else is logged.
        if (err != error.FileNotFound) {
            log.warn("sidebar: cannot read {s}: {}", .{ path, err });
        }
        return store;
    };
    defer alloc.free(data);

    // Parse the v2 shape first (structured roots). If that fails, fall back
    // to the legacy v1 shape (flat string roots) so old files upgrade
    // transparently. A file that parses as neither yields an empty store.
    const parsed = std.json.parseFromSlice(
        Wire,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return loadV1(alloc, data);
    };
    defer parsed.deinit();

    for (parsed.value.roots) |r| {
        // Skip empty and non-absolute paths. `scanPaths` feeds local roots to
        // `std.fs.openDirAbsolute`, whose `assert(isAbsolute)` would PANIC on a
        // relative path — a hand-edited/foreign file must never crash startup.
        if (r.path.len == 0 or !std.fs.path.isAbsolute(r.path)) {
            if (r.path.len > 0) log.warn("sidebar: skipping non-absolute root {s}", .{r.path});
            continue;
        }
        if (r.host) |h| {
            if (h.alias.len == 0) {
                log.warn("sidebar: skipping remote root with empty host: {s}", .{r.path});
                continue;
            }
            const spec: RemoteSpec = .{
                .alias = alloc.dupeZ(u8, h.alias) catch continue,
                .username = if (h.username) |u| (if (u.len > 0) alloc.dupeZ(u8, u) catch null else null) else null,
                .port = h.port,
            };
            // addRemote dupes its inputs, so free our temporary spec after.
            defer spec.deinit(alloc);
            _ = store.addRemote(alloc, spec, r.path) catch |err| {
                log.debug("sidebar: skipping remote root {s}: {}", .{ r.path, err });
                continue;
            };
        } else {
            _ = store.add(alloc, r.path) catch |err| {
                log.debug("sidebar: skipping root {s}: {}", .{ r.path, err });
                continue;
            };
        }
    }

    // Restore the last-browsed folder for the `+` picker. Ignore non-absolute
    // values (hand-edited / foreign files) — useless as an initial folder.
    if (parsed.value.lastFolder) |lf| {
        if (lf.len > 0 and std.fs.path.isAbsolute(lf)) {
            store.setLastFolder(alloc, lf) catch |err| {
                log.debug("sidebar: cannot restore last folder: {}", .{err});
            };
        }
    }
    return store;
}

/// Load the legacy v1 shape (flat string roots). Returns an empty store on
/// parse failure. Local-only (v1 had no remote concept).
fn loadV1(alloc: Allocator, data: []const u8) Store {
    var store: Store = .{};
    const parsed = std.json.parseFromSlice(
        WireV1,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("sidebar: cannot parse (v1) {} (starting empty)", .{err});
        return store;
    };
    defer parsed.deinit();
    for (parsed.value.roots) |r| {
        if (r.len == 0 or !std.fs.path.isAbsolute(r)) {
            if (r.len > 0) log.warn("sidebar: skipping non-absolute root {s}", .{r});
            continue;
        }
        _ = store.add(alloc, r) catch continue;
    }
    if (parsed.value.lastFolder) |lf| {
        if (lf.len > 0 and std.fs.path.isAbsolute(lf)) {
            store.setLastFolder(alloc, lf) catch {};
        }
    }
    return store;
}

/// Persist `store` to `~/.simbacode/sidebar.json`, creating the parent
/// directory as needed. Writes atomically via a temp file + rename so a
/// crash mid-write never truncates the user's curation. Always writes to the
/// canonical (new) location, completing migration off any legacy path.
pub fn save(alloc: Allocator, store: *const Store) !void {
    const path = saveStorePath(alloc) orelse return error.NoHome;
    defer alloc.free(path);
    return saveTo(alloc, path, store);
}

/// Persist `store` to an explicit file path. Exposed for hermetic tests.
pub fn saveTo(alloc: Allocator, path: []const u8, store: *const Store) !void {
    // Ensure the parent directory exists.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("sidebar: cannot create dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    // Build the JSON payload (v2 structured roots).
    var wire_roots = try alloc.alloc(WireRoot, store.roots.items.len);
    defer alloc.free(wire_roots);
    for (store.roots.items, 0..) |*r, i| {
        wire_roots[i] = .{
            .path = r.path,
            .host = if (r.host) |*h| WireRemote{
                .alias = h.alias,
                .username = if (h.username) |u| u else null,
                .port = h.port,
            } else null,
        };
    }
    const wire: Wire = .{
        .schemaVersion = schema_version,
        .roots = wire_roots,
        .lastFolder = store.last_folder,
    };

    const json = try std.json.Stringify.valueAlloc(alloc, wire, .{ .whitespace = .indent_2 });
    defer alloc.free(json);

    // Atomic write: temp file in the same dir, then rename over the target.
    // Clean up the temp file if anything after creation fails.
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

test "store add/remove/contains" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    try std.testing.expect(try store.add(alloc, "/a"));
    try std.testing.expect(try store.add(alloc, "/b"));
    // Duplicate is rejected.
    try std.testing.expect(!try store.add(alloc, "/a"));
    try std.testing.expectEqual(@as(usize, 2), store.roots.items.len);

    try std.testing.expect(store.contains("/a"));
    try std.testing.expect(!store.contains("/c"));

    try std.testing.expect(store.remove(alloc, "/a"));
    try std.testing.expect(!store.remove(alloc, "/a"));
    try std.testing.expectEqual(@as(usize, 1), store.roots.items.len);
    try std.testing.expect(std.mem.eql(u8, store.roots.items[0].path, "/b"));
}

test "loadFrom missing file yields empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, ".simbacode", "sidebar.json" });
    defer alloc.free(path);

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.roots.items.len);
}

test "saveTo then loadFrom round-trips roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, ".simbacode", "sidebar.json" });
    defer alloc.free(path);

    {
        var store: Store = .{};
        defer store.deinit(alloc);
        _ = try store.add(alloc, "/home/u/proj-a");
        _ = try store.add(alloc, "/home/u/proj-b");
        try saveTo(alloc, path, &store);
    }

    var loaded = loadFrom(alloc, path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.roots.items.len);
    try std.testing.expect(loaded.contains("/home/u/proj-a"));
    try std.testing.expect(loaded.contains("/home/u/proj-b"));
}

test "setLastFolder round-trips through saveTo/loadFrom" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, ".simbacode", "sidebar.json" });
    defer alloc.free(path);

    {
        var store: Store = .{};
        defer store.deinit(alloc);
        _ = try store.add(alloc, "/home/u/git/proj");
        try store.setLastFolder(alloc, "/home/u/git");
        // Replacing keeps only the latest value (no leak).
        try store.setLastFolder(alloc, "/home/u/git");
        try saveTo(alloc, path, &store);
    }

    var loaded = loadFrom(alloc, path);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.last_folder != null);
    try std.testing.expectEqualStrings("/home/u/git", loaded.last_folder.?);
}

test "loadFrom ignores non-absolute lastFolder" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sidebar.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{
        .sub_path = "sidebar.json",
        .data =
        \\{ "schemaVersion": 1, "roots": [], "lastFolder": "relative/dir" }
        ,
    });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expect(store.last_folder == null);
}

test "loadFrom corrupt file yields empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sidebar.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{ .sub_path = "sidebar.json", .data = "{ not valid json " });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), store.roots.items.len);
}

test "loadFrom skips non-absolute roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sidebar.json" });
    defer alloc.free(path);
    // Well-formed JSON, but a relative root would PANIC in openDirAbsolute if
    // it reached scanPaths. Only the absolute entry must survive load.
    try tmp.dir.writeFile(.{
        .sub_path = "sidebar.json",
        .data =
        \\{ "schemaVersion": 1, "roots": ["relative/path", "/abs/keep", ""] }
        ,
    });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), store.roots.items.len);
    try std.testing.expect(store.contains("/abs/keep"));
    try std.testing.expect(!store.contains("relative/path"));
}

test "loadFrom migrates a v1 (flat string roots) file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sidebar.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{
        .sub_path = "sidebar.json",
        .data =
        \\{ "schemaVersion": 1, "roots": ["/home/u/a", "/home/u/b"], "lastFolder": "/home/u" }
        ,
    });

    var store = loadFrom(alloc, path);
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), store.roots.items.len);
    try std.testing.expect(store.contains("/home/u/a"));
    try std.testing.expect(store.contains("/home/u/b"));
    try std.testing.expect(store.roots.items[0].host == null);
    try std.testing.expect(store.last_folder != null);
    try std.testing.expectEqualStrings("/home/u", store.last_folder.?);
}

test "addRemote + containsRemote + remove distinguish host" {
    const alloc = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(alloc);

    const host_a: RemoteSpec = .{ .alias = try alloc.dupeZ(u8, "server"), .username = try alloc.dupeZ(u8, "alice"), .port = 2222 };
    defer host_a.deinit(alloc);
    const host_b: RemoteSpec = .{ .alias = try alloc.dupeZ(u8, "server"), .username = null, .port = null };
    defer host_b.deinit(alloc);

    try std.testing.expect(try store.addRemote(alloc, host_a, "/srv/proj"));
    // Same host + path again: rejected.
    try std.testing.expect(!try store.addRemote(alloc, host_a, "/srv/proj"));
    // Same path, different host identity: added as distinct.
    try std.testing.expect(try store.addRemote(alloc, host_b, "/srv/proj"));
    try std.testing.expectEqual(@as(usize, 2), store.roots.items.len);

    // A local root with the same path does not collide with the remotes.
    try std.testing.expect(try store.add(alloc, "/srv/proj"));
    try std.testing.expectEqual(@as(usize, 3), store.roots.items.len);
    try std.testing.expect(store.contains("/srv/proj"));

    try std.testing.expect(store.containsRemote(host_a, "/srv/proj"));
    try std.testing.expect(store.removeRemote(alloc, host_a, "/srv/proj"));
    try std.testing.expect(!store.containsRemote(host_a, "/srv/proj"));
    try std.testing.expectEqual(@as(usize, 2), store.roots.items.len);
}

test "saveTo then loadFrom round-trips a remote root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "sidebar.json" });
    defer alloc.free(path);

    {
        var store: Store = .{};
        defer store.deinit(alloc);
        _ = try store.add(alloc, "/home/u/local");
        const host: RemoteSpec = .{ .alias = try alloc.dupeZ(u8, "box"), .username = try alloc.dupeZ(u8, "bob"), .port = 22 };
        defer host.deinit(alloc);
        _ = try store.addRemote(alloc, host, "/remote/proj");
        try saveTo(alloc, path, &store);
    }

    var loaded = loadFrom(alloc, path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.roots.items.len);
    // Local root preserved.
    try std.testing.expect(loaded.contains("/home/u/local"));
    // Remote root preserved with host fields.
    var found_remote = false;
    for (loaded.roots.items) |*r| {
        if (r.host) |h| {
            found_remote = true;
            try std.testing.expectEqualStrings("box", h.alias);
            try std.testing.expectEqualStrings("bob", h.username.?);
            try std.testing.expectEqual(@as(u16, 22), h.port.?);
            try std.testing.expectEqualStrings("/remote/proj", r.path);
        }
    }
    try std.testing.expect(found_remote);
}
