// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
#if canImport(PhotosUI) && os(iOS)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if os(iOS) || os(macOS)

/// The native `richDocument` visualization: the same document, rules and
/// commands as the web editor (CellScaffold `haven-rich-document.js`).
/// Layout follows the approved G1-GUI images in CellProtocolDocuments
/// `Deliverables/PDD_native-dokumenteditor_2026-11-20/images/`.
public struct RichDocumentEditorView: View {
    @StateObject private var model: RichDocumentEditorModel
    @State private var commentDraft = ""
    @State private var showComments = false
    @State private var showLinkPrompt = false
    @State private var linkDraft = ""
    @State private var showChartForm = false
    @State private var chartTitle = ""
    @State private var chartType = "bar"
    @State private var chartData = ""
    @State private var showImageImporter = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    #if os(iOS)
    @State private var photoItem: PhotosPickerItem?
    #endif

    public init(model: @autoclosure @escaping () -> RichDocumentEditorModel) {
        _model = StateObject(wrappedValue: model())
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macToolbar
            Divider()
            offlineBanner
            HStack(spacing: 0) {
                RichDocumentTextView(model: model)
                    .frame(minHeight: 420)
                    .background(Color(nsColor: .textBackgroundColor))
                Divider()
                commentsPanel.frame(width: 300)
            }
            Divider()
            statusLine.padding(.horizontal, 14).padding(.vertical, 6)
            #else
            HStack { statusLine; Spacer(); peerAvatars }.padding(.horizontal, 16).padding(.vertical, 6)
            offlineBanner
            RichDocumentTextView(model: model)
                .frame(minHeight: 360)
            if !model.isReadOnly { iosFormatBar }
            #endif
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .sheet(isPresented: $showComments) { NavigationStack { commentsPanel.navigationTitle("Kommentarer").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Ferdig") { showComments = false } } } } }
        .sheet(isPresented: $showChartForm) { chartForm }
        .alert("Lenke", isPresented: $showLinkPrompt) {
            TextField("https://", text: $linkDraft)
            Button("Bruk") { model.setLink(linkDraft) }
            Button("Fjern lenke", role: .destructive) { model.setLink(nil) }
            Button("Avbryt", role: .cancel) {}
        } message: { Text("Lenker må begynne med https://, http:// eller mailto:.") }
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.png, .jpeg]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { model.insertImage(data: data) }
            }
        }
        #if os(iOS)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { model.insertImage(data: data) }; photoItem = nil }
        }
        #endif
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            #if os(macOS)
            Spacer()
            Text("\(model.wordCount) ord").font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let base = model.status.text
        let names = model.peerNames
        guard model.status == .saved, !names.isEmpty else { return model.isReadOnly && model.status != .denied ? "Bare lesetilgang" : base }
        let joined = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " og " + names.last!
        return "Alle endringer er lagret · \(joined) er her"
    }

    private var statusColor: Color {
        switch model.status {
        case .saved: return .green
        case .saving, .opening: return .gray
        case .offline, .waitingForSafeStorage: return .orange
        default: return .red
        }
    }

    @ViewBuilder private var offlineBanner: some View {
        if case .offline(let pending) = model.status {
            Text("**Frakoblet.** \(pending == 1 ? "1 endring er" : "\(pending) endringer er") lagret på denne enheten og sendes når du er på nett igjen. Du kan skrive videre.")
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.45)))
                .padding(.horizontal, 14).padding(.vertical, 8)
        } else if model.status == .historyGap || model.status == .denied {
            Text(model.status.text).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08)).padding(.horizontal, 14).padding(.vertical, 8)
        } else if case .rejected = model.status {
            Text(model.status.text).font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08)).padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var peerAvatars: some View {
        HStack(spacing: -5) {
            ForEach(Array(model.peerNames.prefix(4).enumerated()), id: \.offset) { offset, name in
                Text(String(name.prefix(1)).uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(RichDocumentLayoutManager.peerColors[offset % RichDocumentLayoutManager.peerColors.count])))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .accessibilityLabel(name)
            }
        }
    }

    // MARK: Toolbars

    private func formatButton(_ format: RichDocumentEditorModel.InlineFormat) -> some View {
        let label: Text
        switch format {
        case .bold: label = Text("B").bold()
        case .italic: label = Text("I").italic()
        case .underline: label = Text("U").underline()
        case .strike: label = Text("S").strikethrough()
        }
        let names: [RichDocumentEditorModel.InlineFormat: String] = [.bold: "Fet", .italic: "Kursiv", .underline: "Understreket", .strike: "Gjennomstreket"]
        return Button { model.toggle(format) } label: {
            label.frame(minWidth: 30, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.isActive(format) ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(names[format] ?? format.rawValue)
        .accessibilityAddTraits(model.isActive(format) ? .isSelected : [])
    }

    private func lineButton(_ title: String, _ format: RichDocumentEditorModel.LineFormat, accessibility: String) -> some View {
        Button { model.setLineFormat(format) } label: {
            Text(title).frame(minWidth: 30, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.currentLineFormat == format ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var styleMenu: some View {
        Menu {
            Button("Brødtekst") { model.setLineFormat(.body) }
            Button("Overskrift 1") { model.setLineFormat(.header(1)) }
            Button("Overskrift 2") { model.setLineFormat(.header(2)) }
            Button("Overskrift 3") { model.setLineFormat(.header(3)) }
        } label: {
            #if os(macOS)
            Text(styleLabel)
            #else
            Text("Aa").frame(minWidth: 30, minHeight: 30)
            #endif
        }
        .accessibilityLabel("Tekststil")
    }

    private var styleLabel: String {
        if case .header(let level) = model.currentLineFormat { return "Overskrift \(level)" }
        return "Brødtekst"
    }

    #if os(macOS)
    private var macToolbar: some View {
        HStack(spacing: 2) {
            styleMenu.fixedSize().padding(.trailing, 8)
            ForEach(RichDocumentEditorModel.InlineFormat.allCases, id: \.self) { formatButton($0) }
            Divider().frame(height: 22).padding(.horizontal, 4)
            lineButton("•≡", .bulletList, accessibility: "Punktliste")
            lineButton("1≡", .orderedList, accessibility: "Nummerert liste")
            lineButton("❝", .blockquote, accessibility: "Sitat")
            Button { linkDraft = ""; showLinkPrompt = true } label: { Image(systemName: "link").frame(minWidth: 30, minHeight: 30) }
                .buttonStyle(.plain).accessibilityLabel("Lenke")
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button("Kommenter") { commentFocus() }.disabled(model.selection.length == 0)
            Button("Sett inn bilde") { showImageImporter = true }
            Button("Sett inn diagram") { showChartForm = true }
            Spacer()
            exportMenu
        }
        .disabled(model.isReadOnly && false)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
    #endif

    #if os(iOS)
    private var iosFormatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                styleMenu
                ForEach(RichDocumentEditorModel.InlineFormat.allCases, id: \.self) { formatButton($0) }
                Divider().frame(height: 22).padding(.horizontal, 2)
                lineButton("•≡", .bulletList, accessibility: "Punktliste")
                lineButton("1≡", .orderedList, accessibility: "Nummerert liste")
                lineButton("❝", .blockquote, accessibility: "Sitat")
                Button { linkDraft = ""; showLinkPrompt = true } label: { Image(systemName: "link").frame(minWidth: 30, minHeight: 30) }
                    .accessibilityLabel("Lenke")
                Divider().frame(height: 22).padding(.horizontal, 2)
                Button { showComments = true } label: { Image(systemName: "text.bubble").frame(minWidth: 30, minHeight: 30) }
                    .accessibilityLabel("Kommentarer")
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Bilde fra Bilder", systemImage: "photo") }
                    Button { showImageImporter = true } label: { Label("Bilde fra Filer", systemImage: "folder") }
                    Button { showChartForm = true } label: { Label("Diagram", systemImage: "chart.bar") }
                    Divider()
                    exportItems
                } label: { Image(systemName: "plus").frame(minWidth: 30, minHeight: 30) }
                .accessibilityLabel("Sett inn og eksporter")
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
    #endif

    // MARK: Export

    private var exportMenu: some View {
        Menu("Del / eksporter") { exportItems }
            .fixedSize()
    }

    @ViewBuilder private var exportItems: some View {
        ForEach(RichDocumentExport.Format.available) { format in
            Button(format.label) { export(format) }
        }
    }

    private func export(_ format: RichDocumentExport.Format) {
        do {
            let url = try RichDocumentExport.file(format, document: model.shown)
            exportURL = url
            #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url.lastPathComponent
            if panel.runModal() == .OK, let target = panel.url {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
                model.notice = "Filen er lagret."
            }
            #else
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first?
                .topmostPresented.present(controller, animated: true)
            #endif
        } catch {
            model.notice = "Eksporten mislyktes."
        }
    }

    // MARK: Comments

    private func commentFocus() { showComments = true }

    private var commentsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                Text("Kommentarer").font(.headline)
                #endif
                if model.selection.length > 0 {
                    let selected = (model.shown.plainText as NSString)
                    let range = NSIntersectionRange(model.selection, NSRange(location: 0, length: selected.length))
                    Text("Markert: «\(selected.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").prefix(80))»")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.isReadOnly {
                    TextEditor(text: $commentDraft)
                        .frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                        .overlay(alignment: .topLeading) {
                            if commentDraft.isEmpty { Text("Kommentar til markert tekst").foregroundStyle(.secondary).padding(8).allowsHitTesting(false) }
                        }
                        .accessibilityLabel("Kommentar til markert tekst")
                    Button("Legg til kommentar") {
                        Task { if await model.addComment(commentDraft) { commentDraft = "" } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.16, green: 0.47, blue: 0.29))
                    .disabled(model.selection.length == 0 || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.allComments.isEmpty {
                    Text("Marker tekst for å legge til en kommentar.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.allComments, id: \.id) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.displayName(comment.author) + (comment.resolved == true ? " · løst" : comment.detached == true ? " · teksten er slettet" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        let quote = model.quote(for: comment)
                        if !quote.isEmpty {
                            Text("«\(quote)»").font(.caption).padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.15)))
                        }
                        Text(comment.text).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if comment.detached != true { Button("Vis i teksten") { model.show(comment); showComments = false }.buttonStyle(.bordered) }
                            if comment.resolved != true, !model.isReadOnly { Button("Løs") { Task { await model.resolveComment(comment.id) } }.buttonStyle(.bordered) }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                }
                #if os(macOS)
                Divider()
                Text("Skrivehjelp og Dokumentchat ligger under dokumentet.").font(.footnote).foregroundStyle(.secondary)
                #endif
            }
            .padding(14)
        }
    }

    // MARK: Chart form

    private var chartForm: some View {
        NavigationStack {
            Form {
                TextField("Tittel", text: $chartTitle)
                Picker("Diagramtype", selection: $chartType) {
                    Text("Søyler").tag("bar")
                    Text("Linje").tag("line")
                }
                Section("Data, én linje per verdi: «Januar: 10»") {
                    TextEditor(text: $chartData).frame(minHeight: 120).accessibilityLabel("Diagramdata")
                }
            }
            .navigationTitle("Sett inn diagram")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { showChartForm = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sett inn") {
                        if model.insertChart(title: chartTitle, type: chartType, data: chartData) {
                            showChartForm = false; chartTitle = ""; chartData = ""
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

#if os(iOS)
private extension UIViewController {
    var topmostPresented: UIViewController { presentedViewController?.topmostPresented ?? self }
}
#endif

/// The two legacy kinds from layouts saved before writing help and chat became
/// plain skeleton elements: a list and a field on the same document.
public struct RichDocumentConversationView: View {
    @StateObject private var model: RichDocumentEditorModel
    let help: Bool
    @State private var draft = ""

    public init(model: @autoclosure @escaping () -> RichDocumentEditorModel, help: Bool) {
        _model = StateObject(wrappedValue: model())
        self.help = help
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(help ? "Skrivehjelp" : "Dokumentchat").font(.headline)
            if help {
                Text(model.snapshot?.onboarding ?? "Jeg kan hjelpe med formatering, bilder, diagrammer, kommentarer, samarbeid og eksport.")
                    .font(.callout)
                ForEach(model.snapshot?.help ?? [], id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Du: \(entry.question)").font(.callout.weight(.semibold))
                        Text(entry.answer).font(.callout)
                    }
                }
            } else {
                ForEach(model.snapshot?.messages ?? [], id: \.id) { message in
                    (Text(model.displayName(message.author) + ": ").bold() + Text(message.text)).font(.callout)
                }
            }
            TextEditor(text: $draft)
                .frame(minHeight: 56)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(help ? "Spør skrivehjelpen" : "Chatmelding")
            Button(help ? "Spør" : "Send melding") {
                let text = draft
                Task { if await model.postChat(text, help: help), draft == text { draft = "" } }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isReadOnly)
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(12)
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

#endif
