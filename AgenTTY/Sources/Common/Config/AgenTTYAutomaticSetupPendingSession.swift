import Foundation

nonisolated struct AgenTTYAutomaticSetupPendingClaim: Codable, Equatable, Sendable {
    let pairingCode: String
    let keyID: UUID
    let flowID: String
    let startedAtEpochSeconds: Int
    let expiresAtEpochSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case keyID = "key_id"
        case flowID = "flow_id"
        case startedAtEpochSeconds = "started_at_epoch_seconds"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
    }

    func isExpired(at date: Date = .init()) -> Bool {
        Int(date.timeIntervalSince1970.rounded()) >= expiresAtEpochSeconds
    }
}

nonisolated struct AgenTTYAutomaticSetupPendingSession: Codable, Equatable, Sendable {
    let sessionID: String
    let keyID: UUID
    let flowID: String
    let claimedAtEpochSeconds: Int
    let expiresAtEpochSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case keyID = "key_id"
        case flowID = "flow_id"
        case claimedAtEpochSeconds = "claimed_at_epoch_seconds"
        case expiresAtEpochSeconds = "expires_at_epoch_seconds"
    }

    func isExpired(at date: Date = .init()) -> Bool {
        Int(date.timeIntervalSince1970.rounded()) >= expiresAtEpochSeconds
    }
}

nonisolated enum AgenTTYAutomaticSetupPendingState: Equatable, Sendable, Codable {
    case claiming(AgenTTYAutomaticSetupPendingClaim)
    case claimed(AgenTTYAutomaticSetupPendingSession)

    private enum CodingKeys: String, CodingKey {
        case kind
        case claiming
        case claimed
    }

    private enum Kind: String, Codable {
        case claiming
        case claimed
    }

    var flowID: String {
        switch self {
        case .claiming(let claim):
            claim.flowID
        case .claimed(let session):
            session.flowID
        }
    }

    func isExpired(at date: Date = .init()) -> Bool {
        switch self {
        case .claiming(let claim):
            claim.isExpired(at: date)
        case .claimed(let session):
            session.isExpired(at: date)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .claiming:
            self = .claiming(try container.decode(AgenTTYAutomaticSetupPendingClaim.self, forKey: .claiming))
        case .claimed:
            self = .claimed(try container.decode(AgenTTYAutomaticSetupPendingSession.self, forKey: .claimed))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .claiming(let claim):
            try container.encode(Kind.claiming, forKey: .kind)
            try container.encode(claim, forKey: .claiming)
        case .claimed(let session):
            try container.encode(Kind.claimed, forKey: .kind)
            try container.encode(session, forKey: .claimed)
        }
    }
}

nonisolated enum AgenTTYAutomaticSetupPendingStateStore {
    private static let storageKey = "automatic_setup_pending_session"

    static func load(
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store,
        date: Date = .init()
    ) -> AgenTTYAutomaticSetupPendingState? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let state = try? decoder.decode(AgenTTYAutomaticSetupPendingState.self, from: data) {
            if state.isExpired(at: date) {
                userDefaults.removeObject(forKey: storageKey)
                return nil
            }
            return state
        }

        if let legacySession = try? decoder.decode(AgenTTYAutomaticSetupPendingSession.self, from: data) {
            if legacySession.isExpired(at: date) {
                userDefaults.removeObject(forKey: storageKey)
                return nil
            }
            return .claimed(legacySession)
        }

        userDefaults.removeObject(forKey: storageKey)
        return nil
    }

    static func save(
        _ state: AgenTTYAutomaticSetupPendingState,
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store
    ) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }

    static func saveClaiming(
        pairingCode: String,
        keyID: UUID,
        flowID: String,
        now: Date = .init(),
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store
    ) {
        let startedAtEpochSeconds = Int(now.timeIntervalSince1970.rounded())
        save(
            .claiming(
                AgenTTYAutomaticSetupPendingClaim(
                    pairingCode: pairingCode,
                    keyID: keyID,
                    flowID: flowID,
                    startedAtEpochSeconds: startedAtEpochSeconds,
                    expiresAtEpochSeconds: startedAtEpochSeconds + (10 * 60)
                )
            ),
            userDefaults: userDefaults
        )
    }

    static func saveClaimed(
        sessionID: String,
        keyID: UUID,
        flowID: String,
        claimedAtEpochSeconds: Int,
        expiresAtEpochSeconds: Int,
        userDefaults: UserDefaults = AgenTTYSharedDefaults.store
    ) {
        save(
            .claimed(
                AgenTTYAutomaticSetupPendingSession(
                    sessionID: sessionID,
                    keyID: keyID,
                    flowID: flowID,
                    claimedAtEpochSeconds: claimedAtEpochSeconds,
                    expiresAtEpochSeconds: expiresAtEpochSeconds
                )
            ),
            userDefaults: userDefaults
        )
    }

    static func clear(userDefaults: UserDefaults = AgenTTYSharedDefaults.store) {
        userDefaults.removeObject(forKey: storageKey)
    }
}
