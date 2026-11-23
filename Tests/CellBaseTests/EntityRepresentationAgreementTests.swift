// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class EntityRepresentationAgreementTests: XCTestCase {
    func testEntityRepresentationEncodesAndDecodesAgreementRefs() throws {
        let reference = AgreementReference(
            id: "agreement-1",
            label: "Del grunnprofil - Binding app",
            counterparty: "Binding app",
            purpose: "vise grunnprofil",
            dataPointer: "person.displayName",
            recordState: .signed,
            savedAt: 1_741_449_600,
            savedAtText: "8. mars 2026 16:00",
            recordKeypath: "signedAgreementEntity.records.agreement-1",
            sourceEntityKeypath: "entityRepresentation.agreementRefs"
        )

        let entityRepresentation = EntityRepresentation(
            name: "Binding relation",
            agreementRefs: [reference]
        )

        let data = try JSONEncoder().encode(entityRepresentation)
        let decoded = try JSONDecoder().decode(EntityRepresentation.self, from: data)

        XCTAssertEqual(decoded.agreementRefs.count, 1)
        XCTAssertEqual(decoded.agreementRefs.first?.id, "agreement-1")
        XCTAssertEqual(decoded.agreementRefs.first?.recordState, .signed)
        XCTAssertEqual(decoded.agreementRefs.first?.recordKeypath, "signedAgreementEntity.records.agreement-1")
    }

    /// Built from a record as the EntityAnchor commit flow stores it.
    func testSignedAgreementEntityBuildsCanonicalAgreementRefs() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }
        let ownerCandidate = await vault.identity(for: "owner", makeNewIfNotFound: true)
        let owner = try XCTUnwrap(ownerCandidate)
        let agreement = Agreement(owner: owner)
        agreement.name = "Tilgang etter bevis - Deltaker"
        let contract = try await Contract.ownerSignedSnapshot(
            agreement: agreement,
            signer: owner,
            domain: SignedAgreementEntitySupport.ownerEntityDomain(for: owner)
        )
        let request = SignedAgreementEntityCommitRequest(contract: contract, metadata: [
            "counterparty": .string("Deltaker"),
            "purpose": .string("slippe inn pa arrangementet"),
            "dataPointer": .string("paymentProofDoor.state"),
        ])
        let prepared = try SignedAgreementEntitySupport.prepareRecord(
            request: request,
            contractHash: try SignedAgreementEntitySupport.contractHash(contract),
            existingRecords: [:],
            committedAt: Date(timeIntervalSince1970: 1_741_449_600)
        )
        let record = try SignedAgreementRecord(object: prepared.record)

        let entity = SignedAgreementEntity(records: [record])
        let refs = entity.agreementRefs()

        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.id, contract.uuid)
        XCTAssertEqual(refs.first?.label, "Tilgang etter bevis - Deltaker")
        XCTAssertEqual(refs.first?.counterparty, "Deltaker")
        XCTAssertEqual(refs.first?.purpose, "slippe inn pa arrangementet")
        XCTAssertEqual(refs.first?.dataPointer, "paymentProofDoor.state")
        XCTAssertEqual(refs.first?.recordState, .signed)
        XCTAssertEqual(refs.first?.savedAt, 1_741_449_600)
        XCTAssertEqual(refs.first?.savedAtText, "2025-03-08T16:00:00.000Z")
        XCTAssertEqual(refs.first?.recordKeypath, "signedAgreementEntity.records.\(contract.uuid)")
        XCTAssertEqual(refs.first?.sourceEntityKeypath, "entityRepresentation.agreementRefs")
    }
}
