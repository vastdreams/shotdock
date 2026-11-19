// Watches ~/.claude/projects for Claude Code sessions (editor, terminal, or earlier ShotDock runs).
// Polls every 2 s; reads only head + tail for the list, and appended bytes for transcripts that are open.

import os from "node:os";
import path from "node:path";
import type { Session, SessionKind, Owner } from "../../../shared/model";
import type { Store } from "../../core/store";
import { log } from "../../core/log";
import { emptyFacts, parseText, stateFromFacts, needsFromFacts, type Facts } from "./parse";
import { readRange } from "./files";
import { head, tail, appended, safeStat, safeReaddir } from "./files";

interface Tracked { file: string; mtime: number; size: number; facts: Facts; offset?: number }

export const claudeRoot = () => path.join(process.env.CLAUDE_CONFIG_DIR ?? path.join(os.homedir(), ".claude"), "projects");

function ownerFor(entry?: string): { kind: SessionKind; owner: Owner } {
  if (entry?.startsWith("sdk")) return { kind: "hosted", owner: { kind: "hosted", app: "ShotDock" } };
  if (entry === "cli") return { kind: "terminal", owner: { kind: "terminal", app: "Terminal" } };
  return { kind: "ide", owner: { kind: "ide", app: "Editor" } };
}

export class ClaudeProjectsWatcher {
  private tracked = new Map<string, Tracked>();
  private loaded = new Set<string>();     // sessions whose transcript the UI asked for
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private store: Store, private isOurs: (id: string) => boolean,
              private onConflict: (id: string, app: string) => void = () => undefined, private root = claudeRoot()) {}

  start(): void { this.scan(); this.timer = setInterval(() => this.scan(), 2000); }
  stop(): void { if (this.timer) clearInterval(this.timer); }

  fileFor(id: string): string | undefined { return this.tracked.get(id)?.file; }
  factsFor(id: string): Facts | undefined { return this.tracked.get(id)?.facts; }

  /** True while another process is likely writing this session (file changed in the last 10 s, turn not finished). */
  externallyLive(id: string): boolean {
    const t = this.tracked.get(id);
    if (!t) return false;
    const finished = t.facts.lastRole === "assistant" && t.facts.lastStop === "end_turn";
    return !finished && Date.now() - t.mtime < 10_000;
  }

  /** Load the last 2 MB of a transcript into the store and keep tailing it. */
  load(id: string): boolean {
    const t = this.tracked.get(id);
    if (!t) return false;
    const st = safeStat(t.file);
    if (!st) return false;
    const { items } = parseText(tail(t.file, st.size, 2_000_000));
    this.store.dispatch({ t: "transcript.set", id, items });
    t.offset = st.size;
    this.loaded.add(id);
    return true;
  }

  scan(): void {
    const cutoff = Date.now() - this.store.get().settings.recentDays * 86_400_000;
    for (const dir of safeReaddir(this.root)) {
      const full = path.join(this.root, dir);
      for (const name of safeReaddir(full)) {
        if (!name.endsWith(".jsonl")) continue;
        const file = path.join(full, name);
        const st = safeStat(file);
        if (!st || st.mtimeMs < cutoff) continue;
        const id = name.slice(0, -6);
        const prev = this.tracked.get(id);
        if (prev && prev.mtime === st.mtimeMs && prev.size === st.size) {
          // Unchanged file: only the quiet-time based state can move (working -> needs you / idle).
          if (!this.isOurs(id)) this.refreshState(id, prev);
          continue;
        }
        try { this.update(id, file, st.mtimeMs, st.size, prev); }
        catch (e) { log("warn", "watch.claude", "read failed", { id, err: String(e) }); }
      }
    }
  }

  private update(id: string, file: string, mtime: number, size: number, prev?: Tracked): void {
    let facts: Facts;
    if (prev && prev.offset !== undefined && this.loaded.has(id)) {
      const { text, next } = appended(file, prev.offset, size);
      facts = prev.facts;
      const { items } = parseText(text, facts);
      if (items.length) this.store.dispatch({ t: "transcript.append", id, items });
      prev.offset = next;
    } else {
      facts = emptyFacts();
      parseText(head(file, size, 64_000), facts);
      parseText(tail(file, size, 400_000), facts);
    }
    this.tracked.set(id, { file, mtime, size, facts, offset: prev?.offset });
    if (this.isOurs(id)) {
      // Rule 2 guard: if another app writes to a chat ShotDock runs, stop ShotDock's side at once.
      if (prev && size > prev.size) {
        const added = readRange(file, prev.size, size);
        const other = /"entrypoint":"(?!sdk)([^"]+)"/.exec(added);
        if (other && /"type":"(user|assistant)"/.test(added)) this.onConflict(id, other[1]);
      }
      return; // otherwise the hosted adapter reports live state for sessions ShotDock runs
    }
    const cwd = facts.cwd ?? "";
    const { kind, owner } = ownerFor(facts.entrypoint);
    const s: Session = {
      id, kind, owner, folder: cwd, window: cwd ? path.basename(cwd) : "Unknown folder",
      title: facts.title ?? "Untitled chat", state: stateFromFacts(facts, mtime), model: facts.model, lastActivity: mtime,
      needs: this.externalNeeds(id, facts, mtime),
    };
    this.store.dispatch({ t: "session.upserted", s });
  }

  private externalNeeds(id: string, facts: Facts, mtime: number) {
    const n = needsFromFacts(facts, mtime);
    return n ? { requestId: `ext-${id}-${facts.pending?.id}`, tool: n.tool, summary: n.summary, canAlways: false, external: true } : undefined;
  }

  private refreshState(id: string, t: Tracked): void {
    const cur = this.store.get().sessions[id];
    if (!cur || cur.kind === "hosted") return;
    const state = stateFromFacts(t.facts, t.mtime);
    if (state === cur.state) return;
    this.store.dispatch({ t: "session.state", id, state, needs: state === "needs-you" ? this.externalNeeds(id, t.facts, t.mtime) : undefined });
  }
}
