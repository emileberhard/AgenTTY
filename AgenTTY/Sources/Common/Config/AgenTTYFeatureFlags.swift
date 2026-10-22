import Foundation

nonisolated enum AgenTTYFeatureFlags {
    static let dictationAIStorageKey = "enhancedDictationEnabled"
    static let shellTitleAIStorageKey = "shellTitleAIEnabled"
    static let dictationAIEnvironmentKey = "AGENTTY_ENABLE_DICTATION_AI"
    static let shellTitleAIEnvironmentKey = "AGENTTY_ENABLE_SHELL_TITLE_AI"
    static let aiComingSoonLabel = "coming soon!"
    static let enhancedDictationComingSoonMessage = "Enhanced dictation is coming soon!"

    static var dictationAIAvailableInCurrentFlavor: Bool {
        true
    }

    static var shellTitleAIAvailableInCurrentFlavor: Bool {
        AgenTTYBuildFlavor.current() != .main
    }

    static var dictationAIEnabled: Bool {
        resolvedValue(
            storageKey: dictationAIStorageKey,
            environmentKey: dictationAIEnvironmentKey,
            defaultWhenUnset: true,
            featureAvailable: dictationAIAvailableInCurrentFlavor
        )
    }

    static var shellTitleAIEnabled: Bool {
        resolvedValue(
            storageKey: shellTitleAIStorageKey,
            environmentKey: shellTitleAIEnvironmentKey,
            defaultWhenUnset: true,
            featureAvailable: shellTitleAIAvailableInCurrentFlavor
        )
    }

    private static func resolvedValue(
        storageKey: String,
        environmentKey: String,
        defaultWhenUnset: Bool,
        featureAvailable: Bool
    ) -> Bool {
        guard featureAvailable else {
            return false
        }
        if let envValue = envBooleanValue(for: environmentKey) {
            return envValue
        }
        let store = AgenTTYSharedDefaults.store
        if store.object(forKey: storageKey) != nil {
            return store.bool(forKey: storageKey)
        }
        return defaultWhenUnset
    }

    private static func envBooleanValue(for key: String) -> Bool? {
        guard let rawPtr = unsafe getenv(key) else { return nil }
        let normalizedValue = unsafe String(cString: rawPtr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedValue {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            preconditionFailure(
                "invalid \(key) value '\(normalizedValue)' (expected one of: 1,true,yes,on,0,false,no,off)"
            )
        }
    }
}
