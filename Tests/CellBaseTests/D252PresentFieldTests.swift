import XCTest
@testable import CellBase

final class D252PresentFieldTests: XCTestCase {
    private func decode(_ fields: [String: Any]) throws -> BridgeCommand {
        try JSONDecoder().decode(BridgeCommand.self, from: JSONSerialization.data(withJSONObject: fields.merging(["cid": 7]) { a, _ in a }))
    }
    private func keyValue(_ fields: [String: Any]) -> [String: Any] {
        ["cmd": "set", "cid": 7, "&keyValue": fields.merging(["key": "FIXTURE-PAYLOAD"]) { a, _ in a }]
    }
    func testKeyValueRejectsEveryMalformedTypedField() throws {
        let bad: [String: Any] = ["string": 123, "number": false, "float": "FIXTURE-PAYLOAD",
            "integer": 1.5, "object": false, "list": false]
        for (key, value) in bad {
            XCTAssertThrowsError(try decode(keyValue([key: value])), "D252-B selected \(key)")
            var other: [String: Any] = ["string": "FIXTURE-PAYLOAD", "value": "FIXTURE-PAYLOAD"]
            other[key] = value
            XCTAssertThrowsError(try decode(keyValue(other)), "D252-B present \(key) before priority")
        }
        for key in ["object", "list"] {
            let child: [String: Any] = ["&keyValue": 0]
            let value: Any = key == "object" ? ["child": child] : [child]
            XCTAssertThrowsError(try decode(keyValue([key: value])), "D252-B child error \(key)")
        }
    }
    func testKeyValueProducerVariantsAndCompatibility() throws {
        let variants: [ValueType] = [.string("FIXTURE-PAYLOAD"), .number(7), .float(1.5), .integer(7),
            .object(["field": .string("FIXTURE-PAYLOAD")]), .list([.integer(7)]), .null]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for value in variants {
            let original = KeyValue(key: "FIXTURE-PAYLOAD", value: value)
            let bytes = try encoder.encode(original)
            let decoded = try JSONDecoder().decode(KeyValue.self, from: bytes)
            switch (value, decoded.value) {
            case (.string(let a), .string(let b)): XCTAssertEqual(a, b)
            case (.number(let a), .number(let b)): XCTAssertEqual(a, b)
            case (.integer(let a), .integer(let b)): XCTAssertEqual(a, b)
            case (.float(let a), .float(let b)): XCTAssertEqual(a, b)
            case (.object(let a), .object(let b)):
                XCTAssertEqual(a["field"], b["field"])
            case (.list(let a), .list(let b)): XCTAssertEqual(a, b)
            case (.null, .null): break
            default: XCTFail("D252-B exact ValueType variant")
            }
            XCTAssertEqual(try encoder.encode(decoded), bytes)
        }
        for fields in [[:], ["string": NSNull()], ["future": 123]] as [[String: Any]] {
            guard case .keyValue(let decoded) = try decode(keyValue(fields)).payload else { return XCTFail("KeyValue") }
            XCTAssertNil(decoded.value)
        }
        guard case .keyValue(let decoded) = try decode(keyValue(["string": "FIXTURE-PAYLOAD", "integer": 7])).payload else { return XCTFail("KeyValue") }
        XCTAssertEqual(decoded.value, .string("FIXTURE-PAYLOAD"))
    }
    private var flow: [String: Any] {
        ["id": "FIXTURE-PAYLOAD", "title": "FIXTURE-PAYLOAD",
         "properties": ["type": "content", "contentType": "string"], "content": "FIXTURE-PAYLOAD"]
    }
    func testFlowRejectsEveryMalformedPresentField() throws {
        let bad: [String: Any] = ["topic": 123, "properties": 123, "origin": 123, "hops": "FIXTURE-PAYLOAD", "content": 123]
        for (key, value) in bad {
            var fields = flow; fields[key] = value
            XCTAssertThrowsError(try decode(["cmd": "response", "cid": 7, "&flowElement": fields]), "D252-C \(key)")
            XCTAssertThrowsError(try decode(["cmd": "response", "cid": 7, "&connectState": "connected", "&flowElement": fields]), "D252-C nonselected \(key)")
        }
        // With valid untyped object content, only properties validation rejects this frame.
        var propertiesOnly = flow
        propertiesOnly["properties"] = 123
        propertiesOnly["content"] = ["field": "FIXTURE-PAYLOAD"]
        XCTAssertThrowsError(try decode(["cmd": "response", "cid": 7, "&flowElement": propertiesOnly]), "D252-C properties independent content")
        for contentType in ["string", "base64", "dslv17", "experienceTemplate", "html", "httpRedirect", "rdf", "login", "object"] {
            var fields = flow
            fields["properties"] = ["type": "content", "contentType": contentType]
            fields["content"] = 123
            XCTAssertThrowsError(try decode(["cmd": "response", "&flowElement": fields]), "D252-C content \(contentType)")
        }
    }
    func testFlowProducerAndAbsentNullCompatibility() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var original = FlowElement(id: "FIXTURE-PAYLOAD", title: "FIXTURE-PAYLOAD", content: .string("FIXTURE-PAYLOAD"), properties: .init(type: .content, contentType: .string))
        original.topic = "FIXTURE-PAYLOAD"; original.origin = "FIXTURE-PAYLOAD"; original.hops = 3
        let bytes = try encoder.encode(original)
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(FlowElement.self, from: bytes)), bytes)
        for null in [false, true] {
            var fields = flow
            for key in ["topic", "origin", "hops"] { fields[key] = null ? NSNull() : nil }
            guard case .flowElement(let item) = try decode(["cmd": "response", "&flowElement": fields]).payload else { return XCTFail("flow") }
            XCTAssertEqual(item.topic, "*"); XCTAssertNil(item.origin); XCTAssertEqual(item.hops, 0)
            fields["properties"] = null ? NSNull() : nil; fields["content"] = [:] as [String: Any]
            guard case .flowElement(let untyped) = try decode(["cmd": "response", "&flowElement": fields]).payload else { return XCTFail("untyped") }
            XCTAssertNil(untyped.properties)
            fields["content"] = null ? NSNull() : nil
            guard case .flowElement(let missing) = try decode(["cmd": "response", "&flowElement": fields]).payload,
                  case .string(let text) = missing.content else { return XCTFail("legacy content") }
            XCTAssertEqual(text, "Decoding error")
        }
    }
}
