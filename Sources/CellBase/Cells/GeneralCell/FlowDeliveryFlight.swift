// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Extends the existing forwarding reservation through asynchronous subscriber
/// authorization. Captured synchronously before buffering; never encoded on wire.
final class FlowDeliveryFlight: @unchecked Sendable {
    @TaskLocal static var current: FlowDeliveryFlight?
    private let lock = NSLock()
    private let valid: () -> Bool
    private var pending = 1
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(valid: @escaping () -> Bool) { self.valid = valid }

    func reserve() -> Ticket {
        lock.withLock { pending += 1 }
        return Ticket(flight: self)
    }

    func finishScheduling() { release() }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pending == 0 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    private func release() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            pending -= 1
            guard pending == 0 else { return [] }
            defer { waiters.removeAll() }
            return waiters
        }
        ready.forEach { $0.resume() }
    }

    final class Ticket {
        private let lock = NSLock()
        private var flight: FlowDeliveryFlight?
        fileprivate init(flight: FlowDeliveryFlight) { self.flight = flight }
        func shouldDeliver() -> Bool { lock.withLock { flight }?.valid() == true }
        func finish() {
            let flight = lock.withLock { () -> FlowDeliveryFlight? in
                defer { self.flight = nil }
                return self.flight
            }
            flight?.release()
        }
        deinit { finish() }
    }
}
