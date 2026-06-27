//! Supacode agent-presence hook INSTALLER (Linux port).
//!
//! Writes / removes the `# supacode-managed-hook` guarded blocks into each
//! agent's NATIVE config, so the agent emits OSC-3008 agent-presence events to
//! its controlling tty. Faithful port of the macOS per-agent installers:
//!   - Claude  -> `~/.claude/settings.json` `hooks` map (JSON merge)
//!   - Codex   -> `~/.codex/hooks.json` `hooks` map (JSON merge)
//!   - Kiro    -> `~/.kiro/agents/kiro_default.json` flat `hooks` map (JSON merge)
//!   - Copilot -> `~/.copilot/hooks/supacode.json` (own file)
//!   - OpenCode-> `~/.config/opencode/plugins/supacode-presence.js` (own file)
//!   - Pi      -> `~/.pi/agent/extensions/supacode/index.ts` (own file)
//!
//! Idempotent: the trailing `# supacode-managed-hook` sentinel is the SOLE
//! ownership marker, so a re-install strips only Supacode-managed entries then
//! re-appends the canonical ones (`install = uninstall + append`), and a
//! user-authored hook in the same file is never touched.
//!
//! See `agent_hooks.zig` for the command builder (the wire/shell shape).

const std = @import("std");
const Allocator = std.mem.Allocator;
const hooks = @import("agent_hooks.zig");

const Agent = hooks.Agent;
const HookEvent = hooks.HookEvent;

const log = std.log.scoped(.supacode_agent_hooks);

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
};

// ===========================================================================
// Canonical per-agent hook maps (ported from the macOS *HookSettings).
// ===========================================================================

/// Claude (`ClaudeHookSettings`). Tool-level granularity: PreToolUse/
/// UserPromptSubmit -> busy, PostToolUse -> idle, AskUserQuestion|ExitPlanMode
/// -> awaiting_input, Notification -> awaiting_input + notify, Stop -> idle +
/// notify, SessionEnd -> session_end + idle.
pub const claude_slots = [_]HookSlot{
    .{ .event_key = "SessionStart", .events = &.{.session_start}, .timeout = 5 },
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
    .{ .event_key = "SessionStart", .events = &.{.session_start}, .timeout = 5 },
    .{ .event_key = "UserPromptSubmit", .events = &.{.busy}, .timeout = 10 },
    .{ .event_key = "Stop", .events = &.{.idle}, .notify = true, .timeout = 10 },
};

/// Kiro (`KiroHookSettings`). camelCase event names; agentSpawn ->
/// session_start, userPromptSubmit -> busy, stop -> idle + notify. Timeouts in
/// ms in the file (×1000 from these seconds).
pub const kiro_slots = [_]HookSlot{
    .{ .event_key = "agentSpawn", .events = &.{.session_start}, .timeout = 5 },
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
/// dist/linux/supacode/SOURCE-PARITY.md deferred items.
pub const copilot_slots = [_]HookSlot{
    .{ .event_key = "sessionStart", .events = &.{.session_start}, .timeout = 5 },
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
/// re-running strips Supacode-managed blocks then re-appends the canonical
/// set, never touching user-authored hooks. Best-effort per agent: a failure
/// installing one agent is logged and does not block the others.
pub fn installAll(alloc: Allocator) void {
    const home = homeDir() orelse {
        log.warn("supacode: HOME unset; skipping agent-hook install", .{});
        return;
    };
    installOne(alloc, home, .claude) catch |err| logErr(.claude, "install", err);
    installOne(alloc, home, .codex) catch |err| logErr(.codex, "install", err);
    installOne(alloc, home, .kiro) catch |err| logErr(.kiro, "install", err);
    installOne(alloc, home, .copilot) catch |err| logErr(.copilot, "install", err);
    installOne(alloc, home, .opencode) catch |err| logErr(.opencode, "install", err);
    installOne(alloc, home, .pi) catch |err| logErr(.pi, "install", err);
}

/// Uninstall the agent-presence hooks for every supported agent. Removes only
/// Supacode-managed blocks (by sentinel); user-authored hooks survive.
pub fn uninstallAll(alloc: Allocator) void {
    const home = homeDir() orelse return;
    uninstallOne(alloc, home, .claude) catch |err| logErr(.claude, "uninstall", err);
    uninstallOne(alloc, home, .codex) catch |err| logErr(.codex, "uninstall", err);
    uninstallOne(alloc, home, .kiro) catch |err| logErr(.kiro, "uninstall", err);
    uninstallOne(alloc, home, .copilot) catch |err| logErr(.copilot, "uninstall", err);
    uninstallOne(alloc, home, .opencode) catch |err| logErr(.opencode, "uninstall", err);
    uninstallOne(alloc, home, .pi) catch |err| logErr(.pi, "uninstall", err);
}

fn logErr(agent: Agent, op: []const u8, err: anyerror) void {
    log.warn("supacode: {s} hooks for {s} failed: {}", .{ op, agent.rawValue(), err });
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
        .copilot => try installOwnFile(alloc, home, ".copilot/hooks/supacode.json", try copilotFileSource(alloc), agent),
        .opencode => try installOwnFile(alloc, home, ".config/opencode/plugins/supacode-presence.js", try openCodePluginSource(alloc), agent),
        .pi => try installOwnFile(alloc, home, ".pi/agent/extensions/supacode/index.ts", try piExtensionSource(alloc), agent),
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
        .copilot => try uninstallOwnFile(alloc, home, ".copilot/hooks/supacode.json"),
        .opencode => try uninstallOwnFile(alloc, home, ".config/opencode/plugins/supacode-presence.js"),
        .pi => try uninstallOwnFile(alloc, home, ".pi/agent/extensions/supacode/index.ts"),
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
    const tmp = try std.fmt.allocPrint(alloc, "{s}.supacode.tmp", .{path});
    defer alloc.free(tmp);
    {
        const file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Install (idempotent) the canonical hook map into a JSON settings file.
/// `install = uninstall + append`: parse the existing object, strip every
/// Supacode-managed command from the `hooks` map, append the canonical groups,
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

    // Get/replace the `hooks` object, pruning Supacode-managed commands.
    var hooks_obj = try prunedHooksObject(aa, &root, format);

    // Append the canonical groups, grouped by event key (preserving order).
    try appendCanonicalSlots(aa, &hooks_obj, slots, agent, format);

    try root.object.put("hooks", .{ .object = hooks_obj });

    // Serialize and write.
    const out = try std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(out);
    try writeFileAtomic(alloc, path, out);
    log.info("supacode: installed {s} hooks at {s}", .{ agent.rawValue(), rel });
}

/// Uninstall (idempotent): strip every Supacode-managed command from the JSON
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
    log.info("supacode: uninstalled hooks from {s}", .{rel});
}

/// Build a fresh `hooks` object with every Supacode-managed command pruned from
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

/// Strip Supacode-managed commands from one group, returning null if the group
/// becomes empty. For `nested`, the group is `{matcher?, hooks:[...]}`; for
/// `flat`, the group is a single `{command, timeout_ms}` entry.
fn strippedGroup(aa: Allocator, group: std.json.Value, format: HookFormat) !?std.json.Value {
    switch (format) {
        .flat => {
            // A flat entry is itself the command-bearing object.
            if (group != .object) return group;
            const cmd = group.object.get("command") orelse return group;
            if (cmd == .string and hooks.isSupacodeManagedCommand(cmd.string)) return null;
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
                        if (cmd == .string and hooks.isSupacodeManagedCommand(cmd.string)) continue;
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
        const command = try hooks.compositeCommandFull(aa, slot.events, slot.notify, agent);

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
                // A non-array value at a Supacode event key is malformed user
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

/// Install a Supacode-owned file: write `content` to `<home>/<rel>` only if the
/// existing file (if any) is also Supacode-managed (carries the sentinel). A
/// user file that merely shares the name is never overwritten.
fn installOwnFile(alloc: Allocator, home: []const u8, rel: []const u8, content: []u8, agent: Agent) !void {
    defer alloc.free(content);
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    if (try readFileAlloc(alloc, path)) |existing| {
        defer alloc.free(existing);
        if (std.mem.indexOf(u8, existing, hooks.ownership_marker) == null) {
            // Not ours — refuse to overwrite a user file with the same name.
            log.warn("supacode: {s} exists but is not Supacode-managed; skipping", .{rel});
            return;
        }
        if (std.mem.eql(u8, existing, content)) return; // already current
    }
    try writeFileAtomic(alloc, path, content);
    log.info("supacode: installed {s} file at {s}", .{ agent.rawValue(), rel });
}

/// Uninstall a Supacode-owned file: remove it only if it carries the sentinel.
fn uninstallOwnFile(alloc: Allocator, home: []const u8, rel: []const u8) !void {
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);
    const existing = (try readFileAlloc(alloc, path)) orelse return;
    defer alloc.free(existing);
    if (std.mem.indexOf(u8, existing, hooks.ownership_marker) == null) return;
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    log.info("supacode: uninstalled file {s}", .{rel});
}

// ===========================================================================
// Own-file source builders.
// ===========================================================================

/// Build `~/.copilot/hooks/supacode.json` (CopilotHookSettings). Copilot auto-
/// loads every JSON file in the hooks dir, so Supacode owns its own file. The
/// composite command embeds the ownership sentinel, so the file is always
/// recognizable. Caller owns the result.
fn copilotFileSource(alloc: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var hooks_obj: std.json.ObjectMap = .init(aa);
    for (copilot_slots) |slot| {
        const command = try hooks.compositeCommandFull(aa, slot.events, slot.notify, .copilot);
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

/// Build `~/.config/opencode/plugins/supacode-presence.js` (OpenCodePluginContent).
/// OpenCode loads JS/TS plugins; the plugin runs the same guarded shell command
/// every other agent's hooks run. Caller owns the result.
fn openCodePluginSource(alloc: Allocator) ![]u8 {
    const session_start = try hooks.compositeCommandFull(alloc, &.{.session_start}, false, .opencode);
    defer alloc.free(session_start);
    const session_end_idle = try hooks.compositeCommandFull(alloc, &.{ .session_end, .idle }, false, .opencode);
    defer alloc.free(session_end_idle);
    const busy = try hooks.compositeCommandFull(alloc, &.{.busy}, false, .opencode);
    defer alloc.free(busy);
    const idle = try hooks.compositeCommandFull(alloc, &.{.idle}, false, .opencode);
    defer alloc.free(idle);
    const awaiting = try hooks.compositeCommandFull(alloc, &.{.awaiting_input}, false, .opencode);
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
        \\// Generated by Supacode — do not edit. Bridges OpenCode plugin events to
        \\// Supacode's OSC 3008 agent-presence protocol by running the same guarded
        \\// shell command Supacode installs for every other agent. The command checks
        \\// SUPACODE_SURFACE_ID first, so it is inert outside a Supacode surface.
        \\export const SupacodePresence = async ({{ $ }}) => {{
        \\  const emit = (command) => $`sh -c ${{command}}`.quiet().nothrow()
        \\  await emit({s})
        \\  return {{
        \\    dispose: async () => {{
        \\      await emit({s})
        \\    }},
        \\    "tool.execute.before": async () => {{
        \\      await emit({s})
        \\    }},
        \\    "tool.execute.after": async () => {{
        \\      await emit({s})
        \\    }},
        \\    "permission.ask": async () => {{
        \\      await emit({s})
        \\    }},
        \\    event: async ({{ event }}) => {{
        \\      if (event.type === "session.idle") {{
        \\        await emit({s})
        \\      }} else if (event.type === "permission.replied") {{
        \\        await emit({s})
        \\      }}
        \\    }},
        \\  }}
        \\}}
        \\
    , .{ hooks.ownership_marker, j_ss, j_sei, j_busy, j_idle, j_await, j_idle, j_busy });
}

/// JSON-encode `value` as a double-quoted JS string literal (escapes `"`, `\`,
/// control chars). The composite command has no newlines and `$`/backticks are
/// literal inside a double-quoted JS string. Caller owns the result.
fn jsString(alloc: Allocator, value: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = value }, .{});
}

/// The Pi extension index.ts (PiExtensionContent). Shipped in-tree; the
/// installer reconciles it into `~/.pi/agent/extensions/supacode/index.ts`.
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
    log.info("supacode: codex hooks feature flag {s}", .{if (enable) "enabled" else "disabled"});
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
    \\/* supacode-managed-extension */
    \\// # supacode-managed-hook
    \\/**
    \\ * Supacode + Pi integration extension.
    \\ *
    \\ * Reports agent lifecycle and notifications to Supacode by emitting OSC 3008
    \\ * escape sequences to the controlling terminal. Inert in any terminal that
    \\ * does not handle OSC 3008, and reaches Supacode over SSH too (no local
    \\ * socket needed), matching the Claude / Codex / Kiro hook integrations.
    \\ *
    \\ * Required env (injected by Supacode on every surface):
    \\ *   SUPACODE_SURFACE_ID  present only on a Supacode surface; absence is the
    \\ *                        no-op gate.
    \\ * Optional:
    \\ *   SUPACODE_SOCKET_PATH present only on the local host; gates the local pid
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
    \\function isSupacodeSurface(): boolean {
    \\  const id = process.env["SUPACODE_SURFACE_ID"];
    \\  return !!id && id.length > 0;
    \\}
    \\
    \\function localPidSuffix(): string {
    \\  return process.env["SUPACODE_SOCKET_PATH"] ? `;pid=${process.pid}` : "";
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
    \\      process.stderr.write(`supacode: OSC emit failed: ${e.code ?? ""} ${e.message ?? String(err)}\n`);
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
    \\  if (!isSupacodeSurface()) return;
    \\  emitPresence("session_start");
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

/// Persisted install-settings file: `~/.supacode/hooks.json`. Tracks whether
/// agent-hook auto-install is enabled (default on) and whether the first-run
/// install has happened. Matches the user's preference: run automatically on
/// first launch WITH a settings toggle to disable (default on).
const SettingsFile = struct {
    /// Whether agent-presence hook auto-install is enabled. Default true.
    enabled: bool = true,
    /// Whether the first-run install has already run.
    installed: bool = false,
};

/// Resolve `~/.supacode/hooks.json`. Caller owns the result.
fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ home, ".supacode", "hooks.json" });
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
        log.debug("supacode: agent-hook auto-install disabled by settings", .{});
        return;
    }
    installAll(alloc);
    saveSettings(alloc, home, .{ .enabled = true, .installed = true }) catch |err|
        log.warn("supacode: failed to persist hook settings: {}", .{err});
}

/// Disable auto-install and uninstall all Supacode-managed hooks. Used by the
/// settings toggle when the user turns the feature off.
pub fn disableAndUninstall() void {
    const alloc = std.heap.page_allocator;
    const home = homeDir() orelse return;
    uninstallAll(alloc);
    saveSettings(alloc, home, .{ .enabled = false, .installed = false }) catch |err|
        log.warn("supacode: failed to persist hook settings: {}", .{err});
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
        // Supacode-managed hook present.
        try testing.expect(std.mem.indexOf(u8, bytes, hooks.ownership_marker) != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "event=session_start") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "event=busy") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "AskUserQuestion|ExitPlanMode") != null);
    }

    // Re-install: idempotent (no duplicate Supacode blocks).
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

    // Uninstall: Supacode blocks gone, user hook survives.
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

    // Uninstall removes the file's Supacode entries.
    try uninstallJsonHookMap(alloc, home, rel, .flat);
    const after = (try readFileAlloc(alloc, path)).?;
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, hooks.ownership_marker) == null);
}

test "install refuses a non-array Supacode event value (no silent data loss)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    const rel = ".claude/settings.json";
    const path = try joinHome(alloc, home, rel);
    defer alloc.free(path);

    // A Supacode event key with a non-array (malformed) value must NOT be
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

    const rel = ".copilot/hooks/supacode.json";
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

    // Replace with a Supacode-managed file, then install overwrites it.
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

    // Uninstall removes the Supacode-managed file.
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
    try testing.expect(std.mem.indexOf(u8, plugin, "SupacodePresence") != null);

    const pi_src = try piExtensionSource(alloc);
    defer alloc.free(pi_src);
    try testing.expect(std.mem.indexOf(u8, pi_src, hooks.ownership_marker) != null);
    try testing.expect(std.mem.indexOf(u8, pi_src, "emitPresence(\"session_start\")") != null);
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
