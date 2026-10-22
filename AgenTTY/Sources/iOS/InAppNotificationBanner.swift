import SwiftUI

@safe
struct InAppNotificationBanner: View {
    private enum DragLockAxis {
        case horizontal
        case vertical
    }

    private enum SwipeDismissDirection {
        case up
        case left
        case right
        case down

        var animation: Animation {
            switch self {
            case .up, .left:
                .spring(duration: 0.24, bounce: 0.06)
            case .right, .down:
                .easeOut(duration: 0.18)
            }
        }

        var finalOpacity: Double {
            switch self {
            case .up, .left:
                1
            case .right, .down:
                0
            }
        }

        func finalOffset(from translation: CGSize, in containerSize: CGSize) -> CGSize {
            switch self {
            case .up:
                let targetY = -max(120, containerSize.height * 0.28)
                return CGSize(width: 0, height: targetY)
            case .left:
                let targetX = -max(220, containerSize.width * 0.7)
                return CGSize(width: targetX, height: 0)
            case .right:
                let targetX = max(24, min(80, abs(translation.width)))
                return CGSize(width: targetX, height: 0)
            case .down:
                let targetY = max(24, min(80, abs(translation.height)))
                return CGSize(width: 0, height: targetY)
            }
        }
    }

    private let dismissThreshold: CGFloat = 56
    private let axisLockActivationDistance: CGFloat = 10
    private let interactiveFadeDistance: CGFloat = 260
    private let dismissCompletionDelay: Duration = .milliseconds(180)
    private let resetAnimation: Animation = .spring(duration: 0.26, bounce: 0.12)

    let notification: InAppNotification
    let onDismiss: () -> Void
    let onNavigate: (() -> Void)?
    @State private var dragOffset: CGSize = .zero
    @State private var dragOpacity: Double = 1
    @State private var isDragging = false
    @State private var hasCommittedDismiss = false
    @State private var dragLockAxis: DragLockAxis?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            GlassCapsuleBar(
                fixedWidth: geo.size.width * 0.55,
                fitContentHeight: true,
                horizontalContentPadding: 20,
                verticalContentPadding: 10
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    let cleanBody = notification.body
                        .components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: "\n")
                    if !cleanBody.isEmpty {
                        Text(cleanBody)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(.rect)
            .offset(x: dragOffset.width, y: dragOffset.height)
            .opacity(dragOpacity)
            .highPriorityGesture(dismissalGesture(containerSize: geo.size))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            dismissTask?.cancel()
        }
        .onTapGesture {
            guard !isDragging, !hasCommittedDismiss else { return }
            if let onNavigate {
                onNavigate()
            } else {
                onDismiss()
            }
        }
    }

    private func dismissalGesture(containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard !hasCommittedDismiss else { return }
                isDragging = true

                if dragLockAxis == nil {
                    let translation = value.translation
                    let primaryDistance = max(abs(translation.width), abs(translation.height))
                    if primaryDistance >= axisLockActivationDistance {
                        dragLockAxis =
                            abs(translation.width) >= abs(translation.height)
                            ? .horizontal : .vertical
                    }
                }

                let translation = lockedTranslation(from: value.translation, axis: dragLockAxis)
                dragOffset = translation
                dragOpacity = dragOpacity(for: translation)
            }
            .onEnded { value in
                guard !hasCommittedDismiss else { return }
                isDragging = false
                let axis = dragLockAxis
                dragLockAxis = nil
                let translation = lockedTranslation(from: value.translation, axis: axis)

                if let direction = resolveDismissDirection(for: value, axis: axis) {
                    commitDismiss(direction, translation: translation, containerSize: containerSize)
                } else {
                    withAnimation(resetAnimation) {
                        dragOffset = .zero
                        dragOpacity = 1
                    }
                }
            }
    }

    private func lockedTranslation(from translation: CGSize, axis: DragLockAxis?) -> CGSize {
        guard let axis else { return translation }
        switch axis {
        case .horizontal:
            return CGSize(width: translation.width, height: 0)
        case .vertical:
            return CGSize(width: 0, height: translation.height)
        }
    }

    private func dragOpacity(for translation: CGSize) -> Double {
        let distance = max(abs(translation.width), abs(translation.height))
        let fade = min(0.35, distance / interactiveFadeDistance)
        return 1 - fade
    }

    private func resolveDismissDirection(
        for value: DragGesture.Value,
        axis: DragLockAxis?
    ) -> SwipeDismissDirection? {
        let projected = lockedTranslation(from: value.predictedEndTranslation, axis: axis)
        let translation = lockedTranslation(from: value.translation, axis: axis)

        switch axis {
        case .horizontal:
            if projected.width <= -dismissThreshold || translation.width <= -dismissThreshold {
                return .left
            }
            if projected.width >= dismissThreshold || translation.width >= dismissThreshold {
                return .right
            }
        case .vertical:
            if projected.height <= -dismissThreshold || translation.height <= -dismissThreshold {
                return .up
            }
            if projected.height >= dismissThreshold || translation.height >= dismissThreshold {
                return .down
            }
        case nil:
            let horizontalDominant = abs(projected.width) >= abs(projected.height)
            if horizontalDominant {
                if projected.width <= -dismissThreshold || translation.width <= -dismissThreshold {
                    return .left
                }
                if projected.width >= dismissThreshold || translation.width >= dismissThreshold {
                    return .right
                }
            } else {
                if projected.height <= -dismissThreshold || translation.height <= -dismissThreshold {
                    return .up
                }
                if projected.height >= dismissThreshold || translation.height >= dismissThreshold {
                    return .down
                }
            }
        }
        return nil
    }

    private func commitDismiss(
        _ direction: SwipeDismissDirection,
        translation: CGSize,
        containerSize: CGSize
    ) {
        hasCommittedDismiss = true
        dismissTask?.cancel()
        withAnimation(direction.animation) {
            dragOffset = direction.finalOffset(from: translation, in: containerSize)
            dragOpacity = direction.finalOpacity
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: dismissCompletionDelay)
            onDismiss()
        }
    }
}
