// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase

/// Snapshot-only binding shared by rows and component mounts. A present null is
/// a value, not a missing key. No keypath rewriting, Cell lookup or deep merging.
public struct SkeletonRenderDataContext {
    public var root: ValueType?
    public var item: ValueType?

    public init(root: ValueType? = nil, item: ValueType? = nil) {
        self.root = root
        self.item = item
    }

    public static func value(_ keypath: String, in value: ValueType?) -> ValueType? {
        guard !keypath.hasPrefix("cell://") else { return nil }
        if keypath.isEmpty { return value }
        var cursor = value
        for part in keypath.split(separator: ".", omittingEmptySubsequences: false) {
            switch cursor {
            case .object(let object): cursor = object[String(part)]
            case .list(let values):
                guard let index = Int(part), values.indices.contains(index) else { return nil }
                cursor = values[index]
            default: return nil
            }
        }
        return cursor
    }

    public func resolve(_ keypath: String?) -> ValueType? {
        guard let keypath else { return nil }
        return Self.value(keypath, in: item) ?? Self.value(keypath, in: root)
    }

    public func row(_ value: ValueType?) -> Self { Self(root: root, item: value) }
    var signature: String { ((try? root?.jsonString()) ?? "nil") + ":" + ((try? item?.jsonString()) ?? "nil") }
}

public extension SkeletonList {
    /// R2: local row/root values take precedence over the existing Cell fallback.
    func getElements(in context: SkeletonRenderDataContext, allowCellFallback: Bool = true) async throws -> ValueTypeList {
        if let value = context.resolve(keypath) {
            if case .list(let rows) = value { return rows }
            return []
        }
        return allowCellFallback ? try await getElements() : []
    }
}

public struct SkeletonNativeMountMetadata: Equatable {
    public let instanceID: String
    public let componentID: String
    public let revision: String
}

/// The adapter receives the payload unchanged. It must use the active requester
/// and normal source-cell authorization/Agreement flow; mount is not authority.
public struct SkeletonNativeActionRequest {
    public let keypath: String
    public let payload: ValueType?
    public let sourceCellEndpoint: String?
    public let mount: SkeletonNativeMountMetadata?
}

public struct SkeletonNativeActionHandler {
    public let send: @MainActor (SkeletonNativeActionRequest) async throws -> ValueType
    public init(_ send: @escaping @MainActor (SkeletonNativeActionRequest) async throws -> ValueType) { self.send = send }
}

struct SkeletonNativeActionScope {
    let sourceCellEndpoint: String
    let mount: SkeletonNativeMountMetadata
    func request(keypath: String, payload: ValueType?) -> SkeletonNativeActionRequest {
        .init(keypath: keypath, payload: payload, sourceCellEndpoint: sourceCellEndpoint, mount: mount)
    }
}

enum SkeletonNativeRuntimeError: LocalizedError {
    case sourceActionAdapterMissing
    case invalidTreeIDs
    var errorDescription: String? {
        switch self {
        case .sourceActionAdapterMissing: return "ComponentSurface: the host has no source action adapter with separate mount metadata."
        case .invalidTreeIDs: return "Tree requires unique, nonempty string node IDs."
        }
    }
}

struct SkeletonNativeToggle: View {
    let toggle: SkeletonToggle
    let data: SkeletonRenderDataContext
    @EnvironmentObject private var viewModel: PortholeViewModel
    @Environment(\.skeletonNativeActionScope) private var scope
    @Environment(\.skeletonNativeActionHandler) private var handler
    @State private var value = false
    var body: some View {
        Toggle(toggle.label, isOn: Binding(get: { value }, set: { next in
            let previous = value
            value = next
            Task {
                do {
                    _ = try await skeletonNativeSend(keypath: toggle.keypath, payload: .bool(next), scope: scope, handler: handler, viewModel: viewModel)
                    viewModel.markLocalMutation()
                } catch {
                    value = previous
                    viewModel.alertMessage = error.localizedDescription; viewModel.showAlert = true
                }
            }
        }))
        .task(id: data.signature + String(viewModel.localMutationVersion)) {
            if let local = data.resolve(toggle.keypath) { value = local == .bool(true) }
            else if scope == nil { value = await nativeRead(toggle.keypath, viewModel: viewModel) == .bool(true) }
        }
    }
}

/// R4 is host-scoped and transient. Binding's R6 adapter calls begin/end, also
/// for external drags; end must run on drop, cancellation and teardown.
public final class SkeletonNativeDragContext: ObservableObject {
    @Published public private(set) var sourceID: String?
    @Published public private(set) var role: String?
    @Published public private(set) var payload: ValueType?
    @Published public private(set) var isActive = false
    public init() {}
    public func begin(sourceID: String?, role: String?, payload: ValueType?) {
        self.sourceID = sourceID; self.role = role; self.payload = payload; isActive = true
    }
    public func end() { isActive = false; sourceID = nil; role = nil; payload = nil }
    public func accepts(_ roles: [String]?) -> Bool {
        guard isActive, let role else { return false }
        return roles?.contains(role) == true
    }
}

public struct SkeletonNativeDragSource {
    public let elementID: String
    public let role: String
    public let payload: ValueType?
    public let previewRole: String?
    public let accessibilityLabel: String?
}
public struct SkeletonNativeDropTarget {
    public let elementID: String
    public let role: String?
    public let acceptedRoles: [String]
    public let payload: ValueType?
    public let actionKeypath: String
    public let intents: [String]
    public let accessibilityLabel: String?
}

/// R6 integration seam: the renderer supplies the same generic role/payload
/// for a ComponentSurface and any other element, plus an inert card preview.
/// The host adapter owns platform sessions and calls the shared drag context.
public struct SkeletonNativeTransferAdapter {
    public let decorate: (AnyView, AnyView, SkeletonNativeDragSource?, SkeletonNativeDropTarget?) -> AnyView
    public init(_ decorate: @escaping (AnyView, AnyView, SkeletonNativeDragSource?, SkeletonNativeDropTarget?) -> AnyView) {
        self.decorate = decorate
    }
}

enum SkeletonNativeTransfer {
    static func source(_ m: SkeletonModifiers, data: SkeletonRenderDataContext, id: String) -> SkeletonNativeDragSource? {
        guard let role = m.draggableRole, !role.isEmpty else { return nil }
        return .init(elementID: id, role: role, payload: data.resolve(m.dragPayloadKeypath),
                     previewRole: m.dragPreviewRole, accessibilityLabel: m.accessibilityDragLabel)
    }
    static func target(_ m: SkeletonModifiers, data: SkeletonRenderDataContext, id: String) -> SkeletonNativeDropTarget? {
        guard let action = m.dropActionKeypath, !action.isEmpty else { return nil }
        return .init(elementID: id, role: m.dropTargetRole, acceptedRoles: m.acceptedDragRoles ?? [],
                     payload: data.resolve(m.dropTargetPayloadKeypath), actionKeypath: action,
                     intents: m.dropIntents ?? [], accessibilityLabel: m.accessibilityDropLabel)
    }
}

struct SkeletonNativeTransferSurface: ViewModifier {
    let modifiers: SkeletonModifiers
    @Environment(\.skeletonNativeTransferAdapter) private var adapter
    @Environment(\.skeletonRenderData) private var data
    @Environment(\.skeletonNativeElementID) private var elementID
    func body(content: Content) -> some View {
        let source = SkeletonNativeTransfer.source(modifiers, data: data ?? .init(), id: elementID)
        let target = SkeletonNativeTransfer.target(modifiers, data: data ?? .init(), id: elementID)
        return adapter?.decorate(AnyView(content), AnyView(content.allowsHitTesting(false).accessibilityHidden(true)), source, target)
            ?? AnyView(content)
    }
}

private struct DataContextKey: EnvironmentKey { static let defaultValue: SkeletonRenderDataContext? = nil }
private struct LayoutContextKey: EnvironmentKey { static let defaultValue = try! SkeletonLayoutContext() }
private struct NativeActionKey: EnvironmentKey { static let defaultValue: SkeletonNativeActionHandler? = nil }
private struct NativeScopeKey: EnvironmentKey { static let defaultValue: SkeletonNativeActionScope? = nil }
private struct NativeDragKey: EnvironmentKey { static let defaultValue: SkeletonNativeDragContext? = nil }
private struct NativeTransferKey: EnvironmentKey { static let defaultValue: SkeletonNativeTransferAdapter? = nil }
private struct NativeElementIDKey: EnvironmentKey { static let defaultValue = "root" }
private struct ComponentAncestorsKey: EnvironmentKey { static let defaultValue: [String] = [] }
private struct ComponentStateKey: EnvironmentKey { static let defaultValue: SkeletonComponentLocalState? = nil }

/// Surviving field bindings keep drafts even when a new revision moves them
/// under another container. Separate objects for separate instanceIDs.
final class SkeletonComponentLocalState: ObservableObject {
    var drafts: [String: String] = [:]
    var focusedField: String?
    var scrollOffsets: [String: CGPoint] = [:]
}

struct SkeletonNativeChild: Identifiable {
    let id: String
    let element: SkeletonElement
    let index: Int
    static func children(_ elements: [SkeletonElement]) -> [Self] {
        var occurrences: [String: Int] = [:]
        return elements.enumerated().map { index, element in
            let key = element.nativeIdentity(fallback: String(index))
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return Self(id: key + (occurrence == 0 ? "" : ":duplicate:\(occurrence)"), element: element, index: index)
        }
    }
}

public extension EnvironmentValues {
    var skeletonNativeTransferAdapter: SkeletonNativeTransferAdapter? {
        get { self[NativeTransferKey.self] } set { self[NativeTransferKey.self] = newValue }
    }
    var skeletonRenderData: SkeletonRenderDataContext? {
        get { self[DataContextKey.self] } set { self[DataContextKey.self] = newValue }
    }
    var skeletonLayoutContext: SkeletonLayoutContext {
        get { self[LayoutContextKey.self] } set { self[LayoutContextKey.self] = newValue }
    }
    var skeletonNativeActionHandler: SkeletonNativeActionHandler? {
        get { self[NativeActionKey.self] } set { self[NativeActionKey.self] = newValue }
    }
    var skeletonNativeDragContext: SkeletonNativeDragContext? {
        get { self[NativeDragKey.self] } set { self[NativeDragKey.self] = newValue }
    }
}
extension EnvironmentValues {
    var skeletonComponentLocalState: SkeletonComponentLocalState? {
        get { self[ComponentStateKey.self] } set { self[ComponentStateKey.self] = newValue }
    }
    var skeletonNativeActionScope: SkeletonNativeActionScope? {
        get { self[NativeScopeKey.self] } set { self[NativeScopeKey.self] = newValue }
    }
    var skeletonNativeElementID: String {
        get { self[NativeElementIDKey.self] } set { self[NativeElementIDKey.self] = newValue }
    }
    var skeletonComponentAncestors: [String] {
        get { self[ComponentAncestorsKey.self] } set { self[ComponentAncestorsKey.self] = newValue }
    }
}

enum SkeletonNativeLayout {
    static func effective(_ base: SkeletonModifiers?, layout: SkeletonLayoutContext,
                          data: SkeletonRenderDataContext) -> (SkeletonModifiers, SkeletonLayoutVariant?) {
        var result = base ?? SkeletonModifiers()
        let available = (try? layout.narrowed(availableWidth: result.width, availableHeight: result.height)) ?? layout
        let variant = result.layoutVariant(in: available, root: data.root, item: data.item, context: data.item ?? data.root)
        if let v = variant {
            result.paddingInsets = v.paddingInsets ?? result.paddingInsets
            result.minHeight = v.minHeight ?? result.minHeight
            result.maxHeight = v.maxHeight ?? result.maxHeight
            result.flexGrow = v.flexGrow ?? result.flexGrow
            result.fontSize = v.fontSize ?? result.fontSize
            result.borderColor = v.borderColor ?? result.borderColor
            result.foregroundColor = v.foregroundColor ?? result.foregroundColor
            result.width = v.width ?? result.width
        }
        if case .string(let value)? = data.resolve(result.backgroundKeypath) { result.background = value }
        if variant?.foregroundColor == nil, case .string(let value)? = data.resolve(result.foregroundColorKeypath) { result.foregroundColor = value }
        if case .string(let value)? = data.resolve(result.hAlignmentKeypath) { result.hAlignment = value }
        return (result, variant)
    }

    static func children(_ layout: SkeletonLayoutContext, modifiers: SkeletonModifiers) -> SkeletonLayoutContext {
        let own = (try? layout.narrowed(availableWidth: modifiers.width, availableHeight: modifiers.height)) ?? layout
        let bounded = (try? own.narrowed(availableHeight: modifiers.maxHeight)) ?? own
        let insets = (modifiers.paddingInsets ?? .init()).resolved(padding: modifiers.padding)
        return try! SkeletonLayoutContext(
            availableWidth: bounded.availableWidth.map { max(0, $0 - (insets.leading ?? 0) - (insets.trailing ?? 0)) },
            availableHeight: bounded.availableHeight.map { max(0, $0 - (insets.top ?? 0) - (insets.bottom ?? 0)) },
            capabilities: layout.capabilities)
    }

    /// Same declared allocation as web; no geometry measurements. Also used to
    /// size native Grid tracks so the inherited budget equals the actual track.
    static func gridWidths(_ columns: [SkeletonGridColumn], width: Double?, spacing: Double, count: Int) -> [Double?] {
        guard !columns.isEmpty else { return [] }
        if let adaptive = columns.first(where: { $0.type == .adaptive }) {
            guard let width else { return [] }
            let minimum = adaptive.min ?? 120
            let tracks = max(1, min(max(count, 1), Int((width + spacing) / (minimum + spacing))))
            return Array(repeating: min(adaptive.max ?? .infinity, max(0, (width - spacing * Double(tracks - 1)) / Double(tracks))), count: tracks)
        }
        guard let width else { return columns.map { $0.type == .fixed ? $0.value : nil } }
        var sizes = columns.map { $0.type == .fixed ? ($0.value ?? 0) : ($0.min ?? 0) }
        var remaining = max(0, width - spacing * Double(columns.count - 1) - sizes.reduce(0, +))
        var flexible = columns.indices.filter { columns[$0].type == .flexible }
        while remaining > 0.01 && !flexible.isEmpty {
            let share = remaining / Double(flexible.count)
            let previous = remaining
            for index in flexible {
                let addition = max(0, min(share, (columns[index].max ?? .infinity) - sizes[index]))
                sizes[index] += addition; remaining -= addition
            }
            flexible = flexible.filter { sizes[$0] < (columns[$0].max ?? .infinity) }
            if remaining == previous { break }
        }
        return sizes.map(Optional.some)
    }

    static func verticalAlignment(_ value: String?) -> VerticalAlignment {
        switch value {
        case "top": return .top
        case "bottom": return .bottom
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: return .center
        }
    }
    static func horizontalAlignment(_ value: String?) -> HorizontalAlignment {
        switch value { case "center": return .center; case "trailing": return .trailing; default: return .leading }
    }
}

extension SkeletonElement {
    var nativeModifiers: SkeletonModifiers? {
        switch self {
        case .Text(let value): return value.modifiers
        case .AttachmentField(let value): return value.modifiers
        case .FileUpload(let value): return value.modifiers
        case .TextField(let value): return value.modifiers
        case .TextArea(let value): return value.modifiers
        case .HStack(let value): return value.modifiers
        case .VStack(let value): return value.modifiers
        case .Image(let value): return value.modifiers
        case .Tree(let value): return value.modifiers
        case .ComponentSurface(let value): return value.modifiers
        case .List(let value): return value.modifiers
        case .Object(let value): return value.modifiers
        case .Spacer(let value): return value.modifiers
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
    func withNativeModifiers(_ modifiers: SkeletonModifiers) -> SkeletonElement {
        switch self {
        case .Text(var value): value.modifiers = modifiers; return .Text(value)
        case .AttachmentField(var value): value.modifiers = modifiers; return .AttachmentField(value)
        case .FileUpload(var value): value.modifiers = modifiers; return .FileUpload(value)
        case .TextField(var value): value.modifiers = modifiers; return .TextField(value)
        case .TextArea(var value): value.modifiers = modifiers; return .TextArea(value)
        case .HStack(var value): value.modifiers = modifiers; return .HStack(value)
        case .VStack(var value): value.modifiers = modifiers; return .VStack(value)
        case .Image(var value): value.modifiers = modifiers; return .Image(value)
        case .Tree(var value): value.modifiers = modifiers; return .Tree(value)
        case .ComponentSurface(var value): value.modifiers = modifiers; return .ComponentSurface(value)
        case .List(var value): value.modifiers = modifiers; return .List(value)
        case .Object(var value): value.modifiers = modifiers; return .Object(value)
        case .Spacer(var value): value.modifiers = modifiers; return .Spacer(value)
        case .Reference(var value): value.modifiers = modifiers; return .Reference(value)
        case .Button(var value): value.modifiers = modifiers; return .Button(value)
        case .Divider(var value): value.modifiers = modifiers; return .Divider(value)
        case .ScrollView(var value): value.modifiers = modifiers; return .ScrollView(value)
        case .Section(var value): value.modifiers = modifiers; return .Section(value)
        case .Tabs(var value): value.modifiers = modifiers; return .Tabs(value)
        case .NavigationBar(var value): value.modifiers = modifiers; return .NavigationBar(value)
        case .ZStack(var value): value.modifiers = modifiers; return .ZStack(value)
        case .Grid(var value): value.modifiers = modifiers; return .Grid(value)
        case .Toggle(var value): value.modifiers = modifiers; return .Toggle(value)
        case .Picker(var value): value.modifiers = modifiers; return .Picker(value)
        case .Visualization(var value): value.modifiers = modifiers; return .Visualization(value)
        case .Unsupported(var value): value.modifiers = modifiers; return .Unsupported(value)
        @unknown default: return self
        }
    }
    func nativeIdentity(fallback: String) -> String {
        switch self {
        case .ComponentSurface(let surface): return "component:" + (surface.instanceID ?? "{" + (surface.instanceIDKeypath ?? "") + "}")
        case .TextField(let field): return "field:" + (field.targetKeypath ?? field.sourceKeypath ?? fallback)
        case .TextArea(let field): return "area:" + (field.targetKeypath ?? field.sourceKeypath ?? fallback)
        case .Tree(let tree): return "tree:" + tree.keypath
        case .Button(let button): return "button:" + button.keypath
        case .Text(let text): return "text:" + (text.keypath ?? fallback)
        default: return fallback
        }
    }
}
