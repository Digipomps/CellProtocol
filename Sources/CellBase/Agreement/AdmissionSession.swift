// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct AdmissionSession: Codable, Hashable {
    public var id: String
    public var label: String
    public var requesterUUID: String
    public var targetCellUUID: String
    public var agreementUUID: String
    public var agreementName: String
    public var connectState: String
    public var primaryReasonCode: String?
    public var requiredAction: String?
    public var issueCount: Int
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String = UUID().uuidString,
        label: String,
        requesterUUID: String,
        targetCellUUID: String,
        agreementUUID: String,
        agreementName: String,
        connectState: ConnectState,
        primaryReasonCode: String? = nil,
        requiredAction: String? = nil,
        issueCount: Int = 0,
        createdAt: Int = Int(Date().timeIntervalSince1970),
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.requesterUUID = requesterUUID
        self.targetCellUUID = targetCellUUID
        self.agreementUUID = agreementUUID
        self.agreementName = agreementName
        self.connectState = connectState.rawValue
        self.primaryReasonCode = primaryReasonCode
        self.requiredAction = requiredAction
        self.issueCount = issueCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func refresh(
        targetCellUUID: String,
        agreementUUID: String,
        agreementName: String,
        connectState: ConnectState,
        primaryReasonCode: String?,
        requiredAction: String?,
        issueCount: Int,
        updatedAt: Int = Int(Date().timeIntervalSince1970)
    ) {
        self.targetCellUUID = targetCellUUID
        self.agreementUUID = agreementUUID
        self.agreementName = agreementName
        self.connectState = connectState.rawValue
        self.primaryReasonCode = primaryReasonCode
        self.requiredAction = requiredAction
        self.issueCount = issueCount
        self.updatedAt = updatedAt
    }

    public func asObject() -> Object {
        var object: Object = [
            "id": .string(id),
            "label": .string(label),
            "requesterUUID": .string(requesterUUID),
            "targetCellUUID": .string(targetCellUUID),
            "agreementUUID": .string(agreementUUID),
            "agreementName": .string(agreementName),
            "connectState": .string(connectState),
            "issueCount": .integer(issueCount),
            "createdAt": .integer(createdAt),
            "updatedAt": .integer(updatedAt)
        ]
        if let primaryReasonCode,
           !primaryReasonCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["primaryReasonCode"] = .string(primaryReasonCode)
        }
        if let requiredAction,
           !requiredAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["requiredAction"] = .string(requiredAction)
        }
        return object
    }
}
