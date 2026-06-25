//! Supacode agent presence: map an agent name (announced via OSC-3008
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

const log = std.log.scoped(.supacode_agent);

/// Known coding agents, matching the macOS asset marks
/// (claude-code-mark, codex-mark, pi-mark, kiro-mark) plus a generic fallback.
pub const Agent = enum {
    claude,
    codex,
    pi,
    kiro,
    generic,

    /// Parse an agent name (case-insensitive, tolerant of common aliases) into
    /// a known Agent. Unrecognized non-empty names map to `.generic`.
    pub fn parse(name: []const u8) ?Agent {
        if (name.len == 0) return null;
        // Lowercase into a small stack buffer for comparison.
        var buf: [32]u8 = undefined;
        const n = @min(name.len, buf.len);
        for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const lower = buf[0..n];

        if (contains(lower, "claude")) return .claude;
        if (contains(lower, "codex")) return .codex;
        if (contains(lower, "kiro")) return .kiro;
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
            .generic => @embedFile("agent-icons/agent-generic-symbolic.svg"),
        };
    }

    /// A short human-readable label used in tooltips and notifications.
    pub fn label(self: Agent) [:0]const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .pi => "Pi",
            .kiro => "Kiro",
            .generic => "Agent",
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

test "Agent.parse known agents" {
    const testing = std.testing;
    try testing.expectEqual(Agent.claude, Agent.parse("claude").?);
    try testing.expectEqual(Agent.claude, Agent.parse("claude-code").?);
    try testing.expectEqual(Agent.claude, Agent.parse("Claude Code").?);
    try testing.expectEqual(Agent.codex, Agent.parse("codex").?);
    try testing.expectEqual(Agent.kiro, Agent.parse("kiro").?);
    try testing.expectEqual(Agent.pi, Agent.parse("pi").?);
    try testing.expectEqual(Agent.generic, Agent.parse("aider").?);
    try testing.expect(Agent.parse("") == null);
    // "api" must not be misread as pi.
    try testing.expectEqual(Agent.generic, Agent.parse("api").?);
}
