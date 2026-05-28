// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum CellMemoryExpiryAction: String, Codable {
    case notifyOnly
    case unloadFromMemory
    case persistAndUnload
}

public enum CellPersistedDataExpiryAction: String, Codable {
    case notifyOnly
    case deletePersistedData
}

public struct CellLifecyclePolicy: Codable {
    public var memoryTTL: TimeInterval?
    public var warningLeadTime: TimeInterval
    public var persistedDataTTL: TimeInterval?
    public var persistedDataExpiryAction: CellPersistedDataExpiryAction
    public var memoryExpiryAction: CellMemoryExpiryAction

    public init(
        memoryTTL: TimeInterval? = nil,
        warningLeadTime: TimeInterval = 0,
        persistedDataTTL: TimeInterval? = nil,
        persistedDataExpiryAction: CellPersistedDataExpiryAction = .notifyOnly,
        memoryExpiryAction: CellMemoryExpiryAction = .notifyOnly
    ) {
        self.memoryTTL = memoryTTL
        self.warningLeadTime = max(0, warningLeadTime)
        self.persistedDataTTL = persistedDataTTL
        self.persistedDataExpiryAction = persistedDataExpiryAction
        self.memoryExpiryAction = memoryExpiryAction
    }

    enum CodingKeys: String, CodingKey {
        case memoryTTL
        case warningLeadTime
        case persistedDataTTL
        case persistedDataExpiryAction
        case memoryExpiryAction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.memoryTTL = try values.decodeIfPresent(TimeInterval.self, forKey: .memoryTTL)
        self.warningLeadTime = max(0, try values.decodeIfPresent(TimeInterval.self, forKey: .warningLeadTime) ?? 0)
        self.persistedDataTTL = try values.decodeIfPresent(TimeInterval.self, forKey: .persistedDataTTL)
        self.persistedDataExpiryAction = try values.decodeIfPresent(
            CellPersistedDataExpiryAction.self,
            forKey: .persistedDataExpiryAction
        ) ?? .notifyOnly
        self.memoryExpiryAction = try values.decodeIfPresent(
            CellMemoryExpiryAction.self,
            forKey: .memoryExpiryAction
        ) ?? .notifyOnly
    }
}

public enum CellLifecycleEventType: String, Codable {
    case memoryTTLWarning
    case memoryTTLExpired
    case memoryEvicted
    case persistedDataTTLExpired
    case persistedDataDeleted
}

public struct CellLifecycleEvent: Codable {
    public let type: CellLifecycleEventType
    public let uuid: String
    public let endpoint: String?
    public let identityUUID: String?
    public let recipientIdentityUUIDs: [String]?
    public let timestamp: Date
    public let secondsRemaining: TimeInterval?
    public let memoryTTL: TimeInterval?
    public let persistedDataTTL: TimeInterval?
    public let requiresAction: Bool?
    public let availableResponses: [String]?

    public init(
        type: CellLifecycleEventType,
        uuid: String,
        endpoint: String?,
        identityUUID: String?,
        recipientIdentityUUIDs: [String]? = nil,
        timestamp: Date = Date(),
        secondsRemaining: TimeInterval? = nil,
        memoryTTL: TimeInterval? = nil,
        persistedDataTTL: TimeInterval? = nil,
        requiresAction: Bool? = nil,
        availableResponses: [String]? = nil
    ) {
        self.type = type
        self.uuid = uuid
        self.endpoint = endpoint
        self.identityUUID = identityUUID
        self.recipientIdentityUUIDs = recipientIdentityUUIDs
        self.timestamp = timestamp
        self.secondsRemaining = secondsRemaining
        self.memoryTTL = memoryTTL
        self.persistedDataTTL = persistedDataTTL
        self.requiresAction = requiresAction
        self.availableResponses = availableResponses
    }
}

public enum CellLifecycleEventResponse {
    case useDefaultAction
    case ignore
    case extendMemoryTTL(TimeInterval)
    case extendPersistedDataTTL(TimeInterval)
    case unloadFromMemory
    case persistAndUnload
    case deletePersistedData
}

public protocol CellLifecycleEventResponder: AnyObject {
    func resolver(_ resolver: CellResolver, didReceive event: CellLifecycleEvent) async -> CellLifecycleEventResponse
}
