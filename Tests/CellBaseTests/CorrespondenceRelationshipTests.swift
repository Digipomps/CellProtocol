// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(Testing) @testable import CellBase

final class CorrespondenceRelationshipTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    override func setUp() {
        super.setUp()
        XCTAssertFalse(CellBase.debugValidateAccessForEverything)
        CellBase.debugValidateAccessForEverything = false
        previousVault = CellBase.defaultIdentityVault
    }
    override func tearDown() {
        CellBase.defaultIdentityVault = previousVault
        super.tearDown()
    }
    private struct Fixture {
        let e: EphemeralIdentityVault
        let h: EphemeralIdentityVault
        let i: EphemeralIdentityVault
        let owner: Identity
        let invitee: Identity
        let cell: CorrespondenceCell
        let contract: Contract
        let storageRoot: URL
    }
    private func identity(_ vault: EphemeralIdentityVault) async -> Identity {
        let uuid = UUID().uuidString
        var identity = Identity(uuid, displayName: uuid, identityVault: vault)
        await vault.addIdentity(identity: &identity, for: UUID().uuidString)
        return identity
    }
    private func fixture(admit: Bool = true, nowProvider: @escaping () -> Date = Date.init) async throws -> Fixture {
        let e = EphemeralIdentityVault(), h = EphemeralIdentityVault(), i = EphemeralIdentityVault()
        let owner = await identity(e), invitee = await identity(i)
        CellBase.defaultIdentityVault = h
        let cell = await CorrespondenceCell(owner: owner.publicIdentitySnapshot(), nowProvider: nowProvider)
        let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("korr-relation-" + UUID().uuidString)
        try await cell.configureAttachmentStorage(root: storageRoot, requester: owner)
        addTeardownBlock { if FileManager.default.fileExists(atPath: storageRoot.path) { try FileManager.default.removeItem(at: storageRoot) } }
        let agreement = CorrespondenceAgreementTemplates.withAttachments(owner: owner.publicIdentitySnapshot())
        agreement.state = .signed
        agreement.duration = 3600
        agreement.signatories = [owner.publicIdentitySnapshot(), invitee.publicIdentitySnapshot()]
        let contract = try await Contract.signed(agreement: agreement, issuer: owner,
            subject: invitee.publicIdentitySnapshot(), domain: cell.identityDomain, targetCellUUID: cell.uuid)
        if admit {
            let resolver = CellResolver.makeIsolatedForTesting()
            let name = "correspondence-" + UUID().uuidString
            try await resolver.registerNamedEmitCell(name: name, emitCell: cell,
                scope: .scaffoldUnique, identity: owner)
            let endpoint = try XCTUnwrap(URL(string: "cell:///\(name)/agreement.accept"))
            let response = try await resolver.set(value: CorrespondenceCellCodec.encode(contract),
                into: endpoint, requester: invitee)
            XCTAssertEqual(field("status", response ?? .null), .string("accepted"))
            await resolver.unregisterEmitCell(uuid: cell.uuid)
        }
        let hostOwner = await h.identity(forUUID: owner.uuid)
        let hostInvitee = await h.identity(forUUID: invitee.uuid)
        XCTAssertNil(hostOwner)
        XCTAssertNil(hostInvitee)
        return Fixture(e: e, h: h, i: i, owner: owner, invitee: invitee, cell: cell, contract: contract, storageRoot: storageRoot)
    }
    func testUnsignedContractLabelsCannotPreventPersistence() async throws {
        let f = try await fixture(admit: false)
        var contract = f.contract
        contract.subject.displayName = "unsigned-member-label"
        contract.subject.properties = ["label": .string("unsigned-property")]
        contract.subject.homeVaultReference = "unsigned-vault"
        contract.issuer.displayName = "unsigned-issuer-label"
        contract.issuer.properties = ["label": .string("unsigned-issuer-property")]
        contract.issuer.homeVaultReference = "unsigned-issuer-vault"
        let verified = await contract.verifyCryptographicSignature()
        XCTAssertTrue(verified)
        let result = try await f.cell.set(keypath: "agreement.accept",
            value: CorrespondenceCellCodec.encode(contract), requester: f.invitee)
        XCTAssertEqual(field("status", result), .string("accepted"))
        try await assertCanonicalMemberSurvivesPersistence(f.cell, member: f.invitee)
    }

    func testNamedVaultIdentityInviteSurvivesPersistence() async throws {
        let f = try await fixture(admit: false)
        var member = Identity(UUID().uuidString, displayName: "vault-real-name", identityVault: f.e)
        member.properties = ["label": .string("vault-property")]
        await f.e.addIdentity(identity: &member, for: UUID().uuidString)
        CellBase.defaultIdentityVault = f.e
        let result = try await f.cell.set(keypath: "audience.inviteIdentities",
            value: .object(["identityUUID": .string(member.uuid)]), requester: f.owner)
        XCTAssertEqual(field("status", result), .string("invited"))
        try await assertCanonicalMemberSurvivesPersistence(f.cell, member: member)
    }

    func testNamedLocalAgreementMemberSurvivesPersistence() async throws {
        let f = try await fixture(admit: false)
        f.invitee.displayName = "vault-real-name"
        f.invitee.properties = ["label": .string("vault-property")]
        let result = await f.cell.addAgreement(f.cell.agreementTemplate, for: f.invitee, authorizedBy: f.owner)
        XCTAssertEqual(result, .signed)
        try await assertCanonicalMemberSurvivesPersistence(f.cell, member: f.invitee)
    }

    func testUnsignedJoinContractLabelsAreCanonicalBeforeLedgerStorage() async throws {
        let f = try await fixture(admit: false)
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let pending = try CorrespondenceCellCodec.decode(try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: f.invitee), as: CorrespondenceJoinResult.self)
        var contract = f.contract
        contract.subject.displayName = "unsigned-member-label"
        contract.issuer.properties = ["label": .string("unsigned-issuer-property")]
        let decision = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: pending.requestID, approve: true, contract: contract)), requester: f.owner)
        XCTAssertEqual(field("status", decision), .string("approved"))
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: JSONEncoder().encode(f.cell))
        let result = try CorrespondenceCellCodec.decode(try await restored.get(keypath: "join.result." + pending.requestID,
            requester: f.invitee), as: CorrespondenceJoinResult.self)
        let stored = try XCTUnwrap(result.contract)
        XCTAssertEqual(stored.subject.displayName, stored.subject.uuid)
        XCTAssertTrue(stored.issuer.properties?.isEmpty ?? true)
        let verified = await stored.verifyCryptographicSignature()
        XCTAssertTrue(verified)
    }

    func testCanonicalizationDoesNotAuthorizeAlteredSignedAgreement() async throws {
        let f = try await fixture(admit: false)
        var contract = f.contract
        contract.subject.displayName = "unsigned-member-label"
        contract.agreement.duration += 1
        let result = await f.cell.acceptExternallySignedAgreement(contract, for: f.invitee)
        XCTAssertEqual(result, .rejected)
        let snapshot = await f.cell.currentAuthorizationSnapshot()
        XCTAssertFalse(snapshot.members.contains { $0.uuid == f.invitee.uuid })
        _ = try JSONEncoder().encode(f.cell)
    }

    private func assertCanonicalMemberSurvivesPersistence(_ cell: CorrespondenceCell, member: Identity) async throws {
        let bytes = try JSONEncoder().encode(cell)
        let text = String(decoding: bytes, as: UTF8.self)
        for label in ["unsigned-member-label", "unsigned-property", "unsigned-vault",
                      "unsigned-issuer-label", "unsigned-issuer-property", "unsigned-issuer-vault",
                      "vault-real-name", "vault-property"] {
            XCTAssertFalse(text.contains(label))
        }
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: bytes)
        let snapshot = await restored.currentAuthorizationSnapshot()
        let installed = try XCTUnwrap(snapshot.members.first { $0.uuid == member.uuid })
        XCTAssertEqual(installed.displayName, installed.uuid)
        XCTAssertTrue(installed.properties?.isEmpty ?? true)
        XCTAssertNil(installed.homeVaultReference)
        let contract = try XCTUnwrap(snapshot.contracts.first { $0.subject.uuid == member.uuid })
        XCTAssertEqual(contract.issuer.displayName, contract.issuer.uuid)
        let verified = await contract.verifyCryptographicSignature()
        XCTAssertTrue(verified)
        _ = try await restored.state(requester: member)
    }

    private func join(_ f: Fixture, requester: Identity? = nil) async throws -> String {
        let presenter = requester ?? f.invitee
        let resolver = CellResolver.makeIsolatedForTesting()
        let name = "join-" + UUID().uuidString
        try await resolver.registerNamedEmitCell(name: name, emitCell: f.cell, scope: .scaffoldUnique, identity: f.owner)
        func endpoint(_ key: String) -> URL { URL(string: "cell:///\(name)/\(key)")! }

        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let response = try await resolver.set(value: CorrespondenceCellCodec.encode(request), into: endpoint("join.request"), requester: presenter) ?? .null
        let receipt = try CorrespondenceCellCodec.decode(response, as: CorrespondenceJoinResult.self)
        XCTAssertEqual(receipt.status, "pending")
        let pending = try CorrespondenceCellCodec.decode(try await resolver.get(from: endpoint("join.pending"), requester: f.owner) ?? .null, as: [CorrespondenceJoinPending].self)
        XCTAssertEqual(pending.count, 1)
        let item = try XCTUnwrap(pending.first)
        let ownerCode = CorrespondenceJoinCode.code(cellUUID: f.cell.uuid, invitationID: item.invitationID,
            signingPublicKey: item.signingPublicKey, agreementPublicKey: item.agreementPublicKey)
        let inviteeCode = CorrespondenceJoinCode.code(cellUUID: f.cell.uuid, invitationID: invitation.invitationID,
            signingPublicKey: request.signingPublicKey, agreementPublicKey: request.agreementPublicKey)
        XCTAssertEqual(ownerCode, inviteeCode)
        XCTAssertEqual(ownerCode.count, 6)
        let alteredCode = CorrespondenceJoinCode.code(cellUUID: f.cell.uuid, invitationID: invitation.invitationID,
            signingPublicKey: Data(repeating: 1, count: 32), agreementPublicKey: request.agreementPublicKey)
        XCTAssertNotEqual(ownerCode, alteredCode)
        let decision = try await resolver.set(value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: receipt.requestID, approve: true, contract: f.contract)), into: endpoint("join.decide"), requester: f.owner) ?? .null
        XCTAssertEqual(field("status", decision), .string("approved"))
        let result = try CorrespondenceCellCodec.decode(try await resolver.get(from: endpoint("join.result." + receipt.requestID), requester: presenter) ?? .null, as: CorrespondenceJoinResult.self)
        XCTAssertEqual(result.status, "approved")
        let contract = try XCTUnwrap(result.contract)
        let snapshot = try JSONEncoder().encode(f.cell)
        let json = String(decoding: snapshot, as: UTF8.self)
        XCTAssertFalse(json.contains("displayName"))
        XCTAssertFalse(json.contains("privateKey\":true"))
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: snapshot)
        let restoredResult = try CorrespondenceCellCodec.decode(try await restored.get(keypath: "join.result." + receipt.requestID, requester: presenter), as: CorrespondenceJoinResult.self)
        let restoredContract = try XCTUnwrap(restoredResult.contract)
        let verified = await restoredContract.verifyCryptographicSignature()
        XCTAssertTrue(verified)
        let accepted = try await resolver.set(value: CorrespondenceCellCodec.encode(contract), into: endpoint("agreement.accept"), requester: presenter) ?? .null
        await resolver.unregisterEmitCell(uuid: f.cell.uuid)
        XCTAssertEqual(field("status", accepted), .string("accepted"))
        print("PURPOSE join: I requested; E matched six-digit code and approved; I retrieved agreement and accepted")
        return receipt.requestID
    }

    // Same public reconstruction as BridgeChannelSession; only the invitee's own
    // isolated vault supplies the live signing proof. The host has neither key.
    private func signOnly(_ identity: Identity, vault: EphemeralIdentityVault) throws -> Identity {
        let requester = try BridgeChannelAuthentication.PublicIdentity(identity).makeIdentity()
        XCTAssertNil(requester.publicKeyAgreementSecureKey)
        requester.identityVault = vault
        return requester
    }

    private func verifyExpiredJoinRenewal(signingOnly: Bool) async throws {
        let f = try await fixture(admit: false)
        let requester = signingOnly ? try signOnly(f.invitee, vault: f.i) : f.invitee
        let id = try await join(f, requester: requester)
        let before = await f.cell.currentAuthorizationSnapshot()
        XCTAssertEqual(before.contracts.count, 1)
        XCTAssertEqual(before.members.count, 1)
        let now = Date(timeIntervalSince1970: f.contract.expiresAt + 1)
        f.cell.authorizationClock = { now }
        do { _ = try await f.cell.state(requester: requester); XCTFail("Expired member read history") }
        catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        let oldResult = try CorrespondenceCellCodec.decode(try await f.cell.get(keypath: "join.result." + id,
            requester: requester), as: CorrespondenceJoinResult.self)
        XCTAssertEqual(oldResult.contract?.uuid, f.contract.uuid)
        let agreement = try f.contract.agreement.publicDescriptorSnapshot()
        agreement.duration = 7200
        let renewal = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: now, targetCellUUID: f.cell.uuid)
        let decision = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: id, approve: true, contract: renewal)), requester: f.owner)
        XCTAssertEqual(field("status", decision), .string("approved"))
        // Renewal is retrievable without active membership, including on cold decode.
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: JSONEncoder().encode(f.cell))
        restored.authorizationClock = { now }
        let result = try CorrespondenceCellCodec.decode(try await restored.get(keypath: "join.result." + id,
            requester: requester), as: CorrespondenceJoinResult.self)
        let latest = try XCTUnwrap(result.contract)
        XCTAssertEqual(latest.uuid, renewal.uuid)
        XCTAssertEqual(latest.agreement.uuid, f.contract.agreement.uuid)
        let verified = await latest.verifyCryptographicSignature()
        XCTAssertTrue(verified)
        let stillOld = await restored.currentAuthorizationSnapshot()
        XCTAssertEqual(stillOld.contracts.map(\.uuid), [f.contract.uuid])
        let accepted = try await restored.set(keypath: "agreement.accept",
            value: CorrespondenceCellCodec.encode(latest), requester: requester)
        XCTAssertEqual(field("status", accepted), .string("accepted"))
        let after = await restored.currentAuthorizationSnapshot()
        XCTAssertEqual(after.contracts.map(\.uuid), [renewal.uuid])
        XCTAssertEqual(after.members.count, before.members.count)
        _ = try await restored.state(requester: requester)
        let outsider = await identity(EphemeralIdentityVault())
        let hidden = try await restored.get(keypath: "join.result." + id, requester: outsider)
        XCTAssertEqual(hidden, .null)
        if signingOnly { XCTAssertNil(requester.publicKeyAgreementSecureKey) }
    }

    func testJoinRenewalAfterExpiryReplacesContractAndSurvivesDecode() async throws {
        try await verifyExpiredJoinRenewal(signingOnly: false)
    }

    func testSignOnlyBridgeRequesterRenewsAfterExpiryAndAcceptsLatestResult() async throws {
        try await verifyExpiredJoinRenewal(signingOnly: true)
    }

    func testJoinRenewalRejectsReplayOlderKeysGrantsCellAndAgreementChanges() async throws {
        let f = try await fixture(admit: false)
        let requester = try signOnly(f.invitee, vault: f.i)
        let id = try await join(f, requester: requester)
        let now = Date(timeIntervalSince1970: f.contract.expiresAt + 1)
        f.cell.authorizationClock = { now }
        let other = await identity(EphemeralIdentityVault())
        for scenario in 0..<12 {
            let agreement = try f.contract.agreement.publicDescriptorSnapshot()
            agreement.duration = 7200
            var subject = f.invitee.publicIdentitySnapshot()
            var issuedAt = now
            var cellUUID = f.cell.uuid
            var issuer = f.owner
            var approve = true
            switch scenario {
            case 0: break // exact original decision replay below
            case 1: issuedAt = Date(timeIntervalSince1970: f.contract.issuedAt - 1)
            case 2: issuedAt = Date(timeIntervalSince1970: f.contract.issuedAt) // equal issuance, later expiry
            case 3: agreement.duration = 1 // newer issuance, earlier expiry
                issuedAt = Date(timeIntervalSince1970: f.contract.issuedAt + 1)
            case 4: subject.publicSecureKey = other.publicSecureKey
                agreement.signatories = [f.owner.publicIdentitySnapshot(), subject]
            case 5: subject.publicKeyAgreementSecureKey = other.publicKeyAgreementSecureKey
                agreement.signatories = [f.owner.publicIdentitySnapshot(), subject]
            case 6: agreement.addGrant("-w--", for: "members")
            case 7: cellUUID = UUID().uuidString
            case 8: agreement.uuid = UUID().uuidString
            case 9: issuer = other
            case 10: approve = false
            default: agreement.signatories[0].publicKeyAgreementSecureKey = other.publicKeyAgreementSecureKey
            }
            // Keep freshness-only failures active so expiry cannot mask them.
            let testNow = scenario <= 3 ? Date(timeIntervalSince1970: f.contract.issuedAt + 1.5) : now
            f.cell.authorizationClock = { testNow }
            let candidate = scenario == 0 ? f.contract : try await Contract.signed(agreement: agreement,
                issuer: issuer, subject: subject, domain: f.cell.identityDomain, issuedAt: issuedAt,
                targetCellUUID: cellUUID)
            let response = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
                CorrespondenceJoinDecision(requestID: id, approve: approve, contract: approve ? candidate : nil)), requester: f.owner)
            XCTAssertEqual(field("status", response), .string("rejected"), "scenario \(scenario)")
            let result = try CorrespondenceCellCodec.decode(try await f.cell.get(keypath: "join.result." + id,
                requester: requester), as: CorrespondenceJoinResult.self)
            XCTAssertEqual(result.contract?.uuid, f.contract.uuid, "scenario \(scenario)")
            let snapshot = await f.cell.currentAuthorizationSnapshot()
            XCTAssertEqual(snapshot.contracts.count, 1)
        }
    }

    func testJoinRenewalRejectsFreshSignatureAfterRevocationAndDecode() async throws {
        let f = try await fixture(admit: false)
        let requester = try signOnly(f.invitee, vault: f.i)
        let id = try await join(f, requester: requester)
        let cutoff = Date(timeIntervalSince1970: f.contract.issuedAt + 1)
        f.cell.authorizationClock = { cutoff }
        let revocation = try await ContractRevocation.signed(contract: f.contract, owner: f.owner, at: cutoff)
        let revoked = await f.cell.acceptExternallySignedRevocation(revocation)
        XCTAssertTrue(revoked)
        let now = cutoff.addingTimeInterval(1)
        let agreement = try f.contract.agreement.publicDescriptorSnapshot()
        agreement.duration = 7200
        let renewal = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: now, targetCellUUID: f.cell.uuid)
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: JSONEncoder().encode(f.cell))
        for cell in [f.cell, restored] {
            cell.authorizationClock = { now }
            let response = try await cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
                CorrespondenceJoinDecision(requestID: id, approve: true, contract: renewal)), requester: f.owner)
            XCTAssertEqual(field("status", response), .string("rejected"))
            let result = try CorrespondenceCellCodec.decode(try await cell.get(keypath: "join.result." + id,
                requester: requester), as: CorrespondenceJoinResult.self)
            XCTAssertEqual(result.contract?.uuid, f.contract.uuid)
            do { _ = try await cell.state(requester: requester); XCTFail("Revoked member read history") }
            catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        }
    }

    func testPendingDecisionCannotRenewAcrossConcurrentApprovalAndRevocation() async throws {
        let f = try await fixture(admit: false)
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid,
            owner: f.owner, expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let receipt = try CorrespondenceCellCodec.decode(try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: f.invitee), as: CorrespondenceJoinResult.self)
        let now = Date(timeIntervalSince1970: f.contract.issuedAt + 3)
        f.cell.authorizationClock = { now }
        let agreement = try f.contract.agreement.publicDescriptorSnapshot()
        agreement.duration = 7200
        let late = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: Date(timeIntervalSince1970: f.contract.issuedAt + 2), targetCellUUID: f.cell.uuid)
        let pause = Pause(), entered = expectation(description: "Pending approval validated before commit")
        f.cell.beforeJoinDecisionCommitForTesting = { await pause.stop(entered) }
        async let delayed = f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: receipt.requestID, approve: true, contract: late)), requester: f.owner)
        await fulfillment(of: [entered], timeout: 5)
        f.cell.beforeJoinDecisionCommitForTesting = nil
        let approved = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: receipt.requestID, approve: true, contract: f.contract)), requester: f.owner)
        XCTAssertEqual(field("status", approved), .string("approved"))
        let admitted = await f.cell.acceptExternallySignedAgreement(f.contract, for: f.invitee)
        XCTAssertEqual(admitted, .signed)
        let revocation = try await ContractRevocation.signed(contract: f.contract, owner: f.owner,
            at: Date(timeIntervalSince1970: f.contract.issuedAt + 1))
        let revoked = await f.cell.acceptExternallySignedRevocation(revocation)
        XCTAssertTrue(revoked)
        await pause.resume()
        let response = try await delayed
        XCTAssertEqual(field("status", response), .string("rejected"))
        let result = try CorrespondenceCellCodec.decode(try await f.cell.get(keypath: "join.result." + receipt.requestID,
            requester: f.invitee), as: CorrespondenceJoinResult.self)
        XCTAssertEqual(result.contract?.uuid, f.contract.uuid)
    }

    func testJoinLedgerRenewalIgnoresInvitationExpiryAndRejectsLateReplay() async throws {
        let f = try await fixture(admit: false)
        let base = Date()
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid,
            owner: f.owner, issuedAt: base, expiresAt: base.addingTimeInterval(1))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee, at: base)
        let ledger = CorrespondenceJoinLedger()
        let receipt = ledger.insert(request, now: base)
        XCTAssertEqual(ledger.decide(CorrespondenceJoinDecision(requestID: receipt.requestID,
            approve: true, contract: f.contract), now: base)?.status, "approved")
        let now = Date(timeIntervalSince1970: f.contract.expiresAt + 2)
        let agreement = try f.contract.agreement.publicDescriptorSnapshot()
        agreement.duration = 7200
        let earlier = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: now.addingTimeInterval(-1), targetCellUUID: f.cell.uuid)
        let newer = try await Contract.signed(agreement: agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: now, targetCellUUID: f.cell.uuid)
        let latest = CorrespondenceJoinDecision(requestID: receipt.requestID, approve: true, contract: newer)
        XCTAssertEqual(ledger.decide(latest, now: now)?.status, "approved")
        XCTAssertNil(ledger.decide(latest, now: now))
        XCTAssertNil(ledger.decide(CorrespondenceJoinDecision(requestID: receipt.requestID,
            approve: true, contract: earlier), now: now))
        XCTAssertEqual(ledger.result(id: receipt.requestID, requester: f.invitee, now: now)?.contract?.uuid, newer.uuid)
        XCTAssertTrue(ledger.pending(now: now).isEmpty)
    }

    func testSignOnlyBridgeRequesterJoinsAcceptsAndReadsEncryptedMessage() async throws {
        let f = try await fixture(admit: false)
        let requester = try signOnly(f.invitee, vault: f.i)
        let otherVault = EphemeralIdentityVault()
        let other = await identity(otherVault)
        let conflicting = try signOnly(f.invitee, vault: f.i)
        conflicting.publicKeyAgreementSecureKey = other.publicKeyAgreementSecureKey
        let rejected = await f.cell.acceptExternallySignedAgreement(f.contract, for: conflicting)
        XCTAssertEqual(rejected, .rejected)
        _ = try await join(f, requester: requester)
        let id = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e)
        let opened = try await read(f, id: id, recipient: requester, sender: f.owner, vault: f.i)
        XCTAssertEqual(opened.inner.content, "synthetic-body")
        let replyID = try await send(f, sender: f.invitee, recipient: f.owner, vault: f.i, requester: requester)
        let reply = try await read(f, id: replyID, recipient: f.owner, sender: f.invitee, vault: f.e)
        XCTAssertEqual(reply.inner.content, "synthetic-body")
        XCTAssertNil(requester.publicKeyAgreementSecureKey)
    }

    func testSignOnlyBridgeRequesterRejectsAlteredJoinProofsAndResultSigner() async throws {
        let f = try await fixture(admit: false)
        let requester = try signOnly(f.invitee, vault: f.i)
        let otherVault = EphemeralIdentityVault()
        let other = await identity(otherVault)
        let otherRequester = try signOnly(other, vault: otherVault)
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid,
            owner: f.owner, expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        var alteredKey = request
        alteredKey.agreementPublicKey = try XCTUnwrap(other.publicKeyAgreementSecureKey?.compressedKey)
        var alteredUUID = request
        alteredUUID.identityUUID = other.uuid
        var unsigned = request
        unsigned.signature = nil
        let wrongInvitation = try await CorrespondenceJoinInvitation.signed(cellUUID: UUID().uuidString,
            owner: f.owner, expiresAt: Date().addingTimeInterval(3600))
        let wrongCell = try await CorrespondenceJoinRequest.signed(invitation: wrongInvitation, invitee: f.invitee)
        // A genuine different signer copying the claimed UUID/key cannot sign for I.
        var otherSigned = request
        otherSigned.signature = try await other.sign(data: otherSigned.canonicalPayloadData())
        for bad in [alteredKey, alteredUUID, unsigned, wrongCell, otherSigned] {
            let response = try await f.cell.set(keypath: "join.request",
                value: CorrespondenceCellCodec.encode(bad), requester: requester)
            XCTAssertEqual(field("status", response), .string("rejected"))
        }
        let foreignResponse = try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: otherRequester)
        XCTAssertEqual(field("code", foreignResponse), .string("join.proof.invalid"))
        let conflicting = try signOnly(f.invitee, vault: f.i)
        conflicting.publicKeyAgreementSecureKey = other.publicKeyAgreementSecureKey
        let conflictResponse = try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: conflicting)
        XCTAssertEqual(field("code", conflictResponse), .string("join.proof.invalid"))
        let response = try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: requester)
        let receipt = try CorrespondenceCellCodec.decode(response, as: CorrespondenceJoinResult.self)
        XCTAssertEqual(receipt.status, "pending")
        let result = try await f.cell.get(keypath: "join.result." + receipt.requestID, requester: otherRequester)
        XCTAssertEqual(result, .null)
        let forged = Identity(f.invitee.uuid, displayName: "", identityVault: otherVault)
        forged.publicSecureKey = other.publicSecureKey
        let forgedResult = try await f.cell.get(keypath: "join.result." + receipt.requestID, requester: forged)
        XCTAssertEqual(forgedResult, .null)
    }

    func testJoinCodeGoldenAndPendingExpiry() async throws {
        XCTAssertEqual(CorrespondenceJoinCode.code(cellUUID: "00000000-0000-0000-0000-000000000001",
            invitationID: "00000000-0000-0000-0000-000000000002", signingPublicKey: Data(0..<32),
            agreementPublicKey: Data(32..<64)), "983780")
        let f = try await fixture(admit: false)
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let ledger = CorrespondenceJoinLedger()
        let receipt = ledger.insert(request, now: Date())
        let later = Date().addingTimeInterval(7200)
        XCTAssertEqual(ledger.result(id: receipt.requestID, requester: f.invitee, now: later)?.status, "expired")
        XCTAssertTrue(ledger.pending(now: later).isEmpty)
        XCTAssertEqual(ledger.decide(CorrespondenceJoinDecision(requestID: receipt.requestID, approve: true,
            contract: f.contract), now: later)?.status, "expired")
    }

    func testJoinRejectionsPrivacyRestartAndFlow() async throws {
        let f = try await fixture(admit: false)
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let ownerEvent = expectation(description: "Owner receives join.requested")
        let token = try await f.cell.flow(requester: f.owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            if event.title == "join.requested" { ownerEvent.fulfill() }
        })
        defer { token.cancel() }
        do { _ = try await f.cell.flow(requester: f.invitee); XCTFail("Nonmember received Flow") } catch { XCTAssertTrue(error is StreamState) }
        var invalid = request; invalid.agreementPublicKey = Data(repeating: 7, count: 32)
        let bad = try await f.cell.set(keypath: "join.request", value: CorrespondenceCellCodec.encode(invalid), requester: f.invitee)
        XCTAssertEqual(field("code", bad), .string("join.proof.invalid"))
        let submitted = try await f.cell.set(keypath: "join.request", value: CorrespondenceCellCodec.encode(request), requester: f.invitee)
        let id = try CorrespondenceCellCodec.decode(submitted, as: CorrespondenceJoinResult.self).requestID
        await fulfillment(of: [ownerEvent], timeout: 2)
        let replay = try await f.cell.set(keypath: "join.request", value: CorrespondenceCellCodec.encode(request), requester: f.invitee)
        XCTAssertEqual(field("code", replay), .string("invitation.used"))
        let other = await identity(EphemeralIdentityVault())
        let otherResult = try await f.cell.get(keypath: "join.result." + id, requester: other)
        XCTAssertEqual(otherResult, .null)
        let differentVault = EphemeralIdentityVault()
        var sameUUID = Identity(f.invitee.uuid, displayName: f.invitee.uuid, identityVault: differentVault)
        await differentVault.addIdentity(identity: &sameUUID, for: UUID().uuidString)
        let hasProof = await f.cell.verifyRequesterIdentityControl(sameUUID)
        XCTAssertTrue(hasProof)
        let sameUUIDResult = try await f.cell.get(keypath: "join.result." + id, requester: sameUUID)
        XCTAssertEqual(sameUUIDResult, .null)

        do {
            _ = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
                CorrespondenceJoinDecision(requestID: id, approve: true, contract: f.contract)), requester: f.owner.publicIdentitySnapshot())
            XCTFail("Host approved without owner proof")
        } catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        let namedAgreement = CorrespondenceAgreementTemplates.withAttachments(owner: f.owner.publicIdentitySnapshot())
        namedAgreement.state = .signed; namedAgreement.duration = 3600
        namedAgreement.signatories = [f.owner.publicIdentitySnapshot(), f.invitee.publicIdentitySnapshot()]
        namedAgreement.name = "synthetic-contact-label"
        let namedContract = try await Contract.signed(agreement: namedAgreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain, targetCellUUID: f.cell.uuid)
        let namedDecision = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: id, approve: true, contract: namedContract)), requester: f.owner)
        XCTAssertEqual(field("status", namedDecision), .string("rejected"))
        let denied = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: id, approve: false)), requester: f.owner)
        XCTAssertEqual(field("status", denied), .string("denied"))
        let snapshot = try JSONEncoder().encode(f.cell)
        let json = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        XCTAssertFalse(json.contains("privateKey\":true"))
        XCTAssertFalse(json.contains("displayName"))
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: snapshot)
        let result = try await restored.get(keypath: "join.result." + id, requester: f.invitee)
        XCTAssertEqual(field("status", result), .string("denied"))
        let restoredReplay = try await restored.set(keypath: "join.request", value: CorrespondenceCellCodec.encode(request), requester: f.invitee)
        XCTAssertEqual(field("code", restoredReplay), .string("invitation.used"))
        let expired = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            issuedAt: Date().addingTimeInterval(-100), expiresAt: Date().addingTimeInterval(-1))
        let expiredRequest = try await CorrespondenceJoinRequest.signed(invitation: expired, invitee: f.invitee)
        let expiredResult = try await f.cell.set(keypath: "join.request", value: CorrespondenceCellCodec.encode(expiredRequest), requester: f.invitee)
        XCTAssertEqual(field("code", expiredResult), .string("invitation.expired"))
    }

    func testJoinFlowIsBoundToKeyAndRecipient() async throws {
        let f = try await fixture()
        let ownerRequested = expectation(description: "Owner gets requested")
        let memberDecided = expectation(description: "Requesting member gets decided")
        let wrongKeyDecision = expectation(description: "Old key does not receive new-key decision")
        wrongKeyDecision.isInverted = true
        let memberRequested = expectation(description: "Member does not see owner's request")
        memberRequested.isInverted = true
        let ownerDecided = expectation(description: "Owner does not see member's decision")
        ownerDecided.isInverted = true
        let ownerToken = try await f.cell.flow(requester: f.owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            if event.title == "join.requested" { ownerRequested.fulfill() }
            if event.title == "join.decided" { ownerDecided.fulfill() }
        })
        var wrongID = ""
        let lock = NSLock()
        let memberToken = try await f.cell.flow(requester: f.invitee).sink(receiveCompletion: { _ in }, receiveValue: { event in
            if event.title == "join.requested" { memberRequested.fulfill() }
            if event.title == "join.decided", case .object(let fields) = event.content {
                if fields["requestID"] == .string(lock.withLock { wrongID }) { wrongKeyDecision.fulfill() }
                else { memberDecided.fulfill() }
            }
        })
        defer { ownerToken.cancel(); memberToken.cancel() }
        let invitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let request = try await CorrespondenceJoinRequest.signed(invitation: invitation, invitee: f.invitee)
        let receipt = try CorrespondenceCellCodec.decode(try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(request), requester: f.invitee), as: CorrespondenceJoinResult.self)
        _ = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: receipt.requestID, approve: false)), requester: f.owner)
        await fulfillment(of: [ownerRequested, memberDecided], timeout: 2)
        ownerToken.cancel()
        let vault = EphemeralIdentityVault()
        var otherKey = Identity(f.invitee.uuid, displayName: f.invitee.uuid, identityVault: vault)
        await vault.addIdentity(identity: &otherKey, for: UUID().uuidString)
        let secondInvitation = try await CorrespondenceJoinInvitation.signed(cellUUID: f.cell.uuid, owner: f.owner,
            expiresAt: Date().addingTimeInterval(3600))
        let secondRequest = try await CorrespondenceJoinRequest.signed(invitation: secondInvitation, invitee: otherKey)
        let secondReceipt = try CorrespondenceCellCodec.decode(try await f.cell.set(keypath: "join.request",
            value: CorrespondenceCellCodec.encode(secondRequest), requester: otherKey), as: CorrespondenceJoinResult.self)
        lock.withLock { wrongID = secondReceipt.requestID }
        _ = try await f.cell.set(keypath: "join.decide", value: CorrespondenceCellCodec.encode(
            CorrespondenceJoinDecision(requestID: secondReceipt.requestID, approve: false)), requester: f.owner)
        await fulfillment(of: [wrongKeyDecision, memberRequested, ownerDecided], timeout: 0.2)
    }

    func testTrustedHostAttachmentRootPurgesAtColdRestartWithoutMember() async throws {
        let f = try await fixture()
        let sealed = try AttachmentStreamV1.seal(plaintext: Data([1, 2, 3]))
        var request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString, agreementID: f.cell.uuid,
            senderIdentityUUID: f.owner.uuid, metadata: CorrespondenceAttachmentMetadata(name: "synthetic.bin", mediaType: "application/octet-stream", byteCount: 3), header: sealed.stream.header)
        let plan = try CorrespondenceCellCodec.decode(try await f.cell.set(keypath: "attachments.prepare",
            value: CorrespondenceCellCodec.encode(request), requester: f.owner), as: CorrespondenceAttachmentPlan.self)
        request.attachmentID = plan.attachmentID; request.chunk = sealed.stream.chunks[0]
        _ = try await f.cell.set(keypath: "attachments.upload", value: CorrespondenceCellCodec.encode(request), requester: f.owner)
        let snapshot = try JSONEncoder().encode(f.cell)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: f.storageRoot, includingPropertiesForKeys: nil))
        var index: URL?
        for case let url as URL in enumerator where url.lastPathComponent == "state.json" { index = url }
        let indexURL = try XCTUnwrap(index)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        // Edit only the offline disk image expiry, simulating elapsed time while stopped.
        func expire(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                for (key, item) in dict { dict[key] = key == "expiresAt" ? -1.0 : expire(item) }
                return dict
            }
            if let array = value as? [Any] { return array.map(expire) }
            return value
        }
        object = try XCTUnwrap(expire(object) as? [String: Any])
        try JSONSerialization.data(withJSONObject: object).write(to: indexURL)
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: snapshot)
        await restored.configureTrustedHostAttachmentStorage(root: f.storageRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.deletingLastPathComponent().appendingPathComponent(plan.attachmentID).path))
        let remaining = try Data(contentsOf: indexURL)
        XCTAssertFalse(String(decoding: remaining, as: UTF8.self).contains(plan.attachmentID))
        print("PURPOSE cold restart: trusted host root purged expired disk entry without member reconnect")
    }

    private func field(_ key: String, _ value: ValueType) -> ValueType? {
        guard case .object(let object) = value else { return nil }; return object[key]
    }
    private func send(_ f: Fixture, sender: Identity, recipient: Identity,
                      vault: EphemeralIdentityVault, attachment: CorrespondenceAttachment? = nil,
                      request: CorrespondenceAttachmentRequest? = nil, retention: Int? = nil, messageID: String? = nil, requester: Identity? = nil) async throws -> String {
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: sender, content: "synthetic-body"), subject: "synthetic-subject", clientMessageID: request?.messageID,
            cellID: f.cell.uuid, membershipFingerprint: f.cell.membershipFingerprintSnapshot,
            recipients: [recipient.publicIdentitySnapshot()], provider: vault, attachment: attachment)
        let response = try await f.cell.set(keypath: "sendMessage", value: CorrespondenceSendRequest(
            preparedEnvelope: prepared, purposeRef: "purpose://contact.communication",
            retentionSeconds: retention, messageID: request?.messageID ?? messageID, attachmentRequest: request).valueType(), requester: requester ?? sender)
        XCTAssertEqual(field("status", response), .string("stored"))
        guard case .string(let id)? = field("messageID", response) else { throw GeneralCell.KeyValueErrors.otherError }
        return id
    }
    private func read(_ f: Fixture, id: String, recipient: Identity, sender: Identity,
                      vault: EphemeralIdentityVault) async throws -> CorrespondenceOpenedEnvelope {
        let value = try await f.cell.set(keypath: "readMessage", value: .object(["messageID": .string(id)]), requester: recipient)
        let stored = try CorrespondenceCellCodec.decode(value, as: CorrespondenceStoredEnvelope.self)
        return try await CorrespondenceEnvelopeUtility.open(storedEnvelope: stored, recipient: recipient, sender: sender.publicIdentitySnapshot(), provider: vault)
    }
    private func attachment(_ f: Fixture, sender: Identity, recipient: Identity,
                            vault: EphemeralIdentityVault, receivingVault: EphemeralIdentityVault, retention: Int? = nil) async throws {
        let bytes = Data((0..<1_100_037).map { UInt8($0 % 251) })
        let sealed = try AttachmentStreamV1.seal(plaintext: bytes)
        var request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
            agreementID: sender.uuid == f.owner.uuid ? f.cell.uuid : f.contract.agreement.uuid,
            senderIdentityUUID: sender.uuid,
            metadata: CorrespondenceAttachmentMetadata(name: "synthetic.bin", mediaType: "application/octet-stream", byteCount: UInt64(bytes.count)),
            header: sealed.stream.header)
        let result = try await f.cell.set(keypath: "attachments.prepare", value: CorrespondenceCellCodec.encode(request), requester: sender)
        let plan = try CorrespondenceCellCodec.decode(result, as: CorrespondenceAttachmentPlan.self)
        request.attachmentID = plan.attachmentID
        for chunk in sealed.stream.chunks {
            request.chunk = chunk
            let response = try await f.cell.set(keypath: "attachments.upload", value: CorrespondenceCellCodec.encode(request), requester: sender)
            XCTAssertEqual(field("status", response), .string("ok"))
        }
        request.chunk = nil
        let manifest = CorrespondenceAttachment(attachmentID: plan.attachmentID, messageID: request.messageID,
            agreementID: request.agreementID, cellID: f.cell.uuid, senderIdentityUUID: sender.uuid,
            metadata: plan.metadata, mode: plan.mode, reason: plan.reason, reference: plan.reference,
            header: plan.header, contentKey: sealed.contentKey.withUnsafeBytes { Data($0) })
        let id = try await send(f, sender: sender, recipient: recipient, vault: vault, attachment: manifest, request: request, retention: retention)
        _ = try await read(f, id: id, recipient: recipient, sender: sender, vault: receivingVault)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try CorrespondenceAttachmentFileReceiver(destination: destination, attachment: manifest)
        for index in 0..<sealed.stream.chunks.count {
            request.index = UInt64(index)
            let response = try await f.cell.set(keypath: "attachments.fetch", value: CorrespondenceCellCodec.encode(request), requester: recipient)
            try receiver.append(CorrespondenceCellCodec.decode(response, as: AttachmentStreamChunk.self))
        }
        _ = try receiver.finish()
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }
    func testLocalPurposeThreeVaultsTextAttachmentsFlowRenewalAndRevocation() async throws {
        let f = try await fixture(admit: false)
        _ = try await join(f)
        print("PURPOSE E/H/I: independent vaults; host contains neither participant key")
        let delivered = expectation(description: "Unpolled encrypted delivery")
        delivered.expectedFulfillmentCount = 4
        let attachmentEvents = expectation(description: "Attachment prepare events arrive on member Flow")
        attachmentEvents.expectedFulfillmentCount = 2
        let receiptEvent = expectation(description: "Receipt arrives on member Flow")
        let revokedFeed = expectation(description: "Existing feed terminates on revocation")
        let publisher = try await f.cell.flow(requester: f.invitee)
        let subscription = publisher.sink(receiveCompletion: { completion in
            if case .failure = completion { revokedFeed.fulfill() }
        }, receiveValue: { element in
            guard case .object(let object) = element.content else { return }
            if object["event"] == .string("attachments.prepare") { attachmentEvents.fulfill(); return }
            if object["event"] == .string("message.receipt") { receiptEvent.fulfill(); return }
            guard object["event"] == .string("message.stored") else { return }
            guard let value = object["envelope"] else { XCTFail("Flow omitted encrypted envelope"); return }
            Task {
                do {
                    let stored = try CorrespondenceCellCodec.decode(value, as: CorrespondenceStoredEnvelope.self)
                    let sender = stored.outer.senderIdentityUUID == f.owner.uuid ? f.owner : f.invitee
                    let opened = try await CorrespondenceEnvelopeUtility.open(storedEnvelope: stored,
                        recipient: f.invitee, sender: sender.publicIdentitySnapshot(), provider: f.i)
                    XCTAssertEqual(opened.inner.subject, "synthetic-subject")
                    XCTAssertEqual(opened.inner.content, "synthetic-body")
                    let serialized = try JSONEncoder().encode(value)
                    XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("synthetic-body"))
                    delivered.fulfill()
                } catch { XCTFail("Flow envelope did not open: \(error)") }
            }
        })
        defer { subscription.cancel() }
        let first = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e)
        _ = try await read(f, id: first, recipient: f.invitee, sender: f.owner, vault: f.i)
        let receipt = try await f.cell.set(keypath: "ackMessage",
            value: .object(["messageID": .string(first)]), requester: f.invitee)
        XCTAssertEqual(field("status", receipt), .string("acknowledged"))
        let second = try await send(f, sender: f.invitee, recipient: f.owner, vault: f.i)
        _ = try await read(f, id: second, recipient: f.owner, sender: f.invitee, vault: f.e)
        print("PURPOSE text: owner -> invitee and invitee -> owner opened")
        try await attachment(f, sender: f.owner, recipient: f.invitee, vault: f.e, receivingVault: f.i)
        try await attachment(f, sender: f.invitee, recipient: f.owner, vault: f.i, receivingVault: f.e)
        await fulfillment(of: [delivered, attachmentEvents, receiptEvent], timeout: 5)
        let history = try await f.cell.get(keypath: "state", requester: f.invitee)
        guard case .list(let messages)? = field("messages", history) else { XCTFail("Missing member history"); return }
        XCTAssertEqual(messages.count, 4)
        print("PURPOSE attachments: 1100037 bytes each direction, byte exact; Flow delivered without inbox polling")
        let outsider = await identity(EphemeralIdentityVault())
        do { _ = try await f.cell.flow(requester: outsider); XCTFail("Nonmember received feed") } catch { XCTAssertTrue(error is StreamState) }
        do { _ = try await f.cell.state(requester: outsider); XCTFail("Nonmember read history") } catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        let renewedAgreement = try f.contract.agreement.publicDescriptorSnapshot()
        renewedAgreement.duration = 7200
        let renewal = try await Contract.signed(agreement: renewedAgreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain, targetCellUUID: f.cell.uuid)
        let renewed = await f.cell.acceptExternallySignedAgreement(renewal, for: f.invitee)
        XCTAssertEqual(renewed, .signed)
        let revocation = try await ContractRevocation.signed(contract: renewal, owner: f.owner)
        let revoked = await f.cell.acceptExternallySignedRevocation(revocation)
        XCTAssertTrue(revoked)
        await fulfillment(of: [revokedFeed], timeout: 5)
        let replay = await f.cell.acceptExternallySignedAgreement(f.contract, for: f.invitee)
        XCTAssertEqual(replay, .rejected)
        do { _ = try await f.cell.state(requester: f.invitee); XCTFail("Revoked member read history") } catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        do { _ = try await f.cell.flow(requester: f.invitee); XCTFail("Revoked member subscribed") } catch { XCTAssertTrue(error is StreamState) }
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: JSONEncoder().encode(f.cell))
        let restoredReplay = await restored.acceptExternallySignedAgreement(f.contract, for: f.invitee)
        XCTAssertEqual(restoredReplay, .rejected)
        print("PURPOSE renewal replaced old grant; signed revocation denies replay, history and Flow")
    }
    func testAdmissionRejectionsAgainstRelationshipCell() async throws {
        for scenario in 0..<12 {
            let f = try await fixture(admit: false)
            let agreement = try f.contract.agreement.publicDescriptorSnapshot()
            var issuer = f.owner
            var target: String? = f.cell.uuid
            var domain = f.cell.identityDomain
            var date = Date()
            var presenter = f.invitee
            switch scenario {
            case 0:
                let other = EphemeralIdentityVault()
                var impostor = Identity(f.owner.uuid, displayName: f.owner.uuid, identityVault: other)
                await other.addIdentity(identity: &impostor, for: "synthetic")
                issuer = impostor
            case 1: target = UUID().uuidString
            case 2: date = Date().addingTimeInterval(-7200)
            case 3: date = Date().addingTimeInterval(601)
            case 4: presenter = f.invitee.publicIdentitySnapshot()
            case 5: agreement.addGrant("-w--", for: "members")
            case 6: agreement.duration = Int(Contract.maximumDuration) + 1
            case 7: presenter = await identity(EphemeralIdentityVault())
            case 8: target = nil
            case 9: domain = "foreign-domain"
            case 10: agreement.conditions = [GrantCondition(requestedGrant: "identity.displayName", requestedPermission: "r---")]
            default: agreement.grants.removeLast()
            }
            let contract = try await Contract.signed(agreement: agreement, issuer: issuer,
                subject: f.invitee.publicIdentitySnapshot(), domain: domain, issuedAt: date, targetCellUUID: target)
            let result = await f.cell.acceptExternallySignedAgreement(contract, for: presenter)
            XCTAssertEqual(result, .rejected, "scenario \(scenario)")
            do { _ = try await f.cell.state(requester: f.invitee); XCTFail("Rejected subject read history") }
            catch { XCTAssertTrue(error is GeneralCell.KeyValueErrors) }
        }
    }

    func testUnsignedSubjectEncryptionKeySubstitutionIsRejected() async throws {
        let f = try await fixture(admit: false)
        let attacker = await identity(EphemeralIdentityVault())
        let contract = try JSONDecoder().decode(Contract.self, from: JSONEncoder().encode(f.contract))
        contract.subject.publicKeyAgreementSecureKey = attacker.publicKeyAgreementSecureKey
        let signatureStillValid = await contract.verifyCryptographicSignature()
        XCTAssertTrue(signatureStillValid, "Top-level role key is not the signed Agreement descriptor")
        let admission = await f.cell.acceptExternallySignedAgreement(contract, for: f.invitee)
        XCTAssertEqual(admission, .rejected)
    }

    func testHostAndAgentCannotSignOrApplyRevocationWithoutOwnerKey() async throws {
        let f = try await fixture()
        let hostAdmission = await f.cell.addAgreement(
            CorrespondenceAgreementTemplates.withAttachments(owner: f.cell.owner),
            for: f.invitee, authorizedBy: f.cell.owner)
        XCTAssertEqual(hostAdmission, .rejected)
        let invalid = try await ContractRevocation.signed(contract: f.contract, owner: f.invitee)
        let applied = await f.cell.acceptExternallySignedRevocation(invalid)
        XCTAssertFalse(applied)
        do { _ = try await ContractRevocation.signed(contract: f.contract, owner: f.cell.owner); XCTFail("Host signed revocation") }
        catch { XCTAssertTrue(error is IdentityVaultError || error is ContractError) }
        let id = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e)
        _ = try await read(f, id: id, recipient: f.invitee, sender: f.owner, vault: f.i)
    }

    private final class Clock {
        var now = Date()
    }
    func testOldExpiryTimerCannotDeleteNewEnvelopeReusingMessageID() async throws {
        let clock = Clock()
        let f = try await fixture(nowProvider: { clock.now })
        let id = UUID().uuidString
        _ = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e, retention: 1, messageID: id)
        clock.now = clock.now.addingTimeInterval(2)
        _ = try await f.cell.get(keypath: "inbox", requester: f.owner)
        _ = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e, retention: 30, messageID: id)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.cell)) as? [String: Any])
        let envelopes = try XCTUnwrap(object["storedEnvelopesByMessageID"] as? [String: Any])
        XCTAssertNotNil(envelopes[id])
        XCTAssertEqual(envelopes.count, 1)
    }

    func testParallelSendAndSnapshotRemainConsistentDuringAutomaticExpiry() async throws {
        let f = try await fixture()
        _ = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e, retention: 1)
        async let snapshotting: Void = snapshotUntilExpiry(f.cell)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<128 {
                group.addTask { _ = try await self.send(f, sender: f.owner, recipient: f.invitee, vault: f.e) }
            }
            try await group.waitForAll()
        }
        try await snapshotting
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.cell)) as? [String: Any])
        let envelopes = try XCTUnwrap(object["storedEnvelopesByMessageID"] as? [String: [String: Any]])
        XCTAssertEqual(envelopes.count, 128)
        let sequences = envelopes.values.compactMap { ($0["outer"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(Set(sequences).count, 128)
    }
    private func snapshotUntilExpiry(_ cell: CorrespondenceCell) async throws {
        let deadline = Date().addingTimeInterval(1.3)
        while Date() < deadline {
            _ = try JSONEncoder().encode(cell)
            await Task.yield()
        }
    }

    func testEnvelopeExpiresWithoutInboxRead() async throws {
        let f = try await fixture()
        try await attachment(f, sender: f.owner, recipient: f.invitee, vault: f.e, receivingVault: f.i, retention: 1)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.cell)) as? [String: Any])
        // Trusted fixture provisioning supplies the root; snapshots must not disclose it.
        let beforeRoot = f.storageRoot
        let beforeFiles = FileManager.default.enumerator(at: beforeRoot, includingPropertiesForKeys: nil)!
        XCTAssertTrue(beforeFiles.compactMap { $0 as? URL }.contains { $0.lastPathComponent == "0.json" })
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let serialized = try JSONEncoder().encode(f.cell)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
        let envelopes = try XCTUnwrap(object["storedEnvelopesByMessageID"] as? [String: Any])
        XCTAssertTrue(envelopes.isEmpty)
        XCTAssertNil(object["attachmentRoot"])
        let root = f.storageRoot
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let chunks = files.compactMap { $0 as? URL }.filter { $0.lastPathComponent.range(of: "^[0-9]+\\.json$", options: .regularExpression) != nil }
        XCTAssertTrue(chunks.isEmpty)
    }
    private actor Pause {
        var continuation: CheckedContinuation<Void, Never>?
        var used = false
        func stop(_ entered: XCTestExpectation) async {
            guard !used else { return }
            used = true
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }

    func testExpiredMemberIsNotEncryptionRecipient() async throws {
        let f = try await fixture()
        f.cell.authorizationClock = { Date(timeIntervalSince1970: f.contract.expiresAt + 1) }
        _ = try await f.cell.state(requester: f.owner)
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: f.owner, content: "after-expiry"), subject: "synthetic",
            cellID: f.cell.uuid, membershipFingerprint: f.cell.membershipFingerprintSnapshot,
            recipients: [], provider: f.e)
        let result = try await f.cell.set(keypath: "sendMessage", value: CorrespondenceSendRequest(
            preparedEnvelope: prepared, purposeRef: "purpose://contact.communication").valueType(), requester: f.owner)
        XCTAssertEqual(field("status", result), .string("stored"))
        let state = try await f.cell.state(requester: f.owner)
        guard case .list(let messages)? = field("messages", state) else { return XCTFail("Missing history") }
        let outer = try CorrespondenceCellCodec.decode(try XCTUnwrap(messages.first), as: CorrespondenceOuterEnvelope.self)
        let value = try await f.cell.set(keypath: "readMessage", value: .object(["messageID": .string(outer.messageID)]), requester: f.owner)
        let stored = try CorrespondenceCellCodec.decode(value, as: CorrespondenceStoredEnvelope.self)
        XCTAssertEqual(Set(stored.innerCiphertext.header.recipientKeys.compactMap(\.recipientIdentityUUID)), [f.owner.uuid])
    }

    func testAcceptRefreshCannotOverwriteConcurrentRevocation() async throws {
        let f = try await fixture(admit: false)
        let pause = Pause(), entered = expectation(description: "Accepted snapshot suspended")
        f.cell.beforeMembershipApplyForTesting = { await pause.stop(entered) }
        async let accepted = f.cell.acceptExternallySignedAgreement(f.contract, for: f.invitee)
        await fulfillment(of: [entered], timeout: 5)
        let command = try await ContractRevocation.signed(contract: f.contract, owner: f.owner)
        let revoked = await f.cell.acceptExternallySignedRevocation(command)
        XCTAssertTrue(revoked)
        let revokedFingerprint = f.cell.membershipFingerprintSnapshot
        await pause.resume()
        let admission = await accepted
        XCTAssertEqual(admission, .signed)
        XCTAssertEqual(f.cell.membershipFingerprintSnapshot, revokedFingerprint)
        f.cell.beforeMembershipApplyForTesting = nil
        _ = try await f.cell.state(requester: f.owner)
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: f.owner, content: "after-revoke"), subject: "synthetic",
            cellID: f.cell.uuid, membershipFingerprint: f.cell.membershipFingerprintSnapshot,
            recipients: [], provider: f.e)
        let result = try await f.cell.set(keypath: "sendMessage", value: CorrespondenceSendRequest(
            preparedEnvelope: prepared, purposeRef: "purpose://contact.communication").valueType(), requester: f.owner)
        XCTAssertEqual(field("status", result), .string("stored"))
    }

    func testMembershipChangeWhileSendingRejectsCommit() async throws {
        let f = try await fixture()
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: f.owner, content: "must-not-store"), subject: "synthetic",
            cellID: f.cell.uuid, membershipFingerprint: f.cell.membershipFingerprintSnapshot,
            recipients: [f.invitee.publicIdentitySnapshot()], provider: f.e)
        let payload = try CorrespondenceSendRequest(preparedEnvelope: prepared,
            purposeRef: "purpose://contact.communication").valueType()
        let pause = Pause(), entered = expectation(description: "Send awaits before commit")
        f.cell.beforeSendCommitForTesting = { await pause.stop(entered) }
        async let pending = f.cell.set(keypath: "sendMessage", value: payload, requester: f.owner)
        await fulfillment(of: [entered], timeout: 5)
        let command = try await ContractRevocation.signed(contract: f.contract, owner: f.owner)
        let revoked = await f.cell.acceptExternallySignedRevocation(command)
        XCTAssertTrue(revoked)
        await pause.resume()
        let result = try await pending
        XCTAssertEqual(field("denialReason", result), .string("membershipFingerprintMismatch"))
        let history = try await f.cell.state(requester: f.owner)
        guard case .list(let messages)? = field("messages", history) else { return XCTFail("Missing history") }
        XCTAssertTrue(messages.isEmpty)
    }

    func testRestoredRevocationAlsoAllowsFreshContract() async throws {
        let f = try await fixture()
        let command = try await ContractRevocation.signed(contract: f.contract, owner: f.owner)
        let revoked = await f.cell.acceptExternallySignedRevocation(command)
        XCTAssertTrue(revoked)
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: JSONEncoder().encode(f.cell))
        let replay = await restored.acceptExternallySignedAgreement(f.contract, for: f.invitee)
        XCTAssertEqual(replay, .rejected)
        let snapshot = await restored.currentAuthorizationSnapshot()
        let cutoff = try XCTUnwrap(snapshot.revokedBefore[f.invitee.uuid])
        restored.authorizationClock = { Date(timeIntervalSince1970: cutoff + 1) }
        let fresh = try await Contract.signed(agreement: f.contract.agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: restored.identityDomain,
            issuedAt: Date(timeIntervalSince1970: cutoff.nextUp), targetCellUUID: restored.uuid)
        let admitted = await restored.acceptExternallySignedAgreement(fresh, for: f.invitee)
        XCTAssertEqual(admitted, .signed)
        _ = try await restored.state(requester: f.invitee)
    }

    func testHostAttachmentMetadataAndProbeDoNotDiscloseNameOrPath() async throws {
        let f = try await fixture()
        let marker = "synthetic-private-filename.bin"
        let stream = try AttachmentStreamV1.seal(plaintext: Data([1]))
        var request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
            agreementID: f.cell.uuid, senderIdentityUUID: f.owner.uuid,
            metadata: .init(name: marker, mediaType: "application/octet-stream", byteCount: 1), header: stream.stream.header)
        let response = try await f.cell.set(keypath: "attachments.prepare", value: CorrespondenceCellCodec.encode(request), requester: f.owner)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains(marker))
        let plan = try CorrespondenceCellCodec.decode(response, as: CorrespondenceAttachmentPlan.self)
        XCTAssertEqual(plan.metadata.name, "")
        request.attachmentID = plan.attachmentID
        request.sourceID = "arbitrary-source"
        let sourceFile = f.storageRoot.appendingPathComponent(marker)
        try Data([1]).write(to: sourceFile)
        try await f.cell.registerAttachmentSource(id: "arbitrary-source", file: sourceFile,
            metadata: .init(name: marker, mediaType: "application/octet-stream", byteCount: 1),
            sharedReference: sourceFile, requester: f.owner)
        let probe = try await f.cell.set(keypath: "attachments.probe", value: CorrespondenceCellCodec.encode(request), requester: f.invitee)
        let text = String(decoding: try JSONEncoder().encode(probe), as: UTF8.self)
        XCTAssertFalse(text.contains("referenceURL"))
        XCTAssertFalse(text.contains(marker))
        XCTAssertEqual(field("message", probe), .string("attachmentUnavailable"))
        let snapshot = String(decoding: try JSONEncoder().encode(f.cell), as: UTF8.self)
        XCTAssertFalse(snapshot.contains("file:"))
        XCTAssertFalse(snapshot.contains("storageRoot"))
        XCTAssertFalse(snapshot.contains(marker))
    }

    func testSmallExternalClockToleranceAndRevocationCutoff() async throws {
        let f = try await fixture(admit: false)
        let now = Date()
        f.cell.authorizationClock = { now }
        let skewed = try await Contract.signed(agreement: f.contract.agreement, issuer: f.owner,
            subject: f.invitee.publicIdentitySnapshot(), domain: f.cell.identityDomain,
            issuedAt: now.addingTimeInterval(4), targetCellUUID: f.cell.uuid)
        let admitted = await f.cell.acceptExternallySignedAgreement(skewed, for: f.invitee)
        XCTAssertEqual(admitted, .signed)
        await f.cell.removeMember(uuid: f.invitee.uuid, requester: f.owner)
        let replay = await f.cell.acceptExternallySignedAgreement(skewed, for: f.invitee)
        XCTAssertEqual(replay, .rejected)
    }

    func testMembershipChangeDuringAttachmentPrepareRejectsResult() async throws {
        let f = try await fixture()
        let command = try await ContractRevocation.signed(contract: f.contract, owner: f.owner)
        f.cell.beforeAttachmentCommitForTesting = {
            let revoked = await f.cell.acceptExternallySignedRevocation(command)
            XCTAssertTrue(revoked)
        }
        let sealed = try AttachmentStreamV1.seal(plaintext: Data([1]))
        let request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
            agreementID: f.cell.uuid, senderIdentityUUID: f.owner.uuid,
            metadata: .init(name: "synthetic.bin", mediaType: "application/octet-stream", byteCount: 1), header: sealed.stream.header)
        let response = try await f.cell.set(keypath: "attachments.prepare", value: CorrespondenceCellCodec.encode(request), requester: f.owner)
        XCTAssertEqual(field("status", response), .string("error"))
        XCTAssertEqual(field("message", response), .string("attachmentUnavailable"))
    }

    func testRestoredCopyUsesHostProvisioningAndEncryptedFilename() async throws {
        let f = try await fixture()
        let bytes = Data([1, 2, 3]), sealed = try AttachmentStreamV1.seal(plaintext: Data([1, 2, 3]))
        let metadata = CorrespondenceAttachmentMetadata(name: "synthetic-encrypted-name.bin", mediaType: "application/octet-stream", byteCount: 3)
        var request = CorrespondenceAttachmentRequest(messageID: UUID().uuidString,
            agreementID: f.cell.uuid, senderIdentityUUID: f.owner.uuid,
            metadata: metadata, header: sealed.stream.header)
        let response = try await f.cell.set(keypath: "attachments.prepare", value: CorrespondenceCellCodec.encode(request), requester: f.owner)
        let plan = try CorrespondenceCellCodec.decode(response, as: CorrespondenceAttachmentPlan.self)
        request.attachmentID = plan.attachmentID
        for chunk in sealed.stream.chunks {
            request.chunk = chunk
            _ = try await f.cell.set(keypath: "attachments.upload", value: CorrespondenceCellCodec.encode(request), requester: f.owner)
        }
        request.chunk = nil
        let manifest = CorrespondenceAttachment(attachmentID: plan.attachmentID, messageID: request.messageID,
            agreementID: request.agreementID, cellID: f.cell.uuid, senderIdentityUUID: f.owner.uuid,
            metadata: metadata, mode: plan.mode, reason: plan.reason, header: plan.header,
            contentKey: sealed.contentKey.withUnsafeBytes { Data($0) })
        let id = try await send(f, sender: f.owner, recipient: f.invitee, vault: f.e, attachment: manifest, request: request)
        let opened = try await read(f, id: id, recipient: f.invitee, sender: f.owner, vault: f.i)
        XCTAssertEqual(opened.inner.attachment?.metadata.name, metadata.name)
        let snapshot = try JSONEncoder().encode(f.cell)
        XCTAssertFalse(String(decoding: snapshot, as: UTF8.self).contains(metadata.name))
        let restored = try JSONDecoder().decode(CorrespondenceCell.self, from: snapshot)
        try await restored.configureAttachmentStorage(root: f.storageRoot, requester: f.owner)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let receiver = try CorrespondenceAttachmentFileReceiver(destination: destination, attachment: manifest)
        for index in sealed.stream.chunks.indices {
            request.index = UInt64(index)
            let chunk = try await restored.set(keypath: "attachments.fetch", value: CorrespondenceCellCodec.encode(request), requester: f.invitee)
            try receiver.append(CorrespondenceCellCodec.decode(chunk, as: AttachmentStreamChunk.self))
        }
        _ = try receiver.finish()
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

}
