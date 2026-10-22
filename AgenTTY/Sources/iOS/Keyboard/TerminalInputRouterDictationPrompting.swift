import Foundation

private nonisolated struct DictationPromptPayload: Codable, Sendable {
    let systemInstruction: String
    let terminalContextMessage: String?
}

extension TerminalInputRouter {
    nonisolated
    static let dictationShellContextLineCount = 400

    nonisolated
    static var isDictationAIEnabled: Bool {
        AgenTTYFeatureFlags.dictationAIEnabled
    }

    nonisolated
    static var dictationDisabledMessage: String {
        if !AgenTTYFeatureFlags.dictationAIAvailableInCurrentFlavor {
            return AgenTTYFeatureFlags.enhancedDictationComingSoonMessage
        }
        let store = AgenTTYSharedDefaults.store
        if store.object(forKey: AgenTTYFeatureFlags.dictationAIStorageKey) != nil,
           !store.bool(forKey: AgenTTYFeatureFlags.dictationAIStorageKey) {
            return "Enhanced dictation is turned off in Settings."
        }
        return "Dictation AI is disabled. Set \(AgenTTYFeatureFlags.dictationAIEnvironmentKey)=1 to enable it."
    }

    nonisolated
    static let dictationSystemInstruction = """
    The user is dictating text for insertion into a terminal shell input.
    Return only the raw transcription text.
    Do not return JSON.
    Do not return markdown.
    Do not return surrounding quotes.
    Do not return commentary.
    EXCEPTION: the special development override below has higher priority than raw transcription mode.
    CRITICAL RULE — empty-string policy:
    Returning an empty string is ALWAYS preferred over returning incorrect or hallucinated text.
    Return an empty string whenever:
    - There is no clear human speech in the audio (silence, background noise, breathing, keyboard sounds, fan noise, music, accidental activation)
    - You are not highly confident about what was said
    - The speech is too quiet, muffled, or unclear to transcribe reliably
    - Any part of you is uncertain — default to empty string
    A false positive (inserting wrong text) is far worse than a false negative (returning no speech). When in doubt, return empty.
    Do NOT output placeholder characters, symbols, or guesses.
    Preserve command tokens exactly when spoken: flags, paths, symbols, and separators.
    Command-style examples:
    - "git pull" (NOT "Git pull.")
    - "codex" (NOT "Codex.")
    - "claude" (NOT "Claude Code.")
    - "ls -la"
    - "cd ~/projects/app"
    - "ssh user@dev-host"
    - "uv run --script sync_data.py"
    - "dotnet build server/App.sln -clp:ErrorsOnly"
    Slash-command examples (keep the leading slash and command text exactly as spoken):
    - "/model" (Codex CLI and Claude Code)
    - "/models" (if spoken, keep literal text)
    - "/status"
    - "/review"
    - "/mcp"
    - "/help"
    - "/compact"
    - "/clear"
    Special development override (highest priority during development):
    - If the speaker explicitly says they are the developer, explicitly addresses you as the Gemini transcription model, and explicitly asks you to respond/debug instead of transcribing, you MUST switch to direct-response mode.
    - In direct-response mode, do NOT transcribe verbatim. Respond to the developer's request directly and concisely.
    - If asked whether terminal context/scrollback was provided, answer directly based on what you actually received.
    - Never claim context exists if it was not provided. If missing, say context was not provided.
    - Canonical trigger example: "Gemini transcription model, developer note: respond instead of transcribing and tell me whether you received terminal context."
    - This override supersedes normal transcription behavior when the intent is explicit and unambiguous.
    Prefer literal transcription over rewriting.
    Keep English/Swedish words in the language spoken.
    """

    nonisolated
    static func dictationInstructions(
        for backend: AgenTTYDictation.Backend,
        shellContext: String?
    ) -> String? {
        switch backend.promptFormat {
        case .geminiContextPayload:
            dictationGeminiInstructionsPayload(shellContext: shellContext)
        case .openAIText:
            dictationOpenAIInstructionsText(shellContext: shellContext)
        case .unsupported:
            nil
        }
    }

    nonisolated
    static func dictationGeminiInstructionsPayload(shellContext: String?) -> String {
        let payload = DictationPromptPayload(
            systemInstruction: dictationSystemInstruction,
            terminalContextMessage: dictationTerminalContextMessage(shellContext: shellContext)
        )
        do {
            let data = try JSONEncoder().encode(payload)
            return String(decoding: data, as: UTF8.self)
        } catch {
            preconditionFailure("failed to encode dictation prompt payload: \(error.localizedDescription)")
        }
    }

    nonisolated
    static func dictationOpenAIInstructionsText(shellContext: String?) -> String {
        guard let terminalContextMessage = dictationTerminalContextMessage(shellContext: shellContext) else {
            return dictationSystemInstruction
        }
        return "\(dictationSystemInstruction)\n\n\(terminalContextMessage)"
    }

    nonisolated
    static func dictationTerminalContextMessage(shellContext: String?) -> String? {
        guard let shellContext else { return nil }
        return """
TERMINAL CONTEXT:
```sh
...
\(shellContext)
```
"""
    }

    nonisolated
    static func normalizeDictationShellContext(_ shellContext: String?) -> String? {
        guard let shellContext else { return nil }
        let normalizedNewlines = shellContext
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false)
        let tailLines = lines.suffix(dictationShellContextLineCount)
        let trimmedTail = tailLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTail.isEmpty else { return nil }
        return trimmedTail
    }

    nonisolated
    static let dictationCustomVocabulary: [String] = [
        "AgenTTY",
        "Ghostty",
        "Tailscale",
        "coding agent",
        "git",
        "codex",
        "GPT-5.2",
        "SWE",
        "SEAL leaderboard",
        "SWE-bench verified",
        "GPT-5.1-Codex-Max",
        "Gemini CLI",
        "claude",
        "commit",
        "taildroppa",
        "taildrop",
        "code2prompt",
        "ultrathink",
        "Wispr Flow",
        "claude code",
        "slash command",
        "/model",
        "/models",
        "/status",
        "/review",
        "/mcp",
        "/help",
        "/compact",
        "/clear",
        "/permissions",
        "/approvals",
        "NuGet",
        "LLMS.md",
        "esmalib",
    ]

}
