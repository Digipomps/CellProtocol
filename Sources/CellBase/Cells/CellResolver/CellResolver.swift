// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CombineHelpers

#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif


/*
 Resolver scopes
 Register by uuid - must be initialised or serialized instance
 Register by name - named template - new instance for every request
 Register by name - named scoped template - new instance for each identity (or condition for scope)
  
 */

// Move this to a more sutable location
protocol CellResolverProtocolExt : CellResolverProtocol {
    func identityForCellReference(_ ref: CellReference)
    func cellForReference(_ ref: CellReference)
}

enum CellResolverError: Error {
    case noDefaultResolver
    case cellNotFound
    case identityNotFound
    case bridgeSetupError
    case unsupportedUrlScheme
    case failedToCreateUrlEndpoint(from: String)
    case insecureWebSocketNotAllowed(endpoint: String)
    case missingRemoteCellHostRegistration(host: String)
    case invalidRemoteCellReference(endpoint: String)
}

public enum CellSetupError: Error {
    case missingPersistanceUtility
}

public struct RemoteCellHostRoute: Sendable {
    public enum SchemePreference: Sendable {
        case automatic
        case ws
        case wss
    }

    public enum PathLayout: Sendable {
        case endpointThenPublisherUUID
        case publisherUUIDThenEndpoint
    }

    public var websocketEndpoint: String
    public var schemePreference: SchemePreference
    public var pathLayout: PathLayout

    public init(
        websocketEndpoint: String = "publishersws",
        schemePreference: SchemePreference = .automatic,
        pathLayout: PathLayout = .endpointThenPublisherUUID
    ) {
        self.websocketEndpoint = websocketEndpoint
        self.schemePreference = schemePreference
        self.pathLayout = pathLayout
    }
}

//Remember to keep track of instantiated Cell in local address space
public class CellResolver: CellResolverProtocol {
    var namedCellResolves = [String : CellResolve]()
    var loadCellFacilitators = [String : CellClusterFacilitator]()
    var resolverEmitter: FlowElementPusherCell? = nil
    private var resolverEmittersByIdentityUUID = [String: FlowElementPusherCell]()
    var transports = [String : BridgeTransportProtocol.Type]() // TODO: move this to auditor?
    private var remoteCellHostRoutes = [String : RemoteCellHostRoute]()
    private var remoteBridgeCache = [String : Emit]()
    private var pendingRemoteBridgeTasks = [String : Task<Emit, Error>]()
    var auditor = ResolverAuditor()
    
    var connectCellCancellables = [String : AnyCancellable]() // used by push item
    private let stateLock = NSLock()
    private let lifecycleTracker = ResolverLifecycleTracker()
    private var lifecycleSweepTask: Task<Void, Never>?
    private var runtimeShadowTask: Task<Void, Never>?
    private var runtimeShadowManager: RuntimeLifecycleManager?
    private var runtimeShadowTimeSource: MonotonicTimeSource?
    private var runtimeShadowEnabled = false
    private var runtimeShadowNodeID = "local-node"
    private var runtimeShadowLeaseDurationTicks: UInt64 = 300
    private var runtimeShadowTickDurationNanoseconds: UInt64 = 1_000_000_000
    public weak var lifecycleEventResponder: CellLifecycleEventResponder?
    public var lifecycleSweepInterval: TimeInterval = 1.0
    public var runtimeShadowSweepInterval: TimeInterval = 0.5
    
    public static let sharedInstance = CellResolver()
    public var tcUtility: TypedCellUtility?
    
    public struct Config {
        public let endpoint: String
        public let identity: Identity
    }

    private init() {
        startLifecycleSweepLoop()
    }

    deinit {
        lifecycleSweepTask?.cancel()
        runtimeShadowTask?.cancel()
    }

    private func withStateLock<T>(_ block: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try block()
    }
    
    public func setResolverEmitter(_ emitter: FlowElementPusherCell, requester: Identity) async  throws {
        // validate permissions
        withStateLock {
            self.resolverEmitter = emitter
            resolverEmittersByIdentityUUID[requester.uuid] = emitter
            resolverEmittersByIdentityUUID[emitter.owner.uuid] = emitter
        }
        if runtimeShadowEnabled {
            enableRuntimeLifecycleShadowMode(
                nodeID: runtimeShadowNodeID,
                resolverEmitter: emitter,
                tickDurationNanoseconds: runtimeShadowTickDurationNanoseconds,
                processingInterval: runtimeShadowSweepInterval,
                leaseDurationTicks: runtimeShadowLeaseDurationTicks
            )
        }
    }

    public func enableRuntimeLifecycleShadowMode(
        nodeID: String,
        resolverEmitter: FlowElementPusherCell? = nil,
        tickDurationNanoseconds: UInt64 = 1_000_000_000,
        processingInterval: TimeInterval = 0.5,
        leaseDurationTicks: UInt64 = 300
    ) {
        runtimeShadowEnabled = true
        runtimeShadowNodeID = nodeID.isEmpty ? "local-node" : nodeID
        runtimeShadowTickDurationNanoseconds = max(1, tickDurationNanoseconds)
        runtimeShadowSweepInterval = max(0.1, processingInterval)
        runtimeShadowLeaseDurationTicks = max(1, leaseDurationTicks)

        let fallbackEmitter = withStateLock { self.resolverEmitter }
        let selectedEmitter = resolverEmitter ?? fallbackEmitter
        let effectSink: RuntimeLifecycleEffectSink
        let metricsSink: RuntimeLifecycleMetricsSink
        if let selectedEmitter {
            effectSink = RuntimeLifecycleFlowEventSink(emitter: selectedEmitter)
            metricsSink = RuntimeLifecycleFlowMetricsSink(emitter: selectedEmitter)
        } else {
            effectSink = RuntimeNoopLifecycleEffectSink()
            metricsSink = RuntimeNoopLifecycleMetricsSink()
        }

        let timeSource = SystemMonotonicTimeSource(tickDurationNanoseconds: runtimeShadowTickDurationNanoseconds)
        runtimeShadowTimeSource = timeSource
        runtimeShadowManager = RuntimeLifecycleManager(
            timeSource: timeSource,
            effectSink: effectSink,
            metricsSink: metricsSink
        )
        startRuntimeShadowLoop()
    }

    public func disableRuntimeLifecycleShadowMode() {
        runtimeShadowEnabled = false
        runtimeShadowTask?.cancel()
        runtimeShadowTask = nil
        runtimeShadowManager = nil
        runtimeShadowTimeSource = nil
    }

    public func setCellLifecycleEventResponder(_ responder: CellLifecycleEventResponder?) {
        self.lifecycleEventResponder = responder
    }

    public func extendCellTTL(uuid: String, by seconds: TimeInterval) async -> Bool {
        await lifecycleTracker.extendMemoryTTL(uuid: uuid, by: seconds)
    }

    public func extendPersistedCellTTL(uuid: String, by seconds: TimeInterval) async -> Bool {
        await lifecycleTracker.extendPersistedDataTTL(uuid: uuid, by: seconds)
    }

    public func performLifecycleSweepNow() async {
        await performLifecycleSweep()
    }

    private func startLifecycleSweepLoop() {
        lifecycleSweepTask?.cancel()
        lifecycleSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let interval = max(0.2, self.lifecycleSweepInterval)
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await self.performLifecycleSweep()
            }
        }
    }

    private func startRuntimeShadowLoop() {
        runtimeShadowTask?.cancel()
        runtimeShadowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let interval = max(0.1, self.runtimeShadowSweepInterval)
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard self.runtimeShadowEnabled else { continue }
                guard let manager = self.runtimeShadowManager else { continue }
                do {
                    try await manager.processDueExpiries()
                } catch {
                    continue
                }
            }
        }
    }

    private func performLifecycleSweep() async {
        let dueEvents = await lifecycleTracker.dueEvents()
        for dueEvent in dueEvents {
            await handleLifecycleDueEvent(dueEvent)
        }
    }

    private func handleLifecycleDueEvent(_ dueEvent: CellLifecycleDueEvent) async {
        switch dueEvent {
        case .memoryWarning(let record, let remaining):
            let event = CellLifecycleEvent(
                type: .memoryTTLWarning,
                uuid: record.uuid,
                endpoint: record.endpoint,
                identityUUID: record.identityUUID,
                recipientIdentityUUIDs: record.alertRecipientIdentityUUIDs,
                secondsRemaining: remaining,
                memoryTTL: record.policy.memoryTTL,
                persistedDataTTL: record.policy.persistedDataTTL
            )
            let response = await resolveLifecycleResponse(for: event)
            switch response {
            case .extendMemoryTTL(let seconds):
                _ = await lifecycleTracker.extendMemoryTTL(uuid: record.uuid, by: seconds)
            case .extendPersistedDataTTL(let seconds):
                _ = await lifecycleTracker.extendPersistedDataTTL(uuid: record.uuid, by: seconds)
            case .persistAndUnload:
                await evictCellFromMemory(record: record, persistBeforeUnload: true)
            case .unloadFromMemory:
                await evictCellFromMemory(record: record, persistBeforeUnload: false)
            default:
                break
            }
        case .memoryExpired(let record):
            let event = CellLifecycleEvent(
                type: .memoryTTLExpired,
                uuid: record.uuid,
                endpoint: record.endpoint,
                identityUUID: record.identityUUID,
                recipientIdentityUUIDs: record.alertRecipientIdentityUUIDs,
                secondsRemaining: 0,
                memoryTTL: record.policy.memoryTTL,
                persistedDataTTL: record.policy.persistedDataTTL
            )
            let response = await resolveLifecycleResponse(for: event)
            switch response {
            case .extendMemoryTTL(let seconds):
                _ = await lifecycleTracker.extendMemoryTTL(uuid: record.uuid, by: seconds)
            case .persistAndUnload:
                await evictCellFromMemory(record: record, persistBeforeUnload: true)
            case .unloadFromMemory:
                await evictCellFromMemory(record: record, persistBeforeUnload: false)
            case .useDefaultAction:
                switch record.policy.memoryExpiryAction {
                case .notifyOnly:
                    break
                case .unloadFromMemory:
                    await evictCellFromMemory(record: record, persistBeforeUnload: false)
                case .persistAndUnload:
                    await evictCellFromMemory(record: record, persistBeforeUnload: true)
                }
            default:
                break
            }
        case .persistedDataExpired(let record):
            let event = CellLifecycleEvent(
                type: .persistedDataTTLExpired,
                uuid: record.uuid,
                endpoint: record.endpoint,
                identityUUID: record.identityUUID,
                recipientIdentityUUIDs: record.alertRecipientIdentityUUIDs,
                secondsRemaining: 0,
                persistedDataTTL: record.persistedDataTTL
            )
            let response = await resolveLifecycleResponse(for: event)
            let shouldDelete: Bool
            switch response {
            case .extendPersistedDataTTL(let seconds):
                _ = await lifecycleTracker.extendPersistedDataTTL(uuid: record.uuid, by: seconds)
                shouldDelete = false
            case .ignore:
                shouldDelete = false
            case .useDefaultAction, .deletePersistedData:
                shouldDelete = true
            default:
                shouldDelete = false
            }
            if shouldDelete {
                let deleted = deletePersistedCellData(uuid: record.uuid)
                if deleted {
                    await lifecycleTracker.untrackPersistedCell(uuid: record.uuid)
                    await syncRuntimeShadowDeleteIfNeeded(uuid: record.uuid)
                    publishLifecycleEvent(
                        CellLifecycleEvent(
                            type: .persistedDataDeleted,
                            uuid: record.uuid,
                            endpoint: record.endpoint,
                            identityUUID: record.identityUUID,
                            recipientIdentityUUIDs: record.alertRecipientIdentityUUIDs
                        )
                    )
                }
            }
        }
    }

    private func resolveLifecycleResponse(for event: CellLifecycleEvent) async -> CellLifecycleEventResponse {
        publishLifecycleEvent(event)
        guard let responder = lifecycleEventResponder else {
            return .useDefaultAction
        }
        return await responder.resolver(self, didReceive: event)
    }

    private func publishLifecycleEvent(_ event: CellLifecycleEvent) {
        let emitters = lifecycleEmitters(for: event.recipientIdentityUUIDs)
        guard !emitters.isEmpty else {
            return
        }
        var payload: Object = [
            "type": .string(event.type.rawValue),
            "uuid": .string(event.uuid),
            "timestamp": .float(event.timestamp.timeIntervalSince1970)
        ]
        if let endpoint = event.endpoint {
            payload["endpoint"] = .string(endpoint)
        }
        if let identityUUID = event.identityUUID {
            payload["identityUUID"] = .string(identityUUID)
        }
        if let secondsRemaining = event.secondsRemaining {
            payload["secondsRemaining"] = .float(secondsRemaining)
        }
        if let memoryTTL = event.memoryTTL {
            payload["memoryTTL"] = .float(memoryTTL)
        }
        if let persistedDataTTL = event.persistedDataTTL {
            payload["persistedDataTTL"] = .float(persistedDataTTL)
        }
        if let recipientIdentityUUIDs = event.recipientIdentityUUIDs {
            payload["recipientIdentityUUIDs"] = .list(recipientIdentityUUIDs.map { .string($0) })
        }
        var flowElement = FlowElement(
            title: "Resolver lifecycle event",
            content: .object(payload),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "lifecycle"
        for emitter in emitters {
            emitter.pushFlowElement(flowElement, requester: emitter.owner)
        }
    }

    private func lifecycleEmitters(for recipientIdentityUUIDs: [String]?) -> [FlowElementPusherCell] {
        let (snapshotResolverEmitter, snapshotEmittersByIdentityUUID) = withStateLock {
            (resolverEmitter, resolverEmittersByIdentityUUID)
        }

        guard let recipientIdentityUUIDs, !recipientIdentityUUIDs.isEmpty else {
            guard let snapshotResolverEmitter else {
                return []
            }
            return [snapshotResolverEmitter]
        }

        var emittersByReference = [ObjectIdentifier: FlowElementPusherCell]()
        for identityUUID in recipientIdentityUUIDs {
            if let emitter = snapshotEmittersByIdentityUUID[identityUUID] {
                emittersByReference[ObjectIdentifier(emitter)] = emitter
            }
        }

        if let snapshotResolverEmitter,
           recipientIdentityUUIDs.contains(snapshotResolverEmitter.owner.uuid) {
            emittersByReference[ObjectIdentifier(snapshotResolverEmitter)] = snapshotResolverEmitter
        }

        return Array(emittersByReference.values)
    }

    private func evictCellFromMemory(record: TrackedCellLifecycleRecord, persistBeforeUnload: Bool) async {
        let cell = await auditor.loadCellInstance(forUUID: record.uuid)
        if persistBeforeUnload, let cell {
            await persistCellIfPossible(
                cell,
                preferredTypeName: record.cellTypeName,
                fallbackOwnerIdentityUUID: record.identityUUID
            )
        }
        await auditor.evictCellInstance(uuid: record.uuid)
        await lifecycleTracker.untrackCell(uuid: record.uuid)
        if record.persistancy == .persistant {
            await lifecycleTracker.touchPersistedCell(uuid: record.uuid)
        }
        await syncRuntimeShadowUnloadIfNeeded(
            uuid: record.uuid,
            persistedSnapshotAvailable: record.persistancy == .persistant || persistBeforeUnload
        )
        publishLifecycleEvent(
            CellLifecycleEvent(
                type: .memoryEvicted,
                uuid: record.uuid,
                endpoint: record.endpoint,
                identityUUID: record.identityUUID,
                recipientIdentityUUIDs: record.alertRecipientIdentityUUIDs
            )
        )
    }

    private func persistCellIfPossible(
        _ cell: Emit,
        preferredTypeName: String? = nil,
        fallbackOwnerIdentityUUID: String? = nil
    ) async {
        guard let tcUtility = self.tcUtility,
              let codableEmit = cell as? Codable else {
            return
        }
        let typeName = preferredTypeName ?? typeNameFromRuntime(type(of: cell))
        await ensurePersistedCellMasterKeyLoaded()
        let writeOptions = persistenceWriteOptions(
            for: cell,
            fallbackOwnerIdentityUUID: fallbackOwnerIdentityUUID
        )
        tcUtility.storeAsTypedCell(
            cellName: typeName,
            cell: codableEmit,
            uuid: cell.uuid,
            options: writeOptions
        )
        await lifecycleTracker.touchPersistedCell(uuid: cell.uuid)
    }

    private func deletePersistedCellData(uuid: String) -> Bool {
        guard let documentRootPath = CellBase.documentRootPath else {
            return false
        }
        let fileManager = FileManager.default
        let documentRootURL = URL(fileURLWithPath: documentRootPath)
        let candidates = [
            documentRootURL.appendingPathComponent(uuid),
            documentRootURL.appendingPathComponent("CellsContainer").appendingPathComponent(uuid)
        ]

        var didDelete = false
        var visited = Set<String>()
        for candidate in candidates {
            if visited.contains(candidate.path) {
                continue
            }
            visited.insert(candidate.path)
            if fileManager.fileExists(atPath: candidate.path) {
                do {
                    try fileManager.removeItem(at: candidate)
                    didDelete = true
                } catch {
                    print("Failed deleting persisted cell data at: \(candidate.path) error: \(error)")
                }
            }
        }
        return didDelete
    }

    private func applyLifecycleTrackingIfNeeded(
        cell: Emit,
        resolve: CellResolve?,
        endpoint: String?,
        identity: Identity?,
        typeName: String? = nil
    ) async {
        guard let resolve,
              let policy = resolve.lifecyclePolicy else {
            return
        }
        let runtimeTypeName = typeName ?? typeNameFromRuntime(type(of: cell))
        let alertRecipients = lifecycleAlertRecipients(
            for: cell,
            fallbackIdentityUUID: identity?.uuid
        )
        let fundingMetadata = lifecycleFundingMetadata(for: cell)
        await lifecycleTracker.trackCell(
            uuid: cell.uuid,
            endpoint: endpoint,
            identityUUID: identity?.uuid,
            persistancy: cell.persistancy,
            cellTypeName: runtimeTypeName,
            alertRecipientIdentityUUIDs: alertRecipients,
            deleteIfUnfunded: fundingMetadata.deleteIfUnfunded,
            fundedUntilTick: fundingMetadata.fundedUntilTick,
            fundingEnforced: fundingMetadata.fundingEnforced,
            policy: policy
        )
        await syncRuntimeShadowLifecycleIfNeeded(
            cell: cell,
            policy: policy,
            loadedInMemory: true
        )
    }

    private func lifecycleAlertRecipients(
        for cell: Emit,
        fallbackIdentityUUID: String?
    ) -> [String] {
        var recipients = Set<String>()
        let agreement = cell.agreementTemplate

        let ownerUUID = agreement.owner.uuid
        if !ownerUUID.isEmpty {
            recipients.insert(ownerUUID)
        }
        if let fallbackIdentityUUID, !fallbackIdentityUUID.isEmpty {
            recipients.insert(fallbackIdentityUUID)
        }

        for condition in agreement.conditions {
            guard let accessCondition = condition as? LifecycleAlertAccessCondition else {
                continue
            }
            for allowedIdentityUUID in accessCondition.allowedIdentityUUIDs where !allowedIdentityUUID.isEmpty {
                recipients.insert(allowedIdentityUUID)
            }
            if accessCondition.includeSignatories {
                for signatory in agreement.signatories where !signatory.uuid.isEmpty {
                    recipients.insert(signatory.uuid)
                }
            }
        }

        return recipients.sorted()
    }

    private func lifecycleFundingMetadata(for cell: Emit) -> (
        deleteIfUnfunded: Bool,
        fundedUntilTick: UInt64?,
        fundingEnforced: Bool
    ) {
        var fundingCondition: LifecycleFundingCondition?
        var coldStorageCondition: ColdStorageCondition?
        for condition in cell.agreementTemplate.conditions {
            if let funding = condition as? LifecycleFundingCondition {
                fundingCondition = funding
                continue
            }
            if let coldStorage = condition as? ColdStorageCondition {
                coldStorageCondition = coldStorage
            }
        }

        guard let fundingCondition else {
            return (deleteIfUnfunded: false, fundedUntilTick: nil, fundingEnforced: false)
        }

        return (
            deleteIfUnfunded: coldStorageCondition?.deleteIfUnfunded ?? true,
            fundedUntilTick: fundingCondition.fundedUntilTick,
            fundingEnforced: true
        )
    }

    private func touchLifecycle(for cell: Emit) async {
        await lifecycleTracker.touchCell(uuid: cell.uuid)
        if cell.persistancy == .persistant {
            await lifecycleTracker.touchPersistedCell(uuid: cell.uuid)
        }
    }

    private func syncRuntimeShadowLifecycleIfNeeded(
        cell: Emit,
        policy: CellLifecyclePolicy,
        loadedInMemory: Bool
    ) async {
        guard runtimeShadowEnabled else {
            return
        }
        guard let manager = runtimeShadowManager else {
            return
        }
        guard let runtimePolicy = runtimeLifecyclePolicy(from: policy) else {
            return
        }

        let cellID = RuntimeCellID(cell.uuid)
        if let _ = await manager.readState(cellID: cellID) {
            do {
                let lease = try await manager.acquireLease(
                    cellID: cellID,
                    nodeID: runtimeShadowNodeID,
                    leaseDurationTicks: runtimeShadowLeaseDurationTicks
                )
                if loadedInMemory {
                    _ = try await manager.touch(cellID: cellID, lease: lease)
                } else {
                    _ = try await manager.unloadFromMemory(cellID: cellID, lease: lease)
                }
            } catch {
                return
            }
            return
        }

        do {
            _ = try await manager.registerCell(
                cellID: cellID,
                policy: runtimePolicy,
                loadedInMemory: loadedInMemory,
                persistedSnapshotAvailable: cell.persistancy == .persistant,
                nodeID: runtimeShadowNodeID,
                leaseDurationTicks: runtimeShadowLeaseDurationTicks
            )
        } catch {
            return
        }
    }

    private func runtimeLifecyclePolicy(from policy: CellLifecyclePolicy) -> RuntimeLifecyclePolicy? {
        let memoryTTL = policy.memoryTTL ?? 0
        let persistedTTL = policy.persistedDataTTL
        if memoryTTL <= 0 && (persistedTTL ?? 0) <= 0 {
            return .nonExpiring
        }

        let hasMemoryTTL = memoryTTL > 0
        let memoryTicks: UInt64 = hasMemoryTTL
            ? max(1, UInt64(ceil(memoryTTL)))
            : (UInt64.max / 4)
        let warningTicks: UInt64 = hasMemoryTTL
            ? UInt64(ceil(max(0, policy.warningLeadTime)))
            : 0
        let persistedTicks: UInt64?
        if let persistedTTL, persistedTTL > 0 {
            persistedTicks = UInt64(ceil(persistedTTL))
        } else {
            persistedTicks = nil
        }

        let memoryExpiryAction: RuntimeMemoryExpiryAction
        switch policy.memoryExpiryAction {
        case .notifyOnly:
            memoryExpiryAction = .notifyOnly
        case .unloadFromMemory:
            memoryExpiryAction = .unload
        case .persistAndUnload:
            memoryExpiryAction = .persistAndUnload
        }
        return .expiring(
            memoryTTLTicks: memoryTicks,
            memoryWarningLeadTicks: warningTicks,
            persistedDataTTLTicks: persistedTicks,
            tombstoneGraceTicks: 0,
            memoryExpiryAction: memoryExpiryAction
        )
    }

    private func runtimeLifecycleNowTick() -> UInt64 {
        if let timeSource = runtimeShadowTimeSource {
            return timeSource.nowTick()
        }
        return 0
    }

    private func persistenceWriteOptions(for cell: Emit, fallbackOwnerIdentityUUID: String?) -> CellStorageWriteOptions {
        let ownerUUID = fallbackOwnerIdentityUUID ?? cell.agreementTemplate.owner.uuid
        let nowTick = runtimeLifecycleNowTick()
        let encryptedAtRestRequired: Bool
        if let resolution = try? cell.agreementTemplate.runtimeLifecycleResolution(nowTick: nowTick) {
            encryptedAtRestRequired = resolution.encryptedAtRestRequired
        } else {
            encryptedAtRestRequired = true
        }
        return CellStorageWriteOptions(
            ownerIdentityUUID: ownerUUID,
            encryptedAtRestRequired: encryptedAtRestRequired
        )
    }

    private func ensurePersistedCellMasterKeyLoaded() async {
        if CellBase.persistedCellMasterKey != nil {
            return
        }
        let secretTag = "cell.persistence.master.v1"

        if let scopedSecretProvider = CellBase.defaultScopedSecretProvider,
           let seedData = try? await scopedSecretProvider.scopedSecretData(tag: secretTag, minimumLength: 32) {
            CellBase.configurePersistedCellMasterKey(seedData: seedData)
            return
        }

        if let vaultSecretProvider = CellBase.defaultIdentityVault as? ScopedSecretProviderProtocol,
           let seedData = try? await vaultSecretProvider.scopedSecretData(tag: secretTag, minimumLength: 32) {
            CellBase.configurePersistedCellMasterKey(seedData: seedData)
            return
        }

        guard let identityVault = CellBase.defaultIdentityVault else {
            return
        }
        if let tuple = try? await identityVault.aquireKeyForTag(tag: secretTag) {
            let seedData = Data("\(tuple.key).\(tuple.iv)".utf8)
            CellBase.configurePersistedCellMasterKey(seedData: seedData)
        }
    }

    private func syncRuntimeShadowUnloadIfNeeded(uuid: String, persistedSnapshotAvailable: Bool) async {
        guard runtimeShadowEnabled else {
            return
        }
        guard let manager = runtimeShadowManager else {
            return
        }
        let cellID = RuntimeCellID(uuid)
        guard await manager.readState(cellID: cellID) != nil else {
            return
        }
        do {
            let lease = try await manager.acquireLease(
                cellID: cellID,
                nodeID: runtimeShadowNodeID,
                leaseDurationTicks: runtimeShadowLeaseDurationTicks
            )
            if persistedSnapshotAvailable {
                _ = try await manager.applyWarningCommand(
                    cellID: cellID,
                    lease: lease,
                    command: .persistAndUnload
                )
            } else {
                _ = try await manager.unloadFromMemory(cellID: cellID, lease: lease)
            }
        } catch {
            return
        }
    }

    private func syncRuntimeShadowDeleteIfNeeded(uuid: String) async {
        guard runtimeShadowEnabled else {
            return
        }
        guard let manager = runtimeShadowManager else {
            return
        }
        let cellID = RuntimeCellID(uuid)
        guard await manager.readState(cellID: cellID) != nil else {
            return
        }
        do {
            let lease = try await manager.acquireLease(
                cellID: cellID,
                nodeID: runtimeShadowNodeID,
                leaseDurationTicks: runtimeShadowLeaseDurationTicks
            )
            _ = try await manager.applyWarningCommand(
                cellID: cellID,
                lease: lease,
                command: .delete
            )
        } catch {
            return
        }
    }

    private func typeNameFromRuntime(_ type: Any.Type) -> String {
        String(String(describing: type).split(separator: ".").last ?? "err")
    }
    
    public func loadCell(from cellConfiguration: CellConfiguration, into sourceCellClient: Absorb, requester: Identity ) async throws -> [Emit] {
        
//        print("Auditor state1: \(await auditor.auditorState())")
        let facilitator = CellClusterFacilitator()
        let configurationName = cellConfiguration.name
        withStateLock {
            loadCellFacilitators[configurationName] = facilitator
        }
        defer {
            withStateLock {
                loadCellFacilitators[configurationName] = nil
            }
        }
        
        if let references = cellConfiguration.cellReferences {
            for currentReference in references {
                try await loadCell(from: currentReference, into: sourceCellClient, using: facilitator, requester: requester)
            }
        }
//        print("Auditor state2   : \(await auditor.auditorState())")
        return await facilitator.all
    }
   
    func identity(for requester: Identity?, or identityDomain: String) async -> Identity {
        if requester == nil {
            if let tmpIdentity = await CellBase.defaultIdentityVault?.identity(for: identityDomain, makeNewIfNotFound: true) {
                return tmpIdentity
            }
        }
        return requester!
    }
    
    func loadCell(from reference: CellReference, into source: Absorb, using facilitator: CellClusterFacilitator, requester: Identity) async throws {
        do {
            let target = try await self.cellAtEndpoint(endpoint: reference.endpoint, requester: requester)
            CellBase.diagnosticLog("Loaded cell at endpoint \(reference.endpoint)", domain: .resolver)
            try await connectToLoadedCell(target: target, into: source, reference: reference, facilitator: facilitator, requester: requester)
        } catch {
            print("loadCell from reference failed with error: \(error) reference: \(reference)")
            source.detach(label: reference.label, requester: requester)
            throw error
        }
    }
    
    private func connectToLoadedCell(target: Emit, into source: Absorb, reference: CellReference, facilitator: CellClusterFacilitator,requester: Identity?) async throws  {
        let identity = await self.identity(for: requester, or: target.identityDomain)
        // Only try to connect if target is not already connected
        if await facilitator.loadConnectedCellEmitter(for: reference.id) == nil {
            let connectState = try await source.attach(emitter: target, label: reference.label, requester: identity)
            if connectState == .connected {
                // recursivly connect and subscribe if possible
                await facilitator.storeConnectedCellEmitter(publisher: target, for: reference.id)
                if reference.subscribeFeed {
                    try await source.absorbFlow(label: reference.label, requester: identity)
                    
                    // Should set value be sent after of before feed? hmmm...
                    try await lookupKeysAndValues(target: target, reference: reference, requester: identity)
                }
                // load subscriptions
                try await loadSubscriptions(target: target, reference: reference, facilitator: facilitator, requester: identity)
            } else {
                CellBase.diagnosticLog("Skipping subscription load because connectState=\(connectState)", domain: .resolver)
            }
        } else {
            CellBase.diagnosticLog("Target already connected; skipping duplicate load", domain: .resolver)
        }
    }
    
    private func lookupKeysAndValues(target: Emit, reference: CellReference, requester: Identity) async throws {
        CellBase.diagnosticLog("lookupKeysAndValues endpoint=\(reference.endpoint)", domain: .resolver)
        if let meddleTarget = target as? Meddle {
//            if let keysAndValues = reference.setKeysAndValues {
            var targetValue: ValueType?
                for currentKeyValue in reference.setKeysAndValues {
                    if let value = currentKeyValue.value {
                        CellBase.diagnosticLog("Setting key=\(currentKeyValue.key) with explicit value", domain: .resolver)
                        targetValue = try await meddleTarget.set(keypath: currentKeyValue.key, value: value, requester: requester)
                    } else {
                        CellBase.diagnosticLog("Fetching key=\(currentKeyValue.key) for assignment", domain: .resolver)
                        targetValue = try await meddleTarget.get(keypath: currentKeyValue.key, requester: requester)
                    }
                    if let target = currentKeyValue.target,
                       let targetValue {
                        if target.hasPrefix("cell://"),
                           let targetURL = URL(string: target)
                        {
                            _ = try await set(value: targetValue, into: targetURL, requester: requester)
                            
                        } else {
                            
                            _ = try await meddleTarget.set(keypath: target, value: targetValue, requester: requester)
                        }
                    }
                }
//            }
        }
    }

    // These methods may be elevated to become part of resolver protocol ...or another utility protocol??
    public func get(from url: URL, requester: Identity) async throws -> ValueType? {
        // cell://<host>/Purposes/state
        // cell://<host>/<cell endpoint>/<keypath>
        let (cellURL, keypath) = splitCellURL(cellURL: url)
        
        guard let keypath = keypath,
            let target = try await emitCellAtCellEndpoint(endpointUrl: cellURL, requester: requester) as? Meddle else {
            // throw something
            return nil
        }
        let resultValue = try await target.get(keypath: keypath, requester: requester)
        
        let resultDescription = (try? resultValue.jsonString()) ?? "No result"
        CellBase.diagnosticLog(
            "Resolver get \(url.absoluteString) -> \(resultDescription)",
            domain: .resolver
        )
        
        return resultValue
    }
    
    public func set(value: ValueType, into url: URL, requester: Identity) async throws -> ValueType? {
        // cell:///Purposes/state
        let encodedValue = try value.jsonString()
        CellBase.diagnosticLog(
            "Resolver set \(url.absoluteString) value=\(encodedValue)",
            domain: .resolver
        )
        let (cellURL, keypath) = splitCellURL(cellURL: url)
        
        guard let keypath = keypath,
              let target = try await emitCellAtCellEndpoint(endpointUrl: cellURL, requester: requester) as? Meddle else {
            // throw something
            return nil
        }
        let resultValue = try await target.set(keypath: keypath, value: value, requester: requester)
        let resultDescription: String
        if let resultValue {
            resultDescription = (try? resultValue.jsonString()) ?? "Unencodable result"
        } else {
            resultDescription = "No result"
        }
        CellBase.diagnosticLog(
            "Resolver set \(url.absoluteString) result=\(resultDescription)",
            domain: .resolver
        )
        return resultValue
    }
    
    private func splitCellURL(cellURL: URL) -> (URL, String?) {
        var responseURL = cellURL
        var keypath: String?
        let pathArray = cellURL.pathComponents
        if pathArray.count > 1 {
            keypath = pathArray.last
            responseURL = cellURL.deletingLastPathComponent()
        }
        CellBase.diagnosticLog("splitCellURL responseURL=\(responseURL) keypath=\(keypath ?? "-")", domain: .resolver)
        return (responseURL, keypath)
    }
    
    private func loadSubscriptions(target: Emit, reference: CellReference, facilitator: CellClusterFacilitator, requester: Identity ) async throws {
        if let targetClient = target as? Absorb /*, let subscriptions = reference.subscriptions */ {
            
            for currentReference in reference.subscriptions {
                CellBase.diagnosticLog(
                    "Loading subscription \(currentReference.endpoint) into \(targetClient.self)",
                    domain: .resolver
                )
                try await loadCell(from: currentReference, into: targetClient, using: facilitator, requester: requester)
            }
        }
    }
    
    func pushFlowElement(_ flowElement: FlowElement, into absorber: Absorb, requester: Identity) async {
        let pushCell = FlowElementPusherCell(owner: requester)
        do {
            let connectState = try await absorber.attach(emitter: pushCell, label: "push", requester: requester)
            if connectState == .connected {
                try await absorber.absorbFlow(label: "push", requester: requester)
                pushCell.feedPublisher.send(flowElement)
                pushCell.feedPublisher.send(completion: .finished)
            }
        } catch {
            pushCell.feedPublisher.send(completion: .failure(error))
        }
    }
    
    // This is probably the wrong way to do it... maybe just use the endpoint in a hashtable?
    func cellUUID(from endpointString: String) -> String {
        let pathComponents = endpointString.split(separator: "/")
        
        let uuid = pathComponents.last! as String.SubSequence
        
        
        return String(uuid)
    }
    
    
    public func cellAtEndpoint(endpoint: String, requester: Identity) async throws -> Emit {
        guard let endpointUrl = URL(string: endpoint) else {
            throw CellResolverError.failedToCreateUrlEndpoint(from: endpoint)
        }
        return try await self.emitCellAtEndpoint(
            endpointUrl: endpointUrl,
            endpoint: endpoint,
            requester: requester
        )
    }
    
    public func emitCellAtEndpoint(endpointUrl: URL, endpoint:String, requester: Identity) async throws -> Emit {
        switch endpointUrl.scheme {
        case "ws", "wss":
            return try await emitCellAtWSEndpoint(endpoint: endpoint, requester: requester) // TODO: Consider using only url
        case "cell":
            return try await emitCellAtCellEndpoint(endpointUrl: endpointUrl, requester: requester)
        default:
            throw CellResolverError.unsupportedUrlScheme
        }
    }
    
    private func emitCellAtWSEndpoint(endpoint: String, requester: Identity) async throws -> Emit {
        guard let endpointURL = URL(string: endpoint) else {
            throw TransportError.InvalidURL
        }
        if endpointURL.scheme == "ws" && !CellBase.allowsInsecureWebSockets {
            throw CellResolverError.insecureWebSocketNotAllowed(endpoint: endpoint)
        }
        let emitCell = try await self.cellBridgeEmit(for: endpoint, and: requester)
        await touchLifecycle(for: emitCell)
        return emitCell
        
//        
//        guard let identity = await CellBase.defaultIdentityVault?.identity(for: endpoint, makeNewIfNotFound: true) else {
//            throw CellResolverError.identityNotFound
//        }
////        let cloudBridgeSetup = try await self.setupCloudBridge(endpoint: endpoint, identity: identity)
//        let cloudBridgeSetup = try await self.cellBridgeEmit(for: endpoint, and: identity)
//        return cloudBridgeSetup
    }
    
    private func emitCellAtCellEndpoint(endpointUrl: URL, requester: Identity) async throws -> Emit {
        if let host = endpointUrl.host, host != "", host != "localhost" {
            return try await emitCellAtRemoteCellEndpoint(endpointUrl: endpointUrl, requester: requester)
        }
        
        var targetCellUUID = endpointUrl.path
        if targetCellUUID.hasPrefix("/") {
            targetCellUUID.remove(at: targetCellUUID.startIndex)
        }
        let emitCell = try await emitCellWithReference(reference: targetCellUUID, identity: requester)
        await touchLifecycle(for: emitCell)
        return emitCell
    }

    private func emitCellAtRemoteCellEndpoint(endpointUrl: URL, requester: Identity) async throws -> Emit {
        let logicalEndpoint = endpointUrl.absoluteString
        let cacheKey = remoteBridgeCacheKey(endpoint: logicalEndpoint, identity: requester)

        if let cachedBridge = withStateLock({ remoteBridgeCache[cacheKey] }) {
            await touchLifecycle(for: cachedBridge)
            return cachedBridge
        }

        let task = withStateLock { () -> Task<Emit, Error> in
            if let existingTask = pendingRemoteBridgeTasks[cacheKey] {
                return existingTask
            }

            let task = Task<Emit, Error> { [weak self] in
                guard let self else {
                    throw CellResolverError.bridgeSetupError
                }
                return try await self.makeRemoteCellBridgeEmit(
                    for: endpointUrl,
                    logicalEndpoint: logicalEndpoint,
                    identity: requester
                )
            }
            pendingRemoteBridgeTasks[cacheKey] = task
            return task
        }

        do {
            let bridge = try await task.value
            withStateLock {
                pendingRemoteBridgeTasks[cacheKey] = nil
                remoteBridgeCache[cacheKey] = bridge
            }
            await touchLifecycle(for: bridge)
            return bridge
        } catch {
            withStateLock {
                pendingRemoteBridgeTasks[cacheKey] = nil
            }
            throw error
        }
    }

    private func remoteWebSocketEndpoint(from cellEndpointURL: URL) throws -> String {
        guard let host = cellEndpointURL.host else {
            throw CellResolverError.invalidRemoteCellReference(endpoint: cellEndpointURL.absoluteString)
        }
        let normalizedHost = normalizedHostKey(host)
        guard let route = withStateLock({ remoteCellHostRoutes[normalizedHost] }) else {
            throw CellResolverError.missingRemoteCellHostRegistration(host: host)
        }

        let resolvedScheme: String
        switch route.schemePreference {
        case .automatic:
            resolvedScheme = CellBase.allowsInsecureWebSockets ? "ws" : "wss"
        case .ws:
            resolvedScheme = "ws"
        case .wss:
            resolvedScheme = "wss"
        }

        if resolvedScheme == "ws" && !CellBase.allowsInsecureWebSockets {
            throw CellResolverError.insecureWebSocketNotAllowed(endpoint: cellEndpointURL.absoluteString)
        }

        let cellPath = trimmedSlashes(cellEndpointURL.path)
        guard !cellPath.isEmpty else {
            throw CellResolverError.invalidRemoteCellReference(endpoint: cellEndpointURL.absoluteString)
        }

        let routePath = trimmedSlashes(route.websocketEndpoint)
        let websocketPath = routePath.isEmpty ? "/\(cellPath)" : "/\(routePath)/\(cellPath)"

        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = host
        components.port = cellEndpointURL.port
        components.path = websocketPath
        if let queryItemsProvider = CellBase.remoteWebSocketQueryItemsProvider {
            let queryItems = queryItemsProvider(cellEndpointURL).filter { item in
                item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            if queryItems.isEmpty == false {
                components.queryItems = queryItems
            }
        }

        guard let websocketURL = components.url else {
            throw CellResolverError.failedToCreateUrlEndpoint(from: cellEndpointURL.absoluteString)
        }
        return websocketURL.absoluteString
    }

    private func remoteWebSocketConnectionURL(
        from cellEndpointURL: URL,
        publisherUUID: String
    ) throws -> URL {
        guard let host = cellEndpointURL.host else {
            throw CellResolverError.invalidRemoteCellReference(endpoint: cellEndpointURL.absoluteString)
        }
        let normalizedHost = normalizedHostKey(host)
        guard let route = withStateLock({ remoteCellHostRoutes[normalizedHost] }) else {
            throw CellResolverError.missingRemoteCellHostRegistration(host: host)
        }

        let resolvedScheme = try remoteWebSocketScheme(for: route, endpoint: cellEndpointURL.absoluteString)

        let cellPath = trimmedSlashes(cellEndpointURL.path)
        guard !cellPath.isEmpty else {
            throw CellResolverError.invalidRemoteCellReference(endpoint: cellEndpointURL.absoluteString)
        }

        let routePath = trimmedSlashes(route.websocketEndpoint)
        let orderedPathSuffix: String
        switch route.pathLayout {
        case .endpointThenPublisherUUID:
            orderedPathSuffix = "\(cellPath)/\(publisherUUID)"
        case .publisherUUIDThenEndpoint:
            orderedPathSuffix = "\(publisherUUID)/\(cellPath)"
        }

        let websocketPath = routePath.isEmpty
            ? "/\(orderedPathSuffix)"
            : "/\(routePath)/\(orderedPathSuffix)"

        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = host
        components.port = cellEndpointURL.port
        components.path = websocketPath

        guard let websocketURL = components.url else {
            throw CellResolverError.failedToCreateUrlEndpoint(from: cellEndpointURL.absoluteString)
        }
        return websocketURL
    }

    private func remoteWebSocketScheme(
        for route: RemoteCellHostRoute,
        endpoint: String
    ) throws -> String {
        let resolvedScheme: String
        switch route.schemePreference {
        case .automatic:
            resolvedScheme = CellBase.allowsInsecureWebSockets ? "ws" : "wss"
        case .ws:
            resolvedScheme = "ws"
        case .wss:
            resolvedScheme = "wss"
        }

        if resolvedScheme == "ws" && !CellBase.allowsInsecureWebSockets {
            throw CellResolverError.insecureWebSocketNotAllowed(endpoint: endpoint)
        }
        return resolvedScheme
    }

    private func normalizedHostKey(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func trimmedSlashes(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    /*
     name or uuid
     if name resolve to uuid - also check identity unique resolution
     check if it is a template
     check if uuid is loaded in memory
     if it is persistable
     */
    private func isUUID(_ uuidString: String) -> Bool {
        if let _ = UUID(uuidString: uuidString) {
            return true
        }
        return false
    }
    
    private func emitCellWithReference(reference: String, identity: Identity) async throws -> Emit {
        if isUUID(reference) {
            if let cell = await loadCellFromMemory(uuid:reference) {
                if let endpoint = await auditor.cellname(for: cell.uuid),
                   let resolve = await auditor.loadNamedResolve(endpoint) {
                    await applyLifecycleTrackingIfNeeded(
                        cell: cell,
                        resolve: resolve,
                        endpoint: endpoint,
                        identity: identity
                    )
                }
                return cell
            }
            if let cell = await loadCellFromPersistance(uuid: reference) {
                if let endpoint = await auditor.cellname(for: cell.uuid),
                   let resolve = await auditor.loadNamedResolve(endpoint) {
                    await applyLifecycleTrackingIfNeeded(
                        cell: cell,
                        resolve: resolve,
                        endpoint: endpoint,
                        identity: identity
                    )
                }
                return cell
            }
            print("Error cell not found for: \(reference) at emit cell with reference")
            throw CellResolverError.cellNotFound
        }

        let resolve = await auditor.loadNamedResolve(reference)
        switch resolve?.cellScope {
        case .template:
            let cell = try await createCell(reference: reference)
            await applyLifecycleTrackingIfNeeded(
                cell: cell,
                resolve: resolve,
                endpoint: reference,
                identity: identity
            )
            return cell
        case .scaffoldUnique:
            if let cell = await loadCellFromMemory(name:reference) {
                if await shouldRefreshSharedCell(cell, for: resolve) {
                    await auditor.unregisterSharedReference(endpoint: reference)
                } else {
                    await applyLifecycleTrackingIfNeeded(
                        cell: cell,
                        resolve: resolve,
                        endpoint: reference,
                        identity: identity
                    )
                    return cell
                }
            }
            
            if resolve?.cellPersistancy == .persistant,
               let cell = await loadCellFromPersistance(uuid: reference) {
                if await shouldRefreshSharedCell(cell, for: resolve) {
                    _ = deletePersistedCellData(uuid: cell.uuid)
                    await auditor.unregisterSharedReference(endpoint: reference)
                } else {
                    CellBase.diagnosticLog("Loaded persisted cell named \(reference)", domain: .resolver)
                    await applyLifecycleTrackingIfNeeded(
                        cell: cell,
                        resolve: resolve,
                        endpoint: reference,
                        identity: identity
                    )
                    return cell
                }
            }

            let emitter = try await cellLoadingSequence(key: reference, loaders: [
                loadCellFromMemory(name:),
                loadCellFromPersistance(uuid:),
                createAndRegisterCell(reference:)
            ])
            await applyLifecycleTrackingIfNeeded(
                cell: emitter,
                resolve: resolve,
                endpoint: reference,
                identity: identity
            )
            return emitter
        case .identityUnique:
            if let cell = await loadPersonalCellFromMemory(name:reference, identity: identity) {
                await applyLifecycleTrackingIfNeeded(
                    cell: cell,
                    resolve: resolve,
                    endpoint: reference,
                    identity: identity
                )
                return cell
            }
            if let cell = await loadPersonalCellFromPersistance(name: reference, identity: identity) {
                await applyLifecycleTrackingIfNeeded(
                    cell: cell,
                    resolve: resolve,
                    endpoint: reference,
                    identity: identity
                )
                return cell
            }
            let cell = try await createAndRegisterPersonalCell(endpoint: reference, identity: identity)
            await applyLifecycleTrackingIfNeeded(
                cell: cell,
                resolve: resolve,
                endpoint: reference,
                identity: identity
            )
            return cell
        case .none:
            if let cell = await loadPersonalCellFromMemory(name:reference, identity: identity) {
                return cell
            }
            
            return try await cellLoadingSequence(key: reference, loaders: [
                    loadCellFromMemory(uuid:),
                    loadCellFromMemory(name:),
                    loadCellFromPersistance(uuid:),
                    loadCellFromPersistance(name:)
                ])
        }
    }

    // Should this be refactored?
    func cellLoadingSequence(key: String, loaders: [(String) async throws -> Emit?]) async throws -> Emit {
        for loader in loaders {
            if let cell = try await loader(key) {
                return cell
            }
        }
        print("Did NOT find any EmitCell with name: \(key)!!!")
        throw CellResolverError.cellNotFound
    }

    private func loadCellFromMemory(name: String) async -> Emit? {
        await auditor.loadCellInstance(forEndpoint: name)
    }
    private func loadCellFromMemory(uuid: String) async -> Emit? {
        await auditor.loadCellInstance(forUUID: uuid)
    }
    private func loadCellFromPersistance(uuid: String) async -> Emit? {
        do {
            return try await loadTypedEmitCell(with: uuid)
        } catch {
            print("loadTypedEmitCell with uuid: \(uuid) failed with error: \(error)")
        }
        return nil
    }
   
    private func loadPersonalCellFromPersistance(name: String, identity: Identity) async -> Emit? {
        do {
            guard let uuid = await auditor.loadIdentityCellUuid(name: name, identity: identity) else {
                return nil
            }
            let emitCell = try await loadTypedEmitCell(with: uuid)
            return emitCell
        } catch {
            print("loadPersonalCellFromPersistance with name: \(name) for identity: \(identity.uuid) failed with error: \(error)")
        }
        return nil
    }
    private func loadCellFromPersistance(name: String) async -> Emit? {
        
        do {
            return try await loadTypedEmitCell(with: name)
        } catch {
            print("loadTypedEmitCell with name: \(name) failed with error: \(error)")
        }
        return nil
    }
    
    private func loadPersonalCellFromMemory(name: String, identity: Identity) async -> Emit? {
        await auditor.loadIdentityCellInstance(name: name, identity: identity)
    }

    private func shouldRefreshSharedCell(_ cell: Emit, for resolve: CellResolve?) async -> Bool {
        guard let resolve,
              resolve.cellScope == .scaffoldUnique else {
            return false
        }
        guard let generalCell = cell as? GeneralCell else {
            return false
        }
        guard let owner = try? await generalCell.getOwner(requester: resolve.owner) else {
            return false
        }
        return owner.uuid != resolve.owner.uuid
    }
    
    private func createCell(reference: String) async throws -> Emit {
        guard let resolve = await auditor.loadNamedResolve(reference) else {
            print("Error cell not found for: \(reference) at create cell")
            throw CellResolverError.cellNotFound
        }
        let instance = try await resolve.new()
        
        guard let emitCell = instance as? Emit else {
            print("Error cell not found for: \(reference) at create cell(2)")
            throw CellResolverError.cellNotFound
        }
        try await auditor.registerReference(emitCell)
        return emitCell
    }
    
    private func createAndRegisterCell(reference: String) async throws -> Emit? {
        guard let resolve = await auditor.loadNamedResolve(reference) else {
            print("Error cell not found for: \(reference) at create and register cell")
            throw CellResolverError.cellNotFound
        }
        let instance = try await resolve.new()
        guard let cell = instance as? Emit else {
            print("Error cell not found for: \(reference) at create and register cell(2)")
            throw CellResolverError.cellNotFound
        }
        cell.cellScope = resolve.cellScope
        cell.persistancy = resolve.cellPersistancy
        try await auditor.registerReference(cell, endpoint: reference)
        
        var flowElement = FlowElement(title: "Resolver event", content: .string("registered_named_cell"), properties: FlowElement.Properties(type: .event, contentType: .string))
        flowElement.topic = "register"
        if let resolverEmitter = withStateLock({ self.resolverEmitter })
        {
             resolverEmitter.pushFlowElement(flowElement, requester: resolverEmitter.owner)
        }
        
        if resolve.cellPersistancy == .persistant,
           let tcUtility = self.tcUtility,
           let codableEmit = cell as? Codable
        {
            let typeName = String(String(describing: instance.self).split(separator: ".").last ?? "err")
            await ensurePersistedCellMasterKeyLoaded()
            tcUtility.storeAsTypedCell(
                cellName: typeName,
                cell: codableEmit,
                uuid: cell.uuid,
                options: persistenceWriteOptions(
                    for: cell,
                    fallbackOwnerIdentityUUID: nil
                )
            )
            await lifecycleTracker.touchPersistedCell(uuid: cell.uuid)
        }
        
        return cell
    }
    
    private func createAndRegisterPersonalCell(endpoint: String, identity: Identity) async throws -> Emit {
        guard let resolve = await auditor.loadNamedResolve(endpoint) else {
            print("Error cell not found for: \(endpoint) at create and register personal cell")
            throw CellResolverError.cellNotFound
        }
        let instance = try await resolve.new(requester: identity)
        guard let cell = instance as? Emit else {
            print("Error cell not found for: \(endpoint) at create and register personal cell (2)")
            throw CellResolverError.cellNotFound
        }
        cell.cellScope = resolve.cellScope
        cell.persistancy = resolve.cellPersistancy
        try await auditor.registerPersonalReference(cell, endpoint: endpoint, identity: identity)
        // Push notification for updated personal cell register
        var flowElement = FlowElement(title: "Resolver event", content: .string("registered_identity_named_cell"), properties: FlowElement.Properties(type: .event, contentType: .string))
        flowElement.topic = "register"
        if let resolverEmitter = withStateLock({ self.resolverEmitter })
        {
             resolverEmitter.pushFlowElement(flowElement, requester: resolverEmitter.owner)
        }
        
        if resolve.cellPersistancy == .persistant,
           let tcUtility = self.tcUtility,
           let codableEmit = cell as? Codable
        {
            let typeName = String(String(describing: instance.self).split(separator: ".").last ?? "err")
            await ensurePersistedCellMasterKeyLoaded()
            tcUtility.storeAsTypedCell(
                cellName: typeName,
                cell: codableEmit,
                uuid: cell.uuid,
                options: persistenceWriteOptions(
                    for: cell,
                    fallbackOwnerIdentityUUID: identity.uuid
                )
            )
            await lifecycleTracker.touchPersistedCell(uuid: cell.uuid)
        }

        
        return cell
    }
    
    
    public func registerTransport(_ transportType: BridgeTransportProtocol.Type, for scheme: String) async throws {
        
        withStateLock {
            transports[scheme] = transportType
        }
    }
    
    
    
    func transportForScheme(_ scheme: String) throws -> BridgeTransportProtocol {
        guard let transportType = withStateLock({ self.transports[scheme] }) else {
            throw TransportError.TransportNotFound
        }
        let transport =  transportType.new()
        return transport
    }
    
    private func cellBridgeEmit(for endpoint: String, and identity: Identity) async throws -> Emit {
        let cacheKey = remoteBridgeCacheKey(endpoint: endpoint, identity: identity)

        if let cachedBridge = withStateLock({ remoteBridgeCache[cacheKey] }) {
            return cachedBridge
        }

        let task = withStateLock { () -> Task<Emit, Error> in
            if let existingTask = pendingRemoteBridgeTasks[cacheKey] {
                return existingTask
            }

            let task = Task<Emit, Error> { [weak self] in
                guard let self else {
                    throw CellResolverError.bridgeSetupError
                }
                return try await self.makeCellBridgeEmit(for: endpoint, and: identity)
            }
            pendingRemoteBridgeTasks[cacheKey] = task
            return task
        }

        do {
            let bridge = try await task.value
            withStateLock {
                pendingRemoteBridgeTasks[cacheKey] = nil
                remoteBridgeCache[cacheKey] = bridge
            }
            return bridge
        } catch {
            withStateLock {
                pendingRemoteBridgeTasks[cacheKey] = nil
            }
            throw error
        }
    }

    private func makeCellBridgeEmit(for endpoint: String, and identity: Identity) async throws -> Emit {
        guard var endpointUrl = URL(string: endpoint) else {
            throw TransportError.InvalidURL
        }
        guard let transportScheme = endpointUrl.scheme else {
            throw TransportError.UnrecognisedScheme
        }
        
        
        let transport = try transportForScheme(transportScheme)// Find available transport for protocol
        // TODO: Consider refactoring 
        let bridgeConfig = BridgeBase.Config(contractTemplate: await Agreement(), transport: transport, connection: .outbound)
        let cellBridge = try await BridgeBase(bridgeConfig)
        try await cellBridge.setTransport(transport, connection: .outbound)
        
        endpointUrl.appendPathComponent(cellBridge.uuid)
        try await transport.setup(endpointUrl, identity: identity)
        do {
            try await cellBridge.retrieveProxyRepresentation(for: identity)
        } catch {
            // Some protected remote cells require admission before they will answer
            // `description`. Keep the bridge alive so the caller can authorize first
            // and retry metadata fetch afterward.
            CellBase.diagnosticLog(
                "bridge_description_deferred:\(endpoint):\(error)",
                domain: .flow
            )
        }
        try await self.registerNamedEmitCell(name: endpoint, emitCell: cellBridge, identity: identity)
        return cellBridge
    }

    private func makeRemoteCellBridgeEmit(
        for endpointUrl: URL,
        logicalEndpoint: String,
        identity: Identity
    ) async throws -> Emit {
        guard let host = endpointUrl.host else {
            throw CellResolverError.invalidRemoteCellReference(endpoint: logicalEndpoint)
        }
        let normalizedHost = normalizedHostKey(host)
        guard let route = withStateLock({ remoteCellHostRoutes[normalizedHost] }) else {
            throw CellResolverError.missingRemoteCellHostRegistration(host: host)
        }
        let transportScheme = try remoteWebSocketScheme(for: route, endpoint: logicalEndpoint)
        let transport = try transportForScheme(transportScheme)
        let bridgeConfig = BridgeBase.Config(contractTemplate: await Agreement(), transport: transport, connection: .outbound)
        let cellBridge = try await BridgeBase(bridgeConfig)

        let finalizedConnectionURL = try remoteWebSocketConnectionURL(
            from: endpointUrl,
            publisherUUID: cellBridge.uuid
        )
        try await cellBridge.setTransport(transport, connection: .outbound)
        try await transport.setup(finalizedConnectionURL, identity: identity)
        do {
            try await cellBridge.retrieveProxyRepresentation(for: identity)
        } catch {
            CellBase.diagnosticLog(
                "bridge_description_deferred:\(logicalEndpoint):\(error)",
                domain: .flow
            )
        }
        try await self.registerNamedEmitCell(name: logicalEndpoint, emitCell: cellBridge, identity: identity)
        return cellBridge
    }

    private func remoteBridgeCacheKey(endpoint: String, identity: Identity) -> String {
        "\(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(identity.uuid.lowercased())"
    }

    private func evictRemoteBridges(for uuid: String) {
        let normalizedUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedUUID.isEmpty else { return }
        withStateLock {
            remoteBridgeCache = remoteBridgeCache.filter { _, emit in
                emit.uuid.lowercased() != normalizedUUID
            }
        }
    }
    
    public func addCellResolve<T>(
        name: String,
        cellScope: CellUsageScope = .template,
        persistency: Persistancy = .ephemeral,
        identityDomain: String = "scaffold",
        lifecyclePolicy: CellLifecyclePolicy? = nil,
        type: T.Type
    ) async throws where T : Emit & OwnerInstantiable {
        let resolve = try await CellResolve(
            name: name,
            cellType: type,
            cellScope: cellScope,
            percistancy: persistency,
            lifecyclePolicy: lifecyclePolicy,
            identityDomain: identityDomain,
            resolver: self
        )
        try await auditor.storeNamedResolve(resolve: resolve)
        
        if persistency == .persistant {
            if let codableType = type as? Codable.Type {
                guard let tcUtility = tcUtility else {
                    throw CellSetupError.missingPersistanceUtility
                }
                
                try tcUtility.register(
                    name: String(describing: type.self),
                    type: codableType)
            }
        }
    }

    public func refreshNamedResolveOwnersFromCurrentVault() async {
        guard let identityVault = CellBase.defaultIdentityVault else {
            return
        }
        let resolves = await auditor.namedResolves()
        for resolve in resolves {
            guard let identity = await identityVault.identity(
                for: resolve.identityDomain,
                makeNewIfNotFound: true
            ) else {
                continue
            }
            resolve.owner = identity
        }
    }
    
    public func registerNamedEmitCell(name: String, emitCell: Emit, scope: CellUsageScope = .scaffoldUnique /*, persistancy: Persistancy = .ephemeral */, identity: Identity) async throws {
        switch scope {
        case .template:
            try await auditor.registerReference(emitCell, endpoint: name)
            
        case .scaffoldUnique:
            try? await auditor.registerReference(emitCell, endpoint: name)
            
        case .identityUnique:
            try await auditor.registerPersonalReference(emitCell, endpoint: name, identity: identity)
        }
        let resolve = await auditor.loadNamedResolve(name)
        await applyLifecycleTrackingIfNeeded(
            cell: emitCell,
            resolve: resolve,
            endpoint: name,
            identity: identity
        )
//        if persistancy == .persistant {
//            
//        }
    }
    
    public func cellUUID(for name: String) async -> String? {
        
        return await auditor.celluuid(for: name)
    }
    
    public func namedCell(for uuid: String) async -> String? {
        return nil
    }
    
    public func unregisterEmitCell(uuid: String) async {
        evictRemoteBridges(for: uuid)
        await auditor.unregisterReference(uuid: uuid)
        await lifecycleTracker.untrackCell(uuid: uuid)
        await syncRuntimeShadowUnloadIfNeeded(uuid: uuid, persistedSnapshotAvailable: true)
    }
    
    public func loadTypedEmitCell(with reference: String) async throws -> Emit? {
        guard
            let typedCellUtility = CellBase.typedCellUtility,
            let uuid = isUUID(reference) ? reference : await auditor.celluuid(for: reference), // should it throw so we can catch an error? A personal unique cell will always come as UUID
            let emitCell = typedCellUtility.loadTypedEmitCell(with: uuid)
        else {
            return nil
        }
        try await auditor.registerReference(emitCell, endpoint: reference)
        let endpoint = isUUID(reference) ? await auditor.cellname(for: uuid) : reference
        if let endpoint,
           let resolve = await auditor.loadNamedResolve(endpoint),
           let persistedTTL = resolve.lifecyclePolicy?.persistedDataTTL,
           persistedTTL > 0 {
            await lifecycleTracker.setPersistedTTL(uuid: uuid, ttl: persistedTTL)
        }
        await lifecycleTracker.touchPersistedCell(uuid: uuid)
        return emitCell
    }
    
    public func loadTypedEmitCell(by name: String) async throws -> Emit? {
        
        
        guard
            let uuid = await auditor.celluuid(for: name),
            let typedCellUtility = CellBase.typedCellUtility,
            let emitCell = typedCellUtility.loadTypedEmitCell(with: uuid)
        else {
            return nil
        }
        try await auditor.registerReference(emitCell, endpoint: uuid)
        if let resolve = await auditor.loadNamedResolve(name),
           let persistedTTL = resolve.lifecyclePolicy?.persistedDataTTL,
           persistedTTL > 0 {
            await lifecycleTracker.setPersistedTTL(uuid: uuid, ttl: persistedTTL)
        }
        await lifecycleTracker.touchPersistedCell(uuid: uuid)
        return emitCell
    }

    public func registerRemoteCellHost(_ host: String, route: RemoteCellHostRoute = RemoteCellHostRoute()) {
        let normalizedHost = normalizedHostKey(host)
        guard !normalizedHost.isEmpty else { return }
        withStateLock {
            remoteCellHostRoutes[normalizedHost] = route
        }
    }

    public func unregisterRemoteCellHost(_ host: String) {
        let normalizedHost = normalizedHostKey(host)
        withStateLock {
            remoteCellHostRoutes[normalizedHost] = nil
        }
    }

    public func remoteCellHostRoutesSnapshot() -> [String: RemoteCellHostRoute] {
        withStateLock {
            remoteCellHostRoutes
        }
    }

    public func registeredTransportSchemesSnapshot() -> [String] {
        withStateLock {
            transports.keys.sorted()
        }
    }
    
    
    public func logAction(context: ConnectContext, action: String, param: String) {
        Task {
            let sourceID = (try? (await context.source) as? Emit)?.uuid ?? "source"
            let targetID = (try? await context.target)?.uuid ?? "target"
            let identityID = context.identity?.uuid ?? ""
            CellBase.diagnosticLog(
                "INTR:\(action):\(param):\(sourceID):\(targetID):\(identityID):\(Date().timeIntervalSince1970)",
                domain: .flow
            )
        }
        //INTeRaction:action:connectState:source:target:requester:connectState:timestamp
    }
    public func logReference(emitter: Emit) {
        Task {
            if let requester = await CellBase.defaultIdentityVault?.identity(for: "private", makeNewIfNotFound: true) {
                let anyCell = await emitter.advertise(for: requester)
                do {
                    let anyCSJsonData = try JSONEncoder().encode(anyCell)
                    CellBase.diagnosticLog(
                        "REF:\(String(data: anyCSJsonData, encoding: .utf8) ?? "nil")",
                        domain: .resolver
                    )
                } catch {
                    CellBase.diagnosticLog("REF:FAILED:\(error)", domain: .resolver)
                }
            }
        }
    }
    
    public func namedCells(requester: Identity) async -> [String: String] {
        // check permissions
        return await auditor.namedCells()
    }
    
    public func setNamedCells(_ namedCells: [String : String], requester: Identity) async {

        
        await auditor.setNamedCells(namedCells)
    }
    
    public func identityNamedCells(requester: Identity) async -> [String : [String : String]] {
        
        return await auditor.identityNamedCells()
    }

    public func resolverRegistrySnapshot(requester: Identity) async -> CellResolverRegistrySnapshot {
        CellResolverRegistrySnapshot(
            resolves: await auditor.resolveSnapshots(),
            sharedNamedInstances: await auditor.sharedNamedInstanceSnapshots(),
            identityNamedInstances: await auditor.identityNamedInstanceSnapshots()
        )
    }
    
    public func setIdentityNamedCells(_ identityNamedCells: [String : [String : String]], requester: Identity) async {
        
        await auditor.setIdentityNamedCells(identityNamedCells)
    }
}
