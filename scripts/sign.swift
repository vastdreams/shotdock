// Sign a release zip: prints the base64 Ed25519 signature of its SHA-256, using the key from keygen.swift.
import CryptoKit
import Foundation
import Security

guard CommandLine.arguments.count > 1, let zip = FileManager.default.contents(atPath: CommandLine.arguments[1]) else { print("usage: sign <zip>"); exit(1) }
var out: AnyObject?
let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "shotdock-release-signing",
                        kSecAttrAccount as String: "ed25519", kSecReturnData as String: true]
guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let raw = out as? Data,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { print("No signing key. Run keygen first."); exit(1) }
print(try key.signature(for: Data(SHA256.hash(data: zip))).base64EncodedString())
