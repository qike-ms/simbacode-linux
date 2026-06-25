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

Builds cleanly. Working tree clean.

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

## Key files

- `src/apprt/gtk/class/sidebar.zig` — worktree sidebar (git scan, rows, polling).
- `src/apprt/gtk/class/window.zig` — sidebar wiring, tab open/switch logic.
- `src/apprt/gtk/class/application.zig` — agent-attention notification.
- `src/apprt/gtk/ui/1.5/window.blp` — Adw.OverlaySplitView layout.
- `src/terminal/osc/parsers/context_signal.zig` — OSC-3008 parser.
- `src/terminal/Parser.zig`, `src/terminal/osc.zig`, `src/terminal/stream.zig`,
  `src/terminal/stream_terminal.zig` — OSC-3008 plumbing.
- `src/Surface.zig`, `src/apprt/action.zig`, `src/apprt/surface.zig`,
  `src/apprt/embedded.zig`, `src/termio/Exec.zig`,
  `src/termio/stream_handler.zig`, `src/config/Config.zig`,
  `include/ghostty.h` — context_signal / command-wrapper / font-size patches.

## Next steps

No stage-4 roadmap is recorded in the repo yet. Next logical step is to define
and implement stage-4 (scope TBD with the user).
