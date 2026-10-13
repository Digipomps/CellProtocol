// SPDX-License-Identifier: Apache-2.0
import XCTest
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
@_spi(HAVENRuntime) @testable import CellBase
@testable import CellApple

final class PerspectiveContextTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T07:00:00Z")!
    private func event(_ revision: Int, _ labels: [String], transition: String = "entered") -> ContextObservation {
        .init(revision: revision, observedAt: now, validUntil: now.addingTimeInterval(3600), transition: transition, labels: labels)
    }
    private func config(weight: Double = 0.8) -> ContextConfiguration {
        let predicate = GoalPredicate(kind: "all", all: [
            .init(kind: "contains-label", sourceID: "time", expected: "morning"),
            .init(kind: "any", any: [
                .init(kind: "contains-label", sourceID: "place", expected: "home"),
                .init(kind: "contains-label", sourceID: "presence", expected: "family")
            ])
        ])
        let definition = GoalDefinition(goalID: "morning", purposeRef: "purpose://family", title: "Family morning", description: "Morning at home or with family", lifecycle: .continuous, evaluatorKind: .composite,
                                        evidenceSources: ["time", "place", "presence"].map { .init(sourceID: $0) }, predicate: predicate)
        return .init(sources: ["time", "place", "presence"].map { .init(sourceID: $0, endpoint: "cell:///" + $0) },
                     rules: [.init(id: "morning", definition: definition, label: "morning", purposeWeights: ["purpose://family": weight])])
    }
    func testMorningNeedsTimeAndHomeOrFamilyAndKnownEmptySources() throws {
        for home in [false, true] { for family in [false, true] { for morning in [false, true] {
            var state = PerspectiveContextState(configuration: config())
            try state.ingest(event(1, home ? ["home"] : []), sourceID: "place", eventID: "p", snapshot: false, now: now)
            try state.ingest(event(1, family ? ["family"] : []), sourceID: "presence", eventID: "e", snapshot: false, now: now)
            try state.ingest(event(1, morning ? ["morning"] : []), sourceID: "time", eventID: "t", snapshot: false, now: now)
            XCTAssertEqual(state.decision(now: now).labels, morning && (home || family) ? ["morning"] : [])
        } } }
    }
    func testDepartureDuplicateDelayedAndConflictingEvents() throws {
        var state = PerspectiveContextState(configuration: config())
        XCTAssertTrue(try state.ingest(event(1, ["home"]), sourceID: "place", eventID: "p1", snapshot: false, now: now))
        XCTAssertFalse(try state.ingest(event(1, ["home"]), sourceID: "place", eventID: "p1", snapshot: false, now: now))
        try state.ingest(event(2, [], transition: "left"), sourceID: "place", eventID: "p2", snapshot: false, now: now)
        XCTAssertFalse(try state.ingest(event(1, ["home"]), sourceID: "place", eventID: "old", snapshot: false, now: now))
        XCTAssertEqual(state.observations["place"]?.labels, [])
        XCTAssertThrowsError(try state.ingest(event(2, ["home"]), sourceID: "place", eventID: "conflict", snapshot: false, now: now))
        XCTAssertThrowsError(try state.ingest(event(3, []), sourceID: "outsider", eventID: "x", snapshot: false, now: now))
    }
    func testExpiryAndRestartRequireFreshSnapshotEvenAtSameRevision() throws {
        var state = PerspectiveContextState(configuration: config())
        for (id, labels) in [("place", ["home"]), ("time", ["morning"]), ("presence", [])] {
            try state.ingest(event(1, labels), sourceID: id, eventID: id, snapshot: false, now: now)
        }
        XCTAssertEqual(state.decision(now: now).labels, ["morning"])
        XCTAssertEqual(state.decision(now: now.addingTimeInterval(3600)).labels, [])
        let restored = try ContextCodec.decode(ContextCodec.encode(state), as: PerspectiveContextState.self)
        var reload = restored
        XCTAssertEqual(reload.decision(now: now).labels, [])
        for id in ["place", "time", "presence"] {
            XCTAssertFalse(try reload.ingest(state.observations[id]!, sourceID: id, eventID: id, snapshot: false, now: now))
            XCTAssertTrue(try reload.ingest(state.observations[id]!, sourceID: id, eventID: id, snapshot: true, now: now))
        }
        XCTAssertEqual(reload.decision(now: now).labels, ["morning"])
    }
    func testPrioritySupportsLowerWeightsAndDeactivationAndStableTies() throws {
        var configuration = config(weight: 0.9)
        var low = configuration.rules[0]; low.id = "a"; low.priority = 2; low.purposeWeights = ["purpose://family": 0]
        var tied = low; tied.id = "b"; tied.purposeWeights = ["purpose://family": 0.4]
        configuration.rules += [tied, low]
        var state = PerspectiveContextState(configuration: configuration)
        for (id, labels) in [("place", ["home"]), ("time", ["morning"]), ("presence", [])] { try state.ingest(event(1, labels), sourceID: id, eventID: id, snapshot: false, now: now) }
        XCTAssertEqual(state.decision(now: now).purposeWeights["purpose://family"], 0)
        XCTAssertEqual(state.decision(now: now).purposeRules["purpose://family"], "a")
        try state.ingest(event(2, [], transition: "left"), sourceID: "time", eventID: "t2", snapshot: false, now: now)
        XCTAssertEqual(state.decision(now: now).purposeWeights, [:])
    }
    func testMalformedConfigurationAndEventsAreRejected() throws {
        var c = config(); c.sources.append(c.sources[0]); XCTAssertThrowsError(try c.validate())
        c = config(); c.rules[0].purposeWeights = ["bad": .nan]; XCTAssertThrowsError(try c.validate())
        var e = event(1, ["x", "x"]); XCTAssertThrowsError(try e.validate(now: now))
        e = event(1, []); e.schemaVersion = 2; XCTAssertThrowsError(try e.validate(now: now))
    }
    func testFiltersIntersectWithinBaseAndUseBaseWhenUnknownOrExpired() throws {
        let policy = ContextFilterConfiguration(perspectiveEndpoint: "cell:///Perspective", contentEndpoints: ["cell:///News"], baseTopics: ["news.*"], topicsByLabel: ["morning": ["news.family"], "work": ["news.work"]])
        var state = PerspectiveContextState(configuration: config())
        for (id, labels) in [("place", ["home"]), ("time", ["morning"]), ("presence", [])] { try state.ingest(event(1, labels), sourceID: id, eventID: id, snapshot: false, now: now) }
        var decision = state.decision(now: now)
        XCTAssertTrue(policy.permits(topic: "news.family", decision: decision, now: now))
        XCTAssertFalse(policy.permits(topic: "news.work", decision: decision, now: now))
        XCTAssertFalse(policy.permits(topic: "private", decision: nil, now: now))
        decision.labels.append("work")
        XCTAssertFalse(policy.permits(topic: "news.family", decision: decision, now: now))
        XCTAssertTrue(policy.permits(topic: "news.work", decision: decision, now: now.addingTimeInterval(3601)))
    }
}

private final class SemanticSourceFixture: GeneralCell {
    var observation = ContextObservation(revision: 1, observedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), validUntil: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600), transition: "snapshot", labels: [])
    var emitter: ((FlowElement) -> Void)?
    required init(owner: Identity) async { await super.init(owner: owner); try? await ensureRuntimeReady() }
    required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    override func installCellRuntimeBindingsForAccess() async throws {
        let owner = storedOwnerIdentity
        agreementTemplate.ensureGrant("r---", for: "context")
        emitter = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        await registerGet(key: "context", owner: owner, returns: ExploreContract.schema(type: "object"), permissions: ["r---"], description: .string("Source snapshot")) { [weak self] _ in
            guard let self else { return .null }; return .object(["observation": try! ContextCodec.encode(self.observation)])
        }
    }
    func send(_ labels: [String], topic: String = "context.observation.changed") {
        observation.revision += 1; observation.labels = labels; observation.transition = labels.isEmpty ? "left" : "entered"
        let value = try! ContextCodec.encode(observation)
        guard case let .object(object) = value else { return }
        var event = FlowElement(title: "Changed", content: .object(object), properties: .init(type: .event, contentType: .object))
        event.topic = topic; emitter?(event)
    }
}

final class PerspectiveContextFlowTests: XCTestCase {
    private var oldVault: IdentityVaultProtocol?
    private var oldResolver: CellResolverProtocol?
    private var oldDebug = false
    override func setUp() { oldVault = CellBase.defaultIdentityVault; oldResolver = CellBase.defaultCellResolver; oldDebug = CellBase.debugValidateAccessForEverything; CellBase.debugValidateAccessForEverything = true }
    override func tearDown() { CellBase.defaultIdentityVault = oldVault; CellBase.defaultCellResolver = oldResolver; CellBase.debugValidateAccessForEverything = oldDebug }
    func testRealSubscriptionChangesEffectivePurposesAndDepartureRestoresBaseline() async throws {
        let vault = MockIdentityVault(); CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let resolver = MockCellResolver(); CellBase.defaultCellResolver = resolver
        let source = await SemanticSourceFixture(owner: owner)
        try await resolver.registerNamedEmitCell(name: "place", emitCell: source, scope: .scaffoldUnique, identity: owner)
        let cell = await PerspectiveCell(owner: owner)
        let purpose = Purpose(name: "Family", description: "family")
        await cell.context.upsertActivePurpose(weighedPurpose: Weight<Purpose>(weight: 0.5, value: purpose))
        let definition = GoalDefinition(goalID: "at-home", purposeRef: purpose.reference, title: "Home", description: "At home", lifecycle: .continuous, evaluatorKind: .statePredicate,
                                        evidenceSources: [.init(sourceID: "place")], predicate: .init(kind: "contains-label", sourceID: "place", expected: "home"))
        let config = ContextConfiguration(sources: [.init(sourceID: "place", endpoint: "cell:///place")], rules: [.init(id: "home", definition: definition, label: "home", purposeWeights: [purpose.reference: 0])])
        let response = try await cell.set(keypath: "perspective.context.configure", value: ContextCodec.encode(config), requester: owner)
        guard case let .object(object) = response else { return XCTFail("bad response \(response)") }
        guard case let .string(status)? = object["status"] else { return XCTFail("missing status \(response)") }
        XCTAssertEqual(status, "ok", "\(response)")
        let changed = expectation(description: "home context")
        let departed = expectation(description: "departure context")
        let feed = try await cell.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(value) = event.content, let state = try? ContextCodec.decode(.object(value), as: ContextDecision.self) else { return }
            if state.labels == ["home"] { changed.fulfill() }
            if state.labels.isEmpty && state.sourceRevisions["place"] == 3 { departed.fulfill() }
        })
        defer { feed.cancel() }
        source.send(["home"])
        await fulfillment(of: [changed], timeout: 3)
        let active = await cell.effectiveActivePurposes(minWeight: 0, limit: 100)
        XCTAssertFalse(active.contains { $0.value?.reference == purpose.reference })
        source.send([])
        await fulfillment(of: [departed], timeout: 3)
        let restored = await cell.effectiveActivePurposes(minWeight: 0, limit: 100)
        XCTAssertEqual(restored.first(where: { $0.value?.reference == purpose.reference })?.weight, 0.5)
    }
}

final class PerspectiveContextIntegrationTests: XCTestCase {
    private var oldVault: IdentityVaultProtocol?
    private var oldResolver: CellResolverProtocol?
    private var oldDebug = false
    override func setUp() { oldVault = CellBase.defaultIdentityVault; oldResolver = CellBase.defaultCellResolver; oldDebug = CellBase.debugValidateAccessForEverything; CellBase.debugValidateAccessForEverything = true }
    override func tearDown() { CellBase.defaultIdentityVault = oldVault; CellBase.defaultCellResolver = oldResolver; CellBase.debugValidateAccessForEverything = oldDebug }
    private func fixture() async throws -> (Identity, CellResolver, SemanticSourceFixture, PerspectiveCell) {
        let vault = MockIdentityVault(); CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let resolver = CellResolver.sharedInstance; CellBase.defaultCellResolver = resolver
        let source = await SemanticSourceFixture(owner: owner)
        try await resolver.registerNamedEmitCell(name: source.uuid, emitCell: source, scope: .scaffoldUnique, identity: owner)
        let perspective = await PerspectiveCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: perspective.uuid, emitCell: perspective, scope: .scaffoldUnique, identity: owner)
        let definition = GoalDefinition(goalID: "home", purposeRef: "purpose://family", title: "Home", description: "At home", lifecycle: .continuous, evaluatorKind: .statePredicate,
                                        evidenceSources: [.init(sourceID: "place")], predicate: .init(kind: "contains-label", sourceID: "place", expected: "home"))
        let configuration = ContextConfiguration(sources: [.init(sourceID: "place", endpoint: "cell:///" + source.uuid)], rules: [.init(id: "home", definition: definition, label: "home")])
        try assertOK(await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: owner))
        return (owner, resolver, source, perspective)
    }
    private func assertOK(_ optionalValue: ValueType?, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let value = optionalValue else { return XCTFail("missing response", file: file, line: line) }
        guard case let .object(object) = value, case let .string(status)? = object["status"] else { return XCTFail("Expected status: \(value)", file: file, line: line) }
        XCTAssertEqual(status, "ok", "\(value)", file: file, line: line)
    }
    func testResolverLoadedPortholeInputFiltersContentAndConsumesControlEvents() async throws {
        let (owner, resolver, source, perspective) = try await fixture()
        let news = await SemanticSourceFixture(owner: owner)
        try await resolver.registerNamedEmitCell(name: news.uuid, emitCell: news, scope: .scaffoldUnique, identity: owner)
        let filter = await ContextFlowFilterCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: filter.uuid, emitCell: filter, scope: .scaffoldUnique, identity: owner)
        let config = ContextFilterConfiguration(perspectiveEndpoint: "cell:///" + perspective.uuid, contentEndpoints: ["cell:///" + news.uuid], baseTopics: ["news.*"], topicsByLabel: ["home": ["news.family"]])
        try assertOK(await filter.set(keypath: "filter.configure", value: ContextCodec.encode(config), requester: owner))
        let root = await GeneralCell(owner: owner)
        let reference = CellReference(endpoint: "cell:///" + filter.uuid, label: "filtered")
        _ = try await resolver.loadCell(from: CellConfiguration(name: "Filtered Porthole input", cellReferences: [reference]), into: root, requester: owner)
        let home = expectation(description: "home control")
        let pfeed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(object) = event.content,
                  let decision = try? ContextCodec.decode(.object(object), as: ContextDecision.self), decision.labels == ["home"] else { return }; home.fulfill()
        })
        defer { pfeed.cancel() }
        let delivered = expectation(description: "family news delivered")
        let forbidden = expectation(description: "restricted content or control leaked"); forbidden.isInverted = true
        let feed = try await root.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            if event.topic == "news.family" { delivered.fulfill() }
            else if event.topic == "news.work" || event.topic == "perspective.context.changed" { forbidden.fulfill() }
        })
        defer { feed.cancel() }
        source.send(["home"])
        await fulfillment(of: [home], timeout: 3)
        // The control delivery is asynchronous; reading state waits behind its transaction.
        let stateValue = try await filter.get(keypath: "filter.state", requester: owner)
        let decision = try ContextCodec.decode(stateValue, as: ContextDecision.self)
        XCTAssertEqual(decision.labels, ["home"])
        news.send([], topic: "news.work")
        news.send([], topic: "news.family")
        await fulfillment(of: [delivered, forbidden], timeout: 1)
    }
    func testDurableContextReadAfterFreshCellDecodeAndDetachPersists() async throws {
        let (owner, _, _, perspective) = try await fixture()
        try assertOK(await perspective.set(keypath: "perspective.context.sources.detach", value: .string("place"), requester: owner))
        let data = try JSONEncoder().encode(perspective)
        let restored = try JSONDecoder().decode(PerspectiveCell.self, from: data)
        let rebound = await restored.bindStoredOwnerToRuntimeIdentity(owner)
        XCTAssertTrue(rebound)
        let value = try await restored.get(keypath: "perspective.context.configuration", requester: owner)
        let config = try ContextCodec.decode(value, as: ContextConfiguration.self)
        XCTAssertEqual(config.sources.first?.enabled, false)
        let stateValue = try await restored.get(keypath: "perspective.context.state", requester: owner)
        let decision = try ContextCodec.decode(stateValue, as: ContextDecision.self)
        XCTAssertEqual(decision.unknownSources, ["place"])
    }
    func testConfigurationRejectsNonOwnerWithoutDebugBypass() async throws {
        let (owner, _, _, perspective) = try await fixture()
        CellBase.debugValidateAccessForEverything = false
        let outsider = await CellBase.defaultIdentityVault!.identity(for: "outsider", makeNewIfNotFound: true)!
        do {
            let response = try await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(ContextConfiguration()), requester: outsider)
            guard case .string("denied") = response else { return XCTFail("Unprivileged config accepted: \(response)") }
        } catch { /* Existing runtime may reject before the registered handler. */ }
        let value = try await perspective.get(keypath: "perspective.context.configuration", requester: owner)
        let config = try ContextCodec.decode(value, as: ContextConfiguration.self)
        XCTAssertEqual(config.sources.count, 1)
    }
}

extension PerspectiveContextTests {
    func testJobParentMeetingDigitalGroupAndNewsLabelsAreIndependentRules() throws {
        let sources = ["place", "physical", "digital", "news"].map { ContextSource(sourceID: $0, endpoint: "cell:///" + $0) }
        let cases = [("job", "place", "office"), ("parent-meeting", "physical", "parents"), ("digital-meeting", "digital", "parents"), ("news-alert", "news", "important")]
        let rules = cases.map { id, source, label in
            ContextRule(id: id, definition: GoalDefinition(goalID: id, purposeRef: "purpose://" + id, title: id, description: id, lifecycle: .continuous, evaluatorKind: .statePredicate,
                        evidenceSources: [.init(sourceID: source)], predicate: .init(kind: "contains-label", sourceID: source, expected: label)), label: id)
        }
        var state = PerspectiveContextState(configuration: .init(sources: sources, rules: rules))
        for (index, item) in cases.enumerated() {
            var e = event(1, [item.2]); e.transition = "configurationChanged"; e.configurationRevision = 1
            try state.ingest(e, sourceID: item.1, eventID: "event-\(index)", snapshot: false, now: now)
        }
        XCTAssertEqual(Set(state.decision(now: now).labels), Set(cases.map { $0.0 }))
        try state.ingest(event(2, [], transition: "left"), sourceID: "physical", eventID: "left", snapshot: false, now: now)
        XCTAssertFalse(state.decision(now: now).labels.contains("parent-meeting"))
        XCTAssertTrue(state.decision(now: now).labels.contains("digital-meeting"))
    }
    func testExpiryAdvancesRevisionOnceAndExpiredSnapshotCannotConfirm() throws {
        var state = PerspectiveContextState(configuration: config())
        try state.ingest(event(1, ["home"]), sourceID: "place", eventID: "p", snapshot: false, now: now)
        let before = state.revision
        XCTAssertTrue(state.expire(now: now.addingTimeInterval(3600)))
        XCTAssertEqual(state.revision, before + 1)
        XCTAssertFalse(state.expire(now: now.addingTimeInterval(3601)))
        XCTAssertFalse(try state.ingest(event(1, ["home"]), sourceID: "place", eventID: "p", snapshot: true, now: now.addingTimeInterval(3601)))
        XCTAssertEqual(state.revision, before + 1)
    }
    func testMalformedControlCannotClaimActiveRulesWithoutValidity() throws {
        var state = PerspectiveContextState(configuration: config())
        let valid = state.decision(now: now)
        XCTAssertNoThrow(try valid.validate())
        var invalid = valid; invalid.labels = ["home"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = valid; invalid.revision = -1
        XCTAssertThrowsError(try invalid.validate())
    }
}

extension PerspectiveContextIntegrationTests {
    func testSameFilterConfigurationPreservesActiveRestrictions() async throws {
        let (owner, resolver, source, perspective) = try await fixture()
        let news = await SemanticSourceFixture(owner: owner)
        try await resolver.registerNamedEmitCell(name: news.uuid, emitCell: news, scope: .scaffoldUnique, identity: owner)
        let filter = await ContextFlowFilterCell(owner: owner)
        let configuration = ContextFilterConfiguration(perspectiveEndpoint: "cell:///" + perspective.uuid, contentEndpoints: ["cell:///" + news.uuid], baseTopics: ["news.*"], topicsByLabel: ["home": ["news.family"]])
        // Change upstream state before startup so the authoritative snapshot contains the restriction.
        let changed = expectation(description: "home")
        let pfeed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(object) = event.content,
                  let state = try? ContextCodec.decode(.object(object), as: ContextDecision.self), state.labels == ["home"] else { return }; changed.fulfill()
        })
        defer { pfeed.cancel() }
        source.send(["home"]); await fulfillment(of: [changed], timeout: 2)
        try assertOK(await filter.set(keypath: "filter.configure", value: ContextCodec.encode(configuration), requester: owner))
        try assertOK(await filter.set(keypath: "filter.configure", value: ContextCodec.encode(configuration), requester: owner))
        let value = try await filter.get(keypath: "filter.state", requester: owner)
        let state = try ContextCodec.decode(value, as: ContextDecision.self)
        XCTAssertEqual(state.labels, ["home"])
        let blocked = expectation(description: "work news blocked"); blocked.isInverted = true
        let feed = try await filter.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in if event.topic == "news.work" { blocked.fulfill() } })
        defer { feed.cancel() }
        news.send([], topic: "news.work")
        await fulfillment(of: [blocked], timeout: 0.2)
    }
}

extension PerspectiveContextTests {
    func testGoldenObservationFixturesRoundTripAndRejectInvalidExamples() throws {
        struct Fixture: Decodable { let valid: Bool; let evaluatedAt: Date; let observation: ContextObservation }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PerspectiveContext")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 5)
        for file in files {
            let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: file))
            if fixture.valid {
                XCTAssertNoThrow(try fixture.observation.validate(now: fixture.evaluatedAt), file.lastPathComponent)
                let encoded = try ContextCodec.encode(fixture.observation)
                XCTAssertEqual(try ContextCodec.decode(encoded, as: ContextObservation.self), fixture.observation)
            } else { XCTAssertThrowsError(try fixture.observation.validate(now: fixture.evaluatedAt), file.lastPathComponent) }
        }
    }
}

extension PerspectiveContextIntegrationTests {
    func testFreshDecodeAndOrdinaryFlowReconnectConfirmActiveState() async throws {
        let (owner, _, source, perspective) = try await fixture()
        let changed = expectation(description: "source at home")
        let feed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(object) = event.content,
                  let state = try? ContextCodec.decode(.object(object), as: ContextDecision.self), state.labels == ["home"] else { return }; changed.fulfill()
        })
        source.send(["home"]); await fulfillment(of: [changed], timeout: 2); feed.cancel()
        let restored = try JSONDecoder().decode(PerspectiveCell.self, from: JSONEncoder().encode(perspective))
        let bound = await restored.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(bound)
        let ordinaryFeed = try await restored.flow(requester: owner)
        let cancellable = ordinaryFeed.sink(receiveCompletion: { _ in }, receiveValue: { _ in }); defer { cancellable.cancel() }
        let value = try await restored.get(keypath: "perspective.context.state", requester: owner)
        let state = try ContextCodec.decode(value, as: ContextDecision.self)
        XCTAssertEqual(state.labels, ["home"])
        XCTAssertEqual(state.unknownSources, [])
    }
    func testStorageFailureDoesNotAcknowledgeOrApplyNewConfiguration() async throws {
        let (owner, _, _, perspective) = try await fixture()
        let old = perspective.contextState.configuration
        var changed = old; changed.rules[0].label = "changed"
        let oldName = perspective.name
        perspective.name = "../invalid-context-storage-component"
        defer { perspective.name = oldName }
        let result = try await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(changed), requester: owner)
        guard case let .object(object)? = result, case let .string(status)? = object["status"] else { return XCTFail("Missing failure receipt") }
        XCTAssertEqual(status, "error")
        XCTAssertEqual(perspective.contextState.configuration.rules.first?.label, old.rules.first?.label)
    }
}

extension PerspectiveContextIntegrationTests {
    func testPurposeAliasesUseOnePriorityWinnerAndDuplicateAliasesAreRejected() async throws {
        let (owner, _, source, perspective) = try await fixture()
        let purpose = Purpose(name: "Alias family", description: "Family")
        await perspective.context.upsertActivePurpose(weighedPurpose: Weight<Purpose>(weight: 0.5, value: purpose))
        let portable = try XCTUnwrap(PortableReference.make(kind: "purpose", localReference: purpose.reference, name: purpose.name))
        var configuration = perspective.contextState.configuration
        var high = configuration.rules[0]
        high.id = "high"; high.priority = 10; high.purposeWeights = [purpose.reference: 0]
        var low = high; low.id = "low"; low.priority = 1; low.purposeWeights = [portable: 1]
        configuration.rules = [low, high]
        try assertOK(await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: owner))
        XCTAssertEqual(perspective.contextState.configuration.rules[0].purposeWeights[purpose.reference], 1)
        XCTAssertNil(perspective.contextState.configuration.rules[0].purposeWeights[portable])
        let changed = expectation(description: "home aliases")
        let feed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(object) = event.content,
                  let state = try? ContextCodec.decode(.object(object), as: ContextDecision.self), state.labels == ["home"] else { return }; changed.fulfill()
        })
        defer { feed.cancel() }
        source.send(["home"]); await fulfillment(of: [changed], timeout: 2)
        let active = await perspective.effectiveActivePurposes(minWeight: 0, limit: 100)
        XCTAssertFalse(active.contains { ($0.reference ?? $0.value?.reference) == purpose.reference })
        configuration.rules = [high]
        configuration.rules[0].purposeWeights = [purpose.reference: 0, portable: 1]
        let result = try await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: owner)
        guard case let .object(object)? = result, case .string("error")? = object["status"] else { return XCTFail("Alias conflict accepted: \(String(describing: result))") }
        XCTAssertEqual(perspective.contextState.configuration.rules.count, 2)
    }
    func testCircularPerspectiveSourceReturnsErrorWithoutBlocking() async throws {
        let (owner, _, _, perspective) = try await fixture()
        let configuration = ContextConfiguration(sources: [.init(sourceID: "self", endpoint: "cell:///" + perspective.uuid)])
        let finished = expectation(description: "cycle rejected")
        Task {
            do {
                let result = try await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: owner)
                guard case let .object(object)? = result, case .string("error")? = object["status"] else { XCTFail("Cycle accepted: \(String(describing: result))"); finished.fulfill(); return }
            } catch { /* Rejection before the handler also terminates the cycle. */ }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }
}

extension PerspectiveContextTests {
    func testExploreGoalSchemaPublishesRequiredCodableFields() throws {
        func object(_ value: ValueType) throws -> Object {
            guard case let .object(result) = value else { throw ContextError.invalidConfiguration }; return result
        }
        func property(_ schema: ValueType, _ key: String) throws -> ValueType {
            let properties = try object(try XCTUnwrap(try object(schema)["properties"]))
            return try XCTUnwrap(properties[key])
        }
        func required(_ schema: ValueType) throws -> Set<String> {
            guard case let .list(keys)? = try object(schema)["requiredKeys"] else { throw ContextError.invalidConfiguration }
            return Set(keys.compactMap { if case let .string(value) = $0 { return value }; return nil })
        }
        let rules = try property(ContextSchemas.configuration(), "rules")
        let rule = try XCTUnwrap(try object(rules)["item"])
        let definition = try property(rule, "definition")
        XCTAssertEqual(try required(definition), Set(["schema", "goalID", "purposeRef", "title", "description", "lifecycle", "evaluatorKind", "evidenceSources", "helperCells", "privacy", "tags"]))
        let evidence = try property(definition, "evidenceSources")
        XCTAssertEqual(try required(XCTUnwrap(try object(evidence)["item"])), ["sourceID", "visibility"])
        XCTAssertEqual(try required(property(definition, "privacy")), ["rawEvidenceVisibility", "publishableStatuses", "doNotExportRawLocation"])
        let predicate = try property(definition, "predicate")
        guard case let .list(options)? = try object(predicate)["oneOf"] else { return XCTFail("missing predicate options") }
        XCTAssertEqual(try required(XCTUnwrap(options.first)), ["kind", "all", "any"])
        // Every advertised required definition field is genuinely required by Codable.
        let encoded = try object(ContextCodec.encode(config().rules[0].definition))
        for key in try required(definition) {
            var missing = encoded; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try ContextCodec.decode(.object(missing), as: GoalDefinition.self), key)
        }
        XCTAssertNoThrow(try ContextCodec.decode(.object(encoded), as: GoalDefinition.self))
    }
}

extension PerspectiveContextIntegrationTests {
    func testConcurrentCircularStartupRejectsBothRoots() async throws {
        let (owner, resolver, _, a) = try await fixture()
        let b = await PerspectiveCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: b.uuid, emitCell: b, scope: .scaffoldUnique, identity: owner)
        let first = ContextConfiguration(sources: [.init(sourceID: "b", endpoint: "cell:///" + b.uuid)])
        let second = ContextConfiguration(sources: [.init(sourceID: "a", endpoint: "cell:///" + a.uuid)])
        // Install the cyclic fixture before launching two independent startup roots.
        a.contextState = PerspectiveContextState(configuration: first)
        b.contextState = PerspectiveContextState(configuration: second)
        let finished = expectation(description: "both startup roots rejected"); finished.expectedFulfillmentCount = 2
        for (cell, configuration) in [(a, first), (b, second)] {
            Task {
                do {
                    let result = try await cell.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: owner)
                    guard case let .object(object)? = result, case .string("error")? = object["status"] else { XCTFail("Cycle accepted"); finished.fulfill(); return }
                } catch { /* Runtime rejection also terminates the cycle. */ }
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 3)
    }
    func testDetachedSourceEventsCannotChangeStateAndUnknownPurposeIsRejected() async throws {
        let (owner, _, source, perspective) = try await fixture()
        var bad = perspective.contextState.configuration
        bad.rules[0].purposeWeights = ["purpose://prompt.unknown": 1]
        let result = try await perspective.set(keypath: "perspective.context.configure", value: ContextCodec.encode(bad), requester: owner)
        guard case let .object(object)? = result, case .string("error")? = object["status"] else { return XCTFail("Unknown purpose accepted") }
        try assertOK(await perspective.set(keypath: "perspective.context.sources.detach", value: .string("place"), requester: owner))
        let before = perspective.contextState.revision
        let forbidden = expectation(description: "detached context change"); forbidden.isInverted = true
        let feed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in if event.topic == "perspective.context.changed" { forbidden.fulfill() } })
        defer { feed.cancel() }
        source.send(["home"])
        await fulfillment(of: [forbidden], timeout: 0.2)
        XCTAssertEqual(perspective.contextState.revision, before)
        XCTAssertEqual(perspective.contextState.decision(now: Date()).labels, [])
    }
    func testContextDepartureRestoresBaseFilterOnPortholeInput() async throws {
        let (owner, resolver, source, perspective) = try await fixture()
        let news = await SemanticSourceFixture(owner: owner)
        try await resolver.registerNamedEmitCell(name: news.uuid, emitCell: news, scope: .scaffoldUnique, identity: owner)
        let filter = await ContextFlowFilterCell(owner: owner)
        try await resolver.registerNamedEmitCell(name: filter.uuid, emitCell: filter, scope: .scaffoldUnique, identity: owner)
        let configuration = ContextFilterConfiguration(perspectiveEndpoint: "cell:///" + perspective.uuid, contentEndpoints: ["cell:///" + news.uuid], baseTopics: ["news.*"], topicsByLabel: ["home": ["news.family"]])
        try assertOK(await filter.set(keypath: "filter.configure", value: ContextCodec.encode(configuration), requester: owner))
        let root = await GeneralCell(owner: owner)
        _ = try await resolver.loadCell(from: CellConfiguration(name: "Departure input", cellReferences: [CellReference(endpoint: "cell:///" + filter.uuid, label: "filtered")]), into: root, requester: owner)
        source.send(["home"])
        try await waitForLabels(["home"], filter: filter, owner: owner)
        let blocked = expectation(description: "work blocked at home"); blocked.isInverted = true
        let firstFeed = try await root.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in if event.topic == "news.work" { blocked.fulfill() } })
        news.send([], topic: "news.work"); await fulfillment(of: [blocked], timeout: 0.2); firstFeed.cancel()
        source.send([])
        try await waitForLabels([], filter: filter, owner: owner)
        let restored = expectation(description: "work delivered after departure")
        let secondFeed = try await root.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in if event.topic == "news.work" { restored.fulfill() } })
        defer { secondFeed.cancel() }
        news.send([], topic: "news.work"); await fulfillment(of: [restored], timeout: 2)
    }
    private func waitForLabels(_ labels: [String], filter: ContextFlowFilterCell, owner: Identity) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let value = try await filter.get(keypath: "filter.state", requester: owner)
            if let decision = try? ContextCodec.decode(value, as: ContextDecision.self), decision.labels == labels { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Control decision did not reach filter: \(labels)")
    }
}

extension PerspectiveContextIntegrationTests {
    func testSourceSnapshotFailurePersistsDisconnectRevisionBeforeEmission() async throws {
        let (owner, _, source, perspective) = try await fixture()
        let emitted = expectation(description: "durable disconnect decision")
        var emittedRevision: Int?
        let feed = try await perspective.flow(requester: owner).sink(receiveCompletion: { _ in }, receiveValue: { event in
            guard event.topic == "perspective.context.changed", case let .object(object) = event.content,
                  let state = try? ContextCodec.decode(.object(object), as: ContextDecision.self), state.unknownSources == ["place"] else { return }
            emittedRevision = state.revision; emitted.fulfill()
        })
        defer { feed.cancel() }
        let before = perspective.contextState.revision
        // Simulate reconnect while the source's authoritative same-revision snapshot conflicts.
        perspective.contextSources.removeValue(forKey: "place")
        source.observation.labels = ["conflicting-snapshot"]
        let result = try await perspective.get(keypath: "perspective.context", requester: owner)
        guard case let .object(object) = result, case .string("error")? = object["status"] else { return XCTFail("Conflicting snapshot accepted: \(result)") }
        await fulfillment(of: [emitted], timeout: 2)
        let data = try await perspective.getFileDataInCellDirectory(filename: "PerspectiveContext.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(PerspectiveContextState.self, from: data)
        XCTAssertEqual(saved.revision, before + 1)
        XCTAssertEqual(saved.revision, emittedRevision)
        // A standalone restore can only emit revisions after the live filter's last revision.
        source.observation.labels = []
        let restored = try JSONDecoder().decode(PerspectiveCell.self, from: JSONEncoder().encode(perspective))
        let bound = await restored.bindStoredOwnerToRuntimeIdentity(owner); XCTAssertTrue(bound)
        let value = try await restored.get(keypath: "perspective.context.state", requester: owner)
        let decision = try ContextCodec.decode(value, as: ContextDecision.self)
        XCTAssertGreaterThan(decision.revision, try XCTUnwrap(emittedRevision))
    }
}
