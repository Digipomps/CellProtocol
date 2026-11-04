// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase
import CellApple

final class RelationalSharedCellTests: XCTestCase {
    private var oldVault: IdentityVaultProtocol?
    private var oldMode: CellBase.ExploreContractEnforcementMode = .permissive
    override func setUp() { super.setUp(); oldVault = CellBase.defaultIdentityVault; oldMode = CellBase.exploreContractEnforcementMode; CellBase.exploreContractEnforcementMode = .strict }
    override func tearDown() { CellBase.defaultIdentityVault = oldVault; CellBase.exploreContractEnforcementMode = oldMode; super.tearDown() }
    private func setupCell() async -> (MockIdentityVault, Identity, RelationalLearningCell) {
        let vault = MockIdentityVault(); let owner = await vault.identity(for: "shared-learning-owner", makeNewIfNotFound: true)!
        CellBase.defaultIdentityVault = vault; return (vault, owner, await RelationalLearningCell(owner: owner))
    }
    private func feedback(_ id: String = "choice", revision: UInt64 = 0) throws -> ValueType {
        .object(try RelationalLearningCodec.encodeObject(RelationalUserFeedbackEvent(eventId: id, timestamp: 100,
            expectedJournalRevision: revision, sessionId: "s", episodeId: id, purposeId: "p", kind: .purposeChoice,
            contextBlocks: [.init(domain: "location", blockId: "home")])))
    }
    private func status(_ value: ValueType?) -> String? { guard case let .object(o)? = value, case let .string(s)? = o["status"] else { return nil }; return s }
    private func journal(_ cell: RelationalLearningCell, _ owner: Identity) async throws -> RelationalLearningPersistedJournal {
        guard case let .object(o) = try await cell.get(keypath: "journal", requester: owner) else { throw SetValueError.paramErr }
        return try RelationalLearningCodec.decode(RelationalLearningPersistedJournal.self, from: o)
    }
    private func agree(_ cell: RelationalLearningCell, _ owner: Identity) async throws {
        let result = try await cell.set(keypath: "versionAgreement", value: .object(["envelopeVersion": .string("2.0"), "journalVersion": .integer(2)]), requester: owner)
        XCTAssertEqual(status(result), "ok")
    }
    func testSharedConcreteTypeKeepsAppleReexportDiscoveryAndTypedArchiveName() async throws {
        let (_,owner,cell) = await setupCell()
        XCTAssertEqual(String(describing: type(of: cell)), "RelationalLearningCell")
        let descriptor = try await cell.entityAtlasDescriptor(requester: owner)
        XCTAssertTrue(descriptor.capabilityHints.contains("userFeedback"))
        var coder = CellJSONCoder(); try coder.register(name: "RelationalLearningCell", type: RelationalLearningCell.self)
        let archive = try CellJSONCoder.encodeCell(cellClassName: "RelationalLearningCell", cell: cell)
        let decoded = try await coder.decodeRuntimeReadyEmitCell(from: archive)
        XCTAssertTrue(decoded is RelationalLearningCell)
        let sourceCompatible: RelationalLearningCell = cell
        XCTAssertEqual(sourceCompatible.uuid, cell.uuid)
    }
    func testV2DefaultOffThenOwnerAgreementBeforeMutationAndDecodeRenewsAgreement() async throws {
        let (_,owner,cell) = await setupCell()
        let refused = try await cell.set(keypath: "userFeedback", value: feedback(), requester: owner)
        XCTAssertEqual(status(refused), "error")
        let empty = try await journal(cell,owner); XCTAssertEqual(empty.revision, 0)
        try await agree(cell, owner)
        let accepted = try await cell.set(keypath: "userFeedback", value: feedback(), requester: owner)
        XCTAssertEqual(status(accepted), "ok")
        let learned = try await journal(cell,owner); XCTAssertEqual(learned.revision, 1)
        let decoded = try JSONDecoder().decode(RelationalLearningCell.self, from: JSONEncoder().encode(cell))
        try await decoded.ensureRuntimeReady()
        let declined = try await decoded.set(keypath: "userFeedback", value: feedback("after-decode", revision: 1), requester: owner)
        XCTAssertEqual(status(declined), "error")
        let restored = try await journal(decoded,owner); XCTAssertEqual(restored.revision, 1)
        try await agree(decoded, owner)
        let resumed = try await decoded.set(keypath: "userFeedback", value: feedback("after-decode", revision: 1), requester: owner)
        XCTAssertEqual(status(resumed), "ok")
    }
    func testReplayAndConfigurationPreferenceCannotBypassAgreement() async throws {
        let (_,owner,cell) = await setupCell()
        guard case let .object(payload) = try feedback() else { return XCTFail("fixture") }
        let event = try RelationalLearningCodec.decode(RelationalUserFeedbackEvent.self, from: payload)
        let replay = try await cell.set(keypath: "replay", value: .object(["resetFirst": .bool(true), "events": .list([.object(try RelationalLearningCodec.encodeObject(RelationalLearningEventEnvelope.from(event)))])]), requester: owner)
        XCTAssertEqual(status(replay), "error")
        let preference = RelationalExplicitPreferenceEvent(eventId: "config-pref", timestamp: 100, purposeId: "p", relationType: .purposeConfiguration,
            targetNode: RelationalConfigurationReference(configurationUUID: "12345678-1234-4234-8234-123456789001", sourceCellEndpoint: "cell:///Synthetic").node, preferenceWeight: 0.7)
        let refused = try await cell.set(keypath: "userPreference", value: .object(try RelationalLearningCodec.encodeObject(preference)), requester: owner)
        XCTAssertEqual(status(refused), "error")
        let unchanged = try await journal(cell,owner); XCTAssertEqual(unchanged.revision, 0)
    }
    func testPrivateCandidateRestoresCanonicalJournalWithoutChangingOriginal() async throws {
        let (_,owner,cell) = await setupCell(); try await agree(cell,owner)
        _ = try await cell.set(keypath: "userFeedback", value: feedback(), requester: owner)
        let stored = try await journal(cell,owner)
        let candidate = try await RelationalLearningCell(owner: owner, restoring: stored)
        try await agree(candidate,owner)
        _ = try await candidate.set(keypath: "userFeedback", value: feedback("next", revision: 1), requester: owner)
        let original = try await journal(cell,owner), changed = try await journal(candidate,owner)
        XCTAssertEqual(original.revision, 1); XCTAssertEqual(changed.revision, 2)
    }
    func testActualAbsorbCannotInventExplicitHumanFeedbackOrForwardV2() async throws {
        let (_,owner,cell) = await setupCell()
        let source = await GeneralCell(owner: owner)
        cell.agreementTemplate.ensureGrant("rw--", for: "source")
        let attached = try await cell.attach(emitter: source, label: "source", requester: owner)
        XCTAssertEqual(attached, .connected); try await cell.absorbFlow(label: "source", requester: owner)
        guard case let .object(payload) = try feedback() else { return XCTFail("fixture") }
        let event = try RelationalLearningCodec.decode(RelationalUserFeedbackEvent.self, from: payload)
        var flow = FlowElement(title: "Untrusted assertion of human choice", content: .object(try RelationalLearningCodec.encodeObject(RelationalLearningEventEnvelope.from(event))), properties: .init(type: .event, contentType: .object)); flow.topic = "relational.learning.userFeedback"
        for round in 0..<2 {
            if round == 1 { try await agree(cell,owner) }
            let leaked = expectation(description: "V2 source input is not forwarded \(round)"); leaked.isInverted = true
            let cancellable = try await cell.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { item in if item.id == flow.id { leaked.fulfill() } })
            source.pushFlowElement(flow, requester: owner)
            await fulfillment(of: [leaked], timeout: 0.15); cancellable.cancel()
            let current = try await journal(cell,owner); XCTAssertEqual(current.revision, 0)
        }
        let context = RelationalContextTransitionEvent(eventId: "actual-source-context", timestamp: 99, domain: "location", toBlockId: "home")
        var observation = FlowElement(title: "Actual semantic context", content: .object(try RelationalLearningCodec.encodeObject(RelationalLearningEventEnvelope.from(context))), properties: .init(type: .event, contentType: .object)); observation.topic = "relational.learning.contextTransition"
        let delivered = expectation(description: "Same actual subscription consumes admissible context")
        let cancellable = try await cell.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { item in if item.id == observation.id { delivered.fulfill() } })
        source.pushFlowElement(observation, requester: owner)
        await fulfillment(of: [delivered], timeout: 2); cancellable.cancel()
        let contextJournal = try await journal(cell,owner); XCTAssertEqual(contextJournal.revision, 1)
        let humanChoice = try await cell.set(keypath: "userFeedback", value: feedback("explicit", revision: 1), requester: owner)
        XCTAssertEqual(status(humanChoice), "ok")
        await cell.detachAndWait(label: "source", requester: owner)
    }
    func testLegacyEdgesNeverLeakNewConfigurationShapesAfterRestoration() async throws {
        let (_,owner,cell) = await setupCell(); try await agree(cell,owner)
        let target = RelationalConfigurationReference(configurationUUID: "12345678-1234-4234-8234-123456789001", sourceCellEndpoint: "cell:///Synthetic")
        let event = RelationalUserFeedbackEvent(eventId: "outcome", timestamp: 100, expectedJournalRevision: 0, sessionId: "s", episodeId: "e", purposeId: "p", kind: .confirmedOutcome, configuration: target)
        _ = try await cell.set(keypath: "userFeedback", value: .object(try RelationalLearningCodec.encodeObject(event)), requester: owner)
        let decoded = try JSONDecoder().decode(RelationalLearningCell.self, from: JSONEncoder().encode(cell)); try await decoded.ensureRuntimeReady()
        for agreement in [false,true] {
            if agreement { try await agree(decoded,owner) }
            guard case let .object(result) = try await decoded.get(keypath: "edges", requester: owner), case let .list(edges)? = result["edges"] else { return XCTFail("legacy edges") }
            XCTAssertTrue(edges.isEmpty)
        }
        let utility = try await decoded.set(keypath: "scoreConfigurations", value: .object(["purposeId": .string("p"), "timestamp": .float(100)]), requester: owner)
        guard case let .object(result)? = utility, case let .list(scores)? = result["scores"] else { return XCTFail("new agreed score contract") }
        XCTAssertEqual(scores.count, 1)
    }
    func testWrongRequesterCannotAgreeOrReadPrivateJournal() async throws {
        let (vault,owner,cell) = await setupCell()
        let outsider = await vault.identity(for: "shared-outsider", makeNewIfNotFound: true)!
        try await CellContractHarness.assertSetDenied(on: cell, key: "versionAgreement", input: .object(["envelopeVersion": .string("2.0"), "journalVersion": .integer(2)]), requester: outsider)
        try await CellContractHarness.assertGetDenied(on: cell, key: "journal", requester: outsider)
        let empty = try await journal(cell,owner); XCTAssertEqual(empty.revision, 0)
    }
}
