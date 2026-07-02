//! simbacode agent-presence hook INSTALLER (Linux port).
//!
//! Writes / removes the `# simbacode-managed-hook` guarded blocks into each
//! agent's NATIVE config, so the agent emits OSC-3008 agent-presence events to
//! its controlling tty. Faithful port of the macOS per-agent installers:
//!   - Claude  -> `~/.claude/settings.json` `hooks` map (JSON merge)
//!   - Codex   -> `~/.codex/hooks.json` `hooks` map (JSON merge)
//!   - Kiro    -> `~/.kiro/agents/kiro_default.json` flat `hooks` map (JSON merge)
//!   - Copilot -> `~/.copilot/hooks/simbacode.json` (own file)
//!   - OpenCode-> `~/.config/opencode/plugins/simbacode-presence.js` (own file)
//!   - Pi      -> `~/.pi/agent/extensions/simbacode/index.ts` (own file)
//!
//! Idempotent: the trailing `# simbacode-managed-hook` sentinel is the SOLE
//! ownership marker, so a re-install strips only simbacode-managed entries then
//! re-appends the canonical ones (`install = uninstall + append`), and a
//! user-authored hook in the same file is never touched.
//!
//! See `agent_hooks.zig` for the command builder (the wire/shell shape).

const std = @import("std");
const Allocator = std.mem.Allocator;
const hooks = @import("agent_hooks.zig");

const Agent = hooks.Agent;
const HookEvent = hooks.HookEvent;

const log = std.log.scoped(.simbacode_agent_hooks);

/// A single canonical hook slot: an event key (the agent-native event name),
/// an optional matcher, the OSC events the command emits, and whether it
/// forwards stdin as a notification. The command string is built on demand.
pub const HookSlot = struct {
    /// Agent-native event key (e.g. "SessionStart", "userPromptSubmit").
    event_key: []const u8,
    /// Optional matcher (Claude PreToolUse). Empty string is a real matcher
    /// value ("" = match all); null means "no matcher field".
    matcher: ?[]const u8 = null,
    /// OSC presence events this slot emits.
    events: []const HookEvent,
    /// Whether the command forwards stdin as a notification leg.
    notify: bool = false,
    /// Hook timeout in seconds (Claude/Codex/Copilot) — Kiro uses ms (×1000).
    timeout: u32 = 5,
    /// Whether this slot captures the agent's session id from the hook JSON on
    /// stdin and carries it as `sessionid=` on the presence emit (issue #29).
    /// Set on the session_start slot so the per-tab session identity is
    /// recorded, enabling a restart to resume the exact conversation rather
    /// than every same-agent tab "resuming last" into one session.
    capture_session: bool = false,
};

// ===========================================================================
// Canonical per-agent hook maps (ported from the macOS *HookSettings).
// ===========================================================================

/// Claude (`ClaudeHookSettings`). Tool-level granularity: PreToolUse/
/// UserPromptSubmit -> busy, PostToolUse -> idle, AskUserQuestion|ExitPlanMode
/// -> awaiting_input, Notification -> awaiting_input + notify, Stop -> idle +
/// notify, SessionEnd -> session_end + idle.
pub const claude_slots = [_]HookSlot{
    .{ .event_key = "SessionStart", .events = &.{.session_start}, .timeout = 5, .capture_session = true },
    .{ .event_key = "UserPromptSubmit", .events = &.{.busy}, .timeout = 10 },
    .{ .event_key = "PreToolUse", .matcher = "", .events = &.{.busy}, .timeout = 5 },
    // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
    .{ .event_key = "PreToolUse", .matcher = "AskUserQuestion|ExitPlanMode", .events = &.{.awaiting_input}, .timeout = 5 },
    .{ .event_key = "PostToolUse", .matcher = "", .events = &.{.idle}, .timeout = 5 },
    .{ .event_key = "Notification", .matcher = "", .events = &.{.awaiting_input}, .notify = true, .timeout = 10 },
    .{ .event_key = "Stop", .events = &.{.idle}, .notify = true, .timeout = 10 },
    .{ .event_key = "SessionEnd", .matcher = "", .events = &.{ .session_end, .idle }, .timeout = 5 },
};

/// Codex (`CodexHookSettings`). Turn-level only: SessionStart -> session_start,
/// UserPromptSubmit -> busy, Stop -> idle + notify. No SessionEnd (clears via
/// the pid liveness sweep).
pub const codex_slots = [_]HookSlot{
    .{ .event_key = "SessionStart", .events = &.{.session_start}, .timeout = 5, .capture_session = true },
    .{ .event_key = "UserPromptSubmit", .events = &.{.busy}, .timeout = 10 },
    .{ .event_key = "Stop", .events = &.{.idle}, .notify = true, .timeout = 10 },
};

/// Kiro (`KiroHookSettings`). camelCase event names; agentSpawn ->
/// session_start, userPromptSubmit -> busy, stop -> idle + notify. Timeouts in
/// ms in the file (×1000 from these seconds).
pub const kiro_slots = [_]HookSlot{
    .{ .event_key = "agentSpawn", .events = &.{.session_start}, .timeout = 5, .capture_session = true },
    .{ .event_key = "userPromptSubmit", .events = &.{.busy}, .timeout = 10 },
    .{ .event_key = "stop", .events = &.{.idle}, .notify = true, .timeout = 10 },
};

/// Copilot (`CopilotHookSettings`). Own file; camelCase keys. sessionStart ->
/// session_start, userPromptSubmitted/preToolUse/postToolUse -> busy, agentStop
/// -> idle + notify, sessionEnd -> session_end.
///
/// DEFERRED vs macOS: `CopilotHookSettings.notificationCommand` hand-composes a
/// `notification` event that detects `permission_prompt`/`elicitation_dialog`
/// in the payload and flips to awaiting_input + alert. That conditional branch
/// is not yet ported (the flat-slot model has no payload-conditional shape);
/// agentStop already owns the done-alert, so a Copilot permission prompt shows
/// presence/activity but not the dedicated needs-you banner until ported. See
/// dist/linux/simbacode/SOURCE-PARITY.md deferred items.
pub const copilot_slots = [_]HookSlot{
    .{ .event_key = "sessionStart", .events = &.{.session_start}, .timeout = 5, .capture_session = true },
    .{ .event_key = "userPromptSubmitted", .events = &.{.busy}, .timeout = 10 },
    .{ .event_key = "preToolUse", .events = &.{.busy}, .timeout = 5 },
    .{ .event_key = "postToolUse", .events = &.{.busy}, .timeout = 5 },
    .{ .event_key = "agentStop", .events = &.{.idle}, .notify = true, .timeout = 10 },
    .{ .event_key = "sessionEnd", .events = &.{.session_end}, .timeout = 5 },
};

// ===========================================================================
// Install / uninstall driver.
// ===========================================================================

pub const InstallError = error{
    NoHome,
    InvalidExistingConfig,
} || Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError || std.posix.MakeDirError || std.json.ParseError(std.json.Scanner);

/// Resolve $HOME, or null when unset (we then skip install).
fn homeDir() ?[]const u8 {
    return std.posix.getenv("HOME");
}

/// Install the agent-presence hooks for every supported agent. Idempotent:
/// re-running strips simbacode-managed blocks then re-appends the canonical
/// set, never touching user-authored hooks. Best-effort per agent: a failure
/// installing one agent is logged and does not block the others.
pub fn installAll(alloc: Allocator) void {
    const home = homeDir() orelse {
        log.warn("simbacode: HOME unset; skipping agent-hook install", .{});
        return;
    };
    installOne(alloc, home, .claude) catch |err| logErr(.claude, "install", err);
    installOne(alloc, home, .codex) catch |err| logErr(.codex, "install", err);
    installOne(alloc, home, .kiro) catch |err| logErr(.kiro, "install", err);
    installOne(alloc, home, .copilot) catch |err| logErr(.copilot, "install", err);
    installOne(alloc, home, .opencode) catch |err| logErr(.opencode, "install", err);
    installOne(alloc, home, .pi) catch |err| logErr(.pi, "install", err);
    installOne(alloc, home, .hermes) catch |err| logErr(.hermes, "install", err);

    // Clean up own-files written by the legacy supacode-branded build so an
    // upgrade doesn't leave orphaned `supacode*` files alongside the new
    // `simbacode*` ones. Only removes files carrying our managed sentinel.
    cleanupLegacyOwnFiles(alloc, home);
}

/// Remove legacy `supacode*` own-files (pre-rebrand) if they carry the managed
/// sentinel. The JSON/YAML hook-map installers already strip legacy blocks via
/// `isSimbacodeManagedCommand` (which matches the legacy marker); this handles
/// the standalone own-files whose paths changed in the rebrand.
fn cleanupLegacyOwnFiles(alloc: Allocator, home: []const u8) void {
    const legacy_paths = [_][]const u8{
        ".copilot/hooks/supacode.json",
        ".config/opencode/plugins/supacode-presence.js",
        ".pi/agent/extensions/supacode/index.ts",
        ".hermes/agent-hooks/supacode-presence.sh",
    };
    for (legacy_paths) |rel| {
        uninstallOwnFile(alloc, home, rel) catch |err| {
            log.warn("simbacode: legacy cleanup of {s} failed: {}", .{ rel, err });
        };
    }

    // Strip stale Hermes consent-allowlist entries that point at the legacy
    // presence script path (the new install only carries over non-ours
    // entries keyed on the NEW path, so legacy ones would otherwise linger).
    const legacy_script = joinHome(alloc, home, ".hermes/agent-hooks/supacode-presence.sh") catch return;
    defer alloc.free(legacy_script);
    patchHermesAllowlist(alloc, home, legacy_script, false) catch |err| {
        log.warn("simbacode: legacy hermes allowlist cleanup failed: {}", .{err});
    };
}

/// Uninstall the agent-presence hooks for every supported agent. Removes only
/// simbacode-managed blocks (by sentinel); user-authored hooks survive.
pub fn uninstallAll(alloc: Allocator) void {
    const home = homeDir() orelse return;
    uninstallOne(alloc, home, .claude) catch |err| logErr(.claude, "uninstall", err);
    uninstallOne(alloc, home, .codex) catch |err| logErr(.codex, "uninstall", err);
    uninstallOne(alloc, home, .kiro) catch |err| logErr(.kiro, "uninstall", err);
    uninstallOne(alloc, home, .copilot) catch |err| logErr(.copilot, "uninstall", err);
    uninstallOne(alloc, home, .opencode) catch |err| logErr(.opencode, "uninstall", err);
    uninstallOne(alloc, home, .pi) catch |err| logErr(.pi, "uninstall", err);
    uninstallOne(alloc, home, .hermes) catch |err| logErr(.hermes, "uninstall", err);
}

fn logErr(agent: Agent, op: []const u8, err: anyerror) void {
    log.warn("simbacode: {s} hooks for {s} failed: {}", .{ op, agent.rawValue(), err });
}

fn installOne(alloc: Allocator, home: []const u8, agent: Agent) !void {
    switch (agent) {
        .claude => try installJsonHookMap(alloc, home, ".claude/settings.json", &claude_slots, agent, .nested),
        .codex => {
            try installJsonHookMap(alloc, home, ".codex/hooks.json", &codex_slots, agent, .nested);
            // Codex only loads hooks.json when the feature flag is on; without
            // this the file is inert (CodexSettingsInstaller.enableHooksFeature).
            try setCodexHooksFlag(alloc, home, true);
        },
        .kiro => try installJsonHookMap(alloc, home, ".kiro/agents/kiro_default.json", &kiro_slots, agent, .flat),
        .copilot => try installOwnFile(alloc, home, ".copilot/hooks/simbacode.json", try copilotFileSource(alloc), agent),
        .opencode => try installOwnFile(alloc, home, ".config/opencode/plugins/simbacode-presence.js", try openCodePluginSource(alloc), agent),
        .pi => try installOwnFile(alloc, home, ".pi/agent/extensions/simbacode/index.ts", try piExtensionSource(alloc), agent),
        .hermes => try installHermes(alloc, home),
    }
}

fn uninstallOne(alloc: Allocator, home: []const u8, agent: Agent) !void {
    switch (agent) {
        .claude => try uninstallJsonHookMap(alloc, home, ".claude/settings.json", .nested),
        .codex => {
            try uninstallJsonHookMap(alloc, home, ".codex/hooks.json", .nested);
            try setCodexHooksFlag(alloc, home, false);
        },
        .kiro => try uninstallJsonHookMap(alloc, home, ".kiro/agents/kiro_default.json", .flat),
        .copilot => try uninstallOwnFile(alloc, home, ".copilot/hooks/simbacode.json"),
        .opencode => try uninstallOwnFile(alloc, home, ".config/opencode/plugins/simbacode-presence.js"),
        .pi => try uninstallOwnFile(alloc, home, ".pi/agent/extensions/simbacode/index.ts"),
        .hermes => try uninstallHermes(alloc, home),
    }
}

// ===========================================================================
// JSON hook-map installer (Claude / Codex / Kiro).
// ===========================================================================

const HookFormat = enum {
    /// Claude/Codex: groups carry { matcher?, hooks: [{ type, command, timeout }] }.
    nested,
    /// Kiro: flat entries { command, timeout_ms }.
    flat,
};

/// Build the absolute path `<home>/<rel>`. Caller owns the result.
fn joinHome(alloc: Allocator, home: []const u8, rel: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ home, rel });
}

/// Ensure the parent directory of `path` exists (recursively).
fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

/// Read a file fully, or null if it does not exist. Caller owns the result.
fn readFileAlloc(alloc: Allocator, path: []const u8) !?[]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
}

/// Atomically write `content` to `path` (write temp + rename).
fn writeFileAtomic(alloc: Allocator, path: []const u8, content: []const u8) !void {
    try ensureParentDir(path);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.simbacode.tmp", .{path});
    defer alloc.free(tmp);
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Write `content` to `path` atomically and mark it executable (0o755). Used
/// for the Hermes presence script, which Hermes runs as a subprocess.
fn writeExecutableAtomic(alloc: Allocator, path: []const u8, content: []const u8) !void {
    try ensureParentDir(path);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.simbacode.tmp", .{path});
    defer alloc.free(tmp);
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = 0o755 });
        defer file.close();
        try file.writeAll(content);
    }
    try std.fs.cwd().rename(tmp, path);
    // createFile's mode is masked by umask; force the exec bits explicitly.
    if (std.fs.cwd().openFile(path, .{})) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}
}

// ===========================================================================
// Hermes installer.
//
// Hermes (nous-research) reads shell hooks from `~/.hermes/config.yaml` under a
// `hooks:` block and runs each `command` via `shlex.split` with shell=False
// (so no inline pipeline) — we therefore ship a managed presence SCRIPT and
// point the config at it. Each (event, command) pair needs a consent entry in
// `~/.hermes/shell-hooks-allowlist.json` or it stays inert, so we add that too.
//
// Hermes events we map (see website/docs/user-guide/features/hooks.md):
//   on_session_start -> session_start, pre_tool_call/pre_llm_call -> busy,
//   post_tool_call -> idle, on_session_end -> session_end+idle.
// The script reads `hook_event_name` from the stdin JSON to pick the OSC event,
// and always prints `{}` so Hermes never treats it as a block/inject decision.
// ===========================================================================

const hermes_script_rel = ".hermes/agent-hooks/simbacode-presence.sh";
const hermes_config_rel = ".hermes/config.yaml";
const hermes_allowlist_rel = ".hermes/shell-hooks-allowlist.json";

/// Hermes hook events we register the presence script for. Each maps (in the
/// script) to an OSC presence event by `hook_event_name`.
const hermes_events = [_][]const u8{
    "on_session_start",
    "pre_tool_call",
    "post_tool_call",
    "on_session_end",
};

fn installHermes(alloc: Allocator, home: []const u8) !void {
    // 1. The presence script (idempotent own-file, sentinel-guarded).
    const script_path = try joinHome(alloc, home, hermes_script_rel);
    defer alloc.free(script_path);
    const script = try hermesScriptSource(alloc);
    defer alloc.free(script);
    if (try readFileAlloc(alloc, script_path)) |existing| {
        defer alloc.free(existing);
        if (std.mem.indexOf(u8, existing, hooks.ownership_marker) == null) {
            log.warn("simbacode: {s} exists but is not simbacode-managed; skipping hermes", .{hermes_script_rel});
            return;
        }
    }
    try writeExecutableAtomic(alloc, script_path, script);

    // 2. The config.yaml `hooks:` block (only patch an empty `hooks: {}` or a
    //    missing block; never touch a user-populated hooks map).
    try patchHermesConfig(alloc, home, script_path, true);

    // 3. The consent allowlist so the hooks are not silently skipped.
    try patchHermesAllowlist(alloc, home, script_path, true);
    log.info("simbacode: installed hermes presence hooks", .{});
}

fn uninstallHermes(alloc: Allocator, home: []const u8) !void {
    const script_path = try joinHome(alloc, home, hermes_script_rel);
    defer alloc.free(script_path);
    try patchHermesConfig(alloc, home, script_path, false);
    try patchHermesAllowlist(alloc, home, script_path, false);
    try uninstallOwnFile(alloc, home, hermes_script_rel);
}

/// The Hermes presence script: read the hook JSON on stdin, pick an OSC event
/// from `hook_event_name`, resolve the tty, emit the OSC 3008 presence
/// sequence, and print `{}`. Guarded on SIMBACODE_SURFACE_ID so it is inert
/// outside a simbacode surface. Caller owns the result.
fn hermesScriptSource(alloc: Allocator) ![]u8 {
    // Reuse the shared tty-resolve snippet so behavior matches every other
    // agent's hook (SIMBACODE_TTY -> /proc fd -> ps).
    return std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\# {s}
        \\# simbacode agent-presence bridge for Hermes. Generated — do not edit.
        \\__in=$(cat 2>/dev/null)
        \\[ -n "${{SIMBACODE_SURFACE_ID:-}}" ] || {{ printf '{{}}\n'; exit 0; }}
        \\__ev=$(printf '%s' "$__in" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        \\__sid=$(printf '%s' "$__in" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        \\__ss=""; [ -n "$__sid" ] && __ss=";sessionid=$__sid"
        \\case "$__ev" in
        \\  on_session_start) __osc=session_start; __act=start;;
        \\  pre_tool_call|pre_llm_call) __osc=busy; __act=start;;
        \\  post_tool_call) __osc=idle; __act=start;;
        \\  on_session_end|on_session_finalize) __osc=session_end; __act=end;;
        \\  *) printf '{{}}\n'; exit 0;;
        \\esac
        \\{{ {s}; __sp=""; [ -n "${{SIMBACODE_SOCKET_PATH:-}}" ] && __sp=";pid=$PPID"; printf '\033]3008;%s=hermes;event=%s%s%s\033\\' "$__act" "$__osc" "$__sp" "$__ss" > "$__tty"; }} >/dev/null 2>&1 || true
        \\printf '{{}}\n'
        \\
    , .{ hooks.ownership_marker, hooks.tty_resolve_snippet });
}

/// Patch the Hermes `hooks:` block in config.yaml. To avoid corrupting a
/// hand-written YAML map we ONLY touch the safe cases: a literal `hooks: {}`
/// (empty map) or no `hooks:` key at all. A user-populated `hooks:` block is
/// left untouched (logged), so we never clobber existing hooks. On uninstall we
/// restore `hooks: {}` only when the current block is the one we wrote (keyed
/// by the managed script path).
fn patchHermesConfig(alloc: Allocator, home: []const u8, script_path: []const u8, enable: bool) !void {
    const path = try joinHome(alloc, home, hermes_config_rel);
    defer alloc.free(path);
    const original = (try readFileAlloc(alloc, path)) orelse {
        if (!enable) return;
        // No config yet: nothing safe to anchor to; skip (Hermes will write its
        // own config on first run, and the next install will patch it).
        log.warn("simbacode: ~/.hermes/config.yaml missing; skipping hermes hooks block", .{});
        return;
    };
    defer alloc.free(original);

    const block = try hermesHooksBlock(alloc, script_path);
    defer alloc.free(block);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // Find an `hooks:` top-level key (column 0). We handle two managed shapes:
    //   `hooks: {}`            -> empty, safe to replace
    //   `hooks:` + managed body -> our previously-written block (has sentinel)
    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    var handled = false;
    while (it.next()) |line| {
        const is_hooks_key = std.mem.startsWith(u8, line, "hooks:");
        if (is_hooks_key and !handled) {
            const after = std.mem.trim(u8, line["hooks:".len..], " \t\r");
            const is_empty_map = std.mem.eql(u8, after, "{}");
            // Our managed block spans this `hooks:` line plus indented lines
            // until the next column-0 key. Detect ours by the sentinel inside.
            const our_block = !is_empty_map and blockIsSimbacodeManaged(original, line);
            if (is_empty_map or our_block) {
                handled = true;
                if (enable) {
                    if (!first) try out.append(alloc, '\n');
                    try out.appendSlice(alloc, block);
                    first = false;
                } else {
                    if (!first) try out.append(alloc, '\n');
                    try out.appendSlice(alloc, "hooks: {}");
                    first = false;
                }
                // Skip the rest of our previous managed block's indented body.
                if (our_block) skipIndentedBody(&it);
                continue;
            }
            // User-populated hooks map: do not touch.
            log.warn("simbacode: ~/.hermes/config.yaml has a user hooks block; skipping", .{});
            return;
        }
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
        first = false;
    }

    // No `hooks:` key found: append our block (enable) or nothing (disable).
    if (!handled and enable) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, block);
        try out.append(alloc, '\n');
    }

    const rewritten = try out.toOwnedSlice(alloc);
    defer alloc.free(rewritten);
    if (std.mem.eql(u8, rewritten, original)) return;
    try writeFileAtomic(alloc, path, rewritten);
}

/// Build the managed `hooks:` YAML block that registers the presence script for
/// every Hermes event. Carries the ownership sentinel in a comment so we can
/// recognize it later. Caller owns the result.
fn hermesHooksBlock(alloc: Allocator, script_path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "hooks: # ");
    try out.appendSlice(alloc, hooks.ownership_marker);
    for (hermes_events) |ev| {
        try out.append(alloc, '\n');
        try out.writer(alloc).print(
            "  {s}:\n    - command: \"{s}\"\n      timeout: 5",
            .{ ev, script_path },
        );
    }
    return try out.toOwnedSlice(alloc);
}

/// True when the managed sentinel appears on the `hooks:` header line (our
/// block writes `hooks: # <sentinel>`). Recognizes the legacy marker too so an
/// upgrade replaces (not preserves) a pre-rebrand managed block.
fn blockIsSimbacodeManaged(_: []const u8, hooks_line: []const u8) bool {
    return std.mem.indexOf(u8, hooks_line, hooks.ownership_marker) != null or
        std.mem.indexOf(u8, hooks_line, hooks.legacy_ownership_marker) != null;
}

/// Advance `it` past lines that are part of an indented YAML block body (lines
/// starting with a space/tab), stopping before the next column-0 line. Peeks
/// without consuming the terminator by using an index-restoring split is not
/// possible with SplitIterator, so we consume only indented/blank lines.
fn skipIndentedBody(it: *std.mem.SplitIterator(u8, .scalar)) void {
    while (true) {
        const save = it.index;
        const next = it.next() orelse return;
        if (next.len == 0 or next[0] == ' ' or next[0] == '\t') continue;
        // Not part of the body: rewind so the caller's loop re-reads it.
        it.index = save;
        return;
    }
}

/// Add (or remove) the Hermes consent allowlist entries for our presence
/// script, so the hooks are not silently skipped on a non-TTY run. The file is
/// `~/.hermes/shell-hooks-allowlist.json` with an `approvals` array of
/// `{event, command}`. We add one entry per event; on uninstall we strip every
/// approval whose command equals our script path.
fn patchHermesAllowlist(alloc: Allocator, home: []const u8, script_path: []const u8, enable: bool) !void {
    const path = try joinHome(alloc, home, hermes_allowlist_rel);
    defer alloc.free(path);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var approvals: std.json.Array = .init(aa);
    if (try readFileAlloc(aa, path)) |existing| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, existing, .{}) catch null;
        if (parsed) |root| {
            if (root == .object) {
                if (root.object.get("approvals")) |a| {
                    if (a == .array) {
                        // Carry over every approval that is NOT ours.
                        for (a.array.items) |item| {
                            if (item == .object) {
                                if (item.object.get("command")) |c| {
                                    if (c == .string and std.mem.eql(u8, c.string, script_path)) continue;
                                }
                            }
                            try approvals.append(item);
                        }
                    }
                }
            }
        }
    }

    if (enable) {
        for (hermes_events) |ev| {
            var obj: std.json.ObjectMap = .init(aa);
            try obj.put("event", .{ .string = ev });
            try obj.put("command", .{ .string = script_path });
            try approvals.append(.{ .object = obj });
        }
    }

    var root: std.json.ObjectMap = .init(aa);
    try root.put("approvals", .{ .array = approvals });
    const out = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    defer alloc.free(out);
    try writeFileAtomic(alloc, path, out);
}

/// Install (idempotent) the canonical hook map into a JSON settings file.
/// `install = uninstall + append`: parse the existing object, strip every
/// simbacode-managed command from the `hooks` map, append the canonical groups,
/// and write back. A missing file starts from an empty object; a non-object
/// `hooks` value is refused (would destroy user data we don't own).
fn installJsonHookMap(
    alloc: Allocator,
    home: []const u8,
    rel: []const u8,
    slots: []const HookSlot,
    agent: Agent,
    format: HookFormat,
) !void {
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Load existing root object (or an empty object).
    var root: std.json.Value = root: {
        const existing = try readFileAlloc(aa, path);
        if (existing) |bytes| {
            if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) break :root .{ .object = .init(aa) };
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, bytes, .{}) catch {
                return InstallError.InvalidExistingConfig;
            };
            if (parsed != .object) return InstallError.InvalidExistingConfig;
            break :root parsed;
        }
        break :root .{ .object = .init(aa) };
    };

    // Get/replace the `hooks` object, pruning simbacode-managed commands.
    var hooks_obj = try prunedHooksObject(aa, &root, format);

    // Append the canonical groups, grouped by event key (preserving order).
    try appendCanonicalSlots(aa, &hooks_obj, slots, agent, format);

    try root.object.put("hooks", .{ .object = hooks_obj });

    // Serialize and write.
    const out = try std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(out);
    try writeFileAtomic(alloc, path, out);
    log.info("simbacode: installed {s} hooks at {s}", .{ agent.rawValue(), rel });
}

/// Uninstall (idempotent): strip every simbacode-managed command from the JSON
/// settings file's `hooks` map, leaving user hooks intact. No-op if the file
/// is missing.
fn uninstallJsonHookMap(
    alloc: Allocator,
    home: []const u8,
    rel: []const u8,
    format: HookFormat,
) !void {
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const existing = (try readFileAlloc(aa, path)) orelse return;
    if (std.mem.trim(u8, existing, " \t\r\n").len == 0) return;
    var root = std.json.parseFromSliceLeaky(std.json.Value, aa, existing, .{}) catch
        return InstallError.InvalidExistingConfig;
    if (root != .object) return InstallError.InvalidExistingConfig;

    const hooks_obj = try prunedHooksObject(aa, &root, format);
    try root.object.put("hooks", .{ .object = hooks_obj });

    const out = try std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(out);
    try writeFileAtomic(alloc, path, out);
    log.info("simbacode: uninstalled hooks from {s}", .{rel});
}

/// Build a fresh `hooks` object with every simbacode-managed command pruned from
/// the existing one. A non-object `hooks` value is refused.
fn prunedHooksObject(
    aa: Allocator,
    root: *std.json.Value,
    format: HookFormat,
) !std.json.ObjectMap {
    var result: std.json.ObjectMap = .init(aa);
    const existing = root.object.get("hooks") orelse return result;
    if (existing != .object) return InstallError.InvalidExistingConfig;

    var it = existing.object.iterator();
    while (it.next()) |entry| {
        const groups = entry.value_ptr.*;
        if (groups != .array) {
            // Preserve a non-array event value untouched (don't destroy user data).
            try result.put(entry.key_ptr.*, groups);
            continue;
        }
        var kept: std.json.Array = .init(aa);
        for (groups.array.items) |group| {
            if (try strippedGroup(aa, group, format)) |g| try kept.append(g);
        }
        if (kept.items.len > 0) try result.put(entry.key_ptr.*, .{ .array = kept });
    }
    return result;
}

/// Strip simbacode-managed commands from one group, returning null if the group
/// becomes empty. For `nested`, the group is `{matcher?, hooks:[...]}`; for
/// `flat`, the group is a single `{command, timeout_ms}` entry.
fn strippedGroup(aa: Allocator, group: std.json.Value, format: HookFormat) !?std.json.Value {
    switch (format) {
        .flat => {
            // A flat entry is itself the command-bearing object.
            if (group != .object) return group;
            const cmd = group.object.get("command") orelse return group;
            if (cmd == .string and hooks.isSimbacodeManagedCommand(cmd.string)) return null;
            return group;
        },
        .nested => {
            if (group != .object) return group;
            const hooks_val = group.object.get("hooks") orelse return group;
            if (hooks_val != .array) return group;
            var kept: std.json.Array = .init(aa);
            for (hooks_val.array.items) |hook| {
                if (hook == .object) {
                    if (hook.object.get("command")) |cmd| {
                        if (cmd == .string and hooks.isSimbacodeManagedCommand(cmd.string)) continue;
                    }
                }
                try kept.append(hook);
            }
            if (kept.items.len == 0) return null;
            // Rebuild the group object with the filtered hooks array.
            var obj: std.json.ObjectMap = .init(aa);
            var git = group.object.iterator();
            while (git.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "hooks")) continue;
                try obj.put(e.key_ptr.*, e.value_ptr.*);
            }
            try obj.put("hooks", .{ .array = kept });
            return .{ .object = obj };
        },
    }
}

/// Append the canonical hook slots to the (pruned) hooks object.
fn appendCanonicalSlots(
    aa: Allocator,
    hooks_obj: *std.json.ObjectMap,
    slots: []const HookSlot,
    agent: Agent,
    format: HookFormat,
) !void {
    for (slots) |slot| {
        const command = try hooks.compositeCommandFull(aa, slot.events, slot.notify, agent, if (slot.capture_session) .stdin else .none);

        const group: std.json.Value = switch (format) {
            .flat => flat: {
                var obj: std.json.ObjectMap = .init(aa);
                try obj.put("command", .{ .string = command });
                try obj.put("timeout_ms", .{ .integer = @intCast(slot.timeout * 1000) });
                break :flat .{ .object = obj };
            },
            .nested => nested: {
                var hook: std.json.ObjectMap = .init(aa);
                try hook.put("type", .{ .string = "command" });
                try hook.put("command", .{ .string = command });
                try hook.put("timeout", .{ .integer = @intCast(slot.timeout) });
                var hook_arr: std.json.Array = .init(aa);
                try hook_arr.append(.{ .object = hook });

                var grp: std.json.ObjectMap = .init(aa);
                if (slot.matcher) |m| try grp.put("matcher", .{ .string = m });
                try grp.put("hooks", .{ .array = hook_arr });
                break :nested .{ .object = grp };
            },
        };

        // Append to the event-keyed array (create it if absent).
        if (hooks_obj.getPtr(slot.event_key)) |existing| {
            if (existing.* == .array) {
                try existing.array.append(group);
            } else {
                // A non-array value at a simbacode event key is malformed user
                // data we don't own. Refuse rather than silently replace it
                // (matches macOS AgentHookSettingsFileInstaller.invalidEventHooks).
                return InstallError.InvalidExistingConfig;
            }
        } else {
            var arr: std.json.Array = .init(aa);
            try arr.append(group);
            try hooks_obj.put(slot.event_key, .{ .array = arr });
        }
    }
}

// ===========================================================================
// Own-file installer (Copilot / OpenCode / Pi).
// ===========================================================================

/// Install a simbacode-owned file: write `content` to `<home>/<rel>` only if the
/// existing file (if any) is also simbacode-managed (carries the sentinel). A
/// user file that merely shares the name is never overwritten.
fn installOwnFile(alloc: Allocator, home: []const u8, rel: []const u8, content: []u8, agent: Agent) !void {
    defer alloc.free(content);
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    if (try readFileAlloc(alloc, path)) |existing| {
        defer alloc.free(existing);
        if (std.mem.indexOf(u8, existing, hooks.ownership_marker) == null) {
            // Not ours — refuse to overwrite a user file with the same name.
            log.warn("simbacode: {s} exists but is not simbacode-managed; skipping", .{rel});
            return;
        }
        if (std.mem.eql(u8, existing, content)) return; // already current
    }
    try writeFileAtomic(alloc, path, content);
    log.info("simbacode: installed {s} file at {s}", .{ agent.rawValue(), rel });
}

/// Uninstall a simbacode-owned file: remove it only if it carries our managed
/// sentinel (new or legacy, so an upgrade can clean up pre-rebrand files).
fn uninstallOwnFile(alloc: Allocator, home: []const u8, rel: []const u8) !void {
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);
    const existing = (try readFileAlloc(alloc, path)) orelse return;
    defer alloc.free(existing);
    if (std.mem.indexOf(u8, existing, hooks.ownership_marker) == null and
        std.mem.indexOf(u8, existing, hooks.legacy_ownership_marker) == null) return;
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    log.info("simbacode: uninstalled file {s}", .{rel});
}

// ===========================================================================
// Own-file source builders.
// ===========================================================================

/// Build `~/.copilot/hooks/simbacode.json` (CopilotHookSettings). Copilot auto-
/// loads every JSON file in the hooks dir, so simbacode owns its own file. The
/// composite command embeds the ownership sentinel, so the file is always
/// recognizable. Caller owns the result.
fn copilotFileSource(alloc: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var hooks_obj: std.json.ObjectMap = .init(aa);
    for (copilot_slots) |slot| {
        const command = try hooks.compositeCommandFull(aa, slot.events, slot.notify, .copilot, if (slot.capture_session) .stdin else .none);
        var hook: std.json.ObjectMap = .init(aa);
        try hook.put("type", .{ .string = "command" });
        try hook.put("bash", .{ .string = command });
        try hook.put("timeoutSec", .{ .integer = @intCast(slot.timeout) });
        var arr: std.json.Array = .init(aa);
        try arr.append(.{ .object = hook });
        try hooks_obj.put(slot.event_key, .{ .array = arr });
    }

    var root: std.json.ObjectMap = .init(aa);
    try root.put("version", .{ .integer = 1 });
    try root.put("hooks", .{ .object = hooks_obj });

    const out = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    // Dupe out of the arena into the caller-owned allocator.
    return alloc.dupe(u8, out);
}

/// Build `~/.config/opencode/plugins/simbacode-presence.js` (OpenCodePluginContent).
/// OpenCode loads JS/TS plugins; the plugin runs the same guarded shell command
/// every other agent's hooks run. Caller owns the result.
///
/// Session id (issue #29): OpenCode's plugin API exposes `input.sessionID` on
/// its hook inputs (tool.execute.*, permission.ask) and `event.properties`.
/// The plugin tracks the latest sessionID in JS and passes it to the
/// session_start command as a shell ARGUMENT (`.argv` source), so the emit
/// carries `;sessionid=<id>` for restore. We must NOT read stdin here (the
/// plugin runs commands via `$`sh -c ...`` with the terminal on stdin and
/// nothing piped, so a `cat` would block and hang startup) — the argv path
/// avoids stdin entirely.
fn openCodePluginSource(alloc: Allocator) ![]u8 {
    const session_start = try hooks.compositeCommandFull(alloc, &.{.session_start}, false, .opencode, .argv);
    defer alloc.free(session_start);
    const session_end_idle = try hooks.compositeCommandFull(alloc, &.{ .session_end, .idle }, false, .opencode, .none);
    defer alloc.free(session_end_idle);
    const busy = try hooks.compositeCommandFull(alloc, &.{.busy}, false, .opencode, .none);
    defer alloc.free(busy);
    const idle = try hooks.compositeCommandFull(alloc, &.{.idle}, false, .opencode, .none);
    defer alloc.free(idle);
    const awaiting = try hooks.compositeCommandFull(alloc, &.{.awaiting_input}, false, .opencode, .none);
    defer alloc.free(awaiting);

    const j_ss = try jsString(alloc, session_start);
    defer alloc.free(j_ss);
    const j_sei = try jsString(alloc, session_end_idle);
    defer alloc.free(j_sei);
    const j_busy = try jsString(alloc, busy);
    defer alloc.free(j_busy);
    const j_idle = try jsString(alloc, idle);
    defer alloc.free(j_idle);
    const j_await = try jsString(alloc, awaiting);
    defer alloc.free(j_await);

    return std.fmt.allocPrint(alloc,
        \\// {s}
        \\//
        \\// Generated by simbacode — do not edit. Bridges OpenCode plugin events to
        \\// simbacode's OSC 3008 agent-presence protocol by running the same guarded
        \\// shell command simbacode installs for every other agent. The command checks
        \\// SIMBACODE_SURFACE_ID first, so it is inert outside a simbacode surface.
        \\// Session id (issue #29): OpenCode exposes input.sessionID on hook inputs and
        \\// event.properties.sessionID. We track the latest and pass it to the
        \\// session_start command as argv $1, so a restart resumes the exact session.
        \\export const SimbacodePresence = async ({{ $ }}) => {{
        \\  let sessionID = ""
        \\  const emit = (command) => $`sh -c ${{command}} sh ${{sessionID}}`.quiet().nothrow()
        \\  const sessionStartCmd = {s}
        \\  // sessionID is unknown at plugin load (PluginInput is project-scoped),
        \\  // so the initial session_start below carries no id. The first time a
        \\  // hook/event reveals the id we re-emit session_start WITH it, which the
        \\  // app treats as idempotent presence and uses to record the id (#29).
        \\  const learn = (id) => {{
        \\    if (typeof id === "string" && id && id !== sessionID) {{
        \\      sessionID = id
        \\      return emit(sessionStartCmd)
        \\    }}
        \\  }}
        \\  const track = (input) => learn(input && input.sessionID)
        \\  await emit(sessionStartCmd)
        \\  return {{
        \\    dispose: async () => {{
        \\      await emit({s})
        \\    }},
        \\    "tool.execute.before": async (input) => {{
        \\      track(input)
        \\      await emit({s})
        \\    }},
        \\    "tool.execute.after": async (input) => {{
        \\      track(input)
        \\      await emit({s})
        \\    }},
        \\    "permission.ask": async (input) => {{
        \\      track(input)
        \\      await emit({s})
        \\    }},
        \\    event: async ({{ event }}) => {{
        \\      if (event && event.properties) await learn(event.properties.sessionID)
        \\      if (event.type === "session.idle") {{
        \\        await emit({s})
        \\      }} else if (event.type === "permission.replied") {{
        \\        await emit({s})
        \\      }} else if (event.type === "session.deleted") {{
        \\        // Session gone -> remove its durable restore entry (#29).
        \\        await emit({s})
        \\      }}
        \\    }},
        \\  }}
        \\}}
        \\
    , .{ hooks.ownership_marker, j_ss, j_sei, j_busy, j_idle, j_await, j_idle, j_busy, j_sei });
}

/// JSON-encode `value` as a double-quoted JS string literal (escapes `"`, `\`,
/// control chars). The composite command has no newlines and `$`/backticks are
/// literal inside a double-quoted JS string. Caller owns the result.
fn jsString(alloc: Allocator, value: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = value }, .{});
}

/// The Pi extension index.ts (PiExtensionContent). Shipped in-tree; the
/// installer reconciles it into `~/.pi/agent/extensions/simbacode/index.ts`.
/// The sentinel is the first line so install/uninstall recognize it. Caller
/// owns the result.
fn piExtensionSource(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8, pi_extension_index_ts);
}

// ===========================================================================
// Codex feature-flag (config.toml) — Codex only loads hooks.json when
// `[features] hooks = true`. Ported from CodexSettingsInstaller's
// enableHooksFeature / disableHooksFeatureFlag / rewriteFeaturesSection.
// ===========================================================================

/// Enable (or disable) the Codex `[features] hooks = true` flag in
/// `~/.codex/config.toml`. On enable: ensure a `[features]` section exists with
/// `hooks = true` (and strip the legacy `codex_hooks = true`). On disable: drop
/// `hooks = true` from `[features]`. Idempotent; a no-op when already in the
/// desired state. Best-effort: a missing file on disable is fine.
fn setCodexHooksFlag(alloc: Allocator, home: []const u8, enable: bool) !void {
    const path = try joinHome(alloc, home, ".codex/config.toml");
    defer alloc.free(path);

    const original = (try readFileAlloc(alloc, path)) orelse blk: {
        if (!enable) return; // nothing to disable
        break :blk try alloc.dupe(u8, "");
    };
    defer alloc.free(original);

    const rewritten = try rewriteCodexFeatures(alloc, original, enable);
    defer alloc.free(rewritten);

    if (std.mem.eql(u8, rewritten, original)) return; // no change
    try writeFileAtomic(alloc, path, rewritten);
    log.info("simbacode: codex hooks feature flag {s}", .{if (enable) "enabled" else "disabled"});
}

/// Return the TOML section name if `line` is a `[section]` header (trailing
/// `#`-comment stripped, inner trimmed), else null. Mirrors
/// CodexSettingsInstaller.tomlSectionName.
fn tomlSectionName(line: []const u8) ?[]const u8 {
    const without_comment = if (std.mem.indexOfScalar(u8, line, '#')) |h| line[0..h] else line;
    const trimmed = std.mem.trim(u8, without_comment, " \t\r");
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return null;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    return if (inner.len == 0) null else inner;
}

/// True when `line` is `<key> = true` (optional surrounding whitespace and an
/// optional trailing `#`-comment), the TOML feature-flag shape.
fn isTomlTrueFlag(line: []const u8, key: []const u8) bool {
    // Strip a trailing #-comment first so `hooks = true # note` still matches
    // (symmetry with tomlSectionName's comment handling).
    const without_comment = if (std.mem.indexOfScalar(u8, line, '#')) |h| line[0..h] else line;
    var s = std.mem.trim(u8, without_comment, " \t\r");
    if (!std.mem.startsWith(u8, s, key)) return false;
    s = std.mem.trim(u8, s[key.len..], " \t");
    if (!std.mem.startsWith(u8, s, "=")) return false;
    s = std.mem.trim(u8, s[1..], " \t");
    return std.mem.eql(u8, s, "true");
}

/// Rewrite a Codex config.toml to enable/disable the modern `hooks = true`
/// feature flag inside `[features]`. On enable, also strips the legacy
/// `codex_hooks = true` and creates the `[features]` section if absent. Caller
/// owns the result.
fn rewriteCodexFeatures(alloc: Allocator, original: []const u8, enable: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var in_features = false;
    var saw_features = false;
    var wrote_modern = false;

    var it = std.mem.splitScalar(u8, original, '\n');
    var first = true;
    while (it.next()) |line| {
        if (tomlSectionName(line)) |name| {
            // Leaving the [features] section: if enabling and we never wrote the
            // modern flag, append it before the next header.
            if (enable and in_features and !wrote_modern) {
                if (!first) try out.append(alloc, '\n');
                try out.appendSlice(alloc, "hooks = true");
                wrote_modern = true;
                first = false;
            }
            in_features = std.mem.eql(u8, name, "features");
            if (in_features) saw_features = true;
            if (!first) try out.append(alloc, '\n');
            try out.appendSlice(alloc, line);
            first = false;
            continue;
        }
        if (in_features) {
            // Drop the legacy flag always; drop the modern flag when disabling
            // (we re-add it on enable so it isn't duplicated).
            if (isTomlTrueFlag(line, "codex_hooks")) continue;
            if (isTomlTrueFlag(line, "hooks")) {
                if (!enable) continue;
                // Keep exactly one modern flag.
                if (wrote_modern) continue;
                wrote_modern = true;
            }
        }
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
        first = false;
    }

    // Trailing [features] section with no following header.
    if (enable and in_features and !wrote_modern) {
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, "hooks = true");
        wrote_modern = true;
    }
    // No [features] section at all: append one.
    if (enable and !saw_features) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, "[features]\nhooks = true");
    }

    return out.toOwnedSlice(alloc);
}

// ===========================================================================
// Pi extension content (PiExtensionContent, ported to OSC-3008 vocabulary).
// ===========================================================================

/// Ownership marker for the Pi extension (PiExtensionContent.ownershipMarker).
/// A distinct comment form, but `installOwnFile` keys off the shared sentinel,
/// which this file also embeds in its header for uniform detection.
const pi_extension_index_ts =
    \\/* simbacode-managed-extension */
    \\// # simbacode-managed-hook
    \\/**
    \\ * simbacode + Pi integration extension.
    \\ *
    \\ * Reports agent lifecycle and notifications to simbacode by emitting OSC 3008
    \\ * escape sequences to the controlling terminal. Inert in any terminal that
    \\ * does not handle OSC 3008, and reaches simbacode over SSH too (no local
    \\ * socket needed), matching the Claude / Codex / Kiro hook integrations.
    \\ *
    \\ * Required env (injected by simbacode on every surface):
    \\ *   SIMBACODE_SURFACE_ID  present only on a simbacode surface; absence is the
    \\ *                        no-op gate.
    \\ * Optional:
    \\ *   SIMBACODE_SOCKET_PATH present only on the local host; gates the local pid
    \\ *                        so the app's liveness sweep can reap a crashed agent.
    \\ *
    \\ * Hook event mapping:
    \\ *   extension load      -> session_start
    \\ *   Pi agent_start      -> busy
    \\ *   Pi agent_end        -> idle + notification with last_assistant_message
    \\ *   Pi session_shutdown -> session_end + idle
    \\ */
    \\
    \\import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    \\import { openSync, writeSync, closeSync } from "node:fs";
    \\
    \\interface NotifyContent {
    \\  title?: string;
    \\  body?: string;
    \\}
    \\
    \\const AGENT = "pi";
    \\const TITLE_BUDGET = 160;
    \\const BODY_BUDGET = 1000;
    \\
    \\let lastWarnedAt = 0;
    \\const WARN_INTERVAL_MS = 60_000;
    \\
    \\function isSimbacodeSurface(): boolean {
    \\  const id = process.env["SIMBACODE_SURFACE_ID"];
    \\  return !!id && id.length > 0;
    \\}
    \\
    \\function localPidSuffix(): string {
    \\  return process.env["SIMBACODE_SOCKET_PATH"] ? `;pid=${process.pid}` : "";
    \\}
    \\
    \\function writeToTerminal(sequence: string): void {
    \\  try {
    \\    const fd = openSync("/dev/tty", "w");
    \\    try {
    \\      const bytes = Buffer.from(sequence, "utf8");
    \\      let offset = 0;
    \\      while (offset < bytes.length) {
    \\        try {
    \\          const written = writeSync(fd, bytes, offset, bytes.length - offset);
    \\          if (written <= 0) throw new Error(`short write (${offset}/${bytes.length})`);
    \\          offset += written;
    \\        } catch (writeErr) {
    \\          const code = (writeErr as NodeJS.ErrnoException).code;
    \\          if (code === "EINTR" || code === "EAGAIN") continue;
    \\          throw writeErr;
    \\        }
    \\      }
    \\    } finally {
    \\      closeSync(fd);
    \\    }
    \\  } catch (err) {
    \\    const now = Date.now();
    \\    if (now - lastWarnedAt > WARN_INTERVAL_MS) {
    \\      lastWarnedAt = now;
    \\      const e = err as NodeJS.ErrnoException;
    \\      process.stderr.write(`simbacode: OSC emit failed: ${e.code ?? ""} ${e.message ?? String(err)}\n`);
    \\    }
    \\  }
    \\}
    \\
    \\function emitPresence(event: string): void {
    \\  const action = event === "session_end" ? "end" : "start";
    \\  const meta = `event=${event}${localPidSuffix()}`;
    \\  writeToTerminal(`\x1b]3008;${action}=${AGENT};${meta}\x1b\\`);
    \\}
    \\
    \\// Per-session identity so simbacode can resume THIS conversation (not just
    \\// "the last one") after a restart. The authoritative source is the
    \\// ReadonlySessionManager on the extension context: getSessionId() returns
    \\// the current session's stable id, which changes on resume/fork (so we
    \\// read it from the ctx handed to the session_start handler, not once at
    \\// load). Falls back to empty (no sessionid) if unavailable.
    \\function sessionIdOf(ctx: any): string {
    \\  try {
    \\    const sm = ctx?.sessionManager;
    \\    const id = typeof sm?.getSessionId === "function" ? sm.getSessionId() : "";
    \\    if (typeof id === "string" && id.length > 0) return id.slice(0, 128);
    \\  } catch {
    \\    // ignore identity is optional
    \\  }
    \\  return "";
    \\}
    \\
    \\function emitPresenceWithSession(event: string, sessionId: string): void {
    \\  const action = event === "session_end" ? "end" : "start";
    \\  const sid = sessionId ? `;sessionid=${sessionId}` : "";
    \\  const meta = `event=${event}${localPidSuffix()}${sid}`;
    \\  writeToTerminal(`\x1b]3008;${action}=${AGENT};${meta}\x1b\\`);
    \\}
    \\
    \\function notifyField(value: string, budget: number): string {
    \\  const escaped = JSON.stringify(value).slice(1, -1);
    \\  const buf = Buffer.from(escaped, "utf8");
    \\  const capped = buf.length > budget ? buf.subarray(0, budget) : buf;
    \\  return capped.toString("base64");
    \\}
    \\
    \\function emitNotification(content: NotifyContent): void {
    \\  const meta =
    \\    `kind=notify` +
    \\    `;title=${notifyField(content.title ?? "", TITLE_BUDGET)}` +
    \\    `;body=${notifyField(content.body ?? "", BODY_BUDGET)}`;
    \\  writeToTerminal(`\x1b]3008;start=${AGENT};${meta}\x1b\\`);
    \\}
    \\
    \\function lastAssistantText(ctx: { sessionManager: { getEntries(): any[] } }): string | undefined {
    \\  const entries = ctx.sessionManager.getEntries();
    \\  for (let i = entries.length - 1; i >= 0; i--) {
    \\    const entry = entries[i];
    \\    if (entry.type !== "message") continue;
    \\    if (entry.message.role !== "assistant") continue;
    \\    const content = entry.message.content;
    \\    if (!Array.isArray(content)) continue;
    \\    const text = content
    \\      .filter((c: { type: string; text?: string }) => c.type === "text" && typeof c.text === "string")
    \\      .map((c: { text: string }) => c.text)
    \\      .join("")
    \\      .trim();
    \\    if (text.length > 0) return text;
    \\  }
    \\  return undefined;
    \\}
    \\
    \\export default function (pi: ExtensionAPI) {
    \\  if (!isSimbacodeSurface()) return;
    \\
    \\  // Emit session_start from the session_start event so we can read the
    \\  // session id off ctx.sessionManager (it isn't known at load time, and it
    \\  // changes on resume/fork). This carries sessionid= so a restart can
    \\  // resume the EXACT conversation (issue #29). Fired for new/resume/fork.
    \\  pi.on("session_start", (_event, ctx) => {
    \\    emitPresenceWithSession("session_start", sessionIdOf(ctx));
    \\  });
    \\
    \\  pi.on("agent_start", (_event, _ctx) => {
    \\    emitPresence("busy");
    \\  });
    \\
    \\  pi.on("agent_end", (_event, ctx) => {
    \\    emitPresence("idle");
    \\    emitNotification({ body: lastAssistantText(ctx) });
    \\  });
    \\
    \\  pi.on("session_shutdown", (_event, _ctx) => {
    \\    emitPresence("session_end");
    \\    emitPresence("idle");
    \\  });
    \\}
    \\
;

// ===========================================================================
// First-run / settings toggle.
// ===========================================================================

/// Persisted install-settings file: `~/.simbacode/hooks.json`. Tracks whether
/// agent-hook auto-install is enabled (default on) and whether the first-run
/// install has happened. Matches the user's preference: run automatically on
/// first launch WITH a settings toggle to disable (default on).
const SettingsFile = struct {
    /// Whether agent-presence hook auto-install is enabled. Default true.
    enabled: bool = true,
    /// Whether the first-run install has already run.
    installed: bool = false,
};

/// Resolve `~/.simbacode/hooks.json`. Caller owns the result.
fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ home, ".simbacode", "hooks.json" });
}

/// Load the install-settings file, or defaults when missing/malformed.
fn loadSettings(alloc: Allocator, home: []const u8) SettingsFile {
    const path = settingsPath(alloc, home) catch return .{};
    defer alloc.free(path);
    const bytes = (readFileAlloc(alloc, path) catch return .{}) orelse return .{};
    defer alloc.free(bytes);
    const parsed = std.json.parseFromSlice(SettingsFile, alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

/// Persist the install-settings file.
fn saveSettings(alloc: Allocator, home: []const u8, settings: SettingsFile) !void {
    const path = try settingsPath(alloc, home);
    defer alloc.free(path);
    const out = try std.json.Stringify.valueAlloc(alloc, settings, .{ .whitespace = .indent_2 });
    defer alloc.free(out);
    try writeFileAtomic(alloc, path, out);
}

/// Run the first-launch reconcile: if hook auto-install is enabled, (re)install
/// the agent-presence hooks for every supported agent and mark installed. A
/// no-op when the user has disabled it via the settings toggle. Safe to call
/// on every launch; install is idempotent. Best-effort: never blocks startup.
///
/// Uses `std.heap.page_allocator` (a process-global allocator) for all
/// transient work rather than the app's GPA, so the detached startup thread can
/// outlive a fast app shutdown without a use-after-free on the GPA.
pub fn reconcileOnLaunch() void {
    const alloc = std.heap.page_allocator;
    const home = homeDir() orelse return;
    const settings = loadSettings(alloc, home);
    if (!settings.enabled) {
        log.debug("simbacode: agent-hook auto-install disabled by settings", .{});
        return;
    }
    installAll(alloc);
    saveSettings(alloc, home, .{ .enabled = true, .installed = true }) catch |err|
        log.warn("simbacode: failed to persist hook settings: {}", .{err});
}

/// Disable auto-install and uninstall all simbacode-managed hooks. Used by the
/// settings toggle when the user turns the feature off.
pub fn disableAndUninstall() void {
    const alloc = std.heap.page_allocator;
    const home = homeDir() orelse return;
    uninstallAll(alloc);
    saveSettings(alloc, home, .{ .enabled = false, .installed = false }) catch |err|
        log.warn("simbacode: failed to persist hook settings: {}", .{err});
}

// ===========================================================================
// Tests.
// ===========================================================================

test "install + uninstall claude settings.json round-trips, idempotent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    // Seed a user-authored hook to ensure it survives.
    const settings_rel = ".claude/settings.json";
    {
        const path = try joinHome(alloc, home, settings_rel);
        defer alloc.free(path);
        try writeFileAtomic(alloc, path,
            \\{
            \\  "hooks": {
            \\    "SessionStart": [
            \\      { "hooks": [ { "type": "command", "command": "echo user-hook" } ] }
            \\    ]
            \\  }
            \\}
        );
    }

    // Install.
    try installJsonHookMap(alloc, home, settings_rel, &claude_slots, .claude, .nested);

    const path = try joinHome(alloc, home, settings_rel);
    defer alloc.free(path);
    {
        const bytes = (try readFileAlloc(alloc, path)).?;
        defer alloc.free(bytes);
        // User hook preserved.
        try testing.expect(std.mem.indexOf(u8, bytes, "echo user-hook") != null);
        // simbacode-managed hook present.
        try testing.expect(std.mem.indexOf(u8, bytes, hooks.ownership_marker) != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "event=session_start") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "event=busy") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "AskUserQuestion|ExitPlanMode") != null);
    }

    // Re-install: idempotent (no duplicate simbacode blocks).
    try installJsonHookMap(alloc, home, settings_rel, &claude_slots, .claude, .nested);
    {
        const bytes = (try readFileAlloc(alloc, path)).?;
        defer alloc.free(bytes);
        // Count occurrences of the sentinel — must equal the number of slots.
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, idx, hooks.ownership_marker)) |p| {
            count += 1;
            idx = p + hooks.ownership_marker.len;
        }
        try testing.expectEqual(claude_slots.len, count);
        // User hook still there.
        try testing.expect(std.mem.indexOf(u8, bytes, "echo user-hook") != null);
    }

    // Uninstall: simbacode blocks gone, user hook survives.
    try uninstallJsonHookMap(alloc, home, settings_rel, .nested);
    {
        const bytes = (try readFileAlloc(alloc, path)).?;
        defer alloc.free(bytes);
        try testing.expect(std.mem.indexOf(u8, bytes, hooks.ownership_marker) == null);
        try testing.expect(std.mem.indexOf(u8, bytes, "echo user-hook") != null);
    }
}

test "install kiro flat hooks uses timeout_ms" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const rel = ".kiro/agents/kiro_default.json";
    try installJsonHookMap(alloc, home, rel, &kiro_slots, .kiro, .flat);

    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);
    const bytes = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "timeout_ms") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "agentSpawn") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "event=session_start") != null);

    // Uninstall removes the file's simbacode entries.
    try uninstallJsonHookMap(alloc, home, rel, .flat);
    const after = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, hooks.ownership_marker) == null);
}

test "install refuses a non-array simbacode event value (no silent data loss)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const rel = ".claude/settings.json";
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    // A simbacode event key with a non-array (malformed) value must NOT be
    // silently replaced; install refuses (mirrors macOS invalidEventHooks).
    try writeFileAtomic(alloc, path,
        \\{ "hooks": { "SessionStart": "malformed-not-an-array" } }
    );
    try testing.expectError(
        InstallError.InvalidExistingConfig,
        installJsonHookMap(alloc, home, rel, &claude_slots, .claude, .nested),
    );
    // The original file is left untouched (atomic write never happened).
    const after = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "malformed-not-an-array") != null);
    try testing.expect(std.mem.indexOf(u8, after, hooks.ownership_marker) == null);
}

test "own-file installer respects user-owned files" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const rel = ".copilot/hooks/simbacode.json";
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    // A user file with the same name (no sentinel) must NOT be overwritten.
    try writeFileAtomic(alloc, path, "user content no sentinel");
    const src = try copilotFileSource(alloc);
    try installOwnFile(alloc, home, rel, src, .copilot);
    {
        const bytes = (try readFileAlloc(alloc, path)).?;
        defer alloc.free(bytes);
        try testing.expectEqualStrings("user content no sentinel", bytes);
    }

    // Replace with a simbacode-managed file, then install overwrites it.
    {
        const seed = try copilotFileSource(alloc);
        defer alloc.free(seed);
        // Truncate so the content differs and triggers a rewrite.
        const partial = seed[0 .. seed.len / 2];
        // Ensure the sentinel is present so it's recognized as ours.
        const seeded = try std.fmt.allocPrint(alloc, "{s}\n{s}\n", .{ partial, hooks.ownership_marker });
        defer alloc.free(seeded);
        try writeFileAtomic(alloc, path, seeded);
    }
    const src2 = try copilotFileSource(alloc);
    try installOwnFile(alloc, home, rel, src2, .copilot);
    {
        const bytes = (try readFileAlloc(alloc, path)).?;
        defer alloc.free(bytes);
        try testing.expect(std.mem.indexOf(u8, bytes, "timeoutSec") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, hooks.ownership_marker) != null);
    }

    // Uninstall removes the simbacode-managed file.
    try uninstallOwnFile(alloc, home, rel);
    try testing.expect((try readFileAlloc(alloc, path)) == null);
}

test "opencode plugin + pi extension carry sentinel and events" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const plugin = try openCodePluginSource(alloc);
    defer alloc.free(plugin);
    try testing.expect(std.mem.indexOf(u8, plugin, hooks.ownership_marker) != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "event=session_start") != null);
    try testing.expect(std.mem.indexOf(u8, plugin, "SimbacodePresence") != null);

    const pi_src = try piExtensionSource(alloc);
    defer alloc.free(pi_src);
    try testing.expect(std.mem.indexOf(u8, pi_src, hooks.ownership_marker) != null);
    try testing.expect(std.mem.indexOf(u8, pi_src, "emitPresenceWithSession(\"session_start\"") != null);
    // The pi extension probes for a session id so restore can resume the exact
    // conversation (issue #29).
    try testing.expect(std.mem.indexOf(u8, pi_src, "sessionid=") != null);
    try testing.expect(std.mem.indexOf(u8, pi_src, "emitNotification") != null);
}

test "codex feature flag: enable creates [features] hooks = true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // No file / empty: enable appends a [features] section.
    {
        const out = try rewriteCodexFeatures(alloc, "", true);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "[features]") != null);
        try testing.expect(std.mem.indexOf(u8, out, "hooks = true") != null);
    }

    // Existing [features] without the flag: insert it, preserve other keys.
    {
        const in = "[features]\nother = true\n";
        const out = try rewriteCodexFeatures(alloc, in, true);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "other = true") != null);
        try testing.expect(std.mem.indexOf(u8, out, "hooks = true") != null);
    }

    // Idempotent: enabling when already set makes no change.
    {
        const in = "[features]\nhooks = true\n";
        const out = try rewriteCodexFeatures(alloc, in, true);
        defer alloc.free(out);
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, out, idx, "hooks = true")) |p| {
            count += 1;
            idx = p + "hooks = true".len;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Legacy flag is stripped on enable; modern flag added.
    {
        const in = "[features]\ncodex_hooks = true\n";
        const out = try rewriteCodexFeatures(alloc, in, true);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "codex_hooks = true") == null);
        try testing.expect(std.mem.indexOf(u8, out, "hooks = true") != null);
    }

    // Disable drops the modern flag but preserves the section + other keys.
    {
        const in = "[features]\nhooks = true\nother = true\n";
        const out = try rewriteCodexFeatures(alloc, in, false);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "hooks = true") == null);
        try testing.expect(std.mem.indexOf(u8, out, "other = true") != null);
    }

    // A flag in a non-features section is untouched.
    {
        const in = "[other]\nhooks = true\n";
        const out = try rewriteCodexFeatures(alloc, in, false);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "hooks = true") != null);
    }

    // An inline-commented flag is recognized (no duplicate inserted on enable).
    {
        const in = "[features]\nhooks = true # keep\n";
        const out = try rewriteCodexFeatures(alloc, in, true);
        defer alloc.free(out);
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, out, idx, "hooks = true")) |p| {
            count += 1;
            idx = p + "hooks = true".len;
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "codex install writes config.toml flag" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    try setCodexHooksFlag(alloc, home, true);
    const path = try joinHome(alloc, home, ".codex/config.toml");
    defer alloc.free(path);
    const bytes = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "[features]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "hooks = true") != null);

    try setCodexHooksFlag(alloc, home, false);
    const after = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "hooks = true") == null);
}

test "hermes install: script + config block + allowlist, then uninstall" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    // Seed a config.yaml with an empty hooks map (the safe-to-patch shape).
    {
        const cfg = try joinHome(alloc, home, hermes_config_rel);
        defer alloc.free(cfg);
        try writeFileAtomic(alloc, cfg, "model:\n  default: x\nhooks: {}\nsecurity:\n  redact_secrets: true\n");
    }

    try installHermes(alloc, home);

    // Script exists, is sentinel-guarded, and emits the OSC.
    const script_path = try joinHome(alloc, home, hermes_script_rel);
    defer alloc.free(script_path);
    const script = (try readFileAlloc(alloc, script_path)).?;
    defer alloc.free(script);
    try testing.expect(std.mem.indexOf(u8, script, hooks.ownership_marker) != null);
    try testing.expect(std.mem.indexOf(u8, script, "=hermes;event=") != null);
    try testing.expect(std.mem.indexOf(u8, script, "hook_event_name") != null);

    // config.yaml: empty map replaced by our managed block, user keys intact.
    const cfg_path = try joinHome(alloc, home, hermes_config_rel);
    defer alloc.free(cfg_path);
    const cfg = (try readFileAlloc(alloc, cfg_path)).?;
    defer alloc.free(cfg);
    try testing.expect(std.mem.indexOf(u8, cfg, "hooks: # " ++ "") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "on_session_start:") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "redact_secrets: true") != null); // user key survives
    try testing.expect(std.mem.indexOf(u8, cfg, "hooks: {}") == null);

    // allowlist: one approval per event, all pointing at our script.
    const allow_path = try joinHome(alloc, home, hermes_allowlist_rel);
    defer alloc.free(allow_path);
    const allow = (try readFileAlloc(alloc, allow_path)).?;
    defer alloc.free(allow);
    try testing.expect(std.mem.indexOf(u8, allow, "on_session_start") != null);
    try testing.expect(std.mem.indexOf(u8, allow, script_path) != null);

    // Idempotent: a second install does not duplicate the block.
    try installHermes(alloc, home);
    const cfg2 = (try readFileAlloc(alloc, cfg_path)).?;
    defer alloc.free(cfg2);
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, cfg2, "on_session_start:");
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count); // N+1 splits for N occurrences

    // Uninstall: config restored to empty map, script gone.
    try uninstallHermes(alloc, home);
    const cfg3 = (try readFileAlloc(alloc, cfg_path)).?;
    defer alloc.free(cfg3);
    try testing.expect(std.mem.indexOf(u8, cfg3, "hooks: {}") != null);
    try testing.expect(std.mem.indexOf(u8, cfg3, "on_session_start:") == null);
    try testing.expect((try readFileAlloc(alloc, script_path)) == null);
}

test "hermes config: user-populated hooks block is left untouched" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const cfg = try joinHome(alloc, home, hermes_config_rel);
    defer alloc.free(cfg);
    const user = "hooks:\n  pre_tool_call:\n    - command: \"/usr/bin/true\"\n";
    try writeFileAtomic(alloc, cfg, user);

    const script_path = try joinHome(alloc, home, hermes_script_rel);
    defer alloc.free(script_path);
    try patchHermesConfig(alloc, home, script_path, true);

    const after = (try readFileAlloc(alloc, cfg)).?;
    defer alloc.free(after);
    try testing.expectEqualStrings(user, after); // unchanged
}
