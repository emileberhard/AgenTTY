import XCTest
@testable import AgenTTY_iOS

final class HostConnectionMethodTests: XCTestCase {
    @MainActor
    func testHostConnectionMethodClassifiesTailscaleMagicDNSHostname() {
        XCTAssertEqual(
            AgenTTYHostConnectionMethod.forAddress("dev-host.tail123.ts.net"),
            .tailscale
        )
    }

    @MainActor
    func testHostConnectionMethodClassifiesTailscaleAddressForCGNATRange() {
        XCTAssertEqual(AgenTTYHostConnectionMethod.forAddress("100.64.0.10"), .tailscale)
    }

    @MainActor
    func testHostConnectionMethodClassifiesSingleLabelHostnameAsLocalNetwork() {
        XCTAssertEqual(AgenTTYHostConnectionMethod.forAddress("dev-host"), .localNetwork)
    }

    @MainActor
    func testHostConnectionMethodClassifiesRFC1918AddressAsLocalNetwork() {
        XCTAssertEqual(AgenTTYHostConnectionMethod.forAddress("192.168.1.50"), .localNetwork)
    }

    @MainActor
    func testHostConnectionMethodClassifiesPublicHostnameAsPublicInternet() {
        XCTAssertEqual(AgenTTYHostConnectionMethod.forAddress("ssh.example.com"), .publicInternet)
    }

    @MainActor
    func testResolvedAddressClassificationUsesTailscaleWhenAnyResolvedIPIsTailnetAddress() {
        XCTAssertEqual(
            AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["192.168.1.50", "100.64.0.10"]
            ),
            .tailscale
        )
    }

    @MainActor
    func testResolvedAddressClassificationUsesLocalNetworkWhenAllResolvedIPsArePrivate() {
        XCTAssertEqual(
            AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["192.168.1.50", "fe80::1234"]
            ),
            .localNetwork
        )
    }

    @MainActor
    func testResolvedAddressClassificationUsesPublicInternetForPublicIPAddress() {
        XCTAssertEqual(
            AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["203.0.113.10"]
            ),
            .publicInternet
        )
    }

    @MainActor
    func testHostDecodesPersistedTailscaleAddressHint() throws {
        let json = #"""
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "label": "Laptop",
          "address": "backup-host",
          "uses_tailscale_address": true,
          "port": 22,
          "username": "developer",
          "authentication": {
            "mode": "key",
            "keyID": "11111111-2222-3333-4444-555555555555"
          },
          "connection_route_policy": "direct_then_relay",
          "relay_host_id": "relay-host-1"
        }
        """#

        let host = try JSONDecoder().decode(AgenTTYHost.self, from: Data(json.utf8))

        XCTAssertTrue(host.usesTailscaleAddress)
        XCTAssertEqual(AgenTTYHostConnectionMethod.directMethod(for: host), .tailscale)
    }

    @MainActor
    func testConnectionMethodStatusUsesPersistedTailscaleHintForShortHostname() {
        let status = AgenTTYHostConnectionMethodStatus(method: .tailscale)

        XCTAssertEqual(status.method, .tailscale)
    }

    @MainActor
    func testCurrentMethodUsesLiveMethodForConnectedActiveHost() {
        let resolution = AgenTTYHostConnectionMethodResolver.currentStatusResolution(
                liveMethod: .relay,
                isActiveHostConnected: true,
                directMethod: .tailscale,
                isDirectlyReachable: true,
                directFailureMessage: nil,
                supportsRelayFallback: true,
                isRelayReachable: true,
                relayFailureMessage: nil
            )

        XCTAssertEqual(resolution.method, .relay)
        XCTAssertTrue(resolution.isReachable)
    }

    @MainActor
    func testCurrentMethodUsesDirectMethodWhenRelayFallbackIsUnavailable() {
        let resolution = AgenTTYHostConnectionMethodResolver.currentStatusResolution(
                liveMethod: nil,
                isActiveHostConnected: false,
                directMethod: .tailscale,
                isDirectlyReachable: false,
                directFailureMessage: "timed out",
                supportsRelayFallback: false,
                isRelayReachable: nil,
                relayFailureMessage: nil
            )

        XCTAssertEqual(resolution.method, .tailscale)
        XCTAssertFalse(resolution.isReachable)
        XCTAssertEqual(resolution.failureMessage, "timed out")
    }

    @MainActor
    func testCurrentMethodUsesRelayWhenDirectPathIsUnavailable() {
        let resolution = AgenTTYHostConnectionMethodResolver.currentStatusResolution(
                liveMethod: nil,
                isActiveHostConnected: false,
                directMethod: .publicInternet,
                isDirectlyReachable: false,
                directFailureMessage: "direct failed",
                supportsRelayFallback: true,
                isRelayReachable: true,
                relayFailureMessage: nil
            )

        XCTAssertEqual(resolution.method, .relay)
        XCTAssertTrue(resolution.isReachable)
    }

    @MainActor
    func testCurrentMethodUsesDirectMethodWhenDirectPathIsReachable() {
        let resolution = AgenTTYHostConnectionMethodResolver.currentStatusResolution(
                liveMethod: nil,
                isActiveHostConnected: false,
                directMethod: .tailscale,
                isDirectlyReachable: true,
                directFailureMessage: nil,
                supportsRelayFallback: true,
                isRelayReachable: nil,
                relayFailureMessage: nil
            )

        XCTAssertEqual(resolution.method, .tailscale)
        XCTAssertTrue(resolution.isReachable)
    }

    @MainActor
    func testCurrentMethodUsesRelayAndOfflineWhenBothDirectAndRelayFail() {
        let resolution = AgenTTYHostConnectionMethodResolver.currentStatusResolution(
            liveMethod: nil,
            isActiveHostConnected: false,
            directMethod: .tailscale,
            isDirectlyReachable: false,
            directFailureMessage: "direct failed",
            supportsRelayFallback: true,
            isRelayReachable: false,
            relayFailureMessage: "relay offline"
        )

        XCTAssertEqual(resolution.method, .relay)
        XCTAssertFalse(resolution.isReachable)
        XCTAssertEqual(resolution.failureMessage, "relay offline")
    }

    @MainActor
    private func makeHost(
        address: String,
        usesTailscaleAddress: Bool = false
    ) -> AgenTTYHost {
        AgenTTYHost(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            label: "Test Host",
            address: address,
            usesTailscaleAddress: usesTailscaleAddress,
            port: 22,
            username: "developer",
            authentication: .key(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            connectionRoutePolicy: .directThenRelay,
            relayHostID: "relay-host-1"
        )
    }
}
