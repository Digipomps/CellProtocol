// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Optional remediation metadata that conditions can provide when admission
/// cannot be completed automatically.
public struct ConnectChallengeDescriptor: Codable {
    public var reasonCode: String
    public var userMessage: String
    public var requiredAction: String
    public var canAutoResolve: Bool
    public var helperCellConfiguration: CellConfiguration?
    public var developerHint: String?

    public init(
        reasonCode: String,
        userMessage: String,
        requiredAction: String,
        canAutoResolve: Bool = false,
        helperCellConfiguration: CellConfiguration? = nil,
        developerHint: String? = nil
    ) {
        self.reasonCode = reasonCode
        self.userMessage = userMessage
        self.requiredAction = requiredAction
        self.canAutoResolve = canAutoResolve
        self.helperCellConfiguration = helperCellConfiguration
        self.developerHint = developerHint
    }
}

/// Additive, opt-in protocol for conditions that can explain how to resolve a
/// connect/admission challenge for the active identity.
public protocol ConnectChallengeProvidingCondition {
    func connectChallengeDescriptor(context: ConnectContext) async -> ConnectChallengeDescriptor?
}
