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
import { openTerminal } from "./adapters/terminal";
import * as ws from "./adapters/workspace";
import { deliverToEditor } from "./adapters/editorDelivery";
import { claudeBinary } from "./adapters/hosted/manager";
import { lastTurn, buildPrompt, parseReport } from "./checks/checker";
import { systemPreferences, desktopCapturer, shell } from "electron";

const PANES = {
  screen: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
  accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
};
export function permissions() {
  if (process.platform !== "darwin") return { screen: "granted", accessibility: "granted" };
  return { screen: systemPreferences.getMediaAccessStatus("screen"), accessibility: systemPreferences.isTrustedAccessibilityClient(false) ? "granted" : "denied" };
}
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
    "session.send": async ({ id, text, shotIds }) => {
      const shots = d.store.get().shots.filter((s) => shotIds.includes(s.id));
      const notes = shots.map((s) => s.note).filter(Boolean).join("\n\n");
      const s = session(id);
      // A chat that lives in the editor: mirror the message into that open chat, so it stays one chat in one place.
      if (s && s.kind === "ide" && !d.hosted.has(id)) {
        const r = await deliverToEditor({ sessionId: id, text: notes ? `${text}\n\n${notes}`.trim() : text,
          images: shots.map((x) => x.path), transcript: d.claude.fileFor(id), returnPid: process.pid });
        if (!r.ok) return fail("deliver_failed", r.message);
        for (const x of shots) d.store.dispatch({ t: "shot.removed", id: x.id });
        return ok(r.confirmed ? "Sent to the chat in your editor." : "Sent to the editor. It hasn't shown in the chat yet; check the editor.");
      }
      const r = d.hosted.send(id, notes ? `${text}\n\n${notes}`.trim() : text, shots.map((x) => x.path));
      if (r.ok) for (const s of shots) d.store.dispatch({ t: "shot.removed", id: s.id });
      return r;
    },
    "session.stop": ({ id }) => d.hosted.stop(id),
    "session.permission": ({ id, requestId, decision }) => d.hosted.decide(id, requestId, decision),
    "session.takeOver": async ({ id, fork, confirmClosed }) => {
      const s = session(id);
      if (!s) return fail("unknown_session", "That chat is no longer listed.");
      if (s.kind === "cursor-agent") return fail("unsupported", "Cursor Agent chats can be read here but not driven. Open them in Cursor.");
      // A chat that belongs to an editor or terminal may still be open there. Continuing it here while it is open
      // there would give it two writers, so the person must confirm they closed it (or copy it instead).
      if (!fork && s.kind !== "hosted" && !confirmClosed)
        return fail("confirm_needed", `This chat belongs to ${s.owner.app === "Terminal" ? "a terminal" : "your editor"}. Close it there first, or copy it to a new chat.`);
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
      if (d.hosted.has(id)) {   // one writer: stop ShotDock's side before the editor resumes it
        d.hosted.release(id);
        d.store.dispatch({ t: "session.patch", id, patch: { kind: "ide", owner: { kind: "ide", app: "Editor" }, state: "idle", needs: undefined } });
      }
      const ed = await openInEditor(id);
      return ed ? ok(ed) : fail("no_editor", "No supported editor is installed.");
    },
    "session.setModel": ({ id, model }) => d.hosted.setModel(id, model),
    "session.openTerminal": async ({ id, folder }) => {
      const bin = claudeBinary();
      if (!bin) return fail("no_claude", "Claude Code was not found inside ShotDock. Reinstall ShotDock.");
      const s = id ? session(id) : undefined;
      const dir = s?.folder || folder;
      if (!dir) return fail("bad_args", "Pick a chat or a folder.");
      if (s && d.hosted.has(s.id)) {
        d.hosted.release(s.id);
        d.store.dispatch({ t: "session.patch", id: s.id, patch: { kind: "terminal", owner: { kind: "terminal", app: "Terminal" }, state: "idle", needs: undefined } });
      }
      try { await openTerminal(bin, dir, s?.id); return ok(); }
      catch (e) { return fail("terminal", String(e)); }
    },
    "checks.run": async ({ id }) => {
      const s = session(id);
      if (!s) return fail("unknown_session", "That chat is no longer listed.");
      if (!d.store.get().transcripts[id]?.length) { if (s.kind === "cursor-agent") d.cursor.load(id); else d.claude.load(id); }
      const turn = lastTurn(d.store.get().transcripts[id] ?? []);
      if (!turn.some((i) => i.role === "assistant")) return fail("nothing_to_check", "There is no answer to check yet.");
      d.store.dispatch({ t: "session.patch", id, patch: { claims: { at: Date.now(), checking: true, items: [] } } });
      const r = await d.hosted.ask(buildPrompt(turn));
      if (!r.ok) { d.store.dispatch({ t: "session.patch", id, patch: { claims: { at: Date.now(), items: [], error: r.message } } }); return r; }
      try {
        const rep = parseReport(r.value ?? "");
        d.store.dispatch({ t: "session.patch", id, patch: { claims: { at: rep.at, items: rep.claims, followup: rep.followup } } });
        return ok(rep.claims.length);
      } catch (e) {
        d.store.dispatch({ t: "session.patch", id, patch: { claims: { at: Date.now(), items: [], error: String(e) } } });
        return fail("bad_reply", String(e));
      }
    },
    "shot.capture": async ({ mode }) => {
      if (process.platform === "darwin" && permissions().screen !== "granted") {
        // Asking for a screen source registers ShotDock with macOS and shows its prompt; then open the right pane.
        try { await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: { width: 1, height: 1 } }); } catch { /* prompt shown */ }
        if (permissions().screen !== "granted") {
          await shell.openExternal(PANES.screen);
          return fail("screen_permission", "Turn on ShotDock in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen ShotDock.");
        }
      }
      let shot;
      try { shot = await d.capture.take(mode); }
      catch (e) {
        if (String(e).includes("accessibility")) {
          systemPreferences.isTrustedAccessibilityClient(true);   // shows macOS's "allow ShotDock" prompt
          return fail("accessibility", "Allow ShotDock in System Settings › Privacy & Security › Accessibility, then try again.");
        }
        return fail("capture", String(e).replace(/^Error: /, ""));
      }
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
    "shot.assign": ({ id, sessionId }) => { d.store.dispatch({ t: "shot.patch", id, patch: { sessionId } }); return ok(); },
    "shot.save": ({ id, dataUrl }) => {
      const shot = d.store.get().shots.find((x) => x.id === id);
      if (!shot || !d.capture.overwrite(shot.path, dataUrl)) return fail("save_failed", "Could not save the marked-up screenshot.");
      d.store.dispatch({ t: "shot.patch", id, patch: { createdAt: Date.now() } });  // new key so previews refresh
      return ok();
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
    "permissions.get": () => ok(permissions()),
    "log.renderer": ({ level, msg }) => { log(level, "renderer", msg); return ok(); },
    "files.changes": async ({ folder }) => ok(await ws.changes(folder)),
    "files.read": async ({ folder, path: rel }) => {
      try { return ok(await ws.readFile(folder, rel)); } catch (e) { return fail("read_failed", String(e).replace(/^Error: /, "")); }
    },
    "files.write": ({ folder, path: rel, content }) => {
      try { ws.writeFile(folder, rel, content); return ok(); } catch (e) { return fail("write_failed", String(e).replace(/^Error: /, "")); }
    },
    "files.list": async ({ folder, query }) => ok(await ws.listFiles(folder, query)),
    "window.collapse": () => { d.windows.collapseToBar(); return ok(); },
    "window.expand": () => { d.windows.showHub(); return ok(); },
    "window.widgetFromBar": () => { d.windows.widgetFromBar(); return ok(); },
    "permissions.open": async ({ which }) => {
      if (which === "accessibility") systemPreferences.isTrustedAccessibilityClient(true);
      else { try { await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: { width: 1, height: 1 } }); } catch { /* ok */ } }
      if (process.platform === "darwin") await shell.openExternal(PANES[which as "screen" | "accessibility"]);
      return ok();
    },
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
