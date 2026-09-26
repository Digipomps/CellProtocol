// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// purpose://candidate.entitetsdata.change-leaves-a-trace
// purpose://candidate.entitetsdata.no-write-without-owner-proof
//
// Every accepted change to entity data leaves exactly one entry in the
// entity's own trace: who signed, which keypaths changed, which purpose
// the change served, and which model proposed it when one did. One batch,
// one entry — not one per field. The entry is written in the same snapshot
// as the change, so there is no state where the change exists and the
// trace does not.
//
// The trace lives at its own root keypath, `trace`, next to `chronicle` —
// not inside it. The chronicle list is a wire-level contract that hosts
// compare entry for entry (EntityRelationHostParityTests); the trace is the
// anchor's own record of what it accepted, and must never change what a
// batch wrote.
//
// The same file holds the one purpose rule the anchor enforces itself:
// `purpose://prompt.unknown` fails closed. A change that cannot say what it
// is for is not persisted (lesson.purpose-never-grants-rights).

public enum EntityChangeTraceError: Error, Equatable, LocalizedError {
    case unknownPurposeFailsClosed
    case directWriteRequiresOwnerProof

    public var code: String {
        switch self {
        case .unknownPurposeFailsClosed: return "unknown_purpose_fails_closed"
        case .directWriteRequiresOwnerProof: return "direct_write_requires_owner_proof"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unknownPurposeFailsClosed:
            return "The change names purpose://prompt.unknown; an entity change must say what it is for."
        case .directWriteRequiresOwnerProof:
            return "Direct keypath writes into entity data require the requester to prove entity ownership."
        }
    }
}

public enum EntityChangeTrace {
    public static let unknownPurposeRef = "purpose://prompt.unknown"
    public static let entryIDPrefix = "trace-"
    public static let rootKeypath = "trace"
    public static let appendKeypath = "trace[+]"

    public enum Kind: String, Codable, Sendable {
        case batchPersist = "entity.batchPersist"
        case keypathSet = "entity.keypathSet"
    }

    /// The purpose an envelope claims. The signed commit request wins over
    /// loose metadata; a batch without a commit request may still name one.
    public static func purposeRef(of envelope: EntityBatchPersistEnvelope) -> String? {
        if let signed = envelope.commitRequest?.purposeRef, signed.isEmpty == false {
            return signed
        }
        if case let .string(loose)? = envelope.metadata["purposeRef"], loose.isEmpty == false {
            return loose
        }
        return nil
    }

    /// The model that proposed the change, when the envelope says one did.
    public static func modelRef(of envelope: EntityBatchPersistEnvelope) -> String? {
        for key in ["modelRef", "proposedByModel", "proposedBy"] {
            if case let .string(ref)? = envelope.metadata[key], ref.isEmpty == false {
                return ref
            }
        }
        return nil
    }

    /// Fails closed on `purpose://prompt.unknown`. A missing purpose is not
    /// refused here — older batches carry none — but the trace records it as
    /// absent rather than inventing one.
    public static func requireKnownPurpose(_ envelope: EntityBatchPersistEnvelope) throws {
        if purposeRef(of: envelope) == unknownPurposeRef {
            throw EntityChangeTraceError.unknownPurposeFailsClosed
        }
    }

    /// One trace entry for one accepted batch.
    public static func entry(
        for envelope: EntityBatchPersistEnvelope,
        signedBy requester: Identity,
        receipt: EntityAuthorityCommitReceipt?,
        at date: Date = Date()
    ) -> ValueType {
        let keypaths = envelope.mutations.map(\.keypath)
        var object: Object = [
            "id": .string(entryID(receipt: receipt, keypaths: keypaths, date: date)),
            "kind": .string(Kind.batchPersist.rawValue),
            "schema": .string(envelope.schema),
            "signedBy": .string(requester.uuid),
            "signingKeyFingerprint": .string(requester.signingPublicKeyFingerprint ?? ""),
            "keypaths": .list(keypaths.map { .string($0) }),
            "purposeRef": purposeRef(of: envelope).map { .string($0) } ?? .null,
            "modelRef": modelRef(of: envelope).map { .string($0) } ?? .null,
            "recordedAt": .string(IdentityLinkProtocolService.iso8601(date))
        ]
        if let receipt {
            object["receipt"] = .object([
                "mutationID": .string(receipt.mutationID),
                "revision": .integer(receipt.revision),
                "entryHash": .string(receipt.entryHash),
                "payloadHash": .string(receipt.payloadHash),
                "authorityIdentityUUID": .string(receipt.authorityIdentityUUID),
                "signature": .string(receipt.signature.base64EncodedString())
            ])
        } else {
            object["receipt"] = .null
        }
        return .object(object)
    }

    /// One trace entry for one direct keypath write by a proven owner.
    public static func entry(
        keypath: String,
        signedBy requester: Identity,
        at date: Date = Date()
    ) -> ValueType {
        .object([
            "id": .string(entryID(receipt: nil, keypaths: [keypath], date: date)),
            "kind": .string(Kind.keypathSet.rawValue),
            "signedBy": .string(requester.uuid),
            "signingKeyFingerprint": .string(requester.signingPublicKeyFingerprint ?? ""),
            "keypaths": .list([.string(keypath)]),
            "purposeRef": .null,
            "modelRef": .null,
            "receipt": .null,
            "recordedAt": .string(IdentityLinkProtocolService.iso8601(date))
        ])
    }

    /// Appends the entry to the entity's trace list. `trace[+]` creates the
    /// list on first use.
    public static func append(_ entry: ValueType, to entity: inout Entity) throws {
        try entity.set(keypath: appendKeypath, setValue: entry)
    }

    /// The trace entries in a trace value, oldest first. Tolerates an absent
    /// or empty root.
    public static func entries(in trace: ValueType?) -> [Object] {
        guard case let .list(items)? = trace else { return [] }
        return items.compactMap { item -> Object? in
            guard case let .object(object) = item,
                  case let .string(id)? = object["id"],
                  id.hasPrefix(entryIDPrefix) else { return nil }
            return object
        }
    }

    static func entryID(receipt: EntityAuthorityCommitReceipt?, keypaths: [String], date: Date) -> String {
        if let receipt {
            return entryIDPrefix + safeIdentifier(String(receipt.entryHash.prefix(24)))
        }
        let stamp = String(Int(date.timeIntervalSince1970 * 1_000))
        return entryIDPrefix + stamp + "-" + safeIdentifier(String(UUID().uuidString.prefix(8)))
    }

    static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
