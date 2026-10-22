import Foundation

nonisolated private final class AgenTTYHostConnectionVerificationCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.agentty.ssh.verifier-state")
    private let continuation: CheckedContinuation<AgenTTYHostConnectionVerificationResult, Error>
    private var didResume = false
    private var session: SSHClientSession?

    init(continuation: CheckedContinuation<AgenTTYHostConnectionVerificationResult, Error>) {
        self.continuation = continuation
    }

    func store(session: SSHClientSession) {
        let shouldClose = queue.sync {
            guard !didResume else { return true }
            self.session = session
            return false
        }
        if shouldClose {
            session.close()
        }
    }

    func closeSession() {
        let session = queue.sync { self.session }
        session?.close()
    }

    func finish(with result: AgenTTYHostConnectionVerificationResult) {
        let shouldResume = queue.sync {
            if didResume {
                return false
            }
            didResume = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(returning: result)
    }

    func cancel() {
        let session: SSHClientSession? = queue.sync {
            guard !didResume else { return nil }
            didResume = true
            return self.session
        }
        session?.close()
        continuation.resume(throwing: CancellationError())
    }
}

nonisolated private final class AgenTTYHostConnectionVerificationCoordinatorHolder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.agentty.ssh.verifier-holder")
    private var coordinator: AgenTTYHostConnectionVerificationCoordinator?

    func store(_ coordinator: AgenTTYHostConnectionVerificationCoordinator) {
        queue.sync {
            self.coordinator = coordinator
        }
    }

    func cancel() {
        let coordinator = queue.sync { self.coordinator }
        coordinator?.cancel()
    }
}

enum AgenTTYHostConnectionVerifier {
    private static let defaultColumns = 120
    private static let defaultRows = 32
    private static let defaultWidthPx = 1200
    private static let defaultHeightPx = 900

    static func verify(
        connectionTarget: AgenTTYConnectionTarget,
        userAuthentication: AgenTTYSSHUserAuthentication,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        acceptedOpenSSHPublicKeys: [String] = [],
        preShellProvisioner: (@Sendable (SSHClientSession) async throws -> Void)? = nil
    ) async throws -> AgenTTYHostConnectionVerificationResult {
        let holder = AgenTTYHostConnectionVerificationCoordinatorHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let coordinator = AgenTTYHostConnectionVerificationCoordinator(continuation: continuation)
                holder.store(coordinator)

                let createdSession = SSHClientSession(
                    connectionTarget: connectionTarget,
                    userAuthentication: userAuthentication,
                    trustedHostKeyStore: trustedHostKeyStore,
                    acceptedOpenSSHPublicKeys: acceptedOpenSSHPublicKeys,
                    storesValidatedHostKey: false,
                    preShellProvisioner: preShellProvisioner,
                    outputHandler: { _ in },
                    readyHandler: {
                        coordinator.closeSession()
                        coordinator.finish(with: .succeeded)
                    },
                    disconnectHandler: { outcome in
                        coordinator.finish(with: .failed(outcome))
                    }
                )

                coordinator.store(session: createdSession)
                createdSession.updateWindowSize(
                    columns: defaultColumns,
                    rows: defaultRows,
                    widthPx: defaultWidthPx,
                    heightPx: defaultHeightPx
                )
                createdSession.connect()
            }
        } onCancel: {
            holder.cancel()
        }
    }
}
