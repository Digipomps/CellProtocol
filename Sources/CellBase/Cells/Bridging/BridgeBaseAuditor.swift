// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 07/12/2022.
//

import Foundation

/// The Base supplies its lifecycle lock so lookup/consumption, publication and
/// retirement can share one synchronous decision. Standalone auditors own a lock.
final class BridgeBaseAuditor: @unchecked Sendable {
    private let lock: NSRecursiveLock
    private struct RegisteredCommand {
        var command: BridgeCommand
        var storedAt: Date
        var bytes: Int
    }

    private var commandRegistry = [Int: RegisteredCommand]()
    private var commandId = 0
    private let maximumPendingCommands: Int
    // Loopback lifecycle: a retired auditor admits nothing, and the registry is
    // bounded by encoded size as well as by count.
    private var retired = false
    private let maximumCommandBytes = 1024 * 1024
    private let maximumBytes = 4 * 1024 * 1024
    private let commandRetentionSeconds: TimeInterval

    init(commandRetentionSeconds: TimeInterval = 300, maximumPendingCommands: Int = 256, lock: NSRecursiveLock = NSRecursiveLock()) {
        self.lock = lock
        self.maximumPendingCommands = max(1, maximumPendingCommands)
        self.commandRetentionSeconds = max(1, commandRetentionSeconds)
    }
    
    func getNewCommandId() -> Int {
        lock.lock(); defer { lock.unlock() }
        commandId = commandId + 1
        return commandId
    }
    
    @discardableResult
    func storeBridgeCommand(_ command: BridgeCommand?, for commandId: Int, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeExpired(now: now)
        guard let command else {
            commandRegistry[commandId] = nil
            return true
        }
        guard !retired, let data = try? JSONEncoder().encode(command), data.count <= maximumCommandBytes else { return false }
        let old = commandRegistry[commandId]
        let count = commandRegistry.count - (old == nil ? 0 : 1)
        let bytes = commandRegistry.values.reduce(0) { $0 + $1.bytes } - (old?.bytes ?? 0)
        guard count < maximumPendingCommands, data.count <= maximumBytes - bytes else { return false }
        commandRegistry[commandId] = RegisteredCommand(command: command, storedAt: now, bytes: data.count)
        return true
    }

    /// Retirement is one synchronous decision under the shared lifecycle lock:
    /// later stores are refused and every pending reference is released.
    func retire() {
        lock.withLock {
            retired = true
            commandRegistry.removeAll()
        }
    }

    var isRetired: Bool { lock.withLock { retired } }

    func loadBridgeCommandForCommandId(_ commandId: Int, now: Date = Date()) -> BridgeCommand? {
        lock.lock(); defer { lock.unlock() }
        purgeExpired(now: now)
        return commandRegistry[commandId]?.command
    }

    func takeBridgeCommandForCommandId(_ commandId: Int, now: Date = Date()) -> BridgeCommand? {
        lock.lock(); defer { lock.unlock() }
        purgeExpired(now: now)
        let command = commandRegistry[commandId]?.command
        commandRegistry[commandId] = nil
        return command
    }

    func removeBridgeCommand(for commandId: Int) {
        lock.lock(); defer { lock.unlock() }
        commandRegistry[commandId] = nil
    }

    func pendingCommandCount(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        purgeExpired(now: now)
        return commandRegistry.count
    }

    func clear() { lock.withLock { commandRegistry.removeAll() } }

    private func purgeExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-commandRetentionSeconds)
        commandRegistry = commandRegistry.filter { _, entry in
            entry.command.command == .feed || entry.storedAt >= cutoff
        }
    }
}
