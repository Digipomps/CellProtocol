// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

/// Fail-closed admission policy for owner-private contact records stored below
/// an EntityAnchor. The policy reserves one keypath family so legacy generic
/// Entity writes cannot silently bypass contact validation.
public enum EntityValidatedContactRecordV1 {
    public static let envelopeSchema = "haven.entity-validated-contact-batch.v1"
    public static let recordSchema = "haven.entity-validated-contact-record.v1"
    public static let protectedRoot = "relations.validatedContacts"
    public static let storagePurposeRef = "purpose://access.audit.privacy"

    private static let permittedPurposeRefs: Set<String> = [
        "purpose://access.audit.privacy",
        "purpose://contact.communication",
        "purpose://contact.introduction"
    ]
    private static let permittedSourceKinds: Set<String> = [
        "macos-contacts",
        "recipient-confirmed",
        "user-supplied"
    ]

    /// Validates every batch touching the reserved contact namespace. Other
    /// existing Entity batches remain wire-compatible and are not reclassified
    /// as validated writes by this additive v1 policy.
    public static func validatePersistenceEnvelope(
        _ envelope: EntityBatchPersistEnvelope
    ) throws {
        let protectedMutations = envelope.mutations.filter {
            isProtectedKeypath($0.keypath)
        }

        if protectedMutations.isEmpty {
            guard envelope.schema != envelopeSchema else {
                throw EntityValidatedContactRecordErrorV1.expectedExactlyOneMutation
            }
            return
        }

        guard envelope.schema == envelopeSchema else {
            throw EntityValidatedContactRecordErrorV1.protectedKeypathRequiresValidatedSchema
        }
        guard envelope.mutations.count == 1,
              protectedMutations.count == 1,
              let mutation = protectedMutations.first else {
            throw EntityValidatedContactRecordErrorV1.expectedExactlyOneMutation
        }
        guard let commitRequest = envelope.commitRequest else {
            throw EntityValidatedContactRecordErrorV1.ownerSignedCommitRequired
        }
        guard commitRequest.purposeRef == storagePurposeRef,
              commitRequest.capability == EntityBatchPersistEnvelope.operation else {
            throw EntityValidatedContactRecordErrorV1.invalidCommitAuthority
        }

        let allowedMetadataKeys: Set<String> = [
            "dataAction",
            "disclosureAuthorized",
            "relationID"
        ]
        guard Set(envelope.metadata.keys) == allowedMetadataKeys,
              string("dataAction", in: envelope.metadata) == "entity-storage",
              bool("disclosureAuthorized", in: envelope.metadata) == false,
              let metadataRelationID = string("relationID", in: envelope.metadata) else {
            throw EntityValidatedContactRecordErrorV1.invalidMetadata
        }

        let record = try recordObject(from: mutation.value)
        let relationID = try requiredString("relationID", in: record, maxUTF8Bytes: 128)
        try validateIdentifier(relationID)
        guard metadataRelationID == relationID,
              mutation.keypath == keypath(relationID: relationID) else {
            throw EntityValidatedContactRecordErrorV1.relationBindingMismatch
        }

        try validateRecord(record)
    }

    /// Rejects generic/direct writes to the reserved namespace. The validated
    /// batch path calls `validatePersistenceEnvelope(_:)` instead.
    public static func rejectDirectMutation(to keypath: String) throws {
        if isProtectedKeypath(keypath) {
            throw EntityValidatedContactRecordErrorV1.protectedKeypathRequiresValidatedSchema
        }
    }

    public static func keypath(relationID: String) -> String {
        "\(protectedRoot).\(relationID)"
    }

    public static func isProtectedKeypath(_ keypath: String) -> Bool {
        keypath == protectedRoot || keypath.hasPrefix(protectedRoot + ".")
    }

    /// Value-free schema metadata suitable for an owner-only Explore/read
    /// surface. It contains no contact values or relation cardinality.
    public static func schemaValue() -> ValueType {
        .object([
            "schema": .string(envelopeSchema),
            "recordSchema": .string(recordSchema),
            "protectedRoot": .string(protectedRoot),
            "writeOperation": .string(EntityBatchPersistEnvelope.operation),
            "commitRequired": .bool(true),
            "storagePurposeRef": .string(storagePurposeRef),
            "retentionPermission": .string("---s"),
            "disclosureImplied": .bool(false),
            "allowedFields": .list([
                "schema",
                "relationID",
                "displayName",
                "channels",
                "provenance",
                "purposeRefs",
                "retention",
                "status"
            ].map(ValueType.string)),
            "channelFields": .list(["email", "phoneE164"].map(ValueType.string))
        ])
    }

    /// Complete Explore return contract for `entityContactSchema`. This
    /// describes the value-free metadata shape without exposing contact values
    /// or relationship cardinality.
    public static func schemaExploreReturn() -> ValueType {
        let string = ExploreContract.schema(type: "string")
        return ExploreContract.objectSchema(
            properties: [
                "schema": string,
                "recordSchema": string,
                "protectedRoot": string,
                "writeOperation": string,
                "commitRequired": ExploreContract.schema(type: "bool"),
                "storagePurposeRef": string,
                "retentionPermission": string,
                "disclosureImplied": ExploreContract.schema(type: "bool"),
                "allowedFields": ExploreContract.listSchema(item: string),
                "channelFields": ExploreContract.listSchema(item: string)
            ],
            requiredKeys: [
                "schema",
                "recordSchema",
                "protectedRoot",
                "writeOperation",
                "commitRequired",
                "storagePurposeRef",
                "retentionPermission",
                "disclosureImplied",
                "allowedFields",
                "channelFields"
            ]
        )
    }

    private static func validateRecord(_ record: Object) throws {
        let allowedRecordKeys: Set<String> = [
            "schema",
            "relationID",
            "displayName",
            "channels",
            "provenance",
            "purposeRefs",
            "retention",
            "status"
        ]
        guard Set(record.keys) == allowedRecordKeys,
              string("schema", in: record) == recordSchema,
              string("status", in: record) == "owner-accepted" else {
            throw EntityValidatedContactRecordErrorV1.invalidRecordShape
        }

        _ = try requiredString("displayName", in: record, maxUTF8Bytes: 256)

        guard case let .object(channels)? = record["channels"] else {
            throw EntityValidatedContactRecordErrorV1.invalidChannels
        }
        let allowedChannelKeys: Set<String> = ["email", "phoneE164"]
        guard channels.isEmpty == false,
              Set(channels.keys).isSubset(of: allowedChannelKeys) else {
            throw EntityValidatedContactRecordErrorV1.invalidChannels
        }
        if let email = string("email", in: channels) {
            try validateEmail(email)
        } else if channels["email"] != nil {
            throw EntityValidatedContactRecordErrorV1.invalidEmail
        }
        if let phone = string("phoneE164", in: channels) {
            try validateE164(phone)
        } else if channels["phoneE164"] != nil {
            throw EntityValidatedContactRecordErrorV1.invalidPhoneE164
        }

        guard case let .object(provenance)? = record["provenance"] else {
            throw EntityValidatedContactRecordErrorV1.invalidProvenance
        }
        let allowedProvenanceKeys: Set<String> = [
            "sourceKind",
            "sourceLabel",
            "observedAt"
        ]
        guard Set(provenance.keys) == allowedProvenanceKeys,
              let sourceKind = string("sourceKind", in: provenance),
              permittedSourceKinds.contains(sourceKind),
              (try? requiredString("sourceLabel", in: provenance, maxUTF8Bytes: 256)) != nil,
              let observedAt = string("observedAt", in: provenance),
              isRFC3339(observedAt) else {
            throw EntityValidatedContactRecordErrorV1.invalidProvenance
        }

        guard case let .list(purposeValues)? = record["purposeRefs"] else {
            throw EntityValidatedContactRecordErrorV1.invalidPurposeRefs
        }
        let purposeRefs = purposeValues.compactMap { value -> String? in
            guard case let .string(string) = value else { return nil }
            return string
        }
        guard purposeRefs.count == purposeValues.count,
              purposeRefs.isEmpty == false,
              Set(purposeRefs).count == purposeRefs.count,
              Set(purposeRefs).isSubset(of: permittedPurposeRefs),
              purposeRefs.contains("purpose://contact.communication"),
              purposeRefs.contains("purpose://access.audit.privacy") else {
            throw EntityValidatedContactRecordErrorV1.invalidPurposeRefs
        }

        guard case let .object(retention)? = record["retention"],
              Set(retention.keys) == Set(["storageAuthorized", "disclosureAuthorized"]),
              bool("storageAuthorized", in: retention) == true,
              bool("disclosureAuthorized", in: retention) == false else {
            throw EntityValidatedContactRecordErrorV1.invalidRetention
        }
    }

    private static func recordObject(from value: ValueType) throws -> Object {
        guard case let .object(record) = value else {
            throw EntityValidatedContactRecordErrorV1.invalidRecordShape
        }
        return record
    }

    private static func requiredString(
        _ key: String,
        in object: Object,
        maxUTF8Bytes: Int
    ) throws -> String {
        guard let value = string(key, in: object),
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.isEmpty == false,
              value.utf8.count <= maxUTF8Bytes else {
            throw EntityValidatedContactRecordErrorV1.invalidStringField(key)
        }
        return value
    }

    private static func validateIdentifier(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw EntityValidatedContactRecordErrorV1.invalidRelationID
        }
    }

    private static func validateEmail(_ value: String) throws {
        guard value.utf8.count <= 254,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value != 127 }) else {
            throw EntityValidatedContactRecordErrorV1.invalidEmail
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].isEmpty == false,
              parts[0].utf8.count <= 64,
              parts[1].contains("."),
              parts[1].hasPrefix(".") == false,
              parts[1].hasSuffix(".") == false,
              parts[1].contains("..") == false else {
            throw EntityValidatedContactRecordErrorV1.invalidEmail
        }
    }

    private static func validateE164(_ value: String) throws {
        let digits = value.dropFirst()
        guard value.first == "+",
              (8...15).contains(digits.count),
              digits.first != "0",
              digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw EntityValidatedContactRecordErrorV1.invalidPhoneE164
        }
    }

    private static func string(_ key: String, in object: Object) -> String? {
        guard case let .string(value)? = object[key] else { return nil }
        return value
    }

    private static func bool(_ key: String, in object: Object) -> Bool? {
        guard case let .bool(value)? = object[key] else { return nil }
        return value
    }

    private static func isRFC3339(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

public enum EntityValidatedContactRecordErrorV1: Error, Equatable, Sendable {
    case protectedKeypathRequiresValidatedSchema
    case expectedExactlyOneMutation
    case ownerSignedCommitRequired
    case invalidCommitAuthority
    case invalidMetadata
    case relationBindingMismatch
    case invalidRecordShape
    case invalidStringField(String)
    case invalidRelationID
    case invalidChannels
    case invalidEmail
    case invalidPhoneE164
    case invalidProvenance
    case invalidPurposeRefs
    case invalidRetention
}
