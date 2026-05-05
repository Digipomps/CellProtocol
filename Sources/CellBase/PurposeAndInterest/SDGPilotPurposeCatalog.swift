// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

public enum SDGPilotDomain: String, CaseIterable, Codable, Hashable, Sendable {
    case climateMobility = "climate-mobility"
    case localChildParticipation = "local-child-participation"
    case institutionalAccountability = "institutional-accountability"
}

public struct SDGPilotTemplate: Hashable, Sendable {
    public let domain: SDGPilotDomain
    public let purposeID: String
    public let goalID: String
    public let title: String
    public let description: String
    public let metric: String
    public let target: String
    public let timeframe: String

    public init(
        domain: SDGPilotDomain,
        purposeID: String,
        goalID: String,
        title: String,
        description: String,
        metric: String,
        target: String,
        timeframe: String
    ) {
        self.domain = domain
        self.purposeID = purposeID
        self.goalID = goalID
        self.title = title
        self.description = description
        self.metric = metric
        self.target = target
        self.timeframe = timeframe
    }
}

public enum SDGPilotPurposeCatalog {
    public static func templates() -> [SDGPilotTemplate] {
        SDGPilotDomain.allCases.map(template(for:))
    }

    public static func template(for domain: SDGPilotDomain) -> SDGPilotTemplate {
        switch domain {
        case .climateMobility:
            return SDGPilotTemplate(
                domain: .climateMobility,
                purposeID: "purpose.sdg.climate.member-mobility-decarbonization",
                goalID: "goal.sdg.climate.member-mobility-emissions-intensity",
                title: "Decarbonize member mobility",
                description: "Reduce the emissions intensity of member travel while keeping participation accessible across income groups and locations.",
                metric: "kgCO2e_per_member_km",
                target: "monthly_average <= 0.34",
                timeframe: "2026-01-01/2026-12-31"
            )
        case .localChildParticipation:
            return SDGPilotTemplate(
                domain: .localChildParticipation,
                purposeID: "purpose.sdg.local-child-participation-and-belonging",
                goalID: "goal.sdg.local-child-participation.active-retention-rate",
                title: "Increase local child participation and belonging",
                description: "Increase active participation and retention for children in local activities without widening access gaps across neighborhoods or backgrounds.",
                metric: "active_children_count_and_retention_rate",
                target: "active_children >= 55 && retention_rate >= 0.82",
                timeframe: "2026-season"
            )
        case .institutionalAccountability:
            return SDGPilotTemplate(
                domain: .institutionalAccountability,
                purposeID: "purpose.sdg.institutional-decision-transparency-and-remedy",
                goalID: "goal.sdg.institutional.decision-rationale-publication-latency",
                title: "Publish accountable decisions within the agreed window",
                description: "Ensure relevant decisions are published with rationale, responsible actor and review path within seven days.",
                metric: "share_of_decisions_published_with_rationale_within_7_days",
                target: "share >= 1.0",
                timeframe: "rolling_90_days"
            )
        }
    }

    public static func makePurpose(for domain: SDGPilotDomain) -> Purpose {
        let template = template(for: domain)
        let goal = goalConfiguration(for: template)
        let helpers = helperCells(for: template)
        return Purpose(
            name: template.title,
            description: template.description,
            goal: goal,
            helperCells: helpers
        )
    }

    public static func allPilotPurposes() -> [Purpose] {
        templates().map { makePurpose(for: $0.domain) }
    }

    private static func goalConfiguration(for template: SDGPilotTemplate) -> CellConfiguration {
        var configuration = CellConfiguration(name: template.title + " goal")
        configuration.description = "Success when \(template.metric) satisfies \(template.target) during \(template.timeframe). Canonical goal: \(template.goalID)."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///CommonsTaxonomy",
            sourceCellName: "CommonsTaxonomyCell",
            purpose: template.goalID,
            purposeDescription: template.description,
            interests: ["sdg", template.domain.rawValue, "goal"],
            menuSlots: ["upperMid"]
        )

        var taxonomyReference = CellReference(endpoint: "cell:///CommonsTaxonomy", label: "taxonomy")
        taxonomyReference.addKeyAndValue(
            KeyValue(
                key: "taxonomy.resolve.term",
                value: .object([
                    "term_id": .string(template.goalID),
                    "lang": .string("en-US"),
                    "namespace": .string("haven.sdg")
                ])
            )
        )
        configuration.addReference(taxonomyReference)
        return configuration
    }

    private static func helperCells(for template: SDGPilotTemplate) -> [CellConfiguration] {
        [
            baselineHelper(for: template),
            evidenceRoutingHelper(for: template),
            fairnessGuardrailHelper(for: template)
        ]
    }

    private static func baselineHelper(for template: SDGPilotTemplate) -> CellConfiguration {
        var configuration = CellConfiguration(name: template.title + " baseline capture")
        configuration.description = "Creates a structured baseline note for the pilot so the team can record the starting metric, scope and exclusions before acting."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///Vault",
            sourceCellName: "VaultCell",
            purpose: "baseline-capture",
            purposeDescription: "Prepare the baseline note for \(template.goalID).",
            interests: ["baseline", template.domain.rawValue, "evidence"],
            menuSlots: ["upperLeft"]
        )

        var vaultReference = CellReference(endpoint: "cell:///Vault", label: "vault")
        vaultReference.addKeyAndValue(
            KeyValue(
                key: "vault.note.create",
                value: .object([
                    "id": .string("sdg.pilot.\(template.domain.rawValue).baseline"),
                    "title": .string(template.title + " baseline"),
                    "content": .string("Record baseline, scope, exclusions and assumptions for \(template.goalID)."),
                    "tags": .list([
                        .string("sdg"),
                        .string("pilot"),
                        .string(template.domain.rawValue),
                        .string("baseline")
                    ]),
                    "createdAtEpochMs": .integer(0),
                    "updatedAtEpochMs": .integer(0)
                ])
            )
        )
        configuration.addReference(vaultReference)
        return configuration
    }

    private static func evidenceRoutingHelper(for template: SDGPilotTemplate) -> CellConfiguration {
        var configuration = CellConfiguration(name: template.title + " evidence routing")
        configuration.description = "Normalizes the recommended evidence path so the pilot collects signals in a consistent place before review."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///CommonsResolver",
            sourceCellName: "CommonsResolverCell",
            purpose: "evidence-routing",
            purposeDescription: "Resolve the recommended evidence path for \(template.goalID).",
            interests: ["chronicle", template.domain.rawValue, "measurement"],
            menuSlots: ["upperMid"]
        )

        var resolverReference = CellReference(endpoint: "cell:///CommonsResolver", label: "resolver")
        resolverReference.addKeyAndValue(
            KeyValue(
                key: "commons.resolve.keypath",
                value: .object([
                    "entity_id": .string("self"),
                    "path": .string(evidencePath(for: template.domain)),
                    "context": .object([
                        "role": .string("owner"),
                        "consent_tokens": .list([])
                    ])
                ])
            )
        )
        configuration.addReference(resolverReference)
        return configuration
    }

    private static func fairnessGuardrailHelper(for template: SDGPilotTemplate) -> CellConfiguration {
        var configuration = CellConfiguration(name: template.title + " fairness guardrail")
        configuration.description = "Checks the pilot against equal human worth, net-positive contribution and current atlas coverage before the team claims success."
        configuration.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///CommonsTaxonomy",
            sourceCellName: "CommonsTaxonomyCell",
            purpose: "fairness-guardrail",
            purposeDescription: "Review root guardrails and coverage for \(template.purposeID).",
            interests: ["fairness", template.domain.rawValue, "governance"],
            menuSlots: ["upperRight"]
        )

        var taxonomyReference = CellReference(endpoint: "cell:///CommonsTaxonomy", label: "taxonomy")
        taxonomyReference.addKeyAndValue(
            KeyValue(
                key: "taxonomy.resolve.batchTerms",
                value: .list([
                    .object([
                        "term_id": .string("purpose.human-equal-worth"),
                        "lang": .string("en-US"),
                        "namespace": .string("haven.core")
                    ]),
                    .object([
                        "term_id": .string("purpose.net-positive-contribution"),
                        "lang": .string("en-US"),
                        "namespace": .string("haven.core")
                    ]),
                    .object([
                        "term_id": .string(template.purposeID),
                        "lang": .string("en-US"),
                        "namespace": .string("haven.sdg")
                    ])
                ])
            )
        )

        var atlasReference = CellReference(endpoint: "cell:///EntityAtlas", label: "atlas")
        atlasReference.addKeyAndValue(
            KeyValue(
                key: "atlas.query.coverage",
                value: .object([
                    "purpose_ref": .string(template.purposeID)
                ])
            )
        )

        configuration.addReference(taxonomyReference)
        configuration.addReference(atlasReference)
        return configuration
    }

    private static func evidencePath(for domain: SDGPilotDomain) -> String {
        switch domain {
        case .climateMobility:
            return "#/chronicle/events"
        case .localChildParticipation:
            return "#/perspective/pre/goals"
        case .institutionalAccountability:
            return "#/chronicle/graph"
        }
    }
}
