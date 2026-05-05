// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct EntityAtlasService {
    public var repository: AtlasVaultDocumentRepository
    public var projection: EntityAtlasProjection
    public var exporter: EntityAtlasExporter

    public init(
        repository: AtlasVaultDocumentRepository = AtlasVaultDocumentRepository(),
        projection: EntityAtlasProjection = EntityAtlasProjection(),
        exporter: EntityAtlasExporter = EntityAtlasExporter()
    ) {
        self.repository = repository
        self.projection = projection
        self.exporter = exporter
    }

    public func buildSnapshot(
        resolver: CellResolverProtocol,
        requester: Identity,
        scaffoldConfigurations: [CellConfiguration] = [],
        vaultCell: VaultCell? = nil
    ) async throws -> EntityAtlasSnapshot {
        let documents: AtlasVaultDocumentSnapshot
        if let vaultCell {
            documents = try await repository.loadAll(from: vaultCell, requester: requester)
        } else {
            documents = AtlasVaultDocumentSnapshot()
        }
        let context = EntityAtlasProjectionContext(
            resolver: resolver,
            requester: requester,
            scaffoldConfigurations: scaffoldConfigurations,
            documents: documents
        )
        return try await projection.build(context: context)
    }

    public func exportRedactedJSON(
        snapshot: EntityAtlasSnapshot,
        policy: EntityAtlasExportPolicy = EntityAtlasExportPolicy()
    ) throws -> String {
        try exporter.redactedJSON(snapshot: snapshot, policy: policy)
    }

    public func exportRedactedMarkdown(
        snapshot: EntityAtlasSnapshot,
        policy: EntityAtlasExportPolicy = EntityAtlasExportPolicy()
    ) -> String {
        exporter.redactedMarkdown(snapshot: snapshot, policy: policy)
    }
}
