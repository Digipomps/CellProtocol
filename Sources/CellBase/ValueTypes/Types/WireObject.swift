import Foundation

/// Explicit application Object representation. Keys are data and each value
/// carries its enum variant. Legacy dictionaries remain readable; all-null
/// dictionaries retain their unambiguous historical bytes on re-encoding.
struct WireObject: Codable {
    let value: Object
    init(_ value: Object) { self.value = value }
    private enum Keys: String, CodingKey { case entries = "&objectEntries" }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let key = DynamicCodingKey(stringValue: "&objectEntries")
        if container.contains(key) {
            guard container.allKeys.count == 1 else { throw DecodingPDSError.corruptedData }
            value = try container.decode([String: WireObjectValue].self, forKey: key).mapValues(\.value)
        } else {
            var fields: Object = [:]
            for key in container.allKeys {
                // This is the legacy wire dictionary. Only explicit entries
                // make marker-named properties literal application data.
                fields[key.stringValue] = try ValueTypeCodec.decodeWireValue(
                    from: container.superDecoder(forKey: key), marker: key.stringValue)
            }
            value = fields
        }
    }
    // Preserve established plain JSON whenever it already roundtrips exactly.
    // Marker-named properties and variants lost by JSON inference need tagging.
    private var requiresExplicitRepresentation: Bool {
        value.contains { key, value in
            if key == "&objectEntries" { return true }
            if case .null = value { return false }
            return Self.markers.contains(key) || !Self.preservesInferredVariant(value)
        }
    }
    private static let markers: Set<String> = [
        "&objectEntries", "&string", "&number", "&list", "&object", "bool", "integer", "float", "data",
        "&flowElement", "&connectContext", "&connectState", "&agreementState", "&agreementPayload",
        "&description", "&keyValue", "&setValueState", "&setValueResponse", "&cellConfiguration",
        "&cellReference", "&verifiableCredential", "sign", "&signature", "&cell"
    ]
    private static func preservesInferredVariant(_ value: ValueType) -> Bool {
        switch value {
        case .null, .string, .bool, .integer, .object: return true
        case .float(let number): return number.rounded(.towardZero) != number
        case .list(let values): return values.allSatisfy(preservesInferredVariant)
        default: return false
        }
    }
    func encode(to encoder: Encoder) throws {
        if !requiresExplicitRepresentation {
            try value.encode(to: encoder)
        } else {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(value.mapValues(WireObjectValue.init), forKey: .entries)
        }
    }
}

private struct WireObjectValue: Codable {
    let value: ValueType
    init(_ value: ValueType) { self.value = value }
    private enum Keys: String, CodingKey { case type, value }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard container.contains(.value) else { throw DecodingPDSError.corruptedData }
        let child = try container.superDecoder(forKey: .value)
        switch type {
        case "null":
            guard try child.singleValueContainer().decodeNil() else { throw DecodingPDSError.corruptedData }
            value = .null
        case "&list": value = .list(try [WireObjectValue](from: child).map(\.value))
        case "&identity": value = .identity(try Identity(from: child))
        case "&string", "&number", "integer", "float", "bool", "data", "&object",
             "&flowElement", "&keyValue", "&setValueState", "&setValueResponse",
             "&cellConfiguration", "&cellReference", "&verifiableCredential",
             "&connectContext", "&connectState", "&agreementState", "sign", "&signature",
             "&agreementPayload", "&description":
            value = try ValueTypeCodec.decodeWireValue(from: child, marker: type)
        default: throw DecodingPDSError.corruptedData
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        let type: String
        switch value {
        case .null: type = "null"
        case .string: type = "&string"
        case .number: type = "&number"
        case .integer: type = "integer"
        case .float: type = "float"
        case .bool: type = "bool"
        case .data: type = "data"
        case .object: type = "&object"
        case .list: type = "&list"
        case .identity: type = "&identity"
        case .flowElement: type = "&flowElement"
        case .keyValue: type = "&keyValue"
        case .setValueState: type = "&setValueState"
        case .setValueResponse: type = "&setValueResponse"
        case .cellConfiguration: type = "&cellConfiguration"
        case .cellReference: type = "&cellReference"
        case .verifiableCredential: type = "&verifiableCredential"
        case .connectContext: type = "&connectContext"
        case .connectState: type = "&connectState"
        case .contractState: type = "&agreementState"
        case .signData: type = "sign"
        case .signature: type = "&signature"
        case .agreementPayload: type = "&agreementPayload"
        case .description: type = "&description"
        case .cell: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
            debugDescription: "Advertise a Cell before encoding it as an Object property."))
        }
        try container.encode(type, forKey: .type)
        if case .list(let list) = value {
            try container.encode(list.map(WireObjectValue.init), forKey: .value)
        } else {
            try container.encode(value, forKey: .value)
        }
    }
}
