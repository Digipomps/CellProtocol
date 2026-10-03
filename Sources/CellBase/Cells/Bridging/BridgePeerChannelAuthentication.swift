// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import Crypto

/// SIGMA-I based peer admission. See Documentation/BridgePeerChannelV3.md.
/// Key control admits one channel; it grants no Cell authority.
public enum BridgePeerChannelAuthentication {
    public typealias Auth = BridgeChannelAuthentication
    public static let profile = "org.haven.bridge-peer-channel.v3"
    public enum Role: String, Codable, Sendable {
        case initiator, responder
        var opposite: Self { self == .initiator ? .responder : .initiator }
        var direction: String { self == .initiator ? "initiator-to-responder" : "responder-to-initiator" }
    }
    public struct Endpoint: Codable, Equatable, Sendable {
        public let initiator: String
        public let responder: String
        public let setupID: String
        public let domain: String
        public init(initiator: String, responder: String, setupID: String, domain: String) throws {
            self.initiator = initiator; self.responder = responder; self.setupID = setupID; self.domain = domain
            try validate()
        }
        func validate() throws {
            guard !initiator.isEmpty, !responder.isEmpty, initiator != responder,
                  initiator.utf8.count <= 512, responder.utf8.count <= 512,
                  canonicalUUID(setupID), !domain.isEmpty, domain.utf8.count <= 512 else { throw Auth.Failure.malformed }
        }
        var audience: String { profile + ":" + Auth.digest(try! Auth.encode(self)) }
    }
    /// Hosts must explicitly accept the responder disclosure asymmetry. Expected
    /// descriptors bind UUID AND key AND domain; discovery labels are not pins.
    public enum DisclosurePolicy: Sendable {
        case anyProvenIdentity(allowUnauthenticatedInitiator: Bool)
        case expectedIdentities(domain: String, identities: [Auth.PublicIdentity], allowUnauthenticatedInitiator: Bool)
        func check(_ identity: Auth.PublicIdentity?, endpoint: Endpoint, role: Role) throws {
            let allow: Bool
            switch self {
            case .anyProvenIdentity(let value): allow = value
            case .expectedIdentities(let domain, let identities, let value):
                allow = value
                guard domain == endpoint.domain, !identities.isEmpty else { throw Auth.Failure.identityMismatch }
                if let identity { guard identities.contains(identity) else { throw Auth.Failure.identityMismatch } }
            }
            if role == .responder && identity == nil && !allow { throw Auth.Failure.identityMismatch }
        }
    }
    public struct Hello: Codable, Equatable, Sendable {
        public let profile: String
        public let role: Role
        public let ephemeralPublicKey: Data
        public let nonce: Data
        public let generation: String
        public let issuedAtMilliseconds: Int64
    }
    struct Descriptor: Codable, Sendable {
        let profile: String
        let signer: Role
        let helloDigest: String
        let previousDigest: String?
        let endpoint: Endpoint
        let identity: Auth.PublicIdentity
        let peerIdentity: Auth.PublicIdentity?
    }
    // Locally reconstructed only; never decoded as authority from the wire.
    struct Challenge: Sendable {
        let endpoint: Endpoint
        let identity: Auth.PublicIdentity
        let generation: String
        let signingData: Data
        let digest: String
        let issued: Int64
        var sessionID: String { endpoint.setupID }
    }
    struct Core: Codable, Sendable {
        let endpoint: Endpoint
        let identity: Auth.PublicIdentity
        let proof: Auth.Proof
    }
    struct Authentication: Codable, Sendable {
        let endpoint: Endpoint
        let identity: Auth.PublicIdentity
        let proof: Auth.Proof
        let identityMAC: Data
        var core: Core { Core(endpoint: endpoint, identity: identity, proof: proof) }
    }
    struct ResponderAuth: Codable, Sendable { let hello: Hello; let sealed: Data }
    struct Sealed: Codable, Sendable { let profile: String; let sealed: Data }
    struct Finished: Codable, Sendable { let ack: Auth.Authenticated; let verifyData: Data }
    enum Message: String, Codable {
        case hello = "channelAuthPeerV3Hello"
        case responderAuth = "channelAuthPeerV3ResponderAuth"
        case initiatorAuth = "channelAuthPeerV3InitiatorAuth"
        case responderFinished = "channelAuthPeerV3ResponderFinished"
        case initiatorFinished = "channelAuthPeerV3InitiatorFinished"
    }
    struct Envelope: Codable {
        let body: String
        let cid: Int
        let cmd: Message
        enum CodingKeys: String, CodingKey { case body = "&string", cid, cmd }
    }
    static func envelope<T: Encodable>(_ name: Message, _ body: T) throws -> Data {
        let data = try Auth.encode(Envelope(body: String(decoding: Auth.encode(body), as: UTF8.self), cid: 0, cmd: name))
        guard data.count <= (name == .hello ? 2048 : Auth.maximumEnvelopeBytes) else { throw Auth.Failure.capacity }
        return data
    }
    static func decodeEnvelope(_ bytes: Data) throws -> Envelope {
        let value = try Auth.decode(Envelope.self, from: bytes)
        guard value.cid == 0, value.cmd != .hello || bytes.count <= 2048 else { throw Auth.Failure.malformed }
        return value
    }
    static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString == value && value.utf8.count == 36 }
    static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    static func framed(_ label: String, _ values: Data...) -> Data { framed(label, values: values) }
    static func framed(_ label: String, values: [Data]) -> Data {
        func lp(_ data: Data) -> Data { integer(UInt32(data.count)) + data }
        return lp(Data(profile.utf8)) + lp(Data(label.utf8)) + integer(UInt32(values.count)) + values.reduce(Data()) { $0 + lp($1) }
    }
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func pad<T: Encodable>(_ value: T, size: Int) throws -> Data {
        let json = try Auth.encode(value)
        guard !json.isEmpty, json.count <= size - 4 else { throw Auth.Failure.capacity }
        return integer(UInt32(json.count)) + json + Data(repeating: 0, count: size - 4 - json.count)
    }
    static func unpad<T: Codable>(_ type: T.Type, _ bytes: Data, size: Int) throws -> T {
        guard bytes.count == size else { throw Auth.Failure.malformed }
        let count = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= size - 4, bytes.dropFirst(4 + count).allSatisfy({ $0 == 0 }) else { throw Auth.Failure.malformed }
        return try Auth.decode(type, from: Data(bytes.dropFirst(4).prefix(count)))
    }
    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        try .init(data: Data(repeating: 0, count: 4) + integer(counter))
    }
    static func extract(_ privateKey: Curve25519.KeyAgreement.PrivateKey, remote: Data, salt: Data) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: remote))
        guard secret.withUnsafeBytes({ $0.reduce(UInt8(0)) { $0 | $1 } }) != 0 else { throw Auth.Failure.invalidProof }
        return secret.withUnsafeBytes { bytes in
            SymmetricKey(data: HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: bytes), salt: salt))
        }
    }
    static func key(_ prk: SymmetricKey, _ label: String, _ role: Role, _ context: Data) -> SymmetricKey {
        HKDF<SHA256>.expand(pseudoRandomKey: prk,
            info: framed("kdf", Data(label.utf8), Data(role.direction.utf8), context, integer(UInt16(32))), outputByteCount: 32)
    }
    static func mac(_ key: SymmetricKey, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: key)) }
    static func verifyMAC(_ value: Data, key: SymmetricKey, data: Data) throws {
        guard value.count == 32, HMAC<SHA256>.isValidAuthenticationCode(value, authenticating: data, using: key) else { throw Auth.Failure.invalidProof }
    }
    static func challenge(endpoint: Endpoint, identity: Auth.PublicIdentity, signer: Role,
                          local: Hello, remote: Hello, t0: Data, t2: Data?, responder: Auth.PublicIdentity?) throws -> Challenge {
        let descriptor = Descriptor(profile: profile, signer: signer, helloDigest: hex(t0),
            previousDigest: signer == .initiator ? t2.map(hex) : nil, endpoint: endpoint, identity: identity,
            peerIdentity: signer == .initiator ? responder : nil)
        guard signer != .initiator || (t2 != nil && responder != nil) else { throw Auth.Failure.unexpectedMessage }
        let digest = Auth.digest(try Auth.encode(descriptor)), verifier = local.role == signer ? remote : local
        let issued = min(local.issuedAtMilliseconds, remote.issuedAtMilliseconds)
        let signing = IdentitySigningChallenge(identityUUID: identity.uuid,
            publicKeyFingerprint: identity.makeIdentity().signingPublicKeyFingerprint, domain: endpoint.domain,
            resource: profile + ":" + digest, action: "openPeerBridgeChannel", audience: endpoint.audience,
            nonce: verifier.nonce, issuedAt: Date(timeIntervalSince1970: Double(issued) / 1000), validity: Auth.challengeLifetime)
        return Challenge(endpoint: endpoint, identity: identity, generation: verifier.generation,
                         signingData: try Auth.encode(signing), digest: digest, issued: issued)
    }

    /// All transitions reserve their stage before any await. The gate's captured
    /// liveness check also observes direct session revocation during a vault call.
    actor Operation {
        enum State { case created, waitM1, waitM2, processing, waitM3, waitM4, waitM5, activating, complete, terminal }
        nonisolated let hello: Hello
        private let owner: Identity
        private let identity: Auth.PublicIdentity
        private let endpoint: Endpoint
        private let policy: DisclosurePolicy
        private let wallClock: @Sendable () -> Date
        private let monotonic: @Sendable () -> TimeInterval
        private let deadline: TimeInterval
        private var state: State
        private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
        private var prk: SymmetricKey?
        private var remote: Hello?
        private var remoteIdentity: Auth.PublicIdentity?
        private var t0: Data?, transcript: Data?, t2: Data?, t3: Data?
        private var outgoing: Challenge?, incoming: Challenge?
        private var signingStarted = false
        init(owner: Identity, endpoint: Endpoint, role: Role, generation: String, policy: DisclosurePolicy,
             wallClock: @escaping @Sendable () -> Date = { Date() },
             monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = Auth.randomNonce()) throws {
            try endpoint.validate()
            guard canonicalUUID(generation), nonce.count == 32 else { throw Auth.Failure.malformed }
            self.owner = owner.publicIdentitySnapshot(); self.owner.identityVault = owner.identityVault
            identity = try Auth.PublicIdentity(owner); self.endpoint = endpoint; self.policy = policy
            self.wallClock = wallClock; self.monotonic = monotonic; deadline = monotonic() + 10
            self.ephemeral = ephemeral; state = role == .initiator ? .created : .waitM1
            hello = Hello(profile: profile, role: role, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                          nonce: nonce, generation: generation, issuedAtMilliseconds: Auth.milliseconds(wallClock()))
        }
        private func check(_ live: @Sendable () throws -> Void) throws {
            try Task.checkCancellation(); try live()
            guard state != .terminal, state != .complete, monotonic() < deadline else { throw Auth.Failure.expired }
            let issued = min(hello.issuedAtMilliseconds, remote?.issuedAtMilliseconds ?? hello.issuedAtMilliseconds)
            guard wallClock().timeIntervalSince1970 < Double(issued) / 1000 + 30 else { throw Auth.Failure.expired }
        }
        func begin(live: @Sendable () throws -> Void) throws -> Data {
            try check(live)
            guard state == .created else { throw Auth.Failure.unexpectedMessage }
            let wire = try envelope(.hello, hello)
            transcript = hash(framed("wire-1", wire)); state = .waitM2
            return wire
        }
        private func prepare(_ value: Hello, first: Data) throws {
            let now = Auth.milliseconds(wallClock())
            // Saturating comparisons avoid arithmetic on attacker supplied Int64.
            let lower = now.subtractingReportingOverflow(10_000), upper = now.addingReportingOverflow(5_000)
            guard value.profile == profile, value.role == hello.role.opposite,
                  value.ephemeralPublicKey.count == 32, value.nonce.count == 32,
                  canonicalUUID(value.generation), value.generation != hello.generation,
                  value.issuedAtMilliseconds >= 0,
                  (lower.overflow || value.issuedAtMilliseconds > lower.partialValue),
                  (upper.overflow || value.issuedAtMilliseconds <= upper.partialValue),
                  let ephemeral else { throw Auth.Failure.invalidProof }
            defer { self.ephemeral = nil }
            remote = value
            let r = hello.role == .responder ? hello : value
            let context = hash(framed("clear-2", first, try Auth.encode(r)))
            t0 = context; transcript = context
            prk = try extract(ephemeral, remote: value.ephemeralPublicKey, salt: context)
        }
        private func context(for signer: Role, identity: Auth.PublicIdentity) throws -> Challenge {
            guard let remote, let t0 else { throw Auth.Failure.unexpectedMessage }
            return try challenge(endpoint: endpoint, identity: identity, signer: signer, local: hello, remote: remote,
                t0: t0, t2: t2, responder: hello.role == .responder ? self.identity : remoteIdentity)
        }
        private func key(_ label: String, _ role: Role, _ context: Data) throws -> SymmetricKey {
            guard let prk else { throw Auth.Failure.closed }
            return BridgePeerChannelAuthentication.key(prk, label, role, context)
        }
        private func seal<T: Encodable>(_ value: T, step: Int, context: Data, size: Int) throws -> Data {
            guard let t0 else { throw Auth.Failure.closed }
            let box = try ChaChaPoly.seal(pad(value, size: size), using: key("handshake-key", hello.role, t0),
                nonce: nonce(step >= 4 ? 1 : 0), authenticating: framed("handshake-aead", Data(String(step).utf8), context))
            return box.ciphertext + box.tag
        }
        private func open<T: Codable>(_ type: T.Type, sealed: Data, step: Int, context: Data, size: Int) throws -> T {
            guard sealed.count == size + 16, let t0 else { throw Auth.Failure.malformed }
            let box = try ChaChaPoly.SealedBox(nonce: nonce(step >= 4 ? 1 : 0), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try unpad(type, ChaChaPoly.open(box, using: key("handshake-key", hello.role.opposite, t0),
                authenticating: framed("handshake-aead", Data(String(step).utf8), context)), size: size)
        }
        private func sign(live: @Sendable () throws -> Void,
                          recheck: @Sendable () async throws -> Void) async throws -> Authentication {
            try check(live); try policy.check(remoteIdentity, endpoint: endpoint, role: hello.role)
            guard !signingStarted, let vault = owner.identityVault, !(vault is BridgeIdentityVault), let t0 else { throw Auth.Failure.invalidProof }
            let challenge = try context(for: hello.role, identity: identity)
            _ = try IdentitySigningChallenge.validateSigningData(challenge.signingData, for: owner, now: wallClock())
            outgoing = challenge; signingStarted = true
            let exists = await vault.identityExistInVault(owner)
            try check(live)
            guard exists else { throw Auth.Failure.identityMismatch }
            try await recheck(); try check(live)
            _ = try IdentitySigningChallenge.validateSigningData(challenge.signingData, for: owner, now: wallClock())
            let signature = try await vault.signMessageForIdentity(messageData: challenge.signingData, identity: owner)
            try check(live)
            try await recheck(); try check(live)
            _ = try IdentitySigningChallenge.validateSigningData(challenge.signingData, for: owner, now: wallClock())
            guard signature.count <= 256, IdentityPublicKeySignatureVerifier.verify(signature: signature,
                messageData: challenge.signingData, identity: owner) else { throw Auth.Failure.invalidProof }
            let core = Core(endpoint: endpoint, identity: identity,
                proof: .init(sessionID: endpoint.setupID, generation: challenge.generation, signature: signature))
            let context = hello.role == .responder ? t0 : t2!
            let identityMAC = mac(try key("identity-mac-key", hello.role, t0),
                framed("identity-mac", Data(hello.role.rawValue.utf8), context, try Auth.encode(core)))
            return Authentication(endpoint: core.endpoint, identity: identity, proof: core.proof, identityMAC: identityMAC)
        }
        private func verify(_ auth: Authentication, context: Data) throws -> Challenge {
            guard auth.endpoint == endpoint, auth.proof.sessionID == endpoint.setupID,
                  auth.proof.generation == hello.generation, let t0 else { throw Auth.Failure.invalidProof }
            try auth.identity.validate()
            try verifyMAC(auth.identityMAC, key: key("identity-mac-key", hello.role.opposite, t0),
                data: framed("identity-mac", Data(hello.role.opposite.rawValue.utf8), context, try Auth.encode(auth.core)))
            let challenge = try self.context(for: hello.role.opposite, identity: auth.identity)
            guard auth.proof.signature.count <= 256, IdentityPublicKeySignatureVerifier.verify(signature: auth.proof.signature,
                messageData: challenge.signingData, identity: auth.identity.makeIdentity()) else { throw Auth.Failure.invalidProof }
            incoming = challenge; remoteIdentity = auth.identity
            return challenge
        }
        private func finished(step: Int, context: Data) throws -> Finished {
            guard let incoming, let t3 else { throw Auth.Failure.unexpectedMessage }
            let ack = Auth.Authenticated(sessionID: endpoint.setupID, generation: hello.generation, transcriptDigest: incoming.digest)
            return Finished(ack: ack, verifyData: mac(try key("finished-key", hello.role, t3),
                framed("finished", Data(String(step).utf8), context, try Auth.encode(ack))))
        }
        private func verifyFinished(_ value: Finished, step: Int, context: Data) throws {
            guard let outgoing, let t3, value.ack.sessionID == outgoing.sessionID,
                  value.ack.generation == outgoing.generation, value.ack.transcriptDigest == outgoing.digest else { throw Auth.Failure.invalidProof }
            try verifyMAC(value.verifyData, key: key("finished-key", hello.role.opposite, t3),
                data: framed("finished", Data(String(step).utf8), context, try Auth.encode(value.ack)))
        }
        // Completion is returned only after both proofs, local Finished reception,
        // and (for I) successful submission of M5. No application-key export API.
        func receive(_ wire: Data, live: @Sendable () throws -> Void,
                     authenticate: @Sendable (Challenge, Auth.Proof) async throws -> Void,
                     recheck: @Sendable () async throws -> Void,
                     send: @Sendable (Data) async throws -> Void) async throws -> BridgePeerRecordLayer? {
            do {
                try check(live)
                let envelope = try decodeEnvelope(wire), body = Data(envelope.body.utf8)
                let previous = state; state = .processing
                switch (previous, envelope.cmd) {
                case (.waitM1, .hello):
                    let remote = try Auth.decode(Hello.self, from: body)
                    try prepare(remote, first: hash(framed("wire-1", wire)))
                    try await recheck(); try check(live)
                    let auth = try await sign(live: live, recheck: recheck)
                    let w2 = try BridgePeerChannelAuthentication.envelope(.responderAuth,
                        ResponderAuth(hello: hello, sealed: seal(auth, step: 2, context: t0!, size: 8192)))
                    transcript = hash(framed("wire-2", t0!, w2)); t2 = transcript; state = .waitM3
                    try await send(w2); try check(live)
                case (.waitM2, .responderAuth):
                    let offer = try Auth.decode(ResponderAuth.self, from: body)
                    try prepare(offer.hello, first: transcript!)
                    let auth = try open(Authentication.self, sealed: offer.sealed, step: 2, context: t0!, size: 8192)
                    let challenge = try verify(auth, context: t0!)
                    t2 = hash(framed("wire-2", t0!, wire)); transcript = t2
                    try await authenticate(challenge, auth.proof); try check(live)
                    try policy.check(auth.identity, endpoint: endpoint, role: hello.role)
                    try await recheck(); try check(live)
                    let own = try await sign(live: live, recheck: recheck)
                    let w3 = try BridgePeerChannelAuthentication.envelope(.initiatorAuth,
                        Sealed(profile: profile, sealed: seal(own, step: 3, context: t2!, size: 8192)))
                    transcript = hash(framed("wire-3", t2!, w3)); t3 = transcript; state = .waitM4
                    try await send(w3); try check(live)
                case (.waitM3, .initiatorAuth):
                    let offer = try Auth.decode(Sealed.self, from: body)
                    guard offer.profile == profile else { throw Auth.Failure.invalidProof }
                    let auth = try open(Authentication.self, sealed: offer.sealed, step: 3, context: t2!, size: 8192)
                    let challenge = try verify(auth, context: t2!)
                    try await authenticate(challenge, auth.proof); try check(live)
                    try policy.check(auth.identity, endpoint: endpoint, role: hello.role)
                    try await recheck(); try check(live)
                    transcript = hash(framed("wire-3", t2!, wire)); t3 = transcript
                    let w4 = try BridgePeerChannelAuthentication.envelope(.responderFinished,
                        Sealed(profile: profile, sealed: seal(finished(step: 4, context: t3!), step: 4, context: t3!, size: 1024)))
                    transcript = hash(framed("wire-4", t3!, w4)); state = .waitM5
                    try await send(w4); try check(live)
                case (.waitM4, .responderFinished), (.waitM5, .initiatorFinished):
                    let step = hello.role == .initiator ? 4 : 5
                    let offer = try Auth.decode(Sealed.self, from: body)
                    guard offer.profile == profile else { throw Auth.Failure.invalidProof }
                    let value = try open(Finished.self, sealed: offer.sealed, step: step, context: transcript!, size: 1024)
                    try verifyFinished(value, step: step, context: transcript!)
                    transcript = hash(framed("wire-\(step)", transcript!, wire))
                    try await recheck(); try check(live)
                    state = .activating
                    if step == 4 {
                        let w5 = try BridgePeerChannelAuthentication.envelope(.initiatorFinished,
                            Sealed(profile: profile, sealed: seal(finished(step: 5, context: transcript!), step: 5, context: transcript!, size: 1024)))
                        try await send(w5); try check(live)
                        transcript = hash(framed("wire-5", transcript!, w5))
                    }
                    let records = try BridgePeerRecordLayer(local: hello, remote: remote!,
                        sendKey: key("application-key", hello.role, transcript!),
                        receiveKey: key("application-key", hello.role.opposite, transcript!))
                    state = .complete; clear()
                    return records
                default: throw Auth.Failure.unexpectedMessage
                }
                return nil
            } catch { cancel(); throw error }
        }
        private func clear() {
            ephemeral = nil; prk = nil; t0 = nil; t2 = nil; t3 = nil; transcript = nil
            outgoing = nil; incoming = nil; remoteIdentity = nil
        }
        func cancel() { state = .terminal; clear() }
    }
}
