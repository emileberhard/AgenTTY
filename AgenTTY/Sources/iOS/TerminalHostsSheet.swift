import SwiftUI

enum HostsRoute: Hashable {
    case addSetupMethod
    case addManual
    case addAutomatic
    case addAutomaticTroubleshooting(HostFormDraft)
    case addAutomaticReview(HostFormDraft)
    case addOneTimePassword
    case edit(AgenTTYHost)
}

enum HostSetupMethod: String, CaseIterable, Hashable {
    case manual
    case pairWithCommand
    case oneTimePassword

    var title: String {
        switch self {
        case .manual:
            "Manual Setup"
        case .pairWithCommand:
            "Automatic Setup"
        case .oneTimePassword:
            "Password Setup"
        }
    }

    var subtitle: String {
        switch self {
        case .manual:
            "Enter the host details yourself and use a key the host already trusts."
        case .pairWithCommand:
            "Run one command on the host, scan its QR code, and let AgenTTY finish the setup."
        case .oneTimePassword:
            "Use your password once to install a key, then switch the host to key auth."
        }
    }

    var iconName: String {
        switch self {
        case .manual:
            "slider.horizontal.below.rectangle"
        case .pairWithCommand:
            "qrcode.viewfinder"
        case .oneTimePassword:
            "lock.badge.clock"
        }
    }

    var accentColor: Color {
        switch self {
        case .manual:
            .blue
        case .pairWithCommand:
            .orange
        case .oneTimePassword:
            .green
        }
    }
}

enum HostDetailSetupMethod: Hashable {
    case manual
    case automaticReview
    case oneTimePassword

    var cardMethod: HostSetupMethod {
        switch self {
        case .manual:
            .manual
        case .automaticReview:
            .pairWithCommand
        case .oneTimePassword:
            .oneTimePassword
        }
    }
}

extension HostSetupMethod {
    var analyticsMethod: AgenTTYAnalyticsHostSetupMethod {
        switch self {
        case .manual:
            .manual
        case .pairWithCommand:
            .automatic
        case .oneTimePassword:
            .oneTimePassword
        }
    }
}

enum HostKeyPickerSelection: Hashable {
    case existing(UUID)
    case addNew
}

struct HostFormDraft: Hashable {
    var label: String
    var address: String
    var portText: String
    var username: String
    var suggestedTailscaleAddress: String?
    var setupMethod: HostDetailSetupMethod
    var selectedKeyID: UUID?
    var password: String
    var passwordCredentialID: UUID?
    var pairingHostCandidates: [AgenTTYResolvedPairingHostCandidate]
    var automaticFlowID: String?
    var detectedUsernameSource: AgenTTYPairingDetectedUsernameSource?
    var detectedUsernameSuspicious: Bool?
    var automaticHostPlatform: AgenTTYAnalyticsHostPlatform?
    var automaticHostEnvironmentFlags: [AgenTTYAnalyticsHostEnvironmentFlag]
    var automaticOriginalAddress: String?
    var automaticOriginalPort: Int?
    var automaticOriginalUsername: String?
    var pinnedSSHHostPublicKeys: [String]
    var connectionRoutePolicy: AgenTTYHostConnectionRoutePolicy
    var relayHostID: String?
    var automaticVerificationFailureOutcome: AgenTTYSSHTerminationOutcome?
    var continuedWithoutVerifiedConnection: Bool

    var normalizedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedAddress: String {
        AgenTTYHostAddressNormalizer.normalizeForStorage(address)
    }

    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedSuggestedTailscaleAddress: String? {
        suggestedTailscaleAddress.map(AgenTTYHostAddressNormalizer.normalizeForStorage)
    }

    var isUsingSuggestedTailscaleAddress: Bool {
        guard let normalizedSuggestedTailscaleAddress else { return false }
        return AgenTTYHostStore.normalizedAddress(normalizedAddress)
            == AgenTTYHostStore.normalizedAddress(normalizedSuggestedTailscaleAddress)
    }

    var normalizedPassword: String {
        password.trimmingCharacters(in: .newlines)
    }

    var parsedPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isLabelValid: Bool { !normalizedLabel.isEmpty }
    var isAddressValid: Bool { !normalizedAddress.isEmpty }
    var isUsernameValid: Bool { !normalizedUsername.isEmpty }
    var isPortValid: Bool {
        guard let parsedPort else { return false }
        return (1...65_535).contains(parsedPort)
    }

    var selectedPairingCandidate: AgenTTYResolvedPairingHostCandidate? {
        pairingHostCandidates.first {
            AgenTTYHostStore.normalizedAddress($0.value)
                == AgenTTYHostStore.normalizedAddress(normalizedAddress)
        }
    }

    var pairingCandidateAddresses: Set<String> {
        Set(pairingHostCandidates.map { AgenTTYHostStore.normalizedAddress($0.value) })
    }

    var automaticHostEdited: Bool? {
        guard let automaticOriginalAddress else { return nil }
        return AgenTTYHostStore.normalizedAddress(automaticOriginalAddress)
            != AgenTTYHostStore.normalizedAddress(normalizedAddress)
    }

    var automaticPortEdited: Bool? {
        guard let automaticOriginalPort else { return nil }
        return parsedPort != automaticOriginalPort
    }

    var automaticUsernameEdited: Bool? {
        guard let automaticOriginalUsername else { return nil }
        return automaticOriginalUsername != normalizedUsername
    }

    func makeHostDraft(authentication: AgenTTYHostAuthentication) -> AgenTTYHostDraft? {
        AgenTTYHostDraft(
            label: label,
            address: address,
            usesTailscaleAddress: isUsingSuggestedTailscaleAddress,
            port: parsedPort ?? 0,
            username: username,
            authentication: authentication,
            connectionRoutePolicy: connectionRoutePolicy,
            relayHostID: relayHostID
        )
    }

    init(defaultKeyID: UUID?, setupMethod: HostDetailSetupMethod = .manual) {
        label = ""
        address = ""
        portText = String(AgenTTYConnection.defaultPort)
        username = ""
        suggestedTailscaleAddress = nil
        self.setupMethod = setupMethod
        selectedKeyID = defaultKeyID
        password = ""
        passwordCredentialID = UUID()
        pairingHostCandidates = []
        automaticFlowID = nil
        detectedUsernameSource = nil
        detectedUsernameSuspicious = nil
        automaticHostPlatform = nil
        automaticHostEnvironmentFlags = []
        automaticOriginalAddress = nil
        automaticOriginalPort = nil
        automaticOriginalUsername = nil
        pinnedSSHHostPublicKeys = []
        connectionRoutePolicy = .directOnly
        relayHostID = nil
        automaticVerificationFailureOutcome = nil
        continuedWithoutVerifiedConnection = false
    }

    init(host: AgenTTYHost) {
        label = host.label
        address = host.address
        portText = String(host.port)
        username = host.username
        suggestedTailscaleAddress = host.usesTailscaleAddress ? host.address : nil
        password = ""
        switch host.authentication {
        case .key(let keyID):
            setupMethod = .manual
            selectedKeyID = keyID
            passwordCredentialID = nil
        case .passwordBootstrap(let targetKeyID, let credentialID):
            setupMethod = .oneTimePassword
            selectedKeyID = targetKeyID
            passwordCredentialID = credentialID
        }
        pairingHostCandidates = []
        automaticFlowID = nil
        detectedUsernameSource = nil
        detectedUsernameSuspicious = nil
        automaticHostPlatform = nil
        automaticHostEnvironmentFlags = []
        automaticOriginalAddress = nil
        automaticOriginalPort = nil
        automaticOriginalUsername = nil
        pinnedSSHHostPublicKeys = []
        connectionRoutePolicy = host.connectionRoutePolicy
        relayHostID = host.relayHostID
        automaticVerificationFailureOutcome = nil
        continuedWithoutVerifiedConnection = false
    }

    mutating func setAutomaticConnectionValues(
        address: String,
        port: Int,
        username: String,
        preserveOriginalValues: Bool
    ) {
        let previousAddress = normalizedAddress
        self.address = address
        portText = String(port)
        self.username = username
        if label.isEmpty || label == previousAddress {
            label = address
        }
        if preserveOriginalValues {
            automaticOriginalAddress = automaticOriginalAddress ?? address
            automaticOriginalPort = automaticOriginalPort ?? port
            automaticOriginalUsername = automaticOriginalUsername ?? username
        }
    }
}

struct HostListReachabilityProbeTarget: Hashable, Sendable {
    let id: UUID
    let host: String
    let port: Int
}

enum HostListReachabilityIndicatorState: Equatable, Sendable {
    case checking
    case reachable
    case warning
    case unreachable

    var displayText: String {
        switch self {
        case .checking:
            "checking..."
        case .reachable:
            "online"
        case .warning:
            "unstable"
        case .unreachable:
            "offline"
        }
    }

    var symbolName: String {
        switch self {
        case .checking, .reachable:
            "antenna.radiowaves.left.and.right"
        case .warning, .unreachable:
            "antenna.radiowaves.left.and.right.slash"
        }
    }

    var tint: Color {
        switch self {
        case .checking:
            AppTheme.secondaryText
        case .reachable:
            .green
        case .warning:
            .yellow
        case .unreachable:
            .red
        }
    }
}

struct HostListReachabilityTracker: Equatable, Sendable {
    private(set) var completedChecks = 0
    private(set) var consecutiveFailures = 0
    private(set) var hasSeenSuccess = false
    private(set) var isChecking = true
    private(set) var lastFailureMessage: String?

    var indicatorState: HostListReachabilityIndicatorState {
        guard !isChecking, completedChecks > 0 else { return .checking }
        guard consecutiveFailures > 0 else { return .reachable }
        if hasSeenSuccess && consecutiveFailures == 1 {
            return .warning
        }
        return .unreachable
    }

    mutating func beginCheck() {
        isChecking = true
        lastFailureMessage = nil
    }

    mutating func recordSuccess() {
        completedChecks &+= 1
        consecutiveFailures = 0
        hasSeenSuccess = true
        isChecking = false
        lastFailureMessage = nil
    }

    mutating func recordFailure(message: String? = nil) {
        completedChecks &+= 1
        consecutiveFailures &+= 1
        isChecking = false
        lastFailureMessage = message
    }
}

enum HostReachabilityIndicatorState: Equatable, Sendable {
    case checking
    case reachable
    case unreachable
    case unavailable

    var symbolName: String {
        switch self {
        case .checking, .reachable:
            "antenna.radiowaves.left.and.right"
        case .unreachable, .unavailable:
            "antenna.radiowaves.left.and.right.slash"
        }
    }

    var statusText: String {
        switch self {
        case .checking:
            "Checking..."
        case .reachable:
            "Online"
        case .unreachable:
            "Offline"
        case .unavailable:
            "Enter a valid host and port"
        }
    }

    var tint: Color {
        switch self {
        case .checking, .unavailable:
            AppTheme.secondaryText
        case .reachable:
            .green
        case .unreachable:
            .yellow
        }
    }

    var trailingSymbolName: String? {
        switch self {
        case .checking:
            nil
        case .reachable:
            "antenna.radiowaves.left.and.right"
        case .unreachable, .unavailable:
            "antenna.radiowaves.left.and.right.slash"
        }
    }
}

extension HostReachabilityIndicatorState {
    init(tracker: HostListReachabilityTracker?) {
        guard let tracker else {
            self = .checking
            return
        }

        switch tracker.indicatorState {
        case .checking:
            self = .checking
        case .reachable, .warning:
            self = .reachable
        case .unreachable:
            self = .unreachable
        }
    }
}

enum HostDetailMode {
    case add(prefilledDraft: HostFormDraft?)
    case edit(AgenTTYHost)

    var isAdd: Bool {
        if case .add = self {
            return true
        }
        return false
    }

    var existing: AgenTTYHost? {
        if case .edit(let host) = self {
            return host
        }
        return nil
    }
}

enum PendingHostSaveDisposition: Hashable {
    case addNew
    case replaceExisting(UUID)
}

struct PendingHostSave {
    let hostDraft: AgenTTYHostDraft
    let disposition: PendingHostSaveDisposition
    let relatedMatch: AgenTTYHost?
}

@MainActor
func addAndSelectHost(_ draft: AgenTTYHostDraft, in hostStore: AgenTTYHostStore) -> UUID {
    let hostID = hostStore.addHost(draft)
    hostStore.selectHost(id: hostID)
    return hostID
}

@safe
struct TerminalHostsSheet: View {
    @Environment(AgenTTYHostStore.self) private var hostStore
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore
    @Environment(AgenTTYHostReachabilityMonitor.self) private var reachabilityMonitor
    @Environment(TerminalInputRouter.self) private var inputRouter

    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let passwordStore: AgenTTYSSHPasswordStore
    let analyticsClient: AgenTTYAnalyticsClient
    private let initialHostEditorID: UUID?

    @State private var nav: SheetNavigationCoordinator<HostsRoute>
    @State private var didApplyInitialRoute = false

    init(
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        passwordStore: AgenTTYSSHPasswordStore,
        analyticsClient: AgenTTYAnalyticsClient,
        initialHostEditorID: UUID? = nil
    ) {
        self.trustedHostKeyStore = trustedHostKeyStore
        self.passwordStore = passwordStore
        self.analyticsClient = analyticsClient
        self.initialHostEditorID = initialHostEditorID
        _nav = State(initialValue: SheetNavigationCoordinator<HostsRoute>())
    }

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.path) {
            hostList
                .navigationTitle("Hosts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add", systemImage: "plus") {
                            nav.navigate(to: .addSetupMethod)
                        }
                    }
                }
                .navigationDestination(for: HostsRoute.self) { route in
                    switch route {
                    case .addSetupMethod:
                        HostSetupMethodPickerView(
                            onSelectRoute: { route in
                                nav.path.append(route)
                            }
                        )
                    case .addManual:
                        HostDetailView(
                            mode: .add(prefilledDraft: nil),
                            fixedSetupMethod: .manual,
                            onFinished: { nav.resetToRoot() },
                            trustedHostKeyStore: trustedHostKeyStore,
                            passwordStore: passwordStore,
                            analyticsClient: analyticsClient
                        )
                    case .addAutomatic:
                        AutomaticHostSetupView(
                            analyticsClient: analyticsClient,
                            trustedHostKeyStore: trustedHostKeyStore
                        ) { route in
                            nav.presentDetail(route)
                        }
                    case .addAutomaticTroubleshooting(let seed):
                        AutomaticHostSetupTroubleshootingView(
                            draft: seed,
                            analyticsClient: analyticsClient,
                            trustedHostKeyStore: trustedHostKeyStore
                        ) { draft in
                            nav.presentDetail(.addAutomaticReview(draft))
                        }
                    case .addAutomaticReview(let seed):
                        HostDetailView(
                            mode: .add(prefilledDraft: seed),
                            fixedSetupMethod: .automaticReview,
                            onFinished: { nav.resetToRoot() },
                            trustedHostKeyStore: trustedHostKeyStore,
                            passwordStore: passwordStore,
                            analyticsClient: analyticsClient
                        )
                    case .addOneTimePassword:
                        HostDetailView(
                            mode: .add(prefilledDraft: nil),
                            fixedSetupMethod: .oneTimePassword,
                            onFinished: { nav.resetToRoot() },
                            trustedHostKeyStore: trustedHostKeyStore,
                            passwordStore: passwordStore,
                            analyticsClient: analyticsClient
                        )
                    case .edit(let host):
                        HostDetailView(
                            mode: .edit(host),
                            fixedSetupMethod: nil,
                            onFinished: { nav.resetToRoot() },
                            trustedHostKeyStore: trustedHostKeyStore,
                            passwordStore: passwordStore,
                            analyticsClient: analyticsClient
                        )
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $nav.selectedDetent)
        .sheetDetailNavigation(nav)
        .onAppear {
            guard !didApplyInitialRoute else { return }
            didApplyInitialRoute = true
            if let initialHostEditorID,
               let host = hostStore.hosts.first(where: { $0.id == initialHostEditorID }) {
                nav.selectedDetent = .large
                nav.path = [.edit(host)]
                return
            }

            guard AgenTTYAutomaticSetupPendingStateStore.load() != nil else { return }
            nav.selectedDetent = .large
            nav.path = [.addAutomatic]
        }
    }

    @ViewBuilder
    private var hostList: some View {
        if hostStore.hosts.isEmpty {
            ContentUnavailableView {
                Label("No Hosts", systemImage: "server.rack")
            } description: {
                Text("Add a host to get started.")
            } actions: {
                Button("Add Host") { nav.navigate(to: .addSetupMethod) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    ForEach(hostStore.hosts) { host in
                        Button { nav.navigate(to: .edit(host)) } label: {
                            HostCardRow(
                                host: host,
                                keyName: host.authentication.keyID.flatMap { keyStore.keyName(for: $0) },
                                isActive: host.id == hostStore.activeHostID,
                                reachabilityState: rowReachabilityState(for: host)
                            )
                        }
                        .listRowBackground(AppTheme.sheetListRowBackground)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .containerBackground(.clear, for: .navigation)
        }
    }

    private func rowReachabilityState(for host: AgenTTYHost) -> HostListReachabilityIndicatorState {
        if host.id == hostStore.activeHostID {
            switch inputRouter.hostConnectionPhase {
            case .connected:
                return .reachable
            case .connecting:
                return .checking
            case .disconnected:
                break
            }
        }
        return reachabilityMonitor.trackersByHostID[host.id]?.indicatorState ?? .checking
    }
}
