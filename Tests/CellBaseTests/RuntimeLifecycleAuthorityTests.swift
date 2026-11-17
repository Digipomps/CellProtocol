// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@_spi(Testing) @testable import CellBase

private actor RecordingOwnerNotifier: RuntimeLifecycleOwnerNotifier {
    private(set) var notices: [RuntimeLifecycleOwnerNotice] = []

    func notify(_ notice: RuntimeLifecycleOwnerNotice) async {
        notices.append(notice)
    }

    func types() -> [RuntimeLifecycleEventType] {
        notices.map(\.type)
    }

    func count(of type: RuntimeLifecycleEventType) -> Int {
        notices.filter { $0.type == type }.count
    }

    func last(of type: RuntimeLifecycleEventType) -> RuntimeLifecycleOwnerNotice? {
        notices.last { $0.type == type }
    }
}

/// Wraps the file-system adapter and fails the first N calls of each kind.
private actor FlakyPersistenceAdapter: RuntimeLifecyclePersistenceAdapter {
    private let inner: FileSystemRuntimeLifecyclePersistenceAdapter
    private var tombstoneFailuresLeft: Int
    private var hardDeleteFailuresLeft: Int

    struct InjectedFailure: Error {}

    init(inner: FileSystemRuntimeLifecyclePersistenceAdapter, tombstoneFailures: Int = 0, hardDeleteFailures: Int = 0) {
        self.inner = inner
        self.tombstoneFailuresLeft = tombstoneFailures
        self.hardDeleteFailuresLeft = hardDeleteFailures
    }

    func writeTombstone(for descriptor: RuntimeResourceDescriptor, deleteAfterTick: UInt64, atTick: UInt64) async throws -> UInt64 {
        if tombstoneFailuresLeft > 0 {
            tombstoneFailuresLeft -= 1
            throw InjectedFailure()
        }
        return try await inner.writeTombstone(for: descriptor, deleteAfterTick: deleteAfterTick, atTick: atTick)
    }

    func hardDelete(_ descriptor: RuntimeResourceDescriptor, atTick: UInt64) async throws -> RuntimeHardDeleteResult {
        if hardDeleteFailuresLeft > 0 {
            hardDeleteFailuresLeft -= 1
            throw InjectedFailure()
        }
        return try await inner.hardDelete(descriptor, atTick: atTick)
    }
}

final class RuntimeLifecycleAuthorityTests: XCTestCase {
    private let owner = "owner-identity-uuid"
    private let stranger = "stranger-identity-uuid"
    private let resourceClass = "correspondence.relationship"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // TTL 100, warning 20 ticks ahead, tombstone grace 10. Test tier: TTL 10, warning 2, no grace.
    private func registry() throws -> RuntimeResourceTTLPolicyRegistry {
        try RuntimeResourceTTLPolicyRegistry(
            defaultPolicy: RuntimeResourceTTLClassPolicy(
                resourceClass: "*",
                normal: RuntimeResourceTTLTier(ttlTicks: 1_000, warningLeadTicks: 100, tombstoneGraceTicks: 50),
                test: RuntimeResourceTTLTier(ttlTicks: 20, warningLeadTicks: 5, tombstoneGraceTicks: 0)
            ),
            classPolicies: [
                RuntimeResourceTTLClassPolicy(
                    resourceClass: resourceClass,
                    normal: RuntimeResourceTTLTier(ttlTicks: 100, warningLeadTicks: 20, tombstoneGraceTicks: 10),
                    test: RuntimeResourceTTLTier(ttlTicks: 10, warningLeadTicks: 2, tombstoneGraceTicks: 0)
                )
            ]
        )
    }

    private func descriptor(_ id: String, isTestData: Bool = false) -> RuntimeResourceDescriptor {
        RuntimeResourceDescriptor(
            resourceID: id,
            resourceClass: resourceClass,
            ownerIdentityUUID: owner,
            isTestData: isTestData,
            storageLocations: [id, "snapshots/\(id).json", "backups/\(id).bak"]
        )
    }

    /// Creates data, snapshot and backup files for `id`.
    private func seedFiles(_ id: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(id), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: root.appendingPathComponent(id).appendingPathComponent("cell.json"))
        try fm.createDirectory(at: root.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        try Data("snap".utf8).write(to: root.appendingPathComponent("snapshots/\(id).json"))
        try fm.createDirectory(at: root.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try Data("bak".utf8).write(to: root.appendingPathComponent("backups/\(id).bak"))
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    private func makeAuthority(
        time: DeterministicTimeSource,
        notifier: RuntimeLifecycleOwnerNotifier,
        persistence: RuntimeLifecyclePersistenceAdapter? = nil
    ) throws -> RuntimeLifecycleAuthority {
        RuntimeLifecycleAuthority(
            timeSource: time,
            registry: try registry(),
            persistence: persistence ?? FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root),
            notifier: notifier,
            leaseDurationTicks: 5
        )
    }

    private func advance(_ time: DeterministicTimeSource, to tick: UInt64, _ authority: RuntimeLifecycleAuthority) async throws {
        time.setTick(tick)
        try await authority.processDue()
    }

    // MARK: Policy (G1: no implicit eternal lifetime, short TTL for test data)

    func testRegistryNeverYieldsNonExpiringPolicy() throws {
        let registry = try registry()
        for resourceClass in [self.resourceClass, "unknown.class"] {
            for isTest in [false, true] {
                let policy = try registry.runtimePolicy(for: resourceClass, isTestData: isTest)
                XCTAssertTrue(policy.isExpiring, "\(resourceClass) test=\(isTest)")
                XCTAssertNotNil(policy.persistedDataTTLTicks)
            }
        }
        XCTAssertEqual(try registry.runtimePolicy(for: "unknown.class", isTestData: false).persistedDataTTLTicks, 1_000)
        XCTAssertEqual(try registry.runtimePolicy(for: resourceClass, isTestData: true).persistedDataTTLTicks, 10)
        XCTAssertThrowsError(try registry.runtimePolicy(for: resourceClass, isTestData: false, ttlOverrideTicks: 0))
        XCTAssertTrue(RuntimeResourceTTLPolicyRegistry.standard().classPolicy(for: "correspondence.relationship").normal.ttlTicks > 0)
    }

    func testRegistryRejectsInvalidPolicies() {
        let ok = RuntimeResourceTTLTier(ttlTicks: 10, warningLeadTicks: 2, tombstoneGraceTicks: 0)
        func make(_ normal: RuntimeResourceTTLTier, _ test: RuntimeResourceTTLTier) throws {
            _ = try RuntimeResourceTTLPolicyRegistry(
                defaultPolicy: RuntimeResourceTTLClassPolicy(resourceClass: "*", normal: normal, test: test)
            )
        }
        XCTAssertThrowsError(try make(RuntimeResourceTTLTier(ttlTicks: 0, warningLeadTicks: 0, tombstoneGraceTicks: 0), ok))
        XCTAssertThrowsError(try make(RuntimeResourceTTLTier(ttlTicks: 10, warningLeadTicks: 10, tombstoneGraceTicks: 0), ok))
        XCTAssertThrowsError(try make(ok, RuntimeResourceTTLTier(ttlTicks: 11, warningLeadTicks: 2, tombstoneGraceTicks: 0)))
        XCTAssertThrowsError(
            try RuntimeResourceTTLPolicyRegistry(
                defaultPolicy: RuntimeResourceTTLClassPolicy(resourceClass: "*", normal: ok, test: ok),
                classPolicies: [
                    RuntimeResourceTTLClassPolicy(resourceClass: "a", normal: ok, test: ok),
                    RuntimeResourceTTLClassPolicy(resourceClass: "a", normal: ok, test: ok)
                ]
            )
        )
    }

    func testRegistrationWithoutTTLExpiresAndTestDataGetsShortTTL() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier())

        let normal = try await authority.register(descriptor("rel-normal"))
        let test = try await authority.register(descriptor("rel-test", isTestData: true))
        var other = descriptor("rel-other")
        other.resourceClass = "unconfigured.class"
        let fallback = try await authority.register(other)

        XCTAssertEqual(normal.persistedExpiryTick, 100)
        XCTAssertEqual(normal.persistedWarningTick, 80)
        XCTAssertEqual(test.persistedExpiryTick, 10)
        XCTAssertEqual(test.persistedWarningTick, 8)
        XCTAssertEqual(fallback.persistedExpiryTick, 1_000)

        do {
            try await authority.register(descriptor("rel-normal"))
            XCTFail("double registration must be refused")
        } catch RuntimeLifecycleAuthorityError.alreadyRegistered {}

        do {
            try await authority.register(descriptor("../escape"))
            XCTFail("path-like resource IDs must be refused")
        } catch RuntimeLifecyclePersistenceError.invalidResourceID {}
    }

    // MARK: Warning → extend

    func testWarningThenOwnerExtendKeepsData() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let notifier = RecordingOwnerNotifier()
        let authority = try makeAuthority(time: time, notifier: notifier)
        try seedFiles("rel-1")
        try await authority.register(descriptor("rel-1"))

        try await advance(time, to: 79, authority)
        let warningsBefore = await notifier.count(of: .persistedTTLWarning)
        XCTAssertEqual(warningsBefore, 0)

        try await advance(time, to: 80, authority)
        let warning = await notifier.last(of: .persistedTTLWarning)
        XCTAssertEqual(warning?.ownerIdentityUUID, owner)
        XCTAssertEqual(warning?.resourceClass, resourceClass)
        XCTAssertEqual(warning?.deadlineTick, 100)
        XCTAssertEqual(warning?.availableCommands, ["extend", "deleteNow"])

        // Duplicate processing at the same tick must not warn twice.
        try await authority.processDue()
        let warningsAfterRepeat = await notifier.count(of: .persistedTTLWarning)
        XCTAssertEqual(warningsAfterRepeat, 1)

        let extended = try await authority.extend(resourceID: "rel-1", byTicks: 50, requesterIdentityUUID: owner)
        XCTAssertEqual(extended.persistedExpiryTick, 150)
        XCTAssertEqual(extended.persistedWarningTick, 130)
        let extendedNotice = await notifier.last(of: .persistedTTLExtended)
        XCTAssertEqual(extendedNotice?.deadlineTick, 150)

        try await advance(time, to: 100, authority)
        try await advance(time, to: 129, authority)
        let phaseAfterOldDeadline = await authority.state(for: "rel-1")?.phase
        XCTAssertEqual(phaseAfterOldDeadline, .activeUnloaded)
        XCTAssertTrue(exists("rel-1"))
        let tombstones = await notifier.count(of: .tombstoned)
        XCTAssertEqual(tombstones, 0)

        try await advance(time, to: 130, authority)
        let warningsAfterExtension = await notifier.count(of: .persistedTTLWarning)
        XCTAssertEqual(warningsAfterExtension, 2)

        do {
            try await authority.extend(resourceID: "rel-1", byTicks: 10, requesterIdentityUUID: stranger)
            XCTFail("only the owner may extend")
        } catch RuntimeLifecycleAuthorityError.notOwner {}
    }

    // MARK: Warning → no answer → tombstone → hard delete

    func testNoAnswerLeadsToTombstoneThenHardDeleteOfDataSnapshotAndBackup() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let notifier = RecordingOwnerNotifier()
        let adapter = FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root)
        let authority = try makeAuthority(time: time, notifier: notifier, persistence: adapter)
        try seedFiles("rel-2")
        try await authority.register(descriptor("rel-2"))

        try await advance(time, to: 80, authority)
        try await advance(time, to: 100, authority)

        let tombstonedState = await authority.state(for: "rel-2")
        XCTAssertEqual(tombstonedState?.phase, .tombstoned)
        XCTAssertEqual(tombstonedState?.hardDeleteTick, 110)
        let tombstone = try await adapter.readTombstone(resourceID: "rel-2")
        XCTAssertEqual(tombstone?.tombstonedAtTick, 100)
        XCTAssertEqual(tombstone?.deleteAfterTick, 110)
        XCTAssertNil(tombstone?.hardDeletedAtTick)
        XCTAssertTrue(exists("rel-2"), "data is kept during tombstone grace")
        let tombstoneNotice = await notifier.last(of: .tombstoned)
        XCTAssertEqual(tombstoneNotice?.deadlineTick, 110)

        // Extending is no longer possible once tombstoned.
        do {
            try await authority.extend(resourceID: "rel-2", byTicks: 10, requesterIdentityUUID: owner)
            XCTFail("tombstoned resources cannot be extended")
        } catch RuntimeLifecycleManagerError.transitionRejected {}

        try await advance(time, to: 109, authority)
        XCTAssertTrue(exists("rel-2"))
        try await advance(time, to: 110, authority)

        let deletedPhase = await authority.state(for: "rel-2")?.phase
        XCTAssertEqual(deletedPhase, .deleted)
        XCTAssertFalse(exists("rel-2"))
        XCTAssertFalse(exists("snapshots/rel-2.json"))
        XCTAssertFalse(exists("backups/rel-2.bak"))

        let finalTombstone = try await adapter.readTombstone(resourceID: "rel-2")
        XCTAssertEqual(finalTombstone?.hardDeletedAtTick, 110)
        XCTAssertEqual(finalTombstone?.removedLocations, ["rel-2", "snapshots/rel-2.json", "backups/rel-2.bak"])

        let receipt = await authority.receipt(for: "rel-2")
        XCTAssertEqual(receipt?.trigger, .expired)
        XCTAssertEqual(receipt?.tombstonedAtTick, 100)
        XCTAssertEqual(receipt?.hardDeletedAtTick, 110)
        let types = await notifier.types()
        XCTAssertEqual(types, [.persistedTTLWarning, .tombstoned, .hardDeleted])
    }

    func testTestDataExpiresOnShortTTL() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier())
        try seedFiles("rel-test")
        try await authority.register(descriptor("rel-test", isTestData: true))

        try await advance(time, to: 10, authority)   // expiry → tombstone, grace 0 → hard delete due now
        try await advance(time, to: 10, authority)   // hard delete scheduled at the same tick
        let phase = await authority.state(for: "rel-test")?.phase
        XCTAssertEqual(phase, .deleted)
        XCTAssertFalse(exists("rel-test"))
    }

    // MARK: Delete now (G4)

    func testOwnerDeleteNowRemovesEverythingAndReturnsReceipt() async throws {
        let time = DeterministicTimeSource(initialTick: 5)
        let notifier = RecordingOwnerNotifier()
        let authority = try makeAuthority(time: time, notifier: notifier)
        try seedFiles("rel-3")
        try await authority.register(descriptor("rel-3"))

        do {
            _ = try await authority.deleteNow(resourceID: "rel-3", requesterIdentityUUID: stranger)
            XCTFail("only the owner may delete")
        } catch RuntimeLifecycleAuthorityError.notOwner {}
        XCTAssertTrue(exists("rel-3"))

        time.setTick(7)
        let receipt = try await authority.deleteNow(resourceID: "rel-3", requesterIdentityUUID: owner)
        XCTAssertEqual(receipt.trigger, .ownerRequest)
        XCTAssertEqual(receipt.ownerIdentityUUID, owner)
        XCTAssertEqual(receipt.tombstonedAtTick, 7)
        XCTAssertEqual(receipt.hardDeletedAtTick, 7)
        XCTAssertEqual(receipt.removedLocations, ["rel-3", "snapshots/rel-3.json", "backups/rel-3.bak"])
        XCTAssertFalse(exists("rel-3"))
        XCTAssertFalse(exists("snapshots/rel-3.json"))
        XCTAssertFalse(exists("backups/rel-3.bak"))
        let phase = await authority.state(for: "rel-3")?.phase
        XCTAssertEqual(phase, .deleted)

        // Idempotent: asking again returns the same receipt.
        let again = try await authority.deleteNow(resourceID: "rel-3", requesterIdentityUUID: owner)
        XCTAssertEqual(again, receipt)
    }

    func testDeleteNowDuringTombstoneGraceSkipsRemainingGrace() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier())
        try seedFiles("rel-4")
        try await authority.register(descriptor("rel-4"))
        try await advance(time, to: 100, authority)
        let phase = await authority.state(for: "rel-4")?.phase
        XCTAssertEqual(phase, .tombstoned)

        time.setTick(102)
        let receipt = try await authority.deleteNow(resourceID: "rel-4", requesterIdentityUUID: owner)
        XCTAssertEqual(receipt.trigger, .ownerRequest)
        XCTAssertEqual(receipt.tombstonedAtTick, 100)
        XCTAssertEqual(receipt.hardDeletedAtTick, 102)
        XCTAssertFalse(exists("rel-4"))
    }

    // MARK: Fencing

    func testStaleFenceIsRejectedAndLeavesStateUnchanged() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let leases = InMemoryRuntimeLeaseCoordinator()
        let manager = RuntimeLifecycleManager(timeSource: time, leaseCoordinator: leases)
        let cellID = RuntimeCellID("rel-fence")
        let policy = try registry().runtimePolicy(for: resourceClass, isTestData: false)
        let (_, firstLease) = try await manager.registerCell(
            cellID: cellID,
            policy: policy,
            loadedInMemory: false,
            persistedSnapshotAvailable: true,
            nodeID: "node-a",
            leaseDurationTicks: 5
        )

        // node-a's lease lapses; node-b takes over with a newer fencing token.
        time.setTick(6)
        let takeover = try await manager.acquireLease(cellID: cellID, nodeID: "node-b", leaseDurationTicks: 50)
        XCTAssertGreaterThan(takeover.fencingToken, firstLease.fencingToken)
        let before = await manager.readState(cellID: cellID)

        // A stale owner that still believes it holds the lease.
        let stale = RuntimeLease(
            cellID: cellID,
            ownerNodeID: "node-a",
            fencingToken: firstLease.fencingToken,
            validUntilTick: 1_000
        )
        for command in [RuntimeLifecycleWarningCommand.deleteNow, .delete, .extendPersistedTTL(byTicks: 10)] {
            do {
                _ = try await manager.applyWarningCommand(cellID: cellID, lease: stale, command: command)
                XCTFail("stale fence must be rejected for \(command)")
            } catch RuntimeLifecycleManagerError.transitionRejected(let rejection) {
                guard case .staleFence(let expected, let actual) = rejection else {
                    return XCTFail("unexpected rejection \(rejection)")
                }
                XCTAssertEqual(expected, takeover.fencingToken)
                XCTAssertEqual(actual, firstLease.fencingToken)
            }
        }
        let after = await manager.readState(cellID: cellID)
        XCTAssertEqual(after, before)

        // The current owner is accepted.
        let extended = try await manager.applyWarningCommand(
            cellID: cellID,
            lease: takeover,
            command: .extendPersistedTTL(byTicks: 10)
        )
        XCTAssertEqual(extended.persistedExpiryTick, 110)
    }

    func testAuthorityLeaseRenewalKeepsScheduledExpiryValid() async throws {
        // Lease duration (5) is far shorter than TTL (100). Commands renew,
        // never re-acquire, so the expiry scheduled at registration still fires.
        let time = DeterministicTimeSource(initialTick: 0)
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier())
        try await authority.register(descriptor("rel-lease"))
        let firstToken = try await authority.currentLease(for: "rel-lease").fencingToken
        time.setTick(50)
        let renewedToken = try await authority.currentLease(for: "rel-lease").fencingToken
        XCTAssertEqual(firstToken, renewedToken)
        try await advance(time, to: 100, authority)
        let phase = await authority.state(for: "rel-lease")?.phase
        XCTAssertEqual(phase, .tombstoned)
    }

    // MARK: Effect failures (F5)

    func testHardDeleteFailureIsRetriedUntilDataIsGone() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let adapter = FlakyPersistenceAdapter(
            inner: FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root),
            hardDeleteFailures: 1
        )
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier(), persistence: adapter)
        try seedFiles("rel-5")
        try await authority.register(descriptor("rel-5"))

        time.setTick(1)
        do {
            _ = try await authority.deleteNow(resourceID: "rel-5", requesterIdentityUUID: owner)
            XCTFail("first hard delete is injected to fail")
        } catch RuntimeLifecycleAuthorityError.hardDeletePending {}
        XCTAssertTrue(exists("rel-5"))
        let failures = await authority.effectFailures()
        XCTAssertEqual(failures.count, 1)

        try await advance(time, to: 2, authority)
        XCTAssertFalse(exists("rel-5"))
        let receipt = await authority.receipt(for: "rel-5")
        XCTAssertEqual(receipt?.hardDeletedAtTick, 2)
        XCTAssertEqual(receipt?.trigger, .ownerRequest)
    }

    func testHardDeleteWaitsForDurableTombstone() async throws {
        let time = DeterministicTimeSource(initialTick: 0)
        let inner = FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root)
        let adapter = FlakyPersistenceAdapter(inner: inner, tombstoneFailures: 1)
        let authority = try makeAuthority(time: time, notifier: RecordingOwnerNotifier(), persistence: adapter)
        try seedFiles("rel-6")
        try await authority.register(descriptor("rel-6", isTestData: true))

        try await advance(time, to: 10, authority)   // tombstone write fails
        try await advance(time, to: 10, authority)   // hard delete due, but tombstone not durable yet → retried first
        let tombstone = try await inner.readTombstone(resourceID: "rel-6")
        XCTAssertNotNil(tombstone)

        try await advance(time, to: 11, authority)
        XCTAssertFalse(exists("rel-6"))
        let finalTombstone = try await inner.readTombstone(resourceID: "rel-6")
        XCTAssertNotNil(finalTombstone?.hardDeletedAtTick)
    }

    func testHardDeleteNeverRunsWithoutTombstoneAtAdapterLevel() async throws {
        try seedFiles("rel-7")
        let adapter = FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root)
        do {
            _ = try await adapter.hardDelete(descriptor("rel-7"), atTick: 1)
            XCTFail("hard delete without tombstone must fail")
        } catch RuntimeLifecyclePersistenceError.tombstoneMissing {}
        XCTAssertTrue(exists("rel-7"))
    }

    func testStorageLocationsCannotEscapeRoot() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let adapter = FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root)
        var bad = descriptor("rel-8")
        bad.storageLocations = ["../\(outside.lastPathComponent)"]
        _ = try await adapter.writeTombstone(for: bad, deleteAfterTick: 0, atTick: 0)
        do {
            _ = try await adapter.hardDelete(bad, atTick: 0)
            XCTFail("escaping location must be refused")
        } catch RuntimeLifecyclePersistenceError.locationEscapesRoot {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: Reducer / compatibility

    func testPersistedWarningIsIdempotentForDuplicateDelivery() throws {
        let policy = try registry().runtimePolicy(for: resourceClass, isTestData: false)
        let state = RuntimeLifecycleState.initial(
            cellID: RuntimeCellID("rel-dup"),
            nowTick: 0,
            loadedInMemory: false,
            persistedSnapshotAvailable: true,
            policy: policy
        )
        let first = RuntimeLifecycleTransitionReducer.reduce(
            state: state,
            input: .persistedWarningFired(generation: state.persistedGeneration, nowTick: 80, fencingToken: 0)
        )
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.effects.count, 1)
        let second = RuntimeLifecycleTransitionReducer.reduce(
            state: first.state,
            input: .persistedWarningFired(generation: state.persistedGeneration, nowTick: 80, fencingToken: 0)
        )
        XCTAssertFalse(second.changed)
        XCTAssertTrue(second.effects.isEmpty)
    }

    func testPreP1EncodedPolicyStateAndEventStillDecode() throws {
        let legacyPolicy = """
        {"mode":"expiring","memoryTTLTicks":10,"memoryWarningLeadTicks":2,"persistedDataTTLTicks":20,
         "tombstoneGraceTicks":3,"memoryExpiryAction":"notifyOnly"}
        """
        let policy = try JSONDecoder().decode(RuntimeLifecyclePolicy.self, from: Data(legacyPolicy.utf8))
        XCTAssertNil(policy.persistedWarningLeadTicks)

        let state = RuntimeLifecycleState.initial(
            cellID: RuntimeCellID("legacy"),
            nowTick: 0,
            loadedInMemory: true,
            persistedSnapshotAvailable: true,
            policy: policy
        )
        XCTAssertNil(state.persistedWarningTick, "pre-P1 policies schedule no persisted warning")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object.removeValue(forKey: "persistedWarningTick")
        object.removeValue(forKey: "lastProcessedPersistedWarningGeneration")
        let decoded = try JSONDecoder().decode(
            RuntimeLifecycleState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded, state)

        let legacyEvent = """
        {"type":"tombstoned","cellID":"legacy","version":1,"tick":5,"fencingToken":1}
        """
        let event = try JSONDecoder().decode(RuntimeLifecycleEvent.self, from: Data(legacyEvent.utf8))
        XCTAssertNil(event.deadlineTick)
    }
}

#if DEBUG
/// Resolver opt-in: resolves bound to the authority skip legacy tracking;
/// others are unchanged.
final class RuntimeLifecycleAuthorityResolverTests: XCTestCase {
    private var previousVault: IdentityVaultProtocol?
    private var previousResolver: CellResolverProtocol?
    private var previousDocumentRoot: String?
    private var root: URL!

    override func setUpWithError() throws {
        previousVault = CellBase.defaultIdentityVault
        previousResolver = CellBase.defaultCellResolver
        previousDocumentRoot = CellBase.documentRootPath
        CellBase.defaultIdentityVault = MockIdentityVault()
        CellBase.defaultCellResolver = CellResolver.sharedInstance
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-authority-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CellBase.documentRootPath = root.path
    }

    override func tearDown() async throws {
        await CellResolver.sharedInstance.disableRuntimeLifecycleAuthority()
        CellBase.defaultIdentityVault = previousVault
        CellBase.defaultCellResolver = previousResolver
        CellBase.documentRootPath = previousDocumentRoot
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testOptedInResolveIsRuntimeAuthoritativeAndOthersStayLegacy() async throws {
        let resolver = CellResolver.sharedInstance
        let time = DeterministicTimeSource(initialTick: 0)
        let authority = RuntimeLifecycleAuthority(
            timeSource: time,
            registry: .standard(),
            persistence: FileSystemRuntimeLifecyclePersistenceAdapter(rootURL: root)
        )
        let legacyPolicy = CellLifecyclePolicy(
            memoryTTL: 3_600,
            warningLeadTime: 60,
            persistedDataTTL: nil,
            memoryExpiryAction: .notifyOnly
        )
        let optedIn = "TTL-P1-Authority-\(UUID().uuidString)"
        let legacy = "TTL-P1-Legacy-\(UUID().uuidString)"
        for name in [optedIn, legacy] {
            try await resolver.addCellResolve(
                name: name,
                cellScope: .scaffoldUnique,
                identityDomain: "private",
                lifecyclePolicy: legacyPolicy,
                type: GeneralCell.self
            )
        }
        await resolver.enableRuntimeLifecycleAuthority(
            authority,
            bindings: [optedIn: RuntimeLifecycleAuthorityResolveBinding(resourceClass: "correspondence.relationship", isTestData: true)],
            startProcessingLoop: false
        )

        let maybeIdentity = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true)
        let identity = try XCTUnwrap(maybeIdentity)
        let optedInCell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(optedIn)", requester: identity)
        let legacyCell = try await resolver.cellAtEndpoint(endpoint: "cell:///\(legacy)", requester: identity)

        // Opted in: runtime authority owns it, legacy tracker does not.
        let optedInAuthoritative = await authority.isAuthoritative(for: optedInCell.uuid)
        XCTAssertTrue(optedInAuthoritative)
        let optedInLegacy = await resolver.legacyLifecycleTrackingStateForTesting(uuid: optedInCell.uuid)
        XCTAssertFalse(optedInLegacy.memory)
        XCTAssertFalse(optedInLegacy.persisted)
        let state = await authority.state(for: optedInCell.uuid)
        XCTAssertEqual(state?.persistedExpiryTick, RuntimeResourceTTLPolicyRegistry.standard()
            .classPolicy(for: "correspondence.relationship").test.ttlTicks)

        // Not opted in: unchanged legacy behaviour.
        let legacyAuthoritative = await authority.isAuthoritative(for: legacyCell.uuid)
        XCTAssertFalse(legacyAuthoritative)
        let legacyTracking = await resolver.legacyLifecycleTrackingStateForTesting(uuid: legacyCell.uuid)
        XCTAssertTrue(legacyTracking.memory)

        // Owner deletes now: tombstone + hard delete, and the in-memory instance is evicted.
        let ownerUUID = optedInCell.agreementTemplate.owner.uuid.isEmpty
            ? identity.uuid
            : optedInCell.agreementTemplate.owner.uuid
        let dataDir = root.appendingPathComponent(optedInCell.uuid)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let receipt = try await authority.deleteNow(resourceID: optedInCell.uuid, requesterIdentityUUID: ownerUUID)
        XCTAssertEqual(receipt.trigger, .ownerRequest)
        XCTAssertTrue(receipt.removedLocations.contains(optedInCell.uuid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDir.path))
        let inMemory = await resolver.auditor.loadCellInstance(forUUID: optedInCell.uuid)
        XCTAssertNil(inMemory)
    }
}
#endif
