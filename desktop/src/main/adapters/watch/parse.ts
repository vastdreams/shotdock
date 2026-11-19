// Claude Code transcript (~/.claude/projects/<key>/<session>.jsonl) -> TranscriptItems and session facts.
// Pure functions, golden-tested in tests/parse.test.ts. Unknown line types are ignored, never fatal.

import type { TranscriptItem, SessionState } from "../../../shared/model";

export interface Facts {
  sessionId?: string;
  cwd?: string;
  title?: string;           // custom-title > ai-title > last-prompt
  titleRank: number;        // 3 custom, 2 ai, 1 prompt, 0 none
  lastAt?: number;
  lastStop?: string;        // stop_reason of the last main-chain assistant message
  lastRole?: "user" | "assistant";
  model?: string;
  entrypoint?: string;      // "claude-vscode", "cli", "sdk-ts", ...
  pending?: { id: string; name: string; input: string }; // last tool call with no result yet
}

export const emptyFacts = (): Facts => ({ titleRank: 0 });

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n) + "…" : s);

function toolInputSummary(name: string, input: Record<string, unknown> | undefined): string {
  if (!input) return "";
  const pick = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : "");
  const direct = pick("command") || pick("file_path") || pick("pattern") || pick("url") || pick("query") || pick("description") || pick("prompt");
  return clip(direct || JSON.stringify(input), 400);
}

function blockText(c: unknown): string {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.map((b) => (b && typeof b === "object" && (b as { type?: string }).type === "text" ? (b as { text: string }).text : "")).join("");
  return "";
}

/** Fold one parsed line into the facts and return the items it adds. */
export function foldLine(o: Record<string, any>, facts: Facts): TranscriptItem[] {
  const at = typeof o.timestamp === "string" ? Date.parse(o.timestamp) : undefined;
  if (at && (!facts.lastAt || at > facts.lastAt)) facts.lastAt = at;
  if (o.sessionId && !facts.sessionId) facts.sessionId = o.sessionId;
  if (o.cwd && !facts.cwd) facts.cwd = o.cwd;
  if (o.entrypoint && !facts.entrypoint) facts.entrypoint = o.entrypoint;

  switch (o.type) {
    case "custom-title": if (o.customTitle) { facts.title = o.customTitle; facts.titleRank = 3; } return [];
    case "ai-title": if (o.aiTitle && facts.titleRank <= 2) { facts.title = o.aiTitle; facts.titleRank = 2; } return [];
    case "last-prompt": if (o.lastPrompt && facts.titleRank <= 1) { facts.title = clip(o.lastPrompt, 80); facts.titleRank = 1; } return [];
    case "user": case "assistant": break;
    default: return [];
  }
  if (o.isSidechain) return [];     // subagent traffic; the parent shows its result
  const msg = o.message ?? {};
  const key = o.uuid ?? `${o.type}-${at ?? Math.random()}`;
  const out: TranscriptItem[] = [];

  if (o.type === "user") {
    const content = msg.content;
    if (typeof content === "string") {
      out.push({ key, role: "user", text: content, at });
    } else if (Array.isArray(content)) {
      let text = "", images = 0;
      for (const b of content) {
        if (b?.type === "text") text += b.text;
        else if (b?.type === "image") images++;
        else if (b?.type === "tool_result") {
          if (facts.pending?.id === b.tool_use_id) facts.pending = undefined;
          const res = clip(blockText(b.content), 2000);
          out.push({ key: `res-${b.tool_use_id}`, role: "result", text: res, at,
                     tool: { name: "result", input: b.tool_use_id ?? "", output: res, isError: !!b.is_error } });
        }
      }
      if (text || images) out.unshift({ key, role: "user", text, images: images || undefined, at });
    }
    if (out.some((i) => i.role === "user")) facts.lastRole = "user";
    return out;
  }

  // assistant
  if (msg.model) facts.model = msg.model;
  facts.lastRole = "assistant";
  facts.lastStop = msg.stop_reason ?? facts.lastStop;
  const blocks: any[] = Array.isArray(msg.content) ? msg.content : [];
  blocks.forEach((b, i) => {
    if (b?.type === "text" && b.text?.trim()) out.push({ key: `${key}-${i}`, role: "assistant", text: b.text, at });
    else if (b?.type === "tool_use") {
      const input = toolInputSummary(b.name, b.input);
      facts.pending = { id: b.id, name: b.name, input };
      out.push({ key: `tool-${b.id}`, role: "tool", text: "", at, tool: { name: b.name, input } });
    }
  });
  return out;
}

/** Parse a whole file's text (or a chunk of complete lines). */
export function parseText(text: string, facts: Facts = emptyFacts()): { items: TranscriptItem[]; facts: Facts } {
  const items: TranscriptItem[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let o: Record<string, any>;
    try { o = JSON.parse(line); } catch { continue; }   // a half-written last line is read again next time
    items.push(...foldLine(o, facts));
  }
  return { items, facts };
}

/** Tools that always wait for a person, whatever the permission settings. */
const ASKS_PERSON = new Set(["AskUserQuestion", "ExitPlanMode"]);

/**
 * A chat in another app "needs you" when its last tool call has no result yet and the file has been quiet:
 * Claude Code writes the result as soon as a tool finishes, so silence means it is waiting on a permission
 * prompt or a question. AskUserQuestion / ExitPlanMode always count; other tools after 8 s of silence
 * (a long-running command looks the same, so the UI words it as "waiting on").
 */
export function needsFromFacts(f: Facts, mtimeMs: number, now = Date.now()): { tool: string; summary: string } | null {
  const p = f.pending;
  if (!p || f.lastRole !== "assistant" || f.lastStop !== "tool_use") return null;
  const quiet = now - mtimeMs;
  if (ASKS_PERSON.has(p.name) ? quiet < 1500 : quiet < 8000) return null;
  if (quiet > 6 * 3600_000) return null; // abandoned
  return { tool: p.name, summary: `${p.name}: ${p.input}`.slice(0, 240) };
}

/** Best guess for a session ShotDock does not own: working while the file moves, idle after a finished turn. */
export function stateFromFacts(f: Facts, mtimeMs: number, now = Date.now()): SessionState {
  const quietMs = now - mtimeMs;
  if (needsFromFacts(f, mtimeMs, now)) return "needs-you";
  if (f.lastRole === "assistant" && f.lastStop === "end_turn") return "idle";
  if (quietMs < 90_000) return "working";
  return "idle";
}
