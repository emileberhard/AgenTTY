import Foundation
import Synchronization

nonisolated enum SSHCommandFailure: LocalizedError, Equatable, Sendable {
    case remote(exitStatus: UInt32?, output: String)
    case timedOut
    case channelFailed

    static let maximumOutputLength = 1024

    static func remote(exitStatus: UInt32?, capturedOutput: String) -> Self {
        let trimmed = capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return .remote(exitStatus: exitStatus, output: String(trimmed.suffix(maximumOutputLength)))
    }

    var hostMessage: String? {
        guard case .remote(_, let output) = self else { return nil }
        return output
            .split(whereSeparator: \.isNewline)
            .map { AgenTTYDisplayText.sanitized(String($0), maximumLength: 200) }
            .last { !$0.isEmpty }
    }

    var errorDescription: String? {
        switch self {
        case .remote(let exitStatus, let output):
            let status = exitStatus.map { "exit status \($0)" } ?? "no exit status"
            return output.isEmpty
                ? "Remote command failed (\(status))."
                : "Remote command failed (\(status)): \(output)"
        case .timedOut:
            return "Remote command timed out."
        case .channelFailed:
            return "The SSH command channel was unavailable."
        }
    }
}

typealias SSHCommandResult = Result<String, SSHCommandFailure>

nonisolated final class SSHPendingWork: Sendable {
    private struct State {
        var isClosed = false
        var nextID = 0
        var cancellations: [Int: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    func register(_ cancellation: @escaping @Sendable () -> Void) -> Int? {
        state.withLock { state in
            guard !state.isClosed else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.cancellations[id] = cancellation
            return id
        }
    }

    func finish(_ id: Int) {
        _ = state.withLock { $0.cancellations.removeValue(forKey: id) }
    }

    func close() {
        let cancellations = state.withLock { state in
            state.isClosed = true
            defer { state.cancellations.removeAll() }
            return Array(state.cancellations.values)
        }
        cancellations.forEach { $0() }
    }
}

nonisolated final class SSHOneShot<Value: Sendable>: Sendable {
    private let handler: Mutex<(@Sendable (Value) -> Void)?>

    init(_ handler: @escaping @Sendable (Value) -> Void) {
        self.handler = Mutex(handler)
    }

    func fire(_ value: Value) {
        let handler = handler.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?(value)
    }
}

nonisolated extension Result where Success == String, Failure == SSHCommandFailure {
    func answered() throws(SSHCommandFailure) -> Self {
        switch self {
        case .success, .failure(.remote):
            return self
        case .failure(let failure):
            throw failure
        }
    }
}
