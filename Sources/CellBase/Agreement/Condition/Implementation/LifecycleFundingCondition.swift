// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum LifecycleBillingTier: String, Codable, Sendable {
    case none
    case hotOnly
    case hotAndCold
    case nonExpiring
}

/// Declarative contract term for who pays and what lifecycle tier is funded.
/// This does not enforce payment state directly; runtime maps it into TTL policy.
public struct LifecycleFundingCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var payerIdentityUUID: String
    public var billingTier: LifecycleBillingTier
    public var maxHotTTLTicks: UInt64?
    public var maxColdTTLTicks: UInt64?
    public var fundedUntilTick: UInt64?

    public init(
        payerIdentityUUID: String,
        billingTier: LifecycleBillingTier,
        maxHotTTLTicks: UInt64? = nil,
        maxColdTTLTicks: UInt64? = nil,
        fundedUntilTick: UInt64? = nil,
        name: String = "Lifecycle funding"
    ) {
        self.uuid = UUID().uuidString
        self.name = name
        self.payerIdentityUUID = payerIdentityUUID
        self.billingTier = billingTier
        self.maxHotTTLTicks = maxHotTTLTicks
        self.maxColdTTLTicks = maxColdTTLTicks
        self.fundedUntilTick = fundedUntilTick
    }

    public func isMet(context: ConnectContext) async -> ConditionState {
        .met
    }

    public func resolve(context: ConnectContext) async {}
}
