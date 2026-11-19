// Updates from GitHub Releases, verified before anything is installed.
// Each release carries ShotDock-<version>-macos.zip, its SHA-256, and an Ed25519 signature of that hash made with
// the publisher's private key (kept offline by the publisher). The public key is built into the app,
// so a tampered release, or a release from a hijacked account, is rejected.

import CryptoKit
import Cocoa

enum Updater {
    /// owner/repo on GitHub; set at build time (UPDATE_REPO) or in ~/.duraloop/config.json "update_repo".
    static var repo: String {
        let cfg = (try? Data(contentsOf: Prefs.file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return cfg?["update_repo"] as? String ?? (Bundle.main.object(forInfoDictionaryKey: "ShotDockUpdateRepo") as? String ?? "")
    }
    /// Base64 Ed25519 public key that release signatures must match.
    static var publicKey: String { Bundle.main.object(forInfoDictionaryKey: "ShotDockUpdateKey") as? String ?? "" }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func check(manual: Bool, done: @escaping (String) -> Void) {
        guard !repo.isEmpty, !publicKey.isEmpty else { return done("Updates are not set up in this build.") }
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return done("Bad update repo.") }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            func say(_ s: String) { DispatchQueue.main.async { done(s) } }
            guard let data, let rel = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = rel["tag_name"] as? String, let assets = rel["assets"] as? [[String: Any]] else { return say("Could not reach GitHub.") }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard newer(version, than: current) else { return say(manual ? "ShotDock \(current) is the latest." : "") }
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
            }
            guard let zipURL = asset("-macos.zip"), let sigURL = asset("-macos.zip.sig") else { return say("Release \(version) has no signed Mac build.") }
            guard let zip = try? Data(contentsOf: zipURL), let sigText = try? String(contentsOf: sigURL, encoding: .utf8) else {
                return say("Download failed.")
            }
            // The signature covers the SHA-256 of the zip.
            let digest = Data(SHA256.hash(data: zip))
            guard let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  key.isValidSignature(sig, for: digest) else {
                return say("Update \(version) failed its signature check and was not installed.")
            }
            install(zip: zip, version: version, say: say)
        }.resume()
    }

    /// Unzip next to the running app, swap it in, and quit; the launcher starts the new version.
    static func install(zip: Data, version: String, say: @escaping (String) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shotdock-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let z = tmp.appendingPathComponent("u.zip")
        guard (try? zip.write(to: z)) != nil else { return say("Could not save the update.") }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", z.path, tmp.path]
        try? unzip.run()
        unzip.waitUntilExit()
        guard let app = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else {
            return say("The update did not contain the app.")
        }
        let target = Bundle.main.bundleURL
        let backup = target.deletingLastPathComponent().appendingPathComponent(".ShotDock-previous.app")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: target, to: backup)
            try fm.moveItem(at: app, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            return say("Could not install the update: \(error.localizedDescription)")
        }
        say("Updated to \(version). Restarting.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }
}
