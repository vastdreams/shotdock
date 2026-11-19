// "Send shot to": after a capture, pick the chat. Grouped by window, keyboard first (↑ ↓ Return, 1-9, Esc).

import React, { useEffect, useMemo, useState } from "react";
import type { Session } from "../../shared/model";
import { groupByWindow, ago, ownerLabel } from "../api";
import { StateDot } from "./Sidebar";

export function Chooser({ sessions, onPick, onNew, onCancel }: {
  sessions: Session[]; onPick(id: string): void; onNew(): void; onCancel(): void;
}) {
  const groups = useMemo(() => groupByWindow(sessions.filter((s) => s.kind !== "cursor-agent")).slice(0, 6)
    .map((g) => ({ ...g, sessions: g.sessions.slice(0, 4) })), [sessions]);
  const flat = groups.flatMap((g) => g.sessions);
  const [cur, setCur] = useState(0);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onCancel();
      else if (e.key === "ArrowDown") { e.preventDefault(); setCur((c) => Math.min(c + 1, flat.length)); }
      else if (e.key === "ArrowUp") { e.preventDefault(); setCur((c) => Math.max(c - 1, 0)); }
      else if (e.key === "Enter") { e.preventDefault(); cur < flat.length ? onPick(flat[cur].id) : onNew(); }
      else if (/^[1-9]$/.test(e.key) && Number(e.key) <= flat.length) onPick(flat[Number(e.key) - 1].id);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [flat, cur, onPick, onNew, onCancel]);

  let n = 0;
  return (
    <div className="overlay" onClick={onCancel}>
      <div className="chooser" onClick={(e) => e.stopPropagation()}>
        <div className="chooser-head"><span>Send screenshot to</span><button className="kbd" onClick={onCancel}>Esc</button></div>
        <div className="chooser-list">
          {groups.map((g) => (
            <section key={g.folder || g.window}>
              <div className="chooser-group">{g.window}</div>
              {g.sessions.map((s) => {
                const i = n++;
                return (
                  <button key={s.id} className={`chooser-row ${i === cur ? "cur" : ""}`} onMouseEnter={() => setCur(i)} onClick={() => onPick(s.id)}>
                    <StateDot s={s} />
                    <span className="row-main"><span className="row-title">{s.title}</span>
                      <span className="row-sub">{ownerLabel(s)} · {ago(s.lastActivity)}</span></span>
                    {i < 9 && <span className="kbd">{i + 1}</span>}
                  </button>
                );
              })}
            </section>
          ))}
          <div className="chooser-group">Other</div>
          <button className={`chooser-row ${cur === flat.length ? "cur" : ""}`} onMouseEnter={() => setCur(flat.length)} onClick={onNew}>
            <span className="dot" /><span className="row-main"><span className="row-title">New chat in a folder…</span>
              <span className="row-sub">Start a ShotDock chat with this screenshot</span></span>
          </button>
        </div>
      </div>
    </div>
  );
}
