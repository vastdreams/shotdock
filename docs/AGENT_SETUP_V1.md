# Agent setup guide

For an AI agent (Claude Code, Cursor, or similar) installing ShotDock on a person's Mac. Follow the steps in order.
Run every command yourself. Ask the person only for the two permission toggles in step 4. Do not edit System
Settings files, TCC databases or other apps' settings directly.

## 0. Check the machine

```
sw_vers -productVersion        # must be 13 or higher
xcrun --find swiftc            # must print a path
```

If `swiftc` is missing, run `xcode-select --install`, tell the person: "A window from Apple is asking to install
command line tools. Please click Install and tell me when it finishes." Wait, then continue.

## 1. Check for an existing install

```
P=~/Applications/ShotDock.app/Contents/Info.plist; [[ -f $P ]] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $P
```

- Nothing printed: fresh install, continue.
- `com.fseresearch.shotdock`: an earlier version; the installer updates it in place.
- Anything else: a different build is installed. Stop and ask the person whether to remove it
  (`zsh uninstall.sh --id <that id>`). Never install over it.

## 2. Install

```
curl -fsSL https://raw.githubusercontent.com/vastdreams/shotdock/main/install.sh | zsh
```

Expected: `✓ ShotDock installed.` followed by the doctor and uninstall commands. ShotDock Launcher starts and a
checklist window opens on the person's screen. (Build warnings, if any, go to `$TMPDIR/shotdock-build.log`.)

Installer options: `SHOTDOCK_SRC=/path/to/checkout` installs from a local copy; `SHOTDOCK_NO_LAUNCH=1` installs files
only and starts nothing (no checklist window, launcher not running).

## 3. Check what is still needed

```
~/Applications/ShotDock.app/Contents/MacOS/ShotDock --doctor
```

Each line is `OK` or `TODO`, then `READY` / `NOT READY`, then a `JSON` line you can parse. Exit code 0 means READY.

`READY` needs: `launcher`, `screen`, `accessibility`, `keybinding`, `cursor-a11y`. `apikey` and `hook` are optional.

The two permission checks come from the launcher itself (it writes `~/Library/Application Support/ShotDock/permissions.json`
every 5 seconds). A terminal checking for itself would report the terminal's permissions, so doctor never does that:
if the launcher is not running, `screen` and `accessibility` show `TODO`.

## 4. The only two things the person must do

macOS does not let software grant these itself. Tell the person exactly this:

> "In the ShotDock checklist that just opened, click **Open settings** next to **Screen Recording**, switch on
> **ShotDock Launcher**, and do the same for **Accessibility**. If macOS asks to quit and reopen the launcher,
> click **Quit & Reopen**."

Then run `--doctor` again until `screen` and `accessibility` are `true`.

## 5. Fixes you can apply yourself

Same as the checklist's **Fix** buttons. Each keeps a copy of the file it changes, named
`<file>.shotdock-backup-<timestamp>` (none when the file did not exist yet). Running a fix twice changes nothing.

| Check | Command | What it changes |
|---|---|---|
| `keybinding` | `~/Applications/ShotDock.app/Contents/MacOS/ShotDock --fix keybinding` | adds `ctrl+alt+cmd+c` → `claude-vscode.focus` to Cursor's `keybindings.json` |
| `cursor-a11y` | `… --fix cursor-a11y` | sets `"editor.accessibilitySupport": "off"` in Cursor's `settings.json` (corrects `"on"` too) |
| `hook` (optional) | `… --fix hook` | adds `python3 ~/.claude/hooks/attach_screenshots.py` under `hooks.UserPromptSubmit` in `~/.claude/settings.json` |
| `apikey` (optional) | ask the person for their DeepSeek key and have them paste it in **⋯ → Settings and API keys**. Never write keys to files or print them. |

## 6. Confirm

```
~/Applications/ShotDock.app/Contents/MacOS/ShotDock --doctor   # expect READY
pgrep -fl "ShotDock"                                           # launcher and app running
```

Tell the person: "ShotDock is the bar in the corner. ⌃⌥X takes a screenshot, ⌃⌥E picks an element, 💬 opens
your chats."

## Undo

```
zsh ~/Library/Application\ Support/ShotDock/uninstall.sh            # removes the apps, login item and permissions
zsh ~/Library/Application\ Support/ShotDock/uninstall.sh --purge    # also removes settings, saved shots and API keys
```

Without `--purge` it keeps: editor settings and their backups, `~/.claude/hooks/attach_screenshots.py`, `~/.duraloop/`
and `~/Screenshots/sent/`. Login item and permission resets only run when `HOME` is the real home folder, so a test
install in a throwaway `HOME` never touches the real account.
