import Foundation
import SwiftUI

extension KeyboardState {
    private static let slideChordFrameComparisonTolerance: CGFloat = 0.5

    struct SlideChordTarget {
        let id: String
        let action: KeyAction
        let style: KeyDefinition.KeyStyle
        let label: String
        let frame: CGRect
    }

    static func isApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= slideChordFrameComparisonTolerance
            && abs(lhs.origin.y - rhs.origin.y) <= slideChordFrameComparisonTolerance
            && abs(lhs.size.width - rhs.size.width) <= slideChordFrameComparisonTolerance
            && abs(lhs.size.height - rhs.size.height) <= slideChordFrameComparisonTolerance
    }

    static func modifierPreviewLabel(_ modifier: ModifierKey) -> String {
        switch modifier {
        case .shift:
            return "\u{21E7}"
        case .ctrl:
            return "\u{2303}"
        case .alt:
            return "\u{2325}"
        }
    }

    static func targetPreviewLabel(_ target: SlideChordTarget) -> String {
        switch target.action {
        case .character(let value):
            if value.count == 1, value.first?.isLetter == true {
                return value.uppercased()
            }
            return value
        case .backspace:
            return "\u{232B}"
        case .enter:
            return "\u{21B5}"
        case .space:
            return "Space"
        case .tab:
            return "Tab"
        case .escape:
            return "Esc"
        case .arrowUp:
            return "\u{2191}"
        case .arrowDown:
            return "\u{2193}"
        case .arrowLeft:
            return "\u{2190}"
        case .arrowRight:
            return "\u{2192}"
        case .shift, .ctrl, .alt, .dictation, .directionPad, .symbolLayer:
            return target.label
        }
    }
}
