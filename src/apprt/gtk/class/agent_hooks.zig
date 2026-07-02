//! simbacode agent-presence hook installer (Linux port).
//!
//! Mirrors the macOS source's per-agent hook installers
//! (`AgentHookSettingsCommand`, `AgentPresenceOSC`, and the
//! `{Codex,Claude,Copilot,Kiro}HookSettings` / `OpenCodePluginContent` /
//! `PiExtensionContent` builders). Each agent gets a `# simbacode-managed-hook`
//! guarded shell command (or a plugin/extension that runs it) written into the
//! agent's NATIVE config, so the agent emits OSC-3008 agent-presence events to
//! its controlling tty. The command is inert outside simbacode because it is
//! guarded on `[ -n "${SIMBACODE_SURFACE_ID:-}" ]` (the surface env var injected
//! by `surface.zig`).
//!
//! The hook command shape is byte-for-byte faithful to
//! `AgentHookSettingsCommand.compositeCommand` /
//! `AgentPresenceOSC.{ttyResolveSnippet,emitShell}` so the wire stays
//! compatible with the macOS app and the same hooks could run on either.
//!
//! Install + uninstall are idempotent: the trailing `# simbacode-managed-hook`
//! sentinel is the SOLE ownership marker (`AgentHookCommandOwnership`), so the
//! installer only ever edits its own blocks and never clobbers user-authored
//! hooks.

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.simbacode_agent_hooks);

/// Sentinel comment appended to every simbacode-installed hook command. The SOLE
/// source of truth for ownership (mirrors
/// `AgentHookSettingsCommand.ownershipMarker`): install/uninstall key off this
/// and ONLY this, so user-authored hooks are never touched.
pub const ownership_marker = "# simbacode-managed-hook";

/// Legacy ownership marker from before the simbacode rebrand. Uninstall still
/// strips blocks carrying this so an upgrade doesn't orphan old hooks.
pub const legacy_ownership_marker = "# supacode-managed-hook";

/// Env var present only on simbacode surfaces; its presence is the
/// no-op-outside-simbacode emit gate (`AgentPresenceOSC.surfaceEnvVar`).
pub const surface_env_var = "SIMBACODE_SURFACE_ID";

/// Env var present only on the local host; gates the local `pid=` suffix
/// (`AgentHookSettingsCommand.socketPathEnvVar`). On Linux surface.zig sets it
/// to the surface id so the pid is always emitted for the liveness sweep.
pub const socket_path_env_var = "SIMBACODE_SOCKET_PATH";

/// The supported agents, with their config directory under $HOME. Ported from
/// `SkillAgent` (macOS): claude, codex, copilot, kiro, opencode, pi. `hermes`
/// is Linux-only (no macOS counterpart); it emits the same OSC presence wire.
pub const Agent = enum {
    claude,
    codex,
    copilot,
    kiro,
    opencode,
    pi,
    hermes,

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
            .hermes => "hermes",
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
            .hermes => ".hermes",
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
/// emits. Agents run hooks with no controlling terminal, so resolving the
/// right pty is the load-bearing step (a wrong/empty `$__tty` is the #1 reason
/// a presence icon never appears).
///
/// Resolution order, most-reliable first:
///   1. `$SIMBACODE_TTY` — the surface's real pts path, injected by the
///      emulator into every surface's environment. Always correct when set;
///      agents that re-exec or detach still inherit it.
///   2. `/proc/$PPID/fd/{0,1,2}` — the parent agent's std fds, which point at
///      the pts even when the agent has no controlling terminal (the case that
///      breaks `ps -o tty=`, e.g. Codex). Linux-only, hence the readlink probe.
///   3. `ps -o tty= -p $PPID` — the portable macOS-parity fallback.
/// The chosen path is validated with `[ -w ]` before use; an unwritable or
/// missing device falls through to the next candidate.
pub const tty_resolve_snippet =
    "__tty=\"\"; " ++
    "if [ -n \"${SIMBACODE_TTY:-}\" ] && [ -w \"$SIMBACODE_TTY\" ]; then __tty=\"$SIMBACODE_TTY\"; fi; " ++
    "if [ -z \"$__tty\" ]; then for __fd in 0 1 2; do " ++
    "__c=$(readlink \"/proc/$PPID/fd/$__fd\" 2>/dev/null); " ++
    "case \"$__c\" in /dev/pts/*|/dev/tty[0-9]*) if [ -w \"$__c\" ]; then __tty=\"$__c\"; break; fi;; esac; " ++
    "done; fi; " ++
    "if [ -z \"$__tty\" ]; then " ++
    "__pt=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d '[:space:]'); " ++
    "case \"$__pt\" in *[0-9]*) __tty=\"/dev/${__pt#/dev/}\";; *) __tty=\"/dev/tty\";; esac; fi";

/// Build the shell `printf` that emits the OSC 3008 presence sequence for
/// `event`. Verbatim port of `AgentPresenceOSC.emitShell`: written to the
/// `$__tty` device, with the `pid=$PPID` suffix gated on the socket-path env
/// var. Caller owns the returned string.
///
/// When `with_session` is true the payload carries an extra `;sessionid=<id>`
/// suffix built from the shell variable `$__ss` (set by the session-capture
/// prefix emitted in `compositeCommandFull`). This is the per-tab session
/// identity used to restore the RIGHT conversation across a restart (issue
/// #29): without it two tabs running the same agent in the same cwd would
/// both "resume last" into a single session. When `$__sid` is empty (the agent
/// didn't supply a session id) `$__ss` is empty and the payload is unchanged.
pub fn emitShell(alloc: Allocator, event: HookEvent, agent: Agent, with_session: bool) ![]u8 {
    // payload: \033]3008;<action>=<agent>;event=<event>%s[%s]\033\\
    // The first %s is the conditionally-empty pid suffix (`__sp`); the second
    // (only present when with_session) is the conditionally-empty session
    // suffix (`__ss`).
    if (with_session) {
        return std.fmt.allocPrint(
            alloc,
            "__sp=\"\"; [ -n \"${{{s}:-}}\" ] && __sp=\";pid=$PPID\"; " ++
                "printf '\\033]3008;{s}={s};event={s}%s%s\\033\\\\' \"$__sp\" \"$__ss\" > \"$__tty\"",
            .{ socket_path_env_var, event.action(), agent.rawValue(), event.rawValue() },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "__sp=\"\"; [ -n \"${{{s}:-}}\" ] && __sp=\";pid=$PPID\"; " ++
            "printf '\\033]3008;{s}={s};event={s}%s\\033\\\\' \"$__sp\" > \"$__tty\"",
        .{ socket_path_env_var, event.action(), agent.rawValue(), event.rawValue() },
    );
}

/// The OSC guard expression: a surface id present (the no-op-outside-simbacode
/// gate). Verbatim port of `AgentHookSettingsCommand.oscGuardExpr`.
pub const osc_guard_expr = "[ -n \"${" ++ surface_env_var ++ ":-}\" ]";

/// Emit-side byte budgets for the notify leg (AgentPresenceOSC.notify*Budget).
pub const notify_title_byte_budget = 160;
pub const notify_body_byte_budget = 1000;

/// Terminal-safe stdin capture: read the hook JSON into `$__in`, but ONLY when
/// stdin is a pipe (`[ -t 0 ]` is false). Agents whose runners feed the hook
/// JSON on stdin get the payload; agents that invoke the command with the tty
/// on stdin and NOTHING piped (e.g. the OpenCode plugin's `$`sh -c ...``) skip
/// the read instead of blocking forever on `cat` — which would hang startup.
/// Leaves `$__in` empty in the no-pipe case, so downstream extraction just
/// yields no session id / notify text (a benign no-op).
pub const stdin_capture_snippet = "__in=\"\"; [ -t 0 ] || __in=$(cat)";

/// Notify body source keys, in display precedence (AgentPresenceOSC.notifyBodyKeys).
pub const notify_body_keys = "message,last_assistant_message,assistant_response";

/// Hook-JSON keys that carry the agent's session identity, in precedence order.
/// Claude/Codex/Copilot pass `session_id`; some agents use `sessionId` or a
/// bare `session`. The first non-empty match wins. Used to capture the per-tab
/// session so a restart can resume the RIGHT conversation (issue #29).
pub const session_id_keys = "session_id,sessionId,session";

/// Max bytes of a captured session id carried on the wire. Session ids are
/// short (UUIDs/ULIDs ~36 chars); this bounds a hostile/huge value.
pub const session_id_byte_budget = 128;

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
            if (reads_stdin) stdin_capture_snippet ++ "; " else "",
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
/// sentinel. Verbatim port of `AgentHookSettingsCommand.compositeCommand`,
/// extended with an optional session-id capture leg (issue #29).
/// Caller owns the returned string.
///
/// When `capture_session` is true the command first reads the agent's hook
/// JSON from stdin (unless the notify leg already captured it into `$__in`),
/// extracts a bounded session id via the shared awk, and carries it as
/// `;sessionid=<id>` on every presence emit. This is the per-tab session
/// identity that lets a restart resume the exact conversation each tab was in,
/// rather than every same-agent tab "resuming last" into one session.
pub fn compositeCommandFull(
    alloc: Allocator,
    events: []const HookEvent,
    forward_stdin_as_notification: bool,
    agent: Agent,
    capture_session: bool,
) ![]u8 {
    std.debug.assert(events.len > 0 or forward_stdin_as_notification);

    var steps: std.ArrayListUnmanaged(u8) = .empty;
    defer steps.deinit(alloc);

    try steps.appendSlice(alloc, tty_resolve_snippet);

    // Session-id capture leg: read stdin (once), extract a bounded session id,
    // and build the `$__ss` suffix used by each session-aware emit. We reuse
    // `$__in` when the notify leg will also read stdin, so we never `cat` twice
    // (a second cat would block/return empty). The awk is the same field
    // extractor the notify leg uses. `$__ss` stays empty when no id is found,
    // leaving the payload byte-for-byte identical to the no-session shape.
    if (capture_session) {
        // The capture leg runs first, so it always owns the `__in=$(cat)`.
        const cap = try sessionCaptureShell(alloc, false);
        defer alloc.free(cap);
        try steps.appendSlice(alloc, "; ");
        try steps.appendSlice(alloc, cap);
    }

    for (events) |event| {
        try steps.appendSlice(alloc, "; ");
        const emit = try emitShell(alloc, event, agent, capture_session);
        defer alloc.free(emit);
        try steps.appendSlice(alloc, emit);
    }
    if (forward_stdin_as_notification) {
        try steps.appendSlice(alloc, "; ");
        // The notify leg reads stdin itself only when the session-capture leg
        // didn't already (they share `$__in`).
        const notify = try emitNotifyShell(alloc, agent, !capture_session);
        defer alloc.free(notify);
        try steps.appendSlice(alloc, notify);
    }

    return std.fmt.allocPrint(
        alloc,
        "{s} && {{ {s}; }} >/dev/null 2>&1 || true {s}",
        .{ osc_guard_expr, steps.items, ownership_marker },
    );
}

/// Build the session-id capture shell: read the hook JSON on stdin into `$__in`
/// (only when it isn't already captured), extract a bounded session id via the
/// shared awk into `$__sid`, and precompute the `;sessionid=<id>` suffix into
/// `$__ss` (empty when no id). Caller owns the returned string.
fn sessionCaptureShell(alloc: Allocator, in_already_captured: bool) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}" ++
            "__sid=$(printf '%s' \"$__in\" | LC_ALL=C awk -v keys=\"{s}\" " ++
            "-v budget={d} '{s}'); " ++
            "__ss=\"\"; [ -n \"$__sid\" ] && __ss=\";sessionid=$__sid\"",
        .{
            if (in_already_captured) "" else stdin_capture_snippet ++ "; ",
            session_id_keys,
            session_id_byte_budget,
            notify_extract_awk,
        },
    );
}

/// Presence-only composite command (no notify leg, no session capture).
/// Convenience wrapper over compositeCommandFull. Caller owns the returned
/// string.
pub fn compositeCommand(alloc: Allocator, events: []const HookEvent, agent: Agent) ![]u8 {
    return compositeCommandFull(alloc, events, false, agent, false);
}

/// True when a command string was installed by simbacode. The trailing sentinel
/// is the source of truth (`AgentHookCommandOwnership.isSupacodeManagedCommand`).
/// Recognizes the legacy `# supacode-managed-hook` marker too, so an upgrade
/// from the supacode-branded build can still detect and clean up old blocks.
pub fn isSimbacodeManagedCommand(command: []const u8) bool {
    return std.mem.indexOf(u8, command, ownership_marker) != null or
        std.mem.indexOf(u8, command, legacy_ownership_marker) != null;
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
    // surface-id guard (no-op outside simbacode)
    try testing.expect(std.mem.indexOf(u8, cmd, "SIMBACODE_SURFACE_ID") != null);
    // output suppression + tolerant exit
    try testing.expect(std.mem.indexOf(u8, cmd, ">/dev/null 2>&1 || true") != null);
    // trailing ownership sentinel
    try testing.expect(std.mem.endsWith(u8, cmd, ownership_marker));
    // tty resolve
    try testing.expect(std.mem.indexOf(u8, cmd, "ps -o tty=") != null);
    // pid suffix gated on socket path
    try testing.expect(std.mem.indexOf(u8, cmd, "SIMBACODE_SOCKET_PATH") != null);
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

test "isSimbacodeManagedCommand keys off sentinel only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cmd = try compositeCommand(alloc, &.{.busy}, .claude);
    defer alloc.free(cmd);
    try testing.expect(isSimbacodeManagedCommand(cmd));
    // A user hook that merely references the env var is NOT ours.
    try testing.expect(!isSimbacodeManagedCommand(
        "[ -n \"$SIMBACODE_SURFACE_ID\" ] && echo hi",
    ));
}

test "compositeCommand exact shape matches macOS AgentHookSettingsCommand" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Byte-for-byte expected output of the composite hook command for
    // (events:[.busy], forwardStdinAsNotification:false, agent:.claude). The
    // tty-resolve step prefers the injected SIMBACODE_TTY and /proc/$PPID/fd
    // probes before the ps fallback to fix agents that run hooks with no
    // controlling terminal on Linux; the rest (guard, OSC payload, pid gate,
    // suppression, sentinel) is macOS parity.
    const expected =
        "[ -n \"${SIMBACODE_SURFACE_ID:-}\" ] && { " ++
        tty_resolve_snippet ++ "; " ++
        "__sp=\"\"; [ -n \"${SIMBACODE_SOCKET_PATH:-}\" ] && __sp=\";pid=$PPID\"; " ++
        "printf '\\033]3008;start=claude;event=busy%s\\033\\\\' \"$__sp\" > \"$__tty\"; " ++
        "} >/dev/null 2>&1 || true # simbacode-managed-hook";

    const cmd = try compositeCommand(alloc, &.{.busy}, .claude);
    defer alloc.free(cmd);
    try testing.expectEqualStrings(expected, cmd);
}

test "compositeCommandFull capture_session adds sessionid leg" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A session_start slot with capture_session=true reads stdin, extracts the
    // session id, and carries it as `;sessionid=$__sid` on the presence emit.
    const cmd = try compositeCommandFull(alloc, &.{.session_start}, false, .codex, true);
    defer alloc.free(cmd);

    // Reads the hook JSON from stdin (no notify leg, so this leg captures it).
    try testing.expect(std.mem.indexOf(u8, cmd, "__in=$(cat)") != null);
    // Extracts the session id via awk over the session-id keys.
    try testing.expect(std.mem.indexOf(u8, cmd, "__sid=$(printf") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "session_id") != null);
    // Builds the conditional suffix and carries it on the emit.
    try testing.expect(std.mem.indexOf(u8, cmd, "__ss=\";sessionid=$__sid\"") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "\"$__sp\" \"$__ss\"") != null);
    // Still a well-formed presence emit for the agent.
    try testing.expect(std.mem.indexOf(u8, cmd, "start=codex;event=session_start") != null);
}

test "compositeCommandFull capture_session shares stdin with notify leg" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // With both capture_session and the notify leg, stdin must be captured
    // exactly ONCE (a second `cat` would block/return empty). The capture leg
    // owns the `__in=$(cat)`, and the notify leg reuses `$__in`.
    const cmd = try compositeCommandFull(alloc, &.{.idle}, true, .claude, true);
    defer alloc.free(cmd);

    var it = std.mem.splitSequence(u8, cmd, "__in=$(cat)");
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    // N separators => count is N+1 pieces; exactly one occurrence => 2 pieces.
    try testing.expectEqual(@as(usize, 2), count);
    // Notify leg is present (title/body emit).
    try testing.expect(std.mem.indexOf(u8, cmd, "kind=notify") != null);
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
