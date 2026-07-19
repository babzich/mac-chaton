import Foundation
import LeChatonCore
import Security

actor SystemProviderSecretStore: ProviderSecretStore {
    private let service = "com.vincentbach.LeChaton.vibe-provider"

    func read(account: String) async throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw ProviderKeychainError(status) }
        return value
    }

    func write(_ secret: String, account: String) async throws {
        let data = Data(secret.utf8)
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw ProviderKeychainError(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw ProviderKeychainError(status) }
    }

    func delete(account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderKeychainError(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

private struct ProviderKeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    init(_ status: OSStatus) {
        self.status = status
    }

    var description: String {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain operation failed (\(status))"
    }
}
