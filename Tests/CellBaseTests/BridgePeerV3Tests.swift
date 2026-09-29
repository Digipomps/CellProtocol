import Foundation
import XCTest
import Crypto
@testable import CellBase

final class BridgePeerV3Tests: XCTestCase {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    static func vectors(_ name: String = "vectors") throws -> [String: Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeerV3/\(name).json")
        return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
    }
    func testIndependentFullHandshakeAndAllKeyPurposes() async throws {
        for name in ["vectors", "p256", "mixed-i", "mixed-r"] { try await checkFullVector(name) }
    }
    private func checkFullVector(_ name: String) async throws {
        let v = try Self.vectors(name)
        func data(_ name: String) -> Data { v[name]! }
        let endpoint = try A.decode(P.Endpoint.self, from: data("endpoint"))
        let ih = try A.decode(P.Hello.self, from: data("hello0")), rh = try A.decode(P.Hello.self, from: data("hello1"))
        let i = try A.decode(A.PublicIdentity.self, from: data("identity0")), r = try A.decode(A.PublicIdentity.self, from: data("identity1"))
        let iv = try V3Vault(identity: i, seed: data("seed0"), fixed: (data("challenge0"), data("signature0")))
        let rv = try V3Vault(identity: r, seed: data("seed1"), fixed: (data("challenge1"), data("signature1")))
        let io = i.makeIdentity(), ro = r.makeIdentity(); io.identityVault = iv; ro.identityVault = rv
        let policy = P.DisclosurePolicy.anyProvenIdentity(allowUnauthenticatedInitiator: true)
        let iop = try P.Operation(owner: io, endpoint: endpoint, role: .initiator, generation: ih.generation, policy: policy,
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000.125) }, ephemeral: .init(rawRepresentation: data("dh0")), nonce: ih.nonce)
        let rop = try P.Operation(owner: ro, endpoint: endpoint, role: .responder, generation: rh.generation, policy: policy,
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000.250) }, ephemeral: .init(rawRepresentation: data("dh1")), nonce: rh.nonce)
        XCTAssertEqual(iop.hello, ih); XCTAssertEqual(rop.hello, rh)
        let w1 = try await iop.begin(live: {})
        XCTAssertEqual(w1, data("W1"))
        let wire = V3Wire()
        var records: [BridgePeerRecordLayer] = []
        for step in 1...5 {
            let result = try await (step.isMultiple(of: 2) ? iop : rop).receive(data("W\(step)"), live: {},
                authenticate: { challenge, proof in
                    let index = step == 2 ? 1 : 0
                    XCTAssertEqual(challenge.signingData, data("challenge\(index)"))
                    XCTAssertEqual(proof.signature, data("signature\(index)"))
                }, recheck: {}, send: { try wire.append($0) })
            if step < 5 {
                let actual = try XCTUnwrap(wire.last)
                if step < 3 {
                    let signed = await (step == 1 ? rv : iv).signedBytes
                    XCTAssertEqual(signed.map { String(decoding: $0, as: UTF8.self) }, String(decoding: data("challenge\(step == 1 ? 1 : 0)"), as: UTF8.self))
                    let env = try P.decodeEnvelope(actual)
                    let sealed = step == 1 ? try A.decode(P.ResponderAuth.self, from: Data(env.body.utf8)).sealed
                        : try A.decode(P.Sealed.self, from: Data(env.body.utf8)).sealed
                    let box = try ChaChaPoly.SealedBox(nonce: P.nonce(0), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
                    let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: data("handshake-key\(step == 1 ? 1 : 0)")), authenticating: data("aad\(step+1)"))
                    let auth = try P.unpad(P.Authentication.self, plain, size: 8192)
                    XCTAssertEqual(String(decoding: try A.encode(auth), as: UTF8.self), String(decoding: data("Auth\(step == 1 ? 1 : 0)"), as: UTF8.self))
                }
                XCTAssertEqual(actual, data("W\(step + 1)"), "wire step \(step + 1)")
            }
            if let result { records.append(result) }
        }
        XCTAssertEqual(records.count, 2)
        for counter in 0...1 {
            let message = Data((counter == 0 ? "N22 vector" : "N22 secret").utf8)
            for index in 0...1 {
                let sealed = try records[index].seal(message)
                XCTAssertEqual(sealed, data("record\(index)\(counter)"))
                XCTAssertEqual(try records[1-index].open(sealed), message)
            }
        }
        let prk = try P.extract(.init(rawRepresentation: data("dh0")), remote: rh.ephemeralPublicKey, salt: data("T0"))
        XCTAssertEqual(prk.withUnsafeBytes { Data($0) }, data("PRK"))
        for (label, context) in [("handshake-key","T0"),("identity-mac-key","T0"),("finished-key","T3"),("application-key","T5")] {
            for (index, role) in [P.Role.initiator, .responder].enumerated() {
                let key = P.key(prk, label, role, data(context))
                XCTAssertEqual(key.withUnsafeBytes { Data($0) }, data(label + String(index)))
                XCTAssertEqual(P.framed("kdf", Data(label.utf8), Data(role.direction.utf8), data(context), P.integer(UInt16(32))), data("info-" + label + String(index)))
            }
        }
        for step in 2...5 {
            let role = step.isMultiple(of: 2) ? 1 : 0
            let auth = step < 4 ? data("Auth\(role)") : nil
            if let auth {
                XCTAssertEqual(try P.pad(A.decode(P.Authentication.self, from: auth), size: 8192), data("pad\(step)"))
            } else {
                let finished = try P.unpad(P.Finished.self, data("pad\(step)"), size: 1024)
                XCTAssertEqual(finished.verifyData, data("verify\(step)"))
                XCTAssertEqual(try A.encode(finished.ack), data("ack\(step)"))
            }
            let context = data(step == 2 ? "T0" : "T\(step-1)")
            XCTAssertEqual(P.framed("handshake-aead", Data(String(step).utf8), context), data("aad\(step)"))
        }
    }

    func testCanonicalEnvelopeAndPaddingRejectEveryAlternativeEncoding() throws {
        let v = try Self.vectors(), original = v["W1"]!
        for bytes in [original + Data(" ".utf8), Data(" ".utf8) + original,
                      Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"cid\":0", with: "\"cid\":0.0").utf8),
                      Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"cid\":0", with: "\"cid\":0,\"cid\":0").utf8),
                      Data(String(decoding: original, as: UTF8.self).dropLast().utf8) + Data(",\"error\":null}".utf8)] {
            XCTAssertThrowsError(try P.decodeEnvelope(bytes))
        }
        for size in [8192,1024] {
            let full = String(repeating: "a", count: size-6) // two JSON quote bytes + U32
            let padded = try P.pad(full, size: size)
            XCTAssertEqual(try P.unpad(String.self, padded, size: size), full)
            XCTAssertThrowsError(try P.pad(full + "a", size: size))
            var short = try P.pad("value", size: size); short[short.count-1] = 1
            XCTAssertThrowsError(try P.unpad(String.self, short, size: size))
            for malformed in [padded.dropLast(), padded + Data([0]), Data(repeating: 0, count: size), Data(repeating: 255, count: size)] {
                XCTAssertThrowsError(try P.unpad(String.self, Data(malformed), size: size))
            }
        }
    }
}

final class V3Wire: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Data] = []
    var last: Data? { lock.withLock { values.last } }
    var all: [Data] { lock.withLock { values } }
    var count: Int { lock.withLock { values.count } }
    private let firstSubmission = XCTestExpectation(description: "first physical peer frame")
    func append(_ data: Data) throws {
        let first = lock.withLock { () -> Bool in
            let first = values.isEmpty
            values.append(data)
            return first
        }
        if first { firstSubmission.fulfill() }
    }
    func firstFrame() async throws -> Data {
        // A fixed number of Task.yield calls is not a readiness condition: a
        // loaded CI executor may not run the producer within that many turns.
        let result = await XCTWaiter.fulfillment(of: [firstSubmission], timeout: 3)
        XCTAssertEqual(result, .completed)
        return try XCTUnwrap(lock.withLock { values.first })
    }
}
actor V3Vault: IdentityVaultProtocol {
    let descriptor: BridgeChannelAuthentication.PublicIdentity
    let key: Curve25519.Signing.PrivateKey
    let p256: P256.Signing.PrivateKey?
    let fixed: (Data, Data)?
    private(set) var signCount = 0
    private(set) var signedBytes: Data?
    var beforeExist: (@Sendable () async -> Void)?
    var beforeSign: (@Sendable () async -> Void)?
    init(identity: BridgeChannelAuthentication.PublicIdentity, seed: Data, fixed: (Data, Data)? = nil) throws {
        descriptor = identity; key = try .init(rawRepresentation: seed); self.fixed = fixed
        p256 = identity.algorithm == .ECDSA ? try .init(rawRepresentation: seed) : nil
    }
    func setBarriers(exist: (@Sendable () async -> Void)? = nil, sign: (@Sendable () async -> Void)? = nil) {
        beforeExist = exist; beforeSign = sign
    }
    func identityExistInVault(_ identity: Identity) async -> Bool {
        await beforeExist?()
        return (try? BridgeChannelAuthentication.PublicIdentity(identity)) == descriptor
    }
    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        signCount += 1; signedBytes = messageData; await beforeSign?()
        if let fixed {
            // CryptoKit may randomize Ed25519 signatures. Freeze a independently
            // generated valid signature only for this exact synthetic message.
            guard messageData == fixed.0, IdentityPublicKeySignatureVerifier.verify(signature: fixed.1, messageData: messageData, identity: descriptor.makeIdentity()) else {
                throw BridgeChannelAuthentication.Failure.invalidProof
            }
            return fixed.1
        }
        if let p256 { return try p256.signature(for: messageData).derRepresentation }
        return try key.signature(for: messageData)
    }
    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { descriptor.makeIdentity() }
    func saveIdentity(_ identity: Identity) async {}
    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: messageData, identity: identity)
    }
    func randomBytes64() async -> Data? { nil }
    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) { throw BridgeChannelAuthentication.Failure.unavailable }
    func identity(forUUID uuid: String) async -> Identity? { uuid == descriptor.uuid ? descriptor.makeIdentity() : nil }
}

// Drives the real gate/session at the same synchronous send boundary as Scanner.
// It exposes inner wire bytes, never production keys, to the adversarial test.
private final class V3Transport: BridgeTransportProtocol, @unchecked Sendable {
    weak var gate: BridgeChannelTransport?
    let wire = V3Wire()
    var beforeSubmission: (@Sendable (Data) async throws -> Void)?
    var submitted: (@Sendable (Data) -> Void)?
    var beforeFirstSubmission: (@Sendable () async -> Void)?
    var afterFirstSubmission: (@Sendable () async -> Void)?
    var beforeClose: (@Sendable () async -> Void)?
    func close() async { await beforeClose?() }
    func setDelegate(_ delegate: BridgeDelegateProtocol) { gate = delegate as? BridgeChannelTransport }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws {
        if wire.count == 0 { await beforeFirstSubmission?() }
        try await beforeSubmission?(data)
        try gate!.submitPeerFrame(data) { try wire.append($0) }
        submitted?(data)
        if wire.count == 1 { await afterFirstSubmission?() }
    }
    func identityVault(for: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    static func new() -> BridgeTransportProtocol { V3Transport() }
    func receive(_ data: Data) async throws {
        do {
            let plain = try gate!.openPeerFrame(data)
            if plain.isEmpty { return }
            try gate!.submitPeerReceipts { try wire.append($0) }
            try gate!.validateInboundPayload(plain)
            try await gate!.consumeCommand(command: JSONDecoder().decode(BridgeCommand.self, from: plain))
        } catch { await gate!.close(); throw error }
    }
}
private final class V3Delegate: BridgeDelegateProtocol, @unchecked Sendable {
    let uuid = UUID().uuidString
    private let lock = NSLock(); private var closes = 0; private var deliveries = 0; private var factories = 0
    var counts: (factory: Int, close: Int, delivery: Int) { lock.withLock { (factories, closes, deliveries) } }
    func created() { lock.withLock { factories += 1 } }
    func consumeCommand(command: BridgeCommand) async throws { lock.withLock { deliveries += 1 } }
    func consumeResponse(command: BridgeCommand) async throws { lock.withLock { deliveries += 1 } }
    func sendCommand(command: Command, identity: Identity, payload: ValueType?) async {}
    func sendSetValueState(for requestedKey: String, setValueState: SetValueState) async {}
    func pushError(errorMessage: String?, error: Error?) async { lock.withLock { closes += 1 } }
    func ready() async throws {}
}
private final class V3Clock: @unchecked Sendable {
    private let lock = NSLock(); private var wall = 1_800_000_000.125; private var mono = 10.0
    func date() -> Date { lock.withLock { Date(timeIntervalSince1970: wall) } }
    func uptime() -> TimeInterval { lock.withLock { mono } }
    func advance(wall: Double = 0, mono: Double = 0) { lock.withLock { self.wall += wall; self.mono += mono } }
}
private actor V3Barrier {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    func wait() async {
        entered = true; observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func reached() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { blocked?.resume(); blocked = nil }
}
private final class V3GatePair {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    let i: BridgeChannelTransport, r: BridgeChannelTransport
    let it = V3Transport(), rt = V3Transport()
    let id = V3Delegate(), rd = V3Delegate()
    let iv: V3Vault, rv: V3Vault
    let clock = V3Clock()
    let limits: BridgeChannelLimits
    let io: Identity, ro: Identity
    init(policy: P.DisclosurePolicy? = nil, responderPolicy: P.DisclosurePolicy? = nil,
         family: String = "vectors", sameIdentity: Bool = false, limits: BridgeChannelLimits = .init(), factoryBarrier: V3Barrier? = nil, factoryRole: P.Role = .initiator,
         factory: BridgeChannelTransport.ServerFactory? = nil,
         responderRecheck: @escaping @Sendable (A.PublicIdentity) async throws -> Void = { _ in },
         recheck: @escaping @Sendable (A.PublicIdentity) async throws -> Void = { _ in }) throws {
        self.limits = limits
        let v = try BridgePeerV3Tests.vectors(family)
        let ide = try A.decode(A.PublicIdentity.self, from: v["identity0"]!)
        let rde = sameIdentity ? ide : try A.decode(A.PublicIdentity.self, from: v["identity1"]!)
        iv = try .init(identity: ide, seed: v["seed0"]!); rv = try .init(identity: rde, seed: v[sameIdentity ? "seed0" : "seed1"]!)
        io = ide.makeIdentity(); ro = rde.makeIdentity(); io.identityVault = iv; ro.identityVault = rv
        let endpoint = try P.Endpoint(initiator: "I", responder: "R", setupID: UUID().uuidString, domain: "nearby")
        i = try BridgeChannelTransport(underlying: it, peerEndpoint: endpoint, role: .initiator, owner: io,
            limits: limits, source: UUID().uuidString, disclosurePolicy: policy ?? .anyProvenIdentity(allowUnauthenticatedInitiator: true),
            recheckPolicy: recheck, wallClock: clock.date, monotonic: clock.uptime) { [id] gate, session in
                if let factory, factoryRole == .initiator { return try await factory(gate, session) }
                id.created(); gate.setDelegate(id)
                if factoryRole == .initiator { await factoryBarrier?.wait() }
                return id
            }
        r = try BridgeChannelTransport(underlying: rt, peerEndpoint: endpoint, role: .responder, owner: ro,
            limits: limits, source: UUID().uuidString, disclosurePolicy: responderPolicy ?? .anyProvenIdentity(allowUnauthenticatedInitiator: true),
            recheckPolicy: responderRecheck, wallClock: clock.date, monotonic: clock.uptime) { [rd] gate, session in
                if let factory, factoryRole == .responder { return try await factory(gate, session) }
                rd.created(); gate.setDelegate(rd)
                if factoryRole == .responder { await factoryBarrier?.wait() }
                return rd
            }
    }
    func start() async throws -> Task<Void, Error> {
        let task = Task { try await i.startPeer() }
        do { _ = try await it.wire.firstFrame(); return task }
        catch { await stop(task); throw error }
    }
    func step(_ step: Int) async throws {
        if step.isMultiple(of: 2) { try await it.receive(XCTUnwrap(rt.wire.last)) }
        else { try await rt.receive(XCTUnwrap(it.wire.last)) }
    }
    func stop(_ task: Task<Void, Error>) async {
        await i.close(); await r.close(); _ = try? await task.value
    }
}

extension BridgePeerV3Tests {
    func testExplicitDisclosurePolicyRejectsBeforeInitiatorSigning() async throws {
        let v = try Self.vectors(), wrong = try A.decode(A.PublicIdentity.self, from: v["identity0"]!)
        for any in [false,true] {
            let pair = try V3GatePair(policy: any ? .anyProvenIdentity(allowUnauthenticatedInitiator: true)
                : .expectedIdentities(domain: "nearby", identities: [wrong], allowUnauthenticatedInitiator: true))
            let task = try await pair.start()
            try await pair.step(1)
            XCTAssertNil(pair.r.session.publicIdentity)
            XCTAssertEqual(pair.rd.counts.factory, 0)
            if any {
                for step in 2...5 { try await pair.step(step) }
                try await task.value
                XCTAssertEqual(pair.i.session.publicIdentity, try A.PublicIdentity(pair.ro))
                XCTAssertEqual(pair.id.counts.factory, 1); XCTAssertEqual(pair.rd.counts.factory, 1)
            } else {
                do { try await pair.step(2); XCTFail("Unaccepted responder disclosed initiator") } catch {}
                let count = await pair.iv.signCount
                XCTAssertEqual(count, 0); XCTAssertEqual(pair.it.wire.count, 1)
                XCTAssertEqual(pair.id.counts.factory, 0); XCTAssertEqual(pair.rd.counts.factory, 0)
            }
            await pair.stop(task)
        }
        let pair = try V3GatePair(responderPolicy: .anyProvenIdentity(allowUnauthenticatedInitiator: false))
        let task = try await pair.start()
        do { try await pair.step(1); XCTFail("Responder disclosure policy ignored") } catch {}
        let count = await pair.rv.signCount
        XCTAssertEqual(count, 0); XCTAssertEqual(pair.rt.wire.count, 0)
        await pair.stop(task)
    }

    func testSuspendedVaultExistenceAndSignerCannotSurviveCloseRevokeOrExpiry() async throws {
        for role in [P.Role.initiator, .responder] {
            for existence in [true,false] {
                for reason in ["close","revoke","monotonic","wallForward","wallBackward"] {
                    let pair = try V3GatePair(), barrier = V3Barrier()
                    let vault = role == .initiator ? pair.iv : pair.rv
                    if existence { await vault.setBarriers(exist: { await barrier.wait() }) }
                    else { await vault.setBarriers(sign: { await barrier.wait() }) }
                    let task = try await pair.start()
                    if role == .initiator { try await pair.step(1) }
                    let pending = Task { try await pair.step(role == .initiator ? 2 : 1) }
                    await barrier.reached()
                    let gate = role == .initiator ? pair.i : pair.r
                    let before = (role == .initiator ? pair.it : pair.rt).wire.count
                    switch reason {
                    case "close": await gate.close()
                    case "revoke": gate.session.revoke()
                    case "monotonic": pair.clock.advance(mono: 10)
                    case "wallForward": pair.clock.advance(wall: 30)
                    default: pair.clock.advance(wall: -600, mono: 10)
                    }
                    XCTAssertGreaterThan(pair.limits.outstandingWorkCount, 0, "Suspended work must stay reserved")
                    await barrier.release()
                    do { try await pending.value; XCTFail("Late signer continued: \(role)/\(existence)/\(reason)") } catch {}
                    let signCount = await vault.signCount
                    XCTAssertEqual(signCount, existence ? 0 : 1)
                    XCTAssertEqual((role == .initiator ? pair.it : pair.rt).wire.count, before)
                    XCTAssertEqual(pair.id.counts.factory, 0); XCTAssertEqual(pair.rd.counts.factory, 0)
                    await pair.stop(task)
                    XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
                }
            }
        }
    }

    func testSuspendedFactoryIsRetiredOnceAndNeverPublishesReady() async throws {
        for role in [P.Role.initiator, .responder] {
            let barrier = V3Barrier(), pair = try V3GatePair(factoryBarrier: barrier, factoryRole: role)
            let stepToHold = role == .initiator ? 4 : 5
            let gate = role == .initiator ? pair.i : pair.r, delegate = role == .initiator ? pair.id : pair.rd
            let task = try await pair.start()
            for step in 1..<stepToHold { try await pair.step(step) }
            let pending = Task { try await pair.step(stepToHold) }
            await barrier.reached()
            await gate.close()
            XCTAssertFalse(gate.canSendPeerData)
            XCTAssertEqual(delegate.counts.close, 0, "Provisional delegate is owned by the factory")
            await barrier.release()
            do { try await pending.value; XCTFail() } catch {}
            XCTAssertEqual(delegate.counts.close, 1)
            XCTAssertFalse(gate.canSendPeerData)
            await pair.stop(task)
            XCTAssertEqual(delegate.counts.close, 1)
            XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
        }
    }
}

private struct V3VectorExchange {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    let v: [String: Data]
    let i: P.Operation, r: P.Operation
    let iv: V3Vault, rv: V3Vault
    let wire = V3Wire()
    init(_ name: String = "vectors", policy: P.DisclosurePolicy = .anyProvenIdentity(allowUnauthenticatedInitiator: true)) throws {
        v = try BridgePeerV3Tests.vectors(name)
        let endpoint = try A.decode(P.Endpoint.self, from: v["endpoint"]!)
        let ih = try A.decode(P.Hello.self, from: v["hello0"]!), rh = try A.decode(P.Hello.self, from: v["hello1"]!)
        let id = try A.decode(A.PublicIdentity.self, from: v["identity0"]!), rd = try A.decode(A.PublicIdentity.self, from: v["identity1"]!)
        iv = try V3Vault(identity: id, seed: v["seed0"]!, fixed: (v["challenge0"]!,v["signature0"]!))
        rv = try V3Vault(identity: rd, seed: v["seed1"]!, fixed: (v["challenge1"]!,v["signature1"]!))
        let io = id.makeIdentity(), ro = rd.makeIdentity(); io.identityVault = iv; ro.identityVault = rv
        i = try P.Operation(owner: io, endpoint: endpoint, role: .initiator, generation: ih.generation, policy: policy,
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000.125) }, ephemeral: .init(rawRepresentation: v["dh0"]!), nonce: ih.nonce)
        r = try P.Operation(owner: ro, endpoint: endpoint, role: .responder, generation: rh.generation, policy: policy,
            wallClock: { Date(timeIntervalSince1970: 1_800_000_000.250) }, ephemeral: .init(rawRepresentation: v["dh1"]!), nonce: rh.nonce)
    }
    func advance(to step: Int) async throws {
        _ = try await i.begin(live: {})
        for previous in 1..<step { _ = try await receive(previous, v["W\(previous)"]!) }
    }
    func receive(_ step: Int, _ data: Data) async throws -> BridgePeerRecordLayer? {
        try await (step.isMultiple(of: 2) ? i : r).receive(data, live: {}, authenticate: { _,_ in },
            recheck: {}, send: { try wire.append($0) })
    }
    func assertRejected(_ step: Int, _ data: Data, label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await advance(to: step)
        let before = wire.count
        do { _ = try await receive(step, data); XCTFail("Accepted \(label)", file: file, line: line) } catch {}
        XCTAssertEqual(wire.count, before, label, file: file, line: line)
        do { _ = try await receive(step, v["W\(step)"]!); XCTFail("Reopened \(label)", file: file, line: line) } catch {}
        if step == 2 { let count = await iv.signCount; XCTAssertEqual(count, 0, label, file: file, line: line) }
        if step == 1 { let count = await rv.signCount; XCTAssertEqual(count, 0, label, file: file, line: line) }
    }
}

extension BridgePeerV3Tests {
    private func json(_ bytes: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]) }
    private func canonical(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.withoutEscapingSlashes]) }
    private func changedEnvelope(_ bytes: Data, _ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var outer = try json(bytes), body = try json(Data((outer["&string"] as! String).utf8))
        try mutate(&body); outer["&string"] = String(decoding: try canonical(body), as: UTF8.self)
        return try canonical(outer)
    }
    // Models a legitimate DH participant: correct AEAD with attacker-selected
    // Auth/Finished fields. Tag failure alone cannot test inner validation.
    private func encryptedMutation(_ step: Int, v: [String: Data], repairMAC: Bool = true,
                                   mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        let index = step.isMultiple(of: 2) ? 1 : 0
        var value = try json(step < 4 ? v["Auth\(index)"]! : Data(v["pad\(step)"]!.dropFirst(4).prefix(
            v["pad\(step)"]!.prefix(4).reduce(0) { ($0 << 8) | Int($1) })))
        try mutate(&value)
        if step < 4 && repairMAC {
            let core = ["endpoint":value["endpoint"]!,"identity":value["identity"]!,"proof":value["proof"]!]
            let context = v[step == 2 ? "T0" : "T2"]!
            value["identityMAC"] = P.mac(SymmetricKey(data: v["identity-mac-key\(index)"]!),
                P.framed("identity-mac", Data((index == 1 ? "responder" : "initiator").utf8), context, try canonical(core))).base64EncodedString()
        }
        let encoded = try canonical(value), size = step < 4 ? 8192 : 1024
        let padded = P.integer(UInt32(encoded.count)) + encoded + Data(repeating: 0, count: size-4-encoded.count)
        let box = try ChaChaPoly.seal(padded, using: SymmetricKey(data: v["handshake-key\(index)"]!),
            nonce: P.nonce(step < 4 ? 0 : 1), authenticating: v["aad\(step)"]!)
        return try changedEnvelope(v["W\(step)"]!) { $0["sealed"] = (box.ciphertext+box.tag).base64EncodedString() }
    }

    func testEveryHelloFieldAndLegacyProfileFailsBeforeDisclosure() async throws {
        let v = try Self.vectors()
        for step in [1,2] {
            for field in ["profile","role","ephemeralPublicKey","nonce","generation","issuedAtMilliseconds","missing","extra"] {
                let changed = try changedEnvelope(v["W\(step)"]!) { body in
                    var hello = step == 1 ? body : body["hello"] as! [String: Any]
                    switch field {
                    case "profile": hello[field] = "org.haven.bridge-peer-channel.v2"
                    case "role": hello[field] = step == 1 ? "responder" : "initiator"
                    case "ephemeralPublicKey", "nonce": hello[field] = Data(repeating: 0, count: 31).base64EncodedString()
                    case "generation": hello[field] = step == 1 ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111"
                    case "issuedAtMilliseconds": hello[field] = Int64.max
                    case "missing": hello.removeValue(forKey: "nonce")
                    default: hello["identity"] = "cleartext-forbidden"
                    }
                    if step == 1 { body = hello } else { body["hello"] = hello }
                }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/\(field)")
            }
            for time: Int64 in [-1, Int64.min, step == 1 ? 1_799_999_990_250 : 1_799_999_990_125, step == 1 ? 1_800_000_005_251 : 1_800_000_005_126] {
                let changed = try changedEnvelope(v["W\(step)"]!) { body in
                    if step == 1 { body["issuedAtMilliseconds"] = time }
                    else { var hello = body["hello"] as! [String: Any]; hello["issuedAtMilliseconds"] = time; body["hello"] = hello }
                }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/time/\(time)")
            }
        }
        for old in ["channelAuthPeerHello","channelAuthPeerProof","channelAuthPeerAccepted","channelAuthHello"] {
            var outer = try json(v["W1"]!); outer["cmd"] = old
            try await V3VectorExchange().assertRejected(1, canonical(outer), label: old)
        }
        try await V3VectorExchange().assertRejected(1, Data("HPC2".utf8)+Data(repeating: 0,count: 90), label: "HPC2")
    }

    func testAuthenticatedInnerFieldMutationsRequireMACSignatureAndFrozenContext() async throws {
        let v = try Self.vectors()
        for step in [2,3] {
            for group in ["endpoint","identity","proof"] {
                let fields = group == "endpoint" ? ["initiator","responder","setupID","domain"]
                    : group == "identity" ? ["uuid","algorithm","curve","publicKey"] : ["sessionID","generation","signature"]
                for field in fields {
                    let changed = try encryptedMutation(step, v: v) { value in
                        var object = value[group] as! [String: Any]
                        if field == "publicKey" { object[field] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }
                        else if field == "signature" { object[field] = Data(repeating: 0, count: 64).base64EncodedString() }
                        else { object[field] = field == "algorithm" ? "ECDSA" : field == "curve" ? "P256" : UUID().uuidString }
                        value[group] = object
                    }
                    try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/\(group)/\(field)/valid-AEAD-MAC")
                }
            }
            for bad in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 32), v["identityMAC\(step == 2 ? 0 : 1)"]!] {
                let changed = try encryptedMutation(step, v: v, repairMAC: false) { $0["identityMAC"] = bad.base64EncodedString() }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/MAC/valid-signature-AEAD")
            }
            for field in ["sessionID","generation","transcriptDigest"] {
                // Proof challenge is independently signed over a wrong local
                // claim, while AEAD+identity MAC are repaired by the DH attacker.
                let index = step == 2 ? 1 : 0
                var challenge = try json(v["challenge\(index)"]!)
                let name = field == "sessionID" ? "resource" : field == "generation" ? "audience" : "domain"
                challenge[name] = "wrong-" + (challenge[name] as! String)
                let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: v["seed\(index)"]!).signature(for: canonical(challenge))
                let changed = try encryptedMutation(step, v: v) { value in
                    var proof = value["proof"] as! [String: Any]; proof["signature"] = signature.base64EncodedString(); value["proof"] = proof
                }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/signed-wrong-\(name)")
            }
        }
        for step in [4,5] {
            for field in ["sessionID","generation","transcriptDigest","verifyData"] {
                let changed = try encryptedMutation(step, v: v) { value in
                    if field == "verifyData" { value[field] = Data(repeating: 0, count: 32).base64EncodedString() }
                    else { var ack = value["ack"] as! [String: Any]; ack[field] = UUID().uuidString; value["ack"] = ack }
                }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/\(field)/valid-AEAD")
            }
        }
    }

    func testEveryOutOfOrderHandshakeMessageAndTamperedTagIsTerminal() async throws {
        let v = try Self.vectors()
        for step in 1...5 {
            for wrong in 1...5 where step != wrong {
                try await V3VectorExchange().assertRejected(step, v["W\(wrong)"]!, label: "M\(wrong) at M\(step)")
            }
            if step > 1 {
                let changed = try changedEnvelope(v["W\(step)"]!) { body in
                    var sealed = Data(base64Encoded: body["sealed"] as! String)!
                    sealed[sealed.count-1] ^= 1; body["sealed"] = sealed.base64EncodedString()
                }
                try await V3VectorExchange().assertRejected(step, changed, label: "M\(step)/tag")
            }
        }
    }

    func testActiveInitiatorCanReadResponderButUnrelatedRelayDHCannot() async throws {
        let exchange = try V3VectorExchange(), v = exchange.v
        try await exchange.advance(to: 2)
        let envelope = try P.decodeEnvelope(XCTUnwrap(exchange.wire.last))
        let offer = try A.decode(P.ResponderAuth.self, from: Data(envelope.body.utf8))
        // M intentionally starts DH as I and knows its own private DH key.
        let prk = try P.extract(.init(rawRepresentation: v["dh0"]!), remote: offer.hello.ephemeralPublicKey, salt: v["T0"]!)
        let box = try ChaChaPoly.SealedBox(nonce: P.nonce(0), ciphertext: offer.sealed.dropLast(16), tag: offer.sealed.suffix(16))
        let plain = try ChaChaPoly.open(box, using: P.key(prk,"handshake-key",.responder,v["T0"]!), authenticating: v["aad2"]!)
        XCTAssertEqual(try A.encode(P.unpad(P.Authentication.self, plain, size: 8192).identity), v["identity1"])
        let calls = await exchange.iv.signCount; XCTAssertEqual(calls, 0)
        let unrelated = try P.extract(.init(), remote: offer.hello.ephemeralPublicKey, salt: v["T0"]!)
        XCTAssertThrowsError(try ChaChaPoly.open(box, using: P.key(unrelated,"handshake-key",.responder,v["T0"]!), authenticating: v["aad2"]!))
    }
}

extension BridgePeerV3Tests {
    func testLiveMixedAlgorithmsFixedLengthsAndSameKeyReflection() async throws {
        for family in ["vectors","p256","mixed-i","mixed-r"] {
            for same in [true,false] {
                let pair = try V3GatePair(family: family, sameIdentity: same)
                let task = try await pair.start()
                for step in 1...5 {
                    if step > 1 {
                        let sender = step.isMultiple(of: 2) ? pair.rt : pair.it
                        let body = try json(Data(P.decodeEnvelope(XCTUnwrap(sender.wire.last)).body.utf8))
                        XCTAssertEqual(Data(base64Encoded: body["sealed"] as! String)?.count, step < 4 ? 8208 : 1040)
                    }
                    try await pair.step(step)
                }
                try await task.value
                XCTAssertEqual(pair.i.session.publicIdentity, try A.PublicIdentity(pair.ro))
                XCTAssertEqual(pair.r.session.publicIdentity, try A.PublicIdentity(pair.io))
                XCTAssertEqual(pair.i.peerRecordCounts?.sent, 0); XCTAssertEqual(pair.r.peerRecordCounts?.sent, 0)
                try await pair.i.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("same-key-data"), cid: 1)))
                let record = try XCTUnwrap(pair.it.wire.last)
                try await pair.rt.receive(record)
                XCTAssertEqual(pair.rd.counts.delivery, 1)
                do { try await pair.it.receive(record); XCTFail("Reflection with same signing key") } catch {}
                XCTAssertEqual(pair.id.counts.delivery, 0)
                await pair.stop(task)
            }
        }
    }

    func testIndependentDHLegsCannotSpliceProofOrFinishedEvenWithSameIdentities() async throws {
        for targetStep in [2,3,4,5] {
            let a = try V3GatePair(), b = try V3GatePair()
            let ta = try await a.start(), tb = try await b.start()
            for step in 1..<targetStep { try await a.step(step); try await b.step(step) }
            let wrong = try XCTUnwrap((targetStep.isMultiple(of: 2) ? a.rt : a.it).wire.last)
            let receiver = targetStep.isMultiple(of: 2) ? b.it : b.rt
            do { try await receiver.receive(wrong); XCTFail("Spliced M\(targetStep)") } catch {}
            XCTAssertFalse(receiver.gate!.canSendPeerData)
            XCTAssertEqual((targetStep.isMultiple(of: 2) ? b.id : b.rd).counts.factory, 0)
            XCTAssertEqual(b.id.counts.delivery + b.rd.counts.delivery, 0)
            // The other independent leg still completes.
            for step in targetStep...5 { try await a.step(step) }
            try await ta.value; try a.i.session.check(); try a.r.session.check()
            await a.stop(ta); await b.stop(tb)
        }
    }

    func testRegisteredRemoteRevocationAndSuspendedPolicyPreventLocalDisclosure() async throws {
        let barrier = V3Barrier()
        let pair = try V3GatePair(recheck: { _ in await barrier.wait() })
        let task = try await pair.start(); try await pair.step(1)
        let pending = Task { try await pair.step(2) }
        await barrier.reached()
        let remote = try XCTUnwrap(pair.i.session.publicIdentity)
        pair.limits.revoke(identity: remote, domain: "nearby")
        await barrier.release()
        do { try await pending.value; XCTFail("Revoked policy continued") } catch {}
        let count = await pair.iv.signCount
        XCTAssertEqual(count, 0); XCTAssertEqual(pair.it.wire.count, 1)
        XCTAssertEqual(pair.id.counts.factory, 0)
        await pair.stop(task)
        XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
    }

    func testHandshakeQuotasStayBoundedAndFinalFinishedWaitsForAuthenticatedProgress() async throws {
        var configuration = BridgeChannelLimits.Configuration()
        configuration.maximumPendingSendBytesPerConnection = 14_000
        let pair = try V3GatePair(limits: .init(configuration: configuration))
        let task = try await pair.start()
        for step in 1...5 { try await pair.step(step) }
        try await task.value
        // I's M5 still occupies bytes, although physical send returned.
        XCTAssertThrowsError(try pair.i.session.acquireSend(bytes: 13_000))
        try pair.r.session.acquireSend(bytes: 13_000); pair.r.session.releaseSend(bytes: 13_000)
        try await pair.r.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("progress"), cid: 1)))
        try await pair.it.receive(XCTUnwrap(pair.rt.wire.last))
        try pair.i.session.acquireSend(bytes: 13_000); pair.i.session.releaseSend(bytes: 13_000)
        await pair.stop(task)
        XCTAssertEqual(pair.limits.retainedConnectionCount, 0)
    }
}

extension BridgePeerV3Tests {
    func testLateM1SendCompletionCannotUndoAuthenticatedProgress() async throws {
        let pair = try V3GatePair(), barrier = V3Barrier()
        pair.it.afterFirstSubmission = { await barrier.wait() }
        let task = try await pair.start()
        await barrier.reached()
        for step in 1...5 { try await pair.step(step) }
        XCTAssertTrue(pair.i.canSendPeerData); XCTAssertTrue(pair.r.canSendPeerData)
        await barrier.release()
        try await task.value
        try pair.i.session.check(); try pair.r.session.check()
        await pair.stop(task)
    }
}

extension BridgePeerV3Tests {
    func testPolicyChangeDuringVaultLookupOrSigningStopsDisclosure() async throws {
        for existence in [true, false] {
            let policy = V3MutablePolicy(), barrier = V3Barrier()
            let pair = try V3GatePair(recheck: { _ in try await policy.check() })
            if existence { await pair.iv.setBarriers(exist: { await barrier.wait() }) }
            else { await pair.iv.setBarriers(sign: { await barrier.wait() }) }
            let task = try await pair.start(); try await pair.step(1)
            let pending = Task { try await pair.step(2) }
            await barrier.reached(); await policy.deny(); await barrier.release()
            do { try await pending.value; XCTFail("Changed policy permitted disclosure") } catch {}
            let count = await pair.iv.signCount
            XCTAssertEqual(count, existence ? 0 : 1)
            XCTAssertEqual(pair.it.wire.count, 1)
            XCTAssertEqual(pair.id.counts.factory, 0)
            await pair.stop(task)
            XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
        }
    }

    func testPolicyChangeDuringEitherFactoryRetiresResultWithoutReady() async throws {
        for role in [P.Role.initiator, .responder] {
            let policy = V3MutablePolicy(), barrier = V3Barrier()
            let pair = try V3GatePair(factoryBarrier: barrier, factoryRole: role,
                responderRecheck: { _ in try await policy.check() }, recheck: { _ in try await policy.check() })
            let task = try await pair.start(), finalStep = role == .initiator ? 4 : 5
            for step in 1..<finalStep { try await pair.step(step) }
            let pending = Task { try await pair.step(finalStep) }
            await barrier.reached(); await policy.deny(); await barrier.release()
            do { try await pending.value; XCTFail("Changed policy published factory") } catch {}
            let gate = role == .initiator ? pair.i : pair.r, delegate = role == .initiator ? pair.id : pair.rd
            XCTAssertFalse(gate.canSendPeerData)
            XCTAssertEqual(delegate.counts.close, 1)
            await pair.stop(task)
            XCTAssertEqual(delegate.counts.close, 1)
            XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
        }
    }

    func testCloseAndDirectRevokeWinBeforePhysicalSendAdmission() async throws {
        for role in [P.Role.initiator,.responder] {
            for revoke in [true,false] {
                let pair = try V3GatePair(), barrier = V3Barrier()
                let physical = role == .initiator ? pair.it : pair.rt
                physical.beforeFirstSubmission = { await barrier.wait() }
                let start = Task { try await pair.i.startPeer() }
                let pending = Task {
                    if role == .responder {
                        _ = try await pair.it.wire.firstFrame()
                        try await pair.step(1)
                    }
                }
                await barrier.reached()
                if revoke { physical.gate!.session.revoke() } else { await physical.gate!.close() }
                await barrier.release()
                _ = try? await pending.value
                if role == .initiator { do { try await start.value; XCTFail() } catch {} }
                XCTAssertEqual(physical.wire.count, 0)
                XCTAssertEqual(pair.id.counts.factory + pair.rd.counts.factory, 0)
                await pair.stop(start)
                XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
            }
        }
    }

    func testRetiredSignerCannotAffectFreshChannelWithSameIdentity() async throws {
        let limits = BridgeChannelLimits(), old = try V3GatePair(limits: limits), barrier = V3Barrier()
        await old.rv.setBarriers(sign: { await barrier.wait() })
        let task = try await old.start(), pending = Task { try await old.step(1) }
        await barrier.reached()
        await old.r.close(); await old.i.close()
        XCTAssertGreaterThan(limits.outstandingWorkCount, 0)
        let fresh = try V3GatePair(limits: limits), next = try await fresh.start()
        for step in 1...5 { try await fresh.step(step) }
        try await next.value
        await barrier.release()
        do { try await pending.value; XCTFail() } catch {}
        _ = try? await task.value
        XCTAssertEqual(old.rt.wire.count, 0)
        try fresh.i.session.check(); try fresh.r.session.check()
        XCTAssertTrue(fresh.i.canSendPeerData); XCTAssertTrue(fresh.r.canSendPeerData)
        await fresh.stop(next)
        XCTAssertEqual(limits.outstandingWorkCount, 0)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
    }
}

private actor V3MutablePolicy {
    private var allowed = true
    func deny() { allowed = false }
    func check() throws {
        guard allowed else { throw BridgeChannelAuthentication.Failure.identityMismatch }
    }
}


extension BridgePeerV3Tests {
    func testPeerLateFactoryTransportBindingRetiresSubscriptionAndDeinitializesForBothRoles() async throws {
        for role in [P.Role.initiator, .responder] {
            for bindBeforeHold in [true, false] {
                let hold = BridgeLifecycleBarrier(), cleanup = BridgeLifecycleBarrier(), stats = BridgeFactoryLifetimeStats()
                let owner = await MockIdentityVault().identity(for: "factory", makeNewIfNotFound: true)!
                let pair = try V3GatePair(factoryRole: role, factory: { transport, _ in
                    try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: transport, stats: stats,
                        hold: hold, cleanup: cleanup, bindBeforeHold: bindBeforeHold)
                })
                let healthy = try V3GatePair(limits: pair.limits)
                let healthyStartup = try await healthy.start()
                for n in 1...5 { try await healthy.step(n) }
                try await healthyStartup.value
                let startup = try await pair.start(), step = role == .initiator ? 4 : 5
                for n in 1..<step { try await pair.step(n) }
                let pending = Task { try await pair.step(step) }
                await fulfillment(of: [hold.entered], timeout: 2)
                let gate = role == .initiator ? pair.i : pair.r
                XCTAssertFalse(gate.hasDelegate)
                await gate.close(); await hold.release()
                await fulfillment(of: [cleanup.entered], timeout: 2)
                XCTAssertGreaterThan(pair.limits.outstandingWorkCount, 0)
                XCTAssertEqual(stats.snapshot.subscriptions, 1)
                try await healthy.i.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("healthy"), cid: 1)))
                try await healthy.rt.receive(XCTUnwrap(healthy.it.wire.last))
                XCTAssertEqual(healthy.rd.counts.delivery, 1)
                await cleanup.release(); _ = try? await pending.value
                XCTAssertFalse(gate.hasDelegate); XCTAssertFalse(gate.canSendPeerData)
                XCTAssertEqual(stats.snapshot.retired, 1); XCTAssertEqual(stats.snapshot.subscriptions, 0)
                XCTAssertEqual(stats.snapshot.deinitialized, 1)
                await pair.stop(startup)
                XCTAssertTrue(healthy.i.canSendPeerData); XCTAssertTrue(healthy.r.canSendPeerData)
                await healthy.stop(healthyStartup)
                XCTAssertEqual(stats.snapshot.retired, 1); XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
            }
        }
    }

    func testPeerMuxHeldPhysicalSubmissionFencesReusedIDAndCIDWhileSiblingWorks() async throws {
        let owner = await MockIdentityVault().identity(for: "factory", makeNewIfNotFound: true)!
        let stats = BridgeFactoryLifetimeStats(), frames = BridgeMuxLifetimeFrames(), hold = BridgeLifecycleBarrier()
        let pair = try V3GatePair(factoryRole: .responder, factory: { transport, _ in
            BridgeMultiplexServerSession(physicalTransport: transport, maximumChannels: 3) { target, _, logical in
                let spy = try await BridgeFactoryLifetimeSpy.make(owner: owner, transport: logical,
                    stats: target == "old" ? stats : .init())
                spy.reply = target
                return spy
            }
        })
        let startup = try await pair.start()
        for step in 1...5 { try await pair.step(step) }
        try await startup.value
        pair.rt.beforeSubmission = { data in
            if (try? JSONDecoder().decode(BridgeCommand.self, from: data).payload) == .string("old") { await hold.hold() }
        }
        pair.rt.submitted = { data in if let frame = try? JSONDecoder().decode(BridgeCommand.self, from: data) { frames.append(frame) } }
        try await exerciseMuxSubmissionLifetime(owner: pair.io, hold: hold, frames: frames, stats: stats) { command in
            var command = command
            command.peerGeneration = pair.i.session.generation
            try await pair.r.consumeCommand(command: command)
        }
        await pair.stop(startup)
    }
}

// A real gate faces a legitimate DH participant with a known *test-owned*
// ephemeral key. This lets mutations have valid AEAD/MAC and reach context,
// signature and Finished checks instead of stopping at a bad tag.
private final class V3AdversarialGate {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    let pair: V3GatePair, gate: BridgeChannelTransport, physical: V3Transport
    let operation: P.Operation, privateKey = Curve25519.KeyAgreement.PrivateKey()
    let vault: V3Vault, owner: Identity, role: P.Role
    let sent = V3Wire()
    var history: [Int: Data] = [:]
    var start: Task<Void, Error>?
    init(step: Int, limits: BridgeChannelLimits) throws {
        pair = try V3GatePair(limits: limits)
        role = step.isMultiple(of: 2) ? .responder : .initiator
        gate = role == .responder ? pair.i : pair.r
        physical = role == .responder ? pair.it : pair.rt
        vault = role == .responder ? pair.rv : pair.iv
        owner = role == .responder ? pair.ro : pair.io
        operation = try P.Operation(owner: owner, endpoint: gate.session.peerEndpoint!, role: role,
            generation: UUID().uuidString, policy: .anyProvenIdentity(allowUnauthenticatedInitiator: true),
            wallClock: pair.clock.date, monotonic: pair.clock.uptime, ephemeral: privateKey)
    }
    func advance(to step: Int) async throws {
        await (role == .responder ? pair.r : pair.i).close() // unused opposite gate
        start = Task { try await gate.startPeer() }
        if role == .initiator { history[1] = try await operation.begin(live: {}) }
        else {
            history[1] = try await physical.wire.firstFrame()
        }
        for previous in 1..<step {
            if previous.isMultiple(of: 2) == step.isMultiple(of: 2) {
                try await physical.receive(history[previous]!); history[previous+1] = try XCTUnwrap(physical.wire.last)
            } else {
                _ = try await operation.receive(history[previous]!, live: {}, authenticate: { _,_ in }, recheck: {}, send: { try self.sent.append($0) })
                history[previous+1] = try XCTUnwrap(sent.last)
            }
        }
    }
    func mutated(_ step: Int, field: String) async throws -> Data {
        func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.withoutEscapingSlashes]) }
        if field.hasPrefix("hello.") {
            var outer = try object(history[step]!), body = try object(Data((outer["&string"] as! String).utf8))
            var hello = step == 1 ? body : body["hello"] as! [String: Any]
            let name = String(field.dropFirst(6))
            switch name {
            case "profile": hello[name] = "org.haven.bridge-peer-channel.v2"
            case "role": hello[name] = role == .initiator ? "responder" : "initiator"
            case "ephemeralPublicKey", "nonce": hello[name] = Data(repeating: 0, count: 31).base64EncodedString()
            case "lowOrder": hello["ephemeralPublicKey"] = Data(repeating: 0, count: 32).base64EncodedString()
            case "negativeTime": hello["issuedAtMilliseconds"] = Int64.min
            case "expiredTime": hello["issuedAtMilliseconds"] = Int64(pair.clock.date().timeIntervalSince1970 * 1000) - 10_000
            case "futureTime": hello["issuedAtMilliseconds"] = Int64(pair.clock.date().timeIntervalSince1970 * 1000) + 5_001
            case "generation": hello[name] = gate.session.generation
            case "issuedAtMilliseconds": hello[name] = Int64.max
            case "missing": hello.removeValue(forKey: "nonce")
            default: hello["identity"] = "forbidden-cleartext"
            }
            if step == 1 { body = hello } else { body["hello"] = hello }
            outer["&string"] = String(decoding: try encode(body), as: UTF8.self)
            return try encode(outer)
        }
        if field.hasPrefix("envelope.") {
            var outer = try object(history[step]!)
            switch String(field.dropFirst(9)) {
            case "ready": outer["cmd"] = "ready"
            case "legacy": outer["cmd"] = "channelAuthPeerHello"
            case "ws": outer["cmd"] = "channelAuthHello"
            case "cid": outer["cid"] = 1
            case "extra": outer["unknown"] = true
            case "trailing": return history[step]! + Data([0])
            default: return Data("HPC2".utf8) + Data(repeating: 0, count: 90)
            }
            return try encode(outer)
        }
        let ih = try A.decode(P.Hello.self, from: Data(P.decodeEnvelope(history[1]!).body.utf8))
        let rbody = try A.decode(P.ResponderAuth.self, from: Data(P.decodeEnvelope(history[2]!).body.utf8)), rh = rbody.hello
        let t0 = P.hash(P.framed("clear-2", P.hash(P.framed("wire-1", history[1]!)), try A.encode(rh)))
        var transcript = t0, transcripts: [Int: Data] = [1:t0]
        for n in 2..<step { transcript = P.hash(P.framed("wire-\(n)", transcript, history[n]!)); transcripts[n] = transcript }
        let prk = try P.extract(privateKey, remote: role == .initiator ? rh.ephemeralPublicKey : ih.ephemeralPublicKey, salt: t0)
        let key = P.key(prk, "handshake-key", role, t0), nonce = try P.nonce(step < 4 ? 0 : 1)
        let aad = P.framed("handshake-aead", Data(String(step).utf8), transcript)
        var outer = try object(history[step]!), body = try object(Data((outer["&string"] as! String).utf8))
        let sealed = Data(base64Encoded: body["sealed"] as! String)!
        let plain = try ChaChaPoly.open(.init(nonce: nonce, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)), using: key, authenticating: aad)
        let size = step < 4 ? 8192 : 1024, count = plain.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        var value = try object(Data(plain.dropFirst(4).prefix(count)))
        let path = field.split(separator: ".").map(String.init)
        if path[0] == "selfConsistentEndpoint" {
            var endpoint = value["endpoint"] as! [String: Any]
            endpoint[path[1]] = UUID().uuidString
            let changed = try A.decode(P.Endpoint.self, from: encode(endpoint))
            let challenge = try P.challenge(endpoint: changed, identity: A.PublicIdentity(owner), signer: role,
                local: operation.hello, remote: role == .initiator ? rh : ih, t0: t0, t2: transcripts[2],
                responder: role == .initiator ? A.PublicIdentity(pair.ro) : nil)
            let signature = try await vault.signMessageForIdentity(messageData: challenge.signingData, identity: owner)
            value["endpoint"] = endpoint
            value["proof"] = ["sessionID":changed.setupID,"generation":challenge.generation,"signature":signature.base64EncodedString()]
        } else if path[0] == "signed" {
            let signed = await vault.signedBytes
            var challenge = try object(XCTUnwrap(signed))
            let name = path[1]
            if name == "nonce" { challenge[name] = Data(repeating: 9, count: 32).base64EncodedString() }
            else if name == "issuedAt" || name == "expiresAt" { challenge[name] = (challenge[name] as! Double) + 1 }
            else { challenge[name] = "wrong-" + String(describing: challenge[name]!) }
            var proof = value["proof"] as! [String: Any]
            proof["signature"] = try await vault.signMessageForIdentity(messageData: encode(challenge), identity: owner).base64EncodedString()
            value["proof"] = proof
        } else if path[0] == "badMAC" || path[0] == "badFinished" {
            let isAuth = step < 4, name = isAuth ? "identityMAC" : "verifyData"
            switch path[1] {
            case "missing": value.removeValue(forKey: name)
            case "truncated": value[name] = Data(repeating: 0, count: 31).base64EncodedString()
            default:
                let other: P.Role = role == .initiator ? .responder : .initiator
                let chosenRole = path[1] == "direction" ? other : role
                let context = isAuth ? t0 : transcripts[3]!
                let chosenKey = path[1] == "key" ? SymmetricKey(size: .bits256) : P.key(prk, isAuth ? "identity-mac-key" : "finished-key", chosenRole, context)
                let bound = isAuth ? try encode(["endpoint":value["endpoint"]!,"identity":value["identity"]!,"proof":value["proof"]!]) : try encode(value["ack"] as! [String: Any])
                let contextBytes = path[1] == "transcript" ? Data(repeating: 9, count: 32) : transcript
                value[name] = P.mac(chosenKey, P.framed(isAuth ? "identity-mac" : "finished", Data((isAuth ? chosenRole.rawValue : String(step)).utf8), contextBytes, bound)).base64EncodedString()
            }
        } else if path.count == 2 {
            var object = value[path[0]] as! [String: Any]
            let name = path[1]
            if name == "publicKey" { object[name] = Data(repeating: 7, count: 32).base64EncodedString() }
            else if name == "signature" { object[name] = Data(repeating: 7, count: 64).base64EncodedString() }
            else { object[name] = UUID().uuidString }
            value[path[0]] = object
        } else if field == "identityMAC" || field == "verifyData" { value[field] = Data(repeating: 0, count: 32).base64EncodedString() }
        else if field == "extra" { value["unexpected"] = ["nested": true] }
        if step < 4 && field != "identityMAC" && !field.hasPrefix("badMAC.") {
            let core = ["endpoint":value["endpoint"]!,"identity":value["identity"]!,"proof":value["proof"]!]
            value["identityMAC"] = P.mac(P.key(prk,"identity-mac-key",role,t0), P.framed("identity-mac",Data(role.rawValue.utf8),transcript,try encode(core))).base64EncodedString()
        }
        if step >= 4 && field.hasPrefix("ack.") {
            // Correct Finished HMAC over the wrong ack still must not match the
            // locally expected session/generation/transcript claim.
            value["verifyData"] = P.mac(P.key(prk,"finished-key",role,transcripts[3]!), P.framed("finished",Data(String(step).utf8),transcript,try encode(value["ack"] as! [String: Any]))).base64EncodedString()
        }
        var encoded = try encode(value)
        if field == "duplicateJSON" { encoded = Data("{\"extra\":1,\"extra\":1,".utf8) + encoded.dropFirst() }
        var padded = P.integer(UInt32(encoded.count)) + encoded + Data(repeating: 0, count: size-4-encoded.count)
        if field == "padding" { padded[padded.count-1] = 1 }
        if field == "jsonLength" { padded.replaceSubrange(0..<4, with: P.integer(UInt32(size))) }
        if field == "paddingLength" { padded.removeLast() }
        let box = try ChaChaPoly.seal(padded, using: key, nonce: field == "nonce" ? P.nonce(7) : nonce, authenticating: aad)
        var replacement = box.ciphertext + box.tag
        if field == "sealedLength" { replacement.removeLast() }
        if field == "ciphertext" { replacement[replacement.startIndex] ^= 1 }
        if field == "tag" { replacement[replacement.index(before: replacement.endIndex)] ^= 1 }
        body["sealed"] = replacement.base64EncodedString(); outer["&string"] = String(decoding: try encode(body), as: UTF8.self)
        return try encode(outer)
    }
    func stop() async { await gate.close(); await operation.cancel(); if let start { _ = try? await start.value } }
}

extension BridgePeerV3Tests {
    func testValidAEADInnerMutationsCloseRealGateReleaseQuotaAndPreserveHealthySibling() async throws {
        let quotaClock = V3Clock(), limits = BridgeChannelLimits(monotonic: quotaClock.uptime)
        let sibling = try V3GatePair(limits: limits), healthy = try await sibling.start()
        for step in 1...5 { try await sibling.step(step) }; try await healthy.value
        let baseline = limits.retainedConnectionCount
        for step in 1...5 {
            let helloFields = ["profile","role","ephemeralPublicKey","lowOrder","nonce","generation","issuedAtMilliseconds","negativeTime","expiredTime","futureTime","missing","extra"].map { "hello." + $0 }
            let envelopeFields = ["ready","legacy","ws","cid","extra","trailing","HPC2"].map { "envelope." + $0 }
            let encryptionFields = ["paddingLength","duplicateJSON","nonce","sealedLength","ciphertext"]
            let fields = envelopeFields + (step == 1 ? helloFields : encryptionFields + (step == 2 ? helloFields : []) + (step < 4 ? ["endpoint.initiator","endpoint.responder","endpoint.setupID","endpoint.domain",
                "identity.uuid","identity.algorithm","identity.curve","identity.publicKey","proof.sessionID","proof.generation","proof.signature",
                "signed.resource","signed.audience","signed.domain","signed.nonce","signed.issuedAt","signed.expiresAt","signed.action",
                "identityMAC","badMAC.missing","badMAC.truncated","badMAC.direction","badMAC.key","badMAC.transcript","extra","padding","jsonLength","tag",
                "selfConsistentEndpoint.initiator","selfConsistentEndpoint.responder","selfConsistentEndpoint.setupID","selfConsistentEndpoint.domain"]
                : ["ack.sessionID","ack.generation","ack.transcriptDigest","verifyData","badFinished.missing","badFinished.truncated","badFinished.direction","badFinished.key","badFinished.transcript","extra","padding","jsonLength","tag"]))
            for field in fields {
                quotaClock.advance(mono: 60) // isolate field validation from the separately tested rate window
                print("V3 gate mutation M\(step)/\(field)")
                let attacker = try V3AdversarialGate(step: step, limits: limits)
                try await attacker.advance(to: step)
                let changed = try await attacker.mutated(step, field: field)
                do { try await attacker.physical.receive(changed); XCTFail("Accepted M\(step)/\(field)") } catch {}
                XCTAssertFalse(attacker.gate.canSendPeerData, field)
                XCTAssertFalse(attacker.gate.hasDelegate, field)
                XCTAssertEqual(attacker.pair.id.counts.factory + attacker.pair.rd.counts.factory, 0, field)
                XCTAssertEqual(attacker.pair.id.counts.delivery + attacker.pair.rd.counts.delivery, 0, field)
                XCTAssertEqual(attacker.gate.session.state, .closed, field)
                if let start = attacker.start { _ = try? await start.value }
                // Observe automatic error cleanup before the fixture can close
                // anything itself; otherwise this assertion could hide a leak.
                XCTAssertEqual(limits.retainedConnectionCount, baseline, field)
                await attacker.stop()
                XCTAssertEqual(limits.outstandingWorkCount, 0, field)
                let previous = sibling.rd.counts.delivery
                try await sibling.i.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("healthy"), cid: 1)))
                try await sibling.rt.receive(XCTUnwrap(sibling.it.wire.last))
                try await sibling.it.receive(XCTUnwrap(sibling.rt.wire.last)) // bounded receipt
                XCTAssertEqual(sibling.rd.counts.delivery, previous + 1, field)
            }
        }
        await sibling.stop(healthy)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
    }
}

extension BridgePeerV3Tests {
    func testWrongHandshakeStateAndMalformedRecordsRetireOnlyOffendingGate() async throws {
        let clock = V3Clock(), limits = BridgeChannelLimits(monotonic: clock.uptime)
        let sibling = try V3GatePair(limits: limits), healthy = try await sibling.start()
        for step in 1...5 { try await sibling.step(step) }; try await healthy.value
        let baseline = limits.retainedConnectionCount, vectors = try Self.vectors()
        func checkSibling() async throws {
            let before = sibling.rd.counts.delivery
            try await sibling.i.sendData(A.encode(BridgeCommand(cmd: "response", payload: .string("healthy"), cid: 1)))
            try await sibling.rt.receive(XCTUnwrap(sibling.it.wire.last))
            try await sibling.it.receive(XCTUnwrap(sibling.rt.wire.last))
            XCTAssertEqual(sibling.rd.counts.delivery, before + 1)
        }
        for step in 1...5 {
            for wrong in 1...5 where step != wrong {
                clock.advance(mono: 60)
                let attacker = try V3AdversarialGate(step: step, limits: limits)
                try await attacker.advance(to: step)
                do { try await attacker.physical.receive(vectors["W\(wrong)"]!); XCTFail("M\(wrong) accepted at M\(step)") } catch {}
                XCTAssertEqual(attacker.gate.session.state, .closed)
                if let start = attacker.start { _ = try? await start.value }
                XCTAssertEqual(limits.retainedConnectionCount, baseline)
                XCTAssertEqual(limits.outstandingWorkCount, 0)
                XCTAssertEqual(attacker.pair.id.counts.factory + attacker.pair.rd.counts.factory, 0)
                await attacker.stop(); try await checkSibling()
            }
        }
        for initiator in [true, false] {
            for field in ["magic", "generation", "direction", "counter", "tag", "ciphertext", "empty", "oversize", "replay", "gap", "reflection", "oldCipherNewHeader", "authAfterActive", "plaintext"] {
                clock.advance(mono: 60)
                let pair = try V3GatePair(limits: limits), start = try await pair.start()
                for step in 1...5 { try await pair.step(step) }; try await start.value
                let sender = initiator ? pair.i : pair.r, sending = initiator ? pair.it : pair.rt
                let victim = initiator ? pair.r : pair.i, receiving = initiator ? pair.rt : pair.it
                let delegate = initiator ? pair.rd : pair.id
                let body = try A.encode(BridgeCommand(cmd: "response", payload: .string("private"), cid: 1))
                try await sender.sendData(body)
                var bad = Data(try XCTUnwrap(sending.wire.last))
                switch field {
                case "magic": bad[0] ^= 1
                case "generation": bad.replaceSubrange(4..<40, with: Data(UUID().uuidString.utf8))
                case "direction": bad[40] ^= 1
                case "counter": bad[48] ^= 1
                case "tag": bad[bad.count-1] ^= 1
                case "ciphertext": bad[49] ^= 1
                case "empty": bad = Data()
                case "oversize": bad = Data(repeating: 0, count: BridgePeerRecordLayer.maximumPlaintext + BridgePeerRecordLayer.overhead + 1)
                case "replay": try await receiving.receive(bad)
                case "gap": try await sender.sendData(body); bad = Data(try XCTUnwrap(sending.wire.last))
                case "reflection": try await victim.sendData(body); bad = Data(try XCTUnwrap(receiving.wire.last))
                case "oldCipherNewHeader":
                    let old = try V3GatePair(limits: limits), oldStart = try await old.start()
                    for step in 1...5 { try await old.step(step) }; try await oldStart.value
                    try await old.i.sendData(body)
                    var oldWire = Data(try XCTUnwrap(old.it.wire.last))
                    oldWire.replaceSubrange(0..<49, with: bad.prefix(49)); bad = oldWire
                    await old.stop(oldStart)
                case "authAfterActive": bad = vectors["W1"]!
                default: bad = body
                }
                let before = delegate.counts.delivery
                do { try await receiving.receive(bad); XCTFail("Accepted \(field), initiator=\(initiator)") } catch {}
                XCTAssertEqual(victim.session.state, .closed, field)
                XCTAssertEqual(delegate.counts.delivery, before, field)
                XCTAssertFalse(victim.hasDelegate, field)
                XCTAssertEqual(limits.retainedConnectionCount, baseline + 1, field)
                await pair.stop(start)
                XCTAssertEqual(limits.retainedConnectionCount, baseline, field)
                XCTAssertEqual(limits.outstandingWorkCount, 0, field)
                try await checkSibling()
            }
        }
        await sibling.stop(healthy)
    }

    func testFinalFinishedReservationSurvivesHeldPhysicalClose() async throws {
        var config = BridgeChannelLimits.Configuration()
        config.maximumPendingSendBytes = 40_000
        let limits = BridgeChannelLimits(configuration: config), pair = try V3GatePair(limits: limits)
        let start = try await pair.start()
        for step in 1...5 { try await pair.step(step) }; try await start.value
        let retained = try XCTUnwrap(pair.it.wire.last).count
        let barrier = V3Barrier(); pair.it.beforeClose = { await barrier.wait() }
        let closing = Task { await pair.i.close() }
        await barrier.reached()
        XCTAssertFalse(pair.i.canSendPeerData)
        XCTAssertEqual(limits.retainedConnectionCount, 2)
        // Borrow all remaining bytes from the healthy responder. The old M5 is
        // still charged even after authority has ended and close has started.
        try pair.r.session.acquireSend(bytes: config.maximumPendingSendBytes - retained)
        XCTAssertThrowsError(try pair.r.session.acquireSend(bytes: 1))
        await barrier.release(); await closing.value
        try pair.r.session.acquireSend(bytes: retained)
        pair.r.session.releaseSend(bytes: config.maximumPendingSendBytes)
        await pair.stop(start)
        XCTAssertEqual(limits.retainedConnectionCount, 0)
    }

    func testSuspendedSignerStormKeepsWorkUntilReturnAndRejectsLimitPlusOne() async throws {
        var config = BridgeChannelLimits.Configuration(); config.maximumOutstandingWork = 2
        let limits = BridgeChannelLimits(configuration: config)
        var blocked: [(V3GatePair, V3Barrier, Task<Void, Error>, Task<Void, Error>)] = []
        for _ in 0..<2 {
            let pair = try V3GatePair(limits: limits), barrier = V3Barrier()
            await pair.rv.setBarriers(sign: { await barrier.wait() })
            let start = try await pair.start(), pending = Task { try await pair.step(1) }
            await barrier.reached(); await pair.r.close(); await pair.i.close()
            blocked.append((pair, barrier, start, pending))
        }
        XCTAssertEqual(limits.outstandingWorkCount, 2)
        let retained = limits.retainedConnectionCount
        for _ in 0..<32 {
            let refused = try V3GatePair(limits: limits)
            do { try await refused.i.startPeer(); XCTFail("Unbounded signer work admitted") } catch {}
            XCTAssertEqual(refused.it.wire.count, 0)
            let calls = await refused.iv.signCount; XCTAssertEqual(calls, 0)
            await refused.i.close(); await refused.r.close()
            XCTAssertEqual(limits.outstandingWorkCount, 2)
            XCTAssertEqual(limits.retainedConnectionCount, retained)
        }
        for (pair, barrier, start, pending) in blocked {
            await barrier.release(); _ = try? await pending.value; await pair.stop(start)
            XCTAssertEqual(pair.rt.wire.count, 0)
        }
        XCTAssertEqual(limits.outstandingWorkCount, 0); XCTAssertEqual(limits.retainedConnectionCount, 0)
        let fresh = try V3GatePair(limits: limits), start = try await fresh.start()
        for step in 1...5 { try await fresh.step(step) }; try await start.value
        XCTAssertTrue(fresh.i.canSendPeerData); await fresh.stop(start)
    }

    func testSuspendedPolicySendAndFactoryExpireForBothRolesWithoutLatePublication() async throws {
        for role in [P.Role.initiator, .responder] {
            for stage in ["policy", "send", "factory"] {
                let barrier = V3Barrier()
                let pair = try V3GatePair(factoryBarrier: stage == "factory" ? barrier : nil, factoryRole: role,
                    responderRecheck: { _ in if stage == "policy" && role == .responder { await barrier.wait() } },
                    recheck: { _ in if stage == "policy" && role == .initiator { await barrier.wait() } })
                let physical = role == .initiator ? pair.it : pair.rt, gate = role == .initiator ? pair.i : pair.r
                let heldStep = stage == "factory" ? (role == .initiator ? 4 : 5) : (role == .initiator ? 2 : 3)
                if stage == "send" {
                    physical.beforeSubmission = { data in
                        let command = try? P.decodeEnvelope(data).cmd
                        if command == (role == .initiator ? .initiatorAuth : .responderFinished) { await barrier.wait() }
                    }
                }
                let start = try await pair.start()
                for step in 1..<heldStep { try await pair.step(step) }
                let pending = Task { try await pair.step(heldStep) }
                await barrier.reached()
                let before = physical.wire.count
                pair.clock.advance(wall: stage == "factory" ? 301 : 31, mono: stage == "factory" ? 301 : 11)
                await barrier.release()
                do { try await pending.value; XCTFail("Expired \(role)/\(stage) continued") } catch {}
                XCTAssertFalse(gate.canSendPeerData); XCTAssertFalse(gate.hasDelegate)
                XCTAssertEqual(physical.wire.count, before)
                if stage == "factory" { XCTAssertEqual((role == .initiator ? pair.id : pair.rd).counts.close, 1) }
                await pair.stop(start); XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
            }
        }
    }
}

#if os(macOS)
@testable import CellApple
extension BridgePeerV3Tests {
    func testScannerStopDisconnectAndOwnerCloseDiscardSuspendedSignerInBothRoles() async throws {
        for initiator in [true, false] {
            for existence in [true, false] {
                for reason in ["stop", "disconnect", "ownerClose"] {
                    let v = try Self.vectors(), barrier = V3Barrier(), suffix = UUID().uuidString
                    let identity = try A.decode(A.PublicIdentity.self, from: v[initiator ? "identity0" : "identity1"]!)
                    let vault = try V3Vault(identity: identity, seed: v[initiator ? "seed0" : "seed1"]!)
                    let owner = identity.makeIdentity(); owner.identityVault = vault
                    let pair = try await ScannerPair(ownerA: initiator ? owner : nil, ownerB: initiator ? nil : owner, sessionSuffix: suffix)
                    if existence { await vault.setBarriers(exist: { await barrier.wait() }) }
                    else { await vault.setBarriers(sign: { await barrier.wait() }) }
                    let tasks = pair.start()
                    if initiator { try await pair.deliverNext() }
                    let pending = Task { try await pair.deliverNext() }
                    await barrier.reached()
                    let service = initiator ? pair.a : pair.b, physical = initiator ? pair.pa : pair.pb
                    let sent = pair.wire.history.count
                    switch reason {
                    case "stop": service.stop()
                    case "disconnect": service.session(physical.mcSession, peer: physical.peerID, didChange: .notConnected)
                    default: await physical.gate.close() // explicit local-owner revocation contract
                    }
                    await physical.gate.close()
                    XCTAssertGreaterThan(service.channelLimits.outstandingWorkCount, 0)
                    let fresh = try await ScannerPair(ownerA: pair.a.owner, ownerB: pair.b.owner, sessionSuffix: suffix)
                    // Reusing the same local vault would deliberately suspend
                    // the new signer too. Clear only future barriers; the old
                    // invocation has already captured its non-cancellable wait.
                    await vault.setBarriers()
                    try await fresh.finish(fresh.start())
                    await barrier.release()
                    do { try await pending.value; XCTFail("Retired Scanner signer continued") } catch {}
                    XCTAssertEqual(pair.wire.history.count, sent)
                    let count = await vault.signCount
                    XCTAssertEqual(count, existence ? 1 : 2, "Only the fresh channel may sign after retirement")
                    XCTAssertTrue(fresh.pa.gate.canSendPeerData); XCTAssertTrue(fresh.pb.gate.canSendPeerData)
                    pair.stop(); fresh.stop()
                    await pair.pa.gate.close(); await pair.pb.gate.close()
                    _ = try? await tasks.0.value; _ = try? await tasks.1.value
                }
            }
        }
    }
}
#endif

extension BridgePeerV3Tests {
    func testPeerFeedPreservesOrderDrainsCompletionAndSynchronousPublisher() async throws {
        let owner = await MockIdentityVault().identity(for: "feed", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        let cell = await BridgeOrderingFeedCell(owner: owner)
        let pair = try V3GatePair(factoryRole: .responder, factory: { transport, _ in
            try await bridge.setTransport(transport, connection: .outbound)
            bridge.emitCellAtEndpoint = cell
            return bridge
        })
        let startup = try await pair.start()
        for n in 1...5 { try await pair.step(n) }
        try await startup.value
        let handshakeFrames = pair.rt.wire.count
        pair.rt.beforeSubmission = { data in
            try await probe.submit(JSONDecoder().decode(BridgeCommand.self, from: data))
        }
        try await exerciseOrderedFeed(bridge: bridge, cell: cell, requester: pair.io, probe: probe) { command in
            try await pair.i.sendData(A.encode(command))
            try await pair.rt.receive(XCTUnwrap(pair.it.wire.last))
        }
        // Open actual records in send order: AEAD ordering must preserve the
        // publisher order, including both synchronous final values.
        var values: [String] = []
        for data in pair.rt.wire.all.dropFirst(handshakeFrames) {
            let plain = try pair.i.openPeerFrame(data)
            if let command = try? JSONDecoder().decode(BridgeCommand.self, from: plain),
               case let .flowElement(value) = command.payload { values.append(value.title ?? "") }
        }
        XCTAssertEqual(values, ["1", "2", "1", "2"])
        await pair.stop(startup)
        XCTAssertEqual(pair.limits.retainedConnectionCount, 0)
    }

    func testPeerSetAndDescriptionOwnCIDAndPreserveImmediateRepliesAndTimeoutIsolation() async throws {
        let owner = await MockIdentityVault().identity(for: "rpc", makeNewIfNotFound: true)!
        let bridge = BridgeBase(owner: owner), probe = BridgeOrderingProbe()
        let pair = try V3GatePair(factoryRole: .initiator, factory: { transport, _ in
            try await bridge.setTransport(transport, connection: .outbound)
            return bridge
        })
        let startup = try await pair.start()
        for n in 1...5 { try await pair.step(n) }
        try await startup.value
        pair.it.beforeSubmission = { data in
            if let command = try? JSONDecoder().decode(BridgeCommand.self, from: data) { try await probe.submit(command) }
        }
        try await exerciseRPCOwnership(bridge: bridge, requester: pair.io, probe: probe) { command in
            // Real encrypted peer response arrives before the request's physical
            // submission returns. No ready exception or synthetic session.
            try await pair.r.sendData(A.encode(command))
            try await pair.it.receive(XCTUnwrap(pair.rt.wire.last))
        }
        await pair.stop(startup)
    }
}
