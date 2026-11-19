# Agent setup guide (ShotDock 2)

For an AI agent (Claude Code, Cursor, or similar) installing ShotDock on a person's Mac. Run the commands yourself.
Ask the person only to switch on the two macOS permissions in step 4. Never edit System Settings files, TCC
databases or other apps' settings directly.

## 1. Check the machine

```sh
sw_vers -productVersion        # 13 or higher
```

## 2. Install

From the latest release (preferred):

```sh
cd "$(mktemp -d)" && gh release download --repo vastdreams/shotdock --pattern '*.dmg' \
  && hdiutil attach -nobrowse -quiet ./*.dmg && cp -R /Volumes/ShotDock*/ShotDock.app ~/Applications/ \
  && hdiutil detach -quiet /Volumes/ShotDock* && xattr -dr com.apple.quarantine ~/Applications/ShotDock.app
```

Or from source (needs Node 22+ and Xcode command line tools):

```sh
git clone https://github.com/vastdreams/shotdock && cd shotdock/desktop && npm install && npm test \
  && npm run pack:mac && cp -R release/mac-arm64/ShotDock.app ~/Applications/
```

## 3. Start it

```sh
env -u ELECTRON_RUN_AS_NODE open ~/Applications/ShotDock.app
```

## 4. Ask the person for two permissions

Say: "ShotDock is open. In its Settings (gear, top right) › macOS permissions, press **Allow…** next to Screen
recording and switch ShotDock on, then quit and reopen ShotDock. Do the same for Accessibility if you want element
screenshots or sending into editor chats."

## 5. Check

Ask the person to press **Test connection** in Settings and to press Ctrl+Opt+X and drag over any area: the "Send
screenshot to" list should appear. Logs: `~/Library/Application Support/ShotDock/logs/shotdock.log`.

ShotDock 1 (the Swift app) has its own guide: [docs/AGENT_SETUP_V1.md](docs/AGENT_SETUP_V1.md).
