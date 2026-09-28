// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors
import Foundation
import Crypto

/// Connection-owned record state, accessed under the gate lock. Not Codable,
/// copyable, or reusable across handshakes. Crypto primitives come from Crypto.
final class BridgePeerRecordLayer {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication
    static let overhead = 4 + 36 + 1 + 8 + 16
    static let maximumPlaintext = BridgeInboundPayloadValidator.defaultMaximumBytes
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private let sendPrefix: Data
    private let receivePrefix: Data
    var nextSend: UInt64 = 0
    var nextReceive: UInt64 = 0

    init(local: P.Hello, remote: P.Hello, privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        guard local.ephemeralPublicKey == privateKey.publicKey.rawRepresentation,
              local.role != remote.role, local.endpoint == remote.endpoint,
              local.profile == P.profile, remote.profile == P.profile,
              local.generation.utf8.count == 36, remote.generation.utf8.count == 36 else { throw A.Failure.invalidProof }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.ephemeralPublicKey))
        // Providers normally reject small-order points themselves; also reject
        // any all-zero result, without an early-exit comparison (RFC 7748 §6.1).
        guard secret.withUnsafeBytes({ $0.reduce(UInt8(0)) { $0 | $1 } }) != 0 else { throw A.Failure.invalidProof }
        let transcripts = try [P.Role.initiator, .responder].map { try P.challenge(local: local, remote: remote, signer: $0).transcript }
        let salt = Data(SHA256.hash(data: try A.encode(transcripts)))
        func key(_ direction: P.Role) -> SymmetricKey {
            let name = direction == .initiator ? "initiator-to-responder" : "responder-to-initiator"
            return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                sharedInfo: Data((P.profile + "\0key\0" + name).utf8), outputByteCount: 32)
        }
        sendKey = key(local.role); receiveKey = key(remote.role)
        sendPrefix = Self.prefix(generation: local.generation, role: local.role)
        receivePrefix = Self.prefix(generation: remote.generation, role: remote.role)
    }

    private static func prefix(generation: String, role: P.Role) -> Data {
        Data("HPC2".utf8) + Data(generation.utf8) + Data([role == .initiator ? 0 : 1])
    }
    private static func counter(_ value: UInt64) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
    private static func nonce(_ value: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + counter(value))
    }
    private static func aad(_ header: Data) -> Data { Data((P.profile + "\0record\0").utf8) + header }

    func seal(_ plaintext: Data) throws -> Data {
        do {
            guard let sendKey else { throw A.Failure.closed }
            guard !plaintext.isEmpty, plaintext.count <= Self.maximumPlaintext,
                  nextSend < UInt64.max else { throw A.Failure.capacity }
            let header = sendPrefix + Self.counter(nextSend)
            let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(nextSend), authenticating: Self.aad(header))
            nextSend += 1
            return header + box.ciphertext + box.tag
        } catch { close(); throw error }
    }

    func open(_ record: Data) throws -> Data {
        do {
            guard let receiveKey else { throw A.Failure.closed }
            guard record.count > Self.overhead, record.count <= Self.maximumPlaintext + Self.overhead,
                  nextReceive < UInt64.max else { throw A.Failure.malformed }
            let header = receivePrefix + Self.counter(nextReceive)
            // Exact prefix also rejects reflection, generations, gaps and replay.
            guard record.prefix(header.count) == header else { throw A.Failure.invalidProof }
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(nextReceive),
                ciphertext: record.dropFirst(header.count).dropLast(16), tag: record.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: Self.aad(header))
            nextReceive += 1
            return plaintext
        } catch { close(); throw error }
    }

    func close() { sendKey = nil; receiveKey = nil }
}
