import Foundation

/// An explicitly published, short-lived rendezvous reference. No identity,
/// credential, grant, user name or private key belongs in this object.
/// Discovery is untrusted: selecting an offer never activates an identity link.
public struct NearbyLinkOffer: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let schemaVersion = "haven.nearby-link-offer.v1"
    public static let maximumLifetime: TimeInterval = 300
    public let schema: String
    public let origin: String
    public let offerID: String
    public let expiresAt: Int64
    public var id: String { origin + "/" + offerID }

    public enum ValidationError: Error, Equatable {
        case invalidSchema, invalidOrigin, untrustedOrigin, invalidID, expired, excessiveLifetime, invalidEncoding
    }

    public init(origin: String, offerID: String, expiresAt: Int64) {
        self.schema = Self.schemaVersion
        self.origin = origin
        self.offerID = offerID
        self.expiresAt = expiresAt
    }

    public func validate(trustedOrigins: Set<String>, now: Date = Date()) throws {
        guard schema == Self.schemaVersion else { throw ValidationError.invalidSchema }
        guard let url = URLComponents(string: origin), url.scheme == "https",
              let host = url.host, !host.isEmpty, host == host.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty, url.port == nil,
              origin == "https://" + host, origin.utf8.count <= 200 else {
            throw ValidationError.invalidOrigin
        }
        guard trustedOrigins.contains(origin) else { throw ValidationError.untrustedOrigin }
        guard offerID.utf8.count == 64,
              offerID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ValidationError.invalidID
        }
        let remaining = Double(expiresAt) - now.timeIntervalSince1970
        guard remaining > 0 else { throw ValidationError.expired }
        guard remaining <= Self.maximumLifetime + 5 else { throw ValidationError.excessiveLifetime }
    }

    public var fetchURL: URL? { URL(string: origin + "/link/api/nearby/" + offerID) }

    public func publicationLink() throws -> URL {
        let data = try JSONEncoder().encode(self)
        let value = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "haven://nearby-link?offer=" + value)!
    }

    public static func decodePublicationLink(_ url: URL, trustedOrigins: Set<String>, now: Date = Date()) throws -> Self {
        guard url.absoluteString.utf8.count <= 2048,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "haven", c.host == "nearby-link", c.user == nil, c.password == nil,
              c.port == nil, c.path.isEmpty, c.fragment == nil,
              let items = c.queryItems, items.count == 1, items[0].name == "offer",
              let value = items[0].value else { throw ValidationError.invalidEncoding }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw ValidationError.invalidEncoding }
        let offer = try JSONDecoder().decode(Self.self, from: data)
        try offer.validate(trustedOrigins: trustedOrigins, now: now)
        return offer
    }

    public var discoveryFields: [String: String] {
        ["v": "1", "origin": origin, "id": offerID, "expires": String(expiresAt)]
    }

    public static func fromDiscoveryFields(_ fields: [String: String], trustedOrigins: Set<String>, now: Date = Date()) throws -> Self {
        guard Set(fields.keys) == Set(["v", "origin", "id", "expires"]), fields["v"] == "1",
              let origin = fields["origin"], let id = fields["id"],
              let rawExpiry = fields["expires"], let expiry = Int64(rawExpiry) else {
            throw ValidationError.invalidEncoding
        }
        let offer = Self(origin: origin, offerID: id, expiresAt: expiry)
        try offer.validate(trustedOrigins: trustedOrigins, now: now)
        return offer
    }
}
