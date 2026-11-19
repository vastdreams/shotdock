# ShotDock 2 (desktop, alpha)

Electron + TypeScript app for macOS and Windows. It lives in the menu bar (macOS) or system tray (Windows),
lists every Claude coding chat on the machine grouped by folder, and runs its own Claude Code chats through the
Claude Agent SDK. Design: [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Run

```sh
npm install
npm start              # build + run
npm test               # unit + flow tests (no network)
npm run pack:mac       # release/mac-arm64/ShotDock.app (unsigned)
npm run dist:mac       # signed .dmg + .zip when a Developer ID is in the keychain
npm run dist:win       # Windows installer (run on Windows)
```

If you start it from an editor's terminal, clear `ELECTRON_RUN_AS_NODE` first (`env -u ELECTRON_RUN_AS_NODE npm start`);
editors set it and it makes Electron run as plain Node.

## Using it

| Where | What |
|---|---|
| Menu bar / tray icon, left click | Quick panel: counts, Area / Window / Screen capture, New chat, chats that need you (Allow / Deny inline), recent chats by folder |
| Menu bar / tray icon, right click | Full menu: open, new chat, captures, "Needs you" list, Settings, Open at login, Quit |
| `Ctrl+Opt+Space` (`Ctrl+Alt+Space`) | Show or hide the main window |
| `Ctrl+Opt+D` | Quick panel (works when macOS hides the menu bar icon) |
| `Ctrl+Opt+X` / `Ctrl+Opt+W` | Screenshot an area / a window, then pick the chat it goes to |
| `Ctrl+Opt+E` | Screenshot the element under the mouse, with its app, window, page address and text (macOS) |
| Main window | Chats grouped by folder (⌘\ hides the list, ⊟ folds all folders); read any chat; Send, Stop, Allow / Deny, model picker |
| Chat header | **Continue here** (asks you to close it in the editor first), **Copy to new chat**, **Resume here** (ShotDock's own chats after a restart), More ▾: Check claims, Continue in Terminal, Open in editor / Send back to editor |
| Screenshot chips | Click to mark up: Box, Arrow, Text, Blur (pixelates) |

Connection (Settings): **Use my Claude Code setup** (no key; Claude Code uses what you configured for it) or an
**Anthropic API key** (encrypted by the OS). ShotDock never offers or handles a claude.ai login.

## Code map

```
src/
  shared/
    model.ts               Session, TranscriptItem, Shot, Settings, AppState: the only shapes the UI renders
    ipc.ts                 every request name + zod schema; Result type (ok | coded error)
  main/                    Electron main process (Node)
    index.ts               lifecycle, wiring, notifications, global shortcuts, dev smoke flag
    windows.ts             main window + quick panel (placement under the tray icon, fallback corner)
    tray.ts                menu bar / tray icon, its count and menu
    ipcServer.ts           one handler per request; validates args; never throws to the UI
    core/
      store.ts             pure reducer + store (Rule 3: one-way state)
      registry.ts          one writer per session (Rule 2)
      settings.ts          settings.json + API key via safeStorage (Keychain / DPAPI)
      log.ts               JSON lines log with secret and email redaction
    adapters/
      hosted/session.ts    one Agent SDK session: streaming input, canUseTool, interrupt, setModel (Rule 1)
      hosted/manager.ts    create / take over / fork / release; connection; Test connection; bundled binary path
      watch/parse.ts       Claude Code transcript parser (pure, tested)
      watch/files.ts       head / tail / appended-bytes readers
      watch/claudeProjects.ts  ~/.claude/projects poller (2 s), live tail of open chats
      watch/cursorAgents.ts    Cursor Agent transcripts + names (read-only sqlite3)
      editors.ts           Cursor / VS Code / Windsurf detection, open-session link
    capture/capture.ts     macOS screencapture; Windows Snipping Tool + clipboard; pasted images
  preload/index.ts         the only API renderers see (invoke, onState, onNav)
  renderer/                React UI (sandboxed, CSP)
    views/Hub.tsx  views/Widget.tsx  views/Settings.tsx
    parts/Sidebar.tsx  Reader.tsx  Composer.tsx  Chooser.tsx  Markdown.tsx
    api.ts  styles.css  main.tsx  index.html
tests/                     parse, store/registry, hosted session flows against a fake SDK
assets/                    tray template icons, app icon
scripts/build.mjs          esbuild (main, preload) + Vite (renderer)
```

## Rules the code keeps

1. No synthetic key presses, clicks, focus changes or clipboard writes to deliver anything.
2. One writer per chat. ShotDock writes only to chats it runs; others need Take over (or Fork).
3. Adapters emit events, the store reduces them, windows render snapshots. Nothing else mutates state.
4. Every request is validated and returns ok or a coded error the UI shows.
5. Files stay under 400 lines; one responsibility each.

## Safety rules for chats in other apps

- ShotDock sends only to chats it is running. An editor or terminal chat needs **Continue here**, which asks you to
  close it there first, or **Copy to new chat**. Nothing is taken over silently.
- If the editor or a terminal writes to a chat while ShotDock runs it, ShotDock stops its side at once and says so.
- Open in editor / Continue in Terminal on a chat ShotDock runs stops ShotDock's side first.
- "Needs you" for editor and terminal chats is read from their transcripts (an unanswered tool call or question);
  you answer those in the editor. Allow / Deny in ShotDock is for its own chats.

## Signing

`npm run pack:mac` signs with the local identity "ShotDock Local Signing" (scripts/sign-local.sh) so macOS keeps
Screen Recording / Accessibility across rebuilds. Releases need a Developer ID (`npm run dist:mac`).

## Not done yet (alpha)

- Notarized release (needs an Apple Developer ID) and a signed Windows installer (needs a certificate).
- Windows: built from the same code but not yet run on a Windows machine; element capture is macOS only.
- A terminal inside ShotDock (today: Continue in Terminal opens the system terminal), auto-update.
