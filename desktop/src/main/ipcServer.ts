// One handler per request in shared/ipc.ts. Args are validated before a handler runs; every handler returns a
// Result, so the UI always gets either a value or a coded, human-readable error.

import { app, dialog, ipcMain } from "electron";
import { Requests, CHANNEL_INVOKE, ok, fail, type Result, type RequestName } from "../shared/ipc";
import type { Store } from "./core/store";
import type { SettingsFile } from "./core/settings";
import type { HostedManager } from "./adapters/hosted/manager";
import type { ClaudeProjectsWatcher } from "./adapters/watch/claudeProjects";
import type { CursorAgentsWatcher } from "./adapters/watch/cursorAgents";
import type { Capture } from "./capture/capture";
import type { Windows } from "./windows";
import { openInEditor } from "./adapters/editors";
import { log } from "./core/log";

export interface Deps {
  store: Store; settings: SettingsFile; hosted: HostedManager; claude: ClaudeProjectsWatcher; cursor: CursorAgentsWatcher;
  capture: Capture; windows: Windows; openTranscripts: Set<string>; onSettingsChanged(): void; quit(): void;
}

type Handler = (args: any) => Promise<Result<unknown>> | Result<unknown>;

export function handlers(d: Deps): Record<RequestName, Handler> {
  const session = (id: string) => d.store.get().sessions[id];
  const saveSettings = (patch: object) => {
    const next = { ...d.store.get().settings, ...patch };
    d.settings.save(next);
    d.store.dispatch({ t: "settings.set", settings: { ...next, hasApiKey: d.settings.hasKey() } });
    d.onSettingsChanged();
  };

  return {
    "state.get": () => ok(),
    "transcript.load": ({ id }) => {
      d.openTranscripts.add(id);
      if (d.hosted.has(id) && d.store.get().transcripts[id]) return ok();
      const s = session(id);
      if (!s) return fail("unknown_session", "That chat is no longer listed.");
      const loaded = s.kind === "cursor-agent" ? d.cursor.load(id) : d.claude.load(id);
      return loaded || d.hosted.has(id) ? ok() : fail("no_transcript", "Could not read this chat's transcript.");
    },
    "transcript.close": ({ id }) => { d.openTranscripts.delete(id); return ok(); },
    "session.new": async ({ folder, prompt, model }) => {
      const r = await d.hosted.create(folder, prompt, model);
      if (r.ok) d.openTranscripts.add(r.value as string);
      return r;
    },
    "session.send": ({ id, text, shotIds }) => {
      const shots = d.store.get().shots.filter((s) => shotIds.includes(s.id));
      const r = d.hosted.send(id, text, shots.map((s) => s.path));
      if (r.ok) for (const s of shots) d.store.dispatch({ t: "shot.removed", id: s.id });
      return r;
    },
    "session.stop": ({ id }) => d.hosted.stop(id),
    "session.permission": ({ id, requestId, decision }) => d.hosted.decide(id, requestId, decision),
    "session.takeOver": async ({ id, fork }) => {
      const s = session(id);
      if (!s) return fail("unknown_session", "That chat is no longer listed.");
      if (s.kind === "cursor-agent") return fail("unsupported", "Cursor Agent chats can be read here but not driven. Open them in Cursor.");
      const prior = d.store.get().transcripts[id] ?? [];
      const r = await d.hosted.takeOver(id, s.folder, s.title, d.claude.externallyLive(id), fork);
      if (!r.ok) return r;
      const newId = r.value as string;
      d.openTranscripts.add(newId);
      if (newId === id) { if (!prior.length) d.claude.load(id); }
      else d.store.dispatch({ t: "transcript.set", id: newId, items: prior });
      return r;
    },
    "session.handBack": async ({ id }) => {
      d.hosted.release(id);
      d.store.dispatch({ t: "session.patch", id, patch: { kind: "ide", owner: { kind: "ide", app: "Editor" }, state: "idle", needs: undefined } });
      const ed = await openInEditor(id);
      return ed ? ok(ed) : fail("no_editor", "No editor with the Claude Code extension was found. The chat is released; resume it with `claude --resume`.");
    },
    "session.openInEditor": async ({ id }) => {
      const ed = await openInEditor(id);
      return ed ? ok(ed) : fail("no_editor", "No supported editor is installed.");
    },
    "session.setModel": ({ id, model }) => d.hosted.setModel(id, model),
    "shot.capture": async ({ mode }) => {
      const shot = await d.capture.take(mode);
      if (!shot) return fail("cancelled", "Screenshot cancelled.");
      d.store.dispatch({ t: "shot.added", shot });
      d.windows.showHub({ choose: shot.id });
      return ok(shot.id);
    },
    "shot.paste": ({ dataUrl }) => {
      const shot = d.capture.fromDataUrl(dataUrl);
      if (!shot) return fail("bad_image", "Only PNG, JPEG and WebP images can be attached.");
      d.store.dispatch({ t: "shot.added", shot });
      return ok(shot.id);
    },
    "shot.remove": ({ id }) => { d.store.dispatch({ t: "shot.removed", id }); return ok(); },
    "shot.clear": () => { d.store.dispatch({ t: "shot.cleared" }); return ok(); },
    "folder.pick": async () => {
      const r = await dialog.showOpenDialog({ properties: ["openDirectory", "createDirectory"], title: "Folder for the new chat" });
      return r.canceled || !r.filePaths[0] ? fail("cancelled", "No folder chosen.") : ok(r.filePaths[0]);
    },
    "settings.update": (patch) => { saveSettings(patch); return ok(); },
    "settings.setApiKey": ({ key }) => {
      try { d.settings.setKey(key.trim()); } catch (e) { return fail("keychain", String(e)); }
      saveSettings({});
      return ok();
    },
    "settings.test": () => d.hosted.test(),
    "window.show": ({ view, sessionId }) => { d.windows.showHub(sessionId ? { open: sessionId } : { view }); return ok(); },
    "window.hideWidget": () => { d.windows.widget?.hide(); return ok(); },
    "app.quit": () => { d.quit(); return ok(); },
  };
}

export function registerIpc(d: Deps): void {
  const map = handlers(d);
  ipcMain.handle(CHANNEL_INVOKE, async (_e, name: string, raw: unknown): Promise<Result<unknown>> => {
    if (!(name in Requests)) return fail("unknown_request", `Unknown request: ${name}`);
    const parsed = Requests[name as RequestName].safeParse(raw ?? {});
    if (!parsed.success) return fail("bad_args", parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; "));
    try { return await map[name as RequestName](parsed.data); }
    catch (e) {
      log("error", "ipc", "handler threw", { name, err: String(e) });
      return fail("internal", String(e).slice(0, 300));
    }
  });
  app.on("will-quit", () => ipcMain.removeHandler(CHANNEL_INVOKE));
}
