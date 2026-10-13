// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import XCTest
@testable import CellBase

final class EphemeralIdentityVaultConcurrencyTests: XCTestCase {
    func testConcurrentLookupsDoNotMutatePublishedIdentityAndPreserveKeyChecks() async throws {
        let vault = EphemeralIdentityVault()
        let created = await vault.identity(for: "local-peer", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(created), reference = try XCTUnwrap(owner.homeVaultReference)
        let fingerprint = owner.signingPublicKeyFingerprint
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for _ in 0..<500 {
                        let found = worker.isMultiple(of: 2)
                            ? await vault.identity(forUUID: owner.uuid)
                            : await vault.identity(for: "local-peer", makeNewIfNotFound: false)
                        XCTAssertTrue(found === owner)
                        XCTAssertEqual(found?.homeVaultReference, reference)
                    }
                }
            }
            group.addTask {
                // Mirrors the resolver's reads of an already published owner.
                // Under TSAN the original getter's redundant writes race here.
                for _ in 0..<20_000 {
                    XCTAssertTrue((owner.identityVault as? EphemeralIdentityVault) === vault)
                    XCTAssertEqual(owner.homeVaultReference, reference)
                    XCTAssertEqual(owner.signingPublicKeyFingerprint, fingerprint)
                }
            }
            try await group.waitForAll()
        }
        let message = Data("synthetic-local-proof".utf8)
        let signature = try await vault.signMessageForIdentity(messageData: message, identity: owner)
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: message, identity: owner))
        let foreign = await EphemeralIdentityVault().identity(for: "foreign", makeNewIfNotFound: true)!
        let forgery = Identity(owner.uuid, displayName: "same UUID, other key", identityVault: nil)
        forgery.publicSecureKey = foreign.publicSecureKey
        let exists = await vault.identityExistInVault(forgery)
        XCTAssertFalse(exists)
        do { _ = try await vault.signMessageForIdentity(messageData: message, identity: forgery); XCTFail("UUID alone gained signing authority") } catch {}
    }

    func testSaveAndAddBindBeforePublicationAndKeepLocalSigning() async throws {
        let vault = EphemeralIdentityVault()
        for save in [false, true] {
            var owner = Identity(UUID().uuidString, displayName: save ? "saved" : "added", identityVault: nil)
            if save { await vault.saveIdentity(owner) }
            else { await vault.addIdentity(identity: &owner, for: owner.displayName) }
            let byContext = await vault.identity(for: owner.displayName, makeNewIfNotFound: false)
            let byUUID = await vault.identity(forUUID: owner.uuid)
            XCTAssertTrue(byContext === owner); XCTAssertTrue(byUUID === owner)
            XCTAssertTrue((owner.identityVault as? EphemeralIdentityVault) === vault)
            let reference = await vault.identityVaultReference()
            XCTAssertEqual(owner.homeVaultReference, reference)
            let signature = try await vault.signMessageForIdentity(messageData: Data([1]), identity: owner)
            XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: Data([1]), identity: owner))
        }
    }
}
