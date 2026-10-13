// SPDX-License-Identifier: Apache-2.0
@_spi(HAVENRuntime) import CellBase
import Foundation
import Combine

/// Content policy is downstream of admission. Semantic context never grants access.
public final class ContextFlowFilterCell: GeneralCell {
    private var configuration: ContextFilterConfiguration?
    private var decision: ContextDecision?
    private let gate = ContextTransactionGate()
    private let connectionGate = ContextTransactionGate()
    private var connectedConfiguration: ContextFilterConfiguration?
    public required init(owner: Identity) async { await super.init(owner: owner); try? await ensureRuntimeReady() }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
    public override func installCellRuntimeBindingsForAccess() async throws {
        let owner = storedOwnerIdentity
        agreementTemplate.ensureGrant("rw--", for: "filter")
        do {
            let data = try await getFileDataInCellDirectory(filename: "ContextFilter.json")
            configuration = try JSONDecoder().decode(ContextFilterConfiguration.self, from: data)
        } catch {
            let e = error as NSError
            guard (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError) || (e.domain == NSPOSIXErrorDomain && e.code == ENOENT) else { throw error }
        }
        let object = ContextSchemas.acknowledgement()
        await registerGet(key: "filter", owner: owner, returns: ContextSchemas.filterState(), permissions: ["r---"], description: .string("Configured content filter and latest semantic control state.")) { [weak self] requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "filter", for: requester) else { return .string("denied") }
            do {
                try await self.connectSources(requester: owner)
                await self.gate.enter()
                let config = self.configuration, decision = self.decision
                await self.gate.leave()
                return .object(["configuration": try config.map(ContextCodec.encode) ?? .null, "state": try decision.map(ContextCodec.encode) ?? .null])
            } catch { return ContextCodec.error(error) }
        }
        await registerSet(key: "filter.configure", owner: owner, input: ContextSchemas.filterConfiguration(), returns: object, permissions: ["-w--"], description: .string("Persist an owner-approved base policy and semantic restrictions, then connect authorized sources.")) { [weak self] requester, value in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "filter", for: requester) else { return .string("denied") }
            do {
                let config = try ContextCodec.decode(value, as: ContextFilterConfiguration.self)
                guard !config.perspectiveEndpoint.isEmpty, config.contentEndpoints.count <= 128, Set(config.contentEndpoints).count == config.contentEndpoints.count else { throw ContextError.invalidConfiguration }
                await self.connectionGate.enter()
                await self.gate.enter()
                do {
                    try await self.writeFileDataInCellDirectory(fileData: JSONEncoder().encode(config), filename: "ContextFilter.json")
                    if self.configuration != config { self.decision = nil }
                    self.configuration = config
                    await self.gate.leave()
                    await self.connectionGate.leave()
                } catch { await self.gate.leave(); await self.connectionGate.leave(); throw error }
                try await self.connectSources(requester: owner)
                return .object(["status": .string("ok")])
            } catch { return ContextCodec.error(error) }
        }
        await addInterceptForTopic(requester: owner, topic: "*") { [weak self] element, label, _ in
            guard let self else { return nil }
            await self.gate.enter()

            if label == "filter:perspective" {
                if element.topic == "perspective.context.changed", case let .object(object) = element.content,
                   let incoming = try? ContextCodec.decode(.object(object), as: ContextDecision.self),
                   (try? incoming.validate()) != nil,
                   self.connectedConfiguration == self.configuration,
                   self.decision == nil || incoming.revision > self.decision!.revision {
                    self.decision = incoming
                }
                await self.gate.leave(); return nil
            }
            guard label.hasPrefix("filter:content:"),
                  let config = self.configuration, self.connectedConfiguration == config,
                  config.permits(topic: element.topic, decision: self.decision, now: Date()) else { await self.gate.leave(); return nil }
            await self.gate.leave()
            return element
        }
    }
    private func connectSources(requester: Identity) async throws {
        try await ContextConnectionScope.perform(uuid) {
            try await connectSourcesInScope(requester: requester)
        }
    }
    private func connectSourcesInScope(requester: Identity) async throws {
        await connectionGate.enter()
        do {
            await gate.enter(); let config = configuration; await gate.leave()
            guard let config else { await connectionGate.leave(); return }
            if connectedConfiguration == config { await connectionGate.leave(); return }
            if let old = connectedConfiguration {
                await detachAndWait(label: "filter:perspective", requester: requester)
                for index in old.contentEndpoints.indices { await detachAndWait(label: "filter:content:\(index)", requester: requester) }
            }
            await gate.enter(); connectedConfiguration = nil; await gate.leave()
            guard let resolver = CellBase.defaultCellResolver else { throw ContextError.unknownSource }
            let perspective = try await resolver.cellAtEndpoint(endpoint: config.perspectiveEndpoint, requester: requester)
            agreementTemplate.ensureGrant("rw--", for: "filter:perspective")
            guard try await attach(emitter: perspective, label: "filter:perspective", requester: requester) == .connected else { throw ContextError.unknownSource }
            await gate.enter(); connectedConfiguration = config; await gate.leave()
            try await absorbFlow(label: "filter:perspective", requester: requester)
            guard let readable = perspective as? Meddle else { throw ContextError.unknownSource }
            let payload = try await readable.get(keypath: "perspective.context.state", requester: requester)
            let incoming = try ContextCodec.decode(payload, as: ContextDecision.self)
            try incoming.validate()
            await gate.enter()
            if let current = decision, incoming.revision == current.revision && incoming != current {
                await gate.leave(); throw ContextError.conflictingRevision
            }
            if decision == nil || incoming.revision > decision!.revision { decision = incoming }
            await gate.leave()
            for (index, endpoint) in config.contentEndpoints.enumerated() {
                let cell = try await resolver.cellAtEndpoint(endpoint: endpoint, requester: requester)
                let label = "filter:content:\(index)"
                agreementTemplate.ensureGrant("rw--", for: label)
                guard try await attach(emitter: cell, label: label, requester: requester) == .connected else { throw ContextError.unknownSource }
                try await absorbFlow(label: label, requester: requester)
            }
            await gate.enter(); connectedConfiguration = config; await gate.leave()
            await connectionGate.leave()
        } catch {
            await gate.enter(); decision = nil; connectedConfiguration = nil; await gate.leave()
            await detachAndWait(label: "filter:perspective", requester: requester)
            if let config = configuration { for index in config.contentEndpoints.indices { await detachAndWait(label: "filter:content:\(index)", requester: requester) } }
            await connectionGate.leave(); throw error
        }
    }
    public override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        // Admission is checked by the existing implementation before startup work.
        let publisher = try await super.flow(requester: requester)
        try await connectSources(requester: storedOwnerIdentity)
        return publisher
    }
}
