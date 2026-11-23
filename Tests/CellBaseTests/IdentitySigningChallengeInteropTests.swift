// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  IdentitySigningChallengeInteropTests.swift
//
//  Groundwork for testing the Swift bridge server against the Kotlin client.
//  A client written from the documented rule, without IdentitySigningChallenge,
//  JSONEncoder or the bridge types, builds the bytes it signs for
//  `org.haven.bridge-channel.v1`. The Swift server must accept the result.
//
//  The rule (fixtures/interop/v1/README.md, "Bridge channel admission"):
//  - transcript: sorted keys (code-point order), `/` NOT escaped, Data as base64
//  - resource = "org.haven.bridge-channel.v1:" + hex(SHA-256(transcript bytes))
//  - challenge: IdentitySigningChallenge fields, sorted keys, `/` escaped as `\/`
//  - issuedAt/expiresAt: milliseconds / 1000 through seconds since 2001, as
//    Foundation's Date stores them; expiresAt adds 30 seconds there
//

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

final class IdentitySigningChallengeInteropTests: XCTestCase {
    typealias Auth = BridgeChannelAuthentication

    // MARK: - An independent client

    /// Minimal JSON for this one profile, written by hand.
    indirect enum JSON {
        case string(String)
        case integer(Int64)
        case double(Double)
        case object([String: JSON])
    }

    static func write(_ value: JSON, escapeSlash: Bool) -> String {
        switch value {
        case let .string(text):
            var out = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "/": out += escapeSlash ? "\\/" : "/"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        case let .integer(number):
            return String(number)
        case let .double(number):
            var text = number.description
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text
        case let .object(members):
            // Code-point order of the member names.
            let keys = members.keys.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            return "{" + keys.map { write(.string($0), escapeSlash: escapeSlash) + ":" + write(members[$0]!, escapeSlash: escapeSlash) }.joined(separator: ",") + "}"
        }
    }

    /// What a client knows after `channelAuthChallenge`, read from the wire JSON.
    struct WireTranscript {
        var object: [String: Any]

        func string(_ key: String) -> String { object[key] as! String }
        func integer(_ key: String) -> Int64 {
            switch object[key] {
            case let value as Int: return Int64(value)
            case let value as Int64: return value
            case let value as NSNumber: return value.int64Value
            default: preconditionFailure("\(key) is not an integer")
            }
        }
        var endpoint: [String: String] { object["endpoint"] as! [String: String] }
        var identity: [String: String] { object["identity"] as! [String: String] }

        var json: JSON {
            .object([
                "profile": .string(string("profile")),
                "endpoint": .object(endpoint.mapValues { .string($0) }),
                "identity": .object(identity.mapValues { .string($0) }),
                "clientNonce": .string(string("clientNonce")),
                "serverNonce": .string(string("serverNonce")),
                "sessionID": .string(string("sessionID")),
                "generation": .string(string("generation")),
                "direction": .string(string("direction")),
                "issuedAtMilliseconds": .integer(integer("issuedAtMilliseconds")),
                "channelExpiresAtMilliseconds": .integer(integer("channelExpiresAtMilliseconds")),
            ])
        }
    }

    static func transcriptBytes(_ transcript: WireTranscript) -> Data {
        Data(write(transcript.json, escapeSlash: false).utf8)
    }

    static func hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    /// The IdentitySigningChallenge bytes, built from the transcript alone.
    static func challengeBytes(_ transcript: WireTranscript, escapeSlash: Bool = true) -> Data {
        let referenceOffset = 978_307_200.0   // 1970 → 2001, Foundation's reference date
        let issuedSince2001 = Double(transcript.integer("issuedAtMilliseconds")) / 1000 - referenceOffset
        let identity = transcript.identity
        let challenge: JSON = .object([
            "type": .string("org.haven.cellprotocol.identity-signing-challenge"),
            "version": .integer(1),
            "purpose": .string("identity-origin-proof"),
            "identityUUID": .string(identity["uuid"]!),
            "publicKeyFingerprint": .string("\(identity["algorithm"]!):\(identity["curve"]!):\(identity["publicKey"]!)"),
            "domain": .string(transcript.endpoint["domain"]!),
            "resource": .string("org.haven.bridge-channel.v1:" + hex(transcriptBytes(transcript))),
            "action": .string("openBridgeChannel"),
            "audience": .string(transcript.endpoint["origin"]! + transcript.endpoint["route"]!),
            "nonce": .string(transcript.string("serverNonce")),
            "issuedAt": .double(issuedSince2001 + referenceOffset),
            "expiresAt": .double((issuedSince2001 + 30) + referenceOffset),
        ])
        return Data(write(challenge, escapeSlash: escapeSlash).utf8)
    }

    // MARK: - Fixture

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/interop/v1", isDirectory: true)
    }

    static func fixture(_ id: String) throws -> [String: Any] {
        let url = fixtureDirectory.appendingPathComponent("\(id).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Bob's public test key from the v1 manifest: seed = SHA-256("haven-interop-v1/bob").
    static let bobUUID = "6F1C2B0A-0000-4000-8000-000000000B0B"
    static let bobKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data("haven-interop-v1/bob".utf8))))

    static func bobIdentity() -> Identity {
        let identity = Identity(bobUUID, displayName: "bob", identityVault: nil)
        identity.publicSecureKey = SecureKey(date: Date(timeIntervalSince1970: 0), privateKey: false, use: .signature,
            algorithm: .EdDSA, size: 256, curveType: .Curve25519, x: nil, y: nil,
            compressedKey: bobKey.publicKey.rawRepresentation)
        return identity
    }

    // MARK: - Tests against the committed fixture

    func testIndependentClientReproducesFixtureBytes() throws {
        let file = try Self.fixture("bridge.channel-auth.valid")
        let transcript = WireTranscript(object: try XCTUnwrap(file["object"] as? [String: Any]))
        let related = try XCTUnwrap(file["related"] as? [String: String])

        let transcriptBytes = Self.transcriptBytes(transcript)
        XCTAssertEqual(transcriptBytes.base64EncodedString(), file["encodedBase64"] as? String, "transcript bytes")
        XCTAssertEqual(Self.hex(transcriptBytes), related["transcriptDigestHex"], "transcript digest")

        let challenge = Self.challengeBytes(transcript)
        XCTAssertEqual(challenge.base64EncodedString(), file["canonicalBase64"] as? String,
                       "challenge bytes:\n\(String(decoding: challenge, as: UTF8.self))")
    }

    /// The server builds the bytes itself and never takes them from the client.
    /// Its bytes must equal the independent ones, and the fixture signature must
    /// pass the server's own check.
    func testServerVerificationAcceptsFixtureSignature() throws {
        let file = try Self.fixture("bridge.channel-auth.valid")
        let encoded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["encodedBase64"] as? String)))
        let transcript = try Auth.decode(Auth.Transcript.self, from: encoded)
        let independent = Self.challengeBytes(WireTranscript(object: try XCTUnwrap(file["object"] as? [String: Any])))

        XCTAssertEqual(try Auth.signingData(transcript), independent)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file["signatureBase64"] as? String)))
        XCTAssertTrue(IdentityPublicKeySignatureVerifier.verify(signature: signature, messageData: independent,
                                                                identity: transcript.identity.makeIdentity()))
        XCTAssertEqual(transcript.identity.makeIdentity().signingPublicKeyFingerprint,
                       "EdDSA:Curve25519:\(Self.bobKey.publicKey.rawRepresentation.base64EncodedString())",
                       "fingerprint format the independent client assumes")
    }

    // MARK: - Tests against a live server session

    func liveChallenge() throws -> (BridgeChannelSession, WireTranscript, Auth.Challenge) {
        let endpoint = try Auth.Endpoint(
            url: URL(string: "wss://staging.haven.digipomps.org/bridgehead/6F1C2B0A-0000-4000-8000-00000000A11C/EntityScaffoldExtension")!,
            domain: "bridge")
        let session = try BridgeChannelSession(endpoint: endpoint)
        let challenge = try session.issueChallenge(Auth.Hello(identity: try Auth.PublicIdentity(Self.bobIdentity())))
        // The client sees the challenge as wire JSON, not as Swift types.
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Auth.encode(challenge)) as? [String: Any])
        let transcript = WireTranscript(object: try XCTUnwrap(wire["transcript"] as? [String: Any]))
        return (session, transcript, challenge)
    }

    /// Fresh nonces, session id and clock from the server: the independent
    /// client signs its own bytes and the server admits it.
    func testLiveServerAdmitsIndependentClient() throws {
        let (session, transcript, challenge) = try liveChallenge()
        let bytes = Self.challengeBytes(transcript)
        XCTAssertEqual(bytes, challenge.signingData, "server and independent client disagree:\n\(String(decoding: bytes, as: UTF8.self))")

        let proof = Auth.Proof(sessionID: transcript.string("sessionID"), generation: session.generation,
                               signature: try Self.bobKey.signature(for: bytes))
        XCTAssertNoThrow(try session.reserveOpen(proof))
        XCTAssertEqual(session.publicIdentity?.uuid, Self.bobUUID)
    }

    /// The trap a port falls into: the challenge escapes `/`, the transcript does not.
    func testLiveServerRefusesUnescapedSlashes() throws {
        let (session, transcript, _) = try liveChallenge()
        let wrong = Self.challengeBytes(transcript, escapeSlash: false)
        let proof = Auth.Proof(sessionID: transcript.string("sessionID"), generation: session.generation,
                               signature: try Self.bobKey.signature(for: wrong))
        XCTAssertThrowsError(try session.reserveOpen(proof)) { error in
            XCTAssertEqual(error as? Auth.Failure, .invalidProof)
        }
    }
}
