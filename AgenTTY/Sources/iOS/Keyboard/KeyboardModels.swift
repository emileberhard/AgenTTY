import Foundation
import SwiftUI

enum ModifierTapBehavior {
    case oneShot
    case shiftTap
    case oneShotWithSlideLock
}

struct ModifierPolicy {
    let tapBehavior: ModifierTapBehavior
    let quickTapThreshold: TimeInterval
    let consumesAfterChordOutput: Bool
}

enum ModifierKey: Hashable {
    case shift
    case ctrl
    case alt

    var policy: ModifierPolicy {
        switch self {
        case .shift:
            return ModifierPolicy(
                tapBehavior: .shiftTap,
                quickTapThreshold: 0.3,
                consumesAfterChordOutput: true
            )
        case .ctrl:
            return ModifierPolicy(
                tapBehavior: .oneShotWithSlideLock,
                quickTapThreshold: 0.3,
                consumesAfterChordOutput: true
            )
        case .alt:
            return ModifierPolicy(
                tapBehavior: .oneShotWithSlideLock,
                quickTapThreshold: 0.3,
                consumesAfterChordOutput: true
            )
        }
    }
}

enum KeyAction: Hashable {
    case character(String)
    case backspace
    case enter
    case space
    case dictation
    case shift
    case ctrl
    case alt
    case symbolLayer
    case directionPad
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case escape
    case tab

    var supportsRepeat: Bool {
        repeatBehavior != nil
    }

    var isChordModifier: Bool {
        modifierKey != nil
    }

    var modifierKey: ModifierKey? {
        switch self {
        case .shift:
            return .shift
        case .ctrl:
            return .ctrl
        case .alt:
            return .alt
        default:
            return nil
        }
    }

    var supportsModifierSlideChordTarget: Bool {
        switch self {
        case .shift, .ctrl, .alt, .dictation, .directionPad, .symbolLayer:
            return false
        case .character, .backspace, .enter, .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .escape, .tab:
            return true
        case .space:
            return false
        }
    }
}

struct KeyDefinition: Hashable, Identifiable {
    let id: String
    let action: KeyAction
    let label: String
    let widthWeight: CGFloat
    let style: KeyStyle

    enum KeyStyle: Hashable {
        case character
        case modifier
        case action
        case space
    }
}

enum KeyboardLayer {
    case letters
    case symbols
}

enum ShiftState {
    case lowercase
    case shifted
    case capsLock
}
