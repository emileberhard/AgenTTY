import Foundation

enum AgenTTYPairingDetectedUsernameSource: String, Codable, Hashable, Sendable {
    case accountLookup = "account_lookup"
    case idCommand = "id_command"
    case envUser = "env_user"
    case whoamiCommand = "whoami_command"
}

enum AgenTTYPairingHostEnvironmentFlag: String, Codable, Hashable, Sendable {
    case container
    case wsl
}

enum AgenTTYPairingHostCandidateKind: String, Codable, Hashable, Sendable {
    case tailscaleShort = "tailscale_short"
    case tailscaleFQDN = "tailscale_fqdn"
    case fqdn = "fqdn"
    case singleLabel = "single_label"
    case localDomain = "local_domain"
}

enum AgenTTYPairingHostCandidateSource: String, Codable, Hashable, Sendable {
    case scutilHostname = "scutil_hostname"
    case scutilLocalhostname = "scutil_localhostname"
    case hostnameFQDN = "hostname_fqdn"
    case hostname = "hostname"
    case osHostname = "os_hostname"
    case envHostname = "env_hostname"
    case tailscaleShort = "tailscale_short"
    case tailscaleMagicDNS = "tailscale_magicdns"
    case legacyHostnameCandidates = "legacy_hostname_candidates"
}

struct AgenTTYPairingHostCandidate: Codable, Hashable, Sendable {
    let value: String
    let kind: AgenTTYPairingHostCandidateKind?
    let source: AgenTTYPairingHostCandidateSource?
    let rank: Int?

    private enum CodingKeys: String, CodingKey {
        case value
        case kind
        case source
        case rank
    }

    init(
        value: String,
        kind: AgenTTYPairingHostCandidateKind?,
        source: AgenTTYPairingHostCandidateSource?,
        rank: Int?
    ) {
        self.value = value
        self.kind = kind
        self.source = source
        self.rank = rank
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
            .flatMap(AgenTTYPairingHostCandidateKind.init(rawValue:))
        source = try container.decodeIfPresent(String.self, forKey: .source)
            .flatMap(AgenTTYPairingHostCandidateSource.init(rawValue:))
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(kind?.rawValue, forKey: .kind)
        try container.encodeIfPresent(source?.rawValue, forKey: .source)
        try container.encodeIfPresent(rank, forKey: .rank)
    }
}

struct AgenTTYResolvedPairingHostCandidate: Hashable, Sendable {
    let value: String
    let kind: AgenTTYPairingHostCandidateKind
    let source: AgenTTYPairingHostCandidateSource?
    let rank: Int
}

enum AgenTTYPairingHostCandidateRanking {
    static func resolvedCandidates(
        from completion: AgenTTYPairingSessionCompletionMetadata
    ) -> [AgenTTYResolvedPairingHostCandidate] {
        if !completion.hostCandidates.isEmpty {
            return resolvedCanonicalCandidates(completion.hostCandidates)
        }

        let uniqueCandidates = uniqueCandidates(
            from: synthesizedCandidates(from: completion.hostnameCandidates)
        )

        let shortTailscaleHostnames: Set<String> = Set(
            uniqueCandidates.compactMap { entry -> String? in
                guard entry.candidate.value.isTailscaleMagicDNSHostname else {
                    return nil
                }
                return entry.candidate.value.shortTailscaleHostname?.lowercased()
            }
        )

        return uniqueCandidates
            .map { entry in
                let normalizedValue = entry.candidate.value
                let inferredKind = inferredKind(
                    for: normalizedValue,
                    shortTailscaleHostnames: shortTailscaleHostnames
                )
                return (
                    candidate: AgenTTYResolvedPairingHostCandidate(
                        value: normalizedValue,
                        kind: entry.candidate.kind ?? inferredKind,
                        source: entry.candidate.source,
                        rank: entry.candidate.rank ?? (entry.index + 1)
                    ),
                    index: entry.index
                )
            }
            .sorted { left, right in
                let priorityDelta = priority(for: left.candidate.kind) - priority(for: right.candidate.kind)
                if priorityDelta != 0 {
                    return priorityDelta < 0
                }

                if left.candidate.rank != right.candidate.rank {
                    return left.candidate.rank < right.candidate.rank
                }

                return left.index < right.index
            }
            .map(\.candidate)
    }

    static func isLowConfidence(kind: AgenTTYPairingHostCandidateKind) -> Bool {
        switch kind {
        case .singleLabel, .localDomain:
            true
        case .tailscaleShort, .tailscaleFQDN, .fqdn:
            false
        }
    }

    private static func synthesizedCandidates(
        from hostnameCandidates: [String]
    ) -> [AgenTTYPairingHostCandidate] {
        hostnameCandidates.enumerated().map { index, value in
            AgenTTYPairingHostCandidate(
                value: value,
                kind: nil,
                source: .legacyHostnameCandidates,
                rank: index + 1
            )
        }
    }

    private static func uniqueCandidates(
        from candidates: [AgenTTYPairingHostCandidate]
    ) -> [(candidate: AgenTTYPairingHostCandidate, index: Int)] {
        var uniqueCandidates: [(candidate: AgenTTYPairingHostCandidate, index: Int)] = []
        var seenValues = Set<String>()
        for (index, candidate) in candidates.enumerated() {
            let normalizedValue = AgenTTYHostAddressNormalizer.normalizeForStorage(candidate.value)
            guard !normalizedValue.isEmpty else { continue }
            let dedupeKey = AgenTTYHostAddressNormalizer.normalizeForMatching(normalizedValue)
            guard seenValues.insert(dedupeKey).inserted else { continue }
            uniqueCandidates.append((
                candidate: AgenTTYPairingHostCandidate(
                    value: normalizedValue,
                    kind: candidate.kind,
                    source: candidate.source,
                    rank: candidate.rank
                ),
                index: index
            ))
        }
        return uniqueCandidates
    }

    private static func resolvedCanonicalCandidates(
        _ candidates: [AgenTTYPairingHostCandidate]
    ) -> [AgenTTYResolvedPairingHostCandidate] {
        uniqueCandidates(from: candidates)
            .map { entry in
                AgenTTYResolvedPairingHostCandidate(
                    value: entry.candidate.value,
                    kind: entry.candidate.kind ?? .singleLabel,
                    source: entry.candidate.source,
                    rank: entry.candidate.rank ?? (entry.index + 1)
                )
            }
            .sorted { left, right in
                if left.rank != right.rank {
                    return left.rank < right.rank
                }
                return left.value.localizedCaseInsensitiveCompare(right.value) == .orderedAscending
            }
            .enumerated()
            .map { offset, candidate in
                AgenTTYResolvedPairingHostCandidate(
                    value: candidate.value,
                    kind: candidate.kind,
                    source: candidate.source,
                    rank: offset + 1
                )
            }
    }

    private static func inferredKind(
        for value: String,
        shortTailscaleHostnames: Set<String>
    ) -> AgenTTYPairingHostCandidateKind {
        let normalizedValue = AgenTTYHostAddressNormalizer.normalizeForStorage(value)
        let lowercasedValue = AgenTTYHostAddressNormalizer.normalizeForMatching(normalizedValue)
        if shortTailscaleHostnames.contains(lowercasedValue) {
            return .tailscaleShort
        }
        if normalizedValue.isTailscaleMagicDNSHostname {
            return .tailscaleFQDN
        }
        if lowercasedValue.hasSuffix(".local") || lowercasedValue.hasSuffix(".localdomain") {
            return .localDomain
        }
        if normalizedValue.contains(".") {
            return .fqdn
        }
        return .singleLabel
    }

    private static func priority(for kind: AgenTTYPairingHostCandidateKind) -> Int {
        switch kind {
        case .tailscaleShort:
            0
        case .tailscaleFQDN:
            1
        case .fqdn:
            2
        case .localDomain:
            3
        case .singleLabel:
            4
        }
    }
}

extension AgenTTYResolvedPairingHostCandidate {
    var usesTailscale: Bool {
        switch kind {
        case .tailscaleShort, .tailscaleFQDN:
            true
        case .fqdn, .singleLabel, .localDomain:
            false
        }
    }
}

extension String {
    var isTailscaleMagicDNSHostname: Bool {
        let normalized = AgenTTYHostAddressNormalizer.normalizeForMatching(self)
        return normalized.hasSuffix(".ts.net") && normalized.contains(".")
    }

    var shortTailscaleHostname: String? {
        guard isTailscaleMagicDNSHostname else { return nil }
        let trimmed = AgenTTYHostAddressNormalizer.normalizeForStorage(self)
        let firstLabel = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first
        let normalized = firstLabel.map { AgenTTYHostAddressNormalizer.normalizeForStorage(String($0)) }
        return normalized?.isEmpty == false ? normalized : nil
    }
}
