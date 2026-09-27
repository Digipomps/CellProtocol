// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  File.swift
//  
//
//  Created by Kjetil Hustveit on 07/12/2022.
//

import Foundation

actor BridgeBaseAuditor {
    private struct RegisteredCommand {
        var command: BridgeCommand
        var storedAt: Date
    }

    private var commandRegistry = [Int: RegisteredCommand]()
    private var commandId = 0
    private let maximumPendingCommands: Int
    private let commandRetentionSeconds: TimeInterval

    init(commandRetentionSeconds: TimeInterval = 300, maximumPendingCommands: Int = 256) {
        self.maximumPendingCommands = max(1, maximumPendingCommands)
        self.commandRetentionSeconds = max(1, commandRetentionSeconds)
    }
    
    func getNewCommandId() -> Int {
        commandId = commandId + 1
        return commandId
    }
    
    @discardableResult
    func storeBridgeCommand(_ command: BridgeCommand?, for commandId: Int, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        guard let command else {
            commandRegistry[commandId] = nil
            return true
        }
        guard commandRegistry[commandId] != nil || commandRegistry.count < maximumPendingCommands else { return false }
        commandRegistry[commandId] = RegisteredCommand(command: command, storedAt: now)
        return true
    }
    
    func loadBridgeCommandForCommandId(_ commandId: Int, now: Date = Date()) -> BridgeCommand? {
        purgeExpired(now: now)
        return commandRegistry[commandId]?.command
    }

    func takeBridgeCommandForCommandId(_ commandId: Int, now: Date = Date()) -> BridgeCommand? {
        purgeExpired(now: now)
        let command = commandRegistry[commandId]?.command
        commandRegistry[commandId] = nil
        return command
    }

    func removeBridgeCommand(for commandId: Int) {
        commandRegistry[commandId] = nil
    }

    func pendingCommandCount(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return commandRegistry.count
    }

    func clear() { commandRegistry.removeAll() }

    private func purgeExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-commandRetentionSeconds)
        commandRegistry = commandRegistry.filter { _, entry in
            entry.command.command == .feed || entry.storedAt >= cutoff
        }
    }
}
