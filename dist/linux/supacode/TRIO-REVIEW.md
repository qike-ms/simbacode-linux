# Trio code review — supacode-linux sidebar + agent-native (consolidated)

Branch reviewed: `7191adddc..81f3db5b4` (stages 4–6). Three independent
reviewers: codex (gpt-class), claude (opus), opencode (opus-4.8). Findings
below; **all CRITICAL/MAJOR items were fixed in stage-7 (`4720f03f6`)** except
where marked Deferred.

## CRITICAL — FIXED

**Surface use-after-free on split close (unanimous: codex C1, claude C1/C2,
opencode C1).** `surface_agents` and `agent_banner_surface` held raw `*Surface`
pointers, cleaned up only on whole-tab close (`clearTabAgents`). Closing one
pane of a split (tab survives) left a dangling entry; `refreshTabAgentIcon` /
`agentBannerClicked` later dereferenced freed memory. **Fix:**
`tabSplitTreeChanged` now prunes presence + attention + banner target for every
surface that leaves the tree (`treeContains` helper).

## MAJOR — FIXED

- **Attention keyed by path, not surface (claude M2, codex).** Two tabs on one
  worktree cleared each other's bell. **Fix:** `sidebar_attention` is now
  `*Surface -> path`; `pathHasAttention` aggregates for the badge.
- **Presence-only start didn't clear stale attention (codex M1).** Pi sends a
  presence refresh every turn → banner/bell latched until shutdown. **Fix:** a
  presence-only `start` clears attention for that surface.
- **Banner/notification showed raw metadata, not `comm` (unanimous: codex,
  claude M1, opencode M3).** **Fix:** extract `comm` via `fieldValue`.
- **`end` dismissed any banner regardless of owner (codex).** **Fix:**
  `hideAgentBannerFor(surface)` only dismisses this surface's banner.

## MINOR — FIXED

- Banner detail now Pango-escaped (claude m1).
- Sidebar diff aggregation uses saturating add — no overflow panic (all three).
- `supacode-signal` sanitizes inputs (strips control chars + `;`) to prevent
  OSC field injection from assistant text (codex, claude m3, opencode m1).

## Deferred (tracked in HANDOFF "Next steps")

- **Split-focus icon refresh (codex M4, claude m5).** ~~Tab icon doesn't follow
  focus changes *within* a split.~~ **FIXED (stage-8):** wired to
  `Tab.notify::active-surface` → `refreshTabAgentIcon`.
- **5s synchronous git poll on the main thread (claude M3, opencode M1/M2).**
  Move `sidebar.scan` to a worker thread + stat-cache + `Gio.FileMonitor` on
  `.git/HEAD,index,packed-refs`; diff before rebuilding the ListBox.
- **Agent crash TTL/heartbeat (claude footgun).** Presence clears on `end` and
  tab/split teardown, but a crashed agent whose surface stays open keeps its
  icon. Add a heartbeat + TTL.
- **`<id>` pairing (claude m7, codex).** Presence/attention key by surface and
  ignore `value.id`; a stray `end` from any id clears the surface's state.
  Acceptable for one-agent-per-surface; revisit for concurrent contexts.
- **OOM row-map desync (claude m2, opencode m2).** `sidebar_rows.append catch {}`
  can desync the index map under OOM (bounds-guarded, wrong-action not crash).

## Verified-OK by reviewers (no action)

dispose() teardown frees all keys/values; OSC metadata slice lifetime safe
(banner + notification copy); indicator-icon refcounting (`defer unref` after
`setIndicatorIcon`) correct; `openWorktree` reuses an existing tab for a shared
path; `sidebarRowActivated` bounds-checks; presence-vs-attention split is now
consistent (clearing attention never drops the icon).
