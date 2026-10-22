import Foundation

enum NewShellWorkingDirectorySetting {
    static let storageKey = "reuseRightmostShellWorkingDirectoryForNewShells"
    static let defaultValue = true

    static func persistedValue() -> Bool {
        persistedValue(from: AgenTTYSharedDefaults.store)
    }

    private static func persistedValue(from userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: storageKey)
    }
}
