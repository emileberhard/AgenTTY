import Foundation
import XCTest
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import AgenTTY_iOS

/// Acceptance coverage for RSA key import and the RFC 8332 user-auth ladder.
///
/// Every RSA fixture below is the *same* 2048-bit key in a different container, generated locally with
/// OpenSSH 10.2p1 / OpenSSL 3.6.3:
///
///     ssh-keygen -t rsa -b 2048 -N '' -C agentty-fixture-rsa -f openssh
///     cp openssh pkcs1 && ssh-keygen -p -m PEM -P '' -N '' -f pkcs1
///     openssl pkcs8 -topk8 -nocrypt -in pkcs1 -out pkcs8.pem
///     cp openssh encrypted && ssh-keygen -p -P '' -N 'correct horse' -f encrypted
///     ssh-keygen -y -f openssh                      # the expected public key
///
/// The sub-minimum fixture is a separate key: `ssh-keygen -t rsa -b 1024 -N '' -f small`.
final class SSHKeyImportRSATests: XCTestCase {
    private static let fixturePassphrase = "correct horse"

    // MARK: - Import acceptance

    @MainActor
    func testEveryRSAContainerFormatProducesIdenticalStoredMaterial() throws {
        let openSSH = try AgenTTYSSHPrivateKeyParser.parse(Self.opensshPlaintextKey)
        let pkcs1 = try AgenTTYSSHPrivateKeyParser.parse(Self.pkcs1PEMKey)
        let pkcs8 = try AgenTTYSSHPrivateKeyParser.parse(Self.pkcs8PEMKey)
        let encrypted = try AgenTTYSSHPrivateKeyParser.parse(
            Self.opensshEncryptedKey,
            passphrase: Self.fixturePassphrase
        )

        for material in [openSSH, pkcs1, pkcs8, encrypted] {
            XCTAssertEqual(material.kind, .rsa)
            XCTAssertEqual(material.sshKeyType, .rsa)
        }

        // The stored payload is PKCS#1 DER, so the four containers must converge byte for byte.
        XCTAssertEqual(pkcs1.rawRepresentation, openSSH.rawRepresentation)
        XCTAssertEqual(pkcs8.rawRepresentation, openSSH.rawRepresentation)
        XCTAssertEqual(encrypted.rawRepresentation, openSSH.rawRepresentation)
    }

    @MainActor
    func testImportedRSAKeyReproducesSSHKeygenPublicKey() throws {
        for (label, text) in [
            ("openssh-key-v1", Self.opensshPlaintextKey),
            ("pkcs#1", Self.pkcs1PEMKey),
            ("pkcs#8", Self.pkcs8PEMKey),
        ] {
            let material = try AgenTTYSSHPrivateKeyParser.parse(text)
            XCTAssertEqual(try material.openSSHPublicKey(), Self.rsaPublicKey, label)
        }
    }

    /// Guards the mpint round-trip that a wrong encoding would break: an OpenSSH `ssh-rsa` blob pads
    /// the modulus with a leading `0x00` because its high bit is set. A regenerated fixture that lost
    /// that property would silently stop covering the case.
    @MainActor
    func testRSAFixtureModulusExercisesTheSignBitPadding() throws {
        let blob = try XCTUnwrap(Data(base64Encoded: Self.rsaPublicKeyBase64))
        var reader = SSHBinaryReader(data: blob)

        XCTAssertEqual(try reader.readStringUTF8(), "ssh-rsa")
        let publicExponent = try reader.readStringData()
        let modulus = try reader.readStringData()

        XCTAssertEqual(Array(publicExponent), [0x01, 0x00, 0x01])
        XCTAssertEqual(modulus.first, 0x00, "modulus must carry the sign-bit pad byte")
        XCTAssertEqual(modulus.count, 257)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(modulus.dropFirst().first), 0x80)
    }

    @MainActor
    func testStoredRSAMaterialRoundTripsThroughKeychainPayload() throws {
        let material = try AgenTTYSSHPrivateKeyParser.parse(Self.opensshPlaintextKey)
        let payload = material.encodePayload()

        XCTAssertEqual(payload.first, 5, "RSA must keep storage tag 5")

        let decoded = try XCTUnwrap(AgenTTYStoredSSHPrivateKey.decodePayload(payload))
        XCTAssertEqual(decoded.kind, .rsa)
        XCTAssertEqual(decoded.rawRepresentation, material.rawRepresentation)
        XCTAssertEqual(try decoded.openSSHPublicKey(), Self.rsaPublicKey)
    }

    // MARK: - Negatives

    @MainActor
    func testSubMinimumRSAKeyIsRejectedWithAnActionableError() {
        XCTAssertThrowsError(try AgenTTYSSHPrivateKeyParser.parse(Self.openssh1024BitKey)) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .rsaKeyTooSmall)
        }
    }

    @MainActor
    func testEncryptedRSAKeyWithWrongPassphraseReportsIncorrectPassphrase() {
        XCTAssertThrowsError(
            try AgenTTYSSHPrivateKeyParser.parse(Self.opensshEncryptedKey, passphrase: "wrong horse")
        ) { error in
            XCTAssertEqual(error as? AgenTTYSSHKeyMaterialError, .privateKeyPassphraseIncorrect)
        }
    }

    // MARK: - User-auth ladder

    @MainActor
    func testRSAKeyOffersEverySignatureAlgorithmInPreferenceOrder() throws {
        let privateKey = try AgenTTYSSHPrivateKeyParser.parse(Self.opensshPlaintextKey).makeNIOSSHPrivateKey()
        let outcome = try Self.drainPublicKeyOffers(for: privateKey)

        XCTAssertEqual(outcome.signatureAlgorithms, ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])

        let rejection = try XCTUnwrap(outcome.finalError as? AgenTTYSSHAuthenticationError)
        guard case .publicKeyAuthenticationRejected(let attempted) = rejection else {
            return XCTFail("Expected a public-key rejection, got \(rejection)")
        }
        XCTAssertEqual(attempted, ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
        XCTAssertTrue(
            rejection.localizedDescription.contains("rsa-sha2-512, rsa-sha2-256, ssh-rsa"),
            rejection.localizedDescription
        )
    }

    /// The ladder must not change anything for keys that have a single signature algorithm.
    @MainActor
    func testEd25519KeyOffersExactlyOneSignatureAlgorithm() throws {
        let privateKey = try AgenTTYSSHPrivateKeyParser.parse(Self.ed25519PlaintextKey).makeNIOSSHPrivateKey()
        let outcome = try Self.drainPublicKeyOffers(for: privateKey)

        XCTAssertEqual(outcome.signatureAlgorithms, ["ssh-ed25519"])
    }

    /// Drives the delegate exactly as NIOSSH does: ask for an offer, and on every
    /// `SSH_MSG_USERAUTH_FAILURE` ask again until it refuses.
    @MainActor
    private static func drainPublicKeyOffers(
        for privateKey: NIOSSHPrivateKey,
        maximumAttempts: Int = 8
    ) throws -> (signatureAlgorithms: [String], finalError: Error?) {
        // `EmbeddedEventLoop` completes promises inline, so every offer is available synchronously.
        let loop = EmbeddedEventLoop()

        let delegate = AgenTTYSSHAuthenticationDelegate(
            authentication: .privateKey(username: "developer", privateKey: privateKey),
            failureRecorder: AgenTTYSSHFailureRecorder()
        )

        var signatureAlgorithms: [String] = []
        var finalError: Error?

        for _ in 0..<maximumAttempts {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)

            let result = Result<NIOSSHUserAuthenticationOffer?, Error> {
                try promise.futureResult.wait()
            }

            switch result {
            case .failure(let error):
                finalError = error
                return (signatureAlgorithms, finalError)
            case .success(let offer):
                guard let offer, case .privateKey(let request) = offer.offer else {
                    return (signatureAlgorithms, finalError)
                }
                signatureAlgorithms.append(try XCTUnwrap(request.signatureAlgorithm))
            }
        }

        return (signatureAlgorithms, finalError)
    }

    // MARK: - Fixtures

    /// `String(openSSHPublicKey:)` emits only "<algorithm> <base64>", so the fixture drops
    /// `ssh-keygen`'s trailing comment.
    private static let rsaPublicKeyBase64 =
        "AAAAB3NzaC1yc2EAAAADAQABAAABAQCy3r/SReRZe4UrwuCgii3zwO0IMJK5oq8qSKNmVIsszSP9Z/e9F5QWTg5QjdG0GUVM"
        + "/WBIbuNWAlroYVDPjiyHmZn1vTmz/U1+FtNuxvzW+bgCElYGcD0Fm7/YkjjJccJgud58LWMoY01wH6QTacbRMYQ4IQq0CUi"
        + "reI6cZ1bAY+Ytnh26R94UJAC+JDhZvdr861CIMOFVPZ+ETHCe7HkvfCuq9eQ2TaZsjYiSWAYsKwzuyBXXJMVneZ5s88/4Tm"
        + "Tc/v0kagu3aht52LRW+3QdCjEioR3mZnboebNJbE5j8vc/0K2vpUcoBC4Kaka3jQfCmZ/CbLCBLml8IQ8T5pB7"

    private static let rsaPublicKey = "ssh-rsa " + rsaPublicKeyBase64

    private static let opensshPlaintextKey = [
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn",
        "NhAAAAAwEAAQAAAQEAst6/0kXkWXuFK8LgoIot88DtCDCSuaKvKkijZlSLLM0j/Wf3vReU",
        "Fk4OUI3RtBlFTP1gSG7jVgJa6GFQz44sh5mZ9b05s/1NfhbTbsb81vm4AhJWBnA9BZu/2J",
        "I4yXHCYLnefC1jKGNNcB+kE2nG0TGEOCEKtAlIq3iOnGdWwGPmLZ4dukfeFCQAviQ4Wb3a",
        "/OtQiDDhVT2fhExwnux5L3wrqvXkNk2mbI2IklgGLCsM7sgV1yTFZ3mebPPP+E5k3P79JG",
        "oLt2obedi0Vvt0HQoxIqEd5mZ26HmzSWxOY/L3P9Ctr6VHKAQuCmpGt40HwpmfwmywgS5p",
        "fCEPE+aQewAAA9CMB30NjAd9DQAAAAdzc2gtcnNhAAABAQCy3r/SReRZe4UrwuCgii3zwO",
        "0IMJK5oq8qSKNmVIsszSP9Z/e9F5QWTg5QjdG0GUVM/WBIbuNWAlroYVDPjiyHmZn1vTmz",
        "/U1+FtNuxvzW+bgCElYGcD0Fm7/YkjjJccJgud58LWMoY01wH6QTacbRMYQ4IQq0CUireI",
        "6cZ1bAY+Ytnh26R94UJAC+JDhZvdr861CIMOFVPZ+ETHCe7HkvfCuq9eQ2TaZsjYiSWAYs",
        "KwzuyBXXJMVneZ5s88/4TmTc/v0kagu3aht52LRW+3QdCjEioR3mZnboebNJbE5j8vc/0K",
        "2vpUcoBC4Kaka3jQfCmZ/CbLCBLml8IQ8T5pB7AAAAAwEAAQAAAQEAqyg4l0XnzrRCZvCQ",
        "Ly5p8EAg0GBiVh3UzXo6WPX3QwR9NsNgrOE+A+XnDq/WBSbVSGl/02/AO5H/WTOdty4NcC",
        "fLyfiqmY99snS3Ft50HGVR7TGMfZay3YX+moa4rhIb9KCGw35OztvOwsaUIztpUs21/lun",
        "uUTU87dlh0XfHjIe68DTp5aqY1pDBtzX0fDf7FMy33fhtAXp/MUItMowhtTHFQCl8scnFq",
        "0itjIJJAuId0N775NHHNL29mbCI4NJemQFso7LjKxH91e/HJVfCNepTrOSOPq20iBKBrHa",
        "8U68pK2Vfaa3RK/O0pab33Bn7PTYHFoLnWnblABCcfgFOQAAAIEA3E71h3i721fza/E45/",
        "BROSCV7OL0XgZyNHjuh0Knx6VOhy+qc9x0i+mZVcaCB7XfE9EDDSGbmPlPHxx7zpDKvSHL",
        "cLITypllqTMMySUVMiLWUnGJvL/tgSe6+XIt1GJGeNYXhSPEuSN2iDKux3kHgQWSJAmNCk",
        "TO5NkoUNea1goAAACBAOZ/4B1KOjg8pMl+nnkLeitPXYfw9X0ITNivx1SrpNK/drcrtxiR",
        "If7qLcd0qBmvqw6UfKOpeqUWDYMU0zkPtqpMpuoldttZ2SUZnUnMA68gPL9MW02WUthWSU",
        "HFgKBhojeay+WHFwhVck/2G5F3aoQywgk06bdw7dVPov0m1MiHAAAAgQDGqKUAI1Suvro7",
        "HAH3Zn5dVrqIMv5/JDrp7zezQR67l3AepRJ9yp3F9pw26kn9SdUzGp3LuLqBYGAJXE8CoQ",
        "ijjb7mnaC7VJkrTKBZ7DufIM4KQeSJ8gKleHy08P5wYhoWgR1ZFI5W8VZQY1M/6C6qSdVB",
        "wp3WjwcX0Vho5IgZbQAAABNhZ2VudHR5LWZpeHR1cmUtcnNhAQIDBAUG",
        "-----END OPENSSH " + "PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let pkcs1PEMKey = [
        "-----BEGIN RSA " + "PRIVATE KEY-----",
        "MIIEpAIBAAKCAQEAst6/0kXkWXuFK8LgoIot88DtCDCSuaKvKkijZlSLLM0j/Wf3",
        "vReUFk4OUI3RtBlFTP1gSG7jVgJa6GFQz44sh5mZ9b05s/1NfhbTbsb81vm4AhJW",
        "BnA9BZu/2JI4yXHCYLnefC1jKGNNcB+kE2nG0TGEOCEKtAlIq3iOnGdWwGPmLZ4d",
        "ukfeFCQAviQ4Wb3a/OtQiDDhVT2fhExwnux5L3wrqvXkNk2mbI2IklgGLCsM7sgV",
        "1yTFZ3mebPPP+E5k3P79JGoLt2obedi0Vvt0HQoxIqEd5mZ26HmzSWxOY/L3P9Ct",
        "r6VHKAQuCmpGt40HwpmfwmywgS5pfCEPE+aQewIDAQABAoIBAQCrKDiXRefOtEJm",
        "8JAvLmnwQCDQYGJWHdTNejpY9fdDBH02w2Cs4T4D5ecOr9YFJtVIaX/Tb8A7kf9Z",
        "M523Lg1wJ8vJ+KqZj32ydLcW3nQcZVHtMYx9lrLdhf6ahriuEhv0oIbDfk7O287C",
        "xpQjO2lSzbX+W6e5RNTzt2WHRd8eMh7rwNOnlqpjWkMG3NfR8N/sUzLfd+G0Ben8",
        "xQi0yjCG1McVAKXyxycWrSK2MgkkC4h3Q3vvk0cc0vb2ZsIjg0l6ZAWyjsuMrEf3",
        "V78clV8I16lOs5I4+rbSIEoGsdrxTrykrZV9prdEr87SlpvfcGfs9NgcWgudaduU",
        "AEJx+AU5AoGBAOZ/4B1KOjg8pMl+nnkLeitPXYfw9X0ITNivx1SrpNK/drcrtxiR",
        "If7qLcd0qBmvqw6UfKOpeqUWDYMU0zkPtqpMpuoldttZ2SUZnUnMA68gPL9MW02W",
        "UthWSUHFgKBhojeay+WHFwhVck/2G5F3aoQywgk06bdw7dVPov0m1MiHAoGBAMao",
        "pQAjVK6+ujscAfdmfl1Wuogy/n8kOunvN7NBHruXcB6lEn3KncX2nDbqSf1J1TMa",
        "ncu4uoFgYAlcTwKhCKONvuadoLtUmStMoFnsO58gzgpB5InyAqV4fLTw/nBiGhaB",
        "HVkUjlbxVlBjUz/oLqpJ1UHCndaPBxfRWGjkiBltAoGAFneYbMJzck/W8Bz7bWkE",
        "+3u87ic6hnlspCJeF46zfidTdv831Zkv6x0AYVSpnfdVgRJQI9O9NKI1pvU8sW8q",
        "qubVzjTgpPjZBZi9kBfmtAc8ZJkYvTNN1/BxK4wIwZlCqpDYFwNX52QMxGaEwWUW",
        "aNRZvXP+4/aJ+CTPCkXir7kCgYBww/ANWQDLxIYP4YEYPzzBnOZ7Q38FCrrKabjT",
        "bsaUM404R/lsICRY5/iaj3l6Znu364bgyjZMFDnPdm9/DYvK0z4myBkh3Q6o7nEj",
        "Oh5J4KQ0XFzvFMn9xZv8VcQIZRdr6NSQ6UM3BP062na6EwDSNuDv2BoiXcPn+DRY",
        "Lkk3LQKBgQDcTvWHeLvbV/Nr8Tjn8FE5IJXs4vReBnI0eO6HQqfHpU6HL6pz3HSL",
        "6ZlVxoIHtd8T0QMNIZuY+U8fHHvOkMq9IctwshPKmWWpMwzJJRUyItZScYm8v+2B",
        "J7r5ci3UYkZ41heFI8S5I3aIMq7HeQeBBZIkCY0KRM7k2ShQ15rWCg==",
        "-----END RSA " + "PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let pkcs8PEMKey = [
        "-----BEGIN " + "PRIVATE KEY-----",
        "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCy3r/SReRZe4Ur",
        "wuCgii3zwO0IMJK5oq8qSKNmVIsszSP9Z/e9F5QWTg5QjdG0GUVM/WBIbuNWAlro",
        "YVDPjiyHmZn1vTmz/U1+FtNuxvzW+bgCElYGcD0Fm7/YkjjJccJgud58LWMoY01w",
        "H6QTacbRMYQ4IQq0CUireI6cZ1bAY+Ytnh26R94UJAC+JDhZvdr861CIMOFVPZ+E",
        "THCe7HkvfCuq9eQ2TaZsjYiSWAYsKwzuyBXXJMVneZ5s88/4TmTc/v0kagu3aht5",
        "2LRW+3QdCjEioR3mZnboebNJbE5j8vc/0K2vpUcoBC4Kaka3jQfCmZ/CbLCBLml8",
        "IQ8T5pB7AgMBAAECggEBAKsoOJdF5860QmbwkC8uafBAINBgYlYd1M16Olj190ME",
        "fTbDYKzhPgPl5w6v1gUm1Uhpf9NvwDuR/1kznbcuDXAny8n4qpmPfbJ0txbedBxl",
        "Ue0xjH2Wst2F/pqGuK4SG/SghsN+Ts7bzsLGlCM7aVLNtf5bp7lE1PO3ZYdF3x4y",
        "HuvA06eWqmNaQwbc19Hw3+xTMt934bQF6fzFCLTKMIbUxxUApfLHJxatIrYyCSQL",
        "iHdDe++TRxzS9vZmwiODSXpkBbKOy4ysR/dXvxyVXwjXqU6zkjj6ttIgSgax2vFO",
        "vKStlX2mt0SvztKWm99wZ+z02BxaC51p25QAQnH4BTkCgYEA5n/gHUo6ODykyX6e",
        "eQt6K09dh/D1fQhM2K/HVKuk0r92tyu3GJEh/uotx3SoGa+rDpR8o6l6pRYNgxTT",
        "OQ+2qkym6iV221nZJRmdScwDryA8v0xbTZZS2FZJQcWAoGGiN5rL5YcXCFVyT/Yb",
        "kXdqhDLCCTTpt3Dt1U+i/SbUyIcCgYEAxqilACNUrr66OxwB92Z+XVa6iDL+fyQ6",
        "6e83s0Eeu5dwHqUSfcqdxfacNupJ/UnVMxqdy7i6gWBgCVxPAqEIo42+5p2gu1SZ",
        "K0ygWew7nyDOCkHkifICpXh8tPD+cGIaFoEdWRSOVvFWUGNTP+guqknVQcKd1o8H",
        "F9FYaOSIGW0CgYAWd5hswnNyT9bwHPttaQT7e7zuJzqGeWykIl4XjrN+J1N2/zfV",
        "mS/rHQBhVKmd91WBElAj0700ojWm9Tyxbyqq5tXONOCk+NkFmL2QF+a0BzxkmRi9",
        "M03X8HErjAjBmUKqkNgXA1fnZAzEZoTBZRZo1Fm9c/7j9on4JM8KReKvuQKBgHDD",
        "8A1ZAMvEhg/hgRg/PMGc5ntDfwUKusppuNNuxpQzjThH+WwgJFjn+JqPeXpme7fr",
        "huDKNkwUOc92b38Ni8rTPibIGSHdDqjucSM6HkngpDRcXO8Uyf3Fm/xVxAhlF2vo",
        "1JDpQzcE/TradroTANI24O/YGiJdw+f4NFguSTctAoGBANxO9Yd4u9tX82vxOOfw",
        "UTkglezi9F4GcjR47odCp8elTocvqnPcdIvpmVXGgge13xPRAw0hm5j5Tx8ce86Q",
        "yr0hy3CyE8qZZakzDMklFTIi1lJxiby/7YEnuvlyLdRiRnjWF4UjxLkjdogyrsd5",
        "B4EFkiQJjQpEzuTZKFDXmtYK",
        "-----END " + "PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let opensshEncryptedKey = [
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
        "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",
        "08eOzgSbQu/zuvD4Fiz3PWh2aYg+U=",
        "-----END OPENSSH " + "PRIVATE KEY-----",
    ].joined(separator: "\n")

    private static let openssh1024BitKey = [
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn",
        "NhAAAAAwEAAQAAAIEA16TS+GE25Php/y7IuKu2QWRUoWtDnTbx4Njqk00N6DyqgohurvPJ",
        "IszIvrtyhtOJ34qPjMRpWDbxxp+cDAwxy6mJ1EqiMNQ3Ku69OnF9MLhp8qaj1O6kAAmktE",
        "S555S0OUNe7gZ7NwcTyO+pkudntOSobFWMrBJkfDw2YH+g+SkAAAIQbY1JgW2NSYEAAAAH",
        "c3NoLXJzYQAAAIEA16TS+GE25Php/y7IuKu2QWRUoWtDnTbx4Njqk00N6DyqgohurvPJIs",
        "zIvrtyhtOJ34qPjMRpWDbxxp+cDAwxy6mJ1EqiMNQ3Ku69OnF9MLhp8qaj1O6kAAmktES5",
        "55S0OUNe7gZ7NwcTyO+pkudntOSobFWMrBJkfDw2YH+g+SkAAAADAQABAAAAgQCYphyRpn",
        "9tZkviUAPWdfb2I0elXIDocVSXjfW/f/QwSYGKFXoEbp4a/Eu+eIKB3oziqPsk8oR/5aUQ",
        "rTuRa7By5lNgw2cVIwFmUHk+bg0NiGYCf+RewyHLQQasm3NZfZaAEQueUNBMOaWMW8/aBy",
        "kDvunHVEvVH0HgCaPFuy0JgQAAAEEA0miBRCxYrFyWDO6Hdn9N++T6qY9u5ALYpBzDIvCH",
        "44DsEe1MfI/xhqWHqdAy7yvroWRSGTDsy2ja/3NY8l91bQAAAEEA6wtWgXGqE4J1NpOsog",
        "v6lcFp/5H/Q9h7Q6iTJDzz+FC71czbHmjdq9z2pddpTTR068Y6kQShgzUUHLvKKYFilQAA",
        "AEEA6t6whA75CLchbJZsQ3tND5yv0kAP/HYP0PdrPEzOQjMH9ZAL84NVdfThBoUYp+mkqy",
        "gsvuhQmesHeA7U2jELRQAAABhhZ2VudHR5LWZpeHR1cmUtcnNhLTEwMjQB",
        "-----END OPENSSH " + "PRIVATE KEY-----",
    ].joined(separator: "\n")

    /// Shared with `SSHKeyImportDecryptionTests`; kept local so this file stands on its own.
    private static let ed25519PlaintextKey = [
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
        "QyNTUxOQAAACBXZLTHhM8UgAM9ymCsM4LSxwbbGPXLKj73QWA4vB4ffQAAAKCZKug1mSro",
        "NQAAAAtzc2gtZWQyNTUxOQAAACBXZLTHhM8UgAM9ymCsM4LSxwbbGPXLKj73QWA4vB4ffQ",
        "AAAEDJ0RZgZlOsAnysle6poDCnncfWBNUYzU/gZZ19+pwziFdktMeEzxSAAz3KYKwzgtLH",
        "BtsY9csqPvdBYDi8Hh99AAAAF2FnZW50dHktZml4dHVyZS1lZDI1NTE5AQIDBAUG",
        "-----END OPENSSH " + "PRIVATE KEY-----",
    ].joined(separator: "\n")
}
