// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import Security
@testable import CellApple
@testable import CellBase

final class AppleIdentityVaultKeyStorageTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
    }

    func testNewVaultIdentityUsesKeychainReferenceInsteadOfEmbeddedPrivateKey() throws {
        let uuid = UUID().uuidString
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let vaultIdentity = VaultIdentity(uuid: uuid, displayName: "Test identity")
        if vaultIdentity.publicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        XCTAssertTrue(vaultIdentity.privateKey.isEmpty)
        XCTAssertNotNil(vaultIdentity.privateKeyApplicationTag)
        XCTAssertFalse(vaultIdentity.publicKey.isEmpty)
        XCTAssertEqual(vaultIdentity.publicSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(vaultIdentity.publicSecureKey?.curveType, .P256)
        XCTAssertEqual(vaultIdentity.privateSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(vaultIdentity.privateSecureKey?.curveType, .P256)
        XCTAssertNil(vaultIdentity.privateSecureKey?.compressedKey)
    }

    func testVaultIdentityCodingRoundTripsPrivateKeyApplicationTag() throws {
        let uuid = UUID().uuidString
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let original = VaultIdentity(uuid: uuid, displayName: "Roundtrip identity")
        if original.publicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VaultIdentity.self, from: encoded)

        XCTAssertEqual(decoded.uuid, original.uuid)
        XCTAssertEqual(decoded.privateKeyApplicationTag, original.privateKeyApplicationTag)
        XCTAssertTrue(decoded.privateKey.isEmpty)
        XCTAssertEqual(decoded.publicSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(decoded.publicSecureKey?.curveType, .P256)
        XCTAssertEqual(decoded.privateSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(decoded.privateSecureKey?.curveType, .P256)
        XCTAssertNil(decoded.privateSecureKey?.compressedKey)
    }

    func testVaultIdentityValueForKeyPublishesStoredValueForRequester() async throws {
        var vaultIdentity = VaultIdentity()
        vaultIdentity.properties?["nickname"] = .string("Ada")

        let value = try await vaultIdentity
            .valueForKey(key: "nickname", requester: vaultIdentity)
            .getOneWithTimeout(1)

        guard case let .string(nickname) = value as? ValueType else {
            return XCTFail("Expected ValueType.string from VaultIdentity property publisher")
        }
        XCTAssertEqual(nickname, "Ada")
    }

    func testLegacyEmbeddedPrivateKeyStillSigns() async throws {
        let uuid = UUID().uuidString
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let keys = try createKeyPairForDomainv2(domainString: uuid)
        var vaultIdentity = makeLegacyVaultIdentity(uuid: uuid, keys: keys)
        vaultIdentity.privateKeyApplicationTag = nil

        let message = Data("legacy-signing".utf8)
        let vault = IdentityVault.shared
        let signature = try await vault.signMessageForVaultIdentity(messageData: message, vaultIdentity: vaultIdentity)

        let identity = Identity(uuid, displayName: "Legacy identity", identityVault: nil)
        identity.publicSecureKey = vaultIdentity.publicSecureKey
        let verified = try await vault.verifySignature(signature: signature, messageData: message, for: identity)
        XCTAssertTrue(verified)
    }

    func testLegacyEmbeddedPrivateKeyMigratesToApplicationTagAndSigns() async throws {
        let uuid = UUID().uuidString
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let keys = try createKeyPairForDomainv2(domainString: uuid)
        let legacyIdentity = makeLegacyVaultIdentity(uuid: uuid, keys: keys)
        let vault = IdentityVault.shared

        let (migratedIdentities, needsMigration) = await vault.migrateLoadedVaultIdentities([legacyIdentity])
        XCTAssertTrue(needsMigration)
        guard let migratedIdentity = migratedIdentities.first else {
            XCTFail("Expected migrated identity")
            return
        }

        XCTAssertEqual(migratedIdentity.privateKeyApplicationTag, legacyPrivateKeyApplicationTag(for: uuid))
        XCTAssertTrue(migratedIdentity.privateKey.isEmpty)
        XCTAssertEqual(migratedIdentity.publicSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(migratedIdentity.publicSecureKey?.curveType, .P256)
        XCTAssertEqual(migratedIdentity.privateSecureKey?.algorithm, .ECDSA)
        XCTAssertEqual(migratedIdentity.privateSecureKey?.curveType, .P256)
        XCTAssertNil(migratedIdentity.privateSecureKey?.compressedKey)

        let message = Data("migrated-signing".utf8)
        let signature = try await vault.signMessageForVaultIdentity(messageData: message, vaultIdentity: migratedIdentity)
        let identity = Identity(uuid, displayName: "Migrated identity", identityVault: nil)
        identity.publicSecureKey = migratedIdentity.publicSecureKey
        let verified = try await vault.verifySignature(signature: signature, messageData: message, for: identity)
        XCTAssertTrue(verified)
    }

    func testMigrateLoadedVaultIdentitiesRepairsStoredPublicKeyMismatchAgainstKeychainKey() async throws {
        let uuid = UUID().uuidString
        let mismatchUUID = UUID().uuidString
        defer {
            deletePrivateKeyIfPresent(for: uuid)
            deletePrivateKeyIfPresent(for: mismatchUUID)
        }

        let original = VaultIdentity(uuid: uuid, displayName: "Original identity")
        if original.publicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        let mismatch = VaultIdentity(uuid: mismatchUUID, displayName: "Mismatch identity")
        if mismatch.publicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        var corrupted = original
        corrupted.publicKey = mismatch.publicKey
        corrupted.publicSecureKey = mismatch.publicSecureKey

        let vault = IdentityVault.shared
        let (migratedIdentities, needsMigration) = await vault.migrateLoadedVaultIdentities([corrupted])
        XCTAssertTrue(needsMigration)
        guard let repaired = migratedIdentities.first else {
            XCTFail("Expected repaired identity")
            return
        }

        XCTAssertEqual(repaired.publicKey, original.publicKey)
        XCTAssertEqual(repaired.publicSecureKey?.compressedKey, original.publicSecureKey?.compressedKey)

        let message = Data("repaired-signing".utf8)
        let signature = try await vault.signMessageForVaultIdentity(messageData: message, vaultIdentity: repaired)
        let identity = Identity(uuid, displayName: "Repaired identity", identityVault: nil)
        identity.publicSecureKey = repaired.publicSecureKey
        let verified = try await vault.verifySignature(signature: signature, messageData: message, for: identity)
        XCTAssertTrue(verified)
    }

    func testIdentityLookupForSameDomainKeepsSamePublicKeyAndSigns() async throws {
        let uuid = UUID().uuidString
        let identityContext = "apple-vault-stability-\(uuid)"
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let vault = IdentityVault.shared
        var createdIdentity = Identity(uuid, displayName: "Stable identity", identityVault: vault)
        await vault.addIdentity(identity: &createdIdentity, for: identityContext)

        let initialPublicKey = createdIdentity.publicSecureKey?.compressedKey ?? Data()
        if initialPublicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        guard let firstLookup = await vault.identity(for: identityContext, makeNewIfNotFound: false),
              let secondLookup = await vault.identity(for: identityContext, makeNewIfNotFound: false) else {
            XCTFail("Expected identity lookups for \(identityContext)")
            return
        }

        XCTAssertEqual(firstLookup.uuid, createdIdentity.uuid)
        XCTAssertEqual(secondLookup.uuid, createdIdentity.uuid)
        XCTAssertEqual(firstLookup.publicSecureKey?.compressedKey, initialPublicKey)
        XCTAssertEqual(secondLookup.publicSecureKey?.compressedKey, initialPublicKey)

        let message = Data("stable-domain-signing".utf8)
        let signature = try await vault.signMessageForIdentity(messageData: message, identity: secondLookup)
        let verified = try await vault.verifySignature(signature: signature, messageData: message, for: secondLookup)
        XCTAssertTrue(verified)
    }

    func testVerifySignatureFailsWhenIdentityHasNoPublicSigningKey() async throws {
        let uuid = UUID().uuidString
        defer { deletePrivateKeyIfPresent(for: uuid) }

        let vaultIdentity = VaultIdentity(uuid: uuid, displayName: "Missing public key")
        if vaultIdentity.publicKey.isEmpty {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }

        let message = Data("missing-public-key".utf8)
        let vault = IdentityVault.shared
        let signature = try await vault.signMessageForVaultIdentity(messageData: message, vaultIdentity: vaultIdentity)

        let identity = Identity(uuid, displayName: "Missing public key", identityVault: nil)
        identity.publicSecureKey = nil

        do {
            _ = try await vault.verifySignature(signature: signature, messageData: message, for: identity)
            XCTFail("Expected verification to fail when the public signing key is missing")
        } catch {
            XCTAssertEqual(String(describing: error), "noKey")
        }
    }
}

private func makeLegacyVaultIdentity(
    uuid: String,
    keys: (publicKey: Data, privateKey: Data)
) -> VaultIdentity {
    var vaultIdentity = VaultIdentity()
    vaultIdentity.uuid = uuid
    vaultIdentity.displayName = "Legacy identity"
    vaultIdentity.publicKey = keys.publicKey
    vaultIdentity.privateKey = keys.privateKey
    vaultIdentity.privateKeyApplicationTag = nil
    vaultIdentity.publicSecureKey = SecureKey(
        date: Date(),
        privateKey: false,
        use: .signature,
        algorithm: .EdDSA,
        size: 256,
        curveType: .secp256k1,
        x: nil,
        y: nil,
        compressedKey: keys.publicKey
    )
    vaultIdentity.privateSecureKey = SecureKey(
        date: Date(),
        privateKey: true,
        use: .signature,
        algorithm: .EdDSA,
        size: 256,
        curveType: .secp256k1,
        x: nil,
        y: nil,
        compressedKey: keys.privateKey
    )
    return vaultIdentity
}

private func deletePrivateKeyIfPresent(for uuid: String) {
    deleteKeychainKey(withApplicationTag: managedPrivateKeyApplicationTag(for: uuid))
    deleteKeychainKey(withApplicationTag: legacyPrivateKeyApplicationTag(for: uuid))
}

private func deleteKeychainKey(withApplicationTag tag: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: Data(tag.utf8),
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
    ]
    SecItemDelete(query as CFDictionary)
}
