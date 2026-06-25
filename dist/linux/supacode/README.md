# Supacode (Linux) agent integration

supacode-linux shows, per terminal surface:

- an **agent icon** on the tab (which coding agent is running there), and
- **attention** signals (a top banner + desktop notification + a bell in the
  worktree sidebar) when an agent finishes a turn and is waiting on you.

On macOS, supacode injects a Unix-domain socket and a set of `SUPACODE_*` env
vars into every managed terminal, and each agent's hook posts JSON to the
socket. On Linux we use a simpler, transport-free mechanism: **OSC-3008**
(Hierarchical Context Signalling). The agent writes an escape sequence to its
controlling terminal; the emulator already routes it to the exact surface the
agent is running in, so there is no socket, no env injection, and no
PID→surface mapping to maintain.

## The protocol

Two sequences, written to the tty (`ESC` = `\033`, `BEL` = `\007`):

```
# Presence / attention start:
ESC ] 3008 ; start=<id> ; agent=<name> [ ; attention=1 ] [ ; comm=<detail> ] BEL

# Clear:
ESC ] 3008 ; end=<id> BEL
```

Fields (all after the context id are optional `key=value`, `;`-separated):

| field       | meaning                                                             |
|-------------|---------------------------------------------------------------------|
| `agent`     | agent name. Recognized: `claude`/`claude-code`, `codex`, `pi`, `kiro`. Anything else → a generic agent icon. |
| `attention` | `1`/`true` → raise the top banner + notification + sidebar bell. Omit for presence-only (just the tab icon). |
| `comm`      | short free-text detail shown in the banner (e.g. the last assistant message). |

`<id>` is any 1–64 char ASCII string; use a stable per-process id so `start`
and `end` pair up.

**Presence vs attention are distinct on purpose.** A bare `start` with an
`agent` field only sets the tab icon (long-lived). `attention=1` is the
momentary "I need you" signal. Clearing attention must never drop the icon, so
they are separate — only `end` (or surface teardown) removes the icon.

## Quick test

```bash
# Light up the current tab with the Claude icon:
dist/linux/supacode/supacode-signal start --agent claude

# Ask for attention with a message (banner + notification + bell):
dist/linux/supacode/supacode-signal start --agent claude --attention "review the failing test"

# Clear it:
dist/linux/supacode/supacode-signal end
```

`supacode-signal` writes to `/dev/tty`, so it works even when stdout is
redirected. Install it on `$PATH` for use from agent hooks.

## Wiring real agents

### Pi

Copy `pi-extension/index.ts` to `~/.pi/agent/extensions/supacode/index.ts`.
It announces presence on load, refreshes it per turn, raises attention on
`agent_end` (carrying the last assistant message), and clears on shutdown/exit.

### Claude Code

Add hooks to `~/.claude/settings.json` that shell out to `supacode-signal`:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "supacode-signal start --agent claude" }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "supacode-signal start --agent claude --attention" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "supacode-signal end" }] }]
  }
}
```

### Codex

In `~/.codex/config.toml` enable hooks (`codex_hooks = true`) and point the
session lifecycle hooks at `supacode-signal start --agent codex` /
`--attention` / `end`, mirroring the Claude wiring above.

## Implementation pointers (in this repo)

- `src/terminal/osc/parsers/context_signal.zig` — OSC-3008 parser.
- `src/apprt/gtk/class/agent.zig` — agent name → embedded symbolic icon.
- `src/apprt/gtk/class/application.zig` `contextSignal` — splits presence from
  attention, drives icon + banner + notification + sidebar bell.
- `src/apprt/gtk/class/window.zig` — `setSurfaceAgent`/`refreshTabAgentIcon`
  (tab indicator) and `showAgentBanner` (top banner with teleport-on-open).
