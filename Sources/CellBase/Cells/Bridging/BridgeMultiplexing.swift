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

    var retainedStreamSlotCount: Int { stateLock.withLock { insertionOrder.count } }

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
        if watermarks.isEmpty {
            insertionOrder.removeAll(keepingCapacity: false); insertionHead = 0
            return
        }
        // Close/reopen may remove entries without advancing the eviction head.
        // Bound the backing order as well as the active watermark dictionary.
        guard insertionHead > maximumStreams
                || (insertionOrder.count > maximumStreams && insertionOrder.count - maximumStreams > maximumStreams) else { return }
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

/// What a full pool does with a new key.
public enum BridgeConnectionPoolCapacityPolicy: Sendable, Equatable {
    /// Default (main): retire the least recently used session. A retired
    /// session leaves the pool at once and does not count against the limit.
    case evictLeastRecentlyUsed
    /// Opt-in (loopback lifecycle): a session closes physically when its last
    /// channel is released, and every session that is not yet fully closed
    /// stays charged. A full pool refuses with resourceLimitExceeded.
    case rejectUntilPhysicallyClosed
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
    public let capacityPolicy: BridgeConnectionPoolCapacityPolicy
    // Only used by .rejectUntilPhysicallyClosed: removed but still charged.
    private var retiringSessions: [String: BridgeMultiplexSession] = [:]

    public init(maximumSessions: Int = 32,
                capacityPolicy: BridgeConnectionPoolCapacityPolicy = .evictLeastRecentlyUsed) {
        self.maximumSessions = max(1, maximumSessions)
        self.capacityPolicy = capacityPolicy
    }

    public func channelTransport(
        for key: BridgeConnectionPoolKey,
        targetEndpoint: String,
        physicalTransportFactory: () throws -> BridgeTransportProtocol
    ) throws -> BridgeTransportProtocol {
        // An invalid target must fail before a physical transport is constructed.
        guard BridgeMultiplexSession.isValidTargetEndpoint(targetEndpoint) else {
            throw BridgeMultiplexError.invalidChannel
        }
        guard key.isSecurityBound else {
            throw BridgeMultiplexError.invalidSecurityContext
        }
        if capacityPolicy == .rejectUntilPhysicallyClosed {
            return try stateLock.withLock { () throws -> BridgeTransportProtocol in
                retiringSessions = retiringSessions.filter { !$0.value.isFullyClosed }
                sessions = sessions.filter { !$0.value.session.isFullyClosed }
                accessCounter &+= 1
                if var existing = sessions[key], existing.session.canReuseConnection {
                    existing.lastAccess = accessCounter
                    sessions[key] = existing
                    return try existing.session.channelTransport(targetEndpoint: targetEndpoint)
                }
                if let old = sessions.removeValue(forKey: key) { retiringSessions[old.session.uuid] = old.session }
                guard sessions.count + retiringSessions.count < maximumSessions else {
                    throw BridgeMultiplexError.resourceLimitExceeded
                }
                let created = BridgeMultiplexSession(physicalTransport: try physicalTransportFactory(), closesWhenIdle: true)
                let channel = try created.channelTransport(targetEndpoint: targetEndpoint)
                sessions[key] = SessionEntry(session: created, lastAccess: accessCounter)
                return channel
            }
        }
        let result = try stateLock.withLock { () throws -> (BridgeMultiplexSession, [BridgeMultiplexSession]) in
            accessCounter &+= 1
            if var existing = sessions[key], existing.session.canReuseConnection {
                existing.lastAccess = accessCounter
                sessions[key] = existing
                return (existing.session, [])
            }
            // Construct first: a throwing factory must not orphan the old entry.
            let created = BridgeMultiplexSession(physicalTransport: try physicalTransportFactory())
            var retiredSessions: [BridgeMultiplexSession] = []
            if let replaced = sessions.removeValue(forKey: key) { retiredSessions.append(replaced.session) }
            if sessions.count >= maximumSessions,
               let oldestKey = sessions.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                if let evicted = sessions.removeValue(forKey: oldestKey) { retiredSessions.append(evicted.session) }
            }
            sessions[key] = SessionEntry(session: created, lastAccess: accessCounter)
            return (created, retiredSessions)
        }
        result.1.forEach { $0.retireFromPool() }
        return try result.0.channelTransport(targetEndpoint: targetEndpoint)
    }

    public func sessionCount() -> Int {
        stateLock.withLock { sessions.count }
    }

    public func reset() {
        let retiredSessions = stateLock.withLock { () -> [BridgeMultiplexSession] in
            let retiredSessions = sessions.values.map(\.session)
            if capacityPolicy == .rejectUntilPhysicallyClosed {
                for session in retiredSessions { retiringSessions[session.uuid] = session }
            }
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
            if capacityPolicy == .rejectUntilPhysicallyClosed {
                for session in retiring { retiringSessions[session.uuid] = session }
            }
            return retiring
        }
        retiredSessions.forEach { $0.retireFromPool() }
    }
}

/// Client side of protocol v2 multiplexing. It owns exactly one physical
/// transport and dispatches frames to weak per-channel bridge delegates.
/// Marks work running on behalf of one logical channel (client or server), so
/// a close requested from inside that work starts without joining itself.
enum BridgeMultiplexWorkContext {
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

    fileprivate var channelSession: BridgeChannelSession? { physicalTransport.channelSession }
    private let physicalTransport: BridgeTransportProtocol
    private let stateLock = NSLock()
    private var delegates: [String: WeakDelegate] = [:]
    private var openContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var issuedChannelIDs: Set<String> = []
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
    // G3: every direct call on a channel (setup, open send, sends, consumed
    // frames) is owned work of that channel; close joins it and the channel's
    // capacity is held until it has returned. Session control sends are owned
    // by the session and joined when the physical transport closes.
    private var channelWork: [String: BridgeOwnedTasks] = [:]
    private var closingChannelIDs: Set<String> = []
    private let sessionWork = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
    // G4: open timeouts are separate, weakly held and cancelled on completion.
    private var openTimeouts: [String: Task<Void, Never>] = [:]
    private var physicalCloseTask: Task<Void, Never>?

    static let maximumStreamIDBytes = 256

    /// When true (pool policy .rejectUntilPhysicallyClosed), releasing the last
    /// issued channel closes the physical transport; the session is single-use.
    public let closesWhenIdle: Bool
    private var physicallyClosed = false
    var isClosed: Bool { stateLock.withLock { physicalTransportClosed } }
    /// True once physical close has actually returned.
    var isFullyClosed: Bool { stateLock.withLock { physicallyClosed } }
    private func closePhysicalTransport() async {
        await closePhysical().value
    }

    /// Shared physical close: refuses new work, fails pending opens, closes I/O
    /// first (held sends may only return then), then joins session work.
    private func closePhysical() -> Task<Void, Never> {
        stateLock.withLock {
            if let physicalCloseTask { return physicalCloseTask }
            physicalTransportClosed = true
            let pending = Array(openContinuations.values)
            openContinuations.removeAll()
            let timeouts = Array(openTimeouts.values)
            openTimeouts.removeAll()
            let task = Task { [self] in
                timeouts.forEach { $0.cancel() }
                pending.forEach { $0.resume(throwing: BridgeMultiplexError.sessionClosed) }
                sessionWork.requestStop()
                await physicalTransport.close()
                await sessionWork.finishStop()
                stateLock.withLock { physicallyClosed = true }
            }
            physicalCloseTask = task
            return task
        }
    }

    /// Runs `operation` as owned work of `channelID`. Throws if the channel is
    /// closing or its work budget is exhausted; the slot is held until return.
    fileprivate func runChannelWork<T>(_ channelID: String, bytes: Int = 0,
                                       _ operation: @escaping () async throws -> T) async throws -> T {
        let context = uuid + channelID
        let task = try stateLock.withLock { () throws -> Task<T, Error> in
            guard physicalTransportClosed == false, issuedChannelIDs.contains(channelID),
                  closingChannelIDs.contains(channelID) == false,
                  let work = channelWork[channelID] else { throw BridgeMultiplexError.channelNotFound }
            guard let task = work.submit(bytes: bytes, {
                try await BridgeMultiplexWorkContext.$channel.withValue(context) { try await operation() }
            }) else { throw BridgeMultiplexError.resourceLimitExceeded }
            return task
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    fileprivate func isInsideWork(of channelID: String) -> Bool {
        BridgeMultiplexWorkContext.channel == uuid + channelID
    }

    public init(
        physicalTransport: BridgeTransportProtocol,
        channelOpenTimeoutNanoseconds: UInt64 = 5_000_000_000,
        maximumChannels: Int = 128,
        maximumPendingChannelOpens: Int = 32,
        closesWhenIdle: Bool = false
    ) {
        self.closesWhenIdle = closesWhenIdle
        self.physicalTransport = physicalTransport
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
            if closesWhenIdle, physicalTransportClosed { throw BridgeMultiplexError.sessionClosed }
            guard physicalTransportClosed == false,
                  issuedChannelIDs.count < maximumChannels else {
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

    fileprivate var canReuseConnection: Bool {
        stateLock.withLock {
            !retiredFromPool && !physicalTransportClosed
                && (channelSession?.canReuseConnection() ?? true)
        }
    }

    fileprivate func retireFromPool() {
        let shouldClose = stateLock.withLock { () -> Bool in
            retiredFromPool = true
            return issuedChannelIDs.isEmpty && physicalTransportClosed == false
        }
        guard shouldClose else { return }
        _ = closePhysical()
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
        do { try await task.value }
        catch {
            stateLock.withLock { retiredFromPool = true }
            await closePhysicalTransport()
            throw error
        }
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
            identity: identity.publicIdentitySnapshot(),
            payload: nil,
            cid: cid,
            protocolVersion: protocolVersion,
            channelID: channelID,
            targetEndpoint: targetEndpoint
        )

        let data = try JSONEncoder().encode(open)
        let timeoutNanoseconds = channelOpenTimeoutNanoseconds
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let inserted = stateLock.withLock { () -> Bool in
                guard physicalTransportClosed == false,
                      issuedChannelIDs.contains(channelID),
                      closingChannelIDs.contains(channelID) == false,
                      activeChannelIDs.contains(channelID) == false,
                      openContinuations[channelID] == nil,
                      openContinuations.count < maximumPendingChannelOpens,
                      let work = channelWork[channelID] else {
                    return false
                }
                // The open send is owned channel work (joined by close).
                let context = uuid + channelID
                guard work.submit(bytes: data.count, { [weak self] in
                    try await BridgeMultiplexWorkContext.$channel.withValue(context) {
                        guard let transport = self?.physicalTransport else { return }
                        do { try await transport.sendData(data) }
                        catch { self?.finishOpening(channelID: channelID, result: .failure(error)) }
                    }
                }) != nil else { return false }
                openContinuations[channelID] = continuation
                // G4: the timeout holds the session weakly and is cancelled
                // as soon as the open completes, so a finished open does not
                // retain the session (or its physical transport) for 5 s.
                openTimeouts[channelID] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                    self?.finishOpening(channelID: channelID, result: .failure(BridgeMultiplexError.channelOpenTimedOut))
                }
                return true
            }
            guard inserted else {
                continuation.resume(throwing: BridgeMultiplexError.resourceLimitExceeded)
                return
            }
        }
    }

    fileprivate func releaseChannelTransport(channelID: String, identity: Identity?) async {
        let releaseState = stateLock.withLock { () -> (
            continuation: CheckedContinuation<Void, Error>?,
            sendClose: Bool,
            closePhysical: Bool,
            work: BridgeOwnedTasks?
        ) in
            delegates[channelID] = nil
            activeChannelIDs.remove(channelID)
            closingChannelIDs.insert(channelID)
            openTimeouts.removeValue(forKey: channelID)?.cancel()
            let continuation = openContinuations.removeValue(forKey: channelID)
            let sendClose = configuredEndpoint != nil && physicalTransportClosed == false
            let closePhysical = (retiredFromPool || closesWhenIdle)
                && issuedChannelIDs.isSubset(of: closingChannelIDs) && physicalTransportClosed == false
            return (continuation, sendClose, closePhysical, channelWork[channelID])
        }
        // New direct calls are refused from here; admitted ones are cancelled
        // but keep their slot (and this channel's capacity) until they return.
        releaseState.work?.requestStop()
        continuityTracker.removeStreams(withPrefix: "\(channelID)|")
        releaseState.continuation?.resume(throwing: BridgeMultiplexError.channelNotFound)
        if releaseState.sendClose {
            let cid = stateLock.withLock { () -> Int in
                commandID += 1
                return commandID
            }
            let close = BridgeCommand(
                cmd: Command.closeChannel.rawValue,
                identity: identity?.publicIdentitySnapshot(),
                payload: nil,
                cid: cid,
                protocolVersion: protocolVersion,
                channelID: channelID
            )
            if let data = try? JSONEncoder().encode(close) {
                try? await physicalTransport.sendData(data)
            }
        }
        // Close I/O before joining tails that may need it in order to return.
        if releaseState.closePhysical { await closePhysicalTransport() }
        await releaseState.work?.finishStop()
        stateLock.withLock {
            closingChannelIDs.remove(channelID)
            channelWork[channelID] = nil
            issuedChannelIDs.remove(channelID)
        }
    }

    fileprivate func send(_ data: Data, channelID: String) async throws {
        guard stateLock.withLock({ activeChannelIDs.contains(channelID) && physicalTransportClosed == false }) else {
            throw BridgeMultiplexError.channelNotFound
        }
        try await runChannelWork(channelID, bytes: data.count) { [self] in
            try await sendAdmitted(data, channelID: channelID)
        }
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
            openTimeouts.removeValue(forKey: channelID)?.cancel()
            if case .success = result {
                activeChannelIDs.insert(channelID)
            }
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }

    private func delegate(for channelID: String) -> BridgeDelegateProtocol? {
        stateLock.withLock {
            guard activeChannelIDs.contains(channelID) else { return nil }
            let delegate = delegates[channelID]?.value
            if delegate == nil {
                delegates[channelID] = nil
            }
            return delegate
        }
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        if command.command == .ready, command.channelID == nil {
            return
        }
        if try handleSessionCommand(command) {
            return
        }
        guard let channelID = command.channelID,
              let delegate = delegate(for: channelID) else {
            throw BridgeMultiplexError.channelNotFound
        }
        try await runChannelWork(channelID) { try await delegate.consumeCommand(command: command) }
    }

    func prepareInboundDispatch(_ command: BridgeCommand) -> BridgeInboundDispatch? {
        guard command.protocolVersion == protocolVersion,
              command.command == .response || command.command == .sign,
              let channelID = command.channelID, let target = delegate(for: channelID) else { return nil }
        return BridgeInboundDispatch(laneID: ObjectIdentifier(target)) { [self, target] in
            guard delegate(for: channelID) === target else { return }
            try await runChannelWork(channelID) { [self] in
                if command.command == .response {
                    try await deliverResponse(command, channelID: channelID, delegate: target)
                } else { try await target.consumeCommand(command: command) }
            }
        }
    }

    func isOriginSigningResponse(_ command: BridgeCommand) -> Bool {
        guard command.protocolVersion == protocolVersion, let id = command.channelID,
              let bridge = delegate(for: id) as? BridgeBase else { return false }
        return bridge.isOriginSigningResponse(command)
    }

    public func consumeResponse(command: BridgeCommand) async throws {
        if try handleSessionCommand(command) {
            return
        }
        guard let channelID = command.channelID,
              let delegate = delegate(for: channelID) else {
            throw BridgeMultiplexError.channelNotFound
        }
        try await runChannelWork(channelID) { [self] in
            try await deliverResponse(command, channelID: channelID, delegate: delegate)
        }
    }

    private func deliverResponse(_ command: BridgeCommand, channelID: String,
                                 delegate: BridgeDelegateProtocol) async throws {
        if case .flowElement? = command.payload {
            let trackedStreamID = command.streamID.map { "\(channelID)|\($0)" }
            switch continuityTracker.observe(streamID: trackedStreamID, sequence: command.sequence) {
            case let .gap(expected, received):
                await delegate.pushError(
                    errorMessage: "Bridge flow gap detected: expected \(expected), received \(received). Replay is not guaranteed.",
                    error: nil
                )
            case let .outOfOrder(lastSeen, received):
                CellBase.diagnosticLog(
                    "Bridge flow out of order last=\(lastSeen) received=\(received)",
                    domain: .bridge
                )
            case let .duplicate(sequence):
                CellBase.diagnosticLog(
                    "Bridge flow duplicate sequence=\(sequence)",
                    domain: .bridge
                )
            case .untracked, .first, .contiguous:
                break
            }
        }
        try await delegate.consumeResponse(command: command)
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
        let frame = BridgeCommand(cmd: command.rawValue, identity: identity.publicIdentitySnapshot(), payload: payload, cid: cid)
        if let data = try? JSONEncoder().encode(frame) {
            // Session control send: owned by the session, joined at physical close.
            let task = stateLock.withLock { () -> Task<Void, Error>? in
                guard physicalTransportClosed == false else { return nil }
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
        let current = stateLock.withLock { delegates.values.compactMap(\.value) }
        for delegate in current { await delegate.pushError(errorMessage: errorMessage, error: error) }
        if channelSession != nil { retireFromPool() }
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
    public var channelSession: BridgeChannelSession? { session?.channelSession }
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
        // G3: setup is owned work of this channel; a concurrent close waits
        // for it to return and the channel's capacity is held until then.
        try await session.runChannelWork(channelID, bytes: endpointURL.absoluteString.utf8.count) { [self] in
            do {
                try await session.setupPhysical(endpointURL: endpointURL, identity: identity)
                try await session.openChannel(
                    channelID: channelID,
                    targetEndpoint: targetEndpoint,
                    identity: identity
                )
                guard stateLock.withLock({ !closed }) else { throw BridgeMultiplexError.sessionClosed }
                if channelSession != nil, let bridge = delegate as? BridgeBase {
                    try bridge.activateAuthenticatedChannel()
                } else {
                try await delegate?.consumeCommand(command: BridgeCommand(
                    cmd: Command.ready.rawValue,
                    identity: identity,
                    payload: nil,
                    cid: 0,
                    protocolVersion: session.protocolVersion,
                    channelID: channelID
                ))
                }
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

    /// G3: every external caller joins the same close, which ends only after
    /// all admitted work on this channel has returned. Work running on behalf
    /// of this channel (its delegate closing itself) starts it without joining.
    public func close() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            if let closeTask { return closeTask }
            guard closed == false, let session else { return nil }
            closed = true
            let previousDelegate = delegate
            delegate = nil
            let identity = self.identity, channelID = self.channelID
            let task = Task {
                if let bridge = previousDelegate as? BridgeBase { await bridge.retireLogicalChannel() }
                await session.releaseChannelTransport(channelID: channelID, identity: identity)
            }
            closeTask = task
            return task
        }
        if let session, session.isInsideWork(of: channelID) { return }
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

    private func takeCloseState() -> (session: BridgeMultiplexSession, identity: Identity?, delegate: BridgeDelegateProtocol?)? {
        stateLock.withLock {
            guard closed == false, let session else { return nil }
            closed = true
            let previousDelegate = delegate
            delegate = nil
            return (session, identity, previousDelegate)
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

    private final class ChannelRecord: @unchecked Sendable {
        let delegate: BridgeDelegateProtocol
        let transport: ServerChannelTransport
        let quota: BridgeChannelResourceLease
        private let lock = NSLock()
        private var retired = false
        private var tasks: [UUID: Task<Void, Error>] = [:]
        private var retirement: Task<Void, Never>?

        init(delegate: BridgeDelegateProtocol, transport: ServerChannelTransport, quota: BridgeChannelResourceLease) {
            self.quota = quota
            self.delegate = delegate
            self.transport = transport
        }
        func dispatch(_ command: BridgeCommand, response: Bool = false) async throws {
            let id = UUID()
            let task = try lock.withLock { () throws -> Task<Void, Error>? in
                guard !retired else { return nil }
                guard tasks.count < 64 else { throw BridgeMultiplexError.resourceLimitExceeded }
                let task = Task { [delegate] in
                    try Task.checkCancellation()
                    if response { try await delegate.consumeResponse(command: command) }
                    else { try await delegate.consumeCommand(command: command) }
                }
                tasks[id] = task
                return task
            }
            guard let task else { return }
            defer { _ = lock.withLock { tasks.removeValue(forKey: id) } }
            do {
                try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            } catch {
                // Retirement already revoked this logical destination. A late
                // cancellation/send error cannot retire the physical siblings.
                if !lock.withLock({ retired }) { throw error }
            }
        }
        /// Synchronous snapshot: admitted dispatches or delegate-owned work.
        var hasInFlightWork: Bool {
            lock.withLock { !tasks.isEmpty } || ((delegate as? BridgeBase)?.hasOutstandingOwnedWork ?? false)
        }
        private var hookPending: [Task<Void, Error>]?
        /// Main's closer contract: revoke the destination, cancel admitted work
        /// and await only the delegate's own retirement hook. For a BridgeBase
        /// the hook is terminal retirement, started but not joined.
        func retire() async {
            let pending = lock.withLock { () -> [Task<Void, Error>]? in
                guard !retired else { return nil }
                retired = true
                let pending = Array(tasks.values)
                hookPending = pending
                return pending
            }
            guard let pending else { return }
            // Cancellation handlers may re-enter lifecycle code.
            pending.forEach { $0.cancel() }
            if let bridge = delegate as? BridgeBase { bridge.beginRetirement() }
            else { await delegate.pushError(errorMessage: "bridge_logical_channel_closed", error: BridgeMultiplexError.channelNotFound) }
        }
        /// Full join (loopback D245/D248, used by closeAndJoin and background
        /// tracking): the BridgeBase is fully retired, then every dispatch that
        /// was admitted before retirement has actually returned.
        func retirementTask() -> Task<Void, Never> {
            lock.withLock {
                if let retirement { return retirement }
                let pending = hookPending ?? Array(tasks.values)
                let task = Task { [delegate] in
                    if let bridge = delegate as? BridgeBase { await bridge.finishRetirement() }
                    for task in pending { _ = try? await task.value }
                }
                retirement = task
                return task
            }
        }
    }

    /// One-shot completion shared by everyone that waits for a pending open.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                let immediate = lock.withLock { () -> Bool in
                    if done { return true }
                    waiters.append(continuation); return false
                }
                if immediate { continuation.resume() }
            }
        }
        func complete() {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
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

    fileprivate var channelSession: BridgeChannelSession? { physicalTransport.channelSession }
    private let physicalTransport: BridgeTransportProtocol
    private let channelFactory: ChannelFactory
    private let stateLock = NSLock()
    private let maximumChannels: Int
    private let maximumPendingChannelOpens: Int
    private let maximumTrackedOutboundStreams: Int
    private var channels: [String: ChannelRecord] = [:]
    // Retirements still running (owned work held). Tracked only for the
    // explicit closeAndJoin(); main's ID/capacity charge is sendingChannelIDs.
    private var retiringChannels: [ObjectIdentifier: ChannelRecord] = [:]
    private var pendingCompletions: [String: Completion] = [:]
    private var closeTask: Task<Void, Never>?
    private let beforeChannelSend: (@Sendable () async -> Void)?
    // A retired wire ID is unavailable until every admitted send has returned
    // from the physical transport, including non-cooperative queued sends.
    private var sendingChannelIDs: [String: Int] = [:]
    private var pendingChannelIDs: Set<String> = []
    private var cancelledPendingChannelIDs: Set<String> = []
    private var outboundStreamSequences: [String: OutboundSequenceEntry] = [:]
    private var outboundStreamInsertionOrder: [(streamID: String, insertionID: UInt64)] = []
    private var outboundStreamInsertionHead = 0
    private var outboundStreamInsertionID: UInt64 = 0
    private var commandID = 0
    private var closed = false
    /// G6 (opt-in, loopback D245/D248): a channel close, including the peer's
    /// closeChannel, is joined by every closer until the delegate is fully
    /// retired, every admitted dispatch has returned and every send on the
    /// channel has returned. The wire ID and its capacity stay reserved until
    /// then. Default false keeps main's non-blocking close and immediate reuse.
    public let closeJoinsChannelWork: Bool
    private var joiningChannels: [String: Task<Void, Never>] = [:]
    private let controlWork = BridgeOwnedTasks(maximumTasks: 128, maximumBytes: 4 * 1024 * 1024)
    private var sendDrainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        physicalTransport: BridgeTransportProtocol,
        maximumChannels: Int = 128,
        maximumPendingChannelOpens: Int = 32,
        maximumTrackedOutboundStreams: Int = 4_096,
        closeJoinsChannelWork: Bool = false,
        beforeChannelSend: (@Sendable () async -> Void)? = nil,
        channelFactory: @escaping ChannelFactory
    ) {
        self.closeJoinsChannelWork = closeJoinsChannelWork
        self.physicalTransport = physicalTransport
        self.beforeChannelSend = beforeChannelSend
        self.maximumChannels = max(1, maximumChannels)
        self.maximumPendingChannelOpens = max(1, min(maximumPendingChannelOpens, maximumChannels))
        self.maximumTrackedOutboundStreams = max(1, maximumTrackedOutboundStreams)
        self.channelFactory = channelFactory
        physicalTransport.setDelegate(self)
    }

    deinit {
        let physicalTransport = physicalTransport
        Task {
            await physicalTransport.close()
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
            if channelTransport.channelSession != nil {
                try bridge.activateAuthenticatedChannel()
            } else {
            try await bridge.consumeCommand(command: BridgeCommand(
                cmd: Command.ready.rawValue,
                identity: bridgeOwner,
                payload: nil,
                cid: 0,
                protocolVersion: 2
            ))
            }
            return bridge
        }
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        guard let channelSession else { throw BridgeChannelAuthentication.Failure.unavailable }
        try channelSession.check(identity: command.identity, requiresIdentity: command.command != .response)
        if command.command == .ready { throw BridgeChannelAuthentication.Failure.unexpectedMessage }
        switch command.command {
        case .openChannel:
            try await open(command)
        case .closeChannel:
            guard command.protocolVersion == protocolVersion,
                  let channelID = command.channelID,
                  BridgeMultiplexSession.isValidChannelID(channelID) else {
                throw BridgeMultiplexError.invalidChannel
            }
            await closeChannel(channelID)
        default:
            guard command.protocolVersion == protocolVersion,
                  let channelID = command.channelID,
                  let record = stateLock.withLock({ channels[channelID] }) else {
                throw BridgeMultiplexError.channelNotFound
            }
            defer { withExtendedLifetime(record) {} }
            try await record.dispatch(command)
        }
    }

    private func closeChannel(_ channelID: String, expected: ChannelRecord? = nil) async {
        let (removed, join) = stateLock.withLock { () -> (ChannelRecord?, Task<Void, Never>?) in
            if pendingChannelIDs.contains(channelID) { cancelledPendingChannelIDs.insert(channelID) }
            if let expected, channels[channelID] !== expected { return (nil, joiningChannels[channelID]) }
            guard let removed = channels.removeValue(forKey: channelID) else { return (nil, joiningChannels[channelID]) }
            outboundStreamSequences = outboundStreamSequences.filter { !$0.key.hasPrefix("\(channelID)|") }
            compactOutboundStreamInsertionOrderIfNeeded()
            guard closeJoinsChannelWork else {
                if removed.hasInFlightWork { retiringChannels[ObjectIdentifier(removed)] = removed }
                return (removed, nil)
            }
            // G6: the ID stays reserved by the join itself; every closer of
            // this ID awaits the same task.
            retiringChannels[ObjectIdentifier(removed)] = removed
            let key = ObjectIdentifier(removed)
            let task = Task { [self] in
                await removed.retire()
                await removed.retirementTask().value
                await waitForSendsToDrain(channelID)
                stateLock.withLock {
                    _ = retiringChannels.removeValue(forKey: key)
                    joiningChannels[channelID] = nil
                }
                withExtendedLifetime(removed) {}
            }
            joiningChannels[channelID] = task
            return (removed, task)
        }
        defer { withExtendedLifetime(removed) {} }
        if let join {
            guard closeJoinsChannelWork else { return }
            await join.value
            return
        }
        guard let removed else { return }
        await removed.retire()
        if stateLock.withLock({ retiringChannels[ObjectIdentifier(removed)] != nil }) { trackRetirement(removed) }
    }

    private func waitForSendsToDrain(_ channelID: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate = stateLock.withLock { () -> Bool in
                guard sendingChannelIDs[channelID] != nil else { return true }
                sendDrainWaiters[channelID, default: []].append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    /// Starts a retirement that may be held by non-cooperative work; the record
    /// is forgotten once it has actually returned. Closers never wait for it.
    private func trackRetirement(_ record: ChannelRecord) {
        let retirement = record.retirementTask()
        let key = ObjectIdentifier(record)
        Task { [self] in
            await retirement.value
            _ = stateLock.withLock { retiringChannels.removeValue(forKey: key) }
        }
    }

    /// Started by the channel's own transport (its delegate). Never joins: the
    /// caller may be owned work of the very retirement it starts.
    fileprivate func beginClosingChannel(_ channelID: String, matching transport: ServerChannelTransport) {
        let owned = stateLock.withLock { channels[channelID]?.transport === transport }
        guard owned else { return }
        Task { [self] in await closeChannel(channelID) }
    }

    /// Explicit owner join (loopback D245 guarantee, opt-in): closes the session,
    /// then waits until every channel retirement and every pending factory has
    /// actually returned. close() keeps main's non-blocking contract.
    public func closeAndJoin() async {
        await close()
        let (records, pending, joins) = stateLock.withLock {
            (Array(retiringChannels.values), Array(pendingCompletions.values), Array(joiningChannels.values))
        }
        for record in records { await record.retirementTask().value }
        for completion in pending { await completion.wait() }
        for join in joins { await join.value }
        await controlWork.finishStop()
    }

    func prepareInboundDispatch(_ command: BridgeCommand) -> BridgeInboundDispatch? {
        guard command.protocolVersion == protocolVersion, command.command != .openChannel,
              command.command != .ready, let channelID = command.channelID,
              BridgeMultiplexSession.isValidChannelID(channelID),
              let record = stateLock.withLock({ closed ? nil : channels[channelID] }) else { return nil }
        return BridgeInboundDispatch(laneID: ObjectIdentifier(record),
                                     bypassesOrdering: command.command == .closeChannel) { [self, record] in
            guard let channelSession else { throw BridgeChannelAuthentication.Failure.unavailable }
            try channelSession.check(identity: command.identity, requiresIdentity: command.command != .response)
            if command.command == .closeChannel {
                await closeChannel(channelID, expected: record)
            } else {
                try await record.dispatch(command, response: command.command == .response)
            }
        }
    }

    func isOriginSigningResponse(_ command: BridgeCommand) -> Bool {
        guard command.protocolVersion == protocolVersion, let id = command.channelID,
              let bridge = stateLock.withLock({ channels[id]?.delegate }) as? BridgeBase else { return false }
        return bridge.isOriginSigningResponse(command)
    }

    public func consumeResponse(command: BridgeCommand) async throws {
        guard let channelSession else { throw BridgeChannelAuthentication.Failure.unavailable }
        try channelSession.check(identity: command.identity)
        guard command.protocolVersion == protocolVersion,
              let channelID = command.channelID,
              let record = stateLock.withLock({ channels[channelID] }) else {
            throw BridgeMultiplexError.channelNotFound
        }
        defer { withExtendedLifetime(record) {} }
        try await record.dispatch(command, response: true)
    }

    private func open(_ command: BridgeCommand) async throws {
        // Reserve the response lifetime before any rejection audit/factory await.
        // Even a delayed rejection for an old open cannot target a later reuse.
        let reservedID = command.channelID.flatMap { BridgeMultiplexSession.isValidChannelID($0) ? $0 : nil }
        let previousSends = stateLock.withLock { () -> Int in
            guard let reservedID else { return 0 }
            let previous = sendingChannelIDs[reservedID, default: 0]
            sendingChannelIDs[reservedID] = previous + 1
            return previous
        }
        defer { if let reservedID { releaseSendReservation(reservedID) } }

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
            guard channels[channelID] == nil,
                  joiningChannels[channelID] == nil,
                  pendingChannelIDs.contains(channelID) == false,
                  previousSends == 0 else {
                return .conflict
            }
            let retainedIDs = Set(channels.keys).union(pendingChannelIDs)
                .union(sendingChannelIDs.keys).union(joiningChannels.keys).subtracting([channelID])
            guard retainedIDs.count < maximumChannels,
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
            let completion = stateLock.withLock { () -> Completion? in
                pendingChannelIDs.remove(channelID)
                cancelledPendingChannelIDs.remove(channelID)
                return pendingCompletions.removeValue(forKey: channelID)
            }
            completion?.complete()
        }

        var result: ChannelRecord?
        let channelTransport = ServerChannelTransport(session: self, channelID: channelID)
        do {
            guard let channelSession else { throw BridgeChannelAuthentication.Failure.closed }
            let quota = try BridgeChannelResourceLease(session: channelSession, resource: .channel)
            defer { withExtendedLifetime(quota) {} }
            try channelSession.check(identity: identity, requiresIdentity: true)
            guard let principal = channelSession.publicIdentity?.makeIdentity() else { throw BridgeChannelAuthentication.Failure.closed }
            let delegate = try await channelFactory(targetEndpoint, principal, channelTransport)
            // Own cleanup immediately, including a throwing session check.
            let record = ChannelRecord(delegate: delegate, transport: channelTransport, quota: quota)
            result = record
            let inserted = try stateLock.withLock { () throws -> Bool in
                try Task.checkCancellation()
                try channelSession.check(identity: identity, requiresIdentity: true)
                guard !closed, pendingChannelIDs.contains(channelID),
                      !cancelledPendingChannelIDs.contains(channelID), channels[channelID] == nil else { return false }
                channelTransport.setDelegate(delegate)
                channels[channelID] = record
                return true
            }
            guard inserted else { await record.retire(); return }
            let opened = BridgeCommand(cmd: Command.channelOpened.rawValue, identity: identity,
                payload: nil, cid: command.cid, protocolVersion: protocolVersion, channelID: channelID)
            try await send(JSONEncoder().encode(opened), channelID: channelID, transport: channelTransport)
        } catch {
            stateLock.withLock {
                if let result, channels[channelID] === result { channels[channelID] = nil }
                outboundStreamSequences = outboundStreamSequences.filter { !$0.key.hasPrefix("\(channelID)|") }
                compactOutboundStreamInsertionOrderIfNeeded()
            }
            // A factory may have installed a delegate before failing: retire it
            // before the reservation is released (loopback D245).
            if let result { await result.retire() }
            else { channelTransport.beginRetiringDelegate() }
            guard stateLock.withLock({ !closed && !cancelledPendingChannelIDs.contains(channelID) }),
                  !Task.isCancelled, (try? channelSession?.check()) != nil else { return }
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

    fileprivate func send(_ data: Data, channelID: String, transport: ServerChannelTransport) async throws {
        // The object guard and reservation are one decision. A close may now
        // remove the record, but open cannot reuse its wire ID until defer runs.
        let record = try stateLock.withLock { () throws -> ChannelRecord in
            guard !closed, let record = channels[channelID], record.transport === transport else {
                throw BridgeMultiplexError.channelNotFound
            }
            sendingChannelIDs[channelID, default: 0] += 1
            return record
        }
        defer {
            releaseSendReservation(channelID)
            withExtendedLifetime(record) {}
        }
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

    private func releaseSendReservation(_ channelID: String) {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard let count = sendingChannelIDs[channelID] else { return [] }
            if count == 1 {
                sendingChannelIDs[channelID] = nil
                return sendDrainWaiters.removeValue(forKey: channelID) ?? []
            }
            sendingChannelIDs[channelID] = count - 1
            return []
        }
        waiters.forEach { $0.resume() }
    }

    fileprivate func vault(for identity: Identity?) async -> IdentityVaultProtocol {
        await physicalTransport.identityVault(for: identity)
    }

    private func sendSessionFrame(_ command: BridgeCommand) async throws {
        guard stateLock.withLock({ closed == false }) else {
            throw BridgeMultiplexError.sessionClosed
        }
        // Control responses must not outlive an ID reservation either (a held
        // channelRejected must not reject a subsequent open using the same cid).
        let id = command.channelID
        if let id { stateLock.withLock { sendingChannelIDs[id, default: 0] += 1 } }
        defer { if let id { releaseSendReservation(id) } }
        try await physicalTransport.sendData(JSONEncoder().encode(command))
    }

    public func close() async {
        // One physical close shared by every closer. Pending factories own their
        // reservations until they return; channel work is not joined here.
        let task = stateLock.withLock { () -> Task<Void, Never> in
            if let closeTask { return closeTask }
            closed = true
            let open = channels
            for record in open.values where record.hasInFlightWork { retiringChannels[ObjectIdentifier(record)] = record }
            channels.removeAll(keepingCapacity: false)
            cancelledPendingChannelIDs.formUnion(pendingChannelIDs)
            outboundStreamSequences.removeAll(keepingCapacity: false)
            outboundStreamInsertionOrder.removeAll(keepingCapacity: false)
            outboundStreamInsertionHead = 0
            let task = Task { [self] in
                for record in open.values {
                    await record.retire()
                    if stateLock.withLock({ retiringChannels[ObjectIdentifier(record)] != nil }) { trackRetirement(record) }
                }
                await physicalTransport.close()
                withExtendedLifetime(open) {}
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

    var retainedOutboundStreamSlotCount: Int { stateLock.withLock { outboundStreamInsertionOrder.count } }

    private func compactOutboundStreamInsertionOrderIfNeeded() {
        if outboundStreamSequences.isEmpty {
            outboundStreamInsertionOrder.removeAll(keepingCapacity: false); outboundStreamInsertionHead = 0
            return
        }
        guard outboundStreamInsertionHead > maximumTrackedOutboundStreams
                || (outboundStreamInsertionOrder.count > maximumTrackedOutboundStreams
                    && outboundStreamInsertionOrder.count - maximumTrackedOutboundStreams > maximumTrackedOutboundStreams) else { return }
        outboundStreamInsertionOrder = outboundStreamInsertionOrder.filter {
            outboundStreamSequences[$0.streamID]?.insertionID == $0.insertionID
        }
        outboundStreamInsertionHead = 0
    }

    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        let cid = stateLock.withLock { () -> Int in
            commandID += 1
            return commandID
        }
        let frame = BridgeCommand(
            cmd: command.rawValue,
            identity: identity,
            payload: payload,
            cid: cid,
            protocolVersion: protocolVersion
        )
        // G6: a session control send is owned by the session, so closeAndJoin
        // waits until it has returned from the physical transport.
        guard let task = controlWork.submit({ [self] in try await sendSessionFrame(frame) }) else { return }
        _ = try? await task.value
    }

    public func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        _ = requestedKey
        _ = setValueState
    }

    public func pushError(errorMessage: String?, error: Error?) async { await close() }

    public func ready() async throws {}

    fileprivate final class ServerChannelTransport: BridgeTransportProtocol, @unchecked Sendable {
        var channelSession: BridgeChannelSession? { session?.channelSession }
        private weak var delegate: BridgeDelegateProtocol?
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
            self.delegate = delegate
        }

        func setup(_ endpointURL: URL, identity: Identity) async throws {
            _ = endpointURL
            _ = identity
        }

        func sendData(_ data: Data) async throws {
            guard let session else { throw BridgeMultiplexError.sessionClosed }
            await session.beforeChannelSend?()
            try await session.send(data, channelID: channelID, transport: self)
        }

        /// Starts terminal retirement of an installed BridgeBase delegate.
        func beginRetiringDelegate() {
            (delegate as? BridgeBase)?.beginRetirement()
        }

        /// Called by the channel's own delegate (BridgeBase's finalizer included),
        /// so it only starts the channel's retirement; external closers join.
        func close() async {
            session?.beginClosingChannel(channelID, matching: self)
        }

        func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
            guard let session else { return BridgeIdentityVault() }
            return await session.vault(for: identity)
        }
    }
}
