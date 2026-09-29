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
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(role == .initiator ? alice : bob))
        return P.Hello(profile: P.profile,
            role: role, ephemeralPublicKey: key ?? privateKey.publicKey.rawRepresentation,
            nonce: Data(repeating: role == .initiator ? 0x11 : 0x22, count: 32),
            generation: role == .initiator ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222",
            issuedAtMilliseconds: role == .initiator ? 1_800_000_000_000 : 1_800_000_000_001)
    }
    private func layers() throws -> (BridgePeerRecordLayer, BridgePeerRecordLayer) {
        let a = try hello(.initiator), b = try hello(.responder)
        let v = try BridgePeerV3Tests.vectors()
        let forward = SymmetricKey(data: v["application-key0"]!), reverse = SymmetricKey(data: v["application-key1"]!)
        return (try BridgePeerRecordLayer(local: a, remote: b, sendKey: forward, receiveKey: reverse),
                try BridgePeerRecordLayer(local: b, remote: a, sendKey: reverse, receiveKey: forward))
    }

    func testRFC7748AndIndependentHKDFAndRecordVectors() throws {
        let b = try hello(.responder)
        let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(alice))
            .sharedSecretFromKeyAgreement(with: .init(rawRepresentation: b.ephemeralPublicKey))
        XCTAssertEqual(secret.withUnsafeBytes { Data($0) }, bytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"))
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0x0b, count: 22)),
            salt: bytes("000102030405060708090a0b0c"))
        XCTAssertEqual(Data(prk), bytes("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: bytes("f0f1f2f3f4f5f6f7f8f9"), outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Data($0) }, bytes("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
        let (i, r) = try layers(), v = try BridgePeerV3Tests.vectors()
        for counter in 0...1 {
            let message = Data((counter == 0 ? "N22 vector" : "N22 secret").utf8)
            let forward = try i.seal(message), reverse = try r.seal(message)
            XCTAssertEqual(forward, v["record0\(counter)"])
            XCTAssertEqual(reverse, v["record1\(counter)"])
            XCTAssertEqual(try r.open(forward), message); XCTAssertEqual(try i.open(reverse), message)
        }
    }

    func testSmallOrderPublicKeysAreRejected() throws {
        let smallOrder = [Data(repeating: 0, count: 32), Data([1]) + Data(repeating: 0, count: 31)]
            + [UInt8(0xec), 0xed, 0xee].map { Data([$0]) + Data(repeating: 0xff, count: 30) + Data([0x7f]) }
        for point in smallOrder {
            XCTAssertThrowsError(try P.extract(.init(rawRepresentation: bytes(alice)), remote: point, salt: Data(repeating: 1, count: 32)))
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
