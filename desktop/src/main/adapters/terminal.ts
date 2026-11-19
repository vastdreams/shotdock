// Terminal chats: open the system terminal running Claude Code (the binary that ships with the Agent SDK, so no
// separate install is needed), either resuming a chat or starting a new one in a folder.
// macOS: a .command file opened with Terminal (no Apple Events permission needed). Windows: a new console.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { shell } from "electron";

const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export async function openTerminal(bin: string, folder: string, resumeId?: string): Promise<void> {
  const args = resumeId ? ["--resume", resumeId] : [];
  if (process.platform === "win32") {
    const cmd = `cd /d "${folder}" && "${bin}" ${args.join(" ")}`;
    spawn("cmd.exe", ["/c", "start", "\"Claude\"", "cmd.exe", "/k", cmd], { detached: true, stdio: "ignore", windowsVerbatimArguments: true }).unref();
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "shotdock-term-"));
  const file = path.join(dir, "claude.command");
  const env = "unset ELECTRON_RUN_AS_NODE CLAUDE_CODE_ENTRYPOINT CLAUDECODE";
  fs.writeFileSync(file, `#!/bin/zsh -l\n${env}\ncd ${q(folder)} || exit 1\nexec ${q(bin)} ${args.map(q).join(" ")}\n`, { mode: 0o700 });
  const err = await shell.openPath(file);
  if (err) throw new Error(err);
}
