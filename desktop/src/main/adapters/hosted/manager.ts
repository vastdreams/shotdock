// Starts, resumes, forks and ends hosted sessions, and holds the connection settings they run with.

import os from "node:os";
import path from "node:path";
import type { Store } from "../../core/store";
import type { Registry } from "../../core/registry";
import type { SettingsFile } from "../../core/settings";
import { log } from "../../core/log";
import { HostedSession, type QueryFn } from "./session";
import { ok, fail, type Result } from "../../../shared/ipc";

// Load the ESM SDK from CommonJS without the bundler rewriting import() into require().
const dynamicImport = new Function("s", "return import(s)") as (s: string) => Promise<any>;
let sdkQuery: QueryFn | null = null;
async function realQuery(): Promise<QueryFn> {
  if (!sdkQuery) sdkQuery = (await dynamicImport("@anthropic-ai/claude-agent-sdk")).query as QueryFn;
  return sdkQuery;
}

/** The Claude Code binary that ships with the SDK, outside app.asar when packaged (a file in an archive can't run). */
export function claudeBinary(): string | undefined {
  const name = process.platform === "win32" ? "claude.exe" : "claude";
  const pkg = `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`;
  try {
    const p = path.join(path.dirname(require.resolve(`${pkg}/package.json`)), name).replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`);
    return require("node:fs").existsSync(p) ? p : undefined;
  } catch { return undefined; }
}

export class HostedManager {
  private sessions = new Map<string, HostedSession>();

  constructor(private store: Store, private registry: Registry, private settings: SettingsFile,
              private queryOverride?: QueryFn) {}

  get(id: string): HostedSession | undefined { return this.sessions.get(id); }
  has(id: string): boolean { return this.sessions.has(id); }

  private env(): Result<Record<string, string>> {
    const s = this.store.get().settings;
    if (s.connection === "api-key") {
      const key = this.settings.readKey();
      if (!key) return fail("no_api_key", "Add an Anthropic API key in Settings, or switch to 'Use my Claude Code setup'.");
      return ok({ ANTHROPIC_API_KEY: key });
    }
    // "Use my Claude Code setup": no key is passed; Claude Code uses whatever the user configured for it.
    return ok({});
  }

  private async open(o: { id?: string; fork?: boolean; folder: string; model?: string; title: string }): Promise<Result<string>> {
    const env = this.env();
    if (!env.ok) return env;
    const st = this.store.get().settings;
    let q: QueryFn;
    try { q = this.queryOverride ?? (await realQuery()); }
    catch (e) { return fail("sdk_missing", `The Claude Agent SDK could not load: ${String(e).slice(0, 200)}`); }
    const hs = new HostedSession(this.store, q, {
      id: o.id, fork: o.fork, folder: o.folder, model: o.model ?? st.model, permissionMode: st.permissionMode, env: env.value ?? {},
      executable: claudeBinary(),
    });
    this.sessions.set(hs.id, hs);
    this.registry.claim(hs.id, false);
    this.store.dispatch({ t: "session.upserted", s: {
      id: hs.id, kind: "hosted", owner: { kind: "hosted", app: "ShotDock" }, folder: o.folder, window: path.basename(o.folder),
      title: o.title, state: "idle", model: o.model ?? st.model, lastActivity: Date.now(),
    } });
    log("info", "hosted", "opened", { id: hs.id, resumed: !!o.id, fork: !!o.fork });
    return ok(hs.id);
  }

  async create(folder: string, prompt: string, model?: string): Promise<Result<string>> {
    const r = await this.open({ folder, model, title: prompt ? prompt.slice(0, 60) : "New chat" });
    if (r.ok && prompt.trim()) this.sessions.get(r.value!)!.send(prompt, []);
    return r;
  }

  /** Resume an existing Claude Code session here. `fork` leaves the original untouched. */
  async takeOver(id: string, folder: string, title: string, externalLive: boolean, fork: boolean): Promise<Result<string>> {
    if (this.sessions.has(id)) return ok(id);
    if (!fork) {
      const c = this.registry.claim(id, externalLive);
      if (!c.ok) return fail("owned_elsewhere", c.reason);
    }
    return this.open({ id, fork, folder, title: fork ? `${title} (fork)` : title });
  }

  send(id: string, text: string, images: string[]): Result {
    const hs = this.sessions.get(id);
    if (!hs) return fail("not_owned", "ShotDock is not running this chat. Use Take over first.");
    try { hs.send(text, images); return ok(); }
    catch (e) { return fail("send_failed", String(e)); }
  }

  async stop(id: string): Promise<Result> {
    const hs = this.sessions.get(id);
    if (!hs) return fail("not_owned", "ShotDock is not running this chat.");
    await hs.stop();
    return ok();
  }

  decide(id: string, requestId: string, d: "allow" | "always" | "deny"): Result {
    const hs = this.sessions.get(id);
    return hs?.decide(requestId, d) ? ok() : fail("no_request", "That request is no longer waiting.");
  }

  async setModel(id: string, model: string): Promise<Result> {
    const hs = this.sessions.get(id);
    if (!hs) return fail("not_owned", "ShotDock is not running this chat.");
    await hs.setModel(model);
    this.store.dispatch({ t: "session.patch", id, patch: { model } });
    return ok();
  }

  /** End ShotDock's loop for this session so another app can resume it. */
  release(id: string): Result {
    const hs = this.sessions.get(id);
    if (!hs) return ok();
    hs.close();
    this.sessions.delete(id);
    this.registry.release(id);
    return ok();
  }

  closeAll(): void { for (const id of [...this.sessions.keys()]) this.release(id); }

  /** One short turn in a temp folder, not saved, to prove the connection works. Reports model and time. */
  async test(): Promise<Result<{ model: string; ms: number; source: string }>> {
    const env = this.env();
    if (!env.ok) return env;
    const started = Date.now();
    let model = "", source = "";
    try {
      const q = (this.queryOverride ?? (await realQuery())) as unknown as (p: object) => AsyncIterable<any>;
      const childEnv: Record<string, string | undefined> = { ...process.env, ...env.value };
      delete childEnv.ELECTRON_RUN_AS_NODE;
      const it = q({ prompt: "Reply with the single word OK.", options: {
        cwd: os.tmpdir(), model: this.store.get().settings.model, maxTurns: 1, persistSession: false,
        env: childEnv, tools: [], pathToClaudeCodeExecutable: claudeBinary() } });
      for await (const m of it) {
        if (m?.type === "system" && m.subtype === "init") { model = m.model; source = m.apiKeySource; }
        if (m?.type === "result") {
          if (m.subtype !== "success") return fail("test_failed", `Claude answered with an error: ${m.subtype}`);
          return ok({ model, ms: Date.now() - started, source });
        }
      }
      return fail("test_failed", "No reply from Claude.");
    } catch (e) {
      return fail("test_failed", String(e).slice(0, 300));
    }
  }
}
