import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import AgenTTY_iOS

struct SSHFailureSurfacingTests {
    @Test
    func rejectedKeyReportsAuthenticationFailure() async throws {
        let server = try await LoopbackSSHServer.start(hostKey: NIOSSHPrivateKey(ed25519Key: .init()))
        let clock = ContinuousClock()
        let startedAt = clock.now
        let outcome = try await connect(to: server, trustedHostKeyStore: makeTrustedHostKeyStore())
        let elapsed = clock.now - startedAt
        try await server.shutdown()

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
        let outcome = try await connect(to: server, trustedHostKeyStore: store)
        try await server.shutdown()

        #expect(outcome.category == .hostKeyMismatch)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "The Host Identity Changed")
    }

    @Test
    func hostToolsDownloadFailureHasItsOwnGuidance() {
        let outcome = SSHClientSession.preShellFailureOutcome(
            for: AgenTTYHostRuntimeArtifactError.manifestUnavailable(reason: "The request timed out.")
        )

        #expect(outcome.failureStage == .hostToolsDownload)
        #expect(outcome.rawReason.contains("The request timed out."))
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "Couldn’t Download Host Tools")
    }

    @Test
    func hostSideSetupFailureKeepsHostPreparationGuidance() {
        let outcome = SSHClientSession.preShellFailureOutcome(
            for: AgenTTYHostRuntimeProvisionError.remoteWriteFailed("$HOME/.agentty/config/notify.json")
        )

        #expect(outcome.failureStage == .preShellRuntime)
        #expect(AgenTTYSSHRecoveryGuidance.guidance(for: outcome).title == "Connected, But Host Preparation Failed")
    }

    private let hostID = UUID()

    private func makeTrustedHostKeyStore() -> AgenTTYTrustedHostKeyStore {
        AgenTTYTrustedHostKeyStore(
            userDefaults: UserDefaults(suiteName: "SSHFailureSurfacingTests-\(UUID().uuidString)")!,
            flavor: .dev
        )
    }

    private func connect(
        to server: LoopbackSSHServer,
        trustedHostKeyStore: AgenTTYTrustedHostKeyStore
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
                let (succeeded, output) = await ssh.runCommandCapturingOutput("uname -s && uname -m")
                guard succeeded else {
                    throw AgenTTYHostRuntimeProvisionError.hostPlatformDetectionFailed(output)
                }
            },
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

private final class RejectingUserAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.failure)
    }
}

private struct LoopbackSSHServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let port: Int

    static func start(hostKey: NIOSSHPrivateKey) async throws -> LoopbackSSHServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(
                                SSHServerConfiguration(
                                    hostKeys: [hostKey],
                                    userAuthDelegate: RejectingUserAuthenticationDelegate()
                                )
                            ),
                            allocator: child.allocator,
                            inboundChildChannelInitializer: nil
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
