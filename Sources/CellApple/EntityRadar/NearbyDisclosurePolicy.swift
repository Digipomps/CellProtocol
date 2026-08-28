import CellBase
import Foundation

public struct NearbyDisclosurePolicy: Codable, Equatable, Sendable {
    public static let currentSchema = "cellprotocol.nearby.disclosurePolicy.v1"
    public static let defaultLifetime: TimeInterval = 8 * 60 * 60

    public enum ProbeMode: String, Codable, Sendable {
        case off
        case onOverlap
        case always
    }

    public enum ContactRequestMode: String, Codable, Sendable {
        case manualOnly
        case suggestOnOverlap
    }

    public var schema: String
    public var beaconEnabled: Bool
    public var entityKind: NearbyEntityKind
    public var beaconPurposeRefs: [String]
    public var beaconInterestRefs: [String]
    public var contextRefs: [String]
    public var probeMode: ProbeMode
    public var probeDisclosureRefs: [String]
    public var probeMaxPerPeer: Int
    public var probeMaxPerMinute: Int
    public var contactRequestMode: ContactRequestMode
    public var minimumOverlapForSuggestion: Int
    public var agreementTemplateRef: String?
    public var approvedAt: TimeInterval?
    public var expiresAt: TimeInterval?

    public init(
        schema: String = Self.currentSchema,
        beaconEnabled: Bool = false,
        entityKind: NearbyEntityKind = .person,
        beaconPurposeRefs: [String] = [],
        beaconInterestRefs: [String] = [],
        contextRefs: [String] = [],
        probeMode: ProbeMode = .onOverlap,
        probeDisclosureRefs: [String] = [],
        probeMaxPerPeer: Int = 2,
        probeMaxPerMinute: Int = 12,
        contactRequestMode: ContactRequestMode = .manualOnly,
        minimumOverlapForSuggestion: Int = 1,
        agreementTemplateRef: String? = nil,
        approvedAt: TimeInterval? = nil,
        expiresAt: TimeInterval? = nil
    ) {
        self.schema = schema
        self.beaconEnabled = beaconEnabled
        self.entityKind = entityKind
        self.beaconPurposeRefs = beaconPurposeRefs
        self.beaconInterestRefs = beaconInterestRefs
        self.contextRefs = contextRefs
        self.probeMode = probeMode
        self.probeDisclosureRefs = probeDisclosureRefs
        self.probeMaxPerPeer = probeMaxPerPeer
        self.probeMaxPerMinute = probeMaxPerMinute
        self.contactRequestMode = contactRequestMode
        self.minimumOverlapForSuggestion = minimumOverlapForSuggestion
        self.agreementTemplateRef = agreementTemplateRef
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }

    public static let strict = NearbyDisclosurePolicy(probeMode: .off)

    public static func approved(
        entityKind: NearbyEntityKind,
        purposeRefs: [String],
        interestRefs: [String],
        contextRefs: [String] = [],
        probeDisclosureRefs: [String] = [],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> NearbyDisclosurePolicy {
        NearbyDisclosurePolicy(
            beaconEnabled: true,
            entityKind: entityKind,
            beaconPurposeRefs: purposeRefs,
            beaconInterestRefs: interestRefs,
            contextRefs: contextRefs,
            probeMode: .onOverlap,
            probeDisclosureRefs: probeDisclosureRefs,
            approvedAt: now,
            expiresAt: now + defaultLifetime
        )
    }

    public var beacon: NearbyBeacon? {
        guard beaconEnabled else { return nil }
        return NearbyBeacon(
            sessionUUID: UUID().uuidString,
            entityKind: entityKind,
            contextToken: contextRefs.first.map(NearbyBeacon.token(forCanonicalReference:)),
            purposeTokens: beaconPurposeRefs.map(NearbyBeacon.token(forCanonicalReference:)),
            interestTokens: beaconInterestRefs.map(NearbyBeacon.token(forCanonicalReference:))
        )
    }

    public func isActive(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard beaconEnabled,
              let approvedAt,
              let expiresAt else { return false }
        return approvedAt <= now && now < expiresAt
    }

    public func validate(activePerspectiveRefs: Set<String>? = nil) throws {
        guard schema == Self.currentSchema else { throw ValidationError.unsupportedSchema(schema) }
        guard probeMaxPerPeer >= 0, probeMaxPerMinute >= 0 else { throw ValidationError.invalidRateLimit }
        guard minimumOverlapForSuggestion >= 1 else { throw ValidationError.invalidMinimumOverlap }

        let allRefs = beaconPurposeRefs + beaconInterestRefs + contextRefs + probeDisclosureRefs
        guard allRefs.allSatisfy({ $0.contains("://") && PortableReference.slugify($0) != "unknown" }) else {
            throw ValidationError.invalidReference
        }
        if let activePerspectiveRefs {
            let selectedPerspectiveRefs = Set(beaconPurposeRefs + beaconInterestRefs + probeDisclosureRefs)
            let missing = selectedPerspectiveRefs.subtracting(activePerspectiveRefs)
            guard missing.isEmpty else { throw ValidationError.referenceNotActive(missing.sorted()) }
        }
        if beaconEnabled {
            guard let approvedAt, let expiresAt, expiresAt > approvedAt else {
                throw ValidationError.missingOrInvalidApprovalWindow
            }
        }
    }

    public func redactedSummary() -> String {
        "NearbyDisclosurePolicy(schema=\(schema), beaconEnabled=\(beaconEnabled), kind=\(entityKind.rawValue), purposeCount=\(beaconPurposeRefs.count), interestCount=\(beaconInterestRefs.count), contextCount=\(contextRefs.count), probeMode=\(probeMode.rawValue), probeDisclosureCount=\(probeDisclosureRefs.count), approvedAt=\(String(describing: approvedAt)), expiresAt=\(String(describing: expiresAt)))"
    }

    public enum ValidationError: Error, Equatable {
        case unsupportedSchema(String)
        case invalidRateLimit
        case invalidMinimumOverlap
        case invalidReference
        case referenceNotActive([String])
        case missingOrInvalidApprovalWindow
    }
}
