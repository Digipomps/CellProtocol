// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import SwiftUI
import CellBase
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(iOS) || os(macOS)

/// TextKit 1 layout manager that draws what Quill draws with CSS: list
/// markers in the margin, the blockquote bar, comment highlights and other
/// writers' carets with their names. None of these are characters, so the
/// text, and therefore the delta, stays exactly the document.
final class RichDocumentLayoutManager: NSLayoutManager {
    var commentRanges: [NSRange] = []
    var peerCarets: [RichDocumentPeerCaret] = []
    var markerColor = RichDocumentColor.gray
    static let peerColors: [RichDocumentColor] = [
        RichDocumentColor(red: 0.48, green: 0.30, blue: 0.76, alpha: 1),
        RichDocumentColor(red: 0.76, green: 0.40, blue: 0.30, alpha: 1),
        RichDocumentColor(red: 0.16, green: 0.47, blue: 0.29, alpha: 1),
        RichDocumentColor(red: 0.10, green: 0.42, blue: 0.75, alpha: 1)
    ]

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        #if os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #endif
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Comment highlights.
        context.setFillColor(RichDocumentColor(red: 1, green: 0.95, blue: 0.72, alpha: 1).cgColor)
        for range in commentRanges {
            let visible = NSIntersectionRange(range, characters)
            guard visible.length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }

        // List markers and blockquote bars, once per paragraph.
        let string = storage.string as NSString
        var location = string.paragraphRange(for: NSRange(location: characters.location, length: 0)).location
        while location < NSMaxRange(characters), location < storage.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let firstGlyph = glyphIndexForCharacter(at: paragraph.location)
            let lineRect = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let indent = style?.firstLineHeadIndent ?? 0
            if let marker = storage.attribute(.havenListMarker, at: paragraph.location, effectiveRange: nil) as? String {
                let font = (storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? RichDocumentFont) ?? RichDocumentTextCodec.font(bold: false, italic: false, size: 15)
                let markerText = NSAttributedString(string: marker, attributes: [.font: font, .foregroundColor: markerColor])
                let width = markerText.size().width
                let baselineY = lineRect.minY + (lineRect.height - font.lineHeight) / 2
                markerText.draw(at: CGPoint(x: origin.x + lineRect.minX + indent - width - 6, y: origin.y + baselineY))
            }
            if storage.attribute(.havenBlockquote, at: paragraph.location, effectiveRange: nil) != nil {
                let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
                let bounds = boundingRect(forGlyphRange: glyphs, in: container)
                context.setFillColor(RichDocumentColor(white: 0.8, alpha: 1).cgColor)
                context.fill(CGRect(x: origin.x + lineRect.minX + indent - 12, y: origin.y + bounds.minY, width: 3, height: bounds.height))
            }
            location = NSMaxRange(paragraph)
        }

        // Other writers' carets.
        for caret in peerCarets {
            let index = min(max(0, caret.location), storage.length - 1)
            guard NSLocationInRange(index, characters) || index == NSMaxRange(characters) else { continue }
            let glyph = glyphIndexForCharacter(at: index)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = location(forGlyphAt: glyph).x + line.minX
            let color = Self.peerColors[caret.colorIndex % Self.peerColors.count]
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: origin.x + x, y: origin.y + line.minY + 2, width: 2, height: line.height - 4))
            let label = NSAttributedString(string: " \(caret.name) ", attributes: [.font: RichDocumentTextCodec.font(bold: false, italic: false, size: 10), .foregroundColor: RichDocumentColor.white])
            let size = label.size()
            let tag = CGRect(x: origin.x + x + 4, y: origin.y + line.minY + 2, width: size.width, height: size.height + 2)
            context.addPath(CGPath(roundedRect: tag, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            label.draw(at: CGPoint(x: tag.minX, y: tag.minY + 1))
        }
    }
}

/// The writing surface: a native text view on TextKit 1 inside SwiftUI.
/// SwiftUI's `TextEditor` edits attributed text only from iOS 26 / macOS 26;
/// CellProtocol supports iOS 16 and macOS 13.
struct RichDocumentTextView {
    @ObservedObject var model: RichDocumentEditorModel

    static func makeStack(model: RichDocumentEditorModel) -> (NSTextStorage, RichDocumentLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = RichDocumentLayoutManager()
        layout.markerColor = model.style.secondaryColor
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    static func update(_ layout: RichDocumentLayoutManager, model: RichDocumentEditorModel, length: Int) {
        let ranges = model.openComments.filter { $0.detached != true }.map {
            NSIntersectionRange(NSRange(location: $0.range.index, length: $0.range.length), NSRange(location: 0, length: length))
        }
        guard ranges != layout.commentRanges || model.peerCarets != layout.peerCarets else { return }
        layout.commentRanges = ranges
        layout.peerCarets = model.peerCarets
        if let storage = layout.textStorage {
            layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }
}

#if canImport(UIKit)
final class RichDocumentUITextView: UITextView, RichDocumentTextSurface {
    var richTextStorage: NSMutableAttributedString { textStorage }
    var richSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }
    var isComposing: Bool { markedTextRange != nil }
    func richTextDidChangeProgrammatically() { setNeedsDisplay() }
}

extension RichDocumentTextView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> RichDocumentUITextView {
        let (_, layout, container) = Self.makeStack(model: model)
        let view = RichDocumentUITextView(frame: .zero, textContainer: container)
        context.coordinator.layout = layout
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 24, right: 14)
        view.allowsEditingTextAttributes = false
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = false
        view.accessibilityLabel = "Dokumenttekst"
        model.surface = view
        Task { @MainActor in model.start() }
        return view
    }

    func updateUIView(_ view: RichDocumentUITextView, context: Context) {
        view.isEditable = !model.isReadOnly
        Self.update(context.coordinator.layout, model: model, length: view.textStorage.length)
    }

    static func dismantleUIView(_ view: RichDocumentUITextView, coordinator: Coordinator) {
        coordinator.model.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let model: RichDocumentEditorModel
        var layout: RichDocumentLayoutManager!
        private var editLocation: Int?
        private var insertedNewlineAt: Int?
        init(model: RichDocumentEditorModel) { self.model = model }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !model.isReadOnly else { return false }
            // Never let the document's final "\n" go.
            if NSMaxRange(range) >= textView.textStorage.length, range.length > 0, !text.hasSuffix("\n") {
                if range.location >= textView.textStorage.length - 1 { return false }
            }
            editLocation = range.location
            insertedNewlineAt = text == "\n" ? range.location : nil
            textView.typingAttributes = model.typingAttributes(at: range.location)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            if let location = insertedNewlineAt { model.continueLineFormat(afterInsertingNewlineAt: location); insertedNewlineAt = nil }
            if textView.markedTextRange == nil {
                RichDocumentTextCodec.restyleParagraphs(in: textView.textStorage, range: NSRange(location: editLocation ?? 0, length: 1), style: model.style)
                model.textDidChange(editLocation: editLocation)
                model.compositionEnded()
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            model.selectionChanged(textView.selectedRange)
        }
    }
}
#elseif canImport(AppKit)
final class RichDocumentNSTextView: NSTextView, RichDocumentTextSurface {
    var richTextStorage: NSMutableAttributedString { textStorage ?? NSTextStorage() }
    var richSelection: NSRange {
        get { selectedRange() }
        set { setSelectedRange(newValue) }
    }
    var isComposing: Bool { hasMarkedText() }
    func richTextDidChangeProgrammatically() { needsDisplay = true }
    // Paste as plain text: formats from elsewhere are not Quill attributes.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

extension RichDocumentTextView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let (_, layout, container) = Self.makeStack(model: model)
        let view = RichDocumentNSTextView(frame: .zero, textContainer: container)
        context.coordinator.layout = layout
        view.delegate = context.coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 48, height: 36)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.usesFontPanel = false
        view.setAccessibilityLabel("Dokumenttekst")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = view
        model.surface = view
        Task { @MainActor in model.start() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? RichDocumentNSTextView else { return }
        view.isEditable = !model.isReadOnly
        Self.update(context.coordinator.layout, model: model, length: view.textStorage?.length ?? 0)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.model.stop()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: RichDocumentEditorModel
        var layout: RichDocumentLayoutManager!
        private var editLocation: Int?
        private var insertedNewlineAt: Int?
        init(model: RichDocumentEditorModel) { self.model = model }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard !model.isReadOnly else { return false }
            let length = textView.textStorage?.length ?? 0
            if range.length > 0, range.location >= length - 1, !(text ?? "").hasSuffix("\n") { return false }
            editLocation = range.location
            insertedNewlineAt = text == "\n" ? range.location : nil
            textView.typingAttributes = model.typingAttributes(at: range.location)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
            if let location = insertedNewlineAt { model.continueLineFormat(afterInsertingNewlineAt: location); insertedNewlineAt = nil }
            if !textView.hasMarkedText() {
                RichDocumentTextCodec.restyleParagraphs(in: storage, range: NSRange(location: editLocation ?? 0, length: 1), style: model.style)
                model.textDidChange(editLocation: editLocation)
                model.compositionEnded()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.selectionChanged(textView.selectedRange())
        }
    }
}
#endif

#endif
