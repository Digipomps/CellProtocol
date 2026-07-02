// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class TrustPacketCellTests: XCTestCase {
    func testContractsAdvertiseSignedTrustPacketSurfaceAndDenyOutsider() async throws {
        let subject = await makeSubject()

        try await CellContractHarness.assertAdvertisedKey(
            on: subject.cell,
            key: "trustPacket.state",
            requester: subject.owner,
            expectedMethod: .get,
            expectedInputType: "null",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: subject.cell,
            key: "trustPacket.sendBasicTrustPacket",
            requester: subject.owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: subject.cell,
            key: "trustPacket.verifyReceiptSignature",
            requester: subject.owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "oneOf"
        )
        try await CellContractHarness.assertAdvertisedKey(
            on: subject.cell,
            key: "trustPacket.extractPurposeCandidates",
            requester: subject.owner,
            expectedMethod: .set,
            expectedInputType: "object",
            expectedReturnType: "object"
        )
        try await CellContractHarness.assertPermissions(
            on: subject.cell,
            key: "trustPacket.sendBasicTrustPacket",
            requester: subject.owner,
            expected: ["-w--"]
        )
        try await CellContractHarness.assertSetDenied(
            on: subject.cell,
            key: "trustPacket.sendBasicTrustPacket",
            input: .object(["explicitConsent": .bool(true)]),
            requester: subject.outsider
        )
    }

    func testSendProducesVerifiableOriginSignatureAndTrustMetrics() async throws {
        let subject = await makeSubject()
        try await seedCompleteDraft(on: subject.cell, requester: subject.owner)

        let send = try await subject.cell.set(
            keypath: "trustPacket.sendBasicTrustPacket",
            value: .object(["explicitConsent": .bool(true), "createdAt": .string("2026-07-01T10:00:00Z")]),
            requester: subject.owner
        )
        let receipt = try resultObject(send)
        XCTAssertEqual(string(receipt["status"]), "sent")
        XCTAssertEqual(bool(receipt["explicitConsent"]), true)

        let signature = try object(receipt["originSignature"])
        XCTAssertEqual(string(signature["signerIdentityId"]), subject.owner.uuid)
        XCTAssertEqual(string(signature["verificationStatus"]), "verified")
        XCTAssertNotNil(string(signature["payloadHash"]))
        XCTAssertFalse(string(signature["signature"])?.isEmpty ?? true)

        let verify = try await subject.cell.set(
            keypath: "trustPacket.verifyReceiptSignature",
            value: .object(["receiptId": .string("trust-packet-receipt-1")]),
            requester: subject.owner
        )
        let verification = try resultObject(verify)
        XCTAssertEqual(string(verification["status"]), "verified")
        XCTAssertEqual(bool(verification["hashMatches"]), true)
        XCTAssertEqual(bool(verification["signatureValid"]), true)

        let metricsValue = try await subject.cell.get(keypath: "trustPacket.state.metrics", requester: subject.owner)
        let metrics = try object(metricsValue)
        XCTAssertEqual(double(metrics["receiptCompletenessRate"]), 1.0)
        XCTAssertEqual(double(metrics["purposeGroundingRate"]), 1.0)
        XCTAssertEqual(double(metrics["signatureVerificationRate"]), 1.0)
        XCTAssertEqual(double(metrics["trustSupportingInteractionRate"]), 1.0)
    }

    func testPurposeExtractionIsSideEffectFreeUntilExplicitConfirmation() async throws {
        let subject = await makeSubject()
        try await seedCompleteDraft(on: subject.cell, requester: subject.owner)

        let extracted = try await subject.cell.set(
            keypath: "trustPacket.extractPurposeCandidates",
            value: .object([
                "message": .string("Lag en mutual intro pa eventet om ansvarlig AI."),
                "createdAt": .string("2026-07-01T10:02:00Z")
            ]),
            requester: subject.owner
        )
        let extraction = try object(extracted)
        XCTAssertEqual(bool(extraction["mutatesPerspective"]), false)
        XCTAssertEqual(bool(extraction["blockedByNegativeIntent"]), false)
        let candidates = try list(extraction["candidates"])
        XCTAssertFalse(candidates.isEmpty)

        let stateAfterExtraction = try object(try await subject.cell.get(keypath: "trustPacket.state", requester: subject.owner))
        XCTAssertEqual(try list(stateAfterExtraction["confirmedPurposeCandidates"]).count, 0)

        let firstCandidate = try object(candidates[0])
        let confirmed = try await subject.cell.set(
            keypath: "trustPacket.confirmPurposeCandidate",
            value: .object([
                "approved": .bool(true),
                "id": firstCandidate["id"] ?? .string("trust-purpose-contextual-intro"),
                "label": firstCandidate["label"] ?? .string("Kontekstuell intro"),
                "purposeRef": firstCandidate["purposeRef"] ?? .string("purpose://trust.contextual-intro"),
                "purposeDescription": firstCandidate["purposeDescription"] ?? .string("Confirmed purpose."),
                "interestRefs": firstCandidate["interestRefs"] ?? .list([]),
                "goalRefs": firstCandidate["goalRefs"] ?? .list([]),
                "supportingText": firstCandidate["supportingText"] ?? .string("Explicit user approval."),
                "confirmedAt": .string("2026-07-01T10:03:00Z")
            ]),
            requester: subject.owner
        )
        let confirmation = try resultObject(confirmed)
        XCTAssertEqual(string(confirmation["perspectiveMutation"]), "caller_must_explicitly_call_perspective.addPurpose")

        let stateAfterConfirmation = try object(try await subject.cell.get(keypath: "trustPacket.state", requester: subject.owner))
        XCTAssertEqual(try list(stateAfterConfirmation["confirmedPurposeCandidates"]).count, 1)

        let evaluated = try await subject.cell.set(
            keypath: "trustPacket.evaluateAgainstPerspective",
            value: .object([
                "purposeRef": .string("purpose://trust.contextual-intro"),
                "interestRefs": .list([.string("interest://relationship-context")]),
                "activePurposeRefs": .list([.string("purpose://trust.contextual-intro")]),
                "activeInterestRefs": .list([.string("interest://relationship-context")])
            ]),
            requester: subject.owner
        )
        let evaluation = try object(evaluated)
        XCTAssertEqual(bool(evaluation["accessGranted"]), false)
        XCTAssertEqual(bool(evaluation["mutatesPerspective"]), false)
        XCTAssertEqual(int(evaluation["count"]), 2)
    }

    func testNegativeIntentAndMissingConsentBlockMutationAndSharing() async throws {
        let subject = await makeSubject()
        try await seedCompleteDraft(on: subject.cell, requester: subject.owner)

        let extracted = try await subject.cell.set(
            keypath: "trustPacket.extractPurposeCandidates",
            value: .object(["message": .string("Kun engangsdeling, ikke lagre formal.")]),
            requester: subject.owner
        )
        let extraction = try object(extracted)
        XCTAssertEqual(bool(extraction["mutatesPerspective"]), false)
        XCTAssertEqual(bool(extraction["blockedByNegativeIntent"]), true)
        XCTAssertEqual(try list(extraction["candidates"]).count, 0)

        try await CellContractHarness.assertSetReportsError(
            on: subject.cell,
            key: "trustPacket.shareWithProjectRoom",
            input: .object(["projectRoom": .string("room-1"), "explicitConsent": .bool(false)]),
            requester: subject.owner,
            expectedOperation: "trustPacket.shareWithProjectRoom",
            expectedCode: "explicit_consent_required"
        )

        let metrics = try object(try await subject.cell.get(keypath: "trustPacket.state.metrics", requester: subject.owner))
        XCTAssertEqual(int(metrics["privacyOverreachBlocks"]), 1)
    }

    func testExportAndRevokeKeepSignatureProvenanceAndDoNotClaimResolverEnforcement() async throws {
        let subject = await makeSubject()
        try await seedCompleteDraft(on: subject.cell, requester: subject.owner)
        _ = try await subject.cell.set(
            keypath: "trustPacket.sendBasicTrustPacket",
            value: .object(["explicitConsent": .bool(true), "createdAt": .string("2026-07-01T10:04:00Z")]),
            requester: subject.owner
        )

        let exported = try await subject.cell.set(
            keypath: "trustPacket.exportOwnReceipt",
            value: .object(["receiptId": .string("trust-packet-receipt-1"), "createdAt": .string("2026-07-01T10:05:00Z")]),
            requester: subject.owner
        )
        let manifest = try resultObject(exported)
        XCTAssertEqual(string(manifest["recordType"]), "trust_packet_audit_export_manifest")
        XCTAssertEqual(string(manifest["signatureStatus"]), "verified")
        XCTAssertFalse(string(manifest["checksum"])?.isEmpty ?? true)

        let revoked = try await subject.cell.set(
            keypath: "trustPacket.revokeGrant",
            value: .object([
                "receiptId": .string("trust-packet-receipt-1"),
                "reason": .string("No longer needed"),
                "createdAt": .string("2026-07-01T10:06:00Z")
            ]),
            requester: subject.owner
        )
        let receipt = try resultObject(revoked)
        XCTAssertEqual(string(receipt["status"]), "revoked")
        XCTAssertEqual(string(receipt["resolverEnforcement"]), "external_contract_owner_must_revoke_corresponding_capability")
        let signature = try object(receipt["originSignature"])
        XCTAssertEqual(string(signature["verificationStatus"]), "verified")

        let verify = try await subject.cell.set(
            keypath: "trustPacket.verifyReceiptSignature",
            value: .object(["receiptId": .string("trust-packet-receipt-1")]),
            requester: subject.owner
        )
        let verification = try resultObject(verify)
        XCTAssertEqual(string(verification["status"]), "verified")
    }

    private func makeSubject() async -> (vault: MockIdentityVault, owner: Identity, outsider: Identity, cell: TrustPacketCell) {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "trust-owner", makeNewIfNotFound: true)!
        let outsider = await vault.identity(for: "trust-outsider", makeNewIfNotFound: true)!
        let cell = await TrustPacketCell(owner: owner)
        CellBase.defaultIdentityVault = previousVault
        return (vault, owner, outsider, cell)
    }

    private func seedCompleteDraft(on cell: TrustPacketCell, requester: Identity) async throws {
        _ = try await cell.set(
            keypath: "trustPacket.draft.setMessage",
            value: .object([
                "title": .string("Conference intro trust packet"),
                "message": .string("Intro request with visible AI use and receipt.")
            ]),
            requester: requester
        )
        _ = try await cell.set(
            keypath: "trustPacket.draft.setBoundaries",
            value: .object([
                "purposeRef": .string("purpose://trust.contextual-intro"),
                "interestRefs": .list([.string("interest://relationship-context"), .string("interest://ai-transparency")]),
                "audience": .string("event match recipient"),
                "recipient": .string("recipient-1"),
                "duration": .string("single event"),
                "dataCategories": .list([.string("profile summary"), .string("shared interests")]),
                "aiUseSummary": .string("AI suggests wording. User approves before sending."),
                "boundaries": .list([
                    .object([
                        "label": .string("Event-only intro"),
                        "purposeRef": .string("purpose://trust.contextual-intro"),
                        "audience": .string("event match recipient"),
                        "duration": .string("single event"),
                        "dataCategories": .list([.string("profile summary"), .string("shared interests")]),
                        "canRevoke": .bool(true),
                        "canExport": .bool(true)
                    ])
                ]),
                "evidenceRefs": .list([
                    .object([
                        "id": .string("evidence-ai-policy"),
                        "type": .string("policy"),
                        "issuer": .string("HAVEN local runtime"),
                        "claim": .string("AI output is preview-only until user approval."),
                        "policyRef": .string("policy://trust.ai-preview"),
                        "status": .string("declared")
                    ])
                ])
            ]),
            requester: requester
        )
    }

    private func resultObject(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws -> Object {
        let response = try object(value, file: file, line: line)
        guard let result = response["result"] else {
            XCTFail("Expected result object", file: file, line: line)
            return [:]
        }
        return try object(result, file: file, line: line)
    }

    private func object(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws -> Object {
        guard let object = ExploreContract.object(from: value) else {
            XCTFail("Expected object value", file: file, line: line)
            return [:]
        }
        return object
    }

    private func list(_ value: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws -> ValueTypeList {
        guard let list = ExploreContract.list(from: value) else {
            XCTFail("Expected list value", file: file, line: line)
            return []
        }
        return list
    }

    private func string(_ value: ValueType?) -> String? {
        ExploreContract.string(from: value)
    }

    private func bool(_ value: ValueType?) -> Bool? {
        guard case let .bool(value)? = value else {
            return nil
        }
        return value
    }

    private func int(_ value: ValueType?) -> Int? {
        ExploreContract.int(from: value)
    }

    private func double(_ value: ValueType?) -> Double? {
        switch value {
        case let .float(value)?: return value
        case let .number(value)?: return Double(value)
        case let .integer(value)?: return Double(value)
        default: return nil
        }
    }
}
