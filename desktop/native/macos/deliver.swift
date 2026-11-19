// shotdock-deliver: put a message (and images) into the Claude Code chat box that is open in the front editor
// window, press Return, and go back to the app the person was in. Reads JSON on stdin:
//   {"bundle":"com.todesktop.230313mzl4w4u92","text":"…","images":["/path.png"],"returnTo":12345}
// Writes JSON: {"ok":true} or {"ok":false,"error":"draft"|"no_box"|"accessibility"|"paste"|"…"}.
// Safety: never types into a box that already holds text; restores the clipboard; checks the box after pasting.

import Cocoa
import ApplicationServices

func out(_ d: [String: Any]) -> Never {
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
guard focusedPid() == app.processIdentifier else { out(["ok": false, "error": "editor did not come forward"]) }

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
    if let b = focusedBox() { box = b; break }
    if focusedPid() != app.processIdentifier { app.activate(); usleep(300_000) }
    key(8, [.maskControl, .maskAlternate, .maskCommand])          // Ctrl+Opt+Cmd+C -> claude-vscode.focus
    usleep(i < 3 ? 400_000 : 700_000)
}
guard let target = box else { out(["ok": false, "error": "no_box"]) }
let draft = (attr(target, kAXValueAttribute) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
if dryRun {   // checks only: found the box, report whether it holds a draft; nothing typed
    if let pid = returnTo, let back = NSRunningApplication(processIdentifier: pid_t(pid)) { back.activate() }
    out(["ok": true, "dryRun": true, "draftChars": draft.count])
}
guard draft.isEmpty else { out(["ok": false, "error": "draft"]) }

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
    let now = attr(target, kAXValueAttribute) as? String ?? ""
    let probe = String(text.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
    if !probe.isEmpty && !now.contains(probe) { restore(); out(["ok": false, "error": "paste"]) }
}
key(36)                                                             // Return: send
usleep(250_000)
restore()
if let pid = returnTo, let back = NSRunningApplication(processIdentifier: pid_t(pid)) { back.activate() }
out(["ok": true])
