// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Auth gate around one physical transport. Server factory is not called until
/// proof consumption, policy recheck and activation succeed. All logical channels
/// on a multiplex connection share its proven principal and generation.
public final class BridgeChannelTransport: BridgeTransportProtocol, BridgeDelegateProtocol, @unchecked Sendable {
    public typealias Auth = BridgeChannelAuthentication
    public typealias ServerFactory = @Sendable (BridgeChannelTransport, BridgeChannelSession) async throws -> BridgeDelegateProtocol
    public let uuid = UUID().uuidString
    public var channelSession: BridgeChannelSession? { session }
    public let session: BridgeChannelSession
    private var underlying: BridgeTransportProtocol?
    private let newPhysicalTransport: () -> BridgeTransportProtocol
    private let lock = NSLock()
    private var delegate: BridgeDelegateProtocol?
    private let factory: ServerFactory?
    private let recheckPolicy: @Sendable (Auth.PublicIdentity) async throws -> Void
    private var operation: BridgeChannelClientOperation?
    private var peerOperation: BridgePeerChannelAuthentication.Operation?
    private var peerReady = false
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var pendingSends = 0
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private let isServer: Bool

    /// The host must supply its configured public endpoint, not request headers.
    /// Construct before installing any callback capable of resolving Cells.
    public init(underlying: BridgeTransportProtocol, endpoint: Auth.Endpoint,
                limits: BridgeChannelLimits, source: String,
                recheckPolicy: @escaping @Sendable (Auth.PublicIdentity) async throws -> Void = { _ in },
                wallClock: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                factory: @escaping ServerFactory) throws {
        self.underlying = underlying
        self.newPhysicalTransport = { [transportType = type(of: underlying)] in transportType.new() }
        self.session = try BridgeChannelSession(endpoint: endpoint, limits: limits, source: source, wallClock: wallClock, monotonic: monotonic)
        self.factory = factory; self.recheckPolicy = recheckPolicy; isServer = true
        install()
    }
    public init(underlying: BridgeTransportProtocol, endpoint: Auth.Endpoint) throws {
        self.underlying = underlying; self.newPhysicalTransport = { [transportType = type(of: underlying)] in transportType.new() }; self.session = try BridgeChannelSession(endpoint: endpoint)
        self.factory = nil; self.recheckPolicy = { _ in }; isServer = false
        install()
    }
    public init(underlying: BridgeTransportProtocol, peerEndpoint: BridgePeerChannelAuthentication.Endpoint,
                role: BridgePeerChannelAuthentication.Role, owner: Identity, limits: BridgeChannelLimits,
                source: String, recheckPolicy: @escaping @Sendable (Auth.PublicIdentity) async throws -> Void = { _ in },
                factory: @escaping ServerFactory) throws {
        self.underlying = underlying; newPhysicalTransport = { type(of: underlying).new() }
        session = try BridgeChannelSession(peerEndpoint: peerEndpoint, localIdentity: Auth.PublicIdentity(owner), limits: limits, source: source)
        peerOperation = try .init(owner: owner, endpoint: peerEndpoint, role: role, generation: session.generation)
        self.factory = factory; self.recheckPolicy = recheckPolicy; isServer = true
        install()
    }
    public func startPeer() async throws {
        guard let peer = lock.withLock({ peerOperation }),
              lock.withLock({ if started || stopped { return false }; started = true; return true }) else { throw Auth.Failure.unexpectedMessage }
        do {
            if peer.hello.role == .initiator { try await sendAuth("channelAuthPeerHello", peer.hello) }
            while !lock.withLock({ peerReady }) {
                guard !lock.withLock({ stopped }) else { throw Auth.Failure.closed }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try session.check()
        } catch { await close(); throw error }
    }
    private func activatePeer() async throws {
        try session.recheckBeforeActivation()
        _ = try session.activate()
        guard let factory else { throw Auth.Failure.unavailable }
        let delegate = try await factory(self, session)
        try session.check()
        lock.withLock { self.delegate = delegate }
        if let bridge = delegate as? BridgeBase { try bridge.activateAuthenticatedChannel() }
        scheduleExpiry(seconds: session.expiresAt?.timeIntervalSinceNow ?? 0)
    }
    private func consumePeerAuthentication(_ command: BridgeCommand, bytes: Data,
        peer: BridgePeerChannelAuthentication.Operation) async throws {
        typealias P = BridgePeerChannelAuthentication
        switch (peer.hello.role, command.cmd) {
        case (.responder, "channelAuthPeerHello"):
            let remote = try Auth.decode(P.Hello.self, from: bytes)
            try session.issuePeerChallenge(await peer.prepare(remote))
            try await sendAuth("channelAuthPeerChallenge", P.Offer(hello: peer.hello, proof: await peer.sign()))
        case (.initiator, "channelAuthPeerChallenge"):
            let offer = try Auth.decode(P.Offer.self, from: bytes)
            try session.issuePeerChallenge(await peer.prepare(offer.hello))
            try session.reserveOpen(offer.proof)
            guard let identity = session.publicIdentity else { throw Auth.Failure.invalidProof }
            try await recheckPolicy(identity); try session.recheckBeforeActivation()
            try await sendAuth("channelAuthPeerProof", await peer.sign())
        case (.responder, "channelAuthPeerProof"):
            try session.reserveOpen(Auth.decode(Auth.Proof.self, from: bytes))
            guard let identity = session.publicIdentity else { throw Auth.Failure.invalidProof }
            try await recheckPolicy(identity)
            try session.recheckBeforeActivation()
            // Save acknowledgement before factory; activatePeer performs the shared transition.
            let acknowledgement = try session.peerAcknowledgement()
            try await activatePeer()
            try await sendAuth("channelAuthPeerAccepted", acknowledgement)
            lock.withLock { peerReady = true }
        case (.initiator, "channelAuthPeerAccepted"):
            try await peer.finish(Auth.decode(Auth.Authenticated.self, from: bytes))
            try await activatePeer()
            lock.withLock { peerReady = true }
        default: throw Auth.Failure.unexpectedMessage
        }
    }
    private func install() {
        session.retainTransport()
        session.onClose { [weak self] in
            guard let self else { return }
            Task { await self.close() }
        }
        underlying?.setDelegate(self)
        scheduleExpiry(seconds: 10)
    }
    deinit { timer?.cancel(); session.close(); session.releaseTransport() }

    public static func new() -> BridgeTransportProtocol {
        // A configured origin and physical transport are mandatory.
        UnconfiguredBridgeChannelTransport()
    }
    public func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }

    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        guard !isServer, let endpoint = session.endpoint, endpointURL.absoluteString == endpoint.audience,
              lock.withLock({ if started || stopped { return false }; started = true; return true }) else { throw Auth.Failure.unexpectedMessage }
        let operation = try BridgeChannelClientOperation(owner: identity, endpoint: endpoint)
        lock.withLock { self.operation = operation }
        do {
            try await physicalTransport().setup(endpointURL, identity: identity.publicIdentitySnapshot())
            try await sendAuth("channelAuthHello", operation.hello)
            // No Cell command or write is queued/replayed while authenticating.
            while session.state != .authenticated {
                guard !lock.withLock({ stopped }) else { throw Auth.Failure.closed }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try session.check()
        } catch { await close(); throw error }
    }

    private func physicalTransport() throws -> BridgeTransportProtocol {
        try lock.withLock {
            guard !stopped, let underlying else { throw Auth.Failure.closed }
            return underlying
        }
    }

    private func scheduleExpiry(seconds: TimeInterval) {
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            catch { return }
            await self?.close()
        }
        lock.withLock { timer?.cancel(); timer = task }
    }
    private func sendAuth<T: Encodable>(_ name: String, _ value: T) async throws {
        let command = BridgeCommand(cmd: name, payload: .string(String(decoding: try Auth.encode(value), as: UTF8.self)), cid: 0)
        let data = try Auth.encode(command)
        try session.acquireSend(bytes: data.count, authenticating: true)
        defer { session.releaseSend(bytes: data.count) }
        try await trackedWork { try await self.physicalTransport().sendData(data) }
    }

    public func validateInboundPayload(_ data: Data) throws {
        let maximum = session.state == .authenticated ? BridgeInboundPayloadValidator.defaultMaximumBytes : Auth.maximumEnvelopeBytes
        try BridgeInboundPayloadValidator(maximumBytes: maximum).validate(data)
        if session.state != .authenticated {
            guard let command = try? JSONDecoder().decode(BridgeCommand.self, from: data),
                  command.cmd.hasPrefix("channelAuth"), try Auth.encode(command) == data else { throw Auth.Failure.malformed }
        }
    }

    // Cancellation requests are propagated, but accounting is released by the
    // worker's defer only after non-cooperative host/cell/transport code returns.
    private func trackedWork(admission: Bool = false, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let id = UUID()
        let task = try lock.withLock { () throws -> Task<Void, Error> in
            guard !stopped, inFlight.count < 64 else { throw Auth.Failure.capacity }
            try session.acquireWork(admission: admission)
            let task = Task { [session] in
                defer { session.releaseWork(admission: admission) }
                try Task.checkCancellation()
                try await body()
            }
            inFlight[id] = task
            return task
        }
        defer { _ = lock.withLock { inFlight.removeValue(forKey: id) } }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Host setup uses the same retained work budget as dispatch and factories.
    public func withAuthenticatedWork(_ body: @escaping @Sendable () async throws -> Void) async throws {
        try await trackedWork {
            try self.session.check()
            try await body()
            try self.session.check()
        }
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        do { try await trackedWork(admission: command.cmd.hasPrefix("channelAuth")) { try await self.processCommand(command) } }
        catch { await close(); throw error }
    }
    private func processCommand(_ command: BridgeCommand) async throws {
        do {
            if command.cmd.hasPrefix("channelAuth") {
                try await consumeAuthentication(command)
                return
            }
            guard command.command != .ready else { throw Auth.Failure.unexpectedMessage }
            try session.checkInbound(command)
            if !isServer {
                guard [.sign, .response, .channelOpened, .channelRejected].contains(command.command) else { throw Auth.Failure.unexpectedMessage }
            }
            guard let delegate = lock.withLock({ self.delegate }), !lock.withLock({ stopped }) else { throw Auth.Failure.unavailable }
            try session.check()
            try await delegate.consumeCommand(command: command)
        } catch { await close(); throw error }
    }
    public func consumeResponse(command: BridgeCommand) async throws {
        do { try await trackedWork { try await self.processResponse(command) } }
        catch { await close(); throw error }
    }
    private func processResponse(_ command: BridgeCommand) async throws {
        do {
            try session.checkInbound(command)
            guard command.command == .response, let delegate = lock.withLock({ self.delegate }) else { throw Auth.Failure.unexpectedMessage }
            try await delegate.consumeResponse(command: command)
        } catch { await close(); throw error }
    }

    private func consumeAuthentication(_ command: BridgeCommand) async throws {
        guard command.identity == nil, command.cid == 0, command.protocolVersion == nil,
              command.channelID == nil, command.targetEndpoint == nil,
              command.streamID == nil, command.sequence == nil, command.resumeFromSequence == nil,
              case let .string(payload) = command.payload else { throw Auth.Failure.malformed }
        let bytes = Data(payload.utf8)
        if let peer = lock.withLock({ peerOperation }) {
            try await consumePeerAuthentication(command, bytes: bytes, peer: peer)
            return
        }
        switch (isServer, command.cmd) {
        case (true, "channelAuthHello"):
            let challenge = try session.issueChallenge(Auth.decode(Auth.Hello.self, from: bytes))
            try await sendAuth("channelAuthChallenge", challenge)
        case (true, "channelAuthProof"):
            try session.reserveOpen(Auth.decode(Auth.Proof.self, from: bytes))
            guard let identity = session.publicIdentity, let factory else { throw Auth.Failure.unavailable }
            try await recheckPolicy(identity)
            try session.recheckBeforeActivation()
            let acknowledgement = try session.activate()
            let delegate = try await factory(self, session)
            try session.check()
            lock.withLock { self.delegate = delegate }
            if let bridge = delegate as? BridgeBase { try bridge.activateAuthenticatedChannel() }
            scheduleExpiry(seconds: session.expiresAt?.timeIntervalSinceNow ?? 0)
            try await sendAuth("channelAuthAccepted", acknowledgement)
        case (false, "channelAuthChallenge"):
            guard let operation = lock.withLock({ self.operation }) else { throw Auth.Failure.unexpectedMessage }
            let proof = try await operation.sign(Auth.decode(Auth.Challenge.self, from: bytes))
            guard !lock.withLock({ stopped }) else { throw Auth.Failure.closed }
            try await sendAuth("channelAuthProof", proof)
        case (false, "channelAuthAccepted"):
            guard let operation = lock.withLock({ self.operation }) else { throw Auth.Failure.unexpectedMessage }
            try await operation.finish(Auth.decode(Auth.Authenticated.self, from: bytes), session: session)
            lock.withLock { self.operation = nil }
            if let bridge = lock.withLock({ delegate }) as? BridgeBase { try bridge.activateAuthenticatedChannel() }
            scheduleExpiry(seconds: session.expiresAt?.timeIntervalSinceNow ?? 0)
        default: throw Auth.Failure.unexpectedMessage
        }
    }
    public func sendData(_ data: Data) async throws {
        do {
            guard data.count <= BridgeInboundPayloadValidator.defaultMaximumBytes else { throw Auth.Failure.capacity }
            let reserved = lock.withLock { () -> Bool in
                guard !stopped, pendingSends < 32 else { return false }
                pendingSends += 1; return true
            }
            guard reserved else { throw Auth.Failure.capacity }
            defer { lock.withLock { pendingSends -= 1 } }
            try session.acquireSend(bytes: data.count)
            defer { session.releaseSend(bytes: data.count) }
            try session.check()
            try await trackedWork { try await self.physicalTransport().sendData(data) }
            try session.check()
        } catch { await close(); throw error }
    }
    func replacementForRenewal(using physical: BridgeTransportProtocol? = nil) async throws -> BridgeChannelTransport {
        guard !isServer else { throw Auth.Failure.unexpectedMessage }
        await close()
        guard let endpoint = session.endpoint else { throw Auth.Failure.unavailable }
        return try BridgeChannelTransport(underlying: physical ?? newPhysicalTransport(), endpoint: endpoint)
    }

    public func close() async {
        let cleanup = lock.withLock { () -> (BridgeDelegateProtocol?, BridgeChannelClientOperation?, BridgeTransportProtocol?)? in
            guard !stopped else { return nil }
            stopped = true; timer?.cancel(); timer = nil
            inFlight.values.forEach { $0.cancel() }
            let result = (delegate, operation, underlying); delegate = nil; operation = nil; underlying = nil
            return result
        }
        guard let cleanup else { return }
        defer { session.releaseTransport() }
        session.close()
        await cleanup.1?.cancel()
        await lock.withLock({ peerOperation })?.cancel()
        if let bridge = cleanup.0 as? BridgeBase {
            await bridge.channelDidClose(session)
        } else {
            await cleanup.0?.pushError(errorMessage: "bridge_channel_closed", error: Auth.Failure.closed)
        }
        await cleanup.2?.close()
    }
    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        BridgeIdentityVault(cloudBridge: lock.withLock { delegate as? BridgeProtocol })
    }
    public func pushError(errorMessage: String?, error: Error?) async { await close() }
    public func ready() async throws { try session.check() }
    public func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {
        // Underlying adapters historically initiate description on connect. The
        // resolver starts that operation after authenticated readiness instead.
        guard session.state == .authenticated else { return }
        await lock.withLock({ delegate })?.sendCommand(command: command, identity: identity, payload: payload)
    }
    public func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {
        guard (try? session.check()) != nil else { return }
        await lock.withLock({ delegate })?.sendSetValueState(for: requestedKey, setValueState: setValueState)
    }
}

private struct UnconfiguredBridgeChannelTransport: BridgeTransportProtocol {
    static func new() -> BridgeTransportProtocol { Self() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) {}
    func setup(_ endpointURL: URL, identity: Identity) async throws { throw BridgeChannelAuthentication.Failure.unavailable }
    func sendData(_ data: Data) async throws { throw BridgeChannelAuthentication.Failure.unavailable }
    func identityVault(for identity: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
}
