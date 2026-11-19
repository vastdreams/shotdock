// Composer: the screenshot on top, the message under it, and which Claude chat it goes to.
// Return sends, Shift+Return is a new line, Esc cancels.

import Cocoa

final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Composer: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let window: ComposerPanel
    private let text = NSTextView()
    private let target = NSPopUpButton()
    private let enter = NSButton(checkboxWithTitle: "Send it straight away", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let targets: [CursorWindow]
    private var finished = false
    var onSend: ((String, CursorWindow, Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(image url: URL, targets: [CursorWindow], preferred: String?, info: String? = nil) {
        self.targets = targets
        let img = NSImage(contentsOf: url) ?? NSImage()
        let width: CGFloat = 580
        let inner = width - 32
        let ratio = img.size.width > 0 ? img.size.height / img.size.width : 0.6
        let imgH = min(360, max(120, inner * ratio))
        let infoH: CGFloat = info == nil ? 0 : 74
        let height = 16 + imgH + infoH + 12 + 26 + 10 + 96 + 12 + 30 + 16
        window = ComposerPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Send to Claude"
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = window.contentView!

        var y = height - 28 - imgH
        let iv = NSImageView(frame: NSRect(x: 16, y: y, width: inner, height: imgH))
        iv.image = img
        iv.imageScaling = .scaleProportionallyDown
        iv.wantsLayer = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor
        iv.layer?.cornerRadius = 6
        root.addSubview(iv)

        if let info {
            y -= infoH
            let box = NSTextField(wrappingLabelWithString: info.replacingOccurrences(of: "\n", with: "   ·   "))
            box.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            box.textColor = .secondaryLabelColor
            box.maximumNumberOfLines = 5
            box.frame = NSRect(x: 16, y: y + 4, width: inner, height: infoH - 8)
            root.addSubview(box)
        }

        y -= 12 + 26
        let to = NSTextField(labelWithString: "To:")
        to.frame = NSRect(x: 16, y: y + 4, width: 28, height: 18)
        root.addSubview(to)
        target.frame = NSRect(x: 46, y: y, width: inner - 30, height: 26)
        if preferred == nil { target.addItem(withTitle: "Choose the Claude chat…") }
        for t in targets { target.addItem(withTitle: "Claude in \(t.workspace)") }
        if let p = preferred, let i = targets.firstIndex(where: { $0.workspace == p }) { target.selectItem(at: i) }
        target.target = self
        target.action = #selector(targetChanged)
        root.addSubview(target)

        y -= 10 + 96
        let scroll = NSScrollView(frame: NSRect(x: 16, y: y, width: inner, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.frame = scroll.contentView.bounds
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.delegate = self
        scroll.documentView = text
        root.addSubview(scroll)

        y -= 12 + 30
        enter.frame = NSRect(x: 16, y: y + 4, width: 220, height: 22)
        enter.state = .on
        root.addSubview(enter)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: width - 16 - 190, y: y, width: 90, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        root.addSubview(cancel)
        sendButton.frame = NSRect(x: width - 16 - 94, y: y, width: 94, height: 30)
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.bezelColor = .systemTeal
        root.addSubview(sendButton)
        targetChanged()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let f = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        // macOS may refuse to hand keyboard focus to a background helper. A real click on the message box always
        // works, so if focus did not arrive, click it once for the operator and put the mouse back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.window.isKeyWindow, let content = self.window.contentView,
                  let box = self.text.enclosingScrollView else { return }
            let local = content.convert(NSRect(x: box.frame.midX, y: box.frame.midY, width: 1, height: 1), to: nil)
            let screenPt = self.window.convertToScreen(local).origin
            let target = CGPoint(x: screenPt.x, y: mainScreenHeight - screenPt.y)
            let back = CGEvent(source: nil)?.location ?? target
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            self.window.makeFirstResponder(self.text)
        }
    }

    private var chosen: CursorWindow? {
        let i = target.indexOfSelectedItem - (target.numberOfItems > targets.count ? 1 : 0)
        return targets.indices.contains(i) ? targets[i] : nil
    }

    @objc private func targetChanged() { sendButton.isEnabled = chosen != nil }

    @objc private func send() {
        guard let t = chosen, !finished else { NSSound.beep(); return }
        finished = true
        window.orderOut(nil)
        onSend?(text.string.trimmingCharacters(in: .whitespacesAndNewlines), t, enter.state == .on)
    }

    @objc private func cancel() {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        onCancel?()
    }

    func windowWillClose(_ notification: Notification) { cancel() }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                tv.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send()
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}
