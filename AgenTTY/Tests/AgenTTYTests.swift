import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
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

final class AgenTTYTests: XCTestCase {
    func testElevenLabsRealtimeIsTheDefaultDirectDictationModel() {
        XCTAssertEqual(AgenTTYDictation.defaultModel, .elevenLabsScribeV2Realtime)
        XCTAssertEqual(AgenTTYDictation.defaultModel.capture, .streaming)
    }

    func testPersistedProviderSelectionsFromBeforeTheModelPickerStillResolve() {
        XCTAssertEqual(AgenTTYDictation.Model(rawValue: "elevenLabs"), .elevenLabsScribeV2Realtime)
        XCTAssertEqual(AgenTTYDictation.Model(rawValue: "openai"), .openAIGPT4oMiniTranscribe)
        XCTAssertEqual(AgenTTYDictation.Model(rawValue: "gemini"), .gemini31Pro)
    }

    @MainActor
    func testDictationKeyMatchesBottomRowActionKeyWidth() throws {
        let letterBottomRow = try XCTUnwrap(KeyboardLayouts.letterRows().last)
        let symbolBottomRow = try XCTUnwrap(KeyboardLayouts.symbolRows.last)

        for row in [letterBottomRow, symbolBottomRow] {
            let dictationKey = try XCTUnwrap(row.first { $0.action == .dictation })
            let enterKey = try XCTUnwrap(row.first { $0.action == .enter })
            let symbolLayerKey = try XCTUnwrap(row.first { $0.action == .symbolLayer })

            XCTAssertEqual(dictationKey.widthWeight, enterKey.widthWeight)
            XCTAssertEqual(dictationKey.widthWeight, symbolLayerKey.widthWeight)
        }
    }

    @MainActor
    func testSymbolsLayerCoversEveryShellPunctuationCharacter() {
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
        XCTAssertTrue(required.isSubset(of: symbolChars), "missing: \(required.subtracting(symbolChars))")
        XCTAssertTrue(letterChars.contains("~"))
        XCTAssertTrue(letterChars.contains("."))
    }

    @MainActor
    func testSymbolsLayerKeyIDsAreUniqueWithinTheMountedLayer() {
        for rows in [KeyboardLayouts.symbolRows, KeyboardLayouts.letterRows()] {
            let ids = rows.flatMap { $0 }.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate key id inside one mounted layer")
        }
    }

    @MainActor
    func testSymbolsCharacterRowsAreTenKeysWide() {
        let charRows = KeyboardLayouts.symbolRows.dropLast()
        for row in charRows {
            XCTAssertEqual(row.count, 10)
        }
    }

    func testElapsedMillisecondsUsesMonotonicNanoseconds() {
        XCTAssertEqual(
            EsmaDiagnostics.elapsedMilliseconds(
                since: 1_000_000,
                nowNanoseconds: 3_500_000
            ),
            2
        )
        XCTAssertEqual(
            EsmaDiagnostics.elapsedMilliseconds(
                since: 2_000_000,
                nowNanoseconds: 1_000_000
            ),
            0
        )
    }

    @MainActor
    func testKeyCalloutRowsTrackSimultaneousPressesAndDeactivateCleanly() {
        let keyboardState = KeyboardState()

        keyboardState.beginKeyCallout(id: "char-q", rowIndex: 1)
        keyboardState.beginKeyCallout(id: "char-a", rowIndex: 2)

        XCTAssertTrue(keyboardState.hasActiveKeyCallout(in: 1))
        XCTAssertTrue(keyboardState.hasActiveKeyCallout(in: 2))

        keyboardState.endKeyCallout(id: "char-q")

        XCTAssertFalse(keyboardState.hasActiveKeyCallout(in: 1))
        XCTAssertTrue(keyboardState.hasActiveKeyCallout(in: 2))

        keyboardState.handleAppWillDeactivate()

        XCTAssertFalse(keyboardState.hasActiveKeyCallout(in: 2))
    }

    @MainActor
    func testHostDecodesLegacyNameKeyIntoLabel() throws {
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

        XCTAssertEqual(host.label, "dev-host")
        XCTAssertEqual(host.address, "100.64.0.10")
    }

    @MainActor
    func testHostEncodesLabelKey() throws {
        let host = AgenTTYHost(
            id: UUID(uuidString: "6F31FDF8-1CC0-4DD0-9F80-2A30FCF0A5A6")!,
            label: "macbook",
            address: "backup-host",
            port: 22,
            username: "developer",
            authentication: .key(UUID(uuidString: "3E3BFEB7-2E7E-4B68-9A89-9A28F11B2A63")!)
        )

        let encoded = try JSONEncoder().encode(host)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["label"] as? String, "macbook")
        XCTAssertNil(object["name"])
    }

    @MainActor
    func testHostDecodingPrefersLabelOverLegacyNameWhenBothArePresent() throws {
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

        XCTAssertEqual(host.label, "macbook")
    }

    @MainActor
    func testPairingCandidateRankingPrefersLocalDomainOverSingleLabelForLegacyCandidates() throws {
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

        XCTAssertEqual(ranked.map { $0.value }, ["agentty.local", "agentty"])
        XCTAssertEqual(ranked.map { $0.kind }, [.localDomain, .singleLabel])
    }

    @MainActor
    func testPairingCandidateRankingPreservesRelayProvidedRankForCanonicalCandidates() throws {
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

        XCTAssertEqual(ranked.map { $0.value }, ["agentty", "agentty.local"])
        XCTAssertEqual(ranked.map { $0.rank }, [1, 2])
    }

    @MainActor
    func testPairingCandidateRankingCompactsCanonicalRanksAfterDeduplication() throws {
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

        XCTAssertEqual(ranked.map { $0.value }, ["agentty"])
        XCTAssertEqual(ranked.map { $0.rank }, [1])
    }

    @MainActor
    func testPairingSessionCompletionMetadataDecodesUsernameDiagnosticsAndEnvironmentFlags() throws {
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

        XCTAssertEqual(completion.detectedUsername, "developer")
        XCTAssertEqual(completion.detectedUsernameSource, .whoamiCommand)
        XCTAssertEqual(completion.detectedUsernameSuspicious, true)
        XCTAssertEqual(completion.hostEnvironmentFlags, [.wsl, .container])
    }

    @MainActor
    func testHostStoreAddHostMatchReturnsExactMatchForNormalizedAddress() throws {
        let suiteName = "AgenTTYTests.HostStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgenTTYHostStore(userDefaults: defaults, flavor: .main)
        let existingHostID = store.addHost(
            try XCTUnwrap(
                AgenTTYHostDraft(
                    label: "Mac",
                    address: "Agentty.Local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
                )
            )
        )

        let match = store.addHostMatch(
            for: try XCTUnwrap(
                AgenTTYHostDraft(
                    label: "Mac Again",
                    address: "agentty.local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!)
                )
            )
        )

        guard case .exact(let existingHost)? = match else {
            return XCTFail("Expected an exact host match.")
        }

        XCTAssertEqual(existingHost.id, existingHostID)
    }

    @MainActor
    func testHostAddressNormalizationTrimsInvisibleWhitespaceAndUnicodeDashes() throws {
        let draft = try XCTUnwrap(
            AgenTTYHostDraft(
                label: "Mac",
                address: "\u{200B} dev\u{2011}host \u{FEFF}",
                port: 22,
                username: "developer",
                authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
            )
        )

        XCTAssertEqual(draft.address, "dev-host")
        XCTAssertEqual(
            AgenTTYHostStore.normalizedAddress("Dev\u{2011}Host"),
            "dev-host"
        )
    }

    func testDNSReachabilityErrorUsesDNSRecoveryGuidance() {
        let error = AgenTTYHostReachabilityError.failed(
            host: "dev-host",
            port: 22,
            reason: "No such host",
            subtype: .dns
        )
        let guidance = AgenTTYHostReachabilityGuidance.guidance(for: error)

        XCTAssertEqual(error.localizedDescription, "The hostname dev-host does not resolve from this iPhone.")
        XCTAssertEqual(guidance.title, "Hostname Does Not Resolve")
        XCTAssertTrue(guidance.message.contains("does not resolve from this iPhone"))
        XCTAssertTrue(guidance.suggestions.contains { $0.title == "Use an IP address" })
        XCTAssertTrue(guidance.suggestions.contains { $0.title == "Try the full Tailscale name" })
        XCTAssertTrue(guidance.suggestions.contains { $0.title == "Try the .local name" })
        XCTAssertTrue(guidance.suggestions.contains { $0.title == "Run Automatic Setup again" })
    }

    @MainActor
    func testPreReadyFailureCircuitBreakerTripsOnThirdFailureWithinWindow() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        XCTAssertFalse(breaker.recordFailure(hostID: hostID, authMode: .key, category: .other, at: startedAt))
        XCTAssertFalse(
            breaker.recordFailure(
                hostID: hostID,
                authMode: .key,
                category: .other,
                at: startedAt.addingTimeInterval(10)
            )
        )
        XCTAssertTrue(
            breaker.recordFailure(
                hostID: hostID,
                authMode: .key,
                category: .other,
                at: startedAt.addingTimeInterval(20)
            )
        )
    }

    @MainActor
    func testPreReadyFailureCircuitBreakerIgnoresTransientNetworkCategories() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        let transientCategories: [AgenTTYSSHDisconnectCategory] = [
            .connectTimeout, .networkError, .transportClosed,
        ]
        for (index, category) in transientCategories.enumerated() {
            for attempt in 0..<5 {
                XCTAssertFalse(
                    breaker.recordFailure(
                        hostID: hostID,
                        authMode: .key,
                        category: category,
                        at: startedAt.addingTimeInterval(Double(index * 10 + attempt))
                    ),
                    "transient category \(category) must never trip the breaker"
                )
            }
        }

        // Transient failures must not have advanced the countable streak either.
        XCTAssertFalse(
            breaker.recordFailure(
                hostID: hostID,
                authMode: .key,
                category: .other,
                at: startedAt.addingTimeInterval(50)
            )
        )
    }

    @MainActor
    func testUnknownClientBootstrapChannelFailureIsTransientNetworkFailure() {
        let error = NSError(domain: "NIOCore.ChannelError", code: 0)
        let outcome = SSHClientSession.connectFailureOutcome(
            for: error,
            rawReason: "connect failed: NIOCore.ChannelError error 0"
        )

        XCTAssertEqual(outcome.category, .networkError)
        XCTAssertEqual(outcome.failureStage, .tcpConnect)
        XCTAssertTrue(outcome.shouldReconnect)
        XCTAssertFalse(AgenTTYPreReadyFailureCircuitBreaker.countsTowardTrip(outcome.category))
    }

    @MainActor
    func testRelayResolutionFailureRearmsDirectProbeForNextRetry() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        AgenTTYConnectionRouteResolver.invalidateRouteMemory()
        defer { AgenTTYConnectionRouteResolver.invalidateRouteMemory() }

        AgenTTYConnectionRouteResolver.recordDirectRouteFailure(for: hostID)
        XCTAssertTrue(AgenTTYConnectionRouteResolver.shouldPreferRelay(for: hostID))

        AgenTTYConnectionRouteResolver.recordRelayResolutionFailure(for: hostID)
        XCTAssertFalse(AgenTTYConnectionRouteResolver.shouldPreferRelay(for: hostID))
    }

    @MainActor
    func testPreReadyFailureCircuitBreakerResetsForNewHostOrExpiredWindow() {
        let firstHostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondHostID = UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!
        let startedAt = Date(timeIntervalSince1970: 1_715_000_000)

        var breaker = AgenTTYPreReadyFailureCircuitBreaker()
        XCTAssertFalse(
            breaker.recordFailure(hostID: firstHostID, authMode: .key, category: .other, at: startedAt)
        )
        XCTAssertFalse(
            breaker.recordFailure(
                hostID: secondHostID,
                authMode: .key,
                category: .other,
                at: startedAt.addingTimeInterval(10)
            )
        )

        breaker.reset()
        XCTAssertFalse(
            breaker.recordFailure(hostID: firstHostID, authMode: .key, category: .other, at: startedAt)
        )
        XCTAssertFalse(
            breaker.recordFailure(
                hostID: firstHostID,
                authMode: .key,
                category: .other,
                at: startedAt.addingTimeInterval(61)
            )
        )
    }

    @MainActor
    func testHostStoreAddHostMatchReturnsRelatedMatchForAutomaticCandidateAlias() throws {
        let suiteName = "AgenTTYTests.HostStoreRelated.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgenTTYHostStore(userDefaults: defaults, flavor: .main)
        let existingHostID = store.addHost(
            try XCTUnwrap(
                AgenTTYHostDraft(
                    label: "Mac",
                    address: "agentty.local",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
                )
            )
        )

        let match = store.addHostMatch(
            for: try XCTUnwrap(
                AgenTTYHostDraft(
                    label: "Mac Alias",
                    address: "agentty",
                    port: 22,
                    username: "developer",
                    authentication: .key(UUID(uuidString: "FFFFFFFF-1111-2222-3333-444444444444")!)
                )
            ),
            relatedAddresses: ["agentty.local", "agentty"]
        )

        guard case .related(let existingHost)? = match else {
            return XCTFail("Expected a related host match.")
        }

        XCTAssertEqual(existingHost.id, existingHostID)
    }

    @MainActor
    func testSheetNavigationCoordinatorResetToRootClearsNavigationStateAndRestoresMediumDetent() {
        let coordinator = SheetNavigationCoordinator<String>()
        coordinator.path = ["automatic", "review"]
        coordinator.pendingRoute = "stale"
        coordinator.selectedDetent = .large

        coordinator.resetToRoot()

        XCTAssertTrue(coordinator.path.isEmpty)
        XCTAssertNil(coordinator.pendingRoute)
        XCTAssertEqual(coordinator.selectedDetent, .medium)
    }

    @MainActor
    func testHostListReachabilityTrackerUsesWarningOnlyForFirstFailureAfterSuccess() {
        var tracker = HostListReachabilityTracker()

        XCTAssertEqual(tracker.indicatorState, .checking)

        tracker.recordSuccess()
        XCTAssertEqual(tracker.indicatorState, .reachable)

        tracker.recordFailure()
        XCTAssertEqual(tracker.indicatorState, .warning)

        tracker.recordFailure()
        XCTAssertEqual(tracker.indicatorState, .unreachable)
    }

    @MainActor
    func testHostListReachabilityTrackerStartsRedWhenInitialCheckFails() {
        var tracker = HostListReachabilityTracker()

        tracker.recordFailure()

        XCTAssertEqual(tracker.indicatorState, .unreachable)
    }

    @MainActor
    func testHostListReachabilityTrackerCanTemporarilyReturnToCheckingDuringManualRefresh() {
        var tracker = HostListReachabilityTracker()

        tracker.recordSuccess()
        XCTAssertEqual(tracker.indicatorState, .reachable)

        tracker.beginCheck()
        XCTAssertEqual(tracker.indicatorState, .checking)

        tracker.recordFailure(message: "AgenTTY could not reach backup-host:22.")
        XCTAssertEqual(tracker.indicatorState, .warning)
        XCTAssertEqual(tracker.lastFailureMessage, "AgenTTY could not reach backup-host:22.")
    }

    func testHostRuntimeManifestDecodesTerminfoEntries() throws {
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

        XCTAssertEqual(
            try manifest.target(for: .linuxArm64).terminfoEntries.map(\.relativePath),
            ["74/tmux-256color", "78/xterm-256color"]
        )
        XCTAssertEqual(
            try manifest.target(for: .linuxArm64).agenttyHostConnector?.sha256,
            "connector-sha"
        )
    }

    func testHostRuntimeManifestRejectsInvalidTerminfoRelativePaths() {
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

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgenTTYHostRuntimeArtifactManifest.self,
                from: Data(json.utf8)
            )
        )
    }

    func testHostRuntimeTerminfoPathsUseManagedShareDirectory() {
        XCTAssertEqual(AgenTTYHostRuntime.terminfoRootRemotePath, "$HOME/.agentty/share/terminfo")
        XCTAssertEqual(
            AgenTTYHostRuntime.terminfoEntryRemotePath(relativePath: "74/tmux-256color"),
            "$HOME/.agentty/share/terminfo/74/tmux-256color"
        )
    }

    func testRemoteFileWriteStagesAndVerifiesBeforeAtomicReplacement() throws {
        let command = SSHClientSession.remoteFileWriteCommand(
            for: "$HOME/.agentty/libexec/tmux",
            executable: true,
            expectedByteCount: 1_089_320,
            expectedSHA256: "abc123"
        )

        XCTAssertTrue(command.contains(#"tmp_path="${target_path}.part.$$""#))
        XCTAssertTrue(command.contains(#"[ "$actual_byte_count" != "1089320" ]"#))
        XCTAssertTrue(command.contains("sha256sum"))
        XCTAssertTrue(command.contains("shasum -a 256"))
        XCTAssertTrue(command.contains(#"chmod 700 "$tmp_path""#))
        XCTAssertTrue(command.contains(#"mv -f "$tmp_path" "$target_path""#))

        let byteCountCheck = try XCTUnwrap(command.range(of: "actual_byte_count="))
        let checksumCheck = try XCTUnwrap(command.range(of: "actual_sha256="))
        let permissionChange = try XCTUnwrap(command.range(of: #"chmod 700 "$tmp_path""#))
        let replacement = try XCTUnwrap(command.range(of: #"mv -f "$tmp_path" "$target_path""#))
        XCTAssertLessThan(byteCountCheck.lowerBound, checksumCheck.lowerBound)
        XCTAssertLessThan(checksumCheck.lowerBound, permissionChange.lowerBound)
        XCTAssertLessThan(permissionChange.lowerBound, replacement.lowerBound)
    }

    func testRelayConnectorActivationProbesBeforeAtomicReplacementAndRestart() throws {
        let command = AgenTTYHostRuntimeProvisioner.relayConnectorActivationCommand(
            candidateRemotePath: "$HOME/.agentty/libexec/agentty-host-connector.update.test"
        )

        let probe = try XCTUnwrap(command.range(of: "probe-control --config"))
        let replacement = try XCTUnwrap(command.range(of: #"mv -f "$candidate_path" "$target_path""#))
        let restart = try XCTUnwrap(command.range(of: #"kill -TERM "$pid""#))
        XCTAssertLessThan(probe.lowerBound, replacement.lowerBound)
        XCTAssertLessThan(replacement.lowerBound, restart.lowerBound)
        XCTAssertTrue(command.contains(#"[ "$command" = "$expected_command" ]"#))
    }

    func testHostRuntimeIntegrityManifestIsStableAndUsesManagedRelativePaths() {
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

        XCTAssertEqual(
            AgenTTYHostRuntimeProvisioner.runtimePayloadIntegrityManifest(for: artifacts),
            """
            tmux-hash  libexec/tmux
            notify-hash  libexec/agentty-notify
            terminfo-hash  share/terminfo/74/tmux-256color
            xterm-hash  share/terminfo/78/xterm-256color
            """
        )
    }

    func testTmuxBootstrapCommandRunsBundledBootstrapViaPOSIXSh() {
        let command = AgenTTYConnection.tmuxBootstrapCommand
        XCTAssertTrue(command.contains("exec /bin/sh -lc"))
        XCTAssertTrue(command.contains("agentty-bootstrap"))
    }

    func testTmuxBootstrapCommandAvoidsSystemTmuxFallbacks() {
        let command = AgenTTYConnection.tmuxBootstrapCommand
        XCTAssertFalse(command.contains("command -v tmux"))
        XCTAssertFalse(command.contains("tmux-resurrect"))
        XCTAssertFalse(command.contains("brew install tmux"))
        XCTAssertFalse(command.contains("/bin/zsh -lc"))
    }

    @MainActor
    func testTmuxCommandBuildersUseBundledWrapperPath() {
        XCTAssertEqual(AgenTTYHostRuntime.tmuxWrapperRemotePath, "$HOME/.agentty/bin/tmux")
        XCTAssertTrue(
            TerminalBridge.tmuxListWindowsCommand.contains(AgenTTYHostRuntime.tmuxWrapperShellLiteral)
        )
        XCTAssertTrue(
            SSHClientSession.tmuxDictationInsertCommand(for: "hello")
                .contains(AgenTTYHostRuntime.tmuxWrapperShellLiteral)
        )
    }

    @MainActor
    func testClipboardImagePasteEventDelayIsOnlyUsedForMultiImagePaste() {
        XCTAssertNil(TerminalBridge.clipboardImagePasteEventDelayNanoseconds(forImageCount: 1))
        XCTAssertEqual(
            TerminalBridge.clipboardImagePasteEventDelayNanoseconds(forImageCount: 3),
            500_000_000
        )
    }

    @MainActor
    func testClipboardPlainTextStillResolvesAsText() async {
        let pasteboard = TestTerminalClipboardPasteboard(
            hasImages: false,
            hasFiles: false,
            itemProviders: [],
            hasStrings: true,
            string: "hello"
        )

        let payload = await TerminalClipboard.generalPastePayload(pasteboard: pasteboard)

        guard case .text(let text)? = payload else {
            XCTFail("expected plain text payload")
            return
        }
        XCTAssertEqual(text, "hello")
    }

    @MainActor
    func testClipboardTextFilePayloadBeatsPlainTextFallback() async throws {
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
            XCTFail("expected file payload")
            return
        }
        XCTAssertEqual(fileProviders.count, 1)
        guard let filePayload = await fileProviders[0].loadFilePayload() else {
            XCTFail("expected resolved file payload")
            return
        }
        let filename = filePayload.filename
        let byteCount = filePayload.byteCount
        XCTAssertEqual(filename, "notes.txt")
        XCTAssertEqual(byteCount, 5)
        TerminalClipboard.removeTemporaryFile(at: filePayload.localFileURL)
    }

    @MainActor
    func testClipboardImagesStillWinOverGenericFiles() async throws {
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
            XCTFail("expected image payload")
            return
        }
        XCTAssertEqual(imagePayloads.count, 1)
        let preferredExtension = imagePayloads[0].preferredExtension
        XCTAssertEqual(preferredExtension, "png")
    }

    @MainActor
    func testClipboardDataOnlyGenericProviderDoesNotResolveAsFile() async {
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
            XCTFail("expected provider-backed file payload")
            return
        }
        XCTAssertEqual(fileProviders.count, 1)
        let resolvedPayload = await fileProviders[0].loadFilePayload()
        XCTAssertNil(resolvedPayload)
    }

    func testClipboardGenericFileTypeFilterRejectsDirectoriesAndURLs() {
        XCTAssertFalse(TerminalClipboard.isSupportedGenericFileContentType(.directory))
        XCTAssertFalse(TerminalClipboard.isSupportedGenericFileContentType(.folder))
        XCTAssertFalse(TerminalClipboard.isSupportedGenericFileContentType(.url))
        XCTAssertTrue(TerminalClipboard.isSupportedGenericFileContentType(.pdf))
        XCTAssertTrue(TerminalClipboard.isSupportedGenericFileContentType(.movie))
        XCTAssertTrue(TerminalClipboard.isSupportedGenericFileContentType(.plainText))
    }

    @MainActor
    func testClipboardPasteAvailabilityIncludesSupportedFiles() {
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

        XCTAssertTrue(TerminalClipboard.hasPasteableContent(pasteboard: pasteboard))
    }

    @MainActor
    func testRemoteClipboardFilePathPreservesFilenameExtension() {
        let path = TerminalClipboard.remoteClipboardFilePath(
            filename: "My Report 2026.final.pdf",
            preferredExtension: nil
        )

        XCTAssertTrue(path.hasPrefix("/tmp/agentty-clipboard-"))
        XCTAssertTrue(path.hasSuffix(".pdf"))
        XCTAssertTrue(path.contains("-MyReport2026final"))
    }

    @MainActor
    func testRemoteClipboardFilePathFallsBackToPreferredExtension() {
        let path = TerminalClipboard.remoteClipboardFilePath(
            filename: "video",
            preferredExtension: "mp4"
        )

        XCTAssertTrue(path.hasSuffix(".mp4"))
    }

    @MainActor
    func testClipboardTemporaryFileCleanupRemovesOwnedFiles() throws {
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    @MainActor
    func testGhosttyWindowPaddingCLIValueEncoding() {
        XCTAssertEqual(
            AgenTTYGhosttyConfig.WindowPadding(topLeft: 3, bottomRight: 3).cliValue,
            "3"
        )
        XCTAssertEqual(
            AgenTTYGhosttyConfig.WindowPadding(topLeft: 1, bottomRight: 4).cliValue,
            "1,4"
        )
    }

    @MainActor
    func testBackspaceRepeatAccelerationIsMonotonicAndCappedAfterRamp() {
        guard case .accelerated(let behavior) = KeyAction.backspace.repeatBehavior else {
            XCTFail("backspace should use accelerated repeat behavior")
            return
        }

        let checkpoints: [TimeInterval] = [0, 0.5, 1, 2, 4, 6, 8, 10, 12]
        let intervals = checkpoints.map { behavior.interval(forHoldDuration: $0) }

        for index in 1..<intervals.count {
            XCTAssertLessThanOrEqual(intervals[index], intervals[index - 1] + 0.000_001)
        }

        XCTAssertEqual(intervals[7], intervals[8], accuracy: 0.000_000_1)
    }

    @MainActor
    func testBackspaceRepeatHitsConfiguredPeakAtTenSeconds() {
        guard case .accelerated(let behavior) = KeyAction.backspace.repeatBehavior else {
            XCTFail("backspace should use accelerated repeat behavior")
            return
        }

        let peakInterval = 1 / behavior.maximumRatePerSecond
        XCTAssertEqual(behavior.maximumRatePerSecond, 140, accuracy: 0.000_000_1)
        XCTAssertEqual(behavior.interval(forHoldDuration: 10), peakInterval, accuracy: 0.000_000_1)
        XCTAssertEqual(behavior.interval(forHoldDuration: 16), peakInterval, accuracy: 0.000_000_1)
    }

    @MainActor
    func testStandardRepeatProfileIsUnchangedForCharacterKeys() {
        guard case .fixed(let behavior) = KeyAction.character("x").repeatBehavior else {
            XCTFail("character keys should use fixed repeat behavior")
            return
        }

        XCTAssertEqual(behavior.initialDelay, 0.45, accuracy: 0.000_000_1)
        XCTAssertEqual(behavior.interval, 0.065, accuracy: 0.000_000_1)
    }

    @MainActor
    func testRepeatAccelerationCurveReachesConfiguredMultiplierAtTenSeconds() {
        let curve = RepeatAccelerationCurve(
            rampDuration: 10,
            curveFactor: 2.4,
            maximumMultiplier: 10
        )

        XCTAssertEqual(curve.multiplier(forHoldDuration: 0), 1, accuracy: 0.000_000_1)
        XCTAssertEqual(curve.multiplier(forHoldDuration: 10), 10, accuracy: 0.000_000_1)
        XCTAssertEqual(curve.multiplier(forHoldDuration: 14), 10, accuracy: 0.000_000_1)
    }

    @MainActor
    func testDirectionPadDistanceScaledRateMapsTriggerToQuarterAndCapToTen() {
        let distanceRate = DistanceScaledRepeatBaseRate(
            triggerDistance: 25,
            maxDistanceForRateGain: 300,
            minimumRatePerSecond: 0.25,
            maximumRatePerSecond: 10
        )

        XCTAssertEqual(distanceRate.rate(forDistanceFromCenter: 25), 0.25, accuracy: 0.000_000_1)
        XCTAssertEqual(distanceRate.rate(forDistanceFromCenter: 325), 10, accuracy: 0.000_000_1)
        XCTAssertEqual(distanceRate.rate(forDistanceFromCenter: 420), 10, accuracy: 0.000_000_1)
    }

    @MainActor
    func testNotificationTraceContextParsesSharedPayloadFields() {
        let context = NotificationTraceContext.parse(
            userInfo: [
                "attempt_id": "attempt-1",
                "source": "Claude Code",
                "tmux_window_id": "@42",
            ]
        )

        XCTAssertEqual(context.attemptID, "attempt-1")
        XCTAssertEqual(context.source, "Claude Code")
        XCTAssertEqual(context.tmuxWindowID, 42)
    }

    @MainActor
    func testNotificationTraceContextFallsBackToTitleWhenSourceIsMissing() {
        let context = NotificationTraceContext.parse(
            userInfo: [
                "attempt_id": "attempt-2",
                "tmux_window_id": 7,
            ],
            fallbackSource: "Codex"
        )

        XCTAssertEqual(context.attemptID, "attempt-2")
        XCTAssertEqual(context.source, "Codex")
        XCTAssertEqual(context.tmuxWindowID, 7)
    }

    @MainActor
    func testTerminalTouchGeometryClampsPointsInsideSurfaceBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 90, height: 30)
        let clamped = TerminalTouchGeometry.clampedSurfacePoint(
            CGPoint(x: 400, y: -50),
            within: bounds
        )

        XCTAssertNotNil(clamped)
        XCTAssertEqual(clamped?.x, bounds.maxX.nextDown)
        XCTAssertEqual(clamped?.y, bounds.minY)
    }

    @MainActor
    func testTerminalTouchGeometryRejectsEmptyBounds() {
        XCTAssertNil(
            TerminalTouchGeometry.clampedSurfacePoint(
                CGPoint(x: 0, y: 0),
                within: .zero
            )
        )
    }

    @MainActor
    func testTmuxWindowIDParsingHandlesPrefixedAndPlainValues() {
        XCTAssertEqual(TmuxWindowIDParsing.parse("@42"), 42)
        XCTAssertEqual(TmuxWindowIDParsing.parse("42"), 42)
        XCTAssertNil(TmuxWindowIDParsing.parse("  "))
        XCTAssertNil(TmuxWindowIDParsing.parse("window-42"))
        XCTAssertEqual(TerminalBridge.parseTmuxWindowID(Substring("@7")), 7)
    }

    func testUsageTrialPolicyStartsFreshAtZeroUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = AgenTTYTrialPolicy.mergeRecord(
            keychainRecord: nil,
            mirroredRecord: nil,
            now: now
        )

        XCTAssertEqual(record.startedAt, now)
        XCTAssertEqual(record.consumedUsage, 0, accuracy: 0.000_000_1)

        let status = AgenTTYTrialPolicy.status(for: record)
        XCTAssertFalse(status.isExpired)
        XCTAssertEqual(status.remainingUsage, AgenTTYTrialPolicy.usageLimit, accuracy: 0.000_000_1)
    }

    func testUsageTrialPolicyPrefersEarliestStartAndGreatestUsageAcrossStores() {
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

        XCTAssertEqual(merged.startedAt, mirroredRecord.startedAt)
        XCTAssertEqual(merged.consumedUsage, mirroredRecord.consumedUsage, accuracy: 0.000_000_1)
    }

    func testUsageTrialPolicyMeasuresElapsedUsageFromSystemUptimeWhenAvailable() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let elapsedUsage = AgenTTYTrialPolicy.measuredElapsedUsage(
            wallClockStartedAt: startedAt,
            systemUptimeStartedAt: 100,
            now: startedAt.addingTimeInterval(500),
            systemUptime: 145
        )

        XCTAssertEqual(elapsedUsage, 45, accuracy: 0.000_000_1)
    }

    func testUsageTrialPolicyFallsBackToWallClockWhenSystemUptimeMovesBackward() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let elapsedUsage = AgenTTYTrialPolicy.measuredElapsedUsage(
            wallClockStartedAt: startedAt,
            systemUptimeStartedAt: 100,
            now: startedAt.addingTimeInterval(90),
            systemUptime: 20
        )

        XCTAssertEqual(elapsedUsage, 90, accuracy: 0.000_000_1)
    }

    func testUsageTrialPolicyClampsConsumedUsageAtLimit() {
        let record = AgenTTYUsageTrialRecord(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            consumedUsage: AgenTTYTrialPolicy.usageLimit - 30
        )

        let updated = AgenTTYTrialPolicy.updatedRecord(from: record, adding: 120)
        let status = AgenTTYTrialPolicy.status(for: updated)

        XCTAssertEqual(updated.consumedUsage, AgenTTYTrialPolicy.usageLimit, accuracy: 0.000_000_1)
        XCTAssertTrue(status.isExpired)
        XCTAssertEqual(status.remainingUsage, 0, accuracy: 0.000_000_1)
    }

    func testLifetimeAccessPolicyRendersInteractiveContentWhileInitialLookupRuns() {
        XCTAssertTrue(
            AgenTTYLifetimeAccessPolicy.shouldRenderInteractiveContent(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: false,
                hasLifetimeAccess: false,
                trialStatus: nil
            )
        )
        XCTAssertFalse(
            AgenTTYLifetimeAccessPolicy.shouldBlockWithGate(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: false,
                hasLifetimeAccess: false,
                trialStatus: nil
            )
        )
    }

    func testLifetimeAccessPolicyDoesNotRevokeKnownPurchaseForEmptyLookup() {
        XCTAssertTrue(
            AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .absent
            )
        )
        XCTAssertTrue(
            AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .inconclusive
            )
        )
    }

    func testLifetimeAccessPolicyRequiresExplicitRevocationToRemoveKnownPurchase() {
        XCTAssertFalse(
            AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: true,
                lookup: .revoked
            )
        )
        XCTAssertTrue(
            AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
                currentValue: false,
                lookup: .active
            )
        )
    }

    func testLifetimeAccessPolicyBlocksExpiredTrialAfterLookupFinishes() {
        let expiredTrial = AgenTTYTrialStatus(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            usageLimit: AgenTTYTrialPolicy.usageLimit,
            consumedUsage: AgenTTYTrialPolicy.usageLimit
        )

        XCTAssertFalse(
            AgenTTYLifetimeAccessPolicy.shouldRenderInteractiveContent(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: true,
                hasLifetimeAccess: false,
                trialStatus: expiredTrial
            )
        )
        XCTAssertTrue(
            AgenTTYLifetimeAccessPolicy.shouldBlockWithGate(
                enforcesPaywall: true,
                hasFinishedInitialAccessLoad: true,
                hasLifetimeAccess: false,
                trialStatus: expiredTrial
            )
        )
    }

    @MainActor
    func testMainFlavorLocalInstallUnlockBypassesPaywall() {
        let controller = AgenTTYLifetimeAccessController(
            flavor: .main,
            localMainInstallUnlockEnabled: true
        )

        XCTAssertTrue(controller.hasFinishedInitialAccessLoad)
        XCTAssertTrue(controller.hasLifetimeAccess)
        XCTAssertTrue(controller.shouldRenderInteractiveContent)
        XCTAssertFalse(controller.shouldBlockWithGate)
        XCTAssertNil(controller.trialStatus)
    }

    @MainActor
    func testKeyboardPresentationPolicyKeepsIPadLandscapeOnTheHardwarePath() {
        XCTAssertEqual(
            KeyboardPresentationPolicy.resolve(
                idiom: .pad,
                sceneSize: CGSize(width: 1210, height: 900),
                inputMode: .system,
                isHiddenByUser: false
            ),
            .hidden
        )
        XCTAssertEqual(
            KeyboardPresentationPolicy.resolve(
                idiom: .pad,
                sceneSize: CGSize(width: 900, height: 1210),
                inputMode: .custom,
                isHiddenByUser: false
            ),
            .customGrid
        )
    }

    @MainActor
    func testKeyboardPresentationPolicyResolvesIPhoneModes() {
        let phone = CGSize(width: 402, height: 874)
        XCTAssertEqual(
            KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .custom,
                isHiddenByUser: false
            ),
            .customGrid
        )
        XCTAssertEqual(
            KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .system,
                isHiddenByUser: false
            ),
            .systemKeyboard
        )
        XCTAssertEqual(
            KeyboardPresentationPolicy.resolve(
                idiom: .phone,
                sceneSize: phone,
                inputMode: .system,
                isHiddenByUser: true
            ),
            .hidden
        )
    }

    @MainActor
    func testHidingTheKeyboardSuppressesTheLifecycleUndoBackspace() {
        let keyboardState = KeyboardState()
        keyboardState.recordLifecycleUndoCandidate(for: .character("a"))

        keyboardState.hideKeyboard()

        XCTAssertTrue(keyboardState.isKeyboardHidden)
        XCTAssertFalse(keyboardState.consumeLifecycleUndoCandidate(within: 0.5))
    }

    @MainActor
    func testLifecycleUndoSuppressionOnlyAppliesToTheNextConsumption() {
        let keyboardState = KeyboardState()
        keyboardState.suppressLifecycleUndo()
        XCTAssertFalse(keyboardState.consumeLifecycleUndoCandidate(within: 0.5))

        keyboardState.recordLifecycleUndoCandidate(for: .space)
        XCTAssertTrue(keyboardState.consumeLifecycleUndoCandidate(within: 0.5))
    }

    @MainActor
    func testShowKeyboardClearsTheHiddenState() {
        let keyboardState = KeyboardState()
        keyboardState.hideKeyboard()
        keyboardState.showKeyboard()

        XCTAssertFalse(keyboardState.isKeyboardHidden)
    }

    @MainActor
    func testKeyboardInputModeDefaultsToTheCustomKeyboard() {
        XCTAssertEqual(KeyboardInputMode.defaultValue, .custom)
        XCTAssertEqual(KeyboardInputMode(rawValue: "system"), .system)
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
