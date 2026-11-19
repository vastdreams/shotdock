# Developing ShotDock

ShotDock 2 lives in [`desktop/`](../desktop): Electron + TypeScript + React, with two small Swift helpers for
macOS. Design and rules: [ARCHITECTURE.md](ARCHITECTURE.md). Code map: [desktop/README.md](../desktop/README.md).

## Build and run

```sh
cd desktop
npm install
npm test            # unit and flow tests, no network
npm start           # build and run from source
npm run pack:mac    # release/mac-arm64/ShotDock.app
npm run dist:mac    # .dmg and .zip in release/
```

Started from an editor's terminal? Editors set `ELECTRON_RUN_AS_NODE`, which makes Electron behave like plain
Node. Run `env -u ELECTRON_RUN_AS_NODE npm start`.

## Keep macOS permissions across rebuilds

macOS ties Screen Recording and Accessibility to the app's signature. Ad-hoc builds get a new one each time, so
you'd have to allow them again after every build. Make a local signing identity once:

```sh
desktop/scripts/make-signing-identity.sh
```

`pack:mac` and `dist:mac` then sign with it (`scripts/sign-local.sh`); without it they fall back to ad-hoc.
Public releases should be signed with an Apple Developer ID and notarized (set `CSC_LINK` / `CSC_KEY_PASSWORD`).

## Screenshots for the docs

```sh
cd desktop && npm run screenshots
```

Builds made-up projects and chats in `/Users/Shared/shotdock-demo` (`scripts/demo-data.py`) and renders every
view off-screen into `docs/images/`. No real chats are read and nothing appears on your screen. Update the demo
data when a feature needs a new picture.

## Release

1. Update `desktop/package.json` version and [CHANGELOG.md](../CHANGELOG.md); update [USER_GUIDE.md](USER_GUIDE.md)
   for anything users will notice (and its "Last updated" line).
2. `npm test && npm run screenshots && npm run dist:mac`
3. Tag and publish: `gh release create v<version> desktop/release/*.dmg desktop/release/*.zip --notes-file <notes>`

## Rules the code keeps

1. No synthetic input to deliver messages, except the one documented case: sending into an editor chat, which
   the Claude Code extension offers no API for (`native/macos/deliver.swift`: never types into a draft, restores
   the clipboard, verifies the paste).
2. One writer per chat (`core/registry.ts`, conflict guard in `adapters/watch/claudeProjects.ts`).
3. One-way state: adapters → store (`core/store.ts`) → windows.
4. Every request is validated (`shared/ipc.ts`) and returns ok or a coded error.
5. Files under 400 lines, one job each.
