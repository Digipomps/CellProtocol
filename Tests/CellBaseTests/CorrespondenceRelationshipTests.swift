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
    private func field(_ key: String, _ value: ValueType) -> ValueType? {
        guard case .object(let object) = value else { return nil }; return object[key]
    }
    private func send(_ f: Fixture, sender: Identity, recipient: Identity,
                      vault: EphemeralIdentityVault, attachment: CorrespondenceAttachment? = nil,
                      request: CorrespondenceAttachmentRequest? = nil, retention: Int? = nil, messageID: String? = nil) async throws -> String {
        let prepared = try await CorrespondenceEnvelopeUtility.prepare(
            message: ChatMessage(owner: sender, content: "synthetic-body"), subject: "synthetic-subject", clientMessageID: request?.messageID,
            cellID: f.cell.uuid, membershipFingerprint: f.cell.membershipFingerprintSnapshot,
            recipients: [recipient.publicIdentitySnapshot()], provider: vault, attachment: attachment)
        let response = try await f.cell.set(keypath: "sendMessage", value: CorrespondenceSendRequest(
            preparedEnvelope: prepared, purposeRef: "purpose://contact.communication",
            retentionSeconds: retention, messageID: request?.messageID ?? messageID, attachmentRequest: request).valueType(), requester: sender)
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
        let f = try await fixture()
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
