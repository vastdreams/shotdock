// shotdock-deliver: put a message (and images) into the Claude Code chat box that is open in the front editor
// window, press Return, and go back to the app the person was in. Reads JSON on stdin:
//   {"bundle":"com.todesktop.230313mzl4w4u92","text":"…","images":["/path.png"],"returnTo":12345}
// Writes JSON: {"ok":true} or {"ok":false,"error":"draft"|"no_box"|"accessibility"|"paste"|"…"}.
// Safety: clears any leftover draft first (replaces it); restores the clipboard; checks the box after pasting.

import Cocoa
import ApplicationServices

// Diagnostics: every reply carries what the helper saw at each step, so a failure in the field can be read back
// from ShotDock's log (~/Library/Application Support/ShotDock/logs/shotdock.log) without reproducing it.
var diag: [String: Any] = [:]
var steps: [String] = []
let t0 = Date()
func step(_ s: String) { steps.append("\(Int(Date().timeIntervalSince(t0) * 1000))ms \(s)") }
func snip(_ s: String) -> String { String(s.prefix(40)).replacingOccurrences(of: "\n", with: "⏎") }
func out(_ d0: [String: Any]) -> Never {
    var d = d0; d["diag"] = diag; d["steps"] = steps; d["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: d)) ?? Data("{\"ok\":false}".utf8))
    exit(0)
}
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

guard AXIsProcessTrusted() else { out(["ok": false, "error": "accessibility"]) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let job = try? JSONSerialization.jsonObject(with: input) as? [String: Any], let bundle = job["bundle"] as? String else {
    out(["ok": false, "error": "bad input"])
}
let text = job["text"] as? String ?? ""
let images = job["images"] as? [String] ?? []
let returnTo = job["returnTo"] as? Int
let dryRun = job["dryRun"] as? Bool ?? false
let expectWindow = (job["window"] as? String ?? "").lowercased()   // the chat's folder name; front window must match
let noReturn = job["noReturn"] as? Bool ?? false                   // tests only: paste, do not send

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { out(["ok": false, "error": "editor not running"]) }
let axApp = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Electron apps expose their tree on request

// The open-session link already revealed the chat; make sure the editor has keyboard focus. Ask the accessibility
// system which app is focused (NSWorkspace's answer goes stale in a helper process without a run loop).
func focusedPid() -> pid_t {
    guard let f = attr(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return 0 }
    var pid: pid_t = 0; AXUIElementGetPid(f as! AXUIElement, &pid); return pid
}
if focusedPid() != app.processIdentifier { app.activate() }
for _ in 0..<30 where focusedPid() != app.processIdentifier { usleep(100_000) }
diag["focusedPid"] = Int(focusedPid()); diag["editorPid"] = Int(app.processIdentifier)
guard focusedPid() == app.processIdentifier else { out(["ok": false, "error": "editor did not come forward"]) }
step("editor focused")
// Never type into the wrong chat: the front editor window must be the chat's own folder.
if !expectWindow.isEmpty {
    var title = ""
    for _ in 0..<20 {
        if let w = attr(axApp, kAXFocusedWindowAttribute) { title = (attr(w as! AXUIElement, kAXTitleAttribute) as? String ?? "").lowercased() }
        if title.contains(expectWindow) { break }
        usleep(150_000)
    }
    diag["windowTitle"] = String(title.prefix(80)); diag["expectWindow"] = expectWindow
    guard title.contains(expectWindow) else { out(["ok": false, "error": "wrong_window"]) }
    step("window ok")
}

func focusedBox() -> AXUIElement? {
    guard let f = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
    let el = f as! AXUIElement
    let role = attr(el, kAXRoleAttribute) as? String ?? ""
    let desc = (attr(el, kAXDescriptionAttribute) as? String ?? "").lowercased()
    return role == "AXTextArea" && desc.contains("message input") ? el : nil
}
var box: AXUIElement?
// The chat may still be loading (just opened from its link): keep trying for up to ~10 s.
for i in 0..<14 {
    if let b = focusedBox() { box = b; diag["boxTries"] = i + 1; break }
    if focusedPid() != app.processIdentifier { app.activate(); usleep(300_000) }
    key(8, [.maskControl, .maskAlternate, .maskCommand])          // Ctrl+Opt+Cmd+C -> claude-vscode.focus
    usleep(i < 3 ? 400_000 : 700_000)
}
if box == nil, let f = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
    let el = f as! AXUIElement   // what had focus instead, to see why the box wasn't recognised
    diag["focusedRole"] = attr(el, kAXRoleAttribute) as? String ?? ""
    diag["focusedDesc"] = String((attr(el, kAXDescriptionAttribute) as? String ?? "").prefix(60))
}
guard let target = box else { out(["ok": false, "error": "no_box"]) }
step("box found")
let draftRaw = attr(target, kAXValueAttribute) as? String ?? ""
let draft = draftRaw.trimmingCharacters(in: .whitespacesAndNewlines)
diag["boxBefore"] = snip(draftRaw); diag["boxBeforeLen"] = (draftRaw as NSString).length
if dryRun {   // checks only: found the box, report whether it holds a draft; nothing typed
    if let pid = returnTo, let back = NSRunningApplication(processIdentifier: pid_t(pid)) { back.activate() }
    out(["ok": true, "dryRun": true, "draftChars": draft.count])
}
// Operator, 20 Nov 2026: whatever is in the box never blocks a send; it is cleared first. Cursor's Claude box
// ignores Cmd+A, so: jump to the end, select to the start, delete. Twice, for drafts longer than the view.
func boxValue() -> String { attr(target, kAXValueAttribute) as? String ?? "" }
// Cursor's Claude box reports a grey label ("Ask Claude to edit…", "Queue another message…") as its value when
// empty, and the real text otherwise. The only reliable emptiness test: type one letter; an empty box then holds
// exactly that letter. Leftover text is removed with forward-delete and backspace (the caret can be anywhere).
func emptyByProbe() -> Bool {
    key(7); usleep(250_000)                                          // "x"
    let v = boxValue()
    key(51); usleep(150_000)                                         // take it back out
    var probes = diag["probes"] as? [String] ?? []; probes.append(snip(v)); diag["probes"] = probes
    return v == "x"
}
func clearBox() -> Bool {
    // Tested on Cursor's box (20 Nov 2026): Cmd+A is ignored; Cmd+Delete clears to the line start; single deletes
    // work when spaced 25 ms or more (faster ones are dropped).
    for attempt in 0..<3 {
        diag["clearAttempts"] = attempt
        if emptyByProbe() { return true }
        let text = boxValue()
        let lines = max(1, text.components(separatedBy: "\n").count)
        if attempt < 2 {
            for _ in 0...lines {
                key(51, .maskCommand); usleep(40_000)                // Cmd+Delete: to the line start
                key(117, .maskCommand); usleep(40_000)               // Cmd+Fn+Delete: to the line end
                key(51); usleep(40_000); key(117); usleep(40_000)    // join the next line in
            }
        } else {
            let n = (text as NSString).length + 2
            for _ in 0..<n { key(51); usleep(25_000) }
            for _ in 0..<n { key(117); usleep(25_000) }
        }
        usleep(200_000)
    }
    return emptyByProbe()
}
let cleared = clearBox()
diag["boxAfterClear"] = snip(boxValue())
guard cleared else { out(["ok": false, "error": "draft"]) }
step("box clear")

// Keep whatever the person had copied.
let pb = NSPasteboard.general
let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
    var d: [NSPasteboard.PasteboardType: Data] = [:]
    for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
    return d
}
func restore() {
    pb.clearContents()
    let items = saved.map { d -> NSPasteboardItem in let i = NSPasteboardItem(); for (t, v) in d { i.setData(v, forType: t) }; return i }
    if !items.isEmpty { pb.writeObjects(items) }
}

for path in images {
    guard let img = NSImage(contentsOfFile: path) else { continue }
    pb.clearContents(); pb.writeObjects([img])
    key(9, .maskCommand); usleep(700_000)
}
if !text.isEmpty {
    pb.clearContents(); pb.setString(text, forType: .string)
    key(9, .maskCommand); usleep(350_000)
    // The box is empty now, so after the paste it must hold our text; anything else means the paste missed.
    var now = attr(target, kAXValueAttribute) as? String ?? ""
    let probe = String(text.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<6 where !probe.isEmpty && !now.contains(probe) { usleep(250_000); now = attr(target, kAXValueAttribute) as? String ?? "" }
    diag["afterPaste"] = snip(now); diag["afterPasteLen"] = (now as NSString).length
    if !probe.isEmpty && !now.contains(probe) { restore(); out(["ok": false, "error": "paste"]) }
    step("pasted")
}
if noReturn { restore(); out(["ok": true, "noReturn": true]) }
key(36)                                                             // Return: send
usleep(250_000)
diag["boxAfterSend"] = snip(attr(target, kAXValueAttribute) as? String ?? "")   // should be empty or the grey label
step("return pressed")
restore()
if let pid = returnTo, let back = NSRunningApplication(processIdentifier: pid_t(pid)) { back.activate() }
out(["ok": true])
