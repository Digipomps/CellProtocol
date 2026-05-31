// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct SpatialFeaturePayload: Codable, Equatable {
    public static let schemaName = "haven.spatial.feature.v1"

    public var schema: String
    public var featureId: String
    public var kind: String
    public var positionDisclosure: String
    public var accuracyMeters: Double?
    public var purposeRefs: [String]
    public var interestRefs: [String]
    public var matchExplanation: SpatialMatchExplanation?
    public var contactEndpoint: SpatialContactEndpointReference?
    public var mediaRefs: [SpatialMediaReference]
    public var visibility: String
    public var expiresAt: String?
    public var sourceCellEndpoint: String?
    public var proofRefs: [String]

    public init(
        schema: String = SpatialFeaturePayload.schemaName,
        featureId: String,
        kind: String,
        positionDisclosure: String,
        accuracyMeters: Double? = nil,
        purposeRefs: [String] = [],
        interestRefs: [String] = [],
        matchExplanation: SpatialMatchExplanation? = nil,
        contactEndpoint: SpatialContactEndpointReference? = nil,
        mediaRefs: [SpatialMediaReference] = [],
        visibility: String,
        expiresAt: String? = nil,
        sourceCellEndpoint: String? = nil,
        proofRefs: [String] = []
    ) {
        self.schema = schema
        self.featureId = featureId
        self.kind = kind
        self.positionDisclosure = positionDisclosure
        self.accuracyMeters = accuracyMeters
        self.purposeRefs = purposeRefs
        self.interestRefs = interestRefs
        self.matchExplanation = matchExplanation
        self.contactEndpoint = contactEndpoint
        self.mediaRefs = mediaRefs
        self.visibility = visibility
        self.expiresAt = expiresAt
        self.sourceCellEndpoint = sourceCellEndpoint
        self.proofRefs = proofRefs
    }

    public static func decode(from value: ValueType?) -> SpatialFeaturePayload? {
        SpatialFeatureValueCodec.decode(SpatialFeaturePayload.self, from: value)
    }

    public static func decode(fromProperties properties: Object?) -> SpatialFeaturePayload? {
        guard let properties else { return nil }
        return decode(from: .object(properties))
    }

    public var valueType: ValueType? {
        SpatialFeatureValueCodec.encode(self)
    }

    public var mapFeatureProperties: Object? {
        guard case .object(let object)? = valueType else {
            return nil
        }
        return object
    }
}

public struct SpatialMatchExplanation: Codable, Equatable {
    public var summary: String
    public var matchedPurposeRefs: [String]
    public var matchedInterestRefs: [String]
    public var score: Double?

    public init(
        summary: String,
        matchedPurposeRefs: [String] = [],
        matchedInterestRefs: [String] = [],
        score: Double? = nil
    ) {
        self.summary = summary
        self.matchedPurposeRefs = matchedPurposeRefs
        self.matchedInterestRefs = matchedInterestRefs
        self.score = score
    }
}

public struct SpatialContactEndpointReference: Codable, Equatable {
    public var endpointId: String
    public var displayName: String?
    public var cellEndpoint: String?
    public var capabilityRef: String?

    public init(
        endpointId: String,
        displayName: String? = nil,
        cellEndpoint: String? = nil,
        capabilityRef: String? = nil
    ) {
        self.endpointId = endpointId
        self.displayName = displayName
        self.cellEndpoint = cellEndpoint
        self.capabilityRef = capabilityRef
    }
}

public struct SpatialMediaReference: Codable, Equatable {
    public var id: String
    public var kind: String
    public var title: String?
    public var mimeType: String?
    public var cellEndpoint: String?
    public var previewKeypath: String?
    public var metadata: Object?

    public init(
        id: String,
        kind: String,
        title: String? = nil,
        mimeType: String? = nil,
        cellEndpoint: String? = nil,
        previewKeypath: String? = nil,
        metadata: Object? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.mimeType = mimeType
        self.cellEndpoint = cellEndpoint
        self.previewKeypath = previewKeypath
        self.metadata = metadata
    }
}

private enum SpatialFeatureValueCodec {
    static func encode<T: Encodable>(_ value: T) -> ValueType? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(ValueType.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: ValueType?) -> T? {
        guard let value,
              let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
