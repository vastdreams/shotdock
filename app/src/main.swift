// ShotDock entry point. Sources: Shared, Picker, Composer, Sender, App. Build: ../build.sh
import Cocoa

// --dry-run "<workspace>": print the folder, session and link that a send would use, then exit.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--dry-run" {
    let ws = CommandLine.arguments[2]
    let folder = Sender.folder(for: ws)
    let session = folder.flatMap(Sender.session(for:))
    print("folder:", folder ?? "-", "\nsession:", session ?? "-")
    print("link:", Sender.link(session: session, prompt: Sender.prompt(image: URL(fileURLWithPath: "/tmp/x.png"), text: "hello"))?.absoluteString ?? "-")
    exit(0)
}

// --deliver "<workspace>" "<text>": run one real delivery through Sender and print the outcome.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--deliver" {
    let ws = CommandLine.arguments[2]
    let sem = DispatchSemaphore(value: 0)
    Sender.deliver(image: nil, text: CommandLine.arguments[3], to: CursorWindow(id: 0, workspace: ws, onScreen: false),
                   pressReturn: true) { sent, problem in print("sent:", sent, problem ?? "ok"); sem.signal() }
    while sem.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// --hub-send <session> "<text>" / --cursor-send <session> "<text>": run one real hub send and print the outcome.
if CommandLine.arguments.count > 3, ["--hub-send", "--cursor-send"].contains(CommandLine.arguments[1]) {
    let id = CommandLine.arguments[2], text = CommandLine.arguments[3]
    guard let chat = ChatStore.list().first(where: { $0.session == id }) else { print("no such chat"); exit(1) }
    let sem = DispatchSemaphore(value: 0)
    let report: (String) -> Void = { print("result:", $0); sem.signal() }
    if CommandLine.arguments[1] == "--cursor-send" { Sender.sendToCursorAgent(chat, text: text, attachments: [], done: report) }
    else { Sender.sendToChat(chat, text: text, attachments: [], done: report) }
    while sem.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// --selftest: checks that need no clicks. Exit code 0 when everything passes.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest" {
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "PASS" : "FAIL", name, detail)
        if !ok { failed += 1 }
    }
    let chats = ChatStore.list()
    check("chat list finds chats", !chats.isEmpty, "\(chats.count) chats")
    check("chat list has Claude Code chats", chats.contains { $0.client == "Claude Code" })
    let cursor = chats.filter { $0.client == "Cursor" }
    check("Cursor chats get Cursor's names", cursor.isEmpty || cursor.contains { $0.title != "Cursor chat" }, "\(cursor.count) Cursor chats")
    let sized = chats.filter { $0.client == "Claude Code" }.max {
        ((try? FileManager.default.attributesOfItem(atPath: $0.file.path))?[.size] as? UInt64 ?? 0) <
        ((try? FileManager.default.attributesOfItem(atPath: $1.file.path))?[.size] as? UInt64 ?? 0)
    }
    if let c = sized {
        let t = ChatStore.transcript(c).string
        check("transcript renders", t.contains("CLAUDE") || t.contains("YOU"), "\(t.count) chars")
        check("chat state is known", ["working", "stalled", "waiting"].contains(c.state), c.state)
    }
    let md = markdown("**Bold** and `code`\n| a | b |\n|---|---|\n| 1 | 22 |", size: 12, color: .white).string
    check("markdown strips bold marks", !md.contains("**"))
    check("markdown table aligned, rule dropped", md.contains("a  b") && !md.contains("---"), md.replacingOccurrences(of: "\n", with: " / "))
    check("Cursor windows readable", true, cursorWindows().map(\.workspace).joined(separator: ", "))
    check("Claude link built", Sender.link(session: "abc", prompt: nil)?.absoluteString == "cursor://anthropic.claude-code/open?session=abc")
    check("never targets a closed window", !cursorWindows().contains { $0.workspace == "no-such-folder-xyz" })
    print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

// --fix <keybinding|cursor-a11y|hook>: apply one checklist fix (backup kept), then print the checklist.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--fix" {
    switch CommandLine.arguments[2] {
    case "keybinding": Setup.addKeybinding()
    case "cursor-a11y": Setup.setCursorA11yOff()
    case "hook": Setup.addHook()
    default: print("unknown fix; use keybinding, cursor-a11y or hook"); exit(2)
    }
    print(Setup.report().0)
    exit(0)
}

// --doctor: print the setup checklist (people and agents). Exit 0 when the required steps are done.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--doctor" {
    let (text, ready) = Setup.report()
    print(text)
    exit(ready ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
