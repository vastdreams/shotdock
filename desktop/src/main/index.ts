// App entry: single instance, menu bar / tray item, hub + widget windows, global hotkeys, watchers, IPC.

import path from "node:path";
import { app, globalShortcut, Notification, BrowserWindow } from "electron";
import { Store, initialState } from "./core/store";
import { Registry } from "./core/registry";
import { SettingsFile } from "./core/settings";
import { initLog, log } from "./core/log";
import { HostedManager } from "./adapters/hosted/manager";
import { ClaudeProjectsWatcher } from "./adapters/watch/claudeProjects";
import { CursorAgentsWatcher } from "./adapters/watch/cursorAgents";
import { Capture } from "./capture/capture";
import { Windows } from "./windows";
import { AppTray } from "./tray";
import { registerIpc, handlers, type Deps } from "./ipcServer";
import { CHANNEL_STATE } from "../shared/ipc";
import type { AppState } from "../shared/model";

if (!app.requestSingleInstanceLock()) app.quit();

const isMac = process.platform === "darwin";
app.setName("ShotDock");
if (isMac) app.dock?.hide();   // lives in the menu bar; the hub shows the dock icon while open (see below)

app.whenReady().then(() => {
  const data = app.getPath("userData");
  initLog(path.join(data, "logs"));
  const settingsFile = new SettingsFile(data);
  const store = new Store(initialState(settingsFile.load()));
  const registry = new Registry();
  const hosted = new HostedManager(store, registry, settingsFile);
  const claude = new ClaudeProjectsWatcher(store, (id) => hosted.has(id));
  const cursor = new CursorAgentsWatcher(store);
  const capture = new Capture(path.join(data, "shots"));
  const windows = new Windows(() => store.get().settings);
  const openTranscripts = new Set<string>();

  const quit = () => { windows.quitting = true; hosted.closeAll(); app.quit(); };

  const deps: Deps = { store, settings: settingsFile, hosted, claude, cursor, capture, windows, openTranscripts,
    onSettingsChanged: () => { windows.refreshFloating(); registerHotkeys(); }, quit };
  registerIpc(deps);
  const call = handlers(deps);

  // Push state to every window: all sessions, but only the transcripts a window has open.
  const snapshot = (s: AppState): AppState => ({
    ...s, transcripts: Object.fromEntries(Object.entries(s.transcripts).filter(([id]) => openTranscripts.has(id))),
  });
  const push = (s: AppState) => { const snap = snapshot(s); for (const w of windows.all()) w.webContents.send(CHANNEL_STATE, snap); };
  store.subscribe(push);
  app.on("browser-window-created", (_e, w: BrowserWindow) => w.webContents.on("did-finish-load", () => w.webContents.send(CHANNEL_STATE, snapshot(store.get()))));

  const capture_ = (mode: "area" | "window" | "screen") => {
    windows.widget?.hide();
    void call["shot.capture"]({ mode });
  };
  const newChat = async () => {
    const f = await call["folder.pick"]({});
    if (f.ok) { const r = await call["session.new"]({ folder: f.value, prompt: "" }); if (r.ok) windows.showHub({ open: r.value }); }
  };

  const tray = new AppTray({
    toggleWidget: (b) => windows.toggleWidget(b), showHub: (nav) => windows.showHub(nav),
    capture: capture_, newChat: () => void newChat(), quit,
  }, () => store.get());

  // Notify once when a chat starts needing you; keep the tray count current.
  const notified = new Set<string>();
  store.subscribe((s) => {
    tray.update();
    for (const x of Object.values(s.sessions)) {
      if (x.state === "needs-you" && x.needs && !notified.has(x.needs.requestId)) {
        notified.add(x.needs.requestId);
        if (Notification.isSupported()) {
          const n = new Notification({ title: `${x.window}: needs you`, body: x.needs.summary, silent: false });
          n.on("click", () => windows.showHub({ open: x.id }));
          n.show();
        }
      }
    }
  });

  function registerHotkeys(): void {
    globalShortcut.unregisterAll();
    const h = store.get().settings.hotkeys;
    const reg = (acc: string, fn: () => void) => { try { if (!globalShortcut.register(acc, fn)) log("warn", "hotkeys", "taken", { acc }); } catch (e) { log("warn", "hotkeys", "invalid", { acc, err: String(e) }); } };
    reg(h.capture, () => capture_("area"));
    reg(h.captureWindow, () => capture_("window"));
    reg(h.toggleHub, () => windows.toggleHub());
    reg(h.toggleWidget, () => windows.toggleWidget(tray.bounds()));
  }
  registerHotkeys();

  // Show the dock icon only while the hub is open, so it can be Cmd+Tabbed to.
  const hub = windows.ensureHub();
  if (isMac) { hub.on("show", () => void app.dock?.show()); hub.on("hide", () => app.dock?.hide()); }

  log("info", "tray", "placed", { ...tray.bounds() });
  // Dev-only end-to-end check: --smoke=<folder> starts a hosted chat there with a prompt that needs a permission.
  const smoke = process.argv.find((x) => x.startsWith("--smoke="));
  if (smoke && process.argv.includes("--dev")) setTimeout(async () => {
    const r = await call["session.new"]({ folder: smoke.slice(8), prompt: "Use the Bash tool to run `ls -la` in this folder, then tell me how many files there are." });
    log("info", "smoke", "started", { ok: r.ok, id: r.ok ? r.value : (r as { message: string }).message });
    if (r.ok) windows.showHub({ open: r.value });
  }, 2000);
  if (process.argv.includes("--show-widget")) setTimeout(() => windows.toggleWidget(tray.bounds()), 1500);
  claude.start();
  cursor.start();
  log("info", "app", "started", { version: app.getVersion(), platform: process.platform });
  if (process.argv.includes("--dev") || !app.getLoginItemSettings().wasOpenedAtLogin) windows.showHub();

  app.on("second-instance", () => windows.showHub());
  app.on("activate", () => windows.showHub());
  app.on("before-quit", () => { windows.quitting = true; hosted.closeAll(); claude.stop(); cursor.stop(); });
  app.on("will-quit", () => globalShortcut.unregisterAll());
});

app.on("window-all-closed", () => { /* stay in the menu bar / tray */ });
