// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public final class VaultCell: GeneralCell {
    private var notesByID: [String: VaultNoteRecord]
    private var linksByKey: [String: VaultLinkRecord]
    private var stateVersion: Int
    private var updatedAtEpochMs: Int

    private enum CodingKeys: String, CodingKey {
        case notesByID
        case linksByKey
        case stateVersion
        case updatedAtEpochMs
        case generalCell
    }

    public required init(owner: Identity) async {
        self.notesByID = [:]
        self.linksByKey = [:]
        self.stateVersion = 0
        self.updatedAtEpochMs = 0
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.notesByID = try container.decodeIfPresent([String: VaultNoteRecord].self, forKey: .notesByID) ?? [:]
        self.linksByKey = try container.decodeIfPresent([String: VaultLinkRecord].self, forKey: .linksByKey) ?? [:]
        self.stateVersion = try container.decodeIfPresent(Int.self, forKey: .stateVersion) ?? 0
        self.updatedAtEpochMs = try container.decodeIfPresent(Int.self, forKey: .updatedAtEpochMs) ?? 0
        try super.init(from: decoder)

        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notesByID, forKey: .notesByID)
        try container.encode(linksByKey, forKey: .linksByKey)
        try container.encode(stateVersion, forKey: .stateVersion)
        try container.encode(updatedAtEpochMs, forKey: .updatedAtEpochMs)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "vault")
        agreementTemplate.addGrant("rw--", for: "feed")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "vault.state") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "vault", for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        await addInterceptForSet(requester: owner, key: "vault.note.create") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleNoteCreate(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.note.update") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleNoteUpdate(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.note.get") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleNoteGet(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.note.list") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleNoteList(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.link.add") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleLinkAdd(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.links.forward") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleLinksForward(value: value)
        }

        await addInterceptForSet(requester: owner, key: "vault.links.backlinks") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "vault", for: requester) else { return .string("denied") }
            return self.handleBacklinks(value: value)
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "vault.state",
            method: .get,
            input: .null,
            returns: Self.stateSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns a full, versioned vault snapshot for sync. Clients fetch this once, then follow VaultMutationEvent flow updates and re-fetch on version gaps.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.note.create",
            method: .set,
            input: Self.notePayloadSchema(),
            returns: Self.noteMutationResponseSchema(operation: "vault.note.create"),
            permissions: ["-w--"],
            required: true,
            description: .string("Creates a vault note from a raw note payload or an object containing `note`.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.note.update",
            method: .set,
            input: Self.notePayloadSchema(),
            returns: Self.noteMutationResponseSchema(operation: "vault.note.update"),
            permissions: ["-w--"],
            required: true,
            description: .string("Updates an existing vault note using a raw note payload or an object containing `note`.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.note.get",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.noteLookupResponseSchema(operation: "vault.note.get"),
            permissions: ["-w--"],
            required: true,
            description: .string("Fetches a single vault note by `id` or `note_id`.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.note.list",
            method: .set,
            input: Self.noteListInputSchema(),
            returns: Self.noteListResponseSchema(),
            permissions: ["-w--"],
            required: false,
            description: .string("Lists notes with optional filtering, sorting, and pagination.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.link.add",
            method: .set,
            input: Self.linkPayloadSchema(),
            returns: Self.linkMutationResponseSchema(operation: "vault.link.add"),
            permissions: ["-w--"],
            required: true,
            description: .string("Creates a link between two existing vault notes.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.links.forward",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.linksQueryResponseSchema(operation: "vault.links.forward"),
            permissions: ["-w--"],
            required: true,
            description: .string("Lists outgoing links for a note.")
        )

        await registerExploreContract(
            requester: requester,
            key: "vault.links.backlinks",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.linksQueryResponseSchema(operation: "vault.links.backlinks"),
            permissions: ["-w--"],
            required: true,
            description: .string("Lists incoming links targeting a note.")
        )
    }

    private func statePayload() -> ValueType {
        let notes = sortedNotesSnapshot()
        let links = sortedLinksSnapshot()
        let payload = VaultStatePayload(
            stateVersion: stateVersion,
            noteCount: notes.count,
            linkCount: links.count,
            notes: notes,
            links: links,
            operations: Self.operationsList(),
            updatedAtEpochMs: updatedAtEpochMs
        )

        guard case var .object(object) = try? VaultCellCodec.encode(payload) else {
            return .object([
                "status": .string("error"),
                "cell": .string("VaultCell"),
                "message": .string("Failed to encode vault state")
            ])
        }

        object["note_count"] = .integer(notes.count)
        object["link_count"] = .integer(links.count)
        return .object(object)
    }

    private func handleNoteCreate(value: ValueType) -> ValueType {
        let operation = "vault.note.create"

        let parsedNoteResult = parseNote(from: value)
        switch parsedNoteResult {
        case .failure:
            return validationError(
                operation: operation,
                message: "Invalid payload for note create",
                fieldErrors: [
                    VaultFieldError(
                        field: "note",
                        code: "invalid_payload",
                        message: "Expected VaultNoteRecord payload or object with note"
                    )
                ]
            )
        case .success(let parsedNote):
            let now = currentEpochMs()
            let normalized = normalize(note: parsedNote, now: now)

            var errors = validateRequiredFields(for: normalized)
            if notesByID[normalized.id] != nil {
                errors.append(
                    VaultFieldError(
                        field: "id",
                        code: "duplicate",
                        message: "A note with this id already exists"
                    )
                )
            }

            if !errors.isEmpty {
                return validationError(
                    operation: operation,
                    message: "Validation failed for note create",
                    fieldErrors: errors
                )
            }

            notesByID[normalized.id] = normalized
            if let encoded = try? VaultCellCodec.encode(normalized) {
                let version = advanceStateVersion(now: now)
                emitMutationEvent(
                    operation: operation,
                    recordKind: "note",
                    recordID: normalized.id,
                    result: encoded,
                    stateVersion: version,
                    emittedAtEpochMs: updatedAtEpochMs
                )
                return VaultCellCodec.success(operation: operation, payload: encoded)
            }

            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "encoding_failed",
                    message: "Failed to encode note response"
                )
            )
        }
    }

    private func handleNoteUpdate(value: ValueType) -> ValueType {
        let operation = "vault.note.update"

        let parsedNoteResult = parseNote(from: value)
        switch parsedNoteResult {
        case .failure:
            return validationError(
                operation: operation,
                message: "Invalid payload for note update",
                fieldErrors: [
                    VaultFieldError(
                        field: "note",
                        code: "invalid_payload",
                        message: "Expected VaultNoteRecord payload or object with note"
                    )
                ]
            )
        case .success(let parsedNote):
            let now = currentEpochMs()
            var normalized = normalize(note: parsedNote, now: now)
            var errors = validateRequiredFields(for: normalized)

            guard let existing = notesByID[normalized.id] else {
                return VaultCellCodec.error(
                    VaultCellErrorPayload(
                        operation: operation,
                        code: "not_found",
                        message: "Note not found for update",
                        fieldErrors: [
                            VaultFieldError(
                                field: "id",
                                code: "not_found",
                                message: "No note exists with this id"
                            )
                        ]
                    )
                )
            }

            if !errors.isEmpty {
                return validationError(
                    operation: operation,
                    message: "Validation failed for note update",
                    fieldErrors: errors
                )
            }

            normalized.createdAtEpochMs = existing.createdAtEpochMs
            normalized.updatedAtEpochMs = max(normalized.updatedAtEpochMs, existing.updatedAtEpochMs + 1)

            notesByID[normalized.id] = normalized
            if let encoded = try? VaultCellCodec.encode(normalized) {
                let version = advanceStateVersion(now: max(now, normalized.updatedAtEpochMs))
                emitMutationEvent(
                    operation: operation,
                    recordKind: "note",
                    recordID: normalized.id,
                    result: encoded,
                    stateVersion: version,
                    emittedAtEpochMs: updatedAtEpochMs
                )
                return VaultCellCodec.success(operation: operation, payload: encoded)
            }

            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "encoding_failed",
                    message: "Failed to encode note response"
                )
            )
        }
    }

    private func handleNoteGet(value: ValueType) -> ValueType {
        let operation = "vault.note.get"

        guard let id = parseNoteID(from: value), !id.isEmpty else {
            return validationError(
                operation: operation,
                message: "Missing note id",
                fieldErrors: [
                    VaultFieldError(field: "id", code: "missing", message: "Expected note id in payload")
                ]
            )
        }

        guard let note = notesByID[id] else {
            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "not_found",
                    message: "Note not found",
                    fieldErrors: [
                        VaultFieldError(field: "id", code: "not_found", message: "No note exists with this id")
                    ]
                )
            )
        }

        if let encoded = try? VaultCellCodec.encode(note) {
            return VaultCellCodec.success(operation: operation, payload: encoded)
        }

        return VaultCellCodec.error(
            VaultCellErrorPayload(
                operation: operation,
                code: "encoding_failed",
                message: "Failed to encode note response"
            )
        )
    }

    private func handleNoteList(value: ValueType) -> ValueType {
        let operation = "vault.note.list"

        let queryResult = parseQuery(from: value)
        switch queryResult {
        case .failure:
            return validationError(
                operation: operation,
                message: "Invalid query payload",
                fieldErrors: [
                    VaultFieldError(field: "query", code: "invalid_payload", message: "Expected VaultQuery payload")
                ]
            )
        case .success(let query):
            let listed = listNotes(query: query)
            return VaultCellCodec.success(operation: operation, payload: listed)
        }
    }

    private func handleLinkAdd(value: ValueType) -> ValueType {
        let operation = "vault.link.add"

        let linkResult = parseLink(from: value)
        switch linkResult {
        case .failure:
            return validationError(
                operation: operation,
                message: "Invalid payload for link add",
                fieldErrors: [
                    VaultFieldError(
                        field: "link",
                        code: "invalid_payload",
                        message: "Expected VaultLinkRecord payload or object with link"
                    )
                ]
            )
        case .success(let parsedLink):
            var errors: [VaultFieldError] = []
            let fromID = parsedLink.fromNoteID.trimmingCharacters(in: .whitespacesAndNewlines)
            let toID = parsedLink.toNoteID.trimmingCharacters(in: .whitespacesAndNewlines)

            if fromID.isEmpty {
                errors.append(VaultFieldError(field: "fromNoteID", code: "missing", message: "fromNoteID is required"))
            }
            if toID.isEmpty {
                errors.append(VaultFieldError(field: "toNoteID", code: "missing", message: "toNoteID is required"))
            }
            if notesByID[fromID] == nil {
                errors.append(VaultFieldError(field: "fromNoteID", code: "not_found", message: "source note does not exist"))
            }
            if notesByID[toID] == nil {
                errors.append(VaultFieldError(field: "toNoteID", code: "not_found", message: "target note does not exist"))
            }

            if !errors.isEmpty {
                return validationError(
                    operation: operation,
                    message: "Validation failed for link add",
                    fieldErrors: errors
                )
            }

            let relationship = parsedLink.relationship.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "wiki"
                : parsedLink.relationship
            let normalized = VaultLinkRecord(
                fromNoteID: fromID,
                toNoteID: toID,
                relationship: relationship,
                createdAtEpochMs: parsedLink.createdAtEpochMs > 0 ? parsedLink.createdAtEpochMs : currentEpochMs()
            )
            let key = linkKey(for: normalized)
            linksByKey[key] = normalized

            if let encoded = try? VaultCellCodec.encode(normalized) {
                let version = advanceStateVersion(now: max(currentEpochMs(), normalized.createdAtEpochMs))
                emitMutationEvent(
                    operation: operation,
                    recordKind: "link",
                    recordID: key,
                    result: encoded,
                    stateVersion: version,
                    emittedAtEpochMs: updatedAtEpochMs
                )
                return VaultCellCodec.success(operation: operation, payload: encoded)
            }

            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "encoding_failed",
                    message: "Failed to encode link response"
                )
            )
        }
    }

    private func handleLinksForward(value: ValueType) -> ValueType {
        let operation = "vault.links.forward"
        guard let id = parseNoteID(from: value), !id.isEmpty else {
            return validationError(
                operation: operation,
                message: "Missing note id",
                fieldErrors: [
                    VaultFieldError(field: "id", code: "missing", message: "Expected note id in payload")
                ]
            )
        }

        let links = linksByKey.values
            .filter { $0.fromNoteID == id }
            .sorted { lhs, rhs in
                if lhs.toNoteID != rhs.toNoteID { return lhs.toNoteID < rhs.toNoteID }
                if lhs.relationship != rhs.relationship { return lhs.relationship < rhs.relationship }
                return lhs.createdAtEpochMs < rhs.createdAtEpochMs
            }

        let encodedLinks = links.compactMap { try? VaultCellCodec.encode($0) }
        return VaultCellCodec.success(
            operation: operation,
            payload: .object([
                "id": .string(id),
                "count": .integer(encodedLinks.count),
                "links": .list(encodedLinks)
            ])
        )
    }

    private func handleBacklinks(value: ValueType) -> ValueType {
        let operation = "vault.links.backlinks"
        guard let id = parseNoteID(from: value), !id.isEmpty else {
            return validationError(
                operation: operation,
                message: "Missing note id",
                fieldErrors: [
                    VaultFieldError(field: "id", code: "missing", message: "Expected note id in payload")
                ]
            )
        }

        let links = linksByKey.values
            .filter { $0.toNoteID == id }
            .sorted { lhs, rhs in
                if lhs.fromNoteID != rhs.fromNoteID { return lhs.fromNoteID < rhs.fromNoteID }
                if lhs.relationship != rhs.relationship { return lhs.relationship < rhs.relationship }
                return lhs.createdAtEpochMs < rhs.createdAtEpochMs
            }

        let encodedLinks = links.compactMap { try? VaultCellCodec.encode($0) }
        return VaultCellCodec.success(
            operation: operation,
            payload: .object([
                "id": .string(id),
                "count": .integer(encodedLinks.count),
                "links": .list(encodedLinks)
            ])
        )
    }

    private func parseNote(from value: ValueType) -> Result<VaultNoteRecord, Error> {
        if case let .object(object) = value, let nested = object["note"] {
            if let decoded: VaultNoteRecord = try? VaultCellCodec.decode(nested) {
                return .success(decoded)
            }
        }

        if let decoded: VaultNoteRecord = try? VaultCellCodec.decode(value) {
            return .success(decoded)
        }

        return .failure(ParseError.invalidPayload)
    }

    private func parseLink(from value: ValueType) -> Result<VaultLinkRecord, Error> {
        if case let .object(object) = value, let nested = object["link"] {
            if let decoded: VaultLinkRecord = try? VaultCellCodec.decode(nested) {
                return .success(decoded)
            }
        }

        if let decoded: VaultLinkRecord = try? VaultCellCodec.decode(value) {
            return .success(decoded)
        }

        return .failure(ParseError.invalidPayload)
    }

    private func parseQuery(from value: ValueType) -> Result<VaultQuery, Error> {
        if case .null = value {
            return .success(VaultQuery())
        }

        if case let .object(object) = value,
           object.isEmpty {
            return .success(VaultQuery())
        }

        if case let .object(object) = value, let nested = object["query"] {
            if let decoded: VaultQuery = try? VaultCellCodec.decode(nested) {
                return .success(decoded)
            }
            return .failure(ParseError.invalidPayload)
        }

        if let decoded: VaultQuery = try? VaultCellCodec.decode(value) {
            return .success(decoded)
        }

        return .failure(ParseError.invalidPayload)
    }

    private func parseNoteID(from value: ValueType) -> String? {
        if let raw = VaultCellCodec.string(from: value) {
            return raw
        }

        if case let .object(object) = value {
            if let id = VaultCellCodec.string(from: object["id"]) {
                return id
            }
            if let id = VaultCellCodec.string(from: object["note_id"]) {
                return id
            }
        }

        return nil
    }

    private func listNotes(query: VaultQuery) -> ValueType {
        var items = Array(notesByID.values)

        if let ids = query.ids, !ids.isEmpty {
            let allowed = Set(ids)
            items.removeAll { !allowed.contains($0.id) }
        }

        if let tags = query.tags, !tags.isEmpty {
            let wanted = Set(tags.map { $0.lowercased() })
            items.removeAll { note in
                let noteTags = Set(note.tags.map { $0.lowercased() })
                return wanted.isDisjoint(with: noteTags)
            }
        }

        if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let needle = text.lowercased()
            items.removeAll { note in
                let haystack = "\(note.title)\n\(note.content)".lowercased()
                return !haystack.contains(needle)
            }
        }

        let sortBy = query.sortBy ?? .updatedAt
        let descending = query.descending ?? true

        items.sort { lhs, rhs in
            let ordered: Bool
            switch sortBy {
            case .id:
                ordered = lhs.id < rhs.id
            case .title:
                if lhs.title != rhs.title {
                    ordered = lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                } else {
                    ordered = lhs.id < rhs.id
                }
            case .createdAt:
                if lhs.createdAtEpochMs != rhs.createdAtEpochMs {
                    ordered = lhs.createdAtEpochMs < rhs.createdAtEpochMs
                } else {
                    ordered = lhs.id < rhs.id
                }
            case .updatedAt:
                if lhs.updatedAtEpochMs != rhs.updatedAtEpochMs {
                    ordered = lhs.updatedAtEpochMs < rhs.updatedAtEpochMs
                } else {
                    ordered = lhs.id < rhs.id
                }
            }
            return descending ? !ordered : ordered
        }

        let total = items.count
        let offset = max(query.offset ?? 0, 0)
        let limit = max(min(query.limit ?? 100, 1_000), 0)

        let paged: [VaultNoteRecord]
        if offset >= total {
            paged = []
        } else {
            let end = min(total, offset + limit)
            paged = Array(items[offset..<end])
        }

        let encodedItems = paged.compactMap { try? VaultCellCodec.encode($0) }
        return .object([
            "items": .list(encodedItems),
            "count": .integer(encodedItems.count),
            "total": .integer(total),
            "offset": .integer(offset),
            "limit": .integer(limit)
        ])
    }

    private func normalize(note: VaultNoteRecord, now: Int) -> VaultNoteRecord {
        var normalized = note
        normalized.id = note.id.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.content = note.content

        let sortedTags = Array(
            Set(note.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted()
        normalized.tags = sortedTags

        if normalized.slug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            normalized.slug = slugify(normalized.title)
        }

        if normalized.createdAtEpochMs <= 0 {
            normalized.createdAtEpochMs = now
        }
        if normalized.updatedAtEpochMs <= 0 {
            normalized.updatedAtEpochMs = now
        }
        return normalized
    }

    private func validateRequiredFields(for note: VaultNoteRecord) -> [VaultFieldError] {
        var errors: [VaultFieldError] = []
        if note.id.isEmpty {
            errors.append(VaultFieldError(field: "id", code: "missing", message: "id is required"))
        }
        if note.title.isEmpty {
            errors.append(VaultFieldError(field: "title", code: "missing", message: "title is required"))
        }
        return errors
    }

    private func validationError(operation: String, message: String, fieldErrors: [VaultFieldError]) -> ValueType {
        VaultCellCodec.error(
            VaultCellErrorPayload(
                operation: operation,
                code: "validation_error",
                message: message,
                fieldErrors: fieldErrors
            )
        )
    }

    private func slugify(_ title: String) -> String {
        let cleaned = title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "note-\(UUID().uuidString.lowercased())" : cleaned
    }

    private func linkKey(for link: VaultLinkRecord) -> String {
        "\(link.fromNoteID)|\(link.relationship)|\(link.toNoteID)"
    }

    private func sortedNotesSnapshot() -> [VaultNoteRecord] {
        notesByID.values.sorted { lhs, rhs in
            if lhs.updatedAtEpochMs != rhs.updatedAtEpochMs {
                return lhs.updatedAtEpochMs > rhs.updatedAtEpochMs
            }
            return lhs.id < rhs.id
        }
    }

    private func sortedLinksSnapshot() -> [VaultLinkRecord] {
        linksByKey.values.sorted { lhs, rhs in
            if lhs.fromNoteID != rhs.fromNoteID { return lhs.fromNoteID < rhs.fromNoteID }
            if lhs.relationship != rhs.relationship { return lhs.relationship < rhs.relationship }
            if lhs.toNoteID != rhs.toNoteID { return lhs.toNoteID < rhs.toNoteID }
            return lhs.createdAtEpochMs < rhs.createdAtEpochMs
        }
    }

    private static func operationsList() -> [String] {
        [
            "vault.note.create",
            "vault.note.update",
            "vault.note.get",
            "vault.note.list",
            "vault.link.add",
            "vault.links.forward",
            "vault.links.backlinks"
        ]
    }

    private func advanceStateVersion(now: Int) -> Int {
        stateVersion += 1
        updatedAtEpochMs = max(updatedAtEpochMs + 1, now)
        return stateVersion
    }

    private func emitMutationEvent(
        operation: String,
        recordKind: String,
        recordID: String,
        result: ValueType,
        stateVersion: Int,
        emittedAtEpochMs: Int
    ) {
        let mutation = VaultMutationEvent(
            stateVersion: stateVersion,
            operation: operation,
            recordKind: recordKind,
            recordID: recordID,
            result: result,
            emittedAtEpochMs: emittedAtEpochMs
        )

        guard case let .object(content) = try? VaultCellCodec.encode(mutation) else {
            return
        }

        var flowElement = FlowElement(
            title: "VaultMutationEvent",
            content: .object(content),
            properties: FlowElement.Properties(type: .event, contentType: .object)
        )
        flowElement.topic = "vault.mutation"
        flowElement.origin = uuid
        pushFlowElement(flowElement, requester: owner)
    }

    private func currentEpochMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func stateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "cell": ExploreContract.schema(type: "string"),
                "schemaVersion": ExploreContract.schema(type: "string"),
                "stateVersion": ExploreContract.schema(type: "integer"),
                "noteCount": ExploreContract.schema(type: "integer"),
                "linkCount": ExploreContract.schema(type: "integer"),
                "notes": ExploreContract.listSchema(item: Self.noteRecordSchema()),
                "links": ExploreContract.listSchema(item: Self.linkRecordSchema()),
                "operations": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "updatedAtEpochMs": ExploreContract.schema(type: "integer"),
                "note_count": ExploreContract.schema(type: "integer"),
                "link_count": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: [
                "status",
                "cell",
                "schemaVersion",
                "stateVersion",
                "noteCount",
                "linkCount",
                "notes",
                "links",
                "operations",
                "updatedAtEpochMs"
            ],
            description: "Vault state payload."
        )
    }

    private static func noteRecordSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "slug": ExploreContract.schema(type: "string"),
                "title": ExploreContract.schema(type: "string"),
                "content": ExploreContract.schema(type: "string"),
                "tags": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "createdAtEpochMs": ExploreContract.schema(type: "integer"),
                "updatedAtEpochMs": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["id", "title", "content", "tags", "createdAtEpochMs", "updatedAtEpochMs"],
            description: "Vault note record."
        )
    }

    private static func linkRecordSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "fromNoteID": ExploreContract.schema(type: "string"),
                "toNoteID": ExploreContract.schema(type: "string"),
                "relationship": ExploreContract.schema(type: "string"),
                "createdAtEpochMs": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["fromNoteID", "toNoteID", "relationship", "createdAtEpochMs"],
            description: "Vault note link record."
        )
    }

    private static func fieldErrorSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "field": ExploreContract.schema(type: "string"),
                "code": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["field", "code", "message"],
            description: "Field-level validation error."
        )
    }

    private static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "code": ExploreContract.schema(type: "string"),
                "message": ExploreContract.schema(type: "string"),
                "field_errors": ExploreContract.listSchema(item: fieldErrorSchema())
            ],
            requiredKeys: ["status", "operation", "code", "message", "field_errors"],
            description: "Structured vault error response."
        )
    }

    private static func successEnvelopeSchema(operation: String, result: ValueType) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "result": result
            ],
            requiredKeys: ["status", "operation", "result"],
            description: "Successful vault operation response."
        )
    }

    private static func notePayloadSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                noteRecordSchema(),
                ExploreContract.objectSchema(
                    properties: [
                        "note": noteRecordSchema()
                    ],
                    requiredKeys: ["note"],
                    description: "Nested note payload."
                )
            ],
            description: "Accepts a raw VaultNoteRecord or an object with `note`."
        )
    }

    private static func noteIdentifierSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Note identifier shortcut."),
                ExploreContract.objectSchema(
                    properties: [
                        "id": ExploreContract.schema(type: "string"),
                        "note_id": ExploreContract.schema(type: "string")
                    ],
                    description: "Object payload with note identifier."
                )
            ],
            description: "Accepts a note id string or an object with `id` or `note_id`."
        )
    }

    private static func noteListInputSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                .null,
                querySchema(),
                ExploreContract.objectSchema(
                    properties: [
                        "query": querySchema()
                    ],
                    requiredKeys: ["query"],
                    description: "Nested query payload."
                )
            ],
            description: "Accepts null, a raw VaultQuery object, or an object with `query`."
        )
    }

    private static func querySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "ids": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "text": ExploreContract.schema(type: "string"),
                "tags": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "limit": ExploreContract.schema(type: "integer"),
                "offset": ExploreContract.schema(type: "integer"),
                "sortBy": ExploreContract.schema(type: "string"),
                "descending": ExploreContract.schema(type: "bool")
            ],
            description: "Vault list query."
        )
    }

    private static func noteListResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "items": ExploreContract.listSchema(item: noteRecordSchema()),
                "count": ExploreContract.schema(type: "integer"),
                "total": ExploreContract.schema(type: "integer"),
                "offset": ExploreContract.schema(type: "integer"),
                "limit": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["items", "count", "total", "offset", "limit"],
            description: "Paged vault note list."
        )
    }

    private static func linkPayloadSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                linkRecordSchema(),
                ExploreContract.objectSchema(
                    properties: [
                        "link": linkRecordSchema()
                    ],
                    requiredKeys: ["link"],
                    description: "Nested link payload."
                )
            ],
            description: "Accepts a raw VaultLinkRecord or an object with `link`."
        )
    }

    private static func linksResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "links": ExploreContract.listSchema(item: linkRecordSchema())
            ],
            requiredKeys: ["id", "count", "links"],
            description: "Vault link query result."
        )
    }

    private static func noteMutationResponseSchema(operation: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: operation, result: noteRecordSchema()),
                errorSchema(operation: operation)
            ],
            description: "Vault note mutation response."
        )
    }

    private static func noteLookupResponseSchema(operation: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: operation, result: noteRecordSchema()),
                errorSchema(operation: operation)
            ],
            description: "Vault note lookup response."
        )
    }

    private static func noteListResponseSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: "vault.note.list", result: noteListResultSchema()),
                errorSchema(operation: "vault.note.list")
            ],
            description: "Vault note list response."
        )
    }

    private static func linkMutationResponseSchema(operation: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: operation, result: linkRecordSchema()),
                errorSchema(operation: operation)
            ],
            description: "Vault link mutation response."
        )
    }

    private static func linksQueryResponseSchema(operation: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: operation, result: linksResultSchema()),
                errorSchema(operation: operation)
            ],
            description: "Vault links query response."
        )
    }
}

private enum ParseError: Error {
    case invalidPayload
}
