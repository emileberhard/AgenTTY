import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

nonisolated enum AgenTTYSentryService {
    private static let logger = Logger(subsystem: "dev.tuist.agentty", category: "sentry")

    static func configure(bundle: Bundle = .main) {
#if canImport(Sentry)
        guard let dsn = resolvedDSN(bundle: bundle), !dsn.isEmpty else {
            logger.notice("Sentry DSN not configured, skipping Sentry initialization")
            return
        }

        let flavor = AgenTTYBuildFlavor.current(bundle: bundle)
        let environment = environmentName(for: flavor)

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            options.dist = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            options.enableAppHangTracking = true
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.environment = environment
            options.debug = isDebugBuild
        }
        SentrySDK.configureScope { scope in
            scope.setTag(value: flavor.rawValue, key: "build_flavor")
            if let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty {
                scope.setTag(value: bundleIdentifier, key: "bundle_id")
            }
        }
        Task {
            await configureAnalyticsIdentityIfAvailable(flavor: flavor, bundle: bundle)
        }
        logger.notice(
            "Sentry initialized environment=\(environment, privacy: .public) flavor=\(flavor.rawValue, privacy: .public)"
        )
#endif
    }

    static func addBreadcrumb(
        message: String,
        category: String,
        level: String,
        data: [String: String] = [:]
    ) {
#if canImport(Sentry)
        let breadcrumb = Breadcrumb()
        breadcrumb.message = message
        breadcrumb.category = category
        breadcrumb.level = sentryLevel(for: level)
        for (key, value) in data {
            breadcrumb.setData(value: value, key: key)
        }
        SentrySDK.addBreadcrumb(breadcrumb)
#endif
    }

    static func capture(error: Error, context: String, data: [String: String] = [:]) {
#if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: context, key: "context")
            if !data.isEmpty {
                scope.setContext(value: data, key: "diagnostic_payload")
            }
        }
#endif
    }

    static func captureHandledError(
        message: String,
        context: String,
        data: [String: String] = [:]
    ) {
        let error = NSError(
            domain: "dev.tuist.agentty.handled",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        capture(error: error, context: context, data: data)
    }

#if canImport(Sentry)
    private static func sentryLevel(for level: String) -> SentryLevel {
        switch level {
        case "error":
            .error
        case "warning":
            .warning
        case "debug":
            .debug
        default:
            .info
        }
    }
#endif

    private static func resolvedDSN(bundle: Bundle) -> String? {
        if let env = ProcessInfo.processInfo.environment["AGENTTY_SENTRY_DSN"], !env.isEmpty {
            return env
        }

        if let plistValue = bundle.object(forInfoDictionaryKey: "AGENTTY_SENTRY_DSN") as? String,
           !plistValue.isEmpty {
            return plistValue
        }

        return nil
    }

#if canImport(Sentry)
    private static func configureAnalyticsIdentityIfAvailable(
        flavor: AgenTTYBuildFlavor,
        bundle: Bundle
    ) async {
        guard let identity = await AgenTTYAppTransactionAnalyticsResolver.resolve(
            flavor: flavor,
            bundle: bundle
        ) else {
            return
        }

        let analyticsUserHash = AgenTTYAnalyticsHashing.sha256Hex(identity.appTransactionID)
        let sentryUser = User(userId: analyticsUserHash)
        SentrySDK.configureScope { scope in
            scope.setUser(sentryUser)
            scope.setTag(value: analyticsUserHash, key: "analytics_user_hash")
            scope.setTag(
                value: identity.appTransactionEnvironment.rawValue,
                key: "app_transaction_environment"
            )
        }
    }
#endif

    private static func environmentName(for flavor: AgenTTYBuildFlavor) -> String {
        "\(flavor.rawValue)-\(isDebugBuild ? "debug" : "release")"
    }

    private static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}
