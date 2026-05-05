// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

private func splitCellURLForPicker(_ cellURL: URL) -> (URL, String?) {
    var url = cellURL
    var keypath: String?
    let components = cellURL.pathComponents
    if components.count > 1 {
        keypath = components.last
        url = cellURL.deletingLastPathComponent()
    }
    return (url, keypath)
}

private enum CellPickerSelectionActionError: Error {
    case missingTargetKeypath(String)
    case unresolvedTarget(String)
}

struct CellPickerView: View {
    private struct PickerOption {
        let displayLabel: String
        let value: ValueType
    }

    let userInfoValue: ValueType?
    var skeletonPicker: SkeletonPicker
    @State private var valueTypeList: ValueTypeList = ValueTypeList()
    @State private var selectedIndex: Int?
    @EnvironmentObject var viewModel: PortholeViewModel

    init(skeletonPicker: SkeletonPicker, userInfoValue: ValueType? = nil) {
        self.skeletonPicker = skeletonPicker
        self.userInfoValue = userInfoValue
    }

    private var options: [PickerOption] {
        let source = skeletonPicker.keypath?.isEmpty == false ? valueTypeList : skeletonPicker.elements
        return source.map { value in
            PickerOption(
                displayLabel: optionLabel(for: value),
                value: value
            )
        }
    }

    private var resolvedPlaceholder: String {
        if let placeholder = skeletonPicker.placeholder, placeholder.isEmpty == false {
            return placeholder
        }
        if let label = skeletonPicker.label, label.isEmpty == false {
            return "Velg \(label.lowercased())"
        }
        return "Velg"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = skeletonPicker.label, label.isEmpty == false {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(selection: pickerSelectionBinding) {
                if skeletonPicker.allowsEmptySelection ?? true {
                    Text(resolvedPlaceholder).tag(Optional<Int>.none)
                }

                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Text(option.displayLabel).tag(Optional(index))
                }
            } label: {
                Text(skeletonPicker.label ?? resolvedPlaceholder)
            }
            .pickerStyle(.menu)
        }
        .task(id: refreshTaskID()) {
            if skeletonPicker.keypath?.isEmpty == false,
               let elements = try? await skeletonPicker.getElements() {
                valueTypeList = elements
            }
            await hydrateInitialSelection()
        }
    }

    private var pickerSelectionBinding: Binding<Int?> {
        Binding<Int?>(
            get: { selectedIndex },
            set: { newValue in
                let previousSelection = selectedIndex
                selectedIndex = newValue
                Task {
                    await handleSelectionChange(from: previousSelection, to: newValue)
                }
            }
        )
    }

    private func refreshTaskID() -> String {
        let keypath = skeletonPicker.keypath ?? "__static__"
        let selection = skeletonPicker.selectionStateKeypath ?? "__no_selection_state__"
        let revision = skeletonPicker.keypath?.isEmpty == false ? String(viewModel.localMutationVersion) : "static"
        return "\(keypath)::\(selection)::\(revision)"
    }

    private func optionLabel(for value: ValueType) -> String {
        if let optionLabelKeypath = skeletonPicker.optionLabelKeypath,
           let nestedValue = value[optionLabelKeypath] {
            return stringValue(for: nestedValue)
        }
        return stringValue(for: value)
    }

    private func stringValue(for value: ValueType) -> String {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .object(let object):
            return stringValue(for: object["title"]) ??
                stringValue(for: object["name"]) ??
                stringValue(for: object["label"]) ??
                stringValue(for: object["id"]) ??
                "Object"
        case .flowElement(let flowElement):
            return flowElement.title
        case .null:
            return resolvedPlaceholder
        default:
            return String(describing: value)
        }
    }

    private func stringValue(for value: ValueType?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .float(let float):
            return String(float)
        default:
            return nil
        }
    }

    private func handleSelectionChange(from previousSelection: Int?, to newSelection: Int?) async {
        guard skeletonPicker.selectionStateKeypath?.isEmpty == false || skeletonPicker.selectionActionKeypath?.isEmpty == false else {
            return
        }

        let trigger: SkeletonListSelectionTrigger = newSelection == nil ? .deselect : .select

        do {
            let payload = try skeletonPicker.selectionPayload(
                trigger: trigger,
                rows: options.map(\.value),
                selectedIndex: newSelection
            )

            if let selectionStateKeypath = skeletonPicker.selectionStateKeypath,
               selectionStateKeypath.isEmpty == false {
                try await submit(payload: payload, to: selectionStateKeypath)
            }

            if let selectionActionKeypath = skeletonPicker.selectionActionKeypath,
               selectionActionKeypath.isEmpty == false {
                try await submit(payload: payload, to: selectionActionKeypath)
            }
        } catch {
            selectedIndex = previousSelection
            await presentSelectionError(
                title: "Picker selection failed",
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
            throw CellPickerSelectionActionError.unresolvedTarget(targetURL.absoluteString)
        }

        _ = try await target.set(keypath: keypath, value: payload, requester: requester)
    }

    private func resolveTarget(for actionKeypath: String) throws -> (URL, String) {
        if actionKeypath.hasPrefix("cell://"), let url = URL(string: actionKeypath) {
            let (cellURL, keypath) = splitCellURLForPicker(url)
            guard let keypath, keypath.isEmpty == false else {
                throw CellPickerSelectionActionError.missingTargetKeypath(actionKeypath)
            }
            return (cellURL, keypath)
        }

        guard actionKeypath.isEmpty == false else {
            throw CellPickerSelectionActionError.missingTargetKeypath(actionKeypath)
        }
        return (URL(string: "cell:///Porthole")!, actionKeypath)
    }

    private func hydrateInitialSelection() async {
        guard let selectionStateKeypath = skeletonPicker.selectionStateKeypath,
              selectionStateKeypath.isEmpty == false else {
            return
        }

        guard let _ = CellBase.defaultCellResolver,
              let vault = CellBase.defaultIdentityVault,
              let requester = await vault.identity(for: "private", makeNewIfNotFound: true) else {
            return
        }

        do {
            let (targetURL, keypath) = try resolveTarget(for: selectionStateKeypath)
            guard let target = try await CellResolver.sharedInstance.emitCellAtEndpoint(
                endpointUrl: targetURL,
                endpoint: targetURL.absoluteString,
                requester: requester
            ) as? Meddle else {
                return
            }
            let state = try await target.get(keypath: keypath, requester: requester)
            if let index = selectionIndex(from: state) {
                await MainActor.run {
                    if options.indices.contains(index) {
                        selectedIndex = index
                    }
                }
            }
        } catch {
            // Best effort. Picker selection can still work without initial state hydration.
        }
    }

    private func selectionIndex(from payload: ValueType) -> Int? {
        guard case .object(let object) = payload else {
            return nil
        }

        if case let .integer(selectedIndex)? = object["selectedIndex"] {
            return selectedIndex
        }

        if let selectedValue = object["selected"] {
            if let selectionValueKeypath = skeletonPicker.selectionValueKeypath {
                return options.firstIndex { option in
                    option.value[selectionValueKeypath] == selectedValue
                }
            }
            return options.firstIndex { option in
                option.value == selectedValue
            }
        }

        return nil
    }

    private func presentSelectionError(title: String, message: String) async {
        await MainActor.run {
            viewModel.alertTitle = title
            viewModel.alertMessage = message
            viewModel.alertPrimaryActionLabel = "OK"
            viewModel.showAlert = true
        }
    }
}
