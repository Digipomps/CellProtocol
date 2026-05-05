// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct EntityAtlasExportPolicy {
    public var includeDocumentBodyPreviews: Bool
    public var documentBodyPreviewCharacterLimit: Int
    public var includeRelationExplanations: Bool

    public init(
        includeDocumentBodyPreviews: Bool = false,
        documentBodyPreviewCharacterLimit: Int = 160,
        includeRelationExplanations: Bool = true
    ) {
        self.includeDocumentBodyPreviews = includeDocumentBodyPreviews
        self.documentBodyPreviewCharacterLimit = max(0, documentBodyPreviewCharacterLimit)
        self.includeRelationExplanations = includeRelationExplanations
    }
}

public struct EntityAtlasRedactedExport: Codable, Equatable {
    public struct RedactedCell: Codable, Equatable {
        public var cellID: String
        public var title: String?
        public var typeName: String?
        public var purposes: [String]
        public var capabilities: [String]
        public var dependencies: [String]
        public var requiredCredentialClasses: [String]
        public var knowledgeRoles: [String]
        public var controlState: EntityAtlasCellControlState
    }

    public struct RedactedDocument: Codable, Equatable {
        public var id: String
        public var title: String
        public var scopeKind: String
        public var scopeReference: String?
        public var preview: String?
        public var characterCount: Int
    }

    public struct RedactedAssistantProfile: Codable, Equatable {
        public var id: String
        public var title: String
        public var providerProfileRef: String?
        public var promptRefs: [String]
        public var contextRefs: [String]
        public var executionPolicy: String?
    }

    public struct RedactedProviderProfile: Codable, Equatable {
        public var id: String
        public var title: String
        public var providerID: String
        public var accessMode: String
        public var allowedModels: [String]
        public var credentialHandleRefs: [String]
        public var usageConstraints: [String]
    }

    public struct RedactedCredentialHandle: Codable, Equatable {
        public var id: String
        public var title: String
        public var providerID: String
        public var credentialClass: String
        public var accessMode: String
        public var label: String
        public var revokedAtEpochMs: Int?
        public var lastRotatedAtEpochMs: Int?
        public var metadataKeys: [String]
    }

    public struct RedactedRelation: Codable, Equatable {
        public var fromID: String
        public var kind: String
        public var toID: String
        public var explanation: String?
    }

    public var generatedAtEpochMs: Int
    public var cells: [RedactedCell]
    public var scaffolds: [EntityAtlasScaffoldRecord]
    public var promptDocuments: [RedactedDocument]
    public var contextDocuments: [RedactedDocument]
    public var assistantProfiles: [RedactedAssistantProfile]
    public var providerProfiles: [RedactedProviderProfile]
    public var credentialHandles: [RedactedCredentialHandle]
    public var relations: [RedactedRelation]
}

public struct EntityAtlasExporter {
    public init() {}

    public func redactedExport(
        snapshot: EntityAtlasSnapshot,
        policy: EntityAtlasExportPolicy = EntityAtlasExportPolicy()
    ) -> EntityAtlasRedactedExport {
        EntityAtlasRedactedExport(
            generatedAtEpochMs: snapshot.generatedAtEpochMs,
            cells: snapshot.cells.map { cell in
                EntityAtlasRedactedExport.RedactedCell(
                    cellID: cell.cellID,
                    title: cell.title ?? cell.name,
                    typeName: cell.typeName,
                    purposes: cell.purposes,
                    capabilities: cell.capabilities,
                    dependencies: cell.dependencyRefs,
                    requiredCredentialClasses: cell.requiredCredentialClasses,
                    knowledgeRoles: cell.knowledgeRoles.map(\.rawValue),
                    controlState: cell.controlState
                )
            },
            scaffolds: snapshot.scaffolds,
            promptDocuments: snapshot.promptDocuments.map { redact(document: $0, policy: policy) },
            contextDocuments: snapshot.contextDocuments.map { redact(document: $0, policy: policy) },
            assistantProfiles: snapshot.assistantProfiles.map { profile in
                .init(
                    id: profile.id,
                    title: profile.title,
                    providerProfileRef: profile.providerProfileRef,
                    promptRefs: profile.promptRefs,
                    contextRefs: profile.contextRefs,
                    executionPolicy: profile.executionPolicy
                )
            },
            providerProfiles: snapshot.providerProfiles.map { profile in
                .init(
                    id: profile.id,
                    title: profile.title,
                    providerID: profile.providerID,
                    accessMode: profile.accessMode.rawValue,
                    allowedModels: profile.allowedModels,
                    credentialHandleRefs: profile.credentialHandleRefs,
                    usageConstraints: profile.usageConstraints
                )
            },
            credentialHandles: snapshot.credentialHandles.map { handle in
                .init(
                    id: handle.id,
                    title: handle.title,
                    providerID: handle.providerID,
                    credentialClass: handle.credentialClass,
                    accessMode: handle.accessMode.rawValue,
                    label: handle.label,
                    revokedAtEpochMs: handle.revokedAtEpochMs,
                    lastRotatedAtEpochMs: handle.lastRotatedAtEpochMs,
                    metadataKeys: Array(handle.metadata.keys).sorted()
                )
            },
            relations: snapshot.relations.map { relation in
                .init(
                    fromID: relation.fromID,
                    kind: relation.kind.rawValue,
                    toID: relation.toID,
                    explanation: policy.includeRelationExplanations ? relation.explanation : nil
                )
            }
        )
    }

    public func redactedJSON(
        snapshot: EntityAtlasSnapshot,
        policy: EntityAtlasExportPolicy = EntityAtlasExportPolicy()
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(redactedExport(snapshot: snapshot, policy: policy))
        return String(decoding: data, as: UTF8.self)
    }

    public func redactedMarkdown(
        snapshot: EntityAtlasSnapshot,
        policy: EntityAtlasExportPolicy = EntityAtlasExportPolicy()
    ) -> String {
        let export = redactedExport(snapshot: snapshot, policy: policy)
        var lines = [String]()
        lines.append("# Entity Atlas (Redacted)")
        lines.append("")
        lines.append("Generated at: \(export.generatedAtEpochMs)")
        lines.append("")
        lines.append("## Cells")
        for cell in export.cells {
            lines.append("- `\(cell.cellID)` [\(cell.typeName ?? "unknown")] owned=\(cell.controlState.owned) scaffold=\(cell.controlState.scaffoldAvailable) runtime=\(cell.controlState.runtimeAvailable) attached=\(cell.controlState.runtimeAttached) purposes=\(cell.purposes.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("## Assistant Profiles")
        for profile in export.assistantProfiles {
            lines.append("- `\(profile.id)` provider=\(profile.providerProfileRef ?? "none") prompts=\(profile.promptRefs.joined(separator: ", ")) contexts=\(profile.contextRefs.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("## Prompt Documents")
        for document in export.promptDocuments {
            lines.append("- `\(document.id)` scope=\(document.scopeKind) preview=\(document.preview ?? "hidden")")
        }

        lines.append("")
        lines.append("## Context Documents")
        for document in export.contextDocuments {
            lines.append("- `\(document.id)` scope=\(document.scopeKind) preview=\(document.preview ?? "hidden")")
        }

        lines.append("")
        lines.append("## Credential Handles")
        for handle in export.credentialHandles {
            lines.append("- `\(handle.id)` provider=\(handle.providerID) class=\(handle.credentialClass) metadataKeys=\(handle.metadataKeys.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("## Relations")
        for relation in export.relations {
            let explanation = relation.explanation.map { " - \($0)" } ?? ""
            lines.append("- `\(relation.fromID)` -> `\(relation.kind)` -> `\(relation.toID)`\(explanation)")
        }

        return lines.joined(separator: "\n")
    }

    private func redact(
        document: AtlasPromptDocument,
        policy: EntityAtlasExportPolicy
    ) -> EntityAtlasRedactedExport.RedactedDocument {
        .init(
            id: document.id,
            title: document.title,
            scopeKind: document.scope.kind.rawValue,
            scopeReference: document.scope.reference,
            preview: preview(text: document.body, policy: policy),
            characterCount: document.body.count
        )
    }

    private func redact(
        document: AtlasContextDocument,
        policy: EntityAtlasExportPolicy
    ) -> EntityAtlasRedactedExport.RedactedDocument {
        .init(
            id: document.id,
            title: document.title,
            scopeKind: document.scope.kind.rawValue,
            scopeReference: document.scope.reference,
            preview: preview(text: document.body, policy: policy),
            characterCount: document.body.count
        )
    }

    private func preview(text: String, policy: EntityAtlasExportPolicy) -> String? {
        guard policy.includeDocumentBodyPreviews else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        guard normalized.count > policy.documentBodyPreviewCharacterLimit else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: policy.documentBodyPreviewCharacterLimit)
        return String(normalized[..<endIndex]) + "..."
    }
}
