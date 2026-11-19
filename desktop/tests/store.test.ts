import { describe, it, expect } from "vitest";
import { reduce, initialState } from "../src/main/core/store";
import { Registry } from "../src/main/core/registry";
import type { Session } from "../src/shared/model";

const sess = (over: Partial<Session> = {}): Session => ({
  id: "a", kind: "ide", owner: { kind: "ide", app: "Editor" }, folder: "/w/app", window: "app", title: "T",
  state: "idle", lastActivity: 1, ...over,
});

describe("store reducer", () => {
  it("upserts and patches", () => {
    let s = reduce(initialState(), { t: "session.upserted", s: sess() });
    s = reduce(s, { t: "session.patch", id: "a", patch: { title: "New" } });
    expect(s.sessions.a.title).toBe("New");
  });

  it("never lets a watcher overwrite a hosted session (Rule 2)", () => {
    let s = reduce(initialState(), { t: "session.upserted", s: sess({ kind: "hosted", owner: { kind: "hosted", app: "ShotDock" }, state: "working" }) });
    const after = reduce(s, { t: "session.upserted", s: sess({ state: "idle" }) });
    expect(after).toBe(s);
  });

  it("dedupes transcript appends by key", () => {
    let s = reduce(initialState(), { t: "transcript.append", id: "a", items: [{ key: "1", role: "user", text: "hi" }] });
    s = reduce(s, { t: "transcript.append", id: "a", items: [{ key: "1", role: "user", text: "hi" }, { key: "2", role: "assistant", text: "yo" }] });
    expect(s.transcripts.a.map((i) => i.key)).toEqual(["1", "2"]);
  });

  it("clears needs when the state moves on", () => {
    let s = reduce(initialState(), { t: "session.upserted", s: sess() });
    s = reduce(s, { t: "session.state", id: "a", state: "needs-you", needs: { requestId: "r", tool: "Bash", summary: "Bash: ls", canAlways: false } });
    expect(s.sessions.a.needs?.requestId).toBe("r");
    s = reduce(s, { t: "session.state", id: "a", state: "working" });
    expect(s.sessions.a.needs).toBeUndefined();
  });
});

describe("registry", () => {
  it("refuses to claim a session another app is writing", () => {
    const r = new Registry();
    expect(r.claim("x", true).ok).toBe(false);
    expect(r.claim("x", false).ok).toBe(true);
    expect(r.ownedByUs("x")).toBe(true);
    r.release("x");
    expect(r.ownedByUs("x")).toBe(false);
  });
});
