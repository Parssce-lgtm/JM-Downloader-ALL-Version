import Foundation
import Security

enum SecureStore {
    private static let service = "app.jmdownloader.accounts"
    static func save(username: String, password: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: username]
        let values: [String: Any] = [kSecValueData as String: Data(password.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(key.merging(values) { _, b in b } as CFDictionary, nil) == errSecSuccess else {
                throw JMError.message("无法保存到钥匙串。")
            }
        } else if status != errSecSuccess { throw JMError.message("无法更新钥匙串。") }
    }
    static func password(for username: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: username,
                                    kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func accounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
    static func remove(_ username: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: username] as CFDictionary)
    }
}

enum DiskStore {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JMDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func load() throws -> AppSnapshot {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSnapshot() }
        return try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: url))
    }
    static func save(_ snapshot: AppSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    static func cache(_ id: UUID) -> URL {
        root.appendingPathComponent("Transfers", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static func raw(_ id: UUID, _ index: Int) -> URL { cache(id).appendingPathComponent("\(index).raw") }
}
