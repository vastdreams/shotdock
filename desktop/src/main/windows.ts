// The two windows: the hub (full app) and the widget (menu bar / tray popover). Both load the same renderer with
// a different ?view=. Both are sandboxed and only see the typed preload API.

import path from "node:path";
import { BrowserWindow, screen, type Rectangle } from "electron";
import type { Settings } from "../shared/model";
import { CHANNEL_NAV } from "../shared/ipc";
import { log } from "./core/log";

const isMac = process.platform === "darwin";
const rendererIndex = () => path.join(__dirname, "..", "renderer", "index.html");
const preload = () => path.join(__dirname, "..", "preload", "index.js");

function base(extra: Electron.BrowserWindowConstructorOptions): BrowserWindow {
  const w = new BrowserWindow({
    show: false,
    backgroundColor: "#00000000",
    acceptFirstMouse: true,   // a floating tool: the first click acts, it doesn't just focus the window
    webPreferences: { preload: preload(), contextIsolation: true, sandbox: true, nodeIntegration: false, spellcheck: true },
    ...extra,
  });
  // No navigation away from the app, no new windows.
  w.webContents.on("will-navigate", (e) => e.preventDefault());
  w.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  return w;
}

export class Windows {
  hub: BrowserWindow | null = null;
  widget: BrowserWindow | null = null;
  quitting = false;

  constructor(private settings: () => Settings) {}

  private applyFloating(w: BrowserWindow) {
    const s = this.settings();
    w.setAlwaysOnTop(s.alwaysOnTop, "floating");
    w.setVisibleOnAllWorkspaces(s.showOnAllDesktops, { visibleOnFullScreen: true, skipTransformProcessType: true });
  }

  ensureHub(): BrowserWindow {
    if (this.hub && !this.hub.isDestroyed()) return this.hub;
    const w = base({
      width: 1080, height: 720, minWidth: 360, minHeight: 280, title: "ShotDock",
      titleBarStyle: isMac ? "hiddenInset" : "hidden",
      ...(isMac ? { vibrancy: "under-window" as const, visualEffectState: "active" as const }
                : { titleBarOverlay: { color: "#16181d", symbolColor: "#c9ced6", height: 36 }, backgroundColor: "#16181d" }),
    });
    w.loadFile(rendererIndex(), { query: { view: "hub" } });
    // Close collapses to the floating bar (or hides to the menu bar, per Settings); Quit is in the menus.
    w.on("hide", () => log("info", "window", "hub hidden", { stack: new Error().stack?.split("\n").slice(2, 7).join(" | ") }));
    w.on("close", (e) => {
      log("info", "window", "hub close requested", { quitting: this.quitting });
      if (this.quitting) return;
      e.preventDefault();
      if (this.settings().closeTo === "bar") this.collapseToBar(); else w.hide();
    });
    this.applyFloating(w);
    this.hub = w;
    return w;
  }

  showHub(nav?: Record<string, unknown>): void {
    const w = this.ensureHub();
    const go = () => { w.show(); w.focus(); if (nav) w.webContents.send(CHANNEL_NAV, nav); };
    if (w.webContents.isLoading()) w.webContents.once("did-finish-load", go); else go();
    this.widget?.hide();
    this.bar?.hide();
  }

  toggleHub(): void {
    const w = this.ensureHub();
    if (w.isVisible() && w.isFocused()) { if (this.settings().closeTo === "bar") this.collapseToBar(); else w.hide(); }
    else this.showHub();
  }

  // ---- the floating bar: the main window collapsed to a short strip that stays above everything ----
  bar: BrowserWindow | null = null;
  private barPos: { x: number; y: number } | null = null;

  ensureBar(): BrowserWindow {
    if (this.bar && !this.bar.isDestroyed()) return this.bar;
    const w = base({
      width: 420, height: 44, frame: false, resizable: false, skipTaskbar: true, fullscreenable: false, hasShadow: true,
      transparent: true, backgroundColor: "#00000000", ...(isMac ? { roundedCorners: true } : {}),
    });
    w.loadFile(rendererIndex(), { query: { view: "bar" } });
    w.setAlwaysOnTop(true, "floating");
    w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    w.on("moved", () => { const [x, y] = w.getPosition(); this.barPos = { x, y }; });
    this.bar = w;
    return w;
  }

  collapseToBar(): void {
    log("info", "window", "collapse to bar", { stack: new Error().stack?.split("\n").slice(2, 6).join(" | ") });
    const w = this.ensureBar();
    this.hub?.hide();
    this.widget?.hide();
    if (!this.barPos) {
      const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
      this.barPos = { x: Math.round(area.x + area.width / 2 - 210), y: area.y + 8 };
    }
    w.setPosition(this.barPos.x, this.barPos.y, false);
    const show = () => w.showInactive();
    if (w.webContents.isLoading()) w.webContents.once("did-finish-load", show); else show();
  }

  /** The quick panel, opened under the bar. */
  widgetFromBar(): void {
    const b = this.bar?.getBounds();
    this.toggleWidget(b ? { x: b.x + b.width - 190, y: b.y, width: 0, height: b.height } : undefined);
  }

  ensureWidget(): BrowserWindow {
    if (this.widget && !this.widget.isDestroyed()) return this.widget;
    const w = base({
      width: 380, height: 540, frame: false, resizable: false, movable: false, skipTaskbar: true, fullscreenable: false,
      ...(isMac ? { vibrancy: "popover" as const, visualEffectState: "active" as const, roundedCorners: true }
                : { backgroundColor: "#16181d" }),
    });
    w.loadFile(rendererIndex(), { query: { view: "widget" } });
    w.on("blur", () => { if (!w.webContents.isDevToolsOpened()) w.hide(); });
    w.setAlwaysOnTop(true, "pop-up-menu");
    w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    this.widget = w;
    return w;
  }

  /** Place the widget under the menu bar icon (macOS) or above the tray (Windows), kept on screen. */
  toggleWidget(trayBounds?: Rectangle): void {
    const w = this.ensureWidget();
    if (w.isVisible()) { w.hide(); return; }
    const { width, height } = w.getBounds();
    // The menu bar icon can be hidden (crowded menu bar, camera notch): fall back to the top-right corner of the
    // screen under the mouse (macOS) or bottom-right above the taskbar (Windows).
    if (!trayBounds || trayBounds.height === 0) {
      const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
      w.setPosition(area.x + area.width - width - 10, isMac ? area.y + 6 : area.y + area.height - height - 10, false);
      w.show(); w.focus();
      return;
    }
    const area = screen.getDisplayMatching(trayBounds).workArea;
    let x = Math.round(trayBounds.x + trayBounds.width / 2 - width / 2);
    let y = isMac ? Math.round(trayBounds.y + trayBounds.height + 4)
                  : (trayBounds.y > area.y + area.height / 2 ? Math.round(trayBounds.y - height - 6) : Math.round(trayBounds.y + trayBounds.height + 6));
    x = Math.min(Math.max(x, area.x + 6), area.x + area.width - width - 6);
    y = Math.min(Math.max(y, area.y + 4), area.y + area.height - height - 4);
    w.setPosition(x, y, false);
    w.show();
    w.focus();
  }

  refreshFloating(): void { if (this.hub && !this.hub.isDestroyed()) this.applyFloating(this.hub); }

  all(): BrowserWindow[] { return [this.hub, this.widget, this.bar].filter((w): w is BrowserWindow => !!w && !w.isDestroyed()); }
}
