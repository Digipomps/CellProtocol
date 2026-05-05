// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ContractProbeVerificationChunk: Codable {
    public var id: String
    public var recordType: String
    public var documentKind: String
    public var repo: String
    public var cellType: String
    public var targetEndpoint: String
    public var targetLabel: String?
    public var key: String?
    public var phase: String?
    public var status: String?
    public var verifiedAt: String?
    public var hasRuntimeProbe: Bool
    public var contractVersion: Int?
    public var content: String
}

public enum ContractProbeVerificationChunkBuilder {
    public static func build(from record: ContractProbeVerificationRecord) -> [ContractProbeVerificationChunk] {
        var chunks = [ContractProbeVerificationChunk]()

        chunks.append(summaryChunk(from: record))
        chunks.append(contentsOf: keyContractChunks(from: record))
        chunks.append(contentsOf: failedAssertionChunks(from: record))
        chunks.append(contentsOf: flowAssertionGroupChunks(from: record))

        return chunks
    }

    private static func summaryChunk(from record: ContractProbeVerificationRecord) -> ContractProbeVerificationChunk {
        let declaredKeys = record.contractItems.map(\.key).sorted()
        let content = [
            "# Cell Verification Summary",
            "",
            "Repo: `\(record.repo)`",
            "Cell: `\(record.cellType)`",
            "Target endpoint: `\(record.targetEndpoint)`",
            "Verification status: `\(record.verificationStatus)`",
            "Last verified at: \(record.lastVerifiedAt ?? "*")",
            "Declared key count: \(record.contractItems.count)",
            "Failed assertion count: \(record.failedAssertionCount)",
            "Declared keys: \(declaredKeys.map { "`\($0)`" }.joined(separator: ", "))"
        ].joined(separator: "\n")

        return ContractProbeVerificationChunk(
            id: "\(record.targetEndpoint)#summary",
            recordType: "cell_contract_verification_chunk",
            documentKind: "summary",
            repo: record.repo,
            cellType: record.cellType,
            targetEndpoint: record.targetEndpoint,
            targetLabel: record.targetLabel,
            key: nil,
            phase: nil,
            status: record.verificationStatus,
            verifiedAt: record.lastVerifiedAt,
            hasRuntimeProbe: record.hasRuntimeProbe,
            contractVersion: record.contractVersion,
            content: content
        )
    }

    private static func keyContractChunks(from record: ContractProbeVerificationRecord) -> [ContractProbeVerificationChunk] {
        record.contractItems
            .sorted { $0.key < $1.key }
            .map { item in
                let content = [
                    "# Key Contract",
                    "",
                    "Repo: `\(record.repo)`",
                    "Cell: `\(record.cellType)`",
                    "Target endpoint: `\(record.targetEndpoint)`",
                    "Key: `\(item.key)`",
                    "Method: `\(item.method)`",
                    "Summary: \(item.summary)",
                    "Permissions: \(item.permissions.isEmpty ? "none" : item.permissions.map { "`\($0)`" }.joined(separator: ", "))",
                    "",
                    item.markdown
                ].joined(separator: "\n")

                return ContractProbeVerificationChunk(
                    id: "\(record.targetEndpoint)#key:\(item.key)",
                    recordType: "cell_contract_verification_chunk",
                    documentKind: "key_contract",
                    repo: record.repo,
                    cellType: record.cellType,
                    targetEndpoint: record.targetEndpoint,
                    targetLabel: record.targetLabel,
                    key: item.key,
                    phase: nil,
                    status: record.verificationStatus,
                    verifiedAt: record.lastVerifiedAt,
                    hasRuntimeProbe: record.hasRuntimeProbe,
                    contractVersion: record.contractVersion,
                    content: content
                )
            }
    }

    private static func failedAssertionChunks(from record: ContractProbeVerificationRecord) -> [ContractProbeVerificationChunk] {
        record.failingAssertions
            .sorted {
                if $0.key == $1.key {
                    return $0.phase < $1.phase
                }
                return $0.key < $1.key
            }
            .map { assertion in
                var lines = [String]()
                lines.append("# Failed Assertion")
                lines.append("")
                lines.append("Repo: `\(record.repo)`")
                lines.append("Cell: `\(record.cellType)`")
                lines.append("Target endpoint: `\(record.targetEndpoint)`")
                lines.append("Key: `\(assertion.key)`")
                lines.append("Phase: `\(assertion.phase)`")
                lines.append("Status: `\(assertion.status)`")
                lines.append("Last verified at: \(record.lastVerifiedAt ?? "*")")
                lines.append("Message: \(assertion.message)")

                if let expected = assertion.expected {
                    lines.append("")
                    lines.append("Expected:")
                    lines.append("```json")
                    lines.append(jsonString(for: expected))
                    lines.append("```")
                }

                if let observed = assertion.observed {
                    lines.append("")
                    lines.append("Observed:")
                    lines.append("```json")
                    lines.append(jsonString(for: observed))
                    lines.append("```")
                }

                return ContractProbeVerificationChunk(
                    id: "\(record.targetEndpoint)#failed:\(assertion.key):\(assertion.phase)",
                    recordType: "cell_contract_verification_chunk",
                    documentKind: "failed_assertion",
                    repo: record.repo,
                    cellType: record.cellType,
                    targetEndpoint: record.targetEndpoint,
                    targetLabel: record.targetLabel,
                    key: assertion.key,
                    phase: assertion.phase,
                    status: assertion.status,
                    verifiedAt: record.lastVerifiedAt,
                    hasRuntimeProbe: record.hasRuntimeProbe,
                    contractVersion: record.contractVersion,
                    content: lines.joined(separator: "\n")
                )
            }
    }

    private static func flowAssertionGroupChunks(from record: ContractProbeVerificationRecord) -> [ContractProbeVerificationChunk] {
        let flowAssertions = record.assertions
            .filter { $0.phase.hasPrefix("flow.") }

        let grouped = Dictionary(grouping: flowAssertions, by: \.key)

        return grouped.keys.sorted().compactMap { key in
            guard let assertions = grouped[key], !assertions.isEmpty else {
                return nil
            }

            let sortedAssertions = assertions.sorted { $0.phase < $1.phase }
            let groupStatus: String
            if sortedAssertions.contains(where: { $0.status == "failed" }) {
                groupStatus = "failed"
            } else if sortedAssertions.allSatisfy({ $0.status == "passed" }) {
                groupStatus = "passed"
            } else {
                groupStatus = "mixed"
            }

            var lines = [String]()
            lines.append("# Flow Assertion Group")
            lines.append("")
            lines.append("Repo: `\(record.repo)`")
            lines.append("Cell: `\(record.cellType)`")
            lines.append("Target endpoint: `\(record.targetEndpoint)`")
            lines.append("Key: `\(key)`")
            lines.append("Status: `\(groupStatus)`")
            lines.append("Last verified at: \(record.lastVerifiedAt ?? "*")")
            lines.append("")
            lines.append("Observed flow assertion phases:")
            for assertion in sortedAssertions {
                lines.append("- `\(assertion.phase)` - `\(assertion.status)` - \(assertion.message)")
            }

            return ContractProbeVerificationChunk(
                id: "\(record.targetEndpoint)#flow:\(key)",
                recordType: "cell_contract_verification_chunk",
                documentKind: "flow_assertion_group",
                repo: record.repo,
                cellType: record.cellType,
                targetEndpoint: record.targetEndpoint,
                targetLabel: record.targetLabel,
                key: key,
                phase: "flow",
                status: groupStatus,
                verifiedAt: record.lastVerifiedAt,
                hasRuntimeProbe: record.hasRuntimeProbe,
                contractVersion: record.contractVersion,
                content: lines.joined(separator: "\n")
            )
        }
    }

    private static func jsonString(for value: ValueType) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension ContractProbeVerificationRecord {
    func ragChunks() -> [ContractProbeVerificationChunk] {
        ContractProbeVerificationChunkBuilder.build(from: self)
    }
}

public extension CellProtocol {
    func exploreContractVerificationChunks(
        requester: Identity,
        probeReport: ContractProbeReport,
        repo: String = "CellProtocol",
        targetEndpoint: String? = nil,
        targetLabel: String? = nil
    ) async throws -> [ContractProbeVerificationChunk] {
        let record = try await exploreContractVerificationRecord(
            requester: requester,
            probeReport: probeReport,
            repo: repo,
            targetEndpoint: targetEndpoint,
            targetLabel: targetLabel
        )
        return record.ragChunks()
    }
}
