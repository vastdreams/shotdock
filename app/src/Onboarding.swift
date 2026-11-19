// Setup checklist: everything ShotDock needs, each with its state and a Fix button.
// Shown on first run and from ⋯ → Setup checklist. `ShotDock --doctor` prints the same checks for people and agents.

import ApplicationServices
import Cocoa

struct SetupItem {
    let id: String
    let title: String
    let ok: Bool
    let detail: String
    let fixTitle: String?
    let fix: (() -> Void)?
}

enum Setup {
    static let cursorKeybindings = home.appendingPathComponent("Library/Application Support/Cursor/User/keybindings.json")
    static let cursorSettings = home.appendingPathComponent("Library/Application Support/Cursor/User/settings.json")
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    static let hookFile = home.appendingPathComponent(".claude/hooks/attach_screenshots.py")

    static func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    static var launcherRunning: Bool {
        let me = Bundle.main.bundleIdentifier ?? "com.fseresearch.shotdock"
        return !NSRunningApplication.runningApplications(withBundleIdentifier: me + ".launcher").isEmpty
    }

    static func items() -> [SetupItem] {
        // Ask the launcher (it holds the permissions). Its answer is in permissions.json, refreshed every 5 seconds.
        // Inside the app (a child of the launcher) the direct check is also right; from a terminal it is not.
        let perm = (try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/ShotDock/permissions.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let fresh = ((perm?["ts"] as? Double) ?? 0) > Date().timeIntervalSince1970 - 30
        let insideApp = ProcessInfo.processInfo.arguments.count == 1
        let screen = insideApp ? CGPreflightScreenCaptureAccess() : (fresh && (perm?["screen"] as? Bool ?? false))
        let ax = insideApp ? AXIsProcessTrusted() : (fresh && (perm?["accessibility"] as? Bool ?? false))
        let key = ["deepseek", "anthropic", "openai"].contains { Keys.get($0) != nil }
        let kb = (try? String(contentsOf: cursorKeybindings, encoding: .utf8))?.contains("claude-vscode.focus") ?? false
        let a11yOff = (try? String(contentsOf: cursorSettings, encoding: .utf8))
            .map { $0.range(of: #""editor\.accessibilitySupport"\s*:\s*"off""#, options: .regularExpression) != nil } ?? false
        let hook = (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains("attach_screenshots.py") ?? false
        return [
            SetupItem(id: "launcher", title: "ShotDock Launcher is running", ok: launcherRunning,
                      detail: "It holds the permissions and keeps ShotDock running after restarts.",
                      fixTitle: "Start it", fix: { NSWorkspace.shared.open(home.appendingPathComponent("Applications/ShotDock Launcher.app")) }),
            SetupItem(id: "screen", title: "Screen Recording allowed", ok: screen,
                      detail: "Turn on \"ShotDock Launcher\" in the list, then quit and reopen the launcher when macOS asks. (Checked by the launcher; start it first.)",
                      fixTitle: "Open settings", fix: { _ = CGRequestScreenCaptureAccess(); openPane("Privacy_ScreenCapture") }),
            SetupItem(id: "accessibility", title: "Accessibility allowed", ok: ax,
                      detail: "Turn on \"ShotDock Launcher\". Needed to read elements and paste into chat boxes.",
                      fixTitle: "Open settings", fix: {
                          _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                          openPane("Privacy_Accessibility") }),
            SetupItem(id: "apikey", title: "A model key is saved (optional)", ok: key,
                      detail: "Only for claim checks. DeepSeek is cheapest. Stored in your Keychain.",
                      fixTitle: "Add key", fix: { (NSApp.delegate as? AppDelegate)?.showSettings() }),
            SetupItem(id: "keybinding", title: "Cursor shortcut for Claude's chat box", ok: kb,
                      detail: "Adds Ctrl+Opt+Cmd+C → \"Claude Code: Focus input\" to Cursor (a backup is kept).",
                      fixTitle: "Add it", fix: { addKeybinding() }),
            SetupItem(id: "cursor-a11y", title: "Cursor stays out of screen-reader mode", ok: a11yOff,
                      detail: "Reading Cursor's elements can switch it to screen-reader mode; this setting prevents that.",
                      fixTitle: "Set it", fix: { setCursorA11yOff() }),
            SetupItem(id: "hook", title: "Normal screenshots reach Claude (optional)", ok: hook,
                      detail: "Cmd+Shift+4 shots in ~/Screenshots go to Claude with your next message.",
                      fixTitle: "Add hook", fix: { addHook() }),
        ]
    }

    // MARK: fixes (each keeps a backup of the file it changes)

    static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("shotdock-backup-\(stamp)"))
    }

    static func addKeybinding() {
        backup(cursorKeybindings)
        var text = (try? String(contentsOf: cursorKeybindings, encoding: .utf8)) ?? "[\n]"
        guard !text.contains("claude-vscode.focus"), let i = text.firstIndex(of: "[") else { return }
        let entry = "\n    { \"key\": \"ctrl+alt+cmd+c\", \"command\": \"claude-vscode.focus\" },"
        let after = text[text.index(after: i)...].trimmingCharacters(in: .whitespacesAndNewlines)
        text.insert(contentsOf: after.hasPrefix("]") ? String(entry.dropLast()) : entry, at: text.index(after: i))
        try? FileManager.default.createDirectory(at: cursorKeybindings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: cursorKeybindings, atomically: true, encoding: .utf8)
    }

    static func setCursorA11yOff() {
        backup(cursorSettings)
        var text = (try? String(contentsOf: cursorSettings, encoding: .utf8)) ?? "{\n}"
        // Already set to something else ("on", "auto"): change the value in place.
        if let r = text.range(of: #""editor\.accessibilitySupport"\s*:\s*"[a-z]*""#, options: .regularExpression) {
            text.replaceSubrange(r, with: "\"editor.accessibilitySupport\": \"off\"")
            try? text.write(to: cursorSettings, atomically: true, encoding: .utf8)
            return
        }
        guard let i = text.firstIndex(of: "{") else { return }
        let after = text[text.index(after: i)...].trimmingCharacters(in: .whitespacesAndNewlines)
        text.insert(contentsOf: "\n    \"editor.accessibilitySupport\": \"off\"" + (after.hasPrefix("}") ? "" : ","), at: text.index(after: i))
        try? text.write(to: cursorSettings, atomically: true, encoding: .utf8)
    }

    static func addHook() {
        backup(claudeSettings)
        var d = (try? Data(contentsOf: claudeSettings)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var hooks = d["hooks"] as? [String: Any] ?? [:]
        var list = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        let cmd = "python3 \(hookFile.path)"
        guard !list.contains(where: { ($0["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == cmd } }) else { return }
        list.append(["hooks": [["type": "command", "command": cmd, "timeout": 5]]])
        hooks["UserPromptSubmit"] = list
        d["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: claudeSettings)
        }
    }

    /// Text report for `--doctor`: one line per check, then a JSON line for agents.
    static func report() -> (String, Bool) {
        let list = items()
        let required = ["launcher", "screen", "accessibility", "keybinding", "cursor-a11y"]
        var lines = list.map { "\($0.ok ? "OK  " : "TODO") \($0.title)\($0.ok ? "" : "  ->  \($0.detail)")" }
        let ready = list.filter { required.contains($0.id) }.allSatisfy(\.ok)
        let json = (try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.ok) }))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        lines.append(ready ? "READY" : "NOT READY")
        lines.append("JSON \(json)")
        return (lines.joined(separator: "\n"), ready)
    }
}

/// The checklist window. Refreshes every two seconds so a toggle in System Settings shows up straight away.
final class SetupPanel: NSObject {
    let window: NSPanel
    private var timer: Timer?

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set up ShotDock"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { self?.timer?.invalidate(); return }
            self.render()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "SetupShown")
    }

    private var fixes: [() -> Void] = []

    private func render() {
        let v = NSView(frame: window.contentView!.bounds)
        let items = Setup.items()
        fixes = []
        var y: CGFloat = 430
        let head = NSTextField(labelWithString: "A few one-time steps. Each turns green when done.")
        head.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        head.frame = NSRect(x: 20, y: y, width: 560, height: 20)
        v.addSubview(head)
        y -= 14
        for item in items {
            y -= 54
            let mark = NSTextField(labelWithString: item.ok ? "✓" : "○")
            mark.font = NSFont.systemFont(ofSize: 18, weight: .bold)
            mark.textColor = item.ok ? .systemGreen : .secondaryLabelColor
            mark.frame = NSRect(x: 20, y: y + 22, width: 24, height: 24)
            v.addSubview(mark)
            let t = NSTextField(labelWithString: item.title)
            t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            t.frame = NSRect(x: 50, y: y + 26, width: 400, height: 18)
            v.addSubview(t)
            let d = NSTextField(wrappingLabelWithString: item.detail)
            d.font = NSFont.systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.frame = NSRect(x: 50, y: y, width: 410, height: 26)
            v.addSubview(d)
            if !item.ok, let title = item.fixTitle, let fix = item.fix {
                let b = NSButton(title: title, target: self, action: #selector(fixTapped(_:)))
                b.bezelStyle = .rounded
                b.tag = fixes.count
                fixes.append(fix)
                b.frame = NSRect(x: 470, y: y + 18, width: 110, height: 26)
                v.addSubview(b)
            }
        }
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.frame = NSRect(x: 490, y: 12, width: 90, height: 28)
        v.addSubview(done)
        window.contentView = v
    }

    @objc private func fixTapped(_ b: NSButton) { if fixes.indices.contains(b.tag) { fixes[b.tag]() }; render() }
    @objc private func close() { window.orderOut(nil); timer?.invalidate() }
}
