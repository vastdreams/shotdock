// Settings shared by ShotDock and the claim checker: ~/.duraloop/config.json (no secrets), and API keys in the
// macOS Keychain (service "shotdock", account = provider), never in files.

import Cocoa

struct Prefs {
    var readText = true
    var autoBlur = false
    var shrink = true
    var recordSeconds = 10
    var checkProvider = "deepseek"
    var checkModel = "deepseek-chat"
    var autoFollowup = false
    var mode = "local"
    var server = ""

    static let file = home.appendingPathComponent(".duraloop/config.json")

    static func load() -> Prefs {
        var p = Prefs()
        guard let d = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return p }
        let s = d["shotdock"] as? [String: Any] ?? [:]
        p.readText = s["read_text"] as? Bool ?? p.readText
        p.autoBlur = s["auto_blur"] as? Bool ?? p.autoBlur
        p.shrink = s["shrink"] as? Bool ?? p.shrink
        p.recordSeconds = s["record_seconds"] as? Int ?? p.recordSeconds
        p.checkProvider = d["claimcheck_provider"] as? String ?? p.checkProvider
        p.checkModel = d["claimcheck_model"] as? String ?? p.checkModel
        p.mode = d["mode"] as? String ?? p.mode
        p.server = d["server"] as? String ?? p.server
        return p
    }

    func save() {
        var d = (try? Data(contentsOf: Prefs.file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        d["shotdock"] = ["read_text": readText, "auto_blur": autoBlur, "shrink": shrink, "record_seconds": recordSeconds]
        d["claimcheck_provider"] = checkProvider
        d["claimcheck_model"] = checkModel
        d["mode"] = mode
        d["server"] = server.isEmpty ? NSNull() : server
        try? FileManager.default.createDirectory(at: Prefs.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: Prefs.file) }
    }
}

/// API keys in the login Keychain. Nothing is written to disk in plain text.
enum Keys {
    static let service = "shotdock"
    static func get(_ provider: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: provider, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult
    static func set(_ provider: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Which shot went to which chat, for the history window.
enum History {
    static let file = home.appendingPathComponent(".claude/state/shotdock-history.jsonl")
    static func log(shot: URL, chat: ChatInfo) {
        let rec: [String: Any] = ["ts": Date().timeIntervalSince1970, "shot": shot.path, "chat": chat.title,
                                  "session": chat.session, "workspace": chat.workspace]
        guard let data = try? JSONSerialization.data(withJSONObject: rec), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: file, atomically: true, encoding: .utf8) }
    }
    static func recent(_ n: Int = 40) -> [(URL, String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).reversed().compactMap { line in
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let p = d["shot"] as? String, FileManager.default.fileExists(atPath: p) else { return nil }
            return (URL(fileURLWithPath: p), "\(d["chat"] as? String ?? "") · \(d["workspace"] as? String ?? "")")
        }
    }
}
