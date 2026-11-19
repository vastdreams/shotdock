// Chats grouped under their window (folder). Filter: All / Needs you / ShotDock. Search by title or folder.

import React, { useMemo, useState } from "react";
import type { Session } from "../../shared/model";
import { groupByWindow, ago, ownerLabel } from "../api";

export function StateDot({ s }: { s: Session }) {
  return <span className={`dot dot-${s.state}`} title={s.state} />;
}

export function Sidebar({ sessions, selected, onSelect, onNew }: {
  sessions: Session[]; selected?: string; onSelect(id: string): void; onNew(): void;
}) {
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<"all" | "needs" | "mine">("all");
  const [closed, setClosed] = useState<Record<string, boolean>>({});
  const groups = useMemo(() => {
    const ql = q.trim().toLowerCase();
    const list = sessions.filter((s) =>
      (filter === "all" || (filter === "needs" ? s.state === "needs-you" : s.kind === "hosted")) &&
      (!ql || s.title.toLowerCase().includes(ql) || s.window.toLowerCase().includes(ql)));
    return groupByWindow(list);
  }, [sessions, q, filter]);
  const needs = sessions.filter((s) => s.state === "needs-you").length;

  return (
    <aside className="sidebar">
      <div className="side-top">
        <input className="search" placeholder="Search chats" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="icon-btn" title="New chat in a folder" onClick={onNew}>＋</button>
      </div>
      <div className="seg">
        {(["all", "needs", "mine"] as const).map((f) => (
          <button key={f} className={filter === f ? "on" : ""} onClick={() => setFilter(f)}>
            {f === "all" ? "All" : f === "needs" ? `Needs you${needs ? ` · ${needs}` : ""}` : "ShotDock"}
          </button>
        ))}
      </div>
      <div className="side-list">
        {groups.map((g) => (
          <section key={g.folder || g.window}>
            <button className="group-head" title={g.folder} onClick={() => setClosed({ ...closed, [g.folder]: !closed[g.folder] })}>
              <span className="chev">{closed[g.folder] ? "▸" : "▾"}</span>{g.window}<span className="count">{g.sessions.length}</span>
            </button>
            {!closed[g.folder] && g.sessions.map((s) => (
              <button key={s.id} className={`row ${s.id === selected ? "sel" : ""}`} onClick={() => onSelect(s.id)}>
                <StateDot s={s} />
                <span className="row-main">
                  <span className="row-title">{s.title}</span>
                  <span className="row-sub">{ownerLabel(s)} · {ago(s.lastActivity)}</span>
                </span>
              </button>
            ))}
          </section>
        ))}
        {!groups.length && <div className="empty">No chats in the last few days. Press ＋ to start one.</div>}
      </div>
    </aside>
  );
}
