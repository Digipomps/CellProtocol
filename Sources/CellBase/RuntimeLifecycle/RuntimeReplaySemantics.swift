// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum RuntimeReplayError: Error, Sendable, Equatable {
    case lifecycleDeleted(cellID: RuntimeCellID)
    case lifecycleTombstoned(cellID: RuntimeCellID, hardDeleteTick: UInt64)
    case snapshotMissing(cellID: RuntimeCellID)
    case eventLogGap(cellID: RuntimeCellID, expectedSequence: UInt64, actualSequence: UInt64)
    case staleFencingToken(cellID: RuntimeCellID, expected: UInt64, actual: UInt64)
}

public enum RuntimeReplayResolution: Sendable, Equatable {
    case replayFromSnapshot
    case replayFromEventLog
    case loadBlocked(RuntimeReplayError)
}

public protocol RuntimeReplayPolicy: Sendable {
    func resolve(
        cellID: RuntimeCellID,
        lifecycleState: RuntimeLifecycleState,
        snapshotAvailable: Bool,
        hasEventLogGap: Bool,
        expectedSequence: UInt64?,
        actualSequence: UInt64?
    ) -> RuntimeReplayResolution
}

public struct DefaultRuntimeReplayPolicy: RuntimeReplayPolicy {
    public init() {}

    public func resolve(
        cellID: RuntimeCellID,
        lifecycleState: RuntimeLifecycleState,
        snapshotAvailable: Bool,
        hasEventLogGap: Bool,
        expectedSequence: UInt64?,
        actualSequence: UInt64?
    ) -> RuntimeReplayResolution {
        switch lifecycleState.phase {
        case .deleted:
            return .loadBlocked(.lifecycleDeleted(cellID: cellID))
        case .tombstoned:
            return .loadBlocked(.lifecycleTombstoned(cellID: cellID, hardDeleteTick: lifecycleState.hardDeleteTick ?? 0))
        case .activeLoaded, .activeUnloaded:
            break
        }

        if hasEventLogGap {
            return .loadBlocked(
                .eventLogGap(
                    cellID: cellID,
                    expectedSequence: expectedSequence ?? 0,
                    actualSequence: actualSequence ?? 0
                )
            )
        }

        if snapshotAvailable {
            return .replayFromSnapshot
        }
        return .replayFromEventLog
    }
}
