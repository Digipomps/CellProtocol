// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// One process-wide quota owner, shared by all public bridge routes. Source must
/// come from the socket/trusted proxy, not an unverified forwarded header.
public final class BridgeChannelLimits: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maximumConnections = 512
        public var maximumPending = 256
        public var maximumPendingPerSource = 4
        public var maximumConnectionsPerKey = 8
        public var maximumOperations = 256
        public var maximumFeeds = 128
        public var maximumChannels = 256
        public var maximumOutstandingWork = 512
        public var maximumOutstandingWorkPerConnection = 64
        public var maximumOperationsPerKey = 32
        public var maximumFeedsPerKey = 16
        public var maximumChannelsPerKey = 16
        public var maximumPendingSendBytes = 16 * 1024 * 1024
        public var maximumPendingSendBytesPerConnection = 4 * 1024 * 1024
        public var maximumAttemptsPerMinute = 512
        public var maximumAttemptsPerSourcePerMinute = 60
        public var maximumVerifiedHandshakesPerKeyPerMinute = 12
        public var maximumRateBuckets = 4096
        public init() {}
    }
    private struct Entry {
        let source: String
        var principal: String?
        var active = false
        var closed = false
        var work = 0
        var admissions = 0
        var transportRetained = false
        var retainsPending: Bool { !active || admissions > 0 }
        var hasResources: Bool { operations > 0 || feeds > 0 || channels > 0 || sendBytes > 0 || work > 0 || transportRetained }
        var operations = 0
        var feeds = 0
        var channels = 0
        var sendBytes = 0
        let revoke: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    public let configuration: Configuration
    private struct RateBucket { var started: TimeInterval; var count: Int }
    private var rateBuckets: [String: RateBucket] = [:]
    private let monotonic: @Sendable () -> TimeInterval
    public init(configuration: Configuration = .init(),
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration; self.monotonic = monotonic
    }

    // Fixed 60-second windows. Entries outlive sockets, so close/reconnect cannot
    // reset the rate. Never allocate a bucket from an unverified identity UUID.
    private func consumeRate(_ key: String, maximum: Int) throws {
        let now = monotonic()
        rateBuckets = rateBuckets.filter { now < $0.value.started + 60 }
        if var bucket = rateBuckets[key] {
            guard bucket.count < maximum else { throw BridgeChannelAuthentication.Failure.capacity }
            bucket.count += 1; rateBuckets[key] = bucket
        } else {
            guard maximum > 0, rateBuckets.count < configuration.maximumRateBuckets else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            rateBuckets[key] = RateBucket(started: now, count: 1)
        }
    }

    func reserve(_ id: String, source: String, revoke: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard source.utf8.count <= 256 else { throw BridgeChannelAuthentication.Failure.capacity }
            try consumeRate("global", maximum: configuration.maximumAttemptsPerMinute)
            try consumeRate("source:" + source, maximum: configuration.maximumAttemptsPerSourcePerMinute)
            guard entries[id] == nil,
                  entries.count < configuration.maximumConnections,
                  entries.values.filter({ $0.retainsPending }).count < configuration.maximumPending,
                  entries.values.filter({ $0.retainsPending && $0.source == source }).count < configuration.maximumPendingPerSource else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            entries[id] = Entry(source: source, revoke: revoke)
        }
    }
    func authenticate(_ id: String, principal: String) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.closed, entry.principal == nil else { throw BridgeChannelAuthentication.Failure.closed }
            guard entries.values.filter({ $0.principal == principal }).count < configuration.maximumConnectionsPerKey else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            try consumeRate("key:" + principal, maximum: configuration.maximumVerifiedHandshakesPerKeyPerMinute)
            entry.principal = principal
            entries[id] = entry
        }
    }
    func activate(_ id: String) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.closed, entry.principal != nil, !entry.active else { throw BridgeChannelAuthentication.Failure.closed }
            entry.active = true; entries[id] = entry
        }
    }
    enum Resource { case operation, feed, channel }
    func acquire(_ id: String, resource: Resource) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.closed, let principal = entry.principal else { throw BridgeChannelAuthentication.Failure.closed }
            let related = entries.values.filter { $0.principal == principal }
            switch resource {
            case .operation:
                guard related.reduce(0, { $0 + $1.operations }) < configuration.maximumOperationsPerKey,
                      entries.values.reduce(0, { $0 + $1.operations }) < configuration.maximumOperations else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.operations += 1
            case .feed:
                guard related.reduce(0, { $0 + $1.feeds }) < configuration.maximumFeedsPerKey,
                      entries.values.reduce(0, { $0 + $1.feeds }) < configuration.maximumFeeds else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.feeds += 1
            case .channel:
                guard related.reduce(0, { $0 + $1.channels }) < configuration.maximumChannelsPerKey,
                      entries.values.reduce(0, { $0 + $1.channels }) < configuration.maximumChannels else { throw BridgeChannelAuthentication.Failure.capacity }
                entry.channels += 1
            }
            entries[id] = entry
        }
    }
    func release(_ id: String, resource: Resource) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            switch resource {
            case .operation: entry.operations = max(0, entry.operations - 1)
            case .feed: entry.feeds = max(0, entry.feeds - 1)
            case .channel: entry.channels = max(0, entry.channels - 1)
            }
            storeOrRemove(entry, id: id)
        }
    }
    func acquireSend(_ id: String, bytes: Int) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.closed else { throw BridgeChannelAuthentication.Failure.closed }
            guard bytes >= 0, bytes <= configuration.maximumPendingSendBytesPerConnection - entry.sendBytes,
                  bytes <= configuration.maximumPendingSendBytes - entries.values.reduce(0, { $0 + $1.sendBytes }) else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            entry.sendBytes += bytes
            entries[id] = entry
        }
    }
    func releaseSend(_ id: String, bytes: Int) {
        lock.withLock { if var entry = entries[id] { entry.sendBytes = max(0, entry.sendBytes - bytes); storeOrRemove(entry, id: id) } }
    }
    // Closed entries are bounded tombstones, retained only while owned work lives.
    // They still count against admission and principal/global resource budgets.
    private func storeOrRemove(_ entry: Entry, id: String) {
        if entry.closed && !entry.hasResources { entries[id] = nil }
        else { entries[id] = entry }
    }
    func release(_ id: String) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.closed = true
            storeOrRemove(entry, id: id)
        }
    }
    func retainTransport(_ id: String) {
        lock.withLock { if var entry = entries[id] { entry.transportRetained = true; entries[id] = entry } }
    }
    func releaseTransport(_ id: String) {
        lock.withLock { if var entry = entries[id] { entry.transportRetained = false; storeOrRemove(entry, id: id) } }
    }
    func acquireWork(_ id: String, admission: Bool) throws {
        try lock.withLock {
            guard var entry = entries[id], !entry.closed else { throw BridgeChannelAuthentication.Failure.closed }
            guard entry.work < configuration.maximumOutstandingWorkPerConnection,
                  entries.values.reduce(0, { $0 + $1.work }) < configuration.maximumOutstandingWork else {
                throw BridgeChannelAuthentication.Failure.capacity
            }
            entry.work += 1
            if admission { entry.admissions += 1 }
            entries[id] = entry
        }
    }
    func releaseWork(_ id: String, admission: Bool) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.work = max(0, entry.work - 1)
            if admission { entry.admissions = max(0, entry.admissions - 1) }
            storeOrRemove(entry, id: id)
        }
    }
    public var connectionCount: Int { lock.withLock { entries.values.filter { !$0.closed }.count } }
    /// Includes resources whose socket has gone away but whose work has not returned.
    public var outstandingWorkCount: Int { lock.withLock { entries.values.reduce(0, { $0 + $1.work }) } }
    public var retainedConnectionCount: Int { lock.withLock { entries.count } }

    /// Local host policy calls this after its authoritative key status changes.
    /// This only revokes active transport leases; Cells still own grant revocation.
    public func revoke(identity: BridgeChannelAuthentication.PublicIdentity, domain: String) {
        let principal = Self.principal(identity: identity, domain: domain)
        let callbacks = lock.withLock { entries.values.filter { $0.principal == principal }.map(\.revoke) }
        callbacks.forEach { $0() }
    }
    static func principal(identity: BridgeChannelAuthentication.PublicIdentity, domain: String) -> String {
        // Canonical JSON array avoids delimiter collisions in caller-controlled scopes.
        let fields = [domain, identity.uuid, identity.makeIdentity().signingPublicKeyFingerprint ?? ""]
        return BridgeChannelAuthentication.digest(try! BridgeChannelAuthentication.encode(fields))
    }
}

/// Immutable principal plus connection-owned lease. Not Codable, not a bearer
/// credential. Only the verifier/client acknowledgement can activate it.
public final class BridgeChannelSession: @unchecked Sendable {
    public typealias Auth = BridgeChannelAuthentication
    public enum State: String, Sendable { case unauthenticated, challengeIssued, verifying, authenticated, closed, revoked }
    private let lock = NSLock()
    private var stateValue: State = .unauthenticated
    private struct Pending {
        let sessionID: String
        let identity: Auth.PublicIdentity
        let signingData: Data
        let digest: String
        let issued: Int64
        let expires: Int64
    }
    private var pending: Pending?
    private var identityValue: Auth.PublicIdentity?
    private var authValue: Auth.Authenticated?
    private var absoluteExpiry: Date?
    private var handshakeExpiry: Date?
    private var deadline: TimeInterval
    private let monotonic: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private let limits: BridgeChannelLimits?
    public let generation = UUID().uuidString
    public let endpoint: Auth.Endpoint?
    public let peerEndpoint: BridgePeerChannelAuthentication.Endpoint?
    private let localPeerIdentity: Auth.PublicIdentity?
    private var domain: String { peerEndpoint?.domain ?? endpoint!.domain }
    private var closedCallback: (@Sendable () -> Void)?

    public init(endpoint: Auth.Endpoint, limits: BridgeChannelLimits? = nil, source: String = "local",
                wallClock: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        try endpoint.validate()
        self.endpoint = endpoint; self.peerEndpoint = nil; self.localPeerIdentity = nil; self.limits = limits; self.wallClock = wallClock; self.monotonic = monotonic
        deadline = monotonic() + 10
        try limits?.reserve(generation, source: source) { [weak self] in self?.revoke() }
    }
    init(peerEndpoint: BridgePeerChannelAuthentication.Endpoint, localIdentity: Auth.PublicIdentity,
         limits: BridgeChannelLimits, source: String) throws {
        try peerEndpoint.validate()
        endpoint = nil; self.peerEndpoint = peerEndpoint; localPeerIdentity = localIdentity
        self.limits = limits; wallClock = { Date() }; monotonic = { ProcessInfo.processInfo.systemUptime }
        deadline = ProcessInfo.processInfo.systemUptime + 10
        try limits.reserve(generation, source: source) { [weak self] in self?.revoke() }
    }
    func issuePeerChallenge(_ challenge: BridgePeerChannelAuthentication.Challenge) throws {
        try lock.withLock {
            guard stateValue == .unauthenticated, monotonic() < deadline,
                  challenge.transcript.initiator.endpoint == peerEndpoint,
                  challenge.generation == generation else { throw Auth.Failure.unexpectedMessage }
            pending = Pending(sessionID: challenge.sessionID, identity: challenge.identity,
                signingData: challenge.signingData, digest: Auth.digest(try Auth.encode(challenge.transcript)),
                issued: challenge.transcript.issued, expires: challenge.transcript.issued + Int64(Auth.channelLifetime * 1000))
            handshakeExpiry = Date(timeIntervalSince1970: Double(challenge.transcript.issued) / 1000 + Auth.challengeLifetime)
            stateValue = .challengeIssued
        }
    }
    /// Peer requests originate locally; incoming requests remain bound to the remote proof.
    func checkOutbound(identity: Identity?, requiresIdentity: Bool = false) throws {
        guard let localPeerIdentity else { return try check(identity: identity, requiresIdentity: requiresIdentity) }
        try check()
        guard let identity, (try? Auth.PublicIdentity(identity)) == localPeerIdentity else { throw Auth.Failure.identityMismatch }
    }
    func checkInbound(_ command: BridgeCommand) throws {
        if localPeerIdentity != nil, command.command == .sign {
            try checkOutbound(identity: command.identity, requiresIdentity: true)
        } else if localPeerIdentity != nil, command.command == .response {
            try check()
            if let identity = command.identity,
               (try? Auth.PublicIdentity(identity)) != localPeerIdentity { try check(identity: identity) }
        } else { try check(identity: command.identity, requiresIdentity: command.command != .response) }
    }
    deinit { limits?.release(generation) }
    public var state: State { lock.withLock { stateValue } }
    public var publicIdentity: Auth.PublicIdentity? { lock.withLock { identityValue } }
    public var expiresAt: Date? { lock.withLock { absoluteExpiry } }
    func onClose(_ callback: @escaping @Sendable () -> Void) { lock.withLock { closedCallback = callback } }

    public func issueChallenge(_ hello: Auth.Hello) throws -> Auth.Challenge {
        try lock.withLock {
            guard stateValue == .unauthenticated else { throw Auth.Failure.unexpectedMessage }
            guard monotonic() < deadline else { throw Auth.Failure.expired }
            guard let endpoint else { throw Auth.Failure.unexpectedMessage }
            let challenge = try Auth.challenge(hello: hello, endpoint: endpoint, generation: generation, now: wallClock())
            pending = Pending(sessionID: challenge.transcript.sessionID, identity: challenge.transcript.identity,
                signingData: challenge.signingData, digest: Auth.digest(try Auth.encode(challenge.transcript)),
                issued: challenge.transcript.issuedAtMilliseconds, expires: challenge.transcript.channelExpiresAtMilliseconds)
            handshakeExpiry = Date(timeIntervalSince1970: Double(challenge.transcript.issuedAtMilliseconds) / 1000 + Auth.challengeLifetime)
            stateValue = .challengeIssued
            return challenge
        }
    }

    /// Generalizes PersonEntityReadRouteCoordinator's reserve/recheck/activate
    /// sequence. Consume before expensive verification; no concurrent winner and
    /// no replacement of pending bytes from the wire. No vault is consulted.
    public func reserveOpen(_ proof: Auth.Proof) throws {
        let challenge = try lock.withLock { () throws -> Pending in
            guard stateValue == .challengeIssued, let pending else { throw Auth.Failure.unexpectedMessage }
            guard monotonic() < deadline,
                  wallClock().timeIntervalSince1970 < Double(pending.issued) / 1000 + Auth.challengeLifetime else {
                throw Auth.Failure.expired
            }
            guard proof.sessionID == pending.sessionID, proof.generation == generation else { throw Auth.Failure.staleGeneration }
            stateValue = .verifying
            self.pending = nil
            return pending
        }
        guard proof.signature.count <= 256,
              IdentityPublicKeySignatureVerifier.verify(signature: proof.signature, messageData: challenge.signingData,
                identity: challenge.identity.makeIdentity()) else {
            close(); throw Auth.Failure.invalidProof
        }
        try lock.withLock {
            guard stateValue == .verifying, monotonic() < deadline else { throw Auth.Failure.expired }
            try limits?.authenticate(generation, principal: BridgeChannelLimits.principal(identity: challenge.identity, domain: domain))
            identityValue = challenge.identity
            absoluteExpiry = Date(timeIntervalSince1970: Double(challenge.expires) / 1000)
            authValue = Auth.Authenticated(sessionID: proof.sessionID, generation: generation,
                transcriptDigest: challenge.digest)
        }
    }

    /// Call again after any awaited route/policy check and before Cell creation.
    public func recheckBeforeActivation() throws {
        try lock.withLock {
            guard stateValue == .verifying, identityValue != nil, monotonic() < deadline,
                  let expiry = absoluteExpiry, wallClock() < expiry,
                  let handshakeExpiry, wallClock() < handshakeExpiry else { throw Auth.Failure.expired }
        }
    }
    func peerAcknowledgement() throws -> Auth.Authenticated {
        try recheckBeforeActivation()
        return try lock.withLock { guard peerEndpoint != nil, let authValue else { throw Auth.Failure.unexpectedMessage }; return authValue }
    }
    public func activate() throws -> Auth.Authenticated {
        try lock.withLock {
            guard stateValue == .verifying, monotonic() < deadline, let authValue,
                  let expiry = absoluteExpiry, wallClock() < expiry,
                  let handshakeExpiry, wallClock() < handshakeExpiry else { throw Auth.Failure.expired }
            try limits?.activate(generation)
            deadline = monotonic() + min(Auth.channelLifetime, expiry.timeIntervalSince(wallClock()))
            stateValue = .authenticated
            return authValue
        }
    }

    func acceptAcknowledgement(_ acknowledgement: Auth.Authenticated, challenge: Auth.Challenge) throws {
        try lock.withLock {
            guard stateValue == .unauthenticated, monotonic() < deadline,
                  acknowledgement.sessionID == challenge.transcript.sessionID,
                  acknowledgement.generation == challenge.transcript.generation,
                  acknowledgement.transcriptDigest == Auth.digest(try Auth.encode(challenge.transcript)) else { throw Auth.Failure.invalidProof }
            let expiry = Date(timeIntervalSince1970: Double(challenge.transcript.channelExpiresAtMilliseconds) / 1000)
            guard wallClock() < expiry else { throw Auth.Failure.expired }
            identityValue = challenge.transcript.identity
            authValue = acknowledgement
            absoluteExpiry = expiry
            deadline = monotonic() + min(Auth.channelLifetime, expiry.timeIntervalSince(wallClock()))
            stateValue = .authenticated
        }
    }

    public func check(identity: Identity? = nil, requiresIdentity: Bool = false) throws {
        try lock.withLock {
            guard stateValue == .authenticated else { throw stateValue == .revoked ? Auth.Failure.revoked : Auth.Failure.closed }
            guard monotonic() < deadline, let expiry = absoluteExpiry, wallClock() < expiry else { throw Auth.Failure.expired }
            if let identity {
                guard let identityValue, (try? Auth.PublicIdentity(identity)) == identityValue else { throw Auth.Failure.identityMismatch }
            } else if requiresIdentity { throw Auth.Failure.identityMismatch }
        }
    }
    /// Pool reuse includes a live handshake, never a terminal or expired lease.
    func canReuseConnection() -> Bool {
        lock.withLock {
            guard stateValue != .closed && stateValue != .revoked, monotonic() < deadline else { return false }
            return absoluteExpiry.map { wallClock() < $0 } ?? true
        }
    }
    func retainTransport() { limits?.retainTransport(generation) }
    func releaseTransport() { limits?.releaseTransport(generation) }
    func acquireWork(admission: Bool) throws { try limits?.acquireWork(generation, admission: admission) }
    func releaseWork(admission: Bool) { limits?.releaseWork(generation, admission: admission) }
    func acquireSend(bytes: Int, authenticating: Bool = false) throws {
        if !authenticating { try check() }
        try limits?.acquireSend(generation, bytes: bytes)
    }
    func releaseSend(bytes: Int) { limits?.releaseSend(generation, bytes: bytes) }
    func acquire(_ resource: BridgeChannelLimits.Resource) throws {
        try check()
        try limits?.acquire(generation, resource: resource)
    }
    func release(_ resource: BridgeChannelLimits.Resource) { limits?.release(generation, resource: resource) }
    public func requester(for presented: Identity, bridge: BridgeProtocol) throws -> Identity {
        try check(identity: presented, requiresIdentity: true)
        guard let descriptor = publicIdentity else { throw Auth.Failure.closed }
        let identity = descriptor.makeIdentity()
        identity.identityVault = BridgeIdentityVault(cloudBridge: bridge)
        return identity
    }
    public func revoke() { terminate(.revoked) }
    public func close() { terminate(.closed) }
    private func terminate(_ state: State) {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard stateValue != .closed && stateValue != .revoked else { return nil }
            stateValue = state; pending = nil; authValue = nil
            let callback = closedCallback; closedCallback = nil
            return callback
        }
        limits?.release(generation)
        callback?()
    }
}

/// A reservation is released exactly once, independently of socket table removal.
final class BridgeChannelResourceLease: @unchecked Sendable {
    private let session: BridgeChannelSession
    private let resource: BridgeChannelLimits.Resource
    private let lock = NSLock()
    private var released = true
    init(session: BridgeChannelSession, resource: BridgeChannelLimits.Resource) throws {
        self.session = session; self.resource = resource
        try session.acquire(resource)
        // A throwing initializer also runs deinit: ownership starts only here.
        released = false
    }
    func release() {
        let shouldRelease = lock.withLock { if released { return false }; released = true; return true }
        if shouldRelease { session.release(resource) }
    }
    deinit { release() }
}
