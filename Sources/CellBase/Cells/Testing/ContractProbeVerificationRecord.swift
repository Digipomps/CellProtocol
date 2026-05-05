// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public struct ContractProbeVerificationRecord: Codable {
    public struct AssertionDigest: Codable {
        public var key: String
        public var phase: String
        public var status: String
        public var message: String
        public var expected: ValueType?
        public var observed: ValueType?

        public init(from assertion: ContractProbeAssertionResult) {
            self.key = assertion.key
            self.phase = assertion.phase
            self.status = assertion.status.rawValue
            self.message = assertion.message
            self.expected = assertion.expected
            self.observed = assertion.observed
        }
    }

    public var recordType: String
    public var repo: String
    public var cellType: String
    public var targetEndpoint: String
    public var targetLabel: String?
    public var exportedAt: String
    public var lastVerifiedAt: String?
    public var verificationStatus: String
    public var passedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var failedAssertionCount: Int
    public var hasRuntimeProbe: Bool
    public var contractVersion: Int?
    public var usedExpectedContracts: Bool
    public var contractItems: [ExploreContractCatalog.Record]
    public var assertions: [AssertionDigest]
    public var failingAssertions: [AssertionDigest]
    public var markdown: String
}

public enum ContractProbeVerificationRecordBuilder {
    public static func build(
        for cell: any CellProtocol,
        requester: Identity,
        probeReport: ContractProbeReport,
        repo: String = "CellProtocol",
        targetEndpoint: String? = nil,
        targetLabel: String? = nil
    ) async throws -> ContractProbeVerificationRecord {
        let catalog = try await cell.exploreContractCatalog(requester: requester)
        return build(
            catalog: catalog,
            report: probeReport,
            repo: repo,
            targetEndpoint: targetEndpoint,
            targetLabel: targetLabel
        )
    }

    public static func build(
        catalog: ExploreContractCatalog,
        report: ContractProbeReport,
        repo: String = "CellProtocol",
        targetEndpoint: String? = nil,
        targetLabel: String? = nil
    ) -> ContractProbeVerificationRecord {
        let exportedAt = exportTimestamp()
        let failingAssertions = report.assertions
            .filter { $0.status == .failed }
            .map(ContractProbeVerificationRecord.AssertionDigest.init)
        let assertions = report.assertions.map(ContractProbeVerificationRecord.AssertionDigest.init)
        let endpoint = targetEndpoint ?? report.targetCell
        let version = contractVersion(from: catalog.records)

        return ContractProbeVerificationRecord(
            recordType: "cell_contract_verification",
            repo: repo,
            cellType: catalog.cellType,
            targetEndpoint: endpoint,
            targetLabel: targetLabel,
            exportedAt: exportedAt,
            lastVerifiedAt: report.finishedAt ?? report.startedAt,
            verificationStatus: report.status.rawValue,
            passedCount: report.passedCount,
            failedCount: report.failedCount,
            skippedCount: report.skippedCount,
            failedAssertionCount: failingAssertions.count,
            hasRuntimeProbe: true,
            contractVersion: version,
            usedExpectedContracts: report.usedExpectedContracts,
            contractItems: catalog.records,
            assertions: assertions,
            failingAssertions: failingAssertions,
            markdown: renderMarkdown(
                repo: repo,
                catalog: catalog,
                report: report,
                targetEndpoint: endpoint,
                targetLabel: targetLabel,
                exportedAt: exportedAt,
                failingAssertions: failingAssertions
            )
        )
    }

    private static func contractVersion(from records: [ExploreContractCatalog.Record]) -> Int? {
        let versions = Set(records.compactMap { record -> Int? in
            guard case let .object(contractObject) = record.contract else {
                return nil
            }
            return ExploreContract.int(from: contractObject[ExploreContract.Field.contractVersion])
        })

        guard versions.count == 1 else {
            return versions.sorted().last
        }
        return versions.first
    }

    private static func renderMarkdown(
        repo: String,
        catalog: ExploreContractCatalog,
        report: ContractProbeReport,
        targetEndpoint: String,
        targetLabel: String?,
        exportedAt: String,
        failingAssertions: [ContractProbeVerificationRecord.AssertionDigest]
    ) -> String {
        var lines = [String]()
        lines.append("# Cell Contract Verification")
        lines.append("")
        lines.append("Repo: `\(repo)`")
        lines.append("Cell: `\(catalog.cellType)`")
        lines.append("Target endpoint: `\(targetEndpoint)`")
        if let targetLabel, !targetLabel.isEmpty {
            lines.append("Target label: `\(targetLabel)`")
        }
        lines.append("Exported at: \(exportedAt)")
        lines.append("Last verified at: \(report.finishedAt ?? report.startedAt)")
        lines.append("Verification status: `\(report.status.rawValue)`")
        lines.append("Probe summary: \(report.passedCount) passed, \(report.failedCount) failed, \(report.skippedCount) skipped")
        lines.append("Used expected contracts: \(report.usedExpectedContracts ? "yes" : "no")")
        lines.append("")
        lines.append("## Declared Keys")
        lines.append("")

        for record in catalog.records {
            lines.append("- `\(record.key)` (`\(record.method)`) - \(record.summary)")
        }

        lines.append("")
        lines.append("## Latest Verification")
        lines.append("")
        lines.append("- Runtime probe: yes")
        lines.append("- Failed assertions: \(failingAssertions.count)")
        lines.append("- Declared key count: \(catalog.records.count)")

        lines.append("")
        lines.append("## Failing Assertions")
        lines.append("")
        if failingAssertions.isEmpty {
            lines.append("None")
        } else {
            for assertion in failingAssertions {
                lines.append("### `\(assertion.key)` / `\(assertion.phase)`")
                lines.append("- Status: `\(assertion.status)`")
                lines.append("- Message: \(assertion.message)")
                if let expected = assertion.expected {
                    lines.append("- Expected:")
                    lines.append("```json")
                    lines.append(jsonString(for: expected))
                    lines.append("```")
                }
                if let observed = assertion.observed {
                    lines.append("- Observed:")
                    lines.append("```json")
                    lines.append(jsonString(for: observed))
                    lines.append("```")
                }
                lines.append("")
            }
            if lines.last?.isEmpty == true {
                lines.removeLast()
            }
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
    func exploreContractVerificationRecord(
        requester: Identity,
        probeReport: ContractProbeReport,
        repo: String = "CellProtocol",
        targetEndpoint: String? = nil,
        targetLabel: String? = nil
    ) async throws -> ContractProbeVerificationRecord {
        try await ContractProbeVerificationRecordBuilder.build(
            for: self,
            requester: requester,
            probeReport: probeReport,
            repo: repo,
            targetEndpoint: targetEndpoint,
            targetLabel: targetLabel
        )
    }
}
