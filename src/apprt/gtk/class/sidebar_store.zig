//! Persistence for the user-curated sidebar project roots.
//!
//! Issue #21: instead of auto-scanning every repo under `~/git`, the sidebar
//! lists only folders the user has explicitly added via the `+` button. The
//! chosen set is persisted to `~/.supacode/sidebar.json` and read on startup.
//!
//! macOS source of truth: `~/.supacode/sidebar.json` (a far richer nested
//! schema of sections/buckets/items; see Supacode's `SidebarState.swift`). On
//! Linux we persist only the flat list of project roots we need — the file is
//! versioned so the schema can grow later without breaking older readers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.supacode_sidebar);

/// Current on-disk schema version for the Linux sidebar store.
pub const schema_version: u32 = 1;

/// In-memory model of the persisted sidebar state. Owns its strings.
pub const Store = struct {
    /// User-added project roots (absolute paths). Order is preserved.
    roots: std.ArrayListUnmanaged([:0]u8) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        for (self.roots.items) |r| alloc.free(r);
        self.roots.deinit(alloc);
    }

    /// True if `path` is already present in the roots list.
    pub fn contains(self: *const Store, path: []const u8) bool {
        for (self.roots.items) |r| {
            if (std.mem.eql(u8, r, path)) return true;
        }
        return false;
    }

    /// Add `path` if not already present. Returns true if it was added.
    /// Takes ownership of a fresh copy of `path`.
    pub fn add(self: *Store, alloc: Allocator, path: []const u8) !bool {
        if (self.contains(path)) return false;
        const copy = try alloc.dupeZ(u8, path);
        errdefer alloc.free(copy);
        try self.roots.append(alloc, copy);
        return true;
    }

    /// Remove `path` if present. Returns true if it was removed.
    pub fn remove(self: *Store, alloc: Allocator, path: []const u8) bool {
        for (self.roots.items, 0..) |r, i| {
            if (std.mem.eql(u8, r, path)) {
                const removed = self.roots.orderedRemove(i);
                alloc.free(removed);
                return true;
            }
        }
        return false;
    }
};

/// JSON wire shape. Kept intentionally minimal and forward-compatible: unknown
/// fields are ignored on load, and absence of the file means "start empty"
/// (issue #21 migration rule: do NOT auto-import `~/git`).
const Wire = struct {
    schemaVersion: u32 = schema_version,
    roots: []const []const u8 = &.{},
};

/// Resolve `~/.supacode/sidebar.json`. Caller owns the result.
pub fn storePath(alloc: Allocator) ?[:0]u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fs.path.joinZ(alloc, &.{ home, ".supacode", "sidebar.json" }) catch null;
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

    const parsed = std.json.parseFromSlice(
        Wire,
        alloc,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("sidebar: cannot parse {s}: {} (starting empty)", .{ path, err });
        return store;
    };
    defer parsed.deinit();

    for (parsed.value.roots) |r| {
        // Skip empty and non-absolute entries. `scanPaths` feeds roots to
        // `std.fs.openDirAbsolute`, whose `assert(isAbsolute)` would PANIC
        // (not return an error) on a relative path — a hand-edited or foreign
        // `sidebar.json` must never be able to crash startup. This upholds the
        // module's crash-tolerance contract.
        if (r.len == 0 or !std.fs.path.isAbsolute(r)) {
            if (r.len > 0) log.warn("sidebar: skipping non-absolute root {s}", .{r});
            continue;
        }
        _ = store.add(alloc, r) catch |err| {
            log.debug("sidebar: skipping root {s}: {}", .{ r, err });
            continue;
        };
    }
    return store;
}

/// Persist `store` to `~/.supacode/sidebar.json`, creating the parent
/// directory as needed. Writes atomically via a temp file + rename so a
/// crash mid-write never truncates the user's curation.
pub fn save(alloc: Allocator, store: *const Store) !void {
    const path = storePath(alloc) orelse return error.NoHome;
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

    // Build the JSON payload.
    var roots = try alloc.alloc([]const u8, store.roots.items.len);
    defer alloc.free(roots);
    for (store.roots.items, 0..) |r, i| roots[i] = r;
    const wire: Wire = .{ .schemaVersion = schema_version, .roots = roots };

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
    try std.testing.expect(std.mem.eql(u8, store.roots.items[0], "/b"));
}

test "loadFrom missing file yields empty store" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, ".supacode", "sidebar.json" });
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
    const path = try std.fs.path.join(alloc, &.{ dir, ".supacode", "sidebar.json" });
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
