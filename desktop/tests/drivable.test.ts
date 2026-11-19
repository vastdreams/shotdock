// The send path's safety rules (renderer side), against a fake bridge.
import { describe, it, expect, beforeAll } from "vitest";
import type { Session } from "../src/shared/model";

const calls: { name: string; args: any }[] = [];
let api: typeof import("../src/renderer/api");
beforeAll(async () => {
  (globalThis as any).window = { shotdock: { platform: "darwin",
    invoke: async (name: string, args: any) => { calls.push({ name, args }); return { ok: true, value: args.fork ? "copy-id" : args.id }; },
    onState: () => () => undefined, onNav: () => () => undefined } };
  api = await import("../src/renderer/api");
});
const sess = (o: Partial<Session>): Session => ({ id: "c1", kind: "ide", owner: { kind: "ide", app: "Editor" }, folder: "/w", window: "w",
  title: "t", state: "idle", lastActivity: 0, ...o });
const notes: string[] = [];
const notify = (m: string) => { notes.push(m); };

describe("ensureDrivable", () => {
  it("a chat ShotDock runs is used as is, nothing asked", async () => {
    calls.length = 0;
    let asked = false;
    const id = await api.ensureDrivable(sess({ kind: "hosted", live: true }), async () => { asked = true; return null; }, notify);
    expect(id).toBe("c1"); expect(asked).toBe(false); expect(calls).toEqual([]);
  });
  it("ShotDock's own paused chat resumes quietly", async () => {
    calls.length = 0;
    const id = await api.ensureDrivable(sess({ kind: "hosted", live: false }), async () => { throw new Error("must not ask"); }, notify);
    expect(id).toBe("c1");
    expect(calls[0]).toEqual({ name: "session.takeOver", args: { id: "c1", fork: false, confirmClosed: true } });
  });
  it("an editor chat always asks; cancel does nothing", async () => {
    calls.length = 0;
    expect(await api.ensureDrivable(sess({}), async () => null, notify)).toBeNull();
    expect(calls).toEqual([]);
  });
  it("continue passes the confirmation; copy forks", async () => {
    calls.length = 0;
    expect(await api.ensureDrivable(sess({}), async () => "continue", notify)).toBe("c1");
    expect(calls[0].args).toEqual({ id: "c1", fork: false, confirmClosed: true });
    expect(await api.ensureDrivable(sess({}), async () => "copy", notify)).toBe("copy-id");
    expect(calls[1].args).toEqual({ id: "c1", fork: true, confirmClosed: false });
  });
  it("Cursor Agent chats are refused", async () => {
    calls.length = 0;
    expect(await api.ensureDrivable(sess({ kind: "cursor-agent" }), async () => "continue", notify)).toBeNull();
    expect(calls).toEqual([]);
  });
});
