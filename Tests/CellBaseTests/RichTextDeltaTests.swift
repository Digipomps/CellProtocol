// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// Runs the corpus whose expected values come from the Quill bundle the web
/// document adapter loads (`Tests/Scripts/rich-text-delta/vectors.js`), so
/// Binding and the web agree on every compose, transform and position.
final class RichTextDeltaTests: XCTestCase {
    private struct Case: Decodable {
        var name: String
        var kind: String
        var base: [RichTextOp]?
        var a: [RichTextOp]
        var b: [RichTextOp]?
        var priority: Bool?
        var index: Int?
        var expected: Expected
        var converged: [RichTextOp]?
    }

    private enum Expected: Decodable {
        case ops([RichTextOp])
        case position(Int)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let index = try? container.decode(Int.self) { self = .position(index) } else { self = .ops(try container.decode([RichTextOp].self)) }
        }
    }

    private struct Corpus: Decodable { var cases: [Case] }

    private func corpus() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RichTextDeltaVectors.v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).cases
    }

    private func json(_ ops: [RichTextOp]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(ops)) ?? Data(), as: UTF8.self)
    }

    func testCorpusIsLargeAndCoversEveryKind() throws {
        let cases = try corpus()
        XCTAssertGreaterThanOrEqual(cases.count, 200)
        for kind in ["compose", "transform", "position"] {
            XCTAssertGreaterThanOrEqual(cases.filter { $0.kind == kind }.count, 60, kind)
        }
    }

    func testEveryCaseMatchesQuill() throws {
        for item in try corpus() {
            let a = RichTextDelta(item.a)
            switch (item.kind, item.expected) {
            case ("compose", .ops(let expected)):
                let result = a.compose(RichTextDelta(item.b ?? []))
                XCTAssertEqual(json(result.ops), json(expected), item.name)
            case ("transform", .ops(let expected)):
                let b = RichTextDelta(item.b ?? [])
                let result = a.transform(b, priority: item.priority ?? false)
                XCTAssertEqual(json(result.ops), json(expected), item.name)
                if let base = item.base, let converged = item.converged {
                    let left = RichTextDelta(base).compose(a).compose(a.transform(b, priority: true))
                    XCTAssertEqual(json(left.ops), json(converged), "\(item.name) convergence")
                    let right = RichTextDelta(base).compose(b).compose(b.transform(a, priority: false))
                    XCTAssertEqual(left.units, right.units, "\(item.name) both orders give the same document")
                }
            case ("position", .position(let expected)):
                XCTAssertEqual(a.transformPosition(item.index ?? 0, priority: item.priority ?? false), expected, item.name)
            default:
                XCTFail("Unknown case shape: \(item.name)")
            }
        }
    }

    func testWireFormatIsQuillJSON() throws {
        let delta = RichTextDelta([.retain(3), .retain(2, ["bold": .null, "header": .int(2)]), .insert("😀"), .embed(["image": .string("data:image/png;base64,AA")]), .delete(4)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(delta), as: UTF8.self)
        XCTAssertEqual(text, #"[{"retain":3},{"attributes":{"bold":null,"header":2},"retain":2},{"insert":"😀"},{"insert":{"image":"data:image\/png;base64,AA"}},{"delete":4}]"#)
        let decoded = try JSONDecoder().decode(RichTextDelta.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, delta)
        XCTAssertEqual(delta.ops[2].length, 2, "UTF-16 length, as Quill and NSString count")
        XCTAssertEqual(delta.ops[3].length, 1, "an embed counts one, like U+FFFC")
    }

    func testDiffRebuildsTheNewDocument() throws {
        let documents = try corpus().filter { $0.kind == "compose" }.map { RichTextDelta($0.a) }
        XCTAssertGreaterThan(documents.count, 10)
        for old in documents {
            for new in documents {
                let change = RichTextDelta.diff(from: old, to: new)
                XCTAssertEqual(old.compose(change).units, new.units)
            }
        }
    }

    func testDiffOfFormattingKeepsTheTextInPlace() {
        let old = RichTextDelta([.insert("Hei du\n")])
        let new = RichTextDelta([.insert("Hei "), .insert("du", ["bold": .bool(true)]), .insert("\n")])
        XCTAssertEqual(RichTextDelta.diff(from: old, to: new).ops, [.retain(4), .retain(2, ["bold": .bool(true)])])
        XCTAssertEqual(RichTextDelta.diff(from: new, to: old).ops, [.retain(4), .retain(2, ["bold": .null])])
    }

    func testDiffUsesTheCursorForRepeatedLetters() {
        let old = RichTextDelta([.insert("aa\n")])
        let new = RichTextDelta([.insert("aaa\n")])
        XCTAssertEqual(RichTextDelta.diff(from: old, to: new, cursor: 0).ops, [.insert("a")])
        XCTAssertEqual(RichTextDelta.diff(from: old, to: new).ops, [.retain(2), .insert("a")])
    }

    func testDiffKeepsSurrogatePairsWhole() {
        let old = RichTextDelta([.insert("😀\n")])
        let new = RichTextDelta([.insert("😃\n")])
        let change = RichTextDelta.diff(from: old, to: new)
        XCTAssertEqual(old.compose(change).plainText, "😃\n")
        XCTAssertEqual(change.ops, [.insert("😃"), .delete(2)], "the whole pair, never half of it")
    }
}
