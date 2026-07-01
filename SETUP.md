# SETUP — building & running simbacode-linux (release)

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
  -Dpatch-rpath="$HOME/.local/lib/x86_64-linux-gnu" \
  -fsys=fontconfig
```

- `-Doptimize=ReleaseFast` — max speed (no safety checks). Use `ReleaseSafe` for
  speed + bounds/overflow checks; omit `-Doptimize` for the (slow) debug build.
- `-Demit-macos-app=false` — skip the macOS app bundle (not needed on Linux).
- `--search-prefix` + `-Dpatch-rpath` — find `gtk4-layer-shell` in `~/.local`
  and bake its path into the binary so it runs without `LD_LIBRARY_PATH`.
- `-fsys=fontconfig` — **required on Linux.** Use the system `libfontconfig`
  instead of the vendored copy. GTK/pango already pull in the system
  `libfontconfig.so.1`, so statically linking the vendored fontconfig links
  *two* different versions into one process (e.g. vendored 2.14.2 using
  cache format `.cache-8` vs. system 2.15.0 using `.cache-9`). The vendored
  `Fc*` symbols are exported globally and interpose over the system library,
  so one version reads the other's mmap'd font caches with a mismatched struct
  layout and **segfaults inside `FcCompare`** (seen when a second tab triggers
  font fallback while pango renders a glyph on the main thread). Requires
  `libfontconfig-dev` (`/usr/include/fontconfig/fontconfig.h`).
- Wayland **and** X11 are both enabled (do not pass `-Dgtk-wayland=false`).

Build takes ~90s. Binary lands at `zig-out/bin/ghostty`.

## Install the binary for everyday use

```bash
cp zig-out/bin/ghostty ~/.local/bin/simbacode
chmod +x ~/.local/bin/simbacode
```

## Run

```bash
simbacode           # native Wayland (or X11)
# Force X11 if a Wayland session misbehaves:
GDK_BACKEND=x11 simbacode
```

## Other

- Targeted tests: `zig build test -Dtest-filter=<name>` (full suite is slow).
- Format: `zig fmt .`
- First launch installs simbacode agent hooks into `~/.codex`, `~/.claude`,
  `~/.pi`, `~/.config/opencode`, etc. (toggle/state in `~/.simbacode/hooks.json`).
  They are guarded to no-op outside a simbacode terminal surface. See the
  **Security model** section of [README.md](README.md) for the full list of
  files modified and how to uninstall.
