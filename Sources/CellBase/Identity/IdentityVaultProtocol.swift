// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol IdentityVaultProtocol: Sendable {
    func initialize() async -> IdentityVaultProtocol
    func addIdentity(identity: inout Identity, for identityContext: String) async
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity?
    func identity(forUUID uuid: String) async -> Identity?
    func identityExistInVault(_ identity: Identity) async -> Bool
    func saveIdentity(_ identity: Identity) async
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool
    func randomBytes64() async -> Data?
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) // TODO: This should probably be elsewhere
//    func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async
}

public extension IdentityVaultProtocol {
    func identity(forUUID uuid: String) async -> Identity? {
        nil
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        false
    }
}
