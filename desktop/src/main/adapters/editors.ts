// Editors that run the Claude Code extension, and the documented link it answers:
// <scheme>://anthropic.claude-code/open?session=<id>

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { shell } from "electron";

interface Editor { name: string; scheme: string; mac: string; win: string }

const EDITORS: Editor[] = [
  { name: "Cursor", scheme: "cursor", mac: "/Applications/Cursor.app",
    win: path.join(process.env.LOCALAPPDATA ?? "", "Programs", "cursor", "Cursor.exe") },
  { name: "VS Code", scheme: "vscode", mac: "/Applications/Visual Studio Code.app",
    win: path.join(process.env.LOCALAPPDATA ?? "", "Programs", "Microsoft VS Code", "Code.exe") },
  { name: "Windsurf", scheme: "windsurf", mac: "/Applications/Windsurf.app",
    win: path.join(process.env.LOCALAPPDATA ?? "", "Programs", "Windsurf", "Windsurf.exe") },
];

export function installedEditors(): Editor[] {
  return EDITORS.filter((e) => fs.existsSync(process.platform === "darwin" ? e.mac : e.win)
    || (process.platform === "darwin" && fs.existsSync(path.join(os.homedir(), "Applications", path.basename(e.mac)))));
}

/** Open (or resume) a Claude Code session in the first installed editor. */
export async function openInEditor(sessionId: string, prefer?: string): Promise<string | null> {
  const list = installedEditors();
  const ed = list.find((e) => e.name === prefer) ?? list[0];
  if (!ed) return null;
  await shell.openExternal(`${ed.scheme}://anthropic.claude-code/open?session=${encodeURIComponent(sessionId)}`);
  return ed.name;
}
