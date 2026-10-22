import Foundation

enum GhosttyThemeFileParser {
    struct ParsedTheme {
        let namedColorHexByKey: [String: String]
        let paletteHexByIndex: [Int: String]
    }

    static func parse(content: String) -> ParsedTheme {
        var namedColors: [String: String] = [:]
        var palette: [Int: String] = [:]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines))
            if key.isEmpty {
                continue
            }

            let rawValue = String(line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines))
            if key == "palette" {
                guard let paletteSeparator = rawValue.firstIndex(of: "=") else {
                    continue
                }
                let indexRaw = rawValue[..<paletteSeparator].trimmingCharacters(in: .whitespacesAndNewlines)
                let colorRaw = rawValue[rawValue.index(after: paletteSeparator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let index = Int(indexRaw), (0...255).contains(index), !colorRaw.isEmpty else {
                    continue
                }
                palette[index] = String(colorRaw)
                continue
            }

            namedColors[key] = rawValue
        }

        return ParsedTheme(
            namedColorHexByKey: namedColors,
            paletteHexByIndex: palette
        )
    }

    static func parseRGBComponents(hex rawValue: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6 || digits.count == 8 else {
            return nil
        }
        guard let value = UInt64(digits, radix: 16) else {
            return nil
        }

        if digits.count == 8 {
            return (
                red: Double((value >> 24) & 0xFF) / 255.0,
                green: Double((value >> 16) & 0xFF) / 255.0,
                blue: Double((value >> 8) & 0xFF) / 255.0
            )
        }

        return (
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
