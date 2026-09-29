// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Process-wide admission at the synchronous WebSocketKit callback boundary.
/// This is additional transport accounting; it does not replace gate quotas.
final class VaporBridgeReceiveBudget: @unchecked Sendable {
    static let shared = VaporBridgeReceiveBudget()
    static let connectionCountLimit = 64
    static let connectionByteLimit = 4 * 1024 * 1024
    private let lock = NSLock()
    private let maximumCount: Int
    private let maximumBytes: Int
    private var count = 0
    private var bytes = 0

    init(maximumCount: Int = 1024, maximumBytes: Int = 32 * 1024 * 1024) {
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    func acquire(bytes size: Int) -> Bool {
        lock.withLock {
            guard size >= 0, count < maximumCount, size <= maximumBytes - bytes else { return false }
            count += 1; bytes += size
            return true
        }
    }

    func release(bytes size: Int) {
        lock.withLock { count -= 1; bytes -= size }
    }

    var snapshot: (count: Int, bytes: Int) { lock.withLock { (count, bytes) } }
}
