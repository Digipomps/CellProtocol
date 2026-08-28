import Foundation

public struct NearbyProbeRequest: Codable, Equatable, Sendable {
    public var remoteUUID: String
    public var requestId: String
    public var nonce: String
    public var reasonTokens: [String]

    public init(remoteUUID: String, requestId: String, nonce: String, reasonTokens: [String]) {
        self.remoteUUID = remoteUUID
        self.requestId = requestId
        self.nonce = nonce
        self.reasonTokens = reasonTokens
    }
}

public enum NearbyProbeCountBucket: String, Codable, Sendable {
    case one = "1"
    case two = "2"
    case threeOrMore = "3+"

    init?(count: Int) {
        switch count {
        case 1: self = .one
        case 2: self = .two
        case 3...: self = .threeOrMore
        default: return nil
        }
    }
}

public struct NearbyProbeAggregate: Codable, Equatable, Sendable {
    public var requestId: String
    public var nonce: String
    public var entityKind: NearbyEntityKind
    public var purposeMatches: NearbyProbeCountBucket?
    public var interestMatches: NearbyProbeCountBucket?

    public init(
        requestId: String,
        nonce: String,
        entityKind: NearbyEntityKind,
        purposeMatches: NearbyProbeCountBucket?,
        interestMatches: NearbyProbeCountBucket?
    ) {
        self.requestId = requestId
        self.nonce = nonce
        self.entityKind = entityKind
        self.purposeMatches = purposeMatches
        self.interestMatches = interestMatches
    }
}

public struct NearbyProbeDetail: Codable, Equatable, Sendable {
    public var requestId: String
    public var references: [String]
    public var displayNames: [String: String]

    public init(requestId: String, references: [String], displayNames: [String: String] = [:]) {
        self.requestId = requestId
        self.references = references
        self.displayNames = displayNames
    }
}

public enum NearbyProbeResult: Codable, Equatable, Sendable {
    case aggregate(NearbyProbeAggregate)
    case detail(NearbyProbeDetail)
}

/// Ephemeral, session-scoped probe guard. It deliberately has no persistence API.
public struct NearbyProbeSession: Sendable {
    public static let maximumPayloadBytes = 1_024

    public private(set) var resultsByRemoteUUID = [String: NearbyProbeResult]()
    private var handledRequestIDs = Set<String>()
    private var handledNonces = Set<String>()
    private var probeCountByRemoteUUID = [String: Int]()
    private var probeTimestamps = [TimeInterval]()

    public init() {}

    public mutating func aggregateResponse(
        to request: NearbyProbeRequest,
        from remoteUUID: String,
        localBeacon: NearbyBeacon,
        remoteBeacon: NearbyBeacon,
        policy: NearbyDisclosurePolicy,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws -> NearbyProbeAggregate {
        guard encodedSize(request) <= Self.maximumPayloadBytes else { throw ProbeError.payloadTooLarge }
        guard request.remoteUUID == localBeacon.sessionUUID else {
            throw ProbeError.invalidRequest
        }
        guard !request.requestId.isEmpty, request.requestId.utf8.count <= 128,
              !request.nonce.isEmpty, request.nonce.utf8.count <= 128 else {
            throw ProbeError.invalidRequest
        }
        guard policy.isActive(at: now), policy.probeMode != .off else { throw ProbeError.policyInactive }
        guard localBeacon.overlap(with: remoteBeacon).count > 0 else { throw ProbeError.noBeaconOverlap }
        guard !handledRequestIDs.contains(request.requestId),
              !handledNonces.contains(request.nonce) else { throw ProbeError.duplicateRequest }

        let peerCount = probeCountByRemoteUUID[remoteUUID, default: 0]
        guard peerCount < policy.probeMaxPerPeer else { throw ProbeError.rateLimited }
        probeTimestamps.removeAll { now - $0 >= 60 }
        guard probeTimestamps.count < policy.probeMaxPerMinute else { throw ProbeError.rateLimited }
        handledRequestIDs.insert(request.requestId)
        handledNonces.insert(request.nonce)
        probeCountByRemoteUUID[remoteUUID] = peerCount + 1
        probeTimestamps.append(now)

        let reasons = Set(request.reasonTokens)
        let purposeCount = Set(localBeacon.purposeTokens).intersection(reasons).count
        let interestCount = Set(localBeacon.interestTokens).intersection(reasons).count
        let aggregate = NearbyProbeAggregate(
            requestId: request.requestId,
            nonce: request.nonce,
            entityKind: localBeacon.entityKind,
            purposeMatches: NearbyProbeCountBucket(count: purposeCount),
            interestMatches: NearbyProbeCountBucket(count: interestCount)
        )
        guard encodedSize(aggregate) <= Self.maximumPayloadBytes else { throw ProbeError.payloadTooLarge }
        return aggregate
    }

    public mutating func store(_ result: NearbyProbeResult, for remoteUUID: String) throws {
        guard encodedSize(result) <= Self.maximumPayloadBytes else { throw ProbeError.payloadTooLarge }
        resultsByRemoteUUID[remoteUUID] = result
    }

    public mutating func reset() {
        resultsByRemoteUUID.removeAll()
        handledRequestIDs.removeAll()
        handledNonces.removeAll()
        probeCountByRemoteUUID.removeAll()
        probeTimestamps.removeAll()
    }

    private func encodedSize<T: Encodable>(_ payload: T) -> Int {
        (try? JSONEncoder().encode(payload).count) ?? .max
    }

    public enum ProbeError: Error, Equatable {
        case payloadTooLarge
        case invalidRequest
        case policyInactive
        case noBeaconOverlap
        case duplicateRequest
        case rateLimited
    }
}
