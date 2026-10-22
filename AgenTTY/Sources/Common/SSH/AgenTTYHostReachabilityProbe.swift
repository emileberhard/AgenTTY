import Foundation
@unsafe @preconcurrency import Network

enum AgenTTYHostReachabilityFailureSubtype: String, Codable, Hashable, Sendable {
    case dns
    case timeout
    case connectionRefused = "connection_refused"
    case networkUnreachable = "network_unreachable"
    case other
}

nonisolated enum AgenTTYHostReachabilityError: LocalizedError {
    case invalidPort(Int)
    case timedOut(host: String, port: Int, timeoutSeconds: Int)
    case failed(
        host: String,
        port: Int,
        reason: String,
        subtype: AgenTTYHostReachabilityFailureSubtype
    )

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "AgenTTY could not check this host because port \(port) is invalid."
        case .timedOut(let host, let port, let timeoutSeconds):
            return "AgenTTY could not reach \(host):\(port) within \(timeoutSeconds) seconds."
        case .failed(let host, _, _, .dns):
            return "The hostname \(host) does not resolve from this iPhone."
        case .failed(let host, let port, let reason, _):
            return "AgenTTY could not reach \(host):\(port). \(reason)"
        }
    }

    var failureSubtype: AgenTTYHostReachabilityFailureSubtype {
        switch self {
        case .invalidPort, .failed(_, _, _, .other):
            return .other
        case .timedOut:
            return .timeout
        case .failed(_, _, _, let subtype):
            return subtype
        }
    }
}

nonisolated enum AgenTTYHostReachabilityGuidance {
    static func guidance(for error: AgenTTYHostReachabilityError) -> AgenTTYSSHRecoveryDescription {
        switch error.failureSubtype {
        case .dns:
            return AgenTTYSSHRecoveryDescription(
                title: "Hostname Does Not Resolve",
                message: error.localizedDescription,
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "number",
                        title: "Use an IP address",
                        subtitle: "Enter the host's LAN, public, or Tailscale IP address if DNS is unreliable."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Try the full Tailscale name",
                        subtitle: "If this is a Tailscale host, use its full MagicDNS hostname instead of the short name."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "wifi",
                        title: "Try the .local name",
                        subtitle: "On the same local network, the host's Bonjour name may resolve as name.local."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "qrcode.viewfinder",
                        title: "Run Automatic Setup again",
                        subtitle: "Pairing can refresh the host suggestions and pick a reachable address."
                    ),
                ]
            )
        case .timeout, .connectionRefused, .networkUnreachable, .other:
            return AgenTTYSSHRecoveryDescription(
                title: "Couldn't Reach Host",
                message: error.localizedDescription,
                suggestions: [
                    AgenTTYSSHRecoverySuggestion(
                        icon: "wifi",
                        title: "Check the network path",
                        subtitle: "Use the same LAN, a public address, or Tailscale on both devices."
                    ),
                    AgenTTYSSHRecoverySuggestion(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Verify SSH is listening",
                        subtitle: "Confirm that SSH is running on the selected port for this host."
                    ),
                ]
            )
        }
    }
}

nonisolated enum AgenTTYHostReachabilityProbe {
    private static let defaultTimeoutSeconds = 5

    @concurrent
    static func verifyReachable(
        host: String,
        port: Int,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws {
        let normalizedHost = AgenTTYHostAddressNormalizer.normalizeForStorage(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw AgenTTYHostReachabilityError.invalidPort(port)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(normalizedHost),
            port: endpointPort,
            using: .tcp
        )
        let queue = DispatchQueue(label: "dev.tuist.agentty.host-reachability")
        let resolution = ReachabilityResolution()
        let timeoutWorkItem = DispatchWorkItem {
            resolution.resolve(
                connection: connection,
                result: .failure(
                    AgenTTYHostReachabilityError.timedOut(
                        host: normalizedHost,
                        port: port,
                        timeoutSeconds: timeoutSeconds
                    )
                )
            )
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resolution.install(continuation: continuation, timeoutWorkItem: timeoutWorkItem)
                if Task.isCancelled {
                    resolution.cancel(connection: connection)
                    return
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resolution.resolve(connection: connection, result: .success(()))
                    case .waiting(let error):
                        resolution.resolve(
                            connection: connection,
                            result: .failure(reachabilityFailure(host: normalizedHost, port: port, error: error))
                        )
                    case .failed(let error):
                        resolution.resolve(
                            connection: connection,
                            result: .failure(reachabilityFailure(host: normalizedHost, port: port, error: error))
                        )
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWorkItem)
            }
        } onCancel: {
            resolution.cancel(connection: connection)
        }
    }

    private static func reachabilityFailure(
        host: String,
        port: Int,
        error: NWError
    ) -> AgenTTYHostReachabilityError {
        switch error {
        case .dns:
            return .failed(
                host: host,
                port: port,
                reason: error.localizedDescription,
                subtype: .dns
            )
        case .posix(let code):
            return .failed(
                host: host,
                port: port,
                reason: error.localizedDescription,
                subtype: failureSubtype(for: code)
            )
        case .tls, .wifiAware:
            return .failed(
                host: host,
                port: port,
                reason: error.localizedDescription,
                subtype: .other
            )
        @unknown default:
            return .failed(
                host: host,
                port: port,
                reason: error.localizedDescription,
                subtype: .other
            )
        }
    }

    private static func failureSubtype(
        for code: POSIXErrorCode
    ) -> AgenTTYHostReachabilityFailureSubtype {
        switch code {
        case .ETIMEDOUT:
            return .timeout
        case .ECONNREFUSED:
            return .connectionRefused
        case .ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH:
            return .networkUnreachable
        default:
            return .other
        }
    }
}

nonisolated private final class ReachabilityResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResolved = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    func install(
        continuation: CheckedContinuation<Void, Error>,
        timeoutWorkItem: DispatchWorkItem
    ) {
        lock.lock()
        self.continuation = continuation
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()
    }

    func resolve(
        connection: NWConnection,
        result: Result<Void, Error>
    ) {
        lock.lock()
        guard !hasResolved else {
            lock.unlock()
            return
        }
        hasResolved = true
        let continuation = self.continuation
        let timeoutWorkItem = self.timeoutWorkItem
        self.continuation = nil
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume(returning: ())
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel(connection: NWConnection) {
        resolve(connection: connection, result: .failure(CancellationError()))
    }
}
