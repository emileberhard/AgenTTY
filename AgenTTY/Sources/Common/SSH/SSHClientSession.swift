import Foundation
@unsafe @preconcurrency import NIOCore
@unsafe @preconcurrency import NIOPosix
@unsafe @preconcurrency import NIOSSH

nonisolated final class SSHClientSession: @unchecked Sendable {
    enum Purpose: Sendable {
        case interactiveShell
        case oneOffCommands
    }

    enum Progress: Equatable, Sendable {
        case signingIn
        case preparingHost
        case startingTerminal
    }

    typealias OutputHandler = @Sendable (Data) -> Void
    typealias ReadyHandler = @Sendable () -> Void
    typealias DisconnectHandler = @Sendable (AgenTTYSSHTerminationOutcome) -> Void

    private let progressHandler: @Sendable (Progress) -> Void
    private let outputHandler: OutputHandler
    private let readyHandler: ReadyHandler
    private let disconnectHandler: DisconnectHandler
    private let preShellProvisioner: (@Sendable (SSHClientSession) async throws -> Void)?
    private let purpose: Purpose
    private let connectionTarget: AgenTTYConnectionTarget
    private let group: MultiThreadedEventLoopGroup
    private let stateQueue = DispatchQueue(label: "dev.agentty.ssh.state")

    private let authDelegate: AgenTTYSSHAuthenticationDelegate
    private let hostDelegate: TOFUHostKeysDelegate
    private let failureRecorder = AgenTTYSSHFailureRecorder()
    private let pendingWork = SSHPendingWork()
    private let sshHandlerName = "agentty.ssh.handler"
    private static let remoteFileUploadChunkSize = 64 * 1024
    private let connectionStartedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

    private var rootChannel: Channel?
    private var shellChannel: Channel?
    private var didDisconnect = false
    private var pendingOutboundData: [Data] = []
    private var outboundWriteCount = 0
    private var windowSizeUpdateCount = 0
    private var didLogWindowSizeBeforeShell = false
    private var latestWindowSize: TerminalWindowSize?
    private var didBecomeReady = false

    init(
        connectionTarget: AgenTTYConnectionTarget,
        userAuthentication: AgenTTYSSHUserAuthentication,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        acceptedOpenSSHPublicKeys: [String] = [],
        storesValidatedHostKey: Bool = true,
        purpose: Purpose = .interactiveShell,
        preShellProvisioner: (@Sendable (SSHClientSession) async throws -> Void)? = nil,
        progressHandler: @escaping @Sendable (Progress) -> Void = { _ in },
        outputHandler: @escaping OutputHandler,
        readyHandler: @escaping ReadyHandler,
        disconnectHandler: @escaping DisconnectHandler
    ) {
        self.connectionTarget = connectionTarget
        self.purpose = purpose
        self.preShellProvisioner = preShellProvisioner
        self.progressHandler = progressHandler
        self.outputHandler = outputHandler
        self.readyHandler = readyHandler
        self.disconnectHandler = disconnectHandler
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        authDelegate = AgenTTYSSHAuthenticationDelegate(
            authentication: userAuthentication,
            failureRecorder: failureRecorder
        )
        hostDelegate = TOFUHostKeysDelegate(
            connectionTarget: connectionTarget,
            trustedHostKeyStore: trustedHostKeyStore,
            acceptedOpenSSHPublicKeys: acceptedOpenSSHPublicKeys,
            storesValidatedHostKey: storesValidatedHostKey,
            failureRecorder: failureRecorder
        )
    }

    deinit {
        EsmaLog.ssh.debug("ssh session deinit")
        close()
    }

    func connect() {
        EsmaLog.ssh.info(
            "connect start user=\(self.connectionTarget.username, privacy: .public) host=\(self.connectionTarget.host, privacy: .public) port=\(self.connectionTarget.port) socket_host=\(self.connectionTarget.connectHost, privacy: .public) socket_port=\(self.connectionTarget.connectPort)"
        )

        let authenticated: @Sendable (Channel) -> Void = { [weak self] channel in
            self?.authenticationSucceeded(on: channel)
        }
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [authDelegate, hostDelegate, failureRecorder, sshHandlerName] channel in
                do {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostDelegate,
                                transportProtectionSchemes: AgenTTYSSHTransportProtectionSchemes.clientSchemes()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler, name: sshHandlerName)
                    try channel.pipeline.syncOperations.addHandler(
                        RootSSHDiagnosticsHandler(failureRecorder: failureRecorder, authenticated: authenticated)
                    )
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connectTimeout(.seconds(5))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            // Detect dead peers within ~30s even without app-level probes, and keep
            // NAT/firewall mappings warm while the connection idles.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 15)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
            // Interactive terminal traffic: prefer low-latency queueing on Wi-Fi/cellular.
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_NET_SERVICE_TYPE),
                value: NET_SERVICE_TYPE_RD
            )

        bootstrap.connect(
            host: self.connectionTarget.connectHost,
            port: self.connectionTarget.connectPort
        ).whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                let rawReason = "connect failed: \(error.localizedDescription)"
                notifyDisconnect(
                    Self.connectFailureOutcome(for: error, rawReason: rawReason)
                )

            case .success(let channel):
                EsmaLog.ssh.info(
                    "tcp connected elapsed_ms=\(self.elapsedMillisecondsSinceConnectionStart())"
                )

                stateQueue.sync {
                    self.rootChannel = channel
                }
                progressHandler(.signingIn)

                channel.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    let rawReason = "ssh transport closed"
                    self.notifyDisconnect(
                        AgenTTYSSHTerminationOutcome(
                            category: .transportClosed,
                            failureStage: self.didBecomeReady ? .postReadySession : .transport,
                            rawReason: rawReason,
                            wasReady: self.didBecomeReady,
                            shouldReconnect: !self.didBecomeReady
                        )
                    )
                }
            }
        }
    }

    private func authenticationSucceeded(on channel: Channel) {
        Task { [weak self] in
            guard let self else { return }
            self.progressHandler(.preparingHost)
            let provisioningStartedAt = DispatchTime.now().uptimeNanoseconds
            do {
                try await self.runPreShellProvisionerIfNeeded()
            } catch {
                self.notifyDisconnect(Self.preShellFailureOutcome(for: error))
                return
            }
            guard channel.isActive else { return }
            EsmaLog.ssh.info(
                "ssh auth and pre-shell runtime ready phase_elapsed_ms=\(EsmaDiagnostics.elapsedMilliseconds(since: provisioningStartedAt)) total_elapsed_ms=\(self.elapsedMillisecondsSinceConnectionStart())"
            )
            switch self.purpose {
            case .interactiveShell:
                self.progressHandler(.startingTerminal)
                self.openShellChannel(on: channel)
            case .oneOffCommands:
                self.didBecomeReady = true
                self.readyHandler()
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }

        stateQueue.async { [self] in
            if let shellChannel {
                write(data, on: shellChannel, source: "live")
                return
            }

            pendingOutboundData.append(data)
            let queueDepth = pendingOutboundData.count
            if EsmaDiagnostics.shouldLog(counter: queueDepth, defaultLimit: 2) {
                EsmaLog.ssh.info("queued outbound bytes=\(data.count) depth=\(queueDepth) while shell channel is not ready")
            }
        }
    }

    func runCommand(
        _ command: String,
        timeout: TimeAmount = .seconds(20)
    ) async -> SSHCommandResult {
        await runExec(command: command, input: nil, timeout: timeout, logLabel: "remote command")
    }

    func runLivenessProbe() async -> Bool {
        if case .success = await runCommand("true", timeout: .seconds(6)) {
            return true
        }
        return false
    }

    func writeRemoteFile(
        _ data: Data,
        remotePath: String,
        executable: Bool,
        expectedSHA256: String? = nil
    ) async -> SSHCommandResult {
        let command = Self.remoteFileWriteCommand(
            for: remotePath,
            executable: executable,
            expectedByteCount: data.count,
            expectedSHA256: expectedSHA256
        )
        return await runExec(command: command, input: data, timeout: nil, logLabel: "remote file write")
    }

    @concurrent
    func writeRemoteFile(
        from localFileURL: URL,
        remotePath: String,
        executable: Bool
    ) async -> Bool {
        guard let rootChannel = stateQueue.sync(execute: { self.rootChannel }) else {
            EsmaLog.ssh.error("remote file write dropped: ssh root channel unavailable")
            return false
        }

        guard let expectedByteCount = try? localFileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            EsmaLog.ssh.error(
                "remote file write dropped: local file size unavailable path=\(localFileURL.path, privacy: .private(mask: .hash))"
            )
            return false
        }

        let command = Self.remoteFileWriteCommand(
            for: remotePath,
            executable: executable,
            expectedByteCount: expectedByteCount
        )

        do {
            let (childChannel, execHandler) = try await onEventLoop(of: rootChannel) { complete in
                self.startOneOffExecChannel(command: command, on: rootChannel).whenComplete(complete)
            }.get()

            do {
                try await streamLocalFile(at: localFileURL, to: childChannel)
            } catch {
                childChannel.close(promise: nil)
                throw error
            }

            _ = await onEventLoop(of: childChannel) { complete in
                childChannel.closeFuture.whenComplete(complete)
            }

            let success = execHandler.exitStatus == 0
            if !success {
                EsmaLog.ssh.error(
                    "clipboard file upload failed status=\(String(describing: execHandler.exitStatus), privacy: .public) output=\(execHandler.outputPreview, privacy: .public)"
                )
            }
            return success
        } catch {
            EsmaLog.ssh.error(
                "clipboard file upload exec failed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    func updateWindowSize(columns: Int, rows: Int, widthPx: Int, heightPx: Int) {
        let safeSize = TerminalWindowSize(columns: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)

        let shellChannel = stateQueue.sync { () -> Channel? in
            latestWindowSize = safeSize
            return self.shellChannel
        }

        guard let shellChannel else {
            let shouldLog = stateQueue.sync {
                if didLogWindowSizeBeforeShell { return false }
                didLogWindowSizeBeforeShell = true
                return true
            }
            if shouldLog {
                EsmaLog.ssh.info("queued early window size update: no shell channel yet cols=\(safeSize.columns) rows=\(safeSize.rows) px=\(safeSize.widthPx)x\(safeSize.heightPx)")
            }
            return
        }

        sendWindowSize(safeSize, on: shellChannel, reason: "layout update")
    }

    func close() {
        pendingWork.close()
        let channels: (Channel?, Channel?) = stateQueue.sync {
            let channels = (rootChannel, shellChannel)
            rootChannel = nil
            shellChannel = nil
            pendingOutboundData.removeAll(keepingCapacity: false)
            return channels
        }

        channels.1?.close(promise: nil)
        channels.0?.close(promise: nil)

        group.shutdownGracefully { _ in }
    }

    private func startInteractiveShell(on channel: Channel) {
        guard let requestedSize = stateQueue.sync(execute: { latestWindowSize }) else {
            notifyDisconnect(
                AgenTTYSSHTerminationOutcome(
                    category: .other,
                    failureStage: .ptyBootstrap,
                    rawReason: "missing initial terminal size before PTY bootstrap",
                    wasReady: false,
                    shouldReconnect: false
                )
            )
            return
        }
        EsmaLog.ssh.info(
            "requesting pty cols=\(requestedSize.columns) rows=\(requestedSize.rows) px=\(requestedSize.widthPx)x\(requestedSize.heightPx) tmux_session=\(AgenTTYConnection.tmuxSessionName, privacy: .public)"
        )

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: requestedSize.columns,
            terminalRowHeight: requestedSize.rows,
            terminalPixelWidth: requestedSize.widthPx,
            terminalPixelHeight: requestedSize.heightPx,
            terminalModes: SSHTerminalModes([:])
        )

        channel.triggerUserOutboundEvent(pty).whenComplete { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                self.notifyDisconnect(
                    AgenTTYSSHTerminationOutcome(
                    category: .other,
                    failureStage: .ptyBootstrap,
                    rawReason: "failed to request PTY: \(error.localizedDescription)",
                    wasReady: false,
                    shouldReconnect: false
                )
                )
            case .success:
                let command = SSHChannelRequestEvent.ExecRequest(
                    command: AgenTTYConnection.tmuxBootstrapCommand,
                    wantReply: true
                )
                channel.triggerUserOutboundEvent(command).whenComplete { [weak self] execResult in
                    guard let self else { return }

                    switch execResult {
                    case .failure(let error):
                        self.notifyDisconnect(
                            AgenTTYSSHTerminationOutcome(
                                category: .other,
                                failureStage: .tmuxBootstrap,
                                rawReason: "failed to start tmux shell bootstrap: \(error.localizedDescription)",
                                wasReady: false,
                                shouldReconnect: false
                            )
                        )
                    case .success:
                        EsmaLog.ssh.info(
                            "tmux bootstrap ready total_elapsed_ms=\(self.elapsedMillisecondsSinceConnectionStart())"
                        )
                        self.didBecomeReady = true
                        self.applyLatestWindowSize(on: channel, reason: "shell ready")
                        self.flushPendingOutbound(on: channel)
                        self.readyHandler()
                    }
                }
            }
        }
    }

    private func runPreShellProvisionerIfNeeded() async throws {
        guard let preShellProvisioner else { return }
        try await preShellProvisioner(self)
    }

    private func openShellChannel(on rootChannel: Channel) {
        lookupSSHHandler(on: rootChannel).flatMap { sshHandler in
            let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                }
                let shellHandler = ShellChannelHandler(outputHandler: self.outputHandler)
                do {
                    try childChannel.pipeline.syncOperations.addHandler(shellHandler)
                    return childChannel.eventLoop.makeSucceededFuture(())
                } catch {
                    return childChannel.eventLoop.makeFailedFuture(error)
                }
            }
            return childPromise.futureResult
        }.whenComplete { [weak self] childResult in
            guard let self else { return }
            switch childResult {
            case .failure(let error):
                self.notifyDisconnect(
                    AgenTTYSSHTerminationOutcome(
                        category: .other,
                        failureStage: .shellChannel,
                        rawReason: "failed to open shell channel: \(error.localizedDescription)",
                        wasReady: false,
                        shouldReconnect: true
                    )
                )
            case .success(let childChannel):
                EsmaLog.ssh.info(
                    "session channel opened total_elapsed_ms=\(self.elapsedMillisecondsSinceConnectionStart())"
                )

                self.stateQueue.sync {
                    self.shellChannel = childChannel
                }

                childChannel.closeFuture.whenComplete { [weak self] _ in
                    guard let self else { return }
                    let rawReason = "shell channel closed"
                    self.notifyDisconnect(
                        AgenTTYSSHTerminationOutcome(
                            category: .shellClosed,
                            failureStage: self.didBecomeReady ? .postReadySession : .shellChannel,
                            rawReason: rawReason,
                            wasReady: self.didBecomeReady,
                            shouldReconnect: self.didBecomeReady
                        )
                    )
                }

                self.startInteractiveShell(on: childChannel)
            }
        }
    }

    private func notifyDisconnect(_ fallback: AgenTTYSSHTerminationOutcome) {
        let shouldEmit = stateQueue.sync {
            if didDisconnect { return false }
            didDisconnect = true
            return true
        }

        guard shouldEmit else { return }
        let outcome = failureRecorder.outcome ?? fallback
        EsmaLog.ssh.error("disconnect: \(outcome.rawReason, privacy: .public)")
        disconnectHandler(outcome)
    }

    private func elapsedMillisecondsSinceConnectionStart() -> UInt64 {
        EsmaDiagnostics.elapsedMilliseconds(since: connectionStartedAtNanoseconds)
    }

    private func runExec(
        command: String,
        input: Data?,
        timeout: TimeAmount?,
        logLabel: String
    ) async -> SSHCommandResult {
        guard !command.isEmpty else { return .failure(.channelFailed) }
        guard let rootChannel = stateQueue.sync(execute: { self.rootChannel }) else {
            EsmaLog.ssh.error("\(logLabel, privacy: .public) dropped: ssh root channel unavailable")
            return .failure(.channelFailed)
        }

        return await onEventLoop(of: rootChannel, ifUnavailable: .failure(.channelFailed)) { complete in
            let runState = OneOffExecRunState()
            if let timeout {
                runState.timeoutTask = rootChannel.eventLoop.scheduleTask(in: timeout) {
                    runState.didTimeOut = true
                    EsmaLog.ssh.error("\(logLabel, privacy: .public) timed out")
                    guard let runningChildChannel = runState.runningChildChannel else {
                        complete(.failure(.timedOut))
                        return
                    }
                    runningChildChannel.close(promise: nil)
                }
            }

            self.startOneOffExecChannel(command: command, on: rootChannel)
                .flatMap { childChannel, execHandler in
                    Self.finishInput(input, on: childChannel).map { (childChannel, execHandler) }
                }
                .whenComplete { result in
                    switch result {
                    case .failure(let error):
                        runState.timeoutTask?.cancel()
                        EsmaLog.ssh.error(
                            "\(logLabel, privacy: .public) exec request failed: \(String(describing: error), privacy: .public)"
                        )
                        complete(.failure(runState.didTimeOut ? .timedOut : .channelFailed))

                    case .success(let (childChannel, execHandler)):
                        guard !runState.didTimeOut else {
                            childChannel.close(promise: nil)
                            return
                        }
                        runState.runningChildChannel = childChannel
                        childChannel.closeFuture.whenComplete { _ in
                            runState.timeoutTask?.cancel()
                            guard !runState.didTimeOut else {
                                complete(.failure(.timedOut))
                                return
                            }
                            if execHandler.didTruncateOutput {
                                EsmaLog.ssh.notice("\(logLabel, privacy: .public) output truncated at 1048576 bytes")
                            }
                            let result = execHandler.result
                            if case .failure = result {
                                EsmaLog.ssh.error(
                                    "\(logLabel, privacy: .public) exec failed status=\(String(describing: execHandler.exitStatus), privacy: .public) output=\(execHandler.outputPreview, privacy: .public)"
                                )
                            }
                            complete(result)
                        }
                    }
                }
        }
    }

    private static func finishInput(_ input: Data?, on childChannel: Channel) -> EventLoopFuture<Void> {
        guard let input else {
            childChannel.close(mode: .output, promise: nil)
            return childChannel.eventLoop.makeSucceededVoidFuture()
        }
        var buffer = childChannel.allocator.buffer(capacity: input.count)
        buffer.writeBytes(input)
        let packet = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        return childChannel.writeAndFlush(packet).map {
            childChannel.close(mode: .output, promise: nil)
        }
    }

    private final class OneOffExecRunState: @unchecked Sendable {
        var didTimeOut = false
        var runningChildChannel: Channel?
        var timeoutTask: Scheduled<Void>?
    }

    private func onEventLoop<Value: Sendable>(
        of channel: Channel,
        ifUnavailable unavailable: Value,
        _ body: @escaping @Sendable (_ complete: @escaping @Sendable (Value) -> Void) -> Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let resume = SSHOneShot<Value> { continuation.resume(returning: $0) }
            guard let workID = pendingWork.register({ resume.fire(unavailable) }) else {
                resume.fire(unavailable)
                return
            }
            let pendingWork = pendingWork
            channel.eventLoop.execute {
                body { value in
                    pendingWork.finish(workID)
                    resume.fire(value)
                }
            }
        }
    }

    private func onEventLoop<Success: Sendable>(
        of channel: Channel,
        _ body: @escaping @Sendable (_ complete: @escaping @Sendable (Result<Success, Error>) -> Void) -> Void
    ) async -> Result<Success, Error> {
        await onEventLoop(of: channel, ifUnavailable: .failure(SSHSessionError.closed), body)
    }

    private func startOneOffExecChannel(
        command: String,
        on rootChannel: Channel
    ) -> EventLoopFuture<(Channel, ExecCommandChannelHandler)> {
        lookupSSHHandler(on: rootChannel)
            .flatMap { sshHandler -> EventLoopFuture<(Channel, ExecCommandChannelHandler)> in
                let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)
                let execHandler = ExecCommandChannelHandler()

                sshHandler.createChannel(childPromise) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                    }
                    do {
                        try childChannel.pipeline.syncOperations.addHandler(execHandler)
                        return childChannel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return childChannel.eventLoop.makeFailedFuture(error)
                    }
                }

                return childPromise.futureResult.map { ($0, execHandler) }
            }
            .flatMap { childChannel, execHandler -> EventLoopFuture<(Channel, ExecCommandChannelHandler)> in
                let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                return childChannel.triggerUserOutboundEvent(request).map { (childChannel, execHandler) }
            }
    }

    private func streamLocalFile(
        at localFileURL: URL,
        to childChannel: Channel
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer {
            try? fileHandle.close()
        }

        while true {
            try Task.checkCancellation()
            let chunk = try fileHandle.read(upToCount: Self.remoteFileUploadChunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            try Task.checkCancellation()
            try await onEventLoop(of: childChannel) { complete in
                var buffer = childChannel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                let packet = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                childChannel.writeAndFlush(packet).whenComplete(complete)
            }.get()
        }

        try await onEventLoop(of: childChannel) { complete in
            let promise = childChannel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete(complete)
            childChannel.close(mode: .output, promise: promise)
        }.get()
    }

    private func write(_ data: Data, on channel: Channel, source: String) {
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let packet = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenFailure { error in
                EsmaLog.ssh.error(
                    "outbound write failed source=\(source, privacy: .public) bytes=\(data.count) error=\(String(describing: error), privacy: .public)"
                )
            }
            channel.writeAndFlush(packet, promise: promise)

            let writeCount = self.stateQueue.sync {
                self.outboundWriteCount += 1
                return self.outboundWriteCount
            }
            if EsmaDiagnostics.shouldLog(counter: writeCount, defaultLimit: 6) {
                let preview = Self.logPreview(of: data)
                EsmaLog.ssh.info(
                    "outbound write #\(writeCount) source=\(source, privacy: .public) bytes=\(data.count) preview=\(preview, privacy: .public)"
                )
            }
        }
    }

    private func applyLatestWindowSize(on channel: Channel, reason: String) {
        let size = stateQueue.sync { latestWindowSize }
        guard let size else { return }
        sendWindowSize(size, on: channel, reason: reason)
    }

    private func sendWindowSize(_ size: TerminalWindowSize, on shellChannel: Channel, reason: String) {
        shellChannel.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: size.columns,
                terminalRowHeight: size.rows,
                terminalPixelWidth: size.widthPx,
                terminalPixelHeight: size.heightPx
            )
            shellChannel.triggerUserOutboundEvent(event, promise: nil)

            let updateCount = self.stateQueue.sync {
                self.windowSizeUpdateCount += 1
                return self.windowSizeUpdateCount
            }
            if EsmaDiagnostics.shouldLog(counter: updateCount, defaultLimit: 4) {
                EsmaLog.ssh.info(
                    "window update #\(updateCount) reason=\(reason, privacy: .public) cols=\(size.columns) rows=\(size.rows) px=\(size.widthPx)x\(size.heightPx)"
                )
            }
        }
    }

    private func flushPendingOutbound(on channel: Channel) {
        let pending: [Data] = stateQueue.sync {
            guard !pendingOutboundData.isEmpty else { return [] }
            let data = pendingOutboundData
            pendingOutboundData.removeAll(keepingCapacity: false)
            return data
        }
        guard !pending.isEmpty else { return }

        EsmaLog.ssh.info("flushing queued outbound packets count=\(pending.count)")
        for queuedData in pending {
            write(queuedData, on: channel, source: "flush")
        }
    }

    private func lookupSSHHandler(on channel: Channel) -> EventLoopFuture<NIOSSHHandler> {
        channel.pipeline.context(name: sshHandlerName).flatMapThrowing { context in
            guard let sshHandler = context.handler as? NIOSSHHandler else {
                throw SSHSessionError.missingSSHHandler
            }
            return sshHandler
        }
    }

    private struct TerminalWindowSize: Sendable {
        let columns: Int
        let rows: Int
        let widthPx: Int
        let heightPx: Int

        init(columns: Int, rows: Int, widthPx: Int, heightPx: Int) {
            self.columns = max(columns, 1)
            self.rows = max(rows, 1)
            self.widthPx = max(widthPx, 0)
            self.heightPx = max(heightPx, 0)
        }
    }
}

private enum SSHSessionError: Error {
    case invalidChannelType
    case missingSSHHandler
    case closed
}
