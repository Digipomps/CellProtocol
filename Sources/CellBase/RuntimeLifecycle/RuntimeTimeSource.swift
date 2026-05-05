// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Monotonic time abstraction for runtime-only lifecycle operations.
/// No wall clock timestamps are used by state transitions.
public protocol MonotonicTimeSource: Sendable {
    /// Monotonic tick count. Tick unit is defined by runtime configuration.
    func nowTick() -> UInt64
}

/// Monotonic uptime-backed time source for production runtime lifecycle scheduling.
/// Tick duration defaults to one second.
public final class SystemMonotonicTimeSource: MonotonicTimeSource, @unchecked Sendable {
    private let startUptimeNanoseconds: UInt64
    private let tickDurationNanoseconds: UInt64

    public init(tickDurationNanoseconds: UInt64 = 1_000_000_000) {
        precondition(tickDurationNanoseconds > 0, "tickDurationNanoseconds must be > 0")
        self.startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.tickDurationNanoseconds = tickDurationNanoseconds
    }

    public func nowTick() -> UInt64 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startUptimeNanoseconds
        return elapsed / tickDurationNanoseconds
    }
}

/// Deterministic/manual time for tests and replay simulations.
public final class DeterministicTimeSource: MonotonicTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64

    public init(initialTick: UInt64 = 0) {
        self.tick = initialTick
    }

    public func nowTick() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return tick
    }

    public func advance(by delta: UInt64 = 1) {
        lock.lock()
        tick &+= delta
        lock.unlock()
    }

    public func setTick(_ value: UInt64) {
        lock.lock()
        tick = value
        lock.unlock()
    }
}
