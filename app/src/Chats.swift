// Chats: every Claude Code chat on this Mac, grouped by folder like Cursor's list. Pick one to read it here
// (refreshes while open) and reply from the box at the bottom. A reply goes through Sender into that chat in its
// Cursor window, and only when the chat box is empty.

import Cocoa

struct ChatInfo {
    let session: String
    let file: URL
    let folder: String
    let title: String
    let modified: Date
    /// "working" (mid-turn), "stalled" (mid-turn, silent 10 min), "waiting" (turn finished, your move)
    var state: String = "waiting"
    var client: String = "Claude Code"
    var workspace: String { (folder as NSString).lastPathComponent }
}

/// Light markdown: # headings and **bold** in bold, `code` in monospace. Enough to read replies, not a renderer.
func markdown(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let body = NSFont.systemFont(ofSize: size)
    let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
    let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
    let lines = text.components(separatedBy: "\n")
    // Markdown tables: |a|b| rows become aligned monospace columns; the |---| rule line is dropped.
    var widths: [Int: [Int]] = [:]   // table start index -> column widths
    var tableOf: [Int: Int] = [:]
    var i0 = 0
    while i0 < lines.count {
        if lines[i0].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            var j = i0
            var w: [Int] = []
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                let cells = lines[j].split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) {
                    for (k, c) in cells.enumerated() { if k < w.count { w[k] = max(w[k], min(c.count, 44)) } else { w.append(min(c.count, 44)) } }
                }
                tableOf[j] = i0
                j += 1
            }
            widths[i0] = w
            i0 = j
        } else { i0 += 1 }
    }
    for (i, raw) in lines.enumerated() {
        if let t = tableOf[i], let w = widths[t] {
            let cells = raw.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
            if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
            let row = cells.enumerated().map { k, c -> String in
                let cut = c.count > 44 ? String(c.prefix(43)) + "…" : c
                return cut.padding(toLength: k < w.count ? w[k] : cut.count, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: row, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: i == t ? .semibold : .regular),
                                                                    .foregroundColor: color]))
            continue
        }
        if i > 0 { out.append(NSAttributedString(string: "\n")) }
        var line = Substring(raw)
        var lineFont = body
        if line.hasPrefix("#") { line = line.drop { $0 == "#" }.drop { $0 == " " }; lineFont = bold }
        var rest = String(line)
        while !rest.isEmpty {
            let b = rest.range(of: "**"), c = rest.range(of: "`")
            let next = [b, c].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            guard let n = next else { out.append(NSAttributedString(string: rest, attributes: [.font: lineFont, .foregroundColor: color])); break }
            out.append(NSAttributedString(string: String(rest[..<n.lowerBound]), attributes: [.font: lineFont, .foregroundColor: color]))
            let marker = String(rest[n])
            let after = rest[n.upperBound...]
            if let close = after.range(of: marker) {
                let inner = String(after[..<close.lowerBound])
                out.append(NSAttributedString(string: inner, attributes: [.font: marker == "**" ? bold : mono,
                                                                         .foregroundColor: marker == "**" ? color : NSColor.systemTeal]))
                rest = String(after[close.upperBound...])
            } else {
                out.append(NSAttributedString(string: marker + after, attributes: [.font: lineFont, .foregroundColor: color]))
                break
            }
        }
    }
    return out
}

enum ChatStore {
    static let projects = home.appendingPathComponent(".claude/projects")

    private static func head(_ url: URL, _ n: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: n)) ?? Data(), as: UTF8.self)
    }

    private static func tail(_ url: URL, _ n: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > n ? end - n : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    /// Chats touched in the last 14 days, newest first.
    static func list() -> [ChatInfo] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        var out: [ChatInfo] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for d in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard m > cutoff else { continue }
                let start = head(f, 200_000)
                let folder = start.split(separator: "\n").lazy.compactMap { field($0, "cwd") }.first ?? d.lastPathComponent
                let end = tail(f, 300_000).split(separator: "\n")
                let title = end.reversed().lazy.compactMap { $0.contains("\"ai-title\"") ? field($0, "aiTitle") : nil }.first
                    ?? end.reversed().lazy.compactMap { $0.contains("\"last-prompt\"") ? field($0, "lastPrompt") : nil }.first
                    ?? "Untitled chat"
                var info = ChatInfo(session: f.deletingPathExtension().lastPathComponent, file: f, folder: folder,
                                    title: title, modified: m)
                info.state = state(end, modified: m)
                out.append(info)
            }
        }
        out += cursorChats(since: cutoff, knownFolders: Set(out.map(\.folder)))
        return out.sorted { $0.modified > $1.modified }
    }

    /// Cursor agent chats: ~/.cursor/projects/<key>/agent-transcripts/<id>/<id>.jsonl. Title = first request.
    static func cursorChats(since cutoff: Date, knownFolders: Set<String>) -> [ChatInfo] {
        let root = home.appendingPathComponent(".cursor/projects")
        func key(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        var byKey: [String: String] = [:]
        for f in knownFolders { byKey[key(f)] = f }
        for base in projectRoots {
            let dir = home.appendingPathComponent(base)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let p = dir.appendingPathComponent(name).path
                if byKey[key(p)] == nil { byKey[key(p)] = p }
            }
        }
        var out: [ChatInfo] = []
        for proj in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let tdir = proj.appendingPathComponent("agent-transcripts")
            for id in (try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? [] {
                let f = tdir.appendingPathComponent(id).appendingPathComponent("\(id).jsonl")
                guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m > cutoff else { continue }
                let first = head(f, 60_000)
                var title = "Cursor chat"
                if let r = first.range(of: "<user_query>"), let e = first.range(of: "</user_query>", range: r.upperBound..<first.endIndex) {
                    title = first[r.upperBound..<e.lowerBound].replacingOccurrences(of: "\\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let folder = byKey[proj.lastPathComponent] ?? proj.lastPathComponent
                var info = ChatInfo(session: id, file: f, folder: folder, title: String(title.prefix(80)), modified: m)
                info.client = "Cursor"
                info.state = Date().timeIntervalSince(m) < 90 ? "working" : "waiting"
                out.append(info)
            }
        }
        // Cursor's own names and live status for these chats (one read-only lookup in its global store).
        let meta = cursorMeta(out.map(\.session))
        for i in out.indices {
            guard let m = meta[out[i].session] else { continue }
            if !m.name.isEmpty { out[i] = ChatInfo(session: out[i].session, file: out[i].file, folder: out[i].folder, title: m.name,
                                                   modified: out[i].modified, state: out[i].state, client: "Cursor") }
            out[i].state = m.status == "generating" ? "working" : "waiting"
        }
        return out
    }

    /// composerData name and status from Cursor's global state database, read-only.
    static func cursorMeta(_ ids: [String]) -> [String: (name: String, status: String)] {
        let safe = ids.filter { $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
        guard !safe.isEmpty else { return [:] }
        let db = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        let keys = safe.map { "'composerData:\($0)'" }.joined(separator: ",")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-separator", "\t", "file:\(db)?mode=ro",
                       "select substr(key,14), ifnull(json_extract(value,'$.name'),''), ifnull(json_extract(value,'$.status'),'') from cursorDiskKV where key in (\(keys));"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [String: (String, String)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 3 { out[f[0]] = (f[1], f[2]) }
        }
        return out
    }

    static func cursorTranscript(_ chat: ChatInfo) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var items: [(String, NSColor, String)] = []
        for line in tail(chat.file, 900_000).split(separator: "\n") {
            guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = obj["role"] as? String, let msg = obj["message"] as? [String: Any] else { continue }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            var text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if role == "user" {
                if let r = text.range(of: "<user_query>"), let e = text.range(of: "</user_query>") , r.upperBound <= e.lowerBound {
                    text = String(text[r.upperBound..<e.lowerBound])
                } else { continue }
                items.append(("YOU", .systemTeal, text))
            } else if !text.isEmpty {
                items.append(("CURSOR AGENT", .systemPurple, text))
            }
        }
        for (who, color, text) in items.suffix(60) {
            out.append(NSAttributedString(string: "\(who)\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color]))
            out.append(markdown(text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12.5, color: NSColor.white.withAlphaComponent(0.88)))
            out.append(NSAttributedString(string: "\n\n"))
        }
        return out
    }

    /// Where a chat stands, from its last user or assistant line.
    static func state(_ lines: [Substring], modified: Date) -> String {
        for line in lines.reversed() {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") else { continue }
            if line.contains("\"isSidechain\":true") { continue }
            if line.contains("\"type\":\"assistant\"") && line.contains("\"stop_reason\":\"end_turn\"") { return "waiting" }
            return Date().timeIntervalSince(modified) > 600 ? "stalled" : "working"
        }
        return "waiting"
    }

    /// The last messages of a chat as styled text: what you asked, what Claude said, tools in grey.
    static func transcript(_ chat: ChatInfo) -> NSAttributedString {
        if chat.client == "Cursor" { return cursorTranscript(chat) }
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12.5)
        func add(_ who: String, _ color: NSColor, _ text: String) {
            out.append(NSAttributedString(string: "\(who)\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                                           .foregroundColor: color]))
            out.append(markdown(text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12.5, color: NSColor.white.withAlphaComponent(0.88)))
            out.append(NSAttributedString(string: "\n\n"))
        }
        var items: [(String, NSColor, String)] = []
        for line in tail(chat.file, 900_000).split(separator: "\n") {
            guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["isSidechain"] as? Bool != true, let msg = obj["message"] as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let content = msg["content"]
            if type == "user", obj["isMeta"] as? Bool != true {
                if let s = content as? String, !s.hasPrefix("<") { items.append(("YOU", .systemTeal, s)) }
                else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    let s = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !s.isEmpty, !s.hasPrefix("<") { items.append(("YOU", .systemTeal, s)) }
                }
            } else if type == "assistant", let blocks = content as? [[String: Any]] {
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.isEmpty {
                        items.append(("CLAUDE", .systemOrange, t))
                    } else if b["type"] as? String == "tool_use" {
                        let input = b["input"] as? [String: Any] ?? [:]
                        let what = input["description"] as? String ?? input["file_path"] as? String ?? ""
                        items.append(("", .gray, "· \(b["name"] as? String ?? "tool") \(what)"))
                    }
                }
            }
        }
        for (who, color, text) in items.suffix(80) {
            if who.isEmpty {
                out.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 10.5),
                                                                                 .foregroundColor: NSColor.gray]))
            } else {
                add(who, color, text)
            }
        }
        return out
    }
}

final class ChatsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ChatsPanel: NSObject, NSTextFieldDelegate {
    let window: ChatsPanelWindow
    /// Everything the pane draws; the Claude monitor embeds this view.
    let container = NSView()
    private let listScroll = NSScrollView()
    private let listStack = NSView()
    private let readerScroll = NSScrollView()
    private let reader = NSTextView()
    private let reply = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let backButton = NSButton(title: "‹ Chats", target: nil, action: nil)
    private let jumpButton = NSButton(title: "Open in Cursor", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "Chats")
    private var current: ChatInfo?
    private var lastSize: UInt64 = 0
    private var timer: Timer?
    var send: ((ChatInfo, String, @escaping (String) -> Void) -> Void)?
    var jump: ((ChatInfo) -> Void)?

    override init() {
        window = ChatsPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        super.init()
        window.title = "Claude chats"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 420)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !window.setFrameUsingName("ClaudeChats") { window.center() }
        window.setFrameAutosaveName("ClaudeChats")
        let root = container

        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        for b in [backButton, jumpButton, sendButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        backButton.action = #selector(back)
        jumpButton.action = #selector(jumpTapped)
        sendButton.action = #selector(sendTapped)
        sendButton.keyEquivalent = "\r"
        reply.placeholderString = "Reply to this chat. Return sends."
        reply.font = NSFont.systemFont(ofSize: 13)
        reply.delegate = self
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        listScroll.documentView = listStack
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        reader.isEditable = false
        reader.drawsBackground = false
        reader.textContainerInset = NSSize(width: 8, height: 8)
        reader.autoresizingMask = [.width]
        readerScroll.documentView = reader
        readerScroll.hasVerticalScroller = true
        readerScroll.drawsBackground = false
        for v in [heading, backButton, jumpButton, listScroll, readerScroll, reply, sendButton, status] as [NSView] {
            root.addSubview(v)
        }
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layout), name: NSView.frameDidChangeNotification, object: container)
    }

    /// Called when the monitor opens the pane: start on the list.
    func reset() { showList() }

    func toggle() {
        if window.isVisible { window.orderOut(nil); timer?.invalidate(); return }
        showList()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func layout() {
        let b = container.bounds
        guard b.width > 50 else { return }
        let top = b.height + 2
        let reading = current != nil
        backButton.isHidden = !reading
        jumpButton.isHidden = !reading
        backButton.frame = NSRect(x: 12, y: top - 26, width: 74, height: 24)
        jumpButton.frame = NSRect(x: b.width - 122, y: top - 26, width: 110, height: 24)
        heading.frame = NSRect(x: reading ? 92 : 14, y: top - 22, width: b.width - (reading ? 220 : 28), height: 18)
        listScroll.isHidden = reading
        readerScroll.isHidden = !reading
        reply.isHidden = !reading
        sendButton.isHidden = !reading
        status.isHidden = !reading
        listScroll.frame = NSRect(x: 8, y: 8, width: b.width - 16, height: top - 40)
        readerScroll.frame = NSRect(x: 8, y: 76, width: b.width - 16, height: top - 108)
        reader.frame.size.width = readerScroll.contentSize.width
        reply.frame = NSRect(x: 12, y: 36, width: b.width - 96, height: 28)
        sendButton.frame = NSRect(x: b.width - 78, y: 38, width: 66, height: 24)
        status.frame = NSRect(x: 14, y: 12, width: b.width - 28, height: 16)
        if !reading { buildList() }
    }

    private func showList() {
        current = nil
        timer?.invalidate()
        heading.stringValue = "Chats"
        layout()
    }

    private func buildList() {
        listStack.subviews.forEach { $0.removeFromSuperview() }
        let chats = ChatStore.list()
        let width = listScroll.contentSize.width
        var y: CGFloat = 0
        var views: [(NSView, CGFloat)] = []
        var lastFolder = ""
        let open = Set(cursorWindows().map(\.workspace))
        for c in chats {
            if c.folder != lastFolder {
                lastFolder = c.folder
                let h = NSTextField(labelWithString: "\(open.contains(c.workspace) ? "●" : "○")  \(c.workspace)")
                h.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                h.textColor = NSColor.white.withAlphaComponent(0.55)
                views.append((h, 26))
            }
            let row = NSButton(title: "", target: self, action: #selector(openChat(_:)))
            row.isBordered = false
            row.alignment = .left
            row.identifier = NSUserInterfaceItemIdentifier(c.session)
            let ago = Int(-c.modified.timeIntervalSinceNow)
            let when = ago < 3600 ? "\(max(1, ago / 60))m" : ago < 86400 ? "\(ago / 3600)h" : "\(ago / 86400)d"
            let text = NSMutableAttributedString(string: "    \(c.title.prefix(60))", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            text.append(NSAttributedString(string: "   \(when)", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                            .foregroundColor: NSColor.gray]))
            row.attributedTitle = text
            views.append((row, 28))
        }
        let total = views.reduce(0) { $0 + $1.1 }
        listStack.frame = NSRect(x: 0, y: 0, width: width, height: max(total, listScroll.contentSize.height))
        y = listStack.frame.height
        for (v, h) in views {
            y -= h
            v.frame = NSRect(x: 4, y: y, width: width - 8, height: h)
            listStack.addSubview(v)
        }
        cache = Dictionary(uniqueKeysWithValues: chats.map { ($0.session, $0) })
    }

    private var cache: [String: ChatInfo] = [:]

    @objc private func openChat(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let c = cache[id] else { return }
        current = c
        heading.stringValue = c.title
        status.stringValue = "\(c.workspace)  ·  replies go into this chat in its Cursor window"
        lastSize = 0
        layout()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        container.window?.makeKey()
        container.window?.makeFirstResponder(reply)
    }

    private func refresh() {
        guard let c = current else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: c.file.path))?[.size] as? UInt64 ?? 0
        guard size != lastSize else { return }
        lastSize = size
        let atBottom = readerScroll.verticalScroller.map { $0.floatValue > 0.97 } ?? true
        reader.textStorage?.setAttributedString(ChatStore.transcript(c))
        if atBottom || reader.string.count < 2000 { reader.scrollToEndOfDocument(nil) }
    }

    @objc private func back() { showList() }
    @objc private func jumpTapped() { if let c = current { jump?(c) } }

    @objc private func sendTapped() {
        guard let c = current else { return }
        let text = reply.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        status.stringValue = "Sending…"
        send?(c, text) { [weak self] note in
            self?.status.stringValue = note
            if note.hasPrefix("Sent") { self?.reply.stringValue = "" }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { sendTapped(); return true }
        return false
    }
}
