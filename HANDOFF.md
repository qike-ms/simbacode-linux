# supacode-linux — Handoff

A Ghostty fork that adds a worktree sidebar + AI-agent integration to the GTK
(Linux) app.

## Build

The build requires `blueprint-compiler` >= 0.16.0. The system package is 0.12.0
and will fail, so build inside the nix dev shell (provides blueprint-compiler
0.18.0 and zig 0.15.2):

```bash
nix develop --extra-experimental-features 'nix-command flakes' \
  --command bash -c "zig build -Demit-macos-app=false"
```

Binary lands at `zig-out/bin/ghostty`.

- `-Demit-macos-app=false` skips the macOS app bundle (faster, not needed on Linux).
- Targeted tests: `zig build test -Dtest-filter=<name>` (full suite is slow).
- Format: `zig fmt .`

## Status

Builds cleanly. Window renders; grouped sidebar shows repo headers with diff
counts; agent symbolic icons rasterize.

## Work completed

1. `a11284160` — Applied supacode patches: OSC-3008 `context_signal` escape
   sequence, command-wrapper, font-size getter, plus a temp GTK handler.
2. `d1cb5bcbf` — **stage-1 sidebar**: wrapped window content in
   `Adw.OverlaySplitView` with a placeholder Worktrees `ListBox`.
3. `cbd326848` — **stage-2 sidebar**: git-scan worktree rows with status dots,
   5s poll, row-activation opens worktree in a new tab.
4. `4120a9098` — **stage-2-fix**: row activation switches to an existing tab
   instead of opening a duplicate.
5. `378a96978` — **stage-3 OSC-3008 agent-attention**: sidebar badge +
   GNotification.
6. `562b37083` — **stage-4 sidebar grouping + diff counts** (req 1, 2):
   worktrees grouped under collapsible repo headers; per-worktree branch +
   `git diff HEAD --shortstat` line counts (+added/-removed). `parseShortstat`
   + tests. Sort groups worktrees into contiguous per-repo runs.
7. `867072013` — **stage-5 agent-native tabs + top banner** (req 3, 4):
   `agent.zig` (Agent enum + embedded symbolic SVG icons via gio.BytesIcon).
   Per-tab `Adw.TabPage.indicator-icon` from the focused surface's agent,
   keyed by `*Surface` pointer; torn down on tab detach. `Adw.Banner`
   agent_banner at top-of-window with teleport-on-open.
8. `81f3db5b4` — **stage-6 presence/attention split + OSC transport**:
   contextSignal separates presence (icon) from attention (banner +
   notification + bell). Widened sidebar markup buffers (overflow fix).
   `dist/linux/supacode/` ships `supacode-signal` (OSC emitter),
   `pi-extension/index.ts`, and a protocol README.
9. **stage-8 split-focus tab icon** — the per-tab agent indicator now follows
   focus changes *within* a split. Wired `Tab.notify::active-surface` to
   `refreshTabAgentIcon` so focusing a different pane re-derives the tab icon
   from the focused surface's agent (closes trio M4 / claude m5).

## The 4 user requirements — status

1. Organized by repo/folder on the left sidebar — **DONE** (collapsible repo
   headers grouping worktrees, `window.zig` rebuildSidebarRows).
2. Diff lines + branch name per repo — **DONE** (`sidebar.zig` statusFor runs
   shortstat; header + worktree rows show branch and +/- counts).
3. Agent icon per tab — **DONE** (`agent.zig` + Adw.TabPage indicator-icon,
   one per tab, driven by OSC-3008 agent= metadata).
4. Notifications on top — **DONE** (Adw.Banner at top + desktop GNotification).

Plus `trio-review` was run on the branch; findings tracked separately.

## Design provenance

Designed via trio-brainstorm (codex + claude + opencode). Consolidated brief:
`/tmp/supacode-design-brief.md` (key decisions: OSC carries agent identity
because it's already surface-scoped; presence vs attention are distinct; key
agent state by surface pointer not cwd; Adw.Banner for persistent attention).

## Key files

- `src/apprt/gtk/class/sidebar.zig` — worktree git scan (branch, dirty,
  ahead/behind, diff shortstat, repo grouping). `parseShortstat` + tests.
- `src/apprt/gtk/class/window.zig` — sidebar render (rebuildSidebarRows,
  buildRepoHeaderRow, buildWorktreeRow, collapse toggle), agent presence
  (surface_agents map, setSurfaceAgent, refreshTabAgentIcon), top banner
  (showAgentBanner, agentBannerClicked teleport), dispose() teardown.
- `src/apprt/gtk/class/agent.zig` — Agent enum, OSC name parsing, embedded
  symbolic SVG -> gio.BytesIcon. `agent-icons/*.svg`.
- `src/apprt/gtk/class/application.zig` — contextSignal: presence/attention
  split, agent= + attention= metadata parsing, banner + notification + bell.
- `src/apprt/gtk/ui/1.5/window.blp` — OverlaySplitView + Adw.Banner agent_banner.
- `dist/linux/supacode/` — supacode-signal (OSC emitter), pi-extension/, README.
- `src/terminal/osc/parsers/context_signal.zig` — OSC-3008 parser.
- `src/terminal/Parser.zig`, `src/terminal/osc.zig`, `src/terminal/stream.zig`,
  `src/terminal/stream_terminal.zig` — OSC-3008 plumbing.
- `src/Surface.zig`, `src/apprt/action.zig`, `src/apprt/surface.zig`,
  `src/apprt/embedded.zig`, `src/termio/Exec.zig`,
  `src/termio/stream_handler.zig`, `src/config/Config.zig`,
  `include/ghostty.h` — context_signal / command-wrapper / font-size patches.

## Next steps

All 4 core user requirements are implemented. Remaining refinements (priority
order, none blocking):

1. **Address trio-review findings** (see review output, tracked separately).
2. **Persist sidebar state** — the macOS `~/.supacode/sidebar.json` schema
   (`sections=[repoPath,{buckets,collapsed}]`) is not yet read/written; collapse
   state is in-memory only. Configurable projects root (currently hard-coded
   `~/git`).
3. **Performance** (trio): replace the blanket 5s full-rescan + full ListBox
   rebuild with a stat-cache (HEAD oid + index mtime) and `Gio.FileMonitor` on
   `.git/HEAD`,`.git/index`,`.git/packed-refs`; run git on a worker thread and
   marshal back via `g_idle_add`. Today every tick forks several `git` per
   worktree on the main loop.
4. **TreeListModel sidebar** — trio's ideal widget choice was
   `Gtk.TreeListModel` + `Gtk.ListView` + `Gtk.TreeExpander` (row recycling,
   model-driven expansion). Current impl is a grouped `Gtk.ListBox` rebuilt
   wholesale; fine at this scale, worth revisiting if repos×worktrees grows.
5. **Split-aware tab icon** — **DONE (stage-8)**: `refreshTabAgentIcon` now
   also fires on `Tab.notify::active-surface`, so the icon tracks the focused
   pane within a split, not only OSC events.
6. **Agent crash heartbeat/TTL** — presence clears on tab detach and on `end`,
   but a crashed agent that never sends `end` and whose surface stays open will
   keep its icon. Add a TTL/heartbeat (trio footgun #1).
