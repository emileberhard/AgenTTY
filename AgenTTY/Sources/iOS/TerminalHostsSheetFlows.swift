import SwiftUI
import UIKit
import VisionKit

struct HostSetupSaveAnalyticsOutcome: Equatable {
    let stage: AgenTTYAnalyticsHostSetupStage
    let verificationAttemptCount: Int?
    let verificationFailureOutcome: AgenTTYSSHTerminationOutcome?

    init(
        overrideValidationWarning: Bool,
        verificationFailureOutcome: AgenTTYSSHTerminationOutcome?
    ) {
        guard overrideValidationWarning else {
            stage = .saveSucceeded
            verificationAttemptCount = nil
            self.verificationFailureOutcome = nil
            return
        }

        guard let verificationFailureOutcome else {
            stage = .saveSucceededUnreachable
            verificationAttemptCount = nil
            self.verificationFailureOutcome = nil
            return
        }

        stage = .saveSucceededUnverified
        verificationAttemptCount = 1
        self.verificationFailureOutcome = verificationFailureOutcome
    }
}

@safe
struct HostDetailView: View {
    @Environment(AgenTTYHostStore.self) private var hostStore
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore
    @Environment(AgenTTYHostReachabilityMonitor.self) private var reachabilityMonitor
    @Environment(TerminalInputRouter.self) private var inputRouter

    let mode: HostDetailMode
    let fixedSetupMethod: HostDetailSetupMethod?
    let onFinished: () -> Void
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let passwordStore: AgenTTYSSHPasswordStore
    let analyticsClient: AgenTTYAnalyticsClient

    @State private var draft: HostFormDraft
    @FocusState private var focusedField: FormField?
    @State private var showDeleteConfirmation = false
    @State private var showSSHKeyCreation = false
    @State private var trustedFingerprint: String?
    @State private var errorMessage: String?
    @State private var connectionValidationWarningMessage: String?
    @State private var pendingSave: PendingHostSave?
    @State private var pendingRelatedMatchSave: PendingHostSave?
    @State private var relatedHostMatch: AgenTTYHost?
    @State private var connectionTroubleshootingOutcome: AgenTTYSSHTerminationOutcome?
    @State private var connectionReachabilityFailureSubtype: AgenTTYHostReachabilityFailureSubtype?
    @State private var didRecordStartedAnalytics = false
    @State private var saveTask: Task<Void, Never>?
    @State private var storedPasswordAvailable = false
    @State private var showReachabilityTroubleshooting = false
    @State private var localHostSetupFlowID = UUID().uuidString.lowercased()
    @State private var resolvedConnectionStatus: AgenTTYHostConnectionStatusResolution?

    private var hostSetupFlowID: String {
        draft.automaticFlowID ?? localHostSetupFlowID
    }

    private enum FormField: Hashable {
        case label
        case address
        case port
        case username
        case password
    }

    init(
        mode: HostDetailMode,
        fixedSetupMethod: HostDetailSetupMethod?,
        onFinished: @escaping () -> Void,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        passwordStore: AgenTTYSSHPasswordStore,
        analyticsClient: AgenTTYAnalyticsClient
    ) {
        self.mode = mode
        self.fixedSetupMethod = fixedSetupMethod
        self.onFinished = onFinished
        self.trustedHostKeyStore = trustedHostKeyStore
        self.passwordStore = passwordStore
        self.analyticsClient = analyticsClient

        switch mode {
        case .add(let prefilledDraft):
            _draft = State(initialValue: prefilledDraft ?? HostFormDraft(
                defaultKeyID: nil,
                setupMethod: fixedSetupMethod ?? .manual
            ))
        case .edit(let host):
            _draft = State(initialValue: HostFormDraft(host: host))
        }
    }

    private var availableKeys: [AgenTTYSSHKey] {
        keyStore.keysWithUsableMaterial
    }

    private var selectedKeyPickerSelection: Binding<HostKeyPickerSelection> {
        Binding(
            get: {
                if let selectedKeyID = draft.selectedKeyID,
                   availableKeys.contains(where: { $0.id == selectedKeyID }) {
                    return .existing(selectedKeyID)
                }

                guard let fallbackKeyID = availableKeys.first?.id else {
                    return .addNew
                }

                return .existing(fallbackKeyID)
            },
            set: { selection in
                switch selection {
                case .existing(let keyID):
                    draft.selectedKeyID = keyID
                case .addNew:
                    showSSHKeyCreation = true
                }
            }
        )
    }

    private var selectedUsablePublicKey: String? {
        guard let selectedKeyID = draft.selectedKeyID else { return nil }
        return keyStore.publicKey(for: selectedKeyID)
    }

    private var isFormValid: Bool {
        guard draft.isLabelValid,
              draft.isAddressValid,
              draft.isPortValid,
              draft.isUsernameValid,
              let selectedKeyID = draft.selectedKeyID,
              availableKeys.contains(where: { $0.id == selectedKeyID }) else {
            return false
        }

        switch draft.setupMethod {
        case .manual, .automaticReview:
            return true
        case .oneTimePassword:
            return !draft.normalizedPassword.isEmpty || storedPasswordAvailable
        }
    }

    private var isSaving: Bool {
        saveTask != nil
    }

    private var trustedFingerprintText: String {
        trustedFingerprint ?? "not trusted yet"
    }

    private var trustedFingerprintStyle: Color {
        trustedFingerprint == nil ? AppTheme.secondaryText : .green
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private var connectionValidationAlertIsPresented: Binding<Bool> {
        Binding(
            get: { connectionValidationWarningMessage != nil },
            set: { isPresented in
                if !isPresented {
                    connectionValidationWarningMessage = nil
                    pendingSave = nil
                    connectionReachabilityFailureSubtype = nil
                }
            }
        )
    }

    private var connectionFailureAlertTitle: String {
        if let connectionTroubleshootingOutcome {
            return AgenTTYSSHRecoveryGuidance.guidance(for: connectionTroubleshootingOutcome).title
        }
        return "Couldn't Reach Host"
    }

    private var duplicateHostDialogIsPresented: Binding<Bool> {
        Binding(
            get: { relatedHostMatch != nil && pendingRelatedMatchSave != nil },
            set: { isPresented in
                if !isPresented {
                    relatedHostMatch = nil
                    pendingRelatedMatchSave = nil
                }
            }
        )
    }

    private var reachabilityIndicatorState: HostReachabilityIndicatorState {
        guard case .edit(let host) = mode else { return .unavailable }
        if host.id == hostStore.activeHostID, inputRouter.hostConnectionPhase == .connected {
            return .reachable
        }
        if let resolvedConnectionStatus {
            return resolvedConnectionStatus.isReachable ? .reachable : .unreachable
        }
        return HostReachabilityIndicatorState(tracker: reachabilityMonitor.trackersByHostID[host.id])
    }

    private var reachabilityFailureMessage: String? {
        if let resolvedConnectionStatus, !resolvedConnectionStatus.isReachable {
            return resolvedConnectionStatus.failureMessage
        }
        guard case .edit(let host) = mode else { return nil }
        return reachabilityMonitor.trackersByHostID[host.id]?.lastFailureMessage
    }

    private var connectionMethodStatus: AgenTTYHostConnectionMethodStatus? {
        guard case .edit = mode else { return nil }
        guard let resolvedConnectionStatus else { return nil }
        return AgenTTYHostConnectionMethodStatus(method: resolvedConnectionStatus.method)
    }

    private var canRetryReachability: Bool {
        mode.existing != nil && reachabilityIndicatorState != .checking
    }

    private var shouldShowReachabilityActions: Bool {
        reachabilityIndicatorState == .unreachable
    }

    private var tailscaleReachabilityReminder: String {
        "If you chose Tailscale for this host, make sure Tailscale is installed and connected on this iPhone before saving."
    }

    private var hostAddressNormalizationNote: String? {
        guard !draft.address.isEmpty else { return nil }
        let normalizedAddress = draft.normalizedAddress
        guard !normalizedAddress.isEmpty, normalizedAddress != draft.address else { return nil }
        return "AgenTTY will save and verify this host as \(normalizedAddress)."
    }

    private var deleteHostConfirmationTitle: String {
        guard case .edit(let host) = mode else { return "Delete" }
        return "Delete \"\(host.label)\""
    }

    var body: some View {
        List {
            if case .edit = mode {
                reachabilityStatusSection
            }

            if draft.isUsingSuggestedTailscaleAddress {
                tailscaleSetupSection
            }

            if !automaticReviewWarnings.isEmpty {
                automaticReviewWarningsSection
            }

            switch draft.setupMethod {
            case .manual, .automaticReview:
                hostDetailsSection(
                    showLabelField: true,
                    showConnectionFields: true,
                    includePasswordField: false,
                    header: "Connection Details"
                )
                manualKeySection

                if let selectedUsablePublicKey {
                    Section {
                        SSHPublicKeyExportView(publicKey: selectedUsablePublicKey)
                    } header: {
                        Text("Public Key")
                    } footer: {
                        Text("Copy or share this public key and add it to ~/.ssh/authorized_keys on the host before saving.")
                    }
                }
            case .oneTimePassword:
                hostDetailsSection(
                    showLabelField: true,
                    showConnectionFields: true,
                    includePasswordField: true,
                    header: "Connection Details"
                )
                oneTimePasswordKeySection
            }

            if case .edit(let host) = mode {
                trustedHostKeySection(for: host)
                deleteHostSection
            }
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .disabled(isSaving)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle(mode.isAdd ? "New Host" : (draft.label.isEmpty ? "Edit Host" : draft.label))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save") { commitSave() }
                        .disabled(!isFormValid)
                }
            }
        }
        .onAppear {
            syncSelectedKeyIfNeeded()
            refreshTrustedFingerprint()
            refreshStoredPasswordAvailability()
            if case .edit(let host) = mode {
                reachabilityMonitor.setFocusedHostID(host.id)
            }
            guard shouldRecordStartedAnalytics else { return }
            guard !didRecordStartedAnalytics else { return }
            didRecordStartedAnalytics = true
            recordHostSetupFlow(stage: .screenViewed, hostID: mode.existing?.id)
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            if case .edit(let host) = mode {
                reachabilityMonitor.clearFocusedHost(ifMatches: host.id)
            }
        }
        .onChange(of: keyStore.usableKeyIDs) { _, _ in
            syncSelectedKeyIfNeeded()
        }
        .navigationDestination(isPresented: $showReachabilityTroubleshooting) {
            HostReachabilityTroubleshootingView(
                draft: draft,
                failureMessage: reachabilityFailureMessage,
                failureOutcome: connectionTroubleshootingOutcome,
                failureSubtype: connectionReachabilityFailureSubtype
            )
        }
        .confirmationDialog(
            "Possible Duplicate Host",
            isPresented: duplicateHostDialogIsPresented,
            titleVisibility: .visible,
            actions: duplicateHostDialogActions,
            message: duplicateHostDialogMessage
        )
        .sheetDestructiveAlert(
            title: "Delete Host",
            confirmTitle: deleteHostConfirmationTitle,
            message: "This host will be removed. This cannot be undone.",
            isPresented: $showDeleteConfirmation,
            onConfirm: confirmDeleteHost
        )
        .alert(
            "Host Setup Error",
            isPresented: errorAlertIsPresented
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
        .alert(
            connectionFailureAlertTitle,
            isPresented: connectionValidationAlertIsPresented
        ) {
            Button("Edit Host", role: .cancel) {
                connectionValidationWarningMessage = nil
                pendingSave = nil
                connectionReachabilityFailureSubtype = nil
            }
            Button("Troubleshoot") {
                showReachabilityTroubleshooting = true
            }
            Button("Save Anyway", role: .destructive) {
                guard let pendingSave else { return }
                recordHostSetupFlow(
                    stage: .saveAnywayTapped,
                    hostID: mode.existing?.id,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress
                )
                connectionValidationWarningMessage = nil
                self.pendingSave = nil
                connectionReachabilityFailureSubtype = nil
                finishSave(with: pendingSave, overrideValidationWarning: true)
            }
        } message: {
            Text(connectionValidationWarningMessage ?? "Unknown connection validation error.")
        }
        .sheet(isPresented: $showSSHKeyCreation) {
            TerminalSSHKeysSheet(
                analyticsClient: analyticsClient,
                startsInAddMode: true,
                onAddKeyCreated: { newKeyID in
                    draft.selectedKeyID = newKeyID
                    showSSHKeyCreation = false
                }
            )
            .environment(keyStore)
            .environment(hostStore)
            .esmaTermSheetBackground()
        }
        .task(id: connectionMethodResolutionTaskID) {
            guard case .edit(let host) = mode else {
                resolvedConnectionStatus = nil
                return
            }
            resolvedConnectionStatus = await AgenTTYHostConnectionMethodResolver.resolveCurrentStatus(
                for: host,
                liveMethod: inputRouter.hostConnectionMethod,
                isActiveHostConnected: host.id == hostStore.activeHostID
                    && inputRouter.hostConnectionPhase == .connected
            )
        }
    }

    private var connectionMethodResolutionTaskID: String? {
        guard case .edit(let host) = mode else { return nil }
        var components = [
            host.id.uuidString.lowercased(),
            AgenTTYHostStore.normalizedAddress(host.address),
            host.connectionRoutePolicy.rawValue,
            host.relayHostID ?? "no-relay",
            host.usesTailscaleAddress ? "tailscale" : "direct",
        ]
        if host.id == hostStore.activeHostID {
            components.append(String(describing: inputRouter.hostConnectionPhase))
            components.append(inputRouter.hostConnectionMethod?.rawValue ?? "no-live-method")
        }
        return components.joined(separator: "|")
    }

    @ViewBuilder
    private func trustedHostKeySection(for host: AgenTTYHost) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "key.2.on.ring")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 18)

                Text("Trusted Host Key")
                    .foregroundStyle(AppTheme.primaryText)

                Spacer(minLength: 4)

                Text(trustedFingerprintText)
                    .font(.caption.monospaced())
                    .foregroundStyle(trustedFingerprintStyle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 4)
            .listRowBackground(AppTheme.sheetListRowBackground)

            if trustedFingerprint != nil {
                Button("Reset Trusted Host Key", role: .destructive) {
                    trustedHostKeyStore.resetTrustedHostKey(hostID: host.id)
                    refreshTrustedFingerprint()
                }
                .listRowBackground(AppTheme.sheetListRowBackground)
            }
        }
    }

    private var deleteHostSection: some View {
        Section {
            SheetDestructiveActionButton { showDeleteConfirmation = true }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func duplicateHostDialogActions() -> some View {
        if let relatedHostMatch, let pendingRelatedMatchSave {
            Button("Replace \"\(relatedHostMatch.label)\"") {
                let replacementSave = PendingHostSave(
                    hostDraft: pendingRelatedMatchSave.hostDraft,
                    disposition: .replaceExisting(relatedHostMatch.id),
                    relatedMatch: nil
                )
                self.relatedHostMatch = nil
                self.pendingRelatedMatchSave = nil
                beginConnectionValidation(for: replacementSave)
            }
            Button("Keep Both") {
                let keepBothSave = PendingHostSave(
                    hostDraft: pendingRelatedMatchSave.hostDraft,
                    disposition: .addNew,
                    relatedMatch: nil
                )
                self.relatedHostMatch = nil
                self.pendingRelatedMatchSave = nil
                beginConnectionValidation(for: keepBothSave)
            }
        }
        Button("Cancel", role: .cancel) {
            relatedHostMatch = nil
            pendingRelatedMatchSave = nil
        }
    }

    @ViewBuilder
    private func duplicateHostDialogMessage() -> some View {
        if relatedHostMatch != nil {
            Text("AgenTTY found an existing host that looks like the same machine. Replace it or keep both entries.")
        }
    }

    private func confirmDeleteHost() {
        guard case .edit(let host) = mode else { return }
        if let credentialID = host.authentication.credentialID {
            try? passwordStore.deletePassword(for: credentialID)
        }
        hostStore.deleteHost(id: host.id)
        onFinished()
    }

    @ViewBuilder
    private var reachabilityStatusSection: some View {
        Section {
            reachabilityStatusRow
            if let connectionMethodStatus {
                connectionMethodStatusRow(status: connectionMethodStatus)
            }

            if shouldShowReachabilityActions {
                reachabilityActionsRow
            }
        } header: {
            Text("Status")
        }
    }

    private var reachabilityStatusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: reachabilityIndicatorState.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            Text("Reachability")
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            DetailReachabilityStatusPill(state: reachabilityIndicatorState)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private func connectionMethodStatusRow(
        status: AgenTTYHostConnectionMethodStatus
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: status.method.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            Text("Current Path")
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            DetailConnectionMethodPill(method: status.method)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private var reachabilityActionsRow: some View {
        HStack(spacing: 0) {
            Button {
                retryReachability()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canRetryReachability ? AppTheme.secondaryText : AppTheme.secondaryText.opacity(0.5))
                    Text("Retry")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(canRetryReachability ? AppTheme.primaryText : AppTheme.secondaryText.opacity(0.7))
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canRetryReachability)

            Rectangle()
                .fill(AppTheme.surfaceOrnamentStroke)
                .frame(width: 0.5, height: 20)

            Button {
                recordHostSetupFlow(stage: .troubleshootOpened, hostID: mode.existing?.id)
                showReachabilityTroubleshooting = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text("Troubleshoot")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    @ViewBuilder
    private var tailscaleSetupSection: some View {
        Section {
            infoRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Tailscale Selected",
                subtitle: "This pairing is using the host's Tailscale hostname. \(tailscaleReachabilityReminder)"
            )
        } footer: {
            Text("AgenTTY will run a reachability check before saving so you can fix the address first if this iPhone cannot currently reach the host.")
        }
    }

    @ViewBuilder
    private var automaticReviewWarningsSection: some View {
        Section {
            ForEach(automaticReviewWarnings, id: \.title) { warning in
                HostInfoRow(
                    icon: warning.icon,
                    title: warning.title,
                    subtitle: warning.subtitle
                )
            }
        } header: {
            Text("Review Warnings")
        } footer: {
            Text("AgenTTY detected one or more details that may need manual confirmation before this host is saved.")
        }
    }

    @ViewBuilder
    private var manualKeySection: some View {
        Section {
            keyPickerContent
        } header: {
            Text("Private Key")
        }
    }

    @ViewBuilder
    private var oneTimePasswordKeySection: some View {
        Section {
            keyPickerContent
        } header: {
            Text("Private Key")
        } footer: {
            Text("AgenTTY will install this key during the first login, then delete the stored password and keep the host on key auth.")
        }
    }

    @ViewBuilder
    private func hostDetailsSection(
        showLabelField: Bool,
        showConnectionFields: Bool,
        includePasswordField: Bool,
        header: String,
        footer: String? = nil
    ) -> some View {
        Section {
            if showLabelField {
                fieldRow(
                    icon: "tag",
                    label: "Label",
                    placeholder: "Host label",
                    text: $draft.label,
                    field: .label,
                    isValid: draft.isLabelValid,
                    autocapitalization: .words,
                    submitLabel: showConnectionFields ? .next : .done
                ) {
                    if showConnectionFields {
                        focusedField = .address
                    } else {
                        focusedField = nil
                    }
                }
            }

            if showConnectionFields {
                fieldRow(
                    icon: "network",
                    label: "Host",
                    placeholder: "IP or hostname",
                    text: $draft.address,
                    field: .address,
                    isValid: draft.isAddressValid,
                    keyboardType: .URL,
                    submitLabel: .next
                ) { focusedField = .port }

                if let hostAddressNormalizationNote {
                    infoRow(
                        icon: "textformat",
                        title: "Host Normalized",
                        subtitle: hostAddressNormalizationNote
                    )
                }

                fieldRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    label: "Port",
                    placeholder: "22",
                    text: $draft.portText,
                    field: .port,
                    isValid: draft.isPortValid,
                    keyboardType: .numberPad,
                    submitLabel: .next
                ) { focusedField = .username }

                fieldRow(
                    icon: "person",
                    label: "User",
                    placeholder: "SSH username",
                    text: $draft.username,
                    field: .username,
                    isValid: draft.isUsernameValid,
                    submitLabel: includePasswordField ? .next : .done
                ) {
                    if includePasswordField {
                        focusedField = .password
                    } else {
                        commitSave()
                    }
                }
            } else {
                infoRow(
                    icon: "wand.and.stars",
                    title: "Connection details come from pairing",
                    subtitle: "Run the host command below, then review the suggested values here."
                )
            }

            if includePasswordField {
                secureFieldRow(
                    icon: "lock",
                    label: "Password",
                    placeholder: storedPasswordAvailable ? "Stored password available" : "SSH password",
                    text: $draft.password,
                    field: .password,
                    isValid: !draft.normalizedPassword.isEmpty || storedPasswordAvailable,
                    onSubmit: commitSave
                )
            }
        } header: {
            Text(header)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    @ViewBuilder
    private var keyPickerContent: some View {
        if availableKeys.isEmpty {
            Button {
                showSSHKeyCreation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "key.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("No usable SSH keys available.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.primaryText)

                        Text("Tap to create one.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .listRowBackground(AppTheme.sheetListRowBackground)
        } else {
            SheetPickerRow(icon: "key", label: "Key", selection: selectedKeyPickerSelection) {
                ForEach(availableKeys) { key in
                    Text(key.name).tag(HostKeyPickerSelection.existing(key.id))
                }

                Label("Add New Key...", systemImage: "plus")
                    .tag(HostKeyPickerSelection.addNew)
            }
        }
    }

    private func refreshTrustedFingerprint() {
        guard let host = mode.existing else {
            trustedFingerprint = nil
            return
        }

        trustedFingerprint = trustedHostKeyStore.trustedFingerprint(
            hostID: host.id,
            address: host.address,
            port: host.port
        )
    }

    private func refreshStoredPasswordAvailability() {
        guard case .passwordBootstrap(_, let credentialID) = mode.existing?.authentication else {
            storedPasswordAvailable = false
            return
        }
        storedPasswordAvailable = passwordStore.hasPassword(for: credentialID)
    }

    private func infoRow(icon: String, title: String, subtitle: String) -> some View {
        HostInfoRow(icon: icon, title: title, subtitle: subtitle)
    }

    private func fieldRow(
        icon: String,
        label: String,
        placeholder: String,
        text: Binding<String>,
        field: FormField,
        isValid: Bool,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .never,
        submitLabel: SubmitLabel = .next,
        onSubmit: @escaping () -> Void
    ) -> some View {
        SheetFormFieldRow(
            icon: icon,
            label: label,
            placeholder: placeholder,
            text: text,
            field: field,
            focusedField: $focusedField,
            isValid: isValid,
            keyboardType: keyboardType,
            autocapitalization: autocapitalization,
            submitLabel: submitLabel,
            onSubmit: onSubmit
        )
    }

    private func secureFieldRow(
        icon: String,
        label: String,
        placeholder: String,
        text: Binding<String>,
        field: FormField,
        isValid: Bool,
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    focusedField == field ? AppTheme.primaryText : AppTheme.secondaryText
                )
                .frame(width: 18)

            Text(label)
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            SecureField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .onSubmit(onSubmit)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green.opacity(0.7))
                .opacity(isValid ? 1 : 0)
                .scaleEffect(isValid ? 1 : 0.5)
                .frame(width: 16)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: isValid)
        }
        .padding(.vertical, 4)
        .listRowBackground(
            focusedField == field ? AppTheme.surfaceOrnamentFill : AppTheme.sheetListRowBackground
        )
    }

    private func syncSelectedKeyIfNeeded() {
        guard let selectedKeyID = draft.selectedKeyID else {
            draft.selectedKeyID = availableKeys.first?.id
            return
        }

        guard availableKeys.contains(where: { $0.id == selectedKeyID }) else {
            draft.selectedKeyID = availableKeys.first?.id
            return
        }
    }

    private func resolvedAuthentication() -> AgenTTYHostAuthentication? {
        guard let selectedKeyID = draft.selectedKeyID,
              availableKeys.contains(where: { $0.id == selectedKeyID }) else {
            return nil
        }

        switch draft.setupMethod {
        case .oneTimePassword:
            let credentialID = draft.passwordCredentialID ?? UUID()
            return .passwordBootstrap(targetKeyID: selectedKeyID, credentialID: credentialID)
        case .manual, .automaticReview:
            return .key(selectedKeyID)
        }
    }

    private func persistPasswordIfNeeded(authentication: AgenTTYHostAuthentication) throws {
        guard case .passwordBootstrap(_, let credentialID) = authentication else { return }
        if !draft.normalizedPassword.isEmpty {
            try passwordStore.storePassword(draft.normalizedPassword, credentialID: credentialID)
            storedPasswordAvailable = true
            draft.passwordCredentialID = credentialID
            draft.password = ""
        }
    }

    private func cleanupReplacedPasswordCredential(
        previousAuthentication: AgenTTYHostAuthentication?,
        nextAuthentication: AgenTTYHostAuthentication
    ) {
        guard let previousCredentialID = previousAuthentication?.credentialID else { return }
        if nextAuthentication.credentialID == previousCredentialID {
            return
        }
        try? passwordStore.deletePassword(for: previousCredentialID)
    }

    private func commitSave() {
        guard !isSaving, let pendingSave = pendingSavePlan() else {
            return
        }
        recordHostSetupFlow(
            stage: .saveTapped,
            hostID: mode.existing?.id,
            usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress
        )
        if case .add = mode,
           let existingHost = pendingSave.relatedMatch {
            relatedHostMatch = existingHost
            pendingRelatedMatchSave = pendingSave
            return
        }

        beginConnectionValidation(for: pendingSave)
    }

    private func pendingSavePlan() -> PendingHostSave? {
        guard isFormValid,
              let authentication = resolvedAuthentication(),
              let hostDraft = draft.makeHostDraft(authentication: authentication) else {
            return nil
        }
        if case .add = mode,
           let addMatch = hostStore.addHostMatch(
               for: hostDraft,
               relatedAddresses: draft.pairingCandidateAddresses
           ) {
            switch addMatch {
            case .exact(let exactHost):
                return PendingHostSave(
                    hostDraft: hostDraft,
                    disposition: .replaceExisting(exactHost.id),
                    relatedMatch: nil
                )
            case .related(let relatedHost):
                return PendingHostSave(
                    hostDraft: hostDraft,
                    disposition: .addNew,
                    relatedMatch: relatedHost
                )
            }
        }

        return PendingHostSave(
            hostDraft: hostDraft,
            disposition: .addNew,
            relatedMatch: nil
        )
    }

    private func shouldValidateConnectionBeforeSave(for hostDraft: AgenTTYHostDraft) -> Bool {
        switch mode {
        case .add:
            return true
        case .edit(let host):
            return host.address != hostDraft.address
                || host.port != hostDraft.port
                || host.username != hostDraft.username
                || host.authentication != hostDraft.authentication
        }
    }

    private func finishSave(with pendingSave: PendingHostSave, overrideValidationWarning: Bool = false) {
        do {
            let savedHostID: UUID
            let persistedHostDraft: AgenTTYHostDraft
            let saveAnalyticsOutcome = HostSetupSaveAnalyticsOutcome(
                overrideValidationWarning: overrideValidationWarning,
                verificationFailureOutcome: connectionTroubleshootingOutcome
            )
            switch (mode, pendingSave.disposition) {
            case (.add, .addNew):
                try persistPasswordIfNeeded(authentication: pendingSave.hostDraft.authentication)
                savedHostID = addAndSelectHost(pendingSave.hostDraft, in: hostStore)
                persistedHostDraft = pendingSave.hostDraft
            case (.add, .replaceExisting(let existingHostID)):
                let existingHost = hostStore.hosts.first { $0.id == existingHostID }
                let resolvedReplacementDraft = resolvedReplacementDraft(
                    pendingSave.hostDraft,
                    existingHost: existingHost
                )
                try persistPasswordIfNeeded(authentication: resolvedReplacementDraft.authentication)
                let previousAuthentication = existingHost?.authentication
                _ = hostStore.updateHost(id: existingHostID, with: resolvedReplacementDraft)
                cleanupReplacedPasswordCredential(
                    previousAuthentication: previousAuthentication,
                    nextAuthentication: resolvedReplacementDraft.authentication
                )
                hostStore.selectHost(id: existingHostID)
                savedHostID = existingHostID
                persistedHostDraft = resolvedReplacementDraft
            case (.edit(let host), _):
                try persistPasswordIfNeeded(authentication: pendingSave.hostDraft.authentication)
                let previousAuthentication = host.authentication
                _ = hostStore.updateHost(id: host.id, with: pendingSave.hostDraft)
                cleanupReplacedPasswordCredential(
                    previousAuthentication: previousAuthentication,
                    nextAuthentication: pendingSave.hostDraft.authentication
                )
                savedHostID = host.id
                persistedHostDraft = pendingSave.hostDraft
            }
            try persistPinnedHostKeysIfNeeded(
                hostID: savedHostID,
                hostDraft: persistedHostDraft,
                pinnedSSHHostPublicKeys: draft.pinnedSSHHostPublicKeys
            )

            recordHostSetupFlow(
                stage: saveAnalyticsOutcome.stage,
                savedHostCount: hostStore.hosts.count,
                hostID: savedHostID,
                usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                verificationAttemptCount: saveAnalyticsOutcome.verificationAttemptCount,
                verificationFailureOutcome: saveAnalyticsOutcome.verificationFailureOutcome
            )
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
            recordHostSetupFlow(
                stage: .failed,
                hostID: mode.existing?.id,
                errorCategory: .save,
                errorMessage: error.localizedDescription,
                usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress
            )
        }
    }

    private func persistPinnedHostKeysIfNeeded(
        hostID: UUID,
        hostDraft: AgenTTYHostDraft,
        pinnedSSHHostPublicKeys: [String]
    ) throws {
        guard !pinnedSSHHostPublicKeys.isEmpty else {
            return
        }
        try trustedHostKeyStore.storePinnedHostKeys(
            hostID: hostID,
            address: hostDraft.address,
            port: hostDraft.port,
            openSSHPublicKeys: pinnedSSHHostPublicKeys
        )
    }

    private func reachabilityWarningMessage(for error: AgenTTYHostReachabilityError) -> String {
        let guidance = AgenTTYHostReachabilityGuidance.guidance(for: error)
        var lines = [guidance.message]
        if error.failureSubtype == .dns {
            lines.append(guidance.suggestions.map { "\($0.title): \($0.subtitle)" }.joined(separator: "\n"))
        }
        if draft.isUsingSuggestedTailscaleAddress {
            lines.append(tailscaleReachabilityReminder)
        }
        lines.append("You can go back and edit the host, or save it anyway.")
        return lines.joined(separator: "\n\n")
    }

    private func verificationWarningMessage(for outcome: AgenTTYSSHTerminationOutcome) -> String {
        let guidance = AgenTTYSSHRecoveryGuidance.guidance(for: outcome)
        return "\(guidance.message)\n\nYou can keep editing this host, troubleshoot it, or save it anyway."
    }

    private func verificationHostID(for pendingSave: PendingHostSave) -> UUID {
        switch (mode, pendingSave.disposition) {
        case (.add, .replaceExisting(let existingHostID)):
            existingHostID
        case (.edit(let host), _):
            host.id
        case (.add, .addNew):
            UUID()
        }
    }

    private func retryReachability() {
        guard let host = mode.existing else { return }
        reachabilityMonitor.forceRefresh(hostID: host.id)
    }

    private var analyticsMethod: AgenTTYAnalyticsHostSetupMethod {
        draft.setupMethod.cardMethod.analyticsMethod
    }

    private var automaticReviewWarnings: [(icon: String, title: String, subtitle: String)] {
        guard draft.setupMethod == .automaticReview else { return [] }

        var warnings: [(icon: String, title: String, subtitle: String)] = []
        if draft.detectedUsernameSuspicious == true {
            warnings.append((
                icon: "exclamationmark.triangle",
                title: "Username Looks Unreliable",
                subtitle: "AgenTTY had to fall back while resolving the host username. Double-check it before saving."
            ))
        } else if draft.detectedUsernameSource == .envUser {
            warnings.append((
                icon: "exclamationmark.triangle",
                title: "Username Needs Review",
                subtitle: "The host username came from the shell environment instead of the authoritative id command."
            ))
        }

        if let candidate = draft.selectedPairingCandidate,
           AgenTTYPairingHostCandidateRanking.isLowConfidence(kind: candidate.kind) {
            warnings.append((
                icon: "exclamationmark.triangle",
                title: "Host Address May Be Local-Only",
                subtitle: "This host suggestion may not resolve reliably from the iPhone unless both devices share the same local network."
            ))
        }

        if draft.continuedWithoutVerifiedConnection {
            warnings.append((
                icon: "antenna.radiowaves.left.and.right.slash",
                title: "Connection Was Not Fully Verified",
                subtitle: "AgenTTY completed key setup, but it could not verify a usable terminal session before this review step."
            ))
        }

        return warnings
    }

    private var shouldRecordStartedAnalytics: Bool {
        switch mode {
        case .add(let prefilledDraft):
            return prefilledDraft == nil
        case .edit:
            return true
        }
    }

    private func recordHostSetupFlow(
        stage: AgenTTYAnalyticsHostSetupStage,
        savedHostCount: Int? = nil,
        hostID: UUID? = nil,
        errorCategory: AgenTTYAnalyticsHostSetupErrorCategory? = nil,
        errorMessage: String? = nil,
        usesTailscaleAddress: Bool? = nil,
        probeAttemptCount: Int? = nil,
        reachabilityFailureSubtype: AgenTTYHostReachabilityFailureSubtype? = nil,
        verificationAttemptCount: Int? = nil,
        verificationFailureOutcome: AgenTTYSSHTerminationOutcome? = nil
    ) {
        let method = analyticsMethod
        let isEdit = !mode.isAdd
        let resolvedUsesTailscaleAddress = usesTailscaleAddress ?? draft.isUsingSuggestedTailscaleAddress
        let analyticsMetadata = HostSetupAnalyticsMetadata(
            flowID: hostSetupFlowID,
            detectedUsername: draft.normalizedUsername.isEmpty ? nil : draft.normalizedUsername,
            detectedUsernameSource: draft.detectedUsernameSource,
            usernameSuspicious: draft.detectedUsernameSuspicious,
            candidates: draft.pairingHostCandidates,
            selectedCandidate: draft.selectedPairingCandidate,
            hostPlatform: draft.automaticHostPlatform,
            hostEnvironmentFlags: draft.automaticHostEnvironmentFlags
        )
        Task {
            await analyticsClient.recordHostSetupFlow(
                AgenTTYAnalyticsHostSetupFlowEvent(
                    method: method,
                    stage: stage,
                    isEdit: isEdit,
                    usesTailscaleAddress: resolvedUsesTailscaleAddress,
                    flowID: analyticsMetadata.flowID,
                    savedHostCount: savedHostCount,
                    hostID: hostID,
                    errorCategory: errorCategory,
                    errorMessage: errorMessage,
                    detectedUsername: analyticsMetadata.detectedUsername,
                    detectedUsernameSource: analyticsMetadata.detectedUsernameSource,
                    usernameSuspicious: analyticsMetadata.usernameSuspicious,
                    hostEdited: draft.automaticHostEdited,
                    portEdited: draft.automaticPortEdited,
                    usernameEdited: draft.automaticUsernameEdited,
                    selectedCandidateKind: analyticsMetadata.selectedCandidateKind,
                    selectedCandidateSource: analyticsMetadata.selectedCandidateSource,
                    selectedCandidateRank: analyticsMetadata.selectedCandidateRank,
                    selectedCandidateValue: analyticsMetadata.selectedCandidateValue,
                    candidateValues: analyticsMetadata.candidateValues,
                    candidateCount: analyticsMetadata.candidateCount,
                    highConfidenceCandidateCount: analyticsMetadata.highConfidenceCandidateCount,
                    allLowConfidenceCandidates: analyticsMetadata.allLowConfidenceCandidates,
                    hostPlatform: analyticsMetadata.hostPlatform,
                    hostEnvironmentFlags: analyticsMetadata.hostEnvironmentFlags ?? [],
                    probeAttemptCount: probeAttemptCount,
                    reachabilityFailureSubtype: reachabilityFailureSubtype?.analyticsValue,
                    verificationAttemptCount: verificationAttemptCount,
                    verificationFailureStage: verificationFailureOutcome?.failureStage?.analyticsValue,
                    verificationDisconnectCategory: verificationFailureOutcome?.category.analyticsValue
                )
            )
        }
    }

    private func beginConnectionValidation(for pendingSave: PendingHostSave) {
        guard shouldValidateConnectionBeforeSave(for: pendingSave.hostDraft) else {
            finishSave(with: pendingSave)
            return
        }

        saveTask?.cancel()
        saveTask = Task {
            do {
                if case .passwordBootstrap = pendingSave.hostDraft.authentication {
                    try await AgenTTYHostReachabilityProbe.verifyReachable(
                        host: pendingSave.hostDraft.address,
                        port: pendingSave.hostDraft.port
                    )
                    try Task.checkCancellation()
                    await MainActor.run {
                        saveTask = nil
                        connectionReachabilityFailureSubtype = nil
                        connectionTroubleshootingOutcome = nil
                        finishSave(with: pendingSave)
                    }
                    return
                }

                let verificationHostID = verificationHostID(for: pendingSave)
                recordHostSetupFlow(
                    stage: .verificationStarted,
                    hostID: mode.existing?.id ?? verificationHostID,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                    verificationAttemptCount: 1
                )
                let verificationResult = try await verifyHostConnection(
                    hostDraft: pendingSave.hostDraft,
                    hostID: verificationHostID,
                    keyStore: keyStore,
                    trustedHostKeyStore: trustedHostKeyStore
                )
                try Task.checkCancellation()
                await MainActor.run {
                    saveTask = nil
                }
                switch verificationResult {
                case .succeeded:
                    recordHostSetupFlow(
                        stage: .verificationSucceeded,
                        hostID: mode.existing?.id ?? verificationHostID,
                        usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                        verificationAttemptCount: 1
                    )
                    await MainActor.run {
                        connectionReachabilityFailureSubtype = nil
                        connectionTroubleshootingOutcome = nil
                        finishSave(with: pendingSave)
                    }
                case .failed(let outcome):
                    recordHostSetupFlow(
                        stage: .verificationFailed,
                        hostID: mode.existing?.id ?? verificationHostID,
                        errorCategory: .connectionVerification,
                        errorMessage: outcome.rawReason,
                        usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                        verificationAttemptCount: 1,
                        verificationFailureOutcome: outcome
                    )
                    await MainActor.run {
                        connectionReachabilityFailureSubtype = nil
                        self.pendingSave = pendingSave
                        connectionTroubleshootingOutcome = outcome
                        connectionValidationWarningMessage = verificationWarningMessage(for: outcome)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    saveTask = nil
                }
            } catch let reachabilityError as AgenTTYHostReachabilityError {
                recordHostSetupFlow(
                    stage: .failed,
                    hostID: mode.existing?.id,
                    errorCategory: .reachability,
                    errorMessage: reachabilityError.localizedDescription,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                    probeAttemptCount: 1,
                    reachabilityFailureSubtype: reachabilityError.failureSubtype
                )
                let analyticsMetadata = HostSetupAnalyticsMetadata(
                    flowID: hostSetupFlowID,
                    detectedUsername: draft.normalizedUsername.isEmpty ? nil : draft.normalizedUsername,
                    detectedUsernameSource: draft.detectedUsernameSource,
                    usernameSuspicious: draft.detectedUsernameSuspicious,
                    candidates: draft.pairingHostCandidates,
                    selectedCandidate: draft.selectedPairingCandidate,
                    hostPlatform: draft.automaticHostPlatform,
                    hostEnvironmentFlags: draft.automaticHostEnvironmentFlags
                )
                reportHostSetupFailureToSentry(
                    context: "host_detail_reachability_failed",
                    method: analyticsMethod,
                    stage: .failed,
                    flowID: hostSetupFlowID,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                    errorCategory: .reachability,
                    errorMessage: reachabilityError.localizedDescription,
                    analyticsMetadata: analyticsMetadata,
                    probeAttemptCount: 1
                )
                await MainActor.run {
                    saveTask = nil
                    self.pendingSave = pendingSave
                    connectionReachabilityFailureSubtype = reachabilityError.failureSubtype
                    connectionTroubleshootingOutcome = nil
                    connectionValidationWarningMessage = reachabilityWarningMessage(for: reachabilityError)
                }
            } catch {
                let outcome = SSHClientSession.connectFailureOutcome(
                    for: error,
                    rawReason: error.localizedDescription
                )
                recordHostSetupFlow(
                    stage: .verificationFailed,
                    hostID: mode.existing?.id,
                    errorCategory: .connectionVerification,
                    errorMessage: error.localizedDescription,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                    verificationAttemptCount: 1,
                    verificationFailureOutcome: outcome
                )
                let analyticsMetadata = HostSetupAnalyticsMetadata(
                    flowID: hostSetupFlowID,
                    detectedUsername: draft.normalizedUsername.isEmpty ? nil : draft.normalizedUsername,
                    detectedUsernameSource: draft.detectedUsernameSource,
                    usernameSuspicious: draft.detectedUsernameSuspicious,
                    candidates: draft.pairingHostCandidates,
                    selectedCandidate: draft.selectedPairingCandidate,
                    hostPlatform: draft.automaticHostPlatform,
                    hostEnvironmentFlags: draft.automaticHostEnvironmentFlags
                )
                reportHostSetupFailureToSentry(
                    context: "host_detail_verification_failed",
                    method: analyticsMethod,
                    stage: .verificationFailed,
                    flowID: hostSetupFlowID,
                    usesTailscaleAddress: pendingSave.hostDraft.address == draft.normalizedSuggestedTailscaleAddress,
                    errorCategory: .connectionVerification,
                    errorMessage: error.localizedDescription,
                    analyticsMetadata: analyticsMetadata,
                    verificationAttemptCount: 1,
                    verificationFailureOutcome: outcome
                )
                await MainActor.run {
                    saveTask = nil
                    self.pendingSave = pendingSave
                    connectionReachabilityFailureSubtype = nil
                    connectionTroubleshootingOutcome = outcome
                    connectionValidationWarningMessage = verificationWarningMessage(for: outcome)
                }
            }
        }
    }

    private func resolvedReplacementDraft(
        _ hostDraft: AgenTTYHostDraft,
        existingHost: AgenTTYHost?
    ) -> AgenTTYHostDraft {
        guard draft.setupMethod == .automaticReview,
              let existingHost,
              let automaticOriginalAddress = draft.automaticOriginalAddress,
              hostDraft.label == automaticOriginalAddress,
              hostDraft.label != existingHost.label,
              let preservedLabelDraft = AgenTTYHostDraft(
                label: existingHost.label,
                address: hostDraft.address,
                usesTailscaleAddress: hostDraft.usesTailscaleAddress,
                port: hostDraft.port,
                username: hostDraft.username,
                authentication: hostDraft.authentication,
                connectionRoutePolicy: hostDraft.connectionRoutePolicy,
                relayHostID: hostDraft.relayHostID
              ) else {
            return hostDraft
        }

        return preservedLabelDraft
    }
}

@safe
private struct DetailReachabilityStatusPill: View {
    let state: HostReachabilityIndicatorState

    var body: some View {
        HStack(spacing: 4) {
            if state == .checking {
                ProgressView()
                    .controlSize(.small)
                    .tint(state.tint)
            } else if let symbolName = state.trailingSymbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(state.statusText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(state.tint.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .stroke(state.tint.opacity(0.3), lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

@safe
private struct DetailConnectionMethodPill: View {
    let method: AgenTTYHostConnectionMethod

    private var tint: Color {
        switch method {
        case .localNetwork:
            .blue
        case .publicInternet:
            .teal
        case .tailscale:
            .cyan
        case .relay:
            .orange
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: method.symbolName)
                .font(.system(size: 12, weight: .semibold))

            Text(method.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

@safe
private struct HostReachabilityTroubleshootingGuidanceSection: View {
    let suggestions: [AgenTTYSSHRecoverySuggestion]?

    var body: some View {
        Section {
            if let suggestions, !suggestions.isEmpty {
                ForEach(suggestions, id: \.self) { suggestion in
                    HostInfoRow(
                        icon: suggestion.icon,
                        title: suggestion.title,
                        subtitle: suggestion.subtitle
                    )
                }
            } else {
                HostInfoRow(
                    icon: "wifi",
                    title: "Reachability matters",
                    subtitle: "Make sure the iPhone can reach the host on the same LAN, by public hostname or IP, or through Tailscale on both devices."
                )
                HostInfoRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Verify SSH is listening",
                    subtitle: "Check that the host name and port are correct and that the SSH service is running on that port."
                )
                HostInfoRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Tailscale note",
                    subtitle: "If you want to use Tailscale, confirm that Tailscale is running and connected on both devices."
                )
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Use these checks to confirm the host details, authentication, and runtime setup before retrying.")
        }
    }
}

@safe
private struct HostReachabilityTroubleshootingView: View {
    let draft: HostFormDraft
    let failureMessage: String?
    let failureOutcome: AgenTTYSSHTerminationOutcome?
    let failureSubtype: AgenTTYHostReachabilityFailureSubtype?

    var body: some View {
        let guidance = reachabilityGuidance
        List {
            Section {
                HostInfoRow(
                    icon: "network",
                    title: "Host",
                    subtitle: draft.normalizedAddress
                )
                HostInfoRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Port",
                    subtitle: draft.portText
                )
            } header: {
                Text("Current Details")
            }

            if let failureMessage {
                Section {
                    HostInfoRow(
                        icon: "exclamationmark.triangle",
                        title: "Most Recent Result",
                        subtitle: failureMessage
                    )
                }
            }

            HostReachabilityTroubleshootingGuidanceSection(suggestions: guidance?.suggestions)
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Troubleshoot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var reachabilityGuidance: AgenTTYSSHRecoveryDescription? {
        if let failureOutcome {
            return AgenTTYSSHRecoveryGuidance.guidance(for: failureOutcome)
        }
        if let failureSubtype, let failureMessage {
            return AgenTTYHostReachabilityGuidance.guidance(
                for: .failed(
                    host: draft.normalizedAddress,
                    port: draft.parsedPort ?? AgenTTYConnection.defaultPort,
                    reason: failureMessage,
                    subtype: failureSubtype
                )
            )
        }
        return nil
    }
}

@safe
struct AutomaticHostSetupTroubleshootingView: View {
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore

    let analyticsClient: AgenTTYAnalyticsClient
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let onContinueToReview: (HostFormDraft) -> Void

    @State private var draft: HostFormDraft
    @State private var isTesting = false
    @State private var errorMessage: String?
    @State private var status: VerificationStatus
    @FocusState private var focusedField: FormField?

    private enum FormField: Hashable {
        case address
        case port
        case username
    }

    private enum VerificationStatus {
        case failed(AgenTTYSSHTerminationOutcome?)
        case succeeded

        var isVerified: Bool {
            if case .succeeded = self {
                return true
            }
            return false
        }
    }

    init(
        draft: HostFormDraft,
        analyticsClient: AgenTTYAnalyticsClient,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        onContinueToReview: @escaping (HostFormDraft) -> Void
    ) {
        self.analyticsClient = analyticsClient
        self.trustedHostKeyStore = trustedHostKeyStore
        self.onContinueToReview = onContinueToReview
        _draft = State(initialValue: draft)
        _status = State(initialValue: .failed(draft.automaticVerificationFailureOutcome))
    }

    private var canRetry: Bool {
        !isTesting && draft.isAddressValid && draft.isPortValid && draft.isUsernameValid
    }

    private var canUseNextSuggestion: Bool {
        draft.pairingHostCandidates.count > 1 && !isTesting
    }

    private var hostAddressNormalizationNote: String? {
        guard !draft.address.isEmpty else { return nil }
        let normalizedAddress = draft.normalizedAddress
        guard !normalizedAddress.isEmpty, normalizedAddress != draft.address else { return nil }
        return "AgenTTY will test and save this host as \(normalizedAddress)."
    }

    private var guidance: AgenTTYSSHRecoveryDescription? {
        if case .failed(let outcome?) = status {
            return AgenTTYSSHRecoveryGuidance.guidance(for: outcome)
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                statusRow(
                    icon: "key.fill",
                    tint: .green,
                    title: "SSH Key Authorized",
                    subtitle: "AgenTTY successfully installed or confirmed its SSH key on the host."
                )
                switch status {
                case .failed:
                    statusRow(
                        icon: "exclamationmark.triangle",
                        tint: .yellow,
                        title: guidance?.title ?? "Verification Failed",
                        subtitle: guidance?.message ?? "AgenTTY could not verify that this host is ready for a usable terminal session."
                    )
                case .succeeded:
                    statusRow(
                        icon: "checkmark.circle",
                        tint: .green,
                        title: "Host Verified",
                        subtitle: "AgenTTY reached a usable terminal session with the current host details."
                    )
                }
            } header: {
                Text("Setup Status")
            } footer: {
                Text("Authentication setup finished on the host, but AgenTTY still needs a full verified terminal path from this iPhone before the host can be used normally.")
            }

            Section {
                SheetFormFieldRow(
                    icon: "network",
                    label: "Host",
                    placeholder: "IP or hostname",
                    text: $draft.address,
                    field: .address,
                    focusedField: $focusedField,
                    isValid: draft.isAddressValid,
                    keyboardType: .URL,
                    submitLabel: .next,
                    onSubmit: { focusedField = .port }
                )

                if let hostAddressNormalizationNote {
                    statusRow(
                        icon: "textformat",
                        tint: .yellow,
                        title: "Host Normalized",
                        subtitle: hostAddressNormalizationNote
                    )
                }

                SheetFormFieldRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    label: "Port",
                    placeholder: "22",
                    text: $draft.portText,
                    field: .port,
                    focusedField: $focusedField,
                    isValid: draft.isPortValid,
                    keyboardType: .numberPad,
                    submitLabel: .next,
                    onSubmit: { focusedField = .username }
                )

                SheetFormFieldRow(
                    icon: "person",
                    label: "User",
                    placeholder: "SSH username",
                    text: $draft.username,
                    field: .username,
                    focusedField: $focusedField,
                    isValid: draft.isUsernameValid,
                    submitLabel: .go,
                    onSubmit: { retryCurrentValues() }
                )
            } header: {
                Text("Connection Details")
            } footer: {
                Text("These are the values AgenTTY detected from pairing. Update them here if they look wrong, then test again.")
            }

            HostReachabilityTroubleshootingGuidanceSection(suggestions: guidance?.suggestions)

            if let errorMessage {
                Section {
                    HostInfoRow(
                        icon: "exclamationmark.triangle",
                        title: "Most Recent Error",
                        subtitle: errorMessage
                    )
                }
            }
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .disabled(isTesting)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Check Connection")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        retryCurrentValues()
                    } label: {
                        HStack(spacing: 8) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Try Again")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canRetry)

                    if canUseNextSuggestion {
                        Button {
                            useNextSuggestion()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right.circle")
                                Text("Use Next Suggestion")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glass)
                    }
                }

                if status.isVerified {
                    Button {
                        continueToReview(verified: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                            Text("Continue to Review")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.green.opacity(0.15))
                } else {
                    Button {
                        continueToReview(verified: false)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Continue Anyway")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .tint(Color.red.opacity(0.15))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func statusRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private func retryCurrentValues() {
        guard canRetry else { return }
        guard let selectedKeyID = draft.selectedKeyID else {
            errorMessage = "The selected SSH key is unavailable."
            return
        }
        guard let hostDraft = draft.makeHostDraft(authentication: .key(selectedKeyID)) else {
            return
        }

        errorMessage = nil
        isTesting = true
        Task {
            defer {
                Task { @MainActor in
                    isTesting = false
                }
            }

            do {
                let result = try await verifyHostConnection(
                    hostDraft: hostDraft,
                    hostID: UUID(),
                    keyStore: keyStore,
                    trustedHostKeyStore: trustedHostKeyStore,
                    pinnedSSHHostPublicKeys: draft.pinnedSSHHostPublicKeys
                )
                await MainActor.run {
                    switch result {
                    case .succeeded:
                        status = .succeeded
                        draft.automaticVerificationFailureOutcome = nil
                        errorMessage = nil
                    case .failed(let outcome):
                        status = .failed(outcome)
                        draft.automaticVerificationFailureOutcome = outcome
                        errorMessage = AgenTTYSSHRecoveryGuidance.guidance(for: outcome).message
                    }
                }
            } catch {
                await MainActor.run {
                    status = .failed(nil)
                    draft.automaticVerificationFailureOutcome = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func useNextSuggestion() {
        guard !draft.pairingHostCandidates.isEmpty else { return }
        let currentIndex = draft.pairingHostCandidates.firstIndex {
            AgenTTYHostStore.normalizedAddress($0.value) == AgenTTYHostStore.normalizedAddress(draft.normalizedAddress)
        } ?? -1
        let nextIndex = (currentIndex + 1) % draft.pairingHostCandidates.count
        let nextCandidate = draft.pairingHostCandidates[nextIndex]
        draft.setAutomaticConnectionValues(
            address: nextCandidate.value,
            port: draft.parsedPort ?? AgenTTYConnection.defaultPort,
            username: draft.normalizedUsername,
            preserveOriginalValues: true
        )
        draft.suggestedTailscaleAddress = nextCandidate.usesTailscale ? nextCandidate.value : nil
        retryCurrentValues()
    }

    private func continueToReview(verified: Bool) {
        let shouldSyncLabel = draft.label.isEmpty
            || draft.label == draft.automaticOriginalAddress
            || draft.pairingCandidateAddresses.contains(
                AgenTTYHostStore.normalizedAddress(draft.label)
            )
        if shouldSyncLabel {
            draft.label = draft.normalizedAddress
        }
        draft.continuedWithoutVerifiedConnection = !verified
        onContinueToReview(draft)
    }
}

@safe
struct AutomaticHostSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore

    let analyticsClient: AgenTTYAnalyticsClient
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let onPairingCompleted: (HostsRoute) -> Void
    @State private var manualCode = ""
    @State private var showScanner = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var pairingTask: Task<Void, Never>?
    @State private var pairingTaskToken = 0
    @State private var pendingSetupState: AgenTTYAutomaticSetupPendingState?
    @State private var setupMode: AgenTTYAutomaticSetupMode = .recommended
    @State private var didRecordStartedAnalytics = false
    @State private var hostSetupFlowID = UUID().uuidString.lowercased()
    @FocusState private var focusedField: FormField?

    private enum FormField: Hashable {
        case code
    }

    private var hasPendingSetup: Bool {
        pendingSetupState != nil
    }

    private var canSubmitCode: Bool {
        AgenTTYPairingRelayClient.pairingCode(from: manualCode) != nil
            && pairingTask == nil
            && !hasPendingSetup
    }

    private var automaticSetupErrorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private var shouldHideSystemBackButton: Bool {
        pairingTask != nil || hasPendingSetup
    }

    var body: some View {
        List {
            Section {
                ForEach(AgenTTYAutomaticSetupMode.allCases, id: \.self) { mode in
                    automaticSetupModeRow(mode)
                }
            } header: {
                Text("Setup Mode")
            } footer: {
                Text("Both modes add one AgenTTY SSH public key for this user, use ~/.agentty for managed tmux/runtime files, and avoid editing normal shell startup files outside AgenTTY's managed directory.")
            }

            Section {
                HostCommandRow(
                    icon: "terminal",
                    title: "Run this on the host first",
                    command: setupMode.command
                )
                setupInfoRow(
                    icon: "network",
                    title: setupModeDetailTitle,
                    subtitle: setupModeDetailSubtitle
                )
            } header: {
                Text("Automatic Setup")
            } footer: {
                Text("Run the host command, then scan its QR code here. If scanning is inconvenient, you can type the short code manually.")
            }

            Section {
                Button {
                    openScanner()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Scan Host QR")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.primaryText)

                            Text("Scan the QR code that the host command prints in the terminal.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Spacer(minLength: 4)

                        if pairingTask != nil {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "camera")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .disabled(pairingTask != nil || hasPendingSetup)
                .listRowBackground(AppTheme.sheetListRowBackground)

                SheetFormFieldRow(
                    icon: "number",
                    label: "Code",
                    placeholder: "ABCD-EFGH",
                    text: $manualCode,
                    field: .code,
                    focusedField: $focusedField,
                    isValid: canSubmitCode,
                    autocapitalization: .characters,
                    submitLabel: .go,
                    onSubmit: submitManualCode,
                    showsValidationIndicator: false,
                    trailingAccessory: AnyView(
                        Button("Pair") {
                            submitManualCode()
                        }
                        .disabled(!canSubmitCode)
                    )
                )
            } header: {
                Text("Claim Host")
            }

            if let statusMessage {
                Section {
                    setupInfoRow(
                        icon: "hourglass",
                        title: "Status",
                        subtitle: statusMessage
                    )
                }
            }
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("Automatic Setup")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(shouldHideSystemBackButton)
        .onAppear {
            restorePendingStateIfNeeded()
            if !didRecordStartedAnalytics {
                didRecordStartedAnalytics = true
                recordHostSetupFlow(stage: .screenViewed)
            }
            resumePendingStateIfNeeded(reason: "view_appeared")
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            restorePendingStateIfNeeded()
            resumePendingStateIfNeeded(reason: "scene_active")
        }
        .onDisappear {
            cancelPairingTask()
        }
        .alert(
            "Automatic Setup Error",
            isPresented: automaticSetupErrorIsPresented
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
        .toolbar {
            if shouldHideSystemBackButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        abandonAutomaticSetup()
                    }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingQRCodeScannerView(
                    onPayload: { payload in
                        showScanner = false
                        beginPairing(using: payload)
                    },
                    onError: { error in
                        showScanner = false
                        errorMessage = error.localizedDescription
                    }
                )
                .ignoresSafeArea()
                .navigationTitle("Scan Host QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showScanner = false
                        }
                    }
                }
            }
            .presentationDetents([.large])
            .esmaTermSheetBackground()
        }
    }

    private func openScanner() {
        guard DataScannerViewController.isSupported else {
            errorMessage = PairingQRCodeScannerError.unsupported.localizedDescription
            return
        }
        guard DataScannerViewController.isAvailable else {
            errorMessage = PairingQRCodeScannerError.unavailable.localizedDescription
            return
        }
        recordHostSetupFlow(stage: .scannerOpened)
        showScanner = true
    }

    private func submitManualCode() {
        beginPairing(using: manualCode)
    }

    private func abandonAutomaticSetup() {
        clearPendingState()
        cancelPairingTask()
        errorMessage = nil
        statusMessage = nil
        dismiss()
    }

    private func cancelPairingTask() {
        pairingTaskToken &+= 1
        pairingTask?.cancel()
        pairingTask = nil
    }

    private func restorePendingStateIfNeeded() {
        guard let restored = AgenTTYAutomaticSetupPendingStateStore.load() else {
            pendingSetupState = nil
            if pairingTask == nil {
                statusMessage = nil
            }
            return
        }

        guard pendingSetupState != restored else { return }
        pendingSetupState = restored
        hostSetupFlowID = restored.flowID
        if pairingTask == nil {
            statusMessage = switch restored {
            case .claiming:
                "Claiming pairing session..."
            case .claimed:
                "Waiting for the host to finish setup..."
            }
        }
    }

    private func persistPendingClaim(
        pairingCode: String,
        keyID: UUID
    ) {
        AgenTTYAutomaticSetupPendingStateStore.saveClaiming(
            pairingCode: pairingCode,
            keyID: keyID,
            flowID: hostSetupFlowID
        )
        pendingSetupState = AgenTTYAutomaticSetupPendingStateStore.load()
    }

    private func persistClaimedSession(
        sessionID: String,
        keyID: UUID,
        expiresAtEpochSeconds: Int
    ) {
        let claimedAtEpochSeconds = Int(Date().timeIntervalSince1970.rounded())
        AgenTTYAutomaticSetupPendingStateStore.saveClaimed(
            sessionID: sessionID,
            keyID: keyID,
            flowID: hostSetupFlowID,
            claimedAtEpochSeconds: claimedAtEpochSeconds,
            expiresAtEpochSeconds: expiresAtEpochSeconds
        )
        pendingSetupState = AgenTTYAutomaticSetupPendingStateStore.load()
    }

    private func clearPendingState() {
        pendingSetupState = nil
        AgenTTYAutomaticSetupPendingStateStore.clear()
    }

    private func resumePendingStateIfNeeded(reason: String) {
        guard pairingTask == nil, let pendingSetupState else { return }
        errorMessage = nil
        switch pendingSetupState {
        case .claiming(let claim):
            statusMessage = "Claiming pairing session..."
            launchPairingTask(
                failureContext: [
                    "resume_reason": reason,
                    "pending_state": "claiming",
                    "code_tail": String(claim.pairingCode.suffix(4)),
                ]
            ) {
                try await claimAndAwaitCompletion(
                    pairingCode: claim.pairingCode,
                    keyID: claim.keyID
                )
            }
        case .claimed(let session):
            statusMessage = "Waiting for the host to finish setup..."
            launchPairingTask(
                failureContext: [
                    "resume_reason": reason,
                    "pending_state": "claimed",
                    "session_id": session.sessionID,
                ]
            ) {
                try await waitForCompletion(
                    sessionID: session.sessionID,
                    keyID: session.keyID
                )
            }
        }
    }

    private func launchPairingTask(
        failureContext: [String: String],
        operation: @escaping () async throws -> Void
    ) {
        cancelPairingTask()
        let taskToken = pairingTaskToken
        pairingTask = Task {
            defer {
                Task { @MainActor in
                    guard pairingTaskToken == taskToken else { return }
                    pairingTask = nil
                }
            }

            do {
                try await operation()
            } catch {
                if isNonTerminalPairingInterruption(error) {
                    await MainActor.run {
                        switch pendingSetupState {
                        case .claiming:
                            statusMessage = "Claiming pairing session..."
                        case .claimed:
                            statusMessage = "Waiting for the host to finish setup..."
                        case nil:
                            statusMessage = nil
                        }
                    }
                    return
                }

                recordHostSetupFlow(
                    stage: .failed,
                    errorCategory: .pairing,
                    errorMessage: error.localizedDescription
                )
                EsmaLog.notifications.error(
                    "event=pairing_flow_failure error=\(String(describing: error), privacy: .public)"
                )
                AgenTTYSentryService.capture(
                    error: error,
                    context: "automatic_host_setup",
                    data: failureContext
                )
                await MainActor.run {
                    clearPendingState()
                    statusMessage = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func isNonTerminalPairingInterruption(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func beginPairing(using rawCode: String) {
        guard let pairingCode = AgenTTYPairingRelayClient.pairingCode(from: rawCode) else {
            errorMessage = PairingQRCodeScannerError.unreadableCode.localizedDescription
            return
        }
        guard let keyID = keyStore.defaultGeneratedKeyID(named: defaultAutomaticKeyName) else {
            errorMessage = "Unable to create or load the default AgenTTY SSH key."
            return
        }

        cancelPairingTask()
        clearPendingState()
        persistPendingClaim(pairingCode: pairingCode, keyID: keyID)
        errorMessage = nil
        statusMessage = "Claiming pairing session..."
        recordHostSetupFlow(stage: .attemptStarted)
        recordHostSetupFlow(stage: .pairingClaimStarted)
        EsmaLog.notifications.notice(
            "event=pairing_flow_start code_tail=\(String(pairingCode.suffix(4)), privacy: .public) key_id=\(keyID.uuidString, privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Automatic host setup started",
            category: "pairing",
            level: "info",
            data: [
                "code_tail": String(pairingCode.suffix(4)),
                "key_id": keyID.uuidString,
            ]
        )
        launchPairingTask(
            failureContext: ["code_tail": String(pairingCode.suffix(4))]
        ) {
            try await claimAndAwaitCompletion(
                pairingCode: pairingCode,
                keyID: keyID
            )
        }
    }

    private func claimAndAwaitCompletion(
        pairingCode: String,
        keyID: UUID
    ) async throws {
        guard let publicKey = keyStore.publicKey(for: keyID) else {
            throw AgenTTYPairingQRCodeSetupError.missingSSHKey
        }

        let claim = try await AgenTTYPairingRelayClient.shared.claimPairingSession(
            code: pairingCode,
            publicKey: publicKey
        )
        recordHostSetupFlow(stage: .pairingClaimed)
        EsmaLog.notifications.notice(
            "event=pairing_flow_claimed session_id=\(claim.sessionID, privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Automatic host setup claimed session",
            category: "pairing",
            level: "info",
            data: ["session_id": claim.sessionID]
        )
        await MainActor.run {
            manualCode = ""
            persistClaimedSession(
                sessionID: claim.sessionID,
                keyID: keyID,
                expiresAtEpochSeconds: claim.expiresAtEpochSeconds
            )
            statusMessage = "Waiting for the host to authorize the AgenTTY key..."
        }
        try await waitForCompletion(sessionID: claim.sessionID, keyID: keyID)
    }

    private func waitForCompletion(sessionID: String, keyID: UUID) async throws {
        while !Task.isCancelled {
            let status = try await AgenTTYPairingRelayClient.shared.fetchPairingSessionStatus(sessionID: sessionID)

            switch status.status {
            case .pending, .claimed:
                try await Task.sleep(for: .seconds(1))
            case .completed:
                guard let completion = status.completion else {
                    throw AgenTTYPairingRelayError.invalidResponse
                }
                recordHostSetupFlow(
                    stage: .pairingCompleted,
                    usesTailscaleAddress: completion.shouldUseTailscale,
                    completion: completion
                )
                EsmaLog.notifications.notice(
                    "event=pairing_completion_received session_id=\(sessionID, privacy: .public) username_present=\(completion.detectedUsername != nil) hostname_candidates=\(completion.hostnameCandidates.count)"
                )
                AgenTTYSentryService.addBreadcrumb(
                    message: "Pairing completion received",
                    category: "pairing",
                    level: "info",
                    data: [
                        "session_id": sessionID,
                        "username_present": completion.detectedUsername != nil ? "true" : "false",
                        "hostname_candidates": String(completion.hostnameCandidates.count),
                    ]
                )
                do {
                    await MainActor.run {
                        statusMessage = "Verifying that this iPhone can open a usable terminal session..."
                    }
                    let nextRoute = try await nextRouteAfterPairingCompletion(
                        from: completion,
                        keyID: keyID
                    )
                    await MainActor.run {
                        clearPendingState()
                        statusMessage = nil
                        presentNextStep(route: nextRoute)
                    }
                } catch {
                    EsmaLog.notifications.error(
                        "event=pairing_review_prep_failure session_id=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    AgenTTYSentryService.capture(
                        error: error,
                        context: "automatic_host_setup_review",
                        data: ["session_id": sessionID]
                    )
                    throw error
                }
                return
            case .failed:
                EsmaLog.notifications.error(
                    "event=pairing_completion_failed session_id=\(sessionID, privacy: .public) host_error=\(status.completion?.errorMessage ?? "none", privacy: .public)"
                )
                AgenTTYSentryService.addBreadcrumb(
                    message: "Pairing completion failed",
                    category: "pairing",
                    level: "error",
                    data: [
                        "session_id": sessionID,
                        "host_error": status.completion?.errorMessage ?? "none",
                    ]
                )
                throw AgenTTYPairingQRCodeSetupError.pairingFailed(
                    status.completion?.errorMessage ?? "The host failed to authorize the AgenTTY key."
                )
            case .expired:
                EsmaLog.notifications.error(
                    "event=pairing_completion_expired session_id=\(sessionID, privacy: .public)"
                )
                AgenTTYSentryService.addBreadcrumb(
                    message: "Pairing completion expired",
                    category: "pairing",
                    level: "error",
                    data: ["session_id": sessionID]
                )
                throw AgenTTYPairingQRCodeSetupError.pairingExpired
            }
        }
    }

    private func nextRouteAfterPairingCompletion(
        from completion: AgenTTYPairingSessionCompletionMetadata,
        keyID: UUID
    ) async throws -> HostsRoute {
        let candidates = AgenTTYPairingHostCandidateRanking.resolvedCandidates(from: completion)
        guard let firstCandidate = candidates.first else {
            throw AgenTTYPairingQRCodeSetupError.missingHostAddress
        }

        let username = completion.detectedUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !username.isEmpty else {
            throw AgenTTYPairingQRCodeSetupError.missingDetectedUsername
        }

        if candidates.allSatisfy({ AgenTTYPairingHostCandidateRanking.isLowConfidence(kind: $0.kind) }) {
            let reviewDraft = try makeAutomaticDraft(
                from: completion,
                keyID: keyID,
                username: username,
                selectedCandidate: firstCandidate,
                allCandidates: candidates
            )
            return .addAutomaticReview(reviewDraft)
        }

        recordHostSetupFlow(
            stage: .verificationStarted,
            usesTailscaleAddress: false,
            completion: completion,
            verificationAttemptCount: candidates.count
        )

        var lastVerificationOutcome: AgenTTYSSHTerminationOutcome?
        for (index, candidate) in candidates.enumerated() {
            let candidateDraft = try makeAutomaticDraft(
                from: completion,
                keyID: keyID,
                username: username,
                selectedCandidate: candidate,
                allCandidates: candidates
            )
            guard let hostDraft = candidateDraft.makeHostDraft(authentication: .key(keyID)) else {
                continue
            }
            let verificationResult = try await verifyHostConnection(
                hostDraft: hostDraft,
                hostID: UUID(),
                keyStore: keyStore,
                trustedHostKeyStore: trustedHostKeyStore,
                pinnedSSHHostPublicKeys: completion.sshHostPublicKeys
            )
            switch verificationResult {
            case .succeeded:
                recordHostSetupFlow(
                    stage: .verificationSucceeded,
                    usesTailscaleAddress: candidateDraft.isUsingSuggestedTailscaleAddress,
                    completion: completion,
                    verificationAttemptCount: index + 1
                )
                return .addAutomaticReview(candidateDraft)
            case .failed(let outcome):
                lastVerificationOutcome = outcome
            }
        }

        let fallbackDraft = try makeAutomaticDraft(
            from: completion,
            keyID: keyID,
            username: username,
            selectedCandidate: firstCandidate,
            allCandidates: candidates
        )

        let verificationFailureOutcome = lastVerificationOutcome ?? AgenTTYSSHTerminationOutcome(
            category: .other,
            failureStage: .tcpConnect,
            rawReason: "Automatic setup could not verify a usable connection.",
            wasReady: false,
            shouldReconnect: false
        )
        var troubleshootingDraft = fallbackDraft
        troubleshootingDraft.automaticVerificationFailureOutcome = verificationFailureOutcome
        recordHostSetupFlow(
            stage: .verificationFailed,
            errorCategory: .connectionVerification,
            errorMessage: verificationFailureOutcome.rawReason,
            usesTailscaleAddress: troubleshootingDraft.isUsingSuggestedTailscaleAddress,
            completion: completion,
            verificationAttemptCount: candidates.count,
            verificationFailureOutcome: verificationFailureOutcome
        )
        let analyticsMetadata = HostSetupAnalyticsMetadata(
            flowID: hostSetupFlowID,
            detectedUsername: completion.detectedUsername,
            detectedUsernameSource: completion.detectedUsernameSource,
            usernameSuspicious: completion.detectedUsernameSuspicious,
            candidates: candidates,
            selectedCandidate: firstCandidate,
            hostPlatform: completion.platform?.analyticsValue,
            hostEnvironmentFlags: completion.hostEnvironmentFlags.compactMap(\.analyticsValue)
        )
        reportHostSetupFailureToSentry(
            context: "automatic_host_setup_verification_failed",
            method: .automatic,
            stage: .verificationFailed,
            flowID: hostSetupFlowID,
            usesTailscaleAddress: troubleshootingDraft.isUsingSuggestedTailscaleAddress,
            errorCategory: .connectionVerification,
            errorMessage: verificationFailureOutcome.rawReason,
            analyticsMetadata: analyticsMetadata,
            verificationAttemptCount: candidates.count,
            verificationFailureOutcome: verificationFailureOutcome
        )
        return .addAutomaticTroubleshooting(troubleshootingDraft)
    }

    private func makeAutomaticDraft(
        from completion: AgenTTYPairingSessionCompletionMetadata,
        keyID: UUID,
        username: String,
        selectedCandidate: AgenTTYResolvedPairingHostCandidate,
        allCandidates: [AgenTTYResolvedPairingHostCandidate]
    ) throws -> HostFormDraft {
        guard let hostDraft = AgenTTYHostDraft(
            label: selectedCandidate.value,
            address: selectedCandidate.value,
            port: completion.port ?? AgenTTYConnection.defaultPort,
            username: username,
            authentication: .key(keyID)
        ) else {
            throw AgenTTYPairingQRCodeSetupError.invalidHostMetadata
        }

        var draft = HostFormDraft(defaultKeyID: keyID, setupMethod: .automaticReview)
        draft.label = hostDraft.label
        draft.address = hostDraft.address
        draft.portText = String(hostDraft.port)
        draft.username = hostDraft.username
        draft.suggestedTailscaleAddress = selectedCandidate.usesTailscale ? hostDraft.address : nil
        draft.passwordCredentialID = nil
        draft.pairingHostCandidates = allCandidates
        draft.automaticFlowID = hostSetupFlowID
        draft.detectedUsernameSource = completion.detectedUsernameSource
        draft.detectedUsernameSuspicious = completion.detectedUsernameSuspicious
        draft.automaticHostPlatform = completion.platform?.analyticsValue
        draft.automaticHostEnvironmentFlags = completion.hostEnvironmentFlags.compactMap(\.analyticsValue)
        draft.automaticOriginalAddress = hostDraft.address
        draft.automaticOriginalPort = hostDraft.port
        draft.automaticOriginalUsername = hostDraft.username
        draft.pinnedSSHHostPublicKeys = completion.sshHostPublicKeys
        draft.connectionRoutePolicy = completion.relayCapable == true ? .directThenRelay : .directOnly
        draft.relayHostID = completion.relayCapable == true ? completion.relayHostID : nil
        return draft
    }

    private func recordHostSetupFlow(
        stage: AgenTTYAnalyticsHostSetupStage,
        errorCategory: AgenTTYAnalyticsHostSetupErrorCategory? = nil,
        errorMessage: String? = nil,
        usesTailscaleAddress: Bool = false,
        completion: AgenTTYPairingSessionCompletionMetadata? = nil,
        probeAttemptCount: Int? = nil,
        reachabilityFailureSubtype: AgenTTYHostReachabilityFailureSubtype? = nil,
        verificationAttemptCount: Int? = nil,
        verificationFailureOutcome: AgenTTYSSHTerminationOutcome? = nil
    ) {
        let resolvedCompletion = completion
        let resolvedCandidates = resolvedCompletion.map { completion in
            AgenTTYPairingHostCandidateRanking.resolvedCandidates(from: completion)
        } ?? []
        let analyticsMetadata = HostSetupAnalyticsMetadata(
            flowID: hostSetupFlowID,
            detectedUsername: resolvedCompletion?.detectedUsername,
            detectedUsernameSource: resolvedCompletion?.detectedUsernameSource,
            usernameSuspicious: resolvedCompletion?.detectedUsernameSuspicious,
            candidates: resolvedCandidates,
            hostPlatform: resolvedCompletion?.platform?.analyticsValue,
            hostEnvironmentFlags: resolvedCompletion?.hostEnvironmentFlags.compactMap(\.analyticsValue) ?? []
        )
        Task {
            await analyticsClient.recordHostSetupFlow(
                AgenTTYAnalyticsHostSetupFlowEvent(
                    method: .automatic,
                    stage: stage,
                    isEdit: false,
                    usesTailscaleAddress: usesTailscaleAddress,
                    flowID: analyticsMetadata.flowID,
                    savedHostCount: nil,
                    hostID: nil,
                    errorCategory: errorCategory,
                    errorMessage: errorMessage,
                    detectedUsername: analyticsMetadata.detectedUsername,
                    detectedUsernameSource: analyticsMetadata.detectedUsernameSource,
                    usernameSuspicious: analyticsMetadata.usernameSuspicious,
                    hostEdited: nil,
                    portEdited: nil,
                    usernameEdited: nil,
                    selectedCandidateKind: analyticsMetadata.selectedCandidateKind,
                    selectedCandidateSource: analyticsMetadata.selectedCandidateSource,
                    selectedCandidateRank: analyticsMetadata.selectedCandidateRank,
                    selectedCandidateValue: analyticsMetadata.selectedCandidateValue,
                    candidateValues: analyticsMetadata.candidateValues,
                    candidateCount: analyticsMetadata.candidateCount,
                    highConfidenceCandidateCount: analyticsMetadata.highConfidenceCandidateCount,
                    allLowConfidenceCandidates: analyticsMetadata.allLowConfidenceCandidates,
                    hostPlatform: analyticsMetadata.hostPlatform,
                    hostEnvironmentFlags: analyticsMetadata.hostEnvironmentFlags ?? [],
                    probeAttemptCount: probeAttemptCount,
                    reachabilityFailureSubtype: reachabilityFailureSubtype?.analyticsValue,
                    verificationAttemptCount: verificationAttemptCount,
                    verificationFailureStage: verificationFailureOutcome?.failureStage?.analyticsValue,
                    verificationDisconnectCategory: verificationFailureOutcome?.category.analyticsValue
                )
            )
        }
    }

    @MainActor
    private func presentNextStep(route: HostsRoute) {
        EsmaLog.notifications.notice(
            "event=pairing_review_ready route=\(String(describing: route), privacy: .public)"
        )
        AgenTTYSentryService.addBreadcrumb(
            message: "Pairing next step ready",
            category: "pairing",
            level: "info",
            data: [:]
        )
        recordHostSetupFlow(stage: .reviewPresented)
        onPairingCompleted(route)
    }

    private var defaultAutomaticKeyName: String {
        "AgenTTY on \(UIDevice.current.name)"
    }

    private var setupModeDetailTitle: String {
        switch setupMode {
        case .recommended:
            return "Recommended setup keeps SSH reliable"
        case .directOnly:
            return "Direct setup uses only reachable SSH"
        }
    }

    private var setupModeDetailSubtitle: String {
        switch setupMode {
        case .recommended:
            return "Full AgenTTY Setup adds a fallback relay connector when your iPhone cannot reach SSH directly. SSH remains normal SSH; the relay does not receive your private key or terminate the SSH session."
        case .directOnly:
            return "AgenTTY still handles the SSH key and managed runtime, but this host will only connect when your iPhone can reach SSH directly."
        }
    }

    private func automaticSetupModeRow(_ mode: AgenTTYAutomaticSetupMode) -> some View {
        Button {
            setupMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: setupMode == mode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(setupMode == mode ? .orange : AppTheme.secondaryText)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(mode.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.primaryText)

                        if let badge = mode.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(mode.summary)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(pairingTask != nil || hasPendingSetup)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private func setupInfoRow(icon: String, title: String, subtitle: String) -> some View {
        HostInfoRow(icon: icon, title: title, subtitle: subtitle, selectableSubtitle: true)
    }
}

@MainActor
private func verifyHostConnection(
    hostDraft: AgenTTYHostDraft,
    hostID: UUID,
    keyStore: AgenTTYSSHKeyStore,
    trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
    pinnedSSHHostPublicKeys: [String] = []
) async throws -> AgenTTYHostConnectionVerificationResult {
    guard case .key(let keyID) = hostDraft.authentication else {
        preconditionFailure("Host verification only supports key-based host drafts.")
    }

    let host = AgenTTYHost(
        id: hostID,
        label: hostDraft.label,
        address: hostDraft.address,
        usesTailscaleAddress: hostDraft.usesTailscaleAddress,
        port: hostDraft.port,
        username: hostDraft.username,
        authentication: hostDraft.authentication,
        connectionRoutePolicy: hostDraft.connectionRoutePolicy,
        relayHostID: hostDraft.relayHostID
    )
    var resolvedRoute: AgenTTYResolvedConnectionRoute?
    defer {
        resolvedRoute?.bridge?.close()
    }
    let route = try await AgenTTYConnectionRouteResolver.resolve(for: host)
    resolvedRoute = route
    let userAuthentication = try keyStore.userAuthentication(for: keyID, username: hostDraft.username)
    return try await AgenTTYHostConnectionVerifier.verify(
        connectionTarget: route.connectionTarget,
        userAuthentication: userAuthentication,
        trustedHostKeyStore: trustedHostKeyStore,
        acceptedOpenSSHPublicKeys: pinnedSSHHostPublicKeys,
        preShellProvisioner: { ssh in
            try await AgenTTYHostRuntimeProvisioner.prepareBaseRuntime(ssh: ssh)
        }
    )
}

private extension String {
    var normalizedHostnameCandidate: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct HostSetupAnalyticsMetadata {
    let flowID: String
    let detectedUsername: String?
    let detectedUsernameSource: AgenTTYPairingDetectedUsernameSource?
    let usernameSuspicious: Bool?
    let selectedCandidateKind: AgenTTYAnalyticsHostCandidateKind?
    let selectedCandidateSource: AgenTTYAnalyticsHostCandidateSource?
    let selectedCandidateRank: Int?
    let selectedCandidateValue: String?
    let candidateValues: [String]?
    let candidateCount: Int?
    let highConfidenceCandidateCount: Int?
    let allLowConfidenceCandidates: Bool?
    let hostPlatform: AgenTTYAnalyticsHostPlatform?
    let hostEnvironmentFlags: [AgenTTYAnalyticsHostEnvironmentFlag]?

    init(
        flowID: String,
        detectedUsername: String?,
        detectedUsernameSource: AgenTTYPairingDetectedUsernameSource?,
        usernameSuspicious: Bool?,
        candidates: [AgenTTYResolvedPairingHostCandidate],
        selectedCandidate: AgenTTYResolvedPairingHostCandidate? = nil,
        hostPlatform: AgenTTYAnalyticsHostPlatform?,
        hostEnvironmentFlags: [AgenTTYAnalyticsHostEnvironmentFlag]
    ) {
        let resolvedSelectedCandidate = selectedCandidate ?? candidates.first
        let candidateCount = candidates.isEmpty ? nil : candidates.count
        let highConfidenceCandidateCount = candidates.isEmpty
            ? nil
            : candidates.filter { !AgenTTYPairingHostCandidateRanking.isLowConfidence(kind: $0.kind) }
                .count
        let selectedCandidateRank = resolvedSelectedCandidate.flatMap { candidate in
            candidates.firstIndex(where: {
                $0.value.caseInsensitiveCompare(candidate.value) == .orderedSame
            }).map { $0 + 1 }
        }

        self.flowID = flowID
        self.detectedUsername = detectedUsername
        self.detectedUsernameSource = detectedUsernameSource
        self.usernameSuspicious = usernameSuspicious
        self.selectedCandidateKind = resolvedSelectedCandidate?.kind.analyticsValue
        self.selectedCandidateSource = resolvedSelectedCandidate?.source?.analyticsValue
        self.selectedCandidateRank = selectedCandidateRank
        self.selectedCandidateValue = resolvedSelectedCandidate?.value
        self.candidateValues = candidates.isEmpty ? nil : candidates.map(\.value)
        self.candidateCount = candidateCount
        self.highConfidenceCandidateCount = highConfidenceCandidateCount
        self.allLowConfidenceCandidates = highConfidenceCandidateCount.map { $0 == 0 }
        self.hostPlatform = hostPlatform
        self.hostEnvironmentFlags = hostEnvironmentFlags.isEmpty ? nil : hostEnvironmentFlags
    }
}

private func reportHostSetupFailureToSentry(
    context: String,
    method: AgenTTYAnalyticsHostSetupMethod,
    stage: AgenTTYAnalyticsHostSetupStage,
    flowID: String,
    usesTailscaleAddress: Bool,
    errorCategory: AgenTTYAnalyticsHostSetupErrorCategory?,
    errorMessage: String,
    analyticsMetadata: HostSetupAnalyticsMetadata,
    probeAttemptCount: Int? = nil,
    verificationAttemptCount: Int? = nil,
    verificationFailureOutcome: AgenTTYSSHTerminationOutcome? = nil
) {
    var data: [String: String] = [
        "flow_id": flowID,
        "method": method.rawValue,
        "stage": stage.rawValue,
        "uses_tailscale_address": usesTailscaleAddress ? "true" : "false",
        "error_category": errorCategory?.rawValue ?? "none",
        "host_platform": analyticsMetadata.hostPlatform?.rawValue ?? "unknown",
        "selected_candidate_kind": analyticsMetadata.selectedCandidateKind?.rawValue ?? "none",
        "selected_candidate_source": analyticsMetadata.selectedCandidateSource?.rawValue ?? "none",
        "selected_candidate_rank": analyticsMetadata.selectedCandidateRank.map(String.init) ?? "none",
        "candidate_count": analyticsMetadata.candidateCount.map(String.init) ?? "none",
        "high_confidence_candidate_count": analyticsMetadata.highConfidenceCandidateCount.map(String.init) ?? "none",
        "all_low_confidence_candidates": analyticsMetadata.allLowConfidenceCandidates.map { $0 ? "true" : "false" } ?? "none",
    ]
    if let probeAttemptCount {
        data["probe_attempt_count"] = String(probeAttemptCount)
    }
    if let verificationAttemptCount {
        data["verification_attempt_count"] = String(verificationAttemptCount)
    }
    if let verificationFailureOutcome {
        data["verification_failure_stage"] = verificationFailureOutcome.failureStage?.analyticsValue.rawValue ?? "none"
        data["verification_disconnect_category"] = verificationFailureOutcome.category.analyticsValue.rawValue
    }
    if let hostEnvironmentFlags = analyticsMetadata.hostEnvironmentFlags, !hostEnvironmentFlags.isEmpty {
        data["host_environment_flags"] = hostEnvironmentFlags.map(\.rawValue).joined(separator: ",")
    }

    AgenTTYSentryService.captureHandledError(
        message: errorMessage,
        context: context,
        data: data
    )
}

private extension AgenTTYPairingHostCandidateKind {
    var analyticsValue: AgenTTYAnalyticsHostCandidateKind {
        switch self {
        case .tailscaleShort:
            .tailscaleShort
        case .tailscaleFQDN:
            .tailscaleFQDN
        case .fqdn:
            .fqdn
        case .singleLabel:
            .singleLabel
        case .localDomain:
            .localDomain
        }
    }
}

private extension AgenTTYPairingHostCandidateSource {
    var analyticsValue: AgenTTYAnalyticsHostCandidateSource {
        switch self {
        case .scutilHostname:
            .scutilHostname
        case .scutilLocalhostname:
            .scutilLocalhostname
        case .hostnameFQDN:
            .hostnameFQDN
        case .hostname:
            .hostname
        case .osHostname:
            .osHostname
        case .envHostname:
            .envHostname
        case .tailscaleShort:
            .tailscaleShort
        case .tailscaleMagicDNS:
            .tailscaleMagicDNS
        case .legacyHostnameCandidates:
            .legacyHostnameCandidates
        }
    }
}

private extension AgenTTYPairingHostEnvironmentFlag {
    var analyticsValue: AgenTTYAnalyticsHostEnvironmentFlag {
        switch self {
        case .container:
            .container
        case .wsl:
            .wsl
        }
    }
}

private extension String {
    var analyticsValue: AgenTTYAnalyticsHostPlatform? {
        switch lowercased() {
        case "linux":
            .linux
        case "macos":
            .macos
        default:
            nil
        }
    }
}

private extension AgenTTYHostReachabilityFailureSubtype {
    var analyticsValue: AgenTTYAnalyticsReachabilityFailureSubtype {
        switch self {
        case .dns:
            .dns
        case .timeout:
            .timeout
        case .connectionRefused:
            .connectionRefused
        case .networkUnreachable:
            .networkUnreachable
        case .other:
            .other
        }
    }
}

private enum AgenTTYPairingQRCodeSetupError: LocalizedError {
    case missingSSHKey
    case missingDetectedUsername
    case missingHostAddress
    case invalidHostMetadata
    case pairingFailed(String)
    case pairingExpired

    var errorDescription: String? {
        switch self {
        case .missingSSHKey:
            "Unable to load the selected AgenTTY SSH key."
        case .missingDetectedUsername:
            "Pairing completed, but the host did not report a usable username."
        case .missingHostAddress:
            "Pairing completed, but the host did not report a usable hostname."
        case .invalidHostMetadata:
            "Pairing completed with invalid host metadata."
        case .pairingFailed(let message):
            message
        case .pairingExpired:
            "The pairing code expired before the host finished setup."
        }
    }
}
