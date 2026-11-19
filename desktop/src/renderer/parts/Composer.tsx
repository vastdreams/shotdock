// Message box: this chat's screenshots (click one to mark it up), capture buttons, Send.
// Enter sends, Shift+Enter is a new line. A chat ShotDock is not running goes through ensureDrivable first,
// which asks before continuing an editor / terminal chat.

import React, { useEffect, useRef, useState } from "react";
import type { Session, Shot } from "../../shared/model";
import { call, canDrive, ensureDrivable, type ContinueChoice } from "../api";
import { Markup } from "./Markup";

const fileUrl = (p: string, v: number) => "file://" + encodeURI(p.replace(/\\/g, "/")).replace(/#/g, "%23") + `?v=${v}`;

function readAsDataUrl(f: Blob): Promise<string> {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = rej; r.readAsDataURL(f); });
}

export function Composer({ s, shots, notify, onOpen, ask }: {
  s: Session; shots: Shot[]; notify(m: string, bad?: boolean): void; onOpen(id: string): void;
  ask(s: Session): Promise<ContinueChoice>;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<Shot | null>(null);
  const box = useRef<HTMLTextAreaElement>(null);
  const mine = shots.filter((x) => !x.sessionId || x.sessionId === s.id);   // this chat's shots + unassigned ones
  useEffect(() => { box.current?.focus(); }, [s.id, mine.length]);
  const live = canDrive(s);

  const attachBlobs = async (files: Blob[]) => {
    for (const f of files) if (f.type.startsWith("image/")) {
      const r = await call("shot.paste", { dataUrl: await readAsDataUrl(f) });
      if (r.ok) await call("shot.assign", { id: r.value as string, sessionId: s.id }); else notify(r.message, true);
    }
  };

  const send = async () => {
    if (busy || (!text.trim() && !mine.length)) return;
    setBusy(true);
    if (s.kind === "ide" && !live) {          // mirror into the chat that is open in the editor
      const r = await call("session.send", { id: s.id, text, shotIds: mine.map((x) => x.id) });
      setBusy(false);
      if (r.ok) { setText(""); notify(String(r.value ?? "Sent.")); } else notify(r.message, true);
      return;
    }
    const id = await ensureDrivable(s, ask, notify);
    if (!id) { setBusy(false); return; }
    if (id !== s.id) onOpen(id);
    const r = await call("session.send", { id, text, shotIds: mine.map((x) => x.id) });
    setBusy(false);
    if (r.ok) setText(""); else notify(r.message, true);
  };

  if (s.kind === "cursor-agent")
    return <div className="composer readonly">Cursor Agent chats are read-only here: Cursor has no way for other apps to send to them.</div>;

  const label = live ? "Send" : s.kind === "hosted" ? "Resume and send" : s.kind === "ide" ? "Send to editor chat" : "Continue here and send";
  return (
    <div className="composer" onDragOver={(e) => e.preventDefault()}
         onDrop={(e) => { e.preventDefault(); void attachBlobs([...e.dataTransfer.files]); }}>
      {mine.length > 0 && (
        <div className="chips">
          {mine.map((x) => (
            <div key={x.id} className="chip" title={x.note ? "Element screenshot. Click to mark up." : "Click to mark up"}>
              <img src={fileUrl(x.path, x.createdAt)} alt="" onClick={() => setEditing(x)} />
              {x.note && <span className="chip-tag">element</span>}
              <button className="chip-x" title="Remove" onClick={() => call("shot.remove", { id: x.id })}>×</button>
            </div>
          ))}
        </div>
      )}
      <textarea ref={box} rows={3} value={text}
        placeholder={live ? "Message Claude…  (Enter to send, Shift+Enter for a new line)" : s.kind === "hosted"
          ? "Message… (ShotDock resumes this chat when you send)" : s.kind === "ide"
          ? "Message… (goes into this chat in your editor, then you're back here)" : "Message… (you'll be asked before ShotDock continues this chat)"}
        onChange={(e) => setText(e.target.value)}
        onPaste={(e) => { const imgs = [...e.clipboardData.files].filter((f) => f.type.startsWith("image/")); if (imgs.length) { e.preventDefault(); void attachBlobs(imgs); } }}
        onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void send(); } }} />
      <div className="composer-bar">
        <div className="left">
          <button className="btn ghost" title="Screenshot an area (Ctrl+Opt+X)" onClick={() => call("shot.capture", { mode: "area" })}>◱ Area</button>
          <button className="btn ghost" title="Screenshot a window (Ctrl+Opt+W)" onClick={() => call("shot.capture", { mode: "window" })}>▣ Window</button>
          <button className="btn ghost" title="Hover over something, then press Ctrl+Opt+E" onClick={() => notify("Hover over the thing you want, then press Ctrl+Opt+E.")}>⌖ Element</button>
        </div>
        <button className="btn primary" disabled={busy || (!text.trim() && !mine.length)} onClick={() => void send()}>
          {busy ? "Sending…" : label}
        </button>
      </div>
      {editing && <Markup shot={editing} notify={notify} onClose={() => setEditing(null)} />}
    </div>
  );
}
