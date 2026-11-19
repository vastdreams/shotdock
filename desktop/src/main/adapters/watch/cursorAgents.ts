// Watches Cursor Agent chats (read-only): ~/.cursor/projects/<key>/agent-transcripts/<id>/<id>.jsonl.
// Names and live status come from Cursor's own state database, opened read-only through the sqlite3 tool when
// it is installed (macOS ships it). Without it, the first request is the title.

import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import type { Session, TranscriptItem } from "../../../shared/model";
import type { Store } from "../../core/store";
import { head, tail, safeStat, safeReaddir } from "./files";

const root = () => path.join(os.homedir(), ".cursor", "projects");
const stateDb = () => process.platform === "win32"
  ? path.join(process.env.APPDATA ?? "", "Cursor", "User", "globalStorage", "state.vscdb")
  : path.join(os.homedir(), "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb");

const keyOf = (p: string) => p.replace(/[^A-Za-z0-9]/g, "-").replace(/^-+|-+$/g, "");

/** Map Cursor's folder keys back to real folders, using folders we know about plus common parents. */
export function folderIndex(known: string[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const f of known) if (f) m.set(keyOf(f), f);
  const home = os.homedir();
  for (const base of ["Desktop", "", "Developer", "Documents", "QuotechPrimary"]) {
    const dir = path.join(home, base);
    for (const n of safeReaddir(dir)) { const p = path.join(dir, n); if (!m.has(keyOf(p))) m.set(keyOf(p), p); }
  }
  return m;
}

export function parseCursor(text: string): TranscriptItem[] {
  const out: TranscriptItem[] = [];
  text.split("\n").forEach((line, i) => {
    if (!line.trim()) return;
    let o: any; try { o = JSON.parse(line); } catch { return; }
    const role = o.role === "user" ? "user" : o.role === "assistant" ? "assistant" : null;
    if (!role) return;
    const blocks: any[] = Array.isArray(o.message?.content) ? o.message.content : [];
    let text = blocks.filter((b) => b?.type === "text").map((b) => b.text).join("\n");
    if (role === "user") {
      const q = /<user_query>([\s\S]*?)<\/user_query>/.exec(text);
      if (q) text = q[1].trim();
    }
    if (text.trim()) out.push({ key: `c${i}`, role, text });
  });
  return out;
}

export class CursorAgentsWatcher {
  private seen = new Map<string, number>();
  private files = new Map<string, string>();
  private names = new Map<string, { name: string; status: string }>();
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private store: Store) {}

  start(): void { this.scan(); this.timer = setInterval(() => this.scan(), 4000); }
  stop(): void { if (this.timer) clearInterval(this.timer); }

  load(id: string): boolean {
    const f = this.files.get(id);
    const st = f ? safeStat(f) : null;
    if (!f || !st) return false;
    this.store.dispatch({ t: "transcript.set", id, items: parseCursor(tail(f, st.size, 2_000_000)) });
    return true;
  }

  private scan(): void {
    const cutoff = Date.now() - this.store.get().settings.recentDays * 86_400_000;
    const known = Object.values(this.store.get().sessions).map((s) => s.folder);
    const idx = folderIndex(known);
    const fresh: string[] = [];
    for (const proj of safeReaddir(root())) {
      const tdir = path.join(root(), proj, "agent-transcripts");
      for (const id of safeReaddir(tdir)) {
        const f = path.join(tdir, id, `${id}.jsonl`);
        const st = safeStat(f);
        if (!st || st.mtimeMs < cutoff) continue;
        this.files.set(id, f);
        if (this.seen.get(id) === st.mtimeMs) continue;
        this.seen.set(id, st.mtimeMs);
        fresh.push(id);
        const first = parseCursor(head(f, st.size, 60_000)).find((i) => i.role === "user")?.text ?? "Cursor chat";
        const folder = idx.get(proj) ?? proj;
        const meta = this.names.get(id);
        const s: Session = {
          id, kind: "cursor-agent", owner: { kind: "cursor-agent", app: "Cursor" }, folder,
          window: path.basename(folder), title: meta?.name || first.slice(0, 80),
          state: meta?.status === "generating" || Date.now() - st.mtimeMs < 90_000 ? "working" : "idle", lastActivity: st.mtimeMs,
        };
        this.store.dispatch({ t: "session.upserted", s });
      }
    }
    if (fresh.length) this.lookupNames(fresh);
  }

  /** composerData name/status, read-only. Silent no-op when sqlite3 or the database is missing. */
  private lookupNames(ids: string[]): void {
    const safe = ids.filter((i) => /^[A-Za-z0-9-]+$/.test(i));
    if (!safe.length) return;
    const sql = `select key, json_extract(value,'$.name'), json_extract(value,'$.status') from cursorDiskKV where key in (${safe.map((i) => `'composerData:${i}'`).join(",")})`;
    execFile("sqlite3", ["-readonly", "-separator", "\t", `file:${stateDb()}?mode=ro`, sql], { timeout: 4000 }, (err, out) => {
      if (err) return;
      for (const line of out.split("\n")) {
        const [key, name, status] = line.split("\t");
        if (!key) continue;
        const id = key.replace("composerData:", "");
        this.names.set(id, { name: name ?? "", status: status ?? "" });
        const cur = this.store.get().sessions[id];
        if (cur && name) this.store.dispatch({ t: "session.patch", id, patch: { title: name, state: status === "generating" ? "working" : cur.state } });
      }
    });
  }
}
