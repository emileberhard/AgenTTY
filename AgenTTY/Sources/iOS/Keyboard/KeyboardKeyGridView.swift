import SwiftUI

struct KeyGridView: View {
    let keyboardState: KeyboardState
    let inputRouter: TerminalInputRouter

    private let keyHeight: CGFloat = 45
    private let bottomRowHeight: CGFloat = 45

    private var currentRows: [[KeyDefinition]] {
        switch keyboardState.layer {
        case .letters:
            KeyboardLayouts.letterRows()
        case .symbols: KeyboardLayouts.symbolRows
        }
    }

    var body: some View {
        GeometryReader { geo in
            // SwiftUI can report transient zero/invalid geometry during startup.
            // Clamp here so child key frames never receive negative/non-finite widths.
            let availableWidth = sanitizedWidth(geo.size.width - 8)

            VStack(spacing: 8) {
                ForEach(Array(currentRows.enumerated()), id: \.offset) { rowIndex, row in
                    KeyRowDepthWrapper(
                        rowIndex: rowIndex,
                        rowCount: currentRows.count,
                        keyboardState: keyboardState
                    ) {
                        KeyRow(
                            keys: row,
                            rowIndex: rowIndex,
                            availableWidth: availableWidth,
                            keyHeight: rowIndex == currentRows.count - 1 ? bottomRowHeight : keyHeight,
                            keyboardState: keyboardState,
                            inputRouter: inputRouter
                        )
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .frame(height: keyGridHeight)
        .allowsHitTesting(keyboardState.isInputEnabled)
    }

    private func sanitizedWidth(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    private var keyGridHeight: CGFloat {
        let rowCount = CGFloat(currentRows.count)
        let spacing: CGFloat = 8
        let padding: CGFloat = 12
        return (rowCount - 1) * keyHeight + bottomRowHeight + (rowCount - 1) * spacing + padding
    }
}

private struct KeyRowDepthWrapper<Content: View>: View {
    let rowIndex: Int
    let rowCount: Int
    let keyboardState: KeyboardState
    let content: Content

    init(
        rowIndex: Int,
        rowCount: Int,
        keyboardState: KeyboardState,
        @ViewBuilder content: () -> Content
    ) {
        self.rowIndex = rowIndex
        self.rowCount = rowCount
        self.keyboardState = keyboardState
        self.content = content()
    }

    var body: some View {
        content
            .zIndex(rowZIndex)
    }

    private var rowZIndex: Double {
        VisualLayering.KeyboardRows.resolvedZIndex(
            rowIndex: rowIndex,
            rowCount: rowCount,
            isModifierHintElevated: keyboardState.isModifierHintRowElevated(rowIndex),
            hasActiveKeyCallout: keyboardState.hasActiveKeyCallout(in: rowIndex),
            isBottomRow: rowIndex == rowCount - 1
        )
    }
}

private struct KeyRow: View {
    let keys: [KeyDefinition]
    let rowIndex: Int
    let availableWidth: CGFloat
    let keyHeight: CGFloat
    let keyboardState: KeyboardState
    let inputRouter: TerminalInputRouter

    private var rowInset: CGFloat {
        if keyboardState.layer == .letters,
           keys.contains(where: { $0.id == "char-a" }) {
            return 16
        }
        return 0
    }

    var body: some View {
        let totalWeight = keys.reduce(CGFloat(0)) { $0 + $1.widthWeight }
        let spacing: CGFloat = 7
        let totalSpacing = spacing * CGFloat(keys.count - 1)
        let inset = max(rowInset, 0)
        let safeAvailableWidth = max(availableWidth, 0)
        let safeTotalWeight = totalWeight > 0 && totalWeight.isFinite ? totalWeight : 1
        let effectiveWidth = max(safeAvailableWidth - totalSpacing - inset * 2, 0)
        let unitWidth = max(effectiveWidth / safeTotalWeight, 0)

        HStack(spacing: spacing) {
            ForEach(keys.indices, id: \.self) { slotIndex in
                let key = keys[slotIndex]
                keyView(for: key, unitWidth: unitWidth)
            }
        }
        .padding(.horizontal, inset)
    }

    @ViewBuilder
    private func keyView(for key: KeyDefinition, unitWidth: CGFloat) -> some View {
        let width = max(unitWidth * max(key.widthWeight, 0), 0)
        let dimmed = isDimmedDuringDictation(key)
        let renderInput = renderInput(for: key)

        Group {
            if key.action == .directionPad {
                DirectionalPadKeyButton(
                    definition: key,
                    width: width,
                    keyHeight: keyHeight,
                    keyboardState: keyboardState,
                    inputRouter: inputRouter,
                    visualInvalidationGeneration: keyboardState.visualInvalidationGeneration
                )
            } else {
                if key.action == .space {
                    SpacebarKeyHost(
                        definition: key,
                        width: width,
                        height: keyHeight,
                        rowIndex: rowIndex,
                        keyboardState: keyboardState,
                        inputRouter: inputRouter,
                        renderInput: renderInput
                    )
                } else {
                    KeyButton(
                        definition: key,
                        width: width,
                        height: keyHeight,
                        rowIndex: rowIndex,
                        keyboardState: keyboardState,
                        inputRouter: inputRouter,
                        renderInput: renderInput,
                        spacebarTitle: " ",
                        activeSpacebarWindowID: nil,
                        spacebarTitleSlideDirection: .none,
                        spacebarSwipePreviewProgress: 0,
                        spacebarSwipeReleaseVelocityX: 0,
                        spacebarShellCards: [],
                        onSpacebarShellCardSelect: nil,
                        onSpacebarCharacterLimitChange: nil
                    )
                }
            }
        }
        .opacity(dimmed ? 0.35 : 1.0)
        .allowsHitTesting(!dimmed)
    }

    private func isDimmedDuringDictation(_ key: KeyDefinition) -> Bool {
        inputRouter.isDictationButtonActive && key.action != .dictation
    }

    private func renderInput(for key: KeyDefinition) -> KeyButtonRenderInput {
        let isDictationKey = key.action == .dictation
        let modifier = key.action.modifierKey
        let isModifierActive: Bool
        let isModifierLocked: Bool
        if let modifier {
            isModifierActive = keyboardState.isModifierActive(modifier)
            isModifierLocked = keyboardState.isModifierLocked(modifier)
        } else {
            isModifierActive = false
            isModifierLocked = false
        }

        return KeyButtonRenderInput(
            displayLabel: displayLabel(for: key),
            isInputEnabled: keyboardState.isInputEnabled,
            isHostInteractionAvailable: inputRouter.hostConnectionPhase.allowsHostInteraction,
            pressCancellationGeneration: keyboardState.pressCancellationGeneration,
            visualInvalidationGeneration: keyboardState.visualInvalidationGeneration,
            isModifierActive: isModifierActive,
            isModifierLocked: isModifierLocked,
            isDictationProcessing: isDictationKey ? inputRouter.isDictationProcessing : false,
            isDictationCaptureActive: isDictationKey ? inputRouter.isDictationCaptureActive : false,
            isDictationButtonActive: isDictationKey ? inputRouter.isDictationButtonActive : false
        )
    }

    private func displayLabel(for key: KeyDefinition) -> String {
        if case .character(let c) = key.action,
           c.count == 1,
           c.first?.isLetter == true,
           keyboardState.layer == .letters {
            return keyboardState.isUppercase ? c.uppercased() : c
        }

        if key.action == .shift {
            switch keyboardState.shiftState {
            case .lowercase: return "\u{21E7}"
            case .shifted: return "\u{21E7}"
            case .capsLock: return "\u{21EA}"
            }
        }

        return key.label
    }
}

private struct SpacebarKeyHost: View {
    @Environment(ShellIndicatorState.self) private var shellState

    let definition: KeyDefinition
    let width: CGFloat
    let height: CGFloat
    let rowIndex: Int
    let keyboardState: KeyboardState
    let inputRouter: TerminalInputRouter
    let renderInput: KeyButtonRenderInput

    var body: some View {
        KeyButton(
            definition: definition,
            width: width,
            height: height,
            rowIndex: rowIndex,
            keyboardState: keyboardState,
            inputRouter: inputRouter,
            renderInput: renderInput,
            spacebarTitle: shellState.activeShellTitle,
            activeSpacebarWindowID: shellState.activeWindowId,
            spacebarTitleSlideDirection: shellState.activeShellTitleSlideDirection,
            spacebarSwipePreviewProgress: shellState.activeShellSwipePreviewProgress,
            spacebarSwipeReleaseVelocityX: shellState.activeShellSwipeReleaseVelocityX,
            spacebarShellCards: shellState.spacebarShellCards,
            onSpacebarShellCardSelect: { windowID in
                shellState.navigateAndClearUnread(windowID)
            },
            onSpacebarCharacterLimitChange: { maxCharacters in
                shellState.reportSpacebarTitleCharacterLimit(maxCharacters)
            }
        )
    }
}
