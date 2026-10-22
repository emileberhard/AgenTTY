import SwiftUI
import UIKit

struct InAppKeyboardView: View {
    @Environment(TerminalInputRouter.self) private var inputRouter
    @Environment(AppThemeToken.self) private var themeToken
    @Environment(\.scenePhase) private var scenePhase
    let keyboardState: KeyboardState
    /// Sourced from the app shell's GeometryReader. The previous
    /// UIApplication key-window walk resolves 0 on current SDKs, which
    /// collapses the bottom shelf and drops the keyboard to the screen edge.
    let bottomSafeAreaInset: CGFloat
    @State private var modifierSlidePreviewMeasuredWidth: CGFloat = 0
    private let lifecycleUndoWindow: TimeInterval = 0.5
    private let keyboardMaskPadding: CGFloat = 5
    private let modifierSlidePreviewEdgePadding: CGFloat = 5
    private let modifierSlidePreviewVerticalOffset: CGFloat = -70

    private struct LayoutMetrics {
        let screenBounds: CGRect
    }

    var body: some View {
        let layoutMetrics = currentLayoutMetrics()

        KeyGridView(
            keyboardState: keyboardState,
            inputRouter: inputRouter
        )
            .id(themeToken.nonce)
            .overlay(alignment: .bottom) {
                ShellIndicatorView()
                    .id(themeToken.nonce)
                    .offset(y: shellIndicatorVerticalOffset(bottomSafeAreaInset: bottomSafeAreaInset))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    if let previewBaseText = keyboardState.modifierSlidePreviewBaseText,
                       (keyboardState.modifierSlidePreviewIsLatchedVisible
                           || !keyboardState.modifierSlidePreviewTargetText.isEmpty),
                       keyboardState.isInputEnabled {
                        let containerFrame = proxy.frame(in: .global)
                        let estimatedPreviewWidth = ModifierSlideChordPreviewCard.estimatedWidth(
                            prefixText: previewBaseText,
                            targetText: keyboardState.modifierSlidePreviewTargetText
                        )
                        let previewWidthForClamping = max(
                            modifierSlidePreviewMeasuredWidth,
                            estimatedPreviewWidth
                        )
                        ModifierSlideChordPreviewCard(
                            prefixText: previewBaseText,
                            targetText: keyboardState.modifierSlidePreviewTargetText
                        )
                            // GeometryReader lays children out from top-leading; this offset
                            // is therefore expressed in that local leading coordinate space.
                            .offset(
                                x: modifierSlidePreviewLeadingOffsetX(
                                    containerFrameInGlobal: containerFrame,
                                    previewWidth: previewWidthForClamping,
                                    screenBounds: layoutMetrics.screenBounds
                                ),
                                y: modifierSlidePreviewVerticalOffset
                            )
                            .allowsHitTesting(false)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .background {
                                GeometryReader { previewProxy in
                                    Color.clear
                                        .onAppear {
                                            updateModifierSlidePreviewMeasuredWidth(previewProxy.size.width)
                                        }
                                        .onChange(of: previewProxy.size.width) { _, width in
                                            updateModifierSlidePreviewMeasuredWidth(width)
                                        }
                                }
                            }
                    }
                }
            }
            .animation(
                .spring(duration: 0.24, bounce: 0.16),
                value: keyboardState.modifierSlidePreviewBaseText
            )
            .animation(
                .spring(duration: 0.11, bounce: 0.18),
                value: keyboardState.modifierSlidePreviewTargetText
            )
            .animation(
                .spring(duration: 0.11, bounce: 0.18),
                value: keyboardState.modifierSlidePreviewAnchorX
            )
            .padding(.bottom, extraBottomShelfHeight - keyboardBottomLift(bottomSafeAreaInset: bottomSafeAreaInset))
            // Only the background may bleed into the home-indicator zone. A
            // content-level ignoresSafeArea sinks the whole keyboard ~34pt on
            // current SDKs, hiding the shelf strip below the screen edge.
            .background {
                ZStack {
                    AppTheme.keyboardBackgroundGradient
                        .ignoresSafeArea(.container, edges: .bottom)
                    KeyboardHapticHostView()
                }
            }
            .onAppear {
                KeyboardHaptics.beginInteractiveSession()
                syncKeyboardLifecycle(with: scenePhase)
            }
            .onDisappear {
                handleAppWillDeactivate()
            }
            .onChange(of: scenePhase) { _, newPhase in
                syncKeyboardLifecycle(with: newPhase)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                handleAppWillDeactivate()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                handleAppWillDeactivate()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                handleAppBecameActive()
            }
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func activeWindowScene(activeKeyWindow: UIWindow?) -> UIWindowScene? {
        if let activeKeyWindowScene = activeKeyWindow?.windowScene {
            return activeKeyWindowScene
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
    }

    private func currentLayoutMetrics() -> LayoutMetrics {
        let activeKeyWindow = Self.activeKeyWindow()
        let activeWindowScene = Self.activeWindowScene(activeKeyWindow: activeKeyWindow)

        let keyWindowBounds = activeKeyWindow?.bounds ?? .zero
        let screenBounds: CGRect
        if keyWindowBounds.width > 0, keyWindowBounds.height > 0 {
            screenBounds = keyWindowBounds
        } else {
            let sceneBounds = activeWindowScene?.screen.bounds ?? .zero
            if sceneBounds.width > 0, sceneBounds.height > 0 {
                screenBounds = sceneBounds
            } else {
                screenBounds = .zero
            }
        }

        return LayoutMetrics(screenBounds: screenBounds)
    }

    private func keyboardBottomLift(bottomSafeAreaInset: CGFloat) -> CGFloat {
        max(0, bottomSafeAreaInset - 34)
    }

    private let extraBottomShelfHeight: CGFloat = 5

    private func effectiveBottomShelfHeight(bottomSafeAreaInset: CGFloat) -> CGFloat {
        max(
            0,
            bottomSafeAreaInset
                + extraBottomShelfHeight
                - keyboardBottomLift(bottomSafeAreaInset: bottomSafeAreaInset)
                - keyboardMaskPadding
        )
    }

    private func shellIndicatorVerticalOffset(bottomSafeAreaInset: CGFloat) -> CGFloat {
        (effectiveBottomShelfHeight(bottomSafeAreaInset: bottomSafeAreaInset) + ShellIndicatorView.shelfCenteringHeight) / 2
    }

    private func updateModifierSlidePreviewMeasuredWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        modifierSlidePreviewMeasuredWidth = width
    }

    private func modifierSlidePreviewLeadingOffsetX(
        containerFrameInGlobal frame: CGRect,
        previewWidth: CGFloat,
        screenBounds: CGRect
    ) -> CGFloat {
        guard frame.width.isFinite, frame.width > 0 else { return 0 }
        let normalizedPreviewWidth = max(previewWidth, 0)

        var placementBounds = frame
        if screenBounds.width > 0, screenBounds.height > 0 {
            let intersectedBounds = frame.intersection(screenBounds)
            if !intersectedBounds.isNull, intersectedBounds.width > 0, intersectedBounds.height > 0 {
                placementBounds = intersectedBounds
            }
        }

        let preferredCenterX = keyboardState.modifierSlidePreviewAnchorX ?? frame.midX
        let normalizedPreferredCenterX = preferredCenterX.isFinite ? preferredCenterX : frame.midX
        let halfPreviewWidth = normalizedPreviewWidth * 0.5

        let clampMinEdge = placementBounds.minX + modifierSlidePreviewEdgePadding
        let clampMaxEdge = placementBounds.maxX - modifierSlidePreviewEdgePadding

        let minCenterX = clampMinEdge + halfPreviewWidth
        let maxCenterX = clampMaxEdge - halfPreviewWidth

        let clampedCenterX: CGFloat
        if minCenterX <= maxCenterX {
            clampedCenterX = min(max(normalizedPreferredCenterX, minCenterX), maxCenterX)
        } else {
            clampedCenterX = (clampMinEdge + clampMaxEdge) * 0.5
        }

        let leadingEdgeXInGlobal = clampedCenterX - halfPreviewWidth
        return leadingEdgeXInGlobal - frame.minX
    }

    private func syncKeyboardLifecycle(with phase: ScenePhase) {
        switch phase {
        case .active:
            handleAppBecameActive()
        case .inactive, .background:
            handleAppWillDeactivate()
        @unknown default:
            handleAppWillDeactivate()
        }
    }

    private func handleAppBecameActive() {
        KeyboardHaptics.beginInteractiveSession()
        keyboardState.handleAppBecameActive()
    }

    private func handleAppWillDeactivate() {
        KeyboardHaptics.endInteractiveSession()
        let shouldUndoRecentInput = keyboardState.consumeLifecycleUndoCandidate(within: lifecycleUndoWindow)
        keyboardState.handleAppWillDeactivate()
        if shouldUndoRecentInput {
            inputRouter.handleKeyAction(.backspace, keyboardState: keyboardState)
        }
    }
}

private struct ModifierSlideChordPreviewCard: View {
    private static let font = UIFont.systemFont(ofSize: 28, weight: .semibold)
    private static let horizontalPadding: CGFloat = 21
    private static let targetMinimumWidth: CGFloat = 26

    let prefixText: String
    let targetText: String

    private var renderedTargetText: String {
        targetText.isEmpty ? "" : " \(targetText)"
    }

    static func estimatedWidth(prefixText: String, targetText: String) -> CGFloat {
        let prefixWidth = (prefixText as NSString).size(withAttributes: [.font: font]).width
        let renderedTargetText = targetText.isEmpty ? "" : " \(targetText)"
        let targetWidth = (renderedTargetText as NSString).size(withAttributes: [.font: font]).width
        let contentWidth = prefixWidth + max(targetWidth, targetMinimumWidth)
        return ceil(contentWidth + (horizontalPadding * 2))
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(prefixText)
            Text(renderedTargetText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: Self.targetMinimumWidth, alignment: .leading)
        }
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 14)
            .containerShape(.capsule)
            .glassEffect(AppTheme.glass(.regular), in: .capsule)
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 7)
            .animation(.spring(duration: 0.11, bounce: 0.18), value: targetText)
    }
}
