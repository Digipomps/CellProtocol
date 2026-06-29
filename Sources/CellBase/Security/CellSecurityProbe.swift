// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellSecurityProbeKind: String, Codable, CaseIterable, Sendable {
    case forgedUUIDWrongPublicKey
    case wrongVaultSigning
    case replayedSigningChallenge
    case expiredSigningChallenge
    case wrongDomainSigningChallenge
    case wrongAudienceSigningChallenge
    case malformedContract
    case remoteConfigurationLookup
    case oversizedConfigurationPayload
    case bridgeUnknownCommand
    case proofContextMismatch
}

public enum CellSecurityProbeExecutionBoundary: String, Codable, Sendable {
    case localOnly
    case stagingAllowlistOnly
}

public struct CellSecurityProbeExpectation: Codable, Equatable, Sendable {
    public var expectedEventKind: CellSecurityEventKind
    public var expectedReasonCode: String
    public var expectedRequiredAction: String?

    public init(
        expectedEventKind: CellSecurityEventKind,
        expectedReasonCode: String,
        expectedRequiredAction: String? = nil
    ) {
        self.expectedEventKind = expectedEventKind
        self.expectedReasonCode = expectedReasonCode
        self.expectedRequiredAction = expectedRequiredAction
    }
}

public struct CellSecurityProbe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: CellSecurityProbeKind
    public var summary: String
    public var executionBoundary: CellSecurityProbeExecutionBoundary
    public var performsNetworkIO: Bool
    public var expectation: CellSecurityProbeExpectation
    public var remediation: String
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        kind: CellSecurityProbeKind,
        summary: String,
        executionBoundary: CellSecurityProbeExecutionBoundary = .localOnly,
        performsNetworkIO: Bool = false,
        expectation: CellSecurityProbeExpectation,
        remediation: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.executionBoundary = executionBoundary
        self.performsNetworkIO = performsNetworkIO
        self.expectation = expectation
        self.remediation = remediation
        self.metadata = metadata
    }
}

public enum CellSecurityProbeCatalog {
    public static let baseline: [CellSecurityProbe] = [
        CellSecurityProbe(
            id: "forged-uuid-wrong-public-key",
            name: "Forged UUID with wrong public key",
            kind: .forgedUUIDWrongPublicKey,
            summary: "Requester reuses an owner UUID with a different signing key.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .authorizationDenied,
                expectedReasonCode: "identity_public_key_mismatch",
                expectedRequiredAction: "restore_owner_identity_or_link_scaffold"
            ),
            remediation: "Restore the owner identity, link the scaffold through an owner-approved proof, or request a signed contract."
        ),
        CellSecurityProbe(
            id: "wrong-vault-signing",
            name: "Wrong vault signing",
            kind: .wrongVaultSigning,
            summary: "A vault is asked to sign for an Identity whose public key does not match the stored key.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .vaultSignRejected,
                expectedReasonCode: CellSecurityReasonCode.invalidSigningChallenge,
                expectedRequiredAction: "retry_with_valid_identity_signing_challenge"
            ),
            remediation: "Use the vault that owns the private key or present a new owner-approved proof."
        ),
        CellSecurityProbe(
            id: "replayed-signing-challenge",
            name: "Replayed signing challenge",
            kind: .replayedSigningChallenge,
            summary: "A previously consumed signing challenge is submitted again.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .signingChallengeReplay,
                expectedReasonCode: CellSecurityReasonCode.challengeReplay,
                expectedRequiredAction: "retry_with_fresh_challenge"
            ),
            remediation: "Reject the replay and create a new nonce-scoped challenge."
        ),
        CellSecurityProbe(
            id: "expired-signing-challenge",
            name: "Expired signing challenge",
            kind: .expiredSigningChallenge,
            summary: "A signing challenge is submitted after its validity window.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .vaultSignRejected,
                expectedReasonCode: CellSecurityReasonCode.challengeExpired,
                expectedRequiredAction: "retry_with_current_challenge"
            ),
            remediation: "Issue a fresh challenge with current timestamps."
        ),
        CellSecurityProbe(
            id: "wrong-domain-signing-challenge",
            name: "Wrong-domain signing challenge",
            kind: .wrongDomainSigningChallenge,
            summary: "A challenge is validly signed but scoped to the wrong domain.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .vaultSignRejected,
                expectedReasonCode: CellSecurityReasonCode.invalidSigningChallenge,
                expectedRequiredAction: "retry_with_valid_identity_signing_challenge"
            ),
            remediation: "Bind the proof to the target identity domain and resource."
        ),
        CellSecurityProbe(
            id: "wrong-audience-signing-challenge",
            name: "Wrong-audience signing challenge",
            kind: .wrongAudienceSigningChallenge,
            summary: "A challenge is replayed across consumers by changing audience expectations.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .vaultSignRejected,
                expectedReasonCode: CellSecurityReasonCode.invalidSigningChallenge,
                expectedRequiredAction: "retry_with_valid_identity_signing_challenge"
            ),
            remediation: "Use audience-scoped challenge generation and verification."
        ),
        CellSecurityProbe(
            id: "malformed-contract",
            name: "Malformed contract",
            kind: .malformedContract,
            summary: "A signed contract has the wrong subject, issuer, signatory, domain, or expiry.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .contractRejected,
                expectedReasonCode: "contract_rejected",
                expectedRequiredAction: "request_valid_contract"
            ),
            remediation: "Request a fresh contract from the cell owner with the expected subject and domain."
        ),
        CellSecurityProbe(
            id: "remote-configuration-lookup",
            name: "Remote configuration lookup without allowlist",
            kind: .remoteConfigurationLookup,
            summary: "A configuration tries to resolve through a remote cell endpoint that policy has not allowlisted.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .configLookupBlocked,
                expectedReasonCode: CellSecurityReasonCode.remoteEndpointBlocked,
                expectedRequiredAction: "allowlist_endpoint_or_use_local_configuration"
            ),
            remediation: "Allowlist the endpoint or ship a local configuration."
        ),
        CellSecurityProbe(
            id: "oversized-configuration-payload",
            name: "Oversized configuration payload",
            kind: .oversizedConfigurationPayload,
            summary: "A configuration payload exceeds accepted depth or size limits.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .configLookupBlocked,
                expectedReasonCode: "configuration_payload_rejected",
                expectedRequiredAction: "reduce_payload_or_use_catalog_reference"
            ),
            remediation: "Reject the payload and use a catalog-backed configuration reference."
        ),
        CellSecurityProbe(
            id: "bridge-unknown-command",
            name: "Bridge unknown command",
            kind: .bridgeUnknownCommand,
            summary: "A bridge receives an unsupported command and must not treat it as authority.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .transportRejected,
                expectedReasonCode: "unknown_bridge_command",
                expectedRequiredAction: "ignore_or_upgrade_protocol"
            ),
            remediation: "Ignore the command, record diagnostics, and require protocol upgrade if legitimate."
        ),
        CellSecurityProbe(
            id: "proof-context-mismatch",
            name: "Proof context mismatch",
            kind: .proofContextMismatch,
            summary: "A credential or proof is valid but belongs to a different subject or context.",
            expectation: CellSecurityProbeExpectation(
                expectedEventKind: .contractRejected,
                expectedReasonCode: "proof_context_mismatch",
                expectedRequiredAction: "present_context_bound_proof"
            ),
            remediation: "Require a proof bound to the requester, resource, action, and domain."
        )
    ]
}
