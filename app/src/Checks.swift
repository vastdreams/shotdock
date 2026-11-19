// Claude monitor: a compact, draggable dark panel with one row per Claude chat, fed by claimcheck.py
// (~/.claude/state/claimcheck/results.jsonl).
// Row: status dot (green backed up, red not backed up, grey finished), workspace, what happened, how long ago.
// Click a row to expand its claims in place. Only the small arrow button switches to that chat.
// Header: counts and a collapse chevron. Red rows send the follow-up automatically (toggle in the ShotDock menu)
// and say "Delivered" only once it shows up in that chat's transcript.

import Cocoa

struct Claim {
    let text: String
    let verdict: String
    let why: String
}

struct CheckResult {
    let session: String
    let cwd: String
    let workspace: String
    let status: String
    let followup: String
    let auto: Bool
    let claims: [Claim]
    let summary: String
    let time: Date

    init?(_ d: [String: Any]) {
        guard let session = d["session"] as? String else { return nil }
        self.session = session
        cwd = d["cwd"] as? String ?? ""
        workspace = d["workspace"] as? String ?? "Claude"
        status = d["status"] as? String ?? "finished"
        followup = d["followup"] as? String ?? ""
        auto = d["auto"] as? Bool ?? false
        claims = (d["claims"] as? [[String: Any]] ?? []).map {
            Claim(text: $0["claim"] as? String ?? "", verdict: $0["verdict"] as? String ?? "", why: $0["why"] as? String ?? "")
        }
        summary = (d["summary"] as? String ?? d["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        time = Date(timeIntervalSince1970: d["ts"] as? Double ?? Date().timeIntervalSince1970)
    }

    var bad: Int { claims.filter { $0.verdict == "unsupported" }.count }

    var line: String {
        switch status {
        case "unsupported": return "\(bad) of \(claims.count) claims not backed up"
        case "supported": return claims.isEmpty ? "Done" : claims.count == 1 ? "Done · claim backed up" : "Done · \(claims.count) claims backed up"
        case "unchecked": return "Finished · check could not run"
        default: return "Finished · nothing claimed"
        }
    }

    var color: NSColor {
        switch status {
        case "unsupported": return .systemRed
        case "supported": return .systemGreen
        default: return .systemGray
        }
    }

    func text(of c: Claim) -> String { c.verdict == "supported" ? c.text : "\(c.text): \(c.why)" }
}

private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = NSColor.white.withAlphaComponent(alpha)
    l.lineBreakMode = .byTruncatingTail
    return l
}

private func wrapped(_ s: String, width: CGFloat) -> (NSTextField, CGFloat) {
    let t = NSTextField(wrappingLabelWithString: s)
    t.font = NSFont.systemFont(ofSize: 11)
    t.textColor = NSColor.white.withAlphaComponent(0.82)
    t.maximumNumberOfLines = 3
    return (t, min(46, t.sizeThatFits(NSSize(width: width, height: 60)).height))
}

private func ago(_ d: Date) -> String {
    let s = Int(-d.timeIntervalSinceNow)
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

/// One chat. Collapsed: 44 points (60 with a follow-up note). Expanded: claims, note and actions.
final class RowView: NSView {
    let result: CheckResult
    var expanded = false
    var onToggle: (() -> Void)?
    var onJump: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onFollowup: (() -> Void)?
    private var note = ""
    private let width: CGFloat
    private var when: NSTextField?

    init(_ r: CheckResult, width: CGFloat) {
        result = r
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func setNote(_ s: String) { note = s }
    func refreshTime() { when?.stringValue = ago(result.time) }

    private var claimTexts: [String] {
        result.claims.isEmpty ? [result.summary] : result.claims.prefix(5).map(result.text(of:))
    }

    /// Size for the current state, then draw.
    func relayout() {
        var h: CGFloat = note.isEmpty ? 44 : 60
        if expanded {
            h = 50 + claimTexts.reduce(0) { $0 + wrapped($1, width: width - 64).1 + 6 } + 34
        }
        setFrameSize(NSSize(width: width, height: h))
        draw()
    }

    private func draw() {
        subviews.forEach { $0.removeFromSuperview() }
        let h = frame.height
        let dot = NSView(frame: NSRect(x: 12, y: h - 25, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = result.color.cgColor
        addSubview(dot)
        let chatTitle = ChatMarks.titles[result.session]
        let name = label(chatTitle.map { "\($0)  ·  \(result.workspace)" } ?? result.workspace, size: 12.5, weight: .semibold)
        name.frame = NSRect(x: 30, y: h - 22, width: width - 120, height: 16)
        addSubview(name)
        let line = label(result.line, size: 11, alpha: 0.7)
        line.frame = NSRect(x: 30, y: h - 38, width: width - 110, height: 14)
        addSubview(line)
        let w = label(ago(result.time), size: 10.5, alpha: 0.55)
        w.alignment = .right
        w.frame = NSRect(x: width - 90, y: h - 21, width: 34, height: 14)
        addSubview(w)
        when = w
        let jump = icon("arrow.up.forward.app", "Switch to this chat", #selector(jumpTapped))
        jump.frame = NSRect(x: width - 52, y: h - 29, width: 20, height: 20)
        addSubview(jump)
        let close = icon("xmark", "Remove", #selector(closeTapped))
        close.frame = NSRect(x: width - 27, y: h - 27, width: 15, height: 15)
        addSubview(close)
        let noteLabel = label(note, size: 11, weight: .medium, alpha: 0.85)
        if note.hasPrefix("Delivered") { noteLabel.textColor = .systemGreen }
        if !expanded {
            if !note.isEmpty {
                noteLabel.frame = NSRect(x: 30, y: 6, width: width - 44, height: 14)
                addSubview(noteLabel)
            }
            return
        }
        var y = h - 48
        let items: [(String, NSColor)] = result.claims.isEmpty ? [("", .systemGray)] : result.claims.prefix(5).map {
            switch $0.verdict {
            case "supported": return ("✓", .systemGreen)
            case "unsupported": return ("✕", .systemRed)
            default: return ("?", .systemGray)
            }
        }
        for (i, text) in claimTexts.enumerated() {
            let (t, th) = wrapped(text, width: width - 64)
            let m = label(items[i].0, size: 11, weight: .bold)
            m.textColor = items[i].1
            m.frame = NSRect(x: 30, y: y - 14, width: 12, height: 14)
            t.frame = NSRect(x: 44, y: y - th, width: width - 60, height: th)
            addSubview(m)
            addSubview(t)
            y -= th + 6
        }
        if !result.claims.isEmpty {
            let wrong = NSButton(title: "Verdict wrong", target: self, action: #selector(wrongTapped))
            wrong.bezelStyle = .rounded
            wrong.controlSize = .small
            wrong.frame = NSRect(x: width - 232, y: 6, width: 104, height: 22)
            addSubview(wrong)
        }
        if !result.followup.isEmpty {
            let send = NSButton(title: "Send follow-up", target: self, action: #selector(followupTapped))
            send.bezelStyle = .rounded
            send.controlSize = .small
            send.frame = NSRect(x: width - 122, y: 6, width: 110, height: 22)
            addSubview(send)
        }
        noteLabel.frame = NSRect(x: 30, y: 10, width: width - 160, height: 14)
        addSubview(noteLabel)
    }

    private func icon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        b.toolTip = tip
        return b
    }

    private var downAt: NSPoint?
    private var startOrigin = NSPoint.zero
    private var moved = false
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let w = window else { return }
        let now = NSEvent.mouseLocation
        if !moved && hypot(now.x - start.x, now.y - start.y) < 3 { return }
        moved = true
        w.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - start.x, y: startOrigin.y + now.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        if !moved { onToggle?() } else { window?.saveFrame(usingName: "ClaudeMonitor") }
        downAt = nil
    }
    @objc private func jumpTapped() { onJump?() }
    @objc private func closeTapped() { onDismiss?() }
    @objc private func followupTapped() { onFollowup?() }

    /// Log a wrong verdict; claimcheck moves it into the DuraLoop database for accuracy tracking.
    @objc private func wrongTapped() {
        let rec: [String: Any] = ["ts": Date().timeIntervalSince1970, "session": result.session, "workspace": result.workspace,
                                  "status": result.status, "note": "verdict wrong"]
        let url = home.appendingPathComponent(".claude/state/claimcheck/feedback.jsonl")
        if let data = try? JSONSerialization.data(withJSONObject: rec), var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        setNote("Thanks. Logged as a wrong verdict.")
        relayout()
    }
}

/// The monitor window: floats without activating ShotDock, but can take keyboard focus for the reply box.
final class KeyFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// An edge or corner strip that resizes the overlay (borderless windows get no resize edges from macOS).
final class EdgeHandle: NSView {
    struct Edge: OptionSet { let rawValue: Int; static let left = Edge(rawValue: 1), right = Edge(rawValue: 2), top = Edge(rawValue: 4), bottom = Edge(rawValue: 8) }
    let edge: Edge
    var minSize = NSSize(width: 560, height: 360)
    var onResize: ((NSRect) -> Void)?
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(_ e: Edge) { edge = e; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    private var cursor: NSCursor {
        let horizontal = edge.contains(.left) || edge.contains(.right)
        let vertical = edge.contains(.top) || edge.contains(.bottom)
        return horizontal && vertical ? .crosshair : horizontal ? .resizeLeftRight : .resizeUpDown
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // Cursor rects only work in the active window; tracking areas show the resize arrows even when it is not.
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { cursor.push() }
    override func mouseExited(with event: NSEvent) { NSCursor.pop() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x
        let dy = now.y - startMouse.y
        var f = startFrame
        if edge.contains(.right) { f.size.width = max(minSize.width, startFrame.width + dx) }
        if edge.contains(.left) {
            f.size.width = max(minSize.width, startFrame.width - dx)
            f.origin.x = startFrame.maxX - f.width
        }
        if edge.contains(.top) { f.size.height = max(minSize.height, startFrame.height + dy) }
        if edge.contains(.bottom) {
            f.size.height = max(minSize.height, startFrame.height - dy)
            f.origin.y = startFrame.maxY - f.height
        }
        w.setFrame(f, display: true)
        onResize?(f)
    }
}

/// Background that always lets a drag move the window.
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class ChecksPanel {
    let panel: KeyFloatingPanel
    private let content = DragView()
    private var hideButton: NSButton!
    var hidden = UserDefaults.standard.bool(forKey: "MonitorHidden")
    var quiet = UserDefaults.standard.bool(forKey: "MonitorQuiet")
    private let title = label("Claude monitor", size: 12, weight: .semibold)
    private let counts = label("", size: 11, weight: .medium, alpha: 0.75)
    private let headDot = NSView()
    private var chevron: NSButton!
    private var rows: [RowView] = []
    private var collapsed = UserDefaults.standard.bool(forKey: "MonitorCollapsed")
    private var offset: UInt64 = 0
    private let resultsURL = home.appendingPathComponent(".claude/state/claimcheck/results.jsonl")
    private let rowWidth: CGFloat = 360
    private var hubSize: NSSize = {
        let d = UserDefaults.standard
        let w = d.double(forKey: "HubWidth"), h = d.double(forKey: "HubHeight")
        return NSSize(width: w > 0 ? w : 820, height: h > 0 ? h : 620)
    }()
    private var handles: [EdgeHandle] = []
    private var width: CGFloat { showingChats && !collapsed ? hubSize.width - 16 : 360 }
    var onResult: ((CheckResult) -> Void)?
    /// Live counts from the transcripts, shown first in the bar.
    var working = 0 { didSet { if oldValue != working { layout() } } }
    var stalled = 0 { didSet { if oldValue != stalled { layout() } } }
    var needYou = 0 { didSet { if oldValue != needYou { layout() } } }
    /// The Chats pane lives inside this window, under the header.
    var chatsView: NSView?
    private var chooser: NSView?
    private var chooserDone: ((Int?) -> Void)?

    /// "Send shot to": a short list in the body of this window. Calls back with the picked index, or nil.
    func choose(_ heading: String, _ options: [String], done: @escaping (Int?) -> Void) {
        chooser?.removeFromSuperview()
        let v = DragView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: CGFloat(options.count) * 30 + 34))
        let h = NSTextField(labelWithString: heading)
        h.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        h.textColor = NSColor.white.withAlphaComponent(0.7)
        h.frame = NSRect(x: 8, y: v.frame.height - 22, width: rowWidth - 60, height: 16)
        v.addSubview(h)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(chooserCancel))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.frame = NSRect(x: rowWidth - 70, y: v.frame.height - 26, width: 64, height: 22)
        v.addSubview(cancel)
        for (i, title) in options.enumerated() {
            let b = NSButton(title: "  " + title, target: self, action: #selector(chooserPick(_:)))
            b.tag = i
            b.alignment = .left
            b.bezelStyle = .rounded
            b.frame = NSRect(x: 4, y: v.frame.height - 30 - CGFloat(i + 1) * 30, width: rowWidth - 8, height: 26)
            v.addSubview(b)
        }
        chooser = v
        chooserDone = done
        if hidden { hidden = false }
        collapsed = false
        layout()
        panel.makeKey()
    }

    @objc private func chooserPick(_ sender: NSButton) { endChooser(sender.tag) }
    @objc private func chooserCancel() { endChooser(nil) }

    private func endChooser(_ pick: Int?) {
        chooser?.removeFromSuperview()
        chooser = nil
        let done = chooserDone
        chooserDone = nil
        layout()
        done?(pick)
    }
    private(set) var showingChats = false
    var onChatsShown: (() -> Void)?
    private var lastCheckerLook = Date.distantPast
    var autoFollowup = true
    var deliver: ((CheckResult, @escaping (String) -> Void) -> Void)?
    var openChat: ((CheckResult) -> Void)?
    var onCapture: (() -> Void)?
    var onElement: (() -> Void)?
    var onChats: (() -> Void)?
    private var elementButton: NSButton!
    private var chatsButton: NSButton!
    var onMenu: ((NSButton) -> Void)?
    private var cameraButton: NSButton!
    private var menuButton: NSButton!

    init() {
        panel = KeyFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 376, height: 40),
                              styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.alphaValue = 1.0
        let bg = DragView(frame: panel.contentView!.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1.0).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg
        bg.addSubview(content)
        headDot.wantsLayer = true
        headDot.layer?.cornerRadius = 4
        content.addSubview(headDot)
        content.addSubview(title)
        content.addSubview(counts)
        counts.alignment = .right
        chevron = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse") ?? NSImage(),
                           target: self, action: #selector(toggleCollapse))
        chevron.isBordered = false
        chevron.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        content.addSubview(chevron)
        hideButton = NSButton(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide") ?? NSImage(),
                              target: self, action: #selector(hideTapped))
        hideButton.isBordered = false
        hideButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        hideButton.toolTip = "Hide the monitor (Ctrl+Opt+M brings it back)"
        content.addSubview(hideButton)
        cameraButton = NSButton(image: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture") ?? NSImage(),
                                target: self, action: #selector(captureTapped))
        cameraButton.isBordered = false
        cameraButton.contentTintColor = .white
        cameraButton.toolTip = "Capture and send to Claude (Ctrl+Opt+X)"
        content.addSubview(cameraButton)
        cameraButton.toolTip = "Screenshot: drag an area (Ctrl+Opt+X)"
        elementButton = NSButton(image: NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Element") ?? NSImage(),
                                 target: self, action: #selector(elementTapped))
        elementButton.isBordered = false
        elementButton.contentTintColor = .white
        elementButton.toolTip = "Element: pick the exact thing, with its details (Ctrl+Opt+E)"
        content.addSubview(elementButton)
        chatsButton = NSButton(image: NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Chats") ?? NSImage(),
                               target: self, action: #selector(chatsTapped))
        chatsButton.isBordered = false
        chatsButton.contentTintColor = .white
        chatsButton.toolTip = "Chats: read and reply to any Claude chat"
        content.addSubview(chatsButton)
        menuButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More") ?? NSImage(),
                              target: self, action: #selector(menuTapped))
        menuButton.isBordered = false
        menuButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        content.addSubview(menuButton)
        for e: EdgeHandle.Edge in [.left, .right, .top, .bottom, [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]] {
            let h = EdgeHandle(e)
            h.onResize = { [weak self] f in
                guard let self else { return }
                self.hubSize = f.size
                UserDefaults.standard.set(Double(f.width), forKey: "HubWidth")
                UserDefaults.standard.set(Double(f.height), forKey: "HubHeight")
                self.layout()
            }
            handles.append(h)
            bg.addSubview(h)
        }
        if !panel.setFrameUsingName("ClaudeMonitor"), let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - 376 - 24, y: f.minY + 24))
        }
        panel.setFrameAutosaveName("ClaudeMonitor")
        if let size = (try? FileManager.default.attributesOfItem(atPath: resultsURL.path))?[.size] as? UInt64 { offset = size }
        restoreRecent()
        ensureChecker()
    }

    /// Keep claimcheck.py running as ShotDock's child; looked at every 30 seconds.
    private var checker: Process?
    /// Installed copy first, then a development copy.
    private var checkerPath: String {
        let installed = home.appendingPathComponent("Library/Application Support/ShotDock/claimcheck/claimcheck.py").path
        return FileManager.default.fileExists(atPath: installed) ? installed : home.appendingPathComponent(".claude/tools/claimcheck/claimcheck.py").path
    }

    /// Keep claimcheck.py running as ShotDock's child; looked at every 30 seconds. The script's own pid lock
    /// stops a second copy if one was started elsewhere.
    func ensureChecker() {
        lastCheckerLook = Date()
        if let c = checker, c.isRunning { return }
        // A checker started elsewhere holds the pid lock; leave it alone.
        let pidFile = home.appendingPathComponent(".claude/state/claimcheck/claimcheck.pid")
        if let txt = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [checkerPath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); checker = p; slog("claimcheck launched by ShotDock (pid \(p.processIdentifier))") }
        catch { slog("claimcheck launch failed: \(error)") }
    }

    /// After a restart, bring back each chat's latest result from the last 12 hours, quietly.
    private func restoreRecent() {
        guard let text = try? String(contentsOf: resultsURL, encoding: .utf8) else { return }
        var latest: [String: CheckResult] = [:]
        for line in text.split(separator: "\n").suffix(400) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let r = CheckResult(obj),
                  r.time > Date().addingTimeInterval(-12 * 3600), !r.session.hasPrefix("test-") else { continue }
            latest[r.session] = r
        }
        for r in latest.values.sorted(by: { $0.time < $1.time }).suffix(6) {
            let row = RowView(r, width: rowWidth)
            row.onToggle = { [weak self, weak row] in row?.expanded.toggle(); self?.layout() }
            row.onJump = { [weak self] in self?.openChat?(r) }
            row.onDismiss = { [weak self, weak row] in
                guard let self, let row else { return }
                self.rows.removeAll { $0 === row }; row.removeFromSuperview(); self.layout()
            }
            row.onFollowup = { [weak self, weak row] in self?.deliver?(r) { note in row?.setNote(note); self?.layout() } }
            rows.insert(row, at: 0)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for r in latest.values { self.onResult?(r) }
        }
    }

    func poll() {
        if Date().timeIntervalSince(lastCheckerLook) > 30 { ensureChecker() }
        rows.forEach { $0.refreshTime() }
        guard let h = try? FileHandle(forReadingFrom: resultsURL) else { return }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end > offset else { return }
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: Int(end - offset)), let text = String(data: data, encoding: .utf8),
              let lastNL = text.lastIndex(of: "\n") else { return }
        offset += UInt64(text[...lastNL].utf8.count)
        for line in text[...lastNL].split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let r = CheckResult(obj) else { continue }
            add(r)
        }
    }

    private func add(_ r: CheckResult) {
        onResult?(r)
        if let old = rows.first(where: { $0.result.session == r.session }) { rows.removeAll { $0 === old }; old.removeFromSuperview() }
        let row = RowView(r, width: rowWidth)
        row.onToggle = { [weak self, weak row] in
            row?.expanded.toggle()
            self?.layout()
        }
        row.onJump = { [weak self] in self?.openChat?(r) }
        row.onDismiss = { [weak self, weak row] in
            guard let self, let row else { return }
            self.rows.removeAll { $0 === row }
            row.removeFromSuperview()
            self.layout()
        }
        row.onFollowup = { [weak self, weak row] in
            self?.deliver?(r) { note in row?.setNote(note); self?.layout() }
        }
        rows.insert(row, at: 0)
        while rows.count > 6 { rows.removeLast().removeFromSuperview() }
        if r.status == "unsupported", !r.followup.isEmpty {
            if r.auto && autoFollowup {
                deliver?(r) { [weak self, weak row] note in row?.setNote(note); self?.layout() }
            } else {
                row.setNote(r.auto ? "Auto-send is off. Expand to send." : "Two follow-ups already sent. Expand to send.")
            }
        }
        if r.status == "unsupported" && hidden && !quiet { hidden = false }
        if hidden { return }
        layout()
        if r.status == "unsupported" || !quiet { NSSound(named: r.status == "unsupported" ? "Basso" : "Glass")?.play() }
    }

    @objc private func hideTapped() { setHidden(true) }
    @objc private func captureTapped() { onCapture?() }
    @objc private func elementTapped() { onElement?() }
    @objc private func chatsTapped() { toggleChats() }

    func toggleChats() {
        showingChats.toggle()
        if showingChats { collapsed = false; onChatsShown?() }
        layout()
        if showingChats { panel.makeKey() }
    }
    @objc private func menuTapped() { onMenu?(menuButton) }

    /// The monitor is ShotDock's only window: hide it while capturing so it is not in the shot.
    func hideForCapture(_ on: Bool) {
        if on { panel.orderOut(nil) } else { layout() }
    }

    func setHidden(_ h: Bool) {
        hidden = h
        UserDefaults.standard.set(h, forKey: "MonitorHidden")
        if h { panel.orderOut(nil) } else { layout() }
    }

    func toggleQuiet() {
        quiet.toggle()
        UserDefaults.standard.set(quiet, forKey: "MonitorQuiet")
    }

    @objc private func toggleCollapse() {
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: "MonitorCollapsed")
        layout()
    }

    private func layout() {
        guard !hidden else { panel.orderOut(nil); return }
        let green = rows.filter { $0.result.status == "supported" }.count
        let red = rows.filter { $0.result.status == "unsupported" }.count
        let grey = rows.count - green - red
        let live = [needYou > 0 ? "\(needYou) need you" : nil, working > 0 ? "\(working) working" : nil,
                    stalled > 0 ? "\(stalled) stalled" : nil].compactMap { $0 }
        counts.stringValue = (live + (rows.isEmpty ? [] : [red > 0 ? "\(red) to check" : nil, green > 0 ? "\(green) done" : nil,
                              grey > 0 ? "\(grey) finished" : nil].compactMap { $0 })).joined(separator: " · ")
        if counts.stringValue.isEmpty { counts.stringValue = "Watching" }
        headDot.layer?.backgroundColor = (red > 0 ? NSColor.systemRed : green > 0 ? .systemGreen : .systemGray).cgColor
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        rows.forEach { $0.relayout() }
        let header: CGFloat = 36
        let gap: CGFloat = 6
        let chatsOpen = showingChats && !collapsed && chooser == nil
        let body = chooser.map { $0.frame.height + 6 } ?? (chatsOpen ? hubSize.height - 40 : (collapsed || rows.isEmpty ? 0 : rows.reduce(0) { $0 + $1.frame.height } + CGFloat(rows.count) * gap))
        let h = header + body + (collapsed || (rows.isEmpty && !chatsOpen && chooser == nil) ? 0 : 4)
        let screen = (NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, screen.minX), screen.maxX - width - 16)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - h)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width + 16, height: h), display: true)
        content.frame = NSRect(x: 8, y: 0, width: width, height: h)
        headDot.frame = NSRect(x: 8, y: h - 22, width: 8, height: 8)
        title.stringValue = "Claude"
        title.frame = NSRect(x: 22, y: h - 26, width: 56, height: 16)
        counts.alignment = .left
        counts.frame = NSRect(x: 78, y: h - 25, width: width - 78 - 176, height: 14)
        chatsButton.frame = NSRect(x: width - 170, y: h - 30, width: 24, height: 22)
        elementButton.frame = NSRect(x: width - 140, y: h - 31, width: 24, height: 24)
        cameraButton.frame = NSRect(x: width - 110, y: h - 31, width: 24, height: 24)
        menuButton.frame = NSRect(x: width - 80, y: h - 29, width: 20, height: 20)
        hideButton.frame = NSRect(x: width - 52, y: h - 28, width: 18, height: 18)
        chevron.frame = NSRect(x: width - 26, y: h - 28, width: 18, height: 18)
        chatsButton.contentTintColor = showingChats ? .systemTeal : .white
        if let cv = chatsView {
            if chatsOpen {
                if cv.superview == nil { content.addSubview(cv) }
                cv.frame = NSRect(x: 0, y: 4, width: width, height: h - header - 4)
                cv.needsLayout = true
                NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: cv)
            } else {
                cv.removeFromSuperview()
            }
        }
        // Resize strips: only while the hub is open (the slim bar and rows size themselves).
        let pf = panel.contentView!.bounds
        let t: CGFloat = 10
        let frames: [NSRect] = [NSRect(x: 0, y: t, width: t, height: pf.height - 2 * t), NSRect(x: pf.width - t, y: t, width: t, height: pf.height - 2 * t),
                                NSRect(x: t, y: pf.height - t, width: pf.width - 2 * t, height: t), NSRect(x: t, y: 0, width: pf.width - 2 * t, height: t),
                                NSRect(x: 0, y: pf.height - t, width: t, height: t), NSRect(x: pf.width - t, y: pf.height - t, width: t, height: t),
                                NSRect(x: 0, y: 0, width: t, height: t), NSRect(x: pf.width - t, y: 0, width: t, height: t)]
        for (h, f) in zip(handles, frames) {
            h.frame = f
            h.isHidden = !chatsOpen
            h.window?.invalidateCursorRects(for: h)
            h.removeFromSuperview()
            panel.contentView?.addSubview(h)   // keep on top
        }
        if let ch = chooser {
            if ch.superview == nil { content.addSubview(ch) }
            ch.frame.origin = NSPoint(x: 0, y: h - header - ch.frame.height)
        }
        var y = h - header
        for r in rows {
            if collapsed || chatsOpen || chooser != nil { r.removeFromSuperview(); continue }
            if r.superview == nil { content.addSubview(r) }
            y -= r.frame.height
            r.frame.origin = NSPoint(x: 0, y: y)
            y -= gap
        }
        panel.orderFrontRegardless()
    }
}
