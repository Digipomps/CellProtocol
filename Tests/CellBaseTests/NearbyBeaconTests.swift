import XCTest
@testable import CellApple
@testable import CellBase

final class NearbyBeaconTests: XCTestCase {
    private var savedDomains = Set<CellBase.DiagnosticLogDomain>()
    private var savedHandler: ((CellBase.DiagnosticLogDomain, String) -> Void)?

    override func setUp() {
        super.setUp()
        savedDomains = CellBase.enabledDiagnosticLogDomains
        savedHandler = CellBase.diagnosticLogHandler
    }

    override func tearDown() {
        CellBase.enabledDiagnosticLogDomains = savedDomains
        CellBase.diagnosticLogHandler = savedHandler
        super.tearDown()
    }

    func testPortableReferenceAndTokenAreDeterministicAcrossDevices() {
        let firstReference = PortableReference.make(
            kind: "purpose",
            localReference: nil,
            name: "Klimatílpasning"
        )
        let secondReference = PortableReference.make(
            kind: "purpose",
            localReference: "purpose://klimatilpasning",
            name: nil
        )

        XCTAssertEqual(firstReference, "purpose://klimatilpasning")
        XCTAssertEqual(firstReference, secondReference)
        XCTAssertEqual(firstReference.map(NearbyBeacon.token(forCanonicalReference:)), "29f362d8")
    }

    func testPortableReferencePreservesExistingNordicSlugifyContract() {
        XCTAssertEqual(PortableReference.slugify("ÆØÅ"), "a")
        XCTAssertEqual(PortableReference.slugify("Blåbærgrød i Ærø"), "blab-rgr-d-i-r")
        XCTAssertEqual(PortableReference.slugify("  Crème brûlée  "), "creme-brulee")
    }

    func testEncodingDropsInterestTailThenPurposeTailAndLogsExactTokens() {
        var messages = [String]()
        CellBase.enabledDiagnosticLogDomains = [.flow]
        CellBase.diagnosticLogHandler = { _, message in messages.append(message) }
        let purposes = (0..<8).map { String(format: "%08x", $0 + 100) }
        let interests = (0..<8).map { String(format: "%08x", $0 + 200) }
        let beacon = NearbyBeacon(
            sessionUUID: UUID().uuidString,
            entityKind: .person,
            purposeTokens: purposes,
            interestTokens: interests
        )

        let info = beacon.encodeToDiscoveryInfo()

        XCTAssertLessThanOrEqual(NearbyBeacon.utf8Size(of: info), 200)
        XCTAssertEqual(info["it"], interests.prefix(6).joined(separator: "."))
        XCTAssertEqual(info["pt"], purposes.prefix(6).joined(separator: "."))
        XCTAssertTrue(messages.contains { $0.contains(interests[7]) && $0.contains(purposes[7]) })
        XCTAssertNotNil(info["uuid"])
        XCTAssertEqual(info["v"], "1")
        XCTAssertEqual(info["k"], "p")
    }

    func testRealisticPolicyStaysWithinBonjourTXTBudget() {
        let purposes = (0..<8).map { String(format: "%08x", $0 + 100) }
        let interests = (0..<8).map { String(format: "%08x", $0 + 200) }
        let beacon = NearbyBeacon(
            sessionUUID: "01234567-89AB-CDEF-0123-456789ABCDEF",
            entityKind: .person,
            contextToken: "12345678",
            purposeTokens: purposes,
            interestTokens: interests
        )

        let info = beacon.encodeToDiscoveryInfo()

        XCTAssertEqual(info["pt"]?.split(separator: ".").count, 6)
        XCTAssertEqual(info["it"]?.split(separator: ".").count, 6)
        let encodedBytes = NearbyBeacon.utf8Size(of: info)
        XCTAssertLessThanOrEqual(encodedBytes, NearbyBeacon.maximumDiscoveryInfoBytes)
    }

    func testDiscoveryInfoRoundTripAndUnknownVersionRejection() {
        let beacon = NearbyBeacon(
            sessionUUID: UUID().uuidString,
            entityKind: .organization,
            contextToken: "0123abcd",
            purposeTokens: ["11111111", "22222222"],
            interestTokens: ["aaaaaaaa"]
        )
        let encoded = beacon.encodeToDiscoveryInfo()

        XCTAssertEqual(NearbyBeacon(discoveryInfo: encoded), beacon)
        var unknown = encoded
        unknown["v"] = "2"
        XCTAssertNil(NearbyBeacon(discoveryInfo: unknown))
    }

    func testOverlapIsSetIntersectionAndContextMatch() {
        let first = NearbyBeacon(
            sessionUUID: "first",
            entityKind: .person,
            contextToken: "12345678",
            purposeTokens: ["11111111", "22222222"],
            interestTokens: ["aaaaaaaa", "bbbbbbbb"]
        )
        let second = NearbyBeacon(
            sessionUUID: "second",
            entityKind: .event,
            contextToken: "12345678",
            purposeTokens: ["22222222", "33333333"],
            interestTokens: ["bbbbbbbb", "cccccccc"]
        )

        let overlap = first.overlap(with: second)

        XCTAssertEqual(overlap.matchedPurposeTokens, ["22222222"])
        XCTAssertEqual(overlap.matchedInterestTokens, ["bbbbbbbb"])
        XCTAssertEqual(overlap.count, 2)
        XCTAssertTrue(overlap.contextMatches)
    }
}
