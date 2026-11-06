import Foundation
import Testing
@testable import AgenTTY_iOS

@Suite
struct HostConnectionMethodTests {
    @MainActor
    @Test
    func hostConnectionMethodClassifiesTailscaleMagicDNSHostname() {
        #expect(AgenTTYHostConnectionMethod.forAddress("dev-host.tail123.ts.net") == .tailscale)
    }

    @MainActor
    @Test
    func hostConnectionMethodClassifiesTailscaleAddressForCGNATRange() {
        #expect(AgenTTYHostConnectionMethod.forAddress("100.64.0.10") == .tailscale)
    }

    @MainActor
    @Test
    func hostConnectionMethodClassifiesSingleLabelHostnameAsLocalNetwork() {
        #expect(AgenTTYHostConnectionMethod.forAddress("dev-host") == .localNetwork)
    }

    @MainActor
    @Test
    func hostConnectionMethodClassifiesRFC1918AddressAsLocalNetwork() {
        #expect(AgenTTYHostConnectionMethod.forAddress("192.168.1.50") == .localNetwork)
    }

    @MainActor
    @Test
    func hostConnectionMethodClassifiesPublicHostnameAsPublicInternet() {
        #expect(AgenTTYHostConnectionMethod.forAddress("ssh.example.com") == .publicInternet)
    }

    @MainActor
    @Test
    func resolvedAddressClassificationUsesTailscaleWhenAnyResolvedIPIsTailnetAddress() {
        #expect(AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["192.168.1.50", "100.64.0.10"]
            ) == .tailscale)
    }

    @MainActor
    @Test
    func resolvedAddressClassificationUsesLocalNetworkWhenAllResolvedIPsArePrivate() {
        #expect(AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["192.168.1.50", "fe80::1234"]
            ) == .localNetwork)
    }

    @MainActor
    @Test
    func resolvedAddressClassificationUsesPublicInternetForPublicIPAddress() {
        #expect(AgenTTYHostConnectionMethod.resolvedMethod(
                forResolvedAddresses: ["203.0.113.10"]
            ) == .publicInternet)
    }

    @MainActor
    @Test
    func hostDecodesPersistedTailscaleAddressHint() throws {
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

        #expect(host.usesTailscaleAddress)
        #expect(AgenTTYHostConnectionMethod.directMethod(for: host) == .tailscale)
    }

    @MainActor
    @Test
    func connectionMethodStatusUsesPersistedTailscaleHintForShortHostname() {
        let status = AgenTTYHostConnectionMethodStatus(method: .tailscale)

        #expect(status.method == .tailscale)
    }

    @MainActor
    @Test
    func currentMethodUsesLiveMethodForConnectedActiveHost() {
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

        #expect(resolution.method == .relay)
        #expect(resolution.isReachable)
    }

    @MainActor
    @Test
    func currentMethodUsesDirectMethodWhenRelayFallbackIsUnavailable() {
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

        #expect(resolution.method == .tailscale)
        #expect(!resolution.isReachable)
        #expect(resolution.failureMessage == "timed out")
    }

    @MainActor
    @Test
    func currentMethodUsesRelayWhenDirectPathIsUnavailable() {
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

        #expect(resolution.method == .relay)
        #expect(resolution.isReachable)
    }

    @MainActor
    @Test
    func currentMethodUsesDirectMethodWhenDirectPathIsReachable() {
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

        #expect(resolution.method == .tailscale)
        #expect(resolution.isReachable)
    }

    @MainActor
    @Test
    func currentMethodUsesRelayAndOfflineWhenBothDirectAndRelayFail() {
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

        #expect(resolution.method == .relay)
        #expect(!resolution.isReachable)
        #expect(resolution.failureMessage == "relay offline")
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
