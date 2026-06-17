// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 18/09/2023.
//

import Foundation

public enum PurposeResolutionStatus: String, Codable, Equatable {
    case started
    case succeeded
    case failed
}

public struct PurposeResolutionRecord: Codable, Equatable {
    public var purposeRef: String
    public var status: PurposeResolutionStatus
    public var resolvedAt: TimeInterval
    public var metadata: [String: String]

    public init(
        purposeRef: String,
        status: PurposeResolutionStatus = .succeeded,
        resolvedAt: TimeInterval,
        metadata: [String: String] = [:]
    ) {
        self.purposeRef = purposeRef
        self.status = status
        self.resolvedAt = resolvedAt
        self.metadata = metadata
    }
}

public struct InterestConditionContext: Equatable {
    public var evaluatedAt: TimeInterval
    public var purposeResolutions: [PurposeResolutionRecord]
    public var metadataTimestamps: [String: TimeInterval]
    public var runtimeStatuses: [String: String]

    public init(
        evaluatedAt: TimeInterval = Date().timeIntervalSince1970,
        purposeResolutions: [PurposeResolutionRecord] = [],
        metadataTimestamps: [String: TimeInterval] = [:],
        runtimeStatuses: [String: String] = [:]
    ) {
        self.evaluatedAt = evaluatedAt
        self.purposeResolutions = purposeResolutions
        self.metadataTimestamps = metadataTimestamps
        self.runtimeStatuses = runtimeStatuses
    }
}

public struct PurposeSolvedWithinCondition: Codable, Equatable {
    public var purposeRef: String
    public var maxAgeSeconds: TimeInterval
    public var status: PurposeResolutionStatus

    public init(
        purposeRef: String,
        maxAgeSeconds: TimeInterval,
        status: PurposeResolutionStatus = .succeeded
    ) {
        self.purposeRef = purposeRef
        self.maxAgeSeconds = max(0.0, maxAgeSeconds)
        self.status = status
    }
}

public struct MetadataFreshnessCondition: Codable, Equatable {
    public var key: String
    public var maxAgeSeconds: TimeInterval

    public init(key: String, maxAgeSeconds: TimeInterval) {
        self.key = key
        self.maxAgeSeconds = max(0.0, maxAgeSeconds)
    }
}

public indirect enum InterestCondition: Codable, Equatable {
    case always
    case purposeSolvedWithin(PurposeSolvedWithinCondition)
    case metadataFreshness(MetadataFreshnessCondition)
    case all([InterestCondition])
    case any([InterestCondition])
    case not(InterestCondition)

    enum CodingKeys: String, CodingKey {
        case type
        case purposeRef
        case maxAgeSeconds
        case status
        case key
        case conditions
        case condition
    }

    enum ConditionType: String, Codable {
        case always
        case purposeSolvedWithin
        case metadataFreshness
        case all
        case any
        case not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConditionType.self, forKey: .type)
        switch type {
        case .always:
            self = .always
        case .purposeSolvedWithin:
            self = .purposeSolvedWithin(
                PurposeSolvedWithinCondition(
                    purposeRef: try container.decode(String.self, forKey: .purposeRef),
                    maxAgeSeconds: try container.decode(TimeInterval.self, forKey: .maxAgeSeconds),
                    status: try container.decodeIfPresent(PurposeResolutionStatus.self, forKey: .status) ?? .succeeded
                )
            )
        case .metadataFreshness:
            self = .metadataFreshness(
                MetadataFreshnessCondition(
                    key: try container.decode(String.self, forKey: .key),
                    maxAgeSeconds: try container.decode(TimeInterval.self, forKey: .maxAgeSeconds)
                )
            )
        case .all:
            self = .all(try container.decode([InterestCondition].self, forKey: .conditions))
        case .any:
            self = .any(try container.decode([InterestCondition].self, forKey: .conditions))
        case .not:
            self = .not(try container.decode(InterestCondition.self, forKey: .condition))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try container.encode(ConditionType.always, forKey: .type)
        case .purposeSolvedWithin(let condition):
            try container.encode(ConditionType.purposeSolvedWithin, forKey: .type)
            try container.encode(condition.purposeRef, forKey: .purposeRef)
            try container.encode(condition.maxAgeSeconds, forKey: .maxAgeSeconds)
            try container.encode(condition.status, forKey: .status)
        case .metadataFreshness(let condition):
            try container.encode(ConditionType.metadataFreshness, forKey: .type)
            try container.encode(condition.key, forKey: .key)
            try container.encode(condition.maxAgeSeconds, forKey: .maxAgeSeconds)
        case .all(let conditions):
            try container.encode(ConditionType.all, forKey: .type)
            try container.encode(conditions, forKey: .conditions)
        case .any(let conditions):
            try container.encode(ConditionType.any, forKey: .type)
            try container.encode(conditions, forKey: .conditions)
        case .not(let condition):
            try container.encode(ConditionType.not, forKey: .type)
            try container.encode(condition, forKey: .condition)
        }
    }

    public func evaluate(in context: InterestConditionContext?) -> Bool {
        switch self {
        case .always:
            return true
        case .purposeSolvedWithin(let condition):
            guard let context else { return false }
            return context.purposeResolutions.contains { record in
                guard record.purposeRef == condition.purposeRef,
                      record.status == condition.status,
                      record.resolvedAt <= context.evaluatedAt else {
                    return false
                }
                return context.evaluatedAt - record.resolvedAt <= condition.maxAgeSeconds
            }
        case .metadataFreshness(let condition):
            guard let context,
                  let timestamp = context.metadataTimestamps[condition.key],
                  timestamp <= context.evaluatedAt else {
                return false
            }
            return context.evaluatedAt - timestamp <= condition.maxAgeSeconds
        case .all(let conditions):
            return conditions.allSatisfy { $0.evaluate(in: context) }
        case .any(let conditions):
            return conditions.contains { $0.evaluate(in: context) }
        case .not(let condition):
            return !condition.evaluate(in: context)
        }
    }
}

public struct DefaultInterestConstraint: InterestConstraint {
    func within() -> Bool {
        return true
    }
}
