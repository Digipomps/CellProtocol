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
    /// Removes the identity's private keys and stored identity for good
    /// (account erasure, keyChoice `destroy`). Vaults that cannot do this
    /// must throw `IdentityVaultLifecycleError.notSupported`, never pretend.
    func destroyIdentity(_ identity: Identity) async throws
    /// Makes the identity unusable for signing until `until` (keyChoice
    /// `lock30`). Same rule: throw `notSupported` rather than pretend.
    func lockIdentity(_ identity: Identity, until: Date) async throws
    /// Undoes `lockIdentity` (the person regrets within the lock period).
    func unlockIdentity(_ identity: Identity) async throws
//    func setPostAuthenticationInitializer(initializer: @escaping () -> ()) async
}

public enum IdentityVaultLifecycleError: Error, Equatable, Sendable {
    /// The vault does not implement destroy or lock. Nothing was removed.
    case notSupported
    /// Signing is refused until the date (keyChoice `lock30`).
    case locked(until: Date)
}

public extension IdentityVaultProtocol {
    /// Default: refuse. A vault only deletes when it really implements it.
    func destroyIdentity(_ identity: Identity) async throws {
        throw IdentityVaultLifecycleError.notSupported
    }

    /// Default: refuse. A vault only locks when it really implements it.
    func lockIdentity(_ identity: Identity, until: Date) async throws {
        throw IdentityVaultLifecycleError.notSupported
    }

    func unlockIdentity(_ identity: Identity) async throws {
        throw IdentityVaultLifecycleError.notSupported
    }

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
