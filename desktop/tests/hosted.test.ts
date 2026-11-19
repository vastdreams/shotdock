// HostedSession against a scripted fake of the Agent SDK: send -> tool permission -> allow -> answer -> result,
// plus stop and fork. No network, no Claude.
import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Store, initialState } from "../src/main/core/store";
import { HostedSession, type QueryFn, type UserMsg, type CanUseTool } from "../src/main/adapters/hosted/session";

const tick = () => new Promise((r) => setTimeout(r, 30));

function fakeSdk() {
  const calls: { options: Record<string, any>; interrupted: number; models: string[] } = { options: {}, interrupted: 0, models: [] };
  const query: QueryFn = ({ prompt, options }) => {
    calls.options = options;
    const canUseTool = options.canUseTool as CanUseTool;
    async function* run() {
      yield { type: "system", subtype: "init", model: "claude-opus-5-5", session_id: options.sessionId };
      for await (const m of prompt as AsyncIterable<UserMsg>) {
        const text = (m.message.content.find((b: any) => b.type === "text") as any)?.text ?? "";
        yield { type: "assistant", uuid: `a-${text}`, parent_tool_use_id: null, message: { role: "assistant", stop_reason: "tool_use",
          content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "rm -rf build" } }] } };
        const d = await canUseTool("Bash", { command: "rm -rf build" }, { signal: new AbortController().signal, suggestions: [{ type: "addRules" }] });
        yield { type: "user", uuid: "r1", parent_tool_use_id: null, message: { role: "user",
          content: [{ type: "tool_result", tool_use_id: "t1", content: d.behavior === "allow" ? "removed" : "denied" }] } };
        yield { type: "assistant", uuid: `b-${text}`, parent_tool_use_id: null, message: { role: "assistant", stop_reason: "end_turn",
          content: [{ type: "text", text: d.behavior === "allow" ? "Cleaned." : "Skipped." }] } };
        yield { type: "result", subtype: "success", session_id: options.sessionId };
      }
    }
    const gen = run();
    return Object.assign(gen, {
      interrupt: async () => { calls.interrupted++; },
      setModel: async (m?: string) => { calls.models.push(m ?? ""); },
      setPermissionMode: async () => undefined,
      close: () => undefined,
    });
  };
  return { query, calls };
}

describe("HostedSession", () => {
  it("runs a full turn with a permission round-trip", async () => {
    const store = new Store(initialState());
    const { query, calls } = fakeSdk();
    const hs = new HostedSession(store, query, { folder: "/w/app", model: "claude-opus-5-5", permissionMode: "default", env: {} });
    store.dispatch({ t: "session.upserted", s: { id: hs.id, kind: "hosted", owner: { kind: "hosted", app: "ShotDock" },
      folder: "/w/app", window: "app", title: "t", state: "idle", lastActivity: 0 } });
    expect(calls.options.sessionId).toBe(hs.id);
    expect(calls.options.cwd).toBe("/w/app");

    hs.send("clean it", []);
    await tick();
    const s1 = store.get().sessions[hs.id];
    expect(s1.state).toBe("needs-you");
    expect(s1.needs?.summary).toBe("Bash: rm -rf build");
    expect(s1.needs?.canAlways).toBe(true);

    expect(hs.decide(s1.needs!.requestId, "allow")).toBe(true);
    await tick();
    const s2 = store.get();
    expect(s2.sessions[hs.id].state).toBe("idle");
    expect(s2.transcripts[hs.id].map((i) => i.role)).toEqual(["user", "tool", "result", "assistant"]);
    expect(s2.transcripts[hs.id].at(-1)?.text).toBe("Cleaned.");

    await hs.stop();
    expect(calls.interrupted).toBe(1);
    await hs.setModel("claude-sonnet-5-5");
    expect(calls.models).toEqual(["claude-sonnet-5-5"]);
    hs.close();
  });

  it("deny reaches Claude as a denial", async () => {
    const store = new Store(initialState());
    const { query } = fakeSdk();
    const hs = new HostedSession(store, query, { folder: "/w", model: "m", permissionMode: "default", env: {} });
    store.dispatch({ t: "session.upserted", s: { id: hs.id, kind: "hosted", owner: { kind: "hosted", app: "ShotDock" }, folder: "/w", window: "w", title: "t", state: "idle", lastActivity: 0 } });
    hs.send("go", []);
    await tick();
    hs.decide(store.get().sessions[hs.id].needs!.requestId, "deny");
    await tick();
    expect(store.get().transcripts[hs.id].at(-1)?.text).toBe("Skipped.");
    hs.close();
  });

  it("resume keeps the id; fork gets a new one and never touches the original", () => {
    const store = new Store(initialState());
    const a = fakeSdk();
    const resumed = new HostedSession(store, a.query, { id: "orig", folder: "/w", model: "m", permissionMode: "default", env: {} });
    expect(resumed.id).toBe("orig");
    expect(a.calls.options.resume).toBe("orig");
    const b = fakeSdk();
    const forked = new HostedSession(store, b.query, { id: "orig", fork: true, folder: "/w", model: "m", permissionMode: "default", env: {} });
    expect(forked.id).not.toBe("orig");
    expect(b.calls.options).toMatchObject({ resume: "orig", forkSession: true, sessionId: forked.id });
    resumed.close(); forked.close();
  });

  it("sends screenshots as image blocks", async () => {
    const store = new Store(initialState());
    let seen: any[] = [];
    const query: QueryFn = ({ prompt }) => {
      (async () => { for await (const m of prompt) seen = m.message.content as any[]; })();
      return Object.assign((async function* () {})(), { interrupt: async () => 0, setModel: async () => undefined, setPermissionMode: async () => undefined, close: () => undefined });
    };
    const png = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sd-")), "a.png");
    fs.writeFileSync(png, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const hs = new HostedSession(store, query, { folder: "/w", model: "m", permissionMode: "default", env: {} });
    hs.send("look", [png]);
    await tick();
    expect(seen[0]).toMatchObject({ type: "image", source: { type: "base64", media_type: "image/png" } });
    expect(seen[1]).toEqual({ type: "text", text: "look" });
    hs.close();
  });
});
