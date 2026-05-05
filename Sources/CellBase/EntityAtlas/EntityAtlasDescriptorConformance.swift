// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

extension VaultCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Vault Cell",
            summary: "Stores typed and human-readable local notes plus explicit links between them.",
            purposeRefs: ["purpose.local-document-storage"],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [
                "vault.note.create",
                "vault.note.update",
                "vault.note.get",
                "vault.note.list",
                "vault.link.add",
                "vault.links.forward",
                "vault.links.backlinks"
            ],
            knowledgeRoles: []
        )
    }
}

extension GraphIndexCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Graph Index Cell",
            summary: "Builds a deterministic local graph index over note documents and their explicit links.",
            purposeRefs: ["purpose.local-graph-index"],
            dependencyRefs: ["Vault"],
            requiredCredentialClasses: [],
            capabilityHints: [
                "graph.reindex",
                "graph.outgoing",
                "graph.incoming",
                "graph.neighbors"
            ],
            knowledgeRoles: [.indexesCells]
        )
    }
}

extension CommonsResolverCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Commons Resolver Cell",
            summary: "Resolves registered HAVEN Commons keypaths and validates keypath routing against the local commons registry.",
            purposeRefs: ["purpose.commons-keypath-resolution"],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [
                "commons.resolve.keypath",
                "commons.resolve.batchKeypaths",
                "commons.lint.keypaths",
                "commons.validate.schemas"
            ],
            knowledgeRoles: [.describesCells]
        )
    }
}

extension CommonsTaxonomyCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Commons Taxonomy Cell",
            summary: "Resolves taxonomy terms, guidance, and purpose-tree governance for the local commons registry.",
            purposeRefs: ["purpose.commons-taxonomy-governance"],
            dependencyRefs: [],
            requiredCredentialClasses: [],
            capabilityHints: [
                "taxonomy.resolve.term",
                "taxonomy.resolve.batchTerms",
                "taxonomy.resolve.guidance",
                "taxonomy.validate.purposeTree"
            ],
            knowledgeRoles: [.describesCells]
        )
    }
}

extension EntityAtlasInspectorCell: EntityAtlasDescribing {
    public func entityAtlasDescriptor(requester: Identity) async throws -> EntityAtlasCellDescriptor {
        EntityAtlasCellDescriptor(
            title: "Entity Atlas Inspector",
            summary: "Builds a queryable, redacted projection of owned, attached, and scaffold-available cells.",
            purposeRefs: ["purpose.net-positive-contribution"],
            dependencyRefs: ["Vault"],
            requiredCredentialClasses: [],
            capabilityHints: [
                "atlas.snapshot",
                "atlas.export.redactedJSON",
                "atlas.export.redactedMarkdown",
                "atlas.query.coverage"
            ],
            knowledgeRoles: [.describesCells, .indexesCells]
        )
    }
}
