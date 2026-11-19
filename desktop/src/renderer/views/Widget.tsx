// Menu bar / tray popover: counts, quick actions, chats that need you (with Allow / Deny inline), recent chats
// grouped by window. Clicking a chat opens it in the hub.

import React, { useMemo } from "react";
import type { AppState } from "../../shared/model";
import { call, groupByWindow, ago, ownerLabel } from "../api";
import { StateDot } from "../parts/Sidebar";

export function Widget({ state }: { state: AppState }) {
  const sessions = useMemo(() => Object.values(state.sessions), [state.sessions]);
  const needs = sessions.filter((s) => s.state === "needs-you").sort((a, b) => b.lastActivity - a.lastActivity);
  const working = sessions.filter((s) => s.state === "working").length;
  const groups = groupByWindow(sessions.filter((s) => s.state !== "needs-you")).slice(0, 5);
  const open = (id: string) => call("window.show", { view: "hub", sessionId: id });

  return (
    <div className="widget">
      <header className="w-head">
        <div className="w-brand">ShotDock</div>
        <div className="w-stats"><span className="dot dot-needs-you" /> {needs.length} need you <span className="dot dot-working" /> {working} working</div>
      </header>
      <div className="w-actions">
        <button className="tile" onClick={() => call("shot.capture", { mode: "area" })}><span>◱</span>Area</button>
        <button className="tile" onClick={() => call("shot.capture", { mode: "window" })}><span>▣</span>Window</button>
        <button className="tile" onClick={() => call("shot.capture", { mode: "screen" })}><span>▭</span>Screen</button>
        <button className="tile" onClick={async () => {
          const f = await call("folder.pick", {});
          if (f.ok) { const r = await call("session.new", { folder: f.value as string, prompt: "" }); if (r.ok) void open(r.value as string); }
        }}><span>＋</span>New chat</button>
      </div>
      <div className="w-list">
        {needs.length > 0 && <div className="w-group">Needs you</div>}
        {needs.map((s) => (
          <div key={s.id} className="w-need">
            <button className="w-row" onClick={() => open(s.id)}>
              <StateDot s={s} /><span className="row-main"><span className="row-title">{s.title}</span>
                <span className="row-sub">{s.window} · {s.needs?.summary ?? "waiting"}</span></span>
            </button>
            {s.needs && <div className="w-need-actions">
              <button className="btn primary sm" onClick={() => call("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "allow" })}>Allow</button>
              <button className="btn danger sm" onClick={() => call("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "deny" })}>Deny</button>
            </div>}
          </div>
        ))}
        {groups.map((g) => (
          <section key={g.folder || g.window}>
            <div className="w-group">{g.window}</div>
            {g.sessions.slice(0, 3).map((s) => (
              <button key={s.id} className="w-row" onClick={() => open(s.id)}>
                <StateDot s={s} /><span className="row-main"><span className="row-title">{s.title}</span>
                  <span className="row-sub">{ownerLabel(s)} · {ago(s.lastActivity)}</span></span>
              </button>
            ))}
          </section>
        ))}
      </div>
      <footer className="w-foot">
        <button className="btn ghost sm" onClick={() => call("window.show", { view: "hub" })}>Open ShotDock</button>
        <button className="btn ghost sm" onClick={() => call("window.show", { view: "settings" })}>Settings</button>
        <button className="btn ghost sm" onClick={() => call("app.quit", {})}>Quit</button>
      </footer>
    </div>
  );
}
