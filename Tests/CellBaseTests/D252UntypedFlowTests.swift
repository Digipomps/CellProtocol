import XCTest
@testable import CellBase

final class D252UntypedFlowTests: XCTestCase {
    // Loopback D252E/D256 wire format is opt-in on main; these tests exercise it.
    private var previousObjectWireFormat = CellBase.ObjectWireFormat.legacyInference
    override func setUp() {
        super.setUp()
        previousObjectWireFormat = CellBase.objectWireFormat
        CellBase.objectWireFormat = .explicitEntries
    }
    override func tearDown() {
        CellBase.objectWireFormat = previousObjectWireFormat
        super.tearDown()
    }

    func testProducerContentWithoutTypePreservesValues() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let variants: [FlowElementValueType] = [.string("FIXTURE-PAYLOAD"), .number(7), .bool(true),
            .object(["data": .integer(1)]), .list([.string("FIXTURE-PAYLOAD"), .object(["data": .integer(1)])])]
        for properties in [nil, FlowElement.Properties(type: .content, contentType: nil)] {
            for content in variants {
                let original = FlowElement(id: "FIXTURE-PAYLOAD", title: "FIXTURE-PAYLOAD", content: content, properties: properties)
                let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: .flowElement(original), cid: 7))
                do {
                    let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
                    guard case .flowElement(let item) = decoded.payload else { return XCTFail("D252-C untyped flow variant") }
                    switch (content, item.content) {
                    case (.string(let a), .string(let b)): XCTAssertEqual(a, b)
                    case (.number(let a), .number(let b)): XCTAssertEqual(a, b)
                    case (.bool(let a), .bool(let b)): XCTAssertEqual(a, b)
                    case (.object(let a), .object(let b)): XCTAssertEqual(a["data"], b["data"])
                    case (.list(let a), .list(let b)): XCTAssertEqual(a.count, b.count)
                    default: XCTFail("D252-C untyped content variant changed")
                    }
                    XCTAssertEqual(try encoder.encode(decoded), bytes, "D252-C untyped content bytes")
                } catch { XCTFail("D252-C untyped producer rejected: \(error)") }
            }
        }
    }

    func testUntypedNestedFailuresStillPropagate() throws {
        let bad: [String: Any] = ["&keyValue": 0]
        for content in [["child": bad], [bad]] as [Any] {
            let fields: [String: Any] = ["cmd": "response", "cid": 7,
                "&flowElement": ["id": "FIXTURE-PAYLOAD", "title": "FIXTURE-PAYLOAD", "content": content]]
            XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self,
                from: JSONSerialization.data(withJSONObject: fields)), "D252-C untyped child error")
        }
    }
}
