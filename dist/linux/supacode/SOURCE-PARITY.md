# supacode-linux ↔ macOS supacode source parity (issue #25)

Comparison of the merged Linux agent-presence implementation against the
authoritative macOS source (`/home/nvidia/git/supacode/`, supabitapp/supacode
v0.10.4). For each dimension: **MATCHES** / **DIFFERS(why)** vs the cited macOS
file:line.

Linux files:
- `src/terminal/osc/parsers/context_signal.zig` — OSC-3008 parser + HookEvent.
- `src/apprt/gtk/class/application.zig` — `contextSignal` event handler.
- `src/apprt/gtk/class/agent_hooks.zig` — hook shell-command builder.
- `src/apprt/gtk/class/agent_hook_installer.zig` — per-agent installers.
- `src/apprt/gtk/class/window.zig` — presence + liveness sweep.
- `src/apprt/gtk/class/surface.zig` — env injection.

---

## 1. OSC wire format

**MATCHES** — `AgentPresenceOSC.swift:5–28` (emit shape doc), `:188`
(`metadata(event:pidSuffix:)`), `:212` (`emitShell`).

- macOS emit: `OSC 3008 ; <action>=<agent> ; event=<event>[ ; pid=<pid>] ST`.
- Linux `agent_hooks.emitShell` (agent_hooks.zig) builds the identical
  `\033]3008;<action>=<agent>;event=<event>%s\033\\` with the `%s` pid suffix.
- An exact-shape unit test (`agent_hooks.zig` "compositeCommand exact shape
  matches macOS AgentHookSettingsCommand") locks the Claude `busy` command
  byte-for-byte.
- Parse side: `context_signal.zig` splits id (`start=<agent>`) + metadata, keys
  the event off `event=` (`AgentPresenceOSC.parse`, `:68`); the `start`/`end`
  action byte is descriptive only (`AgentPresenceOSC.action(for:)`).
- Field names `event/pid/kind/title/body` match `AgentPresenceOSC.swift:36–40`.

DIFFERS(intentional): the pid suffix is gated on `SUPACODE_SOCKET_PATH`
(`emitShell`, `:216`) — Linux always sets that env var (to the surface id) so a
pid is always emitted, because on Linux the OSC always reaches the local
surface. macOS gates it on a real socket path (omitted over SSH). Wire shape is
identical; only the gating value differs.

## 2. Event vocabulary

**MATCHES** — `AgentHookSettingsCommand.swift:6–12` (`enum HookEvent: String`).

- macOS: `session_start, session_end, busy, awaiting_input, idle`.
- Linux `HookEvent` (context_signal.zig + agent_hooks.zig) has the identical
  five rawValues. `context_signal.HookEvent.parse` rejects unknown values; a
  `HookEvent.parse` coverage test asserts all five + rejection.
- Mapping (application.zig `handlePresenceEvent`): session_start/end → presence
  (tab icon + Active membership), busy/idle → activity, awaiting_input →
  attention. Matches `AgentPresenceFeature.apply` (`:159`+).
- Duplicate `event=`/`kind=` rejection (application.zig `fieldCount`) mirrors
  `AgentPresenceOSC.parseFields` dedupedFields (`AgentPresenceOSC.swift:118`).

## 3. Hook command shape

**MATCHES** — `AgentHookSettingsCommand.swift:51–64` (`compositeCommand`),
`AgentPresenceOSC.swift:198` (`ttyResolveSnippet`), `:212` (`emitShell`), `:237`
(`notifyExtractAwk`), `:252` (`emitNotifyShell`).

- Guard: `[ -n "${SUPACODE_SURFACE_ID:-}" ]` (agent_hooks `osc_guard_expr`) ==
  `oscGuardExpr` (`AgentHookSettingsCommand.swift:69`).
- tty resolve: `ps -o tty= -p "$PPID" ... case ... /dev/...` — byte-identical to
  `ttyResolveSnippet`.
- Brace group, output suppression `>/dev/null 2>&1 || true`, trailing
  `# supacode-managed-hook` sentinel — all identical.
- Notify awk: `agent_hooks.notify_extract_awk` was verified **byte-identical**
  (609 bytes) to `AgentPresenceOSC.notifyExtractAwk` via a diff harness.

DIFFERS(intentional): macOS `envCheck` keeps a legacy 4-var guard
(`AgentHookSettingsCommand.swift:39`) for *detecting* old hooks; the live guard
is surface-id-only (`oscGuardExpr`), which is exactly what Linux emits. Linux
does not carry the legacy-detection branch of `AgentHookCommandOwnership`
(`isLegacyCommand`) because supacode-linux never shipped the pre-sentinel
hooks; ownership is sentinel-only (`agent_hooks.isSupacodeManagedCommand`),
matching `AgentHookCommandOwnership.isSupacodeManagedCommand`'s primary path.

## 4. Env injection

**MATCHES (gate)** — `AgentPresenceOSC.swift:34` (`surfaceEnvVar`).

- Linux `surface.zig injectSupacodeEnv` sets `SUPACODE_SURFACE_ID` (the gate),
  plus `SUPACODE_TAB_ID`, `SUPACODE_WORKTREE_ID`, and `SUPACODE_SOCKET_PATH`.
- The gate var name + role match: hooks no-op without it.

DIFFERS(intentional, Linux-appropriate):
- macOS injects a per-*tab* UUID for `SUPACODE_TAB_ID` and percent-encodes
  `SUPACODE_WORKTREE_ID`; Linux uses the surface id for TAB_ID and the raw
  worktree path for WORKTREE_ID. On Linux attribution is by the receiving
  surface (the OSC arrives on the emitting tty), so these are informational
  parity fields, not load-bearing — the legacy guard only checks `-n`.
- `SUPACODE_SOCKET_PATH` on macOS is a real Unix-domain socket path; on Linux
  there is no socket (OSC is the transport), so it is set to the surface id as a
  non-empty "local host" marker so the unmodified hook shells emit `pid=$PPID`.

## 5. Per-agent installer set

**MATCHES** — `SkillAgent.swift:12` (`configDirectoryName`) and the per-agent
`*HookSettings` / `*Installer` files.

| agent | macOS config | Linux config | source |
|-------|--------------|--------------|--------|
| claude | `.claude/settings.json` hooks | same | `ClaudeHookSettings.swift`, `ClaudeSettingsInstaller.swift:55` |
| codex | `.codex/hooks.json` | same | `CodexSettingsInstaller.swift:217` |
| kiro | `.kiro/agents/kiro_default.json` flat `timeout_ms` | same | `KiroSettingsInstaller.swift:179`, `KiroHookSettings.swift` |
| copilot | `.copilot/hooks/supacode.json` own file | same | `CopilotHooksInstaller.swift`, `CopilotHookSettings.swift` |
| opencode | `.config/opencode/plugins/*.js` plugin | `supacode-presence.js` | `OpenCodePluginContent.swift`, `OpenCodePluginInstaller.swift:61` |
| pi | `.pi/agent/extensions/supacode/index.ts` | same | `PiExtensionContent.swift`, `PiSettingsInstaller.swift:105` |

- Canonical hook maps match the macOS `*HookSettings` event→event mappings:
  Claude tool-level (PreToolUse busy / AskUserQuestion|ExitPlanMode
  awaiting_input ordered after `""`, PostToolUse idle, Stop idle+notify,
  SessionEnd session_end+idle) per `ClaudeHookSettings.swift`; Codex turn-level
  (SessionStart/UserPromptSubmit/Stop) per `CodexHookSettings.swift`; Kiro
  (agentSpawn/userPromptSubmit/stop) per `KiroHookSettings.swift`; Copilot
  per-event own-file per `CopilotHookSettings.swift`.
- Idempotent `install = uninstall + append`, sentinel-only ownership
  (`AgentHookSettingsFileInstaller.swift:120`+, `AgentHookCommandOwnership.swift`).
  Verified by tests (user-hook preservation, no-duplicate re-install,
  own-file user-file refusal).

DIFFERS(intentional):
- Codex: macOS enables `[features].hooks = true` in `~/.codex/config.toml` via a
  CLI command (`CodexSettingsInstaller.swift:82`+). Linux writes the same flag
  directly (`agent_hook_installer.setCodexHooksFlag` / `rewriteCodexFeatures`),
  stripping the legacy `codex_hooks = true` and creating `[features]` if absent,
  so Codex actually loads `hooks.json`. **MATCHES** the effect; the mechanism is
  a direct TOML rewrite instead of the CLI shim.
- Copilot: macOS has a hand-composed `notification` permission/elicitation
  branch (`CopilotHookSettings.swift notificationCommand`); Linux uses the flat
  per-event slot model and lets `agentStop` own the done-alert. (Deferred.)
- Kiro/Codex: macOS gates install behind an agent-availability check (CLI
  version probe); Linux installs unconditionally (the guarded hook is inert if
  the agent is absent, so it is harmless).
- CLI skill install (`CLISkillContent`/`CLISkillInstaller`) is NOT ported — it
  is a macOS deeplink/skill convenience, not part of the presence wire.

## 6. Liveness sweep

**MATCHES** — `AgentPresenceFeature.swift:88` (`livenessSweepInterval =
.seconds(2)`), `:239` (`liveness` / `kill(pid, 0)`).

- Linux `window.zig livenessSweep` runs every 2000 ms (`liveness_timer`),
  reaps presence whose pid fails `kill(pid, 0)` with ESRCH (process gone);
  EPERM is treated as alive.
- Non-positive pids rejected (`kill(0/-N, 0)` targets process groups), matching
  `AgentPresenceFeature.liveness` (`$0 > 0 && kill($0, 0) == 0`) and
  `AgentPresenceOSC.parsePid` (`value > 0`, `:85`).
- Pid-less records (SSH attach) are skipped and torn down by session_end /
  surface close, matching the macOS pid-less branch (`apply`, `:159`+).

DIFFERS(intentional simplification): Linux tracks one `?pid` per surface-agent
record; macOS tracks a `Set<pid_t>` (`PresenceRecord.pids`). Equivalent for the
one-agent-per-surface case supacode-linux targets; a single surface hosting two
local agents of the same name would only track the latest pid. Documented.

---

## Deferred items (tracked, not divergences in the wire/presence core)

1. **Copilot notification branch** — the permission/elicitation →
   awaiting_input hand-composed hook (`CopilotHookSettings.notificationCommand`).
   Copilot still reports presence/activity; only the dedicated needs-you banner
   on a permission prompt is missing.
2. **Per-tab UUID / percent-encoded worktree id** for `SUPACODE_TAB_ID` /
   `SUPACODE_WORKTREE_ID` (informational on Linux).
3. **pid Set vs single pid** per surface-agent record.
4. **Process-scan fallback** for un-hooked agents (explicitly the optional
   last-resort path per #25; the hook path is the real design and is done).

## Summary

The OSC wire format, event vocabulary, hook command shape (incl. the
byte-identical notify awk), env-injection gate, per-agent installer set, and
liveness sweep all **MATCH** the macOS source. The differences are deliberate
Linux adaptations (OSC transport instead of a Unix socket; surface-based
attribution) or explicitly-deferred convenience items, none of which break wire
compatibility with the macOS app.
