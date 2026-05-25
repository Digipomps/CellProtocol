// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public actor EphemeralIdentityVault: IdentityVaultProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private var privateKeysByUUID: [String: Curve25519.Signing.PrivateKey] = [:]
    private var idCounter = 1

    public init() {}

    public func initialize() async -> IdentityVaultProtocol {
        self
    }

    public func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        ensureSigningKey(for: identity)
        identitiesByContext[identityContext] = identity
    }

    public func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else { return nil }
        let suffix = String(format: "%012d", idCounter)
        idCounter += 1
        let uuidString = "00000000-0000-0000-0000-\(suffix)"
        let identity = Identity(uuidString, displayName: identityContext, identityVault: self)
        ensureSigningKey(for: identity)
        identitiesByContext[identityContext] = identity
        return identity
    }

    public func identity(forUUID uuid: String) async -> Identity? {
        identitiesByContext.values.first { $0.uuid == uuid }
    }

    public func identityExistInVault(_ identity: Identity) async -> Bool {
        identitiesByContext.values.contains { storedIdentity in
            guard storedIdentity.uuid == identity.uuid else { return false }
            return publicSigningKeyMatches(requested: identity, stored: storedIdentity)
        }
    }

    public func saveIdentity(_ identity: Identity) async {
        ensureSigningKey(for: identity)
        identitiesByContext[identity.displayName] = identity
    }

    public func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        if let storedIdentity = await self.identity(forUUID: identity.uuid),
           !publicSigningKeyMatches(requested: identity, stored: storedIdentity) {
            throw EphemeralIdentityVaultError.publicKeyMismatch
        }
        guard let privateKey = privateKeysByUUID[identity.uuid] else {
            throw EphemeralIdentityVaultError.noPrivateKey
        }
        return try privateKey.signature(for: messageData)
    }

    public func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    public func randomBytes64() async -> Data? {
        let bytes = (0..<64).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes)
    }

    public func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        ("ephemeral-key-\(tag)", "ephemeral-iv-\(tag)")
    }

    private func ensureSigningKey(for identity: Identity) {
        if privateKeysByUUID[identity.uuid] == nil, identity.publicSecureKey == nil {
            let privateKey = Curve25519.Signing.PrivateKey()
            privateKeysByUUID[identity.uuid] = privateKey
            identity.publicSecureKey = SecureKey(
                date: Date(),
                privateKey: false,
                use: .signature,
                algorithm: .EdDSA,
                size: 32,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: privateKey.publicKey.rawRepresentation
            )
        }
    }

    private func publicSigningKeyMatches(requested: Identity, stored: Identity) -> Bool {
        guard
            let requestedFingerprint = requested.signingPublicKeyFingerprint,
            let storedFingerprint = stored.signingPublicKeyFingerprint
        else {
            return false
        }
        return requestedFingerprint == storedFingerprint
    }
}

public enum EphemeralIdentityVaultError: Error {
    case noPrivateKey
    case publicKeyMismatch
}
