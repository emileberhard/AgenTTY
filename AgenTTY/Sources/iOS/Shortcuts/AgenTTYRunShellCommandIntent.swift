import AppIntents
import Foundation
import Observation

nonisolated struct AgenTTYForegroundShellCommand: Identifiable, Equatable, Sendable {
    let id: UUID
    let hostID: UUID
    let command: String
}

@MainActor
@Observable
final class AgenTTYShortcutExecutionContext: Sendable {
    private struct PendingForegroundCommand {
        let request: AgenTTYForegroundShellCommand
        let continuation: CheckedContinuation<Void, Error>
    }

    let hostStore: AgenTTYHostStore

    private let keyMaterialStore: AgenTTYSSHKeyMaterialStore
    private let passwordStore: AgenTTYSSHPasswordStore
    private let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    private let lifetimeAccessController: AgenTTYLifetimeAccessController

    private var pendingForegroundCommands: [PendingForegroundCommand] = []

    var pendingForegroundCommand: AgenTTYForegroundShellCommand? {
        pendingForegroundCommands.first?.request
    }

    init(
        hostStore: AgenTTYHostStore,
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        passwordStore: AgenTTYSSHPasswordStore,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        lifetimeAccessController: AgenTTYLifetimeAccessController
    ) {
        self.hostStore = hostStore
        self.keyMaterialStore = keyMaterialStore
        self.passwordStore = passwordStore
        self.trustedHostKeyStore = trustedHostKeyStore
        self.lifetimeAccessController = lifetimeAccessController
    }

    func hostEntities() -> [AgenTTYHostEntity] {
        hostStore.hosts.map(AgenTTYHostEntity.init)
    }

    func host(id: UUID) -> AgenTTYHost? {
        hostStore.hosts.first(where: { $0.id == id })
    }

    func allowsExecution() async -> Bool {
        await lifetimeAccessController.allowsExternalAction()
    }

    func runOneOffCommand(
        _ command: String,
        hostID: UUID,
        timeoutSeconds: Int
    ) async throws -> String {
        guard let host = host(id: hostID) else {
            throw AgenTTYRunShellCommandIntentError.hostNotFound
        }
        return try await AgenTTYSSHCommandExecutor.run(
            command,
            on: host,
            timeoutSeconds: timeoutSeconds,
            keyMaterialStore: keyMaterialStore,
            passwordStore: passwordStore,
            trustedHostKeyStore: trustedHostKeyStore
        )
    }

    func enqueueForegroundCommand(_ command: String, hostID: UUID) async throws {
        let request = AgenTTYForegroundShellCommand(
            id: UUID(),
            hostID: hostID,
            command: command
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingForegroundCommands.append(
                    PendingForegroundCommand(
                        request: request,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelForegroundCommand(id: request.id)
            }
        }
    }

    func completeForegroundCommand(id: UUID, succeeded: Bool) {
        guard let index = pendingForegroundCommands.firstIndex(where: { $0.request.id == id }) else {
            return
        }
        let pendingCommand = pendingForegroundCommands.remove(at: index)
        if succeeded {
            pendingCommand.continuation.resume()
        } else {
            pendingCommand.continuation.resume(
                throwing: AgenTTYRunShellCommandIntentError.foregroundShellFailed
            )
        }
    }

    private func cancelForegroundCommand(id: UUID) {
        guard let index = pendingForegroundCommands.firstIndex(where: { $0.request.id == id }) else {
            return
        }
        let pendingCommand = pendingForegroundCommands.remove(at: index)
        pendingCommand.continuation.resume(throwing: CancellationError())
    }
}

nonisolated struct AgenTTYHostEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Host")
    static let defaultQuery = AgenTTYHostEntityQuery()

    let id: UUID
    let label: String
    let address: String
    let port: Int
    let username: String

    init(_ host: AgenTTYHost) {
        id = host.id
        label = host.label
        address = host.address
        port = host.port
        username = host.username
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(label)",
            subtitle: "\(username)@\(address):\(port)",
            image: .init(systemName: "server.rack")
        )
    }
}

struct AgenTTYHostEntityQuery: EntityStringQuery {
    @AppDependency private var executionContext: AgenTTYShortcutExecutionContext

    func entities(for identifiers: [UUID]) async throws -> [AgenTTYHostEntity] {
        let identifierSet = Set(identifiers)
        return await executionContext.hostEntities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AgenTTYHostEntity] {
        await executionContext.hostEntities()
    }

    func entities(matching string: String) async throws -> [AgenTTYHostEntity] {
        let hosts = await executionContext.hostEntities()
        guard !string.isEmpty else { return hosts }
        return hosts.filter {
            $0.label.localizedCaseInsensitiveContains(string)
                || $0.address.localizedCaseInsensitiveContains(string)
                || $0.username.localizedCaseInsensitiveContains(string)
        }
    }

    func defaultResult() async -> AgenTTYHostEntity? {
        await executionContext.hostStore.activeHost.map(AgenTTYHostEntity.init)
    }
}

nonisolated enum AgenTTYShellCommandMode: String, AppEnum, Sendable {
    case runInBackground
    case openInNewShell

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .runInBackground: DisplayRepresentation(
            title: "Run in Background",
            subtitle: "Execute once over SSH without opening AgenTTY",
            image: .init(systemName: "terminal")
        ),
        .openInNewShell: DisplayRepresentation(
            title: "Open in New Shell",
            subtitle: "Create a tmux shell in AgenTTY and run the command",
            image: .init(systemName: "rectangle.badge.plus")
        ),
    ]
}

nonisolated enum AgenTTYRunShellCommandIntentError: Error, CustomLocalizedStringResourceConvertible {
    case accessRequired
    case emptyCommand
    case hostNotFound
    case foregroundUnavailable
    case foregroundShellFailed
    case invalidTimeout
    case commandFailed(String)
    case connectionFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .accessRequired:
            "Lifetime access is required to run SSH commands from Shortcuts."
        case .emptyCommand:
            "Enter a shell command to run."
        case .hostNotFound:
            "The selected AgenTTY host no longer exists."
        case .foregroundUnavailable:
            "This shortcut cannot open AgenTTY from its current context."
        case .foregroundShellFailed:
            "AgenTTY could not create the new shell."
        case .invalidTimeout:
            "Timeout must be between 1 and 20 seconds."
        case .commandFailed(let output):
            LocalizedStringResource(stringLiteral: output.isEmpty
                ? "The remote command failed or timed out."
                : "The remote command failed: \(Self.outputPreview(output))")
        case .connectionFailed(let reason):
            LocalizedStringResource(stringLiteral: "The SSH connection failed: \(reason)")
        }
    }

    private static func outputPreview(_ output: String) -> String {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 400 else { return normalized }
        return "\(normalized.prefix(400))…"
    }
}

struct AgenTTYRunShellCommandIntent: AppIntent {
    static let backgroundTimeoutRange = 1...20

    static let title: LocalizedStringResource = "Run Shell Command"
    static let description = IntentDescription(
        "Run a shell command over SSH on a saved AgenTTY host.",
        categoryName: "SSH",
        searchKeywords: ["SSH", "shell", "terminal", "command"],
        resultValueName: "Command Output"
    )
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Host", description: "The saved AgenTTY host to connect to.")
    var host: AgenTTYHostEntity

    @Parameter(
        title: "Command",
        description: "The shell command to execute.",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var command: String

    @Parameter(title: "Mode", default: .runInBackground)
    var mode: AgenTTYShellCommandMode

    @Parameter(
        title: "Timeout",
        description: "Maximum time to wait for a background command, from 1 to 20 seconds.",
        default: 10
    )
    var timeoutSeconds: Int

    @Dependency private var executionContext: AgenTTYShortcutExecutionContext

    static var parameterSummary: some ParameterSummary {
        When(\AgenTTYRunShellCommandIntent.$mode, .equalTo, .runInBackground, {
            Summary("Run \(\.$command) on \(\.$host)") {
                \.$mode
                \.$timeoutSeconds
            }
        }, otherwise: {
            Summary("Run \(\.$command) in a new shell on \(\.$host)") {
                \.$mode
            }
        })
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgenTTYRunShellCommandIntentError.emptyCommand
        }
        guard await executionContext.allowsExecution() else {
            throw AgenTTYRunShellCommandIntentError.accessRequired
        }
        guard await executionContext.host(id: host.id) != nil else {
            throw AgenTTYRunShellCommandIntentError.hostNotFound
        }

        switch mode {
        case .runInBackground:
            guard Self.backgroundTimeoutRange.contains(timeoutSeconds) else {
                throw AgenTTYRunShellCommandIntentError.invalidTimeout
            }
            do {
                let output = try await executionContext.runOneOffCommand(
                    command,
                    hostID: host.id,
                    timeoutSeconds: timeoutSeconds
                )
                return .result(
                    value: output,
                    dialog: "Command finished on \(host.label)."
                )
            } catch let error as AgenTTYSSHCommandExecutionError {
                switch error {
                case .commandFailed(let output):
                    throw AgenTTYRunShellCommandIntentError.commandFailed(output)
                case .disconnected(let outcome):
                    throw AgenTTYRunShellCommandIntentError.connectionFailed(outcome.rawReason)
                case .sessionUnavailable:
                    throw AgenTTYRunShellCommandIntentError.connectionFailed("SSH session unavailable")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgenTTYRunShellCommandIntentError.connectionFailed(error.localizedDescription)
            }

        case .openInNewShell:
            if systemContext.currentMode != .foreground {
                guard systemContext.currentMode.canContinueInForeground else {
                    throw AgenTTYRunShellCommandIntentError.foregroundUnavailable
                }
                try await continueInForeground(
                    "Opening a new shell on \(host.label)…",
                    alwaysConfirm: false
                )
            }
            do {
                try await executionContext.enqueueForegroundCommand(command, hostID: host.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AgenTTYRunShellCommandIntentError.foregroundShellFailed
            }
            return .result(
                value: "",
                dialog: "Opened a new shell on \(host.label)."
            )
        }
    }
}
