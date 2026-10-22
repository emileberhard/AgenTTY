import Foundation

enum TerminalFontSizeSetting {
    static let storageKey = "terminalFontSize"
    static let defaultValue = 7.0
    static let minimumValue = 5.0
    static let maximumValue = 11.0
    static let stepValue = 0.1
    private static let precisionScale = 10

    static func clamped(_ value: Double) -> Double {
        max(minimumValue, min(maximumValue, value))
    }

    static func quantized(_ value: Double) -> Double {
        let scale = Double(precisionScale)
        let roundedToStep = (value * scale).rounded() / scale
        return clamped(roundedToStep)
    }

    static func canDecrement(_ value: Double) -> Bool {
        quantized(value) > minimumValue
    }

    static func canIncrement(_ value: Double) -> Bool {
        quantized(value) < maximumValue
    }

    static func decrement(_ value: Double) -> Double {
        quantized(value - stepValue)
    }

    static func increment(_ value: Double) -> Double {
        quantized(value + stepValue)
    }

    static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_1
    }

    static func formattedValue(_ value: Double) -> String {
        let tenths = Int((quantized(value) * Double(precisionScale)).rounded())
        let whole = tenths / precisionScale
        let fractional = abs(tenths % precisionScale)
        return "\(whole).\(fractional)"
    }

    static func persistedValue() -> Double {
        persistedValue(from: AgenTTYSharedDefaults.store)
    }

    private static func persistedValue(from userDefaults: UserDefaults) -> Double {
        guard let storedValue = userDefaults.object(forKey: storageKey) else {
            return defaultValue
        }

        if let number = storedValue as? NSNumber {
            return quantized(number.doubleValue)
        }

        return quantized(userDefaults.double(forKey: storageKey))
    }
}
