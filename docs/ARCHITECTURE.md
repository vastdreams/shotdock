# ShotDock 2 — Architecture

Status: phase 1 implemented in `desktop/` (alpha), 19 November 2026. Owner: FSE Research and Investments.
Replaces the Swift prototype in `app/` (kept running until phase 3 below ships). Code map: `desktop/README.md`.

### What the alpha changed from this plan

- Secrets use Electron `safeStorage` (Keychain / DPAPI) instead of `keytar`: no native module to rebuild.
- Settings are a JSON file with atomic writes instead of SQLite; nothing yet needs queries.
- Watchers poll every 2 s (Cursor: 4 s) instead of chokidar; reliable on both OSes and network folders.
- Capture uses the system tools (macOS `screencapture`, Windows Snipping Tool) until the native helper ships.
- The menu bar / tray quick panel is a second window; a shortcut (Ctrl+Opt+D) opens it when macOS hides the icon.
- The SDK's bundled Claude Code binary is unpacked from `app.asar` and passed as `pathToClaudeCodeExecutable`.

## 1. What ShotDock is for

One window that floats over everything, from which you can see, read, drive and feed every Claude coding session
on the machine, without going to the editor or terminal that holds it.

It must let you:

1. See every session at a glance: which are working, which need you, which finished, which claimed something false.
2. Read any session in full, including tool calls, diffs and images.
3. Drive a session: send a message with screenshots or page elements, stop it, approve or deny a permission
   request, change model or mode, start a new one in any folder.
4. Capture fast: area, window, page element, scrolling page, recording, before/after, with markup and auto-blur.
5. Check claims ("tests pass", "deployed", "email sent") against real evidence and offer a follow-up.
6. Install in one step on macOS and Windows, update itself safely, and never take over the keyboard, mouse or
   clipboard to do any of this.

### Non-goals

- Replacing the editor. ShotDock opens files and diffs in the editor; it does not edit code itself.
- Offering claude.ai login. Anthropic does not allow third-party apps to offer claude.ai login or its rate limits
  unless approved (Agent SDK docs, "Get started"). See section 6.
- Remote control of other machines. Local only; DuraLoop sync is an optional export.

## 2. Why the prototype breaks, and the rule that replaces it

The prototype drives Cursor like a person: bring the window forward, switch Space, find the chat box through
the accessibility tree, paste through the clipboard, press Return, then read the transcript to see if it landed.
Every step can fail independently (focus moved, Space did not switch, box had a draft, accessibility tree changed
in an editor update, two sends overlapped, the user typed at the same moment). The log for 19 November shows
14 failed sends and none confirmed.

**Rule 1: ShotDock never sends input by simulating a person.** No synthetic key presses, no clipboard writes, no
focus stealing on any path that delivers a message. Every action goes through a programmatic channel that returns
a typed result.

**Rule 2: every session has exactly one owner (writer).** The owner is the process that runs the agent loop for
it: ShotDock itself, a terminal `claude`, or the IDE extension. ShotDock only writes to sessions it owns, or
asks the owner to. Two writers on one transcript corrupt it.

**Rule 3: state flows one way.** Adapters produce events; a single store reduces them; the UI renders the store.
The UI never reads files or calls adapters directly.

## 3. Session kinds and how each is driven

| Kind | Who owns the loop | How ShotDock reads it | How ShotDock drives it |
|---|---|---|---|
| **Hosted** | ShotDock, through the Claude Agent SDK | SDK message stream (live) | SDK: streaming input (send), `interrupt()`, `canUseTool` callback (approve / deny), `setModel` / `setPermissionMode`, `resume` / `forkSession` |
| **Terminal** | ShotDock-launched `claude` in a pseudo-terminal it owns | Transcript file + the PTY screen | Write to the PTY it owns (this is its own terminal, not the user's keyboard) |
| **IDE** | Claude Code extension in Cursor / VS Code / Windsurf | Transcript file `~/.claude/projects/<cwd>/<id>.jsonl` (tailed) | Read-only by default. "Take over" moves ownership to Hosted (section 3.1). "Open in editor" uses the extension's documented `<scheme>://anthropic.claude-code/open?session=<id>` link |
| **Cursor Agent** | Cursor's own agent | `~/.cursor/projects/<key>/agent-transcripts/<id>/<id>.jsonl` | Read-only; "Open in Cursor". No programmatic input exists; ShotDock does not fake one |

Hosted is the main mode. A session started in ShotDock is an ordinary Claude Code session: its transcript lands
in the same `~/.claude/projects` folder, so it also shows up in `claude --resume` and in the IDE's session list.

### 3.1 Take over and hand back

- **Take over** (IDE or Terminal session → Hosted). ShotDock checks the session is idle (last transcript entry
  is a finished assistant turn, no write in 10 s). It asks you to close that chat in the editor, then resumes it
  with the SDK (`resume: <id>`). If it cannot confirm idle, it offers **Fork** instead (`forkSession: true`),
  which never touches the original.
- **Hand back** (Hosted → IDE). ShotDock ends its loop for that session, then opens the editor link with the
  session id. The extension resumes it.
- Ownership lives in the session registry (section 5) and is shown on every row ("in ShotDock", "in Cursor",
  "in Terminal"). The Send box is disabled for sessions ShotDock does not own, with one button: Take over.

### 3.2 Optional editor bridge (phase 4, spike first)

A small VS Code-compatible extension (`bridge/`) that runs in Cursor / VS Code / Windsurf and exposes a local,
authenticated socket. It can report which Claude sessions are open in which window and open or focus one. It does
not type into Claude's panel; that panel has no public input API. If the Claude Code extension adds one, the
bridge is where it gets used. Until then IDE sessions stay read-only plus Take over.

## 4. Process model

```
┌──────────────────────── Electron main (Node, TypeScript) ────────────────────────┐
│  core/      store, registry, event bus, persistence, settings, auth, updater     │
│  adapters/  hosted (Agent SDK), terminal (node-pty), ide-watch, cursor-watch     │
│  capture/   calls the native helper; post-processing (OCR, blur, diff, stitch)   │
│  checks/    claim checker (Claude API), evidence fetchers                        │
│  ipc/       typed request/response + event channels (zod-validated)              │
└───────────────▲──────────────────────────────▲────────────────────────────────────┘
                │ IPC (contextBridge, typed)   │ stdio JSON-RPC
┌───────────────┴──────────────┐   ┌───────────┴─────────────────────────────────────┐
│ Renderer (React, sandboxed)  │   │ Native helper per OS                            │
│ overlay bar, hub, composer,  │   │ macOS: Swift (ScreenCaptureKit, AX element      │
│ reader, chooser, markup,     │   │ picker, global hotkeys, window list)            │
│ settings, terminal (xterm)   │   │ Windows: C# / .NET (Graphics Capture, UI        │
└──────────────────────────────┘   │ Automation picker, RegisterHotKey)              │
                                   └─────────────────────────────────────────────────┘
```

Why this shape:

- **Electron + TypeScript**: the Claude Agent SDK is first-class in TypeScript, `node-pty` + `xterm.js` give a
  real terminal on both OSes, and one UI codebase covers macOS and Windows. Tauri was considered; it would still
  need a Node sidecar for the SDK, so it adds a process without removing one.
- **Native helper** keeps the OS-specific parts (screen capture, accessibility, hotkeys) small, replaceable and
  separately testable. Its contract is a JSON-RPC schema, so the Windows and macOS helpers are interchangeable.
- **Renderer is sandboxed** (`contextIsolation: true`, `nodeIntegration: false`, strict CSP). It never sees API
  keys or file paths outside what the store gives it.

## 5. Data model (single source of truth)

```ts
// core/model.ts — the only shapes the UI ever renders
type SessionKind = "hosted" | "terminal" | "ide" | "cursor-agent";
type Owner = { kind: SessionKind; app?: "Cursor" | "VS Code" | "Windsurf" | "Terminal" | "ShotDock"; pid?: number };
type SessionState = "starting" | "working" | "needs-you" | "idle" | "failed" | "ended";

interface Session {
  id: string;                 // Claude session id (or Cursor transcript id)
  kind: SessionKind;
  owner: Owner;
  folder: string;             // absolute cwd
  window: string;             // display name of the folder / editor window
  title: string;              // ai title, Cursor name, or first prompt
  state: SessionState;
  needs?: PendingPermission;  // set when state = needs-you
  model?: string;
  lastActivity: number;       // epoch ms
  claims?: ClaimSummary;      // from the checker
}

interface PendingPermission { requestId: string; tool: string; summary: string; input: unknown }

type Event =                  // everything that changes state is one of these
  | { t: "session.upserted"; s: Session }
  | { t: "session.message"; id: string; m: TranscriptItem }
  | { t: "session.state"; id: string; state: SessionState; needs?: PendingPermission }
  | { t: "session.ended"; id: string; reason: string }
  | { t: "capture.ready"; shot: Shot }
  | { t: "claims.updated"; id: string; claims: ClaimSummary }
  | { t: "error"; scope: string; code: string; detail: string };
```

- `core/store.ts` is a pure reducer `(State, Event) => State`. Adapters emit events; nothing else mutates state.
- `core/registry.ts` owns the ownership map and enforces Rule 2 (`claim(id, owner)` fails if another live owner
  holds it).
- Persistence: SQLite (`better-sqlite3`) in the app data folder for sessions index, read marks, pins, archived,
  claim results and settings. Transcripts are never copied; they are read in place.

## 6. Claude connection and authentication

Settings → Claude offers, in this order:

1. **Anthropic API key**. Stored in the OS keychain (macOS Keychain, Windows Credential Manager via `keytar`),
   never in files or logs. Passed to the Agent SDK through the environment of the SDK subprocess only.
2. **Amazon Bedrock / Google Vertex AI / Microsoft Foundry**. Uses the provider's own credentials on the machine
   (AWS profile, gcloud ADC, Azure). ShotDock stores only the profile / project / region names.
3. **Use my Claude Code setup**. ShotDock starts the user's own installed `claude` command without passing any
   key; the CLI uses whatever the user configured in Claude Code (`claude` itself handles its own login). ShotDock
   never shows a claude.ai login screen, never handles claude.ai tokens and never reads Claude Code's stored
   credentials. In the public build this option is labelled with that boundary.

"Add Claude directly" therefore means: paste an API key once, or point at a provider, or reuse an existing Claude
Code install. A **Test connection** button runs a one-turn hosted session and shows the model and latency.

Model choice: default `claude-opus-5-5`; per-session picker lists the models the connection reports.

## 7. Module structure

```
shotdock/
  apps/desktop/
    src/main/
      index.ts                  app lifecycle, single instance, windows
      windows/overlay.ts        floating bar + hub window (always on top, all Spaces / virtual desktops)
      windows/tray.ts
      ipc/contract.ts           zod schemas for every request, response and event (shared with renderer)
      ipc/server.ts             one handler per request; validates in and out
      core/store.ts             reducer
      core/model.ts             types above
      core/registry.ts          ownership
      core/bus.ts               typed event bus
      core/db.ts                SQLite, migrations in core/migrations/*.sql
      core/settings.ts
      core/secrets.ts           keychain wrapper (the only module that touches keys)
      core/log.ts               structured JSON log, redaction built in
      adapters/hosted/session.ts        one Agent SDK query per hosted session, streaming input queue
      adapters/hosted/permissions.ts    canUseTool → PendingPermission → user decision → resolve
      adapters/terminal/pty.ts          node-pty session running `claude` (or `claude --resume <id>`)
      adapters/watch/claude-projects.ts tail ~/.claude/projects/**.jsonl (chokidar), parse, emit
      adapters/watch/cursor-agents.ts   tail Cursor agent transcripts + read-only name/status lookup
      adapters/watch/parse.ts           transcript line → TranscriptItem (golden-tested)
      adapters/editors.ts               editor table (Cursor, VS Code, Insiders, Windsurf, VSCodium): links, CLI
      capture/helper.ts                 spawn + JSON-RPC client for the native helper
      capture/post.ts                   OCR, auto-blur boxes, stitch, before/after diff
      checks/checker.ts                 claim extraction + verdict (Claude API, structured output)
      checks/evidence/*.ts              gitlab.ts, http-probe.ts, transcript.ts (tests/CI output in the chat)
      update/updater.ts                 signed updates (section 9)
    src/renderer/
      app.tsx  state.ts (subscribes to store snapshots)
      bar/  hub/  reader/  composer/  chooser/  markup/  settings/  terminal/
    src/preload/index.ts              exposes the typed IPC client only
  native/
    macos/ShotDockHelper/            Swift package: capture, picker, hotkeys, windows (JSON-RPC over stdio)
    windows/ShotDockHelper/          .NET 8: same contract
    contract/helper.schema.json      the shared helper contract
  bridge/                            optional editor extension (phase 4)
  packages/transcript/               parser shared by app and tests
  tests/
    golden/                          real (redacted) transcript fixtures → expected TranscriptItems
    contract/                        IPC + helper schema tests
    fakes/                           FakeAgentSdk, FakePty, FakeHelper, FakeClock
    e2e/                             Playwright for Electron: full flows against fakes
  docs/ARCHITECTURE.md  SETUP.md  SECURITY.md  AGENT_SETUP.md
```

Rules for the tree: no file over 400 lines; one responsibility per file; adapters never import renderer code;
renderer never imports main code (only `ipc/contract.ts` types).

## 8. Key flows

### 8.1 Screenshot to a session

1. Hotkey → helper `capture.area` → `capture.ready` event with the PNG path and, for element mode, the element
   details (role, label, URL, selector, outer HTML when the page exposes it).
2. Chooser opens in the overlay: sessions grouped by window, newest first; the window the shot came from on top.
3. Pick → hub opens on that session with the shot attached and the cursor in the composer.
4. Send:
   - Hosted: message (text + image blocks) goes into the session's streaming input. Result: `accepted`, then
     the session's own events show it running.
   - IDE / Terminal not owned: Send button reads **Take over and send**; nothing is sent until ownership moves.
5. No clipboard, no focus change, no key presses at any step.

### 8.2 Permission request

`canUseTool(tool, input)` in the hosted adapter → emits `session.state needs-you` with the request → overlay
shows a notification "<session>: wants to run <tool>" with Allow once / Always for this session / Deny →
the adapter resolves the pending promise. Times out to Deny after the configured period (default: never).

### 8.3 Stop

Stop button → `interrupt()` on the hosted query, or SIGINT to the owned PTY. Not available for sessions ShotDock
does not own.

### 8.4 Claim check

After each finished turn of any session: the checker extracts claims from the final assistant text, gathers
evidence (tool results in the same turn, GitLab pipeline / MR state when a link or IID is present, HTTP probes of
URLs the claim names), and asks Claude for a verdict per claim using structured output. A claim is only marked
**unsupported** when evidence contradicts it or is missing for a checkable claim. The UI shows a ready-made
follow-up message; it is never sent automatically.

## 9. Install and update

| | macOS | Windows |
|---|---|---|
| Package | Signed + notarized `.dmg` (Developer ID) | Signed MSIX, plus a `winget` manifest |
| Updates | `electron-updater` from GitHub Releases; every artifact signed, update metadata verified | Same |
| Permissions | First-run checklist: Screen Recording, Accessibility (for element picking only), Notifications. Each row shows live status and an "Open settings" button | Notifications; no special permissions for capture |
| Agent install | `curl -fsSL …/install.sh \| sh` installs the release and runs `shotdock doctor` | `winget install FSE.ShotDock` |

Signing the app removes the prototype's launcher trick: permissions attach to the signed app identity and survive
updates.

`shotdock doctor` (CLI inside the app bundle) checks: Claude connection, permissions, editor detection,
transcript folders readable, helper responds, update channel reachable. Each failed check prints the fix.

## 10. Reliability: how it stays working without manual bug hunts

1. **Typed boundaries everywhere.** Every IPC message, helper call and SDK event is validated with zod at the
   boundary. Bad input becomes an `error` event with a code, never a crash or silent no-op.
2. **Golden transcript tests.** `tests/golden/` holds real, redacted transcripts from Claude Code and Cursor
   (several versions). Any parser change must reproduce the expected items. When an editor update changes its
   format, add the new fixture first, see it fail, then fix.
3. **Fakes for every outside system.** `FakeAgentSdk` (scripted message streams, permission requests, interrupts),
   `FakePty`, `FakeHelper`, `FakeClock`. The e2e suite drives the real app UI against these, so flows such as
   "screenshot → choose → send → permission → allow → finished" run in CI on both OSes without Claude or a screen.
4. **Contract tests for the native helper**, run on a macOS and a Windows CI runner against the shared schema.
5. **One live smoke test per release** (manual trigger): real API key, one hosted session in a temp folder,
   send, permission, stop, resume. Recorded to the release notes.
6. **No hidden retries.** An action either succeeds with a typed result or returns a coded error shown in the UI
   ("Session is owned by Cursor. Take over?"). The log always has the same code.
7. **Version pinning.** The Agent SDK version is pinned; Renovate opens upgrade PRs, which must pass the golden and
   e2e suites.
8. **Crash safety.** Hosted sessions are Claude Code sessions on disk; if ShotDock quits, they resume on next start
   (`resume: <id>`), never lost.

## 11. Security

- Keys only in the OS keychain; `core/secrets.ts` is the single reader. Logs redact anything matching key, token
  and email patterns before writing.
- Renderer sandboxed with CSP; no remote content except image previews of local files.
- The claim checker sends transcript excerpts to the configured provider only after redaction, and only when the
  user has turned checking on.
- Editor bridge socket (phase 4) binds to localhost with a per-install random token.
- Updates verified by signature before install; no unsigned code path.

## 12. Plan

| Phase | Ships | Exit test |
|---|---|---|
| 0. Spike (2 days) | Agent SDK hosted session in Electron: send, stream, interrupt, permission callback, resume a session created by the IDE (forked) | Scripted demo passes against a real key; findings written into this doc |
| 1. Core (1 week) | Store, registry, watchers for Claude and Cursor transcripts, hub reader, chooser, hosted sessions, API key + provider settings, macOS helper capture | e2e suite green on macOS; daily use replaces the prototype for reading and hosted chats |
| 2. Drive (1 week) | Permissions UI, stop, model / mode switch, new session in folder, terminal sessions (xterm + node-pty), Take over / Hand back | e2e green; no keyboard simulation left in the code (CI grep check) |
| 3. Ship (1 week) | Signing + notarization, updater, doctor, first-run checklist, Windows helper + MSIX | Fresh-machine install test on macOS and Windows passes from the README alone |
| 4. Extras | Claim checker v2 with evidence, editor bridge (if the spike shows value), diff / file view, DuraLoop export, local model option | Per feature |

The Swift prototype stays installed until phase 3 passes, then `uninstall.sh` removes it.

## 13. Open questions

1. Apple Developer ID and Windows code-signing certificate: who holds them for FSE Research and Investments.
2. Whether the Claude Code extension will accept "resume this session" from an external link while the same
   session is open (phase 0 spike checks this; the design does not depend on it).
3. Public name: "ShotDock" may change before the public release.
