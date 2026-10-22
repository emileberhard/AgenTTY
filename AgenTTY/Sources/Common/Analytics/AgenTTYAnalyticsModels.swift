import CryptoKit
import Foundation
import StoreKit

nonisolated enum AgenTTYAnalyticsEventType: String, Codable, Sendable {
    case appSessionCompleted = "app_session_completed"
    case accessStateSnapshot = "access_state_snapshot"
    case sshSessionCompleted = "ssh_session_completed"
    case purchaseFlowEvent = "purchase_flow_event"
    case hostSetupFlowEvent = "host_setup_flow_event"
    case paywallEvent = "paywall_event"
    case keyMaterialEvent = "key_material_event"
}

nonisolated enum AgenTTYAnalyticsPurchaseFlowKind: String, Codable, Sendable {
    case purchase
    case restore
}

nonisolated enum AgenTTYAnalyticsPurchaseFlowState: String, Codable, Sendable {
    case attempted
    case success
    case pending
    case cancelled
    case failed
    case notFound = "not_found"
}

nonisolated enum AgenTTYAnalyticsHostSetupMethod: String, Codable, Sendable {
    case automatic
    case manual
    case oneTimePassword = "one_time_password"
}

nonisolated enum AgenTTYAnalyticsHostSetupStage: String, Codable, Sendable {
    case screenViewed = "screen_viewed"
    case started
    case attemptStarted = "attempt_started"
    case scannerOpened = "scanner_opened"
    case pairingClaimStarted = "pairing_claim_started"
    case pairingClaimed = "pairing_claimed"
    case pairingCompleted = "pairing_completed"
    case reviewPresented = "review_presented"
    case verificationStarted = "verification_started"
    case verificationSucceeded = "verification_succeeded"
    case verificationFailed = "verification_failed"
    case saveTapped = "save_tapped"
    case saveSucceeded = "save_succeeded"
    case saveSucceededUnreachable = "save_succeeded_unreachable"
    case saveSucceededUnverified = "save_succeeded_unverified"
    case saveAnywayTapped = "save_anyway_tapped"
    case troubleshootOpened = "troubleshoot_opened"
    case failed
}

nonisolated enum AgenTTYAnalyticsHostSetupErrorCategory: String, Codable, Sendable {
    case pairing
    case reachability
    case connectionVerification = "connection_verification"
    case save
    case keyMaterial = "key_material"
    case unknown
}

nonisolated enum AgenTTYAnalyticsHostCandidateKind: String, Codable, Sendable {
    case tailscaleShort = "tailscale_short"
    case tailscaleFQDN = "tailscale_fqdn"
    case fqdn = "fqdn"
    case singleLabel = "single_label"
    case localDomain = "local_domain"
}

nonisolated enum AgenTTYAnalyticsHostCandidateSource: String, Codable, Sendable {
    case scutilHostname = "scutil_hostname"
    case scutilLocalhostname = "scutil_localhostname"
    case hostnameFQDN = "hostname_fqdn"
    case hostname = "hostname"
    case osHostname = "os_hostname"
    case envHostname = "env_hostname"
    case tailscaleShort = "tailscale_short"
    case tailscaleMagicDNS = "tailscale_magicdns"
    case legacyHostnameCandidates = "legacy_hostname_candidates"
}

nonisolated enum AgenTTYAnalyticsHostEnvironmentFlag: String, Codable, Sendable {
    case container
    case wsl
}

nonisolated enum AgenTTYAnalyticsHostPlatform: String, Codable, Sendable {
    case linux
    case macos
}

nonisolated enum AgenTTYAnalyticsReachabilityFailureSubtype: String, Codable, Sendable {
    case dns
    case timeout
    case connectionRefused = "connection_refused"
    case networkUnreachable = "network_unreachable"
    case other
}

nonisolated enum AgenTTYAnalyticsPaywallStage: String, Codable, Sendable {
    case shown
    case purchaseTapped = "purchase_tapped"
    case restoreTapped = "restore_tapped"
    case retryLookupTapped = "retry_lookup_tapped"
}

nonisolated enum AgenTTYAnalyticsSSHDisconnectCategory: String, Codable, Sendable {
    case shellClosed = "shell_closed"
    case connectTimeout = "connect_timeout"
    case networkError = "network_error"
    case authFailed = "auth_failed"
    case hostKeyMismatch = "host_key_mismatch"
    case localClose = "local_close"
    case transportClosed = "transport_closed"
    case other
}

nonisolated enum AgenTTYAnalyticsSSHAuthMode: String, Codable, Sendable {
    case key
    case passwordBootstrap = "password_bootstrap"
}

nonisolated enum AgenTTYAnalyticsSSHFailureStage: String, Codable, Sendable {
    case tcpConnect = "tcp_connect"
    case sshAuth = "ssh_auth"
    case preShellRuntime = "pre_shell_runtime"
    case shellChannel = "shell_channel"
    case ptyBootstrap = "pty_bootstrap"
    case tmuxBootstrap = "tmux_bootstrap"
    case transport = "transport"
    case postReadySession = "post_ready_session"
}

nonisolated enum AgenTTYAnalyticsKeyMaterialOperation: String, Codable, Sendable {
    case generate
    case `import`
}

nonisolated enum AgenTTYAnalyticsKeyMaterialStage: String, Codable, Sendable {
    case attempted
    case succeeded
    case failed
}

nonisolated enum AgenTTYAnalyticsKeyMaterialFailureReason: String, Codable, Sendable {
    case rsaUnsupported = "rsa_unsupported"
    case encryptedPrivateKeyUnsupported = "encrypted_private_key_unsupported"
    case unsupportedPrivateKeyFormat = "unsupported_private_key_format"
    case invalidPrivateKeyFormat = "invalid_private_key_format"
    case unsupportedPrivateKeyType = "unsupported_private_key_type"
    case keychainStoreFailed = "keychain_store_failed"
    case internalError = "internal_error"
}

nonisolated enum AgenTTYAnalyticsDeviceFamily: String, Codable, Sendable {
    case phone
    case pad
    case mac
    case tv
    case carPlay = "carplay"
    case vision
    case unspecified
}

nonisolated enum AgenTTYAnalyticsJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: AgenTTYAnalyticsJSONValue])
    case array([AgenTTYAnalyticsJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgenTTYAnalyticsJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgenTTYAnalyticsJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported analytics JSON payload."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

nonisolated enum AgenTTYAnalyticsCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

nonisolated struct AgenTTYAnalyticsAccessState: Codable, Equatable, Sendable {
    let hasFinishedInitialAccessLoad: Bool
    let hasLifetimeAccess: Bool
    let trialExpired: Bool
    let trialConsumedUsageSeconds: Double
    let trialRemainingUsageSeconds: Double
    let interactiveContentAllowed: Bool
    let gateBlocking: Bool
}

nonisolated struct AgenTTYAnalyticsContextInfo: Codable, Equatable, Sendable {
    let appSessionID: String
}

nonisolated struct AgenTTYAnalyticsAppSessionInfoPayload: Codable, Equatable, Sendable {
    let id: String
    let durationSeconds: Int
    let savedHostCount: Int
    let activeHostPresent: Bool
    let hadPaywallVisible: Bool
    let sshSessionCount: Int
    let readySSHSessionCount: Int
    let hadTerminalInput: Bool
}

nonisolated struct AgenTTYAnalyticsSSHSessionInfoPayload: Codable, Equatable, Sendable {
    let id: String
    let durationSeconds: Int
    let wasReady: Bool
}

nonisolated struct AgenTTYAnalyticsHostReferencePayload: Codable, Equatable, Sendable {
    let idHash: String?
    let keyHash: String?
    let savedHostCount: Int?
}

nonisolated struct AgenTTYAnalyticsSSHAuthPayload: Codable, Equatable, Sendable {
    let mode: AgenTTYAnalyticsSSHAuthMode
}

nonisolated struct AgenTTYAnalyticsSSHDisconnectPayload: Codable, Equatable, Sendable {
    let category: AgenTTYAnalyticsSSHDisconnectCategory
    let reason: String?
    let failureStage: AgenTTYAnalyticsSSHFailureStage?
}

nonisolated struct AgenTTYAnalyticsSSHInputPayload: Codable, Equatable, Sendable {
    let hadTerminalInput: Bool
    let eventCount: Int
}

nonisolated struct AgenTTYAnalyticsPurchaseFlowErrorPayload: Codable, Equatable, Sendable {
    let message: String
}

nonisolated struct AgenTTYAnalyticsHostSetupFlowInfoPayload: Codable, Equatable, Sendable {
    let id: String?
    let method: AgenTTYAnalyticsHostSetupMethod
    let stage: AgenTTYAnalyticsHostSetupStage
    let isEdit: Bool
    let usesTailscaleAddress: Bool
}

nonisolated struct AgenTTYAnalyticsHostSetupErrorPayload: Codable, Equatable, Sendable {
    let category: AgenTTYAnalyticsHostSetupErrorCategory
    let message: String?
}

nonisolated struct AgenTTYAnalyticsDetectedUsernamePayload: Codable, Equatable, Sendable {
    let value: String?
    let source: AgenTTYPairingDetectedUsernameSource?
    let suspicious: Bool?
}

nonisolated struct AgenTTYAnalyticsHostSetupEditsPayload: Codable, Equatable, Sendable {
    let host: Bool?
    let port: Bool?
    let username: Bool?
}

nonisolated struct AgenTTYAnalyticsSelectedCandidatePayload: Codable, Equatable, Sendable {
    let value: String
    let kind: AgenTTYAnalyticsHostCandidateKind
    let source: AgenTTYAnalyticsHostCandidateSource
    let rank: Int
}

nonisolated struct AgenTTYAnalyticsCandidateSummaryPayload: Codable, Equatable, Sendable {
    let selected: AgenTTYAnalyticsSelectedCandidatePayload?
    let allValues: [String]?
    let count: Int?
    let highConfidenceCount: Int?
    let allLowConfidence: Bool?
}

nonisolated struct AgenTTYAnalyticsHostEnvironmentPayload: Codable, Equatable, Sendable {
    let platform: AgenTTYAnalyticsHostPlatform
    let flags: [AgenTTYAnalyticsHostEnvironmentFlag]
}

nonisolated struct AgenTTYAnalyticsReachabilityPayload: Codable, Equatable, Sendable {
    let attemptCount: Int
    let failureSubtype: AgenTTYAnalyticsReachabilityFailureSubtype?
}

nonisolated struct AgenTTYAnalyticsVerificationPayload: Codable, Equatable, Sendable {
    let attemptCount: Int
    let failureStage: AgenTTYAnalyticsSSHFailureStage?
    let disconnectCategory: AgenTTYAnalyticsSSHDisconnectCategory?
}

nonisolated struct AgenTTYAnalyticsKeyPayload: Codable, Equatable, Sendable {
    let type: SSHKeyType
}

nonisolated struct AgenTTYAnalyticsKeyMaterialErrorPayload: Codable, Equatable, Sendable {
    let reason: AgenTTYAnalyticsKeyMaterialFailureReason
    let detail: String?
}

nonisolated struct AgenTTYAnalyticsAppSessionCompletedEvent: Sendable {
    let appSessionID: String
    let durationSeconds: Int
    let accessState: AgenTTYAnalyticsAccessState
    let savedHostCount: Int
    let activeHostPresent: Bool
    let hadPaywallVisible: Bool
    let sshSessionCount: Int
    let readySSHSessionCount: Int
    let hadTerminalInput: Bool
}

nonisolated struct AgenTTYAnalyticsAccessStateSnapshotEvent: Sendable {
    let reason: String
    let accessState: AgenTTYAnalyticsAccessState
}

nonisolated struct AgenTTYAnalyticsPurchaseFlowEvent: Sendable {
    let kind: AgenTTYAnalyticsPurchaseFlowKind
    let state: AgenTTYAnalyticsPurchaseFlowState
    let errorMessage: String?
}

nonisolated struct AgenTTYAnalyticsHostSetupFlowEvent: Sendable {
    let method: AgenTTYAnalyticsHostSetupMethod
    let stage: AgenTTYAnalyticsHostSetupStage
    let isEdit: Bool
    let usesTailscaleAddress: Bool
    let flowID: String?
    let savedHostCount: Int?
    let hostID: UUID?
    let errorCategory: AgenTTYAnalyticsHostSetupErrorCategory?
    let errorMessage: String?
    let detectedUsername: String?
    let detectedUsernameSource: AgenTTYPairingDetectedUsernameSource?
    let usernameSuspicious: Bool?
    let hostEdited: Bool?
    let portEdited: Bool?
    let usernameEdited: Bool?
    let selectedCandidateKind: AgenTTYAnalyticsHostCandidateKind?
    let selectedCandidateSource: AgenTTYAnalyticsHostCandidateSource?
    let selectedCandidateRank: Int?
    let selectedCandidateValue: String?
    let candidateValues: [String]?
    let candidateCount: Int?
    let highConfidenceCandidateCount: Int?
    let allLowConfidenceCandidates: Bool?
    let hostPlatform: AgenTTYAnalyticsHostPlatform?
    let hostEnvironmentFlags: [AgenTTYAnalyticsHostEnvironmentFlag]
    let probeAttemptCount: Int?
    let reachabilityFailureSubtype: AgenTTYAnalyticsReachabilityFailureSubtype?
    let verificationAttemptCount: Int?
    let verificationFailureStage: AgenTTYAnalyticsSSHFailureStage?
    let verificationDisconnectCategory: AgenTTYAnalyticsSSHDisconnectCategory?
}

nonisolated struct AgenTTYAnalyticsKeyMaterialEvent: Sendable {
    let operation: AgenTTYAnalyticsKeyMaterialOperation
    let stage: AgenTTYAnalyticsKeyMaterialStage
    let keyType: SSHKeyType?
    let failureReason: AgenTTYAnalyticsKeyMaterialFailureReason?
    let failureDetail: String?
}

nonisolated struct AgenTTYAnalyticsPaywallEvent: Sendable {
    let stage: AgenTTYAnalyticsPaywallStage
    let accessState: AgenTTYAnalyticsAccessState
}

nonisolated struct AgenTTYAnalyticsSSHSessionCompletedEvent: Sendable {
    let sessionID: String
    let hostID: UUID
    let duration: TimeInterval
    let wasReady: Bool
    let disconnectCategory: AgenTTYAnalyticsSSHDisconnectCategory
    let disconnectReason: String?
    let failureStage: AgenTTYAnalyticsSSHFailureStage?
    let hadTerminalInput: Bool
    let inputEventCount: Int
    let authMode: AgenTTYAnalyticsSSHAuthMode
    let hostKeyHash: String?
}

nonisolated struct AgenTTYAnalyticsAccessStateSnapshotPayload: Codable, Sendable {
    let context: AgenTTYAnalyticsContextInfo?
    let reason: String
    let accessState: AgenTTYAnalyticsAccessState
}

nonisolated struct AgenTTYAnalyticsAppSessionCompletedPayload: Codable, Sendable {
    let session: AgenTTYAnalyticsAppSessionInfoPayload
    let accessState: AgenTTYAnalyticsAccessState
}

nonisolated struct AgenTTYAnalyticsSSHSessionCompletedPayload: Codable, Sendable {
    let context: AgenTTYAnalyticsContextInfo?
    let session: AgenTTYAnalyticsSSHSessionInfoPayload
    let host: AgenTTYAnalyticsHostReferencePayload
    let auth: AgenTTYAnalyticsSSHAuthPayload
    let disconnect: AgenTTYAnalyticsSSHDisconnectPayload
    let input: AgenTTYAnalyticsSSHInputPayload
}

nonisolated struct AgenTTYAnalyticsPurchaseFlowPayload: Codable, Sendable {
    let kind: AgenTTYAnalyticsPurchaseFlowKind
    let state: AgenTTYAnalyticsPurchaseFlowState
    let error: AgenTTYAnalyticsPurchaseFlowErrorPayload?
}

nonisolated struct AgenTTYAnalyticsHostSetupFlowPayload: Codable, Sendable {
    let context: AgenTTYAnalyticsContextInfo?
    let flow: AgenTTYAnalyticsHostSetupFlowInfoPayload
    let host: AgenTTYAnalyticsHostReferencePayload?
    let detectedUsername: AgenTTYAnalyticsDetectedUsernamePayload?
    let edits: AgenTTYAnalyticsHostSetupEditsPayload?
    let candidates: AgenTTYAnalyticsCandidateSummaryPayload?
    let hostEnvironment: AgenTTYAnalyticsHostEnvironmentPayload?
    let reachability: AgenTTYAnalyticsReachabilityPayload?
    let verification: AgenTTYAnalyticsVerificationPayload?
    let error: AgenTTYAnalyticsHostSetupErrorPayload?
}

nonisolated struct AgenTTYAnalyticsKeyMaterialEventPayload: Codable, Sendable {
    let context: AgenTTYAnalyticsContextInfo?
    let operation: AgenTTYAnalyticsKeyMaterialOperation
    let stage: AgenTTYAnalyticsKeyMaterialStage
    let key: AgenTTYAnalyticsKeyPayload?
    let error: AgenTTYAnalyticsKeyMaterialErrorPayload?
}

nonisolated struct AgenTTYAnalyticsPaywallPayload: Codable, Sendable {
    let context: AgenTTYAnalyticsContextInfo?
    let stage: AgenTTYAnalyticsPaywallStage
    let accessState: AgenTTYAnalyticsAccessState
}

nonisolated struct AgenTTYAnalyticsDeviceContext: Codable, Sendable {
    let systemVersion: String
    let deviceModelIdentifier: String
    let deviceFamily: AgenTTYAnalyticsDeviceFamily
    let localeIdentifier: String
    let preferredLanguages: [String]
}

nonisolated struct AgenTTYAnalyticsRequestEvent: Codable, Sendable {
    let eventID: String
    let eventType: AgenTTYAnalyticsEventType
    let occurredAtEpochSeconds: Int
    let payloadVersion: Int?
    let payload: AgenTTYAnalyticsJSONValue
}

nonisolated struct AgenTTYAnalyticsIngestRequest: Codable, Sendable {
    let deviceID: String
    let deviceSecret: String
    let appTransactionID: String
    let originalPurchaseDateEpochSeconds: Int
    let bundleID: String
    let appTransactionEnvironment: AgenTTYAnalyticsAppTransactionEnvironment
    let appVersion: String
    let buildNumber: String
    let flavor: AgenTTYAnalyticsFlavor
    let platform: AgenTTYAnalyticsPlatform
    let deviceContext: AgenTTYAnalyticsDeviceContext
    let events: [AgenTTYAnalyticsRequestEvent]
}

nonisolated enum AgenTTYAnalyticsAppTransactionEnvironment: String, Codable, Sendable {
    case production
    case sandbox
    case xcode
}

nonisolated enum AgenTTYAnalyticsFlavor: String, Codable, Sendable {
    case main
}

nonisolated enum AgenTTYAnalyticsPlatform: String, Codable, Sendable {
    case ios
}

nonisolated struct AgenTTYAnalyticsResolvedIdentity: Sendable {
    let appTransactionID: String
    let originalPurchaseDateEpochSeconds: Int
    let bundleID: String
    let appTransactionEnvironment: AgenTTYAnalyticsAppTransactionEnvironment
}

nonisolated enum AgenTTYAnalyticsHashing {
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { byte in
            let value = String(byte, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }
}

nonisolated enum AgenTTYAppTransactionAnalyticsResolver {
    static func resolve(
        flavor: AgenTTYBuildFlavor = .current(),
        bundle: Bundle = .main
    ) async -> AgenTTYAnalyticsResolvedIdentity? {
        guard flavor == .main else { return nil }
        guard bundle.path(forResource: "embedded", ofType: "mobileprovision") == nil else {
            return nil
        }
        let appTransactionResult: VerificationResult<AppTransaction>
        do {
            appTransactionResult = try await AppTransaction.shared
        } catch {
            return nil
        }
        guard case .verified(let appTransaction) = appTransactionResult else {
            return nil
        }
        guard let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier == appTransaction.bundleID else {
            return nil
        }
        let appTransactionEnvironment: AgenTTYAnalyticsAppTransactionEnvironment
        if appTransaction.environment == .production {
            appTransactionEnvironment = .production
        } else if appTransaction.environment == .sandbox {
            appTransactionEnvironment = .sandbox
        } else if appTransaction.environment == .xcode {
            appTransactionEnvironment = .xcode
        } else {
            return nil
        }

        return AgenTTYAnalyticsResolvedIdentity(
            appTransactionID: appTransaction.appTransactionID,
            originalPurchaseDateEpochSeconds: Int(appTransaction.originalPurchaseDate.timeIntervalSince1970.rounded()),
            bundleID: appTransaction.bundleID,
            appTransactionEnvironment: appTransactionEnvironment
        )
    }
}
