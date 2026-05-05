// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RuntimeLifecycleMetric: String, Sendable {
    case activeLoadedCells = "lifecycle.active_loaded_cells"
    case activeUnloadedCells = "lifecycle.active_unloaded_cells"
    case tombstonedCells = "lifecycle.tombstoned_cells"
    case deletedCells = "lifecycle.deleted_cells"
    case wheelScheduled = "lifecycle.wheel.scheduled_total"
    case wheelExpired = "lifecycle.wheel.expired_total"
    case wheelStaleDropped = "lifecycle.wheel.stale_dropped_total"
    case casSuccess = "lifecycle.cas.success_total"
    case casConflict = "lifecycle.cas.conflict_total"
    case leaseAcquireSuccess = "lifecycle.lease.acquire_success_total"
    case leaseAcquireFailure = "lifecycle.lease.acquire_failure_total"
    case expiryMemory = "lifecycle.expiry.memory_total"
    case expiryPersisted = "lifecycle.expiry.persisted_total"
    case expiryHardDelete = "lifecycle.expiry.hard_delete_total"
    case replayBlocked = "lifecycle.replay.blocked_total"
}

public protocol RuntimeLifecycleMetricsSink: Sendable {
    func increment(_ metric: RuntimeLifecycleMetric, by value: Int64, dimensions: [String: String]) async
    func gauge(_ metric: RuntimeLifecycleMetric, value: Int64, dimensions: [String: String]) async
    func histogram(_ metric: RuntimeLifecycleMetric, value: Double, dimensions: [String: String]) async
}

public actor RuntimeNoopLifecycleMetricsSink: RuntimeLifecycleMetricsSink {
    public init() {}

    public func increment(_ metric: RuntimeLifecycleMetric, by value: Int64 = 1, dimensions: [String : String] = [:]) async {}
    public func gauge(_ metric: RuntimeLifecycleMetric, value: Int64, dimensions: [String : String] = [:]) async {}
    public func histogram(_ metric: RuntimeLifecycleMetric, value: Double, dimensions: [String : String] = [:]) async {}
}
