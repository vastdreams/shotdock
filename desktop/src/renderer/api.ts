// Renderer side of the typed IPC: call(name, args) and the live state hook.

import { useEffect, useState } from "react";
import type { AppState, Session } from "../shared/model";
import type { RequestArgs, RequestName, Result } from "../shared/ipc";

interface Bridge {
  platform: string;
  invoke(name: string, args?: unknown): Promise<Result<unknown>>;
  onState(fn: (s: AppState) => void): () => void;
  onNav(fn: (n: Nav) => void): () => void;
}
export interface Nav { open?: string; view?: "hub" | "settings"; choose?: string; code?: boolean }

declare global { interface Window { shotdock: Bridge } }

export const bridge = window.shotdock;
export const platform = bridge.platform;

export function call<N extends RequestName>(name: N, args?: RequestArgs<N>): Promise<Result<unknown>> {
  return bridge.invoke(name, args ?? {});
}

export function useAppState(): AppState | null {
  const [s, setS] = useState<AppState | null>(null);
  useEffect(() => {
    const off = bridge.onState(setS);
    // Ask for the current state now; pushes keep it fresh afterwards.
    void call("state.get", {}).then((r) => { if (r.ok && r.value) setS((cur) => cur ?? (r.value as AppState)); });
    return off;
  }, []);
  return s;
}

export function useNav(fn: (n: Nav) => void): void {
  useEffect(() => bridge.onNav(fn), [fn]);
}

/** Sessions grouped by window (folder), the most recently active window first, newest session first inside. */
export function groupByWindow(list: Session[]): { window: string; folder: string; sessions: Session[] }[] {
  const groups = new Map<string, { window: string; folder: string; sessions: Session[]; latest: number }>();
  for (const s of list) {
    const key = s.folder || s.window;
    const g = groups.get(key) ?? { window: s.window, folder: s.folder, sessions: [], latest: 0 };
    g.sessions.push(s);
    g.latest = Math.max(g.latest, s.lastActivity);
    groups.set(key, g);
  }
  return [...groups.values()]
    .sort((a, b) => b.latest - a.latest)
    .map((g) => ({ ...g, sessions: g.sessions.sort((a, b) => b.lastActivity - a.lastActivity) }));
}

export function ago(ms: number): string {
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 45) return "now";
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}

export const ownerLabel = (s: Session) =>
  s.kind === "hosted" ? (s.live ? "ShotDock" : "ShotDock (paused)") : s.kind === "cursor-agent" ? "Cursor Agent" : s.kind === "terminal" ? "Terminal" : "Editor";

/** ShotDock can send / stop / answer permissions only while it is running the chat. */
export const canDrive = (s: Session) => s.kind === "hosted" && s.live === true;

export type ContinueChoice = "continue" | "copy" | null;

/**
 * Make a chat sendable from ShotDock and return the id to send to (a copy gets a new id), or null.
 * - running here: as is
 * - ShotDock's own chat from an earlier run: resume quietly (nobody else owns it)
 * - editor / terminal chat: ask first (close it there, or copy it), never silently
 */
export async function ensureDrivable(s: Session, ask: (s: Session) => Promise<ContinueChoice>,
                                     notify: (m: string, bad?: boolean) => void): Promise<string | null> {
  if (canDrive(s)) return s.id;
  if (s.kind === "cursor-agent") { notify("Cursor Agent chats can be read here but not driven. Open them in Cursor.", true); return null; }
  let args: { id: string; fork: boolean; confirmClosed: boolean } = { id: s.id, fork: false, confirmClosed: true };
  if (s.kind !== "hosted") {
    const choice = await ask(s);
    if (!choice) return null;
    args = { id: s.id, fork: choice === "copy", confirmClosed: choice === "continue" };
  }
  const r = await call("session.takeOver", args);
  if (!r.ok) { notify(r.message, true); return null; }
  return r.value as string;
}
