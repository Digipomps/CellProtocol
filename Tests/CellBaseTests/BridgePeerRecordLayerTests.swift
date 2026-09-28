import Foundation
import XCTest
import Crypto
@testable import CellBase

final class BridgePeerRecordLayerTests: XCTestCase {
    typealias P = BridgePeerChannelAuthentication
    typealias A = BridgeChannelAuthentication

    // RFC 7748 §6.1 Alice/Bob key-agreement example; all keys here are public
    // test fixtures. The profile outputs were independently computed with
    // Python hashlib/hmac and the installed OpenSSL EVP ChaCha20-Poly1305.
    private let alice = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    private let bob = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }
    private func hello(_ role: P.Role, key: Data? = nil) throws -> P.Hello {
        let identity = Identity(role == .initiator ? "vector-a" : "vector-b", displayName: "", identityVault: nil)
        identity.publicSecureKey = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false,
            use: .signature, algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil,
            compressedKey: bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(role == .initiator ? alice : bob))
        return P.Hello(profile: P.profile,
            endpoint: try P.Endpoint(initiator: "vector-a", responder: "vector-b", setupID: "33333333-3333-4333-8333-333333333333", domain: "nearby"),
            role: role, identity: try A.PublicIdentity(identity), ephemeralPublicKey: key ?? privateKey.publicKey.rawRepresentation,
            nonce: Data(repeating: role == .initiator ? 0x11 : 0x22, count: 32),
            generation: role == .initiator ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222",
            issuedAtMilliseconds: role == .initiator ? 1_800_000_000_000 : 1_800_000_000_001)
    }
    private func layers() throws -> (BridgePeerRecordLayer, BridgePeerRecordLayer) {
        let a = try hello(.initiator), b = try hello(.responder)
        return (try BridgePeerRecordLayer(local: a, remote: b, privateKey: .init(rawRepresentation: bytes(alice))),
                try BridgePeerRecordLayer(local: b, remote: a, privateKey: .init(rawRepresentation: bytes(bob))))
    }

    func testRFC7748AndIndependentHKDFAndRecordVectors() throws {
        let a = try hello(.initiator), b = try hello(.responder)
        let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(alice))
            .sharedSecretFromKeyAgreement(with: .init(rawRepresentation: b.ephemeralPublicKey))
        XCTAssertEqual(secret.withUnsafeBytes { Data($0) }, bytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"))
        let transcripts = try [P.Role.initiator, .responder].map { try P.challenge(local: a, remote: b, signer: $0).transcript }
        let salt = Data(SHA256.hash(data: try A.encode(transcripts)))
        XCTAssertEqual(salt, bytes("772640ff1898a4ffdecaceeedafd79be9d2f4d6696ff879f60b7b189f1bfb138"))
        let vectors = [
            ("initiator-to-responder", "f198c746bac283a10f266e864a601f76cebf8f7fe873288add8a52b84b5ea147"),
            ("responder-to-initiator", "e152f4b63be5ce535afaffa5dd687bcb398ae527d6575b5b25ef55315e180d5f")
        ]
        for (direction, expected) in vectors {
            let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                sharedInfo: Data((P.profile + "\0key\0" + direction).utf8), outputByteCount: 32)
            XCTAssertEqual(key.withUnsafeBytes { Data($0) }, bytes(expected))
        }
        let (initiator, responder) = try layers(), message = Data("N07 vector".utf8)
        let forward = [
            "4850433231313131313131312d313131312d343131312d383131312d3131313131313131313131310000000000000000003e3e7079c170a1bd60bb235bd3d064d1f2598b3da55eb6a9c7d4",
            "4850433231313131313131312d313131312d343131312d383131312d31313131313131313131313100000000000000000113f0d430b5ddc6b1506f1a0601a43ed2d6b717dcbb05ac32bee1"
        ]
        let reverse = [
            "4850433232323232323232322d323232322d343232322d383232322d3232323232323232323232320100000000000000008580511d920b8fb112080f87f2d218668718720b989fef4017e4",
            "4850433232323232323232322d323232322d343232322d383232322d3232323232323232323232320100000000000000011c0481ba8ee921886c5487a67c62f3516123a5b67c906797bc28"
        ]
        for index in 0..<2 {
            let sent = try initiator.seal(message), reply = try responder.seal(message)
            XCTAssertEqual(sent, bytes(forward[index])); XCTAssertEqual(reply, bytes(reverse[index]))
            XCTAssertEqual(try responder.open(sent), message); XCTAssertEqual(try initiator.open(reply), message)
        }
    }

    func testSmallOrderPublicKeysAreRejected() throws {
        let a = try hello(.initiator)
        let smallOrder = [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31)]
            + [UInt8(0xec), 0xed, 0xee].map { Data([$0]) + Data(repeating: 0xff, count: 30) + Data([0x7f]) }
        for point in smallOrder {
            XCTAssertThrowsError(try BridgePeerRecordLayer(local: a, remote: hello(.responder, key: point),
                privateKey: .init(rawRepresentation: bytes(alice))))
        }
    }

    func testCounterExhaustionClosesBeforeWrapInBothDirections() throws {
        let (a, b) = try layers()
        a.nextSend = UInt64.max - 1; b.nextReceive = UInt64.max - 1
        XCTAssertEqual(try b.open(a.seal(Data([1]))), Data([1]))
        XCTAssertEqual(a.nextSend, UInt64.max); XCTAssertEqual(b.nextReceive, UInt64.max)
        XCTAssertThrowsError(try a.seal(Data([2])))
        XCTAssertThrowsError(try b.open(Data(repeating: 0, count: 66)))
        a.nextSend = 0; b.nextReceive = 0 // failure destroyed both keys; cannot reset/reopen
        XCTAssertThrowsError(try a.seal(Data([3])))
        XCTAssertThrowsError(try b.seal(Data([3])))
    }

    func testExactFrameBoundsAndFailureAreTerminal() throws {
        let maximum = BridgePeerRecordLayer.maximumPlaintext
        let (a, b) = try layers(), plaintext = Data(repeating: 0x55, count: maximum)
        let frame = try a.seal(plaintext)
        XCTAssertEqual(frame.count, maximum + BridgePeerRecordLayer.overhead)
        XCTAssertEqual(try b.open(frame), plaintext)
        XCTAssertThrowsError(try a.seal(Data(repeating: 1, count: maximum + 1)))
        XCTAssertThrowsError(try a.seal(Data([1])))
        let (c, _) = try layers()
        XCTAssertThrowsError(try c.seal(Data()))
        XCTAssertThrowsError(try c.seal(Data([1])))
    }
}
