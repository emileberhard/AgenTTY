import Foundation
@unsafe @preconcurrency import Network

@MainActor
final class AgenTTYRelayBridge {
    private let relaySession: AgenTTYSSHRelaySession
    private let listenerQueue = DispatchQueue(label: "dev.tuist.agentty.relay.listener")
    private let connectionQueue = DispatchQueue(label: "dev.tuist.agentty.relay.connection")
    private let urlSession: URLSession
    private let pump = RelayBridgePump()

    private var listener: NWListener?
    private var websocketReceiveTask: Task<Void, Never>?
    private var websocketPingTask: Task<Void, Never>?
    private var didClose = false

    private static let websocketPingInterval: Duration = .seconds(20)
    private static let websocketOpenTimeout: Duration = .seconds(10)

    /// Terminal bytes ride this session; mark them as latency-sensitive so
    /// Wi-Fi/cellular queueing prioritizes them over bulk traffic.
    private static let interactiveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .responsiveData
        return URLSession(configuration: configuration)
    }()

    private(set) var localPort: Int = 0

    init(
        relaySession: AgenTTYSSHRelaySession,
        urlSession: URLSession = AgenTTYRelayBridge.interactiveSession
    ) {
        self.relaySession = relaySession
        self.urlSession = urlSession
    }

    func start() async throws {
        try await startListener()
        try await startWebSocket()
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        websocketReceiveTask?.cancel()
        websocketReceiveTask = nil
        websocketPingTask?.cancel()
        websocketPingTask = nil
        pump.close()
        listener?.cancel()
        listener = nil
    }

    private func startListener() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionLimit = 1
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewLocalConnection(connection)
            }
        }

        let resolution = StartResolution()
        try await withCheckedThrowingContinuation { continuation in
            resolution.install(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolution.resume(with: .success(()))
                case .failed(let error):
                    resolution.resume(with: .failure(error))
                default:
                    break
                }
            }
            listener.start(queue: listenerQueue)
        }

        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw AgenTTYSSHRelayError.invalidResponse
        }
        self.listener = listener
        localPort = Int(port)
    }

    /// Opens the relay websocket and waits for the server handshake, bounded
    /// by `websocketOpenTimeout`. The previous fire-and-forget resume left a
    /// dead relay path undetected until the system's own multi-minute
    /// timeout, so during partial connectivity (e.g. a wedged VPN) the app
    /// kept cycling "connecting" without ever surfacing a failure.
    private func startWebSocket() async throws {
        guard let websocketURL = URL(string: relaySession.websocketURL) else {
            close()
            throw AgenTTYSSHRelayError.invalidResponse
        }

        var request = URLRequest(url: websocketURL)
        request.setValue(
            "Bearer \(relaySession.authorizationToken)",
            forHTTPHeaderField: "Authorization"
        )
        let websocketTask = urlSession.webSocketTask(with: request)
        let openResolution = StartResolution()
        websocketTask.delegate = WebSocketOpenDelegate(resolution: openResolution)
        pump.attachWebSocket(websocketTask) { [weak self] in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }

        var timeoutTask: Task<Void, Never>?
        do {
            try await withCheckedThrowingContinuation { continuation in
                openResolution.install(continuation: continuation)
                websocketTask.resume()
                timeoutTask = Task { [openResolution] in
                    try? await Task.sleep(for: Self.websocketOpenTimeout)
                    guard !Task.isCancelled else { return }
                    openResolution.resume(
                        with: .failure(AgenTTYSSHRelayError.websocketOpenTimedOut)
                    )
                }
            }
        } catch {
            timeoutTask?.cancel()
            close()
            throw error
        }
        timeoutTask?.cancel()

        websocketReceiveTask = Task { [weak self, pump] in
            await Self.runWebSocketReceiveLoop(pump: pump) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.close()
                }
            }
        }
        websocketPingTask = Task { [pump] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.websocketPingInterval)
                guard !Task.isCancelled else { return }
                guard pump.sendPing() else { return }
            }
        }
    }

    private func handleNewLocalConnection(_ connection: NWConnection) {
        guard !didClose else {
            connection.cancel()
            return
        }
        guard pump.attachLocalConnection(connection) else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, pump] state in
            switch state {
            case .ready:
                pump.flushPendingRemoteFrames()
                pump.scheduleLocalReceive()
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.close()
                }
            default:
                break
            }
        }
        connection.start(queue: connectionQueue)
    }

    // @concurrent keeps the frame-forwarding loop off the MainActor so inbound
    // terminal bytes never wait behind UI work.
    @concurrent
    private nonisolated static func runWebSocketReceiveLoop(
        pump: RelayBridgePump,
        onFailure: @escaping @Sendable () -> Void
    ) async {
        guard let websocketTask = pump.currentWebSocketTask() else { return }
        do {
            while !Task.isCancelled && !pump.isClosed {
                let message = try await websocketTask.receive()
                switch message {
                case .data(let data):
                    pump.forwardRemoteFrame(data)
                case .string(let string):
                    pump.forwardRemoteFrame(Data(string.utf8))
                @unknown default:
                    break
                }
            }
        } catch {
            guard !pump.isClosed else { return }
            onFailure()
        }
    }
}

/// Lock-guarded byte pump shared between the relay websocket and the local
/// loopback connection. Forwarding runs directly on the network callbacks'
/// queues so per-chunk latency never depends on main-thread availability;
/// only lifecycle transitions hop back to the MainActor bridge.
nonisolated private final class RelayBridgePump: @unchecked Sendable {
    private let lock = NSLock()
    private var websocketTask: URLSessionWebSocketTask?
    private var websocketFailureHandler: (@Sendable () -> Void)?
    private var localConnection: NWConnection?
    private var pendingRemoteFrames: [Data] = []
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func attachWebSocket(
        _ task: URLSessionWebSocketTask,
        onFailure: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        websocketTask = task
        websocketFailureHandler = onFailure
        lock.unlock()
    }

    func attachLocalConnection(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, localConnection == nil else { return false }
        localConnection = connection
        return true
    }

    func currentWebSocketTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return websocketTask
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let websocketTask = self.websocketTask
        let localConnection = self.localConnection
        self.websocketTask = nil
        self.websocketFailureHandler = nil
        self.localConnection = nil
        pendingRemoteFrames.removeAll(keepingCapacity: false)
        lock.unlock()

        websocketTask?.cancel(with: .normalClosure, reason: nil)
        localConnection?.cancel()
    }

    func scheduleLocalReceive() {
        lock.lock()
        let connection = localConnection
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let connection else { return }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.sendWebSocketBinary(data)
            }
            if isComplete || error != nil {
                self.failFromPump()
                return
            }
            self.scheduleLocalReceive()
        }
    }

    func forwardRemoteFrame(_ data: Data) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        guard let connection = localConnection else {
            pendingRemoteFrames.append(data)
            lock.unlock()
            return
        }
        lock.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.failFromPump()
            }
        })
    }

    func flushPendingRemoteFrames() {
        lock.lock()
        guard !closed, let connection = localConnection, !pendingRemoteFrames.isEmpty else {
            lock.unlock()
            return
        }
        let frames = pendingRemoteFrames
        pendingRemoteFrames.removeAll(keepingCapacity: false)
        lock.unlock()

        for frame in frames {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Returns false when the pump is closed so the ping loop can stop.
    func sendPing() -> Bool {
        lock.lock()
        let task = websocketTask
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let task else { return false }

        task.sendPing { [weak self] error in
            if error != nil {
                self?.failFromPump()
            }
        }
        return true
    }

    private func sendWebSocketBinary(_ data: Data) {
        lock.lock()
        let task = websocketTask
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let task else { return }

        task.send(.data(data)) { [weak self] error in
            if error != nil {
                self?.failFromPump()
            }
        }
    }

    private func failFromPump() {
        lock.lock()
        let handler = websocketFailureHandler
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        handler?()
    }
}

/// Task-level delegate that resolves the bounded websocket-open wait in
/// `startWebSocket()`. URLSession retains it until the task completes;
/// resolutions after the first are ignored, so post-open completion events
/// fall through to the receive loop's failure handling.
nonisolated private final class WebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let resolution: StartResolution

    init(resolution: StartResolution) {
        self.resolution = resolution
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolution.resume(with: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        resolution.resume(with: .failure(error ?? AgenTTYSSHRelayError.invalidResponse))
    }
}

/// One-shot bridge from a callback-style start event to a checked
/// continuation; used by both the loopback listener start and the relay
/// websocket open.
nonisolated private final class StartResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var didResume = false

    func install(continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume(returning: ())
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
