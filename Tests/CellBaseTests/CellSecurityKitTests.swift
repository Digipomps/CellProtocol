// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CellSecurityKitTests: XCTestCase {
    func testReplayStoreAcceptsFirstChallengeAndRejectsReplay() async throws {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let challenge = IdentitySigningChallenge(
            identityUUID: "identity-1",
            publicKeyFingerprint: "fingerprint-1",
            domain: "private",
            resource: "cell:///Vault",
            action: "sign",
            audience: "bridge-1",
            nonce: Data([1, 2, 3, 4]),
            issuedAt: issuedAt,
            validity: 60
        )
        let store = CellSecuritySigningChallengeReplayStore()

        let first = await store.consume(challenge, now: issuedAt.addingTimeInterval(1))
        let second = await store.consume(challenge, now: issuedAt.addingTimeInterval(2))

        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(second, .replay)
    }

    func testReplayStoreRejectsExpiredChallenge() async throws {
        let issuedAt = Date(timeIntervalSince1970: 2_000)
        let challenge = IdentitySigningChallenge(
            identityUUID: "identity-1",
            publicKeyFingerprint: "fingerprint-1",
            domain: "private",
            resource: "cell:///Vault",
            action: "sign",
            audience: "bridge-1",
            nonce: Data([4, 3, 2, 1]),
            issuedAt: issuedAt,
            validity: 1
        )
        let store = CellSecuritySigningChallengeReplayStore()

        let decision = await store.consume(challenge, now: issuedAt.addingTimeInterval(2))

        XCTAssertEqual(decision, .expired)
    }

    func testEndpointPolicyBlocksRemoteByDefault() throws {
        let policy = CellSecurityEndpointPolicy()

        XCTAssertThrowsError(try policy.validate("cell://remote.example/Vault")) { error in
            XCTAssertEqual(
                error as? CellSecurityEndpointPolicyError,
                .remoteEndpointNotAllowed("remote.example")
            )
        }
    }

    func testEndpointPolicyAllowsLocalCellEndpointByDefault() throws {
        let policy = CellSecurityEndpointPolicy()

        let validation = try policy.validate("cell:///Vault")

        XCTAssertFalse(validation.isRemote)
        XCTAssertNil(validation.host)
        XCTAssertEqual(validation.canonicalEndpoint, "cell:///Vault")
    }

    func testEndpointPolicyAllowsWhitelistedRemoteHost() throws {
        let policy = CellSecurityEndpointPolicy(
            allowRemoteEndpoints: true,
            allowedRemoteHosts: ["remote.example"]
        )

        let validation = try policy.validate("cell://Remote.Example/Vault")

        XCTAssertTrue(validation.isRemote)
        XCTAssertEqual(validation.host, "remote.example")
        XCTAssertEqual(validation.canonicalEndpoint, "cell://remote.example/Vault")
    }

    func testEndpointPolicyPreservesPathCaseWhenCanonicalizing() throws {
        let policy = CellSecurityEndpointPolicy(
            allowRemoteEndpoints: true,
            allowedRemoteHosts: ["remote.example"]
        )

        let validation = try policy.validate("cell://Remote.Example/CaseSensitiveCell")

        XCTAssertEqual(validation.canonicalEndpoint, "cell://remote.example/CaseSensitiveCell")
    }

    func testCellConfigurationResolutionBlocksRemoteSourceEndpointByDefault() async throws {
        var configuration = CellConfiguration(
            name: "Remote catalog",
            cellReferences: [
                CellReference(endpoint: "cell:///Vault", label: "vault")
            ]
        )
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell://remote.example/Catalog"
        )

        let resolved = await CellConfigurationPayloadSupport.resolveCellConfiguration(
            from: .cellConfiguration(configuration),
            requester: Identity()
        )

        XCTAssertNil(resolved)
    }

    func testCellConfigurationResolutionRetargetsWhitelistedRemoteSourceEndpoint() async throws {
        var configuration = CellConfiguration(
            name: "Remote catalog",
            cellReferences: [
                CellReference(endpoint: "cell:///Vault", label: "vault")
            ]
        )
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell://Remote.Example/Catalog"
        )
        let endpointPolicy = CellSecurityEndpointPolicy(
            allowRemoteEndpoints: true,
            allowedRemoteHosts: ["remote.example"]
        )

        let resolved = await CellConfigurationPayloadSupport.resolveCellConfiguration(
            from: .cellConfiguration(configuration),
            requester: Identity(),
            endpointPolicy: endpointPolicy
        )

        XCTAssertEqual(resolved?.cellReferences?.first?.endpoint, "cell://remote.example/Vault")
    }

    func testCellConfigurationCandidateEndpointMatchingPreservesPathCase() throws {
        var candidate = CellConfiguration(
            name: "Case sensitive",
            cellReferences: [
                CellReference(endpoint: "cell:///Vault", label: "vault")
            ]
        )
        candidate.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell://remote.example/CaseSensitiveCatalog"
        )
        let endpointPolicy = CellSecurityEndpointPolicy(
            allowRemoteEndpoints: true,
            allowedRemoteHosts: ["remote.example"]
        )
        let lookup: ValueType = .object([
            "name": .string("Case sensitive"),
            "sourceCellEndpoint": .string("cell://remote.example/casesensitivecatalog")
        ])

        let resolved = CellConfigurationPayloadSupport.resolveCellConfiguration(
            from: lookup,
            candidates: [candidate],
            endpointPolicy: endpointPolicy
        )

        XCTAssertNil(resolved)
    }

    func testSecurityEventCarriesRemediationWithoutPrivatePayload() {
        let event = CellSecurityEvent(
            kind: .authorizationDenied,
            severity: .high,
            resource: CellSecurityResource(
                kind: "cell",
                identifier: "cell-1",
                action: "read",
                keypath: "private.notes"
            ),
            requester: CellSecurityActor(
                identityUUID: "requester-1",
                signingKeyFingerprint: "fingerprint-1",
                domain: "private"
            ),
            reasonCode: "agreement_or_proof_required",
            userMessage: "Access requires an owner proof, signed contract, or concrete policy proof.",
            requiredAction: "request_contract_or_present_proof",
            canAutoResolve: false,
            metadata: ["policy": "owner-or-contract"]
        )

        XCTAssertEqual(event.kind, .authorizationDenied)
        XCTAssertEqual(event.requiredAction, "request_contract_or_present_proof")
        XCTAssertNil(event.metadata["privatePayload"])
    }
}
