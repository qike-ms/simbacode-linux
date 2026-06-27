/* supacode-managed-extension */
// # supacode-managed-hook
/**
 * Supacode + Pi integration extension.
 *
 * Reports agent lifecycle and notifications to Supacode by emitting OSC 3008
 * escape sequences to the controlling terminal. Inert in any terminal that
 * does not handle OSC 3008, and reaches Supacode over SSH too (no local
 * socket needed), matching the Claude / Codex / Kiro hook integrations.
 *
 * Required env (injected by Supacode on every surface):
 *   SUPACODE_SURFACE_ID  present only on a Supacode surface; absence is the
 *                        no-op gate.
 * Optional:
 *   SUPACODE_SOCKET_PATH present only on the local host; gates the local pid
 *                        so the app's liveness sweep can reap a crashed agent.
 *
 * Hook event mapping:
 *   extension load      -> session_start
 *   Pi agent_start      -> busy
 *   Pi agent_end        -> idle + notification with last_assistant_message
 *   Pi session_shutdown -> session_end + idle
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { openSync, writeSync, closeSync } from "node:fs";

interface NotifyContent {
  title?: string;
  body?: string;
}

const AGENT = "pi";
const TITLE_BUDGET = 160;
const BODY_BUDGET = 1000;

let lastWarnedAt = 0;
const WARN_INTERVAL_MS = 60_000;

function isSupacodeSurface(): boolean {
  const id = process.env["SUPACODE_SURFACE_ID"];
  return !!id && id.length > 0;
}

function localPidSuffix(): string {
  return process.env["SUPACODE_SOCKET_PATH"] ? `;pid=${process.pid}` : "";
}

function writeToTerminal(sequence: string): void {
  try {
    const fd = openSync("/dev/tty", "w");
    try {
      const bytes = Buffer.from(sequence, "utf8");
      let offset = 0;
      while (offset < bytes.length) {
        try {
          const written = writeSync(fd, bytes, offset, bytes.length - offset);
          if (written <= 0) throw new Error(`short write (${offset}/${bytes.length})`);
          offset += written;
        } catch (writeErr) {
          const code = (writeErr as NodeJS.ErrnoException).code;
          if (code === "EINTR" || code === "EAGAIN") continue;
          throw writeErr;
        }
      }
    } finally {
      closeSync(fd);
    }
  } catch (err) {
    const now = Date.now();
    if (now - lastWarnedAt > WARN_INTERVAL_MS) {
      lastWarnedAt = now;
      const e = err as NodeJS.ErrnoException;
      process.stderr.write(`supacode: OSC emit failed: ${e.code ?? ""} ${e.message ?? String(err)}\n`);
    }
  }
}

function emitPresence(event: string): void {
  const action = event === "session_end" ? "end" : "start";
  const meta = `event=${event}${localPidSuffix()}`;
  writeToTerminal(`\x1b]3008;${action}=${AGENT};${meta}\x1b\\`);
}

function notifyField(value: string, budget: number): string {
  const escaped = JSON.stringify(value).slice(1, -1);
  const buf = Buffer.from(escaped, "utf8");
  const capped = buf.length > budget ? buf.subarray(0, budget) : buf;
  return capped.toString("base64");
}

function emitNotification(content: NotifyContent): void {
  const meta =
    `kind=notify` +
    `;title=${notifyField(content.title ?? "", TITLE_BUDGET)}` +
    `;body=${notifyField(content.body ?? "", BODY_BUDGET)}`;
  writeToTerminal(`\x1b]3008;start=${AGENT};${meta}\x1b\\`);
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
  if (!isSupacodeSurface()) return;
  emitPresence("session_start");

  pi.on("agent_start", (_event, _ctx) => {
    emitPresence("busy");
  });

  pi.on("agent_end", (_event, ctx) => {
    emitPresence("idle");
    emitNotification({ body: lastAssistantText(ctx) });
  });

  pi.on("session_shutdown", (_event, _ctx) => {
    emitPresence("session_end");
    emitPresence("idle");
  });
}
