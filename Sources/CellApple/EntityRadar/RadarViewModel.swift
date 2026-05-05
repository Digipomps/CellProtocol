// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if os(Linux)
import OpenCombine
#else
import Combine
#endif

@MainActor
public final class RadarViewModel: ObservableObject {
    @Published public private(set) var entities: [NearbyEntity] = []
    @Published public private(set) var scannerStatus: String = "idle"
    @Published public private(set) var connectedDevices: [String] = []
    @Published public private(set) var lastError: String?

    public let staleEntityTimeout: TimeInterval

    private var entitiesById: [String: NearbyEntity] = [:]
    private var flowCancellable: AnyCancellable?
    private var pruneCancellable: AnyCancellable?
    private var scannerEmit: Emit?
    private var scannerMeddle: Meddle?
    private var requester: Identity?

    public init(staleEntityTimeout: TimeInterval = 20.0) {
        self.staleEntityTimeout = staleEntityTimeout
    }

    deinit {
        flowCancellable?.cancel()
        pruneCancellable?.cancel()
    }

    public func connectIfNeeded() async {
        if scannerEmit != nil, scannerMeddle != nil, requester != nil {
            return
        }

        await AppInitializer.prepareLocalRuntime()

        guard let resolver = CellBase.defaultCellResolver else {
            lastError = "Cell resolver missing"
            return
        }
        guard let vault = CellBase.defaultIdentityVault else {
            lastError = "Identity vault missing"
            return
        }
        guard let identity = await vault.identity(for: "private", makeNewIfNotFound: true) else {
            lastError = "Could not resolve private identity"
            return
        }

        do {
            let emit = try await resolver.cellAtEndpoint(endpoint: "cell:///EntityScanner", requester: identity)
            guard let meddle = emit as? Meddle else {
                lastError = "EntityScanner does not support meddle"
                return
            }

            requester = identity
            scannerMeddle = meddle
            scannerEmit = emit
            lastError = nil

            try await subscribeToFlow(emitter: emit, requester: identity)
            startPruningTimerIfNeeded()
            await startScanning()
        } catch {
            lastError = "Failed to connect scanner: \(error)"
        }
    }

    public func startScanning() async {
        guard let requester, let scannerMeddle else {
            await connectIfNeeded()
            return
        }
        do {
            _ = try await scannerMeddle.set(keypath: "start", value: .bool(true), requester: requester)
            scannerStatus = "started"
            lastError = nil
        } catch {
            lastError = "Start scanner failed: \(error)"
        }
    }

    public func stopScanning() async {
        guard let requester, let scannerMeddle else {
            return
        }
        do {
            _ = try await scannerMeddle.set(keypath: "stop", value: .bool(true), requester: requester)
            scannerStatus = "stopped"
            lastError = nil
        } catch {
            lastError = "Stop scanner failed: \(error)"
        }
    }

    public func invite(remoteUUID: String) async {
        let normalizedUUID = remoteUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUUID.isEmpty else {
            return
        }
        guard let requester, let scannerMeddle else {
            return
        }

        do {
            _ = try await scannerMeddle.set(keypath: "invite", value: .string(normalizedUUID), requester: requester)
            lastError = nil
        } catch {
            lastError = "Invite failed: \(error)"
        }
    }

    public func clear() {
        entitiesById.removeAll()
        entities.removeAll()
        connectedDevices.removeAll()
    }

    private func subscribeToFlow(emitter: Emit, requester: Identity) async throws {
        flowCancellable?.cancel()
        let publisher = try await emitter.flow(requester: requester)
        flowCancellable = publisher.sink(
            receiveCompletion: { [weak self] completion in
                guard let self else { return }
                Task { @MainActor in
                    if case let .failure(error) = completion {
                        self.lastError = "Scanner flow ended: \(error)"
                    }
                }
            },
            receiveValue: { [weak self] flowElement in
                guard let self else { return }
                Task { @MainActor in
                    self.consume(flowElement)
                }
            }
        )
    }

    private func startPruningTimerIfNeeded() {
        guard pruneCancellable == nil else {
            return
        }
        pruneCancellable = Timer
            .publish(every: 2.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.pruneStaleEntities()
            }
    }

    private func consume(_ flowElement: FlowElement) {
        guard let scannerEvent = RadarEventParser.parse(flowElement) else {
            return
        }

        switch scannerEvent {
        case let .found(update):
            upsert(update, fallbackStatus: "found")
        case var .connected(update):
            if let devices = update.connectedDevices {
                connectedDevices = devices
            }
            if update.remoteUUID != nil, update.connected == nil {
                update.connected = true
            }
            upsert(update, fallbackStatus: "connected")
        case let .lost(update):
            handleLost(update)
        case let .proximity(update):
            upsert(update, fallbackStatus: "nearby")
        case let .status(update):
            if let status = update.status, !status.isEmpty {
                scannerStatus = status
            }
            upsert(update, fallbackStatus: scannerStatus)
        }
    }

    private func handleLost(_ update: RadarEntityUpdate) {
        guard let remoteUUID = normalizedRemoteUUID(update.remoteUUID) else {
            return
        }
        if var entity = entitiesById[remoteUUID] {
            var lostUpdate = update
            lostUpdate.remoteUUID = remoteUUID
            if lostUpdate.status == nil {
                lostUpdate.status = "lost"
            }
            lostUpdate.connected = false
            entity.merge(update: lostUpdate, defaultStatus: "lost")
            entitiesById[remoteUUID] = entity
            refreshEntities()
        }
    }

    private func upsert(_ update: RadarEntityUpdate, fallbackStatus: String) {
        guard let remoteUUID = normalizedRemoteUUID(update.remoteUUID) else {
            return
        }

        var normalizedUpdate = update
        normalizedUpdate.remoteUUID = remoteUUID
        if normalizedUpdate.status == nil || normalizedUpdate.status?.isEmpty == true {
            normalizedUpdate.status = fallbackStatus
        }

        if var entity = entitiesById[remoteUUID] {
            entity.merge(update: normalizedUpdate, defaultStatus: fallbackStatus)
            entitiesById[remoteUUID] = entity
        } else {
            entitiesById[remoteUUID] = NearbyEntity(update: normalizedUpdate, defaultStatus: fallbackStatus)
        }
        refreshEntities()
    }

    private func normalizedRemoteUUID(_ remoteUUID: String?) -> String? {
        guard let remoteUUID else {
            return nil
        }
        let normalizedUUID = remoteUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUUID.isEmpty else {
            return nil
        }
        return normalizedUUID
    }

    private func pruneStaleEntities() {
        guard !entitiesById.isEmpty else {
            return
        }

        let now = Date()
        let staleCutoff = now.addingTimeInterval(-staleEntityTimeout)
        let lostCutoff = now.addingTimeInterval(-4.0)

        let keysToRemove = entitiesById.compactMap { key, entity -> String? in
            if entity.status == "lost", entity.lastSeenAt < lostCutoff {
                return key
            }
            if !entity.connected, entity.lastSeenAt < staleCutoff {
                return key
            }
            return nil
        }
        guard !keysToRemove.isEmpty else {
            return
        }

        keysToRemove.forEach { key in
            entitiesById.removeValue(forKey: key)
        }
        refreshEntities()
    }

    private func refreshEntities() {
        entities = entitiesById.values.sorted { lhs, rhs in
            if lhs.connected != rhs.connected {
                return lhs.connected && !rhs.connected
            }
            let lhsDistance = lhs.distanceMeters ?? .greatestFiniteMagnitude
            let rhsDistance = rhs.distanceMeters ?? .greatestFiniteMagnitude
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }
}
