#!/usr/bin/env python3
"""Make a demo home folder for screenshots: four fake projects (one a git repo with a change) and six Claude Code
chats in different states. Nothing real is read. Usage: demo-data.py /Users/Shared/shotdock-demo"""
import datetime, json, os, shutil, subprocess, sys, time, uuid

H = sys.argv[1] if len(sys.argv) > 1 else "/Users/Shared/shotdock-demo"
shutil.rmtree(H, ignore_errors=True)
P = os.path.join(H, "projects")

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)

web = os.path.join(P, "acme-web")
write(os.path.join(web, "src/checkout/tax.ts"), """export function lineTax(price: number, rate: number): number {
  return price * rate;
}

export function orderTax(lines: { price: number; qty: number }[], rate: number): number {
  return lines.reduce((sum, l) => sum + lineTax(l.price * l.qty, rate), 0);
}
""")
write(os.path.join(web, "README.md"), "# acme-web\n\nStorefront for Acme.\n")
git = lambda *a: subprocess.run(["git", "-C", web, *a], check=True, capture_output=True)
git("init", "-q"); git("config", "user.email", "demo@example.com"); git("config", "user.name", "Demo")
git("add", "."); git("commit", "-qm", "initial")
write(os.path.join(web, "src/checkout/tax.ts"), """/** Tax for one line, rounded to cents (half up), so totals match the receipt. */
export function lineTax(price: number, rate: number): number {
  return Math.round(price * rate * 100 + Number.EPSILON) / 100;
}

export function orderTax(lines: { price: number; qty: number }[], rate: number): number {
  const total = lines.reduce((sum, l) => sum + lineTax(l.price * l.qty, rate), 0);
  return Math.round(total * 100) / 100;
}
""")
write(os.path.join(web, "src/checkout/tax.test.ts"), """import { lineTax, orderTax } from "./tax";

test("rounds each line to cents", () => expect(lineTax(19.99, 0.0825)).toBe(1.65));
test("order total matches the receipt", () => expect(orderTax([{ price: 19.99, qty: 3 }], 0.0825)).toBe(4.95));
""")
api, mob, docs = (os.path.join(P, n) for n in ("api-service", "mobile-app", "docs-site"))
for d in (api, mob, docs): write(os.path.join(d, "README.md"), f"# {os.path.basename(d)}\n")

def iso(ago): return (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
key = lambda p: "".join(c if c.isalnum() else "-" for c in p)

def chat(folder, title, entry, turns, ago, pending=None):
    sid = str(uuid.uuid4()); lines = []; t = ago + len(turns) * 20 + 30; parent = None
    def add(o):
        nonlocal t, parent
        o.update({"sessionId": sid, "cwd": folder, "entrypoint": entry, "timestamp": iso(t), "uuid": str(uuid.uuid4()), "parentUuid": parent})
        parent = o["uuid"]; t -= 10; lines.append(json.dumps(o))
    for role, content in turns:
        if role == "user": add({"type": "user", "message": {"role": "user", "content": content}})
        elif role == "tool":
            tid = "toolu_" + uuid.uuid4().hex[:12]; name, inp, res, err = content
            add({"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5-5", "stop_reason": "tool_use",
                 "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}})
            add({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": res, "is_error": err}]}})
        else:
            add({"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [{"type": "text", "text": content}]}})
    if pending:
        add({"type": "assistant", "message": {"role": "assistant", "model": "claude-opus-5-5", "stop_reason": "tool_use",
             "content": [{"type": "tool_use", "id": "toolu_pending", "name": pending[0], "input": pending[1]}]}})
    lines.append(json.dumps({"type": "ai-title", "sessionId": sid, "aiTitle": title}))
    f = os.path.join(H, ".claude", "projects", key(folder), sid + ".jsonl")
    write(f, "\n".join(lines) + "\n")
    m = time.time() - ago; os.utime(f, (m, m))
    return sid

ids = {
  "tax": chat(web, "Fix checkout tax rounding", "claude-vscode", [
    ("user", "Customers say the tax on the receipt is a cent off the order total. Fix the rounding in checkout and add tests."),
    ("tool", ("Read", {"file_path": web + "/src/checkout/tax.ts"}, "export function lineTax(price, rate) { return price * rate; } ...", False)),
    ("assistant", "Found it: `lineTax` never rounds, so three lines of $19.99 at 8.25% add up to **4.947** instead of **4.95** on the receipt. I'll round each line to cents (half up) and the order total too."),
    ("tool", ("Edit", {"file_path": web + "/src/checkout/tax.ts"}, "The file was updated.", False)),
    ("tool", ("Write", {"file_path": web + "/src/checkout/tax.test.ts"}, "File created.", False)),
    ("tool", ("Bash", {"command": "npm test -- tax"}, "PASS src/checkout/tax.test.ts\n  ✓ rounds each line to cents\n  ✓ order total matches the receipt\nTests: 2 passed", False)),
    ("assistant", "Fixed.\n\n- `lineTax` now rounds each line to cents, half up.\n- `orderTax` rounds the total, so it always matches the receipt.\n- Two new tests cover the case from the bug report; both pass.\n\nThe change is in `src/checkout/tax.ts`."),
  ], ago=40),
  "dark": chat(web, "Add a dark mode toggle", "claude-vscode", [
    ("user", "Add a dark mode toggle to the header, remembered per user."),
    ("tool", ("Grep", {"pattern": "ThemeProvider"}, "src/app/layout.tsx:12", False)),
    ("assistant", "There's already a ThemeProvider in `layout.tsx`. I'll add the toggle and store the choice in the user's profile."),
  ], ago=20, pending=("Bash", {"command": "npm install @acme/theme-switch"})),
  "mig": chat(api, "Migrate users table to UUID keys", "cli", [
    ("user", "Plan the migration of users.id from integer to UUID without downtime."),
    ("assistant", "Here's a zero-downtime plan in four steps:\n\n1. Add a nullable `uuid` column and backfill it in batches.\n2. Write both keys from the app.\n3. Switch reads and foreign keys to `uuid`.\n4. Drop the old column after a week.\n\nWant me to write step 1 as a migration?"),
  ], ago=900),
  "crash": chat(mob, "Crash on Android 14 at launch", "claude-vscode", [
    ("user", "The app crashes on Android 14 right after the splash screen. Logs attached."),
    ("tool", ("Read", {"file_path": mob + "/logs/crash.txt"}, "java.lang.SecurityException: RECEIVER_EXPORTED or RECEIVER_NOT_EXPORTED should be specified", False)),
    ("assistant", "Android 14 requires every runtime broadcast receiver to say whether it's exported. `PushReceiver` doesn't, so registration throws at launch. I added `RECEIVER_NOT_EXPORTED` and the app now starts on the Android 14 emulator."),
  ], ago=3600),
  "notes": chat(docs, "Release notes for v2.3", "sdk-ts", [
    ("user", "Draft release notes for v2.3 from the merged pull requests."),
    ("assistant", "**v2.3**\n\n- Faster checkout: tax is calculated once per order.\n- Dark mode follows your system setting.\n- Fixed a crash on Android 14 at launch."),
  ], ago=7200),
  "search": chat(api, "Speed up product search", "claude-vscode", [
    ("user", "Product search takes 2 seconds. Make it fast."),
    ("tool", ("Bash", {"command": "psql -c 'EXPLAIN ANALYZE ...'"}, "Seq Scan on products (cost=0.00..48211.00) actual time=1874 ms", False)),
    ("assistant", "Search scans every row. A trigram index on `name` brings it to 18 ms in my test. The migration is ready for review."),
  ], ago=600),
}
write(os.path.join(H, "ids.json"), json.dumps(ids))
print(H)
