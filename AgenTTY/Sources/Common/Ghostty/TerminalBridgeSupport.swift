import Foundation

extension TerminalBridge {
    static func parseTmuxWindowStates(from output: String) -> [TmuxWindowState] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard columns.count == 4 else { return nil }
                guard let windowID = parseTmuxWindowID(columns[0]) else { return nil }
                guard let windowIndex = Int(columns[1]) else { return nil }
                let isActive = String(columns[2]).trimmingCharacters(in: .whitespaces) == "1"
                let workingDirectoryPath = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                return TmuxWindowState(
                    id: windowID,
                    index: windowIndex,
                    isActive: isActive,
                    lineCount: 0,
                    workingDirectoryPath: workingDirectoryPath,
                    alternateScreenActive: false,
                    sessionCreated: nil,
                    agentTitleProvider: nil,
                    agentTitleSessionID: nil,
                    agentCompletedTurnCount: nil,
                    agentTitleRevision: nil
                )
            }
            // Keep indicator/swipe order as oldest -> newest creation order, independent of tmux index gaps/reuse.
            .sorted(by: { lhs, rhs in
                if lhs.id == rhs.id {
                    return lhs.index < rhs.index
                }
                return lhs.id < rhs.id
            })
    }

    static func parseTmuxWindowStatesWithLineCounts(from output: String) -> [TmuxWindowState] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(separator: "\t", maxSplits: 10, omittingEmptySubsequences: false)
                guard columns.count == 11 else { return nil }
                guard let windowID = parseTmuxWindowID(columns[0]) else { return nil }
                guard let windowIndex = Int(columns[1]) else { return nil }
                let isActive = String(columns[2]).trimmingCharacters(in: .whitespaces) == "1"
                let historySize = Int(columns[3]) ?? 0
                let alternateScreenActive = String(columns[4]).trimmingCharacters(in: .whitespaces) == "1"
                let sessionCreated = Int64(columns[5])
                let agentTitleProvider = nonEmptyString(columns[6])
                let agentTitleSessionID = nonEmptyString(columns[7])
                let agentCompletedTurnCount = Int(columns[8])
                let agentTitleRevision = Int(columns[9])
                let workingDirectoryPath = String(columns[10]).trimmingCharacters(in: .whitespacesAndNewlines)
                return TmuxWindowState(
                    id: windowID,
                    index: windowIndex,
                    isActive: isActive,
                    lineCount: max(0, historySize),
                    workingDirectoryPath: workingDirectoryPath,
                    alternateScreenActive: alternateScreenActive,
                    sessionCreated: sessionCreated,
                    agentTitleProvider: agentTitleProvider,
                    agentTitleSessionID: agentTitleSessionID,
                    agentCompletedTurnCount: agentCompletedTurnCount,
                    agentTitleRevision: agentTitleRevision
                )
            }
            // Keep indicator/swipe order as oldest -> newest creation order, independent of tmux index gaps/reuse.
            .sorted(by: { lhs, rhs in
                if lhs.id == rhs.id {
                    return lhs.index < rhs.index
                }
                return lhs.id < rhs.id
            })
    }

    static func parseTmuxWindowID(_ rawValue: Substring) -> Int? {
        TmuxWindowIDParsing.parse(rawValue)
    }

    private static func nonEmptyString(_ rawValue: Substring) -> String? {
        let value = String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizeWorkingDirectoryPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseGitHeadResolution(from output: String) -> GitHeadResolution {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.hasPrefix("repo:") {
            let rawBranchName = String(trimmedOutput.dropFirst("repo:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .repository(branchName: rawBranchName.isEmpty ? nil : rawBranchName)
        }
        if trimmedOutput.hasPrefix("norepo:") {
            return .notRepository
        }
        return .unknown
    }

    static func gitHeadStateCommand(forWorkingDirectoryPath path: String) -> String {
        let escapedPath = shellSingleQuoted(path)
        return """
set +e
TARGET_PATH=\(escapedPath)

if [ -z "$TARGET_PATH" ]; then
  printf 'norepo:'
elif git -C "$TARGET_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch_name="$(git -C "$TARGET_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [ -n "$branch_name" ]; then
    printf 'repo:%s' "$branch_name"
  else
    detached_head="$(git -C "$TARGET_PATH" rev-parse --short HEAD 2>/dev/null)"
    printf 'repo:%s' "$detached_head"
  fi
else
  printf 'norepo:'
fi
"""
    }

    static func shellSingleQuoted(_ rawValue: String) -> String {
        let escapedValue = rawValue.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escapedValue)'"
    }

    static func shellTitleGenerationMilestone(
        for lineCount: Int,
        initialThreshold: Int,
        secondThreshold: Int,
        earlyRefreshLineCutoff: Int,
        earlyRefreshInterval: Int,
        frequentRefreshLineCutoff: Int,
        frequentRefreshInterval: Int,
        steadyRefreshInterval: Int
    ) -> Int {
        let normalizedLineCount = max(lineCount, 0)
        guard normalizedLineCount >= initialThreshold else { return 0 }

        let safeSecondThreshold = max(secondThreshold, initialThreshold + 1)
        if normalizedLineCount < safeSecondThreshold {
            return initialThreshold
        }

        if normalizedLineCount < 100 {
            return safeSecondThreshold
        }

        let safeEarlyCutoff = max(earlyRefreshLineCutoff, 100)
        let safeEarlyInterval = max(earlyRefreshInterval, 1)
        if normalizedLineCount <= safeEarlyCutoff {
            return (normalizedLineCount / safeEarlyInterval) * safeEarlyInterval
        }

        let milestoneAtEarlyCutoff = (safeEarlyCutoff / safeEarlyInterval) * safeEarlyInterval
        let safeFrequentInterval = max(frequentRefreshInterval, 1)
        if normalizedLineCount < frequentRefreshLineCutoff {
            let normalizedFrequentDelta = normalizedLineCount - safeEarlyCutoff
            return milestoneAtEarlyCutoff + (normalizedFrequentDelta / safeFrequentInterval) * safeFrequentInterval
        }

        let milestoneAtFrequentCutoff = milestoneAtEarlyCutoff +
            ((frequentRefreshLineCutoff - safeEarlyCutoff) / safeFrequentInterval) * safeFrequentInterval
        let safeSteadyInterval = max(steadyRefreshInterval, 1)
        let normalizedSteadyDelta = normalizedLineCount - frequentRefreshLineCutoff
        return milestoneAtFrequentCutoff + (normalizedSteadyDelta / safeSteadyInterval) * safeSteadyInterval
    }

    static func shellTitleTurnMilestone(for completedTurnCount: Int) -> Int {
        switch max(completedTurnCount, 0) {
        case 0:
            0
        case 1...5:
            completedTurnCount
        case 6..<10:
            5
        case let count:
            (count / 10) * 10
        }
    }

    static func shouldScheduleShellTitleGeneration(
        currentMilestone: Int,
        lastGeneratedMilestone: Int,
        retryAfter: Date?,
        now: Date
    ) -> Bool {
        currentMilestone > lastGeneratedMilestone
            && retryAfter.map { $0 <= now } != false
    }

    static func shellTitleRetryDelay(consecutiveFailureCount: Int) -> TimeInterval {
        let exponent = min(max(consecutiveFailureCount - 1, 0), 4)
        return min(30 * pow(2, Double(exponent)), 5 * 60)
    }

    static func isShellTitleGenerationResultCurrent(
        requestIdentity: ShellTitleIdentity,
        requestRevision: Int,
        requestConnectionGeneration: Int,
        currentIdentity: ShellTitleIdentity?,
        currentRevision: Int?,
        currentConnectionGeneration: Int
    ) -> Bool {
        requestIdentity == currentIdentity
            && requestRevision == currentRevision
            && requestConnectionGeneration == currentConnectionGeneration
    }

    static func tmuxSelectWindowCommand(windowID: Int) -> String {
        "\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) select-window -t @\(windowID)"
    }

    static func tmuxCreateWindowAndSelectCommand(reuseRightmostWorkingDirectory: Bool) -> String {
        """
set -e
SESSION_NAME='\(AgenTTYConnection.tmuxSessionName)'
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t "$SESSION_NAME" >/dev/null 2>&1
\(tmuxCreateWindowCommandScript(reuseRightmostWorkingDirectory: reuseRightmostWorkingDirectory))
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) select-window -t "$new_window_id"
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}	#{window_index}	#{window_active}	#{pane_current_path}' | sort -t '	' -k1.2n
"""
    }

    static func tmuxCreateWindowAndRunCommand(
        _ command: String,
        maxShellCount: Int,
        reuseRightmostWorkingDirectory: Bool
    ) -> String {
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let boundedMaxShellCount = max(maxShellCount, 1)
        return """
set -e
SESSION_NAME='\(AgenTTYConnection.tmuxSessionName)'
MAX_SHELL_COUNT=\(boundedMaxShellCount)
COMMAND_BASE64=\(shellSingleQuoted(encodedCommand))

\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t "$SESSION_NAME" >/dev/null 2>&1
window_count="$(\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}' | awk 'NF { count += 1 } END { print count + 0 }')"
if [ "$window_count" -ge "$MAX_SHELL_COUNT" ]; then
  printf 'AgenTTY already has the maximum number of shells (%s).\n' "$MAX_SHELL_COUNT" >&2
  exit 1
fi

\(tmuxCreateWindowCommandScript(reuseRightmostWorkingDirectory: reuseRightmostWorkingDirectory))
printf %s "$COMMAND_BASE64" | { base64 --decode 2>/dev/null || base64 -d 2>/dev/null || base64 -D; } | \(AgenTTYHostRuntime.tmuxWrapperShellLiteral) load-buffer -
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) paste-buffer -p -d -t "$new_window_id"
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) send-keys -t "$new_window_id" Enter
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) select-window -t "$new_window_id"
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}\t#{window_index}\t#{window_active}\t#{pane_current_path}' | sort -t '\t' -k1.2n
"""
    }

    private static func tmuxCreateWindowCommandScript(reuseRightmostWorkingDirectory: Bool) -> String {
        let defaultCreateCommand = """
new_window_id="$(\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) new-window -d -P -F '#{window_id}' -t "$SESSION_NAME")"
"""
        guard reuseRightmostWorkingDirectory else {
            return defaultCreateCommand
        }

        return """
rightmost_working_directory="$(\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}	#{window_index}	#{pane_current_path}' | sort -t '	' -k1.2n | awk -F '	' 'NF { path = $3 } END { print path }')"
new_window_id=""
if [ -n "$rightmost_working_directory" ]; then
  new_window_id="$(\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) new-window -d -P -F '#{window_id}' -t "$SESSION_NAME" -c "$rightmost_working_directory" 2>/dev/null || true)"
fi
if [ -z "$new_window_id" ]; then
\(defaultCreateCommand)
fi
"""
    }

    static func tmuxShellSwipeCommand(
        direction: TerminalShellSwipeDirection,
        maxShellCount: Int,
        reuseRightmostWorkingDirectory: Bool
    ) -> String {
        let directionValue = direction == .forward ? "forward" : "backward"
        let boundedMaxShellCount = max(maxShellCount, 1)
        return """
set -e
SESSION_NAME='\(AgenTTYConnection.tmuxSessionName)'
DIRECTION='\(directionValue)'
MAX_SHELL_COUNT=\(boundedMaxShellCount)

\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t "$SESSION_NAME" >/dev/null 2>&1
window_list="$(\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}:#{window_index}:#{window_active}' | sort -t ':' -k1.2n)"

resolve_target_window_id() {
  printf '%s\\n' "$window_list" | awk -F: -v direction="$DIRECTION" '
    {
      ids[NR] = $1
      total = NR
      if ($3 == 1) {
        active = NR
      }
    }
    END {
      if (total == 0) exit
      if (active == 0) active = total
      if (direction == "forward") {
        if (active < total) print ids[active + 1]
      } else {
        if (active > 1) print ids[active - 1]
      }
    }'
}

window_count="$(printf '%s\\n' "$window_list" | awk 'NF { count += 1 } END { print count + 0 }')"
target_window_id="$(resolve_target_window_id)"

if [ -n "$target_window_id" ]; then
  \(AgenTTYHostRuntime.tmuxWrapperShellLiteral) select-window -t "$target_window_id"
elif [ "$DIRECTION" = "forward" ] && [ "$window_count" -lt "$MAX_SHELL_COUNT" ]; then
\(tmuxCreateWindowCommandScript(reuseRightmostWorkingDirectory: reuseRightmostWorkingDirectory))
  \(AgenTTYHostRuntime.tmuxWrapperShellLiteral) select-window -t "$new_window_id"
fi

\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t "$SESSION_NAME" -F '#{window_id}	#{window_index}	#{window_active}	#{pane_current_path}' | sort -t '	' -k1.2n
"""
    }

    static let tmuxListWindowsCommand = """
set -e
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t \(AgenTTYConnection.tmuxSessionName) >/dev/null 2>&1
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t \(AgenTTYConnection.tmuxSessionName) -F '#{window_id}	#{window_index}	#{window_active}	#{pane_current_path}'
"""

    static let tmuxListWindowsWithLineCountsCommand = """
set -e
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t \(AgenTTYConnection.tmuxSessionName) >/dev/null 2>&1
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) list-windows -t \(AgenTTYConnection.tmuxSessionName) -F '#{window_id}	#{window_index}	#{window_active}	#{history_size}	#{alternate_on}	#{session_created}	#{@agentty_title_provider}	#{@agentty_title_session}	#{@agentty_title_turn_count}	#{@agentty_title_revision}	#{pane_current_path}'
"""

    static func tmuxCapturePaneTailCommand(maxLines: Int) -> String {
        let boundedLineCount = max(1, min(maxLines, 400))
        return """
set -e
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t \(AgenTTYConnection.tmuxSessionName) >/dev/null 2>&1
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) capture-pane -p -J -t \(AgenTTYConnection.tmuxSessionName) -S -\(boundedLineCount)
"""
    }

    static func tmuxCapturePaneTailCommand(windowID: Int, maxLines: Int) -> String {
        let boundedLineCount = max(1, min(maxLines, 5_000))
        return """
set -e
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) has-session -t \(AgenTTYConnection.tmuxSessionName) >/dev/null 2>&1
\(AgenTTYHostRuntime.tmuxWrapperShellLiteral) capture-pane -p -J -t @\(windowID) -S -\(boundedLineCount)
"""
    }

    static func shellTitleHostStateCommand(sessionCreated: Int64, windowID: Int) -> String {
        "cat \"$HOME/.agentty/state/shell-title/\(sessionCreated)/window-\(windowID).json\""
    }

    @concurrent nonisolated static func shellTitleContext(
        fromHostStateJSON output: String
    ) async -> String? {
        guard let data = output.data(using: .utf8),
              let hostState = try? JSONDecoder().decode(ShellTitleHostState.self, from: data),
              hostState.schemaVersion == 1,
              !hostState.recentTurns.isEmpty else {
            return nil
        }

        let turns = hostState.recentTurns.suffix(5).enumerated().map { index, turn in
            """
            Turn \(index + 1)
            User: \(turn.prompt)
            Assistant: \(turn.assistantMessage)
            """
        }
        return """
        Agent: \(hostState.provider)
        Completed turns: \(hostState.completedTurnCount)

        \(turns.joined(separator: "\n\n"))
        """
    }

    static func sanitizeShellTitle(_ title: String, maxCharacters: Int) -> String {
        let collapsedWhitespace = title
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !unquoted.isEmpty else { return "" }
        return String(unquoted.prefix(maxCharacters))
    }

    static func logErrorSummary(_ error: any Error, maxCharacters: Int = 220) -> String {
        let singleLine = String(describing: error).replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= maxCharacters {
            return singleLine
        }
        return String(singleLine.prefix(maxCharacters)) + "…"
    }

    enum GitHeadResolution: Equatable {
        case unknown
        case notRepository
        case repository(branchName: String?)

        var branchName: String? {
            guard case .repository(let branchName) = self else { return nil }
            return branchName
        }
    }

    struct TerminalWindowSize {
        let columns: Int
        let rows: Int
        let widthPx: Int
        let heightPx: Int

        init(columns: Int, rows: Int, widthPx: Int, heightPx: Int) {
            self.columns = max(columns, 1)
            self.rows = max(rows, 1)
            self.widthPx = max(widthPx, 0)
            self.heightPx = max(heightPx, 0)
        }
    }

    struct ShellStateSignature: Equatable {
        let windowIds: [Int]
        let activePosition: Int
    }

    struct ActiveShellContextSignature: Equatable {
        let windowID: Int
        let workingDirectoryPath: String
        let branchName: String?
    }

    struct ShellContextBranchLookupRequest {
        let requestID: Int
        let windowID: Int
        let workingDirectoryPath: String
    }

    struct TmuxWindowState {
        let id: Int
        let index: Int
        let isActive: Bool
        let lineCount: Int
        let workingDirectoryPath: String
        let alternateScreenActive: Bool
        let sessionCreated: Int64?
        let agentTitleProvider: String?
        let agentTitleSessionID: String?
        let agentCompletedTurnCount: Int?
        let agentTitleRevision: Int?

        var hasAnyAgentTitleMetadata: Bool {
            agentTitleProvider != nil
                || agentTitleSessionID != nil
                || agentCompletedTurnCount != nil
                || agentTitleRevision != nil
        }
    }

    struct ShellTitleIdentity: Codable, Hashable, Sendable {
        let hostID: UUID
        let sessionCreated: Int64
        let windowID: Int
        let provider: String
        let providerSessionID: String
    }

    struct ShellTitleObservation: Sendable {
        let identity: ShellTitleIdentity
        let sourceRevision: Int
    }

    struct ShellTitleState: Codable, Sendable {
        var latestProgress: Int
        var lastGeneratedMilestone: Int
        var title: String
        var consecutiveFailureCount: Int
        var retryAfter: Date?
        var updatedAt: Date
    }

    struct ShellTitleGenerationRequest: Sendable {
        let identity: ShellTitleIdentity
        let windowID: Int
        let milestone: Int
        let sourceRevision: Int
        let connectionGeneration: Int
        let contextCommand: String
        let usesHostAgentState: Bool
        let currentTitle: String
    }

    enum ShellTitleGenerationOutcome: Sendable {
        case success(String)
        case failure
    }

    struct PersistedShellTitleState: Codable, Sendable {
        let identity: ShellTitleIdentity
        let state: ShellTitleState
    }

    nonisolated struct ShellTitleHostState: Decodable, Sendable {
        let schemaVersion: Int
        let provider: String
        let completedTurnCount: Int
        let recentTurns: [ShellTitleHostTurn]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case provider
            case completedTurnCount = "completed_turn_count"
            case recentTurns = "recent_turns"
        }
    }

    nonisolated struct ShellTitleHostTurn: Decodable, Sendable {
        let prompt: String
        let assistantMessage: String

        enum CodingKeys: String, CodingKey {
            case prompt
            case assistantMessage = "assistant_message"
        }
    }

    enum ShellTitlePersistence {
        static let storageKey = "agentty.shell_title_state.v2"
        static let obsoleteStorageKey = "agentty.shell_title_state.v1"
        static let maximumPersistedStateCount = 100

        static func loadStates() -> [ShellTitleIdentity: ShellTitleState] {
            UserDefaults.standard.removeObject(forKey: obsoleteStorageKey)
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
            do {
                let persistedStates = try JSONDecoder().decode([PersistedShellTitleState].self, from: data)
                return persistedStates.reduce(into: [:]) { partialResult, entry in
                    partialResult[entry.identity] = entry.state
                }
            } catch {
                EsmaLog.terminal.error(
                    "failed to decode persisted shell title state error=\(String(describing: error), privacy: .public)"
                )
                return [:]
            }
        }

        static func saveStates(_ states: [ShellTitleIdentity: ShellTitleState]) {
            let persistedStates = states
                .map { PersistedShellTitleState(identity: $0.key, state: $0.value) }
                .sorted(by: { $0.state.updatedAt > $1.state.updatedAt })
                .prefix(maximumPersistedStateCount)
            do {
                let data = try JSONEncoder().encode(Array(persistedStates))
                UserDefaults.standard.set(data, forKey: storageKey)
            } catch {
                EsmaLog.terminal.error(
                    "failed to persist shell title state error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
