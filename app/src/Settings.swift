// Settings window: API keys (saved to the macOS Keychain, shown masked), the claim checker's provider and model,
// DuraLoop mode and server, and capture options. Non-secret settings go to ~/.duraloop/config.json.

import Cocoa

final class SettingsPanel: NSObject {
    let window: NSPanel
    private var prefs = Prefs.load()
    private let deepseek = NSSecureTextField()
    private let anthropic = NSSecureTextField()
    private let openai = NSSecureTextField()
    private let ingest = NSSecureTextField()
    private let provider = NSPopUpButton()
    private let model = NSComboBox()
    private let mode = NSPopUpButton()
    private let server = NSTextField()
    private let readText = NSButton(checkboxWithTitle: "Read the text in each shot and send it along", target: nil, action: nil)
    private let autoBlur = NSButton(checkboxWithTitle: "Blur emails, money, phone numbers and keys automatically", target: nil, action: nil)
    private let shrink = NSButton(checkboxWithTitle: "Shrink shots before sending (fewer tokens)", target: nil, action: nil)
    private let seconds = NSStepper()
    private let secondsLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    var onSaved: (() -> Void)?

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "ShotDock settings"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let v = window.contentView!
        var y: CGFloat = 520
        func heading(_ t: String) {
            let l = NSTextField(labelWithString: t)
            l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            l.frame = NSRect(x: 20, y: y, width: 500, height: 18)
            v.addSubview(l)
            y -= 28
        }
        func row(_ label: String, _ field: NSView, note: String? = nil) {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.frame = NSRect(x: 20, y: y + 3, width: 150, height: 18)
            v.addSubview(l)
            field.frame = NSRect(x: 180, y: y, width: 350, height: 24)
            v.addSubview(field)
            y -= note == nil ? 32 : 26
            if let note {
                let n = NSTextField(labelWithString: note)
                n.font = NSFont.systemFont(ofSize: 10.5)
                n.textColor = .secondaryLabelColor
                n.frame = NSRect(x: 180, y: y + 6, width: 350, height: 14)
                v.addSubview(n)
                y -= 16
            }
        }
        heading("API keys (stored in your Keychain, never in a file)")
        for (f, k) in [(deepseek, "deepseek"), (anthropic, "anthropic"), (openai, "openai"), (ingest, "duraloop-ingest")] {
            f.placeholderString = Keys.get(k) == nil ? "not set" : "saved, type to replace"
        }
        row("DeepSeek", deepseek, note: "Used by the claim checker. platform.deepseek.com → API keys")
        row("Anthropic", anthropic)
        row("OpenAI", openai)
        row("DuraLoop ingest key", ingest, note: "Only for syncing to a DuraLoop server")
        heading("Claim checker")
        provider.addItems(withTitles: ["deepseek", "anthropic", "openai"])
        provider.selectItem(withTitle: prefs.checkProvider)
        row("Provider", provider)
        model.addItems(withObjectValues: ["deepseek-chat", "deepseek-reasoner", "claude-haiku-5-5", "claude-sonnet-5-5", "gpt-5-mini"])
        model.stringValue = prefs.checkModel
        row("Model", model)
        heading("DuraLoop")
        mode.addItems(withTitles: ["local", "org", "self-hosted"])
        mode.selectItem(withTitle: prefs.mode)
        row("Mode", mode, note: "local keeps everything on this Mac")
        server.stringValue = prefs.server
        server.placeholderString = "https://your-duraloop-server"
        row("Server", server)
        heading("Capture")
        for (b, on) in [(readText, prefs.readText), (autoBlur, prefs.autoBlur), (shrink, prefs.shrink)] {
            b.state = on ? .on : .off
            b.frame = NSRect(x: 180, y: y, width: 360, height: 20)
            v.addSubview(b)
            y -= 24
        }
        seconds.minValue = 5
        seconds.maxValue = 30
        seconds.integerValue = prefs.recordSeconds
        seconds.target = self
        seconds.action = #selector(stepped)
        secondsLabel.frame = NSRect(x: 180, y: y + 2, width: 200, height: 18)
        seconds.frame = NSRect(x: 380, y: y, width: 20, height: 24)
        v.addSubview(secondsLabel)
        v.addSubview(seconds)
        stepped()
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 450, y: 14, width: 90, height: 30)
        v.addSubview(save)
        status.frame = NSRect(x: 20, y: 20, width: 420, height: 18)
        status.textColor = .secondaryLabelColor
        v.addSubview(status)
        window.center()
    }

    @objc private func stepped() { secondsLabel.stringValue = "Recording length: \(seconds.integerValue) seconds" }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func saveTapped() {
        var saved: [String] = []
        for (f, k) in [(deepseek, "deepseek"), (anthropic, "anthropic"), (openai, "openai"), (ingest, "duraloop-ingest")] {
            let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty, Keys.set(k, v) { saved.append(k); f.stringValue = ""; f.placeholderString = "saved, type to replace" }
        }
        prefs.checkProvider = provider.titleOfSelectedItem ?? "deepseek"
        prefs.checkModel = model.stringValue
        prefs.mode = mode.titleOfSelectedItem ?? "local"
        prefs.server = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.readText = readText.state == .on
        prefs.autoBlur = autoBlur.state == .on
        prefs.shrink = shrink.state == .on
        prefs.recordSeconds = seconds.integerValue
        prefs.save()
        status.stringValue = "Saved" + (saved.isEmpty ? "." : ". Keys stored in Keychain: " + saved.joined(separator: ", "))
        onSaved?()
    }
}

/// Recent shots and the chat each went to. Click one to attach it to the open chat in the hub.
final class HistoryPanel: NSObject {
    let window: NSPanel
    var onPick: ((URL) -> Void)?
    private var items: [(URL, String)] = []

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Shot history: click one to attach it again"
        window.level = .floating
        window.isReleasedWhenClosed = false
    }

    func show() {
        items = History.recent(40)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let cols = 4, cell: CGFloat = 150, gap: CGFloat = 8
        let rowsN = (items.count + cols - 1) / cols
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 620, height: CGFloat(rowsN) * (cell + 28) + gap))
        for (i, item) in items.enumerated() {
            let x = gap + CGFloat(i % cols) * (cell + gap), y = gap + CGFloat(i / cols) * (cell + 28)
            let b = NSButton(frame: NSRect(x: x, y: y, width: cell, height: cell * 0.66))
            b.image = NSImage(contentsOf: item.0)
            b.imageScaling = .scaleProportionallyUpOrDown
            b.isBordered = false
            b.tag = i
            b.target = self
            b.action = #selector(picked(_:))
            b.toolTip = item.1
            doc.addSubview(b)
            let l = NSTextField(labelWithString: item.1)
            l.font = NSFont.systemFont(ofSize: 10)
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: x, y: y + cell * 0.66 + 2, width: cell, height: 14)
            doc.addSubview(l)
        }
        if items.isEmpty {
            let l = NSTextField(labelWithString: "No shots sent yet.")
            l.frame = NSRect(x: 20, y: 20, width: 300, height: 20)
            doc.addSubview(l)
        }
        scroll.documentView = doc
        window.contentView = scroll
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func picked(_ b: NSButton) {
        guard items.indices.contains(b.tag) else { return }
        onPick?(items[b.tag].0)
        window.orderOut(nil)
    }
}
