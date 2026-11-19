// Main-side ownership rules in the IPC handlers, with Electron and the editor link mocked.
import { describe, it, expect, vi } from "vitest";
vi.mock("electron", () => ({ app: { on: () => undefined }, dialog: {}, ipcMain: {}, shell: { openExternal: async () => undefined, openPath: async () => "" },
  systemPreferences: { getMediaAccessStatus: () => "granted", isTrustedAccessibilityClient: () => true }, desktopCapturer: {} }));
const opened: string[] = [];
vi.mock("../src/main/adapters/editors", () => ({ openInEditor: async (id: string) => { opened.push(id); return "Cursor"; } }));
const delivered: any[] = [];
vi.mock("../src/main/adapters/editorDelivery", () => ({ deliverToEditor: async (o: any) => { delivered.push(o); return { ok: true, confirmed: true }; } }));
import { handlers } from "../src/main/ipcServer";
import { Store, initialState } from "../src/main/core/store";

function setup(kind: "ide" | "hosted", live = false) {
  const store = new Store(initialState());
  store.dispatch({ t: "session.upserted", s: { id: "c1", kind, owner: { kind, app: kind === "ide" ? "Editor" : "ShotDock" }, folder: "/w", window: "w",
    title: "t", state: "idle", lastActivity: 0, live } });
  const released: string[] = [];
  const hosted = { has: (id: string) => live && id === "c1", release: (id: string) => { released.push(id); return { ok: true }; },
    takeOver: async (id: string) => ({ ok: true, value: id }) } as any;
  const h = handlers({ store, hosted, settings: {} as any, claude: { externallyLive: () => false, load: () => true, fileFor: () => "/t.jsonl" } as any,
    cursor: {} as any, capture: {} as any, windows: {} as any, openTranscripts: new Set(), onSettingsChanged() {}, quit() {} });
  return { h, store, released };
}

describe("ownership rules", () => {
  it("an editor chat cannot be continued here without confirmation", async () => {
    const { h } = setup("ide");
    const r = await h["session.takeOver"]({ id: "c1", fork: false, confirmClosed: false });
    expect(r.ok).toBe(false);
    expect((r as any).code).toBe("confirm_needed");
    expect((await h["session.takeOver"]({ id: "c1", fork: false, confirmClosed: true })).ok).toBe(true);
    expect((await h["session.takeOver"]({ id: "c1", fork: true, confirmClosed: false })).ok).toBe(true);
  });
  it("Open in editor stops ShotDock's side first when it is running the chat", async () => {
    const { h, store, released } = setup("hosted", true);
    await h["session.openInEditor"]({ id: "c1" });
    expect(released).toEqual(["c1"]);
    expect(store.get().sessions.c1.kind).toBe("ide");
    expect(opened).toContain("c1");
  });

  it("sending to an editor chat mirrors it into the editor, with no takeover and no dialog", async () => {
    const { h, released } = setup("ide");
    (h as any);
    const r = await h["session.send"]({ id: "c1", text: "hello", shotIds: [] });
    expect(r.ok).toBe(true);
    expect(delivered.at(-1)).toMatchObject({ sessionId: "c1", text: "hello", transcript: "/t.jsonl" });
    expect(released).toEqual([]);
  });
});
