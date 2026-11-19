// Settings (JSON in the app data folder, atomic writes) and the API key (OS-encrypted via Electron safeStorage:
// macOS Keychain, Windows DPAPI). This file is the only reader of the key.

import fs from "node:fs";
import path from "node:path";
import { safeStorage } from "electron";
import type { Settings } from "../../shared/model";
import { DEFAULT_SETTINGS } from "../../shared/model";

export class SettingsFile {
  private readonly file: string;
  private readonly keyFile: string;

  constructor(dir: string) {
    fs.mkdirSync(dir, { recursive: true });
    this.file = path.join(dir, "settings.json");
    this.keyFile = path.join(dir, "api-key.bin");
  }

  load(): Settings {
    let saved: Partial<Settings> = {};
    try { saved = JSON.parse(fs.readFileSync(this.file, "utf8")); } catch { /* first run */ }
    return { ...DEFAULT_SETTINGS, ...saved, hotkeys: { ...DEFAULT_SETTINGS.hotkeys, ...(saved.hotkeys ?? {}) }, hasApiKey: this.hasKey() };
  }

  save(s: Settings): void {
    const { hasApiKey: _omit, ...rest } = s;
    const tmp = this.file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(rest, null, 2));
    fs.renameSync(tmp, this.file);
  }

  hasKey(): boolean { return fs.existsSync(this.keyFile); }

  setKey(key: string): void {
    if (!key) { fs.rmSync(this.keyFile, { force: true }); return; }
    if (!safeStorage.isEncryptionAvailable()) throw new Error("This system cannot encrypt secrets; the key was not saved.");
    fs.writeFileSync(this.keyFile, safeStorage.encryptString(key), { mode: 0o600 });
  }

  /** Only for the hosted adapter's subprocess environment. Never log or send to a renderer. */
  readKey(): string | null {
    try { return safeStorage.decryptString(fs.readFileSync(this.keyFile)); } catch { return null; }
  }
}
