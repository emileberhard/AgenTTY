import Foundation
import Testing
@testable import AgenTTY_iOS

@Suite
@MainActor
struct ShortcutCommandTests {
    @Test
    func backgroundTimeoutAcceptsDocumentedBounds() {
        #expect(AgenTTYRunShellCommandIntent.backgroundTimeoutRange.contains(1))
        #expect(AgenTTYRunShellCommandIntent.backgroundTimeoutRange.contains(10))
        #expect(AgenTTYRunShellCommandIntent.backgroundTimeoutRange.contains(20))
        #expect(!AgenTTYRunShellCommandIntent.backgroundTimeoutRange.contains(0))
        #expect(!AgenTTYRunShellCommandIntent.backgroundTimeoutRange.contains(21))
    }

    @Test
    func tmuxCommandTransportsShellTextAsBase64() {
        let command = "printf 'agentty-shortcut-raw-sentinel-92f4';\nwhoami"
        let encodedCommand = Data(command.utf8).base64EncodedString()

        let script = TerminalBridge.tmuxCreateWindowAndRunCommand(
            command,
            maxShellCount: 10,
            reuseRightmostWorkingDirectory: true
        )

        #expect(script.contains("COMMAND_BASE64='\(encodedCommand)'"))
        #expect(!script.contains(command))
        #expect(script.contains("new-window -d"))
        #expect(script.contains("load-buffer -"))
        #expect(script.contains("paste-buffer -p -d"))
        #expect(script.contains("send-keys"))
        #expect(script.contains("Enter"))
    }

    @Test
    func tmuxCommandEnforcesAtLeastOneShellSlot() {
        let script = TerminalBridge.tmuxCreateWindowAndRunCommand(
            "true",
            maxShellCount: 0,
            reuseRightmostWorkingDirectory: false
        )

        #expect(script.contains("MAX_SHELL_COUNT=1"))
        #expect(script.contains("already has the maximum number of shells"))
    }

    @Test
    func foregroundCommandsRemainOrderedUntilCompleted() async throws {
        let flavor = AgenTTYBuildFlavor.dev
        let defaults = UserDefaults(suiteName: "ShortcutCommandTests-\(UUID().uuidString)")!
        let materialStore = AgenTTYSSHKeyMaterialStore(flavor: flavor)
        let context = AgenTTYShortcutExecutionContext(
            hostStore: AgenTTYHostStore(userDefaults: defaults, flavor: flavor),
            keyMaterialStore: materialStore,
            passwordStore: AgenTTYSSHPasswordStore(flavor: flavor),
            trustedHostKeyStore: AgenTTYTrustedHostKeyStore(userDefaults: defaults, flavor: flavor),
            lifetimeAccessController: AgenTTYLifetimeAccessController(flavor: flavor)
        )
        let hostID = UUID()

        let firstTask = Task { @MainActor in
            try await context.enqueueForegroundCommand("first", hostID: hostID)
        }
        await Task.yield()
        let firstID = context.pendingForegroundCommand?.id
        let secondTask = Task { @MainActor in
            try await context.enqueueForegroundCommand("second", hostID: hostID)
        }
        await Task.yield()

        #expect(context.pendingForegroundCommand?.command == "first")
        if let firstID {
            context.completeForegroundCommand(id: firstID, succeeded: true)
        }
        try await firstTask.value
        #expect(context.pendingForegroundCommand?.command == "second")
        if let secondID = context.pendingForegroundCommand?.id {
            context.completeForegroundCommand(id: secondID, succeeded: true)
        }
        try await secondTask.value
    }
}
