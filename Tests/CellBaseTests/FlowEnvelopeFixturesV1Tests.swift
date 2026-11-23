// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  FlowEnvelopeFixturesV1Tests.swift
//
//  Pinned golden fixtures for the signed flow envelope (`FlowEnvelope`), so a
//  port (Kotlin first) can check its canonical bytes, hashes and Ed25519
//  signatures against what CellBase produces. The bytes are today's canonical
//  form: `JSONSerialization` with `.sortedKeys` through `FlowCanonicalEncoder`.
//  A JCS (RFC 8785) variant comes with the canonicalization transition; until
//  then these files are the contract and must not change silently.
//
//  Regenerate (Linux, where swift-crypto's Ed25519 is deterministic):
//    HAVEN_WRITE_FLOW_FIXTURES=1 swift test --filter FlowEnvelopeFixturesV1Tests
//  Verify (any platform, always runs):
//    swift test --filter FlowEnvelopeFixturesV1Tests
//

import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import CellBase

final class FlowEnvelopeFixturesV1Tests: XCTestCase {

    // MARK: - Fixed inputs

    struct Party {
        let name: String
        let uuid: String
        let key: Curve25519.Signing.PrivateKey

        var descriptor: IdentityPublicKeyDescriptor {
            IdentityPublicKeyDescriptor(
                uuid: uuid,
                displayName: name,
                publicKey: key.publicKey.rawRepresentation,
                algorithm: .EdDSA,
                curveType: .Curve25519
            )
        }

        /// An Identity whose vault signs with exactly this key.
        func signingIdentity() -> Identity {
            let identity = Identity(uuid, displayName: name, identityVault: FixedKeyIdentityVault(key: key))
            identity.publicSecureKey = SecureKey(
                date: Date(timeIntervalSince1970: 0),
                privateKey: false,
                use: .signature,
                algorithm: .EdDSA,
                size: 32,
                curveType: .Curve25519,
                x: nil,
                y: nil,
                compressedKey: key.publicKey.rawRepresentation
            )
            return identity
        }
    }

    /// Public test keys: seed = SHA-256("haven-interop-v1/<seedName>").
    static func party(_ name: String, seedName: String? = nil, uuid: String) -> Party {
        let seed = Data(SHA256.hash(data: Data("haven-interop-v1/\(seedName ?? name)".utf8)))
        return Party(name: name, uuid: uuid, key: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    static let producerUUID = "6F1C2B0A-0000-4000-8000-00000000F10E"
    static let producer = party("flow-producer", uuid: producerUUID)
    /// Mallory's v1 key claiming the producer's uuid.
    static let impostor = party("flow-impostor", seedName: "mallory", uuid: producerUUID)

    static func bytes(_ label: String, count: Int = 32) -> Data {
        var out = Data()
        var counter = 0
        while out.count < count {
            out.append(contentsOf: SHA256.hash(data: Data("haven-interop-v1/\(label)/\(counter)".utf8)))
            counter += 1
        }
        return out.prefix(count)
    }

    /// Same stress text as fixtures/interop/v1.
    static let stressText = "Hei/hallo \"Ærlig\" \\ sti: a/b?c=d&e<f>\nlinje\tTab æøå ÆØÅ 🙂 é"

    // MARK: - Case record

    struct Case {
        var id: String
        var description: String
        var envelope: FlowEnvelope
        var signer: Party
        var verdict: String
        var signatureValid: Bool
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    // MARK: - Builders

    static func stringElement() -> FlowElement {
        var element = FlowElement(
            id: "fe-interop-0001",
            title: "Melding / hilsen",
            content: .string(stressText),
            properties: .init(mimetype: "text/plain; charset=utf-8", type: .content, contentType: .string)
        )
        element.topic = "chat.message"
        element.origin = "cell:///Porthole/ChatCell"
        return element
    }

    static func objectElement() -> FlowElement {
        let nested = FlowElement(
            id: "fe-interop-nested",
            title: "Indre",
            content: .bool(false),
            properties: .init(type: .alert, contentType: nil)
        )
        var element = FlowElement(
            id: "fe-interop-0002",
            title: "Objekt",
            content: .object([
                "count": .number(42),
                "big": .integer(9_007_199_254_740_993),
                "neg": .integer(-7),
                "ratio": .float(3.25),
                "whole": .float(1.0),
                "huge": .float(1e21),
                "half": .float(-0.5),
                "flag": .bool(true),
                "name": .string("Ærlig / \"sitat\""),
                "blob": .data(bytes("flow-blob", count: 20)),
                "nothing": .null,
                "pair": .keyValue(KeyValue(key: "k", value: .string("v"), target: "cell:///Target")),
                "items": .list([.integer(1), .string("to"), .bool(false)]),
                "nested": .object(["inner": .string("x")]),
                "element": .flowElement(nested),
            ]),
            properties: .init(mimetype: "application/json", type: .event, contentType: .object)
        )
        element.topic = "entity.update"
        element.origin = "cell:///EntityAnchor"
        return element
    }

    static func dataElement() -> FlowElement {
        FlowElement(
            id: "fe-interop-0003",
            title: "Vedlegg",
            content: .data(bytes("flow-data", count: 48)),
            properties: .init(mimetype: "application/octet-stream", type: .content, contentType: .base64)
        )
    }

    static func listElement() -> FlowElement {
        var element = FlowElement(
            id: "fe-interop-0004",
            title: "Liste",
            content: .list([.number(0), .integer(-1), .float(-0.5), .string("ø")]),
            properties: nil
        )
        element.topic = "list.items"
        return element
    }

    static func sign(
        _ envelope: FlowEnvelope,
        as party: Party,
        signatureKeyId: String? = nil,
        provenance: Bool
    ) async throws -> FlowEnvelope {
        try await FlowEnvelopeSigner.sign(
            envelope,
            with: party.signingIdentity(),
            signatureKeyId: signatureKeyId,
            ensureProvenance: provenance,
            signProvenance: provenance
        )
    }

    static func buildCases() async throws -> [Case] {
        let stringEnvelope = try FlowEnvelope(
            streamId: "stream-interop-0001",
            sequence: 1,
            domain: "private",
            producerCell: "cell:///ChatCell",
            producerIdentity: producerUUID,
            payload: stringElement()
        )
        let stringSigned = try await sign(stringEnvelope, as: producer, provenance: true)

        let objectEnvelope = try FlowEnvelope(
            streamId: "stream-interop-0001",
            sequence: 2,
            domain: "private",
            producerCell: "cell:///EntityAnchor",
            producerIdentity: producerUUID,
            payload: objectElement(),
            revisionLink: FlowRevisionLink(revision: 3, previousRevisionHash: hex(bytes("revision-2"))),
            metadata: ["Zulu": "z", "alpha": "a", "item10": "10", "item2": "2"]
        )
        let objectSigned = try await sign(objectEnvelope, as: producer, provenance: true)

        let dataEnvelope = try FlowEnvelope(
            streamId: "stream-interop-0002",
            sequence: 1,
            domain: "scaffold",
            producerCell: "cell:///FileCell",
            producerIdentity: producerUUID,
            payload: dataElement()
        )
        let dataSigned = try await sign(dataEnvelope, as: producer, provenance: false)

        // No provenance on the data envelope, so its envelope hash is
        // deterministic and can be pinned as the next link in the stream.
        let listEnvelope = try FlowEnvelope(
            streamId: "stream-interop-0002",
            sequence: 2,
            domain: "scaffold",
            producerCell: "cell:///FileCell",
            producerIdentity: producerUUID,
            payload: listElement(),
            previousEnvelopeHash: try FlowHasher.envelopeHash(for: dataSigned)
        )
        let listSigned = try await sign(listEnvelope, as: producer, signatureKeyId: "flow-producer#ed25519-1", provenance: false)

        var tampered = stringSigned
        var tamperedPayload = stringElement()
        tamperedPayload.content = .string("Endret etter signering")
        tampered.payload = tamperedPayload

        let wrongKey = try await sign(stringEnvelope, as: impostor, provenance: true)

        return [
            Case(id: "flow.envelope.string.valid",
                 description: "Tekstinnhold med skråstrek, anførselstegn, linjeskift, tab, æøå og emoji. Proveniens er signert.",
                 envelope: stringSigned, signer: producer, verdict: "valid", signatureValid: true),
            Case(id: "flow.envelope.object.valid",
                 description: "Objektinnhold med alle enkle ValueType-varianter, et nestet FlowElement, revisionLink og metadata hvis nøkler viser sorteringsregelen (store/små bokstaver og tall).",
                 envelope: objectSigned, signer: producer, verdict: "valid", signatureValid: true),
            Case(id: "flow.envelope.data.valid",
                 description: "Binært innhold (base64), uten proveniens og uten origin.",
                 envelope: dataSigned, signer: producer, verdict: "valid", signatureValid: true),
            Case(id: "flow.envelope.list.valid",
                 description: "Liste uten properties, egen signatureKeyId og previousEnvelopeHash lik envelopeHashHex i flow.envelope.data.valid.",
                 envelope: listSigned, signer: producer, verdict: "valid", signatureValid: true),
            Case(id: "flow.envelope.string.tampered",
                 description: "Innholdet er endret etter signering; payloadHash og signatur er de opprinnelige.",
                 envelope: tampered, signer: producer, verdict: "payloadHashMismatch", signatureValid: false),
            Case(id: "flow.envelope.string.wrong-key",
                 description: "Signert med en annen nøkkel som påstår å være produsenten.",
                 envelope: wrongKey, signer: producer, verdict: "invalidProducerSignature", signatureValid: false),
        ]
    }

    // MARK: - Derived values

    static func signingData(_ envelope: FlowEnvelope) throws -> Data {
        try FlowCanonicalEncoder.canonicalData(for: envelope, includingSignature: false, includingProvenance: false)
    }

    static func provenanceSigningData(_ envelope: FlowEnvelope) throws -> Data? {
        guard let provenance = envelope.provenance else { return nil }
        return try FlowSignatureMaterial.originPayloadSigningData(
            originCell: provenance.originCell,
            originIdentity: provenance.originIdentity,
            payloadHash: envelope.payloadHash
        )
    }

    static func verdict(_ envelope: FlowEnvelope, signer: Party) async -> String {
        do {
            try await FlowEnvelopeVerifier.verify(
                envelope,
                producerIdentity: ChatInvitationProofUtility.identity(from: signer.descriptor),
                requireProvenanceSignature: envelope.provenance != nil
            )
            return "valid"
        } catch {
            return String(String(describing: error).prefix { $0 != "(" })
        }
    }

    static func rawSignatureValid(_ envelope: FlowEnvelope, signer: Party) throws -> Bool {
        guard let signature = envelope.signature else { return false }
        return IdentityPublicKeySignatureVerifier.verify(
            signature: signature,
            messageData: try signingData(envelope),
            descriptor: signer.descriptor
        )
    }

    static func fileObject(_ item: Case) throws -> [String: Any] {
        let envelope = item.envelope
        let signing = try signingData(envelope)
        let payload = try FlowCanonicalEncoder.canonicalData(for: envelope.payload)
        let full = try FlowCanonicalEncoder.canonicalData(for: envelope, includingSignature: true, includingProvenance: true)
        var object: [String: Any] = [
            "id": item.id,
            "flow": "flow",
            "type": "FlowEnvelope",
            "description": item.description,
            "envelope": try JSONSerialization.jsonObject(with: full),
            "envelopeCanonicalBase64": full.base64EncodedString(),
            "payloadCanonicalBase64": payload.base64EncodedString(),
            "payloadHashHex": envelope.payloadHash,
            "canonicalBase64": signing.base64EncodedString(),
            "canonicalSHA256Hex": sha256Hex(signing),
            "envelopeHashHex": try FlowHasher.envelopeHash(for: envelope),
            "signer": try JSONSerialization.jsonObject(with: try sortedEncoder().encode(item.signer.descriptor)),
            "expect": ["signatureValid": item.signatureValid, "verdict": item.verdict],
        ]
        if let signature = envelope.signature {
            object["signatureBase64"] = signature.base64EncodedString()
        }
        if let provenanceData = try provenanceSigningData(envelope) {
            object["provenanceCanonicalBase64"] = provenanceData.base64EncodedString()
            if let originSignature = envelope.provenance?.originSignature {
                object["provenanceSignatureBase64"] = originSignature.base64EncodedString()
            }
        }
        return object
    }

    static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Files

    static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/interop/flow-v1", isDirectory: true)
    }

    static func manifest(_ cases: [Case]) -> [String: Any] {
        [
            "schema": "haven.interop.fixtures.flow.v1",
            "generator": "Tests/CellBaseTests/FlowEnvelopeFixturesV1Tests.swift",
            "canonicalization": "foundation-sortedkeys-v1",
            "canonicalRule": "FlowCanonicalEncoder: JSONSerialization.data(withJSONObject:options:[.sortedKeys]) over the tagged object tree. Signed bytes exclude signature and provenance; envelopeHash excludes signature only.",
            "signature": "Ed25519 (RFC 8032). Keys are derived from SHA-256(\"haven-interop-v1/<seed>\") and are public test keys.",
            "parties": [producer, impostor].map { party -> [String: Any] in
                [
                    "name": party.name,
                    "uuid": party.uuid,
                    "seedHex": hex(party.key.rawRepresentation),
                    "publicKeyBase64": party.key.publicKey.rawRepresentation.base64EncodedString(),
                ]
            },
            "cases": cases.map { ["id": $0.id, "file": "\($0.id).json", "flow": "flow", "type": "FlowEnvelope"] },
        ]
    }

    static func write(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    static func loadFile(_ id: String) throws -> [String: Any] {
        let url = fixtureDirectory.appendingPathComponent("\(id).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(id): unreadable")
    }

    static func base64(_ file: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(file[key] as? String, "missing \(key)")), "bad base64 in \(key)")
    }

    static func show(_ data: Data) -> String {
        "\(data.base64EncodedString())\n\(String(decoding: data, as: UTF8.self))"
    }

    // MARK: - Tests

    func testWriteFlowEnvelopeFixturesV1() async throws {
        guard ProcessInfo.processInfo.environment["HAVEN_WRITE_FLOW_FIXTURES"] == "1" else {
            throw XCTSkip("Set HAVEN_WRITE_FLOW_FIXTURES=1 to regenerate fixtures/interop/flow-v1.")
        }
        let cases = try await Self.buildCases()
        let directory = Self.fixtureDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in cases {
            try Self.write(try Self.fileObject(item), to: directory.appendingPathComponent("\(item.id).json"))
        }
        try Self.write(Self.manifest(cases), to: directory.appendingPathComponent("manifest.json"))
    }

    /// The committed files are the contract. Every case is rebuilt and signed
    /// with CellBase on this platform; the deterministic bytes must equal the
    /// files exactly, and the committed signatures must give the committed
    /// verdicts through FlowEnvelopeVerifier.
    func testFlowEnvelopeFixturesV1MatchThisPlatform() async throws {
        let manifestURL = Self.fixtureDirectory.appendingPathComponent("manifest.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                                     "Missing \(manifestURL.path). Generate with HAVEN_WRITE_FLOW_FIXTURES=1.")
        let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let fresh = try await Self.buildCases()
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, fresh.map(\.id), "case list drifted")

        for item in fresh {
            let id = item.id
            let file = try Self.loadFile(id)

            // 1. Deterministic bytes: payload, signed bytes, provenance bytes.
            let payload = try FlowCanonicalEncoder.canonicalData(for: item.envelope.payload)
            let filePayload = try Self.base64(file, "payloadCanonicalBase64")
            XCTAssertEqual(payload, filePayload, "\(id): payload canonical bytes changed:\n\(Self.show(payload))")
            XCTAssertEqual(item.envelope.payloadHash, file["payloadHashHex"] as? String, "\(id): payloadHash changed")
            if item.verdict != "payloadHashMismatch" {
                XCTAssertEqual(Self.sha256Hex(payload), item.envelope.payloadHash, "\(id): payloadHash is not SHA-256 of the payload bytes")
            }

            let signing = try Self.signingData(item.envelope)
            let fileSigning = try Self.base64(file, "canonicalBase64")
            XCTAssertEqual(signing, fileSigning, "\(id): signed canonical bytes changed:\n\(Self.show(signing))")
            XCTAssertEqual(Self.sha256Hex(fileSigning), file["canonicalSHA256Hex"] as? String, "\(id): canonicalSHA256Hex")

            let provenance = try Self.provenanceSigningData(item.envelope)
            let fileProvenance = file["provenanceCanonicalBase64"] == nil ? nil : try Self.base64(file, "provenanceCanonicalBase64")
            XCTAssertEqual(provenance, fileProvenance, "\(id): provenance canonical bytes changed:\n\(provenance.map(Self.show) ?? "none")")

            // 2. Pin this platform's envelope to the committed signatures, then
            //    the hashes and full canonical form must match the files.
            var pinned = item.envelope
            pinned.signature = try Self.base64(file, "signatureBase64")
            if pinned.provenance != nil, file["provenanceSignatureBase64"] != nil {
                pinned.provenance?.originSignature = try Self.base64(file, "provenanceSignatureBase64")
            }
            let full = try FlowCanonicalEncoder.canonicalData(for: pinned, includingSignature: true, includingProvenance: true)
            XCTAssertEqual(full, try Self.base64(file, "envelopeCanonicalBase64"), "\(id): full envelope bytes changed:\n\(Self.show(full))")
            XCTAssertEqual(try FlowHasher.envelopeHash(for: pinned), file["envelopeHashHex"] as? String, "\(id): envelopeHash changed")

            // 3. Verdicts on the committed signatures.
            let expect = try XCTUnwrap(file["expect"] as? [String: Any])
            XCTAssertEqual(try Self.rawSignatureValid(pinned, signer: item.signer), expect["signatureValid"] as? Bool, "\(id): signature verdict")
            let verdict = await Self.verdict(pinned, signer: item.signer)
            XCTAssertEqual(verdict, expect["verdict"] as? String, "\(id): verifier verdict")
            XCTAssertEqual(verdict, item.verdict, "\(id): builder expectation")

            // 4. Signing: this platform's fresh signature reaches the same verdict.
            let freshVerdict = await Self.verdict(item.envelope, signer: item.signer)
            XCTAssertEqual(freshVerdict, item.verdict, "\(id): fresh signature verdict")
            #if !canImport(CryptoKit)
            // BoringSSL Ed25519 is deterministic (RFC 8032); Apple's is randomized.
            XCTAssertEqual(item.envelope.signature?.base64EncodedString(), file["signatureBase64"] as? String, "\(id): Ed25519 signature bytes changed")
            XCTAssertEqual(item.envelope.provenance?.originSignature?.base64EncodedString(), file["provenanceSignatureBase64"] as? String,
                           "\(id): provenance signature bytes changed")
            #endif
        }
    }

    /// The list envelope chains to the data envelope by its pinned hash.
    func testFlowEnvelopeFixturesV1StreamLink() throws {
        let data = try Self.loadFile("flow.envelope.data.valid")
        let list = try Self.loadFile("flow.envelope.list.valid")
        let listEnvelope = try XCTUnwrap(list["envelope"] as? [String: Any])
        XCTAssertEqual(listEnvelope["previousEnvelopeHash"] as? String, data["envelopeHashHex"] as? String)
    }
}

/// Signs with one fixed Curve25519 key. Test-only.
private actor FixedKeyIdentityVault: IdentityVaultProtocol {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func initialize() async -> IdentityVaultProtocol { self }
    func addIdentity(identity: inout Identity, for identityContext: String) async {}
    func identity(for identityContext: String, makeNewIfNotFound: Bool) async -> Identity? { nil }
    func saveIdentity(_ identity: Identity) async {}

    func signMessageForIdentity(messageData: Data, identity: Identity) async throws -> Data {
        try key.signature(for: messageData)
    }

    func verifySignature(signature: Data, messageData: Data, for identity: Identity) async throws -> Bool {
        key.publicKey.isValidSignature(signature, for: messageData)
    }

    func randomBytes64() async -> Data? { nil }

    func aquireKeyForTag(tag: String) async throws -> (key: String, iv: String) {
        throw IdentityVaultError.signingFailed
    }
}
