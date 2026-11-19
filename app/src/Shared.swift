// Shared helpers: paths, Cursor windows, accessibility, screen capture.

import Cocoa

let home = FileManager.default.homeDirectoryForCurrentUser
let shotsDir = home.appendingPathComponent("Screenshots")
/// ShotDock's own captures live here, so the Claude Code hook (which reads only the top level) never
/// attaches them a second time.
let sentDir = shotsDir.appendingPathComponent("sent")
let stateFile = home.appendingPathComponent(".claude/state/last_screenshot_check")
let cursorBundle = "com.todesktop.230313mzl4w4u92"

/// One Cursor workspace window, from the window server (works across full-screen Spaces).
struct CursorWindow: Equatable {
    let id: CGWindowID
    let workspace: String
    let onScreen: Bool
}

func workspaceName(fromTitle title: String) -> String? {
    guard !title.isEmpty, title != "Cursor Agents" else { return nil }
    if let r = title.range(of: " — ", options: .backwards) { return String(title[r.upperBound...]) }
    return title
}

func cursorWindows() -> [CursorWindow] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [CursorWindow] = []
    var seen = Set<String>()
    for w in list {
        guard (w[kCGWindowOwnerName as String] as? String) == "Cursor", (w[kCGWindowLayer as String] as? Int) == 0,
              let ws = workspaceName(fromTitle: w[kCGWindowName as String] as? String ?? ""),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 200,
              !seen.contains(ws) else { continue }
        seen.insert(ws)
        out.append(CursorWindow(id: w[kCGWindowNumber as String] as? CGWindowID ?? 0, workspace: ws,
                                onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false))
    }
    return out
}

/// The front-most normal window under a point (top-left global coordinates), ignoring ShotDock itself.
func windowUnder(_ p: CGPoint) -> (pid: pid_t, owner: String, title: String)? {
    let me = ProcessInfo.processInfo.processIdentifier
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.contains(p) {
            return (pid, w[kCGWindowOwnerName as String] as? String ?? "", w[kCGWindowName as String] as? String ?? "")
        }
    }
    return nil
}

// MARK: accessibility

func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func axElement(_ v: AnyObject?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

/// Element frame in top-left global coordinates.
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return size.width > 0 && size.height > 0 ? CGRect(origin: pos, size: size) : nil
}

private var axEnabled = Set<pid_t>()

/// Electron apps (Cursor) only build their accessibility tree when asked.
func axApp(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    if !axEnabled.contains(pid) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        axEnabled.insert(pid)
    }
    return app
}

// MARK: coordinates and capture

var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

func newShotURL() -> URL {
    try? FileManager.default.createDirectory(at: sentDir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return sentDir.appendingPathComponent("shot-\(f.string(from: Date())).png")
}

/// Captures a rectangle in top-left global points. Returns the file, or nil if nothing was written.
func captureRect(_ r: CGRect) -> URL? {
    let url = newShotURL()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path]
    try? p.run()
    p.waitUntilExit()
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}


/// Folders (relative to home) searched for a Cursor workspace by name. ~/.duraloop/config.json "project_roots".
var projectRoots: [String] {
    let cfg = (try? Data(contentsOf: home.appendingPathComponent(".duraloop/config.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    return cfg?["project_roots"] as? [String] ?? ["Desktop", "", "Documents", "Developer", "Projects", "Code"]
}
