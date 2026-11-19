// Settings: how ShotDock connects to Claude, defaults for new chats, window behaviour, shortcuts.

import React, { useEffect, useState } from "react";
import { platform } from "../api";
import type { Settings as S } from "../../shared/model";
import { call } from "../api";

const MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"];

export function Settings({ s, notify, onClose }: { s: S; notify(m: string, bad?: boolean): void; onClose(): void }) {
  const [key, setKey] = useState("");
  const [testing, setTesting] = useState(false);
  const [perm, setPerm] = useState<{ screen: string; accessibility: string } | null>(null);
  useEffect(() => {
    const load = () => void call("permissions.get", {}).then((r) => r.ok && setPerm(r.value as { screen: string; accessibility: string }));
    load(); const t = setInterval(load, 3000); return () => clearInterval(t);
  }, []);
  const set = async (patch: object) => { const r = await call("settings.update", patch as never); if (!r.ok) notify(r.message, true); };

  return (
    <div className="settings">
      <header className="reader-head"><div className="title">Settings</div><button className="btn" onClick={onClose}>Done</button></header>
      <div className="settings-body">
        <h3>Claude connection</h3>
        <label className="radio">
          <input type="radio" checked={s.connection === "claude-code"} onChange={() => set({ connection: "claude-code" })} />
          <span><strong>Use my Claude Code setup</strong><br />
            <small>ShotDock starts Claude Code without passing any key, so it uses whatever you set up for Claude Code on this computer. ShotDock never sees or stores a Claude login.</small></span>
        </label>
        <label className="radio">
          <input type="radio" checked={s.connection === "api-key"} onChange={() => set({ connection: "api-key" })} />
          <span><strong>Anthropic API key</strong><br />
            <small>Stored encrypted by the operating system (macOS Keychain, Windows DPAPI). Get one at console.anthropic.com.</small></span>
        </label>
        {s.connection === "api-key" && (
          <div className="field-row">
            <input type="password" placeholder={s.hasApiKey ? "Key saved. Paste a new one to replace it." : "sk-ant-…"} value={key} onChange={(e) => setKey(e.target.value)} />
            <button className="btn primary" disabled={!key.trim()} onClick={async () => {
              const r = await call("settings.setApiKey", { key }); setKey(""); notify(r.ok ? "Key saved." : r.message, !r.ok);
            }}>Save key</button>
            {s.hasApiKey && <button className="btn danger" onClick={async () => { await call("settings.setApiKey", { key: "" }); notify("Key removed."); }}>Remove</button>}
          </div>
        )}
        <div className="field-row">
          <button className="btn" disabled={testing} onClick={async () => {
            setTesting(true);
            const r = await call("settings.test", {});
            setTesting(false);
            const v = r.ok ? (r.value as { model: string; ms: number }) : null;
            notify(v ? `Connected: ${v.model}, ${(v.ms / 1000).toFixed(1)} s.` : (r as { message: string }).message, !r.ok);
          }}>{testing ? "Testing…" : "Test connection"}</button>
        </div>

        {platform === "darwin" && perm && <>
          <h3>macOS permissions</h3>
          {([["screen", "Screen recording", "Needed for every screenshot."], ["accessibility", "Accessibility", "Needed only for element screenshots (Ctrl+Opt+E)."]] as const).map(([k, name, why]) => (
            <div key={k} className="field-row perm-row">
              <span className={`dot ${perm[k] === "granted" ? "dot-working" : "dot-needs-you"}`} />
              <span className="lbl"><strong>{name}</strong><br /><small>{why}</small></span>
              {perm[k] === "granted" ? <span className="muted">Allowed</span>
                : <button className="btn primary" onClick={() => call("permissions.open", { which: k })}>Allow…</button>}
            </div>
          ))}
          <p className="hint">After turning Screen recording on, quit and reopen ShotDock: macOS applies it on the next start.</p>
        </>}

        <h3>New chats</h3>
        <div className="field-row">
          <span className="lbl">Model</span>
          <select value={s.model} onChange={(e) => set({ model: e.target.value })}>
            {[...new Set([s.model, ...MODELS])].map((m) => <option key={m}>{m}</option>)}
          </select>
        </div>
        <div className="field-row">
          <span className="lbl">Permissions</span>
          <select value={s.permissionMode} onChange={(e) => set({ permissionMode: e.target.value })}>
            <option value="default">Ask me before tools run</option>
            <option value="acceptEdits">Allow file edits, ask for the rest</option>
            <option value="plan">Plan only, no changes</option>
          </select>
        </div>

        <h3>Window</h3>
        <label className="check"><input type="checkbox" checked={s.alwaysOnTop} onChange={(e) => set({ alwaysOnTop: e.target.checked })} /> Keep ShotDock above other windows</label>
        <label className="check"><input type="checkbox" checked={s.showOnAllDesktops} onChange={(e) => set({ showOnAllDesktops: e.target.checked })} /> Show on every desktop and over full-screen apps</label>
        <div className="field-row">
          <span className="lbl">List chats from the last</span>
          <select value={s.recentDays} onChange={(e) => set({ recentDays: Number(e.target.value) })}>
            {[1, 2, 3, 7, 14, 30].map((d) => <option key={d} value={d}>{d} day{d > 1 ? "s" : ""}</option>)}
          </select>
        </div>

        <h3>Shortcuts</h3>
        <table className="keys"><tbody>
          <tr><td>Screenshot an area</td><td><span className="kbd">{s.hotkeys.capture}</span></td></tr>
          <tr><td>Screenshot the element under the mouse (macOS)</td><td><span className="kbd">{s.hotkeys.element}</span></td></tr>
          <tr><td>Screenshot a window</td><td><span className="kbd">{s.hotkeys.captureWindow}</span></td></tr>
          <tr><td>Show or hide ShotDock</td><td><span className="kbd">{s.hotkeys.toggleHub}</span></td></tr>
          <tr><td>Quick panel (same as the menu bar icon)</td><td><span className="kbd">{s.hotkeys.toggleWidget}</span></td></tr>
        </tbody></table>
        <p className="hint">Can't see the menu bar icon? macOS hides icons that don't fit, for example behind the camera notch.
          Remove a few other menu bar icons, or allow ShotDock in System Settings › Menu Bar. The quick panel shortcut works either way.
          On Windows, drag the icon out of the hidden-icons area onto the taskbar.</p>
      </div>
    </div>
  );
}
