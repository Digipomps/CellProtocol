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

    private var ledger = RadarEntityLedger()
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
        ledger.clear()
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
        ledger.consume(scannerEvent)
        if case let .status(update) = scannerEvent, let status = update.status, !status.isEmpty {
            scannerStatus = status
        }
        connectedDevices = ledger.connectedDevices
        refreshEntities()
    }

    private func pruneStaleEntities() {
        // The ledger's own staleness plus the view's quicker drop of «lost».
        ledger.staleAfter = staleEntityTimeout
        let lostCutoff = Date().addingTimeInterval(-4.0)
        var removed = ledger.prune()
        for entity in ledger.entities where entity.status == "lost" && entity.lastSeenAt < lostCutoff {
            ledger.remove(entity.remoteUUID)
            removed.append(entity.remoteUUID)
        }
        if !removed.isEmpty || entities.count != ledger.entities.count {
            refreshEntities()
        }
    }

    private func refreshEntities() {
        entities = ledger.entities
    }
}
