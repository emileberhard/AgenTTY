import Foundation

nonisolated enum AgenTTYDisplayText {
    static func sanitized(_ text: String, maximumLength: Int) -> String {
        var printable = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                printable.append(" ")
            case .format:
                continue
            default:
                printable.append(scalar)
            }
        }
        let collapsed = String(printable).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }
}
