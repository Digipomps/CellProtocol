import Foundation
import XCTest
import Crypto
@testable import CellBase

final class BridgePeerV3Tests: XCTestCase {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    static func vectors() throws -> [String: Data] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PeerV3/vectors.json")
        return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
    }
    func testIndependentFullHandshakeAndAllKeyPurposes() async throws {
        let v = try Self.vectors()
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
    var count: Int { lock.withLock { values.count } }
    func append(_ data: Data) throws { lock.withLock { values.append(data) } }
}
actor V3Vault: IdentityVaultProtocol {
    let descriptor: BridgeChannelAuthentication.PublicIdentity
    let key: Curve25519.Signing.PrivateKey
    let fixed: (Data, Data)?
    private(set) var signCount = 0
    private(set) var signedBytes: Data?
    var beforeExist: (@Sendable () async -> Void)?
    var beforeSign: (@Sendable () async -> Void)?
    init(identity: BridgeChannelAuthentication.PublicIdentity, seed: Data, fixed: (Data, Data)? = nil) throws {
        descriptor = identity; key = try .init(rawRepresentation: seed); self.fixed = fixed
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
            guard messageData == fixed.0, key.publicKey.isValidSignature(fixed.1, for: messageData) else {
                throw BridgeChannelAuthentication.Failure.invalidProof
            }
            return fixed.1
        }
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
    func setDelegate(_ delegate: BridgeDelegateProtocol) { gate = delegate as? BridgeChannelTransport }
    func setup(_ endpointURL: URL, identity: Identity) async throws {}
    func sendData(_ data: Data) async throws { try gate!.submitPeerFrame(data) { try wire.append($0) } }
    func identityVault(for: Identity?) async -> IdentityVaultProtocol { BridgeIdentityVault() }
    static func new() -> BridgeTransportProtocol { V3Transport() }
    func receive(_ data: Data) async throws {
        do {
            let plain = try gate!.openPeerFrame(data)
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
         limits: BridgeChannelLimits = .init(), factoryBarrier: V3Barrier? = nil,
         recheck: @escaping @Sendable (A.PublicIdentity) async throws -> Void = { _ in }) throws {
        self.limits = limits
        let v = try BridgePeerV3Tests.vectors()
        let ide = try A.decode(A.PublicIdentity.self, from: v["identity0"]!)
        let rde = try A.decode(A.PublicIdentity.self, from: v["identity1"]!)
        iv = try .init(identity: ide, seed: v["seed0"]!); rv = try .init(identity: rde, seed: v["seed1"]!)
        io = ide.makeIdentity(); ro = rde.makeIdentity(); io.identityVault = iv; ro.identityVault = rv
        let endpoint = try P.Endpoint(initiator: "I", responder: "R", setupID: UUID().uuidString, domain: "nearby")
        i = try BridgeChannelTransport(underlying: it, peerEndpoint: endpoint, role: .initiator, owner: io,
            limits: limits, source: UUID().uuidString, disclosurePolicy: policy ?? .anyProvenIdentity(allowUnauthenticatedInitiator: true),
            recheckPolicy: recheck, wallClock: clock.date, monotonic: clock.uptime) { [id] gate, _ in
                id.created(); gate.setDelegate(id)
                await factoryBarrier?.wait()
                return id
            }
        r = try BridgeChannelTransport(underlying: rt, peerEndpoint: endpoint, role: .responder, owner: ro,
            limits: limits, source: UUID().uuidString, disclosurePolicy: responderPolicy ?? .anyProvenIdentity(allowUnauthenticatedInitiator: true),
            wallClock: clock.date, monotonic: clock.uptime) { [rd] gate, _ in rd.created(); gate.setDelegate(rd); return rd }
    }
    func start() async throws -> Task<Void, Error> {
        let task = Task { try await i.startPeer() }
        for _ in 0..<1000 { if it.wire.last != nil { return task }; await Task.yield() }
        throw A.Failure.unavailable
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
        let barrier = V3Barrier(), pair = try V3GatePair(factoryBarrier: barrier)
        let task = try await pair.start()
        for step in 1...3 { try await pair.step(step) }
        let pending = Task { try await pair.step(4) }
        await barrier.reached()
        await pair.i.close()
        XCTAssertFalse(pair.i.canSendPeerData)
        XCTAssertEqual(pair.id.counts.close, 0, "Provisional delegate is owned by the factory")
        await barrier.release()
        do { try await pending.value; XCTFail() } catch {}
        XCTAssertEqual(pair.id.counts.close, 1)
        XCTAssertFalse(pair.i.canSendPeerData)
        await pair.stop(task)
        XCTAssertEqual(pair.id.counts.close, 1)
        XCTAssertEqual(pair.limits.outstandingWorkCount, 0)
    }
}
