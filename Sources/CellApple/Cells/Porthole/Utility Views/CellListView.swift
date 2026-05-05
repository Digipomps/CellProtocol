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

    private var rows: [RowData] {
        var resolvedRows = [RowData]()

        for valueElement in valueTypeList {
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

    private var selectionMode: SkeletonListSelectionMode {
        skeletonList.selectionMode ?? .none
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.indices), id: \.self) { index in
                    rowView(for: rows[index], index: index)
                }
            }
        }
        .scrollIndicators(.visible)
        .task(id: refreshTaskID()) {
            if let elementsList = try? await skeletonList.getElements() {
                valueTypeList = elementsList
            }
        }
    }

    private func refreshTaskID() -> String {
        let topic = skeletonList.topic ?? "__no_topic__"
        let keypath = skeletonList.keypath ?? "__no_keypath__"
        let revision = skeletonList.topic == nil ? String(viewModel.localMutationVersion) : "shared"
        return "\(topic)::\(keypath)::\(revision)"
    }

    @ViewBuilder
    private func rowView(for row: RowData, index: Int) -> some View {
        let isSelected = selectedIndices.contains(index)

        HStack(alignment: .center, spacing: 8) {
            if selectionMode == .multiple {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

            rowContent(for: row)

            Spacer(minLength: 8)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .onTapGesture {
            Task {
                await handleSelectionTap(at: index)
            }
        }
    }

    @ViewBuilder
    private func rowContent(for row: RowData) -> some View {
        if let skeletonVStack = skeletonList.flowElementSkeleton {
            SkeletonView(
                element: .VStack(skeletonVStack),
                userInfoValue: row.selectionValue
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
