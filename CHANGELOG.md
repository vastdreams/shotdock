# Changelog

## 2.0.0-alpha.1 (19 November 2026)

ShotDock 2: a new app (Electron + TypeScript) in `desktop/`, replacing the Swift overlay.

- **All chats in one place.** Claude Code chats from Cursor, VS Code, Windsurf and the terminal, plus Cursor Agent
  chats (read-only), grouped by project with live status.
- **Chats ShotDock runs** through the Claude Agent SDK: send, stop, Allow / Deny tool requests, switch model,
  resume after a restart, copy into a new chat.
- **Send to editor chats.** Messages and screenshots go into the chat that's open in your editor; refuses when
  you have a draft there.
- **Needs you** for every chat, including editor and terminal chats (read from their chat files).
- **Screenshots:** area, window, screen, and element under the mouse (with app, window, page address and text);
  pick the chat; mark up with box, arrow, text, blur.
- **Code panel:** VS Code's editor with the project's git changes as diffs, quick open, edit and save.
- **Check claims** in the last answer against what actually ran.
- **Floating bar**, **quick panel** from the menu bar, close-to-bar, floats over full-screen apps, narrow windows.
- **Continue in Terminal** with the Claude Code that ships inside ShotDock.
- **Safety:** one writer per chat, conflict detection, file access limited to the chat's folder, redacted logs.

## 1.0.0

ShotDock 1 (Swift overlay, macOS). See `app/`.
