import CellBase
#if canImport(CryptoKit)
import CryptoKit
#else
#error("NearbyBeacon requires CryptoKit for SHA-256 beacon token generation")
#endif
import Foundation

public enum NearbyEntityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case unspecified = "u"
    case person = "p"
    case organization = "o"
    case place = "l"
    case event = "e"
    case agent = "a"
}

public struct NearbyBeaconOverlap: Codable, Equatable, Sendable {
    public let matchedPurposeTokens: [String]
    public let matchedInterestTokens: [String]
    public let contextMatches: Bool

    public var count: Int {
        matchedPurposeTokens.count + matchedInterestTokens.count
    }
}

public struct NearbyBeacon: Codable, Equatable, Sendable {
    public static let currentVersion = "1"
    public static let maximumDiscoveryInfoBytes = 200
    public static let maximumTokensPerAxis = 6

    public let sessionUUID: String
    public let entityKind: NearbyEntityKind
    public let contextToken: String?
    public let purposeTokens: [String]
    public let interestTokens: [String]

    public init(
        sessionUUID: String,
        entityKind: NearbyEntityKind,
        contextToken: String? = nil,
        purposeTokens: [String] = [],
        interestTokens: [String] = []
    ) {
        self.sessionUUID = sessionUUID
        self.entityKind = entityKind
        self.contextToken = contextToken
        self.purposeTokens = Self.unique(purposeTokens)
        self.interestTokens = Self.unique(interestTokens)
    }

    public init?(discoveryInfo: [String: String]) {
        guard discoveryInfo["v"] == Self.currentVersion,
              let sessionUUID = discoveryInfo["uuid"],
              !sessionUUID.isEmpty,
              let kindValue = discoveryInfo["k"],
              let entityKind = NearbyEntityKind(rawValue: kindValue) else {
            return nil
        }

        let contextToken = discoveryInfo["c"]
        guard contextToken.map(Self.isToken) ?? true else { return nil }

        let purposeTokens = Self.tokens(from: discoveryInfo["pt"])
        let interestTokens = Self.tokens(from: discoveryInfo["it"])
        guard purposeTokens != nil, interestTokens != nil else { return nil }

        self.init(
            sessionUUID: sessionUUID,
            entityKind: entityKind,
            contextToken: contextToken,
            purposeTokens: purposeTokens ?? [],
            interestTokens: interestTokens ?? []
        )
    }

    public static func token(forCanonicalReference reference: String) -> String {
        let digest = SHA256.hash(data: Data(reference.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func token(kind: String, localReference: String?, name: String?) -> String? {
        PortableReference.make(kind: kind, localReference: localReference, name: name)
            .map(token(forCanonicalReference:))
    }

    public func encodeToDiscoveryInfo() -> [String: String] {
        var purposes = purposeTokens
        var interests = interestTokens
        var droppedPurposes: [String] = []
        var droppedInterests: [String] = []

        while interests.count > Self.maximumTokensPerAxis {
            droppedInterests.append(interests.removeLast())
        }
        while purposes.count > Self.maximumTokensPerAxis {
            droppedPurposes.append(purposes.removeLast())
        }

        var info = Self.discoveryInfo(
            sessionUUID: sessionUUID,
            entityKind: entityKind,
            contextToken: contextToken,
            purposeTokens: purposes,
            interestTokens: interests
        )

        while Self.utf8Size(of: info) > Self.maximumDiscoveryInfoBytes, !interests.isEmpty {
            droppedInterests.append(interests.removeLast())
            info = Self.discoveryInfo(
                sessionUUID: sessionUUID,
                entityKind: entityKind,
                contextToken: contextToken,
                purposeTokens: purposes,
                interestTokens: interests
            )
        }
        while Self.utf8Size(of: info) > Self.maximumDiscoveryInfoBytes, !purposes.isEmpty {
            droppedPurposes.append(purposes.removeLast())
            info = Self.discoveryInfo(
                sessionUUID: sessionUUID,
                entityKind: entityKind,
                contextToken: contextToken,
                purposeTokens: purposes,
                interestTokens: interests
            )
        }

        if !droppedInterests.isEmpty || !droppedPurposes.isEmpty {
            CellBase.diagnosticLog(
                "NearbyBeacon dropped interestTokens=\(droppedInterests) purposeTokens=\(droppedPurposes) encodedBytes=\(Self.utf8Size(of: info))",
                domain: .flow
            )
        }
        return info
    }

    public func overlap(with other: NearbyBeacon) -> NearbyBeaconOverlap {
        // A truncated, unsalted token collision is only a hint for whether a
        // peer may be worth probing. It is never proof of identity, trust,
        // access, contact, or agreement. The tokens are obfuscation against
        // casual sniffing, not confidentiality, and can be brute-forced.
        let matchedPurposes = Set(purposeTokens).intersection(other.purposeTokens).sorted()
        let matchedInterests = Set(interestTokens).intersection(other.interestTokens).sorted()
        return NearbyBeaconOverlap(
            matchedPurposeTokens: matchedPurposes,
            matchedInterestTokens: matchedInterests,
            contextMatches: contextToken != nil && contextToken == other.contextToken
        )
    }

    public static func utf8Size(of discoveryInfo: [String: String]) -> Int {
        discoveryInfo.reduce(into: 0) { total, pair in
            // Bonjour TXT records prefix every key=value entry with a length
            // octet. Count both that byte and the equals sign so the project
            // limit applies to the encoded TXT payload, not just its strings.
            total += 1 + pair.key.utf8.count + 1 + pair.value.utf8.count
        }
    }

    private static func discoveryInfo(
        sessionUUID: String,
        entityKind: NearbyEntityKind,
        contextToken: String?,
        purposeTokens: [String],
        interestTokens: [String]
    ) -> [String: String] {
        var info = [
            "uuid": sessionUUID,
            "v": currentVersion,
            "k": entityKind.rawValue
        ]
        if let contextToken { info["c"] = contextToken }
        if !purposeTokens.isEmpty { info["pt"] = purposeTokens.joined(separator: ".") }
        if !interestTokens.isEmpty { info["it"] = interestTokens.joined(separator: ".") }
        return info
    }

    private static func tokens(from encoded: String?) -> [String]? {
        guard let encoded, !encoded.isEmpty else { return [] }
        let tokens = encoded.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count <= maximumTokensPerAxis, tokens.allSatisfy(isToken) else { return nil }
        return unique(tokens)
    }

    private static func isToken(_ token: String) -> Bool {
        token.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil
    }

    private static func unique(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        return tokens.filter { seen.insert($0).inserted }
    }
}
