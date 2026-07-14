// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AppleIntelligenceCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 22/12/2025.
//

import Foundation
@_spi(HAVENRuntime) import CellBase
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple Intelligence assistant logic operating on a GeneralCell via Meddle.get/set.
// All publishing is deferred to Emit by writing Flow-ready messages into ai.outbox as ValueType.object entries.
// Your Emit implementation can drain ai.outbox, convert entries to FlowElement with appropriate properties/topic, and publish.

@available(macOS 26.0, iOS 26.0, *)
public class AppleIntelligenceCell: GeneralCell {
    private let builders = AIAssistantFlowBuilders()
    private let stateLock = NSLock()

    private static let maximumPromptUTF8Bytes = 65_536
    private static let maximumReferenceUTF8Bytes = 512
    private static let maximumPurposeClusterRefs = 256
    private static let maximumCandidates = 256
    private static let maximumEncodedCandidatesBytes = 1_048_576
    private static let maximumOutboxEntries = 256
    private static let maximumEncodedOutboxEntryBytes = 1_100_000
    private static let maximumEncodedOutboxBytes = 8_388_608
    private static let maximumEncodedRankWeightsBytes = 65_536
    private static let dequeueOutboxKey = "\(AIKeys.root).dequeueOutbox"

    private struct PersistedRuntimeState: Codable {
        private static let defaultPromptText = "Hva vil du hjelpe deg med i dag?"
        private static let defaultPromptInstructions = """

            Du er en assistent som skal bruke relasjoner i en graf for å finne likhet og sammenhenger.
        Ikke stol på navn/labels alene. Når du skal finne beslektede noder, bruk verktøyet "graph_match".
        Oppgi relasjonstype (types, parts, partOf, interests, purposes, entities, states), ønsket vekt og toleranse.
        Returner korte, handlingsrettede forslag basert på treffene.
        """

        var revision: Int
        var status: AIStatus
        var currentPurposeRef: String?
        var purposeClusterRefs: [String]
        var candidates: [CellConfiguration]
        var rankWeights: Object
        var outbox: ValueTypeList
        var outboxEntryEncodedBytes: [Int]
        var outboxEncodedBytes: Int
        var rankEnabled: Bool
        var promptText: String
        var promptInstructions: String
        var sendFlowOnIngest: Bool

        private enum CodingKeys: String, CodingKey {
            case revision
            case status
            case currentPurposeRef
            case purposeClusterRefs
            case candidates
            case rankWeights
            case outbox
            case rankEnabled
            case promptText
            case promptInstructions
            case sendFlowOnIngest
        }

        init() {
            revision = 0
            status = .idle
            currentPurposeRef = nil
            purposeClusterRefs = []
            candidates = []
            rankWeights = [:]
            outbox = []
            outboxEntryEncodedBytes = []
            outboxEncodedBytes = 2
            rankEnabled = false
            promptText = Self.defaultPromptText
            promptInstructions = Self.defaultPromptInstructions
            sendFlowOnIngest = true
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = max(0, try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0)
            status = try container.decodeIfPresent(AIStatus.self, forKey: .status) ?? .idle

            let decodedPurposeRef = try container.decodeIfPresent(
                String.self,
                forKey: .currentPurposeRef
            )
            currentPurposeRef = decodedPurposeRef.flatMap {
                Self.boundedString($0, maximumUTF8Bytes: AppleIntelligenceCell.maximumReferenceUTF8Bytes)
            }

            let decodedClusterRefs = try container.decodeIfPresent(
                [String].self,
                forKey: .purposeClusterRefs
            ) ?? []
            purposeClusterRefs = Array(
                decodedClusterRefs
                    .lazy
                    .filter { !$0.isEmpty && $0.utf8.count <= AppleIntelligenceCell.maximumReferenceUTF8Bytes }
                    .prefix(AppleIntelligenceCell.maximumPurposeClusterRefs)
            )

            candidates = Self.boundedCandidates(
                try container.decodeIfPresent(
                    [CellConfiguration].self,
                    forKey: .candidates
                ) ?? []
            )

            let decodedRankWeights = try container.decodeIfPresent(
                Object.self,
                forKey: .rankWeights
            ) ?? [:]
            rankWeights = Self.encodedSize(
                decodedRankWeights,
                isAtMost: AppleIntelligenceCell.maximumEncodedRankWeightsBytes
            ) ? decodedRankWeights : [:]

            let boundedOutbox = Self.boundedOutbox(
                try container.decodeIfPresent(ValueTypeList.self, forKey: .outbox) ?? []
            )
            outbox = boundedOutbox.entries
            outboxEntryEncodedBytes = boundedOutbox.entryEncodedBytes
            outboxEncodedBytes = boundedOutbox.totalEncodedBytes
            rankEnabled = try container.decodeIfPresent(Bool.self, forKey: .rankEnabled) ?? false

            let decodedPrompt = try container.decodeIfPresent(String.self, forKey: .promptText)
            promptText = decodedPrompt.flatMap {
                Self.boundedString($0, maximumUTF8Bytes: AppleIntelligenceCell.maximumPromptUTF8Bytes)
            } ?? Self.defaultPromptText

            let decodedInstructions = try container.decodeIfPresent(
                String.self,
                forKey: .promptInstructions
            )
            promptInstructions = decodedInstructions.flatMap {
                Self.boundedString($0, maximumUTF8Bytes: AppleIntelligenceCell.maximumPromptUTF8Bytes)
            } ?? Self.defaultPromptInstructions
            sendFlowOnIngest = try container.decodeIfPresent(
                Bool.self,
                forKey: .sendFlowOnIngest
            ) ?? true
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revision, forKey: .revision)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(currentPurposeRef, forKey: .currentPurposeRef)
            try container.encode(purposeClusterRefs, forKey: .purposeClusterRefs)
            try container.encode(candidates, forKey: .candidates)
            try container.encode(rankWeights, forKey: .rankWeights)
            try container.encode(outbox, forKey: .outbox)
            try container.encode(rankEnabled, forKey: .rankEnabled)
            try container.encode(promptText, forKey: .promptText)
            try container.encode(promptInstructions, forKey: .promptInstructions)
            try container.encode(sendFlowOnIngest, forKey: .sendFlowOnIngest)
        }

        private static func boundedString(
            _ value: String,
            maximumUTF8Bytes: Int
        ) -> String? {
            value.utf8.count <= maximumUTF8Bytes ? value : nil
        }

        private static func boundedCandidates(
            _ decoded: [CellConfiguration]
        ) -> [CellConfiguration] {
            var retained: [CellConfiguration] = []
            var encodedBytes = 2
            for candidate in decoded.prefix(AppleIntelligenceCell.maximumCandidates) {
                guard let data = try? JSONEncoder().encode(candidate) else { continue }
                let additionalBytes = data.count + (retained.isEmpty ? 0 : 1)
                guard encodedBytes + additionalBytes <= AppleIntelligenceCell.maximumEncodedCandidatesBytes else {
                    break
                }
                retained.append(candidate)
                encodedBytes += additionalBytes
            }
            return retained
        }

        private static func boundedOutbox(
            _ decoded: ValueTypeList
        ) -> (entries: ValueTypeList, entryEncodedBytes: [Int], totalEncodedBytes: Int) {
            var retained: ValueTypeList = []
            var retainedSizes: [Int] = []
            var encodedBytes = 2
            for entry in decoded.prefix(AppleIntelligenceCell.maximumOutboxEntries) {
                guard let data = try? JSONEncoder().encode(entry),
                      data.count <= AppleIntelligenceCell.maximumEncodedOutboxEntryBytes else {
                    continue
                }
                let additionalBytes = data.count + (retained.isEmpty ? 0 : 1)
                guard encodedBytes + additionalBytes <= AppleIntelligenceCell.maximumEncodedOutboxBytes else {
                    break
                }
                retained.append(entry)
                retainedSizes.append(data.count)
                encodedBytes += additionalBytes
            }
            return (retained, retainedSizes, encodedBytes)
        }

        private static func encodedSize<T: Encodable>(
            _ value: T,
            isAtMost limit: Int
        ) -> Bool {
            guard let encoded = try? JSONEncoder().encode(value) else { return false }
            return encoded.count <= limit
        }
    }

    private enum RuntimeStateError: Error {
        case unsupportedKey(String)
        case invalidValue(String)
        case unauthorized
    }

    enum RuntimeMutationOutcome: String {
        case updated
        case unchanged
        case unavailable
        case conflict
    }

    private var runtimeState = PersistedRuntimeState()
    private var transientLastToolArguments: ValueType?
    private var activeDiscoveryGeneration: UUID?
    
    
    let detailedInstuctions = """
    
            Du er en personlig hjelper som skal gjøre ditt ytterste for å hjelpe brukeren til å nå sitt mål
    
        Du er en assistent som skal bruke relasjoner i en graf for å finne likhet og sammenhenger.
    Ikke stol på navn/labels alene. Når du skal finne beslektede noder, bruk verktøyet "graph_match".
    Oppgi relasjonstype (types, parts, partOf, interests, purposes, entities, states), ønsket vekt og toleranse.
    Returner korte, handlingsrettede forslag basert på treffene.
    """
    
    public required init(owner: Identity) async {
        await super.init(owner: owner)
        CellBase.diagnosticLog("AppleIntelligenceCell init owner=\(owner.uuid)", domain: .lifecycle)
        _ = await self.ensurePurpose(perspective: Perspective(), requester: owner)
        _ = await self.buildCluster(requester: owner)
        try? await ensureRuntimeReady()
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeState
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runtimeState = try container.decodeIfPresent(
            PersistedRuntimeState.self,
            forKey: .runtimeState
        ) ?? PersistedRuntimeState()
        if runtimeState.status == .discovering {
            runtimeState.status = .idle
            runtimeState.revision += 1
        }
        try super.init(from: decoder)
    }

    public override func installCellRuntimeBindingsForAccess() async throws {
        let bindingOwner = storedOwnerIdentity
        await setupPermissions(owner: bindingOwner)
        await setupKeys(owner: bindingOwner)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stateSnapshot(), forKey: .runtimeState)
    }

    private func stateSnapshot() -> PersistedRuntimeState {
        stateLock.withLock { runtimeState }
    }

    @discardableResult
    private func updateState<T>(_ update: (inout PersistedRuntimeState) throws -> T) rethrows -> T {
        try stateLock.withLock {
            try update(&runtimeState)
        }
    }

    private func readOnlyStateValue(for key: String) throws -> ValueType {
        let state = stateSnapshot()
        switch key {
        case AIKeys.status:
            return .string(state.status.rawValue)
        case AIKeys.currentPurposeRef:
            return state.currentPurposeRef.map(ValueType.string) ?? .null
        case AIKeys.purposeClusterRefs:
            return .list(state.purposeClusterRefs.map(ValueType.string))
        case AIKeys.candidates:
            return .list(state.candidates.map(ValueType.cellConfiguration))
        case AIKeys.rankWeights:
            return .object(state.rankWeights)
        case AIKeys.outbox:
            return .list(state.outbox)
        case AIKeys.lastToolArguments:
            return stateLock.withLock { transientLastToolArguments } ?? .object([:])
        default:
            throw RuntimeStateError.unsupportedKey(key)
        }
    }

    func storeLastToolArguments(_ value: ValueType, requester: Identity) async {
        guard await requesterIsRuntimeOwner(requester),
              isBoundedValue(value, maximumBytes: Self.maximumEncodedRankWeightsBytes) else {
            return
        }
        stateLock.withLock {
            transientLastToolArguments = value
        }
    }

    private func requesterIsRuntimeOwner(_ requester: Identity) async -> Bool {
        guard requester.referencesSameSigningIdentity(as: storedOwnerIdentity) else {
            return false
        }
        return await verifyRequesterIdentityControl(requester)
    }



    private func setupPermissions(owner: Identity) async {
        // Allow skeleton and flow to read AI state from this cell
        self.agreementTemplate.ensureGrant("rw--", for: AIKeys.root)
        self.agreementTemplate.ensureGrant("r---", for: "flow")
    }

    private func setupKeys(owner: Identity) async {
        await registerContracts(requester: owner)

        for key in [
            AIKeys.status,
            AIKeys.currentPurposeRef,
            AIKeys.purposeClusterRefs,
            AIKeys.candidates,
            AIKeys.rankWeights
        ] {
            await addInterceptForGet(
                requester: owner,
                key: "\(AIKeys.root).\(key)"
            ) { [weak self] _, _ in
                guard let self else { return .null }
                return try self.readOnlyStateValue(for: key)
            }
        }

        for ownerOnlyKey in [AIKeys.outbox, AIKeys.lastToolArguments] {
            await addInterceptForGet(
                requester: owner,
                key: "\(AIKeys.root).\(ownerOnlyKey)"
            ) { [weak self] _, requester in
                guard let self else { return .null }
                guard await self.requesterIsRuntimeOwner(requester) else {
                    throw RuntimeStateError.unauthorized
                }
                return try self.readOnlyStateValue(for: ownerOnlyKey)
            }
        }

        // GET ai.state snapshot
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).state", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            return self.snapshotPayload()
        })

        await addInterceptForSet(
            requester: owner,
            key: Self.dequeueOutboxKey
        ) { [weak self] _, _, requester in
            guard let self else { return .null }
            guard await self.requesterIsRuntimeOwner(requester) else {
                throw RuntimeStateError.unauthorized
            }
            return self.dequeueOutboxMessageForOwner() ?? .null
        }

        // SET ai.discover -> trigger discovery
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).discover", setValueIntercept: { [weak self] keypath, value, requester in
            CellBase.diagnosticLog("AppleIntelligenceCell set intercept keypath=\(keypath)", domain: .flow)
            guard let self = self else { return .string("failure") }
            return .string(await self.discover(requester: requester))
        })

        // SET ai.rank -> trigger ranking
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).rank", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            return .string(
                await self.rank(perspective: Perspective(), requester: requester)
                    ? "ok"
                    : "conflict"
            )
        })

        // SET ai.ensurePurpose
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).ensurePurpose", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            return .string(
                await self.ensurePurpose(perspective: Perspective(), requester: requester).rawValue
            )
        })

        // SET ai.buildCluster
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).buildCluster", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            return .string(await self.buildCluster(requester: requester).rawValue)
        })

        // GET/SET ai.promptText
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptText)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .string("") }
            return .string(self.stateSnapshot().promptText)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptText)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            guard case let .string(newValue) = value,
                  self.isBoundedString(newValue, maximumUTF8Bytes: Self.maximumPromptUTF8Bytes) else {
                return .string("paramErr")
            }
            self.updateState { state in
                state.promptText = newValue
                state.revision += 1
            }
            return .string("New promtpt text: \(newValue)")
        })

        // GET/SET ai.promptInstructions
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptInstructions)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .string("") }
            return .string(self.stateSnapshot().promptInstructions)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptInstructions)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            guard case let .string(newValue) = value,
                  self.isBoundedString(newValue, maximumUTF8Bytes: Self.maximumPromptUTF8Bytes) else {
                return .string("paramErr")
            }
            self.updateState { state in
                state.promptInstructions = newValue
                state.revision += 1
            }
            return .string("New prompt instructions: \(newValue)")
        })

        // GET/SET ai.sendFlowOnIngest
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .bool(true) }
            return .bool(self.stateSnapshot().sendFlowOnIngest)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            guard case .bool(let newValue) = value else { return .string("paramErr") }
            self.updateState { state in
                state.sendFlowOnIngest = newValue
                state.revision += 1
            }
            return .string("New sendFlowOnIngest: \(newValue)")
        })

        // GET/SET ai.rankEnabled
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.rankEnabled)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .bool(true) }
            return .bool(self.stateSnapshot().rankEnabled)
        })
        
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.rankEnabled)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            guard case .bool(let newValue) = value else { return .string("failure") }
            self.updateState { state in
                state.rankEnabled = newValue
                state.revision += 1
            }
            return .bool(newValue)
        })

        // SET ai.ingestConfigurations with payload
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).ingestConfigurations", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            return .string(
                await self.ingestConfigurations(from: value, requester: requester)
                    ? "ok"
                    : "paramErr"
            )
        })

        // SET ai.send -> append one validated Flow-shaped message to the explicit outbox.
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).send", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            guard case let .object(obj) = value,
                  let content = obj["content"],
                  content != .null,
                  Self.isSupportedSendContent(content),
                  obj["endpoint"] == nil else {
                return .string("paramErr")
            }

            let topic: String
            if let rawTopic = obj["topic"] {
                guard case let .string(value) = rawTopic, !value.isEmpty else {
                    return .string("paramErr")
                }
                topic = value
            } else {
                topic = AITopics.requestConfigs
            }

            let title: String
            if let rawTitle = obj["title"] {
                guard case let .string(value) = rawTitle else {
                    return .string("paramErr")
                }
                title = value
            } else {
                title = ""
            }

            let type: FlowElementType
            if let rawType = obj["type"] {
                guard case let .string(value) = rawType,
                      let parsedType = FlowElementType(rawValue: value) else {
                    return .string("paramErr")
                }
                type = parsedType
            } else {
                type = .event
            }

            let queued = self.enqueueOutboxMessage(
                topic: topic,
                type: type,
                content: content,
                title: title,
                requester: requester
            )
            return .string(queued ? "queued" : "outboxFull")
        })

        // SET ai.sendPrompt -> generate first, then atomically enqueue prompt and response.
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).sendPrompt", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }

            var topic: String = AITopics.exploreRequest
            var title: String = "Prompt"
            var type: FlowElementType = .event
            let storedInstructions = self.stateSnapshot().promptInstructions
            var instructionsText = storedInstructions.isEmpty
                ? "You are a helpful assistant. Keep answers concise."
                : storedInstructions

            let promptString: String
            switch value {
            case let .string(prompt) where !prompt.isEmpty:
                promptString = prompt
            case let .object(obj):
                guard case let .string(prompt)? = obj["prompt"],
                      !prompt.isEmpty,
                      obj["content"] == nil,
                      obj["endpoint"] == nil else {
                    return .string("paramErr")
                }
                promptString = prompt
                if let rawTopic = obj["topic"] {
                    guard case let .string(value) = rawTopic, !value.isEmpty else {
                        return .string("paramErr")
                    }
                    topic = value
                }
                if let rawTitle = obj["title"] {
                    guard case let .string(value) = rawTitle else {
                        return .string("paramErr")
                    }
                    title = value
                }
                if let rawType = obj["type"] {
                    guard case let .string(value) = rawType,
                          let parsedType = FlowElementType(rawValue: value) else {
                        return .string("paramErr")
                    }
                    type = parsedType
                }
                if let rawInstructions = obj["instructions"] {
                    guard case let .string(value) = rawInstructions else {
                        return .string("paramErr")
                    }
                    instructionsText = value
                }
            default:
                return .string("paramErr")
            }

            guard self.isBoundedString(promptString, maximumUTF8Bytes: Self.maximumPromptUTF8Bytes),
                  self.isBoundedString(instructionsText, maximumUTF8Bytes: Self.maximumPromptUTF8Bytes) else {
                return .string("paramErr")
            }

            var messages = [self.outboxMessage(
                topic: topic,
                type: type,
                content: .string(promptString),
                title: title
            )]
            if let aiText = await self.aiGenerateResponse(prompt: promptString, instructions: instructionsText, requester: requester), !aiText.isEmpty {
                messages.append(self.outboxMessage(
                    topic: topic,
                    type: .content,
                    content: .string(aiText),
                    title: "Response"
                ))
            }

            return .string(self.enqueueOutboxMessages(messages) ? "queued" : "outboxFull")
        })

    }

    // MARK: - Direct AI operations (formerly in AIAssistant)
    private func buildCluster(requester: Identity) async -> RuntimeMutationOutcome {
        _ = requester
        return updateState { state in
            guard let currentPurposeRef = state.currentPurposeRef else {
                return .unavailable
            }
            guard state.purposeClusterRefs.isEmpty else {
                return .unchanged
            }
            state.purposeClusterRefs = [currentPurposeRef]
            state.revision += 1
            return .updated
        }
    }

#if canImport(FoundationModels)
    private func makeIntelligenceSession(requester: Identity) -> LanguageModelSession {
        LanguageModelSession(
            tools: [GraphMatchTool(requester: requester)],
            instructions: Instructions {
                "Your job is to find purposes to fill into your day."
                "Each day needs to be fulfilled by one or more purposes."
                "Always use GraphMatchTool to find related purposes and interests."
            }
        )
    }
#endif

    func beginDiscoveryGeneration() -> UUID? {
        stateLock.withLock {
            guard activeDiscoveryGeneration == nil else { return nil }
            let generation = UUID()
            activeDiscoveryGeneration = generation
            runtimeState.status = .discovering
            runtimeState.revision += 1
            return generation
        }
    }

    @discardableResult
    func finishDiscoveryGeneration(_ generation: UUID, status: AIStatus) -> Bool {
        stateLock.withLock {
            guard activeDiscoveryGeneration == generation else { return false }
            activeDiscoveryGeneration = nil
            runtimeState.status = status
            runtimeState.revision += 1
            return true
        }
    }

    private func discover(requester: Identity) async -> String {
        guard let generation = beginDiscoveryGeneration() else { return "busy" }

        do {
            let state = stateSnapshot()
            var pendingMessages: ValueTypeList = [outboxMessage(
                topic: AITopics.exploreRequest,
                type: .event,
                content: builders.requestPayload(
                    currentPurposeRef: state.currentPurposeRef,
                    purposeClusterRefs: state.purposeClusterRefs
                ),
                title: "AI Discover"
            )]

#if canImport(FoundationModels)
            let session = makeIntelligenceSession(requester: requester)
            let stream = session.streamResponse(
                generating: PurposeWrapper.self,
                includeSchemaInPrompt: false,
                options: GenerationOptions(sampling: .greedy)
            ) {
                "Generate 5 suggestions of Purposes"
                "Generate a list of purposes relevant to the user's current situation."
                "Give each suggestion a concise title and description."
            }
            var counter = 0
            for try await partialResponse in stream {
                counter += 1
                pendingMessages.append(outboxMessage(
                    topic: AITopics.recommendations,
                    type: .content,
                    content: .string(partialResponse.content.description ?? ""),
                    title: "Suggestion no: \(counter) - \(partialResponse.content.title ?? "")"
                ))
            }
#endif

            let finalState = stateSnapshot()
            let snapshot = builders.statePayload(
                status: AIStatus.ready.rawValue,
                currentPurposeRef: finalState.currentPurposeRef,
                purposeClusterRefs: finalState.purposeClusterRefs,
                candidates: finalState.candidates
            )
            pendingMessages.append(outboxMessage(
                topic: AITopics.state,
                type: .content,
                content: snapshot
            ))

            guard commitDiscoveryGeneration(generation, messages: pendingMessages) else {
                _ = finishDiscoveryGeneration(generation, status: .error)
                return "outboxFull"
            }
            return "updated"
        } catch {
            _ = finishDiscoveryGeneration(generation, status: .error)
            CellBase.diagnosticLog("Apple Intelligence discovery failed: \(error)", domain: .flow)
            return "error"
        }
    }

    private func commitDiscoveryGeneration(
        _ generation: UUID,
        messages: ValueTypeList
    ) -> Bool {
        let messageSizes = messages.compactMap {
            encodedSize(of: $0, maximumBytes: Self.maximumEncodedOutboxEntryBytes)
        }
        guard messageSizes.count == messages.count else { return false }

        return stateLock.withLock {
            guard activeDiscoveryGeneration == generation else { return false }
            let additionalBytes = zip(messages.indices, messageSizes).reduce(0) { total, pair in
                total + pair.1 + ((runtimeState.outbox.isEmpty && pair.0 == messages.startIndex) ? 0 : 1)
            }
            guard runtimeState.outbox.count + messages.count <= Self.maximumOutboxEntries,
                  runtimeState.outboxEncodedBytes + additionalBytes <= Self.maximumEncodedOutboxBytes else {
                return false
            }
            runtimeState.outbox.append(contentsOf: messages)
            runtimeState.outboxEntryEncodedBytes.append(contentsOf: messageSizes)
            runtimeState.outboxEncodedBytes += additionalBytes
            runtimeState.status = .ready
            runtimeState.revision += 1
            activeDiscoveryGeneration = nil
            return true
        }
    }

    private func ensurePurpose(
        perspective: Perspective = Perspective(),
        requester: Identity
    ) async -> RuntimeMutationOutcome {
        _ = requester
        let initial = stateSnapshot()
        guard initial.currentPurposeRef == nil else { return .unchanged }
        guard let primary = try? await perspective.getPrimaryPurpose(),
              isBoundedString(primary.reference, maximumUTF8Bytes: 512) else {
            return .unavailable
        }
        return updateState { state in
            guard state.revision == initial.revision else {
                return state.currentPurposeRef == nil ? .conflict : .unchanged
            }
            guard state.currentPurposeRef == nil else {
                return .unchanged
            }
            state.currentPurposeRef = primary.reference
            state.revision += 1
            return .updated
        }
    }

    private func ingestConfigurations(from value: ValueType, requester: Identity) async -> Bool {
        _ = requester
        guard let configurations = parseConfigurations(value),
              !configurations.isEmpty,
              configurations.count <= Self.maximumCandidates,
              let encoded = try? JSONEncoder().encode(configurations),
              encoded.count <= Self.maximumEncodedCandidatesBytes else {
            return false
        }

        let message = outboxMessage(
            topic: AITopics.responseConfigs,
            type: .content,
            content: value,
            title: "Ingested Configurations"
        )
        guard let messageSize = encodedSize(
            of: message,
            maximumBytes: Self.maximumEncodedOutboxEntryBytes
        ) else { return false }

        return updateState { state in
            if state.sendFlowOnIngest {
                let additionalBytes = messageSize + (state.outbox.isEmpty ? 0 : 1)
                guard state.outbox.count < Self.maximumOutboxEntries,
                      state.outboxEncodedBytes + additionalBytes <= Self.maximumEncodedOutboxBytes else {
                    return false
                }
                state.outbox.append(message)
                state.outboxEntryEncodedBytes.append(messageSize)
                state.outboxEncodedBytes += additionalBytes
            }
            state.candidates = configurations
            state.revision += 1
            return true
        }
    }

    private func rank(perspective: Perspective = Perspective(), requester: Identity) async -> Bool {
        _ = requester
        let initial = stateSnapshot()
        guard initial.rankEnabled, !initial.candidates.isEmpty else { return false }

        var purposeName: String?
        if let currentPurposeRef = initial.currentPurposeRef,
           let primary = try? await perspective.getPrimaryPurpose(),
           primary.reference == currentPurposeRef {
            purposeName = primary.name
        }

        let ranked = initial.candidates.sorted {
            score(config: $0, purposeName: purposeName, weights: initial.rankWeights)
                > score(config: $1, purposeName: purposeName, weights: initial.rankWeights)
        }
        let snapshot = builders.statePayload(
            status: AIStatus.ready.rawValue,
            currentPurposeRef: initial.currentPurposeRef,
            purposeClusterRefs: initial.purposeClusterRefs,
            candidates: ranked
        )
        let messages = [
            outboxMessage(topic: AITopics.recommendations, type: .content, content: snapshot),
            outboxMessage(topic: AITopics.state, type: .content, content: snapshot)
        ]
        let messageSizes = messages.compactMap {
            encodedSize(of: $0, maximumBytes: Self.maximumEncodedOutboxEntryBytes)
        }
        guard messageSizes.count == messages.count else {
            return false
        }

        return updateState { state in
            let additionalBytes = zip(messages.indices, messageSizes).reduce(0) { total, pair in
                total + pair.1 + ((state.outbox.isEmpty && pair.0 == messages.startIndex) ? 0 : 1)
            }
            guard state.revision == initial.revision,
                  state.outbox.count + messages.count <= Self.maximumOutboxEntries,
                  state.outboxEncodedBytes + additionalBytes <= Self.maximumEncodedOutboxBytes else {
                return false
            }
            state.candidates = ranked
            state.status = .ready
            state.outbox.append(contentsOf: messages)
            state.outboxEntryEncodedBytes.append(contentsOf: messageSizes)
            state.outboxEncodedBytes += additionalBytes
            state.revision += 1
            return true
        }
    }

    private func score(config: CellConfiguration, purposeName: String?, weights: Object?) -> Double {
        let nameMatchWeight = (weights?["nameMatch"].flatMap { if case let .number(n) = $0 { return Double(n) } else if case let .integer(i) = $0 { return Double(i) } else { return nil } }) ?? 0.7
        let biasWeight = (weights?["bias"].flatMap { if case let .number(n) = $0 { return Double(n) } else if case let .integer(i) = $0 { return Double(i) } else { return nil } }) ?? 0.1
        var s = 0.0
        if let pn = purposeName, config.name.localizedCaseInsensitiveContains(pn) {
            s += nameMatchWeight
        }
        s += biasWeight
        return s
    }

    private func snapshotPayload() -> ValueType {
        let state = stateSnapshot()
        return builders.statePayload(
            status: state.status.rawValue,
            currentPurposeRef: state.currentPurposeRef,
            purposeClusterRefs: state.purposeClusterRefs,
            candidates: state.candidates
        )
    }

    private func outboxMessage(
        topic: String,
        type: FlowElementType,
        content: ValueType,
        title: String = ""
    ) -> ValueType {
        let (wireContent, wireContentType) = flowCompatibleContent(content)
        var msg = Object(propertyValues: [:])
        msg["id"] = .string(UUID().uuidString)
        msg["topic"] = .string(topic)
        msg["title"] = .string(title)
        var props = Object(propertyValues: [:])
        props["type"] = .string(type.rawValue)
        props["contentType"] = .string(wireContentType.rawValue)
        msg["properties"] = .object(props)
        msg["content"] = wireContent
        return .object(msg)
    }

    private func flowCompatibleContent(
        _ content: ValueType
    ) -> (ValueType, FlowElementContentType) {
        switch content {
        case .string:
            return (content, .string)
        case .data:
            return (content, .base64)
        case .object:
            return (content, .object)
        default:
            // Internal callers may need to carry richer ValueType cases. Keep the
            // outer FlowElement wire-compatible by nesting those values in an object.
            return (.object(["value": content]), .object)
        }
    }

    private static func isSupportedSendContent(_ content: ValueType) -> Bool {
        switch content {
        case .object, .string, .data:
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func enqueueOutboxMessage(
        topic: String,
        type: FlowElementType,
        content: ValueType,
        title: String = "",
        requester: Identity
    ) -> Bool {
        _ = requester
        guard isBoundedString(topic, maximumUTF8Bytes: 512),
              isBoundedString(title, maximumUTF8Bytes: 4_096) else {
            return false
        }
        let message = outboxMessage(topic: topic, type: type, content: content, title: title)
        return enqueueOutboxMessages([message])
    }

    private func enqueueOutboxMessages(_ messages: ValueTypeList) -> Bool {
        guard !messages.isEmpty else { return false }
        let messageSizes = messages.compactMap {
            encodedSize(of: $0, maximumBytes: Self.maximumEncodedOutboxEntryBytes)
        }
        guard messageSizes.count == messages.count else { return false }

        return updateState { state in
            let additionalBytes = zip(messages.indices, messageSizes).reduce(0) { total, pair in
                total + pair.1 + ((state.outbox.isEmpty && pair.0 == messages.startIndex) ? 0 : 1)
            }
            guard state.outbox.count + messages.count <= Self.maximumOutboxEntries,
                  state.outboxEncodedBytes + additionalBytes <= Self.maximumEncodedOutboxBytes else {
                return false
            }
            state.outbox.append(contentsOf: messages)
            state.outboxEntryEncodedBytes.append(contentsOf: messageSizes)
            state.outboxEncodedBytes += additionalBytes
            state.revision += 1
            return true
        }
    }

    public func dequeueOutboxMessage(requester: Identity) async -> ValueType? {
        guard await requesterIsRuntimeOwner(requester) else { return nil }
        return dequeueOutboxMessageForOwner()
    }

    private func dequeueOutboxMessageForOwner() -> ValueType? {
        return updateState { state in
            guard !state.outbox.isEmpty else { return nil }
            let removedSize = state.outboxEntryEncodedBytes.removeFirst()
            if state.outbox.count == 1 {
                state.outboxEncodedBytes = 2
            } else {
                state.outboxEncodedBytes -= removedSize + 1
            }
            state.revision += 1
            return state.outbox.removeFirst()
        }
    }

    private func parseConfigurations(_ value: ValueType) -> [CellConfiguration]? {
        let values: ValueTypeList
        switch value {
        case .list(let list):
            values = list
        case .object(let object):
            guard case let .list(list)? = object["configurations"] else { return nil }
            values = list
        default:
            return nil
        }
        return values.reduce(into: [CellConfiguration]?([])) { result, item in
            guard result != nil, case let .cellConfiguration(configuration) = item else {
                result = nil
                return
            }
            result?.append(configuration)
        }
    }

    private func isBoundedString(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        value.utf8.count <= maximumUTF8Bytes
    }

    private func isBoundedValue(_ value: ValueType, maximumBytes: Int) -> Bool {
        encodedSize(of: value, maximumBytes: maximumBytes) != nil
    }

    private func encodedSize(of value: ValueType, maximumBytes: Int) -> Int? {
        guard let encoded = try? JSONEncoder().encode(value),
              encoded.count <= maximumBytes else {
            return nil
        }
        return encoded.count
    }

    private func registerContracts(requester: Identity) async {
        let readOnlyStateContracts: [(key: String, returns: ValueType, summary: String)] = [
            (AIKeys.status, ExploreContract.schema(type: "string"), "Returns the current assistant status."),
            (AIKeys.currentPurposeRef, ExploreContract.oneOfSchema(options: [.null, ExploreContract.schema(type: "string")]), "Returns the current purpose reference."),
            (AIKeys.purposeClusterRefs, ExploreContract.listSchema(item: ExploreContract.schema(type: "string")), "Returns the current purpose cluster references."),
            (AIKeys.candidates, ExploreContract.listSchema(item: ExploreContract.schema(type: "cellConfiguration")), "Returns the currently ingested or ranked configuration candidates."),
            (AIKeys.rankWeights, ExploreContract.schema(type: "object"), "Returns the internal ranking weights.")
        ]
        for contract in readOnlyStateContracts {
            await registerExploreContract(
                requester: requester,
                key: "\(AIKeys.root).\(contract.key)",
                method: .get,
                input: .null,
                returns: contract.returns,
                permissions: ["r---"],
                required: false,
                description: .string(contract.summary)
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.outbox)",
            method: .get,
            input: .null,
            returns: ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
            permissions: [],
            required: false,
            description: .string("Owner-only bounded pending messages awaiting explicit dequeue.")
        )
        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.lastToolArguments)",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.schema(type: "object"), .null]
            ),
            permissions: [],
            required: false,
            description: .string("Owner-only transient bounded arguments from the latest model tool invocation.")
        )
        await registerExploreContract(
            requester: requester,
            key: Self.dequeueOutboxKey,
            method: .set,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.schema(type: "object"), .null]
            ),
            permissions: [],
            required: false,
            description: .string("Owner-only atomic dequeue of the oldest pending AI message.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).state",
            method: .get,
            input: .null,
            returns: Self.aiStateSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current AI assistant snapshot including status, current purpose ref, purpose clusters, and ranked candidates.")
        )

        for key in ["discover", "rank", "ensurePurpose", "buildCluster"] {
            await registerExploreContract(
                requester: requester,
                key: "\(AIKeys.root).\(key)",
                method: .set,
                input: ExploreContract.oneOfSchema(
                    options: [.null, ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "object")],
                    description: "Payload is ignored; any value triggers the action."
                ),
                returns: ExploreContract.schema(type: "string", description: "Operation status."),
                permissions: ["-w--"],
                required: false,
                description: .string("Triggers the AI assistant operation `\(key)`.")
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.promptText)",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current prompt text."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current default prompt text.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.promptText)",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "New prompt text."),
            returns: ExploreContract.schema(type: "string", description: "Echoes the stored prompt text."),
            permissions: ["-w--"],
            required: true,
            description: .string("Updates the default prompt text.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.promptInstructions)",
            method: .get,
            input: .null,
            returns: ExploreContract.schema(type: "string", description: "Current prompt instructions."),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the current instruction block used for prompt generation.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).\(AIKeys.promptInstructions)",
            method: .set,
            input: ExploreContract.schema(type: "string", description: "New instruction block."),
            returns: ExploreContract.schema(type: "string", description: "Echoes the stored instruction block."),
            permissions: ["-w--"],
            required: true,
            description: .string("Updates the instruction block used for prompt generation.")
        )

        for key in [AIKeys.sendFlowOnIngest, AIKeys.rankEnabled] {
            await registerExploreContract(
                requester: requester,
                key: "\(AIKeys.root).\(key)",
                method: .get,
                input: .null,
                returns: ExploreContract.schema(type: "bool", description: "Current toggle state."),
                permissions: ["r---"],
                required: false,
                description: .string("Returns the current boolean toggle for `\(key)`.")
            )
            await registerExploreContract(
                requester: requester,
                key: "\(AIKeys.root).\(key)",
                method: .set,
                input: ExploreContract.schema(type: "bool", description: "New toggle state."),
                returns: ExploreContract.oneOfSchema(
                    options: [ExploreContract.schema(type: "bool"), ExploreContract.schema(type: "string")],
                    description: "Returns the stored toggle or a status string."
                ),
                permissions: ["-w--"],
                required: true,
                description: .string("Updates the boolean toggle `\(key)`.")
            )
        }

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).ingestConfigurations",
            method: .set,
            input: Self.configIngestSchema(),
            returns: ExploreContract.schema(type: "string", description: "Operation status."),
            permissions: ["-w--"],
            required: true,
            description: .string("Ingests candidate cell configurations for later ranking and optional outbox publishing.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).send",
            method: .set,
            input: Self.sendSchema(),
            returns: ExploreContract.schema(type: "string", description: "Operation status."),
            permissions: ["-w--"],
            required: true,
            description: .string("Queues one validated FlowElement-shaped message for explicit owner dequeue.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).sendPrompt",
            method: .set,
            input: Self.sendPromptSchema(),
            returns: ExploreContract.schema(type: "string", description: "Operation status."),
            permissions: ["-w--"],
            required: false,
            description: .string("Builds a prompt message, optionally runs on-device generation, and atomically queues the result for explicit owner dequeue.")
        )
    }

    private static func aiStateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                AIKeys.status: ExploreContract.schema(type: "string"),
                AIKeys.currentPurposeRef: ExploreContract.schema(type: "string"),
                AIKeys.purposeClusterRefs: ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                AIKeys.candidates: ExploreContract.listSchema(item: ExploreContract.schema(type: "cellConfiguration"))
            ],
            requiredKeys: [AIKeys.status],
            description: "AI assistant snapshot payload."
        )
    }

    private static func configIngestSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.listSchema(item: ExploreContract.schema(type: "cellConfiguration")),
                ExploreContract.objectSchema(
                    properties: [
                        "configurations": ExploreContract.listSchema(item: ExploreContract.schema(type: "cellConfiguration"))
                    ],
                    requiredKeys: ["configurations"],
                    description: "Object payload alternative for candidate configurations."
                )
            ],
            description: "Candidate configuration ingestion payload."
        )
    }

    private static func sendSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "topic": ExploreContract.schema(type: "string"),
                "title": ExploreContract.schema(type: "string"),
                "type": ExploreContract.schema(type: "string"),
                "content": ExploreContract.oneOfSchema(
                    options: [
                        ExploreContract.schema(type: "object"),
                        ExploreContract.schema(type: "string"),
                        ExploreContract.schema(type: "data")
                    ]
                )
            ],
            requiredKeys: ["content"],
            description: "FlowElement-style send payload."
        )
    }

    private static func sendPromptSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Shortcut prompt string."),
                ExploreContract.objectSchema(
                    properties: [
                        "prompt": ExploreContract.schema(type: "string"),
                        "topic": ExploreContract.schema(type: "string"),
                        "title": ExploreContract.schema(type: "string"),
                        "type": ExploreContract.schema(type: "string"),
                        "instructions": ExploreContract.schema(type: "string")
                    ],
                    requiredKeys: ["prompt"],
                    description: "Prompt payload object."
                )
            ],
            description: "Prompt send payload."
        )
    }
    
    // Query Apple's on-device model if available; otherwise return nil
    private func aiGenerateResponse(prompt: String, instructions: String?, requester: Identity) async -> String? {
#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            do {
                let tools: [any Tool] = [
                    GetConfigurationsTool(cell: self, requester: requester)
                ]
                let session: LanguageModelSession
                if let instr = instructions, !instr.isEmpty {
                    session = LanguageModelSession(tools: tools, instructions: instr)
                } else {
                    session = LanguageModelSession(tools: tools)
                }
                let response = try await session.respond(to: prompt, options: GenerationOptions())
                return response.content
            } catch {
                CellBase.diagnosticLog("LanguageModelSession respond failed: \(error)", domain: .flow)
                return nil
            }
        case .unavailable(let reason):
            let reasonString = "LanguageModelSession unavailable: \(reason)"
            CellBase.diagnosticLog(reasonString, domain: .flow)
            return nil
        }
#else
        return nil
#endif
    }

    func instructionsFrom (flow: FlowElement) -> [String] {
        return [String]()
    }
}

@available(macOS 26.0, iOS 26.0, *)
public struct AppleIntelligenceCellBootstrap {
    public init() {}

    public func seed(cell: inout GeneralCell, requester: Identity, initialPurposeRef: String? = nil) async {
        if let appleIntelligenceCell = cell as? AppleIntelligenceCell {
            await appleIntelligenceCell.seedRuntimeState(
                initialPurposeRef: initialPurposeRef,
                requester: requester
            )
            return
        }
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.status)", value: .string(AIStatus.idle.rawValue), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.candidates)", value: .list([]), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.outbox)", value: .list([]), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", value: .bool(true), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.promptText)", value: .string(""), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.promptInstructions)", value: .string("You are a helpful assistant. Keep answers concise."), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.rankEnabled)", value: .bool(true), requester: requester)
        _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.rankWeights)", value: .object([:]), requester: requester)
        if let ref = initialPurposeRef {
            _ = try? await cell.set(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", value: .string(ref), requester: requester)
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
extension AppleIntelligenceCell {
    fileprivate func seedRuntimeState(initialPurposeRef: String?, requester: Identity) async {
        guard await requesterIsRuntimeOwner(requester),
              initialPurposeRef.map({ isBoundedString($0, maximumUTF8Bytes: 512) }) ?? true else {
            return
        }
        stateLock.withLock {
            activeDiscoveryGeneration = nil
            runtimeState.status = .idle
            runtimeState.currentPurposeRef = initialPurposeRef
            runtimeState.purposeClusterRefs = initialPurposeRef.map { [$0] } ?? []
            runtimeState.candidates = []
            runtimeState.rankWeights = [:]
            runtimeState.outbox = []
            runtimeState.outboxEntryEncodedBytes = []
            runtimeState.outboxEncodedBytes = 2
            runtimeState.sendFlowOnIngest = true
            runtimeState.promptText = ""
            runtimeState.promptInstructions = "You are a helpful assistant. Keep answers concise."
            runtimeState.rankEnabled = true
            runtimeState.revision += 1
        }
    }
}
