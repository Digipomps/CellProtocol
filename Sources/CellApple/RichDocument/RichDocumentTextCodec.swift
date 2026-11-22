// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if canImport(UIKit)
import UIKit
public typealias RichDocumentFont = UIFont
public typealias RichDocumentColor = UIColor
public typealias RichDocumentImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias RichDocumentFont = NSFont
public typealias RichDocumentColor = NSColor
public typealias RichDocumentImage = NSImage
#endif

#if os(iOS) || os(macOS)

extension NSAttributedString.Key {
    /// The Quill attributes of a character; the source of truth for the delta.
    static let havenRichText = NSAttributedString.Key("haven.richText.attributes")
    /// The embed value of a U+FFFC character.
    static let havenRichEmbed = NSAttributedString.Key("haven.richText.embed")
    /// Drawn in the margin of a list paragraph ("•" or "3.").
    static let havenListMarker = NSAttributedString.Key("haven.richText.listMarker")
    /// Marks a blockquote paragraph; the layout manager draws its bar.
    static let havenBlockquote = NSAttributedString.Key("haven.richText.blockquote")
}

/// Boxes for attribute values; NSAttributedString compares them with isEqual.
final class RichTextAttributesBox: NSObject {
    let attributes: RichTextAttributes
    init(_ attributes: RichTextAttributes) { self.attributes = attributes }
    override func isEqual(_ object: Any?) -> Bool { (object as? RichTextAttributesBox)?.attributes == attributes }
    override var hash: Int { attributes.hashValue }
}

final class RichTextEmbedBox: NSObject {
    let embed: [String: RichTextValue]
    init(_ embed: [String: RichTextValue]) { self.embed = embed }
    override func isEqual(_ object: Any?) -> Bool { (object as? RichTextEmbedBox)?.embed == embed }
    override var hash: Int { embed.hashValue }
}

/// Converts between the cell's Quill delta and the attributed text a native
/// text view edits. Every character carries its Quill attributes in
/// `.havenRichText`, so reading the delta back never depends on fonts.
/// Line formats (header, list, blockquote) live on the paragraph's "\n", as in
/// Quill, and are drawn over the whole paragraph.
public enum RichDocumentTextCodec {
    public static let inlineKeys: Set<String> = ["bold", "italic", "underline", "strike", "link"]
    public static let lineKeys: Set<String> = ["header", "list", "blockquote"]
    public static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    public struct Style {
        public var baseSize: CGFloat
        public var textColor: RichDocumentColor
        public var secondaryColor: RichDocumentColor
        public var linkColor: RichDocumentColor
        public var maxEmbedWidth: CGFloat

        public static var standard: Style {
            #if os(macOS)
            Style(baseSize: 15, textColor: .textColor, secondaryColor: .secondaryLabelColor, linkColor: .linkColor, maxEmbedWidth: 620)
            #else
            Style(baseSize: 17, textColor: .label, secondaryColor: .secondaryLabel, linkColor: .link, maxEmbedWidth: 340)
            #endif
        }
    }

    // MARK: Delta -> attributed text

    public static func attributedString(from document: RichTextDelta, style: Style = .standard,
                                        embedImage: ([String: RichTextValue]) -> RichDocumentImage? = { _ in nil }) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for op in document.ops {
            let attributes = op.attributes ?? [:]
            switch op.kind {
            case .insertText(let text):
                result.append(NSAttributedString(string: text, attributes: characterAttributes(attributes, style: style)))
            case .insertEmbed(let embed):
                result.append(embedString(embed, attributes: attributes, style: style, image: embedImage(embed)))
            default:
                continue
            }
        }
        if result.length == 0 || (result.string as NSString).character(at: result.length - 1) != 10 {
            result.append(NSAttributedString(string: "\n", attributes: characterAttributes([:], style: style)))
        }
        restyleParagraphs(in: result, range: NSRange(location: 0, length: result.length), style: style)
        return result
    }

    static func embedString(_ embed: [String: RichTextValue], attributes: RichTextAttributes, style: Style, image: RichDocumentImage?) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let picture = image ?? placeholderImage(for: embed, style: style)
        attachment.image = picture
        let size = picture.size
        let scale = size.width > style.maxEmbedWidth ? style.maxEmbedWidth / max(size.width, 1) : 1
        attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes([.havenRichEmbed: RichTextEmbedBox(embed), .havenRichText: RichTextAttributesBox(attributes)],
                             range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Visual attributes plus the Quill attributes for one run of characters.
    public static func characterAttributes(_ quill: RichTextAttributes, style: Style) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [.havenRichText: RichTextAttributesBox(quill)]
        result[.font] = font(bold: quill["bold"] == .bool(true), italic: quill["italic"] == .bool(true), size: style.baseSize)
        result[.foregroundColor] = style.textColor
        if quill["underline"] == .bool(true) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if quill["strike"] == .bool(true) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if case .string(let link)? = quill["link"], let url = URL(string: link) {
            result[.link] = url
            result[.foregroundColor] = style.linkColor
        }
        return result
    }

    public static func font(bold: Bool, italic: Bool, size: CGFloat) -> RichDocumentFont {
        #if os(macOS)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    /// The Quill attributes of the "\n" that ends the paragraph containing `location`.
    public static func lineAttributes(in text: NSAttributedString, paragraphContaining location: Int) -> RichTextAttributes {
        let string = text.string as NSString
        guard text.length > 0 else { return [:] }
        let paragraph = string.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        let end = NSMaxRange(paragraph) - 1
        guard end >= 0, end < text.length, string.character(at: end) == 10 else { return [:] }
        let quill = (text.attribute(.havenRichText, at: end, effectiveRange: nil) as? RichTextAttributesBox)?.attributes ?? [:]
        return quill.filter { lineKeys.contains($0.key) }
    }

    /// Redraws header sizes, list indents and markers, and blockquotes for
    /// every paragraph that touches `range`, from the attributes on its "\n".
    public static func restyleParagraphs(in text: NSMutableAttributedString, range: NSRange, style: Style) {
        guard text.length > 0 else { return }
        let string = text.string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        var start = string.paragraphRange(for: NSRange(location: min(clamped.location, text.length - 1), length: 0)).location
        let endLocation = min(NSMaxRange(clamped), text.length - 1)
        // Ordered list numbering continues from the paragraph before.
        var ordinal = 0
        if start > 0 {
            var probe = string.paragraphRange(for: NSRange(location: start - 1, length: 0))
            while lineAttributes(in: text, paragraphContaining: probe.location)["list"] == .string("ordered") {
                ordinal += 1
                guard probe.location > 0 else { break }
                probe = string.paragraphRange(for: NSRange(location: probe.location - 1, length: 0))
            }
        }
        text.beginEditing()
        while start < text.length {
            let paragraph = string.paragraphRange(for: NSRange(location: start, length: 0))
            let line = lineAttributes(in: text, paragraphContaining: paragraph.location)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = style.baseSize * 0.5
            paragraphStyle.lineHeightMultiple = 1.15
            text.removeAttribute(.havenListMarker, range: paragraph)
            text.removeAttribute(.havenBlockquote, range: paragraph)
            var headerSize: CGFloat?
            if case .int(let level)? = line["header"] {
                headerSize = style.baseSize * (level == 1 ? 1.6 : level == 2 ? 1.3 : 1.12)
                paragraphStyle.paragraphSpacingBefore = style.baseSize * 0.6
            }
            if case .string(let kind)? = line["list"] {
                ordinal = kind == "ordered" ? ordinal + 1 : 0
                paragraphStyle.headIndent = style.baseSize * 1.6
                paragraphStyle.firstLineHeadIndent = style.baseSize * 1.6
                paragraphStyle.paragraphSpacing = style.baseSize * 0.2
                text.addAttribute(.havenListMarker, value: kind == "ordered" ? "\(ordinal)." : "•", range: paragraph)
            } else {
                ordinal = 0
            }
            if line["blockquote"] == .bool(true) {
                paragraphStyle.headIndent += style.baseSize
                paragraphStyle.firstLineHeadIndent += style.baseSize
                text.addAttribute(.havenBlockquote, value: true, range: paragraph)
            }
            text.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
            // Fonts follow the per-character attributes, sized by the line.
            text.enumerateAttribute(.havenRichText, in: paragraph) { value, run, _ in
                let quill = (value as? RichTextAttributesBox)?.attributes ?? [:]
                guard text.attribute(.havenRichEmbed, at: run.location, effectiveRange: nil) == nil else { return }
                let size = headerSize ?? style.baseSize
                text.addAttribute(.font, value: font(bold: headerSize != nil || quill["bold"] == .bool(true), italic: quill["italic"] == .bool(true) || line["blockquote"] == .bool(true), size: size), range: run)
                if line["blockquote"] == .bool(true), quill["link"] == nil {
                    text.addAttribute(.foregroundColor, value: style.secondaryColor, range: run)
                }
            }
            start = NSMaxRange(paragraph)
            if start > endLocation, ordinal == 0 { break }
            if start > endLocation, lineAttributes(in: text, paragraphContaining: start)["list"] != .string("ordered") { break }
        }
        text.endEditing()
    }

    // MARK: Attributed text -> delta

    public static func document(from text: NSAttributedString) -> RichTextDelta {
        var units: [RichTextDelta.Unit] = []
        units.reserveCapacity(text.length)
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, run, _ in
            var quill = (attributes[.havenRichText] as? RichTextAttributesBox)?.attributes ?? [:]
            if let embed = (attributes[.havenRichEmbed] as? RichTextEmbedBox)?.embed {
                for _ in 0..<run.length { units.append(.init(codeUnit: RichTextDelta.objectReplacementCharacter, embed: embed, attributes: quill)) }
                return
            }
            for offset in 0..<run.length {
                let unit = string.character(at: run.location + offset)
                // Line formats belong only on "\n"; inline formats never on it.
                var unitAttributes = quill
                if unit == 10 { unitAttributes = quill.filter { lineKeys.contains($0.key) } }
                else { unitAttributes = quill.filter { !lineKeys.contains($0.key) } }
                if unit == 0xFFFC { unitAttributes = [:] } // attachment that lost its embed: dropped below
                units.append(.init(codeUnit: unit, embed: nil, attributes: unitAttributes))
            }
            quill = [:]
        }
        // An attachment without an embed value cannot be expressed in the delta.
        units.removeAll { $0.codeUnit == 0xFFFC && $0.embed == nil }
        if units.last?.codeUnit != 10 || units.last?.embed != nil { units.append(.init(codeUnit: 10, embed: nil, attributes: [:])) }
        return RichTextDelta(units: units)
    }

    // MARK: Applying a change to live text

    /// Applies a change (relative to the text's current document) in place,
    /// so the selection and scroll position stay where they are.
    public static func apply(_ change: RichTextDelta, to text: NSMutableAttributedString, style: Style = .standard,
                             embedImage: ([String: RichTextValue]) -> RichDocumentImage? = { _ in nil }) {
        var index = 0
        var touched: NSRange?
        func touch(_ range: NSRange) { touched = touched.map { NSUnionRange($0, range) } ?? range }
        text.beginEditing()
        for op in change.ops {
            switch op.kind {
            case .retain(let count):
                let range = NSRange(location: index, length: min(count, text.length - index))
                if let attributes = op.attributes, range.length > 0 {
                    applyAttributeChange(attributes, to: text, range: range, style: style)
                    touch(range)
                }
                index += count
            case .delete(let count):
                let range = NSRange(location: index, length: min(count, text.length - index))
                text.deleteCharacters(in: range)
                touch(NSRange(location: index, length: 0))
            case .insertText(let value):
                let inserted = NSAttributedString(string: value, attributes: characterAttributes(op.attributes ?? [:], style: style))
                text.insert(inserted, at: index)
                touch(NSRange(location: index, length: inserted.length))
                index += inserted.length
            case .insertEmbed(let embed):
                text.insert(embedString(embed, attributes: op.attributes ?? [:], style: style, image: embedImage(embed)), at: index)
                touch(NSRange(location: index, length: 1))
                index += 1
            }
        }
        text.endEditing()
        if let touched { restyleParagraphs(in: text, range: touched, style: style) }
    }

    /// Merges Quill attributes into a range (`null` removes a key), keeping
    /// line keys on "\n" and inline keys off it.
    public static func applyAttributeChange(_ change: RichTextAttributes, to text: NSMutableAttributedString, range: NSRange, style: Style) {
        let string = text.string as NSString
        var location = range.location
        while location < NSMaxRange(range) {
            var run = NSRange()
            let current = (text.attribute(.havenRichText, at: location, longestEffectiveRange: &run, in: range) as? RichTextAttributesBox)?.attributes ?? [:]
            // Split runs at newlines so each unit gets the right key set.
            var end = NSMaxRange(run)
            let newline = string.range(of: "\n", options: [], range: NSRange(location: location, length: end - location))
            let isNewline = newline.location == location
            if newline.location != NSNotFound, !isNewline { end = newline.location }
            if isNewline { end = location + 1 }
            let piece = NSRange(location: location, length: end - location)
            var merged = current
            for (key, value) in change where isNewline == lineKeys.contains(key) {
                if value == .null { merged.removeValue(forKey: key) } else { merged[key] = value }
            }
            if text.attribute(.havenRichEmbed, at: location, effectiveRange: nil) != nil {
                text.addAttribute(.havenRichText, value: RichTextAttributesBox(merged), range: piece)
            } else {
                text.addAttributes(characterAttributes(merged, style: style), range: piece)
            }
            location = end
        }
    }

    // MARK: Embeds

    public static func decodeImage(_ embed: [String: RichTextValue]) -> RichDocumentImage? {
        guard case .string(let uri)? = embed["image"], let comma = uri.firstIndex(of: ","),
              uri.hasPrefix("data:image/png;base64,") || uri.hasPrefix("data:image/jpeg;base64,"),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
        return RichDocumentImage(data: data)
    }

    /// A drawn card for a chart, network or table embed, or a missing image.
    static func placeholderImage(for embed: [String: RichTextValue], style: Style) -> RichDocumentImage {
        var title = "Bilde"
        var bars: [Double] = []
        var labels: [String] = []
        if case .object(let visualization)? = embed["visualization"], case .object(let spec)? = visualization["spec"] {
            if case .string(let value)? = spec["title"], !value.isEmpty { title = value } else { title = "Diagram" }
            if case .array(let rows)? = spec["rows"] {
                for row in rows.prefix(24) {
                    guard case .object(let fields) = row else { continue }
                    switch fields["value"] { case .int(let v)?: bars.append(Double(v)); case .double(let v)?: bars.append(v); default: bars.append(0) }
                    if case .string(let label)? = fields["label"] { labels.append(label) } else { labels.append("") }
                }
            }
        }
        let size = CGSize(width: min(style.maxEmbedWidth, 560), height: bars.isEmpty ? 64 : 200)
        return drawImage(size: size) { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.setFillColor(RichDocumentColor(white: 0.97, alpha: 1).cgColor)
            context.setStrokeColor(RichDocumentColor(white: 0.82, alpha: 1).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.addPath(path); context.drawPath(using: .fillStroke)
            let titleAttributes: [NSAttributedString.Key: Any] = [.font: font(bold: true, italic: false, size: 13), .foregroundColor: style.textColor]
            NSAttributedString(string: title, attributes: titleAttributes).draw(at: CGPoint(x: 14, y: 12))
            guard !bars.isEmpty else { return }
            let maxValue = max(bars.max() ?? 1, 1)
            let area = CGRect(x: 14, y: 40, width: size.width - 28, height: size.height - 70)
            let gap: CGFloat = 8
            let width = (area.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count)
            let labelAttributes: [NSAttributedString.Key: Any] = [.font: font(bold: false, italic: false, size: 10), .foregroundColor: style.secondaryColor]
            for (offset, value) in bars.enumerated() {
                let height = area.height * CGFloat(max(value, 0) / maxValue)
                let x = area.minX + CGFloat(offset) * (width + gap)
                context.setFillColor(RichDocumentColor(red: 0.30, green: 0.56, blue: 0.41, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: area.maxY - height, width: width, height: height))
                NSAttributedString(string: labels[offset], attributes: labelAttributes).draw(at: CGPoint(x: x, y: area.maxY + 4))
            }
        }
    }

    static func drawImage(size: CGSize, _ draw: (CGContext) -> Void) -> RichDocumentImage {
        #if os(macOS)
        let image = NSImage(size: size, flipped: true) { _ in
            if let context = NSGraphicsContext.current?.cgContext { draw(context) }
            return true
        }
        return image
        #else
        return UIGraphicsImageRenderer(size: size).image { draw($0.cgContext) }
        #endif
    }
}

#endif
