/**
 * Supacode (Linux) ↔ Pi integration extension.
 *
 * Reports agent lifecycle to supacode-linux via OSC-3008 (Hierarchical Context
 * Signalling) written to the controlling terminal. Unlike the macOS build —
 * which injects a Unix-domain socket + env vars — the Linux build routes agent
 * presence/attention over the terminal escape stream, which the emulator
 * already delivers to the exact surface the agent runs in. No socket, no env
 * injection, no PID→surface mapping.
 *
 * Event mapping:
 *   extension load   → start (presence)   → tab icon appears
 *   Pi agent_start   → (presence refresh) → keeps the icon while working
 *   Pi agent_end     → start (attention)  → top banner + notification + bell,
 *                                            carrying the last assistant message
 *   Pi session_shutdown → end             → tab icon + attention cleared
 *
 * The OSC sequences (ESC ] 3008 ; ... BEL):
 *   start:  3008;start=<id>;agent=pi[;attention=1][;comm=<detail>]
 *   end:    3008;end=<id>
 *
 * Best-effort: writes go to the tty via process.stdout; failures are swallowed.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const ESC = "\u001B";
const BEL = "\u0007";
const OSC = "3008";

// A stable per-process context id so start/end pair up.
const CONTEXT_ID = `pi-${process.pid}`;

function emit(seq: string): void {
  try {
    process.stdout.write(seq);
  } catch {
    // best-effort
  }
}

/** Sanitize a metadata value: OSC 3008 fields are semicolon-separated, and the
 *  context id range is 0x20–0x7e. Strip control chars and ';' to avoid
 *  corrupting the sequence; collapse whitespace; cap length. */
function sanitize(value: string, max = 120): string {
  return value
    .replace(/[\u0000-\u001F\u007F;]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
}

function start(opts: { attention?: boolean; detail?: string } = {}): void {
  let seq = `${ESC}]${OSC};start=${CONTEXT_ID};agent=pi`;
  if (opts.attention) seq += ";attention=1";
  if (opts.detail) {
    const d = sanitize(opts.detail);
    if (d.length > 0) seq += `;comm=${d}`;
  }
  seq += BEL;
  emit(seq);
}

function end(): void {
  emit(`${ESC}]${OSC};end=${CONTEXT_ID}${BEL}`);
}

function lastAssistantText(ctx: { sessionManager: { getEntries(): any[] } }): string | undefined {
  const entries = ctx.sessionManager.getEntries();
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry.type !== "message") continue;
    if (entry.message.role !== "assistant") continue;
    const content = entry.message.content;
    if (!Array.isArray(content)) continue;
    const text = content
      .filter((c: { type: string; text?: string }) => c.type === "text" && typeof c.text === "string")
      .map((c: { text: string }) => c.text)
      .join("")
      .trim();
    if (text.length > 0) return text;
  }
  return undefined;
}

export default function (pi: ExtensionAPI) {
  // Extension load = agent process running: announce presence (tab icon).
  start();

  pi.on("agent_start", async (_event, _ctx) => {
    // Refresh presence at the start of each turn (idempotent).
    start();
  });

  pi.on("agent_end", async (_event, ctx) => {
    // Turn finished and the agent is now waiting on the user: request
    // attention, carrying a short summary of the last assistant message.
    const detail = lastAssistantText(ctx);
    start({ attention: true, detail });
  });

  pi.on("session_shutdown", async (_event, _ctx) => {
    // Clear presence + attention so no stale tab icon / banner survives.
    end();
  });

  // Defensive: clear on process exit too (covers crashes that still run the
  // exit handler — a hard kill is handled by the terminal on surface teardown).
  process.on("exit", () => {
    end();
  });
}
