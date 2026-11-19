// The full app window: sidebar | reader + composer, the screenshot chooser, settings, and a toast line.

import React, { useCallback, useEffect, useMemo, useState } from "react";
import type { AppState } from "../../shared/model";
import { call, useNav, platform, type Nav } from "../api";
import { Sidebar } from "../parts/Sidebar";
import { Reader } from "../parts/Reader";
import { Composer } from "../parts/Composer";
import { Chooser } from "../parts/Chooser";
import { Settings } from "./Settings";

export function Hub({ state }: { state: AppState }) {
  const sessions = useMemo(() => Object.values(state.sessions), [state.sessions]);
  const [selected, setSelected] = useState<string | undefined>();
  const [view, setView] = useState<"chat" | "settings">("chat");
  const [choosing, setChoosing] = useState(false);
  const [sideHidden, setSideHiddenRaw] = useState(() => { try { return localStorage.getItem("sideHidden") === "1"; } catch { return false; } });
  const setSideHidden = (v: boolean) => { setSideHiddenRaw(v); try { localStorage.setItem("sideHidden", v ? "1" : "0"); } catch { /* ok */ } };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key === "\\") { e.preventDefault(); setSideHidden(!sideHidden); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [sideHidden]);
  const [toast, setToast] = useState<{ m: string; bad: boolean } | null>(null);
  const notify = useCallback((m: string, bad = false) => { setToast({ m, bad }); setTimeout(() => setToast(null), bad ? 6000 : 2500); }, []);

  useNav(useCallback((n: Nav) => {
    if (n.open) { setSelected(n.open); setView("chat"); setChoosing(false); }
    if (n.view === "settings") setView("settings");
    if (n.choose) { setView("chat"); setChoosing(true); }
  }, []));

  // Default selection: a chat that needs you, else the newest.
  useEffect(() => {
    if (selected && state.sessions[selected]) return;
    const first = sessions.find((s) => s.state === "needs-you") ?? [...sessions].sort((a, b) => b.lastActivity - a.lastActivity)[0];
    if (first) setSelected(first.id);
  }, [sessions, selected, state.sessions]);

  const newChat = async () => {
    const f = await call("folder.pick", {});
    if (!f.ok) return;
    const r = await call("session.new", { folder: f.value as string, prompt: "" });
    if (r.ok) { setSelected(r.value as string); setChoosing(false); } else notify(r.message, true);
  };

  const s = selected ? state.sessions[selected] : undefined;
  return (
    <div className={`hub ${platform} ${sideHidden ? "side-hidden" : ""}`}>
      <div className="drag-strip" />
      <button className="side-toggle" title={`${sideHidden ? "Show" : "Hide"} the chat list (${platform === "darwin" ? "⌘" : "Ctrl+"}\\)`}
        onClick={() => setSideHidden(!sideHidden)}>{sideHidden ? "☰" : "⟨"}</button>
      {!sideHidden && <Sidebar sessions={sessions} selected={selected} onSelect={(id) => { setSelected(id); setView("chat"); }} onNew={() => void newChat()} />}
      <main className="main">
        {view === "settings" ? <Settings s={state.settings} notify={notify} onClose={() => setView("chat")} />
          : s ? <>
              <Reader s={s} items={state.transcripts[s.id] ?? []} notify={notify} />
              <Composer s={s} shots={state.shots} notify={notify} onOpen={setSelected} />
            </>
          : <div className="empty big">
              <div>No chat selected.</div>
              <button className="btn primary" onClick={() => void newChat()}>New chat in a folder…</button>
            </div>}
        <button className="gear" title="Settings" onClick={() => setView(view === "settings" ? "chat" : "settings")}>⚙︎</button>
      </main>
      {choosing && <Chooser sessions={sessions}
        onPick={(id) => { setSelected(id); setChoosing(false); }}
        onNew={() => void newChat()}
        onCancel={() => { setChoosing(false); notify("The screenshot stays attached; pick a chat any time."); }} />}
      {state.lastError && Date.now() - state.lastError.at < 8000 && <div className="toast bad">{state.lastError.detail}</div>}
      {toast && <div className={`toast ${toast.bad ? "bad" : ""}`}>{toast.m}</div>}
    </div>
  );
}
