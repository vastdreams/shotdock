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
import { registerIpc, handlers, permissions, type Deps } from "./ipcServer";
import { CHANNEL_STATE } from "../shared/ipc";
import { renderScreenshots } from "./devShots";
import type { AppState } from "../shared/model";

// A separate profile (settings, shots, lock) for demos and tests: SHOTDOCK_PROFILE_DIR=/some/dir.
if (process.env.SHOTDOCK_PROFILE_DIR) app.setPath("userData", process.env.SHOTDOCK_PROFILE_DIR);
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
  const claude = new ClaudeProjectsWatcher(store, (id) => hosted.has(id), (id, other) => {
    // Another app wrote to a chat ShotDock is running: step back so there is only one writer.
    hosted.release(id);
    const app_ = other === "cli" ? "a terminal" : "your editor";
    store.dispatch({ t: "session.patch", id, patch: { kind: other === "cli" ? "terminal" : "ide",
      owner: { kind: other === "cli" ? "terminal" : "ide", app: other === "cli" ? "Terminal" : "Editor" }, state: "idle",
      error: `Continued in ${app_}, so ShotDock stopped running it.` } });
    log("warn", "registry", "conflict", { id, other });
    if (Notification.isSupported()) new Notification({ title: "ShotDock stepped back", body: `A chat ShotDock was running was continued in ${app_}. ShotDock stopped so only one app writes to it.` }).show();
  });
  const cursor = new CursorAgentsWatcher(store);
  const capture = new Capture(path.join(data, "shots"));
  const windows = new Windows(() => store.get().settings);
  const openTranscripts = new Set<string>();

  const quit = () => { windows.quitting = true; hosted.closeAll(); app.quit(); };

  const deps: Deps = { store, settings: settingsFile, hosted, claude, cursor, capture, windows, openTranscripts,
    onSettingsChanged: () => { windows.refreshFloating(); registerHotkeys(); }, quit };
  deps.snapshot = () => snapshot(store.get());
  registerIpc(deps);
  const call = handlers(deps);

  // Push state to every window: all sessions, but only the transcripts a window has open.
  const snapshot = (s: AppState): AppState => ({
    ...s, transcripts: Object.fromEntries(Object.entries(s.transcripts).filter(([id]) => openTranscripts.has(id))),
  });
  const push = (s: AppState) => { const snap = snapshot(s); for (const w of windows.all()) w.webContents.send(CHANNEL_STATE, snap); };
  store.subscribe(push);
  app.on("browser-window-created", (_e, w: BrowserWindow) => w.webContents.on("did-finish-load", () => w.webContents.send(CHANNEL_STATE, snapshot(store.get()))));

  const capture_ = async (mode: "area" | "window" | "screen" | "element") => {
    windows.widget?.hide();
    const r = await call["shot.capture"]({ mode });
    log("info", "capture", "result", { mode, ok: r.ok, code: r.ok ? undefined : r.code });
    if (!r.ok && r.code !== "cancelled" && Notification.isSupported()) new Notification({ title: "ShotDock screenshot", body: r.message }).show();
  };
  const newChat = async () => {
    const f = await call["folder.pick"]({});
    if (f.ok) { const r = await call["session.new"]({ folder: f.value, prompt: "" }); if (r.ok) windows.showHub({ open: r.value }); }
  };

  const tray = new AppTray({
    toggleWidget: (b) => windows.toggleWidget(b), showHub: (nav) => windows.showHub(nav),
    capture: (m) => void capture_(m), newChat: () => void newChat(), quit,
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
    reg(h.capture, () => { log("info", "hotkeys", "capture pressed"); void capture_("area"); });
    reg(h.captureWindow, () => capture_("window"));
    reg(h.element, () => capture_("element"));
    reg(h.toggleHub, () => windows.toggleHub());
    reg(h.toggleWidget, () => windows.toggleWidget(tray.bounds()));
  }
  registerHotkeys();

  // macOS only lets accessory (menu bar) apps float over full-screen apps. Show a Dock icon only when the user
  // turned "Show on every desktop" off; otherwise stay a menu bar app so the window can sit over full-screen Cursor.
  const hub = windows.ensureHub();
  if (isMac) {
    hub.on("show", () => { if (!store.get().settings.showOnAllDesktops) void app.dock?.show(); });
    hub.on("hide", () => app.dock?.hide());
  }

  log("info", "tray", "placed", { ...tray.bounds() });
  // Dev-only end-to-end check: --smoke=<folder> starts a hosted chat there with a prompt that needs a permission.
  const smoke = process.argv.find((x) => x.startsWith("--smoke="));
  if (smoke && process.argv.includes("--dev")) setTimeout(async () => {
    const r = await call["session.new"]({ folder: smoke.slice(8), prompt: "Use the Bash tool to run `ls -la` in this folder, then tell me how many files there are." });
    log("info", "smoke", "started", { ok: r.ok, id: r.ok ? r.value : (r as { message: string }).message });
    if (r.ok) windows.showHub({ open: r.value, code: process.argv.includes("--code") });
  }, 2000);
  // Dev-only: --open=<chat id> [--code] opens a chat (and the code panel); --collapse starts as the bar.
  if (process.argv.includes("--dev")) setTimeout(() => {
    const open = process.argv.find((x) => x.startsWith("--open="))?.slice(7);
    if (open) windows.showHub({ open, code: process.argv.includes("--code") });
    if (process.argv.includes("--choose")) windows.showHub({ choose: "demo" });
    if (process.argv.includes("--settings")) windows.showHub({ view: "settings" });
  }, 2500);
  if (process.argv.includes("--show-widget")) setTimeout(() => windows.toggleWidget(tray.bounds()), 1500);
  claude.start();
  cursor.start();
  log("info", "app", "started", { version: app.getVersion(), platform: process.platform });
  log("info", "permissions", "status", permissions());
  const shotsDir = process.argv.find((x) => x.startsWith("--screenshots="))?.slice(14);
  if (shotsDir && process.argv.includes("--dev")) {
    const idsFile = process.argv.find((x) => x.startsWith("--ids="))?.slice(6);
    setTimeout(() => void renderScreenshots(windows, shotsDir, idsFile ? JSON.parse(require("node:fs").readFileSync(idsFile, "utf8")) : {}), 2500);
    return;
  }
  // Start as the floating bar (never steals focus) when opened at login or with --collapse; otherwise open the window.
  if (process.argv.includes("--collapse") || app.getLoginItemSettings().wasOpenedAtLogin) setTimeout(() => windows.collapseToBar(), 800);
  else windows.showHub();

  app.on("second-instance", () => windows.showHub());
  app.on("activate", () => windows.showHub());
  app.on("before-quit", () => { windows.quitting = true; hosted.closeAll(); claude.stop(); cursor.stop(); });
  app.on("will-quit", () => globalShortcut.unregisterAll());
});

app.on("window-all-closed", () => { /* stay in the menu bar / tray */ });
