// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

actor MockIdentityVault: IdentityVaultProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private var privateKeysByUUID: [String: Curve25519.Signing.PrivateKey] = [:]
    private var idCounter = 1

    func initialize() async -> IdentityVaultProtocol {
        return self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
        ensureSigningKey(for: identity)
        identitiesByContext[identityContext] = identity
    }

    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? {
        if let existing = identitiesByContext[identityContext] {
            return existing
        }
        guard makeNewIfNotFound else { return nil }
        let suffix = String(format: "%012d", idCounter)
        idCounter += 1
        let uuidString = "00000000-0000-0000-0000-\(suffix)"
        let newIdentity = Identity(uuidString, displayName: identityContext, identityVault: self)
        ensureSigningKey(for: newIdentity)
        identitiesByContext[identityContext] = newIdentity
        return newIdentity
    }

    func identity(forUUID uuid: String) async -> Identity? {
        identitiesByContext.values.first { $0.uuid == uuid }
    }

    func saveIdentity(_ identity: Identity) async {
        ensureSigningKey(for: identity)
        identitiesByContext[identity.displayName] = identity
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        identitiesByContext.values.contains { $0.uuid == identity.uuid }
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        guard let privateKey = privateKeysByUUID[identity.uuid] else {
            throw MockIdentityVaultError.noPrivateKey
        }
        return try privateKey.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        guard let compressedKey = identity.publicSecureKey?.compressedKey else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: compressedKey)
        return publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? {
        return Data(repeating: 0xAB, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        return ("test-key-\(tag)", "test-iv-\(tag)")
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

    enum MockIdentityVaultError: Error {
        case noPrivateKey
    }
}
