// ShotDock Launcher: a tiny app that never changes, so macOS permissions granted to it survive every ShotDock
// rebuild. It asks once for Screen Recording and Accessibility, then keeps ShotDock running as its child
// (children inherit the launcher's permissions) and restarts it if it quits. Started at login by
// ~/Library/LaunchAgents/<bundle id>.launcher.plist.
import ApplicationServices
import Cocoa

let bin = NSHomeDirectory() + "/Applications/ShotDock.app/Contents/MacOS/ShotDock"
/// The app this launcher keeps running: its own bundle id without ".launcher".
let companionBundleID = (Bundle.main.bundleIdentifier ?? "com.fseresearch.shotdock.launcher").replacingOccurrences(of: ".launcher", with: "")

final class Launcher: NSObject, NSApplicationDelegate {
    var child: Process?

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.ensure() }
        ensure()
    }

    /// Start ShotDock unless it is already running (for example, started from a terminal during development).
    func ensure() {
        if let c = child, c.isRunning { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: companionBundleID).isEmpty { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        try? p.run()
        child = p
    }
}

let app = NSApplication.shared
let d = Launcher()
app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
