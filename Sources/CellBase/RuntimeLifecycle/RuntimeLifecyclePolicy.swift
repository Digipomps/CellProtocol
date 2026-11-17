// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RuntimeMemoryExpiryAction: String, Codable, Sendable, Equatable {
    case notifyOnly
    case unload
    case persistAndUnload
}

/// Runtime-only TTL policy. Never serialized into deterministic reducer state.
public struct RuntimeLifecyclePolicy: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case nonExpiring
        case expiring
    }

    public var mode: Mode
    public var memoryTTLTicks: UInt64
    public var memoryWarningLeadTicks: UInt64
    public var persistedDataTTLTicks: UInt64?
    public var tombstoneGraceTicks: UInt64
    public var memoryExpiryAction: RuntimeMemoryExpiryAction
    /// Lead time for the owner warning before persisted data expires.
    /// `nil`/0 means no persisted warning (pre-P1 behaviour). Optional so older
    /// encoded policies still decode.
    public var persistedWarningLeadTicks: UInt64?

    public static let nonExpiring = RuntimeLifecyclePolicy(
        mode: .nonExpiring,
        memoryTTLTicks: 0,
        memoryWarningLeadTicks: 0,
        persistedDataTTLTicks: nil,
        tombstoneGraceTicks: 0,
        memoryExpiryAction: .notifyOnly
    )

    public init(
        mode: Mode,
        memoryTTLTicks: UInt64,
        memoryWarningLeadTicks: UInt64,
        persistedDataTTLTicks: UInt64?,
        tombstoneGraceTicks: UInt64,
        memoryExpiryAction: RuntimeMemoryExpiryAction,
        persistedWarningLeadTicks: UInt64? = nil
    ) {
        self.mode = mode
        self.memoryTTLTicks = memoryTTLTicks
        self.memoryWarningLeadTicks = memoryWarningLeadTicks
        self.persistedDataTTLTicks = persistedDataTTLTicks
        self.tombstoneGraceTicks = tombstoneGraceTicks
        self.memoryExpiryAction = memoryExpiryAction
        self.persistedWarningLeadTicks = persistedWarningLeadTicks
    }

    public static func expiring(
        memoryTTLTicks: UInt64,
        memoryWarningLeadTicks: UInt64 = 0,
        persistedDataTTLTicks: UInt64? = nil,
        tombstoneGraceTicks: UInt64 = 0,
        memoryExpiryAction: RuntimeMemoryExpiryAction = .notifyOnly,
        persistedWarningLeadTicks: UInt64? = nil
    ) -> RuntimeLifecyclePolicy {
        RuntimeLifecyclePolicy(
            mode: .expiring,
            memoryTTLTicks: memoryTTLTicks,
            memoryWarningLeadTicks: memoryWarningLeadTicks,
            persistedDataTTLTicks: persistedDataTTLTicks,
            tombstoneGraceTicks: tombstoneGraceTicks,
            memoryExpiryAction: memoryExpiryAction,
            persistedWarningLeadTicks: persistedWarningLeadTicks
        )
    }

    public var isExpiring: Bool {
        mode == .expiring
    }
}

public enum RuntimeLifecycleEventType: String, Codable, Sendable, Equatable {
    case registered
    case touched
    case memoryTTLWarning
    case memoryTTLExtended
    case persistedTTLExtended
    case persistedTTLWarning
    case memoryExpired
    case unloaded
    case tombstoned
    case hardDeleted
    case leaseGranted
    case leaseExpired
}

public struct RuntimeLifecycleEvent: Codable, Sendable, Equatable {
    public let type: RuntimeLifecycleEventType
    public let cellID: RuntimeCellID
    public let version: UInt64
    public let tick: UInt64
    public let fencingToken: UInt64
    /// Tick the event points at: persisted expiry for warnings/extensions,
    /// hard-delete tick for tombstones. `nil` when not applicable.
    public let deadlineTick: UInt64?

    public init(
        type: RuntimeLifecycleEventType,
        cellID: RuntimeCellID,
        version: UInt64,
        tick: UInt64,
        fencingToken: UInt64,
        deadlineTick: UInt64? = nil
    ) {
        self.type = type
        self.cellID = cellID
        self.version = version
        self.tick = tick
        self.fencingToken = fencingToken
        self.deadlineTick = deadlineTick
    }
}
