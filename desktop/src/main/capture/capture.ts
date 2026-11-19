// Screen capture. macOS: the system `screencapture` tool (area / window / screen, interactive, no sound).
// Windows: the Snipping Tool overlay (ms-screenclip:), then the image it puts on the clipboard.
// Never touches the user's clipboard on macOS; on Windows the Snipping Tool itself writes it.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { clipboard, shell, desktopCapturer, screen } from "electron";
import type { Shot } from "../../shared/model";

export type CaptureMode = "area" | "window" | "screen";

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
    const ok = process.platform === "darwin" ? await this.mac(mode, file) : await this.windows(mode, file);
    if (!ok || !fs.existsSync(file) || fs.statSync(file).size === 0) return null;
    return { id: randomUUID(), path: file, createdAt: Date.now() };
  }

  private mac(mode: CaptureMode, file: string): Promise<boolean> {
    const args = mode === "area" ? ["-i", "-x", file] : mode === "window" ? ["-i", "-W", "-x", "-o", file] : ["-x", file];
    return new Promise((resolve) => execFile("/usr/sbin/screencapture", args, (err) => resolve(!err)));
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

  /** Save a pasted or dropped image (from a renderer data URL) as a shot. */
  fromDataUrl(dataUrl: string): Shot | null {
    const m = /^data:image\/(png|jpeg|webp);base64,(.+)$/.exec(dataUrl);
    if (!m) return null;
    const file = this.newPath();
    fs.writeFileSync(file, Buffer.from(m[2], "base64"));
    return { id: randomUUID(), path: file, createdAt: Date.now() };
  }
}
