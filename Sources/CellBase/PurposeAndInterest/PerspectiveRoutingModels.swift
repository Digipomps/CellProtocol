// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct PerspectiveRoutingPurpose: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct PerspectiveRoutingTarget: Codable, Equatable, Sendable {
    public var reference: RelationalConfigurationReference
    public var name: String
    public var purposeRefs: [String]
    public init(reference: RelationalConfigurationReference, name: String, purposeRefs: [String]) {
        self.reference = reference; self.name = name; self.purposeRefs = purposeRefs
    }
}
public struct PerspectiveRoutingConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var confirm: Bool
    public var envelopeVersion: String
    public var journalVersion: Int
    public var sources: [ContextSource]
    public var purposes: [PerspectiveRoutingPurpose]
    public var configurations: [RelationalConfigurationReference]
    public init(enabled: Bool, confirm: Bool, sources: [ContextSource], purposes: [PerspectiveRoutingPurpose], configurations: [RelationalConfigurationReference]) {
        self.enabled = enabled; self.confirm = confirm; self.sources = sources; self.purposes = purposes
        self.configurations = configurations; self.envelopeVersion = "2.0"; self.journalVersion = 2
    }
    public static var disabled: Self { .init(enabled: false, confirm: false, sources: [], purposes: [], configurations: []) }
    public func validate() throws {
        guard confirm, envelopeVersion == "2.0", journalVersion == 2,
              sources.count <= 16, purposes.count <= 32, configurations.count <= 64,
              Set(sources.map(\.sourceID)).count == sources.count,
              Set(purposes.map(\.id)).count == purposes.count,
              Set(configurations.map(\.node.id)).count == configurations.count,
              !enabled || (!sources.isEmpty && !purposes.isEmpty && !configurations.isEmpty),
              purposes.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 && !$0.title.isEmpty && $0.title.utf8.count <= 512 }),
              sources.allSatisfy({ !$0.sourceID.isEmpty && $0.sourceID.utf8.count <= 256 && $0.enabled && !$0.snapshotKey.isEmpty && URL(string: $0.endpoint)?.scheme == "cell" }) else { throw PerspectiveRoutingError.invalidInput("explicit opt-in and bounded exact scope required") }
        try configurations.forEach { try $0.validate() }
    }
}
public enum PerspectiveRoutingError: Error { case invalidInput(String), unavailable(String), staleDecision, persistenceConflict }
/// Issued by the trusted native/web host adapter, never by a Cell action payload.
/// The adapter retains one binding for its real session lifetime.
public struct PerspectiveRoutingHostSession: Sendable {
    public let id: String
    public let proof: String
    internal init(id: String, proof: String) { self.id = id; self.proof = proof }
}
public struct PerspectiveRoutingFeedback: Codable, Sendable {
    public var eventID: String
    public var episodeID: String
    public var sessionID: String
    public var sessionProof: String
    public var kind: RelationalUserFeedbackKind
    public var occurredAt: TimeInterval
    public var purposeRef: String
    public var decisionRevision: Int
    public var configuration: RelationalConfigurationReference?
    public init(eventID: String, episodeID: String, sessionID: String, sessionProof: String, kind: RelationalUserFeedbackKind, occurredAt: TimeInterval,
                purposeRef: String, decisionRevision: Int, configuration: RelationalConfigurationReference? = nil) {
        self.eventID = eventID; self.episodeID = episodeID; self.sessionID = sessionID; self.sessionProof = sessionProof; self.kind = kind
        self.occurredAt = occurredAt; self.purposeRef = purposeRef; self.decisionRevision = decisionRevision; self.configuration = configuration
    }
}
public struct PerspectiveRoutingRenderReceipt: Codable, Sendable {
    public var decisionRevision: Int
    public var episodeID: String
    public var sessionID: String
    public var sessionProof: String
    public var requestID: String
    public var configuration: RelationalConfigurationReference
    public var rendered: Bool
    public init(decisionRevision: Int, episodeID: String, sessionID: String, sessionProof: String, requestID: String,
                configuration: RelationalConfigurationReference, rendered: Bool) {
        self.decisionRevision = decisionRevision; self.episodeID = episodeID; self.sessionID = sessionID; self.sessionProof = sessionProof
        self.requestID = requestID; self.configuration = configuration; self.rendered = rendered
    }
}
public struct PerspectiveRoutingLoadRequest: Codable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var decisionRevision: Int
    public var episodeID: String
    public var purposeRef: String
    public var target: PerspectiveRoutingTarget
    public var automatic: Bool
}
public struct PerspectiveRoutingChoiceScore: Codable, Sendable {
    public var id: String
    public var title: String
    public var score: Double
    public var evidenceCount: Int
    public var distinctSessionCount: Int
    public var eligible: Bool
}
public struct PerspectiveRoutingState: Codable, Sendable {
    public var enabled: Bool
    public var revision: Int
    public var episodeID: String
    public var phase: String
    public var explanation: String
    public var purposeChoices: [PerspectiveRoutingChoiceScore]
    public var configurationChoices: [PerspectiveRoutingChoiceScore]
    public var selectedPurposeRef: String?
    public var activeConfiguration: RelationalConfigurationReference?
    public var loadRequest: PerspectiveRoutingLoadRequest?
    public var contextValidUntil: Date?
    public var functionalPolicyID: String = "perspective-routing-functional-v1"
    public var statisticallyQualified: Bool = false
}

/// Active-purpose projection of one verified committed routing revision.
/// Activation priority is distinct from the motor's learned certainty score.
public struct PerspectiveRoutingPurposeProjection: Sendable {
    public let revision: Int
    public let selected: PerspectiveRoutingPurpose
    public let scope: [PerspectiveRoutingPurpose]
}

struct PerspectiveRoutingAcceptedFeedback: Codable {
    var feedback: PerspectiveRoutingFeedback
    var canonicalPayload: Data
    var motorApplied: Bool
    var motorSequence: UInt64
}
struct PerspectiveRoutingDocument: Codable {
    var schema: Int = 1
    var ownerUUID: String
    var cellUUID: String
    var revision: Int = 0
    var configuration: PerspectiveRoutingConfiguration = .disabled
    var context: PerspectiveContextState = .init()
    var renderedPurpose: String?
    var motorJournal: RelationalLearningPersistedJournal = .empty
    var accepted: [String: PerspectiveRoutingAcceptedFeedback] = [:]
    var state: PerspectiveRoutingState
    var selectedPurpose: String?
    var selectedConfiguration: RelationalConfigurationReference?
    var rendered: PerspectiveRoutingRenderReceipt?
    var episodeKinds: Set<String> = []
    var correctionPending: Bool = false
    var failedTargets: Set<String> = []
    init(ownerUUID: String, cellUUID: String) {
        self.ownerUUID = ownerUUID; self.cellUUID = cellUUID
        self.state = .init(enabled: false, revision: 0, episodeID: UUID().uuidString, phase: "disabled", explanation: "Automatisk tilpasning er av.", purposeChoices: [], configurationChoices: [])
    }
}
