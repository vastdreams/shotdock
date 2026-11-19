// The open chat: header (who runs it, model, actions), claim check results, transcript, permission / waiting bar.

import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Session, TranscriptItem } from "../../shared/model";
import { call, ownerLabel, canDrive, ensureDrivable, type ContinueChoice } from "../api";
import { Markdown } from "./Markdown";
import { StateDot } from "./Sidebar";

const MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"];

function More({ items }: { items: { label: string; run(): void }[] }) {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(false);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [open]);
  return (
    <div className="more">
      <button className="btn ghost" title="More actions" onClick={(e) => { e.stopPropagation(); setOpen(!open); }}>More ▾</button>
      {open && <div className="menu">{items.map((i) => <button key={i.label} onClick={() => { setOpen(false); i.run(); }}>{i.label}</button>)}</div>}
    </div>
  );
}

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
        {!result && <span className="badge">running</span>}
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

function Claims({ s, onUse }: { s: Session; onUse(text: string): void }) {
  const c = s.claims;
  if (!c) return null;
  if (c.checking) return <div className="claims"><span className="muted">Checking the last answer…</span></div>;
  if (c.error) return <div className="claims bad">Claim check failed: {c.error}</div>;
  const bad = c.items.filter((i) => i.verdict === "unsupported").length;
  return (
    <details className={`claims ${bad ? "bad" : ""}`} open={bad > 0}>
      <summary>{c.items.length ? `${c.items.length} claim${c.items.length > 1 ? "s" : ""} checked · ${bad} not backed by evidence` : "No checkable claims in the last answer"}</summary>
      {c.items.map((i, k) => (
        <div key={k} className={`claim v-${i.verdict}`}><span className="verdict">{i.verdict}</span> {i.claim}<div className="why">{i.why}</div></div>
      ))}
      {c.followup && <div className="followup"><div>Suggested follow-up:</div><div className="fu-text">{c.followup}</div>
        <button className="btn sm" onClick={() => onUse(c.followup!)}>Copy to clipboard</button></div>}
    </details>
  );
}

export function Reader({ s, items, notify, ask, onOpen }: {
  s: Session; items: TranscriptItem[]; notify(msg: string, bad?: boolean): void;
  ask(s: Session): Promise<ContinueChoice>; onOpen(id: string): void;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  useEffect(() => { void call("transcript.load", { id: s.id }); return () => { void call("transcript.close", { id: s.id }); }; }, [s.id]);
  useLayoutEffect(() => { const el = scroller.current; if (el && stick.current) el.scrollTop = el.scrollHeight; }, [items.length, s.id]);
  const run = async (name: Parameters<typeof call>[0], args: object, done?: string) => {
    const r = await call(name, args as never);
    notify(r.ok ? done ?? "Done." : r.message, !r.ok);
    return r;
  };
  const live = canDrive(s);
  const continueHere = async () => { const id = await ensureDrivable(s, ask, notify); if (id) { if (id !== s.id) onOpen(id); notify("ShotDock is running this chat now."); } };
  const copy = async () => { const r = await run("session.takeOver", { id: s.id, fork: true }, "Copied into a new ShotDock chat."); if (r.ok) onOpen(r.value as string); };
  const terminal = async () => {
    if (s.kind === "ide" && !(await ask(s))) return;
    await run("session.openTerminal", { id: s.id }, "Opened in Terminal.");
  };

  return (
    <div className="reader">
      <header className="reader-head">
        <div className="reader-title">
          <StateDot s={s} />
          <div>
            <div className="title">{s.title}</div>
            <div className="sub">{s.window} · {ownerLabel(s)}{!live && s.model ? ` · ${s.model}` : ""}{s.error ? ` · ${s.error}` : ""}</div>
          </div>
        </div>
        <div className="actions">
          {live && <select className="model" value={s.model ?? ""} title="Model for the next replies"
                           onChange={(e) => run("session.setModel", { id: s.id, model: e.target.value }, `Model: ${e.target.value}`)}>
            {[...new Set([s.model ?? MODELS[0], ...MODELS])].map((m) => <option key={m}>{m}</option>)}
          </select>}
          {live && s.state === "working" && <button className="btn danger" onClick={() => run("session.stop", { id: s.id }, "Stopped.")}>Stop</button>}
          {!live && s.kind === "hosted" && <button className="btn primary" onClick={() => void continueHere()}>Resume here</button>}
          {(s.kind === "ide" || s.kind === "terminal") && <>
            <button className="btn primary" title="Run this chat from ShotDock (close it in the editor first)" onClick={() => void continueHere()}>Continue here</button>
            <button className="btn" title="A new chat with this chat's history; the original is untouched" onClick={() => void copy()}>Copy to new chat</button>
          </>}
          <More items={[
            { label: "Check claims in the last answer", run: () => void run("checks.run", { id: s.id }, "Checked.") },
            ...(s.kind !== "cursor-agent" ? [
              { label: "Continue in Terminal", run: () => void terminal() },
              { label: live ? "Send back to editor" : "Open in editor", run: () => void run("session.openInEditor", { id: s.id }, "Opened in the editor.") },
            ] : []),
          ]} />
        </div>
      </header>
      <Claims s={s} onUse={(t) => { void navigator.clipboard.writeText(t); notify("Follow-up copied. Paste it in the message box."); }} />
      <div className="transcript" ref={scroller}
           onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; }}>
        {items.length ? <Items items={items} /> : <div className="empty">{live ? "Say what you want done." : "Loading…"}</div>}
      </div>
      {s.state === "needs-you" && s.needs && (s.needs.external ? (
        <div className="permission">
          <div className="perm-text"><strong>Waiting in {s.owner.app === "Terminal" ? "the terminal" : "your editor"}</strong> <code>{s.needs.summary}</code></div>
          <div className="perm-actions">
            {s.kind !== "cursor-agent" && <button className="btn primary" onClick={() => run("session.openInEditor", { id: s.id }, "Opened in the editor.")}>Answer in editor</button>}
          </div>
        </div>
      ) : (
        <div className="permission">
          <div className="perm-text"><strong>Claude wants to run</strong> <code>{s.needs.summary}</code></div>
          <div className="perm-actions">
            <button className="btn primary" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "allow" }, "Allowed.")}>Allow</button>
            {s.needs.canAlways && <button className="btn" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "always" }, "Allowed for this chat.")}>Always allow</button>}
            <button className="btn danger" onClick={() => run("session.permission", { id: s.id, requestId: s.needs!.requestId, decision: "deny" }, "Denied.")}>Deny</button>
          </div>
        </div>
      ))}
    </div>
  );
}
