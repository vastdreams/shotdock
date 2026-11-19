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
export interface Nav { open?: string; view?: "hub" | "settings"; choose?: string }

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
    void call("state.get", {});
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
  s.kind === "hosted" ? "ShotDock" : s.kind === "cursor-agent" ? "Cursor Agent" : s.kind === "terminal" ? "Terminal" : "Editor";

export const canDrive = (s: Session) => s.kind === "hosted";
