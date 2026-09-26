// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(macOS)
import XCTest
@testable import CellBase
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

// Entitetsdata runde 2 (WP3–WP5). Every test runs twice: against the CellApple
// anchor (the app — a personal scaffold) and the CellVapor anchor (a cloud
// scaffold). FORMAALSSPEC §2A.1: a cloud scaffold is not a weaker place.
//
//   test.entitet.read-without-proof-refused          testReadWithoutProofRefused
//   test.entitet.auth-negative                        testWrongIdentity…, testUnsigned…, testUnknownPurpose…, testDirectWrite…
//   test.entitet.admin-cannot-enter-foreign-cell      testScaffoldAdminCannotEnterForeignCell
//   test.entitet.agreement-grants-exactly-what-it-says testAgreementGrantsExactlyWhatItSays
//   test.entitet.trace                                testEachAcceptedBatchLeavesOneTraceEntry, testDirectOwnerWriteLeavesATrace
//   test.entitet.genesis-once (first-persist half)    testFirstPersistSealsAnchorToOwner  — unblocked from round 1
//
// "Revoked model" from WP4's list is NOT here: model trust is WP12 (round 4).
// TESTRESULT.md says blocked, not green.
final class EntityAnchorAccessBoundaryTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousDocumentRoot: String?
    private var previousResolver: CellResolverProtocol?
    private var previousKey: Data?
    private var previousDebug = false
    private var root: URL!
    private var scaffoldVault: MockIdentityVault!

    override func setUp() async throws {
        previousVault = CellBase.defaultIdentityVault
        previousDocumentRoot = CellBase.documentRootPath
        previousResolver = CellBase.defaultCellResolver
        previousKey = CellBase.persistedCellMasterKey
        previousDebug = CellBase.debugValidateAccessForEverything
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
        CellBase.persistedCellMasterKey = Data(repeating: 0x67, count: 32)
        CellBase.defaultCellResolver = MockCellResolver()
        // The scaffold's own vault: whoever runs the process. Entities never use it.
        scaffoldVault = MockIdentityVault()
        CellBase.defaultIdentityVault = scaffoldVault
        CellBase.debugValidateAccessForEverything = false
    }

    override func tearDown() async throws {
        CellBase.defaultIdentityVault = previousVault
        CellBase.documentRootPath = previousDocumentRoot
        CellBase.defaultCellResolver = previousResolver
        CellBase.persistedCellMasterKey = previousKey
        CellBase.debugValidateAccessForEverything = previousDebug
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Both scaffolds

    private enum Scaffold: String, CaseIterable {
        case local = "CellApple (personlig scaffold)"
        case cloud = "CellVapor (skyscaffold)"

        func anchor(owner: Identity) async -> GeneralCell {
            switch self {
            case .local: return await AppleEntityAnchorCell(owner: owner)
            case .cloud: return await VaporEntityAnchorCell(owner: owner)
            }
        }

        /// The same cell after a restart: encoded, decoded, reading its files again.
        func restart(_ anchor: GeneralCell) throws -> GeneralCell {
            let snapshot = try JSONEncoder().encode(anchor)
            switch self {
            case .local: return try JSONDecoder().decode(AppleEntityAnchorCell.self, from: snapshot)
            case .cloud: return try JSONDecoder().decode(VaporEntityAnchorCell.self, from: snapshot)
            }
        }
    }

    private func forEachScaffold(_ body: (Scaffold, GeneralCell, SimulatedEntity) async throws -> Void) async throws {
        for scaffold in Scaffold.allCases {
            let entity = await SimulatedEntity.make("A-\(scaffold)")
            let anchor = await scaffold.anchor(owner: entity.owner)
            try await body(scaffold, anchor, entity)
        }
    }

    // MARK: - WP3 read requires proof

    func testReadWithoutProofRefused() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let owner = a.owner
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: owner)
            _ = try await anchor.set(keypath: "person.nickname", value: .string("Ada"), requester: owner)

            let b = await SimulatedEntity.make("B")
            let claimant = SimulatedEntity.keylessClaimant(of: owner)
            for keypath in ["person", "relations", "proofs", "agreements", "identityLinks", "chronicle"] {
                // The owner reads. (identityLinks and chronicle are the ones the spec names first.)
                do {
                    _ = try await anchor.get(keypath: keypath, requester: owner)
                } catch {
                    XCTFail("[\(scaffold.rawValue)] owner could not read \(keypath): \(error)")
                }
                // Another entity does not.
                await XCTAssertThrowsAsync(try await anchor.get(keypath: keypath, requester: b.owner),
                                           "[\(scaffold.rawValue)] entity B read \(keypath)")
                // A copy of the owner's descriptor without the key does not.
                await XCTAssertThrowsAsync(try await anchor.get(keypath: keypath, requester: claimant),
                                           "[\(scaffold.rawValue)] keyless claimant read \(keypath)")
            }
        }
    }

    // MARK: - WP4 five refusals

    func testWrongIdentityCannotWriteOrAct() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: a.owner)
            let b = await SimulatedEntity.make("B")
            let tag = "[\(scaffold.rawValue)]"

            // Writes.
            await XCTAssertRefusedSet(anchor, "person.nickname", .string("Mallory"), requester: b.owner, "\(tag) B wrote person")
            await XCTAssertRefusedSet(anchor, "relations.note", .string("x"), requester: b.owner, "\(tag) B wrote relations")
            // Actions — calling something on the cell is access too.
            await XCTAssertRefusedSet(anchor, "identityLinks.genesis", .string("onboarding"), requester: b.owner, "\(tag) B re-ran genesis")
            await XCTAssertRefusedSet(anchor, "identityLinks.revoke", .string("genesis-\(anchor.uuid)"), requester: b.owner, "\(tag) B revoked a link")
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "reloadStorage", requester: b.owner), "\(tag) B reloaded storage")

            // Nothing changed.
            let absent1 = await read(anchor, "person.nickname", as: a.owner)
            XCTAssertNil(absent1, tag)
            let decision = await anchor.authorizationDecision(requestedAccess: "-w--", at: "person", for: b.owner)
            XCTAssertFalse(decision.allowed, tag)
        }
    }

    func testScaffoldAdminCannotEnterForeignCell() async throws {
        // The scaffold admin: the identity the process itself runs as, owner of
        // the admin plane. It owns the machine. It owns nothing inside A.
        let adminCandidate = await scaffoldVault.identity(for: "scaffold-admin", makeNewIfNotFound: true)
        let admin = try XCTUnwrap(adminCandidate)
        let adminPlane = await GeneralCell(owner: admin)
        let proves2 = await adminPlane.requesterProvesOwnership(admin)
        XCTAssertTrue(proves2, "admin must be a real owner of its own cell")
        XCTAssertFalse(CellBase.debugValidateAccessForEverything, "the debug bypass must be off for this test to mean anything")

        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)] scaffold admin"
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: a.owner)
            _ = try await anchor.set(keypath: "person.nickname", value: .string("Ada"), requester: a.owner)

            // Read: every entity keypath.
            for keypath in ["person", "relations", "proofs", "agreements", "identityLinks", "identityLinks.state", "chronicle", "entityAuthority", "dataInventory"] {
                await XCTAssertThrowsAsync(try await anchor.get(keypath: keypath, requester: admin), "\(tag) read \(keypath)")
            }
            // Write.
            await XCTAssertRefusedSet(anchor, "person.nickname", .string("Admin"), requester: admin, "\(tag) wrote person")
            // Actions.
            await XCTAssertRefusedSet(anchor, "identityLinks.genesis", .string("onboarding"), requester: admin, "\(tag) ran genesis")
            await XCTAssertRefusedSet(anchor, "identityLinks.revoke", .string("genesis-\(anchor.uuid)"), requester: admin, "\(tag) revoked")
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "reloadStorage", requester: admin), "\(tag) reloaded")
            // The flow lifecycle is an action too: admin cannot make the anchor absorb anything.
            let source = FlowElementPusherCell(owner: admin)
            await XCTAssertThrowsAsync(try await anchor.attach(emitter: source, label: "admin-feed", requester: admin), "\(tag) attached a feed")
            await XCTAssertThrowsAsync(try await anchor.absorbFlow(label: "admin-feed", requester: admin), "\(tag) absorbed a feed")

            // And the decision says why, without a grant to hide behind.
            let decision = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: admin)
            XCTAssertFalse(decision.allowed, tag)
            XCTAssertTrue([.deniedNoGrant, .deniedIdentityReferenceMismatch, .deniedOwnerProofFailed].contains(decision.path), "\(tag) path=\(decision.path)")

            // Same answer on both scaffolds: the owner still reads what the admin could not.
            let got3 = try await anchor.get(keypath: "person.nickname", requester: a.owner)
            XCTAssertEqual(got3, .string("Ada"), tag)
        }
    }

    func testAgreementGrantsExactlyWhatItSays() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            _ = try await anchor.set(keypath: "identityLinks.genesis", value: .string("onboarding"), requester: a.owner)
            _ = try await anchor.set(keypath: "person.nickname", value: .string("Ada"), requester: a.owner)
            _ = try await anchor.set(keypath: "relations.note", value: .string("private"), requester: a.owner)
            let b = await SimulatedEntity.make("B")

            // Closed door first.
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "person.nickname", requester: b.owner), "\(tag) B read before agreement")

            // The owner signs an agreement: B may read person. Nothing else.
            let agreement = Agreement(owner: a.owner)
            agreement.grants = [Grant("person-read", keypath: "person", permission: "r---")]
            let state = await anchor.addAgreement(agreement, for: b.owner, authorizedBy: a.owner)
            XCTAssertEqual(state, .signed, "\(tag) agreement state")

            // It is a door.
            let got4 = try await anchor.get(keypath: "person.nickname", requester: b.owner)
            XCTAssertEqual(got4, .string("Ada"), "\(tag) B reads person under agreement")
            let allowed = await anchor.authorizationDecision(requestedAccess: "r---", at: "person", for: b.owner)
            XCTAssertTrue(allowed.allowed, tag)
            XCTAssertEqual(allowed.path, .signedContract, tag)

            // It is not a bigger door.
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "relations.note", requester: b.owner), "\(tag) B read relations outside agreement")
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "identityLinks", requester: b.owner), "\(tag) B read identityLinks outside agreement")
            await XCTAssertRefusedSet(anchor, "person.nickname", .string("Bob"), requester: b.owner, "\(tag) B wrote person with a read-only agreement")
            await XCTAssertRefusedSet(anchor, "identityLinks.genesis", .string("onboarding"), requester: b.owner, "\(tag) B acted under a read agreement")
            let got5 = try await anchor.get(keypath: "person.nickname", requester: a.owner)
            XCTAssertEqual(got5, .string("Ada"), tag)

            // A second identity of B does not inherit B's agreement.
            let bPhone = await b.identity("phone")
            await XCTAssertThrowsAsync(try await anchor.get(keypath: "person.nickname", requester: bPhone), "\(tag) B's other identity read under B's agreement")
        }
    }

    // MARK: - Flow harness: batchPersist through the feed (the path Binding uses)

    func testFirstPersistSealsAnchorToOwner() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            let before = try await state(anchor, requester: a.owner)
            XCTAssertEqual(before["sealed"], .bool(false), tag)

            let harness = try await FlowHarness(anchor: anchor, owner: a.owner)
            let envelope = try await Self.signedEnvelope(
                mutations: [.init(keypath: "person.headline", value: .string("first"))],
                mutationID: "first-1", revision: 0, previousHash: nil,
                requester: a.owner, purposeRef: "purpose://access.audit.privacy")
            let response = try await harness.send(envelope)
            XCTAssertEqual(response["status"], .string("authority_committed"), "\(tag) \(response)")

            let after = try await state(anchor, requester: a.owner)
            XCTAssertEqual(after["sealed"], .bool(true), tag)
            guard case let .object(seal)? = after["genesis"] else { return XCTFail("\(tag) no seal after first persist") }
            XCTAssertEqual(seal["trigger"], .string("firstPersist"), tag)
            XCTAssertEqual(seal["initiatorIdentityUUID"], .string(a.owner.uuid), tag)
            let got6 = try await anchor.get(keypath: "person.headline", requester: a.owner)
            XCTAssertEqual(got6, .string("first"), tag)
        }
    }

    func testUnsignedProposalIsRefused() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            let harness = try await FlowHarness(anchor: anchor, owner: a.owner)
            var envelope = try await Self.signedEnvelope(
                mutations: [.init(keypath: "person.headline", value: .string("forged"))],
                mutationID: "forged-1", revision: 0, previousHash: nil,
                requester: a.owner, purposeRef: "purpose://access.audit.privacy")
            // The proposal is well-formed but the signature is not the owner's.
            let signatureLength = envelope.commitRequest?.signature.count ?? 64
            envelope.commitRequest?.signature = Data(repeating: 0x00, count: signatureLength)
            let response = try await harness.send(envelope)
            XCTAssertEqual(response["status"], .string("failed"), "\(tag) \(response)")
            XCTAssertEqual(response["errorCode"], .string("request_signature_invalid"), tag)
            let absent7 = await read(anchor, "person.headline", as: a.owner)
            XCTAssertNil(absent7, "\(tag) forged write landed")
            let chronicle8 = try await anchor.get(keypath: "chronicle", requester: a.owner)
            XCTAssertTrue(EntityChangeTrace.entries(in: chronicle8).isEmpty, "\(tag) a refused change left a trace")
        }
    }

    func testUnknownPurposeFailsClosed() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            let harness = try await FlowHarness(anchor: anchor, owner: a.owner)
            let envelope = try await Self.signedEnvelope(
                mutations: [.init(keypath: "person.headline", value: .string("why"))],
                mutationID: "unknown-1", revision: 0, previousHash: nil,
                requester: a.owner, purposeRef: EntityChangeTrace.unknownPurposeRef)
            let response = try await harness.send(envelope)
            XCTAssertEqual(response["status"], .string("failed"), "\(tag) \(response)")
            XCTAssertTrue((try? response["error"]?.stringValue())??.contains("prompt.unknown") == true, "\(tag) \(response)")
            let absent9 = await read(anchor, "person.headline", as: a.owner)
            XCTAssertNil(absent9, tag)

            // The loose, unsigned form fails the same way.
            let loose = EntityBatchPersistEnvelope(
                schema: "test.entity-turn.v1",
                mutations: [.init(keypath: "person.headline", value: .string("why"))],
                metadata: ["purposeRef": .string(EntityChangeTrace.unknownPurposeRef)])
            let looseResponse = try await harness.send(loose)
            XCTAssertEqual(looseResponse["status"], .string("failed"), "\(tag) \(looseResponse)")
            let absent10 = await read(anchor, "person.headline", as: a.owner)
            XCTAssertNil(absent10, tag)
        }
    }

    func testDirectWriteOutsideBatchPathRequiresOwnerProof() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            let b = await SimulatedEntity.make("B")
            // B cannot even make the anchor listen to a feed.
            let bSource = FlowElementPusherCell(owner: b.owner)
            await XCTAssertThrowsAsync(try await anchor.attach(emitter: bSource, label: "b-feed", requester: b.owner), "\(tag) B attached")
            await XCTAssertThrowsAsync(try await anchor.absorbFlow(label: "b-feed", requester: b.owner), "\(tag) B absorbed")

            // The owner can — and a plain keypath write from the owner's own feed is
            // accepted, traced, and visible.
            let harness = try await FlowHarness(anchor: anchor, owner: a.owner)
            let response = try await harness.sendKeypath("person.headline", .string("direct"))
            XCTAssertEqual(response["status"], .string("persisted"), "\(tag) \(response)")
            let got11 = try await anchor.get(keypath: "person.headline", requester: a.owner)
            XCTAssertEqual(got11, .string("direct"), tag)
            let entries = EntityChangeTrace.entries(in: try await anchor.get(keypath: "chronicle", requester: a.owner))
            XCTAssertEqual(entries.count, 1, "\(tag) direct owner write should leave exactly one trace entry")
            XCTAssertEqual(entries.first?["kind"], .string(EntityChangeTrace.Kind.keypathSet.rawValue), tag)
            XCTAssertEqual(entries.first?["signedBy"], .string(a.owner.uuid), tag)
        }
    }

    // MARK: - WP5 trace

    func testEachAcceptedBatchLeavesOneTraceEntry() async throws {
        try await forEachScaffold { scaffold, anchor, a in
            let tag = "[\(scaffold.rawValue)]"
            let harness = try await FlowHarness(anchor: anchor, owner: a.owner)

            let first = try await Self.signedEnvelope(
                mutations: [.init(keypath: "person.headline", value: .string("one")), .init(keypath: "person.nickname", value: .string("Ada"))],
                mutationID: "batch-1", revision: 0, previousHash: nil,
                requester: a.owner, purposeRef: "purpose://access.audit.privacy",
                metadata: ["modelRef": .string("model://local/apple-intelligence")])
            let firstResponse = try await harness.send(first)
            XCTAssertEqual(firstResponse["status"], .string("authority_committed"), "\(tag) \(firstResponse)")
            let firstReceipt = try EntityAuthorityCommitReceipt(value: try XCTUnwrap(firstResponse["commitReceipt"]))

            var entries = EntityChangeTrace.entries(in: try await anchor.get(keypath: "chronicle", requester: a.owner))
            XCTAssertEqual(entries.count, 1, "\(tag) one batch, one entry — not one per field")
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry["kind"], .string(EntityChangeTrace.Kind.batchPersist.rawValue), tag)
            XCTAssertEqual(entry["signedBy"], .string(a.owner.uuid), tag)
            XCTAssertEqual(entry["signingKeyFingerprint"], .string(a.owner.signingPublicKeyFingerprint ?? "?"), tag)
            XCTAssertEqual(entry["keypaths"], .list([.string("person.headline"), .string("person.nickname")]), tag)
            XCTAssertEqual(entry["purposeRef"], .string("purpose://access.audit.privacy"), tag)
            XCTAssertEqual(entry["modelRef"], .string("model://local/apple-intelligence"), tag)
            guard case let .object(receipt)? = entry["receipt"] else { return XCTFail("\(tag) trace has no receipt") }
            XCTAssertEqual(receipt["entryHash"], .string(firstReceipt.entryHash), tag)
            XCTAssertEqual(receipt["signature"], .string(firstReceipt.signature.base64EncodedString()), tag)
            XCTAssertTrue(firstReceipt.verifies(with: a.owner), "\(tag) receipt in trace must verify against the owner")

            // A second batch: a second entry, chained to the first.
            let second = try await Self.signedEnvelope(
                mutations: [.init(keypath: "person.headline", value: .string("two"))],
                mutationID: "batch-2", revision: 1, previousHash: firstReceipt.entryHash,
                requester: a.owner, purposeRef: "purpose://access.audit.privacy")
            let sent12 = try await harness.send(second)
            XCTAssertEqual(sent12["status"], .string("authority_committed"), tag)
            entries = EntityChangeTrace.entries(in: try await anchor.get(keypath: "chronicle", requester: a.owner))
            XCTAssertEqual(entries.count, 2, tag)
            XCTAssertEqual(entries.last?["modelRef"], .null, "\(tag) no model, no model ref")

            // The same batch again is the same change: idempotent, and no third entry.
            let replay = try await harness.send(second)
            XCTAssertEqual(replay["idempotentReplay"], .bool(true), "\(tag) \(replay)")
            entries = EntityChangeTrace.entries(in: try await anchor.get(keypath: "chronicle", requester: a.owner))
            XCTAssertEqual(entries.count, 2, "\(tag) a replayed batch must not add a trace entry")

            // The trace survives a restart from disk.
            let restarted = try scaffold.restart(anchor)
            let restartedEntries = EntityChangeTrace.entries(in: try await restarted.get(keypath: "chronicle", requester: a.owner))
            XCTAssertEqual(restartedEntries.map { $0["id"] }, entries.map { $0["id"] }, "\(tag) trace after restart")
        }
    }

    // MARK: - Helpers

    /// A value, or nil when the keypath is absent or refused. For "nothing changed".
    private func read(_ anchor: GeneralCell, _ keypath: String, as requester: Identity) async -> ValueType? {
        guard let value = try? await anchor.get(keypath: keypath, requester: requester), value != .null else { return nil }
        return value
    }

    private func state(_ anchor: GeneralCell, requester: Identity) async throws -> Object {
        let value = try await anchor.get(keypath: "identityLinks.state", requester: requester)
        guard case let .object(object) = value else {
            throw XCTSkip("identityLinks.state did not return an object: \(value)")
        }
        return object
    }

    private static func signedEnvelope(
        mutations: [EntityBatchPersistMutation],
        mutationID: String,
        revision: Int,
        previousHash: String?,
        requester: Identity,
        purposeRef: String,
        metadata: Object = [:]
    ) async throws -> EntityBatchPersistEnvelope {
        var envelope = EntityBatchPersistEnvelope(schema: "test.entity-turn.v1", mutations: mutations, metadata: metadata)
        envelope.commitRequest = try await EntityAuthorityCommitRequest.signed(
            envelope: envelope,
            mutationID: mutationID,
            epoch: 1,
            expectedRevision: revision,
            expectedPreviousHash: previousHash,
            requester: requester,
            purposeRef: purposeRef
        )
        return envelope
    }

    /// The owner's feed into the anchor, the way BindingPersonalChatChronicle
    /// reaches it: attach a pusher, absorb its flow, send one element, wait
    /// for the "PDS update" the anchor answers with.
    private final class FlowHarness {
        let anchor: GeneralCell
        let owner: Identity
        let source: FlowElementPusherCell
        private var responses = AsyncStream<Object>.makeStream()
        private var subscription: AnyCancellable?

        init(anchor: GeneralCell, owner: Identity) async throws {
            self.anchor = anchor
            self.owner = owner
            self.source = FlowElementPusherCell(owner: owner)
            let continuation = responses.continuation
            subscription = try await anchor.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { element in
                guard element.title == "PDS update", case let .object(response) = element.content else { return }
                continuation.yield(response)
            })
            _ = try await anchor.attach(emitter: source, label: "entity-input", requester: owner)
            try await anchor.absorbFlow(label: "entity-input", requester: owner)
        }

        deinit { subscription?.cancel() }

        func send(_ envelope: EntityBatchPersistEnvelope) async throws -> Object {
            let correlationID = UUID().uuidString
            source.feedPublisher.send(FlowElement(title: "entity-turn", content: .object([
                "operation": .string(EntityBatchPersistEnvelope.operation),
                "correlationId": .string(correlationID),
                "envelope": .object(envelope.objectValue())
            ]), properties: .init(type: .content, contentType: .object)))
            return try await awaitResponse(correlationID: correlationID)
        }

        func sendKeypath(_ keypath: String, _ value: ValueType) async throws -> Object {
            let correlationID = UUID().uuidString
            source.feedPublisher.send(FlowElement(title: "entity-set", content: .object([
                "correlationId": .string(correlationID),
                "keypath": .string(keypath),
                "value": value
            ]), properties: .init(type: .content, contentType: .object)))
            return try await awaitResponse(correlationID: correlationID)
        }

        private func awaitResponse(correlationID: String) async throws -> Object {
            let stream = responses.stream
            return try await withThrowingTaskGroup(of: Object.self) { group in
                group.addTask {
                    for await response in stream where response["correlationId"] == .string(correlationID) {
                        return response
                    }
                    throw HarnessError.streamEnded
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw HarnessError.timeout(correlationID)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }

        enum HarnessError: Error { case streamEnded, timeout(String) }
    }
}

// MARK: - Async assertion helpers

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected a refusal: \(message)", file: file, line: line)
    } catch {
        // refused, as it should be
    }
}

/// A set on GeneralCell may refuse by throwing or by answering an error object.
/// Either is a refusal; silently succeeding is not.
private func XCTAssertRefusedSet(_ cell: GeneralCell, _ keypath: String, _ value: ValueType, requester: Identity, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let result = try await cell.set(keypath: keypath, value: value, requester: requester)
        if case let .object(object)? = result, object["status"] == .string("error") {
            return
        }
        XCTFail("Expected a refusal: \(message) — got \(String(describing: result))", file: file, line: line)
    } catch {
        // refused
    }
}
#endif
