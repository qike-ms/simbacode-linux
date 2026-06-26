#!/usr/bin/env bash
# Install blueprint-compiler 0.16.0 to ~/.local (no nix, no root).
#
# The Ghostty/GTK build requires blueprint-compiler >= 0.16.0. Debian/Ubuntu
# ship 0.12.0, which is too old. blueprint-compiler is pure-python, so we clone
# a tagged release and drop a launcher on PATH ahead of the system copy.
set -euo pipefail

VERSION="0.16.0"
SRC="/tmp/blueprint-compiler-${VERSION}"
LIB="${HOME}/.local/lib/blueprint-compiler"
BIN="${HOME}/.local/bin/blueprint-compiler"

rm -rf "$SRC"
git clone --depth 1 -b "v${VERSION}" \
  https://gitlab.gnome.org/jwestman/blueprint-compiler.git "$SRC"

mkdir -p "${HOME}/.local/lib" "${HOME}/.local/bin"
rm -rf "$LIB"
cp -r "$SRC" "$LIB"

# Bake the version (meson normally substitutes this at install time).
sed -i "s/^VERSION = \"uninstalled\"/VERSION = \"${VERSION}\"/" \
  "${LIB}/blueprintcompiler/main.py"

cat > "$BIN" <<EOF
#!/usr/bin/env python3
import sys, os
sys.path.insert(0, os.path.expanduser("~/.local/lib/blueprint-compiler"))
from blueprintcompiler import main
main.main("${VERSION}", None)
EOF
chmod +x "$BIN"

echo "Installed blueprint-compiler $("$BIN" --version) -> $BIN"
echo "Ensure ~/.local/bin is on PATH ahead of /usr/bin."
