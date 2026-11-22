import Foundation
import Security

/// The GitHub token. Saved in the App Group's keychain access group so the widget
/// extension can read it too (an App Group id doubles as a keychain access group on iOS).
enum Keychain {
    private static let service = "gitsidian"
    private static let account = "github-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Searches every access group this process can see (app or widget).
    static func read() -> String? {
        readItem()?.token
    }

    private static func readItem() -> (token: String, group: String?)? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any],
              let d = item[kSecValueData as String] as? Data,
              let token = String(data: d, encoding: .utf8) else { return nil }
        return (token, item[kSecAttrAccessGroup as String] as? String)
    }

    static func save(_ token: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var shared = q
        shared[kSecAttrAccessGroup as String] = AppGroup.identifier
        // Falls back to the app's own group when the App Group entitlement is missing (unsigned builds).
        if SecItemAdd(shared as CFDictionary, nil) != errSecSuccess {
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Tokens saved before widgets existed live in the app's private group: move them to the shared one.
    static func migrateToSharedGroup() {
        guard let item = readItem(), item.group != AppGroup.identifier else { return }
        save(item.token)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
