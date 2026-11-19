// Hub: the expanded Claude overlay, laid out like Cursor.
// Left: every Claude chat grouped by folder, each with a status dot from the claim checker (red = a claim is not
// backed up, green = backed up, grey = finished). Right: the selected chat's conversation (refreshes while open),
// then a chat box with Screenshot and Element buttons that attach to THIS chat, and Send. Sending pastes the
// attachments and the text into that exact chat in its Cursor window and presses Return, only if its box is empty.

import Cocoa

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// One chat in the sidebar.
final class SideRow: NSView {
    let chat: ChatInfo
    var onClick: (() -> Void)?
    var onArchive: (() -> Void)?
    var isArchived = false

    override func rightMouseDown(with event: NSEvent) {
        let m = NSMenu()
        let item = m.addItem(withTitle: isArchived ? "Unarchive" : "Archive", action: #selector(archiveTapped), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }
    @objc private func archiveTapped() { onArchive?() }

    init(chat: ChatInfo, status: CheckResult?, selected: Bool, width: CGFloat) {
        self.chat = chat
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
        let dot = NSView(frame: NSRect(x: 10, y: 11, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        let live: NSColor? = chat.state == "working" ? .systemBlue : chat.state == "stalled" ? .systemOrange : nil
        dot.layer?.backgroundColor = (live ?? status?.color ?? NSColor.white.withAlphaComponent(0.25)).cgColor
        addSubview(dot)
        let t = NSTextField(labelWithString: (chat.client == "Cursor" ? "◆ " : "") + chat.title)
        let unread = !selected && ChatMarks.unread(chat)
        t.font = NSFont.systemFont(ofSize: 12.5, weight: selected || unread ? .semibold : .regular)
        if unread {
            let u = NSView(frame: NSRect(x: width - 64, y: 12, width: 6, height: 6))
            u.wantsLayer = true
            u.layer?.cornerRadius = 3
            u.layer?.backgroundColor = NSColor.systemTeal.cgColor
            addSubview(u)
        }
        t.textColor = NSColor.white.withAlphaComponent(selected ? 1 : 0.85)
        t.lineBreakMode = .byTruncatingTail
        t.frame = NSRect(x: 26, y: 7, width: width - 84, height: 17)
        addSubview(t)
        let s = Int(-chat.modified.timeIntervalSinceNow)
        let w = NSTextField(labelWithString: chat.state == "working" ? "working" : chat.state == "stalled" ? "stalled"
                            : s < 3600 ? "\(max(1, s / 60))m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d")
        w.font = NSFont.systemFont(ofSize: 10.5)
        w.textColor = .gray
        w.alignment = .right
        if chat.state != "waiting" { w.textColor = live }
        w.frame = NSRect(x: width - 56, y: 8, width: 48, height: 14)
        addSubview(w)
        let stateWord = chat.state == "working" ? "Working" : chat.state == "stalled" ? "Stalled, silent 10 min" : "Waiting for you"
        toolTip = "\(chat.title)\n\(chat.client) · \(stateWord)" + (status.map { "\n\($0.line)" } ?? "")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Per-chat "last viewed" times and the archive, shared with the bar's "need you" count.
enum ChatMarks {
    static func lastViewed(_ id: String) -> Double { (UserDefaults.standard.dictionary(forKey: "ChatLastViewed")?[id] as? Double) ?? 0 }
    static func viewed(_ id: String) {
        var d = UserDefaults.standard.dictionary(forKey: "ChatLastViewed") ?? [:]
        d[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: "ChatLastViewed")
    }
    /// Unread: a reply arrived after you last looked. Chats never seen count from when ShotDock first saw them.
    static func unread(_ c: ChatInfo) -> Bool {
        let seen = lastViewed(c.session)
        let base = seen > 0 ? seen : firstSeen
        return c.state == "waiting" && c.modified.timeIntervalSince1970 > base + 2
    }
    static var firstSeen: Double {
        let d = UserDefaults.standard
        if d.double(forKey: "ChatMarksStart") == 0 { d.set(Date().timeIntervalSince1970, forKey: "ChatMarksStart") }
        return d.double(forKey: "ChatMarksStart")
    }
    /// Session id -> chat title, refreshed by the live counts, for the monitor rows.
    static var titles: [String: String] = [:]
    static var archived: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "ArchivedChats") ?? []) }
    static func setArchived(_ id: String, _ on: Bool) {
        var s = archived
        if on { s.insert(id) } else { s.remove(id) }
        UserDefaults.standard.set(Array(s), forKey: "ArchivedChats")
    }
}

/// The hub's chat box: Cmd+V of an image becomes an attachment instead of text.
final class ComposerTextView: NSTextView {
    var onImage: ((NSImage) -> Void)?
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb) { onImage?(img); return }
        super.paste(sender)
    }
}

final class HubView: NSView, NSTextViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["All", "Claude", "Cursor"], trackingMode: .selectOne, target: nil, action: nil)
    private let archivedToggle = NSButton(title: "Show archived", target: nil, action: nil)
    private var showArchived = false
    private var markup: MarkupPanel?
    private let sideScroll = NSScrollView()
    private let sideList = FlippedView()
    private let divider = NSView()
    private let titleLabel = NSTextField(labelWithString: "Pick a chat")
    private let subLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open in Cursor", target: nil, action: nil)
    private let followButton = NSButton(title: "Send follow-up", target: nil, action: nil)
    private let readerScroll = NSScrollView()
    private let reader = NSTextView()
    private let composerScroll = NSScrollView()
    private let composer = ComposerTextView()
    private let chips = FlippedView()
    private let shotButton = NSButton(title: "Screenshot", target: nil, action: nil)
    private let elementButton = NSButton(title: "Element", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var chats: [ChatInfo] = []
    private(set) var selected: ChatInfo?
    private var statuses: [String: CheckResult] = [:]
    private var attachments: [(URL, String?)] = []
    private var lastSize: UInt64 = 0
    private var timer: Timer?
    private var sideHidden = UserDefaults.standard.bool(forKey: "HubSidebarHidden")
    private var sideWidth: CGFloat { sideHidden ? 0 : 240 }
    private let sideToggle = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Chats list") ?? NSImage(),
                                      target: nil, action: nil)

    var onCapture: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    /// Cmd+1...9 jump to the first nine chats. Esc collapses the overlay.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { onEscape?(); return true }
        if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n),
           chats.indices.contains(n - 1) {
            select(chats[n - 1])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var onOpen: ((ChatInfo) -> Void)?
    var onSend: ((ChatInfo, String, [(URL, String?)], @escaping (String) -> Void) -> Void)?
    var onFollowup: ((CheckResult, @escaping (String) -> Void) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search chats"
        search.delegate = self
        search.controlSize = .small
        filter.selectedSegment = 0
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(filterChanged)
        archivedToggle.setButtonType(.switch)
        archivedToggle.controlSize = .small
        archivedToggle.target = self
        archivedToggle.action = #selector(archivedChanged)
        for v in [search, filter, archivedToggle] as [NSView] { addSubview(v) }
        sideScroll.documentView = sideList
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        for (b, a) in [(openButton, #selector(openTapped)), (followButton, #selector(followTapped)),
                       (shotButton, #selector(shotTapped)), (elementButton, #selector(elementTapped)),
                       (sendButton, #selector(sendTapped))] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
            b.action = a
        }
        shotButton.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        elementButton.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)
        for b in [shotButton, elementButton] { b.imagePosition = .imageLeading }
        sendButton.bezelColor = .systemTeal
        reader.isEditable = false
        reader.drawsBackground = false
        reader.textContainerInset = NSSize(width: 10, height: 10)
        reader.autoresizingMask = [.width]
        readerScroll.documentView = reader
        readerScroll.hasVerticalScroller = true
        readerScroll.drawsBackground = false
        composer.isRichText = false
        composer.font = NSFont.systemFont(ofSize: 13)
        composer.textColor = .white
        composer.insertionPointColor = .white
        composer.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        composer.textContainerInset = NSSize(width: 6, height: 6)
        composer.delegate = self
        composer.onImage = { [weak self] img in self?.addImage(img) }
        registerForDraggedTypes([.fileURL, .png, .tiff])
        composer.autoresizingMask = [.width]
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 8
        composerScroll.layer?.borderWidth = 1
        composerScroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        sideToggle.isBordered = false
        sideToggle.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        sideToggle.toolTip = "Hide or show the chat list"
        sideToggle.target = self
        sideToggle.action = #selector(toggleSide)
        for v in [sideToggle, sideScroll, divider, titleLabel, subLabel, openButton, followButton, readerScroll, chips,
                  composerScroll, shotButton, elementButton, sendButton, status] as [NSView] { addSubview(v) }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true, self.superview != nil else { return }
            self.reload()
        }
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: data

    func reload() {
        chats = ChatStore.list()
        if let s = selected, let fresh = chats.first(where: { $0.session == s.session }) { selected = fresh }
        if selected == nil { select(chats.first) }
        buildSidebar()
    }

    func setStatus(_ r: CheckResult) {
        statuses[r.session] = r
        buildSidebar()
        if r.session == selected?.session { updateHeader() }
    }

    /// Save a pasted or dropped image into the shots folder and attach it.
    func addImage(_ img: NSImage) {
        let url = newShotURL()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]),
           (try? png.write(to: url)) != nil { addAttachment(url, nil) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    /// Dropped images attach; other files go in as their paths, so Claude can read them.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for u in urls {
            if ["png", "jpg", "jpeg", "gif", "heic", "tiff"].contains(u.pathExtension.lowercased()) { addAttachment(u, nil) }
            else { composer.string += (composer.string.isEmpty ? "" : "\n") + "File: \(u.path)" }
        }
        if urls.isEmpty, let img = NSImage(pasteboard: pb) { addImage(img) }
        return true
    }

    func addAttachment(_ url: URL, _ info: String?) {
        attachments.append((url, info))
        buildChips()
        relayout()
        window?.makeKey()
        window?.makeFirstResponder(composer)
    }

    private func select(_ c: ChatInfo?) {
        selected = c
        if let c { ChatMarks.viewed(c.session) }
        lastSize = 0
        reader.string = ""
        updateHeader()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        buildSidebar()
        window?.makeFirstResponder(composer)
    }

    private func updateHeader() {
        guard let c = selected else { titleLabel.stringValue = "Pick a chat"; subLabel.stringValue = ""; return }
        titleLabel.stringValue = c.title
        let st = statuses[c.session]
        subLabel.stringValue = "\(c.client) · \(c.workspace)" + (st.map { "  ·  \($0.line)" } ?? "")
        subLabel.textColor = st?.status == "unsupported" ? .systemRed : .secondaryLabelColor
        followButton.isHidden = !(st?.status == "unsupported" && !(st?.followup.isEmpty ?? true))
    }

    private func refresh() {
        guard let c = selected else { return }
        if window?.isVisible == true { ChatMarks.viewed(c.session) }
        let size = (try? FileManager.default.attributesOfItem(atPath: c.file.path))?[.size] as? UInt64 ?? 0
        guard size != lastSize else { return }
        lastSize = size
        let atBottom = readerScroll.verticalScroller.map { $0.floatValue > 0.97 } ?? true
        reader.textStorage?.setAttributedString(ChatStore.transcript(c))
        if atBottom || reader.string.count < 3000 { reader.scrollToEndOfDocument(nil) }
    }

    // MARK: building

    func controlTextDidChange(_ obj: Notification) { buildSidebar() }
    @objc private func filterChanged() { buildSidebar() }
    @objc private func archivedChanged() { showArchived = archivedToggle.state == .on; buildSidebar() }

    private var visibleChats: [ChatInfo] {
        let q = search.stringValue.lowercased()
        let arch = ChatMarks.archived
        let picked = chats.filter { c in
            (showArchived || !arch.contains(c.session)) &&
            (filter.selectedSegment == 0 || (filter.selectedSegment == 1) == (c.client == "Claude Code")) &&
            (q.isEmpty || c.title.lowercased().contains(q) || c.workspace.lowercased().contains(q))
        }
        // One group per folder, the most recently active folder first, newest chat first inside it.
        var latest: [String: Date] = [:]
        for c in picked { latest[c.folder] = max(latest[c.folder] ?? .distantPast, c.modified) }
        return picked.sorted { a, b in
            a.folder == b.folder ? a.modified > b.modified : (latest[a.folder]!, a.folder) > (latest[b.folder]!, b.folder)
        }
    }

    private func buildSidebar() {
        sideList.subviews.forEach { $0.removeFromSuperview() }
        let archivedCount = ChatMarks.archived.count
        archivedToggle.title = archivedCount > 0 ? "Show archived (\(archivedCount))" : "Show archived"
        let w = sideWidth - 12
        var y: CGFloat = 4
        var lastFolder = ""
        let open = Set(cursorWindows().map(\.workspace))
        let arch = ChatMarks.archived
        for c in visibleChats {
            if c.folder != lastFolder {
                lastFolder = c.folder
                let h = NSTextField(labelWithString: c.workspace)
                h.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                h.textColor = NSColor.white.withAlphaComponent(open.contains(c.workspace) ? 0.6 : 0.35)
                h.lineBreakMode = .byTruncatingTail
                h.frame = NSRect(x: 8, y: y + 8, width: w - 8, height: 15)
                sideList.addSubview(h)
                y += 28
            }
            let row = SideRow(chat: c, status: statuses[c.session], selected: c.session == selected?.session, width: w)
            row.frame.origin = NSPoint(x: 2, y: y)
            row.onClick = { [weak self] in self?.select(c) }
            row.isArchived = arch.contains(c.session)
            row.onArchive = { [weak self] in
                ChatMarks.setArchived(c.session, !arch.contains(c.session))
                self?.buildSidebar()
            }
            sideList.addSubview(row)
            y += 31
        }
        sideList.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 6, sideScroll.contentSize.height))
    }

    private func buildChips() {
        chips.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for (i, a) in attachments.enumerated() {
            let iv = NSImageView(frame: NSRect(x: x, y: 0, width: 64, height: 40))
            iv.image = NSImage(contentsOf: a.0)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4
            iv.layer?.borderWidth = 1
            iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            iv.toolTip = (a.1 ?? "Screenshot") + "\nClick to mark up"
            chips.addSubview(iv)
            let hit = NSButton(title: "", target: self, action: #selector(markupChip(_:)))
            hit.isBordered = false
            hit.isTransparent = true
            hit.tag = i
            hit.frame = iv.frame
            chips.addSubview(hit)
            let x0 = NSButton(title: "×", target: self, action: #selector(removeChip(_:)))
            x0.tag = i
            x0.isBordered = false
            x0.font = NSFont.boldSystemFont(ofSize: 12)
            x0.contentTintColor = .white
            x0.frame = NSRect(x: x + 50, y: -2, width: 16, height: 16)
            chips.addSubview(x0)
            if a.1 != nil {
                let tag = NSTextField(labelWithString: "element")
                tag.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
                tag.textColor = .systemTeal
                tag.frame = NSRect(x: x + 2, y: 26, width: 50, height: 12)
                chips.addSubview(tag)
            }
            x += 72
        }
    }

    @objc private func markupChip(_ b: NSButton) {
        guard attachments.indices.contains(b.tag), let m = MarkupPanel(url: attachments[b.tag].0) else { return }
        m.onDone = { [weak self] in self?.buildChips() }
        markup = m
        m.show()
    }

    @objc private func removeChip(_ b: NSButton) {
        guard attachments.indices.contains(b.tag) else { return }
        attachments.remove(at: b.tag)
        buildChips()
        relayout()
    }

    @objc func relayout() {
        let b = bounds
        guard b.width > 300 else { return }
        sideScroll.isHidden = sideHidden
        divider.isHidden = sideHidden
        search.isHidden = sideHidden
        filter.isHidden = sideHidden
        archivedToggle.isHidden = sideHidden
        search.frame = NSRect(x: 4, y: b.height - 26, width: max(sideWidth - 8, 1), height: 22)
        filter.frame = NSRect(x: 4, y: b.height - 52, width: max(sideWidth - 8, 1), height: 22)
        archivedToggle.frame = NSRect(x: 8, y: 2, width: max(sideWidth - 12, 1), height: 18)
        sideScroll.frame = NSRect(x: 0, y: 22, width: max(sideWidth, 1), height: max(b.height - 78, 1))
        divider.frame = NSRect(x: sideWidth + 4, y: 0, width: 1, height: b.height)
        sideToggle.frame = NSRect(x: sideWidth + 12, y: b.height - 30, width: 22, height: 22)
        let x = sideWidth + 40
        let w = b.width - x - 6
        let top = b.height
        titleLabel.frame = NSRect(x: x, y: top - 22, width: w - 240, height: 18)
        subLabel.frame = NSRect(x: x, y: top - 38, width: w - 240, height: 14)
        openButton.frame = NSRect(x: b.width - 112, y: top - 30, width: 106, height: 22)
        followButton.frame = NSRect(x: b.width - 228, y: top - 30, width: 112, height: 22)
        let chipH: CGFloat = attachments.isEmpty ? 0 : 46
        status.frame = NSRect(x: sideWidth + 14, y: 4, width: b.width - sideWidth - 270, height: 14)
        shotButton.frame = NSRect(x: b.width - 252, y: 2, width: 96, height: 22)
        elementButton.frame = NSRect(x: b.width - 154, y: 2, width: 84, height: 22)
        sendButton.frame = NSRect(x: b.width - 66, y: 2, width: 60, height: 22)
        let bx = sideWidth + 14
        let bw = b.width - bx - 6
        composerScroll.frame = NSRect(x: bx, y: 30, width: bw, height: 64)
        composer.frame.size.width = composerScroll.contentSize.width
        chips.frame = NSRect(x: bx, y: 100, width: bw, height: chipH)
        readerScroll.frame = NSRect(x: bx, y: 100 + chipH + 4, width: bw, height: top - 46 - (104 + chipH))
        reader.frame.size.width = readerScroll.contentSize.width
        if chats.isEmpty { reload() } else { buildSidebar() }
    }

    // MARK: actions

    @objc private func toggleSide() {
        sideHidden.toggle()
        UserDefaults.standard.set(sideHidden, forKey: "HubSidebarHidden")
        relayout()
    }

    @objc private func openTapped() { if let c = selected { onOpen?(c) } }
    @objc private func shotTapped() { onCapture?(false) }
    @objc private func elementTapped() { onCapture?(true) }

    @objc private func followTapped() {
        guard let c = selected, let st = statuses[c.session] else { return }
        status.stringValue = "Sending follow-up…"
        onFollowup?(st) { [weak self] note in self?.status.stringValue = note }
    }

    @objc private func sendTapped() {
        guard let c = selected else { status.stringValue = "Pick a chat first."; return }

        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        status.stringValue = "Sending to \(c.title)…"
        let sent = attachments
        UserDefaults.standard.set(c.session, forKey: "LastChatSession")
        let outgoing = sent.map { (Prefs.load().shrink ? Media.sendable($0.0) : $0.0, $0.1) }
        onSend?(c, text, outgoing) { [weak self] note in
            if note.hasPrefix("Delivered") || note.hasPrefix("Sent") { sent.forEach { History.log(shot: $0.0, chat: c) } }
            guard let self else { return }
            self.status.stringValue = note
            if note.hasPrefix("Sent") || note.hasPrefix("Delivered") {
                self.composer.string = ""
                self.attachments = []
                self.buildChips()
                self.relayout()
            }
        }
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { tv.insertNewlineIgnoringFieldEditor(nil) }
            else { sendTapped() }
            return true
        }
        return false
    }
}
