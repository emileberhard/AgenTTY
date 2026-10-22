import Foundation
import XCTest
@testable import AgenTTY_iOS

/// Coverage for passphrase-protected `openssh-key-v1` import.
///
/// Fixtures were generated locally with the system `ssh-keygen` (OpenSSH); each encrypted key is
/// the *same* key as its plaintext sibling, re-encrypted in place with
/// `ssh-keygen -p -P '' -N 'correct horse'`, so a successful import must produce byte-identical
/// stored material. The `aes256-cbc` fixture additionally passed `-Z aes256-cbc`.
final class SSHKeyImportDecryptionTests: XCTestCase {
    private static let fixturePassphrase = "correct horse"

    // MARK: - bcrypt_pbkdf known-answer vectors

    /// Published OpenBSD regress vectors, transcribed from
    /// `regress/lib/libutil/bcrypt_pbkdf/bcrypt_pbkdf_test.c` (`$OpenBSD: ...,v 1.7 2014/08/10`).
    /// Every vector was independently re-derived with the Python `bcrypt` 5.0.0 `kdf()` reference
    /// before being committed.
    func testBcryptPBKDFMatchesOpenBSDRegressVectors() throws {
        let vectors: [(rounds: Int, passwordHex: String, saltHex: String, expectedHex: String)] = [
            (
                rounds: 4,
                passwordHex: "70617373776f7264",
                saltHex: "73616c74",
                expectedHex: "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"
            ),
            (
                rounds: 4,
                passwordHex: "70617373776f7264",
                saltHex: "00",
                expectedHex: "c12b566235eee04c212598970a579a67"
            ),
            (
                rounds: 4,
                passwordHex: "00",
                saltHex: "73616c74",
                expectedHex: "6051be18c2f4f82cbf0efee5471b4bb9"
            ),
            (
                rounds: 4,
                passwordHex: "70617373776f726400",
                saltHex: "73616c7400",
                expectedHex: "7410e44cf4fa07bfaac8a928b1727fac001375e7bf7384370f48efd121743050"
            ),
            (
                rounds: 4,
                passwordHex: "7061737300776f72",
                saltHex: "7361006c",
                expectedHex: "c2bffd9db38f6569efef4372f4de83c0"
            ),
            (
                rounds: 4,
                passwordHex: "7061737300776f7264",
                saltHex: "7361006c74",
                expectedHex: "4ba4ac3925c0e8d7f0cdb6bb1684a56f"
            ),
            (
                rounds: 8,
                passwordHex: "70617373776f7264",
                saltHex: "73616c74",
                expectedHex: "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246"
                    + "e74bba51723fefa9f9474d6508845e8d"
            ),
            (
                rounds: 42,
                passwordHex: "70617373776f7264",
                saltHex: "73616c74",
                expectedHex: "833cf0dcf56db65608e8f0dc0ce882bd"
            ),
            (
                rounds: 8,
                passwordHex: "4c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963"
                    + "696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61"
                    + "626f726520657420646f6c6f7265206d61676e6120616c697175612e20557420656e696d206164206d696e696d207665"
                    + "6e69616d2c2071756973206e6f737472756420657865726369746174696f6e20756c6c616d636f206c61626f72697320"
                    + "6e69736920757420616c697175697020657820656120636f6d6d6f646f20636f6e7365717561742e2044756973206175"
                    + "746520697275726520646f6c6f7220696e20726570726568656e646572697420696e20766f6c7570746174652076656c"
                    + "697420657373652063696c6c756d20646f6c6f726520657520667567696174206e756c6c612070617269617475722e20"
                    + "4578636570746575722073696e74206f6363616563617420637570696461746174206e6f6e2070726f6964656e742c20"
                    + "73756e7420696e2063756c706120717569206f666669636961206465736572756e74206d6f6c6c697420616e696d2069"
                    + "6420657374206c61626f72756d2e",
                saltHex: "73616c697300",
                expectedHex: "10978b07253df57f71a162eb0e8ad30a"
            ),
            (
                rounds: 8,
                passwordHex: "0db3ac94b3ee53284f4a22893b3c24ae",
                saltHex: "3a62f0f0dbcef823cfcc854856ea1028",
                expectedHex: "204438175eee7ce136c91b49a67923ff"
            ),
            (
                rounds: 8,
                passwordHex: "0db3ac94b3ee53284f4a22893b3c24ae",
                saltHex: "3a62f0f0dbcef823cfcc854856ea1028",
                expectedHex: "2054b9fff34e3721440334746828e9ed38de4b72e0a69adc170a13b5e8d646385ea4034ae6d26600ee2332c5ed40ad55"
                    + "7c86e3403fbb30e4e1dc1ae06b99a071368f518d2c426651c9e7e437fd6c915b1bbfc3a4cea71491490ea7afb7dd0290"
                    + "a678a4f441128db1792eab2776b21eb4238e0715add4127dff44e4b3e4cc4c4f9970083f3f74bd698873fdf648844f75"
                    + "c9bf7f9e0c4d9e5d89a7783997492966616707611cb901de31a19726b6e08c3a8001661f2d5c9dcc33b4aa072f90dd0b"
                    + "3f548d5eeba4211397e2fb062e526e1d68f46a4ce256185b4badc2685fbe78e1c7657b59f83ab9ab80cf9318d6add1f5"
                    + "933f12d6f36182c8e8115f68030a1244"
            ),
        ]

        for (index, vector) in vectors.enumerated() {
            let derived = try BcryptPBKDF.derive(
                passphrase: Self.bytes(vector.passwordHex),
                salt: Self.bytes(vector.saltHex),
                rounds: vector.rounds,
                outputByteCount: vector.expectedHex.count / 2
            )
            XCTAssertEqual(Self.hex(derived), vector.expectedHex, "OpenBSD vector \(index)")
        }
    }

    func testBcryptPBKDFRejectsDegenerateParameters() {
        XCTAssertThrowsError(
            try BcryptPBKDF.derive(passphrase: [1], salt: [2], rounds: 0, outputByteCount: 32)
        ) { XCTAssertEqual($0 as? BcryptPBKDFError, .invalidRounds) }

        XCTAssertThrowsError(
            try BcryptPBKDF.derive(passphrase: [], salt: [2], rounds: 4, outputByteCount: 32)
        ) { XCTAssertEqual($0 as? BcryptPBKDFError, .invalidPassphrase) }

        XCTAssertThrowsError(
            try BcryptPBKDF.derive(passphrase: [1], salt: [], rounds: 4, outputByteCount: 32)
        ) { XCTAssertEqual($0 as? BcryptPBKDFError, .invalidSalt) }

        XCTAssertThrowsError(
            try BcryptPBKDF.derive(passphrase: [1], salt: [2], rounds: 4, outputByteCount: 0)
        ) { XCTAssertEqual($0 as? BcryptPBKDFError, .invalidOutputLength) }
    }

    // MARK: - Encrypted round-trips

    @MainActor
    func testEncryptedEd25519KeyImportsToSameMaterialAsPlaintextKey() throws {
        let plaintext = try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519PlaintextKey)
        let encrypted = try AgenTTYSSHPrivateKeyParser.parse(
            Self.ed25519EncryptedKey,
            passphrase: Self.fixturePassphrase
        )

        XCTAssertEqual(plaintext.kind, .ed25519)
        XCTAssertEqual(encrypted.kind, plaintext.kind)
        XCTAssertEqual(encrypted.rawRepresentation, plaintext.rawRepresentation)
        XCTAssertEqual(try encrypted.openSSHPublicKey(), Self.ed25519PublicKey)
    }

    @MainActor
    func testEncryptedECDSAP256KeyImportsToSameMaterialAsPlaintextKey() throws {
        let plaintext = try AgenTTYSSHPrivateKeyParser.parse(Self.ecdsaPlaintextKey)
        let encrypted = try AgenTTYSSHPrivateKeyParser.parse(
            Self.ecdsaEncryptedKey,
            passphrase: Self.fixturePassphrase
        )

        XCTAssertEqual(plaintext.kind, .ecdsaP256)
        XCTAssertEqual(encrypted.kind, plaintext.kind)
        XCTAssertEqual(encrypted.rawRepresentation, plaintext.rawRepresentation)
        XCTAssertEqual(try encrypted.openSSHPublicKey(), Self.ecdsaPublicKey)
    }

    @MainActor
    func testPlaintextKeyIgnoresASuppliedPassphrase() throws {
        let withoutPassphrase = try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519PlaintextKey)
        let withPassphrase = try AgenTTYSSHPrivateKeyParser.parse(
            Self.ed25519PlaintextKey,
            passphrase: "unused"
        )

        XCTAssertEqual(withPassphrase.rawRepresentation, withoutPassphrase.rawRepresentation)
    }

    // MARK: - Negatives

    @MainActor
    func testEncryptedKeyWithoutPassphraseReportsPassphraseRequired() {
        XCTAssertThrowsError(try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519EncryptedKey)) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .privateKeyPassphraseRequired)
        }

        XCTAssertThrowsError(
            try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519EncryptedKey, passphrase: "")
        ) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .privateKeyPassphraseRequired)
        }
    }

    @MainActor
    func testEncryptedKeyWithWrongPassphraseReportsIncorrectPassphrase() {
        XCTAssertThrowsError(
            try AgenTTYSSHPrivateKeyParser.parse(Self.ecdsaEncryptedKey, passphrase: "wrong horse")
        ) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .privateKeyPassphraseIncorrect)
        }
    }

    @MainActor
    func testAES256CBCEncryptedKeyReportsUnsupportedCipher() {
        // The cipher is rejected before a passphrase is demanded, so both callers see the
        // actionable re-export message rather than a passphrase prompt.
        for passphrase in [nil, Self.fixturePassphrase] as [String?] {
            XCTAssertThrowsError(
                try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519CBCEncryptedKey, passphrase: passphrase)
            ) { error in
                XCTAssertEqual(
                    error as? AgenTTYSSHKeyMaterialError,
                    .unsupportedPrivateKeyCipher("aes256-cbc")
                )
            }
        }
    }

    @MainActor
    func testLegacyEncryptedPEMRemainsRejected() {
        let legacyPEM = [
            "-----BEGIN RSA " + "PRIVATE KEY-----",
            "Proc-Type: 4,ENCRYPTED",
            "DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF",
            "",
            "ZmFrZWZha2VmYWtlZmFrZQ==",
            "-----END RSA " + "PRIVATE KEY-----",
        ].joined(separator: "\n")

        XCTAssertThrowsError(try AgenTTYSSHPrivateKeyParser.parse(legacyPEM)) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .encryptedPrivateKeyNotSupported)
        }
    }

    // MARK: - Helpers

    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }

    // MARK: - Fixtures

    /// `ssh-keygen` output with the trailing comment dropped, matching
    /// `String(openSSHPublicKey:)`, which emits only "<algorithm> <base64>".
    private static let ed25519PublicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdktMeEzxSAAz3KYKwzgtLHBtsY9csqPvdBYDi8Hh99"

    private static let ecdsaPublicKey =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCm8d0e2dDCM60G3"
        + "dBjCsQXkPp6Vk8xwlA2nO6fYhcvs2xZnk2ats/6sirf3ghJGq2sl6UNzAIuM24wApZC5yL4="

    private static let ed25519PlaintextKey = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
        "QyNTUxOQAAACBXZLTHhM8UgAM9ymCsM4LSxwbbGPXLKj73QWA4vB4ffQAAAKCZKug1mSro",
        "NQAAAAtzc2gtZWQyNTUxOQAAACBXZLTHhM8UgAM9ymCsM4LSxwbbGPXLKj73QWA4vB4ffQ",
        "AAAEDJ0RZgZlOsAnysle6poDCnncfWBNUYzU/gZZ19+pwziFdktMeEzxSAAz3KYKwzgtLH",
        "BtsY9csqPvdBYDi8Hh99AAAAF2FnZW50dHktZml4dHVyZS1lZDI1NTE5AQIDBAUG",
        "-----END OPENSSH PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let ed25519EncryptedKey = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAsuJCEwo",
        "ikTJGRH90mGPfcAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFdktMeEzxSAAz3K",
        "YKwzgtLHBtsY9csqPvdBYDi8Hh99AAAAoLST9Z/ZdMxfoBLshi2yeI8ALOxvbZ+f5Oq4tj",
        "VvANh3A+0xoBm0OUsYhNUK+kL9q8Y6/8YEmpQnVlqwZsJIMsI2zgSKFREJ6tKPIz7jtrJk",
        "cE6cx1VzzBJBKhwbPZ85s8jZHdg0vMsXwLsO5Fh2dj2em83FVEZR3VZEuvgfsSrrt9y/i3",
        "KMdiqMX5z5zxMtvWoAvlmbVJEpDqokuUHU5gY=",
        "-----END OPENSSH PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let ed25519CBCEncryptedKey = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jYmMAAAAGYmNyeXB0AAAAGAAAABD51l0Yyz",
        "QiDatl6RUJYQkLAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFdktMeEzxSAAz3K",
        "YKwzgtLHBtsY9csqPvdBYDi8Hh99AAAAoKy/j0iXRX14EC5htxQFnc1ySPDU9em7A9igcb",
        "jENov6ZaoTAM09ZXqAy4d+00wTSicgYogqkZb2Afn8cyA5vVG/noU2a2YjMhbvWOObSaAp",
        "o2XakyTxIJU5O6SxeFtSyQn3w/p3+Vj8ubO4l71KeRu7PBkawast3fVw4Rdmn+Pugca2Cf",
        "sfdnOBs/2U/6Oprv1VWAsnwsORhEwUm71Cpb8=",
        "-----END OPENSSH PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let ecdsaPlaintextKey = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS",
        "1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQpvHdHtnQwjOtBt3QYwrEF5D6elZPM",
        "cJQNpzun2IXL7NsWZ5NmrbP+rIq394ISRqtrJelDcwCLjNuMAKWQuci+AAAAsEoW5ohKFu",
        "aIAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCm8d0e2dDCM60G3",
        "dBjCsQXkPp6Vk8xwlA2nO6fYhcvs2xZnk2ats/6sirf3ghJGq2sl6UNzAIuM24wApZC5yL",
        "4AAAAgQOg3VP0jH5AhACAL06Yo9y7NfCciUJZhEuuogU+lqB0AAAAVYWdlbnR0eS1maXh0",
        "dXJlLWVjZHNhAQID",
        "-----END OPENSSH PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let ecdsaEncryptedKey = [
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA0XMdEda",
        "a6pUXrg3169eCsAAAACAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz",
        "dHAyNTYAAABBBCm8d0e2dDCM60G3dBjCsQXkPp6Vk8xwlA2nO6fYhcvs2xZnk2ats/6sir",
        "f3ghJGq2sl6UNzAIuM24wApZC5yL4AAACwJJo9z0ZlqMnkmTJe/LCMUnHwt6MrDiGY1q37",
        "Xo3ORxcBRUwnrPNcRrb4zE3lCy5EixCINCZu0liQpteoTJ+X2vtl7iub6Q+AjrxjviY64u",
        "yFvGfHC15RzXRGdAuMEqzXjBB+DwVdZZfAsKsCdxqqXRN4tBIA94OkMA9u4CR5P7ylAYcg",
        "XI5ZgzhWIo280Uy+GHzd7chBnE7VeYL35Wc4cyZr/CfieOQe0BrpVf6uaqg=",
        "-----END OPENSSH PRIVATE KEY-----",
    ].joined(separator: "\n")
}
