// Screen capture. macOS: the system `screencapture` tool (area / window / screen, interactive, no sound).
// Windows: the Snipping Tool overlay (ms-screenclip:), then the image it puts on the clipboard.
// Never touches the user's clipboard on macOS; on Windows the Snipping Tool itself writes it.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { clipboard, shell, desktopCapturer, screen } from "electron";
import type { Shot } from "../../shared/model";
import { log } from "../core/log";

export type CaptureMode = "area" | "window" | "screen" | "element";

/** Path of a bundled executable, outside app.asar when packaged. */
export function bundled(rel: string): string {
  return path.join(__dirname, "..", "..", "assets", rel).replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`);
}

export interface ElementInfo { app?: string; window?: string; role?: string; title?: string; desc?: string; value?: string; url?: string; help?: string;
                               frame: { x: number; y: number; w: number; h: number } }

/** Describe the UI element under the mouse (macOS helper). Throws "accessibility" when not allowed yet. */
export function elementUnderMouse(): Promise<ElementInfo> {
  return new Promise((resolve, reject) => execFile(bundled("bin/shotdock-element"), [], { timeout: 5000 }, (err, out) => {
    if (err) return reject(new Error(String(err)));
    try {
      const d = JSON.parse(out);
      if (!d.ok) return reject(new Error(d.error ?? "no element"));
      resolve(d as ElementInfo);
    } catch (e) { reject(e as Error); }
  }));
}

export function describeElement(e: ElementInfo): string {
  const lines = ["Element details:"];
  const add = (k: string, v?: string) => { if (v) lines.push(`- ${k}: ${v}`); };
  add("App", e.app); add("Window", e.window); add("Page / document", e.url); add("Role", e.role);
  add("Title", e.title); add("Label", e.desc); add("Help", e.help); add("Text", e.value?.slice(0, 800));
  lines.push(`- Position on screen: ${Math.round(e.frame.x)},${Math.round(e.frame.y)} size ${Math.round(e.frame.w)}x${Math.round(e.frame.h)}`);
  return lines.join("\n");
}

/** The clipboard's PNG image, if it holds one (Electron 45 async clipboard API). */
async function clipboardPng(): Promise<Buffer | null> {
  try {
    for (const item of await clipboard.read()) {
      if (item.types.includes("image/png")) return Buffer.from(await (await item.getType("image/png") as Blob).arrayBuffer());
    }
  } catch { /* empty or unreadable clipboard */ }
  return null;
}

export class Capture {
  constructor(private dir: string) { fs.mkdirSync(dir, { recursive: true }); }

  private newPath(): string {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    return path.join(this.dir, `shot-${stamp}.png`);
  }

  /** Resolves to a Shot, or null when the user cancelled. */
  async take(mode: CaptureMode): Promise<Shot | null> {
    const file = this.newPath();
    if (mode === "element") {
      if (process.platform !== "darwin") throw new Error("Element capture is macOS only for now. Use Area.");
      const e = await elementUnderMouse();
      const { x, y, w, h } = e.frame;
      const ok = await new Promise<boolean>((r) => execFile("/usr/sbin/screencapture",
        ["-x", "-R", `${Math.round(x)},${Math.round(y)},${Math.max(1, Math.round(w))},${Math.max(1, Math.round(h))}`, file], (err) => r(!err)));
      if (!ok || !fs.existsSync(file)) return null;
      return { id: randomUUID(), path: file, createdAt: Date.now(), sourceWindow: e.window ?? e.app, note: describeElement(e) };
    }
    const ok = process.platform === "darwin" ? await this.mac(mode, file) : await this.windows(mode, file);
    if (!ok || !fs.existsSync(file) || fs.statSync(file).size === 0) return null;
    return { id: randomUUID(), path: file, createdAt: Date.now() };
  }

  private mac(mode: CaptureMode, file: string): Promise<boolean> {
    const args = mode === "area" ? ["-i", "-x", file] : mode === "window" ? ["-i", "-W", "-x", "-o", file] : ["-x", file];
    return new Promise((resolve) => execFile("/usr/sbin/screencapture", args, (err, _o, stderr) => {
      log("info", "capture", "screencapture done", { mode, err: err ? String(err) : undefined, stderr: stderr?.slice(0, 200), saved: fs.existsSync(file) });
      resolve(!err);
    }));
  }

  private async windows(mode: CaptureMode, file: string): Promise<boolean> {
    if (mode === "screen") {
      const d = screen.getPrimaryDisplay();
      const sources = await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: {
        width: Math.round(d.size.width * d.scaleFactor), height: Math.round(d.size.height * d.scaleFactor) } });
      if (!sources[0]) return false;
      fs.writeFileSync(file, sources[0].thumbnail.toPNG());
      return true;
    }
    // Area / window: the Snipping Tool overlay; wait up to 60 s for a new image on the clipboard.
    const before = await clipboardPng();
    await shell.openExternal("ms-screenclip:");
    for (let i = 0; i < 120; i++) {
      await new Promise((r) => setTimeout(r, 500));
      const png = await clipboardPng();
      if (png && (!before || !png.equals(before))) { fs.writeFileSync(file, png); return true; }
    }
    return false;
  }

  /** Overwrite a shot's image (after markup). Only files inside the shots folder. */
  overwrite(file: string, dataUrl: string): boolean {
    const m = /^data:image\/png;base64,(.+)$/.exec(dataUrl);
    if (!m || path.dirname(path.resolve(file)) !== path.resolve(this.dir)) return false;
    fs.writeFileSync(file, Buffer.from(m[1], "base64"));
    return true;
  }

  /** Save a pasted or dropped image (from a renderer data URL) as a shot. */
  fromDataUrl(dataUrl: string): Shot | null {
    const m = /^data:image\/(png|jpeg|webp);base64,(.+)$/.exec(dataUrl);
    if (!m) return null;
    const file = this.newPath();
    fs.writeFileSync(file, Buffer.from(m[2], "base64"));
    return { id: randomUUID(), path: file, createdAt: Date.now() };
  }
}
