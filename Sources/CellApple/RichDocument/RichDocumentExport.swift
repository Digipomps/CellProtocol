// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import CellBase
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(iOS) || os(macOS)

/// Export from the delta, as on the web: Markdown and PDF on both platforms,
/// Word (.docx) on macOS where the system writes it.
public enum RichDocumentExport {
    public enum Format: String, CaseIterable, Identifiable {
        case markdown, pdf, docx
        public var id: String { rawValue }
        public var label: String {
            switch self { case .markdown: return "Markdown (.md)"; case .pdf: return "PDF"; case .docx: return "Word (.docx)" }
        }
        public var fileExtension: String {
            switch self { case .markdown: return "md"; case .pdf: return "pdf"; case .docx: return "docx" }
        }
        public static var available: [Format] {
            #if os(macOS)
            return [.markdown, .pdf, .docx]
            #else
            return [.markdown, .pdf]
            #endif
        }
    }

    /// Markdown with the same rules as the web export: headers, lists,
    /// quotes, bold, italic, strike, links; images as data URIs; charts as a title.
    public static func markdown(_ document: RichTextDelta) -> String {
        var lines: [String] = []
        var current = ""
        var ordinal = 0
        for op in document.ops {
            let attributes = op.attributes ?? [:]
            switch op.kind {
            case .insertEmbed(let embed):
                if case .string(let uri)? = embed["image"] { current += "![](\(uri))" }
                else if case .object(let visualization)? = embed["visualization"], case .object(let spec)? = visualization["spec"] {
                    var title = "Diagram"
                    if case .string(let value)? = spec["title"], !value.isEmpty { title = value }
                    current += "_[\(title)]_"
                }
            case .insertText(let text):
                let parts = text.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    current += inline(part, attributes)
                    guard index < parts.count - 1 else { continue }
                    var prefix = ""
                    if case .int(let level)? = attributes["header"] { prefix = String(repeating: "#", count: max(1, min(level, 3))) + " " }
                    if attributes["list"] == .string("bullet") { prefix = "- " }
                    if attributes["list"] == .string("ordered") { ordinal += 1; prefix = "\(ordinal). " } else { ordinal = 0 }
                    if attributes["blockquote"] == .bool(true) { prefix = "> " }
                    lines.append(prefix + current)
                    current = ""
                }
            default: continue
            }
        }
        if !current.isEmpty { lines.append(current) }
        // A blank line between blocks, except inside a list.
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            output.append(line)
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            let inList = (line.hasPrefix("- ") || line.first?.isNumber == true) && (next?.hasPrefix("- ") == true || next?.first?.isNumber == true)
            if next != nil, !inList { output.append("") }
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func inline(_ text: String, _ attributes: RichTextAttributes) -> String {
        guard !text.isEmpty else { return "" }
        var value = text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
        if attributes["bold"] == .bool(true) { value = "**\(value)**" }
        if attributes["italic"] == .bool(true) { value = "_\(value)_" }
        if attributes["strike"] == .bool(true) { value = "~~\(value)~~" }
        if case .string(let link)? = attributes["link"] { value = "[\(value)](\(link))" }
        return value
    }

    /// The document as print-ready attributed text (no carets or highlights).
    public static func printable(_ document: RichTextDelta) -> NSAttributedString {
        var style = RichDocumentTextCodec.Style.standard
        style.baseSize = 12
        #if os(macOS)
        style.textColor = .black; style.secondaryColor = .darkGray
        #else
        style.textColor = .black; style.secondaryColor = .darkGray
        #endif
        style.maxEmbedWidth = 460
        let text = RichDocumentTextCodec.attributedString(from: document, style: style, embedImage: RichDocumentTextCodec.decodeImage)
        // List markers are drawn by the editor; in a file they become text.
        let result = NSMutableAttributedString()
        let string = text.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            if let marker = text.attribute(.havenListMarker, at: paragraph.location, effectiveRange: nil) as? String {
                let attributes = text.attributes(at: paragraph.location, effectiveRange: nil).filter { $0.key != .havenRichEmbed && $0.key != .attachment }
                result.append(NSAttributedString(string: marker + " ", attributes: attributes))
            }
            result.append(text.attributedSubstring(from: paragraph))
            location = NSMaxRange(paragraph)
        }
        return result
    }

    public static func pdf(_ document: RichTextDelta) -> Data {
        let text = printable(document)
        let page = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 in points
        let margin: CGFloat = 56
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = page
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin))
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 500
        for container in containers {
            context.beginPDFPage(nil)
            #if os(macOS)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            let range = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()
            #else
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            let range = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: margin, y: margin))
            UIGraphicsPopContext()
            #endif
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    #if os(macOS)
    public static func docx(_ document: RichTextDelta) throws -> Data {
        let text = printable(document)
        return try text.data(from: NSRange(location: 0, length: text.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
    #endif

    /// Writes the export to a temporary file named after the first line.
    public static func file(_ format: Format, document: RichTextDelta) throws -> URL {
        let title = document.plainText.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\u{FFFC}", with: "") ?? ""
        let name = (title.isEmpty ? "Dokument" : String(title.prefix(60))) + "." + format.fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        switch format {
        case .markdown: data = Data(markdown(document).utf8)
        case .pdf: data = pdf(document)
        case .docx:
            #if os(macOS)
            data = try docx(document)
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

#endif
