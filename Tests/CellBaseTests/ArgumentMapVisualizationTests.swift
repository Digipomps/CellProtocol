// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class ArgumentMapVisualizationTests: XCTestCase {
    private struct Vector: Decodable {
        var name: String
        var spec: ValueType
        var expected: [[ValueType]]
    }

    private struct Vectors: Decodable { var vectors: [Vector] }

    private func loadVectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ArgumentMapLayoutVectors.v1.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
    }

    private func spec(_ json: String) throws -> ArgumentMapVisualizationSpec? {
        let value = try JSONDecoder().decode(ValueType.self, from: Data(json.utf8))
        return ArgumentMapVisualizationSpec.decode(from: value)
    }

    func testLayoutMatchesSharedVectors() throws {
        let vectors = try loadVectors()
        XCTAssertGreaterThanOrEqual(vectors.count, 5)
        for vector in vectors {
            let decoded = try XCTUnwrap(ArgumentMapVisualizationSpec.decode(from: vector.spec), vector.name)
            let actual = decoded.layout().map { "\($0.id):\($0.row):\($0.order):\($0.rowCount)" }
            let expected = vector.expected.map { row -> String in
                row.map { cell -> String in
                    switch cell {
                    case .string(let text): return text
                    case .integer(let number): return String(number)
                    case .number(let number): return String(number)
                    default: return "?"
                    }
                }.joined(separator: ":")
            }
            XCTAssertEqual(actual, expected, vector.name)
        }
    }

    func testUnknownRoleAndRelationFallBackInsteadOfFailing() throws {
        let decoded = try XCTUnwrap(spec("""
        {"nodes":[{"id":"a","role":"thesis","title":"A"},{"id":"b","role":"premise","title":"B"}],
         "edges":[{"source":"b","target":"a","relation":"undermines"}]}
        """))
        XCTAssertEqual(decoded.nodes.first?.role, .premise)
        XCTAssertEqual(decoded.edges.first?.relation, .context)
        XCTAssertEqual(decoded.edges.first?.displayLabel, "kontekst")
    }

    func testEdgeLabelDefaultsToNorwegianRelationName() throws {
        let decoded = try XCTUnwrap(spec("""
        {"nodes":[{"id":"a","role":"conclusion","title":"A"},{"id":"b","role":"counter","title":"B"},{"id":"c","role":"rebuttal","title":"C"}],
         "edges":[{"source":"b","target":"a","relation":"attacks"},{"source":"c","target":"b","relation":"rebuts","label":"svarer på","inferred":true}]}
        """))
        XCTAssertEqual(decoded.edges.map(\.displayLabel), ["angriper", "svarer på"])
        XCTAssertEqual(decoded.edges.map(\.inferred), [false, true])
    }

    func testMissingNodesIsNotASpec() throws {
        XCTAssertNil(try spec(#"{"edges":[]}"#))
        XCTAssertNil(ArgumentMapVisualizationSpec.decode(from: nil))
    }

    func testCapsNodesAndEdges() {
        let nodes = (0..<250).map { ArgumentMapVisualizationSpec.Node(id: "n\($0)", role: .premise, title: "n\($0)") }
        let edges = (1..<250).map { ArgumentMapVisualizationSpec.Edge(source: "n\($0)", target: "n0", relation: .supports) }
        let normalized = ArgumentMapVisualizationSpec(nodes: nodes, edges: edges).normalized()
        XCTAssertEqual(normalized.nodes.count, ArgumentMapVisualizationSpec.maximumNodes)
        XCTAssertEqual(normalized.edges.count, ArgumentMapVisualizationSpec.maximumNodes - 1)
        XCTAssertEqual(normalized.layout().count, ArgumentMapVisualizationSpec.maximumNodes)
    }

    func testRoundTripThroughValueTypeKeepsContent() throws {
        let original = ArgumentMapVisualizationSpec(
            nodes: [.init(id: "P7", role: .conclusion, title: "P7 · Konklusjon", body: "Derfor bør …", status: "Kilde mangler", statusTone: .warning, detail: "2 enig")],
            edges: [],
            legend: "Konklusjonen øverst."
        )
        let value = try XCTUnwrap(original.valueType)
        XCTAssertEqual(ArgumentMapVisualizationSpec.decode(from: value), original)
    }
}
