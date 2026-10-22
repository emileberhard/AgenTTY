#if DEBUG
import SwiftUI

@MainActor
private struct TerminalHostsSheetPreviewFixture {
    let hostStore: AgenTTYHostStore
    let keyStore: AgenTTYSSHKeyStore
    let passwordStore: AgenTTYSSHPasswordStore
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let analyticsClient: AgenTTYAnalyticsClient
    let reachabilityMonitor: AgenTTYHostReachabilityMonitor

    init() {
        let suiteName = "dev.tuist.agentty.preview.terminal-hosts-sheet"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)

        let flavor: AgenTTYBuildFlavor = .dev
        let hostStore = AgenTTYHostStore(userDefaults: userDefaults, flavor: flavor)
        let keyStore = AgenTTYSSHKeyStore(userDefaults: userDefaults, flavor: flavor)
        let passwordStore = AgenTTYSSHPasswordStore(flavor: flavor)
        let trustedHostKeyStore = AgenTTYTrustedHostKeyStore(userDefaults: userDefaults, flavor: flavor)
        let analyticsClient = AgenTTYAnalyticsClient(flavor: flavor)
        let reachabilityMonitor = AgenTTYHostReachabilityMonitor()

        hostStore.deleteHost(id: AgenTTYSSHSeedPolicy.bootstrapSeedHostID)

        let defaultPreviewKeyName = "AgenTTY on iPhone"
        guard let previewKeyID = keyStore.defaultGeneratedKeyID(named: defaultPreviewKeyName)
            ?? keyStore.keysWithUsableMaterial.first?.id else {
            preconditionFailure("Failed to seed preview SSH key.")
        }
        let previewAuthentication: AgenTTYHostAuthentication = .key(previewKeyID)

        let hostDrafts = [
            AgenTTYHostDraft(
                label: "Example Workstation A",
                address: "192.0.2.10",
                port: 22,
                username: "developer",
                authentication: previewAuthentication
            ),
            AgenTTYHostDraft(
                label: "Example Workstation B",
                address: "host-b.example.invalid",
                port: 22,
                username: "developer",
                authentication: previewAuthentication
            ),
            AgenTTYHostDraft(
                label: "Example Workstation C",
                address: "host-c.example.invalid",
                port: 22,
                username: "developer",
                authentication: previewAuthentication
            ),
        ].compactMap { $0 }

        var hostIDs: [UUID] = []
        for draft in hostDrafts {
            hostIDs.append(hostStore.addHost(draft))
        }
        if hostIDs.indices.contains(1) {
            hostStore.selectHost(id: hostIDs[1])
        }

        self.hostStore = hostStore
        self.keyStore = keyStore
        self.passwordStore = passwordStore
        self.trustedHostKeyStore = trustedHostKeyStore
        self.analyticsClient = analyticsClient
        self.reachabilityMonitor = reachabilityMonitor
        reachabilityMonitor.updateHosts(hostStore.hosts)
        reachabilityMonitor.seedPreviewTrackers([
            hostIDs[0]: Self.makeReachabilityTracker(.reachable),
            hostIDs[1]: Self.makeReachabilityTracker(.reachable),
            hostIDs[2]: Self.makeReachabilityTracker(.unreachable),
        ])
    }

    private static func makeReachabilityTracker(
        _ state: HostListReachabilityIndicatorState
    ) -> HostListReachabilityTracker {
        var tracker = HostListReachabilityTracker()
        switch state {
        case .checking:
            return tracker
        case .reachable:
            tracker.recordSuccess()
            return tracker
        case .warning:
            tracker.recordSuccess()
            tracker.recordFailure()
            return tracker
        case .unreachable:
            tracker.recordFailure()
            tracker.recordFailure()
            return tracker
        }
    }
}

@MainActor
private struct TerminalHostsSheetPreviewPresenter: View {
    let fixture: TerminalHostsSheetPreviewFixture

    var body: some View {
        Rectangle()
            .fill(AppTheme.terminalBackground)
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                TerminalHostsSheet(
                    trustedHostKeyStore: fixture.trustedHostKeyStore,
                    passwordStore: fixture.passwordStore,
                    analyticsClient: fixture.analyticsClient
                )
                .environment(TerminalInputRouter())
                .environment(fixture.hostStore)
                .environment(fixture.keyStore)
                .environment(fixture.reachabilityMonitor)
                .preferredColorScheme(.dark)
            }
            .preferredColorScheme(.dark)
    }
}

#Preview("Hosts Sheet") {
    TerminalHostsSheetPreviewPresenter(fixture: TerminalHostsSheetPreviewFixture())
}
#endif
