#!/usr/bin/env bash
# Install the native (no-nix) build dependencies that this distro lacks:
#   1. blueprint-compiler >= 0.16  (apt ships 0.12; pure-python)
#   2. gtk4-layer-shell            (not packaged; needed for the Wayland build)
# Everything else (zig 0.15.2, gtk4, libadwaita, wayland) is already native.
#
# Installs to ~/.local (no root). Re-runnable.
set -euo pipefail

LOCAL="${HOME}/.local"
mkdir -p "${LOCAL}/lib" "${LOCAL}/bin"

# ---------------------------------------------------------------------------
# 1. blueprint-compiler 0.16.0
# ---------------------------------------------------------------------------
BP_VERSION="0.16.0"
BP_SRC="/tmp/blueprint-compiler-${BP_VERSION}"
BP_LIB="${LOCAL}/lib/blueprint-compiler"

rm -rf "$BP_SRC"
git clone --depth 1 -b "v${BP_VERSION}" \
  https://gitlab.gnome.org/jwestman/blueprint-compiler.git "$BP_SRC"
rm -rf "$BP_LIB"
cp -r "$BP_SRC" "$BP_LIB"
# Bake the version (meson normally substitutes this at install time).
sed -i "s/^VERSION = \"uninstalled\"/VERSION = \"${BP_VERSION}\"/" \
  "${BP_LIB}/blueprintcompiler/main.py"
cat > "${LOCAL}/bin/blueprint-compiler" <<EOF
#!/usr/bin/env python3
import sys, os
sys.path.insert(0, os.path.expanduser("~/.local/lib/blueprint-compiler"))
from blueprintcompiler import main
main.main("${BP_VERSION}", None)
EOF
chmod +x "${LOCAL}/bin/blueprint-compiler"
echo "Installed blueprint-compiler $("${LOCAL}/bin/blueprint-compiler" --version)"

# ---------------------------------------------------------------------------
# 2. gtk4-layer-shell (Wayland layer-shell; needed unless you build X11-only)
#    Built with meson+ninja from a throwaway venv so we don't touch system pip.
# ---------------------------------------------------------------------------
GLS_SRC="/tmp/gtk4-layer-shell"
BUILD_VENV="${LOCAL}/share/gtklayershell-build-venv"

python3 -m venv "$BUILD_VENV"
"${BUILD_VENV}/bin/pip" install -q meson ninja

rm -rf "$GLS_SRC"
git clone --depth 1 https://github.com/wmww/gtk4-layer-shell.git "$GLS_SRC"
cd "$GLS_SRC"
PATH="${BUILD_VENV}/bin:$PATH" meson setup build \
  --prefix="$LOCAL" \
  -Dexamples=false -Ddocs=false -Dtests=false -Dvapi=false
PATH="${BUILD_VENV}/bin:$PATH" ninja -C build
PATH="${BUILD_VENV}/bin:$PATH" meson install -C build
echo "Installed gtk4-layer-shell to ${LOCAL}/lib/x86_64-linux-gnu"

cat <<'NOTE'

Done. Ensure ~/.local/bin is on PATH (ahead of /usr/bin for blueprint-compiler).
Build the project with:

  PKG_CONFIG_PATH="$HOME/.local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH" \
  LIBRARY_PATH="$HOME/.local/lib/x86_64-linux-gnu:$LIBRARY_PATH" \
  zig build -Demit-macos-app=false \
    --search-prefix "$HOME/.local" \
    -Dpatch-rpath="$HOME/.local/lib/x86_64-linux-gnu"

(-Dpatch-rpath bakes the gtk4-layer-shell path into the binary so it runs
without LD_LIBRARY_PATH. Wayland and X11 are both enabled.)
NOTE
