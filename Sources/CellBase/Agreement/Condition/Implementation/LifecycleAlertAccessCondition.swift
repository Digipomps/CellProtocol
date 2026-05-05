// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Declarative lifecycle alert routing policy.
/// Controls who can receive lifecycle alarms in addition to the owner.
public struct LifecycleAlertAccessCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var allowedIdentityUUIDs: [String]
    public var includeSignatories: Bool

    public init(
        allowedIdentityUUIDs: [String],
        includeSignatories: Bool = false,
        name: String = "Lifecycle alert access"
    ) {
        self.uuid = UUID().uuidString
        self.name = name
        self.allowedIdentityUUIDs = Array(Set(allowedIdentityUUIDs.filter { !$0.isEmpty })).sorted()
        self.includeSignatories = includeSignatories
    }

    public func isMet(context: ConnectContext) async -> ConditionState {
        .met
    }

    public func resolve(context: ConnectContext) async {}
}
