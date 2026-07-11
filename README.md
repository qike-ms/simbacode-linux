# simbacode-linux

**An agent-centric terminal for Linux.** simbacode-linux turns
[Ghostty](https://ghostty.org) into a terminal built for running many AI coding
agents at once: a git-worktree sidebar, live per-agent presence and activity,
and click-to-jump notifications — so you always know, at a glance, which agent
is working, which is waiting, and which needs you.

> [!NOTE]
>
> **Status: v0.1.0 (first tagged release).** simbacode-linux is a young but
> working build. You install it by building from source (no AppImage / Flatpak
> / `.deb` yet), and it integrates with your AI-agent config files by installing
> small, reversible presence hooks under your home directory (see
> [Security model](#security-model)). Everything below is implemented and in
> daily use.

## What it does

- **Worktree sidebar** — discovers your git repos and their worktrees, grouped
  by repo, showing branch, dirty state, and ahead/behind + insertion/deletion
  counts. Click a worktree to jump to its terminal.
- **Live agent presence** — when a coding agent starts working in a terminal,
  its icon appears next to the worktree; activity (busy / waiting) updates live,
  and a busy agent's indicator gently bounces so it's obvious across many rows.
- **"Needs you" notifications** — when an agent finishes or needs input, you get
  an attention bell on the sidebar row and tab, a desktop notification, and a
  sound. Click to jump straight to that agent.
- **Session restore across restarts** — running agents are remembered and, on
  the next launch, each is resumed into its exact prior session (never a fresh
  one), in the right worktree.
- **Remote repositories over SSH** — add a repository that lives on another host
  and work with its worktrees exactly like local ones: status is gathered over
  SSH and each worktree's terminal opens as an SSH session, all multiplexed over
  a single shared connection.
- **Multi-agent aware** — several agents across many repos/worktrees at once,
  each with its own colored indicator.

### Implemented today

- Worktree-grouped sidebar with branch / dirty / ahead-behind / diff stats, and
  a per-worktree status dot (clean / dirty / pushable / behind)
- **Remote (SSH) repositories & worktrees** — scan and open worktrees on a
  remote host over a multiplexed SSH ControlMaster connection
- OSC-3008 agent-presence protocol + per-agent hook installers for
  **Claude Code, Codex, Copilot, Kiro, OpenCode, Pi, and Hermes**
- Per-agent presence icons with per-agent colors, a bouncing busy indicator,
  attention bells (sidebar + tab), desktop notifications + sound, click-to-jump
- **Agent session persistence & restore** across restarts (exact-session resume
  for Pi, Claude, Codex, OpenCode, and Hermes)
- Per-worktree tab spaces; persisted, user-curated sidebar
- **Add Folder** with an ancestor quick-pick (jump straight to a parent like
  `~/git`) and last-location memory

### Not implemented yet

See the [issue backlog](https://github.com/qike-ms/simbacode-linux/issues) and
the umbrella tracking issue
[#6](https://github.com/qike-ms/simbacode-linux/issues/6). Highlights:

- **Settings UI + agent-integration manager** (opt-in install / preview /
  uninstall of hooks, with backup/restore) — _planned P0_, see
  [#7](https://github.com/qike-ms/simbacode-linux/issues/7)
- Command palette, worktree creation from the sidebar, PR/check status badges
- Phone control + Matrix/Telegram/Signal notifications over Tailnet
- Packaged releases (AppImage / Flatpak / `.deb`)

> _Screenshots / demo GIF: coming soon._

## Install

You build from source (no packaged releases yet). See [SETUP.md](SETUP.md) for
the full instructions (build deps, build flags, run). In short:

```bash
scripts/install-build-deps.sh   # one-time: blueprint-compiler + gtk4-layer-shell into ~/.local
scripts/install-binary.sh       # build (ReleaseFast) + install to ~/.local/bin/simbacode
simbacode
```

`scripts/install-binary.sh` builds with the correct flags and installs
atomically, so it works even while an older simbacode is still running (a plain
`cp` fails with `Text file busy`). Pass `--no-build` to install an
already-built binary. Requires zig 0.15.2 and system GTK4 / libadwaita. No nix
required.

## Remote repositories (SSH)

To work with a repository that lives on another machine, open the sidebar
**➕** dropdown and choose **Add Remote (SSH)…**. Enter the host (an
`~/.ssh/config` alias or a hostname), optionally a user and port, and the
absolute path to the repository on that host. Its worktrees then appear in the
sidebar like any local repo, and clicking one opens a terminal SSH'd into that
worktree.

All git status queries and the worktree terminals share a single SSH
[ControlMaster](https://man.openbsd.org/ssh_config#ControlMaster) connection
(`~/.ssh/simbacode-%C`), so you authenticate once. Status is gathered on a
background thread, so a slow or unreachable host never freezes the UI.

> [!TIP]
>
> For a brand-new host, background status queries use `BatchMode` and won't
> prompt, so worktrees may not appear until the host key is known. Open the
> worktree terminal once (which _can_ prompt) to accept the key, after which
> status populates normally. Passwordless auth (an SSH key or agent) is
> recommended.

## Security model

simbacode integrates with coding agents by installing small **presence hooks**
into their config files. This is the project's main trust boundary, so it is
worth understanding exactly what happens.

**What gets written.** On launch, simbacode installs hooks into these paths
under your home directory (only for agents you actually have installed):

| Agent | File(s) modified / created |
|---|---|
| Claude Code | `~/.claude/settings.json` |
| Codex | `~/.codex/config.toml`, `~/.codex/hooks.json` |
| Copilot | `~/.copilot/hooks/simbacode.json` |
| Kiro | `~/.kiro/agents/kiro_default.json` |
| OpenCode | `~/.config/opencode/plugins/simbacode-presence.js` |
| Pi | `~/.pi/agent/extensions/simbacode/index.ts` |
| Hermes | `~/.hermes/config.yaml`, `~/.hermes/shell-hooks-allowlist.json`, `~/.hermes/agent-hooks/simbacode-presence.sh` |

State is tracked in `~/.simbacode/hooks.json`.

**How it tries to be safe.** The installer is written to be conservative:

- Changes are marked with a managed sentinel and are **idempotent** — install /
  uninstall are reversible and re-running doesn't duplicate anything.
- It **preserves user-authored hooks** (for Hermes it only patches an empty or
  missing `hooks:` block, never a populated one).
- Own-files it created are removed cleanly on uninstall.
- The hooks **no-op unless they're running inside a simbacode terminal** — they
  only emit when `SIMBACODE_SURFACE_ID` is set, so they stay silent in any other
  terminal.

**Honest caveats.** Today this happens automatically on first launch rather
than via an explicit opt-in dialog, and there is not yet a backup/restore or a
settings page to preview/disable it. Making installation explicit opt-in, with
a preview of changed files and backup/restore, is the planned **P0** work in
[#7](https://github.com/qike-ms/simbacode-linux/issues/7). If you'd rather not
have any config modified, set `"enabled": false` in `~/.simbacode/hooks.json`
(or don't run simbacode).

**Uninstall.** To remove all hooks and integration state:

```bash
# remove the per-agent hooks simbacode installed, then drop its state
rm -f ~/.codex/hooks.json \
      ~/.copilot/hooks/simbacode.json \
      ~/.config/opencode/plugins/simbacode-presence.js \
      ~/.hermes/agent-hooks/simbacode-presence.sh
rm -rf ~/.pi/agent/extensions/simbacode
rm -rf ~/.simbacode
# Then manually review ~/.claude/settings.json, ~/.codex/config.toml,
# ~/.kiro/agents/kiro_default.json, and ~/.hermes/config.yaml and remove the
# blocks marked with the `simbacode-managed-hook` sentinel.
```

## Relationship to Ghostty and supacode

simbacode-linux is inspired by, and deeply indebted to, two outstanding
projects:

- **[supacode](https://github.com/supabitapp/supacode)** pioneered this
  agent-centric way of working. It treats coding agents as first-class citizens
  of your workflow, makes git worktrees effortless, and surfaces exactly the
  right signal — presence, activity, and "needs you" attention — without ever
  getting in your way. **If you are on macOS, use supacode**; it is the real,
  polished thing and we admire it enormously. simbacode-linux exists to bring
  that experience to Linux, borrowing many of its ideas (the OSC-based
  agent-presence protocol, worktree-grouped sidebar, and per-tab agent
  indicators) with gratitude.
- **[Ghostty](https://ghostty.org)** provides the fast, native,
  standards-compliant terminal foundation that all of this is built on.

simbacode-linux is a separate, community project and is **not affiliated with
or endorsed by** supacode/supabit or the Ghostty project. The name is
deliberately distinct to avoid any brand confusion.

---

_The rest of this README is the upstream Ghostty documentation, retained
because simbacode-linux is a Ghostty fork and inherits its terminal._

## About Ghostty

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate actually libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

We haven't tagged libghostty with a version yet and we're still working
on a better docs experience, but our [Doxygen website](https://libghostty.tip.ghostty.org/)
is a good resource for the C API.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
