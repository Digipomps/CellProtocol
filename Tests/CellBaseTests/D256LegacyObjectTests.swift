import XCTest
@testable import CellBase

final class D256LegacyObjectTests: XCTestCase {
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

    private let objectTypes: [FlowElementContentType] = [.dslv17, .rdf, .html, .login, .experienceTemplate, .object]
    private func decode(_ payload: [String: Any]) throws -> BridgeCommand {
        try JSONDecoder().decode(BridgeCommand.self, from: JSONSerialization.data(
            withJSONObject: payload.merging(["cmd": "response", "cid": 7]) { a, _ in a }))
    }

    func testLegacyObjectRejectsMalformedMarkersAtEveryEntry() throws {
        let malformed: [String: Any] = ["&keyValue": 0, "data": 1, "bool": "FIXTURE-PAYLOAD",
            "integer": 1.5, "float": "FIXTURE-PAYLOAD", "&string": false,
            "&number": "FIXTURE-PAYLOAD", "&object": false, "&list": false,
            "&flowElement": 0, "&description": 0, "&agreementPayload": 0,
            "&cellConfiguration": 0, "&verifiableCredential": 0]
        for (marker, bad) in malformed {
            let legacy: [String: Any] = [marker: bad]
            let payloads: [[String: Any]] = [
                ["&object": legacy],
                ["&object": ["child": legacy]],
                ["&list": [["&object": legacy]]],
                ["&object": legacy, "&connectState": "connected"],
                ["&keyValue": ["key": "FIXTURE-PAYLOAD", "object": legacy]],
                ["&keyValue": ["key": "FIXTURE-PAYLOAD", "string": "selected", "object": legacy]],
                ["&object": ["&objectEntries": ["literal": ["type": "&object", "value": legacy]]]],
                ["&flowElement": ["id": "FIXTURE-PAYLOAD", "title": "FIXTURE-PAYLOAD", "content": legacy]]
            ]
            for (index, payload) in payloads.enumerated() {
                XCTAssertThrowsError(try decode(payload), "D256 legacy marker \(marker), entry \(index)")
            }
        }
    }

    func testTypedFlowObjectsRejectMalformedMarkers() throws {
        for type in objectTypes {
            for content in [["&keyValue": 0], ["data": 1]] as [[String: Any]] {
                XCTAssertThrowsError(try decode(["&flowElement": [
                    "id": "FIXTURE-PAYLOAD", "title": "FIXTURE-PAYLOAD",
                    "properties": ["type": "content", "contentType": type.rawValue],
                    "content": content]]), "D256 typed flow \(type)")
            }
        }
    }

    func testExplicitLiteralPropertiesRoundTripAcrossProducers() throws {
        let fields: Object = ["&keyValue": .integer(0), "data": .integer(1),
            "bool": .string("FIXTURE-PAYLOAD"), "integer": .float(1.0),
            "&objectEntries": .null, "nested": .object(["&keyValue": .integer(0)])]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var payloads: [ValueType] = [.object(fields), .list([.object(fields)]),
            .keyValue(KeyValue(key: "FIXTURE-PAYLOAD", value: .object(fields)))]
        for type in [nil] + objectTypes.map(Optional.some) {
            payloads.append(.flowElement(FlowElement(id: "FIXTURE-PAYLOAD", title: "FIXTURE-PAYLOAD",
                content: .object(fields), properties: type.map { .init(type: .content, contentType: $0) })))
        }
        for payload in payloads {
            let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: payload, cid: 7))
            do {
                let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
                let result: Object
                switch decoded.payload {
                case .object(let value): result = value
                case .list(let value):
                    guard case .object(let item) = value.first else { return XCTFail("D256 list variant") }
                    result = item
                case .keyValue(let value):
                    guard case .object(let item) = value.value else { return XCTFail("D256 KeyValue variant") }
                    result = item
                case .flowElement(let value):
                    guard case .object(let item) = value.content else { return XCTFail("D256 flow variant") }
                    result = item
                default: return XCTFail("D256 Object variant")
                }
                XCTAssertEqual(result["&keyValue"], .integer(0))
                XCTAssertEqual(result["data"], .integer(1))
                XCTAssertEqual(result["bool"], .string("FIXTURE-PAYLOAD"))
                guard case .float(1.0) = result["integer"], case .null = result["&objectEntries"],
                      case .object(let nested) = result["nested"] else { return XCTFail("D256 explicit variants") }
                XCTAssertEqual(nested["&keyValue"], .integer(0))
                XCTAssertEqual(try encoder.encode(decoded), bytes)
            } catch { XCTFail("D256 explicit producer rejected: \(error)") }
        }
    }

    func testLegacyValidNullAndUnknownPropertiesRemainCompatible() throws {
        let decoded = try decode(["&object": ["&keyValue": ["key": "FIXTURE-PAYLOAD", "integer": 7],
            "data": "AQI=", "bool": true, "integer": 7, "float": 1.0,
            "&number": 7, "future": ["arbitrary": true], "&object": NSNull()]])
        guard case .object(let fields) = decoded.payload,
              case .keyValue(let kv) = fields["&keyValue"], case .data(let data) = fields["data"],
              case .float(1.0) = fields["float"], case .number(7) = fields["&number"],
              case .object(let future) = fields["future"], case .null = fields["&object"]
        else { return XCTFail("D256 valid legacy variants") }
        XCTAssertEqual(kv.value, .integer(7)); XCTAssertEqual(data, Data([1, 2]))
        XCTAssertEqual(fields["bool"], .bool(true)); XCTAssertEqual(future["arbitrary"], .bool(true))
        for object in [[:], ["&keyValue": NSNull(), "data": NSNull()]] as [[String: Any]] {
            XCTAssertNotNil(try decode(["&object": object]).payload)
        }
    }
}
