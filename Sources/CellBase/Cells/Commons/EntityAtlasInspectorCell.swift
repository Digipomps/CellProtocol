// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public final class EntityAtlasInspectorCell: GeneralCell {
    private var service = EntityAtlasService()

    private enum CodingKeys: String, CodingKey {
        case generalCell
    }

    private enum AtlasInspectorError: LocalizedError {
        case resolverUnavailable
        case invalidPayload(operation: String, message: String)

        var errorDescription: String? {
            switch self {
            case .resolverUnavailable:
                return "CellBase.defaultCellResolver is not configured."
            case let .invalidPayload(operation, message):
                return "\(operation): \(message)"
            }
        }
    }

    private struct PurposeRequest: Codable {
        var purposeRef: String

        enum CodingKeys: String, CodingKey {
            case purposeRef = "purpose_ref"
        }
    }

    private struct CellIDRequest: Codable {
        var cellID: String

        enum CodingKeys: String, CodingKey {
            case cellID = "cell_id"
        }
    }

    private struct ExportPolicyRequest: Codable {
        var includeDocumentBodyPreviews: Bool?
        var documentBodyPreviewCharacterLimit: Int?
        var includeRelationExplanations: Bool?

        enum CodingKeys: String, CodingKey {
            case includeDocumentBodyPreviews = "include_document_body_previews"
            case documentBodyPreviewCharacterLimit = "document_body_preview_character_limit"
            case includeRelationExplanations = "include_relation_explanations"
        }
    }

    public required init(owner: Identity) async {
        await super.init(owner: owner)
        await setupPermissions(owner: owner)
        await setupKeys(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        Task {
            await setupPermissions(owner: self.owner)
            await setupKeys(owner: self.owner)
        }
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
    }

    private func setupPermissions(owner: Identity) async {
        agreementTemplate.addGrant("rw--", for: "atlas")
    }

    private func setupKeys(owner: Identity) async {
        await addInterceptForGet(requester: owner, key: "atlas.status") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "atlas", for: requester) else { return .string("denied") }
            return self.statusPayload()
        }

        await addInterceptForGet(requester: owner, key: "atlas.samples.requests") { [weak self] _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("r---", at: "atlas", for: requester) else { return .string("denied") }
            return self.samplesPayload()
        }

        await addInterceptForSet(requester: owner, key: "atlas.snapshot") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.snapshotPayload(requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.export.redactedJSON") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.exportPayload(format: "json", value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.export.redactedMarkdown") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.exportPayload(format: "markdown", value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.cellsForPurpose") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.cellsForPurposePayload(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.scaffoldCandidates") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.scaffoldCandidatesPayload(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.purposesForCell") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.purposesForCellPayload(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.cellsRequiringCredentials") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.cellsRequiringCredentialsPayload(requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.knowledgeCells") { [weak self] _, _, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.knowledgeCellsPayload(requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.dependencies") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.dependenciesPayload(value: value, requester: requester)
        }

        await addInterceptForSet(requester: owner, key: "atlas.query.coverage") { [weak self] _, value, requester in
            guard let self else { return .string("failure") }
            guard await self.validateAccess("-w--", at: "atlas", for: requester) else { return .string("denied") }
            return await self.coveragePayload(value: value, requester: requester)
        }

        await registerContracts(requester: owner)
    }

    private func registerContracts(requester: Identity) async {
        await registerExploreContract(
            requester: requester,
            key: "atlas.status",
            method: .get,
            input: .null,
            returns: Self.statusSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Reports atlas inspector availability, runtime dependencies, and supported operations.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.samples.requests",
            method: .get,
            input: .null,
            returns: Self.samplesSchema(),
            permissions: ["r---"],
            required: false,
            description: .string("Returns sample payloads for atlas snapshot, export, and query operations.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.snapshot",
            method: .set,
            input: .null,
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: Self.snapshotSchema()),
                    Self.errorSchema(operation: "atlas.snapshot")
                ],
                description: "Returns a snapshot of the current entity atlas."
            ),
            permissions: ["-w--"],
            required: false,
            description: .string("Builds a runtime entity atlas snapshot from the active resolver and optional Vault documents.")
        )

        let exportInput = ExploreContract.oneOfSchema(
            options: [
                .null,
                Self.exportPolicySchema()
            ],
            description: "Optional redaction/export policy overrides."
        )
        let exportResult = ExploreContract.oneOfSchema(
            options: [
                Self.resultEnvelopeSchema(result: Self.exportResultSchema()),
                Self.errorSchema(operation: "atlas.export")
            ],
            description: "Returns a redacted atlas export."
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.export.redactedJSON",
            method: .set,
            input: exportInput,
            returns: exportResult,
            permissions: ["-w--"],
            required: false,
            description: .string("Exports the current atlas snapshot as redacted JSON.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.export.redactedMarkdown",
            method: .set,
            input: exportInput,
            returns: exportResult,
            permissions: ["-w--"],
            required: false,
            description: .string("Exports the current atlas snapshot as redacted Markdown.")
        )

        let purposeInput = ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Purpose reference shortcut."),
                Self.purposeRequestSchema()
            ],
            description: "Accepts a raw purpose ref string or an object with `purpose_ref`."
        )
        let cellInput = ExploreContract.oneOfSchema(
            options: [
                ExploreContract.schema(type: "string", description: "Cell identifier shortcut."),
                Self.cellIDRequestSchema()
            ],
            description: "Accepts a raw cell id string or an object with `cell_id`."
        )
        let cellListResult = ExploreContract.oneOfSchema(
            options: [
                Self.resultEnvelopeSchema(result: ExploreContract.listSchema(item: Self.cellRecordSchema(), description: "Entity atlas cell records.")),
                Self.errorSchema(operation: "atlas.query")
            ],
            description: "Returns a list of atlas cell records."
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.cellsForPurpose",
            method: .set,
            input: purposeInput,
            returns: cellListResult,
            permissions: ["-w--"],
            required: true,
            description: .string("Returns cells that advertise coverage for the requested purpose.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.scaffoldCandidates",
            method: .set,
            input: purposeInput,
            returns: cellListResult,
            permissions: ["-w--"],
            required: true,
            description: .string("Returns scaffold-available cells that cover the requested purpose without current ownership.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.purposesForCell",
            method: .set,
            input: cellInput,
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: ExploreContract.listSchema(item: ExploreContract.schema(type: "string"), description: "Purpose refs.")),
                    Self.errorSchema(operation: "atlas.query.purposesForCell")
                ],
                description: "Returns purpose refs for a given cell."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Returns advertised purposes for a given cell id.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.cellsRequiringCredentials",
            method: .set,
            input: .null,
            returns: cellListResult,
            permissions: ["-w--"],
            required: false,
            description: .string("Returns cells that explicitly require credential classes.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.knowledgeCells",
            method: .set,
            input: .null,
            returns: cellListResult,
            permissions: ["-w--"],
            required: false,
            description: .string("Returns cells that explicitly know about, describe, or index other cells.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.dependencies",
            method: .set,
            input: cellInput,
            returns: cellListResult,
            permissions: ["-w--"],
            required: true,
            description: .string("Returns dependencies for a given cell id.")
        )

        await registerExploreContract(
            requester: requester,
            key: "atlas.query.coverage",
            method: .set,
            input: purposeInput,
            returns: ExploreContract.oneOfSchema(
                options: [
                    Self.resultEnvelopeSchema(result: Self.coverageSchema()),
                    Self.errorSchema(operation: "atlas.query.coverage")
                ],
                description: "Returns a purpose coverage explanation."
            ),
            permissions: ["-w--"],
            required: true,
            description: .string("Explains whether a purpose is covered, partial, or blocked in the current topology.")
        )
    }

    private func statusPayload() -> ValueType {
        .object([
            "cell": .string("EntityAtlasInspectorCell"),
            "resolver_available": .bool(CellBase.defaultCellResolver != nil),
            "identity_vault_available": .bool(CellBase.defaultIdentityVault != nil),
            "operations": .list([
                .string("atlas.snapshot"),
                .string("atlas.export.redactedJSON"),
                .string("atlas.export.redactedMarkdown"),
                .string("atlas.query.cellsForPurpose"),
                .string("atlas.query.scaffoldCandidates"),
                .string("atlas.query.purposesForCell"),
                .string("atlas.query.cellsRequiringCredentials"),
                .string("atlas.query.knowledgeCells"),
                .string("atlas.query.dependencies"),
                .string("atlas.query.coverage"),
                .string("atlas.samples.requests")
            ])
        ])
    }

    private func samplesPayload() -> ValueType {
        .object([
            "status": .string("ok"),
            "items": .list([
                .object(["operation": .string("atlas.snapshot"), "payload": .null]),
                .object([
                    "operation": .string("atlas.export.redactedJSON"),
                    "payload": .object([
                        "include_document_body_previews": .bool(false),
                        "include_relation_explanations": .bool(true)
                    ])
                ]),
                .object([
                    "operation": .string("atlas.query.cellsForPurpose"),
                    "payload": .object(["purpose_ref": .string("purpose.net-positive-contribution")])
                ]),
                .object([
                    "operation": .string("atlas.query.coverage"),
                    "payload": .string("purpose.human-equal-worth")
                ]),
                .object([
                    "operation": .string("atlas.query.dependencies"),
                    "payload": .object(["cell_id": .string("cell:///Graph")])
                ])
            ])
        ])
    }

    private func snapshotPayload(requester: Identity) async -> ValueType {
        do {
            let snapshot = try await buildSnapshot(requester: requester)
            return CommonsCellCodec.success(try CommonsCellCodec.encode(snapshot))
        } catch {
            return CommonsCellCodec.error(error, operation: "atlas.snapshot")
        }
    }

    private func exportPayload(format: String, value: ValueType, requester: Identity) async -> ValueType {
        do {
            let snapshot = try await buildSnapshot(requester: requester)
            let policy = try parseExportPolicy(from: value)
            let content: String
            switch format {
            case "json":
                content = try service.exportRedactedJSON(snapshot: snapshot, policy: policy)
            case "markdown":
                content = service.exportRedactedMarkdown(snapshot: snapshot, policy: policy)
            default:
                throw AtlasInspectorError.invalidPayload(operation: "atlas.export", message: "Unknown export format \(format).")
            }
            return CommonsCellCodec.success(.object([
                "format": .string(format),
                "content": .string(content)
            ]))
        } catch {
            return CommonsCellCodec.error(error, operation: "atlas.export.redacted\(format.uppercased())")
        }
    }

    private func cellsForPurposePayload(value: ValueType, requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.cellsForPurpose", requester: requester) { snapshot, projection in
            let purposeRef = try parsePurposeRef(from: value, operation: "atlas.query.cellsForPurpose")
            return try CommonsCellCodec.encode(projection.cells(forPurpose: purposeRef, in: snapshot))
        }
    }

    private func scaffoldCandidatesPayload(value: ValueType, requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.scaffoldCandidates", requester: requester) { snapshot, projection in
            let purposeRef = try parsePurposeRef(from: value, operation: "atlas.query.scaffoldCandidates")
            return try CommonsCellCodec.encode(projection.scaffoldCandidates(forPurpose: purposeRef, in: snapshot))
        }
    }

    private func purposesForCellPayload(value: ValueType, requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.purposesForCell", requester: requester) { snapshot, projection in
            let cellID = try parseCellID(from: value, operation: "atlas.query.purposesForCell")
            return try CommonsCellCodec.encode(projection.purposes(forCellID: cellID, in: snapshot))
        }
    }

    private func cellsRequiringCredentialsPayload(requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.cellsRequiringCredentials", requester: requester) { snapshot, projection in
            try CommonsCellCodec.encode(projection.cellsRequiringCredentials(in: snapshot))
        }
    }

    private func knowledgeCellsPayload(requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.knowledgeCells", requester: requester) { snapshot, projection in
            try CommonsCellCodec.encode(projection.cellsKnowingAboutOtherCells(in: snapshot))
        }
    }

    private func dependenciesPayload(value: ValueType, requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.dependencies", requester: requester) { snapshot, projection in
            let cellID = try parseCellID(from: value, operation: "atlas.query.dependencies")
            return try CommonsCellCodec.encode(projection.dependencies(forCellID: cellID, in: snapshot))
        }
    }

    private func coveragePayload(value: ValueType, requester: Identity) async -> ValueType {
        await withSnapshot(operation: "atlas.query.coverage", requester: requester) { snapshot, projection in
            let purposeRef = try parsePurposeRef(from: value, operation: "atlas.query.coverage")
            return try CommonsCellCodec.encode(projection.explainCoverage(for: purposeRef, in: snapshot))
        }
    }

    private func withSnapshot(
        operation: String,
        requester: Identity,
        body: (EntityAtlasSnapshot, EntityAtlasProjection) throws -> ValueType
    ) async -> ValueType {
        do {
            let snapshot = try await buildSnapshot(requester: requester)
            return CommonsCellCodec.success(try body(snapshot, service.projection))
        } catch {
            return CommonsCellCodec.error(error, operation: operation)
        }
    }

    private func buildSnapshot(requester: Identity) async throws -> EntityAtlasSnapshot {
        guard let resolver = CellBase.defaultCellResolver else {
            throw AtlasInspectorError.resolverUnavailable
        }
        let vaultCell = try? await resolver.cellAtEndpoint(endpoint: "cell:///Vault", requester: requester) as? VaultCell
        return try await service.buildSnapshot(
            resolver: resolver,
            requester: requester,
            vaultCell: vaultCell
        )
    }

    private func parsePurposeRef(from value: ValueType, operation: String) throws -> String {
        if let raw = CommonsCellCodec.string(from: value) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AtlasInspectorError.invalidPayload(operation: operation, message: "purpose_ref must not be empty.")
            }
            return trimmed
        }

        let request = try CommonsCellCodec.decode(value, as: PurposeRequest.self)
        let trimmed = request.purposeRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AtlasInspectorError.invalidPayload(operation: operation, message: "purpose_ref must not be empty.")
        }
        return trimmed
    }

    private func parseCellID(from value: ValueType, operation: String) throws -> String {
        if let raw = CommonsCellCodec.string(from: value) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AtlasInspectorError.invalidPayload(operation: operation, message: "cell_id must not be empty.")
            }
            return trimmed
        }

        let request = try CommonsCellCodec.decode(value, as: CellIDRequest.self)
        let trimmed = request.cellID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AtlasInspectorError.invalidPayload(operation: operation, message: "cell_id must not be empty.")
        }
        return trimmed
    }

    private func parseExportPolicy(from value: ValueType) throws -> EntityAtlasExportPolicy {
        if case .null = value {
            return EntityAtlasExportPolicy()
        }
        let request = try CommonsCellCodec.decode(value, as: ExportPolicyRequest.self)
        return EntityAtlasExportPolicy(
            includeDocumentBodyPreviews: request.includeDocumentBodyPreviews ?? false,
            documentBodyPreviewCharacterLimit: request.documentBodyPreviewCharacterLimit ?? 80,
            includeRelationExplanations: request.includeRelationExplanations ?? true
        )
    }

    private static func statusSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "cell": ExploreContract.schema(type: "string"),
                "resolver_available": ExploreContract.schema(type: "boolean"),
                "identity_vault_available": ExploreContract.schema(type: "boolean"),
                "operations": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["cell", "resolver_available", "identity_vault_available", "operations"]
        )
    }

    private static func samplesSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "items": ExploreContract.listSchema(
                    item: ExploreContract.objectSchema(
                        properties: [
                            "operation": ExploreContract.schema(type: "string"),
                            "payload": ExploreContract.oneOfSchema(
                                options: [
                                    .null,
                                    ExploreContract.schema(type: "string"),
                                    ExploreContract.schema(type: "object")
                                ],
                                description: "Operation payload example."
                            )
                        ],
                        requiredKeys: ["operation", "payload"]
                    )
                )
            ],
            requiredKeys: ["status", "items"]
        )
    }

    private static func resultEnvelopeSchema(result: ValueType) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "result": result
            ],
            requiredKeys: ["status", "result"]
        )
    }

    private static func errorSchema(operation: String) -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "status": ExploreContract.schema(type: "string"),
                "operation": ExploreContract.schema(type: "string", description: operation),
                "message": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["status", "operation", "message"]
        )
    }

    private static func snapshotSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "generatedAtEpochMs": ExploreContract.schema(type: "integer"),
                "cells": ExploreContract.listSchema(item: Self.cellRecordSchema()),
                "scaffolds": ExploreContract.listSchema(item: ExploreContract.schema(type: "object")),
                "relations": ExploreContract.listSchema(item: ExploreContract.schema(type: "object"))
            ],
            requiredKeys: ["generatedAtEpochMs", "cells", "scaffolds", "relations"]
        )
    }

    private static func exportPolicySchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "include_document_body_previews": ExploreContract.schema(type: "boolean"),
                "document_body_preview_character_limit": ExploreContract.schema(type: "integer"),
                "include_relation_explanations": ExploreContract.schema(type: "boolean")
            ],
            requiredKeys: []
        )
    }

    private static func exportResultSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "format": ExploreContract.schema(type: "string"),
                "content": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["format", "content"]
        )
    }

    private static func purposeRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "purpose_ref": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["purpose_ref"]
        )
    }

    private static func cellIDRequestSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "cell_id": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["cell_id"]
        )
    }

    private static func cellRecordSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "cellID": ExploreContract.schema(type: "string"),
                "name": ExploreContract.schema(type: "string"),
                "endpoint": ExploreContract.schema(type: "string"),
                "purposes": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "capabilities": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "requiredCredentialClasses": ExploreContract.listSchema(item: ExploreContract.schema(type: "string"))
            ],
            requiredKeys: ["cellID", "name", "endpoint", "purposes", "capabilities", "requiredCredentialClasses"]
        )
    }

    private static func coverageSchema() -> ValueType {
        ExploreContract.objectSchema(
            properties: [
                "purposeRef": ExploreContract.schema(type: "string"),
                "status": ExploreContract.schema(type: "string"),
                "supportingCellIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "scaffoldCandidateCellIDs": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "blockedReasons": ExploreContract.listSchema(item: ExploreContract.schema(type: "string")),
                "explanation": ExploreContract.schema(type: "string")
            ],
            requiredKeys: ["purposeRef", "status", "supportingCellIDs", "scaffoldCandidateCellIDs", "blockedReasons", "explanation"]
        )
    }
}
