import XCTest
@testable import CellBase

final class D252StructuredPayloadTests: XCTestCase {
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func fixtures() async throws -> [(String, [String: Any], [String: Any])] {
        let agreement = await Agreement()
        let description = AnyCell(uuid: "FIXTURE-PAYLOAD", name: "FIXTURE-PAYLOAD",
            contractTemplate: agreement, identityDomain: "FIXTURE-PAYLOAD")
        let credential = VCClaim(issuerIdentity: Identity(), subjectIdentity: Identity(), credentialSubject: [:])
        return [
            ("&description", try object(description), ["uuid": 17, "owner": 17, "experiences": 17, "feedProperties": 17]),
            ("&cellConfiguration", ["uuid": "FIXTURE-PAYLOAD", "name": "FIXTURE-PAYLOAD"], ["uuid": 17]),
            ("&agreementPayload", try object(agreement), ["timestamp": "FIXTURE-PAYLOAD", "state": 17]),
            ("&verifiableCredential", try object(credential), ["@context": 17])
        ]
    }
    private func decode(_ marker: String, _ payload: [String: Any], nonselected: Bool = false) throws -> BridgeCommand {
        var frame: [String: Any] = ["cmd": "response", "cid": 7, marker: payload]
        if nonselected { frame["&agreementPayload"] = ["name": "FIXTURE-PAYLOAD", "owner": try object(Identity())] }
        return try JSONDecoder().decode(BridgeCommand.self, from: JSONSerialization.data(withJSONObject: frame))
    }
    func testStructuredPayloadRejectsMalformedPresentFields() async throws {
        for (marker, base, fields) in try await fixtures() {
            // Validate each complete producer fixture before deriving a negative.
            XCTAssertNotNil(try decode(marker, base).payload)
            for (field, bad) in fields {
                var payload = base; payload[field] = bad
                XCTAssertThrowsError(try decode(marker, payload), "D252-C \(marker).\(field)")
                if marker != "&agreementPayload" {
                    XCTAssertThrowsError(try decode(marker, payload, nonselected: true), "D252-C nonselected \(marker).\(field)")
                }
            }
        }
    }
    func testStructuredPayloadAbsentNullAndUnknownCompatibility() async throws {
        for (marker, base, fields) in try await fixtures() {
            for field in fields.keys {
                for useNull in [false, true] {
                    var payload = base; payload[field] = useNull ? NSNull() : nil
                    payload["future-field"] = ["arbitrary": 123]
                    XCTAssertNotNil(try decode(marker, payload).payload, "D252-C compatibility \(marker).\(field)")
                }
            }
        }
    }
}

extension D252StructuredPayloadTests {
    func testAgreementStateTypeAndUnknownStringCompatibility() async throws {
        let agreement = await Agreement()
        var fields = try object(agreement)
        fields["state"] = 17
        XCTAssertThrowsError(try decode("&agreementPayload", fields), "D252-C state wrong JSON type")
        for state in ["future-state", "template"] {
            fields["state"] = state
            XCTAssertNotNil(try decode("&agreementPayload", fields).payload)
        }
    }
}
