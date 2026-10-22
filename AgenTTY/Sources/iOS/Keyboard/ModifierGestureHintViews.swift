import SwiftUI

enum ModifierGestureHintIcon {
    case systemImage(String)
    case modifierSymbolPlus(String)
}

struct SpacebarOverlayVisibilityModifier: ViewModifier {
    let opacity: Double
    let scaleX: CGFloat
    let scaleY: CGFloat
    let riseOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .offset(y: riseOffset)
    }
}

struct ModifierGestureHintSymbol: View {
    let icon: ModifierGestureHintIcon
    let arrowName: String
    let iconOffset: CGFloat
    let directionalOffset: CGFloat
    let progress: CGFloat
    let frameSize: CGFloat
    let symbolScale: CGFloat

    private var normalizedProgress: CGFloat {
        min(max(progress, 0), 1)
    }

    private var iconOpacity: Double {
        0.72 + (0.27 * normalizedProgress)
    }

    private var arrowOpacity: Double {
        0.55 + (0.37 * normalizedProgress)
    }

    private var iconScale: CGFloat {
        1 + (0.21 * normalizedProgress)
    }

    private var hintScale: CGFloat {
        1 + (0.40 * normalizedProgress)
    }

    private var iconGlowOpacity: Double {
        0.16 + (0.56 * normalizedProgress)
    }

    private var arrowGlowOpacity: Double {
        0.12 + (0.36 * normalizedProgress)
    }

    private var glowRadius: CGFloat {
        2 + (11 * normalizedProgress)
    }

    private var iconUsesCapsuleBackground: Bool {
        switch icon {
        case .systemImage:
            false
        case .modifierSymbolPlus:
            true
        }
    }

    @ViewBuilder
    private var iconContent: some View {
        switch icon {
        case .systemImage(let iconName):
            Image(systemName: iconName)
        case .modifierSymbolPlus(let symbol):
            HStack(spacing: 2 * symbolScale) {
                Text(symbol)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "plus")
            }
            .fixedSize(horizontal: true, vertical: true)
        }
    }

    var body: some View {
        ZStack {
            iconContent
                .font(.system(size: 13 * symbolScale, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText.opacity(iconOpacity))
                .shadow(color: AppTheme.primaryText.opacity(iconGlowOpacity), radius: glowRadius, x: 0, y: 0)
                .shadow(color: .black.opacity(0.20 + (0.10 * normalizedProgress)), radius: 0, x: 0, y: 1)
                .padding(.horizontal, iconUsesCapsuleBackground ? (5 * symbolScale) : 0)
                .padding(.vertical, iconUsesCapsuleBackground ? (3 * symbolScale) : 0)
                .glassEffect(
                    iconUsesCapsuleBackground ? AppTheme.glass(.regular) : .identity,
                    in: .capsule
                )
                .padding(.top, iconUsesCapsuleBackground ? (3 * symbolScale) : 0)
                .frame(minWidth: frameSize, minHeight: frameSize)
                .scaleEffect(iconScale)
                .offset(y: iconOffset)

            Image(systemName: arrowName)
                .font(.system(size: 11 * symbolScale, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText.opacity(arrowOpacity))
            .shadow(color: AppTheme.primaryText.opacity(arrowGlowOpacity), radius: glowRadius - 1, x: 0, y: 0)
            .shadow(color: .black.opacity(0.18 + (0.10 * normalizedProgress)), radius: 0, x: 0, y: 1)
            .frame(width: frameSize, height: frameSize)
        }
        .scaleEffect(hintScale)
        .offset(y: directionalOffset)
        .animation(.easeOut(duration: 0.09), value: normalizedProgress)
    }
}
