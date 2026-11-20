// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation

// Structural editing of a skeleton tree: the one place where the rules for
// "which element may go where" live. Porthole on the web and the native app
// both edit through a cell that uses these functions, so the rules are not
// written twice (PDD redigerer-paneler 2026-11-20, F5.1).
//
// Paths address elements by child index from the root, as Porthole already
// does ("root", "root.0.2"). The children of a container are:
//   HStack/VStack/ScrollView/ZStack/Grid: `elements`
//   Section: `content` (header and footer are not part of the tree)
//   Tabs: the panels' content, flattened in panel order
//   List: its row template (`flowElementSkeleton`) as the single child 0.
//         The template itself is a fixed slot: it can be edited inside, but it
//         cannot be moved, removed or used as a sibling target.
// All functions are pure; nothing here renders or grants any right.

public struct SkeletonEditPath: Hashable, Codable, Sendable, CustomStringConvertible {
    public private(set) var indices: [Int]

    public static let root = SkeletonEditPath(indices: [])

    public init(indices: [Int] = []) {
        self.indices = indices
    }

    /// Parses "root", "", "root.0.2" or "0.2". Returns nil for anything else.
    public init?(_ rawValue: String?) {
        let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw == "root" {
            self = .root
            return
        }
        let trimmed = raw.hasPrefix("root.") ? String(raw.dropFirst(5)) : raw
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let index = Int(part), index >= 0 else { return nil }
            parsed.append(index)
        }
        self.indices = parsed
    }

    public var isRoot: Bool { indices.isEmpty }

    public var parent: SkeletonEditPath? {
        guard indices.isEmpty == false else { return nil }
        return SkeletonEditPath(indices: Array(indices.dropLast()))
    }

    public var lastIndex: Int? { indices.last }

    public func appending(_ index: Int) -> SkeletonEditPath {
        SkeletonEditPath(indices: indices + [index])
    }

    /// True when `self` is `other` or one of its ancestors.
    public func contains(_ other: SkeletonEditPath) -> Bool {
        other.indices.count >= indices.count && Array(other.indices.prefix(indices.count)) == indices
    }

    public var description: String {
        indices.isEmpty ? "root" : "root." + indices.map(String.init).joined(separator: ".")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = SkeletonEditPath(raw) else {
            throw Swift.DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid skeleton path '\(raw)'")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A position in a container: insert as child number `index` of `parent`,
/// counted in the tree as it is before the edit.
public struct SkeletonInsertionPoint: Hashable, Codable, Sendable {
    public var parent: SkeletonEditPath
    public var index: Int

    public init(parent: SkeletonEditPath, index: Int) {
        self.parent = parent
        self.index = index
    }

    public var id: String { "\(parent.description)#\(index)" }
}

/// A legal place to move an element to, with where it ends up afterwards.
public struct SkeletonMoveTarget: Hashable, Codable, Sendable {
    public var point: SkeletonInsertionPoint
    /// Path of the moved element in the tree after the move.
    public var resultingPath: SkeletonEditPath
    /// Kind of the container that receives the element (`vstack`, `tabs`, …).
    public var containerKind: String

    public init(point: SkeletonInsertionPoint, resultingPath: SkeletonEditPath, containerKind: String) {
        self.point = point
        self.resultingPath = resultingPath
        self.containerKind = containerKind
    }

    public var id: String { point.id }
}

public enum SkeletonEditingError: Error, Equatable, LocalizedError {
    case invalidPath(String)
    case notAContainer(String)
    case fixedSlot(String)
    case cannotMoveRoot
    case targetInsideSource(String)
    case indexOutOfRange(String)
    case invalidPurposeRef(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Finner ikke elementet på \(path)."
        case .notAContainer(let path): return "Elementet på \(path) kan ikke inneholde andre elementer."
        case .fixedSlot(let path): return "\(path) er radmalen til en liste og kan ikke flyttes eller fjernes."
        case .cannotMoveRoot: return "Rotelementet kan ikke flyttes."
        case .targetInsideSource(let path): return "Et element kan ikke flyttes inn i seg selv (\(path))."
        case .indexOutOfRange(let point): return "Plassen \(point) finnes ikke."
        case .invalidPurposeRef(let ref): return "«\(ref)» er ikke en purpose://-referanse."
        }
    }
}

public enum SkeletonWrapperKind: String, Codable, Sendable {
    case vStack = "VStack"
    case hStack = "HStack"
}

public enum SkeletonEditing {

    // MARK: Queries

    public static func kindIdentifier(for element: SkeletonElement) -> String {
        switch element {
        case .List: return "list"
        case .Tree: return "tree"
        case .ComponentSurface: return "componentsurface"
        case .Object: return "object"
        case .Spacer: return "spacer"
        case .Image: return "image"
        case .Text: return "text"
        case .AttachmentField: return "attachmentfield"
        case .FileUpload: return "fileupload"
        case .TextField: return "textfield"
        case .TextArea: return "textarea"
        case .HStack: return "hstack"
        case .VStack: return "vstack"
        case .Reference: return "reference"
        case .Button: return "button"
        case .Divider: return "divider"
        case .ScrollView: return "scrollview"
        case .Section: return "section"
        case .Tabs: return "tabs"
        case .NavigationBar: return "navigationbar"
        case .ZStack: return "zstack"
        case .Grid: return "grid"
        case .Toggle: return "toggle"
        case .Picker: return "picker"
        case .Visualization: return "visualization"
        case .Audio: return "audio"
        case .AudioQueue: return "audioqueue"
        case .Unsupported: return "unsupported"
        }
    }

    /// True when elements can be inserted into `element`.
    public static func acceptsChildren(_ element: SkeletonElement) -> Bool {
        switch element {
        case .HStack, .VStack, .ScrollView, .Section, .ZStack, .Grid:
            return true
        case .Tabs(let tabs):
            return tabs.panels.isEmpty == false
        default:
            return false
        }
    }

    /// Children in path order; empty for elements without children.
    public static func children(of element: SkeletonElement) -> [SkeletonElement] {
        switch element {
        case .HStack(let stack): return stack.elements
        case .VStack(let stack): return stack.elements
        case .ScrollView(let scrollView): return scrollView.elements
        case .Section(let section): return section.content
        case .ZStack(let zStack): return zStack.elements
        case .Grid(let grid): return grid.elements
        case .Tabs(let tabs): return tabs.panels.flatMap(\.content)
        case .List(let list):
            if let template = list.flowElementSkeleton { return [.VStack(template)] }
            return []
        default:
            return []
        }
    }

    public static func element(in root: SkeletonElement, at path: SkeletonEditPath) -> SkeletonElement? {
        var current = root
        for index in path.indices {
            let children = children(of: current)
            guard index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    /// The list row template slot: child 0 of a List. It is edited in place only.
    public static func isFixedSlot(_ path: SkeletonEditPath, in root: SkeletonElement) -> Bool {
        guard let parentPath = path.parent, let parent = element(in: root, at: parentPath) else { return false }
        if case .List = parent { return true }
        return false
    }

    /// Every element in depth-first order with its path.
    public static func allPaths(in root: SkeletonElement) -> [SkeletonEditPath] {
        var result: [SkeletonEditPath] = []
        func walk(_ element: SkeletonElement, _ path: SkeletonEditPath) {
            result.append(path)
            for (index, child) in children(of: element).enumerated() {
                walk(child, path.appending(index))
            }
        }
        walk(root, .root)
        return result
    }

    // MARK: Primitive mutations

    /// Replaces the element at `path` by the result of `transform`.
    public static func updating(
        at path: SkeletonEditPath,
        in root: SkeletonElement,
        _ transform: (SkeletonElement) throws -> SkeletonElement
    ) throws -> SkeletonElement {
        try update(root, remaining: ArraySlice(path.indices), fullPath: path, transform)
    }

    public static func removing(at path: SkeletonEditPath, in root: SkeletonElement) throws -> (root: SkeletonElement, removed: SkeletonElement) {
        guard let parentPath = path.parent, let index = path.lastIndex else { throw SkeletonEditingError.cannotMoveRoot }
        guard let removed = element(in: root, at: path) else { throw SkeletonEditingError.invalidPath(path.description) }
        if isFixedSlot(path, in: root) { throw SkeletonEditingError.fixedSlot(path.description) }
        let updated = try updating(at: parentPath, in: root) { parent in
            var children = children(of: parent)
            children.remove(at: index)
            return try withChildren(children, in: parent, path: parentPath, change: .removed(index))
        }
        return (updated, removed)
    }

    public static func inserting(
        _ fragment: SkeletonElement,
        at point: SkeletonInsertionPoint,
        in root: SkeletonElement
    ) throws -> SkeletonElement {
        guard let parent = element(in: root, at: point.parent) else { throw SkeletonEditingError.invalidPath(point.parent.description) }
        guard acceptsChildren(parent) else { throw SkeletonEditingError.notAContainer(point.parent.description) }
        let count = children(of: parent).count
        guard point.index >= 0, point.index <= count else { throw SkeletonEditingError.indexOutOfRange(point.id) }
        return try updating(at: point.parent, in: root) { parent in
            var children = children(of: parent)
            children.insert(fragment, at: point.index)
            return try withChildren(children, in: parent, path: point.parent, change: .inserted(point.index))
        }
    }

    // MARK: Editing operations

    /// Moves the element at `source` to `point` (counted in the tree before the move).
    public static func moving(
        from source: SkeletonEditPath,
        to point: SkeletonInsertionPoint,
        in root: SkeletonElement
    ) throws -> (root: SkeletonElement, path: SkeletonEditPath) {
        guard source.isRoot == false else { throw SkeletonEditingError.cannotMoveRoot }
        guard element(in: root, at: source) != nil else { throw SkeletonEditingError.invalidPath(source.description) }
        if isFixedSlot(source, in: root) { throw SkeletonEditingError.fixedSlot(source.description) }
        if source.contains(point.parent) { throw SkeletonEditingError.targetInsideSource(point.parent.description) }
        guard let parent = element(in: root, at: point.parent) else { throw SkeletonEditingError.invalidPath(point.parent.description) }
        guard acceptsChildren(parent) else { throw SkeletonEditingError.notAContainer(point.parent.description) }
        guard point.index >= 0, point.index <= children(of: parent).count else { throw SkeletonEditingError.indexOutOfRange(point.id) }

        let adjusted = adjustedPoint(point, afterRemoving: source)
        let (withoutSource, moved) = try removing(at: source, in: root)
        let result = try inserting(moved, at: adjusted, in: withoutSource)
        return (result, adjusted.parent.appending(adjusted.index))
    }

    /// Every place the element at `source` can be moved to, excluding places
    /// where it already is. Never inside itself, never the list template slot.
    public static func legalMoveTargets(for source: SkeletonEditPath, in root: SkeletonElement) -> [SkeletonMoveTarget] {
        guard source.isRoot == false,
              element(in: root, at: source) != nil,
              isFixedSlot(source, in: root) == false,
              let sourceParent = source.parent,
              let sourceIndex = source.lastIndex
        else { return [] }

        var targets: [SkeletonMoveTarget] = []
        for path in allPaths(in: root) {
            guard source.contains(path) == false,
                  let container = element(in: root, at: path),
                  acceptsChildren(container)
            else { continue }
            let count = children(of: container).count
            for index in 0...count {
                if path == sourceParent && (index == sourceIndex || index == sourceIndex + 1) { continue }
                let point = SkeletonInsertionPoint(parent: path, index: index)
                let adjusted = adjustedPoint(point, afterRemoving: source)
                targets.append(
                    SkeletonMoveTarget(
                        point: point,
                        resultingPath: adjusted.parent.appending(adjusted.index),
                        containerKind: kindIdentifier(for: container)
                    )
                )
            }
        }
        return targets
    }

    /// The tree as it would be if the element were dropped at `point`.
    /// Renderers use this for the drop preview, so the preview is the result.
    public static func previewMove(
        from source: SkeletonEditPath,
        to point: SkeletonInsertionPoint,
        in root: SkeletonElement
    ) throws -> (root: SkeletonElement, path: SkeletonEditPath) {
        try moving(from: source, to: point, in: root)
    }

    /// Inserts a copy right after the element. The copy gets fresh runtime ids.
    public static func duplicating(at path: SkeletonEditPath, in root: SkeletonElement) throws -> (root: SkeletonElement, path: SkeletonEditPath) {
        guard let parentPath = path.parent, let index = path.lastIndex else { throw SkeletonEditingError.cannotMoveRoot }
        guard let original = element(in: root, at: path) else { throw SkeletonEditingError.invalidPath(path.description) }
        if isFixedSlot(path, in: root) { throw SkeletonEditingError.fixedSlot(path.description) }
        let copy = try JSONDecoder().decode(SkeletonElement.self, from: JSONEncoder().encode(original))
        let point = SkeletonInsertionPoint(parent: parentPath, index: index + 1)
        return (try inserting(copy, at: point, in: root), parentPath.appending(index + 1))
    }

    /// Puts the element inside a new VStack or HStack at the same place.
    public static func wrapping(
        at path: SkeletonEditPath,
        in kind: SkeletonWrapperKind,
        root: SkeletonElement
    ) throws -> (root: SkeletonElement, wrapperPath: SkeletonEditPath) {
        guard element(in: root, at: path) != nil else { throw SkeletonEditingError.invalidPath(path.description) }
        if isFixedSlot(path, in: root) { throw SkeletonEditingError.fixedSlot(path.description) }
        let updated = try updating(at: path, in: root) { element in
            switch kind {
            case .vStack: return .VStack(SkeletonVStack(elements: [element]))
            case .hStack: return .HStack(SkeletonHStack(elements: [element]))
            }
        }
        return (updated, path)
    }

    // MARK: Purposes

    /// The element's own `purposeRef` (modifiers), if any.
    public static func purposeRef(of element: SkeletonElement) -> String? {
        guard let (_, body) = try? jsonBody(of: element),
              let modifiers = body["modifiers"] as? [String: Any],
              let ref = modifiers["purposeRef"] as? String,
              ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        return ref
    }

    /// Sets or clears (`nil`) the element's `purposeRef`. A purpose is metadata
    /// for tests and audits; setting it never grants or widens a right.
    public static func settingPurposeRef(
        _ purposeRef: String?,
        at path: SkeletonEditPath,
        in root: SkeletonElement
    ) throws -> SkeletonElement {
        if let purposeRef, purposeRef.hasPrefix("purpose://") == false {
            throw SkeletonEditingError.invalidPurposeRef(purposeRef)
        }
        return try updating(at: path, in: root) { element in
            let (key, body) = try jsonBody(of: element)
            var updated = body
            var modifiers = updated["modifiers"] as? [String: Any] ?? [:]
            if let purposeRef { modifiers["purposeRef"] = purposeRef } else { modifiers.removeValue(forKey: "purposeRef") }
            updated["modifiers"] = modifiers.isEmpty ? nil : modifiers
            let data = try JSONSerialization.data(withJSONObject: [key: updated])
            return try JSONDecoder().decode(SkeletonElement.self, from: data)
        }
    }

    /// Elements grouped by their `purposeRef`, in tree order. Elements without
    /// one are listed under `nil`, so the group is never hidden.
    public static func purposeGroups(in root: SkeletonElement) -> [(purposeRef: String?, paths: [SkeletonEditPath])] {
        var order: [String?] = []
        var groups: [String?: [SkeletonEditPath]] = [:]
        for path in allPaths(in: root) {
            guard isFixedSlot(path, in: root) == false, let element = element(in: root, at: path) else { continue }
            let ref = purposeRef(of: element)
            if groups[ref] == nil { order.append(ref) }
            groups[ref, default: []].append(path)
        }
        let withRef = order.compactMap { $0 }.map { (purposeRef: Optional($0), paths: groups[$0] ?? []) }
        let without = groups[nil].map { [(purposeRef: String?.none, paths: $0)] } ?? []
        return withRef + without
    }

    private static func jsonBody(of element: SkeletonElement) throws -> (String, [String: Any]) {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(element))
        guard let wrapper = object as? [String: Any], wrapper.count == 1,
              let (key, value) = wrapper.first, let body = value as? [String: Any]
        else { throw SkeletonEditingError.invalidPath("element") }
        return (key, body)
    }

    // MARK: Internals

    /// Translates a point counted before removing `source` into the tree after removal.
    static func adjustedPoint(_ point: SkeletonInsertionPoint, afterRemoving source: SkeletonEditPath) -> SkeletonInsertionPoint {
        guard let sourceParent = source.parent, let sourceIndex = source.lastIndex else { return point }
        var parentIndices = point.parent.indices
        var index = point.index
        let depth = sourceParent.indices.count
        if point.parent == sourceParent {
            if index > sourceIndex { index -= 1 }
        } else if sourceParent.contains(point.parent), parentIndices.count > depth, parentIndices[depth] > sourceIndex {
            parentIndices[depth] -= 1
        }
        return SkeletonInsertionPoint(parent: SkeletonEditPath(indices: parentIndices), index: index)
    }

    private static func update(
        _ element: SkeletonElement,
        remaining: ArraySlice<Int>,
        fullPath: SkeletonEditPath,
        _ transform: (SkeletonElement) throws -> SkeletonElement
    ) throws -> SkeletonElement {
        guard let next = remaining.first else { return try transform(element) }
        var children = children(of: element)
        guard next >= 0, next < children.count else { throw SkeletonEditingError.invalidPath(fullPath.description) }
        children[next] = try update(children[next], remaining: remaining.dropFirst(), fullPath: fullPath, transform)
        return try withChildren(children, in: element, path: fullPath, change: .replaced)
    }

    private enum ChildChange {
        case replaced
        case inserted(Int)
        case removed(Int)
    }

    /// Rebuilds a container with a new child list. For Tabs the flat list is
    /// split back into panels: an insertion at index i lands in the panel that
    /// held the element at i (so at a panel boundary it starts the next panel),
    /// and an insertion at the end lands in the last panel.
    private static func withChildren(
        _ children: [SkeletonElement],
        in element: SkeletonElement,
        path: SkeletonEditPath,
        change: ChildChange
    ) throws -> SkeletonElement {
        switch element {
        case .HStack(var stack): stack.elements = children; return .HStack(stack)
        case .VStack(var stack): stack.elements = children; return .VStack(stack)
        case .ScrollView(var scrollView): scrollView.elements = children; return .ScrollView(scrollView)
        case .Section(var section): section.content = children; return .Section(section)
        case .ZStack(var zStack): zStack.elements = children; return .ZStack(zStack)
        case .Grid(var grid): grid.elements = children; return .Grid(grid)
        case .List(var list):
            guard case .replaced = change, children.count == 1, case .VStack(let template) = children[0] else {
                throw SkeletonEditingError.fixedSlot(path.appending(0).description)
            }
            list.flowElementSkeleton = template
            return .List(list)
        case .Tabs(var tabs):
            guard tabs.panels.isEmpty == false else { throw SkeletonEditingError.notAContainer(path.description) }
            var counts = tabs.panels.map(\.content.count)
            switch change {
            case .replaced:
                break
            case .inserted(let index):
                counts[panelIndex(holding: index, counts: counts) ?? counts.count - 1] += 1
            case .removed(let index):
                guard let panel = panelIndex(holding: index, counts: counts) else {
                    throw SkeletonEditingError.invalidPath(path.appending(index).description)
                }
                counts[panel] -= 1
            }
            guard counts.reduce(0, +) == children.count else { throw SkeletonEditingError.invalidPath(path.description) }
            var offset = 0
            for panelIndex in tabs.panels.indices {
                let count = counts[panelIndex]
                tabs.panels[panelIndex].content = Array(children[offset..<(offset + count)])
                offset += count
            }
            return .Tabs(tabs)
        default:
            throw SkeletonEditingError.notAContainer(path.description)
        }
    }

    private static func panelIndex(holding flatIndex: Int, counts: [Int]) -> Int? {
        var running = 0
        for (panel, count) in counts.enumerated() {
            if flatIndex < running + count { return panel }
            running += count
        }
        return nil
    }
}
