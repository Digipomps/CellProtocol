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

extension SkeletonReachabilityAuditTests {
    private func wpR1Tree(row: SkeletonVStack = .init(elements: [])) -> SkeletonTree {
        SkeletonTree(keypath: "tree.nodes", idKeypath: "id", parentIDKeypath: "parent",
            levelKeypath: "level", leadingInsetKeypath: "inset", hasChildrenKeypath: "hasChildren",
            expandedKeypath: "expanded", selectedIDStateKeypath: "tree.selected",
            selectionActionKeypath: "tree.select", expansionActionKeypath: "tree.expand", rowSkeleton: row)
    }

    private func wpR1Mount(_ id: String = "instance-a") -> SkeletonElement {
        .ComponentSurface(SkeletonComponentSurface(sourceKeypath: "sources.program", instanceID: id, variant: .pinned))
    }

    func testWPR1TreeRequiresBothOwnActions() {
        var tree = wpR1Tree()
        XCTAssertTrue(SkeletonReachabilityAudit.audit(.Tree(tree)).isEmpty)
        XCTAssertEqual(SkeletonReachabilityAudit.reachableActionKeypaths(.Tree(tree)), ["tree.select", "tree.expand"])
        for missing in ["selectionActionKeypath", "expansionActionKeypath", "both"] {
            tree = wpR1Tree()
            if missing != "expansionActionKeypath" { tree.selectionActionKeypath = "" }
            if missing != "selectionActionKeypath" { tree.expansionActionKeypath = " \n" }
            let findings = SkeletonReachabilityAudit.audit(.Tree(tree))
            XCTAssertEqual(findings.filter { $0.kind == .missingRequiredAction }.count, missing == "both" ? 2 : 1)
            if missing != "both" { XCTAssertTrue(findings[0].detail.contains(missing)) }
        }
    }

    func testWPR1TreeRowsGetItemContextAndNestedChildActions() {
        let button = gated(SkeletonCondition(scope: .item, keypath: "canMove", equals: .bool(true)), importButton)
        XCTAssertEqual(SkeletonReachabilityAudit.audit(button).first?.kind, .unreachableAtRootScope)
        let tree = wpR1Tree(row: .init(elements: [.HStack(.init(elements: [button]))]))
        XCTAssertTrue(SkeletonReachabilityAudit.audit(.Tree(tree)).isEmpty)
        XCTAssertTrue(SkeletonReachabilityAudit.reachableActionKeypaths(.Tree(tree)).contains("contactImport.import.commit"))
    }

    func testWPR1TreeRowAndDisclosureModifiersOwnTheirActions() {
        var tree = wpR1Tree(row: .init(elements: [importButton]))
        var hidden = SkeletonModifiers(); hidden.hidden = true
        tree.disclosureModifiers = hidden
        var actions = SkeletonReachabilityAudit.reachableActionKeypaths(.Tree(tree))
        XCTAssertTrue(actions.contains("tree.select"))
        XCTAssertFalse(actions.contains("tree.expand"))
        XCTAssertEqual(SkeletonReachabilityAudit.audit(.Tree(tree)).first?.lostActionKeypaths, ["tree.expand"])
        tree.rowModifiers = hidden
        actions = SkeletonReachabilityAudit.reachableActionKeypaths(.Tree(tree))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(SkeletonReachabilityAudit.audit(.Tree(tree)).first?.lostActionKeypaths,
                       ["contactImport.import.commit", "tree.expand", "tree.select"])
    }

    func testWPR1MissingComponentResolutionNeverPassesAudit() {
        let findings = SkeletonReachabilityAudit.audit(wpR1Mount())
        XCTAssertEqual(findings.first?.kind, .unresolvedComponentDefinition)
        XCTAssertTrue(findings.first?.detail.contains("instance-a") == true)
        XCTAssertTrue(SkeletonReachabilityAudit.reachableActionKeypaths(wpR1Mount()).isEmpty)
    }

    func testWPR1ResolvedDefinitionExposesActionsAndOmissionsAreDetected() {
        let resolved = SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: self.importButton)
        let required: Set<String> = ["contactImport.import.commit", "program.refresh"]
        let findings = SkeletonReachabilityAudit.audit(wpR1Mount(), requiredActionKeypaths: required) { _ in resolved }
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].kind, .missingRequiredAction)
        XCTAssertEqual(findings[0].lostActionKeypaths, ["program.refresh"])
        XCTAssertEqual(SkeletonReachabilityAudit.reachableActionKeypaths(wpR1Mount()) { _ in resolved }, ["contactImport.import.commit"])
        let invalid = SkeletonResolvedComponent(componentID: "program", revision: "r1",
            skeleton: .Button(.init(keypath: "", label: "Broken")))
        XCTAssertEqual(SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in invalid }.first?.kind, .missingRequiredAction)
    }

    func testWPR1ResolvedDefinitionMustReceiveTheCorrectDataScope() {
        let gatedAction = gated(SkeletonCondition(scope: .item, keypath: "canRefresh", equals: .bool(true)), importButton)
        var definition = SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: gatedAction,
                                                    dataContext: .init(root: true))
        var findings = SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in definition }
        XCTAssertEqual(findings.first?.kind, .unreachableAtRootScope)
        XCTAssertEqual(findings.first?.lostActionKeypaths, ["contactImport.import.commit"])
        XCTAssertTrue(findings.first?.path.contains("instance-a:program@r1") == true)
        definition.dataContext = .init(item: true)
        findings = SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in definition }
        XCTAssertTrue(findings.isEmpty)
        XCTAssertEqual(SkeletonReachabilityAudit.reachableActionKeypaths(wpR1Mount()) { _ in definition }, ["contactImport.import.commit"])
    }

    func testWPR1WireMountAdapterPreservesHostRootAndReplacesEnclosingItem() {
        let itemAction = gated(SkeletonCondition(scope: .item, keypath: "canRefresh", equals: .bool(true)), importButton)
        var mount = SkeletonComponentMount(componentID: "program", revision: "r1",
            sourceCellEndpoint: "cell:///Program", skeleton: itemAction, item: .object(["canRefresh": .bool(true)]))
        let withItem = SkeletonResolvedComponent(mount: mount, hostContext: .init())
        XCTAssertEqual(withItem.componentID, "program")
        XCTAssertEqual(withItem.revision, "r1")
        XCTAssertEqual(withItem.dataContext, .init(item: true))
        XCTAssertTrue(SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in withItem }.isEmpty)
        for absent in [nil, ValueType.null] as [ValueType?] {
            mount.item = absent
            let resolved = SkeletonResolvedComponent(mount: mount, hostContext: .row)
            XCTAssertEqual(resolved.dataContext, .init(root: true, item: false, context: true))
            let findings = SkeletonReachabilityAudit.audit(wpR1Mount(), context: .row) { _ in resolved }
            XCTAssertEqual(findings.first?.kind, .unreachableAtRootScope)
            XCTAssertEqual(findings.first?.lostActionKeypaths, ["contactImport.import.commit"])
        }
    }

    func testWPR1WireMountItemDoesNotInventHostRootAvailability() {
        let rootAction = gated(SkeletonCondition(scope: .root, keypath: "canRefresh", equals: .bool(true)), importButton)
        let mount = SkeletonComponentMount(componentID: "program", revision: "r1",
            sourceCellEndpoint: "cell:///Program", skeleton: rootAction, item: .object(["canRefresh": .bool(true)]))
        let noRoot = SkeletonResolvedComponent(mount: mount, hostContext: .init())
        XCTAssertEqual(SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in noRoot }.first?.kind, .unreachableAtRootScope)
        let withRoot = SkeletonResolvedComponent(mount: mount, hostContext: .init(root: true))
        XCTAssertTrue(SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in withRoot }.isEmpty)
        XCTAssertEqual(SkeletonReachabilityAudit.reachableActionKeypaths(wpR1Mount()) { _ in withRoot }, ["contactImport.import.commit"])
    }

    func testWPR1WireMountSharedFixtureResolvesBothInstances() throws {
        struct Fixture: Decodable {
            struct Root: Decodable { let mounts: [String: SkeletonComponentMount] }
            let skeleton: SkeletonElement
            let initialRoot: Root
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/skeleton-wp-r1/component-mount-two-instances.json")))
        var seen: [String] = []
        let findings = SkeletonReachabilityAudit.audit(fixture.skeleton, context: .init(root: true),
                                                      requiredActionKeypaths: ["actions.refresh"]) { surface in
            seen.append(surface.instanceID ?? "")
            return fixture.initialRoot.mounts[surface.instanceID ?? ""].map {
                SkeletonResolvedComponent(mount: $0, hostContext: .init(root: true))
            }
        }
        XCTAssertEqual(seen, ["A", "B"])
        XCTAssertTrue(findings.isEmpty, "\(findings)")
    }

    func testWPR1ComponentInTreeRowInheritsDataWithoutInventingItAtRoot() {
        let gatedAction = gated(SkeletonCondition(scope: .item, keypath: "canRefresh", equals: .bool(true)), importButton)
        let definition = SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: gatedAction)
        XCTAssertEqual(SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in definition }.first?.kind, .unreachableAtRootScope)
        let tree = wpR1Tree(row: .init(elements: [wpR1Mount()]))
        XCTAssertTrue(SkeletonReachabilityAudit.audit(.Tree(tree)) { _ in definition }.isEmpty)
    }

    func testWPR1TwoInstancesResolveIndependentlyAndRecursiveDefinitionsStop() {
        let surface = SkeletonElement.VStack(.init(elements: [wpR1Mount("a"), wpR1Mount("b")]))
        var seen: [String] = []
        let actions = SkeletonReachabilityAudit.reachableActionKeypaths(surface) { mount in
            seen.append(mount.instanceID ?? "")
            return SkeletonResolvedComponent(componentID: "program", revision: "r1",
                skeleton: .Button(.init(keypath: "refresh.\(mount.instanceID ?? "")", label: "Refresh")))
        }
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(actions, ["refresh.a", "refresh.b"])
        let duplicate = SkeletonElement.VStack(.init(elements: [wpR1Mount("a"), wpR1Mount("a")]))
        XCTAssertTrue(SkeletonReachabilityAudit.audit(duplicate) { _ in
            SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: self.importButton)
        }.contains { $0.kind == .duplicateComponentInstanceID })
        let recursion = SkeletonReachabilityAudit.audit(wpR1Mount()) { _ in
            SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: self.wpR1Mount("nested"))
        }
        XCTAssertEqual(recursion.first?.kind, .recursiveComponentDefinition)
    }

    func testWPR1HiddenComponentReportsResolvedLostActionsAndUnresolvedChildren() {
        var hidden = SkeletonModifiers(); hidden.hidden = true
        let root = SkeletonElement.VStack(.init(elements: [wpR1Mount()], modifiers: hidden))
        let findings = SkeletonReachabilityAudit.audit(root) { _ in
            SkeletonResolvedComponent(componentID: "program", revision: "r1", skeleton: self.importButton)
        }
        XCTAssertEqual(findings.first?.lostActionKeypaths, ["contactImport.import.commit"])
        XCTAssertTrue(SkeletonReachabilityAudit.audit(root).contains { $0.kind == .unresolvedComponentDefinition })
    }

    func testWPR1MalformedConditionsRemainDeadInsideRows() {
        for condition in [SkeletonCondition(scope: .item), .expression(.init(isMalformed: true))] {
            let tree = wpR1Tree(row: .init(elements: [gated(condition, importButton)]))
            XCTAssertFalse(SkeletonReachabilityAudit.audit(.Tree(tree)).isEmpty)
            XCTAssertFalse(SkeletonReachabilityAudit.reachableActionKeypaths(.Tree(tree)).contains("contactImport.import.commit"))
        }
    }

    func testWPR1SectionHeaderFooterAndDropActionsAreTraversed() {
        var drop = SkeletonModifiers(); drop.dropActionKeypath = "program.drop"
        let header = SkeletonElement.VStack(.init(elements: [importButton], modifiers: drop))
        let section = SkeletonElement.Section(SkeletonSection(header: header, footer: .Button(.init(keypath: "program.close", label: "Close")), content: []))
        XCTAssertEqual(SkeletonReachabilityAudit.reachableActionKeypaths(section),
                       ["program.drop", "program.close", "contactImport.import.commit"])
    }
}
