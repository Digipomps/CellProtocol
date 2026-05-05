// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public protocol RuntimeLifecycleEffectSink: Sendable {
    func handle(effect: RuntimeLifecycleEffect) async
}

public actor RuntimeNoopLifecycleEffectSink: RuntimeLifecycleEffectSink {
    public init() {}
    public func handle(effect: RuntimeLifecycleEffect) async {}
}

public enum RuntimeLifecycleManagerError: Error, Sendable {
    case stateNotFound(RuntimeCellID)
    case stateAlreadyExists(RuntimeCellID)
    case casContention(RuntimeCellID)
    case leaseExpired
    case transitionRejected(RuntimeLifecycleRejection)
}

public enum RuntimeLifecycleWarningCommand: Sendable, Equatable {
    case extendMemoryTTL(byTicks: UInt64)
    case extendPersistedTTL(byTicks: UInt64)
    case persistAndUnload
    case delete
    case ignore
}

public actor RuntimeLifecycleManager {
    private let timeSource: MonotonicTimeSource
    private let stateStore: RuntimeLifecycleStateStore
    private let leaseCoordinator: RuntimeLeaseCoordinator
    private let wheel: RuntimeHierarchicalTimingWheel
    private let effectSink: RuntimeLifecycleEffectSink
    private let metricsSink: RuntimeLifecycleMetricsSink
    private let maxCASRetries: Int

    public init(
        timeSource: MonotonicTimeSource,
        stateStore: RuntimeLifecycleStateStore = InMemoryRuntimeLifecycleStateStore(),
        leaseCoordinator: RuntimeLeaseCoordinator = InMemoryRuntimeLeaseCoordinator(),
        wheel: RuntimeHierarchicalTimingWheel = RuntimeHierarchicalTimingWheel(),
        effectSink: RuntimeLifecycleEffectSink = RuntimeNoopLifecycleEffectSink(),
        metricsSink: RuntimeLifecycleMetricsSink = RuntimeNoopLifecycleMetricsSink(),
        maxCASRetries: Int = 16
    ) {
        self.timeSource = timeSource
        self.stateStore = stateStore
        self.leaseCoordinator = leaseCoordinator
        self.wheel = wheel
        self.effectSink = effectSink
        self.metricsSink = metricsSink
        self.maxCASRetries = maxCASRetries
    }

    public func registerCell(
        cellID: RuntimeCellID,
        policy: RuntimeLifecyclePolicy,
        loadedInMemory: Bool,
        persistedSnapshotAvailable: Bool,
        nodeID: String,
        leaseDurationTicks: UInt64
    ) async throws -> (state: RuntimeLifecycleState, lease: RuntimeLease) {
        let now = timeSource.nowTick()
        let lease: RuntimeLease
        do {
            lease = try await leaseCoordinator.acquire(
                cellID: cellID,
                nodeID: nodeID,
                nowTick: now,
                leaseDurationTicks: leaseDurationTicks
            )
            await metricsSink.increment(.leaseAcquireSuccess, by: 1, dimensions: [:])
        } catch {
            await metricsSink.increment(.leaseAcquireFailure, by: 1, dimensions: [:])
            throw error
        }

        var state = RuntimeLifecycleState.initial(
            cellID: cellID,
            nowTick: now,
            loadedInMemory: loadedInMemory,
            persistedSnapshotAvailable: persistedSnapshotAvailable,
            policy: policy
        )
        state.fencingToken = lease.fencingToken
        state.leaseOwnerNodeID = lease.ownerNodeID
        state.leaseValidUntilTick = lease.validUntilTick

        let inserted = await stateStore.putIfAbsent(state)
        guard inserted else {
            throw RuntimeLifecycleManagerError.stateAlreadyExists(cellID)
        }

        var effects: [RuntimeLifecycleEffect] = []
        if let memoryWarningTick = state.memoryWarningTick {
            effects.append(
                .scheduleMemoryWarning(
                    cellID: state.cellID,
                    generation: state.memoryGeneration,
                    fencingToken: state.fencingToken,
                    atTick: memoryWarningTick
                )
            )
        }
        if let memoryTick = state.memoryExpiryTick {
            effects.append(.scheduleMemoryExpiry(
                cellID: state.cellID,
                generation: state.memoryGeneration,
                fencingToken: state.fencingToken,
                atTick: memoryTick
            ))
        }
        if let persistedTick = state.persistedExpiryTick {
            effects.append(.schedulePersistedExpiry(
                cellID: state.cellID,
                generation: state.persistedGeneration,
                fencingToken: state.fencingToken,
                atTick: persistedTick
            ))
        }
        effects.append(
            .emit(
                RuntimeLifecycleEvent(
                    type: .registered,
                    cellID: state.cellID,
                    version: state.version,
                    tick: now,
                    fencingToken: state.fencingToken
                )
            )
        )
        await applyEffects(effects)
        await emitPhaseGauges()
        return (state, lease)
    }

    public func acquireLease(
        cellID: RuntimeCellID,
        nodeID: String,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease {
        let now = timeSource.nowTick()
        let lease: RuntimeLease
        do {
            lease = try await leaseCoordinator.acquire(
                cellID: cellID,
                nodeID: nodeID,
                nowTick: now,
                leaseDurationTicks: leaseDurationTicks
            )
            await metricsSink.increment(.leaseAcquireSuccess, by: 1, dimensions: [:])
        } catch {
            await metricsSink.increment(.leaseAcquireFailure, by: 1, dimensions: [:])
            throw error
        }
        _ = try await applyCAS(cellID: cellID, input: .leaseGranted(lease))
        return lease
    }

    public func renewLease(
        _ lease: RuntimeLease,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease {
        let now = timeSource.nowTick()
        let renewed = try await leaseCoordinator.renew(
            lease: lease,
            nowTick: now,
            leaseDurationTicks: leaseDurationTicks
        )
        _ = try await applyCAS(cellID: lease.cellID, input: .leaseGranted(renewed))
        return renewed
    }

    public func releaseLease(_ lease: RuntimeLease) async throws {
        await leaseCoordinator.release(lease: lease)
        _ = try await applyCAS(
            cellID: lease.cellID,
            input: .leaseExpired(nowTick: timeSource.nowTick(), fencingToken: lease.fencingToken)
        )
    }

    public func applyWarningCommand(
        cellID: RuntimeCellID,
        lease: RuntimeLease,
        command: RuntimeLifecycleWarningCommand
    ) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        switch command {
        case .extendMemoryTTL(let byTicks):
            return try await applyCAS(
                cellID: cellID,
                input: .extendMemoryTTL(
                    byTicks: byTicks,
                    nowTick: timeSource.nowTick(),
                    fencingToken: lease.fencingToken
                )
            )
        case .extendPersistedTTL(let byTicks):
            return try await applyCAS(
                cellID: cellID,
                input: .extendPersistedTTL(
                    byTicks: byTicks,
                    nowTick: timeSource.nowTick(),
                    fencingToken: lease.fencingToken
                )
            )
        case .persistAndUnload:
            return try await applyCAS(
                cellID: cellID,
                input: .persistAndUnloadNow(
                    nowTick: timeSource.nowTick(),
                    fencingToken: lease.fencingToken
                )
            )
        case .delete:
            return try await applyCAS(
                cellID: cellID,
                input: .requestTombstone(
                    nowTick: timeSource.nowTick(),
                    fencingToken: lease.fencingToken
                )
            )
        case .ignore:
            guard let state = await stateStore.read(cellID: cellID) else {
                throw RuntimeLifecycleManagerError.stateNotFound(cellID)
            }
            return state
        }
    }

    public func touch(cellID: RuntimeCellID, lease: RuntimeLease) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        return try await applyCAS(
            cellID: cellID,
            input: .touch(nowTick: timeSource.nowTick(), fencingToken: lease.fencingToken)
        )
    }

    public func extendMemoryTTL(
        cellID: RuntimeCellID,
        byTicks: UInt64,
        lease: RuntimeLease
    ) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        return try await applyCAS(
            cellID: cellID,
            input: .extendMemoryTTL(
                byTicks: byTicks,
                nowTick: timeSource.nowTick(),
                fencingToken: lease.fencingToken
            )
        )
    }

    public func extendPersistedTTL(
        cellID: RuntimeCellID,
        byTicks: UInt64,
        lease: RuntimeLease
    ) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        return try await applyCAS(
            cellID: cellID,
            input: .extendPersistedTTL(
                byTicks: byTicks,
                nowTick: timeSource.nowTick(),
                fencingToken: lease.fencingToken
            )
        )
    }

    public func loadIntoMemory(cellID: RuntimeCellID, lease: RuntimeLease) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        return try await applyCAS(
            cellID: cellID,
            input: .loadIntoMemory(nowTick: timeSource.nowTick(), fencingToken: lease.fencingToken)
        )
    }

    public func unloadFromMemory(cellID: RuntimeCellID, lease: RuntimeLease) async throws -> RuntimeLifecycleState {
        try ensureLeaseValid(lease)
        return try await applyCAS(
            cellID: cellID,
            input: .unloadFromMemory(nowTick: timeSource.nowTick(), fencingToken: lease.fencingToken)
        )
    }

    public func readState(cellID: RuntimeCellID) async -> RuntimeLifecycleState? {
        await stateStore.read(cellID: cellID)
    }

    /// Run bounded expiry processing up to `timeSource.nowTick()`.
    /// Repeated calls are safe and idempotent.
    public func processDueExpiries() async throws {
        let now = timeSource.nowTick()
        let expired = await wheel.advance(toTick: now)
        if !expired.isEmpty {
            await metricsSink.increment(.wheelExpired, by: Int64(expired.count), dimensions: [:])
        }
        var memoryExpiredCount: Int64 = 0
        var persistedExpiredCount: Int64 = 0
        var hardDeleteExpiredCount: Int64 = 0
        for item in expired {
            let input: RuntimeLifecycleInput
            switch item.kind {
            case .memoryWarning:
                input = .memoryWarningFired(
                    generation: item.generation,
                    nowTick: now,
                    fencingToken: item.fencingToken
                )
            case .memoryExpiry:
                memoryExpiredCount &+= 1
                input = .memoryExpiryFired(
                    generation: item.generation,
                    nowTick: now,
                    fencingToken: item.fencingToken
                )
            case .persistedExpiry:
                persistedExpiredCount &+= 1
                input = .persistedExpiryFired(
                    generation: item.generation,
                    nowTick: now,
                    fencingToken: item.fencingToken
                )
            case .hardDelete:
                hardDeleteExpiredCount &+= 1
                input = .hardDeleteFired(
                    generation: item.generation,
                    nowTick: now,
                    fencingToken: item.fencingToken
                )
            }
            do {
                _ = try await applyCAS(cellID: item.cellID, input: input)
            } catch RuntimeLifecycleManagerError.stateNotFound {
                continue
            } catch RuntimeLifecycleManagerError.transitionRejected {
                continue
            }
        }
        if memoryExpiredCount > 0 {
            await metricsSink.increment(.expiryMemory, by: memoryExpiredCount, dimensions: [:])
        }
        if persistedExpiredCount > 0 {
            await metricsSink.increment(.expiryPersisted, by: persistedExpiredCount, dimensions: [:])
        }
        if hardDeleteExpiredCount > 0 {
            await metricsSink.increment(.expiryHardDelete, by: hardDeleteExpiredCount, dimensions: [:])
        }
        await emitPhaseGauges()
    }

    private func ensureLeaseValid(_ lease: RuntimeLease) throws {
        if lease.validUntilTick <= timeSource.nowTick() {
            throw RuntimeLifecycleManagerError.leaseExpired
        }
    }

    private func applyCAS(
        cellID: RuntimeCellID,
        input: RuntimeLifecycleInput
    ) async throws -> RuntimeLifecycleState {
        for _ in 0..<maxCASRetries {
            guard let current = await stateStore.read(cellID: cellID) else {
                throw RuntimeLifecycleManagerError.stateNotFound(cellID)
            }

            let transition = RuntimeLifecycleTransitionReducer.reduce(state: current, input: input)
            if let rejection = transition.rejection {
                throw RuntimeLifecycleManagerError.transitionRejected(rejection)
            }
            if !transition.changed {
                return current
            }

            let swapped = await stateStore.compareAndSwap(
                cellID: cellID,
                expectedVersion: current.version,
                next: transition.state
            )
            if swapped {
                await metricsSink.increment(.casSuccess, by: 1, dimensions: [:])
                await applyEffects(transition.effects)
                return transition.state
            }
            await metricsSink.increment(.casConflict, by: 1, dimensions: [:])
        }

        await metricsSink.increment(.casConflict, by: 1, dimensions: [:])
        throw RuntimeLifecycleManagerError.casContention(cellID)
    }

    private func applyEffects(_ effects: [RuntimeLifecycleEffect]) async {
        for effect in effects {
            switch effect {
            case .scheduleMemoryWarning(let cellID, let generation, let fencingToken, let atTick):
                await metricsSink.increment(.wheelScheduled, by: 1, dimensions: ["kind": RuntimeWheelItemKind.memoryWarning.rawValue])
                await wheel.schedule(
                    RuntimeWheelItem(
                        cellID: cellID,
                        kind: .memoryWarning,
                        generation: generation,
                        fencingToken: fencingToken
                    ),
                    deadlineTick: atTick
                )
            case .scheduleMemoryExpiry(let cellID, let generation, let fencingToken, let atTick):
                await metricsSink.increment(.wheelScheduled, by: 1, dimensions: ["kind": RuntimeWheelItemKind.memoryExpiry.rawValue])
                await wheel.schedule(
                    RuntimeWheelItem(
                        cellID: cellID,
                        kind: .memoryExpiry,
                        generation: generation,
                        fencingToken: fencingToken
                    ),
                    deadlineTick: atTick
                )
            case .schedulePersistedExpiry(let cellID, let generation, let fencingToken, let atTick):
                await metricsSink.increment(.wheelScheduled, by: 1, dimensions: ["kind": RuntimeWheelItemKind.persistedExpiry.rawValue])
                await wheel.schedule(
                    RuntimeWheelItem(
                        cellID: cellID,
                        kind: .persistedExpiry,
                        generation: generation,
                        fencingToken: fencingToken
                    ),
                    deadlineTick: atTick
                )
            case .scheduleHardDelete(let cellID, let generation, let fencingToken, let atTick):
                await metricsSink.increment(.wheelScheduled, by: 1, dimensions: ["kind": RuntimeWheelItemKind.hardDelete.rawValue])
                await wheel.schedule(
                    RuntimeWheelItem(
                        cellID: cellID,
                        kind: .hardDelete,
                        generation: generation,
                        fencingToken: fencingToken
                    ),
                    deadlineTick: atTick
                )
            case .cancelMemoryExpiry(let cellID, let generation, _):
                await wheel.cancel(cellID: cellID, kind: .memoryExpiry, generation: generation)
            case .cancelMemoryWarning(let cellID, let generation, _):
                await wheel.cancel(cellID: cellID, kind: .memoryWarning, generation: generation)
            default:
                await effectSink.handle(effect: effect)
            }
        }
    }

    private func emitPhaseGauges() async {
        let snapshot = await stateStore.snapshotStates()
        guard !snapshot.isEmpty else {
            await metricsSink.gauge(.activeLoadedCells, value: 0, dimensions: [:])
            await metricsSink.gauge(.activeUnloadedCells, value: 0, dimensions: [:])
            await metricsSink.gauge(.tombstonedCells, value: 0, dimensions: [:])
            await metricsSink.gauge(.deletedCells, value: 0, dimensions: [:])
            return
        }

        var activeLoaded: Int64 = 0
        var activeUnloaded: Int64 = 0
        var tombstoned: Int64 = 0
        var deleted: Int64 = 0

        for state in snapshot {
            switch state.phase {
            case .activeLoaded:
                activeLoaded &+= 1
            case .activeUnloaded:
                activeUnloaded &+= 1
            case .tombstoned:
                tombstoned &+= 1
            case .deleted:
                deleted &+= 1
            }
        }

        await metricsSink.gauge(.activeLoadedCells, value: activeLoaded, dimensions: [:])
        await metricsSink.gauge(.activeUnloadedCells, value: activeUnloaded, dimensions: [:])
        await metricsSink.gauge(.tombstonedCells, value: tombstoned, dimensions: [:])
        await metricsSink.gauge(.deletedCells, value: deleted, dimensions: [:])
    }
}
