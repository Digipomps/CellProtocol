// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

public enum FlowCacheRunState: String, Codable {
    case idle
    case running
    case stopped
    case failed
}

public struct FlowCacheSnapshot {
    public let items: [FlowElement]
    public let capacity: Int
    public let totalReceived: Int
    public let droppedCount: Int
    public let isCompleted: Bool
}

/// A process-local, bounded replay hub. Registration and buffer snapshotting are
/// atomic, so a subscriber cannot miss a live value between replay and follow-on.
private final class FlowReplayHub: @unchecked Sendable {
    private final class ReplaySubscription: Subscription, @unchecked Sendable {
        private let stateLock = NSLock()
        private let downstream: AnySubscriber<FlowElement, Error>
        private var pending: [FlowElement]
        private var demand: Subscribers.Demand = .none
        private var completion: Subscribers.Completion<Error>?
        private var draining = false
        private var cancelled = false
        private var termination: (() -> Void)?

        init(
            downstream: AnySubscriber<FlowElement, Error>,
            replay: [FlowElement],
            completion: Subscribers.Completion<Error>?,
            termination: @escaping () -> Void
        ) {
            self.downstream = downstream
            self.pending = replay
            self.completion = completion
            self.termination = termination
        }

        func request(_ newDemand: Subscribers.Demand) {
            guard newDemand > .none else { return }
            stateLock.withLock {
                guard !cancelled else { return }
                demand += newDemand
            }
            drain()
        }

        func cancel() {
            let termination = stateLock.withLock { () -> (() -> Void)? in
                guard !cancelled else { return nil }
                cancelled = true
                pending.removeAll(keepingCapacity: false)
                let callback = self.termination
                self.termination = nil
                return callback
            }
            termination?()
        }

        func enqueue(_ element: FlowElement) {
            stateLock.withLock {
                guard !cancelled else { return }
                pending.append(element)
            }
            drain()
        }

        func finish(_ completion: Subscribers.Completion<Error>) {
            stateLock.withLock {
                guard !cancelled else { return }
                self.completion = completion
            }
            drain()
        }

        private func drain() {
            let shouldDrain = stateLock.withLock { () -> Bool in
                guard !cancelled, !draining else { return false }
                draining = true
                return true
            }
            guard shouldDrain else { return }

            while true {
                let next = stateLock.withLock { () -> FlowElement? in
                    guard !cancelled, demand > .none, !pending.isEmpty else { return nil }
                    if demand != .unlimited {
                        demand -= .max(1)
                    }
                    return pending.removeFirst()
                }

                if let next {
                    let additionalDemand = downstream.receive(next)
                    if additionalDemand > .none {
                        stateLock.withLock {
                            if !cancelled {
                                demand += additionalDemand
                            }
                        }
                    }
                    continue
                }

                let terminal = stateLock.withLock { () -> Subscribers.Completion<Error>? in
                    guard !cancelled, pending.isEmpty, let completion else {
                        draining = false
                        return nil
                    }
                    cancelled = true
                    draining = false
                    self.completion = nil
                    return completion
                }
                if let terminal {
                    downstream.receive(completion: terminal)
                    let termination = stateLock.withLock { () -> (() -> Void)? in
                        let callback = self.termination
                        self.termination = nil
                        return callback
                    }
                    termination?()
                }
                return
            }
        }
    }

    private struct ReplayPublisher: Publisher {
        typealias Output = FlowElement
        typealias Failure = Error

        let hub: FlowReplayHub

        func receive<S>(subscriber: S) where S: Subscriber, Error == S.Failure, FlowElement == S.Input {
            hub.register(AnySubscriber(subscriber))
        }
    }

    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "FlowReplayHub.Delivery")
    private var capacity: Int
    private var buffer: [FlowElement] = []
    private var totalReceived = 0
    private var droppedCount = 0
    private var completion: Subscribers.Completion<Error>?
    private var subscriptions: [UUID: ReplaySubscription] = [:]

    init(capacity: Int) {
        self.capacity = Self.clampedCapacity(capacity)
    }

    func publisher() -> AnyPublisher<FlowElement, Error> {
        ReplayPublisher(hub: self).eraseToAnyPublisher()
    }

    func send(_ element: FlowElement) {
        stateLock.withLock {
            guard completion == nil else { return }
            totalReceived += 1
            buffer.append(element)
            if buffer.count > capacity {
                let overflow = buffer.count - capacity
                buffer.removeFirst(overflow)
                droppedCount += overflow
            }
            let currentSubscriptions = Array(subscriptions.values)
            deliveryQueue.async {
                currentSubscriptions.forEach { $0.enqueue(element) }
            }
        }
    }

    func finish(_ completion: Subscribers.Completion<Error>) {
        stateLock.withLock {
            guard self.completion == nil else { return }
            self.completion = completion
            let currentSubscriptions = Array(subscriptions.values)
            deliveryQueue.async {
                currentSubscriptions.forEach { $0.finish(completion) }
            }
        }
    }

    func updateCapacity(_ requestedCapacity: Int) {
        stateLock.withLock {
            capacity = Self.clampedCapacity(requestedCapacity)
            if buffer.count > capacity {
                let overflow = buffer.count - capacity
                buffer.removeFirst(overflow)
                droppedCount += overflow
            }
        }
    }

    func snapshot() -> FlowCacheSnapshot {
        stateLock.withLock {
            FlowCacheSnapshot(
                items: buffer,
                capacity: capacity,
                totalReceived: totalReceived,
                droppedCount: droppedCount,
                isCompleted: completion != nil
            )
        }
    }

    private func register(_ subscriber: AnySubscriber<FlowElement, Error>) {
        let id = UUID()
        let subscription = stateLock.withLock { () -> ReplaySubscription in
            let subscription = ReplaySubscription(
                downstream: subscriber,
                replay: buffer,
                completion: completion,
                termination: { [weak self] in
                    self?.removeSubscription(id)
                }
            )
            if completion == nil {
                subscriptions[id] = subscription
            }
            return subscription
        }
        subscriber.receive(subscription: subscription)
    }

    private func removeSubscription(_ id: UUID) {
        stateLock.withLock {
            subscriptions[id] = nil
        }
    }

    private static func clampedCapacity(_ value: Int) -> Int {
        min(max(value, 1), 10_000)
    }
}

/// Optional cell that can be placed between an Emit source (including a bridge)
/// and local subscribers. It keeps one upstream subscription and replays only
/// the bounded data observed during this process lifetime.
public final class FlowCacheCell: GeneralCell {
    public static let defaultCapacity = 100

    private let cacheStateLock = NSLock()
    private var replayHub = FlowReplayHub(capacity: FlowCacheCell.defaultCapacity)
    private var configuredCapacity = FlowCacheCell.defaultCapacity
    private var configuredTarget: String?
    private var runState: FlowCacheRunState = .idle
    private var startedAt: Date?
    private var lastError: String?
    private var upstreamCancellable: AnyCancellable?
    private var cacheGeneration = UUID()

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        persistancy = .ephemeral
        name = "FlowCache"
        await setupPermissions()
        await setupExploreContract(owner: owner)
        await setupIntercepts(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        persistancy = .ephemeral
        Task {
            await self.setupPermissions()
            await self.setupExploreContract(owner: self.owner)
            await self.setupIntercepts(owner: self.owner)
        }
    }

    deinit {
        upstreamCancellable?.cancel()
    }

    public override func flow(requester: Identity) async throws -> AnyPublisher<FlowElement, Error> {
        guard await validateAccess("r---", at: "flowCache", for: requester) else {
            throw StreamState.denied
        }
        return cacheStateLock.withLock { replayHub.publisher() }
    }

    public func startCaching(
        upstream: Emit,
        requester: Identity,
        targetEndpoint: String? = nil
    ) async throws {
        guard await validateAccess("-w--", at: "flowCache", for: requester) else {
            throw StreamState.denied
        }
        let upstreamFlow = try await upstream.flow(requester: requester)
        let setup = cacheStateLock.withLock { () -> (hub: FlowReplayHub, previous: AnyCancellable?, generation: UUID) in
            let previous = upstreamCancellable
            upstreamCancellable = nil
            let hub = FlowReplayHub(capacity: configuredCapacity)
            let generation = UUID()
            cacheGeneration = generation
            replayHub = hub
            configuredTarget = targetEndpoint
            runState = .running
            startedAt = Date()
            lastError = nil
            return (hub, previous, generation)
        }
        setup.previous?.cancel()
        let newHub = setup.hub
        let generation = setup.generation
        let cancellable = upstreamFlow.sink(
            receiveCompletion: { [weak self, weak newHub] completion in
                newHub?.finish(completion)
                self?.cacheStateLock.withLock {
                    guard self?.cacheGeneration == generation else { return }
                    switch completion {
                    case .finished:
                        self?.runState = .stopped
                    case let .failure(error):
                        self?.runState = .failed
                        self?.lastError = error.localizedDescription
                    }
                    self?.upstreamCancellable = nil
                }
            },
            receiveValue: { [weak newHub] element in
                newHub?.send(element)
            }
        )
        cacheStateLock.withLock {
            if cacheGeneration == generation, runState == .running {
                upstreamCancellable = cancellable
            } else {
                cancellable.cancel()
            }
        }
    }

    public func startCaching(endpoint: String, requester: Identity) async throws {
        guard let resolver = CellBase.defaultCellResolver else {
            throw FlowError.noResolver
        }
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEndpoint.isEmpty else {
            throw CellBaseError.noTargetCell
        }
        let upstream = try await resolver.cellAtEndpoint(endpoint: normalizedEndpoint, requester: requester)
        try await startCaching(
            upstream: upstream,
            requester: requester,
            targetEndpoint: normalizedEndpoint
        )
    }

    public func stopCaching() {
        let stopped = cacheStateLock.withLock { () -> (hub: FlowReplayHub, cancellable: AnyCancellable?) in
            let cancellable = upstreamCancellable
            upstreamCancellable = nil
            cacheGeneration = UUID()
            if runState == .running {
                runState = .stopped
            }
            return (replayHub, cancellable)
        }
        stopped.cancellable?.cancel()
        stopped.hub.finish(.finished)
    }

    public func clearCache() {
        let cleared = cacheStateLock.withLock { () -> (hub: FlowReplayHub, cancellable: AnyCancellable?) in
            let cancellable = upstreamCancellable
            upstreamCancellable = nil
            let previousHub = replayHub
            cacheGeneration = UUID()
            replayHub = FlowReplayHub(capacity: configuredCapacity)
            runState = .idle
            startedAt = nil
            lastError = nil
            return (previousHub, cancellable)
        }
        cleared.cancellable?.cancel()
        cleared.hub.finish(.finished)
    }

    public func cacheSnapshot() -> FlowCacheSnapshot {
        cacheStateLock.withLock { replayHub.snapshot() }
    }

    private func setupPermissions() async {
        agreementTemplate.addGrant("rw--", for: "flowCache")
    }

    private func setupExploreContract(owner: Identity) async {
        let statusSchema: ValueType = .object([
            "status": .string("idle|running|stopped|failed"),
            "target": .string("cell endpoint or empty"),
            "capacity": .string("integer 1...10000"),
            "cachedCount": .string("integer"),
            "totalReceived": .string("integer"),
            "droppedCount": .string("integer"),
            "replayScope": .string("process-local")
        ])
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.status",
            schema: statusSchema,
            description: .string("Bounded process-local cache status; does not promise reconnect replay.")
        )
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.target.current",
            schema: .string("cell endpoint or empty")
        )
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.items",
            schema: .list([.flowElement(FlowElement())])
        )
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.target",
            schema: .string("cell endpoint")
        )
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.capacity",
            schema: .integer(FlowCacheCell.defaultCapacity)
        )
        await registerExploreSchema(
            requester: owner,
            key: "flowCache.start",
            schema: .string("optional cell endpoint")
        )
        await registerExploreSchema(requester: owner, key: "flowCache.stop", schema: .null)
        await registerExploreSchema(requester: owner, key: "flowCache.clear", schema: .null)
    }

    private func setupIntercepts(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "flowCache.status") { [weak self] _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            return self.statusPayload()
        }
        await addInterceptForGet(requester: owner, key: "flowCache.target.current") { [weak self] _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            return .string(self.cacheStateLock.withLock { self.configuredTarget ?? "" })
        }
        await addInterceptForGet(requester: owner, key: "flowCache.items") { [weak self] _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("r---", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            return .list(self.cacheSnapshot().items.map(ValueType.flowElement))
        }
        await addInterceptForSet(requester: owner, key: "flowCache.target") { [weak self] _, value, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            guard case let .string(endpoint) = value,
                  !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .object(["status": .string("error"), "message": .string("Expected a target endpoint string.")])
            }
            self.cacheStateLock.withLock {
                self.configuredTarget = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return .string(endpoint)
        }
        await addInterceptForSet(requester: owner, key: "flowCache.capacity") { [weak self] _, value, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            guard case let .integer(capacity) = value else {
                return .object(["status": .string("error"), "message": .string("Expected an integer capacity.")])
            }
            let clamped = min(max(capacity, 1), 10_000)
            self.cacheStateLock.withLock {
                self.configuredCapacity = clamped
                self.replayHub.updateCapacity(clamped)
            }
            return .integer(clamped)
        }
        await addInterceptForSet(requester: owner, key: "flowCache.start") { [weak self] _, value, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            let inlineEndpoint: String?
            if case let .string(value) = value,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inlineEndpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                inlineEndpoint = nil
            }
            guard let endpoint = inlineEndpoint ?? self.cacheStateLock.withLock({ self.configuredTarget }) else {
                return .object(["status": .string("error"), "message": .string("Configure flowCache.target before starting.")])
            }
            do {
                try await self.startCaching(endpoint: endpoint, requester: requester)
                return self.statusPayload()
            } catch {
                return .object(["status": .string("error"), "message": .string(error.localizedDescription)])
            }
        }
        await addInterceptForSet(requester: owner, key: "flowCache.stop") { [weak self] _, _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            self.stopCaching()
            return self.statusPayload()
        }
        await addInterceptForSet(requester: owner, key: "flowCache.clear") { [weak self] _, _, requester in
            guard let self else { return .null }
            guard await self.validateAccess("-w--", at: "flowCache", for: requester) else {
                return .string("denied")
            }
            self.clearCache()
            return self.statusPayload()
        }
    }

    private func statusPayload() -> ValueType {
        cacheStateLock.withLock {
            let snapshot = replayHub.snapshot()
            return .object([
                "status": .string(runState.rawValue),
                "target": .string(configuredTarget ?? ""),
                "capacity": .integer(snapshot.capacity),
                "cachedCount": .integer(snapshot.items.count),
                "totalReceived": .integer(snapshot.totalReceived),
                "droppedCount": .integer(snapshot.droppedCount),
                "startedAt": .string(startedAt.map(Self.isoTimestamp) ?? ""),
                "lastError": .string(lastError ?? ""),
                "replayScope": .string("process-local"),
                "reconnectReplayGuaranteed": .bool(false)
            ])
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
