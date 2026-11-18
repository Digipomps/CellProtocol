// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

private actor DurabilityRecordingNotifier: RuntimeLifecycleOwnerNotifier {
    private(set) var notices: [RuntimeLifecycleOwnerNotice] = []

    func notify(_ notice: RuntimeLifecycleOwnerNotice) async {
        notices.append(notice)
    }

    func count(of type: RuntimeLifecycleEventType) -> Int {
        notices.filter { $0.type == type }.count
    }

    func types() -> [RuntimeLifecycleEventType] {
        notices.map(\.type)
    }
}

private actor FailingTombstoneAdapter: RuntimeLifecyclePersistenceAdapter {
    struct InjectedFailure: Error {}
    func writeTombstone(for descriptor: RuntimeResourceDescriptor, deleteAfterTick: UInt64, atTick: UInt64) async throws -> UInt64 {
        throw InjectedFailure()
    }
    func hardDelete(_ descriptor: RuntimeResourceDescriptor, atTick: UInt64) async throws -> RuntimeHardDeleteResult {
        throw InjectedFailure()
    }
}

/// Restart tests: an authority is dropped ("crash") and a new one is built
/// over the same directories and the same deterministic clock.
final class RuntimeLifecycleDurabilityTests: XCTestCase {
    private let owner = "owner-identity-uuid"
    private let resourceClass = "correspondence.relationship"
    private var root: URL!
    private var dataRoot: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var lifecycleRoot: URL { root.appendingPathComponent("lifecycle", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // TTL 100, warning at 80, tombstone grace 10.
    private func registry() throws -> RuntimeResourceTTLPolicyRegistry {
        let tier = RuntimeResourceTTLTier(ttlTicks: 100, warningLeadTicks: 20, tombstoneGraceTicks: 10)
        return try RuntimeResourceTTLPolicyRegistry(
            defaultPolicy: RuntimeResourceTTLClassPolicy(resourceClass: "*", normal: tier, test: tier)
        )
    }

    private func descriptor(_ id: String) -> RuntimeResourceDescriptor {
        RuntimeResourceDescriptor(
            resourceID: id,
            resourceClass: resourceClass,
            ownerIdentityUUID: owner,
            isTestData: false,
            storageLocations: [id, "backups/\(id).bak"]
        )
    }

    private func seed(_ id: String) throws {
        try FileManager.default.createDirectory(at: dataRoot.appendingPathComponent(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataRoot.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try Data("bak".utf8).write(to: dataRoot.appendingPathComponent("backups/\(id).bak"))
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(relative).path)
    }

    private func boot(
        _ time: DeterministicTimeSource,
        notifier: RuntimeLifecycleOwnerNotifier = RuntimeNoopLifecycleOwnerNotifier(),
        persistence: RuntimeLifecyclePersistenceAdapter? = nil
    ) throws -> RuntimeLifecycleAuthority {
        try RuntimeLifecycleAuthority.durable(
            directoryURL: lifecycleRoot,
            timeSource: time,
            registry: try registry(),
            persistence: persistence ?? FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: dataRoot),
            notifier: notifier,
            leaseDurationTicks: 5
        )
    }

    private func advance(_ time: DeterministicTimeSource, to tick: UInt64, _ authority: RuntimeLifecycleAuthority) async throws {
        time.setTick(tick)
        try await authority.processDue()
    }

    func testFileStateStorePersistsCASAndFailsClosedOnCorruptEntry() async throws {
        let dir = lifecycleRoot.appendingPathComponent("states")
        let store = try FileRuntimeLifecycleStateStore(directoryURL: dir)
        let state = RuntimeLifecycleState.initial(
            cellID: RuntimeCellID("a/b with spaces"),
            nowTick: 3,
            loadedInMemory: false,
            persistedSnapshotAvailable: true,
            policy: try registry().runtimePolicy(for: resourceClass, isTestData: false)
        )
        let inserted = await store.putIfAbsent(state)
        XCTAssertTrue(inserted)
        var next = state
        next.version += 1
        next.persistedExpiryTick = 500
        let wrongVersion = await store.compareAndSwap(cellID: state.cellID, expectedVersion: 99, next: next)
        XCTAssertFalse(wrongVersion)
        let swapped = await store.compareAndSwap(cellID: state.cellID, expectedVersion: state.version, next: next)
        XCTAssertTrue(swapped)

        let reopened = try FileRuntimeLifecycleStateStore(directoryURL: dir)
        let reread = await reopened.read(cellID: state.cellID)
        XCTAssertEqual(reread, next)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].contains("/"))

        try Data("not json".utf8).write(to: dir.appendingPathComponent("ff.json"))
        XCTAssertThrowsError(try FileRuntimeLifecycleStateStore(directoryURL: dir)) { error in
            guard case RuntimeLifecycleDurableStoreError.unreadableEntry = error else {
                return XCTFail("expected unreadableEntry, got \(error)")
            }
        }
    }

    func testRestartAfterWarningKeepsDeadlineAndDoesNotRewarn() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let firstNotifier = DurabilityRecordingNotifier()
        var authority: RuntimeLifecycleAuthority? = try boot(time, notifier: firstNotifier)
        try seed("rel-w")
        try await authority!.register(descriptor("rel-w"))
        try await advance(time, to: 85, authority!)
        let warned = await firstNotifier.count(of: .persistedTTLWarning)
        XCTAssertEqual(warned, 1)
        authority = nil  // crash

        let secondNotifier = DurabilityRecordingNotifier()
        let restarted = try boot(time, notifier: secondNotifier)
        let report = try await restarted.recover()
        XCTAssertEqual(report.activeResourceIDs, ["rel-w"])
        XCTAssertTrue(report.statesWithoutDescriptor.isEmpty)
        try await restarted.processDue()
        let rewarned = await secondNotifier.count(of: .persistedTTLWarning)
        XCTAssertEqual(rewarned, 0, "warning already delivered before the restart")

        // Owner check survives the restart (durable descriptor).
        do {
            try await restarted.extend(resourceID: "rel-w", byTicks: 10, requesterIdentityUUID: "someone-else")
            XCTFail("non-owner must still be refused after restart")
        } catch RuntimeLifecycleAuthorityError.notOwner {}

        try await advance(time, to: 99, restarted)
        XCTAssertTrue(exists("rel-w"))
        try await advance(time, to: 100, restarted)
        let tombstonedPhase = await restarted.state(for: "rel-w")?.phase
        XCTAssertEqual(tombstonedPhase, .tombstoned)
        try await advance(time, to: 110, restarted)
        XCTAssertFalse(exists("rel-w"))
        XCTAssertFalse(exists("backups/rel-w.bak"))
        let receipt = await restarted.receipt(for: "rel-w")
        XCTAssertEqual(receipt?.tombstonedAtTick, 100)
        XCTAssertEqual(receipt?.hardDeletedAtTick, 110)
    }

    func testRestartAfterWarningOwnerCanStillExtend() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time)
        try seed("rel-x")
        try await authority!.register(descriptor("rel-x"))
        try await advance(time, to: 85, authority!)
        authority = nil

        let restarted = try boot(time)
        try await restarted.recover()
        let extended = try await restarted.extend(resourceID: "rel-x", byTicks: 50, requesterIdentityUUID: owner)
        XCTAssertEqual(extended.persistedExpiryTick, 150)
        try await advance(time, to: 120, restarted)
        let phase = await restarted.state(for: "rel-x")?.phase
        XCTAssertEqual(phase, .activeUnloaded)
        XCTAssertTrue(exists("rel-x"))
    }

    func testDowntimePastDeadlineFiresOverdueExpiryDeterministicallyAtStartup() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time)
        try seed("rel-d")
        try await authority!.register(descriptor("rel-d"))
        authority = nil

        time.setTick(150)  // down across warning (80) and expiry (100)
        let notifier = DurabilityRecordingNotifier()
        let restarted = try boot(time, notifier: notifier)
        try await restarted.recover()
        try await restarted.processDue()

        let state = await restarted.state(for: "rel-d")
        XCTAssertEqual(state?.phase, .tombstoned)
        XCTAssertEqual(state?.hardDeleteTick, 160, "grace counts from the processing tick")
        let types = await notifier.types()
        XCTAssertEqual(types, [.persistedTTLWarning, .tombstoned])
        XCTAssertTrue(exists("rel-d"))
        try await advance(time, to: 160, restarted)
        XCTAssertFalse(exists("rel-d"))
    }

    func testRestartDuringTombstoneGraceKeepsOriginalTombstoneAndDeletesOnTime() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time)
        try seed("rel-t")
        try await authority!.register(descriptor("rel-t"))
        try await advance(time, to: 100, authority!)
        let phase = await authority!.state(for: "rel-t")?.phase
        XCTAssertEqual(phase, .tombstoned)
        authority = nil

        time.setTick(105)
        let restarted = try boot(time)
        let report = try await restarted.recover()
        XCTAssertEqual(report.tombstonedResourceIDs, ["rel-t"])
        try await advance(time, to: 109, restarted)
        XCTAssertTrue(exists("rel-t"))
        try await advance(time, to: 110, restarted)
        XCTAssertFalse(exists("rel-t"))
        let receipt = await restarted.receipt(for: "rel-t")
        XCTAssertEqual(receipt?.tombstonedAtTick, 100, "original tombstone tick survives the restart")
        XCTAssertEqual(receipt?.hardDeletedAtTick, 110)
    }

    func testCrashBeforeTombstoneWriteWritesTombstoneBeforeDeletingAfterRestart() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time, persistence: FailingTombstoneAdapter())
        try seed("rel-c")
        try await authority!.register(descriptor("rel-c"))
        try await advance(time, to: 100, authority!)   // state tombstoned, tombstone write failed
        authority = nil

        time.setTick(120)  // restart after the hard-delete deadline
        let adapter = FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: dataRoot)
        let restarted = try boot(time, persistence: adapter)
        try await restarted.recover()
        try await restarted.processDue()
        let tombstone = try await adapter.readTombstone(resourceID: "rel-c")
        XCTAssertNotNil(tombstone)
        XCTAssertEqual(tombstone?.tombstonedAtTick, 120)
        XCTAssertFalse(exists("rel-c"))
        let phase = await restarted.state(for: "rel-c")?.phase
        XCTAssertEqual(phase, .deleted)
    }

    func testRestartAfterDeletionReplaysReceiptWithoutTouchingOtherData() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time)
        try seed("rel-r")
        try seed("rel-keep")
        try await authority!.register(descriptor("rel-r"))
        try await authority!.register(descriptor("rel-keep"))
        time.setTick(4)
        let original = try await authority!.deleteNow(resourceID: "rel-r", requesterIdentityUUID: owner)
        authority = nil

        time.setTick(30)
        let restarted = try boot(time)
        let report = try await restarted.recover()
        XCTAssertEqual(report.deletedResourceIDs, ["rel-r"])
        XCTAssertEqual(report.activeResourceIDs, ["rel-keep"])
        try await restarted.processDue()
        let replayed = await restarted.receipt(for: "rel-r")
        XCTAssertEqual(replayed?.hardDeletedAtTick, original.hardDeletedAtTick)
        XCTAssertEqual(replayed?.tombstonedAtTick, original.tombstonedAtTick)
        XCTAssertEqual(replayed?.removedLocations, original.removedLocations)
        XCTAssertTrue(exists("rel-keep"))
    }

    func testRecoveredLeaseFencesOutPreRestartOwner() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        var authority: RuntimeLifecycleAuthority? = try boot(time)
        try await authority!.register(descriptor("rel-f"))
        let before = try await authority!.currentLease(for: "rel-f")
        authority = nil

        let restarted = try boot(time)
        try await restarted.recover()
        let after = try await restarted.currentLease(for: "rel-f")
        XCTAssertGreaterThan(after.fencingToken, before.fencingToken)
        let state = await restarted.state(for: "rel-f")
        XCTAssertEqual(state?.fencingToken, after.fencingToken)

        let reduced = RuntimeLifecycleTransitionReducer.reduce(
            state: try XCTUnwrap(state),
            input: .requestImmediateDeletion(nowTick: 1, fencingToken: before.fencingToken)
        )
        guard case .staleFence? = reduced.rejection else {
            return XCTFail("pre-restart fence must be rejected")
        }
    }

    func testWallClockEpochTimeSourceNeverGoesBackwards() {
        final class Clock: @unchecked Sendable { var seconds: Double = 1_000 }
        let clock = Clock()
        let source = WallClockEpochTimeSource(tickDurationSeconds: 1, floorTick: 0) {
            Date(timeIntervalSince1970: clock.seconds)
        }
        XCTAssertEqual(source.nowTick(), 1_000)
        clock.seconds = 1_010
        XCTAssertEqual(source.nowTick(), 1_010)
        clock.seconds = 900   // clock stepped back
        XCTAssertEqual(source.nowTick(), 1_010)
        let floored = WallClockEpochTimeSource(tickDurationSeconds: 1, floorTick: 5_000) {
            Date(timeIntervalSince1970: 1_000)
        }
        XCTAssertEqual(floored.nowTick(), 5_000)
    }
}
