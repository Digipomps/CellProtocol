// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Lossless correspondence-specific storage encoding. Generic Identity requires
/// a displayName on decode, but correspondence identities use their UUID as that
/// runtime fallback. Store that rule instead of a person-mapping field. Restore
/// the exact fallback before decoding signed Contracts, preserving their bytes.
/// Never redact an actual label from a signed Contract: reject that snapshot.
enum CorrespondenceIdentityStateCodec {
    static let markerKey = "correspondenceIdentityEncoding"
    static let markerValue = "uuid-display-fallback-v1"

    enum Failure: Error {
        case identifyingMetadataNotAllowed
        case invalidIdentityEncoding
    }

    struct BaseState: Encodable {
        let encodeValue: (Encoder) throws -> Void
        func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
    }

    struct CapturedDecoder: Decodable {
        let decoder: Decoder
        init(from decoder: Decoder) { self.decoder = decoder }
    }

    static func compact(_ value: Any) throws -> Any {
        if var object = value as? [String: Any] {
            if let label = object["displayName"] {
                guard let uuid = object["uuid"] as? String,
                      UUID(uuidString: uuid) != nil,
                      label as? String == uuid,
                      object[markerKey] == nil else {
                    throw Failure.identifyingMetadataNotAllowed
                }
                if let properties = object["properties"] {
                    guard let fields = properties as? [String: Any], fields.isEmpty else {
                        throw Failure.identifyingMetadataNotAllowed
                    }
                }
                if let vault = object["homeVaultReference"] {
                    guard vault as? String == "haven.correspondence.identity-vault:\(uuid)" else {
                        throw Failure.identifyingMetadataNotAllowed
                    }
                }
                for key in ["publicSecureKey", "publicKeyAgreementSecureKey"] {
                    if let material = object[key] {
                        guard let fields = material as? [String: Any],
                              fields["privateKey"] as? Bool == false else {
                            throw Failure.identifyingMetadataNotAllowed
                        }
                    }
                }
                object.removeValue(forKey: "displayName")
                object[markerKey] = markerValue
            }
            for (key, nested) in object {
                guard !["entityRef", "principalID", "principalLabel", "deviceID"].contains(key) else {
                    throw Failure.identifyingMetadataNotAllowed
                }
                object[key] = try compact(nested)
            }
            return object
        }
        if let list = value as? [Any] { return try list.map(compact) }
        return value
    }

    static func expand(_ value: Any) throws -> Any {
        if var object = value as? [String: Any] {
            if let marker = object.removeValue(forKey: markerKey) {
                guard marker as? String == markerValue,
                      let uuid = object["uuid"] as? String, UUID(uuidString: uuid) != nil,
                      object["displayName"] == nil else {
                    throw Failure.invalidIdentityEncoding
                }
                object["displayName"] = uuid
            }
            for (key, nested) in object { object[key] = try expand(nested) }
            return object
        }
        if let list = value as? [Any] { return try list.map(expand) }
        return value
    }

    static func decoderRestoringIdentityFallbacks(_ decoder: Decoder) throws -> Decoder {
        let value = try ValueType(from: decoder)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let restored = try JSONSerialization.data(withJSONObject: expand(raw), options: [.sortedKeys])
        let jsonDecoder = JSONDecoder()
        jsonDecoder.userInfo = decoder.userInfo
        return try jsonDecoder.decode(CapturedDecoder.self, from: restored).decoder
    }
}
