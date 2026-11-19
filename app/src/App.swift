// ShotDock app: the floating button, the menu, hotkeys, and the pick -> compose -> send flow.
// Ctrl+Opt+S shows or hides the button. Ctrl+Opt+X starts a capture. The button only shows while a Cursor
// workspace window exists.

import Carbon.HIToolbox
import Cocoa

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Toast body: click anywhere to dismiss.
final class ToastView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) { window?.orderOut(nil) }
}

final class HoverBackground: NSVisualEffectView {
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { window?.animator().alphaValue = 1.0 }
    override func mouseExited(with event: NSEvent) { window?.animator().alphaValue = 0.85 }
    override var mouseDownCanMoveWindow: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var shoot: NSButton!
    var badge: NSTextField!
    var toast: NSPanel?
    var userHidden = false
    var busy = false
    var picker = Picker()
    var composer: Composer?
    var lastRect: CGRect?
    var beforeShot: URL?
    var settings: SettingsPanel?
    var historyPanel: HistoryPanel?
    var hotKeys: [EventHotKeyRef?] = []
    var checks: ChecksPanel!
    var chats: ChatsPanel!
    var hub: HubView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let me = Bundle.main.bundleIdentifier ?? "com.fseresearch.shotdock"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 { NSApp.terminate(nil) }
        try? FileManager.default.createDirectory(at: sentDir, withIntermediateDirectories: true)
        buildPanel()
        registerHotKeys()
        setUpChecks()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.checks.poll() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.liveCounts() }
        // Daily update check; installs only a release whose signature verifies, and says so in a toast.
        let daily = { [weak self] in Updater.check(manual: false) { note in if !note.isEmpty { self?.showToast(note) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: daily)
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in daily() }
        tick()
    }

    // MARK: panel

    func buildPanel() {
        let size = NSSize(width: 92, height: 44)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0.85
        let bg = HoverBackground(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        panel.contentView = bg
        shoot = addButton("camera.viewfinder", "Capture and send to Claude (Ctrl+Opt+X)", x: 8, #selector(startCapture))
        _ = addButton("ellipsis.circle", "More", x: 50, #selector(showMenu(_:)))
        badge = NSTextField(labelWithString: "")
        badge.frame = NSRect(x: 30, y: 26, width: 16, height: 16)
        badge.alignment = .center
        badge.font = NSFont.boldSystemFont(ofSize: 10)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemTeal.cgColor
        badge.layer?.cornerRadius = 8
        badge.isHidden = true
        bg.addSubview(badge)
        if !panel.setFrameUsingName("ShotDockPanel2"), let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24))
        }
        panel.setFrameAutosaveName("ShotDockPanel2")
    }

    func addButton(_ symbol: String, _ tip: String, x: CGFloat, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: action)
        b.frame = NSRect(x: x, y: 5, width: 34, height: 34)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imageScaling = .scaleProportionallyUpOrDown
        b.contentTintColor = .white
        b.toolTip = tip
        panel.contentView?.addSubview(b)
        return b
    }

    /// Show the button only while Cursor has a workspace window, unless the operator hid it.
    func tick() {
        if panel.isVisible { panel.orderOut(nil) }   // the camera lives in the Claude monitor now
        refreshBadge()
    }

    @objc func showMenu(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: "Screenshot  (Ctrl+Opt+X)", action: #selector(startCapture), keyEquivalent: "")
        m.addItem(withTitle: "Element  (Ctrl+Opt+E)", action: #selector(startElement), keyEquivalent: "")
        m.addItem(withTitle: "Whole window  (Ctrl+Opt+W)", action: #selector(captureWindow), keyEquivalent: "")
        m.addItem(withTitle: "Scrolling capture", action: #selector(captureScroll), keyEquivalent: "")
        m.addItem(withTitle: "Record a bug  (Ctrl+Opt+R)", action: #selector(captureRecording), keyEquivalent: "")
        m.addItem(withTitle: beforeShot == nil ? "Before / after: take before" : "Before / after: take after", action: #selector(captureBeforeAfter), keyEquivalent: "")
        m.addItem(withTitle: "One-key send to last chat  (Ctrl+Opt+Q)", action: #selector(captureOneKey), keyEquivalent: "")
        m.addItem(withTitle: "Shot history…", action: #selector(showHistory), keyEquivalent: "")
        let again = m.addItem(withTitle: "Same area again", action: #selector(repeatLast), keyEquivalent: "")
        again.isEnabled = lastRect != nil
        m.addItem(.separator())
        let auto = m.addItem(withTitle: "Send claim follow-ups automatically", action: #selector(toggleAutoFollowup), keyEquivalent: "")
        auto.state = checks.autoFollowup ? .on : .off
        let quiet = m.addItem(withTitle: "Quiet: only pop up when a claim is not backed up", action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.state = checks.quiet ? .on : .off
        m.addItem(withTitle: checks.hidden ? "Show Claude monitor  (Ctrl+Opt+M)" : "Hide Claude monitor  (Ctrl+Opt+M)",
                  action: #selector(toggleMonitor), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Open the Screenshots folder", action: #selector(openFolder), keyEquivalent: "")
        m.addItem(withTitle: "Hide  (Ctrl+Opt+S brings it back)", action: #selector(togglePanel), keyEquivalent: "")
        m.addItem(withTitle: "Settings and API keys…", action: #selector(showSettings), keyEquivalent: "")
        m.addItem(withTitle: "Check for updates", action: #selector(checkUpdates), keyEquivalent: "")
        m.addItem(withTitle: "Quit ShotDock", action: #selector(quit), keyEquivalent: "")
        m.autoenablesItems = false
        m.items.forEach { if $0.action != nil { $0.target = self } }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Working and stalled chats across the Mac, for the bar.
    func liveCounts() {
        DispatchQueue.global(qos: .utility).async {
            let recent = ChatStore.list().filter { $0.modified > Date().addingTimeInterval(-86400) }
            let w = recent.filter { $0.state == "working" }.count
            let s = recent.filter { $0.state == "stalled" }.count
            let titles = Dictionary(recent.map { ($0.session, $0.title) }, uniquingKeysWith: { a, _ in a })
            let arch = ChatMarks.archived
            let n = recent.filter { ChatMarks.unread($0) && !arch.contains($0.session) }.count
            DispatchQueue.main.async {
                ChatMarks.titles.merge(titles) { _, new in new }
                self.checks.working = w; self.checks.stalled = s; self.checks.needYou = n
            }
        }
    }

    func setUpChecks() {
        checks = ChecksPanel()
        checks.autoFollowup = UserDefaults.standard.object(forKey: "AutoFollowup") as? Bool ?? false
        checks.onCapture = { [weak self] in self?.startCapture() }
        checks.onElement = { [weak self] in self?.startElement() }
        chats = ChatsPanel()
        hub = HubView(frame: NSRect(x: 0, y: 0, width: 820, height: 580))
        checks.chatsView = hub
        checks.onChatsShown = { [weak self] in self?.hub.reload() }
        checks.onResult = { [weak self] r in self?.hub.setStatus(r) }
        hub.onCapture = { [weak self] element in self?.capture(element: element, intoHub: true) }
        hub.onOpen = { [weak self] c in
            if c.client == "Cursor" {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", "Cursor", c.folder]; try? p.run()
            } else { self?.chats.jump?(c) }
        }
        hub.onEscape = { [weak self] in if self?.checks.showingChats == true { self?.checks.toggleChats() } }
        hub.onSend = { c, text, atts, note in
            if c.client == "Cursor" { Sender.sendToCursorAgent(c, text: text, attachments: atts, done: note) }
            else { Sender.sendToChat(c, text: text, attachments: atts, done: note) }
        }
        hub.onFollowup = { [weak self] r, note in self?.checks.deliver?(r, note) }
        chats.jump = { [weak self] c in
            Sender.deliver(image: nil, text: "", to: CursorWindow(id: 0, workspace: c.workspace, onScreen: false), pressReturn: false,
                           folderPath: c.folder, sessionID: c.session, openOnly: true) { _, problem in
                if let problem { self?.showToast(problem) }
            }
        }
        chats.send = { c, text, note in
            Sender.deliver(image: nil, text: text, to: CursorWindow(id: 0, workspace: c.workspace, onScreen: false), pressReturn: true,
                           folderPath: c.folder, sessionID: c.session, reveal: true) { sent, problem in
                note(problem ?? (sent ? "Sent to Claude in \(c.workspace)." : "Filled in. Press Return in the chat."))
            }
        }
        checks.onMenu = { [weak self] b in self?.showMenu(b) }
        checks.hideForCapture(false)
        checks.openChat = { r in
            let target = CursorWindow(id: 0, workspace: r.workspace, onScreen: false)
            Sender.deliver(image: nil, text: "", to: target, pressReturn: false, folderPath: r.cwd.isEmpty ? nil : r.cwd,
                           sessionID: r.session, openOnly: true) { [weak self] _, problem in
                if let problem { self?.showToast(problem) }
            }
        }
        checks.deliver = { [weak self] r, note in
            guard let self else { return }
            guard !self.busy else { note("Not sent: a capture was open. Press Send follow-up."); return }
            note("Sending follow-up…")
            let target = CursorWindow(id: 0, workspace: r.workspace, onScreen: false)
            let folder = r.cwd.isEmpty ? (Sender.folder(for: r.workspace) ?? "") : r.cwd
            let marker = "[Claim check]"
            let started = Date()
            Sender.deliver(image: nil, text: "\(marker) " + r.followup, to: target, pressReturn: true,
                           folderPath: folder.isEmpty ? nil : folder, sessionID: r.session) { _, problem in
                if let problem { note(problem) } else { note("Checking it reached the chat…") }
                // Only say delivered when the follow-up shows up in that chat's transcript.
                DispatchQueue.global().async {
                    for _ in 0..<15 {
                        if transcriptHas(session: r.session, folder: folder, marker: marker, since: started) {
                            slog("deliver \(r.workspace): confirmed in transcript")
                            DispatchQueue.main.async { note("Delivered to the chat") }
                            return
                        }
                        sleep(2)
                    }
                    slog("deliver \(r.workspace): not found in transcript after 30s")
                    DispatchQueue.main.async {
                        note(problem == nil ? "Not in the chat yet. Open it and press Return." : "Not sent. Open the chat.")
                    }
                }
            }
        }
    }

    @objc func toggleQuiet() { checks.toggleQuiet() }

    @objc func showSettings() {
        if settings == nil { settings = SettingsPanel() }
        settings?.show()
    }

    @objc func showHistory() {
        if historyPanel == nil { historyPanel = HistoryPanel() }
        historyPanel?.onPick = { [weak self] url in
            guard let self else { return }
            if !self.checks.showingChats { self.checks.toggleChats() }
            self.hub.addAttachment(url, nil)
        }
        historyPanel?.show()
    }

    @objc func checkUpdates() { Updater.check(manual: true) { [weak self] note in self?.showToast(note) } }
    @objc func toggleMonitor() { checks.setHidden(!checks.hidden) }

    @objc func toggleAutoFollowup() {
        checks.autoFollowup.toggle()
        UserDefaults.standard.set(checks.autoFollowup, forKey: "AutoFollowup")
        showToast(checks.autoFollowup ? "Follow-ups on unbacked claims are sent automatically."
                                      : "Follow-ups wait for you to press Send follow-up.")
    }

    @objc func togglePanel() { checks.setHidden(!checks.hidden) }

    @objc func openFolder() { NSWorkspace.shared.open(shotsDir) }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: pick -> compose -> send

    @objc func startCapture() { capture(element: false) }
    @objc func startElement() { capture(element: true) }

    /// Capture. With the hub open on a chat, the shot becomes an attachment in that chat's box in the hub.
    func capture(element: Bool, intoHub: Bool = false) {
        guard !busy else { return }
        busy = true
        let toHub = intoHub || (checks.showingChats && hub.selected != nil)
        checks.hideForCapture(true)
        picker.run(element: element) { [weak self] rect, info in
            guard let self else { return }
            guard let rect else { self.finish(); return }
            self.lastRect = rect
            if toHub {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if let url = captureRect(rect) { self.hub.addAttachment(url, self.finishShot(url, info: info)) }
                    else { self.showToast("Capture failed.") }
                    self.finish()
                }
            } else {
                self.shootAndCompose(rect, info: info)
            }
        }
    }

    @objc func repeatLast() {
        guard let r = lastRect, !busy else { return }
        busy = true
        checks.hideForCapture(true)
        shootAndCompose(r)
    }

    func shootAndCompose(_ rect: CGRect, info: String? = nil) {
        let under = windowUnder(CGPoint(x: rect.midX, y: rect.midY))
        let preferred = under?.owner == "Cursor" ? workspaceName(fromTitle: under?.title ?? "") : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let url = captureRect(rect) else {
                self.showToast("Capture failed. Screen Recording permission may be missing.")
                self.finish()
                return
            }
            self.shootAndComposeFile(url, more: [], info: self.finishShot(url, info: info), preferred: preferred)
        }
    }

    /// Put finished shot(s) into the right chat: the window they came from, else the most recent chat.
    func shootAndComposeFile(_ url: URL, more: [URL], info: String?, preferred: String? = nil) {
        do {
            let targets = cursorWindows()
            guard !targets.isEmpty else {
                self.copyImage(url)
                self.showToast("No Cursor window with Claude is open. The shot is on the clipboard.")
                self.finish()
                return
            }
            // Straight into a chat: the window it was taken from, else the chat used most recently.
            let all = ChatStore.list()
            let recent = all.first { c in targets.contains { $0.workspace == c.workspace } }?.workspace
            let name = preferred ?? recent ?? targets[0].workspace
            let target = targets.first { $0.workspace == name } ?? targets[0]
            // A window can hold several chats: if more than one was active in the last 12 hours, ask which.
            let candidates = all.filter { $0.workspace == target.workspace && $0.modified > Date().addingTimeInterval(-12 * 3600) }
            let go: (ChatInfo?) -> Void = { [weak self] chat in
                let images = ([url] + more).map { self?.prefs.shrink == true ? Media.sendable($0) : $0 }
                Sender.attach(image: images[0], more: Array(images.dropFirst()), details: info, to: target, sessionID: chat?.session) { problem in
                    if problem == nil, let chat { History.log(shot: url, chat: chat) }
                    if let problem {
                        self?.copyImage(url)
                        self?.showToast(problem + " The shot is on the clipboard: press Cmd+V in the chat.")
                    } else {
                        self?.showToast("Screenshot added to \(chat.map { "\"\($0.title)\"" } ?? "Claude") in \(target.workspace). Type your message and press Return.")
                    }
                    self?.finish()
                }
            }
            if candidates.count > 1 {
                self.checks.hideForCapture(false)
                self.checks.choose("Send shot to (\(target.workspace))", candidates.prefix(6).map { String($0.title.prefix(48)) }) { [weak self] pick in
                    guard let pick else {
                        self?.copyImage(url)
                        self?.showToast("Not sent. The shot is on the clipboard.")
                        self?.finish()
                        return
                    }
                    go(candidates[pick])
                }
            } else {
                go(candidates.first)
            }
        }
    }

    func finish() {
        busy = false
        checks.hideForCapture(false)
    }

    func copyImage(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    // MARK: feedback

    func showToast(_ message: String) {
        toast?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let width: CGFloat = 340
        let h = label.sizeThatFits(NSSize(width: width - 28, height: 200)).height + 22
        let t = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: h),
                              styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        t.level = .floating
        t.backgroundColor = .clear
        t.isOpaque = false
        t.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = ToastView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        label.frame = NSRect(x: 14, y: 11, width: width - 28, height: h - 22)
        bg.addSubview(label)
        t.contentView = bg
        let f = panel.frame
        let screen = NSScreen.main?.visibleFrame ?? .zero
        t.setFrameOrigin(NSPoint(x: min(f.maxX - width, screen.maxX - width - 8), y: max(f.minY - h - 8, screen.minY + 8)))
        t.orderFrontRegardless()
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak t] in t?.orderOut(nil) }
    }

    /// Native Cmd+Shift+4 shots waiting in ~/Screenshots for the next message (the hook attaches them).
    func refreshBadge() {
        let since = (try? String(contentsOf: stateFile, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let files = (try? FileManager.default.contentsOfDirectory(at: shotsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let waiting = files.filter { url in
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return false }
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (m?.timeIntervalSince1970 ?? 0) > since
        }.count
        badge.isHidden = waiting == 0
        badge.stringValue = "\(waiting)"
    }

    // MARK: hotkeys

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.hotKey(id.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let mods = UInt32(controlKey | optionKey)
        for (id, key) in [(UInt32(1), kVK_ANSI_S), (2, kVK_ANSI_X), (3, kVK_ANSI_M), (4, kVK_ANSI_E), (5, kVK_ANSI_Q), (6, kVK_ANSI_R), (7, kVK_ANSI_W)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5348_4F54), id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    func hotKey(_ id: UInt32) {
        if id == 1 { togglePanel() } else if id == 2 { startCapture() } else if id == 3 { checks.setHidden(!checks.hidden) } else if id == 4 { startElement() }
        else if id == 5 { captureOneKey() } else if id == 6 { captureRecording() } else if id == 7 { captureWindow() }
    }
}
