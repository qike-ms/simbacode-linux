//! Supacode agent-presence hook installer (Linux port).
//!
//! Mirrors the macOS source's per-agent hook installers
//! (`AgentHookSettingsCommand`, `AgentPresenceOSC`, and the
//! `{Codex,Claude,Copilot,Kiro}HookSettings` / `OpenCodePluginContent` /
//! `PiExtensionContent` builders). Each agent gets a `# supacode-managed-hook`
//! guarded shell command (or a plugin/extension that runs it) written into the
//! agent's NATIVE config, so the agent emits OSC-3008 agent-presence events to
//! its controlling tty. The command is inert outside Supacode because it is
//! guarded on `[ -n "${SUPACODE_SURFACE_ID:-}" ]` (the surface env var injected
//! by `surface.zig`).
//!
//! The hook command shape is byte-for-byte faithful to
//! `AgentHookSettingsCommand.compositeCommand` /
//! `AgentPresenceOSC.{ttyResolveSnippet,emitShell}` so the wire stays
//! compatible with the macOS app and the same hooks could run on either.
//!
//! Install + uninstall are idempotent: the trailing `# supacode-managed-hook`
//! sentinel is the SOLE ownership marker (`AgentHookCommandOwnership`), so the
//! installer only ever edits its own blocks and never clobbers user-authored
//! hooks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.supacode_agent_hooks);

/// Sentinel comment appended to every Supacode-installed hook command. The SOLE
/// source of truth for ownership (mirrors
/// `AgentHookSettingsCommand.ownershipMarker`): install/uninstall key off this
/// and ONLY this, so user-authored hooks are never touched.
pub const ownership_marker = "# supacode-managed-hook";

/// Env var present only on Supacode surfaces; its presence is the
/// no-op-outside-Supacode emit gate (`AgentPresenceOSC.surfaceEnvVar`).
pub const surface_env_var = "SUPACODE_SURFACE_ID";

/// Env var present only on the local host; gates the local `pid=` suffix
/// (`AgentHookSettingsCommand.socketPathEnvVar`). On Linux surface.zig sets it
/// to the surface id so the pid is always emitted for the liveness sweep.
pub const socket_path_env_var = "SUPACODE_SOCKET_PATH";

/// The supported agents, with their config directory under $HOME. Ported from
/// `SkillAgent` (macOS): claude, codex, copilot, kiro, opencode, pi.
pub const Agent = enum {
    claude,
    codex,
    copilot,
    kiro,
    opencode,
    pi,

    /// The agent's rawValue used as the OSC context id (`start=<agent>`). Must
    /// match `SkillAgent.rawValue` byte-for-byte for wire compat.
    pub fn rawValue(self: Agent) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .copilot => "copilot",
            .kiro => "kiro",
            .opencode => "opencode",
            .pi => "pi",
        };
    }

    /// The config directory under $HOME (`SkillAgent.configDirectoryName`).
    pub fn configDir(self: Agent) []const u8 {
        return switch (self) {
            .claude => ".claude",
            .codex => ".codex",
            .copilot => ".copilot",
            .kiro => ".kiro",
            .opencode => ".config/opencode",
            .pi => ".pi/agent",
        };
    }
};

/// Hook events emitted via the OSC-3008 presence path. Matches the macOS
/// `HookEvent` rawValues exactly.
pub const HookEvent = enum {
    session_start,
    session_end,
    busy,
    awaiting_input,
    idle,

    pub fn rawValue(self: HookEvent) []const u8 {
        return @tagName(self);
    }

    /// The OSC 3008 action byte for an event: `session_end` ends a context,
    /// everything else starts/updates one. Descriptive only — the app keys off
    /// `event=` (`AgentPresenceOSC.action(for:)`).
    fn action(self: HookEvent) []const u8 {
        return if (self == .session_end) "end" else "start";
    }
};

/// Shell that resolves `$__tty` to a writable terminal device for the OSC
/// emits. Verbatim port of `AgentPresenceOSC.ttyResolveSnippet`: agents run
/// hooks with no controlling terminal, so the hook recovers the parent agent's
/// tty via `ps -o tty=` and prefixes `/dev/`.
pub const tty_resolve_snippet =
    "__tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d '[:space:]'); " ++
    "case \"$__tty\" in *[0-9]*) __tty=\"/dev/${__tty#/dev/}\";; *) __tty=\"/dev/tty\";; esac";

/// Build the shell `printf` that emits the OSC 3008 presence sequence for
/// `event`. Verbatim port of `AgentPresenceOSC.emitShell`: written to the
/// `$__tty` device, with the `pid=$PPID` suffix gated on the socket-path env
/// var. Caller owns the returned string.
pub fn emitShell(alloc: Allocator, event: HookEvent, agent: Agent) ![]u8 {
    // payload: \033]3008;<action>=<agent>;event=<event>%s\033\\
    // The trailing %s is filled by the shell-built, conditionally-empty pid
    // suffix (`__sp`).
    return std.fmt.allocPrint(
        alloc,
        "__sp=\"\"; [ -n \"${{{s}:-}}\" ] && __sp=\";pid=$PPID\"; " ++
            "printf '\\033]3008;{s}={s};event={s}%s\\033\\\\' \"$__sp\" > \"$__tty\"",
        .{ socket_path_env_var, event.action(), agent.rawValue(), event.rawValue() },
    );
}

/// The OSC guard expression: a surface id present (the no-op-outside-Supacode
/// gate). Verbatim port of `AgentHookSettingsCommand.oscGuardExpr`.
pub const osc_guard_expr = "[ -n \"${" ++ surface_env_var ++ ":-}\" ]";

/// Emit-side byte budgets for the notify leg (AgentPresenceOSC.notify*Budget).
pub const notify_title_byte_budget = 160;
pub const notify_body_byte_budget = 1000;

/// Notify body source keys, in display precedence (AgentPresenceOSC.notifyBodyKeys).
pub const notify_body_keys = "message,last_assistant_message,assistant_response";

/// Portable awk that extracts one JSON string value from the agent's hook JSON
/// on stdin. Verbatim port of `AgentPresenceOSC.notifyExtractAwk`.
pub const notify_extract_awk =
    "function ws(c){return c==\" \"||c==\"\\t\"||c==\"\\n\"||c==\"\\r\"}" ++
    "function fv(s,key,  p,i,n,c,o,e){p=\"\\\"\"key\"\\\"\";i=index(s,p);if(i==0)return \"\";" ++
    "i+=length(p);n=length(s);while(i<=n){if(ws(substr(s,i,1)))i++;else break}" ++
    "if(substr(s,i,1)!=\":\")return \"\";i++;while(i<=n){if(ws(substr(s,i,1)))i++;else break}" ++
    "if(substr(s,i,1)!=\"\\\"\")return \"\";i++;o=\"\";e=0;while(i<=n){c=substr(s,i,1);" ++
    "if(e){o=o c;e=0;i++;continue}if(c==\"\\\\\"){o=o c;e=1;i++;continue}if(c==\"\\\"\")break;o=o c;i++}return o}" ++
    "{d=d $0}END{n=split(keys,ks,\",\");v=\"\";for(j=1;j<=n;j++){v=fv(d,ks[j]);if(v!=\"\")break}" ++
    "if(length(v)>budget+0)v=substr(v,1,budget+0);printf \"%s\",v}";

/// Build the notify-leg shell: read the hook JSON from stdin, extract a bounded
/// title/body via portable awk, base64 each, and emit the OSC 3008 notify.
/// Verbatim port of `AgentPresenceOSC.emitNotifyShell`. `reads_stdin=false`
/// skips the `__in=$(cat)` capture when the caller already set `$__in`.
pub fn emitNotifyShell(alloc: Allocator, agent: Agent, reads_stdin: bool) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}" ++
            "__t=$(printf '%s' \"$__in\" | LC_ALL=C awk -v keys=\"title\" " ++
            "-v budget={d} '{s}' | base64 | tr -d '\n'); " ++
            "__b=$(printf '%s' \"$__in\" | LC_ALL=C awk -v keys=\"{s}\" " ++
            "-v budget={d} '{s}' | base64 | tr -d '\n'); " ++
            "printf '\\033]3008;start={s};kind=notify;title=%s;body=%s\\033\\\\' \"$__t\" \"$__b\" > \"$__tty\"",
        .{
            if (reads_stdin) "__in=$(cat); " else "",
            notify_title_byte_budget,
            notify_extract_awk,
            notify_body_keys,
            notify_body_byte_budget,
            notify_extract_awk,
            agent.rawValue(),
        },
    );
}

/// Compose the OSC 3008 hook command: one guard, then (once it passes) the tty
/// resolve plus one presence emit per event and/or a notify emit, all in a
/// single brace group whose output is suppressed, with the trailing ownership
/// sentinel. Verbatim port of `AgentHookSettingsCommand.compositeCommand`.
/// Caller owns the returned string.
pub fn compositeCommandFull(
    alloc: Allocator,
    events: []const HookEvent,
    forward_stdin_as_notification: bool,
    agent: Agent,
) ![]u8 {
    std.debug.assert(events.len > 0 or forward_stdin_as_notification);

    var steps: std.ArrayListUnmanaged(u8) = .empty;
    defer steps.deinit(alloc);

    try steps.appendSlice(alloc, tty_resolve_snippet);
    for (events) |event| {
        try steps.appendSlice(alloc, "; ");
        const emit = try emitShell(alloc, event, agent);
        defer alloc.free(emit);
        try steps.appendSlice(alloc, emit);
    }
    if (forward_stdin_as_notification) {
        try steps.appendSlice(alloc, "; ");
        const notify = try emitNotifyShell(alloc, agent, true);
        defer alloc.free(notify);
        try steps.appendSlice(alloc, notify);
    }

    return std.fmt.allocPrint(
        alloc,
        "{s} && {{ {s}; }} >/dev/null 2>&1 || true {s}",
        .{ osc_guard_expr, steps.items, ownership_marker },
    );
}

/// Presence-only composite command (no notify leg). Convenience wrapper over
/// compositeCommandFull. Caller owns the returned string.
pub fn compositeCommand(alloc: Allocator, events: []const HookEvent, agent: Agent) ![]u8 {
    return compositeCommandFull(alloc, events, false, agent);
}

/// True when a command string was installed by Supacode. The trailing sentinel
/// is the source of truth (`AgentHookCommandOwnership.isSupacodeManagedCommand`).
pub fn isSupacodeManagedCommand(command: []const u8) bool {
    return std.mem.indexOf(u8, command, ownership_marker) != null;
}

test "compositeCommand carries event, guard, sentinel, suppression" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{.busy}, .claude);
    defer alloc.free(cmd);

    // event vocabulary
    try testing.expect(std.mem.indexOf(u8, cmd, "event=busy") != null);
    // agent name as the OSC context id
    try testing.expect(std.mem.indexOf(u8, cmd, "start=claude") != null);
    // surface-id guard (no-op outside Supacode)
    try testing.expect(std.mem.indexOf(u8, cmd, "SUPACODE_SURFACE_ID") != null);
    // output suppression + tolerant exit
    try testing.expect(std.mem.indexOf(u8, cmd, ">/dev/null 2>&1 || true") != null);
    // trailing ownership sentinel
    try testing.expect(std.mem.endsWith(u8, cmd, ownership_marker));
    // tty resolve
    try testing.expect(std.mem.indexOf(u8, cmd, "ps -o tty=") != null);
    // pid suffix gated on socket path
    try testing.expect(std.mem.indexOf(u8, cmd, "SUPACODE_SOCKET_PATH") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "pid=$PPID") != null);
}

test "compositeCommand session_end uses end action" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{.session_end}, .codex);
    defer alloc.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "end=codex") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "event=session_end") != null);
}

test "compositeCommand session_start uses start action" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{.session_start}, .pi);
    defer alloc.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "start=pi") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "event=session_start") != null);
}

test "compositeCommand multiple events" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{ .session_end, .idle }, .opencode);
    defer alloc.free(cmd);
    try testing.expect(std.mem.indexOf(u8, cmd, "event=session_end") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "event=idle") != null);
}

test "isSupacodeManagedCommand keys off sentinel only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{.busy}, .claude);
    defer alloc.free(cmd);
    try testing.expect(isSupacodeManagedCommand(cmd));
    // A user hook that merely references the env var is NOT ours.
    try testing.expect(!isSupacodeManagedCommand(
        "[ -n \"$SUPACODE_SURFACE_ID\" ] && echo hi",
    ));
}

test "compositeCommand exact shape matches macOS AgentHookSettingsCommand" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Byte-for-byte expected output of the macOS
    // AgentHookSettingsCommand.compositeCommand(events:[.busy],
    // forwardStdinAsNotification:false, agent:.claude), with the Linux
    // socket-path gate. This locks wire/shell parity.
    const expected =
        "[ -n \"${SUPACODE_SURFACE_ID:-}\" ] && { " ++
        "__tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d '[:space:]'); " ++
        "case \"$__tty\" in *[0-9]*) __tty=\"/dev/${__tty#/dev/}\";; *) __tty=\"/dev/tty\";; esac; " ++
        "__sp=\"\"; [ -n \"${SUPACODE_SOCKET_PATH:-}\" ] && __sp=\";pid=$PPID\"; " ++
        "printf '\\033]3008;start=claude;event=busy%s\\033\\\\' \"$__sp\" > \"$__tty\"; " ++
        "} >/dev/null 2>&1 || true # supacode-managed-hook";

    const cmd = try compositeCommand(alloc, &.{.busy}, .claude);
    defer alloc.free(cmd);
    try testing.expectEqualStrings(expected, cmd);
}

test "Agent rawValue and configDir parity with SkillAgent" {
    const testing = std.testing;
    try testing.expectEqualStrings("claude", Agent.claude.rawValue());
    try testing.expectEqualStrings(".claude", Agent.claude.configDir());
    try testing.expectEqualStrings(".codex", Agent.codex.configDir());
    try testing.expectEqualStrings(".copilot", Agent.copilot.configDir());
    try testing.expectEqualStrings(".kiro", Agent.kiro.configDir());
    try testing.expectEqualStrings(".config/opencode", Agent.opencode.configDir());
    try testing.expectEqualStrings(".pi/agent", Agent.pi.configDir());
}
