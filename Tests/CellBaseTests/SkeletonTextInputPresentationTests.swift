// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import XCTest
@testable import CellBase

/// WP-S (PDD_butler-onboarding-og-formaalsforstaaelse_2026-09-23): `placeholderKeypath`, `secure` og
/// `secureKeypath` på `TextField` og `TextArea`.
/// Formål: Butler kan vise stegets spørsmål som plassholder og skjule en API-nøkkel mens den skrives,
/// uten at gamle konfigurasjoner endrer seg. Fixturen deles med CellScaffolds web-renderer.
final class SkeletonTextInputPresentationTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            var id: String
            var expectedPlaceholder: String
            var expectedSecure: Bool
        }
        var schema: String
        var cases: [Case]
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/skeleton-textinput/parity.v1.json")
    }

    /// Ren JSON → ValueType (ValueTypes egen Codable-form er ikke ren JSON). Linux-trygg: ingen CoreFoundation.
    private enum JSONValue: Decodable {
        case bool(Bool), integer(Int), float(Double), string(String), object([String: JSONValue]), list([JSONValue]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .float(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else { self = .list(try container.decode([JSONValue].self)) }
        }

        var valueType: ValueType {
            switch self {
            case .bool(let value): return .bool(value)
            case .integer(let value): return .integer(value)
            case .float(let value): return .float(value)
            case .string(let value): return .string(value)
            case .object(let value): return .object(value.mapValues { $0.valueType })
            case .list(let value): return .list(value.map { $0.valueType })
            case .null: return .null
            }
        }
    }

    private struct RawCase: Decodable {
        var data: JSONValue
    }

    private struct RawFixture: Decodable {
        var cases: [RawCase]
    }

    private func resolver(_ data: Object) -> (String) -> ValueType? {
        { keypath in
            guard let value = try? data.get(keypath: keypath) else { return nil }
            if case .null = value { return nil }
            return value
        }
    }

    func testParityFixtureDrivesBothTextFieldAndTextArea() throws {
        let data = try Data(contentsOf: fixtureURL())
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(fixture.schema, "haven.skeleton-textinput-parity.v1")
        let rawCases = try JSONDecoder().decode(RawFixture.self, from: data).cases
        XCTAssertGreaterThanOrEqual(rawCases.count, 10, "fixturen er for tynn til å si noe om paritet")
        let specs = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["cases"] as? [[String: Any]])

        for ((item, rawCase), specCase) in zip(zip(fixture.cases, rawCases), specs) {
            let specJSON = try JSONSerialization.data(withJSONObject: specCase["spec"] ?? [String: Any]())
            guard case let .object(state) = rawCase.data.valueType else {
                return XCTFail("\(item.id): data er ikke et objekt")
            }
            let resolve = resolver(state)

            let field = try JSONDecoder().decode(SkeletonTextField.self, from: specJSON)
            XCTAssertEqual(field.effectivePlaceholder(resolve: resolve), item.expectedPlaceholder, "\(item.id) TextField plassholder")
            XCTAssertEqual(field.isSecureInput(resolve: resolve), item.expectedSecure, "\(item.id) TextField secure")

            let area = try JSONDecoder().decode(SkeletonTextArea.self, from: specJSON)
            XCTAssertEqual(area.effectivePlaceholder(resolve: resolve), item.expectedPlaceholder, "\(item.id) TextArea plassholder")
            XCTAssertEqual(area.isSecureInput(resolve: resolve), item.expectedSecure, "\(item.id) TextArea secure")
        }
    }

    func testNewFieldsRoundTripUnderWrapperKeys() throws {
        let field = SkeletonElement.TextField(SkeletonTextField(
            targetKeypath: "draft",
            placeholder: "Skriv til Butler …",
            placeholderKeypath: "onboarding.prompt",
            secure: false,
            secureKeypath: "onboarding.secret"
        ))
        let area = SkeletonElement.TextArea(SkeletonTextArea(
            targetKeypath: "draft",
            placeholder: "Skriv til Butler …",
            submitOnEnter: true,
            submitActionKeypath: "assistant.send",
            placeholderKeypath: "onboarding.prompt",
            secure: true,
            secureKeypath: "onboarding.secret"
        ))
        for element in [field, area] {
            let data = try JSONEncoder().encode(element)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let inner = try XCTUnwrap((json["TextField"] ?? json["TextArea"]) as? [String: Any])
            XCTAssertEqual(inner["placeholderKeypath"] as? String, "onboarding.prompt")
            XCTAssertEqual(inner["secureKeypath"] as? String, "onboarding.secret")
            XCTAssertNotNil(inner["secure"])

            let decoded = try JSONDecoder().decode(SkeletonElement.self, from: data)
            switch decoded {
            case .TextField(let value):
                XCTAssertEqual(value.placeholderKeypath, "onboarding.prompt")
                XCTAssertEqual(value.secure, false)
                XCTAssertEqual(value.secureKeypath, "onboarding.secret")
            case .TextArea(let value):
                XCTAssertEqual(value.placeholderKeypath, "onboarding.prompt")
                XCTAssertEqual(value.secure, true)
                XCTAssertEqual(value.secureKeypath, "onboarding.secret")
                XCTAssertEqual(value.submitActionKeypath, "assistant.send")
            default:
                XCTFail("feil elementtype etter rundtur")
            }
        }
    }

    /// Regel 1 i kontrakten: gamle konfigurasjoner uten feltene dekoder og kodes uendret.
    func testConfigurationsWithoutNewFieldsAreUnchanged() throws {
        let legacy = """
        { "TextArea": { "targetKeypath": "draft", "placeholder": "Skriv til Butler …", "submitOnEnter": true } }
        """
        let element = try JSONDecoder().decode(SkeletonElement.self, from: Data(legacy.utf8))
        guard case let .TextArea(area) = element else { return XCTFail("forventet TextArea") }
        XCTAssertNil(area.placeholderKeypath)
        XCTAssertNil(area.secure)
        XCTAssertNil(area.secureKeypath)
        XCTAssertFalse(area.isSecureInput { _ in .bool(true) }, "uten secure/secureKeypath skal data ikke kunne skjule feltet")
        XCTAssertEqual(area.effectivePlaceholder { _ in .string("ignorert") }, "Skriv til Butler …")

        let reencoded = try JSONEncoder().encode(element)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let inner = try XCTUnwrap(json["TextArea"] as? [String: Any])
        XCTAssertEqual(Set(inner.keys), ["targetKeypath", "placeholder", "submitOnEnter"], "ingen nye nøkler skal dukke opp i gamle konfigurasjoner")
    }

    func testLocalizedFallbackIsUsedWhenKeypathIsEmpty() {
        let field = SkeletonTextField(placeholder: "Write to Butler …", placeholderKeypath: "onboarding.prompt")
        XCTAssertEqual(field.effectivePlaceholder(fallback: "Skriv til Butler …") { _ in .string("") }, "Skriv til Butler …")
        XCTAssertEqual(field.effectivePlaceholder(fallback: "Skriv til Butler …") { _ in .string("Steg 2") }, "Steg 2")
    }
}
