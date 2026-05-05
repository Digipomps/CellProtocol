// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class FlowEnvelopeSerializationTests: XCTestCase {
    func testFlowEnvelopeRoundTrip() throws {
        let payload = FlowElement(
            id: "flow-1",
            title: "example.event",
            content: .string("hello"),
            properties: .init(type: .event, contentType: .string)
        )

        let provenance = FlowProvenance(
            originCell: "cell://origin",
            originIdentity: "did:key:zExample"
        )

        let envelope = try FlowEnvelope(
            streamId: "stream-alpha",
            sequence: 1,
            domain: "private",
            producerCell: "cell://producer",
            producerIdentity: "did:key:zProducer",
            payload: payload,
            previousEnvelopeHash: nil,
            signature: Data("sig".utf8),
            signatureKeyId: "kid-1",
            provenance: provenance,
            revisionLink: FlowRevisionLink(revision: 0),
            metadata: ["source": "test"]
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(FlowEnvelope.self, from: data)

        XCTAssertEqual(decoded.streamId, "stream-alpha")
        XCTAssertEqual(decoded.sequence, 1)
        XCTAssertEqual(decoded.domain, "private")
        XCTAssertEqual(decoded.producerCell, "cell://producer")
        XCTAssertEqual(decoded.producerIdentity, "did:key:zProducer")
        XCTAssertEqual(decoded.payload.id, "flow-1")
        XCTAssertEqual(decoded.signatureKeyId, "kid-1")
        XCTAssertEqual(decoded.provenance?.originCell, "cell://origin")
        XCTAssertEqual(decoded.metadata?["source"], "test")
    }

    func testPayloadHashStableForEquivalentObjectsWithDifferentKeyOrder() throws {
        let objectA: Object = [
            "name": .string("alice"),
            "age": .integer(30),
            "active": .bool(true)
        ]

        let objectB: Object = [
            "active": .bool(true),
            "age": .integer(30),
            "name": .string("alice")
        ]

        let payloadA = FlowElement(
            id: "flow-stable",
            title: "stable",
            content: .object(objectA),
            properties: .init(type: .content, contentType: .object)
        )

        let payloadB = FlowElement(
            id: "flow-stable",
            title: "stable",
            content: .object(objectB),
            properties: .init(type: .content, contentType: .object)
        )

        let hashA = try FlowHasher.payloadHash(for: payloadA)
        let hashB = try FlowHasher.payloadHash(for: payloadB)

        XCTAssertEqual(hashA, hashB)
    }

    func testEnvelopeHashChangesWhenSequenceChanges() throws {
        let payload = FlowElement(
            id: "flow-seq",
            title: "sequence",
            content: .string("x"),
            properties: .init(type: .event, contentType: .string)
        )

        let envelope1 = try FlowEnvelope(
            streamId: "stream-seq",
            sequence: 1,
            domain: "private",
            producerCell: "cell://producer",
            producerIdentity: "did:key:zProducer",
            payload: payload
        )

        let envelope2 = try FlowEnvelope(
            streamId: "stream-seq",
            sequence: 2,
            domain: "private",
            producerCell: "cell://producer",
            producerIdentity: "did:key:zProducer",
            payload: payload
        )

        let hash1 = try FlowHasher.envelopeHash(for: envelope1)
        let hash2 = try FlowHasher.envelopeHash(for: envelope2)

        XCTAssertNotEqual(hash1, hash2)
    }
}
