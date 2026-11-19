// Element picker: hover highlights the element under the mouse (any app, Cursor panes included),
// Up and Down widen or narrow it, click takes it. Dragging draws a free box instead. Esc cancels.

import Cocoa

final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class PickerView: NSView {
    private let screenFrame: NSRect
    private var chain: [AXUIElement] = []
    private var level = 0
    private var highlight: CGRect?
    private var dragStart: NSPoint?
    private var dragNow: NSPoint?
    private var lastProbe = NSPoint(x: -999, y: -999)
    var onDone: ((CGRect?) -> Void)?
    /// true: hover picks an element. false: drag a free area only.
    var elementMode = true
    var windowMode = false
    var currentElement: AXUIElement? { chain.indices.contains(level) ? chain[level] : nil }

    init(screenFrame: NSRect) {
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func toGlobal(_ p: NSPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: mainScreenHeight - (screenFrame.minY + p.y))
    }

    private func toView(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX - screenFrame.minX, y: mainScreenHeight - r.maxY - screenFrame.minY, width: r.width, height: r.height)
    }

    private var dragRect: NSRect? {
        guard !elementMode, let a = dragStart, let b = dragNow, hypot(a.x - b.x, a.y - b.y) > 6 else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func probe(at p: NSPoint) {
        guard hypot(p.x - lastProbe.x, p.y - lastProbe.y) > 4 else { return }
        lastProbe = p
        let g = toGlobal(p)
        chain = []
        highlight = nil
        defer { needsDisplay = true }
        guard let owner = windowUnder(g) else { return }
        if windowMode {   // whole window under the mouse
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerPID as String] as? pid_t) == owner.pid {
                if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
                    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                    if r.contains(g) { highlight = r; return }
                }
            }
            return
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(axApp(owner.pid), Float(g.x), Float(g.y), &hit) == .success, var cur = hit
        else { return }
        chain = [cur]
        while chain.count < 40, let parent = axElement(axAttr(cur, kAXParentAttribute)) {
            chain.append(parent)
            cur = parent
        }
        level = 0
        // Skip slivers (text runs, icons) so the first highlight is a block worth sending.
        while level < chain.count - 1, let f = axFrame(chain[level]), f.width < 60 || f.height < 30 { level += 1 }
        highlight = axFrame(chain[level])
    }

    private func setLevel(_ n: Int) {
        guard !chain.isEmpty else { return }
        level = max(0, min(chain.count - 1, n))
        highlight = axFrame(chain[level])
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { if elementMode { probe(at: convert(e.locationInWindow, from: nil)) } }

    override func mouseDown(with e: NSEvent) {
        dragStart = convert(e.locationInWindow, from: nil)
        dragNow = dragStart
    }

    override func mouseDragged(with e: NSEvent) {
        dragNow = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        dragNow = convert(e.locationInWindow, from: nil)
        if let r = dragRect, r.width > 20, r.height > 20 {
            let a = toGlobal(NSPoint(x: r.minX, y: r.maxY))
            onDone?(CGRect(x: a.x, y: a.y, width: r.width, height: r.height))
        } else if let h = highlight {
            onDone?(h)
        }
        dragStart = nil
        dragNow = nil
    }

    override func scrollWheel(with e: NSEvent) {
        if e.scrollingDeltaY > 1 { setLevel(level + 1) } else if e.scrollingDeltaY < -1 { setLevel(level - 1) }
    }

    override func keyDown(with e: NSEvent) { handleKey(Int(e.keyCode)) }

    override func rightMouseDown(with e: NSEvent) { onDone?(nil) }

    func handleKey(_ code: Int) {
        switch code {
        case 53: onDone?(nil)                             // Esc
        case 126: setLevel(level + 1)                     // Up: bigger
        case 125: setLevel(level - 1)                     // Down: smaller
        case 36, 76: if let h = highlight { onDone?(h) }  // Return
        default: break
        }
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        let box = dragRect ?? highlight.map(toView)
        if let box {
            NSColor.systemTeal.withAlphaComponent(0.10).setFill()
            box.fill(using: .copy)
            NSColor.systemTeal.setStroke()
            let path = NSBezierPath(rect: box.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            let size = "\(Int(box.width)) × \(Int(box.height))" as NSString
            size.draw(at: NSPoint(x: box.minX + 6, y: max(box.minY - 20, 4)),
                      withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                       .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemTeal])
        }
        let hint = (windowMode ? "  WINDOW  ·  Hover a window and click it.  Esc: cancel.  " : elementMode
            ? "  ELEMENT  ·  Hover and click to take it.  ↑ ↓ or scroll: bigger / smaller.  Esc: cancel.  "
            : "  SCREENSHOT  ·  Drag a box.  Esc: cancel.  ") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                    .foregroundColor: NSColor.white,
                                                    .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
        let w = hint.size(withAttributes: attrs).width
        hint.draw(at: NSPoint(x: (bounds.width - w) / 2, y: bounds.height - 70), withAttributes: attrs)
    }
}

/// Shows the picker on the screen under the mouse and reports the chosen rectangle (top-left global points).
final class Picker {
    private var window: NSWindow?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private weak var view: PickerView?
    private var timeout: DispatchWorkItem?

    /// While the picker is up, every key press goes to it and nowhere else (Esc must not reach Cursor).
    private func startKeyTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let picker = Unmanaged<Picker>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = picker.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                DispatchQueue.main.async { picker.view?.handleKey(code) }
            }
            return nil
        }, userInfo: me)
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func stopKeyTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    func run(element: Bool, window wholeWindow: Bool = false, _ done: @escaping (CGRect?, String?) -> Void) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return done(nil, nil) }
        let previous = NSWorkspace.shared.frontmostApplication
        let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.acceptsMouseMovedEvents = true
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PickerView(screenFrame: screen.frame)
        v.elementMode = element || wholeWindow
        v.windowMode = wholeWindow
        w.contentView = v
        window = w
        view = v
        var finished = false
        v.onDone = { [weak self] r in
            guard !finished else { return }
            finished = true
            self?.timeout?.cancel()
            self?.stopKeyTap()
            let info = (element && !wholeWindow && r != nil) ? v.currentElement.map { describe($0, rect: r!) } : nil
            w.orderOut(nil)
            self?.window = nil
            previous?.activate()
            done(r, info)
        }
        startKeyTap()
        let t = DispatchWorkItem { [weak v] in v?.onDone?(nil) }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: t)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        let local = w.convertPoint(fromScreen: NSEvent.mouseLocation)
        v.probe(at: local)
    }
}


/// What the agent needs to find this element: type, DOM id and classes, text, page URL, app and window.
func describe(_ e: AXUIElement, rect: CGRect) -> String {
    func str(_ a: String) -> String { (axAttr(e, a) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var parts: [String] = []
    let role = str(kAXRoleDescriptionAttribute).isEmpty ? str(kAXRoleAttribute) : str(kAXRoleDescriptionAttribute)
    parts.append("Element: \(role)")
    let domID = str("AXDOMIdentifier")
    if !domID.isEmpty { parts.append("id: #\(domID)") }
    if let classes = axAttr(e, "AXDOMClassList") as? [String], !classes.isEmpty {
        parts.append("classes: ." + classes.prefix(8).joined(separator: " ."))
    }
    var text = [str(kAXTitleAttribute), str(kAXDescriptionAttribute), str(kAXValueAttribute)].filter { !$0.isEmpty }
        .joined(separator: " | ")
    if text.isEmpty {   // a container: gather the text of its first children
        var bits: [String] = []
        var queue: [AXUIElement] = [e]
        while !queue.isEmpty && bits.joined().count < 300 {
            let n = queue.removeFirst()
            if let v = axAttr(n, kAXValueAttribute) as? String, !v.isEmpty { bits.append(v) }
            else if let t = axAttr(n, kAXTitleAttribute) as? String, !t.isEmpty { bits.append(t) }
            queue += (axAttr(n, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(30)
        }
        text = bits.joined(separator: " ")
    }
    if !text.isEmpty { parts.append("text: \"\(text.prefix(300))\"") }
    var cur: AXUIElement? = e
    for _ in 0..<40 {   // nearest web page around it
        guard let c = cur else { break }
        if (axAttr(c, kAXRoleAttribute) as? String) == "AXWebArea", let u = axAttr(c, "AXURL") {
            parts.append("page: \(u)")
            break
        }
        cur = axElement(axAttr(c, kAXParentAttribute))
    }
    if let w = windowUnder(CGPoint(x: rect.midX, y: rect.midY)) {
        parts.append("in: \(w.owner)\(w.title.isEmpty ? "" : " — \(w.title)")")
    }
    parts.append("size: \(Int(rect.width))×\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")
    return parts.joined(separator: "\n")
}
