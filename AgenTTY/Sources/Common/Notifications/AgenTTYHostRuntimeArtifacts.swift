import CryptoKit
import Foundation

nonisolated enum AgenTTYHostRuntimeArtifactError: LocalizedError {
    case missingBundleVersion
    case invalidManifestURL(String)
    case invalidManifestResponse(Int)
    case invalidBinaryResponse(Int)
    case manifestDecodeFailed
    case missingTarget(String)
    case invalidTarget(String)
    case invalidRelativePath(String)
    case unsupportedSchemaVersion(Int)
    case checksumMismatch(name: String)
    case unavailableCachedManifest

    var errorDescription: String? {
        switch self {
        case .missingBundleVersion:
            "Missing app marketing version."
        case .invalidManifestURL(let value):
            "Invalid host runtime manifest URL: \(value)."
        case .invalidManifestResponse(let statusCode):
            "Unexpected host runtime manifest status code: \(statusCode)."
        case .invalidBinaryResponse(let statusCode):
            "Unexpected host runtime binary status code: \(statusCode)."
        case .manifestDecodeFailed:
            "Failed to decode host runtime manifest."
        case .missingTarget(let target):
            "Host runtime manifest does not contain target \(target)."
        case .invalidTarget(let target):
            "Invalid host runtime manifest target: \(target)."
        case .invalidRelativePath(let path):
            "Invalid host runtime relative path: \(path)."
        case .unsupportedSchemaVersion(let version):
            "Unsupported host runtime manifest schema version: \(version)."
        case .checksumMismatch(let name):
            "Host runtime checksum mismatch for \(name)."
        case .unavailableCachedManifest:
            "No cached host runtime manifest is available."
        }
    }
}

nonisolated struct AgenTTYHostRuntimeArtifactBinaryDescriptor: Decodable, Sendable {
    let url: URL
    let sha256: String
}

nonisolated struct AgenTTYHostRuntimeArtifactManifestTerminfoEntry: Decodable, Sendable {
    let relativePath: String
    let url: URL
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case url
        case sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRelativePath = try container.decode(String.self, forKey: .relativePath)
        relativePath = try Self.validatedRelativePath(decodedRelativePath)
        url = try container.decode(URL.self, forKey: .url)
        sha256 = try container.decode(String.self, forKey: .sha256)
    }

    private static func validatedRelativePath(_ relativePath: String) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = NSString(string: trimmed).pathComponents
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "/._-")
        )
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !components.contains(".."),
              !components.contains("/"),
              trimmed.unicodeScalars.allSatisfy(allowedCharacters.contains) else {
            throw AgenTTYHostRuntimeArtifactError.invalidRelativePath(relativePath)
        }
        return trimmed
    }
}

nonisolated struct AgenTTYHostRuntimeArtifactManifestTarget: Decodable, Sendable {
    let tmux: AgenTTYHostRuntimeArtifactBinaryDescriptor
    let agenttyNotify: AgenTTYHostRuntimeArtifactBinaryDescriptor
    let agenttyHostConnector: AgenTTYHostRuntimeArtifactBinaryDescriptor?
    let terminfoEntries: [AgenTTYHostRuntimeArtifactManifestTerminfoEntry]

    enum CodingKeys: String, CodingKey {
        case tmux
        case agenttyNotify = "agentty_notify"
        case agenttyHostConnector = "agentty_host_connector"
        case terminfoEntries = "terminfo_entries"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tmux = try container.decode(AgenTTYHostRuntimeArtifactBinaryDescriptor.self, forKey: .tmux)
        agenttyNotify = try container.decode(
            AgenTTYHostRuntimeArtifactBinaryDescriptor.self,
            forKey: .agenttyNotify
        )
        agenttyHostConnector = try container.decodeIfPresent(
            AgenTTYHostRuntimeArtifactBinaryDescriptor.self,
            forKey: .agenttyHostConnector
        )
        terminfoEntries = try container.decodeIfPresent(
            [AgenTTYHostRuntimeArtifactManifestTerminfoEntry].self,
            forKey: .terminfoEntries
        ) ?? []
    }
}

nonisolated struct AgenTTYHostRuntimeArtifactManifest: Decodable, Sendable {
    let schemaVersion: Int
    let runtimeVersion: String
    let generatedAt: String
    let targets: [AgenTTYRemoteHostPlatform: AgenTTYHostRuntimeArtifactManifestTarget]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runtimeVersion = "runtime_version"
        case generatedAt = "generated_at"
        case targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        runtimeVersion = try container.decode(String.self, forKey: .runtimeVersion)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)

        let decodedTargets = try container.decode(
            [String: AgenTTYHostRuntimeArtifactManifestTarget].self,
            forKey: .targets
        )
        var typedTargets: [AgenTTYRemoteHostPlatform: AgenTTYHostRuntimeArtifactManifestTarget] = [:]
        for (rawTarget, target) in decodedTargets {
            guard let hostPlatform = AgenTTYRemoteHostPlatform(rawValue: rawTarget) else {
                throw AgenTTYHostRuntimeArtifactError.invalidTarget(rawTarget)
            }
            typedTargets[hostPlatform] = target
        }
        targets = typedTargets
    }

    nonisolated func target(
        for hostPlatform: AgenTTYRemoteHostPlatform
    ) throws -> AgenTTYHostRuntimeArtifactManifestTarget {
        guard let target = targets[hostPlatform] else {
            throw AgenTTYHostRuntimeArtifactError.missingTarget(hostPlatform.rawValue)
        }
        return target
    }
}

nonisolated struct AgenTTYResolvedHostRuntimeArtifacts: Sendable {
    let runtimeVersion: String
    let hostPlatform: AgenTTYRemoteHostPlatform
    let tmuxData: Data
    let tmuxSHA256: String
    let notifyData: Data
    let notifySHA256: String
    let terminfoEntries: [AgenTTYResolvedHostRuntimeArtifactTerminfoEntry]
}

nonisolated struct AgenTTYHostConnectorArtifactReference: Sendable {
    let runtimeVersion: String
    let hostPlatform: AgenTTYRemoteHostPlatform
    let url: URL
    let sha256: String
}

nonisolated struct AgenTTYResolvedHostRuntimeArtifactTerminfoEntry: Sendable {
    let relativePath: String
    let data: Data
    let sha256: String
}

private nonisolated enum AgenTTYHostRuntimeArtifactChannel {
    case release(String)
    case latest(String)

    nonisolated var manifestPath: String {
        switch self {
        case .release(let version):
            "\(version)/host-runtime-manifest.json"
        case .latest:
            "latest.json"
        }
    }

    nonisolated var cacheKey: String {
        switch self {
        case .release(let version):
            "release-\(version)"
        case .latest(let flavor):
            "latest-\(flavor)"
        }
    }
}

extension AgenTTYBuildFlavor {
    fileprivate nonisolated var hostRuntimeArtifactChannel: AgenTTYHostRuntimeArtifactChannel {
        switch self {
        case .main:
            .release(hostRuntimeReleaseVersion)
        case .dev, .exp:
            .latest(rawValue)
        }
    }

    nonisolated var expectedHostRuntimeVersionHint: String? {
        switch self {
        case .main:
            hostRuntimeReleaseVersion
        case .dev, .exp:
            nil
        }
    }

    private nonisolated var hostRuntimeReleaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

private extension Digest {
    nonisolated var lowercaseHexString: String {
        map {
            let value = String($0, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }
}

actor AgenTTYHostRuntimeArtifactStore {
    static let shared = AgenTTYHostRuntimeArtifactStore()

    private static let defaultBaseURL = AgenTTYBuildConfiguration.artifactURL
    private static let baseURLOverrideEnvironmentKey = "AGENTTY_HOST_RUNTIME_ASSET_BASE_URL"

    private let fileManager: FileManager
    private let urlSession: URLSession

    init(fileManager: FileManager = .default, urlSession: URLSession = .shared) {
        self.fileManager = fileManager
        self.urlSession = urlSession
    }

    func resolvedArtifacts(
        for hostPlatform: AgenTTYRemoteHostPlatform,
        buildFlavor: AgenTTYBuildFlavor = .current()
    ) async throws -> AgenTTYResolvedHostRuntimeArtifacts {
        let manifest = try await manifest(for: buildFlavor)
        let target = try manifest.target(for: hostPlatform)
        async let tmuxData = binaryData(
            named: "tmux",
            descriptor: target.tmux,
            runtimeVersion: manifest.runtimeVersion,
            hostPlatform: hostPlatform
        )
        async let notifyData = binaryData(
            named: "agentty-notify",
            descriptor: target.agenttyNotify,
            runtimeVersion: manifest.runtimeVersion,
            hostPlatform: hostPlatform
        )
        var terminfoEntries: [AgenTTYResolvedHostRuntimeArtifactTerminfoEntry] = []
        terminfoEntries.reserveCapacity(target.terminfoEntries.count)
        for descriptor in target.terminfoEntries {
            let data = try await artifactData(
                relativePath: descriptor.relativePath,
                url: descriptor.url,
                expectedSHA256: descriptor.sha256,
                checksumName: descriptor.relativePath,
                runtimeVersion: manifest.runtimeVersion,
                hostPlatform: hostPlatform
            )
            EsmaLog.terminal.info(
                "host runtime terminfo fetched path=\(descriptor.relativePath, privacy: .public) runtime_version=\(manifest.runtimeVersion, privacy: .public) target=\(hostPlatform.rawValue, privacy: .public)"
            )
            terminfoEntries.append(
                AgenTTYResolvedHostRuntimeArtifactTerminfoEntry(
                    relativePath: descriptor.relativePath,
                    data: data,
                    sha256: descriptor.sha256.lowercased()
                )
            )
        }
        return AgenTTYResolvedHostRuntimeArtifacts(
            runtimeVersion: manifest.runtimeVersion,
            hostPlatform: hostPlatform,
            tmuxData: try await tmuxData,
            tmuxSHA256: target.tmux.sha256.lowercased(),
            notifyData: try await notifyData,
            notifySHA256: target.agenttyNotify.sha256.lowercased(),
            terminfoEntries: terminfoEntries
        )
    }

    func hostConnectorReference(
        for hostPlatform: AgenTTYRemoteHostPlatform,
        buildFlavor: AgenTTYBuildFlavor = .current()
    ) async throws -> AgenTTYHostConnectorArtifactReference? {
        let manifest = try await manifest(for: buildFlavor)
        let target = try manifest.target(for: hostPlatform)
        guard let descriptor = target.agenttyHostConnector else {
            return nil
        }
        return AgenTTYHostConnectorArtifactReference(
            runtimeVersion: manifest.runtimeVersion,
            hostPlatform: hostPlatform,
            url: descriptor.url,
            sha256: descriptor.sha256.lowercased()
        )
    }

    func hostConnectorData(
        for reference: AgenTTYHostConnectorArtifactReference
    ) async throws -> Data {
        let data = try await artifactData(
            relativePath: "agentty-host-connector",
            url: reference.url,
            expectedSHA256: reference.sha256,
            checksumName: "agentty-host-connector",
            runtimeVersion: reference.runtimeVersion,
            hostPlatform: reference.hostPlatform
        )
        EsmaLog.terminal.info(
            "host runtime binary fetched name=agentty-host-connector runtime_version=\(reference.runtimeVersion, privacy: .public) target=\(reference.hostPlatform.rawValue, privacy: .public)"
        )
        return data
    }

    private func manifest(
        for buildFlavor: AgenTTYBuildFlavor
    ) async throws -> AgenTTYHostRuntimeArtifactManifest {
        let channel = try manifestChannel(for: buildFlavor)
        let manifestURL = baseURL(for: buildFlavor).appending(path: channel.manifestPath)
        let cacheURL = try manifestCacheURL(for: channel)

        do {
            let (data, response) = try await urlSession.data(from: manifestURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AgenTTYHostRuntimeArtifactError.invalidManifestResponse(-1)
            }
            guard httpResponse.statusCode == 200 else {
                throw AgenTTYHostRuntimeArtifactError.invalidManifestResponse(httpResponse.statusCode)
            }
            let manifest = try decodeManifest(data)
            try writeAtomically(data, to: cacheURL)
            EsmaLog.terminal.info(
                "host runtime manifest fetched url=\(manifestURL.absoluteString, privacy: .public) runtime_version=\(manifest.runtimeVersion, privacy: .public)"
            )
            return manifest
        } catch {
            let cachedManifestData = try cachedManifestData(at: cacheURL)
            let cachedManifest = try decodeManifest(cachedManifestData)
            EsmaLog.terminal.notice(
                "host runtime manifest using cache channel=\(channel.cacheKey, privacy: .public) runtime_version=\(cachedManifest.runtimeVersion, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return cachedManifest
        }
    }

    private func binaryData(
        named name: String,
        descriptor: AgenTTYHostRuntimeArtifactBinaryDescriptor,
        runtimeVersion: String,
        hostPlatform: AgenTTYRemoteHostPlatform
    ) async throws -> Data {
        let data = try await artifactData(
            relativePath: name,
            url: descriptor.url,
            expectedSHA256: descriptor.sha256,
            checksumName: name,
            runtimeVersion: runtimeVersion,
            hostPlatform: hostPlatform
        )

        EsmaLog.terminal.info(
            "host runtime binary fetched name=\(name, privacy: .public) runtime_version=\(runtimeVersion, privacy: .public) target=\(hostPlatform.rawValue, privacy: .public)"
        )
        return data
    }

    private func artifactData(
        relativePath: String,
        url: URL,
        expectedSHA256: String,
        checksumName: String,
        runtimeVersion: String,
        hostPlatform: AgenTTYRemoteHostPlatform
    ) async throws -> Data {
        let cacheURL = try artifactCacheURL(
            runtimeVersion: runtimeVersion,
            hostPlatform: hostPlatform,
            relativePath: relativePath
        )
        if let cachedData = try? Data(contentsOf: cacheURL),
           isExpectedDigest(cachedData, expectedHex: expectedSHA256) {
            return cachedData
        }

        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgenTTYHostRuntimeArtifactError.invalidBinaryResponse(-1)
        }
        guard httpResponse.statusCode == 200 else {
            throw AgenTTYHostRuntimeArtifactError.invalidBinaryResponse(httpResponse.statusCode)
        }
        guard isExpectedDigest(data, expectedHex: expectedSHA256) else {
            throw AgenTTYHostRuntimeArtifactError.checksumMismatch(name: checksumName)
        }

        try writeAtomically(data, to: cacheURL)
        return data
    }

    private func decodeManifest(
        _ data: Data
    ) throws -> AgenTTYHostRuntimeArtifactManifest {
        do {
            let manifest = try JSONDecoder().decode(AgenTTYHostRuntimeArtifactManifest.self, from: data)
            guard manifest.schemaVersion == 1 else {
                throw AgenTTYHostRuntimeArtifactError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch {
            if let artifactError = error as? AgenTTYHostRuntimeArtifactError {
                throw artifactError
            }
            throw AgenTTYHostRuntimeArtifactError.manifestDecodeFailed
        }
    }

    private func cachedManifestData(at cacheURL: URL) throws -> Data {
        guard let data = try? Data(contentsOf: cacheURL) else {
            throw AgenTTYHostRuntimeArtifactError.unavailableCachedManifest
        }
        return data
    }

    private func manifestChannel(
        for buildFlavor: AgenTTYBuildFlavor
    ) throws -> AgenTTYHostRuntimeArtifactChannel {
        let channel = buildFlavor.hostRuntimeArtifactChannel
        if case .release(let version) = channel, version.isEmpty {
            throw AgenTTYHostRuntimeArtifactError.missingBundleVersion
        }
        return channel
    }

    private func baseURL(for buildFlavor: AgenTTYBuildFlavor) -> URL {
        guard let rawValue = ProcessInfo.processInfo.environment[Self.baseURLOverrideEnvironmentKey],
              !rawValue.isEmpty,
              let overrideURL = URL(string: rawValue),
              let scheme = overrideURL.scheme,
              let host = overrideURL.host,
              (scheme == "http" || scheme == "https"),
              !host.isEmpty else {
            return buildFlavor == .main ? AgenTTYBuildConfiguration.releaseArtifactURL : Self.defaultBaseURL
        }
        return overrideURL
    }

    private func cacheRootURL() throws -> URL {
        let rootURL: URL
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AgenTTYSharedDefaults.appGroupIdentifier
        ) {
            rootURL = containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("HostRuntimeArtifacts", isDirectory: true)
        } else {
            rootURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HostRuntimeArtifacts", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return rootURL
    }

    private func manifestCacheURL(
        for channel: AgenTTYHostRuntimeArtifactChannel
    ) throws -> URL {
        try cacheRootURL()
            .appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent("\(channel.cacheKey).json")
    }

    private func artifactCacheURL(
        runtimeVersion: String,
        hostPlatform: AgenTTYRemoteHostPlatform,
        relativePath: String
    ) throws -> URL {
        try cacheRootURL()
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent(runtimeVersion, isDirectory: true)
            .appendingPathComponent(hostPlatform.rawValue, isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func isExpectedDigest(_ data: Data, expectedHex: String) -> Bool {
        SHA256.hash(data: data).lowercaseHexString == expectedHex.lowercased()
    }
}
