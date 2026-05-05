// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public final class GraphIndexCell: GeneralCell {
    private var notesByID: [String: String]
    private var outgoing: [String: Set<String>]
    private var incoming: [String: Set<String>]

    private enum CodingKeys: String, CodingKey {
        case notesByID
        case outgoing
        case incoming
        case generalCell
    }

    private static let wikiLinkRegex = try? NSRegularExpression(
        pattern: #"\[\[([^\[\]\|#]+)(?:\|[^\]]*)?\]\]"#
    )

    public required init(owner: Identity) async {
        self.notesByID = [:]
        self.outgoing = [:]
        self.incoming = [:]
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.notesByID = try container.decodeIfPresent([String: String].self, forKey: .notesByID) ?? [:]
        self.outgoing = try container.decodeIfPresent([String: Set<String>].self, forKey: .outgoing) ?? [:]
        self.incoming = try container.decodeIfPresent([String: Set<String>].self, forKey: .incoming) ?? [:]
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
        try container.encode(outgoing, forKey: .outgoing)
        try container.encode(incoming, forKey: .incoming)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "graph")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "graph.state") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "graph", for: requester) else { return .string("denied") }
            return self.statePayload()
        }

        await addInterceptForSet(requester: owner, key: "graph.reindex") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "graph", for: requester) else { return .string("denied") }
            return self.handleReindex(value: value)
        }

        await addInterceptForSet(requester: owner, key: "graph.outgoing") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "graph", for: requester) else { return .string("denied") }
            return self.handleOutgoing(value: value)
        }

        await addInterceptForSet(requester: owner, key: "graph.incoming") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "graph", for: requester) else { return .string("denied") }
            return self.handleIncoming(value: value)
        }

        await addInterceptForSet(requester: owner, key: "graph.neighbors") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "graph", for: requester) else { return .string("denied") }
            return self.handleNeighbors(value: value)
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "graph.state",
            method: .get,
            input: .null,
            returns: Self.stateSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Reports graph index node and edge counts plus the supported graph operations.")
        )

        await registerExploreContract(
            requester: requester,
            key: "graph.reindex",
            method: .set,
            input: Self.reindexInputSchema(),
            returns: Self.reindexResponseSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Rebuilds the graph index from note documents containing wiki links.")
        )

        await registerExploreContract(
            requester: requester,
            key: "graph.outgoing",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.linksResponseSchema(operation: "graph.outgoing"),
            permissions: ["-w--"],
            required: true,
            description: .string("Returns outgoing graph links for a note id.")
        )

        await registerExploreContract(
            requester: requester,
            key: "graph.incoming",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.linksResponseSchema(operation: "graph.incoming"),
            permissions: ["-w--"],
            required: true,
            description: .string("Returns incoming graph links for a note id.")
        )

        await registerExploreContract(
            requester: requester,
            key: "graph.neighbors",
            method: .set,
            input: Self.noteIdentifierSchema(),
            returns: Self.neighborsResponseSchema(),
            permissions: ["-w--"],
            required: true,
            description: .string("Returns the combined neighbors for a note id.")
        )
    }

    private func statePayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "cell": .string("GraphIndexCell"),
            "node_count": .integer(notesByID.count),
            "edge_count": .integer(totalEdgeCount()),
            "operations": .list([
                .string("graph.reindex"),
                .string("graph.outgoing"),
                .string("graph.incoming"),
                .string("graph.neighbors")
            ])
        ])
    }

    private func handleReindex(value: ValueType) -> ValueType {
        let operation = "graph.reindex"
        let documentsResult = parseDocuments(from: value)
        switch documentsResult {
        case .failure:
            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Expected payload with notes list",
                    fieldErrors: [
                        VaultFieldError(field: "notes", code: "invalid_payload", message: "Expected list of note documents")
                    ]
                )
            )
        case .success(let documents):
            var notes: [String: String] = [:]
            var newOutgoing: [String: Set<String>] = [:]
            var newIncoming: [String: Set<String>] = [:]

            for doc in documents {
                let id = doc.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty {
                    notes[id] = doc.content
                }
            }

            let noteIDs = Set(notes.keys)
            for id in notes.keys {
                newOutgoing[id] = []
                newIncoming[id] = []
            }

            for (id, content) in notes {
                let rawTargets = extractWikiLinks(from: content)
                let targets = rawTargets.filter { noteIDs.contains($0) }
                for target in targets {
                    newOutgoing[id, default: []].insert(target)
                    newIncoming[target, default: []].insert(id)
                }
            }

            notesByID = notes
            outgoing = newOutgoing
            incoming = newIncoming

            return VaultCellCodec.success(
                operation: operation,
                payload: .object([
                    "node_count": .integer(notesByID.count),
                    "edge_count": .integer(totalEdgeCount())
                ])
            )
        }
    }

    private func handleOutgoing(value: ValueType) -> ValueType {
        let operation = "graph.outgoing"
        return nodeQuery(
            value: value,
            operation: operation,
            linksProvider: { id in
                Array(outgoing[id] ?? []).sorted()
            }
        )
    }

    private func handleIncoming(value: ValueType) -> ValueType {
        let operation = "graph.incoming"
        return nodeQuery(
            value: value,
            operation: operation,
            linksProvider: { id in
                Array(incoming[id] ?? []).sorted()
            }
        )
    }

    private func handleNeighbors(value: ValueType) -> ValueType {
        let operation = "graph.neighbors"
        guard let id = parseNodeID(from: value), !id.isEmpty else {
            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Missing node id",
                    fieldErrors: [
                        VaultFieldError(field: "id", code: "missing", message: "Expected node id in payload")
                    ]
                )
            )
        }

        let outgoingLinks = outgoing[id] ?? []
        let incomingLinks = incoming[id] ?? []
        let neighbors = Array(outgoingLinks.union(incomingLinks)).sorted()

        return VaultCellCodec.success(
            operation: operation,
            payload: .object([
                "id": .string(id),
                "count": .integer(neighbors.count),
                "neighbors": .list(neighbors.map { .string($0) })
            ])
        )
    }

    private func nodeQuery(
        value: ValueType,
        operation: String,
        linksProvider: (String) -> [String]
    ) -> ValueType {
        guard let id = parseNodeID(from: value), !id.isEmpty else {
            return VaultCellCodec.error(
                VaultCellErrorPayload(
                    operation: operation,
                    code: "validation_error",
                    message: "Missing node id",
                    fieldErrors: [
                        VaultFieldError(field: "id", code: "missing", message: "Expected node id in payload")
                    ]
                )
            )
        }

        let links = linksProvider(id)
        return VaultCellCodec.success(
            operation: operation,
            payload: .object([
                "id": .string(id),
                "count": .integer(links.count),
                "links": .list(links.map { .string($0) })
            ])
        )
    }

    private func parseNodeID(from value: ValueType) -> String? {
        if let direct = VaultCellCodec.string(from: value) {
            return direct
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

    private func parseDocuments(from value: ValueType) -> Result<[GraphDocument], Error> {
        if case let .object(object) = value,
           let nested = object["notes"],
           let docs: [GraphDocument] = try? VaultCellCodec.decode(nested) {
            return .success(docs)
        }

        if let docs: [GraphDocument] = try? VaultCellCodec.decode(value) {
            return .success(docs)
        }

        return .failure(GraphParseError.invalidPayload)
    }

    private func extractWikiLinks(from markdown: String) -> [String] {
        guard let regex = Self.wikiLinkRegex else { return [] }
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        let matches = regex.matches(in: markdown, options: [], range: range)

        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound,
                  let swiftRange = Range(tokenRange, in: markdown) else {
                return nil
            }
            let token = markdown[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    }

    private func totalEdgeCount() -> Int {
        outgoing.values.reduce(0) { partial, set in
            partial + set.count
        }
    }

    private static func stateSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "cell": ExploreContract.schema(type: "string"),
                "node_count": ExploreContract.schema(type: "integer"),
                "edge_count": ExploreContract.schema(type: "integer"),
                "operations": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["status", "cell", "node_count", "edge_count", "operations"],
            description: "Graph index state payload."
        )
    }

    private static func graphDocumentSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "content": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["id", "content"],
            description: "Graph note document to be indexed."
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
            description: "Structured graph operation error."
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
            description: "Successful graph operation response."
        )
    }

    private static func reindexInputSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                ExploreContract.listSchema(item: graphDocumentSchema()),
                ExploreContract.objectSchema(
                    properties: [
                        "notes": ExploreContract.listSchema(item: graphDocumentSchema())
                    ],
                    requiredKeys: ["notes"],
                    description: "Nested graph reindex payload."
                )
            ],
            description: "Accepts a raw list of note documents or an object containing `notes`."
        )
    }

    private static func reindexResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "node_count": ExploreContract.schema(type: "integer"),
                "edge_count": ExploreContract.schema(type: "integer")
            ],
            requiredKeys: ["node_count", "edge_count"],
            description: "Graph reindex counts."
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

    private static func linksResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "links": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["id", "count", "links"],
            description: "Graph links query result."
        )
    }

    private static func neighborsResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "id": ExploreContract.schema(type: "string"),
                "count": ExploreContract.schema(type: "integer"),
                "neighbors": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["id", "count", "neighbors"],
            description: "Graph neighbors query result."
        )
    }

    private static func reindexResponseSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: "graph.reindex", result: reindexResultSchema()),
                errorSchema(operation: "graph.reindex")
            ],
            description: "Graph reindex response."
        )
    }

    private static func linksResponseSchema(operation: String) -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: operation, result: linksResultSchema()),
                errorSchema(operation: operation)
            ],
            description: "Graph links query response."
        )
    }

    private static func neighborsResponseSchema() -> ValueType {
        ExploreContract.oneOfSchema(
            options: [
                successEnvelopeSchema(operation: "graph.neighbors", result: neighborsResultSchema()),
                errorSchema(operation: "graph.neighbors")
            ],
            description: "Graph neighbors query response."
        )
    }
}

private struct GraphDocument: Codable, Equatable {
    var id: String
    var content: String
}

private enum GraphParseError: Error {
    case invalidPayload
}
