// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

/// A chat admits a guest only through its Agreement: the owner picks the
/// conditions, the guest meets them, and the host signs the contract.
final class ChatAgreementAdmissionTests: XCTestCase {
    private var previousDebugFlag = false

    override func setUp() {
        previousDebugFlag = CellBase.debugValidateAccessForEverything
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() {
        CellBase.debugValidateAccessForEverything = previousDebugFlag
    }

    private struct Fixture {
        let owner: Identity
        let guest: Identity
        let stranger: Identity
        let cell: ChatCell
        let artifact: Object
        let acceptance: Object
    }

    private func makeFixture(conditions: [String]) async throws -> Fixture {
        let vault = ChatCellTestIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let guest = await vault.identity(for: "guest", makeNewIfNotFound: true)!
        let stranger = await vault.identity(for: "stranger", makeNewIfNotFound: true)!
        let cell = await ChatCell(owner: owner)

        let applied = try await cell.set(keypath: "audience.admissionConditions", value: .list(conditions.map(ValueType.string)), requester: owner)
        XCTAssertEqual(applied.map { String(describing: $0) }, String(describing: ValueType.list(conditions.map(ValueType.string))))
        _ = try await cell.set(keypath: "audience.inviteIdentities", value: .list([.identity(guest.publicIdentitySnapshot())]), requester: owner)
        guard case let .list(artifacts)? = try await cell.set(keypath: "audience.generateInvitationArtifacts", value: .bool(true), requester: owner),
              case let .object(artifact)? = artifacts.first else {
            throw XCTSkip("no invitation artifact")
        }
        // The guest signs the acceptance on its own node; any ChatCell can build it.
        let guestNode = await ChatCell(owner: guest)
        guard case let .object(acceptance)? = try await guestNode.set(keypath: "audience.generateInvitationAcceptance", value: .object(artifact), requester: guest) else {
            throw XCTSkip("no acceptance")
        }
        return Fixture(owner: owner, guest: guest, stranger: stranger, cell: cell, artifact: artifact, acceptance: acceptance)
    }

    /// What a guest sends: the advertised template with the grants it wants.
    private func request(from cell: ChatCell, requester: Identity) async throws -> Agreement {
        // Round-trip through the wire so the guest sends exactly what it was advertised.
        let advertised = try await cell.advertise(for: requester)
        let data = try JSONEncoder().encode(advertised)
        return try JSONDecoder().decode(AnyCell.self, from: data).agreementTemplate
    }

    func testInvitationConditionAdmitsTheInviteeAndRevocationEndsAccess() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted"])
        let presented = try await f.cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object(["artifact": .object(f.artifact), "acceptance": .object(f.acceptance)]),
            requester: f.guest
        )
        guard case let .object(presentedObject)? = presented else {
            return XCTFail("invitee could not present its own proof: \(String(describing: presented))")
        }
        XCTAssertEqual(presentedObject["status"], .string("accepted"))

        let state = await f.cell.addAgreement(try await request(from: f.cell, requester: f.guest), for: f.guest)
        XCTAssertEqual(state, .signed)
        let canSend = await f.cell.validateAccess("-w--", at: "sendMessage", for: f.guest)
        XCTAssertTrue(canSend)
        let sent = try await f.cell.set(keypath: "sendMessage", value: .string("hei"), requester: f.guest)
        guard case let .object(sentObject)? = sent else { return XCTFail("guest could not send") }
        XCTAssertEqual(sentObject["status"], .string("sent"))

        let strangerState = await f.cell.addAgreement(try await request(from: f.cell, requester: f.stranger), for: f.stranger)
        XCTAssertEqual(strangerState, .rejected)

        _ = try await f.cell.set(keypath: "audience.revokeInvites", value: .list([.string(f.guest.uuid)]), requester: f.owner)
        let canSendAfterRevoke = await f.cell.validateAccess("-w--", at: "sendMessage", for: f.guest)
        XCTAssertFalse(canSendAfterRevoke)
    }

    func testInvitationConditionRejectsAGuestThatDidNotPresentProof() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted"])
        let state = await f.cell.addAgreement(try await request(from: f.cell, requester: f.guest), for: f.guest)
        XCTAssertEqual(state, .rejected)
    }

    func testOwnerAcceptedMemberMeetsMemberConditionButNotInvitationCondition() async throws {
        let f = try await makeFixture(conditions: ["member"])
        _ = try await f.cell.set(keypath: "audience.acceptInvites", value: .list([.string(f.guest.uuid)]), requester: f.owner)
        let state = await f.cell.addAgreement(try await request(from: f.cell, requester: f.guest), for: f.guest)
        XCTAssertEqual(state, .signed)

        let g = try await makeFixture(conditions: ["invitationAccepted"])
        _ = try await g.cell.set(keypath: "audience.acceptInvites", value: .list([.string(g.guest.uuid)]), requester: g.owner)
        let invitationState = await g.cell.addAgreement(try await request(from: g.cell, requester: g.guest), for: g.guest)
        XCTAssertEqual(invitationState, .rejected)
    }

    func testOnlyTheOwnerSetsConditionsAndAnotherPersonsProofAdmitsOnlyThatPerson() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted"])
        let byGuest = try? await f.cell.set(keypath: "audience.admissionConditions", value: .list([]), requester: f.guest)
        XCTAssertNotEqual(byGuest.flatMap { $0 }.map { String(describing: $0) }, String(describing: ValueType.list([])))
        let unchanged = try await f.cell.get(keypath: "audience.admissionConditions", requester: f.owner)
        XCTAssertEqual(String(describing: unchanged), String(describing: ValueType.list([.string("invitationAccepted")])))

        // The proof carries both signatures, so whoever delivers it, it admits the invitee only.
        let relayed = try await f.cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object(["artifact": .object(f.artifact), "acceptance": .object(f.acceptance)]),
            requester: f.stranger
        )
        guard case let .object(relayedObject)? = relayed else { return XCTFail("relay failed: \(String(describing: relayed))") }
        XCTAssertEqual(relayedObject["status"], .string("accepted"))
        let strangerState = await f.cell.addAgreement(try await request(from: f.cell, requester: f.stranger), for: f.stranger)
        XCTAssertEqual(strangerState, .rejected)
        let guestState = await f.cell.addAgreement(try await request(from: f.cell, requester: f.guest), for: f.guest)
        XCTAssertEqual(guestState, .signed)
    }

    func testAGuestCannotWidenTheAgreementBeyondTheTemplate() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted"])
        _ = try await f.cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object(["artifact": .object(f.artifact), "acceptance": .object(f.acceptance)]),
            requester: f.guest
        )
        let widened = try await request(from: f.cell, requester: f.guest)
        widened.addGrant("rw--", for: "audience.admissionConditions")
        let widenedState = await f.cell.addAgreement(widened, for: f.guest)
        XCTAssertEqual(widenedState, .rejected)
        let dropped = try await request(from: f.cell, requester: f.guest)
        dropped.conditions = []
        let droppedState = await f.cell.addAgreement(dropped, for: f.guest)
        XCTAssertEqual(droppedState, .rejected)
    }

    func testConditionsAndPolicySurviveARestoredChat() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted"])
        _ = try await f.cell.set(
            keypath: "audience.acceptInvitationArtifact",
            value: .object(["artifact": .object(f.artifact), "acceptance": .object(f.acceptance)]),
            requester: f.guest
        )
        let restored = try JSONDecoder().decode(ChatCell.self, from: JSONEncoder().encode(f.cell))
        let conditions = try await restored.get(keypath: "audience.admissionConditions", requester: f.owner)
        XCTAssertEqual(String(describing: conditions), String(describing: ValueType.list([.string("invitationAccepted")])))
        XCTAssertEqual(restored.agreementAdmissionPolicy, .automaticWhenConditionsMet)
        let holds = try await restored.get(keypath: "audience.admission.invitationAccepted", requester: f.guest)
        XCTAssertEqual(holds, .bool(true))
        let strangerHolds = try await restored.get(keypath: "audience.admission.invitationAccepted", requester: f.stranger)
        XCTAssertEqual(strangerHolds, .bool(false))
    }

    func testConditionsTravelInTheAgreementWireFormat() async throws {
        let f = try await makeFixture(conditions: ["invitationAccepted", "member"])
        let agreement = try await request(from: f.cell, requester: f.guest)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agreement)) as? [String: Any]
        let conditions = json?["conditions"] as? [[String: Any]]
        XCTAssertEqual(conditions?.count, 2)
        XCTAssertEqual(conditions?.first?["type"] as? String, "lookup")
        let inner = conditions?.first?["condition"] as? [String: Any]
        XCTAssertEqual(inner?["keypath"] as? String, "target.audience.admission.invitationAccepted")
        print("AGREEMENT_WIRE", String(data: try JSONEncoder().encode(agreement), encoding: .utf8)!)
    }
}
