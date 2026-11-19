# Setup details

## Cursor keybinding for Claude Code
Add to `~/Library/Application Support/Cursor/User/keybindings.json`:
```json
{ "key": "ctrl+alt+cmd+c", "command": "claude-vscode.focus" }
```
Also set `"editor.accessibilitySupport": "off"` in Cursor settings; reading Cursor's accessibility tree otherwise
switches it to screen-reader mode.

## Screenshots with your next message
`hooks/attach_screenshots.py` is a Claude Code `UserPromptSubmit` hook: Cmd+Shift+4 shots saved in `~/Screenshots`
are handed to Claude with your next message. Add it under `hooks.UserPromptSubmit` in `~/.claude/settings.json`.

## Config (`~/.duraloop/config.json`)
| Key | Meaning |
|---|---|
| `mode` | `local` (default), `org` or `self-hosted` |
| `claimcheck_provider`, `claimcheck_model` | `deepseek` / `anthropic` / `openai` and the model name |
| `claimcheck_exclude` | folders never sent for checking |
| `live_checks` | `[{"match": "regex", "url": "https://…/version.json"}]` fetched for "it's live" claims |
| `credentials_file` | optional JSON whose values are scrubbed from anything sent out |
| `project_roots` | folders searched for a workspace by name |
