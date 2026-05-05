// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  AppleIntelligenceCell.swift
//  CellProtocol
//
//  Created by Kjetil Hustveit on 22/12/2025.
//

import Foundation
import CellBase
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple Intelligence assistant logic operating on a GeneralCell via Meddle.get/set.
// All publishing is deferred to Emit by writing Flow-ready messages into ai.outbox as ValueType.object entries.
// Your Emit implementation can drain ai.outbox, convert entries to FlowElement with appropriate properties/topic, and publish.

@available(macOS 26.0, iOS 26.0, *)
public class AppleIntelligenceCell: GeneralCell {
    private let bootstrap = AppleIntelligenceCellBootstrap()
    private let builders = AIAssistantFlowBuilders()
    private var rankEnabled = false
    private var status: AIStatus = .ready
    
    private var promptText: String = "Hva vil du hjelpe deg med i dag?"
    private var promptInstructions = """
    
        Du er en assistent som skal bruke relasjoner i en graf for å finne likhet og sammenhenger.
    Ikke stol på navn/labels alene. Når du skal finne beslektede noder, bruk verktøyet "graph_match".
    Oppgi relasjonstype (types, parts, partOf, interests, purposes, entities, states), ønsket vekt og toleranse.
    Returner korte, handlingsrettede forslag basert på treffene.
    """
    
    
    let detailedInstuctions = """
    
            Du er en personlig hjelper som skal gjøre ditt ytterste for å hjelpe brukeren til å nå sitt mål
    
        Du er en assistent som skal bruke relasjoner i en graf for å finne likhet og sammenhenger.
    Ikke stol på navn/labels alene. Når du skal finne beslektede noder, bruk verktøyet "graph_match".
    Oppgi relasjonstype (types, parts, partOf, interests, purposes, entities, states), ønsket vekt og toleranse.
    Returner korte, handlingsrettede forslag basert på treffene.
    """
    
    private var sendFlowOnIngest: Bool = true
#if canImport(FoundationModels)
    
    private var tools: [any Tool] = []
    private var session: LanguageModelSession?
#endif

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        print("AppleIntelligenceCell init")
//        var selfAsGeneral: GeneralCell = self
//        await bootstrap.seed(cell: &selfAsGeneral, requester: owner)
        await self.ensurePurpose(perspective: Perspective(), requester: owner)
        await self.buildCluster(requester: owner)
//        registerBindings()
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
#if canImport(FoundationModels)
        let tool = GetConfigurationsTool( cell: self, requester: owner)
        self.tools = [tool]
        self.setupIntelligence(requester: owner)
#endif
    }

    private enum CodingKeys: String, CodingKey { case cellOwner }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try super.init(from: decoder)
//        registerBindings()
        Task {
            if let vault = CellBase.defaultIdentityVault,
               let requester = await vault.identity(for: "private", makeNewIfNotFound: true ) {
                await setupPermissions(owner: requester)
                await setupKeys(owner: requester)
            }
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
    }



    private func registerBindings() {
        // Expose callable endpoints by convention: writing any value to these paths triggers the action
        // ai.discover
        self.registerAction(at: "\(AIKeys.root).discover") { [weak self] requester, _ in
            guard let self = self /*, self.isAuthorized(requester) */ else { return }
            Task { try? await self.discover(requester: requester) }
        }
        // ai.rank
        self.registerAction(at: "\(AIKeys.root).rank") { [weak self] requester, _ in
            guard let self = self /*, self.isAuthorized(requester) */ else { return }
            Task { await self.rank(perspective: Perspective(), requester: requester) }
        }
        // ai.ensurePurpose
        self.registerAction(at: "\(AIKeys.root).ensurePurpose") { [weak self] requester, _ in
            guard let self = self /*, self.isAuthorized(requester) */ else { return }
            Task { await self.ensurePurpose(perspective: Perspective(), requester: requester) }
        }
        // ai.buildCluster
        self.registerAction(at: "\(AIKeys.root).buildCluster") { [weak self] requester, _ in
            guard let self = self else { return }
            Task { await self.buildCluster(requester: requester) }
        }
        // ai.ingestConfigurations: expect a payload at ai.ingestConfigurations.payload
        self.registerSetter(at: "\(AIKeys.root).ingestConfigurations") { [weak self] requester, value in
            guard let self = self else { return }
            Task { await self.ingestConfigurations(from: value, requester: requester) }
        }
    }

    private func setupPermissions(owner: Identity) async {
        // Allow skeleton and flow to read AI state from this cell
        self.agreementTemplate.addGrant("rw--", for: AIKeys.root)
        self.agreementTemplate.addGrant("r---", for: "flow")
    }

    private func setupKeys(owner: Identity) async {
        // GET ai.state snapshot
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).state", getValueIntercept: { [weak self] keypath, requester in
            guard let self = self else { return .string("failure") }
            return await self.snapshotPayload(requester: requester)
        })

        // SET ai.discover -> trigger discovery
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).discover", setValueIntercept: { [weak self] keypath, value, requester in
            print("Set intercept for discover")
            guard let self = self else { return .string("failure") }
            try await self.discover(requester: requester)
            return .string("ok")
        })

        // SET ai.rank -> trigger ranking
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).rank", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            await self.rank(perspective: Perspective(), requester: requester)
            return .string("ok")
        })

        // SET ai.ensurePurpose
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).ensurePurpose", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            await self.ensurePurpose(perspective: Perspective(), requester: requester)
            return .string("ok")
        })

        // SET ai.buildCluster
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).buildCluster", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            await self.buildCluster(requester: requester)
            return .string("ok")
        })

        // GET/SET ai.promptText
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptText)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .string("") }
            
            return .string(self.promptText)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptText)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
//            _ = try? await self.set(keypath: key, value: value, requester: requester)
            
            if case let .string(newValue) = value { self.promptText = newValue }
            
            return .string("New promtpt text: \(self.promptText)")
        })

        // GET/SET ai.promptInstructions
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptInstructions)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .string("") }
            return .string(self.promptInstructions)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.promptInstructions)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            if case let .string(newValue) = value { self.promptInstructions = newValue }
            return .string("New prompt instructions: \(self.promptInstructions)")
        })

        // GET/SET ai.sendFlowOnIngest
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .bool(true) }
            return .bool(self.sendFlowOnIngest) //(try? await self.get(keypath: key, requester: requester)) ?? .bool(true)
        })
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            if case  .bool(let newValue) = value { self.sendFlowOnIngest = newValue }
            return .string("New sendFlowOnIngest: \(self.sendFlowOnIngest)")
        })

        // GET/SET ai.rankEnabled
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.rankEnabled)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .bool(true) }
            return .bool(rankEnabled)
        })
        
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).\(AIKeys.rankEnabled)", setValueIntercept: { [weak self] key, value, requester in
            guard let self = self else { return .string("failure") }
            guard case .bool(let newValue) = value else { return .string("failure") }
            rankEnabled = newValue
            return .bool(rankEnabled)
        })

        // GET ai.lastToolArguments (read-only from outside)
        await addInterceptForGet(requester: owner, key: "\(AIKeys.root).\(AIKeys.lastToolArguments)", getValueIntercept: { [weak self] key, requester in
            guard let self = self else { return .object([:]) }
            return .string("set \(key)") //(try? await self.get(keypath: key, requester: requester)) ?? .object([:])
        })

        // SET ai.ingestConfigurations with payload
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).ingestConfigurations", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            await self.ingestConfigurations(from: value, requester: requester)
            let sendToggle = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.sendFlowOnIngest)", requester: requester)).flatMap { if case let .bool(b) = $0 { return b } else { return nil } } ?? true
            if sendToggle {
                await self.enqueueOutboxMessage(topic: AITopics.responseConfigs, type: .content, content: value, title: "Ingested Configurations", requester: requester)
            }
            return .string("ok")
        })

        // SET ai.send -> forward via Porthole using named connection "intelligence" when no endpoint specified
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).send", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }
            // Expect an object { topic, type, content, title?, endpoint? }
            guard case let .object(obj) = value else { return .string("paramErr") }
            let topic: String = {
                if let v = obj["topic"], case let .string(s) = v { return s }
                return AITopics.requestConfigs
            }()
            let title: String = {
                if let v = obj["title"], case let .string(s) = v { return s }
                return ""
            }()
            let type: FlowElementType = {
                if let v = obj["type"], case let .string(s) = v, let t = FlowElementType(rawValue: s) { return t }
                return .event
            }()
            let content: ValueType = obj["content"] ?? .null

            // Convert only the root content to FlowElementValueType; nested collections remain as ValueType
            // This matches FlowElement API expectations where content is FlowElementValueType

            let flowContent = self.toFlowElementValueType(content)
            let contentType: FlowElementContentType = {
                switch content {
                case .object, .list:
                    return .dslv17
                case .string:
                    return .string
                case .data:
                    return .base64
                default:
                    return .string
                }
            }()
            var msg = FlowElement(title: title, content: flowContent, properties: .init(type: type, contentType: contentType))
            msg.topic = topic
            msg.origin = self.uuid
            self.pushFlowElement(msg, requester: requester)
            return .string("ok")
        })

        // SET ai.sendPrompt -> build a FlowElement from a prompt and push to feed
        await addInterceptForSet(requester: owner, key: "\(AIKeys.root).sendPrompt", setValueIntercept: { [weak self] keypath, value, requester in
            guard let self = self else { return .string("failure") }

            // Defaults
            var topic: String = AITopics.exploreRequest
            var title: String = "Prompt"
            var type: FlowElementType = .event
            var instructionsText: String = await {
                if let v = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.promptInstructions)", requester: requester), case let .string(s) = v, !s.isEmpty { return s }
                return "You are a helpful assistant. Keep answers concise."
            }()

            // Resolve prompt string
            var promptString: String = ""
            switch value {
            case .string(let s):
                if s.isEmpty, let v = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.promptText)", requester: requester), case let .string(ps) = v {
                    promptString = ps
                } else {
                    promptString = s
                }
            case .object(let obj):
                if case let .string(s)? = obj["prompt"] {
                    promptString = s
                } else if let v = obj["content"] {
                    switch v {
                    case .string(let s):
                        promptString = s
                    default:
                        promptString = (try? v.jsonString()) ?? ""
                    }
                }
                if case let .string(s)? = obj["topic"] { topic = s }
                if case let .string(s)? = obj["title"] { title = s }
                if case let .string(s)? = obj["type"], let t = FlowElementType(rawValue: s) { type = t }
                if case let .string(s)? = obj["instructions"] { instructionsText = s }
                if promptString.isEmpty, let v = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.promptText)", requester: requester), case let .string(ps) = v {
                    promptString = ps
                }
            default:
                if let v = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.promptText)", requester: requester), case let .string(ps) = v {
                    promptString = ps
                }
            }

            // 1) Push the prompt as an event (prompt content)
            var promptMsg = FlowElement(title: title, content: .string(promptString), properties: .init(type: type, contentType: .string))
            promptMsg.topic = topic
            promptMsg.origin = self.uuid
            self.pushFlowElement(promptMsg, requester: requester)

            // 2) Query Apple Intelligence and push a response
            if let aiText = await self.aiGenerateResponse(prompt: promptString, instructions: instructionsText, requester: requester), !aiText.isEmpty {
                var responseMsg = FlowElement(title: "Response", content: .string(aiText), properties: .init(type: .content, contentType: .string))
                responseMsg.topic = topic
                responseMsg.origin = self.uuid
                self.pushFlowElement(responseMsg, requester: requester)
            }

            return .string("ok")
        })

        await registerContracts(requester: owner)
    }

    // MARK: - Direct AI operations (formerly in AIAssistant)
    public func buildCluster(requester: Identity) async {
        let clusterPath = "\(AIKeys.root).\(AIKeys.purposeClusterRefs)"
        if (try? await self.get(keypath: clusterPath, requester: requester)) == nil,
           case let .string(ref)? = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", requester: requester) {
            _ = try? await self.set(keypath: clusterPath, value: .list([.string(ref)]), requester: requester)
        }
    }

    private func setupIntelligence(requester: Identity) {
        let graphMatchTool = GraphMatchTool(cell: self, requester: requester)
        self.session = LanguageModelSession(
            tools: [graphMatchTool],
            instructions: Instructions {
                "Your job is to find purposes to fill into your day."
                
                "Each day needs to be fulfilled by one or more purposes."
                
                """
                Always use the GraphMatchTool tool to find purposes \
                and associated interests, helpercells and entityrepresentations 
                
                If no interests are found the default purpose is to fill the day purposes 
                """
                /* FindPointsOfInterestTool.categories */
                
                """
                Here is a description of  for your reference \
                when considering : First Purpose. Will prompt Person the Entity represent to find and add Purposes
                
                
                """
                 /* landmark.description */
            }
        )
    }
    
    public func discover(requester: Identity) async throws {
        self.status = .discovering
        
//        let currentRef = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", requester: requester)).flatMap {
//            if case let .string(s) = $0 { return s } else { return nil }
//        }
        // Get current purpose from PerspectiveCell
//        guard let resolver = CellBase.defaultCellResolver else {
////            throw CellBaseError.noResolver
//            return
//        }
        
        
        
        
//        let perspective = try await resolver.cellAtEndpoint(endpoint: "cell:///Perspective", requester: requester)
//        
//        let clusterRefs: [String]? = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.purposeClusterRefs)", requester: requester)).flatMap { vt in
//            if case let .list(list) = vt {
//                return list.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
//            }
//            return nil
//        }
//
//        let requestPayload = builders.requestPayload(currentPurposeRef: currentRef, purposeClusterRefs: clusterRefs, context: nil)
//        await enqueueOutboxMessage(topic: AITopics.requestConfigs, type: .event, content: requestPayload, title: "", requester: requester)
//        await enqueueOutboxMessage(topic: AITopics.exploreRequest, type: .event, content: requestPayload, title: "", requester: requester)
//
//        let snapshot = await snapshotPayload(requester: requester)
//        await enqueueOutboxMessage(topic: AITopics.state, type: .content, content: snapshot, title: "", requester: requester)
//        
//        
        var flowElement = FlowElement(title: "AI Discover", content: .string("AI Please discover!"), properties: FlowElement.Properties(type: .content, contentType: .string))
        flowElement.topic = "ai" // Just to test and debug
        self.pushFlowElement(flowElement, requester: requester)

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 11.0, visionOS 2.0, *) {
            var wrappedPurpose: PurposeWrapper.PartiallyGenerated?
            var counter: Int = 0
            if let session = self.session {
                let stream = session.streamResponse(
                    generating: PurposeWrapper.self,
                    includeSchemaInPrompt: false,
                    options: GenerationOptions(sampling: .greedy)
                ) {
                    "Generate 5 suggestions of Purposes"
                    "Generate a list of purposes that could be relevant resolve to the user's current situation."
                    "Give it a fun title and description. You can also add a link to a website or a video if you'd like. This is just a suggestion, you can always edit it later."
                }
                for try await partialResponse in stream {
                    wrappedPurpose = partialResponse.content
                    counter += 1
                    flowElement.title = "Suggestion no: \(counter) - \(wrappedPurpose?.title ?? "")"
                    flowElement.content = .string(wrappedPurpose?.description ?? "")
                    self.pushFlowElement(flowElement, requester: requester)
                    print("flowElement.title \(flowElement.title)")
                }
            }
        } else {
            flowElement.title = "AI Discover unavailable"
            flowElement.content = .string("PurposeWrapper generation requires iOS 26+.")
            self.pushFlowElement(flowElement, requester: requester)
        }
#endif
        
        
        
        // Push flow element directly
        
        
        flowElement.topic = "ai.assistant.state" // Just to test and debug
        self.pushFlowElement(flowElement, requester: requester)
        
        flowElement.topic = "ai.assistant.recommendations" // Just to test and debug
        self.pushFlowElement(flowElement, requester: requester)
        
    }

    public func ensurePurpose(perspective: Perspective = Perspective(), requester: Identity) async {
        if case .string? = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", requester: requester) {
            return
        }
        if let primary = try? await perspective.getPrimaryPurpose() {
            _ = try? await self.set(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", value: .string(primary.reference), requester: requester)
        }
    }

    public func ingestConfigurations(from value: ValueType, requester: Identity) async {
        var configs: [CellConfiguration] = []
        switch value {
        case .list(let list):
            for item in list {
                if case let .cellConfiguration(conf) = item { configs.append(conf) }
            }
        case .object(let obj):
            if let v = obj["configurations"], case let .list(list) = v {
                for item in list {
                    if case let .cellConfiguration(conf) = item { configs.append(conf) }
                }
            }
        default:
            break
        }

        if !configs.isEmpty {
            let vtList = ValueTypeList(configs.map { .cellConfiguration($0) })
            _ = try? await self.set(keypath: "\(AIKeys.root).\(AIKeys.candidates)", value: .list(vtList), requester: requester)
        }
    }

    public func rank(perspective: Perspective = Perspective(), requester: Identity) async {
        guard case let .list(list)? = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.candidates)", requester: requester) else { return }

        var purposeName: String?
        if case let .string(ref)? = try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", requester: requester),
           let primary = try? await perspective.getPrimaryPurpose(),
           primary.reference == ref {
            purposeName = primary.name
        }

        var configs: [CellConfiguration] = []
        for item in list {
            if case let .cellConfiguration(conf) = item { configs.append(conf) }
        }

        let weightsObj: Object? = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.rankWeights)", requester: requester)).flatMap { vt in
            if case let .object(o) = vt { return o } else { return nil }
        }
        configs.sort { a, b in
            score(config: a, purposeName: purposeName, weights: weightsObj) > score(config: b, purposeName: purposeName, weights: weightsObj)
        }

        let vtList = ValueTypeList(configs.map { .cellConfiguration($0) })
        _ = try? await self.set(keypath: "\(AIKeys.root).\(AIKeys.candidates)", value: .list(vtList), requester: requester)
        _ = try? await self.set(keypath: "\(AIKeys.root).\(AIKeys.status)", value: .string(AIStatus.ready.rawValue), requester: requester)

        let snapshot = await snapshotPayload(requester: requester)
        await enqueueOutboxMessage(topic: AITopics.recommendations, type: .content, content: snapshot, title: "", requester: requester)
        await enqueueOutboxMessage(topic: AITopics.state, type: .content, content: snapshot, title: "", requester: requester)
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

    public func snapshotPayload(requester: Identity) async -> ValueType {
        let status = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.status)", requester: requester)).flatMap {
            if case let .string(s) = $0 { return s } else { return nil }
        } ?? AIStatus.idle.rawValue

        let currentRef = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.currentPurposeRef)", requester: requester)).flatMap {
            if case let .string(s) = $0 { return s } else { return nil }
        }

        let clusterRefs: [String]? = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.purposeClusterRefs)", requester: requester)).flatMap { vt in
            if case let .list(list) = vt {
                return list.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
            }
            return nil
        }

        let candidates: [CellConfiguration]? = (try? await self.get(keypath: "\(AIKeys.root).\(AIKeys.candidates)", requester: requester)).flatMap { vt in
            if case let .list(list) = vt {
                var out: [CellConfiguration] = []
                for item in list {
                    if case let .cellConfiguration(conf) = item { out.append(conf) }
                }
                return out
            }
            return nil
        }

        return builders.statePayload(status: status,
                                     currentPurposeRef: currentRef,
                                     purposeClusterRefs: clusterRefs,
                                     candidates: candidates)
    }

    public func enqueueOutboxMessage(topic: String,
                                     type: FlowElementType,
                                     content: ValueType,
                                     title: String = "",
                                     requester: Identity) async {
        var msg = Object(propertyValues: [:])
        msg["topic"] = .string(topic)
        msg["title"] = .string(title)
        var props = Object(propertyValues: [:])
        props["type"] = .string(type.rawValue)
        props["contentType"] = .string(FlowElementContentType.dslv17.rawValue)
        msg["properties"] = .object(props)
        msg["content"] = content

        let outboxPath = "\(AIKeys.root).\(AIKeys.outbox)"
        var current = (try? await self.get(keypath: outboxPath, requester: requester)).flatMap { vt -> ValueTypeList? in
            if case let .list(list) = vt { return list }
            return nil
        } ?? ValueTypeList()

        current.append(.object(msg))
        _ = try? await self.set(keypath: outboxPath, value: .list(current), requester: requester)
    }

    public func dequeueOutboxMessage(requester: Identity) async -> ValueType? {
        let outboxPath = "\(AIKeys.root).\(AIKeys.outbox)"
        guard var current = (try? await self.get(keypath: outboxPath, requester: requester)).flatMap({ vt -> ValueTypeList? in
            if case let .list(list) = vt { return list }
            return nil
        }), !current.isEmpty else { return nil }

        let first = current.removeFirst()
        _ = try? await self.set(keypath: outboxPath, value: .list(current), requester: requester)
        return first
    }

    private func registerContracts(requester: Identity) async {
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
            key: "\(AIKeys.root).\(AIKeys.lastToolArguments)",
            method: .get,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [ExploreContract.schema(type: "string"), ExploreContract.schema(type: "object")],
                description: "Returns the last tool arguments snapshot or a placeholder string."
            ),
            permissions: ["r---"],
            required: false,
            description: .string("Returns the last captured tool arguments, when available.")
        )

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
            description: .string("Pushes a FlowElement-shaped message into the AI feed bridge.")
        )

        await registerExploreContract(
            requester: requester,
            key: "\(AIKeys.root).sendPrompt",
            method: .set,
            input: Self.sendPromptSchema(),
            returns: ExploreContract.schema(type: "string", description: "Operation status."),
            permissions: ["-w--"],
            required: false,
            description: .string("Builds a prompt FlowElement, optionally runs on-device generation, and publishes the response.")
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
                "endpoint": ExploreContract.schema(type: "string"),
                "content": ExploreContract.schema(type: "object")
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
                        "content": ExploreContract.schema(type: "object"),
                        "topic": ExploreContract.schema(type: "string"),
                        "title": ExploreContract.schema(type: "string"),
                        "type": ExploreContract.schema(type: "string"),
                        "instructions": ExploreContract.schema(type: "string")
                    ],
                    description: "Prompt payload object."
                )
            ],
            description: "Prompt send payload."
        )
    }
    
    // Query Apple's on-device model if available; otherwise return nil
    private func aiGenerateResponse(prompt: String, instructions: String?, requester: Identity) async -> String? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) /* /&& !targetEnvironment(macCatalyst) */ {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                do {
                    let session: LanguageModelSession
#if canImport(FoundationModels)
                        if let instr = instructions, !instr.isEmpty {
                            session = LanguageModelSession(tools: self.tools, instructions: instr)
                        } else {
                            session = LanguageModelSession(tools: self.tools)
                        }
#else
                    session = LanguageModelSession()
#endif
                    let response = try await session.respond(to: prompt, options: GenerationOptions())
                    return response.content
                } catch {
                    print("LanguageModelSession respond error: \(error)")
                    return nil
                }
            case .unavailable(let reason):
                let reasonString = "LanguageModelSession unavailable: \(reason)"
                print(reasonString)
                let flowElement = FlowElement( title: "Apple Intelligence Error", content: .string(reasonString), properties: FlowElement.Properties(type: .alert, contentType: .string))
                pushFlowElement(flowElement, requester: requester)
                return nil
            
            }
        }
#endif
        return nil
    }

    private func toFlowElementValueType(_ value: ValueType) -> FlowElementValueType {
        switch value {
        case .string(let s):
            return .string(s)
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .number(n)
        case .integer(let i):
            return .number(i)
        case .float(let d):
            return .string(String(d))
        case .data(let data):
            return .data(data)
        case .object(let o):
            return .object(o)
        case .list(let l):
            return .list(l)
        default:
            let json = (try? value.jsonString()) ?? "null"
            return .string(json)
        }
    }
    
    func instructionsFrom (flow: FlowElement) -> [String] {
        return [String]()
    }
}

extension GeneralCell {
    fileprivate func registerAction(at keypath: String, _ action: @escaping (_ requester: Identity, _ value: ValueType) -> Void) {
        // Hook into your framework's action registration here.
    }

    fileprivate func registerSetter(at keypath: String, _ setter: @escaping (_ requester: Identity, _ value: ValueType) -> Void) {
        // Hook into your framework's setter registration here.
    }
}

public struct AppleIntelligenceCellBootstrap {
    public init() {}

    public func seed(cell: inout GeneralCell, requester: Identity, initialPurposeRef: String? = nil) async {
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
    func storeLastToolArguments(_ args: Any, requester: Identity) async {
        // Expect args to be encodable to ValueType.object; best effort JSON
        if let data = try? JSONEncoder().encode(String(describing: args)), let s = String(data: data, encoding: .utf8) {
            
        }
    }
}
