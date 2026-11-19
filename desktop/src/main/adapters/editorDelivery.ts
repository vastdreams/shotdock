// Mirror a message into a Claude Code chat that lives in the editor: reveal that exact chat (the extension's
// open-session link), then the native helper pastes into its box and presses Return, and ShotDock comes back.
// The Claude Code extension refuses outside prompts for open chats, so this is the only way to keep one chat
// in one place. Confirmed by watching the chat's transcript for the message.

import fs from "node:fs";
import { execFile } from "node:child_process";
import { app, shell } from "electron";
import { bundled } from "../capture/capture";
import { installedEditors } from "./editors";
import { log } from "../core/log";

const BUNDLES: Record<string, string> = { Cursor: "com.todesktop.230313mzl4w4u92", "VS Code": "com.microsoft.VSCode", Windsurf: "com.exafunction.windsurf" };

const REASONS: Record<string, string> = {
  draft: "You have unsent text in that chat's box in the editor. Send or clear it there, then try again.",
  no_box: "Couldn't reach the Claude message box in the editor. Is the chat open there?",
  accessibility: "Allow ShotDock in System Settings › Privacy & Security › Accessibility, then try again.",
  paste: "The message didn't land in the editor's chat box. Nothing was sent.",
  "editor not running": "The editor isn't running. Open it, or use Continue here.",
  "editor did not come forward": "The editor didn't come to the front in time. Nothing was sent.",
};

function helper(job: object): Promise<{ ok: boolean; error?: string }> {
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

export async function deliverToEditor(o: { sessionId: string; text: string; images: string[]; transcript?: string; returnPid: number })
  : Promise<{ ok: true; confirmed: boolean } | { ok: false; message: string }> {
  if (process.platform !== "darwin") return { ok: false, message: "Sending into an editor chat is macOS only for now. Use Continue here." };
  const ed = installedEditors().find((e) => e.name === "Cursor") ?? installedEditors()[0];
  if (!ed) return { ok: false, message: "No editor with the Claude Code extension was found." };
  const since = Date.now();
  // Reveal that exact chat in its window (opens it if its tab was closed). No prompt in the link: it would be refused.
  await shell.openExternal(`${ed.scheme}://anthropic.claude-code/open?session=${encodeURIComponent(o.sessionId)}`);
  await new Promise((r) => setTimeout(r, 700));
  const r = await helper({ bundle: BUNDLES[ed.name], text: o.text, images: o.images, returnTo: o.returnPid });
  log(r.ok ? "info" : "warn", "deliver", r.ok ? "pasted" : "failed", { session: o.sessionId.slice(0, 8), error: r.error });
  if (!r.ok) return { ok: false, message: REASONS[r.error ?? ""] ?? `Not sent: ${r.error}` };
  if (!o.transcript) return { ok: true, confirmed: false };
  const marker = JSON.stringify(o.text.slice(0, 30)).slice(1, -1) || '"type":"image"';
  for (let i = 0; i < 16; i++) {
    await new Promise((res) => setTimeout(res, 500));
    if (landed(o.transcript, marker, since)) return { ok: true, confirmed: true };
  }
  return { ok: true, confirmed: false };
}

export const appPid = () => process.pid ?? app.getAppMetrics()[0]?.pid;
