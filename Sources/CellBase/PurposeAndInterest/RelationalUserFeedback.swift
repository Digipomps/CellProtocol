// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct RelationalConfigurationReference: Codable, Hashable, Sendable {
    public var configurationUUID: String
    public var sourceCellEndpoint: String
    public init(configurationUUID: String, sourceCellEndpoint: String) {
        self.configurationUUID = configurationUUID.lowercased(); self.sourceCellEndpoint = sourceCellEndpoint
    }
    private enum CodingKeys: String, CodingKey { case configurationUUID, sourceCellEndpoint }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(configurationUUID: try values.decode(String.self, forKey: .configurationUUID),
                  sourceCellEndpoint: try values.decode(String.self, forKey: .sourceCellEndpoint))
    }
    public var node: RelationalNode { .init(type: .configuration, id: configurationUUID + "|" + sourceCellEndpoint) }
    public func validate() throws {
        guard UUID(uuidString: configurationUUID) != nil, configurationUUID == configurationUUID.lowercased(),
              let url = URL(string: sourceCellEndpoint), url.scheme == "cell", !url.path.isEmpty,
              sourceCellEndpoint.utf8.count <= 1024 else {
            throw RelationalLearningError.invalidEvent("exact configuration UUID and cell endpoint required")
        }
    }
    public init(nodeID: String) throws {
        let parts = nodeID.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RelationalLearningError.invalidEvent("invalid configuration node identity") }
        self.init(configurationUUID: String(parts[0]), sourceCellEndpoint: String(parts[1])); try validate()
    }
}
public enum RelationalUserFeedbackKind: String, Codable, Sendable {
    case purposeChoice, purposeCorrection, configurationChoice, configurationCorrection, confirmedOutcome
}
public struct RelationalUserFeedbackEvent: Codable, Sendable {
    public var eventId: String
    public var timestamp: TimeInterval
    /// Revision actually read by the serialized producer before accepting this original choice.
    public var expectedJournalRevision: UInt64
    public var sessionId: String
    public var episodeId: String
    public var purposeId: String
    public var kind: RelationalUserFeedbackKind
    public var configuration: RelationalConfigurationReference?
    public var contextBlocks: [RelationalContextBlockSignal]
    public init(eventId: String, timestamp: TimeInterval, expectedJournalRevision: UInt64, sessionId: String, episodeId: String, purposeId: String,
                kind: RelationalUserFeedbackKind, configuration: RelationalConfigurationReference? = nil,
                contextBlocks: [RelationalContextBlockSignal] = []) {
        self.eventId = eventId; self.timestamp = timestamp; self.expectedJournalRevision = expectedJournalRevision; self.sessionId = sessionId; self.episodeId = episodeId
        self.purposeId = purposeId; self.kind = kind; self.configuration = configuration; self.contextBlocks = contextBlocks
    }
    public func validate() throws {
        guard timestamp.isFinite, !eventId.isEmpty, !sessionId.isEmpty, !episodeId.isEmpty, !purposeId.isEmpty,
              [eventId, sessionId, episodeId, purposeId].allSatisfy({ $0.utf8.count <= 512 }), contextBlocks.count <= 32,
              Set(contextBlocks.map { $0.node.id }).count == contextBlocks.count else {
            throw RelationalLearningError.invalidEvent("invalid original user feedback identity or context")
        }
        for block in contextBlocks {
            guard !block.domain.isEmpty, !block.blockId.isEmpty, block.confidence.isFinite, (0...1).contains(block.confidence) else {
                throw RelationalLearningError.invalidEvent("invalid feedback context")
            }
        }
        switch kind {
        case .purposeChoice, .purposeCorrection:
            guard configuration == nil, !contextBlocks.isEmpty else {
                throw RelationalLearningError.invalidEvent("purpose feedback requires actual context, without a configuration")
            }
        case .configurationChoice, .configurationCorrection, .confirmedOutcome:
            guard let configuration else { throw RelationalLearningError.invalidEvent("configuration feedback requires an exact target") }
            try configuration.validate()
        }
    }
}
public struct RelationalConfigurationScore: Codable, Sendable {
    public var configuration: RelationalConfigurationReference
    public var score: Double
    public var explain: RelationalEdgeContributionExplain
    public init(configuration: RelationalConfigurationReference, score: Double, explain: RelationalEdgeContributionExplain) {
        self.configuration = configuration; self.score = score; self.explain = explain
    }
}
public extension RelationalLearningEventEnvelope {
    static func from(_ event: RelationalUserFeedbackEvent) throws -> Self {
        Self(eventType: .userFeedback, schemaVersion: "2.0", emittedAt: event.timestamp,
             payload: try RelationalLearningCodec.encodeObject(event))
    }
}
