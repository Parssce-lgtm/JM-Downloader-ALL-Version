import Foundation
import Security

enum SessionVault {
    private static let service = "app.jmdownloader.sessions"
    private static func key(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func save(_ session: ServiceSession, account: String) throws {
        let data = try JSONEncoder().encode(session)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(key(account).merging(values) { _, b in b } as CFDictionary, nil) == errSecSuccess else {
                throw JMError.message("登录成功，但会话无法保存到钥匙串。")
            }
        } else if status != errSecSuccess { throw JMError.message("会话无法更新到钥匙串。") }
    }
    static func load(_ account: String) -> ServiceSession? {
        var query = key(account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServiceSession.self, from: data)
    }
    static func remove(_ account: String) { SecItemDelete(key(account) as CFDictionary) }
}
