// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
import HavenCoreSchemas
import TaxonomyResolver

final class TaxonomyResolverTests: XCTestCase {
    private var commonsRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("commons", isDirectory: true)
    }

    private func makeResolver() throws -> TaxonomyTermResolver {
        let registry = try TaxonomyRegistry.load(from: CommonsPaths.taxonomiesURL(root: commonsRoot))
        return TaxonomyTermResolver(registry: registry)
    }

    private func makeResolver(packages: [TaxonomyPackage]) throws -> TaxonomyTermResolver {
        let registry = try TaxonomyRegistry(packages: packages)
        return TaxonomyTermResolver(registry: registry)
    }

    func testLocalizedLabelResolutionReportsBaseLanguageFallback() throws {
        let package = TaxonomyPackage(
            namespace: "haven.test",
            version: "0.1.0",
            dependsOn: [],
            terms: [
                .init(
                    termId: "interest.language",
                    labels: ["nb": "Sprak", "en-US": "Language"],
                    definition: "Language interest",
                    kind: .interest
                )
            ]
        )

        let resolver = try makeResolver(packages: [package])
        let resolved = try XCTUnwrap(resolver.resolve(termID: "interest.language", lang: "nb-NO", namespace: "haven.test"))
        XCTAssertEqual(resolved.label, "Sprak")
        XCTAssertEqual(resolved.requestedLocale, "nb-NO")
        XCTAssertEqual(resolved.resolvedLocale, "nb")
        XCTAssertTrue(resolved.fallbackUsed)

        let localized = try XCTUnwrap(resolver.resolveLocalizedTerm(termID: "interest.language", lang: "nb-NO", namespace: "haven.test"))
        XCTAssertEqual(localized.termID, "interest.language")
        XCTAssertEqual(localized.kind, .interest)
        XCTAssertEqual(localized.label, "Sprak")
        XCTAssertEqual(localized.resolvedLocale, "nb")
    }

    func testLocalizedLabelResolutionFallsBackToTermIDWhenLabelsAreMissing() throws {
        let package = TaxonomyPackage(
            namespace: "haven.test",
            version: "0.1.0",
            dependsOn: [],
            terms: [
                .init(
                    termId: "interest.unlabeled",
                    labels: [:],
                    definition: "Unlabeled test interest",
                    kind: .interest
                )
            ]
        )

        let resolver = try makeResolver(packages: [package])
        let resolved = try XCTUnwrap(resolver.resolve(termID: "interest.unlabeled", lang: "fr-FR", namespace: "haven.test"))
        XCTAssertEqual(resolved.label, "interest.unlabeled")
        XCTAssertEqual(resolved.requestedLocale, "fr-FR")
        XCTAssertNil(resolved.resolvedLocale)
        XCTAssertTrue(resolved.fallbackUsed)
    }

    func testLocalizationCoverageWarnsForMissingRequiredLabels() throws {
        let package = TaxonomyPackage(
            namespace: "haven.test",
            version: "0.1.0",
            dependsOn: [],
            terms: [
                .init(
                    termId: "interest.coverage",
                    labels: ["en-US": "Coverage"],
                    definition: "Coverage test interest",
                    kind: .interest
                )
            ]
        )

        let resolver = try makeResolver(packages: [package])
        let result = try resolver.validateLocalizationCoverage(
            namespace: "haven.test",
            requiredLocales: ["nb-NO", "en-US"]
        )

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(result.issues.first?.termID, "interest.coverage")
        XCTAssertEqual(result.issues.first?.locale, "nb-NO")
    }

    func testConferenceNamespaceInheritsCoreTerm() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "purpose.learn",
            lang: "nb-NO",
            namespace: "haven.conference"
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.sourceNamespace, "haven.core")
        XCTAssertEqual(resolved?.label, "Lære")
    }

    func testConferenceExtensionTermResolvesFromConferencePackage() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "conference.sponsor",
            lang: "en-US",
            namespace: "haven.conference"
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.sourceNamespace, "haven.conference")
        XCTAssertEqual(resolved?.label, "Sponsor")
    }

    func testDeprecatedCoreTermHasReplacement() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "purpose.present",
            lang: "en-US",
            namespace: "haven.core"
        )

        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved?.term.deprecated == true)
        XCTAssertEqual(resolved?.term.replacedBy, "purpose.share")
        XCTAssertEqual(resolved?.replacementTerm?.termId, "purpose.share")
    }

    func testConferenceNamespaceInheritsCoreGuidance() throws {
        let resolver = try makeResolver()
        let guidance = try resolver.guidance(namespace: "haven.conference")

        XCTAssertNotNil(guidance)
        XCTAssertEqual(guidance?.rootPurposeTermID, "purpose.human-equal-worth")
        XCTAssertEqual(guidance?.contributionPurposeTermID, "purpose.net-positive-contribution")
        XCTAssertEqual(guidance?.articleReference, "UDHR Article 1")
        XCTAssertEqual(guidance?.goalPolicy.mode, .encouraged)
        XCTAssertTrue(guidance?.incentiveOnly == true)
        XCTAssertEqual(
            guidance?.mandatoryInheritedPurposes,
            ["purpose.human-equal-worth", "purpose.net-positive-contribution"]
        )
        XCTAssertEqual(guidance?.forbiddenRelationsToMandatory, [.opposes])
    }

    func testGoalTermCanBeResolved() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "goal.support-local-community",
            lang: "nb-NO",
            namespace: "haven.core"
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.term.kind, .goal)
        XCTAssertEqual(resolved?.label, "Styrke lokalsamfunn")
    }

    func testSDGNamespaceResolvesPurposeFamilyFromSDGPackage() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "purpose.sdg.no-poverty",
            lang: "nb-NO",
            namespace: "haven.sdg"
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.sourceNamespace, "haven.sdg")
        XCTAssertEqual(resolved?.label, "Utrydde fattigdom")
    }

    func testSDGNamespaceInheritsCoreGuidance() throws {
        let resolver = try makeResolver()
        let guidance = try resolver.guidance(namespace: "haven.sdg")

        XCTAssertNotNil(guidance)
        XCTAssertEqual(guidance?.rootPurposeTermID, "purpose.human-equal-worth")
        XCTAssertEqual(guidance?.contributionPurposeTermID, "purpose.net-positive-contribution")
        XCTAssertEqual(
            guidance?.mandatoryInheritedPurposes,
            ["purpose.human-equal-worth", "purpose.net-positive-contribution"]
        )
    }

    func testSDGNamespaceProvidesGoalTemplate() throws {
        let resolver = try makeResolver()
        let resolved = try resolver.resolve(
            termID: "goal.sdg.climate.emissions-intensity-reduction",
            lang: "en-US",
            namespace: "haven.sdg"
        )

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.sourceNamespace, "haven.sdg")
        XCTAssertEqual(resolved?.term.kind, .goal)
        XCTAssertEqual(resolved?.term.mappings["measurement_class"], "intensity_reduction")
    }

    func testSDGNamespaceProvidesPilotTerms() throws {
        let resolver = try makeResolver()
        let purpose = try resolver.resolve(
            termID: "purpose.sdg.local-child-participation-and-belonging",
            lang: "en-US",
            namespace: "haven.sdg"
        )
        let goal = try resolver.resolve(
            termID: "goal.sdg.institutional.decision-rationale-publication-latency",
            lang: "en-US",
            namespace: "haven.sdg"
        )

        XCTAssertEqual(purpose?.sourceNamespace, "haven.sdg")
        XCTAssertEqual(purpose?.term.mappings["pilot_domain"], "local-child-participation")
        XCTAssertEqual(goal?.sourceNamespace, "haven.sdg")
        XCTAssertEqual(goal?.term.mappings["pilot_domain"], "institutional-accountability")
    }

    func testPurposeTreeValidationForCoreNamespacePasses() throws {
        let resolver = try makeResolver()
        let result = try resolver.validatePurposeTree(namespace: "haven.core")

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(
            result.mandatoryPurposeTermIDs,
            ["purpose.human-equal-worth", "purpose.net-positive-contribution"]
        )
    }

    func testPurposeTreeValidationRejectsForbiddenRelationToMandatoryPurpose() throws {
        let guidance = TaxonomyPackage.Guidance(
            rootPurposeTermID: "purpose.human-equal-worth",
            contributionPurposeTermID: "purpose.net-positive-contribution",
            articleReference: "UDHR Article 1",
            incentiveOnly: true,
            goalPolicy: .init(mode: .encouraged, description: "Encouraged goals")
        )

        let terms: [Term] = [
            .init(termId: "purpose.human-equal-worth", labels: ["en-US": "Equal Worth"], definition: "Root", kind: .purpose),
            .init(
                termId: "purpose.net-positive-contribution",
                labels: ["en-US": "Net Positive"],
                definition: "Contribution",
                kind: .purpose,
                relations: [.init(kind: .broader, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "purpose.extractive-growth",
                labels: ["en-US": "Extractive Growth"],
                definition: "Conflicting purpose",
                kind: .purpose,
                relations: [.init(kind: .opposes, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "goal.uphold-equal-worth",
                labels: ["en-US": "Uphold Equal Worth"],
                definition: "Goal for root",
                kind: .goal,
                relations: [.init(kind: .usedWith, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "goal.net-positive-impact",
                labels: ["en-US": "Net Positive Impact"],
                definition: "Goal for contribution",
                kind: .goal,
                relations: [.init(kind: .usedWith, target: "purpose.net-positive-contribution")]
            )
        ]

        let package = TaxonomyPackage(
            namespace: "haven.core",
            version: "0.1.0",
            dependsOn: [],
            terms: terms,
            guidance: guidance
        )

        let resolver = try makeResolver(packages: [package])
        let result = try resolver.validatePurposeTree(namespace: "haven.core")

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains(where: { $0.code == "purpose.conflicts_with_mandatory" }))
    }

    func testPurposeTreeValidationRequiresGoalsForMandatoryPurposes() throws {
        let guidance = TaxonomyPackage.Guidance(
            rootPurposeTermID: "purpose.human-equal-worth",
            contributionPurposeTermID: "purpose.net-positive-contribution",
            articleReference: "UDHR Article 1",
            incentiveOnly: true,
            goalPolicy: .init(mode: .encouraged, description: "Encouraged goals")
        )

        let terms: [Term] = [
            .init(termId: "purpose.human-equal-worth", labels: ["en-US": "Equal Worth"], definition: "Root", kind: .purpose),
            .init(
                termId: "purpose.net-positive-contribution",
                labels: ["en-US": "Net Positive"],
                definition: "Contribution",
                kind: .purpose,
                relations: [.init(kind: .broader, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "goal.net-positive-impact",
                labels: ["en-US": "Net Positive Impact"],
                definition: "Goal for contribution",
                kind: .goal,
                relations: [.init(kind: .usedWith, target: "purpose.net-positive-contribution")]
            )
        ]

        let package = TaxonomyPackage(
            namespace: "haven.core",
            version: "0.1.0",
            dependsOn: [],
            terms: terms,
            guidance: guidance
        )

        let resolver = try makeResolver(packages: [package])
        let result = try resolver.validatePurposeTree(namespace: "haven.core")

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains(where: { $0.code == "mandatory_purpose.goal_missing" && $0.termID == "purpose.human-equal-worth" }))
    }

    func testPurposeTreeValidationRejectsPurposeWithoutMandatoryInheritancePath() throws {
        let guidance = TaxonomyPackage.Guidance(
            rootPurposeTermID: "purpose.human-equal-worth",
            contributionPurposeTermID: "purpose.net-positive-contribution",
            articleReference: "UDHR Article 1",
            incentiveOnly: true,
            goalPolicy: .init(mode: .encouraged, description: "Encouraged goals")
        )

        let terms: [Term] = [
            .init(termId: "purpose.human-equal-worth", labels: ["en-US": "Equal Worth"], definition: "Root", kind: .purpose),
            .init(
                termId: "purpose.net-positive-contribution",
                labels: ["en-US": "Net Positive"],
                definition: "Contribution",
                kind: .purpose,
                relations: [.init(kind: .broader, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "purpose.orphan",
                labels: ["en-US": "Orphan Purpose"],
                definition: "No path to mandatory purposes",
                kind: .purpose
            ),
            .init(
                termId: "goal.uphold-equal-worth",
                labels: ["en-US": "Uphold Equal Worth"],
                definition: "Goal for root",
                kind: .goal,
                relations: [.init(kind: .usedWith, target: "purpose.human-equal-worth")]
            ),
            .init(
                termId: "goal.net-positive-impact",
                labels: ["en-US": "Net Positive Impact"],
                definition: "Goal for contribution",
                kind: .goal,
                relations: [.init(kind: .usedWith, target: "purpose.net-positive-contribution")]
            )
        ]

        let package = TaxonomyPackage(
            namespace: "haven.core",
            version: "0.1.0",
            dependsOn: [],
            terms: terms,
            guidance: guidance
        )

        let resolver = try makeResolver(packages: [package])
        let result = try resolver.validatePurposeTree(namespace: "haven.core")

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains(where: { $0.code == "purpose.inheritance_missing" && $0.termID == "purpose.orphan" }))
    }

    func testPurposeTreeValidationForSDGNamespacePasses() throws {
        let resolver = try makeResolver()
        let result = try resolver.validatePurposeTree(namespace: "haven.sdg")

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertTrue(result.warningCount >= 0)
    }
}
