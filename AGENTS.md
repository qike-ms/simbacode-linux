# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
  - Prefer to run targeted tests with `-Dtest-filter` because the full
    test suite is slow to run.
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --strict --fix`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## Working principles (non-negotiable)

### Do everything to achieve the goal — never dismiss a challenge

When something doesn't work or a reviewer/user pushes back, DO NOT take the
easy escape (disable the feature, remove the capability, "fall back"). That is
lazy and erodes trust. Instead:

- **Research first.** Read the actual source, the official online docs, and
  real examples before concluding something "isn't possible" or "isn't
  exposed". If the answer isn't in local files, search the web / vendor repo.
- **Assume the capability exists** until proven otherwise by primary sources.
  If the user says "I wrote X myself and I know Y is possible", believe them
  and go find how.
- **Fix the root cause**, then keep the capability. Only degrade as a genuine
  last resort, and only after exhausting the real fix and saying so explicitly.
- **Prove it.** Verify the fix functionally (run it, capture output), not just
  by reasoning.

### Trio-review every change

Before considering any work done, run a trio-review: three independent
reviewer perspectives (codex / claude / opencode style — correctness,
lifetime/safety, and API/behavior fidelity). Enumerate CRITICAL / MAJOR /
MINOR findings, fix all CRITICAL/MAJOR, and note anything deferred. See
`dist/linux/simbacode/TRIO-REVIEW.md` for the established format. Do not skip
this even for small changes.

### Always install a fresh binary from the tested source state

After every `simbacode-linux` code change, run `scripts/install-binary.sh`, then
require `cmp -s zig-out/bin/ghostty ~/.local/bin/simbacode` to pass before
declaring the work done. A successful source-tree build is not a user-testable
delivery. The installer creates a fresh ReleaseFast build from the source state
that passed tests and atomically replaces the binary even while Simbacode is
running. The current process keeps its old inode until a full quit; because GTK
single-instance launches can route into that old process, the fix becomes
active only in the first fresh process after the old instance exits. Never skip
installation merely to avoid interrupting active tabs: install first, verify
the on-disk artifact, then report whether a full quit/relaunch is still needed.

### Linux GTK Fontconfig crash invariant

GTK/Pango and Simbacode must dynamically share **one system Fontconfig**. A
vendored static Fontconfig plus GTK's system `libfontconfig.so.1` corrupts
process-global Fontconfig state/cache layout and crashes renderer threads during
fallback-glyph lookup (`Fc*` / FreeType frames).

- GTK builds must use `-fsys=fontconfig`; `-fno-sys=fontconfig` is forbidden
  and must fail during the build.
- Keep the Nix package explicit (`-fsys=fontconfig`) and preserve its
  post-install ELF gate: `DT_NEEDED libfontconfig.so.1`, with no defined `Fc*`
  exports.
- Keep `scripts/install-binary.sh`'s identical pre-replacement gate. It must
  reject an unsafe artifact **before** replacing `~/.local/bin/simbacode`.
- Regression proof: run a normal installer build, verify the installed artifact
  matches `zig-out/bin/ghostty`, and run a deliberately invalid ELF fixture that
  is rejected while a destination sentinel remains unchanged.

