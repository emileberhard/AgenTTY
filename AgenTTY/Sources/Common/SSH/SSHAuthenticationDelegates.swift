import Foundation
@unsafe @preconcurrency import NIOCore
@unsafe @preconcurrency import NIOSSH

enum AgenTTYSSHAuthenticationError: LocalizedError {
    case publicKeyMethodUnavailable
    case publicKeyAuthenticationRejected(attemptedAlgorithms: [String])
    case passwordMethodUnavailable
    case passwordAuthenticationRejected

    var errorDescription: String? {
        switch self {
        case .publicKeyMethodUnavailable:
            "Server does not allow public-key authentication for this host."
        case .publicKeyAuthenticationRejected(let attemptedAlgorithms):
            "Public-key authentication was rejected by the server (tried "
                + attemptedAlgorithms.joined(separator: ", ") + ")."
        case .passwordMethodUnavailable:
            "Server does not allow password authentication for this host."
        case .passwordAuthenticationRejected:
            "Password authentication was rejected by the server."
        }
    }
}

nonisolated final class AgenTTYSSHFailureRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.agentty.ssh.failure-recorder")
    private var recordedOutcome: AgenTTYSSHTerminationOutcome?

    func record(_ outcome: AgenTTYSSHTerminationOutcome) {
        queue.sync {
            guard case nil = recordedOutcome else { return }
            recordedOutcome = outcome
        }
    }

    func takeOutcome() -> AgenTTYSSHTerminationOutcome? {
        queue.sync {
            defer { recordedOutcome = nil }
            return recordedOutcome
        }
    }
}

enum AgenTTYSSHUserAuthentication: Sendable {
    case privateKey(username: String, privateKey: NIOSSHPrivateKey)
    case password(username: String, password: String)
}

nonisolated final class TOFUHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let connectionTarget: AgenTTYConnectionTarget
    private let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    private let acceptedOpenSSHPublicKeys: [String]
    private let storesValidatedHostKey: Bool
    private let failureRecorder: AgenTTYSSHFailureRecorder

    init(
        connectionTarget: AgenTTYConnectionTarget,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        acceptedOpenSSHPublicKeys: [String] = [],
        storesValidatedHostKey: Bool,
        failureRecorder: AgenTTYSSHFailureRecorder
    ) {
        self.connectionTarget = connectionTarget
        self.trustedHostKeyStore = trustedHostKeyStore
        self.acceptedOpenSSHPublicKeys = acceptedOpenSSHPublicKeys
        self.storesValidatedHostKey = storesValidatedHostKey
        self.failureRecorder = failureRecorder
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try trustedHostKeyStore.validateAndStore(
                hostID: connectionTarget.hostID,
                address: connectionTarget.host,
                port: connectionTarget.port,
                hostKey: hostKey,
                acceptedOpenSSHPublicKeys: acceptedOpenSSHPublicKeys,
                storesValidatedKey: storesValidatedHostKey
            )
            EsmaLog.ssh.debug("host key accepted via TOFU for host=\(self.connectionTarget.host, privacy: .public)")
            validationCompletePromise.succeed(())
        } catch {
            EsmaLog.ssh.error("host key validation failed: \(error.localizedDescription, privacy: .public)")
            let category: AgenTTYSSHDisconnectCategory = if error is AgenTTYTrustedHostKeyValidationError {
                .hostKeyMismatch
            } else {
                .other
            }
            failureRecorder.record(
                AgenTTYSSHTerminationOutcome(
                    category: category,
                    failureStage: .sshAuth,
                    rawReason: error.localizedDescription,
                    wasReady: false,
                    shouldReconnect: false
                )
            )
            validationCompletePromise.fail(error)
        }
    }
}

nonisolated final class AgenTTYSSHAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let authentication: AgenTTYSSHUserAuthentication
    private let failureRecorder: AgenTTYSSHFailureRecorder

    /// One offer per signature algorithm the key can produce, strongest first. RFC 8332 lets an
    /// RSA key sign as `rsa-sha2-512`, `rsa-sha2-256`, or `ssh-rsa` while the key blob stays
    /// `ssh-rsa`, and only `SSH_MSG_USERAUTH_FAILURE` tells us which the server accepts. Every
    /// other key type yields exactly one entry, so their wire behavior is unchanged.
    private var pendingOffers: [NIOSSHUserAuthenticationOffer.Offer]
    private let attemptedSignatureAlgorithms: [String]

    init(
        authentication: AgenTTYSSHUserAuthentication,
        failureRecorder: AgenTTYSSHFailureRecorder
    ) {
        self.authentication = authentication
        self.failureRecorder = failureRecorder

        switch authentication {
        case .privateKey(_, let privateKey):
            let algorithms = privateKey.signatureAlgorithms
            attemptedSignatureAlgorithms = algorithms
            pendingOffers = algorithms.map { algorithm -> NIOSSHUserAuthenticationOffer.Offer in
                .privateKey(.init(privateKey: privateKey, signatureAlgorithm: algorithm))
            }
        case .password(_, let password):
            attemptedSignatureAlgorithms = []
            pendingOffers = [.password(.init(password: password))]
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        switch authentication {
        case .privateKey(let username, _):
            guard availableMethods.contains(.publicKey) else {
                EsmaLog.ssh.error(
                    "server does not support public key auth; methods=\(String(describing: availableMethods), privacy: .public)"
                )
                failureRecorder.record(
                    AgenTTYSSHTerminationOutcome(
                        category: .authFailed,
                        failureStage: .sshAuth,
                        rawReason: AgenTTYSSHAuthenticationError.publicKeyMethodUnavailable.localizedDescription,
                        wasReady: false,
                        shouldReconnect: false
                    )
                )
                nextChallengePromise.fail(AgenTTYSSHAuthenticationError.publicKeyMethodUnavailable)
                return
            }

            guard !pendingOffers.isEmpty else {
                let rejection = AgenTTYSSHAuthenticationError.publicKeyAuthenticationRejected(
                    attemptedAlgorithms: attemptedSignatureAlgorithms
                )
                let tried = attemptedSignatureAlgorithms.joined(separator: ",")
                EsmaLog.ssh.error(
                    "public key auth rejected by server; tried=\(tried, privacy: .public)"
                )
                failureRecorder.record(
                    AgenTTYSSHTerminationOutcome(
                        category: .authFailed,
                        failureStage: .sshAuth,
                        rawReason: rejection.localizedDescription,
                        wasReady: false,
                        shouldReconnect: false
                    )
                )
                nextChallengePromise.fail(rejection)
                return
            }

            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: pendingOffers.removeFirst()
                )
            )
        case .password(let username, _):
            guard availableMethods.contains(.password) else {
                EsmaLog.ssh.error(
                    "server does not support password auth; methods=\(String(describing: availableMethods), privacy: .public)"
                )
                failureRecorder.record(
                    AgenTTYSSHTerminationOutcome(
                        category: .authFailed,
                        failureStage: .sshAuth,
                        rawReason: AgenTTYSSHAuthenticationError.passwordMethodUnavailable.localizedDescription,
                        wasReady: false,
                        shouldReconnect: false
                    )
                )
                nextChallengePromise.fail(AgenTTYSSHAuthenticationError.passwordMethodUnavailable)
                return
            }

            guard !pendingOffers.isEmpty else {
                EsmaLog.ssh.error("password auth rejected by server")
                failureRecorder.record(
                    AgenTTYSSHTerminationOutcome(
                        category: .authFailed,
                        failureStage: .sshAuth,
                        rawReason: AgenTTYSSHAuthenticationError.passwordAuthenticationRejected.localizedDescription,
                        wasReady: false,
                        shouldReconnect: false
                    )
                )
                nextChallengePromise.fail(AgenTTYSSHAuthenticationError.passwordAuthenticationRejected)
                return
            }

            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: pendingOffers.removeFirst()
                )
            )
        }
    }
}
