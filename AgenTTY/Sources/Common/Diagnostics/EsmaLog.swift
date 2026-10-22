import Foundation
import OSLog

nonisolated enum EsmaLog {
    static let app = Logger(subsystem: "dev.tuist.agentty", category: "app")
    static let ghostty = Logger(subsystem: "dev.tuist.agentty", category: "ghostty")
    static let notifications = Logger(subsystem: "dev.tuist.agentty", category: "notifications")
    static let ssh = Logger(subsystem: "dev.tuist.agentty", category: "ssh")
    static let terminal = Logger(subsystem: "dev.tuist.agentty", category: "terminal")
}

nonisolated enum EsmaDiagnostics {
    private static let verboseLoggingKey = "AGENTTY_VERBOSE_LOGGING"
    private static let legacyVerboseLoggingKey = "AGENTTY_VERBOSE_LOGGING"

    static var verboseLoggingEnabled: Bool {
        if let value = unsafe getenv(verboseLoggingKey) {
            let normalized = unsafe String(cString: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return parseBooleanEnvironmentValue(normalized)
        }
        if let legacyValue = unsafe getenv(legacyVerboseLoggingKey) {
            let normalized = unsafe String(cString: legacyValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return parseBooleanEnvironmentValue(normalized)
        }
        return false
    }

    static func shouldLog(counter: Int, defaultLimit: Int) -> Bool {
        verboseLoggingEnabled || counter <= defaultLimit
    }

    static func elapsedMilliseconds(
        since startNanoseconds: UInt64,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        guard nowNanoseconds >= startNanoseconds else { return 0 }
        return (nowNanoseconds - startNanoseconds) / 1_000_000
    }

    private static func parseBooleanEnvironmentValue(_ normalized: String) -> Bool {
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }
}
