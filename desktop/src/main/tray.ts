// Menu bar (macOS) / system tray (Windows) item. Left click: the widget. Right click: the full menu.
// The title next to the icon shows how many chats need you.

import path from "node:path";
import { app, Menu, Tray, nativeImage, type MenuItemConstructorOptions } from "electron";
import type { AppState } from "../shared/model";

export interface TrayActions {
  toggleWidget(bounds: Electron.Rectangle): void;
  showHub(nav?: Record<string, unknown>): void;
  capture(mode: "area" | "window" | "screen" | "element"): void;
  newChat(): void;
  quit(): void;
}

const isMac = process.platform === "darwin";

export class AppTray {
  private tray: Tray;
  private last = "";

  constructor(private actions: TrayActions, private state: () => AppState) {
    const icon = nativeImage.createFromPath(path.join(__dirname, "..", "..", "assets", isMac ? "trayTemplate.png" : "tray.png"));
    if (isMac) icon.setTemplateImage(true);
    this.tray = new Tray(icon);
    this.tray.setToolTip("ShotDock");
    this.tray.on("click", (_e, bounds) => this.actions.toggleWidget(bounds));
    this.tray.on("right-click", () => this.tray.popUpContextMenu(this.menu()));
    this.update();
  }

  bounds(): Electron.Rectangle { return this.tray.getBounds(); }

  /** Cheap: only rebuilds the title when the count changes. */
  update(): void {
    const s = this.state();
    const needs = Object.values(s.sessions).filter((x) => x.state === "needs-you").length;
    const working = Object.values(s.sessions).filter((x) => x.state === "working").length;
    const key = `${needs}/${working}`;
    if (key === this.last) return;
    this.last = key;
    if (isMac) this.tray.setTitle(needs ? ` ${needs}` : "", { fontType: "monospacedDigit" });
    this.tray.setToolTip(`ShotDock — ${needs} need you, ${working} working`);
  }

  private menu(): Menu {
    const s = this.state();
    const needing = Object.values(s.sessions).filter((x) => x.state === "needs-you").sort((a, b) => b.lastActivity - a.lastActivity);
    const login = app.getLoginItemSettings().openAtLogin;
    const items: MenuItemConstructorOptions[] = [
      { label: "Open ShotDock", accelerator: s.settings.hotkeys.toggleHub, click: () => this.actions.showHub() },
      { label: "New chat in folder…", click: () => this.actions.newChat() },
      { type: "separator" },
      { label: "Screenshot area", accelerator: s.settings.hotkeys.capture, click: () => this.actions.capture("area") },
      { label: "Screenshot window", accelerator: s.settings.hotkeys.captureWindow, click: () => this.actions.capture("window") },
      { label: "Screenshot whole screen", click: () => this.actions.capture("screen") },
      { label: "Element under the mouse", accelerator: s.settings.hotkeys.element, click: () => this.actions.capture("element") },
      { type: "separator" },
      needing.length
        ? { label: `Needs you (${needing.length})`, submenu: needing.slice(0, 12).map((x) => ({
            label: `${x.window} · ${x.title}`.slice(0, 70), click: () => this.actions.showHub({ open: x.id }) })) }
        : { label: "Nothing needs you", enabled: false },
      { type: "separator" },
      { label: "Settings…", click: () => this.actions.showHub({ view: "settings" }) },
      { label: "Open at login", type: "checkbox", checked: login,
        click: () => app.setLoginItemSettings({ openAtLogin: !login }) },
      { type: "separator" },
      { label: "Quit ShotDock", accelerator: isMac ? "Cmd+Q" : "Alt+F4", click: () => this.actions.quit() },
    ];
    return Menu.buildFromTemplate(items);
  }
}
