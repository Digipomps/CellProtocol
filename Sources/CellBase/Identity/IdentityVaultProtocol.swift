// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol IdentityVaultProtocol: Sendable {
    func identityVaultReference() async -> String?
    func initialize() async -> IdentityVaultProtocol
    func addIdentity(identity: inout Identity, for identityContext: String) async
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity?
    func identity(forUUID uuid: String) async -> Identity?
    func identityExistInVault(_ identity: Identity) async -> Bool
    func identityDomainBinding(for identity: Identity) async -> IdentityDomainBinding?
    func saveIdentity(_ identity: Identity) async
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data
    func signMessageForIdentity(messageData: Data, identity: Identity, bridgeConnectContext: BridgeConnectSigningContext) async throws -> Data
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool
    func randomBytes64() async -> Data?
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) // TODO: This should probably be elsewhere
//    func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async
}

public extension IdentityVaultProtocol {
    /// Source compatibility for ordinary vaults. Strict holder vaults override this
    /// requirement and perform live one-shot admission at their private signer.
    func signMessageForIdentity(messageData: Data, identity: Identity, bridgeConnectContext: BridgeConnectSigningContext) async throws -> Data {
        try await signMessageForIdentity(messageData: messageData, identity: identity)
    }

    func identityVaultReference() async -> String? {
        nil
    }

    func identity(forUUID uuid: String) async -> Identity? {
        nil
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        false
    }

    func identityDomainBinding(for identity: Identity) async -> IdentityDomainBinding? {
        nil
    }
}
