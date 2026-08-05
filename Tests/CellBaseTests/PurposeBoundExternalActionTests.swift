// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class PurposeBoundExternalActionTests: XCTestCase {
    func testExactOwnerAuthorizedEffectIsEligibleButNotYetExecuted() throws {
        let fixture = try makeFixture()

        let first = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: true),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )
        let second = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: true),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )

        XCTAssertEqual(first, second, "Evaluation must be deterministic for identical inputs")
        XCTAssertTrue(first.allowed)
        XCTAssertEqual(first.context.authorizationStatus, .eligible)
        XCTAssertEqual(first.context.authority.authorityPath, .ownerPath)
        XCTAssertEqual(first.receipt.decisionStatus, .allowed)
        XCTAssertEqual(first.receipt.executionStatus, .notExecuted)
        XCTAssertFalse(first.receipt.containsSecrets)
        XCTAssertEqual(first.receipt.recordingExecution(.completed).executionStatus, .completed)
    }

    func testCurrentTrustPackageCannotReplaceMissingAuthority() throws {
        let fixture = try makeFixture()
        let result = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: false),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.context.authority.authorityPath, .none)
        XCTAssertTrue(result.context.denialReasons?.contains("underlying_cell_authorization_denied") == true)
        XCTAssertTrue(result.context.denialReasons?.contains("authority_evidence_missing") == true)
        XCTAssertTrue(result.receipt.checks.trustPackageDidNotAuthorize)
    }

    func testOwnerPathCannotBypassDestinationOrBindingCeiling() throws {
        var fixture = try makeFixture()
        fixture.intent.effect.destination.destinationRef = "destination://example/not-approved"
        fixture.intent.bindings.payloadDigest = digest("0")

        let result = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: true),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )

        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.context.authority.authorityPath, .ownerPath)
        XCTAssertFalse(result.context.checks.destinationAllowed)
        XCTAssertFalse(result.context.checks.bindingDigestsMatch)
        XCTAssertTrue(result.receipt.checks.ownerPathDidNotBypassCeiling)
    }

    func testSignedContractRequiresExactRefsAndPolicyBinding() throws {
        let fixture = try makeFixture()
        var validDecision = ownerDecision(allowed: true)
        validDecision.path = .signedContract
        validDecision.agreementRef = "agreement://example/a1"
        validDecision.contractRef = "contract://example/c1"
        validDecision.grantRef = "grant://example/g1"
        validDecision.authorizationPolicyBinding = fixture.policyBinding

        let valid = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: validDecision,
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )
        XCTAssertTrue(valid.allowed)
        XCTAssertEqual(valid.context.authority.authorityPath, .contractGrant)

        validDecision.grantRef = nil
        let missingGrant = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: validDecision,
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )
        XCTAssertFalse(missingGrant.allowed)
        XCTAssertTrue(missingGrant.context.denialReasons?.contains("agreement_policy_binding_mismatch") == true)
    }

    func testUnknownPurposeAndFacetOnlyMatchAreFailClosed() throws {
        var fixture = try makeFixture()
        fixture.intent.primaryPurposeRef = "purpose://prompt.unknown"
        fixture.intent.primaryPurposeSelection = .unknown
        fixture.intent.status = .blocked
        fixture.intent.effect.executionMode = .notRequested
        fixture.evidence.facetMatchOnly = true

        let result = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: true),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.context.checks.unknownPurpose)
        XCTAssertTrue(result.context.checks.facetMatchOnly)
        XCTAssertTrue(result.context.denialReasons?.contains("unknown_primary_purpose") == true)
        XCTAssertTrue(result.context.denialReasons?.contains("facet_match_is_non_authorizing") == true)
    }

    func testDigestFramingIsDomainSeparatedAndUnambiguous() {
        let first = PurposeBindingDigest.sha256(domain: "purpose", strings: ["ab", "c"])
        let second = PurposeBindingDigest.sha256(domain: "purpose", strings: ["a", "bc"])
        let third = PurposeBindingDigest.sha256(domain: "payload", strings: ["ab", "c"])

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
        XCTAssertTrue(first.hasPrefix("sha256:"))
        XCTAssertEqual(first.count, 71)
    }

    func testNonASCIIContractTokensAreRejectedByRuntimeShapeValidation() throws {
        var fixture = try makeFixture()
        fixture.intent.bindings.payloadDigest = "sha256:" + String(repeating: "١", count: 64)
        fixture.intent.primaryPurposeRef = "purpose://Project/uppercase"

        let result = PurposeBoundActionAuthorizer.evaluate(
            intent: fixture.intent,
            policy: fixture.policy,
            agreementPolicyBinding: fixture.policyBinding,
            observedBindings: fixture.bindings,
            authorizationDecision: ownerDecision(allowed: true),
            evidence: fixture.evidence,
            identifiers: fixture.identifiers
        )

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(
            result.context.denialReasons?.contains("invalid_or_unsupported_contract_shape") == true
        )
    }

    private typealias Fixture = (
        intent: PurposeBoundActionIntent,
        policy: CellExecutionPolicy,
        policyBinding: AuthorizationPolicyBinding,
        bindings: PurposeActionBindings,
        evidence: PurposeBoundAuthorizationEvidence,
        identifiers: PurposeBoundAuthorizationIdentifiers
    )

    private func makeFixture() throws -> Fixture {
        let bindings = PurposeActionBindings(
            purposeDigest: digest("1"),
            actionDigest: digest("2"),
            destinationDigest: digest("3"),
            dataManifestDigest: digest("4"),
            planDigest: digest("5"),
            configDigest: digest("6"),
            policyDigest: digest("7"),
            taxonomyDigest: digest("8"),
            payloadDigest: digest("9")
        )
        let intent = PurposeBoundActionIntent(
            intentID: "example/share-selected-update-001",
            status: .proposed,
            primaryPurposeRef: "purpose://project-work.share-selected-intent",
            primaryPurposeSelection: .ownerConfirmed,
            primaryPurposeEvidenceRefs: ["evidence://example/owner-confirmation-001"],
            facetRefs: ["purpose://access.audit.privacy"],
            effect: .init(
                effectID: "effect-example-share-selected-update-001",
                effectKind: .externalDisclosure,
                actionRef: "action://example/send-selected-project-update",
                executionMode: .execute,
                destination: .init(
                    destinationRef: "destination://example/admitted-project-room",
                    destinationClass: .admittedRecipient
                ),
                data: .init(
                    dataClassRefs: ["data-class://example/internal-non-sensitive"],
                    fieldManifestDigest: bindings.dataManifestDigest
                )
            ),
            bindings: bindings,
            createdAt: "2026-08-03T12:00:00Z"
        )
        let policy = CellExecutionPolicy(
            policyID: "policy-example-selected-update-v1",
            bindings: .init(
                configDigest: bindings.configDigest,
                policyDigest: bindings.policyDigest,
                taxonomyDigest: bindings.taxonomyDigest
            ),
            policyProvenance: .init(
                policyVersion: "1.0.0-normative-draft",
                issuerRef: "identity://example/policy-maintainer",
                publicationRef: "policy-publication://example/selected-update-v1",
                signatureRef: "signature://example/policy-selected-update-v1",
                issuedAt: "2026-08-03T12:00:00Z"
            ),
            effectCeilings: [
                .init(
                    ceilingID: "ceiling-example-share-selected-update-001",
                    effectKind: .externalDisclosure,
                    actionRef: intent.effect.actionRef,
                    primaryPurposeRef: intent.primaryPurposeRef,
                    permittedFacetRefs: intent.facetRefs,
                    allowedDestinationRefs: [intent.effect.destination.destinationRef],
                    allowedDataClassRefs: intent.effect.data.dataClassRefs,
                    planDigest: bindings.planDigest,
                    requiredPermissions: .init(execute: true, storage: false, disclosure: true)
                )
            ]
        )
        let policyBinding = try AuthorizationPolicyBinding(
            policyID: policy.policyID,
            policyVersion: policy.policyProvenance.policyVersion,
            policyDigest: bindings.policyDigest,
            configDigest: bindings.configDigest,
            taxonomyDigest: bindings.taxonomyDigest,
            actionFamily: PurposeEffectKind.externalDisclosure.rawValue
        )
        let evidence = PurposeBoundAuthorizationEvidence(
            identityRef: "identity://example/owner-001",
            proofRef: "proof://example/owner-current",
            trustPackageEvidence: .init(
                evidenceRef: "trust-package://example/provider-audit-001",
                status: .current
            ),
            storagePermissionSatisfied: true,
            disclosureCapabilitySatisfied: true
        )
        return (
            intent,
            policy,
            policyBinding,
            bindings,
            evidence,
            .init(
                contextID: "example/share-selected-update-001",
                receiptID: "example/share-selected-update-001",
                createdAt: "2026-08-03T12:00:00Z"
            )
        )
    }

    private func ownerDecision(allowed: Bool) -> CellAuthorizationDecision {
        let requester = Identity()
        return CellAuthorizationDecision(
            allowed: allowed,
            path: allowed ? .ownerProof : .deniedNoGrant,
            reason: allowed ? "owner" : "denied",
            request: CellAuthorizationRequest(
                cellUUID: "cell-example",
                identityDomain: "example.local",
                keypath: "share",
                requestedAccess: "-w--",
                requester: requester
            )
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }
}
