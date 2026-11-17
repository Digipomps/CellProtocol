// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Durable storage for the P1 runtime lifecycle authority, so TTL deadlines,
// warnings and tombstone grace windows survive a restart.
//
// Layout: one JSON file per entry, named by the hex encoding of the ID (no
// path characters ever reach the file system). Writes are atomic
// (write-to-temp + rename). Loading fails closed: a file that cannot be
// decoded throws instead of being skipped, because skipping it would silently
// drop a deletion deadline.

public enum RuntimeLifecycleDurableStoreError: Error, Sendable, Equatable {
    case unreadableEntry(file: String, reason: String)
    case writeFailed(file: String, reason: String)
}

enum RuntimeLifecycleDurableFiles {
    static func fileName(for identifier: String) -> String {
        identifier.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func loadAll<T: Decodable>(_ type: T.Type, from directory: URL) throws -> [T] {
        try ensureDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        return try files.map { file in
            do {
                return try decoder.decode(T.self, from: Data(contentsOf: file))
            } catch {
                throw RuntimeLifecycleDurableStoreError.unreadableEntry(
                    file: file.lastPathComponent,
                    reason: String(describing: error)
                )
            }
        }
    }

    static func write<T: Encodable>(_ value: T, identifier: String, in directory: URL) throws {
        let file = directory.appendingPathComponent(fileName(for: identifier))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: file, options: .atomic)
        } catch {
            throw RuntimeLifecycleDurableStoreError.writeFailed(
                file: file.lastPathComponent,
                reason: String(describing: error)
            )
        }
    }
}

/// File-backed `RuntimeLifecycleStateStore`. Every successful CAS is written
/// to disk before it becomes visible; a failed write leaves state unchanged
/// and the CAS returns `false`.
public actor FileRuntimeLifecycleStateStore: RuntimeLifecycleStateStore {
    private let directoryURL: URL
    private var states = [RuntimeCellID: RuntimeLifecycleState]()

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        for state in try RuntimeLifecycleDurableFiles.loadAll(RuntimeLifecycleState.self, from: directoryURL) {
            states[state.cellID] = state
        }
    }

    public func read(cellID: RuntimeCellID) async -> RuntimeLifecycleState? {
        states[cellID]
    }

    public func putIfAbsent(_ state: RuntimeLifecycleState) async -> Bool {
        guard states[state.cellID] == nil else {
            return false
        }
        guard persist(state) else {
            return false
        }
        states[state.cellID] = state
        return true
    }

    public func compareAndSwap(
        cellID: RuntimeCellID,
        expectedVersion: UInt64,
        next: RuntimeLifecycleState
    ) async -> Bool {
        guard let current = states[cellID], current.version == expectedVersion else {
            return false
        }
        guard persist(next) else {
            return false
        }
        states[cellID] = next
        return true
    }

    public func snapshotStates() async -> [RuntimeLifecycleState] {
        states.values.sorted { $0.cellID.rawValue < $1.cellID.rawValue }
    }

    private func persist(_ state: RuntimeLifecycleState) -> Bool {
        do {
            try RuntimeLifecycleDurableFiles.ensureDirectory(directoryURL)
            try RuntimeLifecycleDurableFiles.write(state, identifier: state.cellID.rawValue, in: directoryURL)
            return true
        } catch {
            return false
        }
    }
}

/// Stores the descriptors (owner, class, storage locations) of resources under
/// runtime authority, so owner checks and deletion targets survive a restart.
public protocol RuntimeResourceDescriptorStore: Sendable {
    func save(_ descriptor: RuntimeResourceDescriptor) async throws
    func loadAll() async throws -> [RuntimeResourceDescriptor]
}

public actor InMemoryRuntimeResourceDescriptorStore: RuntimeResourceDescriptorStore {
    private var descriptors = [String: RuntimeResourceDescriptor]()

    public init() {}

    public func save(_ descriptor: RuntimeResourceDescriptor) async throws {
        descriptors[descriptor.resourceID] = descriptor
    }

    public func loadAll() async throws -> [RuntimeResourceDescriptor] {
        descriptors.values.sorted { $0.resourceID < $1.resourceID }
    }
}

public actor FileRuntimeResourceDescriptorStore: RuntimeResourceDescriptorStore {
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func save(_ descriptor: RuntimeResourceDescriptor) async throws {
        try RuntimeLifecycleDurableFiles.ensureDirectory(directoryURL)
        try RuntimeLifecycleDurableFiles.write(descriptor, identifier: descriptor.resourceID, in: directoryURL)
    }

    public func loadAll() async throws -> [RuntimeResourceDescriptor] {
        try RuntimeLifecycleDurableFiles.loadAll(RuntimeResourceDescriptor.self, from: directoryURL)
            .sorted { $0.resourceID < $1.resourceID }
    }
}

/// Summary of `RuntimeLifecycleAuthority.recover()`.
public struct RuntimeLifecycleRecoveryReport: Sendable, Equatable {
    public var recoveredResourceIDs: [String]
    public var activeResourceIDs: [String]
    public var tombstonedResourceIDs: [String]
    public var deletedResourceIDs: [String]
    /// Stored states without a descriptor. They keep their timers, but
    /// effects cannot reach storage until the descriptor is re-registered.
    public var statesWithoutDescriptor: [String]
}
