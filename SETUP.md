# SETUP — building & running supacode-linux (release)

A Ghostty fork (GTK4/libadwaita) with a worktree sidebar + AI-agent integration.
**No nix.** Builds natively against system GTK4/libadwaita + zig 0.15.2.

## One-time: install the two missing build deps

The distro lacks `blueprint-compiler >= 0.16` (apt ships 0.12) and `gtk4-layer-shell`
(needed for the Wayland build). Install both to `~/.local` (no root):

```bash
scripts/install-build-deps.sh
```

Make sure `~/.local/bin` is on your `PATH` (ahead of `/usr/bin`).

## Build (ReleaseFast — fast, optimized)

```bash
export PATH="$HOME/.local/bin:$PATH"
PKG_CONFIG_PATH="$HOME/.local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH" \
LIBRARY_PATH="$HOME/.local/lib/x86_64-linux-gnu:$LIBRARY_PATH" \
zig build -Demit-macos-app=false -Doptimize=ReleaseFast \
  --search-prefix "$HOME/.local" \
  -Dpatch-rpath="$HOME/.local/lib/x86_64-linux-gnu"
```

- `-Doptimize=ReleaseFast` — max speed (no safety checks). Use `ReleaseSafe` for
  speed + bounds/overflow checks; omit `-Doptimize` for the (slow) debug build.
- `-Demit-macos-app=false` — skip the macOS app bundle (not needed on Linux).
- `--search-prefix` + `-Dpatch-rpath` — find `gtk4-layer-shell` in `~/.local`
  and bake its path into the binary so it runs without `LD_LIBRARY_PATH`.
- Wayland **and** X11 are both enabled (do not pass `-Dgtk-wayland=false`).

Build takes ~90s. Binary lands at `zig-out/bin/ghostty`.

## Install the binary for everyday use

```bash
cp zig-out/bin/ghostty ~/.local/bin/supacode
chmod +x ~/.local/bin/supacode
```

A prebuilt copy is already installed at **`~/.local/bin/supacode`**.

## Run

```bash
supacode            # native Wayland (or X11)
# Force X11 if a Wayland session misbehaves:
GDK_BACKEND=x11 supacode
```

## Other

- Targeted tests: `zig build test -Dtest-filter=<name>` (full suite is slow).
- Format: `zig fmt .`
- First launch installs supacode agent hooks into `~/.codex`, `~/.claude`,
  `~/.pi`, `~/.config/opencode`, etc. (toggle/state in `~/.supacode/hooks.json`).
  They are guarded to no-op outside a supacode terminal surface.
