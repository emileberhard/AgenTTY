import Foundation

nonisolated enum AgenTTYBuildConfiguration {
    static let appGroupIdentifier = required("AGENTTY_APP_GROUP")
    static let cloudKitContainerIdentifier = required("AGENTTY_CLOUDKIT_CONTAINER")
    static let keychainNamespace = required("AGENTTY_KEYCHAIN_NAMESPACE")
    static let unlockProductID = required("AGENTTY_UNLOCK_PRODUCT_ID")
    static let relayURL = url("AGENTTY_RELAY_URL")
    static let artifactURL = url("AGENTTY_ARTIFACT_URL")
    static let releaseArtifactURL = url("AGENTTY_RELEASE_ARTIFACT_URL")

    private static func required(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            preconditionFailure("Missing build configuration: \(key)")
        }
        return value
    }

    private static func url(_ key: String) -> URL {
        let value = required(key)
        guard let url = URL(string: value), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            preconditionFailure("Invalid HTTPS service URL: \(key)")
        }
        return url
    }
}
