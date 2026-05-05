// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

final class SerializationTests: XCTestCase {
    private func decodeJSONObject(_ data: Data, file: StaticString = #file, line: UInt = #line) -> [String: Any] {
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = obj as? [String: Any] else {
                XCTFail("Expected top-level JSON object", file: file, line: line)
                return [:]
            }
            return dict
        } catch {
            XCTFail("JSON decode failed: \(error)", file: file, line: line)
            return [:]
        }
    }

    func testValueTypeDecodesPrimitives() throws {
        let boolValue = try JSONDecoder().decode(ValueType.self, from: Data("true".utf8))
        XCTAssertEqual(boolValue, .bool(true))

        let intValue = try JSONDecoder().decode(ValueType.self, from: Data("1".utf8))
        XCTAssertEqual(intValue, .integer(1))

        let floatValue = try JSONDecoder().decode(ValueType.self, from: Data("1.5".utf8))
        XCTAssertEqual(floatValue, .float(1.5))

        let stringValue = try JSONDecoder().decode(ValueType.self, from: Data("\"hi\"".utf8))
        XCTAssertEqual(stringValue, .string("hi"))

        let nullValue = try JSONDecoder().decode(ValueType.self, from: Data("null".utf8))
        XCTAssertEqual(nullValue, .null)
    }

    func testValueTypeEncodesAndDecodesObjectAndList() throws {
        let object: Object = [
            "name": .string("Alice"),
            "age": .integer(30)
        ]
        let list: ValueTypeList = [.string("a"), .integer(2)]
        let value = ValueType.object(object)
        let listValue = ValueType.list(list)

        let encodedObject = try JSONEncoder().encode(value)
        let decodedObject = try JSONDecoder().decode(ValueType.self, from: encodedObject)
        if case let .object(decoded) = decodedObject {
            XCTAssertEqual(decoded["name"], .string("Alice"))
        } else {
            XCTFail("Expected object value")
        }

        let encodedList = try JSONEncoder().encode(listValue)
        let decodedList = try JSONDecoder().decode(ValueType.self, from: encodedList)
        if case let .list(decoded) = decodedList {
            XCTAssertEqual(decoded.count, 2)
        } else {
            XCTFail("Expected list value")
        }
    }

    func testValueTypeObjectEncodingKeepsCanonicalJSONShape() throws {
        let object: Object = [
            "name": .string("Alice"),
            "age": .integer(30)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(ValueType.object(object))

        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"age":30,"name":"Alice"}"#)
    }

    func testValueTypeObjectIdentityIsDeterministicForSameObjectShape() {
        let first = ValueType.object(["name": .string("Alice"), "age": .integer(30)])
        let second = ValueType.object(["age": .integer(30), "name": .string("Alice")])

        XCTAssertEqual(first.id, second.id)
    }

    func testValueTypeConnectContextHashDoesNotRequireIdentity() {
        let value = ValueType.connectContext(ConnectContext(source: nil, target: nil, identity: nil))

        XCTAssertEqual(value.id, value.hashValue)
    }

    func testFlowElementStringRoundTrip() throws {
        let properties = FlowElement.Properties(type: .content, contentType: .string)
        let element = FlowElement(
            id: "flow-1",
            title: "title",
            content: .string("hello"),
            properties: properties
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(FlowElement.self, from: data)
        XCTAssertEqual(decoded.id, "flow-1")
        XCTAssertEqual(decoded.title, "title")
        XCTAssertEqual(decoded.properties?.contentType, .string)
        if case let .string(value) = decoded.content {
            XCTAssertEqual(value, "hello")
        } else {
            XCTFail("Expected string content")
        }
    }

    func testFlowElementBase64RoundTrip() throws {
        let properties = FlowElement.Properties(type: .content, contentType: .base64)
        let element = FlowElement(
            id: "flow-2",
            title: "title",
            content: .data(Data([0x01, 0x02, 0x03])),
            properties: properties
        )
        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(FlowElement.self, from: data)
        if case let .data(value) = decoded.content {
            XCTAssertEqual(value, Data([0x01, 0x02, 0x03]))
        } else {
            XCTFail("Expected data content")
        }
    }

    func testKeyValueEncodesTypedField() throws {
        let kv = KeyValue(key: "example", value: .string("hello"))
        let data = try JSONEncoder().encode(kv)
        let json = decodeJSONObject(data)
        XCTAssertNotNil(json["string"])
        XCTAssertNil(json["value"])
    }

    func testKeyValueRoundTripPreservesExplicitNullValue() throws {
        let kv = KeyValue(key: "syncScaffoldPurposeGoals", value: .null)
        let data = try JSONEncoder().encode(kv)
        let json = decodeJSONObject(data)

        XCTAssertTrue(json.keys.contains("value"))
        XCTAssertTrue(json["value"] is NSNull)

        let decoded = try JSONDecoder().decode(KeyValue.self, from: data)
        XCTAssertEqual(decoded.key, "syncScaffoldPurposeGoals")
        XCTAssertEqual(decoded.value, .null)
    }

    func testKeyValueFallsBackToGenericValueEncodingForBool() throws {
        let kv = KeyValue(key: "enabled", value: .bool(true))
        let data = try JSONEncoder().encode(kv)
        let json = decodeJSONObject(data)

        XCTAssertNil(json["string"])
        XCTAssertEqual(json["value"] as? Bool, true)

        let decoded = try JSONDecoder().decode(KeyValue.self, from: data)
        XCTAssertEqual(decoded.key, "enabled")
        XCTAssertEqual(decoded.value, .bool(true))
    }

    func testKeyValueDecodeKeepsLegacyTypedFieldPriority() throws {
        let data = Data(#"{"key":"priority","string":"hello","integer":42}"#.utf8)

        let decoded = try JSONDecoder().decode(KeyValue.self, from: data)

        XCTAssertEqual(decoded.value, .string("hello"))
    }

    func testCellConfigurationDecodeFixture() throws {
        let data = TestFixtures.loadJSON(named: "CellConfigurationMinimal.json")
        let config = try JSONDecoder().decode(CellConfiguration.self, from: data)
        XCTAssertEqual(config.name, "Test Config")
        XCTAssertEqual(config.cellReferences?.count, 1)
        let ref = config.cellReferences?.first
        XCTAssertEqual(ref?.endpoint, "cell:///Example")
        XCTAssertEqual(ref?.label, "example")
        XCTAssertEqual(ref?.setKeysAndValues.count, 1)
        if let kv = ref?.setKeysAndValues.first {
            XCTAssertEqual(kv.key, "example.set")
            if case let .string(value)? = kv.value {
                XCTAssertEqual(value, "hello")
            } else {
                XCTFail("Expected string value in KeyValue")
            }
        }
        if case .Text = config.skeleton {
            // ok
        } else {
            XCTFail("Expected Text skeleton")
        }
    }

    func testCellConfigurationEncodesSkeletonKey() throws {
        var config = CellConfiguration(name: "Config")
        config.skeleton = .Text(SkeletonText(text: "Hello"))
        let data = try JSONEncoder().encode(config)
        let json = decodeJSONObject(data)
        XCTAssertNotNil(json["skeleton"])
    }

    func testCellConfigurationRoundTripIncludesDiscoveryMetadata() throws {
        var config = CellConfiguration(name: "RAG Gateway Workspace")
        config.description = "Case-aware workspace"
        config.discovery = CellConfigurationDiscovery(
            sourceCellEndpoint: "cell:///RAGGateway",
            sourceCellName: "RAGGatewayCell",
            purpose: "Domenespesifikk RAG-utforskning",
            purposeDescription: "Case-aware RAG for sporsmal, sitater, corpus-utforskning og dokumentlenker.",
            interests: ["rag", "documentation", "prompts"],
            purposeRefs: ["purpose.research"],
            interestRefs: ["interest.ai", "interest.documentation"],
            menuSlots: ["upperLeft", "upperMid"],
            localizedText: [
                "en-US": CellConfigurationDiscoveryLocalization(
                    purpose: "Domain-specific RAG exploration",
                    purposeDescription: "Case-aware RAG for questions, quotes, corpus exploration and document links.",
                    interests: ["rag", "documentation", "prompts"]
                )
            ]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CellConfiguration.self, from: data)

        XCTAssertEqual(decoded.discovery?.sourceCellEndpoint, "cell:///RAGGateway")
        XCTAssertEqual(decoded.discovery?.sourceCellName, "RAGGatewayCell")
        XCTAssertEqual(decoded.discovery?.purpose, "Domenespesifikk RAG-utforskning")
        XCTAssertEqual(decoded.discovery?.interests, ["rag", "documentation", "prompts"])
        XCTAssertEqual(decoded.discovery?.purposeRefs, ["purpose.research"])
        XCTAssertEqual(decoded.discovery?.interestRefs, ["interest.ai", "interest.documentation"])
        XCTAssertEqual(decoded.discovery?.menuSlots, ["upperLeft", "upperMid"])
        XCTAssertEqual(decoded.discovery?.localizedText["en-US"]?.purpose, "Domain-specific RAG exploration")
    }

    func testCellConfigurationDiscoveryDecodesLegacyPayloadWithoutSemanticRefs() throws {
        let data = Data(
            """
            {
              "sourceCellEndpoint": "cell:///Legacy",
              "sourceCellName": "LegacyCell",
              "purpose": "Legacy purpose",
              "interests": ["legacy"],
              "menuSlots": ["upperLeft"]
            }
            """.utf8
        )

        let discovery = try JSONDecoder().decode(CellConfigurationDiscovery.self, from: data)

        XCTAssertEqual(discovery.sourceCellEndpoint, "cell:///Legacy")
        XCTAssertEqual(discovery.interests, ["legacy"])
        XCTAssertTrue(discovery.purposeRefs.isEmpty)
        XCTAssertTrue(discovery.interestRefs.isEmpty)
        XCTAssertTrue(discovery.localizedText.isEmpty)
    }

    func testCellConfigurationDecodesWithoutDiscoveryKey() throws {
        let data = TestFixtures.loadJSON(named: "CellConfigurationMinimal.json")
        let config = try JSONDecoder().decode(CellConfiguration.self, from: data)
        XCTAssertNil(config.discovery)
    }

    func testPurposeRoundTripIncludesGoalAndHelperCells() throws {
        var goal = CellConfiguration(name: "Resolve Goal")
        goal.description = "Tracks whether the goal is complete"

        var autoHelper = CellConfiguration(name: "Auto Helper")
        autoHelper.description = "Can fix the issue automatically"

        var guideHelper = CellConfiguration(name: "Guide Helper")
        guideHelper.description = "Shows instructions to the user"

        let purpose = Purpose(
            name: "Community Support",
            description: "Improve local football participation",
            goal: goal,
            helperCells: [autoHelper, guideHelper]
        )

        let data = try JSONEncoder().encode(purpose)
        let decoded = try JSONDecoder().decode(Purpose.self, from: data)

        let decodedGoal = try decoded.getGoal()
        XCTAssertEqual(decodedGoal.name, "Resolve Goal")

        let helpers = try decoded.getHelpers()
        XCTAssertEqual(helpers.count, 2)
        XCTAssertEqual(helpers[0].name, "Auto Helper")
        XCTAssertEqual(helpers[1].name, "Guide Helper")
    }

    func testPurposeDecodesWithoutHelperCellsKey() throws {
        let purpose = Purpose(name: "No Helper Field", description: "Backwards compatibility test")
        let encoded = try JSONEncoder().encode(purpose)

        var json = decodeJSONObject(encoded)
        json.removeValue(forKey: "helperCells")
        let modifiedData = try JSONSerialization.data(withJSONObject: json, options: [])

        let decoded = try JSONDecoder().decode(Purpose.self, from: modifiedData)
        let helpers = try decoded.getHelpers()
        XCTAssertTrue(helpers.isEmpty)
    }
}
