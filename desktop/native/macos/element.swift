// shotdock-element: describe the UI element under the mouse, as JSON on stdout.
// {"ok":true,"app":"Cursor","window":"…","role":"AXButton","title":"…","desc":"…","value":"…","url":"…",
//  "frame":{"x":..,"y":..,"w":..,"h":..}}   or {"ok":false,"error":"accessibility"} when not trusted.
// Coordinates are global, top-left origin (what `screencapture -R` takes).

import Cocoa
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? {
    if let s = attr(e, name) as? String, !s.isEmpty { return s }
    if let u = attr(e, name) as? URL { return u.absoluteString }
    return nil
}
func out(_ d: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    exit(0)
}

guard AXIsProcessTrusted() else { out(["ok": false, "error": "accessibility"]) }

let mouse = NSEvent.mouseLocation                       // bottom-left origin
let mainH = NSScreen.screens.first?.frame.height ?? 0
let p = CGPoint(x: mouse.x, y: mainH - mouse.y)         // to top-left origin
var hit: AXUIElement?
guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success, var el = hit else {
    out(["ok": false, "error": "nothing under the mouse"])
}

// Climb to an element worth capturing: skip tiny text runs, stop at groups / buttons / web areas of a useful size.
func frame(_ e: AXUIElement) -> CGRect? {
    guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &pt); AXValueGetValue(sv as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
var steps = 0
while let f = frame(el), (f.width < 60 || f.height < 24), steps < 6, let parent = attr(el, kAXParentAttribute) {
    el = parent as! AXUIElement; steps += 1
}

var url: String?
var window: String?
var cur: AXUIElement? = el
var hops = 0
while let c = cur, hops < 40 {
    if url == nil { url = str(c, "AXURL") ?? str(c, "AXDocument") }
    if (attr(c, kAXRoleAttribute) as? String) == "AXWindow" { window = str(c, kAXTitleAttribute) }
    cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
    hops += 1
}
var pid: pid_t = 0
AXUIElementGetPid(el, &pid)
let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
let f = frame(el) ?? .zero
var d: [String: Any] = ["ok": true, "app": app, "role": (attr(el, kAXRoleAttribute) as? String) ?? "",
                        "frame": ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]]
if let v = window { d["window"] = v }
if let v = url { d["url"] = v }
if let v = str(el, kAXTitleAttribute) { d["title"] = String(v.prefix(300)) }
if let v = str(el, kAXDescriptionAttribute) { d["desc"] = String(v.prefix(300)) }
if let v = str(el, kAXValueAttribute) { d["value"] = String(v.prefix(1500)) }
if let v = str(el, kAXHelpAttribute) { d["help"] = String(v.prefix(300)) }
out(d)
