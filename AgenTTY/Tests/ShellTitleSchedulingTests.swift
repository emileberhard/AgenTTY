import Foundation
import Testing
@testable import AgenTTY_iOS

@Suite("Shell title scheduling")
@MainActor
struct ShellTitleSchedulingTests {
    @Test
    func parsesAgentMetadataWithoutCountingTheVisiblePaneAsHistory() {
        let output = "@7\t3\t1\t42\t1\t1782935379\tclaude\tsession-1\t5\t9\t/tmp/project"

        let window = TerminalBridge.parseTmuxWindowStatesWithLineCounts(from: output).first

        #expect(window?.id == 7)
        #expect(window?.lineCount == 42)
        #expect(window?.alternateScreenActive == true)
        #expect(window?.sessionCreated == 1_782_935_379)
        #expect(window?.agentTitleProvider == "claude")
        #expect(window?.agentTitleSessionID == "session-1")
        #expect(window?.agentCompletedTurnCount == 5)
        #expect(window?.agentTitleRevision == 9)
    }

    @Test(arguments: [
        (0, 0),
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 4),
        (5, 5),
        (6, 5),
        (9, 5),
        (10, 10),
        (19, 10),
        (20, 20),
        (29, 20),
    ])
    func completedTurnMilestones(completedTurns: Int, expectedMilestone: Int) {
        #expect(TerminalBridge.shellTitleTurnMilestone(for: completedTurns) == expectedMilestone)
    }

    @Test
    func catchesUpOnceToTheLatestEligibleMilestone() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(TerminalBridge.shouldScheduleShellTitleGeneration(
            currentMilestone: TerminalBridge.shellTitleTurnMilestone(for: 17),
            lastGeneratedMilestone: 5,
            retryAfter: nil,
            now: now
        ))
        #expect(!TerminalBridge.shouldScheduleShellTitleGeneration(
            currentMilestone: TerminalBridge.shellTitleTurnMilestone(for: 17),
            lastGeneratedMilestone: 10,
            retryAfter: nil,
            now: now
        ))
    }

    @Test
    func failedMilestoneRemainsEligibleAfterBackoff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retryAfter = now.addingTimeInterval(30)

        #expect(!TerminalBridge.shouldScheduleShellTitleGeneration(
            currentMilestone: 5,
            lastGeneratedMilestone: 2,
            retryAfter: retryAfter,
            now: now
        ))
        #expect(TerminalBridge.shouldScheduleShellTitleGeneration(
            currentMilestone: 5,
            lastGeneratedMilestone: 2,
            retryAfter: retryAfter,
            now: retryAfter
        ))
        #expect(TerminalBridge.shellTitleRetryDelay(consecutiveFailureCount: 1) == 30)
        #expect(TerminalBridge.shellTitleRetryDelay(consecutiveFailureCount: 20) == 300)
    }

    @Test
    func hostAndTmuxSessionArePartOfThePersistentIdentity() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = TerminalBridge.ShellTitleIdentity(
            hostID: hostID,
            sessionCreated: 100,
            windowID: 7,
            provider: "claude",
            providerSessionID: "session"
        )
        let differentTmuxSession = TerminalBridge.ShellTitleIdentity(
            hostID: hostID,
            sessionCreated: 101,
            windowID: 7,
            provider: "claude",
            providerSessionID: "session"
        )

        #expect(first != differentTmuxSession)
        #expect(Set([first, differentTmuxSession]).count == 2)
    }

    @Test
    func rejectsResultsFromAnOlderAgentRevisionOrConnection() {
        let identity = TerminalBridge.ShellTitleIdentity(
            hostID: UUID(),
            sessionCreated: 100,
            windowID: 7,
            provider: "codex",
            providerSessionID: "thread"
        )

        #expect(TerminalBridge.isShellTitleGenerationResultCurrent(
            requestIdentity: identity,
            requestRevision: 4,
            requestConnectionGeneration: 2,
            currentIdentity: identity,
            currentRevision: 4,
            currentConnectionGeneration: 2
        ))
        #expect(!TerminalBridge.isShellTitleGenerationResultCurrent(
            requestIdentity: identity,
            requestRevision: 4,
            requestConnectionGeneration: 2,
            currentIdentity: identity,
            currentRevision: 5,
            currentConnectionGeneration: 2
        ))
    }

    @Test
    func buildsBoundedModelContextFromTypedHostState() async {
        let json = """
        {
          "schema_version": 1,
          "provider": "claude",
          "provider_session_id": "session-1",
          "completed_turn_count": 2,
          "revision": 4,
          "recent_event_ids": ["turn:1", "turn:2"],
          "recent_turns": [
            {
              "event_id": "1",
              "prompt": "Inspect the title bug",
              "assistant_message": "Found the viewport heuristic"
            },
            {
              "event_id": "2",
              "prompt": "Implement the fix",
              "assistant_message": "Moved scheduling to completed turns"
            }
          ]
        }
        """

        let context = await TerminalBridge.shellTitleContext(fromHostStateJSON: json)

        #expect(context?.contains("Agent: claude") == true)
        #expect(context?.contains("Inspect the title bug") == true)
        #expect(context?.contains("Moved scheduling to completed turns") == true)
    }
}
