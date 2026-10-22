import Foundation

nonisolated enum AgenTTYSharedDefaults {
    static let appGroupIdentifier = AgenTTYBuildConfiguration.appGroupIdentifier
    static let legacyAppGroupIdentifier = "group.dev.tuist.EsmaTerm"

    static var store: UserDefaults {
        if let store = UserDefaults(suiteName: appGroupIdentifier) {
            return store
        }
        return .standard
    }
}
