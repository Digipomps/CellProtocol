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
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var started = false
    private var pendingSends = 0
    private let isServer: Bool

    /// The host must supply its configured public endpoint, not request headers.
    /// Construct before installing any callback capable of resolving Cells.
    public init(underlying: BridgeTransportProtocol, endpoint: Auth.Endpoint,
                limits: BridgeChannelLimits, source: String,
                recheckPolicy: @escaping @Sendable (Auth.PublicIdentity) async throws -> Void = { _ in },
                factory: @escaping ServerFactory) throws {
        self.underlying = underlying
        self.newPhysicalTransport = { [transportType = type(of: underlying)] in transportType.new() }
        self.session = try BridgeChannelSession(endpoint: endpoint, limits: limits, source: source)
        self.factory = factory; self.recheckPolicy = recheckPolicy; isServer = true
        install()
    }
    public init(underlying: BridgeTransportProtocol, endpoint: Auth.Endpoint) throws {
        self.underlying = underlying; self.newPhysicalTransport = { [transportType = type(of: underlying)] in transportType.new() }; self.session = try BridgeChannelSession(endpoint: endpoint)
        self.factory = nil; self.recheckPolicy = { _ in }; isServer = false
        install()
    }
    private func install() {
        session.onClose { [weak self] in
            guard let self else { return }
            Task { await self.close() }
        }
        underlying?.setDelegate(self)
        scheduleExpiry(seconds: 10)
    }
    deinit { timer?.cancel(); session.close() }

    public static func new() -> BridgeTransportProtocol {
        // A configured origin and physical transport are mandatory.
        UnconfiguredBridgeChannelTransport()
    }
    public func setDelegate(_ delegate: BridgeDelegateProtocol) { lock.withLock { self.delegate = delegate } }

    public func setup(_ endpointURL: URL, identity: Identity) async throws {
        guard !isServer, endpointURL.absoluteString == session.endpoint.audience,
              lock.withLock({ if started || stopped { return false }; started = true; return true }) else { throw Auth.Failure.unexpectedMessage }
        let operation = try BridgeChannelClientOperation(owner: identity, endpoint: session.endpoint)
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
        try await physicalTransport().sendData(Auth.encode(command))
    }

    public func validateInboundPayload(_ data: Data) throws {
        let maximum = session.state == .authenticated ? BridgeInboundPayloadValidator.defaultMaximumBytes : Auth.maximumEnvelopeBytes
        try BridgeInboundPayloadValidator(maximumBytes: maximum).validate(data)
        if session.state != .authenticated {
            guard let command = try? JSONDecoder().decode(BridgeCommand.self, from: data),
                  command.cmd.hasPrefix("channelAuth"), try Auth.encode(command) == data else { throw Auth.Failure.malformed }
        }
    }

    public func consumeCommand(command: BridgeCommand) async throws {
        do {
            if command.cmd.hasPrefix("channelAuth") {
                try await consumeAuthentication(command)
                return
            }
            guard command.command != .ready else { throw Auth.Failure.unexpectedMessage }
            try session.check(identity: command.identity, requiresIdentity: command.command != .response)
            if !isServer {
                guard [.sign, .response, .channelOpened, .channelRejected].contains(command.command) else { throw Auth.Failure.unexpectedMessage }
            }
            guard let delegate = lock.withLock({ self.delegate }), !lock.withLock({ stopped }) else { throw Auth.Failure.unavailable }
            try session.check()
            try await delegate.consumeCommand(command: command)
        } catch { await close(); throw error }
    }
    public func consumeResponse(command: BridgeCommand) async throws {
        do {
            try session.check(identity: command.identity)
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
            try await physicalTransport().sendData(data)
            try session.check()
        } catch { await close(); throw error }
    }
    func replacementForRenewal(using physical: BridgeTransportProtocol? = nil) async throws -> BridgeChannelTransport {
        guard !isServer else { throw Auth.Failure.unexpectedMessage }
        await close()
        return try BridgeChannelTransport(underlying: physical ?? newPhysicalTransport(), endpoint: session.endpoint)
    }

    public func close() async {
        let cleanup = lock.withLock { () -> (BridgeDelegateProtocol?, BridgeChannelClientOperation?, BridgeTransportProtocol?)? in
            guard !stopped else { return nil }
            stopped = true; timer?.cancel(); timer = nil
            let result = (delegate, operation, underlying); delegate = nil; operation = nil; underlying = nil
            return result
        }
        guard let cleanup else { return }
        session.close()
        await cleanup.1?.cancel()
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
