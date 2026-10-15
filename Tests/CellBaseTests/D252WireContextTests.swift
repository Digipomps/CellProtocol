import XCTest
@testable import CellBase

final class D252WireContextTests: XCTestCase {
    func testObjectMarkerNamesRoundTrip() throws {
        let object: Object = ["data": .object(["type": .string("data")]),
            "bool": .string("FIXTURE-PAYLOAD"), "integer": .float(1.5), "float": .string("FIXTURE-PAYLOAD")]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for payload in [ValueType.object(object), .list([.object(object)])] {
            let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: payload, cid: 7))
            do {
                let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
                XCTAssertEqual(try encoder.encode(decoded), bytes)
                let result: Object
                switch decoded.payload {
                case .object(let fields): result = fields
                case .list(let fields):
                    guard case .object(let item) = fields.first else { return XCTFail("D252-A list object variant") }
                    result = item
                default: return XCTFail("D252-A payload variant")
                }
                guard case .object(let data) = result["data"] else { return XCTFail("D252-A data is an Object property") }
                XCTAssertEqual(data["type"], .string("data"))
                XCTAssertEqual(result["bool"], .string("FIXTURE-PAYLOAD"))
                XCTAssertEqual(result["integer"], .float(1.5))
                XCTAssertEqual(result["float"], .string("FIXTURE-PAYLOAD"))
            } catch { XCTFail("D252-A legal Object rejected: \(error)") }
        }
    }
    func testExplicitObjectListEncodingDiffersFromRejectedLegacyInput() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let command = BridgeCommand(cmd: "response", payload: .list([.object(["data": .integer(1)])]), cid: 7)
        let encoded = try encoder.encode(command)
        let legacy = try JSONSerialization.data(withJSONObject: ["cmd": "response", "cid": 7, "&list": [["data": 1]]], options: [.sortedKeys])
        XCTAssertNotEqual(encoded, legacy, "D252-A explicit Object must distinguish the preserved negative fixture")
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self, from: legacy))
    }
    func testWireMarkerStillRejectsWrongType() throws {
        let raw = Data(#"{"cmd":"response","cid":7,"data":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeCommand.self, from: raw))
    }
}

extension D252WireContextTests {
    func testActualFileCryptoExploreManifestRoundTrip() async throws {
        let previous = CellBase.defaultIdentityVault
        defer { CellBase.defaultIdentityVault = previous }
        let vault = EphemeralIdentityVault()
        CellBase.defaultIdentityVault = vault
        let owner = await vault.identity(for: "private", makeNewIfNotFound: true)!
        let cell = await FileCryptoCell(owner: owner)
        let description = try await cell.advertise(for: owner)
        // Identity's existing decoder materializes absent properties as {}.
        // Normalize only that unrelated DTO default before byte-exact comparison.
        description.owner?.properties = [:]
        description.agreementTemplate.owner.properties = [:]
        for identity in description.agreementTemplate.signatories { identity.properties = [:] }
        let manifest = try XCTUnwrap(description.exploreManifest)
        XCTAssertFalse(manifest.operations.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: .description(description), cid: 7))
        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
        guard case .description(let result) = decoded.payload else { return XCTFail("D252-A Explore description variant") }
        XCTAssertNotNil(result.exploreManifest)
        XCTAssertEqual(try encoder.encode(result.exploreManifest), try encoder.encode(description.exploreManifest))
        let reencoded = try encoder.encode(decoded)
        func differences(_ a: Any, _ b: Any, _ path: String) {
            if let a = a as? [String: Any], let b = b as? [String: Any] {
                for key in Set(a.keys).union(b.keys).sorted() { differences(a[key] ?? "<absent>", b[key] ?? "<absent>", path + "." + key) }
            } else if let a = a as? [Any], let b = b as? [Any], a.count == b.count {
                for i in a.indices { differences(a[i], b[i], path + "[\(i)]") }
            } else if String(describing: a) != String(describing: b) {
                print("D252 fixture difference \(path): \(a) -> \(b)")
            }
        }
        if reencoded != bytes { differences(try JSONSerialization.jsonObject(with: bytes), try JSONSerialization.jsonObject(with: reencoded), "frame") }
        XCTAssertEqual(reencoded, bytes)
    }
    func testObjectPreservesPrimitiveVariantsAndReservedEntryName() throws {
        let fields: Object = ["data": .data(Data([1,2])), "number": .number(7), "float": .float(1.0),
            "integer": .integer(7), "bool": .bool(true), "&objectEntries": .string("FIXTURE-PAYLOAD"),
            "list": .list([.number(7), .float(1.0), .data(Data([1,2]))])]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(BridgeCommand(cmd: "response", payload: .object(fields), cid: 7))
        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: bytes)
        guard case .object(let result) = decoded.payload,
              case .data(let data) = result["data"], case .number(7) = result["number"],
              case .float(1.0) = result["float"], case .integer(7) = result["integer"],
              case .bool(true) = result["bool"], case .list(let list) = result["list"],
              case .number(7) = list[0], case .float(1.0) = list[1], case .data(let item) = list[2]
        else { return XCTFail("D252-A exact primitive variants") }
        XCTAssertEqual(data, Data([1,2])); XCTAssertEqual(item, data)
        XCTAssertEqual(result["&objectEntries"], .string("FIXTURE-PAYLOAD"))
        XCTAssertEqual(try encoder.encode(decoded), bytes)
    }
}
