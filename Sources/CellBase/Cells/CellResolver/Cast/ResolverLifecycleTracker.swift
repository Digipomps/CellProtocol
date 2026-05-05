// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

struct TrackedCellLifecycleRecord {
    var uuid: String
    var endpoint: String?
    var identityUUID: String?
    var persistancy: Persistancy
    var cellTypeName: String
    var alertRecipientIdentityUUIDs: [String]
    var deleteIfUnfunded: Bool
    var fundedUntilTick: UInt64?
    var fundingEnforced: Bool
    var policy: CellLifecyclePolicy
    var lastAccessAt: Date
    var ttlExtension: TimeInterval = 0
    var warningEmitted = false
    var expiryEmitted = false
}

struct TrackedPersistedCellRecord {
    var uuid: String
    var endpoint: String?
    var identityUUID: String?
    var alertRecipientIdentityUUIDs: [String]
    var deleteIfUnfunded: Bool
    var fundedUntilTick: UInt64?
    var fundingEnforced: Bool
    var persistedDataTTL: TimeInterval
    var lastAccessAt: Date
    var ttlExtension: TimeInterval = 0
    var expiryEmitted = false
}

enum CellLifecycleDueEvent {
    case memoryWarning(TrackedCellLifecycleRecord, remaining: TimeInterval)
    case memoryExpired(TrackedCellLifecycleRecord)
    case persistedDataExpired(TrackedPersistedCellRecord)
}

actor ResolverLifecycleTracker {
    private var trackedCells = [String: TrackedCellLifecycleRecord]()
    private var trackedPersistedCells = [String: TrackedPersistedCellRecord]()

    func trackCell(
        uuid: String,
        endpoint: String?,
        identityUUID: String?,
        persistancy: Persistancy,
        cellTypeName: String,
        alertRecipientIdentityUUIDs: [String],
        deleteIfUnfunded: Bool,
        fundedUntilTick: UInt64?,
        fundingEnforced: Bool,
        policy: CellLifecyclePolicy,
        now: Date = Date()
    ) {
        trackedCells[uuid] = TrackedCellLifecycleRecord(
            uuid: uuid,
            endpoint: endpoint,
            identityUUID: identityUUID,
            persistancy: persistancy,
            cellTypeName: cellTypeName,
            alertRecipientIdentityUUIDs: alertRecipientIdentityUUIDs,
            deleteIfUnfunded: deleteIfUnfunded,
            fundedUntilTick: fundedUntilTick,
            fundingEnforced: fundingEnforced,
            policy: policy,
            lastAccessAt: now
        )

        if let persistedDataTTL = policy.persistedDataTTL, persistedDataTTL > 0 {
            trackedPersistedCells[uuid] = TrackedPersistedCellRecord(
                uuid: uuid,
                endpoint: endpoint,
                identityUUID: identityUUID,
                alertRecipientIdentityUUIDs: alertRecipientIdentityUUIDs,
                deleteIfUnfunded: deleteIfUnfunded,
                fundedUntilTick: fundedUntilTick,
                fundingEnforced: fundingEnforced,
                persistedDataTTL: persistedDataTTL,
                lastAccessAt: now
            )
        }
    }

    func touchCell(uuid: String, at date: Date = Date()) {
        guard var record = trackedCells[uuid] else {
            return
        }
        record.lastAccessAt = date
        record.ttlExtension = 0
        record.warningEmitted = false
        record.expiryEmitted = false
        trackedCells[uuid] = record
    }

    func extendMemoryTTL(uuid: String, by seconds: TimeInterval) -> Bool {
        guard seconds > 0, var record = trackedCells[uuid] else {
            return false
        }
        record.ttlExtension += seconds
        record.warningEmitted = false
        record.expiryEmitted = false
        trackedCells[uuid] = record
        return true
    }

    func touchPersistedCell(uuid: String, at date: Date = Date()) {
        guard var record = trackedPersistedCells[uuid] else {
            return
        }
        record.lastAccessAt = date
        record.ttlExtension = 0
        record.expiryEmitted = false
        trackedPersistedCells[uuid] = record
    }

    func setPersistedTTL(uuid: String, ttl: TimeInterval, at date: Date = Date()) {
        guard ttl > 0 else {
            trackedPersistedCells[uuid] = nil
            return
        }

        if var record = trackedPersistedCells[uuid] {
            record.persistedDataTTL = ttl
            record.lastAccessAt = date
            record.ttlExtension = 0
            record.expiryEmitted = false
            trackedPersistedCells[uuid] = record
        } else {
            trackedPersistedCells[uuid] = TrackedPersistedCellRecord(
                uuid: uuid,
                endpoint: nil,
                identityUUID: nil,
                alertRecipientIdentityUUIDs: [],
                deleteIfUnfunded: false,
                fundedUntilTick: nil,
                fundingEnforced: false,
                persistedDataTTL: ttl,
                lastAccessAt: date
            )
        }
    }

    func extendPersistedDataTTL(uuid: String, by seconds: TimeInterval) -> Bool {
        guard seconds > 0, var record = trackedPersistedCells[uuid] else {
            return false
        }
        record.ttlExtension += seconds
        record.expiryEmitted = false
        trackedPersistedCells[uuid] = record
        return true
    }

    func untrackCell(uuid: String) {
        trackedCells[uuid] = nil
    }

    func untrackPersistedCell(uuid: String) {
        trackedPersistedCells[uuid] = nil
    }

    func dueEvents(now: Date = Date()) -> [CellLifecycleDueEvent] {
        var events = [CellLifecycleDueEvent]()

        for (uuid, var record) in trackedCells {
            guard let memoryTTL = record.policy.memoryTTL, memoryTTL > 0 else {
                continue
            }
            let expiryDate = record.lastAccessAt.addingTimeInterval(memoryTTL + record.ttlExtension)
            let secondsRemaining = expiryDate.timeIntervalSince(now)

            if secondsRemaining <= 0 {
                if !record.expiryEmitted {
                    record.expiryEmitted = true
                    trackedCells[uuid] = record
                    events.append(.memoryExpired(record))
                }
                continue
            }

            if record.policy.warningLeadTime > 0,
               secondsRemaining <= record.policy.warningLeadTime,
               !record.warningEmitted {
                record.warningEmitted = true
                trackedCells[uuid] = record
                events.append(.memoryWarning(record, remaining: secondsRemaining))
            }
        }

        for (uuid, var record) in trackedPersistedCells {
            let expiryDate = record.lastAccessAt.addingTimeInterval(record.persistedDataTTL + record.ttlExtension)
            if now >= expiryDate, !record.expiryEmitted {
                record.expiryEmitted = true
                trackedPersistedCells[uuid] = record
                events.append(.persistedDataExpired(record))
            }
        }

        return events
    }
}
