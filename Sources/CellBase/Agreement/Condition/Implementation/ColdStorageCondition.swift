// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Declarative term for cold-storage behavior when a cell is no longer active in RAM.
public struct ColdStorageCondition: Codable, Condition {
    public var uuid: String
    public var name: String
    public var allowPersistedColdTier: Bool
    public var encryptedAtRestRequired: Bool
    public var deleteIfUnfunded: Bool
    public var tombstoneGraceTicks: UInt64

    public init(
        allowPersistedColdTier: Bool = true,
        encryptedAtRestRequired: Bool = true,
        deleteIfUnfunded: Bool = true,
        tombstoneGraceTicks: UInt64 = 0,
        name: String = "Cold storage policy"
    ) {
        self.uuid = UUID().uuidString
        self.name = name
        self.allowPersistedColdTier = allowPersistedColdTier
        self.encryptedAtRestRequired = encryptedAtRestRequired
        self.deleteIfUnfunded = deleteIfUnfunded
        self.tombstoneGraceTicks = tombstoneGraceTicks
    }

    public func isMet(context: ConnectContext) async -> ConditionState {
        .met
    }

    public func resolve(context: ConnectContext) async {}
}
