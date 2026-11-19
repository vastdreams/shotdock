// Mark up a screenshot before sending: Box, Arrow, Text, Blur (pixelates, so it cannot be undone by the reader).
// Draws on a canvas at the image's full resolution; Save writes the PNG back over the shot.

import React, { useEffect, useRef, useState } from "react";
import type { Shot } from "../../shared/model";
import { call } from "../api";

type Tool = "box" | "arrow" | "text" | "blur";
interface Mark { tool: Tool; x1: number; y1: number; x2: number; y2: number; text?: string }

const fileUrl = (p: string, v: number) => "file://" + encodeURI(p.replace(/\\/g, "/")).replace(/#/g, "%23") + `?v=${v}`;
const RED = "#ef4444";

function draw(ctx: CanvasRenderingContext2D, img: HTMLImageElement, marks: Mark[], scale: number) {
  ctx.drawImage(img, 0, 0);
  const lw = Math.max(3, Math.round(3 * scale));
  for (const m of marks) {
    const x = Math.min(m.x1, m.x2), y = Math.min(m.y1, m.y2), w = Math.abs(m.x2 - m.x1), h = Math.abs(m.y2 - m.y1);
    if (m.tool === "blur" && w > 2 && h > 2) {
      const cell = Math.max(8, Math.round(12 * scale));
      const tmp = document.createElement("canvas");
      tmp.width = Math.max(1, Math.round(w / cell)); tmp.height = Math.max(1, Math.round(h / cell));
      const t = tmp.getContext("2d")!;
      t.drawImage(ctx.canvas, x, y, w, h, 0, 0, tmp.width, tmp.height);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(tmp, 0, 0, tmp.width, tmp.height, x, y, w, h);
      ctx.imageSmoothingEnabled = true;
    } else if (m.tool === "box") {
      ctx.strokeStyle = RED; ctx.lineWidth = lw; ctx.strokeRect(x, y, w, h);
    } else if (m.tool === "arrow") {
      const a = Math.atan2(m.y2 - m.y1, m.x2 - m.x1), L = 18 * scale;
      ctx.strokeStyle = RED; ctx.fillStyle = RED; ctx.lineWidth = lw;
      ctx.beginPath(); ctx.moveTo(m.x1, m.y1); ctx.lineTo(m.x2, m.y2); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(m.x2, m.y2);
      ctx.lineTo(m.x2 - L * Math.cos(a - 0.45), m.y2 - L * Math.sin(a - 0.45));
      ctx.lineTo(m.x2 - L * Math.cos(a + 0.45), m.y2 - L * Math.sin(a + 0.45)); ctx.closePath(); ctx.fill();
    } else if (m.tool === "text" && m.text) {
      const size = Math.round(18 * scale);
      ctx.font = `600 ${size}px -apple-system, "Segoe UI", sans-serif`;
      const tw = ctx.measureText(m.text).width;
      ctx.fillStyle = RED; ctx.fillRect(m.x1, m.y1 - size, tw + size * 0.6, size * 1.35);
      ctx.fillStyle = "#fff"; ctx.fillText(m.text, m.x1 + size * 0.3, m.y1 + size * 0.1);
    }
  }
}

export function Markup({ shot, onClose, notify }: { shot: Shot; onClose(): void; notify(m: string, bad?: boolean): void }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const img = useRef<HTMLImageElement | null>(null);
  const [tool, setTool] = useState<Tool>("box");
  const [marks, setMarks] = useState<Mark[]>([]);
  const [drag, setDrag] = useState<Mark | null>(null);
  const scale = useRef(1);

  useEffect(() => {
    const i = new Image();
    i.onload = () => {
      img.current = i;
      const c = canvas.current!;
      c.width = i.naturalWidth; c.height = i.naturalHeight;
      scale.current = Math.max(1, i.naturalWidth / 1200);
      draw(c.getContext("2d")!, i, [], scale.current);
    };
    i.src = fileUrl(shot.path, shot.createdAt);
  }, [shot.path, shot.createdAt]);

  useEffect(() => {
    const c = canvas.current;
    if (c && img.current) draw(c.getContext("2d")!, img.current, drag ? [...marks, drag] : marks, scale.current);
  }, [marks, drag]);

  const pos = (e: React.MouseEvent) => {
    const r = canvas.current!.getBoundingClientRect();
    return { x: (e.clientX - r.left) * (canvas.current!.width / r.width), y: (e.clientY - r.top) * (canvas.current!.height / r.height) };
  };
  const down = (e: React.MouseEvent) => {
    const p = pos(e);
    if (tool === "text") {
      const text = window.prompt("Label text");
      if (text) setMarks([...marks, { tool, x1: p.x, y1: p.y, x2: p.x, y2: p.y, text }]);
      return;
    }
    setDrag({ tool, x1: p.x, y1: p.y, x2: p.x, y2: p.y });
  };
  const move = (e: React.MouseEvent) => { if (drag) { const p = pos(e); setDrag({ ...drag, x2: p.x, y2: p.y }); } };
  const up = () => { if (drag && Math.hypot(drag.x2 - drag.x1, drag.y2 - drag.y1) > 6) setMarks([...marks, drag]); setDrag(null); };

  const save = async () => {
    const r = await call("shot.save", { id: shot.id, dataUrl: canvas.current!.toDataURL("image/png") });
    if (r.ok) { notify("Screenshot updated."); onClose(); } else notify(r.message, true);
  };

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      if ((e.metaKey || e.ctrlKey) && e.key === "z") setMarks((m) => m.slice(0, -1));
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [onClose]);

  return (
    <div className="overlay markup-overlay">
      <div className="markup">
        <div className="markup-bar">
          <div className="seg">
            {(["box", "arrow", "text", "blur"] as Tool[]).map((t) => (
              <button key={t} className={tool === t ? "on" : ""} onClick={() => setTool(t)}>{t[0].toUpperCase() + t.slice(1)}</button>
            ))}
          </div>
          <div className="left">
            <button className="btn ghost" disabled={!marks.length} onClick={() => setMarks(marks.slice(0, -1))}>Undo</button>
            <button className="btn" onClick={onClose}>Cancel</button>
            <button className="btn primary" disabled={!marks.length} onClick={() => void save()}>Save</button>
          </div>
        </div>
        <div className="markup-stage">
          <canvas ref={canvas} onMouseDown={down} onMouseMove={move} onMouseUp={up} onMouseLeave={up} />
        </div>
      </div>
    </div>
  );
}
