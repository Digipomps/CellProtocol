// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

struct SkeletonTreeNode: Identifiable {
    let id: String
    let parentID: String?
    let level: Int
    let leadingInset: Double
    let hasChildren: Bool
    let expanded: Bool
    let item: ValueType
}

enum SkeletonTreeKey: String { case up, down, home, end, left, right, enter, space }

/// Only focus is renderer-owned. Nodes, order, selection and expansion are
/// confirmed snapshots from the cell; commands never mutate those values.
struct SkeletonTreeState {
    private(set) var nodes: [SkeletonTreeNode] = []
    private(set) var selectedID: String?
    var focusedID: String?

    mutating func update(_ values: ValueTypeList, selectedID: String?, spec: SkeletonTree) throws {
        var ids = Set<String>()
        let next = try values.map { value -> SkeletonTreeNode in
            func read(_ key: String) -> ValueType? { SkeletonRenderDataContext.value(key, in: value) }
            guard case .string(let id)? = read(spec.idKeypath), !id.isEmpty, ids.insert(id).inserted else {
                throw SkeletonNativeRuntimeError.invalidTreeIDs
            }
            let parent: String? = { if case .string(let id)? = read(spec.parentIDKeypath) { return id }; return nil }()
            let level = nativeNumber(read(spec.levelKeypath)).map(Int.init) ?? 1
            return SkeletonTreeNode(id: id, parentID: parent, level: level,
                leadingInset: nativeNumber(read(spec.leadingInsetKeypath)) ?? 0,
                hasChildren: read(spec.hasChildrenKeypath) == .bool(true),
                expanded: read(spec.expandedKeypath) == .bool(true), item: value)
        }
        var focus = focusedID
        var visited = Set<String>()
        while let id = focus, !ids.contains(id), visited.insert(id).inserted {
            focus = nodes.first { $0.id == id }?.parentID
        }
        if focus == nil || !ids.contains(focus!) {
            focus = selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? next.first?.id
        }
        nodes = next; self.selectedID = selectedID; focusedID = focus
    }

    mutating func command(_ key: SkeletonTreeKey, spec: SkeletonTree) -> (String, ValueType)? {
        guard let index = nodes.firstIndex(where: { $0.id == focusedID }) else { return nil }
        let node = nodes[index]
        func expand(_ value: Bool) -> (String, ValueType) {
            (spec.expansionActionKeypath, .object(["nodeID": .string(node.id), "expanded": .bool(value)]))
        }
        switch key {
        case .up: focusedID = nodes[max(0, index - 1)].id
        case .down: focusedID = nodes[min(nodes.count - 1, index + 1)].id
        case .home: focusedID = nodes.first?.id
        case .end: focusedID = nodes.last?.id
        case .right:
            if node.hasChildren {
                if !node.expanded { return expand(true) }
                if let child = nodes.first(where: { $0.parentID == node.id }) { focusedID = child.id }
            }
        case .left:
            if node.hasChildren && node.expanded { return expand(false) }
            if let parent = node.parentID, nodes.contains(where: { $0.id == parent }) { focusedID = parent }
        case .enter, .space:
            return (spec.selectionActionKeypath, .object(["nodeID": .string(node.id)]))
        }
        return nil
    }
}

func nativeNumber(_ value: ValueType?) -> Double? {
    switch value {
    case .integer(let n): return Double(n)
    case .number(let n): return Double(n)
    case .float(let n): return Double(n)
    default: return nil
    }
}

struct CellTreeView: View {
    let tree: SkeletonTree
    let data: SkeletonRenderDataContext
    @EnvironmentObject private var viewModel: PortholeViewModel
    @Environment(\.skeletonNativeActionHandler) private var actionHandler
    @Environment(\.skeletonNativeActionScope) private var actionScope
    @Environment(\.skeletonLayoutContext) private var layout
    @State private var state = SkeletonTreeState()
    @State private var failure: String?
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibleRow: String?

    var body: some View {
        ScrollViewReader { scroll in
            // One scroll surface, regardless of semantic level or parentage.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: tree.modifiers?.itemSpacing ?? 0) {
                    if let failure { Text(failure).foregroundStyle(.red) }
                    ForEach(state.nodes) { node in row(node).id(node.id) }
                }.background(SkeletonScrollState())
            }
            .modifier(SkeletonTreeFocus(focused: $keyboardFocused))
            .background(SkeletonTreeKeyboardBridge(active: keyboardFocused) { handle($0) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tree.modifiers?.accessibilityLabel ?? "Tree")
            .onChange(of: state.focusedID) { id in
                if let id { scroll.scrollTo(id, anchor: nil) }
            }
            .task(id: tree.keypath + data.signature + String(viewModel.localMutationVersion)) { await refresh() }
        }
    }

    private func row(_ node: SkeletonTreeNode) -> some View {
        let rowData = data.row(node.item)
        let rowStyle = SkeletonNativeLayout.effective(tree.rowModifiers, layout: layout, data: rowData).0
        let disclosureStyle = SkeletonNativeLayout.effective(tree.disclosureModifiers, layout: layout, data: rowData).0
        return HStack(spacing: 0) {
            Button {
                state.focusedID = node.id
                keyboardFocused = true
                send(tree.expansionActionKeypath, .object(["nodeID": .string(node.id), "expanded": .bool(!node.expanded)]))
            } label: {
                Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!node.hasChildren)
            .opacity(node.hasChildren ? 1 : 0)
            .accessibilityHidden(!node.hasChildren)
            .accessibilityLabel(disclosureStyle.accessibilityLabel ?? "\(node.expanded ? "Collapse" : "Expand") \(node.id)")
            .accessibilityValue(node.expanded ? "Expanded" : "Collapsed")
            .applySkeletonModifiers(disclosureStyle)

            SkeletonView(element: .VStack(tree.rowSkeleton), showsKeyboardToolbar: false, renderData: rowData)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { select(node.id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(state.selectedID == node.id ? .isSelected : [])
                .accessibilityValue("Level \(node.level)")
                .accessibilityAction { select(node.id) }
                .accessibilityFocused($accessibleRow, equals: node.id)
        }
        .padding(.leading, node.leadingInset)
        .applySkeletonModifiers(rowStyle, focusVisible: keyboardFocused && state.focusedID == node.id)
        .overlay {
            if keyboardFocused && state.focusedID == node.id {
                RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .environment(\.skeletonRenderData, rowData)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skeleton.tree.node.\(node.id)")
    }

    private func select(_ id: String) {
        state.focusedID = id; keyboardFocused = true
        send(tree.selectionActionKeypath, .object(["nodeID": .string(id)]))
    }
    private func handle(_ key: SkeletonTreeKey) {
        if let (path, payload) = state.command(key, spec: tree) { send(path, payload) }
    }
    private func send(_ keypath: String, _ payload: ValueType) {
        Task {
            do {
                _ = try await skeletonNativeSend(keypath: keypath, payload: payload, scope: actionScope,
                    handler: actionHandler, viewModel: viewModel)
                viewModel.markLocalMutation()
            } catch { failure = error.localizedDescription }
        }
    }
    private func refresh() async {
        var value = data.resolve(tree.keypath)
        var selected = data.resolve(tree.selectedIDStateKeypath)
        if actionScope == nil {
            if value == nil { value = await nativeRead(tree.keypath, viewModel: viewModel) }
            if selected == nil { selected = await nativeRead(tree.selectedIDStateKeypath, viewModel: viewModel) }
        }
        let values: ValueTypeList = { if case .list(let rows)? = value { return rows }; return [] }()
        let id: String? = { if case .string(let id)? = selected { return id }; return nil }()
        let wasAccessible = accessibleRow
        do {
            try state.update(values, selectedID: id, spec: tree)
            failure = nil
            if let wasAccessible, !state.nodes.contains(where: { $0.id == wasAccessible }) {
                accessibleRow = state.focusedID
            }
        } catch { failure = error.localizedDescription }
    }
}

@MainActor
func nativeRead(_ keypath: String, viewModel: PortholeViewModel) async -> ValueType? {
    guard let resolver = CellBase.defaultCellResolver, let requester = await viewModel.executionRequesterIdentity(),
          let url = URL(string: keypath.hasPrefix("cell://") ? keypath : "cell:///Porthole/\(keypath)") else { return nil }
    return try? await resolver.get(from: url, requester: requester)
}

@MainActor
func skeletonNativeSend(keypath: String, payload: ValueType?, scope: SkeletonNativeActionScope?,
                        handler: SkeletonNativeActionHandler?, viewModel: PortholeViewModel) async throws -> ValueType {
    let request = scope?.request(keypath: keypath, payload: payload)
        ?? SkeletonNativeActionRequest(keypath: keypath, payload: payload, sourceCellEndpoint: nil, mount: nil)
    if let handler { return try await handler.send(request) }
    guard scope == nil else { throw SkeletonNativeRuntimeError.sourceActionAdapterMissing }
    let button = SkeletonButton(keypath: keypath, label: "", payload: payload)
    guard let response = await button.execute(requester: await viewModel.executionRequesterIdentity()) else {
        throw CellBaseError.noIdentity
    }
    return response
}

private struct SkeletonTreeFocus: ViewModifier {
    let focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        #if os(macOS)
        content.focusable().focused(focused)
        #else
        if #available(iOS 17, *) { content.focusable().focused(focused) } else { content }
        #endif
    }
}

#if os(macOS)
import AppKit
/// The local monitor consumes only this focused tree's unmodified navigation
/// keys in its own window. Tab, text editing and other windows remain untouched.
private struct SkeletonTreeKeyboardBridge: NSViewRepresentable {
    let active: Bool
    let handle: (SkeletonTreeKey) -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.active = active; view.handle = handle }
    final class KeyView: NSView {
        var active = false
        var handle: ((SkeletonTreeKey) -> Void)?
        var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, event.window === self.window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let key: SkeletonTreeKey?
                switch event.keyCode {
                case 126: key = .up; case 125: key = .down; case 123: key = .left; case 124: key = .right
                case 115: key = .home; case 119: key = .end; case 36, 76: key = .enter; case 49: key = .space
                default: key = nil
                }
                guard let key else { return event }
                self.handle?(key); return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
#else
import UIKit
private struct SkeletonTreeKeyboardBridge: UIViewRepresentable {
    let active: Bool
    let handle: (SkeletonTreeKey) -> Void
    func makeUIView(context: Context) -> KeyView { KeyView() }
    func updateUIView(_ view: KeyView, context: Context) {
        view.handle = handle
        if active && !view.isFirstResponder { view.becomeFirstResponder() }
        if !active && view.isFirstResponder { view.resignFirstResponder() }
    }
    final class KeyView: UIView {
        var handle: ((SkeletonTreeKey) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
             UIKeyCommand.inputRightArrow, UIKeyCommand.inputHome, UIKeyCommand.inputEnd, "\r", " "].map {
                UIKeyCommand(input: $0, modifierFlags: [], action: #selector(key(_:)))
            }
        }
        @objc func key(_ command: UIKeyCommand) {
            let values: [String: SkeletonTreeKey] = [UIKeyCommand.inputUpArrow: .up, UIKeyCommand.inputDownArrow: .down,
                UIKeyCommand.inputLeftArrow: .left, UIKeyCommand.inputRightArrow: .right,
                UIKeyCommand.inputHome: .home, UIKeyCommand.inputEnd: .end, "\r": .enter, " ": .space]
            if let input = command.input, let key = values[input] { handle?(key) }
        }
    }
}
#endif
