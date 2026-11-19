// The open chat: header with ownership and actions, the transcript, the permission bar.

import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Session, TranscriptItem } from "../../shared/model";
import { call, ownerLabel, canDrive } from "../api";
import { Markdown } from "./Markdown";
import { StateDot } from "./Sidebar";

function ToolRow({ item, result }: { item: TranscriptItem; result?: TranscriptItem }) {
  const [open, setOpen] = useState(false);
  const err = result?.tool?.isError;
  return (
    <div className={`tool ${err ? "tool-err" : ""}`}>
      <button className="tool-head" onClick={() => setOpen(!open)}>
        <span className="chev">{open ? "▾" : "▸"}</span>
        <span className="tool-name">{item.tool?.name}</span>
        <span className="tool-input">{item.tool?.input}</span>
        {err && <span className="badge red">error</span>}
      </button>
      {open && result && <pre className="tool-out">{result.text || "(no output)"}</pre>}
    </div>
  );
}

function Items({ items }: { items: TranscriptItem[] }) {
  const results = new Map(items.filter((i) => i.role === "result").map((i) => [i.tool?.input ?? "", i]));
  return <>{items.map((it) => {
    if (it.role === "result") return null;
    if (it.role === "tool") return <ToolRow key={it.key} item={it} result={results.get(it.key.replace(/^tool-/, ""))} />;
    if (it.role === "user") return (
      <div key={it.key} className="msg user"><div className="bubble">
        {it.images ? <div className="img-note">🖼 {it.images} image{it.images > 1 ? "s" : ""}</div> : null}
        {it.text && <Markdown text={it.text} />}
      </div></div>
    );
    return <div key={it.key} className="msg assistant"><Markdown text={it.text} /></div>;
  })}</>;
}

export function Reader({ s, items, notify }: { s: Session; items: TranscriptItem[]; notify(msg: string, bad?: boolean): void }) {
  const scroller = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => { void call("transcript.load", { id: s.id }); return () => { void call("transcript.close", { id: s.id }); }; }, [s.id]);
  useLayoutEffect(() => { const el = scroller.current; if (el && stick.current) el.scrollTop = el.scrollHeight; }, [items.length, s.id]);
  const run = async (name: Parameters<typeof call>[0], args: object, done?: string) => {
    const r = await call(name, args as never);
    notify(r.ok ? done ?? "Done." : r.message, !r.ok);
  };
  const mine = canDrive(s);

  return (
    <div className="reader">
      <header className="reader-head">
        <div className="reader-title">
          <StateDot s={s} />
          <div>
            <div className="title">{s.title}</div>
            <div className="sub">{s.window} · {ownerLabel(s)}{s.model ? ` · ${s.model}` : ""}{s.error ? ` · ${s.error}` : ""}</div>
          </div>
        </div>
        <div className="actions">
          {mine && s.state === "working" && <button className="btn danger" onClick={() => run("session.stop", { id: s.id }, "Stopped.")}>Stop</button>}
          {!mine && s.kind !== "cursor-agent" && <>
            <button className="btn primary" onClick={() => run("session.takeOver", { id: s.id, fork: false }, "ShotDock is running this chat now.")}>Take over</button>
            <button className="btn" onClick={() => run("session.takeOver", { id: s.id, fork: true }, "Forked into a new ShotDock chat.")}>Fork</button>
          </>}
          {mine && <button className="btn" onClick={() => run("session.handBack", { id: s.id }, "Handed back to the editor.")}>Hand back</button>}
          {s.kind !== "cursor-agent" && <button className="btn ghost" onClick={() => run("session.openInEditor", { id: s.id }, "Opened in the editor.")}>Open in editor</button>}
        </div>
      </header>
      <div className="transcript" ref={scroller}
           onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; }}>
        {items.length ? <Items items={items} /> : <div className="empty">{mine ? "Say what you want done." : "Loading…"}</div>}
      </div>
      {s.state === "needs-you" && s.needs && (
        <div className="permission">
          <div className="perm-text"><strong>Claude wants to run</strong> <code>{s.needs.summary}</code></div>
          <div className="perm-actions">
            <button className="btn primary" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "allow" }, "Allowed.")}>Allow</button>
            {s.needs.canAlways && <button className="btn" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "always" }, "Allowed for this chat.")}>Always allow</button>}
            <button className="btn danger" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "deny" }, "Denied.")}>Deny</button>
          </div>
        </div>
      )}
    </div>
  );
}
