// Asked before ShotDock continues a chat that belongs to an editor or terminal (Rule 2: one writer per chat).

import React, { useEffect } from "react";
import type { Session } from "../../shared/model";

export function ContinueDialog({ s, onChoose }: { s: Session; onChoose(c: "continue" | "copy" | null): void }) {
  const where = s.owner.app === "Terminal" ? "the terminal" : "your editor";
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") onChoose(null); };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [onChoose]);
  return (
    <div className="overlay" onClick={() => onChoose(null)}>
      <div className="dialog" onClick={(e) => e.stopPropagation()}>
        <div className="dialog-title">Continue “{s.title}” in ShotDock?</div>
        <p>This chat belongs to {where}. If it stays open there while ShotDock continues it, both would write to the same
          chat and its history can get mixed up.</p>
        <p><strong>Close it in {where} first</strong> (close its tab or panel), then continue here. Or make a copy: the original stays where it is.</p>
        <div className="dialog-actions">
          <button className="btn" onClick={() => onChoose(null)}>Cancel</button>
          <button className="btn" onClick={() => onChoose("copy")}>Copy to a new chat</button>
          <button className="btn primary" onClick={() => onChoose("continue")}>I closed it, continue here</button>
        </div>
      </div>
    </div>
  );
}
