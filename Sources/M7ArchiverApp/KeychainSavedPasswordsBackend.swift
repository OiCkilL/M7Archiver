import Foundation
import Security

/// Production backend that stores archive passwords in the macOS Keychain
/// as generic-password items. Keyed by archive path under a single service
/// label so listing/clear-all is scoped to the app.
public struct KeychainSavedPasswordsBackend: SavedPasswordsBackend {
    public static let defaultService = "com.m7archiver.savedpasswords"

    public let service: String

    public init(service: String = KeychainSavedPasswordsBackend.defaultService) {
        self.service = service
    }

    public func save(password: String, for path: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError(status: errSecParam)
        }
        let baseQuery = baseQuery(account: path)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    public func lookup(for path: String) -> String? {
        var query = baseQuery(account: path)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(for path: String) throws {
        let query = baseQuery(account: path)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    public func allEntries() throws -> [SavedPasswordEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            let savedAt = (item[kSecAttrModificationDate as String] as? Date)
                ?? (item[kSecAttrCreationDate as String] as? Date)
                ?? Date()
            return SavedPasswordEntry(path: account, savedAt: savedAt)
        }
    }

    public func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct KeychainError: Error, Equatable, Sendable {
    public var status: OSStatus
    public init(status: OSStatus) { self.status = status }
}
