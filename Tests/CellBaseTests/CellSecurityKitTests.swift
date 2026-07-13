// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class CellSecurityKitTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousSecurityEventSink: CellSecurityEventSink?
    private var previousSigningChallengeReplayStore: CellSecuritySigningChallengeReplayStore?
    private var previousSecurityContainmentPolicy: CellSecurityContainmentPolicy?
    private var previousSecurityContainmentController: CellSecurityContainmentController?

    override func setUp() {
        super.setUp()
        previousVault = CellBase.defaultIdentityVault
        previousSecurityEventSink = CellBase.securityEventSink
        previousSigningChallengeReplayStore = CellBase.signingChallengeReplayStore
        previousSecurityContainmentPolicy = CellBase.securityContainmentPolicy
        previousSecurityContainmentController = CellBase.securityContainmentController
        CellBase.signingChallengeReplayStore = CellSecuritySigningChallengeReplayStore()
        CellBase.securityEventSink = nil
        CellBase.securityContainmentPolicy = .monitorOnly
        CellBase.securityContainmentController = CellSecurityContainmentController()
    }

    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        CellBase.securityEventSink = previousSecurityEventSink
        CellBase.signingChallengeReplayStore = previousSigningChallengeReplayStore
        if let previousSecurityContainmentPolicy {
            CellBase.securityContainmentPolicy = previousSecurityContainmentPolicy
        }
        CellBase.securityContainmentController = previousSecurityContainmentController
        super.tearDown()
    }

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

    func testCellConfigurationRemoteLookupRecordsSecurityEvent() async throws {
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        let lookup: ValueType = .object([
            "sourceCellEndpoint": .string("cell://remote.example/Catalog?token=super-secret#private-fragment")
        ])

        let resolved = await CellConfigurationPayloadSupport.resolveCellConfiguration(
            from: lookup,
            requester: Identity()
        )

        XCTAssertNil(resolved)
        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.kind, .configLookupBlocked)
        XCTAssertEqual(events.last?.reasonCode, CellSecurityReasonCode.remoteEndpointBlocked)
        XCTAssertEqual(events.last?.requiredAction, "allowlist_endpoint_or_use_local_configuration")
        XCTAssertEqual(events.last?.resource.identifier, "cell://remote.example/Catalog")
        XCTAssertFalse(events.last?.resource.identifier.contains("super-secret") ?? true)
        XCTAssertFalse(events.last?.userMessage?.contains("super-secret") ?? true)
        XCTAssertFalse(events.last?.userMessage?.contains("private-fragment") ?? true)
        XCTAssertNil(events.last?.metadata["privatePayload"])
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

    func testInMemorySecurityEventSinkRetainsOnlyNewestEvents() async throws {
        let sink = InMemoryCellSecurityEventSink(maxEvents: 3)

        for index in 0..<5 {
            await sink.record(CellSecurityEvent(
                kind: .authorizationDenied,
                severity: .medium,
                resource: CellSecurityResource(
                    kind: "cell",
                    identifier: "cell-\(index)",
                    action: "read"
                ),
                reasonCode: "test_denial"
            ))
        }

        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.resource.identifier), ["cell-2", "cell-3", "cell-4"])
    }

    func testAuthorizationDeniedRecordsSecurityEvent() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        guard let owner = await vault.identity(for: "owner", makeNewIfNotFound: true),
              let requester = await vault.identity(for: "requester", makeNewIfNotFound: true) else {
            XCTFail("Expected identities")
            return
        }
        let cell = await GeneralCell(owner: owner)

        let decision = await cell.authorizationDecision(
            requestedAccess: "r---",
            at: "private.notes",
            for: requester
        )

        XCTAssertFalse(decision.allowed)
        let events = await sink.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .authorizationDenied)
        XCTAssertEqual(events[0].reasonCode, "agreement_or_proof_required")
        XCTAssertEqual(events[0].resource.keypath, "private.notes")
        XCTAssertEqual(events[0].requester?.identityUUID, requester.uuid)
        XCTAssertNil(events[0].metadata["privatePayload"])
    }

    func testContractRejectionRecordsSecurityEvent() async throws {
        let vault = MockIdentityVault()
        CellBase.defaultIdentityVault = vault
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        guard let owner = await vault.identity(for: "owner", makeNewIfNotFound: true),
              let requester = await vault.identity(for: "requester", makeNewIfNotFound: true) else {
            XCTFail("Expected identities")
            return
        }
        let cell = await GeneralCell(owner: owner)
        let agreement = Agreement(owner: owner)
        agreement.conditions = [
            LookupCondition(keypath: "identity.contractApproval", expectedValue: .bool(true))
        ]
        cell.agreementTemplate.conditions = agreement.conditions

        let state = await cell.addAgreement(agreement, for: requester, authorizedBy: owner)

        XCTAssertEqual(state, .rejected)
        let events = await sink.snapshot()
        XCTAssertEqual(events.last?.kind, .contractRejected)
        XCTAssertEqual(events.last?.reasonCode, "contract_conditions_unmet")
        XCTAssertEqual(events.last?.requiredAction, "review_agreement_or_present_required_proof")
        XCTAssertNil(events.last?.metadata["privatePayload"])
    }

    func testSecurityProbeCatalogIsLocalOnlyAndCoversBaselineThreats() {
        let probes = CellSecurityProbeCatalog.baseline

        XCTAssertGreaterThanOrEqual(probes.count, 10)
        XCTAssertTrue(probes.allSatisfy { !$0.performsNetworkIO })
        XCTAssertTrue(probes.allSatisfy { $0.executionBoundary == .localOnly })
        XCTAssertTrue(probes.contains { $0.kind == .forgedUUIDWrongPublicKey })
        XCTAssertTrue(probes.contains { $0.kind == .wrongVaultSigning })
        XCTAssertTrue(probes.contains { $0.kind == .replayedSigningChallenge })
        XCTAssertTrue(probes.contains { $0.kind == .remoteConfigurationLookup })
        XCTAssertTrue(probes.allSatisfy { !$0.expectation.expectedReasonCode.isEmpty })
        XCTAssertTrue(probes.allSatisfy { !$0.remediation.isEmpty })
    }

    func testContainmentPolicyProposesReplayActionsWithoutAutoGrantingAccess() {
        let now = Date(timeIntervalSince1970: 3_000)
        let event = CellSecurityEvent(
            kind: .signingChallengeReplay,
            severity: .high,
            occurredAt: now,
            resource: CellSecurityResource(kind: "bridge", identifier: "bridge-1", action: "sign"),
            requester: CellSecurityActor(
                identityUUID: "identity-1",
                signingKeyFingerprint: "fingerprint-1",
                domain: "bridge"
            ),
            reasonCode: CellSecurityReasonCode.challengeReplay,
            requiredAction: "retry_with_fresh_challenge"
        )
        let policy = CellSecurityContainmentPolicy.localProtection

        let actions = policy.actions(for: event, now: now)

        XCTAssertTrue(actions.contains { $0.kind == .revokeOrRetryChallenge })
        XCTAssertTrue(actions.contains { $0.kind == .quarantineBridge })
        XCTAssertTrue(actions.contains { $0.kind == .requireReauthentication })
        XCTAssertTrue(actions.allSatisfy { $0.automatic })
        XCTAssertTrue(actions.allSatisfy { $0.requiredAction.isEmpty == false })
        XCTAssertFalse(actions.contains { $0.requiredAction.lowercased().contains("grant") })
        XCTAssertEqual(
            actions.first { $0.kind == .quarantineBridge }?.expiresAt,
            now.addingTimeInterval(policy.bridgeQuarantineSeconds)
        )
    }

    func testContainmentControllerRateLimitsOnlyInLocalProtectionMode() async throws {
        let controller = CellSecurityContainmentController()
        let now = Date(timeIntervalSince1970: 4_000)
        let monitorPolicy = CellSecurityContainmentPolicy(
            mode: .monitorOnly,
            signingRateLimit: CellSecurityRateLimitPolicy(maxAttempts: 1, windowSeconds: 60)
        )
        let localPolicy = CellSecurityContainmentPolicy(
            mode: .localProtection,
            signingRateLimit: CellSecurityRateLimitPolicy(maxAttempts: 1, windowSeconds: 60)
        )

        let monitorFirst = await controller.checkSigningRateLimit(scope: "scope", policy: monitorPolicy, now: now)
        let monitorSecond = await controller.checkSigningRateLimit(scope: "scope", policy: monitorPolicy, now: now)
        let localFirst = await controller.checkSigningRateLimit(scope: "local-scope", policy: localPolicy, now: now)
        let localSecond = await controller.checkSigningRateLimit(scope: "local-scope", policy: localPolicy, now: now.addingTimeInterval(1))

        XCTAssertTrue(monitorFirst.allowed)
        XCTAssertTrue(monitorSecond.allowed)
        XCTAssertTrue(localFirst.allowed)
        XCTAssertFalse(localSecond.allowed)
    }

    func testContainmentControllerBoundsActionHistoryAndActorMaps() async throws {
        let controller = CellSecurityContainmentController(
            maxActions: 2,
            maxReauthenticationEntries: 2,
            maxRateLimitScopes: 2
        )
        let now = Date(timeIntervalSince1970: 4_500)
        let resource = CellSecurityResource(kind: "bridge", identifier: "bridge-1", action: "sign")

        for index in 0..<4 {
            await controller.applyManualAction(
                CellSecurityContainmentAction(
                    kind: .requireReauthentication,
                    reasonCode: CellSecurityReasonCode.reauthenticationRequired,
                    resource: resource,
                    actor: CellSecurityActor(identityUUID: "identity-\(index)"),
                    requiredAction: "require_reauthentication",
                    automatic: true,
                    createdAt: now.addingTimeInterval(TimeInterval(index))
                ),
                now: now.addingTimeInterval(TimeInterval(index))
            )
            _ = await controller.checkSigningRateLimit(
                scope: "scope-\(index)",
                policy: .localProtection,
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let snapshot = await controller.snapshot(now: now.addingTimeInterval(10))
        XCTAssertEqual(snapshot.actions.count, 2)
        XCTAssertEqual(snapshot.reauthenticationRequired.count, 2)
        XCTAssertFalse(snapshot.reauthenticationRequired.keys.contains("identity-0::"))
        XCTAssertFalse(snapshot.reauthenticationRequired.keys.contains("identity-1::"))
    }

    func testRecordSecurityEventFeedsContainmentController() async throws {
        let controller = CellSecurityContainmentController()
        let sink = InMemoryCellSecurityEventSink()
        CellBase.securityEventSink = sink
        CellBase.securityContainmentController = controller
        CellBase.securityContainmentPolicy = CellSecurityContainmentPolicy.localProtection
        let event = CellSecurityEvent(
            kind: .signingChallengeReplay,
            severity: .high,
            resource: CellSecurityResource(kind: "bridge", identifier: "bridge-1", action: "sign"),
            requester: CellSecurityActor(
                identityUUID: "identity-1",
                signingKeyFingerprint: "fingerprint-1",
                domain: "bridge"
            ),
            reasonCode: CellSecurityReasonCode.challengeReplay,
            requiredAction: "retry_with_fresh_challenge"
        )

        await CellBase.recordSecurityEvent(event)

        let events = await sink.snapshot()
        let snapshot = await controller.snapshot()
        let isQuarantined = await controller.isQuarantined(resourceKind: "bridge", identifier: "bridge-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(snapshot.actions.contains { $0.kind == .quarantineBridge })
        XCTAssertTrue(isQuarantined)
    }

    func testSecurityProbeRunnerPlansLocalCatalogAndRefusesUnallowlistedStaging() async throws {
        let runner = CellSecurityProbeRunner()

        let localReport = await runner.run(now: Date(timeIntervalSince1970: 5_000))
        let refusedReport = await runner.run(
            configuration: CellSecurityProbeRunConfiguration(
                mode: .stagingAllowlist,
                targetEndpoint: "https://unlisted.example/security",
                allowedStagingHosts: ["staging.example"]
            ),
            now: Date(timeIntervalSince1970: 5_100)
        )
        let allowedReport = await runner.run(
            configuration: CellSecurityProbeRunConfiguration(
                mode: .stagingAllowlist,
                targetEndpoint: "https://staging.example/security",
                allowedStagingHosts: ["staging.example"]
            ),
            now: Date(timeIntervalSince1970: 5_200)
        )

        XCTAssertEqual(localReport.refusedCount, 0)
        XCTAssertEqual(localReport.plannedCount, CellSecurityProbeCatalog.baseline.count)
        XCTAssertEqual(refusedReport.plannedCount, 0)
        XCTAssertEqual(refusedReport.refusedCount, CellSecurityProbeCatalog.baseline.count)
        XCTAssertEqual(refusedReport.results.first?.reasonCode, "staging_target_not_allowlisted")
        XCTAssertEqual(allowedReport.refusedCount, 0)
        XCTAssertEqual(allowedReport.plannedCount, CellSecurityProbeCatalog.baseline.count)
    }
}
