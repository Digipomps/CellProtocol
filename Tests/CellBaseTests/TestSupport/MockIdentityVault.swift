// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@testable import CellBase

actor MockIdentityVault: IdentityVaultProtocol {
    private var identitiesByContext: [String: Identity] = [:]
    private var idCounter = 1

    func initialize() async -> IdentityVaultProtocol {
        return self
    }

    func addIdentity(identity: inout Identity, for identityContext: String) async {
        identity.identityVault = self
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
        identitiesByContext[identityContext] = newIdentity
        return newIdentity
    }

    func saveIdentity(_ identity: Identity) async {
        identitiesByContext[identity.displayName] = identity
    }

    func identityExistInVault(_ identity: Identity) async -> Bool {
        identitiesByContext.values.contains { $0.uuid == identity.uuid }
    }

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        return messageData + identity.uuid.data(using: .utf8, allowLossyConversion: false)!
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        let expected = messageData + identity.uuid.data(using: .utf8, allowLossyConversion: false)!
        return signature == expected
    }

    func randomBytes64() async -> Data? {
        return Data(repeating: 0xAB, count: 64)
    }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        return ("test-key-\(tag)", "test-iv-\(tag)")
    }
}
