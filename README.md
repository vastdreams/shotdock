# ShotDock

A floating overlay for people who run several AI coding chats at once (Claude Code and Cursor). It watches every
chat, tells you which ones are working, stalled or waiting on you, checks whether "it's done" claims are backed up,
and sends screenshots and element details to the right chat in one move.

By **FSE Research and Investments**. MIT licence.

## What it does

- **One overlay.** A slim bar that expands into a chat list (grouped by folder, with search, filters, archive and
  unread markers) and the selected chat's conversation, with a chat box to reply from.
- **Live status.** Blue = working, orange = stalled 10 minutes, teal dot = new reply you have not read.
- **Claim checks.** When a chat ends a turn saying something is done, merged, sent or live, the claim checker asks
  a model you choose (DeepSeek by default) whether the steps in that turn prove it. For "it's live" claims it also
  fetches the live version pages you list, so the verdict rests on the real site.
- **Capture.** Screenshot (drag), Element (hover-pick: type, id, classes, text, page URL), Whole window, Scrolling
  capture, Record a bug (key frames plus frozen stretches), Before / after (changes highlighted), One-key send.
- **Markup.** Boxes, arrows, numbered pins, text, highlight, blur, and auto-blur of emails, money, phone numbers and
  keys.
- **Text in shots.** macOS text recognition reads each shot and sends the text along.

## Install (macOS 13 or later)

```
curl -fsSL https://raw.githubusercontent.com/vastdreams/shotdock/main/install.sh | zsh
```

With Apple's command line tools installed it builds from source. Without them it downloads the latest release and
installs it **only if its Ed25519 signature verifies**. Then:

1. Open **ShotDock Launcher** once and allow **Screen Recording** and **Accessibility** when macOS asks.
2. In the bar, **⋯ → Settings and API keys**: paste your DeepSeek (or Anthropic or OpenAI) key. Keys go to your
   Keychain, never to a file.
3. For Claude Code in Cursor, add the keybinding `ctrl+alt+cmd+c` → `claude-vscode.focus` (see docs/SETUP.md).

Build from source yourself: `git clone`, then `./build.sh && scripts/install_launcher.sh`.

## Shortcuts

| Keys | Action |
|---|---|
| ⌃⌥X | Screenshot |
| ⌃⌥E | Element |
| ⌃⌥W | Whole window |
| ⌃⌥R | Record a bug |
| ⌃⌥Q | One-key send to your last chat |
| ⌃⌥M | Show or hide the overlay |
| ⌘1–9 | Jump to a chat (hub open) |

## Privacy and security

Read [SECURITY.md](SECURITY.md). In short: local by default, nothing leaves your Mac unless you add a model key or a
DuraLoop server; secrets are scrubbed before any text goes to a model; updates are signature-checked.

## Windows

Not yet. See [windows/README.md](windows/README.md) for the plan. The claim checker (Python) already runs there.
