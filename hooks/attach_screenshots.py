#!/usr/bin/env python3
"""
UserPromptSubmit hook: hand Claude any screenshot taken since the last message.

The operator takes screenshots with Cmd+Shift+4 (macOS saves them to ~/Screenshots). On each prompt this
lists image files in that folder newer than the last prompt, and tells Claude their paths so it reads them.
State is one timestamp in ~/.claude/state/last_screenshot_check. Never blocks the prompt.
"""

import json
import sys
import time
from pathlib import Path

FOLDER = Path.home() / "Screenshots"
STATE = Path.home() / ".claude" / "state" / "last_screenshot_check"
EXTS = {".png", ".jpg", ".jpeg", ".heic"}
MAX_FILES = 6


def safe_name(p: Path) -> Path:
    """macOS names shots with a narrow no-break space before am/pm; rename to a plain ASCII name."""
    if p.name.isascii() and " " not in p.name:
        return p
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(p.stat().st_mtime))
    target = p.with_name(f"shot-{stamp}{p.suffix.lower()}")
    n = 1
    while target.exists():
        target = p.with_name(f"shot-{stamp}-{n}{p.suffix.lower()}")
        n += 1
    try:
        p.rename(target)
        return target
    except OSError:
        return p


def main() -> None:
    try:
        sys.stdin.read()
        now = time.time()
        STATE.parent.mkdir(parents=True, exist_ok=True)
        last = float(STATE.read_text().strip()) if STATE.exists() else now
        STATE.write_text(str(now))
        if not FOLDER.is_dir():
            return
        new = sorted(
            (p for p in FOLDER.iterdir() if p.suffix.lower() in EXTS and p.stat().st_mtime > last),
            key=lambda p: p.stat().st_mtime,
        )[-MAX_FILES:]
        if not new:
            return
        new = [safe_name(p) for p in new]
        lines = "\n".join(f"- {p}" for p in new)
        context = (
            "The operator took screenshot(s) since their last message. Read each one with the Read tool "
            "before answering; the message is probably about what they show:\n" + lines
        )
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}))
    except Exception:
        return


if __name__ == "__main__":
    main()
