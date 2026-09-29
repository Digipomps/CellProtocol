// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Crypto
import Foundation
import XCTest
@testable import CellBase

final class CellIdentifierIntegrationTests: XCTestCase {
    private let lower = "a42f007b-931d-4682-a842-aabbccddeeff"
    private let mixed = "a42F007b-931D-4682-a842-AabBCcdDEefF"

    func testResolverRetainsCaseSensitiveIdentityAndCellMappings() async throws {
        let auditor = ResolverAuditor()
        let owner = Identity(lower, displayName: "owner", identityVault: nil)
        let otherOwner = Identity(lower.uppercased(), displayName: "other", identityVault: nil)
        let cell = await GeneralCell(owner: owner)
        cell.uuid = mixed
        let otherCell = await GeneralCell(owner: otherOwner)
        otherCell.uuid = mixed.uppercased()

        try await auditor.registerPersonalReference(cell, endpoint: "Entity", identity: owner)
        try await auditor.registerPersonalReference(otherCell, endpoint: "Entity", identity: otherOwner)
        let found = await auditor.loadIdentityCellInstance(name: "Entity", identity: owner)
        let otherFound = await auditor.loadIdentityCellInstance(name: "Entity", identity: otherOwner)
        XCTAssertTrue(found === cell)
        XCTAssertTrue(otherFound === otherCell)
        let direct = await auditor.loadCellInstance(forUUID: mixed)
        XCTAssertTrue(direct === cell)
        let missing = await auditor.loadCellInstance(forUUID: mixed.lowercased())
        XCTAssertNil(missing)

        let snapshot = await auditor.identityNamedCells()
        XCTAssertEqual(snapshot, [lower: ["Entity": mixed], lower.uppercased(): ["Entity": mixed.uppercased()]])
        let restored = ResolverAuditor()
        await restored.setIdentityNamedCells(snapshot)
        let restoredUUID = await restored.loadIdentityCellUuid(name: "Entity", identity: owner)
        XCTAssertEqual(restoredUUID, mixed)
        await restored.setNamedCells(["Shared": mixed])
        let names = await restored.namedCells()
        XCTAssertEqual(names, ["Shared": mixed])
        let restoredName = await restored.cellname(for: mixed)
        XCTAssertEqual(restoredName, "Shared")
    }

    func testIdentityCellAndRuntimeIDKeepOriginalTextWhenEncoded() async throws {
        let identity = Identity(lower, displayName: "owner", identityVault: nil)
        let decodedIdentity = try JSONDecoder().decode(Identity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(decodedIdentity.uuid, lower)
        XCTAssertEqual(decodedIdentity.identifier.uuid, UUID(uuidString: lower))

        let cell = await GeneralCell(owner: identity)
        cell.uuid = mixed
        let decodedCell = try JSONDecoder().decode(GeneralCell.self, from: JSONEncoder().encode(cell))
        XCTAssertEqual(decodedCell.uuid, mixed)
        XCTAssertEqual(decodedCell.identifier.uuid, UUID(uuidString: mixed))

        let runtimeID = RuntimeCellID(mixed)
        let data = try JSONEncoder().encode(runtimeID)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeCellID.self, from: data), runtimeID)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), mixed)
    }

    func testPerspectiveFindsAndRemovesUUIDReferencesWithoutCaseAliasing() async throws {
        let perspective = Perspective()
        let entity = EntityRepresentation(name: "Example", nodeIdentifier: mixed, projectionSource: "source")
        _ = await perspective.upsertEntityRepresentation(entity)
        let found = await perspective.findENtityRepresentationByReference(mixed)
        XCTAssertTrue(found === entity)
        let missing = await perspective.findENtityRepresentationByReference(mixed.uppercased())
        XCTAssertNil(missing)
        let references = await perspective.projectedEntityReferences(source: "source")
        XCTAssertEqual(references, [mixed])
        let removed = await perspective.removeEntityRepresentation(reference: mixed)
        XCTAssertTrue(removed)
        let after = await perspective.findENtityRepresentationByReference(mixed)
        XCTAssertNil(after)
    }

    func testLegacyEncryptedEnvelopeRetainsKeyAndAuthenticatedText() throws {
        // Construct the pre-refactor wire format using ordinary String fields.
        struct LegacyEnvelope: Codable {
            let version: UInt8
            let ownerIdentityUUID: String
            let combined: Data
        }
        let previous = CellBase.persistedCellMasterKey
        defer { CellBase.persistedCellMasterKey = previous }
        let master = Data(repeating: 0x42, count: 32)
        CellBase.persistedCellMasterKey = master
        let plaintext = Data("persisted UUID compatibility".utf8)
        let seed = master + Data(lower.utf8) + Data([0x2E]) + Data(mixed.utf8)
        let key = SymmetricKey(data: Data(SHA256.hash(data: seed)))
        let aad = Data("cell-persistence-v1".utf8) + Data([0]) + Data(lower.utf8) + Data([0]) + Data(mixed.utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: key,
            nonce: ChaChaPoly.Nonce(data: Data(repeating: 0x11, count: 12)), authenticating: aad)
        let legacy = Data("CELLENC1".utf8) + (try JSONEncoder().encode(
            LegacyEnvelope(version: 1, ownerIdentityUUID: lower, combined: sealed.combined)))
        XCTAssertEqual(try CellPersistenceCrypto.decodeFromStorage(stored: legacy, uuid: mixed), plaintext)
        XCTAssertThrowsError(try CellPersistenceCrypto.decodeFromStorage(stored: legacy, uuid: mixed.uppercased()))

        let stored = try CellPersistenceCrypto.encodeForStorage(plaintext: plaintext, uuid: mixed,
            options: CellStorageWriteOptions(ownerIdentityUUID: lower, encryptedAtRestRequired: true))
        let envelope = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(stored.dropFirst(8)))
        XCTAssertEqual(envelope.ownerIdentityUUID, lower)
        let box = try ChaChaPoly.SealedBox(combined: envelope.combined)
        XCTAssertEqual(try ChaChaPoly.open(box, using: key, authenticating: aad), plaintext)
    }

    func testLegacyContractSignatureWithMixedCaseUUIDsStillVerifies() async throws {
        // A signature over the historical String payload must verify after decoding
        // into the new representation. This also protects optional field omission.
        struct LegacySigningPayload: Encodable {
            let uuid: String
            let agreement: Agreement
            let issuerUUID: String
            let issuerSigningKeyFingerprint: String?
            let subjectUUID: String
            let subjectSigningKeyFingerprint: String?
            let domain: String
            let issuedAt: TimeInterval
            let expiresAt: TimeInterval
        }
        let vault = EphemeralIdentityVault()
        var identity = Identity(lower, displayName: "signer", identityVault: vault)
        await vault.addIdentity(identity: &identity, for: "uuid-test")
        let agreement = Agreement(owner: identity)
        agreement.uuid = mixed
        let issuedAt: TimeInterval = 1_700_000_000
        let expiresAt = issuedAt + TimeInterval(agreement.duration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = LegacySigningPayload(uuid: mixed, agreement: agreement, issuerUUID: lower,
            issuerSigningKeyFingerprint: identity.signingPublicKeyFingerprint, subjectUUID: lower,
            subjectSigningKeyFingerprint: identity.signingPublicKeyFingerprint, domain: "uuid-test",
            issuedAt: issuedAt, expiresAt: expiresAt)
        let signature = try await identity.sign(data: encoder.encode(legacy))
        let contract = Contract(uuid: mixed, agreement: agreement, issuer: identity, subject: identity,
            domain: "uuid-test", issuedAt: issuedAt, expiresAt: expiresAt, signature: signature)
        let encoded = try encoder.encode(contract)
        let decoded = try JSONDecoder().decode(Contract.self, from: encoded)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
        let verified = await decoded.verifyCryptographicSignature()
        XCTAssertTrue(verified)
        var altered = decoded
        altered.uuid = mixed.uppercased()
        let alteredVerified = await altered.verifyCryptographicSignature()
        XCTAssertFalse(alteredVerified)
    }
}
