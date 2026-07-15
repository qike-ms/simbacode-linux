//! SSH command construction for remote repositories and worktrees (issue #32).
//!
//! A remote worktree lives on an SSH host: git operations (worktree list,
//! status, worktree add) run over `ssh`, and its terminal surface is an `ssh`
//! session `cd`'d into the worktree. This module is the pure, allocation-based
//! Zig port of supacode's `SSHCommand.swift` + `RemoteHost.swift`, with the
//! same two output shapes:
//!
//!   * `invocation(...)` — an argv (`[][]const u8`) for `std.process.Child`,
//!     used for the git shell-outs. ssh receives the remote command as a
//!     single argument and hands it to the remote login shell verbatim.
//!   * `commandLine(...)` — a single string for a parent `/bin/sh -c` (the
//!     terminal surface command), so the remote command is quoted for BOTH the
//!     local shell and (once) the remote login shell.
//!
//! Connection multiplexing: all invocations share an ssh ControlMaster
//! (`~/.ssh/simbacode-%C`) so a burst of git calls plus the open terminal reuse
//! one TCP connection and one authentication.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The local `ssh` executable. Fixed path (matches supacode) so a hostile
/// `PATH` can't shadow it.
pub const ssh_executable_path = "/usr/bin/ssh";

/// `%C` is ssh's hash of (local host, remote host, port, user): stable per
/// connection and short, keeping the control socket well under the
/// `sockaddr_un.sun_path` limit. ssh expands both `~` and `%C` itself.
pub const default_control_path = "~/.ssh/simbacode-%C";

/// Describes an SSH destination a worktree can live on. `alias` is whatever
/// `ssh` accepts as a host: a `~/.ssh/config` alias or a bare hostname.
/// `username` / `port` are optional overrides for callers that don't want to
/// encode them in ssh config. All fields are borrowed; the struct owns
/// nothing.
pub const RemoteHost = struct {
    alias: []const u8,
    username: ?[]const u8 = null,
    port: ?u16 = null,

    /// The `user@host` (or bare `host`) token passed to `ssh`. The host is left
    /// bare even for an IPv6 literal, since the ssh CLI wants `user@::1`, not
    /// the bracketed URL form. Caller owns the result.
    pub fn sshDestination(self: RemoteHost, alloc: Allocator) ![]u8 {
        if (self.username) |u| {
            if (u.len > 0) return std.fmt.allocPrint(alloc, "{s}@{s}", .{ u, self.alias });
        }
        return alloc.dupe(u8, self.alias);
    }

    /// Extra `ssh` option arguments derived from the host (currently just the
    /// port). Always shell-safe tokens. Appends to `out`; caller owns the
    /// duped strings pushed onto `out`.
    pub fn appendOptionArguments(self: RemoteHost, alloc: Allocator, out: *std.ArrayListUnmanaged([]const u8)) !void {
        if (self.port) |p| {
            try out.append(alloc, try alloc.dupe(u8, "-p"));
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{d}", .{p}));
        }
    }

    /// Parse `[user@]host[:port]` into a host. A bracketed IPv6 host keeps its
    /// colons inside the brackets. Returns null if the host part is empty.
    /// Borrows into `authority`; the returned host's slices point into it.
    pub fn parseAuthority(authority: []const u8) ?RemoteHost {
        const trimmed = std.mem.trim(u8, authority, " \t");
        if (trimmed.len == 0) return null;

        var user: ?[]const u8 = null;
        var host_port: []const u8 = trimmed;
        if (std.mem.lastIndexOfScalar(u8, trimmed, '@')) |at| {
            user = trimmed[0..at];
            host_port = trimmed[at + 1 ..];
        }
        if (host_port.len == 0 or host_port[0] == '-') return null;
        if (user) |u| if (u.len == 0 or u[0] == '-') return null;

        var host: []const u8 = undefined;
        var port: ?u16 = null;
        if (host_port[0] == '[') {
            // Bracketed IPv6: [host] or [host]:port. Reject malformed tails or
            // ports rather than silently changing the target/default port.
            const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return null;
            host = host_port[1..close];
            const after = host_port[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':' or after.len == 1) return null;
                port = std.fmt.parseInt(u16, after[1..], 10) catch return null;
            }
        } else if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
            // host:port only when the tail parses as a port; otherwise the
            // colon belongs to a bare IPv6 literal, so keep the whole thing.
            if (std.fmt.parseInt(u16, host_port[colon + 1 ..], 10)) |p| {
                host = host_port[0..colon];
                port = p;
            } else |_| {
                host = host_port;
            }
        } else {
            host = host_port;
        }
        if (host.len == 0 or host[0] == '-') return null;

        return .{
            .alias = host,
            .username = if (user) |u| (if (u.len > 0) u else null) else null,
            .port = port,
        };
    }
};

/// POSIX single-quote a token so a shell passes it through literally. Any
/// embedded `'` becomes `'\''`. Caller owns the result.
pub fn shellQuote(alloc: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '\'');
    for (value) |c| {
        if (c == '\'') {
            try buf.appendSlice(alloc, "'\\''");
        } else {
            try buf.append(alloc, c);
        }
    }
    try buf.append(alloc, '\'');
    return buf.toOwnedSlice(alloc);
}

/// The command string the *remote* shell runs for a local
/// `(executable, arguments, workingDirectory)` invocation. A working directory
/// becomes `cd -- <dir> && exec ...` so the remote process starts in the
/// worktree and replaces the shell (signals / exit status map straight
/// through). Caller owns the result.
pub fn remoteCommand(
    alloc: Allocator,
    executable: []const u8,
    arguments: []const []const u8,
    working_directory: ?[]const u8,
) ![]u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(alloc);

    const exe_q = try shellQuote(alloc, executable);
    defer alloc.free(exe_q);
    try parts.appendSlice(alloc, exe_q);
    for (arguments) |arg| {
        const arg_q = try shellQuote(alloc, arg);
        defer alloc.free(arg_q);
        try parts.append(alloc, ' ');
        try parts.appendSlice(alloc, arg_q);
    }

    if (working_directory) |wd| {
        const dir_q = try shellQuote(alloc, wd);
        defer alloc.free(dir_q);
        const invocation_str = try parts.toOwnedSlice(alloc);
        defer alloc.free(invocation_str);
        return std.fmt.allocPrint(alloc, "cd -- {s} && exec {s}", .{ dir_q, invocation_str });
    }
    return parts.toOwnedSlice(alloc);
}

/// Wrap a remote command so it runs under a **login** shell. ssh's default
/// `$SHELL -c <cmd>` is non-interactive AND non-login, so it can inherit only a
/// bare PATH and miss tools installed under a login profile. A login shell
/// reads the profile, restoring the full PATH. `$SHELL` is expanded by ssh's
/// own outer shell; `exec` replaces it so signals / exit status pass through.
/// Caller owns the result.
pub fn loginShellWrapped(alloc: Allocator, remote_script: []const u8) ![]u8 {
    const script_q = try shellQuote(alloc, remote_script);
    defer alloc.free(script_q);
    return std.fmt.allocPrint(alloc, "exec \"$SHELL\" -l -c {s}", .{script_q});
}

/// Control-multiplexing options: `auto` opens a master if none exists and
/// reuses it otherwise; `ControlPersist` keeps it warm briefly after the last
/// client so a burst of git calls shares one connection. Appends to `out`.
pub fn appendControlOptions(alloc: Allocator, out: *std.ArrayListUnmanaged([]const u8), control_path: []const u8) !void {
    try out.append(alloc, try alloc.dupe(u8, "-o"));
    try out.append(alloc, try alloc.dupe(u8, "ControlMaster=auto"));
    try out.append(alloc, try alloc.dupe(u8, "-o"));
    try out.append(alloc, try std.fmt.allocPrint(alloc, "ControlPath={s}", .{control_path}));
    try out.append(alloc, try alloc.dupe(u8, "-o"));
    try out.append(alloc, try alloc.dupe(u8, "ControlPersist=10m"));
}

/// Options for a non-interactive git shell-out. `BatchMode` fails fast instead
/// of blocking on a password / host-key prompt; `ConnectTimeout` bounds the
/// TCP+handshake; `ServerAlive*` aborts a connection that stalls mid-command.
/// A live ControlMaster (an open terminal) bypasses auth, so the common case is
/// fast. Appends to `out`.
pub fn appendBatchOptions(alloc: Allocator, out: *std.ArrayListUnmanaged([]const u8)) !void {
    const opts = [_][]const u8{
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=2",
    };
    for (opts) |o| try out.append(alloc, try alloc.dupe(u8, o));
}

/// Full local `ssh` argv for `std.process.Child`, running `executable` +
/// `arguments` in `working_directory` on `host`. The remote command is a
/// single argument; ssh hands it to the remote login shell verbatim.
///
/// `batch` adds fail-fast non-interactive options (for background git calls);
/// leave it false for anything that may need to prompt. `allocate_tty` adds
/// `-tt` (needed for an interactive terminal, not for git).
///
/// Returns an owned argv: caller frees each element and the slice (see
/// `freeArgv`).
pub fn invocation(
    alloc: Allocator,
    host: RemoteHost,
    executable: []const u8,
    arguments: []const []const u8,
    working_directory: ?[]const u8,
    opts: struct {
        batch: bool = true,
        allocate_tty: bool = false,
        control_path: []const u8 = default_control_path,
    },
) ![][]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer freeArgvList(alloc, &argv);

    try argv.append(alloc, try alloc.dupe(u8, ssh_executable_path));
    try appendControlOptions(alloc, &argv, opts.control_path);
    if (opts.batch) try appendBatchOptions(alloc, &argv);
    if (opts.allocate_tty) try argv.append(alloc, try alloc.dupe(u8, "-tt"));
    try host.appendOptionArguments(alloc, &argv);

    const dest = try host.sshDestination(alloc);
    try argv.append(alloc, dest);

    const remote = try remoteCommand(alloc, executable, arguments, working_directory);
    defer alloc.free(remote);
    const wrapped = try loginShellWrapped(alloc, remote);
    try argv.append(alloc, wrapped);

    return argv.toOwnedSlice(alloc);
}

/// Full `ssh` command line as a single string for a parent `/bin/sh -c` (the
/// terminal surface command). The fixed option tokens are shell-safe and stay
/// unquoted (so ssh still expands `~` / `%C` in ControlPath); the
/// login-shell-wrapped remote command is quoted for the local shell. Opens an
/// interactive login shell in `working_directory` (or the remote home when
/// null). Caller owns the result.
pub fn terminalCommandLine(
    alloc: Allocator,
    host: RemoteHost,
    working_directory: ?[]const u8,
    control_path: []const u8,
) ![:0]u8 {
    // The remote command is a login shell; cd into the worktree first.
    const remote_script: []u8 = if (working_directory) |wd| blk: {
        const dir_q = try shellQuote(alloc, wd);
        defer alloc.free(dir_q);
        break :blk try std.fmt.allocPrint(alloc, "cd -- {s} && exec \"$SHELL\" -l", .{dir_q});
    } else try alloc.dupe(u8, "exec \"$SHELL\" -l");
    defer alloc.free(remote_script);

    // Local-shell quote of the (already remote-safe) script.
    const script_q = try shellQuote(alloc, remote_script);
    defer alloc.free(script_q);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line.deinit(alloc);

    try line.appendSlice(alloc, ssh_executable_path);
    // Control options (unquoted, shell-safe).
    try line.appendSlice(alloc, " -o ControlMaster=auto -o ControlPath=");
    try line.appendSlice(alloc, control_path);
    try line.appendSlice(alloc, " -o ControlPersist=10m");
    // Interactive terminal: allocate a TTY.
    try line.appendSlice(alloc, " -tt");
    // Port option, if any (shell-safe).
    if (host.port) |p| {
        try line.appendSlice(alloc, " -p ");
        try std.fmt.format(line.writer(alloc), "{d}", .{p});
    }
    // Destination.
    const dest = try host.sshDestination(alloc);
    defer alloc.free(dest);
    const dest_q = try shellQuote(alloc, dest);
    defer alloc.free(dest_q);
    try line.append(alloc, ' ');
    try line.appendSlice(alloc, dest_q);
    // Remote command (quoted for the local shell).
    try line.append(alloc, ' ');
    try line.appendSlice(alloc, script_q);

    return line.toOwnedSliceSentinel(alloc, 0);
}

/// Open an interactive remote terminal, resume an exact agent session, then
/// leave the user at the same remote worktree's login shell when the agent
/// exits. `resume_command` is already restricted to an executable prefix plus
/// an allowlisted session id by the caller.
pub fn terminalCommandThenShell(
    alloc: Allocator,
    host: RemoteHost,
    working_directory: []const u8,
    resume_command: []const u8,
    control_path: []const u8,
) ![:0]u8 {
    const dir_q = try shellQuote(alloc, working_directory);
    defer alloc.free(dir_q);
    // Run the resume inside a login shell so profile-provided PATH entries are
    // available, then return to an interactive login shell in the same cwd.
    const login_script = try std.fmt.allocPrint(
        alloc,
        "{s}; exec \"$SHELL\" -l",
        .{resume_command},
    );
    defer alloc.free(login_script);
    const login_script_q = try shellQuote(alloc, login_script);
    defer alloc.free(login_script_q);
    const remote_script = try std.fmt.allocPrint(
        alloc,
        "cd -- {s} && SIMBACODE_SURFACE_ID=${{SIMBACODE_SURFACE_ID:-remote}} " ++
            "SIMBACODE_TTY=$(tty) SIMBACODE_SOCKET_PATH= exec \"$SHELL\" -l -c {s}",
        .{ dir_q, login_script_q },
    );
    defer alloc.free(remote_script);
    const script_q = try shellQuote(alloc, remote_script);
    defer alloc.free(script_q);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line.deinit(alloc);
    try line.appendSlice(alloc, ssh_executable_path);
    try line.appendSlice(alloc, " -o ControlMaster=auto -o ControlPath=");
    try line.appendSlice(alloc, control_path);
    try line.appendSlice(alloc, " -o ControlPersist=10m -tt");
    if (host.port) |p| try std.fmt.format(line.writer(alloc), " -p {d}", .{p});
    const dest = try host.sshDestination(alloc);
    defer alloc.free(dest);
    const dest_q = try shellQuote(alloc, dest);
    defer alloc.free(dest_q);
    try line.append(alloc, ' ');
    try line.appendSlice(alloc, dest_q);
    try line.append(alloc, ' ');
    try line.appendSlice(alloc, script_q);
    return line.toOwnedSliceSentinel(alloc, 0);
}

/// Free an argv produced by `invocation`.
pub fn freeArgv(alloc: Allocator, argv: [][]const u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

fn freeArgvList(alloc: Allocator, argv: *std.ArrayListUnmanaged([]const u8)) void {
    for (argv.items) |a| alloc.free(a);
    argv.deinit(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sshDestination bare host, user, and empty user" {
    const alloc = std.testing.allocator;
    {
        const h: RemoteHost = .{ .alias = "server" };
        const d = try h.sshDestination(alloc);
        defer alloc.free(d);
        try std.testing.expectEqualStrings("server", d);
    }
    {
        const h: RemoteHost = .{ .alias = "server", .username = "alice" };
        const d = try h.sshDestination(alloc);
        defer alloc.free(d);
        try std.testing.expectEqualStrings("alice@server", d);
    }
    {
        const h: RemoteHost = .{ .alias = "::1", .username = "" };
        const d = try h.sshDestination(alloc);
        defer alloc.free(d);
        try std.testing.expectEqualStrings("::1", d);
    }
}

test "appendOptionArguments emits -p only with a port" {
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeArgvList(alloc, &out);
    const h1: RemoteHost = .{ .alias = "h" };
    try h1.appendOptionArguments(alloc, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    const h2: RemoteHost = .{ .alias = "h", .port = 2222 };
    try h2.appendOptionArguments(alloc, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("-p", out.items[0]);
    try std.testing.expectEqualStrings("2222", out.items[1]);
}

test "parseAuthority rejects option-like hosts and users" {
    try std.testing.expect(RemoteHost.parseAuthority("-oProxyCommand=bad") == null);
    try std.testing.expect(RemoteHost.parseAuthority("user@-bad") == null);
    try std.testing.expect(RemoteHost.parseAuthority("-oProxyCommand=bad@host") == null);
}

test "parseAuthority rejects malformed bracketed IPv6 ports" {
    try std.testing.expect(RemoteHost.parseAuthority("[::1]:bad") == null);
    try std.testing.expect(RemoteHost.parseAuthority("[::1]:") == null);
    try std.testing.expect(RemoteHost.parseAuthority("[::1]junk") == null);
}

test "parseAuthority variants" {
    // bare host
    {
        const h = RemoteHost.parseAuthority("server").?;
        try std.testing.expectEqualStrings("server", h.alias);
        try std.testing.expect(h.username == null);
        try std.testing.expect(h.port == null);
    }
    // user@host:port
    {
        const h = RemoteHost.parseAuthority("alice@server:2222").?;
        try std.testing.expectEqualStrings("server", h.alias);
        try std.testing.expectEqualStrings("alice", h.username.?);
        try std.testing.expectEqual(@as(u16, 2222), h.port.?);
    }
    // bracketed IPv6 with port
    {
        const h = RemoteHost.parseAuthority("[::1]:22").?;
        try std.testing.expectEqualStrings("::1", h.alias);
        try std.testing.expectEqual(@as(u16, 22), h.port.?);
    }
    // bare IPv6 (colons, non-numeric final segment) stays whole. NOTE: a bare
    // IPv6 whose last segment parses as a number (e.g. "fe80::1") is ambiguous
    // and mis-splits into host+port — same as supacode; bracket it ("[fe80::1]")
    // to be unambiguous.
    {
        const h = RemoteHost.parseAuthority("fe80::ab").?;
        try std.testing.expectEqualStrings("fe80::ab", h.alias);
        try std.testing.expect(h.port == null);
    }
    // empty / invalid
    try std.testing.expect(RemoteHost.parseAuthority("") == null);
    try std.testing.expect(RemoteHost.parseAuthority("   ") == null);
    try std.testing.expect(RemoteHost.parseAuthority("user@") == null);
}

test "shellQuote escapes single quotes" {
    const alloc = std.testing.allocator;
    {
        const q = try shellQuote(alloc, "plain");
        defer alloc.free(q);
        try std.testing.expectEqualStrings("'plain'", q);
    }
    {
        const q = try shellQuote(alloc, "it's");
        defer alloc.free(q);
        try std.testing.expectEqualStrings("'it'\\''s'", q);
    }
}

test "remoteCommand with and without working directory" {
    const alloc = std.testing.allocator;
    {
        const c = try remoteCommand(alloc, "git", &.{ "status", "--porcelain" }, null);
        defer alloc.free(c);
        try std.testing.expectEqualStrings("'git' 'status' '--porcelain'", c);
    }
    {
        const c = try remoteCommand(alloc, "git", &.{"status"}, "/home/u/proj");
        defer alloc.free(c);
        try std.testing.expectEqualStrings("cd -- '/home/u/proj' && exec 'git' 'status'", c);
    }
}

test "loginShellWrapped" {
    const alloc = std.testing.allocator;
    const w = try loginShellWrapped(alloc, "cd -- '/x' && exec 'git' 'status'");
    defer alloc.free(w);
    try std.testing.expectEqualStrings(
        "exec \"$SHELL\" -l -c 'cd -- '\\''/x'\\'' && exec '\\''git'\\'' '\\''status'\\'''",
        w,
    );
}

test "invocation builds a full ssh argv (git shell-out)" {
    const alloc = std.testing.allocator;
    const host: RemoteHost = .{ .alias = "server", .username = "alice", .port = 2222 };
    const argv = try invocation(
        alloc,
        host,
        "git",
        &.{ "worktree", "list", "--porcelain" },
        "/home/alice/proj",
        .{ .batch = true, .control_path = "~/.ssh/simbacode-%C" },
    );
    defer freeArgv(alloc, argv);

    try std.testing.expectEqualStrings("/usr/bin/ssh", argv[0]);
    // Control options.
    try std.testing.expectEqualStrings("-o", argv[1]);
    try std.testing.expectEqualStrings("ControlMaster=auto", argv[2]);
    try std.testing.expectEqualStrings("-o", argv[3]);
    try std.testing.expectEqualStrings("ControlPath=~/.ssh/simbacode-%C", argv[4]);
    try std.testing.expectEqualStrings("-o", argv[5]);
    try std.testing.expectEqualStrings("ControlPersist=10m", argv[6]);
    // Batch options.
    try std.testing.expectEqualStrings("-o", argv[7]);
    try std.testing.expectEqualStrings("BatchMode=yes", argv[8]);
    // ...find the destination and remote command at the tail.
    try std.testing.expectEqualStrings("alice@server", argv[argv.len - 2]);
    try std.testing.expectEqualStrings(
        "exec \"$SHELL\" -l -c 'cd -- '\\''/home/alice/proj'\\'' && exec '\\''git'\\'' '\\''worktree'\\'' '\\''list'\\'' '\\''--porcelain'\\'''",
        argv[argv.len - 1],
    );
    // The port option appears before the destination.
    var saw_port = false;
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-p")) {
            saw_port = true;
            try std.testing.expectEqualStrings("2222", argv[i + 1]);
        }
    }
    try std.testing.expect(saw_port);
}

test "terminalCommandThenShell resumes remotely and preserves terminal" {
    const alloc = std.testing.allocator;
    const host: RemoteHost = .{ .alias = "server", .username = "alice", .port = 2222 };
    const line = try terminalCommandThenShell(
        alloc,
        host,
        "/srv/project one",
        "pi --session abc-123",
        "~/.ssh/simbacode-%C",
    );
    defer alloc.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "alice@server") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-p 2222") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "pi --session abc-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "SIMBACODE_SURFACE_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "SIMBACODE_TTY=$(tty)") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "exec \"$SHELL\" -l") != null);
}

test "terminalCommandLine opens a login shell in the worktree" {
    const alloc = std.testing.allocator;
    const host: RemoteHost = .{ .alias = "server" };
    const line = try terminalCommandLine(alloc, host, "/home/u/proj", "~/.ssh/simbacode-%C");
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/simbacode-%C -o ControlPersist=10m -tt 'server' 'cd -- '\\''/home/u/proj'\\'' && exec \"$SHELL\" -l'",
        line,
    );
}

test "terminalCommandLine without working dir" {
    const alloc = std.testing.allocator;
    const host: RemoteHost = .{ .alias = "server", .port = 2022 };
    const line = try terminalCommandLine(alloc, host, null, "~/.ssh/simbacode-%C");
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "/usr/bin/ssh -o ControlMaster=auto -o ControlPath=~/.ssh/simbacode-%C -o ControlPersist=10m -tt -p 2022 'server' 'exec \"$SHELL\" -l'",
        line,
    );
}
