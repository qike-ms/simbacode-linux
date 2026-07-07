#!/usr/bin/env bash
# Build the release binary and install it as ~/.local/bin/simbacode, reliably —
# even while an old simbacode is still running.
#
# Why this exists:
#   * `cp zig-out/bin/ghostty ~/.local/bin/simbacode` fails with
#     "Text file busy" (ETXTBSY) when a simbacode process currently maps that
#     file. This script installs via a temp file + atomic `mv` (rename), which
#     succeeds regardless: the running process keeps its old inode, and the
#     next launch picks up the new one.
#   * The plain `zig build` in the README omits the PKG_CONFIG_PATH /
#     LIBRARY_PATH that gtk4-layer-shell needs, so it fails to link. This wraps
#     the exact env the build requires.
#
# Usage:
#   scripts/install-binary.sh            # build (ReleaseFast) + install
#   scripts/install-binary.sh --no-build # install the existing zig-out binary
#   DEST=/path/to/simbacode scripts/install-binary.sh   # override install path
set -euo pipefail

cd "$(dirname "$0")/.."

LOCAL="${HOME}/.local"
DEST="${DEST:-${LOCAL}/bin/simbacode}"
SRC="zig-out/bin/ghostty"

build=1
[[ "${1:-}" == "--no-build" ]] && build=0

if [[ "$build" == 1 ]]; then
  echo "==> Building (ReleaseFast)…"
  PKG_CONFIG_PATH="${LOCAL}/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}" \
  LIBRARY_PATH="${LOCAL}/lib/x86_64-linux-gnu:${LIBRARY_PATH:-}" \
  zig build -Demit-macos-app=false -Doptimize=ReleaseFast \
    --search-prefix "${LOCAL}" \
    -Dpatch-rpath="${LOCAL}/lib/x86_64-linux-gnu"
fi

if [[ ! -x "$SRC" ]]; then
  echo "error: $SRC not found (build failed or --no-build with no prior build)" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"

# Atomic install: write next to the destination (same filesystem, so rename is
# atomic and never hits ETXTBSY), then rename over the target.
tmp="${DEST}.new.$$"
trap 'rm -f "$tmp"' EXIT
cp "$SRC" "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$DEST"
trap - EXIT

echo "==> Installed $DEST"
ls -la "$DEST"

# Warn if an old process is still running the previous inode.
if pgrep -f "$DEST" >/dev/null 2>&1; then
  echo
  echo "NOTE: a simbacode process is still running the OLD binary."
  echo "      Fully quit it and relaunch to pick up this build."
fi
