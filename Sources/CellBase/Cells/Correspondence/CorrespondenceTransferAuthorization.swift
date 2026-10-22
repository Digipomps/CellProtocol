// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Synchronous effect fence shared by membership invalidation and attachment I/O.
/// Never persisted, transported, or exposed as a general Cell capability.
final class CorrespondenceTransferAuthorization: @unchecked Sendable {
    private let lock: NSRecursiveLock
    private let session: BridgeChannelSession?
    private let validate: () throws -> Void
    init(lock: NSRecursiveLock, session: BridgeChannelSession?, validate: @escaping () throws -> Void) {
        self.lock = lock; self.session = session; self.validate = validate
    }
    func perform<T>(_ effect: () throws -> T) throws -> T {
        try lock.withLock {
            try validate()
            if let session { return try session.withAuthenticatedEffect(effect) }
            return try effect()
        }
    }
}
