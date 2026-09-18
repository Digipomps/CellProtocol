// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// The audit exists because of one shipped surface: HAVEN's Relations
/// workbench had five sections gated on `relations.state…` at root scope,
/// where the renderer passes nil. Every gate evaluated false, every section
/// vanished, every test stayed green, and the owner got a card with a title
/// and no way in. These pin the rule that would have caught it.
final class SkeletonReachabilityAuditTests: XCTestCase {

    private func gated(_ condition: SkeletonCondition, _ element: SkeletonElement) -> SkeletonElement {
        var stack = SkeletonVStack(elements: [element])
        var modifiers = SkeletonModifiers()
        modifiers.visibility = SkeletonVisibilityRule(when: condition)
        stack.modifiers = modifiers
        return .VStack(stack)
    }

    private var importButton: SkeletonElement {
        .Button(SkeletonButton(keypath: "contactImport.import.commit", label: "Legg dem inn"))
    }

    // MARK: The shipped failure

    func testASectionGatedOnCellStateAtRootScopeIsReportedDead() {
        let surface = SkeletonVStack(elements: [
            .Text(SkeletonText(text: "Relasjoner")),
            gated(
                SkeletonCondition(scope: .root, keypath: "relations.state.stats.total", equals: .integer(0)),
                .Button(SkeletonButton(keypath: "addressBook.addressBook.pickFile", label: "Hent fra en fil"))
            )
        ])

        let findings = SkeletonReachabilityAudit.audit(.VStack(surface))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.kind, .unreachableAtRootScope)
        XCTAssertTrue(findings.first?.detail.contains("relations.state.stats.total") == true)
        // The finding names what the owner loses, not just that a node is hidden.
        XCTAssertEqual(findings.first?.lostActionKeypaths, ["addressBook.addressBook.pickFile"])

        XCTAssertFalse(
            SkeletonReachabilityAudit.reachableActionKeypaths(.VStack(surface))
                .contains("addressBook.addressBook.pickFile")
        )
    }

    /// `notEquals` fails the same way, and this is the form that gates the
    /// everyday list — so a surface is empty both when you have nothing and
    /// when you have something.
    func testNotEqualsIsJustAsDeadAtRootScope() {
        let element = gated(
            SkeletonCondition(scope: .root, keypath: "relations.state.stats.total", notEquals: .integer(0)),
            importButton
        )
        XCTAssertEqual(SkeletonReachabilityAudit.audit(element).first?.kind, .unreachableAtRootScope)
    }

    // MARK: What is legitimately fine

    /// Inside a list row the renderer passes the row's value down, so a
    /// condition there is answerable at runtime and the audit must stay quiet.
    func testAConditionInsideAListRowIsLeftAlone() {
        var row = SkeletonVStack(elements: [
            gated(
                SkeletonCondition(scope: .item, keypath: "canInvite", equals: .bool(true)),
                importButton
            )
        ])
        row.modifiers = nil
        let list = SkeletonList(topic: nil, keypath: "relations.state.records", flowElementSkeleton: row)

        XCTAssertTrue(SkeletonReachabilityAudit.audit(.List(list)).isEmpty)
        XCTAssertTrue(
            SkeletonReachabilityAudit.reachableActionKeypaths(.List(list))
                .contains("contactImport.import.commit")
        )
    }

    func testAnUngatedSurfaceHasNoFindings() {
        let surface = SkeletonVStack(elements: [.Text(SkeletonText(text: "Hei")), importButton])
        XCTAssertTrue(SkeletonReachabilityAudit.audit(.VStack(surface)).isEmpty)
    }

    // MARK: The other silent forms

    func testAConditionWithNoPredicateHidesAndIsReported() {
        let element = gated(SkeletonCondition(scope: .root), importButton)
        XCTAssertEqual(SkeletonReachabilityAudit.audit(element).first?.kind, .conditionHasNoPredicate)
    }

    func testAMalformedConditionIsReported() {
        let element = gated(.expression(SkeletonConditionExpression(isMalformed: true)), importButton)
        XCTAssertEqual(SkeletonReachabilityAudit.audit(element).first?.kind, .malformedCondition)
    }

    func testHiddenTrueIsReportedWithWhatItCosts() {
        var stack = SkeletonVStack(elements: [importButton])
        var modifiers = SkeletonModifiers()
        modifiers.hidden = true
        stack.modifiers = modifiers
        let findings = SkeletonReachabilityAudit.audit(.VStack(stack))
        XCTAssertEqual(findings.first?.kind, .hiddenModifier)
        XCTAssertEqual(findings.first?.lostActionKeypaths, ["contactImport.import.commit"])
    }

    /// `exists: false` is the one root-scoped form that is true when nothing
    /// resolves — so it must not be reported, or the audit cries wolf.
    func testExistsFalseIsReachableAtRootScope() {
        let element = gated(
            SkeletonCondition(scope: .root, keypath: "relations.state.error", exists: false),
            importButton
        )
        XCTAssertTrue(SkeletonReachabilityAudit.audit(element).isEmpty)
    }

    /// One finding per dead subtree, not one per node inside it.
    func testADeadSubtreeIsReportedOnceWithEveryActionItSwallows() {
        let element = gated(
            SkeletonCondition(scope: .root, keypath: "a.b", equals: .bool(true)),
            .VStack(SkeletonVStack(elements: [
                .Button(SkeletonButton(keypath: "one", label: "1")),
                .VStack(SkeletonVStack(elements: [.Button(SkeletonButton(keypath: "two", label: "2"))]))
            ]))
        )
        let findings = SkeletonReachabilityAudit.audit(element)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.lostActionKeypaths, ["one", "two"])
    }
}
