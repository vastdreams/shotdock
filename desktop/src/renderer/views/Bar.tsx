// The main window collapsed: a short bar that floats above everything (drag it anywhere).
// Shows what needs you; buttons: screenshot, quick panel, expand.

import React, { useMemo } from "react";
import type { AppState } from "../../shared/model";
import { call } from "../api";

export function Bar({ state }: { state: AppState }) {
  const sessions = useMemo(() => Object.values(state.sessions), [state.sessions]);
  const needs = sessions.filter((s) => s.state === "needs-you").sort((a, b) => b.lastActivity - a.lastActivity);
  const working = sessions.filter((s) => s.state === "working").length;
  const top = needs[0];
  return (
    <div className="bar">
      <span className="bar-grip" title="Drag to move">⋮⋮</span>
      <button className="bar-status" title={top ? `Open ${top.title}` : "Open ShotDock"}
        onClick={() => call("window.show", { view: "hub", sessionId: top?.id })}>
        <span className={`dot ${needs.length ? "dot-needs-you" : working ? "dot-working" : ""}`} />
        {top ? <span className="bar-text"><strong>{needs.length} need you</strong> · {top.window}: {top.title}</span>
             : <span className="bar-text">{working ? `${working} working` : "All quiet"} · {sessions.length} chats</span>}
      </button>
      <button className="bar-btn" title="Screenshot an area" onClick={() => call("shot.capture", { mode: "area" })}>◱</button>
      <button className="bar-btn" title="Quick panel" onClick={() => call("window.widgetFromBar", {})}>▾</button>
      <button className="bar-btn" title="Expand ShotDock" onClick={() => call("window.expand", {})}>⤢</button>
    </div>
  );
}
