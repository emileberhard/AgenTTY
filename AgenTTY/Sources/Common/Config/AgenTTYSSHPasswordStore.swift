import Foundation
@unsafe @preconcurrency import Security

enum AgenTTYSSHPasswordStoreError: LocalizedError, Equatable {
    case passwordNotFound
    case passwordInvalid
    case keychainStoreFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .passwordNotFound:
            "No password was found for this host."
        case .passwordInvalid:
            "The stored password is invalid."
        case .keychainStoreFailed:
            "Failed to store the SSH password in Keychain."
        case .keychainReadFailed:
            "Failed to read the SSH password from Keychain."
        case .keychainDeleteFailed:
            "Failed to delete the SSH password from Keychain."
        }
    }
}

nonisolated final class AgenTTYSSHPasswordStore: @unchecked Sendable {
    private let serviceName: String

    @MainActor
    convenience init() {
        self.init(flavor: .current())
    }

    init(flavor: AgenTTYBuildFlavor) {
        serviceName = flavor.sshPasswordBootstrapKeychainServiceV1
    }

    func hasPassword(for credentialID: UUID) -> Bool {
        do {
            _ = try loadPassword(for: credentialID)
            return true
        } catch {
            return false
        }
    }

    func storePassword(_ password: String, credentialID: UUID) throws {
        let normalizedPassword = password.trimmingCharacters(in: .newlines)
        guard !normalizedPassword.isEmpty else {
            throw AgenTTYSSHPasswordStoreError.passwordInvalid
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalizedPassword.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw AgenTTYSSHPasswordStoreError.keychainStoreFailed(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = Data(normalizedPassword.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgenTTYSSHPasswordStoreError.keychainStoreFailed(addStatus)
        }
    }

    func loadPassword(for credentialID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw AgenTTYSSHPasswordStoreError.passwordNotFound
        }
        guard status == errSecSuccess else {
            throw AgenTTYSSHPasswordStoreError.keychainReadFailed(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            throw AgenTTYSSHPasswordStoreError.passwordInvalid
        }
        return password
    }

    func deletePassword(for credentialID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: credentialID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw AgenTTYSSHPasswordStoreError.keychainDeleteFailed(status)
    }
}
