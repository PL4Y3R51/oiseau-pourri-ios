import Foundation
import Security
import OiseauCore

/// The session cookies, in the Keychain: this device only, never in a backup or
/// moved to a new phone (a restored session cookie would sign another phone in;
/// Android excludes them from backups for the same reason).
final class KeychainCookieStore: CookieStore {
    private let service = "ch.oiseaupourri.session"
    private let account = "cookies"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> [StoredCookie] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([StoredCookie].self, from: data)) ?? []
    }

    func save(_ cookies: [StoredCookie]) {
        SecItemDelete(query as CFDictionary)
        guard !cookies.isEmpty, let data = try? JSONEncoder().encode(cookies) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The last signed-in player, so the app opens offline.
final class DefaultsUserCache: UserCache {
    private let key = "session.user"

    func load() -> AuthUser? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AuthUser.self, from: $0) }
    }

    func save(_ user: AuthUser?) {
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
