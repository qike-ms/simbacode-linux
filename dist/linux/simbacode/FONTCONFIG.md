# Fontconfig crash invariant (Linux GTK build)

simbacode-linux must dynamically share **one system Fontconfig** with GTK/Pango.
A vendored static Fontconfig linked alongside GTK's system `libfontconfig.so.1`
corrupts process-global Fontconfig state / cache layout and crashes the renderer
thread during fallback-glyph lookup (`Fc*` / FreeType frames).

This is enforced in **simbacode-owned tooling only** — we do not modify upstream
Ghostty build files to carry this rule.

## Where it is enforced

`scripts/install-binary.sh` (the canonical simbacode delivery path):

1. Builds with `-fsys=fontconfig` so the vendored copy is never statically
   linked.
2. Before atomically replacing `~/.local/bin/simbacode`, verifies the freshly
   built artifact:
   - `readelf -d` shows `DT_NEEDED libfontconfig.so.1`;
   - `nm -D --defined-only` exports **no** `Fc*` symbols.
3. Rejects an unsafe artifact **before** the replacement, so a bad build can
   never overwrite the working binary.

## Regression proof

- A normal `scripts/install-binary.sh` build installs, and the installed
  artifact matches `zig-out/bin/ghostty`.
- A deliberately corrupted ELF fixture (DT_NEEDED `libfontconfig` name mangled)
  is rejected while a destination sentinel file remains unchanged.

## Do NOT put this in upstream files

The `-fsys=fontconfig` requirement is documented upstream in `SETUP.md`, but the
enforcement/verification stays in `scripts/install-binary.sh`. Never edit
`nix/`, `src/build/*.zig`, or `AGENTS.md` to carry this guard — those are
upstream Ghostty code and must not diverge for this.
