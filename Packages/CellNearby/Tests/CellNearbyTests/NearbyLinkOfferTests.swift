import XCTest
@testable import CellNearby

final class NearbyLinkOfferTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let origins: Set<String> = ["https://staging.haven.digipomps.org", "https://haven.digipomps.org"]
    func offer(origin: String = "https://haven.digipomps.org", expires: Int64 = 2_000_000_120) -> NearbyLinkOffer {
        NearbyLinkOffer(origin: origin, offerID: String(repeating: "ab", count: 32), expiresAt: expires)
    }
    func testRoundTripAndNoIdentityInAdvertisement() throws {
        let value = offer()
        XCTAssertEqual(try NearbyLinkOffer.decodePublicationLink(value.publicationLink(), trustedOrigins: origins, now: now), value)
        XCTAssertEqual(try NearbyLinkOffer.fromDiscoveryFields(value.discoveryFields, trustedOrigins: origins, now: now), value)
        XCTAssertEqual(Set(value.discoveryFields.keys), ["v", "origin", "id", "expires"])
        XCTAssertEqual(value.fetchURL?.host, "haven.digipomps.org")
    }
    func testUntrustedLookalikeOriginsCannotReceiveRequests() {
        for origin in ["http://haven.digipomps.org", "https://haven.digipomps.org.evil.invalid", "https://haven.digipomps.org@evil.invalid", "https://haven.digipomps.org:444", "https://haven.digipomps.org/redirect", "https://evil.invalid", "https://HAVEN.digipomps.org"] {
            XCTAssertThrowsError(try offer(origin: origin).validate(trustedOrigins: origins, now: now), origin)
        }
    }
    func testExpiryLifetimeMalformedAndUnexpectedFieldsFailClosed() {
        XCTAssertThrowsError(try offer(expires: 2_000_000_000).validate(trustedOrigins: origins, now: now))
        XCTAssertThrowsError(try offer(expires: 2_000_001_000).validate(trustedOrigins: origins, now: now))
        for key in ["../request", "a", String(repeating: "Z", count: 64)] {
            XCTAssertThrowsError(try NearbyLinkOffer(origin: "https://haven.digipomps.org", offerID: key, expiresAt: 2_000_000_100).validate(trustedOrigins: origins, now: now))
        }
        var fields = offer().discoveryFields
        fields["entity"] = "private"
        XCTAssertThrowsError(try NearbyLinkOffer.fromDiscoveryFields(fields, trustedOrigins: origins, now: now))
        XCTAssertThrowsError(try NearbyLinkOffer.decodePublicationLink(URL(string:"haven://nearby-link?offer=a&offer=b")!, trustedOrigins: origins, now: now))
    }
}
