# Supacode (Linux) agent integration

supacode-linux shows, per terminal surface:

- which **coding agent** is running there (a tab icon + sidebar "Active"
  membership),
- whether it is **working** (busy) or **waiting** (idle), and
- when it **needs you** (a top banner + desktop notification + a sidebar bell).

On macOS, supacode injects a Unix-domain socket and a set of `SUPACODE_*` env
vars into every managed terminal, and each agent's hook posts JSON to the
socket. On Linux we carry the same information over **OSC-3008** (Hierarchical
Context Signalling): the agent writes an escape sequence to its controlling
terminal and the emulator routes it to the exact surface the agent runs in — no
socket, no PID→surface mapping. The wire format and event vocabulary match the
macOS source (`SupacodeSettingsShared/BusinessLogic/AgentPresenceOSC.swift`) so
the same hooks are compatible with both apps.

## How it just works

supacode-linux **auto-installs agent hooks on first launch** (toggle in
`~/.supacode/hooks.json`, `"enabled": true` by default). For every supported
agent it writes a `# supacode-managed-hook` guarded block into the agent's
native config:

| agent     | config file                                          |
|-----------|------------------------------------------------------|
| Claude    | `~/.claude/settings.json` (`hooks`)                  |
| Codex     | `~/.codex/hooks.json`                                |
| Kiro      | `~/.kiro/agents/kiro_default.json` (`hooks`)         |
| Copilot   | `~/.copilot/hooks/supacode.json`                     |
| OpenCode  | `~/.config/opencode/plugins/supacode-presence.js`   |
| Pi        | `~/.pi/agent/extensions/supacode/index.ts`          |

Each block is guarded on `[ -n "${SUPACODE_SURFACE_ID:-}" ]` (an env var
supacode-linux injects into every surface), so it is **inert outside a Supacode
surface** — safe to leave installed anywhere. Install/uninstall are idempotent
and key ONLY off the `# supacode-managed-hook` sentinel, so user-authored hooks
in the same file are never touched.

To turn it off: set `"enabled": false` in `~/.supacode/hooks.json` (the app
will uninstall the managed blocks on the next toggle).

## The protocol

The hook resolves the agent's controlling tty (`ps -o tty= -p $PPID`) and writes
one OSC-3008 sequence per lifecycle event (`ESC` = `\033`, `ST` = `\033\`):

```
ESC ] 3008 ; <action>=<agent> ; event=<event> [ ; pid=<pid> ] ST
```

- `<action>` is `start` for every event except `session_end` (which uses
  `end`). The app keys off `event=`, not the action byte.
- `<agent>` is the agent name (the OSC context id): `claude`, `codex`, `kiro`,
  `copilot`, `opencode`, `pi`.
- `event` ∈ `session_start | session_end | busy | awaiting_input | idle`:
  - `session_start` / `session_end` → presence on/off (tab icon + Active),
  - `busy` / `idle` → working vs waiting,
  - `awaiting_input` → needs-you (banner + bell).
- `pid` is the agent's local process id (gated on `SUPACODE_SOCKET_PATH`, which
  supacode-linux also injects); it feeds the liveness sweep that reaps a crashed
  local agent. Omitted over SSH.

The rich-notification leg (the last assistant message) is a second shape:

```
ESC ] 3008 ; start=<agent> ; kind=notify ; title=<base64> ; body=<base64> ST
```

## Manual install / test

`supacode-signal` is a small helper that emits the sequences by hand (writes to
`/dev/tty`, so it works even when stdout is redirected):

```bash
# Presence on (tab icon appears):
SUPACODE_SURFACE_ID=test dist/linux/supacode/supacode-signal session_start --agent claude

# Working / waiting:
SUPACODE_SURFACE_ID=test dist/linux/supacode/supacode-signal busy --agent claude
SUPACODE_SURFACE_ID=test dist/linux/supacode/supacode-signal idle --agent claude

# Needs you:
SUPACODE_SURFACE_ID=test dist/linux/supacode/supacode-signal awaiting_input --agent claude

# Presence off:
SUPACODE_SURFACE_ID=test dist/linux/supacode/supacode-signal session_end --agent claude
```

## Implementation pointers (in this repo)

- `src/terminal/osc/parsers/context_signal.zig` — OSC-3008 parser + HookEvent.
- `src/apprt/gtk/class/agent_hooks.zig` — the hook shell-command builder
  (`compositeCommand` / `emitShell` / `emitNotifyShell` /
  `tty_resolve_snippet`), a byte-for-byte port of macOS
  `AgentHookSettingsCommand` + `AgentPresenceOSC`.
- `src/apprt/gtk/class/agent_hook_installer.zig` — per-agent canonical hook
  maps + idempotent install/uninstall + first-run reconcile.
- `src/apprt/gtk/class/agent.zig` — agent name → embedded symbolic icon.
- `src/apprt/gtk/class/application.zig` `contextSignal` — maps the event
  vocabulary to presence / activity / attention.
- `src/apprt/gtk/class/window.zig` — `setSurfaceAgent` / `setSurfaceActivity` /
  `livenessSweep` (presence + liveness) and `showAgentBanner` (top banner).
