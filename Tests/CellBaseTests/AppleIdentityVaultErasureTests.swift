// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import Security
@testable import CellApple
@testable import CellBase

/// AP4 (PDD_kontosletting_2026-11-20): destroy and lock in the CellApple vault.
final class AppleIdentityVaultErasureTests: XCTestCase {
    private func makeIdentity(_ label: String) async throws -> (IdentityVault, Identity) {
        let vault = IdentityVault.shared
        let context = "apple-vault-erasure-\(label)-\(UUID().uuidString)"
        guard let identity = await vault.identity(for: context, makeNewIfNotFound: true) else {
            throw XCTSkip("Vault could not create an identity in this test host")
        }
        if identity.signingPublicKeyFingerprint == nil {
            throw XCTSkip("Keychain-backed key generation is unavailable in this test environment")
        }
        return (vault, identity)
    }

    /// Reads Identities.crypt again, as a restart with the same store does.
    private func storedIdentity(_ vault: IdentityVault, uuid: String) async throws -> VaultIdentity? {
        let (loaded, _) = try await vault.loadIdentities()
        return loaded?.first { $0.uuid == uuid }
    }

    private func signs(_ vault: IdentityVault, _ identity: Identity) async -> Result<Data, Error> {
        do { return .success(try await vault.signMessageForIdentity(messageData: Data("erasure".utf8), identity: identity)) }
        catch { return .failure(error) }
    }

    func testDestroyRemovesKeysAndStoredIdentity() async throws {
        let (vault, identity) = try await makeIdentity("destroy")
        guard case .success = await signs(vault, identity) else { return XCTFail("fresh identity must sign") }
        let stored = try await storedIdentity(vault, uuid: identity.uuid)
        let tag = try XCTUnwrap(stored?.privateKeyApplicationTag)

        try await vault.destroyIdentity(identity)

        guard case .failure = await signs(vault, identity) else { return XCTFail("destroyed identity still signs") }
        let afterRestart = try await storedIdentity(vault, uuid: identity.uuid)
        XCTAssertNil(afterRestart, "identity must be gone from Identities.crypt")
        let lookedUp = await vault.identity(forUUID: identity.uuid)
        XCTAssertNil(lookedUp)
        XCTAssertFalse(keyExists(applicationTag: tag), "signing key must be removed from the keychain")
    }

    func testDestroyRefusesAPresentedKeyThatIsNotTheStoredOne() async throws {
        let (vault, identity) = try await makeIdentity("forged")
        defer { Task { try? await vault.destroyIdentity(identity) } }
        let forged = Identity(identity.uuid, displayName: "forged", identityVault: vault)
        forged.publicSecureKey = SecureKey(date: Date(), privateKey: false, use: .signature, algorithm: .ECDSA,
                                           size: 256, curveType: .P256, x: nil, y: nil, compressedKey: Data(repeating: 7, count: 33))
        do { try await vault.destroyIdentity(forged); XCTFail("forged key destroyed the identity") } catch {}
        let stillThere = try await storedIdentity(vault, uuid: identity.uuid)
        XCTAssertNotNil(stillThere)
    }

    func testLockRefusesSigningUntilDeadlineSurvivesRestartAndCanBeUndone() async throws {
        let (vault, identity) = try await makeIdentity("lock")
        defer { Task { try? await vault.destroyIdentity(identity) } }
        let until = Date().addingTimeInterval(30 * 86_400)

        try await vault.lockIdentity(identity, until: until)

        guard case .failure(let error) = await signs(vault, identity) else { return XCTFail("locked identity signs") }
        if case .locked(let lockedUntil)? = error as? IdentityVaultLifecycleError {
            XCTAssertEqual(lockedUntil.timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.001)
        } else {
            XCTFail("expected locked error, got \(error)")
        }
        let afterRestart = try await storedIdentity(vault, uuid: identity.uuid)
        XCTAssertEqual(try XCTUnwrap(afterRestart?.signingLockedUntil).timeIntervalSince1970,
                       until.timeIntervalSince1970, accuracy: 0.001)

        try await vault.unlockIdentity(identity)

        guard case .success = await signs(vault, identity) else { return XCTFail("unlocked identity must sign") }
        let unlockedStored = try await storedIdentity(vault, uuid: identity.uuid)
        XCTAssertNil(unlockedStored?.signingLockedUntil)
    }

    func testExpiredLockNoLongerBlocks() async throws {
        let (vault, identity) = try await makeIdentity("expired")
        defer { Task { try? await vault.destroyIdentity(identity) } }
        try await vault.lockIdentity(identity, until: Date().addingTimeInterval(-1))
        guard case .success = await signs(vault, identity) else { return XCTFail("expired lock still blocks") }
    }

    private func keyExists(applicationTag: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}
