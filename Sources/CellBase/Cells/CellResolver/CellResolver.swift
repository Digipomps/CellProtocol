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
    case persistedCellUnavailable
    case ownerAuthorityUnavailable
}

private enum IdentityUniqueOwnerValidation {
    case valid
    case mismatchedReference
    case authorityUnproven
}

private enum PersonalCellPersistenceLoadError: Error {
    case missing
    case unavailable
    case ownerReferenceMismatch
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

    public enum ConnectionSharing: Sendable {
        /// Existing wire format: one physical connection per remote bridge.
        case dedicated
        /// Protocol v2: identity-bound physical session with logical channels.
        case multiplexedV2
    }

    public var websocketEndpoint: String
    public var schemePreference: SchemePreference
    public var pathLayout: PathLayout
    public var connectionSharing: ConnectionSharing

    public init(
        websocketEndpoint: String = "bridgehead",
        schemePreference: SchemePreference = .automatic,
        pathLayout: PathLayout = .endpointThenPublisherUUID,
        connectionSharing: ConnectionSharing = .dedicated
    ) {
        self.websocketEndpoint = websocketEndpoint
        self.schemePreference = schemePreference
        self.pathLayout = pathLayout
        self.connectionSharing = connectionSharing
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
    private let remoteBridgeConnectionPool = BridgeConnectionPool()
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
                persistedDataTTL: record.persistedDataTTL,
                requiresAction: true,
                availableResponses: [
                    "extendPersistedDataTTL",
                    "deletePersistedData",
                    "ignore"
                ]
            )
            let response = await resolveLifecycleResponse(for: event)
            let shouldDelete: Bool
            switch response {
            case .extendPersistedDataTTL(let seconds):
                _ = await lifecycleTracker.extendPersistedDataTTL(uuid: record.uuid, by: seconds)
                shouldDelete = false
            case .ignore:
                shouldDelete = false
            case .deletePersistedData:
                shouldDelete = true
            case .useDefaultAction:
                shouldDelete = record.persistedDataExpiryAction == .deletePersistedData
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
        if let requiresAction = event.requiresAction {
            payload["requiresAction"] = .bool(requiresAction)
        }
        if let availableResponses = event.availableResponses {
            payload["availableResponses"] = .list(availableResponses.map { .string($0) })
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
        do {
            _ = try await prepareCellForRuntime(cell)
        } catch {
            CellBase.diagnosticLog(
                "Refused to persist Cell \(cell.uuid) before runtime readiness: \(error)",
                domain: .lifecycle
            )
            return
        }
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
        try await authorizeMeddleIfAvailable(
            target: target,
            keypath: keypath,
            method: .get,
            defaultAccess: "r---",
            requester: requester
        )
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
        try await authorizeMeddleIfAvailable(
            target: target,
            keypath: keypath,
            method: .set,
            defaultAccess: "-w--",
            requester: requester
        )
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

    private func authorizeMeddleIfAvailable(
        target: Meddle,
        keypath: String,
        method: ExploreContractMethod,
        defaultAccess: String,
        requester: Identity
    ) async throws {
        if let runtimeReadyTarget = target as? CellRuntimeReady {
            try await runtimeReadyTarget.ensureRuntimeReady()
        }
        guard let authorizer = target as? CellAuthorizationDeciding else {
            return
        }
        let requestedAccess = try await MeddleOperationAuthorizationRequirementResolver.resolve(
            target: target,
            keypath: keypath,
            method: method,
            requester: requester
        ) ?? defaultAccess
        let decision = await authorizer.authorizationDecision(
            requestedAccess: requestedAccess,
            at: keypath,
            for: requester
        )
        CellBase.diagnosticLog(
            "Resolver authorization keypath=\(keypath) access=\(requestedAccess) allowed=\(decision.allowed) path=\(decision.path.rawValue)",
            domain: .resolver
        )
        if !decision.allowed {
            throw CellAuthorizationError.denied(decision)
        }
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
        let emitCell: Emit
        switch endpointUrl.scheme {
        case "ws", "wss":
            emitCell = try await emitCellAtWSEndpoint(endpoint: endpoint, requester: requester) // TODO: Consider using only url
        case "cell":
            emitCell = try await emitCellAtCellEndpoint(endpointUrl: endpointUrl, requester: requester)
        default:
            throw CellResolverError.unsupportedUrlScheme
        }
        return try await prepareCellForRuntime(emitCell)
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
                if cell.cellScope == .identityUnique {
                    guard try await validatesIdentityUniqueDirectReferenceAccess(
                        cell,
                        requester: identity
                    ) else {
                        throw CellSetupError.ownerAuthorityUnavailable
                    }
                }
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
            if let cell = try await loadCellFromPersistance(uuid: reference, requester: identity) {
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
            let cell = try await createCell(reference: reference, requester: identity)
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
               let cell = try await loadCellFromPersistance(uuid: reference) {
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

            let emitter: Emit
            if resolve?.cellPersistancy == .persistant {
                emitter = try await cellLoadingSequence(key: reference, loaders: [
                    loadCellFromMemory(name:),
                    loadCellFromPersistance(uuid:),
                    createAndRegisterCell(reference:)
                ])
            } else {
                // A transient shared Cell has no persistence contract. An
                // unrelated unavailable storage backend must therefore not
                // prevent recreation after lifecycle eviction.
                emitter = try await cellLoadingSequence(key: reference, loaders: [
                    loadCellFromMemory(name:),
                    createAndRegisterCell(reference:)
                ])
            }
            await applyLifecycleTrackingIfNeeded(
                cell: emitter,
                resolve: resolve,
                endpoint: reference,
                identity: identity
            )
            return emitter
        case .identityUnique:
            if let existingUUID = await auditor.loadIdentityCellUuid(
                name: reference,
                identity: identity
            ) {
                if let cell = await auditor.loadIdentityCellInstance(
                    name: reference,
                    identity: identity
                ) {
                    switch try await validateIdentityUniqueOwner(cell, requester: identity) {
                    case .valid:
                        await applyLifecycleTrackingIfNeeded(
                            cell: cell,
                            resolve: resolve,
                            endpoint: reference,
                            identity: identity
                        )
                        return cell
                    case .mismatchedReference:
                        await auditor.unregisterIdentityReference(
                            uuid: existingUUID,
                            name: reference,
                            identity: identity
                        )
                    case .authorityUnproven:
                        throw CellSetupError.ownerAuthorityUnavailable
                    }
                }
                if await auditor.loadIdentityCellUuid(name: reference, identity: identity) != nil {
                    do {
                        let cell = try await loadPersonalCellFromPersistance(
                            name: reference,
                            identity: identity
                        )
                        await applyLifecycleTrackingIfNeeded(
                            cell: cell,
                            resolve: resolve,
                            endpoint: reference,
                            identity: identity
                        )
                        return cell
                    } catch PersonalCellPersistenceLoadError.missing,
                            PersonalCellPersistenceLoadError.ownerReferenceMismatch {
                        await auditor.unregisterIdentityReference(
                            uuid: existingUUID,
                            name: reference,
                            identity: identity
                        )
                    } catch {
                        throw error
                    }
                }
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
            if await auditor.loadIdentityCellUuid(name: reference, identity: identity) != nil {
                if let cell = await auditor.loadIdentityCellInstance(name: reference, identity: identity) {
                    guard case .valid = try await validateIdentityUniqueOwner(cell, requester: identity) else {
                        throw CellSetupError.ownerAuthorityUnavailable
                    }
                    return cell
                }
                do {
                    return try await loadPersonalCellFromPersistance(
                        name: reference,
                        identity: identity
                    )
                } catch {
                    // Scope is unknown here, so even a missing persistence
                    // record is not authority to mutate identity metadata.
                    throw error
                }
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
    private func loadCellFromPersistance(uuid: String) async throws -> Emit? {
        try await loadTypedEmitCell(with: uuid)
    }

    private func loadCellFromPersistance(uuid: String, requester: Identity) async throws -> Emit? {
        try await loadTypedEmitCell(with: uuid, requester: requester)
    }
    private func loadPersonalCellFromPersistance(name: String, identity: Identity) async throws -> Emit {
        guard let uuid = await auditor.loadIdentityCellUuid(name: name, identity: identity),
              tcUtility != nil || CellBase.typedCellUtility != nil else {
            throw PersonalCellPersistenceLoadError.unavailable
        }
        let emitCell: Emit
        switch await loadTypedEmitCellResult(with: uuid) {
        case .loaded(let loaded):
            emitCell = loaded
        case .missing:
            throw PersonalCellPersistenceLoadError.missing
        case .unavailable:
            throw PersonalCellPersistenceLoadError.unavailable
        }

        // A persisted identity-unique mapping is metadata, not proof that
        // the active requester owns the decoded Cell. Validate the stored
        // signing identity before runtime readiness, because readiness may
        // restore resolver mappings or install other process-wide state.
        switch try await validateIdentityUniqueOwner(emitCell, requester: identity) {
        case .valid:
            break
        case .mismatchedReference:
            throw PersonalCellPersistenceLoadError.ownerReferenceMismatch
        case .authorityUnproven:
            CellBase.diagnosticLog(
                "Refusing persisted identity-unique cell without owner key proof endpoint=\(name) cell=\(uuid)",
                domain: .resolver
            )
            throw CellSetupError.ownerAuthorityUnavailable
        }

        _ = try await prepareCellForRuntime(emitCell)
        try await auditor.registerReference(emitCell)
        await lifecycleTracker.touchPersistedCell(uuid: uuid)
        return emitCell
    }
    private func loadCellFromPersistance(name: String) async throws -> Emit? {
        try await loadTypedEmitCell(with: name)
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
    
    private func createCell(reference: String, requester: Identity) async throws -> Emit {
        guard let resolve = await auditor.loadNamedResolve(reference) else {
            print("Error cell not found for: \(reference) at create cell")
            throw CellResolverError.cellNotFound
        }
        let instance = try await resolve.new(requester: requester)
        
        guard let emitCell = instance as? Emit else {
            print("Error cell not found for: \(reference) at create cell(2)")
            throw CellResolverError.cellNotFound
        }
        _ = try await prepareCellForRuntime(emitCell)
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
        _ = try await prepareCellForRuntime(cell)
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
        guard await requesterProvesSigningControl(identity) else {
            throw CellSetupError.ownerAuthorityUnavailable
        }
        let instance = try await resolve.new(requester: identity)
        guard let cell = instance as? Emit else {
            print("Error cell not found for: \(endpoint) at create and register personal cell (2)")
            throw CellResolverError.cellNotFound
        }
        cell.cellScope = resolve.cellScope
        cell.persistancy = resolve.cellPersistancy
        _ = try await prepareCellForRuntime(cell)
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
        let cellBridgeUUID = UUID().uuidString
        let transport: BridgeTransportProtocol
        let finalizedConnectionURL: URL

        switch route.connectionSharing {
        case .dedicated:
            transport = try transportForScheme(transportScheme)
            finalizedConnectionURL = try remoteWebSocketConnectionURL(
                from: endpointUrl,
                publisherUUID: cellBridgeUUID
            )
        case .multiplexedV2:
            guard let transportType = withStateLock({ transports[transportScheme] }) else {
                throw TransportError.TransportNotFound
            }
            guard let signingKeyFingerprint = identity.signingPublicKeyFingerprint,
                  let homeVaultReference = identity.homeVaultReference else {
                throw IdentityVaultError.noKey
            }
            finalizedConnectionURL = try remoteMultiplexSessionURL(
                from: endpointUrl,
                route: route
            )
            let key = BridgeConnectionPoolKey(
                sessionEndpoint: finalizedConnectionURL,
                identityUUID: identity.uuid,
                signingKeyFingerprint: signingKeyFingerprint,
                homeVaultReference: homeVaultReference
            )
            transport = try remoteBridgeConnectionPool.channelTransport(
                for: key,
                targetEndpoint: trimmedSlashes(endpointUrl.path),
                physicalTransportFactory: { transportType.new() }
            )
        }
        let bridgeConfig = BridgeBase.Config(
            contractTemplate: await Agreement(),
            uuid: cellBridgeUUID,
            transport: transport,
            connection: .outbound
        )
        let cellBridge = try await BridgeBase(bridgeConfig)
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

    private func remoteMultiplexSessionURL(
        from cellEndpointURL: URL,
        route: RemoteCellHostRoute
    ) throws -> URL {
        guard let host = cellEndpointURL.host else {
            throw CellResolverError.invalidRemoteCellReference(
                endpoint: cellEndpointURL.absoluteString
            )
        }
        let resolvedScheme = try remoteWebSocketScheme(
            for: route,
            endpoint: cellEndpointURL.absoluteString
        )
        let routePath = trimmedSlashes(route.websocketEndpoint)
        let sessionPath = routePath.isEmpty ? "/session" : "/\(routePath)/session"

        var components = URLComponents()
        components.scheme = resolvedScheme
        components.host = host
        components.port = cellEndpointURL.port
        components.path = sessionPath
        if let queryItemsProvider = CellBase.remoteWebSocketQueryItemsProvider {
            let queryItems = queryItemsProvider(cellEndpointURL).filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            components.queryItems = queryItems.isEmpty ? nil : queryItems
        }
        guard let url = components.url else {
            throw CellResolverError.failedToCreateUrlEndpoint(
                from: cellEndpointURL.absoluteString
            )
        }
        return url
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
        if scope == .identityUnique {
            guard case .valid = try await validateIdentityUniqueOwner(
                emitCell,
                requester: identity
            ) else {
                throw CellSetupError.ownerAuthorityUnavailable
            }
        }
        _ = try await prepareCellForRuntime(emitCell)
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

#if DEBUG
    @_spi(Testing)
    public func resetRuntimeStateForTesting() async {
        let pendingTasks: [Task<Emit, Error>] = withStateLock {
            let tasks = Array(pendingRemoteBridgeTasks.values)
            namedCellResolves.removeAll(keepingCapacity: false)
            loadCellFacilitators.removeAll(keepingCapacity: false)
            resolverEmitter = nil
            resolverEmittersByIdentityUUID.removeAll(keepingCapacity: false)
            remoteCellHostRoutes.removeAll(keepingCapacity: false)
            remoteBridgeCache.removeAll(keepingCapacity: false)
            pendingRemoteBridgeTasks.removeAll(keepingCapacity: false)
            connectCellCancellables.removeAll(keepingCapacity: false)
            return tasks
        }
        pendingTasks.forEach { $0.cancel() }
        for task in pendingTasks {
            _ = try? await task.value
        }
        remoteBridgeConnectionPool.reset()
        await auditor.resetRuntimeStateForTesting()
        await lifecycleTracker.resetRuntimeStateForTesting()
    }
#endif

    public func loadTypedEmitCell(with reference: String) async throws -> Emit? {
        try await loadTypedEmitCell(with: reference, requester: nil)
    }

    public func loadTypedEmitCell(with reference: String, requester: Identity) async throws -> Emit? {
        try await loadTypedEmitCell(with: reference, requester: Optional(requester))
    }

    /// Loads persisted bytes only after restoring the process-local encryption
    /// key from the configured scoped secret provider. The tri-state result is
    /// retained so callers never replace an unreadable encrypted Cell as if it
    /// were missing.
    public func loadTypedEmitCellResult(with uuid: String) async -> TypedCellLoadResult {
        await ensurePersistedCellMasterKeyLoaded()
        guard let typedCellUtility = CellBase.typedCellUtility ?? tcUtility else {
            return .unavailable
        }
        return typedCellUtility.loadTypedEmitCellResult(with: uuid)
    }

    private func loadTypedEmitCell(with reference: String, requester: Identity?) async throws -> Emit? {
        guard let uuid = isUUID(reference) ? reference : await auditor.celluuid(for: reference) else {
            return nil
        }
        let emitCell: Emit
        switch await loadTypedEmitCellResult(with: uuid) {
        case .loaded(let loaded):
            emitCell = loaded
        case .missing:
            return nil
        case .unavailable:
            throw CellSetupError.persistedCellUnavailable
        }
        if emitCell.cellScope == .identityUnique {
            guard let requester else {
                throw CellSetupError.ownerAuthorityUnavailable
            }
            if isUUID(reference) {
                guard try await validatesIdentityUniqueDirectReferenceAccess(
                    emitCell,
                    requester: requester
                ) else {
                    throw CellSetupError.ownerAuthorityUnavailable
                }
            } else {
                guard case .valid = try await validateIdentityUniqueOwner(
                    emitCell,
                    requester: requester
                ) else {
                    throw CellSetupError.ownerAuthorityUnavailable
                }
            }
        }
        _ = try await prepareCellForRuntime(emitCell)
        try await auditor.registerReference(emitCell, endpoint: reference)
        let endpoint = isUUID(reference) ? await auditor.cellname(for: uuid) : reference
        if let endpoint,
           let policy = (await auditor.loadNamedResolve(endpoint))?.lifecyclePolicy,
           let persistedTTL = policy.persistedDataTTL,
           persistedTTL > 0 {
            await lifecycleTracker.setPersistedTTL(
                uuid: uuid,
                ttl: persistedTTL,
                expiryAction: policy.persistedDataExpiryAction
            )
        }
        await lifecycleTracker.touchPersistedCell(uuid: uuid)
        return emitCell
    }

    private func validateIdentityUniqueOwner(
        _ emitCell: Emit,
        requester: Identity
    ) async throws -> IdentityUniqueOwnerValidation {
        let storedOwner = try await emitCell.getOwner(requester: requester)
        guard storedOwner.uuid == requester.uuid else {
            return .mismatchedReference
        }
        guard storedOwner.signingPublicKeyFingerprint != nil,
              storedOwner.signingPublicKeyFingerprint == requester.signingPublicKeyFingerprint else {
            return .authorityUnproven
        }
        if let generalCell = emitCell as? GeneralCell {
            return await generalCell.bindStoredOwnerToRuntimeIdentity(requester)
                ? .valid
                : .authorityUnproven
        }
        return await requesterProvesSigningControl(requester)
            ? .valid
            : .authorityUnproven
    }

    /// A concrete UUID may be resolved by either its proven owner or a subject
    /// holding an active signed Contract in that Cell. Named identity-unique
    /// references remain owner-bound because resolving a name also selects an
    /// Identity-specific instance. Returning the concrete Cell does not grant
    /// keypath access; GeneralCell still evaluates the Contract for every GET
    /// and SET operation.
    private func validatesIdentityUniqueDirectReferenceAccess(
        _ emitCell: Emit,
        requester: Identity
    ) async throws -> Bool {
        if case .valid = try await validateIdentityUniqueOwner(
            emitCell,
            requester: requester
        ) {
            return true
        }
        guard let generalCell = emitCell as? GeneralCell else {
            return false
        }
        return await generalCell.hasVerifiedAuthorizationContract(for: requester)
    }

    private func requesterProvesSigningControl(_ requester: Identity) async -> Bool {
        guard let vault = requester.identityVault,
              let challenge = await vault.randomBytes64(),
              !challenge.isEmpty else {
            return false
        }
        do {
            let signature = try await vault.signMessageForIdentity(
                messageData: challenge,
                identity: requester
            )
            return try await vault.verifySignature(
                signature: signature,
                messageData: challenge,
                for: requester
            )
        } catch {
            return false
        }
    }
    
    public func loadTypedEmitCell(by name: String) async throws -> Emit? {
        
        
        guard let uuid = await auditor.celluuid(for: name) else {
            return nil
        }
        let emitCell: Emit
        switch await loadTypedEmitCellResult(with: uuid) {
        case .loaded(let loaded):
            emitCell = loaded
        case .missing:
            return nil
        case .unavailable:
            throw CellSetupError.persistedCellUnavailable
        }
        if emitCell.cellScope == .identityUnique {
            throw CellSetupError.ownerAuthorityUnavailable
        }
        _ = try await prepareCellForRuntime(emitCell)
        try await auditor.registerReference(emitCell, endpoint: uuid)
        if let policy = (await auditor.loadNamedResolve(name))?.lifecyclePolicy,
           let persistedTTL = policy.persistedDataTTL,
           persistedTTL > 0 {
            await lifecycleTracker.setPersistedTTL(
                uuid: uuid,
                ttl: persistedTTL,
                expiryAction: policy.persistedDataExpiryAction
            )
        }
        await lifecycleTracker.touchPersistedCell(uuid: uuid)
        return emitCell
    }

    private func prepareCellForRuntime(_ cell: Emit) async throws -> Emit {
        if let runtimeReadyCell = cell as? CellRuntimeReady {
            try await runtimeReadyCell.ensureRuntimeReady()
        }
        return cell
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
                do {
                    let anyCell = try await emitter.advertise(for: requester)
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

    public func replaceIdentityNamedCells(
        _ namedCells: [String: String],
        requester: Identity
    ) async throws {
        guard await requesterProvesSigningControl(requester) else {
            CellBase.diagnosticLog(
                "Refusing identity mapping replacement without requester key proof identity=\(requester.uuid)",
                domain: .resolver
            )
            throw CellSetupError.ownerAuthorityUnavailable
        }
        await auditor.replaceIdentityNamedCells(namedCells, for: requester.uuid)
    }

    @discardableResult
    public func restoreIdentityNamedCellsFillingGaps(
        _ restored: [String: [String: String]],
        requester: Identity,
        authorization: CellResolverRecoveryAuthorization
    ) async throws -> [String: [String: String]] {
        guard await requesterProvesSigningControl(requester) else {
            CellBase.diagnosticLog(
                "Refusing identity mapping recovery without requester key proof identity=\(requester.uuid)",
                domain: .resolver
            )
            throw CellSetupError.ownerAuthorityUnavailable
        }
        return await auditor.restoreIdentityNamedCellsFillingGaps(restored)
    }
}
