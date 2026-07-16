// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class TrustedIssuerEvaluationReceiptTests: XCTestCase {
    func testSignedReceiptBindsEvaluationAndVerifier() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let resolvedVerifier = await vault.identity(for: "trusted-verifier", makeNewIfNotFound: true)
        let verifier = try XCTUnwrap(resolvedVerifier)
        let evaluation = try makeEvaluation()
        let receipt = try await TrustedIssuerEvaluationReceipt.issue(
            evaluation: evaluation,
            verifier: verifier,
            evidenceBinding: try makeEvidenceBinding(evaluation: evaluation)
        )

        XCTAssertTrue(receipt.verifySignature())
        XCTAssertTrue(receipt.verifyTrustedEvaluation(
            expectedRequesterID: "did:key:zRequester",
            expectedIssuerID: "did:key:zIssuer",
            expectedContextID: "agreement-proof"
        ))

        let roundTripped = try TrustedIssuerEvaluationReceipt.from(object: receipt.asObject())
        XCTAssertTrue(roundTripped.verifySignature())
        XCTAssertEqual(roundTripped.verifier.signingPublicKeyFingerprint, verifier.signingPublicKeyFingerprint)
    }

    func testSignedReceiptRejectsEvaluationMutation() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let resolvedVerifier = await vault.identity(for: "trusted-verifier-tamper", makeNewIfNotFound: true)
        let verifier = try XCTUnwrap(resolvedVerifier)
        var receipt = try await TrustedIssuerEvaluationReceipt.issue(
            evaluation: makeEvaluation(),
            verifier: verifier,
            evidenceBinding: try makeEvidenceBinding(evaluation: makeEvaluation())
        )
        receipt.evaluation["decision"] = .string("untrusted")

        XCTAssertFalse(receipt.verifySignature())
        XCTAssertFalse(receipt.verifyTrustedEvaluation())
    }

    func testSignedReceiptRejectsUnpinnedVerifierAndConditionReuse() async throws {
        let previousVault = CellBase.defaultIdentityVault
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        defer { CellBase.defaultIdentityVault = previousVault }

        let trustedVerifierValue = await vault.identity(for: "trusted-verifier-authority", makeNewIfNotFound: true)
        let attackerValue = await vault.identity(for: "attacker-verifier", makeNewIfNotFound: true)
        let trustedVerifier = try XCTUnwrap(trustedVerifierValue)
        let attacker = try XCTUnwrap(attackerValue)
        let evaluation = try makeEvaluation()
        let binding = try makeEvidenceBinding(evaluation: evaluation)
        let attackerReceipt = try await TrustedIssuerEvaluationReceipt.issue(
            evaluation: evaluation,
            verifier: attacker,
            evidenceBinding: binding
        )

        XCTAssertFalse(attackerReceipt.verifyTrustedEvaluation(expectedVerifier: trustedVerifier))
        XCTAssertFalse(attackerReceipt.verifyTrustedEvaluation(
            expectedVerifier: attacker,
            expectedConditionHash: String(repeating: "0", count: 64)
        ))
    }

    private func makeEvaluation() throws -> Object {
        var evaluation: Object = [
            "evaluationId": .string("evaluation-1"),
            "issuerId": .string("did:key:zIssuer"),
            "contextId": .string("agreement-proof"),
            "requesterId": .string("did:key:zRequester"),
            "score": .float(0.9),
            "threshold": .float(0.5),
            "decision": .string("trusted"),
            "reasons": .list([.string("trust_threshold_met"), .string("vc_signature_valid")]),
            "components": .object(["baseWeight": .float(0.9)]),
            "createdAt": .string("2026-07-16T10:00:00Z")
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(evaluation)
        evaluation["snapshotHash"] = .string(FlowHasher.sha256Hex(canonical))
        return evaluation
    }

    private func makeEvidenceBinding(evaluation: Object) throws -> Object {
        try TrustedIssuerEvaluationReceipt.evidenceBinding(
            candidateCredential: ["id": .string("credential-1")],
            policySnapshot: [
                "requireSubjectBinding": .bool(true),
                "requireRevocationCheck": .bool(false)
            ],
            agreementCondition: [
                "kind": .string("prove"),
                "title": .string("agreement-proof"),
                "requiredCredentialType": .string("AgreementCredential"),
                "subjectClaimPath": .string("credentialSubject.allowed")
            ],
            evaluation: evaluation
        )
    }
}
