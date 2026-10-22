import SwiftUI

@safe
struct TerminalSettingsSheet: View {
    @AppStorage(TerminalFontSizeSetting.storageKey, store: AgenTTYSharedDefaults.store)
    private var terminalFontSize: Double = TerminalFontSizeSetting.defaultValue
    @AppStorage(KeyboardEncodingMode.storageKey, store: AgenTTYSharedDefaults.store)
    private var keyboardEncodingModeRawValue: String = KeyboardEncodingMode.defaultValue.rawValue
    @AppStorage(KeyboardInputMode.storageKey, store: AgenTTYSharedDefaults.store)
    private var keyboardInputModeRawValue: String = KeyboardInputMode.defaultValue.rawValue
    @AppStorage(NewShellWorkingDirectorySetting.storageKey, store: AgenTTYSharedDefaults.store)
    private var reuseRightmostWorkingDirectoryForNewShells: Bool = NewShellWorkingDirectorySetting.defaultValue
    @AppStorage(AgenTTYFeatureFlags.shellTitleAIStorageKey, store: AgenTTYSharedDefaults.store)
    private var shellTitleAIEnabled: Bool = true
    @AppStorage(AgenTTYFeatureFlags.dictationAIStorageKey, store: AgenTTYSharedDefaults.store)
    private var enhancedDictationEnabled: Bool = true
    @AppStorage(AgenTTYDictation.modelStorageKey, store: AgenTTYSharedDefaults.store)
    private var dictationModelRawValue: String?
    @AppStorage(AgenTTYDictationLibrary.consentKey, store: AgenTTYSharedDefaults.store)
    private var dictationLibraryEnabled = false
    @State private var dictationLibrary = AgenTTYDictationLibrary.shared
    @State private var navigation = SheetNavigationCoordinator<SettingsRoute>()

    private enum SettingsRoute: Hashable {
        case acknowledgements
    }

    private var shellTitleAIUnavailableInCurrentFlavor: Bool {
        !AgenTTYFeatureFlags.shellTitleAIAvailableInCurrentFlavor
    }

    private var modelSelectionAvailableInCurrentFlavor: Bool {
        AgenTTYDictation.modelSelectionAvailableInCurrentFlavor
    }

    private var selectedDictationModel: AgenTTYDictation.Model? {
        if dictationLibraryEnabled, let profile = dictationLibrary.profile,
           let model = AgenTTYDictation.Model.allCases.first(where: { $0.libraryIdentifier == profile.preferredModel }) {
            return model
        }
        guard let dictationModelRawValue else {
            return nil
        }
        return AgenTTYDictation.Model(rawValue: dictationModelRawValue)
    }

    private func selectDictationModel(_ model: AgenTTYDictation.Model) {
        if dictationLibraryEnabled { dictationLibrary.setPreferredModel(model) }
        else { dictationModelRawValue = model.rawValue }
    }

    private var dictationProviderSubtitle: String? {
        guard selectedDictationModel != nil else {
            return "Select a provider"
        }
        return AgenTTYDictation.routerConfigured ? nil : "No llm-router key in this build"
    }

    private var dictationModelSubtitle: String? {
        switch selectedDictationModel?.capture {
        case .streaming: "Transcribes while you speak"
        case .batch: "Transcribes after you stop"
        case nil: nil
        }
    }

    private var selectedKeyboardEncodingMode: KeyboardEncodingMode {
        if let mode = KeyboardEncodingMode(rawValue: keyboardEncodingModeRawValue) {
            return mode
        }
        return .defaultValue
    }

    private var selectedKeyboardInputMode: KeyboardInputMode {
        if let mode = KeyboardInputMode(rawValue: keyboardInputModeRawValue) {
            return mode
        }
        return .defaultValue
    }

    private var enhancedDictationSubtitle: String {
        AgenTTYDictation.enhancedDictationSubtitle(enabled: enhancedDictationEnabled)
    }

    private var newShellWorkingDirectorySubtitle: String {
        if reuseRightmostWorkingDirectoryForNewShells {
            return "New shells start in the rightmost shell's folder."
        }
        return "New shells start in HOME."
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            List {
                Section {
                    TerminalSettingsRow(
                        icon: "textformat.size",
                        iconTint: .blue,
                        title: "Font Size"
                    ) {
                        HStack(spacing: 12) {
                            FontSizeStepButton(
                                systemName: "minus",
                                enabled: TerminalFontSizeSetting.canDecrement(terminalFontSize)
                            ) {
                                terminalFontSize = TerminalFontSizeSetting.decrement(terminalFontSize)
                            }

                            FontSizeSlider(value: $terminalFontSize)
                                .frame(minWidth: 100)

                            FontSizeStepButton(
                                systemName: "plus",
                                enabled: TerminalFontSizeSetting.canIncrement(terminalFontSize)
                            ) {
                                terminalFontSize = TerminalFontSizeSetting.increment(terminalFontSize)
                            }
                        }
                        .sensoryFeedback(.selection, trigger: terminalFontSize)
                    }

                    TerminalSettingsRow(
                        icon: "keyboard",
                        iconTint: .teal,
                        title: "Keyboard Mode",
                        subtitle: selectedKeyboardEncodingMode.subtitle
                    ) {
                        Menu {
                            ForEach(KeyboardEncodingMode.allCases, id: \.self) { mode in
                                Button(mode.displayName) {
                                    keyboardEncodingModeRawValue = mode.rawValue
                                }
                            }
                        } label: {
                            settingsMenuLabel(title: selectedKeyboardEncodingMode.displayName)
                        }
                    }

                    TerminalSettingsRow(
                        icon: "keyboard.badge.ellipsis",
                        iconTint: .teal,
                        title: "Keyboard Style",
                        subtitle: selectedKeyboardInputMode.subtitle
                    ) {
                        Menu {
                            ForEach(KeyboardInputMode.allCases, id: \.self) { mode in
                                Button(mode.displayName) {
                                    keyboardInputModeRawValue = mode.rawValue
                                }
                            }
                        } label: {
                            settingsMenuLabel(title: selectedKeyboardInputMode.displayName)
                        }
                    }

                    TerminalSettingsRow(
                        icon: "folder.badge.plus",
                        iconTint: .orange,
                        title: "Reuse Working Directory",
                        subtitle: newShellWorkingDirectorySubtitle
                    ) {
                        Toggle("", isOn: $reuseRightmostWorkingDirectoryForNewShells)
                            .labelsHidden()
                            .tint(.orange)
                    }
                }
                .listRowBackground(AppTheme.sheetListRowBackground)

                Section {
                    TerminalSettingsRow(
                        icon: "sparkles",
                        iconTint: .indigo,
                        title: "Shell Titles",
                        subtitle: "Generate shell titles via Gemini"
                    ) {
                        if shellTitleAIUnavailableInCurrentFlavor {
                            comingSoonLabel()
                        } else {
                            Toggle("", isOn: $shellTitleAIEnabled)
                                .labelsHidden()
                                .tint(.indigo)
                        }
                    }
                    .opacity(shellTitleAIUnavailableInCurrentFlavor ? 0.55 : 1.0)

                    TerminalSettingsRow(
                        icon: "waveform",
                        iconTint: .purple,
                        title: "Enhanced Dictation",
                        subtitle: enhancedDictationSubtitle
                    ) {
                        Toggle("", isOn: $enhancedDictationEnabled)
                            .labelsHidden()
                            .tint(.purple)
                    }

                    TerminalSettingsRow(
                        icon: "icloud",
                        iconTint: .purple,
                        title: "WisprClone Library",
                        subtitle: dictationLibrary.status ?? "Share your dictionary and save recordings in your private iCloud library."
                    ) {
                        Toggle("", isOn: $dictationLibraryEnabled)
                            .labelsHidden()
                            .tint(.purple)
                    }
                    .onChange(of: dictationLibraryEnabled) { _, enabled in
                        if enabled { Task { await dictationLibrary.resumePublication() } }
                    }

                    NavigationLink {
                        DictationRecoveryView(library: dictationLibrary)
                    } label: {
                        Label("Recording Recovery", systemImage: "waveform.badge.exclamationmark")
                    }

                    if modelSelectionAvailableInCurrentFlavor && enhancedDictationEnabled {
                        TerminalSettingsRow(
                            icon: "server.rack",
                            iconTint: .purple.opacity(0.7),
                            title: "Provider",
                            subtitle: dictationProviderSubtitle,
                            subtitleColor: .red
                        ) {
                            Menu {
                                ForEach(AgenTTYDictation.Provider.allCases, id: \.self) { provider in
                                    Button(provider.displayName) {
                                        if let model = provider.models.first { selectDictationModel(model) }
                                    }
                                }
                            } label: {
                                settingsMenuLabel(
                                    title: selectedDictationModel?.provider.displayName ?? "Not configured",
                                    isError: selectedDictationModel == nil
                                )
                            }
                            .disabled(dictationLibrary.isSavingSettings)
                        }

                        if let selectedDictationModel {
                            TerminalSettingsRow(
                                icon: "waveform.badge.mic",
                                iconTint: .purple.opacity(0.5),
                                title: "Model",
                                subtitle: dictationModelSubtitle
                            ) {
                                Menu {
                                    ForEach(selectedDictationModel.provider.models, id: \.self) { model in
                                        Button(model.displayName) {
                                            selectDictationModel(model)
                                        }
                                    }
                                } label: {
                                    settingsMenuLabel(title: selectedDictationModel.displayName)
                                }
                                .disabled(dictationLibrary.isSavingSettings)
                            }
                        }
                    }
                } header: {
                    Text("AI Features")
                }
                .listRowBackground(AppTheme.sheetListRowBackground)

                Section {
                    Button {
                        navigation.navigate(to: .acknowledgements)
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                }
                .listRowBackground(AppTheme.sheetListRowBackground)
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .acknowledgements: AgenTTYAcknowledgementsView()
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .containerBackground(.clear, for: .navigation)
            .task { if dictationLibraryEnabled { await dictationLibrary.resumePublication() } }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .overlayPreferenceValue(FontSizeThumbPreferenceKey.self) { data in
                GeometryReader { proxy in
                    if let data, let anchor = data.trackAnchor {
                        let trackRect = proxy[anchor]
                        Text("\(TerminalFontSizeSetting.formattedValue(data.value)) pt")
                            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                            )
                            .position(x: trackRect.minX + data.currentX + data.thumbWidth / 2, y: trackRect.midY - 44)
                            .scaleEffect(data.isDragging ? 1.0 : 0.6, anchor: .bottom)
                            .opacity(data.isDragging ? 1 : 0)
                            .animation(.interpolatingSpring(stiffness: 300, damping: 25), value: data.isDragging)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .presentationDetents([.medium, .large], selection: $navigation.selectedDetent)
        .sheetDetailNavigation(navigation)
    }
}

@MainActor
private func settingsMenuLabel(title: String, isError: Bool = false) -> some View {
    HStack(spacing: 6) {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(isError ? .red : .primary)
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(
        RoundedRectangle(cornerRadius: 8)
            .stroke(AppTheme.primaryText.opacity(0.3), lineWidth: 1)
    )
}

@MainActor
private func comingSoonLabel() -> some View {
    Text(AgenTTYFeatureFlags.aiComingSoonLabel)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .stroke(AppTheme.primaryText.opacity(0.25), lineWidth: 1)
        )
}

private let fontSizeControlHeight: CGFloat = 28

@safe
private struct FontSizeStepButton: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: fontSizeControlHeight, height: fontSizeControlHeight)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .overlay(Circle().stroke(AppTheme.primaryText.opacity(0.3), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .opacity(enabled ? 1 : 0.3)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}

@safe
private struct FontSizeThumbData {
    var trackAnchor: Anchor<CGRect>?
    var isDragging: Bool
    var value: Double
    var currentX: CGFloat
    var thumbWidth: CGFloat
}

@safe
private struct FontSizeThumbPreferenceKey: PreferenceKey {
    static let defaultValue: FontSizeThumbData? = nil
    static func reduce(value: inout FontSizeThumbData?, nextValue: () -> FontSizeThumbData?) {
        value = nextValue() ?? value
    }
}

@safe
private struct FontSizeSlider: View {
    @Binding var value: Double
    @State private var isDragging = false
    @State private var dragX: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let thumbWidth: CGFloat = 58
            let thumbHeight: CGFloat = fontSizeControlHeight
            let availableWidth = max(0, trackWidth - thumbWidth)
            
            let range = TerminalFontSizeSetting.maximumValue - TerminalFontSizeSetting.minimumValue
            let percentage = (value - TerminalFontSizeSetting.minimumValue) / range
            
            let currentX: CGFloat = dragX ?? (CGFloat(percentage) * availableWidth)
            
            ZStack(alignment: .leading) {
                // Track Background
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 5)
                
                // Track Fill
                Capsule()
                    .fill(Color.blue)
                    .frame(width: currentX + thumbWidth / 2, height: 5)
                
                // Thumb
                Text(TerminalFontSizeSetting.formattedValue(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .opacity(isDragging ? 0 : 1)
                    .scaleEffect(isDragging ? 0.6 : 1.0)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.primaryText.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .offset(x: currentX)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                            }
                            let clampedX = min(max(gesture.location.x - thumbWidth / 2, 0), availableWidth)
                            dragX = clampedX
                            
                            let newPercentage = clampedX / availableWidth
                            let rawValue = TerminalFontSizeSetting.minimumValue + newPercentage * range
                            let stepped = round(rawValue / TerminalFontSizeSetting.stepValue) * TerminalFontSizeSetting.stepValue
                            value = min(max(stepped, TerminalFontSizeSetting.minimumValue), TerminalFontSizeSetting.maximumValue)
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragX = nil
                        }
                )
            }
            .anchorPreference(key: FontSizeThumbPreferenceKey.self, value: .bounds) { anchor in
                FontSizeThumbData(trackAnchor: anchor, isDragging: isDragging, value: value, currentX: currentX, thumbWidth: thumbWidth)
            }
            .frame(height: thumbHeight)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 36)
        .animation(.interpolatingSpring(stiffness: 300, damping: 25), value: isDragging)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.8), trigger: isDragging)
    }
}

@safe
struct TerminalSettingsRow<TrailingContent: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = .secondary
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.darkModePrimaryText)
                .frame(width: 26, height: 26)
                .background(iconTint.gradient, in: .rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailingContent()
        }
        .frame(minHeight: 36)
        .padding(.vertical, 2)
    }
}
