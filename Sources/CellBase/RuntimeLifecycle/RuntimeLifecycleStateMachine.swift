// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RuntimeLifecyclePhase: String, Codable, Sendable {
    case activeLoaded
    case activeUnloaded
    case tombstoned
    case deleted
}

public struct RuntimeLifecycleState: Codable, Sendable {
    public var cellID: RuntimeCellID
    public var version: UInt64
    public var phase: RuntimeLifecyclePhase
    public var policy: RuntimeLifecyclePolicy

    public var lastAccessTick: UInt64
    public var persistedSnapshotAvailable: Bool

    public var leaseOwnerNodeID: String?
    public var leaseValidUntilTick: UInt64
    public var fencingToken: UInt64

    public var memoryExpiryTick: UInt64?
    public var memoryWarningTick: UInt64?
    public var memoryGeneration: UInt64
    public var lastProcessedMemoryWarningGeneration: UInt64
    public var lastProcessedMemoryGeneration: UInt64

    public var persistedExpiryTick: UInt64?
    public var persistedGeneration: UInt64
    public var lastProcessedPersistedGeneration: UInt64

    public var hardDeleteTick: UInt64?
    public var hardDeleteGeneration: UInt64
    public var lastProcessedHardDeleteGeneration: UInt64

    public init(
        cellID: RuntimeCellID,
        version: UInt64,
        phase: RuntimeLifecyclePhase,
        policy: RuntimeLifecyclePolicy,
        lastAccessTick: UInt64,
        persistedSnapshotAvailable: Bool,
        leaseOwnerNodeID: String?,
        leaseValidUntilTick: UInt64,
        fencingToken: UInt64,
        memoryExpiryTick: UInt64?,
        memoryWarningTick: UInt64?,
        memoryGeneration: UInt64,
        lastProcessedMemoryWarningGeneration: UInt64,
        lastProcessedMemoryGeneration: UInt64,
        persistedExpiryTick: UInt64?,
        persistedGeneration: UInt64,
        lastProcessedPersistedGeneration: UInt64,
        hardDeleteTick: UInt64?,
        hardDeleteGeneration: UInt64,
        lastProcessedHardDeleteGeneration: UInt64
    ) {
        self.cellID = cellID
        self.version = version
        self.phase = phase
        self.policy = policy
        self.lastAccessTick = lastAccessTick
        self.persistedSnapshotAvailable = persistedSnapshotAvailable
        self.leaseOwnerNodeID = leaseOwnerNodeID
        self.leaseValidUntilTick = leaseValidUntilTick
        self.fencingToken = fencingToken
        self.memoryExpiryTick = memoryExpiryTick
        self.memoryWarningTick = memoryWarningTick
        self.memoryGeneration = memoryGeneration
        self.lastProcessedMemoryWarningGeneration = lastProcessedMemoryWarningGeneration
        self.lastProcessedMemoryGeneration = lastProcessedMemoryGeneration
        self.persistedExpiryTick = persistedExpiryTick
        self.persistedGeneration = persistedGeneration
        self.lastProcessedPersistedGeneration = lastProcessedPersistedGeneration
        self.hardDeleteTick = hardDeleteTick
        self.hardDeleteGeneration = hardDeleteGeneration
        self.lastProcessedHardDeleteGeneration = lastProcessedHardDeleteGeneration
    }

    public static func initial(
        cellID: RuntimeCellID,
        nowTick: UInt64,
        loadedInMemory: Bool,
        persistedSnapshotAvailable: Bool,
        policy: RuntimeLifecyclePolicy
    ) -> RuntimeLifecycleState {
        let phase: RuntimeLifecyclePhase = loadedInMemory ? .activeLoaded : .activeUnloaded
        var state = RuntimeLifecycleState(
            cellID: cellID,
            version: 1,
            phase: phase,
            policy: policy,
            lastAccessTick: nowTick,
            persistedSnapshotAvailable: persistedSnapshotAvailable,
            leaseOwnerNodeID: nil,
            leaseValidUntilTick: 0,
            fencingToken: 0,
            memoryExpiryTick: nil,
            memoryWarningTick: nil,
            memoryGeneration: 0,
            lastProcessedMemoryWarningGeneration: 0,
            lastProcessedMemoryGeneration: 0,
            persistedExpiryTick: nil,
            persistedGeneration: 0,
            lastProcessedPersistedGeneration: 0,
            hardDeleteTick: nil,
            hardDeleteGeneration: 0,
            lastProcessedHardDeleteGeneration: 0
        )
        state.rescheduleExpiries(nowTick: nowTick)
        return state
    }

    mutating func rescheduleExpiries(nowTick: UInt64) {
        guard policy.isExpiring else {
            memoryExpiryTick = nil
            memoryWarningTick = nil
            persistedExpiryTick = nil
            hardDeleteTick = nil
            return
        }

        if phase == .activeLoaded {
            memoryGeneration &+= 1
            memoryExpiryTick = nowTick &+ policy.memoryTTLTicks
            if policy.memoryWarningLeadTicks > 0,
               policy.memoryTTLTicks > policy.memoryWarningLeadTicks {
                memoryWarningTick = memoryExpiryTick! &- policy.memoryWarningLeadTicks
            } else {
                memoryWarningTick = nil
            }
        } else {
            memoryExpiryTick = nil
            memoryWarningTick = nil
        }

        if let persistedTTL = policy.persistedDataTTLTicks, persistedSnapshotAvailable {
            persistedGeneration &+= 1
            persistedExpiryTick = nowTick &+ persistedTTL
        } else {
            persistedExpiryTick = nil
        }
    }
}

public enum RuntimeLifecycleInput: Sendable {
    case touch(nowTick: UInt64, fencingToken: UInt64)
    case extendMemoryTTL(byTicks: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case extendPersistedTTL(byTicks: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case persistAndUnloadNow(nowTick: UInt64, fencingToken: UInt64)
    case requestTombstone(nowTick: UInt64, fencingToken: UInt64)
    case loadIntoMemory(nowTick: UInt64, fencingToken: UInt64)
    case unloadFromMemory(nowTick: UInt64, fencingToken: UInt64)
    case memoryWarningFired(generation: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case memoryExpiryFired(generation: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case persistedExpiryFired(generation: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case hardDeleteFired(generation: UInt64, nowTick: UInt64, fencingToken: UInt64)
    case leaseGranted(RuntimeLease)
    case leaseExpired(nowTick: UInt64, fencingToken: UInt64)
}

public enum RuntimeLifecycleEffect: Sendable {
    case scheduleMemoryWarning(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64, atTick: UInt64)
    case scheduleMemoryExpiry(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64, atTick: UInt64)
    case schedulePersistedExpiry(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64, atTick: UInt64)
    case scheduleHardDelete(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64, atTick: UInt64)
    case cancelMemoryWarning(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64)
    case cancelMemoryExpiry(cellID: RuntimeCellID, generation: UInt64, fencingToken: UInt64)
    case unloadFromMemory(cellID: RuntimeCellID)
    case persistSnapshot(cellID: RuntimeCellID)
    case writeTombstone(cellID: RuntimeCellID, deleteAfterTick: UInt64)
    case hardDeletePersistedData(cellID: RuntimeCellID)
    case emit(RuntimeLifecycleEvent)
}

public enum RuntimeLifecycleRejection: Error, Sendable {
    case staleFence(expected: UInt64, actual: UInt64)
    case deleted
    case tombstoned(untilTick: UInt64)
    case staleLease(expectedAtLeast: UInt64, actual: UInt64)
}

public struct RuntimeLifecycleTransitionResult: Sendable {
    public var state: RuntimeLifecycleState
    public var effects: [RuntimeLifecycleEffect]
    public var changed: Bool
    public var rejection: RuntimeLifecycleRejection?

    public init(
        state: RuntimeLifecycleState,
        effects: [RuntimeLifecycleEffect],
        changed: Bool,
        rejection: RuntimeLifecycleRejection?
    ) {
        self.state = state
        self.effects = effects
        self.changed = changed
        self.rejection = rejection
    }
}

/// Formal transition reducer:
/// States = {activeLoaded, activeUnloaded, tombstoned, deleted}
/// Inputs = RuntimeLifecycleInput
/// Guard = strict fencing token equality for mutable operations
/// Idempotency = generation checks (`lastProcessed*Generation`) for all expiry events.
public enum RuntimeLifecycleTransitionReducer {
    public static func reduce(
        state original: RuntimeLifecycleState,
        input: RuntimeLifecycleInput
    ) -> RuntimeLifecycleTransitionResult {
        var state = original
        var effects: [RuntimeLifecycleEffect] = []

        func reject(_ rejection: RuntimeLifecycleRejection) -> RuntimeLifecycleTransitionResult {
            RuntimeLifecycleTransitionResult(
                state: original,
                effects: [],
                changed: false,
                rejection: rejection
            )
        }

        func ensureFence(_ token: UInt64) -> RuntimeLifecycleRejection? {
            if state.fencingToken == 0 {
                return nil
            }
            if token != state.fencingToken {
                return .staleFence(expected: state.fencingToken, actual: token)
            }
            return nil
        }

        func emit(_ type: RuntimeLifecycleEventType, tick: UInt64) {
            effects.append(
                .emit(
                    RuntimeLifecycleEvent(
                        type: type,
                        cellID: state.cellID,
                        version: state.version,
                        tick: tick,
                        fencingToken: state.fencingToken
                    )
                )
            )
        }

        func scheduleMemoryTimers() {
            if let warningTick = state.memoryWarningTick {
                effects.append(
                    .scheduleMemoryWarning(
                        cellID: state.cellID,
                        generation: state.memoryGeneration,
                        fencingToken: state.fencingToken,
                        atTick: warningTick
                    )
                )
            }
            if let memoryExpiryTick = state.memoryExpiryTick {
                effects.append(
                    .scheduleMemoryExpiry(
                        cellID: state.cellID,
                        generation: state.memoryGeneration,
                        fencingToken: state.fencingToken,
                        atTick: memoryExpiryTick
                    )
                )
            }
        }

        func schedulePersistedTimer() {
            if let persistedExpiryTick = state.persistedExpiryTick {
                effects.append(
                    .schedulePersistedExpiry(
                        cellID: state.cellID,
                        generation: state.persistedGeneration,
                        fencingToken: state.fencingToken,
                        atTick: persistedExpiryTick
                    )
                )
            }
        }

        switch input {
        case .leaseGranted(let lease):
            guard lease.fencingToken >= state.fencingToken else {
                return reject(.staleLease(expectedAtLeast: state.fencingToken, actual: lease.fencingToken))
            }
            state.version &+= 1
            state.fencingToken = lease.fencingToken
            state.leaseOwnerNodeID = lease.ownerNodeID
            state.leaseValidUntilTick = lease.validUntilTick
            emit(.leaseGranted, tick: lease.validUntilTick)

        case .leaseExpired(let nowTick, let fencingToken):
            if state.fencingToken != fencingToken {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            state.version &+= 1
            state.leaseOwnerNodeID = nil
            state.leaseValidUntilTick = nowTick
            emit(.leaseExpired, tick: nowTick)

        case .touch(let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }

            state.version &+= 1
            state.lastAccessTick = nowTick
            state.rescheduleExpiries(nowTick: nowTick)
            scheduleMemoryTimers()
            schedulePersistedTimer()
            emit(.touched, tick: nowTick)

        case .extendMemoryTTL(let byTicks, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }
            guard state.policy.isExpiring,
                  byTicks > 0,
                  state.phase == .activeLoaded else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }

            let base = max(state.memoryExpiryTick ?? nowTick, nowTick)
            let nextExpiry = base &+ byTicks
            state.version &+= 1
            state.memoryGeneration &+= 1
            state.memoryExpiryTick = nextExpiry
            if state.policy.memoryWarningLeadTicks > 0,
               nextExpiry > state.policy.memoryWarningLeadTicks {
                state.memoryWarningTick = nextExpiry &- state.policy.memoryWarningLeadTicks
            } else {
                state.memoryWarningTick = nil
            }
            scheduleMemoryTimers()
            emit(.memoryTTLExtended, tick: nowTick)

        case .extendPersistedTTL(let byTicks, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }
            guard state.policy.isExpiring,
                  state.policy.persistedDataTTLTicks != nil,
                  byTicks > 0,
                  state.persistedSnapshotAvailable else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }

            let base = max(state.persistedExpiryTick ?? nowTick, nowTick)
            let nextExpiry = base &+ byTicks
            state.version &+= 1
            state.persistedGeneration &+= 1
            state.persistedExpiryTick = nextExpiry
            schedulePersistedTimer()
            emit(.persistedTTLExtended, tick: nowTick)

        case .persistAndUnloadNow(let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }

            state.version &+= 1
            state.persistedSnapshotAvailable = true
            state.phase = .activeUnloaded
            state.memoryGeneration &+= 1
            state.memoryExpiryTick = nil
            state.memoryWarningTick = nil
            effects.append(
                .cancelMemoryWarning(
                    cellID: state.cellID,
                    generation: state.memoryGeneration,
                    fencingToken: state.fencingToken
                )
            )
            effects.append(
                .cancelMemoryExpiry(
                    cellID: state.cellID,
                    generation: state.memoryGeneration,
                    fencingToken: state.fencingToken
                )
            )
            effects.append(.persistSnapshot(cellID: state.cellID))
            effects.append(.unloadFromMemory(cellID: state.cellID))

            if state.policy.isExpiring,
               let persistedTTL = state.policy.persistedDataTTLTicks {
                state.persistedGeneration &+= 1
                state.persistedExpiryTick = nowTick &+ persistedTTL
                schedulePersistedTimer()
            } else {
                state.persistedExpiryTick = nil
            }
            emit(.unloaded, tick: nowTick)

        case .requestTombstone(let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }

            state.version &+= 1
            let wasLoaded = state.phase == .activeLoaded
            state.phase = .tombstoned
            state.memoryGeneration &+= 1
            state.persistedGeneration &+= 1
            state.memoryExpiryTick = nil
            state.memoryWarningTick = nil
            state.persistedExpiryTick = nil
            state.hardDeleteGeneration &+= 1
            let hardDeleteAt = nowTick &+ state.policy.tombstoneGraceTicks
            state.hardDeleteTick = hardDeleteAt

            effects.append(
                .cancelMemoryWarning(
                    cellID: state.cellID,
                    generation: state.memoryGeneration,
                    fencingToken: state.fencingToken
                )
            )
            effects.append(
                .cancelMemoryExpiry(
                    cellID: state.cellID,
                    generation: state.memoryGeneration,
                    fencingToken: state.fencingToken
                )
            )
            if wasLoaded {
                effects.append(.unloadFromMemory(cellID: state.cellID))
            }
            effects.append(.writeTombstone(cellID: state.cellID, deleteAfterTick: hardDeleteAt))
            effects.append(
                .scheduleHardDelete(
                    cellID: state.cellID,
                    generation: state.hardDeleteGeneration,
                    fencingToken: state.fencingToken,
                    atTick: hardDeleteAt
                )
            )
            emit(.tombstoned, tick: nowTick)

        case .loadIntoMemory(let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }
            if state.phase == .activeLoaded {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }

            state.version &+= 1
            state.phase = .activeLoaded
            state.lastAccessTick = nowTick
            state.rescheduleExpiries(nowTick: nowTick)
            scheduleMemoryTimers()
            emit(.registered, tick: nowTick)

        case .unloadFromMemory(let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if state.phase == .deleted { return reject(.deleted) }
            if state.phase == .tombstoned { return reject(.tombstoned(untilTick: state.hardDeleteTick ?? nowTick)) }
            if state.phase == .activeUnloaded {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }

            state.version &+= 1
            state.phase = .activeUnloaded
            state.memoryGeneration &+= 1
            state.memoryExpiryTick = nil
            state.memoryWarningTick = nil
            effects.append(.cancelMemoryWarning(
                cellID: state.cellID,
                generation: state.memoryGeneration,
                fencingToken: state.fencingToken
            ))
            effects.append(.cancelMemoryExpiry(
                cellID: state.cellID,
                generation: state.memoryGeneration,
                fencingToken: state.fencingToken
            ))
            effects.append(.unloadFromMemory(cellID: state.cellID))
            emit(.unloaded, tick: nowTick)

        case .memoryWarningFired(let generation, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if generation <= state.lastProcessedMemoryWarningGeneration {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            guard state.phase == .activeLoaded, generation == state.memoryGeneration else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            state.lastProcessedMemoryWarningGeneration = generation
            state.version &+= 1
            emit(.memoryTTLWarning, tick: nowTick)

        case .memoryExpiryFired(let generation, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if generation <= state.lastProcessedMemoryGeneration {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            guard state.phase == .activeLoaded, generation == state.memoryGeneration else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            state.lastProcessedMemoryGeneration = generation
            state.version &+= 1

            emit(.memoryExpired, tick: nowTick)
            state.memoryWarningTick = nil
            switch state.policy.memoryExpiryAction {
            case .notifyOnly:
                break
            case .unload:
                state.phase = .activeUnloaded
                state.memoryGeneration &+= 1
                state.memoryExpiryTick = nil
                state.memoryWarningTick = nil
                effects.append(.unloadFromMemory(cellID: state.cellID))
                emit(.unloaded, tick: nowTick)
            case .persistAndUnload:
                state.phase = .activeUnloaded
                state.memoryGeneration &+= 1
                state.memoryExpiryTick = nil
                state.memoryWarningTick = nil
                state.persistedSnapshotAvailable = true
                effects.append(.persistSnapshot(cellID: state.cellID))
                effects.append(.unloadFromMemory(cellID: state.cellID))
                emit(.unloaded, tick: nowTick)
            }

        case .persistedExpiryFired(let generation, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if generation <= state.lastProcessedPersistedGeneration {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            guard generation == state.persistedGeneration,
                  state.persistedSnapshotAvailable,
                  state.phase != .deleted else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            state.lastProcessedPersistedGeneration = generation
            state.version &+= 1

            state.phase = .tombstoned
            state.hardDeleteGeneration &+= 1
            state.memoryExpiryTick = nil
            state.memoryWarningTick = nil
            state.persistedExpiryTick = nil
            let hardDeleteAt = nowTick &+ state.policy.tombstoneGraceTicks
            state.hardDeleteTick = hardDeleteAt
            effects.append(.writeTombstone(cellID: state.cellID, deleteAfterTick: hardDeleteAt))
            effects.append(.scheduleHardDelete(
                cellID: state.cellID,
                generation: state.hardDeleteGeneration,
                fencingToken: state.fencingToken,
                atTick: hardDeleteAt
            ))
            emit(.tombstoned, tick: nowTick)

        case .hardDeleteFired(let generation, let nowTick, let fencingToken):
            if let rejection = ensureFence(fencingToken) { return reject(rejection) }
            if generation <= state.lastProcessedHardDeleteGeneration {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            guard state.phase == .tombstoned,
                  generation == state.hardDeleteGeneration else {
                return RuntimeLifecycleTransitionResult(state: original, effects: [], changed: false, rejection: nil)
            }
            state.lastProcessedHardDeleteGeneration = generation
            state.version &+= 1

            state.phase = .deleted
            state.persistedSnapshotAvailable = false
            state.memoryExpiryTick = nil
            state.memoryWarningTick = nil
            state.persistedExpiryTick = nil
            state.hardDeleteTick = nil
            effects.append(.hardDeletePersistedData(cellID: state.cellID))
            emit(.hardDeleted, tick: nowTick)
        }

        return RuntimeLifecycleTransitionResult(
            state: state,
            effects: effects,
            changed: state != original || !effects.isEmpty,
            rejection: nil
        )
    }
}

extension RuntimeLifecycleState: Equatable {}

public protocol RuntimeLifecycleStateStore: Sendable {
    func read(cellID: RuntimeCellID) async -> RuntimeLifecycleState?
    func putIfAbsent(_ state: RuntimeLifecycleState) async -> Bool
    func compareAndSwap(
        cellID: RuntimeCellID,
        expectedVersion: UInt64,
        next: RuntimeLifecycleState
    ) async -> Bool
    func snapshotStates() async -> [RuntimeLifecycleState]
}

public extension RuntimeLifecycleStateStore {
    func snapshotStates() async -> [RuntimeLifecycleState] {
        []
    }
}

public actor InMemoryRuntimeLifecycleStateStore: RuntimeLifecycleStateStore {
    private var states = [RuntimeCellID: RuntimeLifecycleState]()

    public init() {}

    public func read(cellID: RuntimeCellID) async -> RuntimeLifecycleState? {
        states[cellID]
    }

    public func putIfAbsent(_ state: RuntimeLifecycleState) async -> Bool {
        guard states[state.cellID] == nil else {
            return false
        }
        states[state.cellID] = state
        return true
    }

    public func compareAndSwap(
        cellID: RuntimeCellID,
        expectedVersion: UInt64,
        next: RuntimeLifecycleState
    ) async -> Bool {
        guard let current = states[cellID], current.version == expectedVersion else {
            return false
        }
        states[cellID] = next
        return true
    }

    public func snapshotStates() async -> [RuntimeLifecycleState] {
        Array(states.values)
    }
}
