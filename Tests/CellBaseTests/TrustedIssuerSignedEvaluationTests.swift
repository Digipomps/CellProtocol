// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class TrustedIssuerSignedEvaluationTests: XCTestCase {
    func testEvaluateSignedReturnsPortableVerifierReceipt() async throws {
        let previousVault = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previousVault }

        let vault = Curve25519TestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.makeIdentity(displayName: "trusted-owner")
        let issuer = await vault.makeIdentity(displayName: "credential-issuer")
        let cell = await TrustedIssuerCell(owner: owner)
        let contextID = "agreement-proof"
        let issuerID = try issuer.did()

        _ = try await cell.set(
            keypath: "trustedIssuers.policy.upsert",
            value: .object([
                "contextId": .string(contextID),
                "threshold": .float(0.5),
                "maximumCredentialAgeSeconds": .float(86_400),
                "requireRevocationCheck": .bool(false),
                "requireSubjectBinding": .bool(true),
                "requireIndependentSources": .integer(0),
                "acceptedDidMethods": .list([.string("did:key")]),
                "claimSchema": .object([
                    "credentialType": .string("AgreementCredential"),
                    "subjectPath": .string("credentialSubject.allowed"),
                    "operator": .string("=="),
                    "expectedValue": .bool(true)
                ])
            ]),
            requester: owner
        )
        _ = try await cell.set(
            keypath: "trustedIssuers.issuer.upsert",
            value: .object([
                "issuerId": .string(issuerID),
                "issuerKind": .string("institution"),
                "baseWeight": .float(0.9),
                "contexts": .list([.string(contextID)]),
                "status": .string("active")
            ]),
            requester: owner
        )

        var claim = try await VCClaim(
            type: "AgreementCredential",
            issuerIdentity: issuer,
            subjectIdentity: owner,
            credentialSubject: ["allowed": .bool(true)]
        )
        try await claim.generateProof(issuerIdentity: issuer)
        let claimObject = try JSONDecoder().decode(
            Object.self,
            from: JSONEncoder().encode(claim)
        )
        let result = try await cell.set(
            keypath: "trustedIssuers.evaluateSigned",
            value: .object([
                "issuerId": .string(issuerID),
                "contextId": .string(contextID),
                "requesterId": .string(try owner.did()),
                "candidateVc": .object(claimObject),
                "agreementCondition": .object([
                    "kind": .string("prove"),
                    "title": .string(contextID),
                    "technicalRule": .string("credentialSubject.allowed == true"),
                    "permission": .string("r---"),
                    "requiredCredentialType": .string("AgreementCredential"),
                    "subjectClaimPath": .string("credentialSubject.allowed")
                ])
            ]),
            requester: owner
        )

        guard case let .object(receiptObject)? = result else {
            return XCTFail("Expected signed evaluation receipt, got \(String(describing: result))")
        }
        let receipt = try TrustedIssuerEvaluationReceipt.from(object: receiptObject)
        XCTAssertTrue(receipt.verifyTrustedEvaluation(
            expectedRequesterID: try owner.did(),
            expectedIssuerID: issuerID,
            expectedContextID: contextID
        ))

        var tamperedObject = receiptObject
        if case let .object(existingEvaluation)? = tamperedObject["evaluation"] {
            var evaluation = existingEvaluation
            evaluation["decision"] = .string("untrusted")
            tamperedObject["evaluation"] = .object(evaluation)
        }
        let tampered = try TrustedIssuerEvaluationReceipt.from(object: tamperedObject)
        XCTAssertFalse(tampered.verifySignature())
    }
}
