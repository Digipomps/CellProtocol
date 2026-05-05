// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum AdmissionChallengePayloadState: String, Codable {
    case unmet
    case denied
}

// Codable-only because helperCellConfiguration remains an opaque transport object
// and does not currently provide stable Equatable/Hashable semantics.
public struct AdmissionChallengeIssueRecord: Codable {
    public var conditionName: String
    public var conditionType: String
    public var state: ConditionState
    public var reasonCode: String
    public var userMessage: String
    public var requiredAction: String
    public var canAutoResolve: Bool
    public var helperCellConfiguration: CellConfiguration?
    public var developerHint: String?

    public init(
        conditionName: String,
        conditionType: String,
        state: ConditionState,
        reasonCode: String,
        userMessage: String,
        requiredAction: String,
        canAutoResolve: Bool,
        helperCellConfiguration: CellConfiguration? = nil,
        developerHint: String? = nil
    ) {
        self.conditionName = conditionName
        self.conditionType = conditionType
        self.state = state
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.requiredAction = requiredAction
        self.canAutoResolve = canAutoResolve
        self.helperCellConfiguration = helperCellConfiguration
        self.developerHint = developerHint
    }
}

public struct AdmissionChallengePayload: Codable {
    public var state: AdmissionChallengePayloadState
    public var connectState: ConnectState
    public var agreement: Agreement
    public var context: ConnectContext
    public var issues: [AdmissionChallengeIssueRecord]
    public var issueCount: Int
    public var sessionId: String?
    public var session: AdmissionSession?
    public var reasonCode: String?
    public var userMessage: String?
    public var requiredAction: String?
    public var canAutoResolve: Bool?
    public var helperCellConfiguration: CellConfiguration?
    public var developerHint: String?

    public init(
        state: AdmissionChallengePayloadState,
        connectState: ConnectState,
        agreement: Agreement,
        context: ConnectContext,
        issues: [AdmissionChallengeIssueRecord],
        issueCount: Int,
        sessionId: String? = nil,
        session: AdmissionSession? = nil,
        reasonCode: String? = nil,
        userMessage: String? = nil,
        requiredAction: String? = nil,
        canAutoResolve: Bool? = nil,
        helperCellConfiguration: CellConfiguration? = nil,
        developerHint: String? = nil
    ) {
        self.state = state
        self.connectState = connectState
        self.agreement = agreement
        self.context = context
        self.issues = issues
        self.issueCount = issueCount
        self.sessionId = sessionId
        self.session = session
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.requiredAction = requiredAction
        self.canAutoResolve = canAutoResolve
        self.helperCellConfiguration = helperCellConfiguration
        self.developerHint = developerHint
    }

    public var primaryIssue: AdmissionChallengeIssueRecord? {
        issues.first
    }
}

public struct AdmissionRetryRequest: Codable, Hashable {
    public var sessionId: String
    public var requesterUUID: String?
    public var note: String?

    public init(sessionId: String, requesterUUID: String? = nil, note: String? = nil) {
        self.sessionId = sessionId
        self.requesterUUID = requesterUUID
        self.note = note
    }
}
