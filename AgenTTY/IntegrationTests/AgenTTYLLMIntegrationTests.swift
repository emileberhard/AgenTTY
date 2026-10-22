import Foundation
import Testing
@testable import AgenTTY_iOS_Dev

@Suite("Live LLM integration")
nonisolated struct AgenTTYLLMIntegrationTests {
    @Test("Gemini decodes and preserves a typed shell title")
    func geminiDecodesAndPreservesTypedShellTitle() async throws {
        _ = try AgenTTYDictation.router()

        let title = try await AgenTTYLLMClient.generateShellTitle(
            from: """
            The user asked the coding assistant to write a short science-fiction story about
            a programmer debugging a satellite that mysteriously drifts off course.
            """,
            provider: .gemini,
            model: "gemini-3.1-flash-lite",
            maxCharacters: 40
        )

        #expect(!title.isEmpty)
        #expect(title.count <= 40)
        #expect(title == title.trimmingCharacters(in: .whitespacesAndNewlines))

        let preservedTitle = try await AgenTTYLLMClient.generateShellTitle(
            from: """
            The user asked the coding assistant to write a short science-fiction story about
            a programmer debugging a satellite that mysteriously drifts off course.
            """,
            provider: .gemini,
            model: "gemini-3.1-flash-lite",
            maxCharacters: 40,
            currentTitle: title
        )

        #expect(preservedTitle == title)
    }
}
