import Foundation

enum AgenTTYSSHUserAuthenticationResolver {
    @concurrent
    nonisolated static func resolve(
        keyMaterialStore: AgenTTYSSHKeyMaterialStore,
        passwordStore: AgenTTYSSHPasswordStore,
        connectionTarget: AgenTTYConnectionTarget
    ) async throws -> AgenTTYSSHUserAuthentication {
        switch connectionTarget.authentication {
        case .key(let keyID):
            let material = try keyMaterialStore.loadMaterial(for: keyID)
            return .privateKey(
                username: connectionTarget.username,
                privateKey: try material.makeNIOSSHPrivateKey()
            )
        case .passwordBootstrap(_, let credentialID):
            return .password(
                username: connectionTarget.username,
                password: try passwordStore.loadPassword(for: credentialID)
            )
        }
    }
}
