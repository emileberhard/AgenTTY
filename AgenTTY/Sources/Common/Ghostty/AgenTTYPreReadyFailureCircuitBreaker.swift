import Foundation

nonisolated struct AgenTTYPreReadyFailureCircuitBreaker: Equatable, Sendable {
    static let threshold = 3
    static let window: TimeInterval = 60

    private var consecutiveFailureCount = 0
    private var firstFailureAt: Date?
    private var hostID: UUID?
    private var authMode: AgenTTYAnalyticsSSHAuthMode?

    /// Pure network transients (roaming, flaky cellular, interrupted handshakes)
    /// must not lock the user into manual recovery; bounded reconnect backoff
    /// already rate-limits those retries. The breaker exists for repeatable
    /// pre-ready failures like broken bootstrap or rejected sessions.
    static func countsTowardTrip(_ category: AgenTTYSSHDisconnectCategory) -> Bool {
        switch category {
        case .connectTimeout, .networkError, .transportClosed:
            false
        case .shellClosed, .authFailed, .hostKeyMismatch, .localClose, .algorithmNegotiationFailed, .other:
            true
        }
    }

    mutating func reset() {
        consecutiveFailureCount = 0
        firstFailureAt = nil
        hostID = nil
        authMode = nil
    }

    mutating func recordFailure(
        hostID: UUID,
        authMode: AgenTTYAnalyticsSSHAuthMode,
        category: AgenTTYSSHDisconnectCategory,
        at: Date
    ) -> Bool {
        guard Self.countsTowardTrip(category) else {
            return false
        }

        let shouldResetWindow = self.hostID != hostID
            || self.authMode != authMode
            || firstFailureAt == nil
            || at.timeIntervalSince(firstFailureAt!) > Self.window

        if shouldResetWindow {
            consecutiveFailureCount = 1
            firstFailureAt = at
            self.hostID = hostID
            self.authMode = authMode
        } else {
            consecutiveFailureCount += 1
        }

        return consecutiveFailureCount >= Self.threshold
    }
}
