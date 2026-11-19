# Security

## Reporting

Email security reports to the maintainers through a private GitHub security advisory on this repository. Please do
not open a public issue for a vulnerability.

## What ShotDock can do on your Mac, and why

| Permission | Why it is needed | Limits |
|---|---|---|
| Screen Recording | To capture the area, element or window you pick | Only when you start a capture |
| Accessibility | To read element details, focus a chat box and paste into it | Only into chat boxes it has identified; it never types into a box that already has text |

Both permissions belong to **ShotDock Launcher**, a small app that is not rebuilt, so a modified ShotDock binary
cannot silently inherit them without the launcher you approved.

## Data flow

- **Local by default.** Chats, shots, checks and feedback stay in `~/.duraloop/` and `~/Screenshots/`.
- **Claim checks** send a turn's steps and reply to the model you configure. Before sending, the checker removes
  API keys, tokens, JWTs, private keys, passwords and every value in an optional credentials file you point it at.
  Money figures are kept because claims are often about them; exclude whole folders with `claimcheck_exclude`.
- **No telemetry.** ShotDock sends nothing to its authors.
- **Keys** live in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never in files or logs.

## Updates

Releases carry an Ed25519 signature over the SHA-256 of the app zip. The public key is built into the app and the
installer. An update that fails the check is discarded, so a compromised release page or account cannot push code.
The private key never leaves the publisher's Keychain.

## Safe sending

- Sends refuse when the target chat box has text in it (you may be typing).
- Sends only target windows that are already open; ShotDock never opens a new Cursor window.
- Automatic follow-ups to chats are off by default.
