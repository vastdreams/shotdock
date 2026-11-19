// Sender: bring the chosen Cursor workspace window forward, focus its Claude Code input, paste the image and the
// message, press Return. It checks focus is in a web view (the Claude panel), never a code editor, before pasting.
// Cursor keybinding Ctrl+Opt+Cmd+C runs claude-vscode.focus (added to Cursor's keybindings.json on 19 Nov 2026).

import Cocoa

let shotLog = home.appendingPathComponent(".claude/state/shotdock.log")

func slog(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: shotLog) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: shotLog, atomically: true, encoding: .utf8) }
}

enum Sender {
    static let cursorCLI = "/usr/local/bin/cursor"

    /// Folder path for a workspace name, from Cursor's workspaceStorage (newest match wins).
    static func folder(for workspace: String) -> String? {
        let root = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var best: (String, Date)?
        for d in dirs {
            let json = d.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: json),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = obj["folder"] as? String, let url = URL(string: folder), url.isFileURL,
                  url.lastPathComponent == workspace else { continue }
            let m = (try? json.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || m > best!.1 { best = (url.path, m) }
        }
        if let found = best?.0 { return found }
        for base in projectRoots {
            let candidate = home.appendingPathComponent(base).appendingPathComponent(workspace)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate.path }
        }
        return nil
    }

    static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    static func frontWorkspace() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cursorBundle else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Cursor" && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let ws = workspaceName(fromTitle: w[kCGWindowName as String] as? String ?? "") { return ws }
        }
        return nil
    }

    /// True when keyboard focus is inside a nested web view (the Claude panel) and not a code editor.
    static func focusIsChatPanel() -> Bool {
        guard let f = axElement(axAttr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)) else { return false }
        let role = axAttr(f, kAXRoleAttribute) as? String ?? ""
        let desc = (axAttr(f, kAXDescriptionAttribute) as? String ?? "").lowercased()
        let title = axAttr(f, kAXTitleAttribute) as? String ?? ""
        if desc.contains("editor") { return false }
        if role == "AXWebArea" { return title.isEmpty }   // the window's own web area carries the window title
        if role == "AXTextArea" || role == "AXTextField" {
            let ph = (axAttr(f, "AXPlaceholderValue") as? String ?? "").lowercased()
            return ph.contains("claude") || ph.contains("message") || ph.contains("queue") || ph.isEmpty
        }
        return false
    }

    /// The Claude Code session a workspace is using: the newest transcript in ~/.claude/projects/<folder key>.
    static func session(for folder: String) -> String? {
        let key = String(folder.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let dir = home.appendingPathComponent(".claude/projects/\(key)")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "jsonl" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        return newest?.deletingPathExtension().lastPathComponent
    }

    static func prompt(image: URL?, text: String) -> String {
        guard let image else { return text }
        return text.isEmpty ? "Screenshot: \(image.path)" : "\(text)\n\nScreenshot: \(image.path)"
    }

    /// cursor://anthropic.claude-code/open?session=<id>&prompt=<text> opens that chat with the prompt filled in.
    static func link(session: String?, prompt: String?) -> URL? {
        var c = URLComponents()
        c.scheme = "cursor"
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = (session.map { [URLQueryItem(name: "session", value: $0)] } ?? []) + (prompt.map { [URLQueryItem(name: "prompt", value: $0)] } ?? [])
        return c.url
    }

    /// Runs off the main thread. Calls back on the main thread with (sent, problem).
    static func deliver(image: URL?, text: String, to target: CursorWindow, pressReturn: Bool,
                        folderPath: String? = nil, sessionID: String? = nil, openOnly: Bool = false, reveal: Bool = false,
                        done: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ sent: Bool, _ why: String?) {
                slog("deliver \(target.workspace): sent=\(sent) \(why ?? "ok")")
                DispatchQueue.main.async { done(sent, why) }
            }
            slog("deliver \(target.workspace): start (front=\(frontWorkspace() ?? "-"), openOnly=\(openOnly))")
            guard let path = folderPath ?? folder(for: target.workspace) else {
                return finish(false, "Could not find the folder for \(target.workspace).")
            }
            if let c = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundle).first { _ = axApp(c.processIdentifier) }

            // 1. Bring the workspace window forward (switches to its Space), so the link lands in that window.
            // Only ever target a window that is already open in Cursor; never open a new one.
            guard cursorWindows().contains(where: { $0.workspace == target.workspace }) else {
                return finish(false, "No open Cursor window for \(target.workspace). Nothing was sent.")
            }
            if frontWorkspace() != target.workspace {
                let p = Process()   // `open -a` activates Cursor and switches to that folder's window and Space
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", "Cursor", path]
                try? p.run()
                p.waitUntilExit()
                for _ in 0..<20 where frontWorkspace() != target.workspace { usleep(150_000) }
                usleep(400_000)
            }
            guard frontWorkspace() == target.workspace else {
                return finish(false, "Could not bring \(target.workspace) to the front.")
            }

            // 2. Bring the right chat forward. The link carries no prompt: Claude Code ignores prompts for a chat
            //    that is already open, so the text is pasted into the input instead.
            if openOnly || reveal, let url = link(session: sessionID ?? session(for: path), prompt: nil) {
                slog("deliver \(target.workspace): revealing \(url.absoluteString.prefix(110))")
                DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                usleep(1_200_000)
            }
            guard !openOnly else { return finish(false, nil) }

            // 3. Focus Claude's input and make sure it is that box and that it is empty (never send a draft).
            // A notice from the reveal can take focus first, so try the focus shortcut up to three times.
            var f: AXUIElement?
            var role = "-"
            var desc = ""
            for _ in 0..<3 {
                key(8, [.maskControl, .maskAlternate, .maskCommand])   // Ctrl+Opt+Cmd+C, claude-vscode.focus
                usleep(600_000)
                f = axElement(axAttr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute))
                role = f.flatMap { axAttr($0, kAXRoleAttribute) as? String } ?? "-"
                desc = f.flatMap { axAttr($0, kAXDescriptionAttribute) as? String }?.lowercased() ?? ""
                if role == "AXTextArea" && desc.contains("message input") { break }
            }
            let current = (f.flatMap { axAttr($0, kAXValueAttribute) as? String } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            slog("deliver \(target.workspace): focus role=\(role) desc=\(desc) chars=\(current.count) front=\(frontWorkspace() ?? "-")")
            guard frontWorkspace() == target.workspace, role == "AXTextArea", desc.contains("message input") else {
                return finish(false, "Could not reach Claude's message box in \(target.workspace). Nothing was sent.")
            }
            guard current.isEmpty else {
                return finish(false, "Claude's box in \(target.workspace) has a draft in it. Nothing was sent.")
            }

            // 4. Paste the message, check it landed, send.
            let message = prompt(image: image, text: text)
            DispatchQueue.main.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
            key(9, .maskCommand)
            usleep(400_000)
            let after = (f.flatMap { axAttr($0, kAXValueAttribute) as? String } ?? "")
            guard after.contains(String(message.prefix(20))) else {
                return finish(false, "The paste did not land in Claude's box in \(target.workspace). Nothing was sent.")
            }
            guard pressReturn else { return finish(false, nil) }
            key(36)
            finish(true, nil)
        }
    }
}


/// True once a user line containing `marker` appears in the session transcript after `since`.
func transcriptHas(session: String, folder: String, marker: String, since: Date) -> Bool {
    let key = String(folder.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let file = home.appendingPathComponent(".claude/projects/\(key)/\(session).jsonl")
    guard let h = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? h.close() }
    let end = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: end > 400_000 ? end - 400_000 : 0)
    guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for line in text.split(separator: "\n").reversed() where line.contains(marker) && line.contains("\"type\":\"user\"") {
        if let r = line.range(of: "\"timestamp\":\""), let t = line[r.upperBound...].split(separator: "\"").first,
           let d = stamp.date(from: String(t)), d >= since.addingTimeInterval(-5) { return true }
    }
    return false
}

extension Sender {
    /// Put a screenshot (and optional element details) into Claude's chat box in `target`, after anything already
    /// typed there. Never presses Return: the operator adds words and sends.
    static func attach(image: URL, more: [URL] = [], details: String?, to target: CursorWindow, sessionID: String? = nil,
                       done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ why: String?) {
                slog("attach \(target.workspace): \(why ?? "ok")")
                DispatchQueue.main.async { done(why) }
            }
            guard let path = folder(for: target.workspace),
                  cursorWindows().contains(where: { $0.workspace == target.workspace }) else {
                return finish("No open Cursor window for \(target.workspace).")
            }
            if let c = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundle).first { _ = axApp(c.processIdentifier) }
            if frontWorkspace() != target.workspace { bringForward(folder: path, workspace: target.workspace) }
            // Several chats can share a window: bring this exact chat up first.
            if let sid = sessionID, let url = link(session: sid, prompt: nil) {
                DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                usleep(1_200_000)
            }
            var ok = false
            for _ in 0..<4 {
                key(8, [.maskControl, .maskAlternate, .maskCommand])   // Ctrl+Opt+Cmd+C, claude-vscode.focus
                usleep(500_000)
                let f = axElement(axAttr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute))
                let role = f.flatMap { axAttr($0, kAXRoleAttribute) as? String } ?? ""
                let desc = f.flatMap { axAttr($0, kAXDescriptionAttribute) as? String }?.lowercased() ?? ""
                if role == "AXTextArea" && desc.contains("message input") { ok = true; break }
            }
            guard ok, frontWorkspace() == target.workspace else {
                return finish("Could not reach Claude's chat box in \(target.workspace).")
            }
            key(125, .maskCommand)   // Cmd+Down: end of whatever is typed
            for shot in [image] + more {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    if let img = NSImage(contentsOf: shot) { NSPasteboard.general.writeObjects([img]) }
                }
                key(9, .maskCommand)
                usleep(700_000)
            }
            if let details, !details.isEmpty {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\n" + details + "\n", forType: .string)
                }
                key(9, .maskCommand)
                usleep(200_000)
            }
            finish(nil)
        }
    }
}

extension Sender {
    /// Send a message composed in the hub into one exact chat: bring that chat up, check its box is empty, paste each
    /// screenshot, paste the text (with element details), press Return, then confirm it shows in the transcript.
    static func sendToChat(_ chat: ChatInfo, text: String, attachments: [(URL, String?)], done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let previous = NSWorkspace.shared.frontmostApplication
            var stashed = ""
            func goBack() {
                if let p = previous, p.bundleIdentifier != Bundle.main.bundleIdentifier { usleep(300_000); p.activate() }
            }
            func finish(_ s: String) {
                slog("hub send \(chat.workspace)/\(chat.session.prefix(8)): \(s)")
                if !stashed.isEmpty {   // put the operator's draft back in the box
                    DispatchQueue.main.sync {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(stashed, forType: .string)
                    }
                    usleep(600_000)
                    key(8, [.maskControl, .maskAlternate, .maskCommand])
                    usleep(400_000)
                    key(9, .maskCommand)
                    usleep(200_000)
                }
                goBack()
                DispatchQueue.main.async { done(s) }
            }
            let target = chat.workspace
            guard cursorWindows().contains(where: { $0.workspace == target }) else {
                return finish("No open Cursor window for \(target). Nothing was sent.")
            }
            if let c = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundle).first { _ = axApp(c.processIdentifier) }
            if frontWorkspace() != target {
                bringForward(folder: chat.folder, workspace: target)
            }
            // Only switch chats inside the window when it holds more than one recent Claude chat: the link moves
            // focus away from the chat box, so it is skipped in the usual one-chat case.
            let siblings = ChatStore.list().filter { $0.client == "Claude Code" && $0.folder == chat.folder &&
                                                     $0.modified > Date().addingTimeInterval(-12 * 3600) }
            if siblings.count > 1, let url = link(session: chat.session, prompt: nil) {
                DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                usleep(1_500_000)
            }
            var f: AXUIElement?
            // Prefer focusing Claude's chat box directly when exactly one is visible in the front window.
            if let cur = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundle).first,
               let win = axElement(axAttr(axApp(cur.processIdentifier), kAXFocusedWindowAttribute)) {
                var boxes: [AXUIElement] = []
                var queue = [win]
                var seen = 0
                while !queue.isEmpty && seen < 15000 {
                    let e = queue.removeFirst(); seen += 1
                    if (axAttr(e, kAXRoleAttribute) as? String) == "AXTextArea",
                       ((axAttr(e, kAXDescriptionAttribute) as? String) ?? "").lowercased().contains("message input") { boxes.append(e) }
                    queue += axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
                slog("hub send: \(boxes.count) Claude chat box(es) in the front window")
                if boxes.count == 1 {
                    AXUIElementSetAttributeValue(boxes[0], kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    usleep(300_000)
                }
            }
            for _ in 0..<4 {
                key(8, [.maskControl, .maskAlternate, .maskCommand])
                usleep(500_000)
                f = axElement(axAttr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute))
                let role = f.flatMap { axAttr($0, kAXRoleAttribute) as? String } ?? ""
                let desc = f.flatMap { axAttr($0, kAXDescriptionAttribute) as? String }?.lowercased() ?? ""
                slog("hub send focus try: role=\(role) desc=\(desc) front=\(frontWorkspace() ?? "-")")
                if role == "AXTextArea" && desc.contains("message input") { break }
                f = nil
            }
            guard let box = f, frontWorkspace() == target else { return finish("Could not reach that chat's box in \(target). Nothing was sent.") }
            let draft = (axAttr(box, kAXValueAttribute) as? String ?? "")
            // Never touch a box with text in it: you may be typing there.
            guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return finish("You have text in that chat's box in Cursor. Send or clear it, then send again. Nothing was sent.")
            }
            for (url, _) in attachments {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    if let img = NSImage(contentsOf: url) { NSPasteboard.general.writeObjects([img]) }
                }
                key(9, .maskCommand)
                usleep(800_000)
            }
            let details = attachments.compactMap { $0.1 }.joined(separator: "\n\n")
            let message = [text, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !message.isEmpty {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                key(9, .maskCommand)
                usleep(400_000)
            }
            let started = Date()
            key(36)
            let marker = text.isEmpty ? "\"type\":\"image\"" : String(text.prefix(24))
            for _ in 0..<10 {
                usleep(1_500_000)
                if transcriptHas(session: chat.session, folder: chat.folder, marker: marker, since: started) {
                    return finish("Delivered to \(chat.title).")
                }
            }
            finish("Sent, but not seen in \(chat.title) yet. Check the chat.")
        }
    }
}


extension Sender {
    /// Breadth-first search of a window's accessibility tree.
    static func axFind(_ root: AXUIElement, limit: Int = 12000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty && seen < limit {
            let e = queue.removeFirst()
            seen += 1
            if match(e) { return e }
            queue += axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return nil
    }

    /// Send into a Cursor agent chat: open it by name in Cursor's agent list, paste into its empty Prompt box,
    /// press Return, and confirm the message landed in that chat's transcript.
    static func sendToCursorAgent(_ chat: ChatInfo, text: String, attachments: [(URL, String?)], done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let previous = NSWorkspace.shared.frontmostApplication
            func finish(_ s: String) {
                slog("cursor send \(chat.session.prefix(8)): \(s)")
                if let p = previous, p.bundleIdentifier != Bundle.main.bundleIdentifier { usleep(300_000); p.activate() }
                DispatchQueue.main.async { done(s) }
            }
            guard let cursor = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundle).first else {
                return finish("Cursor is not running.")
            }
            let app = axApp(cursor.processIdentifier)
            cursor.activate()
            usleep(500_000)
            let windows = axAttr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let name = chat.title
            var row: AXUIElement?
            var win: AXUIElement?
            for w in windows {
                row = axFind(w) { e in
                    for a in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                        if let s = axAttr(e, a) as? String, s == name { return true }
                    }
                    return false
                }
                if row != nil { win = w; break }
            }
            guard let r = row, let w = win else {
                return finish("Could not find \"\(name)\" in an open Cursor window. Open the Cursor Agents window and try again.")
            }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            var pressTarget: AXUIElement? = r
            for _ in 0..<5 {   // the row itself, or the first parent that accepts a press
                guard let t = pressTarget else { break }
                if AXUIElementPerformAction(t, kAXPressAction as CFString) == .success { break }
                pressTarget = axElement(axAttr(t, kAXParentAttribute))
            }
            usleep(900_000)
            guard let box = axFind(w, { e in
                (axAttr(e, kAXRoleAttribute) as? String) == "AXTextArea" &&
                    ((axAttr(e, kAXDescriptionAttribute) as? String) == "Prompt")
            }) else { return finish("Could not find the Prompt box in that Cursor window. Nothing was sent.") }
            let draft = (axAttr(box, kAXValueAttribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard draft.isEmpty else { return finish("That Cursor chat's Prompt box has a draft in it. Nothing was sent.") }
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(300_000)
            let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: chat.file.path))?[.size] as? UInt64 ?? 0
            for (url, _) in attachments {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    if let img = NSImage(contentsOf: url) { NSPasteboard.general.writeObjects([img]) }
                }
                key(9, .maskCommand)
                usleep(800_000)
            }
            let details = attachments.compactMap { $0.1 }.joined(separator: "\n\n")
            let message = [text, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !message.isEmpty {
                DispatchQueue.main.sync {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                key(9, .maskCommand)
                usleep(400_000)
            }
            key(36)
            for _ in 0..<12 {
                usleep(1_500_000)
                let size = (try? FileManager.default.attributesOfItem(atPath: chat.file.path))?[.size] as? UInt64 ?? 0
                if size > sizeBefore { return finish("Delivered to \(name).") }
            }
            finish("Sent, but \(name) did not change yet. Check that chat in Cursor.")
        }
    }
}


extension Sender {
    /// Make that folder's Cursor window the front window, across full-screen Spaces: `cursor <folder>` makes it
    /// Cursor's current window, `open -a Cursor` then activates Cursor, which switches to that window's Space.
    static func bringForward(folder: String, workspace: String) {
        for attempt in 0..<2 where frontWorkspace() != workspace {
            let cli = Process()
            cli.executableURL = URL(fileURLWithPath: cursorCLI)
            cli.arguments = attempt == 0 ? [folder] : ["-r", folder]
            try? cli.run()
            cli.waitUntilExit()
            usleep(400_000)
            let act = Process()
            act.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            act.arguments = ["-a", "Cursor"]
            try? act.run()
            act.waitUntilExit()
            for _ in 0..<20 where frontWorkspace() != workspace { usleep(150_000) }
        }
        usleep(300_000)
        slog("bringForward \(workspace): front=\(frontWorkspace() ?? "-")")
    }
}
