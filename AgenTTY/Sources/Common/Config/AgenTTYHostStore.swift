import Foundation
import Observation

@MainActor
@Observable
final class AgenTTYHostStore {
    enum AdjacentDirection {
        case previous
        case next
    }

    enum AddHostMatch {
        case exact(AgenTTYHost)
        case related(AgenTTYHost)
    }

    private static let legacyHostsStorageKey = "hosts.v1"
    private static let legacyActiveHostIDStorageKey = "hosts.active.id"

    private let hostsStorageKey: String
    private let activeHostIDStorageKey: String

    private(set) var hosts: [AgenTTYHost]
    private(set) var activeHostID: UUID?

    @ObservationIgnored
    private let flavor: AgenTTYBuildFlavor
    @ObservationIgnored
    private let userDefaults: UserDefaults
    @ObservationIgnored
    private let encoder = JSONEncoder()
    @ObservationIgnored
    private let decoder = JSONDecoder()

    var activeHost: AgenTTYHost? {
        guard let activeHostID else { return nil }
        return hosts.first(where: { $0.id == activeHostID })
    }

    init(
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store,
        flavor: AgenTTYBuildFlavor = .current()
    ) {
        self.userDefaults = userDefaults
        self.flavor = flavor
        hostsStorageKey = flavor.hostsStorageKeyV2
        activeHostIDStorageKey = flavor.activeHostIDStorageKeyV2
        hosts = []
        activeHostID = nil

        if let screenshotHosts = AgenTTYSSHSeedPolicy.screenshotDemoHosts() {
            hosts = screenshotHosts
            activeHostID = AgenTTYSSHSeedPolicy.bootstrapSeedHostID
            return
        }

        let persistedHostsV2 = loadHostsV2()
        let initialHosts: [AgenTTYHost]
        if let persistedV2 = persistedHostsV2 {
            initialHosts = normalizeBootstrapSeedHost(in: persistedV2)
        } else {
            initialHosts = migrateFromLegacyHostsV1()
        }
        hosts = initialHosts
        var shouldPersistHosts = persistedHostsV2 == nil
        if let persistedHostsV2, persistedHostsV2 != hosts {
            shouldPersistHosts = true
        }

        let persistedActiveHostIDV2 = loadActiveHostIDV2()
        let initialActiveHostID: UUID?
        if let persistedActiveHostID = persistedActiveHostIDV2 {
            initialActiveHostID = persistedActiveHostID
        } else {
            initialActiveHostID = migrateActiveHostIDFromLegacy()
        }
        activeHostID = initialActiveHostID
        var shouldPersistActiveHostID = persistedActiveHostIDV2 == nil

        let activeHostIDBeforeNormalization = activeHostID
        normalizeStateAfterLoad()
        shouldPersistActiveHostID = shouldPersistActiveHostID || activeHostID != activeHostIDBeforeNormalization

        if shouldPersistHosts {
            persistHosts()
        }
        if shouldPersistActiveHostID {
            persistActiveHostID()
        }
    }

    func selectHost(id: UUID) {
        guard hosts.contains(where: { $0.id == id }) else { return }
        guard activeHostID != id else { return }
        activeHostID = id
        persistActiveHostID()
    }

    func clearActiveHost() {
        guard activeHostID != nil else { return }
        activeHostID = nil
        persistActiveHostID()
    }

    func selectAdjacentHost(direction: AdjacentDirection) {
        guard !hosts.isEmpty else { return }

        guard let activeHost else {
            switch direction {
            case .previous:
                selectHost(id: hosts[hosts.count - 1].id)
            case .next:
                selectHost(id: hosts[0].id)
            }
            return
        }

        guard let currentIndex = hosts.firstIndex(where: { $0.id == activeHost.id }) else {
            return
        }

        let nextIndex: Int
        switch direction {
        case .previous:
            nextIndex = currentIndex == 0 ? hosts.count - 1 : currentIndex - 1
        case .next:
            nextIndex = currentIndex == hosts.count - 1 ? 0 : currentIndex + 1
        }
        selectHost(id: hosts[nextIndex].id)
    }

    func addHost(_ draft: AgenTTYHostDraft) -> UUID {
        let newHost = AgenTTYHost(
            id: UUID(),
            label: draft.label,
            address: draft.address,
            usesTailscaleAddress: draft.usesTailscaleAddress,
            port: draft.port,
            username: draft.username,
            authentication: draft.authentication,
            connectionRoutePolicy: draft.connectionRoutePolicy,
            relayHostID: draft.relayHostID
        )
        hosts.append(newHost)
        persistHosts()
        return newHost.id
    }

    func addHostMatch(
        for draft: AgenTTYHostDraft,
        relatedAddresses: Set<String> = []
    ) -> AddHostMatch? {
        let normalizedDraftAddress = Self.normalizedAddress(draft.address)
        if let exactHost = hosts.first(where: {
            Self.normalizedAddress($0.address) == normalizedDraftAddress
                && $0.port == draft.port
                && $0.username == draft.username
        }) {
            return .exact(exactHost)
        }

        guard !relatedAddresses.isEmpty else { return nil }

        if let relatedHost = hosts.first(where: {
            relatedAddresses.contains(Self.normalizedAddress($0.address))
                && $0.port == draft.port
                && $0.username == draft.username
        }) {
            return .related(relatedHost)
        }

        return nil
    }

    func updateHost(id: UUID, with draft: AgenTTYHostDraft) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            return false
        }

        hosts[index] = AgenTTYHost(
            id: id,
            label: draft.label,
            address: draft.address,
            usesTailscaleAddress: draft.usesTailscaleAddress,
            port: draft.port,
            username: draft.username,
            authentication: draft.authentication,
            connectionRoutePolicy: draft.connectionRoutePolicy,
            relayHostID: draft.relayHostID
        )
        persistHosts()
        return true
    }

    func updateHostAuthentication(id: UUID, authentication: AgenTTYHostAuthentication) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let existing = hosts[index]
        guard existing.authentication != authentication else {
            return false
        }
        hosts[index] = AgenTTYHost(
            id: existing.id,
            label: existing.label,
            address: existing.address,
            usesTailscaleAddress: existing.usesTailscaleAddress,
            port: existing.port,
            username: existing.username,
            authentication: authentication,
            connectionRoutePolicy: existing.connectionRoutePolicy,
            relayHostID: existing.relayHostID
        )
        persistHosts()
        return true
    }

    func deleteHost(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts.remove(at: index)
        if activeHostID == id {
            activeHostID = nil
        }
        normalizeStateAfterLoad()
        persistHosts()
        persistActiveHostID()
    }

    func deleteHosts(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        let removedIDs = offsets.compactMap { index in
            hosts.indices.contains(index) ? hosts[index].id : nil
        }
        for index in offsets.sorted(by: >) where hosts.indices.contains(index) {
            hosts.remove(at: index)
        }
        if let activeHostID, removedIDs.contains(activeHostID) {
            self.activeHostID = nil
        }
        normalizeStateAfterLoad()
        persistHosts()
        persistActiveHostID()
    }

    private func normalizeStateAfterLoad() {
        if hosts.isEmpty {
            activeHostID = nil
            return
        }

        if let activeHostID,
           hosts.contains(where: { $0.id == activeHostID }) {
            return
        }

        if let bootstrapActiveHostID = bootstrapSeedActiveHostIDIfPresent(in: hosts) {
            activeHostID = bootstrapActiveHostID
            return
        }

        activeHostID = nil
    }

    private func persistHosts() {
        if let encoded = try? encoder.encode(hosts) {
            userDefaults.set(encoded, forKey: hostsStorageKey)
        }
    }

    private func persistActiveHostID() {
        userDefaults.set(activeHostID?.uuidString, forKey: activeHostIDStorageKey)
    }

    private func loadHostsV2() -> [AgenTTYHost]? {
        guard let data = userDefaults.data(forKey: hostsStorageKey) else {
            return nil
        }
        return try? decoder.decode([AgenTTYHost].self, from: data)
    }

    private func loadActiveHostIDV2() -> UUID? {
        guard let raw = userDefaults.string(forKey: activeHostIDStorageKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private func migrateFromLegacyHostsV1() -> [AgenTTYHost] {
        guard AgenTTYSSHSeedPolicy.shouldSeedBootstrapConfiguration(for: flavor) else {
            return []
        }

        guard let data = userDefaults.data(forKey: Self.legacyHostsStorageKey) else {
            return bootstrapSeedHostArray()
        }

        if let decodedV2 = try? decoder.decode([AgenTTYHost].self, from: data) {
            return normalizeBootstrapSeedHost(in: decodedV2)
        }

        guard let decodedLegacyHosts = try? decoder.decode([LegacyHostV1].self, from: data) else {
            return bootstrapSeedHostArray()
        }

        let migratedHosts = decodedLegacyHosts.map {
            AgenTTYHost(
                id: $0.id,
                label: $0.name,
                address: $0.address,
                port: AgenTTYConnection.defaultPort,
                username: $0.username,
                authentication: .key(AgenTTYSSHSeedPolicy.bootstrapSeedKeyID)
            )
        }

        return normalizeBootstrapSeedHost(in: migratedHosts)
    }

    private func migrateActiveHostIDFromLegacy() -> UUID? {
        guard let rawLegacy = userDefaults.string(forKey: Self.legacyActiveHostIDStorageKey),
              let legacyID = UUID(uuidString: rawLegacy),
              hosts.contains(where: { $0.id == legacyID }) else {
            return bootstrapSeedActiveHostIDIfPresent(in: hosts)
        }

        return legacyID
    }

    private func normalizeBootstrapSeedHost(in currentHosts: [AgenTTYHost]) -> [AgenTTYHost] {
        guard AgenTTYSSHSeedPolicy.shouldSeedBootstrapConfiguration(for: flavor) else {
            return currentHosts.filter {
                $0.id != AgenTTYSSHSeedPolicy.bootstrapSeedHostID &&
                $0.authentication.keyID != AgenTTYSSHSeedPolicy.bootstrapSeedKeyID
            }
        }

        let seededHosts = AgenTTYSSHSeedPolicy.bootstrapSeedHosts(for: flavor)
        guard !seededHosts.isEmpty else {
            return currentHosts
        }

        var normalized = currentHosts
        for (index, seededHost) in seededHosts.enumerated()
            where !normalized.contains(where: {
                $0.id == seededHost.id || (
                    Self.normalizedAddress($0.address) == Self.normalizedAddress(seededHost.address)
                        && $0.port == seededHost.port
                        && $0.username == seededHost.username
                )
            }) {
            normalized.insert(seededHost, at: min(index, normalized.endIndex))
        }
        return normalized
    }

    private func bootstrapSeedHostArray() -> [AgenTTYHost] {
        AgenTTYSSHSeedPolicy.bootstrapSeedHosts(for: flavor)
    }

    private func bootstrapSeedActiveHostIDIfPresent(in hosts: [AgenTTYHost]) -> UUID? {
        guard AgenTTYSSHSeedPolicy.shouldSeedBootstrapConfiguration(for: flavor),
              hosts.contains(where: { $0.id == AgenTTYSSHSeedPolicy.bootstrapSeedHostID }) else {
            return nil
        }
        return AgenTTYSSHSeedPolicy.bootstrapSeedHostID
    }

    nonisolated static func normalizedAddress(_ address: String) -> String {
        AgenTTYHostAddressNormalizer.normalizeForMatching(address)
    }
}

private struct LegacyHostV1: Codable {
    let id: UUID
    let name: String
    let address: String
    let username: String
}
