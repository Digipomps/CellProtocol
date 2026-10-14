// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum BridgeMultiplexError: Error, Equatable {
    case transportNotConfigured
    case physicalSessionConflict
    case invalidFrame
    case invalidChannel
    case channelAlreadyExists
    case channelNotFound
    case channelRejected
    case channelOpenTimedOut
    case resourceLimitExceeded
    case sessionClosed
    case invalidSecurityContext
}

public enum BridgeFlowContinuityObservation: Equatable, Sendable {
    case untracked
    case first(sequence: UInt64)
    case contiguous(sequence: UInt64)
    case duplicate(sequence: UInt64)
    case outOfOrder(lastSeen: UInt64, received: UInt64)
    case gap(expected: UInt64, received: UInt64)
}

/// Tracks only what has been observed on the wire. It detects discontinuity but
/// deliberately makes no claim that the missing range can be replayed.
public final class BridgeFlowContinuityTracker: @unchecked Sendable {
    private struct Entry {
        var sequence: UInt64
        let insertionID: UInt64
    }

    private let stateLock = NSLock()
    private let maximumStreams: Int
    private var watermarks: [String: Entry] = [:]
    private var insertionOrder: [(streamID: String, insertionID: UInt64)] = []
    private var insertionHead = 0
    private var nextInsertionID: UInt64 = 0

    public init(maximumStreams: Int = 4_096) {
        self.maximumStreams = max(1, maximumStreams)
    }

    public func observe(streamID: String?, sequence: UInt64?) -> BridgeFlowContinuityObservation {
        guard let streamID,
              !streamID.isEmpty,
              streamID.utf8.count <= BridgeMultiplexSession.maximumStreamIDBytes,
              let sequence else {
            return .untracked
        }
        return stateLock.withLock {
            guard var entry = watermarks[streamID] else {
                evictOldestStreamIfNeeded()
                nextInsertionID &+= 1
                let insertionID = nextInsertionID
                watermarks[streamID] = Entry(sequence: sequence, insertionID: insertionID)
                insertionOrder.append((streamID, insertionID))
                return .first(sequence: sequence)
            }
            let lastSeen = entry.sequence
            if sequence == lastSeen {
                return .duplicate(sequence: sequence)
            }
            if sequence < lastSeen {
                return .outOfOrder(lastSeen: lastSeen, received: sequence)
            }
            entry.sequence = sequence
            watermarks[streamID] = entry
            if lastSeen < UInt64.max, sequence == lastSeen + 1 {
                return .contiguous(sequence: sequence)
            }
            let expected = lastSeen == UInt64.max ? UInt64.max : lastSeen + 1
            return .gap(expected: expected, received: sequence)
        }
    }

    public func watermark(for streamID: String) -> UInt64? {
        stateLock.withLock { watermarks[streamID]?.sequence }
    }

    public func trackedStreamCount() -> Int {
        stateLock.withLock { watermarks.count }
    }

    func removeStreams(withPrefix prefix: String) {
        stateLock.withLock {
            watermarks = watermarks.filter { !$0.key.hasPrefix(prefix) }
            compactInsertionOrderIfNeeded()
        }
    }

    public func reset() {
        stateLock.withLock {
            watermarks.removeAll(keepingCapacity: false)
            insertionOrder.removeAll(keepingCapacity: false)
            insertionHead = 0
        }
    }

    private func evictOldestStreamIfNeeded() {
        while watermarks.count >= maximumStreams, insertionHead < insertionOrder.count {
            let candidate = insertionOrder[insertionHead]
            insertionHead += 1
            if watermarks[candidate.streamID]?.insertionID == candidate.insertionID {
                watermarks[candidate.streamID] = nil
            }
        }
        compactInsertionOrderIfNeeded()
    }

    private func compactInsertionOrderIfNeeded() {
        insertionOrder = insertionOrder.filter { watermarks[$0.streamID]?.insertionID == $0.insertionID }
        insertionHead = 0
    }

}

/// Security-sensitive key for sharing one physical connection. Sessions are never
/// pooled across signing identities or home vaults, even when their host is equal.
public struct BridgeConnectionPoolKey: Hashable, Sendable {
    public let sessionEndpoint: String
    public let identityUUID: String
    public let signingKeyFingerprint: String
    public let homeVaultReference: String
    public let routeGeneration: UInt64

    public init(
        sessionEndpoint: URL,
        identityUUID: String,
        signingKeyFingerprint: String,
        homeVaultReference: String,
        routeGeneration: UInt64 = 0
    ) {
        self.sessionEndpoint = sessionEndpoint.absoluteString
        self.identityUUID = identityUUID.lowercased()
        self.signingKeyFingerprint = signingKeyFingerprint
        self.homeVaultReference = homeVaultReference
        self.routeGeneration = routeGeneration
    }

    fileprivate var isSecurityBound: Bool {
        Self.isValidComponent(identityUUID, maximumBytes: 512)
            && Self.isValidComponent(signingKeyFingerprint, maximumBytes: 256)
            && Self.isValidComponent(homeVaultReference, maximumBytes: 2_048)
            && Self.isValidComponent(sessionEndpoint, maximumBytes: 2_048)
            && URL(string: sessionEndpoint)?.scheme != nil
    }

    private static func isValidComponent(_ value: String, maximumBytes: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value
            && trimmed.isEmpty == false
            && trimmed.utf8.count <= maximumBytes
            && trimmed.unicodeScalars.allSatisfy {
                CharacterSet.controlCharacters.contains($0) == false
            }
    }
}

/// Owns identity-bound physical bridge sessions and creates lightweight logical
/// channel transports for individual remote cells.
public final class BridgeConnectionPool: @unchecked Sendable {
    private struct SessionEntry {
        let session: BridgeMultiplexSession
        var lastAccess: UInt64
    }

    private let stateLock = NSLock()
    private let maximumSessions: Int
    private var sessions: [BridgeConnectionPoolKey: SessionEntry] = [:]
    private var accessCounter: UInt64 = 0
    private var retiredSessions: [String: BridgeMultiplexSession] = [:]

    public init(maximumSessions: Int = 32) {
        self.maximumSessions = max(1, maximumSessions)
    }

    public func channelTransport(
        for key: BridgeConnectionPoolKey,
        targetEndpoint: String,
        physicalTransportFactory: () -> BridgeTransportProtocol
    ) throws -> BridgeTransportProtocol {
        guard BridgeMultiplexSession.isValidTargetEndpoint(targetEndpoint) else { throw BridgeMultiplexError.invalidChannel }
        guard key.isSecurityBound else {
            throw BridgeMultiplexError.invalidSecurityContext
        }
        return try stateLock.withLock {
            // Retired-but-owned sessions remain charged across reset and new keys.
            retiredSessions = retiredSessions.filter { !$0.value.isFullyClosed }
            sessions = sessions.filter { !$0.value.session.isFullyClosed }
            accessCounter &+= 1
            if var existing = sessions[key], !existing.session.isClosed {
                existing.lastAccess = accessCounter
                sessions[key] = existing
                return try existing.session.channelTransport(targetEndpoint: targetEndpoint)
            }
            if let old = sessions.removeValue(forKey: key) { retiredSessions[old.session.uuid] = old.session }
            guard sessions.count + retiredSessions.count < maximumSessions else { throw BridgeMultiplexError.resourceLimitExceeded }
            let created = BridgeMultiplexSession(physicalTransport: physicalTransportFactory())
            let channel = try created.channelTransport(targetEndpoint: targetEndpoint)
            sessions[key] = SessionEntry(session: created, lastAccess: accessCounter)
            return channel
        }
    }

    public func sessionCount() -> Int {
        stateLock.withLock { sessions.count }
    }

    public func reset() {
        let retiredSessions = stateLock.withLock { () -> [BridgeMultiplexSession] in
            let retiredSessions = sessions.values.map(\.session)
            for session in retiredSessions { self.retiredSessions[session.uuid] = session }
            sessions.removeAll(keepingCapacity: false)
            return retiredSessions
        }
        retiredSessions.forEach { $0.retireFromPool() }
    }

    func reset(host: String, routeGeneration: UInt64) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedHost.isEmpty == false else { return }
        let retiredSessions = stateLock.withLock { () -> [BridgeMultiplexSession] in
            let matchingKeys = sessions.keys.filter { key in
                URL(string: key.sessionEndpoint)?.host?.lowercased() == normalizedHost
                    && key.routeGeneration == routeGeneration
            }
            let retiring = matchingKeys.compactMap { sessions.removeValue(forKey: $0)?.session }
            for session in retiring { self.retiredSessions[session.uuid] = session }
            return retiring
        }
        retiredSessions.forEach { $0.retireFromPool() }
    }
}

/// Client side of protocol v2 multiplexing. It owns exactly one physical
/// transport and dispatches frames to weak per-channel bridge delegates.
private enum MultiplexWorkContext {
    @TaskLocal static var channel: String?
}

public final class BridgeMultiplexSession: BridgeDelegateProtocol, @unchecked Sendable {
    private final class WeakDelegate {
        weak var value: BridgeDelegateProtocol?

        init(_ value: BridgeDelegateProtocol?) {
            self.value = value
        }
    }

    public let uuid = UUID().uuidString
    public let protocolVersion = 2

    private let physicalTransport: BridgeTransportProtocol
    private let stateLock = NSLock()
    private var delegates: [String: WeakDelegate] = [:]
    private var channelWork: [String: BridgeOwnedTasks] = [:]
    private let sessionWork = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
    private var openTasks: [String: Task<Void, Error>] = [:]
    private let openWork: BridgeOwnedTasks
    private var physicalCloseTask: Task<Void, Never>?
    private var physicallyClosed = false
    var isClosed: Bool { stateLock.withLock { physicalTransportClosed } }
    var isFullyClosed: Bool { stateLock.withLock { physicallyClosed } }
    private var openContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var issuedChannelIDs: Set<String> = []
    private var closingChannelIDs: Set<String> = []
    private var activeChannelIDs: Set<String> = []
    private var setupTask: Task<Void, Error>?
    private var configuredEndpoint: URL?
    private var configuredIdentity: Identity?
    private var commandID = 0
    private let channelOpenTimeoutNanoseconds: UInt64
    private let maximumChannels: Int
    private let maximumPendingChannelOpens: Int
    private let continuityTracker = BridgeFlowContinuityTracker()
    private var retiredFromPool = false
    private var physicalTransportClosed = false

    static let maximumStreamIDBytes = 256

    public init(
        physicalTransport: BridgeTransportProtocol,
        channelOpenTimeoutNanoseconds: UInt64 = 5_000_000_000,
        maximumChannels: Int = 128,
        maximumPendingChannelOpens: Int = 32
    ) {
        self.physicalTransport = physicalTransport
        self.openWork = BridgeOwnedTasks(maximumTasks: max(1, min(maximumPendingChannelOpens, maximumChannels)), maximumBytes: 4 * 1024 * 1024)
        self.channelOpenTimeoutNanoseconds = channelOpenTimeoutNanoseconds
        self.maximumChannels = max(1, maximumChannels)
        self.maximumPendingChannelOpens = max(1, min(maximumPendingChannelOpens, maximumChannels))
        physicalTransport.setDelegate(self)
    }

    deinit {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard physicalTransportClosed == false else { return false }
            physicalTransportClosed = true
            return true
        }
        guard shouldClose else { return }
        let physicalTransport = physicalTransport
        Task {
            await physicalTransport.close()
        }
    }

    public func channelTransport(targetEndpoint: String) throws -> BridgeTransportProtocol {
        guard Self.isValidTargetEndpoint(targetEndpoint) else {
            throw BridgeMultiplexError.invalidChannel
        }
        let channelID = UUID().uuidString
        let reserved = try stateLock.withLock { () throws -> Bool in
            guard !physicalTransportClosed else { throw BridgeMultiplexError.sessionClosed }
            guard issuedChannelIDs.count < maximumChannels else {
                return false
            }
            issuedChannelIDs.insert(channelID)
            channelWork[channelID] = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
            return true
        }
        guard reserved else {
            throw BridgeMultiplexError.resourceLimitExceeded
        }
        return BridgeMultiplexChannelTransport(
            session: self,
            channelID: channelID,
            targetEndpoint: targetEndpoint
        )
    }

    private func closePhysical() -> Task<Void, Never> {
        stateLock.withLock {
            if let physicalCloseTask { return physicalCloseTask }
            physicalTransportClosed = true
            setupTask?.cancel()
            openWork.requestStop()
            let setup = setupTask
            let pending = Array(openContinuations.values)
            openContinuations.removeAll()
            let task = Task { [self] in
                pending.forEach { $0.resume(throwing: BridgeMultiplexError.sessionClosed) }
                sessionWork.requestStop()
                await physicalTransport.close()
                await sessionWork.finishStop()
                _ = try? await setup?.value
                await openWork.finishStop()
                let channelTasks = stateLock.withLock { Array(channelWork.values) }
                for work in channelTasks { await work.finishStop() }
                stateLock.withLock { physicallyClosed = true; openTasks.removeAll() }
            }
            physicalCloseTask = task
            return task
        }
    }
    fileprivate func retireFromPool() {
        let empty = stateLock.withLock { retiredFromPool = true; return issuedChannelIDs.isEmpty }
        if empty { _ = closePhysical() }
    }

    fileprivate func register(_ delegate: BridgeDelegateProtocol?, channelID: String) {
        stateLock.withLock {
            guard issuedChannelIDs.contains(channelID), physicalTransportClosed == false else { return }
            delegates[channelID] = WeakDelegate(delegate)
        }
    }

    fileprivate func unregister(channelID: String) {
        stateLock.withLock {
            delegates[channelID] = nil
        }
    }

    fileprivate func setupChannelTransport(channelID: String, bytes: Int, operation: @escaping () async throws -> Void) async throws {
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard !physicalTransportClosed, issuedChannelIDs.contains(channelID),
                  !closingChannelIDs.contains(channelID), let work = channelWork[channelID] else {
                throw BridgeMultiplexError.channelNotFound
            }
            guard let task = work.submit(bytes: bytes, { [self] in
                try await MultiplexWorkContext.$channel.withValue(uuid + channelID) {
                    try await operation()
                }
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    fileprivate func setupPhysical(endpointURL: URL, identity: Identity) async throws {
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard physicalTransportClosed == false else {
                throw BridgeMultiplexError.sessionClosed
            }
            if let configuredEndpoint, let configuredIdentity {
                guard configuredEndpoint == endpointURL,
                      configuredIdentity.referencesSameSigningIdentity(as: identity),
                      configuredIdentity.homeVaultReference == identity.homeVaultReference else {
                    throw BridgeMultiplexError.physicalSessionConflict
                }
            }
            if let setupTask {
                return setupTask
            }
            configuredEndpoint = endpointURL
            configuredIdentity = identity
            let task = Task { [physicalTransport] in
                try await physicalTransport.setup(endpointURL, identity: identity)
            }
            setupTask = task
            return task
        }
        try await task.value
    }

    fileprivate func openChannel(
        channelID: String,
        targetEndpoint: String,
        identity: Identity
    ) async throws {
        guard Self.isValidChannelID(channelID), Self.isValidTargetEndpoint(targetEndpoint) else {
            throw BridgeMultiplexError.invalidChannel
        }

        let cid = stateLock.withLock { () -> Int in
            commandID += 1
            return commandID
        }
        let open = BridgeCommand(
            cmd: Command.openChannel.rawValue,
            identity: identity,
            payload: nil,
            cid: cid,
            protocolVersion: protocolVersion,
            channelID: channelID,
            targetEndpoint: targetEndpoint
        )

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let inserted = stateLock.withLock { () -> Bool in
                        guard !Task.isCancelled, !physicalTransportClosed,
                              issuedChannelIDs.contains(channelID), !activeChannelIDs.contains(channelID),
                              openContinuations[channelID] == nil,
                              openContinuations.count < maximumPendingChannelOpens else { return false }
                        guard let data = try? JSONEncoder().encode(open),
                              let task = openWork.submit(bytes: data.count, { [self] in
                            do {
                                try await physicalTransport.sendData(data)
                                try await Task.sleep(nanoseconds: channelOpenTimeoutNanoseconds)
                                finishOpening(channelID: channelID, result: .failure(BridgeMultiplexError.channelOpenTimedOut))
                            } catch {
                                finishOpening(channelID: channelID, result: .failure(error))
                            }
                        }) else { return false }
                        openContinuations[channelID] = continuation
                        openTasks[channelID] = task
                        return true
                    }
                    if !inserted { continuation.resume(throwing: BridgeMultiplexError.resourceLimitExceeded) }
                }
            } onCancel: { self.finishOpening(channelID: channelID, result: .failure(CancellationError())) }
        } catch {
            await joinOpen(channelID)
            throw error
        }
        await joinOpen(channelID)
    }
    private func joinOpen(_ channelID: String) async {
        let task = stateLock.withLock { openTasks[channelID] }
        task?.cancel()
        _ = try? await task?.value
        stateLock.withLock { openTasks[channelID] = nil }
    }

    fileprivate func releaseChannelTransport(channelID: String, identity: Identity?) async {
        let released = stateLock.withLock { () -> (CheckedContinuation<Void, Error>?, Bool) in
            closingChannelIDs.insert(channelID)
            delegates[channelID] = nil
            activeChannelIDs.remove(channelID)
            let continuation = openContinuations.removeValue(forKey: channelID)
            openTasks[channelID]?.cancel()
            return (continuation, configuredEndpoint != nil && !physicalTransportClosed)
        }
        let work = stateLock.withLock { channelWork[channelID] }
        work?.requestStop()
        continuityTracker.removeStreams(withPrefix: "\(channelID)|")
        released.0?.resume(throwing: BridgeMultiplexError.channelNotFound)
        if released.1 {
            let cid = stateLock.withLock { commandID += 1; return commandID }
            let close = BridgeCommand(cmd: Command.closeChannel.rawValue, identity: identity, payload: nil,
                                      cid: cid, protocolVersion: protocolVersion, channelID: channelID)
            if let data = try? JSONEncoder().encode(close) { try? await physicalTransport.sendData(data) }
        }
        // If every remaining channel is retiring, close I/O before joining
        // open/send tails that may need physical close in order to return.
        let last = stateLock.withLock { issuedChannelIDs.isSubset(of: closingChannelIDs) }
        if last { await closePhysical().value }
        // Retain the identity and capacity through direct calls and open tails.
        await work?.finishStop()
        await joinOpen(channelID)
        // Keep the channel charge through its complete close-send tail.
        stateLock.withLock {
            closingChannelIDs.remove(channelID)
            channelWork[channelID] = nil
            issuedChannelIDs.remove(channelID)
        }
    }

    fileprivate func send(_ data: Data, channelID: String) async throws {
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard activeChannelIDs.contains(channelID), !physicalTransportClosed,
                  let work = channelWork[channelID] else { throw BridgeMultiplexError.channelNotFound }
            guard let task = work.submit(bytes: data.count, { [self] in
                try await MultiplexWorkContext.$channel.withValue(uuid + channelID) {
                    try await sendAdmitted(data, channelID: channelID)
                }
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    private func sendAdmitted(_ data: Data, channelID: String) async throws {
        guard var command = try? JSONDecoder().decode(BridgeCommand.self, from: data) else {
            throw BridgeMultiplexError.invalidFrame
        }
        guard command.channelID == nil || command.channelID == channelID else {
            throw BridgeMultiplexError.invalidChannel
        }
        command.protocolVersion = protocolVersion
        command.channelID = channelID
        command.targetEndpoint = nil
        try await physicalTransport.sendData(JSONEncoder().encode(command))
    }

    fileprivate func vault(for identity: Identity?) async -> IdentityVaultProtocol {
        await physicalTransport.identityVault(for: identity)
    }

    @discardableResult
    private func finishOpening(channelID: String, result: Result<Void, Error>) -> Bool {
        let continuation = stateLock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard let continuation = openContinuations.removeValue(forKey: channelID) else {
                return nil
            }
            openTasks[channelID]?.cancel()
            if case .success = result {
                activeChannelIDs.insert(channelID)
            }
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }

    private func consume(_ command: BridgeCommand, response: Bool) async throws {
        let bytes = try JSONEncoder().encode(command).count
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard !physicalTransportClosed, let channelID = command.channelID,
                  activeChannelIDs.contains(channelID), let delegate = delegates[channelID]?.value,
                  let work = channelWork[channelID] else { throw BridgeMultiplexError.channelNotFound }
            guard let task = work.submit(bytes: bytes, { [self] in
                try await MultiplexWorkContext.$channel.withValue(uuid + channelID) {
                    if response {
                        if case .flowElement? = command.payload {
                            let stream = command.streamID.map { "\(channelID)|\($0)" }
                            switch continuityTracker.observe(streamID: stream, sequence: command.sequence) {
                            case let .gap(expected, received):
                                await delegate.pushError(errorMessage: "Bridge flow gap detected: expected \(expected), received \(received). Replay is not guaranteed.", error: nil)
                            case let .outOfOrder(lastSeen, received):
                                CellBase.diagnosticLog("Bridge flow out of order last=\(lastSeen) received=\(received)", domain: .bridge)
                            case let .duplicate(sequence):
                                CellBase.diagnosticLog("Bridge flow duplicate sequence=\(sequence)", domain: .bridge)
                            case .untracked, .first, .contiguous: break
                            }
                        }
                        try await delegate.consumeResponse(command: command)
                    } else { try await delegate.consumeCommand(command: command) }
                }
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        if command.command == .ready, command.channelID == nil { return }
        if try handleSessionCommand(command) { return }
        try await consume(command, response: false)
    }

    public func consumeResponse(command: BridgeCommand) async throws {
        if try handleSessionCommand(command) { return }
        try await consume(command, response: true)
    }

    private func handleSessionCommand(_ command: BridgeCommand) throws -> Bool {
        switch command.command {
        case .channelOpened:
            guard command.protocolVersion == protocolVersion,
                  let channelID = command.channelID,
                  Self.isValidChannelID(channelID),
                  finishOpening(channelID: channelID, result: .success(())) else {
                throw BridgeMultiplexError.invalidChannel
            }
            return true
        case .channelRejected:
            guard command.protocolVersion == protocolVersion,
                  let channelID = command.channelID,
                  Self.isValidChannelID(channelID),
                  finishOpening(
                    channelID: channelID,
                    result: .failure(BridgeMultiplexError.channelRejected)
                  ) else {
                throw BridgeMultiplexError.invalidChannel
            }
            return true
        default:
            return false
        }
    }

    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        let cid = stateLock.withLock { () -> Int in
            commandID += 1
            return commandID
        }
        let frame = BridgeCommand(cmd: command.rawValue, identity: identity, payload: payload, cid: cid)
        if let data = try? JSONEncoder().encode(frame) {
            let task = stateLock.withLock { () -> Task<Void, Error>? in
                guard !physicalTransportClosed else { return nil }
                return sessionWork.submit(bytes: data.count) { [physicalTransport] in try await physicalTransport.sendData(data) }
            }
            _ = try? await task?.value
        }
    }

    public func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        _ = requestedKey
        _ = setValueState
    }

    public func pushError(errorMessage: String?, error: Error?) async {
        CellBase.diagnosticLog(errorMessage ?? String(describing: error), domain: .bridge)
    }

    public func ready() async throws {}

    fileprivate static func isValidChannelID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    fileprivate static func isValidTargetEndpoint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024, trimmed == value else { return false }
        guard !trimmed.contains(".."), !trimmed.contains("?"), !trimmed.contains("#") else { return false }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url.scheme?.lowercased() == "cell" && (url.host == nil || url.host == "localhost")
        }
        return !trimmed.contains("://")
    }

    fileprivate static func isValidStreamID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumStreamIDBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.controlCharacters.contains(scalar) == false
        }
    }
}

public final class BridgeMultiplexChannelTransport: BridgeTransportProtocol, @unchecked Sendable {
    private weak var delegate: BridgeDelegateProtocol?
    private let session: BridgeMultiplexSession?
    private let stateLock = NSLock()
    public let channelID: String
    public let targetEndpoint: String
    private var identity: Identity?
    private var closed = false
    private var closeTask: Task<Void, Never>?

    fileprivate init(
        session: BridgeMultiplexSession,
        channelID: String,
        targetEndpoint: String
    ) {
        self.session = session
        self.channelID = channelID
        self.targetEndpoint = targetEndpoint
    }

    private init() {
        session = nil
        channelID = ""
        targetEndpoint = ""
    }

    public static func new() -> BridgeTransportProtocol {
        BridgeMultiplexChannelTransport()
    }

    public func setDelegate(_ delegate: BridgeDelegateProtocol) {
        guard stateLock.withLock({ closed == false }) else { return }
        self.delegate = delegate
        session?.register(delegate, channelID: channelID)
    }

    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        guard let session,
              stateLock.withLock({ closed == false }) else {
            throw BridgeMultiplexError.transportNotConfigured
        }
        self.identity = identity
        try await session.setupChannelTransport(channelID: channelID, bytes: endpointURL.absoluteString.utf8.count) { [self] in
            do {
                try await session.setupPhysical(endpointURL: endpointURL, identity: identity)
                try await session.openChannel(
                    channelID: channelID,
                    targetEndpoint: targetEndpoint,
                    identity: identity
                )
                guard stateLock.withLock({ !closed }) else { throw BridgeMultiplexError.sessionClosed }
                try await delegate?.consumeCommand(command: BridgeCommand(
                    cmd: Command.ready.rawValue,
                    identity: identity,
                    payload: nil,
                    cid: 0,
                    protocolVersion: session.protocolVersion,
                    channelID: channelID
                ))
            } catch {
                await close()
                throw error
            }
        }
    }

    public func sendData(_ data: Data) async throws {
        guard let session,
              stateLock.withLock({ closed == false }) else {
            throw BridgeMultiplexError.transportNotConfigured
        }
        try await session.send(data, channelID: channelID)
    }

    public func close() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            if let closeTask { return closeTask }
            guard let session else { return nil }
            closed = true; delegate = nil
            let identity = self.identity, channelID = self.channelID
            let task = Task { await session.releaseChannelTransport(channelID: channelID, identity: identity) }
            closeTask = task
            return task
        }
        // A delegate may request its own retirement; only external callers join.
        if let session, MultiplexWorkContext.channel == session.uuid + channelID { return }
        await task?.value
    }

    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        guard let session else { return BridgeIdentityVault() }
        return await session.vault(for: identity)
    }

    deinit {
        guard let closeState = takeCloseState() else { return }
        let channelID = self.channelID
        Task {
            await closeState.session.releaseChannelTransport(
                channelID: channelID,
                identity: closeState.identity
            )
        }
    }

    private func takeCloseState() -> (session: BridgeMultiplexSession, identity: Identity?)? {
        stateLock.withLock {
            guard closed == false, let session else { return nil }
            closed = true
            delegate = nil
            return (session, identity)
        }
    }
}

/// Server-side demultiplexer. A WebSocket route supplies a factory which creates
/// one inbound bridge delegate per accepted logical channel. Resolution and
/// authorization remain in that bridge/resolver, not in the transport router.
public final class BridgeMultiplexServerSession: BridgeDelegateProtocol, @unchecked Sendable {
    public typealias ChannelFactory = (
        _ targetEndpoint: String,
        _ identity: Identity,
        _ channelTransport: BridgeTransportProtocol
    ) async throws -> BridgeDelegateProtocol

    private final class ChannelRecord {
        let delegate: BridgeDelegateProtocol
        let transport: ServerChannelTransport
        let work = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
        var retirement: Task<Void, Never>?

        init(delegate: BridgeDelegateProtocol, transport: ServerChannelTransport) {
            self.delegate = delegate
            self.transport = transport
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                let immediate = lock.withLock {
                    if done { return true }
                    waiters.append(continuation); return false
                }
                if immediate { continuation.resume() }
            }
        }
        func complete() {
            let pending = lock.withLock {
                done = true; let result = waiters; waiters.removeAll(); return result
            }
            pending.forEach { $0.resume() }
        }
    }

    private struct OutboundSequenceEntry {
        var sequence: UInt64
        let insertionID: UInt64
    }

    private enum ChannelReservation {
        case accepted
        case conflict
        case capacityExceeded
        case closed
    }

    public let uuid = UUID().uuidString
    public let protocolVersion = 2

    private let physicalTransport: BridgeTransportProtocol
    private let channelFactory: ChannelFactory
    private let beforeChannelSend: (@Sendable () async -> Void)?
    private let stateLock = NSLock()
    private let sessionWork = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
    private let maximumChannels: Int
    private let maximumPendingChannelOpens: Int
    private let maximumTrackedOutboundStreams: Int
    private var channels: [String: ChannelRecord] = [:]
    private var pendingChannelIDs: Set<String> = []
    private var pendingCompletions: [String: Completion] = [:]
    private var closeTask: Task<Void, Never>?
    private var cancelledPendingChannelIDs: Set<String> = []
    private var outboundStreamSequences: [String: OutboundSequenceEntry] = [:]
    private var outboundStreamInsertionOrder: [(streamID: String, insertionID: UInt64)] = []
    private var outboundStreamInsertionHead = 0
    private var outboundStreamInsertionID: UInt64 = 0
    private var commandID = 0
    private var closed = false

    public init(
        physicalTransport: BridgeTransportProtocol,
        maximumChannels: Int = 128,
        maximumPendingChannelOpens: Int = 32,
        maximumTrackedOutboundStreams: Int = 4_096,
        beforeChannelSend: (@Sendable () async -> Void)? = nil,
        channelFactory: @escaping ChannelFactory
    ) {
        self.physicalTransport = physicalTransport
        self.maximumChannels = max(1, maximumChannels)
        self.maximumPendingChannelOpens = max(1, min(maximumPendingChannelOpens, maximumChannels))
        self.maximumTrackedOutboundStreams = max(1, maximumTrackedOutboundStreams)
        self.channelFactory = channelFactory
        self.beforeChannelSend = beforeChannelSend
        physicalTransport.setDelegate(self)
    }

    deinit {
        let physicalTransport = physicalTransport
        let records = Array(channels.values)
        Task {
            await physicalTransport.close()
            for record in records { await record.transport.retireDelegate() }
        }
    }

    /// Convenience used by a WebSocket host route when each logical channel
    /// should expose an ordinary inbound BridgeBase. The command identity still
    /// reaches the resolver and the represented cell for authorization.
    public convenience init(
        physicalTransport: BridgeTransportProtocol,
        bridgeOwner: Identity,
        inboundPublisherLookupIdentity: Identity? = nil
    ) {
        self.init(physicalTransport: physicalTransport) { targetEndpoint, _, channelTransport in
            let publisherReference: String
            if let url = URL(string: targetEndpoint), url.scheme?.lowercased() == "cell" {
                publisherReference = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                publisherReference = targetEndpoint
            }
            guard !publisherReference.isEmpty else {
                throw BridgeMultiplexError.invalidChannel
            }
            let bridge = try await BridgeBase(.init(
                owner: bridgeOwner,
                contractTemplate: Agreement(owner: bridgeOwner),
                transport: channelTransport,
                connection: .inbound(publisherUuid: publisherReference),
                inboundPublisherLookupIdentity: inboundPublisherLookupIdentity
            ))
            try await bridge.setTransport(
                channelTransport,
                connection: .inbound(publisherUuid: publisherReference)
            )
            try await bridge.consumeCommand(command: BridgeCommand(
                cmd: Command.ready.rawValue,
                identity: bridgeOwner,
                payload: nil,
                cid: 0,
                protocolVersion: 2
            ))
            return bridge
        }
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        switch command.command {
        case .openChannel:
            try await open(command)
        case .closeChannel:
            guard command.protocolVersion == protocolVersion,
                  let channelID = command.channelID,
                  BridgeMultiplexSession.isValidChannelID(channelID) else {
                throw BridgeMultiplexError.invalidChannel
            }
            let closing = stateLock.withLock { () -> (Completion?, ServerChannelTransport?) in
                if pendingChannelIDs.contains(channelID) { cancelledPendingChannelIDs.insert(channelID) }
                return (pendingCompletions[channelID], channels[channelID]?.transport)
            }
            if let transport = closing.1, let task = retireChannel(channelID, matching: transport) { await task.value }
            await closing.0?.wait()

        default:
            try await consume(command, response: false)
        }
    }

    public func consumeResponse(command: BridgeCommand) async throws {
        try await consume(command, response: true)
    }

    private func consume(_ command: BridgeCommand, response: Bool) async throws {
        let bytes = try JSONEncoder().encode(command).count
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard !closed, command.protocolVersion == protocolVersion,
                  let channelID = command.channelID, let record = channels[channelID],
                  record.retirement == nil else { throw BridgeMultiplexError.channelNotFound }
            guard let task = record.work.submit(bytes: bytes, {
                if response { try await record.delegate.consumeResponse(command: command) }
                else { try await record.delegate.consumeCommand(command: command) }
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    private func open(_ command: BridgeCommand) async throws {
        guard command.protocolVersion == protocolVersion,
              let channelID = command.channelID,
              BridgeMultiplexSession.isValidChannelID(channelID),
              let targetEndpoint = command.targetEndpoint,
              BridgeMultiplexSession.isValidTargetEndpoint(targetEndpoint) else {
            try await reject(command)
            return
        }
        guard let identity = command.identity,
              IdentityPublicKeySignatureVerifier.descriptor(for: identity) != nil,
              identity.signingPublicKeyFingerprint != nil else {
            await recordChannelRejection(
                identity: command.identity,
                reasonCode: CellSecurityReasonCode.identityPublicKeyMismatch,
                requiredAction: "retry_with_key_bound_identity"
            )
            try await reject(command)
            return
        }

        let reservation = stateLock.withLock { () -> ChannelReservation in
            guard closed == false else { return .closed }
            guard channels[channelID] == nil, pendingChannelIDs.contains(channelID) == false else {
                return .conflict
            }
            guard channels.count + pendingChannelIDs.count < maximumChannels,
                  pendingChannelIDs.count < maximumPendingChannelOpens else {
                return .capacityExceeded
            }
            pendingChannelIDs.insert(channelID)
            pendingCompletions[channelID] = Completion()
            return .accepted
        }
        switch reservation {
        case .accepted:
            break
        case .conflict:
            await recordChannelRejection(
                identity: identity,
                reasonCode: CellSecurityReasonCode.bridgeChannelConflict,
                requiredAction: "retry_with_fresh_channel_id"
            )
            try await reject(command)
            return
        case .capacityExceeded:
            await recordChannelRejection(
                identity: identity,
                reasonCode: CellSecurityReasonCode.bridgeChannelCapacityExceeded,
                requiredAction: "wait_before_opening_another_channel"
            )
            try await reject(command)
            return
        case .closed:
            try await reject(command)
            return
        }

        defer {
            let completion = stateLock.withLock {
                pendingChannelIDs.remove(channelID)
                cancelledPendingChannelIDs.remove(channelID)
                return pendingCompletions.removeValue(forKey: channelID)
            }
            completion?.complete()
        }
        let channelTransport = ServerChannelTransport(session: self, channelID: channelID)

        do {
            let delegate = try await channelFactory(targetEndpoint, identity, channelTransport)
            channelTransport.setDelegate(delegate)
            let inserted = stateLock.withLock { () -> Bool in
                guard closed == false, !channelTransport.isClosed,
                      pendingChannelIDs.contains(channelID),
                      cancelledPendingChannelIDs.contains(channelID) == false,
                      channels[channelID] == nil else {
                    return false
                }
                channels[channelID] = ChannelRecord(delegate: delegate, transport: channelTransport)
                return true
            }
            guard inserted else {
                await channelTransport.retireDelegate()
                try await reject(command)
                return
            }
            try await sendSessionFrame(BridgeCommand(
                cmd: Command.channelOpened.rawValue,
                identity: identity,
                payload: nil,
                cid: command.cid,
                protocolVersion: protocolVersion,
                channelID: channelID
            ))
        } catch {
            if let task = retireChannel(channelID, matching: channelTransport) { await task.value }
            else { await channelTransport.retireDelegate() }

            try await reject(command)
        }
    }

    private func reject(_ command: BridgeCommand) async throws {
        try await sendSessionFrame(BridgeCommand(
            cmd: Command.channelRejected.rawValue,
            identity: command.identity,
            payload: nil,
            cid: command.cid,
            protocolVersion: protocolVersion,
            channelID: command.channelID
        ))
    }

    private func send(_ data: Data, channelID: String, matching transport: ServerChannelTransport) async throws {
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard !closed, let record = channels[channelID], record.retirement == nil,
                  record.transport === transport else { throw BridgeMultiplexError.channelNotFound }
            guard let task = record.work.submit(bytes: data.count, { [self] in
                try await sendAdmitted(data, channelID: channelID)
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    private func sendAdmitted(_ data: Data, channelID: String) async throws {
        guard var command = try? JSONDecoder().decode(BridgeCommand.self, from: data) else {
            throw BridgeMultiplexError.invalidFrame
        }
        command.protocolVersion = protocolVersion
        command.channelID = channelID
        command.targetEndpoint = nil
        if case .flowElement? = command.payload {
            let streamID: String
            if let proposedStreamID = command.streamID,
               BridgeMultiplexSession.isValidStreamID(proposedStreamID) {
                streamID = proposedStreamID
            } else {
                streamID = "\(channelID):\(command.cid)"
            }
            let trackingKey = "\(channelID)|\(streamID)"
            let sequence = stateLock.withLock { () -> UInt64 in
                nextOutboundSequence(for: trackingKey)
            }
            command.streamID = streamID
            command.sequence = sequence
        }
        try await sendSessionFrame(command)
    }

    fileprivate func vault(for identity: Identity?) async -> IdentityVaultProtocol {
        await physicalTransport.identityVault(for: identity)
    }

    private func sendSessionFrame(_ command: BridgeCommand) async throws {
        let data = try JSONEncoder().encode(command)
        let task = try stateLock.withLock { () throws -> Task<Void, Error> in
            guard !closed else { throw BridgeMultiplexError.sessionClosed }
            guard let task = sessionWork.submit(bytes: data.count, { [physicalTransport] in
                try await physicalTransport.sendData(data)
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        try await task.value
    }

    // Internal transport close only starts retirement: BridgeBase's finalizer
    // calls it and must never await its own completion. External owners join.
    @discardableResult
    private func retireChannel(_ channelID: String, matching transport: ServerChannelTransport? = nil) -> Task<Void, Never>? {
        stateLock.withLock {
            guard let record = channels[channelID], transport == nil || record.transport === transport else { return nil }
            if let task = record.retirement { return task }
            let task = Task { [self, record] in
                record.work.requestStop()
                await record.transport.retireDelegate()
                await record.work.finishStop()
                stateLock.withLock {
                    if channels[channelID] === record { channels[channelID] = nil }
                    outboundStreamSequences = outboundStreamSequences.filter { !$0.key.hasPrefix("\(channelID)|") }
                    compactOutboundStreamInsertionOrderIfNeeded()
                }
            }
            record.retirement = task
            return task
        }
    }

    public func close() async {
        let task = stateLock.withLock { () -> Task<Void, Never> in
            if let closeTask { return closeTask }
            closed = true
            cancelledPendingChannelIDs.formUnion(pendingChannelIDs)
            let channelIDs = Array(channels.keys)
            let pending = Array(pendingCompletions.values)
            let task = Task { [self] in
                let retirements = channelIDs.compactMap { retireChannel($0) }
                sessionWork.requestStop()
                await physicalTransport.close()
                await sessionWork.finishStop()
                for task in retirements { await task.value }
                for completion in pending { await completion.wait() }
                stateLock.withLock {
                    outboundStreamSequences.removeAll(keepingCapacity: false)
                    outboundStreamInsertionOrder.removeAll(keepingCapacity: false)
                    outboundStreamInsertionHead = 0
                }
            }
            closeTask = task
            return task
        }
        await task.value
    }

    private func recordChannelRejection(
        identity: Identity?,
        reasonCode: String,
        requiredAction: String
    ) async {
        await CellBase.recordSecurityEvent(CellSecurityEvent(
            kind: .transportRejected,
            severity: .high,
            resource: CellSecurityResource(
                kind: "bridgeMultiplexSession",
                identifier: uuid,
                action: Command.openChannel.rawValue
            ),
            requester: identity.map {
                CellSecurityActor(
                    identityUUID: $0.uuid,
                    signingKeyFingerprint: $0.signingPublicKeyFingerprint,
                    domain: nil
                )
            },
            reasonCode: reasonCode,
            userMessage: "Bridge logical channel request was rejected.",
            requiredAction: requiredAction,
            canAutoResolve: false
        ))
    }

    private func nextOutboundSequence(for streamID: String) -> UInt64 {
        if var existing = outboundStreamSequences[streamID] {
            let next = existing.sequence == UInt64.max ? UInt64.max : existing.sequence + 1
            existing.sequence = next
            outboundStreamSequences[streamID] = existing
            return next
        }

        while outboundStreamSequences.count >= maximumTrackedOutboundStreams,
              outboundStreamInsertionHead < outboundStreamInsertionOrder.count {
            let candidate = outboundStreamInsertionOrder[outboundStreamInsertionHead]
            outboundStreamInsertionHead += 1
            if outboundStreamSequences[candidate.streamID]?.insertionID == candidate.insertionID {
                outboundStreamSequences[candidate.streamID] = nil
            }
        }
        compactOutboundStreamInsertionOrderIfNeeded()
        outboundStreamInsertionID &+= 1
        let insertionID = outboundStreamInsertionID
        outboundStreamSequences[streamID] = OutboundSequenceEntry(sequence: 1, insertionID: insertionID)
        outboundStreamInsertionOrder.append((streamID, insertionID))
        return 1
    }

    private func compactOutboundStreamInsertionOrderIfNeeded() {
        outboundStreamInsertionOrder = outboundStreamInsertionOrder.filter { outboundStreamSequences[$0.streamID]?.insertionID == $0.insertionID }
        outboundStreamInsertionHead = 0
    }

    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        let cid = stateLock.withLock { () -> Int in
            commandID += 1
            return commandID
        }
        try? await sendSessionFrame(BridgeCommand(
            cmd: command.rawValue,
            identity: identity,
            payload: payload,
            cid: cid,
            protocolVersion: protocolVersion
        ))
    }

    public func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        _ = requestedKey
        _ = setValueState
    }

    public func pushError(errorMessage: String?, error: Error?) async {
        CellBase.diagnosticLog(errorMessage ?? String(describing: error), domain: .bridge)
    }

    public func ready() async throws {}

    private final class ServerChannelTransport: BridgeTransportProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var delegate: BridgeDelegateProtocol?
        private var closed = false
        private weak var session: BridgeMultiplexServerSession?
        private let channelID: String

        init(session: BridgeMultiplexServerSession, channelID: String) {
            self.session = session
            self.channelID = channelID
        }

        static func new() -> BridgeTransportProtocol {
            BridgeMultiplexChannelTransport.new()
        }

        func setDelegate(_ delegate: BridgeDelegateProtocol) {
            lock.withLock { self.delegate = delegate }
        }

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = endpointURL
            _ = identity
        }

        func sendData(_ data: Data) async throws {
            guard lock.withLock({ !closed }), let session else { throw BridgeMultiplexError.sessionClosed }
            await session.beforeChannelSend?()
            try await session.send(data, channelID: channelID, matching: self)
        }

        func close() async {
            lock.withLock { closed = true }
            session?.retireChannel(channelID, matching: self)
        }

        var isClosed: Bool { lock.withLock { closed } }

        func retireDelegate() async {
            let delegate = lock.withLock { closed = true; return self.delegate }
            if let bridge = delegate as? BridgeBase { await bridge.finishRetirement() }
            lock.withLock { self.delegate = nil }
        }

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            guard let session else { return BridgeIdentityVault() }
            return await session.vault(for: identity)
        }
    }
}
