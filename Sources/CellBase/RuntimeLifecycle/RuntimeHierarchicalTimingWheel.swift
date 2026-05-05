// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import Collections

public enum RuntimeWheelItemKind: String, Codable, Sendable {
    case memoryWarning
    case memoryExpiry
    case persistedExpiry
    case hardDelete
}

public struct RuntimeWheelItem: Codable, Sendable, Hashable {
    public var cellID: RuntimeCellID
    public var kind: RuntimeWheelItemKind
    public var generation: UInt64
    public var fencingToken: UInt64

    public init(
        cellID: RuntimeCellID,
        kind: RuntimeWheelItemKind,
        generation: UInt64,
        fencingToken: UInt64
    ) {
        self.cellID = cellID
        self.kind = kind
        self.generation = generation
        self.fencingToken = fencingToken
    }
}

public struct RuntimeTimingWheelConfiguration: Sendable {
    public var slotBits: Int
    public var levelCount: Int
    public var maxExpiredPerTick: Int
    public var maxRebucketPerTick: Int

    public init(
        slotBits: Int = 8,
        levelCount: Int = 4,
        maxExpiredPerTick: Int = 4096,
        maxRebucketPerTick: Int = 8192
    ) {
        precondition(slotBits > 0 && slotBits <= 16, "slotBits must be within 1...16")
        precondition(levelCount > 0 && levelCount <= 8, "levelCount must be within 1...8")
        precondition(maxExpiredPerTick > 0)
        precondition(maxRebucketPerTick > 0)
        self.slotBits = slotBits
        self.levelCount = levelCount
        self.maxExpiredPerTick = maxExpiredPerTick
        self.maxRebucketPerTick = maxRebucketPerTick
    }
}

private struct RuntimeWheelKey: Hashable, Sendable {
    var cellID: RuntimeCellID
    var kind: RuntimeWheelItemKind
}

private struct RuntimeWheelNode: Sendable {
    var item: RuntimeWheelItem
    var deadlineTick: UInt64
}

private struct RuntimeWheelLevel: Sendable {
    var slots: [Deque<RuntimeWheelNode>]
}

private struct RuntimeCascadeJob: Hashable, Sendable {
    var level: Int
    var slotIndex: Int
}

/// Hierarchical timing wheel with generation-based idempotency.
/// No per-item timers; all progression is driven by explicit `advance(...)`.
public actor RuntimeHierarchicalTimingWheel {
    private let config: RuntimeTimingWheelConfiguration
    private let slotCount: Int
    private let slotMask: UInt64

    private var levels: [RuntimeWheelLevel]
    private var latestGenerationByKey = [RuntimeWheelKey: UInt64]()
    private var pendingDueOverflow = Deque<RuntimeWheelNode>()
    private var pendingCascadeJobs = Deque<RuntimeCascadeJob>()
    private var pendingCascadeSet = Set<RuntimeCascadeJob>()
    private(set) var currentTick: UInt64

    public init(
        configuration: RuntimeTimingWheelConfiguration = RuntimeTimingWheelConfiguration(),
        startTick: UInt64 = 0
    ) {
        self.config = configuration
        self.slotCount = 1 << configuration.slotBits
        self.slotMask = UInt64(slotCount - 1)
        self.currentTick = startTick

        let emptySlots = Array(repeating: Deque<RuntimeWheelNode>(), count: slotCount)
        self.levels = (0..<configuration.levelCount).map { _ in
            RuntimeWheelLevel(slots: emptySlots)
        }
    }

    public func schedule(_ item: RuntimeWheelItem, deadlineTick: UInt64) {
        let key = RuntimeWheelKey(cellID: item.cellID, kind: item.kind)
        let knownGeneration = latestGenerationByKey[key] ?? 0
        if item.generation < knownGeneration {
            return
        }
        latestGenerationByKey[key] = item.generation
        let node = RuntimeWheelNode(item: item, deadlineTick: deadlineTick)
        if deadlineTick <= currentTick {
            pendingDueOverflow.append(node)
            return
        }
        insert(node)
    }

    public func cancel(cellID: RuntimeCellID, kind: RuntimeWheelItemKind, generation: UInt64) {
        let key = RuntimeWheelKey(cellID: cellID, kind: kind)
        let knownGeneration = latestGenerationByKey[key] ?? 0
        if generation >= knownGeneration {
            latestGenerationByKey[key] = generation
        }
    }

    public func advance(toTick targetTick: UInt64) -> [RuntimeWheelItem] {
        guard targetTick >= currentTick else { return [] }
        var expired = [RuntimeWheelItem]()

        if targetTick == currentTick {
            var remainingExpired = config.maxExpiredPerTick
            expired.append(contentsOf: drainDueOverflow(remainingExpired: &remainingExpired))
            return expired
        }

        while currentTick < targetTick {
            currentTick &+= 1

            var remainingExpired = config.maxExpiredPerTick
            var remainingRebucket = config.maxRebucketPerTick

            cascadeIfNeeded(remainingRebucket: &remainingRebucket)
            expired.append(contentsOf: drainDueOverflow(remainingExpired: &remainingExpired))
            let expiredThisTick = drainCurrentSlot(remainingExpired: &remainingExpired)
            expired.append(contentsOf: expiredThisTick)
        }

        return expired
    }

    private func insert(_ node: RuntimeWheelNode) {
        let level = targetLevel(forDeadlineTick: node.deadlineTick)
        let slotIndex = slotIndex(for: level, deadlineTick: node.deadlineTick)
        levels[level].slots[slotIndex].append(node)
    }

    private func targetLevel(forDeadlineTick deadlineTick: UInt64) -> Int {
        if deadlineTick <= currentTick {
            return 0
        }
        let delta = deadlineTick &- currentTick

        for level in 0..<config.levelCount {
            let bits = config.slotBits * (level + 1)
            if bits >= UInt64.bitWidth {
                return level
            }
            let maxDeltaAtLevel = (UInt64(1) << UInt64(bits)) &- 1
            if delta <= maxDeltaAtLevel {
                return level
            }
        }
        return config.levelCount - 1
    }

    private func slotIndex(for level: Int, deadlineTick: UInt64) -> Int {
        let shift = UInt64(level * config.slotBits)
        return Int((deadlineTick >> shift) & slotMask)
    }

    private func cascadeIfNeeded(remainingRebucket: inout Int) {
        guard config.levelCount > 1 else { return }

        for level in 1..<config.levelCount {
            let intervalBits = level * config.slotBits
            if intervalBits >= UInt64.bitWidth {
                break
            }
            let intervalMask = (UInt64(1) << UInt64(intervalBits)) &- 1
            if (currentTick & intervalMask) != 0 {
                continue
            }
            let index = slotIndex(for: level, deadlineTick: currentTick)
            let job = RuntimeCascadeJob(level: level, slotIndex: index)
            if pendingCascadeSet.insert(job).inserted {
                pendingCascadeJobs.append(job)
            }
        }

        while remainingRebucket > 0, let job = pendingCascadeJobs.popFirst() {
            pendingCascadeSet.remove(job)
            let emptied = cascade(level: job.level, slotIndex: job.slotIndex, remainingRebucket: &remainingRebucket)
            if !emptied {
                if pendingCascadeSet.insert(job).inserted {
                    pendingCascadeJobs.prepend(job)
                }
                break
            }
        }
    }

    private func cascade(level: Int, slotIndex: Int, remainingRebucket: inout Int) -> Bool {
        guard remainingRebucket > 0 else {
            return levels[level].slots[slotIndex].isEmpty
        }

        var slot = levels[level].slots[slotIndex]
        var nodesToInsert = [RuntimeWheelNode]()

        while remainingRebucket > 0, let node = slot.popFirst() {
            remainingRebucket -= 1
            nodesToInsert.append(node)
        }
        levels[level].slots[slotIndex] = slot

        for node in nodesToInsert {
            insert(node)
        }

        return slot.isEmpty
    }

    private func drainDueOverflow(remainingExpired: inout Int) -> [RuntimeWheelItem] {
        var expired = [RuntimeWheelItem]()

        while remainingExpired > 0, let node = pendingDueOverflow.popFirst() {
            let key = RuntimeWheelKey(cellID: node.item.cellID, kind: node.item.kind)
            let knownGeneration = latestGenerationByKey[key] ?? 0
            if node.item.generation != knownGeneration {
                continue
            }
            if node.deadlineTick > currentTick {
                insert(node)
                continue
            }
            remainingExpired -= 1
            expired.append(node.item)
        }

        return expired
    }

    private func drainCurrentSlot(remainingExpired: inout Int) -> [RuntimeWheelItem] {
        var expired = [RuntimeWheelItem]()
        let index = slotIndex(for: 0, deadlineTick: currentTick)
        var slot = levels[0].slots[index]
        let initialCount = slot.count
        var processed = 0
        var nodesToInsert = [RuntimeWheelNode]()

        while processed < initialCount, let node = slot.popFirst() {
            processed += 1
            let key = RuntimeWheelKey(cellID: node.item.cellID, kind: node.item.kind)
            let knownGeneration = latestGenerationByKey[key] ?? 0
            if node.item.generation != knownGeneration {
                continue
            }

            if node.deadlineTick > currentTick {
                nodesToInsert.append(node)
                continue
            }

            if remainingExpired == 0 {
                pendingDueOverflow.append(node)
                while processed < initialCount, let pendingNode = slot.popFirst() {
                    processed += 1
                    let pendingKey = RuntimeWheelKey(cellID: pendingNode.item.cellID, kind: pendingNode.item.kind)
                    let pendingGeneration = latestGenerationByKey[pendingKey] ?? 0
                    if pendingNode.item.generation != pendingGeneration {
                        continue
                    }
                    if pendingNode.deadlineTick > currentTick {
                        nodesToInsert.append(pendingNode)
                    } else {
                        pendingDueOverflow.append(pendingNode)
                    }
                }
                break
            }

            remainingExpired -= 1
            expired.append(node.item)
        }

        levels[0].slots[index] = slot
        for node in nodesToInsert {
            insert(node)
        }
        return expired
    }
}
