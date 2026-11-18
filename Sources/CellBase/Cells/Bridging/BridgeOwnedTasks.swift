// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One terminal transport lifetime. Work is charged until its body returns,
/// including cancellation. One external owner closes physical I/O before join.
final class BridgeOwnedTasks: @unchecked Sendable {
    private struct Entry {
        let cancel: () -> Void
        let join: () async -> Void
        let bytes: Int
    }
    private let lock = NSLock()
    private var closed = false
    private let maximumTasks: Int
    private let maximumBytes: Int
    init(maximumTasks: Int = 64, maximumBytes: Int = 4 * 1024 * 1024) {
        precondition(maximumTasks > 0 && maximumBytes > 0)
        self.maximumTasks = maximumTasks; self.maximumBytes = maximumBytes
    }
    private var bytes = 0
    private var entries: [UUID: Entry] = [:]
    var isClosed: Bool { lock.withLock { closed } }
    func submit<T>(bytes cost: Int = 0, _ operation: @escaping () async throws -> T) -> Task<T, Error>? {
        lock.withLock {
            guard !closed, cost >= 0, entries.count < maximumTasks,
                  cost <= maximumBytes - bytes else { return nil }
            let id = UUID()
            bytes += cost
            let task = Task {
                defer { self.complete(id) }
                return try await operation()
            }
            entries[id] = Entry(cancel: { task.cancel() }, join: { _ = try? await task.value }, bytes: cost)
            return task
        }
    }
    private func complete(_ id: UUID) {
        lock.withLock { if let entry = entries.removeValue(forKey: id) { bytes -= entry.bytes } }
    }
    func requestStop() {
        let all = lock.withLock { closed = true; return Array(entries.values) }
        all.forEach { $0.cancel() }
    }
    func finishStop() async {
        requestStop()
        let all = lock.withLock { Array(entries.values) }
        for entry in all { await entry.join() }
    }
}
