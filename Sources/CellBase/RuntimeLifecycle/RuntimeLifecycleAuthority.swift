// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// MARK: - P1: runtime lifecycle authority for opted-in resources
//
// P0 ran the runtime lifecycle as an observer next to the legacy
// `ResolverLifecycleTracker`. P1 lets selected resources (opt-in, per resolve
// or per resource) be owned by the runtime lifecycle alone:
//
// - every registered resource gets a TTL from a resource-class policy; a
//   resource registered without an explicit TTL still expires (no implicit
//   "forever"),
// - the owner is warned before persisted data expires and can extend it or
//   delete it now,
// - what is not extended is tombstoned (tombstone persisted first) and then
//   hard deleted, including snapshot/backup locations,
// - effects go through a persistence adapter that really writes the tombstone
//   and really removes the data.
//
// Resources that are not registered here keep their existing behaviour.

/// TTL values for one tier (normal or test-marked data) of a resource class.
public struct RuntimeResourceTTLTier: Codable, Sendable, Equatable {
    public var ttlTicks: UInt64
    public var warningLeadTicks: UInt64
    public var tombstoneGraceTicks: UInt64

    public init(ttlTicks: UInt64, warningLeadTicks: UInt64, tombstoneGraceTicks: UInt64) {
        self.ttlTicks = ttlTicks
        self.warningLeadTicks = warningLeadTicks
        self.tombstoneGraceTicks = tombstoneGraceTicks
    }
}

/// TTL policy for a resource class such as `correspondence.relationship`.
public struct RuntimeResourceTTLClassPolicy: Codable, Sendable, Equatable {
    public var resourceClass: String
    public var normal: RuntimeResourceTTLTier
    /// Applied when a resource is marked as test data. Must not outlive `normal`.
    public var test: RuntimeResourceTTLTier

    public init(resourceClass: String, normal: RuntimeResourceTTLTier, test: RuntimeResourceTTLTier) {
        self.resourceClass = resourceClass
        self.normal = normal
        self.test = test
    }

    public func tier(isTestData: Bool) -> RuntimeResourceTTLTier {
        isTestData ? test : normal
    }
}

public enum RuntimeResourceTTLPolicyError: Error, Sendable, Equatable {
    case emptyResourceClass
    case zeroTTL(resourceClass: String)
    case warningNotBeforeExpiry(resourceClass: String)
    case testTierOutlivesNormal(resourceClass: String)
    case duplicateResourceClass(String)
    case zeroOverride
}

/// Resource class → TTL policy. Unknown classes fall back to `defaultPolicy`,
/// which is always expiring: creating a resource without a TTL never yields
/// an unbounded lifetime.
public struct RuntimeResourceTTLPolicyRegistry: Sendable, Equatable {
    public let defaultPolicy: RuntimeResourceTTLClassPolicy
    private let policiesByClass: [String: RuntimeResourceTTLClassPolicy]

    public init(
        defaultPolicy: RuntimeResourceTTLClassPolicy,
        classPolicies: [RuntimeResourceTTLClassPolicy] = []
    ) throws {
        try Self.validate(defaultPolicy)
        var byClass = [String: RuntimeResourceTTLClassPolicy]()
        for policy in classPolicies {
            try Self.validate(policy)
            guard byClass[policy.resourceClass] == nil else {
                throw RuntimeResourceTTLPolicyError.duplicateResourceClass(policy.resourceClass)
            }
            byClass[policy.resourceClass] = policy
        }
        self.defaultPolicy = defaultPolicy
        self.policiesByClass = byClass
    }

    public var resourceClasses: [String] {
        policiesByClass.keys.sorted()
    }

    public func classPolicy(for resourceClass: String) -> RuntimeResourceTTLClassPolicy {
        policiesByClass[resourceClass] ?? defaultPolicy
    }

    /// Runtime policy for a resource. `ttlOverrideTicks` replaces the class TTL
    /// but can never turn expiry off. The warning lead is clamped below the TTL.
    public func runtimePolicy(
        for resourceClass: String,
        isTestData: Bool,
        ttlOverrideTicks: UInt64? = nil
    ) throws -> RuntimeLifecyclePolicy {
        var tier = classPolicy(for: resourceClass).tier(isTestData: isTestData)
        if let ttlOverrideTicks {
            guard ttlOverrideTicks > 0 else {
                throw RuntimeResourceTTLPolicyError.zeroOverride
            }
            tier.ttlTicks = ttlOverrideTicks
        }
        let warningLead = tier.warningLeadTicks < tier.ttlTicks ? tier.warningLeadTicks : 0
        return .expiring(
            memoryTTLTicks: tier.ttlTicks,
            memoryWarningLeadTicks: 0,
            persistedDataTTLTicks: tier.ttlTicks,
            tombstoneGraceTicks: tier.tombstoneGraceTicks,
            memoryExpiryAction: .notifyOnly,
            persistedWarningLeadTicks: warningLead
        )
    }

    private static func validate(_ policy: RuntimeResourceTTLClassPolicy) throws {
        guard !policy.resourceClass.isEmpty else {
            throw RuntimeResourceTTLPolicyError.emptyResourceClass
        }
        for tier in [policy.normal, policy.test] {
            guard tier.ttlTicks > 0 else {
                throw RuntimeResourceTTLPolicyError.zeroTTL(resourceClass: policy.resourceClass)
            }
            guard tier.warningLeadTicks < tier.ttlTicks else {
                throw RuntimeResourceTTLPolicyError.warningNotBeforeExpiry(resourceClass: policy.resourceClass)
            }
        }
        guard policy.test.ttlTicks <= policy.normal.ttlTicks else {
            throw RuntimeResourceTTLPolicyError.testTierOutlivesNormal(resourceClass: policy.resourceClass)
        }
    }

    private static let day: UInt64 = 86_400

    /// Defaults with one tick = one second (`SystemMonotonicTimeSource` default).
    /// Normal data: 90 days, warned 7 days ahead, 7 days tombstone grace.
    /// Test data: 1 day, warned 1 hour ahead, no grace.
    public static func standard() -> RuntimeResourceTTLPolicyRegistry {
        let normal = RuntimeResourceTTLTier(ttlTicks: 90 * day, warningLeadTicks: 7 * day, tombstoneGraceTicks: 7 * day)
        let test = RuntimeResourceTTLTier(ttlTicks: day, warningLeadTicks: 3_600, tombstoneGraceTicks: 0)
        // Values are statically valid; force-try documents that invariant.
        return try! RuntimeResourceTTLPolicyRegistry(
            defaultPolicy: RuntimeResourceTTLClassPolicy(resourceClass: "*", normal: normal, test: test),
            classPolicies: [
                RuntimeResourceTTLClassPolicy(
                    resourceClass: "correspondence.relationship",
                    normal: normal,
                    test: test
                )
            ]
        )
    }
}

/// What the authority knows about a resource it owns.
public struct RuntimeResourceDescriptor: Codable, Sendable, Equatable {
    public var resourceID: String
    public var resourceClass: String
    public var ownerIdentityUUID: String
    public var isTestData: Bool
    /// Storage locations relative to the persistence root, including
    /// snapshots and backups. All are removed on hard delete.
    public var storageLocations: [String]

    public init(
        resourceID: String,
        resourceClass: String,
        ownerIdentityUUID: String,
        isTestData: Bool,
        storageLocations: [String]
    ) {
        self.resourceID = resourceID
        self.resourceClass = resourceClass
        self.ownerIdentityUUID = ownerIdentityUUID
        self.isTestData = isTestData
        self.storageLocations = storageLocations
    }
}

// MARK: Persistence effects

public enum RuntimeLifecyclePersistenceError: Error, Sendable, Equatable {
    case invalidResourceID(String)
    case locationEscapesRoot(String)
    case tombstoneMissing(String)
}

/// Performs the persisted side effects of the lifecycle. Implementations must
/// make `writeTombstone` durable before returning, and `hardDelete` must remove
/// every location in the descriptor (data, snapshots, backups).
public protocol RuntimeLifecyclePersistenceAdapter: Sendable {
    func writeTombstone(
        for descriptor: RuntimeResourceDescriptor,
        deleteAfterTick: UInt64,
        atTick: UInt64
    ) async throws
    /// Returns the locations that existed and were removed.
    func hardDelete(_ descriptor: RuntimeResourceDescriptor, atTick: UInt64) async throws -> [String]
}

/// Tombstone record. Holds identifiers and ticks only, never resource content,
/// so it may outlive the data as an audit trail.
public struct RuntimeTombstoneRecord: Codable, Sendable, Equatable {
    public var resourceID: String
    public var resourceClass: String
    public var ownerIdentityUUID: String
    public var tombstonedAtTick: UInt64
    public var deleteAfterTick: UInt64
    public var hardDeletedAtTick: UInt64?
    public var removedLocations: [String]?
}

/// File-system adapter. Tombstones live in `<root>/.lifecycle-tombstones/`.
public actor FileSystemRuntimeLifecyclePersistenceAdapter: RuntimeLifecyclePersistenceAdapter {
    public static let tombstoneDirectoryName = ".lifecycle-tombstones"

    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func tombstoneURL(for resourceID: String) throws -> URL {
        try Self.validateIdentifier(resourceID)
        return rootURL
            .appendingPathComponent(Self.tombstoneDirectoryName, isDirectory: true)
            .appendingPathComponent("\(resourceID).json")
    }

    public func readTombstone(resourceID: String) throws -> RuntimeTombstoneRecord? {
        let url = try tombstoneURL(for: resourceID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(RuntimeTombstoneRecord.self, from: Data(contentsOf: url))
    }

    public func writeTombstone(
        for descriptor: RuntimeResourceDescriptor,
        deleteAfterTick: UInt64,
        atTick: UInt64
    ) async throws {
        let url = try tombstoneURL(for: descriptor.resourceID)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record = RuntimeTombstoneRecord(
            resourceID: descriptor.resourceID,
            resourceClass: descriptor.resourceClass,
            ownerIdentityUUID: descriptor.ownerIdentityUUID,
            tombstonedAtTick: atTick,
            deleteAfterTick: deleteAfterTick,
            hardDeletedAtTick: nil,
            removedLocations: nil
        )
        try write(record, to: url)
    }

    public func hardDelete(_ descriptor: RuntimeResourceDescriptor, atTick: UInt64) async throws -> [String] {
        let tombstoneURL = try tombstoneURL(for: descriptor.resourceID)
        guard var record = try readTombstone(resourceID: descriptor.resourceID) else {
            // Hard delete is only reachable through a persisted tombstone.
            throw RuntimeLifecyclePersistenceError.tombstoneMissing(descriptor.resourceID)
        }
        var removed = [String]()
        for location in descriptor.storageLocations {
            let url = try resolve(location)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed.append(location)
            }
        }
        record.hardDeletedAtTick = atTick
        record.removedLocations = removed
        try write(record, to: tombstoneURL)
        return removed
    }

    private func write(_ record: RuntimeTombstoneRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func resolve(_ location: String) throws -> URL {
        guard !location.isEmpty,
              !location.hasPrefix("/"),
              !location.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw RuntimeLifecyclePersistenceError.locationEscapesRoot(location)
        }
        let url = rootURL.appendingPathComponent(location).standardizedFileURL
        guard url.path.hasPrefix(rootURL.path + "/") else {
            throw RuntimeLifecyclePersistenceError.locationEscapesRoot(location)
        }
        return url
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              !identifier.contains("/"),
              !identifier.contains("\\"),
              identifier != ".",
              identifier != ".." else {
            throw RuntimeLifecyclePersistenceError.invalidResourceID(identifier)
        }
    }
}

// MARK: Owner notification

/// Notice to the owner of a resource. Delivered only to the owner identity.
public struct RuntimeLifecycleOwnerNotice: Codable, Sendable, Equatable {
    public var type: RuntimeLifecycleEventType
    public var resourceID: String
    public var resourceClass: String
    public var ownerIdentityUUID: String
    public var tick: UInt64
    public var deadlineTick: UInt64?
    public var availableCommands: [String]
}

public protocol RuntimeLifecycleOwnerNotifier: Sendable {
    func notify(_ notice: RuntimeLifecycleOwnerNotice) async
}

public actor RuntimeNoopLifecycleOwnerNotifier: RuntimeLifecycleOwnerNotifier {
    public init() {}
    public func notify(_ notice: RuntimeLifecycleOwnerNotice) async {}
}

/// Publishes owner notices on `runtime.lifecycle` through the emitter bound to
/// the owner identity. If the owner has no emitter, nothing is broadcast.
public actor RuntimeLifecycleFlowOwnerNotifier: RuntimeLifecycleOwnerNotifier {
    public typealias EmitterLookup = @Sendable (String) async -> FlowElementPusherCell?
    private let emitterForOwner: EmitterLookup

    public init(emitterForOwner: @escaping EmitterLookup) {
        self.emitterForOwner = emitterForOwner
    }

    public func notify(_ notice: RuntimeLifecycleOwnerNotice) async {
        guard let emitter = await emitterForOwner(notice.ownerIdentityUUID) else {
            return
        }
        var payload: Object = [
            "type": .string(notice.type.rawValue),
            "resourceID": .string(notice.resourceID),
            "resourceClass": .string(notice.resourceClass),
            "ownerIdentityUUID": .string(notice.ownerIdentityUUID),
            "recipientIdentityUUIDs": .list([.string(notice.ownerIdentityUUID)]),
            "tick": .string(String(notice.tick)),
            "authority": .string("runtime")
        ]
        if let deadlineTick = notice.deadlineTick {
            payload["deadlineTick"] = .string(String(deadlineTick))
        }
        if !notice.availableCommands.isEmpty {
            payload["availableCommands"] = .list(notice.availableCommands.map { .string($0) })
            payload["commandRoute"] = .string("RuntimeLifecycleAuthority")
        }
        var flowElement = FlowElement(
            title: "Runtime lifecycle owner notice",
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "runtime.lifecycle"
        emitter.pushFlowElement(flowElement, requester: emitter.owner)
    }
}

// MARK: Deletion receipt

/// Receipt for a completed hard delete (expiry or owner request).
public struct RuntimeDeletionReceipt: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable {
        case expired
        case ownerRequest
    }

    public var resourceID: String
    public var resourceClass: String
    public var ownerIdentityUUID: String
    public var trigger: Trigger
    public var tombstonedAtTick: UInt64
    public var hardDeletedAtTick: UInt64
    public var removedLocations: [String]
}

// MARK: Effect router

/// Effect sink used by the authority. Routes persisted effects to the
/// persistence adapter, owner-relevant events to the notifier, and keeps
/// failed hard deletes for retry (failure mode F5).
public actor RuntimeLifecycleResourceEffectRouter: RuntimeLifecycleEffectSink {
    private let timeSource: MonotonicTimeSource
    private let persistence: RuntimeLifecyclePersistenceAdapter
    private let notifier: RuntimeLifecycleOwnerNotifier

    private var descriptors = [RuntimeCellID: RuntimeResourceDescriptor]()
    private var tombstonedAt = [RuntimeCellID: UInt64]()
    private var pendingTombstones = [RuntimeCellID: UInt64]()
    private var pendingHardDeletes = Set<RuntimeCellID>()
    private var ownerRequested = Set<RuntimeCellID>()
    private var receipts = [RuntimeCellID: RuntimeDeletionReceipt]()
    private var failures = [String]()
    private var hardDeleteObserver: (@Sendable (RuntimeDeletionReceipt) async -> Void)?

    init(
        timeSource: MonotonicTimeSource,
        persistence: RuntimeLifecyclePersistenceAdapter,
        notifier: RuntimeLifecycleOwnerNotifier
    ) {
        self.timeSource = timeSource
        self.persistence = persistence
        self.notifier = notifier
    }

    func register(_ descriptor: RuntimeResourceDescriptor) {
        descriptors[RuntimeCellID(descriptor.resourceID)] = descriptor
    }

    func descriptor(for cellID: RuntimeCellID) -> RuntimeResourceDescriptor? {
        descriptors[cellID]
    }

    func markOwnerRequested(_ cellID: RuntimeCellID) {
        ownerRequested.insert(cellID)
    }

    func setHardDeleteObserver(_ observer: (@Sendable (RuntimeDeletionReceipt) async -> Void)?) {
        hardDeleteObserver = observer
    }

    func receipt(for cellID: RuntimeCellID) -> RuntimeDeletionReceipt? {
        receipts[cellID]
    }

    func hasPendingHardDelete(_ cellID: RuntimeCellID) -> Bool {
        pendingHardDeletes.contains(cellID) || pendingTombstones[cellID] != nil
    }

    func recordedFailures() -> [String] {
        failures
    }

    public func handle(effect: RuntimeLifecycleEffect) async {
        switch effect {
        case .writeTombstone(let cellID, let deleteAfterTick):
            await writeTombstone(cellID: cellID, deleteAfterTick: deleteAfterTick)
        case .hardDeletePersistedData(let cellID):
            await hardDelete(cellID: cellID)
        case .emit(let event):
            await notifyOwnerIfRelevant(event)
        default:
            // Memory effects (persist/unload) are not owned by the authority in P1.
            break
        }
    }

    /// Retries tombstone writes and hard deletes that failed earlier.
    func retryPending() async {
        for (cellID, deleteAfterTick) in pendingTombstones.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            await writeTombstone(cellID: cellID, deleteAfterTick: deleteAfterTick)
        }
        for cellID in pendingHardDeletes.sorted(by: { $0.rawValue < $1.rawValue }) {
            await hardDelete(cellID: cellID)
        }
    }

    private func writeTombstone(cellID: RuntimeCellID, deleteAfterTick: UInt64) async {
        guard let descriptor = descriptors[cellID] else {
            return
        }
        let now = timeSource.nowTick()
        do {
            try await persistence.writeTombstone(for: descriptor, deleteAfterTick: deleteAfterTick, atTick: now)
            pendingTombstones[cellID] = nil
            if tombstonedAt[cellID] == nil {
                tombstonedAt[cellID] = now
            }
        } catch {
            pendingTombstones[cellID] = deleteAfterTick
            failures.append("writeTombstone \(cellID.rawValue): \(error)")
        }
    }

    private func hardDelete(cellID: RuntimeCellID) async {
        guard let descriptor = descriptors[cellID] else {
            return
        }
        guard pendingTombstones[cellID] == nil, let tombstonedAtTick = tombstonedAt[cellID] else {
            // Never delete before the tombstone is durable; retry later.
            pendingHardDeletes.insert(cellID)
            failures.append("hardDelete \(cellID.rawValue): tombstone not persisted")
            return
        }
        let now = timeSource.nowTick()
        do {
            let removed = try await persistence.hardDelete(descriptor, atTick: now)
            pendingHardDeletes.remove(cellID)
            let receipt = RuntimeDeletionReceipt(
                resourceID: descriptor.resourceID,
                resourceClass: descriptor.resourceClass,
                ownerIdentityUUID: descriptor.ownerIdentityUUID,
                trigger: ownerRequested.contains(cellID) ? .ownerRequest : .expired,
                tombstonedAtTick: tombstonedAtTick,
                hardDeletedAtTick: now,
                removedLocations: removed
            )
            receipts[cellID] = receipt
            if let hardDeleteObserver {
                await hardDeleteObserver(receipt)
            }
        } catch {
            pendingHardDeletes.insert(cellID)
            failures.append("hardDelete \(cellID.rawValue): \(error)")
        }
    }

    private func notifyOwnerIfRelevant(_ event: RuntimeLifecycleEvent) async {
        guard let descriptor = descriptors[event.cellID] else {
            return
        }
        let commands: [String]
        switch event.type {
        case .persistedTTLWarning:
            commands = ["extend", "deleteNow"]
        case .tombstoned:
            commands = ["deleteNow"]
        case .persistedTTLExtended, .hardDeleted:
            commands = []
        default:
            return
        }
        await notifier.notify(
            RuntimeLifecycleOwnerNotice(
                type: event.type,
                resourceID: descriptor.resourceID,
                resourceClass: descriptor.resourceClass,
                ownerIdentityUUID: descriptor.ownerIdentityUUID,
                tick: event.tick,
                deadlineTick: event.deadlineTick,
                availableCommands: commands
            )
        )
    }
}

// MARK: Authority

public enum RuntimeLifecycleAuthorityError: Error, Sendable, Equatable {
    case notRegistered(String)
    case alreadyRegistered(String)
    case notOwner(resourceID: String)
    case hardDeletePending(resourceID: String)
    case invalidExtension
}

/// Runtime lifecycle authority for opted-in resources (P1). Resources
/// registered here are governed only by the runtime lifecycle; the legacy
/// resolver sweep must not track them.
public actor RuntimeLifecycleAuthority {
    public let nodeID: String
    public let registry: RuntimeResourceTTLPolicyRegistry
    private let timeSource: MonotonicTimeSource
    private let manager: RuntimeLifecycleManager
    private let router: RuntimeLifecycleResourceEffectRouter
    private let leaseDurationTicks: UInt64
    private var leases = [RuntimeCellID: RuntimeLease]()

    public init(
        timeSource: MonotonicTimeSource,
        registry: RuntimeResourceTTLPolicyRegistry = .standard(),
        persistence: RuntimeLifecyclePersistenceAdapter,
        notifier: RuntimeLifecycleOwnerNotifier = RuntimeNoopLifecycleOwnerNotifier(),
        metricsSink: RuntimeLifecycleMetricsSink = RuntimeNoopLifecycleMetricsSink(),
        stateStore: RuntimeLifecycleStateStore = InMemoryRuntimeLifecycleStateStore(),
        leaseCoordinator: RuntimeLeaseCoordinator = InMemoryRuntimeLeaseCoordinator(),
        nodeID: String = "local-node",
        leaseDurationTicks: UInt64 = 3_600
    ) {
        let router = RuntimeLifecycleResourceEffectRouter(
            timeSource: timeSource,
            persistence: persistence,
            notifier: notifier
        )
        self.nodeID = nodeID
        self.registry = registry
        self.timeSource = timeSource
        self.router = router
        self.leaseDurationTicks = max(1, leaseDurationTicks)
        self.manager = RuntimeLifecycleManager(
            timeSource: timeSource,
            stateStore: stateStore,
            leaseCoordinator: leaseCoordinator,
            effectSink: router,
            metricsSink: metricsSink
        )
    }

    /// Called after every completed hard delete, e.g. to evict an in-memory copy.
    public func setHardDeleteObserver(_ observer: (@Sendable (RuntimeDeletionReceipt) async -> Void)?) async {
        await router.setHardDeleteObserver(observer)
    }

    /// Registers a persisted resource under runtime authority. Without
    /// `ttlOverrideTicks` the class (or default) TTL applies; there is no way to
    /// register a non-expiring resource here.
    @discardableResult
    public func register(
        _ descriptor: RuntimeResourceDescriptor,
        ttlOverrideTicks: UInt64? = nil
    ) async throws -> RuntimeLifecycleState {
        try FileSystemRuntimeLifecyclePersistenceAdapter.validateIdentifier(descriptor.resourceID)
        let cellID = RuntimeCellID(descriptor.resourceID)
        if await manager.readState(cellID: cellID) != nil {
            throw RuntimeLifecycleAuthorityError.alreadyRegistered(descriptor.resourceID)
        }
        let policy = try registry.runtimePolicy(
            for: descriptor.resourceClass,
            isTestData: descriptor.isTestData,
            ttlOverrideTicks: ttlOverrideTicks
        )
        await router.register(descriptor)
        let (state, lease) = try await manager.registerCell(
            cellID: cellID,
            policy: policy,
            loadedInMemory: false,
            persistedSnapshotAvailable: true,
            nodeID: nodeID,
            leaseDurationTicks: leaseDurationTicks
        )
        leases[cellID] = lease
        return state
    }

    public func isAuthoritative(for resourceID: String) async -> Bool {
        await router.descriptor(for: RuntimeCellID(resourceID)) != nil
    }

    public func state(for resourceID: String) async -> RuntimeLifecycleState? {
        await manager.readState(cellID: RuntimeCellID(resourceID))
    }

    public func receipt(for resourceID: String) async -> RuntimeDeletionReceipt? {
        await router.receipt(for: RuntimeCellID(resourceID))
    }

    public func effectFailures() async -> [String] {
        await router.recordedFailures()
    }

    /// The current lease, for callers that drive the manager directly in tests.
    public func currentLease(for resourceID: String) async throws -> RuntimeLease {
        try await liveLease(for: RuntimeCellID(resourceID))
    }

    /// Owner extends the persisted TTL by `byTicks` from the current deadline.
    @discardableResult
    public func extend(
        resourceID: String,
        byTicks: UInt64,
        requesterIdentityUUID: String
    ) async throws -> RuntimeLifecycleState {
        guard byTicks > 0 else {
            throw RuntimeLifecycleAuthorityError.invalidExtension
        }
        let cellID = try await authorizeOwner(resourceID: resourceID, requesterIdentityUUID: requesterIdentityUUID)
        let lease = try await liveLease(for: cellID)
        return try await manager.applyWarningCommand(
            cellID: cellID,
            lease: lease,
            command: .extendPersistedTTL(byTicks: byTicks)
        )
    }

    /// Owner deletes their resource now (G4). Tombstone is written first, then
    /// data, snapshots and backups are hard deleted in the same call. Returns
    /// the receipt, or throws `hardDeletePending` if storage failed (the delete
    /// is retried by `processDue()`).
    public func deleteNow(
        resourceID: String,
        requesterIdentityUUID: String
    ) async throws -> RuntimeDeletionReceipt {
        let cellID = try await authorizeOwner(resourceID: resourceID, requesterIdentityUUID: requesterIdentityUUID)
        if let receipt = await router.receipt(for: cellID) {
            return receipt
        }
        let lease = try await liveLease(for: cellID)
        await router.markOwnerRequested(cellID)
        _ = try await manager.applyWarningCommand(cellID: cellID, lease: lease, command: .deleteNow)
        try await processDue()
        guard let receipt = await router.receipt(for: cellID) else {
            throw RuntimeLifecycleAuthorityError.hardDeletePending(resourceID: resourceID)
        }
        return receipt
    }

    /// Process due warnings/expiries/hard deletes and retry failed effects.
    /// Safe to call repeatedly.
    public func processDue() async throws {
        await router.retryPending()
        try await manager.processDueExpiries()
    }

    private func authorizeOwner(resourceID: String, requesterIdentityUUID: String) async throws -> RuntimeCellID {
        let cellID = RuntimeCellID(resourceID)
        guard let descriptor = await router.descriptor(for: cellID) else {
            throw RuntimeLifecycleAuthorityError.notRegistered(resourceID)
        }
        guard !requesterIdentityUUID.isEmpty,
              descriptor.ownerIdentityUUID == requesterIdentityUUID else {
            throw RuntimeLifecycleAuthorityError.notOwner(resourceID: resourceID)
        }
        return cellID
    }

    /// Renews (never re-acquires) the lease so the fencing token, and with it
    /// every scheduled wheel entry, stays valid.
    private func liveLease(for cellID: RuntimeCellID) async throws -> RuntimeLease {
        guard let lease = leases[cellID] else {
            throw RuntimeLifecycleAuthorityError.notRegistered(cellID.rawValue)
        }
        let renewed = try await manager.renewLease(lease, leaseDurationTicks: leaseDurationTicks)
        leases[cellID] = renewed
        return renewed
    }
}

/// Opt-in binding from a named resolve to a runtime-authority resource class.
public struct RuntimeLifecycleAuthorityResolveBinding: Sendable, Equatable {
    public var resourceClass: String
    public var isTestData: Bool
    public var ttlOverrideTicks: UInt64?

    public init(resourceClass: String, isTestData: Bool = false, ttlOverrideTicks: UInt64? = nil) {
        self.resourceClass = resourceClass
        self.isTestData = isTestData
        self.ttlOverrideTicks = ttlOverrideTicks
    }
}
