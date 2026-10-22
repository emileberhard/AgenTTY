import Foundation
@unsafe @preconcurrency import Security

nonisolated struct AgenTTYNotificationDeviceIdentity: Codable, Sendable {
    let deviceID: UUID
    let deviceSecret: String
}

nonisolated enum AgenTTYNotificationDeviceIdentityStore {
    private final class Cache: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.agentty.notifications.device-identity")
        private var identitiesByService: [String: AgenTTYNotificationDeviceIdentity] = [:]

        func value(
            for serviceName: String,
            create: () -> AgenTTYNotificationDeviceIdentity
        ) -> AgenTTYNotificationDeviceIdentity {
            queue.sync {
                if let cachedIdentity = identitiesByService[serviceName] {
                    return cachedIdentity
                }

                let identity = create()
                identitiesByService[serviceName] = identity
                return identity
            }
        }
    }

    private static let accountName = "device-identity"
    private static let legacyStorageKey = "agentty.notifications.device-identity.v1"
    private static let cache = Cache()

    static func loadOrCreate(
        userDefaults: UserDefaults = .standard,
        flavor: AgenTTYBuildFlavor = .current()
    ) -> AgenTTYNotificationDeviceIdentity {
        let serviceName = flavor.relayDeviceIdentityKeychainServiceV1
        return cache.value(for: serviceName) {
            if let keychainIdentity = loadFromKeychain(serviceName: serviceName) {
                return keychainIdentity
            }

            if let legacyIdentity = loadLegacyIdentity(userDefaults: userDefaults) {
                if storeInKeychain(legacyIdentity, serviceName: serviceName) {
                    userDefaults.removeObject(forKey: legacyStorageKey)
                }
                return legacyIdentity
            }

            let generatedIdentity = AgenTTYNotificationDeviceIdentity(
                deviceID: UUID(),
                deviceSecret: randomHexString(byteCount: 32)
            )
            if storeInKeychain(generatedIdentity, serviceName: serviceName) {
                userDefaults.removeObject(forKey: legacyStorageKey)
            } else {
                persistLegacyFallback(generatedIdentity, userDefaults: userDefaults)
            }
            return generatedIdentity
        }
    }

    private static func loadFromKeychain(serviceName: String) -> AgenTTYNotificationDeviceIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(AgenTTYNotificationDeviceIdentity.self, from: data)
    }

    private static func loadLegacyIdentity(
        userDefaults: UserDefaults
    ) -> AgenTTYNotificationDeviceIdentity? {
        guard let data = userDefaults.data(forKey: legacyStorageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AgenTTYNotificationDeviceIdentity.self, from: data)
    }

    private static func persistLegacyFallback(
        _ identity: AgenTTYNotificationDeviceIdentity,
        userDefaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(identity) else {
            return
        }
        userDefaults.set(data, forKey: legacyStorageKey)
    }

    private static func storeInKeychain(
        _ identity: AgenTTYNotificationDeviceIdentity,
        serviceName: String
    ) -> Bool {
        guard let payload = try? JSONEncoder().encode(identity) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func randomHexString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status: OSStatus = unsafe SecRandomCopyBytes(
            kSecRandomDefault,
            byteCount,
            &bytes
        )
        if status == errSecSuccess {
            let hexDigits = Array("0123456789abcdef".utf8)
            var output = [UInt8]()
            output.reserveCapacity(byteCount * 2)
            for byte in bytes {
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0f)])
            }
            return String(decoding: output, as: UTF8.self)
        }

        var value = ""
        while value.count < byteCount * 2 {
            value += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return String(value.prefix(byteCount * 2))
    }
}
