// SPDX-License-Identifier: Apache-2.0
import Foundation

private enum PerspectiveRoutingConnectionScope {
    @TaskLocal static var hosts: Set<String> = []
}

private actor PerspectiveRoutingGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        if held { await withCheckedContinuation { waiters.append($0) } } else { held = true }
        defer { if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() } }
        return try await operation()
    }
}

/// Composition installed on the actual host PerspectiveCell. Sensing stays in
/// subscribed Cells; original human feedback uses the owner-private handlers.
/// Decisions use the existing concrete RelationalLearningCell, never a scorer copy.
public actor PerspectiveRoutingRuntime {
    public typealias Catalog = @Sendable (Identity) async -> [PerspectiveRoutingTarget]
    private weak var host: GeneralCell?
    private var owner: Identity
    private var catalog: Catalog
    private let sourceTopicOwnedByHost: Bool
    private let now: @Sendable () -> Date
    private let gate = PerspectiveRoutingGate()
    private var store: PerspectiveRoutingStore
    private var document: PerspectiveRoutingDocument
    private var motor: RelationalLearningCell?
    private var emitter: ((FlowElement) -> Void)?
    private var sources: [String: (configuration: ContextSource, cell: GeneralCell)] = [:]
    private var reconnectNeeded = true
    private var hostSession: PerspectiveRoutingHostSession?
    private var started = false
    private var hostRegistrations: [UUID: PerspectiveRoutingHostSession] = [:]
    private var closedHostInstances: Set<UUID> = []
    private var expiry: Task<Void, Never>?
    private var unavailable: String?
    private init(host: GeneralCell, owner: Identity, catalog: @escaping Catalog, sourceTopicOwnedByHost: Bool, now: @escaping @Sendable () -> Date) {
        self.host = host; self.owner = owner; self.catalog = catalog; self.sourceTopicOwnedByHost = sourceTopicOwnedByHost; self.now = now
        self.store = .init(ownerUUID: owner.uuid, cellUUID: host.uuid)
        self.document = .init(ownerUUID: owner.uuid, cellUUID: host.uuid)
    }
    deinit { expiry?.cancel() }
    public static func install(on host: GeneralCell, catalog: @escaping Catalog, sourceTopicOwnedByHost: Bool = false,
                               clock: @escaping @Sendable () -> Date = { Date() }) async throws -> PerspectiveRoutingRuntime {
        let verifiedOwner = await host.verifiedRuntimeOwnerIdentity()
        let runtime = PerspectiveRoutingRuntime(host: host, owner: verifiedOwner ?? host.storedOwnerIdentity, catalog: catalog, sourceTopicOwnedByHost: sourceTopicOwnedByHost, now: clock)
        try await runtime.bind()
        return runtime
    }
    /// Called by the owning host on identity/window teardown. The next host
    /// must restore and reconfirm its actual semantic sources.
    public func shutdown() async {
        await gate.run {
            self.expiry?.cancel(); self.expiry = nil; self.unavailable = "Routing host stopped."
            self.emitter = nil; self.hostSession = nil; self.hostRegistrations = [:]
            if let host = self.host {
                for id in Array(self.sources.keys) { await host.detachAndWait(label: "routing-source:" + id, requester: self.owner) }
            }
            self.sources = [:]
        }
    }
    private func bind() async throws {
        guard let host else { throw PerspectiveRoutingError.unavailable("Perspective unavailable") }
        guard let emitter = await host.makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner) else { throw FlowError.denied }
        self.emitter = emitter
        let response = ExploreContract.schema(type: "object")
        host.agreementTemplate.ensureGrant("r---", for: "perspective.routing.state")
        await host.registerGet(key: "perspective.routing.state", owner: owner, returns: response, permissions: ["r---"], description: .string("Owner-private learned routing state. Scores are functional gates, not calibrated probabilities.")) { [weak self, weak host] requester in
            guard let self, let host, host.identitiesReferenceSame(host.storedOwnerIdentity, requester),
                  await host.validateAccess("r---", at: "perspective.routing.state", for: requester) else { return .string("denied") }
            return await self.readState(requester: requester)
        }
        for action in ["configure", "feedback", "choosePurpose", "chooseConfiguration", "pause", "dismissNotice", "renderAcknowledged"] {
            let key = "perspective.routing." + action
            host.agreementTemplate.ensureGrant("-w--", for: key)
            await host.registerSet(key: key, owner: owner, input: ExploreContract.schema(type: "object"), returns: response, permissions: ["-w--"], flowEffects: [ExploreContract.flowEffect(trigger: .set, topic: "perspective.routing.changed", contentType: "object")], description: .string("Owner-private versioned Perspective routing action: \(action).")) { [weak self, weak host] requester, payload in
                guard let self, let host, host.identitiesReferenceSame(host.storedOwnerIdentity, requester),
                      await host.validateAccess("-w--", at: key, for: requester) else { return .string("denied") }
                return await self.perform(action, payload: payload, requester: requester)
            }
        }
        if !sourceTopicOwnedByHost {
            let installed = await host.addInterceptForTopic(requester: owner, topic: "context.observation.changed") { [weak self] element, label, _ in
                await self?.consumeAttachedSource(element, label: label)
                return nil
            }
            guard installed else { throw PerspectiveRoutingError.unavailable("routing source topic already bound") }
        }

    }
    private func startIfNeeded() async throws {
        guard !started else { return }
        guard owner.identityVault != nil else { throw PerspectiveRoutingError.unavailable("verified runtime owner required") }
        if let restored = try store.load() {
            // Replay the canonical engine to verify that each counted original
            // actually applied, rather than merely having a journal sequence.
            let verifier = RelationalLearningEngine()
            for record in restored.motorJournal.records {
                let result = try await verifier.applyEnvelopeTransaction(record.envelope)
                if record.envelope.eventType == .userFeedback, !result.applied {
                    throw PerspectiveRoutingError.unavailable("counted feedback did not apply in canonical replay")
                }
            }
            document = restored
        }
        motor = try await makeMotor(document.motorJournal)
        if document.configuration.enabled {
            document.state.loadRequest = nil; document.selectedPurpose = nil; document.selectedConfiguration = nil
            document.rendered = nil; document.renderedPurpose = nil
        }
        started = true
    }
    /// Only the trusted application/session adapter calls this direct runtime API.
    /// No Explore/Cell key can mint host sessions. Register once per actual host
    /// lifetime, close on identity/window/session teardown.
    public func openHostSession(hostInstanceID: UUID, requester: Identity, catalog hostCatalog: Catalog? = nil) async throws -> PerspectiveRoutingHostSession {
        try await gate.run {
            guard let host = self.host, await host.requesterProvesOwnership(requester) else { throw FlowError.denied }
            guard !self.closedHostInstances.contains(hostInstanceID) else { throw PerspectiveRoutingError.invalidInput("closed host instance") }
            if let hostCatalog { self.catalog = hostCatalog }
            if let existing = self.hostRegistrations[hostInstanceID] {
                if self.hostSession?.id != existing.id {
                    self.hostSession = existing
                    if self.document.configuration.enabled {
                        var candidate = self.document; self.beginEpisode(&candidate)
                        try await self.evaluate(&candidate); try self.commit(&candidate)
                    }
                }
                return existing
            }
            guard self.hostRegistrations.count < 32, self.closedHostInstances.count < 512 else { throw PerspectiveRoutingError.unavailable("host session capacity reached") }
            self.owner = requester; try await self.startIfNeeded()
            try self.verifyAuthorityRevision()
            let session = PerspectiveRoutingHostSession(id: UUID().uuidString, proof: UUID().uuidString + UUID().uuidString)
            self.hostRegistrations[hostInstanceID] = session
            self.hostSession = session
            if self.document.configuration.enabled {
                var candidate = self.document; self.beginEpisode(&candidate)
                try await self.evaluate(&candidate); try self.commit(&candidate)
            }
            return session
        }
    }
    public func closeHostSession(_ session: PerspectiveRoutingHostSession) async {
        await gate.run {
            guard let registration = self.hostRegistrations.first(where: { $0.value.id == session.id && $0.value.proof == session.proof }) else { return }
            self.hostRegistrations.removeValue(forKey: registration.key); self.closedHostInstances.insert(registration.key)
            guard self.hostSession?.id == session.id else { return }
            self.hostSession = nil
            var candidate = self.document; candidate.state.loadRequest = nil; candidate.state.phase = "waitingHost"
            do { try self.commit(&candidate) } catch { /* commit already retires unverified authority */ }
        }
    }
    // Internal fault admission for contract tests; never registered as a Cell operation.
    func replacePersistenceForTesting(_ factory: @escaping PerspectiveRoutingStore.Factory) { store.factory = factory }
    private func makeMotor(_ journal: RelationalLearningPersistedJournal) async throws -> RelationalLearningCell {
        let cell = try await RelationalLearningCell(owner: owner, restoring: journal)
        let receipt = try await cell.set(keypath: "versionAgreement", value: .object(["envelopeVersion": .string("2.0"), "journalVersion": .integer(2)]), requester: owner)
        guard case let .object(result)? = receipt, result["status"] == .string("ok") else { throw PerspectiveRoutingError.unavailable("learning version agreement failed") }
        return cell
    }
    private func motorJournal(_ cell: RelationalLearningCell) async throws -> RelationalLearningPersistedJournal {
        guard case let .object(payload) = try await cell.get(keypath: "journal", requester: owner) else { throw PerspectiveRoutingError.unavailable("learning journal unavailable") }
        return try RelationalLearningCodec.decode(RelationalLearningPersistedJournal.self, from: payload)
    }
    private func readState(requester: Identity? = nil) async -> ValueType {
        guard !PerspectiveRoutingConnectionScope.hosts.contains(document.cellUUID) else { return error(PerspectiveRoutingError.invalidInput("cyclic routing source")) }
        return await gate.run {
            do {
                if let reason = self.unavailable { return .object(["status": .string("unavailable"), "message": .string(reason), "enabled": .bool(false)]) }
                if let requester { self.owner = requester }
                try await self.startIfNeeded()
                try self.verifyAuthorityRevision()
                if self.reconnectNeeded, self.unavailable == nil {
                    try await self.connectSources()
                    self.reconnectNeeded = false
                    if self.document.configuration.enabled {
                        var resumed = self.document; self.beginEpisode(&resumed)
                        try await self.evaluate(&resumed); try self.commit(&resumed)
                    }
                }
                try await self.expireIfNeeded()
                if let request = self.document.state.loadRequest,
                   !(await self.visibleTargets(self.document).contains(where: { $0 == request.target })) {
                    var invalidated = self.document
                    invalidated.state.loadRequest = nil; invalidated.selectedConfiguration = nil
                    invalidated.state.phase = "noSuitableConfiguration"; invalidated.state.explanation = "Den valgte flaten er ikke lenger tilgjengelig."
                    try self.commit(&invalidated)
                }
                if let reason = self.unavailable { return .object(["status": .string("unavailable"), "message": .string(reason), "enabled": .bool(false)]) }
                try await self.expireIfNeeded()
                return try self.response()
            } catch { return self.error(error) }
        }
    }
    private func perform(_ action: String, payload: ValueType, requester: Identity) async -> ValueType {
        guard !PerspectiveRoutingConnectionScope.hosts.contains(document.cellUUID) else { return error(PerspectiveRoutingError.invalidInput("cyclic routing source")) }
        return await gate.run {
            do {
                self.owner = requester
                try await self.startIfNeeded()
                if let reason = self.unavailable { throw PerspectiveRoutingError.unavailable(reason) }
                try self.verifyAuthorityRevision()
                try await self.expireIfNeeded()
                switch action {
                case "configure":
                    let configuration = try ContextCodec.decode(payload, as: PerspectiveRoutingConfiguration.self)
                    try configuration.validate()
                    var candidate = self.document
                    candidate.configuration = configuration
                    candidate.failedTargets = []
                    try candidate.context.configure(.init(sources: configuration.sources))
                    self.beginEpisode(&candidate)
                    candidate.state.enabled = configuration.enabled
                    candidate.state.phase = configuration.enabled ? "waitingContext" : "disabled"
                    candidate.state.explanation = configuration.enabled ? "Venter på fersk kontekst fra godkjente kilder." : "Automatisk tilpasning er av."
                    try self.commit(&candidate)
                    self.reconnectNeeded = true
                    try await self.connectSources(); self.reconnectNeeded = false
                    var connected = self.document
                    try await self.evaluate(&connected); try self.commit(&connected)
                case "pause":
                    var candidate = self.document
                    candidate.configuration.enabled = false; candidate.state.enabled = false
                    candidate.state.loadRequest = nil; candidate.state.phase = "disabled"; candidate.state.explanation = "Automatisk tilpasning er satt på pause."
                    try self.commit(&candidate); try await self.connectSources()
                case "dismissNotice": return .object(["status": .string("ok"), "learning": .bool(false)])
                case "feedback", "choosePurpose", "chooseConfiguration":
                    let feedback = try ContextCodec.decode(payload, as: PerspectiveRoutingFeedback.self)
                    if action == "choosePurpose", feedback.kind != .purposeChoice { throw PerspectiveRoutingError.invalidInput("purpose choice required") }
                    if action == "chooseConfiguration", feedback.kind != .configurationChoice { throw PerspectiveRoutingError.invalidInput("configuration choice required") }
                    try await self.accept(feedback)
                case "renderAcknowledged": try await self.acknowledge(ContextCodec.decode(payload, as: PerspectiveRoutingRenderReceipt.self))
                default: throw PerspectiveRoutingError.invalidInput("unknown routing action")
                }
                return try self.response()
            } catch {
                if case PerspectiveRoutingError.persistenceConflict = error {
                    self.unavailable = "Routing authority changed in another instance; reconnect before retry."
                }
                return self.error(error)
            }
        }
    }
    private func verifyAuthorityRevision() throws {
        do {
            guard (try store.load()?.revision ?? 0) == document.revision else { throw PerspectiveRoutingError.persistenceConflict }
        } catch {
            unavailable = "Routing authority changed or could not be verified; reconnect required."
            document.state.loadRequest = nil; document.state.enabled = false; document.state.phase = "unavailable"
            document.state.revision += 1; emit(); throw error
        }
    }
    /// A synchronous actor read of committed authority. It intentionally does
    /// not acquire the mutation gate: catalog/discovery callbacks may ask for
    /// the old committed projection while a private candidate awaits them.
    public func committedPurposeProjection() -> PerspectiveRoutingPurposeProjection? {
        guard started, unavailable == nil else { return nil }
        do { try verifyAuthorityRevision() } catch { return nil }
        guard document.configuration.enabled, freshBlocks(document) != nil,
              document.state.phase != "choosePurpose", let selected = document.state.selectedPurposeRef,
              let purpose = document.configuration.purposes.first(where: { $0.id == selected }) else { return nil }
        return .init(revision: document.revision, selected: purpose, scope: document.configuration.purposes)
    }
    private func response() throws -> ValueType {
        .object(["status": .string("ok"), "state": try ContextCodec.encode(document.state)])
    }
    private func error(_ error: Error) -> ValueType { .object(["status": .string("error"), "message": .string(String(describing: error))]) }
    private func commit(_ candidate: inout PerspectiveRoutingDocument, motor candidateMotor: RelationalLearningCell? = nil) throws {
        // Last synchronous admission, after every scoring/catalog suspension.
        // An expiry task cannot enter the held mutation gate during those awaits.
        if candidate.configuration.enabled, freshBlocks(candidate) == nil {
            candidate.state.loadRequest = nil; candidate.state.selectedPurposeRef = nil
            candidate.selectedPurpose = nil; candidate.selectedConfiguration = nil
            candidate.rendered = nil; candidate.renderedPurpose = nil
            candidate.state.phase = "waitingContext"
            candidate.state.explanation = "Konteksten er ukjent eller utløpt. Beholder flaten som virker."
            candidate.state.purposeChoices = []; candidate.state.configurationChoices = []
            candidate.state.contextValidUntil = nil
        }
        candidate.revision = document.revision + 1; candidate.state.revision = candidate.revision
        if var request = candidate.state.loadRequest { request.decisionRevision = candidate.revision; candidate.state.loadRequest = request }
        do { try store.commit(candidate, replacing: document.revision) }
        catch {
            // A write/readback failure may have left newer authority on disk.
            // Retire old operative requests immediately, before any client can
            // validate or complete them. Reconnection must reconcile this ID.
            unavailable = "Routing authority is unverified after persistence failure; reconnect required."
            document.state.loadRequest = nil; document.state.enabled = false
            document.state.phase = "unavailable"; document.state.revision += 1
            emit(); throw error
        }
        document = candidate
        if let candidateMotor { motor = candidateMotor }
        emit(); scheduleExpiry()
    }
    private func emit() {
        guard case let .object(payload)? = try? ContextCodec.encode(document.state) else { return }
        var element = FlowElement(title: "Perspective", content: .object(payload), properties: .init(type: .event, contentType: .object))
        element.topic = "perspective.routing.changed"
        // A live subscription can inherit the TaskLocal from its original
        // connection setup. Published decisions start a notification boundary;
        // a client's subsequent state read is not a recursive source lookup.
        // Keep the cycle scope intact around actual source/snapshot resolution.
        PerspectiveRoutingConnectionScope.$hosts.withValue([]) { emitter?(element) }
    }
    private func beginEpisode(_ candidate: inout PerspectiveRoutingDocument) {
        candidate.state.episodeID = UUID().uuidString; candidate.state.loadRequest = nil
        candidate.selectedPurpose = nil; candidate.selectedConfiguration = nil; candidate.rendered = nil; candidate.renderedPurpose = nil
        candidate.state.selectedPurposeRef = nil
        candidate.episodeKinds = []
    }
    private func freshBlocks(_ candidate: PerspectiveRoutingDocument) -> [RelationalContextBlockSignal]? {
        let clock = now()
        guard !candidate.configuration.sources.isEmpty else { return nil }
        var blocks: [RelationalContextBlockSignal] = []
        for source in candidate.configuration.sources {
            guard candidate.context.confirmed.contains(source.sourceID), sources[source.sourceID]?.configuration == source,
                  let observation = candidate.context.observations[source.sourceID], observation.validUntil > clock,
                  observation.observedAt <= clock.addingTimeInterval(30), !observation.labels.isEmpty,
                  observation.transition != "left" else { return nil }
            for label in observation.labels { blocks.append(.init(domain: source.sourceID, blockId: label)) }
        }
        return blocks
    }
    private func visibleTargets(_ candidate: PerspectiveRoutingDocument) async -> [PerspectiveRoutingTarget] {
        let allowed = Set(candidate.configuration.configurations.map(\.node.id))
        let visible = await catalog(owner)
        let grouped = Dictionary(grouping: visible.filter { allowed.contains($0.reference.node.id) && (try? $0.reference.validate()) != nil }, by: { $0.reference.node.id })
        // Conflicting descriptors for the same exact identity do not acquire
        // authority from array order. The actual loader validates again.
        return grouped.values.compactMap { group in
            guard let first = group.first, group.allSatisfy({ $0 == first }) else { return nil }; return first
        }.sorted { $0.reference.node.id < $1.reference.node.id }
    }
    private func evidence(_ candidate: PerspectiveRoutingDocument, kind: RelationalUserFeedbackKind, purpose: String,
                          configuration: RelationalConfigurationReference? = nil) -> (Int, Int, Bool) {
        let accepted = candidate.accepted.values.filter {
            $0.motorApplied && $0.feedback.purposeRef == purpose &&
            (configuration == nil || $0.feedback.configuration == configuration)
        }
        let negativeKind: RelationalUserFeedbackKind = kind == .purposeChoice ? .purposeCorrection : .configurationCorrection
        let latestNegative = accepted.filter { $0.feedback.kind == negativeKind }.map(\.motorSequence).max() ?? 0
        // An accepted correction applies immediately in causal journal order,
        // including bounded clock skew. Only positive freshness waits for time.
        let positives = accepted.filter { $0.feedback.kind == kind && $0.motorSequence > latestNegative && $0.feedback.occurredAt <= now().timeIntervalSince1970 }
        let latestPositive = positives.map(\.motorSequence).max() ?? 0
        let events = positives.map(\.feedback), latest = events.map(\.occurredAt).max()
        return (events.count, Set(events.map(\.sessionID)).count,
                latestPositive > latestNegative && (latest.map { now().timeIntervalSince1970 - $0 <= 14*86400 } ?? false))
    }

    private func evaluate(_ candidate: inout PerspectiveRoutingDocument, using candidateMotor: RelationalLearningCell? = nil) async throws {
        candidate.state.enabled = candidate.configuration.enabled
        candidate.state.loadRequest = nil
        guard candidate.configuration.enabled else { candidate.state.phase = "disabled"; return }
        guard let blocks = freshBlocks(candidate) else {
            candidate.state.phase = "waitingContext"; candidate.state.explanation = "Konteksten er ukjent eller utløpt. Beholder flaten som virker."
            candidate.state.purposeChoices = []; candidate.state.configurationChoices = []; candidate.state.contextValidUntil = nil
            return
        }
        candidate.state.contextValidUntil = candidate.configuration.sources.compactMap { candidate.context.observations[$0.sourceID]?.validUntil }.min()
        guard let learning = candidateMotor ?? motor else { throw PerspectiveRoutingError.unavailable("learning Cell unavailable") }
        let timestamp = now().timeIntervalSince1970
        let purposeResult = try await learning.set(keypath: "scorePurposes", value: .object([
            "timestamp": .float(timestamp), "activeContextBlocks": .list(try blocks.map { .object(try RelationalLearningCodec.encodeObject($0)) })]), requester: owner)
        guard case let .object(result)? = purposeResult, result["status"] == .string("ok"), case let .list(values)? = result["scores"] else { throw PerspectiveRoutingError.unavailable("actual purpose scoring failed") }
        let scores = try values.map { value -> RelationalPurposeScore in guard case let .object(o) = value else { throw SetValueError.paramErr }; return try RelationalLearningCodec.decode(RelationalPurposeScore.self, from: o) }
        candidate.state.purposeChoices = candidate.configuration.purposes.map { purpose in
            let evidence = evidence(candidate, kind: .purposeChoice, purpose: purpose.id)
            let score = scores.first { $0.purposeId == purpose.id }?.score ?? 0
            return .init(id: purpose.id, title: purpose.title, score: score, evidenceCount: evidence.0, distinctSessionCount: evidence.1,
                         eligible: score >= 0.9 && evidence.0 >= 5 && evidence.1 >= 3 && evidence.2)
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let ranked = candidate.state.purposeChoices
        let purpose: String
        if let manual = candidate.selectedPurpose { purpose = manual }
        else if let first = ranked.first, first.eligible, first.score - (ranked.dropFirst().first?.score ?? 0) >= 0.2, !candidate.correctionPending { purpose = first.id }
        else {
            candidate.state.phase = "choosePurpose"; candidate.state.explanation = "Velg hva du ønsker å gjøre. Formålet er ikke entydig nok."
            candidate.state.selectedPurposeRef = nil; candidate.state.configurationChoices = []; return
        }
        candidate.state.selectedPurposeRef = purpose
        let targets = await visibleTargets(candidate).filter { $0.purposeRefs.contains(purpose) }
        guard !targets.isEmpty else { candidate.state.phase = "noSuitableConfiguration"; candidate.state.configurationChoices = []; candidate.state.explanation = "Fant ingen godkjent flate for dette formålet."; return }
        let configResult = try await learning.set(keypath: "scoreConfigurations", value: .object(["purposeId": .string(purpose), "timestamp": .float(timestamp), "candidateConfigurationIDs": .list(targets.map { .string($0.reference.node.id) })]), requester: owner)
        guard case let .object(configPayload)? = configResult, configPayload["status"] == .string("ok"), case let .list(configValues)? = configPayload["scores"] else { throw PerspectiveRoutingError.unavailable("actual configuration scoring failed") }
        let configScores = try configValues.map { value -> RelationalConfigurationScore in guard case let .object(o) = value else { throw SetValueError.paramErr }; return try RelationalLearningCodec.decode(RelationalConfigurationScore.self, from: o) }
        candidate.state.configurationChoices = targets.map { target in
            let evidence = evidence(candidate, kind: .confirmedOutcome, purpose: purpose, configuration: target.reference)
            let score = configScores.first { $0.configuration == target.reference }?.score ?? 0
            return .init(id: target.reference.node.id, title: target.name, score: score, evidenceCount: evidence.0, distinctSessionCount: evidence.1,
                         eligible: score >= 0.9 && evidence.0 >= 3 && evidence.1 >= 3 && evidence.2 && !candidate.failedTargets.contains(target.reference.node.id))
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let configs = candidate.state.configurationChoices
        let target: PerspectiveRoutingTarget
        let automatic: Bool
        if let manual = candidate.selectedConfiguration, let selected = targets.first(where: { $0.reference == manual }) { target = selected; automatic = false }
        else if let first = configs.first, first.eligible, first.score - (configs.dropFirst().first?.score ?? 0) >= 0.2,
                !candidate.correctionPending, let selected = targets.first(where: { $0.reference.node.id == first.id }) { target = selected; automatic = true }
        else { candidate.state.phase = "chooseConfiguration"; candidate.state.explanation = "Velg flate. Egnetheten er ikke entydig nok."; return }
        if let rendered = candidate.rendered, rendered.configuration == target.reference, candidate.renderedPurpose == purpose {
            let confirmed = candidate.episodeKinds.contains(candidate.state.episodeID + "|" + RelationalUserFeedbackKind.confirmedOutcome.rawValue)
            candidate.state.phase = confirmed ? "confirmed" : "rendered"
            candidate.state.explanation = confirmed ? "Takk. Det bekreftede resultatet er registrert." : "Flaten er klar. Fortell om formålet er løst."
            return
        }
        guard let hostSession else {
            candidate.state.phase = "waitingHost"; candidate.state.explanation = "Venter på en aktiv Porthole-økt."; return
        }
        candidate.state.phase = "loading"; candidate.state.explanation = automatic ? "Laster flaten som passer det lærte formålet." : "Laster flaten du valgte."
        candidate.state.loadRequest = .init(sessionID: hostSession.id, requestID: UUID().uuidString, decisionRevision: candidate.revision + 1,
            episodeID: candidate.state.episodeID, purposeRef: purpose, target: target, automatic: automatic)
    }
    private func accept(_ feedback: PerspectiveRoutingFeedback) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let payload = try encoder.encode(feedback)
        if let previous = document.accepted[feedback.eventID] {
            guard previous.canonicalPayload == payload else { throw PerspectiveRoutingError.invalidInput("feedback identity conflict") }; return
        }
        guard let hostSession, hostSession.id == feedback.sessionID, hostSession.proof == feedback.sessionProof,
              document.configuration.enabled, feedback.decisionRevision == document.state.revision,
              feedback.episodeID == document.state.episodeID, !feedback.eventID.isEmpty, !feedback.sessionID.isEmpty,
              feedback.sessionID.utf8.count <= 512, feedback.eventID.utf8.count <= 512,
              feedback.occurredAt.isFinite, abs(feedback.occurredAt - now().timeIntervalSince1970) <= 300,
              document.configuration.purposes.contains(where: { $0.id == feedback.purposeRef }),
              let blocks = freshBlocks(document), document.accepted.count < 2048 else { throw PerspectiveRoutingError.staleDecision }
        let episodeKey = feedback.episodeID + "|" + feedback.kind.rawValue
        guard !document.episodeKinds.contains(episodeKey) else { throw PerspectiveRoutingError.invalidInput("one original signal of this kind per episode") }
        var candidate = document
        let purposeFeedback = feedback.kind == .purposeChoice || feedback.kind == .purposeCorrection
        if !purposeFeedback {
            guard let configuration = feedback.configuration,
                  feedback.purposeRef == candidate.state.selectedPurposeRef,
                  await visibleTargets(candidate).contains(where: { $0.reference == configuration && $0.purposeRefs.contains(feedback.purposeRef) }) else { throw PerspectiveRoutingError.invalidInput("exact visible purpose/configuration correlation required") }
            if feedback.kind == .confirmedOutcome || feedback.kind == .configurationCorrection {
                guard let rendered = candidate.rendered, rendered.rendered, rendered.configuration == configuration,
                      rendered.sessionID == feedback.sessionID, rendered.episodeID == feedback.episodeID, candidate.renderedPurpose == feedback.purposeRef else { throw PerspectiveRoutingError.invalidInput("user-confirmed outcome requires actual correlated render") }
            }
        } else if feedback.configuration != nil { throw PerspectiveRoutingError.invalidInput("purpose signal cannot claim configuration utility") }
        guard freshBlocks(candidate) != nil else { throw PerspectiveRoutingError.staleDecision }
        let learning = try await makeMotor(candidate.motorJournal)
        guard freshBlocks(candidate) != nil else { throw PerspectiveRoutingError.staleDecision }
        let event = RelationalUserFeedbackEvent(eventId: feedback.eventID, timestamp: feedback.occurredAt,
            expectedJournalRevision: candidate.motorJournal.revision, sessionId: feedback.sessionID, episodeId: feedback.episodeID,
            purposeId: feedback.purposeRef, kind: feedback.kind, configuration: feedback.configuration, contextBlocks: purposeFeedback ? blocks : [])
        let result = try await learning.set(keypath: "userFeedback", value: .object(try RelationalLearningCodec.encodeObject(event)), requester: owner)
        guard case let .object(receipt)? = result, receipt["status"] == .string("ok"), receipt["applied"] == .bool(true) else { throw PerspectiveRoutingError.unavailable("learning Cell did not accept original feedback") }
        candidate.motorJournal = try await motorJournal(learning)
        guard freshBlocks(candidate) != nil else { throw PerspectiveRoutingError.staleDecision }
        candidate.accepted[feedback.eventID] = .init(feedback: feedback, canonicalPayload: payload, motorApplied: true, motorSequence: candidate.motorJournal.revision)
        candidate.episodeKinds.insert(episodeKey)
        switch feedback.kind {
        case .purposeChoice: candidate.selectedPurpose = feedback.purposeRef; candidate.correctionPending = false
        case .configurationChoice:
            candidate.selectedConfiguration = feedback.configuration; candidate.correctionPending = false
            if let target = feedback.configuration { candidate.failedTargets.remove(target.node.id) }
        case .purposeCorrection:
            guard candidate.state.selectedPurposeRef == feedback.purposeRef else { throw PerspectiveRoutingError.staleDecision }
            beginEpisode(&candidate); candidate.correctionPending = true
        case .configurationCorrection: beginEpisode(&candidate); candidate.selectedPurpose = feedback.purposeRef; candidate.correctionPending = true
        case .confirmedOutcome: break
        }
        try await evaluate(&candidate, using: learning)
        try commit(&candidate, motor: learning)
    }
    private func acknowledge(_ receipt: PerspectiveRoutingRenderReceipt) async throws {
        guard let hostSession, hostSession.id == receipt.sessionID, hostSession.proof == receipt.sessionProof,
              document.configuration.enabled, receipt.decisionRevision == document.state.revision,
              receipt.episodeID == document.state.episodeID, let request = document.state.loadRequest,
              request.sessionID == receipt.sessionID, request.requestID == receipt.requestID, request.target.reference == receipt.configuration,
              !receipt.sessionID.isEmpty, receipt.sessionID.utf8.count <= 512, freshBlocks(document) != nil,
              await visibleTargets(document).contains(where: { $0 == request.target }) else { throw PerspectiveRoutingError.staleDecision }
        guard freshBlocks(document) != nil else { throw PerspectiveRoutingError.staleDecision }
        var candidate = document; candidate.state.loadRequest = nil
        if receipt.rendered {
            candidate.rendered = receipt; candidate.renderedPurpose = request.purposeRef; candidate.state.activeConfiguration = receipt.configuration
            candidate.state.phase = "rendered"; candidate.state.explanation = "Flaten er klar. Fortell om formålet er løst."
        } else {
            candidate.failedTargets.insert(receipt.configuration.node.id); candidate.selectedConfiguration = nil
            candidate.state.phase = "chooseConfiguration"; candidate.state.explanation = "Flaten kunne ikke lastes. Beholder flaten som virker."
        }
        try commit(&candidate)
    }
    /// Dispatch only from the owning host's actual labelled Flow intercept.
    /// This direct composition hook is not a Cell action or a source grant.
    public func consumeAttachedSource(_ element: FlowElement, label: String) async {
        guard label.hasPrefix("routing-source:") else { return }
        await receive(element, sourceID: String(label.dropFirst("routing-source:".count)))
    }
    private func receive(_ element: FlowElement, sourceID: String) async {
        await gate.run {
            do {
                guard self.sources[sourceID] != nil, self.unavailable == nil else { return }
                try self.verifyAuthorityRevision()
                guard case let .object(payload) = element.content else { throw PerspectiveRoutingError.invalidInput("semantic observation object required") }
                let observation = try ContextCodec.decode(.object(payload), as: ContextObservation.self)
                try await self.ingest(observation, sourceID: sourceID, eventID: element.id, snapshot: false)
            } catch { CellBase.diagnosticLog("Perspective routing rejected source event: \(error)", domain: .flow) }
        }
    }
    private func ingest(_ observation: ContextObservation, sourceID: String, eventID: String, snapshot: Bool) async throws {
        var candidate = document
        guard try candidate.context.ingest(observation, sourceID: sourceID, eventID: eventID, snapshot: snapshot, now: now()) else { return }
        beginEpisode(&candidate)
        try await evaluate(&candidate); try commit(&candidate)
    }
    private func connectSources() async throws {
        guard !PerspectiveRoutingConnectionScope.hosts.contains(document.cellUUID) else { throw PerspectiveRoutingError.invalidInput("cyclic routing source") }
        try await PerspectiveRoutingConnectionScope.$hosts.withValue(PerspectiveRoutingConnectionScope.hosts.union([document.cellUUID])) {
            try await self.connectSourcesInScope()
        }
    }
    private func connectSourcesInScope() async throws {
        guard let host else { throw PerspectiveRoutingError.unavailable("Perspective unavailable") }
        let wanted = document.configuration.enabled ? document.configuration.sources : []
        for id in Array(sources.keys) where !wanted.contains(where: { $0 == sources[id]?.configuration }) {
            await host.detachAndWait(label: "routing-source:" + id, requester: owner); sources.removeValue(forKey: id)
            document.context.disconnect(id)
        }
        for source in wanted where sources[source.sourceID] == nil {
            guard let resolver = CellBase.defaultCellResolver,
                  let cell = try await resolver.cellAtEndpoint(endpoint: source.endpoint, requester: owner) as? GeneralCell else { throw PerspectiveRoutingError.unavailable("authorized context source unavailable") }
            guard cell.uuid != host.uuid else { throw PerspectiveRoutingError.invalidInput("Perspective cannot observe itself as a source") }
            let label = "routing-source:" + source.sourceID
            host.agreementTemplate.ensureGrant("rw--", for: label)
            guard try await host.attach(emitter: cell, label: label, requester: owner) == .connected else { throw PerspectiveRoutingError.unavailable("context source attachment failed") }
            sources[source.sourceID] = (source, cell)
            do {
                try await host.absorbFlow(label: label, requester: owner)
                let snapshot = try await cell.get(keypath: source.snapshotKey, requester: owner)
                let observation = try ContextCodec.decode(snapshot, as: ContextObservation.self)
                // Each current source revision is a distinct read snapshot, not
                // a replay of one universal event named "snapshot". Ordinary
                // Flow originals still retain their actual immutable event ID.
                try await ingest(observation, sourceID: source.sourceID, eventID: "snapshot:\(observation.revision)", snapshot: true)
            } catch {
                sources.removeValue(forKey: source.sourceID); document.context.disconnect(source.sourceID)
                await host.detachAndWait(label: label, requester: owner); throw error
            }
        }
    }
    private func expireIfNeeded() async throws {
        var candidate = document
        guard candidate.context.expire(now: now()) else { return }
        beginEpisode(&candidate); try await evaluate(&candidate); try commit(&candidate)
    }
    private func scheduleExpiry() {
        expiry?.cancel()
        guard document.configuration.enabled, let deadline = document.state.contextValidUntil else { return }
        let seconds = max(0.01, min(deadline.timeIntervalSince(now()), 86400))
        expiry = Task.detached { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)); try Task.checkCancellation() }
            catch { return }
            guard let self else { return }
            _ = await self.readState()
        }
    }
}
