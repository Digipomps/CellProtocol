// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public actor FlowEnvelopeSupervisor {
    public struct EnvelopeRecord {
        public let envelope: FlowEnvelope
        public let producerIdentity: Identity
    }

    private var outboundSequenceByStream: [String: UInt64] = [:]
    private var inboundSequenceByStream: [String: UInt64] = [:]
    private var lastEnvelopeHashByStream: [String: String] = [:]
    private var recordsByFlowElementId: [String: EnvelopeRecord] = [:]

    public init() {}

    public func issueOutboundSequence(for streamId: String) -> (sequence: UInt64, previousEnvelopeHash: String?) {
        let nextSequence = (outboundSequenceByStream[streamId] ?? 0) + 1
        outboundSequenceByStream[streamId] = nextSequence
        return (nextSequence, lastEnvelopeHashByStream[streamId])
    }

    public func storeOutboundEnvelope(
        _ envelope: FlowEnvelope,
        producerIdentity: Identity,
        forFlowElementId flowElementId: String
    ) {
        recordsByFlowElementId[flowElementId] = EnvelopeRecord(envelope: envelope, producerIdentity: producerIdentity)
        if let envelopeHash = try? FlowHasher.envelopeHash(for: envelope, includingSignature: true) {
            lastEnvelopeHashByStream[envelope.streamId] = envelopeHash
        }
    }

    public func record(forFlowElementId flowElementId: String) -> EnvelopeRecord? {
        recordsByFlowElementId[flowElementId]
    }

    public func validateInboundSequence(for envelope: FlowEnvelope) throws {
        let expectedSequence = (inboundSequenceByStream[envelope.streamId] ?? 0) + 1
        guard envelope.sequence == expectedSequence else {
            throw FlowIntegrityError.sequenceGap(
                streamId: envelope.streamId,
                expected: expectedSequence,
                actual: envelope.sequence
            )
        }
        inboundSequenceByStream[envelope.streamId] = envelope.sequence
    }

    public func reset() {
        outboundSequenceByStream.removeAll()
        inboundSequenceByStream.removeAll()
        lastEnvelopeHashByStream.removeAll()
        recordsByFlowElementId.removeAll()
    }
}
