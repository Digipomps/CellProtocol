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
    public static let maximumHistoryCount = 512
    public static let maximumHistoryPeers = 128
    public static let maximumHistoryBytes = 128 * 1024
    public static let maximumResultCount = 128
    public static let maximumResultBytes = 160 * 1024
    public static let resultLifetime: TimeInterval = 60
    private struct History: Sendable {
        let id: String, nonce: String, remote: String
        let deadline: TimeInterval
        var bytes: Int { 96 + id.utf8.count + nonce.utf8.count + remote.utf8.count }
    }
    private var history: [History] = []
    private var resultDeadlines = [String: TimeInterval]()
    private var resultBytesByRemoteUUID = [String: Int]()
    private var probeTimestamps = [TimeInterval]()

    public init() {}

    var retainedSnapshot: (history: Int, peers: Int, historyBytes: Int, results: Int, resultBytes: Int, rate: Int) {
        (history.count, Set(history.map(\.remote)).count, history.reduce(0) { $0 + $1.bytes },
         resultsByRemoteUUID.count, resultBytesByRemoteUUID.values.reduce(0, +), probeTimestamps.count)
    }

    /// The cell's maintenance owns expiry. Replay/rate history survives transport
    /// reconnects and peer loss until the original local approval window ends.
    public mutating func prune(now: TimeInterval = Date().timeIntervalSince1970) {
        history.removeAll { now >= $0.deadline }
        probeTimestamps.removeAll { now - $0 >= 60 }
        for (remote, deadline) in resultDeadlines where now >= deadline { removeResult(for: remote) }
    }

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
        guard !remoteUUID.isEmpty, remoteUUID.utf8.count <= 128,
              let deadline = policy.expiresAt, deadline.isFinite else { throw ProbeError.invalidRequest }
        prune(now: now)
        guard !history.contains(where: { $0.id == request.requestId || $0.nonce == request.nonce }) else { throw ProbeError.duplicateRequest }
        let peerCount = history.filter { $0.remote == remoteUUID }.count
        guard peerCount < policy.probeMaxPerPeer,
              probeTimestamps.count < min(policy.probeMaxPerMinute, Self.maximumHistoryCount) else { throw ProbeError.rateLimited }
        let record = History(id: request.requestId, nonce: request.nonce, remote: remoteUUID, deadline: deadline)
        let usage = retainedSnapshot
        guard history.count < Self.maximumHistoryCount,
              peerCount > 0 || usage.peers < Self.maximumHistoryPeers,
              record.bytes <= Self.maximumHistoryBytes - usage.historyBytes else { throw ProbeError.capacity }
        history.append(record)
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

    public mutating func store(_ result: NearbyProbeResult, for remoteUUID: String, now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard !remoteUUID.isEmpty, remoteUUID.utf8.count <= 128 else { throw ProbeError.invalidRequest }
        let bytes = encodedSize(result)
        guard bytes <= Self.maximumPayloadBytes else { throw ProbeError.payloadTooLarge }
        prune(now: now)
        let oldBytes = resultBytesByRemoteUUID[remoteUUID] ?? 0
        guard resultsByRemoteUUID[remoteUUID] != nil || resultsByRemoteUUID.count < Self.maximumResultCount,
              retainedSnapshot.resultBytes - oldBytes + bytes + remoteUUID.utf8.count + 64 <= Self.maximumResultBytes else { throw ProbeError.capacity }
        resultsByRemoteUUID[remoteUUID] = result
        resultDeadlines[remoteUUID] = now + Self.resultLifetime
        resultBytesByRemoteUUID[remoteUUID] = bytes + remoteUUID.utf8.count + 64
    }

    mutating func removeResult(for remoteUUID: String) {
        resultsByRemoteUUID[remoteUUID] = nil
        resultDeadlines[remoteUUID] = nil
        resultBytesByRemoteUUID[remoteUUID] = nil
    }

    public mutating func reset() {
        resultsByRemoteUUID.removeAll()
        history.removeAll()
        resultDeadlines.removeAll()
        resultBytesByRemoteUUID.removeAll()
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
        case capacity
    }
}
