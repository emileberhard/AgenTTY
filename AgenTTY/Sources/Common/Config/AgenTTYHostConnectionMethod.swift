import Darwin
import Foundation

nonisolated enum AgenTTYHostConnectionMethod: String, Equatable, Sendable {
    case localNetwork = "local_network"
    case publicInternet = "public_internet"
    case tailscale
    case relay

    var title: String {
        switch self {
        case .localNetwork:
            "Local Network"
        case .publicInternet:
            "Public Internet"
        case .tailscale:
            "Tailscale"
        case .relay:
            "Relay"
        }
    }

    var symbolName: String {
        switch self {
        case .localNetwork:
            "wifi"
        case .publicInternet:
            "globe"
        case .tailscale:
            "point.3.connected.trianglepath.dotted"
        case .relay:
            "arrow.left.arrow.right"
        }
    }

    static func directMethod(for host: AgenTTYHost) -> Self {
        if host.usesTailscaleAddress {
            return .tailscale
        }
        return forAddress(host.address)
    }

    static func forAddress(_ address: String) -> Self {
        let normalizedAddress = AgenTTYHostAddressNormalizer.normalizeForMatching(address)
        guard !normalizedAddress.isEmpty else { return .publicInternet }

        if normalizedAddress.isTailscaleMagicDNSHostnameLiteral || normalizedAddress.isTailscaleAddressLiteral {
            return .tailscale
        }

        if normalizedAddress.isPrivateOrLocalAddressLiteral {
            return .localNetwork
        }

        return .publicInternet
    }

    static func resolvedMethod(forResolvedAddresses addresses: [String]) -> Self? {
        let normalizedAddresses = Array(
            Set(
                addresses
                    .map(AgenTTYHostAddressNormalizer.normalizeForMatching)
                    .filter { !$0.isEmpty }
            )
        )
        guard !normalizedAddresses.isEmpty else { return nil }

        if normalizedAddresses.contains(where: \.isTailscaleAddressLiteral) {
            return .tailscale
        }

        if normalizedAddresses.allSatisfy({
            $0.isPrivateIPv4Literal || $0.isLinkLocalIPv4Literal || $0.isLoopbackIPv4Literal || $0.isLinkLocalIPv6Literal || $0.isLoopbackIPv6Literal
        }) {
            return .localNetwork
        }

        if normalizedAddresses.contains(where: \.isIPAddressLiteral) {
            return .publicInternet
        }

        return nil
    }
}

struct AgenTTYHostConnectionMethodStatus: Equatable, Sendable {
    let method: AgenTTYHostConnectionMethod

    init(method: AgenTTYHostConnectionMethod) {
        self.method = method
    }
}

struct AgenTTYHostConnectionStatusResolution: Equatable, Sendable {
    let method: AgenTTYHostConnectionMethod
    let isReachable: Bool
    let failureMessage: String?
}

nonisolated enum AgenTTYHostConnectionMethodResolver {
    static func currentStatusResolution(
        liveMethod: AgenTTYHostConnectionMethod?,
        isActiveHostConnected: Bool,
        directMethod: AgenTTYHostConnectionMethod,
        isDirectlyReachable: Bool,
        directFailureMessage: String?,
        supportsRelayFallback: Bool,
        isRelayReachable: Bool?,
        relayFailureMessage: String?
    ) -> AgenTTYHostConnectionStatusResolution {
        if isActiveHostConnected, let liveMethod {
            return AgenTTYHostConnectionStatusResolution(
                method: liveMethod,
                isReachable: true,
                failureMessage: nil
            )
        }

        if isDirectlyReachable {
            return AgenTTYHostConnectionStatusResolution(
                method: directMethod,
                isReachable: true,
                failureMessage: nil
            )
        }

        guard supportsRelayFallback else {
            return AgenTTYHostConnectionStatusResolution(
                method: directMethod,
                isReachable: false,
                failureMessage: directFailureMessage
            )
        }

        if isRelayReachable == true {
            return AgenTTYHostConnectionStatusResolution(
                method: .relay,
                isReachable: true,
                failureMessage: nil
            )
        }

        return AgenTTYHostConnectionStatusResolution(
            method: .relay,
            isReachable: false,
            failureMessage: relayFailureMessage ?? directFailureMessage
        )
    }

    static func resolveCurrentStatus(
        for host: AgenTTYHost,
        liveMethod: AgenTTYHostConnectionMethod?,
        isActiveHostConnected: Bool
    ) async -> AgenTTYHostConnectionStatusResolution {
        if isActiveHostConnected, let liveMethod {
            return AgenTTYHostConnectionStatusResolution(
                method: liveMethod,
                isReachable: true,
                failureMessage: nil
            )
        }

        let directMethod = await resolveDirectMethod(for: host) ?? AgenTTYHostConnectionMethod.directMethod(for: host)
        let supportsRelayFallback = host.connectionRoutePolicy == .directThenRelay
            && host.relayHostID?.isEmpty == false

        var directFailureMessage: String?
        do {
            try await AgenTTYHostReachabilityProbe.verifyReachable(
                host: host.address,
                port: host.port,
                timeoutSeconds: 2
            )
            return currentStatusResolution(
                liveMethod: liveMethod,
                isActiveHostConnected: isActiveHostConnected,
                directMethod: directMethod,
                isDirectlyReachable: true,
                directFailureMessage: nil,
                supportsRelayFallback: supportsRelayFallback,
                isRelayReachable: nil,
                relayFailureMessage: nil
            )
        } catch {
            directFailureMessage = error.localizedDescription
        }

        guard supportsRelayFallback, let relayHostID = host.relayHostID, !relayHostID.isEmpty else {
            return currentStatusResolution(
                liveMethod: liveMethod,
                isActiveHostConnected: isActiveHostConnected,
                directMethod: directMethod,
                isDirectlyReachable: false,
                directFailureMessage: directFailureMessage,
                supportsRelayFallback: false,
                isRelayReachable: nil,
                relayFailureMessage: nil
            )
        }

        do {
            _ = try await AgenTTYSSHRelayClient.shared.issueRelaySession(relayHostID: relayHostID)
            return currentStatusResolution(
                liveMethod: liveMethod,
                isActiveHostConnected: isActiveHostConnected,
                directMethod: directMethod,
                isDirectlyReachable: false,
                directFailureMessage: directFailureMessage,
                supportsRelayFallback: true,
                isRelayReachable: true,
                relayFailureMessage: nil
            )
        } catch {
            return currentStatusResolution(
                liveMethod: liveMethod,
                isActiveHostConnected: isActiveHostConnected,
                directMethod: directMethod,
                isDirectlyReachable: false,
                directFailureMessage: directFailureMessage,
                supportsRelayFallback: true,
                isRelayReachable: false,
                relayFailureMessage: error.localizedDescription
            )
        }
    }

    static func resolveDirectMethod(for host: AgenTTYHost) async -> AgenTTYHostConnectionMethod? {
        if host.usesTailscaleAddress {
            return .tailscale
        }

        let normalizedAddress = AgenTTYHostAddressNormalizer.normalizeForMatching(host.address)
        guard normalizedAddress.requiresHostnameResolutionForConnectionMethod else {
            return nil
        }

        let resolvedAddresses = await resolveNumericAddresses(forHostname: normalizedAddress)
        return AgenTTYHostConnectionMethod.resolvedMethod(forResolvedAddresses: resolvedAddresses)
    }

    private static func resolveNumericAddresses(forHostname hostname: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: lookupNumericAddresses(forHostname: hostname))
            }
        }
    }

    private static func lookupNumericAddresses(forHostname hostname: String) -> [String] {
        var hints = unsafe addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var infoPointer: UnsafeMutablePointer<addrinfo>?
        guard unsafe getaddrinfo(hostname, nil, &hints, &infoPointer) == 0,
              let infoPointer = unsafe infoPointer else {
            return []
        }
        defer { unsafe freeaddrinfo(infoPointer) }

        var resolvedAddresses: [String] = []
        var seenAddresses = Set<String>()
        var currentPointer: UnsafeMutablePointer<addrinfo>? = unsafe infoPointer

        while let entry = unsafe currentPointer?.pointee {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = unsafe getnameinfo(
                unsafe entry.ai_addr,
                unsafe entry.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let endIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
                let numericHost = String(
                    decoding: hostBuffer[..<endIndex].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                ).lowercased()
                if !numericHost.isEmpty, seenAddresses.insert(numericHost).inserted {
                    resolvedAddresses.append(numericHost)
                }
            }
            let nextPointer = unsafe entry.ai_next
            unsafe currentPointer = nextPointer
        }

        return resolvedAddresses
    }
}

private extension String {
    nonisolated var requiresHostnameResolutionForConnectionMethod: Bool {
        guard !isEmpty else { return false }
        guard !isIPAddressLiteral else { return false }
        if isTailscaleMagicDNSHostnameLiteral {
            return false
        }
        return true
    }

    nonisolated var isTailscaleMagicDNSHostnameLiteral: Bool {
        hasSuffix(".ts.net") || hasSuffix(".beta.tailscale.net")
    }

    nonisolated var isIPAddressLiteral: Bool {
        ipv4Octets != nil || contains(":")
    }

    nonisolated var isTailscaleAddressLiteral: Bool {
        isTailscaleIPv4Literal || isTailscaleIPv6Literal
    }

    nonisolated var isPrivateOrLocalAddressLiteral: Bool {
        if self == "localhost" {
            return true
        }

        if isPrivateIPv4Literal || isLinkLocalIPv4Literal || isLoopbackIPv4Literal {
            return true
        }

        if isLinkLocalIPv6Literal || isLoopbackIPv6Literal {
            return true
        }

        if hasSuffix(".local") || hasSuffix(".localdomain") || hasSuffix(".lan") || hasSuffix(".home") || hasSuffix(".home.arpa") {
            return true
        }

        return !contains(".") && !contains(":")
    }

    nonisolated var ipv4Octets: [Int]? {
        let segments = split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 4 else { return nil }

        var octets: [Int] = []
        octets.reserveCapacity(4)
        for segment in segments {
            guard let octet = Int(segment), (0...255).contains(octet) else {
                return nil
            }
            octets.append(octet)
        }
        return octets
    }

    nonisolated var isPrivateIPv4Literal: Bool {
        guard let octets = ipv4Octets else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    nonisolated var isLinkLocalIPv4Literal: Bool {
        guard let octets = ipv4Octets else { return false }
        return octets[0] == 169 && octets[1] == 254
    }

    nonisolated var isLoopbackIPv4Literal: Bool {
        guard let octets = ipv4Octets else { return false }
        return octets[0] == 127
    }

    nonisolated var isTailscaleIPv4Literal: Bool {
        guard let octets = ipv4Octets else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    nonisolated var isLinkLocalIPv6Literal: Bool {
        hasPrefix("fe80:")
    }

    nonisolated var isLoopbackIPv6Literal: Bool {
        self == "::1"
    }

    nonisolated var isTailscaleIPv6Literal: Bool {
        hasPrefix("fd7a:115c:a1e0:")
    }
}
