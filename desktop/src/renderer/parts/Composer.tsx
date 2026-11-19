// Message box: attachments (screenshots, pasted or dropped images), capture buttons, Send. Enter sends,
// Shift+Enter is a new line. For chats ShotDock does not run, Send becomes "Take over and send".

import React, { useEffect, useRef, useState } from "react";
import type { Session, Shot } from "../../shared/model";
import { call, canDrive } from "../api";

const fileUrl = (p: string) => "file://" + encodeURI(p.replace(/\\/g, "/")).replace(/#/g, "%23");

function readAsDataUrl(f: Blob): Promise<string> {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = rej; r.readAsDataURL(f); });
}

export function Composer({ s, shots, notify, onOpen }: {
  s: Session; shots: Shot[]; notify(m: string, bad?: boolean): void; onOpen(id: string): void;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const box = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { box.current?.focus(); }, [s.id, shots.length]);
  const mine = canDrive(s);
  const readOnly = s.kind === "cursor-agent";

  const attachBlobs = async (files: Blob[]) => {
    for (const f of files) if (f.type.startsWith("image/")) {
      const r = await call("shot.paste", { dataUrl: await readAsDataUrl(f) });
      if (!r.ok) notify(r.message, true);
    }
  };

  const send = async () => {
    if (busy || (!text.trim() && !shots.length)) return;
    setBusy(true);
    let id = s.id;
    if (!mine) {
      const t = await call("session.takeOver", { id: s.id, fork: false });
      if (!t.ok) { setBusy(false); notify(t.message, true); return; }
      id = t.value as string;
      if (id !== s.id) onOpen(id);
    }
    const r = await call("session.send", { id, text, shotIds: shots.map((x) => x.id) });
    setBusy(false);
    if (r.ok) setText(""); else notify(r.message, true);
  };

  if (readOnly) return <div className="composer readonly">Cursor Agent chats are read-only here. <button className="btn ghost" onClick={() => notify("Open it from Cursor's Agents panel.")}>Why?</button></div>;

  return (
    <div className="composer"
         onDragOver={(e) => e.preventDefault()}
         onDrop={(e) => { e.preventDefault(); void attachBlobs([...e.dataTransfer.files]); }}>
      {shots.length > 0 && (
        <div className="chips">
          {shots.map((x) => (
            <div key={x.id} className="chip">
              <img src={fileUrl(x.path)} alt="" />
              <button className="chip-x" title="Remove" onClick={() => call("shot.remove", { id: x.id })}>×</button>
            </div>
          ))}
        </div>
      )}
      <textarea ref={box} rows={3} value={text} placeholder={mine ? "Message Claude…  (Enter to send, Shift+Enter for a new line)" : "Message… (ShotDock takes over this chat when you send)"}
        onChange={(e) => setText(e.target.value)}
        onPaste={(e) => { const imgs = [...e.clipboardData.files].filter((f) => f.type.startsWith("image/")); if (imgs.length) { e.preventDefault(); void attachBlobs(imgs); } }}
        onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void send(); } }} />
      <div className="composer-bar">
        <div className="left">
          <button className="btn ghost" title="Screenshot an area" onClick={() => call("shot.capture", { mode: "area" })}>◱ Area</button>
          <button className="btn ghost" title="Screenshot a window" onClick={() => call("shot.capture", { mode: "window" })}>▣ Window</button>
        </div>
        <button className="btn primary" disabled={busy || (!text.trim() && !shots.length)} onClick={() => void send()}>
          {busy ? "Sending…" : mine ? "Send" : "Take over and send"}
        </button>
      </div>
    </div>
  );
}
