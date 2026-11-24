import CrateCore
import Foundation
import Security

/// Service credentials and tokens in the user's login keychain.
///
/// Crate is signed ad hoc, and macOS ties keychain access to the signature, so
/// after rebuilding the app macOS may ask for permission to read these again.
final class KeychainStore: SecretStore, @unchecked Sendable {
    private let service = "app.crate.Crate"
    // Each read can raise a system prompt; remember answers for the life of the process.
    private var cache: [String: String?] = [:]
    private let lock = NSLock()

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func secret(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let value: String?
        if SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            value = String(decoding: data, as: UTF8.self)
        } else {
            value = nil
        }
        cache[key] = .some(value)
        return value
    }

    func setSecret(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(query(key) as CFDictionary)
        if let value, !value.isEmpty {
            var item = query(key)
            item[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(item as CFDictionary, nil)
            cache[key] = .some(value)
        } else {
            cache[key] = .some(nil)
        }
    }
}
