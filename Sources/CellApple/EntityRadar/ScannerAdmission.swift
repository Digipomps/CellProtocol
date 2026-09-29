// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import MultipeerConnectivity

/// Process-wide pre-authentication budgets. An MCPeerID is physical transport
/// context, NOT a verified device or person; a Sybil can exhaust the global cap.
/// No attacker-supplied UUID/displayName creates a quota bucket.
final class ScannerAdmission {
    enum Kind: CaseIterable { case discovery, invitation, task, event }
    struct Budget {
        var count: Int
        var bytes: Int
        var perSourceCount: Int
        var perSourceBytes: Int
        var lifetime: TimeInterval
    }
    struct Configuration {
        var discovery = Budget(count: 128, bytes: 128 * 1024, perSourceCount: 1, perSourceBytes: 4096, lifetime: 60)
        var invitation = Budget(count: 32, bytes: 64 * 1024, perSourceCount: 1, perSourceBytes: 4096, lifetime: 30)
        var task = Budget(count: 16, bytes: 64 * 1024, perSourceCount: 2, perSourceBytes: 8192, lifetime: 10)
        var event = Budget(count: 64, bytes: 64 * 1024, perSourceCount: 8, perSourceBytes: 8192, lifetime: 5)
        var maximumSources = 256
        var rateWindow: TimeInterval = 10
        var sourceLifetime: TimeInterval = 60
        var rate = 256
        var perSourceRate = 24
        func budget(_ kind: Kind) -> Budget {
            switch kind { case .discovery: return discovery; case .invitation: return invitation; case .task: return task; case .event: return event }
        }
    }
    struct Usage { var count = 0; var bytes = 0 }
    private struct Source {
        let id = UUID().uuidString
        var lastSeen: TimeInterval
        var window: TimeInterval
        var rate = 0
        var usage: [Kind: Usage] = [:]
    }
    final class Lease {
        fileprivate let id = UUID()
        fileprivate let owner: ScannerAdmission
        fileprivate let peer: MCPeerID
        fileprivate let kind: Kind
        fileprivate var bytes: Int
        fileprivate var released = false
        fileprivate var deadline: TimeInterval
        let source: String
        var isLive: Bool { owner.lock.withLock { !released && owner.now() < deadline } }
        fileprivate init(owner: ScannerAdmission, peer: MCPeerID, kind: Kind, bytes: Int, source: String, deadline: TimeInterval) {
            self.owner = owner; self.peer = peer; self.kind = kind; self.bytes = bytes; self.source = source; self.deadline = deadline
        }
        func release() { owner.release(self) }
        deinit { release() }
    }
    static let shared = ScannerAdmission()
    let configuration: Configuration
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var sources: [MCPeerID: Source] = [:]
    private var usage: [Kind: Usage] = [:]
    private var window: TimeInterval = 0
    private var rate = 0

    init(configuration: Configuration = .init(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration; self.now = now
    }
    func snapshot(_ kind: Kind) -> Usage { lock.withLock { usage[kind, default: Usage()] } }
    var sourceCount: Int { lock.withLock { purge(); return sources.count } }

    /// Acquire before retaining metadata/handler, allocating a Task, or queuing
    /// a UI event. Replacement is atomic and cannot transiently exceed a budget.
    func reserve(_ kind: Kind, peer: MCPeerID, bytes: Int, replacing old: Lease? = nil) -> Lease? {
        lock.withLock {
            purge()
            let time = now(), budget = configuration.budget(kind)
            guard bytes >= 0, bytes <= budget.perSourceBytes, bytes <= budget.bytes else { return nil }
            if time >= window + configuration.rateWindow { window = time; rate = 0 }
            guard rate < configuration.rate else { return nil }
            rate += 1 // rejected capacity attempts consume rate too
            guard sources[peer] != nil || sources.count < configuration.maximumSources else { return nil }
            var source = sources[peer] ?? Source(lastSeen: time, window: time)
            if time >= source.window + configuration.rateWindow { source.window = time; source.rate = 0 }
            guard source.rate < configuration.perSourceRate else { return nil }
            source.rate += 1; source.lastSeen = time; sources[peer] = source
            let replace = old.map { $0.owner === self && $0.peer == peer && $0.kind == kind && !$0.released } == true
            let oldBytes = replace ? old!.bytes : 0, oldCount = replace ? 1 : 0
            let total = usage[kind, default: Usage()], local = source.usage[kind, default: Usage()]
            guard total.count - oldCount < budget.count, local.count - oldCount < budget.perSourceCount,
                  bytes <= budget.bytes - (total.bytes - oldBytes), bytes <= budget.perSourceBytes - (local.bytes - oldBytes) else { return nil }
            if replace { old!.released = true }
            usage[kind] = Usage(count: total.count + 1 - oldCount, bytes: total.bytes + bytes - oldBytes)
            source.usage[kind] = Usage(count: local.count + 1 - oldCount, bytes: local.bytes + bytes - oldBytes)
            sources[peer] = source
            return Lease(owner: self, peer: peer, kind: kind, bytes: bytes, source: source.id, deadline: time + budget.lifetime)
        }
    }
    private func release(_ lease: Lease) {
        lock.withLock {
            guard !lease.released else { return }
            lease.released = true
            usage[lease.kind, default: Usage()].count -= 1
            usage[lease.kind, default: Usage()].bytes -= lease.bytes
            sources[lease.peer]?.usage[lease.kind, default: Usage()].count -= 1
            sources[lease.peer]?.usage[lease.kind, default: Usage()].bytes -= lease.bytes
        }
    }
    private func purge() {
        let time = now()
        sources = sources.filter { _, source in
            source.usage.values.contains { $0.count > 0 } || time < source.lastSeen + max(configuration.sourceLifetime, configuration.rateWindow)
        }
    }
}
