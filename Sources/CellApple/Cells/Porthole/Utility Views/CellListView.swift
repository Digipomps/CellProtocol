// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

private func splitCellURLLocal(_ cellURL: URL) -> (URL, String?) {
    var url = cellURL
    var keypath: String?
    let components = cellURL.pathComponents
    if components.count > 1 {
        keypath = components.last
        url = cellURL.deletingLastPathComponent()
    }
    return (url, keypath)
}

private enum CellListSelectionActionError: Error {
    case missingTargetKeypath(String)
    case unresolvedTarget(String)
}

struct CellListView: View {
    private struct RowData {
        let displayValue: ValueType
        let selectionValue: ValueType
    }

    let userInfoValue: ValueType?
    var skeletonList: SkeletonList
    @State var valueTypeList: ValueTypeList = ValueTypeList()
    @State private var selectedIndices = Set<Int>()
    @State private var treeExpansion = SkeletonListTreeExpansion()
    @Environment(\.skeletonRenderData) private var renderData
    @Environment(\.skeletonNativeActionScope) private var actionScope
    @Environment(\.skeletonNativeActionHandler) private var actionHandler
    @EnvironmentObject var viewModel: PortholeViewModel

    init(skeletonList: SkeletonList, userInfoValue: ValueType? = nil) {
        self.skeletonList = skeletonList
        self.userInfoValue = userInfoValue
    }

    private func resolvedUserInfoValue(from value: ValueType) -> ValueType {
        switch value {
        case .flowElement(let flowElement):
            return flowElementUserInfoValue(flowElement)
        default:
            return value
        }
    }

    private func flowElementUserInfoValue(_ flowElement: FlowElement) -> ValueType {
        let contentValue = (try? flowElement.content.valueType()) ?? .null
        var flowObject: Object = [
            "id": .string(flowElement.id),
            "title": .string(flowElement.title),
            "topic": .string(flowElement.topic),
            "content": contentValue
        ]

        if case let .object(contentObject) = contentValue {
            for (key, value) in contentObject where flowObject[key] == nil {
                flowObject[key] = value
            }
        }

        if let origin = flowElement.origin {
            flowObject["origin"] = .string(origin)
        }

        if let properties = flowElement.properties {
            var propertiesObject: Object = [
                "type": .string(properties.type.rawValue)
            ]
            if let mimetype = properties.mimetype {
                propertiesObject["mimetype"] = .string(mimetype)
            }
            if let contentType = properties.contentType {
                propertiesObject["contentType"] = .string(contentType.rawValue)
            }
            flowObject["properties"] = .object(propertiesObject)
        }

        return .object(flowObject)
    }

    private var shouldIncludeFlowRows: Bool {
        if let topic = skeletonList.topic, !topic.isEmpty {
            return true
        }
        if let types = skeletonList.filterTypes, !types.isEmpty {
            return true
        }
        return false
    }

    private var filteredFlowElements: [FlowElement] {
        viewModel.flowElements.filter { flowElement in
            let topicMatch: Bool = {
                guard let topic = skeletonList.topic, !topic.isEmpty else { return true }
                return flowElement.topic == topic
            }()
            let typeMatch: Bool = {
                if let types = skeletonList.filterTypes, !types.isEmpty {
                    return types.contains(flowElement.properties?.type.rawValue ?? "TypeNotSet")
                }
                return true
            }()
            return topicMatch && typeMatch
        }
    }

    private var sourceRows: [RowData] {
        var resolvedRows = [RowData]()

        for valueElement in rowElements ?? valueTypeList {
            resolvedRows.append(
                RowData(
                    displayValue: valueElement,
                    selectionValue: resolvedUserInfoValue(from: valueElement)
                )
            )
        }

        for valueElement in skeletonList.elements {
            resolvedRows.append(
                RowData(
                    displayValue: valueElement,
                    selectionValue: resolvedUserInfoValue(from: valueElement)
                )
            )
        }

        guard shouldIncludeFlowRows else {
            return resolvedRows
        }

        var indexByIdentifier = [String: Int]()
        for (index, row) in resolvedRows.enumerated() {
            if let identifier = rowIdentifier(for: row) {
                indexByIdentifier[identifier] = index
            }
        }

        for flowElement in filteredFlowElements {
            let displayValue = (try? flowElement.content.valueType()) ?? .null
            let row = RowData(
                displayValue: displayValue,
                selectionValue: flowElementUserInfoValue(flowElement)
            )

            if let identifier = rowIdentifier(for: row) {
                if let existingIndex = indexByIdentifier[identifier] {
                    resolvedRows[existingIndex] = row
                } else {
                    indexByIdentifier[identifier] = resolvedRows.count
                    resolvedRows.append(row)
                }
            } else {
                resolvedRows.append(row)
            }
        }

        return resolvedRows
    }

    private var dataContext: SkeletonRenderDataContext {
        renderData ?? SkeletonRenderDataContext(root: userInfoValue)
    }

    /// A relative nested list belongs to its row, including an absent/invalid
    /// value (empty list). It must not fetch another cell's `tags` in that case.
    private var rowElements: ValueTypeList? {
        // SkeletonView already distinguishes root data from a row context.
        // A directly hosted CellListView can pass its row as userInfoValue.
        let row = renderData == nil ? userInfoValue : renderData?.item
        return skeletonListRowElements(skeletonList, userInfoValue: row)
    }

    private var isTree: Bool { skeletonList.childrenKeypath?.isEmpty == false }

    private var seededTreeExpansion: SkeletonListTreeExpansion {
        treeExpansion.seeded(keypath: skeletonList.expandedStateKeypath,
                             value: dataContext.resolve(skeletonList.expandedStateKeypath))
    }

    private var treeRows: [SkeletonListTreeRow] {
        guard isTree else { return [] }
        return SkeletonListTree.flatten(sourceRows.map(\.selectionValue),
            childrenKeypath: skeletonList.childrenKeypath,
            selectionValueKeypath: skeletonList.selectionValueKeypath,
            expanded: seededTreeExpansion.expanded)
    }

    private var rows: [RowData] {
        guard isTree else { return sourceRows }
        let source = sourceRows
        return treeRows.map { entry in
            if entry.depth == 0 { return source[entry.path[0]] }
            return RowData(displayValue: entry.value, selectionValue: resolvedUserInfoValue(from: entry.value))
        }
    }

    private struct IdentifiedRow: Identifiable {
        let id: String
        let index: Int
        let row: RowData
        let tree: SkeletonListTreeRow?
    }
    private var identifiedRows: [IdentifiedRow] {
        let metadata = treeRows
        var occurrences: [String: Int] = [:]
        return rows.enumerated().map { index, row in
            let tree = isTree ? metadata[index] : nil
            let key = tree?.identity ?? rowIdentifier(for: row) ?? "index:\(index)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return IdentifiedRow(id: key + ":\(occurrence)", index: index, row: row, tree: tree)
        }
    }

    private var selectionMode: SkeletonListSelectionMode {
        skeletonList.selectionMode ?? .none
    }

    private var wrapsRows: Bool {
        skeletonList.modifiers?.wrap == true
    }

    private var rowInsets: EdgeInsets {
        if let insets = skeletonList.modifiers?.rowInsets { return insets.resolved().nativeInsets }
        // Wrapped items own their padding. Ordinary list chrome would otherwise
        // become invisible space around each chip in FlowLayout's measurement.
        return wrapsRows ? EdgeInsets() : EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    }

    var body: some View {
        Group {
            if rowElements != nil {
                // Nested lists size to their content inside the enclosing row.
                // A second vertical ScrollView has no intrinsic content height.
                listContent(inline: true)
            } else {
                ScrollView(.vertical) {
                    listContent(inline: false)
                }
                .scrollIndicators(.visible)
            }
        }
        .task(id: refreshTaskID()) {
            if isTree { treeExpansion = seededTreeExpansion }
            guard rowElements == nil else { return }
            if let elementsList = try? await skeletonList.getElements(in: dataContext, allowCellFallback: actionScope == nil),
               !Task.isCancelled {
                valueTypeList = elementsList
            }
        }
    }

    @ViewBuilder
    private func listContent(inline: Bool) -> some View {
        if wrapsRows {
            FlowLayout(spacing: skeletonList.modifiers?.itemSpacing ?? 8,
                       lineSpacing: skeletonList.modifiers?.itemSpacing ?? 8) {
                listRows
            }.background(SkeletonScrollState())
        } else if inline {
            VStack(alignment: .leading, spacing: skeletonList.modifiers?.itemSpacing ?? 8) {
                listRows
            }
        } else {
            LazyVStack(alignment: .leading, spacing: skeletonList.modifiers?.itemSpacing ?? 8) {
                listRows
            }.background(SkeletonScrollState())
        }
    }

    private var listRows: some View {
        ForEach(identifiedRows) { identified in
            rowView(for: identified.row, index: identified.index, tree: identified.tree)
        }
    }

    private func refreshTaskID() -> String {
        let topic = skeletonList.topic ?? "__no_topic__"
        let keypath = skeletonList.keypath ?? "__no_keypath__"
        let revision = skeletonList.topic == nil ? String(viewModel.localMutationVersion) : "shared"
        return "\(topic)::\(keypath)::\(revision)::\(dataContext.signature)::\(skeletonList.expandedStateKeypath ?? "")"
    }

    private func toggleTreeRow(_ row: SkeletonListTreeRow) {
        let before = treeRows
        let selected = Set(selectedIndices.compactMap { index in
            before.indices.contains(index) ? before[index].identity : nil
        })
        var next = seededTreeExpansion
        next.toggle(row, visibleRows: before)
        treeExpansion = next
        let after = SkeletonListTree.flatten(sourceRows.map(\.selectionValue),
            childrenKeypath: skeletonList.childrenKeypath,
            selectionValueKeypath: skeletonList.selectionValueKeypath,
            expanded: next.expanded)
        selectedIndices = Set(after.enumerated().compactMap { selected.contains($0.element.identity) ? $0.offset : nil })
        // Deliberately no selection callback, mutation version bump or Cell action.
    }

    @ViewBuilder
    private func rowView(for row: RowData, index: Int, tree: SkeletonListTreeRow?) -> some View {
        let isSelected = selectedIndices.contains(index)

        HStack(alignment: .center, spacing: 8) {
            if selectionMode == .multiple {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

            if let tree {
                if tree.hasChildren {
                    Button {
                        toggleTreeRow(tree)
                    } label: {
                        Text(tree.expanded ? "▾" : "▸")
                            .frame(width: 20, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tree.expanded ? "Slå sammen" : "Utvid")
                    .accessibilityValue(tree.expanded ? "true" : "false")
                    .accessibilityIdentifier("skeleton-list-toggle:" + tree.identity)
                } else {
                    Color.clear.frame(width: 20, height: 1).accessibilityHidden(true)
                }
            }

            rowMain(for: row, index: index, isSelected: isSelected, tree: tree)

            if !wrapsRows {
                Spacer(minLength: 8)
            }

            if selectionMode == .single, isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }

            if skeletonList.activationActionKeypath?.isEmpty == false {
                Button {
                    Task {
                        await handleActivation(at: index)
                    }
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .frame(maxWidth: wrapsRows ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: wrapsRows, vertical: false)
        .padding(rowInsets)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected && skeletonList.modifiers?.rowDecoration != SkeletonRowDecoration.none ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .padding(.leading, CGFloat(tree?.depth ?? 0) * 16)
        .skeletonListApplyIf(wrapsRows) { view in
            view.accessibilityElement(children: .contain)
                .accessibilityIdentifier("skeleton-list-wrap-item:\(index)")
        }
        .onTapGesture {
            // For trees the selection gesture lives on rowMain, so a disclosure
            // button cannot bubble into a selection/activation action.
            guard tree == nil else { return }
            Task { await handleSelectionTap(at: index) }
        }
    }

    @ViewBuilder
    private func rowMain(for row: RowData, index: Int, isSelected: Bool, tree: SkeletonListTreeRow?) -> some View {
        if let tree {
            rowContent(for: row)
                .frame(maxWidth: wrapsRows ? nil : .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { Task { await handleSelectionTap(at: index) } }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("skeleton-list-row:" + tree.identity)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        } else {
            rowContent(for: row)
        }
    }

    @ViewBuilder
    private func rowContent(for row: RowData) -> some View {
        if let skeletonVStack = skeletonList.flowElementSkeleton {
            SkeletonView(
                element: .VStack(skeletonVStack),
                userInfoValue: row.selectionValue,
                renderData: dataContext.row(row.selectionValue)
            )
                .environmentObject(viewModel)
        } else {
            VTVF.view(for: row.displayValue)
        }
    }

    private func handleSelectionTap(at index: Int) async {
        guard let trigger = applySelectionChange(at: index) else {
            return
        }
        await submitSelectionChange(trigger: trigger)
    }

    private func handleActivation(at index: Int) async {
        let previousSelection = selectedIndices
        if selectionMode != .none {
            selectedIndices = activationSelection(for: index)
        }

        guard let activationActionKeypath = skeletonList.activationActionKeypath,
              activationActionKeypath.isEmpty == false else {
            return
        }

        do {
            let payload = try skeletonList.selectionPayload(
                trigger: .activate,
                rows: rows.map(\.selectionValue),
                selectedIndices: Array(selectedIndices)
            )
            try await submit(payload: payload, to: activationActionKeypath)
        } catch {
            selectedIndices = previousSelection
            await presentSelectionError(
                title: "List activation failed",
                message: String(describing: error)
            )
        }
    }

    private func applySelectionChange(at index: Int) -> SkeletonListSelectionTrigger? {
        switch selectionMode {
        case .none:
            return nil
        case .single:
            if selectedIndices.contains(index) {
                let allowsEmptySelection = skeletonList.allowsEmptySelection ?? true
                if allowsEmptySelection {
                    selectedIndices.removeAll()
                    return .deselect
                }
                return nil
            }
            selectedIndices = [index]
            return .select
        case .multiple:
            if selectedIndices.contains(index) {
                let allowsEmptySelection = skeletonList.allowsEmptySelection ?? true
                if allowsEmptySelection == false, selectedIndices.count == 1 {
                    return nil
                }
                selectedIndices.remove(index)
                return .deselect
            }
            selectedIndices.insert(index)
            return .select
        }
    }

    private func activationSelection(for index: Int) -> Set<Int> {
        switch selectionMode {
        case .multiple:
            var updatedSelection = selectedIndices
            updatedSelection.insert(index)
            return updatedSelection
        case .single, .none:
            return [index]
        }
    }

    private func submitSelectionChange(trigger: SkeletonListSelectionTrigger) async {
        guard skeletonList.selectionStateKeypath?.isEmpty == false || skeletonList.selectionActionKeypath?.isEmpty == false else {
            return
        }

        do {
            let payload = try skeletonList.selectionPayload(
                trigger: trigger,
                rows: rows.map(\.selectionValue),
                selectedIndices: Array(selectedIndices)
            )

            if let selectionStateKeypath = skeletonList.selectionStateKeypath,
               selectionStateKeypath.isEmpty == false {
                try await submit(payload: payload, to: selectionStateKeypath)
            }

            if let selectionActionKeypath = skeletonList.selectionActionKeypath,
               selectionActionKeypath.isEmpty == false {
                try await submit(payload: payload, to: selectionActionKeypath)
            }
        } catch {
            await presentSelectionError(
                title: "List selection failed",
                message: String(describing: error)
            )
        }
    }

    private func submit(payload: ValueType, to actionKeypath: String) async throws {
        if actionScope != nil || actionHandler != nil {
            _ = try await skeletonNativeSend(keypath: actionKeypath, payload: payload, scope: actionScope, handler: actionHandler, viewModel: viewModel)
            return
        }
        guard let _ = CellBase.defaultCellResolver,
              let vault = CellBase.defaultIdentityVault,
              let requester = await vault.identity(for: "private", makeNewIfNotFound: true) else {
            throw CellBaseError.noIdentity
        }

        let (targetURL, keypath) = try resolveTarget(for: actionKeypath)
        guard let target = try await CellResolver.sharedInstance.emitCellAtEndpoint(
            endpointUrl: targetURL,
            endpoint: targetURL.absoluteString,
            requester: requester
        ) as? Meddle else {
            throw CellListSelectionActionError.unresolvedTarget(targetURL.absoluteString)
        }

        _ = try await target.set(keypath: keypath, value: payload, requester: requester)
    }

    private func resolveTarget(for actionKeypath: String) throws -> (URL, String) {
        if actionKeypath.hasPrefix("cell://"), let url = URL(string: actionKeypath) {
            let (cellURL, keypath) = splitCellURLLocal(url)
            guard let keypath, keypath.isEmpty == false else {
                throw CellListSelectionActionError.missingTargetKeypath(actionKeypath)
            }
            return (cellURL, keypath)
        }

        guard actionKeypath.isEmpty == false else {
            throw CellListSelectionActionError.missingTargetKeypath(actionKeypath)
        }
        return (URL(string: "cell:///Porthole")!, actionKeypath)
    }

    private func presentSelectionError(title: String, message: String) async {
        await MainActor.run {
            viewModel.alertTitle = title
            viewModel.alertMessage = message
            viewModel.alertPrimaryActionLabel = "OK"
            viewModel.showAlert = true
        }
    }

    private func rowIdentifier(for row: RowData) -> String? {
        identifier(from: row.selectionValue) ?? identifier(from: row.displayValue)
    }

    private func identifier(from value: ValueType) -> String? {
        switch value {
        case .object(let object):
            return stringValue(object["id"]) ??
                stringValue(object["uuid"]) ??
                stringValue(object["messageId"]) ??
                stringValue(object["participantId"]) ??
                stringValue(object["requestId"])
        case .flowElement(let flowElement):
            return flowElement.id
        default:
            return nil
        }
    }

    private func stringValue(_ value: ValueType?) -> String? {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        default:
            return nil
        }
    }
}

/// Nil means use the normal list source. A non-nil result (even empty) is an
/// authoritative row-local value and never causes a Cell lookup.
func skeletonListRowElements(_ list: SkeletonList, userInfoValue: ValueType?) -> ValueTypeList? {
    guard let userInfoValue, let keypath = list.keypath, !keypath.hasPrefix("cell://") else { return nil }
    if case .list(let values)? = SkeletonRenderDataContext.value(keypath, in: userInfoValue) { return values }
    return []
}


// `applyIf` in SkeletonView.swift is file-private, so this file keeps its own.
private extension View {
    @ViewBuilder
    func skeletonListApplyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
