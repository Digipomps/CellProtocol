// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// A locally captured mux destination. Scheduling grants no authority: the
/// originating gate revalidates every command when this work executes.
public struct BridgeInboundDispatch: @unchecked Sendable {
    public let laneID: ObjectIdentifier
    public let bypassesOrdering: Bool
    private let body: @Sendable () async throws -> Void

    init(laneID: ObjectIdentifier, bypassesOrdering: Bool = false,
         body: @escaping @Sendable () async throws -> Void) {
        self.laneID = laneID; self.bypassesOrdering = bypassesOrdering; self.body = body
    }
    public func consume() async throws { try await body() }
}

/// Auth gate around one physical transport. Server factory is not called until
/// proof consumption, policy recheck and activation succeed. All logical channels
/// on a multiplex connection share its proven principal and generation.
public final class BridgeChannelTransport: BridgeTransportProtocol, BridgeDelegateProtocol, @unchecked Sendable {
    public typealias Auth = BridgeChannelAuthentication
    public typealias ServerFactory = @Sendable (BridgeChannelTransport, BridgeChannelSession) async throws -> BridgeDelegateProtocol
    public static let maximumPeerFrameBytes = BridgePeerRecordLayer.maximumPlaintext + BridgePeerRecordLayer.overhead
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
    private var peerRecords: BridgePeerRecordLayer?
    private let peerFlow = BridgePeerFlowControl()
    private var peerCapacityRevision: UInt64 = 0
    private var peerCapacityWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var flowTimer: Task<Void, Never>?
    var peerFlowClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public var peerOutstandingUsage: (records: Int, bytes: Int, dataRecords: Int) {
        lock.withLock { (peerFlow.outstanding.count, peerFlow.bytes, peerFlow.outstanding.values.filter { !$0.control }.count) }
    }
    private var progressChecks = 0
    var peerProgressDiagnostics: (checks: Int, age: TimeInterval?) {
        lock.withLock { (progressChecks, peerFlow.oldest.map { peerFlowClock() - $0 }) }
    }
    public func checkPeerProgress() async {
        let expired = lock.withLock { () -> Bool in
            progressChecks = min(1000, progressChecks + 1)
            return peerFlow.oldest.map { peerFlowClock() >= $0 + 10 } ?? false
        }
        if expired { await close() }
    }

    // Only internal auth-send can reserve one exact envelope for physical send.
    private var peerAuthSend: Data?
    private var peerAuthSendBytes = 0
    private var peerLastAuthBytes = 0
    private var remotePeerGeneration: String?
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
                source: String, disclosurePolicy: BridgePeerChannelAuthentication.DisclosurePolicy,
                recheckPolicy: @escaping @Sendable (Auth.PublicIdentity) async throws -> Void = { _ in },
                wallClock: @escaping @Sendable () -> Date = { Date() },
                monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                factory: @escaping ServerFactory) throws {
        self.underlying = underlying; newPhysicalTransport = { type(of: underlying).new() }
        session = try BridgeChannelSession(peerEndpoint: peerEndpoint, localIdentity: Auth.PublicIdentity(owner), limits: limits, source: source, wallClock: wallClock, monotonic: monotonic)
        peerOperation = try .init(owner: owner, endpoint: peerEndpoint, role: role, generation: session.generation,
                                  policy: disclosurePolicy, wallClock: wallClock, monotonic: monotonic)
        self.factory = factory; self.recheckPolicy = recheckPolicy; isServer = true
        install()
    }
    public func startPeer() async throws {
        guard let peer = lock.withLock({ peerOperation }),
              lock.withLock({ if started || stopped { return false }; started = true; return true }) else { throw Auth.Failure.unexpectedMessage }
        do {
            if peer.hello.role == .initiator {
                try await trackedWork(admission: true) {
                    try await self.sendPeerAuthentication(peer.begin(live: self.checkPeerHandshake))
                }
            }
            while !lock.withLock({ peerReady }) {
                guard !lock.withLock({ stopped }) else { throw Auth.Failure.closed }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try session.check()
        } catch { await close(); throw error }
    }
    private func checkPeerHandshake() throws {
        try lock.withLock {
            guard !stopped else { throw Auth.Failure.closed }
            try session.checkPeerHandshake()
        }
    }
    private func recheckPeerPolicy() async throws {
        try checkPeerHandshake()
        if let identity = session.publicIdentity { try await recheckPolicy(identity) }
        try checkPeerHandshake()
    }
    private func activatePeer() async throws {
        try session.recheckBeforeActivation()
        _ = try session.activate()
        guard let factory else { throw Auth.Failure.unavailable }
        let result = try await factory(self, session)
        try await adoptFactoryResult(result, peer: true)
    }

    /// Exactly one owner retires a returned factory result: this adoption or
    /// close. setDelegate during factory construction is deliberately provisional.
    private func adoptFactoryResult(_ result: BridgeDelegateProtocol, peer: Bool) async throws {
        var adopted = false
        do {
            try Task.checkCancellation()
            try session.check()
            if peer {
                guard let identity = session.publicIdentity else { throw Auth.Failure.invalidProof }
                try await recheckPolicy(identity)
            }
            try lock.withLock {
                try Task.checkCancellation()
                guard !stopped else { throw Auth.Failure.closed }
                try session.check()
                delegate = result; adopted = true
                // Publication and ownership share the terminality lock. close
                // cannot retire the Base between activation and ready publication.
                if let bridge = result as? BridgeBase { try bridge.activateAuthenticatedChannel() }
                if peer { peerReady = true }
            }
            scheduleExpiry(seconds: session.expiresAt?.timeIntervalSinceNow ?? 0)
        } catch {
            let ownsCleanup = lock.withLock { () -> Bool in
                if !adopted { return true }
                guard delegate === result else { return false }
                delegate = nil; peerReady = false; return true
            }
            if ownsCleanup { await retireFactoryResult(result) }
            throw error
        }
    }
    private func retireFactoryResult(_ result: BridgeDelegateProtocol) async {
        if let bridge = result as? BridgeBase { await bridge.channelDidClose(session) }
        else { await result.pushError(errorMessage: "bridge_channel_closed", error: Auth.Failure.closed) }
    }
    private func consumePeerAuthentication(_ command: BridgeCommand, bytes: Data,
        peer: BridgePeerChannelAuthentication.Operation) async throws {
        let wire = try Auth.encode(command)
        let records = try await peer.receive(wire, live: checkPeerHandshake,
            authenticate: { [self] challenge, proof in
                try checkPeerHandshake()
                try session.issuePeerChallenge(challenge)
                try session.reserveOpen(proof)
                try await recheckPeerPolicy()
            }, recheck: recheckPeerPolicy, send: sendPeerAuthentication)
        // The operation has validated the exact expected, transcript-bound step.
        // M5's reservation remains until an authenticated application record.
        if let records {
            if peer.hello.role == .responder { releasePeerHandshakeBytes() }
            try installPeerRecords(records)
            try await activatePeer()
        }
    }
    private func sendPeerAuthentication(_ data: Data) async throws {
        try checkPeerHandshake()
        _ = try BridgePeerChannelAuthentication.decodeEnvelope(data)
        let previous = try lock.withLock { () throws -> Int in
            guard !stopped, peerAuthSend == nil else { throw Auth.Failure.closed }
            try session.acquireSend(bytes: data.count, authenticating: true)
            let old = peerLastAuthBytes
            peerAuthSend = data; peerAuthSendBytes += data.count; peerLastAuthBytes = data.count
            return old
        }
        // Reaching the next locally generated step requires authenticated remote
        // progress; initial M1/M2 have no previous reservation.
        if previous > 0 { releasePeerHandshakeBytes(previous) }
        try await physicalTransport().sendData(data)
        try lock.withLock {
            guard !stopped else { throw Auth.Failure.closed }
            // M1 submission may return after the independent receive queue has
            // already completed the handshake. Recheck this captured session,
            // without rejecting legitimate authenticated progress.
            if peerReady { try session.check() } else { try session.checkPeerHandshake() }
            guard peerAuthSend != data else { throw Auth.Failure.unavailable }
        }
    }
    private func releasePeerHandshakeBytes(_ bytes: Int? = nil) {
        lock.withLock {
            let released = min(bytes ?? peerAuthSendBytes, peerAuthSendBytes)
            peerAuthSendBytes -= released
            session.releaseSend(bytes: released)
            if peerAuthSendBytes == 0 { peerLastAuthBytes = 0 }
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
    deinit { flowTimer?.cancel(); timer?.cancel(); session.close(); session.releaseTransport() }

    public static func new() -> BridgeTransportProtocol {
        // A configured origin and physical transport are mandatory.
        UnconfiguredBridgeChannelTransport()
    }
    public func setDelegate(_ delegate: BridgeDelegateProtocol) {
        lock.withLock {
            // Server factory results are adopted only under the terminality
            // guard. A suspended WS/peer factory must not create a retain cycle.
            if !stopped && factory == nil { self.delegate = delegate }
        }
    }

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
        lock.withLock {
            guard !stopped else { task.cancel(); return }
            timer?.cancel(); timer = task
        }
    }
    private func sendAuth<T: Encodable>(_ name: String, _ value: T) async throws {
        let command = BridgeCommand(cmd: name, payload: .string(String(decoding: try Auth.encode(value), as: UTF8.self)), cid: 0)
        let data = try Auth.encode(command)
        let wireBytes = data.count
        try session.acquireSend(bytes: wireBytes, authenticating: true)
        defer { session.releaseSend(bytes: wireBytes) }
        try await trackedWork { try await self.physicalTransport().sendData(data) }
    }

    // Metadata-only verification seam; no key material or plaintext access.
    var peerRecordCounts: (sent: UInt64, received: UInt64)? {
        lock.withLock { peerRecords.map { ($0.nextSend, $0.nextReceive) } }
    }

    private func installPeerRecords(_ records: BridgePeerRecordLayer) throws {
        try lock.withLock {
            guard !stopped, peerRecords == nil else { records.close(); throw Auth.Failure.closed }
            peerRecords = records
            flowTimer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    await self?.checkPeerProgress()
                    if self == nil { return }
                }
            }
        }
    }

    /// Adapter holds its send-order lock; this lock spans final gate admission,
    /// sealing and synchronous physical submission. Close cannot win in between.
    public func submitPeerFrame(_ plaintext: Data, submit: (Data) throws -> Void) throws {
        try lock.withLock {
            let authenticating = peerAuthSend != nil
            let wire = try sealPeerFrameLocked(plaintext)
            try session.withPeerSendAdmission(authenticating: authenticating) { try submit(wire) }
        }
    }
    /// nil means submitted; otherwise wait on the captured revision. A bounded
    /// producer holds its existing work slot, never an unbounded payload queue.
    public func submitPeerFrameWhenAvailable(_ plaintext: Data, submit: (Data) throws -> Void) throws -> UInt64? {
        try lock.withLock {
            do {
                let authenticating = peerAuthSend != nil
                let wire = try sealPeerFrameLocked(plaintext)
                try session.withPeerSendAdmission(authenticating: authenticating) { try submit(wire) }
                return nil
            } catch is BridgePeerFlowControl.WindowFull { return peerCapacityRevision }
        }
    }
    public func waitForPeerCapacity(after revision: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if stopped || Task.isCancelled { continuation.resume(throwing: Auth.Failure.closed) }
                    else if revision != peerCapacityRevision { continuation.resume() }
                    else if peerCapacityWaiters.count >= 32 { continuation.resume(throwing: Auth.Failure.capacity) }
                    else { peerCapacityWaiters[id] = continuation }
                }
            }
        }, onCancel: { [self] in
            lock.withLock { peerCapacityWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        })
    }

    public func sealPeerFrame(_ plaintext: Data) throws -> Data {
        try lock.withLock { try sealPeerFrameLocked(plaintext) }
    }
    private func sealPeerFrameLocked(_ plaintext: Data) throws -> Data {
        guard !stopped, peerOperation != nil else { throw Auth.Failure.closed }
        if let reserved = peerAuthSend {
            guard plaintext == reserved else { throw Auth.Failure.unexpectedMessage }
            try session.checkPeerHandshake()
            peerAuthSend = nil
            return plaintext
        }
        guard peerReady, let peerRecords else { throw Auth.Failure.invalidProof }
        try session.check()
        let command = try JSONDecoder().decode(BridgeCommand.self, from: plaintext)
        guard !command.cmd.hasPrefix("channelAuth"), command.command != .ready else { throw Auth.Failure.unexpectedMessage }
        let body = try peerFlow.prepare(plaintext, counter: peerRecords.nextSend, now: peerFlowClock()) {
            try session.acquireSend(bytes: $0)
        }
        let counter = peerRecords.nextSend
        let wire = try peerRecords.seal(body)
        peerFlow.sealed(counter: counter, wire: wire)
        return wire
    }
    public func openPeerFrame(_ record: Data) throws -> Data {
        try lock.withLock {
            guard !stopped, peerOperation != nil else { throw Auth.Failure.closed }
            guard let peerRecords else {
                try session.checkPeerHandshake()
                let envelope = try BridgePeerChannelAuthentication.decodeEnvelope(record)
                // Remote generation is public and checked again by the operation.
                if envelope.cmd == .hello {
                    remotePeerGeneration = try Auth.decode(BridgePeerChannelAuthentication.Hello.self,
                        from: Data(envelope.body.utf8)).generation
                } else if envelope.cmd == .responderAuth {
                    remotePeerGeneration = try Auth.decode(BridgePeerChannelAuthentication.ResponderAuth.self,
                        from: Data(envelope.body.utf8)).hello.generation
                }
                return record
            }
            guard peerReady else { throw Auth.Failure.unexpectedMessage }
            try session.check()
            let counter = peerRecords.nextReceive
            let before = peerFlow.outstanding.count
            let plaintext = try peerFlow.receive(peerRecords.open(record), counter: counter, wire: record, now: peerFlowClock()) { session.releaseSend(bytes: $0) }
            if peerFlow.outstanding.count < before {
                peerCapacityRevision &+= 1
                let waiters = peerCapacityWaiters.values; peerCapacityWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            if !plaintext.isEmpty {
                let command = try JSONDecoder().decode(BridgeCommand.self, from: plaintext)
                guard !command.cmd.hasPrefix("channelAuth"), command.command != .ready else { throw Auth.Failure.unexpectedMessage }
            }
            // First authenticated Kapp traffic acknowledges I's final Finished.
            if peerAuthSendBytes > 0 {
                session.releaseSend(bytes: peerAuthSendBytes)
                peerAuthSendBytes = 0; peerLastAuthBytes = 0
            }
            return plaintext
        }
    }

    /// Same adapter ordering/physical admission as data. Receipts never pass
    /// through public sendData, BridgeCommand, resolver or Cell dispatch.
    public func submitPeerReceipts(submit: (Data) throws -> Void) throws {
        try lock.withLock {
            guard !stopped, peerReady, let records = peerRecords else { return }
            guard peerFlow.shouldSendReceipt else { return }
            let body = try peerFlow.prepare(nil, counter: records.nextSend, now: peerFlowClock()) {
                try session.acquireSend(bytes: $0)
            }
            let counter = records.nextSend
            let wire = try records.seal(body)
            peerFlow.sealed(counter: counter, wire: wire)
            try session.withPeerSendAdmission(authenticating: false) { try submit(wire) }
        }
    }

    /// Optional broadcasts skip pending/closed peers without submitting a send
    /// that would terminate their handshake. sendData still rechecks admission.
    public var canSendPeerData: Bool {
        lock.withLock { peerReady && !stopped } && (try? session.check()) != nil
    }

    private func checkPeerGeneration(_ command: BridgeCommand) throws {
        guard lock.withLock({ peerOperation != nil }), !command.cmd.hasPrefix("channelAuth") else { return }
        guard let generation = command.peerGeneration else { throw Auth.Failure.malformed }
        guard generation == lock.withLock({ remotePeerGeneration }) else { throw Auth.Failure.staleGeneration }
    }

    public func validateInboundPayload(_ data: Data) throws {
        let maximum = session.state == .authenticated ? BridgeInboundPayloadValidator.defaultMaximumBytes : Auth.maximumEnvelopeBytes
        try BridgeInboundPayloadValidator(maximumBytes: maximum).validate(data)
        if lock.withLock({ peerOperation != nil }) {
            try checkPeerGeneration(JSONDecoder().decode(BridgeCommand.self, from: data))
        }
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
    private func processCommand(_ command: BridgeCommand, prepared: BridgeInboundDispatch? = nil) async throws {
        do {
            if command.cmd.hasPrefix("channelAuth") {
                try await consumeAuthentication(command)
                return
            }
            guard command.command != .ready else { throw Auth.Failure.unexpectedMessage }
            guard lock.withLock({ peerOperation == nil || peerReady }) else { throw Auth.Failure.unexpectedMessage }
            try checkPeerGeneration(command)
            try session.checkInbound(command)
            if !isServer {
                guard [.sign, .response, .channelOpened, .channelRejected].contains(command.command) else { throw Auth.Failure.unexpectedMessage }
            }
            guard let delegate = lock.withLock({ self.delegate }), !lock.withLock({ stopped }) else { throw Auth.Failure.unavailable }
            try session.check()
            if let prepared { try await prepared.consume() }
            else { try await delegate.consumeCommand(command: command) }
        } catch { await close(); throw error }
    }

    /// Capture a live logical destination before a transport queues the frame.
    /// A retired destination never gets looked up again by a reusable wire ID.
    public func prepareMultiplexDispatch(_ command: BridgeCommand) -> BridgeInboundDispatch? {
        let target = lock.withLock { stopped ? nil : delegate }
        let captured: BridgeInboundDispatch?
        if let mux = target as? BridgeMultiplexServerSession { captured = mux.prepareInboundDispatch(command) }
        else if let mux = target as? BridgeMultiplexSession { captured = mux.prepareInboundDispatch(command) }
        else { return nil }
        guard let captured else { return nil }
        return BridgeInboundDispatch(laneID: captured.laneID, bypassesOrdering: captured.bypassesOrdering) { [self] in
            do {
                try await trackedWork {
                    if command.command == .response { try await self.processResponse(command, prepared: captured) }
                    else { try await self.processCommand(command, prepared: captured) }
                }
            } catch { await close(); throw error }
        }
    }

    /// Scheduling only; all response validation still runs through this gate.
    public func isOriginSigningResponse(_ command: BridgeCommand) -> Bool {
        let target = lock.withLock { stopped ? nil : delegate }
        if let bridge = target as? BridgeBase { return bridge.isOriginSigningResponse(command) }
        if let mux = target as? BridgeMultiplexSession { return mux.isOriginSigningResponse(command) }
        if let mux = target as? BridgeMultiplexServerSession { return mux.isOriginSigningResponse(command) }
        return false
    }

    public func consumeResponse(command: BridgeCommand) async throws {
        do { try await trackedWork { try await self.processResponse(command) } }
        catch { await close(); throw error }
    }
    private func processResponse(_ command: BridgeCommand, prepared: BridgeInboundDispatch? = nil) async throws {
        do {
            guard lock.withLock({ peerOperation == nil || peerReady }) else { throw Auth.Failure.unexpectedMessage }
            try checkPeerGeneration(command)
            try session.checkInbound(command)
            guard command.command == .response, let delegate = lock.withLock({ self.delegate }) else { throw Auth.Failure.unexpectedMessage }
            if let prepared { try await prepared.consume() }
            else { try await delegate.consumeResponse(command: command) }
        } catch { await close(); throw error }
    }

    private func consumeAuthentication(_ command: BridgeCommand) async throws {
        guard command.identity == nil, command.cid == 0, command.protocolVersion == nil,
              command.channelID == nil, command.targetEndpoint == nil,
              command.streamID == nil, command.sequence == nil, command.resumeFromSequence == nil, command.peerGeneration == nil,
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
            let result = try await factory(self, session)
            try await adoptFactoryResult(result, peer: false)
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
            var data = data
            if lock.withLock({ peerOperation != nil }) {
                guard canSendPeerData else { throw Auth.Failure.unexpectedMessage }
                var command = try JSONDecoder().decode(BridgeCommand.self, from: data)
                command.peerGeneration = session.generation
                data = try Auth.encode(command)
            }
            guard data.count <= BridgeInboundPayloadValidator.defaultMaximumBytes else { throw Auth.Failure.capacity }
            let reserved = lock.withLock { () -> Bool in
                guard !stopped, pendingSends < 32 else { return false }
                pendingSends += 1; return true
            }
            guard reserved else { throw Auth.Failure.capacity }
            defer { lock.withLock { pendingSends -= 1 } }
            let wireBytes = data.count + lock.withLock { peerOperation != nil ? BridgePeerRecordLayer.overhead : 0 }
            let peer = lock.withLock { peerOperation != nil }
            if !peer { try session.acquireSend(bytes: wireBytes) }
            defer { if !peer { session.releaseSend(bytes: wireBytes) } }
            // Peer wire bytes are reserved at sealing and retained through MC
            // enqueue until a token receipt or completed physical retirement.
            try session.check()
            try await trackedWork { [data] in try await self.physicalTransport().sendData(data) }
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
        let cleanup = lock.withLock { () -> (BridgeDelegateProtocol?, BridgeChannelClientOperation?, BridgeTransportProtocol?, [Task<Void, Error>])? in
            guard !stopped else { return nil }
            stopped = true; timer?.cancel(); timer = nil; flowTimer?.cancel(); flowTimer = nil
            peerRecords?.close(); peerRecords = nil; peerReady = false; peerAuthSend = nil
            let work = Array(inFlight.values)
            let waiters = peerCapacityWaiters.values; peerCapacityWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: Auth.Failure.closed) }
            let result = (delegate, operation, underlying, work); delegate = nil; operation = nil; underlying = nil
            return result
        }
        guard let cleanup else { return }
        // Task cancellation may synchronously invoke a window waiter's handler;
        // do not call it while holding the gate lock.
        cleanup.3.forEach { $0.cancel() }
        defer { session.releaseTransport() }
        session.close()
        // Peer eviction must not wait behind suspended Cell/factory cleanup.
        // Authority is already revoked; physical reservations stay held until
        // this exact adapter has observed retirement.
        let peer = lock.withLock { peerOperation != nil }
        if peer { await cleanup.2?.close() }
        await cleanup.1?.cancel()
        await lock.withLock({ peerOperation })?.cancel()
        if let bridge = cleanup.0 as? BridgeBase {
            await bridge.channelDidClose(session)
        } else {
            await cleanup.0?.pushError(errorMessage: "bridge_channel_closed", error: Auth.Failure.closed)
        }
        if !peer { await cleanup.2?.close() }
        releasePeerHandshakeBytes()
        lock.withLock { peerFlow.retire { session.releaseSend(bytes: $0) } }
    }
    public func identityVault(for identity: Identity?) async -> IdentityVaultProtocol {
        BridgeIdentityVault(cloudBridge: lock.withLock { delegate as? BridgeProtocol })
    }
    public func pushError(errorMessage: String?, error: Error?) async { await close() }
    public func ready() async throws {
        try lock.withLock {
            guard !stopped else { throw Auth.Failure.closed }
            try session.check()
        }
    }
    var hasDelegate: Bool { lock.withLock { delegate != nil } }
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
