// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase

/// Local, immutable authority/lifetime context; never reconstructed from payload IDs.
/// The gate owns the work lease until the async delegate actually returns.
final class ScannerConsumerContext: @unchecked Sendable {
    private weak var service: ScannerService?
    let physical: ScannerPeerTransport
    let session: BridgeChannelSession
    let localIdentity: BridgeChannelAuthentication.PublicIdentity
    let identity: BridgeChannelAuthentication.PublicIdentity
    let localUUID: String
    let remoteUUID: String
    let generation: String
    let setupID: String

    init(service: ScannerService, physical: ScannerPeerTransport) throws {
        self.service = service; self.physical = physical
        localIdentity = try BridgeChannelAuthentication.PublicIdentity(service.owner)
        session = physical.gate.session
        guard let endpoint = session.peerEndpoint, let identity = session.publicIdentity else { throw CancellationError() }
        self.identity = identity
        setupID = endpoint.setupID
        localUUID = service.mySessionUUID; remoteUUID = physical.remoteUUID
        generation = session.generation
        try check()
    }

    var isLive: Bool { (try? perform {}) != nil }
    func check() throws {
        try Task.checkCancellation()
        try perform {}
    }
    func perform<T>(_ body: () throws -> T) throws -> T {
        guard let service else { throw CancellationError() }
        return try service.consumerEffect(on: physical, body)
    }
    func matches(_ other: ScannerConsumerContext) -> Bool {
        session === other.session && physical === other.physical && generation == other.generation && identity == other.identity
    }
}

/// One combined budget for all incoming/outgoing contact and probe records.
/// Consumed entries are bounded tombstones until their original TTL, preventing
/// a second effect from a replay. Retirement removes the whole generation.
@MainActor final class ScannerPendingRequests {
    enum Kind: Hashable { case incoming, outgoing, detail, outgoingAggregate, outgoingDetail }
    struct Key: Hashable { let kind: Kind; let generation: String; let id: String }
    struct Record {
        let context: ScannerConsumerContext
        let payload: Object
        let bytes: Int
        let deadline: TimeInterval
        var consumed = false
    }
    static let maximumCount = 128
    static let maximumPerPeer = 16
    static let maximumBytes = 1024 * 1024
    static let maximumBytesPerPeer = 128 * 1024
    static let maximumPayloadBytes = 64 * 1024
    static let ttl: TimeInterval = 60
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var records: [Key: Record] = [:]
    var expired: ((Kind, Record) -> Void)?
    private var expiryTask: Task<Void, Never>?

    func prune() {
        let now = clock()
        let removed = records.filter { now >= $0.value.deadline || !$0.value.context.isLive }
        records = records.filter { now < $0.value.deadline && $0.value.context.isLive }
        for (key, record) in removed where !record.consumed { expired?(key.kind, record) }
    }
    func retire(_ generation: String) { records = records.filter { $0.key.generation != generation } }
    func reset() { records.removeAll(); expiryTask?.cancel(); expiryTask = nil }
    var retainedCountForTesting: Int { records.count }
    var snapshot: (count: Int, bytes: Int) { prune(); return (records.count, records.values.reduce(0) { $0 + $1.bytes }) }

    func insert(_ kind: Kind, id: String, payload: Object, context: ScannerConsumerContext, lifetime: TimeInterval? = nil) throws {
        prune()
        let key = Key(kind: kind, generation: context.generation, id: id)
        let payload = try JSONDecoder().decode(Object.self, from: JSONEncoder().encode(payload))
        let bytes = try FlowCanonicalEncoder.canonicalData(for: .object(payload)).count
        let peer = records.values.filter { $0.context.remoteUUID == context.remoteUUID }
        guard !id.isEmpty, id.utf8.count <= 128, records[key] == nil,
              bytes <= Self.maximumPayloadBytes, records.count < Self.maximumCount,
              peer.count < Self.maximumPerPeer,
              bytes <= Self.maximumBytes - records.values.reduce(0, { $0 + $1.bytes }),
              bytes <= Self.maximumBytesPerPeer - peer.reduce(0, { $0 + $1.bytes }) else {
            throw BridgeChannelAuthentication.Failure.capacity
        }
        try context.perform { records[key] = Record(context: context, payload: payload, bytes: bytes, deadline: clock() + min(Self.ttl, max(0, lifetime ?? Self.ttl))) }
        if expiryTask == nil {
            expiryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    self.prune()
                    if self.records.isEmpty { self.expiryTask = nil; return }
                }
            }
        }
    }
    func remove(_ kind: Kind, id: String, context: ScannerConsumerContext) {
        records[Key(kind: kind, generation: context.generation, id: id)] = nil
    }
    func find(_ kind: Kind, id: String, context: ScannerConsumerContext) -> Record? {
        prune()
        guard let record = records[Key(kind: kind, generation: context.generation, id: id)],
              !record.consumed, record.context.matches(context) else { return nil }
        return record
    }
    func consume(_ kind: Kind, id: String, context: ScannerConsumerContext) throws -> Record {
        guard let record = find(kind, id: id, context: context) else { throw BridgeChannelAuthentication.Failure.invalidProof }
        try context.perform { records[Key(kind: kind, generation: context.generation, id: id)]?.consumed = true }
        return record
    }
}
