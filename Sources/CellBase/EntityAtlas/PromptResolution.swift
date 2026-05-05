// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum AtlasPromptResolutionLayer: String, Codable {
    case entity
    case assistant
    case purpose
    case cell
    case sessionOverride
}

public enum AtlasResolvedSectionKind: String, Codable {
    case prompt
    case context
}

public struct AtlasResolvedPromptSection: Codable, Equatable {
    public var kind: AtlasResolvedSectionKind
    public var layer: AtlasPromptResolutionLayer
    public var sourceID: String
    public var title: String
    public var body: String

    public init(kind: AtlasResolvedSectionKind, layer: AtlasPromptResolutionLayer, sourceID: String, title: String, body: String) {
        self.kind = kind
        self.layer = layer
        self.sourceID = sourceID
        self.title = title
        self.body = body
    }
}

public struct AtlasResolvedPrompt: Codable, Equatable {
    public var sections: [AtlasResolvedPromptSection]
    public var assembledText: String
    public var explain: [String]

    public init(sections: [AtlasResolvedPromptSection], assembledText: String, explain: [String]) {
        self.sections = sections
        self.assembledText = assembledText
        self.explain = explain
    }
}

public struct AtlasPromptResolver {
    public init() {}

    public func resolve(
        assistantProfile: AtlasAssistantProfile,
        promptDocuments: [AtlasPromptDocument],
        contextDocuments: [AtlasContextDocument],
        purposeRef: String? = nil,
        cellRefs: [String] = [],
        sessionPromptOverrides: [AtlasPromptDocument] = [],
        sessionContextOverrides: [AtlasContextDocument] = []
    ) -> AtlasResolvedPrompt {
        let promptMap = Dictionary(uniqueKeysWithValues: promptDocuments.map { ($0.id, $0) })
        let contextMap = Dictionary(uniqueKeysWithValues: contextDocuments.map { ($0.id, $0) })

        var sections = [AtlasResolvedPromptSection]()
        var explain = [String]()

        appendPromptSections(
            matching: promptDocuments.filter { $0.scope.matches(kind: .entity, reference: nil) },
            layer: .entity,
            explainPrefix: "entity prompt",
            into: &sections,
            explain: &explain
        )
        appendContextSections(
            matching: contextDocuments.filter { $0.scope.matches(kind: .entity, reference: nil) },
            layer: .entity,
            explainPrefix: "entity context",
            into: &sections,
            explain: &explain
        )

        let assistantPromptRefs = assistantProfile.promptRefs.compactMap { promptMap[$0] }
        let assistantScopedPrompts = promptDocuments
            .filter { $0.scope.matches(kind: .assistant, reference: assistantProfile.id) && !assistantProfile.promptRefs.contains($0.id) }
            .sorted { $0.id < $1.id }
        appendPromptSections(
            matching: assistantPromptRefs + assistantScopedPrompts,
            layer: .assistant,
            explainPrefix: "assistant prompt",
            into: &sections,
            explain: &explain
        )

        let assistantContextRefs = assistantProfile.contextRefs.compactMap { contextMap[$0] }
        let assistantScopedContexts = contextDocuments
            .filter { $0.scope.matches(kind: .assistant, reference: assistantProfile.id) && !assistantProfile.contextRefs.contains($0.id) }
            .sorted { $0.id < $1.id }
        appendContextSections(
            matching: assistantContextRefs + assistantScopedContexts,
            layer: .assistant,
            explainPrefix: "assistant context",
            into: &sections,
            explain: &explain
        )

        if let purposeRef, !purposeRef.isEmpty {
            appendPromptSections(
                matching: promptDocuments.filter { $0.scope.matches(kind: .purpose, reference: purposeRef) },
                layer: .purpose,
                explainPrefix: "purpose prompt",
                into: &sections,
                explain: &explain
            )
            appendContextSections(
                matching: contextDocuments.filter { $0.scope.matches(kind: .purpose, reference: purposeRef) },
                layer: .purpose,
                explainPrefix: "purpose context",
                into: &sections,
                explain: &explain
            )
        }

        for cellRef in cellRefs {
            appendPromptSections(
                matching: promptDocuments.filter { $0.scope.matches(kind: .cell, reference: cellRef) },
                layer: .cell,
                explainPrefix: "cell prompt",
                into: &sections,
                explain: &explain
            )
            appendContextSections(
                matching: contextDocuments.filter { $0.scope.matches(kind: .cell, reference: cellRef) },
                layer: .cell,
                explainPrefix: "cell context",
                into: &sections,
                explain: &explain
            )
        }

        appendPromptSections(
            matching: sessionPromptOverrides,
            layer: .sessionOverride,
            explainPrefix: "session prompt",
            into: &sections,
            explain: &explain
        )
        appendContextSections(
            matching: sessionContextOverrides,
            layer: .sessionOverride,
            explainPrefix: "session context",
            into: &sections,
            explain: &explain
        )

        let assembledText = sections.map { section in
            "[\(section.layer.rawValue) \(section.kind.rawValue)] \(section.title)\n\(section.body)"
        }
        .joined(separator: "\n\n")

        return AtlasResolvedPrompt(sections: sections, assembledText: assembledText, explain: explain)
    }

    private func appendPromptSections(
        matching documents: [AtlasPromptDocument],
        layer: AtlasPromptResolutionLayer,
        explainPrefix: String,
        into sections: inout [AtlasResolvedPromptSection],
        explain: inout [String]
    ) {
        for document in documents.sorted(by: documentSort) {
            sections.append(
                AtlasResolvedPromptSection(
                    kind: .prompt,
                    layer: layer,
                    sourceID: document.id,
                    title: document.title,
                    body: document.body
                )
            )
            explain.append("Included \(explainPrefix) `\(document.id)` from scope `\(document.scope.kind.rawValue)`.")
        }
    }

    private func appendContextSections(
        matching documents: [AtlasContextDocument],
        layer: AtlasPromptResolutionLayer,
        explainPrefix: String,
        into sections: inout [AtlasResolvedPromptSection],
        explain: inout [String]
    ) {
        for document in documents.sorted(by: documentSort) {
            let body: String
            if document.blockIDs.isEmpty {
                body = document.body
            } else {
                body = document.body + "\n\nBlocks: " + document.blockIDs.joined(separator: ", ")
            }
            sections.append(
                AtlasResolvedPromptSection(
                    kind: .context,
                    layer: layer,
                    sourceID: document.id,
                    title: document.title,
                    body: body
                )
            )
            explain.append("Included \(explainPrefix) `\(document.id)` from scope `\(document.scope.kind.rawValue)`.")
        }
    }

    private func documentSort<T: AtlasVaultDocumentConvertible>(_ lhs: T, _ rhs: T) -> Bool {
        if lhs.updatedAtEpochMs != rhs.updatedAtEpochMs {
            return lhs.updatedAtEpochMs < rhs.updatedAtEpochMs
        }
        return lhs.id < rhs.id
    }
}
