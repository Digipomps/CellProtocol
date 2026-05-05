// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum FlowCanonicalEncodingError: Error {
    case invalidJSONObject
    case unsupportedValueType(String)
}

public enum FlowCanonicalEncoder {
    public static func canonicalData(for flowElement: FlowElement) throws -> Data {
        let object = try flowElementJSONObject(flowElement)
        return try canonicalData(from: object)
    }

    public static func canonicalData(
        for envelope: FlowEnvelope,
        includingSignature: Bool = false,
        includingProvenance: Bool = true
    ) throws -> Data {
        var object: [String: Any] = [
            "envelopeVersion": envelope.envelopeVersion,
            "streamId": envelope.streamId,
            "sequence": envelope.sequence,
            "domain": envelope.domain,
            "producerCell": envelope.producerCell,
            "producerIdentity": envelope.producerIdentity,
            "payload": try flowElementJSONObject(envelope.payload),
            "payloadHash": envelope.payloadHash
        ]

        if let previousEnvelopeHash = envelope.previousEnvelopeHash {
            object["previousEnvelopeHash"] = previousEnvelopeHash
        }
        if let signatureKeyId = envelope.signatureKeyId {
            object["signatureKeyId"] = signatureKeyId
        }
        if includingSignature, let signature = envelope.signature {
            object["signature"] = signature.base64EncodedString()
        }
        if includingProvenance, let provenance = envelope.provenance {
            object["provenance"] = flowProvenanceJSONObject(provenance)
        }
        if let revisionLink = envelope.revisionLink {
            object["revisionLink"] = flowRevisionLinkJSONObject(revisionLink)
        }
        if let metadata = envelope.metadata {
            object["metadata"] = metadata
        }

        return try canonicalData(from: object)
    }

    public static func canonicalData(for value: FlowElementValueType) throws -> Data {
        let object: [String: Any] = ["value": try flowElementValueJSONObject(value)]
        return try canonicalData(from: object)
    }

    private static func canonicalData(from jsonObject: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            throw FlowCanonicalEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    private static func flowElementJSONObject(_ flowElement: FlowElement) throws -> [String: Any] {
        var object: [String: Any] = [
            "id": flowElement.id,
            "title": flowElement.title,
            "topic": flowElement.topic,
            "content": try flowElementValueJSONObject(flowElement.content)
        ]

        if let properties = flowElement.properties {
            var propertiesObject: [String: Any] = [
                "type": properties.type.rawValue
            ]
            if let mimetype = properties.mimetype {
                propertiesObject["mimetype"] = mimetype
            }
            if let contentType = properties.contentType {
                propertiesObject["contentType"] = contentType.rawValue
            }
            object["properties"] = propertiesObject
        }

        if let origin = flowElement.origin {
            object["origin"] = origin
        }

        return object
    }

    private static func flowElementValueJSONObject(_ value: FlowElementValueType) throws -> [String: Any] {
        switch value {
        case let .number(number):
            return taggedValue(type: "number", value: number)
        case let .string(string):
            return taggedValue(type: "string", value: string)
        case let .data(data):
            return taggedValue(type: "data", value: data.base64EncodedString())
        case let .bool(bool):
            return taggedValue(type: "bool", value: bool)
        case let .object(object):
            return taggedValue(type: "object", value: try objectJSONObject(object))
        case let .list(list):
            return taggedValue(type: "list", value: try listJSONObject(list))
        }
    }

    private static func objectJSONObject(_ object: Object) throws -> [String: Any] {
        var encodedObject: [String: Any] = [:]
        for (key, value) in object {
            encodedObject[key] = try valueTypeJSONObject(value)
        }
        return encodedObject
    }

    private static func listJSONObject(_ list: ValueTypeList) throws -> [Any] {
        try list.map { try valueTypeJSONObject($0) }
    }

    private static func valueTypeJSONObject(_ value: ValueType) throws -> Any {
        switch value {
        case let .flowElement(flowElement):
            return taggedValue(type: "flowElement", value: try flowElementJSONObject(flowElement))
        case let .bool(bool):
            return taggedValue(type: "bool", value: bool)
        case let .number(number):
            return taggedValue(type: "number", value: number)
        case let .integer(integer):
            return taggedValue(type: "integer", value: integer)
        case let .float(float):
            return taggedValue(type: "float", value: float)
        case let .string(string):
            return taggedValue(type: "string", value: string)
        case let .object(object):
            return taggedValue(type: "object", value: try objectJSONObject(object))
        case let .list(list):
            return taggedValue(type: "list", value: try listJSONObject(list))
        case let .data(data):
            return taggedValue(type: "data", value: data.base64EncodedString())
        case let .keyValue(keyValue):
            var obj: [String: Any] = ["key": keyValue.key]
            if let keyValuePayload = keyValue.value {
                obj["value"] = try valueTypeJSONObject(keyValuePayload)
            }
            if let target = keyValue.target {
                obj["target"] = target
            }
            return taggedValue(type: "keyValue", value: obj)
        case let .setValueState(setValueState):
            return taggedValue(type: "setValueState", value: setValueState.rawValue)
        case let .setValueResponse(setValueResponse):
            return taggedValue(type: "setValueResponse", value: try encodableJSONObject(setValueResponse))
        case let .cellConfiguration(cellConfiguration):
            return taggedValue(type: "cellConfiguration", value: try encodableJSONObject(cellConfiguration))
        case let .cellReference(cellReference):
            return taggedValue(type: "cellReference", value: try encodableJSONObject(cellReference))
        case let .verifiableCredential(verifiableCredential):
            return taggedValue(type: "verifiableCredential", value: try encodableJSONObject(verifiableCredential))
        case let .identity(identity):
            return taggedValue(type: "identity", value: try encodableJSONObject(identity))
        case let .connectContext(connectContext):
            return taggedValue(type: "connectContext", value: try encodableJSONObject(connectContext))
        case let .connectState(connectState):
            return taggedValue(type: "connectState", value: connectState.rawValue)
        case let .contractState(contractState):
            return taggedValue(type: "contractState", value: contractState.rawValue)
        case let .signData(data):
            return taggedValue(type: "signData", value: data.base64EncodedString())
        case let .signature(signature):
            return taggedValue(type: "signature", value: signature.base64EncodedString())
        case let .agreementPayload(agreement):
            return taggedValue(type: "agreementPayload", value: try encodableJSONObject(agreement))
        case let .description(description):
            return taggedValue(type: "description", value: try encodableJSONObject(description))
        case let .cell(cell):
            return taggedValue(type: "cell", value: try encodableJSONObject(AnyEncodableBox(cell)))
        case .null:
            return taggedValue(type: "null", value: NSNull())
        }
    }

    private static func flowProvenanceJSONObject(_ provenance: FlowProvenance) -> [String: Any] {
        var object: [String: Any] = [
            "originCell": provenance.originCell,
            "originIdentity": provenance.originIdentity
        ]

        if let originPayloadHash = provenance.originPayloadHash {
            object["originPayloadHash"] = originPayloadHash
        }
        if let originSignature = provenance.originSignature {
            object["originSignature"] = originSignature.base64EncodedString()
        }

        return object
    }

    private static func flowRevisionLinkJSONObject(_ revisionLink: FlowRevisionLink) -> [String: Any] {
        var object: [String: Any] = [
            "revision": revisionLink.revision
        ]
        if let previousRevisionHash = revisionLink.previousRevisionHash {
            object["previousRevisionHash"] = previousRevisionHash
        }
        return object
    }

    private static func encodableJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func taggedValue(type: String, value: Any) -> [String: Any] {
        [
            "$type": type,
            "value": value
        ]
    }
}

private struct AnyEncodableBox: Encodable {
    private let wrapped: any Encodable

    init(_ wrapped: any Encodable) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
