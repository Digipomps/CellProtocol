// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  HavenContactBasisV1.swift
//  CellProtocol
//
//  What an owner holds about a person who is not (yet) here, in two parts.
//
//  The *basis* is the claim: a handful of named fields, each with where it
//  came from and whether the person has confirmed it
//  (purpose://candidate.invite.claim-about-another). It is what an invitation
//  is built from, and exactly what the person gets to see before answering
//  (purpose://candidate.invite.recipient-sees-what-is-held).
//
//  The *private notes* are the owner's own. They have no path into a ticket,
//  a publication, a contact request or a landing page
//  (purpose://candidate.invite.private-notes-never-leave). The only way out
//  of this type is `basisFields()`, and that method does not know they exist.
//

import Foundation

public struct HavenContactBasisV1: Codable, Equatable, Sendable {

    public static let schema = "haven.contact.basis.v1"

    /// The fields a basis may carry. Anything else is not a claim about a
    /// person, it is text — and text is what private notes are for.
    public static let allowedKeys: Set<String> = [
        "name", "givenName", "email", "phone", "organization", "role", "context"
    ]
    public static let maximumValueBytes = 160
    public static let maximumValueWords = 12

    public enum Status: String, Codable, Equatable, Sendable {
        /// The owner's claim, not yet seen by the person it is about.
        case unconfirmed
        /// The person has seen it and let it stand.
        case confirmed
    }

    /// Where a field came from. Rendered for the person as
    /// "Boklisten, 12. sep., kolonne Epost" — a label, never a path.
    public struct Origin: Codable, Equatable, Sendable {
        public var file: String?
        public var date: String?
        public var column: String?

        public init(file: String? = nil, date: String? = nil, column: String? = nil) {
            self.file = file
            self.date = date
            self.column = column
        }

        public var displayText: String {
            var parts: [String] = []
            if let file, !file.isEmpty { parts.append(file) }
            if let date, !date.isEmpty { parts.append(date) }
            if let column, !column.isEmpty { parts.append("kolonne \(column)") }
            return parts.joined(separator: ", ")
        }
    }

    public struct Field: Codable, Equatable, Sendable {
        public var key: String
        public var value: String
        public var origin: Origin?
        public var status: Status

        public init(key: String, value: String, origin: Origin? = nil, status: Status = .unconfirmed) {
            self.key = key
            self.value = value
            self.origin = origin
            self.status = status
        }
    }

    public var schema: String
    public var fields: [Field]
    /// Never leaves the entity. Not part of `basisFields()`, not compared in
    /// "shown equals held", not readable by anything with a send path.
    public var privateNotes: String?

    public init(
        schema: String = HavenContactBasisV1.schema,
        fields: [Field],
        privateNotes: String? = nil
    ) {
        self.schema = schema
        self.fields = fields
        self.privateNotes = privateNotes
    }

    // MARK: Validation

    public enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case wrongSchema
        case empty
        case unknownKey(String)
        case duplicateKey(String)
        case emptyValue(String)
        case freeText(String)
        case originTooLong(String)

        public var description: String {
            switch self {
            case .wrongSchema: return "Feil skjema for grunnlag."
            case .empty: return "Grunnlaget har ingen felt."
            case .unknownKey(let key): return "«\(key)» er ikke et grunnlagsfelt. Fritekst hører i private notater."
            case .duplicateKey(let key): return "Feltet «\(key)» finnes to ganger."
            case .emptyValue(let key): return "Feltet «\(key)» er tomt."
            case .freeText(let key): return "Feltet «\(key)» ser ut som fritekst. Fritekst hører i private notater, og de sendes aldri."
            case .originTooLong(let key): return "Opphavet til «\(key)» er for langt til å være en merkelapp."
            }
        }
    }

    /// Fails closed on anything that is not a short, single-line claim in a
    /// known field. This is what keeps a private note from being smuggled
    /// into the basis by putting it under a made-up key.
    public func validate() throws {
        guard schema == Self.schema else { throw ValidationError.wrongSchema }
        guard !fields.isEmpty else { throw ValidationError.empty }
        var seen: Set<String> = []
        for field in fields {
            guard Self.allowedKeys.contains(field.key) else { throw ValidationError.unknownKey(field.key) }
            guard seen.insert(field.key).inserted else { throw ValidationError.duplicateKey(field.key) }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ValidationError.emptyValue(field.key) }
            guard Self.isShortClaim(value) else { throw ValidationError.freeText(field.key) }
            if let origin = field.origin {
                for part in [origin.file, origin.date, origin.column].compactMap({ $0 }) {
                    guard part.utf8.count <= 96, !part.contains("\n") else {
                        throw ValidationError.originTooLong(field.key)
                    }
                }
            }
        }
    }

    public static func isShortClaim(_ value: String) -> Bool {
        guard !value.contains("\n"), !value.contains("\r") else { return false }
        guard value.utf8.count <= maximumValueBytes else { return false }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        return words.count <= maximumValueWords
    }

    // MARK: The only way out

    /// The fields an invitation carries and the person sees. Built from
    /// `fields` alone; `privateNotes` is not an input to this function.
    public func basisFields() -> [HavenInviteBasisField] {
        fields.map { field in
            HavenInviteBasisField(
                key: field.key,
                value: field.value,
                origin: field.origin.map(\.displayText).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    /// Does what the invitation shows match what is held? Compared field by
    /// field against the basis — never against the whole record.
    public func shownEqualsHeld(_ shown: [HavenInviteBasisField]) -> Bool {
        let held = basisFields()
        guard held.count == shown.count else { return false }
        let heldByKey = Dictionary(uniqueKeysWithValues: held.map { ($0.key, $0) })
        return shown.allSatisfy { heldByKey[$0.key] == $0 }
    }

    /// Marks a field as confirmed by the person it is about; other fields
    /// keep their status.
    public func confirming(_ key: String) -> HavenContactBasisV1 {
        var copy = self
        copy.fields = fields.map { field in
            var field = field
            if field.key == key { field.status = .confirmed }
            return field
        }
        return copy
    }

    /// The person asked for a field to go. The claim disappears; nothing of
    /// its value is kept in the basis.
    public func erasing(_ key: String) -> HavenContactBasisV1 {
        var copy = self
        copy.fields = fields.filter { $0.key != key }
        return copy
    }
}
