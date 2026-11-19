// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

// PDD_flow-plassering_2026-11-07, WP4: the agent's side of a same-entity link.
// The other side is played by CellProtocol's own approval service, the same one
// the Palazzo anchor runs, and the result must pass CellProtocol's own check.
// Moved from HavenAgentD with the client (WP10).
final class IdentityLinkClientTests: XCTestCase {
    private let vault: IdentityVaultProtocol = MockIdentityVault()

    private func identity(_ name: String) async -> Identity {
        await vault.identity(for: name, makeNewIfNotFound: true)!
    }

    private func request(for agent: Identity) async throws -> IdentityEnrollmentRequest {
        try await IdentityLinkClient.makeEnrollmentRequest(
            for: agent,
            audience: "haven",
            origin: "palazzo-comunale",
            requestedDomains: ["palazzo-comunale"],
            requestedIdentityContexts: ["palazzo"]
        )
    }

    private func approval(_ request: IdentityEnrollmentRequest, by custodian: Identity) async throws -> ValueType {
        let package = try await IdentityLinkProtocolService.approveEnrollment(
            IdentityLinkApprovalEnvelope(request: request, issuerType: .custodian, freshAuthRequired: true),
            issuerIdentity: custodian
        )
        return .object([
            "status": .string("approved"),
            "anchorOwnerUUID": .string(custodian.uuid),
            "approvalPackage": try IdentityLinkProtocolService.value(from: package)
        ])
    }

    func testTheAgentsRequestIsSignedByItsOwnKeyAndValid() async throws {
        let agent = await identity("agent")
        let request = try await request(for: agent)
        XCTAssertEqual(request.newIdentity.uuid, agent.uuid)
        XCTAssertEqual(request.proof?.byIdentityUUID, agent.uuid)
        XCTAssertEqual(request.requestedScopes, ["entity.same"])
        _ = try await IdentityLinkProtocolService.validateEnrollmentRequest(request)
    }

    func testACompletionBuiltFromTheApprovalPassesCellProtocolsCheck() async throws {
        let agent = await identity("agent")
        let custodian = await identity("palazzo-guest")
        let request = try await request(for: agent)
        let requestValue = try IdentityLinkProtocolService.value(from: request)
        // The HTTP body wraps the cell value as `value`; both shapes are accepted.
        let wrapped = ValueType.object(["value": try await approval(request, by: custodian)])

        let payload = try await IdentityLinkClient.completionPayload(
            approvalResponse: wrapped, request: requestValue, holder: agent, presentationDomain: "palazzo-comunale")
        guard case let .object(object) = payload else {
            return XCTFail("payload is not an object")
        }
        XCTAssertEqual(object["anchorOwnerUUID"], .string(custodian.uuid))
        let envelope = try IdentityLinkClient.decode(payload, as: IdentityLinkCompletionEnvelope.self)
        let result = try await IdentityLinkProtocolService.verifyCompletion(envelope)
        XCTAssertEqual(result.record.linkedIdentity.uuid, agent.uuid)
    }

    func testAnotherIdentityCannotCompleteTheAgentsRequest() async throws {
        let agent = await identity("agent")
        let stranger = await identity("stranger")
        let custodian = await identity("palazzo-guest")
        let request = try await request(for: agent)
        let approvalValue = try await approval(request, by: custodian)
        do {
            _ = try await IdentityLinkClient.completionPayload(
                approvalResponse: approvalValue,
                request: try IdentityLinkProtocolService.value(from: request),
                holder: stranger, presentationDomain: "palazzo-comunale")
            XCTFail("a stranger completed the agent's request")
        } catch {
            XCTAssertTrue(error is IdentityLinkClientError, "\(error)")
        }
    }

    func testAnApprovalWithoutItsPackageIsRefused() async throws {
        let agent = await identity("agent")
        let request = try await request(for: agent)
        do {
            _ = try await IdentityLinkClient.completionPayload(
                approvalResponse: .object(["anchorOwnerUUID": .string("x")]),
                request: try IdentityLinkProtocolService.value(from: request),
                holder: agent, presentationDomain: "palazzo-comunale")
            XCTFail("an approval without its package was accepted")
        } catch {
            XCTAssertEqual(error as? IdentityLinkClientError, .invalidApproval(
                "approvalPackage with approval, sameEntityCredential and issuerIdentity is missing"))
        }
    }

    func testARemoteHostGetsTheBridgeheadRouteOnceAndLocalEndpointsNone() async throws {
        let resolver = CellResolver.sharedInstance
        let host = "flowpl-\(UUID().uuidString.lowercased()).example.org"
        XCTAssertTrue(FlowPlacementRemoteHosts.registerIfNeeded(for: "cell://\(host)/PalazzoIdentityLink", resolver: resolver))
        XCTAssertEqual(resolver.remoteCellHostRoutesSnapshot()[host], FlowPlacementRemoteHosts.route)
        XCTAssertFalse(FlowPlacementRemoteHosts.registerIfNeeded(for: "cell://\(host)/PalazzoEntity", resolver: resolver))
        XCTAssertFalse(FlowPlacementRemoteHosts.registerIfNeeded(for: "cell:///EntityAnchor", resolver: resolver))
    }

    func testProofScopesFromAnApprovalStayInTheRequestedDomainAndAreKeptPerHost() throws {
        let link = UUID().uuidString, entity = UUID().uuidString
        let approval: ValueType = .object(["value": .object(["identityProofScopes": .list([
            .object(["domain": .string("palazzo-comunale"), "resource": .string(link)]),
            .object(["domain": .string("palazzo-comunale"), "resource": .string(entity)]),
            .object(["domain": .string("someone-else"), "resource": .string(UUID().uuidString)]),
            .object(["domain": .string("palazzo-comunale"), "resource": .string("not-a-uuid")]),
            .object(["domain": .string("palazzo-comunale"), "resource": .string(link)])
        ])])])
        let scopes = FlowPlacementProofScopes.scopes(fromApproval: approval, allowedDomains: ["palazzo-comunale"])
        XCTAssertEqual(scopes, [BridgeIdentityProofScope(domain: "palazzo-comunale", resource: link),
                                BridgeIdentityProofScope(domain: "palazzo-comunale", resource: entity)])
        XCTAssertTrue(FlowPlacementProofScopes.scopes(fromApproval: approval, allowedDomains: []).isEmpty)
        XCTAssertEqual(FlowPlacementProofScopes.websocketURL(for: "cell://palazzo.example.org/PalazzoIdentityLink"),
            "wss://palazzo.example.org/bridgehead/PalazzoIdentityLink")
        XCTAssertEqual(FlowPlacementProofScopes.websocketURL(for: "cell:///EntityAnchor"), nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("proof-scopes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FlowPlacementProofScopes.Store(fileURL: file)
        try store.record(host: "Palazzo.Example.org", scopes: scopes)
        try store.record(host: "palazzo.example.org", scopes: scopes)
        XCTAssertEqual(store.scope(for: "cell://palazzo.example.org/\(entity)"), scopes[1])
        XCTAssertEqual(store.scope(for: "cell://other.example.org/\(entity)"), nil)
        XCTAssertEqual(store.scope(for: "cell://palazzo.example.org/PalazzoEntity"), nil)
    }
}
