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

