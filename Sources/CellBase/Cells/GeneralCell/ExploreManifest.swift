// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ExploreManifest: Codable {
    public static let version = 1

    public struct Intent: Codable {
        public var title: String?
        public var summary: String?
        public var purposeRefs: [String]
        public var purposeDescription: String?
        public var interests: [String]
        public var menuSlots: [String]
        public var dependencyRefs: [String]
        public var requiredCredentialClasses: [String]
        public var capabilityHints: [String]
        public var knowledgeRoles: [String]
        public var sourceCellEndpoint: String?
        public var sourceCellName: String?

        public init(
            title: String? = nil,
            summary: String? = nil,
            purposeRefs: [String] = [],
            purposeDescription: String? = nil,
            interests: [String] = [],
            menuSlots: [String] = [],
            dependencyRefs: [String] = [],
            requiredCredentialClasses: [String] = [],
            capabilityHints: [String] = [],
            knowledgeRoles: [String] = [],
            sourceCellEndpoint: String? = nil,
            sourceCellName: String? = nil
        ) {
            self.title = title
            self.summary = summary
            self.purposeRefs = purposeRefs.sorted()
            self.purposeDescription = purposeDescription
            self.interests = interests.sorted()
            self.menuSlots = menuSlots.sorted()
            self.dependencyRefs = dependencyRefs.sorted()
            self.requiredCredentialClasses = requiredCredentialClasses.sorted()
            self.capabilityHints = capabilityHints.sorted()
            self.knowledgeRoles = knowledgeRoles.sorted()
            self.sourceCellEndpoint = sourceCellEndpoint
            self.sourceCellName = sourceCellName
        }
    }

    public struct Operation: Codable {
        public var id: String
        public var key: String
        public var method: String
        public var summary: String
        public var description: String?
        public var permissions: [String]
        public var inputType: String
        public var returnType: String
        public var flowTopics: [String]
        public var tags: [String]
        public var contract: ValueType
        public var markdown: String

        public init(
            id: String,
            key: String,
            method: String,
            summary: String,
            description: String? = nil,
            permissions: [String] = [],
            inputType: String,
            returnType: String,
            flowTopics: [String] = [],
            tags: [String] = [],
            contract: ValueType,
            markdown: String
        ) {
            self.id = id
            self.key = key
            self.method = method
            self.summary = summary
            self.description = description
            self.permissions = permissions
            self.inputType = inputType
            self.returnType = returnType
            self.flowTopics = flowTopics
            self.tags = tags
            self.contract = contract
            self.markdown = markdown
        }
    }

    public var manifestVersion: Int
    public var contractVersion: Int
    public var cellType: String
    public var cellUUID: String
    public var identityDomain: String
    public var exportedAt: String
    public var intent: Intent
    public var operations: [Operation]
    public var markdown: String

    public init(
        manifestVersion: Int = ExploreManifest.version,
        contractVersion: Int = ExploreContract.version,
        cellType: String,
        cellUUID: String,
        identityDomain: String,
        exportedAt: String,
        intent: Intent,
        operations: [Operation],
        markdown: String
    ) {
        self.manifestVersion = manifestVersion
        self.contractVersion = contractVersion
        self.cellType = cellType
        self.cellUUID = cellUUID
        self.identityDomain = identityDomain
        self.exportedAt = exportedAt
        self.intent = intent
        self.operations = operations
        self.markdown = markdown
    }
}

public enum ExploreManifestBuilder {
    public static func build(
        for cell: any CellProtocol,
        requester: Identity,
        discovery: CellConfigurationDiscovery? = nil
    ) async throws -> ExploreManifest {
        let catalog = try await cell.exploreContractCatalog(requester: requester)
        let descriptor = try await descriptorIfAvailable(for: cell, requester: requester)
        let intent = makeIntent(
            descriptor: descriptor,
            discovery: discovery,
            contractKeys: catalog.records.map(\.key)
        )
        let operations = catalog.records.map {
            ExploreManifest.Operation(
                id: $0.id,
                key: $0.key,
                method: $0.method,
                summary: $0.summary,
                description: $0.description,
                permissions: $0.permissions,
                inputType: $0.inputType,
                returnType: $0.returnType,
                flowTopics: $0.flowTopics,
                tags: $0.tags,
                contract: $0.contract,
                markdown: $0.markdown
            )
        }

        return ExploreManifest(
            cellType: catalog.cellType,
            cellUUID: cell.uuid,
            identityDomain: cell.identityDomain,
            exportedAt: catalog.exportedAt,
            intent: intent,
            operations: operations,
            markdown: renderMarkdown(
                cellType: catalog.cellType,
                cellUUID: cell.uuid,
                identityDomain: cell.identityDomain,
                exportedAt: catalog.exportedAt,
                intent: intent,
                operations: operations
            )
        )
    }

    private static func descriptorIfAvailable(
        for cell: any CellProtocol,
        requester: Identity
    ) async throws -> EntityAtlasCellDescriptor? {
        guard let describable = cell as? any EntityAtlasDescribing else {
            return nil
        }
        return try await describable.entityAtlasDescriptor(requester: requester)
    }

    private static func makeIntent(
        descriptor: EntityAtlasCellDescriptor?,
        discovery: CellConfigurationDiscovery?,
        contractKeys: [String]
    ) -> ExploreManifest.Intent {
        let purposeRefs = uniqueSorted(
            (descriptor?.purposeRefs ?? []) +
            (discovery?.purpose.map { [$0] } ?? [])
        )
        let capabilityHints = uniqueSorted(
            (descriptor?.capabilityHints ?? []) + contractKeys
        )
        let knowledgeRoles = uniqueSorted(
            (descriptor?.knowledgeRoles.map(\.rawValue) ?? [])
        )

        return ExploreManifest.Intent(
            title: descriptor?.title ?? discovery?.sourceCellName,
            summary: descriptor?.summary,
            purposeRefs: purposeRefs,
            purposeDescription: discovery?.purposeDescription,
            interests: discovery?.interests ?? [],
            menuSlots: discovery?.menuSlots ?? [],
            dependencyRefs: descriptor?.dependencyRefs ?? [],
            requiredCredentialClasses: descriptor?.requiredCredentialClasses ?? [],
            capabilityHints: capabilityHints,
            knowledgeRoles: knowledgeRoles,
            sourceCellEndpoint: discovery?.sourceCellEndpoint,
            sourceCellName: discovery?.sourceCellName
        )
    }

    private static func renderMarkdown(
        cellType: String,
        cellUUID: String,
        identityDomain: String,
        exportedAt: String,
        intent: ExploreManifest.Intent,
        operations: [ExploreManifest.Operation]
    ) -> String {
        var lines = [String]()
        lines.append("# \(cellType) Explore Manifest")
        lines.append("")
        lines.append("Exported at: \(exportedAt)")
        lines.append("Cell UUID: `\(cellUUID)`")
        lines.append("Identity domain: `\(identityDomain)`")
        lines.append("")
        lines.append("## Declared Intent")
        lines.append("")
        lines.append("Title: \(intent.title ?? "unknown")")
        lines.append("Summary: \(intent.summary ?? "none")")
        lines.append("Declared purposes: \(inlineList(intent.purposeRefs))")
        lines.append("Purpose description: \(intent.purposeDescription ?? "none")")
        lines.append("Interests: \(inlineList(intent.interests))")
        lines.append("Menu slots: \(inlineList(intent.menuSlots))")
        lines.append("Dependency refs: \(inlineList(intent.dependencyRefs))")
        lines.append("Required credential classes: \(inlineList(intent.requiredCredentialClasses))")
        lines.append("Capability hints: \(inlineList(intent.capabilityHints))")
        lines.append("Knowledge roles: \(inlineList(intent.knowledgeRoles))")
        lines.append("Source cell endpoint: \(intent.sourceCellEndpoint ?? "none")")
        lines.append("Source cell name: \(intent.sourceCellName ?? "none")")
        lines.append("")
        lines.append("## Operations")
        lines.append("")

        if operations.isEmpty {
            lines.append("none")
        } else {
            for operation in operations {
                lines.append(operation.markdown)
                lines.append("")
            }
            _ = lines.popLast()
        }

        return lines.joined(separator: "\n")
    }

    private static func inlineList(_ values: [String]) -> String {
        guard !values.isEmpty else {
            return "none"
        }
        return values.map { "`\($0)`" }.joined(separator: ", ")
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

public extension CellProtocol {
    func exploreManifest(
        requester: Identity,
        discovery: CellConfigurationDiscovery? = nil
    ) async throws -> ExploreManifest {
        try await ExploreManifestBuilder.build(
            for: self,
            requester: requester,
            discovery: discovery
        )
    }
}
