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

/// Wall-clock epoch ticks for lifecycle deadlines that must survive restarts
/// (durable state store). `SystemMonotonicTimeSource` restarts at 0 with each
/// process and therefore cannot be combined with persisted deadlines.
/// The clock is only read here, never in the reducer, and never goes backwards
/// within a process (`floorTick` also lets callers carry a persisted floor
/// across restarts). Downtime counts towards TTL, which is the intent for
/// retention deadlines.
public final class WallClockEpochTimeSource: MonotonicTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private let tickDurationSeconds: Double
    private let now: @Sendable () -> Date
    private var lastTick: UInt64

    public init(
        tickDurationSeconds: Double = 1,
        floorTick: UInt64 = 0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(tickDurationSeconds > 0, "tickDurationSeconds must be > 0")
        self.tickDurationSeconds = tickDurationSeconds
        self.now = now
        self.lastTick = floorTick
    }

    public func nowTick() -> UInt64 {
        let seconds = max(0, now().timeIntervalSince1970)
        let tick = UInt64(seconds / tickDurationSeconds)
        lock.lock()
        defer { lock.unlock() }
        if tick > lastTick {
            lastTick = tick
        }
        return lastTick
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
