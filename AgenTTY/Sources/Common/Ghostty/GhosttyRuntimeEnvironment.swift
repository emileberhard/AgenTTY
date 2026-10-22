import Foundation

@MainActor
enum GhosttyRuntimeEnvironment {
    static func configureCoreLoggingEnvironment() {
        // Keep logging quiet by default for battery/CPU efficiency.
        // Debug diagnostics remain opt-in through launch env vars.
        let keys = ["GHOSTTY_LOG", "AGENTTY_VERBOSE_LOGGING", "AGENTTY_VERBOSE_LOGGING"]
        let resolvedEntries = keys.compactMap { key -> String? in
            guard let rawValue = unsafe getenv(key) else { return nil }
            return "\(key)=\(unsafe String(cString: rawValue))"
        }

        if resolvedEntries.isEmpty {
            EsmaLog.ghostty.info(
                "logging defaults: quiet (set GHOSTTY_LOG or AGENTTY_VERBOSE_LOGGING to enable diagnostics)"
            )
        } else {
            EsmaLog.ghostty.info("logging overrides: \(resolvedEntries.joined(separator: " "), privacy: .public)")
        }
    }
}
