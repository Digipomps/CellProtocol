// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct RuntimeLease: Codable, Sendable {
    public let cellID: RuntimeCellID
    public let ownerNodeID: String
    public let fencingToken: UInt64
    public let validUntilTick: UInt64

    public init(
        cellID: RuntimeCellID,
        ownerNodeID: String,
        fencingToken: UInt64,
        validUntilTick: UInt64
    ) {
        self.cellID = cellID
        self.ownerNodeID = ownerNodeID
        self.fencingToken = fencingToken
        self.validUntilTick = validUntilTick
    }
}

public enum RuntimeLeaseError: Error, Sendable {
    case alreadyLeased(activeOwner: String, validUntilTick: UInt64)
    case staleLease(expectedAtLeastFencingToken: UInt64, provided: UInt64)
    case leaseNotOwned(expectedOwner: String, actualOwner: String?)
}

public protocol RuntimeLeaseCoordinator: Sendable {
    func acquire(
        cellID: RuntimeCellID,
        nodeID: String,
        nowTick: UInt64,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease

    func renew(
        lease: RuntimeLease,
        nowTick: UInt64,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease

    func release(lease: RuntimeLease) async
}

/// Single-node/default implementation. Distributed deployments can replace this
/// with a DB-backed coordinator that keeps strict monotonic fencing tokens.
public actor InMemoryRuntimeLeaseCoordinator: RuntimeLeaseCoordinator {
    private struct LeaseRecord {
        var ownerNodeID: String
        var fencingToken: UInt64
        var validUntilTick: UInt64
    }

    private var leasesByCell = [RuntimeCellID: LeaseRecord]()
    private var lastFencingTokenByCell = [RuntimeCellID: UInt64]()

    public init() {}

    public func acquire(
        cellID: RuntimeCellID,
        nodeID: String,
        nowTick: UInt64,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease {
        if let existing = leasesByCell[cellID], existing.validUntilTick > nowTick, existing.ownerNodeID != nodeID {
            throw RuntimeLeaseError.alreadyLeased(
                activeOwner: existing.ownerNodeID,
                validUntilTick: existing.validUntilTick
            )
        }

        let nextFencingToken = (lastFencingTokenByCell[cellID] ?? leasesByCell[cellID]?.fencingToken ?? 0) &+ 1
        let validUntilTick = nowTick &+ leaseDurationTicks
        leasesByCell[cellID] = LeaseRecord(
            ownerNodeID: nodeID,
            fencingToken: nextFencingToken,
            validUntilTick: validUntilTick
        )
        lastFencingTokenByCell[cellID] = nextFencingToken
        return RuntimeLease(
            cellID: cellID,
            ownerNodeID: nodeID,
            fencingToken: nextFencingToken,
            validUntilTick: validUntilTick
        )
    }

    public func renew(
        lease: RuntimeLease,
        nowTick: UInt64,
        leaseDurationTicks: UInt64
    ) async throws -> RuntimeLease {
        guard let existing = leasesByCell[lease.cellID] else {
            throw RuntimeLeaseError.leaseNotOwned(expectedOwner: lease.ownerNodeID, actualOwner: nil)
        }
        guard existing.ownerNodeID == lease.ownerNodeID else {
            throw RuntimeLeaseError.leaseNotOwned(expectedOwner: lease.ownerNodeID, actualOwner: existing.ownerNodeID)
        }
        guard existing.fencingToken == lease.fencingToken else {
            throw RuntimeLeaseError.staleLease(
                expectedAtLeastFencingToken: existing.fencingToken,
                provided: lease.fencingToken
            )
        }

        let renewed = LeaseRecord(
            ownerNodeID: lease.ownerNodeID,
            fencingToken: lease.fencingToken,
            validUntilTick: nowTick &+ leaseDurationTicks
        )
        leasesByCell[lease.cellID] = renewed
        return RuntimeLease(
            cellID: lease.cellID,
            ownerNodeID: lease.ownerNodeID,
            fencingToken: lease.fencingToken,
            validUntilTick: renewed.validUntilTick
        )
    }

    public func release(lease: RuntimeLease) async {
        guard let existing = leasesByCell[lease.cellID] else {
            return
        }
        guard existing.ownerNodeID == lease.ownerNodeID,
              existing.fencingToken == lease.fencingToken else {
            return
        }
        leasesByCell[lease.cellID] = nil
    }
}
