import XCTest
@testable import CellBase

final class D252ObjectCompatibilityTests: XCTestCase {
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

    func testExplicitMalformedEntriesAreRejected() throws {
        for record in [
            ["type": "bool", "value": 1], ["type": "&number", "value": false],
            ["type": "null", "value": 1], ["type": "null"],
            ["type": "&list", "value": false], ["type": "future-type", "value": 1]
        ] as [[String: Any]] {
            let frame: [String: Any] = ["cmd": "response", "cid": 7,
                "&object": ["&objectEntries": ["data": record]]]
            XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self,
                from: JSONSerialization.data(withJSONObject: frame)), "D252-A invalid explicit value")
        }
        for fields in [["&objectEntries": false], ["&objectEntries": [:], "extra": 1]] as [[String: Any]] {
            let frame: [String: Any] = ["cmd": "response", "cid": 7, "&object": fields]
            XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self,
                from: JSONSerialization.data(withJSONObject: frame)), "D252-A invalid explicit Object")
        }
    }

    func testReservedEnvelopeNameWithNullRoundTripsInObjectAndList() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fields: Object = ["&objectEntries": .null]
        for payload in [ValueType.object(fields), .list([.object(fields)])] {
            let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: payload, cid: 7))
            do {
                let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
                let result: Object
                switch decoded.payload {
                case .object(let value): result = value
                case .list(let values):
                    guard case .object(let value) = values.first else {
                        XCTFail("D252-A reserved null list must retain Object variant")
                        continue
                    }
                    result = value
                default:
                    XCTFail("D252-A reserved null must retain payload variant")
                    continue
                }
                XCTAssertEqual(result.count, 1, "D252-A reserved null property is retained")
                XCTAssertEqual(result["&objectEntries"], .null)
                XCTAssertEqual(try encoder.encode(decoded), bytes)
            } catch {
                XCTFail("D252-A reserved null Object rejected: \(error)")
            }
        }
    }
}
