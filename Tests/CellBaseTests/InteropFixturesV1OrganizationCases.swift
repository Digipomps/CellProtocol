// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  InteropFixturesV1OrganizationCases.swift
//  PDD_informasjonssystemer-gruppeentitet, WP10 (test.ge.interop).
//
//  Golden cases for an organization owned by a group: the governance policy,
//  the genesis seal, a proposal and the owners' approvals, the evaluator's
//  decision on approval bundles, a role credential signed by the organization
//  key and its signed status list. Python and Go must reach the same verdicts.
//
//  Verdict codes:
//    seal, approval, status list: `valid` or the Swift error case name
//      (`founderSignatureInvalid`, `unexpectedSigner`, `bad_signature`, …);
//    ApprovalBundle: `met:<ruleID>:<clauseIndex>` or the
//      GovernanceEvaluationError case name (`clauseNotSatisfied`, …);
//    role credential: `valid` or `invalid`.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

extension InteropFixturesV1Tests {
    /// The organization key the vault holds. A public test key like the others.
    static let custodian = party("custodian", uuid: "0D9A0000-0000-4000-8000-00000000C057")

    static let orgAnchorID = "entity:interop-gruppe"
    static let orgValidFrom = "2026-10-01T00:00:00Z"
    static let orgCreatedAt = "2026-10-27T11:59:00Z"
    static let orgExpiresAt = "2026-10-27T12:09:00Z"
    static let orgApprovedAt = "2026-10-27T11:59:30Z"

    /// The Swift error case name, without associated values.
    static func orgCode(_ error: Error) -> String {
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" })
    }

    static func orgVerdict(_ body: () throws -> Void) -> String {
        do { try body(); return "valid" } catch { return orgCode(error) }
    }

    static func orgPolicy(
        _ owners: [Party], agreement: OwnershipAgreement = .rolesOneGovernanceAll,
        version: Int = 1, previous: GovernancePolicy? = nil
    ) throws -> GovernancePolicy {
        try GovernancePolicy.ownerGroup(
            policyID: orgAnchorID, version: version,
            previousPolicyHash: try previous?.policyHash(),
            owners: owners.map(\.descriptor), agreement: agreement, validFrom: orgValidFrom)
    }

    static func orgProposal(
        under policy: GovernancePolicy, actionClass: String, payloadHash: Data,
        summary: String, label: String, proposer: Party = alice
    ) throws -> OrganizationActionProposal {
        OrganizationActionProposal(
            proposalID: "prop-interop-\(label)", organizationAnchorID: orgAnchorID,
            policyHash: try policy.policyHash(), actionClass: actionClass,
            payloadHash: payloadHash, payloadSummary: summary, audience: orgAnchorID,
            createdAt: orgCreatedAt, expiresAt: orgExpiresAt,
            nonce: bytes("org-nonce/\(label)", count: 16), proposer: proposer.descriptor)
    }

    static func orgApproval(_ proposal: OrganizationActionProposal, by party: Party, signedBy signer: Party? = nil) throws -> OrganizationApproval {
        var approval = OrganizationApproval(
            proposalHash: try proposal.proposalHash(), approver: party.descriptor,
            role: .owner, decision: .approve, approvedAt: orgApprovedAt)
        approval.signature = try (signer ?? party).sign(try approval.canonicalPayloadData())
        return approval
    }

    static func bundleVerdict(_ policy: GovernancePolicy, _ bundle: ApprovalBundle) -> String {
        do {
            let evaluation = try GovernancePolicyEvaluator.evaluate(policy: policy, bundle: bundle, now: verifyAt)
            return "met:\(evaluation.ruleID):\(evaluation.clauseIndex)"
        } catch {
            return orgCode(error)
        }
    }

    static func organizationCases() async throws -> [Case] {
        var cases: [Case] = []
        let flow = "org"

        // Policies. v1: Alice alone (the starting point). v2: Alice and Bob.
        let v1 = try orgPolicy([alice])
        let v2 = try orgPolicy([alice, bob], version: 2, previous: v1)
        let v3 = try orgPolicy([alice, bob, mallory], version: 3, previous: v2)
        let allTwo = try orgPolicy([alice, bob], agreement: .allTwo)
        for (id, policy, text) in [
            ("org.policy.v1", v1, "Gruppa eies av Alice alene. Roller: én eier. Styring: alle eiere."),
            ("org.policy.v2", v2, "Bob er lagt til som eier. Peker på hashen til v1."),
            ("org.policy.all-two", allTwo, "Eierskapsavtalen all-two: to eiere for alt."),
        ] {
            cases.append(try record(id, flow: flow, type: "GovernancePolicy", description: text,
                value: policy, excluded: [], canonical: try policy.canonicalPayloadData(),
                signer: nil, signature: nil, verdict: "valid",
                related: ["policyHashBase64": try policy.policyHash().base64EncodedString()]))
        }

        // Genesis seal, signed by the founder.
        var seal = OrganizationGenesisSeal(
            anchorID: orgAnchorID, displayName: "Interop-gruppa (test)",
            initialPolicyHash: try v1.policyHash(), custodianKey: custodian.descriptor,
            founders: [alice.descriptor], sealedAt: "2026-10-27T11:58:00Z")
        let sealPayload = try seal.canonicalPayloadData()
        seal.signatures = [OrganizationFounderSignature(founder: alice.descriptor, signedAt: "2026-10-27T11:58:00Z",
                                                        signature: try alice.sign(sealPayload))]
        cases.append(try record("org.genesis.valid", flow: flow, type: "OrganizationGenesisSeal",
            description: "Gruppa forsegles til policy v1. Alice er grunnlegger og signerer.",
            value: seal, excluded: ["signatures"], canonical: sealPayload,
            signer: alice.descriptor, signature: seal.signatures.first?.signature,
            verdict: orgVerdict { try seal.verify(initialPolicy: v1) },
            related: ["policy": "org.policy.v1", "sealHashBase64": try seal.sealHash().base64EncodedString()]))

        var tamperedSeal = seal
        tamperedSeal.displayName = "Noen andres gruppe"
        cases.append(try record("org.genesis.tampered", flow: flow, type: "OrganizationGenesisSeal",
            description: "Navnet er endret etter at Alice signerte.",
            value: tamperedSeal, excluded: ["signatures"], canonical: try tamperedSeal.canonicalPayloadData(),
            signer: alice.descriptor, signature: tamperedSeal.signatures.first?.signature,
            verdict: orgVerdict { try tamperedSeal.verify(initialPolicy: v1) },
            related: ["policy": "org.policy.v1"]))

        var outsiderSeal = seal
        outsiderSeal.signatures.append(OrganizationFounderSignature(
            founder: mallory.descriptor, signedAt: "2026-10-27T11:58:00Z", signature: try mallory.sign(sealPayload)))
        cases.append(try record("org.genesis.outsider-signer", flow: flow, type: "OrganizationGenesisSeal",
            description: "Mallory, som ikke er grunnlegger, har lagt til en gyldig signatur. Forseglingen skal avvises.",
            value: outsiderSeal, excluded: ["signatures"], canonical: sealPayload,
            signer: mallory.descriptor, signature: outsiderSeal.signatures.last?.signature,
            verdict: orgVerdict { try outsiderSeal.verify(initialPolicy: v1) },
            related: ["policy": "org.policy.v1"]))

        // Role credential the owners approve, and the organization key signs.
        var credential = try OrganizationRoleCredential.unsigned(
            organizationAnchorID: orgAnchorID, credentialType: "InteropGruppeRoleCredential",
            custodian: custodian.descriptor, subject: bob.descriptor, role: "researcher",
            cohort: "MasterHAVEN26", validUntil: "2027-06-30", policyHash: try v1.policyHash(),
            issuedAt: rfc3339("2026-10-27T11:59:45Z"))
        credential.id = "cell:///identity/\(bob.uuid)/claims/0201E000-0000-4000-8000-000000000001"
        credential.proof.created = rfc3339("2026-10-27T11:59:45Z")
        let rolePayloadHash = try OrganizationRoleCredential.payloadHash(of: credential)
        let roleSummary = OrganizationRoleCredential.summary(of: credential, displayName: seal.displayName)
        credential.proof.signatureData = try custodian.sign(try unsignedClaimData(credential))
        let roleVerdict = await asyncVerdict { [credential] in try await credential.verify() }
        cases.append(try record("org.role.valid", flow: flow, type: "VCClaim",
            description: "Gruppa gir Bob rollen researcher i kullet MasterHAVEN26. Signert med organisasjonsnøkkelen; rolle, kull og gyldighet ligger i credentialSubject.",
            value: credential, excluded: ["proof"], canonical: try unsignedClaimData(credential),
            signer: custodian.descriptor, signature: credential.proof.signatureData, verdict: roleVerdict,
            related: [
                "payloadHashBase64": rolePayloadHash.base64EncodedString(),
                "summary": roleSummary,
                "issuerDID": try IdentityLinkProtocolService.did(for: custodian.descriptor),
                "holderDID": try IdentityLinkProtocolService.did(for: bob.descriptor),
            ]))

        var tamperedRole = credential
        tamperedRole.credentialSubject[OrganizationRoleCredential.Field.role] = .string("supervisor")
        let tamperedVerdict = await asyncVerdict { [tamperedRole] in try await tamperedRole.verify() }
        cases.append(try record("org.role.tampered", flow: flow, type: "VCClaim",
            description: "Rollen er endret til supervisor etter signering.",
            value: tamperedRole, excluded: ["proof"], canonical: try unsignedClaimData(tamperedRole),
            signer: custodian.descriptor, signature: tamperedRole.proof.signatureData, verdict: tamperedVerdict))

        // The proposal to give that role, and the approvals.
        let roleProposal = try orgProposal(under: v1, actionClass: OrganizationActionClass.roleIssue,
            payloadHash: rolePayloadHash, summary: roleSummary, label: "role-issue")
        cases.append(try record("org.proposal.role-issue", flow: flow, type: "OrganizationActionProposal",
            description: "Forslag om å gi rollen. payloadHash er hashen av credentialet uten proof; sammendraget er utledet av credentialet.",
            value: roleProposal, excluded: [], canonical: try roleProposal.canonicalPayloadData(),
            signer: nil, signature: nil, verdict: "valid",
            related: ["proposalHashBase64": try roleProposal.proposalHash().base64EncodedString(), "policy": "org.policy.v1"]))

        let aliceApproval = try orgApproval(roleProposal, by: alice)
        cases.append(try record("org.approval.role-issue.alice", flow: flow, type: "OrganizationApproval",
            description: "Alice godkjenner forslaget med sin egen nøkkel.",
            value: aliceApproval, excluded: ["signature"], canonical: try aliceApproval.canonicalPayloadData(),
            signer: alice.descriptor, signature: aliceApproval.signature,
            verdict: aliceApproval.signatureIsValid() ? "valid" : "bad_signature",
            related: ["proposal": "org.proposal.role-issue"]))

        let forgedApproval = try orgApproval(roleProposal, by: alice, signedBy: mallory)
        cases.append(try record("org.approval.role-issue.forged", flow: flow, type: "OrganizationApproval",
            description: "Godkjenningen sier Alice, men er signert av Mallory.",
            value: forgedApproval, excluded: ["signature"], canonical: try forgedApproval.canonicalPayloadData(),
            signer: alice.descriptor, signature: forgedApproval.signature,
            verdict: forgedApproval.signatureIsValid() ? "valid" : "bad_signature",
            related: ["proposal": "org.proposal.role-issue"]))

        // Decisions on approval bundles.
        func bundleCase(_ id: String, _ text: String, _ policy: GovernancePolicy, _ policyCase: String, _ bundle: ApprovalBundle) throws -> Case {
            try record(id, flow: flow, type: "ApprovalBundle", description: text,
                value: bundle, excluded: [], canonical: try CanonicalPayloadEncoder.data(for: bundle),
                signer: nil, signature: nil, verdict: bundleVerdict(policy, bundle),
                related: ["policy": policyCase])
        }

        cases.append(try bundleCase("org.bundle.role-issue.one-owner",
            "Én eier holder for å gi en rolle under starten (roles-one-governance-all).", v1, "org.policy.v1",
            ApprovalBundle(proposal: roleProposal, approvals: [aliceApproval])))
        cases.append(try bundleCase("org.bundle.role-issue.forged",
            "En forfalsket godkjenning avvises før regelen vurderes.", v1, "org.policy.v1",
            ApprovalBundle(proposal: roleProposal, approvals: [forgedApproval])))
        let outsiderProposal = try orgProposal(under: v1, actionClass: OrganizationActionClass.roleIssue,
            payloadHash: rolePayloadHash, summary: roleSummary, label: "role-issue-outsider", proposer: mallory)
        cases.append(try bundleCase("org.bundle.role-issue.outsider",
            "Mallory er ikke eier og kan ikke gi roller.", v1, "org.policy.v1",
            ApprovalBundle(proposal: outsiderProposal, approvals: [try orgApproval(outsiderProposal, by: mallory)])))

        let twoProposal = try orgProposal(under: allTwo, actionClass: OrganizationActionClass.roleIssue,
            payloadHash: rolePayloadHash, summary: roleSummary, label: "role-issue-all-two")
        let aliceTwice = try orgApproval(twoProposal, by: alice)
        cases.append(try bundleCase("org.bundle.all-two.same-owner-twice",
            "Under all-two teller Alice som godkjenner to ganger bare én gang.", allTwo, "org.policy.all-two",
            ApprovalBundle(proposal: twoProposal, approvals: [aliceTwice, aliceTwice])))
        cases.append(try bundleCase("org.bundle.all-two.both",
            "Alice og Bob godkjenner begge; to eiere holder.", allTwo, "org.policy.all-two",
            ApprovalBundle(proposal: twoProposal, approvals: [aliceTwice, try orgApproval(twoProposal, by: bob)])))

        var amendV2 = try GovernancePolicyAmendment.proposal(replacing: v1, with: v2, organizationAnchorID: orgAnchorID,
            proposer: alice.descriptor, createdAt: orgCreatedAt, expiresAt: orgExpiresAt, nonce: bytes("org-nonce/amend-v2", count: 16))
        amendV2.proposalID = "prop-interop-amend-v2"
        cases.append(try bundleCase("org.bundle.amend-v2.alice",
            "Alice, eneste eier i v1, legger til Bob. Styring krever alle eiere, og det er bare henne.", v1, "org.policy.v1",
            ApprovalBundle(proposal: amendV2, approvals: [try orgApproval(amendV2, by: alice)])))
        var amendV3 = try GovernancePolicyAmendment.proposal(replacing: v2, with: v3, organizationAnchorID: orgAnchorID,
            proposer: alice.descriptor, createdAt: orgCreatedAt, expiresAt: orgExpiresAt, nonce: bytes("org-nonce/amend-v3", count: 16))
        amendV3.proposalID = "prop-interop-amend-v3"
        cases.append(try bundleCase("org.bundle.amend-v3.only-alice",
            "Under v2 kreves både Alice og Bob for å endre eierne; Alice alene holder ikke.", v2, "org.policy.v2",
            ApprovalBundle(proposal: amendV3, approvals: [try orgApproval(amendV3, by: alice)])))
        cases.append(try bundleCase("org.bundle.amend-v3.both",
            "Alice og Bob godkjenner begge; endringen holder.", v2, "org.policy.v2",
            ApprovalBundle(proposal: amendV3, approvals: [try orgApproval(amendV3, by: alice), try orgApproval(amendV3, by: bob)])))

        // Signed status lists.
        let issuerDID = try IdentityLinkProtocolService.did(for: custodian.descriptor)
        func statusList(_ sequence: Int, revoked: [String], signer: Party = custodian) throws -> OrganizationRoleStatusList {
            var list = OrganizationRoleStatusList(organizationAnchorID: orgAnchorID, issuerDID: issuerDID, sequence: sequence,
                issuedAt: sequence == 1 ? "2026-10-27T11:58:00Z" : "2026-10-27T11:59:50Z", revokedCredentialIDs: revoked)
            list.signature = try signer.sign(try list.canonicalPayloadData())
            return list
        }
        func statusCase(_ id: String, _ text: String, _ list: OrganizationRoleStatusList) throws -> Case {
            try record(id, flow: flow, type: "OrganizationRoleStatusList", description: text,
                value: list, excluded: ["signature"], canonical: try list.canonicalPayloadData(),
                signer: custodian.descriptor, signature: list.signature,
                verdict: list.signatureIsValid() ? "valid" : "bad_signature",
                related: ["issuerDID": issuerDID])
        }
        cases.append(try statusCase("org.status.v1", "Første statusliste, tom. Signeres når hvelvet opprettes.", try statusList(1, revoked: [])))
        cases.append(try statusCase("org.status.v2", "Bobs rolle er trukket tilbake.", try statusList(2, revoked: [credential.id])))
        var tamperedList = try statusList(2, revoked: [credential.id])
        tamperedList.revokedCredentialIDs = []
        cases.append(try statusCase("org.status.tampered", "Tilbaketrekkingen er fjernet etter signering.", tamperedList))
        cases.append(try statusCase("org.status.wrong-key", "Listen sier organisasjonens did:key, men er signert av Mallory.",
            try statusList(2, revoked: [], signer: mallory)))
        return cases
    }
}
