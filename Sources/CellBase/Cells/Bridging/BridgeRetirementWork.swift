// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Work admitted by one bridge lifetime. Cancellation never releases a slot;
/// only return from the complete operation does. A retired lifetime stays shut.
final class BridgeRetirementWork: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var bytes = 0
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private let maximumCount = 64
    private let maximumBytes = 4 * 1024 * 1024

    @discardableResult
    func submit(bytes cost: Int = 0, _ operation: @escaping () async -> Void) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, cost >= 0, jobs.count < maximumCount,
              cost <= maximumBytes - bytes else { return nil }
        return start(cost: cost, operation)
    }

    /// Serial encoding plus admission, before retaining Data in a new Task.
    @discardableResult
    func submitEncoded(_ encode: () throws -> Data, send: @escaping (Data) async -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, jobs.count < maximumCount,
              let data = try? encode(), data.count <= 1024 * 1024,
              data.count <= maximumBytes - bytes else { return false }
        _ = start(cost: data.count) { await send(data) }
        return true
    }

    private func start(cost: Int, _ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        bytes += cost
        let task = Task { [self] in
            await operation()
            complete(id, cost: cost)
        }
        jobs[id] = task
        return task
    }
    private func complete(_ id: UUID, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        jobs[id] = nil; bytes -= cost
    }
    func requestStop() {
        lock.lock(); closed = true; let tasks = Array(jobs.values); lock.unlock()
        tasks.forEach { $0.cancel() }
    }
    func finishStop() async {
        requestStop()
        for task in snapshot() { await task.value }
    }
    private func snapshot() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }; return Array(jobs.values)
    }
}
