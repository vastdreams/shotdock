// Mirror a message into a Claude Code chat that lives in the editor: reveal that exact chat (the extension's
// open-session link), then the native helper pastes into its box and presses Return, and ShotDock comes back.
// The Claude Code extension refuses outside prompts for open chats, so this is the only way to keep one chat
// in one place. Confirmed by watching the chat's transcript for the message.

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { app, shell } from "electron";
import { bundled } from "../capture/capture";
import { installedEditors } from "./editors";
import { execFile as execFileCb } from "node:child_process";
import { log } from "../core/log";

const BUNDLES: Record<string, string> = { Cursor: "com.todesktop.230313mzl4w4u92", "VS Code": "com.microsoft.VSCode", Windsurf: "com.exafunction.windsurf" };

const REASONS: Record<string, string> = {
  draft: "Couldn't clear the old text in that chat's box in the editor. Nothing was sent.",
  no_box: "Couldn't reach the Claude message box in the editor. Is the chat open there?",
  wrong_window: "The editor didn't open this chat's folder, so nothing was typed (it won't go into another chat).",
  accessibility: "Allow ShotDock in System Settings › Privacy & Security › Accessibility, then try again.",
  paste: "The message didn't land in the editor's chat box. Nothing was sent.",
  "editor not running": "The editor isn't running. Open it, or use Continue here.",
  "editor did not come forward": "The editor didn't come to the front in time. Nothing was sent.",
};

type HelperReply = { ok: boolean; error?: string; diag?: Record<string, unknown>; steps?: string[]; ms?: number };
function helper(job: object): Promise<HelperReply> {
  return new Promise((resolve) => {
    const p = execFile(bundled("bin/shotdock-deliver"), [], { timeout: 20000 }, (err, out) => {
      if (err && !out) return resolve({ ok: false, error: String(err) });
      try { resolve(JSON.parse(out)); } catch { resolve({ ok: false, error: "bad helper reply" }); }
    });
    p.stdin?.end(JSON.stringify(job));
  });
}

/** True once a user line containing `marker` appears in the transcript after `since`. */
function landed(file: string, marker: string, since: number): boolean {
  try {
    const st = fs.statSync(file);
    const start = Math.max(0, st.size - 400_000);
    const fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(st.size - start);
    fs.readSync(fd, buf, 0, buf.length, start); fs.closeSync(fd);
    return buf.toString("utf8").split("\n").some((l) => l.includes('"type":"user"') && l.includes(marker) && Date.parse(/"timestamp":"([^"]+)"/.exec(l)?.[1] ?? "") >= since - 3000);
  } catch { return false; }
}

const CLI: Record<string, string[]> = {
  Cursor: ["/usr/local/bin/cursor", "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"],
  "VS Code": ["/usr/local/bin/code", "/opt/homebrew/bin/code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"],
  Windsurf: ["/usr/local/bin/windsurf", "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf"],
};

/** `cursor <folder>`: focuses the window that has the folder open (or opens one). */
function focusFolder(editor: string, folder: string): Promise<void> {
  const bin = (CLI[editor] ?? []).find((p) => fs.existsSync(p));
  if (!bin || !fs.existsSync(folder)) return Promise.resolve();
  const env = { ...process.env }; delete env.ELECTRON_RUN_AS_NODE;
  return new Promise((r) => execFileCb(bin, [folder], { env, timeout: 8000 }, () => setTimeout(r, 900)));
}

/** Failures where ShotDock can safely continue the chat itself instead (nothing was typed anywhere). */
export const CAN_FALL_BACK = new Set(["no_box", "wrong_window", "editor not running", "editor did not come forward", "accessibility"]);

export async function deliverToEditor(o: { sessionId: string; text: string; images: string[]; transcript?: string; returnPid: number; folder?: string })
  : Promise<{ ok: true; confirmed: boolean } | { ok: false; message: string; code: string }> {
  if (process.platform !== "darwin") return { ok: false, code: "editor not running", message: "Sending into an editor chat is macOS only for now." };
  const ed = installedEditors().find((e) => e.name === "Cursor") ?? installedEditors()[0];
  if (!ed) return { ok: false, code: "editor not running", message: "No editor with the Claude Code extension was found." };
  const since = Date.now();
  // 1. Bring forward the editor window for the chat's folder (opens it if needed), so the chat opens in the right
  //    window, not whichever one happens to be in front.
  if (o.folder) await focusFolder(ed.name, o.folder);
  // 2. Reveal that exact chat in it (opens it if its tab was closed). No prompt in the link: it would be refused.
  await shell.openExternal(`${ed.scheme}://anthropic.claude-code/open?session=${encodeURIComponent(o.sessionId)}`);
  await new Promise((r) => setTimeout(r, 1200));
  // The front window must be the chat's own folder, or nothing is typed (never paste into another chat).
  const windowName = o.folder ? path.basename(o.folder) : "";
  const r = await helper({ bundle: BUNDLES[ed.name], text: o.text, images: o.images, returnTo: o.returnPid, window: windowName });
  // Every attempt is logged with what the helper saw, so failures can be diagnosed from the log alone.
  const base = { session: o.sessionId.slice(0, 8), folder: windowName, chars: o.text.length, images: o.images.length, error: r.error, ms: r.ms, steps: r.steps, diag: r.diag };
  log(r.ok ? "info" : "error", "deliver", r.ok ? "pasted" : "failed", base);
  if (!r.ok) return { ok: false, code: r.error ?? "unknown", message: REASONS[r.error ?? ""] ?? `Not sent: ${r.error}` };
  if (!o.transcript) return { ok: true, confirmed: false };
  const marker = JSON.stringify(o.text.slice(0, 30)).slice(1, -1) || '"type":"image"';
  for (let i = 0; i < 16; i++) {
    await new Promise((res) => setTimeout(res, 500));
    if (landed(o.transcript, marker, since)) { log("info", "deliver", "confirmed", { session: base.session, after_ms: Date.now() - since }); return { ok: true, confirmed: true }; }
  }
  log("error", "deliver", "unconfirmed: pasted and Return pressed, but the message never appeared in the chat transcript", base);
  return { ok: true, confirmed: false };
}

export const appPid = () => process.pid ?? app.getAppMetrics()[0]?.pid;
