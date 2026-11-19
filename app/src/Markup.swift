// Markup: annotate a screenshot before it goes to a chat.
// Tools: Box, Arrow, Pin (numbered 1, 2, 3 to match your message), Text, Highlight, Blur. Undo, Auto-blur
// (emails, money, phone numbers, company numbers, keys), Done saves over the file.

import Cocoa

enum MarkTool: Int { case box, arrow, pin, text, highlight, blur }

struct Mark {
    let tool: MarkTool
    let a: NSPoint
    let b: NSPoint
    var text: String = ""
    var number: Int = 0
}

final class MarkupView: NSView {
    let image: NSImage
    var marks: [Mark] = []
    var tool: MarkTool = .box
    var askText: ((@escaping (String) -> Void) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    var fitted: NSRect = .zero

    init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Draws marks in whatever coordinate space `map` converts view points into.
    func drawMarks(_ list: [Mark], scale: CGFloat, map: (NSPoint) -> NSPoint) {
        for m in list {
            let a = map(m.a), b = map(m.b)
            let lw = 3 * scale
            switch m.tool {
            case .box:
                NSColor.systemRed.setStroke()
                let p = NSBezierPath(rect: rect(a, b)); p.lineWidth = lw; p.stroke()
            case .highlight:
                NSColor.systemYellow.withAlphaComponent(0.35).setFill()
                rect(a, b).fill(using: .sourceOver)
            case .blur:
                NSColor(white: 0.15, alpha: 0.92).setFill()
                rect(a, b).fill()
            case .arrow:
                NSColor.systemRed.set()
                let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = lw; p.stroke()
                let ang = atan2(b.y - a.y, b.x - a.x), len = 16 * scale
                let head = NSBezierPath()
                head.move(to: b)
                head.line(to: NSPoint(x: b.x - len * cos(ang - 0.45), y: b.y - len * sin(ang - 0.45)))
                head.line(to: NSPoint(x: b.x - len * cos(ang + 0.45), y: b.y - len * sin(ang + 0.45)))
                head.close(); head.fill()
            case .pin:
                let r = 13 * scale
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)).fill()
                let s = "\(m.number)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 14 * scale), .foregroundColor: NSColor.white]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: a.x - sz.width / 2, y: a.y - sz.height / 2), withAttributes: attrs)
            case .text:
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 16 * scale),
                                                            .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemRed]
                (" \(m.text) " as NSString).draw(at: a, withAttributes: attrs)
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let s = image.size
        let scale = min(bounds.width / max(s.width, 1), bounds.height / max(s.height, 1))
        fitted = NSRect(x: (bounds.width - s.width * scale) / 2, y: (bounds.height - s.height * scale) / 2,
                        width: s.width * scale, height: s.height * scale)
        image.draw(in: fitted)
        var list = marks
        if let a = start, let b = current, [.box, .arrow, .highlight, .blur].contains(tool) { list.append(Mark(tool: tool, a: a, b: b)) }
        drawMarks(list, scale: 1) { $0 }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .pin:
            marks.append(Mark(tool: .pin, a: p, b: p, number: marks.filter { $0.tool == .pin }.count + 1))
            needsDisplay = true
        case .text:
            askText? { [weak self] text in
                guard !text.isEmpty else { return }
                self?.marks.append(Mark(tool: .text, a: p, b: p, text: text))
                self?.needsDisplay = true
            }
        default:
            start = p
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard start != nil else { return }
        current = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if let a = start, let b = current, hypot(a.x - b.x, a.y - b.y) > 6 { marks.append(Mark(tool: tool, a: a, b: b)) }
        start = nil
        current = nil
        needsDisplay = true
    }

    /// The image with every mark burned in, at full resolution.
    func rendered() -> NSImage {
        let s = image.size
        let scale = s.width / max(fitted.width, 1)
        let out = NSImage(size: s)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: s))
        drawMarks(marks, scale: scale) { NSPoint(x: ($0.x - self.fitted.minX) * scale, y: ($0.y - self.fitted.minY) * scale) }
        out.unlockFocus()
        return out
    }
}

final class MarkupPanel: NSObject {
    let window: NSPanel
    private let view: MarkupView
    private let url: URL
    private let tools = NSSegmentedControl(labels: ["Box", "Arrow", "Pin", "Text", "Highlight", "Blur"], trackingMode: .selectOne,
                                           target: nil, action: nil)
    var onDone: (() -> Void)?

    init?(url: URL) {
        guard let img = NSImage(contentsOf: url) else { return nil }
        self.url = url
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        view = MarkupView(image: img, frame: NSRect(x: 0, y: 44, width: 1000, height: 656))
        super.init()
        window.title = "Mark up the screenshot"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        view.autoresizingMask = [.width, .height]
        view.askText = { [weak self] done in self?.askForText(done) }
        window.contentView?.addSubview(view)
        tools.selectedSegment = 0
        tools.target = self
        tools.action = #selector(toolChanged)
        tools.frame = NSRect(x: 10, y: 9, width: 420, height: 26)
        window.contentView?.addSubview(tools)
        let buttons: [(String, Selector)] = [("Auto-blur", #selector(autoBlur)), ("Undo", #selector(undo)),
                                             ("Cancel", #selector(cancel)), ("Done", #selector(save))]
        for (i, (title, sel)) in buttons.enumerated() {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            let bx: CGFloat = 1000 - 4 * 96 - 6 + CGFloat(i) * 96
            b.frame = NSRect(x: bx, y: 8, width: 90, height: 28)
            b.autoresizingMask = [.minXMargin]
            if title == "Done" { b.keyEquivalent = "\r" }
            window.contentView?.addSubview(b)
        }
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func askForText(_ done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "Label text"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = field
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        done(a.runModal() == .alertFirstButtonReturn ? field.stringValue : "")
    }

    @objc private func toolChanged() { view.tool = MarkTool(rawValue: tools.selectedSegment) ?? .box }
    @objc private func undo() { if !view.marks.isEmpty { view.marks.removeLast(); view.needsDisplay = true } }
    @objc private func cancel() { window.orderOut(nil) }

    /// Cover every email, money amount, phone number, company number and key the text reader finds.
    @objc private func autoBlur() {
        let rects = Media.sensitiveBoxes(url)
        guard !rects.isEmpty, let rep = view.image.representations.first else { return }
        let pxW = CGFloat(rep.pixelsWide), pxH = CGFloat(rep.pixelsHigh)
        let f = view.fitted
        for r in rects {   // pixels (top-left) -> view points
            let a = NSPoint(x: f.minX + r.minX / pxW * f.width, y: f.minY + (1 - r.maxY / pxH) * f.height)
            let b = NSPoint(x: f.minX + r.maxX / pxW * f.width, y: f.minY + (1 - r.minY / pxH) * f.height)
            view.marks.append(Mark(tool: .blur, a: a, b: b))
        }
        view.needsDisplay = true
    }

    @objc private func save() {
        let img = view.rendered()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
        onDone?()
    }
}
