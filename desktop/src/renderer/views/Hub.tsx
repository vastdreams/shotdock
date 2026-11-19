// The full app window: sidebar | reader + composer, the screenshot chooser, settings, and a toast line.

import React, { useCallback, useEffect, useMemo, useState } from "react";
import type { AppState } from "../../shared/model";
import { call, useNav, platform, type Nav } from "../api";
import { Sidebar } from "../parts/Sidebar";
import { Reader } from "../parts/Reader";
import { Composer } from "../parts/Composer";
import { Chooser } from "../parts/Chooser";
import { Settings } from "./Settings";
import { ContinueDialog } from "../parts/ContinueDialog";
const CodePanel = React.lazy(() => import("../parts/CodePanel").then((m) => ({ default: m.CodePanel })));
import type { Session } from "../../shared/model";
import type { ContinueChoice } from "../api";

export function Hub({ state }: { state: AppState }) {
  const sessions = useMemo(() => Object.values(state.sessions), [state.sessions]);
  const [selected, setSelected] = useState<string | undefined>();
  const [view, setView] = useState<"chat" | "settings">("chat");
  const [choosing, setChoosing] = useState<string | false>(false);   // the shot id being placed
  const [asking, setAsking] = useState<{ s: Session; done(c: ContinueChoice): void } | null>(null);
  const ask = useCallback((s: Session) => new Promise<ContinueChoice>((done) => setAsking({ s, done })), []);
  const [sideHidden, setSideHiddenRaw] = useState(() => { try { return localStorage.getItem("sideHidden") === "1"; } catch { return false; } });
  const setSideHidden = (v: boolean) => { setSideHiddenRaw(v); try { localStorage.setItem("sideHidden", v ? "1" : "0"); } catch { /* ok */ } };
  const [width, setWidth] = useState(window.innerWidth);
  useEffect(() => { const r = () => setWidth(window.innerWidth); window.addEventListener("resize", r); return () => window.removeEventListener("resize", r); }, []);
  const [codeOpen, setCodeOpenRaw] = useState(() => { try { return localStorage.getItem("codeOpen") === "1"; } catch { return false; } });
  const setCodeOpen = (v: boolean) => { setCodeOpenRaw(v); try { localStorage.setItem("codeOpen", v ? "1" : "0"); } catch { /* ok */ } };
  const [codeW, setCodeW] = useState(() => { try { return Number(localStorage.getItem("codeW")) || 560; } catch { return 560; } });
  const narrow = width < 760;                       // small window: the chat list gets out of the way by itself
  const listHidden = sideHidden || narrow;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key === "\\") { e.preventDefault(); setSideHidden(!sideHidden); }
      if (e.key === "e") { e.preventDefault(); setCodeOpen(!codeOpen); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [sideHidden, codeOpen]);
  const dragSplit = (e: React.MouseEvent) => {
    e.preventDefault();
    const startX = e.clientX, startW = codeW;
    const move = (m: MouseEvent) => setCodeW(Math.min(Math.max(280, startW - (m.clientX - startX)), window.innerWidth - (listHidden ? 0 : 290) - 320));
    const up = () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up);
      try { localStorage.setItem("codeW", String(codeW)); } catch { /* ok */ } };
    window.addEventListener("mousemove", move); window.addEventListener("mouseup", up);
  };
  const [toast, setToast] = useState<{ m: string; bad: boolean } | null>(null);
  const notify = useCallback((m: string, bad = false) => { setToast({ m, bad }); setTimeout(() => setToast(null), bad ? 6000 : 2500); }, []);

  useNav(useCallback((n: Nav) => {
    if (n.open) { setSelected(n.open); setView("chat"); setChoosing(false); }
    if (n.view === "settings") { setView("settings"); setChoosing(false); }
    if (n.choose) { setView("chat"); setChoosing(n.choose); }
    if (n.code) setCodeOpen(true);
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
    <div className={`hub ${platform} ${listHidden ? "side-hidden" : ""}`}>
      <div className="drag-strip" />
      <div className="top-tools">
        <button title={`${listHidden ? "Show" : "Hide"} the chat list (${platform === "darwin" ? "⌘" : "Ctrl+"}\\)`}
          onClick={() => setSideHidden(!sideHidden)}>{listHidden ? "☰" : "⟨"}</button>
        <button title="Collapse to the floating bar" onClick={() => call("window.collapse", {})}>⌄</button>
        <button className={codeOpen ? "on" : ""} title={`Code: changes and editor (${platform === "darwin" ? "⌘" : "Ctrl+"}E)`} onClick={() => setCodeOpen(!codeOpen)}>{"</>"}</button>
      </div>
      {!listHidden && <Sidebar sessions={sessions} selected={selected} onSelect={(id) => { setSelected(id); setView("chat"); }} onNew={() => void newChat()} />}
      <main className="main">
        {view === "settings" ? <Settings s={state.settings} notify={notify} onClose={() => setView("chat")} />
          : s ? <div className="split">
              <div className="chat-col">
                <Reader s={s} items={state.transcripts[s.id] ?? []} notify={notify} ask={ask} onOpen={setSelected} />
                <Composer s={s} shots={state.shots} notify={notify} onOpen={setSelected} ask={ask} />
              </div>
              {codeOpen && s.folder && <>
                <div className="splitter" onMouseDown={dragSplit} title="Drag to resize" />
                <div className="code-col" style={{ width: Math.max(280, Math.min(codeW, width - (listHidden ? 0 : 290) - 320)) }}>
                  <React.Suspense fallback={<div className="empty">Loading the editor…</div>}>
                    <CodePanel folder={s.folder} notify={notify} onClose={() => setCodeOpen(false)} />
                  </React.Suspense>
                </div>
              </>}
            </div>
          : <div className="empty big">
              <div>No chat selected.</div>
              <button className="btn primary" onClick={() => void newChat()}>New chat in a folder…</button>
            </div>}
        <button className="gear" title="Settings" onClick={() => setView(view === "settings" ? "chat" : "settings")}>⚙︎</button>
      </main>
      {choosing && <Chooser sessions={sessions}
        onPick={(id) => { if (choosing) void call("shot.assign", { id: choosing, sessionId: id }); setSelected(id); setChoosing(false); }}
        onNew={() => void newChat()}
        onCancel={() => { setChoosing(false); notify("The screenshot stays attached; pick a chat any time."); }} />}
      {state.lastError && Date.now() - state.lastError.at < 8000 && <div className="toast bad">{state.lastError.detail}</div>}
      {asking && <ContinueDialog s={asking.s} onChoose={(c) => { asking.done(c); setAsking(null); }} />}
      {toast && <div className={`toast ${toast.bad ? "bad" : ""}`}>{toast.m}</div>}
    </div>
  );
}
