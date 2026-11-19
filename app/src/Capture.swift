// More ways to capture: whole window, scrolling page, short recording, before/after, one-key send.
// Every capture can have its text read, sensitive text blurred and be shrunk before sending (Settings).

import Cocoa

enum CaptureKind { case area, element, window, scroll, record, oneKey }

extension AppDelegate {
    var prefs: Prefs { Prefs.load() }

    /// Apply the per-capture settings: auto-blur, read text. Returns extra details for the message.
    func finishShot(_ url: URL, info: String?) -> String? {
        if prefs.autoBlur { Media.blur(url, rects: Media.sensitiveBoxes(url)) }
        var parts: [String] = []
        if let info { parts.append(info) }
        if prefs.readText {
            let t = Media.text(url).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append("Text in the screenshot:\n" + String(t.prefix(1500))) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Deliver a finished shot: into the hub's chat box when it is open on a chat, else straight into a chat.
    func route(_ urls: [URL], details: String?) {
        if checks.showingChats && hub.selected != nil {
            for (i, u) in urls.enumerated() { hub.addAttachment(u, i == 0 ? details : nil) }
            finish()
        } else if let first = urls.first {
            shootAndComposeFile(first, more: Array(urls.dropFirst()), info: details)
        }
    }

    @objc func captureWindow() {
        guard !busy else { return }
        busy = true
        checks.hideForCapture(true)
        picker.run(element: false, window: true) { [weak self] rect, _ in
            guard let self, let rect else { self?.finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let url = captureRect(rect) else { self.finish(); return }
                self.route([url], details: self.finishShot(url, info: windowUnder(CGPoint(x: rect.midX, y: rect.midY)).map { "Window: \($0.owner) — \($0.title)" }))
            }
        }
    }

    /// Drag an area; ShotDock scrolls inside it and stitches the frames into one tall image.
    @objc func captureScroll() {
        guard !busy else { return }
        busy = true
        checks.hideForCapture(true)
        picker.run(element: false) { [weak self] rect, _ in
            guard let self, let rect else { self?.finish(); return }
            DispatchQueue.global(qos: .userInitiated).async {
                var frames: [URL] = []
                let center = CGPoint(x: rect.midX, y: rect.midY)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
                for _ in 0..<10 {
                    usleep(350_000)
                    guard let u = captureRect(rect) else { break }
                    if let last = frames.last, let a = Media.cgImage(last), let b = Media.cgImage(u),
                       Media.overlap(a, b) >= b.height - 4 { try? FileManager.default.removeItem(at: u); break }   // reached the end
                    frames.append(u)
                    let lines = Int32(max(3, rect.height * 0.7 / 10))
                    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                }
                let out = Media.stitch(frames)
                frames.forEach { try? FileManager.default.removeItem(at: $0) }
                DispatchQueue.main.async {
                    guard let out else { self.showToast("Scrolling capture failed."); self.finish(); return }
                    self.route([out], details: self.finishShot(out, info: "Scrolling capture, \(frames.count) screens stitched."))
                }
            }
        }
    }

    /// Drag an area; record it, pull key frames and report frozen stretches.
    @objc func captureRecording() {
        guard !busy else { return }
        busy = true
        checks.hideForCapture(true)
        picker.run(element: false) { [weak self] rect, _ in
            guard let self, let rect else { self?.finish(); return }
            let secs = self.prefs.recordSeconds
            self.showToast("Recording \(secs) seconds. Do the thing that breaks.")
            Media.record(rect: rect, seconds: secs) { frames, report in
                guard !frames.isEmpty else { self.showToast("Recording failed."); self.finish(); return }
                self.route(frames, details: report)
            }
        }
    }

    /// First press keeps a "before" of the last area; second press takes "after" and sends both side by side.
    @objc func captureBeforeAfter() {
        guard let rect = lastRect else { showToast("Take a screenshot of the area first, then use Before / after."); return }
        guard !busy else { return }
        if let before = beforeShot {
            busy = true
            checks.hideForCapture(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                defer { self.beforeShot = nil }
                guard let after = captureRect(rect), let pair = Media.beforeAfter(before: before, after: after) else {
                    self.showToast("Before / after failed."); self.finish(); return
                }
                self.route([pair], details: "Before (left) and after (right). Changed pixels are tinted red on the right.")
            }
        } else {
            beforeShot = captureRect(rect)
            showToast("Before saved. Make the change, then choose Before / after again.")
        }
    }

    /// Ctrl+Opt+Q: drag an area and it goes straight to the last chat you sent to, no choosing.
    @objc func captureOneKey() {
        guard !busy else { return }
        guard let last = UserDefaults.standard.string(forKey: "LastChatSession"),
              let chat = ChatStore.list().first(where: { $0.session == last }) else {
            showToast("Send to a chat from the hub once, then one-key send knows where to go.")
            return
        }
        busy = true
        checks.hideForCapture(true)
        picker.run(element: false) { [weak self] rect, _ in
            guard let self, let rect else { self?.finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let url = captureRect(rect) else { self.finish(); return }
                let details = self.finishShot(url, info: nil)
                let send = self.prefs.shrink ? Media.sendable(url) : url
                let go: (ChatInfo, String, [(URL, String?)], @escaping (String) -> Void) -> Void =
                    chat.client == "Cursor" ? { Sender.sendToCursorAgent($0, text: $1, attachments: $2, done: $3) }
                                            : { Sender.sendToChat($0, text: $1, attachments: $2, done: $3) }
                go(chat, "", [(send, details)]) { note in
                    History.log(shot: url, chat: chat)
                    self.showToast(note)
                    self.finish()
                }
            }
        }
    }
}
