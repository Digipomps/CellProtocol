// AppleIntelligenceCell.swift
//
// AppleIntelligenceCell – Arkitektur, flyt og Skeleton-koblinger
//
// Denne filen dokumenterer hvordan AppleIntelligenceCell er bygget opp, hvorfor den er strukturert slik,
// og hvordan GET/SET og FlowElements henger sammen med Skeleton-visningen. Målet er å gjøre det enklere
// å forbedre implementasjonen og å bygge flere celler som følger samme mønster.
//
// [Detaljert dokumentasjon følger i kommentaren ovenfor.]
// 
// Implementasjon følger nedenfor.

import Foundation

// MARK: - AIKeys Namespace

enum AIKeys {
    static let status = "ai.status"
    static let currentPurposeRef = "ai.currentPurposeRef"
    static let purposeClusterRefs = "ai.purposeClusterRefs"
    static let candidates = "ai.candidates"
    static let outbox = "ai.outbox"
    static let promptText = "ai.promptText"
    static let promptInstructions = "ai.promptInstructions"
    static let sendFlowOnIngest = "ai.sendFlowOnIngest"
    static let rankEnabled = "ai.rankEnabled"
    static let rankWeights = "ai.rankWeights"
    static let lastToolArguments = "ai.lastToolArguments"
    
    static let state = "ai.state"
    static let discover = "ai.discover"
    static let rank = "ai.rank"
    static let ensurePurpose = "ai.ensurePurpose"
    static let buildCluster = "ai.buildCluster"
    static let ingestConfigurations = "ai.ingestConfigurations"
    static let send = "ai.send"
    static let sendPrompt = "ai.sendPrompt"
}

// MARK: - AITopics Namespace

enum AITopics {
    static let assistantState = "ai.assistant.state"
    static let assistantRecommendations = "ai.assistant.recommendations"
    static let intentRequestConfigurations = "ai.intent.requestConfigurations"
    static let intentResponseConfigurations = "ai.intent.response.configurations"
    static let exploreRequest = "explore.request"
    static let exploreResponse = "explore.response"
    static let exploreAnnounce = "explore.announce"
}

// MARK: - ValueType and Helpers

// Assuming ValueType is defined elsewhere with possible cases such as .string, .object, .list, .dslv17, etc.

// A minimal placeholder for ValueType for context
enum ValueType {
    case string(String)
    case object([String: ValueType])
    case list([ValueType])
    case dslv17([String: Any])
    case bool(Bool)
    case null
    
    // Helper to create empty list
    static var emptyList: ValueType {
        return .list([])
    }
}

// MARK: - CellConfiguration (Example placeholder)

struct CellConfiguration: Codable {
    let id: String
    let name: String
    // Additional properties as needed
}

// MARK: - AppleIntelligenceCellBootstrap

struct AppleIntelligenceCellBootstrap {
    static func seed(into cell: inout GeneralCell) {
        // Seed default values for ai.* keys
        cell.set(key: AIKeys.status, value: .string("idle"))
        cell.set(key: AIKeys.rankEnabled, value: .bool(true))
        cell.set(key: AIKeys.sendFlowOnIngest, value: .bool(true))
        cell.set(key: AIKeys.candidates, value: .list([]))
        cell.set(key: AIKeys.outbox, value: .list([]))
        cell.set(key: AIKeys.promptText, value: .string(""))
        cell.set(key: AIKeys.promptInstructions, value: .string("You are a helpful AI assistant."))
        cell.set(key: AIKeys.rankWeights, value: .object([
            "nameMatch": .string("0.8"),
            "bias": .string("0.05")
        ]))
        // Additional default seeds as needed
    }
}

// MARK: - AIAssistant

final class AIAssistant {
    
    private var tools: [Tool] = []
    
    init(tools: [Tool] = []) {
        self.tools = tools
    }
    
    // Rank candidates using weights
    func rank(candidates: [CellConfiguration], with weights: [String: Double]?) -> [CellConfiguration] {
        // Placeholder ranking logic
        // Sort by name length descending as example; use weights if provided
        let sorted = candidates.sorted { c1, c2 in
            return c1.name.count > c2.name.count
        }
        return sorted
    }
    
    // Score single candidate (used internally)
    func score(candidate: CellConfiguration, weights: [String: Double]?) -> Double {
        // Placeholder scoring; use weights such as nameMatch and bias for scoring
        return Double(candidate.name.count)
    }
    
    // Enqueue message to outbox
    static func enqueueOutboxMessage(in cell: inout GeneralCell, topic: String, title: String, type: String, contentType: String, content: ValueType) {
        // Retrieve current outbox or create new
        var outboxList: [ValueType] = []
        if case let .list(existingList) = cell.get(key: AIKeys.outbox) {
            outboxList = existingList
        }
        // Construct message
        let message: ValueType = .object([
            "topic": .string(topic),
            "title": .string(title),
            "properties": .object([
                "type": .string(type),
                "contentType": .string(contentType)
            ]),
            "content": content
        ])
        outboxList.append(message)
        cell.set(key: AIKeys.outbox, value: .list(outboxList))
    }
    
    // Ingest configurations and update candidates, optionally sending response message
    func ingestConfigurations(in cell: inout GeneralCell, from value: ValueType, requester: Identity) {
        var configurations: [CellConfiguration] = []
        switch value {
        case .list(let list):
            configurations = list.compactMap { vt in
                return decodeCellConfiguration(from: vt)
            }
        case .object(let obj):
            if let configsVT = obj["configurations"], case let .list(configList) = configsVT {
                configurations = configList.compactMap { vt in
                    return decodeCellConfiguration(from: vt)
                }
            }
        default:
            break
        }
        
        // Update candidates
        let candidatesVT = ValueType.list(configurations.map { encodeCellConfiguration($0) })
        cell.set(key: AIKeys.candidates, value: candidatesVT)
        
        // Send response if toggled
        if case let .bool(true) = cell.get(key: AIKeys.sendFlowOnIngest) {
            Self.enqueueOutboxMessage(
                in: &cell,
                topic: AITopics.intentResponseConfigurations,
                title: "Configurations ingested",
                type: "acknowledgement",
                contentType: "application/json",
                content: candidatesVT
            )
        }
    }
    
    // Placeholder for decoding CellConfiguration from ValueType
    private func decodeCellConfiguration(from vt: ValueType) -> CellConfiguration? {
        guard case let .object(dict) = vt else { return nil }
        if case let .string(id)? = dict["id"],
           case let .string(name)? = dict["name"] {
            return CellConfiguration(id: id, name: name)
        }
        return nil
    }
    
    // Placeholder for encoding CellConfiguration to ValueType
    private func encodeCellConfiguration(_ config: CellConfiguration) -> ValueType {
        return .object([
            "id": .string(config.id),
            "name": .string(config.name)
        ])
    }
    
    // Send prompt to Apple Intelligence
    func sendPrompt(in cell: inout GeneralCell, withPayload payload: ValueType?) -> ValueType {
        let promptTextVT = cell.get(key: AIKeys.promptText)
        let instructionsVT = cell.get(key: AIKeys.promptInstructions)
        
        var promptText = ""
        if let payload = payload, case let .string(plString) = payload, !plString.isEmpty {
            promptText = plString
        } else {
            if case let .string(text) = promptTextVT {
                promptText = text
            }
        }
        
        var instructions = "You are a helpful AI assistant."
        if case let .string(instr) = instructionsVT, !instr.isEmpty {
            instructions = instr
        }
        
        // Compose prompt event and response event
        let promptEvent: ValueType = .object([
            "topic": .string("ai.assistant.prompt"),
            "title": .string("Prompt sent"),
            "properties": .object([
                "type": .string("prompt"),
                "contentType": .string("text/plain")
            ]),
            "content": .string(promptText)
        ])
        
        // Placeholder response from LLM (simulate)
        let responseContent = "Simulated response to prompt."
        let responseEvent: ValueType = .object([
            "topic": .string("ai.assistant.response"),
            "title": .string("Response received"),
            "properties": .object([
                "type": .string("response"),
                "contentType": .string("text/plain")
            ]),
            "content": .string(responseContent)
        ])
        
        // Enqueue both prompt and response
        Self.enqueueOutboxMessage(in: &cell, topic: "ai.assistant.prompt", title: "Prompt sent", type: "prompt", contentType: "text/plain", content: .string(promptText))
        Self.enqueueOutboxMessage(in: &cell, topic: "ai.assistant.response", title: "Response received", type: "response", contentType: "text/plain", content: .string(responseContent))
        
        return .string("ok")
    }
}

// MARK: - Tool Protocol and GetConfigurationsTool

protocol Tool {
    var name: String { get }
    func execute(in cell: inout GeneralCell, arguments: ValueType) -> ValueType
}

final class GetConfigurationsTool: Tool {
    let name = "GetConfigurationsTool"
    
    func execute(in cell: inout GeneralCell, arguments: ValueType) -> ValueType {
        // Store arguments to ai.lastToolArguments
        cell.set(key: AIKeys.lastToolArguments, value: arguments)
        
        // Build prompt combining ai.promptText and ai.promptInstructions
        let promptText = cell.get(key: AIKeys.promptText)
        let promptInstructions = cell.get(key: AIKeys.promptInstructions)
        
        // Placeholder to create prompt string
        var promptStrings: [String] = []
        if case let .string(instr) = promptInstructions {
            promptStrings.append(instr)
        }
        if case let .string(text) = promptText {
            promptStrings.append(text)
        }
        let combinedPrompt = promptStrings.joined(separator: "\n---\n")
        
        // Here would be call to LLM or processing
        // For now, simulate a response
        let response = "Generated configurations based on prompt."
        
        // Placeholders: returning response as string
        return .string(response)
    }
}

// MARK: - GeneralCell Protocol

protocol GeneralCell {
    func get(key: String) -> ValueType
    func set(key: String, value: ValueType)
    func subscribe(key: String, handler: @escaping (ValueType) -> Void)
}

// MARK: - Identity Placeholder

struct Identity {
    let id: String
}

// MARK: - AppleIntelligenceCell: Setup Intercepts and Bindings

final class AppleIntelligenceCell {
    private var cell: GeneralCell
    private let assistant: AIAssistant
    
    init(cell: GeneralCell) {
        self.cell = cell
        // Register tools if FoundationModels available
        var tools: [Tool] = []
        tools.append(GetConfigurationsTool())
        self.assistant = AIAssistant(tools: tools)
        setupKeys()
        AppleIntelligenceCellBootstrap.seed(into: &self.cell)
    }
    
    private func setupKeys() {
        // Setup intercepts for GET/SET keys
        
        // GET ai.state - snapshot of current state (object)
        cell.subscribe(key: AIKeys.state) { [weak self] _ in
            guard let self = self else { return }
            let snapshot = self.snapshotPayload()
            self.cell.set(key: AIKeys.state, value: snapshot)
        }
        
        // SET ai.discover - start discovery: set status, enqueue intent, publish state snapshot
        cell.subscribe(key: AIKeys.discover) { [weak self] _ in
            guard let self = self else { return }
            self.cell.set(key: AIKeys.status, value: .string("discovering"))
            let intentMessage: ValueType = .object([
                "topic": .string(AITopics.intentRequestConfigurations),
                "title": .string("Discover configurations"),
                "properties": .object([
                    "type": .string("intent"),
                    "contentType": .string("application/json")
                ]),
                "content": .null
            ])
            AIAssistant.enqueueOutboxMessage(
                in: &self.cell,
                topic: AITopics.intentRequestConfigurations,
                title: "Discover configurations",
                type: "intent",
                contentType: "application/json",
                content: .null
            )
            // Also update state snapshot
            let snapshot = self.snapshotPayload()
            self.cell.set(key: AIKeys.state, value: snapshot)
        }
        
        // SET ai.rank - rank candidates if enabled, update recommendations and state
        cell.subscribe(key: AIKeys.rank) { [weak self] _ in
            guard let self = self else { return }
            guard case let .bool(enabled) = self.cell.get(key: AIKeys.rankEnabled), enabled else {
                return
            }
            
            // Extract candidates
            var candidates: [CellConfiguration] = []
            if case let .list(vtCandidates) = self.cell.get(key: AIKeys.candidates) {
                candidates = vtCandidates.compactMap { vt in
                    self.assistant.decodeCellConfiguration(from: vt)
                }
            }
            // Extract weights
            var weightsDict: [String: Double]? = nil
            if case let .object(dict) = self.cell.get(key: AIKeys.rankWeights) {
                var weights: [String: Double] = [:]
                for (key, val) in dict {
                    if case let .string(strVal) = val, let dVal = Double(strVal) {
                        weights[key] = dVal
                    }
                }
                if !weights.isEmpty {
                    weightsDict = weights
                }
            }
            // Rank candidates
            let ranked = self.assistant.rank(candidates: candidates, with: weightsDict)
            let rankedVT = ValueType.list(ranked.map { self.assistant.encodeCellConfiguration($0) })
            self.cell.set(key: AIKeys.candidates, value: rankedVT)
            
            // Enqueue recommendations message
            AIAssistant.enqueueOutboxMessage(
                in: &self.cell,
                topic: AITopics.assistantRecommendations,
                title: "Ranked configurations",
                type: "recommendations",
                contentType: "application/json",
                content: rankedVT
            )
            
            // Update state snapshot
            let snapshot = self.snapshotPayload()
            self.cell.set(key: AIKeys.state, value: snapshot)
        }
        
        // SET ai.ingestConfigurations - parse and update candidates, optionally send response
        cell.subscribe(key: AIKeys.ingestConfigurations) { [weak self] newValue in
            guard let self = self else { return }
            self.assistant.ingestConfigurations(in: &self.cell, from: newValue, requester: Identity(id: "ingestConfigurations"))
        }
        
        // SET ai.sendPrompt - sends prompt with optional payload
        cell.subscribe(key: AIKeys.sendPrompt) { [weak self] payload in
            guard let self = self else { return }
            _ = self.assistant.sendPrompt(in: &self.cell, withPayload: payload)
        }
        
        // Additional intercepts for GET/SET promptText, promptInstructions, sendFlowOnIngest, rankEnabled, etc.
        // For brevity, implementing GET/SET pass-through
        
        // GET/SET promptText
        cell.subscribe(key: AIKeys.promptText) { _ in /* no-op for get */ }
        
        // GET/SET promptInstructions
        cell.subscribe(key: AIKeys.promptInstructions) { _ in /* no-op for get */ }
        
        // GET/SET sendFlowOnIngest
        cell.subscribe(key: AIKeys.sendFlowOnIngest) { _ in /* no-op for get */ }
        
        // GET/SET rankEnabled
        cell.subscribe(key: AIKeys.rankEnabled) { _ in /* no-op for get */ }
        
        // GET lastToolArguments (read-only observable)
        cell.subscribe(key: AIKeys.lastToolArguments) { _ in /* no-op for get */ }
        
        // SET ai.send - generic send endpoint (pass-through, can be implemented later)
        cell.subscribe(key: AIKeys.send) { _ in /* no-op */ }
        
        // SET ai.ensurePurpose & ai.buildCluster - placeholders for maintenance (no-op here)
        cell.subscribe(key: AIKeys.ensurePurpose) { _ in /* no-op */ }
        cell.subscribe(key: AIKeys.buildCluster) { _ in /* no-op */ }
    }
    
    // Snapshot payload returns object of current cell state for ai.state key
    private func snapshotPayload() -> ValueType {
        var dict: [String: ValueType] = [:]
        dict["status"] = cell.get(key: AIKeys.status)
        dict["currentPurposeRef"] = cell.get(key: AIKeys.currentPurposeRef)
        dict["purposeClusterRefs"] = cell.get(key: AIKeys.purposeClusterRefs)
        dict["candidates"] = cell.get(key: AIKeys.candidates)
        dict["promptText"] = cell.get(key: AIKeys.promptText)
        dict["promptInstructions"] = cell.get(key: AIKeys.promptInstructions)
        dict["rankEnabled"] = cell.get(key: AIKeys.rankEnabled)
        dict["rankWeights"] = cell.get(key: AIKeys.rankWeights)
        dict["lastToolArguments"] = cell.get(key: AIKeys.lastToolArguments)
        return .object(dict)
    }
}

// MARK: - Skeleton Bindings (Example Demo Configuration)

struct PortholeBindingViewModel {
    
    struct AppleIntelligenceDemoConfiguration {
        
        static func bindings(for cellReference: CellReference) -> [SkeletonBinding] {
            return [
                .textField(keypath: "\(cellReference.label).\(AIKeys.promptText)", placeholder: "Enter prompt text"),
                .textField(keypath: "\(cellReference.label).\(AIKeys.promptInstructions)", placeholder: "Enter prompt instructions"),
                .button(keypath: "\(cellReference.label).\(AIKeys.sendPrompt)", title: "Send Prompt"),
                .button(keypath: "\(cellReference.label).\(AIKeys.discover)", title: "Discover"),
                .button(keypath: "\(cellReference.label).\(AIKeys.rank)", title: "Rank"),
                .toggle(keypath: "\(cellReference.label).\(AIKeys.rankEnabled)", label: "Rank Enabled"),
                .toggle(keypath: "\(cellReference.label).\(AIKeys.sendFlowOnIngest)", label: "Send Flow On Ingest"),
                .list(topic: AITopics.assistantState, keypath: "\(cellReference.label).\(AIKeys.state)", titleKey: "status", subtitleKey: "currentPurposeRef"),
                .list(topic: AITopics.assistantRecommendations, keypath: "\(cellReference.label).\(AIKeys.candidates)", titleKey: "name"),
                .list(topic: "ai", keypath: "\(cellReference.label).\(AIKeys.outbox)", titleKey: "topic", subtitleKey: "title")
            ]
        }
    }
}

// MARK: - Placeholder Types for Skeleton Bindings

struct CellReference {
    let endpoint: String
    let label: String
    let subscribeFeed: Bool
}

enum SkeletonBinding {
    case textField(keypath: String, placeholder: String)
    case button(keypath: String, title: String)
    case toggle(keypath: String, label: String)
    case list(topic: String, keypath: String, titleKey: String? = nil, subtitleKey: String? = nil)
}

// MARK: - Notes

// This file only contains the core AppleIntelligenceCell architecture and flow per the specification.
// Full implementations of ValueType, GeneralCell, Skeleton UI, and actual FlowElement publishing are assumed
// to be provided elsewhere in the codebase.

///
/// ## Caching av input med `targetKeypath` i Skeleton
///
/// For å gjøre det enkelt å sende inntastet tekst som payload ved knappetrykk, kan du bruke `targetKeypath` i `SkeletonTextField` som en cache for en tilhørende `SkeletonButton`.
///
/// Mønsteret er:
/// - `SkeletonTextField` skriver brukerens inntastede verdi til `targetKeypath`.
/// - `SkeletonButton` trigges på samme keypath; når payload er `nil`, kan emitter hente cached verdi fra `targetKeypath` og sende den som payload til mottakeren.
///
/// Eksempel:
/// ```swift
/// .VStack(SkeletonVStack(elements: [
///     .TextField(SkeletonTextField(
///         text: nil,
///         sourceKeypath: "intelligence.ai.promptText",
///         targetKeypath: "intelligence.ai.sendPrompt", // cache for Button
///         placeholder: "Skriv en prompt…",
///         modifiers: nil
///     )),
///     .Button(SkeletonButton(
///         keypath: "intelligence.ai.sendPrompt",
///         label: "Send",
///         payload: nil // emitter bruker cached verdi fra targetKeypath
///     ))
/// ]))
/// ```
///
/// Alternativt kan `targetKeypath` peke til selve tilstandsverdien (f.eks. `intelligence.ai.promptText`), og `ai.sendPrompt` leser verdien direkte derfra. Valg av mønster avhenger av hvordan din emitter/renderer er implementert. Denne dokumentasjonen anbefaler `targetKeypath`-caching når du ønsker å sende dynamisk tekst som payload til en knapp uten å endre den underliggende modellen.
///

