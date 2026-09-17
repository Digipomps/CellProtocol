// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

//
//  SkeletonReachabilityAudit.swift
//  CellBase
//
//  Answers one question a schema check cannot: *will the person ever see
//  this?*
//
//  A visibility condition that cannot be resolved evaluates to `false`, which
//  is indistinguishable from a condition that is legitimately not met. So an
//  element gated on data the renderer never has at that position is not
//  reported as broken — it simply never appears, and the surface looks
//  finished while doing nothing. That is how a relations surface shipped with
//  every way in hidden: five sections gated on `relations.state…` at root
//  scope, where the renderer passes `nil`.
//
//  The audit decides reachability by calling the renderer's own evaluation
//  with the renderer's own root inputs, so it cannot drift from what the
//  screen does. Scope is the whole trick:
//
//  - At **root** the renderer supplies no value (`SkeletonView(element:)`
//    defaults `userInfoValue` to nil), so every keypath resolves to nil.
//  - Inside a **row** — a `List`/`Grid` item or a `Reference` flow element —
//    the row's value is passed down, so conditions there are answerable at
//    runtime and the audit leaves them alone.
//

import Foundation

public struct SkeletonReachabilityFinding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The condition is false for every possible runtime state at this
        /// position, because nothing can be resolved here.
        case unreachableAtRootScope
        /// A condition object with no predicate at all. `evaluate` returns
        /// `evaluatedAnyPredicate`, so this hides the element everywhere.
        case conditionHasNoPredicate
        /// Malformed after decoding; evaluates to false forever.
        case malformedCondition
        /// `modifiers.hidden == true` left in a shipped surface.
        case hiddenModifier
    }

    public var kind: Kind
    /// Where in the tree, in author terms: `VStack[1].Section[0].Button[2]`.
    public var path: String
    public var elementKind: String
    public var detail: String
    /// The actions the owner loses with this subtree. This is what turns a
    /// structural finding into a purpose finding: not "a node is hidden" but
    /// "the person cannot import a file".
    public var lostActionKeypaths: [String]

    public init(kind: Kind, path: String, elementKind: String, detail: String, lostActionKeypaths: [String]) {
        self.kind = kind
        self.path = path
        self.elementKind = elementKind
        self.detail = detail
        self.lostActionKeypaths = lostActionKeypaths
    }
}

public enum SkeletonReachabilityAudit {

    /// Every element that can never be seen, and every action lost with it.
    /// An empty result means nothing is *structurally* dead; it does not
    /// promise the surface is right, only that it is not invisible.
    public static func audit(_ element: SkeletonElement) -> [SkeletonReachabilityFinding] {
        var findings: [SkeletonReachabilityFinding] = []
        walk(element, path: "", hasRowData: false, findings: &findings)
        return findings
    }

    /// Action keypaths the surface offers where the person can actually reach
    /// them. Use it to check a purpose: "the owner can import a file" means
    /// this contains the import action.
    public static func reachableActionKeypaths(_ element: SkeletonElement) -> Set<String> {
        var reachable: Set<String> = []
        collectReachableActions(element, hasRowData: false, into: &reachable)
        return reachable
    }

    // MARK: - Walk

    private static func walk(
        _ element: SkeletonElement,
        path: String,
        hasRowData: Bool,
        findings: inout [SkeletonReachabilityFinding]
    ) {
        let kind = elementKind(element)
        let here = path.isEmpty ? kind : "\(path).\(kind)"
        let modifiers = modifiers(of: element)

        if modifiers?.hidden == true {
            findings.append(SkeletonReachabilityFinding(
                kind: .hiddenModifier,
                path: here,
                elementKind: kind,
                detail: "hidden = true. Nothing below this point is drawn.",
                lostActionKeypaths: actionKeypaths(in: element)
            ))
            return
        }

        if let rule = modifiers?.visibility, let condition = rule.when {
            if let dead = deadCondition(condition, hasRowData: hasRowData) {
                findings.append(SkeletonReachabilityFinding(
                    kind: dead.kind,
                    path: here,
                    elementKind: kind,
                    detail: dead.detail,
                    lostActionKeypaths: actionKeypaths(in: element)
                ))
                // Do not descend: everything below inherits the same fate, and
                // one finding per dead subtree reads better than twenty.
                return
            }
        }

        for (index, child) in children(of: element).enumerated() {
            walk(
                child.element,
                path: "\(here)[\(index)]",
                hasRowData: hasRowData || child.providesRowData,
                findings: &findings
            )
        }
    }

    private struct DeadCondition {
        var kind: SkeletonReachabilityFinding.Kind
        var detail: String
    }

    /// A condition is dead here when the renderer's own evaluation, given the
    /// values the renderer will actually have at this position, cannot return
    /// true. Inside a row the values are the row's and are unknown until
    /// runtime, so the audit says nothing.
    private static func deadCondition(
        _ condition: SkeletonCondition,
        hasRowData: Bool
    ) -> DeadCondition? {
        guard !hasRowData else { return nil }

        if case let .expression(expression) = condition {
            if expression.isMalformed {
                return DeadCondition(
                    kind: .malformedCondition,
                    detail: "The condition did not decode. It is false forever."
                )
            }
            if hasNoPredicate(expression) {
                return DeadCondition(
                    kind: .conditionHasNoPredicate,
                    detail: "The condition states no predicate, so it evaluates to false and hides the element everywhere."
                )
            }
        }

        // The renderer's own call, with the renderer's own root inputs.
        if condition.evaluate(root: nil, item: nil, context: nil) == false {
            return DeadCondition(
                kind: .unreachableAtRootScope,
                detail: "At root the renderer passes no value, so \(describe(condition)) resolves to nothing and the condition is false. "
                    + "Move the element inside a List/Grid/Reference row, where the row's value is passed down, "
                    + "or let the cell decide and bind content instead of gating the section."
            )
        }
        return nil
    }

    private static func hasNoPredicate(_ expression: SkeletonConditionExpression) -> Bool {
        expression.exists == nil
            && expression.equals == nil
            && expression.notEquals == nil
            && expression.inValues == nil
            && expression.contains == nil
            && expression.allOf == nil
            && expression.anyOf == nil
            && expression.not == nil
    }

    private static func describe(_ condition: SkeletonCondition) -> String {
        guard case let .expression(expression) = condition else { return "the condition" }
        let scope = (expression.scope ?? .root).rawValue
        guard let keypath = expression.keypath, !keypath.isEmpty else {
            return "the \(scope)-scoped condition"
        }
        return "`\(keypath)` (\(scope) scope)"
    }

    // MARK: - Reachable actions

    private static func collectReachableActions(
        _ element: SkeletonElement,
        hasRowData: Bool,
        into reachable: inout Set<String>
    ) {
        let modifiers = modifiers(of: element)
        if modifiers?.hidden == true { return }
        if let condition = modifiers?.visibility?.when,
           deadCondition(condition, hasRowData: hasRowData) != nil {
            return
        }
        for keypath in actionKeypaths(inOnly: element) {
            reachable.insert(keypath)
        }
        for child in children(of: element) {
            collectReachableActions(child.element, hasRowData: hasRowData || child.providesRowData, into: &reachable)
        }
    }

    // MARK: - Tree shape

    private struct Child {
        var element: SkeletonElement
        /// True when the renderer passes a per-row value into this subtree, so
        /// conditions below it can resolve at runtime.
        var providesRowData: Bool
    }

    private static func children(of element: SkeletonElement) -> [Child] {
        func plain(_ elements: [SkeletonElement]) -> [Child] {
            elements.map { Child(element: $0, providesRowData: false) }
        }
        switch element {
        case .VStack(let value): return plain(value.elements)
        case .HStack(let value): return plain(value.elements)
        case .ZStack(let value): return plain(value.elements)
        case .ScrollView(let value): return plain(value.elements)
        case .Section(let value): return plain(value.content)
        case .Object(let value): return plain(Array(value.elements.values))
        case .Tabs(let value): return value.panels.flatMap { plain($0.content) }
        case .Grid(let value):
            var result = plain(value.elements)
            if let item = value.itemSkeleton {
                result.append(Child(element: item, providesRowData: value.keypath != nil))
            }
            return result
        case .List(let value):
            guard let row = value.flowElementSkeleton else { return [] }
            return [Child(element: .VStack(row), providesRowData: true)]
        case .Reference(let value):
            guard let row = value.flowElementSkeleton else { return [] }
            return [Child(element: .VStack(row), providesRowData: true)]
        default:
            return []
        }
    }

    private static func elementKind(_ element: SkeletonElement) -> String {
        switch element {
        case .List: return "List"
        case .Object: return "Object"
        case .Spacer: return "Spacer"
        case .Image: return "Image"
        case .Text: return "Text"
        case .AttachmentField: return "AttachmentField"
        case .FileUpload: return "FileUpload"
        case .TextField: return "TextField"
        case .TextArea: return "TextArea"
        case .HStack: return "HStack"
        case .VStack: return "VStack"
        case .Reference: return "Reference"
        case .Button: return "Button"
        case .Divider: return "Divider"
        case .ScrollView: return "ScrollView"
        case .Section: return "Section"
        case .Tabs: return "Tabs"
        case .NavigationBar: return "NavigationBar"
        case .ZStack: return "ZStack"
        case .Grid: return "Grid"
        case .Toggle: return "Toggle"
        case .Picker: return "Picker"
        case .Visualization: return "Visualization"
        case .Unsupported: return "Unsupported"
        @unknown default: return "Unknown"
        }
    }

    private static func modifiers(of element: SkeletonElement) -> SkeletonModifiers? {
        switch element {
        case .List(let value): return value.modifiers
        case .Object(let value): return value.modifiers
        case .Spacer(let value): return value.modifiers
        case .Image(let value): return value.modifiers
        case .Text(let value): return value.modifiers
        case .AttachmentField(let value): return value.modifiers
        case .FileUpload(let value): return value.modifiers
        case .TextField(let value): return value.modifiers
        case .TextArea(let value): return value.modifiers
        case .HStack(let value): return value.modifiers
        case .VStack(let value): return value.modifiers
        case .Reference(let value): return value.modifiers
        case .Button(let value): return value.modifiers
        case .Divider(let value): return value.modifiers
        case .ScrollView(let value): return value.modifiers
        case .Section(let value): return value.modifiers
        case .Tabs(let value): return value.modifiers
        case .NavigationBar(let value): return value.modifiers
        case .ZStack(let value): return value.modifiers
        case .Grid(let value): return value.modifiers
        case .Toggle(let value): return value.modifiers
        case .Picker(let value): return value.modifiers
        case .Visualization(let value): return value.modifiers
        case .Unsupported(let value): return value.modifiers
        @unknown default: return nil
        }
    }

    /// Actions on this element only.
    private static func actionKeypaths(inOnly element: SkeletonElement) -> [String] {
        var keypaths: [String] = []
        func add(_ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            keypaths.append(value)
        }
        switch element {
        case .Button(let value): add(value.keypath)
        case .TextField(let value): add(value.targetKeypath)
        case .TextArea(let value): add(value.targetKeypath)
        case .Toggle(let value): add(value.keypath)
        case .Picker(let value): add(value.selectionActionKeypath)
        case .FileUpload(let value): add(value.actionKeypath)
        case .Visualization(let value): add(value.actionKeypath)
        case .List(let value):
            add(value.selectionActionKeypath)
            add(value.activationActionKeypath)
        case .Tabs(let value): add(value.selectionActionKeypath)
        case .NavigationBar(let value): value.items.forEach { add($0.keypath) }
        default: break
        }
        return keypaths
    }

    /// Actions on this element and everything below it.
    private static func actionKeypaths(in element: SkeletonElement) -> [String] {
        var keypaths = actionKeypaths(inOnly: element)
        for child in children(of: element) {
            keypaths.append(contentsOf: actionKeypaths(in: child.element))
        }
        var seen = Set<String>()
        return keypaths.filter { seen.insert($0).inserted }
    }
}
