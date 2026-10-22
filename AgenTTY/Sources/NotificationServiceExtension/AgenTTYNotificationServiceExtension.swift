import Foundation
import UserNotifications

final class AgenTTYNotificationServiceExtension: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let traceContext = NotificationTraceContext.parse(content: request.content)
        NotificationTraceLogger.log(
            .pushExtensionReceived,
            context: traceContext,
            fields: .empty
        )
        NotificationTraceLogger.log(
            .pushExtensionPassthrough,
            context: traceContext,
            fields: .notificationExtension(
                decision: .passthrough,
                reason: nil
            )
        )
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        NotificationTraceLogger.log(.pushExtensionTimeout, context: .empty, fields: .empty)
    }
}
