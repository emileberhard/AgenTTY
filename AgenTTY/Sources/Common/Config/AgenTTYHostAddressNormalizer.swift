import Foundation

nonisolated enum AgenTTYHostAddressNormalizer {
    static func normalizeForStorage(_ address: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in address.unicodeScalars {
            scalars.append(unicodeDashScalars.contains(scalar.value) ? UnicodeScalar(45)! : scalar)
        }
        let dashNormalized = String(scalars)
        return dashNormalized.trimmingCharacters(in: hostAddressTrimCharacters)
    }

    static func normalizeForMatching(_ address: String) -> String {
        normalizeForStorage(address).lowercased()
    }

    static func changes(_ address: String) -> Bool {
        normalizeForStorage(address) != address
    }

    private static let unicodeDashScalars: Set<UInt32> = [
        0x2010,
        0x2011,
        0x2012,
        0x2013,
        0x2014,
        0x2015,
        0x2212,
        0xFE58,
        0xFE63,
        0xFF0D,
    ]

    private static var hostAddressTrimCharacters: CharacterSet {
        var characters = CharacterSet.whitespacesAndNewlines
        characters.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}")
        return characters
    }
}
