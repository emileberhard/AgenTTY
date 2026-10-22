import Foundation
@unsafe @preconcurrency import Network

/// Watches the device's network path and reports meaningful changes
/// (interface set or satisfiability) on the main actor. The initial callback
/// that merely reports the current path is suppressed so consumers only react
/// to real transitions (Wi-Fi <-> cellular, connectivity loss/recovery).
@MainActor
final class AgenTTYNetworkPathObserver {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.tuist.agentty.network-path")
    private var lastPathSignature: String?
    private var isStarted = false

    var pathDidChange: ((_ isSatisfied: Bool) -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(for: path)
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in
                self.handlePathUpdate(signature: signature, isSatisfied: isSatisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }

    private func handlePathUpdate(signature: String, isSatisfied: Bool) {
        let previousSignature = lastPathSignature
        lastPathSignature = signature
        guard let previousSignature, previousSignature != signature else { return }
        EsmaLog.terminal.info(
            "network path changed satisfied=\(isSatisfied) signature=\(signature, privacy: .public)"
        )
        pathDidChange?(isSatisfied)
    }

    private nonisolated static func signature(for path: NWPath) -> String {
        let interfaceTypes = path.availableInterfaces
            .map { interfaceDescription($0.type) }
            .sorted()
            .joined(separator: ",")
        return "\(statusDescription(path.status))|\(interfaceTypes)"
    }

    private nonisolated static func statusDescription(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requiresConnection"
        @unknown default: "unknown"
        }
    }

    private nonisolated static func interfaceDescription(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "wired"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }
}
