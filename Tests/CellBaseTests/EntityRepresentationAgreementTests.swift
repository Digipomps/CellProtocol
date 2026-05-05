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

    func testSignedAgreementEntityBuildsCanonicalAgreementRefs() {
        let owner = TestFixtures.makeIdentity(displayName: "owner")
        let agreement = Agreement(owner: owner)
        agreement.name = "Tilgang etter bevis - Deltaker"

        let record = SignedAgreementRecord(
            agreement: agreement,
            counterparty: "Deltaker",
            purpose: "slippe inn pa arrangementet",
            dataPointer: "paymentProofDoor.state",
            summary: "Denne startmallen lar Deltaker lese paymentProofDoor.state.",
            savedAt: 1_741_449_600,
            savedAtText: "8. mars 2026 16:00",
            recordState: .signed
        )

        let entity = SignedAgreementEntity(records: [record])
        let refs = entity.agreementRefs()

        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.id, agreement.uuid)
        XCTAssertEqual(refs.first?.label, "Tilgang etter bevis - Deltaker")
        XCTAssertEqual(refs.first?.recordState, .signed)
        XCTAssertEqual(refs.first?.recordKeypath, "signedAgreementEntity.records.\(agreement.uuid)")
        XCTAssertEqual(refs.first?.sourceEntityKeypath, "entityRepresentation.agreementRefs")
    }
}
