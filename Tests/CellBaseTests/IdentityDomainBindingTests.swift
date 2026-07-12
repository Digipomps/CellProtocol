// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class IdentityDomainBindingTests: XCTestCase {
    func testEphemeralVaultIssuesCanonicalDomainBinding() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(
            for: "domain:personal:contact",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(identityValue)

        let bindingValue = await vault.identityDomainBinding(for: identity)
        let binding = try XCTUnwrap(bindingValue)
        XCTAssertEqual(binding.schema, IdentityDomainBinding.currentSchema)
        XCTAssertEqual(binding.bindingKind, IdentityDomainBinding.vaultContextKind)
        XCTAssertEqual(binding.domain, "domain:personal:contact")
        XCTAssertEqual(binding.identityUUID, identity.uuid)
        XCTAssertTrue(binding.matches(identity: identity))
        XCTAssertFalse(binding.grantsAuthority)

        let encoded = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(IdentityDomainBinding.self, from: encoded)
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(IdentityDomainBinding(object: binding.objectValue), binding)
    }

    func testEphemeralVaultRejectsForgedIdentityWithSameUUID() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(
            for: "domain:personal:contact",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(identityValue)
        let attackerVault = EphemeralIdentityVault()
        let attackerValue = await attackerVault.identity(
            for: "domain:attacker",
            makeNewIfNotFound: true
        )
        let attacker = try XCTUnwrap(attackerValue)
        let forged = Identity(identity.uuid, displayName: "Forged", identityVault: attackerVault)
        forged.publicSecureKey = attacker.publicSecureKey

        let forgedBinding = await vault.identityDomainBinding(for: forged)
        XCTAssertNil(forgedBinding)
    }

    func testEphemeralVaultFailsClosedForAmbiguousContextAliases() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(
            for: "domain:personal:contact",
            makeNewIfNotFound: true
        )
        var identity = try XCTUnwrap(identityValue)
        await vault.addIdentity(identity: &identity, for: "domain:personal:alias")

        let ambiguousBinding = await vault.identityDomainBinding(for: identity)
        XCTAssertNil(ambiguousBinding)
    }

    func testBindingObjectRejectsAuthorityAndFingerprintMismatch() async throws {
        let vault = EphemeralIdentityVault()
        let identityValue = await vault.identity(
            for: "domain:personal:contact",
            makeNewIfNotFound: true
        )
        let identity = try XCTUnwrap(identityValue)
        let bindingValue = await vault.identityDomainBinding(for: identity)
        let binding = try XCTUnwrap(bindingValue)
        var authority = binding.objectValue
        authority["grantsAuthority"] = .bool(true)
        XCTAssertNil(IdentityDomainBinding(object: authority))
        let authorityJSON = Data("""
        {
          "schema": "cellprotocol.identity.domain-binding.v1",
          "bindingKind": "vault_context",
          "domain": "domain:personal:contact",
          "identityUUID": "identity",
          "signingKeyFingerprint": "fingerprint",
          "grantsAuthority": true
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            IdentityDomainBinding.self,
            from: authorityJSON
        ))

        var wrongFingerprint = binding.objectValue
        wrongFingerprint["signingKeyFingerprint"] = .string("forged")
        let parsed = try XCTUnwrap(IdentityDomainBinding(object: wrongFingerprint))
        XCTAssertFalse(parsed.matches(identity: identity))
    }
}
