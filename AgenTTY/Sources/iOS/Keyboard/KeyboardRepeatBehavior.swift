import CoreGraphics
import Foundation

struct RepeatAccelerationCurve: Equatable {
    let rampDuration: TimeInterval
    let curveFactor: Double
    let maximumMultiplier: Double

    func multiplier(forHoldDuration holdDuration: TimeInterval) -> Double {
        let boundedDuration = max(0, min(holdDuration, rampDuration))
        let normalizedProgress = rampDuration > 0 ? boundedDuration / rampDuration : 1
        let easedProgress = Self.exponentialProgress(
            normalizedProgress,
            curveFactor: curveFactor
        )
        return 1 + (maximumMultiplier - 1) * easedProgress
    }

    private static func exponentialProgress(_ value: Double, curveFactor: Double) -> Double {
        let x = max(0, min(value, 1))
        guard curveFactor > 0 else { return x }

        let denominator = exp(curveFactor) - 1
        guard denominator > 0 else { return x }
        return (exp(curveFactor * x) - 1) / denominator
    }
}

struct DistanceScaledRepeatBaseRate: Equatable {
    let triggerDistance: CGFloat
    let maxDistanceForRateGain: CGFloat
    let minimumRatePerSecond: Double
    let maximumRatePerSecond: Double

    func rate(forDistanceFromCenter distance: CGFloat) -> Double {
        let distanceBeyondTrigger = max(distance - triggerDistance, 0)
        let normalizedDistance: CGFloat
        if maxDistanceForRateGain > 0 {
            normalizedDistance = min(distanceBeyondTrigger / maxDistanceForRateGain, 1)
        } else {
            normalizedDistance = 1
        }
        let rateRange = maximumRatePerSecond - minimumRatePerSecond
        return minimumRatePerSecond + (rateRange * Double(normalizedDistance))
    }
}

enum KeyRepeatBehavior: Equatable {
    case fixed(FixedKeyRepeatBehavior)
    case accelerated(AcceleratedKeyRepeatBehavior)

    var initialDelay: TimeInterval {
        switch self {
        case .fixed(let behavior):
            behavior.initialDelay
        case .accelerated(let behavior):
            behavior.initialDelay
        }
    }

    var hapticMinimumInterval: TimeInterval? {
        switch self {
        case .fixed(let behavior):
            behavior.hapticMinimumInterval
        case .accelerated(let behavior):
            behavior.hapticMinimumInterval
        }
    }

    func interval(forHoldDuration holdDuration: TimeInterval) -> TimeInterval {
        switch self {
        case .fixed(let behavior):
            return behavior.interval
        case .accelerated(let behavior):
            return behavior.interval(forHoldDuration: holdDuration)
        }
    }
}

struct FixedKeyRepeatBehavior: Equatable {
    let initialDelay: TimeInterval
    let interval: TimeInterval
    let hapticMinimumInterval: TimeInterval?
}

struct AcceleratedKeyRepeatBehavior: Equatable {
    let initialDelay: TimeInterval
    let baseRatePerSecond: Double
    let accelerationCurve: RepeatAccelerationCurve
    let hapticMinimumInterval: TimeInterval?

    var maximumRatePerSecond: Double {
        baseRatePerSecond * accelerationCurve.maximumMultiplier
    }

    func interval(forHoldDuration holdDuration: TimeInterval) -> TimeInterval {
        let multiplier = accelerationCurve.multiplier(forHoldDuration: holdDuration)
        let ratePerSecond = baseRatePerSecond * multiplier
        return 1 / ratePerSecond
    }
}

extension KeyRepeatBehavior {
    static let standard = KeyRepeatBehavior.fixed(
        FixedKeyRepeatBehavior(
            initialDelay: 0.45,
            interval: 0.065,
            hapticMinimumInterval: nil
        )
    )

    static let acceleratedBackspace = KeyRepeatBehavior.accelerated(
        AcceleratedKeyRepeatBehavior(
            initialDelay: 0.25,
            baseRatePerSecond: 14,
            accelerationCurve: RepeatAccelerationCurve(
                rampDuration: 10,
                curveFactor: 2.4,
                maximumMultiplier: 140.0 / 14.0
            ),
            hapticMinimumInterval: 0.045
        )
    )
}

extension KeyAction {
    var repeatBehavior: KeyRepeatBehavior? {
        switch self {
        case .backspace:
            return .acceleratedBackspace

        case .character, .space, .arrowUp, .arrowDown, .arrowLeft, .arrowRight:
            return .standard

        default:
            return nil
        }
    }
}
