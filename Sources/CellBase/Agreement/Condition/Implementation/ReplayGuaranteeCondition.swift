// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum ReplayGuaranteeMode: String, Codable, Sendable {
    case none
    case snapshot
    case eventLog
}

/// Declarative contract term for replay obligations.
/// This is policy metadata and does not block connection admission by itself.
public struct ReplayGuaranteeCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var mode: ReplayGuaranteeMode
    public var minimumRetentionTicks: UInt64
    public var allowEventLogGap: Bool

    public init(
        mode: ReplayGuaranteeMode,
        minimumRetentionTicks: UInt64,
        allowEventLogGap: Bool = false,
        name: String = "Replay guarantee"
    ) {
        self.uuid = UUID().uuidString
        self.name = name
        self.mode = mode
        self.minimumRetentionTicks = minimumRetentionTicks
        self.allowEventLogGap = allowEventLogGap
    }

    public func isMet(context: ConnectContext) async -> ConditionState {
        .met
    }

    public func resolve(context: ConnectContext) async {}
}
