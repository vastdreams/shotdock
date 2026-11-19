// One Claude Code session run by ShotDock through the Claude Agent SDK (Rule 1: programmatic input only).
// Send = push onto the streaming input; Stop = interrupt(); permissions = canUseTool awaiting the user's decision.

import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { Store } from "../../core/store";
import { log } from "../../core/log";
import { foldLine, emptyFacts } from "../watch/parse";
import type { PendingPermission } from "../../../shared/model";

// Minimal structural types for what we use from the SDK, so tests can inject a fake.
export interface UserMsg { type: "user"; message: { role: "user"; content: unknown[] }; parent_tool_use_id: null }
export type PermissionDecision =
  | { behavior: "allow"; updatedInput?: Record<string, unknown>; updatedPermissions?: unknown[] }
  | { behavior: "deny"; message: string; interrupt?: boolean };
export type CanUseTool = (tool: string, input: Record<string, unknown>,
                          o: { signal: AbortSignal; suggestions?: unknown[] }) => Promise<PermissionDecision>;
export interface QueryLike extends AsyncIterable<any> {
  interrupt(): Promise<unknown>;
  setModel(model?: string): Promise<void>;
  setPermissionMode(mode: string): Promise<void>;
  close(): void;
}
export type QueryFn = (p: { prompt: AsyncIterable<UserMsg>; options: Record<string, unknown> }) => QueryLike;

/** An async iterable we can push messages into, one at a time, until closed. */
class Inbox implements AsyncIterable<UserMsg> {
  private queue: UserMsg[] = [];
  private waiting: ((r: IteratorResult<UserMsg>) => void) | null = null;
  private closed = false;
  push(m: UserMsg) {
    if (this.closed) throw new Error("session closed");
    if (this.waiting) { const w = this.waiting; this.waiting = null; w({ value: m, done: false }); } else this.queue.push(m);
  }
  close() { this.closed = true; if (this.waiting) { this.waiting({ value: undefined as never, done: true }); this.waiting = null; } }
  [Symbol.asyncIterator](): AsyncIterator<UserMsg> {
    return {
      next: () => {
        if (this.queue.length) return Promise.resolve({ value: this.queue.shift()!, done: false });
        if (this.closed) return Promise.resolve({ value: undefined as never, done: true });
        return new Promise((r) => { this.waiting = r; });
      },
    };
  }
}

export interface HostedOptions {
  id?: string;                 // resume this session (or fork it)
  fork?: boolean;
  folder: string;
  model: string;
  permissionMode: string;
  env: Record<string, string>;
  executable?: string;         // Claude Code binary (outside app.asar when packaged)
}

function summarize(tool: string, input: Record<string, unknown>): string {
  const v = (k: string) => (typeof input[k] === "string" ? String(input[k]) : "");
  const detail = v("command") || v("file_path") || v("url") || v("pattern") || v("description") || JSON.stringify(input).slice(0, 160);
  return `${tool}: ${detail}`.slice(0, 240);
}

export function imageBlock(file: string): unknown {
  const ext = path.extname(file).toLowerCase();
  const media = ext === ".jpg" || ext === ".jpeg" ? "image/jpeg" : ext === ".gif" ? "image/gif" : ext === ".webp" ? "image/webp" : "image/png";
  return { type: "image", source: { type: "base64", media_type: media, data: fs.readFileSync(file).toString("base64") } };
}

export class HostedSession {
  readonly id: string;
  private inbox = new Inbox();
  private q: QueryLike;
  private pending = new Map<string, { resolve: (d: PermissionDecision) => void; input: Record<string, unknown>; suggestions?: unknown[] }>();
  private ended = false;

  constructor(private store: Store, query: QueryFn, o: HostedOptions) {
    // New sessions get their id up front, so the store key never changes. A fork gets a new id too.
    this.id = o.id && !o.fork ? o.id : randomUUID();
    const options: Record<string, unknown> = {
      cwd: o.folder, model: o.model, permissionMode: o.permissionMode, env: { ...process.env, ...o.env },
      canUseTool: this.canUseTool,
    };
    if (o.executable) options.pathToClaudeCodeExecutable = o.executable;
    // Never let the child think it is Electron-as-Node (set when ShotDock is launched from an editor terminal).
    for (const k of ["ELECTRON_RUN_AS_NODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDECODE", "VSCODE_PID", "VSCODE_IPC_HOOK", "VSCODE_IPC_HOOK_CLI"])
      delete (options.env as Record<string, string>)[k];
    if (o.id) { options.resume = o.id; if (o.fork) { options.forkSession = true; options.sessionId = this.id; } }
    else options.sessionId = this.id;
    this.q = query({ prompt: this.inbox, options });
    void this.pump();
  }

  private canUseTool: CanUseTool = (tool, input, { signal, suggestions }) => new Promise((resolve) => {
    const requestId = randomUUID();
    const needs: PendingPermission = { requestId, tool, summary: summarize(tool, input), canAlways: !!suggestions?.length };
    this.pending.set(requestId, { resolve, input, suggestions });
    this.store.dispatch({ t: "session.state", id: this.id, state: "needs-you", needs });
    signal.addEventListener("abort", () => this.decide(requestId, "deny"));
  });

  decide(requestId: string, decision: "allow" | "always" | "deny"): boolean {
    const p = this.pending.get(requestId);
    if (!p) return false;
    this.pending.delete(requestId);
    if (decision === "deny") p.resolve({ behavior: "deny", message: "Denied in ShotDock." });
    else p.resolve({ behavior: "allow", updatedInput: p.input, ...(decision === "always" && p.suggestions ? { updatedPermissions: p.suggestions } : {}) });
    this.store.dispatch({ t: "session.state", id: this.id, state: "working" });
    return true;
  }

  send(text: string, images: string[]): void {
    const content: unknown[] = images.map(imageBlock);
    if (text.trim()) content.push({ type: "text", text });
    if (!content.length) return;
    this.inbox.push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null });
    this.store.dispatch({ t: "transcript.append", id: this.id,
      items: [{ key: `local-${randomUUID()}`, role: "user", text, images: images.length || undefined, at: Date.now() }] });
    this.store.dispatch({ t: "session.state", id: this.id, state: "working" });
  }

  async stop(): Promise<void> {
    for (const id of [...this.pending.keys()]) this.decide(id, "deny");
    await this.q.interrupt();
  }

  setModel(model: string): Promise<void> { return this.q.setModel(model); }

  close(): void {
    this.ended = true;
    for (const id of [...this.pending.keys()]) this.decide(id, "deny");
    this.inbox.close();
    try { this.q.close(); } catch { /* already closed */ }
  }

  private async pump(): Promise<void> {
    const facts = emptyFacts();
    try {
      for await (const m of this.q) {
        if (m?.parent_tool_use_id) continue;                 // subagent traffic
        if (m?.type === "system" && m.subtype === "init") {
          this.store.dispatch({ t: "session.patch", id: this.id, patch: { model: m.model } });
        } else if (m?.type === "assistant" || m?.type === "user") {
          if (m.type === "user" && m.isSynthetic) continue;
          const items = foldLine({ type: m.type, message: m.message, uuid: m.uuid, timestamp: new Date().toISOString() }, facts);
          // Our own sends are already shown; skip the echo of plain user text.
          const add = m.type === "user" ? items.filter((i) => i.role !== "user") : items;
          if (add.length) this.store.dispatch({ t: "transcript.append", id: this.id, items: add });
          if (facts.title && facts.titleRank) this.store.dispatch({ t: "session.patch", id: this.id, patch: { title: facts.title } });
        } else if (m?.type === "result") {
          const failed = m.subtype !== "success";
          this.store.dispatch({ t: "session.state", id: this.id, state: failed ? "failed" : "idle",
                                error: failed ? `Run ended: ${m.subtype}` : undefined });
        }
      }
      if (!this.ended) this.store.dispatch({ t: "session.state", id: this.id, state: "ended" });
    } catch (e) {
      log("error", "hosted", "session stopped", { id: this.id, err: String(e) });
      this.store.dispatch({ t: "session.state", id: this.id, state: "failed", error: String(e).slice(0, 300) });
    }
  }
}
