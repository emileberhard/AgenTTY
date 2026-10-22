import Foundation

nonisolated struct AgenTTYLocalSSHBootstrapSecrets: Decodable, Sendable {
    let host: String
    let label: String
    let username: String
    let privateKeyRawBase64: String
    let secondaryHost: String?
}

nonisolated struct AgenTTYLocalLLMRouterSecrets: Decodable, Sendable {
    let origin: String
    let keyBase64: String
}

nonisolated enum AgenTTYLocalSecrets {
    private nonisolated struct FileContents: Decodable, Sendable {
        let sshBootstrap: AgenTTYLocalSSHBootstrapSecrets?
        let llmRouter: AgenTTYLocalLLMRouterSecrets?
    }

    static var sshBootstrap: AgenTTYLocalSSHBootstrapSecrets? {
        current?.sshBootstrap
    }

    static var llmRouter: AgenTTYLocalLLMRouterSecrets? {
        current?.llmRouter
    }

    private static var current: FileContents? {
        guard let url = Bundle.main.url(forResource: "AgenTTYLocalSecrets", withExtension: "json") else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FileContents.self, from: data)
        } catch {
            assertionFailure("Invalid AgenTTYLocalSecrets.json: \(error)")
            return nil
        }
    }
}
