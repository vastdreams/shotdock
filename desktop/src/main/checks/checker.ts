// Claim checker: after a turn, find what the assistant claimed ("tests pass", "deployed", "sent") and check each
// claim against the evidence in the same turn (tool calls and their results). Never sends anything to the chat;
// the UI offers the suggested follow-up for the user to send.

import type { TranscriptItem } from "../../shared/model";

export interface Claim { claim: string; verdict: "supported" | "unsupported" | "unclear"; why: string }
export interface ClaimReport { at: number; claims: Claim[]; followup?: string }

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n) + " …[cut]" : s);

/** The last turn: from the last user message to the end. */
export function lastTurn(items: TranscriptItem[]): TranscriptItem[] {
  let i = items.length - 1;
  while (i >= 0 && items[i].role !== "user") i--;
  return items.slice(Math.max(0, i));
}

export function buildPrompt(turn: TranscriptItem[]): string {
  const lines = turn.map((it) => {
    if (it.role === "user") return `USER: ${clip(it.text, 1500)}`;
    if (it.role === "tool") return `TOOL CALL ${it.key.replace(/^tool-/, "")}: ${it.tool?.name} ${clip(it.tool?.input ?? "", 400)}`;
    if (it.role === "result") return `TOOL RESULT for ${it.tool?.input}${it.tool?.isError ? " (ERROR)" : ""}: ${clip(it.text, 1200)}`;
    return `ASSISTANT: ${clip(it.text, 4000)}`;
  });
  return [
    "You audit a coding agent's last turn. List each concrete claim the ASSISTANT makes about work done or facts",
    "(tests passing, files changed, deployed, sent, fixed, verified). For each, judge it ONLY from the tool calls and",
    "results shown: supported (a result shows it), unsupported (a result contradicts it, or it claims something no",
    "tool did), or unclear (plausible but not shown). Ignore plans and opinions. If anything is unsupported, write",
    "one short follow-up message the user could send asking the agent to prove or fix it.",
    'Reply with JSON only: {"claims":[{"claim":"...","verdict":"supported|unsupported|unclear","why":"..."}],"followup":"..."}',
    "", "TURN:", ...lines,
  ].join("\n");
}

export function parseReport(text: string): ClaimReport {
  const m = /\{[\s\S]*\}/.exec(text);
  if (!m) throw new Error("The checker did not return JSON.");
  const raw = JSON.parse(m[0]) as { claims?: Claim[]; followup?: string };
  const claims = (raw.claims ?? []).filter((c) => c && typeof c.claim === "string")
    .map((c) => ({ claim: c.claim.slice(0, 300), verdict: (["supported", "unsupported", "unclear"].includes(c.verdict) ? c.verdict : "unclear") as Claim["verdict"], why: String(c.why ?? "").slice(0, 400) }));
  const followup = claims.some((c) => c.verdict === "unsupported") && raw.followup ? String(raw.followup).slice(0, 600) : undefined;
  return { at: Date.now(), claims, followup };
}
