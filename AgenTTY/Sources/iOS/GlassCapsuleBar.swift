import SwiftUI

@safe
struct GlassCapsuleBar<Content: View>: View {
    static var unitHeight: CGFloat { 40 }
    static var sharedCornerRadius: CGFloat { 20 }

    let heightMultiplier: CGFloat
    let fixedWidth: CGFloat?
    let maxWidth: CGFloat?
    let fitContentHeight: Bool
    let horizontalContentPadding: CGFloat
    let verticalContentPadding: CGFloat
    @ViewBuilder let content: Content

    init(
        heightMultiplier: CGFloat = 1,
        fixedWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        fitContentHeight: Bool = false,
        horizontalContentPadding: CGFloat = 14,
        verticalContentPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.heightMultiplier = heightMultiplier
        self.fixedWidth = fixedWidth
        self.maxWidth = maxWidth
        self.fitContentHeight = fitContentHeight
        self.horizontalContentPadding = horizontalContentPadding
        self.verticalContentPadding = verticalContentPadding
        self.content = content()
    }

    var body: some View {
        let height = Self.unitHeight * heightMultiplier

        let container = Group {
            if let fixedWidth {
                content.frame(width: fixedWidth, alignment: .leading)
            } else if let maxWidth {
                content.frame(maxWidth: maxWidth, alignment: .leading)
            } else {
                content
            }
        }
        .padding(.horizontal, horizontalContentPadding)
        .padding(.vertical, verticalContentPadding)

        Group {
            if fitContentHeight {
                container
            } else {
                container.frame(height: height)
            }
        }
        .containerShape(.rect(cornerRadius: Self.sharedCornerRadius))
        .glassEffect(AppTheme.glass(.regular), in: .rect(cornerRadius: Self.sharedCornerRadius))
        .overlay {
            ConcentricRectangle(
                corners: .concentric(minimum: .fixed(Self.sharedCornerRadius)),
                isUniform: true
            )
            .stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 7)
    }
}
