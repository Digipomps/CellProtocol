// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if os(macOS)
import AppKit
#endif

private func fontFromStyle(_ style: String) -> Font {
    switch style {
    case "largeTitle": return .largeTitle
    case "title": return .title
    case "title2": return .title2
    case "title3": return .title3
    case "headline": return .headline
    case "subheadline": return .subheadline
    case "body": return .body
    case "callout": return .callout
    case "footnote": return .footnote
    case "caption": return .caption
    case "caption2": return .caption2
    default: return .body
    }
}

private func weightFrom(_ s: String?) -> Font.Weight {
    switch s ?? "" {
    case "ultralight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .regular
    }
}

private func textAlignmentFrom(_ s: String) -> TextAlignment {
    switch s {
    case "leading": return .leading
    case "trailing": return .trailing
    default: return .center
    }
}

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

private func skeletonStringValue(_ value: ValueType?) -> String? {
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
    case .bool(let bool):
        return bool ? "true" : "false"
    case .object(let object):
        return skeletonStringValue(object["title"]) ??
            skeletonStringValue(object["name"]) ??
            skeletonStringValue(object["label"]) ??
            skeletonStringValue(object["id"])
    case .null:
        return nil
    default:
        return String(describing: value)
    }
}

private func sanitizeStyleToken(_ token: String) -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return ""
    }
    return String(
        trimmed.lowercased().map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
    )
}

private func applyStyleMetadata(to view: AnyView, modifiers: SkeletonModifiers?) -> AnyView {
    guard let modifiers else {
        return view
    }
    let role = sanitizeStyleToken(modifiers.styleRole ?? "")
    let classes = (modifiers.styleClasses ?? []).map(sanitizeStyleToken).filter { !$0.isEmpty }
    guard !role.isEmpty || !classes.isEmpty else {
        return view
    }
    let rolePart = role.isEmpty ? "none" : role
    let classesPart = classes.isEmpty ? "none" : classes.joined(separator: ".")
    return AnyView(
        view.accessibilityIdentifier("style-role-\(rolePart)|style-classes-\(classesPart)")
    )
}

private func resolvedImage(_ image: SkeletonImage) -> Image {
    if image.type == "system", let name = image.name {
        return Image(systemName: name)
    }
    if let name = image.name {
        return Image(name)
    }
    return Image(systemName: "photo")
}

private func renderConfiguredImage(_ baseImage: Image, image: SkeletonImage) -> AnyView {
    AnyView(
        baseImage
            .applyIf(image.resizable) { $0.resizable() }
            .applyIf(image.scaledToFit) { $0.scaledToFit() }
            .padding(CGFloat(image.padding ?? 0))
            .frame(maxWidth: .infinity, alignment: .center)
            .applySkeletonModifiers(image.modifiers)
    )
}

private func renderSkeletonImage(_ image: SkeletonImage) -> AnyView {
    if let url = image.url {
        return AnyView(
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(CGFloat(image.padding ?? 0))
                        .applySkeletonModifiers(image.modifiers)
                case .success(let loadedImage):
                    loadedImage
                        .applyIf(image.resizable) { $0.resizable() }
                        .applyIf(image.scaledToFit) { $0.scaledToFit() }
                        .padding(CGFloat(image.padding ?? 0))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .applySkeletonModifiers(image.modifiers)
                case .failure:
                    renderConfiguredImage(resolvedImage(image), image: image)
                @unknown default:
                    renderConfiguredImage(resolvedImage(image), image: image)
                }
            }
        )
    }

    return renderConfiguredImage(resolvedImage(image), image: image)
}

private func renderStyledButtonLabel(_ label: String, modifiers: SkeletonModifiers?) -> AnyView {
    var view: AnyView = AnyView(Text(label))

    if let fontSize = modifiers?.fontSize {
        view = AnyView(
            view.font(.system(size: CGFloat(fontSize), weight: weightFrom(modifiers?.fontWeight)))
        )
    } else if let fontStyle = modifiers?.fontStyle, fontStyle.isEmpty == false {
        view = AnyView(view.font(fontFromStyle(fontStyle)))
        if modifiers?.fontWeight != nil {
            view = AnyView(view.fontWeight(weightFrom(modifiers?.fontWeight)))
        }
    } else if modifiers?.fontWeight != nil {
        view = AnyView(view.fontWeight(weightFrom(modifiers?.fontWeight)))
    }

    if let foregroundColor = modifiers?.foregroundColor,
       let color = Color(hex: foregroundColor) {
        view = AnyView(view.foregroundColor(color))
    }

    return view
}

private func toggleBinding(for keypath: String, requester: Identity?) -> Binding<Bool> {
    // Resolve via CellBase.defaultCellResolver and IdentityVault
    class Box { var value: Bool = false }
    let box = Box()
    let binding = Binding<Bool>(
        get: {
            // Best-effort synchronous cache; real value fetched asynchronously below
            return box.value
        },
        set: { newValue in
            Task {
                guard let resolver = CellBase.defaultCellResolver,
                      let requester else { return }
                // Determine URL and keypath
                var url: URL
                var kp: String?
                if keypath.hasPrefix("cell://") {
                    url = URL(string: keypath)!
                } else {
                    url = URL(string: "cell:///Porthole")!
                    kp = keypath
                }
                if kp == nil {
                    // split last path as keypath if provided inline
                    let (cellURL, child) = splitCellURLLocal(url)
                    url = cellURL
                    kp = child
                }
                guard let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(endpointUrl: url, endpoint: url.absoluteString, requester: requester) as? Meddle,
                      let child = kp else { return }
                _ = try? await target.set(keypath: child, value: .bool(newValue), requester: requester)
                box.value = newValue
            }
        }
    )
    // Initial fetch
    Task {
        guard let resolver = CellBase.defaultCellResolver,
              let requester else { return }
        var url: URL
        var kp: String?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)!
        } else {
            url = URL(string: "cell:///Porthole")!
            kp = keypath
        }
        if kp == nil {
            let (cellURL, child) = splitCellURLLocal(url)
            url = cellURL
            kp = child
        }
        if let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(endpointUrl: url, endpoint: url.absoluteString, requester: requester) as? Meddle,
           let child = kp,
           let v = try? await target.get(keypath: child, requester: requester),
           case let .bool(b) = v {
            box.value = b
        }
    }
    return binding
}

private func textBinding(for keypath: String, requester: Identity?) -> Binding<String> {
    class Box { var value: String = "" }
    let box = Box()
    let binding = Binding<String>(
        get: { box.value },
        set: { newValue in
            Task {
                guard let _ = CellBase.defaultCellResolver,
                      let requester else { return }
                var url: URL
                var kp: String?
                if keypath.hasPrefix("cell://") {
                    url = URL(string: keypath)!
                } else {
                    url = URL(string: "cell:///Porthole")!
                    kp = keypath
                }
                if kp == nil {
                    let (cellURL, child) = splitCellURLLocal(url)
                    url = cellURL
                    kp = child
                }
                guard let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(endpointUrl: url, endpoint: url.absoluteString, requester: requester) as? Meddle,
                      let child = kp else { return }
                _ = try? await target.set(keypath: child, value: .string(newValue), requester: requester)
                box.value = newValue
            }
        }
    )
    Task {
        guard let _ = CellBase.defaultCellResolver,
              let requester else { return }
        var url: URL
        var kp: String?
        if keypath.hasPrefix("cell://") {
            url = URL(string: keypath)!
        } else {
            url = URL(string: "cell:///Porthole")!
            kp = keypath
        }
        if kp == nil {
            let (cellURL, child) = splitCellURLLocal(url)
            url = cellURL
            kp = child
        }
        if let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(endpointUrl: url, endpoint: url.absoluteString, requester: requester) as? Meddle,
           let child = kp,
           let v = try? await target.get(keypath: child, requester: requester) {
            switch v {
            case .string(let s): box.value = s
            case .integer(let i): box.value = String(i)
            case .float(let d): box.value = String(d)
            case .bool(let b): box.value = b ? "true" : "false"
            default: break
            }
        }
    }
    return binding
}

private func resolveCellTarget(for keypath: String) -> (URL, String)? {
    var url: URL
    var child: String?

    if keypath.hasPrefix("cell://") {
        guard let absoluteURL = URL(string: keypath) else { return nil }
        url = absoluteURL
    } else {
        guard let defaultURL = URL(string: "cell:///Porthole") else { return nil }
        url = defaultURL
        child = keypath
    }

    if child == nil {
        let split = splitCellURLLocal(url)
        url = split.0
        child = split.1
    }

    guard let child, child.isEmpty == false else {
        return nil
    }
    return (url, child)
}

private func getValueType(at keypath: String, requester: Identity?) async -> ValueType? {
    guard let requester,
          let (url, child) = resolveCellTarget(for: keypath),
          let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(
            endpointUrl: url,
            endpoint: url.absoluteString,
            requester: requester
          ) as? Meddle
    else {
        return nil
    }

    return try? await target.get(keypath: child, requester: requester)
}

private func setValueType(_ value: ValueType, at keypath: String, requester: Identity?) async -> Bool {
    guard let requester,
          let (url, child) = resolveCellTarget(for: keypath),
          let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(
            endpointUrl: url,
            endpoint: url.absoluteString,
            requester: requester
          ) as? Meddle
    else {
        return false
    }

    guard (try? await target.set(keypath: child, value: value, requester: requester)) != nil else {
        return false
    }
    return true
}

#if canImport(UniformTypeIdentifiers)
private func attachmentUTTypes(from identifiers: [String]?) -> [UTType] {
    let identifiers = (identifiers ?? []).filter { $0.isEmpty == false }
    guard identifiers.isEmpty == false else {
        return [.item]
    }

    let resolved = identifiers.compactMap { identifier -> UTType? in
        if let type = UTType(identifier) {
            return type
        }
        switch identifier.lowercased() {
        case "image/*", "public.image":
            return .image
        case "video/*", "public.movie":
            return .movie
        case "audio/*", "public.audio":
            return .audio
        case "text/*", "public.text":
            return .text
        case "application/pdf", "com.adobe.pdf":
            return .pdf
        case "public.data":
            return .data
        default:
            return nil
        }
    }

    return resolved.isEmpty ? [.item] : resolved
}
#endif

private func attachmentValues(from value: ValueType?, allowsMultiple: Bool) -> [AttachmentValue] {
    switch value {
    case .list(let values):
        let decoded = values.compactMap { AttachmentValue(valueType: $0) }
        if decoded.isEmpty, let single = AttachmentValue(valueType: value) {
            return [single]
        }
        return allowsMultiple ? decoded : Array(decoded.prefix(1))
    default:
        guard let single = AttachmentValue(valueType: value) else {
            return []
        }
        return [single]
    }
}

private func preferredAttachmentKind(for url: URL, acceptedContentTypes: [String]?) -> String {
    let accepted = (acceptedContentTypes ?? []).map { $0.lowercased() }
    if accepted.contains(where: { $0.contains("image") }) {
        return "image"
    }
    if accepted.contains(where: { $0.contains("video") }) {
        return "video"
    }
    if accepted.contains(where: { $0.contains("audio") }) {
        return "audio"
    }

    if let inferred = UTType(filenameExtension: url.pathExtension) {
        if inferred.conforms(to: .image) { return "image" }
        if inferred.conforms(to: .movie) { return "video" }
        if inferred.conforms(to: .audio) { return "audio" }
        if inferred.conforms(to: .pdf) { return "document" }
    }
    return "file"
}

private func attachmentMimeType(for url: URL) -> String? {
    guard let inferred = UTType(filenameExtension: url.pathExtension) else {
        return nil
    }
    return inferred.preferredMIMEType
}

private func attachmentValidationMessage(for urls: [URL], maxSizeBytes: Int?) -> String? {
    guard let maxSizeBytes, maxSizeBytes > 0 else {
        return nil
    }

    for url in urls {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize,
           fileSize > maxSizeBytes {
            let maxSize = ByteCountFormatter.string(fromByteCount: Int64(maxSizeBytes), countStyle: .file)
            return "\(url.lastPathComponent) is larger than \(maxSize)."
        }
    }

    return nil
}

private func temporaryAttachmentItemPayload(
    for url: URL,
    acceptedContentTypes: [String]?,
    uploadMode: String?
) -> Object {
    var payload: Object = [
        "displayName": .string(url.lastPathComponent),
        "temporaryURL": .string(url.absoluteString),
        "kind": .string(preferredAttachmentKind(for: url, acceptedContentTypes: acceptedContentTypes)),
        "uploadMode": .string((uploadMode?.isEmpty == false ? uploadMode : "base64") ?? "base64")
    ]

    if let mimeType = attachmentMimeType(for: url) {
        payload["mimeType"] = .string(mimeType)
    }

    if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
       let fileSize = values.fileSize {
        payload["byteSize"] = .integer(fileSize)
    }

    let normalizedUploadMode = (uploadMode ?? "base64").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalizedUploadMode != "metadata" {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let data = try? Data(contentsOf: url) {
            let base64 = data.base64EncodedString()
            if normalizedUploadMode == "chunked" {
                let chunkSize = 256 * 1024
                payload["chunks"] = .list(chunkBase64String(base64, chunkSize: chunkSize).map(ValueType.string))
                payload["chunkEncoding"] = .string("base64")
                payload["chunkSize"] = .integer(chunkSize)
            } else {
                payload["dataBase64"] = .string(base64)
            }
        }
    }

    return payload
}

private func temporaryAttachmentPayload(
    for urls: [URL],
    acceptedContentTypes: [String]?,
    uploadMode: String?
) -> Object {
    let items = urls.map {
        ValueType.object(temporaryAttachmentItemPayload(for: $0, acceptedContentTypes: acceptedContentTypes, uploadMode: uploadMode))
    }
    if let first = items.first, items.count == 1, case let .object(object) = first {
        return object
    }
    return [
        "items": .list(items),
        "count": .integer(items.count),
        "uploadMode": .string((uploadMode?.isEmpty == false ? uploadMode : "base64") ?? "base64")
    ]
}

private func chunkBase64String(_ value: String, chunkSize: Int) -> [String] {
    guard chunkSize > 0 else {
        return [value]
    }

    var chunks: [String] = []
    var start = value.startIndex
    while start < value.endIndex {
        let end = value.index(start, offsetBy: chunkSize, limitedBy: value.endIndex) ?? value.endIndex
        chunks.append(String(value[start..<end]))
        start = end
    }
    return chunks
}

private extension View {
    func applySkeletonModifiers(_ modifiers: SkeletonModifiers?) -> AnyView {
        var view: AnyView = AnyView(self)
        // padding
        if let padding = modifiers?.padding {
            view = AnyView(view.padding(CGFloat(padding)))
        }
        // frame sizing
        let frameWidth: CGFloat? = modifiers?.width.map { CGFloat($0) }
        let frameHeight: CGFloat? = modifiers?.height.map { CGFloat($0) }
        let maxW: CGFloat? = modifiers?.maxWidthInfinity == true ? .infinity : nil
        let maxH: CGFloat? = modifiers?.maxHeightInfinity == true ? .infinity : nil
        // alignment mapping
        func mapH(_ s: String?) -> Alignment { switch (s ?? "") { case "leading": return .leading; case "trailing": return .trailing; default: return .center } }
        func mapV(_ s: String?) -> Alignment { switch (s ?? "") { case "top": return .top; case "bottom": return .bottom; default: return .center } }
        let alignment = Alignment(horizontal: mapH(modifiers?.hAlignment).horizontal, vertical: mapV(modifiers?.vAlignment).vertical)
        view = AnyView(view.frame(width: frameWidth, height: frameHeight, alignment: alignment))
        if maxW != nil || maxH != nil {
            view = AnyView(view.frame(maxWidth: maxW ?? .infinity, maxHeight: maxH ?? .infinity, alignment: alignment))
        }
        // background color
        if let bg = modifiers?.background, let color = Color(hex: bg) {
            view = AnyView(view.background(color))
        }
        // corner radius
        if let cr = modifiers?.cornerRadius { view = AnyView(view.cornerRadius(CGFloat(cr))) }
        // shadow
        if let radius = modifiers?.shadowRadius {
            let x = CGFloat(modifiers?.shadowX ?? 0)
            let y = CGFloat(modifiers?.shadowY ?? 0)
            let c = Color(hex: modifiers?.shadowColor ?? "#00000033") ?? Color.black.opacity(0.2)
            view = AnyView(view.shadow(color: c, radius: CGFloat(radius), x: x, y: y))
        }
        // border
        if let bw = modifiers?.borderWidth, bw > 0 {
            if let hex = modifiers?.borderColor, let c = Color(hex: hex) {
                if let cr = modifiers?.cornerRadius, cr > 0 {
                    view = AnyView(view.overlay(RoundedRectangle(cornerRadius: CGFloat(cr)).stroke(c, lineWidth: CGFloat(bw))))
                } else {
                    view = AnyView(view.overlay(Rectangle().stroke(c, lineWidth: CGFloat(bw))))
                }
            } else {
                // default color if provided width but no color
                let c = Color.black.opacity(0.2)
                if let cr = modifiers?.cornerRadius, cr > 0 {
                    view = AnyView(view.overlay(RoundedRectangle(cornerRadius: CGFloat(cr)).stroke(c, lineWidth: CGFloat(bw))))
                } else {
                    view = AnyView(view.overlay(Rectangle().stroke(c, lineWidth: CGFloat(bw))))
                }
            }
        }
        // opacity
        if let op = modifiers?.opacity { view = AnyView(view.opacity(op)) }
        // hidden
        if let hidden = modifiers?.hidden, hidden { view = AnyView(view.hidden()) }
        view = applyStyleMetadata(to: view, modifiers: modifiers)
        return view
    }
}

private extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var rgba: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&rgba) else { return nil }
        switch s.count {
        case 6:
            let r = Double((rgba & 0xFF0000) >> 16) / 255.0
            let g = Double((rgba & 0x00FF00) >> 8) / 255.0
            let b = Double(rgba & 0x0000FF) / 255.0
            self = Color(red: r, green: g, blue: b)
        case 8:
            let r = Double((rgba & 0xFF000000) >> 24) / 255.0
            let g = Double((rgba & 0x00FF0000) >> 16) / 255.0
            let b = Double((rgba & 0x0000FF00) >> 8) / 255.0
            let a = Double(rgba & 0x000000FF) / 255.0
            self = Color(red: r, green: g, blue: b).opacity(a)
        default:
            return nil
        }
    }
}

public struct SkeletonView: View {
    let element: SkeletonElement

    let userInfoValue: ValueType?
    @EnvironmentObject var viewModel: PortholeViewModel
    public init(element: SkeletonElement, userInfoValue: ValueType? = nil) {
        self.element = element
        self.userInfoValue = userInfoValue
    }
    
    public var body: some View {
        render(element)
    }

    private func render(_ element: SkeletonElement) -> AnyView {
        switch element {
        case .Text(let text):
            return AnyView(
                CellTextView(skeletonText: text, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(text.modifiers)
            )
        case .AttachmentField(let attachmentField):
            return AnyView(
                CellAttachmentFieldView(skeletonAttachmentField: attachmentField)
                    .applySkeletonModifiers(attachmentField.modifiers)
                    .environmentObject(viewModel)
            )
        case .FileUpload(let fileUpload):
            let attachmentField = fileUpload.attachmentField
            return AnyView(
                CellAttachmentFieldView(skeletonAttachmentField: attachmentField)
                    .applySkeletonModifiers(fileUpload.modifiers)
                    .environmentObject(viewModel)
            )
        case .Image(let image):
            return renderSkeletonImage(image)
        case .Spacer(let spacer):
            return AnyView(
                Spacer()
                    .frame(width: spacer.width.map { CGFloat($0) })
                    .applySkeletonModifiers(spacer.modifiers)
            )
        case .HStack(let h):
            return AnyView(
                HStack(alignment: .center, spacing: h.spacing.map { CGFloat($0) } ?? 8) {
                    ForEach(h.elements, id: \.id) { el in
                        render(el)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .applySkeletonModifiers(h.modifiers)
            )
        case .VStack(let v):
            return AnyView(
                VStack(alignment: .center, spacing: v.spacing.map { CGFloat($0) } ?? 8) {
                    ForEach(v.elements, id: \.id) { el in
                        render(el)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .applySkeletonModifiers(v.modifiers)
            )
        case .List(let skeletonList):
            return AnyView(
                CellListView(skeletonList: skeletonList, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(skeletonList.modifiers)
                    .environmentObject(viewModel)
            )
        case .Reference(let skeletonCellReference):
            return AnyView(
                CellReferenceView(skeletonReference: skeletonCellReference, userInfoValue: userInfoValue)
                    .environmentObject(viewModel)
                    .applyIf(skeletonCellReference.scaledToFit) { view in
                        view.scaledToFit()
                    }
                    .applySkeletonModifiers(skeletonCellReference.modifiers)
            )
        case .Object(let o):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(o.elements.keys).sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 6) {
                            Text(key)
                                .bold()
                            Text(":")
                            if let child = o.elements[key] {
                                render(child)
                            } else {
                                Text("nil")
                            }
                        }
                    }
                }
                    .applySkeletonModifiers(o.modifiers)
            )
        case .Button(let btn):
            let resolvedButton = resolveButton(btn, with: userInfoValue)
            return AnyView(
                CellActionButtonView(skeletonButton: resolvedButton)
                    .applySkeletonModifiers(resolvedButton.modifiers)
                    .environmentObject(viewModel)
            )
        case .Divider(let div):
            return AnyView(
                SwiftUI.Divider()
                    .applySkeletonModifiers(div.modifiers)
            )
        case .ScrollView(let sc):
            if sc.axis == "horizontal" {
                return AnyView(
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(sc.elements, id: \.id) { el in
                                render(el)
                            }
                        }
                    }
                    .applySkeletonModifiers(sc.modifiers)
                )
            } else {
                return AnyView(
                    ScrollView(.vertical) {
                        VStack {
                            ForEach(sc.elements, id: \.id) { el in
                                render(el)
                            }
                        }
                    }
                    .applySkeletonModifiers(sc.modifiers)
                )
            }
        case .Section(let sec):
            return AnyView(
                VStack(alignment: .center, spacing: 8) {
                    if let header = sec.header { render(header) }
                    ForEach(sec.content, id: \.id) { el in
                        render(el)
                    }
                    if let footer = sec.footer { render(footer) }
                }
                .applySkeletonModifiers(sec.modifiers)
            )
        case .ZStack(let zs):
            return AnyView(
                ZStack {
                    ForEach(zs.elements, id: \.id) { render($0) }
                }
                .applySkeletonModifiers(zs.modifiers)
            )
        case .Grid(let grid):
            return AnyView(
                CellGridView(skeletonGrid: grid, userInfoValue: userInfoValue)
                    .environmentObject(viewModel)
                .applySkeletonModifiers(grid.modifiers)
            )
        case .Toggle(let tog):
            return AnyView(
                Toggle(tog.label, isOn: toggleBinding(for: tog.keypath, requester: viewModel.currentRequesterIdentity))
                    .applySkeletonModifiers(tog.modifiers)
            )
        case .Picker(let picker):
            return AnyView(
                CellPickerView(skeletonPicker: picker, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(picker.modifiers)
                    .environmentObject(viewModel)
            )
        case .Tabs(let tabs):
            return AnyView(
                CellTabsView(skeletonTabs: tabs, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(tabs.modifiers)
                    .environmentObject(viewModel)
            )
        case .Visualization(let visualization):
            return AnyView(
                CellVisualizationView(skeletonVisualization: visualization, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(visualization.modifiers)
                    .environmentObject(viewModel)
            )
        case .TextField(let tf):
            return AnyView(
                CellTextFieldView(skeletonTextField: tf, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(tf.modifiers)
                    .environmentObject(viewModel)
            )
        case .TextArea(let ta):
            return AnyView(
                CellTextAreaView(skeletonTextArea: ta, userInfoValue: userInfoValue)
                    .applySkeletonModifiers(ta.modifiers)
                    .environmentObject(viewModel)
            )
        @unknown default:
            return AnyView(EmptyView())
        }
    }

    private func describe(_ value: ValueType) -> String {
        (try? value.jsonString()) ?? "null"
    }
    
    private func checkCache(url: URL?, requester: Identity) async -> ValueType? {
        guard let localUrl = url else {
            return nil
        }
        return await self.viewModel.cache.get(localUrl.absoluteString)
    }
    
    private func setCache(url: URL?, requester: Identity, valueType: ValueType) async {
        guard let url = url else { return }
        await self.viewModel.cache.set(valueType, for: url.absoluteString)
    }
    
    private func clearCache(url: URL?, requester: Identity) async {
        guard let url = url else { return }
//        await self.viewModel.cache.set(nil, for: url.absoluteString)
    }
    
    private func clearAllCache() async {
//        await self.viewModel.cache.set(nil, forAllKeys: ())
    }

    private func resolveButton(_ skeletonButton: SkeletonButton, with userInfoValue: ValueType?) -> SkeletonButton {
        var button = skeletonButton
        guard case let .object(object)? = userInfoValue else {
            return button
        }

        if let urlValue = object["url"], case let .string(urlString) = urlValue {
            button.url = urlString
        }
        if let keypathValue = object["keypath"], case let .string(keypathString) = keypathValue {
            button.keypath = keypathString
        }
        if let payloadValue = object["payload"] {
            button.payload = payloadValue
        }
        if let labelValue = object["label"], case let .string(labelString) = labelValue {
            button.label = labelString
        }
        return button
    }
    
    private func makeURL(for keypath: String?, or urlString: String?) -> URL? {
        var url: URL?
        
        if urlString == nil {
            if let localKeypath = keypath {
                if localKeypath.hasPrefix("cell://") {
                    url = URL(string: localKeypath)
                } else {
                    url = URL(string: "cell:///Porthole")?.appending(path: localKeypath)
                }
            }
        } else if keypath == nil {
            if let localUrlString = urlString {
                url = URL(string: localUrlString)
            }
        }
        return url
    }
}


private struct CellAttachmentFieldView: View {
    let skeletonAttachmentField: SkeletonAttachmentField

    @EnvironmentObject var viewModel: PortholeViewModel
    @Environment(\.openURL) private var openURL

    @State private var resolvedAttachments: [AttachmentValue] = []
    @State private var resolvedState: AttachmentFieldState?
    @State private var importerPresented = false
    @State private var pendingPickerActionKind: AttachmentFieldActionKind = .pick
    @State private var isDropTargeted = false

    private var allowsMultiple: Bool {
        skeletonAttachmentField.allowsMultiple == true
    }

    private var canOpen: Bool {
        resolvedState?.canOpen ?? resolvedAttachments.contains { $0.previewURL?.isEmpty == false }
    }

    private var canReplace: Bool {
        resolvedState?.canReplace ?? (!resolvedAttachments.isEmpty && allowsMultiple == false)
    }

    private var canRemove: Bool {
        resolvedState?.canRemove ?? !resolvedAttachments.isEmpty
    }

    private var phase: AttachmentTransferPhase {
        if isDropTargeted && skeletonAttachmentField.supportsDrop == true {
            return .dragTargeted
        }
        if let phase = resolvedState?.phase {
            return phase
        }
        return resolvedAttachments.isEmpty ? .idle : .attached
    }

    private var errorMessage: String? {
        resolvedState?.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? resolvedState?.errorMessage
            : nil
    }

    private var contentTypes: [UTType] {
        attachmentUTTypes(from: skeletonAttachmentField.acceptedContentTypes)
    }

    private var dropHighlightColor: Color {
        phase == .dragTargeted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)
    }

    private var dropBorderColor: Color {
        phase == .dragTargeted ? Color.accentColor : Color.secondary.opacity(0.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = skeletonAttachmentField.title, title.isEmpty == false {
                Text(title)
                    .font(.headline)
            }

            if let subtitle = skeletonAttachmentField.subtitle, subtitle.isEmpty == false {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            attachmentCard

            if let helperText = skeletonAttachmentField.helperText, helperText.isEmpty == false {
                Text(helperText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
            }
        }
        .task(id: taskID) {
            await refreshResolvedValues()
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: contentTypes,
            allowsMultipleSelection: allowsMultiple
        ) { result in
            Task {
                await handleImporterResult(result)
            }
        }
    }

    private var attachmentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .uploading, .picking:
                uploadStateView
            default:
                if resolvedAttachments.isEmpty {
                    emptyStateView
                } else {
                    attachedStateView
                }
            }

            if shouldShowDropHint {
                Label("Drop file here", systemImage: "square.and.arrow.down.on.square")
                    .font(.footnote)
                    .foregroundStyle(phase == .dragTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dropHighlightColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropBorderColor, style: StrokeStyle(lineWidth: 1.25, dash: shouldShowDropHint ? [6] : []))
        )
        .modifier(AttachmentDropModifier(
            isEnabled: skeletonAttachmentField.supportsDrop == true,
            contentTypes: contentTypes,
            isTargeted: $isDropTargeted,
            onURLs: { urls in
                Task {
                    await submitDrop(urls: urls)
                }
            }
        ))
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(skeletonAttachmentField.emptyTitle ?? "No attachment")
                .font(.headline)
            Text(skeletonAttachmentField.emptyMessage ?? "Attach a file to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            primaryAttachButton(label: "Attach…", actionKind: .pick)
        }
    }

    private var uploadStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase == .picking ? "Preparing attachment…" : "Uploading attachment…")
                .font(.headline)
            if let progress = resolvedState?.progressFraction {
                ProgressView(value: min(max(progress, 0), 1))
            } else {
                ProgressView()
            }
            actionRow(includePrimaryAttach: false)
        }
    }

    private var attachedStateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(resolvedAttachments, id: \.id) { attachment in
                attachmentPreview(for: attachment)
            }
            actionRow(includePrimaryAttach: allowsMultiple)
        }
    }

    private func attachmentPreview(for attachment: AttachmentValue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            previewThumbnail(for: attachment)
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.displayName ?? "Attached file")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(attachmentSubtitle(for: attachment))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func previewThumbnail(for attachment: AttachmentValue) -> some View {
        if let previewURL = attachment.previewURL,
           let url = URL(string: previewURL),
           attachment.kind.lowercased() == "image" || attachment.mimeType?.lowercased().hasPrefix("image/") == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Image(systemName: iconName(for: attachment))
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: iconName(for: attachment))
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(includePrimaryAttach: Bool) -> some View {
        HStack(spacing: 8) {
            if includePrimaryAttach {
                primaryAttachButton(
                    label: resolvedAttachments.isEmpty ? "Attach…" : (allowsMultiple ? "Attach another…" : "Replace…"),
                    actionKind: resolvedAttachments.isEmpty ? .pick : (allowsMultiple ? .pick : .replace)
                )
            } else if canReplace {
                primaryAttachButton(label: "Replace…", actionKind: .replace)
            }

            if canOpen {
                Button("Open") {
                    Task {
                        await performAction(.openPreview)
                        await openResolvedPreview()
                    }
                }
                .buttonStyle(.bordered)
            }

            if canRemove {
                Button("Remove") {
                    Task {
                        await performAction(.remove)
                    }
                }
                .buttonStyle(.bordered)
            }

            if phase == .failed || errorMessage != nil {
                Button("Retry") {
                    Task {
                        await performAction(.retry)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func primaryAttachButton(label: String, actionKind: AttachmentFieldActionKind) -> some View {
        Button(label) {
            Task {
                pendingPickerActionKind = actionKind
                await performAction(actionKind)
                await MainActor.run {
                    importerPresented = true
                }
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func attachmentSubtitle(for attachment: AttachmentValue) -> String {
        var parts: [String] = []
        if let mimeType = attachment.mimeType, mimeType.isEmpty == false {
            parts.append(mimeType)
        } else if attachment.kind.isEmpty == false {
            parts.append(attachment.kind)
        }
        if let byteSize = attachment.byteSize, byteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))
        }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " • ")
    }

    private func iconName(for attachment: AttachmentValue) -> String {
        let kind = attachment.kind.lowercased()
        if kind.contains("image") || attachment.mimeType?.lowercased().hasPrefix("image/") == true {
            return "photo"
        }
        if kind.contains("video") || attachment.mimeType?.lowercased().hasPrefix("video/") == true {
            return "film"
        }
        if kind.contains("audio") || attachment.mimeType?.lowercased().hasPrefix("audio/") == true {
            return "waveform"
        }
        if attachment.mimeType == "application/pdf" {
            return "doc.richtext"
        }
        return "doc"
    }

    private var shouldShowDropHint: Bool {
        #if os(macOS)
        skeletonAttachmentField.supportsDrop == true
        #else
        false
        #endif
    }

    private var taskID: String {
        [
            skeletonAttachmentField.id.uuidString,
            skeletonAttachmentField.valueKeypath ?? "__no_value__",
            skeletonAttachmentField.stateKeypath ?? "__no_state__",
            String(viewModel.localMutationVersion)
        ].joined(separator: "::")
    }

    private func refreshResolvedValues() async {
        let requester = await viewModel.executionRequesterIdentity()

        let attachments: [AttachmentValue]
        if let valueKeypath = skeletonAttachmentField.valueKeypath,
           let value = await getValueType(at: valueKeypath, requester: requester) {
            attachments = attachmentValues(from: value, allowsMultiple: allowsMultiple)
        } else {
            attachments = []
        }

        let state: AttachmentFieldState?
        if let stateKeypath = skeletonAttachmentField.stateKeypath,
           let value = await getValueType(at: stateKeypath, requester: requester) {
            state = AttachmentFieldState(valueType: value)
        } else {
            state = nil
        }

        await MainActor.run {
            resolvedAttachments = attachments
            resolvedState = state
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            await submitDrop(urls: urls)
        case .failure:
            break
        }
    }

    private func submitDrop(urls: [URL]) async {
        let urls = allowsMultiple ? urls : Array(urls.prefix(1))
        guard urls.isEmpty == false else {
            return
        }
        if let validationError = attachmentValidationMessage(for: urls, maxSizeBytes: skeletonAttachmentField.maxSizeBytes) {
            await MainActor.run {
                resolvedState = AttachmentFieldState(phase: .failed, errorMessage: validationError)
            }
            return
        }
        let payload = temporaryAttachmentPayload(
            for: urls,
            acceptedContentTypes: skeletonAttachmentField.acceptedContentTypes,
            uploadMode: skeletonAttachmentField.uploadMode
        )
        await performAction(.drop, temporaryPayload: payload)
    }

    private func performAction(_ kind: AttachmentFieldActionKind, temporaryPayload: Object? = nil) async {
        guard let actionKeypath = skeletonAttachmentField.actionKeypath,
              let actionValue = AttachmentFieldAction(
                kind: kind,
                fieldID: skeletonAttachmentField.id.uuidString,
                temporaryPayload: temporaryPayload
              ).valueType
        else {
            return
        }

        let requester = await viewModel.executionRequesterIdentity()
        let didWrite = await setValueType(actionValue, at: actionKeypath, requester: requester)
        if didWrite {
            await MainActor.run {
                viewModel.markLocalMutation()
            }
        }
    }

    private func openResolvedPreview() async {
        guard let target = resolvedAttachments.first?.previewURL,
              let url = URL(string: target) else {
            return
        }
        await MainActor.run {
            openURL(url)
        }
    }
}

#if os(macOS)
private struct AttachmentDropModifier: ViewModifier {
    let isEnabled: Bool
    let contentTypes: [UTType]
    @Binding var isTargeted: Bool
    let onURLs: ([URL]) -> Void

    func body(content: Content) -> some View {
        guard isEnabled else {
            return AnyView(content)
        }

        return AnyView(
            content.onDrop(of: contentTypes, isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let identifiers = contentTypes.map(\.identifier)
        let matchingProviders = providers.filter { provider in
            identifiers.contains(where: provider.hasItemConformingToTypeIdentifier)
        }
        guard matchingProviders.isEmpty == false else {
            return false
        }

        Task {
            var urls: [URL] = []
            for provider in matchingProviders {
                if let url = await loadTemporaryURL(from: provider, identifiers: identifiers) {
                    urls.append(url)
                }
            }
            if urls.isEmpty == false {
                onURLs(urls)
            }
        }

        return true
    }

    private func loadTemporaryURL(from provider: NSItemProvider, identifiers: [String]) async -> URL? {
        for identifier in identifiers {
            if provider.hasItemConformingToTypeIdentifier(identifier) == false {
                continue
            }

            if let url = await withCheckedContinuation({ continuation in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    continuation.resume(returning: url)
                }
            }) {
                return url
            }
        }
        return nil
    }
}
#else
private struct AttachmentDropModifier: ViewModifier {
    let isEnabled: Bool
    let contentTypes: [UTType]
    @Binding var isTargeted: Bool
    let onURLs: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
    }
}
#endif

private struct CellTextView: View {
    let skeletonText: SkeletonText
    let userInfoValue: ValueType?
    @State private var resolvedText: String?
    @EnvironmentObject var viewModel: PortholeViewModel

    private var shouldRenderMarkdown: Bool {
        if sanitizeStyleToken(skeletonText.modifiers?.styleRole ?? "") == "markdown" {
            return true
        }
        guard skeletonText.keypath == "text",
              case let .string(contentType)? = userInfoValue?["contentType"] else {
            return false
        }
        return contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/markdown"
    }

    private var hasDynamicSource: Bool {
        skeletonText.keypath?.isEmpty == false || skeletonText.url != nil
    }

    var body: some View {
        renderText(resolvedText ?? (skeletonText.text ?? ""))
            .applyIf(skeletonText.modifiers?.foregroundColor != nil && Color(hex: skeletonText.modifiers?.foregroundColor ?? "") != nil) { v in
                v.foregroundColor(Color(hex: skeletonText.modifiers?.foregroundColor ?? "")!)
            }
            .applyIf(skeletonText.modifiers?.fontStyle != nil) { v in
                v.font(fontFromStyle(skeletonText.modifiers?.fontStyle ?? ""))
            }
            .applyIf(skeletonText.modifiers?.fontSize != nil) { v in
                v.font(.system(size: CGFloat(skeletonText.modifiers?.fontSize ?? 0), weight: weightFrom(skeletonText.modifiers?.fontWeight)))
            }
            .applyIf(skeletonText.modifiers?.lineLimit != nil) { v in
                v.lineLimit(skeletonText.modifiers?.lineLimit ?? 0)
            }
            .applyIf(skeletonText.modifiers?.multilineTextAlignment != nil) { v in
                v.multilineTextAlignment(textAlignmentFrom(skeletonText.modifiers?.multilineTextAlignment ?? ""))
            }
            .applyIf(skeletonText.modifiers?.minimumScaleFactor != nil) { v in
                v.minimumScaleFactor(skeletonText.modifiers?.minimumScaleFactor ?? 1.0)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .task(id: contentTaskID()) {
                if let cached = await cachedResolvedText() {
                    resolvedText = cached
                    return
                }

                let requester = await viewModel.executionRequesterIdentity()
                let loaded = await skeletonText.asyncContent(
                    userInfoValue: userInfoValue,
                    requester: requester
                )
                resolvedText = loaded
                await cacheResolvedText(loaded)
            }
    }

    private func renderText(_ content: String) -> Text {
        guard shouldRenderMarkdown,
              let rendered = try? AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
              ) else {
            return Text(content)
        }
        return Text(rendered)
    }

    private func contentTaskID() -> String {
        let base = skeletonText.id.uuidString
        let context = (try? userInfoValue?.jsonString()) ?? "__nil__"
        let revision = hasDynamicSource ? String(viewModel.localMutationVersion) : "static"
        return "\(base)::\(context)::\(revision)"
    }

    private func cachedResolvedText() async -> String? {
        guard hasDynamicSource, userInfoValue == nil, let cacheKey = cacheKey() else {
            return nil
        }
        guard case let .string(cached)? = await viewModel.cache.get(cacheKey) else {
            return nil
        }
        return cached
    }

    private func cacheResolvedText(_ text: String) async {
        guard hasDynamicSource, userInfoValue == nil, let cacheKey = cacheKey() else {
            return
        }
        await viewModel.cache.set(.string(text), for: cacheKey)
    }

    private func cacheKey() -> String? {
        if let keypath = skeletonText.keypath, keypath.isEmpty == false {
            return "text::\(keypath)::\(viewModel.localMutationVersion)"
        }
        if let url = skeletonText.url?.absoluteString, url.isEmpty == false {
            return "text::\(url)::\(viewModel.localMutationVersion)"
        }
        return nil
    }
}

private struct CellActionButtonView: View {
    let skeletonButton: SkeletonButton
    @State private var actionInstanceID = UUID().uuidString
    @EnvironmentObject var viewModel: PortholeViewModel

    var body: some View {
        Button {
            Task {
                await execute()
            }
        } label: {
            HStack(spacing: 8) {
                switch executionState {
                case .working:
                    ProgressView()
                        .controlSize(.small)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                case .idle:
                    EmptyView()
                }

                renderStyledButtonLabel(labelText, modifiers: skeletonButton.modifiers)
            }
        }
        .buttonStyle(.plain)
        .disabled(executionState == .working)
        .opacity(executionState == .working ? 0.86 : 1.0)
        .accessibilityValue(accessibilityValue)
    }

    private var actionID: String {
        let payloadSignature: String = {
            guard let payload = skeletonButton.payload else {
                return "__nil__"
            }
            return (try? payload.jsonString()) ?? "__unencodable__"
        }()
        let urlSignature = skeletonButton.url ?? "__nil__"
        return [
            actionInstanceID,
            skeletonButton.id.uuidString,
            skeletonButton.keypath,
            skeletonButton.label,
            urlSignature,
            payloadSignature
        ].joined(separator: "::")
    }

    private var executionState: PortholeViewModel.ActionFeedbackState {
        viewModel.actionFeedbackState(for: actionID)
    }

    private var labelText: String {
        executionState == .working ? "\(skeletonButton.label) …" : skeletonButton.label
    }

    private var accessibilityValue: String {
        switch executionState {
        case .idle:
            return "Idle"
        case .working:
            return "Working"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    private func execute() async {
        await MainActor.run {
            viewModel.setActionFeedbackState(.working, for: actionID)
        }

        var button = skeletonButton
        var response: ValueType?

        if let requester = await requesterIdentity() {
            if let url = actionURL(for: button.keypath, or: button.url),
               let cachedValueType = await viewModel.cache.get(url.absoluteString) {
                button = resolvedActionButton(button, cachedValue: cachedValueType)
            }
            response = await button.execute(requester: requester)
        }

        await MainActor.run {
            viewModel.markLocalMutation()
            viewModel.setActionFeedbackState(response == nil ? .failed : .succeeded, for: actionID)
        }

        guard response != nil else {
            return
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await MainActor.run {
            if viewModel.actionFeedbackState(for: actionID) == .succeeded {
                viewModel.clearActionFeedbackState(for: actionID)
            }
        }
    }

    private func requesterIdentity() async -> Identity? {
        await viewModel.executionRequesterIdentity()
    }

    private func actionURL(for keypath: String?, or urlString: String?) -> URL? {
        if let urlString, keypath == nil {
            return URL(string: urlString)
        }
        guard let keypath else {
            return nil
        }
        if keypath.hasPrefix("cell://") {
            return URL(string: keypath)
        }
        return URL(string: "cell:///Porthole")?.appending(path: keypath)
    }
}

func resolvedActionButton(_ button: SkeletonButton, cachedValue: ValueType?) -> SkeletonButton {
    var resolved = button
    guard resolved.payload == nil, let cachedValue else {
        return resolved
    }
    resolved.payload = cachedValue
    return resolved
}

private enum SkeletonSetActionError: Error {
    case missingTargetKeypath(String)
    case unresolvedTarget(String)
}

private func resolveSkeletonTarget(for actionKeypath: String) throws -> (URL, String) {
    if actionKeypath.hasPrefix("cell://"), let url = URL(string: actionKeypath) {
        let (cellURL, keypath) = splitCellURLLocal(url)
        guard let keypath, keypath.isEmpty == false else {
            throw SkeletonSetActionError.missingTargetKeypath(actionKeypath)
        }
        return (cellURL, keypath)
    }

    guard actionKeypath.isEmpty == false else {
        throw SkeletonSetActionError.missingTargetKeypath(actionKeypath)
    }
    return (URL(string: "cell:///Porthole")!, actionKeypath)
}

struct VisualizationSelectionState {
    var selectedID: String?
    var selectedIndex: Int?
    var selectedIDs: Set<String> = []

    init(_ value: ValueType?) {
        if case let .integer(index)? = value {
            self.selectedIndex = index
            return
        }
        if let id = skeletonStringValue(value) {
            self.selectedID = id
            return
        }
        if case let .list(list)? = value {
            self.selectedIDs = Set(list.compactMap { skeletonStringValue($0) })
            return
        }
        guard case let .object(object)? = value else {
            return
        }
        self.selectedID = skeletonStringValue(object["selectedID"]) ??
            skeletonStringValue(object["id"]) ??
            skeletonStringValue(object["activeID"])
        if case let .integer(index)? = object["selectedIndex"] {
            self.selectedIndex = index
        } else if case let .integer(index)? = object["index"] {
            self.selectedIndex = index
        }
        if case let .list(list)? = object["selectedIDs"] {
            self.selectedIDs = Set(list.compactMap { skeletonStringValue($0) })
        }
    }

    func contains(id: String?, index: Int) -> Bool {
        if let selectedIndex, selectedIndex == index {
            return true
        }
        guard let id else {
            return false
        }
        if selectedID == id {
            return true
        }
        return selectedIDs.contains(id)
    }
}

private struct VisualizationTableColumn: Identifiable {
    var id: String
    var key: String
    var label: String
    var alignment: String = "leading"
}

private struct VisualizationChartPoint: Identifiable {
    var id: String
    var label: String
    var value: Double
    var color: Color?
    var raw: ValueType
}

private struct VisualizationGraphNode: Identifiable {
    var id: String
    var label: String
    var x: Double?
    var y: Double?
    var color: Color?
    var raw: ValueType
}

private struct VisualizationGraphEdge: Identifiable {
    var id: String
    var source: String
    var target: String
    var raw: ValueType
}

private func localVisualizationValue(at keypath: String, from context: ValueType?) -> ValueType? {
    guard keypath.hasPrefix("cell://") == false,
          case let .object(object)? = context else {
        return nil
    }
    return try? object.get(keypath: keypath)
}

private func visualizationObject(_ value: ValueType?) -> Object? {
    guard case let .object(object)? = value else {
        return nil
    }
    return object
}

private func visualizationDouble(_ value: ValueType?) -> Double? {
    switch value {
    case .integer(let integer):
        return Double(integer)
    case .number(let number):
        return Double(number)
    case .float(let float):
        return float
    case .string(let string):
        return Double(string.replacingOccurrences(of: ",", with: "."))
    default:
        return nil
    }
}

private func visualizationString(_ value: ValueType?) -> String? {
    skeletonStringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func visualizationDisplayString(_ value: ValueType?) -> String {
    if let string = visualizationString(value), string.isEmpty == false {
        return string
    }
    guard let value else {
        return ""
    }
    return (try? value.jsonString()) ?? ""
}

private func visualizationColor(from value: ValueType?) -> Color? {
    guard let hex = visualizationString(value), hex.isEmpty == false else {
        return nil
    }
    return Color(hex: hex)
}

private func visualizationRows(from spec: ValueType?) -> [ValueType] {
    if case let .list(list)? = spec {
        return Array(list)
    }
    guard let object = visualizationObject(spec) else {
        return []
    }
    for key in ["rows", "items", "data", "values"] {
        if case let .list(list)? = object[key] {
            return Array(list)
        }
    }
    return []
}

private func visualizationColumns(from spec: ValueType?) -> [VisualizationTableColumn] {
    if let object = visualizationObject(spec),
       case let .list(columnValues)? = object["columns"] {
        let decoded = columnValues.compactMap { value -> VisualizationTableColumn? in
            if let key = visualizationString(value), key.isEmpty == false {
                return VisualizationTableColumn(id: key, key: key, label: key)
            }
            guard let columnObject = visualizationObject(value) else {
                return nil
            }
            let key = visualizationString(columnObject["key"]) ??
                visualizationString(columnObject["id"]) ??
                visualizationString(columnObject["label"]) ??
                "value"
            let label = visualizationString(columnObject["label"]) ??
                visualizationString(columnObject["title"]) ??
                key
            let alignment: String
            switch visualizationString(columnObject["alignment"]) ?? visualizationString(columnObject["align"]) ?? "" {
            case "center":
                alignment = "center"
            case "trailing", "right":
                alignment = "trailing"
            default:
                alignment = "leading"
            }
            return VisualizationTableColumn(id: key, key: key, label: label, alignment: alignment)
        }
        if decoded.isEmpty == false {
            return decoded
        }
    }

    let rows = visualizationRows(from: spec)
    if case let .object(firstRow)? = rows.first {
        return firstRow.keys.sorted().map { key in
            VisualizationTableColumn(id: key, key: key, label: key, alignment: "leading")
        }
    }

    return [VisualizationTableColumn(id: "value", key: "__value__", label: "value", alignment: "leading")]
}

private func visualizationTableCellValue(row: ValueType, column: VisualizationTableColumn) -> ValueType? {
    if column.key == "__value__" {
        return row
    }
    return visualizationObject(row)?[column.key]
}

private func visualizationChartStyle(from spec: ValueType?) -> String {
    guard let object = visualizationObject(spec) else {
        return "bar"
    }
    return (visualizationString(object["chartType"]) ??
        visualizationString(object["style"]) ??
        visualizationString(object["variant"]) ??
        "bar").lowercased()
}

private func visualizationChartPoints(from spec: ValueType?) -> [VisualizationChartPoint] {
    let rows = visualizationRows(from: spec)
    return rows.enumerated().compactMap { index, row in
        if let value = visualizationDouble(row) {
            return VisualizationChartPoint(
                id: "point-\(index)",
                label: "Item \(index + 1)",
                value: value,
                color: nil,
                raw: row
            )
        }
        guard let object = visualizationObject(row),
              let value = visualizationDouble(object["value"] ?? object["y"] ?? object["amount"] ?? object["count"]) else {
            return nil
        }
        let id = visualizationString(object["id"]) ?? visualizationString(object["label"]) ?? "point-\(index)"
        let label = visualizationString(object["label"]) ??
            visualizationString(object["title"]) ??
            visualizationString(object["name"]) ??
            id
        return VisualizationChartPoint(
            id: id,
            label: label,
            value: value,
            color: visualizationColor(from: object["color"]),
            raw: row
        )
    }
}

private func visualizationGraphNodes(from spec: ValueType?) -> [VisualizationGraphNode] {
    let source: ValueType?
    if case .list = spec {
        source = spec
    } else {
        source = visualizationObject(spec)?["nodes"] ?? visualizationObject(spec)?["items"]
    }

    guard case let .list(list)? = source else {
        return []
    }

    return list.enumerated().compactMap { index, value in
        guard let object = visualizationObject(value) else {
            return nil
        }
        let id = visualizationString(object["id"]) ?? "node-\(index)"
        let label = visualizationString(object["label"]) ??
            visualizationString(object["title"]) ??
            visualizationString(object["name"]) ??
            id
        return VisualizationGraphNode(
            id: id,
            label: label,
            x: visualizationDouble(object["x"]),
            y: visualizationDouble(object["y"]),
            color: visualizationColor(from: object["color"]),
            raw: value
        )
    }
}

private func visualizationGraphEdges(from spec: ValueType?) -> [VisualizationGraphEdge] {
    guard let object = visualizationObject(spec),
          case let .list(list)? = object["edges"] ?? object["links"] else {
        return []
    }

    return list.enumerated().compactMap { index, value in
        guard let edgeObject = visualizationObject(value),
              let source = visualizationString(edgeObject["source"] ?? edgeObject["from"]),
              let target = visualizationString(edgeObject["target"] ?? edgeObject["to"]) else {
            return nil
        }
        return VisualizationGraphEdge(
            id: visualizationString(edgeObject["id"]) ?? "edge-\(index)",
            source: source,
            target: target,
            raw: value
        )
    }
}

private func visualizationInteractionPayload(
    visualizationKind: String,
    interaction: String,
    item: ValueType,
    index: Int,
    id: String?,
    label: String?
) -> ValueType {
    var payload: Object = [
        "trigger": .string("visualization"),
        "visualizationKind": .string(visualizationKind),
        "interaction": .string(interaction),
        "index": .integer(index),
        "item": item
    ]

    if let id, id.isEmpty == false {
        payload["id"] = .string(id)
    }
    if let label, label.isEmpty == false {
        payload["label"] = .string(label)
    }

    switch interaction {
    case "row":
        payload["row"] = item
    case "point":
        payload["point"] = item
    case "node":
        payload["node"] = item
    case "feature":
        payload["feature"] = item
    default:
        break
    }

    if let itemObject = visualizationObject(item),
       let value = itemObject["value"] {
        payload["value"] = value
    }

    if interaction == "feature",
       let itemObject = visualizationObject(item),
       let coordinateSpace = itemObject["coordinateSpace"] {
        payload["coordinateSpace"] = coordinateSpace
    }

    return .object(payload)
}

private func visualizationPointPositions(
    for points: [VisualizationChartPoint],
    in size: CGSize
) -> [CGPoint] {
    guard points.isEmpty == false else {
        return []
    }
    let maxValue = max(points.map(\.value).max() ?? 1, 1)
    let usableHeight = max(size.height - 28, 1)
    if points.count == 1 {
        let y = usableHeight - CGFloat(points[0].value / maxValue) * usableHeight + 8
        return [CGPoint(x: size.width / 2, y: y)]
    }
    let stepX = max(size.width - 16, 1) / CGFloat(points.count - 1)
    return points.enumerated().map { index, point in
        let x = 8 + CGFloat(index) * stepX
        let y = usableHeight - CGFloat(point.value / maxValue) * usableHeight + 8
        return CGPoint(x: x, y: y)
    }
}

private func visualizationGraphPositions(
    for nodes: [VisualizationGraphNode]
) -> [String: CGPoint] {
    guard nodes.isEmpty == false else {
        return [:]
    }

    let explicit = nodes.compactMap { node -> (String, CGPoint)? in
        guard let x = node.x, let y = node.y else {
            return nil
        }
        return (node.id, CGPoint(x: x, y: y))
    }

    if explicit.count == nodes.count {
        let maxX = explicit.map { $0.1.x }.max() ?? 1
        let maxY = explicit.map { $0.1.y }.max() ?? 1
        return Dictionary(uniqueKeysWithValues: explicit.map { entry in
            let normalizedX = maxX > 1 ? entry.1.x / maxX : entry.1.x
            let normalizedY = maxY > 1 ? entry.1.y / maxY : entry.1.y
            return (entry.0, CGPoint(x: normalizedX, y: normalizedY))
        })
    }

    let count = Double(nodes.count)
    return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { index, node in
        let angle = (Double(index) / max(count, 1)) * Double.pi * 2
        let radius = 0.36
        let x = 0.5 + cos(angle - Double.pi / 2) * radius
        let y = 0.5 + sin(angle - Double.pi / 2) * radius
        return (node.id, CGPoint(x: x, y: y))
    })
}

private struct CellVisualizationView: View {
    let skeletonVisualization: SkeletonVisualization
    let userInfoValue: ValueType?
    @State private var resolvedSpec: ValueType?
    @State private var resolvedState: ValueType?
    @EnvironmentObject var viewModel: PortholeViewModel

    private var normalizedKind: String {
        skeletonVisualization.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var currentSpec: ValueType? {
        resolvedSpec ?? skeletonVisualization.spec
    }

    private var selectionState: VisualizationSelectionState {
        VisualizationSelectionState(resolvedState)
    }

    var body: some View {
        Group {
            switch normalizedKind {
            case "table":
                let columns = visualizationColumns(from: currentSpec)
                let rows = visualizationRows(from: currentSpec)
                if rows.isEmpty {
                    visualizationFallback(message: "Ingen tabellrader tilgjengelig ennå.")
                } else {
                    VisualizationTableView(
                        visualizationKind: normalizedKind,
                        columns: columns,
                        rows: rows,
                        selection: selectionState,
                        activateRow: actionHandler(for: "row")
                    )
                }
            case "chart":
                let points = visualizationChartPoints(from: currentSpec)
                if points.isEmpty {
                    visualizationFallback(message: "Ingen datapunkter tilgjengelig ennå.")
                } else {
                    VisualizationChartView(
                        visualizationKind: normalizedKind,
                        style: visualizationChartStyle(from: currentSpec),
                        points: points,
                        selection: selectionState,
                        activatePoint: actionHandler(for: "point")
                    )
                }
            case "network", "graph":
                let nodes = visualizationGraphNodes(from: currentSpec)
                let edges = visualizationGraphEdges(from: currentSpec)
                if nodes.isEmpty {
                    visualizationFallback(message: "Ingen noder tilgjengelig ennå.")
                } else {
                    VisualizationNetworkView(
                        visualizationKind: normalizedKind,
                        nodes: nodes,
                        edges: edges,
                        selection: selectionState,
                        activateNode: actionHandler(for: "node")
                    )
                }
            case "map":
                if let mapSpec = MapVisualizationSpec.decode(from: currentSpec) {
                    VisualizationMapView(
                        visualizationKind: normalizedKind,
                        spec: mapSpec,
                        selection: selectionState,
                        activateFeature: actionHandler(for: "feature")
                    )
                } else {
                    visualizationFallback(message: "Kartspesifikasjonen kunne ikke leses.")
                }
            default:
                visualizationFallback(message: "Visualization kind '\(skeletonVisualization.kind)' støttes ikke ennå.")
            }
        }
        .task(id: refreshTaskID()) {
            await refresh()
        }
    }

    private func refreshTaskID() -> String {
        [
            skeletonVisualization.id.uuidString,
            skeletonVisualization.kind,
            skeletonVisualization.keypath ?? "__inline__",
            skeletonVisualization.stateKeypath ?? "__nostate__",
            String(viewModel.localMutationVersion)
        ].joined(separator: "::")
    }

    private func refresh() async {
        let requester = await viewModel.executionRequesterIdentity()
        var nextSpec = skeletonVisualization.spec
        if let keypath = skeletonVisualization.keypath, keypath.isEmpty == false {
            if let localSpec = localVisualizationValue(at: keypath, from: userInfoValue) {
                nextSpec = localSpec
            } else if let remoteSpec = await getValueType(at: keypath, requester: requester) {
                nextSpec = remoteSpec
            }
        }
        var nextState: ValueType?
        if let stateKeypath = skeletonVisualization.stateKeypath, stateKeypath.isEmpty == false {
            if let localState = localVisualizationValue(at: stateKeypath, from: userInfoValue) {
                nextState = localState
            } else {
                nextState = await getValueType(at: stateKeypath, requester: requester)
            }
        }
        await MainActor.run {
            resolvedSpec = nextSpec
            resolvedState = nextState
        }
    }

    private func actionHandler(for interaction: String) -> ((ValueType, Int, String?, String?) -> Void)? {
        guard let actionKeypath = skeletonVisualization.actionKeypath,
              actionKeypath.isEmpty == false else {
            return nil
        }
        return { item, index, id, label in
            Task {
                let requester = await viewModel.executionRequesterIdentity()
                let payload = visualizationInteractionPayload(
                    visualizationKind: normalizedKind,
                    interaction: interaction,
                    item: item,
                    index: index,
                    id: id,
                    label: label
                )
                let didSubmit = await setValueType(payload, at: actionKeypath, requester: requester)
                if didSubmit {
                    await MainActor.run {
                        viewModel.markLocalMutation()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func visualizationFallback(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skeletonVisualization.kind.capitalized)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.04))
        .cornerRadius(12)
    }
}

private struct VisualizationTableView: View {
    let visualizationKind: String
    let columns: [VisualizationTableColumn]
    let rows: [ValueType]
    let selection: VisualizationSelectionState
    let activateRow: ((ValueType, Int, String?, String?) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(columns) { column in
                    Text(column.label)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: alignment(for: column.alignment))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.05))

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let rowID = visualizationString(visualizationObject(row)?["id"]) ?? "row-\(index)"
                let rowLabel = visualizationString(visualizationObject(row)?["label"])
                let isSelected = selection.contains(id: rowID, index: index)
                Group {
                    if let activateRow {
                        Button {
                            activateRow(row, index, rowID, rowLabel)
                        } label: {
                            rowContent(row: row)
                        }
                        .buttonStyle(.plain)
                    } else {
                        rowContent(row: row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)

                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color.black.opacity(0.02))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func rowContent(row: ValueType) -> some View {
        HStack(spacing: 12) {
            ForEach(columns) { column in
                Text(visualizationDisplayString(visualizationTableCellValue(row: row, column: column)))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: alignment(for: column.alignment))
            }
        }
        .contentShape(Rectangle())
    }

    private func alignment(for horizontalAlignment: String) -> Alignment {
        switch horizontalAlignment {
        case "center":
            return .center
        case "trailing":
            return .trailing
        default:
            return .leading
        }
    }
}

private struct VisualizationChartView: View {
    let visualizationKind: String
    let style: String
    let points: [VisualizationChartPoint]
    let selection: VisualizationSelectionState
    let activatePoint: ((ValueType, Int, String?, String?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style == "line" && points.count > 1 {
                lineChart
            } else {
                barChart
            }
        }
    }

    private var barChart: some View {
        GeometryReader { geometry in
            let maxValue = max(points.map(\.value).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let isSelected = selection.contains(id: point.id, index: index)
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(point.color ?? (isSelected ? Color.accentColor : Color.accentColor.opacity(0.72)))
                            .frame(height: max(10, CGFloat(point.value / maxValue) * max(geometry.size.height - 36, 1)))
                        Text(point.label)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activatePoint?(point.raw, index, point.id, point.label)
                    }
                }
            }
        }
        .frame(height: 220)
    }

    private var lineChart: some View {
        GeometryReader { geometry in
            let positions = visualizationPointPositions(for: points, in: geometry.size)
            ZStack {
                Path { path in
                    guard let first = positions.first else {
                        return
                    }
                    path.move(to: first)
                    for point in positions.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let location = positions[index]
                    let isSelected = selection.contains(id: point.id, index: index)
                    Circle()
                        .fill(point.color ?? (isSelected ? Color.accentColor : Color.white))
                        .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .position(location)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activatePoint?(point.raw, index, point.id, point.label)
                        }

                    Text(point.label)
                        .font(.caption2)
                        .position(x: location.x, y: min(geometry.size.height - 8, location.y + 22))
                }
            }
        }
        .frame(height: 220)
    }
}

private struct VisualizationNetworkView: View {
    let visualizationKind: String
    let nodes: [VisualizationGraphNode]
    let edges: [VisualizationGraphEdge]
    let selection: VisualizationSelectionState
    let activateNode: ((ValueType, Int, String?, String?) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let positions = visualizationGraphPositions(for: nodes)
            ZStack {
                ForEach(edges) { edge in
                    if let source = positions[edge.source], let target = positions[edge.target] {
                        Path { path in
                            path.move(to: CGPoint(x: source.x * geometry.size.width, y: source.y * geometry.size.height))
                            path.addLine(to: CGPoint(x: target.x * geometry.size.width, y: target.y * geometry.size.height))
                        }
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    }
                }

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    let point = positions[node.id] ?? CGPoint(x: 0.5, y: 0.5)
                    let isSelected = selection.contains(id: node.id, index: index)
                    VStack(spacing: 6) {
                        Circle()
                            .fill(node.color ?? (isSelected ? Color.accentColor : Color.accentColor.opacity(0.82)))
                            .frame(width: isSelected ? 26 : 22, height: isSelected ? 26 : 22)
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        Text(node.label)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activateNode?(node.raw, index, node.id, node.label)
                    }
                }
            }
        }
        .frame(height: 260)
    }
}

private struct CellTabsView: View {
    let skeletonTabs: SkeletonTabs
    let userInfoValue: ValueType?
    @State private var tabRows: ValueTypeList = ValueTypeList()
    @State private var activeTabID: String = ""
    @EnvironmentObject var viewModel: PortholeViewModel

    private var rows: ValueTypeList {
        if tabRows.isEmpty == false {
            return tabRows
        }
        return skeletonTabs.panels.enumerated().map { index, panel in
            .object([
                "id": .string(panel.id),
                "title": .string(defaultPanelTitle(panel.id)),
                "order": .integer(index + 1)
            ])
        }
    }

    private var resolvedActiveTabID: String {
        let panelIDs = Set(skeletonTabs.panels.map(\.id))
        if panelIDs.contains(activeTabID) {
            return activeTabID
        }
        return skeletonTabs.panels.first?.id ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let id = tabID(for: row)
                        Button {
                            Task {
                                await select(row: row, id: id, index: index)
                            }
                        } label: {
                            Text(tabLabel(for: row, fallback: id))
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(id == resolvedActiveTabID ? Color.accentColor.opacity(0.16) : Color.clear)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(id == resolvedActiveTabID ? "Selected" : "")
                    }
                }
            }

            if let panel = skeletonTabs.panels.first(where: { $0.id == resolvedActiveTabID }) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(panel.content, id: \.id) { element in
                        SkeletonView(element: element, userInfoValue: userInfoValue)
                            .environmentObject(viewModel)
                    }
                }
                .applySkeletonModifiers(panel.modifiers)
            }
        }
        .task(id: refreshTaskID()) {
            await loadTabs()
            await loadActiveTab()
        }
    }

    private func refreshTaskID() -> String {
        let tabsKeypath = skeletonTabs.tabsKeypath ?? "__static_tabs__"
        return "\(tabsKeypath)::\(skeletonTabs.activeTabStateKeypath)::\(viewModel.localMutationVersion)"
    }

    private func tabID(for row: ValueType) -> String {
        if let id = row[skeletonTabs.idKeypath] {
            return skeletonStringValue(id) ?? ""
        }
        return skeletonStringValue(row) ?? ""
    }

    private func tabLabel(for row: ValueType, fallback: String) -> String {
        if let label = row[skeletonTabs.labelKeypath] {
            return skeletonStringValue(label) ?? fallback
        }
        return skeletonStringValue(row) ?? fallback
    }

    private func defaultPanelTitle(_ id: String) -> String {
        id
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func loadTabs() async {
        guard let tabsKeypath = skeletonTabs.tabsKeypath, tabsKeypath.isEmpty == false,
              let value = try? await fetchValue(at: tabsKeypath),
              case let .list(list) = value else {
            return
        }
        await MainActor.run {
            tabRows = list
        }
    }

    private func loadActiveTab() async {
        guard skeletonTabs.activeTabStateKeypath.isEmpty == false,
              let value = try? await fetchValue(at: skeletonTabs.activeTabStateKeypath),
              let id = skeletonStringValue(value),
              id.isEmpty == false else {
            return
        }
        await MainActor.run {
            activeTabID = id
        }
    }

    private func select(row: ValueType, id: String, index: Int) async {
        guard id.isEmpty == false else { return }
        await MainActor.run {
            activeTabID = id
        }

        let actionKeypath = skeletonTabs.selectionActionKeypath?.isEmpty == false
            ? skeletonTabs.selectionActionKeypath!
            : skeletonTabs.activeTabStateKeypath
        let payload: ValueType
        if skeletonTabs.selectionActionKeypath?.isEmpty == false {
            payload = .object([
                "trigger": .string("select"),
                "selectedIndex": .integer(index),
                "selected": row,
                "selectedValue": .string(id),
                "id": .string(id)
            ])
        } else {
            payload = .string(id)
        }
        try? await submit(payload: payload, to: actionKeypath)
        await MainActor.run {
            viewModel.markLocalMutation()
        }
    }

    private func fetchValue(at keypath: String) async throws -> ValueType {
        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }

        let (targetURL, childKeypath) = try resolveSkeletonTarget(for: keypath)
        guard let target = try await resolver.cellAtEndpoint(
            endpoint: targetURL.absoluteString,
            requester: requester
        ) as? Meddle else {
            throw SkeletonSetActionError.unresolvedTarget(targetURL.absoluteString)
        }

        return try await target.get(keypath: childKeypath, requester: requester)
    }

    private func submit(payload: ValueType, to actionKeypath: String) async throws {
        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }

        let (targetURL, keypath) = try resolveSkeletonTarget(for: actionKeypath)
        guard let target = try await resolver.cellAtEndpoint(
            endpoint: targetURL.absoluteString,
            requester: requester
        ) as? Meddle else {
            throw SkeletonSetActionError.unresolvedTarget(targetURL.absoluteString)
        }

        _ = try await target.set(keypath: keypath, value: payload, requester: requester)
    }
}

private struct CellTextFieldView: View {
    let skeletonTextField: SkeletonTextField
    let userInfoValue: ValueType?
    @State private var text: String = ""
    @State private var suggestions: ValueTypeList = ValueTypeList()
    @State private var isDropdownVisible = false
    @State private var highlightedIndex = 0
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    @EnvironmentObject var viewModel: PortholeViewModel
    
//    private var requester: Identity? = nil
//    private var fullURL: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SwiftUI.TextField(skeletonTextField.placeholder ?? "", text: binding())
                .focused($isFocused)
                .applyIf(skeletonTextField.modifiers?.foregroundColor != nil && Color(hex: skeletonTextField.modifiers?.foregroundColor ?? "") != nil) { v in
                    v.foregroundColor(Color(hex: skeletonTextField.modifiers?.foregroundColor ?? "")!)
                }
                .applyIf(skeletonTextField.modifiers?.fontStyle != nil) { v in
                    v.font(fontFromStyle(skeletonTextField.modifiers?.fontStyle ?? ""))
                }
                .applyIf(skeletonTextField.modifiers?.fontSize != nil) { v in
                    v.font(.system(size: CGFloat(skeletonTextField.modifiers?.fontSize ?? 0), weight: weightFrom(skeletonTextField.modifiers?.fontWeight)))
                }
                .applyIf(skeletonTextField.modifiers?.lineLimit != nil) { v in
                    v.lineLimit(skeletonTextField.modifiers?.lineLimit ?? 0)
                }
                .applyIf(skeletonTextField.modifiers?.multilineTextAlignment != nil) { v in
                    v.multilineTextAlignment(textAlignmentFrom(skeletonTextField.modifiers?.multilineTextAlignment ?? ""))
                }
                .applyIf(skeletonTextField.modifiers?.minimumScaleFactor != nil) { v in
                    v.minimumScaleFactor(skeletonTextField.modifiers?.minimumScaleFactor ?? 1.0)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .task(id: refreshTaskID()) { await loadInitial() }
                .onChange(of: isFocused) { focused in
                    if focused {
                        scheduleAutocompleteQuery(text)
                    } else {
                        isDropdownVisible = false
                    }
                }
                .onSubmit {
                    Task {
                        await handleSubmit()
                    }
                }

            if isDropdownVisible, suggestions.isEmpty == false {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button {
                            Task {
                                await selectSuggestion(suggestion, index: index)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestionLabel(suggestion))
                                    .font(.body)
                                let detail = suggestionDetail(suggestion)
                                if detail.isEmpty == false {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(index == highlightedIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        if index < suggestions.count - 1 {
                            SwiftUI.Divider()
                        }
                    }
                }
                .background(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                )
                .cornerRadius(8)
            }
        }
        #if os(macOS)
        .onExitCommand {
            isDropdownVisible = false
        }
        .onMoveCommand { direction in
            guard isDropdownVisible, suggestions.isEmpty == false else { return }
            switch direction {
            case .down:
                highlightedIndex = min(highlightedIndex + 1, suggestions.count - 1)
            case .up:
                highlightedIndex = max(highlightedIndex - 1, 0)
            default:
                break
            }
        }
        #endif
    }

    private func binding() -> Binding<String> {
        Binding<String>(
            get: { text },
            set: { newValue in
                text = newValue
                scheduleAutocompleteQuery(newValue)
                Task {
                    guard let requester = try? await requester() else { return }
                    let (fullURL, _) = generateFullURL(for: skeletonTextField.targetKeypath ?? skeletonTextField.sourceKeypath)
                    await setCache(url: fullURL, requester: requester, valueType: .string(text))
                }
            }
        )
    }

    private func refreshTaskID() -> String {
        let source = skeletonTextField.sourceKeypath ?? "__static__"
        return "\(source)::\(viewModel.localMutationVersion)"
    }

    private func handleSubmit() async {
        if isDropdownVisible, suggestions.indices.contains(highlightedIndex) {
            await selectSuggestion(suggestions[highlightedIndex], index: highlightedIndex)
            return
        }
        if skeletonTextField.autocomplete?.allowsCustomValue == false,
           suggestions.isEmpty == false {
            return
        }
        await submitCurrentValue()
    }

    private func submitCurrentValue() async {
        guard let targetKeypath = skeletonTextField.targetKeypath, !targetKeypath.isEmpty else {
            return
        }

        var submitButton = SkeletonButton(
            keypath: targetKeypath,
            label: "Submit",
            payload: .string(text)
        )
        if targetKeypath.hasPrefix("cell://"), let targetURL = URL(string: targetKeypath) {
            let (cellURL, child) = splitCellURLLocal(targetURL)
            if let child {
                submitButton.keypath = child
                submitButton.url = cellURL.absoluteString
            }
        }
        let requester = try? await requester()
        let response = await submitButton.execute(requester: requester)
        guard response != nil else {
            return
        }
        await MainActor.run {
            viewModel.markLocalMutation()
        }
    }

    private func scheduleAutocompleteQuery(_ query: String) {
        guard let autocomplete = skeletonTextField.autocomplete,
              autocomplete.queryActionKeypath?.isEmpty == false,
              autocomplete.suggestionsKeypath?.isEmpty == false else {
            return
        }

        let minimum = max(0, autocomplete.minCharacters)
        if query.count < minimum {
            suggestions = ValueTypeList()
            isDropdownVisible = false
            highlightedIndex = 0
            return
        }

        debounceTask?.cancel()
        debounceTask = Task {
            let delay = max(0, autocomplete.debounceMilliseconds)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
            if Task.isCancelled { return }
            await runAutocompleteQuery(query, autocomplete: autocomplete)
        }
    }

    private func runAutocompleteQuery(_ query: String, autocomplete: SkeletonAutocomplete) async {
        if let queryActionKeypath = autocomplete.queryActionKeypath,
           queryActionKeypath.isEmpty == false {
            try? await submit(payload: .string(query), to: queryActionKeypath)
        }

        guard let suggestionsKeypath = autocomplete.suggestionsKeypath,
              suggestionsKeypath.isEmpty == false,
              let value = try? await fetchValue(at: suggestionsKeypath),
              case let .list(list) = value else {
            await MainActor.run {
                suggestions = ValueTypeList()
                isDropdownVisible = false
                highlightedIndex = 0
            }
            return
        }

        await MainActor.run {
            suggestions = list
            highlightedIndex = 0
            isDropdownVisible = isFocused && list.isEmpty == false
            viewModel.markLocalMutation()
        }
    }

    private func selectSuggestion(_ suggestion: ValueType, index: Int) async {
        guard let autocomplete = skeletonTextField.autocomplete else { return }
        let originalQuery = text
        let selectedValue = suggestionValue(suggestion)
        await MainActor.run {
            text = selectedValue
            highlightedIndex = index
            isDropdownVisible = false
        }

        if let requester = try? await requester() {
            let (fullURL, _) = generateFullURL(for: skeletonTextField.targetKeypath ?? skeletonTextField.sourceKeypath)
            await setCache(url: fullURL, requester: requester, valueType: .string(selectedValue))
        }

        if let selectionActionKeypath = autocomplete.selectionActionKeypath,
           selectionActionKeypath.isEmpty == false {
            let payload: ValueType = .object([
                "trigger": .string("select"),
                "query": .string(originalQuery),
                "selectedIndex": .integer(index),
                "selected": suggestion,
                "selectedValue": .string(selectedValue)
            ])
            try? await submit(payload: payload, to: selectionActionKeypath)
        } else if let targetKeypath = skeletonTextField.targetKeypath,
                  targetKeypath.isEmpty == false {
            try? await submit(payload: .string(selectedValue), to: targetKeypath)
        }

        await MainActor.run {
            viewModel.markLocalMutation()
        }
    }

    private func suggestionLabel(_ suggestion: ValueType) -> String {
        if let keypath = skeletonTextField.autocomplete?.optionLabelKeypath,
           keypath.isEmpty == false,
           let value = suggestion[keypath] {
            return skeletonStringValue(value) ?? suggestionValue(suggestion)
        }
        return suggestionValue(suggestion)
    }

    private func suggestionValue(_ suggestion: ValueType) -> String {
        if let keypath = skeletonTextField.autocomplete?.optionValueKeypath,
           keypath.isEmpty == false,
           let value = suggestion[keypath],
           let string = skeletonStringValue(value),
           string.isEmpty == false {
            return string
        }
        return skeletonStringValue(suggestion) ?? ""
    }

    private func suggestionDetail(_ suggestion: ValueType) -> String {
        let detailKeypaths = skeletonTextField.autocomplete?.optionDetailKeypaths ?? []
        return detailKeypaths.compactMap { keypath in
            guard let value = suggestion[keypath],
                  let text = skeletonStringValue(value),
                  text.isEmpty == false else {
                return nil
            }
            return text
        }.joined(separator: " · ")
    }

    private func fetchValue(at keypath: String) async throws -> ValueType {
        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }

        let (targetURL, childKeypath) = try resolveSkeletonTarget(for: keypath)
        guard let target = try await resolver.cellAtEndpoint(
            endpoint: targetURL.absoluteString,
            requester: requester
        ) as? Meddle else {
            throw SkeletonSetActionError.unresolvedTarget(targetURL.absoluteString)
        }

        return try await target.get(keypath: childKeypath, requester: requester)
    }

    private func submit(payload: ValueType, to actionKeypath: String) async throws {
        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }

        let (targetURL, keypath) = try resolveSkeletonTarget(for: actionKeypath)
        guard let target = try await resolver.cellAtEndpoint(
            endpoint: targetURL.absoluteString,
            requester: requester
        ) as? Meddle else {
            throw SkeletonSetActionError.unresolvedTarget(targetURL.absoluteString)
        }

        _ = try await target.set(keypath: keypath, value: payload, requester: requester)
    }

    private func loadInitial() async {
        // seed from userInfoValue if available
        if text.isEmpty, let key = skeletonTextField.sourceKeypath, let v = userInfoValue?[key] {
            switch v {
            case .string(let s): text = s
            case .integer(let i): text = String(i)
            case .float(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: break
            }
        }
        // then try to fetch from remote
        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else { return }

        let (fullURL, url) = generateFullURL(for: skeletonTextField.targetKeypath ?? skeletonTextField.sourceKeypath)
//        Check cache
            var valueType = await checkCache(url: fullURL, requester: requester)
        
        if valueType == nil {
            if let meddleCell = try? await resolver.cellAtEndpoint(endpoint: url.absoluteString, requester: requester) as? Meddle,
            let keypath = skeletonTextField.sourceKeypath
            {
                valueType = try? await meddleCell.get(keypath: keypath, requester: requester)
            }
        }
        
        if valueType != nil {
            switch valueType {
            case .string(let s): text = s
            case .integer(let i): text = String(i)
            case .float(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: ()
            
        }
            await setCache(url: fullURL, requester: requester, valueType: .string(text))
            
        }
        
    }

    private func requester() async throws-> Identity {
        guard let _ = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }
        return requester
    }
    
    private func generateFullURL(for keypath: String?) -> (URL, URL) {
        var url: URL
        
        var fullURL: URL?
        if let keypath = keypath, keypath.hasPrefix("cell://") {
            url = URL(string: keypath)!
            fullURL = url
        } else {
            url = URL(string: "cell:///Porthole")!
            if let tmpKeypath = keypath {
                fullURL = url.appending(path: tmpKeypath)
            }
        }
//        if keypath == nil {
//            let (cellURL, child) = splitCellURLLocal(url)
//            url = cellURL
//            keypath = child
//        }
        return (fullURL ?? url, url)
    }
    private func checkCache(url: URL?, requester: Identity) async -> ValueType? {
        guard let url = url else {
            return nil
        }
        return await self.viewModel.cache.get(url.absoluteString)
    }
    
    private func setCache(url: URL?, requester: Identity, valueType: ValueType) async {
        guard let url = url else { return }
        await self.viewModel.cache.set(valueType, for: url.absoluteString)
    }
    
    
//    private func persist(_ newValue: String) async {
//        guard let _ = CellBase.defaultCellResolver,
//              let vault = CellBase.defaultIdentityVault,
//              let requester = await vault.identity(for: "private", makeNewIfNotFound: true) else { return }
//        var url: URL
//        var kp: String?
//        if let keypath = skeletonTextField.keypath, keypath.hasPrefix("cell://") {
//            url = URL(string: keypath)!
//        } else {
//            url = URL(string: "cell:///Porthole")!
//            kp = skeletonTextField.keypath
//        }
//        if kp == nil {
//            let (cellURL, child) = splitCellURLLocal(url)
//            url = cellURL
//            kp = child
//        }
//        guard let target = try? await CellResolver.sharedInstance.emitCellAtEndpoint(endpointUrl: url, endpoint: url.absoluteString, requester: requester) as? Meddle,
//              let child = kp else { return }
//        _ = try? await target.set(keypath: child, value: .string(newValue), requester: requester)
//    }
}

private struct CellTextAreaView: View {
    let skeletonTextArea: SkeletonTextArea
    let userInfoValue: ValueType?
    @State private var text: String = ""
    @State private var persistTask: Task<Void, Never>?
    @State private var lastLocalEditAt: Date?
    @StateObject private var richMarkdownController = RichMarkdownEditorController()
    @EnvironmentObject var viewModel: PortholeViewModel

    var body: some View {
        editorBody
        .frame(maxWidth: .infinity, alignment: .center)
        .task(id: refreshTaskID()) { await loadInitial() }
    }

    @ViewBuilder
    private var editorBody: some View {
        #if os(macOS)
        if skeletonTextArea.editorMode == .richMarkdown {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    richToolbarButton("B") { richMarkdownController.apply(.bold) }
                    richToolbarButton("I") { richMarkdownController.apply(.italic) }
                    richToolbarButton("</>") { richMarkdownController.apply(.code) }
                    richToolbarButton("•") { richMarkdownController.apply(.bullet) }
                    richToolbarButton("❝") { richMarkdownController.apply(.quote) }
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty, let placeholder = skeletonTextArea.placeholder, !placeholder.isEmpty {
                        Text(placeholder)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }

                    RichMarkdownTextEditor(
                        markdown: binding(),
                        minHeight: minHeight(),
                        maxHeight: maxHeight(),
                        modifiers: skeletonTextArea.modifiers,
                        controller: richMarkdownController
                    )
                    .frame(minHeight: minHeight(), maxHeight: maxHeight())
                }
            }
        } else {
            plainEditorBody
        }
        #else
        plainEditorBody
        #endif
    }

    private var plainEditorBody: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, let placeholder = skeletonTextArea.placeholder, !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            TextEditor(text: binding())
                .applyIf(skeletonTextArea.modifiers?.foregroundColor != nil && Color(hex: skeletonTextArea.modifiers?.foregroundColor ?? "") != nil) { v in
                    v.foregroundColor(Color(hex: skeletonTextArea.modifiers?.foregroundColor ?? "")!)
                }
                .applyIf(skeletonTextArea.modifiers?.fontStyle != nil) { v in
                    v.font(fontFromStyle(skeletonTextArea.modifiers?.fontStyle ?? ""))
                }
                .applyIf(skeletonTextArea.modifiers?.fontSize != nil) { v in
                    v.font(.system(size: CGFloat(skeletonTextArea.modifiers?.fontSize ?? 0), weight: weightFrom(skeletonTextArea.modifiers?.fontWeight)))
                }
                .frame(minHeight: minHeight(), maxHeight: maxHeight())
        }
    }

    #if os(macOS)
    private func richToolbarButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
    #endif

    private func binding() -> Binding<String> {
        Binding<String>(
            get: { text },
            set: { newValue in
                var valueToPersist = newValue
                let submitOnEnter = skeletonTextArea.submitOnEnter == true
                let shouldSubmit = submitOnEnter && valueToPersist.hasSuffix("\n")
                if shouldSubmit {
                    valueToPersist.removeLast()
                }
                text = valueToPersist
                lastLocalEditAt = Date()
                persistTask?.cancel()
                persistTask = Task {
                    guard let requester = try? await requester() else { return }
                    let (fullURL, _) = generateFullURL(for: skeletonTextArea.targetKeypath ?? skeletonTextArea.sourceKeypath)
                    await setCache(url: fullURL, requester: requester, valueType: .string(valueToPersist))

                    if shouldSubmit {
                        await submitCurrentValue(valueToPersist)
                    } else if skeletonTextArea.targetKeypath?.isEmpty == false {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        if Task.isCancelled { return }
                        await persistCurrentValue(valueToPersist)
                    }

                    await MainActor.run {
                        viewModel.markLocalMutation()
                    }
                }
            }
        )
    }

    private func submitCurrentValue(_ value: String) async {
        guard let targetKeypath = skeletonTextArea.targetKeypath, !targetKeypath.isEmpty else {
            return
        }

        var submitButton = SkeletonButton(
            keypath: targetKeypath,
            label: "Submit",
            payload: .string(value)
        )
        if targetKeypath.hasPrefix("cell://"), let targetURL = URL(string: targetKeypath) {
            let (cellURL, child) = splitCellURLLocal(targetURL)
            if let child {
                submitButton.keypath = child
                submitButton.url = cellURL.absoluteString
            }
        }
        let requester = try? await requester()
        let response = await submitButton.execute(requester: requester)
        guard response != nil else {
            return
        }
        await MainActor.run {
            viewModel.markLocalMutation()
        }
    }

    private func persistCurrentValue(_ value: String) async {
        guard let targetKeypath = skeletonTextArea.targetKeypath, !targetKeypath.isEmpty else {
            return
        }

        var persistButton = SkeletonButton(
            keypath: targetKeypath,
            label: "Persist",
            payload: .string(value)
        )
        if targetKeypath.hasPrefix("cell://"), let targetURL = URL(string: targetKeypath) {
            let (cellURL, child) = splitCellURLLocal(targetURL)
            if let child {
                persistButton.keypath = child
                persistButton.url = cellURL.absoluteString
            }
        }
        let requester = try? await requester()
        let response = await persistButton.execute(requester: requester)
        guard response != nil else {
            return
        }
        await MainActor.run {
            viewModel.markLocalMutation()
        }
    }

    private func loadInitial() async {
        if let lastLocalEditAt {
            let elapsed = Date().timeIntervalSince(lastLocalEditAt)
            if elapsed < 0.45 {
                let remainingDelay = UInt64((0.45 - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: remainingDelay)
                if Task.isCancelled { return }
            }
        }

        if text.isEmpty, let key = skeletonTextArea.sourceKeypath, let v = userInfoValue?[key] {
            switch v {
            case .string(let s): text = s
            case .integer(let i): text = String(i)
            case .float(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: break
            }
        }

        guard let resolver = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else { return }

        let (fullURL, url) = generateFullURL(for: skeletonTextArea.targetKeypath ?? skeletonTextArea.sourceKeypath)
        var valueType: ValueType?
        if let meddleCell = try? await resolver.cellAtEndpoint(endpoint: url.absoluteString, requester: requester) as? Meddle,
           let keypath = skeletonTextArea.sourceKeypath {
            valueType = try? await meddleCell.get(keypath: keypath, requester: requester)
        }

        if valueType == nil {
            valueType = await checkCache(url: fullURL, requester: requester)
        }

        if valueType != nil {
            switch valueType {
            case .string(let s): text = s
            case .integer(let i): text = String(i)
            case .float(let d): text = String(d)
            case .bool(let b): text = b ? "true" : "false"
            default: ()
            }
            await setCache(url: fullURL, requester: requester, valueType: .string(text))
        }
    }

    private func requester() async throws -> Identity {
        guard let _ = CellBase.defaultCellResolver,
              let requester = await viewModel.executionRequesterIdentity() else {
            throw CellBaseError.noIdentity
        }
        return requester
    }

    private func generateFullURL(for keypath: String?) -> (URL, URL) {
        var url: URL

        var fullURL: URL?
        if let keypath = keypath, keypath.hasPrefix("cell://") {
            url = URL(string: keypath)!
            fullURL = url
        } else {
            url = URL(string: "cell:///Porthole")!
            if let tmpKeypath = keypath {
                fullURL = url.appending(path: tmpKeypath)
            }
        }
        return (fullURL ?? url, url)
    }

    private func checkCache(url: URL?, requester: Identity) async -> ValueType? {
        guard let url = url else {
            return nil
        }
        return await self.viewModel.cache.get(url.absoluteString)
    }

    private func setCache(url: URL?, requester: Identity, valueType: ValueType) async {
        guard let url = url else { return }
        await self.viewModel.cache.set(valueType, for: url.absoluteString)
    }

    private func minHeight() -> CGFloat {
        let lines = max(1, skeletonTextArea.minLines ?? 4)
        return CGFloat(lines * 22)
    }

    private func maxHeight() -> CGFloat? {
        guard let maxLines = skeletonTextArea.maxLines else {
            return nil
        }
        let minLines = max(1, skeletonTextArea.minLines ?? 1)
        return CGFloat(max(maxLines, minLines) * 22)
    }

    private func refreshTaskID() -> String {
        let sourceKeypath = skeletonTextArea.sourceKeypath ?? skeletonTextArea.targetKeypath ?? "__no_keypath__"
        let sourceValueSignature: String = {
            guard let sourceKeypath = skeletonTextArea.sourceKeypath,
                  let value = userInfoValue?[sourceKeypath] else {
                return "__nil__"
            }
            return (try? value.jsonString()) ?? "__unencodable__"
        }()
        return "\(sourceKeypath)::\(sourceValueSignature)"
    }
}

private enum RichMarkdownEditorCommand {
    case bold
    case italic
    case code
    case bullet
    case quote
}

private final class RichMarkdownEditorController: ObservableObject {
    #if os(macOS)
    weak var textView: NSTextView?
    var onDidChange: (() -> Void)?

    func attach(textView: NSTextView, onDidChange: @escaping () -> Void) {
        self.textView = textView
        self.onDidChange = onDidChange
    }

    func apply(_ command: RichMarkdownEditorCommand) {
        guard let textView else { return }
        switch command {
        case .bold:
            applyFontTrait(.boldFontMask, placeholder: "tekst", to: textView)
        case .italic:
            applyFontTrait(.italicFontMask, placeholder: "tekst", to: textView)
        case .code:
            applyCodeStyle(to: textView)
        case .bullet:
            prefixSelectedParagraphs(with: "• ", fallback: "punkt", in: textView)
        case .quote:
            prefixSelectedParagraphs(with: "▍ ", fallback: "sitat", in: textView)
        }
        onDidChange?()
    }

    private func applyFontTrait(_ trait: NSFontTraitMask, placeholder: String, to textView: NSTextView) {
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = toggledFont(
                from: (textView.typingAttributes[.font] as? NSFont) ?? RichMarkdownBridge.baseFont(),
                trait: trait
            )
            let attributes = RichMarkdownBridge.typingAttributes(
                baseFont: font,
                textColor: textView.textColor ?? .labelColor
            )
            let attributed = NSAttributedString(string: placeholder, attributes: attributes)
            replaceSelection(in: textView, with: attributed)
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let current = (value as? NSFont) ?? RichMarkdownBridge.baseFont()
            storage.addAttribute(.font, value: toggledFont(from: current, trait: trait), range: subrange)
        }
        storage.endEditing()
    }

    private func toggledFont(from font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let manager = NSFontManager.shared
        let traits = manager.traits(of: font)
        if traits.contains(trait) {
            return manager.convert(font, toNotHaveTrait: trait)
        }
        return manager.convert(font, toHaveTrait: trait)
    }

    private func applyCodeStyle(to textView: NSTextView) {
        let range = textView.selectedRange()
        let codeFont = NSFont.monospacedSystemFont(ofSize: RichMarkdownBridge.pointSize(from: textView.typingAttributes[.font] as? NSFont), weight: .regular)
        let codeAttributes = RichMarkdownBridge.codeAttributes(
            baseFont: codeFont,
            textColor: textView.textColor ?? .labelColor
        )

        if range.length == 0 {
            replaceSelection(in: textView, with: NSAttributedString(string: "kode", attributes: codeAttributes))
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttributes(codeAttributes, range: range)
        storage.endEditing()
    }

    private func prefixSelectedParagraphs(with prefix: String, fallback: String, in textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        if string.length == 0 {
            replaceSelection(in: textView, with: NSAttributedString(string: prefix + fallback, attributes: RichMarkdownBridge.typingAttributes(
                baseFont: (textView.typingAttributes[.font] as? NSFont) ?? RichMarkdownBridge.baseFont(),
                textColor: textView.textColor ?? .labelColor
            )))
            return
        }

        let paragraphRanges = paragraphRangesForSelection(in: string, selectedRange: selectedRange)
        storage.beginEditing()
        for paragraphRange in paragraphRanges.reversed() {
            storage.insert(
                NSAttributedString(
                    string: prefix,
                    attributes: RichMarkdownBridge.prefixAttributes(
                        prefix: prefix,
                        baseFont: RichMarkdownBridge.baseFont(),
                        textColor: textView.textColor ?? .labelColor
                    )
                ),
                at: paragraphRange.location
            )
        }
        storage.endEditing()

        if selectedRange.length == 0, let firstRange = paragraphRanges.first {
            textView.setSelectedRange(NSRange(location: firstRange.location + prefix.count, length: fallback.count))
        }
    }

    private func paragraphRangesForSelection(in string: NSString, selectedRange: NSRange) -> [NSRange] {
        let safeLocation = min(selectedRange.location, string.length)
        let safeLength = min(selectedRange.length, max(0, string.length - safeLocation))
        let effective = NSRange(location: safeLocation, length: safeLength)
        var ranges: [NSRange] = []
        var cursor = string.paragraphRange(for: effective)
        ranges.append(cursor)
        let selectionUpperBound = effective.location + effective.length

        while cursor.location + cursor.length < selectionUpperBound {
            let nextStart = cursor.location + cursor.length
            let next = string.paragraphRange(for: NSRange(location: nextStart, length: 0))
            if ranges.contains(where: { $0.location == next.location && $0.length == next.length }) {
                break
            }
            ranges.append(next)
            cursor = next
        }
        return ranges
    }

    private func replaceSelection(in textView: NSTextView, with attributed: NSAttributedString) {
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: attributed)
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
    }
    #else
    func apply(_ command: RichMarkdownEditorCommand) {}
    #endif
}

#if os(macOS)
private struct RichMarkdownTextEditor: NSViewRepresentable {
    @Binding var markdown: String
    let minHeight: CGFloat
    let maxHeight: CGFloat?
    let modifiers: SkeletonModifiers?
    @ObservedObject var controller: RichMarkdownEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesInspectorBar = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        controller.attach(textView: textView) {
            context.coordinator.syncMarkdownFromTextView()
        }
        updateTextView(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        controller.attach(textView: textView) {
            context.coordinator.syncMarkdownFromTextView()
        }
        updateTextView(textView, coordinator: context.coordinator)
    }

    private func updateTextView(_ textView: NSTextView, coordinator: Coordinator) {
        let font = RichMarkdownBridge.baseFont(from: modifiers)
        let color = RichMarkdownBridge.textColor(from: modifiers)
        textView.textColor = color
        textView.insertionPointColor = color
        textView.typingAttributes = RichMarkdownBridge.typingAttributes(baseFont: font, textColor: color)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: maxHeight ?? .greatestFiniteMagnitude)

        if coordinator.lastMarkdown == markdown {
            return
        }

        coordinator.isApplyingExternalUpdate = true
        textView.textStorage?.setAttributedString(
            RichMarkdownBridge.attributedString(from: markdown, baseFont: font, textColor: color)
        )
        coordinator.isApplyingExternalUpdate = false
        coordinator.lastMarkdown = markdown
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichMarkdownTextEditor
        var isApplyingExternalUpdate = false
        var lastMarkdown = ""

        init(_ parent: RichMarkdownTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            syncMarkdownFromTextView()
        }

        func syncMarkdownFromTextView() {
            guard !isApplyingExternalUpdate,
                  let textView = parent.controller.textView else { return }
            let nextMarkdown = RichMarkdownBridge.markdown(from: textView.attributedString())
            lastMarkdown = nextMarkdown
            if parent.markdown != nextMarkdown {
                parent.markdown = nextMarkdown
            }
        }
    }
}

private enum RichMarkdownBridge {
    static let codeAttribute = NSAttributedString.Key("RichMarkdownCode")

    static func attributedString(from markdown: String, baseFont: NSFont, textColor: NSColor) -> NSAttributedString {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let result = NSMutableAttributedString()
        let lines = normalized.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: typingAttributes(baseFont: baseFont, textColor: textColor)))
            }

            if rawLine.hasPrefix("- ") {
                result.append(NSAttributedString(string: "• ", attributes: prefixAttributes(prefix: "• ", baseFont: baseFont, textColor: textColor)))
                appendInlineMarkdown(String(rawLine.dropFirst(2)), to: result, baseFont: baseFont, textColor: textColor)
            } else if rawLine.hasPrefix("> ") {
                result.append(NSAttributedString(string: "▍ ", attributes: prefixAttributes(prefix: "▍ ", baseFont: baseFont, textColor: textColor)))
                appendInlineMarkdown(String(rawLine.dropFirst(2)), to: result, baseFont: baseFont, textColor: textColor)
            } else {
                appendInlineMarkdown(rawLine, to: result, baseFont: baseFont, textColor: textColor)
            }
        }

        return result
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        let lines = attributedString.string.components(separatedBy: "\n")
        var location = 0
        var rendered: [String] = []

        for line in lines {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: location, length: lineLength)
            location += lineLength + 1

            var prefix = ""
            var contentRange = lineRange
            if line.hasPrefix("• ") {
                prefix = "- "
                contentRange = NSRange(location: lineRange.location + 2, length: max(0, lineRange.length - 2))
            } else if line.hasPrefix("▍ ") {
                prefix = "> "
                contentRange = NSRange(location: lineRange.location + 2, length: max(0, lineRange.length - 2))
            }

            let lineMarkdown = inlineMarkdown(from: attributedString, range: contentRange)
            rendered.append(prefix + lineMarkdown)
        }

        return rendered.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inlineMarkdown(from attributedString: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let output = NSMutableString()
        attributedString.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let raw = attributedString.attributedSubstring(from: subrange).string
            guard raw.isEmpty == false else { return }
            let escaped = escapeMarkdown(raw)

            if attributes[codeAttribute] as? Bool == true {
                output.append("`\(escaped.replacingOccurrences(of: "`", with: "\\`"))`")
                return
            }

            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isItalic = traits.contains(.italicFontMask)

            switch (isBold, isItalic) {
            case (true, true):
                output.append("***\(escaped)***")
            case (true, false):
                output.append("**\(escaped)**")
            case (false, true):
                output.append("*\(escaped)*")
            default:
                output.append(escaped)
            }
        }
        return output as String
    }

    static func appendInlineMarkdown(_ markdown: String, to output: NSMutableAttributedString, baseFont: NSFont, textColor: NSColor) {
        var index = markdown.startIndex
        var buffer = ""

        func flushBuffer() {
            guard buffer.isEmpty == false else { return }
            output.append(NSAttributedString(string: buffer, attributes: typingAttributes(baseFont: baseFont, textColor: textColor)))
            buffer = ""
        }

        while index < markdown.endIndex {
            if markdown[index...].hasPrefix("**"),
               let close = markdown[index...].dropFirst(2).range(of: "**") {
                flushBuffer()
                let content = String(markdown[markdown.index(index, offsetBy: 2)..<close.lowerBound])
                output.append(NSAttributedString(string: content, attributes: boldAttributes(baseFont: baseFont, textColor: textColor)))
                index = close.upperBound
                continue
            }

            if markdown[index] == "*",
               let close = markdown[markdown.index(after: index)...].firstIndex(of: "*") {
                flushBuffer()
                let content = String(markdown[markdown.index(after: index)..<close])
                output.append(NSAttributedString(string: content, attributes: italicAttributes(baseFont: baseFont, textColor: textColor)))
                index = markdown.index(after: close)
                continue
            }

            if markdown[index] == "`",
               let close = markdown[markdown.index(after: index)...].firstIndex(of: "`") {
                flushBuffer()
                let content = String(markdown[markdown.index(after: index)..<close])
                output.append(NSAttributedString(string: content, attributes: codeAttributes(baseFont: baseFont, textColor: textColor)))
                index = markdown.index(after: close)
                continue
            }

            buffer.append(markdown[index])
            index = markdown.index(after: index)
        }

        flushBuffer()
    }

    static func baseFont(from modifiers: SkeletonModifiers? = nil) -> NSFont {
        if let fontSize = modifiers?.fontSize, fontSize > 0 {
            return NSFont.systemFont(ofSize: CGFloat(fontSize), weight: nsWeight(from: modifiers?.fontWeight))
        }

        let size: CGFloat
        switch modifiers?.fontStyle ?? "body" {
        case "largeTitle": size = 28
        case "title": size = 24
        case "title2": size = 20
        case "title3": size = 18
        case "headline": size = 15
        case "subheadline": size = 13
        case "callout": size = 14
        case "footnote": size = 12
        case "caption", "caption2": size = 11
        default: size = 14
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight(from: modifiers?.fontWeight))
    }

    static func pointSize(from font: NSFont?) -> CGFloat {
        font?.pointSize ?? baseFont().pointSize
    }

    static func textColor(from modifiers: SkeletonModifiers?) -> NSColor {
        guard let hex = modifiers?.foregroundColor,
              let color = nsColor(hex: hex) else {
            return .labelColor
        }
        return color
    }

    static func typingAttributes(baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: textColor
        ]
    }

    static func boldAttributes(baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes = typingAttributes(baseFont: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask), textColor: textColor)
        attributes.removeValue(forKey: codeAttribute)
        return attributes
    }

    static func italicAttributes(baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes = typingAttributes(baseFont: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask), textColor: textColor)
        attributes.removeValue(forKey: codeAttribute)
        return attributes
    }

    static func codeAttributes(baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
            .foregroundColor: textColor,
            .backgroundColor: NSColor.controlBackgroundColor,
            codeAttribute: true
        ]
    }

    static func prefixAttributes(prefix: String, baseFont: NSFont, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        let accent = prefix == "▍ " ? textColor.withAlphaComponent(0.7) : textColor
        return [
            .font: baseFont,
            .foregroundColor: accent
        ]
    }

    static func escapeMarkdown(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    static func nsWeight(from weight: String?) -> NSFont.Weight {
        switch weight ?? "" {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    static func nsColor(hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        var rgba: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&rgba) else { return nil }
        switch value.count {
        case 6:
            return NSColor(
                red: CGFloat((rgba & 0xFF0000) >> 16) / 255.0,
                green: CGFloat((rgba & 0x00FF00) >> 8) / 255.0,
                blue: CGFloat(rgba & 0x0000FF) / 255.0,
                alpha: 1.0
            )
        case 8:
            return NSColor(
                red: CGFloat((rgba & 0xFF000000) >> 24) / 255.0,
                green: CGFloat((rgba & 0x00FF0000) >> 16) / 255.0,
                blue: CGFloat((rgba & 0x0000FF00) >> 8) / 255.0,
                alpha: CGFloat(rgba & 0x000000FF) / 255.0
            )
        default:
            return nil
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
