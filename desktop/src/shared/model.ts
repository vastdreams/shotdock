// The only shapes the UI renders. Main owns the state; renderers get snapshots of it.
// See docs/ARCHITECTURE.md section 5.

export type SessionKind = "hosted" | "terminal" | "ide" | "cursor-agent";
export type SessionState = "starting" | "working" | "needs-you" | "idle" | "failed" | "ended";

export interface Owner {
  kind: SessionKind;
  app: "ShotDock" | "Cursor" | "VS Code" | "Editor" | "Terminal";
}

export interface PendingPermission {
  requestId: string;
  tool: string;
  summary: string;      // one line a person can judge, e.g. "Bash: npm test"
  canAlways: boolean;   // Claude Code offered "always allow" rules for this request
  external?: boolean;   // seen in another app's transcript: answer it there (no Allow / Deny here)
}

export interface Session {
  id: string;
  kind: SessionKind;
  owner: Owner;
  folder: string;       // absolute working directory
  window: string;       // display name of the folder (last path part)
  title: string;
  state: SessionState;
  needs?: PendingPermission;
  model?: string;
  lastActivity: number; // epoch ms
  error?: string;
  live?: boolean;       // ShotDock is running this chat right now (only then can it Send / Stop / Allow)
  claims?: { at: number; checking?: boolean; error?: string;
             items: { claim: string; verdict: "supported" | "unsupported" | "unclear"; why: string }[]; followup?: string };
}

export type ItemRole = "user" | "assistant" | "tool" | "result" | "system";

export interface TranscriptItem {
  key: string;          // stable per item (uuid or synthetic)
  role: ItemRole;
  text: string;         // plain text / markdown
  tool?: { name: string; input: string; output?: string; isError?: boolean };
  images?: number;      // count of image blocks in the item
  at?: number;          // epoch ms
}

export interface Shot {
  id: string;
  path: string;         // absolute PNG path
  createdAt: number;
  sourceWindow?: string;
  sessionId?: string;   // the chat this shot was picked for; unassigned shots go with the open chat
  note?: string;        // extra context (e.g. element details)
}

export type ConnectionMode = "claude-code" | "api-key";

export interface Settings {
  connection: ConnectionMode;
  hasApiKey: boolean;               // never the key itself
  model: string;                    // default model for new hosted sessions
  permissionMode: "default" | "acceptEdits" | "plan";
  hotkeys: { capture: string; toggleHub: string; captureWindow: string; toggleWidget: string; element: string };
  alwaysOnTop: boolean;
  showOnAllDesktops: boolean;
  recentDays: number;
  closeTo: "bar" | "menubar";       // what the main window's close button does
}

export interface AppState {
  sessions: Record<string, Session>;
  transcripts: Record<string, TranscriptItem[]>; // loaded on demand, hosted sessions always
  shots: Shot[];                                  // pending attachments, newest last
  settings: Settings;
  lastError?: { scope: string; code: string; detail: string; at: number };
}

export const DEFAULT_SETTINGS: Settings = {
  connection: "claude-code",
  hasApiKey: false,
  model: "claude-opus-5-5",
  permissionMode: "default",
  hotkeys: { capture: "Control+Alt+X", toggleHub: "Control+Alt+Space", captureWindow: "Control+Alt+W", toggleWidget: "Control+Alt+D", element: "Control+Alt+E" },
  alwaysOnTop: true,
  showOnAllDesktops: true,
  recentDays: 14,
  closeTo: "bar",
};

export const needsYou = (s: Session) => s.state === "needs-you";
