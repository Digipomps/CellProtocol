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
//    the row's value is passed down, so data-dependent conditions may be true
//    at runtime. Malformed and constant-false conditions are still reported.
//  - ComponentSurface uses the resolved definition and its mounting context.
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
        case missingRequiredAction
        case unresolvedComponentDefinition
        case recursiveComponentDefinition
        case duplicateComponentInstanceID
        case unsupportedElement
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

/// Availability, not example values. An available scope may vary at runtime;
/// an unavailable scope always resolves to nil. Existing List/Reference rows
/// supply their row value for all three scopes, as the current renderers do.
public struct SkeletonReachabilityContext: Equatable {
    public var root: Bool
    public var item: Bool
    public var context: Bool

    public init(root: Bool = false, item: Bool = false, context: Bool = false) {
        self.root = root
        self.item = item
        self.context = context
    }

    public static let row = SkeletonReachabilityContext(root: true, item: true, context: true)

    fileprivate func available(_ scope: SkeletonVisibilityScope) -> Bool {
        switch scope {
        case .root: return root
        case .item: return item
        case .context: return context
        }
    }
}

/// An audit input, not a wire-format registry. The host resolves sourceKeypath
/// against the surface's instance and supplies the exact definition/revision it
/// will mount. No I/O is performed by the audit. Nil dataContext inherits the
/// mounting position; explicit availability describes a new binding context.
public struct SkeletonResolvedComponent {
    public var componentID: String
    public var revision: String
    public var skeleton: SkeletonElement
    public var dataContext: SkeletonReachabilityContext?

    public init(componentID: String, revision: String, skeleton: SkeletonElement,
                dataContext: SkeletonReachabilityContext? = nil) {
        self.componentID = componentID
        self.revision = revision
        self.skeleton = skeleton
        self.dataContext = dataContext
    }

    /// Adapts the wire mount without mistaking its item for the host root.
    /// Host root/context availability is explicit; an enclosing row's item is
    /// replaced even when this mount has no item. Endpoint routing and access
    /// checks belong to the runtime, outside this structural reachability audit.
    public init(mount: SkeletonComponentMount, hostContext: SkeletonReachabilityContext) {
        let hasItem: Bool
        if let item = mount.item, case .null = item { hasItem = false }
        else { hasItem = mount.item != nil }
        self.init(componentID: mount.componentID, revision: mount.revision, skeleton: mount.skeleton,
                  dataContext: .init(root: hostContext.root, item: hasItem, context: hostContext.context))
    }
}

public enum SkeletonReachabilityAudit {
    public typealias ComponentResolver = (SkeletonComponentSurface) -> SkeletonResolvedComponent?

    /// Structural reachability only; this does not prove data exists, an action
    /// is authorized, or a separate conversational entry point works (T-P2).
    public static func audit(_ element: SkeletonElement,
                             context: SkeletonReachabilityContext = .init(),
                             requiredActionKeypaths: Set<String> = [],
                             resolveComponent: ComponentResolver? = nil) -> [SkeletonReachabilityFinding] {
        var builder = Builder(resolveComponent: resolveComponent)
        let root = builder.build(element, path: "", context: context, definitions: [])
        var findings: [SkeletonReachabilityFinding] = []
        walk(root, findings: &findings)
        for action in requiredActionKeypaths.subtracting(reachable(root)).sorted() {
            findings.append(SkeletonReachabilityFinding(kind: .missingRequiredAction, path: root.path,
                elementKind: root.kind, detail: "Required action \(action) is not reachable.", lostActionKeypaths: [action]))
        }
        return findings
    }

    public static func reachableActionKeypaths(_ element: SkeletonElement,
                                              context: SkeletonReachabilityContext = .init(),
                                              resolveComponent: ComponentResolver? = nil) -> Set<String> {
        var builder = Builder(resolveComponent: resolveComponent)
        let root = builder.build(element, path: "", context: context, definitions: [])
        return reachable(root)
    }

    private struct DefinitionID: Hashable {
        var componentID: String
        var revision: String
    }

    private struct Node {
        var path: String
        var kind: String
        var context: SkeletonReachabilityContext
        var modifiers: SkeletonModifiers?
        var actions: [String]
        var children: [Node] = []
        var findings: [SkeletonReachabilityFinding] = []

        var allActions: [String] { Array(Set(actions + modifierActions(modifiers) + children.flatMap(\.allActions))).sorted() }
    }

    private struct Builder {
        let resolveComponent: ComponentResolver?
        var instanceIDs: Set<String> = []

        mutating func build(_ element: SkeletonElement, path: String,
                            context: SkeletonReachabilityContext, definitions: Set<DefinitionID>) -> Node {
            let kind = elementKind(element)
            let here = path.isEmpty ? kind : "\(path).\(kind)"
            var node = Node(path: here, kind: kind, context: context,
                            modifiers: modifiers(of: element), actions: ownActions(element))
            func finding(_ kind: SkeletonReachabilityFinding.Kind, _ detail: String) -> SkeletonReachabilityFinding {
                SkeletonReachabilityFinding(kind: kind, path: here, elementKind: node.kind,
                                            detail: detail, lostActionKeypaths: [])
            }
            switch element {
            case .Unsupported(let unsupported):
                node.findings.append(finding(.unsupportedElement, unsupported.reason ?? unsupported.elementType))
            case .Button(let button) where !nonempty(button.keypath) && !nonempty(button.keypathKeypath):
                node.findings.append(finding(.missingRequiredAction, "Button requires keypath or keypathKeypath."))
            case .Tree(let tree):
                for (name, value) in [("selectionActionKeypath", tree.selectionActionKeypath),
                                      ("expansionActionKeypath", tree.expansionActionKeypath)] where !nonempty(value) {
                    node.findings.append(finding(.missingRequiredAction, "Tree requires \(name)."))
                }
                // Row hit area owns selection. Disclosure owns expansion; hiding
                // either must remove its action from reachableActionKeypaths.
                var row = Node(path: here + ".row", kind: "TreeRow", context: .row,
                               modifiers: tree.rowModifiers, actions: valid([tree.selectionActionKeypath]))
                row.children.append(Node(path: here + ".row.disclosure", kind: "TreeDisclosure", context: .row,
                    modifiers: tree.disclosureModifiers, actions: valid([tree.expansionActionKeypath])))
                row.children.append(build(.VStack(tree.rowSkeleton), path: here + ".rowSkeleton",
                                          context: .row, definitions: definitions))
                node.children = [row]
            case .ComponentSurface(let surface):
                guard instanceIDs.insert(surface.instanceID).inserted else {
                    node.findings.append(finding(.duplicateComponentInstanceID, "Duplicate instanceID: \(surface.instanceID)."))
                    return node
                }
                guard let resolved = resolveComponent?(surface), nonempty(resolved.componentID), nonempty(resolved.revision) else {
                    node.findings.append(finding(.unresolvedComponentDefinition,
                        "No resolved definition/revision for instance \(surface.instanceID), source \(surface.sourceKeypath)."))
                    return node
                }
                let identity = DefinitionID(componentID: resolved.componentID, revision: resolved.revision)
                guard !definitions.contains(identity) else {
                    node.findings.append(finding(.recursiveComponentDefinition,
                        "Recursive component definition \(resolved.componentID)@\(resolved.revision)."))
                    return node
                }
                node.children = [build(resolved.skeleton,
                    path: here + "[\(surface.instanceID):\(resolved.componentID)@\(resolved.revision)]",
                    context: resolved.dataContext ?? context, definitions: definitions.union([identity]))]
            default:
                for (index, child) in children(of: element).enumerated() {
                    node.children.append(build(child.element, path: "\(here)[\(index)]",
                        context: child.providesRowData ? .row : context, definitions: definitions))
                }
            }
            return node
        }
    }

    private static func walk(_ node: Node, findings: inout [SkeletonReachabilityFinding]) {
        findings.append(contentsOf: node.findings)
        if let dead = dead(node) {
            findings.append(SkeletonReachabilityFinding(kind: dead.kind, path: node.path, elementKind: node.kind,
                                                        detail: dead.detail, lostActionKeypaths: node.allActions))
            // Structural resolution errors remain visible even under a hidden
            // parent; visibility findings themselves stay one per dead subtree.
            for child in node.children { appendStructuralFindings(child, into: &findings) }
            return
        }
        for child in node.children { walk(child, findings: &findings) }
    }

    private static func appendStructuralFindings(_ node: Node, into findings: inout [SkeletonReachabilityFinding]) {
        findings.append(contentsOf: node.findings)
        for child in node.children { appendStructuralFindings(child, into: &findings) }
    }

    private static func reachable(_ node: Node) -> Set<String> {
        guard dead(node) == nil,
              !node.findings.contains(where: { [.unresolvedComponentDefinition, .recursiveComponentDefinition,
                  .duplicateComponentInstanceID, .unsupportedElement].contains($0.kind) }) else { return [] }
        return node.children.reduce(Set(node.actions + modifierActions(node.modifiers))) { $0.union(reachable($1)) }
    }

    private struct DeadCondition {
        var kind: SkeletonReachabilityFinding.Kind
        var detail: String
    }

    private static func dead(_ node: Node) -> DeadCondition? {
        if node.modifiers?.hidden == true {
            return DeadCondition(kind: .hiddenModifier, detail: "hidden = true. Nothing below this point is drawn.")
        }
        guard let condition = node.modifiers?.visibility?.when else { return nil }
        guard case .expression(let expression) = condition else { return nil }
        if expression.isMalformed { return DeadCondition(kind: .malformedCondition, detail: "The condition did not decode.") }
        if hasNoPredicate(expression) {
            return DeadCondition(kind: .conditionHasNoPredicate, detail: "The condition states no predicate.")
        }
        if !possibleValues(condition, context: node.context).contains(true) {
            return DeadCondition(kind: .unreachableAtRootScope,
                detail: "\(describe(condition)) cannot be true with the data scopes available here. Supply the binding context or move it into a data row.")
        }
        return nil
    }

    /// Conservative truth possibilities. Unknown row values never count as dead,
    /// but unavailable scopes and constant/malformed predicates can be proved so.
    /// Uses the existing evaluator for the local predicates with no available data.
    private static func possibleValues(_ condition: SkeletonCondition,
                                       context: SkeletonReachabilityContext) -> Set<Bool> {
        guard case .expression(var expression) = condition else { return [false] }
        if expression.isMalformed { return [false] }
        let all = expression.allOf, any = expression.anyOf, not = expression.not
        expression.allOf = nil; expression.anyOf = nil; expression.not = nil
        var result: Set<Bool> = [true]
        func combine(_ lhs: Set<Bool>, _ rhs: Set<Bool>, and: Bool) -> Set<Bool> {
            Set(lhs.flatMap { a in rhs.map { b in and ? (a && b) : (a || b) } })
        }
        let hasLocal = !hasNoPredicate(expression)
        if hasLocal {
            if context.available(expression.scope ?? .root), nonempty(expression.keypath) {
                result = [true, false]
            } else { result = [expression.evaluate()] }
        }
        if let all {
            for child in all { result = combine(result, possibleValues(child, context: context), and: true) }
        }
        if let any {
            var possibilities: Set<Bool> = [false]
            for child in any { possibilities = combine(possibilities, possibleValues(child, context: context), and: false) }
            result = combine(result, possibilities, and: true)
        }
        if let not { result = combine(result, Set(possibleValues(not, context: context).map { !$0 }), and: true) }
        return (!hasLocal && all == nil && any == nil && not == nil) ? [false] : result
    }

    private static func hasNoPredicate(_ expression: SkeletonConditionExpression) -> Bool {
        !nonempty(expression.keypath) && expression.exists == nil && expression.equals == nil
            && expression.notEquals == nil && expression.inValues == nil && expression.contains == nil
            && expression.allOf == nil && expression.anyOf == nil && expression.not == nil
    }

    private static func describe(_ condition: SkeletonCondition) -> String {
        guard case .expression(let expression) = condition else { return "The condition" }
        return "`\(expression.keypath ?? "condition")` (\((expression.scope ?? .root).rawValue) scope)"
    }

    private struct Child {
        var element: SkeletonElement
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
        case .Section(let value): return plain([value.header].compactMap { $0 } + value.content + [value.footer].compactMap { $0 })
        case .Object(let value): return plain(value.elements.keys.sorted().compactMap { value.elements[$0] })
        case .Tabs(let value): return value.panels.flatMap { plain($0.content) }
        case .Grid(let value):
            var result = plain(value.elements)
            if let item = value.itemSkeleton { result.append(Child(element: item, providesRowData: nonempty(value.keypath))) }
            return result
        case .List(let value):
            guard let row = value.flowElementSkeleton else { return [] }
            return [Child(element: .VStack(row), providesRowData: true)]
        case .Reference(let value):
            guard let row = value.flowElementSkeleton else { return [] }
            return [Child(element: .VStack(row), providesRowData: true)]
        default: return []
        }
    }

    private static func nonempty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private static func valid(_ values: [String?]) -> [String] { values.compactMap { nonempty($0) ? $0 : nil } }

    private static func modifierActions(_ value: SkeletonModifiers?) -> [String] {
        valid([value?.dropActionKeypath, value?.presentation?.closeActionKeypath])
    }

    private static func ownActions(_ element: SkeletonElement) -> [String] {
        var actions = modifierActions(modifiers(of: element))
        switch element {
        case .Button(let value): actions += valid([value.keypath])
        case .TextField(let value): actions += valid([value.targetKeypath])
        case .TextArea(let value): actions += valid([value.targetKeypath, value.submitActionKeypath])
        case .Toggle(let value): actions += valid([value.keypath])
        case .Picker(let value): actions += valid([value.selectionActionKeypath])
        case .FileUpload(let value): actions += valid([value.actionKeypath])
        case .Visualization(let value): actions += valid([value.actionKeypath])
        case .List(let value): actions += valid([value.selectionActionKeypath, value.activationActionKeypath])
        case .Tabs(let value): actions += valid([value.selectionActionKeypath])
        case .NavigationBar(let value): actions += valid(value.items.map(\.keypath))
        default: break
        }
        return actions
    }

    private static func elementKind(_ element: SkeletonElement) -> String {
        switch element {
        case .List: return "List"
        case .Tree: return "Tree"
        case .ComponentSurface: return "ComponentSurface"
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
        case .Tree(let value): return value.modifiers
        case .ComponentSurface(let value): return value.modifiers
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
}
