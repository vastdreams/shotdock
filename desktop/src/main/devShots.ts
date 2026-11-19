// Dev only: render the docs screenshots without putting anything on the person's screen.
// Windows are shown off-screen (Chromium doesn't paint hidden windows), captured with capturePage, then closed.
// Usage: SHOTDOCK_PROFILE_DIR=… HOME=<demo> electron . --dev --screenshots=<dir> --ids=<json file>

import fs from "node:fs";
import path from "node:path";
import { app, type BrowserWindow } from "electron";
import type { Windows } from "./windows";
import { CHANNEL_NAV } from "../shared/ipc";

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function prep(w: BrowserWindow, width: number, height: number) {
  w.setBounds({ x: -6000, y: 100, width, height });
  w.showInactive();
  await wait(400);
  // Vibrancy doesn't show in a page capture: paint the window's own background colour instead.
  await w.webContents.executeJavaScript(`document.body.style.background = getComputedStyle(document.documentElement).getPropertyValue('--bg') || '#f6f7f9'; 0`);
}
async function snap(w: BrowserWindow, file: string) {
  await wait(900);
  fs.writeFileSync(file, (await w.capturePage()).toPNG());
}
const nav = (w: BrowserWindow, n: object) => w.webContents.send(CHANNEL_NAV, n);
const click = (w: BrowserWindow, selector: string) =>
  w.webContents.executeJavaScript(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (e) e.click(); return !!e; })()`);

export async function renderScreenshots(windows: Windows, dir: string, ids: Record<string, string>): Promise<void> {
  fs.mkdirSync(dir, { recursive: true });
  const hub = windows.ensureHub();
  await new Promise<void>((r) => (hub.webContents.isLoading() ? hub.webContents.once("did-finish-load", () => r()) : r()));
  await prep(hub, 1360, 860);

  nav(hub, { open: ids.tax, code: true });
  await wait(1500);
  await click(hub, ".code-file");                       // the first changed file: show its diff
  await snap(hub, path.join(dir, "main-window-code.png"));

  nav(hub, { open: ids.dark });
  await hub.webContents.executeJavaScript(`localStorage.setItem("codeOpen","0"); 0`);
  await click(hub, '.top-tools button[title^="Code"]');
  await snap(hub, path.join(dir, "needs-you.png"));

  nav(hub, { open: ids.tax, choose: "demo" });
  await snap(hub, path.join(dir, "send-screenshot-to.png"));
  await hub.webContents.executeJavaScript(`document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })); window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })); 0`);

  await wait(3000);                                      // let the "screenshot stays attached" note fade
  nav(hub, { view: "settings" });
  await snap(hub, path.join(dir, "settings.png"));
  hub.hide();

  const widget = windows.ensureWidget();
  await new Promise<void>((r) => (widget.webContents.isLoading() ? widget.webContents.once("did-finish-load", () => r()) : r()));
  await prep(widget, 380, 540);
  await snap(widget, path.join(dir, "quick-panel.png"));
  widget.hide();

  const bar = windows.ensureBar();
  await new Promise<void>((r) => (bar.webContents.isLoading() ? bar.webContents.once("did-finish-load", () => r()) : r()));
  await prep(bar, 420, 44);
  await snap(bar, path.join(dir, "floating-bar.png"));
  bar.hide();

  windows.quitting = true;
  app.quit();
}
