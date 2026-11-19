// Code panel beside the chat: the chat folder's changed files (git) shown as a VS Code diff with highlights, and any
// file opened in the VS Code editor. Edit and save (⌘S). Refreshes while Claude works.

import React, { useCallback, useEffect, useRef, useState } from "react";
import { call } from "../api";
import { monaco, modelFor } from "./monaco";

interface Change { path: string; status: string }
const MARK: Record<string, string> = { modified: "M", added: "A", deleted: "D", untracked: "U", renamed: "R" };

export function CodePanel({ folder, notify, onClose }: { folder: string; notify(m: string, bad?: boolean): void; onClose(): void }) {
  const [tab, setTab] = useState<"changes" | "files">("changes");
  const [changes, setChanges] = useState<Change[]>([]);
  const [isGit, setIsGit] = useState(true);
  const [files, setFiles] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [file, setFile] = useState<string | null>(null);
  const [view, setView] = useState<"diff" | "edit">("diff");
  const [dirty, setDirty] = useState(false);
  const [hasOriginal, setHasOriginal] = useState(false);
  const host = useRef<HTMLDivElement>(null);
  const editor = useRef<monaco.editor.IStandaloneCodeEditor | monaco.editor.IStandaloneDiffEditor | null>(null);
  const loaded = useRef<string>("");

  // Changed files, every 3 s.
  useEffect(() => {
    let alive = true;
    const load = async () => {
      const r = await call("files.changes", { folder });
      if (alive && r.ok) { const v = r.value as { git: boolean; items: Change[] }; setIsGit(v.git); setChanges(v.items); }
    };
    void load(); const t = setInterval(load, 3000);
    return () => { alive = false; clearInterval(t); };
  }, [folder]);
  useEffect(() => { setTab(isGit ? "changes" : "files"); }, [isGit, folder]);
  useEffect(() => {
    if (tab !== "files") return;
    const t = setTimeout(async () => { const r = await call("files.list", { folder, query }); if (r.ok) setFiles(r.value as string[]); }, 150);
    return () => clearTimeout(t);
  }, [tab, query, folder]);

  const modified = () => {
    const e = editor.current;
    if (!e) return null;
    return "getModifiedEditor" in e ? e.getModifiedEditor().getModel() : e.getModel();
  };

  const save = useCallback(async () => {
    const m = modified();
    if (!m || !file) return;
    const r = await call("files.write", { folder, path: file, content: m.getValue() });
    if (r.ok) { loaded.current = m.getValue(); setDirty(false); notify(`Saved ${file}`); } else notify(r.message, true);
  }, [file, folder, notify]);

  // (Re)build the editor for the chosen file and view.
  const open = useCallback(async (path: string, mode: "diff" | "edit", keepScroll = false) => {
    try { await openInner(path, mode, keepScroll); }
    catch (e) { notify(`Could not open ${path}: ${String(e)}`, true); void call("log.renderer", { level: "error", msg: `code panel: ${String((e as Error)?.stack ?? e)}` }); }
  }, [folder, notify, save]);   // eslint-disable-line

  const openInner = async (path: string, mode: "diff" | "edit", keepScroll: boolean) => {
    const r = await call("files.read", { folder, path });
    if (!r.ok) { notify(r.message, true); return; }
    const v = r.value as { current: string | null; original: string | null; binary: boolean };
    if (v.binary) { notify("That file isn't text (PDF, image, archive…), so it can't be shown here.", true); return; }
    const current = v.current ?? "", original = v.original ?? "";
    setHasOriginal(v.original !== null);
    const useDiff = mode === "diff" && v.original !== null && v.original !== current;
    const el = host.current!;
    const prev = editor.current;
    const scroll = keepScroll && prev && !("getModifiedEditor" in prev) ? prev.getScrollTop() : 0;
    prev?.dispose();
    const opts = { automaticLayout: true, minimap: { enabled: false }, fontSize: 12.5, scrollBeyondLastLine: false, wordWrap: "on" as const };
    if (useDiff) {
      const d = monaco.editor.createDiffEditor(el, { ...opts, renderSideBySide: el.clientWidth > 900, originalEditable: false, readOnly: false });
      d.setModel({ original: modelFor(path, original, "original"), modified: modelFor(path, current, "current") });
      d.getModifiedEditor().onDidChangeModelContent(() => setDirty(d.getModifiedEditor().getValue() !== loaded.current));
      d.getModifiedEditor().addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => void save());
      editor.current = d;
    } else {
      const e = monaco.editor.create(el, { ...opts, model: modelFor(path, current, "current") });
      e.onDidChangeModelContent(() => setDirty(e.getValue() !== loaded.current));
      e.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => void save());
      if (scroll) e.setScrollTop(scroll);
      editor.current = e;
    }
    loaded.current = current;
    setDirty(false);
    setFile(path);
    setView(useDiff ? "diff" : "edit");
  };

  // Keep the open file current while Claude edits it (only when you have no unsaved changes).
  useEffect(() => {
    if (!file || dirty) return;
    const t = setInterval(async () => {
      const r = await call("files.read", { folder, path: file });
      if (r.ok && (r.value as { current: string | null }).current !== loaded.current) void open(file, view, true);
    }, 3000);
    return () => clearInterval(t);
  }, [file, dirty, folder, view, open]);

  useEffect(() => () => editor.current?.dispose(), []);
  useEffect(() => { editor.current?.dispose(); editor.current = null; setFile(null); }, [folder]);

  return (
    <div className="code">
      <div className="code-head">
        <div className="seg">
          <button className={tab === "changes" ? "on" : ""} disabled={!isGit} onClick={() => setTab("changes")}>Changes{isGit ? ` · ${changes.length}` : ""}</button>
          <button className={tab === "files" ? "on" : ""} onClick={() => setTab("files")}>Files</button>
        </div>
        <button className="icon-btn" title="Close the code panel (⌘E)" onClick={onClose}>×</button>
      </div>
      <div className="code-body">
        <div className="code-list">
          {tab === "files" && <input className="search" placeholder="Find a file" value={query} onChange={(e) => setQuery(e.target.value)} />}
          {tab === "changes" && !changes.length && <div className="empty">No changes{isGit ? " since the last commit" : ""}.</div>}
          {(tab === "changes" ? changes.map((c) => ({ p: c.path, m: MARK[c.status] ?? "?" })) : files.map((p) => ({ p, m: "" }))).map(({ p, m }) => (
            <button key={p} className={`code-file ${p === file ? "sel" : ""}`} title={p} onClick={() => void open(p, tab === "changes" ? "diff" : "edit")}>
              {m && <span className={`fmark f-${m}`}>{m}</span>}
              <span className="fname">{p.split("/").pop()}</span><span className="fdir">{p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : ""}</span>
            </button>
          ))}
        </div>
        <div className="code-main">
          {file && (
            <div className="code-bar">
              <span className="code-path" title={file}>{file}{dirty ? " ●" : ""}</span>
              {hasOriginal && <div className="seg small">
                <button className={view === "diff" ? "on" : ""} onClick={() => void open(file, "diff", true)}>Changes</button>
                <button className={view === "edit" ? "on" : ""} onClick={() => void open(file, "edit", true)}>Edit</button>
              </div>}
              <button className="btn primary sm" disabled={!dirty} onClick={() => void save()}>Save</button>
            </div>
          )}
          <div className="code-editor-wrap">
            <div className="code-editor" ref={host} />
            {!file && <div className="empty code-empty">Pick a file to see what changed or to edit it.</div>}
          </div>
        </div>
      </div>
    </div>
  );
}
