import Foundation
import OSLog
import UserNotifications

enum TmuxWindowIDParsing {
    static func parse(_ rawValue: some StringProtocol) -> Int? {
        let trimmedValue = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }
        if trimmedValue.first == "@" {
            return Int(trimmedValue.dropFirst())
        }
        return Int(trimmedValue)
    }
}

enum NotificationTraceEvent: String, Sendable {
    case pushParseError = "push_parse_error"
    case pushForeground = "push_foreground"
    case pushResponse = "push_response"
    case bannerPresented = "banner_presented"
    case bannerQueued = "banner_queued"
    case bannerDismissed = "banner_dismissed"
    case pushExtensionReceived = "push_extension_received"
    case pushExtensionPassthrough = "push_extension_passthrough"
    case pushExtensionTimeout = "push_extension_timeout"
}

enum NotificationTraceDecision: String, Sendable {
    case suppressActiveWindow = "suppress_active_window"
    case showInAppBanner = "show_in_app_banner"
    case navigateWindow = "navigate_window"
    case noWindowNavigation = "no_window_navigation"
    case passthrough
}

enum NotificationTraceAppState: String, Sendable {
    case active
    case inactive
    case background
    case unknown
}

enum NotificationTraceReason: String, Sendable {
    case minDisplayDuration = "min_display_duration"
    case timeout
    case manual
    case replaced
    case navigate
    case activeWindowMatch = "active_window_match"
}

struct NotificationTraceAction: Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct NotificationTraceFields: Equatable, Sendable {
    let activeWindowID: Int?
    let appState: NotificationTraceAppState?
    let decision: NotificationTraceDecision?
    let action: NotificationTraceAction?
    let reason: NotificationTraceReason?

    static let empty = NotificationTraceFields(
        activeWindowID: nil,
        appState: nil,
        decision: nil,
        action: nil,
        reason: nil
    )

    static func foreground(
        activeWindowID: Int?,
        appState: NotificationTraceAppState,
        decision: NotificationTraceDecision
    ) -> NotificationTraceFields {
        NotificationTraceFields(
            activeWindowID: activeWindowID,
            appState: appState,
            decision: decision,
            action: nil,
            reason: nil
        )
    }

    static func response(
        action: NotificationTraceAction,
        decision: NotificationTraceDecision
    ) -> NotificationTraceFields {
        NotificationTraceFields(
            activeWindowID: nil,
            appState: nil,
            decision: decision,
            action: action,
            reason: nil
        )
    }

    static func banner(
        activeWindowID: Int?,
        reason: NotificationTraceReason?
    ) -> NotificationTraceFields {
        NotificationTraceFields(
            activeWindowID: activeWindowID,
            appState: nil,
            decision: nil,
            action: nil,
            reason: reason
        )
    }

    static func notificationExtension(
        decision: NotificationTraceDecision?,
        reason: NotificationTraceReason?
    ) -> NotificationTraceFields {
        NotificationTraceFields(
            activeWindowID: nil,
            appState: nil,
            decision: decision,
            action: nil,
            reason: reason
        )
    }
}

struct NotificationTraceContext: Equatable, Sendable {
    private static let attemptIDKey = "attempt_id"
    private static let sourceKey = "source"
    private static let tmuxWindowIDKey = "tmux_window_id"

    static let empty = NotificationTraceContext(
        attemptID: nil,
        source: nil,
        tmuxWindowID: nil
    )

    let attemptID: String?
    let source: String?
    let tmuxWindowID: Int?

    static func parse(
        userInfo: [AnyHashable: Any],
        fallbackSource: String? = nil
    ) -> NotificationTraceContext {
        NotificationTraceContext(
            attemptID: parseString(
                field: attemptIDKey,
                userInfo: userInfo
            ),
            source: parseString(
                field: sourceKey,
                userInfo: userInfo
            ) ?? normalizeString(fallbackSource),
            tmuxWindowID: parseTmuxWindowID(userInfo: userInfo)
        )
    }

    static func parse(content: UNNotificationContent) -> NotificationTraceContext {
        parse(userInfo: content.userInfo, fallbackSource: content.title)
    }

    private static func parseString(
        field: String,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        guard let rawValue = userInfo[field] else {
            return nil
        }
        guard let stringValue = rawValue as? String else {
            NotificationTraceLogger.logParseError(field: field, rawValue: rawValue)
            return nil
        }
        return normalizeString(stringValue)
    }

    private static func parseTmuxWindowID(userInfo: [AnyHashable: Any]) -> Int? {
        guard let rawValue = userInfo[tmuxWindowIDKey] else {
            return nil
        }

        if let windowID = rawValue as? Int {
            return windowID
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        if let stringValue = rawValue as? String,
           let windowID = TmuxWindowIDParsing.parse(stringValue) {
            return windowID
        }

        NotificationTraceLogger.logParseError(field: tmuxWindowIDKey, rawValue: rawValue)
        return nil
    }

    private static func normalizeString(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

nonisolated enum NotificationTraceLogger {
    private static let logger = Logger(subsystem: "dev.tuist.agentty", category: "notifications")

    static func log(
        _ event: NotificationTraceEvent,
        context: NotificationTraceContext,
        fields: NotificationTraceFields
    ) {
        let attemptID = sanitize(context.attemptID, defaultValue: "none")
        let source = sanitize(context.source, defaultValue: "unknown")
        let tmuxWindowID = context.tmuxWindowID.map(String.init) ?? "none"
        let activeWindow = fields.activeWindowID.map(String.init) ?? "none"
        let appStateValue = fields.appState?.rawValue ?? "none"
        let decisionValue = fields.decision?.rawValue ?? "none"
        let actionValue = sanitize(fields.action?.rawValue, defaultValue: "none")
        let reasonValue = fields.reason?.rawValue ?? "none"

        logger.notice(
            "event=\(event.rawValue, privacy: .public) attempt_id=\(attemptID, privacy: .public) source=\(source, privacy: .public) tmux_window_id=\(tmuxWindowID, privacy: .public) active_window_id=\(activeWindow, privacy: .public) app_state=\(appStateValue, privacy: .public) decision=\(decisionValue, privacy: .public) action=\(actionValue, privacy: .public) reason=\(reasonValue, privacy: .public)"
        )
    }

    static func logParseError(field: String, rawValue: Any) {
        let valueType = String(describing: type(of: rawValue))
        logger.error(
            "event=\(NotificationTraceEvent.pushParseError.rawValue, privacy: .public) field=\(sanitize(field, defaultValue: "unknown"), privacy: .public) type=\(sanitize(valueType, defaultValue: "unknown"), privacy: .public)"
        )
    }

    private static func sanitize(_ value: String?, defaultValue: String) -> String {
        guard let value else {
            return defaultValue
        }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: "_")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : String(trimmed.prefix(160))
    }
}
