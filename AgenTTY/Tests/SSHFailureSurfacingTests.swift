import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
import Synchronization
@testable import AgenTTY_iOS

final class SSHFailureSurfacingTests {
    private let hostID = UUID()
    private let defaultsSuiteName = "SSHFailureSurfacingTests-\(UUID().uuidString)"

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func rejectedKeyReportsAuthenticationFailure() async throws {
        let server = try await LoopbackSSHServer.start(hostKey: NIOSSHPrivateKey(ed25519Key: .init()))
        let clock = ContinuousClock()
        let startedAt = clock.now
        let probe = SessionProbe()
        let outcome = try await connect(to: server, trustedHostKeyStore: makeTrustedHostKeyStore(), probe: probe) { ssh in
            _ = try await ssh.runCommand("uname -s && uname -m").get()
        }
        let elapsed = clock.now - startedAt
        try await server.shutdown()

        #expect(probe.provisionCount == 0)
        #expect(probe.progress == [.signingIn])
        #expect(elapsed < .seconds(10))
        #expect(outcome.category == .authFailed)
        #expect(outcome.failureStage == .sshAuth)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "SSH Authentication Failed")
    }

    @Test
    func changedHostKeyReportsHostKeyMismatch() async throws {
        let server = try await LoopbackSSHServer.start(hostKey: NIOSSHPrivateKey(ed25519Key: .init()))
        let store = makeTrustedHostKeyStore()
        try store.storePinnedHostKeys(
            hostID: hostID,
            address: "127.0.0.1",
            port: server.port,
            openSSHPublicKeys: [String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey)]
        )
        let probe = SessionProbe()
        let outcome = try await connect(to: server, trustedHostKeyStore: store, probe: probe) { _ in }
        try await server.shutdown()

        #expect(probe.provisionCount == 0)
        #expect(outcome.category == .hostKeyMismatch)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "The Host Identity Changed")
    }

    @Test
    func hostPreparationStartsOnlyAfterAuthenticationAndKeepsItsCause() async throws {
        let server = try await LoopbackSSHServer.start(
            hostKey: NIOSSHPrivateKey(ed25519Key: .init()),
            acceptsAuthentication: true,
            execRequestReceived: {}
        )
        let probe = SessionProbe()
        let outcome = try await connect(to: server, trustedHostKeyStore: makeTrustedHostKeyStore(), probe: probe) { _ in
            throw SSHCommandFailure.timedOut
        }
        try await server.shutdown()

        #expect(probe.provisionCount == 1)
        #expect(probe.progress == [.signingIn, .preparingHost])
        #expect(outcome.category == .hostSetupTimeout)
        #expect(outcome.failureStage == .preShellRuntime)
        #expect(!outcome.shouldReconnect)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "Host Setup Timed Out")
    }

    @Test(.timeLimit(.minutes(1)))
    func closeAnswersACommandTheHostNeverRepliesTo() async throws {
        let execRequests = AsyncStream<Void>.makeStream()
        let server = try await LoopbackSSHServer.start(
            hostKey: NIOSSHPrivateKey(ed25519Key: .init()),
            acceptsAuthentication: true,
            execRequestReceived: { execRequests.continuation.yield() }
        )
        let results = AsyncStream<SSHCommandResult>.makeStream()
        _ = try await connect(to: server, trustedHostKeyStore: makeTrustedHostKeyStore(), probe: SessionProbe()) { ssh in
            async let result = ssh.runCommand("true", timeout: .seconds(600))
            var requests = execRequests.stream.makeAsyncIterator()
            _ = await requests.next()
            ssh.close()
            results.continuation.yield(await result)
            results.continuation.finish()
            throw CancellationError()
        }
        var iterator = results.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        try await server.shutdown()

        #expect(result == .failure(.channelFailed))
    }

    @Test(arguments: [
        PreShellFailureCase(
            error: URLError(.timedOut),
            stage: .hostToolsDownload,
            title: "Couldn’t Download Host Tools"
        ),
        PreShellFailureCase(
            error: AgenTTYHostRuntimeProvisionError.remoteWriteFailed("$HOME/.agentty/config/notify.json"),
            stage: .preShellRuntime,
            title: "Connected, But Host Preparation Failed"
        ),
    ])
    func preShellFailureGuidance(_ failure: PreShellFailureCase) {
        let outcome = SSHClientSession.preShellFailureOutcome(for: failure.error)

        #expect(outcome.failureStage == failure.stage)
        #expect(outcome.rawReason.contains(failure.error.localizedDescription))
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == failure.title)
    }

    private func makeTrustedHostKeyStore() -> AgenTTYTrustedHostKeyStore {
        AgenTTYTrustedHostKeyStore(
            userDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
            flavor: .dev
        )
    }

    private func connect(
        to server: LoopbackSSHServer,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore,
        probe: SessionProbe,
        provisioner: @escaping @Sendable (SSHClientSession) async throws -> Void
    ) async throws -> AgenTTYSSHTerminationOutcome {
        let target = AgenTTYConnectionTarget(
            hostID: hostID,
            authentication: .key(UUID()),
            host: "127.0.0.1",
            username: "agentty",
            port: server.port,
            connectHost: "127.0.0.1",
            connectPort: server.port
        )
        let outcomes = AsyncStream<AgenTTYSSHTerminationOutcome>.makeStream()
        let session = SSHClientSession(
            connectionTarget: target,
            userAuthentication: .privateKey(
                username: "agentty",
                privateKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
            ),
            trustedHostKeyStore: trustedHostKeyStore,
            preShellProvisioner: { ssh in
                probe.recordProvision()
                try await provisioner(ssh)
            },
            progressHandler: { probe.record($0) },
            outputHandler: { _ in },
            readyHandler: {},
            disconnectHandler: { outcome in
                outcomes.continuation.yield(outcome)
                outcomes.continuation.finish()
            }
        )
        session.connect()
        defer { session.close() }

        var iterator = outcomes.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

struct ConnectionFailureMappingTests {
    @Test
    func authorizedKeyLineReplacesTheCommentWithTheKeyName() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample"
        #expect(AgenTTYAuthorizedKeyLine.make(publicKey: "\(key) old@laptop", keyName: "iPhone") == "\(key) AgenTTY: iPhone")
        #expect(AgenTTYAuthorizedKeyLine.make(publicKey: key, keyName: "AgenTTY iPad") == "\(key) AgenTTY iPad")
        #expect(AgenTTYAuthorizedKeyLine.make(publicKey: key, keyName: "agentty-work") == "\(key) agentty-work")
        #expect(AgenTTYAuthorizedKeyLine.make(publicKey: key, keyName: " \n\t ") == "\(key) AgenTTY")
        #expect(AgenTTYAuthorizedKeyLine.make(publicKey: key, keyName: "Work\nKey\u{1B}[31m") == "\(key) AgenTTY: Work Key [31m")
    }

    @Test
    func authorizedKeyCommentIsBounded() {
        let comment = AgenTTYAuthorizedKeyLine.comment(forKeyName: String(repeating: "k", count: 500))
        #expect(comment.count == AgenTTYAuthorizedKeyLine.maximumCommentLength)
        #expect(comment.hasPrefix("AgenTTY: kkk"))
    }

    @Test
    func passwordBootstrapInstallsTheNamedLine() {
        let line = AgenTTYAuthorizedKeyLine.make(publicKey: "ssh-ed25519 AAAAexample", keyName: "Neha’s iPhone")
        let command = AgenTTYSSHAuthorizedKeysInstaller.installPublicKeyCommand(authorizedKeyLine: line)
        #expect(command.contains("public_key='ssh-ed25519 AAAAexample AgenTTY: Neha’s iPhone'"))
        #expect(command.contains("$2 == key_blob"))
    }

    @Test(arguments: [
        PreflightCase(AgenTTYSSHKeyMaterialError.keyMaterialNotFound, .keyUnavailable, reconnects: false, title: "SSH Key Unavailable"),
        PreflightCase(AgenTTYSSHKeyStoreError.keyNotFound, .keyUnavailable, reconnects: false, title: "SSH Key Unavailable"),
        PreflightCase(AgenTTYSSHPasswordStoreError.passwordNotFound, .passwordUnavailable, reconnects: false, title: "SSH Password Unavailable"),
        PreflightCase(AgenTTYHostReachabilityError.invalidPort(0), .other, reconnects: false, title: "Couldn’t Start the Connection"),
        PreflightCase(
            AgenTTYHostReachabilityError.timedOut(host: "mini", port: 22, timeoutSeconds: 3),
            .connectTimeout, reconnects: true, title: "Couldn’t Reach the Host"
        ),
        PreflightCase(
            AgenTTYHostReachabilityError.failed(host: "mini", port: 22, reason: "nodename", subtype: .dns),
            .dnsFailure, reconnects: true, title: "Host Name Not Found"
        ),
        PreflightCase(
            AgenTTYHostReachabilityError.failed(host: "mini", port: 22, reason: "refused", subtype: .connectionRefused),
            .networkError, reconnects: true, title: "Couldn’t Reach the Host"
        ),
        PreflightCase(
            AgenTTYRelayFallbackFailure(directFailure: URLError(.timedOut), relayFailure: AgenTTYSSHRelayError.unauthorized),
            .relayRejected, reconnects: false, title: "Relay Access Rejected"
        ),
        PreflightCase(
            AgenTTYRelayFallbackFailure(directFailure: nil, relayFailure: AgenTTYSSHRelayError.resourceLimit("3 of 3 relay sessions in use")),
            .relayLimit(detail: "3 of 3 relay sessions in use"), reconnects: false, title: "Relay Limit Reached"
        ),
        PreflightCase(
            AgenTTYRelayFallbackFailure(directFailure: URLError(.timedOut), relayFailure: AgenTTYSSHRelayError.relayConnectorOffline),
            .relayConnectorOffline, reconnects: true, title: "Can’t Reach This Host"
        ),
        PreflightCase(
            AgenTTYRelayFallbackFailure(directFailure: URLError(.timedOut), relayFailure: URLError(.notConnectedToInternet)),
            .relayUnavailable, reconnects: true, title: "Relay Temporarily Unavailable"
        ),
        PreflightCase(
            AgenTTYRelayFallbackFailure(directFailure: nil, relayFailure: AgenTTYSSHRelayError.websocketOpenTimedOut),
            .relayUnavailable, reconnects: true, title: "Relay Temporarily Unavailable"
        ),
    ])
    func preflightFailuresBecomeOutcomes(_ failure: PreflightCase) {
        let outcome = SSHClientSession.preflightFailureOutcome(for: failure.error)

        #expect(outcome.category == failure.category)
        #expect(outcome.failureStage == .preflight)
        #expect(outcome.shouldReconnect == failure.reconnects)
        #expect(!outcome.wasReady)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == failure.title)
    }

    @Test
    func relayFallbackKeepsTheDirectFailureAndTheRelayLimitDetail() {
        let outcome = SSHClientSession.preflightFailureOutcome(
            for: AgenTTYRelayFallbackFailure(
                directFailure: AgenTTYHostReachabilityError.timedOut(host: "mini", port: 22, timeoutSeconds: 3),
                relayFailure: AgenTTYSSHRelayError.resourceLimit("3 of 3 relay sessions in use")
            )
        )

        #expect(outcome.rawReason.contains("mini"))
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).message.hasSuffix("3 of 3 relay sessions in use"))
    }

    @Test
    func keyInstallFailureNamesWhatTheHostReported() {
        let error = AgenTTYSSHKeyInstallError(
            failure: .remote(exitStatus: 1, capturedOutput: "\nmkdir: /home/agentty/.ssh: Permission denied\n")
        )
        let outcome = SSHClientSession.preShellFailureOutcome(for: error)
        let guidance = AgenTTYSSHRecoveryGuidance.guidance(for: outcome)

        #expect(outcome.category == .keyInstallFailed(hostMessage: "mkdir: /home/agentty/.ssh: Permission denied"))
        #expect(!outcome.shouldReconnect)
        #expect(guidance.title == "Couldn’t Install the SSH Key")
        #expect(guidance.message.contains("~/.ssh/authorized_keys"))
        #expect(guidance.message.hasSuffix("The host reported: mkdir: /home/agentty/.ssh: Permission denied"))
    }

    @Test
    func keyInstallFailureWithoutOutputClaimsNoCause() {
        let outcome = SSHClientSession.preShellFailureOutcome(
            for: AgenTTYSSHKeyInstallError(failure: .remote(exitStatus: 1, capturedOutput: "  \n"))
        )

        #expect(outcome.category == .keyInstallFailed(hostMessage: nil))
        #expect(!AgenTTYSSHRecoveryGuidance.guidance(for: outcome).message.contains("reported"))
    }

    @Test
    func unsupportedPlatformNamesTheDetectedSystem() {
        let outcome = SSHClientSession.preShellFailureOutcome(
            for: AgenTTYHostRuntimeProvisionError.unsupportedHostPlatform(operatingSystem: "FreeBSD", architecture: "amd64")
        )
        let guidance = AgenTTYSSHRecoveryGuidance.guidance(for: outcome)

        #expect(guidance.title == "Host Platform Not Supported")
        #expect(guidance.message.contains("FreeBSD on amd64"))
    }

    @Test
    func aLostCommandChannelRetriesInsteadOfBlaming() {
        let outcome = SSHClientSession.preShellFailureOutcome(for: SSHCommandFailure.channelFailed)

        #expect(outcome.category == .other)
        #expect(outcome.shouldReconnect)
    }

    @Test
    func remoteFailureKeepsABoundedTailOfItsOutput() {
        let failure = SSHCommandFailure.remote(exitStatus: 2, capturedOutput: String(repeating: "x", count: 5_000) + "\nlast line")

        guard case .remote(_, let output) = failure else {
            Issue.record("expected a remote failure")
            return
        }
        #expect(output.count == SSHCommandFailure.maximumOutputLength)
        #expect(failure.hostMessage == "last line")
    }

    @Test(arguments: [
        NoticeCase(.connectTimeout, .localNetwork, networkSatisfied: true, "Can’t reach mini.local", "Make sure this device is on the host’s network."),
        NoticeCase(.networkError, .tailscale, networkSatisfied: true, "Can’t reach mini.local", "Check that Tailscale is connected on this device and the host."),
        NoticeCase(.connectTimeout, .publicInternet, networkSatisfied: nil, "Can’t reach mini.local", "Check the address, the port and the host’s firewall."),
        NoticeCase(.connectTimeout, .tailscale, networkSatisfied: false, "No network connection", "Waiting for Wi-Fi or cellular."),
        NoticeCase(.dnsFailure, .localNetwork, networkSatisfied: true, "Can’t find mini.local", "Check the host name, or use its IP address."),
        NoticeCase(
            .transportClosed, .localNetwork, networkSatisfied: true,
            "The host closed SSH before the terminal started.", "If this repeats, check the host’s SSH server."
        ),
        NoticeCase(
            .relayConnectorOffline, .publicInternet, networkSatisfied: true,
            "Can’t reach mini.local", "The direct route failed and the host’s relay connector is offline. Check that the host is awake."
        ),
        NoticeCase(.relayUnavailable, .publicInternet, networkSatisfied: true, "Relay temporarily unavailable", "The direct route failed too."),
        NoticeCase(.shellClosed, .relay, networkSatisfied: true, "Connection lost", "AgenTTY will keep trying."),
    ])
    func retryNoticeNamesTheLikelyRemedy(_ notice: NoticeCase) {
        let failure = AgenTTYSSHRetryFailure(
            outcome: AgenTTYSSHTerminationOutcome(
                category: notice.category,
                failureStage: .tcpConnect,
                rawReason: "test",
                wasReady: false,
                shouldReconnect: true
            ),
            method: notice.method,
            address: "mini.local"
        )

        #expect(
            AgenTTYSSHRecoveryGuidance.retryNotice(for: failure, networkSatisfied: notice.networkSatisfied)
                == AgenTTYSSHRetryNotice(headline: notice.headline, hint: notice.hint)
        )
    }
}

struct PreflightCase: Sendable, CustomTestStringConvertible {
    let error: any Error
    let category: AgenTTYSSHDisconnectCategory
    let reconnects: Bool
    let title: String

    init(_ error: any Error, _ category: AgenTTYSSHDisconnectCategory, reconnects: Bool, title: String) {
        self.error = error
        self.category = category
        self.reconnects = reconnects
        self.title = title
    }

    var testDescription: String { "\(category)" }
}

struct NoticeCase: Sendable, CustomTestStringConvertible {
    let category: AgenTTYSSHDisconnectCategory
    let method: AgenTTYHostConnectionMethod
    let networkSatisfied: Bool?
    let headline: String
    let hint: String

    init(
        _ category: AgenTTYSSHDisconnectCategory,
        _ method: AgenTTYHostConnectionMethod,
        networkSatisfied: Bool?,
        _ headline: String,
        _ hint: String
    ) {
        self.category = category
        self.method = method
        self.networkSatisfied = networkSatisfied
        self.headline = headline
        self.hint = hint
    }

    var testDescription: String { "\(category) via \(method.rawValue)" }
}

struct PreShellFailureCase: Sendable, CustomTestStringConvertible {
    let error: any Error
    let stage: AgenTTYSSHFailureStage
    let title: String

    var testDescription: String { title }
}

private final class FixedUserAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
    let accepts: Bool

    init(accepts: Bool) {
        self.accepts = accepts
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(accepts ? .success : .failure)
    }
}

private final class UnansweredExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let execRequestReceived: @Sendable () -> Void

    init(execRequestReceived: @escaping @Sendable () -> Void) {
        self.execRequestReceived = execRequestReceived
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        execRequestReceived()
    }
}

private struct LoopbackSSHServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let port: Int

    static func start(hostKey: NIOSSHPrivateKey) async throws -> LoopbackSSHServer {
        try await start(hostKey: hostKey, acceptsAuthentication: false, execRequestReceived: {})
    }

    static func start(
        hostKey: NIOSSHPrivateKey,
        acceptsAuthentication: Bool,
        execRequestReceived: @escaping @Sendable () -> Void
    ) async throws -> LoopbackSSHServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(
                                SSHServerConfiguration(
                                    hostKeys: [hostKey],
                                    userAuthDelegate: FixedUserAuthenticationDelegate(accepts: acceptsAuthentication)
                                )
                            ),
                            allocator: child.allocator,
                            inboundChildChannelInitializer: { sessionChannel, _ in
                                sessionChannel.eventLoop.makeCompletedFuture {
                                    try sessionChannel.pipeline.syncOperations.addHandler(
                                        UnansweredExecHandler(execRequestReceived: execRequestReceived)
                                    )
                                }
                            }
                        )
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(channel.localAddress?.port)
        return LoopbackSSHServer(group: group, channel: channel, port: port)
    }

    func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }
}

private final class SessionProbe: Sendable {
    private struct State {
        var provisionCount = 0
        var progress: [SSHClientSession.Progress] = []
    }

    private let state = Mutex(State())

    var provisionCount: Int { state.withLock { $0.provisionCount } }
    var progress: [SSHClientSession.Progress] { state.withLock { $0.progress } }

    func recordProvision() {
        state.withLock { $0.provisionCount += 1 }
    }

    func record(_ progress: SSHClientSession.Progress) {
        state.withLock { $0.progress.append(progress) }
    }
}
