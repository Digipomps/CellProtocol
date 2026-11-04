// SPDX-License-Identifier: Apache-2.0
// Runtime contracts with real Cells/Absorb and synthetic host receipts.
// These are NOT native/web rendering acceptance evidence.
import Foundation
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase
@_spi(HAVENRuntime) @testable import CellApple

private final class RoutingClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = floor(Date().timeIntervalSince1970)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: value) }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}
private final class RoutingVisibleCatalog: @unchecked Sendable {
    private let lock = NSLock(); private var entries: [PerspectiveRoutingTarget] = []
    private var suspension: (() async -> Void)?
    func delayNext(_ body: @escaping () async -> Void) { lock.lock(); suspension = body; lock.unlock() }
    private func takeDelay() -> (() async -> Void)? { lock.lock(); defer { lock.unlock() }; let body = suspension; suspension = nil; return body }
    func read() async -> [PerspectiveRoutingTarget] { if let body = takeDelay() { await body() }; return get() }
    func get() -> [PerspectiveRoutingTarget] { lock.lock(); defer { lock.unlock() }; return entries }
    func replace(_ entries: [PerspectiveRoutingTarget]) { lock.lock(); self.entries = entries; lock.unlock() }
}
private final class RoutingSource: GeneralCell {
    private let lock = NSLock()
    private var observation = ContextObservation(revision: 0, observedAt: Date(), validUntil: Date().addingTimeInterval(3600), transition: "snapshot", labels: [])
    private var publish: ((FlowElement) -> Void)?
    required init(owner: Identity) async { await super.init(owner: owner); try? await ensureRuntimeReady() }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    private func snapshot() -> ContextObservation { lock.lock(); defer { lock.unlock() }; return observation }
    private func replace(_ value: ContextObservation) { lock.lock(); observation = value; lock.unlock() }
    override func installCellRuntimeBindingsForAccess() async throws {
        let owner = storedOwnerIdentity
        publish = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        agreementTemplate.ensureGrant("r---", for: "context.observation")
        agreementTemplate.ensureGrant("-w--", for: "test.observe")
        await registerGet(key: "context.observation", owner: owner, returns: ExploreContract.schema(type: "object"), permissions: ["r---"]) { [weak self] requester in
            guard let self, await self.validateAccess("r---", at: "context.observation", for: requester) else { return .string("denied") }
            return try! ContextCodec.encode(self.snapshot())
        }
        await registerSet(key: "test.observe", owner: owner, input: ExploreContract.schema(type: "object"), returns: ExploreContract.schema(type: "object"), permissions: ["-w--"]) { [weak self] requester, value in
            guard let self, await self.validateAccess("-w--", at: "test.observe", for: requester) else { return .string("denied") }
            do {
                let observation = try ContextCodec.decode(value, as: ContextObservation.self); self.replace(observation)
                guard case let .object(payload) = value else { return .null }
                var event = FlowElement(title: "Actual semantic source", content: .object(payload), properties: .init(type: .event, contentType: .object)); event.topic = "context.observation.changed"
                self.publish?(event); return .object(["status": .string("ok")])
            } catch { return .object(["status": .string("error")]) }
        }
    }
}
final class PerspectiveRoutingRuntimeTests: XCTestCase {
    private var oldVault: IdentityVaultProtocol?, oldResolver: CellResolverProtocol?
    private var oldRoot: String?, oldKey: Data?
    private var oldMode: CellBase.ExploreContractEnforcementMode = .permissive
    private var root: URL!
    private var owner: Identity!
    private var host: GeneralCell!
    private var runtime: PerspectiveRoutingRuntime!
    private var hostSession: PerspectiveRoutingHostSession!
    private let hostInstanceID = UUID()
    private var sourceCells: [RoutingSource] = []
    private var sourceConfigurations: [ContextSource] = []
    private let clock = RoutingClock()
    private let visibleCatalog = RoutingVisibleCatalog()
    private let target = PerspectiveRoutingTarget(reference: .init(configurationUUID: "12345678-1234-4234-8234-123456789001", sourceCellEndpoint: "cell:///SyntheticFamily"), name: "Family", purposeRefs: ["purpose://family"])
    override func setUp() async throws {
        oldVault = CellBase.defaultIdentityVault; oldResolver = CellBase.defaultCellResolver
        oldRoot = CellBase.documentRootPath; oldKey = CellBase.persistedCellMasterKey; oldMode = CellBase.exploreContractEnforcementMode
        root = FileManager.default.temporaryDirectory.appendingPathComponent("perspective-routing-contract-" + UUID().uuidString)
        CellBase.documentRootPath = root.path; CellBase.persistedCellMasterKey = Data(repeating: 0x74, count: 32); CellBase.exploreContractEnforcementMode = .strict
        let vault = MockIdentityVault(); CellBase.defaultIdentityVault = vault
        owner = await vault.identity(for: "routing-test", makeNewIfNotFound: true)!
        let resolver = CellResolver.sharedInstance; CellBase.defaultCellResolver = resolver
        host = await GeneralCell(owner: owner)
        for (domain,label) in [("location","home"),("time","morning"),("company","family")] {
            let source = await RoutingSource(owner: owner)
            try await resolver.registerNamedEmitCell(name: source.uuid, emitCell: source, scope: .scaffoldUnique, identity: owner)
            let initial = ContextObservation(revision: 1, observedAt: clock.now(), validUntil: clock.now().addingTimeInterval(3600), transition: "snapshot", labels: [label])
            _ = try await source.set(keypath: "test.observe", value: ContextCodec.encode(initial), requester: owner)
            sourceCells.append(source); sourceConfigurations.append(.init(sourceID: domain, endpoint: "cell:///" + source.uuid))
        }
        visibleCatalog.replace([target])
        let catalog = visibleCatalog, testClock = clock
        runtime = try await PerspectiveRoutingRuntime.install(on: host, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        hostSession = try await runtime.openHostSession(hostInstanceID: hostInstanceID, requester: owner)
    }
    override func tearDown() async throws {
        await runtime?.shutdown()
        if let host { await CellResolver.sharedInstance.unregisterEmitCell(uuid: host.uuid) }
        for source in sourceCells { await CellResolver.sharedInstance.unregisterEmitCell(uuid: source.uuid) }
        for source in sourceConfigurations { await host.detachAndWait(label: "routing-source:" + source.sourceID, requester: owner) }
        runtime = nil; host = nil; sourceCells = []
        CellBase.defaultIdentityVault = oldVault; CellBase.defaultCellResolver = oldResolver; CellBase.documentRootPath = oldRoot; CellBase.persistedCellMasterKey = oldKey; CellBase.exploreContractEnforcementMode = oldMode
        if let root, FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func state() async throws -> PerspectiveRoutingState {
        let response = try await host.get(keypath: "perspective.routing.state", requester: owner)
        guard case let .object(o) = response, o["status"] == .string("ok"), let value = o["state"] else { throw PerspectiveRoutingError.unavailable("bad state: \(response)") }
        return try ContextCodec.decode(value, as: PerspectiveRoutingState.self)
    }
    @discardableResult private func call<T: Encodable>(_ action: String, _ payload: T) async throws -> PerspectiveRoutingState {
        let response = try await host.set(keypath: "perspective.routing." + action, value: ContextCodec.encode(payload), requester: owner)
        guard case let .object(o)? = response, o["status"] == .string("ok"), let value = o["state"] else { throw PerspectiveRoutingError.unavailable("bad action \(action): \(String(describing: response))") }
        return try ContextCodec.decode(value, as: PerspectiveRoutingState.self)
    }
    private func configure(configurations: [RelationalConfigurationReference]? = nil) async throws -> PerspectiveRoutingState {
        try await call("configure", PerspectiveRoutingConfiguration(enabled: true, confirm: true, sources: sourceConfigurations,
            purposes: [.init(id: "purpose://family", title: "Family"), .init(id: "purpose://work", title: "Work")], configurations: configurations ?? [target.reference]))
    }
    private func feedback(_ kind: RelationalUserFeedbackKind, state: PerspectiveRoutingState, session: String, target: RelationalConfigurationReference? = nil) -> PerspectiveRoutingFeedback {
        .init(eventID: UUID().uuidString, episodeID: state.episodeID, sessionID: session, sessionProof: hostSession.proof, kind: kind, occurredAt: clock.now().timeIntervalSince1970,
              purposeRef: "purpose://family", decisionRevision: state.revision, configuration: target)
    }
    private func pulse(_ revision: Int, labels: [String] = ["home"], sourceIndex: Int = 0) async throws -> PerspectiveRoutingState {
        let before = try await state(), changed = expectation(description: "real source flow consumed")
        let feed = try await host.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.routing.changed", case let .object(payload) = event.content,
                  let state = try? ContextCodec.decode(.object(payload), as: PerspectiveRoutingState.self), state.episodeID != before.episodeID else { return }; changed.fulfill()
        })
        defer { feed.cancel() }
        let observation = ContextObservation(revision: revision, observedAt: clock.now(), validUntil: clock.now().addingTimeInterval(3600), transition: labels.isEmpty ? "left" : "entered", labels: labels)
        _ = try await sourceCells[sourceIndex].set(keypath: "test.observe", value: ContextCodec.encode(observation), requester: owner)
        await fulfillment(of: [changed], timeout: 3)
        return try await state()
    }
    private func train(_ count: Int, chosenTarget: PerspectiveRoutingTarget? = nil, startingRevision: Int = 2) async throws {
        let chosen = chosenTarget ?? target
        for index in 0..<count {
            // Three synthetic actual-host lifetimes for the contract gate. UI
            // acceptance must separately establish real app/browser lifetimes.
            if index == 12 || index == 24 {
                await runtime.closeHostSession(hostSession)
                hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
            }
            var current = try await pulse(index + startingRevision)
            let session = hostSession.id
            current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: session))
            current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: session, target: chosen.reference))
            let request = try XCTUnwrap(current.loadRequest)
            current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
                sessionID: session, sessionProof: hostSession.proof, requestID: request.requestID, configuration: chosen.reference, rendered: true))
            _ = try await call("feedback", feedback(.confirmedOutcome, state: current, session: session, target: chosen.reference))
        }
    }
    func testLiveSourceNotificationCanReadStateWithoutInheritingConnectionCycleScope() async throws {
        _ = try await configure()
        let host = self.host!, owner = self.owner!
        let readable = expectation(description: "host reads live decision from Flow notification")
        let subscription = try await host.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.routing.changed" else { return }
            Task {
                do {
                    let value = try await host.get(keypath: "perspective.routing.state", requester: owner)
                    guard case let .object(result) = value, result["status"] == .string("ok") else {
                        XCTFail("live host read rejected: \(value)"); readable.fulfill(); return
                    }
                    readable.fulfill()
                } catch { XCTFail("live host read failed: \(error)"); readable.fulfill() }
            }
        })
        defer { subscription.cancel() }
        _ = try await pulse(2)
        await fulfillment(of: [readable], timeout: 5)
    }
    func testActualSourceAbsorbAndCanonicalLearningCrossIndependentEvidenceGates() async throws {
        let disabled = try await state(); XCTAssertFalse(disabled.enabled); XCTAssertNil(disabled.loadRequest)
        let zero = try await configure(); XCTAssertEqual(zero.phase, "choosePurpose"); XCTAssertNil(zero.loadRequest)
        try await train(35)
        let learned = try await pulse(100)
        XCTAssertEqual(learned.phase, "loading"); XCTAssertTrue(try XCTUnwrap(learned.loadRequest).automatic)
        XCTAssertGreaterThan(try XCTUnwrap(learned.purposeChoices.first).score, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(learned.configurationChoices.first).score, 0.9)
        XCTAssertEqual(learned.configurationChoices.first?.evidenceCount, 35)
        XCTAssertEqual(learned.configurationChoices.first?.distinctSessionCount, 3)
        XCTAssertFalse(learned.statisticallyQualified)
    }
    func testRenderReceiptIsNotConfirmedUtilityAndOriginalChoiceRetriesDeduplicate() async throws {
        var current = try await configure()
        let original = feedback(.purposeChoice, state: current, session: hostSession.id)
        current = try await call("choosePurpose", original)
        let count = current.purposeChoices.first { $0.id == "purpose://family" }?.evidenceCount
        let duplicate = try await call("choosePurpose", original)
        XCTAssertEqual(duplicate.revision, current.revision); XCTAssertEqual(count, 1)
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        let request = try XCTUnwrap(current.loadRequest)
        current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: request.requestID, configuration: target.reference, rendered: true))
        XCTAssertEqual(current.phase, "rendered"); XCTAssertEqual(current.configurationChoices.first?.evidenceCount, 0)
        let next = try await pulse(2); XCTAssertNil(next.loadRequest)
    }
    func testOneHostInstanceReopenDoesNotMintAdditionalSessionsAndForgedSessionRejects() async throws {
        let original = try XCTUnwrap(hostSession)
        let reopened = try await runtime.openHostSession(hostInstanceID: hostInstanceID, requester: owner)
        XCTAssertEqual(original.id, reopened.id); XCTAssertEqual(original.proof, reopened.proof)
        let current = try await configure()
        var forged = feedback(.purposeChoice, state: current, session: UUID().uuidString)
        forged.sessionProof = "invented"
        let result = try await host.set(keypath: "perspective.routing.choosePurpose", value: ContextCodec.encode(forged), requester: owner)
        guard case let .object(o)? = result else { return XCTFail("receipt") }; XCTAssertEqual(o["status"], .string("error"))
        let after = try await state(); XCTAssertEqual(after.revision, current.revision)
    }
    func testCorrectionRequiresNewEvidenceAfterCorrectionRatherThanReusingOldSessions() async throws {
        _ = try await configure(); try await train(35)
        var current = try await pulse(100)
        XCTAssertTrue(try XCTUnwrap(current.loadRequest).automatic)
        current = try await call("feedback", feedback(.purposeCorrection, state: current, session: hostSession.id))
        XCTAssertEqual(current.phase, "choosePurpose")
        XCTAssertEqual(current.purposeChoices.first { $0.id == "purpose://family" }?.evidenceCount, 0)
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        XCTAssertEqual(current.purposeChoices.first { $0.id == "purpose://family" }?.evidenceCount, 1)
        XCTAssertEqual(current.purposeChoices.first { $0.id == "purpose://family" }?.distinctSessionCount, 1)
        let next = try await pulse(101); XCTAssertEqual(next.phase, "choosePurpose"); XCTAssertNil(next.loadRequest)
    }
    func testUnknownCommitOutcomeRetiresOldLoadBeforeAnyFurtherValidation() async throws {
        var current = try await configure()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        XCTAssertNotNil(current.loadRequest)
        let fault = RoutingReadbackFault()
        await runtime.replacePersistenceForTesting { RoutingFaultPersistence(url: $0, fault: fault) }
        let correction = feedback(.purposeCorrection, state: current, session: hostSession.id)
        let receipt = try await host.set(keypath: "perspective.routing.feedback", value: ContextCodec.encode(correction), requester: owner)
        guard case let .object(o)? = receipt else { return XCTFail("receipt") }; XCTAssertEqual(o["status"], .string("error"))
        let blocked = try await host.get(keypath: "perspective.routing.state", requester: owner)
        guard case let .object(unavailable) = blocked else { return XCTFail("state") }
        XCTAssertEqual(unavailable["status"], .string("unavailable")); XCTAssertEqual(unavailable["enabled"], .bool(false))
        let authoritative = try PerspectiveRoutingStore(ownerUUID: owner.uuid, cellUUID: host.uuid).load()
        XCTAssertNotNil(authoritative?.accepted[correction.eventID], "Unknown outcome was an actual successful write followed by failed readback")
    }
    func testSelfSourceRejectsWithoutWaitingForItsOwnGate() async throws {
        try await CellResolver.sharedInstance.registerNamedEmitCell(name: host.uuid, emitCell: host, scope: .scaffoldUnique, identity: owner)
        let configuration = PerspectiveRoutingConfiguration(enabled: true, confirm: true,
            sources: [.init(sourceID: "self", endpoint: "cell:///" + host.uuid, snapshotKey: "perspective.routing.state")],
            purposes: [.init(id: "purpose://family", title: "Family")], configurations: [target.reference])
        let start = Date()
        let result = try await host.set(keypath: "perspective.routing.configure", value: ContextCodec.encode(configuration), requester: owner)
        guard case let .object(o)? = result else { return XCTFail("receipt") }; XCTAssertEqual(o["status"], .string("error"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let paused = try await host.set(keypath: "perspective.routing.pause", value: .object([:]), requester: owner)
        guard case let .object(p)? = paused else { return XCTFail("pause") }; XCTAssertEqual(p["status"], .string("ok"))
    }
    func testSurfaceCorrectionRequiresNewConfirmedOutcomesAndSessions() async throws {
        _ = try await configure(); try await train(35)
        var current = try await pulse(100)
        let request = try XCTUnwrap(current.loadRequest)
        current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: request.requestID, configuration: target.reference, rendered: true))
        current = try await call("feedback", feedback(.configurationCorrection, state: current, session: hostSession.id, target: target.reference))
        XCTAssertEqual(current.phase, "chooseConfiguration"); XCTAssertEqual(current.configurationChoices.first?.evidenceCount, 0)
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        let nextRequest = try XCTUnwrap(current.loadRequest)
        current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: nextRequest.requestID, configuration: target.reference, rendered: true))
        current = try await call("feedback", feedback(.confirmedOutcome, state: current, session: hostSession.id, target: target.reference))
        XCTAssertEqual(current.configurationChoices.first?.evidenceCount, 1); XCTAssertEqual(current.configurationChoices.first?.distinctSessionCount, 1)
        let next = try await pulse(101); XCTAssertEqual(next.phase, "chooseConfiguration"); XCTAssertNil(next.loadRequest)
    }
    func testCompetingLearnedPurposesRequireChoiceEvenWithGoodSurfaceHistory() async throws {
        _ = try await configure(); try await train(35)
        for index in 0..<35 {
            if index == 12 || index == 24 {
                await runtime.closeHostSession(hostSession); hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
            }
            let current = try await pulse(200 + index)
            var choice = feedback(.purposeChoice, state: current, session: hostSession.id); choice.purposeRef = "purpose://work"
            _ = try await call("choosePurpose", choice)
        }
        let ambiguous = try await pulse(300)
        XCTAssertEqual(ambiguous.phase, "choosePurpose"); XCTAssertNil(ambiguous.loadRequest)
        XCTAssertTrue(ambiguous.purposeChoices.allSatisfy { $0.score >= 0.9 && $0.eligible })
    }
    func testConfirmedOutcomeHasOwnDurableReceiptAndCannotConfirmTheEpisodeTwice() async throws {
        var current = try await configure()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        let request = try XCTUnwrap(current.loadRequest)
        current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: request.requestID, configuration: target.reference, rendered: true))
        XCTAssertEqual(current.phase, "rendered")
        let signal = feedback(.confirmedOutcome, state: current, session: hostSession.id, target: target.reference)
        let confirmed = try await call("feedback", signal)
        XCTAssertEqual(confirmed.phase, "confirmed")
        XCTAssertEqual(confirmed.explanation, "Takk. Det bekreftede resultatet er registrert.")
        XCTAssertEqual(confirmed.configurationChoices.first?.evidenceCount, 1)
        let retried = try await call("feedback", signal)
        XCTAssertEqual(retried.revision, confirmed.revision)
        XCTAssertEqual(retried.phase, "confirmed")
        let duplicate = feedback(.confirmedOutcome, state: retried, session: hostSession.id, target: target.reference)
        let response = try await host.set(keypath: "perspective.routing.feedback", value: ContextCodec.encode(duplicate), requester: owner)
        guard case let .object(o)? = response else { return XCTFail("missing receipt") }
        XCTAssertEqual(o["status"], .string("error"))
        let unchanged = try await state()
        XCTAssertEqual(unchanged.configurationChoices.first?.evidenceCount, 1)
    }
    func testRestartAcceptsNewerCurrentSnapshotsInsteadOfReusingOneSnapshotEventID() async throws {
        _ = try await configure()
        let savedHost = try JSONEncoder().encode(host)
        await runtime.shutdown()
        clock.advance(10)
        for (index, label) in ["home", "morning", "family"].enumerated() {
            let newer = ContextObservation(revision: 2, observedAt: clock.now(), validUntil: clock.now().addingTimeInterval(3600), transition: "snapshot", labels: [label])
            _ = try await sourceCells[index].set(keypath: "test.observe", value: ContextCodec.encode(newer), requester: owner)
        }
        host = try JSONDecoder().decode(GeneralCell.self, from: savedHost)
        let rebound = await host.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(rebound)
        let catalog = visibleCatalog, testClock = clock
        runtime = try await PerspectiveRoutingRuntime.install(on: host, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
        let refreshed = try await state()
        XCTAssertEqual(refreshed.phase, "choosePurpose")
        XCTAssertNil(refreshed.loadRequest)
    }
    func testRestartRetainsLearningButRequiresActualFreshSourceSnapshots() async throws {
        _ = try await configure(); try await train(35)
        let savedHost = try JSONEncoder().encode(host)
        clock.advance(3601)
        await runtime.shutdown()
        host = try JSONDecoder().decode(GeneralCell.self, from: savedHost)
        let rebound = await host.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(rebound)
        visibleCatalog.replace([target])
        let catalog = visibleCatalog, testClock = clock
        runtime = try await PerspectiveRoutingRuntime.install(on: host, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
        let expired = try await state(); XCTAssertEqual(expired.phase, "waitingContext"); XCTAssertNil(expired.loadRequest)
        _ = try await pulse(400)
        _ = try await pulse(2, labels: ["morning"], sourceIndex: 1)
        let refreshed = try await pulse(2, labels: ["family"], sourceIndex: 2)
        XCTAssertEqual(refreshed.phase, "loading"); XCTAssertTrue(try XCTUnwrap(refreshed.loadRequest).automatic)
        XCTAssertEqual(refreshed.configurationChoices.first?.evidenceCount, 35)
        XCTAssertEqual(refreshed.configurationChoices.first?.distinctSessionCount, 3)
    }
    func testInactiveHostCanBeRetiredAndExistingFocusedHostKeepsSessionIdentity() async throws {
        let first = try XCTUnwrap(hostSession), otherID = UUID()
        let other = try await runtime.openHostSession(hostInstanceID: otherID, requester: owner)
        let focusedAgain = try await runtime.openHostSession(hostInstanceID: hostInstanceID, requester: owner)
        XCTAssertEqual(focusedAgain.id, first.id)
        await runtime.closeHostSession(other)
        do { _ = try await runtime.openHostSession(hostInstanceID: otherID, requester: owner); XCTFail("retired inactive host must not silently mint a new session") }
        catch PerspectiveRoutingError.invalidInput { }
        let current = try await runtime.openHostSession(hostInstanceID: hostInstanceID, requester: owner)
        XCTAssertEqual(current.id, first.id)
    }
    func testIndependentConfigurationAmbiguityRequiresUserChoice() async throws {
        let alternative = PerspectiveRoutingTarget(reference: .init(configurationUUID: "12345678-1234-4234-8234-123456789002", sourceCellEndpoint: "cell:///SyntheticAlternative"), name: "Alternative", purposeRefs: ["purpose://family"])
        visibleCatalog.replace([target, alternative])
        _ = try await configure(configurations: [target.reference, alternative.reference])
        try await train(35)
        try await train(35, chosenTarget: alternative, startingRevision: 200)
        let ambiguous = try await pulse(400)
        XCTAssertEqual(ambiguous.phase, "chooseConfiguration"); XCTAssertNil(ambiguous.loadRequest)
        XCTAssertEqual(ambiguous.configurationChoices.count, 2)
        XCTAssertTrue(ambiguous.configurationChoices.allSatisfy { $0.score >= 0.9 && $0.eligible })
    }
    func testRevokedOrUnknownExactTargetNeverFallsBackToAnotherSurface() async throws {
        var current = try await configure()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        var unknown = feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference)
        unknown.configuration = .init(configurationUUID: "12345678-1234-4234-8234-123456789099", sourceCellEndpoint: "cell:///SyntheticFamily")
        let refused = try await host.set(keypath: "perspective.routing.chooseConfiguration", value: ContextCodec.encode(unknown), requester: owner)
        guard case let .object(o)? = refused else { return XCTFail("receipt") }; XCTAssertEqual(o["status"], .string("error"))
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        XCTAssertNotNil(current.loadRequest)
        visibleCatalog.replace([])
        let revoked = try await state(); XCTAssertEqual(revoked.phase, "noSuitableConfiguration"); XCTAssertNil(revoked.loadRequest)
    }
    func testKnownFailedLoadPreservesActiveSurfaceAndRequiresExplicitRetryAcrossSourceChanges() async throws {
        _ = try await configure(); try await train(35)
        var current = try await pulse(100)
        let previous = current.activeConfiguration, request = try XCTUnwrap(current.loadRequest)
        current = try await call("renderAcknowledged", PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: request.requestID, configuration: target.reference, rendered: false))
        XCTAssertEqual(current.activeConfiguration, previous); XCTAssertEqual(current.phase, "chooseConfiguration")
        let next = try await pulse(101); XCTAssertEqual(next.phase, "chooseConfiguration"); XCTAssertNil(next.loadRequest)
        let retry = try await call("chooseConfiguration", feedback(.configurationChoice, state: next, session: hostSession.id, target: target.reference))
        XCTAssertNotNil(retry.loadRequest); XCTAssertFalse(try XCTUnwrap(retry.loadRequest).automatic)
    }
    func testOtherInstanceNewAuthorityInvalidatesOldOperativeLoadReads() async throws {
        var current = try await configure()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        XCTAssertNotNil(current.loadRequest)
        let otherHost = try JSONDecoder().decode(GeneralCell.self, from: JSONEncoder().encode(host))
        let rebound = await otherHost.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(rebound)
        let catalog = visibleCatalog, testClock = clock
        let other = try await PerspectiveRoutingRuntime.install(on: otherHost, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        _ = try await other.openHostSession(hostInstanceID: UUID(), requester: owner)
        let response = try await host.get(keypath: "perspective.routing.state", requester: owner)
        guard case let .object(o) = response else { await other.shutdown(); return XCTFail("response") }
        XCTAssertNotEqual(o["status"], .string("ok")); XCTAssertNil(o["state"])
        let projection = await runtime.committedPurposeProjection(); XCTAssertNil(projection)
        await other.shutdown()
    }
    func testTemporarilyMissingSourceAtRestartCanReconnectOnLaterStateRead() async throws {
        _ = try await configure()
        let bytes = try JSONEncoder().encode(host); await runtime.shutdown()
        host = try JSONDecoder().decode(GeneralCell.self, from: bytes)
        let rebound = await host.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(rebound)
        let catalog = visibleCatalog, testClock = clock
        runtime = try await PerspectiveRoutingRuntime.install(on: host, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
        let realResolver = CellBase.defaultCellResolver
        CellBase.defaultCellResolver = MockCellResolver()
        let missing = try await host.get(keypath: "perspective.routing.state", requester: owner)
        CellBase.defaultCellResolver = realResolver
        guard case let .object(o) = missing else { return XCTFail("response") }; XCTAssertEqual(o["status"], .string("error"))
        let reconnected = try await state(); XCTAssertEqual(reconnected.phase, "choosePurpose")
    }
    func testNativePerspectiveQueriesUseCommittedReversiblePurposeOverlay() async throws {
        await runtime.shutdown()
        let native = await PerspectiveCell(owner: owner)
        host = native
        for (id,name,weight) in [("purpose://family","Family",0.5),("purpose://work","Work",0.6),("purpose://outside","Outside",0.7)] {
            let interest = Interest(name: name + " interest", types: [], parts: [], partOf: [], purposes: [])
            let purpose = Purpose(name: name, description: "Synthetic baseline", interests: [Weight<Interest>(weight: 1, value: interest)]); purpose.nodeIdentifier = id
            await native.context.upsertActivePurpose(weighedPurpose: Weight<Purpose>(weight: weight, value: purpose))
        }
        let baselineBefore = await native.context.getActivePurposes(minWeight: 0, limit: 100)
        let expectedReferences = Set(baselineBefore.compactMap { $0.reference ?? $0.value?.reference }).subtracting(["purpose://work"])
        let catalog = visibleCatalog, testClock = clock
        runtime = try await native.installPerspectiveRouting(requester: owner, catalog: { _ in await catalog.read() }, clock: { testClock.now() })
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner)
        let before = try await configure()
        _ = try await call("choosePurpose", feedback(.purposeChoice, state: before, session: hostSession.id))
        let active = await native.effectiveActivePurposes(minWeight: 0, limit: 100)
        XCTAssertEqual(Set(active.compactMap { $0.reference ?? $0.value?.reference }), expectedReferences)
        let baseline = await native.context.getActivePurposes(minWeight: 0, limit: 100)
        XCTAssertEqual(baseline.count, baselineBefore.count)
        for response in [try await native.get(keypath: "activePurpose", requester: owner),
                         try await native.set(keypath: "perspective.query.activePurposes", value: .object([:]), requester: owner) ?? .null] {
            guard case let .object(payload) = response, case let .list(purposes)? = payload["purposes"] else { return XCTFail("active payload") }
            let refs = purposes.compactMap { value -> String? in guard case let .object(o) = value, case let .string(ref)? = o["purposeRef"] else { return nil }; return ref }
            XCTAssertEqual(Set(refs), expectedReferences)
        }
        let interestResponse = try await native.set(keypath: "perspective.query.interestsFromActivePurposes", value: .object([:]), requester: owner)
        guard case let .object(interestPayload)? = interestResponse, case let .list(interests)? = interestPayload["interests"] else { return XCTFail("interest response") }
        let names = interests.compactMap { value -> String? in guard case let .object(o) = value, case let .string(name)? = o["interestName"] else { return nil }; return name }
        XCTAssertTrue(names.contains("Family interest")); XCTAssertFalse(names.contains("Work interest"))
        let matching = try await native.set(keypath: "perspective.query.match", value: .object(["targetPurposes": .list([
            .object(["purposeRef": .string("purpose://family"), "purposeName": .string("Family"), "purposeWeight": .float(1)]),
            .object(["purposeRef": .string("purpose://work"), "purposeName": .string("Work"), "purposeWeight": .float(1)])])]), requester: owner)
        guard case let .object(matches)? = matching, case let .list(hits)? = matches["directPurposeHits"] else { return XCTFail("matching response") }
        XCTAssertEqual(hits.count, 1)
        _ = try await host.set(keypath: "perspective.routing.pause", value: .object([:]), requester: owner)
        let paused = await native.effectiveActivePurposes(minWeight: 0, limit: 100)
        XCTAssertEqual(paused.count, baselineBefore.count)
        XCTAssertEqual(paused.first { ($0.reference ?? $0.value?.reference) == "purpose://family" }?.weight, 0.5)
    }
    func testNativeHostReadsExactLoadedConfigurationOnlyWithLiveOwner() async throws {
        let porthole = await OrchestratorCell(owner: owner)
        var configuration = CellConfiguration(name: "Actual host configuration")
        configuration.uuid = "12345678-1234-4234-8234-123456789009"
        configuration.skeleton = .Text(.init(text: "Real normal loader"))
        try await porthole.loadCellConfiguration(configuration, requester: owner)
        let actual = try await porthole.activeConfigurationForRuntimeBinding(requester: owner)
        XCTAssertEqual(actual?.uuid, configuration.uuid)
        do {
            _ = try await porthole.activeConfigurationForRuntimeBinding(requester: owner.publicIdentitySnapshot())
            XCTFail("public descriptor acquired host inspection")
        } catch { }
        let stranger = await CellBase.defaultIdentityVault!.identity(for: "stranger", makeNewIfNotFound: true)!
        do {
            _ = try await porthole.activeConfigurationForRuntimeBinding(requester: stranger)
            XCTFail("foreign owner acquired host inspection")
        } catch { }
    }
    func testTrustedNewHostRebindsCatalogRatherThanRetainingClosedWindowProvider() async throws {
        _ = try await configure()
        let old = hostSession!
        await runtime.closeHostSession(old)
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner, catalog: { _ in [] })
        var current = try await state()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        XCTAssertEqual(current.phase, "noSuitableConfiguration")
        let catalog = visibleCatalog
        hostSession = try await runtime.openHostSession(hostInstanceID: UUID(), requester: owner, catalog: { _ in await catalog.read() })
        do {
            _ = try await runtime.openHostSession(hostInstanceID: hostInstanceID, requester: owner, catalog: { _ in [] })
            XCTFail("closed host replaced active catalog")
        } catch { }
        current = try await state()
        current = try await call("choosePurpose", feedback(.purposeChoice, state: current, session: hostSession.id))
        XCTAssertEqual(current.configurationChoices.map(\.id), [target.reference.node.id])
    }
    func testAcceptedFutureClockSkewCorrectionImmediatelyRetiresOldEvidence() async throws {
        _ = try await configure(); try await train(35)
        let rendered = try await state()
        var correction = feedback(.configurationCorrection, state: rendered, session: hostSession.id, target: target.reference)
        correction.occurredAt += 299
        let corrected = try await call("feedback", correction)
        _ = try await call("chooseConfiguration", feedback(.configurationChoice, state: corrected, session: hostSession.id, target: target.reference))
        let next = try await pulse(900)
        XCTAssertEqual(next.phase, "chooseConfiguration"); XCTAssertNil(next.loadRequest)
        XCTAssertEqual(next.configurationChoices.first?.evidenceCount, 0)
        XCTAssertFalse(next.configurationChoices.first?.eligible ?? true)
    }
    func testExpiryDuringCatalogAwaitCannotPublishOperativeLoadOrRenderReceipt() async throws {
        _ = try await configure()
        var current = try await call("choosePurpose", feedback(.purposeChoice, state: try await state(), session: hostSession.id))
        let testClock = clock
        visibleCatalog.delayNext { testClock.advance(3601) }
        let selected = feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference)
        let response = try await host.set(keypath: "perspective.routing.chooseConfiguration", value: ContextCodec.encode(selected), requester: owner)
        guard case let .object(result)? = response else { return XCTFail("response missing") }
        XCTAssertEqual(result["status"], .string("error"))
        current = try await state()
        XCTAssertNil(current.loadRequest); XCTAssertEqual(current.phase, "waitingContext")
    }
    func testExpiryDuringAutomaticEvaluationCannotPublishLateRequest() async throws {
        _ = try await configure(); try await train(35)
        let testClock = clock
        visibleCatalog.delayNext { testClock.advance(3601) }
        let expired = try await pulse(901)
        XCTAssertEqual(expired.phase, "waitingContext"); XCTAssertNil(expired.loadRequest)
    }
    func testExpiryDuringRenderAdmissionRejectsLateAcknowledgement() async throws {
        _ = try await configure()
        var current = try await call("choosePurpose", feedback(.purposeChoice, state: try await state(), session: hostSession.id))
        current = try await call("chooseConfiguration", feedback(.configurationChoice, state: current, session: hostSession.id, target: target.reference))
        let request = try XCTUnwrap(current.loadRequest), testClock = clock
        visibleCatalog.delayNext { testClock.advance(3601) }
        let receipt = PerspectiveRoutingRenderReceipt(decisionRevision: current.revision, episodeID: current.episodeID,
            sessionID: hostSession.id, sessionProof: hostSession.proof, requestID: request.requestID, configuration: target.reference, rendered: true)
        let result = try await host.set(keypath: "perspective.routing.renderAcknowledged", value: ContextCodec.encode(receipt), requester: owner)
        guard case let .object(o)? = result else { return XCTFail("response missing") }
        XCTAssertEqual(o["status"], .string("error"))
        let expired = try await state(); XCTAssertNil(expired.activeConfiguration); XCTAssertNil(expired.loadRequest)
    }
    func testRestoreRejectsInventedEvidenceAndMismatchedOriginalMetadata() async throws {
        _ = try await configure()
        _ = try await call("choosePurpose", feedback(.purposeChoice, state: try await state(), session: hostSession.id))
        let store = PerspectiveRoutingStore(ownerUUID: owner.uuid, cellUUID: host.uuid)
        let original = try XCTUnwrap(store.load())
        XCTAssertNoThrow(try PerspectiveRoutingStore.validateFeedbackBinding(original))
        let id = try XCTUnwrap(original.accepted.keys.first)
        for mutation in 0..<5 {
            var tampered = original
            switch mutation {
            case 0: tampered.accepted[id]?.motorSequence += 1
            case 1: tampered.accepted[id]?.feedback.sessionID = "invented-session"
            case 2: tampered.accepted[id]?.motorApplied = false
            case 3: tampered.accepted["invented-event"] = original.accepted[id]
            default: tampered.motorJournal = .empty
            }
            XCTAssertThrowsError(try PerspectiveRoutingStore.validateFeedbackBinding(tampered))
        }
    }
    func testExpiredOrDepartedContextCannotTrainOrTriggerLoad() async throws {
        let configured = try await configure()
        clock.advance(3601)
        let expired = try await state(); XCTAssertEqual(expired.phase, "waitingContext"); XCTAssertNil(expired.loadRequest)
        let invalid = feedback(.purposeChoice, state: expired, session: hostSession.id)
        let response = try await host.set(keypath: "perspective.routing.choosePurpose", value: ContextCodec.encode(invalid), requester: owner)
        guard case let .object(o)? = response else { return XCTFail("receipt") }; XCTAssertEqual(o["status"], .string("error"))
        XCTAssertGreaterThan(expired.revision, configured.revision)
        let departed = try await pulse(2, labels: []); XCTAssertEqual(departed.phase, "waitingContext"); XCTAssertNil(departed.loadRequest)
    }
}

private final class RoutingReadbackFault: @unchecked Sendable {
    private let lock = NSLock(); private var pending = false
    func afterWrite() { lock.lock(); pending = true; lock.unlock() }
    func consume() -> Bool { lock.lock(); defer { lock.unlock() }; let value = pending; pending = false; return value }
}
private struct RoutingFaultPersistence: EntityAuthorityReplicaPersistence {
    let url: URL; let fault: RoutingReadbackFault
    var durabilityLevel: EntityAuthorityReplicaDurabilityLevel { .atomicFileReplaceWithoutPowerLossProof }
    func store(_ data: Data) throws { try AtomicFileEntityAuthorityReplicaPersistence(fileURL: url).store(data); fault.afterWrite() }
    func load() throws -> Data? {
        if fault.consume() { throw PerspectiveRoutingError.unavailable("synthetic readback failure AFTER actual atomic write") }
        return try AtomicFileEntityAuthorityReplicaPersistence(fileURL: url).load()
    }
}
