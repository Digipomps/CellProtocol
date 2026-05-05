// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

private actor RecordingRuntimeLifecycleEffectSink: RuntimeLifecycleEffectSink {
    private(set) var emittedEvents: [RuntimeLifecycleEvent] = []

    func handle(effect: RuntimeLifecycleEffect) async {
        if case .emit(let event) = effect {
            emittedEvents.append(event)
        }
    }

    func hasEvent(_ type: RuntimeLifecycleEventType) -> Bool {
        emittedEvents.contains(where: { $0.type == type })
    }
}

final class RuntimeLifecyclePropertyTests: XCTestCase {
    private struct LCG {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state = 6364136223846793005 &* state &+ 1
            return state
        }
    }

    func testTimingWheelExpiresOnlyAtOrAfterDeadline() async {
        let wheel = RuntimeHierarchicalTimingWheel(
            configuration: RuntimeTimingWheelConfiguration(
                slotBits: 8,
                levelCount: 4,
                maxExpiredPerTick: 2048,
                maxRebucketPerTick: 4096
            )
        )
        var rng = LCG(seed: 0xA11CE)
        var expectedDeadlineByCell = [RuntimeCellID: UInt64]()
        var maxDeadline: UInt64 = 0

        for index in 0..<4000 {
            let cellID = RuntimeCellID("cell-\(index)")
            let deadline = (rng.next() % 2000) + 1
            maxDeadline = max(maxDeadline, deadline)
            expectedDeadlineByCell[cellID] = deadline
            await wheel.schedule(
                RuntimeWheelItem(
                    cellID: cellID,
                    kind: .memoryExpiry,
                    generation: 1,
                    fencingToken: 1
                ),
                deadlineTick: deadline
            )
        }

        var seen = Set<RuntimeCellID>()
        for tick in 1...maxDeadline {
            let expired = await wheel.advance(toTick: tick)
            for item in expired {
                guard let expectedDeadline = expectedDeadlineByCell[item.cellID] else {
                    XCTFail("Unexpected cellID \(item.cellID.rawValue)")
                    continue
                }
                XCTAssertGreaterThanOrEqual(tick, expectedDeadline)
                XCTAssertFalse(seen.contains(item.cellID))
                seen.insert(item.cellID)
            }
        }

        XCTAssertEqual(seen.count, expectedDeadlineByCell.count)
    }

    func testTimingWheelGenerationReplacementIsIdempotent() async {
        let wheel = RuntimeHierarchicalTimingWheel()
        let cellID = RuntimeCellID("cell-generation")

        await wheel.schedule(
            RuntimeWheelItem(cellID: cellID, kind: .memoryExpiry, generation: 1, fencingToken: 7),
            deadlineTick: 10
        )
        await wheel.schedule(
            RuntimeWheelItem(cellID: cellID, kind: .memoryExpiry, generation: 2, fencingToken: 7),
            deadlineTick: 20
        )

        let before = await wheel.advance(toTick: 15)
        XCTAssertFalse(before.contains(where: { $0.cellID == cellID }))

        let atTwenty = await wheel.advance(toTick: 20)
        XCTAssertEqual(atTwenty.filter { $0.cellID == cellID }.count, 1)
        XCTAssertEqual(atTwenty.first(where: { $0.cellID == cellID })?.generation, 2)
    }

    func testReducerIsIdempotentForDuplicateExpiryDelivery() {
        var state = RuntimeLifecycleState.initial(
            cellID: RuntimeCellID("cell-reducer"),
            nowTick: 0,
            loadedInMemory: true,
            persistedSnapshotAvailable: true,
            policy: .expiring(
                memoryTTLTicks: 5,
                persistedDataTTLTicks: 10,
                tombstoneGraceTicks: 5,
                memoryExpiryAction: .unload
            )
        )
        state.fencingToken = 9
        let generation = state.memoryGeneration

        let first = RuntimeLifecycleTransitionReducer.reduce(
            state: state,
            input: .memoryExpiryFired(generation: generation, nowTick: 5, fencingToken: 9)
        )
        XCTAssertNil(first.rejection)
        XCTAssertEqual(first.state.phase, .activeUnloaded)

        let duplicate = RuntimeLifecycleTransitionReducer.reduce(
            state: first.state,
            input: .memoryExpiryFired(generation: generation, nowTick: 6, fencingToken: 9)
        )
        XCTAssertNil(duplicate.rejection)
        XCTAssertFalse(duplicate.changed)
    }

    func testManagerAppliesTombstoneBeforeHardDelete() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let manager = RuntimeLifecycleManager(timeSource: time)
        let cellID = RuntimeCellID("cell-tombstone")

        let (registered, lease) = try await manager.registerCell(
            cellID: cellID,
            policy: .expiring(
                memoryTTLTicks: 100,
                persistedDataTTLTicks: 3,
                tombstoneGraceTicks: 2,
                memoryExpiryAction: .notifyOnly
            ),
            loadedInMemory: false,
            persistedSnapshotAvailable: true,
            nodeID: "node-A",
            leaseDurationTicks: 1000
        )
        XCTAssertEqual(registered.phase, .activeUnloaded)

        time.advance(by: 3)
        try await manager.processDueExpiries()
        let tombstoned = await manager.readState(cellID: cellID)
        XCTAssertEqual(tombstoned?.phase, .tombstoned)

        time.advance(by: 2)
        try await manager.processDueExpiries()
        let deleted = await manager.readState(cellID: cellID)
        XCTAssertEqual(deleted?.phase, .deleted)

        // Ensure stale fencing token is rejected after lease turnover.
        try await manager.releaseLease(lease)
        let newLease = try await manager.acquireLease(cellID: cellID, nodeID: "node-B", leaseDurationTicks: 1000)
        XCTAssertGreaterThan(newLease.fencingToken, lease.fencingToken)
        do {
            _ = try await manager.touch(cellID: cellID, lease: lease)
            XCTFail("Expected stale fence rejection")
        } catch RuntimeLifecycleManagerError.transitionRejected(let rejection) {
            if case .staleFence = rejection {
                // expected
            } else {
                XCTFail("Unexpected rejection: \(rejection)")
            }
        }
    }

    func testOwnerCanExtendMemoryTTLDeterministically() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let manager = RuntimeLifecycleManager(timeSource: time)
        let cellID = RuntimeCellID("cell-extend-memory")

        let (_, lease) = try await manager.registerCell(
            cellID: cellID,
            policy: .expiring(
                memoryTTLTicks: 5,
                persistedDataTTLTicks: nil,
                tombstoneGraceTicks: 0,
                memoryExpiryAction: .notifyOnly
            ),
            loadedInMemory: true,
            persistedSnapshotAvailable: false,
            nodeID: "node-A",
            leaseDurationTicks: 100
        )

        let before = await manager.readState(cellID: cellID)
        XCTAssertEqual(before?.memoryExpiryTick, 5)

        time.advance(by: 4)
        _ = try await manager.extendMemoryTTL(cellID: cellID, byTicks: 3, lease: lease)

        let extended = await manager.readState(cellID: cellID)
        XCTAssertEqual(extended?.memoryExpiryTick, 8)
        XCTAssertEqual(extended?.phase, .activeLoaded)

        time.advance(by: 4)
        try await manager.processDueExpiries()
        let postExpiry = await manager.readState(cellID: cellID)
        XCTAssertEqual(postExpiry?.lastProcessedMemoryGeneration, extended?.memoryGeneration)
    }

    func testReplayPolicyAllowsUnloadedReplayFromEventLog() {
        let policy = DefaultRuntimeReplayPolicy()
        let state = RuntimeLifecycleState.initial(
            cellID: RuntimeCellID("cell-unloaded-replay"),
            nowTick: 42,
            loadedInMemory: false,
            persistedSnapshotAvailable: false,
            policy: .expiring(memoryTTLTicks: 10)
        )

        let resolution = policy.resolve(
            cellID: state.cellID,
            lifecycleState: state,
            snapshotAvailable: false,
            hasEventLogGap: false,
            expectedSequence: 100,
            actualSequence: 100
        )

        XCTAssertEqual(resolution, .replayFromEventLog)
    }

    func testMemoryWarningEventFiresBeforeExpiry() async throws {
        let sink = RecordingRuntimeLifecycleEffectSink()
        let time = DeterministicTimeSource(initialTick: 0)
        let manager = RuntimeLifecycleManager(timeSource: time, effectSink: sink)
        let cellID = RuntimeCellID("cell-warning")

        _ = try await manager.registerCell(
            cellID: cellID,
            policy: .expiring(
                memoryTTLTicks: 10,
                memoryWarningLeadTicks: 3,
                persistedDataTTLTicks: nil,
                tombstoneGraceTicks: 0,
                memoryExpiryAction: .notifyOnly
            ),
            loadedInMemory: true,
            persistedSnapshotAvailable: false,
            nodeID: "node-A",
            leaseDurationTicks: 100
        )

        time.advance(by: 6)
        try await manager.processDueExpiries()
        let hasEarlyWarning = await sink.hasEvent(.memoryTTLWarning)
        XCTAssertFalse(hasEarlyWarning)

        time.advance(by: 1)
        try await manager.processDueExpiries()
        let hasWarningAtDeadline = await sink.hasEvent(.memoryTTLWarning)
        XCTAssertTrue(hasWarningAtDeadline)
    }

    func testWarningCommandRoutePersistAndUnload() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let manager = RuntimeLifecycleManager(timeSource: time)
        let cellID = RuntimeCellID("cell-warning-command")

        let (_, lease) = try await manager.registerCell(
            cellID: cellID,
            policy: .expiring(
                memoryTTLTicks: 10,
                memoryWarningLeadTicks: 3,
                persistedDataTTLTicks: 50,
                tombstoneGraceTicks: 5,
                memoryExpiryAction: .notifyOnly
            ),
            loadedInMemory: true,
            persistedSnapshotAvailable: false,
            nodeID: "node-A",
            leaseDurationTicks: 100
        )

        let updated = try await manager.applyWarningCommand(
            cellID: cellID,
            lease: lease,
            command: .persistAndUnload
        )
        XCTAssertEqual(updated.phase, .activeUnloaded)
        XCTAssertTrue(updated.persistedSnapshotAvailable)
        XCTAssertNotNil(updated.persistedExpiryTick)
    }

    func testAgreementMappingResolvesReplayFundingAndColdTier() throws {
        let owner = Identity()
        let agreement = Agreement(owner: owner)
        try agreement.addCondition(
            ReplayGuaranteeCondition(
                mode: .snapshot,
                minimumRetentionTicks: 120,
                allowEventLogGap: false
            )
        )
        try agreement.addCondition(
            LifecycleFundingCondition(
                payerIdentityUUID: "payer-1",
                billingTier: .hotAndCold,
                maxHotTTLTicks: 60,
                maxColdTTLTicks: 180,
                fundedUntilTick: 1_000
            )
        )
        try agreement.addCondition(
            ColdStorageCondition(
                allowPersistedColdTier: true,
                encryptedAtRestRequired: true,
                deleteIfUnfunded: true,
                tombstoneGraceTicks: 9
            )
        )

        let resolution = try RuntimeLifecycleAgreementMapper.resolve(
            agreement: agreement,
            nowTick: 10,
            defaults: RuntimeLifecycleAgreementDefaults(
                defaultHotTTLTicks: 300,
                defaultMemoryWarningLeadTicks: 20,
                defaultColdTTLTicks: 90,
                defaultTombstoneGraceTicks: 2,
                defaultMemoryExpiryAction: .notifyOnly
            )
        )

        XCTAssertEqual(resolution.replayMode, .snapshot)
        XCTAssertEqual(resolution.payerIdentityUUID, "payer-1")
        XCTAssertEqual(resolution.billingTier, .hotAndCold)
        XCTAssertEqual(resolution.policy.mode, .expiring)
        XCTAssertEqual(resolution.policy.memoryTTLTicks, 60)
        XCTAssertEqual(resolution.policy.persistedDataTTLTicks, 120)
        XCTAssertEqual(resolution.policy.tombstoneGraceTicks, 9)
        XCTAssertTrue(resolution.encryptedAtRestRequired)
    }

    func testAgreementMappingFailsWhenSnapshotReplayHasNoColdTier() throws {
        let owner = Identity()
        let agreement = Agreement(owner: owner)
        try agreement.addCondition(
            ReplayGuaranteeCondition(
                mode: .snapshot,
                minimumRetentionTicks: 100,
                allowEventLogGap: false
            )
        )

        XCTAssertThrowsError(
            try RuntimeLifecycleAgreementMapper.resolve(
                agreement: agreement,
                nowTick: 0,
                defaults: RuntimeLifecycleAgreementDefaults()
            )
        )
    }
}
