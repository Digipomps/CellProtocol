// SPDX-License-Identifier: Apache-2.0
import Foundation

extension PerspectiveCell {
    func contextPayload() async -> ValueType {
        do {
            try await connectContextSources(requester: storedOwnerIdentity)
            let (decision, configuration) = try await currentContextSnapshot()
            return .object(["state": try ContextCodec.encode(decision), "configuration": try ContextCodec.encode(configuration)])
        } catch { return ContextCodec.error(error) }
    }

    func setupContextKeys(owner: Identity) async throws {
        do {
            let data = try await readPerspectiveFile(filename: "PerspectiveContext.json")
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            contextState = try decoder.decode(PerspectiveContextState.self, from: data)
        } catch {
            let e = error as NSError
            guard (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) || (e.domain == NSPOSIXErrorDomain && e.code == ENOENT) else { throw error }
        }
        contextEmitter = await makeCellOwnedFlowEmitterForRuntimeBinding(requester: owner)
        let object = ContextSchemas.acknowledgement()
        await registerGet(key: "perspective.context", owner: owner, returns: ContextSchemas.perspective(), permissions: ["r---"], description: .string("Semantic context and its current rule evidence.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "perspective", for: requester) else { return .string("denied") }
            return await self.contextPayload()
        }
        await registerSet(key: "perspective.context.configure", owner: owner, input: ContextSchemas.configuration(), returns: object, permissions: ["-w--"], description: .string("Configure semantic sources and context rules; source bindings must be explicitly authorized.")) { [weak self] requester, value in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "perspective", for: requester) else { return .string("denied") }
            do {
                var configuration = try ContextCodec.decode(value, as: ContextConfiguration.self)
                try configuration.validate()
                // Resolve aliases before priority selection so one Purpose has one weight.
                for index in configuration.rules.indices {
                    var canonical: [String: Double] = [:]
                    for (reference, weight) in configuration.rules[index].purposeWeights {
                        guard let purpose = await self.resolveContextPurpose(reference),
                              canonical[purpose.reference] == nil else { throw ContextError.invalidConfiguration }
                        canonical[purpose.reference] = weight
                    }
                    configuration.rules[index].purposeWeights = canonical
                }
                await self.contextConnectionGate.enter()
                await self.contextGate.enter()
                do {
                    let evaluationTime = Date()
                    var candidate = self.contextState; try candidate.configure(configuration)
                    candidate.expire(now: evaluationTime)
                    try await self.saveContextState(candidate)
                    self.contextState = candidate
                    self.emitContextDecision(now: evaluationTime)
                    await self.contextGate.leave()
                    await self.contextConnectionGate.leave()
                } catch { await self.contextGate.leave(); await self.contextConnectionGate.leave(); throw error }
                // Binding changes are serialized separately; attach must not hold the event transaction gate.
                try await self.connectContextSources(requester: owner)
                return .object(["status": .string("ok")])
            } catch { return ContextCodec.error(error) }
        }
        await registerSet(key: "perspective.context.sources.detach", owner: owner, input: ExploreContract.schema(type: "string"), returns: object, permissions: ["-w--"], description: .string("Detach and invalidate one semantic source.")) { [weak self] requester, value in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "perspective", for: requester) else { return .string("denied") }
            guard case let .string(sourceID) = value else { return .string("invalid_source") }
            await self.contextConnectionGate.enter()
            await self.contextGate.enter()
            var candidate = self.contextState
            var configuration = candidate.configuration
            guard let index = configuration.sources.firstIndex(where: { $0.sourceID == sourceID }) else {
                await self.contextGate.leave(); await self.contextConnectionGate.leave(); return .string("unknown_source")
            }
            configuration.sources[index].enabled = false
            do { try candidate.configure(configuration); try await self.saveContextState(candidate) }
            catch { await self.contextGate.leave(); await self.contextConnectionGate.leave(); return ContextCodec.error(error) }
            self.contextState = candidate
            self.contextSources.removeValue(forKey: sourceID)
            await self.contextGate.leave()
            await self.detachAndWait(label: "context:" + sourceID, requester: owner)
            do { try await self.disconnectContextSource(sourceID) }
            catch { await self.contextConnectionGate.leave(); return ContextCodec.error(error) }
            await self.contextConnectionGate.leave()
            return .object(["status": .string("ok")])
        }
        await registerSet(key: "perspective.context.sources.attach", owner: owner, input: ExploreContract.schema(type: "string"), returns: object, permissions: ["-w--"], description: .string("Re-enable one configured semantic source; source admission still applies.")) { [weak self] requester, value in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "perspective", for: requester) else { return .string("denied") }
            guard case let .string(sourceID) = value else { return .string("invalid_source") }
            await self.contextGate.enter()
            var configuration = self.contextState.configuration
            await self.contextGate.leave()
            guard let index = configuration.sources.firstIndex(where: { $0.sourceID == sourceID }) else { return .string("unknown_source") }
            configuration.sources[index].enabled = true
            do { return try await self.set(keypath: "perspective.context.configure", value: ContextCodec.encode(configuration), requester: requester) }
            catch { return ContextCodec.error(error) }
        }
        await addInterceptForTopic(requester: owner, topic: "context.observation.changed") { [weak self] event, label, _ in
            guard let self else { return nil }
            if label.hasPrefix("routing-source:") {
                await self.perspectiveRoutingRuntime?.consumeAttachedSource(event, label: label)
                return nil
            }
            let sourceID = String(label.dropFirst("context:".count))
            guard label.hasPrefix("context:") else { return nil }
            // Labels are assigned by this Cell's source binding, not event.origin.
            if case let .object(object) = event.content {
                do { try await self.ingestContext(try ContextCodec.decode(.object(object), as: ContextObservation.self), sourceID: sourceID, eventID: event.id, snapshot: false) }
                catch { CellBase.diagnosticLog("context event rejected: \(error)", domain: .flow) }
            }
            return nil
        }
    }

    func connectContextSources(requester: Identity) async throws {
        try await ContextConnectionScope.perform(uuid) {
            try await connectContextSourcesInScope(requester: requester)
        }
    }
    private func connectContextSourcesInScope(requester: Identity) async throws {
        await contextConnectionGate.enter()
        do {
            await contextGate.enter()
            let wanted = contextState.configuration.sources.filter(\.enabled)
            await contextGate.leave()
            for (id, binding) in contextSources where !wanted.contains(binding.configuration) {
                await detachAndWait(label: "context:" + id, requester: requester)
                await contextGate.enter(); contextSources.removeValue(forKey: id); await contextGate.leave()
                try await disconnectContextSource(id)
            }
            for source in wanted where contextSources[source.sourceID] == nil {
                guard let resolver = CellBase.defaultCellResolver,
                      let cell = try await resolver.cellAtEndpoint(endpoint: source.endpoint, requester: requester) as? GeneralCell else { throw ContextError.unknownSource }
                let label = "context:" + source.sourceID
                agreementTemplate.ensureGrant("rw--", for: label)
                let status = try await attach(emitter: cell, label: label, requester: requester)
                guard status == .connected else { throw ContextError.unknownSource }
                // Install binding before subscription so incoming events can be accepted.
                await contextGate.enter()
                contextSources[source.sourceID] = ContextRuntimeSource(configuration: source, cell: cell)
                await contextGate.leave()
                do {
                    try await absorbFlow(label: label, requester: requester)
                    let value = try await cell.get(keypath: source.snapshotKey, requester: requester)
                    let observation = try ContextCodec.decode(value, as: ContextObservation.self)
                    try await ingestContext(observation, sourceID: source.sourceID, eventID: "snapshot:\(observation.revision)", snapshot: true)
                } catch {
                    await contextGate.enter(); contextSources.removeValue(forKey: source.sourceID); await contextGate.leave()
                    await detachAndWait(label: label, requester: requester)
                    try await disconnectContextSource(source.sourceID)
                    throw error
                }
            }
            await contextConnectionGate.leave()
        } catch { await contextConnectionGate.leave(); throw error }
    }
    private func ingestContext(_ observation: ContextObservation, sourceID: String, eventID: String, snapshot: Bool) async throws {
        await contextGate.enter()
        do {
            guard let binding = contextSources[sourceID], contextState.configuration.sources.contains(binding.configuration) else { throw ContextError.unknownSource }
            var candidate = contextState
            let evaluationTime = Date()
            let updated = try candidate.ingest(observation, sourceID: sourceID, eventID: eventID, snapshot: snapshot, now: evaluationTime)
            let expired = candidate.expire(now: evaluationTime)
            if updated || expired {
                try await saveContextState(candidate)
                contextState = candidate
                emitContextDecision(now: evaluationTime)
            }
            await contextGate.leave()
        } catch { await contextGate.leave(); throw error }
    }
    private func saveContextState(_ state: PerspectiveContextState) async throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try await writePerspectiveFile(fileData: encoder.encode(state), filename: "PerspectiveContext.json")
    }
    private func currentContextSnapshot() async throws -> (ContextDecision, ContextConfiguration) {
        await contextGate.enter()
        do {
            let evaluationTime = Date()
            var candidate = contextState
            if candidate.expire(now: evaluationTime) {
                try await saveContextState(candidate); contextState = candidate; emitContextDecision(now: evaluationTime)
            }
            let decision = contextState.decision(now: evaluationTime), configuration = contextState.configuration
            await contextGate.leave()
            return (decision, configuration)
        } catch { await contextGate.leave(); throw error }
    }
    // Disconnect revisions must also survive a Perspective-only restart.
    private func disconnectContextSource(_ sourceID: String) async throws {
        await contextGate.enter()
        do {
            let evaluationTime = Date()
            var candidate = contextState
            candidate.disconnect(sourceID)
            candidate.expire(now: evaluationTime)
            if candidate.revision != contextState.revision {
                try await saveContextState(candidate)
                contextState = candidate
            }
            emitContextDecision(now: evaluationTime)
            await contextGate.leave()
        } catch { await contextGate.leave(); throw error }
    }
    private func emitContextDecision(now: Date) {
        let decision = contextState.decision(now: now)
        if decision != lastContextDecision {
            lastContextDecision = decision
            if let value = try? ContextCodec.encode(decision), case let .object(object) = value {
                var event = FlowElement(title: "Perspective context changed", content: .object(object), properties: .init(type: .event, contentType: .object))
                event.topic = "perspective.context.changed"; event.origin = uuid
                contextEmitter?(event)
            }
        }
        contextExpiryTask?.cancel()
        if let expiry = contextState.observations.values.map(\.validUntil).filter({ $0 > now }).min() {
            contextExpiryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, expiry.timeIntervalSinceNow) * 1_000_000_000)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.contextGate.enter()
                let evaluationTime = Date()
                var candidate = self.contextState
                do { if candidate.expire(now: evaluationTime) { try await self.saveContextState(candidate); self.contextState = candidate }; self.emitContextDecision(now: evaluationTime) }
                catch { CellBase.diagnosticLog("context expiry persistence failed: \(error)", domain: .flow) }
                await self.contextGate.leave()
            }
        }
    }
    private func resolveContextPurpose(_ reference: String) async -> Purpose? {
        if let purpose = await context.findPurposeByReference(reference) { return purpose }
        let active = await context.getActivePurposes(minWeight: 0, limit: Int.max)
        let known = active.compactMap { $0.value as? Purpose } + (await context.findPurpose(name: "*", weightedPurposes: []))
        return known.first { $0.reference == reference || PortableReference.make(kind: "purpose", localReference: $0.reference, name: $0.name) == reference }
    }
    func effectiveActivePurposes(minWeight: Double, limit: Int) async -> [Weight<Purpose>] {
        try? await connectContextSources(requester: storedOwnerIdentity)
        let overrides = (try? await currentContextSnapshot())?.0.purposeWeights ?? [:]
        var effective = [Weight<Purpose>]()
        for var weighted in await context.getActivePurposes(minWeight: 0, limit: Int.max) {
            let purpose = weighted.value as? Purpose
            let local = weighted.reference ?? purpose?.reference
            let portable = PortableReference.make(kind: "purpose", localReference: local, name: purpose?.name)
            if let override = local.flatMap({ overrides[$0] }) ?? portable.flatMap({ overrides[$0] }) { weighted.weight = override }
            effective.append(weighted)
        }
        let represented = Set(effective.compactMap { $0.reference ?? $0.value?.reference })
        for (reference, weight) in overrides where !represented.contains(reference) {
            if let purpose = await resolveContextPurpose(reference),
               !effective.contains(where: { ($0.reference ?? $0.value?.reference) == purpose.reference }) {
                effective.append(Weight<Purpose>(weight: weight, value: purpose))
            }
        }
        if let projection = await perspectiveRoutingRuntime?.committedPurposeProjection() {
            var scoped = Set(projection.scope.map(\.id))
            for purpose in projection.scope {
                if let resolved = await resolveContextPurpose(purpose.id) { scoped.insert(resolved.reference) }
            }
            effective.removeAll { weighted in
                let local = weighted.reference ?? weighted.value?.reference
                let portable = PortableReference.make(kind: "purpose", localReference: local, name: weighted.value?.name)
                return local.map(scoped.contains) ?? false || portable.map(scoped.contains) ?? false
            }
            let purpose: Purpose
            if let resolved = await resolveContextPurpose(projection.selected.id) { purpose = resolved }
            else {
                purpose = Purpose(name: projection.selected.title, description: "Owner-approved active purpose")
                purpose.nodeIdentifier = projection.selected.id
            }
            effective.append(Weight<Purpose>(weight: 1, value: purpose))
        }
        return Array(effective.filter { $0.weight > 0 && $0.weight >= minWeight }.sorted {
            $0.weight == $1.weight ? ($0.reference ?? $0.value?.reference ?? "") < ($1.reference ?? $1.value?.reference ?? "") : $0.weight > $1.weight
        }.prefix(max(0, limit)))
    }
}
struct ContextRuntimeSource { var configuration: ContextSource; var cell: GeneralCell }
