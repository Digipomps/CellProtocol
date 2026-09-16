// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// The provenance class of one audio-analysis claim.
///
/// Keep this enum closed: consumers must not silently treat a new claim class
/// as if it had one of the existing provenance guarantees.
public enum AudioAnalysisTier: String, Codable, CaseIterable, Sendable {
    case computed
    case inferred
    case modelOpinion = "model_opinion"
    case declared
}

/// A JSON-compatible value used by the heterogeneous fields in an analysis.
public indirect enum AudioAnalysisValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([AudioAnalysisValue])
    case object([String: AudioAnalysisValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AudioAnalysisValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AudioAnalysisValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Reproduction information for one field.
public struct AudioAnalysisProducer: Codable, Equatable, Sendable {
    public let toolOrModel: String
    public let version: String
    public let paramsOrPrompt: AudioAnalysisValue

    public init(
        toolOrModel: String,
        version: String,
        paramsOrPrompt: AudioAnalysisValue
    ) {
        self.toolOrModel = toolOrModel
        self.version = version
        self.paramsOrPrompt = paramsOrPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case toolOrModel = "tool_or_model"
        case version
        case paramsOrPrompt = "params_or_prompt"
    }
}

/// Untrusted field input. `AudioAnalysisRecord` converts this to a validated
/// `AudioAnalysisField` or rejects the complete record.
public struct AudioAnalysisFieldInput: Codable, Equatable, Sendable {
    public let value: AudioAnalysisValue
    public let tier: AudioAnalysisTier?
    public let producer: AudioAnalysisProducer?
    public let confidence: Double?
    public let labelVocabulary: [String]?
    public let computedAt: String

    public init(
        value: AudioAnalysisValue,
        tier: AudioAnalysisTier?,
        producer: AudioAnalysisProducer?,
        confidence: Double? = nil,
        labelVocabulary: [String]? = nil,
        computedAt: String
    ) {
        self.value = value
        self.tier = tier
        self.producer = producer
        self.confidence = confidence
        self.labelVocabulary = labelVocabulary
        self.computedAt = computedAt
    }
}

public enum AudioAnalysisRecordError: Error, Equatable, Sendable {
    case missingTier(field: String)
    case missingProducer(field: String)
    case confidenceForbidden(field: String, tier: AudioAnalysisTier)
    case confidenceRequired(field: String)
    case confidenceOutOfRange(field: String)
    case labelVocabularyRequired(field: String)
}

/// A validated audio-analysis field. Its initializer is intentionally private;
/// records are the validation boundary for untrusted field input.
public struct AudioAnalysisField: Codable, Equatable, Sendable {
    public let value: AudioAnalysisValue
    public let tier: AudioAnalysisTier
    public let producer: AudioAnalysisProducer
    public let confidence: Double?
    public let labelVocabulary: [String]?
    public let computedAt: String

    fileprivate init(validating input: AudioAnalysisFieldInput, named fieldName: String) throws {
        guard let tier = input.tier else {
            throw AudioAnalysisRecordError.missingTier(field: fieldName)
        }
        guard let producer = input.producer else {
            throw AudioAnalysisRecordError.missingProducer(field: fieldName)
        }

        switch tier {
        case .inferred:
            guard let confidence = input.confidence else {
                throw AudioAnalysisRecordError.confidenceRequired(field: fieldName)
            }
            guard confidence.isFinite, (0.0 ... 1.0).contains(confidence) else {
                throw AudioAnalysisRecordError.confidenceOutOfRange(field: fieldName)
            }
            guard let vocabulary = input.labelVocabulary,
                  !vocabulary.isEmpty,
                  vocabulary.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AudioAnalysisRecordError.labelVocabularyRequired(field: fieldName)
            }
        case .computed, .modelOpinion, .declared:
            if input.confidence != nil {
                throw AudioAnalysisRecordError.confidenceForbidden(field: fieldName, tier: tier)
            }
        }

        self.value = input.value
        self.tier = tier
        self.producer = producer
        self.confidence = input.confidence
        self.labelVocabulary = input.labelVocabulary
        self.computedAt = input.computedAt
    }

    public init(from decoder: Decoder) throws {
        let input = try AudioAnalysisFieldInput(from: decoder)
        let fieldName = decoder.codingPath.last?.stringValue ?? "<unknown>"
        try self.init(validating: input, named: fieldName)
    }
}

/// A typed set of derived claims about the audio bytes identified by
/// `contentHash`. The record contains no raw audio.
public struct AudioAnalysisRecord: Codable, Equatable, Sendable {
    public let contentHash: String
    public let fields: [String: AudioAnalysisField]

    public init(
        contentHash: String,
        fields inputFields: [String: AudioAnalysisFieldInput]
    ) throws {
        self.contentHash = contentHash
        self.fields = try inputFields.reduce(into: [:]) { result, entry in
            result[entry.key] = try AudioAnalysisField(validating: entry.value, named: entry.key)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let contentHash = try container.decode(String.self, forKey: .contentHash)
        let inputFields = try container.decode([String: AudioAnalysisFieldInput].self, forKey: .fields)
        try self.init(contentHash: contentHash, fields: inputFields)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(fields, forKey: .fields)
    }

    private enum CodingKeys: String, CodingKey {
        case contentHash
        case fields
    }
}
