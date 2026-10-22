import Foundation

enum AgenTTYResolvedConnectionRouteMode: Equatable, Sendable {
    case direct
    case relay
}

@MainActor
struct AgenTTYResolvedConnectionRoute {
    let bridge: AgenTTYRelayBridge?
    let connectionTarget: AgenTTYConnectionTarget
    let mode: AgenTTYResolvedConnectionRouteMode
}

@MainActor
enum AgenTTYConnectionRouteResolver {
    private static let directProbeTimeoutSeconds = 2
    private static let recentDirectProbeFailureLifetime: TimeInterval = 15
    private static let recentDirectRouteSuccessLifetime: TimeInterval = 10 * 60
    private static var recentDirectProbeFailures: [UUID: Date] = [:]
    private static var recentDirectRouteSuccesses: [UUID: Date] = [:]

    static func resolve(for host: AgenTTYHost) async throws -> AgenTTYResolvedConnectionRoute {
        let directConnectionTarget = host.connectionTarget
        switch host.connectionRoutePolicy {
        case .directOnly:
            clearRecentDirectProbeFailure(for: host.id)
            return AgenTTYResolvedConnectionRoute(
                bridge: nil,
                connectionTarget: directConnectionTarget,
                mode: .direct
            )
        case .directThenRelay:
            if shouldPreferRelay(for: host.id), host.relayHostID?.isEmpty == false {
                return try await resolveViaRelayRearmingDirectProbe(
                    for: host,
                    directConnectionTarget: directConnectionTarget
                )
            }
            // A recently-ready direct connection on an unchanged network path is
            // the strongest reachability signal available: skip the extra probe
            // handshake and let the SSH connect (with its own timeout) be the probe.
            if hasRecentDirectRouteSuccess(for: host.id) {
                return AgenTTYResolvedConnectionRoute(
                    bridge: nil,
                    connectionTarget: directConnectionTarget,
                    mode: .direct
                )
            }
            do {
                try await AgenTTYHostReachabilityProbe.verifyReachable(
                    host: host.address,
                    port: host.port,
                    timeoutSeconds: directProbeTimeoutSeconds
                )
                clearRecentDirectProbeFailure(for: host.id)
                return AgenTTYResolvedConnectionRoute(
                    bridge: nil,
                    connectionTarget: directConnectionTarget,
                    mode: .direct
                )
            } catch {
                recordRecentDirectProbeFailure(for: host.id)
                guard host.relayHostID?.isEmpty == false else {
                    throw error
                }
                return try await resolveViaRelayRearmingDirectProbe(
                    for: host,
                    directConnectionTarget: directConnectionTarget
                )
            }
        }
    }

    /// Called when a connection reached ready state over the direct route.
    static func recordDirectRouteSuccess(for hostID: UUID) {
        recentDirectRouteSuccesses[hostID] = Date()
        clearRecentDirectProbeFailure(for: hostID)
    }

    /// Called when a direct-route connection failed before becoming ready, so the
    /// next attempt re-probes (and can fall back to relay) instead of repeating
    /// a connect against a dead direct path.
    static func recordDirectRouteFailure(for hostID: UUID) {
        recentDirectRouteSuccesses.removeValue(forKey: hostID)
        recordRecentDirectProbeFailure(for: hostID)
    }

    /// Network path changes invalidate everything we learned about routes.
    static func invalidateRouteMemory() {
        recentDirectRouteSuccesses.removeAll(keepingCapacity: false)
        recentDirectProbeFailures.removeAll(keepingCapacity: false)
    }

    /// A failed relay attempt means both routes were unavailable. Re-arm the
    /// direct probe for the next retry instead of pinning retries to the failed
    /// relay for the remainder of the short direct-failure cache window.
    static func recordRelayResolutionFailure(for hostID: UUID) {
        clearRecentDirectProbeFailure(for: hostID)
    }

    private static func hasRecentDirectRouteSuccess(for hostID: UUID) -> Bool {
        guard let successDate = recentDirectRouteSuccesses[hostID] else {
            return false
        }
        guard Date().timeIntervalSince(successDate) < recentDirectRouteSuccessLifetime else {
            recentDirectRouteSuccesses.removeValue(forKey: hostID)
            return false
        }
        return true
    }

    private static func resolveViaRelay(
        for host: AgenTTYHost,
        directConnectionTarget: AgenTTYConnectionTarget
    ) async throws -> AgenTTYResolvedConnectionRoute {
        guard let relayHostID = host.relayHostID, !relayHostID.isEmpty else {
            throw AgenTTYSSHRelayError.invalidRelayHostID
        }
        let relaySession = try await AgenTTYSSHRelayClient.shared.issueRelaySession(
            relayHostID: relayHostID
        )
        let bridge = AgenTTYRelayBridge(relaySession: relaySession)
        try await bridge.start()
        return AgenTTYResolvedConnectionRoute(
            bridge: bridge,
            connectionTarget: directConnectionTarget.connecting(
                to: "127.0.0.1",
                port: bridge.localPort
            ),
            mode: .relay
        )
    }

    private static func resolveViaRelayRearmingDirectProbe(
        for host: AgenTTYHost,
        directConnectionTarget: AgenTTYConnectionTarget
    ) async throws -> AgenTTYResolvedConnectionRoute {
        do {
            return try await resolveViaRelay(
                for: host,
                directConnectionTarget: directConnectionTarget
            )
        } catch {
            recordRelayResolutionFailure(for: host.id)
            throw error
        }
    }

    static func shouldPreferRelay(for hostID: UUID) -> Bool {
        pruneRecentDirectProbeFailures(now: Date())
        guard let failureDate = recentDirectProbeFailures[hostID] else {
            return false
        }
        return Date().timeIntervalSince(failureDate) < recentDirectProbeFailureLifetime
    }

    private static func recordRecentDirectProbeFailure(for hostID: UUID) {
        let now = Date()
        pruneRecentDirectProbeFailures(now: now)
        recentDirectProbeFailures[hostID] = now
    }

    private static func clearRecentDirectProbeFailure(for hostID: UUID) {
        recentDirectProbeFailures.removeValue(forKey: hostID)
    }

    private static func pruneRecentDirectProbeFailures(now: Date) {
        recentDirectProbeFailures = recentDirectProbeFailures.filter { _, failureDate in
            now.timeIntervalSince(failureDate) < recentDirectProbeFailureLifetime
        }
    }
}
