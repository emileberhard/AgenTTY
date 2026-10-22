import Foundation
import Observation

@MainActor
@Observable
final class AgenTTYHostReachabilityMonitor {
    private let baselinePollInterval: Duration
    private let focusedPollInterval: Duration

    private(set) var trackersByHostID: [UUID: HostListReachabilityTracker] = [:]

    @ObservationIgnored
    private var targetsByHostID: [UUID: HostListReachabilityProbeTarget] = [:]
    @ObservationIgnored
    private var baselineTask: Task<Void, Never>?
    @ObservationIgnored
    private var focusedTask: Task<Void, Never>?
    @ObservationIgnored
    private var inFlightHostIDs: Set<UUID> = []
    @ObservationIgnored
    private var isSceneActive = false
    @ObservationIgnored
    private var focusedHostID: UUID?

    init(
        baselinePollInterval: Duration = .seconds(20),
        focusedPollInterval: Duration = .seconds(5)
    ) {
        self.baselinePollInterval = baselinePollInterval
        self.focusedPollInterval = focusedPollInterval
    }

    func setSceneActive(_ isActive: Bool) {
        guard isSceneActive != isActive else { return }
        isSceneActive = isActive
        restartPollingTasks()
    }

    func updateHosts(_ hosts: [AgenTTYHost]) {
        let nextTargetsByHostID = Dictionary(
            uniqueKeysWithValues: hosts.map {
                (
                    $0.id,
                    HostListReachabilityProbeTarget(
                        id: $0.id,
                        host: $0.address,
                        port: $0.port
                    )
                )
            }
        )
        let targetIDs = Set(nextTargetsByHostID.keys)
        let currentIDs = Set(trackersByHostID.keys)

        if focusedHostID.map({ !targetIDs.contains($0) }) == true {
            focusedHostID = nil
        }

        var nextTrackersByHostID: [UUID: HostListReachabilityTracker] = [:]
        for host in hosts {
            nextTrackersByHostID[host.id] = trackersByHostID[host.id] ?? HostListReachabilityTracker()
        }

        let targetsChanged = nextTargetsByHostID != targetsByHostID || targetIDs != currentIDs
        targetsByHostID = nextTargetsByHostID
        if nextTrackersByHostID != trackersByHostID {
            trackersByHostID = nextTrackersByHostID
        }
        inFlightHostIDs = inFlightHostIDs.intersection(targetIDs)

        if targetsChanged {
            restartPollingTasks()
        }
    }

    func setFocusedHostID(_ hostID: UUID?) {
        let normalizedHostID = hostID.flatMap { targetsByHostID[$0] == nil ? nil : $0 }
        guard focusedHostID != normalizedHostID else { return }
        focusedHostID = normalizedHostID
        restartPollingTasks()
    }

    func clearFocusedHost(ifMatches hostID: UUID) {
        guard focusedHostID == hostID else { return }
        focusedHostID = nil
        restartPollingTasks()
    }

    func forceRefresh(hostID: UUID) {
        guard targetsByHostID[hostID] != nil else { return }
        var tracker = trackersByHostID[hostID] ?? HostListReachabilityTracker()
        tracker.beginCheck()
        trackersByHostID[hostID] = tracker

        Task { [weak self] in
            await self?.probeHostNow(hostID: hostID)
        }
    }

#if DEBUG
    func seedPreviewTrackers(_ trackersByHostID: [UUID: HostListReachabilityTracker]) {
        self.trackersByHostID = trackersByHostID
    }
#endif

    private func restartPollingTasks() {
        baselineTask?.cancel()
        baselineTask = nil
        focusedTask?.cancel()
        focusedTask = nil

        guard isSceneActive, !targetsByHostID.isEmpty else { return }

        baselineTask = Task { [weak self] in
            await self?.runBaselineLoop()
        }

        if let focusedHostID {
            focusedTask = Task { [weak self] in
                await self?.runFocusedLoop(hostID: focusedHostID)
            }
        }
    }

    private func runBaselineLoop() async {
        await probeHosts(Array(targetsByHostID.values))

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: baselinePollInterval)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            await probeHosts(Array(targetsByHostID.values))
        }
    }

    private func runFocusedLoop(hostID: UUID) async {
        await probeHostNow(hostID: hostID)

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: focusedPollInterval)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            await probeHostNow(hostID: hostID)
        }
    }

    private func probeHostNow(hostID: UUID) async {
        guard let target = targetsByHostID[hostID] else { return }
        await probeHosts([target])
    }

    private func probeHosts(_ targets: [HostListReachabilityProbeTarget]) async {
        let pendingTargets = targets.filter {
            targetsByHostID[$0.id] == $0 && !inFlightHostIDs.contains($0.id)
        }
        guard !pendingTargets.isEmpty else { return }

        let scheduledIDs = Set(pendingTargets.map(\.id))
        inFlightHostIDs.formUnion(scheduledIDs)
        defer {
            inFlightHostIDs.subtract(scheduledIDs)
        }

        await withTaskGroup(of: (UUID, String?)?.self, returning: Void.self) { group in
            for target in pendingTargets {
                group.addTask {
                    do {
                        try await AgenTTYHostReachabilityProbe.verifyReachable(
                            host: target.host,
                            port: target.port
                        )
                        return (target.id, nil)
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return (target.id, error.localizedDescription)
                    }
                }
            }

            for await observation in group {
                guard let (hostID, failureMessage) = observation else { continue }
                updateTracker(for: hostID, failureMessage: failureMessage)
                inFlightHostIDs.remove(hostID)
            }
        }
    }

    private func updateTracker(
        for hostID: UUID,
        failureMessage: String?
    ) {
        guard var tracker = trackersByHostID[hostID] else { return }

        if let failureMessage {
            tracker.recordFailure(message: failureMessage)
        } else {
            tracker.recordSuccess()
        }

        trackersByHostID[hostID] = tracker
    }
}
