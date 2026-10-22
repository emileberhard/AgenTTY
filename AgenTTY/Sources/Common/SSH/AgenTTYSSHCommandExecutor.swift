import Foundation
@unsafe @preconcurrency import NIOCore
import Synchronization

enum AgenTTYSSHCommandExecutionError: Error, Sendable {
    case commandFailed(output: String)
    case disconnected(AgenTTYSSHTerminationOutcome)
    case sessionUnavailable
}

nonisolated private struct AgenTTYSSHCommandExecutionState: Sendable {
    var didResume = false
    var session: SSHClientSession?
}

nonisolated private final class AgenTTYSSHCommandExecutionCoordinator: Sendable {
    private let state = Mutex(AgenTTYSSHCommandExecutionState())
    private let continuation: CheckedContinuation<String, Error>

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func store(session: SSHClientSession) {
        let shouldClose = state.withLock { state in
            guard !state.didResume else { return true }
            state.session = session
            return false
        }
        if shouldClose {
            session.close()
        }
    }

    func run(command: String, timeoutSeconds: Int) {
        guard let session = state.withLock({ $0.session }) else {
            finish(with: .failure(AgenTTYSSHCommandExecutionError.sessionUnavailable))
            return
        }

        session.runTmuxCommand(
            command,
            timeout: .seconds(Int64(max(timeoutSeconds, 1)))
        ) { [weak self] success, output in
            guard let self else { return }
            if success {
                self.finish(with: .success(output))
            } else {
                self.finish(with: .failure(AgenTTYSSHCommandExecutionError.commandFailed(output: output)))
            }
        }
    }

    func disconnect(_ outcome: AgenTTYSSHTerminationOutcome) {
        finish(with: .failure(AgenTTYSSHCommandExecutionError.disconnected(outcome)))
    }

    func cancel() {
        finish(with: .failure(CancellationError()))
    }

    private func finish(with result: Result<String, Error>) {
        let completion: (shouldResume: Bool, session: SSHClientSession?) = state.withLock { state in
            guard !state.didResume else { return (false, nil) }
            state.didResume = true
            defer { state.session = nil }
            return (true, state.session)
        }
        guard completion.shouldResume else { return }
        completion.session?.close()
        continuation.resume(with: result)
    }
}

nonisolated private final class AgenTTYSSHCommandExecutionCoordinatorHolder: Sendable {
    private struct State: Sendable {
        var coordinator: AgenTTYSSHCommandExecutionCoordinator?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func store(_ coordinator: AgenTTYSSHCommandExecutionCoordinator) {
        let shouldCancel = state.withLock { state in
            state.coordinator = coordinator
            return state.isCancelled
        }
        if shouldCancel {
            coordinator.cancel()
        }
    }

    func cancel() {
        let storedCoordinator = state.withLock { state in
            state.isCancelled = true
            return state.coordinator
        }
        storedCoordinator?.cancel()
    }
}

@MainActor
enum AgenTTYSSHCommandExecutor {
    static func run(
        _ command: String,
        on host: AgenTTYHost,
        timeoutSeconds: Int,
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        passwordStore: AgenTTYSSHPasswordStore,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    ) async throws -> String {
        let userAuthentication = try await AgenTTYSSHUserAuthenticationResolver.resolve(
            keyMaterialStore: keyMaterialStore,
            passwordStore: passwordStore,
            connectionTarget: host.connectionTarget
        )
        let route = try await AgenTTYConnectionRouteResolver.resolve(for: host)

        do {
            let output = try await run(
                command,
                connectionTarget: route.connectionTarget,
                userAuthentication: userAuthentication,
                timeoutSeconds: timeoutSeconds,
                trustedHostKeyStore: trustedHostKeyStore
            )
            if route.mode == .direct {
                AgenTTYConnectionRouteResolver.recordDirectRouteSuccess(for: host.id)
            }
            route.bridge?.close()
            return output
        } catch {
            if route.mode == .direct,
               let executionError = error as? AgenTTYSSHCommandExecutionError {
                switch executionError {
                case .commandFailed:
                    AgenTTYConnectionRouteResolver.recordDirectRouteSuccess(for: host.id)
                case .disconnected(let outcome)
                    where [.connectTimeout, .networkError, .transportClosed].contains(outcome.category):
                    AgenTTYConnectionRouteResolver.recordDirectRouteFailure(for: host.id)
                case .disconnected, .sessionUnavailable:
                    break
                }
            }
            route.bridge?.close()
            throw error
        }
    }

    private static func run(
        _ command: String,
        connectionTarget: AgenTTYConnectionTarget,
        userAuthentication: AgenTTYSSHUserAuthentication,
        timeoutSeconds: Int,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    ) async throws -> String {
        let holder = AgenTTYSSHCommandExecutionCoordinatorHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let coordinator = AgenTTYSSHCommandExecutionCoordinator(continuation: continuation)
                holder.store(coordinator)

                let session = SSHClientSession(
                    connectionTarget: connectionTarget,
                    userAuthentication: userAuthentication,
                    trustedHostKeyStore: trustedHostKeyStore,
                    purpose: .oneOffCommands,
                    outputHandler: { _ in },
                    readyHandler: { [weak coordinator] in
                        coordinator?.run(command: command, timeoutSeconds: timeoutSeconds)
                    },
                    disconnectHandler: { [weak coordinator] outcome in
                        coordinator?.disconnect(outcome)
                    }
                )
                coordinator.store(session: session)
                session.connect()
            }
        } onCancel: {
            holder.cancel()
        }
    }
}
