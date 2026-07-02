//! simbacode agent presence: map an agent name (announced via OSC-3008
//! `agent=<name>` metadata) to a GIcon used as an Adw.TabPage indicator icon.
//!
//! Icons are embedded as symbolic SVGs and wrapped in a `gio.BytesIcon`, so no
//! gresource/icon-theme plumbing is required. One icon per tab, driven by the
//! agent attached to the tab's focused surface (see window.zig).
//!
//! Agent identity is keyed by the stable surface, never by cwd/worktree (two
//! tabs can share a worktree). Lifecycle: a `3008;start=...;agent=<name>`
//! signal attaches the agent to a surface; `3008;end` or surface teardown
//! clears it.

const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");

const log = std.log.scoped(.simbacode_agent);

/// Agent activity state, set by OSC-3008 busy/idle/awaiting_input events.
/// Ported verbatim from AgentPresenceFeature.Activity (macOS): `busy` is
/// working (drives the shimmer), `idle` is waiting (turn finished, not parked
/// on the user), `awaiting_input` is the explicit needs-you prompt that drives
/// the attention banner/bell.
pub const Activity = enum {
    idle,
    busy,
    awaiting_input,
};

/// Known coding agents, matching the macOS asset marks
/// (claude-code-mark, codex-mark, pi-mark, kiro-mark) plus a generic fallback.
pub const Agent = enum {
    claude,
    codex,
    pi,
    kiro,
    hermes,
    opencode,
    openclaw,
    generic,

    /// Parse an agent name (case-insensitive, tolerant of common aliases) into
    /// a known Agent. Unrecognized non-empty names map to `.generic`.
    pub fn parse(agent_name: []const u8) ?Agent {
        if (agent_name.len == 0) return null;
        // Lowercase into a small stack buffer for comparison.
        var buf: [32]u8 = undefined;
        const n = @min(agent_name.len, buf.len);
        for (agent_name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];

        if (contains(lower, "claude")) return .claude;
        if (contains(lower, "codex")) return .codex;
        if (contains(lower, "kiro")) return .kiro;
        if (contains(lower, "hermes")) return .hermes;
        // Check openclaw before opencode (both start with "open").
        if (contains(lower, "openclaw") or contains(lower, "claw")) return .openclaw;
        if (contains(lower, "opencode")) return .opencode;
        // Match "pi" exactly or as a path component to avoid false positives
        // (e.g. "api"). Accept the standalone token only.
        if (std.mem.eql(u8, lower, "pi")) return .pi;
        return .generic;
    }

    fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    /// The embedded symbolic SVG bytes for this agent.
    fn svg(self: Agent) []const u8 {
        return switch (self) {
            .claude => @embedFile("agent-icons/agent-claude-symbolic.svg"),
            .codex => @embedFile("agent-icons/agent-codex-symbolic.svg"),
            .pi => @embedFile("agent-icons/agent-pi-symbolic.svg"),
            .kiro => @embedFile("agent-icons/agent-kiro-symbolic.svg"),
            .hermes => @embedFile("agent-icons/agent-hermes-symbolic.svg"),
            // opencode/openclaw have no dedicated SVG yet; reuse the generic
            // mark for the tab indicator (the sidebar uses the text symbol).
            .opencode, .openclaw, .generic => @embedFile("agent-icons/agent-generic-symbolic.svg"),
        };
    }

    /// A short text mark for this agent, used as a Pango-markup glyph in the
    /// sidebar (a raw-SVG BytesIcon does not reliably render in a plain
    /// Gtk.Image, so the sidebar uses guaranteed-to-render text). Distinct per
    /// agent so the user can tell which agent runs where at a glance.
    pub fn symbol(self: Agent) []const u8 {
        return switch (self) {
            .claude => "\u{2733}", // ✳ eight-spoked asterisk
            .codex => "\u{276F}", // ❯ single-char prompt mark (was ">_", too wide)
            .pi => "\u{03C0}", // π
            .kiro => "ki",
            .hermes => "h",
            .opencode => "\u{1F916}", // 🤖 robot (matches its own tab-bar mark)
            .openclaw => "\u{1F99E}", // 🦞 lobster
            .generic => "\u{1F916}", // 🤖 robot
        };
    }

    /// Per-agent Pango-markup styling for the sidebar symbol: a foreground
    /// color and an optional background. Distinct styling (e.g. Claude's
    /// orange, Codex's black-on-white "&gt;_" chip) lets the user tell which
    /// agent runs where at a glance, beyond the glyph alone.
    pub const SymbolStyle = struct {
        foreground: []const u8,
        background: ?[]const u8 = null,
    };

    pub fn symbolStyle(self: Agent) SymbolStyle {
        return switch (self) {
            // Claude: orange text (matches its brand mark).
            .claude => .{ .foreground = "#e5883e" },
            // Codex: black ">_" prompt on a white chip.
            .codex => .{ .foreground = "#000000", .background = "#ffffff" },
            // Everything else keeps the default blue.
            else => .{ .foreground = "#7aa2f7" },
        };
    }

    /// A short human-readable label used in tooltips and notifications.
    pub fn label(self: Agent) [:0]const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .pi => "Pi",
            .kiro => "Kiro",
            .hermes => "Hermes",
            .opencode => "OpenCode",
            .openclaw => "OpenClaw",
            .generic => "Agent",
        };
    }

    /// A stable, machine-readable name for this agent. Used as the persisted
    /// value in the agent-session store (issue #29) and to round-trip through
    /// `parse`. Distinct from `label` (which is human-facing) so the on-disk
    /// format stays terse and stable across UI copy changes.
    pub fn name(self: Agent) [:0]const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .pi => "pi",
            .kiro => "kiro",
            .hermes => "hermes",
            .opencode => "opencode",
            .openclaw => "openclaw",
            .generic => "generic",
        };
    }

    /// The shell command that relaunches this agent and resumes the EXACT
    /// session `session_id` (issue #29). simbacode NEVER starts a fresh agent
    /// session on restore: if we can't resume the exact conversation there is
    /// nothing to restore, so this returns null when the agent has no verified
    /// resume-by-id form or when `session_id` is empty. There is deliberately
    /// NO "continue last" / bare-launch fallback — those would start a new
    /// session, which is forbidden in simbacode.
    ///
    /// Only agents whose session-id capture AND resume-by-id have been
    /// live-verified are eligible (see `canResumeExact`); everything else
    /// returns null and is never recorded/restored.
    ///
    /// `buf` is caller-owned scratch; the returned slice points into it and is
    /// NUL-terminated so it can be used directly as a `Command.shell`.
    pub fn resumeCommand(self: Agent, session_id: []const u8, buf: []u8) ?[:0]const u8 {
        if (session_id.len == 0) return null;
        // Per-agent "resume THIS exact session" prefix; the id is appended
        // verbatim (the emit side sanitizes the id to [A-Za-z0-9._-]).
        const prefix: ?[]const u8 = switch (self) {
            // `claude --resume <id>` reopens a specific session by id.
            .claude => "claude --resume ",
            // `codex resume <id>` reopens a specific rollout by id.
            .codex => "codex resume ",
            // pi: `--session <id>` reopens a specific session by (partial or
            // full) UUID. NOT `--resume`, which is an interactive picker.
            .pi => "pi --session ",
            // opencode: `--session <id>` (`-s`) reopens a specific session.
            .opencode => "opencode --session ",
            // hermes: `--resume <SESSION>` reopens by id or title.
            .hermes => "hermes --resume ",
            // Not live-verified (capture and/or resume-by-id unknown). Under
            // "never start new", these are NOT restorable until verified.
            .kiro, .openclaw, .generic => null,
        };
        const p = prefix orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ p, session_id }) catch null;
    }

    /// Whether this agent has a live-verified session-id capture AND a
    /// resume-by-EXACT-id command, i.e. it is eligible to be recorded and
    /// restored. Gates capture, persist, and restore in ONE place so an
    /// unverified agent can never be fake-restored into a fresh session.
    ///
    /// Verified this session (see legion-wiki design doc): pi, claude, codex,
    /// opencode, hermes. NOT verified: kiro, copilot, openclaw, generic.
    /// (`copilot` is only in the installer enum, not this UI enum.)
    pub fn canResumeExact(self: Agent) bool {
        return switch (self) {
            .claude, .codex, .pi, .opencode, .hermes => true,
            .kiro, .openclaw, .generic => false,
        };
    }

    /// Build a new `gio.Icon` (BytesIcon) for this agent. Caller owns a
    /// reference and must `unref` it. Returns null on allocation failure.
    pub fn newIcon(self: Agent) ?*gio.Icon {
        const data = self.svg();
        const bytes = glib.Bytes.new(data.ptr, data.len);
        defer bytes.unref();
        const icon = gio.BytesIcon.new(bytes);
        return icon.as(gio.Icon);
    }
};

/// Build a standalone bell `gio.Icon` (BytesIcon), used as the
/// unclicked-notification mark in the sidebar and as a tab-indicator emblem.
/// Caller owns a reference and must `unref` it.
pub fn newBellIcon() ?*gio.Icon {
    const data = @embedFile("agent-icons/bell-symbolic.svg");
    const bytes = glib.Bytes.new(data.ptr, data.len);
    defer bytes.unref();
    const icon = gio.BytesIcon.new(bytes);
    return icon.as(gio.Icon);
}

test "Agent.name round-trips through parse" {
    const testing = std.testing;
    inline for (.{
        Agent.claude, Agent.codex,    Agent.pi,       Agent.kiro,
        Agent.hermes, Agent.opencode, Agent.openclaw,
    }) |a| {
        try testing.expectEqual(a, Agent.parse(a.name()).?);
    }
    // Only live-verified agents are eligible for exact-id resume.
    inline for (.{
        Agent.claude, Agent.codex, Agent.pi, Agent.opencode, Agent.hermes,
    }) |a| {
        try testing.expect(a.canResumeExact());
    }
    // Unverified agents must NOT be resumable (never fake-restore into fresh).
    inline for (.{ Agent.kiro, Agent.openclaw, Agent.generic }) |a| {
        try testing.expect(!a.canResumeExact());
    }
    var buf: [128]u8 = undefined;
    // Empty id -> nothing to resume.
    try testing.expect(Agent.claude.resumeCommand("", &buf) == null);
    // Ineligible agent -> null even with an id (never starts fresh).
    try testing.expect(Agent.kiro.resumeCommand("someid", &buf) == null);
    try testing.expect(Agent.generic.resumeCommand("someid", &buf) == null);
    // Exact-id resume commands per verified agent.
    try testing.expectEqualStrings(
        "claude --resume abc123",
        Agent.claude.resumeCommand("abc123", &buf).?,
    );
    try testing.expectEqualStrings(
        "codex resume xyz",
        Agent.codex.resumeCommand("xyz", &buf).?,
    );
    // pi uses `--session <id>` (not `--resume`, which is interactive).
    try testing.expectEqualStrings(
        "pi --session 019f-abc",
        Agent.pi.resumeCommand("019f-abc", &buf).?,
    );
    try testing.expectEqualStrings(
        "opencode --session ses_1",
        Agent.opencode.resumeCommand("ses_1", &buf).?,
    );
    // hermes now resumes by exact id (previously bugged to bare `hermes`).
    try testing.expectEqualStrings(
        "hermes --resume 20260101_120000_abcd",
        Agent.hermes.resumeCommand("20260101_120000_abcd", &buf).?,
    );
}

test "Agent.parse known agents" {
    const testing = std.testing;
    try testing.expectEqual(Agent.claude, Agent.parse("claude").?);
    try testing.expectEqual(Agent.claude, Agent.parse("claude-code").?);
    try testing.expectEqual(Agent.claude, Agent.parse("Claude Code").?);
    try testing.expectEqual(Agent.codex, Agent.parse("codex").?);
    try testing.expectEqual(Agent.kiro, Agent.parse("kiro").?);
    try testing.expectEqual(Agent.hermes, Agent.parse("hermes").?);
    try testing.expectEqual(Agent.pi, Agent.parse("pi").?);
    try testing.expectEqual(Agent.opencode, Agent.parse("opencode").?);
    try testing.expectEqual(Agent.openclaw, Agent.parse("openclaw").?);
    // openclaw must win over the "open" prefix shared with opencode.
    try testing.expectEqual(Agent.openclaw, Agent.parse("OpenClaw").?);
    try testing.expectEqual(Agent.generic, Agent.parse("aider").?);
    try testing.expect(Agent.parse("") == null);
    // "api" must not be misread as pi.
    try testing.expectEqual(Agent.generic, Agent.parse("api").?);
}
