// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ExploreContractCatalog: Codable {
    public struct Record: Codable {
        public var id: String
        public var cellType: String
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
    }

    public var cellType: String
    public var exportedAt: String
    public var records: [Record]
    public var markdown: String
}

public enum ExploreContractCatalogBuilder {
    public static func build(
        for cell: any CellProtocol,
        requester: Identity
    ) async throws -> ExploreContractCatalog {
        let keys = try await cell.keys(requester: requester).sorted()
        let cellType = String(describing: type(of: cell))
        var records = [ExploreContractCatalog.Record]()
        records.reserveCapacity(keys.count)

        for key in keys {
            let contract = try await cell.typeForKey(key: key, requester: requester)
            let contractObject = ExploreContract.object(from: contract) ?? [:]
            let summary = ExploreContract.string(from: contractObject[ExploreContract.Field.summary]) ?? "*"
            let description = try await descriptionText(for: key, on: cell, requester: requester)
            let permissions = stringList(from: contractObject[ExploreContract.Field.permissions])
            let inputType = ExploreContract.schemaType(from: contractObject[ExploreContract.Field.input]) ?? "unknown"
            let returnType = ExploreContract.schemaType(from: contractObject[ExploreContract.Field.returns]) ?? "unknown"
            let flowTopics = ExploreContract.flowEffects(from: .object(contractObject)).compactMap {
                ExploreContract.string(from: $0[ExploreContract.Field.topic])
            }
            let tags = makeTags(
                cellType: cellType,
                key: key,
                method: ExploreContract.string(from: contractObject[ExploreContract.Field.method]) ?? "unknown",
                permissions: permissions,
                inputType: inputType,
                returnType: returnType,
                flowTopics: flowTopics
            )

            let record = ExploreContractCatalog.Record(
                id: "\(cellType)#\(key)",
                cellType: cellType,
                key: key,
                method: ExploreContract.string(from: contractObject[ExploreContract.Field.method]) ?? "unknown",
                summary: summary,
                description: description,
                permissions: permissions,
                inputType: inputType,
                returnType: returnType,
                flowTopics: flowTopics,
                tags: tags,
                contract: contract,
                markdown: renderMarkdown(
                    cellType: cellType,
                    key: key,
                    summary: summary,
                    description: description,
                    permissions: permissions,
                    input: contractObject[ExploreContract.Field.input],
                    returns: contractObject[ExploreContract.Field.returns],
                    flowTopics: flowTopics
                )
            )
            records.append(record)
        }

        let exportedAt = Self.exportTimestamp()
        return ExploreContractCatalog(
            cellType: cellType,
            exportedAt: exportedAt,
            records: records,
            markdown: renderCatalogMarkdown(cellType: cellType, exportedAt: exportedAt, records: records)
        )
    }

    private static func descriptionText(
        for key: String,
        on cell: any CellProtocol,
        requester: Identity
    ) async throws -> String? {
        guard let generalCell = cell as? GeneralCell else {
            return nil
        }

        let description = try await generalCell.schemaDescriptionForKey(key: key, requester: requester)
        return ExploreContract.string(from: description)
    }

    private static func stringList(from value: ValueType?) -> [String] {
        guard let list = ExploreContract.list(from: value) else {
            return []
        }

        return list.compactMap { item in
            ExploreContract.string(from: item)
        }
    }

    private static func makeTags(
        cellType: String,
        key: String,
        method: String,
        permissions: [String],
        inputType: String,
        returnType: String,
        flowTopics: [String]
    ) -> [String] {
        var tags = [cellType.lowercased(), method.lowercased(), inputType.lowercased(), returnType.lowercased()]
        tags.append(contentsOf: key.split(separator: ".").map { String($0).lowercased() })
        tags.append(contentsOf: permissions.map { $0.lowercased() })
        tags.append(contentsOf: flowTopics.map { $0.lowercased() })

        var deduped = [String]()
        var seen = Set<String>()
        for tag in tags where !tag.isEmpty && seen.insert(tag).inserted {
            deduped.append(tag)
        }
        return deduped
    }

    private static func renderCatalogMarkdown(
        cellType: String,
        exportedAt: String,
        records: [ExploreContractCatalog.Record]
    ) -> String {
        let body = records.map(\.markdown).joined(separator: "\n\n")
        return [
            "# \(cellType) Explore Contract Catalog",
            "",
            "Exported at: \(exportedAt)",
            "",
            body
        ]
        .joined(separator: "\n")
    }

    private static func renderMarkdown(
        cellType: String,
        key: String,
        summary: String,
        description: String?,
        permissions: [String],
        input: ValueType?,
        returns: ValueType?,
        flowTopics: [String]
    ) -> String {
        let permissionText = permissions.isEmpty ? "none" : permissions.map { "`\($0)`" }.joined(separator: ", ")
        let inputType = ExploreContract.schemaType(from: input) ?? "unknown"
        let returnType = ExploreContract.schemaType(from: returns) ?? "unknown"
        let flowTopicsText = flowTopics.isEmpty ? "none" : flowTopics.map { "`\($0)`" }.joined(separator: ", ")

        var lines = [String]()
        lines.append("## `\(key)`")
        lines.append("")
        lines.append("Cell: `\(cellType)`")
        lines.append("Summary: \(summary)")
        if let description, !description.isEmpty, description != summary {
            lines.append("Description: \(description)")
        }
        lines.append("Permissions: \(permissionText)")
        lines.append("Input type: `\(inputType)`")
        lines.append("Return type: `\(returnType)`")
        lines.append("Flow topics: \(flowTopicsText)")

        if let input {
            lines.append("")
            lines.append("Input schema:")
            lines.append("```json")
            lines.append(jsonString(for: input))
            lines.append("```")
        }

        if let returns {
            lines.append("")
            lines.append("Return schema:")
            lines.append("```json")
            lines.append(jsonString(for: returns))
            lines.append("```")
        }

        return lines.joined(separator: "\n")
    }

    private static func jsonString(for value: ValueType) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func exportTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

public extension CellProtocol {
    func exploreContractCatalog(requester: Identity) async throws -> ExploreContractCatalog {
        try await ExploreContractCatalogBuilder.build(for: self, requester: requester)
    }
}
