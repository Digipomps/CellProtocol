// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

import Foundation
import XCTest
@testable import CellBase

// purposeRef: purpose://candidate.tillitspakke-agentflaate.projeksjon
final class AgentTrustPackageTests: XCTestCase {
    private typealias Canonical = AgentTrustPackageCanonicalEncoder

    func testIdenticalInputProducesIdenticalCanonicalBytesAndDigest() throws {
        let first = try fixture()
        let second = try fixture()
        XCTAssertEqual(try Canonical.canonicalBytes(for: first), try Canonical.canonicalBytes(for: second))
        XCTAssertEqual(try Canonical.digest(for: first), try Canonical.digest(for: second))
        XCTAssertEqual(
            try Canonical.digest(for: first),
            try PurposeBindingDigest.sha256(
                domain: "haven.agent-trust-package.v0", components: [Canonical.canonicalBytes(for: first)]
            )
        )
    }

    func testOneTemplateGrantPermissionChangeChangesDigest() throws {
        let original = try fixture()
        var changed = original
        changed.cells[0].templateGrants?[0].permission = "r---"
        XCTAssertNotEqual(try Canonical.digest(for: original), try Canonical.digest(for: changed))
    }

    func testFixtureRoundTripWritesCopyWithComputedDigest() throws {
        let source = try Data(contentsOf: fixtureDirectory.appendingPathComponent("fleet-webfetch.package.json"))
        var package = try JSONDecoder().decode(AgentTrustPackage.self, from: source)
        XCTAssertEqual(package.schema, AgentTrustPackage.schemaV0)
        XCTAssertEqual(package.cells.count, 3)
        XCTAssertEqual(package.reach, .fixtureReference)
        package.packageDigest = try Canonical.digest(for: package)
        // Independent Python hashlib/json reference: 2180 canonical UTF-8 bytes,
        // domain + NUL + UInt64 big-endian byte length + canonical JSON.
        XCTAssertEqual(package.packageDigest, "sha256:d6e82deda41dce717cae5f971b347ed7a50a3ffc1b71eac4ef7c04cad97209ea")
        let encoded = try Canonical.encode(package)
        let decoded = try JSONDecoder().decode(AgentTrustPackage.self, from: encoded)
        XCTAssertEqual(package, decoded)
        XCTAssertEqual(package.packageDigest, try Canonical.digest(for: decoded))

        // Compare all fixture fields, including omitted optionals and the reach
        // reference, so this test cannot silently replace the supplied fixture.
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        expected["packageDigest"] = package.packageDigest
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-webfetch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try encoded.write(to: destination, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: destination), encoded)
    }

    func testContractReachArrayRoundTripsAndBindsItsContents() throws {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("fleet-webfetch.reach.json"))
        var entries = try JSONDecoder().decode([AgentTrustPackage.ReachEntry].self, from: data)
        var package = try fixture()
        package.reach = .entries(entries)
        XCTAssertEqual(try JSONDecoder().decode(AgentTrustPackage.self, from: Canonical.encode(package)), package)
        let digest = try Canonical.digest(for: package)
        entries[0].credentials = true
        package.reach = .entries(entries)
        XCTAssertNotEqual(try Canonical.digest(for: package), digest)
    }

    func testOmittedCellDetailsRemainAbsent() throws {
        let package = AgentTrustPackage(
            fleetID: "fixture", generatedAt: "2026-09-08T10:12:00Z",
            cells: [.init(id: "service", endpoint: "cell:///Service", role: .service)],
            edges: [], reach: .entries([])
        )
        let encoded = try Canonical.encode(package)
        XCTAssertEqual(try JSONDecoder().decode(AgentTrustPackage.self, from: encoded), package)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let cells = try XCTUnwrap(object["cells"] as? [[String: Any]])
        XCTAssertEqual(Set(cells[0].keys), ["id", "endpoint", "role"])
    }

    func testPackageDigestIsExcludedButOtherFieldsAndArrayOrderAreBound() throws {
        var package = try fixture()
        let original = try Canonical.digest(for: package)
        package.packageDigest = "sha256:replacement"
        XCTAssertEqual(try Canonical.digest(for: package), original)
        let bytes = try Canonical.canonicalBytes(for: package)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["packageDigest"])
        package.cells[0].modelRoute?.baseURLDigest = "sha256:changed-route"
        XCTAssertNotEqual(try Canonical.digest(for: package), original)
        package = try fixture()
        package.cells.reverse()
        XCTAssertNotEqual(try Canonical.digest(for: package), original)
    }

    func testCanonicalKeysAreSortedCompactAndSlashesUnescaped() throws {
        var first = [String: String]()
        first["z"] = "a b"
        first["a"] = "cell:///WebFetch"
        var second = [String: String]()
        second["a"] = "cell:///WebFetch"
        second["z"] = "a b"
        let bytes = try Canonical.encode(first)
        XCTAssertEqual(bytes, try Canonical.encode(second))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"a":"cell:///WebFetch","z":"a b"}"#)
    }

    func testSecretGuardRejectsAPIKeyObject() {
        // Deliberately synthetic pattern, not a credential.
        assertRejection(["apiKey": "sk-abc-fixture-only"], .forbiddenField)
    }

    func testSecretGuardRejectsForbiddenNamesRecursivelyAndCaseInsensitively() {
        for field in ["apiKey", "SECRETRef", "accessToken", "passwordHash", "systemPrompt", "apiKeypath"] {
            assertRejection(["cells": [[field: "fixture"]]], .forbiddenField)
        }
    }

    func testSecretGuardRejectsEachValuePatternEvenUnderKeypath() {
        // All values are synthetic, generated solely to exercise rejection.
        for value in [
            "prefix sk-abc-fixture-only suffix", "prefix AKIA-fixture-only",
            "-----BEGIN FIXTURE-----", String(repeating: "A", count: 41),
            String(repeating: "B", count: 42) + "=="
        ] {
            assertRejection(["cells": [["keypath": value]]], .secretLikeValue)
        }
    }

    func testKeypathAndNonSecretReferenceValuesPass() throws {
        let object = [
            "keypath": "cell:///AssistantPersona#persona.text",
            "KEYPATH": "credentials", "digest": "sha256:" + String(repeating: "a", count: 64),
            "short": String(repeating: "A", count: 40),
            "summary": String(repeating: "A", count: 41) + " with spaces"
        ]
        XCTAssertNoThrow(try Canonical.encode(object))
        XCTAssertNoThrow(try Canonical.encode(fixture()))
    }

    func testPlainJSONEncoderAndDigestCannotBypassPackageSecretGuard() throws {
        var package = try fixture()
        package.cells[0].instruction?.digest = "sk-abc-fixture-only"
        XCTAssertThrowsError(try JSONEncoder().encode(package)) { error in
            XCTAssertEqual(error as? Canonical.ValidationError, .secretLikeValue)
        }
        XCTAssertThrowsError(try Canonical.digest(for: package))
        package = try fixture()
        package.packageDigest = "sk-abc-fixture-only"
        // Exclusion from hashing must not bypass validation of exported data.
        XCTAssertThrowsError(try Canonical.digest(for: package))
    }

    func testDatesNormalizeToUTCWithoutLosingFractionalPrecision() throws {
        var offset = try fixture()
        offset.generatedAt = "2026-09-08T12:12:00.1234567890+02:00"
        offset.cells[0].contracts?[0].expiresAt = "2026-12-31T02:00:00+02:00"
        var utc = try fixture()
        utc.generatedAt = "2026-09-08T10:12:00.123456789Z"
        XCTAssertEqual(try Canonical.digest(for: offset), try Canonical.digest(for: utc))
        let decoded = try JSONDecoder().decode(AgentTrustPackage.self, from: Canonical.encode(offset))
        XCTAssertEqual(decoded.generatedAt, utc.generatedAt)
        XCTAssertEqual(decoded.cells[0].contracts?[0].expiresAt, "2026-12-31T00:00:00Z")
        utc.generatedAt = "2026-09-08T10:12:00.123456788Z"
        XCTAssertNotEqual(try Canonical.digest(for: offset), try Canonical.digest(for: utc))
    }

    func testInvalidDatesUnknownSchemaAndUnknownReachReferenceFailClosed() throws {
        for timestamp in ["2026-09-08", "2026-02-31T10:12:00Z", "2026-09-08T10:12:00-00:00", "fixture"] {
            var package = try fixture()
            package.generatedAt = timestamp
            XCTAssertThrowsError(try Canonical.encode(package)) { error in
                XCTAssertEqual(error as? Canonical.ValidationError, .invalidTimestamp)
            }
        }
        var package = try fixture()
        package.cells[0].contracts?[0].expiresAt = "fixture"
        XCTAssertThrowsError(try Canonical.encode(package))
        package = try fixture()
        package.schema = "haven.agent-trust-package.unknown"
        XCTAssertThrowsError(try Canonical.encode(package)) { error in
            XCTAssertEqual(error as? Canonical.ValidationError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(AgentTrustPackage.Reach.self, from: Data(#""unknown""#.utf8)))
    }

    private func assertRejection<T: Encodable>(
        _ value: T, _ expected: Canonical.ValidationError, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try Canonical.encode(value), file: file, line: line) { error in
            XCTAssertEqual(error as? Canonical.ValidationError, expected, file: file, line: line)
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }

    private func fixture() throws -> AgentTrustPackage {
        try JSONDecoder().decode(
            AgentTrustPackage.self,
            from: Data(contentsOf: fixtureDirectory.appendingPathComponent("fleet-webfetch.package.json"))
        )
    }

    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AgentTrustPackage")
    }
}
