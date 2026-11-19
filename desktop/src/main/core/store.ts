// The single source of truth (Rule 3). Adapters emit events; reduce() is pure; listeners get the new state.

import type { AppState, Session, SessionState, PendingPermission, Shot, TranscriptItem, Settings } from "../../shared/model";
import { DEFAULT_SETTINGS } from "../../shared/model";

export type StoreEvent =
  | { t: "session.upserted"; s: Session }
  | { t: "session.patch"; id: string; patch: Partial<Session> }
  | { t: "session.state"; id: string; state: SessionState; needs?: PendingPermission; error?: string }
  | { t: "session.removed"; id: string }
  | { t: "transcript.set"; id: string; items: TranscriptItem[] }
  | { t: "transcript.append"; id: string; items: TranscriptItem[] }
  | { t: "shot.added"; shot: Shot }
  | { t: "shot.removed"; id: string }
  | { t: "shot.patch"; id: string; patch: Partial<Shot> }
  | { t: "shot.cleared" }
  | { t: "settings.set"; settings: Settings }
  | { t: "error"; scope: string; code: string; detail: string };

const MAX_ITEMS = 2000; // per transcript kept in memory

export function initialState(settings: Settings = DEFAULT_SETTINGS): AppState {
  return { sessions: {}, transcripts: {}, shots: [], settings };
}

export function reduce(s: AppState, e: StoreEvent): AppState {
  switch (e.t) {
    case "session.upserted": {
      const prev = s.sessions[e.s.id];
      // A watcher must never overwrite a session ShotDock now owns.
      if (prev && prev.kind === "hosted" && e.s.kind !== "hosted") return s;
      return { ...s, sessions: { ...s.sessions, [e.s.id]: { ...prev, ...e.s } } };
    }
    case "session.patch": {
      const prev = s.sessions[e.id];
      if (!prev) return s;
      return { ...s, sessions: { ...s.sessions, [e.id]: { ...prev, ...e.patch } } };
    }
    case "session.state": {
      const prev = s.sessions[e.id];
      if (!prev) return s;
      const next: Session = { ...prev, state: e.state, needs: e.needs, error: e.error,
                              lastActivity: prev.kind === "hosted" ? Date.now() : prev.lastActivity };
      return { ...s, sessions: { ...s.sessions, [e.id]: next } };
    }
    case "session.removed": {
      const { [e.id]: _gone, ...rest } = s.sessions;
      const { [e.id]: _t, ...trest } = s.transcripts;
      return { ...s, sessions: rest, transcripts: trest };
    }
    case "transcript.set":
      return { ...s, transcripts: { ...s.transcripts, [e.id]: e.items.slice(-MAX_ITEMS) } };
    case "transcript.append": {
      const cur = s.transcripts[e.id] ?? [];
      const seen = new Set(cur.map((i) => i.key));
      const add = e.items.filter((i) => !seen.has(i.key));
      if (!add.length) return s;
      return { ...s, transcripts: { ...s.transcripts, [e.id]: [...cur, ...add].slice(-MAX_ITEMS) } };
    }
    case "shot.added":
      return { ...s, shots: [...s.shots, e.shot] };
    case "shot.removed":
      return { ...s, shots: s.shots.filter((x) => x.id !== e.id) };
    case "shot.patch":
      return { ...s, shots: s.shots.map((x) => (x.id === e.id ? { ...x, ...e.patch } : x)) };
    case "shot.cleared":
      return { ...s, shots: [] };
    case "settings.set":
      return { ...s, settings: e.settings };
    case "error":
      return { ...s, lastError: { scope: e.scope, code: e.code, detail: e.detail, at: Date.now() } };
  }
}

export class Store {
  private state: AppState;
  private listeners = new Set<(s: AppState) => void>();
  private pending: ReturnType<typeof setTimeout> | null = null;

  constructor(initial: AppState) { this.state = initial; }

  get(): AppState { return this.state; }

  dispatch(e: StoreEvent): void {
    const next = reduce(this.state, e);
    if (next === this.state) return;
    this.state = next;
    // Coalesce bursts (a transcript tail can emit many events) into one push per frame.
    if (!this.pending) this.pending = setTimeout(() => { this.pending = null; this.listeners.forEach((l) => l(this.state)); }, 16);
  }

  subscribe(l: (s: AppState) => void): () => void {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  }
}
