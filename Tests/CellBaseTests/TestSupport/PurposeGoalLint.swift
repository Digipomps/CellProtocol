// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
@testable import CellBase

enum PurposeGoalLintSeverity: String {
    case error
    case warning
    case info
}

struct PurposeGoalLintFinding: Equatable {
    let severity: PurposeGoalLintSeverity
    let code: String
    let message: String
    let suggestion: String?
}

struct PurposeGoalLintReport {
    let findings: [PurposeGoalLintFinding]
    let summary: String

    var hasErrors: Bool {
        findings.contains { $0.severity == .error }
    }

    var hasWarnings: Bool {
        findings.contains { $0.severity == .warning }
    }
}

enum PurposeGoalLint {
    static func evaluate(_ purpose: Purpose) -> PurposeGoalLintReport {
        var findings = [PurposeGoalLintFinding]()

        let purposeName = purpose.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let purposeDescription = purpose.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if purposeName.isEmpty {
            findings.append(
                .init(
                    severity: .error,
                    code: "purpose.name.missing",
                    message: "Purpose must have a name.",
                    suggestion: "Set `Purpose.name` to a stable, human-readable outcome label."
                )
            )
        }

        if purposeDescription.count < 12 {
            findings.append(
                .init(
                    severity: .warning,
                    code: "purpose.description.missing",
                    message: "Purpose description is missing or too short to explain intent.",
                    suggestion: "Describe the outcome the cell is meant to achieve."
                )
            )
        } else if containsVagueWording(purposeDescription) {
            findings.append(
                .init(
                    severity: .warning,
                    code: "purpose.description.vague",
                    message: "Purpose description is too vague to validate against runtime behavior.",
                    suggestion: "Describe a specific state change, user outcome, or observable result."
                )
            )
        }

        let goal = purpose.goal
        let helpers = purpose.helperCells

        if goal == nil && helpers.isEmpty {
            findings.append(
                .init(
                    severity: .warning,
                    code: "goal.missing",
                    message: "Purpose has neither a goal nor helper cells for remediation.",
                    suggestion: "Add a goal `CellConfiguration` or at least one helper cell."
                )
            )
        }

        if let goal {
            let goalName = goal.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let goalDescription = goal.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let combinedGoalText = [goalName, goalDescription]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if goalName.isEmpty {
                findings.append(
                    .init(
                        severity: .error,
                        code: "goal.name.missing",
                        message: "Goal configuration must have a name.",
                        suggestion: "Name the goal after the success condition."
                    )
                )
            }

            if containsVagueWording(combinedGoalText) {
                findings.append(
                    .init(
                        severity: .warning,
                        code: "goal.wording.vague",
                        message: "Goal wording is too vague to be checked reliably.",
                        suggestion: "Use concrete terms such as a state, event, count, or explicit human action."
                    )
                )
            }

            if containsUnboundedLanguage(combinedGoalText) {
                findings.append(
                    .init(
                        severity: .warning,
                        code: "goal.timeline.unbounded",
                        message: "Goal uses unbounded timeline language.",
                        suggestion: "Replace words like `eventually` or `soon` with a bounded success condition."
                    )
                )
            }

            if !containsMeasurableSignal(combinedGoalText) {
                findings.append(
                    .init(
                        severity: .warning,
                        code: "goal.successSignal.missing",
                        message: "Goal does not expose a measurable success signal.",
                        suggestion: "Describe what event, state, or user action proves the goal is complete."
                    )
                )
            }
        }

        if !helpers.isEmpty && helpers.allSatisfy({ helper in
            helper.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            findings.append(
                .init(
                    severity: .warning,
                    code: "helpers.naming.missing",
                    message: "Helper cells are present but unnamed.",
                    suggestion: "Give helper cells names that describe remediation or guidance."
                )
            )
        }

        let errors = findings.filter { $0.severity == .error }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        let infos = findings.filter { $0.severity == .info }.count
        let summary = "\(errors) errors, \(warnings) warnings, \(infos) info"

        return PurposeGoalLintReport(findings: findings, summary: summary)
    }

    private static func containsVagueWording(_ text: String) -> Bool {
        let normalized = normalize(text)
        let vaguePhrases = [
            "do stuff",
            "things",
            "utility",
            "general",
            "misc",
            "helper",
            "make better",
            "improve experience",
            "handles data"
        ]
        return containsAny(vaguePhrases, in: normalized)
    }

    private static func containsUnboundedLanguage(_ text: String) -> Bool {
        let normalized = normalize(text)
        let unboundedPhrases = [
            "eventually",
            "soon",
            "later",
            "sometime",
            "future",
            "better"
        ]
        return containsAny(unboundedPhrases, in: normalized)
    }

    private static func containsMeasurableSignal(_ text: String) -> Bool {
        let normalized = normalize(text)
        let measurableIndicators = [
            "when ",
            "state",
            "status",
            "event",
            "flow",
            "count",
            "press",
            "click",
            "select",
            "approve",
            "signed",
            "created",
            "updated",
            "received",
            "within ",
            "timeout",
            "complete",
            "completed"
        ]
        return containsAny(measurableIndicators, in: normalized)
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsAny(_ patterns: [String], in normalized: String) -> Bool {
        let tokens = Set(
            normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        for pattern in patterns {
            if pattern.contains(" ") {
                if normalized.contains(pattern) {
                    return true
                }
                continue
            }

            if tokens.contains(pattern) {
                return true
            }
        }

        return false
    }
}
