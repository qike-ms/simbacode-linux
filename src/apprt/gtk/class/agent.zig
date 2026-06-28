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
            .codex => "&gt;_", // >_ prompt mark (escaped for Pango markup)
            .pi => "\u{03C0}", // π
            .kiro => "ki",
            .hermes => "h",
            .opencode => "\u{1F916}", // 🤖 robot (matches its own tab-bar mark)
            .openclaw => "\u{1F99E}", // 🦞 lobster
            .generic => "\u{1F916}", // 🤖 robot
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
