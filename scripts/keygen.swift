// One-time: create the Ed25519 key pair that signs releases. The private key goes into the login Keychain
// (service "shotdock-release-signing"); the public key is printed for build.sh (SHOTDOCK_UPDATE_KEY).
import CryptoKit
import Foundation
import Security

let key = Curve25519.Signing.PrivateKey()
let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "shotdock-release-signing",
                        kSecAttrAccount as String: "ed25519", kSecValueData as String: key.rawRepresentation,
                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "shotdock-release-signing"] as CFDictionary)
guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { print("Could not store the key"); exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
