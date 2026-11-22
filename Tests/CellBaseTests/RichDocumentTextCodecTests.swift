// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

#if os(iOS) || os(macOS)
import XCTest
@testable import CellBase
@testable import CellApple

/// The native editor's text must turn back into exactly the delta it was
/// built from, and every delta it produces must pass the cell's attribute
/// rules (CellScaffold `RichDocumentState.validateAttributes`).
@MainActor
final class RichDocumentTextCodecTests: XCTestCase {
    private struct Corpus: Decodable { var cases: [Case] }
    private struct Case: Decodable { var name: String; var kind: String; var a: [RichTextOp]; var b: [RichTextOp]? }

    private func corpus() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/RichTextDeltaVectors.v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).cases
    }

    /// Quill documents always end with "\n", and line keys sit only on "\n".
    private func canonical(_ delta: RichTextDelta) -> [RichTextDelta.Unit] {
        var units = delta.units.map { unit -> RichTextDelta.Unit in
            var copy = unit
            if unit.embed == nil {
                copy.attributes = unit.codeUnit == 10
                    ? unit.attributes.filter { RichDocumentTextCodec.lineKeys.contains($0.key) }
                    : unit.attributes.filter { !RichDocumentTextCodec.lineKeys.contains($0.key) }
            }
            return copy
        }
        if units.last?.codeUnit != 10 || units.last?.embed != nil { units.append(.init(codeUnit: 10, embed: nil, attributes: [:])) }
        return units
    }

    private let everyFormat = RichTextDelta([
        .insert("Tittel"), .insert("\n", ["header": .int(1)]),
        .insert("Fet", ["bold": .bool(true)]), .insert(" kursiv", ["italic": .bool(true)]), .insert(" under", ["underline": .bool(true)]),
        .insert(" strek", ["strike": .bool(true)]), .insert(" lenke", ["link": .string("https://uio.no")]), .insert(" 😀\n"),
        .insert("punkt"), .insert("\n", ["list": .string("bullet")]),
        .insert("nummer"), .insert("\n", ["list": .string("ordered")]),
        .insert("sitat"), .insert("\n", ["blockquote": .bool(true)]),
        .embed(["visualization": .object(["kind": .string("chart"), "spec": .object(["title": .string("T"), "chartType": .string("bar"),
            "rows": .array([.object(["id": .string("0"), "label": .string("a"), "value": .int(3)])])])])]),
        .insert("\n")
    ])

    func testEveryFormatRoundTrips() {
        let text = RichDocumentTextCodec.attributedString(from: everyFormat)
        XCTAssertEqual(RichDocumentTextCodec.document(from: text).units, canonical(everyFormat))
    }

    func testCorpusDocumentsRoundTrip() throws {
        for item in try corpus() where item.kind == "compose" {
            let document = RichTextDelta(item.a)
            guard document.isDocument else { continue }
            let text = RichDocumentTextCodec.attributedString(from: document)
            XCTAssertEqual(RichDocumentTextCodec.document(from: text).units, canonical(document), item.name)
        }
    }

    func testApplyingAChangeInPlaceEqualsRebuilding() throws {
        for item in try corpus() where item.kind == "compose" {
            let document = RichTextDelta(item.a)
            guard document.isDocument, let change = item.b, document.plainText.hasSuffix("\n") else { continue }
            let text = RichDocumentTextCodec.attributedString(from: document)
            RichDocumentTextCodec.apply(RichTextDelta(change), to: text)
            XCTAssertEqual(RichDocumentTextCodec.document(from: text).units, canonical(document.compose(RichTextDelta(change))), item.name)
        }
    }

    func testProducedAttributesPassTheCellsRules() {
        let text = RichDocumentTextCodec.attributedString(from: everyFormat)
        for op in RichDocumentTextCodec.document(from: text).ops {
            for (key, value) in op.attributes ?? [:] {
                switch key {
                case "bold", "italic", "underline", "strike", "blockquote":
                    guard case .bool = value else { return XCTFail("\(key) must be a bool") }
                case "header":
                    guard case .int(let level) = value, (1...3).contains(level) else { return XCTFail("header 1–3") }
                case "list":
                    XCTAssertTrue(value == .string("ordered") || value == .string("bullet"))
                case "link":
                    guard case .string(let link) = value, let url = URL(string: link) else { return XCTFail("link") }
                    XCTAssertTrue(RichDocumentTextCodec.allowedLinkSchemes.contains(url.scheme ?? ""))
                default:
                    XCTFail("The cell rejects attribute \(key)")
                }
            }
        }
    }

    // MARK: Editor model against a fake text view

    private final class FakeSurface: RichDocumentTextSurface {
        let richTextStorage = NSMutableAttributedString()
        var richSelection = NSRange(location: 0, length: 0)
        var isComposing = false
        func richTextDidChangeProgrammatically() {}
    }

    private struct EchoTransport: RichDocumentTransport {
        func current() async throws -> ValueType? {
            RichTextValue(encoding: RichDocumentSnapshot(documentId: "d", revision: 0, sequence: 0, ops: [.insert("Hei du\n")]))!.valueType
        }
        func send(_ command: ValueType) async throws -> ValueType? { throw URLError(.notConnectedToInternet) }
    }

    private func openModel() async -> (RichDocumentEditorModel, FakeSurface) {
        let model = RichDocumentEditorModel(session: RichDocumentSession(transport: EchoTransport(), retryDelay: 60))
        let surface = FakeSurface()
        model.surface = surface
        await model.session.refresh()
        return (model, surface)
    }

    func testTypingBecomesAnInsert() async {
        let (model, surface) = await openModel()
        XCTAssertEqual(surface.richTextStorage.string, "Hei du\n")
        surface.richTextStorage.insert(NSAttributedString(string: "!", attributes: model.typingAttributes(at: 6)), at: 6)
        model.textDidChange(editLocation: 6)
        XCTAssertEqual(model.session.localDocument.plainText, "Hei du!\n")
        XCTAssertEqual(model.session.pendingCount, 1)
    }

    func testBoldOnSelectionIsAnAttributeRetain() async {
        let (model, surface) = await openModel()
        surface.richSelection = NSRange(location: 4, length: 2)
        model.selectionChanged(surface.richSelection)
        model.toggle(.bold)
        XCTAssertEqual(model.shown.ops, [.insert("Hei "), .insert("du", ["bold": .bool(true)]), .insert("\n")])
        XCTAssertTrue(model.isActive(.bold))
    }

    func testHeaderGoesOnTheLineEnd() async {
        let (model, surface) = await openModel()
        surface.richSelection = NSRange(location: 1, length: 0)
        model.selectionChanged(surface.richSelection)
        model.setLineFormat(.header(2))
        XCTAssertEqual(model.shown.ops, [.insert("Hei du"), .insert("\n", ["header": .int(2)])])
        XCTAssertEqual(model.currentLineFormat, .header(2))
    }

    func testLinksOutsideTheCellsSchemesAreRefused() async {
        let (model, surface) = await openModel()
        surface.richSelection = NSRange(location: 0, length: 3)
        model.selectionChanged(surface.richSelection)
        XCTAssertFalse(model.setLink("javascript:alert(1)"))
        XCTAssertTrue(model.setLink("uio.no"))
        XCTAssertEqual(model.shown.ops.first, .insert("Hei", ["link": .string("https://uio.no")]))
    }

    func testRemoteChangeKeepsTheCaret() async {
        let (model, surface) = await openModel()
        surface.richSelection = NSRange(location: 4, length: 0)
        let snapshot = RichDocumentSnapshot(documentId: "d", revision: 1, sequence: 1, ops: [.insert(">> Hei du\n")],
            events: [.init(sequence: 1, revision: 1, author: "x", command: RichDocumentCommand(clientId: "c", baseRevision: 0, kind: "delta", ops: [.insert(">> ")]))])
        model.session.accept(snapshot)
        XCTAssertEqual(surface.richTextStorage.string, ">> Hei du\n")
        XCTAssertEqual(surface.richSelection.location, 7, "the caret moved with the text")
    }

    func testChartFormBuildsTheWebShape() async {
        // The model holds its surface weakly, as the view owns it; keep it alive.
        let (model, surface) = await openModel()
        defer { withExtendedLifetime(surface) {} }
        XCTAssertFalse(model.insertChart(title: "T", type: "bar", data: "uten kolon"))
        XCTAssertTrue(model.insertChart(title: "T", type: "bar", data: "Jan: 10\nFeb: 2,5"))
        guard case .insertEmbed(let embed)? = model.shown.ops.first(where: { if case .insertEmbed = $0.kind { return true }; return false })?.kind,
              case .object(let visualization)? = embed["visualization"], case .object(let spec)? = visualization["spec"],
              case .array(let rows)? = spec["rows"] else { return XCTFail("chart embed") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(visualization["kind"], .string("chart"))
    }

    func testMarkdownExport() {
        let markdown = RichDocumentExport.markdown(everyFormat)
        XCTAssertTrue(markdown.hasPrefix("# Tittel\n"), markdown)
        XCTAssertTrue(markdown.contains("**Fet**"))
        XCTAssertTrue(markdown.contains("[ lenke](https://uio.no)"))
        XCTAssertTrue(markdown.contains("- punkt"))
        XCTAssertTrue(markdown.contains("1. nummer"))
        XCTAssertTrue(markdown.contains("> sitat"))
    }

    func testPdfExportIsAPdf() {
        let data = RichDocumentExport.pdf(everyFormat)
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))
        XCTAssertGreaterThan(data.count, 1000)
    }
}
#endif
