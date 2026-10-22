import SwiftUI

struct KeyPressCallout: View {
    let label: String
    let keyWidth: CGFloat
    let keyHeight: CGFloat

    static let bubbleHeight: CGFloat = 62
    static let neckHeight: CGFloat = 16
    static let overlayCenterYOffset = -((bubbleHeight + neckHeight) / 2)

    private let bubbleCornerRadius: CGFloat = 12
    private let keyCornerRadius: CGFloat = 5  // matches KeyButton.baseCornerRadius

    // Bubble is noticeably wider than the key — gives the diagonal shoulders room to breathe.
    // Extra +8 per the user's request for a slightly wider bubble.
    private var bubbleWidth: CGFloat {
        min(max(keyWidth + 30, 58), 76)
    }

    var body: some View {
        let shape = KeyPressCalloutShape(
            bubbleWidth: bubbleWidth,
            keyWidth: keyWidth,
            keyHeight: keyHeight,
            neckHeight: Self.neckHeight,
            bubbleHeight: Self.bubbleHeight,
            bubbleCornerRadius: bubbleCornerRadius,
            keyCornerRadius: keyCornerRadius
        )

        shape
            .fill(AppTheme.keyCharacterPressed)
            .shadow(color: .black.opacity(0.22), radius: 4)
            .frame(
                width: bubbleWidth,
                height: Self.bubbleHeight + Self.neckHeight + keyHeight
            )
            .overlay {
                Text(label)
                    .font(.system(size: 44, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.primaryText)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    // Center the label in the bubble portion, not the whole frame.
                    .offset(y: -((Self.neckHeight + keyHeight) / 2))
            }
    }
}

// Tombstone shape: rounded-rect bubble → straight diagonal shoulders → key-sized base.
// The base exactly matches the pressed key dimensions so the two shapes read as one object.
nonisolated struct KeyPressCalloutShape: Shape {
    let bubbleWidth: CGFloat
    let keyWidth: CGFloat
    let keyHeight: CGFloat
    let neckHeight: CGFloat
    let bubbleHeight: CGFloat
    let bubbleCornerRadius: CGFloat
    let keyCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Vertical layout (top → bottom):
        //  [0 … bubbleHeight]                   bubble
        //  [bubbleHeight … bubbleHeight+neckHeight]  diagonal neck
        //  [bubbleHeight+neckHeight … maxY]     key section
        let neckTopY = bubbleHeight
        let keyTopY  = bubbleHeight + neckHeight

        let cx   = rect.midX
        let keyHW = min(keyWidth / 2, rect.width / 2 - 1)

        let br = min(bubbleCornerRadius, bubbleHeight / 2, rect.width / 2)
        let kr = min(keyCornerRadius,   keyHeight  / 2, keyHW)

        var p = Path()

        // ── Bubble ──────────────────────────────────────────────────
        p.move(to: CGPoint(x: rect.minX + br, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - br, y: rect.minY))
        p.addArc(center: .init(x: rect.maxX - br, y: rect.minY + br),
                 radius: br, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: neckTopY))

        // ── Right diagonal shoulder (straight) ──────────────────────
        p.addLine(to: CGPoint(x: cx + keyHW, y: keyTopY))

        // ── Key section ─────────────────────────────────────────────
        p.addLine(to: CGPoint(x: cx + keyHW, y: rect.maxY - kr))
        p.addArc(center: .init(x: cx + keyHW - kr, y: rect.maxY - kr),
                 radius: kr, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: cx - keyHW + kr, y: rect.maxY))
        p.addArc(center: .init(x: cx - keyHW + kr, y: rect.maxY - kr),
                 radius: kr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: cx - keyHW, y: keyTopY))

        // ── Left diagonal shoulder (straight) ───────────────────────
        p.addLine(to: CGPoint(x: rect.minX, y: neckTopY))

        // ── Left bubble side ────────────────────────────────────────
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + br))
        p.addArc(center: .init(x: rect.minX + br, y: rect.minY + br),
                 radius: br, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        p.closeSubpath()
        return p
    }
}

extension CGRect {
    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
