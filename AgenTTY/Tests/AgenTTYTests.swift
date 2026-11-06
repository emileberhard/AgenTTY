import CoreGraphics
import Foundation
import UIKit
import UniformTypeIdentifiers
import Testing
@testable import AgenTTY_iOS

private struct TestTerminalClipboardPasteboard: TerminalClipboardPasteboard {
    var hasImages: Bool
    var hasFiles: Bool
    var itemProviders: [any TerminalClipboardItemProvider]
    var hasStrings: Bool
    var string: String?
}

private struct TestTerminalClipboardItemProvider: TerminalClipboardItemProvider {
    var registeredImageContentTypes: [UTType] = []
    var registeredContentTypes: [UTType] = []
    var registeredContentTypesForOpenInPlace: [UTType] = []
    var suggestedName: String?
    var canLoadUIImage = false
    var dataRepresentations: [String: Data] = [:]
    var fileRepresentations: [String: URL] = [:]

    func loadDataRepresentation(for contentType: UTType) async -> Data? {
        dataRepresentations[contentType.identifier]
    }

    func loadUIImage() async -> UIImage? {
        nil
    }

    func loadFileRepresentation(for contentType: UTType) async -> URL? {
        fileRepresentations[contentType.identifier]
    }
}

@Suite
struct AgenTTYTests {
    @Test
    func elevenLabsRealtimeIsTheDefaultDirectDictationModel() {
        #expect(AgenTTYDictation.defaultModel == .elevenLabsScribeV2Realtime)
        #expect(AgenTTYDictation.defaultModel.capture == .streaming)
    }

    @Test
    func persistedProviderSelectionsFromBeforeTheModelPickerStillResolve() {
        #expect(AgenTTYDictation.Model(rawValue: "elevenLabs") == .elevenLabsScribeV2Realtime)
        #expect(AgenTTYDictation.Model(rawValue: "openai") == .openAIGPT4oMiniTranscribe)
        #expect(AgenTTYDictation.Model(rawValue: "gemini") == .gemini31Pro)
    }

    @MainActor
    @Test
    func dictationKeyMatchesBottomRowActionKeyWidth() throws {
        let letterBottomRow = try #require(KeyboardLayouts.letterRows().last)
        let symbolBottomRow = try #require(KeyboardLayouts.symbolRows.last)

        for row in [letterBottomRow, symbolBottomRow] {
            let dictationKey = try #require(row.first { $0.action == .dictation })
            let enterKey = try #require(row.first { $0.action == .enter })
            let symbolLayerKey = try #require(row.first { $0.action == .symbolLayer })

            #expect(dictationKey.widthWeight == enterKey.widthWeight)
            #expect(dictationKey.widthWeight == symbolLayerKey.widthWeight)
        }
    }

    @MainActor
    @Test
    func symbolsLayerCoversEveryShellPunctuationCharacter() {
        let symbolChars = Set(
            KeyboardLayouts.symbolRows.flatMap { $0 }.compactMap { key -> String? in
                guard case .character(let c) = key.action else { return nil }
                return c
            }
        )
        let letterChars = Set(
            KeyboardLayouts.letterRows().flatMap { $0 }.compactMap { key -> String? in
                guard case .character(let c) = key.action else { return nil }
                return c
            }
        )

        let required = Set("0123456789-/:;()$&@\"[]{}#%^*+=_\\|<>,!?'`".map(String.init))
        #expect(required.isSubset(of: symbolChars), "missing: \(required.subtracting(symbolChars))")
        #expect(letterChars.contains("~"))
        #expect(letterChars.contains("."))
    }

    @MainActor
    @Test
    func symbolsLayerKeyIDsAreUniqueWithinTheMountedLayer() {
        for rows in [KeyboardLayouts.symbolRows, KeyboardLayouts.letterRows()] {
            let ids = rows.flatMap { $0 }.map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate key id inside one mounted layer")
        }
    }

    @MainActor
    @Test
    func symbolsCharacterRowsAreTenKeysWide() {
        let charRows = KeyboardLayouts.symbolRows.dropLast()
        for row in charRows {
            #expect(row.count == 10)
        }
    }

    @Test
    func elapsedMillisecondsUsesMonotonicNanoseconds() {
        #expect(EsmaDiagnostics.elapsedMilliseconds(
                since: 1_000_000,
                nowNanoseconds: 3_500_000
            ) == 2)
        #expect(EsmaDiagnostics.elapsedMilliseconds(
                since: 2_000_000,
                nowNanoseconds: 1_000_000
            ) == 0)
    }

    @MainActor
    @Test
    func keyCalloutRowsTrackSimultaneousPressesAndDeactivateCleanly() {
        let keyboardState = KeyboardState()

        keyboardState.beginKeyCallout(id: "char-q", rowIndex: 1)
        keyboardState.beginKeyCallout(id: "char-a", rowIndex: 2)

        #expect(keyboardState.hasActiveKeyCallout(in: 1))
        #expect(keyboardState.hasActiveKeyCallout(in: 2))

        keyboardState.endKeyCallout(id: "char-q")

        #expect(!keyboardState.hasActiveKeyCallout(in: 1))
        #expect(keyboardState.hasActiveKeyCallout(in: 2))

        keyboardState.handleAppWillDeactivate()

        #expect(!keyboardState.hasActiveKeyCallout(in: 2))
    }

    @MainActor
    @Test
    func hostDecodesLegacyNameKeyIntoLabel() throws {
        let json = #"""
        {
          "id": "6F31FDF8-1CC0-4DD0-9F80-2A30FCF0A5A6",
          "name": "dev-host",
          "address": "100.64.0.10",
          "port": 22,
          "username": "developer",
          "authentication": {
            "mode": "key",
            "keyID": "3E3BFEB7-2E7E-4B68-9A89-9A28F11B2A63"
          }
        }
        """#

        let host = try JSONDecoder().decode(AgenTTYHost.self, from: Data(json.utf8))

        #expect(host.label == "dev-host")
        #expect(host.address == "100.64.0.10")
    }

    @MainActor
    @Test
    func hostEncodesLabelKey() throws {
        let host = AgenTTYHost(
            id: UUID(uuidString: "6F31FDF8-1CC0-4DD0-9F80-2A30FCF0A5A6")!,
            label: "macbook",
            address: "backup-host",
            port: 22,
            username: "developer",
            authentication: .key(UUID(uuidString: "3E3BFEB7-2E7E-4B68-9A89-9A28F11B2A63")!)
        )

        let encoded = try JSONEncoder().encode(host)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["label"] as? String == "macbook")
        #expect(object["name"] == nil)
    }

    @MainActor
    @Test
    func hostDecodingPrefersLabelOverLegacyNameWhenBothArePresent() throws {
        let json = #"""
        {
          "id": "6F31FDF8-1CC0-4DD0-9F80-2A30FCF0A5A6",
          "label": "macbook",
          "name": "dev-host",
          "address": "backup-host",
          "port": 22,
          "username": "developer",
          "authentication": {
            "mode": "key",
            "keyID": "3E3BFEB7-2E7E-4B68-9A89-9A28F11B2A63"
          }
        }
        """#

        let host = try JSONDecoder().decode(AgenTTYHost.self, from: Data(json.utf8))

        #expect(host.label == "macbook")
    }

    @MainActor
    @Test
    func pairingCandidateRankingPrefersLocalDomainOverSingleLabelForLegacyCandidates() throws {
        let json = #"""
        {
          "detected_username": "developer",
          "hostname_candidates": ["agentty", "agentty.local"],
          "uses_tailscale": false,
          "port": 22,
          "platform": "linux"
        }
        """#

        let completion = try JSONDecoder().decode(
            AgenTTYPairingSessionCompletionMetadata.self,
            from: Data(json.utf8)
        )
        let ranked = AgenTTYPairingHostCandidateRanking.resolvedCandidates(from: completion)

        #expect(ranked.map { $0.value } == ["agentty.local", "agentty"])
        #expect(ranked.map { $0.kind } == [.localDomain, .singleLabel])
    }

    @MainActor
    @Test
    func pairingCandidateRankingPreservesRelayProvidedRankForCanonicalCandidates() throws {
        let json = #"""
        {
          "detected_username": "developer",
          "host_candidates": [
            {
              "value": "agentty",
              "kind": "single_label",
              "source": "hostname",
              "rank": 1
            },
            {
              "value": "agentty.local",
              "kind": "local_domain",
              "source": "hostname_fqdn",
              "rank": 2
            }
          ],
          "hostname_candidates": ["agentty.local", "agentty"],
          "uses_tailscale": false,
          "port": 22,
          "platform": "linux"
        }
        """#

        let completion = try JSONDecoder().decode(
            AgenTTYPairingSessionCompletionMetadata.self,
            from: Data(json.utf8)
        )
        let ranked = AgenTTYPairingHostCandidateRanking.resolvedCandidates(from: completion)

        #expect(ranked.map { $0.value } == ["agentty", "agentty.local"])
        #expect(ranked.map { $0.rank } == [1, 2])
    }

    @MainActor
    @Test
    func pairingCandidateRankingCompactsCanonicalRanksAfterDeduplication() throws {
        let json = #"""
        {
          "detected_username": "developer",
          "host_candidates": [
            {
              "value": "agentty",
              "kind": "single_label",
              "source": "hostname",
              "rank": 2
            },
            {
              "value": "agentty",
              "kind": "single_label",
              "source": "hostname",
              "rank": 3
            }
          ],
          "hostname_candidates": [],
          "uses_tailscale": false,
          "port": 22,
          "platform": "linux"
        }
        """#

        let completion = try JSONDecoder().decode(
            AgenTTYPairingSessionCompletionMetadata.self,
            from: Data(json.utf8)
        )
        let ranked = AgenTTYPairingHostCandidateRanking.resolvedCandidates(from: completion)

        #expect(ranked.map { $0.value } == ["agentty"])
        #expect(ranked.map { $0.rank } == [1])
    }

    @MainActor
    @Test
    func pairingSessionCompletionMetadataDecodesUsernameDiagnosticsAndEnvironmentFlags() throws {
        let json = #"""
        {
          "detected_username": "developer",
          "detected_username_source": "whoami_command",
          "detected_username_suspicious": true,
          "host_environment_flags": ["wsl", "container"],
          "host_candidates": [
            {
              "value": "agentty",
              "kind": "single_label",
              "source": "hostname",
              "rank": 1
            }
          ],
          "hostname_candidates": ["agentty"],
          "uses_tailscale": false,
          "port": 22,
          "platform": "linux"
        }
        """#

        let completion = try JSONDecoder().decode(
            AgenTTYPairingSessionCompletionMetadata.self,
            from: Data(json.utf8)
        )

        #expect(completion.detectedUsername == "developer")
        #expect(completion.detectedUsernameSource == .whoamiCommand)
        #expect(completion.detectedUsernameSuspicious == true)
        #expect(completion.hostEnvironmentFlags == [.wsl, .container])
    }

    @MainActor
    @Test
    func hostStoreAddHostMatchReturnsExactMatchForNormalizedAddress() throws {
        let suiteName = "AgenTTYTests.HostStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgenTTYHostStore(userDefaults: defaults, flavor: .main)
        let existingHostID = store.addHost(
            try #require(AgenTTYHostDraft(
                    label: "Mac",
                    address: "Agentty.Local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
                ))
        )

        let match = store.addHostMatch(
            for: try #require(AgenTTYHostDraft(
                    label: "Mac Again",
                    address: "agentty.local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!)
                ))
        )

        guard case .exact(let existingHost)? = match else {
            Issue.record("Expected an exact host match.")
            return
        }

        #expect(existingHost.id == existingHostID)
    }

    @MainActor
    @Test
    func hostAddressNormalizationTrimsInvisibleWhitespaceAndUnicodeDashes() throws {
        let draft = try #require(AgenTTYHostDraft(
                label: "Mac",
                address: "\u{200B} dev\u{2011}host \u{FEFF}",
                port: 22,
                username: "developer",
                authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
            ))

        #expect(draft.address == "dev-host")
        #expect(AgenTTYHostStore.normalizedAddress("Dev\u{2011}Host") == "dev-host")
    }

    @Test
    func dnsReachabilityErrorUsesDNSRecoveryGuidance() {
        let error = AgenTTYHostReachabilityError.failed(
            host: "dev-host",
            port: 22,
            reason: "No such host",
            subtype: .dns
        )
        let guidance = AgenTTYHostReachabilityGuidance.guidance(for: error)

        #expect(error.localizedDescription == "The hostname dev-host does not resolve from this iPhone.")
        #expect(guidance.title == "Hostname Does Not Resolve")
        #expect(guidance.message.contains("does not resolve from this iPhone"))
        #expect(guidance.suggestions.contains { $0.title == "Use an IP address" })
        #expect(guidance.suggestions.contains { $0.title == "Try the full Tailscale name" })
        #expect(guidance.suggestions.contains { $0.title == "Try the .local name" })
        #expect(guidance.suggestions.contains { $0.title == "Run Automatic Setup again" })
    }

    @MainActor
    @Test
    func preReadyFailureCircuitBreakerTripsOnThirdFailureWithinWindow() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        let first = breaker.recordFailure(hostID: hostID, authMode: .key, category: .other, at: startedAt)
        #expect(!first)
        let second = breaker.recordFailure(hostID: hostID, authMode: .key, category: .other, at: startedAt.addingTimeInterval(10))
        #expect(!second)
        let third = breaker.recordFailure(hostID: hostID, authMode: .key, category: .other, at: startedAt.addingTimeInterval(20))
        #expect(third)
    }

    @MainActor
    @Test
    func preReadyFailureCircuitBreakerIgnoresTransientNetworkCategories() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        let transientCategories: [AgenTTYSSHDisconnectCategory] = [
            .connectTimeout, .networkError, .transportClosed,
        ]
        for (index, category) in transientCategories.enumerated() {
            for attempt in 0..<5 {
                let tripped = breaker.recordFailure(hostID: hostID, authMode: .key, category: category, at: startedAt.addingTimeInterval(Double(index * 10 + attempt)))
                #expect(!tripped, "transient category \(category) must never trip the breaker")
            }
        }

        // Transient failures must not have advanced the countable streak either.
        let afterTransients = breaker.recordFailure(hostID: hostID, authMode: .key, category: .other, at: startedAt.addingTimeInterval(50))
        #expect(!afterTransients)
    }

    @MainActor
    @Test
    func unknownClientBootstrapChannelFailureIsTransientNetworkFailure() {
        let error = NSError(domain: "NIOCore.ChannelError", code: 0)
        let outcome = SSHClientSession.connectFailureOutcome(
            for: error,
            rawReason: "connect failed: NIOCore.ChannelError error 0"
        )

        #expect(outcome.category == .networkError)
        #expect(outcome.failureStage == .tcpConnect)
        #expect(outcome.shouldReconnect)
        #expect(!AgenTTYPreReadyFailureCircuitBreaker.countsTowardTrip(outcome.category))
    }

    @MainActor
    @Test
    func relayResolutionFailureRearmsDirectProbeForNextRetry() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        AgenTTYConnectionRouteResolver.invalidateRouteMemory()
        defer { AgenTTYConnectionRouteResolver.invalidateRouteMemory() }

        AgenTTYConnectionRouteResolver.recordDirectRouteFailure(for: hostID)
        #expect(AgenTTYConnectionRouteResolver.shouldPreferRelay(for: hostID))

        AgenTTYConnectionRouteResolver.recordRelayResolutionFailure(for: hostID)
        #expect(!AgenTTYConnectionRouteResolver.shouldPreferRelay(for: hostID))
    }

    @MainActor
    @Test
    func preReadyFailureCircuitBreakerResetsForNewHostOrExpiredWindow() {
        let firstHostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondHostID = UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        let firstHost = breaker.recordFailure(hostID: firstHostID, authMode: .key, category: .other, at: startedAt)
        #expect(!firstHost)
        let secondHost = breaker.recordFailure(hostID: secondHostID, authMode: .key, category: .other, at: startedAt.addingTimeInterval(10))
        #expect(!secondHost)

        breaker.reset()
        let afterReset = breaker.recordFailure(hostID: firstHostID, authMode: .key, category: .other, at: startedAt)
        #expect(!afterReset)
        let afterWindow = breaker.recordFailure(hostID: firstHostID, authMode: .key, category: .other, at: startedAt.addingTimeInterval(61))
        #expect(!afterWindow)
    }

    @MainActor
    @Test
    func hostStoreAddHostMatchReturnsRelatedMatchForAutomaticCandidateAlias() throws {
        let suiteName = "AgenTTYTests.HostStoreRelated.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgenTTYHostStore(userDefaults: defaults, flavor: .main)
        let existingHostID = store.addHost(
            try #require(AgenTTYHostDraft(
                    label: "Mac",
                    address: "agentty.local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
                ))
        )

        let match = store.addHostMatch(
            for: try #require(AgenTTYHostDraft(
                    label: "Mac Alias",
                    address: "agentty",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!)
                )),
            relatedAddresses: ["agentty.local", "agentty"]
        )

        guard case .related(let existingHost)? = match else {
            Issue.record("Expected a related host match.")
            return
        }

        #expect(existingHost.id == existingHostID)
    }

    @MainActor
    @Test
    func sheetNavigationCoordinatorResetToRootClearsNavigationStateAndRestoresMediumDetent() {
        let coordinator = SheetNavigationCoordinator<String>()
        coordinator.path = ["automatic", "review"]
        coordinator.pendingRoute = "stale"
        coordinator.selectedDetent = .large

        coordinator.resetToRoot()

        #expect(coordinator.path.isEmpty)
        #expect(coordinator.pendingRoute == nil)
        #expect(coordinator.selectedDetent == .medium)
    }

    @MainActor
    @Test
    func hostListReachabilityTrackerUsesWarningOnlyForFirstFailureAfterSuccess() {
        var tracker = HostListReachabilityTracker()

        #expect(tracker.indicatorState == .checking)

        tracker.recordSuccess()
        #expect(tracker.indicatorState == .reachable)

        tracker.recordFailure()
        #expect(tracker.indicatorState == .warning)

        tracker.recordFailure()
        #expect(tracker.indicatorState == .unreachable)
    }

    @MainActor
    @Test
    func hostListReachabilityTrackerStartsRedWhenInitialCheckFails() {
        var tracker = HostListReachabilityTracker()

        tracker.recordFailure()

        #expect(tracker.indicatorState == .unreachable)
    }

    @MainActor
    @Test
    func hostListReachabilityTrackerCanTemporarilyReturnToCheckingDuringManualRefresh() {
        var tracker = HostListReachabilityTracker()

        tracker.recordSuccess()
        #expect(tracker.indicatorState == .reachable)

        tracker.beginCheck()
        #expect(tracker.indicatorState == .checking)

        tracker.recordFailure(message: "AgenTTY could not reach backup-host:22.")
        #expect(tracker.indicatorState == .warning)
        #expect(tracker.lastFailureMessage == "AgenTTY could not reach backup-host:22.")
    }

    @Test
    func hostRuntimeManifestDecodesTerminfoEntries() throws {
        let json = #"""
        {
          "schema_version": 1,
          "runtime_version": "latest-1234567890ab",
          "generated_at": "2026-04-08T20:00:00Z",
          "source_hashes": {
            "agentty_notify": "notify-source",
            "agentty_host_connector": "connector-source"
          },
          "targets": {
            "linux-arm64": {
              "tmux": {
                "url": "https://example.com/linux-arm64/tmux",
                "sha256": "aaa"
              },
              "agentty_notify": {
                "url": "https://example.com/linux-arm64/agentty-notify",
                "sha256": "bbb"
              },
              "agentty_host_connector": {
                "url": "https://example.com/linux-arm64/agentty-host-connector",
                "sha256": "connector-sha"
              },
              "terminfo_entries": [
                {
                  "relative_path": "74/tmux-256color",
                  "url": "https://example.com/linux-arm64/terminfo/74/tmux-256color",
                  "sha256": "ccc"
                },
                {
                  "relative_path": "78/xterm-256color",
                  "url": "https://example.com/linux-arm64/terminfo/78/xterm-256color",
                  "sha256": "ddd"
                }
              ]
            }
          }
        }
        """#

        let manifest = try JSONDecoder().decode(
            AgenTTYHostRuntimeArtifactManifest.self,
            from: Data(json.utf8)
        )

        #expect((try manifest.target(for: .linuxArm64).terminfoEntries.map(\.relativePath)) == ["74/tmux-256color", "78/xterm-256color"])
        #expect((try manifest.target(for: .linuxArm64).agenttyHostConnector?.sha256) == "connector-sha")
    }

    @Test
    func hostRuntimeManifestRejectsInvalidTerminfoRelativePaths() {
        let json = #"""
        {
          "schema_version": 1,
          "runtime_version": "latest-1234567890ab",
          "generated_at": "2026-04-08T20:00:00Z",
          "targets": {
            "linux-arm64": {
              "tmux": {
                "url": "https://example.com/linux-arm64/tmux",
                "sha256": "aaa"
              },
              "agentty_notify": {
                "url": "https://example.com/linux-arm64/agentty-notify",
                "sha256": "bbb"
              },
              "terminfo_entries": [
                {
                  "relative_path": "../tmux-256color",
                  "url": "https://example.com/linux-arm64/terminfo/t/tmux-256color",
                  "sha256": "ccc"
                }
              ]
            }
          }
        }
        """#

        #expect(throws: (any Error).self) { try JSONDecoder().decode(
                AgenTTYHostRuntimeArtifactManifest.self,
                from: Data(json.utf8)
            ) }
    }

    @Test
    func hostRuntimeTerminfoPathsUseManagedShareDirectory() {
        #expect(AgenTTYHostRuntime.terminfoRootRemotePath == "$HOME/.agentty/share/terminfo")
        #expect(AgenTTYHostRuntime.terminfoEntryRemotePath(relativePath: "74/tmux-256color") == "$HOME/.agentty/share/terminfo/74/tmux-256color")
    }

    @Test
    func remoteFileWriteStagesAndVerifiesBeforeAtomicReplacement() throws {
        let command = SSHClientSession.remoteFileWriteCommand(
            for: "$HOME/.agentty/libexec/tmux",
            executable: true,
            expectedByteCount: 1_089_320,
            expectedSHA256: "abc123"
        )

        #expect(command.contains(#"tmp_path="${target_path}.part.$$""#))
        #expect(command.contains(#"[ "$actual_byte_count" != "1089320" ]"#))
        #expect(command.contains("sha256sum"))
        #expect(command.contains("shasum -a 256"))
        #expect(command.contains(#"chmod 700 "$tmp_path""#))
        #expect(command.contains(#"mv -f "$tmp_path" "$target_path""#))

        let byteCountCheck = try #require(command.range(of: "actual_byte_count="))
        let checksumCheck = try #require(command.range(of: "actual_sha256="))
        let permissionChange = try #require(command.range(of: #"chmod 700 "$tmp_path""#))
        let replacement = try #require(command.range(of: #"mv -f "$tmp_path" "$target_path""#))
        #expect(byteCountCheck.lowerBound < checksumCheck.lowerBound)
        #expect(checksumCheck.lowerBound < permissionChange.lowerBound)
        #expect(permissionChange.lowerBound < replacement.lowerBound)
    }

    @Test
    func relayConnectorActivationProbesBeforeAtomicReplacementAndRestart() throws {
        let command = AgenTTYHostRuntimeProvisioner.relayConnectorActivationCommand(
            candidateRemotePath: "$HOME/.agentty/libexec/agentty-host-connector.update.test"
        )

        let probe = try #require(command.range(of: "probe-control --config"))
        let replacement = try #require(command.range(of: #"mv -f "$candidate_path" "$target_path""#))
        let restart = try #require(command.range(of: #"kill -TERM "$pid""#))
        #expect(probe.lowerBound < replacement.lowerBound)
        #expect(replacement.lowerBound < restart.lowerBound)
        #expect(command.contains(#"[ "$command" = "$expected_command" ]"#))
    }

    @Test
    func hostRuntimeIntegrityManifestIsStableAndUsesManagedRelativePaths() {
        let artifacts = AgenTTYResolvedHostRuntimeArtifacts(
            runtimeVersion: "2.8.4",
            hostPlatform: .darwinArm64,
            tmuxData: Data("tmux".utf8),
            tmuxSHA256: "tmux-hash",
            notifyData: Data("notify".utf8),
            notifySHA256: "notify-hash",
            terminfoEntries: [
                AgenTTYResolvedHostRuntimeArtifactTerminfoEntry(
                    relativePath: "78/xterm-256color",
                    data: Data("xterm".utf8),
                    sha256: "xterm-hash"
                ),
                AgenTTYResolvedHostRuntimeArtifactTerminfoEntry(
                    relativePath: "74/tmux-256color",
                    data: Data("terminfo".utf8),
                    sha256: "terminfo-hash"
                ),
            ]
        )

        #expect(AgenTTYHostRuntimeProvisioner.runtimePayloadIntegrityManifest(for: artifacts) == """
            tmux-hash  libexec/tmux
            notify-hash  libexec/agentty-notify
            terminfo-hash  share/terminfo/74/tmux-256color
            xterm-hash  share/terminfo/78/xterm-256color
            """)
    }

    @Test
    func tmuxBootstrapCommandRunsBundledBootstrapViaPOSIXSh() {
        let command = AgenTTYConnection.tmuxBootstrapCommand
        #expect(command.contains("exec /bin/sh -lc"))
        #expect(command.contains("agentty-bootstrap"))
    }

    @Test
    func tmuxBootstrapCommandAvoidsSystemTmuxFallbacks() {
        let command = AgenTTYConnection.tmuxBootstrapCommand
        #expect(!command.contains("command -v tmux"))
        #expect(!command.contains("tmux-resurrect"))
        #expect(!command.contains("brew install tmux"))
        #expect(!command.contains("/bin/zsh -lc"))
    }

    @MainActor
    @Test
    func tmuxCommandBuildersUseBundledWrapperPath() {
        #expect(AgenTTYHostRuntime.tmuxWrapperRemotePath == "$HOME/.agentty/bin/tmux")
        #expect(TerminalBridge.tmuxListWindowsCommand.contains(AgenTTYHostRuntime.tmuxWrapperShellLiteral))
        #expect(SSHClientSession.tmuxDictationInsertCommand(for: "hello")
                .contains(AgenTTYHostRuntime.tmuxWrapperShellLiteral))
    }

    @MainActor
    @Test
    func clipboardImagePasteEventDelayIsOnlyUsedForMultiImagePaste() {
        #expect(TerminalBridge.clipboardImagePasteEventDelayNanoseconds(forImageCount: 1) == nil)
        #expect(TerminalBridge.clipboardImagePasteEventDelayNanoseconds(forImageCount: 3) == 500_000_000)
    }

    @MainActor
    @Test
    func clipboardPlainTextStillResolvesAsText() async {
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: false,
            hasFiles: false,
            itemProviders: [],
            hasStrings: true,
            string: "hello"
        )

        let payload = await TerminalClipboard.generalPastePayload(pasteboard: pasteboard)

        guard case .text(let text)? = payload else {
            Issue.record("expected plain text payload")
            return
        }
        #expect(text == "hello")
    }

    @MainActor
    @Test
    func clipboardTextFilePayloadBeatsPlainTextFallback() async throws {
        let fileURL = try makeTemporaryClipboardTestFile(
            named: "notes.txt",
            contents: Data("hello".utf8)
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let provider = TestTerminalClipboardItemProvider(
            registeredContentTypes: [.plainText],
            suggestedName: "notes.txt",
            dataRepresentations: [:],
            fileRepresentations: [UTType.plainText.identifier: fileURL]
        )
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: false,
            hasFiles: true,
            itemProviders: [provider],
            hasStrings: true,
            string: "hello"
        )

        let payload = await TerminalClipboard.generalPastePayload(pasteboard: pasteboard)

        guard case .files(let fileProviders)? = payload else {
            Issue.record("expected file payload")
            return
        }
        #expect(fileProviders.count == 1)
        guard let filePayload = await fileProviders[0].loadFilePayload() else {
            Issue.record("expected resolved file payload")
            return
        }
        let filename = filePayload.filename
        let byteCount = filePayload.byteCount
        #expect(filename == "notes.txt")
        #expect(byteCount == 5)
        TerminalClipboard.removeTemporaryFile(at: filePayload.localFileURL)
    }

    @MainActor
    @Test
    func clipboardImagesStillWinOverGenericFiles() async throws {
        let fileURL = try makeTemporaryClipboardTestFile(
            named: "document.pdf",
            contents: Data([0x25, 0x50, 0x44, 0x46])
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let provider = TestTerminalClipboardItemProvider(
            registeredImageContentTypes: [.png],
            registeredContentTypes: [.pdf],
            registeredContentTypesForOpenInPlace: [.pdf],
            suggestedName: "document.pdf",
            canLoadUIImage: false,
            dataRepresentations: [UTType.png.identifier: Data([0x89, 0x50, 0x4E, 0x47])],
            fileRepresentations: [UTType.pdf.identifier: fileURL]
        )
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: true,
            hasFiles: true,
            itemProviders: [provider],
            hasStrings: false,
            string: nil
        )

        let payload = await TerminalClipboard.generalPastePayload(pasteboard: pasteboard)

        guard case .images(let imagePayloads)? = payload else {
            Issue.record("expected image payload")
            return
        }
        #expect(imagePayloads.count == 1)
        let preferredExtension = imagePayloads[0].preferredExtension
        #expect(preferredExtension == "png")
    }

    @MainActor
    @Test
    func clipboardDataOnlyGenericProviderDoesNotResolveAsFile() async {
        let provider = TestTerminalClipboardItemProvider(
            registeredContentTypes: [.pdf],
            suggestedName: "paper.pdf",
            dataRepresentations: [UTType.pdf.identifier: Data([0x25, 0x50, 0x44, 0x46])]
        )
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: false,
            hasFiles: true,
            itemProviders: [provider],
            hasStrings: false,
            string: nil
        )

        let payload = await TerminalClipboard.generalPastePayload(pasteboard: pasteboard)

        guard case .files(let fileProviders)? = payload else {
            Issue.record("expected provider-backed file payload")
            return
        }
        #expect(fileProviders.count == 1)
        let resolvedPayload = await fileProviders[0].loadFilePayload()
        #expect(resolvedPayload == nil)
    }

    @Test
    func clipboardGenericFileTypeFilterRejectsDirectoriesAndURLs() {
        #expect(!TerminalClipboard.isSupportedGenericFileContentType(.directory))
        #expect(!TerminalClipboard.isSupportedGenericFileContentType(.folder))
        #expect(!TerminalClipboard.isSupportedGenericFileContentType(.url))
        #expect(TerminalClipboard.isSupportedGenericFileContentType(.pdf))
        #expect(TerminalClipboard.isSupportedGenericFileContentType(.movie))
        #expect(TerminalClipboard.isSupportedGenericFileContentType(.plainText))
    }

    @MainActor
    @Test
    func clipboardPasteAvailabilityIncludesSupportedFiles() {
        let provider = TestTerminalClipboardItemProvider(
            registeredContentTypes: [.pdf],
            registeredContentTypesForOpenInPlace: [.pdf],
            suggestedName: "paper.pdf"
        )
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: false,
            hasFiles: true,
            itemProviders: [provider],
            hasStrings: false,
            string: nil
        )

        #expect(TerminalClipboard.hasPasteableContent(pasteboard: pasteboard))
    }

    @MainActor
    @Test
    func remoteClipboardFilePathPreservesFilenameExtension() {
        let path = TerminalClipboard.remoteClipboardFilePath(
            filename: "My Report 2026.final.pdf",
            preferredExtension: nil
        )

        #expect(path.hasPrefix("/tmp/agentty-clipboard-"))
        #expect(path.hasSuffix(".pdf"))
        #expect(path.contains("-MyReport2026final"))
    }

    @MainActor
    @Test
    func remoteClipboardFilePathFallsBackToPreferredExtension() {
        let path = TerminalClipboard.remoteClipboardFilePath(
            filename: "video",
            preferredExtension: "mp4"
        )

        #expect(path.hasSuffix(".mp4"))
    }

    @MainActor
    @Test
    func clipboardTemporaryFileCleanupRemovesOwnedFiles() throws {
        let fileURL = try makeTemporaryClipboardTestFile(
            named: "cleanup.txt",
            contents: Data("bye".utf8)
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let payload = TerminalClipboardFilePayload(
            localFileURL: fileURL,
            contentType: .plainText,
            filename: "cleanup.txt",
            byteCount: 3
        )

        TerminalClipboard.removeTemporaryFiles(for: [payload])

        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    @MainActor
    @Test
    func ghosttyWindowPaddingCLIValueEncoding() {
        #expect(AgenTTYGhosttyConfig.WindowPadding(topLeft: 3, bottomRight: 3).cliValue == "3")
        #expect(AgenTTYGhosttyConfig.WindowPadding(topLeft: 1, bottomRight: 4).cliValue == "1,4")
    }

    @MainActor
    @Test
    func backspaceRepeatAccelerationIsMonotonicAndCappedAfterRamp() {
        guard case .accelerated(let behavior) = KeyAction.backspace.repeatBehavior else {
            Issue.record("backspace should use accelerated repeat behavior")
            return
        }

        let checkpoints: [TimeInterval] = [0, 0.5, 1, 2, 4, 6, 8, 10, 12]
        let intervals = checkpoints.map { behavior.interval(forHoldDuration: $0) }

        for index in 1..<intervals.count {
            #expect(intervals[index] <= intervals[index - 1] + 0.000_001)
        }

        #expect(abs(intervals[7] - intervals[8]) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func backspaceRepeatHitsConfiguredPeakAtTenSeconds() {
        guard case .accelerated(let behavior) = KeyAction.backspace.repeatBehavior else {
            Issue.record("backspace should use accelerated repeat behavior")
            return
        }

        let peakInterval = 1 / behavior.maximumRatePerSecond
        #expect(abs(behavior.maximumRatePerSecond - 140) <= 0.000_000_1)
        #expect(abs(behavior.interval(forHoldDuration: 10) - peakInterval) <= 0.000_000_1)
        #expect(abs(behavior.interval(forHoldDuration: 16) - peakInterval) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func standardRepeatProfileIsUnchangedForCharacterKeys() {
        guard case .fixed(let behavior) = KeyAction.character("x").repeatBehavior else {
            Issue.record("character keys should use fixed repeat behavior")
            return
        }

        #expect(abs(behavior.initialDelay - 0.45) <= 0.000_000_1)
        #expect(abs(behavior.interval - 0.065) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func repeatAccelerationCurveReachesConfiguredMultiplierAtTenSeconds() {
        let curve = RepeatAccelerationCurve(
            rampDuration: 10,
            curveFactor: 2.4,
            maximumMultiplier: 10
        )

        #expect(abs(curve.multiplier(forHoldDuration: 0) - 1) <= 0.000_000_1)
        #expect(abs(curve.multiplier(forHoldDuration: 10) - 10) <= 0.000_000_1)
        #expect(abs(curve.multiplier(forHoldDuration: 14) - 10) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func directionPadDistanceScaledRateMapsTriggerToQuarterAndCapToTen() {
        let distanceRate = DistanceScaledRepeatBaseRate(
            triggerDistance: 25,
            maxDistanceForRateGain: 300,
            minimumRatePerSecond: 0.25,
            maximumRatePerSecond: 10
        )

        #expect(abs(distanceRate.rate(forDistanceFromCenter: 25) - 0.25) <= 0.000_000_1)
        #expect(abs(distanceRate.rate(forDistanceFromCenter: 325) - 10) <= 0.000_000_1)
        #expect(abs(distanceRate.rate(forDistanceFromCenter: 420) - 10) <= 0.000_000_1)
    }

    @MainActor
    @Test
    func notificationTraceContextParsesSharedPayloadFields() {
        let context = NotificationTraceContext.parse(
            userInfo: [
                "attempt_id": "attempt-1",
                "source": "Claude Code",
                "tmux_window_id": "@42",
            ]
        )

        #expect(context.attemptID == "attempt-1")
        #expect(context.source == "Claude Code")
        #expect(context.tmuxWindowID == 42)
    }

    @MainActor
    @Test
    func notificationTraceContextFallsBackToTitleWhenSourceIsMissing() {
        let context = NotificationTraceContext.parse(
            userInfo: [
                "attempt_id": "attempt-2",
                "tmux_window_id": 7,
            ],
            fallbackSource: "Codex"
        )

        #expect(context.attemptID == "attempt-2")
        #expect(context.source == "Codex")
        #expect(context.tmuxWindowID == 7)
    }

    @MainActor
    @Test
    func terminalTouchGeometryClampsPointsInsideSurfaceBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 90, height: 30)
        let clamped = TerminalTouchGeometry.clampedSurfacePoint(
            CGPoint(x: 400, y: -50),
            within: bounds
        )

        #expect(clamped != nil)
        #expect(clamped?.x == bounds.maxX.nextDown)
        #expect(clamped?.y == bounds.minY)
    }

    @MainActor
    @Test
    func terminalTouchGeometryRejectsEmptyBounds() {
        #expect(TerminalTouchGeometry.clampedSurfacePoint(
                CGPoint(x: 0, y: 0),
                within: .zero
            ) == nil)
    }

    @MainActor
    @Test
    func tmuxWindowIDParsingHandlesPrefixedAndPlainValues() {
        #expect(TmuxWindowIDParsing.parse("@42") == 42)
        #expect(TmuxWindowIDParsing.parse("42") == 42)
        #expect(TmuxWindowIDParsing.parse("  ") == nil)
        #expect(TmuxWindowIDParsing.parse("window-42") == nil)
        #expect(TerminalBridge.parseTmuxWindowID(Substring("@7")) == 7)
    }

    @Test
    func usageTrialPolicyStartsFreshAtZeroUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgenTTYTrialPolicy.mergeRecord(
            keychainRecord: nil,
            mirroredRecord: nil,
            now: now
        )

        #expect(record.startedAt == now)
        #expect(abs(record.consumedUsage - 0) <= 0.000_000_1)

        let status = AgenTTYTrialPolicy.status(for: record)
        #expect(!status.isExpired)
        #expect(abs(status.remainingUsage - AgenTTYTrialPolicy.usageLimit) <= 0.000_000_1)
    }

    @Test
    func usageTrialPolicyPrefersEarliestStartAndGreatestUsageAcrossStores() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let keychainRecord = AgenTTYUsageTrialRecord(
            startedAt: now.addingTimeInterval(-3_600),
            consumedUsage: 1_800
        )
        let mirroredRecord = AgenTTYUsageTrialRecord(
            startedAt: now.addingTimeInterval(-7_200),
            consumedUsage: 5_400
        )

        let merged = AgenTTYTrialPolicy.mergeRecord(
            keychainRecord: keychainRecord,
            mirroredRecord: mirroredRecord,
            now: now
        )

        #expect(merged.startedAt == mirroredRecord.startedAt)
        #expect(abs(merged.consumedUsage - mirroredRecord.consumedUsage) <= 0.000_000_1)
    }

    @Test
    func usageTrialPolicyMeasuresElapsedUsageFromSystemUptimeWhenAvailable() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let elapsedUsage = AgenTTYTrialPolicy.measuredElapsedUsage(
            wallClockStartedAt: startedAt,
            systemUptimeStartedAt: 100,
            now: startedAt.addingTimeInterval(500),
            systemUptime: 145
        )

        #expect(abs(elapsedUsage - 45) <= 0.000_000_1)
    }

    @Test
    func usageTrialPolicyFallsBackToWallClockWhenSystemUptimeMovesBackward() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let elapsedUsage = AgenTTYTrialPolicy.measuredElapsedUsage(
            wallClockStartedAt: startedAt,
            systemUptimeStartedAt: 100,
            now: startedAt.addingTimeInterval(90),
            systemUptime: 20
        )

        #expect(abs(elapsedUsage - 90) <= 0.000_000_1)
    }

    @Test
    func usageTrialPolicyClampsConsumedUsageAtLimit() {
        let record = AgenTTYUsageTrialRecord(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            consumedUsage: AgenTTYTrialPolicy.usageLimit - 30
        )

        let updated = AgenTTYTrialPolicy.updatedRecord(from: record, adding: 120)
        let status = AgenTTYTrialPolicy.status(for: updated)

        #expect(abs(updated.consumedUsage - AgenTTYTrialPolicy.usageLimit) <= 0.000_000_1)
        #expect(status.isExpired)
        #expect(abs(status.remainingUsage - 0) <= 0.000_000_1)
    }

    @Test
    func lifetimeAccessPolicyRendersInteractiveContentWhileInitialLookupRuns() {
        #expect(AgenTTYLifetimeAccessPolicy.shouldRenderInteractiveContent(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: false,
                hasLifetimeAccess: false,
                trialStatus: nil
            ))
        #expect(!AgenTTYLifetimeAccessPolicy.shouldBlockWithGate(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: false,
                hasLifetimeAccess: false,
                trialStatus: nil
            ))
    }

    @Test
    func lifetimeAccessPolicyDoesNotRevokeKnownPurchaseForEmptyLookup() {
        #expect(AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .absent
            ))
        #expect(AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .inconclusive
            ))
    }

    @Test
    func lifetimeAccessPolicyRequiresExplicitRevocationToRemoveKnownPurchase() {
        #expect(!AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .revoked
            ))
        #expect(AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: false,
                lookup: .active
            ))
    }

    @Test
    func lifetimeAccessPolicyBlocksExpiredTrialAfterLookupFinishes() {
        let expiredTrial = AgenTTYTrialStatus(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            usageLimit: AgenTTYTrialPolicy.usageLimit,
            consumedUsage: AgenTTYTrialPolicy.usageLimit
        )

        #expect(!AgenTTYLifetimeAccessPolicy.shouldRenderInteractiveContent(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: true,
                hasLifetimeAccess: false,
                trialStatus: expiredTrial
            ))
        #expect(AgenTTYLifetimeAccessPolicy.shouldBlockWithGate(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: true,
                hasLifetimeAccess: false,
                trialStatus: expiredTrial
            ))
    }

    @MainActor
    @Test
    func mainFlavorLocalInstallUnlockBypassesPaywall() {
        let controller = AgenTTYLifetimeAccessController(
            flavor: .main,
            localMainInstallUnlockEnabled: true
        )

        #expect(controller.hasFinishedInitialAccessLoad)
        #expect(controller.hasLifetimeAccess)
        #expect(controller.shouldRenderInteractiveContent)
        #expect(!controller.shouldBlockWithGate)
        #expect(controller.trialStatus == nil)
    }

    @MainActor
    @Test
    func keyboardPresentationPolicyKeepsIPadLandscapeOnTheHardwarePath() {
        #expect(KeyboardPresentationPolicy.resolve(
                idiom: .pad,
                sceneSize: CGSize(width: 1210, height: 900),
                inputMode: .system,
                isHiddenByUser: false
            ) == .hidden)
        #expect(KeyboardPresentationPolicy.resolve(
                idiom: .pad,
                sceneSize: CGSize(width: 900, height: 1210),
                inputMode: .custom,
                isHiddenByUser: false
            ) == .customGrid)
    }

    @MainActor
    @Test
    func keyboardPresentationPolicyResolvesIPhoneModes() {
        let phone = CGSize(width: 402, height: 874)
        #expect(KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .custom,
                isHiddenByUser: false
            ) == .customGrid)
        #expect(KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .system,
                isHiddenByUser: false
            ) == .systemKeyboard)
        #expect(KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .system,
                isHiddenByUser: true
            ) == .hidden)
    }

    @MainActor
    @Test
    func hidingTheKeyboardSuppressesTheLifecycleUndoBackspace() {
        let keyboardState = KeyboardState()
        keyboardState.recordLifecycleUndoCandidate(for: .character("a"))

        keyboardState.hideKeyboard()

        #expect(keyboardState.isKeyboardHidden)
        #expect(!keyboardState.consumeLifecycleUndoCandidate(within: 0.5))
    }

    @MainActor
    @Test
    func lifecycleUndoSuppressionOnlyAppliesToTheNextConsumption() {
        let keyboardState = KeyboardState()
        keyboardState.suppressLifecycleUndo()
        #expect(!keyboardState.consumeLifecycleUndoCandidate(within: 0.5))

        keyboardState.recordLifecycleUndoCandidate(for: .space)
        #expect(keyboardState.consumeLifecycleUndoCandidate(within: 0.5))
    }

    @MainActor
    @Test
    func showKeyboardClearsTheHiddenState() {
        let keyboardState = KeyboardState()
        keyboardState.hideKeyboard()
        keyboardState.showKeyboard()

        #expect(!keyboardState.isKeyboardHidden)
    }

    @MainActor
    @Test
    func keyboardInputModeDefaultsToTheCustomKeyboard() {
        #expect(KeyboardInputMode.defaultValue == .custom)
        #expect(KeyboardInputMode(rawValue: "system") == .system)
    }

    private func makeTemporaryClipboardTestFile(named filename: String, contents: Data) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
