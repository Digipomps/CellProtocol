// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if canImport(Combine)
import Combine
#endif

#if os(iOS) || os(macOS)

/// Reaches the document cell with closures, so the host decides how keypaths
/// resolve (Porthole reference, bridge, or a test double).
public struct RichDocumentClosureTransport: RichDocumentTransport {
    let readCurrent: @Sendable () async throws -> ValueType?
    let sendChange: @Sendable (ValueType) async throws -> ValueType?
    public init(current: @escaping @Sendable () async throws -> ValueType?, send: @escaping @Sendable (ValueType) async throws -> ValueType?) {
        self.readCurrent = current; self.sendChange = send
    }
    public func current() async throws -> ValueType? { try await readCurrent() }
    public func send(_ command: ValueType) async throws -> ValueType? { try await sendChange(command) }
}

/// What the editor view needs from a text view, so the model stays testable.
@MainActor
public protocol RichDocumentTextSurface: AnyObject {
    var richTextStorage: NSMutableAttributedString { get }
    var richSelection: NSRange { get set }
    /// True while the input method composes (marked text); remote changes wait.
    var isComposing: Bool { get }
    func richTextDidChangeProgrammatically()
}

public struct RichDocumentPeerCaret: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var location: Int
    public var colorIndex: Int
}

@MainActor
public final class RichDocumentEditorModel: ObservableObject {
    @Published public private(set) var status: RichDocumentStatus = .opening
    @Published public private(set) var snapshot: RichDocumentSnapshot?
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var wordCount = 0
    @Published public private(set) var peerCarets: [RichDocumentPeerCaret] = []
    @Published public var selection = NSRange(location: 0, length: 0)
    @Published public var notice: String?
    @Published public private(set) var revisionShown = 0

    public let session: RichDocumentSession
    public let style: RichDocumentTextCodec.Style
    public weak var surface: RichDocumentTextSurface? {
        didSet { if surface != nil, snapshot != nil { replaceSurfaceText(with: shown) } }
    }
    /// Names for identities, when the host knows them (otherwise the first 8 characters).
    public var displayName: (String) -> String = { String($0.prefix(8)) }

    /// The document exactly as the text view shows it.
    public private(set) var shown = RichTextDelta([.insert("\n")])
    private var deferredRemote: [RichTextDelta] = []
    private var applyingProgrammatic = false
    private var presenceTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var flowCancellable: AnyCancellable?
    private var lastFlowRefresh = Date.distantPast
    private var started = false
    /// Characters typed next take these inline formats (toolbar toggles with no selection).
    public private(set) var typingAttributes: RichTextAttributes = [:]

    public init(session: RichDocumentSession, style: RichDocumentTextCodec.Style = .standard) {
        self.session = session
        self.style = style
        session.setListener { [weak self] update in self?.handle(update) }
    }

    deinit {
        presenceTask?.cancel(); heartbeatTask?.cancel(); refreshTask?.cancel()
    }

    // MARK: Lifecycle

    /// Opens the document, then keeps it current: on each `document.change`
    /// Flow the host forwards, and by reading `current` every `pollInterval`
    /// seconds while the editor is on screen and idle.
    public func start(flow: AnyPublisher<FlowElement, Error>? = nil, pollInterval: Double = 2) {
        guard !started else { return }
        started = true
        if let flow {
            flowCancellable = flow.sink(receiveCompletion: { _ in }, receiveValue: { [weak self] element in
                guard element.topic == "document.change" || element.title.hasPrefix("document.") else { return }
                Task { @MainActor [weak self] in self?.lastFlowRefresh = Date(); await self?.session.refresh() }
            })
        }
        refreshTask = Task { [weak self] in
            await self?.session.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.session.pendingCount == 0 { await self.session.refresh() }
            }
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.session.pendingCount == 0, !self.isReadOnly {
                    _ = await self.session.sendMeta(kind: "presence", range: RichDocumentRange(index: self.selection.location, length: self.selection.length))
                }
            }
        }
    }

    public func stop() {
        refreshTask?.cancel(); heartbeatTask?.cancel(); presenceTask?.cancel(); flowCancellable = nil
        started = false
    }

    // MARK: Session updates

    private func handle(_ update: RichDocumentSessionUpdate) {
        switch update {
        case .reset(let document, let snapshot):
            shown = document
            self.snapshot = snapshot
            deferredRemote.removeAll()
            replaceSurfaceText(with: document)
            refreshDerived()
        case .remote(let change, let snapshot):
            self.snapshot = snapshot
            if surface?.isComposing == true { deferredRemote.append(change); return }
            applyRemote(change)
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            revisionShown = snapshot.revision
            refreshDerived()
        case .status(let status):
            self.status = status
            if status == .denied { isReadOnly = true }
        }
    }

    private func replaceSurfaceText(with document: RichTextDelta) {
        guard let surface else { return }
        applyingProgrammatic = true
        let text = RichDocumentTextCodec.attributedString(from: document, style: style, embedImage: RichDocumentTextCodec.decodeImage)
        surface.richTextStorage.setAttributedString(text)
        let length = surface.richTextStorage.length
        surface.richSelection = NSRange(location: min(selection.location, max(0, length - 1)), length: 0)
        applyingProgrammatic = false
        surface.richTextDidChangeProgrammatically()
    }

    private func applyRemote(_ change: RichTextDelta) {
        shown = shown.compose(change)
        guard let surface else { return }
        let before = surface.richSelection
        applyingProgrammatic = true
        RichDocumentTextCodec.apply(change, to: surface.richTextStorage, style: style, embedImage: RichDocumentTextCodec.decodeImage)
        let start = change.transformPosition(before.location, priority: false)
        let end = change.transformPosition(NSMaxRange(before), priority: true)
        let length = surface.richTextStorage.length
        surface.richSelection = NSRange(location: min(start, max(0, length - 1)), length: max(0, min(end, length) - min(start, length)))
        applyingProgrammatic = false
        // Safety net: if the text and the delta ever disagree, show the delta.
        if RichDocumentTextCodec.document(from: surface.richTextStorage).units != shown.units {
            replaceSurfaceText(with: shown)
        }
        surface.richTextDidChangeProgrammatically()
        refreshDerived()
    }

    /// Called when marked text (input method) is committed.
    public func compositionEnded() {
        let pending = deferredRemote
        deferredRemote.removeAll()
        for change in pending { applyRemote(change) }
    }

    // MARK: Local edits

    /// Called by the text view after the user changed the text. `editLocation`
    /// is where the change started, so repeated letters go where typed.
    public func textDidChange(editLocation: Int?) {
        guard !applyingProgrammatic, let surface, !isReadOnly else { return }
        ensureTrailingNewline(surface)
        let current = RichDocumentTextCodec.document(from: surface.richTextStorage)
        let change = RichTextDelta.diff(from: shown, to: current, cursor: editLocation)
        shown = current
        guard !change.ops.isEmpty else { return }
        session.localEdit(change)
        refreshDerived()
    }

    private func ensureTrailingNewline(_ surface: RichDocumentTextSurface) {
        let storage = surface.richTextStorage
        if storage.length == 0 || (storage.string as NSString).character(at: storage.length - 1) != 10 {
            applyingProgrammatic = true
            let selection = surface.richSelection
            storage.append(NSAttributedString(string: "\n", attributes: RichDocumentTextCodec.characterAttributes([:], style: style)))
            surface.richSelection = selection
            applyingProgrammatic = false
        }
    }

    /// Attributes for text the user is about to type at `location`: the inline
    /// formats of the character before, overridden by toolbar toggles.
    public func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        var quill: RichTextAttributes = [:]
        if let storage = surface?.richTextStorage, location > 0, location <= storage.length {
            let previous = (storage.attribute(.havenRichText, at: location - 1, effectiveRange: nil) as? RichTextAttributesBox)?.attributes ?? [:]
            if (storage.string as NSString).character(at: location - 1) != 10 {
                quill = previous.filter { RichDocumentTextCodec.inlineKeys.contains($0.key) && $0.key != "link" }
            }
        }
        for (key, value) in typingAttributes { if value == .null { quill.removeValue(forKey: key) } else { quill[key] = value } }
        return RichDocumentTextCodec.characterAttributes(quill, style: style)
    }

    /// After the user inserted "\n" inside a formatted line, the new line keeps
    /// the list or quote it was split from, as in Quill.
    public func continueLineFormat(afterInsertingNewlineAt location: Int) {
        guard let surface else { return }
        let storage = surface.richTextStorage
        guard location < storage.length, (storage.string as NSString).character(at: location) == 10 else { return }
        let next = RichDocumentTextCodec.lineAttributes(in: storage, paragraphContaining: min(location + 1, storage.length - 1))
        let carried = next.filter { $0.key != "header" }
        guard !carried.isEmpty else { return }
        applyingProgrammatic = true
        RichDocumentTextCodec.applyAttributeChange(carried, to: storage, range: NSRange(location: location, length: 1), style: style)
        RichDocumentTextCodec.restyleParagraphs(in: storage, range: NSRange(location: location, length: 1), style: style)
        applyingProgrammatic = false
    }

    // MARK: Toolbar

    public enum InlineFormat: String, CaseIterable { case bold, italic, underline, strike }
    public enum LineFormat: Equatable { case body, header(Int), bulletList, orderedList, blockquote }

    public func isActive(_ format: InlineFormat) -> Bool {
        guard let storage = surface?.richTextStorage, storage.length > 0 else { return typingAttributes[format.rawValue] == .bool(true) }
        if selection.length == 0 {
            if let toggled = typingAttributes[format.rawValue] { return toggled == .bool(true) }
            let location = max(0, selection.location - 1)
            return ((storage.attribute(.havenRichText, at: min(location, storage.length - 1), effectiveRange: nil) as? RichTextAttributesBox)?.attributes[format.rawValue]) == .bool(true)
        }
        var all = true
        storage.enumerateAttribute(.havenRichText, in: NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))) { value, run, stop in
            if (storage.string as NSString).substring(with: run) == "\n" { return }
            if (value as? RichTextAttributesBox)?.attributes[format.rawValue] != .bool(true) { all = false; stop.pointee = true }
        }
        return all
    }

    public func toggle(_ format: InlineFormat) {
        guard !isReadOnly else { return }
        let on = !isActive(format)
        if selection.length == 0 {
            typingAttributes[format.rawValue] = on ? .bool(true) : .null
            objectWillChange.send()
            return
        }
        applyFormat([format.rawValue: on ? .bool(true) : .null], range: selection)
    }

    public var currentLineFormat: LineFormat {
        guard let storage = surface?.richTextStorage, storage.length > 0 else { return .body }
        let line = RichDocumentTextCodec.lineAttributes(in: storage, paragraphContaining: selection.location)
        if case .int(let level)? = line["header"] { return .header(level) }
        if line["list"] == .string("bullet") { return .bulletList }
        if line["list"] == .string("ordered") { return .orderedList }
        if line["blockquote"] == .bool(true) { return .blockquote }
        return .body
    }

    public func setLineFormat(_ format: LineFormat) {
        guard !isReadOnly, let storage = surface?.richTextStorage, storage.length > 0 else { return }
        let toggleOff = format == currentLineFormat && format != .body
        var change: RichTextAttributes = ["header": .null, "list": .null, "blockquote": .null]
        if !toggleOff {
            switch format {
            case .body: break
            case .header(let level): change["header"] = .int(level)
            case .bulletList: change["list"] = .string("bullet")
            case .orderedList: change["list"] = .string("ordered")
            case .blockquote: change["blockquote"] = .bool(true)
            }
        }
        let paragraphs = (storage.string as NSString).paragraphRange(for: NSIntersectionRange(selection, NSRange(location: 0, length: storage.length)))
        applyFormat(change, range: paragraphs)
    }

    /// Sets a link on the selection. Only http, https and mailto, which the cell accepts.
    @discardableResult
    public func setLink(_ text: String?) -> Bool {
        guard !isReadOnly, selection.length > 0 else { notice = "Marker teksten som skal bli en lenke."; return false }
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            applyFormat(["link": .null], range: selection); return true
        }
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains(":") { candidate = candidate.contains("@") ? "mailto:\(candidate)" : "https://\(candidate)" }
        guard candidate.count <= 2048, let url = URL(string: candidate),
              RichDocumentTextCodec.allowedLinkSchemes.contains(url.scheme?.lowercased() ?? "") else {
            notice = "Lenken må begynne med https://, http:// eller mailto:."
            return false
        }
        applyFormat(["link": .string(candidate)], range: selection)
        return true
    }

    private func applyFormat(_ change: RichTextAttributes, range: NSRange) {
        guard let surface else { return }
        let storage = surface.richTextStorage
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        let keep = surface.richSelection
        applyingProgrammatic = true
        RichDocumentTextCodec.applyAttributeChange(change, to: storage, range: clamped, style: style)
        RichDocumentTextCodec.restyleParagraphs(in: storage, range: clamped, style: style)
        surface.richSelection = keep
        applyingProgrammatic = false
        surface.richTextDidChangeProgrammatically()
        textDidChange(editLocation: clamped.location)
    }

    // MARK: Embeds

    /// Inserts a PNG or JPEG (at most 2 MB, as on the web) at the cursor.
    public func insertImage(data: Data) {
        guard !isReadOnly else { return }
        let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = data.starts(with: [255, 216, 255])
        guard png || jpeg, data.count <= 2_000_000 else { notice = "Velg PNG eller JPEG på høyst 2 MB."; return }
        let uri = "data:image/\(png ? "png" : "jpeg");base64," + data.base64EncodedString()
        insertEmbed(["image": .string(uri)])
    }

    /// Inserts a chart from "Etikett: tall" lines, the same shape as the web form.
    @discardableResult
    public func insertChart(title: String, type: String, data: String) -> Bool {
        var rows: [RichTextValue] = []
        for (index, line) in data.split(separator: "\n").map(String.init).enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let split = line.lastIndex(of: ":") else { notice = "Skriv en etikett og et tall på hver linje, adskilt med kolon."; return false }
            let label = line[..<split].trimmingCharacters(in: .whitespaces)
            let number = Double(line[line.index(after: split)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            guard !label.isEmpty, let number, number.isFinite, type != "bar" || number >= 0 else {
                notice = "Skriv en etikett og et tall på hver linje, adskilt med kolon."; return false
            }
            let value: RichTextValue = number == number.rounded() && abs(number) < 1e15 ? .int(Int(number)) : .double(number)
            rows.append(.object(["id": .string(String(index)), "label": .string(label), "value": value]))
        }
        guard !rows.isEmpty, rows.count <= 100 else { notice = "Skriv en etikett og et tall på hver linje, adskilt med kolon."; return false }
        insertEmbed(["visualization": .object(["kind": .string("chart"), "spec": .object(["title": .string(title), "chartType": .string(type), "rows": .array(rows)])])])
        return true
    }

    private func insertEmbed(_ embed: [String: RichTextValue]) {
        guard let surface else { return }
        let storage = surface.richTextStorage
        let location = min(selection.location, max(0, storage.length - 1))
        applyingProgrammatic = true
        storage.insert(RichDocumentTextCodec.embedString(embed, attributes: [:], style: style, image: RichDocumentTextCodec.decodeImage(embed)), at: location)
        surface.richSelection = NSRange(location: location + 1, length: 0)
        applyingProgrammatic = false
        surface.richTextDidChangeProgrammatically()
        textDidChange(editLocation: location)
    }

    // MARK: Comments and presence

    public var openComments: [RichDocumentSnapshot.Comment] { (snapshot?.comments ?? []).filter { $0.resolved != true } }
    public var allComments: [RichDocumentSnapshot.Comment] { snapshot?.comments ?? [] }

    public func selectionChanged(_ range: NSRange) {
        selection = range
        typingAttributes = [:]
        presenceTask?.cancel()
        guard !isReadOnly else { return }
        presenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, self.session.pendingCount == 0 else { return }
            _ = await self.session.sendMeta(kind: "presence", range: RichDocumentRange(index: range.location, length: range.length))
        }
    }

    @discardableResult
    public func addComment(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection.length > 0 else { notice = "Marker teksten kommentaren gjelder først."; return false }
        guard !trimmed.isEmpty else { return false }
        return await meta("comment.add", range: RichDocumentRange(index: selection.location, length: selection.length), text: String(trimmed.prefix(4000)))
    }

    @discardableResult
    public func resolveComment(_ id: String) async -> Bool { await meta("comment.resolve", commentId: id) }

    @discardableResult
    public func postChat(_ text: String, help: Bool) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await meta(help ? "help.ask" : "chat.post", text: String(trimmed.prefix(4000)))
    }

    private func meta(_ kind: String, range: RichDocumentRange? = nil, text: String? = nil, commentId: String? = nil) async -> Bool {
        switch await session.sendMeta(kind: kind, range: range, text: text, commentId: commentId) {
        case .accepted: notice = nil; return true
        case .waitForText: notice = "Vent til tekstendringene er lagret, og prøv igjen."; return false
        case .failed(let message): notice = message; return false
        }
    }

    public func show(_ comment: RichDocumentSnapshot.Comment) {
        guard let surface, comment.detached != true else { return }
        let length = surface.richTextStorage.length
        let start = min(comment.range.index, max(0, length - 1))
        surface.richSelection = NSRange(location: start, length: min(comment.range.length, length - start))
        selection = surface.richSelection
    }

    /// The quoted text a comment points at, as it reads now.
    public func quote(for comment: RichDocumentSnapshot.Comment) -> String {
        let text = shown.plainText as NSString
        guard comment.detached != true, comment.range.index + comment.range.length <= text.length else { return "" }
        return text.substring(with: NSRange(location: comment.range.index, length: comment.range.length)).replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private func refreshDerived() {
        let text = shown.plainText
        wordCount = text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).count
        let now = Date().timeIntervalSince1970
        var carets: [RichDocumentPeerCaret] = []
        for (offset, peer) in (snapshot?.presence ?? []).enumerated() where peer.clientId != session.clientId {
            guard let range = peer.range, now - (peer.updatedAt ?? now) < 90 else { continue }
            carets.append(RichDocumentPeerCaret(id: peer.clientId, name: displayName(peer.author), location: range.index + range.length, colorIndex: offset))
        }
        peerCarets = carets
    }

    /// Names of the other people with the document open now.
    public var peerNames: [String] {
        var seen: [String] = []
        for caret in peerCarets where !seen.contains(caret.name) { seen.append(caret.name) }
        return seen
    }
}

#endif
