import SwiftUI

private enum SSHKeysRoute: Hashable {
    case add
    case edit(AgenTTYSSHKey)
}

private enum SSHKeyCreationMethod: String, CaseIterable {
    case generate
    case `import`

    var label: String {
        switch self {
        case .generate: "Generate"
        case .import: "Import"
        }
    }
}

private struct SSHKeyFormDraft {
    var name: String
    var keyType: SSHKeyType
    var creationMethod: SSHKeyCreationMethod
    var importedKeyText: String
    var importedKeyPassphrase: String

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isNameValid: Bool {
        !normalizedName.isEmpty
    }

    var isImportTextValid: Bool {
        !importedKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        name = ""
        keyType = .ed25519
        creationMethod = .generate
        importedKeyText = ""
        importedKeyPassphrase = ""
    }

    init(from key: AgenTTYSSHKey) {
        name = key.name
        keyType = key.keyType
        creationMethod = .generate
        importedKeyText = ""
        importedKeyPassphrase = ""
    }
}

private typealias SSHKeyDetailMode = SheetDetailMode<AgenTTYSSHKey>

@safe
struct TerminalSSHKeysSheet: View {
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore

    let analyticsClient: AgenTTYAnalyticsClient?
    let startsInAddMode: Bool
    let onAddKeyCreated: ((UUID) -> Void)?

    @State private var nav = SheetNavigationCoordinator<SSHKeysRoute>()
    @State private var hasAppliedInitialAddRoute = false

    init(
        analyticsClient: AgenTTYAnalyticsClient? = nil,
        startsInAddMode: Bool = false,
        onAddKeyCreated: ((UUID) -> Void)? = nil
    ) {
        self.analyticsClient = analyticsClient
        self.startsInAddMode = startsInAddMode
        self.onAddKeyCreated = onAddKeyCreated
    }

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: $nav.path) {
            keyList
                .navigationTitle("Keys")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add", systemImage: "plus") {
                            nav.navigate(to: .add)
                        }
                    }
                }
                .navigationDestination(for: SSHKeysRoute.self) { route in
                    switch route {
                    case .add:
                        SSHKeyDetailView(
                            mode: .add,
                            selectedDetent: $nav.selectedDetent,
                            analyticsClient: analyticsClient,
                            onAddKeyCreated: onAddKeyCreated
                        )
                    case .edit(let key):
                        SSHKeyDetailView(
                            mode: .edit(key),
                            selectedDetent: $nav.selectedDetent,
                            analyticsClient: analyticsClient
                        )
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $nav.selectedDetent)
        .sheetDetailNavigation(nav)
        .onAppear {
            guard startsInAddMode, !hasAppliedInitialAddRoute else { return }
            hasAppliedInitialAddRoute = true
            nav.navigate(to: .add)
        }
    }

    @ViewBuilder
    private var keyList: some View {
        if keyStore.keys.isEmpty {
            ContentUnavailableView {
                Label("No Keys", systemImage: "key.fill")
            } description: {
                Text("Add a key to get started.")
            } actions: {
                Button("Add Key") { nav.navigate(to: .add) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let usableKeyIDs = keyStore.usableKeyIDs
            List {
                Section {
                    ForEach(keyStore.keys) { sshKey in
                        Button { nav.navigate(to: .edit(sshKey)) } label: {
                            SSHKeyCardRow(sshKey: sshKey, hasMaterial: usableKeyIDs.contains(sshKey.id))
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
}

@safe
private struct SSHKeyCardRow: View {
    let sshKey: AgenTTYSSHKey
    let hasMaterial: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.darkModePrimaryText)
                .frame(width: 32, height: 32)
                .background((hasMaterial ? Color.orange : Color.gray).gradient, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(sshKey.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(sshKey.publicKeyFingerprint)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(sshKey.keyType.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AppTheme.surfaceOrnamentFill, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 1))
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

@safe
private struct SSHKeyDetailView: View {
    @Environment(AgenTTYSSHKeyStore.self) private var keyStore
    @Environment(AgenTTYHostStore.self) private var hostStore
    @Environment(\.dismiss) private var dismiss

    let mode: SSHKeyDetailMode

    @State private var draft: SSHKeyFormDraft
    @FocusState private var focusedField: FormField?
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var deletionBlockedMessage: String?
    @Binding var selectedDetent: PresentationDetent
    let analyticsClient: AgenTTYAnalyticsClient?
    let onAddKeyCreated: ((UUID) -> Void)?

    private enum FormField: Hashable {
        case name
        case passphrase
    }

    init(
        mode: SSHKeyDetailMode,
        selectedDetent: Binding<PresentationDetent>,
        analyticsClient: AgenTTYAnalyticsClient? = nil,
        onAddKeyCreated: ((UUID) -> Void)? = nil
    ) {
        self.mode = mode
        _selectedDetent = selectedDetent
        self.analyticsClient = analyticsClient
        self.onAddKeyCreated = onAddKeyCreated
        switch mode {
        case .add:
            _draft = State(initialValue: SSHKeyFormDraft())
        case .edit(let key):
            _draft = State(initialValue: SSHKeyFormDraft(from: key))
        }
    }

    private var canSave: Bool {
        guard draft.isNameValid else { return false }

        switch mode {
        case .add:
            switch draft.creationMethod {
            case .generate:
                return SSHKeyType.generatable.contains(draft.keyType)
            case .import:
                return draft.isImportTextValid
            }
        case .edit:
            return true
        }
    }

    private var deleteKeyConfirmationTitle: String {
        guard case .edit(let key) = mode else { return "Delete" }
        return "Delete \"\(key.name)\""
    }

    var body: some View {
        List {
            Section {
                SheetFormFieldRow(
                    icon: "tag",
                    label: "Name",
                    placeholder: "Key name",
                    text: $draft.name,
                    field: FormField.name,
                    focusedField: $focusedField,
                    isValid: draft.isNameValid,
                    autocapitalization: .words,
                    submitLabel: .done,
                    onSubmit: { commitSave() }
                )
            } header: {
                Text("Key Info")
            }

            if mode.isAdd {
                Section {
                    Picker("Method", selection: $draft.creationMethod) {
                        ForEach(SSHKeyCreationMethod.allCases, id: \.self) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(AppTheme.sheetListRowBackground)

                    switch draft.creationMethod {
                    case .generate:
                        SheetPickerRow(icon: "cpu", label: "Type", selection: $draft.keyType) {
                            ForEach(SSHKeyType.generatable, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }

                    case .import:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Paste private key")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                            TextEditor(text: $draft.importedKeyText)
                                .font(.caption.monospaced())
                                .frame(minHeight: 130)
                                .scrollContentBackground(.hidden)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(AppTheme.sheetListRowBackground)

                        passphraseRow
                    }
                } header: {
                    Text("Creation Method")
                }
            } else if let existingKey = mode.existing {
                Section {
                    SSHPublicKeyExportView(publicKey: existingKey.publicKey)
                } header: {
                    Text("Public Key")
                }

                Section {
                    detailRow(icon: "cpu", label: "Type", value: existingKey.keyType.displayName)
                    detailRow(icon: "number", label: "Fingerprint", value: existingKey.publicKeyFingerprint, monospaced: true)
                    detailRow(icon: "calendar", label: "Created", value: existingKey.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow(icon: "shippingbox", label: "Source", value: existingKey.source.displayName)
                } header: {
                    Text("Details")
                }
            }
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom) {
            if case .edit = mode, selectedDetent == .large {
                HStack {
                    SheetDestructiveActionButton { attemptDelete() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .containerBackground(.clear, for: .navigation)
        .navigationTitle(mode.isAdd ? "New Key" : (draft.name.isEmpty ? "Edit Key" : draft.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { commitSave() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            if mode.isAdd {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    focusedField = .name
                }
            }
        }
        .sheetDestructiveAlert(
            title: "Delete Key",
            confirmTitle: deleteKeyConfirmationTitle,
            message: "This key will be removed. This cannot be undone.",
            isPresented: $showDeleteConfirmation,
            onConfirm: confirmDeleteKey
        )
        .alert("Key Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Key In Use", isPresented: Binding(
            get: { deletionBlockedMessage != nil },
            set: { if !$0 { deletionBlockedMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deletionBlockedMessage = nil }
        } message: {
            Text(deletionBlockedMessage ?? "")
        }
    }

    private var passphraseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    focusedField == .passphrase ? AppTheme.primaryText : AppTheme.secondaryText
                )
                .frame(width: 18)

            Text("Passphrase")
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            SecureField("Encrypted keys only", text: $draft.importedKeyPassphrase)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .focused($focusedField, equals: .passphrase)
                .submitLabel(.done)
                .onSubmit { commitSave() }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            focusedField == .passphrase ? AppTheme.surfaceOrnamentFill : AppTheme.sheetListRowBackground
        )
    }

    private func detailRow(icon: String, label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            Text(label)
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 4)

            if monospaced {
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private func attemptDelete() {
        guard case .edit(let key) = mode else { return }
        let dependentHosts = hostStore.hosts.filter { $0.authentication.keyID == key.id }

        guard dependentHosts.isEmpty else {
            let hostNames = dependentHosts.map(\.label).joined(separator: ", ")
            deletionBlockedMessage = "This key is still used by: \(hostNames). Reassign those hosts first."
            return
        }

        showDeleteConfirmation = true
    }

    private func confirmDeleteKey() {
        guard case .edit(let key) = mode else { return }
        let deleteResult = keyStore.deleteKey(id: key.id)
        switch deleteResult {
        case .success:
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func commitSave() {
        guard canSave else { return }

        switch mode {
        case .add:
            let createResult: Result<UUID, AgenTTYSSHKeyStoreError>
            switch draft.creationMethod {
            case .generate:
                recordKeyMaterialEvent(
                    operation: .generate,
                    stage: .attempted,
                    keyType: draft.keyType
                )
                createResult = keyStore.addGeneratedKey(name: draft.normalizedName, keyType: draft.keyType)
            case .import:
                recordKeyMaterialEvent(operation: .import, stage: .attempted)
                createResult = keyStore.addImportedKey(
                    name: draft.normalizedName,
                    privateKeyText: draft.importedKeyText,
                    passphrase: draft.importedKeyPassphrase.isEmpty ? nil : draft.importedKeyPassphrase
                )
            }

            switch createResult {
            case .success(let keyID):
                recordKeyMaterialEvent(
                    operation: draft.creationMethod == .generate ? .generate : .import,
                    stage: .succeeded,
                    keyType: draft.creationMethod == .generate ? draft.keyType : nil
                )
                if let onAddKeyCreated {
                    onAddKeyCreated(keyID)
                } else {
                    dismiss()
                }
            case .failure(let error):
                recordKeyMaterialEvent(
                    operation: draft.creationMethod == .generate ? .generate : .import,
                    stage: .failed,
                    keyType: draft.creationMethod == .generate ? draft.keyType : nil,
                    failureReason: error.analyticsFailureReason,
                    failureDetail: error.localizedDescription
                )
                errorMessage = error.localizedDescription
            }

        case .edit(let key):
            guard keyStore.updateKeyName(id: key.id, name: draft.normalizedName) else {
                errorMessage = "Failed to update key name."
                return
            }
            dismiss()
        }
    }

    private func recordKeyMaterialEvent(
        operation: AgenTTYAnalyticsKeyMaterialOperation,
        stage: AgenTTYAnalyticsKeyMaterialStage,
        keyType: SSHKeyType? = nil,
        failureReason: AgenTTYAnalyticsKeyMaterialFailureReason? = nil,
        failureDetail: String? = nil
    ) {
        guard let analyticsClient else { return }
        Task {
            await analyticsClient.recordKeyMaterial(
                AgenTTYAnalyticsKeyMaterialEvent(
                    operation: operation,
                    stage: stage,
                    keyType: keyType,
                    failureReason: failureReason,
                    failureDetail: failureDetail
                )
            )
        }
    }
}

private extension AgenTTYSSHKeyStoreError {
    var analyticsFailureReason: AgenTTYAnalyticsKeyMaterialFailureReason {
        switch self {
        case .invalidName, .keyNotFound:
            .internalError
        case .generationOnlySupportsEd25519:
            .unsupportedPrivateKeyType
        case .keyMaterialFailure(let error):
            error.analyticsFailureReason
        }
    }
}

private extension AgenTTYSSHKeyMaterialError {
    var analyticsFailureReason: AgenTTYAnalyticsKeyMaterialFailureReason {
        switch self {
        case .rsaKeyTooSmall:
            .rsaUnsupported
        // The relay validates this enum strictly, so passphrase/cipher failures reuse the
        // existing encrypted-key bucket rather than introducing an unknown reason string.
        case .encryptedPrivateKeyNotSupported,
             .privateKeyPassphraseRequired,
             .privateKeyPassphraseIncorrect,
             .unsupportedPrivateKeyCipher:
            .encryptedPrivateKeyUnsupported
        case .unsupportedPrivateKeyFormat:
            .unsupportedPrivateKeyFormat
        case .invalidPrivateKeyFormat:
            .invalidPrivateKeyFormat
        case .unsupportedPrivateKeyType:
            .unsupportedPrivateKeyType
        case .keychainStoreFailed:
            .keychainStoreFailed
        case .bootstrapSeedKeyMaterialUnavailable,
             .invalidBootstrapSeedKeyMaterial,
             .keyMaterialNotFound,
             .keyMaterialCorrupt,
             .keychainReadFailed,
             .keychainDeleteFailed,
             .internalError:
            .internalError
        }
    }
}
